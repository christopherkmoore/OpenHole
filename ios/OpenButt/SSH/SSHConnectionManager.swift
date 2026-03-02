import Foundation
import Citadel
import Crypto
import NIOSSH
import NIO

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

@MainActor
class SSHConnectionManager: ObservableObject {
    @Published var state: ConnectionState = .disconnected

    private var client: SSHClient?
    private(set) var connectedHost: String = ""
    private weak var wireGuard: WireGuardManager?

    var isConnected: Bool { state == .connected }

    init(wireGuard: WireGuardManager? = nil) {
        self.wireGuard = wireGuard
    }

    func connect(settings: AppSettings) async {
        guard state != .connecting else { return }
        state = .connecting

        do {
            let privateKey = try loadPrivateKey(settings: settings)

            // Try local host first with short timeout
            let localTimeout: Duration = settings.remoteHost.isEmpty ? .seconds(15) : .seconds(4)

            if !settings.sshHost.isEmpty {
                buttLog.info("[ssh] trying local \(settings.sshHost) (timeout \(localTimeout))")
                do {
                    let c = try await connectHost(host: settings.sshHost, port: settings.sshPort,
                                                   username: settings.sshUser, privateKey: privateKey,
                                                   timeout: localTimeout)
                    client = c
                    connectedHost = settings.sshHost
                    state = .connected
                    buttLog.info("[ssh] connected via local host")
                    return
                } catch {
                    buttLog.error("[ssh] local host failed: \(error)")
                }
            }

            // Fall back to remote host via WireGuard
            guard !settings.remoteHost.isEmpty else {
                throw SSHError.notConnected
            }

            // Auto-start WireGuard tunnel if enabled and configured
            if settings.wireguardEnabled, let wg = wireGuard, wg.hasConfig {
                buttLog.info("[ssh] starting WireGuard tunnel...")
                try await wg.ensureConnected(timeout: .seconds(12))
                buttLog.info("[ssh] WireGuard connected")
            }

            buttLog.info("[ssh] trying remote \(settings.remoteHost)")
            client = try await connectHost(host: settings.remoteHost, port: settings.sshPort,
                                            username: settings.sshUser, privateKey: privateKey,
                                            timeout: .seconds(15))
            connectedHost = settings.remoteHost
            state = .connected
            buttLog.info("[ssh] connected via WireGuard remote host")

        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func disconnect() async {
        try? await client?.close()
        client = nil
        connectedHost = ""
        state = .disconnected
    }

    func ensureConnected(settings: AppSettings) async {
        guard client != nil else {
            await connect(settings: settings)
            return
        }
        do {
            _ = try await client!.executeCommand("echo ok")
            if state != .connected { state = .connected }
        } catch {
            buttLog.info("SSH health check failed, reconnecting...")
            client = nil
            connectedHost = ""
            state = .disconnected
            await connect(settings: settings)
        }
    }

    @discardableResult
    func executeCommand(_ command: String) async throws -> String {
        guard let client else { throw SSHError.notConnected }
        let result = try await client.executeCommand(command)
        return String(buffer: result)
    }

    // MARK: - Private

    private func connectHost(host: String, port: Int, username: String,
                              privateKey: Curve25519.Signing.PrivateKey,
                              timeout: Duration) async throws -> SSHClient {
        try await withThrowingTaskGroup(of: SSHClient.self) { group in
            group.addTask {
                try await SSHClient.connect(
                    host: host, port: port,
                    authenticationMethod: .ed25519(username: username, privateKey: privateKey),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SSHError.connectionTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func loadPrivateKey(settings: AppSettings) throws -> Curve25519.Signing.PrivateKey {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let keyPath = docsDir.appendingPathComponent(settings.sshKeyName)
        if FileManager.default.fileExists(atPath: keyPath.path) {
            let keyData = try String(contentsOf: keyPath, encoding: .utf8)
            buttLog.info("[ssh] key loaded from file")
            return try Curve25519.Signing.PrivateKey(sshEd25519: keyData)
        }
        if let keyData = KeychainHelper.load(key: settings.privateKeyTag) {
            let keyString = String(data: keyData, encoding: .utf8) ?? ""
            buttLog.info("[ssh] key loaded from keychain")
            return try Curve25519.Signing.PrivateKey(sshEd25519: keyString)
        }
        buttLog.error("[ssh] no private key found")
        throw SSHError.noPrivateKey
    }
}

enum SSHError: LocalizedError {
    case notConnected
    case noPrivateKey
    case connectionTimeout

    var errorDescription: String? {
        switch self {
        case .notConnected:      return "SSH not connected"
        case .noPrivateKey:      return "No SSH private key found. Import or generate one in Settings."
        case .connectionTimeout: return "Connection timed out"
        }
    }
}
