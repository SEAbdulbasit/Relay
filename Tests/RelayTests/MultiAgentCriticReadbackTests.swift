import Foundation
import Testing
@testable import Relay

@MainActor @Suite struct MultiAgentCriticReadbackTests {
    @Test(arguments: ["VERIFIED: The returned exact value matches.", "UNVERIFIED: The file contains a different value.", "", "The read succeeded.", "VERIFIED: First claim.\nUNVERIFIED: Conflicting outcome."])
    func aReadMustReachAVerdictAfterItsActualResult(_ verdict: String) async throws {
        let rig = Rig(verdict: verdict)
        let result = try await rig.orchestrator.executeTask(goal: "Save the exact owned value once, then verify its contents.")
        let accepted = verdict.hasPrefix("VERIFIED:") && !verdict.contains("UNVERIFIED:")
        #expect(result.isSuccess == accepted)
        #expect(rig.writes == 1 && rig.reads == 1 && rig.verdicts == 1)
        #expect(rig.verdictSawExactResult && rig.verdictSawOriginalPair)
        #expect(rig.syntheses == (accepted ? 1 : 0))
    }

    @Test(arguments: ["matching", "mismatch", "failed-read", "no-read"])
    func freshPostconditionProofDoesNotRewriteAnUncertainActionReceipt(_ outcome: String) async throws {
        let rig = Rig(verdict: outcome == "mismatch" ? "UNVERIFIED: The actual value differs." : "VERIFIED: The actual value matches.")
        rig.actionVerified = false
        rig.skipRead = outcome == "no-read"
        rig.readVerified = outcome != "failed-read"
        if outcome == "mismatch" { rig.readEvidence = "Actual owned contents: DIFFERENT-VALUE" }
        var originalReceipts: [Bool] = []
        rig.orchestrator.onToolResult = { call, result in
            if call.name == "write_file" { originalReceipts.append(result.verified) }
        }
        let result = try await rig.orchestrator.executeTask(goal: "Save once, then verify the exact owned postcondition without repeating an uncertain action.")
        #expect(result.isSuccess == (outcome == "matching"))
        #expect(originalReceipts == [false] && rig.writes == 1)
        #expect(!result.verifiedResults.contains { $0.summary == "One owned write." })
        #expect(rig.reads == (outcome == "no-read" ? 0 : 1))
        #expect(rig.syntheses == (outcome == "matching" ? 1 : 0))
        if outcome == "matching" || outcome == "mismatch" {
            #expect(rig.verdictSawExactResult && rig.verdictSawOriginalPair)
        }
    }

    @Test func failedReadCannotBecomeAVerifiedGoalOrTriggerAnotherAction() async throws {
        let rig = Rig(verdict: "VERIFIED: This must never be consumed.")
        rig.readVerified = false
        let result = try await rig.orchestrator.executeTask(goal: "Write once and independently check the owned result.")
        #expect(!result.isSuccess && rig.writes == 1 && rig.reads == 1)
        #expect(rig.verdicts == 0 && rig.syntheses == 0)
    }

