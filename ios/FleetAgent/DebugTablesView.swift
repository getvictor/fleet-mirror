import SwiftUI

/// Debug view that shows the output of all registered query engine tables.
struct DebugTablesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var results: [(table: String, rows: [TableRow])] = []

    private let engine = QueryEngine()

    var body: some View {
        NavigationStack {
            List {
                ForEach(results, id: \.table) { result in
                    Section(result.table) {
                        if result.rows.isEmpty {
                            Text("No rows")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
                                ForEach(row.keys.sorted(), id: \.self) { key in
                                    LabeledContent(key, value: row[key] ?? "")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Query Tables")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { runAllQueries() }
        }
    }

    private func runAllQueries() {
        results = engine.availableTableNames.map { name in
            let rows = engine.execute("SELECT * FROM \(name)")
            return (table: name, rows: rows)
        }
    }
}
