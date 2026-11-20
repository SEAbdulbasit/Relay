import CryptoKit
import Dispatch
import Foundation

/// Optional explicit Responses API route. Uses endpoint-scoped Keychain
/// credentials only; never reads ChatGPT/Codex CLI auth, OpenRouter keys, or env vars.
actor CustomResponsesClient {
    typealias Response = LMStudioClient.Response
    typealias Transport = LMStudioClient.Transport

    private static let keylessDigest = Data("keyless-loopback".utf8)

    private let executorQueue = DispatchSerialQueue(label: "relay.custom-responses-client")
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }
    private let transport: Transport
    private let credentials: CustomResponsesCredentials
    private var revision: UInt64 = 0
    private var operationID: UUID?
    private var cancelOperation: (@Sendable () -> Void)?
    private var drainOperation: Task<Void, Never>?
    private var verifiedVisionChoice: CustomResponsesConfiguration?
    private var verifiedVisionKeyDigest: Data?

    init(
        transport: Transport = CustomResponsesHTTPTransport.make(),
        credentials: CustomResponsesCredentials = CustomResponsesCredentials()
    ) {
        self.transport = transport
        self.credentials = credentials
    }

    func invalidate() {
        if revision < .max { revision += 1 }
        verifiedVisionChoice = nil
        verifiedVisionKeyDigest = nil
        cancelOperation?()
    }

    func drain() async {
        await drainOperation?.value
    }

    func replaceKey(_ data: Data?, for endpoint: CustomResponsesEndpoint) throws {
        // Store owns/cancels the exact save task synchronously on selection or
        // Stop. A job queued on this actor must recheck before custody starts.
        try Task.checkCancellation()
        invalidate()
        try Task.checkCancellation()
        if let data {
            try credentials.saveKey(data, for: endpoint)
        } else {
            try credentials.clearKey(for: endpoint)
        }
    }

    func visionIsVerified(for configuration: CustomResponsesConfiguration) -> Bool {
        guard configuration.isConfigured,
              let endpoint = configuration.endpoint,
              let (_, digest) = try? resolvedKeyAndDigest(for: endpoint, requiresAPIKey: configuration.effectiveRequiresAPIKey) else {
            return false
        }
        return verifiedVisionChoice == configuration && verifiedVisionKeyDigest == digest
    }

    private func resolvedKeyAndDigest(
        for endpoint: CustomResponsesEndpoint,
        requiresAPIKey: Bool
    ) throws -> (key: Data?, digest: Data) {
        if let key = try credentials.resolvedKey(for: endpoint, requiresAPIKey: requiresAPIKey) {
            return (key, Data(SHA256.hash(data: key)))
        }
        return (nil, Self.keylessDigest)
    }

    private func validate(
        _ expected: UInt64,
        endpoint: CustomResponsesEndpoint,
        requiresAPIKey: Bool,
        keyDigest: Data
    ) throws {
        try Task.checkCancellation()
        guard revision == expected, revision < .max,
              (try? resolvedKeyAndDigest(for: endpoint, requiresAPIKey: requiresAPIKey).digest) == keyDigest else {
            throw CancellationError()
        }
    }

    func listModels(configuration: CustomResponsesConfiguration) async throws -> [String] {
        guard let endpoint = configuration.endpoint else {
            throw CustomResponsesFailure.invalidBaseURL
        }
        guard endpoint.isLoopback || configuration.uploadsApproved else {
            throw CustomResponsesFailure.uploadsNotApproved
        }
        let expected = revision
        let requiresKey = configuration.effectiveRequiresAPIKey
        let (key, digest) = try resolvedKeyAndDigest(for: endpoint, requiresAPIKey: requiresKey)
        let request = try CustomResponsesHTTPTransport.makeRequest(
            url: endpoint.modelsURL,
            method: "GET",
            apiKey: key,
            endpoint: endpoint,
            requiresAPIKey: requiresKey
        )
        let transport = self.transport
        do {
            let names: [String] = try await perform {
                try await self.validate(expected, endpoint: endpoint, requiresAPIKey: requiresKey, keyDigest: digest)
                let response = try await transport.open(request)
                defer { response.cancel() }
                try Self.validateResponse(response, request: request)
                let bytes = try await Self.read(response.body, maximum: LMStudioWireCodec.maximumOutputBytes)
                return try CustomResponsesWireCodec.models(from: bytes)
            }
            try validate(expected, endpoint: endpoint, requiresAPIKey: requiresKey, keyDigest: digest)
            return names
        } catch {
            try validate(expected, endpoint: endpoint, requiresAPIKey: requiresKey, keyDigest: digest)
            throw Self.closed(error)
        }
    }

    func complete(
        messages: [ModelMessage],
        tools: [ToolDefinition],
        namespaces: [CustomResponsesNamespaceDefinition] = [],
        configuration: CustomResponsesConfiguration,
        vision: LMStudioVisionAttachment? = nil,
        sourceAuthorization: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws -> ModelReply {
        guard let endpoint = configuration.endpoint else {
            throw CustomResponsesFailure.invalidBaseURL
        }
        _ = try CustomResponsesConfiguration.validatedModelID(configuration.modelID)
        _ = try CustomResponsesConfiguration.validatedReasoningEffort(configuration.reasoningEffort)
        guard endpoint.isLoopback || configuration.uploadsApproved else {
            throw CustomResponsesFailure.uploadsNotApproved
        }
        if vision != nil, !visionIsVerified(for: configuration) {
            throw CustomResponsesFailure.visionUnsupported
        }
        do {
            return try await completion(
                messages: messages,
                tools: tools,
                namespaces: namespaces,
                configuration: configuration,
                endpoint: endpoint,
                vision: vision,
                sourceAuthorization: sourceAuthorization
            )
        } catch {
            if vision != nil {
                verifiedVisionChoice = nil
                verifiedVisionKeyDigest = nil
            }
            try await sourceAuthorization?()
            throw Self.closed(error)
        }
    }

    func verifyVision(
        configuration: CustomResponsesConfiguration,
        syntheticImage: LMStudioVisionAttachment,
        expectedMarker: String
    ) async throws {
        guard operationID == nil else { throw LocalInferenceFailure.busy }
        invalidate()
        guard let endpoint = configuration.endpoint else {
            throw CustomResponsesFailure.invalidBaseURL
        }
        _ = try CustomResponsesConfiguration.validatedModelID(configuration.modelID)
        _ = try CustomResponsesConfiguration.validatedReasoningEffort(configuration.reasoningEffort)
        guard endpoint.isLoopback || configuration.uploadsApproved else {
            throw CustomResponsesFailure.uploadsNotApproved
        }
        guard expectedMarker.range(of: #"^[A-Z0-9]{4,12}$"#, options: .regularExpression) != nil else {
            throw CustomResponsesFailure.visionUnsupported
        }
        let expected = revision
        let requiresKey = configuration.effectiveRequiresAPIKey
        let (_, digest) = try resolvedKeyAndDigest(for: endpoint, requiresAPIKey: requiresKey)
        let reply: ModelReply
        do {
            reply = try await completion(
                messages: [
                    .init(role: "system", content: "Read only the synthetic image marker. No tools or actions are available."),
                    .init(role: "user", content: "Reply with only the centered marker characters.")
                ],
                tools: [],
                namespaces: [],
                configuration: configuration,
                endpoint: endpoint,
                vision: syntheticImage,
                sourceAuthorization: nil
            )
        } catch let error as CustomResponsesFailure where error == .unauthorized || error == .rateLimited || error == .responseTooLarge {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CustomResponsesFailure.visionUnsupported
        }
        try await syntheticImage.validate()
        try validate(expected, endpoint: endpoint, requiresAPIKey: requiresKey, keyDigest: digest)
        guard reply.toolCalls.isEmpty,
              reply.content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == expectedMarker else {
            throw CustomResponsesFailure.visionUnsupported
        }
        verifiedVisionChoice = configuration
        verifiedVisionKeyDigest = digest
    }

    private func completion(
        messages: [ModelMessage],
        tools: [ToolDefinition],
        namespaces: [CustomResponsesNamespaceDefinition],
        configuration: CustomResponsesConfiguration,
        endpoint: CustomResponsesEndpoint,
        vision: LMStudioVisionAttachment?,
        sourceAuthorization: (@MainActor @Sendable () async throws -> Void)?
    ) async throws -> ModelReply {
        let expected = revision
        let requiresKey = configuration.effectiveRequiresAPIKey
        try await sourceAuthorization?()
        try await vision?.validate()
        let (key, digest) = try resolvedKeyAndDigest(for: endpoint, requiresAPIKey: requiresKey)
        let (body, mapping) = try CustomResponsesWireCodec.request(
            model: configuration.modelID,
            reasoningEffort: configuration.reasoningEffort,
            messages: messages,
            tools: tools,
            namespaces: namespaces,
            image: vision?.jpeg,
            imageAnnotation: vision?.annotation,
            stream: true
        )
        let prepared = try CustomResponsesHTTPTransport.makeRequest(
            url: endpoint.responsesURL,
            method: "POST",
            body: body,
            apiKey: key,
            endpoint: endpoint,
            requiresAPIKey: requiresKey
        )
        let transport = self.transport
        let names = Set(tools.map(\.name))
        let prior = CustomResponsesWireCodec.priorToolCallIDs(in: messages)
        do {
            let reply = try await perform {
                try await vision?.validate()
                try await sourceAuthorization?()
                try await self.validate(expected, endpoint: endpoint, requiresAPIKey: requiresKey, keyDigest: digest)
                let response = try await transport.open(prepared)
                defer { response.cancel() }
                try Self.validateResponse(response, request: prepared)
                if response.contentType.lowercased().hasPrefix("text/event-stream") {
                    var decoder = CustomResponsesSSEDecoder(
                        availableTools: names,
                        priorCallIDs: prior,
                        mapping: mapping
                    )
                    for try await chunk in response.body {
                        try Task.checkCancellation()
                        try decoder.append(chunk)
                        if decoder.sawCompleted {
                            return try decoder.finish()
                        }
                    }
                    return try decoder.finish()
                }
                guard response.contentType.lowercased().hasPrefix("application/json") else {
                    throw CustomResponsesFailure.invalidResponse
                }
                let bytes = try await Self.read(response.body, maximum: LMStudioWireCodec.maximumOutputBytes)
                return try CustomResponsesWireCodec.reply(
                    from: bytes,
                    availableTools: names,
                    priorCallIDs: prior,
                    mapping: mapping
                )
            }
            try await vision?.validate()
            try await sourceAuthorization?()
            try validate(expected, endpoint: endpoint, requiresAPIKey: requiresKey, keyDigest: digest)
            return reply
        } catch {
            try await vision?.validate()
            try await sourceAuthorization?()
            try validate(expected, endpoint: endpoint, requiresAPIKey: requiresKey, keyDigest: digest)
            throw Self.closed(error)
        }
    }

    private func perform<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard operationID == nil else { throw LocalInferenceFailure.busy }
        try Task.checkCancellation()
        guard revision < .max else { throw CancellationError() }
        let id = UUID(), expected = revision, task = Task { try await body() }
        operationID = id
        cancelOperation = { task.cancel() }
        drainOperation = Task { _ = try? await task.value }
        defer {
            if operationID == id {
                operationID = nil
                cancelOperation = nil
                drainOperation = nil
            }
        }
        let result: Value
        do {
            result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            try Task.checkCancellation()
            guard revision == expected else { throw CancellationError() }
            throw Self.closed(error)
        }
        try Task.checkCancellation()
        guard revision == expected else { throw CancellationError() }
        return result
    }

    private nonisolated static func closed(_ error: any Error) -> any Error {
        if error is CancellationError || error is CustomResponsesFailure || error is LocalInferenceFailure {
            return error
        }
        if error is LMStudioFailure || error is ModelProtocolError {
            return CustomResponsesFailure.invalidResponse
        }
        return CustomResponsesFailure.requestRejected
    }

    private nonisolated static func validateResponse(_ response: Response, request: URLRequest) throws {
        guard response.url == request.url else {
            throw CustomResponsesFailure.invalidResponse
        }
        switch response.status {
        case 200...299:
            return
        case 401, 403:
            throw CustomResponsesFailure.unauthorized
        case 429:
            throw CustomResponsesFailure.rateLimited
        default:
            throw CustomResponsesFailure.requestRejected
        }
    }

    private nonisolated static func read(
        _ stream: AsyncThrowingStream<Data, any Error>,
        maximum: Int
    ) async throws -> Data {
        var result = Data()
        for try await chunk in stream {
            try Task.checkCancellation()
            guard chunk.count <= maximum - result.count else {
                throw CustomResponsesFailure.responseTooLarge
            }
            result.append(chunk)
        }
        return result
    }
}
