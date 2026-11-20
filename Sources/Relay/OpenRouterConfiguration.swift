import Foundation

nonisolated enum OpenRouterFailure: Error, Equatable, LocalizedError {
    case keyRequired, secureStorage, invalidKey, invalidModel, unavailable, rejected(Int), protocolFailure
    var errorDescription: String? {
        switch self {
        case .keyRequired: "Save an OpenRouter API key in Settings. Relay never uses a ChatGPT token for OpenRouter."
        case .secureStorage: "The OpenRouter Keychain item could not be accessed. Unlock your Mac and try again."
        case .invalidKey: "Enter an OpenRouter API key without spaces or line breaks."
        case .invalidModel: "Enter an explicit OpenRouter model ID and approve cloud uploads in Settings."
        case .unavailable: "OpenRouter could not finish this request. No other provider was used."
        case .rejected(let status): "OpenRouter rejected the request (HTTP \(status)). Check your key, credits and selected model."
        case .protocolFailure: "OpenRouter returned an incomplete or unsupported response. No partial tool call was accepted."
        }
    }
}
/// Secrets never enter this saved configuration. Approval and key-version
/// changes participate in the same live provider identity as model selection.
nonisolated struct OpenRouterConfiguration: Codable, Equatable, Sendable {
    var modelID: String = ""
    var credentialRevision: UUID = UUID()
    var uploadsApproved = false
    init(modelID: String = "", credentialRevision: UUID = UUID(), uploadsApproved: Bool = false) throws {
        if !modelID.isEmpty { try Self.validateModel(modelID) }
        self.modelID = modelID; self.credentialRevision = credentialRevision; self.uploadsApproved = uploadsApproved
    }
    var isConfigured: Bool { uploadsApproved && (try? Self.validateModel(modelID)) != nil }
    static func validateModel(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 256,
              id.utf8.allSatisfy({ (33...126).contains($0) }), !id.contains("\\") else { throw OpenRouterFailure.invalidModel }
    }
    static func == (a: Self, b: Self) -> Bool {
        a.modelID.utf8.elementsEqual(b.modelID.utf8) && a.credentialRevision == b.credentialRevision && a.uploadsApproved == b.uploadsApproved
    }
    private enum CodingKeys: String, CodingKey { case modelID, credentialRevision, uploadsApproved }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(modelID: c.decodeIfPresent(String.self, forKey: .modelID) ?? "",
            credentialRevision: c.decodeIfPresent(UUID.self, forKey: .credentialRevision) ?? UUID(),
            uploadsApproved: c.decodeIfPresent(Bool.self, forKey: .uploadsApproved) ?? false)
    }
}
