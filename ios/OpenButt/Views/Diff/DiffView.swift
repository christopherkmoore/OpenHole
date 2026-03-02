import SwiftUI

struct DiffView: View {
    let diffs: [FileDiff]

    var body: some View {
        NavigationStack {
            List(diffs) { diff in
                Section(diff.filePath) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 4) {
            Text(linePrefix)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)

            Text(line.content)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
        }
        .listRowBackground(lineBackground)
    }

    private var linePrefix: String {
        switch line.type {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private var lineBackground: Color {
        switch line.type {
        case .added: return Color.green.opacity(0.15)
        case .removed: return Color.red.opacity(0.15)
        case .context: return .clear
        }
    }
}

// MARK: - Models

struct FileDiff: Identifiable {
    let id = UUID()
    let filePath: String
    let lines: [DiffLine]
}

struct DiffLine {
    enum LineType { case added, removed, context }
    let type: LineType
    let content: String
}

// MARK: - Diff Extraction

enum DiffExtractor {
    /// Extract diffs from Edit tool calls in the chat
    static func extractFromToolCalls(_ messages: [ChatMessage]) -> [FileDiff] {
        var diffs: [FileDiff] = []

        for message in messages {
            for toolCall in message.toolCalls {
                if toolCall.name == "Edit", let diff = parseEditToolCall(toolCall) {
                    diffs.append(diff)
                } else if toolCall.name == "Write", let diff = parseWriteToolCall(toolCall) {
                    diffs.append(diff)
                }
            }
        }

        return diffs
    }

    private static func parseEditToolCall(_ toolCall: ToolCall) -> FileDiff? {
        // The input is pretty-printed from JSONValue
        // Try to extract file_path, old_string, new_string
        let input = toolCall.input
        guard let filePath = extractField("file_path", from: input) else { return nil }
        let oldString = extractField("old_string", from: input) ?? ""
        let newString = extractField("new_string", from: input) ?? ""

        var lines: [DiffLine] = []
        for line in oldString.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(DiffLine(type: .removed, content: String(line)))
        }
        for line in newString.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(DiffLine(type: .added, content: String(line)))
        }

        return FileDiff(filePath: filePath, lines: lines)
    }

    private static func parseWriteToolCall(_ toolCall: ToolCall) -> FileDiff? {
        let input = toolCall.input
        guard let filePath = extractField("file_path", from: input) else { return nil }

        let lines = [DiffLine(type: .added, content: "[New file written]")]
        return FileDiff(filePath: filePath, lines: lines)
    }

    private static func extractField(_ field: String, from input: String) -> String? {
        // Simple extraction from the pretty-printed format "field: value"
        let pattern = "\(field): "
        guard let range = input.range(of: pattern) else { return nil }
        let rest = input[range.upperBound...]
        if let commaIndex = rest.firstIndex(of: ",") {
            return String(rest[..<commaIndex]).trimmingCharacters(in: .whitespaces)
        }
        if let braceIndex = rest.firstIndex(of: "}") {
            return String(rest[..<braceIndex]).trimmingCharacters(in: .whitespaces)
        }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse unified diff output from `git diff`
    static func parseGitDiff(_ output: String) -> [FileDiff] {
        var diffs: [FileDiff] = []
        var currentFile: String?
        var currentLines: [DiffLine] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)
            if lineStr.hasPrefix("diff --git") {
                if let file = currentFile {
                    diffs.append(FileDiff(filePath: file, lines: currentLines))
                }
                currentLines = []
                // Extract filename from "diff --git a/path b/path"
                let parts = lineStr.split(separator: " ")
                currentFile = parts.last.map { String($0).replacingOccurrences(of: "b/", with: "", options: [], range: nil) }
            } else if lineStr.hasPrefix("+++") || lineStr.hasPrefix("---") || lineStr.hasPrefix("@@") {
                continue
            } else if lineStr.hasPrefix("+") {
                currentLines.append(DiffLine(type: .added, content: String(lineStr.dropFirst())))
            } else if lineStr.hasPrefix("-") {
                currentLines.append(DiffLine(type: .removed, content: String(lineStr.dropFirst())))
            } else {
                currentLines.append(DiffLine(type: .context, content: lineStr))
            }
        }

        if let file = currentFile {
            diffs.append(FileDiff(filePath: file, lines: currentLines))
        }

        return diffs
    }
}
