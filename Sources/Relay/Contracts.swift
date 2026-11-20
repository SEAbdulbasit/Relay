import Foundation
import RelayJournal

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
    var foundationValue: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues { $0.foundationValue }
        case .array(let v): return v.map { $0.foundationValue }
        case .null: return NSNull()
        }
    }
    var pretty: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .number(let v): return String(v)
        case .string(let v):
            guard let d = try? JSONSerialization.data(withJSONObject: [v]) else { return "\"\(v)\"" }
            let s = String(decoding: d, as: UTF8.self)
            return s.hasPrefix("[") && s.hasSuffix("]") ? String(s.dropFirst().dropLast()) : s
        case .object, .array:
            guard let d = try? JSONSerialization.data(withJSONObject: foundationValue, options: [.sortedKeys]) else { return "null" }
            return String(decoding: d, as: UTF8.self)
        }
    }
}
nonisolated struct ToolCall: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var arguments: [String: JSONValue]
    init(id: String = UUID().uuidString, name: String, arguments: [String: JSONValue]) { self.id = id; self.name = name; self.arguments = arguments }
}
nonisolated struct ToolDefinition: Codable, Equatable, Sendable {
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
nonisolated enum LocalBackend: String, Codable, CaseIterable, Hashable, Sendable { case liteRTLM, lmStudio, openRouter, customResponses, claudeCLI, codexCLI }
nonisolated struct ModelConfiguration: Codable, Equatable, Sendable {
    var backend: LocalBackend = .liteRTLM
    var modelPath: String = ""
    var computeBackend: String = "cpu"
    var model: String = ""
    var lmStudio: LMStudioConfiguration? = nil
    var openRouter: OpenRouterConfiguration? = nil
    var customResponses: CustomResponsesConfiguration? = nil
    var claudeCLI: ClaudeCLIConfiguration? = nil
    var codexCLI: CodexCLIConfiguration? = nil
    init(backend: LocalBackend = .liteRTLM, modelPath: String = "", computeBackend: String = "cpu",
         model: String = "", lmStudio: LMStudioConfiguration? = nil, openRouter: OpenRouterConfiguration? = nil,
         customResponses: CustomResponsesConfiguration? = nil, claudeCLI: ClaudeCLIConfiguration? = nil,
         codexCLI: CodexCLIConfiguration? = nil) {
        self.backend = backend; self.modelPath = modelPath; self.computeBackend = computeBackend
        self.model = model; self.lmStudio = lmStudio; self.openRouter = openRouter; self.customResponses = customResponses
        self.claudeCLI = claudeCLI; self.codexCLI = codexCLI
    }
    private enum CodingKeys: String, CodingKey { case backend, modelPath, computeBackend, model, lmStudio, openRouter, customResponses, claudeCLI, codexCLI }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.backend) { backend = try values.decode(LocalBackend.self, forKey: .backend) }
        else { backend = .liteRTLM }
        modelPath = try values.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
        computeBackend = try values.decodeIfPresent(String.self, forKey: .computeBackend) ?? "cpu"
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        lmStudio = try values.decodeIfPresent(LMStudioConfiguration.self, forKey: .lmStudio)
        openRouter = try values.decodeIfPresent(OpenRouterConfiguration.self, forKey: .openRouter)
        customResponses = try values.decodeIfPresent(CustomResponsesConfiguration.self, forKey: .customResponses)
        claudeCLI = try values.decodeIfPresent(ClaudeCLIConfiguration.self, forKey: .claudeCLI)
        codexCLI = try values.decodeIfPresent(CodexCLIConfiguration.self, forKey: .codexCLI)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.backend == rhs.backend && LMStudioProtocolID.same(lhs.modelPath, rhs.modelPath)
            && LMStudioProtocolID.same(lhs.computeBackend, rhs.computeBackend)
            && LMStudioProtocolID.same(lhs.model, rhs.model) && lhs.lmStudio == rhs.lmStudio
            && lhs.openRouter == rhs.openRouter && lhs.customResponses == rhs.customResponses
            && lhs.claudeCLI == rhs.claudeCLI && lhs.codexCLI == rhs.codexCLI
    }
}
nonisolated struct ToolResult: Codable, Sendable {
    var summary: String
    var evidence: String
    var verified: Bool
    var artifactPath: String? = nil
    /// Process-only source proof from actual extraction, never serialized or restored.
    var fileExtractionReceipt: FileExtractionReceipt? = nil
    /// Actual filename-query metadata receipt, omitted from wire/history.
    var filenameSearchReceipt: FilenameSearchReceipt? = nil
    /// Actual task calendar projection; no SDK objects, wire or restored grant.
    var calendarReadReceipt: CalendarReadReceipt? = nil
    /// Actual process-only MCP response; never decoded/restored as authority.
    var mcpTaskReceipt: MCPTaskReceipt? = nil
    private enum CodingKeys: String, CodingKey { case summary, evidence, verified, artifactPath }
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
    var reply: JournalReplyReference? = nil
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
    var sharesWithOpenAI = false
    var visualPresentation: NativeVisualReviewPresentation? = nil
    var canApprove: Bool { visualPresentation?.imageIsDecodable ?? true }
    var title: String {
        if visualPresentation != nil { return "Review Mac action" }
        if sharesWithOpenAI { return "Share this excerpt with OpenAI?" }
        switch call.name {
        case "create_mail_draft": return "Create this Mail draft?"
        case "send_mail": return "Send this message?"
        case "mcp_read": return "Read from this MCP service?"
        default: return "Action approval required"
        }
    }
    var approvalTitle: String {
        if visualPresentation != nil { return "Perform action" }
        if sharesWithOpenAI { return "Share Excerpt" }
        switch call.name {
        case "create_mail_draft": return "Create draft"
        case "send_mail": return "Send message"
        case "mcp_read": return "Send this read"
        default: return "Approve Action"
        }
    }
    var hasStructuredMailReview: Bool { ["create_mail_draft", "send_mail"].contains(call.name) }
}
nonisolated enum RunPhase: String, Sendable { case idle, thinking, acting, awaitingReview, stopped, failed, completed, needsInput }
nonisolated enum RelayError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

nonisolated enum ModelProtocolError: LocalizedError {
    case invalidAction(String)
    case emptyResponse
    var errorDescription: String? {
        switch self {
        case .invalidAction(let reason): "The model returned an invalid action request: \(reason). No action from that reply was dispatched."
        case .emptyResponse: "The model returned no answer or action. No action from that reply was dispatched."
        }
    }
}
