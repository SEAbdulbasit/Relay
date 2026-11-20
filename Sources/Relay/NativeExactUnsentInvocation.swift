import AppKit
import ApplicationServices
import Foundation

nonisolated enum NativeExactUnsentFailure: Error, Equatable {
    case unavailable, changedOriginal, protectedContext, revoked, wrongTask
    case invalidLiteral, wrongMessage, acknowledgmentBridgeUnavailable, directAdapterUnavailable, alreadyPrepared
}

/// Failure location only. No AX value, application identity or text is retained.
nonisolated struct NativeExactUnsentCaptureDiagnostic: Encodable, Sendable {
    enum Stage: String, Encodable, Sendable {
        case missingOriginal, storeInactive, storeClearing, storeRestoring, storeDraining
        case dependencyAccessibility, dependencyRuntime, presentation, originRevision
        case accessibilityTrust, applicationActive, applicationIdentity, initialFrontmost
        case focusedWindow, focusedEditor, technicalSnapshot, snapshotPolicy, finalReference, finalFrontmost
    }
    enum Check: String, Encodable, Sendable { case source, deadline, attributeResult, attributeType, processIdentifier }
    enum Attribute: String, Encodable, Sendable {
        case focusedWindow = "AXFocusedWindow", focusedEditor = "AXFocusedUIElement"
        case editorWindow = "AXWindow", windows = "AXWindows", hidden = "AXHidden"
        case minimized = "AXMinimized", enabled = "AXEnabled", role = "AXRole"
        case subrole = "AXSubrole", modal = "AXModal", protected = "AXProtectedContent"
        case containsProtected = "AXContainsProtectedContent"
    }
    struct Read: Encodable, Sendable {
        let check: Check
        let attribute: Attribute?
        let axStatus: Int32?
    }
    let stage: Stage
    var read: Read? = nil
}

/// Supported absence stays distinct from false and from an AX/type failure.
nonisolated enum NativeExactUnsentOptionalFact<Value: Equatable>: Equatable {
    case reported(Value), unsupported, noValue
    var reported: Value? { if case .reported(let value) = self { value } else { nil } }
}

/// Technical metadata only. This type and its comparison mint no permission.
@MainActor struct NativeExactUnsentTechnicalSnapshot<Node> {
    let application: DesktopApplicationIdentity
    let window: Node, editor: Node, selectedWindow: Node, selectedEditor: Node, editorWindow: Node
    let windows: [Node]
    let rootPID: Int32, windowPID: Int32, editorPID: Int32
    let applicationHidden: Bool, minimized: Bool, enabled: Bool
    let windowRole: String, editorRole: String
    let editorSubrole: NativeExactUnsentOptionalFact<String>
    let modal: NativeExactUnsentOptionalFact<Bool>
    let protection: [NativeExactUnsentOptionalFact<Bool>]

    func validate(original: Self? = nil, identical: (Node, Node) -> Bool) throws {
        try Task.checkCancellation()
        guard !protection.contains(where: { $0.reported == true }),
              modal.reported != true else { throw NativeExactUnsentFailure.protectedContext }
        if let subrole = editorSubrole.reported,
           ["secure", "password", "search"].contains(where: { subrole.localizedCaseInsensitiveContains($0) }) {
            throw NativeExactUnsentFailure.protectedContext
        }
        guard application.processID > 0, protection.count == 6,
              !applicationHidden, !minimized, enabled, windowRole == "AXWindow",
              ["AXTextField", "AXTextArea"].contains(editorRole),
              rootPID == application.processID, windowPID == application.processID, editorPID == application.processID,
              !windows.isEmpty, windows.count <= 64,
              windows.filter({ identical($0, window) }).count == 1,
              identical(selectedWindow, window), identical(selectedEditor, editor), identical(editorWindow, window) else {
            throw NativeExactUnsentFailure.changedOriginal
        }
        if let original {
            guard application == original.application, identical(window, original.window), identical(editor, original.editor),
                  windowRole == original.windowRole, editorRole == original.editorRole,
                  editorSubrole == original.editorSubrole, modal == original.modal,
                  protection == original.protection else { throw NativeExactUnsentFailure.changedOriginal }
        }
    }
}

/// Pure namespace comparison, NOT a saved-message receipt or an ACK constructor.
nonisolated struct NativeExactUnsentMessageBinding: Equatable {
    let messageID: UUID, logicalTaskID: UUID, runID: UUID, attemptID: UUID
    let anchorID: UUID, originID: UUID
    let originRevision: Int
    let exactRequestUTF8: Data
    let literalUTF8: Data
    func requireSame(_ current: Self) throws {
        guard self == current else { throw NativeExactUnsentFailure.wrongMessage }
    }
}

/// Weak owner identity only; no observer, snapshot or source grant is retained.
/// Even a failed first preparation cannot remint adoption in another owner.
@MainActor final class NativeExactUnsentPreparationOwnership {
    private weak var owner: AnyObject?
    private var began = false
    func begin(owner: AnyObject) throws {
        guard !began else { throw NativeExactUnsentFailure.alreadyPrepared }
        began = true; self.owner = owner
    }
    func validate(owner: AnyObject) throws {
        guard began, self.owner === owner else { throw NativeExactUnsentFailure.wrongTask }
    }
}

