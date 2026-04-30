import Foundation
import Security

/// Manages secure storage of the orbit node key in the iOS Keychain.
/// Uses kSecAttrAccessibleAfterFirstUnlock so background tasks can access it.
class KeychainManager {
    static let shared = KeychainManager()

    private let service = "com.fleetdm.agent"
    private let nodeKeyAccount = "orbit_node_key"

    private init() {}

    func saveOrbitNodeKey(_ key: String) -> Bool {
        save(account: nodeKeyAccount, data: Data(key.utf8))
    }

    func loadOrbitNodeKey() -> String? {
        guard let data = load(account: nodeKeyAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteOrbitNodeKey() {
        delete(account: nodeKeyAccount)
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
