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
    private let sessionIsActive: @MainActor () -> Bool
    private let authorizer: any NativeControlAuthorizing
    private let clockNow: @MainActor () -> ContinuousClock.Instant

    init(client: OwnedNativeComputerUseClient, sessionIsActive: @escaping @MainActor () -> Bool,
         authorizer: any NativeControlAuthorizing = DenyNativeControlMutations(),
         clockNow: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        let observer = TargetBoundNativeObservation(client: client, sessionIsActive: sessionIsActive)
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
        self.backend = backend; self.sessionIsActive = sessionIsActive; self.authorizer = authorizer; observer = nil; self.clockNow = clockNow
    }

    func observeForRead(application: NSRunningApplication) async throws -> Observation {
        try await acquire(); defer { release() }
        return try await withTaskCancellationHandler {
            try requireActive()
            guard let observer else { throw Failure.invalidAction }
            retireInputPreview()
            let expected = revision
            let snapshot = try await observer.observe(observer.prepare(application: application))
            try requireRevision(expected)
            let lease = try observer.retainTarget(for: snapshot)
            let active = sessionIsActive
            let originalWindow = try observer.originalAXWindow(lease)
            let validateSource: @MainActor () throws -> Void = { try observer.validateOriginalSource(lease) }
            let validateCapture: @MainActor () throws -> Void = { try observer.validateTarget(lease) }
            let validateInput: @MainActor () throws -> Void = { try observer.validateForInput(lease) }
            // A retained source may outlive this image generation. Escaping
            // target closures keep only these immutable identity values.
            let applicationIdentity = snapshot.application
            let windowInfo = snapshot.window
            let target = Target(sourceID: lease.sourceID, application: applicationIdentity, window: windowInfo,
                validateOriginalSource: validateSource, validateForInput: validateInput,
                capture: { reserved in
                    if let reserved { return try await observer.observeOriginal(lease, reserved: reserved) }
                    return try await observer.observeOriginal(lease)
                }, isCurrent: { observer.isCurrent($0) },
                captureFocusForReview: { authorization in
                    try authorization()
                    return try Self.captureFocusForReview(application: applicationIdentity, originalWindow: originalWindow,
                        validateSource: { try authorization(); try validateSource() },
                        validateCapture: { try authorization(); try validateCapture() },
                        validateInput: { try authorization(); try validateInput() })
                }, restoreReviewedOriginalFocus: { authorization, gate, deadline in
                    await observer.restoreReviewedOriginalFocus(lease, authorization: authorization, gate: gate, notAfter: deadline)
                }, captureInsertionForReview: { gate, authorization in
                    try authorization(); try validateCapture()
                    return try NativeFocusedAXInsertion.captureForReview(application: applicationIdentity,
                        originalWindow: originalWindow,
                        validateOriginalSource: { try authorization(); try validateSource() },
                        validateForInput: { try authorization(); try validateInput() },
                        sessionIsActive: active, admissionGate: gate)
                }, policyTarget: {
                    try validateSource()
                    return NativeOriginalPolicyTarget(sourceID: lease.sourceID, application: applicationIdentity,
                        originalWindow: originalWindow, validateOriginalSource: validateSource)
                })
            try target.validateOriginalSource()
            revision = UUID()
            return Observation(snapshot: snapshot, owner: owner, revision: revision, target: target)
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }

    func observeForRead(target: Target) async throws -> Observation {
        try await acquire(); defer { release() }
        return try await withTaskCancellationHandler {
            try requireActive(); try target.validateOriginalSource()
            retireInputPreview()
            let expected = revision
            let snapshot = try await target.capture(nil)
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
            let snapshot = try await target.capture(nil)
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

    func validateOriginalSource(_ source: OriginalSource) throws {
        try requireActive()
        guard source.owner == owner else { throw Failure.wrongOwner }
        try source.target.validateOriginalSource(); try requireActive()
    }

    /// Actual retained AX-window metadata capability only. Image consumption
    /// does not create a replacement source, and this performs no capture,
    /// activation, focus or input. The reader separately gates task/privacy IO.
    func policyTarget(from source: OriginalSource) throws -> NativeOriginalPolicyTarget {
        try validateOriginalSource(source)
        guard let bind = source.target.policyTarget else { throw Failure.unqualifiedEffect }
        let target = try bind()
        try validateOriginalSource(source)
        guard target.sourceID == source.id, target.application == source.target.application else { throw Failure.wrongOwner }
        let scoped = target.addingSourceValidation { [weak self] in
            guard let self else { throw Failure.stopped }
            try self.validateOriginalSource(source)
        }
        try scoped.validateSource()
        try validateOriginalSource(source)
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
            let snapshot = try await target.capture(nil)
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

    func refreshOriginalForInputPlanning(_ source: OriginalSource,
                                        authorizeInputPlanning: @escaping @MainActor () throws -> Void) async throws -> Observation {
        try await acquire(); defer { release() }
        return try await withTaskCancellationHandler {
            try validateOriginalSource(source); try authorizeInputPlanning()
            retireInputPreview()
            let expected = revision, target = source.target
            let authorize: @MainActor () throws -> Void = { [weak self] in
                guard let self else { throw Failure.stopped }
                try self.requireActive(); try authorizeInputPlanning(); try target.validateOriginalSource()
            }
            var focus: FocusFence?, insertion: NativeFocusedAXInsertion?
            do { focus = try target.captureFocusForReview(authorize) }
            catch {
                try authorize()
                guard let failure = error as? Failure,
                      failure == .unavailableFocus else { throw error }
            }
            if let capture = target.captureInsertionForReview {
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
            try preview.validate()
            let snapshot = try await target.capture(nil)
            try requireRevision(expected); try authorize(); try preview.validate()
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
        try observation.inputPreview?.validate()
        try validate(observation)
    }

    func isCurrentForPlanning(_ observation: Observation) -> Bool {
        do { try validatePlanningObservation(observation); return true } catch { return false }
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
            focus = originalFocus; try focus?.validateSourceBeforeInput()
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
        try validate(observation); try focus?.validateSourceBeforeInput(); try permit.revalidate()
        // Only the trusted authorizer selects image-bound context after semantic/review
        // admission. Model geometry or an otherwise valid rectangle grants no authority.
        let rectangles = try permit.visualProof.nativeRectangles(action: action, frame: frame)
        let pixels: PixelProof?
        if let normalized { pixels = try await PixelProof.make(pixels: normalized, rectangles: rectangles) }
        else { pixels = nil }
        try validate(observation); try focus?.validateSourceBeforeInput(); try permit.revalidate()
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
                    let captured = self.clockNow()
                    let notAfter = min(reserved.notAfter, captured.advanced(by: .seconds(2)))
                    let fresh = try await target.capture(reserved)
                    if let source = prepared.permit.validateTaskSource { try self.validateTaskSource(source) }
                    try self.requireRevision(dispatchRevision); try prepared.request.validate(); try target.validateForInput()
                    guard target.isCurrent(fresh), fresh.application == prepared.context.application,
                          fresh.window.matchesExactly(prepared.context.window) else { throw Failure.staleObservation }
                    if let pixels = prepared.pixels, !(try await pixels.matches(fresh)) { throw Failure.changedPixels }
                    try self.requireRevision(dispatchRevision); try target.validateForInput()
                    try prepared.context.focus?.validateBeforeInput(); try prepared.permit.revalidate()
                    guard target.isCurrent(fresh), self.clockNow() < notAfter else { throw Failure.staleObservation }
                    try prepared.permit.consume()
                    if let source = prepared.permit.validateTaskSource { try self.validateTaskSource(source) }
                    try self.requireRevision(dispatchRevision); try prepared.request.validate(); try target.validateForInput()
                    try prepared.context.focus?.validateBeforeInput()
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
                    let fresh = try await target.capture(reserved)
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
            let snapshot = try await target.capture(reserved)
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
        case .native(let command): tool = command.tool; arguments = try command.arguments(app: app.bundleURL.path)
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
                                              validateInput: @escaping @MainActor () throws -> Void) throws -> FocusFence {
        try validateSource(); try validateCapture()
        let root = AXUIElementCreateApplication(application.processID)
        AXUIElementSetMessagingTimeout(root, 0.12)
        func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { throw Failure.unavailableFocus }
            return value
        }
        func element(_ value: CFTypeRef) throws -> AXUIElement {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw Failure.unavailableFocus }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        let focus = try element(attribute(root, kAXFocusedUIElementAttribute))
        guard CFEqual(try element(attribute(root, kAXFocusedWindowAttribute)), originalWindow),
              CFEqual(try element(attribute(focus, kAXWindowAttribute)), originalWindow) else { throw Failure.changedFocus }
        let sourceIdentity: @MainActor () throws -> Void = {
            try validateSource(); try validateCapture()
            guard CFEqual(try element(attribute(root, kAXFocusedUIElementAttribute)), focus),
                  CFEqual(try element(attribute(root, kAXFocusedWindowAttribute)), originalWindow),
                  CFEqual(try element(attribute(focus, kAXWindowAttribute)), originalWindow) else { throw Failure.changedFocus }
        }
        return try NativeControlFocus.capture(.init(validateIdentity: sourceIdentity,
            validateInputIdentity: { try sourceIdentity(); try validateInput(); try Self.requireForeground(application) },
            metadata: {
                func writable(_ element: AXUIElement, _ name: String) -> Bool {
                    var value = DarwinBoolean(false)
                    return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
                }
                return .init(role: (try? attribute(focus, kAXRoleAttribute)) as? String ?? "",
                    subrole: (try? attribute(focus, kAXSubroleAttribute)) as? String ?? "",
                    protected: NativeControlFocus.protectedValue([(try? attribute(focus, "AXProtectedContent")) as? Bool,
                        (try? attribute(focus, "AXContainsProtectedContent")) as? Bool]),
                    hidden: (try? attribute(focus, "AXHidden")) as? Bool,
                    enabled: (try? attribute(focus, kAXEnabledAttribute)) as? Bool,
                    valueWritable: writable(focus, kAXValueAttribute), selectionWritable: writable(focus, kAXSelectedTextRangeAttribute))
            }, qualifiedLabels: {
                try sourceIdentity()
                try NativeFocusedAXInsertion.validateSourceHierarchy(editor: focus, window: originalWindow, pid: application.processID)
                let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
                    .compactMap { (try? attribute(focus, $0)) as? String }.first { !$0.isEmpty }
                let identifier = ((try? attribute(focus, kAXIdentifierAttribute)) as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .init(label: label, identifier: identifier)
            }, contents: {
                guard let value = try attribute(focus, kAXValueAttribute) as? String else { throw Failure.unavailableFocus }
                let raw = try attribute(focus, kAXSelectedTextRangeAttribute)
                guard CFGetTypeID(raw) == AXValueGetTypeID() else { throw Failure.unavailableFocus }
                let axValue = unsafeDowncast(raw, to: AXValue.self)
                var range = CFRange()
                guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { throw Failure.unavailableFocus }
                return .init(value: value, selection: NSRange(location: range.location, length: range.length))
            }))
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
