import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import ImageIO

/// Spellings remain unqualified until the owned key oracle passes against this provider.
/// Return, application shortcuts, modifiers and arbitrary key strings are intentionally absent.
nonisolated enum NativeControlKey: String, Sendable, CaseIterable {
    case left = "Left", right = "Right", up = "Up", down = "Down", home = "Home", end = "End"
}

/// A trusted policy adapter supplies semantic scope and any required review. Native catalog
/// annotations, image text, labels and model assertions never create this authority.
@MainActor protocol NativeControlAuthorizing {
    func authorize(_ context: NativeControlSession.PolicyContext) async throws -> NativeControlSession.PolicyPermit
}

@MainActor struct DenyNativeControlMutations: NativeControlAuthorizing {
    func authorize(_ context: NativeControlSession.PolicyContext) throws -> NativeControlSession.PolicyPermit {
        throw NativeControlSession.Failure.unqualifiedEffect
    }
}

/// One owner, one native FIFO and one observation namespace. This is deliberately not a tool
/// registry or Codable history payload; no arbitrary native tool names/indices are accepted.
@MainActor final class NativeControlSession {
    /// Actual Controller-produced fact, never an executable/recovered token.
    /// History's separate saved-result producer binds this exact object.
    @MainActor final class ExactUnsentEffect {
        nonisolated enum Phase: String, Sendable, Hashable { case focus, insertion }
        nonisolated enum Fact: Sendable, Equatable {
            case focus(NativeOriginalWindowFocus.ExactReport)
            case insertion(NativeFocusedAXInsertion.Outcome)
        }
        nonisolated let identity: NativeExactUnsentOperation.Identity
        nonisolated let logicalTaskID: UUID, runID: UUID, attemptID: UUID, proposalID: UUID, anchorID: UUID, requestID: UUID
        nonisolated let invocationID: UUID
        nonisolated let phase: Phase
        nonisolated let literalDigest: Data, callDigest: Data
        nonisolated let outcome: Fact
        fileprivate init(identity: NativeExactUnsentOperation.Identity, invocationID: UUID, outcome: Fact) {
            self.identity = identity; self.outcome = outcome
            self.invocationID = invocationID
            logicalTaskID = identity.logicalTaskID; runID = identity.runID; attemptID = identity.attemptID
            proposalID = identity.proposalID; anchorID = identity.anchorID; requestID = identity.requestID
            phase = identity.phase; literalDigest = identity.literalDigest; callDigest = identity.callDigest
        }
    }
    /// Actual observer-bound, image-free source. Its constructor and executable
    /// members are file-only; callers cannot supply AX IO or positive facts.
    @MainActor final class ExactUnsentPreparation {
        nonisolated let sourceID: UUID
        nonisolated let application: DesktopApplicationIdentity
        fileprivate weak var controller: NativeControlSession?
        fileprivate let owner: UUID, revision: UUID
        fileprivate let observer: TargetBoundNativeObservation
        fileprivate let lease: TargetBoundNativeObservation.TargetLease
        fileprivate let scope: NativeVisualTaskScope
        fileprivate let purpose: NativeExactUnsentPurpose
        fileprivate let authority: NativeLocalTaskInputAuthority
        fileprivate let applicationObject: NSRunningApplication
        fileprivate let root: AXUIElement, window: AXUIElement, editor: AXUIElement
        fileprivate let policyTarget: NativeOriginalPolicyTarget
        /// This actual preparation is minted only after the anchor's one-shot
        /// observer adoption. Never replace/reset this acquisition on an error,
        /// image revision, later phase or storage-only continuation.
        fileprivate let initialMetadata = NativeInitialMetadataAcquisition()
        fileprivate var initialPrivacyAdmissionBegan = false
        fileprivate var admittedFacts: NativeOrdinaryWindowPolicySource.Facts?
        fileprivate var focus: NativeOriginalWindowFocus?
        fileprivate var writer: NativeFocusedAXInsertion?
        fileprivate var insertion: NativeFocusedAXInsertion.PreparedInsertion?
        fileprivate var focusStarted = false, insertionStarted = false
        fileprivate var focusEffect: ExactUnsentEffect?, insertionEffect: ExactUnsentEffect?
        fileprivate init(controller: NativeControlSession, observer: TargetBoundNativeObservation,
                         lease: TargetBoundNativeObservation.TargetLease, scope: NativeVisualTaskScope,
                         purpose: NativeExactUnsentPurpose, authority: NativeLocalTaskInputAuthority,
                         application: NSRunningApplication, root: AXUIElement, window: AXUIElement,
                         editor: AXUIElement, policyTarget: NativeOriginalPolicyTarget) {
            self.controller = controller; owner = controller.owner; revision = controller.revision
            self.observer = observer; self.lease = lease; sourceID = lease.sourceID; self.application = lease.application
            self.scope = scope; self.purpose = purpose; self.authority = authority; applicationObject = application
            self.root = root; self.window = window; self.editor = editor; self.policyTarget = policyTarget
        }
    }

    /// Sealed Controller permit for the actual disclosed direct objective. It
    /// is distinct from an ordinary visual review/PolicyContext.
    @MainActor final class ExactUnsentFocusPermit {
        let sourceID: UUID
        private let source: ExactUnsentPreparation
        private let seal: NativeExactUnsentOperation.DispatchSeal
        private let identity: NativeExactUnsentOperation.Identity
        private var consumed = false
        fileprivate init(source: ExactUnsentPreparation, seal: NativeExactUnsentOperation.DispatchSeal,
                         identity: NativeExactUnsentOperation.Identity) {
            self.source = source; self.seal = seal; self.identity = identity; sourceID = source.sourceID
        }
        func validate() throws {
            guard let controller = source.controller else { throw Failure.stopped }
            try seal.validate(source: source, identity: identity)
            try controller.validateExactUnsent(source, requireInput: false)
            // Genuine saved-owner/disclosed-focus bridge is owned by Invocation/Store.
            try source.purpose.requireOriginalFocusApproval(scope: source.scope)
            try controller.admitExactUnsentPrivacy(source)
            try seal.validate(source: source, identity: identity)
        }
        func consume() throws {
            guard !consumed else { throw Failure.consumed }
            try validate(); consumed = true
        }
    }

    @MainActor final class ExactUnsentFocusExecution {
        nonisolated let requestID: UUID, callDigest: Data, appPath: String
        nonisolated let gate: NativeInputRevocation
        private let source: ExactUnsentPreparation
        private let seal: NativeExactUnsentOperation.DispatchSeal
        private let identity: NativeExactUnsentOperation.Identity
        private var began = false
        fileprivate init(source: ExactUnsentPreparation, seal: NativeExactUnsentOperation.DispatchSeal,
                         identity: NativeExactUnsentOperation.Identity, gate: NativeInputRevocation) {
            self.source = source; self.seal = seal; self.identity = identity; self.gate = gate
            requestID = identity.requestID; callDigest = identity.callDigest; appPath = source.application.bundleURL.path
        }
        func perform(notAfter: ContinuousClock.Instant) async throws -> ExactUnsentEffect {
            guard !began, let controller = source.controller, let focus = source.focus else { throw Failure.consumed }
            began = true
            try seal.validate(source: source, identity: identity)
            try controller.validateExactUnsent(source, requireInput: false)
            let permit = ExactUnsentFocusPermit(source: source, seal: seal, identity: identity)
            let report = await focus.restoreExactUnsent(authorization: permit, gate: gate, notAfter: notAfter)
            // No post-action owner throw: Stop cannot erase an actual admitted
            // activate/raise fact. The caller saves this on the original Run.
            let fact = ExactUnsentEffect(identity: identity, invocationID: seal.invocationID, outcome: .focus(report))
            source.focusEffect = fact
            return fact
        }
    }

    @MainActor final class ExactUnsentInsertionExecution {
        nonisolated let requestID: UUID, callDigest: Data, appPath: String
        nonisolated let gate: NativeInputRevocation
        private let source: ExactUnsentPreparation
        private let seal: NativeExactUnsentOperation.DispatchSeal
        private let identity: NativeExactUnsentOperation.Identity
        private var began = false, consumed = false
        fileprivate init(source: ExactUnsentPreparation, seal: NativeExactUnsentOperation.DispatchSeal,
                         identity: NativeExactUnsentOperation.Identity, gate: NativeInputRevocation) {
            self.source = source; self.seal = seal; self.identity = identity; self.gate = gate
            requestID = identity.requestID; callDigest = identity.callDigest; appPath = source.application.bundleURL.path
        }
        func perform(notAfter: ContinuousClock.Instant) throws -> ExactUnsentEffect {
            guard !began, let controller = source.controller,
                  let writer = source.writer, let insertion = source.insertion else { throw Failure.consumed }
            began = true
            defer { writer.stop(); controller.forget(writer); source.writer = nil; source.insertion = nil }
            let check: @MainActor () throws -> Void = {
                try self.seal.validate(source: self.source, identity: self.identity)
                try controller.validateExactUnsent(self.source, requireInput: true)
                try controller.revalidateExactUnsentPrivacy(self.source)
            }
            try check()
            try controller.admitExactUnsentPrivacy(source)
            let value = writer.execute(insertion, authorization: .init(validateTaskSource: check,
                revalidate: { guard !self.consumed else { throw Failure.consumed }; try check() },
                consume: { guard !self.consumed else { throw Failure.consumed }; try check(); self.consumed = true }),
                notAfter: notAfter)
            let fact = ExactUnsentEffect(identity: identity, invocationID: seal.invocationID, outcome: .insertion(value))
            source.insertionEffect = fact
            return fact
        }
    }