/// Identity-only pre-composer anchor. The sole production constructor reads
/// actual technical OS metadata; there is no AX-reference/test constructor.
@MainActor final class NativeExactUnsentInvocationAnchor {
    let id = UUID()
    let originID: UUID
    let originRevision: Int
    let application: DesktopApplicationIdentity
    private let window: AXUIElement
    private let editor: AXUIElement
    private let root: AXUIElement
    private let applicationObject: NSRunningApplication
    private let initial: NativeExactUnsentTechnicalSnapshot<AXUIElement>
    private var presentationCheck: (@MainActor () throws -> Void)?
    private var claimedScope: NativeVisualTaskScope?
    private var savedOwner: AssistantStore.ExactUnsentSavedInvocation?
    private var retainedProcessBinding: DesktopApplicationTarget.MetadataProcessBinding?
    private var attemptedSavedHandoff = false
    private let preparationOwner = NativeExactUnsentPreparationOwnership()
    private var revoked = false
    var isAvailableForNewInvocation: Bool { !revoked && !attemptedSavedHandoff && savedOwner == nil && claimedScope == nil }

    private init(originID: UUID, originRevision: Int, application: NSRunningApplication,
                 root: AXUIElement, initial: NativeExactUnsentTechnicalSnapshot<AXUIElement>,
                 validatePresentation: @escaping @MainActor () throws -> Void) {
        self.originID = originID; self.originRevision = originRevision
        self.application = initial.application; window = initial.window; editor = initial.editor
        self.root = root; applicationObject = application; self.initial = initial
        presentationCheck = validatePresentation
    }

    /// Call only BEFORE the Sidekick composer becomes key. This does not
    /// request TCC, query private field data, create a task or open a client.
    static func captureBeforeComposerFocus(application: NSRunningApplication, originID: UUID,
        originRevision: Int, diagnostic: (@MainActor (NativeExactUnsentCaptureDiagnostic) -> Void)? = nil,
        validatePresentation: @escaping @MainActor () throws -> Void) throws -> Self {
        var stage = NativeExactUnsentCaptureDiagnostic.Stage.presentation
        var readFailure: NativeExactUnsentCaptureDiagnostic.Read?
        do {
            try Task.checkCancellation(); try validatePresentation()
            stage = .originRevision
            guard originRevision >= 0 else { throw NativeExactUnsentFailure.unavailable }
            stage = .accessibilityTrust
            guard AXIsProcessTrusted() else { throw NativeExactUnsentFailure.unavailable }
            stage = .applicationActive
            guard application.isActive else { throw NativeExactUnsentFailure.unavailable }
            stage = .applicationIdentity
            guard let identity = DesktopApplicationTarget.identity(of: application) else { throw NativeExactUnsentFailure.unavailable }
            stage = .initialFrontmost
            guard let front = NSWorkspace.shared.frontmostApplication,
                  DesktopApplicationTarget.matches(identity, application: front) else { throw NativeExactUnsentFailure.unavailable }
            let root = AXUIElementCreateApplication(identity.processID)
            let recordFailure: (@MainActor (NativeExactUnsentCaptureDiagnostic.Read) -> Void)?
            if diagnostic != nil {
                recordFailure = { event in readFailure = event }
            } else {
                recordFailure = nil
            }
            let read = Reader(check: {
                try validatePresentation(); try Task.checkCancellation()
                guard AXIsProcessTrusted(), DesktopApplicationTarget.matches(identity, application: application) else {
                    throw NativeExactUnsentFailure.changedOriginal
                }
            }, recordFailure: recordFailure)
            stage = .focusedWindow
            let window = try read.element(root, kAXFocusedWindowAttribute)
            stage = .focusedEditor
            let editor = try read.element(root, kAXFocusedUIElementAttribute)
            stage = .technicalSnapshot
            let snapshot = try technicalSnapshot(application: identity, root: root, window: window, editor: editor, read: read)
            stage = .snapshotPolicy
            try snapshot.validate(identical: { CFEqual($0, $1) })
            try read.warmWindowChildren(window)
            stage = .finalReference
            try read.check()
            stage = .finalFrontmost
            guard application.isActive, let currentFront = NSWorkspace.shared.frontmostApplication,
                  DesktopApplicationTarget.matches(identity, application: currentFront) else { throw NativeExactUnsentFailure.changedOriginal }
            return Self(originID: originID, originRevision: originRevision, application: application, root: root,
                initial: snapshot, validatePresentation: validatePresentation)
        } catch {
            diagnostic?(.init(stage: stage, read: readFailure))
            throw error
        }
    }

    func revoke() { revoked = true; presentationCheck = nil; claimedScope = nil; retainedProcessBinding = nil }

    /// Closing an acknowledged surface cannot revoke the Store-owned task.
    func revokePresentation() {
        if savedOwner == nil, claimedScope == nil { revoke() }
    }

