import Foundation

/// Settings may be incomplete while the user chooses a server model. A valid
/// endpoint with no model is setup state, never an implicit embedded fallback.
nonisolated struct LMStudioConfiguration: Codable, Equatable, Sendable {
    var endpoint: LMStudioEndpoint
    var modelID: String
    init(endpoint: LMStudioEndpoint, modelID: String = "") throws {
        if !modelID.isEmpty { _ = try LMStudioSelection(endpoint: endpoint, modelID: modelID) }
        self.endpoint = endpoint; self.modelID = modelID
    }
    var selection: LMStudioSelection? { try? LMStudioSelection(endpoint: endpoint, modelID: modelID) }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.endpoint == rhs.endpoint && LMStudioProtocolID.same(lhs.modelID, rhs.modelID)
    }
    private enum CodingKeys: String, CodingKey { case endpoint, modelID }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpoint: values.decode(LMStudioEndpoint.self, forKey: .endpoint),
                      modelID: values.decodeIfPresent(String.self, forKey: .modelID) ?? "")
    }
}

nonisolated enum LocalInferenceIdentity: Equatable, Sendable {
    case embedded(path: String, compute: String)
    case lmStudio(host: LMStudioEndpoint.Host, port: Int, model: String)
    case openRouter(model: String, credentialRevision: UUID)
    case customResponses(
        canonicalOrigin: String,
        model: String,
        reasoningEffort: String,
        requiresAPIKey: Bool,
        credentialRevision: UUID
    )
    case claudeCLI(model: String, effort: String, allowUnverified: Bool)
    case codexCLI(model: String, effort: String, allowUnverified: Bool)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.embedded(a, ac), .embedded(b, bc)):
            LMStudioProtocolID.same(a, b) && LMStudioProtocolID.same(ac, bc)
        case let (.lmStudio(ah, ap, a), .lmStudio(bh, bp, b)):
            ah == bh && ap == bp && LMStudioProtocolID.same(a, b)
        case let (.openRouter(a, ak), .openRouter(b, bk)): ak == bk && LMStudioProtocolID.same(a, b)
        case let (.customResponses(ao, am, ar, akey, ak), .customResponses(bo, bm, br, bkey, bk)):
            ao == bo && LMStudioProtocolID.same(am, bm) && ar == br && akey == bkey && ak == bk
        case let (.claudeCLI(am, ae, au), .claudeCLI(bm, be, bu)):
            LMStudioProtocolID.same(am, bm) && ae == be && au == bu
        case let (.codexCLI(am, ae, au), .codexCLI(bm, be, bu)):
            LMStudioProtocolID.same(am, bm) && ae == be && au == bu
        default: false
        }
    }
}

extension ModelConfiguration {
    var effectiveClaudeCLI: ClaudeCLIConfiguration {
        claudeCLI ?? (try! ClaudeCLIConfiguration())
    }
    var effectiveCodexCLI: CodexCLIConfiguration {
        codexCLI ?? CodexCLIClient.currentDefaultConfiguration()
    }
    var inferenceIdentity: LocalInferenceIdentity? {
        switch backend {
        case .liteRTLM:
            guard modelPath.hasPrefix("/"), !modelPath.contains("\0"), ["cpu", "gpu"].contains(computeBackend) else { return nil }
            return .embedded(path: URL(fileURLWithPath: modelPath).standardizedFileURL.path, compute: computeBackend)
        case .lmStudio:
            guard let choice = lmStudio?.selection else { return nil }
            return .lmStudio(host: choice.endpoint.host, port: choice.endpoint.port, model: choice.modelID)
        case .openRouter:
            guard let choice = openRouter, choice.isConfigured else { return nil }
            return .openRouter(model: choice.modelID, credentialRevision: choice.credentialRevision)
        case .customResponses:
            guard let choice = customResponses, choice.isConfigured, let endpoint = choice.endpoint else { return nil }
            return .customResponses(
                canonicalOrigin: endpoint.canonicalOrigin,
                model: choice.modelID,
                reasoningEffort: choice.reasoningEffort,
                requiresAPIKey: choice.effectiveRequiresAPIKey,
                credentialRevision: choice.credentialRevision
            )
        case .claudeCLI:
            let choice = effectiveClaudeCLI
            guard (try? ClaudeCLIConfiguration.validateModelID(choice.effectiveModelID)) != nil else { return nil }
            return .claudeCLI(
                model: choice.effectiveModelID,
                effort: choice.reasoningEffort.rawValue,
                allowUnverified: choice.allowUnverifiedBinary
            )
        case .codexCLI:
            let choice = effectiveCodexCLI
            guard (try? CodexCLIConfiguration.validateModelID(choice.modelID)) != nil else { return nil }
            return .codexCLI(
                model: choice.modelID,
                effort: choice.reasoningEffort.rawValue,
                allowUnverified: choice.allowUnverifiedStandalone
            )
        }
    }
    var hasConfiguredInferenceModel: Bool { inferenceIdentity != nil }
    var localProviderName: String {
        switch backend {
        case .liteRTLM: "On this Mac"
        case .lmStudio: "LM Studio"
        case .openRouter: "OpenRouter"
        case .customResponses: "Responses API"
        case .claudeCLI: "Claude"
        case .codexCLI: "ChatGPT (Codex)"
        }
    }
    var usesCloudInference: Bool {
        switch backend {
        case .liteRTLM, .lmStudio: false
        case .openRouter, .claudeCLI, .codexCLI: true
        case .customResponses: customResponses?.usesCloudInference ?? true
        }
    }
    var localModelDisplayName: String {
        switch backend {
        case .liteRTLM:
            if !model.isEmpty { return model }
            return modelPath.isEmpty ? "Choose a model" : URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        case .lmStudio:
            guard let id = lmStudio?.modelID, !id.isEmpty else { return "LM Studio · choose a model" }
            return id + " · LM Studio"
        case .openRouter:
            guard let id = openRouter?.modelID, !id.isEmpty else { return "OpenRouter · choose a model" }
            return id + " · OpenRouter"
        case .customResponses:
            guard let id = customResponses?.modelID, !id.isEmpty else { return "Responses API · choose a model" }
            return id + " · Responses API"
        case .claudeCLI:
            return effectiveClaudeCLI.displayModelName + " · Claude"
        case .codexCLI:
            return effectiveCodexCLI.modelID + " · Codex"
        }
    }
    @MainActor var inferenceContextByteBudget: Int {
        switch backend {
        case .liteRTLM: LocalModelClient.maximumContextBytes
        case .claudeCLI: ClaudeCLIClient.maximumContextBytes
        case .codexCLI: CodexCLIClient.maximumContextBytes
        case .lmStudio, .openRouter, .customResponses: LMStudioWireCodec.maximumInputBytes
        }
    }
}
