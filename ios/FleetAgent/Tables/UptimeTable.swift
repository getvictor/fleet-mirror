import Foundation

/// Reports system uptime.
/// Columns: total_seconds, days, hours, minutes
struct UptimeTable: FleetTable {
    static let tableName = "uptime"

    static func generate() -> [TableRow] {
        let uptime = ProcessInfo.processInfo.systemUptime
        let totalSeconds = Int(uptime)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60

        return [[
            "total_seconds": String(totalSeconds),
            "days": String(days),
            "hours": String(hours),
            "minutes": String(minutes),
        ]]
    }
}
