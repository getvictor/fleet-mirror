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
        AppDelegate.apiClient = api
        AppDelegate.configManager = config

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

/// Handles BGAppRefreshTask, APNs push token registration, and silent push delivery.
class AppDelegate: NSObject, UIApplicationDelegate {
    static var pollingManager: PollingManager?
    static var apiClient: ApiClient?
    static var configManager: ConfigurationManager?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register background task
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: PollingManager.bgTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                AppDelegate.pollingManager?.handleBackgroundTask(refreshTask)
            }
        }

        // Register for remote notifications (silent push — no user permission needed)
        application.registerForRemoteNotifications()

        return true
    }

    // MARK: - APNs Token

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[Fleet] APNs push token: \(token)")

        // Submit to Fleet server
        Task { @MainActor in
            guard let api = AppDelegate.apiClient, let config = AppDelegate.configManager else { return }
            await api.submitPushToken(config: config, pushToken: token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected on simulator — no APNs connection
        print("[Fleet] Push registration failed (expected on simulator): \(error.localizedDescription)")
    }

    // MARK: - Silent Push

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("[Fleet] Silent push received")
        Task { @MainActor in
            guard let polling = AppDelegate.pollingManager else {
                completionHandler(.noData)
                return
            }
            await polling.performPollCycle()
            completionHandler(polling.lastError == nil ? .newData : .failed)
        }
    }
}
