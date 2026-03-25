import SwiftUI
import MarkdownUI

struct ChatView: View {
    @EnvironmentObject var session: ClaudeSession
    @EnvironmentObject var connection: SSHConnectionManager
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var intentService = HoleIntentService.shared
    @State private var inputText = ""
    @State private var showVoiceInput = false
    @State private var showSessionPicker = false
    @State private var isNearBottom = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Connection status bar
                ConnectionStatusBar()

                // Messages
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(session.messages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }

                                // Streaming indicator
                                if session.state == .streaming && !session.currentStreamText.isEmpty {
                                    StreamingBubble(text: session.currentStreamText)
                                        .id("streaming")
                                }

                                // Bottom anchor for near-bottom detection
                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom")
                                    .onAppear { isNearBottom = true }
                                    .onDisappear { isNearBottom = false }
                            }
                            .padding()
                        }
                        .onTapGesture {
                            inputFocused = false
                        }
                        .onChange(of: session.messages.count) { _, _ in
                            if isNearBottom {
                                withAnimation {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: session.currentStreamText) { _, _ in
                            if isNearBottom {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: geo.size.width) { _, _ in
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }

                // Approval banner
                if !session.pendingDenials.isEmpty {
                    ApprovalBanner()
                }

                // Input bar + floating stop button
                ZStack(alignment: .top) {
                    InputBar(
                        text: $inputText,
                        isFocused: $inputFocused,
                        isEnabled: session.state == .ready,
                        showVoice: $showVoiceInput,
                        onSend: sendMessage
                    )

                    if session.state == .streaming {
                        StopButton {
                            Task { await session.interrupt() }
                        }
                        .offset(y: -44)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: session.state == .streaming)
                    }
                }
            }
            .navigationTitle("OpenHole")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await connectAndStart() }
                    } label: {
                        Image(systemName: connection.isConnected ? "wifi" : "wifi.slash")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSessionPicker = true
                    } label: {
                        Image(systemName: "list.bullet.circle")
                    }
                }
            }
            .sheet(isPresented: $showVoiceInput) {
                VoiceInputView { transcription in
                    inputText = transcription
                    showVoiceInput = false
                }
            }
            .sheet(isPresented: $showSessionPicker) {
                SessionPickerView()
            }
            .task {
                await connectAndStart()
            }
            .onChange(of: session.state) { _, newState in
                if newState == .ready, let prompt = intentService.pendingPrompt {
                    intentService.pendingPrompt = nil
                    inputText = ""
                    isNearBottom = true
                    Task { await session.sendMessage(prompt) }
                }
            }
        }
    }

    private func connectAndStart() async {
        await connection.ensureConnected(settings: settings)
        if connection.isConnected && session.state.needsRestart {
            session.attach(to: connection)
            await session.startSession(settings: settings)
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        isNearBottom = true
        Task { await session.sendMessage(text) }
    }
}

// MARK: - Connection Status Bar

struct ConnectionStatusBar: View {
    @EnvironmentObject var connection: SSHConnectionManager
    @EnvironmentObject var session: ClaudeSession
    @State private var dotOpacity: Double = 1.0

    private var isStreaming: Bool { session.state == .streaming }

    var body: some View {
        Group {
            if session.streamingStartTime != nil {
                // Use TimelineView only while streaming so the timer updates every second
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    statusContent(now: context.date)
                }
            } else {
                statusContent(now: Date())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
        .onChange(of: session.isCompacting) { _, compacting in
            if compacting {
                // Start rotating pulse for compaction
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dotOpacity = 0.3
                }
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    dotOpacity = 0.3
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    dotOpacity = 1.0
                }
            }
        }
    }

    @ViewBuilder
    private func statusContent(now: Date) -> some View {
        HStack(spacing: 8) {
            // Status dot with activity pulse
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .opacity(isStreaming ? dotOpacity : 1.0)

            // Status text
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Elapsed timer (streaming only)
            if let start = session.streamingStartTime {
                Text(formatElapsed(now.timeIntervalSince(start)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            // Token count
            if totalTokens > 0 {
                Text("▸ \(formatTokenCount(totalTokens)) out")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if !session.model.isEmpty {
                Text(session.model)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var totalTokens: Int {
        session.turnOutputTokens
    }

    private var statusColor: Color {
        if session.isCompacting { return .orange }
        switch (connection.state, session.state) {
        case (.connected, .ready): return session.isAwaitingQuestion ? .blue : .green
        case (.connected, .streaming): return .blue
        case (.connecting, _), (_, .connecting): return .orange
        case (.error, _), (_, .error): return .red
        default: return .gray
        }
    }

    private var statusText: String {
        if session.isCompacting { return "Compacting context..." }
        switch (connection.state, session.state) {
        case (.disconnected, _): return "Disconnected"
        case (.connecting, _): return "Connecting..."
        case (.error(let e), _): return "SSH: \(e)"
        case (_, .error(let e)): return "Claude: \(e)"
        case (_, .connecting): return "Starting Claude..."
        case (_, .streaming): return session.isAwaitingQuestion ? "Waiting for your answer..." : "Thinking..."
        case (_, .ready): return session.isAwaitingQuestion ? "Waiting for your answer..." : "Ready"
        case (_, .idle): return "Connected"
        }
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 10_000 { return String(format: "%.1fk", Double(count) / 1000) }
        return String(format: "%.0fk", Double(count) / 1000)
    }
}

// MARK: - Approval Banner

struct ApprovalBanner: View {
    @EnvironmentObject var session: ClaudeSession
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Tools need approval: \(toolNames)")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 12) {
                Button("Approve All") {
                    let names = Set(session.pendingDenials.map(\.toolName))
                    Task { await session.approveTools(names, settings: settings) }
                }
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)

                Button("Skip") {
                    session.denyAndContinue()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var toolNames: String {
        let names = Set(session.pendingDenials.map(\.toolName))
        return names.sorted().joined(separator: ", ")
    }
}

// MARK: - Stop Button

struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.caption2)
                Text("Stop")
                    .font(.caption.bold())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}
