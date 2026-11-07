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

    /// Explicit local gate for a candidate CLI before adding its signed code hash to production.
    /// The fixture is scripts/Tests/codex_planner_fixture.py; no real auth/model request is used.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_CODEX_LOOPBACK_FIXTURE"] != nil))
    func installedCandidateUsesProductionPlannerArgumentsWithNoAdvertisedNativeTools() async throws {
        let rawEndpoint = try #require(ProcessInfo.processInfo.environment["RELAY_CODEX_LOOPBACK_FIXTURE"])
        let endpoint = try #require(URL(string: rawEndpoint))
        try #require(endpoint.scheme == "http" && endpoint.host == "127.0.0.1" && endpoint.port != nil
            && endpoint.path == "/v1" && endpoint.user == nil && endpoint.password == nil && endpoint.query == nil && endpoint.fragment == nil)
        let port = try #require(endpoint.port)
        let mode = ProcessInfo.processInfo.environment["RELAY_CODEX_LOOPBACK_MODE"] ?? "answer"
        try #require(["answer", "proposal", "native"].contains(mode))
        let cli = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        try #require(CodexCLIClient.signedCodeHash(cli) == "a11ce3314a7adeaca2a1283051ee2f0b41070d5a")
        let workspace = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("RelayCodexLoopback-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workspace) }
        let isolated = workspace.appendingPathComponent("codex", isDirectory: true)
        try fm.createDirectory(at: isolated, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let auth = isolated.appendingPathComponent("auth.json")
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let claims = JSONValue.object(["sub": .string("relay-loopback-fixture"), "email": .string("fixture@invalid.test"),
            "exp": .number(Date().timeIntervalSince1970 + 3_600),
            "https://api.openai.com/auth": .object(["chatgpt_account_id": .string("relay-fixture-account"),
                "chatgpt_plan_type": .string("plus"), "chatgpt_user_id": .string("relay-fixture-user")])])
        let token = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)) + "."
            + base64URL(Data(claims.pretty.utf8)) + "." + base64URL(Data("synthetic-signature".utf8))
        let syntheticAuth = JSONValue.object(["auth_mode": .string("chatgpt"),
            "tokens": .object(["id_token": .string(token), "access_token": .string("relay-fixture-not-a-real-access-token"),
                "refresh_token": .string("relay-fixture-not-a-real-refresh-token"), "account_id": .string("relay-fixture-account")]),
            "last_refresh": .string(ISO8601DateFormatter().string(from: Date()))])
        try Data(syntheticAuth.pretty.utf8).write(to: auth)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        let user = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        var environment = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL"].contains($0.key) }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TMPDIR"] = workspace.path
        environment["CODEX_HOME"] = isolated.path
        environment["RELAY_CODEX_FIXTURE_KEY"] = "relay-loopback-not-a-real-key"
        let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        @MainActor func prefix(localOnly: Bool) -> [String] {
            var args = CodexCLIClient.sandboxArguments(cli: cli, userHome: user, codexHome: isolated, auth: auth,
                workspace: workspace, localOnly: localOnly)
            if !localOnly {
                // Tighten only this fixture to prevent even synthetic auth-refresh traffic
                // escaping loopback. The production sandbox and planner args are preserved.
                args[1] += "\n(deny network-outbound)\n(allow network-outbound (remote ip \"localhost:\(port)\"))"
            }
            return args
        }
        let bundled = try await CodexCLIProcess.run(executable: sandbox,
            arguments: prefix(localOnly: true) + ["--no-daemon", "debug", "models", "--bundled"],
            environment: environment, directory: workspace, input: nil, timeout: 8, limit: 1_048_576)
        try #require(bundled.status == 0)
        let catalog = try CodexCLIClient.planningCatalog(bundled.stdout)
        let tools = mode == "proposal" ? [tool] : []
        let schema = workspace.appendingPathComponent("reply-schema.json")
        let input = workspace.appendingPathComponent("input.txt")
        for (name, data) in [("models.json", catalog), (schema.lastPathComponent, try CodexCLIClient.outputSchema(tools: tools)),
                             ("instructions.txt", Data("You are Relay’s hosted text planner. Use only the supplied request, answer in the required JSON schema, and never take actions directly. Relay validates proposals and controls its own tools.".utf8)),
                             (input.lastPathComponent, try CodexCLIClient.prompt(messages: [.init(role: "user", content: "Relay synthetic planning ready.")], tools: tools))] {
            let file = workspace.appendingPathComponent(name)
            try data.write(to: file)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let provider = ["model_provider=\"relay_fixture\"", "model_providers.relay_fixture.name=\"Relay loopback fixture\"",
            "model_providers.relay_fixture.base_url=\"\(endpoint.absoluteString)\"", "model_providers.relay_fixture.wire_api=\"responses\"",
            "model_providers.relay_fixture.requires_openai_auth=false", "model_providers.relay_fixture.supports_websockets=false",
            "model_providers.relay_fixture.env_key=\"RELAY_CODEX_FIXTURE_KEY\""]
        let result = try await CodexCLIProcess.run(executable: sandbox,
            arguments: prefix(localOnly: false) + Array(CodexCLIClient.planningArguments(workspace: workspace, schema: schema)
                .dropLast()) + provider.flatMap { ["--config", $0] } + ["-"],
            environment: environment, directory: workspace, input: input, timeout: 35, limit: 262_144)
        if mode == "native" {
            // A native tool attempt must remain a refused protocol event, never an accepted plan.
            #expect(throws: (any Error).self) {
                try CodexCLIClient.validateDiagnostics(result.stderr)
                guard result.status == 0 else { throw CodexCLIError.failed }
                _ = try CodexCLIClient.parseEvents(result.stdout, tools: [])
            }
        } else {
            try #require(result.status == 0, Comment(rawValue: String(decoding: result.stderr, as: UTF8.self)))
            try CodexCLIClient.validateDiagnostics(result.stderr)
            let reply = try CodexCLIClient.parseEvents(result.stdout, tools: tools)
            if mode == "proposal" {
                #expect(reply.toolCalls.count == 1 && reply.toolCalls.first?.name == "launch_app")
                #expect(reply.toolCalls.first?.arguments == ["name": .string("Synthetic Fixture")])
            } else { #expect(reply.content == "Relay synthetic planning ready." && reply.toolCalls.isEmpty) }
        }
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
