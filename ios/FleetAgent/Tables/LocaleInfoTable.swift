import Foundation

/// Reports locale and timezone information.
/// Columns: language, region, timezone, timezone_abbreviation, calendar
struct LocaleInfoTable: FleetTable {
    static let tableName = "locale_info"

    static func generate() -> [TableRow] {
        let locale = Locale.current
        let tz = TimeZone.current

        return [[
            "language": locale.language.languageCode?.identifier ?? "",
            "region": locale.region?.identifier ?? "",
            "timezone": tz.identifier,
            "timezone_abbreviation": tz.abbreviation() ?? "",
            "calendar": locale.calendar.identifier.debugDescription,
        ]]
    }
}
