import CryptoKit
import Foundation

nonisolated enum CustomResponsesFailure: LocalizedError, Equatable, Sendable {
    case invalidBaseURL
    case invalidModelID
    case invalidReasoningEffort
    case invalidAPIKey
    case missingAPIKey
    case uploadsNotApproved
    case requestRejected
    case unauthorized
    case rateLimited
    case invalidResponse
    case streamDisconnected
    case emptyModelList
    case responseTooLarge
    case visionUnsupported
    case requestCancelled
    case keychainFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Enter an https:// base URL (or http://127.0.0.1:<port>/v1 or http://[::1]:<port>/v1 for a local server) without credentials, query parameters, or fragments."
        case .invalidModelID:
            "Enter a valid model ID using printable ASCII characters without spaces or backslashes."
        case .invalidReasoningEffort:
            "Choose a valid reasoning effort level (none, low, medium, high, or xhigh)."
        case .invalidAPIKey:
            "Enter a valid Responses API key without spaces or control characters."
        case .missingAPIKey:
            "Save an API key in Keychain for this Responses endpoint before using it."
        case .uploadsNotApproved:
            "Approve sending prompts and tool context to this remote Responses endpoint in Settings before using it."
        case .requestRejected:
            "The Responses endpoint rejected the request. Check the selected model ID, endpoint URL, and reasoning level."
        case .unauthorized:
            "The Responses endpoint rejected the API key or requires authentication."
        case .rateLimited:
            "The Responses endpoint rate-limited the request. Try again in a moment."
        case .invalidResponse:
            "The Responses endpoint returned a response Relay could not validate."
        case .streamDisconnected:
            "The Responses stream ended before the response completed."
        case .emptyModelList:
            "The Responses endpoint returned no usable model IDs."
        case .responseTooLarge:
            "The Responses endpoint response exceeded Relay's safety limit."
        case .visionUnsupported:
            "The selected Responses model did not pass the synthetic image check."
        case .requestCancelled:
            "The Responses request was stopped."
        case .keychainFailure:
            "Relay could not access the Keychain item for the Responses API key."
        }
    }
}

nonisolated enum CustomResponsesPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case custom
    case lmStudio
    case openRouter

    var title: String {
        switch self {
        case .custom: "Custom"
        case .lmStudio: "LM Studio (Local)"
        case .openRouter: "OpenRouter"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .custom: ""
        case .lmStudio: "http://127.0.0.1:1234/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        }
    }

    var defaultRequiresAPIKey: Bool {
        switch self {
        case .custom, .openRouter: true
        case .lmStudio: false
        }
    }

    static func matching(baseURL: String) -> CustomResponsesPreset {
        guard let endpoint = try? CustomResponsesEndpoint(parsing: baseURL) else { return .custom }
        if endpoint.canonicalOrigin == "http://127.0.0.1:1234/v1" { return .lmStudio }
        if endpoint.canonicalOrigin == "https://openrouter.ai/api/v1" { return .openRouter }
        return .custom
    }
}

