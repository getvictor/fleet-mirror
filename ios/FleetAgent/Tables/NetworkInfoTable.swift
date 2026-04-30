import Network

/// Reports current network path status.
/// Columns: interface_type, is_expensive, is_constrained, status
/// Note: NWPathMonitor is async; we read the current path synchronously.
struct NetworkInfoTable: FleetTable {
    static let tableName = "network_info"

    static func generate() -> [TableRow] {
        let monitor = NWPathMonitor()
        let path = monitor.currentPath

        let interfaceType: String
        if path.usesInterfaceType(.wifi) {
            interfaceType = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            interfaceType = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            interfaceType = "ethernet"
        } else if path.usesInterfaceType(.loopback) {
            interfaceType = "loopback"
        } else {
            interfaceType = "other"
        }

        let status: String
        switch path.status {
        case .satisfied:            status = "connected"
        case .unsatisfied:          status = "disconnected"
        case .requiresConnection:   status = "requires_connection"
        @unknown default:           status = "unknown"
        }

        return [[
            "interface_type": interfaceType,
            "is_expensive": path.isExpensive ? "1" : "0",
            "is_constrained": path.isConstrained ? "1" : "0",
            "status": status,
        ]]
    }
}
