import UIKit

/// Reports device identity and model information.
/// Columns: device_name, model, system_name, system_version, vendor_id, is_physical_device
struct DeviceInfoTable: FleetTable {
    static let tableName = "device_info"

    static func generate() -> [TableRow] {
        let device = UIDevice.current
        let vendorID = device.identifierForVendor?.uuidString ?? ""

        #if targetEnvironment(simulator)
        let isPhysical = "0"
        #else
        let isPhysical = "1"
        #endif

        return [[
            "device_name": device.name,
            "model": device.model,
            "system_name": device.systemName,
            "system_version": device.systemVersion,
            "vendor_id": vendorID,
            "is_physical_device": isPhysical,
        ]]
    }
}