    @MainActor final class ExactUnsentVerification {
        let sourceID: UUID, focusRequestID: UUID, insertionRequestID: UUID
        let literalDigest: Data, utf16Count: Int
        fileprivate init(source: ExactUnsentPreparation, focus: ExactUnsentEffect, insertion: ExactUnsentEffect) {
            sourceID = source.sourceID; focusRequestID = focus.requestID; insertionRequestID = insertion.requestID
            literalDigest = insertion.literalDigest; utf16Count = source.purpose.objective.literal.utf16.count
        }
    }
    @MainActor final class ExactUnsentReadRequest {
        nonisolated let gate: NativeInputRevocation
        nonisolated let requestID: UUID, callDigest: Data, appPath: String
        private let source: ExactUnsentPreparation
        private let focus: ExactUnsentEffect, insertion: ExactUnsentEffect
        private let focusSaved: AssistantConversationHistory.NativeTextEffectSettlement
        private let insertionSaved: AssistantConversationHistory.NativeTextEffectSettlement
        private let publication: NativeExactUnsentOperation.CompletionTransport
        fileprivate init(source: ExactUnsentPreparation, focus: ExactUnsentEffect, insertion: ExactUnsentEffect,
                         focusSaved: AssistantConversationHistory.NativeTextEffectSettlement,
                         insertionSaved: AssistantConversationHistory.NativeTextEffectSettlement,
                         publication: NativeExactUnsentOperation.CompletionTransport,
                         gate: NativeInputRevocation) {
            self.source = source; self.focus = focus; self.insertion = insertion
            self.focusSaved = focusSaved; self.insertionSaved = insertionSaved
            self.publication = publication
            self.gate = gate; requestID = insertion.requestID; callDigest = insertion.callDigest
            appPath = source.application.bundleURL.path
        }
        func perform(notAfter: ContinuousClock.Instant) throws -> ExactUnsentVerification {
            guard let controller = source.controller else { throw Failure.stopped }
            try focusSaved.validate(effect: focus); try insertionSaved.validate(effect: insertion)
            try controller.validateExactUnsent(source, requireInput: true)
            let first = try controller.readExactUnsent(source, notAfter: notAfter)
            let firstStyle = try NativeExactUnsentOperation.requireExactReadback(first, literal: source.purpose.objective.literal)
            let second = try controller.readExactUnsent(source, notAfter: notAfter)
            let secondStyle = try NativeExactUnsentOperation.requireExactReadback(second, literal: source.purpose.objective.literal)
            guard firstStyle.matches(secondStyle) else { throw NativeExactUnsentOperation.Failure.readbackMismatch }
            try focusSaved.validate(effect: focus); try insertionSaved.validate(effect: insertion)
            try controller.validateExactUnsent(source, requireInput: true)
            guard controller.clockNow() < notAfter else { throw NativeExactUnsentOperation.Failure.expired }
            let actual = ExactUnsentVerification(source: source, focus: focus, insertion: insertion)
            publication.publish(actual)
            return actual
        }
    }
    nonisolated enum Failure: Error, Equatable {
        case inactiveSession, stopped, staleObservation, consumed, wrongOwner, invalidAction
        case unqualifiedEffect, changedPixels, changedFocus, unavailableFocus, invalidImage, busy
        case conflictingRequest
    }
    nonisolated enum Action: Sendable, Equatable {
        /// Coordinates identify the attached local image, never AX points or screen points.
        case click(image: UUID, point: NativeVisionFrame.PixelPoint)
        case drag(image: UUID, from: NativeVisionFrame.PixelPoint, to: NativeVisionFrame.PixelPoint)
        case key(NativeControlKey)
        case typeUnsentText(String)
        var requiresEditorPreview: Bool {
            switch self { case .key, .typeUnsentText: true; case .click, .drag: false }
        }
    }

    struct PolicyContext {
        let id: UUID
        let requestID: String
        let originalProviderCallID: Data
        let exactCallDigest: Data
        let sourceID: UUID
        let focusedTarget: NativeControlTargetDescriptor?
        let action: Action
        let application: DesktopApplicationIdentity
        let window: TargetBoundNativeObservation.WindowInfo
        let observationID: UUID
        let frame: NativeVisionFrame?
        let focus: FocusFence?
        let textInsertion: NativeFocusedAXInsertion.PreparedInsertion?
        /// Exact process/window/document validation; does not establish semantic effect safety.
        let validateTarget: @MainActor () throws -> Void
    }

    /// The policy owns this revalidation closure and must freeze its complete semantic effect
    /// and review context. The session additionally enforces owner, generation and single use.
    struct PolicyPermit {
        let visualProof: NativeVisualProofScope
        let revalidate: @MainActor () throws -> Void
        let consume: @MainActor () throws -> Void
        /// Separate from an unconsumed review: this remains valid after consume.
        /// Exact AX insertion requires an explicit original task/source grant fence.
        let validateTaskSource: (@MainActor () throws -> Void)?
        let reviewedOriginalFocus: NativeReviewedFocusAuthorization?
        init(visualProof: NativeVisualProofScope = .wholeFrame,
             revalidate: @escaping @MainActor () throws -> Void,
             consume: @escaping @MainActor () throws -> Void,
             validateTaskSource: (@MainActor () throws -> Void)? = nil,
             reviewedOriginalFocus: NativeReviewedFocusAuthorization? = nil) {
            self.reviewedOriginalFocus = reviewedOriginalFocus
            self.visualProof = visualProof; self.revalidate = revalidate; self.consume = consume; self.validateTaskSource = validateTaskSource
        }
    }

    struct FocusFence {
        let descriptor: NativeControlTargetDescriptor
        let validateSourceBeforeInput: @MainActor () throws -> Void
        /// Process/window/focus object and source contents must match before keyboard input.
        let validateBeforeInput: @MainActor () throws -> Void
        /// Readback may contain edited text, but must remain on the original focus object.
        let validateAfterInput: @MainActor () throws -> Void
    }

    /// Only trusted in-process binders may create targets. The closures retain the original
    /// window/document; refreshing must never select a replacement/current window or tab.
    struct Target {
        let sourceID: UUID
        let application: DesktopApplicationIdentity
        let window: TargetBoundNativeObservation.WindowInfo
        let validateOriginalSource: @MainActor () throws -> Void
        let validateForInput: @MainActor () throws -> Void
        let capture: @MainActor (OwnedNativeComputerUseClient.ReservedState?) async throws -> TargetBoundNativeObservation.Snapshot
        let isCurrent: @MainActor (TargetBoundNativeObservation.Snapshot) -> Bool
        let captureFocusForReview: @MainActor (@escaping @MainActor () throws -> Void) throws -> FocusFence
        let restoreReviewedOriginalFocus: @MainActor (NativeReviewedFocusAuthorization, NativeInputRevocation, ContinuousClock.Instant) async -> NativeReviewedFocusOutcome
        var captureInsertionForReview: (@MainActor (NativeInputRevocation, @escaping @MainActor () throws -> Void) throws -> NativeFocusedAXInsertion)? = nil
        /// Trusted in-process binder only; no AX lookup by model/source labels.
        var policyTarget: (@MainActor () throws -> NativeOriginalPolicyTarget)? = nil
        /// Source-only privacy for this control target, never an input grant.
        /// Nil is allowed only for the separate general read path.
        var controlCapturePrivacy: (@MainActor (NativeOriginalPolicyTarget) throws -> Void)? = nil

        func validateControlReadPrivacy() throws {
            guard let controlCapturePrivacy else { return }
            try validateOriginalSource()
            guard let bind = policyTarget else { throw Failure.unqualifiedEffect }
            let metadata = try bind()
            guard metadata.sourceID == sourceID, metadata.application == application else { throw Failure.wrongOwner }
            try controlCapturePrivacy(metadata)
            try validateOriginalSource()
        }
        func captureForRead(_ reserved: OwnedNativeComputerUseClient.ReservedState?) async throws -> TargetBoundNativeObservation.Snapshot {
            try validateControlReadPrivacy()
            do {
                let snapshot = try await capture(reserved)
                try validateControlReadPrivacy()
                return snapshot
            } catch {
                // A late provider error can contain source text too. Retain it
                // only while the same control source/privacy fence is current.
                // Execute still preserves any earlier attempted effect/focus.
                if controlCapturePrivacy != nil {
                    try validateControlReadPrivacy()
                    try validateOriginalSource()
                }
                throw error
            }
        }
    }

    /// Source authority survives this owner's own image generation changes.
    struct OriginalSource {
        var id: UUID { target.sourceID }
        fileprivate let owner: UUID
        fileprivate let target: Target
    }

    struct Observation {
        let snapshot: TargetBoundNativeObservation.Snapshot
        fileprivate let owner: UUID
        fileprivate let revision: UUID
        fileprivate let target: Target
        fileprivate var inputPreview: InputPreview? = nil
        var hasNavigationPreview: Bool { inputPreview?.focus != nil && inputPreview?.retired == false }
        var hasTextInsertionPreview: Bool { inputPreview?.insertion != nil && inputPreview?.retired == false }
    }

    fileprivate final class InputPreview {
        var focus: FocusFence?
        var insertion: NativeFocusedAXInsertion?
        let validateAuthorization: @MainActor () throws -> Void
        var retired = false
        init(focus: FocusFence?, insertion: NativeFocusedAXInsertion?,
             validateAuthorization: @escaping @MainActor () throws -> Void) {
            self.focus = focus; self.insertion = insertion; self.validateAuthorization = validateAuthorization
        }
        func validate() throws {
            guard !retired else { throw Failure.staleObservation }
            try validateAuthorization()
            try focus?.validateSourceBeforeInput()
            try insertion?.validateSourcePreview()
            try validateAuthorization()
        }
        func stop() {
            retired = true; focus = nil; insertion?.stop(); insertion = nil
        }
    }

    final class ReviewedProposal {
        let context: PolicyContext
        fileprivate let owner: UUID
        fileprivate let revision: UUID
        fileprivate let source: Observation
        fileprivate let effect: Effect
        fileprivate let pixels: PixelProof?
        fileprivate let permit: PolicyPermit
        fileprivate let requestKey: Data
        fileprivate let fingerprint: Data
        fileprivate let request: NativeControlRequestAdmission
        fileprivate var consumed = false
        fileprivate init(context: PolicyContext, owner: UUID, revision: UUID, source: Observation,
                         effect: Effect, pixels: PixelProof?, permit: PolicyPermit,
                         requestKey: Data, fingerprint: Data, request: NativeControlRequestAdmission) {
            self.context = context; self.owner = owner; self.revision = revision; self.source = source
            self.effect = effect; self.pixels = pixels; self.permit = permit
            self.requestKey = requestKey; self.fingerprint = fingerprint; self.request = request
        }
    }

