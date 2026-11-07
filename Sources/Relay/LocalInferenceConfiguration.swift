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
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.embedded(a, ac), .embedded(b, bc)):
            LMStudioProtocolID.same(a, b) && LMStudioProtocolID.same(ac, bc)
        case let (.lmStudio(ah, ap, a), .lmStudio(bh, bp, b)):
            ah == bh && ap == bp && LMStudioProtocolID.same(a, b)
        default: false
        }
    }
}

extension ModelConfiguration {
    var inferenceIdentity: LocalInferenceIdentity? {
        switch backend {
        case .liteRTLM:
            guard modelPath.hasPrefix("/"), !modelPath.contains("\0"), ["cpu", "gpu"].contains(computeBackend) else { return nil }
            return .embedded(path: URL(fileURLWithPath: modelPath).standardizedFileURL.path, compute: computeBackend)
        case .lmStudio:
            guard let choice = lmStudio?.selection else { return nil }
            return .lmStudio(host: choice.endpoint.host, port: choice.endpoint.port, model: choice.modelID)
        }
    }
    var hasConfiguredInferenceModel: Bool { inferenceIdentity != nil }
    var localProviderName: String { backend == .liteRTLM ? "On this Mac" : "LM Studio" }
    var localModelDisplayName: String {
        switch backend {
        case .liteRTLM:
            if !model.isEmpty { return model }
            return modelPath.isEmpty ? "Choose a model" : URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        case .lmStudio:
            guard let id = lmStudio?.modelID, !id.isEmpty else { return "LM Studio · choose a model" }
            return id + " · LM Studio"
        }
    }
    @MainActor var inferenceContextByteBudget: Int {
        backend == .liteRTLM ? LocalModelClient.maximumContextBytes : LMStudioWireCodec.maximumInputBytes
    }
}
