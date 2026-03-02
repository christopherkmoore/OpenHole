import SwiftUI

struct ToolCallCard: View {
    let toolCall: ToolCall
    @EnvironmentObject var session: ClaudeSession
    @EnvironmentObject var settings: AppSettings
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolIcon)
                        .font(.caption)
                        .foregroundStyle(toolColor)

                    Text(toolCall.name)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)

                    Spacer()

                    switch toolCall.status {
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .denied:
                        Image(systemName: "xmark.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    case .running:
                        ProgressView()
                            .scaleEffect(0.6)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Approve button for denied tools
            if toolCall.status == .denied {
                Divider()
                Button {
                    Task { await session.approveTools([toolCall.name], settings: settings) }
                } label: {
                    Label("Approve \(toolCall.name)", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    // Input
                    Text("Input")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Text(toolCall.input)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(20)

                    // Result
                    if let result = toolCall.result {
                        Divider()
                        Text("Result")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(result)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(30)
                    }
                }
                .padding(12)
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
        )
    }

    private var toolIcon: String { ToolMeta.icon(for: toolCall.name) }
    private var toolColor: Color { ToolMeta.color(for: toolCall.name) }
}


// MARK: - Diff Expansion State

struct ExpandedDiff: Identifiable, Equatable {
    let id: String
    let fileName: String
    let filePath: String?
    let toolName: String
    let lines: [DiffLineItem]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
class DiffOverlayState: ObservableObject {
    @Published var expandedDiff: ExpandedDiff?
    var namespace: Namespace.ID?

    func expand(_ diff: ExpandedDiff) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            expandedDiff = diff
        }
    }

    func collapse() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            expandedDiff = nil
        }
    }
}

// MARK: - Optional Matched Geometry

private struct OptionalMatchedGeometry: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let ns = namespace {
            content.matchedGeometryEffect(id: id, in: ns)
        } else {
            content
        }
    }
}

// MARK: - Fullscreen Diff Overlay

struct FullscreenDiffOverlay: View {
    let diff: ExpandedDiff
    let namespace: Namespace.ID?
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: diff.toolName == "Edit" ? "pencil" : "doc.text.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(diff.fileName)
                            .font(.subheadline.bold())
                        if let path = diff.filePath {
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)

                Divider()

                // Scrollable diff (both axes)
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 0) {
                                Text(line.prefix)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(line.prefixColor)
                                    .frame(width: 16, alignment: .center)
                                Text(line.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(line.backgroundColor)
                        }
                    }
                }
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .modifier(OptionalMatchedGeometry(id: diff.id, namespace: namespace))
            .ignoresSafeArea()
        }
    }
}

// MARK: - Edit/Write Card

struct EditCard: View {
    let toolCall: ToolCall
    @EnvironmentObject var session: ClaudeSession
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var diffOverlay: DiffOverlayState
    @State private var isExpanded = true
    @State private var showAll = false

    private let maxCollapsedLines = 30