    /// Metadata-only ownership transition from actual durable user record to
    /// this exact pre-composer source. It creates no executable task scope.
    func acceptSavedInvocation(_ owner: AssistantStore.ExactUnsentSavedInvocation) throws {
        if savedOwner === owner { try owner.validateSavedRecord(); return }
        guard !attemptedSavedHandoff, !revoked else { throw NativeExactUnsentFailure.wrongTask }
        attemptedSavedHandoff = true
        do {
            try owner.validateSavedRecord()
            guard owner.binding.anchorID == id, owner.binding.originID == originID,
                  owner.binding.originRevision == originRevision else { throw NativeExactUnsentFailure.wrongMessage }
            try validateLifetime(); try validateTechnicalIdentity(); try owner.validateSavedRecord()
            savedOwner = owner; presentationCheck = nil
        } catch { revoke(); throw error }
    }

    func validateTechnicalIdentity() throws {
        try validateProcessReference()
        let snapshot = try Self.technicalSnapshot(application: application, root: root, window: window, editor: editor,
            read: Reader(check: { try self.validateProcessReference() }))
        try snapshot.validate(original: initial, identical: { CFEqual($0, $1) })
        try validateProcessReference()
    }
    /// Application admission is a process/lifetime fence, not a window/editor
    /// survey. Strong original-source/private/input boundaries still call the
    /// complete technical identity validator; no successful verdict is cached.
    func validateApplicationIdentity() throws { try validateProcessReference() }

    /// The actual acknowledged original alone can produce this admission.
    /// Full process/canonical checks still run at every strong boundary.
    func applicationAdmission() throws -> NativeWindowTaskAdapter.ApplicationAdmission {
        .acknowledgedOriginal(try ApplicationMetadataBinding.prepare(anchor: self))
    }
    private func requireSavedMetadataOwner() throws {
        guard let savedOwner else { throw NativeExactUnsentFailure.acknowledgmentBridgeUnavailable }
        try savedOwner.requireAcknowledged(); try validateLifetime()
    }

    /// No caller validator, raw identity or inert comparison facts can construct
    /// this factory. It retains no image/editor value/privacy verdict.
    @MainActor final class ApplicationMetadataBinding {
        let application: DesktopApplicationIdentity
        private weak var anchor: NativeExactUnsentInvocationAnchor?
        private let process: DesktopApplicationTarget.MetadataProcessBinding
        private init(anchor: NativeExactUnsentInvocationAnchor, process: DesktopApplicationTarget.MetadataProcessBinding) {
            self.anchor = anchor; self.process = process; application = anchor.application
        }
        fileprivate static func prepare(anchor: NativeExactUnsentInvocationAnchor) throws -> ApplicationMetadataBinding {
            try anchor.requireSavedMetadataOwner(); try anchor.validateApplicationIdentity()
            let process = try DesktopApplicationTarget.MetadataProcessBinding.bind(identity: anchor.application, application: anchor.applicationObject)
            try anchor.validateApplicationIdentity(); try anchor.requireSavedMetadataOwner()
            return ApplicationMetadataBinding(anchor: anchor, process: process)
        }
        func validateStrong() throws {
            guard let anchor else { throw NativeExactUnsentFailure.revoked }
            try anchor.requireSavedMetadataOwner(); try anchor.validateApplicationIdentity(); try anchor.requireSavedMetadataOwner()
        }
        func withLease<Value>(_ body: @MainActor (ApplicationMetadataLease) throws -> Value) throws -> Value {
            try validateStrong()
            let result = Result {
                try process.withLease { process in
                    guard let anchor else { throw NativeExactUnsentFailure.revoked }
                    let lease = ApplicationMetadataLease(anchor: anchor, process: process)
                    defer { lease.retire() }
                    try lease.check()
                    let result = Result { try body(lease) }
                    try lease.check()
                    return try result.get()
                }
            }
            // Retire the live lease before both success/error strong exits.
            try validateStrong()
            return try result.get()
        }
    }
    @MainActor final class ApplicationMetadataLease {
        private weak var anchor: NativeExactUnsentInvocationAnchor?
        private let process: DesktopApplicationTarget.MetadataProcessLease
        private var active = true
        fileprivate init(anchor: NativeExactUnsentInvocationAnchor, process: DesktopApplicationTarget.MetadataProcessLease) {
            self.anchor = anchor; self.process = process
        }
        fileprivate func retire() { active = false; anchor = nil }
        func check(currentQuery: DesktopApplicationTarget.MetadataProcessLease.QueryWitness? = nil) throws {
            guard active else { throw NativeMetadataPhase.Failure.expired }
            guard let anchor else { throw NativeExactUnsentFailure.revoked }
            try anchor.requireSavedMetadataOwner()
            guard AXIsProcessTrusted() else { throw NativeExactUnsentFailure.changedOriginal }
            // Actual kernel start brackets two fresh raw samples of the same
            // retained NSRunningApplication, without canonical filesystem IO.
            try process.check(currentQuery: currentQuery)
            try anchor.requireSavedMetadataOwner()
            guard active else { throw NativeMetadataPhase.Failure.expired }
        }
        func checkSealedTechnical(anchor expectedAnchor: NativeExactUnsentInvocationAnchor, scope: NativeVisualTaskScope,
                                  currentQuery: DesktopApplicationTarget.MetadataProcessLease.QueryWitness) throws {
            let owner = try sealedOwner(anchor: expectedAnchor, scope: scope)
            try currentQuery.validateSavedOwner(owner)
            guard AXIsProcessTrusted() else { throw NativeExactUnsentFailure.changedOriginal }
            try process.check(currentQuery: currentQuery)
            guard active else { throw NativeMetadataPhase.Failure.expired }
        }
        func requireSealedProcess(anchor expectedAnchor: NativeExactUnsentInvocationAnchor, scope: NativeVisualTaskScope,
                                  context: AssistantStore.ExactUnsentSavedInvocation.MetadataContext,
                                  currentQuery: DesktopApplicationTarget.MetadataProcessLease.QueryWitness) throws {
            try context.requireOwner(sealedOwner(anchor: expectedAnchor, scope: scope))
            try process.check(currentQuery: currentQuery)
        }
        private func sealedOwner(anchor expectedAnchor: NativeExactUnsentInvocationAnchor,
                                 scope: NativeVisualTaskScope) throws -> AssistantStore.ExactUnsentSavedInvocation {
            guard active else { throw NativeMetadataPhase.Failure.expired }
            guard let anchor, anchor === expectedAnchor, !anchor.revoked,
                  let owner = anchor.savedOwner, anchor.claimedScope === scope else { throw NativeExactUnsentFailure.revoked }
            return owner
        }
    }

