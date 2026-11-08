import Foundation
import Testing
@testable import Relay

@Suite(.serialized) @MainActor struct NativeCurrentReadbackReceiptTests {
    @Test func exactAcceptedProposalAndByteExactResultAreRequiredForCurrentPrivateAdmission() async throws {
        let rig = try Rig(), proposal = UUID()
        let call = rig.call(id: "cafe\u{301}"), result = rig.result("source cafe\u{301}")
        try rig.book.record(.init(result: result, source: rig.source()), call: call, acceptedProposalID: proposal)
        let check = try rig.book.admission(call: call, acceptedProposalID: proposal, result: result)
        try await check()
        #expect(rig.validations >= 3)
        #expect(throws: (any Error).self) { try rig.book.admission(call: call, acceptedProposalID: UUID(), result: result) }
        #expect(throws: (any Error).self) { try rig.book.admission(call: rig.call(id: "café"), acceptedProposalID: proposal, result: result) }
        #expect(throws: (any Error).self) { try rig.book.admission(call: call, acceptedProposalID: proposal, result: rig.result("source café")) }
        var changed = call; changed.arguments["question"] = .string("different private question")
        #expect(throws: (any Error).self) { try rig.book.admission(call: changed, acceptedProposalID: proposal, result: result) }
    }
    @Test func aNewAcceptedReplyMayReuseTheProviderIDButCannotUseTheEarlierResultBinding() async throws {
        let rig = try Rig(), call = rig.call(), first = UUID(), second = UUID()
        let a = rig.result("first"), b = rig.result("second")
        try rig.book.record(.init(result: a, source: rig.source()), call: call, acceptedProposalID: first)
        try rig.book.record(.init(result: b, source: rig.source()), call: call, acceptedProposalID: second)
        try await rig.book.admission(call: call, acceptedProposalID: second, result: b)()
        #expect(throws: (any Error).self) { try rig.book.admission(call: call, acceptedProposalID: second, result: a) }
        #expect(throws: (any Error).self) {
            try rig.book.record(.init(result: b, source: rig.source()), call: call, acceptedProposalID: first)
        }
    }
    @Test func unqualifiedResultNeverAdmitsEvenWhenItsSummaryAndVerificationLookValid() throws {
        let rig = try Rig(), call = rig.call(), proposal = UUID(), result = rig.result("Unqualified private source")
        try rig.book.record(.init(result: result, source: nil), call: call, acceptedProposalID: proposal)
        #expect(throws: (any Error).self) { try rig.book.admission(call: call, acceptedProposalID: proposal, result: result) }
        #expect(rig.validations == 0)
    }
    @Test func retainedSourceAndTaskRevocationAreCheckedAgainWithoutCaptureOrInput() async throws {
        let rig = try Rig(), call = rig.call(), proposal = UUID(), result = rig.result("private")
        try rig.book.record(.init(result: result, source: rig.source()), call: call, acceptedProposalID: proposal)
        let check = try rig.book.admission(call: call, acceptedProposalID: proposal, result: result)
        rig.sourceCurrent = false
        await #expect(throws: (any Error).self) { try await check() }
        rig.sourceCurrent = true; rig.current = false
        await #expect(throws: (any Error).self) { try await check() }
    }
    @Test func aClearedBookCannotReviveAnOldValidatorForTheSameProposalAndResult() async throws {
        let rig = try Rig(), call = rig.call(), proposal = UUID(), result = rig.result("private")
        let source = rig.source()
        try rig.book.record(.init(result: result, source: source), call: call, acceptedProposalID: proposal)
        let old = try rig.book.admission(call: call, acceptedProposalID: proposal, result: result)
        rig.book.stop()
        try rig.book.record(.init(result: result, source: source), call: call, acceptedProposalID: proposal)
        await #expect(throws: (any Error).self) { try await old() }
        try await rig.book.admission(call: call, acceptedProposalID: proposal, result: result)()
    }
    @Test func boundedMetadataEvictionRefusesOldBodyWithoutImposingAnyTaskOrActionLifetimeLimit() async throws {
        let rig = try Rig(), call = rig.call(), first = UUID(), result = rig.result("first")
        try rig.book.record(.init(result: result, source: rig.source()), call: call, acceptedProposalID: first)
        let old = try rig.book.admission(call: call, acceptedProposalID: first, result: result)
        for index in 0..<1_030 {
            let proposal = UUID(), value = rig.result("current \(index)")
            try rig.book.record(.init(result: value, source: rig.source()), call: call, acceptedProposalID: proposal)
            try await rig.book.admission(call: call, acceptedProposalID: proposal, result: value)()
        }
        await #expect(throws: (any Error).self) { try await old() }
    }
    @MainActor private final class Rig {
        let application = DesktopApplicationIdentity(processID: 42, launchedAt: .init(timeIntervalSince1970: 1),
            bundleID: "test.actual.synthetic", bundleURL: URL(fileURLWithPath: "/Owned Synthetic.app"))
        let sourceID = UUID()
        var current = true, sourceCurrent = true, validations = 0
        let scope: NativeVisualTaskScope
        lazy var book = NativeCurrentReadbackReceipts(scope: scope)
        init() throws {
            let state = State(), task = UUID()
            let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
            let read = NativeLocalTaskReadAuthority.localUserInvocation(taskID: task, taskIsCurrent: { state.current })
            scope = try .init(logicalTaskID: task, runRevision: 1, run: run, originalObjective: "Read the admitted original synthetic source.",
                inferenceIdentity: .embedded(path: "/inert/not-loaded.litertlm", compute: "cpu"), readAuthority: read,
                validateAcknowledgedStoreRun: { guard state.current else { throw CancellationError() } })
            scopeState = state
        }
        private let scopeState: State
        private final class State { var current = true }
        func call(id: String = "provider-id") -> ToolCall { .init(id: id, name: NativeWindowReadTool.name,
            arguments: ["bundle_id": .string(application.bundleID), "question": .string("What is visible?")]) }
        func result(_ text: String) -> ToolResult { .init(summary: text, evidence: "Actual synthetic read result", verified: true) }
        func source() -> NativeCurrentReadbackSource { .init(sourceID: sourceID, application: application, validateOriginalSource: { [self] in
            scopeState.current = current
            try scope.validate()
            guard sourceCurrent else { throw NativeVisualTaskFailure.staleProposal }
            validations += 1
        }) }
    }
}
