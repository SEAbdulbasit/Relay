import Foundation
import Observation
import Security

nonisolated enum MagicReplyProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case workspaceDefault
    case onDeviceGemma
    case lmStudio
    case ollama
    case openRouter
    case customEndpoint
    case codexCLI
    case claudeCLI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspaceDefault: "Active Workspace Model"
        case .onDeviceGemma: "On-Device Gemma (.litertlm)"
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .openRouter: "OpenRouter API"
        case .customEndpoint: "OpenAI-Compatible API"
        case .codexCLI: "ChatGPT (Codex CLI)"
        case .claudeCLI: "Claude (Claude CLI)"
        }
    }

    var shortName: String {
        switch self {
        case .workspaceDefault: "Workspace"
        case .onDeviceGemma: "On this Mac"
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .openRouter: "OpenRouter"
        case .customEndpoint: "Custom API"
        case .codexCLI: "Codex"
        case .claudeCLI: "Claude"
        }
    }

    var requiresAPIKey: Bool {
        self == .openRouter
    }

    var supportsDedicatedAPIKey: Bool {
        switch self {
        case .openRouter, .ollama, .lmStudio, .customEndpoint: true
        case .workspaceDefault, .onDeviceGemma, .codexCLI, .claudeCLI: false
        }
    }

    var keychainAccount: String? {
        switch self {
        case .openRouter: "magicreply.openrouter.apiKey"
        case .ollama: "magicreply.ollama.apiKey"
        case .lmStudio: "magicreply.lmstudio.apiKey"
        case .customEndpoint: "magicreply.custom.apiKey"
        case .workspaceDefault, .onDeviceGemma, .codexCLI, .claudeCLI: nil
        }
    }
}

nonisolated enum MagicReplyAPIFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatCompletions
    case responses

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        }
    }

    var path: String {
        switch self {
        case .chatCompletions: "chat/completions"
        case .responses: "responses"
        }
    }
}

nonisolated enum MagicReplyEndpointValidator {
    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let normalized = host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() else {
            return false
        }
        return normalized == "127.0.0.1" || normalized == "::1" || normalized == "localhost"
    }

    static func endpoint(from baseURL: String, api: MagicReplyAPIFormat = .chatCompletions) -> URL? {
        endpoint(baseURL: baseURL, api: api)
    }

    /// Accepts a base URL or full route while preserving proxy prefixes.
    /// Rejects malformed URLs, whitespace, query/fragment, embedded URL credentials, or non-loopback plaintext HTTP.
    static func endpoint(baseURL: String, api: MagicReplyAPIFormat) -> URL? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              !raw.contains(where: \.isWhitespace),
              var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              scheme == "https" || isLoopbackHost(host),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true else {
            return nil
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        for format in MagicReplyAPIFormat.allCases where parts.path.hasSuffix("/" + format.path) {
            parts.path.removeLast(format.path.count + 1)
            break
        }
        parts.path += "/" + api.path
        return parts.url
    }

    static func validModelID(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 200 && !trimmed.contains(where: \.isWhitespace)
    }
}

nonisolated enum MagicReplyKeychain {
    static let service = "com.relay.macos.magicreply"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return delete(account)
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    static func destroyAllKeys() -> Bool {
        let accounts = MagicReplyProviderKind.allCases.compactMap(\.keychainAccount)
        return accounts.map { delete($0) }.allSatisfy { $0 }
    }
}

@Observable @MainActor
final class DraftModelPreferences {
    nonisolated static let customInstructionsByteLimit = 4_000
    nonisolated private static let stateMaximumBytes = 16_384

