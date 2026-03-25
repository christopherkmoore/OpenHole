import SwiftUI
import MarkdownUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            // Text content
            if !message.text.isEmpty {
                HStack {
                    if message.role == .user { Spacer(minLength: 60) }

                    Markdown(message.text)
                        .markdownTheme(.basic)
                        .foregroundStyle(message.role == .user ? .white : .primary)
                        .padding(12)
                        .background(bubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    if message.role == .assistant { Spacer(minLength: 60) }
                }
            }

            // Tool calls
            ForEach(message.toolCalls) { toolCall in
                if toolCall.name == "AskUserQuestion" && toolCall.status != .denied {
                    QuestionCard(toolCall: toolCall)
                } else if toolCall.name == "Edit" || toolCall.name == "Write" {
                    EditCard(toolCall: toolCall)
                } else {
                    ToolCallCard(toolCall: toolCall)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var bubbleBackground: Color {
        message.role == .user ? .blue : Color(.systemGray6)
    }
}

struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack {
            Markdown(text)
                .markdownTheme(.basic)
                .padding(12)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    TypingIndicator()
                        .offset(x: -8, y: -8)
                }
            Spacer(minLength: 60)
        }
    }
}

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(dotOpacity(for: i))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                phase = 1.0
            }
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        let delay = Double(index) * 0.2
        return 0.3 + 0.7 * max(0, sin((phase - delay) * .pi))
    }
}
