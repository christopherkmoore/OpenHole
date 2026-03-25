import SwiftUI

@main
struct OpenHoleApp: App {
    @StateObject private var wireGuard = WireGuardManager()
    @StateObject private var appSettings = AppSettings()
    @StateObject private var claudeSession = ClaudeSession()
    private let connectionManager: SSHConnectionManager

    init() {
        let wg = WireGuardManager()
        let conn = SSHConnectionManager(wireGuard: wg)
        _wireGuard = StateObject(wrappedValue: wg)
        _appSettings = StateObject(wrappedValue: AppSettings())
        _claudeSession = StateObject(wrappedValue: ClaudeSession())
        connectionManager = conn
        OpenHoleShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionManager)
                .environmentObject(claudeSession)
                .environmentObject(appSettings)
                .environmentObject(wireGuard)
        }
    }
}
