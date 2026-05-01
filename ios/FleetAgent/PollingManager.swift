import Foundation
import BackgroundTasks

/// Manages periodic polling of Fleet server for orbit config and distributed queries.
/// Runs in foreground via Timer and in background via BGAppRefreshTask.
@MainActor
class PollingManager: ObservableObject {
    static let bgTaskIdentifier = "com.fleetdm.agent.poll"

    @Published var lastPollTime: Date?
    @Published var pollCount: Int = 0
    @Published var lastError: String?
    @Published var isPolling: Bool = false
    @Published var lastConfig: OrbitConfigResponse?
    @Published var lastQueryResults: [String: QueryExecutionResult] = [:]

    private var foregroundTimer: Timer?
    let foregroundInterval: TimeInterval = 15

    let apiClient: ApiClient
    let configManager: ConfigurationManager
    let queryEngine: QueryEngine

    init(apiClient: ApiClient, configManager: ConfigurationManager, queryEngine: QueryEngine = QueryEngine()) {
        self.apiClient = apiClient
        self.configManager = configManager
        self.queryEngine = queryEngine
    }

    // MARK: - Foreground Polling

    func startForegroundPolling() {
        guard foregroundTimer == nil else { return }
        Task { await performPollCycle() }
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: foregroundInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.performPollCycle()
            }
        }
        print("[Fleet] Foreground polling started (every \(Int(foregroundInterval))s)")
    }

    func stopForegroundPolling() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    // MARK: - Background Task

    func scheduleBackgroundPoll() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[Fleet] Background poll scheduled")
        } catch {
            print("[Fleet] Failed to schedule background poll: \(error)")
        }
    }

    func handleBackgroundTask(_ task: BGAppRefreshTask) {
        task.expirationHandler = {
            print("[Fleet] Background task expired")
        }
        Task {
            await performPollCycle()
            task.setTaskCompleted(success: lastError == nil)
        }
    }

    // MARK: - Poll Cycle

    /// Full poll cycle: fetch config, fetch queries, execute, submit results.
    func performPollCycle() async {
        guard case .enrolled = apiClient.enrollmentState else { return }
        guard !isPolling else { return }

        isPolling = true
        defer { isPolling = false }

        do {
            // Step 1: Fetch orbit config
            let config = try await apiClient.withReenrollOnUnauthorized(config: configManager) {
                try await self.apiClient.getOrbitConfig(config: self.configManager)
            }
            lastConfig = config

            // Step 2: Fetch distributed queries
            let pendingQueries: [String: String]
            do {
                pendingQueries = try await apiClient.withReenrollOnUnauthorized(config: configManager) {
                    try await self.apiClient.getDistributedQueries(config: self.configManager)
                }
            } catch {
                // Distributed queries may fail until server-side Step 8 is done.
                // Log but don't fail the whole cycle.
                print("[Fleet] Distributed query fetch skipped: \(error)")
                pendingQueries = [:]
            }

            // Step 3: Execute queries and collect results
            if !pendingQueries.isEmpty {
                let executionResults = executeQueries(pendingQueries)
                lastQueryResults = executionResults

                // Step 4: Submit results
                try await submitResults(executionResults)
            }

            lastPollTime = Date()
            pollCount += 1
            lastError = nil

            let queryInfo = pendingQueries.isEmpty ? "" : " — executed \(pendingQueries.count) queries"
            print("[Fleet] Poll #\(pollCount) complete\(queryInfo)")
        } catch {
            lastError = error.localizedDescription
            print("[Fleet] Poll failed: \(error)")
        }

        scheduleBackgroundPoll()
    }

    // MARK: - Query Execution

    /// Execute each distributed query through the QueryEngine.
    func executeQueries(_ queries: [String: String]) -> [String: QueryExecutionResult] {
        var results: [String: QueryExecutionResult] = [:]

        for (name, sql) in queries {
            let rows = queryEngine.execute(sql)
            if queryEngine.parseTableName(sql) != nil {
                results[name] = QueryExecutionResult(rows: rows, status: 0, message: "")
                print("[Fleet] Executed query '\(name)': \(rows.count) rows")
            } else {
                results[name] = QueryExecutionResult(rows: [], status: 1, message: "Could not parse table name")
                print("[Fleet] Query '\(name)' failed: could not parse table name from: \(sql)")
            }
        }

        return results
    }

    /// Submit query results to Fleet server.
    private func submitResults(_ results: [String: QueryExecutionResult]) async throws {
        var queryResults: [String: [TableRow]] = [:]
        var statuses: [String: Int] = [:]
        var messages: [String: String] = [:]

        for (name, result) in results {
            queryResults[name] = result.rows
            statuses[name] = result.status
            messages[name] = result.message
        }

        try await apiClient.withReenrollOnUnauthorized(config: configManager) {
            try await self.apiClient.submitDistributedResults(
                config: self.configManager,
                results: queryResults,
                statuses: statuses,
                messages: messages
            )
        }
        print("[Fleet] Submitted results for \(results.count) queries")
    }
}

/// Result of executing a single distributed query.
struct QueryExecutionResult {
    let rows: [TableRow]
    let status: Int       // 0 = success, 1 = error
    let message: String   // Error message (empty on success)
}
