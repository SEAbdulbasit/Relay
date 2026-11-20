import AppKit
import ApplicationServices
import Foundation
import ImageIO

/// Read-only admission for the native provider. Native indices are never AX references and
/// screenshots are transient memory, not ToolResult/chat/persistence payloads.
@MainActor
final class TargetBoundNativeObservation {
    nonisolated enum Failure: Error, Equatable {
        case inactiveSession, stopped, busy, staleRequest, ambiguousApplication, unavailableWindow
        case missingExclusiveApplication, multipleExclusiveApplications, changedExclusiveApplication
        case changedTarget, malformedHeader, wrongApplication, wrongWindow, nativeError, noUsableState
    }

    nonisolated struct WindowInfo: Sendable, Equatable {
        let title: String
        let role: String
        let identifier: String
        let document: String
        let url: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let minimized: Bool
        let hidden: Bool?
        let modal: Bool?

        func matchesExactly(_ other: Self) -> Bool {
            zip([title, role, identifier, document, url], [other.title, other.role, other.identifier, other.document, other.url])
                .allSatisfy { $0.utf16.elementsEqual($1.utf16) }
                && x == other.x && y == other.y && width == other.width && height == other.height
                && minimized == other.minimized && hidden == other.hidden && modal == other.modal
        }
    }

    /// Sealed only by the genuine saved ACK/anchor's supplied-original producer.
    /// It qualifies this exact retained process/window for direct AX operations,
    /// never app-only backend state/image dispatch or discovery of another app.
    @MainActor fileprivate final class AcknowledgedOriginalBinding {
        let identity: DesktopApplicationIdentity
        let application: NSRunningApplication
        let window: AXUIElement
        let purpose: NativeExactUnsentPurpose
        let validateEditor: @MainActor () throws -> Void

        private init(identity: DesktopApplicationIdentity, application: NSRunningApplication,
                     window: AXUIElement, purpose: NativeExactUnsentPurpose,
                     validateEditor: @escaping @MainActor () throws -> Void) {
            self.identity = identity; self.application = application
            self.window = window; self.purpose = purpose; self.validateEditor = validateEditor
        }

        /// No raw identity/window/callback constructor is available to a caller.
        /// The actual purpose spends its anchor's one preparation owner and
        /// brackets this entire binder with the existing full technical proof.
        static func withOriginal<Value>(purpose: NativeExactUnsentPurpose,
            owner: TargetBoundNativeObservation,
            readAudit: NativeReadAudit? = nil,
            body: (AcknowledgedOriginalBinding) throws -> Value) throws -> Value {
            try purpose.withSuppliedOriginal(owner: owner, readAudit: readAudit) { identity, application, window, validateEditor in
                try body(AcknowledgedOriginalBinding(identity: identity, application: application,
                    window: window, purpose: purpose, validateEditor: validateEditor))
            }
        }
    }

    struct Preparation {
        let application: DesktopApplicationIdentity
        let window: WindowInfo
        let sourceID: UUID
        /// Capture safety: provider app-only reads must still select this exact AX window.
        let validate: @MainActor () throws -> Void
        let validateSource: @MainActor () throws -> Void
        let validateInput: (@MainActor () throws -> Void)?
        fileprivate let originalAXWindow: AXUIElement?
        fileprivate let originalFocus: NativeOriginalWindowFocus?
        // Only bind(application:) can attach the real process/window adapter.
        // The inert Preparation initializer never supplies this capability.
        fileprivate var metadataSource: MetadataSource?
        fileprivate var acknowledgedOriginal: AcknowledgedOriginalBinding?

        init(application: DesktopApplicationIdentity, window: WindowInfo,
             validate: @escaping @MainActor () throws -> Void,
             sourceID: UUID = UUID(), validateSource: (@MainActor () throws -> Void)? = nil,
             validateInput: (@MainActor () throws -> Void)? = nil,
             originalAXWindow: AXUIElement? = nil, originalFocus: NativeOriginalWindowFocus? = nil) {
            self.application = application; self.window = window; self.validate = validate; self.sourceID = sourceID
            self.validateSource = validateSource ?? validate; self.validateInput = validateInput
            self.originalAXWindow = originalAXWindow; self.originalFocus = originalFocus
        }
    }

    struct Backend {
        let capture: @MainActor (String, String) async throws -> OwnedNativeComputerUseClient.NativeResult
        let close: @MainActor () async -> Void

        init(client: OwnedNativeComputerUseClient) {
            capture = { requestID, app in try await client.state(requestID: requestID, app: app) }
            close = { await client.close() }
        }

        init(capture: @escaping @MainActor (String, String) async throws -> OwnedNativeComputerUseClient.NativeResult,
             close: @escaping @MainActor () async -> Void) {
            self.capture = capture; self.close = close
        }
    }

    struct Request {
        fileprivate let owner: UUID
        fileprivate let revision: UUID
        fileprivate let preparation: Preparation
    }

    /// A retained exact-target capability. It never selects the currently active window.
    /// Snapshot generations may change while this target's original metadata remains pinned.
    struct TargetLease {
        fileprivate let owner: UUID
        fileprivate let session: UUID
        fileprivate let preparation: Preparation
        var sourceID: UUID { preparation.sourceID }
        var application: DesktopApplicationIdentity { preparation.application }
        func validate() throws { try preparation.validate() }
        func validateOriginalSource() throws { try preparation.validateSource() }
    }

    fileprivate struct MetadataSource {
        let validateReference: @MainActor () throws -> Void
        let validateSelectedWindow: @MainActor () throws -> Void
        let processBinding: DesktopApplicationTarget.MetadataProcessBinding
        let validateMetadataReference: @MainActor (DesktopApplicationTarget.MetadataProcessLease, DesktopApplicationTarget.MetadataProcessLease.QueryWitness?, NativeReadAudit?) throws -> Void
        let validateTechnicalReference: @MainActor (DesktopApplicationTarget.MetadataProcessLease, DesktopApplicationTarget.MetadataProcessLease.QueryWitness?, NativeReadAudit?) throws -> Void
    }

    /// Comparison data only. It cannot bind a live observer, scope or AX target.
    nonisolated struct MetadataLeaseIdentity: Equatable {
        let owner: UUID, session: UUID, sourceID: UUID
        func requireSame(as candidate: Self) throws {
            guard self == candidate else { throw Failure.staleRequest }
        }
    }

