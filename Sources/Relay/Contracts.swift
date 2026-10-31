import Foundation

nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var int: Int? { if case .number(let v) = self, v.isFinite, v >= Double(Int.min), v < Double(Int.max) { Int(v) } else { nil } }
    var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    var pretty: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; guard let d = try? encoder.encode(self) else { return "null" }; return String(decoding: d, as: UTF8.self) }
}
nonisolated struct ToolCall: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var arguments: [String: JSONValue]
    init(id: String = UUID().uuidString, name: String, arguments: [String: JSONValue]) { self.id = id; self.name = name; self.arguments = arguments }
}
nonisolated struct ToolDefinition: Codable, Sendable {
    var name: String
    var description: String
    var parameters: JSONValue
}
nonisolated struct ModelMessage: Codable, Sendable {
    var role: String
    var content: String
    var toolCalls: [ToolCall] = []
    var toolCallID: String? = nil
    var toolName: String? = nil
}
nonisolated struct ModelReply: Sendable {
    var content: String
    var toolCalls: [ToolCall]
}
nonisolated enum LocalBackend: String, Codable, CaseIterable, Sendable { case liteRTLM }
nonisolated struct ModelConfiguration: Codable, Sendable {
    var backend: LocalBackend = .liteRTLM
    var modelPath: String = ""
    var computeBackend: String = "cpu"
    var model: String = ""
}
nonisolated struct ToolResult: Codable, Sendable {
    var summary: String
    var evidence: String
    var verified: Bool
    var artifactPath: String? = nil
}
nonisolated struct ScopeGrant: Codable, Sendable, Identifiable, Hashable {
    var id: UUID = UUID()
    var path: String
    var writable: Bool = false
}
nonisolated struct ChatMessage: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var role: String
    var text: String
    var date: Date = Date()
    var artifacts: [String] = []
}
nonisolated struct ActivityEntry: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var detail: String
    var status: String
    var date: Date = Date()
}
nonisolated struct MemoryItem: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var text: String
}
nonisolated struct PendingReview: Identifiable, Sendable {
    var id: UUID = UUID()
    var call: ToolCall
    var reason: String
    var revision: Int
}
nonisolated enum RunPhase: String, Sendable { case idle, thinking, acting, awaitingReview, stopped, failed, completed, needsInput }
nonisolated enum RelayError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

nonisolated enum ModelProtocolError: LocalizedError {
    case invalidAction(String)
    var errorDescription: String? {
        switch self { case .invalidAction(let reason): "The local model returned an invalid action request: \(reason). No action from that reply was dispatched." }
    }
}
