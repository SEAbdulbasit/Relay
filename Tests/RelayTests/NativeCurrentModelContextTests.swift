import Foundation
import Testing
@testable import Relay

@Suite(.serialized) @MainActor struct NativeCurrentModelContextTests {
    @Test func staleAIsOmittedAndFreshBAloneGuardsThisTurnEvenForIdenticalBodies() async throws {
        let rig = Rig(), a = rig.entry("A", text: "IDENTICAL_PRIVATE_BODY"), b = rig.entry("B", text: "IDENTICAL_PRIVATE_BODY")
        rig.live[a.proposal] = false
        let snapshot = try await rig.context.prepare([a.handle, b.handle], maximumBytes: 4_000)
        #expect(snapshot.included == 1 && snapshot.omitted == 1)
        let checksAfterSelection = rig.checks[a.proposal] ?? 0
        try await snapshot.validate(); try await snapshot.sourceProof?.validate()
        #expect(rig.checks[a.proposal] == checksAfterSelection)
        #expect((rig.checks[b.proposal] ?? 0) > 1)
        #expect(snapshot.text.components(separatedBy: "IDENTICAL_PRIVATE_BODY").count == 2)
        #expect(rig.admissions.contains(a.proposal) && rig.admissions.contains(b.proposal))
    }
    @Test func BDerivedFromAIsNotReboundToBWhenADisappearsButAFreshBRequestCanProceed() async throws {
        let rig = Rig(), a = rig.entry("A", text: "PRIVATE_A")
        let first = try await rig.context.prepare([a.handle], maximumBytes: 4_000)
        let derived = rig.entry("B", text: "A_DERIVED_PRIVATE_B", inputs: first.sourceProof)
        rig.live[a.proposal] = false
        let refused = try await rig.context.prepare([derived.handle], maximumBytes: 4_000)
        #expect(refused.included == 0 && refused.omitted == 1 && !refused.text.contains("A_DERIVED_PRIVATE_B"))
        let fresh = rig.entry("B-fresh-goal", text: "FRESH_PRIVATE_B")
        let allowed = try await rig.context.prepare([a.handle, derived.handle, fresh.handle], maximumBytes: 4_000)
        #expect(allowed.included == 1 && allowed.omitted == 2)
        #expect(allowed.text.contains("FRESH_PRIVATE_B") && !allowed.text.contains("A_DERIVED_PRIVATE_B"))
        try await allowed.validate()
    }
    @Test func wholeEntryBudgetSkipsAnOversizedSourceWithoutValidatingItOrTruncatingOpaqueBytes() async throws {
        let rig = Rig(), large = rig.entry("large", text: String(repeating: "L", count: 4_000))
        let opaque = "draft=cafe\u{301}-opaque-review-token-881"
        let small = rig.entry("small", text: opaque)
        let snapshot = try await rig.context.prepare([large.handle, small.handle], maximumBytes: 1_200)
        #expect(snapshot.text.utf8.count <= 1_200 && snapshot.included == 1 && snapshot.omitted == 1)
        #expect(Data(snapshot.text.utf8).range(of: Data(opaque.utf8)) != nil)
        #expect(!rig.admissions.contains(large.proposal))
        #expect(snapshot.text.contains("omitted_native_results"))
        await #expect(throws: NativeCurrentModelContext.Failure.self) {
            try await rig.context.prepare([small.handle], maximumBytes: 20)
        }
    }
    @Test func sameActualSourceAndOwnerProofDeduplicateAcrossMoreThan1024Turns() async throws {
        let rig = Rig(), entry = rig.entry("source", text: "PRIVATE_SAME_SOURCE")
        var accumulated: ModelInputSourceProof?
        for _ in 0..<1_030 {
            let snapshot = try await rig.context.prepare([entry.handle], maximumBytes: 4_000)
            accumulated = try ModelInputSourceProof.merging([accumulated, snapshot.sourceProof])
            #expect(accumulated?.dependencyCount == 2)
            try await accumulated?.validate()
        }
    }
    @Test func sourceRevocationAndResetRejectAnAlreadyPreparedPrivateTurn() async throws {
        let rig = Rig(), entry = rig.entry("source", text: "PRIVATE")
        let snapshot = try await rig.context.prepare([entry.handle], maximumBytes: 4_000)
        rig.live[entry.proposal] = false
        await #expect(throws: (any Error).self) { try await snapshot.validate() }
        rig.live[entry.proposal] = true; rig.context.reset()
        await #expect(throws: (any Error).self) { try await snapshot.validate() }
        await #expect(throws: (any Error).self) { try await snapshot.sourceProof?.validate() }
    }
    @Test func aDerivedMailReceiptIsWholeWhileItsActualIncomingProofIsCurrent() async throws {
        let rig = Rig(), source = rig.entry("source", text: "PRIVATE_SOURCE")
        let prepared = try await rig.context.prepare([source.handle], maximumBytes: 4_000)
        let call = ToolCall(id: "actual-mail-reply", name: "create_mail_draft", arguments: [:])
        let opaque = #"{"draft_id":"draft-café-opaque","review_id":"one-use-review-721"}"#
        let handle = rig.context.record(call: call, acceptedProposalID: UUID(),
            result: .init(summary: opaque, evidence: "Actual synthetic dedicated result", verified: true), inputProof: prepared.sourceProof)
        let snapshot = try await rig.context.prepare([handle], maximumBytes: 4_000)
        #expect(snapshot.included == 1 && Data(snapshot.text.utf8).range(of: Data("one-use-review-721".utf8)) != nil)
        rig.live[source.proposal] = false
        let omitted = try await rig.context.prepare([handle], maximumBytes: 4_000)
        #expect(omitted.included == 0 && omitted.omitted == 1 && !omitted.text.contains("one-use-review-721"))
    }
    @MainActor private final class Rig {
        struct Item { let handle: NativeCurrentModelContext.Handle; let proposal: UUID }
        let run = UUID()
        var live: [UUID: Bool] = [:], checks: [UUID: Int] = [:], admissions: [UUID] = []
        var proofs: [UUID: ModelInputSourceProof] = [:]
        lazy var context = NativeCurrentModelContext(admission: { [self] _, proposal, _ in
            admissions.append(proposal)
            return try #require(proofs[proposal])
        }, gate: {})
        func entry(_ source: String, text: String, inputs: ModelInputSourceProof? = nil) -> Item {
            let proposal = UUID(); live[proposal] = true
            proofs[proposal] = .source(identity: .init(owner: run, sourceID: Data(source.utf8), purpose: "owned actual metadata source")) { [self] in
                checks[proposal, default: 0] += 1
                guard live[proposal] == true else { throw NativeVisualTaskFailure.staleProposal }
            }
            let call = ToolCall(id: "provider-id-may-repeat", name: NativeWindowReadTool.name,
                arguments: ["bundle_id": .string("test.admitted"), "question": .string("What is visible?")])
            let handle = context.record(call: call, acceptedProposalID: proposal,
                result: .init(summary: text, evidence: "Actual synthetic source data", verified: true), inputProof: inputs)
            return Item(handle: handle, proposal: proposal)
        }
    }
}

