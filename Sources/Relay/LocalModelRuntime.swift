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
    let speculativeDecodingActive: Bool
    init(engine: LiteRTLM.Engine, speculativeDecodingActive: Bool = false) {
        self.engine = engine
        self.speculativeDecodingActive = speculativeDecodingActive
    }

    static func configureExperimentalFlags(backend: String, enableSpeculativeDecoding: Bool, visionTokenBudget: Int32 = 560) {
        LiteRTLM.ExperimentalFlags.optIntoExperimentalAPIs()
        LiteRTLM.ExperimentalFlags.gpuEnableMetalResidencySet = (backend == "gpu")
        LiteRTLM.ExperimentalFlags.filterChannelContentFromKvCache = true
        LiteRTLM.ExperimentalFlags.visualTokenBudget = visionTokenBudget
        LiteRTLM.ExperimentalFlags.enableSpeculativeDecoding = enableSpeculativeDecoding
    }

    static func engineConfiguration(url: URL, backend: String, cache: URL, vision: Bool = false) throws -> LiteRTLM.EngineConfig {
        guard ["cpu", "gpu"].contains(backend) else { throw RelayError.message("Choose CPU or GPU for local inference.") }
        // Keep the engine's CPU default. GPU uses float32 activations to mitigate a
        // reported lower-precision long-context copying failure; qualification is still required.
        return try LiteRTLM.EngineConfig(modelPath: url.path, backend: backend == "gpu" ? .gpu : .cpu(),
            visionBackend: vision ? .cpu() : nil,
            maxNumTokens: LocalModelClient.maximumNativeTokens, cacheDir: cache.path,
            activationDataType: backend == "gpu" ? .float32 : nil)
    }

    static func load(url: URL, backend: String, cache: URL, vision: Bool = false) async throws -> any LocalModelRuntime {
        let config = try engineConfiguration(url: url, backend: backend, cache: cache, vision: vision)
        // LiteRT-LM 0.18.1 can crash while destroying the GPU MTP drafter.
        // Keep GPU inference available without speculative decoding.
        let useSpeculativeDecoding = backend == "cpu" && !vision
        let visionBudget: Int32
        if vision {
            let info = try LiteRTLM.ModelInfo(throwingModelPath: url.path)
            guard info.inputModalities.vision else { throw RelayError.message("This model package does not accept image input.") }
            let supported = info.visionSignatureSelection()?.filter { (1...560).contains($0) } ?? []
            let advertised = info.maxVisionTokenBudget()
            visionBudget = Int32(supported.max() ?? (advertised > 0 ? min(280, advertised) : 280))
        } else { visionBudget = 560 }
        configureExperimentalFlags(backend: backend, enableSpeculativeDecoding: useSpeculativeDecoding, visionTokenBudget: visionBudget)
        do {
            let engine = LiteRTLM.Engine(engineConfig: config)
            try await engine.initialize()
            return NativeLocalModelRuntime(engine: engine, speculativeDecodingActive: useSpeculativeDecoding)
        } catch {
            guard useSpeculativeDecoding else { throw error }
            // Fall back cleanly if the selected .litertlm package does not bundle MTP draft heads.
            configureExperimentalFlags(backend: backend, enableSpeculativeDecoding: false)
            let fallbackEngine = LiteRTLM.Engine(engineConfig: config)
            try await fallbackEngine.initialize()
            return NativeLocalModelRuntime(engine: fallbackEngine, speculativeDecodingActive: false)
        }
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