    @Test func aVerdictCannotRequestAnotherReadOrMutation() async throws {
        let rig = Rig(verdict: "VERIFIED: A contradictory action is invalid.")
        rig.verdictCalls = [.init(id: "late-write", name: "write_file", arguments: ["path": .string("/owned/result.txt"), "content": .string("another value")])]
        await #expect(throws: RelayError.self) {
            try await rig.orchestrator.executeTask(goal: "Write only the original value once.")
        }
        #expect(rig.writes == 1 && rig.reads == 1 && rig.verdicts == 1 && rig.syntheses == 0)
    }

    @Test func invalidationAfterReadPreventsTheVerdictSend() async throws {
        let rig = Rig(verdict: "VERIFIED: This must never be sent.")
        rig.invalidateAfterRead = true
        await #expect(throws: CancellationError.self) {
            try await rig.orchestrator.executeTask(goal: "Write once, keeping current source validation.")
        }
        #expect(rig.writes == 1 && rig.reads == 1 && rig.verdicts == 0 && rig.syntheses == 0)
    }

    @Test func largeReadbackIsRefusedWholeByProductionContextAdmission() async throws {
        let rig = Rig(verdict: "VERIFIED: This must never be inferred.")
        rig.readEvidence = "START-EXACT\n" + String(repeating: "x", count: 26_000) + "\nEND-EXACT"
        rig.admitProductionContext = true
        await #expect(throws: RelayError.self) {
            try await rig.orchestrator.executeTask(goal: "Write once and assess the complete readback.")
        }
        #expect(rig.writes == 1 && rig.reads == 1 && rig.verdicts == 0 && rig.syntheses == 0)
    }

    @Test func aMissingReadbackBindingRefusesBeforePrivateVerdictInference() async throws {
        let rig = Rig(verdict: "VERIFIED: Unbound data must never be inferred.")
        rig.admitProofs = false
        await #expect(throws: RelayError.self) {
            try await rig.orchestrator.executeTask(goal: "Write once, then verify under a current source binding.")
        }
        #expect(rig.writes == 1 && rig.reads == 1 && rig.verdicts == 0 && rig.syntheses == 0)
    }

    @Test(arguments: [false, true])
    func sourceRevocationDuringVerdictFencesSuccessAndPrivateErrors(_ throwsReply: Bool) async throws {
        var sourceLive = true, writes = 0, reads = 0, verdictSends = 0, privateSendChecks = 0
        let orchestrator = MultiAgentOrchestrator(
            allTools: MacTools.definitions.filter { ["write_file", "read_file"].contains($0.name) },
            complete: { _, _, _ in throw RelayError.message("The source-bound completion is required.") },
            execute: { call in
                if call.name == "write_file" { writes += 1 }
                else { #expect(call.name == "read_file"); reads += 1 }
                return .init(summary: "Owned exact fixture value.", evidence: "Synthetic owned evidence.", verified: true)
            }, sourceBoundComplete: { messages, tools, _, authorizePrivateSend in
                let role = messages.first?.content ?? ""
                if role.contains("ROLE: Planner") {
                    return .init(content: #"{"steps":[{"id":"one","role":"Executor","title":"Save once"}]}"#, toolCalls: [])
                }
                if role.contains("ROLE: Executor") {
                    return .init(content: "", toolCalls: [.init(id: "one-write", name: "write_file", arguments: ["path": .string("/owned/result.txt"), "content": .string("Owned exact fixture value.")])])
                }
                if !tools.isEmpty {
                    return .init(content: "", toolCalls: [.init(id: "one-read", name: "read_file", arguments: ["path": .string("/owned/result.txt")])])
                }
                try #require(authorizePrivateSend != nil)
                try await authorizePrivateSend?(); privateSendChecks += 1; verdictSends += 1
                sourceLive = false
                if throwsReply { throw RelayError.message("PRIVATE-ERROR-MUST-NOT-PUBLISH") }
                return .init(content: "VERIFIED: PRIVATE-REPLY-MUST-NOT-PUBLISH", toolCalls: [])
            }, admitReadback: { _, _, _ in
                return { if !sourceLive { throw CancellationError() } }
            })
        await #expect(throws: CancellationError.self) {
            try await orchestrator.executeTask(goal: "Save and verify the owned fixture value once.")
        }
        #expect(writes == 1 && reads == 1 && verdictSends == 1 && privateSendChecks == 1)
    }

    @MainActor private final class Rig {
        let verdict: String
        var verdictCalls: [ToolCall] = []
        var readVerified = true, invalidateAfterRead = false, current = true, admitProductionContext = false, admitProofs = true
        var actionVerified = true, skipRead = false
        var readEvidence = "Actual owned contents: cafe\u{301} 🌍\nEXPECTED-OWNED-VALUE\n"
        var writes = 0, reads = 0, verdicts = 0, syntheses = 0
        var verdictSawExactResult = false, verdictSawOriginalPair = false
        init(verdict: String) { self.verdict = verdict }
        // These results are owned inert constants. Production Store callers
        // must provide their actual selected-source proof adapter instead.
        private var admission: MultiAgentOrchestrator.ReadbackAdmissionHandler? {
            guard admitProofs else { return nil }
            return { [self] call, _, result in
                #expect(call.name == "read_file" && result.evidence.utf8.elementsEqual(readEvidence.utf8))
                return {}
            }
        }
        lazy var orchestrator = MultiAgentOrchestrator(
            allTools: MacTools.definitions.filter { ["write_file", "read_file"].contains($0.name) },
            complete: { @MainActor [self] messages, tools, _ in
                if admitProductionContext { _ = try LocalModelClient.prepareContext(messages: messages, tools: tools) }
                let role = messages.first?.content ?? ""
                if role.contains("ROLE: Planner") {
                    if messages.last?.content.contains("Synthesize") == true { syntheses += 1; return .init(content: "The checked owned outcome.", toolCalls: []) }
                    return .init(content: #"{"steps":[{"id":"one","role":"Executor","title":"Save the exact owned value"}]}"#, toolCalls: [])
                }
                if role.contains("ROLE: Executor") {
                    return .init(content: "", toolCalls: [.init(id: "first-write", name: "write_file", arguments: ["path": .string("/owned/result.txt"), "content": .string("EXPECTED-OWNED-VALUE\n")])])
                }
                if !tools.isEmpty {
                    if skipRead { return .init(content: verdict, toolCalls: []) }
                    return .init(content: "VERIFIED: Premature claim made before the read returns.", toolCalls: [.init(id: "exact-read", name: "read_file", arguments: ["path": .string("/owned/result.txt")])])
                }
                verdicts += 1
                let tool = messages.first { $0.role == "tool" && $0.toolCallID == "exact-read" && $0.toolName == "read_file" }
                let payload = try #require(tool?.content.data(using: .utf8))
                let value = try JSONDecoder().decode(JSONValue.self, from: payload)
                verdictSawExactResult = value.object?["evidence"]?.string?.utf8.elementsEqual(readEvidence.utf8) == true
                verdictSawOriginalPair = messages.contains { $0.role == "assistant" && $0.toolCalls.first?.id == "exact-read" }
                #expect(tools.isEmpty)
                return .init(content: verdict, toolCalls: verdictCalls)
            }, execute: { @MainActor [self] call in
                if call.name == "write_file" { writes += 1; return .init(summary: "One owned write.", evidence: "Exact resulting bytes were read back by the write adapter.", verified: actionVerified) }
                #expect(call.name == "read_file"); reads += 1
                if invalidateAfterRead { current = false }
                return .init(summary: "Owned file read.", evidence: readEvidence, verified: readVerified)
            }, admitReadback: admission, gate: { [self] in if !current { throw CancellationError() } })
    }
}
