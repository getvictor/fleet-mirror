import XCTest
@testable import FleetAgent

final class ConfigurationManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var configManager: ConfigurationManager!

    override func setUp() {
        super.setUp()
        suiteName = "com.fleetdm.agent.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        configManager = ConfigurationManager(defaults: defaults)
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeSuite(named: suiteName)
    }

    func testDefaultStateIsEmpty() {
        XCTAssertEqual(configManager.serverURL, "")
        XCTAssertEqual(configManager.enrollSecret, "")
        XCTAssertEqual(configManager.hostUUID, "")
        XCTAssertFalse(configManager.isManagedConfig)
        XCTAssertFalse(configManager.isConfigured)
    }

    func testSaveAndLoadDebugConfig() {
        configManager.saveDebugConfig(
            serverURL: "https://fleet.example.com",
            enrollSecret: "secret123",
            hostUUID: "uuid-456"
        )

        XCTAssertEqual(configManager.serverURL, "https://fleet.example.com")
        XCTAssertEqual(configManager.enrollSecret, "secret123")
        XCTAssertEqual(configManager.hostUUID, "uuid-456")
        XCTAssertFalse(configManager.isManagedConfig)
    }

    func testIsConfiguredRequiresBothURLAndSecret() {
        configManager.saveDebugConfig(serverURL: "https://fleet.example.com", enrollSecret: "", hostUUID: "")
        XCTAssertFalse(configManager.isConfigured)

        configManager.saveDebugConfig(serverURL: "", enrollSecret: "secret", hostUUID: "")
        XCTAssertFalse(configManager.isConfigured)

        configManager.saveDebugConfig(serverURL: "https://fleet.example.com", enrollSecret: "secret", hostUUID: "")
        XCTAssertTrue(configManager.isConfigured)
    }

    func testHostUUIDIsOptional() {
        configManager.saveDebugConfig(serverURL: "https://fleet.example.com", enrollSecret: "secret", hostUUID: "")
        XCTAssertTrue(configManager.isConfigured)
        XCTAssertEqual(configManager.hostUUID, "")
    }

    func testConfigPersistsAcrossInstances() {
        configManager.saveDebugConfig(
            serverURL: "https://fleet.example.com",
            enrollSecret: "secret123",
            hostUUID: "uuid-789"
        )

        let newManager = ConfigurationManager(defaults: defaults)
        XCTAssertEqual(newManager.serverURL, "https://fleet.example.com")
        XCTAssertEqual(newManager.enrollSecret, "secret123")
        XCTAssertEqual(newManager.hostUUID, "uuid-789")
    }

    func testManagedConfigTakesPrecedence() {
        // Set debug config first
        configManager.saveDebugConfig(
            serverURL: "https://debug.example.com",
            enrollSecret: "debug_secret",
            hostUUID: ""
        )

        // Simulate MDM-delivered managed config
        defaults.set(
            ["server_url": "https://mdm.example.com", "enroll_secret": "mdm_secret", "host_uuid": "mdm-uuid"],
            forKey: "com.apple.configuration.managed"
        )
        configManager.loadConfiguration()

        XCTAssertEqual(configManager.serverURL, "https://mdm.example.com")
        XCTAssertEqual(configManager.enrollSecret, "mdm_secret")
        XCTAssertEqual(configManager.hostUUID, "mdm-uuid")
        XCTAssertTrue(configManager.isManagedConfig)
    }
}