    private var isExpandedFullscreen: Bool {
        diffOverlay.expandedDiff?.id == toolCall.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: toolCall.name == "Edit" ? "pencil" : "doc.text.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Text(fileName)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                switch toolCall.status {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .denied:
                    Image(systemName: "xmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .running:
                    ProgressView()
                        .scaleEffect(0.6)
                }

                Button {
                    diffOverlay.expand(ExpandedDiff(
                        id: toolCall.id,
                        fileName: fileName,
                        filePath: filePath,
                        toolName: toolCall.name,
                        lines: diffLines
                    ))
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            // Approve button for denied tools
            if toolCall.status == .denied {
                Divider()
                Button {
                    Task { await session.approveTools([toolCall.name], settings: settings) }
                } label: {
                    Label("Approve \(toolCall.name)", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }

            // Diff body
            if isExpanded {
                Divider()
                diffBody
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
        )
        .modifier(OptionalMatchedGeometry(id: toolCall.id, namespace: diffOverlay.namespace))
        .opacity(isExpandedFullscreen ? 0 : 1)
    }

    // MARK: - Diff Body

    @ViewBuilder
    private var diffBody: some View {
        let lines = diffLines
        let truncated = !showAll && lines.count > maxCollapsedLines
        let visible = truncated ? Array(lines.prefix(maxCollapsedLines)) : lines

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                diffLineView(line)
            }

            if truncated {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAll = true
                    }
                } label: {
                    Text("Show all (\(lines.count) lines)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func diffLineView(_ line: DiffLineItem) -> some View {
        HStack(spacing: 0) {
            Text(line.prefix)
                .font(.caption.monospaced())
                .foregroundStyle(line.prefixColor)
                .frame(width: 16, alignment: .center)

            Text(line.text)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(line.backgroundColor)
    }

    // MARK: - Field Extraction

    private var filePath: String? {
        guard case .object(let obj) = toolCall.inputValue,
              case .string(let path) = obj["file_path"] else { return nil }
        return path
    }

    private var fileName: String {
        guard let path = filePath else { return toolCall.name }
        return (path as NSString).lastPathComponent
    }

    private var oldString: String? {
        guard case .object(let obj) = toolCall.inputValue,
              case .string(let s) = obj["old_string"] else { return nil }
        return s
    }

    private var newString: String? {
        guard case .object(let obj) = toolCall.inputValue,
              case .string(let s) = obj["new_string"] else { return nil }
        return s
    }

    private var writeContent: String? {
        guard case .object(let obj) = toolCall.inputValue,
              case .string(let s) = obj["content"] else { return nil }
        return s
    }

    // MARK: - Diff Lines

    private var diffLines: [DiffLineItem] {
        if toolCall.name == "Edit" {
            return editDiffLines
        } else {
            return writeDiffLines
        }
    }

    private var editDiffLines: [DiffLineItem] {
        var lines: [DiffLineItem] = []
        if let old = oldString {
            for line in old.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(DiffLineItem(prefix: "-", text: String(line), kind: .removed))
            }
        }
        if let new = newString {
            for line in new.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(DiffLineItem(prefix: "+", text: String(line), kind: .added))
            }
        }
        return lines
    }

    private var writeDiffLines: [DiffLineItem] {
        guard let content = writeContent else { return [] }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            DiffLineItem(prefix: "+", text: String(line), kind: .added)
        }
    }
}

// MARK: - Diff Line Model

struct DiffLineItem {
    let prefix: String
    let text: String
    let kind: Kind

    enum Kind {
        case added, removed
    }

    var prefixColor: Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        }
    }

    var backgroundColor: Color {
        switch kind {
        case .added: return Color.green.opacity(0.1)
        case .removed: return Color.red.opacity(0.1)
        }
    }
}

// MARK: - Question Card (AskUserQuestion)

struct ParsedQuestion {
    let question: String
    let header: String?
    let multiSelect: Bool
    let options: [(label: String, description: String?)]
}

struct QuestionCard: View {
    let toolCall: ToolCall
    @EnvironmentObject var session: ClaudeSession
    @State private var selections: [String: Set<String>] = [:]  // question → selected labels
    @State private var otherText = ""
    @State private var showOtherInput = false
    @FocusState private var otherFocused: Bool

    private var isInteractive: Bool { toolCall.status == .running }

    private var parsedQuestions: [ParsedQuestion]? {
        guard case .object(let top) = toolCall.inputValue,
              case .array(let questions) = top["questions"] else { return nil }
        let result = questions.compactMap { qVal -> ParsedQuestion? in
            guard case .object(let obj) = qVal,
                  case .string(let q) = obj["question"],
                  case .array(let opts) = obj["options"] else { return nil }
            let header: String? = {
                if case .string(let h) = obj["header"] { return h }
                return nil
            }()
            let multiSelect: Bool = {
                if case .bool(let m) = obj["multiSelect"] { return m }
                return false
            }()
            let options = opts.compactMap { optVal -> (label: String, description: String?)? in
                guard case .object(let opt) = optVal,
                      case .string(let label) = opt["label"] else { return nil }
                let desc: String? = {
                    if case .string(let d) = opt["description"] { return d }
                    return nil
                }()
                return (label, desc)
            }
            return options.isEmpty ? nil : ParsedQuestion(question: q, header: header, multiSelect: multiSelect, options: options)
        }
        return result.isEmpty ? nil : result
    }

    private var isSingleSimple: Bool {
        guard let qs = parsedQuestions, qs.count == 1, !qs[0].multiSelect else { return false }
        return true
    }

