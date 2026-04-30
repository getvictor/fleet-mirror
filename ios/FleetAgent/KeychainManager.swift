import Foundation
import Security

/// Manages secure storage of the orbit node key in the iOS Keychain.
/// Uses kSecAttrAccessibleAfterFirstUnlock so background tasks can access it.
class KeychainManager {
    static let shared = KeychainManager()

    private let service = "com.fleetdm.agent"
    private let orbitKeyAccount = "orbit_node_key"
    private let osqueryKeyAccount = "osquery_node_key"

    private init() {}

    // MARK: - Orbit Node Key (for orbit/* endpoints)

    func saveOrbitNodeKey(_ key: String) -> Bool {
        save(account: orbitKeyAccount, data: Data(key.utf8))
    }

    func loadOrbitNodeKey() -> String? {
        guard let data = load(account: orbitKeyAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteOrbitNodeKey() {
        delete(account: orbitKeyAccount)
    }

    // MARK: - Osquery Node Key (for osquery/* distributed endpoints)

    func saveOsqueryNodeKey(_ key: String) -> Bool {
        save(account: osqueryKeyAccount, data: Data(key.utf8))
    }

    func loadOsqueryNodeKey() -> String? {
        guard let data = load(account: osqueryKeyAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteOsqueryNodeKey() {
        delete(account: osqueryKeyAccount)
    }

    // MARK: - Keychain Operations

    private func save(account: String, data: Data) -> Bool {
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
