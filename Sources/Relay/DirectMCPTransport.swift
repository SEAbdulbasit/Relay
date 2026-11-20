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
    /// Optional payload-free diagnostic of actual task lifetime events. It cannot
    /// supply a task, response, completion verdict or request authority.
    struct CompletionEvent: Sendable {
        enum Phase: Sendable, Equatable { case created, completed, releasedAfterCompletion }
        let phase: Phase
        let taskIdentifier: Int
    }
    struct Reply: Sendable {
        let result: [String: JSONValue]
        let sessionID: String?
    }

    private let endpoint: DirectMCPEndpoint
    private let session: URLSession
    private let taskDelegate: MCPDataTaskDelegate
    private let maximumBytes = 1_048_576
    private let lifetime = MCPTransportLifetime()
    private let completionAudit: (@Sendable (CompletionEvent) -> Void)?

    init(endpoint: DirectMCPEndpoint, completionAudit: (@Sendable (CompletionEvent) -> Void)? = nil) {
        self.endpoint = endpoint
        self.completionAudit = completionAudit
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
        let taskDelegate = MCPDataTaskDelegate()
        self.taskDelegate = taskDelegate
        session = URLSession(configuration: config, delegate: taskDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func invalidate() {
        let shouldCancel = taskDelegate.close()
        lifetime.invalidate()
        if shouldCancel { session.invalidateAndCancel() }
    }
    func drain() async { await lifetime.drain() }

    @concurrent func send(_ method: DirectMCPWire.Method, wire: DirectMCPWire, parameters: [String: JSONValue] = [:],
                          parameterHeaders: [String: String] = [:],
                          sourceAuthorization: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> Reply {
        let operation = try lifetime.begin()
        defer { lifetime.finish(operation) }
        do {
            let reply = try await sendBody(method, wire: wire, parameters: parameters,
                parameterHeaders: parameterHeaders, sourceAuthorization: sourceAuthorization)
            try await sourceAuthorization?(); try Task.checkCancellation()
            return reply
        } catch {
            try await sourceAuthorization?(); try Task.checkCancellation()
            throw error
        }
    }

    @concurrent private func sendBody(_ method: DirectMCPWire.Method, wire: DirectMCPWire,
        parameters: [String: JSONValue], parameterHeaders: [String: String],
        sourceAuthorization: (@MainActor @Sendable () async throws -> Void)?) async throws -> Reply {
        let id = method == .initialized ? nil : UUID().uuidString
        let request = try wire.request(endpoint: endpoint, method: method, id: id, parameters: parameters, parameterHeaders: parameterHeaders)
        try await sourceAuthorization?(); try Task.checkCancellation()
        let operation = try taskDelegate.prepare(session: session, request: request,
            maximumBytes: maximumBytes, audit: completionAudit)
        return try await withTaskCancellationHandler {
            let result: Result<Reply, any Error>
            do {
                try taskDelegate.resume(operation)
                let response = try await operation.response()
                result = .success(try await readReply(operation.bytes, response: response, id: id, wire: wire, method: method))
            } catch {
                result = .failure(error)
            }
            // Header errors, cancellation and early SSE return all settle the
            // actual registered task before the outer logical lifetime ends.
            await operation.cancelAndWait()
            return try result.get()
        } onCancel: {
            operation.task.cancel()
        }
    }

    private func readReply(_ bytes: MCPResponseBytes, response: URLResponse, id: String?,
        wire: DirectMCPWire, method: DirectMCPWire.Method) async throws -> Reply {
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

    private func readSSE(_ bytes: MCPResponseBytes) async throws -> JSONValue {
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

/// Maps the actual suspended task before resume. The session delegate is
/// installed before any creation and observes completion for that exact task.
nonisolated private final class MCPDataTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var requests: [Int: MCPDataRequest] = [:]

    func prepare(session: URLSession, request: URLRequest, maximumBytes: Int,
                 audit: (@Sendable (DirectMCPTransport.CompletionEvent) -> Void)?) throws -> MCPDataRequest {
        let operation = try lock.withLock {
            guard accepting else { throw CancellationError() }
            // This overload returns a suspended task and uses delegate delivery
            // for headers, bytes and completion. There is no async creation gap.
            let task = session.dataTask(with: request)
            let operation = MCPDataRequest(task: task, maximumBytes: maximumBytes, audit: audit)
            requests[task.taskIdentifier] = operation
            return operation
        }
        operation.publishCreation()
        return operation
    }

    func close() -> Bool {
        lock.withLock {
            guard accepting else { return false }
            accepting = false
            return true
        }
    }

    /// Registration alone does not admit a transfer. Close and the exact
    /// suspended task's resume have one ordering under the admission lock.
    func resume(_ operation: MCPDataRequest) throws {
        try lock.withLock {
            try Task.checkCancellation()
            guard accepting, requests[operation.task.taskIdentifier] === operation,
                  operation.task.state == .suspended else { throw CancellationError() }
            operation.task.resume()
        }
    }

    private func operation(for task: URLSessionTask) -> MCPDataRequest? {
        lock.withLock {
            guard let operation = requests[task.taskIdentifier], operation.task === task else { return nil }
            return operation
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let operation = operation(for: dataTask), operation.receive(response) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        operation(for: dataTask)?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let operation = lock.withLock { () -> MCPDataRequest? in
            guard let operation = requests[task.taskIdentifier], operation.task === task else { return nil }
            requests.removeValue(forKey: task.taskIdentifier)
            return operation
        }
        operation?.completeFromDelegate(error)
    }
}

/// Flattens bounded delegate chunks for the existing byte-oriented parsers.
nonisolated private struct MCPResponseBytes: AsyncSequence, Sendable {
    let chunks: AsyncThrowingStream<Data, any Error>

    struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: AsyncThrowingStream<Data, any Error>.Iterator
        private var data = Data()
        private var offset = 0

        init(chunks: AsyncThrowingStream<Data, any Error>.Iterator) { self.chunks = chunks }

        mutating func next() async throws -> UInt8? {
            try await next(isolation: nil)
        }

        mutating func next(isolation actor: isolated (any Actor)?) async throws -> UInt8? {
            if offset == data.endIndex {
                guard let chunk = try await chunks.next(isolation: actor) else { return nil }
                data = chunk
                offset = chunk.startIndex
            }
            defer { offset += 1 }
            return data[offset]
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks.makeAsyncIterator()) }
}

nonisolated private final class MCPDataRequest: @unchecked Sendable {
    let task: URLSessionDataTask
    let bytes: MCPResponseBytes
    private let body: AsyncThrowingStream<Data, any Error>.Continuation
    private let audit: (@Sendable (DirectMCPTransport.CompletionEvent) -> Void)?
    private let lock = NSLock()
    private let maximumBytes: Int
    private var received = 0
    private var bodyLimited = false
    private var header: Result<URLResponse, any Error>?
    private var headerWaiter: CheckedContinuation<URLResponse, any Error>?
    private var creationPublished = false
    private var completionBeforeCreation: Result<Void, any Error>?
    private var settled = false
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []

    init(task: URLSessionDataTask, maximumBytes: Int,
         audit: (@Sendable (DirectMCPTransport.CompletionEvent) -> Void)?) {
        self.task = task
        self.maximumBytes = maximumBytes
        self.audit = audit
        // receive(_:) admits at most maximumBytes total and skips empty chunks.
        // Both the queued payload and the number of queued chunks are bounded.
        let stream = AsyncThrowingStream<Data, any Error>.makeStream()
        bytes = MCPResponseBytes(chunks: stream.stream)
        body = stream.continuation
    }

    func publishCreation() {
        audit?(.init(phase: .created, taskIdentifier: task.taskIdentifier))
        let pending = lock.withLock {
            creationPublished = true
            let pending = completionBeforeCreation
            completionBeforeCreation = nil
            return pending
        }
        // Invalidation can cancel the registered suspended task before resume.
        if let pending { publishCompletion(pending) }
    }

    func response() async throws -> URLResponse {
        try await withCheckedThrowingContinuation { waiter in
            let ready = lock.withLock { () -> Result<URLResponse, any Error>? in
                if let header { return header }
                guard headerWaiter == nil else { return .failure(DirectMCPFailure.reply) }
                headerWaiter = waiter
                return nil
            }
            if let ready { waiter.resume(with: ready) }
        }
    }

    func receive(_ response: URLResponse) -> Bool {
        let result = lock.withLock { () -> (Bool, CheckedContinuation<URLResponse, any Error>?) in
            guard header == nil, !settled else { return (false, nil) }
            header = .success(response)
            let waiter = headerWaiter
            headerWaiter = nil
            return (true, waiter)
        }
        result.1?.resume(returning: response)
        return result.0
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        let accepted = lock.withLock { () -> Int? in
            guard !bodyLimited, !settled else { return nil }
            let count = min(data.count, maximumBytes - received)
            received += count
            bodyLimited = count < data.count
            return count
        }
        guard let accepted else { return }
        if accepted == data.count {
            body.yield(data)
            return
        }
        // Preserve a complete SSE frame that falls inside the old byte limit
        // even when the same SDK chunk also contains excess trailing bytes.
        if accepted > 0 {
            let prefix = data.subdata(in: data.startIndex..<(data.startIndex + accepted))
            body.yield(prefix)
        }
        body.finish(throwing: DirectMCPFailure.responseTooLarge)
        task.cancel()
    }

    func completeFromDelegate(_ error: (any Error)?) {
        let result: Result<Void, any Error> = error.map { .failure($0) } ?? .success(())
        let ready = lock.withLock {
            guard creationPublished else {
                completionBeforeCreation = result
                return false
            }
            return true
        }
        if ready { publishCompletion(result) }
    }

    private func publishCompletion(_ result: Result<Void, any Error>) {
        audit?(.init(phase: .completed, taskIdentifier: task.taskIdentifier))
        let error: (any Error)?
        switch result {
        case .success: error = nil
        case .failure(let failure): error = failure
        }
        body.finish(throwing: error)
        let waiters = lock.withLock {
            let missingHeader = error ?? DirectMCPFailure.reply
            if header == nil { header = .failure(missingHeader) }
            let response = headerWaiter
            headerWaiter = nil
            settled = true
            let terminal = settlementWaiters
            settlementWaiters.removeAll()
            return (response, terminal, missingHeader)
        }
        waiters.0?.resume(throwing: waiters.2)
        for waiter in waiters.1 { waiter.resume() }
    }

    func cancelAndWait() async {
        task.cancel()
        await withCheckedContinuation { waiter in
            let ready = lock.withLock {
                if settled { return true }
                settlementWaiters.append(waiter)
                return false
            }
            if ready { waiter.resume() }
        }
        audit?(.init(phase: .releasedAfterCompletion, taskIdentifier: task.taskIdentifier))
    }
}

/// Metadata-only physical request accounting; invalidation never remints an
/// existing URLSession request. No request, token, endpoint or payload retained.
nonisolated private final class MCPTransportLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var operations = Set<UUID>()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func begin() throws -> UUID {
        try lock.withLock {
            guard !invalidated else { throw CancellationError() }
            let id = UUID(); operations.insert(id); return id
        }
    }
    func invalidate() { lock.withLock { invalidated = true } }
    func finish(_ id: UUID) {
        let resume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            operations.remove(id)
            guard operations.isEmpty else { return [] }
            let result = waiting; waiting.removeAll(); return result
        }
        for continuation in resume { continuation.resume() }
    }
    func drain() async {
        await withCheckedContinuation { next in
            let immediate = lock.withLock { () -> Bool in
                if operations.isEmpty { return true }; waiting.append(next); return false
            }
            if immediate { next.resume() }
        }
    }
}