    private var allQuestionsAnswered: Bool {
        guard let qs = parsedQuestions else { return false }
        return qs.allSatisfy { q in
            !(selections[q.question] ?? []).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let questions = parsedQuestions {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text(isInteractive ? "Claude is asking" : "Claude asked")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(questions.enumerated()), id: \.offset) { idx, pq in
                    questionView(pq, questionIndex: idx, totalQuestions: questions.count)
                }

                // Submit button for multi-question or multiSelect
                if isInteractive && !isSingleSimple {
                    Button {
                        submitAll()
                    } label: {
                        Text("Submit")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(allQuestionsAnswered ? Color.blue : Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!allQuestionsAnswered)
                }
            } else {
                Text(toolCall.input)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func questionView(_ pq: ParsedQuestion, questionIndex: Int, totalQuestions: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = pq.header {
                Text(header)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            Text(pq.question)
                .font(.subheadline)
                .foregroundStyle(.primary)

            VStack(spacing: 6) {
                ForEach(Array(pq.options.enumerated()), id: \.offset) { _, option in
                    optionButton(option, question: pq, totalQuestions: totalQuestions)
                }

                // "Other..." free-text for single-question single-select only
                if isInteractive && isSingleSimple {
                    if showOtherInput {
                        HStack(spacing: 8) {
                            TextField("Type your answer...", text: $otherText)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                                .focused($otherFocused)
                                .onSubmit { submitOther(for: pq.question) }
                            Button { submitOther(for: pq.question) } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(otherText.isEmpty ? Color.gray : Color.blue)
                            }
                            .disabled(otherText.isEmpty)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue, lineWidth: 1))
                    } else {
                        Button {
                            showOtherInput = true
                            otherFocused = true
                        } label: {
                            Text("Other...")
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.systemGray4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        if questionIndex < totalQuestions - 1 {
            Divider().padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func optionButton(_ option: (label: String, description: String?), question: ParsedQuestion, totalQuestions: Int) -> some View {
        let label = option.label
        let selected = isSelected(label, for: question.question)
        let answered = answeredValue(for: question.question)

        Button {
            guard isInteractive else { return }
            if question.multiSelect {
                var current = selections[question.question] ?? []
                if current.contains(label) { current.remove(label) } else { current.insert(label) }
                selections[question.question] = current
            } else if isSingleSimple {
                // Single question, single-select: send immediately
                Task { await session.answerQuestion(toolCallId: toolCall.id, answers: [question.question: label]) }
            } else {
                selections[question.question] = [label]
            }
        } label: {
            HStack(spacing: 8) {
                // Selection indicator
                if question.multiSelect {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.subheadline)
                        .foregroundStyle(selected ? .blue : .secondary)
                } else if !isSingleSimple {
                    Image(systemName: selected ? "circle.inset.filled" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(selected ? .blue : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(optionLabelColor(label, question: question.question))
                    if let desc = option.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Checkmark for selected answer in read-only mode
                if !isInteractive && answered == label {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(optionBgColor(label, question: question.question))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(optionBorderColor(label, question: question.question), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .opacity(!isInteractive && answered != nil && answered != label ? 0.5 : 1.0)
    }

    // MARK: - Actions

    private func submitOther(for question: String) {
        let text = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { await session.answerQuestion(toolCallId: toolCall.id, answers: [question: text]) }
    }

    private func submitAll() {
        guard let qs = parsedQuestions else { return }
        var answers: [String: String] = [:]
        for q in qs {
            let sel = selections[q.question] ?? []
            answers[q.question] = sel.sorted().joined(separator: ", ")
        }
        Task { await session.answerQuestion(toolCallId: toolCall.id, answers: answers) }
    }

    // MARK: - State Helpers

    private func isSelected(_ label: String, for question: String) -> Bool {
        selections[question]?.contains(label) ?? false
    }

    private func answeredValue(for question: String) -> String? {
        toolCall.selectedAnswers[question]
    }

    private func optionBgColor(_ label: String, question: String) -> Color {
        if !isInteractive {
            let ans = answeredValue(for: question)
            return ans == label ? Color.blue.opacity(0.12) : Color(.systemGray5)
        }
        return isSelected(label, for: question) ? Color.blue.opacity(0.12) : Color(.systemGray5)
    }

    private func optionLabelColor(_ label: String, question: String) -> Color {
        if !isInteractive {
            let ans = answeredValue(for: question)
            return ans == label ? .blue : .primary
        }
        return isSelected(label, for: question) ? .blue : .primary
    }

    private func optionBorderColor(_ label: String, question: String) -> Color {
        if !isInteractive {
            let ans = answeredValue(for: question)
            return ans == label ? .blue : Color(.systemGray4)
        }
        return isSelected(label, for: question) ? .blue : Color(.systemGray4)
    }
}
