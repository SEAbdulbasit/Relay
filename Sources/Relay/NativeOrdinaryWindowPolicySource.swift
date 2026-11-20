import AppKit
import ApplicationServices
import CryptoKit
import Foundation

/// Metadata from the actual retained source, never a model description. This
/// reader has no value/selection/style, capture, activation or input operation.
@MainActor enum NativeOrdinaryWindowPolicySource {
    enum Failure: LocalizedError, Equatable {
        case unavailable, incomplete, protectedContext, dedicatedContext, changedContext
        var errorDescription: String? {
            switch self {
            case .unavailable: "The original window's policy metadata is unavailable. No private editor planning or input was admitted."
            case .incomplete: "The original window's bounded policy inspection was incomplete. Use a fresh supported source."
            case .protectedContext: "The original source contains a protected or security interaction. Complete it directly."
            case .dedicatedContext: "This context requires its dedicated consequential workflow. Ordinary visual input cannot bypass it."
            case .changedContext: "The original window's policy context changed. Discard this plan and inspect the retained source again."
            }
        }
    }
    enum Dedicated: String, Hashable, Sendable {
        case attachment, submission, publishing, destructive, financial, authentication, shell
    }
    enum Context: Equatable {
        case ordinary
        case modalReviewRequired
        case dedicated(Dedicated)
        case protected
    }
    enum MissingEvidence: String, Hashable {
        case privacyFlags, modalFlag, containerChildren
    }
    enum Coverage: Equatable {
        case complete
        /// Actual reader-minted supported-role disclosure, with optional flags
        /// retained as unreported rather than fabricated false values.
        case standardRoleSurvey
        case incomplete(Set<MissingEvidence>)
    }
    struct Facts: Equatable {
        let sourceID: UUID
        let application: DesktopApplicationIdentity
        let context: Context
        let coverage: Coverage
        /// A set of unrelated controls is not proof that the focused editor
        /// has that effect. It also cannot positively identify a pointer hit.
        let visibleDedicatedControls: Set<Dedicated>
        let visitedNodes: Int
        let digest: Data
        var standardSurvey: NativeStandardControlSurvey? = nil

        /// Current ordinary-window metadata only; no focused editor, input
        /// grant or old field-value fingerprint is required by this read gate.
        func admitControlReadCapture() throws {
            switch coverage {
            case .complete: break // legacy explicit-positive metadata path
            case .standardRoleSurvey:
                guard let standardSurvey, standardSurvey.sourceID == sourceID,
                      standardSurvey.application == application else { throw Failure.incomplete }
                try standardSurvey.validate()
            case .incomplete: throw Failure.incomplete
            }
            switch context {
            case .ordinary: return
            case .protected: throw Failure.protectedContext
            case .dedicated: throw Failure.dedicatedContext
            case .modalReviewRequired: throw Failure.unavailable
            }
        }
        func admitPrivateEditorPlanning() throws { try admitControlReadCapture() }
    }
    struct Metadata: Equatable {
        let role: String
        let subrole: String
        let protectedContent: Bool?
        let hidden: Bool?
        let modal: Bool?
        let minimized: Bool?
    }
    struct Labels {
        let title: String?
        let description: String?
        let identifier: String?
    }
    enum Children<Node> {
        case reported([Node])
        /// Positive AX leaf role plus precisely attributeUnsupported, never
        /// an arbitrary container/error silently treated as an empty tree.
        case knownLeaf
        case unavailable
    }
    struct Access<Node> {
        let root: Node
        let identical: @MainActor (Node, Node) -> Bool
        /// Task/privacy and retained original source are checked before and
        /// after every OS query, including the metadata-only first pass.
        let validate: @MainActor () throws -> Void
        let metadata: @MainActor (Node) throws -> Metadata
        let children: @MainActor (Node) throws -> Children<Node>
        let labels: @MainActor (Node) throws -> Labels
    }

