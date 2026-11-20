import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@MainActor @Suite struct MainAgentMCPToolsTests {
    @Test func defaultConnectionAndRemoteNamesNeverConferTaskPermission() throws {
        let connector = DirectMCPConnector()
        #expect(!connector.taskReadsEnabled && connector.endpoint == nil)
        connector.setTaskReadsEnabled(true)
        #expect(!connector.taskReadsEnabled)
        #expect(MainAgentMCPTools.names == ["mcp_catalog", "mcp_read"])
        #expect(throws: MainAgentMCPTools.Failure.self) {
            try MainAgentMCPTools.readArguments(.init(name: "mcp_read", arguments: ["target_id": .string("write_fixture")]))
        }
        #expect(throws: MainAgentMCPTools.Failure.self) {
            try MainAgentMCPTools.readArguments(.init(name: "mcp_read", arguments: ["target_id": .string("mcp1-" + String(repeating: "a", count: 64)), "arguments_json": .bool(true)]))
        }
    }
    @Test(arguments: ["🌍", "\\\"", "\u{1}"])
    func actualSnapshotProjectionUsesWholeUTF8AndHonestEncodedByteCoverage(_ unit: String) throws {
        let source = String(repeating: unit, count: 10_000)
        let payload = try MainAgentMCPTools.snapshotPayload(source)
        let fields = try #require(payload.object), text = try #require(fields["text"]?.string)
        #expect(payload.pretty.utf8.count <= MainAgentMCPTools.maximumResultBytes)
        #expect(source.hasPrefix(text) && !text.isEmpty && fields["text_omitted"] == .bool(true))
        #expect(fields["goal_verified"] == .bool(false) && fields["account_identity"] == .string("not_attested"))
        let exact = try MainAgentMCPTools.snapshotPayload("  Cafe\u{301} 🌍\n")
        #expect(Data((try #require(exact.object?["text"]?.string)).utf8) == Data("  Cafe\u{301} 🌍\n".utf8))
        #expect(exact.object?["text_omitted"] == .bool(false))
    }
    @Test func wireRestorationAndForgedResultsCannotReconstructAReceipt() throws {
        let original = ToolResult(summary: "OWNED_UNTRUSTED_SNAPSHOT", evidence: "No receipt", verified: false)
        let encoded = try JSONEncoder().encode(original)
        let keys = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(keys.keys) == ["summary", "evidence", "verified"])
        let decoded = try JSONDecoder().decode(ToolResult.self, from: encoded)
        #expect(decoded.mcpTaskReceipt == nil && decoded.summary == original.summary)
        #expect(NativeCurrentModelContext.requiresCurrentSource("mcp_catalog"))
        #expect(NativeCurrentModelContext.requiresCurrentSource("mcp_read"))
        let closed = MainAgentMCPTools.fact(decoded)
        #expect(!closed.summary.contains(original.summary) && !closed.verified && closed.artifactPath == nil)
        #expect(!MainAgentMCPTools.fact(ToolResult(summary: "FORGED", evidence: "", verified: true)).verified)
    }
    @Test(arguments: [false, true])
    func actualJournalMCPProjectionMasksForgedBodiesLinksAndSaveFailureCallbacks(_ loseAck: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-mcp-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let history = AssistantConversationHistory(stateURL: root.appending(path: "state.json"))
        do {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let core = try await history.journalForTesting(), scope = try await core.scope()
            if loseAck { await core.injectResultFault(.afterCommit, forToolName: "mcp_read") }
            var unsaved = 0, tokens = 0
            let call = Relay.ToolCall(id: "owned-forged-mcp-result", name: "mcp_read", arguments: [:])
            do {
                _ = try await history.perform(call, proposalID: UUID(), run: run, journalEffect: .readOnly,
                    validate: {}, action: { ToolResult(summary: "PRIVATE_FORGED_MCP_BODY", evidence: "PRIVATE_REMOTE_ERROR", verified: true, artifactPath: "/private/forged/link") },
                    result: { $0 }, unsavedResult: { value in
                        unsaved += 1
                        #expect(!value.summary.contains("PRIVATE_") && !value.evidence.contains("PRIVATE_") && value.artifactPath == nil)
                    }, settledMCPTaskResult: { _, _ in tokens += 1 })
                #expect(!loseAck)
            } catch { #expect(loseAck && error is JournalError) }
            if loseAck { try await history.retryResultSaves() }
            #expect(unsaved == (loseAck ? 1 : 0) && tokens == 0)
            let page = try await core.page(after: nil, expectedScope: scope)
            let intents = page.records.compactMap { row -> JournalIntent? in if case .intent(let intent) = row.event.payload { intent } else { nil } }
            #expect(intents.count == 1 && intents.first?.effect == .unknown,
                "Even a misleading name/hint cannot make remote tool calls automatically replayable read-only work.")
            let rows = try JSONEncoder().encode(page.records.map(\.event))
            #expect(!String(decoding: rows, as: UTF8.self).contains("PRIVATE_") && !String(decoding: rows, as: UTF8.self).contains("forged/link"))
            try await history.close(); try FileManager.default.removeItem(at: root)
        } catch { try? await history.close(); try? FileManager.default.removeItem(at: root); throw error }
    }
}