    /// The actual retained original binder alone supplies this descriptor.
    /// Logical task checks are synchronous and bracket one technical query.
    fileprivate final class DirectMetadataSource {
        private weak var observer: TargetBoundNativeObservation?
        private let identity: MetadataLeaseIdentity
        private let authority: NativeLocalTaskInputAuthority
        private let purpose: NativeExactUnsentPurpose
        private let context: AssistantStore.ExactUnsentSavedInvocation.MetadataContext

        fileprivate init(observer: TargetBoundNativeObservation, lease: TargetLease,
            authority: NativeLocalTaskInputAuthority, purpose: NativeExactUnsentPurpose,
            context: AssistantStore.ExactUnsentSavedInvocation.MetadataContext) {
            self.observer = observer
            identity = .init(owner: lease.owner, session: lease.session, sourceID: lease.sourceID)
            self.authority = authority; self.purpose = purpose; self.context = context
        }

        func requireScopeBinding(_ binding: NativeMetadataScopeBinding) throws {
            try binding.requireSealedMetadataAuthority(authority)
        }

        func metadataScopeBinding() -> NativeMetadataScopeBinding {
            authority.metadataScopeBinding(for: purpose.objective.anchor.application)
        }

        func withQuery(target: NativeOriginalPolicyTarget, authorization: NativeMetadataScopeBinding.Authorization,
            query: DesktopApplicationTarget.MetadataProcessLease.QueryWitness, readAudit: NativeReadAudit?,
            body: () throws -> Void) throws {
            try authorization.requireSealedProcess(authority: authority, purpose: purpose, context: context, currentQuery: query)
            try context.withMetadataQuery(scope: authority.scope, query: query, readAudit: readAudit, validateBinding: {
                guard let observer, observer.directMetadataAuthority === authority else { throw Failure.stopped }
                guard observer.activeSession else { observer.stop(); throw Failure.inactiveSession }
                guard !observer.stopped else { throw Failure.stopped }
                try identity.requireSame(as: .init(owner: observer.owner, session: observer.session, sourceID: target.sourceID))
                try authorization.requireSealedMetadataAuthority(authority)
                try purpose.validateSealedMetadataPreparation(scope: authority.scope, owner: observer, context: context)
            }, body: body)
        }

        func checkAdmittedTechnical(_ authorization: NativeMetadataScopeBinding.Authorization,
                                    query: DesktopApplicationTarget.MetadataProcessLease.QueryWitness) throws {
            try authorization.checkSealedTechnical(authority: authority, purpose: purpose, currentQuery: query)
        }
    }

    /// Producer-only factory for fresh lexical metadata phases. It retains no
    /// active phase, survey rows, images, labels or cached source verdict.
    final class MetadataBinding {
        private let sourceID: UUID
        private let application: DesktopApplicationIdentity
        private let window: AXUIElement
        private let validateReference: @MainActor () throws -> Void
        private let validateSelectedWindow: @MainActor () throws -> Void
        private let validateActualSource: @MainActor () throws -> Void
        private let processBinding: DesktopApplicationTarget.MetadataProcessBinding
        private let validateMetadataReference: @MainActor (DesktopApplicationTarget.MetadataProcessLease, DesktopApplicationTarget.MetadataProcessLease.QueryWitness?, NativeReadAudit?) throws -> Void
        private let validateTechnicalReference: @MainActor (DesktopApplicationTarget.MetadataProcessLease, DesktopApplicationTarget.MetadataProcessLease.QueryWitness?, NativeReadAudit?) throws -> Void
        private let directSource: DirectMetadataSource?

        /// Names this binder's actual lease validator. Only the original
        /// direct binder can mint it, with no caller-supplied callback.
        struct CanonicalDirectPolicySource {
            let binding: MetadataBinding
            fileprivate init(binding: MetadataBinding) { self.binding = binding }
            var sourceID: UUID { binding.sourceID }
            var application: DesktopApplicationIdentity { binding.application }
            var window: AXUIElement { binding.window }
            func validate() throws { try binding.validateActualSource() }
        }

        private struct ScopePlan {
            let target: NativeOriginalPolicyTarget
            let scope: NativeMetadataScopeBinding
            let usesCanonicalDirectSource: Bool
        }
        private let scopePlan: ScopePlan?
        var usesCanonicalDirectBoundary: Bool { scopePlan?.usesCanonicalDirectSource == true }

        fileprivate init(sourceID: UUID, application: DesktopApplicationIdentity, window: AXUIElement,
                         validateReference: @escaping @MainActor () throws -> Void,
                         validateSelectedWindow: @escaping @MainActor () throws -> Void,
                         validateActualSource: @escaping @MainActor () throws -> Void,
                         processBinding: DesktopApplicationTarget.MetadataProcessBinding,
                         validateMetadataReference: @escaping @MainActor (DesktopApplicationTarget.MetadataProcessLease, DesktopApplicationTarget.MetadataProcessLease.QueryWitness?, NativeReadAudit?) throws -> Void,
                         validateTechnicalReference: @escaping @MainActor (DesktopApplicationTarget.MetadataProcessLease, DesktopApplicationTarget.MetadataProcessLease.QueryWitness?, NativeReadAudit?) throws -> Void,
                         directSource: DirectMetadataSource?) {
            self.sourceID = sourceID; self.application = application; self.window = window
            self.validateReference = validateReference; self.validateSelectedWindow = validateSelectedWindow
            self.validateActualSource = validateActualSource
            self.processBinding = processBinding; self.validateMetadataReference = validateMetadataReference
            self.validateTechnicalReference = validateTechnicalReference; self.directSource = directSource
            scopePlan = nil
        }

        private init(copying original: MetadataBinding, plan: ScopePlan) {
            sourceID = original.sourceID; application = original.application; window = original.window
            validateReference = original.validateReference; validateSelectedWindow = original.validateSelectedWindow
            validateActualSource = original.validateActualSource; scopePlan = plan
            processBinding = original.processBinding; validateMetadataReference = original.validateMetadataReference
            validateTechnicalReference = original.validateTechnicalReference; directSource = original.directSource
        }

        func canonicalExactUnsentPolicyTarget(readAudit: NativeReadAudit?) -> NativeOriginalPolicyTarget? {
            guard directSource != nil, scopePlan == nil else { return nil }
            return NativeOriginalPolicyTarget(directSource: .init(binding: self), readAudit: readAudit)
        }

        func canonicalMetadataScope() -> NativeMetadataScopeBinding? {
            directSource?.metadataScopeBinding()
        }

        /// Keeps the actual producer fields, never another binding's plan or an
        /// active authorization. Only the exact retained target may scope it.
        func scoped(to target: NativeOriginalPolicyTarget, scope: NativeMetadataScopeBinding) throws -> MetadataBinding {
            guard target.sourceID == sourceID, target.application == application,
                  scope.application == application, target.matchesMetadataWindow(window) else { throw Failure.changedTarget }
            try directSource?.requireScopeBinding(scope)
            let plan = ScopePlan(target: target, scope: scope,
                usesCanonicalDirectSource: directSource != nil && target.usesCanonicalDirectSource(self))
            return MetadataBinding(copying: self, plan: plan)
        }

