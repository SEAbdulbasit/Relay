import Foundation

/// Closed facts supplied by trusted task/OS policy code, never by tool arguments
/// or a model's risk labels. Unknown canvas is reviewable, not an app allowlist.
@MainActor struct NativeOrdinaryAssessment {
    enum Boundary { case protected, dedicated(String), ordinary, review }
    let boundary: Boundary
    /// Trusted original-task/semantic authority, never a model argument. Known
    /// ordinary paths may include bounded original focus without another review.
    let permitsTaskAuthorizedFocus: Bool
    let visualProof: NativeVisualProofScope
    let validateSemanticContext: @MainActor () throws -> Void
}

@MainActor enum NativeReviewedFocusOutcome {
    case notRequested
    case alreadyFocused
    case restored
    case refused(String)
    case uncertain(String)
}

/// An approval-bound, process-local focus request. It is not Codable and cannot
/// be manufactured from the review view's presentation UUID or model geometry.
@MainActor final class NativeReviewedFocusAuthorization {
    let policyContextID: UUID
    let requestID: String
    let sourceID: UUID
    let taskID: UUID
    let revision: Int
    private let validateOriginal: @MainActor () throws -> Void
    private var used = false
    private var revoked = false
    fileprivate init(context: NativeControlSession.PolicyContext, scope: NativeVisualTaskScope,
                     validateOriginal: @escaping @MainActor () throws -> Void) {
        policyContextID = context.id; requestID = context.requestID; sourceID = context.sourceID
        taskID = scope.logicalTaskID; revision = scope.runRevision
        self.validateOriginal = { try scope.validate(); try validateOriginal() }
    }
    func validateOriginalScope() throws {
        guard !revoked else { throw NativeVisualTaskFailure.stopped }
        try validateOriginal()
    }
    func admitOriginalFocusOnce() throws {
        guard !used else { throw NativeVisualTaskFailure.duplicateAttempt }
        try validateOriginalScope(); used = true
    }
    fileprivate func revoke() { revoked = true }
}

/// One task-owned authorizer. Its single current envelope is not an ID ledger.
/// The controller and journal still own actual input/durable dedup admission.
@MainActor final class NativeOrdinaryVisualPolicy: NativeControlAuthorizing {
    typealias Inspect = @MainActor (NativeControlSession.PolicyContext, NativeVisualTaskScope) throws -> NativeOrdinaryAssessment
    typealias Review = @MainActor (ToolCall, String, NativeVisualReviewPresentation?) async throws -> Bool

    struct Envelope {
        let scope: NativeVisualTaskScope
        let identity: NativeVisualProposalIdentity
        let operation: NativeWindowControlPlanningPhase.Operation
        let sourceID: UUID
        /// Retained original target only; independent of the consumed image epoch.
        let validateOriginalSource: @MainActor () throws -> Void
    }
    private final class Grant {
        var consumed = false
        var revoked = false
        let validateSource: @MainActor () throws -> Void
        let validateBeforeInput: @MainActor () throws -> Void
        init(validateSource: @escaping @MainActor () throws -> Void,
             validateBeforeInput: @escaping @MainActor () throws -> Void) {
            self.validateSource = validateSource; self.validateBeforeInput = validateBeforeInput
        }
        func revalidate() throws {
            guard !consumed, !revoked else { throw NativeVisualTaskFailure.staleProposal }
            try validateSource(); try validateBeforeInput()
        }
        func consume() throws { try revalidate(); consumed = true }
        func afterConsumption() throws {
            guard !revoked else { throw NativeVisualTaskFailure.stopped }
            try validateSource()
        }
    }

    private let inspect: Inspect
    private let review: Review
    private var envelope: Envelope?
    private var grant: Grant?
    private(set) var reviewedFocusAuthorization: NativeReviewedFocusAuthorization?

    init(inspect: @escaping Inspect, review: @escaping Review) { self.inspect = inspect; self.review = review }

    func begin(_ envelope: Envelope) throws {
        guard self.envelope == nil else { throw NativeControlSession.Failure.busy }
        try envelope.scope.validate(); try envelope.validateOriginalSource()
        try envelope.identity.validate(scope: envelope.scope, call: envelope.operation.call)
        self.envelope = envelope; reviewedFocusAuthorization = nil
    }
    func retire() { grant?.revoked = true; reviewedFocusAuthorization?.revoke(); grant = nil; reviewedFocusAuthorization = nil; envelope = nil }
    func stop() { retire() }