    fileprivate enum Effect {
        case native(OwnedNativeComputerUseClient.Command)
        case focusedAX(NativeFocusedAXInsertion, NativeFocusedAXInsertion.PreparedInsertion)
    }
    nonisolated enum Uncertainty: Sendable {
        case nativeFailure, readbackFailed, stoppedAfterDispatch
        case focusedTextFailure(NativeFocusedAXInsertion.Uncertainty)
    }
    enum Outcome {
        /// A scoped readback is evidence, not a claim that the requested semantic effect occurred.
        case readback(native: OwnedNativeComputerUseClient.NativeResult, observation: Observation, focus: NativeReviewedFocusOutcome = .notRequested)
        /// Exact local AX text/style/caret verification; no provider input receipt is invented.
        case textInserted(caret: NSRange, observation: Observation, focus: NativeReviewedFocusOutcome = .notRequested)
        case textUnchanged(observation: Observation, focus: NativeReviewedFocusOutcome = .notRequested)
        /// The mutation was attempted. Never replay it automatically or report it as successful.
        case uncertain(Uncertainty, observation: Observation?, focus: NativeReviewedFocusOutcome = .notRequested)
        /// Gesture/text was not attempted. Retains the actual focus-phase fact;
        /// `.alreadyFocused` and `.refused` do not themselves claim a focus effect.
        case focusOnly(NativeReviewedFocusOutcome, reason: String)
    }

    struct Backend {
        let dispatch: @MainActor (String, String, OwnedNativeComputerUseClient.Command, NativeInputRevocation,
                                  @escaping @MainActor @Sendable (OwnedNativeComputerUseClient.ReservedState) async throws -> OwnedNativeComputerUseClient.InputAdmission) async throws -> OwnedNativeComputerUseClient.NativeResult
        let stop: @MainActor () -> Void
        let drain: @MainActor () async -> Void
        var reserveAX: (@MainActor (String, String, Data, NativeInputRevocation,
             @escaping @MainActor @Sendable (OwnedNativeComputerUseClient.ReservedState) async throws -> OwnedNativeComputerUseClient.AXInsertionOperation)
             async throws -> NativeFocusedAXInsertion.Outcome)? = nil
    }

    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private let owner = UUID()
    private let inputRevocation = NativeInputRevocation()
    private var revision = UUID()
    private var stopped = false
    private var sessionActive = true
    private var busy = false
    private var waiters: [Waiter] = []
    /// Full app-owned accepted proposal keys are never evicted into replay eligibility.
    /// There is no raw-provider-ID-only application lifetime cap.
    private var consumedRequests: [Data: Data] = [:]
    private final class WeakInsertion { weak var value: NativeFocusedAXInsertion?; init(_ value: NativeFocusedAXInsertion) { self.value = value } }
    private var focusedInsertions: [WeakInsertion] = []
    private var latestInputPreview: InputPreview?
    private let backend: Backend
    private let observer: TargetBoundNativeObservation?
    private let exactUnsentClient: OwnedNativeComputerUseClient?
    private let readAudit: NativeReadAudit?
    private let sessionIsActive: @MainActor () -> Bool
    private let authorizer: any NativeControlAuthorizing
    private let clockNow: @MainActor () -> ContinuousClock.Instant

    convenience init(client: OwnedNativeComputerUseClient, sessionIsActive: @escaping @MainActor () -> Bool,
         authorizer: any NativeControlAuthorizing = DenyNativeControlMutations(),
         clockNow: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         readAudit: NativeReadAudit? = nil) {
        let observer = TargetBoundNativeObservation(client: client, sessionIsActive: sessionIsActive)
        self.init(client: client, observer: observer, sessionIsActive: sessionIsActive,
            authorizer: authorizer, clockNow: clockNow, readAudit: readAudit)
    }

    /// The dedicated path owns its liveness callback. An arbitrary caller
    /// callback cannot be paired with a typed metadata source.
    convenience init(client: OwnedNativeComputerUseClient, directExactUnsentAuthority authority: NativeLocalTaskInputAuthority,
                     readAudit: NativeReadAudit?) {
        let observer = TargetBoundNativeObservation(client: client, directExactUnsentAuthority: authority)
        self.init(client: client, observer: observer, sessionIsActive: authority.exactUnsentSessionLiveness(),
            authorizer: DenyNativeControlMutations(), clockNow: { .now }, readAudit: readAudit)
    }

    private init(client: OwnedNativeComputerUseClient, observer: TargetBoundNativeObservation,
                 sessionIsActive: @escaping @MainActor () -> Bool, authorizer: any NativeControlAuthorizing,
                 clockNow: @escaping @MainActor () -> ContinuousClock.Instant, readAudit: NativeReadAudit?) {
        self.readAudit = readAudit
        exactUnsentClient = client
        self.observer = observer; self.sessionIsActive = sessionIsActive; self.authorizer = authorizer; self.clockNow = clockNow
        backend = Backend(dispatch: { requestID, app, command, gate, preflight in
            try await client.mutate(requestID: requestID, app: app, command: command, revocation: gate, preflight: preflight)
        }, stop: { observer.stop() }, drain: { await observer.drain() }, reserveAX: { requestID, app, fingerprint, gate, preparation in
            try await client.reserveAXInsertion(requestID: requestID, app: app, fingerprint: fingerprint, revocation: gate, prepare: preparation)
        })
    }

    /// Pure transport/metadata seams. Production uses the initializer above and exact AX binder.
    init(backend: Backend, sessionIsActive: @escaping @MainActor () -> Bool,
         authorizer: any NativeControlAuthorizing = DenyNativeControlMutations(),
         clockNow: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.backend = backend; self.sessionIsActive = sessionIsActive; self.authorizer = authorizer; observer = nil; self.clockNow = clockNow; readAudit = nil
        exactUnsentClient = nil
    }

    func prepareExactUnsent(purpose: NativeExactUnsentPurpose,
                            authority: NativeLocalTaskInputAuthority) async throws -> ExactUnsentPreparation {
        try await acquire(); defer { release() }
        try requireActive(); try authority.validate(); try purpose.validateCurrent(scope: authority.scope)
        guard exactUnsentClient != nil, let observer else { throw Failure.unqualifiedEffect }
        let request = try observer.prepareInitialExactUnsent(purpose, readAudit: readAudit)
        let lease = try observer.retainPreparedTarget(request)
        let window = try observer.originalAXWindow(lease)
        guard let app = NSRunningApplication(processIdentifier: lease.application.processID),
              DesktopApplicationTarget.matches(lease.application, application: app) else { throw Failure.wrongOwner }
        let root = AXUIElementCreateApplication(lease.application.processID)
        try observer.validateOriginalSource(lease)
        let editor = try Self.exactElement(root, kAXFocusedUIElementAttribute)
        try purpose.objective.anchor.validateTechnicalIdentity()
        guard CFEqual(editor, try Self.exactElement(root, kAXFocusedUIElementAttribute)) else { throw Failure.changedFocus }
        let metadataBinding = try observer.metadataBinding(lease)
        let target = metadataBinding.canonicalExactUnsentPolicyTarget(readAudit: readAudit)
            ?? NativeOriginalPolicyTarget(sourceID: lease.sourceID, application: lease.application,
                originalWindow: window, validateOriginalSource: { try observer.validateOriginalSource(lease) },
                readAudit: readAudit, metadataBinding: metadataBinding)
        let source = ExactUnsentPreparation(controller: self, observer: observer, lease: lease,
            scope: authority.scope, purpose: purpose, authority: authority, application: app,
            root: root, window: window, editor: editor, policyTarget: target)
        source.focus = NativeOriginalWindowFocus(sourceID: source.sourceID, application: app,
            identity: source.application, originalWindow: window,
            validateOriginalSource: { [weak self, weak source] in
                guard let self, let source else { throw Failure.stopped }
                try self.validateExactUnsent(source, requireInput: false)
            }, validateForInput: { [weak self, weak source] in
                guard let self, let source else { throw Failure.stopped }
                try self.validateExactUnsent(source, requireInput: true)
            }, sessionIsActive: { [weak self] in self?.isActive == true })
        try validateExactUnsent(source, requireInput: false); try admitExactUnsentPrivacy(source)
        return source
    }

    func restoreExactUnsentFocus(_ source: ExactUnsentPreparation,
                                 identity: NativeExactUnsentOperation.Identity,
                                 dispatch: NativeExactUnsentOperation.DispatchSeal) async throws -> ExactUnsentEffect {
        try await acquire(); defer { release() }
        try validateExactUnsent(source, requireInput: false)
        try validateExactIdentity(identity, source: source, phase: .focus)
        try dispatch.validate(source: source, identity: identity)
        guard !source.focusStarted, let client = exactUnsentClient else { throw Failure.consumed }
        source.focusStarted = true
        let execution = ExactUnsentFocusExecution(source: source, seal: dispatch, identity: identity, gate: inputRevocation)
        return try await client.reserveExactUnsentFocus(execution)
    }

    func prepareExactUnsentInsertion(_ source: ExactUnsentPreparation, focus: ExactUnsentEffect,
                                     saved: AssistantConversationHistory.NativeTextEffectSettlement) async throws {
        try await acquire(); defer { release() }
        try saved.validate(effect: focus)
        guard source.focusEffect === focus, case .focus(let report) = focus.outcome, report.verified,
              !source.insertionStarted, source.writer == nil else { throw Failure.unqualifiedEffect }
        try validateExactUnsent(source, requireInput: true); try admitExactUnsentPrivacy(source)
        let writer = try NativeFocusedAXInsertion.captureForReview(application: source.application,
            originalWindow: source.window, validateOriginalSource: { [weak self, weak source] in
                guard let self, let source else { throw Failure.stopped }
                try self.validateExactUnsent(source, requireInput: false)
            }, validateForInput: { [weak self, weak source] in
                guard let self, let source else { throw Failure.stopped }
                try self.validateExactUnsent(source, requireInput: true)
            }, sessionIsActive: { [weak self] in self?.isActive == true }, admissionGate: inputRevocation,
            policyTarget: source.policyTarget, authorizePrivateQuery: { [weak self, weak source] in
                guard let self, let source else { throw Failure.stopped }
                try self.revalidateExactUnsentPrivacy(source)
            })
        do {
            guard let selected = writer.focusedTargetDescriptor?.selection,
                  selected.location == 0, selected.length == 0, selected.originalUTF16Count == 0 else {
                throw NativeExactUnsentOperation.Failure.nonemptyEditor
            }
            let insertion = try writer.prepare(source.purpose.objective.literal)
            guard insertion.selection == NSRange(location: 0, length: 0),
                  insertion.expectedUTF16Count == source.purpose.objective.literal.utf16.count,
                  insertion.expectedCaret == NSRange(location: source.purpose.objective.literal.utf16.count, length: 0) else {
                throw NativeExactUnsentOperation.Failure.nonemptyEditor
            }
            try saved.validate(effect: focus); try validateExactUnsent(source, requireInput: true)
            source.writer = writer; source.insertion = insertion
            focusedInsertions.append(WeakInsertion(writer))
        } catch { writer.stop(); throw error }
    }

