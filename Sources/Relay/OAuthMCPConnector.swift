import AppKit
import CryptoKit
import Darwin
import Foundation
import Network
import Observation
import Security

// MARK: - Curated Cloud & Remote MCP Catalog (SRC-17..23, CON-11)

nonisolated enum OAuthMCPProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case notion
    case granola
    case gmail
    case googleCalendar = "google_calendar"
    case outlook
    case slack
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notion: "Notion"
        case .granola: "Granola"
        case .gmail: "Gmail"
        case .googleCalendar: "Google Calendar"
        case .outlook: "Outlook"
        case .slack: "Slack"
        case .custom: "Custom OAuth MCP"
        }
    }

    var subtitle: String {
        switch self {
        case .notion: "Workspace pages, notes, and databases via Notion remote MCP."
        case .granola: "Meeting notes, participants, and transcripts via Granola MCP."
        case .gmail: "Primary inbox & sent correspondence, skipping Spam, Trash, Drafts, and Promotions."
        case .googleCalendar: "Upcoming & recent events from primary and selected Google Calendars."
        case .outlook: "Focused inbox mail & calendar agenda via Microsoft OAuth 2.0 + PKCE."
        case .slack: "Opt-in direct messages and channel threads via Slack OAuth MCP."
        case .custom: "Any HTTPS MCP server supporting OAuth 2.0 + S256 PKCE discovery."
        }
    }

    var systemImage: String {
        switch self {
        case .notion: "doc.text.magnifyingglass"
        case .granola: "waveform.and.mic"
        case .gmail: "envelope.fill"
        case .googleCalendar: "calendar"
        case .outlook: "tray.full.fill"
        case .slack: "number.square.fill"
        case .custom: "server.rack"
        }
    }

    var defaultEndpoint: URL? {
        switch self {
        case .notion: URL(string: "https://mcp.notion.com/mcp")
        case .granola: URL(string: "https://mcp.granola.ai/mcp")
        case .gmail: URL(string: "https://gmail.googleapis.com/gmail/v1")
        case .googleCalendar: URL(string: "https://www.googleapis.com/calendar/v3")
        case .outlook: URL(string: "https://graph.microsoft.com/v1.0")
        case .slack: URL(string: "https://mcp.slack.com/mcp")
        case .custom: nil
        }
    }

    var defaultScopes: [String] {
        switch self {
        case .notion: []
        case .granola: []
        case .gmail: ["https://www.googleapis.com/auth/gmail.readonly", "openid", "email"]
        case .googleCalendar: ["https://www.googleapis.com/auth/calendar.readonly", "openid", "email"]
        case .outlook: ["Mail.Read", "Calendars.Read", "User.Read", "offline_access"]
        case .slack: ["channels:history", "groups:history", "im:history", "mpim:history", "users:read"]
        case .custom: []
        }
    }

    var curatedIssuerMetadata: OAuthServerMetadata? {
        switch self {
        case .gmail, .googleCalendar:
            return OAuthServerMetadata(
                issuer: "https://accounts.google.com",
                authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                registrationEndpoint: nil,
                revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke"),
                codeChallengeMethodsSupported: ["S256"],
                issuerParameterSupported: false
            )
        case .outlook:
            return OAuthServerMetadata(
                issuer: "https://login.microsoftonline.com/common/v2.0",
                authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                registrationEndpoint: nil,
                revocationEndpoint: nil,
                codeChallengeMethodsSupported: ["S256"],
                issuerParameterSupported: false
            )
        default:
            return nil
        }
    }

    var usesRemoteMCPProtocol: Bool {
        switch self {
        case .notion, .granola, .slack, .custom: true
        case .gmail, .googleCalendar, .outlook: false
        }
    }

    var supportsDynamicRegistration: Bool {
        switch self {
        case .notion, .granola, .custom: true
        case .slack, .gmail, .googleCalendar, .outlook: false
        }
    }

    var supportsClientSecret: Bool {
        switch self {
        case .slack, .gmail, .googleCalendar, .custom: true
        case .notion, .granola, .outlook: false
        }
    }

    var requiresClientSecret: Bool {
        switch self {
        case .slack: true
        case .notion, .granola, .gmail, .googleCalendar, .outlook, .custom: false
        }
    }

    var curatedReadTools: Set<String> {
        switch self {
        case .notion: ["notion-search", "notion-fetch", "notion-get-self", "notion-get-users"]
        case .granola: ["get_account_info", "list_meetings", "get_meetings", "get_meeting_transcript", "query_granola_meetings"]
        case .slack: ["slack_list_channels", "slack_get_channel_history", "slack_search_messages", "channels_list", "conversations_history"]
        default: []
        }
    }

    static var curatedPresets: [OAuthMCPProvider] {
        [.notion, .granola, .gmail, .googleCalendar, .outlook, .slack]
    }
}

// MARK: - Errors & Models

nonisolated enum OAuthMCPError: LocalizedError, Equatable {
    case invalidEndpoint(String)
    case insecureOrigin(String)
    case discoveryFailed(String)
    case pkceUnsupported
    case clientIDRequired(String)
    case clientSecretRequired(String)
    case registrationFailed(String)
    case registrationExpired
    case stateMismatch
    case issuerMismatch
    case authorizationDenied(String)
    case callbackFailed(String)
    case tokenExchangeFailed(String)
    case reconnectRequired
    case connectionChanged
    case connectionNotFound
    case keychainError(Int32)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let detail): "Invalid connector endpoint: \(detail)"
        case .insecureOrigin(let detail): "Refused untrusted or non-HTTPS OAuth endpoint: \(detail)"
        case .discoveryFailed(let detail): "OAuth metadata discovery failed: \(detail)"
        case .pkceUnsupported: "The authorization server does not advertise S256 PKCE support."
        case .clientIDRequired(let provider): "Provide an OAuth Client ID for \(provider)."
        case .clientSecretRequired(let provider): "\(provider) requires both an OAuth Client ID and Client Secret."
        case .registrationFailed(let detail): "Dynamic OAuth client registration failed: \(detail)"
        case .registrationExpired: "OAuth client registration expired; reconnect the account."
        case .stateMismatch: "OAuth callback state did not match the pending authorization request."
        case .issuerMismatch: "OAuth callback issuer did not match the discovered authorization server."
        case .authorizationDenied(let detail): "Authorization was declined: \(detail)"
        case .callbackFailed(let detail): "Loopback OAuth callback failed: \(detail)"
        case .tokenExchangeFailed(let detail): "OAuth token exchange failed: \(detail)"
        case .reconnectRequired: "Account authorization expired or was revoked. Reconnect to continue."
        case .connectionChanged: "The connected account changed or was disconnected during the read."
        case .connectionNotFound: "The requested cloud connector account is not connected."
        case .keychainError(let status): "Keychain access failed (OSStatus \(status))."
        case .httpError(let status, let detail): "Connector HTTP \(status): \(detail)"
        }
    }
}

nonisolated struct OAuthPKCE: Sendable, Equatable {
    let verifier: String
    let challenge: String
    let method: String = "S256"
    let state: String

    init() {
        let v = Self.randomBase64URL(byteCount: 32)
        self.verifier = v
        self.challenge = Self.s256Challenge(for: v)
        self.state = Self.randomBase64URL(byteCount: 32)
    }

    init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.s256Challenge(for: verifier)
        self.state = state
    }

    static func s256Challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: max(16, byteCount))
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if rc != errSecSuccess {
            let fallback = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            return fallback
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<a.count {
            diff |= (a[index] ^ b[index])
        }
        return diff == 0
    }
}

nonisolated struct OAuthProtectedResourceMetadata: Codable, Sendable, Equatable {
    let resource: String?
    let authorizationServers: [String]?
    let scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

nonisolated struct OAuthServerMetadata: Codable, Sendable, Equatable {
    let issuer: String?
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    let revocationEndpoint: URL?
    let codeChallengeMethodsSupported: [String]?
    let issuerParameterSupported: Bool

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case issuerParameterSupported = "authorization_response_iss_parameter_supported"
    }

    init(
        issuer: String?,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        registrationEndpoint: URL?,
        revocationEndpoint: URL?,
        codeChallengeMethodsSupported: [String]?,
        issuerParameterSupported: Bool
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.issuerParameterSupported = issuerParameterSupported
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer)
        authorizationEndpoint = try c.decode(URL.self, forKey: .authorizationEndpoint)
        tokenEndpoint = try c.decode(URL.self, forKey: .tokenEndpoint)
        registrationEndpoint = try c.decodeIfPresent(URL.self, forKey: .registrationEndpoint)
        revocationEndpoint = try c.decodeIfPresent(URL.self, forKey: .revocationEndpoint)
        codeChallengeMethodsSupported = try c.decodeIfPresent([String].self, forKey: .codeChallengeMethodsSupported)
        issuerParameterSupported = try c.decodeIfPresent(Bool.self, forKey: .issuerParameterSupported) ?? false
    }
}