    static func inspect<Node>(sourceID: UUID, application: DesktopApplicationIdentity,
                              access: Access<Node>, maximumNodes: Int = 512,
                              budget: Duration = .milliseconds(750),
                              now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) throws -> Facts {
        let limit = min(max(maximumNodes, 1), 2_048)
        let deadline = now().advanced(by: budget)
        func check() throws {
            try Task.checkCancellation()
            guard now() < deadline else { throw Failure.incomplete }
            try access.validate()
            try Task.checkCancellation()
            guard now() < deadline else { throw Failure.incomplete }
        }
        try check()
        if let boundary = applicationBoundary(application.bundleID) {
            return makeFacts(sourceID, application, boundary, .complete, [], 0, [])
        }
        var pending = [access.root], visited: [Node] = []
        var rows: [(node: Node, metadata: Metadata)] = []
        var context: Context = .ordinary
        var missing: Set<MissingEvidence> = []
        // This complete metadata pass happens before *any* labels. A later
        // secure descendant cannot be used to justify earlier source labels.
        while !pending.isEmpty {
            try check()
            let node = pending.removeLast()
            if visited.contains(where: { access.identical($0, node) }) { continue }
            guard visited.count < limit else { throw Failure.incomplete }
            let metadata = try access.metadata(node); try check()
            guard !metadata.role.isEmpty, metadata.role.utf8.count <= 128,
                  metadata.subrole.utf8.count <= 128 else { throw Failure.incomplete }
            if visited.isEmpty {
                guard metadata.role == "AXWindow", metadata.minimized == false,
                      metadata.hidden != true else { throw Failure.unavailable }
            }
            visited.append(node)
            if metadata.hidden == true { continue }
            if metadata.protectedContent == nil || metadata.hidden == nil { missing.insert(.privacyFlags) }
            if metadata.modal == nil && (metadata.role == "AXWindow" || metadata.role == "AXSheet" || metadata.role == "AXDialog") { missing.insert(.modalFlag) }
            if isSecure(metadata) {
                return makeFacts(sourceID, application, .protected, .complete, [], visited.count, [])
            }
            rows.append((node, metadata))
            if isModal(metadata) { context = .modalReviewRequired }
            let childScope = try access.children(node); try check()
            let children: [Node]
            switch childScope {
            case .reported(let reported): children = reported
            case .knownLeaf: children = []
            case .unavailable: missing.insert(.containerChildren); children = []
            }
            guard children.count <= limit, pending.count <= limit - children.count else { throw Failure.incomplete }
            pending.append(contentsOf: children)
        }
        var boundaries: Set<Dedicated> = [], fingerprint: [String] = []
        for row in rows {
            try check()
            fingerprint.append([row.metadata.role, row.metadata.subrole,
                String(describing: row.metadata.modal), String(describing: row.metadata.protectedContent)].joined(separator: ":"))
            // Editable values, editor labels, ordinary document text and static
            // text are deliberately not requested by this metadata inspector.
            guard isModal(row.metadata) || ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(row.metadata.role) else { continue }
            let currentMetadata = try access.metadata(row.node); try check()
            guard currentMetadata == row.metadata, !isSecure(currentMetadata), currentMetadata.hidden != true else { throw Failure.changedContext }
            guard currentMetadata.protectedContent == false, currentMetadata.hidden == false else {
                missing.insert(.privacyFlags)
                continue
            }
            let labels = try access.labels(row.node); try check()
            let parts = [labels.title, labels.description, labels.identifier].compactMap { $0 }
            guard parts.allSatisfy({ $0.utf8.count <= 512 }), parts.reduce(0, { $0 + $1.utf8.count }) <= 1_024 else { throw Failure.incomplete }
            let label = parts.joined(separator: " ")
            // Labels are untrusted OS/source data. They may only narrow or
            // refuse authority; no spelling grants an ordinary action.
            if isSensitive(label) {
                return makeFacts(sourceID, application, .protected, .complete, boundaries, visited.count, fingerprint)
            }
            if let boundary = dedicated(label) {
                boundaries.insert(boundary)
                if isModal(row.metadata) { context = .dedicated(boundary) }
            }
            fingerprint.append(label)
        }
        if case .modalReviewRequired = context,
           let boundary = boundaries.sorted(by: { $0.rawValue < $1.rawValue }).first {
            context = .dedicated(boundary)
        }
        try check()
        let coverage: Coverage = missing.isEmpty ? .complete : .incomplete(missing)
        return makeFacts(sourceID, application, context, coverage, boundaries, visited.count, fingerprint)
    }

