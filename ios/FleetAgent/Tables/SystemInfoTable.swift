import UIKit

/// Reports hardware and kernel information.
/// Columns: model, cpu_arch, physical_memory, kernel_version, hostname
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

        return [[
            "model": device.model,
            "hardware_model": machine,
            "cpu_arch": machine,
            "physical_memory": String(processInfo.physicalMemory),
            "kernel_version": release,
            "hostname": nodename,
            "computer_name": device.name,
        ]]
    }
}
