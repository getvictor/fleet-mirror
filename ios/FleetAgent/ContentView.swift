import SwiftUI

struct ContentView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    @EnvironmentObject var apiClient: ApiClient
    @State private var helloCount = 0
    @State private var showDebugConfig = false
    @State private var lastHelloTime = ""

    /// Polling interval in seconds (will be configurable in later steps)
    private let pollingInterval: TimeInterval = 15

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Fleet Agent")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                // Config status
                configCard

                // Enrollment status
                enrollmentCard

                // Hello counter
                counterCard

                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showDebugConfig = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showDebugConfig) {
                DebugConfigView()
            }
            .onAppear { startTimer() }
        }
    }

    // MARK: - Cards

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

    private var counterCard: some View {
        VStack(spacing: 8) {
            Text("Hello #\(helloCount)")
                .font(.title2)
                .monospacedDigit()
            if !lastHelloTime.isEmpty {
                Text("Last: \(lastHelloTime)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Every \(Int(pollingInterval))s")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Timer

    private func startTimer() {
        Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { _ in
            DispatchQueue.main.async {
                helloCount += 1
                lastHelloTime = formattedTime()
                print("[\(lastHelloTime)] Hello #\(helloCount)")
            }
        }
    }

    private func formattedTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
