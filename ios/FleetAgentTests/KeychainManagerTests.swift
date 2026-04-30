import XCTest
@testable import FleetAgent

final class KeychainManagerTests: XCTestCase {
    let keychain = KeychainManager.shared

    override func tearDown() {
        super.tearDown()
        keychain.deleteOrbitNodeKey()
    }

    func testSaveAndLoadOrbitNodeKey() {
        let key = "test-orbit-node-key-12345"
        XCTAssertTrue(keychain.saveOrbitNodeKey(key))
        XCTAssertEqual(keychain.loadOrbitNodeKey(), key)
    }

    func testLoadReturnsNilWhenEmpty() {
        keychain.deleteOrbitNodeKey()
        XCTAssertNil(keychain.loadOrbitNodeKey())
    }

    func testDeleteRemovesKey() {
        keychain.saveOrbitNodeKey("to-be-deleted")
        XCTAssertNotNil(keychain.loadOrbitNodeKey())

        keychain.deleteOrbitNodeKey()
        XCTAssertNil(keychain.loadOrbitNodeKey())
    }

    func testOverwriteReplacesOldValue() {
        keychain.saveOrbitNodeKey("old-key")
        keychain.saveOrbitNodeKey("new-key")
        XCTAssertEqual(keychain.loadOrbitNodeKey(), "new-key")
    }

    func testSaveEmptyString() {
        XCTAssertTrue(keychain.saveOrbitNodeKey(""))
        XCTAssertEqual(keychain.loadOrbitNodeKey(), "")
    }

    func testSaveLongKey() {
        let longKey = String(repeating: "a", count: 1024)
        XCTAssertTrue(keychain.saveOrbitNodeKey(longKey))
        XCTAssertEqual(keychain.loadOrbitNodeKey(), longKey)
    }
}
