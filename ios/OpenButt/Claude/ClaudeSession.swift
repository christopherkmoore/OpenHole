import Foundation
import Combine

enum SessionState: Equatable {
    case idle
    case connecting
    case ready
    case streaming
    case error(String)

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var needsRestart: Bool {
        switch self {
        case .idle, .error: return true
        default: return false
        }
    }
}

@MainActor
class ClaudeSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var state: SessionState = .idle
    @Published var sessionId: String?
    @Published var currentStreamText: String = ""
    @Published var availableTools: [String] = []
    @Published var model: String = ""
    @Published var lastResult: ResultEvent?
    @Published var pendingDenials: [PermissionDenial] = []

    // Streaming activity tracking
    @Published var streamingStartTime: Date?
    @Published var turnInputTokens: Int = 0
    @Published var turnOutputTokens: Int = 0
    @Published var lastEventTime: Date?
    @Published var isCompacting: Bool = false
    private var hasSeenSystemEventThisTurn: Bool = false

    private let parser = ClaudeStreamParser()
    private var sshManager: SSHConnectionManager?
    private weak var settings: AppSettings?
    private var process: ClaudeProcess?
    private var lastUserMessageText: String?

    func attach(to sshManager: SSHConnectionManager) {
        self.sshManager = sshManager
    }

    // MARK: - Session Lifecycle

    func startSession(settings: AppSettings) async {
        self.settings = settings
        guard let ssh = sshManager, ssh.state == .connected else {
            buttLog.error("[session] startSession: SSH not connected")
            state = .error("SSH not connected")
            return
        }

        do {
            try await OAuthManager.ensureValidToken(ssh: ssh)
        } catch {
            buttLog.error("[session] OAuth token refresh failed: \(error)")
            state = .error("OAuth token refresh failed: \(error.localizedDescription)")
            return
        }

        if let savedId = settings.activeSessionId {
            buttLog.info("[session] startSession: resuming saved session \(savedId)")
            await resumeExistingSession(id: savedId, settings: settings)
            return
        }

        buttLog.info("[session] startSession: creating new session")
        await createNewSession(settings: settings)
    }

    func createNewSession(settings: AppSettings) async {
        guard let ssh = sshManager, ssh.state == .connected else {
            state = .error("SSH not connected")
            return
        }

        state = .connecting
        messages = []
        sessionId = nil
        currentStreamText = ""
        pendingDenials = []

        // Clean up any stale interactive tool approvals
        settings.approvedTools.remove("AskUserQuestion")

        let command = buildCommand(settings: settings)
        buttLog.info("[session] createNewSession command: \(command)")

        do {
            let proc = setupProcess(ssh: ssh)
            process = proc
            try await proc.start(command: command, workingDirectory: settings.workingDirectory)
            buttLog.info("[session] createNewSession: process started, beginning polling")
            proc.startPolling()
            state = .ready
            buttLog.info("[session] createNewSession: state → ready")
        } catch {
            buttLog.error("[session] createNewSession failed: \(error)")
            state = .error(error.localizedDescription)
        }
    }

    func resumeExistingSession(id: String, settings: AppSettings) async {
        guard let ssh = sshManager, ssh.state == .connected else {
            state = .error("SSH not connected")
            return
        }

        state = .connecting
        sessionId = id
        messages = []
        currentStreamText = ""
        pendingDenials = []

        await loadSessionHistory(id: id)

        let command = buildCommand(settings: settings) + " --resume \(id)"
        buttLog.info("[session] resumeExistingSession command: \(command)")

        do {
            let proc = setupProcess(ssh: ssh)
            process = proc
            try await proc.start(command: command, workingDirectory: settings.workingDirectory)
            buttLog.info("[session] resumeExistingSession: process started, beginning polling")
            proc.startPolling()
            settings.activeSessionId = id
            state = .ready
            buttLog.info("[session] resumeExistingSession: state → ready, \(messages.count) history messages")
        } catch {
            buttLog.error("[session] resumeExistingSession failed: \(error)")
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Messaging

    func sendMessage(_ text: String) async {
        guard state == .ready else {
            buttLog.info("[session] sendMessage: blocked — state=\(state)")
            return
        }

        // Re-launch process if it was terminated (e.g. after interrupt)
        if process == nil, let sid = sessionId, let ssh = sshManager, let s = settings {
            buttLog.info("[session] sendMessage: re-launching process with --resume \(sid)")
            let command = buildCommand(settings: s) + " --resume \(sid)"
            do {
                let proc = setupProcess(ssh: ssh)
                process = proc
                try await proc.start(command: command, workingDirectory: s.workingDirectory)
                proc.startPolling()
            } catch {
                buttLog.error("[session] sendMessage: failed to re-launch process: \(error)")
                state = .error(error.localizedDescription)
                return
            }
        }

        guard let process else {
            buttLog.info("[session] sendMessage: blocked — no process")
            return
        }

        let userMsg = ChatMessage(role: .user, text: text)
        messages.append(userMsg)
        currentStreamText = ""
        lastUserMessageText = text
        pendingDenials = []
        beginStreaming()

        let sid = sessionId ?? "new"
        buttLog.info("[session] sendMessage: text=\(String(text.prefix(80))), sessionId=\(sid)")

        let input = ClaudeInputMessage(
            message: InputPayload(content: text),
            sessionId: sid
        )

        guard let data = try? JSONEncoder().encode(input),
              let json = String(data: data, encoding: .utf8) else {
            buttLog.error("[session] sendMessage: failed to encode JSON")
            state = .error("Failed to encode message")
            return
        }

        buttLog.debug("[session] sendMessage JSON: \(String(json.prefix(200)))")

        do {
            try await process.sendMessage(json)
            buttLog.info("[session] sendMessage: written to process input file")
        } catch {
            buttLog.error("[session] sendMessage failed: \(error)")
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Tool Approval

    func approveTools(_ toolNames: Set<String>, settings: AppSettings) async {
        settings.approvedTools.formUnion(toolNames)
        pendingDenials = []

        guard let ssh = sshManager, let sid = sessionId else { return }
        guard let retryText = lastUserMessageText else { return }

        await process?.terminate()
        process = nil

        state = .connecting

        let command = buildCommand(settings: settings) + " --resume \(sid)"

        do {
            let proc = setupProcess(ssh: ssh)
            process = proc
            try await proc.start(command: command, workingDirectory: settings.workingDirectory)
            proc.startPolling()

            // Send the retry message immediately — system event will come as part of the response
            beginStreaming()
            let input = ClaudeInputMessage(
                message: InputPayload(content: retryText),
                sessionId: sid
            )
            guard let data = try? JSONEncoder().encode(input),
                  let json = String(data: data, encoding: .utf8) else {
                state = .error("Failed to encode retry message")
                return
            }
            try await proc.sendMessage(json)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func denyAndContinue() {
        pendingDenials = []
    }

    func answerQuestion(toolCallId: String, answers: [String: String]) async {
        // Store answers and mark tool call completed
        for i in messages.indices {
            if let callIdx = messages[i].toolCalls.firstIndex(where: { $0.id == toolCallId }) {
                messages[i].toolCalls[callIdx].selectedAnswers = answers
                messages[i].toolCalls[callIdx].status = .completed
                break
            }
        }

        guard let sid = sessionId, let ssh = sshManager, let s = settings else { return }

        // Format readable text: single answer shows just the value,
        // multiple answers show "question: answer" pairs
        let answerText: String
        if answers.count == 1, let value = answers.values.first {
            answerText = value
        } else {
            answerText = answers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }

        // Add user bubble and update state to show Claude is processing
        messages.append(ChatMessage(role: .user, text: answerText))
        lastUserMessageText = answerText
        beginStreaming()

        // Re-launch process if it was terminated after the AskUserQuestion denial
        if process == nil {
            let command = buildCommand(settings: s) + " --resume \(sid)"
            do {
                let proc = setupProcess(ssh: ssh)
                process = proc
                try await proc.start(command: command, workingDirectory: s.workingDirectory)
                proc.startPolling()
            } catch {
                state = .error(error.localizedDescription)
                return
            }
        }

        guard let process else { return }

        let input = ClaudeInputMessage(message: InputPayload(content: answerText), sessionId: sid)
        guard let data = try? JSONEncoder().encode(input),
              let json = String(data: data, encoding: .utf8) else { return }
        do {
            try await process.sendMessage(json)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    var isAwaitingQuestion: Bool {
        messages.reversed().first(where: { $0.role == .assistant && !$0.toolCalls.isEmpty })?
            .toolCalls.contains { $0.name == "AskUserQuestion" && $0.status == .running } ?? false
    }

    // MARK: - Backgrounding

    func suspend() {
        process?.pausePolling()
    }

    func resume() {
        process?.resumePolling()
    }

    // MARK: - Session Control

    func stop() async {
        await process?.terminate()
        process = nil
        endStreaming()
        state = .idle
    }

    func interrupt() async {
        await process?.terminate()
        process = nil
        currentStreamText = ""
        endStreaming()
        state = .ready
        buttLog.info("[session] interrupt: process terminated, state → ready (sessionId preserved)")
    }

    func clearActiveSession(settings: AppSettings) {
        let p = process
        process = nil
        settings.activeSessionId = nil
        sessionId = nil
        messages = []
        lastResult = nil
        pendingDenials = []
        endStreaming()
        state = .idle
        Task { await p?.terminate() }
    }

    // MARK: - Streaming State Helpers

    private func beginStreaming() {
        state = .streaming
        streamingStartTime = Date()
        turnInputTokens = 0
        turnOutputTokens = 0
        isCompacting = false
        hasSeenSystemEventThisTurn = false
    }

    private func endStreaming() {
        streamingStartTime = nil
    }

    // MARK: - Private Helpers

    private func buildCommand(settings: AppSettings) -> String {
        var cmd = "claude -p"
        cmd += " --output-format stream-json"
        cmd += " --input-format stream-json"
        cmd += " --verbose"
        cmd += " --model \(shellEscape(settings.claudeModel))"
        cmd += " --permission-mode \(shellEscape(settings.permissionMode))"
        // AskUserQuestion is deliberately excluded from --allowedTools so Claude Code
        // denies it. We intercept that denial to show a QuestionCard UI. This denial-based
        // approach is the only viable mechanism in raw CLI pipe mode (`claude -p`), where
        // the Agent SDK's canUseTool callback isn't available.
        let interactiveTools: Set<String> = ["AskUserQuestion"]
        let toolsToAllow = settings.approvedTools.subtracting(interactiveTools)
        for tool in toolsToAllow.sorted() {
            cmd += " --allowedTools \(shellEscape(tool))"
        }
        return cmd
    }

    private func isAuthError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("401") || lower.contains("oauth token") ||
               lower.contains("expired") || lower.contains("unauthorized")
    }

    private func shellEscape(_ s: String) -> String {
        // Wrap in single quotes, escaping any embedded single quotes
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func setupProcess(ssh: SSHConnectionManager) -> ClaudeProcess {
        let proc = ClaudeProcess(ssh: ssh)
        proc.onLines = { [weak self] lines in
            Task { @MainActor in
                guard let self else { return }
                for line in lines {
                    self.handleLine(line)
                }
            }
        }
        proc.onError = { [weak self] error in
            Task { @MainActor in
                self?.state = .error(error)
            }
        }
        return proc
    }

    // MARK: - History Loading

    private func loadSessionHistory(id: String) async {
        guard let ssh = sshManager else { return }

        do {
            // Find the exact file first to avoid concatenating multiple matches
            let findCmd = "find ~/.claude/projects -name '\(id).jsonl' -type f 2>/dev/null | head -1"
            let filePath = try await ssh.executeCommand(findCmd)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !filePath.isEmpty else {
                buttLog.info("[history] no history file found for session \(id)")
                return
            }

            buttLog.info("[history] loading from: \(filePath)")
            let output = try await ssh.executeCommand("cat '\(filePath)'")
            let lines = output.components(separatedBy: "\n")

            var history: [ChatMessage] = []
            var pendingToolCalls: [String: Int] = [:] // toolUseId -> message index

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }

                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = obj["type"] as? String else { continue }

                guard type == "user" || type == "assistant" else { continue }

                guard let message = obj["message"] as? [String: Any] else { continue }

                if type == "user" {
                    if let text = message["content"] as? String {
                        history.append(ChatMessage(role: .user, text: text))
                    } else if let blocks = message["content"] as? [[String: Any]] {
                        for block in blocks {
                            guard let blockType = block["type"] as? String,
                                  blockType == "tool_result",
                                  let toolUseId = block["tool_use_id"] as? String,
                                  let content = block["content"] as? String else { continue }

                            if let msgIdx = pendingToolCalls[toolUseId],
                               msgIdx < history.count,
                               let callIdx = history[msgIdx].toolCalls.firstIndex(where: { $0.id == toolUseId }) {
                                history[msgIdx].toolCalls[callIdx].result = content
                                history[msgIdx].toolCalls[callIdx].status = .completed
                            }
                        }
                    }
                } else if type == "assistant" {
                    guard let blocks = message["content"] as? [[String: Any]] else { continue }

                    var textParts: [String] = []
                    var toolCalls: [ToolCall] = []

                    for block in blocks {
                        guard let blockType = block["type"] as? String else { continue }
                        switch blockType {
                        case "text":
                            if let text = block["text"] as? String {
                                textParts.append(text)
                            }
                        case "tool_use":
                            if let toolId = block["id"] as? String,
                               let name = block["name"] as? String {
                                let input: String
                                var inputValue: JSONValue? = nil
                                if let inputObj = block["input"],
                                   let inputData = try? JSONSerialization.data(withJSONObject: inputObj) {
                                    input = String(data: inputData, encoding: .utf8) ?? "{}"
                                    inputValue = try? JSONDecoder().decode(JSONValue.self, from: inputData)
                                } else {
                                    input = "{}"
                                }
                                // AskUserQuestion from history is already answered — mark completed
                                // so QuestionCard shows it as read-only, not interactive
                                var tc = ToolCall(id: toolId, name: name, input: input, inputValue: inputValue)
                                if name == "AskUserQuestion" { tc.status = .completed }
                                toolCalls.append(tc)
                            }
                        default:
                            break
                        }
                    }

                    if !textParts.isEmpty || !toolCalls.isEmpty {
                        let msg = ChatMessage(
                            role: .assistant,
                            text: textParts.joined(separator: "\n"),
                            toolCalls: toolCalls
                        )
                        let msgIdx = history.count
                        history.append(msg)

                        for tc in toolCalls {
                            pendingToolCalls[tc.id] = msgIdx
                        }
                    }
                }
            }

            // Best-effort: populate selectedAnswers for completed AskUserQuestion tool calls
            // by matching them with the next user message
            for i in history.indices {
                for j in history[i].toolCalls.indices {
                    let tc = history[i].toolCalls[j]
                    guard tc.name == "AskUserQuestion", tc.status == .completed else { continue }
                    // Find the next user message after this assistant message
                    if let nextUser = history[(i+1)...].first(where: { $0.role == .user }) {
                        // Parse the question text(s) to use as key(s)
                        if case .object(let top) = tc.inputValue,
                           case .array(let questions) = top["questions"] {
                            if questions.count == 1,
                               case .object(let qObj) = questions.first,
                               case .string(let qText) = qObj["question"] {
                                history[i].toolCalls[j].selectedAnswers = [qText: nextUser.text]
                            } else {
                                // Multi-question: store entire answer under first question
                                if case .object(let qObj) = questions.first,
                                   case .string(let qText) = qObj["question"] {
                                    history[i].toolCalls[j].selectedAnswers = [qText: nextUser.text]
                                }
                            }
                        }
                    }
                }
            }

            messages = history
            buttLog.info("Loaded \(history.count) messages from history")
        } catch {
            buttLog.error("Failed to load session history: \(error)")
        }
    }

    // MARK: - Event Handling

    private func handleLine(_ line: String) {
        buttLog.debug("[poll] raw line (\(line.count) chars): \(String(line.prefix(300)))")

        guard let event = parser.parseLine(line) else {
            buttLog.info("[poll] failed to parse line")
            return
        }

        lastEventTime = Date()

        switch event {
        case .system(let sys):
            // A second system event within a turn indicates context compaction
            if hasSeenSystemEventThisTurn {
                isCompacting = true
                buttLog.info("[event] system: mid-turn system event — likely context compaction")
            }
            hasSeenSystemEventThisTurn = true
            sessionId = sys.sessionId
            availableTools = sys.tools
            model = sys.model
            settings?.activeSessionId = sys.sessionId
            buttLog.info("[event] system: session=\(sys.sessionId), model=\(sys.model), tools=\(sys.tools.count), permissionMode=\(sys.permissionMode)")

        case .assistant(let asst):
            // Accumulate token usage
            if let usage = asst.message.usage {
                turnInputTokens += usage.inputTokens ?? 0
                turnOutputTokens += usage.outputTokens ?? 0
            }
            isCompacting = false

            var textParts: [String] = []
            var toolCalls: [ToolCall] = []

            for block in asst.message.content {
                switch block {
                case .text(let t):
                    textParts.append(t.text)
                case .toolUse(let t):
                    toolCalls.append(ToolCall(
                        id: t.id,
                        name: t.name,
                        input: t.input.prettyPrinted,
                        inputValue: t.input
                    ))
                case .toolResult, .ignored:
                    break
                }
            }

            if !textParts.isEmpty {
                let msg = ChatMessage(
                    role: .assistant,
                    text: textParts.joined(separator: "\n"),
                    toolCalls: toolCalls
                )
                messages.append(msg)
                buttLog.info("[event] assistant: \(String(msg.text.prefix(100)))")
            } else if !toolCalls.isEmpty {
                let msg = ChatMessage(
                    role: .assistant,
                    text: "",
                    toolCalls: toolCalls
                )
                messages.append(msg)
                buttLog.info("[event] tool calls: \(toolCalls.map { $0.name })")
            }

            currentStreamText = ""

        case .user(let usr):
            for block in usr.message.content {
                if case .toolResult(let result) = block {
                    if let idx = messages.lastIndex(where: { msg in
                        msg.toolCalls.contains(where: { $0.id == result.toolUseId })
                    }) {
                        if let callIdx = messages[idx].toolCalls.firstIndex(where: { $0.id == result.toolUseId }) {
                            // Don't mark AskUserQuestion as completed — it stays .running
                            // until the user answers via QuestionCard
                            if messages[idx].toolCalls[callIdx].name == "AskUserQuestion" { continue }
                            messages[idx].toolCalls[callIdx].result = result.content
                            messages[idx].toolCalls[callIdx].status = .completed
                        }
                    }
                }
            }

        case .result(let res):
            if let usage = res.usage {
                turnOutputTokens = usage.outputTokens ?? turnOutputTokens
            }
            lastResult = res
            endStreaming()

            if res.isError, isAuthError(res.result) {
                buttLog.info("[session] auth error detected, terminating process and re-reading server credentials")
                Task {
                    do {
                        await process?.terminate()
                        process = nil

                        guard let ssh = sshManager else {
                            state = .error("SSH not connected")
                            return
                        }

                        // Re-read credentials from server (kept fresh by Mac's launchd sync)
                        let creds = try await OAuthManager.readCredentials(ssh: ssh)
                        if OAuthManager.isExpired(creds) {
                            // Sync hasn't run yet — try refreshing as a last resort
                            buttLog.info("[session] server token still expired, attempting refresh")
                            try await OAuthManager.forceRefresh(ssh: ssh)
                        }

                        if let sid = sessionId, let s = settings {
                            await resumeExistingSession(id: sid, settings: s)
                        }
                    } catch {
                        state = .error("Authentication expired. Ensure your Mac is syncing credentials.")
                    }
                }
                return
            }

            if let denials = res.permissionDenials, !denials.isEmpty {
                // Separate AskUserQuestion denials (expected, shown as QuestionCards)
                // from real permission denials (shown as approval banners)
                let hasAskDenial = denials.contains { $0.toolName == "AskUserQuestion" }
                let otherDenials = denials.filter { $0.toolName != "AskUserQuestion" }

                if hasAskDenial {
                    // Claude already generated a "dismissed" follow-up message in response
                    // to the denial. Remove everything after the QuestionCard message so the
                    // user only sees the interactive question.
                    if let questionMsgIdx = messages.lastIndex(where: { msg in
                        msg.toolCalls.contains(where: { $0.name == "AskUserQuestion" && $0.status == .running })
                    }), questionMsgIdx + 1 < messages.count {
                        messages.removeSubrange((questionMsgIdx + 1)...)
                    }

                    // Terminate the process — answerQuestion() will re-launch with --resume
                    let p = process
                    process = nil
                    Task { await p?.terminate() }
                }

                pendingDenials = otherDenials
                for denial in otherDenials {
                    for i in messages.indices.reversed() {
                        if let callIdx = messages[i].toolCalls.firstIndex(where: { $0.id == denial.toolUseId }) {
                            messages[i].toolCalls[callIdx].status = .denied
                            break
                        }
                    }
                }
            }
            state = .ready
            buttLog.info("[event] result: cost=$\(res.totalCostUsd), duration=\(res.durationMs)ms, denials=\(res.permissionDenials?.count ?? 0)")
        }
    }
}

// MARK: - Chat Message Model

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let text: String
    var toolCalls: [ToolCall]
    let timestamp = Date()

    init(role: MessageRole, text: String, toolCalls: [ToolCall] = []) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
    }
}

enum MessageRole {
    case user
    case assistant
}

enum ToolCallStatus {
    case running
    case completed
    case denied
}

struct ToolCall: Identifiable {
    let id: String
    let name: String
    let input: String
    let inputValue: JSONValue?
    var result: String?
    var status: ToolCallStatus = .running
    var selectedAnswers: [String: String] = [:]  // question text → answer

    init(id: String, name: String, input: String, inputValue: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.inputValue = inputValue
    }
}
