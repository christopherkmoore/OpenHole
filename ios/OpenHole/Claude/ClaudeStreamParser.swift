import Foundation

class ClaudeStreamParser {
    private let decoder = JSONDecoder()

    func parseLine(_ line: String) -> ClaudeEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }

        // First decode just the type field to determine which struct to use
        guard let typeObj = try? decoder.decode(TypeOnly.self, from: data) else { return nil }

        switch typeObj.type {
        case "system":
            guard let event = try? decoder.decode(SystemEvent.self, from: data) else { return nil }
            return .system(event)
        case "assistant":
            guard let event = try? decoder.decode(AssistantEvent.self, from: data) else { return nil }
            return .assistant(event)
        case "user":
            guard let event = try? decoder.decode(UserEvent.self, from: data) else { return nil }
            return .user(event)
        case "result":
            guard let event = try? decoder.decode(ResultEvent.self, from: data) else { return nil }
            return .result(event)
        default:
            return nil
        }
    }
}

private struct TypeOnly: Decodable {
    let type: String
}
