import UIKit

/// Reports accessibility settings.
/// Columns: is_bold_text_enabled, is_reduce_motion_enabled, is_voiceover_running,
///          is_grayscale_enabled, is_invert_colors_enabled, preferred_content_size
struct AccessibilityTable: FleetTable {
    static let tableName = "accessibility_settings"

    static func generate() -> [TableRow] {
        return [[
            "is_bold_text_enabled": UIAccessibility.isBoldTextEnabled ? "1" : "0",
            "is_reduce_motion_enabled": UIAccessibility.isReduceMotionEnabled ? "1" : "0",
            "is_voiceover_running": UIAccessibility.isVoiceOverRunning ? "1" : "0",
            "is_grayscale_enabled": UIAccessibility.isGrayscaleEnabled ? "1" : "0",
            "is_invert_colors_enabled": UIAccessibility.isInvertColorsEnabled ? "1" : "0",
            "preferred_content_size": UIApplication.shared.preferredContentSizeCategory.rawValue,
        ]]
    }
}
