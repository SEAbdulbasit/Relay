import Foundation
import Testing
@testable import Relay

/// Distinct default-off actual URLSession/owned loopback gate for CustomResponses.
/// Sends only synthetic strings and a fake key to the owned loopback python server.
@MainActor @Suite(.serialized) struct CustomResponsesLoopbackHTTPTests {
    private func wait(_ body: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !body() {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < end)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func choice(_ fixture: Fixture, model: String) throws -> CustomResponsesConfiguration {
        try .init(
            baseURL: fixture.endpoint.baseURLString,
            modelID: model,
            reasoningEffort: "low",
            requiresAPIKey: true,
            uploadsApproved: false
        )
    }

    private func client(_ fixture: Fixture) -> CustomResponsesClient {
        let store = CustomResponsesCredentials.Store.memory(
            for: fixture.endpoint,
            key: Data("SYNTHETIC-RESPONSES-KEY-4926".utf8)
        )
        return CustomResponsesClient(
            transport: CustomResponsesHTTPTransport.make(),
            credentials: CustomResponsesCredentials(store: store)
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_CUSTOM_RESPONSES_LOOPBACK_PROTOCOL_TEST"] == "1"))
    func actualOwnedHTTPBearerSplitUTF8NamespaceToolPairAndNoRedirects() async throws {
        let f = try await Fixture.start()
        defer { f.stop() }
        let c = client(f)

        let models = try await c.listModels(configuration: choice(f, model: "owned/tool"))
        #expect(models.contains("owned/tool"))

        let messages = [ModelMessage(role: "user", content: "Synthetic protocol only")]
        let unicode = try await c.complete(messages: messages, tools: [], configuration: choice(f, model: "owned/unicode"))
        #expect(unicode.content == "Café 🌍 العربية")

        let tools = [ToolDefinition(name: "mcp__calc__calculate", description: "Synthetic", parameters: .object(["type": .string("object")]))]
        let namespaces = [
            CustomResponsesNamespaceDefinition(
                name: "mcp__calc",
                description: "Synthetic namespace",
                tools: [ToolDefinition(name: "calculate", description: "Synthetic", parameters: .object(["type": .string("object")]))]
            )
        ]
        let first = try await c.complete(messages: messages, tools: tools, namespaces: namespaces, configuration: choice(f, model: "owned/tool"))
        let call = try #require(first.toolCalls.first)
        #expect(call.id.utf8.elementsEqual("owned-call-🌍".utf8))
        #expect(call.name == "mcp__calc__calculate")
        #expect(call.arguments == ["expression": .string("6*7")])

        let final = try await c.complete(
            messages: messages + [
                .init(role: "assistant", content: first.content, toolCalls: first.toolCalls),
                .init(role: "tool", content: "42", toolCallID: call.id, toolName: call.name)
            ],
            tools: tools,
            namespaces: namespaces,
            configuration: choice(f, model: "owned/tool")
        )
        #expect(final.content == "42" && f.events().contains("exact-tool-pair"))

        await #expect(throws: CustomResponsesFailure.requestRejected) {
            _ = try await c.complete(messages: messages, tools: [], configuration: choice(f, model: "owned/redirect"))
        }
        #expect(f.events().contains("exact-own-key") && !f.events().contains("wrong-credential") && !f.events().contains("redirect-followed"))
        await c.drain()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_CUSTOM_RESPONSES_LOOPBACK_PROTOCOL_TEST"] == "1"))
    func actualOwnedSocketCancellationDrainsWithoutAcceptingPartialReply() async throws {
        let f = try await Fixture.start()
        defer { f.stop() }
        let c = client(f)
        let selected = try choice(f, model: "owned/cancel")
        let pending = Task {
            try await c.complete(messages: [.init(role: "user", content: "Owned cancellation fixture")], tools: [], configuration: selected)
        }
        do {
            try await wait { f.events().contains("cancel-started") }
            pending.cancel()
            await #expect(throws: CancellationError.self) { try await pending.value }
            await c.drain()
        } catch {
            pending.cancel()
            _ = await pending.result
            await c.drain()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_CUSTOM_RESPONSES_LOOPBACK_PROTOCOL_TEST"] == "1"))
    func actualURLSessionKeylessLoopbackStillEnforcesRequiredLocalAndAllRemoteKeys() async throws {
        let f = try await Fixture.start()
        defer { f.stop() }
        let endpoint = try CustomResponsesEndpoint(parsing: f.endpoint.baseURLString.replacingOccurrences(of: "/v1", with: "/keyless/v1"))
        let c = CustomResponsesClient(transport: CustomResponsesHTTPTransport.make(), credentials: .init(store: .memory()))
        let selected = try CustomResponsesConfiguration(baseURL: endpoint.baseURLString, modelID: "owned/unicode", requiresAPIKey: false, uploadsApproved: false)
        do {
            let models = try await c.listModels(configuration: selected)
            #expect(models == ["owned/unicode"])
            let reply = try await c.complete(messages: [.init(role: "user", content: "Owned keyless loopback protocol")], tools: [], configuration: selected)
            #expect(reply.content == "Café 🌍 العربية" && reply.toolCalls.isEmpty)
            #expect(f.events().contains("keyless-models") && f.events().contains("keyless-responses") && !f.events().contains("keyless-ambient-credential"))
            var required = selected; required.requiresAPIKey = true
            await #expect(throws: CustomResponsesFailure.missingAPIKey) { _ = try await c.listModels(configuration: required) }
            let remote = try CustomResponsesEndpoint(parsing: "https://owned-remote.example/v1")
            var request = URLRequest(url: remote.modelsURL); request.httpMethod = "GET"; request.httpShouldHandleCookies = false
            #expect(throws: CustomResponsesFailure.missingAPIKey) { try CustomResponsesHTTPTransport.validateOutboundRequest(request) }
            #expect(throws: CustomResponsesFailure.missingAPIKey) { try CustomResponsesHTTPTransport.validateOutboundRequest(request, requiresAPIKey: false) }
            await c.drain()
        } catch { await c.drain(); throw error }
    }

    @MainActor private final class Fixture {
        let directory: URL
        let process: Process
        let endpoint: CustomResponsesEndpoint

        private init(directory: URL, process: Process, endpoint: CustomResponsesEndpoint) {
            self.directory = directory
            self.process = process
            self.endpoint = endpoint
        }

        static func start() async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appending(path: "relay-owned-custom-responses-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let ready = directory.appending(path: "ready.json")
            let events = directory.appending(path: "events.jsonl")
            let script = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Scripts/Tests/test-custom-responses-loopback-fixture.py")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, "--ready-file", ready.path, "--events-file", events.path, "--lifetime", "30"]
            process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let end = ContinuousClock.now.advanced(by: .seconds(5))
                var result: JSONValue?
                while ContinuousClock.now < end {
                    if let data = try? Relay.LocalStateFile.read(ready, maximumBytes: 4_096),
                       let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                        result = value
                        break
                    }
                    guard process.isRunning else { throw CustomResponsesFailure.requestRejected }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let value = try #require(result)
                try #require(value.object?["pid"] == .number(Double(process.processIdentifier)))
                let port = try #require(value.object?["port"]?.int)
                let endpoint = try CustomResponsesEndpoint(parsing: "http://127.0.0.1:\(port)/v1")
                return Fixture(directory: directory, process: process, endpoint: endpoint)
            } catch {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        func events() -> Set<String> {
            guard let data = try? Relay.LocalStateFile.read(directory.appending(path: "events.jsonl"), maximumBytes: 32_768),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return Set(text.split(separator: "\n").compactMap {
                (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?.object?["event"]?.string
            })
        }

        func stop() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