    fileprivate func claim(scope: NativeVisualTaskScope) throws {
        guard let savedOwner else { throw NativeExactUnsentFailure.acknowledgmentBridgeUnavailable }
        try savedOwner.requireScope(scope)
        try validateTechnicalIdentity(); try scope.validate()
        if let claimedScope { guard claimedScope === scope else { throw NativeExactUnsentFailure.wrongTask } }
        else { claimedScope = scope; presentationCheck = nil }
        try validateLifetime()
    }

    /// The common observer binder receives the actual retained object. No
    /// title/native ID lookup or selected-window choice can replace it.
    func withSuppliedOriginal<Value>(scope: NativeVisualTaskScope,
        readAudit: NativeReadAudit? = nil,
        body: (DesktopApplicationIdentity, NSRunningApplication, AXUIElement, @escaping @MainActor () throws -> Void) throws -> Value) throws -> Value {
        guard claimedScope === scope else { throw NativeExactUnsentFailure.wrongTask }
        try validateTechnicalIdentity()
        let result = try body(application, applicationObject, window, { try self.validateRetainedEditorIdentity(readAudit: readAudit) })
        try validateTechnicalIdentity()
        return result
    }

    /// Cheap task/revocation fence only, used by the actual binder per-query
    /// lease. Full source/editor proof remains at the strong boundaries.
    fileprivate func validateClaim(scope: NativeVisualTaskScope) throws {
        guard claimedScope === scope else { throw NativeExactUnsentFailure.wrongTask }
        try validateLifetime()
    }

    /// The cell belongs to this actual anchor, not a reconstructible Purpose.
    /// Spend before binder work; failure, another Purpose or a dead weak owner
    /// cannot free the initial-adoption opportunity.
    fileprivate func beginPreparation(scope: NativeVisualTaskScope, owner: TargetBoundNativeObservation) throws {
        try validateClaim(scope: scope)
        try preparationOwner.begin(owner: owner)
        try validateClaim(scope: scope)
    }
    fileprivate func validatePreparation(scope: NativeVisualTaskScope, owner: TargetBoundNativeObservation) throws {
        try validateClaim(scope: scope)
        try preparationOwner.validate(owner: owner)
        try validateClaim(scope: scope)
    }

    /// The query's full Store owner check is outside this identity-only edge.
    fileprivate func validateSealedPreparation(scope: NativeVisualTaskScope, owner: TargetBoundNativeObservation,
        context: AssistantStore.ExactUnsentSavedInvocation.MetadataContext) throws {
        guard !revoked, claimedScope === scope, let savedOwner else { throw NativeExactUnsentFailure.revoked }
        try context.requireOwner(savedOwner)
        try preparationOwner.validate(owner: owner)
    }

    private func validateLifetime() throws {
        try Task.checkCancellation()
        guard !revoked else { throw NativeExactUnsentFailure.revoked }
        if let claimedScope {
            guard let savedOwner else { throw NativeExactUnsentFailure.revoked }
            try savedOwner.requireScope(claimedScope); try claimedScope.validate()
        } else if let savedOwner { try savedOwner.validateSavedRecord() }
        else if let presentationCheck { try presentationCheck() }
        else { throw NativeExactUnsentFailure.revoked }
        try Task.checkCancellation()
        guard !revoked else { throw NativeExactUnsentFailure.revoked }
    }

    static let retainedRootFocusAttributes = [kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute]

