import Network

/// Reports current Wi-Fi network information.
/// Columns: ssid, bssid, interface_type, is_connected
/// Note: SSID/BSSID require location permission or NEHotspotNetwork entitlement
/// on physical devices. On simulator, they return empty.
struct WifiNetworkTable: FleetTable {
    static let tableName = "wifi_networks"

    static func generate() -> [TableRow] {
        let monitor = NWPathMonitor()
        let path = monitor.currentPath
        let isWifi = path.usesInterfaceType(.wifi)

        return [[
            "ssid": "",  // Requires entitlement on physical device
            "bssid": "",
            "is_wifi": isWifi ? "1" : "0",
            "is_connected": path.status == .satisfied ? "1" : "0",
        ]]
    }
}
