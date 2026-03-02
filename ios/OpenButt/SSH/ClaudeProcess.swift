import Foundation
import os

class ClaudeProcess: @unchecked Sendable {
    let processId: String
    private let ssh: SSHConnectionManager
    private var pollTask: Task<Void, Never>?
    private var lastServerSize: Int = 0
    private var lineBuffer: String = ""
    private var pid: Int?
    private let _isPaused = OSAllocatedUnfairLock(initialState: false)
    var onLines: (@Sendable ([String]) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private var inFile: String { "/tmp/ob-\(processId).in" }
    private var outFile: String { "/tmp/ob-\(processId).out" }

    init(ssh: SSHConnectionManager) {
        self.processId = UUID().uuidString
        self.ssh = ssh
    }

    /// Start persistent process on server
    /// - Parameters:
    ///   - command: The claude CLI command (no cd prefix)
    ///   - workingDirectory: Directory to cd into before running (default "~")
    func start(command: String, workingDirectory: String = "~") async throws {
        buttLog.info("[process] creating files: \(inFile), \(outFile)")
        try await ssh.executeCommand("touch \(inFile) && : > \(outFile)")

        let escapedCmd = command.replacingOccurrences(of: "'", with: "'\\''")

        // cd goes INSIDE sh -c so the nohup is backgrounded directly (no subshell
        // wrapping a && chain). ~ is unquoted so sh expands it; other paths are
        // double-quoted to handle spaces.
        let cdPart: String
        if workingDirectory == "~" || workingDirectory.hasPrefix("~/") {
            cdPart = "cd \(workingDirectory)"
        } else {
            let escapedDir = workingDirectory.replacingOccurrences(of: "\"", with: "\\\"")
            cdPart = "cd \"\(escapedDir)\""
        }

        let launchCmd = "nohup sh -c '\(cdPart) && tail -f \(inFile) | \(escapedCmd) > \(outFile) 2>&1' </dev/null >/dev/null 2>&1 & echo $!"
        buttLog.debug("[process] launch command: \(launchCmd)")
        let output = try await ssh.executeCommand(launchCmd)
        let pidStr = output.trimmingCharacters(in: .whitespacesAndNewlines)
        pid = Int(pidStr)
        buttLog.info("[process] started \(processId) with PID \(pidStr)")
    }

    /// Append a JSON message to the input file
    func sendMessage(_ json: String) async throws {
        buttLog.debug("[process] sendMessage: writing \(json.count) chars to \(inFile)")
        let escaped = json.replacingOccurrences(of: "'", with: "'\\''")
        try await ssh.executeCommand(
            "printf '%s\\n' '\(escaped)' >> \(inFile)"
        )
        buttLog.debug("[process] sendMessage: write complete")
    }

    func pausePolling() {
        _isPaused.withLock { $0 = true }
        buttLog.info("[poll] paused (app backgrounded)")
    }

    func resumePolling() {
        _isPaused.withLock { $0 = false }
        buttLog.info("[poll] resumed")
    }

    /// Start polling the output file for new lines
    func startPolling() {
        lastServerSize = 0
        lineBuffer = ""
        pollTask = Task { [weak self] in
            var consecutiveErrors = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { break }

                if self._isPaused.withLock({ $0 }) {
                    consecutiveErrors = 0
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }

                do {
                    // Check file size on the server
                    let sizeOutput = try await self.ssh.executeCommand(
                        "wc -c < \(self.outFile) 2>/dev/null"
                    )
                    let currentSize = Int(sizeOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    consecutiveErrors = 0

                    guard currentSize > self.lastServerSize else { continue }

                    buttLog.debug("[poll] file grew: \(self.lastServerSize) → \(currentSize) bytes")

                    let output = try await self.ssh.executeCommand(
                        "tail -c +\(self.lastServerSize + 1) \(self.outFile) 2>/dev/null"
                    )
                    guard !output.isEmpty else {
                        buttLog.debug("[poll] tail returned empty despite size growth")
                        continue
                    }

                    buttLog.debug("[poll] read \(output.count) chars of new output")
                    self.lastServerSize = currentSize
                    self.lineBuffer += output

                    var lines = self.lineBuffer.components(separatedBy: "\n")
                    self.lineBuffer = lines.removeLast()

                    let jsonLines = lines.compactMap { line -> String? in
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        return (!trimmed.isEmpty && trimmed.hasPrefix("{")) ? trimmed : nil
                    }

                    if !jsonLines.isEmpty {
                        buttLog.info("[poll] delivering \(jsonLines.count) JSON lines to handler")
                        self.onLines?(jsonLines)
                    }
                } catch {
                    consecutiveErrors += 1
                    let backoffMs = min(300 * (1 << consecutiveErrors), 5000)
                    try? await Task.sleep(for: .milliseconds(backoffMs))
                    if consecutiveErrors >= 10 {
                        self.onError?("Lost connection to server")
                        break
                    }
                }
            }
        }
    }

    /// Stop polling and kill server process
    func terminate() async {
        pollTask?.cancel()
        pollTask = nil

        do {
            if let pid {
                // Kill the process tree: children first, then parent
                try await ssh.executeCommand("pkill -P \(pid) 2>/dev/null; kill \(pid) 2>/dev/null; true")
            }
            try await ssh.executeCommand("rm -f \(inFile) \(outFile)")
        } catch {
            buttLog.debug("Cleanup error (expected if SSH disconnected): \(error)")
        }
        buttLog.info("Terminated process \(processId)")
    }

    deinit {
        pollTask?.cancel()
    }
}
