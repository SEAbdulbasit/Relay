import Foundation
import Testing
@testable import Relay

/// No AX/SDK/client/model/UI/filesystem work and no synthetic ACK maker. The
/// future real saved-message bridge/positive adoption remains a separate gate.
@MainActor @Suite struct NativeExactUnsentAdoptionTests {
    @Test func deliveryStatusEvenSavedNeverConstructsAnAcknowledgmentThroughTheUnboundBridge() throws {
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let pending = ConversationSubmission(messageID: UUID(), text: "Exact user request")
        #expect(throws: NativeExactUnsentFailure.acknowledgmentBridgeUnavailable) {
            try NativeExactUnsentAcknowledgment.bindSavedMessage(pending, run: run)
        }
        let statuses: [ConversationSubmission.Status] = [.saved, .failed, .stopped]
        for status in statuses {
            let ticket = ConversationSubmission(messageID: UUID(), text: "Exact user request")
            ticket.resolve(status)
            #expect(ticket.status == status)
            #expect(throws: NativeExactUnsentFailure.acknowledgmentBridgeUnavailable) {
                try NativeExactUnsentAcknowledgment.bindSavedMessage(ticket, run: run)
            }
        }
    }

    @Test func appScopedAuthorityCannotEnterSuppliedOriginalPurposeOrOpenClient() throws {
        let rig = try Rig()
        let factory = try rig.makeFactory()
        #expect(throws: NativeExactUnsentFailure.wrongTask) { try factory.prepareInitialExactUnsent(using: rig.observer) }
        #expect(rig.opens == 0 && rig.captures == 0 && rig.closes == 0)
    }

    @Test func taskStopAndExistingBudgetFenceWinBeforeAnyPreparationOrCapture() throws {
        let stopped = try Rig()
        let stoppedFactory = try stopped.makeFactory()
        stopped.scope.stop()
        #expect(throws: NativeVisualTaskFailure.stopped) { try stoppedFactory.prepareInitialExactUnsent(using: stopped.observer) }
        #expect(stopped.opens == 0 && stopped.captures == 0)
        let expired = try Rig()
        let expiredFactory = try expired.makeFactory()
        expired.clock = 1
        #expect(throws: TaskRunBudget.Limit.activeWork) { try expiredFactory.prepareInitialExactUnsent(using: expired.observer) }
        #expect(expired.opens == 0 && expired.captures == 0)
    }

    @Test func actualPreparationOwnershipIsOneUseAndCannotCrossOrRetainAnObserverOwner() throws {
        final class Owner {}
        let claim = NativeExactUnsentPreparationOwnership(), original = Owner(), foreign = Owner()
        try claim.begin(owner: original); try claim.validate(owner: original)
        #expect(throws: NativeExactUnsentFailure.wrongTask) { try claim.validate(owner: foreign) }
        #expect(throws: NativeExactUnsentFailure.alreadyPrepared) { try claim.begin(owner: original) }
        #expect(throws: NativeExactUnsentFailure.alreadyPrepared) { try claim.begin(owner: foreign) }
        let failed = NativeExactUnsentPreparationOwnership()
        weak var released: Owner?
        do {
            let owner = Owner(); released = owner
            try failed.begin(owner: owner)
            // Simulates a later preparation failure without resetting ownership.
        }
        #expect(released == nil)
        #expect(throws: NativeExactUnsentFailure.alreadyPrepared) { try failed.begin(owner: foreign) }
        #expect(throws: NativeExactUnsentFailure.wrongTask) { try failed.validate(owner: foreign) }
    }

    private final class Clock { var now: TimeInterval = 0 }
    @MainActor private final class Rig {
        let scope: NativeVisualTaskScope
        let budget: TaskRunBudget
        private let time: Clock
        var clock: TimeInterval { get { time.now } set { time.now = newValue } }
        var opens = 0, captures = 0, closes = 0
        lazy var observer = TargetBoundNativeObservation(backend: .init(capture: { [weak self] _,_ in
            self?.captures += 1; throw NativeExactUnsentFailure.unavailable
        }, close: { [weak self] in self?.closes += 1 }), sessionIsActive: { true })
        func makeFactory() throws -> NativeProductionTaskConnectionFactory {
            try NativeProductionTaskConnectionFactory(scope: scope,
            inputAuthority: .localUserInvocation(scope: scope, windowRequirement: .appScoped,
                validateAcknowledgedInputGrant: { [self] in try budget.check() }),
            platform: .init(open: { [self] _,_ in opens += 1; throw NativeExactUnsentFailure.unavailable },
                observeRead: { _,_ in throw NativeExactUnsentFailure.unavailable }))
        }
        init() throws {
            let time = Clock(), task = UUID()
            self.time = time
            let budget = TaskRunBudget(activeLimit: 1, lifetimeLimit: 10, now: { time.now })
            self.budget = budget
            let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
            let read = NativeLocalTaskReadAuthority.localUserInvocation(taskID: task, taskIsCurrent: { true },
                resolve: { _ in throw NativeExactUnsentFailure.unavailable })
            scope = try NativeVisualTaskScope(logicalTaskID: task, runRevision: 1, run: run,
                originalObjective: "Infrastructure-only explicit request.",
                inferenceIdentity: .embedded(path: "/inert/not-loaded.litertlm", compute: "cpu"),
                readAuthority: read, validateAcknowledgedStoreRun: { try budget.check() })
        }
    }
}
