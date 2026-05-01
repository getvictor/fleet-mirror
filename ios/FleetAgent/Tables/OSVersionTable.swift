import Foundation
import UIKit

/// Reports the operating system version.
/// Column names match osquery's os_version table for Fleet detail query compatibility.
struct OSVersionTable: FleetTable {
    static let tableName = "os_version"

    static func generate() -> [TableRow] {
        let version = ProcessInfo.processInfo.operatingSystemVersion

        return [[
            "name": "iOS",
            "version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "major": String(version.majorVersion),
            "minor": String(version.minorVersion),
            "patch": String(version.patchVersion),
            "build": "",
            "platform": "ios",
            "platform_like": "ios",
            "codename": "",
            "arch": currentArch(),
            "extra": "",
        ]]
    }

    private static func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
