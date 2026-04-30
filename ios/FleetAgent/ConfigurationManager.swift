import Foundation

/// Manages app configuration from MDM (Managed App Config) or debug settings.
/// In production, MDM pushes config via AppConfig. In development, values are
/// entered manually via the debug screen and stored in UserDefaults.
class ConfigurationManager: ObservableObject {
    @Published var serverURL: String = ""
    @Published var enrollSecret: String = ""
    @Published var hostUUID: String = ""
    @Published var isManagedConfig: Bool = false

    let defaults: UserDefaults

    enum Keys {
        static let serverURL = "debug_server_url"
        static let enrollSecret = "debug_enroll_secret"
        static let hostUUID = "debug_host_uuid"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadConfiguration()
    }

    func loadConfiguration() {
        // Try managed app config first (MDM AppConfig)
        if let managed = defaults.dictionary(forKey: "com.apple.configuration.managed") {
            serverURL = managed["server_url"] as? String ?? ""
            enrollSecret = managed["enroll_secret"] as? String ?? ""
            hostUUID = managed["host_uuid"] as? String ?? ""
            isManagedConfig = true
            return
        }

        // Fall back to debug config
        serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        enrollSecret = defaults.string(forKey: Keys.enrollSecret) ?? ""
        hostUUID = defaults.string(forKey: Keys.hostUUID) ?? ""
        isManagedConfig = false
    }

    func saveDebugConfig(serverURL: String, enrollSecret: String, hostUUID: String) {
        defaults.set(serverURL, forKey: Keys.serverURL)
        defaults.set(enrollSecret, forKey: Keys.enrollSecret)
        defaults.set(hostUUID, forKey: Keys.hostUUID)
        loadConfiguration()
    }

    var isConfigured: Bool {
        !serverURL.isEmpty && !enrollSecret.isEmpty
    }
}