    static func decodeRetainedRootFocusPair(status: AXError, values: CFTypeRef?) throws -> (window: AXUIElement, editor: AXUIElement) {
        guard status == .success, let values, CFGetTypeID(values) == CFArrayGetTypeID() else {
            throw NativeExactUnsentFailure.unavailable
        }
        let array = unsafeDowncast(values, to: CFArray.self)
        guard CFArrayGetCount(array) == retainedRootFocusAttributes.count else {
            throw NativeExactUnsentFailure.unavailable
        }
        func element(_ index: Int) throws -> AXUIElement {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else {
                throw NativeExactUnsentFailure.unavailable
            }
            let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as CFTypeRef
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw NativeExactUnsentFailure.unavailable
            }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        return (try element(0), try element(1))
    }

    private func validateRetainedEditorIdentity(readAudit: NativeReadAudit? = nil) throws {
        try NativeReadAudit.measure(readAudit, .retainedEditorIdentityValidation) {
            try validateProcessReference(readAudit: readAudit)
            let binding: DesktopApplicationTarget.MetadataProcessBinding
            if let retainedProcessBinding {
                binding = retainedProcessBinding
            } else {
                do {
                    binding = try DesktopApplicationTarget.MetadataProcessBinding.bind(
                        identity: application,
                        application: applicationObject
                    )
                } catch {
                    throw NativeExactUnsentFailure.changedOriginal
                }
                retainedProcessBinding = binding
            }
            do {
                try binding.withLease { process in
                    let read = Reader(check: {
                        try NativeReadAudit.measure(readAudit, .retainedEditorOwnerValidation) { try self.validateLifetime() }
                        let trusted = NativeReadAudit.measure(readAudit, .retainedEditorProcessValidation) { AXIsProcessTrusted() }
                        guard trusted else { throw NativeExactUnsentFailure.changedOriginal }
                        do {
                            try NativeReadAudit.measure(readAudit, .retainedEditorProcessValidation) { try process.check() }
                        } catch {
                            throw NativeExactUnsentFailure.changedOriginal
                        }
                    })
                    let pidsMatched = try NativeReadAudit.measure(readAudit, .retainedEditorPIDValidation) {
                        try read.pidsMatch(root: root, window: window, editor: editor, expected: application.processID)
                    }
                    guard pidsMatched else { throw NativeExactUnsentFailure.changedOriginal }
                    let focused = try NativeReadAudit.measure(readAudit, .retainedEditorFocusedWindowRead) {
                        try read.focusedRootPair(root)
                    }
                    guard CFEqual(focused.window, window), CFEqual(focused.editor, editor) else {
                        throw NativeExactUnsentFailure.changedOriginal
                    }
                    let editorWindow = try NativeReadAudit.measure(readAudit, .retainedEditorWindowRead) {
                        try read.element(editor, kAXWindowAttribute)
                    }
                    guard CFEqual(editorWindow, window) else { throw NativeExactUnsentFailure.changedOriginal }
                    try read.check()
                }
            } catch is DesktopApplicationTarget.MetadataProcessFailure {
                throw NativeExactUnsentFailure.changedOriginal
            }
            try validateProcessReference(readAudit: readAudit)
        }
    }

    private func validateProcessReference(readAudit: NativeReadAudit? = nil) throws {
        try NativeReadAudit.measure(readAudit, .retainedEditorOwnerValidation) { try validateLifetime() }
        let matched = NativeReadAudit.measure(readAudit, .retainedEditorProcessValidation) {
            AXIsProcessTrusted() && DesktopApplicationTarget.matches(application, application: applicationObject)
        }
        guard matched else {
            throw NativeExactUnsentFailure.changedOriginal
        }
        try NativeReadAudit.measure(readAudit, .retainedEditorOwnerValidation) { try validateLifetime() }
    }

    private static func technicalSnapshot(application: DesktopApplicationIdentity, root: AXUIElement,
        window: AXUIElement, editor: AXUIElement, read: Reader) throws -> NativeExactUnsentTechnicalSnapshot<AXUIElement> {
        var protection: [NativeExactUnsentOptionalFact<Bool>] = []
        for node in [root, window, editor] {
            protection.append(try read.optionalBool(node, "AXProtectedContent"))
            protection.append(try read.optionalBool(node, "AXContainsProtectedContent"))
        }
        return try .init(application: application, window: window, editor: editor,
            selectedWindow: read.element(root, kAXFocusedWindowAttribute), selectedEditor: read.element(root, kAXFocusedUIElementAttribute),
            editorWindow: read.element(editor, kAXWindowAttribute), windows: read.elements(root, kAXWindowsAttribute),
            rootPID: read.pid(root), windowPID: read.pid(window), editorPID: read.pid(editor),
            applicationHidden: read.requiredBool(root, kAXHiddenAttribute), minimized: read.requiredBool(window, kAXMinimizedAttribute),
            enabled: read.requiredBool(editor, kAXEnabledAttribute), windowRole: read.requiredString(window, kAXRoleAttribute),
            editorRole: read.requiredString(editor, kAXRoleAttribute), editorSubrole: read.optionalString(editor, kAXSubroleAttribute),
            modal: read.optionalBool(window, kAXModalAttribute), protection: protection)
    }

