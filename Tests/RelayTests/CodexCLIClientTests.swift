import Foundation
import Testing
@testable import Relay

@MainActor struct CodexCLIClientTests {
    private let tool = ToolDefinition(name: "launch_app", description: "Review opening an application", parameters: .object([
        "type": .string("object"),
        "properties": .object(["name": .object(["type": .string("string")])]),
        "required": .array([.string("name")])
    ]))

    @Test func returnsAnAnswerOrOneValidatedProposal() throws {
        let answer = try CodexCLIClient.parseEvents(events(content: "Ready."), tools: [tool])
        #expect(answer.content == "Ready.")
        #expect(answer.toolCalls.isEmpty)

        let reply = try CodexCLIClient.parseEvents(events(name: tool.name, arguments: #"{"name":"Calendar"}"#), tools: [tool])
        #expect(reply.toolCalls.count == 1)
        #expect(reply.toolCalls.first?.name == tool.name)
        #expect(reply.toolCalls.first?.arguments == ["name": .string("Calendar")])
        #expect(reply.toolCalls.first.flatMap { UUID(uuidString: $0.id) } != nil)
    }

    @Test(arguments: [#"{}"#, #"{"name":false}"#, #"{"name":"Calendar","url":"https://example.com"}"#])
    func rejectsMissingWrongTypedAndExtraProposalArguments(arguments: String) {
        #expect(throws: ModelProtocolError.self) {
            try CodexCLIClient.parseEvents(events(name: tool.name, arguments: arguments), tools: [tool])
        }
    }

    @Test func rejectsUnavailableToolsAndNativeToolEvents() {
        #expect(throws: ModelProtocolError.self) {
            try CodexCLIClient.parseEvents(events(name: "other_app", arguments: #"{"name":"Calendar"}"#), tools: [tool])
        }
        let nativeEvent = #"{"type":"item.completed","item":{"type":"command_execution","command":"anything"}}"#
        #expect(throws: CodexCLIError.unexpectedTool) {
            try CodexCLIClient.parseEvents(events(content: "Apparently done.", prefix: nativeEvent), tools: [])
        }
        let refusedCall = Data("ERROR codex_core::tools::router: error=unsupported custom tool call: exec".utf8)
        #expect(throws: CodexCLIError.unexpectedTool) { try CodexCLIClient.validateDiagnostics(refusedCall) }
    }

    @Test func rejectsIncompleteAndUnsolicitedStructuredOutput() {
        #expect(throws: CodexCLIError.invalidOutput) {
            try CodexCLIClient.parseEvents(events(content: "Ready.", complete: false), tools: [])
        }
        #expect(throws: CodexCLIError.invalidOutput) {
            try CodexCLIClient.parseEvents(events(content: "Ready.", arguments: #"{"unrequested":true}"#), tools: [])
        }
        #expect(throws: CodexCLIError.invalidOutput) {
            try CodexCLIClient.parseEvents(events(content: String(repeating: "x", count: 12_001)), tools: [])
        }
    }

    @Test func schemaContainsOnlyAvailableNamesAndPromptUsesStdin() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: CodexCLIClient.outputSchema(tools: [tool]))
        #expect(schema.object?["properties"]?.object?["tool_name"]?.object?["enum"] == .array([.string(""), .string(tool.name)]))
        #expect(throws: CodexCLIError.invalidOutput) { try CodexCLIClient.outputSchema(tools: [tool, tool]) }
        let workspace = URL(fileURLWithPath: "/private/tmp/test-workspace", isDirectory: true)
        let args = CodexCLIClient.planningArguments(workspace: workspace, schema: workspace.appendingPathComponent("reply.json"))
        let marker = "private message fixture"
        let prompt = try CodexCLIClient.prompt(messages: [.init(role: "user", content: marker)], tools: [tool])
        #expect(String(decoding: prompt, as: UTF8.self).contains(marker))
        #expect(args.last == "-")
        #expect(!args.joined(separator: " ").contains(marker))
        #expect(args.contains("--ephemeral"))
        #expect(args.contains("--ignore-user-config"))
    }

    @Test func pinsAPlanningCatalogWithNoNativeToolMetadata() throws {
        let catalog = Data(#"{"models":[{"slug":"gpt-6.1-terra","tool_mode":"code_mode_only","multi_agent_version":"v2","apply_patch_tool_type":"freeform","shell_type":"unified_exec","base_instructions":"original"},{"slug":"other"}]}"#.utf8)
        let safe = try JSONDecoder().decode(JSONValue.self, from: CodexCLIClient.planningCatalog(catalog))
        guard case .array(let models) = try #require(safe.object?["models"]), let model = models.first?.object else {
            Issue.record("Expected one restricted model")
            return
        }
        #expect(models.count == 1)
        #expect(model["slug"] == .string("gpt-6.1-terra"))
        #expect(model["apply_patch_tool_type"] == nil)
        #expect(model["shell_type"] == .string("disabled"))
        #expect(model["tool_mode"] == .string("direct"))
        #expect(model["multi_agent_version"] == nil)
        #expect(model["supports_search_tool"] == .bool(false))
        #expect(model["base_instructions"] != .string("original"))

        let unsafe = Data(#"{"models":[{"slug":"gpt-6.1-terra","tool_mode":"code_mode_only"}]}"#.utf8)
        #expect(throws: CodexCLIError.unsupported) { try CodexCLIClient.planningCatalog(unsafe) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_CODEX_READINESS_TEST"] == "1"))
    func installedCLIHasExistingChatGPTLoginWithoutNetworking() async {
        let readiness = await CodexCLIClient().readiness()
        #expect(readiness.isReady, Comment(rawValue: readiness.message))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_CODEX_SYNTHETIC_TEST"] == "1"))
    func installedCLICompletesSyntheticHostedPlanning() async throws {
        let client = CodexCLIClient()
        let readiness = await client.readiness()
        try #require(readiness.isReady, Comment(rawValue: readiness.message))
        let reply = try await client.complete(messages: [.init(role: "user", content: "Answer only with the exact text Relay synthetic planning ready.")], tools: [])
        #expect(reply.content == "Relay synthetic planning ready.")
        #expect(reply.toolCalls.isEmpty)
    }

    @Test func timeoutAndCancellationEndTheSubprocess() async {
        let binary = URL(fileURLWithPath: "/bin/sleep")
        let directory = FileManager.default.temporaryDirectory
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CodexCLIError.timeout) {
            try await CodexCLIProcess.run(executable: binary, arguments: ["10"], environment: [:], directory: directory, input: nil,
                                          timeout: 0.06, limit: 1024)
        }
        let task = Task {
            try await CodexCLIProcess.run(executable: binary, arguments: ["10"], environment: [:], directory: directory, input: nil,
                                          timeout: 8, limit: 1024)
        }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: clock.now) < .seconds(4))
    }

    private func events(content: String = "", name: String = "", arguments: String = "{}", prefix: String = "", complete: Bool = true) -> Data {
        let reply = JSONValue.object(["content": .string(content), "tool_name": .string(name), "arguments_json": .string(arguments)])
        let item = JSONValue.object(["type": .string("item.completed"), "item": .object(["type": .string("agent_message"), "text": .string(reply.pretty)])])
        let lines = [#"{"type":"thread.started","thread_id":"fixture"}"#, #"{"type":"turn.started"}"#, prefix, item.pretty,
                     complete ? #"{"type":"turn.completed"}"# : ""]
        return Data(lines.joined(separator: "\n").utf8)
    }
}
