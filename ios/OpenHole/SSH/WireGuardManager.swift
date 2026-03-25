import Foundation
import NetworkExtension
import Combine

@MainActor
class WireGuardManager: ObservableObject {
    @Published var status: NEVPNStatus = .disconnected
    @Published var hasConfig: Bool = false

    private var manager: NETunnelProviderManager?
    private var statusObserver: Any?

    static let configKeychainKey = "com.openhole.ai.wireguard.peerConfig"
    static let appGroup = "group.com.openhole.ai"
    static let tunnelBundleID = "com.openhole.ai.tunnel"

    init() {
        Task { await loadManager() }
    }

    // MARK: - Setup

    /// Save WireGuard peer config to shared keychain and configure the VPN manager
    func configure(configString: String) async throws {
        // Save to shared keychain (accessible by extension)
        try saveConfigToKeychain(configString)
        hasConfig = true

        // Build the VPN configuration
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = "OpenHole WireGuard"
        proto.providerConfiguration = [:]

        let mgr = manager ?? NETunnelProviderManager()
        mgr.localizedDescription = "OpenHole"
        mgr.protocolConfiguration = proto
        mgr.isEnabled = true

        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()
        manager = mgr
        observeStatus()
        holeLog.info("[wg] configured VPN manager")
    }

    // MARK: - Connect / Disconnect

    func connect() async throws {
        guard let manager else { throw WireGuardError.notConfigured }
        try manager.connection.startVPNTunnel()
        holeLog.info("[wg] startVPNTunnel called")
    }

    func disconnect() async {
        manager?.connection.stopVPNTunnel()
        holeLog.info("[wg] stopVPNTunnel called")
    }

    /// Ensure the tunnel is connected, waiting up to `timeout` seconds.
    func ensureConnected(timeout: Duration = .seconds(10)) async throws {
        guard hasConfig else { throw WireGuardError.notConfigured }

        if status == .connected { return }

        if status != .connecting {
            try await connect()
        }

        // Wait for connected state
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if status == .connected { return }
            if status == .invalid || status == .disconnected {
                throw WireGuardError.connectionFailed
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw WireGuardError.timeout
    }

    // MARK: - Status

    var isConnected: Bool { status == .connected }

    var statusLabel: String {
        switch status {
        case .connected:     return "Connected"
        case .connecting:    return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        case .disconnected:  return "Disconnected"
        case .invalid:       return "Not configured"
        case .reasserting:   return "Reconnecting..."
        @unknown default:    return "Unknown"
        }
    }

    // MARK: - Private

    private func loadManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == Self.tunnelBundleID
            }) {
                manager = existing
                observeStatus()
                status = existing.connection.status
            }
            hasConfig = loadConfigFromKeychain() != nil
        } catch {
            holeLog.error("[wg] loadAllFromPreferences failed: \(error)")
        }
    }

    private func observeStatus() {
        if let obs = statusObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager?.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.status = self?.manager?.connection.status ?? .disconnected
                holeLog.info("[wg] status → \(self?.status.rawValue ?? -1)")
            }
        }
    }

    private func saveConfigToKeychain(_ config: String) throws {
        guard let data = config.data(using: .utf8) else { throw WireGuardError.invalidConfig }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.configKeychainKey,
            kSecAttrAccessGroup as String: Self.appGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw WireGuardError.keychainError(status) }
    }

    func loadConfigFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.configKeychainKey,
            kSecAttrAccessGroup as String: Self.appGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removeConfig() async {
        await disconnect()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.configKeychainKey,
            kSecAttrAccessGroup as String: Self.appGroup
        ]
        SecItemDelete(query as CFDictionary)
        hasConfig = false
    }
}

enum WireGuardError: LocalizedError {
    case notConfigured
    case invalidConfig
    case connectionFailed
    case timeout
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured:       return "WireGuard not configured. Import config in Settings."
        case .invalidConfig:       return "Invalid WireGuard configuration."
        case .connectionFailed:    return "WireGuard connection failed."
        case .timeout:             return "WireGuard connection timed out."
        case .keychainError(let s): return "Keychain error: \(s)"
        }
    }
}