        func withPhase<Value>(sourceID: UUID, application: DesktopApplicationIdentity, window: AXUIElement,
                              deadline: ContinuousClock.Instant,
                              validateSource: @escaping @MainActor () throws -> Void,
                              authorizeScope: @escaping @MainActor () throws -> Void,
                              readAudit: NativeReadAudit?,
                              body: @MainActor (NativeMetadataPhase) throws -> Value) throws -> Value {
            guard sourceID == self.sourceID, application == self.application, CFEqual(window, self.window) else {
                throw Failure.changedTarget
            }
            func run(validateSource: @escaping @MainActor () throws -> Void,
                     authorizeScope: @escaping @MainActor () throws -> Void,
                     sharedQueryScope: (@MainActor (DesktopApplicationTarget.MetadataProcessLease.QueryWitness) throws -> Void)? = nil,
                     queryAuthorization: NativeMetadataScopeBinding.Authorization? = nil) throws -> Value {
                let result: Result<Value, any Error> = Result {
                    try processBinding.withLease { process in
                        try NativeMetadataPhase.run(deadline: deadline, boundary: {
                            try self.validateReference(); try authorizeScope(); try self.validateSelectedWindow()
                            // The canonical direct target's full check is this
                            // exact binder's producer proof. Keep both producer
                            // checks around every independent target callback.
                            if self.scopePlan?.usesCanonicalDirectSource != true {
                                try self.validateActualSource()
                            }
                            try validateSource()
                            if self.scopePlan?.usesCanonicalDirectSource != true {
                                try self.validateActualSource()
                            }
                            try self.validateSelectedWindow(); try authorizeScope(); try self.validateReference()
                        }, query: {
                            try NativeReadAudit.measure(readAudit, .policyMetadataLeaseValidation) {
                                if let sharedQueryScope {
                                    // Sharing ends before this aggregate callback returns;
                                    // the actual survey AX operation remains outside it.
                                    try process.withCurrentQuery(readAudit: readAudit) { currentQuery in
                                        if let directSource = self.directSource, let scopePlan = self.scopePlan,
                                           let queryAuthorization {
                                            try directSource.withQuery(target: scopePlan.target, authorization: queryAuthorization,
                                                query: currentQuery, readAudit: readAudit) {
                                                try NativeReadAudit.measure(readAudit, .policyMetadataReferenceValidation) {
                                                    try self.validateTechnicalReference(process, currentQuery, readAudit)
                                                }
                                                try NativeReadAudit.measure(readAudit, .policyMetadataScopeAuthorization) {
                                                    try scopePlan.target.validateAdditionalMetadataScope()
                                                    try directSource.checkAdmittedTechnical(queryAuthorization, query: currentQuery)
                                                }
                                                try NativeReadAudit.measure(readAudit, .policyMetadataReferenceValidation) {
                                                    try self.validateTechnicalReference(process, currentQuery, readAudit)
                                                }
                                            }
                                        } else {
                                            try NativeReadAudit.measure(readAudit, .policyMetadataReferenceValidation) {
                                                try self.validateMetadataReference(process, currentQuery, readAudit)
                                            }
                                            try NativeReadAudit.measure(readAudit, .policyMetadataScopeAuthorization) {
                                                try sharedQueryScope(currentQuery)
                                            }
                                            try NativeReadAudit.measure(readAudit, .policyMetadataReferenceValidation) {
                                                try self.validateMetadataReference(process, currentQuery, readAudit)
                                            }
                                        }
                                    }
                                } else {
                                    try NativeReadAudit.measure(readAudit, .policyMetadataReferenceValidation) {
                                        try self.validateMetadataReference(process, nil, readAudit)
                                    }
                                    // Opaque task restrictions keep their original full
                                    // admission callback; no caller verdict is cached.
                                    try NativeReadAudit.measure(readAudit, .policyMetadataScopeAuthorization) {
                                        try authorizeScope()
                                    }
                                    try NativeReadAudit.measure(readAudit, .policyMetadataReferenceValidation) {
                                        try self.validateMetadataReference(process, nil, readAudit)
                                    }
                                }
                            }
                        }, readAudit: readAudit, body: body)
                    }
                }
                return try NativeMetadataPhase.finishLease(result, deadline: deadline, readAudit: readAudit)
            }
            guard let scopePlan else { return try run(validateSource: validateSource, authorizeScope: authorizeScope) }
            let result: Result<Value, any Error> = Result {
                try scopePlan.scope.withAuthorization(readAudit: readAudit) { authorization in
                    let sharedQueryScope: (@MainActor (DesktopApplicationTarget.MetadataProcessLease.QueryWitness) throws -> Void)?
                    if authorization.canShareCurrentProcessQuery {
                        sharedQueryScope = { currentQuery in
                            try scopePlan.target.validateAdditionalMetadataScope()
                            try authorization.check(currentQuery: currentQuery)
                        }
                    } else {
                        guard directSource == nil else { throw Failure.staleRequest }
                        sharedQueryScope = nil
                    }
                    return try run(validateSource: { try scopePlan.target.validateSource() }, authorizeScope: {
                        try scopePlan.target.validateAdditionalMetadataScope(); try authorization.check()
                    }, sharedQueryScope: sharedQueryScope, queryAuthorization: authorization)
                }
            }
            return try NativeMetadataPhase.finishLease(result, deadline: deadline, readAudit: readAudit)
        }
    }

    nonisolated struct Image: Sendable {
        let data: Data
        let mimeType: String
        let width: Int
        let height: Int
    }

    /// Deliberately not Codable. Consumers must check isCurrent before using source data.
    nonisolated struct Snapshot: Sendable {
        let id: UUID
        let application: DesktopApplicationIdentity
        let window: WindowInfo
        let text: String
        let references: [String]
        let images: [Image]
        let imageCoverage: String?
        fileprivate let owner: UUID
        fileprivate let revision: UUID
    }

    nonisolated struct Header: Sendable, Equatable {
        let path: String
        let bundleID: String
        let processID: pid_t
        let windowTitle: String
    }

    private let owner = UUID()
    private var session = UUID()
    private var revision = UUID()
    private var generation: UInt64 = 0
    private var latestPreparation: Preparation?
    private var backend: Backend
    private let sessionIsActive: @MainActor () -> Bool
    private weak var directMetadataAuthority: NativeLocalTaskInputAuthority?
    private var activeSession = true
    private var stopped = false
    private var captureTask: Task<OwnedNativeComputerUseClient.NativeResult, Error>?
    private var captureID: UUID?
    private var cleanupTask: Task<Void, Never>?
    private var lastSnapshot: UUID?
    private var validateLatest: (@MainActor () throws -> Void)?
    private(set) var latest: Snapshot?

    init(client: OwnedNativeComputerUseClient, sessionIsActive: @escaping @MainActor () -> Bool) {
        backend = Backend(client: client)
        self.sessionIsActive = sessionIsActive
    }

    init(client: OwnedNativeComputerUseClient, directExactUnsentAuthority authority: NativeLocalTaskInputAuthority) {
        backend = Backend(client: client)
        sessionIsActive = authority.exactUnsentSessionLiveness()
        directMetadataAuthority = authority.metadataContext == nil ? nil : authority
    }

