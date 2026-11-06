import Foundation
import Testing
@testable import Relay

struct LocalMCPHTTPTests {
    private func request(_ headers: String, body: String = "{}") -> Data {
        Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\(headers)\r\n\r\n\(body)".utf8)
    }

    @Test func incompleteFramesWaitAndAmbiguousFramesAreRejected() {
        let incomplete = LocalMCPHTTP.parse(request("Content-Length: 2", body: "{"))
        if case .incomplete = incomplete {} else { Issue.record("Partial body must await more bytes") }
        for headers in [
            "Content-Length: 2\r\nContent-Length: 3",
            "Content-Length: 2\r\nTransfer-Encoding: chunked",
            "Content-Length: 1",
            "Content-Length: 2\r\nAuthorization: Bearer one\r\nAuthorization: Bearer two",
            "Content-Length: 2\r\n folded header"
        ] {
            if case .rejected(let response) = LocalMCPHTTP.parse(request(headers)) {
                #expect(response.status == 400)
            } else { Issue.record("An ambiguous HTTP frame was not rejected") }
        }
        if case .rejected(let response) = LocalMCPHTTP.parse(request("Content-Length: 16385", body: "")) {
            #expect(response.status == 413)
        } else { Issue.record("Oversized body was not rejected from its header") }
    }