nonisolated struct CustomResponsesEndpoint: Codable, Equatable, Hashable, Sendable {
    let baseURLString: String
    let canonicalOrigin: String
    let isLoopback: Bool

    init(parsing raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512,
              trimmed.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 92 }),
              let components = URLComponents(string: trimmed),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let rawScheme = components.scheme?.lowercased(),
              rawScheme == "https" || rawScheme == "http",
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty else {
            throw CustomResponsesFailure.invalidBaseURL
        }

        let isIPv4Loopback = rawHost == "127.0.0.1"
        let isIPv6Loopback = rawHost == "::1" || rawHost == "[::1]"
        let isAnyLoopbackAlias = isIPv4Loopback || isIPv6Loopback || rawHost == "localhost" || rawHost.hasSuffix(".localhost")

        if rawScheme == "http" {
            guard isIPv4Loopback || isIPv6Loopback,
                  let port = components.port, (1...65535).contains(port) else {
                throw CustomResponsesFailure.invalidBaseURL
            }
        } else {
            guard !isAnyLoopbackAlias else {
                throw CustomResponsesFailure.invalidBaseURL
            }
            if let port = components.port, !(1...65535).contains(port) {
                throw CustomResponsesFailure.invalidBaseURL
            }
        }

        var normalizedPath = components.percentEncodedPath
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        if normalizedPath.lowercased().hasSuffix("/responses") {
            normalizedPath = String(normalizedPath.dropLast("/responses".count))
            while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
                normalizedPath.removeLast()
            }
        }
        if normalizedPath.isEmpty || normalizedPath == "/" {
            normalizedPath = "/v1"
        }
        guard normalizedPath.hasPrefix("/"),
              !normalizedPath.contains("//"),
              !normalizedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              normalizedPath.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw CustomResponsesFailure.invalidBaseURL
        }

        var normalized = URLComponents()
        normalized.scheme = rawScheme
        normalized.host = isIPv6Loopback ? "::1" : rawHost
        normalized.port = components.port
        normalized.percentEncodedPath = normalizedPath
        guard let url = normalized.url else {
            throw CustomResponsesFailure.invalidBaseURL
        }

        self.baseURLString = url.absoluteString
        self.canonicalOrigin = url.absoluteString
        self.isLoopback = (rawScheme == "http") && (isIPv4Loopback || isIPv6Loopback)
    }

    var baseURL: URL {
        guard let url = URL(string: baseURLString) else {
            preconditionFailure("Validated CustomResponsesEndpoint baseURLString must produce URL")
        }
        return url
    }

    var modelsURL: URL {
        guard var components = URLComponents(string: baseURLString) else {
            preconditionFailure("Validated CustomResponsesEndpoint baseURLString must parse")
        }
        components.percentEncodedPath = components.percentEncodedPath + "/models"
        guard let url = components.url else {
            preconditionFailure("Validated CustomResponsesEndpoint modelsURL must produce URL")
        }
        return url
    }

    var responsesURL: URL {
        guard var components = URLComponents(string: baseURLString) else {
            preconditionFailure("Validated CustomResponsesEndpoint baseURLString must parse")
        }
        components.percentEncodedPath = components.percentEncodedPath + "/responses"
        guard let url = components.url else {
            preconditionFailure("Validated CustomResponsesEndpoint responsesURL must produce URL")
        }
        return url
    }

    var credentialAccount: String {
        let digest = SHA256.hash(data: Data(canonicalOrigin.utf8))
        return "custom-responses-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct CustomResponsesConfiguration: Codable, Equatable, Sendable {
    static let defaultBaseURL = "http://127.0.0.1:1234/v1"
    static let defaultReasoningEffort = "low"
    static let supportedReasoningEfforts = ["none", "low", "medium", "high", "xhigh"]

    var baseURL: String
    var modelID: String
    var reasoningEffort: String
    var requiresAPIKey: Bool
    var credentialRevision: UUID
    var uploadsApproved: Bool

    init(
        baseURL: String = Self.defaultBaseURL,
        modelID: String = "",
        reasoningEffort: String = Self.defaultReasoningEffort,
        requiresAPIKey: Bool? = nil,
        credentialRevision: UUID = UUID(),
        uploadsApproved: Bool = false
    ) throws {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedEndpoint: CustomResponsesEndpoint?
        if trimmedURL.isEmpty {
            parsedEndpoint = nil
            self.baseURL = ""
        } else {
            let endpoint = try Self.validatedEndpoint(trimmedURL)
            parsedEndpoint = endpoint
            self.baseURL = endpoint.baseURLString
        }
        self.modelID = modelID.isEmpty ? "" : try Self.validatedModelID(modelID)
        self.reasoningEffort = try Self.validatedReasoningEffort(reasoningEffort)
        if let requiresAPIKey {
            self.requiresAPIKey = parsedEndpoint?.isLoopback == false ? true : requiresAPIKey
        } else {
            self.requiresAPIKey = parsedEndpoint?.isLoopback == false
        }
        self.credentialRevision = credentialRevision
        self.uploadsApproved = uploadsApproved
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case modelID
        case reasoningEffort
        case requiresAPIKey
        case credentialRevision
        case uploadsApproved
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.defaultBaseURL
        let decodedModel = try values.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        let decodedEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? Self.defaultReasoningEffort
        let decodedRequiresKey = try values.decodeIfPresent(Bool.self, forKey: .requiresAPIKey)
        let decodedRevision = try values.decodeIfPresent(UUID.self, forKey: .credentialRevision) ?? UUID()
        let decodedUploads = try values.decodeIfPresent(Bool.self, forKey: .uploadsApproved) ?? false
        try self.init(
            baseURL: decodedURL,
            modelID: decodedModel,
            reasoningEffort: decodedEffort,
            requiresAPIKey: decodedRequiresKey,
            credentialRevision: decodedRevision,
            uploadsApproved: decodedUploads
        )
    }

    var endpoint: CustomResponsesEndpoint? {
        guard !baseURL.isEmpty else { return nil }
        return try? Self.validatedEndpoint(baseURL)
    }

    var effectiveRequiresAPIKey: Bool {
        guard let endpoint else { return true }
        return !endpoint.isLoopback || requiresAPIKey
    }

    var usesCloudInference: Bool {
        guard let endpoint else { return true }
        return !endpoint.isLoopback
    }

    var isConfigured: Bool {
        guard let endpoint,
              (try? Self.validatedModelID(modelID)) != nil,
              (try? Self.validatedReasoningEffort(reasoningEffort)) != nil else {
            return false
        }
        return endpoint.isLoopback || uploadsApproved
    }

    static func validatedEndpoint(_ raw: String) throws -> CustomResponsesEndpoint {
        try CustomResponsesEndpoint(parsing: raw)
    }

    static func validatedModelID(_ raw: String) throws -> String {
        guard (1...256).contains(raw.utf8.count),
              raw.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 && $0 != 92 }) else {
            throw CustomResponsesFailure.invalidModelID
        }
        return raw
    }

    static func validatedReasoningEffort(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = trimmed.isEmpty ? defaultReasoningEffort : trimmed
        guard (1...32).contains(candidate.utf8.count),
              candidate.utf8.allSatisfy({
                  ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45
              }) else {
            throw CustomResponsesFailure.invalidReasoningEffort
        }
        return candidate
    }

    static func == (lhs: CustomResponsesConfiguration, rhs: CustomResponsesConfiguration) -> Bool {
        lhs.baseURL == rhs.baseURL
            && LMStudioProtocolID.same(lhs.modelID, rhs.modelID)
            && lhs.reasoningEffort == rhs.reasoningEffort
            && lhs.effectiveRequiresAPIKey == rhs.effectiveRequiresAPIKey
            && lhs.credentialRevision == rhs.credentialRevision
            && lhs.uploadsApproved == rhs.uploadsApproved
    }
}

