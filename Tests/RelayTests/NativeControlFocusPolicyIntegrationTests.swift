import Foundation
import Testing
@testable import Relay

@Suite @MainActor struct NativeControlFocusPolicyIntegrationTests {
    @Test func actualPolicyIssuesDeferredMatchingFocusOnlyInsideAdmittedExecution() async throws {
        let test = try Rig(), proposal = try await test.prepare()
        #expect(test.focusCalls == 0 && test.rig.commands.isEmpty && !test.rig.foreground)
        #expect(proposal.context.frame?.jpeg == test.planningFrame?.jpeg)
        let outcome = try await test.rig.session.execute(proposal)
        guard case .readback(_, _, .restored) = outcome else { Issue.record("Expected retained focus and original-target readback."); return }
        #expect(test.focusCalls == 1 && test.rig.commands.count == 1 && test.rig.foreground)
        await #expect(throws: NativeControlSession.Failure.consumed) { try await test.rig.session.execute(proposal) }
        #expect(test.focusCalls == 1 && test.rig.commands.count == 1)
    }

    @Test func aFocusAttemptFollowedByStopRemainsUncertainAndNeverSendsTheKey() async throws {
        let test = try Rig(), proposal = try await test.prepare()
        test.afterFocus = { test.rig.session.stop() }
        let outcome = try await test.rig.session.execute(proposal)
        guard case .focusOnly(.uncertain, _) = outcome else { Issue.record("Stop cannot erase an attempted focus phase."); return }
        #expect(test.focusCalls == 1 && test.rig.commands.isEmpty && test.rig.textWrites == 0)
        #expect(NativeVisualStepOutcome.controller(outcome).journalKind == .effectUncertain)
    }

    @Test func sourceDriftAfterRestorationRetainsOnlyThatFocusFactAndDoesNotRebind() async throws {
        let test = try Rig(), proposal = try await test.prepare(), captures = test.rig.captureCount
        test.afterFocus = { test.rig.sourceVersion += 1 }
        let outcome = try await test.rig.session.execute(proposal)
        guard case .focusOnly(.restored, _) = outcome else { Issue.record("Original-window drift must preserve the completed focus fact."); return }
        #expect(test.focusCalls == 1 && test.rig.commands.isEmpty && test.rig.textWrites == 0)
        #expect(test.rig.captureCount == captures)
        #expect(NativeVisualStepOutcome.controller(outcome).journalKind == .returnedUnverified)
    }

    @Test func focusCannotRenewTheOriginalTransportReservationDeadline() async throws {
        let test = try Rig(), proposal = try await test.prepare()
        test.afterFocus = { test.rig.now = test.rig.now.advanced(by: .seconds(91)) }
        let outcome = try await test.rig.session.execute(proposal)
        guard case .focusOnly(.restored, _) = outcome else { Issue.record("Expired post-focus admission must preserve focus without input."); return }
        #expect(test.focusCalls == 1 && test.rig.commands.isEmpty && test.rig.textWrites == 0)
    }

