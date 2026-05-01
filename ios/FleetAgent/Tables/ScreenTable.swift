import UIKit

/// Reports display properties.
/// Columns: width, height, scale, brightness
struct ScreenTable: FleetTable {
    static let tableName = "screen"

    static func generate() -> [TableRow] {
        let screen = UIScreen.main
        let bounds = screen.bounds

        return [[
            "width": String(Int(bounds.width)),
            "height": String(Int(bounds.height)),
            "scale": String(format: "%.1f", screen.scale),
            "brightness": String(format: "%.2f", screen.brightness),
        ]]
    }
}