    private static func makeFacts(_ source: UUID, _ application: DesktopApplicationIdentity,
                                  _ context: Context, _ coverage: Coverage, _ boundaries: Set<Dedicated>,
                                  _ visited: Int, _ parts: [String]) -> Facts {
        var framed = Data("relay.native.window-policy.v1".utf8)
        for value in [source.uuidString, String(application.processID),
                      application.bundleID, String(describing: context), coverageDescription(coverage)] + parts {
            let bytes = Data(value.utf8); var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }; framed.append(bytes)
        }
        return Facts(sourceID: source, application: application, context: context, coverage: coverage,
            visibleDedicatedControls: boundaries, visitedNodes: visited,
            digest: Data(SHA256.hash(data: framed)))
    }
    private static func coverageDescription(_ coverage: Coverage) -> String {
        switch coverage {
        case .complete: "complete"
        case .standardRoleSurvey: "supported-standard-role-survey"
        case .incomplete(let missing): "incomplete:" + missing.map(\.rawValue).sorted().joined(separator: ",")
        }
    }
    static func childScope<Node>(role: String, status: AXError, value: [Node]?) throws -> Children<Node> {
        if status == .success {
            guard let value else { throw Failure.incomplete }
            return .reported(value)
        }
        let leaves: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXStaticText", "AXImage", "AXScrollBar"]
        if status == .attributeUnsupported, leaves.contains(role) { return .knownLeaf }
        return .unavailable
    }
    static func applicationBoundary(_ bundle: String) -> Context? {
        // Existing protected workflows, not an ordinary-app allowlist.
        let security: Set<String> = ["com.apple.systempreferences", "com.apple.securityagent", "com.apple.tccui",
            "com.apple.loginwindow", "com.apple.coreservicesuiagent", "com.apple.passwords", "com.apple.keychainaccess",
            "com.1password.1password", "com.bitwarden.desktop"]
        if security.contains(bundle.lowercased()) { return .protected }
        if ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable"].contains(bundle.lowercased()) { return .dedicated(.shell) }
        return nil
    }
    private static func isSecure(_ metadata: Metadata) -> Bool {
        let spelling = (metadata.role + " " + metadata.subrole).lowercased()
        return metadata.protectedContent == true || spelling.contains("secure") || spelling.contains("password")
    }
    private static func isModal(_ metadata: Metadata) -> Bool {
        metadata.modal == true || metadata.role == "AXSheet" || metadata.role == "AXDialog"
            || metadata.subrole == "AXDialog" || metadata.subrole == "AXSystemDialog"
    }
    static func isSensitive(_ label: String) -> Bool {
        let lower = label.lowercased()
        return ["grant access", "revoke access", "privacy & security", "permission", "authenticate", "password",
                "passcode", "security code", "recovery phrase", "secret key", "two-factor", "2-factor"].contains(where: lower.contains)
    }
    static func dedicated(_ label: String) -> Dedicated? {
        let words = Set(label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !words.isDisjoint(with: ["send", "submit"]) { return .submission }
        if !words.isDisjoint(with: ["publish", "post"]) { return .publishing }
        if !words.isDisjoint(with: ["delete", "erase", "uninstall"]) { return .destructive }
        if !words.isDisjoint(with: ["pay", "buy", "purchase", "checkout", "payment", "transfer"]) { return .financial }
        if !words.isDisjoint(with: ["attach", "upload"]) { return .attachment }
        return nil
    }
}

