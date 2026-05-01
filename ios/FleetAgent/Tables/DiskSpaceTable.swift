import Foundation

/// Reports filesystem storage capacity.
/// Includes both our custom columns and osquery-compatible columns for detail query ingestion.
struct DiskSpaceTable: FleetTable {
    static let tableName = "disk_space"

    static func generate() -> [TableRow] {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())

        var totalBytes: Int64 = 0
        var availableBytes: Int64 = 0
        var important = ""
        var opportunistic = ""

        if let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ]) {
            totalBytes = Int64(values.volumeTotalCapacity ?? 0)
            availableBytes = Int64(values.volumeAvailableCapacity ?? 0)
            if let imp = values.volumeAvailableCapacityForImportantUsage {
                important = String(imp)
            }
            if let opp = values.volumeAvailableCapacityForOpportunisticUsage {
                opportunistic = String(opp)
            }
        }

        // Compute gigs and percent for server detail query compatibility
        let gigsTotal = totalBytes > 0 ? Double(totalBytes) / 1e9 : 0
        let gigsAvailable = Double(availableBytes) / 1e9
        let percentAvailable = totalBytes > 0
            ? Double(availableBytes) * 100.0 / Double(totalBytes)
            : 0

        return [[
            // osquery-compatible columns (used by fleet_detail_query_disk_space_darwin)
            "bytes_total": String(totalBytes),
            "bytes_available": String(availableBytes),
            "percent_disk_space_available": String(format: "%.2f", percentAvailable),
            "gigs_disk_space_available": String(format: "%.2f", gigsAvailable),
            "gigs_total_disk_space": String(format: "%.2f", gigsTotal),
            // Our extra columns
            "total_bytes": String(totalBytes),
            "available_bytes": String(availableBytes),
            "important_available_bytes": important,
            "opportunistic_available_bytes": opportunistic,
        ]]
    }
}
