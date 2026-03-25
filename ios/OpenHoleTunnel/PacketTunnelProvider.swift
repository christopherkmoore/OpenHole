import NetworkExtension
import WireGuardKit
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var adapter: WireGuardAdapter?
    private let log = Logger(subsystem: "com.openhole.ai.tunnel", category: "PacketTunnelProvider")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log.info("startTunnel called")

        guard let configString = loadConfigFromSharedKeychain() else {
            log.error("No WireGuard config found in shared keychain")
            completionHandler(TunnelError.noConfig)
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(fromWgQuickConfig: configString, called: "OpenHole")
        } catch {
            log.error("Failed to parse WireGuard config: \(error)")
            completionHandler(error)
            return
        }

        adapter = WireGuardAdapter(with: self) { [weak self] logLevel, message in
            self?.log.debug("wg[\(logLevel.rawValue)]: \(message)")
        }

        adapter?.start(tunnelConfiguration: tunnelConfiguration) { [weak self] error in
            if let error {
                self?.log.error("WireGuard adapter start failed: \(error)")
                completionHandler(error)
            } else {
                self?.log.info("WireGuard tunnel started")
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("stopTunnel called: \(reason.rawValue)")
        adapter?.stop { [weak self] error in
            if let error { self?.log.error("Stop error: \(error)") }
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(nil)
    }

    // MARK: - Shared Keychain

    private func loadConfigFromSharedKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "com.openhole.ai.wireguard.peerConfig",
            kSecAttrAccessGroup as String: "group.com.openhole.ai",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum TunnelError: LocalizedError {
    case noConfig

    var errorDescription: String? {
        switch self {
        case .noConfig: return "No WireGuard configuration found. Import your server config in OpenHole settings."
        }
    }
}