nonisolated struct OAuthGrant: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String
    var expiresAt: Date?
    var clientID: String
    var clientSecret: String? = nil
    var isDynamicallyRegisteredClient: Bool
    var tokenEndpoint: URL
    var revocationEndpoint: URL?
    var issuer: String?
    var resource: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case tokenType
        case expiresAt
        case clientID
        case clientSecret
        case isDynamicallyRegisteredClient
        case tokenEndpoint
        case revocationEndpoint
        case issuer
        case resource
        case scope
    }

    init(
        accessToken: String,
        refreshToken: String? = nil,
        tokenType: String = "Bearer",
        expiresAt: Date? = nil,
        clientID: String,
        isDynamicallyRegisteredClient: Bool = false,
        tokenEndpoint: URL,
        revocationEndpoint: URL? = nil,
        issuer: String? = nil,
        resource: String? = nil,
        scope: String? = nil,
        clientSecret: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.isDynamicallyRegisteredClient = isDynamicallyRegisteredClient
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.issuer = issuer
        self.resource = resource
        self.scope = scope
    }

    init(
        accessToken: String,
        refreshToken: String? = nil,
        tokenType: String = "Bearer",
        expiresAt: Date? = nil,
        clientID: String,
        clientSecret: String?,
        isDynamicallyRegisteredClient: Bool = false,
        tokenEndpoint: URL,
        revocationEndpoint: URL? = nil,
        issuer: String? = nil,
        resource: String? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.isDynamicallyRegisteredClient = isDynamicallyRegisteredClient
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.issuer = issuer
        self.resource = resource
        self.scope = scope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        clientID = try c.decode(String.self, forKey: .clientID)
        clientSecret = try c.decodeIfPresent(String.self, forKey: .clientSecret)
        isDynamicallyRegisteredClient = try c.decodeIfPresent(Bool.self, forKey: .isDynamicallyRegisteredClient) ?? false
        tokenEndpoint = try c.decode(URL.self, forKey: .tokenEndpoint)
        revocationEndpoint = try c.decodeIfPresent(URL.self, forKey: .revocationEndpoint)
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer)
        resource = try c.decodeIfPresent(String.self, forKey: .resource)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try c.encode(tokenType, forKey: .tokenType)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encode(clientID, forKey: .clientID)
        try c.encodeIfPresent(clientSecret, forKey: .clientSecret)
        try c.encode(isDynamicallyRegisteredClient, forKey: .isDynamicallyRegisteredClient)
        try c.encode(tokenEndpoint, forKey: .tokenEndpoint)
        try c.encodeIfPresent(revocationEndpoint, forKey: .revocationEndpoint)
        try c.encodeIfPresent(issuer, forKey: .issuer)
        try c.encodeIfPresent(resource, forKey: .resource)
        try c.encodeIfPresent(scope, forKey: .scope)
    }

    func isExpiringSoon(now: Date = Date(), leewaySeconds: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leewaySeconds)
    }

    func replacingTokens(accessToken: String, refreshToken: String?, expiresIn: TimeInterval?, scope: String?, now: Date = Date()) -> OAuthGrant {
        var updated = self
        updated.accessToken = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            updated.refreshToken = refreshToken
        }
        if let expiresIn, expiresIn.isFinite, expiresIn > 0 {
            updated.expiresAt = now.addingTimeInterval(expiresIn)
        } else {
            updated.expiresAt = nil
        }
        if let scope, !scope.isEmpty {
            updated.scope = scope
        }
        updated.clientSecret = self.clientSecret
        return updated
    }
}

nonisolated struct OAuthMCPConnection: Codable, Identifiable, Sendable, Equatable {
    enum State: String, Codable, Sendable, Equatable {
        case connected
        case reconnectRequired = "reconnect_required"
        case disconnected
    }

    let id: String
    let provider: OAuthMCPProvider
    var accountLabel: String
    var accountFingerprint: String?
    var endpoint: URL
    var clientID: String?
    var generation: UUID
    var state: State
    var connectedAt: Date
    var lastVerifiedAt: Date?
    var discoveredTools: [String]

    /// Generation-scoped task identifier: relinking or switching an account rotates `generation`,
    /// immediately invalidating any in-flight reads targeting the prior generation (`CON-03`).
    var taskTarget: String {
        "oauth-\(id)@\(generation.uuidString.lowercased())"
    }
}

// MARK: - Keychain & Injectable Grant Stores + Per-Grant File Lock (CON-02)

nonisolated protocol OAuthGrantStore: Sendable {
    func load(connectionID: String) throws -> OAuthGrant?
    func save(_ grant: OAuthGrant, connectionID: String) throws
    func delete(connectionID: String) throws
    func deleteAll() throws
}

nonisolated final class KeychainOAuthGrantStore: OAuthGrantStore, @unchecked Sendable {
    static let defaultService = "com.relay.oauth-mcp.grants"
    let service: String

    init(service: String = KeychainOAuthGrantStore.defaultService) {
        self.service = service
    }

    func load(connectionID: String) throws -> OAuthGrant? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw OAuthMCPError.keychainError(status)
        }
        return try JSONDecoder().decode(OAuthGrant.self, from: data)
    }

    func save(_ grant: OAuthGrant, connectionID: String) throws {
        let data = try JSONEncoder().encode(grant)
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addAttrs = matchQuery
            addAttrs[kSecValueData as String] = data
            addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OAuthMCPError.keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw OAuthMCPError.keychainError(updateStatus)
        }
    }

    func delete(connectionID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OAuthMCPError.keychainError(status)
        }
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OAuthMCPError.keychainError(status)
        }
    }
}

nonisolated final class InMemoryOAuthGrantStore: OAuthGrantStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: OAuthGrant] = [:]

    init(initial: [String: OAuthGrant] = [:]) {
        self.storage = initial
    }

    func load(connectionID: String) throws -> OAuthGrant? {
        lock.lock()
        defer { lock.unlock() }
        return storage[connectionID]
    }

    func save(_ grant: OAuthGrant, connectionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[connectionID] = grant
    }

    func delete(connectionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: connectionID)
    }

    func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - OAuth 2.0 Metadata Discovery & HTTP Exchange (CON-01, CON-02)

