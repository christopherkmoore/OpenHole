import AppIntents
import Foundation

// MARK: - Shared State

@MainActor
final class ButtIntentService: ObservableObject {
    static let shared = ButtIntentService()
    @Published var pendingPrompt: String?
    private init() {}
}

// MARK: - App Intent

struct AskButtIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Butt"
    static let description = IntentDescription("Send a prompt to Claude Code on your server.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Prompt", description: "What to ask Claude")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Butt \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ButtIntentService.shared.pendingPrompt = prompt
        return .result()
    }
}

// MARK: - Siri Phrases

struct OpenButtShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskButtIntent(),
            phrases: [
                "Ask Butt with \(.applicationName)",
                "Ask \(.applicationName)"
            ],
            shortTitle: "Ask Butt",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }
}