    /// Exact attribute allowlist above contains no title/label/value/range,
    /// selected text, attributed style, capture, focus or setter operation.
    @MainActor private struct Reader {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        let validate: @MainActor () throws -> Void
        private let recordFailure: (@MainActor (NativeExactUnsentCaptureDiagnostic.Read) -> Void)?
        init(check: @escaping @MainActor () throws -> Void,
             recordFailure: (@MainActor (NativeExactUnsentCaptureDiagnostic.Read) -> Void)? = nil) {
            validate = check
            self.recordFailure = recordFailure
        }
        private func record(_ check: NativeExactUnsentCaptureDiagnostic.Check, name: String?, status: AXError?) {
            recordFailure?(.init(check: check, attribute: name.flatMap(NativeExactUnsentCaptureDiagnostic.Attribute.init(rawValue:)),
                axStatus: status?.rawValue))
        }
        func check(name: String? = nil, status: AXError? = nil) throws {
            do { try Task.checkCancellation(); try validate() }
            catch { record(.source, name: name, status: status); throw error }
            guard ContinuousClock.now < deadline else {
                record(.deadline, name: name, status: status)
                throw NativeExactUnsentFailure.unavailable
            }
        }
        func raw(_ node: AXUIElement, _ name: String) throws -> (AXError, CFTypeRef?) {
            try check(name: name); AXUIElementSetMessagingTimeout(node, 0.12)
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, name as CFString, &result)
            try check(name: name, status: status)
            return (status, result)
        }
        func required(_ node: AXUIElement, _ name: String) throws -> CFTypeRef {
            let (status, value) = try raw(node, name)
            guard status == .success, let value else {
                record(.attributeResult, name: name, status: status)
                throw NativeExactUnsentFailure.unavailable
            }
            return value
        }
        func requiredBool(_ node: AXUIElement, _ name: String) throws -> Bool {
            let value = try required(node, name)
            guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw wrongType(name) }
            return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
        }
        func requiredString(_ node: AXUIElement, _ name: String) throws -> String {
            let value = try required(node, name)
            guard CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String,
                  string.utf8.count <= 512 else { throw wrongType(name) }
            return string
        }
        func element(_ node: AXUIElement, _ name: String) throws -> AXUIElement {
            let value = try required(node, name)
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw wrongType(name) }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        func elements(_ node: AXUIElement, _ name: String) throws -> [AXUIElement] {
            let value = try required(node, name)
            guard let nodes = value as? [AXUIElement], !nodes.isEmpty, nodes.count <= 64 else { throw wrongType(name) }
            return nodes
        }
        func warmWindowChildren(_ window: AXUIElement) throws {
            try check()
            AXUIElementSetMessagingTimeout(window, 0.04)
            var rawWindowChildren: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &rawWindowChildren) == .success,
                  let windowChildren = rawWindowChildren as? [AXUIElement], windowChildren.count <= 64 else {
                try check()
                return
            }
            for child in windowChildren {
                try check()
                AXUIElementSetMessagingTimeout(child, 0.04)
                var rawNested: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &rawNested) == .success,
                      let nested = rawNested as? [AXUIElement], nested.count <= 64 else { continue }
                for item in nested {
                    try check()
                    AXUIElementSetMessagingTimeout(item, 0.04)
                    var rawGrandchildren: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &rawGrandchildren)
                }
            }
            try check()
        }
        func pid(_ node: AXUIElement) throws -> Int32 {
            try check(); var pid: pid_t = 0
            let status = AXUIElementGetPid(node, &pid)
            guard status == .success else {
                record(.processIdentifier, name: nil, status: status)
                throw NativeExactUnsentFailure.unavailable
            }
            try check(status: status); return pid
        }
        func pidsMatch(root: AXUIElement, window: AXUIElement, editor: AXUIElement, expected: Int32) throws -> Bool {
            try check()
            var matched = true
            for node in [root, window, editor] {
                var pid: pid_t = 0
                let status = AXUIElementGetPid(node, &pid)
                guard status == .success else {
                    record(.processIdentifier, name: nil, status: status)
                    throw NativeExactUnsentFailure.unavailable
                }
                if pid != expected { matched = false }
            }
            try check(status: .success)
            return matched
        }
        func focusedRootPair(_ node: AXUIElement) throws -> (window: AXUIElement, editor: AXUIElement) {
            try check(name: kAXFocusedWindowAttribute)
            AXUIElementSetMessagingTimeout(node, 0.04)
            var values: CFArray?
            let status = AXUIElementCopyMultipleAttributeValues(
                node,
                NativeExactUnsentInvocationAnchor.retainedRootFocusAttributes as CFArray,
                [],
                &values
            )
            try check(name: kAXFocusedWindowAttribute, status: status)
            do {
                return try NativeExactUnsentInvocationAnchor.decodeRetainedRootFocusPair(status: status, values: values)
            } catch {
                record(.attributeResult, name: kAXFocusedWindowAttribute, status: status)
                throw error
            }
        }
        func optionalBool(_ node: AXUIElement, _ name: String) throws -> NativeExactUnsentOptionalFact<Bool> {
            let (status, value) = try raw(node, name)
            if status == .attributeUnsupported, value == nil { return .unsupported }
            if status == .noValue, value == nil { return .noValue }
            guard status == .success, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                record(.attributeResult, name: name, status: status)
                throw NativeExactUnsentFailure.unavailable
            }
            return .reported(CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)))
        }
        func optionalString(_ node: AXUIElement, _ name: String) throws -> NativeExactUnsentOptionalFact<String> {
            let (status, value) = try raw(node, name)
            if status == .attributeUnsupported, value == nil { return .unsupported }
            if status == .noValue, value == nil { return .noValue }
            guard status == .success, let value, CFGetTypeID(value) == CFStringGetTypeID(),
                  let string = value as? String, string.utf8.count <= 512 else {
                record(.attributeResult, name: name, status: status)
                throw NativeExactUnsentFailure.unavailable
            }
            return .reported(string)
        }
        private func wrongType(_ name: String) -> NativeExactUnsentFailure {
            record(.attributeType, name: name, status: .success)
            return .unavailable
        }
    }
}