/// Pure, per-invocation Codex CLI override builder matching Sentient's `CustomProvider.providerOverrides`.
/// Never writes to `~/.codex/config.toml` or reads `~/.codex/auth.json`.
nonisolated struct CodexCustomResponsesRecipe: Equatable, Sendable {
    static let providerID = "relay_custom"
    static let envKeyName = "RELAY_CUSTOM_MODEL_API_KEY"

    let baseURL: String
    let modelID: String
    let reasoningEffort: String
    let arguments: [String]

    init(configuration: CustomResponsesConfiguration, overrideBaseURL: String? = nil) throws {
        let endpoint = try CustomResponsesConfiguration.validatedEndpoint(overrideBaseURL ?? configuration.baseURL)
        let model = try CustomResponsesConfiguration.validatedModelID(configuration.modelID)
        let effort = try CustomResponsesConfiguration.validatedReasoningEffort(configuration.reasoningEffort)
        let escapedURL = endpoint.baseURLString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let table = #"{ name = "Relay Custom", base_url = "\#(escapedURL)", wire_api = "responses", env_key = "\#(Self.envKeyName)", requires_openai_auth = false }"#

        self.baseURL = endpoint.baseURLString
        self.modelID = model
        self.reasoningEffort = effort
        self.arguments = [
            "-m", model,
            "-c", #"model_reasoning_effort="\#(effort)""#,
            "-c", "model_providers.\(Self.providerID)=\(table)",
            "-c", "model_provider=\(Self.providerID)",
            "-c", #"web_search="disabled""#,
            "-c", "features.apps=false"
        ]
    }
}
