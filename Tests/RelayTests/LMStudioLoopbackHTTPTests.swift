import Foundation
import Testing
@testable import Relay

/// Prepared only. This opt-in runs an owned Python HTTP fixture on ephemeral
/// 127.0.0.1, never LM Studio, a model, app data or credentials.
@Suite(.serialized) @MainActor struct LMStudioLoopbackHTTPTests {
    private let messages = [ModelMessage(role: "user", content: "SYNTHETIC HTTP protocol fixture only")]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_LMSTUDIO_LOOPBACK_PROTOCOL_TEST"] == "1")) func realNSURLSessionPreservesSplitUTF8AndExactStreamedCallResultIDs() async throws {
        let fixture = try await Fixture.start(); defer { fixture.stop() }
        let client = LMStudioClient()
        let unicode = try await client.complete(messages: messages, tools: [], selection: fixture.selection("unicode"))
        #expect(unicode.content == "Café 👩‍💻 العربية" && unicode.toolCalls.isEmpty)
        let tool = ToolDefinition(name: "calculate", description: "Synthetic arithmetic", parameters: .object(["type": .string("object")]))
        let choice = try fixture.selection("tool")
        let reply = try await client.complete(messages: messages, tools: [tool], selection: choice)
        let call = try #require(reply.toolCalls.first)
        #expect(reply.toolCalls.count == 1 && call.name == "calculate" && call.arguments == ["expression": .string("6*7")])
        let history = messages + [.init(role: "assistant", content: reply.content, toolCalls: reply.toolCalls),
            .init(role: "tool", content: "42", toolCallID: call.id, toolName: call.name)]
        let final = try await client.complete(messages: history, tools: [tool], selection: choice)
        #expect(final.content == "42" && fixture.events().contains("exact-tool-result-received"))
        #expect(!fixture.events().contains("unexpected-credential-header"))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_LMSTUDIO_LOOPBACK_PROTOCOL_TEST"] == "1")) func redirectIncompleteStreamAndDeclaredOversizeAreTypedFailures() async throws {
        let fixture = try await Fixture.start(); defer { fixture.stop() }
        let client = LMStudioClient()
        await #expect(throws: LMStudioFailure.httpStatus(307)) {
            try await client.complete(messages: messages, tools: [], selection: fixture.selection("redirect"))
        }
        #expect(!fixture.events().contains("forbidden-redirect-followed"))
        let tool = ToolDefinition(name: "calculate", description: "Synthetic", parameters: .object(["type": .string("object")]))
        await #expect(throws: LMStudioFailure.incompleteStream) {
            try await client.complete(messages: messages, tools: [tool], selection: fixture.selection("incomplete"))
        }
        await #expect(throws: LMStudioFailure.responseLimit) {
            try await client.complete(messages: messages, tools: [], selection: fixture.selection("declared-oversize"))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_LMSTUDIO_LOOPBACK_PROTOCOL_TEST"] == "1")) func cancellingRealSocketStreamDrainsWithoutReturningAPartialAction() async throws {
        let fixture = try await Fixture.start(); defer { fixture.stop() }
        let client = LMStudioClient(), choice = try fixture.selection("cancel")
        let request = Task { try await client.complete(messages: messages, tools: [], selection: choice) }
        try await awaitLMStudioCondition { fixture.events().contains("cancel-stream-started") }
        let started = ContinuousClock.now
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        await client.drain()
        #expect(started.duration(to: ContinuousClock.now) < .seconds(3))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_LMSTUDIO_LOOPBACK_PROTOCOL_TEST"] == "1")) func actualBodyLimitIsEnforcedWithoutAnySSEParser() async throws {
        let fixture = try await Fixture.start(); defer { fixture.stop() }
        let choice = try fixture.selection("actual-oversize")
        var request = URLRequest(url: choice.endpoint.completionsURL)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try LMStudioWireCodec.request(selection: choice, messages: messages, tools: [])
        let response = try await LMStudioHTTPTransport.make().open(request)
        defer { response.cancel() }
        var received = 0
        do {
            for try await chunk in response.body { received += chunk.count }
            Issue.record("Transport accepted an oversized body without its parser")
        } catch { #expect(error as? LMStudioFailure == .responseLimit) }
        #expect(received <= LMStudioWireCodec.maximumOutputBytes)
    }

    @MainActor private final class Fixture {
        let directory: URL
        let process: Process
        let endpoint: LMStudioEndpoint
        let models: [String: String]
        private init(directory: URL, process: Process, endpoint: LMStudioEndpoint, models: [String: String]) {
            self.directory = directory; self.process = process; self.endpoint = endpoint; self.models = models
        }
        static func start() async throws -> Fixture {
            let directory = FileManager.default.temporaryDirectory.appending(path: "relay-owned-http-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let ready = directory.appending(path: "ready.json"), events = directory.appending(path: "events.jsonl")
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Scripts/Tests/test-lmstudio-loopback-fixture.py")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, "--ready-file", ready.path, "--events-file", events.path, "--lifetime", "30"]
            process.environment = ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                var metadata: JSONValue?
                try await awaitLMStudioCondition {
                    if let bytes = try? LocalStateFile.read(ready, maximumBytes: 8_192),
                       let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) { metadata = value; return true }
                    return !process.isRunning
                }
                guard let value = metadata,
                      value.object?["pid"] == .number(Double(process.processIdentifier)), value.object?["host"] == .string("127.0.0.1"),
                      let port = value.object?["port"]?.int, value.object?["port"] == .number(Double(port)),
                      let raw = value.object?["models"]?.object else {
                    throw LMStudioFailure.malformedResponse
                }
                let models = raw.compactMapValues(\.string)
                guard models.count == 7 else { throw LMStudioFailure.malformedResponse }
                return Fixture(directory: directory, process: process, endpoint: try LMStudioEndpoint(port: port), models: models)
            } catch {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
        func selection(_ mode: String) throws -> LMStudioSelection {
            guard let model = models[mode] else { throw LMStudioFailure.invalidModel }
            return try LMStudioSelection(endpoint: endpoint, modelID: model)
        }
        func events() -> Set<String> {
            guard let data = try? LocalStateFile.read(directory.appending(path: "events.jsonl"), maximumBytes: 32_768),
                  let string = String(data: data, encoding: .utf8) else { return [] }
            return Set(string.split(separator: "\n").compactMap { line in
                (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?.object?["event"]?.string
            })
        }
        func stop() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
