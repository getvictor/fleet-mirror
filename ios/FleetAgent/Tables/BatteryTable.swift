import UIKit

/// Reports battery level and charging state.
/// Columns: level, state, is_charging
/// Note: UIDevice.batteryLevel returns -1.0 when monitoring is not enabled,
/// so we enable it before reading and restore the previous state after.
struct BatteryTable: FleetTable {
    static let tableName = "battery"

    static func generate() -> [TableRow] {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }

        let level = device.batteryLevel  // 0.0 to 1.0, or -1.0 if unknown
        let state = device.batteryState

        let levelPercent: String
        if level < 0 {
            levelPercent = "-1"  // Unknown (simulator)
        } else {
            levelPercent = String(Int(level * 100))
        }

        return [[
            "level": levelPercent,
            "state": stateString(state),
            "is_charging": (state == .charging || state == .full) ? "1" : "0",
        ]]
    }

    private static func stateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown:    return "unknown"
        case .unplugged:  return "unplugged"
        case .charging:   return "charging"
        case .full:       return "full"
        @unknown default: return "unknown"
        }
    }
}
