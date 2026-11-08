import Foundation
@preconcurrency import LiteRTLM

/// Embedded inference only. There is no server URL, HTTP client or hosted fallback.
@MainActor
final class LocalModelClient {
    static let maximumContextBytes = 24 * 1_024
    static let maximumNativeTokens = 8_192
    static let maximumOutputTokens = 1_536
    static let maximumToolArgumentsBytes = 64 * 1_024
    static let defaultSamplerTopK = 64
    typealias RuntimeFactory = @MainActor (URL, String, URL) async throws -> any LocalModelRuntime
    private let runtimeFactory: RuntimeFactory
    private let visionRuntimeFactory: RuntimeFactory
    private enum RuntimeMode { case text, vision }
    private var runtime: (any LocalModelRuntime)?
    private var activeConversation: (any LocalConversationSession)?
    private var loadedIdentity: String?
    private var generating = false
    private var loading = false
    private var generation: Int = 0
    struct ConversationMetrics {
        var created = 0
        var lastCompletionSeconds: Double = 0
    }
    private(set) var conversationMetrics = ConversationMetrics()

    convenience init(runtimeFactory: RuntimeFactory? = nil) {
        self.init(runtimeFactory: runtimeFactory, visionRuntimeFactory: nil)
    }

    init(runtimeFactory: RuntimeFactory?, visionRuntimeFactory: RuntimeFactory?) {
        self.runtimeFactory = runtimeFactory ?? { url, backend, cache in
            try await NativeLocalModelRuntime.load(url: url, backend: backend, cache: cache)
        }
        self.visionRuntimeFactory = visionRuntimeFactory ?? { url, backend, cache in
            try await NativeLocalModelRuntime.load(url: url, backend: backend, cache: cache, vision: true)
        }
    }

    var isLoaded: Bool { runtime != nil && loadedIdentity != nil }