    init(backend: Backend, sessionIsActive: @escaping @MainActor () -> Bool) {
        self.backend = backend; self.sessionIsActive = sessionIsActive
    }

    func prepare(application: NSRunningApplication) throws -> Request {
        try requireActive()
        return try prepare(Self.bind(application: application, requireCurrent: { [weak self] in
            guard let self else { throw Failure.stopped }
            try self.requireActive()
        }))
    }

    /// Initial app-owned supplied-original purpose. This prepares metadata only;
    /// it neither captures state nor selects/focuses a replacement window/editor.
    func prepareInitialExactUnsent(_ purpose: NativeExactUnsentPurpose,
                                   readAudit: NativeReadAudit? = nil) throws -> Request {
        try requireActive()
        return try AcknowledgedOriginalBinding.withOriginal(purpose: purpose, owner: self, readAudit: readAudit) { original in
            try prepare(Self.bind(application: original.application, acknowledgedOriginal: original, readAudit: readAudit,
                requireCurrent: { [weak self] in
                    guard let self else { throw Failure.stopped }
                    try self.requireActive()
                    // Only the live task/ACK/owner lease, never a full survey,
                    // is repeated inside each lexical metadata query.
                    try purpose.validateMetadataOwnerForPreparedSource(owner: self)
                }))
        }
    }


    /// Metadata seam: production binds AX synchronously; tests supply inert metadata only.
    func prepare(_ preparation: Preparation) throws -> Request {
        try requireActive()
        guard captureTask == nil else { throw Failure.busy }
        try preparation.validate()
        guard Self.valid(preparation.window) else { throw Failure.unavailableWindow }
        return Request(owner: owner, revision: revision, preparation: preparation)
    }

    func observe(_ request: Request) async throws -> Snapshot {
        try await observe(request, capture: backend.capture)
    }

    private func observe(_ request: Request,
                         capture: @escaping @MainActor (String, String) async throws -> OwnedNativeComputerUseClient.NativeResult) async throws -> Snapshot {
        try requireActive()
        guard captureTask == nil else { throw Failure.busy }
        guard request.owner == owner, request.revision == revision else { throw Failure.staleRequest }
        // This backend selects by app path, not our sealed PID/AX window. A
        // direct supplied-original lease can never escape into that route.
        guard request.preparation.acknowledgedOriginal == nil else { throw Failure.unavailableWindow }
        invalidateSnapshot()
        try request.preparation.validate()
        guard generation < UInt64.max else { throw Failure.stopped }
        generation += 1
        let expectedRevision = revision
        let namespace = "native:\(session.uuidString):\(generation):"
        let task = Task { try await capture(UUID().uuidString, request.preparation.application.bundleURL.path) }
        let operation = UUID()
        captureID = operation
        captureTask = task
        defer { if captureID == operation { captureTask = nil; captureID = nil } }
        do {
            let result = try await withTaskCancellationHandler { try await task.value }
                onCancel: { task.cancel() }
            try requireCurrent(expectedRevision)
            try request.preparation.validate()
            guard !result.isError else { throw NativeReadProviderError(result: result) }
            let nativeText = try Self.stateText(result)
            let header = try Self.parseHeader(nativeText)
            try Self.validate(header, preparation: request.preparation)
            let decoded = await Self.decodeImages(result.content)
            try requireCurrent(expectedRevision)
            try request.preparation.validate()
            let scoped = Self.namespace(nativeText, prefix: namespace)
            guard !scoped.references.isEmpty || !decoded.images.isEmpty else { throw Failure.noUsableState }
            let snapshot = Snapshot(id: UUID(), application: request.preparation.application, window: request.preparation.window,
                text: scoped.text, references: scoped.references, images: decoded.images, imageCoverage: decoded.coverage,
                owner: owner, revision: expectedRevision)
            latest = snapshot; lastSnapshot = snapshot.id; validateLatest = request.preparation.validate
            latestPreparation = request.preparation
            return snapshot
        } catch {
            if revision == expectedRevision { invalidateSnapshot() }
            if let transport = error as? OwnedNativeComputerUseClient.Failure { throw NativeReadTransportError(transport) }
            throw error
        }
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        guard activeSession, sessionIsActive() else { stop(); return false }
        guard !stopped, snapshot.owner == owner, snapshot.revision == revision,
              snapshot.id == lastSnapshot else { return false }
        do { try validateLatest?(); return true }
        catch { invalidateSnapshot(); return false }
    }

    /// Metadata-only retained target before the first control image. General
    /// read capture is unchanged; a control caller may inspect this exact source
    /// before admitting provider image/AX state capture.
    func retainPreparedTarget(_ request: Request) throws -> TargetLease {
        try requireActive()
        guard request.owner == owner, request.revision == revision else { throw Failure.staleRequest }
        try request.preparation.validateSource()
        try requireActive()
        return TargetLease(owner: owner, session: session, preparation: request.preparation)
    }

    func retainTarget(for snapshot: Snapshot) throws -> TargetLease {
        try requireActive()
        guard isCurrent(snapshot), let preparation = latestPreparation else { throw Failure.staleRequest }
        return TargetLease(owner: owner, session: session, preparation: preparation)
    }

    /// Refresh and readback use the same original process/window/document, even if another
    /// application's window became current. A changed original target is refused.
    func observeOriginal(_ lease: TargetLease) async throws -> Snapshot {
        try validateTarget(lease)
        return try await observe(prepare(lease.preparation))
    }

    /// A provider FIFO reservation avoids a second queue acquisition between pixel proof and
    /// input dispatch. The reservation itself admits only this original app's state read.
    func observeOriginal(_ lease: TargetLease, reserved: OwnedNativeComputerUseClient.ReservedState) async throws -> Snapshot {
        try validateTarget(lease)
        return try await observe(prepare(lease.preparation), capture: { requestID, app in
            try await reserved.state(requestID: requestID, app: app)
        })
    }

    func validateTarget(_ lease: TargetLease) throws {
        try validateOriginalSource(lease)
        try lease.preparation.validate()
    }

    /// Independent of image consumption and global/app-selected foreground focus.
    func validateOriginalSource(_ lease: TargetLease) throws {
        try requireActive()
        guard lease.owner == owner, lease.session == session else { throw Failure.staleRequest }
        try lease.preparation.validateSource()
        try requireActive()
    }

    func validateForInput(_ lease: TargetLease) throws {
        try validateOriginalSource(lease)
        guard let validate = lease.preparation.validateInput else { throw Failure.unavailableWindow }
        try validate(); try requireActive()
    }

    func originalAXWindow(_ lease: TargetLease) throws -> AXUIElement {
        try validateOriginalSource(lease)
        guard let original = lease.preparation.originalAXWindow else { throw Failure.unavailableWindow }
        return original
    }

