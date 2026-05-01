import UIKit

/// Reports hardware and kernel information.
/// Column names match osquery's system_info table for Fleet detail query compatibility.
struct SystemInfoTable: FleetTable {
    static let tableName = "system_info"

    static func generate() -> [TableRow] {
        let device = UIDevice.current
        let processInfo = ProcessInfo.processInfo

        var sysinfo = utsname()
        uname(&sysinfo)

        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }

        let release = withUnsafePointer(to: &sysinfo.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }

        let nodename = withUnsafePointer(to: &sysinfo.nodename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }

        let vendorID = device.identifierForVendor?.uuidString ?? ""

        return [[
            // Columns the server reads from fleet_detail_query_system_info
            "physical_memory": String(processInfo.physicalMemory),
            "hostname": nodename,
            "uuid": vendorID,
            "cpu_type": machine,
            "cpu_subtype": "",
            "cpu_brand": machine,
            "cpu_physical_cores": String(processInfo.processorCount),
            "cpu_logical_cores": String(processInfo.activeProcessorCount),
            "hardware_vendor": "Apple",
            "hardware_model": machine,
            "hardware_version": "",
            "hardware_serial": "",
            "computer_name": device.name,
            // Extra columns for our tables view
            "kernel_version": release,
            "model": device.model,
        ]]
    }
}
