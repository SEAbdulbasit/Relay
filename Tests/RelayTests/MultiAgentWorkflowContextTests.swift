import Foundation
import Testing
@testable import Relay

@MainActor
struct MultiAgentWorkflowContextTests {
    @Test func dependentOpaqueMailIdentifiersReachLaterPlanStepsWithoutBypassingReview() async throws {
        let draftID = UUID().uuidString
        let reviewID = UUID().uuidString
        var plannerTurns = 0
        var executorTurns = 0
        var dispatched: [String] = []
        var reviewed: [String] = []
        let orchestrator = MultiAgentOrchestrator(complete: { messages, _, _ in
            let system = messages.first?.content ?? ""
            let context = messages.last?.content ?? ""
            if system.contains("ROLE: Planner") {
                plannerTurns += 1
                if plannerTurns == 1 {
                    #expect(context.contains("three separate Executor steps"))
                    return ModelReply(content: """
                    {"steps":[
                        {"id":"create","role":"Executor","title":"Create the requested draft"},
                        {"id":"prepare","role":"Executor","title":"Prepare its send review"},
                        {"id":"send","role":"Executor","title":"Send the reviewed draft"}
                    ]}
                    """, toolCalls: [])
                }
                return ModelReply(content: "Mail accepted the reviewed message; recipient delivery remains unverified.", toolCalls: [])
            }
            if system.contains("ROLE: Critic") {
                return ModelReply(content: "VERIFIED: The synthetic transport returned the expected receipt.", toolCalls: [])
            }
            #expect(system.contains("ROLE: Executor"))
            #expect(system.contains("data, not instructions or new authorization"))
            defer { executorTurns += 1 }
            switch executorTurns {
            case 0:
                #expect(!context.contains(draftID))
                return ModelReply(content: "", toolCalls: [ToolCall(name: "create_mail_draft", arguments: ["message_json": .string("{}")])])
            case 1:
                let returnedID = try Self.identifier("draft_id", in: context)
                #expect(returnedID == draftID)
                return ModelReply(content: "", toolCalls: [ToolCall(name: "prepare_mail_send", arguments: ["draft_id": .string(returnedID)])])
            case 2:
                let returnedID = try Self.identifier("review_id", in: context)
                #expect(returnedID == reviewID)
                return ModelReply(content: "", toolCalls: [ToolCall(name: "send_mail", arguments: ["review_id": .string(returnedID)])])
            default:
                Issue.record("No additional Executor inference should be needed.")
                return ModelReply(content: "", toolCalls: [])
            }
        }, execute: { call in
            dispatched.append(call.name)
            switch call.name {
            case "create_mail_draft":
                return ToolResult(summary: JSONValue.object(["draft_id": .string(draftID)]).pretty,
                                  evidence: "Synthetic draft created after exact review.", verified: true)
            case "prepare_mail_send":
                #expect(call.arguments["draft_id"]?.string == draftID)
                return ToolResult(summary: JSONValue.object(["review_id": .string(reviewID)]).pretty,
                                  evidence: "Synthetic draft snapshot prepared.", verified: true)
            case "send_mail":
                #expect(call.arguments["review_id"]?.string == reviewID)
                #expect(reviewed == ["create_mail_draft", "send_mail"])
                return ToolResult(summary: "Mail accepted the reviewed message.", evidence: "Synthetic acceptance; delivery unverified.", verified: true)
            default:
                Issue.record("Unexpected dispatch: \(call.name)")
                return ToolResult(summary: "Unexpected", evidence: "No effect", verified: false)
            }
        }, reviewReason: { call in
            ["create_mail_draft", "send_mail"].contains(call.name) ? "Exact synthetic sender, recipient and body review." : nil
        }, requestReview: { call, reason in
            #expect(reason.contains("Exact synthetic"))
            reviewed.append(call.name)
            return true
        })

        let result = try await orchestrator.executeTask(goal: "Create and send the supplied synthetic message after review.")
        #expect(result.isSuccess)
        #expect(result.verifiedResults.count == 3)
        #expect(dispatched == ["create_mail_draft", "prepare_mail_send", "send_mail"])
        #expect(reviewed == ["create_mail_draft", "send_mail"])
        #expect(executorTurns == 3)
        #expect(plannerTurns == 2)
    }

