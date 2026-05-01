import Foundation

/// Row type returned by all table implementations.
typealias TableRow = [String: String]

/// Protocol that all virtual table implementations conform to.
protocol FleetTable {
    /// The table name as used in SQL queries (e.g. "device_info").
    static var tableName: String { get }

    /// Generate all rows for this table.
    static func generate() -> [TableRow]
}

/// Simple table-dispatch query engine.
/// Parses the table name from a SQL query and dispatches to the matching table implementation.
/// Supports basic WHERE clause filtering (equality only).
class QueryEngine {
    /// Registry of available tables, keyed by table name.
    private var tables: [String: FleetTable.Type] = [:]

    init() {
        register(DeviceInfoTable.self)
        register(OSVersionTable.self)
        register(BatteryTable.self)
        register(DiskSpaceTable.self)
        register(NetworkInfoTable.self)
        register(SystemInfoTable.self)
        register(ScreenTable.self)
        register(LocaleInfoTable.self)
        register(ThermalStateTable.self)
        register(ManagedConfigTable.self)
        register(PasscodeInfoTable.self)
    }

    func register(_ table: FleetTable.Type) {
        tables[table.tableName] = table
    }

    /// Execute a SQL query by dispatching to the appropriate table.
    /// Supports: SELECT ... FROM table [WHERE col = 'val' [AND ...]]
    /// Also handles: SELECT 1 (returns a single truthy row)
    func execute(_ query: String) -> [TableRow] {
        guard let tableName = parseTableName(query) else {
            // Handle "SELECT 1" or "SELECT 1;" (no FROM clause)
            // Used by Fleet for "All Hosts" label and policy checks
            let trimmed = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("select 1") && !trimmed.contains("from ") {
                return [["1": "1"]]
            }
            print("[Fleet] Could not parse table name from query: \(query)")
            return []
        }

        guard let table = tables[tableName] else {
            print("[Fleet] Unknown table: \(tableName)")
            return []
        }

        var rows = table.generate()

        // Apply WHERE clause filtering if present
        if query.range(of: "where ", options: .caseInsensitive) != nil {
            let conditions = parseWhereConditions(query)
            if conditions.isEmpty {
                // WHERE clause exists but couldn't parse any conditions
                // (uses LIKE, OR, IN, etc.) — return empty to avoid false matches
                return []
            }
            rows = rows.filter { row in
                conditions.allSatisfy { (column, value) in
                    row[column] == value
                }
            }
        }

        return rows
    }

    /// List all registered table names.
    var availableTableNames: [String] {
        tables.keys.sorted()
    }

    /// Extract the table name from a SQL query.
    /// Handles: SELECT ... FROM table_name ...
    func parseTableName(_ query: String) -> String? {
        guard let fromRange = query.range(of: "from ", options: .caseInsensitive) else { return nil }
        let afterFrom = query[fromRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        // Table name is the next word (stop at space, semicolon, or end)
        let tableName = afterFrom.prefix(while: { $0.isLetter || $0 == "_" || $0.isNumber })
        return tableName.isEmpty ? nil : String(tableName)
    }

    /// Parse simple WHERE conditions: column = 'value' [AND column2 = 'value2']
    /// Returns [(column, value)] pairs. Supports single-quoted and unquoted values.
    func parseWhereConditions(_ query: String) -> [(String, String)] {
        guard let whereRange = query.range(of: "where ", options: .caseInsensitive) else { return [] }
        let afterWhere = String(query[whereRange.upperBound...])

        // Split by AND
        let parts = afterWhere
            .replacingOccurrences(of: " AND ", with: "\n", options: .caseInsensitive)
            .split(separator: "\n")

        var conditions: [(String, String)] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            // Match: column = 'value' or column = value or column = "value"
            let components = trimmed.split(separator: "=", maxSplits: 1)
            guard components.count == 2 else { continue }

            let column = components[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = components[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                .trimmingCharacters(in: .whitespaces)

            // Strip quotes
            if (value.hasPrefix("'") && value.hasSuffix("'")) ||
               (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }

            conditions.append((column, value))
        }

        return conditions
    }
}