    func executeExactUnsentInsertion(_ source: ExactUnsentPreparation,
                                     identity: NativeExactUnsentOperation.Identity,
                                     dispatch: NativeExactUnsentOperation.DispatchSeal) async throws -> ExactUnsentEffect {
        try await acquire(); defer { release() }
        try validateExactUnsent(source, requireInput: true)
        try validateExactIdentity(identity, source: source, phase: .insertion)
        try dispatch.validate(source: source, identity: identity)
        guard !source.insertionStarted, source.writer != nil, source.insertion != nil,
              let client = exactUnsentClient else { throw Failure.consumed }
        source.insertionStarted = true
        let execution = ExactUnsentInsertionExecution(source: source, seal: dispatch, identity: identity, gate: inputRevocation)
        return try await client.reserveExactUnsentInsertion(execution)
    }

    func verifyExactUnsent(_ source: ExactUnsentPreparation, focus: ExactUnsentEffect, insertion: ExactUnsentEffect,
                           focusSaved: AssistantConversationHistory.NativeTextEffectSettlement,
                           insertionSaved: AssistantConversationHistory.NativeTextEffectSettlement,
                           publication: NativeExactUnsentOperation.CompletionTransport) async throws -> ExactUnsentVerification {
        try await acquire(); defer { release() }
        try focusSaved.validate(effect: focus); try insertionSaved.validate(effect: insertion)
        guard source.focusEffect === focus, source.insertionEffect === insertion,
              case .focus(let report) = focus.outcome, report.verified,
              case .insertion(.inserted) = insertion.outcome,
              let client = exactUnsentClient else { throw NativeExactUnsentOperation.Failure.incompleteEffects }
        try validateExactUnsent(source, requireInput: true)
        let read = ExactUnsentReadRequest(source: source, focus: focus, insertion: insertion,
            focusSaved: focusSaved, insertionSaved: insertionSaved, publication: publication, gate: inputRevocation)
        return try await client.reserveExactUnsentVerification(read)
    }

