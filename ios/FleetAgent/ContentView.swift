import SwiftUI

struct ContentView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    @EnvironmentObject var apiClient: ApiClient
    @EnvironmentObject var pollingManager: PollingManager
    @State private var showDebugConfig = false
    @State private var showDebugTables = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Fleet Agent")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                configCard
                enrollmentCard
                pollingCard

                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showDebugConfig = true } label: {
                            Label("Server Config", systemImage: "gear")
                        }
                        Button { showDebugTables = true } label: {
                            Label("Query Tables", systemImage: "tablecells")
                        }
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showDebugConfig) {
                DebugConfigView()
            }
            .sheet(isPresented: $showDebugTables) {
                DebugTablesView()
            }
            .onChange(of: apiClient.enrollmentState) { newState in
                if case .enrolled = newState {
                    pollingManager.startForegroundPolling()
                } else {
                    pollingManager.stopForegroundPolling()
                }
            }
            .onAppear {
                if case .enrolled = apiClient.enrollmentState {
                    pollingManager.startForegroundPolling()
                }
            }
        }
    }

    // MARK: - Config Card

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                configManager.isConfigured ? "Configured" : "Not Configured",
                systemImage: configManager.isConfigured
                    ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .foregroundStyle(configManager.isConfigured ? .green : .orange)
            .font(.headline)

            if configManager.isConfigured {
                LabeledContent("Server", value: configManager.serverURL)
                LabeledContent("Source",
                               value: configManager.isManagedConfig ? "MDM" : "Debug")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Enrollment Card

    private var enrollmentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                enrollmentStatusLabel
                Spacer()
                enrollmentButton
            }

            if case .enrolled = apiClient.enrollmentState,
               let key = apiClient.maskedNodeKey {
                LabeledContent("Node Key", value: key)
                    .font(.caption)
            }

            if case .error(let msg) = apiClient.enrollmentState {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var enrollmentStatusLabel: some View {
        switch apiClient.enrollmentState {
        case .unenrolled:
            Label("Not Enrolled", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.orange)
                .font(.headline)
        case .enrolling:
            Label("Enrolling...", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
                .font(.headline)
        case .enrolled:
            Label("Enrolled", systemImage: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.green)
                .font(.headline)
        case .error:
            Label("Enrollment Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.headline)
        }
    }

    @ViewBuilder
    private var enrollmentButton: some View {
        switch apiClient.enrollmentState {
        case .unenrolled, .error:
            Button("Enroll") {
                Task { await apiClient.enroll(config: configManager) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!configManager.isConfigured)
        case .enrolling:
            ProgressView()
                .controlSize(.small)
        case .enrolled:
            Button("Unenroll", role: .destructive) {
                apiClient.clearEnrollment()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Polling Card

    private var pollingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if pollingManager.isPolling {
                    Label("Polling...", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.blue)
                        .font(.headline)
                } else if pollingManager.pollCount > 0 {
                    Label("Poll #\(pollingManager.pollCount)", systemImage: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                } else {
                    Label("Waiting", systemImage: "clock")
                        .foregroundStyle(.secondary)
                        .font(.headline)
                }
                Spacer()
                if case .enrolled = apiClient.enrollmentState {
                    Button {
                        Task { await pollingManager.performPollCycle() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(pollingManager.isPolling)
                }
            }

            if let time = pollingManager.lastPollTime {
                LabeledContent("Last Poll", value: formatTime(time))
                    .font(.caption)
            }

            if !pollingManager.lastQueryResults.isEmpty {
                let succeeded = pollingManager.lastQueryResults.values.filter { $0.status == 0 }.count
                LabeledContent("Last Queries", value: "\(succeeded)/\(pollingManager.lastQueryResults.count) ok")
                    .font(.caption)
            }

            LabeledContent("Interval", value: "\(Int(pollingManager.foregroundInterval))s (fg)")
                .font(.caption)

            if let error = pollingManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
