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
class QueryEngine {
    /// Registry of available tables, keyed by table name.
    private var tables: [String: FleetTable.Type] = [:]

    init() {
        register(DeviceInfoTable.self)
        register(OSVersionTable.self)
        register(BatteryTable.self)
    }

    func register(_ table: FleetTable.Type) {
        tables[table.tableName] = table
    }

    /// Execute a SQL query by dispatching to the appropriate table.
    /// Returns rows as dictionaries, or an empty array if the table is unknown.
    func execute(_ query: String) -> [TableRow] {
        guard let tableName = parseTableName(query) else {
            print("[Fleet] Could not parse table name from query: \(query)")
            return []
        }

        guard let table = tables[tableName] else {
            print("[Fleet] Unknown table: \(tableName)")
            return []
        }

        return table.generate()
    }

    /// List all registered table names.
    var availableTableNames: [String] {
        tables.keys.sorted()
    }

    /// Extract the table name from a SQL query.
    /// Handles: SELECT ... FROM table_name ...
    func parseTableName(_ query: String) -> String? {
        let lowered = query.lowercased()
        guard let fromRange = lowered.range(of: "from ") else { return nil }
        let afterFrom = lowered[fromRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        // Table name is the next word (stop at space, semicolon, or end)
        let tableName = afterFrom.prefix(while: { $0.isLetter || $0 == "_" || $0.isNumber })
        return tableName.isEmpty ? nil : String(tableName)
    }
}
