import Foundation

/// Reports MDM-delivered Managed App Configuration key-value pairs.
/// Each key-value pair becomes a separate row.
/// Columns: key, value
struct ManagedConfigTable: FleetTable {
    static let tableName = "managed_config"

    static func generate() -> [TableRow] {
        guard let managed = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed") else {
            return []
        }

        return managed.map { key, value in
            ["key": key, "value": String(describing: value)]
        }
    }
}
