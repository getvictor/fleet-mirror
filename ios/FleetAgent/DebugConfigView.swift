import SwiftUI

struct DebugConfigView: View {
    @EnvironmentObject var configManager: ConfigurationManager
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var enrollSecret = ""
    @State private var hostUUID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Fleet Server") {
                    TextField("Server URL", text: $serverURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    TextField("Enroll Secret", text: $enrollSecret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }

                Section("Device") {
                    TextField("Host UUID (optional)", text: $hostUUID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))

                    Text("If empty, the device's vendor identifier will be used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Save") {
                        configManager.saveDebugConfig(
                            serverURL: serverURL,
                            enrollSecret: enrollSecret,
                            hostUUID: hostUUID
                        )
                        dismiss()
                    }
                    .disabled(serverURL.isEmpty || enrollSecret.isEmpty)
                }
            }
            .navigationTitle("Debug Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                serverURL = configManager.serverURL
                enrollSecret = configManager.enrollSecret
                hostUUID = configManager.hostUUID
            }
        }
    }
}
