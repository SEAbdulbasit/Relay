import Foundation
import Testing
@testable import Relay

@MainActor
struct DirectMCPConnectorTests {
    @Test func onlyExactHTTPSOrLiteralLoopbackEndpointsCanReceiveBearerTokens() throws {
        for address in ["http://localhost:9001/mcp", "http://127.0.0.2:9001/mcp", "http://fixture.invalid/mcp", "file:///tmp/mcp",
                        "https://person:secret@fixture.invalid/mcp", "https://fixture.invalid/mcp?secret=1", "https://fixture.invalid/mcp#other",
                        "https://fixture.invalid/%0d%0a", "https://fixture.invalid/%5Cmcp"] {
            #expect(throws: DirectMCPFailure.self) { try DirectMCPEndpoint(address, token: "relay-fixture-token") }
        }
        #expect(try DirectMCPEndpoint("https://fixture.invalid/mcp", token: "token.123").bearer == "token.123")
        #expect(try DirectMCPEndpoint("http://[::1]:9001/mcp", token: "").bearer == nil)
        #expect(try DirectMCPEndpoint("http://127.0.0.1:9001/mcp", token: "").url.host == "127.0.0.1")
        #expect(throws: DirectMCPFailure.self) { try DirectMCPEndpoint("https://fixture.invalid/mcp", token: "token\r\nInjected: header") }
    }

    @Test func modernRequestBindsURLMetadataNameAndUnicodeArguments() throws {
        let endpoint = try DirectMCPEndpoint("https://fixture.invalid/mcp", token: "relay-fixture-token")
        let wire = DirectMCPWire(version: DirectMCPWire.currentVersion, sessionID: nil)
        let uri = "fixture://reports/café"
        let request = try wire.request(endpoint: endpoint, method: .read, id: "fixture-read",
                                       parameters: ["uri": .string(uri)])
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint.url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer relay-fixture-token")
        #expect(request.value(forHTTPHeaderField: "Mcp-Method") == "resources/read")
        #expect(request.value(forHTTPHeaderField: "Mcp-Name") == "=?base64?\(Data(uri.utf8).base64EncodedString())?=")
        #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(body.object?["params"]?.object?["uri"] == .string(uri))
        #expect(body.object?["params"]?.object?["_meta"]?.object?["io.modelcontextprotocol/protocolVersion"] == .string("2026-07-28"))
        #expect(!body.pretty.contains("relay-fixture-token"))
    }

    @Test func argumentPreviewRejectsMissingFieldsExtraFieldsAndInexactLargeNumbers() throws {
        let schema: [String: JSONValue] = ["required": .array([.string("limit")]), "additionalProperties": .bool(false),
                                          "properties": .object(["limit": .object(["type": .string("integer")])])]
        for invalid in ["{}", "[]", #"{"limit":4,"extra":1}"#, #"{"limit":9007199254740993}"#] {
            #expect(throws: DirectMCPFailure.self) { try DirectMCPConnector.parseArguments(invalid, schema: schema) }
        }
        #expect(try DirectMCPConnector.parseArguments(#"{"limit":42}"#, schema: schema) == ["limit": .number(42)])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_DIRECT_MCP_FIXTURE"] != nil))
    func loopbackModernLegacyReadsSSEAndRedirectIsolation() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["RELAY_DIRECT_MCP_FIXTURE"])
        let endpoint = try DirectMCPEndpoint(raw, token: "")
        try #require(endpoint.url.scheme == "http" && endpoint.url.host == "127.0.0.1" && endpoint.url.port != nil
            && endpoint.url.path.isEmpty)
        let base = endpoint.url
        let token = "relay-fixture-token"
        let selected = "fixture://reports/selected"
        let before = try await oracle(base)
        let modern = DirectMCPConnector()
        await modern.connect(address: base.appendingPathComponent("mcp").absoluteString, token: token)
        #expect(modern.protocolVersion == "2026-07-28", Comment(rawValue: modern.status))
        #expect(modern.resources.map(\.id) == [selected, "fixture://reports/other"])
        #expect(modern.tools.map(\.id) == ["read_fixture"])
        modern.prepareTool("write_fixture", arguments: "{}")
        #expect(modern.preview == nil)

        modern.prepareResource(selected)
        let resource = try #require(modern.preview)
        #expect(resource.target == selected)
        await modern.performReviewedRead(UUID())
        #expect(modern.output == nil)
        await modern.performReviewedRead(resource.id)
        #expect(modern.output == "Synthetic selected report", Comment(rawValue: modern.status))
        await modern.performReviewedRead(resource.id)
        #expect(modern.status.contains("fresh preview"))

        modern.prepareTool("read_fixture", arguments: #"{"region":"Café"}"#)
        let tool = try #require(modern.preview)
        #expect(tool.arguments?.contains("Café") == true)
        await modern.performReviewedRead(tool.id)
        #expect(modern.output == "Synthetic SSE result · Café", Comment(rawValue: modern.status))
        modern.disconnect()
        #expect(modern.endpoint == nil && modern.output == nil && modern.preview == nil)

        let legacy = DirectMCPConnector()
        await legacy.connect(address: base.appendingPathComponent("legacy").absoluteString, token: token)
        #expect(legacy.protocolVersion == "2025-11-25", Comment(rawValue: legacy.status))
        legacy.prepareResource(selected)
        await legacy.performReviewedRead(try #require(legacy.preview?.id))
        #expect(legacy.output == "Synthetic selected report", Comment(rawValue: legacy.status))
        legacy.disconnect()

        let redirect = DirectMCPConnector()
        await redirect.connect(address: base.appendingPathComponent("redirect").absoluteString, token: token)
        #expect(redirect.endpoint == nil)
        #expect(redirect.status.contains("redirected"))

        let after = try await oracle(base)
        func delta(_ event: String) -> Int { after[event, default: 0] - before[event, default: 0] }
        for event in ["modern:resources/read", "modern:tools/call", "legacy:server/discover", "legacy:initialize",
                      "legacy:notifications/initialized", "legacy:resources/read", "redirect"] {
            #expect(delta(event) == 1, Comment(rawValue: event))
        }
        for event in ["redirect_sink", "forwarded_bearer", "bad_bearer", "bad_protocol"] {
            #expect(delta(event) == 0, Comment(rawValue: event))
        }
    }

    private func oracle(_ base: URL) async throws -> [String: Int] {
        let url = base.appendingPathComponent("state")
        let (data, response) = try await URLSession.shared.data(from: url)
        try #require((response as? HTTPURLResponse)?.statusCode == 200 && response.url == url)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
}
