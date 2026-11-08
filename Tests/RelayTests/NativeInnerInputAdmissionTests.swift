import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

/// Real SQLite intent/result boundaries; the only source is an owned inert
/// liveness flag. No native/model/provider/AX/window runtime is constructed.
@Suite(.serialized) @MainActor struct NativeInnerInputAdmissionTests {
    @Test(arguments: ["prepare", "report", "effect"])
    func eachInnerStageRechecksItsAcceptedInputAfterIntentCommitBeforeItsAction(_ stage: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-native-inner-proof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json"))
        let task = UUID(), run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
        let read = NativeLocalTaskReadAuthority.localUserInvocation(taskID: task, taskIsCurrent: { true })
        let scope = try NativeVisualTaskScope(logicalTaskID: task, runRevision: 1, run: run,
            originalObjective: "Reconcile only the actual admitted synthetic source.",
            inferenceIdentity: .embedded(path: "/inert/not-loaded.litertlm", compute: "cpu"),
            readAuthority: read, validateAcknowledgedStoreRun: {})
        try await history.prepare(run)
        let core = try await history.journalForTesting(), state = Liveness()
        let proof = ModelInputSourceProof.source(identity: .init(owner: run.taskID,
            sourceID: Data("actual-owned-source".utf8), purpose: "inert original source")) {
                guard state.isCurrent else { throw NativeVisualTaskFailure.staleTask }
            }
        let journal = NativeVisualTaskJournal(history: history, scope: scope,
            unsavedFact: { _ in Issue.record("No actual stage action returned a fact") })
        let observation = UUID(), image = UUID()
        let call = stage == "report" ? ToolCall(id: "original-inner-call", name: NativeWindowControlTools.observeName,
            arguments: ["observation_id": .string(observation.uuidString), "image_id": .string(image.uuidString),
                "disposition": .string("cannot_determine"), "detail": .string("PRIVATE_SYNTHETIC_REPORT")])
            : ToolCall(id: "original-inner-call", name: NativeWindowControlTools.outerName,
                arguments: ["bundle_id": .string("test.admitted"), "instruction": .string("One inert source-bound step")])
        let identity = try NativeVisualProposalIdentity(scope: scope, acceptedReplyID: UUID(), call: call)
        var stageActions = 0
        await core.atNextBoundary(.afterCommit) { state.revoke() }
        do {
            switch stage {
            case "prepare":
                _ = try await journal.prepare(anchor: identity, actualOriginalRead: false, inputProof: proof) {
                    stageActions += 1; throw NativeVisualTaskFailure.staleProposal
                }
            case "report":
                _ = try await journal.report(identity: identity,
                    report: NativeObservationReport(kind: .cannotDetermine, detail: "PRIVATE_SYNTHETIC_REPORT"),
                    observationID: observation, imageID: image, inputProof: proof, validateCurrent: {})
            default:
                _ = try await journal.effect(identity: identity, inputProof: proof) {
                    stageActions += 1; return .uncertain("This action must not be entered")
                }
            }
            Issue.record("Post-intent revoked input was admitted")
        } catch { #expect(error as? NativeVisualTaskFailure == .staleTask) }
        #expect(!state.isCurrent && stageActions == 0)
        let expected = try await core.scope()
        let page = try await core.page(expectedScope: expected)
        let results = page.records.compactMap { row -> JournalToolOutcome? in
            if case .result(let value) = row.event.payload { value } else { nil }
        }
        #expect(results.count == 1 && results.first?.kind == .notDispatched)
        #expect(results.allSatisfy { $0.evidence?.text.contains("PRIVATE_SYNTHETIC_REPORT") != true })
        try await history.close()
    }
    nonisolated private final class Liveness: @unchecked Sendable {
        private let lock = NSLock(); private var current = true
        var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return current }
        func revoke() { lock.lock(); current = false; lock.unlock() }
    }
}