    private func validateExactIdentity(_ identity: NativeExactUnsentOperation.Identity,
                                       source: ExactUnsentPreparation, phase: ExactUnsentEffect.Phase) throws {
        let actual = try NativeExactUnsentOperation.Identity(scope: source.scope, purpose: source.purpose,
            sourceID: source.sourceID, phase: phase)
        guard identity == actual else { throw Failure.conflictingRequest }
    }
    private func validateExactUnsent(_ source: ExactUnsentPreparation, requireInput: Bool) throws {
        try requireActive()
        guard source.controller === self, source.owner == owner, source.revision == revision else { throw Failure.wrongOwner }
        try source.authority.validate(); try source.purpose.validateCurrentForPreparedSource(owner: source.observer)
        if source.focusEffect != nil {
            try source.policyTarget.validateSource()
            guard DesktopApplicationTarget.matches(source.application, application: source.applicationObject),
                  source.observer.matchesOriginalAXWindow(source.window, lease: source.lease),
                  CFEqual(source.editor, try Self.exactElement(source.root, kAXFocusedUIElementAttribute)) else { throw Failure.changedFocus }
            if requireInput { try source.observer.validateAlreadyVerifiedOriginalForInput(source.lease) }
            try source.authority.validate(); try requireActive()
            return
        }
        try source.observer.validateOriginalSource(source.lease); try source.policyTarget.validateSource()
        guard DesktopApplicationTarget.matches(source.application, application: source.applicationObject),
              CFEqual(source.window, try source.observer.originalAXWindow(source.lease)),
              CFEqual(source.editor, try Self.exactElement(source.root, kAXFocusedUIElementAttribute)) else { throw Failure.changedFocus }
        try source.purpose.objective.anchor.validateTechnicalIdentity()
        if requireInput { try source.observer.validateForInput(source.lease) }
        try source.authority.validate(); try requireActive()
    }
    private func admitExactUnsentPrivacy(_ source: ExactUnsentPreparation) throws {
        let initial = !source.initialPrivacyAdmissionBegan
        // Spend before ANY strong owner/source check. An error cannot renew
        // the initial opportunity on this same actual preparation.
        source.initialPrivacyAdmissionBegan = true
        try validateExactUnsent(source, requireInput: false)
        let facts: NativeOrdinaryWindowPolicySource.Facts
        if initial {
            facts = try source.policyTarget.inspectInitialMetadata(using: source.initialMetadata,
                validateInitialOwnership: { [weak self, weak source] in
                    guard let self, let source else { throw Failure.stopped }
                    try self.validateExactUnsent(source, requireInput: false)
                }, authorizeMetadata: {
                    try source.authority.authorizeMetadataScope(source.application)
                }, metadataScope: source.authority.metadataScopeBinding(for: source.application))
        } else if source.focusEffect != nil, let admittedFacts = source.admittedFacts {
            try admittedFacts.admitPrivateEditorPlanning()
            try validateExactUnsent(source, requireInput: false)
            return
        } else {
            facts = try source.authority.inspect(source.policyTarget)
        }
        try facts.admitPrivateEditorPlanning()
        try validateExactUnsent(source, requireInput: false)
        if source.focusEffect != nil {
            source.admittedFacts = facts
        }
    }
    private func revalidateExactUnsentPrivacy(_ source: ExactUnsentPreparation) throws {
        guard source.initialPrivacyAdmissionBegan, let facts = source.admittedFacts else {
            try admitExactUnsentPrivacy(source)
            return
        }
        try validateExactUnsent(source, requireInput: false)
        try source.authority.authorizeMetadataScope(source.application)
        guard facts.sourceID == source.sourceID, facts.application == source.application,
              facts.coverage == .standardRoleSurvey, facts.context == .ordinary,
              facts.standardSurvey != nil else {
            throw NativeOrdinaryWindowPolicySource.Failure.incomplete
        }
        try validateExactUnsent(source, requireInput: false)
    }
    private static func exactElement(_ node: AXUIElement, _ name: String) throws -> AXUIElement {
        AXUIElementSetMessagingTimeout(node, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw Failure.unavailableFocus }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Actual independent reads only: no access to writer.State, verifiedCaret,
    /// old Contents, native state, images, input closure or provider response.
    private func readExactUnsent(_ source: ExactUnsentPreparation,
                                 notAfter: ContinuousClock.Instant) throws -> NativeExactUnsentOperation.ReadbackSample {
        func check() throws {
            try Task.checkCancellation()
            guard clockNow() < notAfter else { throw NativeExactUnsentOperation.Failure.expired }
            try validateExactUnsent(source, requireInput: true); try revalidateExactUnsentPrivacy(source)
            guard clockNow() < notAfter else { throw NativeExactUnsentOperation.Failure.expired }
        }
        func attribute(_ name: String, stage: NativeReadAudit.Stage) throws -> CFTypeRef {
            try check(); AXUIElementSetMessagingTimeout(source.editor, 0.05)
            var value: CFTypeRef?
            let status = NativeReadAudit.measure(readAudit, stage) {
                AXUIElementCopyAttributeValue(source.editor, name as CFString, &value)
            }
            try check()
            guard status == .success, let value else { throw NativeExactUnsentOperation.Failure.unavailableReadback }
            return value
        }
        try check()
        let survey = try source.policyTarget.standardSurvey(authorizeMetadata: {
            try self.validateExactUnsent(source, requireInput: false)
        })
        let metadata = try survey.editor(source.editor)
        if metadata.usesCanonicalDirectBoundary {
            try metadata.validateEditorMetadataOnly(role: metadata.role, subrole: metadata.subrole,
                protected: metadata.protected, hidden: metadata.hidden, enabled: metadata.enabled)
        } else {
            try metadata.validate(role: metadata.role, subrole: metadata.subrole,
                protected: metadata.protected, hidden: metadata.hidden, enabled: metadata.enabled)
        }
        try NativeFocusedAXInsertion.validateSourceHierarchy(editor: source.editor, window: source.window,
            pid: source.application.processID, authorizePrivateQuery: check, readAudit: readAudit)
        guard let value = try attribute(kAXValueAttribute, stage: .editorValue) as? String,
              value.utf8.count <= NativeFocusedAXInsertion.maximumFieldBytes else { throw Failure.unavailableFocus }
        let rawRange = try attribute(kAXSelectedTextRangeAttribute, stage: .editorSelection)
        guard CFGetTypeID(rawRange) == AXValueGetTypeID() else { throw Failure.unavailableFocus }
        var range = CFRange()
        let actualRange = unsafeDowncast(rawRange, to: AXValue.self)
        guard AXValueGetType(actualRange) == .cfRange, AXValueGetValue(actualRange, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { throw Failure.unavailableFocus }
        guard let selected = try attribute(kAXSelectedTextAttribute, stage: .editorSelectedText) as? String,
              selected.utf8.count <= NativeFocusedAXInsertion.maximumFieldBytes else { throw Failure.unavailableFocus }
        try check()
        var full = CFRange(location: 0, length: value.utf16.count)
        guard let parameter = AXValueCreate(.cfRange, &full) else { throw Failure.unavailableFocus }
        var rawAttributed: CFTypeRef?
        let status = NativeReadAudit.measure(readAudit, .editorStyle) {
            AXUIElementCopyParameterizedAttributeValue(source.editor, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                parameter, &rawAttributed)
        }
        try check()
        guard status == .success, let attributed = rawAttributed as? NSAttributedString else { throw Failure.unavailableFocus }
        return .init(value: value, selectedText: selected,
            caret: NSRange(location: range.location, length: range.length), attributed: attributed)
    }

    func observeForRead(application: NSRunningApplication,
                        authorizeSourceBeforeCapture: (@MainActor (NativeOriginalPolicyTarget) throws -> Void)? = nil) async throws -> Observation {
        try await acquire(); defer { release() }
        return try await withTaskCancellationHandler {
            try requireActive()
            guard let observer else { throw Failure.invalidAction }
            retireInputPreview()
            let expected = revision
            let request = try observer.prepare(application: application)
            let lease = try observer.retainPreparedTarget(request)
            let beforeCapture = try observer.originalAXWindow(lease)
            let metadataBinding = try observer.metadataBinding(lease)
            let admissionTarget = NativeOriginalPolicyTarget(sourceID: lease.sourceID,
                application: lease.application, originalWindow: beforeCapture,
                validateOriginalSource: { try observer.validateOriginalSource(lease) }, readAudit: readAudit,
                metadataBinding: metadataBinding)
            try authorizeSourceBeforeCapture?(admissionTarget)
            try requireRevision(expected)
            let snapshot: TargetBoundNativeObservation.Snapshot
            do { snapshot = try await observer.observe(request) }
            catch {
                // Initial production capture precedes Target construction but
                // must fence late error text by the same admitted source.
                if let authorizeSourceBeforeCapture {
                    try requireRevision(expected)
                    try authorizeSourceBeforeCapture(admissionTarget)
                    try requireRevision(expected)
                }
                throw error
            }
            try requireRevision(expected)
            try authorizeSourceBeforeCapture?(admissionTarget)
            try requireRevision(expected)
            let active = sessionIsActive
            let originalWindow = try observer.originalAXWindow(lease)
            let validateSource: @MainActor () throws -> Void = { try observer.validateOriginalSource(lease) }
            let validateCapture: @MainActor () throws -> Void = { try observer.validateTarget(lease) }
            let validateInput: @MainActor () throws -> Void = { try observer.validateForInput(lease) }
            // A retained source may outlive this image generation. Escaping
            // target closures keep only these immutable identity values.
            let applicationIdentity = snapshot.application
            let windowInfo = snapshot.window
            let metadataTarget = NativeOriginalPolicyTarget(sourceID: lease.sourceID, application: applicationIdentity,
                originalWindow: originalWindow, validateOriginalSource: validateSource, readAudit: readAudit,
                metadataBinding: metadataBinding)
            var target = Target(sourceID: lease.sourceID, application: applicationIdentity, window: windowInfo,
                validateOriginalSource: validateSource, validateForInput: validateInput,
                capture: { reserved in
                    if let reserved { return try await observer.observeOriginal(lease, reserved: reserved) }
                    return try await observer.observeOriginal(lease)
                }, isCurrent: { observer.isCurrent($0) },
                captureFocusForReview: { authorization in
                    try authorization()
                    return try Self.captureFocusForReview(application: applicationIdentity, originalWindow: originalWindow,
                        validateSource: validateSource, validateCapture: validateCapture, validateInput: validateInput,
                        policyTarget: metadataTarget, authorizePrivateQuery: authorization)
                }, restoreReviewedOriginalFocus: { authorization, gate, deadline in
                    await observer.restoreReviewedOriginalFocus(lease, authorization: authorization, gate: gate, notAfter: deadline)
                }, captureInsertionForReview: { gate, authorization in
                    try authorization(); try validateCapture()
                    return try NativeFocusedAXInsertion.captureForReview(application: applicationIdentity,
                        originalWindow: originalWindow,
                        validateOriginalSource: validateSource, validateForInput: validateInput,
                        sessionIsActive: active, admissionGate: gate,
                        policyTarget: metadataTarget, authorizePrivateQuery: authorization)
                }, policyTarget: {
                    try validateSource()
                    return metadataTarget
                })
            target.controlCapturePrivacy = authorizeSourceBeforeCapture
            try target.validateOriginalSource()
            revision = UUID()
            return Observation(snapshot: snapshot, owner: owner, revision: revision, target: target)
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }

    func observeForRead(target: Target,
                        authorizeSourceBeforeCapture: (@MainActor (NativeOriginalPolicyTarget) throws -> Void)? = nil) async throws -> Observation {
        try await acquire(); defer { release() }
        return try await withTaskCancellationHandler {
            try requireActive(); try target.validateOriginalSource()
            retireInputPreview()
            let expected = revision
            var target = target
            if let authorizeSourceBeforeCapture { target.controlCapturePrivacy = authorizeSourceBeforeCapture }
            let snapshot = try await target.captureForRead(nil)
            try requireRevision(expected); try target.validateOriginalSource()
            guard target.isCurrent(snapshot), snapshot.application == target.application,
                  target.window.matchesExactly(snapshot.window) else { throw Failure.staleObservation }
            revision = UUID()
            return Observation(snapshot: snapshot, owner: owner, revision: revision, target: target)
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }


    /// Read-only refresh of the retained original process/window/document. A stale/foreign
    /// source is refused before capture; this never binds the currently selected replacement.
    func observeOriginal(from observation: Observation) async throws -> Observation {
        try await acquire(); defer { release() }
        return try await withTaskCancellationHandler {
            try validate(observation)
            retireInputPreview()
            let expected = revision, target = observation.target
            let snapshot = try await target.captureForRead(nil)
            try requireRevision(expected); try target.validateOriginalSource()
            guard target.isCurrent(snapshot), snapshot.application == target.application,
                  snapshot.window.matchesExactly(target.window) else { throw Failure.staleObservation }
            revision = UUID()
            return Observation(snapshot: snapshot, owner: owner, revision: revision, target: target)
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }

    func source(from observation: Observation) throws -> OriginalSource {
        try requireActive()
        guard observation.owner == owner else { throw Failure.wrongOwner }
        try observation.target.validateOriginalSource()
        return OriginalSource(owner: owner, target: observation.target)
    }

    private func validateRetainedSourceIdentity(_ source: OriginalSource) throws {
        try requireActive()
        guard source.owner == owner else { throw Failure.wrongOwner }
        try source.target.validateOriginalSource(); try requireActive()
    }
    func validateOriginalSource(_ source: OriginalSource) throws {
        try validateRetainedSourceIdentity(source)
        try source.target.validateControlReadPrivacy()
        try validateRetainedSourceIdentity(source)
    }
    /// Image-free source capability for control continuation/goal reads. A
    /// general read target cannot silently become a protected control capture.
    func controlReadSource(from observation: Observation) throws -> OriginalSource {
        let original = try source(from: observation)
        guard original.target.controlCapturePrivacy != nil else { throw Failure.unqualifiedEffect }
        try validateOriginalSource(original)
        return original
    }

    /// Actual retained AX-window metadata capability only. Image consumption
    /// does not create a replacement source, and this performs no capture,
    /// activation, focus or input. The reader separately gates task/privacy IO.
    func policyTarget(from source: OriginalSource) throws -> NativeOriginalPolicyTarget {
        try validateRetainedSourceIdentity(source)
        guard let bind = source.target.policyTarget else { throw Failure.unqualifiedEffect }
        let target = try bind()
        try validateRetainedSourceIdentity(source)
        guard target.sourceID == source.id, target.application == source.target.application else { throw Failure.wrongOwner }
        let scoped = target.addingSourceValidation { [weak self] in
            guard let self else { throw Failure.stopped }
            try self.validateRetainedSourceIdentity(source)
        } metadataLeaseValidation: { [weak self] in
            guard let self else { throw Failure.stopped }
            try self.requireActive()
            guard source.owner == self.owner else { throw Failure.wrongOwner }
        }
        try scoped.validateSource()
        try validateRetainedSourceIdentity(source)
        return scoped
    }

    func validateForInput(_ source: OriginalSource) throws {
        try validateOriginalSource(source)
        try source.target.validateForInput(); try requireActive()
    }

    func refreshOriginalForRead(_ source: OriginalSource) async throws -> Observation {
        try await acquire(); defer { release() }
        return try await withTaskCancellationHandler {
            try validateOriginalSource(source)
            retireInputPreview()
            let expected = revision, target = source.target
            let snapshot = try await target.captureForRead(nil)
            try requireRevision(expected); try validateOriginalSource(source)
            guard target.isCurrent(snapshot), snapshot.application == target.application,
                  snapshot.window.matchesExactly(target.window) else { throw Failure.staleObservation }
            revision = UUID()
            return Observation(snapshot: snapshot, owner: owner, revision: revision, target: target)
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }

    func observeForInputPlanning(application: NSRunningApplication,
                                 authorizeInputPlanning: @escaping @MainActor () throws -> Void) async throws -> Observation {
        try authorizeInputPlanning()
        let first = try await observeForRead(application: application)
        return try await refreshOriginalForInputPlanning(source(from: first), authorizeInputPlanning: authorizeInputPlanning)
    }

    func refreshOriginalForInputPlanning(_ source: OriginalSource, includesTextInsertion: Bool = true,
                                        authorizeInputPlanning: @escaping @MainActor () throws -> Void) async throws -> Observation {
        try await acquire(); defer { release() }
        return try await withTaskCancellationHandler {
            try validateOriginalSource(source); try authorizeInputPlanning()
            retireInputPreview()
            let expected = revision, target = source.target
            let authorize: @MainActor () throws -> Void = { [weak self] in
                guard let self else { throw Failure.stopped }
                try self.requireActive(); try target.validateControlReadPrivacy()
                try authorizeInputPlanning(); try target.validateOriginalSource()
            }
            var focus: FocusFence?, insertion: NativeFocusedAXInsertion?
            do { focus = try target.captureFocusForReview(authorize) }
            catch {
                try authorize()
                guard let failure = error as? Failure,
                      failure == .unavailableFocus else { throw error }
            }
            if includesTextInsertion, let capture = target.captureInsertionForReview {
                do {
                    insertion = try capture(inputRevocation, authorize)
                    if let insertion {
                        guard insertion.usesAdmissionGate(inputRevocation) else { throw Failure.unqualifiedEffect }
                        track(insertion)
                    }
                } catch {
                    insertion?.stop(); insertion = nil
                    try authorize()
                    if let failure = error as? NativeFocusedAXInsertion.Failure,
                       failure == .unavailableEditor { }
                    else if let failure = error as? Failure, failure == .unavailableFocus { }
                    else { throw error }
                }
            }
            let preview = InputPreview(focus: focus, insertion: insertion, validateAuthorization: authorize)
            var published = false
            defer { if !published { preview.stop() } }
            // The exact source editor/value/selection/style must bracket the model's
            // native frame, not be adopted from whichever field exists after inference.
            // Navigation capture has already established its editor snapshot.
            // Insertion capture can add another editor read before this image.
            if includesTextInsertion { try preview.validate() }
            let snapshot = try await target.captureForRead(nil)
            try requireRevision(expected); try preview.validate()
            guard target.isCurrent(snapshot), snapshot.application == target.application,
                  snapshot.window.matchesExactly(target.window) else { throw Failure.staleObservation }
            revision = UUID(); latestInputPreview = preview; published = true
            return Observation(snapshot: snapshot, owner: owner, revision: revision, target: target, inputPreview: preview)
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }

    func isCurrent(_ observation: Observation) -> Bool {
        do { try validate(observation); return true } catch { return false }
    }

    /// The exact pre-inference editor capability brackets every actual model send
    /// and reply, including failures. Ordinary read/pointer observations have no
    /// private preview and this performs no full-field value/style reads for them.
    func validatePlanningObservation(_ observation: Observation) throws {
        try validate(observation)
        if let preview = observation.inputPreview {
            // The preview brackets its private reads with the same capture
            // privacy gate and additionally revalidates the editor grant.
            try preview.validate()
        } else {
            try observation.target.validateControlReadPrivacy()
        }
        try validate(observation)
    }

    func isCurrentForPlanning(_ observation: Observation) -> Bool {
        do { try validatePlanningObservation(observation); return true } catch { return false }
    }

    /// Transport checks protect the already-captured image and window. The
    /// planning phase validates the exact editor state before and after the
    /// model call, and the controller checks it again before input.
    func isCurrentForModelInput(_ observation: Observation) -> Bool {
        do {
            try validate(observation)
            if let preview = observation.inputPreview {
                guard !preview.retired else { return false }
                try preview.validateAuthorization()
            } else {
                try observation.target.validateControlReadPrivacy()
            }
            try validate(observation)
            return true
        } catch { return false }
    }

    func prepareForReview(_ action: Action, request: NativeControlRequestAdmission,
                          from observation: Observation, frame: NativeVisionFrame? = nil) async throws -> ReviewedProposal {
        try validate(observation)
        try request.validate()
        if let frame {
            try await PixelProof.validateFrame(snapshot: observation.snapshot, frame: frame)
            try validate(observation)
        }
        let requestID = request.requestID
        let normalized: PixelProof.Pixels?, effect: Effect, focus: FocusFence?
        var textBinding: NativeFocusedAXInsertion?, textInsertion: NativeFocusedAXInsertion.PreparedInsertion?
        var preparedSuccessfully = false
        defer {
            if !preparedSuccessfully, let textBinding {
                textBinding.stop(); forget(textBinding); observation.inputPreview?.stop()
            }
        }
        switch action {
        case .click(let imageID, let point):
            guard let frame, frame.id == imageID, frame.observationID == observation.snapshot.id else { throw Failure.invalidAction }
            normalized = try await PixelProof.normalize(snapshot: observation.snapshot, frame: frame)
            effect = .native(.click(try frame.nativePoint(fromPrepared: point))); focus = nil
        case .drag(let imageID, let from, let to):
            guard let frame, frame.id == imageID, frame.observationID == observation.snapshot.id else { throw Failure.invalidAction }
            normalized = try await PixelProof.normalize(snapshot: observation.snapshot, frame: frame)
            effect = .native(.drag(from: try frame.nativePoint(fromPrepared: from), to: try frame.nativePoint(fromPrepared: to))); focus = nil
        case .key(let key):
            guard let preview = observation.inputPreview, let originalFocus = preview.focus else { throw Failure.unavailableFocus }
            try preview.validate()
            focus = originalFocus
            effect = .native(.key(key)); normalized = nil
        case .typeUnsentText(let text):
            guard Self.validUnsentText(text) else { throw Failure.invalidAction }
            guard backend.reserveAX != nil, let preview = observation.inputPreview,
                  let binding = preview.insertion else { throw Failure.unavailableFocus }
            try preview.validate()
            textBinding = binding; track(binding)
            guard binding.usesAdmissionGate(inputRevocation) else { throw Failure.unqualifiedEffect }
            let insertion = try binding.prepare(text)
            textInsertion = insertion
            effect = .focusedAX(binding, insertion); focus = nil; normalized = nil
        }
        let key = Data(SHA256.hash(data: Data(requestID.utf8)))
        let fingerprint = try Self.fingerprint(effect, target: observation.target, frame: frame)
        try requireUnused(key, fingerprint: fingerprint)
        let descriptor = focus?.descriptor ?? textBinding?.focusedTargetDescriptor
        let context = PolicyContext(id: UUID(), requestID: requestID,
            originalProviderCallID: request.originalProviderCallID, exactCallDigest: request.exactCallDigest,
            sourceID: observation.target.sourceID, focusedTarget: descriptor,
            action: action, application: observation.snapshot.application,
            window: observation.snapshot.window, observationID: observation.snapshot.id, frame: frame,
            focus: focus, textInsertion: textInsertion, validateTarget: observation.target.validateOriginalSource)
        try validate(observation)
        let permit = try await authorizer.authorize(context)
        try request.validate()
        if action.requiresEditorPreview { try observation.inputPreview?.validate() }
        if textInsertion != nil {
            guard let source = permit.validateTaskSource else { throw Failure.unqualifiedEffect }
            try validateTaskSource(source)
        } else if let source = permit.validateTaskSource { try validateTaskSource(source) }
        try validate(observation); try permit.revalidate()
        // Only the trusted authorizer selects image-bound context after semantic/review
        // admission. Model geometry or an otherwise valid rectangle grants no authority.
        let rectangles = try permit.visualProof.nativeRectangles(action: action, frame: frame)
        let pixels: PixelProof?
        if let normalized {
            pixels = try await PixelProof.make(pixels: normalized, rectangles: rectangles)
            try validate(observation); try permit.revalidate()
        } else {
            pixels = nil
        }
        if let source = permit.validateTaskSource { try validateTaskSource(source) }
        try requireUnused(key, fingerprint: fingerprint)
        preparedSuccessfully = true
        return ReviewedProposal(context: context, owner: owner, revision: revision, source: observation,
                              effect: effect, pixels: pixels, permit: permit, requestKey: key, fingerprint: fingerprint, request: request)
    }

    private final class FocusExecutionBox { var outcome: NativeReviewedFocusOutcome = .notRequested }

    private func restoreForExecution(_ prepared: ReviewedProposal, target: Target, revision expected: UUID,
                                     reserved: OwnedNativeComputerUseClient.ReservedState,
                                     focus: FocusExecutionBox) async throws {
        try requireRevision(expected); try prepared.request.validate(); try target.validateOriginalSource()
        if let source = prepared.permit.validateTaskSource { try validateTaskSource(source) }
        try prepared.permit.revalidate()
        guard clockNow() < reserved.notAfter else { throw Failure.staleObservation }
        if let authorization = prepared.permit.reviewedOriginalFocus {
            guard authorization.policyContextID == prepared.context.id,
                  authorization.requestID.utf8.elementsEqual(prepared.request.requestID.utf8),
                  authorization.sourceID == prepared.context.sourceID,
                  target.sourceID == prepared.context.sourceID else { throw Failure.unqualifiedEffect }
            focus.outcome = await target.restoreReviewedOriginalFocus(authorization, inputRevocation, reserved.notAfter)
            switch focus.outcome {
            case .alreadyFocused, .restored: break
            case .notRequested, .refused, .uncertain: throw Failure.changedFocus
            }
        } else {
            // Already-foreground ordinary input needs no focus effect or extra approval.
            // Background input without a scoped capability stays refused.
            try target.validateForInput()
            focus.outcome = .alreadyFocused
        }
        try requireRevision(expected); try prepared.request.validate(); try target.validateForInput()
        if let source = prepared.permit.validateTaskSource { try validateTaskSource(source) }
        try prepared.context.focus?.validateBeforeInput()
        if case .focusedAX(let binding, _) = prepared.effect { try binding.validateSourcePreview() }
        try prepared.permit.revalidate()
        guard clockNow() < reserved.notAfter else { throw Failure.staleObservation }
    }

    private func focusRefusal(_ error: any Error, _ focus: FocusExecutionBox) -> Outcome? {
        if case .notRequested = focus.outcome { return nil }
        let reason: String
        if let typed = error as? Failure { reason = String(describing: typed) }
        else if let typed = error as? NativeFocusedAXInsertion.Failure { reason = String(describing: typed) }
        else { reason = NativeVisualStepOutcome.bounded(error.localizedDescription) }
        return .focusOnly(focus.outcome, reason: reason)
    }

    /// Call only from the inserted lexical journal effect callback. The request's
    /// shared accepted-proposal admission is consumed once before any focus/input.
    func execute(_ prepared: ReviewedProposal) async throws -> Outcome {
        try await acquire(); defer { release() }
        try requireActive()
        guard prepared.owner == owner else { throw Failure.wrongOwner }
        guard !prepared.consumed else { throw Failure.consumed }
        defer { if case .focusedAX(let binding, _) = prepared.effect { binding.stop(); forget(binding) } }
        try prepared.request.validate()
        try requireUnused(prepared.requestKey, fingerprint: prepared.fingerprint)
        try validate(prepared.source)
        guard prepared.revision == revision else { throw Failure.staleObservation }
        let target = prepared.source.target
        if let source = prepared.permit.validateTaskSource { try validateTaskSource(source) }
        try prepared.permit.revalidate(); try prepared.context.focus?.validateSourceBeforeInput()
        try prepared.request.admitOneAttempt()
        prepared.consumed = true; consumedRequests[prepared.requestKey] = prepared.fingerprint; revision = UUID()
        let dispatchRevision = revision
        if case .focusedAX(let binding, let insertion) = prepared.effect {
            return try await executeFocusedAX(prepared, binding: binding, insertion: insertion,
                                              target: target, revision: dispatchRevision)
        }
        guard case .native(let command) = prepared.effect else { throw Failure.invalidAction }
        let focus = FocusExecutionBox()
        let native: OwnedNativeComputerUseClient.NativeResult
        do {
            native = try await withTaskCancellationHandler {
                try await backend.dispatch(prepared.request.requestID, target.application.bundleURL.path, command, inputRevocation, { [weak self] reserved in
                    guard let self else { throw Failure.stopped }
                    try await self.restoreForExecution(prepared, target: target, revision: dispatchRevision, reserved: reserved, focus: focus)
                    // The original reservation still caps the fresh-image window; focus
                    // restoration cannot renew the already-owned transport deadline.
                    let fresh = try await target.captureForRead(reserved)
                    let captured = self.clockNow()
                    if let source = prepared.permit.validateTaskSource { try self.validateTaskSource(source) }
                    try self.requireRevision(dispatchRevision); try prepared.request.validate(); try target.validateForInput()
                    guard target.isCurrent(fresh), fresh.application == prepared.context.application,
                          fresh.window.matchesExactly(prepared.context.window) else { throw Failure.staleObservation }
                    if let pixels = prepared.pixels, !(try await pixels.matches(fresh)) { throw Failure.changedPixels }
                    try self.requireRevision(dispatchRevision); try target.validateForInput()
                    try prepared.permit.consume()
                    if let source = prepared.permit.validateTaskSource { try self.validateTaskSource(source) }
                    try self.requireRevision(dispatchRevision); try prepared.request.validate(); try target.validateForInput()
                    try prepared.context.focus?.validateBeforeInput()
                    // Pointer input is bound to the fresh pixel proof. Navigation
                    // instead uses the just-validated original focused editor.
                    let proofTime = prepared.pixels == nil ? self.clockNow() : captured
                    let notAfter = min(reserved.notAfter, proofTime.advanced(by: .seconds(2)))
                    guard target.isCurrent(fresh), self.clockNow() < notAfter else { throw Failure.staleObservation }
                    return .init(notAfter: notAfter, revocation: self.inputRevocation)
                })
            } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
        } catch OwnedNativeComputerUseClient.MutationFailure.notDispatched(let error) {
            if let partial = focusRefusal(error, focus) { return partial }
            throw error
        } catch {
            guard isActive else { return .uncertain(.stoppedAfterDispatch, observation: nil, focus: focus.outcome) }
            return .uncertain(.nativeFailure, observation: await bestEffortReadback(target, revision: dispatchRevision,
                focus: prepared.context.focus, validateSource: prepared.permit.validateTaskSource), focus: focus.outcome)
        }
        guard isActive, revision == dispatchRevision else { return .uncertain(.stoppedAfterDispatch, observation: nil, focus: focus.outcome) }
        guard let readback = await bestEffortReadback(target, revision: dispatchRevision, focus: prepared.context.focus,
            validateSource: prepared.permit.validateTaskSource) else { return .uncertain(.readbackFailed, observation: nil, focus: focus.outcome) }
        if native.isError { return .uncertain(.nativeFailure, observation: readback, focus: focus.outcome) }
        return .readback(native: native, observation: readback, focus: focus.outcome)
    }

    private final class AXExecutionBox {
        var outcome: NativeFocusedAXInsertion.Outcome?
        var observation: Observation?
        let focus = FocusExecutionBox()
    }

    private func executeFocusedAX(_ prepared: ReviewedProposal, binding: NativeFocusedAXInsertion,
                                  insertion: NativeFocusedAXInsertion.PreparedInsertion, target: Target,
                                  revision expected: UUID) async throws -> Outcome {
        guard let reserve = backend.reserveAX, let source = prepared.permit.validateTaskSource else { throw Failure.unqualifiedEffect }
        let box = AXExecutionBox()
        let checkSource: @MainActor () throws -> Void = { [self] in
            try requireRevision(expected); try prepared.request.validate(); try validateTaskSource(source); try target.validateOriginalSource()
            try target.validateControlReadPrivacy()
            try requireRevision(expected); try prepared.request.validate(); try validateTaskSource(source); try target.validateOriginalSource()
        }
        try checkSource()
        let nativeID = prepared.request.requestID
        let result: NativeFocusedAXInsertion.Outcome
        do {
            result = try await withTaskCancellationHandler {
                try await reserve(nativeID, target.application.bundleURL.path, prepared.fingerprint, inputRevocation, { [weak self] reserved in
                    guard let self else { throw Failure.stopped }
                    try checkSource()
                    try await self.restoreForExecution(prepared, target: target, revision: expected, reserved: reserved, focus: box.focus)
                    let captured = self.clockNow(), notAfter = min(reserved.notAfter, captured.advanced(by: .seconds(2)))
                    let fresh = try await target.captureForRead(reserved)
                    try checkSource()
                    guard target.isCurrent(fresh), fresh.application == prepared.context.application,
                          fresh.window.matchesExactly(prepared.context.window), self.clockNow() < notAfter else { throw Failure.staleObservation }
                    try prepared.permit.revalidate()
                    return .init(execute: {
                        // The capability owns the one actual AX write and review consumption.
                        // The shared gate is rechecked at its final synchronous admission.
                        let outcome = binding.execute(insertion, authorization: .init(validateTaskSource: checkSource,
                            revalidate: { try checkSource(); try prepared.permit.revalidate() },
                            consume: { try checkSource(); try prepared.permit.consume() }), notAfter: notAfter)
                        box.outcome = outcome
                        return outcome
                    }, readback: { reserved, outcome in
                        if case .notDispatched = outcome { return }
                        guard let descriptor = prepared.context.focusedTarget else { return }
                        let focus = FocusFence(descriptor: descriptor, validateSourceBeforeInput: {},
                            validateBeforeInput: {}, validateAfterInput: { try binding.validateOriginalFocus() })
                        box.observation = await self.bestEffortReadback(target, revision: expected, focus: focus,
                            reserved: reserved, validateSource: source)
                    })
                })
            } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
        } catch {
            // An abnormal backend must not turn an already attempted AX write into
            // a definitive no-effect throw. The execute closure records its typed outcome.
            if !isActive { stop() }
            if let attempted = box.outcome { return try finishFocusedAX(attempted, insertion: insertion, observation: box.observation, revision: expected, focus: box.focus) }
            if case OwnedNativeComputerUseClient.MutationFailure.notDispatched(let cause) = error {
                if let partial = focusRefusal(cause, box.focus) { return partial }
                throw cause
            }
            if let partial = focusRefusal(error, box.focus) { return partial }
            throw error
        }
        return try finishFocusedAX(result, insertion: insertion, observation: box.observation, revision: expected, focus: box.focus)
    }

    private func finishFocusedAX(_ result: NativeFocusedAXInsertion.Outcome,
                                 insertion: NativeFocusedAXInsertion.PreparedInsertion,
                                 observation: Observation?, revision expected: UUID, focus: FocusExecutionBox) throws -> Outcome {
        if !isActive { stop() }
        switch result {
        case .notDispatched(let failure):
            if let partial = focusRefusal(failure, focus) { return partial }
            throw failure
        case .unchanged:
            do {
                try requireRevision(expected)
                guard let observation else { throw Failure.staleObservation }
                return .textUnchanged(observation: observation, focus: focus.outcome)
            } catch {
                // No text write occurred, but original-window restoration may
                // already be a real effect. Retain that fact on late refusal.
                if let partial = focusRefusal(error, focus) { return partial }
                throw error
            }
        case .inserted:
            guard isActive, revision == expected else { return .uncertain(.stoppedAfterDispatch, observation: nil, focus: focus.outcome) }
            guard let observation else { return .uncertain(.readbackFailed, observation: nil, focus: focus.outcome) }
            return .textInserted(caret: insertion.expectedCaret, observation: observation, focus: focus.outcome)
        case .uncertain(let reason):
            guard isActive, revision == expected else { return .uncertain(.stoppedAfterDispatch, observation: nil, focus: focus.outcome) }
            return .uncertain(.focusedTextFailure(reason), observation: observation, focus: focus.outcome)
        }
    }

    private func bestEffortReadback(_ target: Target, revision expected: UUID, focus: FocusFence?,
                                    reserved: OwnedNativeComputerUseClient.ReservedState? = nil,
                                    validateSource: (@MainActor () throws -> Void)? = nil) async -> Observation? {
        do {
            if let validateSource { try validateTaskSource(validateSource) }
            try requireRevision(expected); try target.validateOriginalSource()
            try focus?.validateAfterInput()
            let snapshot = try await target.captureForRead(reserved)
            if let validateSource { try validateTaskSource(validateSource) }
            try requireRevision(expected); try target.validateOriginalSource(); try focus?.validateAfterInput()
            guard target.isCurrent(snapshot), snapshot.application == target.application,
                  snapshot.window.matchesExactly(target.window) else { throw Failure.staleObservation }
            return Observation(snapshot: snapshot, owner: owner, revision: expected, target: target)
        } catch { return nil }
    }

    func stop() {
        guard !stopped else { return }
        inputRevocation.revoke()
        retireInputPreview()
        stopped = true; revision = UUID()
        for entry in focusedInsertions { entry.value?.stop() }
        focusedInsertions.removeAll()
        let queued = waiters; waiters.removeAll()
        for waiter in queued { waiter.continuation.resume(throwing: Failure.stopped) }
        backend.stop()
    }
    func drain() async { await backend.drain() }
    func setSessionActive(_ active: Bool) { sessionActive = active; if !active { stop() } }

    private var isActive: Bool { !stopped && sessionActive && sessionIsActive() && inputRevocation.isActive && !Task.isCancelled }
    private func requireActive() throws {
        try Task.checkCancellation()
        guard sessionActive, sessionIsActive() else { stop(); throw Failure.inactiveSession }
        guard !stopped else { throw Failure.stopped }
        guard inputRevocation.isActive else { stop(); throw Failure.stopped }
    }
    private func requireRevision(_ expected: UUID) throws {
        try requireActive(); guard expected == revision else { throw Failure.staleObservation }
    }
    private func requireUnused(_ key: Data, fingerprint: Data) throws {
        if let previous = consumedRequests[key] { throw previous == fingerprint ? Failure.consumed : Failure.conflictingRequest }
    }
    private func retireInputPreview() { latestInputPreview?.stop(); latestInputPreview = nil }
    private func track(_ binding: NativeFocusedAXInsertion) {
        focusedInsertions.removeAll { $0.value == nil }
        if !focusedInsertions.contains(where: { $0.value === binding }) { focusedInsertions.append(WeakInsertion(binding)) }
    }
    private func forget(_ binding: NativeFocusedAXInsertion) {
        focusedInsertions.removeAll { $0.value == nil || $0.value === binding }
    }
    private func validateTaskSource(_ check: @MainActor () throws -> Void) throws {
        do { try check() }
        catch { stop(); throw error }
    }
    private static func fingerprint(_ effect: Effect, target: Target,
                                    frame: NativeVisionFrame?) throws -> Data {
        let app = target.application, window = target.window
        let tool: String, arguments: [String: JSONValue]
        switch effect {
        case .native(let command): tool = command.tool; arguments = try command.arguments(app: app.bundleURL.path, allowUnicode: true)
        case .focusedAX(_, let insertion):
            guard let literal = insertion.literalText else { throw Failure.consumed }
            tool = "relay_focused_ax_insertion"
            arguments = ["app": .string(app.bundleURL.path), "text": .string(literal),
                "selection": .array([.number(Double(insertion.selection.location)), .number(Double(insertion.selection.length))]),
                "binding": .string(insertion.sourceBindingID.uuidString)]
        }
        let value = JSONValue.object(["tool": .string(tool), "arguments": .object(arguments),
            "pid": .number(Double(app.processID)), "launch": .number(app.launchedAt.timeIntervalSince1970), "bundle": .string(app.bundleID),
            "window": .array([window.title, window.role, window.identifier, window.document, window.url].map(JSONValue.string)),
            "geometry": .array([window.x, window.y, window.width, window.height].map(JSONValue.number)),
            "minimized": .bool(window.minimized), "hidden": window.hidden.map(JSONValue.bool) ?? .null,
            "modal": window.modal.map(JSONValue.bool) ?? .null,
            "image": frame.map { .string($0.originalSHA256) } ?? .null,
            "pixels": frame.map { .array([.number(Double($0.nativePixels.width)), .number(Double($0.nativePixels.height))]) } ?? .null])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(value)))
    }
    private func validate(_ observation: Observation) throws {
        try requireActive()
        guard observation.owner == owner else { throw Failure.wrongOwner }
        try requireRevision(observation.revision); try observation.target.validateOriginalSource()
        guard observation.target.isCurrent(observation.snapshot) else { throw Failure.staleObservation }
    }
    private func acquire() async throws {
        try requireActive()
        if !busy { busy = true; return }
        guard waiters.count < 64 else { throw Failure.busy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        guard !waiters.isEmpty else { busy = false; return }
        waiters.removeFirst().continuation.resume()
    }
    nonisolated static func validUnsentText(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 4_096 && !text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
        }
    }

    private static func requireForeground(_ identity: DesktopApplicationIdentity) throws {
        guard let app = NSWorkspace.shared.frontmostApplication,
              DesktopApplicationTarget.matches(identity, application: app), app.isActive else { throw Failure.changedFocus }
    }

    private static func captureFocusForReview(application: DesktopApplicationIdentity, originalWindow: AXUIElement,
                                              validateSource: @escaping @MainActor () throws -> Void,
                                              validateCapture: @escaping @MainActor () throws -> Void,
                                              validateInput: @escaping @MainActor () throws -> Void,
                                              policyTarget: NativeOriginalPolicyTarget,
                                              authorizePrivateQuery: @escaping @MainActor () throws -> Void) throws -> FocusFence {
        try validateSource(); try validateCapture(); try authorizePrivateQuery()
        let survey = try policyTarget.standardSurvey(authorizeMetadata: validateSource, ordinaryFocus: true)
        let root = AXUIElementCreateApplication(application.processID)
        AXUIElementSetMessagingTimeout(root, 0.04)
        func attribute(_ element: AXUIElement, _ name: String, stage: NativeReadAudit.Stage = .focusedIdentityMetadata) throws -> CFTypeRef {
            try Task.checkCancellation(); try validateSource()
            AXUIElementSetMessagingTimeout(element, 0.04)
            var value: CFTypeRef?
            let status = NativeReadAudit.measure(policyTarget.readAudit, stage) { AXUIElementCopyAttributeValue(element, name as CFString, &value) }
            guard status == .success, let value else { throw Failure.unavailableFocus }
            try Task.checkCancellation(); try validateSource()
            return value
        }
        func element(_ value: CFTypeRef) throws -> AXUIElement {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw Failure.unavailableFocus }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        let focus = try element(attribute(root, kAXFocusedUIElementAttribute))
        guard CFEqual(try element(attribute(root, kAXFocusedWindowAttribute)), originalWindow),
              CFEqual(try element(attribute(focus, kAXWindowAttribute)), originalWindow) else { throw Failure.changedFocus }
        let standard: NativeStandardControlSurvey.Editor
        do { standard = try survey.editor(focus) }
        catch NativeOrdinaryWindowPolicySource.Failure.incomplete { throw Failure.unavailableFocus }
        let sourceIdentity: @MainActor () throws -> Void = {
            try validateSource(); try validateCapture()
            guard CFEqual(try element(attribute(root, kAXFocusedUIElementAttribute)), focus),
                  CFEqual(try element(attribute(root, kAXFocusedWindowAttribute)), originalWindow),
                  CFEqual(try element(attribute(focus, kAXWindowAttribute)), originalWindow) else { throw Failure.changedFocus }
        }
        let privateCheck: @MainActor () throws -> Void = {
            try sourceIdentity(); try authorizePrivateQuery()
            try standard.validateEditorMetadataOnly(role: standard.role, subrole: standard.subrole, protected: standard.protected,
                hidden: standard.hidden, enabled: standard.enabled)
            try sourceIdentity()
        }
        func privateAttributes(_ names: [String], stage: NativeReadAudit.Stage) throws -> [AnyObject] {
            try sourceIdentity()
            try standard.validateEditorMetadataOnly(role: standard.role, subrole: standard.subrole,
                protected: standard.protected, hidden: standard.hidden, enabled: standard.enabled)
            var result: CFArray?
            let status = NativeReadAudit.measure(policyTarget.readAudit, stage) {
                AXUIElementCopyMultipleAttributeValues(focus, names as CFArray, [], &result)
            }
            try sourceIdentity()
            guard status == .success, let values = result as? [AnyObject], values.count == names.count else {
                throw Failure.unavailableFocus
            }
            return values
        }
        return try NativeControlFocus.capture(.init(validateIdentity: sourceIdentity,
            validateInputIdentity: { try sourceIdentity(); try validateInput(); try Self.requireForeground(application) },
            metadata: {
                var metadata = NativeControlFocus.Metadata(role: standard.role, subrole: standard.subrole,
                    protected: standard.protected, hidden: standard.hidden, enabled: standard.enabled,
                    valueWritable: standard.valueWritable, selectionWritable: standard.selectionWritable)
                metadata.standardEditor = standard
                return metadata
            }, qualifiedLabels: {
                try NativeFocusedAXInsertion.validateSourceHierarchy(editor: focus, window: originalWindow,
                    pid: application.processID, authorizePrivateQuery: sourceIdentity, readAudit: policyTarget.readAudit)
                let values = try privateAttributes([kAXDescriptionAttribute, kAXTitleAttribute,
                    kAXPlaceholderValueAttribute, kAXIdentifierAttribute], stage: .editorLabel)
                let label = values.prefix(3).compactMap { $0 as? String }.first { !$0.isEmpty }
                let identifier = (values[3] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .init(label: label, identifier: identifier)
            }, contents: {
                let values = try privateAttributes([kAXValueAttribute, kAXSelectedTextRangeAttribute], stage: .editorValue)
                let raw = values[1]
                guard let value = values[0] as? String,
                      CFGetTypeID(raw) == AXValueGetTypeID() else { throw Failure.unavailableFocus }
                let axValue = unsafeDowncast(raw, to: AXValue.self)
                var range = CFRange()
                guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { throw Failure.unavailableFocus }
                return .init(value: value, selection: NSRange(location: range.location, length: range.length))
            }, validatePrivacy: privateCheck))
    }

    /// Original and fresh images each normalize/decode once. The default hashes the whole
    /// frame; an explicitly admitted positive scope hashes exact rows in immutable regions.
    fileprivate nonisolated struct PixelProof: Sendable {
        let width: Int, height: Int
        let digest: Data
        let rectangles: [NativeVisualProofScope.NativeRectangle]?

        struct Pixels: Sendable {
            let width: Int, height: Int
            let rgba: Data
            fileprivate init(image: TargetBoundNativeObservation.Image) throws {
                guard image.width > 0, image.height > 0, image.width <= 8_192, image.height <= 8_192,
                      image.width <= 32_000_000 / image.height, image.data.count <= NativeVisionFrame.maximumOriginalBytes,
                      ["image/png", "image/jpeg"].contains(image.mimeType),
                      let source = CGImageSourceCreateWithData(image.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(source) == 1,
                      let sourceType = CGImageSourceGetType(source),
                      sourceType as String == (image.mimeType == "image/png" ? "public.png" : "public.jpeg"),
                      let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      ((info[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1,
                      let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      decoded.width == image.width, decoded.height == image.height,
                      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                      let bytes = context.data else { throw Failure.invalidImage }
                context.draw(decoded, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                width = image.width; height = image.height
                rgba = Data(bytes: bytes, count: image.width * image.height * 4)
            }
        }

        @concurrent static func validateFrame(snapshot: TargetBoundNativeObservation.Snapshot, frame: NativeVisionFrame) async throws {
            try Task.checkCancellation()
            guard snapshot.images.count == 1, let image = snapshot.images.first,
                  frame.observationID == snapshot.id, image.width == frame.nativePixels.width,
                  image.height == frame.nativePixels.height,
                  SHA256.hash(data: image.data).map({ String(format: "%02x", $0) }).joined() == frame.originalSHA256 else { throw Failure.invalidImage }
            try Task.checkCancellation()
        }
        @concurrent static func normalize(snapshot: TargetBoundNativeObservation.Snapshot, frame: NativeVisionFrame) async throws -> Pixels {
            try await validateFrame(snapshot: snapshot, frame: frame)
            guard let image = snapshot.images.first else { throw Failure.invalidImage }
            let pixels = try Pixels(image: image)
            try Task.checkCancellation()
            return pixels
        }
        @concurrent static func make(pixels: Pixels, rectangles: [NativeVisualProofScope.NativeRectangle]?) async throws -> Self {
            try Task.checkCancellation()
            let proof = Self(width: pixels.width, height: pixels.height,
                             digest: try hash(pixels, rectangles: rectangles), rectangles: rectangles)
            try Task.checkCancellation()
            return proof
        }
        private static func hash(_ pixels: Pixels, rectangles: [NativeVisualProofScope.NativeRectangle]?) throws -> Data {
            guard let rectangles else { return Data(SHA256.hash(data: pixels.rgba)) }
            var hasher = SHA256()
            for rectangle in rectangles {
                try Task.checkCancellation()
                guard rectangle.x >= 0, rectangle.y >= 0, rectangle.width > 0, rectangle.height > 0,
                      rectangle.x + rectangle.width <= pixels.width,
                      rectangle.y + rectangle.height <= pixels.height else { throw Failure.invalidImage }
                for y in rectangle.y..<(rectangle.y + rectangle.height) {
                    if y % 64 == 0 { try Task.checkCancellation() }
                    let start = (y * pixels.width + rectangle.x) * 4
                    hasher.update(data: pixels.rgba[start..<(start + rectangle.width * 4)])
                }
            }
            return Data(hasher.finalize())
        }
        @concurrent func matches(_ snapshot: TargetBoundNativeObservation.Snapshot) async throws -> Bool {
            try Task.checkCancellation()
            guard snapshot.images.count == 1, let image = snapshot.images.first,
                  image.width == width, image.height == height else { return false }
            let pixels = try Pixels(image: image)
            let result = try Self.hash(pixels, rectangles: rectangles)
            try Task.checkCancellation()
            return digest == result
        }
    }
}
