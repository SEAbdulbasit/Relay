import Foundation

nonisolated enum DirectMCPFailure: LocalizedError {
    case endpoint, token, redirect, authorization, http(Int), reply, responseTooLarge, sessionChanged
    case version, unsupportedInput, review, arguments, noText, toolError
    case rpc(code: Int, status: Int, supported: [String])

    var errorDescription: String? {
        switch self {
        case .endpoint: "Enter an exact HTTPS MCP endpoint, or HTTP at 127.0.0.1 or [::1]. Leave credentials, query parameters, and fragments out of the URL."
        case .token: "Enter the bearer token by itself, without whitespace, up to 4096 ASCII characters."
        case .redirect: "The endpoint redirected the request. Enter the final MCP endpoint explicitly and connect again."
        case .authorization: "The endpoint refused access. Check the token and its permissions, then reconnect."
        case .http(let status): "The MCP endpoint returned HTTP \(status). Check the endpoint and connection."
        case .reply: "The MCP endpoint returned an invalid or mismatched response."
        case .responseTooLarge: "The MCP response exceeded Relay’s size limit."
        case .sessionChanged: "The MCP session expired or changed. Reconnect and review a fresh request."
        case .version: "The endpoint did not offer a supported Streamable HTTP protocol version."
        case .unsupportedInput: "The server requested another input round. Relay supports single reviewed reads in this panel."
        case .review: "This read needs a fresh preview from the current connection."
        case .arguments: "Enter a JSON object up to 4096 bytes that meets the tool’s input requirements."
        case .noText: "The endpoint completed the read without returning supported text or structured data."
        case .toolError: "The endpoint reported that the selected tool failed."
        case .rpc(let code, _, _): "The endpoint returned MCP error \(code)."
        }
    }

    var allowsLegacyDiscovery: Bool {
        switch self {
        case .http(400): true
        case .rpc(-32022, _, let supported): supported.contains(where: DirectMCPWire.legacyVersions.contains)
        case .rpc(let code, 400, _): ![-32020, -32021].contains(code)
        default: false
        }
    }
}

nonisolated struct DirectMCPEndpoint: Sendable {
    let url: URL
    let bearer: String?

    init(_ address: String, token: String) throws {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 2048, !input.contains("\\"),
              input.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let decoded = input.removingPercentEncoding, !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              let components = URLComponents(string: input), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty, !host.contains("%"), !host.contains("\\"),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) != false,
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host)),
              let url = components.url else { throw DirectMCPFailure.endpoint }
        let tokenValue = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearerBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/=".utf8)
        guard tokenValue.utf8.count <= 4096, tokenValue.utf8.allSatisfy(bearerBytes.contains) else { throw DirectMCPFailure.token }
        self.url = url
        bearer = tokenValue.isEmpty ? nil : tokenValue
    }
}