    @Test func rebindingOriginAndMissingAuthorizationNeverConsultNotes() {
        let rpc = Data(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#.utf8)
        let cases: [(String, String?, String?, Int)] = [
            ("example.invalid:8080", nil, "Bearer fixture", 403),
            ("127.0.0.1:8080", "http://example.invalid", "Bearer fixture", 403),
            ("127.0.0.1:8080", nil, nil, 401),
            ("127.0.0.1:8080", nil, "Bearer fixturE", 401)
        ]
        var noteReads = 0
        for (host, origin, auth, status) in cases {
            var headers = ["host": host, "content-type": "application/json"]
            headers["origin"] = origin
            headers["authorization"] = auth
            let response = LocalKnowledgeMCPProtocol.respond(.init(method: "POST", target: "/mcp", headers: headers, body: rpc),
                                                             port: 8080, token: "fixture") { noteReads += 1; return [] }
            #expect(response.status == status)
            #expect(response.body.isEmpty)
        }
        #expect(noteReads == 0)
    }

    @Test func modernHeadersMustMatchEnvelopeAndNamedOperations() throws {
        let version = "2026-07-28"
        let rpc = Data(#"{"jsonrpc":"2.0","id":"probe","method":"tools/call","params":{"name":"search_relay_notes","arguments":{"query":"fixture"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#.utf8)
        var headers = ["host": "127.0.0.1:8080", "content-type": "application/json", "authorization": "Bearer fixture",
                       "mcp-protocol-version": version, "mcp-method": "tools/call", "mcp-name": "different_tool"]
        let bad = LocalKnowledgeMCPProtocol.respond(.init(method: "POST", target: "/mcp", headers: headers, body: rpc),
                                                   port: 8080, token: "fixture") { Issue.record("Mismatched headers must be rejected before scope lookup"); return [] }
        #expect(bad.status == 400)
        let error = try JSONDecoder().decode(JSONValue.self, from: bad.body).object?["error"]?.object
        #expect(error?["code"] == .number(-32020))
        headers["mcp-name"] = "search_relay_notes"
        let good = LocalKnowledgeMCPProtocol.respond(.init(method: "POST", target: "/mcp", headers: headers, body: rpc),
                                                    port: 8080, token: "fixture") { [] }
        #expect(good.status == 200)
        let result = try JSONDecoder().decode(JSONValue.self, from: good.body).object?["result"]?.object
        #expect(result?["resultType"] == .string("complete"))
    }
}

@MainActor
struct LocalKnowledgeMCPServerTests {
    @Test(.timeLimit(.minutes(1))) func realLoopbackServerSharesOnlyApprovedCurrentNotesAndRevokesChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = KnowledgeVaultManager(directoryURL: directory)
        let shared = try vault.saveNote(title: "Parallax", body: "Synthetic marker Café 🌍")
        _ = try vault.saveNote(title: "Private fixture", body: "Unselected content never appears.")
        let server = LocalKnowledgeMCPServer()
        defer { server.stop() }
        #expect(server.endpoint == nil)
        try server.start(notes: [shared])
        let endpoint = try await readyEndpoint(server)
        let token = try #require(server.token)
        #expect(endpoint.host == "127.0.0.1")
        #expect(token.utf8.count == 64)
        if ProcessInfo.processInfo.environment["RELAY_CHECK_MCP_BIND"] == "1" {
            try requireKernelLoopbackBind(endpoint)
        }
        let connection = URLSession(configuration: .ephemeral)
        defer { connection.invalidateAndCancel() }

        let noToken = try await call(connection, endpoint, token: nil, method: "resources/list")
        #expect(noToken.status == 401)
        let discovery = try await call(connection, endpoint, token: token, method: "server/discover", modern: true)
        #expect(discovery.status == 200)
        #expect(discovery.result?["resultType"] == .string("complete"))
        #expect(discovery.result?["cacheScope"] == .string("private"))
        let legacy = try await call(connection, endpoint, token: token, method: "initialize",
                                    params: ["protocolVersion": .string("2025-11-25")])
        #expect(legacy.result?["protocolVersion"] == .string("2025-11-25"))

        let list = try await call(connection, endpoint, token: token, method: "resources/list", modern: true)
        let resources = try #require(list.result?["resources"])
        guard case .array(let notes) = resources else { Issue.record("Expected resources"); return }
        #expect(notes.count == 1)
        let resource = try #require(notes.first?.object)
        let uri = try #require(resource["uri"]?.string)
        #expect(resource["name"] == .string("Parallax"))
        #expect(uri.hasPrefix("relay-note://local/"))
        #expect(!String(decoding: list.data, as: UTF8.self).contains(directory.path))

        let read = try await call(connection, endpoint, token: token, method: "resources/read",
                                  params: ["uri": .string(uri)], modern: true, name: uri)
        #expect(read.status == 200)
        let content = try #require(read.result?["contents"])
        guard case .array(let items) = content else { Issue.record("Expected Markdown content"); return }
        #expect(items.first?.object?["text"]?.string == shared.sharingMarkdown)
        let search = try await call(connection, endpoint, token: token, method: "tools/call",
                                    params: ["name": .string("search_relay_notes"),
                                             "arguments": .object(["query": .string("cafe")])],
                                    modern: true, name: "search_relay_notes")
        #expect(String(decoding: search.data, as: UTF8.self).contains("Parallax"))

        let connector = DirectMCPConnector()
        defer { connector.disconnect() }
        await connector.connect(address: endpoint.absoluteString, token: token)
        #expect(connector.protocolVersion == "2026-07-28")
        #expect(connector.resources.map(\.uri) == [uri])
        #expect(connector.tools.map(\.name) == ["search_relay_notes"])
        connector.prepareResource(uri)
        let review = try #require(connector.preview)
        await connector.performReviewedRead(review.id)
        #expect(connector.output?.contains("Synthetic marker Café 🌍") == true)

        let changed = try vault.saveNote(title: "Parallax", body: "Changed note content", replacing: shared)
        let revoked = try await call(connection, endpoint, token: token, method: "resources/read",
                                     params: ["uri": .string(uri)], modern: true, name: uri)
        #expect(revoked.status == 404)
        #expect(!String(decoding: revoked.data, as: UTF8.self).contains("Changed note content"))
        _ = try vault.saveNote(title: shared.title, body: shared.body, replacing: changed)
        let restored = try await call(connection, endpoint, token: token, method: "resources/read",
                                      params: ["uri": .string(uri)], modern: true, name: uri)
        #expect(restored.status == 404)

        server.stop()
        #expect(server.token == nil)
        #expect(server.endpoint == nil)
        #expect(!server.isActive)
    }

    private func requireKernelLoopbackBind(_ endpoint: URL) throws {
        let port = try #require(endpoint.port)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(ProcessInfo.processInfo.processIdentifier)", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let listeners = output.split(whereSeparator: \.isNewline).filter { $0.contains("(LISTEN)") }
        #expect(listeners.count == 1)
        #expect(listeners.first?.contains("127.0.0.1:\(port) (LISTEN)") == true)
    }

    private func readyEndpoint(_ server: LocalKnowledgeMCPServer) async throws -> URL {
        for _ in 0..<100 where server.endpoint == nil && server.isActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(server.endpoint, Comment(rawValue: server.status))
    }

    private func call(_ session: URLSession, _ url: URL, token: String?, method: String,
                      params: [String: JSONValue] = [:], modern: Bool = false,
                      name: String? = nil) async throws -> (status: Int, data: Data, result: [String: JSONValue]?) {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var params = params
        if modern {
            request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
            if let name { request.setValue(name, forHTTPHeaderField: "Mcp-Name") }
            params["_meta"] = .object([
                "io.modelcontextprotocol/protocolVersion": .string("2026-07-28"),
                "io.modelcontextprotocol/clientCapabilities": .object([:])
            ])
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": .object(params)
        ]))
        let (data, response) = try await session.data(for: request)
        let status = try #require((response as? HTTPURLResponse)?.statusCode)
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        return (status, data, decoded?.object?["result"]?.object)
    }
}
