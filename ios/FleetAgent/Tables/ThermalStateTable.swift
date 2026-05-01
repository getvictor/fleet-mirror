import Foundation

/// Reports the device's current thermal state.
/// Columns: thermal_state
struct ThermalStateTable: FleetTable {
    static let tableName = "thermal_state"

    static func generate() -> [TableRow] {
        let state = ProcessInfo.processInfo.thermalState

        let stateString: String
        switch state {
        case .nominal:  stateString = "nominal"
        case .fair:     stateString = "fair"
        case .serious:  stateString = "serious"
        case .critical: stateString = "critical"
        @unknown default: stateString = "unknown"
        }

        return [[
            "thermal_state": stateString,
        ]]
    }
}
