import Foundation
import Testing
@testable import Relay

@MainActor @Suite struct ExplicitCriticFreshReadTests {
    @Test(arguments: ["matching", "mismatch", "narrative-only", "failed-read"])
    func aPlannedCriticRequiresAnActualReadBeforeItsSeparateVerdict(_ outcome: String) async throws {
        let exact = "OWNED-CURRENT-cafe\u{301}-🌍\n"
        var planners = 0, reads = 0, verdicts = 0, syntheses = 0
        var verdictSawBytes = false
        let orchestrator = MultiAgentOrchestrator(
            allTools: MacTools.definitions.filter { $0.name == "read_file" },
            complete: { @MainActor messages, tools, _ in
                let role = messages.first?.content ?? ""
                if role.contains("ROLE: Planner") {
                    if messages.last?.content.contains("Synthesize") == true {
                        syntheses += 1
                        return .init(content: "The exact current evidence was checked.", toolCalls: [])
                    }
                    planners += 1
                    return .init(content: #"{"steps":[{"role":"Critic","title":"Verify the current selected bytes"}]}"#, toolCalls: [])
                }
                #expect(role.contains("ROLE: Critic"))
                if !tools.isEmpty {
                    #expect(tools.map(\.name) == ["read_file"])
                    #expect(messages.last?.content.contains("Request at least one advertised read-only tool now") == true)
                    if outcome == "narrative-only" {
                        return .init(content: "VERIFIED: An earlier receipt looked successful.", toolCalls: [])
                    }
                    return .init(content: "Inspect current evidence.", toolCalls: [
                        .init(id: "current-read", name: "read_file", arguments: ["path": .string("/owned/evidence.txt")])
                    ])
                }
                verdicts += 1
                let tool = try #require(messages.first { $0.role == "tool" && $0.toolCallID == "current-read" })
                let payload = try JSONDecoder().decode(JSONValue.self, from: Data(tool.content.utf8))
                verdictSawBytes = payload.object?["summary"]?.string?.utf8.elementsEqual(exact.utf8) == true
                #expect(verdictSawBytes)
                #expect(messages.contains { $0.role == "assistant" && $0.toolCalls.first?.id == "current-read" })
                return .init(content: outcome == "mismatch"
                    ? "UNVERIFIED: The actual read does not match the requested value."
                    : "VERIFIED: The actual whole read matches the requested exact value.", toolCalls: [])
            }, execute: { @MainActor call in
                #expect(call.name == "read_file")
                reads += 1
                return .init(summary: exact, evidence: "Owned inert read result.", verified: outcome != "failed-read")
            }, admitReadback: { call, _, result in
                #expect(call.id == "current-read" && result.summary.utf8.elementsEqual(exact.utf8))
                // This component fixture owns these inert bytes; production
                // Store uses its actual selected-file/native source adapter.
                return {}
            })
        let result = try await orchestrator.executeTask(goal: "Verify the exact current selected bytes without changing anything.")
        #expect(planners == 1)
        #expect(result.isSuccess == (outcome == "matching"))
        #expect(reads == (outcome == "narrative-only" ? 0 : 1))
        #expect(verdicts == (["matching", "mismatch"].contains(outcome) ? 1 : 0))
        #expect(syntheses == (outcome == "matching" ? 1 : 0))
        #expect(verdictSawBytes == ["matching", "mismatch"].contains(outcome))
    }
}
