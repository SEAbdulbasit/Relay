import Foundation
import LiteRTLM
import Testing
@testable import Relay

@Suite("Agent desktop migration regressions")
struct AgentDesktopRegressionTests {
    @Test(arguments: ["observe_app", "press_control"])
    func newArgumentsAreAdvertisedButRemainOptional(name: String) throws {
        let manager = ToolManager(tools: try RelayNativeTools.makeTools(named: [name]))
        let schemas = try JSONDecoder().decode(JSONValue.self, from: Data(manager.toolsJsonDescription.utf8))
        guard case .array(let list) = schemas else { Issue.record("Expected schemas"); return }
        let function = try #require(list.first?.object?["function"]?.object)
        let parameters = try #require(function["parameters"]?.object)
        let properties = try #require(parameters["properties"]?.object)
        let optionalKeys = name == "observe_app" ? ["mode", "root_ref", "query"] : ["action"]
        for key in optionalKeys {
            #expect(properties[key]?.object?["type"]?.string == "string")
        }
        guard case .array(let required) = parameters["required"] else { Issue.record("Expected required keys"); return }
        #expect(Set(required.compactMap(\.string)) == (name == "observe_app" ? ["bundle_id"] : ["bundle_id", "element_id"]))
    }

    @Test(arguments: ["observe_app", "press_control"])
    func schemaToolsCannotBypassExecutor(name: String) async throws {
        let tool = try #require(RelayNativeTools.makeTools(named: [name]).first)
        do {
            _ = try await tool.run()
            Issue.record("Native schema tool bypassed the executor")
        } catch {
            #expect((error as NSError).domain == "Relay.ActionPolicy")
        }
    }

    @Test @MainActor func modelReplyPreservesNewInteractionArgumentsExactly() throws {
        let arguments: [String: Any] = ["bundle_id": "com.example.fixture", "mode": "find", "query": "Résumé 日本語", "root_ref": "@fixture:e1"]
        let actionArguments: [String: Any] = ["bundle_id": "com.example.fixture", "element_id": "@fixture:e2", "action": "toggle"]
        let message = LiteRTLM.Message(contents: [], role: .model, toolCalls: [
            LiteRTLM.ToolCall(name: "observe_app", id: "observe", arguments: arguments),
            LiteRTLM.ToolCall(name: "press_control", id: "press", arguments: actionArguments)
        ])
        let reply = try LocalModelClient.parseReply(message, availableTools: ["observe_app", "press_control"])
        #expect(reply.toolCalls.count == 2)
        #expect(reply.toolCalls[0].arguments["query"]?.string == "Résumé 日本語")
        #expect(reply.toolCalls[0].arguments["root_ref"]?.string == "@fixture:e1")
        #expect(reply.toolCalls[0].arguments["mode"]?.string == "find")
        #expect(reply.toolCalls[1].arguments["action"]?.string == "toggle")
        #expect(reply.toolCalls[1].arguments["element_id"]?.string == "@fixture:e2")
    }

    @Test(arguments: ["", "not json", "[]", "null", "{\"ok\":false}"])
    func malformedOrFailedEnvelopeNeverClaimsSuccess(raw: String) {
        let result = AgentDesktopBridge.parseEnvelope(rawJSON: raw, defaultCommand: "snapshot")
        #expect(!result.ok)
        #expect(result.command == "snapshot")
        #expect(result.errorCode != nil)
        #expect(!result.retrySafe)
    }

    @Test func preservesFailureDetailsAndExplicitRetryDisposition() {
        let raw = #"{"ok":false,"command":"click","error":{"code":"STALE_REF","message":"Refresh snapshot","suggestion":"Observe again","disposition":{"retry":"safe"}}}"#
        let result = AgentDesktopBridge.parseEnvelope(rawJSON: raw, defaultCommand: "unknown")
        #expect(!result.ok)
        #expect(result.errorCode == "STALE_REF")
        #expect(result.errorMessage == "Refresh snapshot")
        #expect(result.errorSuggestion == "Observe again")
        #expect(result.retrySafe)
    }

    @Test func snapshotPreservesQualifiedRefsUnicodeAndDisabledState() {
        let raw = #"{"ok":true,"command":"snapshot","data":{"app":"Fixture","snapshot_id":"s1","ref_count":2,"tree":{"ref_id":"@s1:e1","role":"AXWindow","children":[{"ref_id":"@s1:e2","role":"AXTextField","name":"Résumé 日本語","value":"sf.webm","states":["disabled"]}]}}}"#
        let result = AgentDesktopBridge.parseEnvelope(rawJSON: raw, defaultCommand: "snapshot")
        #expect(result.ok)
        #expect(result.snapshotID == "s1")
        #expect(result.refCount == 2)
        #expect(result.formattedSummary.contains("element_id=@s1:e2"))
        #expect(result.formattedSummary.contains("Résumé 日本語"))
        #expect(result.formattedSummary.contains("value=sf.webm enabled=false"))
    }

    @Test func emptyFindDoesNotInventControls() {
        let result = AgentDesktopBridge.parseEnvelope(rawJSON: #"{"ok":true,"command":"find","data":{"matches":[]}}"#, defaultCommand: "find")
        #expect(result.ok)
        #expect(!result.formattedSummary.contains("element_id="))
    }

    @Test(arguments: ["e1", "", "snapshot:e1"])
    func unqualifiedReferenceIsRejectedBeforeLaunchingCommand(ref: String) async {
        await #expect(throws: (any Error).self) {
            try await AgentDesktopBridge.act(command: "click", ref: ref)
        }
    }

    @Test(arguments: ["delete", "submit", "launch", "click; open /"])
    func unsupportedActionIsRejectedBeforeLaunchingCommand(command: String) async {
        await #expect(throws: (any Error).self) {
            try await AgentDesktopBridge.act(command: command, ref: "@fixture:e1")
        }
    }
}