nonisolated struct DirectMCPWire: Sendable {
    static let currentVersion = "2026-07-28"
    static let legacyVersions: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26"]
    let version: String
    let sessionID: String?

    var modern: Bool { version == Self.currentVersion }

    enum Method: String {
        case discover = "server/discover", initialize, initialized = "notifications/initialized"
        case listResources = "resources/list", listTools = "tools/list"
        case read = "resources/read", call = "tools/call"

        var targetKey: String? { self == .read ? "uri" : self == .call ? "name" : nil }
    }

    static func encodedHeader(_ value: String) -> String {
        let plain = value.utf8.allSatisfy { (32...126).contains($0) || $0 == 9 }
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !(value.hasPrefix("=?base64?") && value.hasSuffix("?="))
        return plain ? value : "=?base64?" + Data(value.utf8).base64EncodedString() + "?="
    }

    static func validSession(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    func request(endpoint: DirectMCPEndpoint, method: Method, id: String?, parameters: [String: JSONValue],
                 parameterHeaders: [String: String] = [:]) throws -> URLRequest {
        var params = parameters
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method.rawValue)]
        if let id { message["id"] = .string(id) }
        var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token = endpoint.bearer { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if method != .initialize { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        if modern {
            params["_meta"] = .object([
                "io.modelcontextprotocol/protocolVersion": .string(version),
                "io.modelcontextprotocol/clientInfo": .object(["name": .string("Relay"), "version": .string("0.1.0")]),
                "io.modelcontextprotocol/clientCapabilities": .object([:])
            ])
            request.setValue(method.rawValue, forHTTPHeaderField: "Mcp-Method")
            if let key = method.targetKey, let value = parameters[key]?.string {
                request.setValue(Self.encodedHeader(value), forHTTPHeaderField: "Mcp-Name")
            }
            for (name, value) in parameterHeaders { request.setValue(Self.encodedHeader(value), forHTTPHeaderField: "Mcp-Param-\(name)") }
        } else if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if !params.isEmpty { message["params"] = .object(params) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(message))
        return request
    }
}

/// Ephemeral, exact-origin Streamable HTTP. A redirect is surfaced to the user;
/// credentials, MCP state, and resource URIs are never forwarded to another URL.
nonisolated final class DirectMCPTransport: Sendable {
    struct Reply: Sendable {
        let result: [String: JSONValue]
        let sessionID: String?
    }

    private let endpoint: DirectMCPEndpoint
    private let session: URLSession
    private let maximumBytes = 1_048_576

    init(endpoint: DirectMCPEndpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        if endpoint.url.scheme?.lowercased() == "http" {
            config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                                "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        }
        session = URLSession(configuration: config, delegate: MCPRejectRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func invalidate() { session.invalidateAndCancel() }

    @concurrent func send(_ method: DirectMCPWire.Method, wire: DirectMCPWire, parameters: [String: JSONValue] = [:],
                          parameterHeaders: [String: String] = [:]) async throws -> Reply {
        let id = method == .initialized ? nil : UUID().uuidString
        let request = try wire.request(endpoint: endpoint, method: method, id: id, parameters: parameters, parameterHeaders: parameterHeaders)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw DirectMCPFailure.reply }
        let status = http.statusCode
        guard http.url == endpoint.url, !(300..<400).contains(status) else { throw DirectMCPFailure.redirect }
        if status == 401 || status == 403 { throw DirectMCPFailure.authorization }
        if status == 404, wire.sessionID != nil { throw DirectMCPFailure.sessionChanged }
        let receivedSession = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        if let receivedSession, !wire.modern {
            guard DirectMCPWire.validSession(receivedSession), method == .initialize || receivedSession == wire.sessionID else {
                throw DirectMCPFailure.sessionChanged
            }
        }
        if id == nil {
            guard status == 202 else { throw DirectMCPFailure.http(status) }
            return Reply(result: [:], sessionID: nil)
        }
        guard status == 200 || status == 400 || status == 404 else { throw DirectMCPFailure.http(status) }
        guard response.expectedContentLength <= maximumBytes else { throw DirectMCPFailure.responseTooLarge }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        let document: JSONValue
        switch mime {
        case "application/json":
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw DirectMCPFailure.responseTooLarge }
                data.append(byte)
            }
            guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw status == 200 ? DirectMCPFailure.reply : DirectMCPFailure.http(status)
            }
            document = decoded
        case "text/event-stream": document = try await readSSE(bytes)
        default: throw status == 200 ? DirectMCPFailure.reply : DirectMCPFailure.http(status)
        }
        try Task.checkCancellation()
        guard let message = document.object, message["jsonrpc"]?.string == "2.0",
              message["id"]?.string == id || (status == 400 && message["error"] != nil && (message["id"] == nil || message["id"] == .null)) else {
            throw DirectMCPFailure.reply
        }
        if let error = message["error"]?.object, let code = error["code"]?.int, message["result"] == nil {
            let supported: [String]
            if case .array(let values) = error["data"]?.object?["supported"] { supported = values.prefix(10).compactMap(\.string) }
            else { supported = [] }
            throw DirectMCPFailure.rpc(code: code, status: status, supported: supported)
        }
        guard status == 200, let result = message["result"]?.object, message["error"] == nil else { throw DirectMCPFailure.reply }
        if result["inputRequests"] != nil || result["resultType"]?.string == "input_required" { throw DirectMCPFailure.unsupportedInput }
        if wire.modern, let type = result["resultType"]?.string, type != "complete" { throw DirectMCPFailure.reply }
        return Reply(result: result, sessionID: wire.modern ? nil : receivedSession)
    }

    private func readSSE(_ bytes: URLSession.AsyncBytes) async throws -> JSONValue {
        var count = 0
        var line = Data()
        var frame = Data()
        for try await byte in bytes {
            count += 1
            guard count <= maximumBytes else { throw DirectMCPFailure.responseTooLarge }
            if byte != 10 { line.append(byte); continue }
            if line.last == 13 { line.removeLast() }
            if line.isEmpty, !frame.isEmpty {
                let message = try JSONDecoder().decode(JSONValue.self, from: frame)
                frame.removeAll(keepingCapacity: true)
                guard let object = message.object, object["jsonrpc"]?.string == "2.0" else { throw DirectMCPFailure.reply }
                if object["result"] != nil || object["error"] != nil { return message }
                if object["id"] != nil || object["method"]?.string == nil { throw DirectMCPFailure.reply }
            } else if line.starts(with: Data("data:".utf8)) {
                var payload = line.dropFirst(5)
                if payload.first == 32 { payload = payload.dropFirst() }
                if !frame.isEmpty { frame.append(10) }
                frame.append(contentsOf: payload)
            }
            line.removeAll(keepingCapacity: true)
        }
        throw DirectMCPFailure.reply
    }
}

nonisolated private final class MCPRejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