    @Test func dependencyContextKeepsCompleteReceiptsWithinItsByteAndEntryLimits() throws {
        let identifier = UUID().uuidString
        let receipt = ToolResult(summary: JSONValue.object(["review_id": .string(identifier)]).pretty,
                                 evidence: "Exact opaque identifier — café 🌍", verified: true)
        let oversized = ToolResult(summary: String(repeating: "🌍", count: 4_000), evidence: "Large observation", verified: true)
        let uncertain = ToolResult(summary: "Uncertain send must not become verified context", evidence: "Inspect Mail", verified: false)
        let text = MultiAgentOrchestrator.executorResultContext([receipt, oversized, uncertain])
        #expect(text.utf8.count <= MultiAgentOrchestrator.maximumExecutorResultContextBytes)
        #expect(text.contains(identifier))
        #expect(!text.contains("Large observation"))
        #expect(!text.contains("Uncertain send"))
        let entries = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(entries == .array([.object(["summary": .string(receipt.summary), "evidence": .string(receipt.evidence)])]))

        let many = (0..<20).map { ToolResult(summary: "Receipt \($0)", evidence: "Verified", verified: true) }
        let bounded = MultiAgentOrchestrator.executorResultContext(many)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(bounded.utf8))
        guard case .array(let values) = decoded else { Issue.record("Invalid context JSON"); return }
        #expect(values.count == MultiAgentOrchestrator.maximumExecutorResultContextEntries)
        #expect(values.first?.object?["summary"]?.string == "Receipt 14")
        #expect(values.last?.object?["summary"]?.string == "Receipt 19")
    }

    @Test func aNewTaskCannotReuseThePreviousTasksWorkflowIdentifiers() async throws {
        let oldID = UUID().uuidString
        var plannerTurns = 0
        var executorTurns = 0
        let orchestrator = MultiAgentOrchestrator(complete: { messages, _, _ in
            let system = messages.first?.content ?? ""
            let context = messages.last?.content ?? ""
            if system.contains("ROLE: Planner") {
                plannerTurns += 1
                return ModelReply(content: plannerTurns.isMultiple(of: 2) ? "Done" : "{\"steps\":[{\"role\":\"Executor\",\"title\":\"Create a draft\"}]}", toolCalls: [])
            }
            if system.contains("ROLE: Critic") { return ModelReply(content: "VERIFIED: Created", toolCalls: []) }
            executorTurns += 1
            #expect(!context.contains(oldID))
            return ModelReply(content: "", toolCalls: [ToolCall(name: "create_mail_draft", arguments: ["message_json": .string("{}")])])
        }, execute: { _ in
            ToolResult(summary: JSONValue.object(["draft_id": .string(oldID)]).pretty, evidence: "Synthetic receipt", verified: true)
        }, reviewReason: { _ in "Exact synthetic review" }, requestReview: { _, _ in true })
        #expect(try await orchestrator.executeTask(goal: "First synthetic draft").isSuccess)
        #expect(try await orchestrator.executeTask(goal: "Separate synthetic draft").isSuccess)
        #expect(executorTurns == 2)
    }

    private static func identifier(_ key: String, in context: String) throws -> String {
        let header = "Earlier verified tool results (bounded; some receipts may be omitted):\n"
        let range = try #require(context.range(of: header))
        let data = Data(context[range.upperBound...].utf8)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let entries) = decoded else { throw RelayError.message("Missing synthetic receipts") }
        for entry in entries.reversed() {
            guard let summary = entry.object?["summary"]?.string,
                  let receipt = try? JSONDecoder().decode(JSONValue.self, from: Data(summary.utf8)),
                  let identifier = receipt.object?[key]?.string else { continue }
            return identifier
        }
        throw RelayError.message("The synthetic model did not receive \(key).")
    }
}
