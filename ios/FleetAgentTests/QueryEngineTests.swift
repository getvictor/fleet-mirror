import XCTest
@testable import FleetAgent

final class QueryEngineTests: XCTestCase {
    var engine: QueryEngine!

    override func setUp() {
        super.setUp()
        engine = QueryEngine()
    }

    // MARK: - Table Name Parsing

    func testParseSimpleSelect() {
        XCTAssertEqual(engine.parseTableName("SELECT * FROM device_info"), "device_info")
    }

    func testParseCaseInsensitive() {
        XCTAssertEqual(engine.parseTableName("select * FROM Battery"), "battery")
    }

    func testParseWithWhereClause() {
        XCTAssertEqual(engine.parseTableName("SELECT level FROM battery WHERE level < 20"), "battery")
    }

    func testParseWithSpecificColumns() {
        XCTAssertEqual(engine.parseTableName("SELECT major, minor FROM os_version"), "os_version")
    }

    func testParseNoFrom() {
        XCTAssertNil(engine.parseTableName("SHOW TABLES"))
    }

    func testParseEmptyQuery() {
        XCTAssertNil(engine.parseTableName(""))
    }

    // MARK: - Table Registration

    func testAvailableTables() {
        let names = engine.availableTableNames
        XCTAssertTrue(names.contains("device_info"))
        XCTAssertTrue(names.contains("os_version"))
        XCTAssertTrue(names.contains("battery"))
        XCTAssertTrue(names.contains("disk_space"))
        XCTAssertTrue(names.contains("network_info"))
        XCTAssertTrue(names.contains("system_info"))
        XCTAssertTrue(names.contains("screen"))
        XCTAssertTrue(names.contains("locale_info"))
        XCTAssertTrue(names.contains("thermal_state"))
        XCTAssertTrue(names.contains("managed_config"))
        XCTAssertTrue(names.contains("passcode_info"))
        XCTAssertEqual(names.count, 11)
    }

    // MARK: - Query Execution

    func testExecuteDeviceInfo() {
        let rows = engine.execute("SELECT * FROM device_info")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNotNil(row["device_name"])
        XCTAssertNotNil(row["model"])
        XCTAssertNotNil(row["system_name"])
        XCTAssertNotNil(row["system_version"])
        XCTAssertNotNil(row["vendor_id"])
        XCTAssertEqual(row["is_physical_device"], "0")  // Simulator
    }

    func testExecuteOSVersion() {
        let rows = engine.execute("SELECT * FROM os_version")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNotNil(row["major"])
        XCTAssertNotNil(row["minor"])
        XCTAssertNotNil(row["patch"])
        XCTAssertEqual(row["platform"], "ios")
        // Version string should be major.minor.patch
        let version = row["version"]!
        XCTAssertTrue(version.contains("."), "Version should contain dots: \(version)")
    }

    func testExecuteBattery() {
        let rows = engine.execute("SELECT * FROM battery")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNotNil(row["level"])
        XCTAssertNotNil(row["state"])
        XCTAssertNotNil(row["is_charging"])
        // On simulator, battery state is unknown
        XCTAssertEqual(row["state"], "unknown")
    }

    func testExecuteDiskSpace() {
        let rows = engine.execute("SELECT * FROM disk_space")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNotNil(row["total_bytes"])
        XCTAssertNotNil(row["available_bytes"])
        // Total should be a positive number
        let total = Int(row["total_bytes"] ?? "0") ?? 0
        XCTAssertGreaterThan(total, 0)
    }

    func testExecuteNetworkInfo() {
        let rows = engine.execute("SELECT * FROM network_info")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNotNil(row["interface_type"])
        XCTAssertNotNil(row["status"])
        XCTAssertNotNil(row["is_expensive"])
    }

    func testExecuteSystemInfo() {
        let rows = engine.execute("SELECT * FROM system_info")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNotNil(row["model"])
        XCTAssertNotNil(row["hardware_model"])
        XCTAssertNotNil(row["physical_memory"])
        let memory = UInt64(row["physical_memory"] ?? "0") ?? 0
        XCTAssertGreaterThan(memory, 0)
    }

    func testExecuteScreen() {
        let rows = engine.execute("SELECT * FROM screen")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNotNil(row["width"])
        XCTAssertNotNil(row["height"])
        XCTAssertNotNil(row["scale"])
    }

    func testExecuteLocaleInfo() {
        let rows = engine.execute("SELECT * FROM locale_info")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNotNil(row["language"])
        XCTAssertNotNil(row["timezone"])
    }

    func testExecuteThermalState() {
        let rows = engine.execute("SELECT * FROM thermal_state")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["thermal_state"], "nominal")  // Simulator is always nominal
    }

    func testExecuteManagedConfig() {
        // No MDM config on simulator, should return empty
        let rows = engine.execute("SELECT * FROM managed_config")
        XCTAssertTrue(rows.isEmpty)
    }

    func testExecutePasscodeInfo() {
        let rows = engine.execute("SELECT * FROM passcode_info")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertNotNil(row["biometric_type"])
        XCTAssertNotNil(row["is_available"])
    }

    func testExecuteUnknownTable() {
        let rows = engine.execute("SELECT * FROM nonexistent_table")
        XCTAssertTrue(rows.isEmpty)
    }

    func testExecuteInvalidQuery() {
        let rows = engine.execute("INVALID SQL")
        XCTAssertTrue(rows.isEmpty)
    }
}
