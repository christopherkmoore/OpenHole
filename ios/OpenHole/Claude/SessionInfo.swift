import Foundation

struct SessionInfo: Identifiable, Comparable {
    let id: String
    let firstMessage: String
    let lastTimestamp: Date
    let messageCount: Int

    static func < (lhs: SessionInfo, rhs: SessionInfo) -> Bool {
        lhs.lastTimestamp > rhs.lastTimestamp // newest first
    }

    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastTimestamp, relativeTo: Date())
    }
}

@MainActor
class SessionListLoader: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var error: String?

    func load(ssh: SSHConnectionManager) async {
        guard ssh.isConnected else {
            error = "Not connected"
            return
        }

        isLoading = true
        error = nil

        do {
            let script = """
            for f in ~/.claude/projects/*/*.jsonl; do
              [ -f "$f" ] || continue
              SID=$(basename "$f" .jsonl)
              FIRST=$(head -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("content","?")[:80])' 2>/dev/null || echo "?")
              LAST=$(tail -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("timestamp","?"))' 2>/dev/null || echo "?")
              LINES=$(wc -l < "$f" | tr -d ' ')
              echo "$SID|$LINES|$LAST|$FIRST"
            done
            """
            let output = try await ssh.executeCommand(script)
            sessions = parseSessionList(output).sorted()
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func delete(id: String, ssh: SSHConnectionManager) async {
        guard ssh.isConnected else { return }

        // 1. Find ob-UUIDs from any process referencing this session
        let processOutput = (try? await ssh.executeCommand(
            "ps aux | grep '\(id)' | grep -v grep | grep -oE 'ob-[A-F0-9-]+' | sort -u"
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let obIds = processOutput.components(separatedBy: "\n").filter { !$0.isEmpty }

        // 2. Kill processes: by session ID and by each ob-UUID (catches orphan tail -f children)
        try? await ssh.executeCommand("pkill -f '[r]esume \(id)' 2>/dev/null; true")
        for obId in obIds {
            // [o]b- trick prevents pkill from matching its own shell
            let pattern = "[o]" + obId.dropFirst()
            try? await ssh.executeCommand("pkill -f '\(pattern)' 2>/dev/null; true")
        }

        // 3. Clean up temp files
        for obId in obIds {
            try? await ssh.executeCommand("rm -f /tmp/\(obId).in /tmp/\(obId).out")
        }

        // 4. Delete the session history file
        do {
            let findCmd = "find ~/.claude/projects -name '\(id).jsonl' -type f 2>/dev/null | head -1"
            let path = try await ssh.executeCommand(findCmd)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                try await ssh.executeCommand("rm -f '\(path)'")
            }
        } catch {
            holeLog.error("[sessions] delete failed: \(error)")
        }

        sessions.removeAll { $0.id == id }
    }

    private func parseSessionList(_ output: String) -> [SessionInfo] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return output.split(separator: "\n").compactMap { line -> SessionInfo? in
            let parts = line.split(separator: "|", maxSplits: 3)
            guard parts.count == 4 else { return nil }

            let id = String(parts[0])
            let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            let timestamp = iso.date(from: String(parts[2])) ?? Date.distantPast
            let firstMsg = String(parts[3])

            guard id.count > 8, firstMsg != "?" else { return nil }
            return SessionInfo(id: id, firstMessage: firstMsg, lastTimestamp: timestamp, messageCount: count)
        }
    }
}