nonisolated enum OAuthMetadataDiscovery {
    typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let defaultTransport: HTTPTransport = { request in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthMCPError.discoveryFailed("Non-HTTP response.")
        }
        return (data, http)
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let lower = host?.lowercased() else { return false }
        return lower == "127.0.0.1" || lower == "localhost" || lower == "::1" || lower == "[::1]"
    }

    static func validateSecureEndpoint(_ url: URL, allowLoopbackHTTP: Bool) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw OAuthMCPError.invalidEndpoint(url.absoluteString)
        }
        if scheme == "https" { return }
        if scheme == "http", allowLoopbackHTTP, isLoopbackHost(host) { return }
        throw OAuthMCPError.insecureOrigin(url.absoluteString)
    }

    static func parseWWWAuthenticate(_ header: String?) -> (resourceMetadataURL: URL?, scope: String?) {
        guard let header, header.lowercased().contains("bearer") else { return (nil, nil) }
        var resourceMeta: URL?
        var scope: String?
        let pattern = #"([a-zA-Z_][a-zA-Z0-9_-]*)\s*=\s*"([^"]*)""#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: header, range: NSRange(header.startIndex..., in: header)) {
                guard match.numberOfRanges == 3,
                      let kRange = Range(match.range(at: 1), in: header),
                      let vRange = Range(match.range(at: 2), in: header) else { continue }
                let key = header[kRange].lowercased()
                let value = String(header[vRange])
                if key == "resource_metadata", let parsed = URL(string: value) {
                    resourceMeta = parsed
                } else if key == "scope", !value.isEmpty {
                    scope = value
                }
            }
        }
        return (resourceMeta, scope)
    }

    static func discover(
        endpoint: URL,
        provider: OAuthMCPProvider,
        transport: HTTPTransport = defaultTransport
    ) async throws -> (server: OAuthServerMetadata, resource: String?, scopes: [String]) {
        let allowLoopback = isLoopbackHost(endpoint.host)
        try validateSecureEndpoint(endpoint, allowLoopbackHTTP: allowLoopback)

        // Curated non-MCP OAuth providers (Gmail, Google Calendar, Outlook) use verified first-party endpoints directly unless pointing at a local loopback test server.
        if !allowLoopback, let curated = provider.curatedIssuerMetadata {
            return (curated, nil, provider.defaultScopes)
        }

        var challengedResourceMetaURL: URL?
        var challengedScopes: [String] = []

        // 1. Optional unauthenticated probe to inspect 401 WWW-Authenticate Bearer resource_metadata challenge
        var probeReq = URLRequest(url: endpoint)
        probeReq.httpMethod = "GET"
        probeReq.setValue("application/json", forHTTPHeaderField: "Accept")
        if let (_, probeResp) = try? await transport(probeReq), probeResp.statusCode == 401 {
            let authHeader = probeResp.value(forHTTPHeaderField: "WWW-Authenticate")
            let parsed = parseWWWAuthenticate(authHeader)
            if let rm = parsed.resourceMetadataURL,
               (try? validateSecureEndpoint(rm, allowLoopbackHTTP: allowLoopback)) != nil {
                challengedResourceMetaURL = rm
            }
            if let s = parsed.scope {
                challengedScopes = s.split(separator: " ").map(String.init)
            }
        }

        // 2. Discover Protected Resource Metadata (`.well-known/oauth-protected-resource`)
        var authServerBaseURLs: [URL] = []
        var discoveredResource: String?
        var resourceScopes: [String] = []

        let prmCandidates = protectedResourceWellKnownURLs(for: endpoint, challenged: challengedResourceMetaURL)
        for candidate in prmCandidates {
            var req = URLRequest(url: candidate)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await transport(req), resp.statusCode == 200,
                  let prm = try? JSONDecoder().decode(OAuthProtectedResourceMetadata.self, from: data) else { continue }
            discoveredResource = prm.resource
            if let scopes = prm.scopesSupported, !scopes.isEmpty {
                resourceScopes = scopes
            }
            if let servers = prm.authorizationServers {
                for raw in servers {
                    if let url = URL(string: raw),
                       (try? validateSecureEndpoint(url, allowLoopbackHTTP: allowLoopback)) != nil {
                        authServerBaseURLs.append(url)
                    }
                }
            }
            if !authServerBaseURLs.isEmpty { break }
        }

        if authServerBaseURLs.isEmpty {
            var root = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            root?.path = ""
            root?.query = nil
            root?.fragment = nil
            if let fallbackBase = root?.url {
                authServerBaseURLs.append(fallbackBase)
            }
        }

        // 3. Discover Authorization Server Metadata (`.well-known/oauth-authorization-server` or `.well-known/openid-configuration`)
        for serverBase in authServerBaseURLs {
            for metaURL in authorizationServerWellKnownURLs(for: serverBase) {
                var req = URLRequest(url: metaURL)
                req.httpMethod = "GET"
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                guard let (data, resp) = try? await transport(req), resp.statusCode == 200,
                      let meta = try? JSONDecoder().decode(OAuthServerMetadata.self, from: data) else { continue }
                try validateServerMetadata(meta, allowLoopbackHTTP: allowLoopback)
                let finalScopes = selectScopes(
                    challengedScopes: challengedScopes,
                    resourceScopes: resourceScopes,
                    defaultScopes: provider.defaultScopes
                )
                return (meta, discoveredResource ?? endpoint.absoluteString, finalScopes)
            }
        }

        throw OAuthMCPError.discoveryFailed("No valid .well-known/oauth-authorization-server metadata found for \(endpoint.host ?? endpoint.absoluteString).")
    }

    static func selectScopes(
        challengedScopes: [String],
        resourceScopes: [String],
        defaultScopes: [String]
    ) -> [String] {
        if !challengedScopes.isEmpty {
            return challengedScopes
        }
        if !defaultScopes.isEmpty {
            if !resourceScopes.isEmpty {
                let supported = Set(resourceScopes)
                let intersection = defaultScopes.filter { supported.contains($0) }
                return intersection.isEmpty ? defaultScopes : intersection
            }
            return defaultScopes
        }
        return resourceScopes
    }

    static func validateServerMetadata(_ meta: OAuthServerMetadata, allowLoopbackHTTP: Bool) throws {
        try validateSecureEndpoint(meta.authorizationEndpoint, allowLoopbackHTTP: allowLoopbackHTTP)
        try validateSecureEndpoint(meta.tokenEndpoint, allowLoopbackHTTP: allowLoopbackHTTP)
        if let reg = meta.registrationEndpoint {
            try validateSecureEndpoint(reg, allowLoopbackHTTP: allowLoopbackHTTP)
        }
        if let rev = meta.revocationEndpoint {
            try validateSecureEndpoint(rev, allowLoopbackHTTP: allowLoopbackHTTP)
        }
        if let methods = meta.codeChallengeMethodsSupported, !methods.isEmpty {
            guard methods.contains("S256") else {
                throw OAuthMCPError.pkceUnsupported
            }
        }
        if let issuer = meta.issuer, let issuerURL = URL(string: issuer) {
            try validateSecureEndpoint(issuerURL, allowLoopbackHTTP: allowLoopbackHTTP)
        }
    }

    static func registerPublicClient(
        registrationEndpoint: URL,
        redirectURI: URL,
        clientName: String = "Relay",
        transport: HTTPTransport = defaultTransport
    ) async throws -> String {
        var req = URLRequest(url: registrationEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await transport(req)
        guard (200...299).contains(resp.statusCode) else {
            throw OAuthMCPError.registrationFailed("HTTP \(resp.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["client_id"] as? String, !clientID.isEmpty else {
            throw OAuthMCPError.registrationFailed("Missing client_id in dynamic registration response.")
        }
        return clientID
    }

    static func buildAuthorizationURL(
        metadata: OAuthServerMetadata,
        clientID: String,
        redirectURI: URL,
        pkce: OAuthPKCE,
        scopes: [String],
        resource: String?,
        provider: OAuthMCPProvider
    ) throws -> URL {
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthMCPError.invalidEndpoint(metadata.authorizationEndpoint.absoluteString)
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "client_id", value: clientID))
        items.append(URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString))
        items.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
        items.append(URLQueryItem(name: "code_challenge_method", value: pkce.method))
        items.append(URLQueryItem(name: "state", value: pkce.state))
        if !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        if let resource, !resource.isEmpty, provider.usesRemoteMCPProtocol {
            items.append(URLQueryItem(name: "resource", value: resource))
        }
        if provider == .gmail || provider == .googleCalendar {
            items.append(URLQueryItem(name: "access_type", value: "offline"))
            items.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw OAuthMCPError.invalidEndpoint(metadata.authorizationEndpoint.absoluteString)
        }
        return url
    }

    static func exchangeAuthorizationCode(
        code: String,
        metadata: OAuthServerMetadata,
        clientID: String,
        clientSecret: String? = nil,
        isDynamicClient: Bool,
        redirectURI: URL,
        pkceVerifier: String,
        resource: String?,
        provider: OAuthMCPProvider,
        now: Date = Date(),
        transport: HTTPTransport = defaultTransport
    ) async throws -> OAuthGrant {
        var params: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("redirect_uri", redirectURI.absoluteString),
            ("code_verifier", pkceVerifier)
        ]
        let trimmedSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSecret = (trimmedSecret?.isEmpty == false) ? trimmedSecret : nil
        if let effectiveSecret {
            params.append(("client_secret", effectiveSecret))
        }
        if let resource, !resource.isEmpty, provider.usesRemoteMCPProtocol {
            params.append(("resource", resource))
        }
        var req = URLRequest(url: metadata.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = formURLEncoded(params)

        let (data, resp) = try await transport(req)
        guard (200...299).contains(resp.statusCode) else {
            let errCode = parseOAuthErrorCode(data)
            throw OAuthMCPError.tokenExchangeFailed(errCode ?? "HTTP \(resp.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw OAuthMCPError.tokenExchangeFailed("Missing access_token.")
        }
        let refreshToken = json["refresh_token"] as? String
        let tokenType = (json["token_type"] as? String) ?? "Bearer"
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        let scope = json["scope"] as? String
        let expiresAt = expiresIn.flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil }

        return OAuthGrant(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresAt: expiresAt,
            clientID: clientID,
            clientSecret: effectiveSecret,
            isDynamicallyRegisteredClient: isDynamicClient,
            tokenEndpoint: metadata.tokenEndpoint,
            revocationEndpoint: metadata.revocationEndpoint,
            issuer: metadata.issuer,
            resource: resource,
            scope: scope
        )
    }

    static func exchangeAuthorizationCode(
        code: String,
        metadata: OAuthServerMetadata,
        clientID: String,
        isDynamicClient: Bool,
        redirectURI: URL,
        pkceVerifier: String,
        resource: String?,
        provider: OAuthMCPProvider,
        clientSecret: String?,
        now: Date = Date(),
        transport: HTTPTransport = defaultTransport
    ) async throws -> OAuthGrant {
        try await exchangeAuthorizationCode(
            code: code,
            metadata: metadata,
            clientID: clientID,
            clientSecret: clientSecret,
            isDynamicClient: isDynamicClient,
            redirectURI: redirectURI,
            pkceVerifier: pkceVerifier,
            resource: resource,
            provider: provider,
            now: now,
            transport: transport
        )
    }

    static func refreshGrant(
        _ grant: OAuthGrant,
        clientSecret: String? = nil,
        now: Date = Date(),
        transport: HTTPTransport = defaultTransport
    ) async throws -> OAuthGrant {
        guard let refreshToken = grant.refreshToken, !refreshToken.isEmpty else {
            throw OAuthMCPError.reconnectRequired
        }
        var params: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", grant.clientID)
        ]
        let trimmedSecret = (clientSecret ?? grant.clientSecret)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSecret = (trimmedSecret?.isEmpty == false) ? trimmedSecret : nil
        if let effectiveSecret {
            params.append(("client_secret", effectiveSecret))
        }
        if let resource = grant.resource, !resource.isEmpty {
            params.append(("resource", resource))
        }
        var req = URLRequest(url: grant.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = formURLEncoded(params)

        let (data, resp) = try await transport(req)
        if !(200...299).contains(resp.statusCode) {
            let errCode = parseOAuthErrorCode(data)
            if errCode == "invalid_grant" || resp.statusCode == 401 {
                throw OAuthMCPError.reconnectRequired
            }
            if errCode == "invalid_client" {
                throw OAuthMCPError.registrationExpired
            }
            throw OAuthMCPError.httpError(resp.statusCode, errCode ?? "Token refresh failed")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw OAuthMCPError.tokenExchangeFailed("Malformed refresh response.")
        }
        let rotatedRefresh = json["refresh_token"] as? String
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        let scope = json["scope"] as? String
        var updated = grant.replacingTokens(
            accessToken: accessToken,
            refreshToken: rotatedRefresh,
            expiresIn: expiresIn,
            scope: scope,
            now: now
        )
        if let effectiveSecret {
            updated.clientSecret = effectiveSecret
        }
        return updated
    }

    private static func protectedResourceWellKnownURLs(for endpoint: URL, challenged: URL?) -> [URL] {
        var urls: [URL] = []
        if let challenged { urls.append(challenged) }
        if var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) {
            let trimmedPath = comps.path == "/" ? "" : comps.path
            comps.query = nil
            comps.fragment = nil
            comps.path = "/.well-known/oauth-protected-resource" + trimmedPath
            if let pathScoped = comps.url { urls.append(pathScoped) }
            comps.path = "/.well-known/oauth-protected-resource"
            if let rootScoped = comps.url, !urls.contains(rootScoped) { urls.append(rootScoped) }
        }
        return urls
    }

    private static func authorizationServerWellKnownURLs(for base: URL) -> [URL] {
        var urls: [URL] = []
        if var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            let trimmedPath = (comps.path == "/" || comps.path.isEmpty) ? "" : comps.path
            comps.query = nil
            comps.fragment = nil
            if !trimmedPath.isEmpty {
                comps.path = "/.well-known/oauth-authorization-server" + trimmedPath
                if let u = comps.url { urls.append(u) }
            }
            comps.path = "/.well-known/oauth-authorization-server"
            if let u = comps.url, !urls.contains(u) { urls.append(u) }
            if !trimmedPath.isEmpty {
                comps.path = trimmedPath + "/.well-known/openid-configuration"
                if let u = comps.url { urls.append(u) }
            }
            comps.path = "/.well-known/openid-configuration"
            if let u = comps.url, !urls.contains(u) { urls.append(u) }
        }
        return urls
    }

    private static func formURLEncoded(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = pairs.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func parseOAuthErrorCode(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? String
    }
}

// MARK: - Ephemeral IPv4 Loopback Callback Listener (CON-01)

