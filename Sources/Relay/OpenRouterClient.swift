import CryptoKit
import Foundation

/// Optional explicit cloud route. The only credential source is this provider's
/// independent custody object; no CLI/account/environment fallback exists.
actor OpenRouterClient {
    typealias Response = LMStudioClient.Response
    typealias Transport = LMStudioClient.Transport
    nonisolated static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    nonisolated static let completionsURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let transport: Transport
    private let credentials: OpenRouterCredentials
    private var revision: UInt64 = 0
    private var operationID: UUID?
    private var cancelOperation: (@Sendable () -> Void)?
    private var drainOperation: Task<Void, Never>?
    private var verifiedVision: OpenRouterConfiguration?
    init(transport: Transport = OpenRouterHTTPTransport.make(), credentials: OpenRouterCredentials = .keychain) {
        self.transport = transport; self.credentials = credentials
    }
    func invalidate() {
        if revision < .max { revision += 1 }
        verifiedVision = nil; cancelOperation?()
    }
    func drain() async { await drainOperation?.value }
    func replaceKey(_ data: Data?) throws {
        invalidate()
        if let data { _ = try OpenRouterCredentials.validated(data) }
        do { try credentials.write(data) } catch { throw OpenRouterFailure.secureStorage }
    }
    func visionIsVerified(for configuration: OpenRouterConfiguration) -> Bool { verifiedVision == configuration }
    private func currentKey() throws -> Data {
        let data: Data?
        do { data = try credentials.read() } catch { throw OpenRouterFailure.secureStorage }
        guard let data else { throw OpenRouterFailure.keyRequired }
        _ = try OpenRouterCredentials.validated(data); return data
    }
    private func validate(_ expected: UInt64, keyDigest: Data) throws {
        try Task.checkCancellation()
        guard revision == expected, revision < .max,
              Data(SHA256.hash(data: try currentKey())) == keyDigest else { throw CancellationError() }
    }
    private func request(url: URL, method: String) throws -> (URLRequest, Data) {
        let key = try currentKey(), digest = Data(SHA256.hash(data: key))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.httpMethod = method; request.httpShouldHandleCookies = false
        request.setValue("Bearer " + (try OpenRouterCredentials.validated(key)), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        return (request, digest)
    }
    func listModels() async throws -> [String] {
        let expected = revision
        let (request, digest) = try self.request(url: Self.modelsURL, method: "GET")
        let transport = transport
        do {
            let names: [String] = try await perform { () async throws -> [String] in
                try await self.validate(expected, keyDigest: digest)
                let response = try await transport.open(request); defer { response.cancel() }
                try Self.validate(response, request: request)
                let bytes = try await Self.read(response.body, maximum: 2 * 1_024 * 1_024)
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: bytes),
                      case .array(let models) = value.object?["data"], models.count <= 2_048 else { throw OpenRouterFailure.protocolFailure }
                let names = try models.map { item in
                    guard let id = item.object?["id"]?.string else { throw OpenRouterFailure.protocolFailure }
                    try OpenRouterConfiguration.validateModel(id); return id
                }
                guard Set(names.map { LMStudioProtocolID($0) }).count == names.count else { throw OpenRouterFailure.protocolFailure }
                return names
            }
            try validate(expected, keyDigest: digest); return names
        } catch { try validate(expected, keyDigest: digest); throw Self.closed(error) }
    }
    func complete(messages: [ModelMessage], tools: [ToolDefinition], configuration: OpenRouterConfiguration,
                  vision: LMStudioVisionAttachment? = nil,
                  sourceAuthorization: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> ModelReply {
        guard configuration.isConfigured else { throw OpenRouterFailure.invalidModel }
        if vision != nil, verifiedVision != configuration { throw OpenRouterFailure.protocolFailure }
        do { return try await completion(messages: messages, tools: tools, configuration: configuration, vision: vision, sourceAuthorization: sourceAuthorization) }
        catch {
            if vision != nil { verifiedVision = nil }
            try await sourceAuthorization?(); throw Self.closed(error)
        }
    }
    func verifyVision(configuration: OpenRouterConfiguration, syntheticImage: LMStudioVisionAttachment,
                      expectedMarker: String) async throws {
        guard operationID == nil else { throw LocalInferenceFailure.busy }
        invalidate()
        guard configuration.isConfigured,
              expectedMarker.range(of: #"^[A-Z0-9]{4,12}$"#, options: .regularExpression) != nil else { throw OpenRouterFailure.protocolFailure }
        let expected = revision
        let reply = try await completion(messages: [
            .init(role: "system", content: "Read only the synthetic image marker. No tools or actions are available."),
            .init(role: "user", content: "Reply with only the centered marker characters.")
        ], tools: [], configuration: configuration, vision: syntheticImage, sourceAuthorization: nil)
        try await syntheticImage.validate(); try Task.checkCancellation()
        guard revision == expected, reply.toolCalls.isEmpty,
              reply.content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == expectedMarker else { throw OpenRouterFailure.protocolFailure }
        verifiedVision = configuration
    }
    private func completion(messages: [ModelMessage], tools: [ToolDefinition], configuration: OpenRouterConfiguration,
                            vision: LMStudioVisionAttachment?,
                            sourceAuthorization: (@MainActor @Sendable () async throws -> Void)?) async throws -> ModelReply {
        let expected = revision
        try await sourceAuthorization?(); try await vision?.validate()
        guard configuration.isConfigured else { throw OpenRouterFailure.invalidModel }
        let (template, digest) = try request(url: Self.completionsURL, method: "POST")
        var request = template
        request.httpBody = try OpenRouterWireCodec.request(modelID: configuration.modelID, messages: messages, tools: tools,
            image: vision?.jpeg, imageAnnotation: vision?.annotation)
        let prepared = request, transport = transport, names = Set(tools.map(\.name))
        let prior = Set(messages.flatMap(\.toolCalls).map { LMStudioProtocolID($0.id) })
        do {
            let reply = try await perform {
                try await vision?.validate(); try await sourceAuthorization?()
                try await self.validate(expected, keyDigest: digest)
                let response = try await transport.open(prepared); defer { response.cancel() }
                try Self.validate(response, request: prepared)
                if response.contentType.lowercased().hasPrefix("text/event-stream") {
                    var decoder = LMStudioSSEDecoder(availableTools: names, priorCallIDs: prior, acceptsTerminalUsage: true)
                    for try await chunk in response.body {
                        try Task.checkCancellation(); try decoder.feed(chunk)
                        if decoder.completed != nil { return try decoder.end() }
                    }
                    return try decoder.end()
                }
                guard response.contentType.lowercased().hasPrefix("application/json") else { throw OpenRouterFailure.protocolFailure }
                let bytes = try await Self.read(response.body, maximum: LMStudioWireCodec.maximumOutputBytes)
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { throw OpenRouterFailure.protocolFailure }
                return try LMStudioWireCodec.reply(value, availableTools: names, priorCallIDs: prior)
            }
            try await vision?.validate(); try await sourceAuthorization?(); try validate(expected, keyDigest: digest)
            return reply
        } catch {
            try await vision?.validate(); try await sourceAuthorization?(); try validate(expected, keyDigest: digest)
            throw Self.closed(error)
        }
    }
    private func perform<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard operationID == nil else { throw LocalInferenceFailure.busy }
        try Task.checkCancellation(); guard revision < .max else { throw CancellationError() }
        let id = UUID(), expected = revision, task = Task { try await body() }
        operationID = id; cancelOperation = { task.cancel() }; drainOperation = Task { _ = try? await task.value }
        defer { if operationID == id { operationID = nil; cancelOperation = nil; drainOperation = nil } }
        let result: Value
        do { result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch {
            try Task.checkCancellation(); guard revision == expected else { throw CancellationError() }
            throw Self.closed(error)
        }
        try Task.checkCancellation(); guard revision == expected else { throw CancellationError() }; return result
    }
    private nonisolated static func closed(_ error: any Error) -> any Error {
        if error is CancellationError || error is OpenRouterFailure || error is LocalInferenceFailure { return error }
        if error is LMStudioFailure || error is ModelProtocolError { return OpenRouterFailure.protocolFailure }
        return OpenRouterFailure.unavailable
    }
    private nonisolated static func validate(_ response: Response, request: URLRequest) throws {
        guard response.url == request.url else { throw OpenRouterFailure.protocolFailure }
        guard (200...299).contains(response.status) else { throw OpenRouterFailure.rejected(response.status) }
    }
    private nonisolated static func read(_ stream: AsyncThrowingStream<Data, any Error>, maximum: Int) async throws -> Data {
        var result = Data()
        for try await chunk in stream {
            try Task.checkCancellation(); guard chunk.count <= maximum - result.count else { throw OpenRouterFailure.protocolFailure }
            result.append(chunk)
        }
        return result
    }
}


nonisolated enum OpenRouterWireCodec {
    static func request(modelID: String, messages: [ModelMessage], tools: [ToolDefinition],
                        image: Data? = nil, imageAnnotation: String? = nil) throws -> Data {
        let bounded = try LMStudioWireCodec.request(modelID: modelID, messages: messages, tools: tools,
            image: image, imageAnnotation: imageAnnotation)
        guard var object = try JSONDecoder().decode(JSONValue.self, from: bounded).object else { throw OpenRouterFailure.protocolFailure }
        // No app/model retry list. Require actual support for our tool/image
        // parameters and refuse provider fallback rather than drop parameters.
        object["provider"] = .object(["require_parameters": .bool(true), "allow_fallbacks": .bool(false)])
        let result = try LMStudioWireCodec.jsonData(.object(object))
        guard result.count <= LMStudioWireCodec.maximumInputBytes + 6 * 1_024 * 1_024 else { throw OpenRouterFailure.protocolFailure }
        return result
    }
}