    private struct Saved: Codable {
        let version: Int
        let model: ModelConfiguration?
        var providerKind: MagicReplyProviderKind?
        var customInstructions: String?
        var includeScreenContext: Bool?
        var ollamaBaseURL: String?
        var ollamaModel: String?
        var ollamaAPIFormat: MagicReplyAPIFormat?
        var lmStudioBaseURL: String?
        var lmStudioModel: String?
        var lmStudioAPIFormat: MagicReplyAPIFormat?
        var openRouterModel: String?
        var customBaseURL: String?
        var customModel: String?
        var customAPIFormat: MagicReplyAPIFormat?
        var claudeModel: ClaudeCLIModel?
        var claudeEffort: ClaudeReasoningEffort?
        var codexModel: String?
        var codexEffort: CodexReasoningEffort?
    }

    private(set) var model: ModelConfiguration?
    private(set) var providerKind: MagicReplyProviderKind = .workspaceDefault
    private(set) var customInstructions: String = ""
    private(set) var includeScreenContext: Bool = true
    private(set) var ollamaBaseURL: String = "http://127.0.0.1:11434/v1"
    private(set) var ollamaModel: String = ""
    private(set) var ollamaAPIFormat: MagicReplyAPIFormat = .chatCompletions
    private(set) var lmStudioBaseURL: String = "http://127.0.0.1:1234/v1"
    private(set) var lmStudioModel: String = ""
    private(set) var lmStudioAPIFormat: MagicReplyAPIFormat = .chatCompletions
    private(set) var openRouterModel: String = "openai/gpt-4.1-mini"
    private(set) var customBaseURL: String = ""
    private(set) var customModel: String = ""
    private(set) var customAPIFormat: MagicReplyAPIFormat = .chatCompletions
    private(set) var claudeModel: ClaudeCLIModel = .sonnet
    private(set) var claudeEffort: ClaudeReasoningEffort = .low
    private(set) var codexModel: String = CodexCLIClient.defaultPlanningModel
    private(set) var codexEffort: CodexReasoningEffort = .low
    private(set) var credentialRevision = UUID()

    private(set) var hasInvalidSelection = false
    private(set) var status = "Magic Reply uses the active workspace model."
    @ObservationIgnored private let location: URL?

