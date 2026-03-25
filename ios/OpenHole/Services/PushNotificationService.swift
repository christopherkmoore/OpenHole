import SwiftUI
import UserNotifications

class PushNotificationService: ObservableObject {
    @Published var deviceToken: String?
    @Published var isRegistered = false

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            Task { @MainActor in
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func handleToken(_ token: Data) {
        let tokenString = token.map { String(format: "%02.2hhx", $0) }.joined()
        deviceToken = tokenString
        isRegistered = true
    }

    /// Send the device token to the remote server via SSH
    func syncTokenToServer(connection: SSHConnectionManager, token: String) async {
        do {
            _ = try await connection.executeCommand("mkdir -p ~/.openhole && echo '\(token)' > ~/.openhole/device_token")
        } catch {
            print("Failed to sync device token: \(error)")
        }
    }
}
