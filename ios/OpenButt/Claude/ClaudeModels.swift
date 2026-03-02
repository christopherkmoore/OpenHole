import Foundation
import SwiftUI

// MARK: - Output Events (from Claude's stdout)

enum ClaudeEvent: Identifiable {
    case system(SystemEvent)
    case assistant(AssistantEvent)
    case user(UserEvent)
    case result(ResultEvent)

    var id: String {
        switch self {
        case .system(let e): return "system-\(e.sessionId)"
        case .assistant(let e): return e.uuid
        case .user(let e): return e.uuid
        case .result(let e): return e.uuid
        }
    }
}

struct SystemEvent: Codable {
    let type: String
    let subtype: String
    let cwd: String
    let sessionId: String
    let tools: [String]
    let model: String
    let permissionMode: String
    let claudeCodeVersion: String

    enum CodingKeys: String, CodingKey {
        case type, subtype, cwd, tools, model
        case sessionId = "session_id"
        case permissionMode
        case claudeCodeVersion = "claude_code_version"
    }
}

struct AssistantEvent: Codable {
    let type: String
    let message: AssistantMessage
    let sessionId: String
    let uuid: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type, message, uuid, error
        case sessionId = "session_id"
    }
}

struct AssistantMessage: Codable {
    let id: String
    let model: String
    let role: String
    let stopReason: String?
    let content: [ContentBlock]
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, model, role, content, usage
        case stopReason = "stop_reason"
    }
}

struct UserEvent: Codable {
    let type: String
    let message: UserMessage
    let sessionId: String
    let uuid: String

    enum CodingKeys: String, CodingKey {
        case type, message, uuid
        case sessionId = "session_id"
    }
}

struct UserMessage: Codable {
    let role: String
    let content: [ContentBlock]
}

struct ResultEvent: Codable {
    let type: String
    let subtype: String
    let isError: Bool
    let durationMs: Int
    let durationApiMs: Int
    let numTurns: Int
    let result: String
    let stopReason: String?
    let sessionId: String
    let totalCostUsd: Double
    let usage: Usage?
    let uuid: String
    let permissionDenials: [PermissionDenial]?

    enum CodingKeys: String, CodingKey {
        case type, subtype, result, usage, uuid
        case isError = "is_error"
        case durationMs = "duration_ms"
        case durationApiMs = "duration_api_ms"
        case numTurns = "num_turns"
        case stopReason = "stop_reason"
        case sessionId = "session_id"
        case totalCostUsd = "total_cost_usd"
        case permissionDenials = "permission_denials"
    }
}

struct PermissionDenial: Codable {
    let toolName: String
    let toolUseId: String
    let toolInput: JSONValue

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case toolUseId = "tool_use_id"
        case toolInput = "tool_input"
    }
}

// MARK: - Content Blocks

enum ContentBlock: Codable, Identifiable {
    case text(TextContent)
    case toolUse(ToolUseContent)
    case toolResult(ToolResultContent)
    case ignored(id: String = UUID().uuidString) // thinking, server_tool_use, etc.

    var id: String {
        switch self {
        case .text(let t): return t.id
        case .toolUse(let t): return t.id
        case .toolResult(let t): return t.toolUseId
        case .ignored(let id): return id
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try TextContent(from: decoder))
        case "tool_use":
            self = .toolUse(try ToolUseContent(from: decoder))
        case "tool_result":
            self = .toolResult(try ToolResultContent(from: decoder))
        default:
            self = .ignored()
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let t): try t.encode(to: encoder)
        case .toolUse(let t): try t.encode(to: encoder)
        case .toolResult(let t): try t.encode(to: encoder)
        case .ignored: break // nothing to encode
        }
    }
}

struct TextContent: Codable, Identifiable {
    let type: String
    let text: String
    let id = UUID().uuidString

    enum CodingKeys: String, CodingKey {
        case type, text
    }
}

struct ToolUseContent: Codable, Identifiable {
    let type: String
    let id: String
    let name: String
    let input: JSONValue

    enum CodingKeys: String, CodingKey {
        case type, id, name, input
    }
}

struct ToolResultContent: Codable, Identifiable {
    let type: String
    let toolUseId: String
    let content: String

    var id: String { toolUseId }

    enum CodingKeys: String, CodingKey {
        case type, content
        case toolUseId = "tool_use_id"
    }
}

// MARK: - Usage

struct Usage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

// MARK: - JSON Value (for arbitrary tool inputs)

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }

    var prettyPrinted: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(n))" : "\(n)"
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .object(let o):
            let pairs = o.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value.prettyPrinted)" }
            return "{\(pairs.joined(separator: ", "))}"
        case .array(let a):
            return "[\(a.map(\.prettyPrinted).joined(separator: ", "))]"
        }
    }
}

// MARK: - Input Events (to Claude's stdin)

struct ClaudeInputMessage: Encodable {
    let type: String = "user"
    let message: InputPayload
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case type, message
        case sessionId = "session_id"
    }
}

struct InputPayload: Encodable {
    let role: String = "user"
    let content: String
}

// MARK: - Tool Metadata

enum ToolMeta {
    static func icon(for name: String) -> String {
        switch name {
        case "Read": return "doc.text"
        case "Write": return "doc.text.fill"
        case "Edit": return "pencil"
        case "Bash": return "terminal"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "WebFetch": return "globe"
        case "WebSearch": return "magnifyingglass.circle"
        case "Task": return "arrow.triangle.branch"
        default: return "wrench"
        }
    }

    static func color(for name: String) -> Color {
        switch name {
        case "Read": return .blue
        case "Write", "Edit": return .orange
        case "Bash": return .purple
        case "Glob", "Grep": return .cyan
        case "WebFetch", "WebSearch": return .green
        default: return .secondary
        }
    }
}