/// Sealed ACK data. There is deliberately NO token constructor or caller-
/// supplied saved-message validator API in this infrastructure-only slice.
@MainActor final class NativeExactUnsentAcknowledgment {
    let binding: NativeExactUnsentMessageBinding
    private let owner: AssistantStore.ExactUnsentSavedInvocation
    private init(owner: AssistantStore.ExactUnsentSavedInvocation) {
        self.owner = owner; binding = owner.binding
    }
    static func bindSavedMessage(_ owner: AssistantStore.ExactUnsentSavedInvocation) throws -> NativeExactUnsentAcknowledgment {
        try owner.validateSavedRecord()
        return NativeExactUnsentAcknowledgment(owner: owner)
    }
    static func bindSavedMessage(_ ticket: ConversationSubmission, run: AssistantConversationHistory.Run) throws -> NativeExactUnsentAcknowledgment {
        // A delivery ticket, even `.saved`, is not the actual journal receipt.
        // A later reviewed Store/History hunk must supply that real bridge.
        throw NativeExactUnsentFailure.acknowledgmentBridgeUnavailable
    }
    fileprivate func validate(scope: NativeVisualTaskScope) throws {
        try scope.validate(); try owner.requireAcknowledged(); try owner.requireScope(scope)
        try requireScopeBinding(scope)
        try scope.validate()
    }
    private func requireScopeBinding(_ scope: NativeVisualTaskScope) throws {
        guard binding.logicalTaskID == scope.logicalTaskID, binding.runID == scope.run.taskID,
              binding.attemptID == scope.run.attemptID,
              binding.exactRequestUTF8 == Data(scope.originalObjective.utf8) else { throw NativeExactUnsentFailure.wrongTask }
    }
    fileprivate func validateSealedBinding(scope: NativeVisualTaskScope,
        context: AssistantStore.ExactUnsentSavedInvocation.MetadataContext) throws {
        try context.requireOwner(owner)
        try requireScopeBinding(scope)
    }
    fileprivate func requireOriginalFocusApproval(scope: NativeVisualTaskScope) throws {
        try validate(scope: scope)
        try owner.requireDisclosedOriginalFocus()
    }
}

@MainActor final class NativeAcknowledgedExactUnsentObjective {
    let id = UUID()
    let literal: String
    let anchor: NativeExactUnsentInvocationAnchor
    private let acknowledgment: NativeExactUnsentAcknowledgment
    init(literal: String, anchor: NativeExactUnsentInvocationAnchor, acknowledgment: NativeExactUnsentAcknowledgment) throws {
        try Self.requireLiteral(literal)
        guard acknowledgment.binding.anchorID == anchor.id, acknowledgment.binding.originID == anchor.originID,
              acknowledgment.binding.originRevision == anchor.originRevision,
              acknowledgment.binding.literalUTF8 == Data(literal.utf8) else { throw NativeExactUnsentFailure.wrongMessage }
        self.literal = literal; self.anchor = anchor; self.acknowledgment = acknowledgment
    }
    static func requireLiteral(_ literal: String) throws {
        guard NativeControlSession.validUnsentText(literal) else { throw NativeExactUnsentFailure.invalidLiteral }
    }
    func validate(scope: NativeVisualTaskScope) throws {
        try acknowledgment.validate(scope: scope); try anchor.validateTechnicalIdentity(); try acknowledgment.validate(scope: scope)
    }
    fileprivate func requireOriginalFocusApproval(scope: NativeVisualTaskScope) throws {
        try acknowledgment.requireOriginalFocusApproval(scope: scope)
    }
    fileprivate func validateAcknowledgmentMetadata(scope: NativeVisualTaskScope) throws {
        try acknowledgment.validate(scope: scope)
    }
    fileprivate func validateSealedAcknowledgment(scope: NativeVisualTaskScope,
        context: AssistantStore.ExactUnsentSavedInvocation.MetadataContext) throws {
        try acknowledgment.validateSealedBinding(scope: scope, context: context)
    }
}

