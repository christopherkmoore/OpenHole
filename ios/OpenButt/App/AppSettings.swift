import SwiftUI

class AppSettings: ObservableObject {
    @Published var sshHost: String { didSet { save() } }
    @Published var remoteHost: String { didSet { save() } }
    @Published var wireguardEnabled: Bool { didSet { save() } }
    @Published var sshPort: Int { didSet { save() } }
    @Published var sshUser: String { didSet { save() } }
    @Published var sshKeyName: String { didSet { save() } }
    @Published var workingDirectory: String { didSet { save() } }
    @Published var claudeModel: String { didSet { save() } }
    @Published var permissionMode: String { didSet { save() } }
    @Published var approvedTools: Set<String> { didSet { save() } }
    @Published var activeSessionId: String? { didSet { save() } }
    @Published var isConfigured: Bool { didSet { save() } }
    @Published var sessionTitles: [String: String] { didSet { save() } }
    @Published var claudeToken: String {
        didSet {
            let trimmed = claudeToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if claudeToken != trimmed { claudeToken = trimmed; return }
            save()
        }
    }

    var privateKeyTag: String { "com.openbutt.ai.ssh.\(sshKeyName)" }

    private static let keychainKey = "com.openbutt.ai.settings"

    init() {
        // Load from keychain, fall back to defaults
        let saved = Self.loadFromKeychain()
        self.sshHost = saved?["ssh_host"] ?? ""
        self.remoteHost = saved?["remote_host"] ?? ""
        self.wireguardEnabled = (saved?["wireguard_enabled"] ?? "") == "true"
        self.sshPort = Int(saved?["ssh_port"] ?? "") ?? 22
        self.sshUser = saved?["ssh_user"] ?? ""
        self.sshKeyName = saved?["ssh_key_name"] ?? "openbutt-key"
        self.workingDirectory = saved?["working_directory"] ?? "~"
        self.claudeModel = saved?["claude_model"] ?? "claude-sonnet-4-6"
        let savedMode = saved?["permission_mode"] ?? "acceptEdits"
        let needsMigration = savedMode == "plan" || savedMode == "fullAuto"
        self.permissionMode = needsMigration ? "acceptEdits" : savedMode
        let toolsStr = saved?["approved_tools"] ?? ""
        self.approvedTools = toolsStr.isEmpty ? [] : Set(toolsStr.split(separator: ",").map(String.init))
        let sid = saved?["active_session_id"] ?? ""
        self.activeSessionId = sid.isEmpty ? nil : sid
        self.isConfigured = (saved?["is_configured"] ?? "") == "true"
        let titlesJson = saved?["session_titles"] ?? "{}"
        self.sessionTitles = (try? JSONDecoder().decode([String: String].self, from: Data(titlesJson.utf8))) ?? [:]
        self.claudeToken = saved?["claude_token"] ?? ""

        if needsMigration { save() }
    }

    func validate() -> Bool {
        !sshHost.isEmpty && !sshUser.isEmpty && sshPort > 0 && !claudeToken.isEmpty
    }

    private func save() {
        let dict: [String: String] = [
            "ssh_host": sshHost,
            "remote_host": remoteHost,
            "wireguard_enabled": wireguardEnabled ? "true" : "false",
            "ssh_port": "\(sshPort)",
            "ssh_user": sshUser,
            "ssh_key_name": sshKeyName,
            "working_directory": workingDirectory,
            "claude_model": claudeModel,
            "permission_mode": permissionMode,
            "approved_tools": approvedTools.sorted().joined(separator: ","),
            "active_session_id": activeSessionId ?? "",
            "is_configured": isConfigured ? "true" : "false",
            "session_titles": (try? String(data: JSONEncoder().encode(sessionTitles), encoding: .utf8)) ?? "{}",
            "claude_token": claudeToken
        ]
        guard let data = try? JSONEncoder().encode(dict) else { return }
        KeychainHelper.save(key: Self.keychainKey, data: data)
    }

    private static func loadFromKeychain() -> [String: String]? {
        guard let data = KeychainHelper.load(key: keychainKey) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
}