    func authorize(_ context: NativeControlSession.PolicyContext) async throws -> NativeControlSession.PolicyPermit {
        guard let envelope else { throw NativeVisualTaskFailure.staleProposal }
        let scope = envelope.scope, identity = envelope.identity, operation = envelope.operation
        try scope.validate(); try envelope.validateOriginalSource()
        guard context.sourceID == envelope.sourceID,
              Data(context.requestID.utf8) == Data(identity.controllerRequestID.utf8),
              context.originalProviderCallID == identity.rawCallID.bytes,
              context.exactCallDigest == identity.callDigest,
              context.application == operation.observation.snapshot.application,
              context.window.matchesExactly(operation.observation.snapshot.window),
              context.observationID == operation.observation.snapshot.id,
              case .input(let expected, let intendedEffect) = operation.proposal,
              Self.sameAction(context.action, expected) else { throw NativeVisualTaskFailure.staleProposal }
        let assessment = try inspect(context, scope)
        try assessment.validateSemanticContext()
        switch assessment.boundary {
        case .protected: throw NativeVisualTaskFailure.protectedEffect
        case .dedicated(let workflow): throw NativeVisualTaskFailure.dedicatedWorkflow(workflow)
        case .ordinary, .review: break
        }

        let needsReview: Bool
        if case .review = assessment.boundary { needsReview = true } else { needsReview = false }
        if needsReview {
            let presentation: NativeVisualReviewPresentation?
            switch context.action {
            case .click(let imageID, let point):
                guard imageID == operation.frame.id else { throw NativeVisualTaskFailure.staleProposal }
                presentation = try NativeVisualReviewPresentation(taskID: scope.logicalTaskID, taskRevision: scope.runRevision,
                    frame: operation.frame, gesture: .click(point), sourceLabel: context.application.bundleID,
                    intendedEffect: intendedEffect)
            case .drag(let imageID, let from, let to):
                guard imageID == operation.frame.id else { throw NativeVisualTaskFailure.staleProposal }
                presentation = try NativeVisualReviewPresentation(taskID: scope.logicalTaskID, taskRevision: scope.runRevision,
                    frame: operation.frame, gesture: .drag(from: from, to: to), sourceLabel: context.application.bundleID,
                    intendedEffect: intendedEffect)
            case .key(let key):
                guard let target = try Self.reviewTarget(context.focusedTarget) else {
                    throw NativeVisualTaskFailure.unavailableDependency("privacy-admitted original focus description")
                }
                presentation = try NativeVisualReviewPresentation(taskID: scope.logicalTaskID, taskRevision: scope.runRevision,
                    frame: operation.frame, gesture: .navigationKey(key, target: target),
                    sourceLabel: context.application.bundleID, intendedEffect: intendedEffect)
            case .typeUnsentText(let literal):
                guard let target = try Self.reviewTarget(context.focusedTarget) else {
                    throw NativeVisualTaskFailure.unavailableDependency("privacy-admitted original editor description")
                }
                presentation = try NativeVisualReviewPresentation(taskID: scope.logicalTaskID, taskRevision: scope.runRevision,
                    frame: operation.frame, gesture: .unsentText(literal: literal, target: target),
                    sourceLabel: context.application.bundleID, intendedEffect: intendedEffect)
            }
            if let presentation, !presentation.imageIsDecodable { throw NativeVisionFailure.invalidImage }
            let reason = """
                Original task: \(scope.originalObjective)
                Proposed ordinary effect: \(intendedEffect)
                Approval brings only this retained original window forward, then attempts this one action. It cannot authorize a different window or dedicated consequential workflow.
                """
            guard try await review(identity.call, reason, presentation) else { throw NativeVisualTaskFailure.reviewDeclined }
            try scope.validate(); try envelope.validateOriginalSource(); try assessment.validateSemanticContext()
        }
        try scope.validate(); try envelope.validateOriginalSource()
        try assessment.validateSemanticContext()
        let source: @MainActor () throws -> Void = {
            try scope.validate(); try envelope.validateOriginalSource()
            try identity.validate(scope: scope, call: identity.call)
        }
        let current = Grant(validateSource: source, validateBeforeInput: {
            // Semantic/source revalidation may run during source-only review
            // preparation. The controller owns foreground/focus admission after
            // deferred restoration, inside the inserted effect/FIFO reservation.
            try assessment.validateSemanticContext()
        }); grant = current
        if needsReview || assessment.permitsTaskAuthorizedFocus {
            reviewedFocusAuthorization = NativeReviewedFocusAuthorization(context: context, scope: scope,
                validateOriginal: { try current.afterConsumption() })
        }
        return NativeControlSession.PolicyPermit(visualProof: assessment.visualProof,
            revalidate: { try current.revalidate() }, consume: { try current.consume() },
            validateTaskSource: { try current.afterConsumption() },
            reviewedOriginalFocus: reviewedFocusAuthorization)
    }

    private static func reviewTarget(_ descriptor: NativeControlTargetDescriptor?) throws -> NativeVisualReviewPresentation.FocusedTarget? {
        guard let descriptor else { return nil }
        let selection = try descriptor.selection.map {
            try NativeVisualReviewPresentation.FocusedTarget.Selection(location: $0.location,
                length: $0.length, originalUTF16Count: $0.originalUTF16Count)
        }
        return try .init(role: descriptor.role, label: descriptor.label,
            identifier: descriptor.identifier, selection: selection)
    }

    private static func sameAction(_ actual: NativeControlSession.Action, _ expected: NativeControlSession.Action) -> Bool {
        if case .typeUnsentText(let left) = actual, case .typeUnsentText(let right) = expected {
            return Data(left.utf8) == Data(right.utf8)
        }
        return actual == expected
    }
}
