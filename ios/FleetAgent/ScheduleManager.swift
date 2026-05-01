import Foundation
import UIKit

/// Info about a single scheduled query parsed from osquery config packs.
struct ScheduledQueryInfo: Identifiable {
    let id: String          // "pack_name/query_name"
    let packName: String
    let queryName: String
    let sql: String
    let interval: Int       // seconds
    let platform: String?
    let snapshot: Bool
}

/// Parses, tracks, and executes scheduled queries from the osquery config endpoint.
@MainActor
class ScheduleManager: ObservableObject {
    @Published var scheduledQueries: [ScheduledQueryInfo] = []
    @Published var lastConfigFetch: Date?
    @Published var lastScheduledRun: Date?
    @Published var lastRunCount: Int = 0
    @Published var lastError: String?

    let apiClient: ApiClient
    let configManager: ConfigurationManager
    let queryEngine: QueryEngine

    /// Tracks last execution time per query ID. Persisted in UserDefaults.
    private var lastExecutionTimes: [String: Date] = [:]
    private let defaults = UserDefaults.standard
    private let lastExecKey = "scheduled_query_last_exec"

    init(apiClient: ApiClient, configManager: ConfigurationManager, queryEngine: QueryEngine = QueryEngine()) {
        self.apiClient = apiClient
        self.configManager = configManager
        self.queryEngine = queryEngine
        loadExecutionTimes()
    }

    // MARK: - Config Fetch

    /// Fetch osquery config and parse scheduled queries from packs.
    func fetchConfig() async {
        do {
            let config = try await apiClient.withReenrollOnUnauthorized(config: configManager) {
                try await self.apiClient.getOsqueryConfig(config: self.configManager)
            }
            scheduledQueries = parseQueries(from: config)
            lastConfigFetch = Date()
            lastError = nil
            print("[Fleet] Schedule config: \(scheduledQueries.count) queries")
        } catch {
            lastError = error.localizedDescription
            print("[Fleet] Schedule config fetch failed: \(error)")
        }
    }

    // MARK: - Execution

    /// Check which scheduled queries are due and execute them.
    func runDueQueries() async {
        let now = Date()
        var dueQueries: [ScheduledQueryInfo] = []

        for query in scheduledQueries {
            let lastRun = lastExecutionTimes[query.id] ?? .distantPast
            let elapsed = now.timeIntervalSince(lastRun)
            if elapsed >= Double(query.interval) {
                dueQueries.append(query)
            }
        }

        guard !dueQueries.isEmpty else { return }

        let hardwareUUID = configManager.hostUUID.isEmpty
            ? (UIDevice.current.identifierForVendor?.uuidString ?? "")
            : configManager.hostUUID

        var results: [ScheduledQueryResultLog] = []

        for query in dueQueries {
            let rows = queryEngine.execute(query.sql)
            let resultName = "pack/\(query.packName)/\(query.queryName)"

            results.append(ScheduledQueryResultLog(
                name: resultName,
                hostIdentifier: hardwareUUID,
                snapshot: rows,
                unixTime: Int(now.timeIntervalSince1970)
            ))

            lastExecutionTimes[query.id] = now
            print("[Fleet] Scheduled query '\(query.queryName)': \(rows.count) rows")
        }

        saveExecutionTimes()

        // Submit results to Fleet
        if !results.isEmpty {
            do {
                try await apiClient.withReenrollOnUnauthorized(config: configManager) {
                    try await self.apiClient.submitScheduledResults(
                        config: self.configManager,
                        results: results
                    )
                }
                lastScheduledRun = now
                lastRunCount = results.count
                print("[Fleet] Submitted \(results.count) scheduled query results")
            } catch {
                lastError = error.localizedDescription
                print("[Fleet] Failed to submit scheduled results: \(error)")
            }
        }
    }

    // MARK: - Config Parsing

    func parseQueries(from config: OsqueryConfigResponse) -> [ScheduledQueryInfo] {
        guard let packs = config.packs else { return [] }

        var result: [ScheduledQueryInfo] = []

        for (packName, pack) in packs {
            if let packPlatform = pack.platform, !packPlatform.isEmpty {
                if !platformMatchesIOS(packPlatform) { continue }
            }

            guard let queries = pack.queries else { continue }

            for (queryName, content) in queries {
                guard let interval = content.interval, interval > 0 else { continue }

                if let queryPlatform = content.platform, !queryPlatform.isEmpty {
                    if !platformMatchesIOS(queryPlatform) { continue }
                }

                result.append(ScheduledQueryInfo(
                    id: "\(packName)/\(queryName)",
                    packName: packName,
                    queryName: queryName,
                    sql: content.query,
                    interval: interval,
                    platform: content.platform,
                    snapshot: content.snapshot ?? false
                ))
            }
        }

        return result.sorted { $0.id < $1.id }
    }

    private func platformMatchesIOS(_ platform: String) -> Bool {
        let platforms = platform.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return platforms.isEmpty || platforms.contains("ios") || platforms.contains("ipados") || platforms.contains("")
    }

    // MARK: - Persistence

    private func loadExecutionTimes() {
        if let saved = defaults.dictionary(forKey: lastExecKey) as? [String: Double] {
            lastExecutionTimes = saved.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    private func saveExecutionTimes() {
        let toSave = lastExecutionTimes.mapValues { $0.timeIntervalSince1970 }
        defaults.set(toSave, forKey: lastExecKey)
    }
}