/// Distinct initial adoption; never a transferable old-owner input permission.
/// This type cannot be obtained while the real ACK bridge remains unavailable.
@MainActor final class NativeExactUnsentPurpose {
    let objective: NativeAcknowledgedExactUnsentObjective
    private let scope: NativeVisualTaskScope
    private let readAdmission: NativeWindowTaskAdapter.ApplicationAdmission
    var hasSealedMetadataApplicationAdmission: Bool { readAdmission.hasSealedMetadataApplicationAdmission }
    init(objective: NativeAcknowledgedExactUnsentObjective, scope: NativeVisualTaskScope,
         existingInputAuthority: NativeLocalTaskInputAuthority) throws {
        guard existingInputAuthority.scope === scope, case .appScoped = existingInputAuthority.windowRequirement else {
            throw NativeExactUnsentFailure.wrongTask
        }
        try existingInputAuthority.validate()
        let read = try scope.admitRead(objective.anchor.application.bundleID)
        guard read.application == objective.anchor.application else { throw NativeExactUnsentFailure.changedOriginal }
        try read.validate(); try objective.validate(scope: scope)
        try objective.anchor.claim(scope: scope)
        self.objective = objective; self.scope = scope; readAdmission = read
        try validateCurrent(scope: scope)
    }
    func validateCurrent(scope candidate: NativeVisualTaskScope) throws {
        guard candidate === scope else { throw NativeExactUnsentFailure.wrongTask }
        try scope.validate(); try objective.acknowledgmentForPurpose(scope: scope)
        try readAdmission.validate(); try objective.anchor.validateClaim(scope: scope); try scope.validate()
    }

    /// No process resolution or AX here. This is not a source/privacy/input
    /// admission: the query's actual live ApplicationAdmission/reference and
    /// the full strong boundaries remain separate and mandatory.
    func validateMetadataOwner(scope candidate: NativeVisualTaskScope) throws {
        guard candidate === scope else { throw NativeExactUnsentFailure.wrongTask }
        try scope.validate(); try objective.validateAcknowledgmentMetadata(scope: scope)
        try objective.anchor.validateClaim(scope: scope); try scope.validate()
    }
    func requireOriginalFocusApproval(scope candidate: NativeVisualTaskScope) throws {
        try validateCurrent(scope: candidate)
        try objective.requireOriginalFocusApproval(scope: candidate)
        try validateCurrent(scope: candidate)
    }

    /// Final known-revocation fence only. No AX/readAdmission/source IO here;
    /// the actual readonly goal target performs the last SDK check separately.
    func validateAcknowledgmentMetadata(scope candidate: NativeVisualTaskScope) throws {
        guard candidate === scope else { throw NativeExactUnsentFailure.wrongTask }
        try candidate.validate()
        try objective.validateAcknowledgmentMetadata(scope: candidate)
        try candidate.validate()
    }
    func withSuppliedOriginal<Value>(owner: TargetBoundNativeObservation,
        readAudit: NativeReadAudit? = nil,
        body: (DesktopApplicationIdentity, NSRunningApplication, AXUIElement,
        @escaping @MainActor () throws -> Void) throws -> Value) throws -> Value {
        try validateCurrent(scope: scope)
        try objective.anchor.beginPreparation(scope: scope, owner: owner)
        let value = try objective.anchor.withSuppliedOriginal(scope: scope, readAudit: readAudit, body: body)
        try validateCurrentForPreparedSource(owner: owner); return value
    }
    func validateApplication(_ identity: DesktopApplicationIdentity) throws {
        try validateCurrent(scope: scope)
        guard identity == objective.anchor.application else { throw NativeExactUnsentFailure.changedOriginal }
    }
    func validateCurrentForPreparedSource(owner: TargetBoundNativeObservation) throws {
        try objective.anchor.validatePreparation(scope: scope, owner: owner); try validateCurrent(scope: scope)
    }
    /// Actual prepared-observer identity and known task/ACK/claim lifetime only.
    /// The binder repeats this inside its technical metadata query bracket;
    /// actual process/reference/admission checks and all strong source/private
    /// boundaries remain separate and are not replaced by this method.
    func validateMetadataOwnerForPreparedSource(owner: TargetBoundNativeObservation) throws {
        try objective.anchor.validatePreparation(scope: scope, owner: owner)
        try validateMetadataOwner(scope: scope)
        try objective.anchor.validatePreparation(scope: scope, owner: owner)
    }
    func validateSealedMetadataPreparation(scope candidate: NativeVisualTaskScope, owner: TargetBoundNativeObservation,
        context: AssistantStore.ExactUnsentSavedInvocation.MetadataContext) throws {
        guard candidate === scope else { throw NativeExactUnsentFailure.wrongTask }
        try objective.validateSealedAcknowledgment(scope: scope, context: context)
        try objective.anchor.validateSealedPreparation(scope: scope, owner: owner, context: context)
    }
}

private extension NativeAcknowledgedExactUnsentObjective {
    func acknowledgmentForPurpose(scope: NativeVisualTaskScope) throws { try acknowledgment.validate(scope: scope) }
}
