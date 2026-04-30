import SwiftUI
import BackgroundTasks

@main
struct FleetAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var configManager: ConfigurationManager
    @StateObject private var apiClient: ApiClient
    @StateObject private var pollingManager: PollingManager

    init() {
        let config = ConfigurationManager()
        let api = ApiClient()
        let polling = PollingManager(apiClient: api, configManager: config)
        _configManager = StateObject(wrappedValue: config)
        _apiClient = StateObject(wrappedValue: api)
        _pollingManager = StateObject(wrappedValue: polling)
        AppDelegate.pollingManager = polling

        // Load debug osquery node key into Keychain if set
        if let osqueryKey = config.loadDebugOsqueryNodeKey() {
            KeychainManager.shared.saveOsqueryNodeKey(osqueryKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configManager)
                .environmentObject(apiClient)
                .environmentObject(pollingManager)
        }
    }
}

/// Registers BGAppRefreshTask handler on launch.
class AppDelegate: NSObject, UIApplicationDelegate {
    static var pollingManager: PollingManager?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: PollingManager.bgTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                AppDelegate.pollingManager?.handleBackgroundTask(refreshTask)
            }
        }
        return true
    }
}
