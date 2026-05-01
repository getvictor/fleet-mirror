import Foundation

/// Reports iCloud account status.
/// Columns: is_signed_in
struct ICloudInfoTable: FleetTable {
    static let tableName = "icloud_info"

    static func generate() -> [TableRow] {
        let token = FileManager.default.ubiquityIdentityToken
        return [[
            "is_signed_in": token != nil ? "1" : "0",
        ]]
    }
}
