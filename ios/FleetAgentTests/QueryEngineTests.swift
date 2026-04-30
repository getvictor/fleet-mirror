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
        XCTAssertEqual(names.count, 3)
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

    func testExecuteUnknownTable() {
        let rows = engine.execute("SELECT * FROM nonexistent_table")
        XCTAssertTrue(rows.isEmpty)
    }

    func testExecuteInvalidQuery() {
        let rows = engine.execute("INVALID SQL")
        XCTAssertTrue(rows.isEmpty)
    }
}
