import Foundation

nonisolated enum LMStudioFailure: Error, Equatable, LocalizedError {
    case invalidEndpoint, invalidModel, busy, unavailable, authenticationRequired, httpStatus(Int)
    case inputLimit, responseLimit, invalidUTF8, malformedInput, malformedResponse, malformedHistory, malformedToolCall
    case incompleteStream, truncatedOutput, serverRejected, visionNotVerified, visionProbeFailed
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Use a literal loopback LM Studio address and a port from 1 to 65535."
        case .invalidModel: "Choose an explicit model identifier from the local LM Studio server."
        case .busy: "Another LM Studio request is still settling. Stop or wait for it to finish."
        case .unavailable: "The selected local LM Studio service is unavailable. Start and configure it in LM Studio, then test again."
        case .authenticationRequired: "This LM Studio server requires its own authentication. This keyless local connection has no token and does not use a ChatGPT login."
        case .httpStatus(let value): "The local model service rejected the request (HTTP \(value)). No returned action was dispatched."
        case .inputLimit: "The local model input exceeds this connection’s byte limit. Use a shorter source or narrower task; no request was sent."
        case .responseLimit: "The local model response exceeded its bounded protocol limits."
        case .malformedInput: "The local model input could not be encoded as valid protocol JSON. No request was sent."
        case .invalidUTF8, .malformedResponse: "The local model returned a malformed response. No returned action was dispatched."
        case .malformedHistory: "The model input could not preserve exact tool call/result pairs. No request was sent."
        case .malformedToolCall: "The local model returned invalid or incomplete structured tool calls. Nothing from that reply was dispatched."
        case .incompleteStream: "The local model stream ended before a complete final reply. No partial action was dispatched."
        case .truncatedOutput: "The local model reached an output or context limit. No incomplete action was dispatched."
        case .serverRejected: "The local model service returned an error. No returned action was dispatched."
        case .visionNotVerified: "This local model has not passed its image-input check. Use text or test a vision-capable model first."
        case .visionProbeFailed: "The local model did not read the synthetic image marker exactly. Visual input is not enabled."
        }
    }
}

/// Fixed literal addresses avoid DNS, LAN hosts, userinfo and arbitrary paths.
/// The transport talks only to this chosen loopback service; that does not
/// promise how an arbitrary local server handles data after receiving it.
nonisolated struct LMStudioEndpoint: Codable, Equatable, Sendable {
    enum Host: String, Codable, Sendable { case ipv4 = "127.0.0.1", ipv6 = "::1" }
    let host: Host
    let port: Int
    init(host: Host = .ipv4, port: Int = 1234) throws {
        guard (1...65_535).contains(port) else { throw LMStudioFailure.invalidEndpoint }
        self.host = host; self.port = port
    }
    init(baseURL: String) throws {
        guard let parts = URLComponents(string: baseURL), parts.scheme == "http", parts.user == nil,
              parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["/v1", "/v1/"].contains(parts.percentEncodedPath), let port = parts.port else {
            throw LMStudioFailure.invalidEndpoint
        }
        let host: Host
        switch parts.percentEncodedHost {
        case "127.0.0.1": host = .ipv4
        case "[::1]", "::1": host = .ipv6
        default: throw LMStudioFailure.invalidEndpoint
        }
        try self.init(host: host, port: port)
    }
    private var authority: String { host == .ipv6 ? "[::1]" : "127.0.0.1" }
    var baseURL: URL { URL(string: "http://\(authority):\(port)/v1")! }
    var modelsURL: URL { baseURL.appending(path: "models") }
    var completionsURL: URL { baseURL.appending(path: "chat/completions") }

    private enum CodingKeys: String, CodingKey { case host, port }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: values.decode(Host.self, forKey: .host), port: values.decode(Int.self, forKey: .port))
    }
}

nonisolated struct LMStudioSelection: Equatable, Sendable {
    let endpoint: LMStudioEndpoint
    let modelID: String
    init(endpoint: LMStudioEndpoint, modelID: String) throws {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, modelID.utf8.count <= 256,
              !modelID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LMStudioFailure.invalidModel
        }
        self.endpoint = endpoint; self.modelID = modelID
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.endpoint == rhs.endpoint && LMStudioProtocolID.same(lhs.modelID, rhs.modelID)
    }
}
