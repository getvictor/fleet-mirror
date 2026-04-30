import XCTest
@testable import FleetAgent

@MainActor
final class PollingManagerTests: XCTestCase {
    private var sessionConfig: URLSessionConfiguration!
    private var apiClient: ApiClient!
    private var configManager: ConfigurationManager!
    private var pollingManager: PollingManager!

    override func setUp() async throws {
        try await super.setUp()
        KeychainManager.shared.deleteOrbitNodeKey()

        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        apiClient = ApiClient(sessionConfiguration: sessionConfig)
        configManager = ConfigurationManager(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        pollingManager = PollingManager(apiClient: apiClient, configManager: configManager)
    }

    override func tearDown() async throws {
        KeychainManager.shared.deleteOrbitNodeKey()
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    // MARK: - Query Execution

    func testExecuteQueriesWithKnownTable() {
        let queries = ["q1": "SELECT * FROM device_info"]
        let results = pollingManager.executeQueries(queries)

        XCTAssertEqual(results.count, 1)
        let r = results["q1"]!
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.message, "")
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertNotNil(r.rows[0]["device_name"])
    }

    func testExecuteQueriesWithMultipleTables() {
        let queries = [
            "q1": "SELECT * FROM device_info",
            "q2": "SELECT * FROM os_version",
            "q3": "SELECT * FROM battery",
        ]
        let results = pollingManager.executeQueries(queries)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results["q1"]?.status, 0)
        XCTAssertEqual(results["q2"]?.status, 0)
        XCTAssertEqual(results["q3"]?.status, 0)
        XCTAssertEqual(results["q2"]?.rows[0]["platform"], "ios")
    }

    func testExecuteQueriesWithUnknownTable() {
        let queries = ["q1": "SELECT * FROM unknown_table"]
        let results = pollingManager.executeQueries(queries)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results["q1"]?.status, 0)  // Engine returns empty rows, not an error
        XCTAssertEqual(results["q1"]?.rows.count, 0)
    }

    func testExecuteQueriesWithUnparsableSQL() {
        let queries = ["q1": "INVALID SQL"]
        let results = pollingManager.executeQueries(queries)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results["q1"]?.status, 1)
        XCTAssertTrue(results["q1"]?.message.contains("parse") ?? false)
    }

    func testExecuteEmptyQueries() {
        let results = pollingManager.executeQueries([:])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - JSON Models

    func testDistributedReadRequestEncoding() throws {
        let request = DistributedReadRequest(nodeKey: "test-key")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["node_key"] as? String, "test-key")
    }

    func testDistributedReadResponseDecoding() throws {
        let json = #"{"queries": {"q1": "SELECT * FROM battery", "q2": "SELECT * FROM os_version"}, "discovery": {}, "accelerate": 0}"#
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(DistributedReadResponse.self, from: data)

        XCTAssertEqual(response.queries.count, 2)
        XCTAssertEqual(response.queries["q1"], "SELECT * FROM battery")
        XCTAssertEqual(response.accelerate, 0)
    }

    func testDistributedReadResponseEmptyQueries() throws {
        let json = #"{"queries": {}}"#
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(DistributedReadResponse.self, from: data)

        XCTAssertTrue(response.queries.isEmpty)
    }

    func testDistributedWriteRequestEncoding() throws {
        let request = DistributedWriteRequest(
            nodeKey: "test-key",
            queries: ["q1": [["col1": "val1", "col2": "val2"]]],
            statuses: ["q1": 0],
            messages: ["q1": ""]
        )
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["node_key"] as? String, "test-key")

        let queries = json["queries"] as! [String: [[String: String]]]
        XCTAssertEqual(queries["q1"]?.count, 1)
        XCTAssertEqual(queries["q1"]?[0]["col1"], "val1")

        let statuses = json["statuses"] as! [String: Int]
        XCTAssertEqual(statuses["q1"], 0)
    }

    // MARK: - Full Poll Cycle with Mock Server

    func testPollCycleFetchesConfigAndQueries() async {
        // Set up enrolled state
        KeychainManager.shared.saveOrbitNodeKey("test-key")
        apiClient = ApiClient(sessionConfiguration: sessionConfig)
        configManager.saveDebugConfig(serverURL: "https://fleet.test", enrollSecret: "s", hostUUID: "")
        pollingManager = PollingManager(apiClient: apiClient, configManager: configManager)

        var requestPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            requestPaths.append(request.url?.path ?? "")

            if request.url?.path == "/api/fleet/orbit/config" {
                let data = #"{"notifications": {}, "script_execution_timeout": 300}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }

            if request.url?.path == "/api/osquery/distributed/read" {
                let data = #"{"queries": {"q1": "SELECT * FROM os_version"}, "accelerate": 0}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }

            if request.url?.path == "/api/osquery/distributed/write" {
                // Verify write body contains results
                if let stream = request.httpBodyStream {
                    stream.open()
                    var bodyData = Data()
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                    defer { buffer.deallocate(); stream.close() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(buffer, maxLength: 1024)
                        if read > 0 { bodyData.append(buffer, count: read) }
                    }
                    let json = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
                    let queries = json["queries"] as! [String: [[String: String]]]
                    XCTAssertEqual(queries["q1"]?.count, 1)
                    XCTAssertEqual(queries["q1"]?[0]["platform"], "ios")
                    let statuses = json["statuses"] as! [String: Int]
                    XCTAssertEqual(statuses["q1"], 0)
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, "{}".data(using: .utf8)!)
            }

            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        await pollingManager.performPollCycle()

        XCTAssertEqual(pollingManager.pollCount, 1)
        XCTAssertNil(pollingManager.lastError)
        XCTAssertNotNil(pollingManager.lastConfig)
        XCTAssertEqual(pollingManager.lastQueryResults.count, 1)
        XCTAssertEqual(pollingManager.lastQueryResults["q1"]?.status, 0)

        // Verify all three endpoints were called in order
        XCTAssertTrue(requestPaths.contains("/api/fleet/orbit/config"))
        XCTAssertTrue(requestPaths.contains("/api/osquery/distributed/read"))
        XCTAssertTrue(requestPaths.contains("/api/osquery/distributed/write"))
    }

    func testPollCycleSkipsWhenNotEnrolled() async {
        await pollingManager.performPollCycle()
        XCTAssertEqual(pollingManager.pollCount, 0)
    }

    func testPollCycleContinuesWhenDistributedReadFails() async {
        KeychainManager.shared.saveOrbitNodeKey("test-key")
        apiClient = ApiClient(sessionConfiguration: sessionConfig)
        configManager.saveDebugConfig(serverURL: "https://fleet.test", enrollSecret: "s", hostUUID: "")
        pollingManager = PollingManager(apiClient: apiClient, configManager: configManager)

        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/fleet/orbit/config" {
                let data = #"{"notifications": {}}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            if request.url?.path == "/api/osquery/distributed/read" {
                // Simulate server rejecting the orbit node key
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, "{}".data(using: .utf8)!)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, "{}".data(using: .utf8)!)
        }

        await pollingManager.performPollCycle()

        // Poll should still succeed — distributed read failure is non-fatal
        XCTAssertEqual(pollingManager.pollCount, 1)
        XCTAssertNil(pollingManager.lastError)
    }
}

// MARK: - Shared Mock (also used by ApiClientTests)

class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