    @Test(arguments: ["stop", "inactive", "source", "readback"])
    func unchangedAXDecisionRetainsActualRestoredFocusOnLatePostcheckFailure(_ refusal: String) async throws {
        let test = try Rig(), proposal = try await test.prepare(action: .typeUnsentText("Original"))
        var readsAtStop: Int?
        test.rig.afterAXOutcome = { outcome in
            #expect(outcome == .unchanged)
            #expect(test.focusCalls == 1 && test.rig.textWrites == 0)
            switch refusal {
            case "stop": readsAtStop = test.rig.textReads; test.rig.session.stop()
            case "inactive": readsAtStop = test.rig.textReads; test.rig.session.setSessionActive(false)
            case "source": test.rig.sourceVersion += 1
            default: test.rig.captureFailureAt = test.rig.captureCount + 1
            }
        }
        let result = try await test.rig.session.execute(proposal)
        guard case .focusOnly(.restored, _) = result else {
            Issue.record("A no-write decision cannot erase completed original-window focus."); return
        }
        #expect(test.focusCalls == 1 && test.rig.textWrites == 0 && test.rig.commands.isEmpty)
        if let readsAtStop { #expect(test.rig.textReads == readsAtStop) }
        #expect(NativeVisualStepOutcome.controller(result).journalKind == .returnedUnverified)
        await #expect(throws: (any Error).self) { try await test.rig.session.execute(proposal) }
        #expect(test.focusCalls == 1 && test.rig.textWrites == 0 && test.rig.commands.isEmpty)
    }

    @MainActor private final class Rig {
        let rig = NextNativeControlRig()
        let scope: NativeVisualTaskScope
        let policy: NativeOrdinaryVisualPolicy
        var focusCalls = 0
        var afterFocus: (@MainActor () -> Void)?
        var planningFrame: NativeVisionFrame?
        init() throws {
            let taskID = UUID()
            let run = try AssistantConversationHistory.Run(logicalTaskID: taskID, cause: .newRequest)
            let authority = NativeLocalTaskReadAuthority.localUserInvocation(taskID: taskID,
                taskIsCurrent: { true }, resolve: { _ in throw NativeVisualTaskFailure.staleTask })
            scope = try NativeVisualTaskScope(logicalTaskID: taskID, runRevision: 1, run: run,
                originalObjective: "Use the original synthetic plain editor for one ordinary unsent editing or navigation step.",
                inferenceIdentity: .embedded(path: "/inert/model-not-loaded.litertlm", compute: "cpu"),
                readAuthority: authority, validateAcknowledgedStoreRun: {})
            policy = NativeOrdinaryVisualPolicy(inspect: { _, _ in
                NativeOrdinaryAssessment(boundary: .ordinary, permitsTaskAuthorizedFocus: true,
                    visualProof: .wholeFrame, validateSemanticContext: {})
            }, review: { _, _, _ in Issue.record("Known task-authorized focus does not invent a new review requirement."); return false })
            let localRig = rig
            rig.session = NativeControlSession(backend: rig.backend, sessionIsActive: { localRig.active },
                authorizer: policy, clockNow: { localRig.now })
            rig.foreground = false
            rig.focusRestorer = { [weak self] authorization, gate, deadline in
                guard let self, gate.isActive, self.rig.now < deadline else { return .refused("Inactive synthetic admission.") }
                do {
                    try authorization.validateOriginalScope()
                    try authorization.admitOriginalFocusOnce()
                } catch { return .refused("The exact original focus capability refused admission.") }
                self.focusCalls += 1; self.rig.foreground = true
                self.afterFocus?()
                guard gate.isActive else { return .uncertain("The admitted synthetic focus phase stopped.") }
                return .restored
            }
        }
        func prepare(action: NativeControlSession.Action = .key(.left)) async throws -> NativeControlSession.ReviewedProposal {
            let observation = try await rig.plan(), source = try rig.session.source(from: observation)
            let frame = try await rig.frame(observation); planningFrame = frame
            let call: ToolCall
            if case .typeUnsentText(let literal) = action {
                call = ToolCall(id: "original-provider-call", name: NativeWindowControlTools.textName,
                    arguments: ["observation_id": .string(observation.snapshot.id.uuidString), "text": .string(literal),
                        "intended_effect": .string("Enter only the original exact unsent literal")])
            } else {
                call = ToolCall(id: "original-provider-call", name: NativeWindowControlTools.keyName,
                    arguments: ["observation_id": .string(observation.snapshot.id.uuidString), "key": .string("Left"),
                        "intended_effect": .string("Navigate within the original inert editor")])
            }
            let identity = try NativeVisualProposalIdentity(scope: scope, acceptedReplyID: UUID(), call: call)
            let operation = NativeWindowControlPlanningPhase.Operation(taskID: scope.logicalTaskID, runRevision: scope.runRevision,
                originalReply: .init(content: "", toolCalls: [call]), call: call,
                proposal: .input(action, intendedEffect: "Use only the original inert editor"),
                observation: observation, frame: frame)
            try policy.begin(.init(scope: scope, identity: identity, operation: operation, sourceID: source.id,
                validateOriginalSource: { [rig] in try rig.session.validateOriginalSource(source) }))
            return try await rig.session.prepareForReview(action, request: identity.admission(scope: scope),
                from: observation, frame: frame)
        }
    }
}