    init(location: URL?) {
        self.location = location
        guard let location, FileManager.default.fileExists(atPath: location.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: LocalStateFile.read(location, maximumBytes: Self.stateMaximumBytes))
            guard saved.version == 1 || saved.version == 2 else {
                throw RelayError.message("Unknown draft model preferences.")
            }
            if let config = saved.model { try Self.validate(config) }
            model = saved.model
            if let kind = saved.providerKind {
                providerKind = kind
            } else if let config = saved.model {
                providerKind = Self.providerKind(for: config.backend)
            } else {
                providerKind = .workspaceDefault
            }
            customInstructions = Self.boundedInstructions(saved.customInstructions ?? "")
            includeScreenContext = saved.includeScreenContext ?? true
            if let url = saved.ollamaBaseURL, !url.isEmpty { ollamaBaseURL = url }
            ollamaModel = saved.ollamaModel ?? ""
            ollamaAPIFormat = saved.ollamaAPIFormat ?? .chatCompletions
            if let url = saved.lmStudioBaseURL, !url.isEmpty { lmStudioBaseURL = url }
            else if let lm = saved.model?.lmStudio {
                lmStudioBaseURL = "http://\(lm.endpoint.host.rawValue):\(lm.endpoint.port)/v1"
            }
            lmStudioModel = saved.lmStudioModel ?? saved.model?.lmStudio?.modelID ?? ""
            lmStudioAPIFormat = saved.lmStudioAPIFormat ?? .chatCompletions
            if let orModel = saved.openRouterModel, !orModel.isEmpty { openRouterModel = orModel }
            customBaseURL = saved.customBaseURL ?? ""
            customModel = saved.customModel ?? ""
            customAPIFormat = saved.customAPIFormat ?? .chatCompletions
            claudeModel = saved.claudeModel ?? .sonnet
            claudeEffort = saved.claudeEffort ?? .low
            if let cxModel = saved.codexModel, !cxModel.isEmpty { codexModel = cxModel }
            codexEffort = saved.codexEffort ?? .low
            refreshStatusMessage()
        } catch {
            hasInvalidSelection = true
            status = "The saved drafting choice is unavailable. Choose it again or explicitly use the chat model; no other provider will be substituted."
        }
    }

    func select(_ url: URL) {
        let config = ModelConfiguration(
            modelPath: url.path,
            computeBackend: model?.computeBackend ?? "cpu",
            model: url.deletingPathExtension().lastPathComponent
        )
        apply(config, provider: .onDeviceGemma)
    }

    func selectBackend(_ backend: String) {
        guard var model, model.backend == .liteRTLM else { return }
        model.computeBackend = backend
        apply(model, provider: .onDeviceGemma)
    }

    func selectLMStudio(_ configuration: ModelConfiguration) {
        guard configuration.backend == .lmStudio else { return }
        if let lm = configuration.lmStudio {
            lmStudioBaseURL = "http://\(lm.endpoint.host.rawValue):\(lm.endpoint.port)/v1"
            lmStudioModel = lm.modelID
        }
        apply(configuration, provider: .lmStudio)
    }

    func useChatModel() {
        apply(nil, provider: .workspaceDefault)
    }

    func setProviderKind(_ kind: MagicReplyProviderKind) {
        providerKind = kind
        if kind == .workspaceDefault {
            model = nil
        }
        persistExtendedPreferences()
    }

    func setCustomInstructions(_ instructions: String) {
        customInstructions = Self.boundedInstructions(instructions)
        persistExtendedPreferences()
    }

    func setIncludeScreenContext(_ enabled: Bool) {
        includeScreenContext = enabled
        persistExtendedPreferences()
    }

    func updateOllama(baseURL: String? = nil, modelID: String? = nil, apiFormat: MagicReplyAPIFormat? = nil) {
        if let baseURL { ollamaBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let modelID { ollamaModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let apiFormat { ollamaAPIFormat = apiFormat }
        persistExtendedPreferences()
    }

    func updateLMStudioEndpoint(baseURL: String? = nil, modelID: String? = nil, apiFormat: MagicReplyAPIFormat? = nil) {
        if let baseURL { lmStudioBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let modelID { lmStudioModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let apiFormat { lmStudioAPIFormat = apiFormat }
        persistExtendedPreferences()
    }

    func updateOpenRouter(modelID: String) {
        openRouterModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        persistExtendedPreferences()
    }

    func updateCustomEndpoint(baseURL: String? = nil, modelID: String? = nil, apiFormat: MagicReplyAPIFormat? = nil) {
        if let baseURL { customBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let modelID { customModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let apiFormat { customAPIFormat = apiFormat }
        persistExtendedPreferences()
    }

    func updateClaude(model: ClaudeCLIModel? = nil, effort: ClaudeReasoningEffort? = nil) {
        if let model { claudeModel = model }
        if let effort { claudeEffort = effort }
        persistExtendedPreferences()
    }

    func updateCodex(modelID: String? = nil, effort: CodexReasoningEffort? = nil) {
        if let modelID {
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { codexModel = trimmed }
        }
        if let effort { codexEffort = effort }
        persistExtendedPreferences()
    }

    @discardableResult
    func saveAPIKey(_ key: String, for provider: MagicReplyProviderKind? = nil) -> Bool {
        let target = provider ?? providerKind
        guard let account = target.keychainAccount else { return false }
        let ok = MagicReplyKeychain.save(key, account: account)
        credentialRevision = UUID()
        refreshStatusMessage()
        return ok
    }

    @discardableResult
    func removeAPIKey(for provider: MagicReplyProviderKind? = nil) -> Bool {
        let target = provider ?? providerKind
        guard let account = target.keychainAccount else { return true }
        let ok = MagicReplyKeychain.delete(account)
        credentialRevision = UUID()
        refreshStatusMessage()
        return ok
    }

    func hasSavedAPIKey(for provider: MagicReplyProviderKind? = nil) -> Bool {
        let target = provider ?? providerKind
        guard let account = target.keychainAccount else { return false }
        return MagicReplyKeychain.read(account) != nil
    }

    func apiKey(for provider: MagicReplyProviderKind? = nil) -> String? {
        let target = provider ?? providerKind
        guard let account = target.keychainAccount else { return nil }
        return MagicReplyKeychain.read(account)
    }

    /// Nil when the selected dedicated Magic Reply route is valid; otherwise a short error caption.
    var configurationProblem: String? {
        _ = credentialRevision
        if customInstructions.utf8.count > Self.customInstructionsByteLimit {
            return "Shorten your Magic Reply instructions to 4,000 bytes or fewer."
        }
        switch providerKind {
        case .workspaceDefault:
            return nil
        case .onDeviceGemma:
            guard let model, model.backend == .liteRTLM else {
                return "Choose a local .litertlm model for Magic Reply."
            }
            return (try? Self.validate(model)) == nil ? "Selected .litertlm model is unavailable." : nil
        case .lmStudio:
            if let model, model.backend == .lmStudio, model.lmStudio?.selection != nil {
                return nil
            }
            guard MagicReplyEndpointValidator.endpoint(baseURL: lmStudioBaseURL, api: lmStudioAPIFormat) != nil else {
                return "Check the LM Studio base URL in Magic Reply Settings."
            }
            guard MagicReplyEndpointValidator.validModelID(lmStudioModel) else {
                return "Choose an LM Studio model in Magic Reply Settings."
            }
            return nil
        case .ollama:
            guard MagicReplyEndpointValidator.endpoint(baseURL: ollamaBaseURL, api: ollamaAPIFormat) != nil else {
                return "Check the Ollama base URL in Magic Reply Settings."
            }
            guard MagicReplyEndpointValidator.validModelID(ollamaModel) else {
                return "Enter an Ollama model ID (for example gemma3:4b) in Magic Reply Settings."
            }
            return nil
        case .openRouter:
            guard hasSavedAPIKey(for: .openRouter) else {
                return "Add your OpenRouter API key in Magic Reply Settings."
            }
            guard MagicReplyEndpointValidator.validModelID(openRouterModel) else {
                return "Enter an OpenRouter model ID in Magic Reply Settings."
            }
            return nil
        case .customEndpoint:
            guard MagicReplyEndpointValidator.endpoint(baseURL: customBaseURL, api: customAPIFormat) != nil else {
                return "Check the custom API base URL in Magic Reply Settings."
            }
            guard MagicReplyEndpointValidator.validModelID(customModel) else {
                return "Enter a model ID for your custom API in Magic Reply Settings."
            }
            return nil
        case .codexCLI:
            return MagicReplyEndpointValidator.validModelID(codexModel)
                ? nil : "Enter a valid Codex model ID in Magic Reply Settings."
        case .claudeCLI:
            return nil
        }
    }

    func resetAll() {
        _ = MagicReplyKeychain.destroyAllKeys()
        model = nil
        providerKind = .workspaceDefault
        customInstructions = ""
        includeScreenContext = true
        ollamaBaseURL = "http://127.0.0.1:11434/v1"
        ollamaModel = ""
        ollamaAPIFormat = .chatCompletions
        lmStudioBaseURL = "http://127.0.0.1:1234/v1"
        lmStudioModel = ""
        lmStudioAPIFormat = .chatCompletions
        openRouterModel = "openai/gpt-4.1-mini"
        customBaseURL = ""
        customModel = ""
        customAPIFormat = .chatCompletions
        claudeModel = .sonnet
        claudeEffort = .low
        codexModel = CodexCLIClient.defaultPlanningModel
        codexEffort = .low
        hasInvalidSelection = false
        credentialRevision = UUID()
        if let location {
            try? FileManager.default.removeItem(at: location)
        }
        refreshStatusMessage()
    }

    private static func providerKind(for backend: LocalBackend) -> MagicReplyProviderKind {
        switch backend {
        case .liteRTLM: .onDeviceGemma
        case .lmStudio: .lmStudio
        case .openRouter: .openRouter
        case .customResponses: .customEndpoint
        case .claudeCLI: .claudeCLI
        case .codexCLI: .codexCLI
        }
    }

    nonisolated static func boundedInstructions(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > customInstructionsByteLimit else { return trimmed }
        var out = ""
        out.reserveCapacity(customInstructionsByteLimit)
        for scalar in trimmed.unicodeScalars {
            let next = String(scalar)
            if out.utf8.count + next.utf8.count > customInstructionsByteLimit { break }
            out += next
        }
        return out
    }

    private static func validate(_ configuration: ModelConfiguration) throws {
        switch configuration.backend {
        case .liteRTLM:
            _ = try LocalModelClient.validatedModelURL(configuration)
        case .lmStudio:
            guard configuration.lmStudio?.selection != nil else { throw LocalInferenceFailure.unconfigured }
        case .openRouter:
            guard configuration.openRouter?.isConfigured == true else { throw LocalInferenceFailure.unconfigured }
        case .customResponses:
            guard configuration.customResponses?.isConfigured == true else { throw LocalInferenceFailure.unconfigured }
        case .claudeCLI, .codexCLI:
            guard configuration.hasConfiguredInferenceModel else { throw LocalInferenceFailure.unconfigured }
        }
    }

    private func apply(_ config: ModelConfiguration?, provider: MagicReplyProviderKind) {
        do {
            if let config { try Self.validate(config) }
            let previousModel = model
            let previousKind = providerKind
            model = config
            providerKind = provider
            do {
                try writeStateToDisk()
            } catch {
                model = previousModel
                providerKind = previousKind
                throw error
            }
            hasInvalidSelection = false
            refreshStatusMessage()
        } catch {
            status = "Draft model selection was not saved. " + error.localizedDescription
        }
    }

    private func persistExtendedPreferences() {
        do {
            if let model { try Self.validate(model) }
            try writeStateToDisk()
            hasInvalidSelection = false
            refreshStatusMessage()
        } catch {
            status = "Magic Reply preferences were not saved. " + error.localizedDescription
        }
    }

    private func writeStateToDisk() throws {
        guard let location else { return }
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let saved = Saved(
            version: 2,
            model: model,
            providerKind: providerKind,
            customInstructions: customInstructions.isEmpty ? nil : customInstructions,
            includeScreenContext: includeScreenContext,
            ollamaBaseURL: ollamaBaseURL,
            ollamaModel: ollamaModel.isEmpty ? nil : ollamaModel,
            ollamaAPIFormat: ollamaAPIFormat,
            lmStudioBaseURL: lmStudioBaseURL,
            lmStudioModel: lmStudioModel.isEmpty ? nil : lmStudioModel,
            lmStudioAPIFormat: lmStudioAPIFormat,
            openRouterModel: openRouterModel,
            customBaseURL: customBaseURL.isEmpty ? nil : customBaseURL,
            customModel: customModel.isEmpty ? nil : customModel,
            customAPIFormat: customAPIFormat,
            claudeModel: claudeModel,
            claudeEffort: claudeEffort,
            codexModel: codexModel,
            codexEffort: codexEffort
        )
        let data = try JSONEncoder().encode(saved)
        try LocalPrivateFileWriter.write(data: data, to: location, maximumBytes: Self.stateMaximumBytes)
    }

    private func refreshStatusMessage() {
        if providerKind == .workspaceDefault && model == nil {
            status = "Double Tap uses the active chat model."
            return
        }
        if let problem = configurationProblem {
            status = problem
            return
        }
        if let model {
            status = "Separate \(model.localProviderName) drafting model selected. Relay checks it on the first draft."
        } else {
            status = "Separate \(providerKind.title) provider selected for Magic Reply."
        }
    }
}