    static func validatedModelURL(_ configuration: ModelConfiguration) throws -> URL {
        guard configuration.backend == .liteRTLM else {
            throw RelayError.message("The selected provider is LM Studio. Use its local connection instead of opening an embedded model package.")
        }
        guard !configuration.modelPath.isEmpty, configuration.modelPath.hasPrefix("/"),
              !configuration.modelPath.contains("\0"),
              ["cpu", "gpu"].contains(configuration.computeBackend) else {
            throw RelayError.message("Import a local .litertlm Gemma model and choose CPU or GPU in Settings.")
        }
        let url = URL(fileURLWithPath: configuration.modelPath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "litertlm" else {
            throw RelayError.message("LiteRT-LM needs a .litertlm model package, not GGUF, a server address or a hosted model.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey])
        guard values.isRegularFile == true, values.isReadable == true, (values.fileSize ?? 0) > 0 else {
            throw RelayError.message("The selected model must be a readable, nonempty local .litertlm file.")
        }
        return url
    }

    func listModels(configuration: ModelConfiguration) async throws -> [String] {
        let url = try Self.validatedModelURL(configuration)
        return [url.lastPathComponent]
    }

    /// Loads the imported package into the embedded runtime. Initialization executes on Engine's actor.
    func load(configuration: ModelConfiguration) async throws {
        try await load(configuration: configuration, mode: .text)
    }

    private func load(configuration: ModelConfiguration, mode: RuntimeMode) async throws {
        try Task.checkCancellation()
        let url = try Self.validatedModelURL(configuration)
        let identity = "\(url.path)|\(configuration.computeBackend)" + (mode == .vision ? "|native-vision" : "")
        if let loadedIdentity, LMStudioProtocolID.same(loadedIdentity, identity), runtime != nil { return }
        guard !generating else { throw RelayError.message("Stop the current inference before replacing its model.") }
        guard !loading else { throw RelayError.message("A local model is already loading. Wait for initialization to finish.") }
        loading = true
        defer { loading = false }
        invalidateConversation()
        let revision = generation
        runtime = nil
        loadedIdentity = nil
        let cache = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Relay/ModelCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let candidate: any LocalModelRuntime
        let factory = mode == .vision ? visionRuntimeFactory : runtimeFactory
        do { candidate = try await factory(url, configuration.computeBackend, cache) }
        catch {
            throw RelayError.message("LiteRT-LM could not load this model on \(configuration.computeBackend.uppercased()): \(error.localizedDescription). Check the package's supported backend and available memory.")
        }
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        runtime = candidate
        loadedIdentity = identity
    }

    func unload() {
        invalidateConversation()
        runtime = nil
        loadedIdentity = nil
    }

    /// Invalidates a pending native reply immediately. Its session is retained only
    /// by the active completion until cancellation settles; every call starts fresh.
    func invalidateConversation() {
        generation += 1
        activeConversation?.cancel()
    }

    func complete(messages: [ModelMessage], tools: [ToolDefinition], configuration: ModelConfiguration,
                  sourceAuthorization: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> ModelReply {
        try await complete(messages: messages, tools: tools, configuration: configuration, visionInput: nil, sourceAuthorization: sourceAuthorization)
    }

    /// Images exist only in this local native completion. They are never added to Codable
    /// application history or passed through the hosted text-planning route.
    func complete(messages: [ModelMessage], tools: [ToolDefinition], configuration: ModelConfiguration,
                  vision: NativeVisionPlanningInput,
                  sourceAuthorization: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> ModelReply {
        try await complete(messages: messages, tools: tools, configuration: configuration, visionInput: vision, sourceAuthorization: sourceAuthorization)
    }

    private func complete(messages: [ModelMessage], tools: [ToolDefinition], configuration: ModelConfiguration,
                          visionInput: NativeVisionPlanningInput?,
                          sourceAuthorization: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> ModelReply {
        try await sourceAuthorization?()
        do {
            let reply = try await completion(messages: messages, tools: tools, configuration: configuration,
                                             visionInput: visionInput, sourceAuthorization: sourceAuthorization)
            try await sourceAuthorization?()
            return reply
        } catch { try await sourceAuthorization?(); throw error }
    }
    private func completion(messages: [ModelMessage], tools: [ToolDefinition], configuration: ModelConfiguration,
                            visionInput: NativeVisionPlanningInput?,
                            sourceAuthorization: (@MainActor @Sendable () async throws -> Void)?) async throws -> ModelReply {
        guard !generating else { throw RelayError.message("Only one model inference can run at a time.") }
        try Task.checkCancellation()
        var visionContext: (systemPrompt: String, messages: [ModelMessage])?
        var visionTools: [any LiteRTLM.Tool]?
        if let visionInput {
            try visionInput.validate()
            let context = try Self.prepareContext(messages: messages, tools: tools)
            let nativeTools = try LiteRTLM.RelayNativeTools.makeTools(named: tools.map(\.name))
            let schemas = LiteRTLM.ToolManager(tools: nativeTools).toolsJsonDescription
            try NativeVisionPlanningBudget.validate(messages: context.messages, systemPrompt: context.systemPrompt,
                tools: tools, actualNativeSchemaBytes: schemas.utf8.count, annotation: visionInput.frame.annotation)
            visionContext = context; visionTools = nativeTools
        }
        try await load(configuration: configuration, mode: visionInput == nil ? .text : .vision)
        let loadedGeneration = generation
        try Task.checkCancellation()
        try visionInput?.validate()
        try await sourceAuthorization?()
        try Task.checkCancellation()
        guard generation == loadedGeneration else { throw CancellationError() }
        guard !generating else { throw RelayError.message("Only one model inference can run at a time.") }
        guard let runtime else { throw RelayError.message("Load a local model first.") }
        let context: (systemPrompt: String, messages: [ModelMessage])
        if let visionContext { context = visionContext }
        else { context = try Self.prepareContext(messages: messages, tools: tools) }
        let nativeHistory = try context.messages.map(Self.nativeMessage)
        guard let textLast = nativeHistory.last else { throw RelayError.message("The conversation is empty.") }
        let last: LiteRTLM.Message
        let initialMessages: [LiteRTLM.Message]
        if let visionInput {
            last = LiteRTLM.Message(of: .imageData(visionInput.frame.jpeg), .text(visionInput.frame.annotation))
            initialMessages = nativeHistory
        } else { last = textLast; initialMessages = Array(nativeHistory.dropLast()) }
        let nativeTools: [any LiteRTLM.Tool]
        if let visionTools { nativeTools = visionTools }
        else { nativeTools = try LiteRTLM.RelayNativeTools.makeTools(named: tools.map(\.name)) }
        let config = LiteRTLM.ConversationConfig(
            systemMessage: LiteRTLM.Message(context.systemPrompt, role: .system),
            initialMessages: initialMessages,
            tools: nativeTools,
            samplerConfig: try LiteRTLM.SamplerConfig(topK: Self.defaultSamplerTopK, topP: 0.95, temperature: 0.15),
            thinkingConfig: LiteRTLM.ThinkingConfig(enableThinking: false),
            automaticToolCalling: false
        )
        generating = true
        let revision = generation
        defer { generating = false; activeConversation = nil }
        // Native tool IDs in the provisioned v0.18.1 model require application repair.
        // Replaying the validated application history keeps those identities coherent;
        // native KV retention is deliberately not enabled for this runtime.
        try await sourceAuthorization?()
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        let conversation = try await runtime.createConversation(config: config)
        conversationMetrics.created += 1
        do {
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
            try visionInput?.validate()
            try await sourceAuthorization?()
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
        } catch { conversation.cancel(); throw error }
        activeConversation = conversation
        let inferenceClock = ContinuousClock()
        let inferenceStarted = inferenceClock.now
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(180)) }
            catch { return }
            conversation.cancel()
        }
        defer {
            timeout.cancel()
            let elapsed = inferenceStarted.duration(to: inferenceClock.now).components
            conversationMetrics.lastCompletionSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
        }
        let reply: LiteRTLM.Message
        do {
            reply = try await withTaskCancellationHandler {
                try await conversation.send(last)
            } onCancel: {
                conversation.cancel()
            }
        } catch {
            try Task.checkCancellation()
            if inferenceStarted.duration(to: inferenceClock.now) >= .seconds(180) {
                throw RelayError.message("Local inference exceeded its three-minute budget. No returned action was dispatched.")
            }
            throw error
        }
        try Task.checkCancellation()
        guard inferenceStarted.duration(to: inferenceClock.now) < .seconds(180) else {
            throw RelayError.message("Local inference exceeded its three-minute budget. No returned action was dispatched.")
        }
        guard generation == revision else { throw CancellationError() }
        try visionInput?.validate()
        return try Self.parseReply(reply, availableTools: Set(tools.map(\.name)))
    }

    static func prepareContext(messages: [ModelMessage], tools: [ToolDefinition]) throws -> (systemPrompt: String, messages: [ModelMessage]) {
        guard !messages.isEmpty, messages.count <= 160, tools.count <= 64 else {
            throw RelayError.message("The local conversation budget was exceeded. Start a new conversation or reduce selected context.")
        }
        let toolsJSON = try JSONEncoder().encode(tools)
        let bytes = messages.reduce(0) { $0 + $1.content.utf8.count + $1.toolCalls.reduce(0) { $0 + JSONValue.object($1.arguments).pretty.utf8.count } } + toolsJSON.count
        guard bytes <= maximumContextBytes else {
            throw RelayError.message("This conversation exceeds the 24 KB local context budget. Nothing was silently discarded; start a new conversation or reduce attached context.")
        }
        guard tools.allSatisfy({ validToolName($0.name) && $0.parameters.object != nil }), Set(tools.map(\.name)).count == tools.count else {
            throw RelayError.message("Invalid or duplicated action schemas.")
        }
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let history = messages.filter { $0.role != "system" }
        guard !history.isEmpty, history.allSatisfy({ ["user", "assistant", "tool"].contains($0.role) }) else {
            throw RelayError.message("Invalid or empty conversation history.")
        }
        let toolInstructions = tools.isEmpty ? "" : """

        TOOL PROTOCOL: Call the native function with exactly the available action name and a structured JSON argument object matching its schema.
        Do not wrap actions in another function or encode the argument object as a string. Do not invent tools.
        The application validates scope, approval and results. It alone executes requested actions.
        Native action names: \(tools.map(\.name).joined(separator: ", ")). Their argument schemas are supplied once through the native tool registry.
        """
        return (system + toolInstructions, history)
    }

    private static func nativeMessage(_ message: ModelMessage) throws -> LiteRTLM.Message {
        let role: LiteRTLM.Role
        switch message.role {
        case "user": role = .user
        case "assistant": role = .model
        case "tool":
            guard let name = message.toolName, validToolName(name), let id = message.toolCallID, !id.isEmpty else {
                throw RelayError.message("A tool observation is missing its action identity.")
            }
            let observation: Any
            if let data = message.content.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { observation = json }
            else { observation = message.content }
            return LiteRTLM.Message(of: .toolResponse(name: name, response: observation, id: id), role: .tool)
        default: throw RelayError.message("Invalid model message role.")
        }
        let calls = try message.toolCalls.map { call -> LiteRTLM.ToolCall in
            guard validToolName(call.name) else { throw RelayError.message("Invalid historical tool call.") }
            let data = try JSONEncoder().encode(JSONValue.object(call.arguments))
            guard let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RelayError.message("Invalid historical action arguments.") }
            return LiteRTLM.ToolCall(name: call.name, id: call.id, arguments: arguments)
        }
        return LiteRTLM.Message(contents: [.text(message.content)], role: role, toolCalls: calls)
    }

    static func parseReply(_ message: LiteRTLM.Message, availableTools: Set<String>) throws -> ModelReply {
        guard message.toolCalls.count <= 8 else { throw ModelProtocolError.invalidAction("Too many native action requests; no action was dispatched.") }
        var calls: [ToolCall] = []
        for call in message.toolCalls {
            let diagnostic = nativeShape(call)
            guard validToolName(call.name), availableTools.contains(call.name), LiteRTLM.RelayNativeTools.supportedNames.contains(call.name) else {
                throw ModelProtocolError.invalidAction("Unavailable native action. \(diagnostic)")
            }
            guard JSONSerialization.isValidJSONObject(call.arguments),
                  let data = try? JSONSerialization.data(withJSONObject: call.arguments), data.count <= maximumToolArgumentsBytes,
                  let arguments = try? JSONDecoder().decode(JSONValue.self, from: data).object else {
                throw ModelProtocolError.invalidAction("Arguments must be a structured JSON object. \(diagnostic)")
            }
            let id = call.id.isEmpty ? "litert_\(UUID().uuidString)" : call.id
            guard id.utf8.count <= 256, !calls.contains(where: { $0.id.utf8.elementsEqual(id.utf8) }) else {
                throw ModelProtocolError.invalidAction("Invalid or duplicated native action identity. \(diagnostic)")
            }
            calls.append(ToolCall(id: id, name: call.name, arguments: arguments))
        }
        // Thought/reasoning channels are intentionally not exposed to UI or persisted.
        let text = message.toString
        guard text.utf8.count <= 128 * 1_024 else { throw RelayError.message("Gemma returned an oversized response. Check the selected package's tool-use support.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else { throw ModelProtocolError.emptyResponse }
        return ModelReply(content: text, toolCalls: calls)
    }

    /// Structural diagnostics only: never emit argument values, filenames or task content.
    private static func nativeShape(_ call: LiteRTLM.ToolCall) -> String {
        func safe(_ name: String) -> String { validToolName(name) ? name : "<invalid identifier>" }
        let keys = call.arguments.keys.sorted().map { key -> String in
            let value = call.arguments[key]
            let type: String
            switch value {
            case is String: type = "string"
            case is [String: Any]: type = "object"
            case is [Any]: type = "array"
            case is NSNull: type = "null"
            case is NSNumber: type = "number/bool"
            default: type = "other"
            }
            return "\(safe(key)):\(type)"
        }
        return "Native function=\(safe(call.name)); argument fields=[\(keys.joined(separator: ", "))]."
    }

    private static func validToolName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 80 && name.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains($0)
        }
    }
}

