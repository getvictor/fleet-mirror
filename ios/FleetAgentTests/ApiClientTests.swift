import XCTest
@testable import FleetAgent

// MARK: - Mock URL Protocol

private class MockURLProtocol: URLProtocol {
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

// MARK: - JSON Model Tests

final class EnrollRequestJSONTests: XCTestCase {
    func testEnrollRequestEncoding() throws {
        let request = EnrollRequest(
            enrollSecret: "secret123",
            hardwareUUID: "uuid-abc",
            hardwareSerial: "serial-xyz",
            platform: "ios",
            computerName: "Test iPhone"
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["enroll_secret"] as? String, "secret123")
        XCTAssertEqual(json["hardware_uuid"] as? String, "uuid-abc")
        XCTAssertEqual(json["hardware_serial"] as? String, "serial-xyz")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["computer_name"] as? String, "Test iPhone")
    }

    func testEnrollResponseDecoding() throws {
        let json = #"{"orbit_node_key": "node-key-12345"}"#
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(EnrollResponse.self, from: data)

        XCTAssertEqual(response.orbitNodeKey, "node-key-12345")
    }

    func testEnrollResponseIgnoresExtraFields() throws {
        let json = #"{"orbit_node_key": "key123", "extra": "ignored"}"#
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(EnrollResponse.self, from: data)

        XCTAssertEqual(response.orbitNodeKey, "key123")
    }
}

// MARK: - ApiClient Tests

@MainActor
final class ApiClientTests: XCTestCase {
    private var sessionConfig: URLSessionConfiguration!
    private var client: ApiClient!

    override func setUp() async throws {
        try await super.setUp()
        KeychainManager.shared.deleteOrbitNodeKey()

        sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        client = ApiClient(sessionConfiguration: sessionConfig)
    }

    override func tearDown() async throws {
        KeychainManager.shared.deleteOrbitNodeKey()
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    func testInitialStateIsUnenrolled() {
        XCTAssertEqual(client.enrollmentState, .unenrolled)
        XCTAssertNil(client.maskedNodeKey)
    }

    func testInitialStateIsEnrolledWhenKeychainHasKey() {
        KeychainManager.shared.saveOrbitNodeKey("existing-key")
        let newClient = ApiClient(sessionConfiguration: sessionConfig)
        XCTAssertEqual(newClient.enrollmentState, .enrolled)
    }

    func testClearEnrollment() {
        KeychainManager.shared.saveOrbitNodeKey("to-clear")
        client = ApiClient(sessionConfiguration: sessionConfig)
        XCTAssertEqual(client.enrollmentState, .enrolled)

        client.clearEnrollment()
        XCTAssertEqual(client.enrollmentState, .unenrolled)
        XCTAssertNil(KeychainManager.shared.loadOrbitNodeKey())
    }

    func testMaskedNodeKey() {
        KeychainManager.shared.saveOrbitNodeKey("abcdefghijklmnop")
        client = ApiClient(sessionConfiguration: sessionConfig)
        XCTAssertEqual(client.maskedNodeKey, "abcdefgh...")
    }

    func testMaskedNodeKeyShortKey() {
        KeychainManager.shared.saveOrbitNodeKey("short")
        client = ApiClient(sessionConfiguration: sessionConfig)
        XCTAssertEqual(client.maskedNodeKey, "short")
    }

    func testEnrollNotConfigured() async {
        let config = ConfigurationManager(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await client.enroll(config: config)
        XCTAssertEqual(client.enrollmentState, .error("Not configured"))
    }

    func testEnrollSuccess() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let config = ConfigurationManager(defaults: defaults)
        config.saveDebugConfig(
            serverURL: "https://fleet.test",
            enrollSecret: "secret",
            hostUUID: "test-uuid"
        )

        MockURLProtocol.requestHandler = { request in
            // Verify request
            XCTAssertEqual(request.url?.path, "/api/fleet/orbit/enroll")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            // Verify JSON body
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["enroll_secret"] as? String, "secret")
            XCTAssertEqual(body["hardware_uuid"] as? String, "test-uuid")
            XCTAssertEqual(body["platform"] as? String, "ios")

            let responseData = #"{"orbit_node_key": "test-node-key-success"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, responseData)
        }

        await client.enroll(config: config)

        XCTAssertEqual(client.enrollmentState, .enrolled)
        XCTAssertEqual(KeychainManager.shared.loadOrbitNodeKey(), "test-node-key-success")
    }

    func testEnrollServerError() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let config = ConfigurationManager(defaults: defaults)
        config.saveDebugConfig(serverURL: "https://fleet.test", enrollSecret: "secret", hostUUID: "")

        MockURLProtocol.requestHandler = { request in
            let responseData = #"{"error": "invalid secret"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, responseData)
        }

        await client.enroll(config: config)

        if case .error(let msg) = client.enrollmentState {
            XCTAssertTrue(msg.contains("401"), "Error should mention HTTP 401, got: \(msg)")
        } else {
            XCTFail("Expected error state, got: \(client.enrollmentState)")
        }
        XCTAssertNil(KeychainManager.shared.loadOrbitNodeKey())
    }

    func testEnrollNetworkError() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let config = ConfigurationManager(defaults: defaults)
        config.saveDebugConfig(serverURL: "https://fleet.test", enrollSecret: "secret", hostUUID: "")

        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await client.enroll(config: config)

        if case .error = client.enrollmentState {
            // Expected
        } else {
            XCTFail("Expected error state, got: \(client.enrollmentState)")
        }
    }

    func testReenrollOnUnauthorized() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let config = ConfigurationManager(defaults: defaults)
        config.saveDebugConfig(serverURL: "https://fleet.test", enrollSecret: "secret", hostUUID: "test-uuid")

        // Pre-enroll
        KeychainManager.shared.saveOrbitNodeKey("old-key")
        client = ApiClient(sessionConfiguration: sessionConfig)

        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1

            if request.url?.path == "/api/fleet/orbit/enroll" {
                let responseData = #"{"orbit_node_key": "new-key-after-reenroll"}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, responseData)
            }

            // Simulate a generic API call
            let responseData = Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        // Simulate a 401 error and verify re-enrollment
        let _: Void = try await client.withReenrollOnUnauthorized(config: config) {
            if callCount == 0 {
                throw ApiError(statusCode: 401, message: "Unauthorized")
            }
        }

        XCTAssertEqual(KeychainManager.shared.loadOrbitNodeKey(), "new-key-after-reenroll")
        XCTAssertEqual(client.enrollmentState, .enrolled)
    }

    func testDuplicateEnrollIsIgnored() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let config = ConfigurationManager(defaults: defaults)
        config.saveDebugConfig(serverURL: "https://fleet.test", enrollSecret: "secret", hostUUID: "")

        // Set state to enrolling manually
        client.enrollmentState = .enrolling

        // This should return immediately without making a request
        var requestMade = false
        MockURLProtocol.requestHandler = { _ in
            requestMade = true
            let response = HTTPURLResponse(url: URL(string: "https://fleet.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, #"{"orbit_node_key": "key"}"#.data(using: .utf8)!)
        }

        await client.enroll(config: config)
        XCTAssertFalse(requestMade, "Should not make request while already enrolling")
    }
}