/// Constructed only by the controller's actual retained-window binder. This is
/// a source capability; metadata inspection never focuses/captures/edits it.
@MainActor final class NativeOriginalPolicyTarget {
    let sourceID: UUID
    let application: DesktopApplicationIdentity
    private let originalWindow: AXUIElement
    private let validateOriginalSource: @MainActor () throws -> Void
    private let metadataBinding: TargetBoundNativeObservation.MetadataBinding?
    private let canonicalDirectBinding: TargetBoundNativeObservation.MetadataBinding?
    private var additionalMetadataScopeValidation: (@MainActor () throws -> Void)?
    let readAudit: NativeReadAudit?

    init(sourceID: UUID, application: DesktopApplicationIdentity, originalWindow: AXUIElement,
         validateOriginalSource: @escaping @MainActor () throws -> Void, readAudit: NativeReadAudit? = nil,
         metadataBinding: TargetBoundNativeObservation.MetadataBinding? = nil) {
        self.sourceID = sourceID; self.application = application; self.originalWindow = originalWindow
        self.validateOriginalSource = validateOriginalSource; self.readAudit = readAudit
        self.metadataBinding = metadataBinding
        canonicalDirectBinding = nil
    }

    init(directSource: TargetBoundNativeObservation.MetadataBinding.CanonicalDirectPolicySource,
         readAudit: NativeReadAudit?) {
        sourceID = directSource.sourceID
        application = directSource.application
        originalWindow = directSource.window
        validateOriginalSource = { try directSource.validate() }
        metadataBinding = directSource.binding
        canonicalDirectBinding = directSource.binding
        self.readAudit = readAudit
    }

    func usesCanonicalDirectSource(_ binding: TargetBoundNativeObservation.MetadataBinding) -> Bool {
        canonicalDirectBinding === binding
    }

    func validateSource() throws {
        try Task.checkCancellation()
        try NativeReadAudit.measure(readAudit, .policySourceValidation) { try validateOriginalSource() }
        try Task.checkCancellation()
    }

    func addingSourceValidation(_ check: @escaping @MainActor () throws -> Void,
                                metadataLeaseValidation: (@MainActor () throws -> Void)? = nil) -> NativeOriginalPolicyTarget {
        let target = NativeOriginalPolicyTarget(sourceID: sourceID, application: application, originalWindow: originalWindow,
            validateOriginalSource: { try check(); try self.validateSource(); try check() }, readAudit: readAudit,
            metadataBinding: metadataBinding)
        target.additionalMetadataScopeValidation = {
            try self.additionalMetadataScopeValidation?()
            // Existing callers without a separate cheap ownership fence keep
            // their full original check at every metadata query.
            try (metadataLeaseValidation ?? check)()
        }
        return target
    }

    func inspectMetadata(authorizeMetadata: @escaping @MainActor () throws -> Void,
                         metadataScope: NativeMetadataScopeBinding? = nil) throws -> NativeOrdinaryWindowPolicySource.Facts {
        try NativeReadAudit.inspectPolicy(readAudit) {
            try makeStandardSurvey(authorizeMetadata: authorizeMetadata, useBoundMetadataPhase: true,
                metadataScope: metadataScope).policyFacts()
        }
    }

    /// Used only to bind the actual observer's scoped copy before any phase.
    /// This performs no SDK read and transfers no private-query authority.
    func matchesMetadataWindow(_ window: AXUIElement) -> Bool { CFEqual(originalWindow, window) }
    func validateAdditionalMetadataScope() throws { try additionalMetadataScopeValidation?() }

    /// Actual-window identity only, for the task's one-use acquisition owner.
    /// It transfers no old survey, input permission or private field preview.
    func sharesOriginalWindow(with other: NativeOriginalPolicyTarget) -> Bool {
        application == other.application && CFEqual(originalWindow, other.originalWindow)
    }

