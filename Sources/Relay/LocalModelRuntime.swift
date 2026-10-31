import Foundation
@preconcurrency import LiteRTLM

/// MainActor seams keep ownership in LocalModelClient; tests substitute an in-memory
/// session without loading weights or dispatching computer actions.
@MainActor protocol LocalModelRuntime: AnyObject {
    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession
}

@MainActor protocol LocalConversationSession: AnyObject, Sendable {
    func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message
    nonisolated func cancel()
}

@MainActor final class NativeLocalModelRuntime: LocalModelRuntime {
    private let engine: LiteRTLM.Engine
    init(engine: LiteRTLM.Engine) { self.engine = engine }

    static func engineConfiguration(url: URL, backend: String, cache: URL) throws -> LiteRTLM.EngineConfig {
        guard ["cpu", "gpu"].contains(backend) else { throw RelayError.message("Choose CPU or GPU for local inference.") }
        // Keep the engine's CPU default. GPU uses float32 activations to mitigate a
        // reported lower-precision long-context copying failure; qualification is still required.
        return try LiteRTLM.EngineConfig(modelPath: url.path, backend: backend == "gpu" ? .gpu : .cpu(), maxNumTokens: LocalModelClient.maximumNativeTokens, cacheDir: cache.path, activationDataType: backend == "gpu" ? .float32 : nil)
    }

    static func load(url: URL, backend: String, cache: URL) async throws -> any LocalModelRuntime {
        let config = try engineConfiguration(url: url, backend: backend, cache: cache)
        let engine = LiteRTLM.Engine(engineConfig: config)
        try await engine.initialize()
        return NativeLocalModelRuntime(engine: engine)
    }

    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
        NativeLocalConversationSession(conversation: try await engine.createConversation(with: config))
    }
}

@MainActor private final class NativeLocalConversationSession: LocalConversationSession {
    private nonisolated let conversation: LiteRTLM.Conversation
    init(conversation: LiteRTLM.Conversation) { self.conversation = conversation }
    func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
        // Streaming in v0.18.1 dispatches tools despite automaticToolCalling:false.
        // The non-streaming API returns the native calls without executing them.
        try await conversation.sendMessage(message, maxOutputTokens: LocalModelClient.maximumOutputTokens, thinkingConfig: LiteRTLM.ThinkingConfig(enableThinking: false))
    }
    nonisolated func cancel() { try? conversation.cancel() }
}
