import Foundation

/// Reports filesystem storage capacity.
/// Columns: total_bytes, available_bytes, important_available_bytes, opportunistic_available_bytes
struct DiskSpaceTable: FleetTable {
    static let tableName = "disk_space"

    static func generate() -> [TableRow] {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())

        var total = ""
        var available = ""
        var important = ""
        var opportunistic = ""

        if let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ]) {
            total = String(values.volumeTotalCapacity ?? 0)
            available = String(values.volumeAvailableCapacity ?? 0)
            if let imp = values.volumeAvailableCapacityForImportantUsage {
                important = String(imp)
            }
            if let opp = values.volumeAvailableCapacityForOpportunisticUsage {
                opportunistic = String(opp)
            }
        }

        return [[
            "total_bytes": total,
            "available_bytes": available,
            "important_available_bytes": important,
            "opportunistic_available_bytes": opportunistic,
        ]]
    }
}