    func matchesOriginalAXWindow(_ candidate: AXUIElement, lease: TargetLease) -> Bool {
        guard lease.owner == owner, lease.session == session,
              let original = lease.preparation.originalAXWindow else { return false }
        return CFEqual(candidate, original)
    }

    func validateAlreadyVerifiedOriginalForInput(_ lease: TargetLease) throws {
        try requireActive()
        guard lease.owner == owner, lease.session == session,
              let original = lease.preparation.originalAXWindow else { throw Failure.staleRequest }
        let root = AXUIElementCreateApplication(lease.application.processID)
        AXUIElementSetMessagingTimeout(root, 0.12)
        guard CFEqual(try Self.selectedWindow(root), original),
              let app = NSRunningApplication(processIdentifier: lease.application.processID),
              DesktopApplicationTarget.matches(lease.application, application: app),
              app.isActive, let front = NSWorkspace.shared.frontmostApplication,
              DesktopApplicationTarget.matches(lease.application, application: front) else {
            throw Failure.changedTarget
        }
        try requireActive()
    }

    /// No fallback for an inert/custom Preparation. Production callers must
    /// obtain this from the same actual binder that retained their AX window.
    func metadataBinding(_ lease: TargetLease) throws -> MetadataBinding {
        try requireActive()
        guard lease.owner == owner, lease.session == session else { throw Failure.staleRequest }
        guard let source = lease.preparation.metadataSource,
              let window = lease.preparation.originalAXWindow else { throw Failure.unavailableWindow }
        let validateLease: @MainActor () throws -> Void = { [weak self] in
            guard let self else { throw Failure.stopped }
            try self.requireActive()
            guard lease.owner == self.owner, lease.session == self.session else { throw Failure.staleRequest }
        }
        try validateLease(); try source.validateReference(); try validateLease()
        let directSource: DirectMetadataSource?
        if let original = lease.preparation.acknowledgedOriginal, let authority = directMetadataAuthority {
            guard let context = authority.metadataContext,
                  case .initialExactUnsent(let purpose) = authority.windowRequirement,
                  original.purpose === purpose else { throw Failure.staleRequest }
            directSource = DirectMetadataSource(observer: self, lease: lease, authority: authority, purpose: purpose, context: context)
        } else { directSource = nil }
        return MetadataBinding(sourceID: lease.sourceID, application: lease.application, window: window,
            validateReference: {
                try validateLease(); try source.validateReference(); try validateLease()
            }, validateSelectedWindow: {
                try validateLease(); try source.validateSelectedWindow(); try validateLease()
            }, validateActualSource: { [weak self] in
                guard let self else { throw Failure.stopped }
                try self.validateOriginalSource(lease)
            }, processBinding: source.processBinding, validateMetadataReference: { process, currentQuery, audit in
                try NativeReadAudit.measure(audit, .policyMetadataObserverOwnerValidation) { try validateLease() }
                try source.validateMetadataReference(process, currentQuery, audit)
                try NativeReadAudit.measure(audit, .policyMetadataObserverOwnerValidation) { try validateLease() }
            }, validateTechnicalReference: source.validateTechnicalReference, directSource: directSource)
    }

    func restoreReviewedOriginalFocus(_ lease: TargetLease, authorization: NativeReviewedFocusAuthorization,
                                      gate: NativeInputRevocation,
                                      notAfter: ContinuousClock.Instant) async -> NativeReviewedFocusOutcome {
        do {
            try validateOriginalSource(lease)
            guard authorization.sourceID == lease.sourceID,
                  let binding = lease.preparation.originalFocus else { throw Failure.changedTarget }
            let outcome = await binding.restore(authorization: authorization, gate: gate, notAfter: notAfter)
            // Attempted focus facts must remain factual after Stop/source revocation.
            return outcome
        } catch { return .refused(NativeVisualStepOutcome.bounded(error.localizedDescription)) }
    }

    /// Invalidate immediately, before awaiting transport teardown. Resuming never captures.
    func stop() {
        let needsCleanup = !stopped
        stopped = true
        invalidateSnapshot()
        captureTask?.cancel(); captureTask = nil; captureID = nil
        guard needsCleanup else { return }
        let previous = cleanupTask, backend = backend
        cleanupTask = Task { await previous?.value; await backend.close() }
    }

    func drain() async { await cleanupTask?.value }

    func setSessionActive(_ active: Bool) {
        activeSession = active
        if !active { stop() }
    }

    func reconnect(client: OwnedNativeComputerUseClient) async throws {
        try await reconnect(backend: Backend(client: client))
    }