    /// First control metadata admission only. Existing standardSurvey, strict
    /// inspectMetadata and every later private/capture/input fence are unchanged.
    func inspectInitialMetadata(using acquisition: NativeInitialMetadataAcquisition,
        validateInitialOwnership: @escaping @MainActor () throws -> Void,
        authorizeMetadata: @escaping @MainActor () throws -> Void,
        metadataScope: NativeMetadataScopeBinding? = nil) throws -> NativeOrdinaryWindowPolicySource.Facts {
        try NativeReadAudit.inspectPolicy(readAudit) {
            let strong = metadataValidation(authorizeScope: authorizeMetadata)
            let survey: NativeStandardControlSurvey
            do {
                survey = try acquisition.acquire(validate: {
                    try validateInitialOwnership(); try strong(); try validateInitialOwnership()
                }, capture: {
                    try self.makeStandardSurvey(authorizeMetadata: authorizeMetadata, useBoundMetadataPhase: true,
                        metadataScope: metadataScope)
                }, compare: { try $0.initialComparison(to: $1) })
            } catch is NativeInitialMetadataAcquisition.Failure {
                throw NativeOrdinaryWindowPolicySource.Failure.changedContext
            }
            metadataScope?.markInitialMetadataSettled()
            // The acquisition is already spent. These existing strict checks
            // and each private query can refuse; none can start another loop.
            return try survey.policyFacts()
        }
    }

    /// Strong source authorization. Legacy metadata readers and ALL private
    /// disclosure paths retain this fence; it is not replaced by a phase lease.
    func metadataValidation(authorizeScope: @escaping @MainActor () throws -> Void) -> @MainActor () throws -> Void {
        { try self.validateSource(); try authorizeScope(); try self.validateSource() }
    }

    /// A metadata-only actual-reader capability. No model fields or diagnostic
    /// flags can manufacture the supported-standard disclosure basis.
    func standardSurvey(authorizeMetadata: @escaping @MainActor () throws -> Void,
                        ordinaryFocus: Bool = false) throws -> NativeStandardControlSurvey {
        // Proofread/focus/selection callers may supply a full source callback.
        // Preserve their original strong per-query contract unchanged.
        if let canonicalDirectBinding, additionalMetadataScopeValidation == nil,
           let scope = canonicalDirectBinding.canonicalMetadataScope() {
            return try makeStandardSurvey(authorizeMetadata: authorizeMetadata, useBoundMetadataPhase: true,
                metadataScope: scope)
        }
        // This focused reader supplies the exact retained source as its
        // per-query authorization. The bound phase also keeps live process
        // and window fences around each metadata request.
        return try makeStandardSurvey(authorizeMetadata: authorizeMetadata, useBoundMetadataPhase: ordinaryFocus,
            inspectionBudget: ordinaryFocus ? .milliseconds(2_500) : nil)
    }

    private func makeStandardSurvey(authorizeMetadata: @escaping @MainActor () throws -> Void,
                                    useBoundMetadataPhase: Bool,
                                    metadataScope: NativeMetadataScopeBinding? = nil,
                                    inspectionBudget: Duration? = nil) throws -> NativeStandardControlSurvey {
        let validate = metadataValidation(authorizeScope: authorizeMetadata)
        if let metadataScope, metadataScope.application != application { throw NativeVisualTaskFailure.staleTask }
        let binding: TargetBoundNativeObservation.MetadataBinding?
        if useBoundMetadataPhase, let metadataBinding, let metadataScope {
            binding = try metadataBinding.scoped(to: self, scope: metadataScope)
        } else { binding = useBoundMetadataPhase ? metadataBinding : nil }
        if binding == nil { try validate() }
        return try NativeStandardControlSurvey.capture(sourceID: sourceID, application: application,
            window: originalWindow, validateSource: validate, readAudit: readAudit,
            metadataBinding: binding, authorizeMetadataScope: {
                try self.additionalMetadataScopeValidation?(); try authorizeMetadata()
            }, inspectionBudget: inspectionBudget)
    }
}
