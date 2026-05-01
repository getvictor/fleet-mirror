import Foundation

/// Reports agent version info, mimicking osquery's osquery_info table.
/// Used by fleet_detail_query_osquery_info to populate the osquery version in Fleet.
struct OsqueryInfoTable: FleetTable {
    static let tableName = "osquery_info"

    static func generate() -> [TableRow] {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

        return [[
            "version": appVersion,
            "build_platform": "ios",
            "build_distro": "ios",
            "config_hash": "",
            "config_valid": "1",
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "uuid": UUID().uuidString,
            "instance_id": UUID().uuidString,
            "start_time": "0",
            "watcher": "-1",
        ]]
    }
}
