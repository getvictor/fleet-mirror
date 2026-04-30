import Foundation

/// Reports the operating system version broken down by component.
/// Columns: major, minor, patch, version (full string), platform
struct OSVersionTable: FleetTable {
    static let tableName = "os_version"

    static func generate() -> [TableRow] {
        let version = ProcessInfo.processInfo.operatingSystemVersion

        return [[
            "major": String(version.majorVersion),
            "minor": String(version.minorVersion),
            "patch": String(version.patchVersion),
            "version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "platform": "ios",
        ]]
    }
}