nonisolated final class OAuthLoopbackCallback: @unchecked Sendable {
    struct Result: Sendable, Equatable {
        let code: String
        let issuer: String?
    }

    private let slug: String
    private let expectedState: String
    private let expectedIssuer: String?
    private let requireIssuer: Bool
    private let queue = DispatchQueue(label: "com.relay.oauth.loopback")
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var continuation: CheckedContinuation<Result, Error>?
    private var completed = false
    private var connectionAttempts = 0

    private(set) var redirectURI: URL?

    init(slug: String, expectedState: String, expectedIssuer: String?, requireIssuer: Bool) {
        self.slug = slug.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        self.expectedState = expectedState
        self.expectedIssuer = expectedIssuer
        self.requireIssuer = requireIssuer
    }

    func start() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = false

        let nwListener = try NWListener(using: params)
        self.listener = nwListener

        let port: UInt16 = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    ready.resume(throwing: CancellationError())
                    return
                }
                self.readyContinuation = ready
                nwListener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let pending = self.readyContinuation else { return }
                        self.readyContinuation = nil
                        if let assigned = nwListener.port?.rawValue, assigned > 0 {
                            pending.resume(returning: assigned)
                        } else {
                            pending.resume(throwing: OAuthMCPError.callbackFailed("No loopback port assigned."))
                        }
                    case .failed(let error):
                        if let pending = self.readyContinuation {
                            self.readyContinuation = nil
                            pending.resume(throwing: OAuthMCPError.callbackFailed(error.localizedDescription))
                        } else {
                            self.finish(with: .failure(OAuthMCPError.callbackFailed(error.localizedDescription)))
                        }
                    default:
                        break
                    }
                }
                nwListener.newConnectionHandler = { [weak self] conn in
                    self?.handleConnection(conn)
                }
                nwListener.start(queue: self.queue)
            }
        }

        let pathSlug = slug.isEmpty ? "callback" : slug
        let url = URL(string: "http://127.0.0.1:\(port)/oauth/\(pathSlug)")!
        self.redirectURI = url
        return url
    }

    func waitForCallback(timeoutSeconds: TimeInterval = 180) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                queue.async { [weak self] in
                    guard let self else {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    if self.completed {
                        cont.resume(throwing: OAuthMCPError.callbackFailed("Callback listener already closed."))
                        return
                    }
                    self.continuation = cont
                    self.queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                        self?.finish(with: .failure(OAuthMCPError.callbackFailed("Timed out waiting for browser authorization.")))
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async {
            self.finish(with: .failure(CancellationError()))
        }
    }

    /// Validates a callback request URL directly (also exposed for deterministic unit testing of `CON-01` validation rules).
    static func validateCallbackURL(
        _ url: URL,
        expectedPath: String,
        expectedState: String,
        expectedIssuer: String?,
        requireIssuer: Bool
    ) throws -> Result {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthMCPError.callbackFailed("Malformed callback URL.")
        }
        guard components.path == expectedPath else {
            throw OAuthMCPError.callbackFailed("Unexpected callback path.")
        }
        let items = components.queryItems ?? []
        var seenKeys = Set<String>()
        var params: [String: String] = [:]
        for item in items {
            // Reject duplicate OAuth parameters to prevent parameter pollution (`CON-01`)
            guard seenKeys.insert(item.name).inserted else {
                throw OAuthMCPError.callbackFailed("Duplicate query parameter '\(item.name)'.")
            }
            params[item.name] = item.value ?? ""
        }

        // State MUST match before inspecting `error` or `code`
        guard let state = params["state"], OAuthPKCE.constantTimeEquals(state, expectedState) else {
            throw OAuthMCPError.stateMismatch
        }

        // Issuer check (RFC 9207 mix-up protection)
        if let returnedIssuer = params["iss"], !returnedIssuer.isEmpty {
            if let expectedIssuer, returnedIssuer != expectedIssuer {
                throw OAuthMCPError.issuerMismatch
            }
        } else if requireIssuer, expectedIssuer != nil {
            throw OAuthMCPError.issuerMismatch
        }

        if let oauthError = params["error"], !oauthError.isEmpty {
            let desc = params["error_description"] ?? oauthError
            throw OAuthMCPError.authorizationDenied(desc)
        }

        guard let code = params["code"], !code.isEmpty else {
            throw OAuthMCPError.callbackFailed("Missing authorization code.")
        }

        return Result(code: code, issuer: params["iss"])
    }

    private func handleConnection(_ connection: NWConnection) {
        connectionAttempts += 1
        guard connectionAttempts <= 8, !completed else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) {
            connection.cancel()
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let rawRequest = String(decoding: data, as: UTF8.self)
            guard let firstLine = rawRequest.components(separatedBy: "\r\n").first,
                  firstLine.hasPrefix("GET ") else {
                self.sendHTTP(connection, status: "405 Method Not Allowed", body: "Method Not Allowed") {}
                return
            }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.sendHTTP(connection, status: "400 Bad Request", body: "Bad Request") {}
                return
            }
            let targetPathAndQuery = String(parts[1])
            let expectedPath = self.redirectURI?.path ?? "/oauth/\(self.slug.isEmpty ? "callback" : self.slug)"
            if targetPathAndQuery == "/favicon.ico" {
                self.sendHTTP(connection, status: "404 Not Found", body: "Not Found") {}
                return
            }
            guard let fullURL = URL(string: "http://127.0.0.1" + targetPathAndQuery),
                  let components = URLComponents(url: fullURL, resolvingAgainstBaseURL: false) else {
                self.sendHTTP(connection, status: "400 Bad Request", body: "Invalid request target") {}
                return
            }
            let queryItems = components.queryItems ?? []
            let hasCodeOrError = queryItems.contains { $0.name == "code" || $0.name == "error" }
            guard components.path == expectedPath, hasCodeOrError else {
                self.sendHTTP(connection, status: "404 Not Found", body: "Not Found") {}
                return
            }

            do {
                let validated = try Self.validateCallbackURL(
                    fullURL,
                    expectedPath: expectedPath,
                    expectedState: self.expectedState,
                    expectedIssuer: self.expectedIssuer,
                    requireIssuer: self.requireIssuer
                )
                let html = "<!doctype html><html><body style='font-family:-apple-system,sans-serif;padding:32px'><h2>Connected to Relay</h2><p>You can close this browser tab and return to Relay.</p><script>window.close()</script></body></html>"
                self.sendHTTP(connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: html) {
                    self.finish(with: .success(validated))
                }
            } catch {
                let html = "<!doctype html><html><body style='font-family:-apple-system,sans-serif;padding:32px'><h2>Authorization could not be completed</h2><p>Return to Relay to try again.</p></body></html>"
                self.sendHTTP(connection, status: "400 Bad Request", contentType: "text/html; charset=utf-8", body: html) {
                    self.finish(with: .failure(error))
                }
            }
        }
    }

    private func sendHTTP(_ connection: NWConnection, status: String, contentType: String = "text/plain; charset=utf-8", body: String, completion: @Sendable @escaping () -> Void) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(header.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
            completion()
        })
    }

    private func finish(with outcome: Swift.Result<Result, Error>) {
        guard !completed else { return }
        completed = true
        listener?.cancel()
        listener = nil
        let cont = continuation
        continuation = nil
        switch outcome {
        case .success(let value): cont?.resume(returning: value)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }
}

// MARK: - Serialized Token Refresh Coordinator (CON-02)

