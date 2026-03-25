import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connection: SSHConnectionManager
    @EnvironmentObject var session: ClaudeSession
    @EnvironmentObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !settings.isConfigured {
                SettingsView(initialSetup: true)
            } else {
                MainTabView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && settings.isConfigured {
                Task {
                    await connection.ensureConnected(settings: settings)
                    if connection.isConnected {
                        session.resume()
                    }
                    if connection.isConnected && session.state.needsRestart {
                        session.attach(to: connection)
                        await session.startSession(settings: settings)
                    }
                }
            } else if newPhase != .active {
                session.suspend()
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var connection: SSHConnectionManager
    @StateObject private var diffOverlay = DiffOverlayState()
    @Namespace private var diffNS

    var body: some View {
        TabView {
            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }

            FileBrowserView()
                .tabItem {
                    Label("Files", systemImage: "folder")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .environmentObject(diffOverlay)
        .onAppear { diffOverlay.namespace = diffNS }
        .overlay {
            if let diff = diffOverlay.expandedDiff {
                FullscreenDiffOverlay(diff: diff, namespace: diffOverlay.namespace) {
                    diffOverlay.collapse()
                }
            }
        }
    }
}
