import AppIntents
import Foundation

// MARK: - Shared State

@MainActor
final class HoleIntentService: ObservableObject {
    static let shared = HoleIntentService()
    @Published var pendingPrompt: String?
    private init() {}
}

// MARK: - App Intent

struct AskHoleIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Hole"
    static let description = IntentDescription("Send a prompt to Claude Code on your server.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Prompt", description: "What to ask Claude")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Hole \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        HoleIntentService.shared.pendingPrompt = prompt
        return .result()
    }
}

// MARK: - Siri Phrases

struct OpenHoleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHoleIntent(),
            phrases: [
                "Ask Hole with \(.applicationName)",
                "Ask \(.applicationName)"
            ],
            shortTitle: "Ask Hole",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }
}
