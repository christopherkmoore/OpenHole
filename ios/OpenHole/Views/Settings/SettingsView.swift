import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var connection: SSHConnectionManager
    @EnvironmentObject var wireGuard: WireGuardManager
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var showKeyImport = false
    @State private var isFetchingConfig = false
    @State private var configError: String?
    var initialSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section("SSH Connection") {
                    TextField("Local Host (e.g. 192.168.1.100)", text: $settings.sshHost)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("Remote Host — WireGuard IP (10.8.0.1)", text: $settings.remoteHost)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", value: $settings.sshPort, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                    }

                    TextField("Username", text: $settings.sshUser)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    HStack {
                        Text("SSH Key")
                        Spacer()
                        Text(settings.sshKeyName)
                            .foregroundStyle(.secondary)
                    }

                    Button("Import SSH Key...") {
                        showKeyImport = true
                    }
                }

                Section("WireGuard") {
                    Toggle("Auto-connect when away from home", isOn: $settings.wireguardEnabled)

                    HStack {
                        Circle()
                            .fill(wireGuardStatusColor)
                            .frame(width: 8, height: 8)
                        Text(wireGuard.statusLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if wireGuard.isConnected {
                            Button("Disconnect") {
                                Task { await wireGuard.disconnect() }
                            }
                            .font(.caption)
                        }
                    }

                    Button(wireGuard.hasConfig ? "Re-import config from server" : "Import config from server") {
                        Task { await importWireGuardConfig() }
                    }
                    .disabled(isFetchingConfig || settings.sshHost.isEmpty)

                    if isFetchingConfig {
                        HStack {
                            ProgressView().scaleEffect(0.7)
                            Text("Fetching from server...").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if let configError {
                        Text(configError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if wireGuard.hasConfig {
                        Button("Forget Config", role: .destructive) {
                            Task { await wireGuard.removeConfig() }
                        }
                    }
                }

                Section("Claude Code") {
                    Picker("Model", selection: $settings.claudeModel) {
                        Text("Sonnet 4.6").tag("claude-sonnet-4-6")
                        Text("Opus 4.6").tag("claude-opus-4-6")
                        Text("Haiku 4.5").tag("claude-haiku-4-5-20251001")
                    }

                    Picker("Permission Mode", selection: $settings.permissionMode) {
                        Text("Default").tag("default")
                        Text("Accept Edits (Recommended)").tag("acceptEdits")
                        Text("Don't Ask").tag("dontAsk")
                        Text("Plan (Read-Only)").tag("plan")
                        Text("Bypass Permissions").tag("bypassPermissions")
                    }

                    TextField("Working Directory", text: $settings.workingDirectory)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                }

                Section("Approved Tools") {
                    if settings.approvedTools.isEmpty {
                        Text("No tools pre-approved. Tools will be approved as needed during chat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.approvedTools.sorted(), id: \.self) { tool in
                            HStack {
                                Image(systemName: ToolMeta.icon(for: tool))
                                    .foregroundStyle(ToolMeta.color(for: tool))
                                    .frame(width: 20)
                                Text(tool)
                                Spacer()
                                Button {
                                    settings.approvedTools.remove(tool)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Quick toggles
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick Add")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(["Read", "Write", "Edit", "Bash", "Glob", "Grep"], id: \.self) { tool in
                                Button {
                                    if settings.approvedTools.contains(tool) {
                                        settings.approvedTools.remove(tool)
                                    } else {
                                        settings.approvedTools.insert(tool)
                                    }
                                } label: {
                                    Text(tool)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(settings.approvedTools.contains(tool) ? Color.blue : Color(.systemGray5))
                                        .foregroundStyle(settings.approvedTools.contains(tool) ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !settings.approvedTools.isEmpty {
                        Button("Clear All", role: .destructive) {
                            settings.approvedTools = []
                        }
                    }
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            } else if let result = testResult {
                                Image(systemName: result.starts(with: "OK") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.starts(with: "OK") ? .green : .red)
                            }
                        }
                    }
                    .disabled(isTesting)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.starts(with: "OK") ? .green : .red)
                    }
                }

                if initialSetup {
                    Section {
                        Button("Save & Connect") {
                            settings.isConfigured = settings.validate()
                        }
                        .disabled(!settings.validate())
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.1.0")
                            .foregroundStyle(.secondary)
                    }
                    Link("GitHub", destination: URL(string: "https://github.com/christopherkmoore/OpenHole")!)
                }
            }
            .navigationTitle(initialSetup ? "Setup" : "Settings")
            .sheet(isPresented: $showKeyImport) {
                SSHKeyImportView()
            }
        }
    }

    private var wireGuardStatusColor: Color {
        switch wireGuard.status {
        case .connected: return .green
        case .connecting, .reasserting: return .yellow
        default: return .secondary
        }
    }

    private func importWireGuardConfig() async {
        isFetchingConfig = true
        configError = nil
        defer { isFetchingConfig = false }

        do {
            // Connect if not already connected
            if !connection.isConnected {
                await connection.connect(settings: settings)
                guard connection.isConnected else {
                    configError = "Import failed: could not connect to server"
                    return
                }
            }

            let config = try await connection.executeCommand(
                "cat ~/.openhole/peer.conf 2>/dev/null || echo ''"
            )
            let trimmed = config.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.hasPrefix("[Interface]") else {
                configError = "No config found on server. Run setup.sh first."
                return
            }
            try await wireGuard.configure(configString: trimmed)
        } catch {
            configError = "Import failed: \(error.localizedDescription)"
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil

        await connection.connect(settings: settings)

        switch connection.state {
        case .connected:
            do {
                let whoami = try await connection.executeCommand("whoami")
                let claudeVersion = try await connection.executeCommand("claude --version 2>/dev/null || echo 'not found'")
                var status = "OK: \(whoami.trimmingCharacters(in: .whitespacesAndNewlines))@\(connection.connectedHost), Claude \(claudeVersion.trimmingCharacters(in: .whitespacesAndNewlines))"

                testResult = status
            } catch {
                testResult = "SSH OK but command failed: \(error.localizedDescription)"
            }
        case .error(let e):
            testResult = "Failed: \(e)"
        default:
            testResult = "Failed: unexpected state"
        }

        isTesting = false
    }

}

// MARK: - Flow Layout for tool chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

// MARK: - SSH Key Import

struct SSHKeyImportView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var keyContent = ""
    @State private var keyName = "openhole-key"

    var body: some View {
        NavigationStack {
            Form {
                Section("Private Key") {
                    TextEditor(text: $keyContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    TextField("Key Name", text: $keyName)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("Paste your SSH private key (Ed25519 or RSA). The key will be stored in the app's keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importKey()
                        dismiss()
                    }
                    .disabled(keyContent.isEmpty)
                }
            }
        }
    }

    private func importKey() {
        guard let data = keyContent.data(using: .utf8) else { return }
        settings.sshKeyName = keyName
        _ = KeychainHelper.save(key: settings.privateKeyTag, data: data)
    }
}