    func reconnect(backend next: Backend) async throws {
        stop()
        let expected = revision
        await drain()
        guard revision == expected, activeSession, sessionIsActive() else { await next.close(); throw Failure.inactiveSession }
        backend = next; session = UUID(); generation = 0; stopped = false
        revision = UUID()
    }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard activeSession, sessionIsActive() else { stop(); throw Failure.inactiveSession }
        guard !stopped else { throw Failure.stopped }
    }

    private func requireCurrent(_ expected: UUID) throws {
        try requireActive()
        guard revision == expected else { throw Failure.staleRequest }
    }

    private func invalidateSnapshot() {
        revision = UUID(); latest = nil; lastSnapshot = nil; validateLatest = nil; latestPreparation = nil
    }

    private nonisolated static func valid(_ window: WindowInfo) -> Bool {
        !window.title.isEmpty && window.title.utf8.count <= 8_192 && window.role == "AXWindow"
            && !window.minimized && window.hidden != true
            && [window.x, window.y, window.width, window.height].allSatisfy(\.isFinite)
            && window.width > 0 && window.height > 0 && window.width <= 32_768 && window.height <= 32_768
    }

    private static func bind(application: NSRunningApplication,
                             acknowledgedOriginal: AcknowledgedOriginalBinding? = nil,
                             readAudit: NativeReadAudit? = nil,
                             requireCurrent: @escaping @MainActor () throws -> Void) throws -> Preparation {
        try requireCurrent()
        guard AXIsProcessTrusted(), let identity = DesktopApplicationTarget.identity(of: application) else {
            throw Failure.ambiguousApplication
        }
        if let acknowledgedOriginal {
            guard application === acknowledgedOriginal.application,
                  identity == acknowledgedOriginal.identity else { throw Failure.changedTarget }
            // The first closed exact-field purpose covers native standard editors,
            // not browser document/tab acquisition or new Apple Events admission.
            if isBrowser(identity) { throw Failure.unavailableWindow }
        } else {
            // General app discovery and every app-only backend read keep their
            // original global ambiguity policy. A raw window cannot opt out.
            try requireExclusive(identity)
        }
        let root = AXUIElementCreateApplication(identity.processID)
        AXUIElementSetMessagingTimeout(root, 0.12)
        let window: AXUIElement
        if let acknowledgedOriginal { window = acknowledgedOriginal.window }
        else { window = try selectedWindow(root) }
        let initial = try windowInfo(window)
        guard valid(initial) else { throw Failure.unavailableWindow }
        let sourceID = UUID()
        let validateOriginalFacts: @MainActor () throws -> Void = {
            try requireCurrent()
            if let acknowledgedOriginal {
                try acknowledgedOriginal.validateEditor()
            } else {
                guard AXIsProcessTrusted(), DesktopApplicationTarget.matches(identity, application: application) else { throw Failure.changedTarget }
                try requireExclusive(identity)
            }
            var pid: pid_t = 0
            guard AXUIElementGetPid(window, &pid) == .success, pid == identity.processID,
                  initial.matchesExactly(try windowInfo(window, acknowledgedOriginal: acknowledgedOriginal, readAudit: readAudit)) else { throw Failure.changedTarget }
            try requireCurrent()
        }
        // An ordinary first binding selects once; a supplied binding never
        // chooses a current replacement. Both require selected-original proof.
        let validateInitiallySelected: @MainActor () throws -> Void = {
            try validateOriginalFacts()
            guard CFEqual(try selectedWindow(root), window) else { throw Failure.changedTarget }
            try requireCurrent()
        }
        try uniqueWindow(window, title: initial.title, root: root, allowSiblingRecovery: false,
                         validateOriginal: validateInitiallySelected, requireCurrent: requireCurrent)
        let browser = isBrowser(identity)
            ? try BrowserPageReader.captureCurrentTarget(application: application, expectedWindow: window) : nil
        if let browser { try BrowserPageReader.validateCurrentTarget(browser, expectedWindow: window) }
        let validateOriginalDocument: @MainActor () throws -> Void = {
            try validateOriginalFacts()
            if let browser {
                try BrowserPageReader.validateCurrentTarget(browser, expectedWindow: window)
                try requireCurrent()
            }
        }
        let validateSource: @MainActor () throws -> Void = {
            try uniqueWindow(window, title: initial.title, root: root, allowSiblingRecovery: true,
                validateOriginal: validateOriginalDocument, requireCurrent: requireCurrent, readAudit: readAudit)
        }
        let validateCapture: @MainActor () throws -> Void = {
            try validateSource()
            // The native schema cannot choose an arbitrary window. Refuse before
            // calling it when this app's selected window is no longer the original.
            guard CFEqual(try selectedWindow(root), window) else { throw Failure.changedTarget }
            try validateSource()
        }
        let validateInput: @MainActor () throws -> Void = {
            try validateCapture()
            guard application.isActive, let front = NSWorkspace.shared.frontmostApplication,
                  DesktopApplicationTarget.matches(identity, application: front) else { throw Failure.changedTarget }
            try validateCapture()
        }
        let focus = NativeOriginalWindowFocus(sourceID: sourceID, application: application, identity: identity,
            originalWindow: window, validateOriginalSource: validateSource,
            validateForInput: validateInput, sessionIsActive: { (try? requireCurrent()) != nil })
        try requireCurrent()
        var preparation = Preparation(application: identity, window: initial, validate: validateCapture,
            sourceID: sourceID, validateSource: validateSource, validateInput: validateInput,
            originalAXWindow: window, originalFocus: focus)
        preparation.acknowledgedOriginal = acknowledgedOriginal
        let processBinding = try DesktopApplicationTarget.MetadataProcessBinding.bind(identity: identity, application: application)
        let validateTechnicalReference: @MainActor (DesktopApplicationTarget.MetadataProcessLease,
            DesktopApplicationTarget.MetadataProcessLease.QueryWitness?, NativeReadAudit?) throws -> Void = { process, currentQuery, audit in
            guard NativeReadAudit.measure(audit, .policyMetadataTrustValidation, operation: { AXIsProcessTrusted() }) else {
                throw Failure.changedTarget
            }
            try NativeReadAudit.measure(audit, .policyMetadataProcessFenceValidation) { try process.check(currentQuery: currentQuery) }
            var windowPID: pid_t = 0, rootPID: pid_t = 0
            guard NativeReadAudit.measure(audit, .policyMetadataWindowPIDValidation, operation: {
                AXUIElementGetPid(window, &windowPID) == .success && windowPID == identity.processID
            }), NativeReadAudit.measure(audit, .policyMetadataRootPIDValidation, operation: {
                AXUIElementGetPid(root, &rootPID) == .success && rootPID == identity.processID
            }) else {
                throw Failure.changedTarget
            }
            try NativeReadAudit.measure(audit, .policyMetadataProcessFenceValidation) { try process.check(currentQuery: currentQuery) }
        }
        preparation.metadataSource = MetadataSource(validateReference: {
            try requireCurrent()
            guard AXIsProcessTrusted(), DesktopApplicationTarget.matches(identity, application: application) else {
                throw Failure.changedTarget
            }
            // Retained AX objects are never reselected here. Their PID plus
            // each actual query's live result constrain this metadata-only scan;
            // full window/document/browser proof remains a phase boundary check.
            var windowPID: pid_t = 0, rootPID: pid_t = 0
            guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == identity.processID,
                  AXUIElementGetPid(root, &rootPID) == .success, rootPID == identity.processID else {
                throw Failure.changedTarget
            }
            try requireCurrent()
        }, validateSelectedWindow: {
            try requireCurrent()
            guard CFEqual(try selectedWindow(root), window) else { throw Failure.changedTarget }
            try requireCurrent()
        }, processBinding: processBinding, validateMetadataReference: { process, currentQuery, audit in
            try NativeReadAudit.measure(audit, .policyMetadataCurrentValidation) { try requireCurrent() }
            try validateTechnicalReference(process, currentQuery, audit)
            try NativeReadAudit.measure(audit, .policyMetadataCurrentValidation) { try requireCurrent() }
        }, validateTechnicalReference: validateTechnicalReference)
        return preparation
    }

    private static func requireExclusive(_ identity: DesktopApplicationIdentity) throws {
        let registered = NSRunningApplication.runningApplications(withBundleIdentifier: identity.bundleID)
        let workspace = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == identity.bundleID }
        let live = (registered + workspace).filter { !$0.isTerminated }
        let processIDs = Set(live.map(\.processIdentifier))
        guard !processIDs.isEmpty else { throw Failure.missingExclusiveApplication }
        guard processIDs.count == 1 else { throw Failure.multipleExclusiveApplications }
        guard live.allSatisfy({ DesktopApplicationTarget.matches(identity, application: $0) }) else {
            throw Failure.changedExclusiveApplication
        }
    }

    private static func isBrowser(_ identity: DesktopApplicationIdentity) -> Bool {
        let known: Set<String> = ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
                                  "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
        if known.contains(identity.bundleID) { return true }
        let types = Bundle(url: identity.bundleURL)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.contains { item in
            (item["CFBundleURLSchemes"] as? [String] ?? []).contains { ["http", "https"].contains($0.lowercased()) }
        }
    }

    private static func selectedWindow(_ root: AXUIElement) throws -> AXUIElement {
        guard let value = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw Failure.unavailableWindow
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func uniqueWindow(_ original: AXUIElement, title: String, root: AXUIElement,
                                     allowSiblingRecovery: Bool,
                                     validateOriginal: @escaping @MainActor () throws -> Void,
                                     requireCurrent: @escaping @MainActor () throws -> Void,
                                     readAudit: NativeReadAudit? = nil) throws {
        try NativeReadAudit.measure(readAudit, .retainedUniqueWindowValidation) {
            let backend = NativeWindowEnumeration.Backend<AXUIElement>(enumerate: {
                var value: CFTypeRef?
                let status = NativeReadAudit.measure(readAudit, .retainedUniqueWindowListRead) {
                    AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
                }
                guard status == .success else { throw NativeWindowEnumeration.ReadFailure(attribute: .windows, status: status) }
                guard let windows = value as? [AXUIElement] else { throw Failure.unavailableWindow }
                return windows
            }, title: { member in
                AXUIElementSetMessagingTimeout(member, 0.04)
                var value: CFTypeRef?
                let status = NativeReadAudit.measure(readAudit, .retainedUniqueWindowTitleRead) {
                    AXUIElementCopyAttributeValue(member, kAXTitleAttribute as CFString, &value)
                }
                guard status == .success else { throw NativeWindowEnumeration.ReadFailure(attribute: .title, status: status) }
                guard let title = value as? String else { throw Failure.unavailableWindow }
                return title
            }, same: { CFEqual($0, $1) }, validateOriginal: validateOriginal, requireCurrent: {
                try NativeReadAudit.measure(readAudit, .retainedUniqueWindowCurrentValidation) { try requireCurrent() }
            })
            do {
                try NativeWindowEnumeration.validate(original: original, title: title,
                    allowSiblingRecovery: allowSiblingRecovery, backend: backend)
            } catch let error as NativeWindowEnumeration.Failure {
                switch error {
                case .unavailableWindow: throw Failure.unavailableWindow
                case .wrongWindow: throw Failure.wrongWindow
                case .changedEnumeration: throw Failure.changedTarget
                }
            } catch is NativeWindowEnumeration.ReadFailure {
                throw Failure.unavailableWindow
            }
        }
    }

    static let requiredWindowInfoAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXMinimizedAttribute,
                                               kAXPositionAttribute, kAXSizeAttribute]
    static let optionalWindowInfoAttributes = [kAXIdentifierAttribute, kAXDocumentAttribute, kAXURLAttribute,
                                               "AXHidden", "AXModal"]
    static let acknowledgedWindowInfoAttributes = requiredWindowInfoAttributes + optionalWindowInfoAttributes

    struct RequiredWindowInfo {
        let role: String, title: String
        let minimized: Bool
        let point: CGPoint, dimensions: CGSize
    }

    static func decodeRequiredWindowInfo(status: AXError, values: CFTypeRef?) throws -> RequiredWindowInfo {
        guard status == .success, let values, CFGetTypeID(values) == CFArrayGetTypeID() else { throw Failure.unavailableWindow }
        let array = unsafeDowncast(values, to: CFArray.self)
        guard CFArrayGetCount(array) == requiredWindowInfoAttributes.count else { throw Failure.unavailableWindow }
        return try decodeRequiredWindowInfoPrefix(array)
    }

    private static func decodeRequiredWindowInfoPrefix(_ array: CFArray) throws -> RequiredWindowInfo {
        func required(_ index: Int, type: CFTypeID) throws -> CFTypeRef {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { throw Failure.unavailableWindow }
            let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as CFTypeRef
            guard CFGetTypeID(value) == type else { throw Failure.unavailableWindow }
            return value
        }
        guard let role = try required(0, type: CFStringGetTypeID()) as? String,
              let title = try required(1, type: CFStringGetTypeID()) as? String else { throw Failure.unavailableWindow }
        let minimized = CFBooleanGetValue(unsafeDowncast(try required(2, type: CFBooleanGetTypeID()), to: CFBoolean.self))
        let position = unsafeDowncast(try required(3, type: AXValueGetTypeID()), to: AXValue.self)
        let size = unsafeDowncast(try required(4, type: AXValueGetTypeID()), to: AXValue.self)
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { throw Failure.unavailableWindow }
        let (point, dimensions) = try windowGeometry(position, size)
        return .init(role: role, title: title, minimized: minimized, point: point, dimensions: dimensions)
    }

    static func decodeAcknowledgedWindowInfo(status: AXError, values: CFTypeRef?) throws -> WindowInfo {
        guard status == .success, let values, CFGetTypeID(values) == CFArrayGetTypeID() else { throw Failure.unavailableWindow }
        let array = unsafeDowncast(values, to: CFArray.self)
        guard CFArrayGetCount(array) == acknowledgedWindowInfoAttributes.count else { throw Failure.unavailableWindow }
        let required = try decodeRequiredWindowInfoPrefix(array)
        func optionalSlot(_ index: Int) -> CFTypeRef? {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as CFTypeRef
            if CFGetTypeID(value) == AXValueGetTypeID() {
                let axValue = unsafeDowncast(value, to: AXValue.self)
                if AXValueGetType(axValue) == .axError { return nil }
            }
            if CFGetTypeID(value) == CFNullGetTypeID() { return nil }
            return value
        }
        func optionalText(_ index: Int) -> String {
            guard let value = optionalSlot(index) else { return "" }
            if let string = value as? String { return string }
            if let url = value as? URL { return url.absoluteString }
            return ""
        }
        func optionalBool(_ index: Int) -> Bool? {
            guard let value = optionalSlot(index), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        }
        return WindowInfo(
            title: required.title,
            role: required.role,
            identifier: optionalText(5),
            document: optionalText(6),
            url: optionalText(7),
            x: required.point.x,
            y: required.point.y,
            width: required.dimensions.width,
            height: required.dimensions.height,
            minimized: required.minimized,
            hidden: optionalBool(8),
            modal: optionalBool(9)
        )
    }

    private static func windowGeometry(_ position: AXValue, _ size: AXValue) throws -> (CGPoint, CGSize) {
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { throw Failure.unavailableWindow }
        return (point, dimensions)
    }

    private static func windowInfo(_ window: AXUIElement,
                                   acknowledgedOriginal: AcknowledgedOriginalBinding? = nil,
                                   readAudit: NativeReadAudit? = nil) throws -> WindowInfo {
        try NativeReadAudit.measure(readAudit, .retainedWindowInfoValidation) {
            AXUIElementSetMessagingTimeout(window, 0.08)
            if let acknowledgedOriginal {
                // Only the genuine acknowledged original's full source proof uses
                // this fixed batch. Any incomplete required slot refuses without fallback.
                guard CFEqual(window, acknowledgedOriginal.window) else { throw Failure.changedTarget }
                var values: CFArray?
                let status = NativeReadAudit.measure(readAudit, .retainedWindowInfoRequiredBatchRead) {
                    AXUIElementCopyMultipleAttributeValues(acknowledgedOriginal.window,
                        acknowledgedWindowInfoAttributes as CFArray, [], &values)
                }
                return try decodeAcknowledgedWindowInfo(status: status, values: values)
            }
            guard let role = attribute(window, kAXRoleAttribute) as? String,
                  let title = attribute(window, kAXTitleAttribute) as? String,
                  let minimized = attribute(window, kAXMinimizedAttribute) as? Bool,
                  let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { throw Failure.unavailableWindow }
            let (point, dimensions) = try windowGeometry(unsafeBitCast(position, to: AXValue.self), unsafeBitCast(size, to: AXValue.self))
            let required = RequiredWindowInfo(role: role, title: title, minimized: minimized, point: point, dimensions: dimensions)
            @MainActor func text(_ name: String) -> String {
                let value = attribute(window, name)
                if let string = value as? String { return string }
                if let url = value as? URL { return url.absoluteString }
                return ""
            }
            let optional = NativeReadAudit.measure(readAudit, .retainedWindowInfoOptionalAttributesRead) {
                (identifier: text(kAXIdentifierAttribute),
                 document: text(kAXDocumentAttribute),
                 url: text(kAXURLAttribute),
                 hidden: attribute(window, "AXHidden") as? Bool,
                 modal: attribute(window, "AXModal") as? Bool)
            }
            return WindowInfo(title: required.title, role: required.role, identifier: optional.identifier, document: optional.document,
                url: optional.url, x: required.point.x, y: required.point.y,
                width: required.dimensions.width, height: required.dimensions.height,
                minimized: required.minimized, hidden: optional.hidden, modal: optional.modal)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    nonisolated static func parseHeader(_ text: String) throws -> Header {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(5).map(String.init)
        guard lines.count >= 4, lines[0].hasPrefix("Computer Use state (CUA App Version: "), lines[0].hasSuffix(")"),
              lines[1] == "<app_state>", lines[2].hasPrefix("App="), lines[2].hasSuffix(")"),
              let bundleStart = lines[2].range(of: " (bundleID ", options: .backwards),
              let pidStart = lines[2].range(of: ", pid ", options: .backwards), bundleStart.upperBound < pidStart.lowerBound else {
            throw Failure.malformedHeader
        }
        let version = lines[0].dropFirst("Computer Use state (CUA App Version: ".count).dropLast()
        guard !version.isEmpty, version.count <= 20, version.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw Failure.malformedHeader
        }
        var path = String(lines[2][lines[2].index(lines[2].startIndex, offsetBy: 4)..<bundleStart.lowerBound])
        if path.hasSuffix("/") && path != "/" { path.removeLast() }
        let bundle = String(lines[2][bundleStart.upperBound..<pidStart.lowerBound])
        let rawPID = lines[2][pidStart.upperBound..<lines[2].index(before: lines[2].endIndex)]
        guard path.hasPrefix("/"), !bundle.isEmpty, !rawPID.isEmpty,
              rawPID.allSatisfy({ $0.isASCII && $0.isNumber }), let pid = pid_t(rawPID), pid > 0,
              lines[3].hasPrefix("Window: \""), let titleEnd = lines[3].range(of: "\", App: ", options: .backwards),
              titleEnd.lowerBound >= lines[3].index(lines[3].startIndex, offsetBy: 9),
              titleEnd.upperBound < lines[3].endIndex else { throw Failure.malformedHeader }
        let title = String(lines[3][lines[3].index(lines[3].startIndex, offsetBy: 9)..<titleEnd.lowerBound])
        guard !title.isEmpty else { throw Failure.malformedHeader }
        return Header(path: path, bundleID: bundle, processID: pid, windowTitle: title)
    }

    private static func validate(_ header: Header, preparation: Preparation) throws {
        let identity = preparation.application
        guard header.processID == identity.processID, header.bundleID.utf16.elementsEqual(identity.bundleID.utf16),
              header.path.utf16.elementsEqual(identity.bundleURL.path.utf16) else { throw Failure.wrongApplication }
        guard header.windowTitle.utf16.elementsEqual(preparation.window.title.utf16) else { throw Failure.wrongWindow }
    }

    private nonisolated static func stateText(_ result: OwnedNativeComputerUseClient.NativeResult) throws -> String {
        guard let text = result.content.first?.object, text["type"] == .string("text"), let content = text["text"]?.string,
              content.utf8.count <= 256_000 else { throw Failure.malformedHeader }
        return content
    }

    private nonisolated static func namespace(_ text: String, prefix: String) -> (text: String, references: [String]) {
        var references: [String] = [], seen = Set<String>(), ids: [String: String] = [:]
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let leading = line.prefix { $0 == "\t" || $0 == " " }
            let remainder = line.dropFirst(leading.count)
            let digits = remainder.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 8, remainder.dropFirst(digits.count).first == " " else { return String(line) }
            let id = prefix + digits
            ids[String(digits)] = id
            if seen.insert(id).inserted { references.append(id) }
            return String(leading) + "[" + id + "]" + remainder.dropFirst(digits.count)
        }
        let focusedPrefix = "The focused UI element is "
        lines = lines.map { line in
            guard line.hasPrefix(focusedPrefix) else { return line }
            let remainder = line.dropFirst(focusedPrefix.count)
            let digits = remainder.prefix { $0.isASCII && $0.isNumber }
            guard let id = ids[String(digits)], remainder.dropFirst(digits.count).first == " " else { return line }
            return focusedPrefix + "[" + id + "]" + remainder.dropFirst(digits.count)
        }
        return (lines.joined(separator: "\n"), references)
    }

    private nonisolated struct DecodedImages: Sendable { let images: [Image]; let coverage: String? }

    @concurrent private static func decodeImages(_ content: [JSONValue]) async -> DecodedImages {
        var images: [Image] = [], bytes = 0, rejected = 0
        for value in content where value.object?["type"] == .string("image") {
            guard images.count < 4, let object = value.object, let encoded = object["data"]?.string,
                  encoded.utf8.count <= 12 * 1_048_576, let mime = object["mimeType"]?.string,
                  ["image/png", "image/jpeg"].contains(mime), let data = Data(base64Encoded: encoded),
                  data.count <= 8 * 1_048_576, bytes + data.count <= 12 * 1_048_576,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8_192, height <= 8_192,
                  width <= 32_000_000 / height,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_048, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                rejected += 1; continue
            }
            bytes += data.count
            images.append(Image(data: data, mimeType: mime, width: width, height: height))
        }
        return DecodedImages(images: images,
            coverage: rejected > 0 ? "Some native images were unavailable or invalid. Use the scoped accessibility text when sufficient; no coordinates are authorized." : nil)
    }
}