@Suite @MainActor struct ModelInputSourceProofTests {
    @Test func stableIdentityAndPurposeAreExactAndMoreThan32DifferentSourcesRefuse() async throws {
        let owner = UUID(); var merged: ModelInputSourceProof?
        let stable = ModelInputSourceProof.source(identity: .init(owner: owner, sourceID: Data("cafe\u{301}".utf8), purpose: "read")) {}
        for _ in 0..<1_030 { merged = try ModelInputSourceProof.merging([merged, stable]) }
        #expect(merged?.dependencyCount == 1)
        let precomposed = ModelInputSourceProof.source(identity: .init(owner: owner, sourceID: Data("café".utf8), purpose: "read")) {}
        merged = try ModelInputSourceProof.merging([merged, precomposed])
        #expect(merged?.dependencyCount == 2)
        let otherPurpose = ModelInputSourceProof.source(identity: .init(owner: owner, sourceID: Data("café".utf8), purpose: "private editor")) {}
        merged = try ModelInputSourceProof.merging([merged, otherPurpose]); #expect(merged?.dependencyCount == 3)
        let many = (0..<33).map { index in Optional(ModelInputSourceProof.source(identity: .init(owner: owner,
            sourceID: Data("source-\(index)".utf8), purpose: "read")) {}) }
        #expect(throws: ModelInputSourceProof.Failure.self) { try ModelInputSourceProof.merging(many) }
    }
}