actor OAuthTokenCoordinator {
    private let grantStore: any OAuthGrantStore
    private let lockDirectoryURL: URL?

    init(grantStore: any OAuthGrantStore, lockDirectoryURL: URL?) {
        self.grantStore = grantStore
        self.lockDirectoryURL = lockDirectoryURL
    }

    func validAccessToken(
        connectionID: String,
        forceRefresh: Bool = false,
        now: Date = Date(),
        transport: OAuthMetadataDiscovery.HTTPTransport
    ) async throws -> OAuthGrant {
        var lockFD: Int32 = -1
        var locked = false
        if let lockDirectoryURL {
            try? FileManager.default.createDirectory(at: lockDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let safeName = connectionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            let lockPath = lockDirectoryURL.appending(path: "\(safeName.isEmpty ? "grant" : safeName).lock").path
            lockFD = lockPath.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
            if lockFD >= 0 {
                for _ in 0..<200 {
                    if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
                        locked = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        defer {
            if lockFD >= 0 {
                if locked {
                    _ = flock(lockFD, LOCK_UN)
                }
                Darwin.close(lockFD)
            }
        }

        guard let existing = try grantStore.load(connectionID: connectionID) else {
            throw OAuthMCPError.reconnectRequired
        }
        if !forceRefresh, !existing.isExpiringSoon(now: now) {
            return existing
        }
        do {
            let refreshed = try await OAuthMetadataDiscovery.refreshGrant(existing, now: now, transport: transport)
            try grantStore.save(refreshed, connectionID: connectionID)
            return refreshed
        } catch let error as OAuthMCPError {
            if error == .reconnectRequired || error == .registrationExpired {
                try? grantStore.delete(connectionID: connectionID)
            }
            throw error
        }
    }
}

// MARK: - Curated Cloud Source Read Items

nonisolated struct CloudIngestedItem: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let connectionID: String
    let provider: OAuthMCPProvider
    let title: String
    let subtitle: String
    let body: String
    let timestamp: Date

    func toKnowledgeRecord() -> KnowledgeRecord {
        let combined = "\(title)\n\(subtitle)\n\n\(body)"
        let digest = SHA256.hash(data: Data(combined.utf8)).map { String(format: "%02x", $0) }.joined()
        return KnowledgeRecord(
            sourcePath: "relay-cloud://\(provider.rawValue)/\(connectionID)/\(id)",
            title: title,
            text: combined,
            modifiedAt: timestamp,
            contentHash: digest,
            byteCount: combined.utf8.count,
            coverageNote: "\(provider.displayName) connected account",
            sourceIdentity: "\(provider.rawValue):\(connectionID)",
            sourceUpdatedAt: timestamp
        )
    }
}

// MARK: - Observable OAuth MCP & Cloud Connector Manager (CON-01..03, CON-11, SRC-17..23)

@Observable @MainActor
final class OAuthMCPConnectorManager {
    private(set) var connections: [OAuthMCPConnection] = []
    private(set) var isAuthorizing = false
    private(set) var status = "Connect a cloud account or remote OAuth MCP server."

    @ObservationIgnored var onGenerationInvalidated: ((String, UUID) -> Void)?
    @ObservationIgnored var onConnectionsChanged: (() -> Void)?

    let grantStore: any OAuthGrantStore
    @ObservationIgnored private let tokenCoordinator: OAuthTokenCoordinator
    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private let httpTransport: OAuthMetadataDiscovery.HTTPTransport
    @ObservationIgnored private let openBrowserURL: @MainActor (URL) -> Bool
    @ObservationIgnored private var activeCallback: OAuthLoopbackCallback?

    static var defaultDirectoryURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Relay", directoryHint: .isDirectory)
    }

    init(
        directoryURL: URL? = OAuthMCPConnectorManager.defaultDirectoryURL,
        grantStore: (any OAuthGrantStore)? = nil,
        httpTransport: @escaping OAuthMetadataDiscovery.HTTPTransport = OAuthMetadataDiscovery.defaultTransport,
        openBrowserURL: (@MainActor (URL) -> Bool)? = nil
    ) {
        let store = grantStore ?? (directoryURL == nil ? InMemoryOAuthGrantStore() : KeychainOAuthGrantStore())
        self.grantStore = store
        self.persistenceURL = directoryURL?.appending(path: "oauth-mcp-connections.json")
        self.tokenCoordinator = OAuthTokenCoordinator(
            grantStore: store,
            lockDirectoryURL: directoryURL?.appending(path: "oauth-locks", directoryHint: .isDirectory)
        )
        self.httpTransport = httpTransport
        self.openBrowserURL = openBrowserURL ?? { NSWorkspace.shared.open($0) }
        restore()
    }

    func connection(id: String) -> OAuthMCPConnection? {
        connections.first { $0.id == id }
    }

    func connections(for provider: OAuthMCPProvider) -> [OAuthMCPConnection] {
        connections.filter { $0.provider == provider }
    }

    /// Checks that `connectionID` is still connected under `expectedGeneration` (`CON-03`).
    func isCurrentGeneration(id: String, generation: UUID) -> Bool {
        guard let conn = connection(id: id) else { return false }
        return conn.state == .connected && conn.generation == generation
    }

    func verifyGeneration(id: String, expected: UUID) throws {
        guard isCurrentGeneration(id: id, generation: expected) else {
            throw OAuthMCPError.connectionChanged
        }
    }

    /// Runs full OAuth 2.0 + S256 PKCE + Loopback Callback authorization for a curated or custom endpoint.
    /// Relinking an existing `existingConnectionID` mints a fresh `generation: UUID` (`CON-03`).
    @discardableResult
    func authorize(
        provider: OAuthMCPProvider,
        customEndpoint: URL? = nil,
        clientID: String? = nil,
        clientSecret: String? = nil,
        accountLabel: String = "",
        existingConnectionID: String? = nil,
        now: Date = Date()
    ) async throws -> OAuthMCPConnection {
        guard !isAuthorizing else {
            throw OAuthMCPError.callbackFailed("Another OAuth sign-in is already in progress.")
        }
        guard let targetEndpoint = customEndpoint ?? provider.defaultEndpoint else {
            let error = OAuthMCPError.invalidEndpoint("Enter an HTTPS MCP endpoint URL.")
            status = error.localizedDescription
            throw error
        }

        isAuthorizing = true
        status = "Discovering \(provider.displayName) OAuth 2.0 metadata…"
        defer {
            isAuthorizing = false
            activeCallback = nil
        }

        do {
            let allowLoopback = OAuthMetadataDiscovery.isLoopbackHost(targetEndpoint.host)
            try OAuthMetadataDiscovery.validateSecureEndpoint(targetEndpoint, allowLoopbackHTTP: allowLoopback)

            let existingGrant = existingConnectionID.flatMap { try? grantStore.load(connectionID: $0) }
            let suppliedSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackSecret = existingGrant?.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedClientSecret: String?
            if let suppliedSecret, !suppliedSecret.isEmpty {
                resolvedClientSecret = suppliedSecret
            } else if let fallbackSecret, !fallbackSecret.isEmpty {
                resolvedClientSecret = fallbackSecret
            } else {
                resolvedClientSecret = nil
            }

            if provider.requiresClientSecret && resolvedClientSecret == nil {
                throw OAuthMCPError.clientSecretRequired(provider.displayName)
            }

            let suppliedClientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let existingConnClientID = existingConnectionID
                .flatMap { connection(id: $0)?.clientID }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let existingGrantClientID: String? = {
                guard let grant = existingGrant, !grant.isDynamicallyRegisteredClient else { return nil }
                let trimmed = grant.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()
            let staticClientID: String?
            if let suppliedClientID, !suppliedClientID.isEmpty {
                staticClientID = suppliedClientID
            } else if let existingConnClientID, !existingConnClientID.isEmpty {
                staticClientID = existingConnClientID
            } else if let existingGrantClientID, !existingGrantClientID.isEmpty {
                staticClientID = existingGrantClientID
            } else {
                staticClientID = nil
            }

            if !provider.supportsDynamicRegistration && staticClientID == nil {
                throw OAuthMCPError.clientIDRequired(provider.displayName)
            }

            let discovery = try await OAuthMetadataDiscovery.discover(
                endpoint: targetEndpoint,
                provider: provider,
                transport: httpTransport
            )
            let pkce = OAuthPKCE()
            let connectionID = existingConnectionID ?? "\(provider.rawValue)-\(UUID().uuidString.prefix(8).lowercased())"

            let callback = OAuthLoopbackCallback(
                slug: provider.rawValue,
                expectedState: pkce.state,
                expectedIssuer: discovery.server.issuer,
                requireIssuer: discovery.server.issuerParameterSupported
            )
            activeCallback = callback
            let redirectURI = try await callback.start()
            defer { callback.cancel() }

            let resolvedClientID: String
            let isDynamicClient: Bool
            if let staticClientID {
                resolvedClientID = staticClientID
                isDynamicClient = false
            } else if provider.supportsDynamicRegistration, let regEndpoint = discovery.server.registrationEndpoint {
                status = "Registering public PKCE client with \(provider.displayName)…"
                resolvedClientID = try await OAuthMetadataDiscovery.registerPublicClient(
                    registrationEndpoint: regEndpoint,
                    redirectURI: redirectURI,
                    transport: httpTransport
                )
                isDynamicClient = true
            } else {
                throw OAuthMCPError.clientIDRequired(provider.displayName)
            }

            let authURL = try OAuthMetadataDiscovery.buildAuthorizationURL(
                metadata: discovery.server,
                clientID: resolvedClientID,
                redirectURI: redirectURI,
                pkce: pkce,
                scopes: discovery.scopes,
                resource: discovery.resource,
                provider: provider
            )

            status = "Waiting for authorization in your browser…"
            guard openBrowserURL(authURL) else {
                throw OAuthMCPError.callbackFailed("Could not open browser for authorization.")
            }

            let callbackResult = try await callback.waitForCallback()
            status = "Exchanging authorization code with S256 PKCE verifier…"

            let grant = try await OAuthMetadataDiscovery.exchangeAuthorizationCode(
                code: callbackResult.code,
                metadata: discovery.server,
                clientID: resolvedClientID,
                clientSecret: resolvedClientSecret,
                isDynamicClient: isDynamicClient,
                redirectURI: redirectURI,
                pkceVerifier: pkce.verifier,
                resource: discovery.resource,
                provider: provider,
                now: now,
                transport: httpTransport
            )

            return try finalizeGrant(
                grant: grant,
                connectionID: connectionID,
                provider: provider,
                endpoint: targetEndpoint,
                accountLabel: accountLabel,
                now: now
            )
        } catch is CancellationError {
            if status != "Canceled OAuth sign-in." {
                status = "Canceled OAuth sign-in."
            }
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled {
                if status != "Canceled OAuth sign-in." {
                    status = "Canceled OAuth sign-in."
                }
            } else {
                status = error.localizedDescription
            }
            throw error
        }
    }

    @discardableResult
    func authorize(
        provider: OAuthMCPProvider,
        customEndpoint: URL? = nil,
        clientID: String? = nil,
        accountLabel: String,
        existingConnectionID: String? = nil,
        now: Date = Date(),
        clientSecret: String?
    ) async throws -> OAuthMCPConnection {
        try await authorize(
            provider: provider,
            customEndpoint: customEndpoint,
            clientID: clientID,
            clientSecret: clientSecret,
            accountLabel: accountLabel,
            existingConnectionID: existingConnectionID,
            now: now
        )
    }

    @discardableResult
    func authorize(
        provider: OAuthMCPProvider,
        customEndpoint: URL? = nil,
        clientID: String? = nil,
        existingConnectionID: String,
        now: Date = Date(),
        clientSecret: String?
    ) async throws -> OAuthMCPConnection {
        try await authorize(
            provider: provider,
            customEndpoint: customEndpoint,
            clientID: clientID,
            clientSecret: clientSecret,
            accountLabel: "",
            existingConnectionID: existingConnectionID,
            now: now
        )
    }

    /// Registers or relinks a connection with a pre-verified grant (also supports programmatic/test setup of multi-account generations).
    @discardableResult
    func finalizeGrant(
        grant: OAuthGrant,
        connectionID: String,
        provider: OAuthMCPProvider,
        endpoint: URL,
        accountLabel: String,
        accountFingerprint: String? = nil,
        discoveredTools: [String] = [],
        now: Date = Date()
    ) throws -> OAuthMCPConnection {
        try grantStore.save(grant, connectionID: connectionID)

        let newGeneration = UUID()
        let trimmedLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLabel = trimmedLabel.isEmpty ? provider.displayName : trimmedLabel

        let previousGeneration = connection(id: connectionID)?.generation
        let record = OAuthMCPConnection(
            id: connectionID,
            provider: provider,
            accountLabel: effectiveLabel,
            accountFingerprint: accountFingerprint,
            endpoint: endpoint,
            clientID: grant.isDynamicallyRegisteredClient ? nil : grant.clientID,
            generation: newGeneration,
            state: .connected,
            connectedAt: now,
            lastVerifiedAt: now,
            discoveredTools: discoveredTools
        )

        if let idx = connections.firstIndex(where: { $0.id == connectionID }) {
            connections[idx] = record
        } else {
            connections.append(record)
        }
        persist()

        if let previousGeneration {
            onGenerationInvalidated?(connectionID, previousGeneration)
        }
        onConnectionsChanged?()
        status = "Connected \(provider.displayName) (\(effectiveLabel))."
        return record
    }

    func cancelPendingAuthorization() {
        activeCallback?.cancel()
        activeCallback = nil
        isAuthorizing = false
        status = "Canceled OAuth sign-in."
    }

    /// Returns a fresh bearer token and verifies `expectedGeneration` before AND after refresh (`CON-02`, `CON-03`).
    func validBearerToken(
        connectionID: String,
        expectedGeneration: UUID? = nil,
        forceRefresh: Bool = false,
        now: Date = Date()
    ) async throws -> (accessToken: String, generation: UUID) {
        guard let current = connection(id: connectionID), current.state == .connected else {
            throw OAuthMCPError.reconnectRequired
        }
        let targetGen = expectedGeneration ?? current.generation
        try verifyGeneration(id: connectionID, expected: targetGen)

        do {
            let grant = try await tokenCoordinator.validAccessToken(
                connectionID: connectionID,
                forceRefresh: forceRefresh,
                now: now,
                transport: httpTransport
            )
            // Re-verify generation after suspension point so relinking/removal mid-refresh fences cleanly!
            try verifyGeneration(id: connectionID, expected: targetGen)
            return (grant.accessToken, targetGen)
        } catch let error as OAuthMCPError {
            if error == .reconnectRequired || error == .registrationExpired {
                markReconnectRequired(connectionID: connectionID, clearDynamicClient: error == .registrationExpired)
            }
            throw error
        }
    }

    /// Executes an account-fenced read operation: checks generation before start and before returning (`CON-03`).
    func performFencedRead<T: Sendable>(
        connectionID: String,
        now: Date = Date(),
        operation: @Sendable (OAuthMCPConnection, String) async throws -> T
    ) async throws -> T {
        guard let snapshot = connection(id: connectionID), snapshot.state == .connected else {
            throw OAuthMCPError.connectionNotFound
        }
        let expectedGeneration = snapshot.generation
        let (token, _) = try await validBearerToken(connectionID: connectionID, expectedGeneration: expectedGeneration, now: now)
        let result = try await operation(snapshot, token)
        try verifyGeneration(id: connectionID, expected: expectedGeneration)
        return result
    }

    /// Reads recent items from a curated cloud or remote MCP source with generation fencing (`SRC-17..23`, `CON-03`).
    func fetchCuratedCloudWindow(connectionID: String, maxItems: Int = 20, now: Date = Date()) async throws -> [CloudIngestedItem] {
        guard maxItems > 0 else { return [] }
        let transport = httpTransport
        guard let initialSnapshot = connection(id: connectionID), initialSnapshot.state == .connected else {
            throw OAuthMCPError.connectionNotFound
        }
        let expectedGeneration = initialSnapshot.generation

        do {
            let outcome: (items: [CloudIngestedItem], discoveredTools: [String]) = try await performFencedRead(connectionID: connectionID, now: now) { conn, bearerToken in
                switch conn.provider {
                case .gmail:
                    let items = try await Self.fetchGmailWindow(connection: conn, token: bearerToken, maxItems: maxItems, transport: transport)
                    return (items, [])
                case .googleCalendar:
                    let items = try await Self.fetchGoogleCalendarWindow(connection: conn, token: bearerToken, maxItems: maxItems, now: now, transport: transport)
                    return (items, [])
                case .outlook:
                    let items = try await Self.fetchOutlookWindow(connection: conn, token: bearerToken, maxItems: maxItems, now: now, transport: transport)
                    return (items, [])
                case .notion, .granola, .slack, .custom:
                    return try await Self.fetchRemoteMCPWindow(connection: conn, token: bearerToken, maxItems: maxItems, now: now, transport: transport)
                }
            }
            if !outcome.discoveredTools.isEmpty,
               let idx = connections.firstIndex(where: { $0.id == connectionID && $0.generation == expectedGeneration }) {
                connections[idx].lastVerifiedAt = now
                if connections[idx].discoveredTools != outcome.discoveredTools {
                    connections[idx].discoveredTools = outcome.discoveredTools
                }
                persist()
                onConnectionsChanged?()
            }
            return Array(outcome.items.prefix(maxItems))
        } catch let error as OAuthMCPError {
            if error == .reconnectRequired, isCurrentGeneration(id: connectionID, generation: expectedGeneration) {
                markReconnectRequired(connectionID: connectionID, clearDynamicClient: false)
            }
            throw error
        }
    }

    func disconnect(connectionID: String) {
        guard let idx = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        let removed = connections.remove(at: idx)
        try? grantStore.delete(connectionID: connectionID)
        persist()
        onGenerationInvalidated?(connectionID, removed.generation)
        onConnectionsChanged?()
        status = "Disconnected \(removed.provider.displayName) (\(removed.accountLabel)) and removed Keychain tokens."
    }

    func removeAll() {
        let existing = connections
        connections.removeAll()
        try? grantStore.deleteAll()
        if let persistenceURL {
            try? FileManager.default.removeItem(at: persistenceURL)
        }
        for item in existing {
            onGenerationInvalidated?(item.id, item.generation)
        }
        onConnectionsChanged?()
        status = "Removed all cloud connector accounts and Keychain tokens."
    }

    private func markReconnectRequired(connectionID: String, clearDynamicClient: Bool) {
        guard let idx = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        let oldGen = connections[idx].generation
        connections[idx].state = .reconnectRequired
        connections[idx].generation = UUID()
        if clearDynamicClient {
            connections[idx].clientID = nil
        }
        persist()
        onGenerationInvalidated?(connectionID, oldGen)
        onConnectionsChanged?()
    }

    private func restore() {
        guard let persistenceURL,
              let data = try? LocalStateFile.read(persistenceURL, maximumBytes: 1_048_576),
              let decoded = try? JSONDecoder().decode([OAuthMCPConnection].self, from: data) else { return }
        connections = decoded
    }

    private func persist() {
        guard let persistenceURL else { return }
        let dir = persistenceURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(connections) {
            try? LocalPrivateFileWriter.write(data: data, to: persistenceURL, maximumBytes: 1_048_576)
        }
    }

    // MARK: - Curated REST Window Readers (Gmail, Google Calendar, Outlook)

    nonisolated private static func fetchGmailWindow(
        connection: OAuthMCPConnection,
        token: String,
        maxItems: Int,
        transport: OAuthMetadataDiscovery.HTTPTransport
    ) async throws -> [CloudIngestedItem] {
        var listComps = URLComponents(url: connection.endpoint.appending(path: "users/me/messages"), resolvingAgainstBaseURL: false)
        listComps?.queryItems = [
            URLQueryItem(name: "q", value: "-in:spam -in:trash -in:drafts -category:promotions"),
            URLQueryItem(name: "maxResults", value: String(max(1, min(maxItems, 25))))
        ]
        guard let listURL = listComps?.url else { return [] }
        var listReq = URLRequest(url: listURL)
        listReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (listData, listResp) = try await transport(listReq)
        if listResp.statusCode == 401 { throw OAuthMCPError.reconnectRequired }
        guard (200...299).contains(listResp.statusCode),
              let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else { return [] }

        var items: [CloudIngestedItem] = []
        for entry in messages.prefix(maxItems) {
            guard let id = entry["id"] as? String else { continue }
            let detailURL = connection.endpoint.appending(path: "users/me/messages/\(id)")
            var detailReq = URLRequest(url: detailURL)
            detailReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (msgData, msgResp) = try? await transport(detailReq),
                  (200...299).contains(msgResp.statusCode),
                  let msgJSON = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] else { continue }
            let labels = Set((msgJSON["labelIds"] as? [String]) ?? [])
            if !labels.isDisjoint(with: ["SPAM", "TRASH", "DRAFT", "CATEGORY_PROMOTIONS"]) { continue }

            let snippet = (msgJSON["snippet"] as? String) ?? ""
            let internalDateMs = Double((msgJSON["internalDate"] as? String) ?? "") ?? 0
            let payload = msgJSON["payload"] as? [String: Any]
            let headers = (payload?["headers"] as? [[String: Any]]) ?? []
            var subject = "(No Subject)"
            var from = ""
            for h in headers {
                let name = ((h["name"] as? String) ?? "").lowercased()
                let val = (h["value"] as? String) ?? ""
                if name == "subject", !val.isEmpty { subject = val }
                if name == "from", !val.isEmpty { from = val }
            }
            items.append(CloudIngestedItem(
                id: id,
                connectionID: connection.id,
                provider: .gmail,
                title: subject,
                subtitle: from.isEmpty ? "Gmail (\(connection.accountLabel))" : "Gmail · \(from)",
                body: NativePersonalSources.bounded(snippet, maximumBytes: 8_192),
                timestamp: internalDateMs > 0 ? Date(timeIntervalSince1970: internalDateMs / 1000.0) : Date()
            ))
        }
        return items
    }

    nonisolated private static func fetchGoogleCalendarWindow(
        connection: OAuthMCPConnection,
        token: String,
        maxItems: Int,
        now: Date,
        transport: OAuthMetadataDiscovery.HTTPTransport
    ) async throws -> [CloudIngestedItem] {
        var comps = URLComponents(url: connection.endpoint.appending(path: "calendars/primary/events"), resolvingAgainstBaseURL: false)
        let iso = ISO8601DateFormatter()
        comps?.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: iso.string(from: now.addingTimeInterval(-7 * 86_400))),
            URLQueryItem(name: "timeMax", value: iso.string(from: now.addingTimeInterval(14 * 86_400))),
            URLQueryItem(name: "maxResults", value: String(max(1, min(maxItems, 50))))
        ]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await transport(req)
        if resp.statusCode == 401 { throw OAuthMCPError.reconnectRequired }
        guard (200...299).contains(resp.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["items"] as? [[String: Any]] else { return [] }

        return events.compactMap { ev in
            guard let id = ev["id"] as? String else { return nil }
            if (ev["status"] as? String) == "cancelled" { return nil }
            let summary = (ev["summary"] as? String) ?? "(Untitled Event)"
            let startObj = ev["start"] as? [String: Any]
            let startStr = (startObj?["dateTime"] as? String) ?? (startObj?["date"] as? String) ?? ""
            let location = (ev["location"] as? String) ?? ""
            let desc = (ev["description"] as? String) ?? ""
            let body = [startStr.isEmpty ? nil : "When: \(startStr)", location.isEmpty ? nil : "Where: \(location)", desc.isEmpty ? nil : desc]
                .compactMap { $0 }.joined(separator: "\n")
            return CloudIngestedItem(
                id: id,
                connectionID: connection.id,
                provider: .googleCalendar,
                title: summary,
                subtitle: "Google Calendar (\(connection.accountLabel))",
                body: NativePersonalSources.bounded(body, maximumBytes: 4_096),
                timestamp: iso.date(from: startStr) ?? now
            )
        }
    }

    nonisolated private static func fetchOutlookWindow(
        connection: OAuthMCPConnection,
        token: String,
        maxItems: Int,
        now: Date = Date(),
        transport: OAuthMetadataDiscovery.HTTPTransport
    ) async throws -> [CloudIngestedItem] {
        let iso = ISO8601DateFormatter()
        var mailItems: [CloudIngestedItem] = []
        var calendarItems: [CloudIngestedItem] = []

        // 1. Focused Inbox Mail (`Mail.Read`)
        var mailComps = URLComponents(url: connection.endpoint.appending(path: "me/mailFolders/inbox/messages"), resolvingAgainstBaseURL: false)
        mailComps?.queryItems = [
            URLQueryItem(name: "$top", value: String(max(1, min(maxItems, 25)))),
            URLQueryItem(name: "$select", value: "id,subject,bodyPreview,receivedDateTime,from,isDraft,inferenceClassification")
        ]
        if let mailURL = mailComps?.url {
            var mailReq = URLRequest(url: mailURL)
            mailReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            mailReq.setValue("application/json", forHTTPHeaderField: "Accept")
            let (mailData, mailResp) = try await transport(mailReq)
            if mailResp.statusCode == 401 { throw OAuthMCPError.reconnectRequired }
            if (200...299).contains(mailResp.statusCode),
               let json = try? JSONSerialization.jsonObject(with: mailData) as? [String: Any],
               let values = json["value"] as? [[String: Any]] {
                mailItems = values.compactMap { msg in
                    guard let id = msg["id"] as? String, !id.isEmpty else { return nil }
                    if (msg["isDraft"] as? Bool) == true { return nil }
                    if let classification = (msg["inferenceClassification"] as? String)?.lowercased(), classification == "other" {
                        return nil
                    }
                    let subject = (msg["subject"] as? String) ?? "(No Subject)"
                    let preview = (msg["bodyPreview"] as? String) ?? ""
                    let receivedStr = (msg["receivedDateTime"] as? String) ?? ""
                    let fromEmail = (((msg["from"] as? [String: Any])?["emailAddress"] as? [String: Any])?["address"] as? String) ?? ""
                    return CloudIngestedItem(
                        id: id,
                        connectionID: connection.id,
                        provider: .outlook,
                        title: subject,
                        subtitle: fromEmail.isEmpty ? "Outlook (\(connection.accountLabel))" : "Outlook · \(fromEmail)",
                        body: NativePersonalSources.bounded(preview, maximumBytes: 8_192),
                        timestamp: parseFlexibleTimestamp(receivedStr, fallback: now)
                    )
                }
            }
        }

        // 2. Calendar Agenda (`Calendars.Read`: now - 7d .. now + 14d)
        var calComps = URLComponents(url: connection.endpoint.appending(path: "me/calendarView"), resolvingAgainstBaseURL: false)
        calComps?.queryItems = [
            URLQueryItem(name: "startDateTime", value: iso.string(from: now.addingTimeInterval(-7 * 86_400))),
            URLQueryItem(name: "endDateTime", value: iso.string(from: now.addingTimeInterval(14 * 86_400))),
            URLQueryItem(name: "$top", value: String(max(1, min(maxItems, 50)))),
            URLQueryItem(name: "$select", value: "id,subject,bodyPreview,start,location,isCancelled")
        ]
        if let calURL = calComps?.url {
            var calReq = URLRequest(url: calURL)
            calReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            calReq.setValue("application/json", forHTTPHeaderField: "Accept")
            let (calData, calResp) = try await transport(calReq)
            if calResp.statusCode == 401 { throw OAuthMCPError.reconnectRequired }
            if (200...299).contains(calResp.statusCode),
               let json = try? JSONSerialization.jsonObject(with: calData) as? [String: Any],
               let events = json["value"] as? [[String: Any]] {
                calendarItems = events.compactMap { ev in
                    guard let id = ev["id"] as? String, !id.isEmpty else { return nil }
                    if (ev["isCancelled"] as? Bool) == true { return nil }
                    let rawSubject = (ev["subject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let subject = rawSubject.isEmpty ? "(Untitled Event)" : rawSubject
                    let startStr: String = {
                        if let startObj = ev["start"] as? [String: Any], let dt = startObj["dateTime"] as? String {
                            return dt
                        }
                        return (ev["start"] as? String) ?? ""
                    }()
                    let locationStr: String = {
                        if let locObj = ev["location"] as? [String: Any], let disp = locObj["displayName"] as? String {
                            return disp
                        }
                        return (ev["location"] as? String) ?? ""
                    }()
                    let preview = (ev["bodyPreview"] as? String) ?? ""
                    let body = [
                        startStr.isEmpty ? nil : "When: \(startStr)",
                        locationStr.isEmpty ? nil : "Where: \(locationStr)",
                        preview.isEmpty ? nil : preview
                    ].compactMap { $0 }.joined(separator: "\n")
                    return CloudIngestedItem(
                        id: "cal-\(id)",
                        connectionID: connection.id,
                        provider: .outlook,
                        title: subject,
                        subtitle: "Outlook Calendar (\(connection.accountLabel))",
                        body: NativePersonalSources.bounded(body, maximumBytes: 4_096),
                        timestamp: parseFlexibleTimestamp(startStr, fallback: now)
                    )
                }
            }
        }

        guard maxItems > 0 else { return [] }
        if calendarItems.isEmpty { return Array(mailItems.prefix(maxItems)) }
        if mailItems.isEmpty { return Array(calendarItems.prefix(maxItems)) }
        if mailItems.count + calendarItems.count <= maxItems {
            return mailItems + calendarItems
        }
        let halfQuota = max(1, maxItems / 2)
        let calCount = min(calendarItems.count, halfQuota)
        let mailCount = min(mailItems.count, maxItems - calCount)
        var combined = Array(mailItems.prefix(mailCount)) + Array(calendarItems.prefix(calCount))
        if combined.count < maxItems {
            let remaining = maxItems - combined.count
            combined.append(contentsOf: calendarItems.dropFirst(calCount).prefix(remaining))
        }
        return Array(combined.prefix(maxItems))
    }

    // MARK: - Streamable HTTP Read-Only MCP Cloud Window Reader (Notion, Granola, Slack, Custom)

    nonisolated private struct SafeMCPToolCandidate {
        let name: String
        let callArguments: [String: Any]?
        let priority: Int
        let discoveryIndex: Int
    }

    nonisolated static func safeReadToolPriority(name: String, provider: OAuthMCPProvider) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let forbidden = ["write", "create", "update", "delete", "remove", "send", "post", "archive", "edit", "mutate"]
        if forbidden.contains(where: { lower.contains($0) }) {
            return nil
        }
        if provider.curatedReadTools.contains(trimmed) {
            return 0
        }
        let allowed = ["search", "list", "get", "read", "fetch", "recent"]
        if allowed.contains(where: { lower.hasPrefix($0) }) {
            return 1
        }
        if allowed.contains(where: { lower.contains($0) }) {
            return 2
        }
        return nil
    }

    nonisolated private static func safeCallArguments(for inputSchema: [String: Any]?) -> [String: Any]? {
        guard let inputSchema else { return [:] }
        guard let rawRequired = inputSchema["required"] else { return [:] }
        guard let requiredStrings = rawRequired as? [String] else { return nil }
        let cleaned = requiredStrings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty {
            return [:]
        }
        if cleaned.count == 1 && cleaned[0] == "query" {
            return ["query": ""]
        }
        return nil
    }

    nonisolated static func parseMCPJSONRPCResponse(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        if let direct = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return direct
        }
        let rawText = String(decoding: data, as: UTF8.self)
        var parsedFrames: [[String: Any]] = []
        var dataLines: [String] = []

        func flushEvent() {
            guard !dataLines.isEmpty else { return }
            defer { dataLines.removeAll(keepingCapacity: true) }
            let joined = dataLines.joined(separator: "\n")
            if let obj = try? JSONSerialization.jsonObject(with: Data(joined.utf8)) as? [String: Any] {
                parsedFrames.append(obj)
                return
            }
            for line in dataLines {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    parsedFrames.append(obj)
                }
            }
        }

        for rawLine in rawText.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("event:") {
                flushEvent()
                continue
            }
            if line.hasPrefix("data:") {
                var payload = String(line.dropFirst(5))
                if payload.hasPrefix(" ") { payload.removeFirst() }
                dataLines.append(payload)
            }
        }
        flushEvent()

        return parsedFrames.first(where: { $0["result"] != nil })
            ?? parsedFrames.first(where: { $0["error"] != nil })
            ?? parsedFrames.last
    }

    nonisolated private static func sendMCPJSONRPC(
        endpoint: URL,
        token: String,
        sessionID: String?,
        method: String,
        id: String?,
        params: [String: Any],
        transport: OAuthMetadataDiscovery.HTTPTransport
    ) async throws -> (json: [String: Any]?, statusCode: Int, sessionID: String?) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID, !sessionID.isEmpty {
            req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        if let id {
            body["id"] = id
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await transport(req)
        if resp.statusCode == 401 {
            throw OAuthMCPError.reconnectRequired
        }
        let nextSession = resp.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID
        return (parseMCPJSONRPCResponse(data), resp.statusCode, nextSession)
    }

    nonisolated private static func fetchRemoteMCPWindow(
        connection: OAuthMCPConnection,
        token: String,
        maxItems: Int,
        now: Date,
        transport: OAuthMetadataDiscovery.HTTPTransport
    ) async throws -> (items: [CloudIngestedItem], discoveredTools: [String]) {
        guard maxItems > 0 else { return ([], []) }

        var listReply = try await sendMCPJSONRPC(
            endpoint: connection.endpoint,
            token: token,
            sessionID: nil,
            method: "tools/list",
            id: "relay-tools-list-1",
            params: [:],
            transport: transport
        )
        var activeSessionID = listReply.sessionID
        var rawTools = (listReply.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]

        // Fallback for stateful Streamable HTTP MCP servers that require `initialize` before `tools/list`.
        if rawTools == nil && (!(200...299).contains(listReply.statusCode) || listReply.json?["error"] != nil) {
            let initParams: [String: Any] = [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Relay", "version": "1.0"]
            ]
            if let initReply = try? await sendMCPJSONRPC(
                endpoint: connection.endpoint,
                token: token,
                sessionID: nil,
                method: "initialize",
                id: "relay-init-1",
                params: initParams,
                transport: transport
            ), (200...299).contains(initReply.statusCode) {
                activeSessionID = initReply.sessionID
                _ = try? await sendMCPJSONRPC(
                    endpoint: connection.endpoint,
                    token: token,
                    sessionID: activeSessionID,
                    method: "notifications/initialized",
                    id: nil,
                    params: [:],
                    transport: transport
                )
                listReply = try await sendMCPJSONRPC(
                    endpoint: connection.endpoint,
                    token: token,
                    sessionID: activeSessionID,
                    method: "tools/list",
                    id: "relay-tools-list-2",
                    params: [:],
                    transport: transport
                )
                activeSessionID = listReply.sessionID
                rawTools = (listReply.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            }
        }

        guard let discoveredRawTools = rawTools, !discoveredRawTools.isEmpty else {
            return ([], [])
        }

        var seenNames = Set<String>()
        var candidates: [SafeMCPToolCandidate] = []
        for (idx, toolObj) in discoveredRawTools.enumerated() {
            guard let rawName = toolObj["name"] as? String else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let priority = safeReadToolPriority(name: name, provider: connection.provider),
                  seenNames.insert(name).inserted else { continue }
            let schema = (toolObj["inputSchema"] as? [String: Any]) ?? (toolObj["input_schema"] as? [String: Any])
            let callArgs = safeCallArguments(for: schema)
            candidates.append(SafeMCPToolCandidate(
                name: name,
                callArguments: callArgs,
                priority: priority,
                discoveryIndex: idx
            ))
        }

        candidates.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.discoveryIndex < rhs.discoveryIndex
        }

        let safeToolNames = candidates.map(\.name)
        guard !safeToolNames.isEmpty else { return ([], []) }

        let callableTools = candidates.filter { $0.callArguments != nil }.prefix(2)
        var collectedItems: [CloudIngestedItem] = []
        var seenItemIDs = Set<String>()

        for (callIdx, tool) in callableTools.enumerated() {
            guard collectedItems.count < maxItems, let args = tool.callArguments else { break }
            let callParams: [String: Any] = [
                "name": tool.name,
                "arguments": args
            ]
            let callReply = try await sendMCPJSONRPC(
                endpoint: connection.endpoint,
                token: token,
                sessionID: activeSessionID,
                method: "tools/call",
                id: "relay-tools-call-\(callIdx + 1)",
                params: callParams,
                transport: transport
            )
            activeSessionID = callReply.sessionID
            guard (200...299).contains(callReply.statusCode),
                  let resultObj = callReply.json?["result"] as? [String: Any],
                  (resultObj["isError"] as? Bool) != true else { continue }

            let parsed = extractCloudItems(
                fromToolResult: resultObj,
                toolName: tool.name,
                connection: connection,
                now: now,
                limit: maxItems - collectedItems.count
            )
            for item in parsed where seenItemIDs.insert(item.id).inserted {
                collectedItems.append(item)
                if collectedItems.count >= maxItems { break }
            }
        }

        return (Array(collectedItems.prefix(maxItems)), safeToolNames)
    }

    nonisolated private static func extractCloudItems(
        fromToolResult resultObj: [String: Any],
        toolName: String,
        connection: OAuthMCPConnection,
        now: Date,
        limit: Int
    ) -> [CloudIngestedItem] {
        guard limit > 0 else { return [] }
        var items: [CloudIngestedItem] = []

        var textBlocks: [String] = []
        if let contentArray = resultObj["content"] as? [[String: Any]] {
            for entry in contentArray {
                if let text = entry["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textBlocks.append(text)
                } else if let resource = entry["resource"] as? [String: Any],
                          let resText = resource["text"] as? String,
                          !resText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textBlocks.append(resText)
                }
            }
        }
        if textBlocks.isEmpty,
           let structured = resultObj["structuredContent"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let serialized = String(data: data, encoding: .utf8) {
            textBlocks.append(serialized)
        }

        let collectionKeys = ["results", "items", "pages", "meetings", "messages", "channels", "documents", "records", "entries", "notes", "data"]

        for (blockIndex, rawBlock) in textBlocks.enumerated() {
            guard items.count < limit else { break }
            let trimmed = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let jsonData = trimmed.data(using: .utf8),
               let parsedJSON = try? JSONSerialization.jsonObject(with: jsonData) {
                if let array = parsedJSON as? [[String: Any]] {
                    for (idx, dict) in array.enumerated() {
                        guard items.count < limit else { break }
                        if let item = cloudItem(fromDictionary: dict, fallbackIndex: "\(blockIndex)-\(idx)", toolName: toolName, connection: connection, now: now) {
                            items.append(item)
                        }
                    }
                    continue
                } else if let dict = parsedJSON as? [String: Any] {
                    if let matchedKey = collectionKeys.first(where: { (dict[$0] as? [[String: Any]]) != nil }),
                       let nested = dict[matchedKey] as? [[String: Any]] {
                        for (idx, entryDict) in nested.enumerated() {
                            guard items.count < limit else { break }
                            if let item = cloudItem(fromDictionary: entryDict, fallbackIndex: "\(blockIndex)-\(idx)", toolName: toolName, connection: connection, now: now) {
                                items.append(item)
                            }
                        }
                        continue
                    } else if let single = cloudItem(fromDictionary: dict, fallbackIndex: "\(blockIndex)-0", toolName: toolName, connection: connection, now: now) {
                        items.append(single)
                        continue
                    }
                }
            }

            // Plain / Markdown text block
            let lines = trimmed.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let firstLine = (lines.first ?? trimmed)
                .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = firstLine.isEmpty
                ? "\(connection.provider.displayName) · \(toolName)"
                : NativePersonalSources.bounded(firstLine, maximumBytes: 140)
            let digest = SHA256.hash(data: Data("\(toolName):\(blockIndex):\(trimmed)".utf8))
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            items.append(CloudIngestedItem(
                id: "\(toolName)-\(digest)",
                connectionID: connection.id,
                provider: connection.provider,
                title: title,
                subtitle: "\(connection.provider.displayName) (\(connection.accountLabel)) · \(toolName)",
                body: NativePersonalSources.bounded(trimmed, maximumBytes: 8_192),
                timestamp: now
            ))
        }

        return Array(items.prefix(limit))
    }

    nonisolated private static func cloudItem(
        fromDictionary dict: [String: Any],
        fallbackIndex: String,
        toolName: String,
        connection: OAuthMCPConnection,
        now: Date
    ) -> CloudIngestedItem? {
        guard !dict.isEmpty else { return nil }

        let idKeys = ["id", "page_id", "meeting_id", "channel_id", "ts", "uri", "url"]
        var resolvedID: String?
        for key in idKeys {
            if let s = (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                resolvedID = s
                break
            } else if let n = dict[key] as? NSNumber {
                resolvedID = n.stringValue
                break
            }
        }

        let titleKeys = ["title", "name", "subject", "summary", "topic", "heading"]
        var resolvedTitle: String?
        for key in titleKeys {
            if let s = (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                resolvedTitle = s
                break
            }
        }

        let bodyKeys = ["text", "body", "content", "snippet", "transcript", "notes", "description", "preview", "markdown", "url"]
        var bodyParts: [String] = []
        for key in bodyKeys {
            if let s = (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty, s != resolvedTitle, !bodyParts.contains(s) {
                bodyParts.append(s)
            }
        }
        if bodyParts.isEmpty {
            if let serialized = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let jsonText = String(data: serialized, encoding: .utf8) {
                bodyParts.append(jsonText)
            }
        }
        let combinedBody = bodyParts.joined(separator: "\n")
        guard !(resolvedTitle == nil && combinedBody.isEmpty) else { return nil }

        let finalTitle = resolvedTitle ?? NativePersonalSources.bounded(
            combinedBody.split(whereSeparator: \.isNewline).first.map(String.init) ?? "\(connection.provider.displayName) · \(toolName)",
            maximumBytes: 140
        )

        let dateKeys = ["updated_at", "updatedAt", "last_edited_time", "created_at", "createdAt", "date", "start_time", "timestamp", "ts"]
        var resolvedDate = now
        for key in dateKeys {
            if let raw = dict[key] as? String, !raw.isEmpty {
                let parsed = parseFlexibleTimestamp(raw, fallback: now)
                if parsed != now {
                    resolvedDate = parsed
                    break
                }
            } else if let epoch = (dict[key] as? NSNumber)?.doubleValue, epoch > 946_684_800 {
                resolvedDate = Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000.0 : epoch)
                break
            }
        }

        let finalID: String
        if let resolvedID {
            finalID = "\(toolName)-\(resolvedID)"
        } else {
            let digest = SHA256.hash(data: Data("\(toolName):\(fallbackIndex):\(finalTitle):\(combinedBody)".utf8))
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            finalID = "\(toolName)-\(digest)"
        }

        return CloudIngestedItem(
            id: finalID,
            connectionID: connection.id,
            provider: connection.provider,
            title: finalTitle,
            subtitle: "\(connection.provider.displayName) (\(connection.accountLabel)) · \(toolName)",
            body: NativePersonalSources.bounded(combinedBody.isEmpty ? finalTitle : combinedBody, maximumBytes: 8_192),
            timestamp: resolvedDate
        )
    }

    nonisolated private static func parseFlexibleTimestamp(_ raw: String, fallback: Date) -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: trimmed) { return d }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: trimmed) { return d }
        // Microsoft Graph often emits 7-digit fractional seconds without trailing 'Z' (UTC)
        let withoutLongFrac = trimmed.replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
        if let d = iso.date(from: withoutLongFrac + "Z") { return d }
        if let epoch = Double(trimmed), epoch > 946_684_800 {
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000.0 : epoch)
        }
        return fallback
    }
}
