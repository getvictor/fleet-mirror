import SwiftUI

@main
struct FleetAgentApp: App {
    @StateObject private var configManager = ConfigurationManager()
    @StateObject private var apiClient = ApiClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configManager)
                .environmentObject(apiClient)
        }
    }
}
