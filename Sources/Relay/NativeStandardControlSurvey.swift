import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

/// Supported OS disclosure, not a claim that optional privacy flags are false.
/// Only the actual retained-window reader can mint this non-Codable capability.
/// No field value, selection, style, image, activation or input is read here.
@MainActor final class NativeStandardControlSurvey: Equatable {
    nonisolated enum OptionalFlag: Equatable, Sendable {
        case reported(Bool)
        case unreported // exactly unadvertised + attributeUnsupported
        var value: Bool? { if case .reported(let value) = self { value } else { nil } }
    }
    private struct Row {
        let node: AXUIElement
        let role: String, subrole: String
        let protected: OptionalFlag, hidden: OptionalFlag
        let protectionFlags: [OptionalFlag]
        let children: [AXUIElement]
    }
    nonisolated let sourceID: UUID
    nonisolated let application: DesktopApplicationIdentity
    nonisolated let digest: Data
    private let window: AXUIElement
    private let validateSource: @MainActor () throws -> Void
    private let metadataBinding: TargetBoundNativeObservation.MetadataBinding?
    private let authorizeMetadataScope: @MainActor () throws -> Void
    private let rows: [Row]
    private let visibilityBasis: String
    private let applicationProtection: [OptionalFlag]
    private let readAudit: NativeReadAudit?
    private let inspectionBudget: Duration

    private static func metadataBudget(_ binding: TargetBoundNativeObservation.MetadataBinding?) -> Duration {
        // Give cross-process metadata scans sufficient headroom for real AppKit,
        // SwiftUI, WebKit, and Chromium lazy AX materialization and scheduling jitter.
        binding?.usesCanonicalDirectBoundary == false ? .milliseconds(2_500) : .milliseconds(2_500)
    }
    nonisolated static func == (lhs: NativeStandardControlSurvey, rhs: NativeStandardControlSurvey) -> Bool {
        // Diagnostic snapshot equality only. Actual validation compares live
        // retained CF objects and source ownership; a digest never binds a target.
        lhs.sourceID == rhs.sourceID && lhs.application == rhs.application && lhs.digest == rhs.digest
    }
    private init(sourceID: UUID, application: DesktopApplicationIdentity, window: AXUIElement,
                 validateSource: @escaping @MainActor () throws -> Void, rows: [Row],
                 visibilityBasis: String, applicationProtection: [OptionalFlag],
                 digest: Data, readAudit: NativeReadAudit?,
                 metadataBinding: TargetBoundNativeObservation.MetadataBinding?,
                 authorizeMetadataScope: @escaping @MainActor () throws -> Void,
                 inspectionBudget: Duration) {
        self.sourceID = sourceID; self.application = application; self.window = window
        self.validateSource = validateSource; self.rows = rows
        self.visibilityBasis = visibilityBasis
        self.applicationProtection = applicationProtection
        self.digest = digest; self.readAudit = readAudit
        self.metadataBinding = metadataBinding; self.authorizeMetadataScope = authorizeMetadataScope
        self.inspectionBudget = inspectionBudget
    }

    static func capture(sourceID: UUID, application: DesktopApplicationIdentity, window: AXUIElement,
                        validateSource: @escaping @MainActor () throws -> Void,
                        readAudit: NativeReadAudit? = nil,
                        diagnosticPhase: NativeReadAudit.MetadataPhase = .initialCapture,
                        metadataBinding: TargetBoundNativeObservation.MetadataBinding? = nil,
                        authorizeMetadataScope: @escaping @MainActor () throws -> Void,
                        inspectionBudget: Duration? = nil) throws -> NativeStandardControlSurvey {
        try capture(sourceID: sourceID, application: application, window: window, validateSource: validateSource,
            readAudit: readAudit, diagnosticPhase: diagnosticPhase, metadataBinding: metadataBinding,
            authorizeMetadataScope: authorizeMetadataScope, inspectionBudget: inspectionBudget, notAfter: nil) { _, _ in }
    }

    private static func capture(sourceID: UUID, application: DesktopApplicationIdentity, window: AXUIElement,
                        validateSource: @escaping @MainActor () throws -> Void, readAudit: NativeReadAudit?,
                        diagnosticPhase: NativeReadAudit.MetadataPhase,
                        metadataBinding: TargetBoundNativeObservation.MetadataBinding?,
                        authorizeMetadataScope: @escaping @MainActor () throws -> Void,
                        inspectionBudget: Duration? = nil,
                        notAfter: ContinuousClock.Instant?,
                        inspectCaptured: @MainActor (NativeStandardControlSurvey, Reader) throws -> Void) throws -> NativeStandardControlSurvey {
        let started = ContinuousClock.now
        defer { readAudit?.record(.policySurvey, since: started) }
        let budget = inspectionBudget ?? metadataBudget(metadataBinding)
        let surveyDeadline = ContinuousClock.now.advanced(by: budget)
        let deadline = min(surveyDeadline, notAfter ?? surveyDeadline)
        return try withMetadataPhase(sourceID: sourceID, application: application, window: window,
            deadline: deadline, validateSource: validateSource, metadataBinding: metadataBinding,
            authorizeMetadataScope: authorizeMetadataScope, readAudit: readAudit) { validateMetadata in
            let io = Reader(application: application, window: window, deadline: deadline, validate: validateMetadata, readAudit: readAudit, diagnosticPhase: diagnosticPhase)
            try io.check()
            if let boundary = NativeOrdinaryWindowPolicySource.applicationBoundary(application.bundleID) {
                if case .protected = boundary { throw NativeOrdinaryWindowPolicySource.Failure.protectedContext }
                throw NativeOrdinaryWindowPolicySource.Failure.dedicatedContext
            }
            let root = AXUIElementCreateApplication(application.processID)
            let applicationNames = try io.names(root)
            let appHidden = try io.flag(root, "AXHidden", names: applicationNames)
            let applicationProtection = try io.protectionFlags(root, names: applicationNames)
            try Self.admitApplicationProtection(applicationProtection)
            guard let running = NSRunningApplication(processIdentifier: application.processID),
                  DesktopApplicationTarget.matches(application, application: running), !running.isHidden else {
                throw NativeOrdinaryWindowPolicySource.Failure.unavailable
            }
            let visibility: String
            switch appHidden {
            case .reported(false): visibility = "application-AXHidden=false"
            case .reported(true): throw NativeOrdinaryWindowPolicySource.Failure.unavailable
            case .unreported: visibility = "application-AXHidden=unreported;exact-process-isHidden=false"
            }
            let actualWindows = try io.elements(root, kAXWindowsAttribute)
            guard actualWindows.filter({ CFEqual($0, window) }).count == 1 else {
                throw NativeOrdinaryWindowPolicySource.Failure.unavailable
            }
            let windowNames = try io.names(window)
            let minimized = try io.requiredBool(window, kAXMinimizedAttribute, names: windowNames)
            guard !minimized, try !io.requiredBool(window, kAXModalAttribute, names: windowNames) else {
                throw NativeOrdinaryWindowPolicySource.Failure.unavailable
            }
            let frame = try io.frame(window)
            guard Self.intersectsDisplay(frame) else { throw NativeOrdinaryWindowPolicySource.Failure.unavailable }
            io.cache.markWindowVerified(window)
            var pending = [window], rows: [Row] = []
            while let node = pending.popLast() {
                if rows.contains(where: { CFEqual($0.node, node) }) {
                    try io.check()
                    continue
                }
                guard rows.count < 2_048, pending.count < 2_048 else {
                    try io.check()
                    throw incomplete(.nodeBound, phase: diagnosticPhase, readAudit: readAudit)
                }
                let names = try io.names(node)
                let metadata = try io.rowMetadata(node, names: names)
                let role = metadata.role, subrole = metadata.subrole
                let protectionFlags = metadata.protectionFlags
                let protection = Self.aggregateProtection(protectionFlags), hidden = metadata.hidden
                if CFEqual(node, window), hidden == .reported(true) { throw NativeOrdinaryWindowPolicySource.Failure.unavailable }
                if Self.secure(role: role, subrole: subrole) || protection == .reported(true) {
                    throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
                }
                guard Self.supportedRoles.contains(role),
                      !["AXDialog", "AXSystemDialog"].contains(subrole) else {
                    throw incomplete(.unsupportedRoleOrSubrole, phase: diagnosticPhase, role: role, readAudit: readAudit)
                }
                if ["AXSheet", "AXDialog"].contains(role) { throw NativeOrdinaryWindowPolicySource.Failure.unavailable }
                if names.contains(kAXModalAttribute), try io.requiredBool(node, kAXModalAttribute, names: names, diagnosticRole: role) {
                    throw NativeOrdinaryWindowPolicySource.Failure.unavailable
                }
                if !CFEqual(node, window) {
                    try io.verifyScannedChildWindowMembership(node, names: names, role: role)
                }
                let children = try io.children(node, role: role, advertised: names.contains(kAXChildrenAttribute))
                guard children.count <= 2_048, pending.count <= 2_048 - children.count else {
                    throw incomplete(.pendingChildrenBound, phase: diagnosticPhase,
                        attribute: .childrenOrQualifiedTerminal, role: role, readAudit: readAudit)
                }
                for child in children {
                    io.cache.markEnumeratedFromVerifiedWindowParent(child)
                }
                rows.append(Row(node: node, role: role, subrole: subrole, protected: protection, hidden: hidden,
                    protectionFlags: protectionFlags, children: children))
                pending.append(contentsOf: children)
            }
            let rootAfter = try io.elements(root, kAXWindowsAttribute)
            let namesAfter = try io.names(root)
            let protectionAfter = try io.protectionFlags(root, names: namesAfter)
            try Self.admitApplicationProtection(protectionAfter)
            let windowNamesAfter = try io.names(window)
            guard protectionAfter == applicationProtection, try io.flag(root, "AXHidden", names: namesAfter) == appHidden,
                  rootAfter.filter({ CFEqual($0, window) }).count == 1,
                  !running.isHidden, DesktopApplicationTarget.matches(application, application: running),
                  try !io.requiredBool(window, kAXMinimizedAttribute, names: windowNamesAfter),
                  try !io.requiredBool(window, kAXModalAttribute, names: windowNamesAfter) else {
                throw NativeOrdinaryWindowPolicySource.Failure.changedContext
            }
            let windowRow = rows.first
            let text = [
                "standard-role-survey-v2",
                sourceID.uuidString,
                String(application.processID),
                application.bundleID,
                visibility,
                String(describing: applicationProtection),
                windowRow?.role ?? "AXWindow",
                windowRow?.subrole ?? "",
                String(describing: windowRow?.protectionFlags ?? []),
                String(describing: windowRow?.hidden ?? .unreported)
            ]
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let digest = Data(SHA256.hash(data: try encoder.encode(text)))
            let current = NativeStandardControlSurvey(sourceID: sourceID, application: application, window: window,
                validateSource: validateSource, rows: rows, visibilityBasis: visibility,
                applicationProtection: applicationProtection, digest: digest, readAudit: readAudit,
                metadataBinding: metadataBinding, authorizeMetadataScope: authorizeMetadataScope, inspectionBudget: budget)
            try inspectCaptured(current, io)
            return current
        }
    }

    /// The survey retains this factory's immutable source binding and STRONG
    /// validator, never the active phase or its cheap query closure. Legacy
    /// callers retain their original full validator around every AX query.
    private static func withMetadataPhase<Value>(sourceID: UUID, application: DesktopApplicationIdentity,
        window: AXUIElement, deadline: ContinuousClock.Instant,
        validateSource: @escaping @MainActor () throws -> Void,
        metadataBinding: TargetBoundNativeObservation.MetadataBinding?,
        authorizeMetadataScope: @escaping @MainActor () throws -> Void,
        readAudit: NativeReadAudit?,
        body: @MainActor (@escaping @MainActor () throws -> Void) throws -> Value) throws -> Value {
        guard let metadataBinding else { return try body(validateSource) }
        return try metadataBinding.withPhase(sourceID: sourceID, application: application, window: window,
            deadline: deadline, validateSource: validateSource, authorizeScope: authorizeMetadataScope,
            readAudit: readAudit) { phase in
                try body { try phase.check() }
            }
    }

    func validate() throws {
        let usesDirectBoundary = metadataBinding?.usesCanonicalDirectBoundary == true
        if !usesDirectBoundary { try validateSource() }
        let current = try Self.capture(sourceID: sourceID, application: application, window: window, validateSource: validateSource, readAudit: readAudit,
            diagnosticPhase: .revalidation, metadataBinding: metadataBinding, authorizeMetadataScope: authorizeMetadataScope,
            inspectionBudget: inspectionBudget)
        guard matchesSemanticContext(current) else {
            diagnoseSurveyMismatch(current)
            throw NativeOrdinaryWindowPolicySource.Failure.changedContext
        }
        if !usesDirectBoundary { try validateSource() }
    }

    /// Validates target process/window identity, visibility, application/window protection,
    /// and retained-node role/protection invariants while tolerating benign AppKit/SwiftUI/Chromium
    /// lazy AX child-list materialization (every newly materialized node in `current` has already
    /// passed `capture`'s strict non-secure, non-protected, non-modal, and window-membership gates).
    private func matchesSemanticContext(_ current: NativeStandardControlSurvey) -> Bool {
        guard sourceID == current.sourceID,
              application == current.application,
              CFEqual(window, current.window),
              visibilityBasis == current.visibilityBasis,
              applicationProtection == current.applicationProtection,
              digest == current.digest,
              let originalRoot = rows.first,
              let currentRoot = current.rows.first,
              CFEqual(originalRoot.node, currentRoot.node),
              originalRoot.role.utf8.elementsEqual(currentRoot.role.utf8),
              originalRoot.subrole.utf8.elementsEqual(currentRoot.subrole.utf8),
              originalRoot.protectionFlags == currentRoot.protectionFlags,
              originalRoot.hidden == currentRoot.hidden else {
            return false
        }
        let priorByHash = Dictionary(grouping: rows, by: { CFHash($0.node) })
        for fresh in current.rows {
            guard let old = priorByHash[CFHash(fresh.node)]?.first(where: { CFEqual($0.node, fresh.node) }) else {
                continue
            }
            if !old.role.utf8.elementsEqual(fresh.role.utf8)
                || !old.subrole.utf8.elementsEqual(fresh.subrole.utf8)
                || old.protectionFlags != fresh.protectionFlags {
                return false
            }
        }
        return true
    }

    /// Both values already completed the actual metadata-only capture. This
    /// cannot turn a capture/source error or diagnostic into retry admission.
    func initialComparison(to current: NativeStandardControlSurvey) throws -> NativeInitialMetadataAcquisition.CompletedComparison {
        guard sourceID == current.sourceID, application == current.application,
              CFEqual(window, current.window) else { throw NativeOrdinaryWindowPolicySource.Failure.changedContext }
        if matchesSemanticContext(current) { return .equal }
        diagnoseSurveyMismatch(current)
        return .mismatch
    }

    /// Only already-returned metadata is classified after the unchanged guard
    /// failed. No extra AX query, raw value, identifier or comparison override.
    private func diagnoseSurveyMismatch(_ current: NativeStandardControlSurvey) {
        guard let readAudit else { return }
        var classified = false
        func record(_ origin: NativeReadAudit.MetadataOrigin, role: String? = nil) {
            classified = true
            readAudit.recordSurveyMismatch(origin: origin, role: role)
        }
        if current.rows.count != rows.count { record(.surveyRowCountChanged) }
        if current.visibilityBasis != visibilityBasis { record(.surveyApplicationVisibilityChanged) }
        // Compare retained nodes even if their traversal indices shifted. Otherwise
        // a single added child makes unrelated rows look like they changed role,
        // visibility or protection. Order still matters to the admission check.
        let priorRows = Dictionary(grouping: rows.enumerated(), by: { CFHash($0.element.node) })
        var retainedIndices = Set<Int>()
        var lastPriorIndex: Int?
        var rowOrderChanged = false
        for fresh in current.rows {
            guard let prior = priorRows[CFHash(fresh.node)]?.first(where: { CFEqual($0.element.node, fresh.node) }) else {
                record(.surveyRowAdded, role: fresh.role)
                continue
            }
            if let lastPriorIndex, prior.offset < lastPriorIndex { rowOrderChanged = true }
            lastPriorIndex = prior.offset
            retainedIndices.insert(prior.offset)
            let old = prior.element
            if !old.role.utf8.elementsEqual(fresh.role.utf8) { record(.surveyRowRoleChanged, role: fresh.role) }
            if !old.subrole.utf8.elementsEqual(fresh.subrole.utf8) { record(.surveyRowSubroleChanged, role: fresh.role) }
            if old.protectionFlags != fresh.protectionFlags { record(.surveyRowProtectionChanged, role: fresh.role) }
            if old.hidden != fresh.hidden { record(.surveyRowVisibilityChanged, role: fresh.role) }
            if old.children.count != fresh.children.count { record(.surveyChildCountChanged, role: fresh.role) }
            if zip(old.children, fresh.children).contains(where: { !CFEqual($0, $1) }) {
                record(.surveyChildIdentityChanged, role: fresh.role)
            }
        }
        for (index, old) in rows.enumerated() where !retainedIndices.contains(index) {
            record(.surveyRowRemoved, role: old.role)
        }
        if rowOrderChanged { record(.surveyRowOrderChanged) }
        if current.digest != digest && !classified {
            // Remaining digest inputs are the already-read window frame and
            // application protection metadata. Do not guess which one changed.
            record(.surveyOtherMetadataDigestChanged)
        }
    }
    func policyFacts() throws -> NativeOrdinaryWindowPolicySource.Facts {
        let started = ContinuousClock.now
        defer { readAudit?.record(.policyLabelsPhase, since: started) }
        let result = Result {
            let usesDirectBoundary = metadataBinding?.usesCanonicalDirectBoundary == true
            let controlRows = rows.filter { ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains($0.role) }
            let io = Reader(application: application, window: window,
                deadline: ContinuousClock.now.advanced(by: inspectionBudget),
                validate: { if !usesDirectBoundary { try self.validateSource() } }, readAudit: readAudit,
                diagnosticPhase: .labelPreparation)
            var boundaries: Set<NativeOrdinaryWindowPolicySource.Dedicated> = [], labels: [String] = []
            var nextPreparedNames: Set<String>? = nil
            var hasPreparedNext = false
            for (index, row) in controlRows.enumerated() {
                if !usesDirectBoundary {
                    try io.check()
                }
                let nextNode: AXUIElement? = (usesDirectBoundary && index + 1 < controlRows.count) ? controlRows[index + 1].node : nil
                var preparedNames: Set<String>? = nil
                var preValidated = false
                try NativeControlLabelBatch.inspectControl(visibility: {
                    if usesDirectBoundary {
                        if hasPreparedNext {
                            preparedNames = nextPreparedNames
                            nextPreparedNames = nil
                            hasPreparedNext = false
                        } else {
                            preparedNames = try self.prepareDirectLabelNames(row.node, deadline: io.deadline)
                        }
                        preValidated = preparedNames != nil
                        return preValidated
                    }
                    return try self.labelVisibility(row.node, deadline: io.deadline, beforeLabels: true)
                }, read: {
                    guard let names = try preparedNames ?? self.labelAttributeNames(row.node, deadline: io.deadline) else {
                        throw NativeOrdinaryWindowPolicySource.Failure.changedContext
                    }
                    return try io.boundedLabels(row.node, advertisedNames: names, validatePrivateScope: {
                        if preValidated {
                            preValidated = false
                            return
                        }
                        if usesDirectBoundary {
                            nextPreparedNames = try self.validatePostLabelAndPrepareNext(
                                row.node,
                                nextNode: nextNode,
                                deadline: io.deadline
                            )
                            hasPreparedNext = nextNode != nil
                        } else {
                            try self.validatePrivateLabel(row.node, deadline: io.deadline)
                        }
                    })
                }, boundaries: &boundaries, labels: &labels)
            }
            try validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let sortedBoundaries = boundaries.map(\.rawValue).sorted()
            let combined = Data(SHA256.hash(data: digest + (try encoder.encode(sortedBoundaries))))
            return NativeOrdinaryWindowPolicySource.Facts(sourceID: sourceID, application: application,
                context: .ordinary, coverage: .standardRoleSurvey, visibleDedicatedControls: boundaries,
                visitedNodes: rows.count, digest: combined, standardSurvey: self)
        }
        // Recheck on success AND error before any labels/facts can escape.
        try validateSource()
        return try result.get()
    }

    private func validateFastWindowAndControlFence(_ node: AXUIElement, using io: Reader) throws {
        try io.check()
        guard let running = NSRunningApplication(processIdentifier: application.processID),
              DesktopApplicationTarget.matches(application, application: running), !running.isHidden else {
            throw NativeOrdinaryWindowPolicySource.Failure.changedContext
        }
        let root = AXUIElementCreateApplication(application.processID)
        let rootNames = try io.names(root)
        let rootProtection = try io.protectionFlags(root, names: rootNames)
        try Self.admitApplicationProtection(rootProtection)
        let windowNames = try io.names(window)
        guard rootProtection == applicationProtection,
              try !io.requiredBool(window, kAXMinimizedAttribute, names: windowNames),
              try !io.requiredBool(window, kAXModalAttribute, names: windowNames) else {
            throw NativeOrdinaryWindowPolicySource.Failure.changedContext
        }
        let nodeNames = try io.names(node)
        let nodeMeta = try io.rowMetadata(node, names: nodeNames)
        if Self.secure(role: nodeMeta.role, subrole: nodeMeta.subrole)
            || Self.aggregateProtection(nodeMeta.protectionFlags) == .reported(true) {
            throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
        }
        if let originalRow = rows.first(where: { CFEqual($0.node, node) }) {
            guard originalRow.role.utf8.elementsEqual(nodeMeta.role.utf8),
                  originalRow.subrole.utf8.elementsEqual(nodeMeta.subrole.utf8),
                  originalRow.protectionFlags == nodeMeta.protectionFlags else {
                throw NativeOrdinaryWindowPolicySource.Failure.changedContext
            }
        }
    }

    private func validatePrivateLabel(_ node: AXUIElement, deadline: ContinuousClock.Instant) throws {
        guard metadataBinding?.usesCanonicalDirectBoundary == true else {
            try Self.withMetadataPhase(sourceID: sourceID, application: application, window: window,
                deadline: deadline, validateSource: validateSource, metadataBinding: metadataBinding,
                authorizeMetadataScope: authorizeMetadataScope, readAudit: readAudit) { validateMetadata in
                    let io = Reader(application: application, window: window, deadline: deadline,
                        validate: validateMetadata, readAudit: readAudit, diagnosticPhase: .revalidation)
                    try validateFastWindowAndControlFence(node, using: io)
                    guard try Self.visibleOriginalAncestry(from: node, access: ancestryAccess(io)) else {
                        throw NativeOrdinaryWindowPolicySource.Failure.changedContext
                    }
                }
            return
        }
        _ = try validatePostLabelAndPrepareNext(node, nextNode: nil, deadline: deadline)
    }

    private func validatePostLabelAndPrepareNext(_ node: AXUIElement,
                                                 nextNode: AXUIElement?,
                                                 deadline: ContinuousClock.Instant) throws -> Set<String>? {
        try Self.withMetadataPhase(sourceID: sourceID, application: application, window: window,
            deadline: deadline, validateSource: validateSource, metadataBinding: metadataBinding,
            authorizeMetadataScope: authorizeMetadataScope, readAudit: readAudit) { validateMetadata in
                let io = Reader(application: application, window: window, deadline: deadline,
                    validate: validateMetadata, readAudit: readAudit, diagnosticPhase: .labelPreparation)
                try validateFastWindowAndControlFence(node, using: io)
                guard try Self.visibleOriginalAncestry(from: node, access: ancestryAccess(io)) else {
                    throw NativeOrdinaryWindowPolicySource.Failure.changedContext
                }
                guard let nextNode else { return nil }
                try validateFastWindowAndControlFence(nextNode, using: io)
                guard try Self.visibleOriginalForLabels(from: nextNode, access: ancestryAccess(io)) else {
                    return nil
                }
                return try io.names(nextNode)
            }
    }

    private func prepareDirectLabelNames(_ node: AXUIElement, deadline: ContinuousClock.Instant) throws -> Set<String>? {
        try Self.withMetadataPhase(sourceID: sourceID, application: application, window: window,
            deadline: deadline, validateSource: validateSource, metadataBinding: metadataBinding,
            authorizeMetadataScope: authorizeMetadataScope, readAudit: readAudit) { validateMetadata in
                let io = Reader(application: application, window: window, deadline: deadline,
                    validate: validateMetadata, readAudit: readAudit, diagnosticPhase: .labelPreparation)
                try validateFastWindowAndControlFence(node, using: io)
                guard try Self.visibleOriginalForLabels(from: node, access: ancestryAccess(io)) else {
                    return nil
                }
                return try io.names(node)
            }
    }

    /// Only Bool leaves this synchronous technical phase. No Reader/Access or
    /// cheap query closure reaches the later private label callback.
    private func labelVisibility(_ node: AXUIElement, deadline: ContinuousClock.Instant,
                                 beforeLabels: Bool) throws -> Bool {
        try Self.withMetadataPhase(sourceID: sourceID, application: application, window: window,
            deadline: deadline, validateSource: validateSource, metadataBinding: metadataBinding,
            authorizeMetadataScope: authorizeMetadataScope, readAudit: readAudit) { validateMetadata in
                let metadata = Reader(application: application, window: window, deadline: deadline,
                    validate: validateMetadata, readAudit: readAudit, diagnosticPhase: .labelPreparation)
                let access = ancestryAccess(metadata)
                if beforeLabels { return try Self.visibleOriginalForLabels(from: node, access: access) }
                return try Self.visibleOriginalAncestry(from: node, access: access)
            }
    }

    /// The exact direct binder may check visibility and discover names in the
    /// same technical phase. Only names leave it, and hidden controls return
    /// before any names query. The full private pre-fence stays outside.
    private func labelAttributeNames(_ node: AXUIElement, deadline: ContinuousClock.Instant,
                                     onlyWhenVisible: Bool = false) throws -> Set<String>? {
        try Self.withMetadataPhase(sourceID: sourceID, application: application, window: window,
            deadline: deadline, validateSource: validateSource, metadataBinding: metadataBinding,
            authorizeMetadataScope: authorizeMetadataScope, readAudit: readAudit) { validateMetadata in
                let metadata = Reader(application: application, window: window, deadline: deadline,
                    validate: validateMetadata, readAudit: readAudit, diagnosticPhase: .labelPreparation)
                if onlyWhenVisible {
                    guard try Self.visibleOriginalForLabels(from: node, access: ancestryAccess(metadata)) else { return nil }
                }
                return try metadata.names(node)
            }
    }

    /// Metadata-only traversal of the actual retained parent chain. A returned
    /// visibility bit is not an editor capability or input permission.
    struct AncestryAccess<Node> {
        let originalWindow: Node
        let identical: @MainActor (Node, Node) -> Bool
        let validate: @MainActor () throws -> Void
        let hidden: @MainActor (Node) throws -> OptionalFlag
        let parent: @MainActor (Node) throws -> Node
        let reportedChildren: @MainActor (Node) throws -> [Node]
        var diagnoseIncomplete: (@MainActor (NativeReadAudit.MetadataOrigin) -> Void)? = nil
    }
    static func visibleOriginalAncestry<Node>(from node: Node, access: AncestryAccess<Node>) throws -> Bool {
        var current = node, visited: [Node] = [], hidden = false
        for _ in 0..<32 {
            try access.validate()
            guard !visited.contains(where: { access.identical($0, current) }) else {
                access.diagnoseIncomplete?(.ancestryCycle)
                throw NativeOrdinaryWindowPolicySource.Failure.incomplete
            }
            visited.append(current)
            if try access.hidden(current) == .reported(true) { hidden = true }
            if access.identical(current, access.originalWindow) {
                try access.validate(); return !hidden
            }
            let parent = try access.parent(current)
            let children = try access.reportedChildren(parent)
            guard children.filter({ access.identical($0, current) }).count == 1 else {
                access.diagnoseIncomplete?(.ancestryMembership)
                throw NativeOrdinaryWindowPolicySource.Failure.incomplete
            }
            try access.validate(); current = parent
        }
        access.diagnoseIncomplete?(.ancestryBound)
        throw NativeOrdinaryWindowPolicySource.Failure.incomplete
    }
    static func readVisibleLabels<Node>(from node: Node, access: AncestryAccess<Node>, read: @MainActor () throws -> String) throws -> String? {
        guard try visibleOriginalForLabels(from: node, access: access) else { return nil }
        return try read()
    }
    /// Shared by the original node/access wrapper and the grouped visibility
    /// callback. Keep the additional validation after visible ancestry.
    static func visibleOriginalForLabels<Node>(from node: Node, access: AncestryAccess<Node>) throws -> Bool {
        guard try visibleOriginalAncestry(from: node, access: access) else { return false }
        try access.validate(); return true
    }
    private func ancestryAccess(_ io: Reader) -> AncestryAccess<AXUIElement> {
        .init(originalWindow: window, identical: { CFEqual($0, $1) }, validate: { try io.check() },
            hidden: { node in
                try io.check()
                if let row = self.rows.first(where: { CFEqual($0.node, node) }) {
                    return row.hidden
                }
                let nodeNames = try io.names(node)
                let metadata = try io.rowMetadata(node, names: nodeNames)
                if Self.secure(role: metadata.role, subrole: metadata.subrole)
                    || Self.aggregateProtection(metadata.protectionFlags) == .reported(true) {
                    throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
                }
                return metadata.hidden
            }, parent: { node in try io.element(node, kAXParentAttribute) }, reportedChildren: { parent in
                try io.check()
                if let row = self.rows.first(where: { CFEqual($0.node, parent) }),
                   !row.children.isEmpty {
                    return row.children
                }
                return try io.elements(parent, kAXChildrenAttribute)
            }, diagnoseIncomplete: { origin in _ = io.incomplete(origin) })
    }

    /// The only supported absence is the exact unadvertised/unsupported pair.
    /// AX errors, advertised-but-unavailable attributes and wrong CF types are
    /// never converted into either false or a supported absence.
    static func optionalFlag(status: AXError, advertised: Bool, value: CFTypeRef?) throws -> OptionalFlag {
        if status == .attributeUnsupported, !advertised, value == nil { return .unreported }
        guard status == .success, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw NativeOrdinaryWindowPolicySource.Failure.incomplete
        }
        return .reported(CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self)))
    }

    static func admitApplicationProtection(_ flags: [OptionalFlag]) throws {
        guard flags.count == 2 else { throw NativeOrdinaryWindowPolicySource.Failure.incomplete }
        guard !flags.contains(.reported(true)) else { throw NativeOrdinaryWindowPolicySource.Failure.protectedContext }
    }

    private static func aggregateProtection(_ flags: [OptionalFlag]) -> OptionalFlag {
        if flags.contains(.reported(true)) { return .reported(true) }
        if flags.contains(.reported(false)) { return .reported(false) }
        return .unreported
    }

    static func terminalChildren<Node>(role: String, status: AXError, value: [Node]?, liveOriginalLeaf: Bool) throws -> [Node] {
        if status == .success {
            guard let value, value.count <= 2_048 else { throw NativeOrdinaryWindowPolicySource.Failure.incomplete }
            return value
        }
        guard [.attributeUnsupported, .noValue].contains(status), value == nil,
              terminalRoles.contains(role), liveOriginalLeaf else { throw NativeOrdinaryWindowPolicySource.Failure.incomplete }
        return []
    }

    /// Positive editor metadata under this actual reader's original window.
    /// Its private initializer prevents diagnostic flags from being upgraded
    /// into disclosure authority. No value/label/selection/style is retained.
    @MainActor final class Editor: Equatable {
        nonisolated private let identity = UUID()
        private let survey: NativeStandardControlSurvey
        private let node: AXUIElement
        let role: String, subrole: String
        let protected: Bool?, hidden: Bool?, enabled: Bool?
        let valueWritable: Bool, selectionWritable: Bool, selectedTextWritable: Bool
        var usesCanonicalDirectBoundary: Bool { survey.metadataBinding?.usesCanonicalDirectBoundary == true }
        nonisolated static func == (lhs: Editor, rhs: Editor) -> Bool { lhs.identity == rhs.identity }
        fileprivate init(survey: NativeStandardControlSurvey, node: AXUIElement, metadata: EditorMetadata) {
            self.survey = survey; self.node = node; role = metadata.role; subrole = metadata.subrole
            protected = metadata.protected.value; hidden = metadata.hidden.value; enabled = metadata.enabled.value
            valueWritable = metadata.valueWritable; selectionWritable = metadata.selectionWritable
            selectedTextWritable = metadata.selectedTextWritable
        }
        func validate(role: String, subrole: String, protected: Bool?, hidden: Bool?, enabled: Bool?) throws {
            guard role.utf8.elementsEqual(self.role.utf8), subrole.utf8.elementsEqual(self.subrole.utf8),
                  protected == self.protected, hidden == self.hidden, enabled == self.enabled else {
                throw NativeOrdinaryWindowPolicySource.Failure.changedContext
            }
            try survey.validate()
            try validateEditorMetadataOnly(role: role, subrole: subrole, protected: protected,
                hidden: hidden, enabled: enabled)
        }
        func validateEditorMetadataOnly(role: String, subrole: String, protected: Bool?, hidden: Bool?, enabled: Bool?) throws {
            guard role.utf8.elementsEqual(self.role.utf8), subrole.utf8.elementsEqual(self.subrole.utf8),
                  protected == self.protected, hidden == self.hidden, enabled == self.enabled else {
                throw NativeOrdinaryWindowPolicySource.Failure.changedContext
            }
            let current = try survey.editorMetadata(node)
            guard current.role.utf8.elementsEqual(self.role.utf8), current.subrole.utf8.elementsEqual(self.subrole.utf8),
                  current.protected.value == self.protected, current.hidden.value == self.hidden,
                  current.enabled.value == self.enabled, current.valueWritable == valueWritable,
                  current.selectionWritable == selectionWritable, current.selectedTextWritable == selectedTextWritable else {
                throw NativeOrdinaryWindowPolicySource.Failure.changedContext
            }
            try survey.validateSource()
        }
    }
    fileprivate struct EditorMetadata {
        let role: String, subrole: String
        let protected: OptionalFlag, hidden: OptionalFlag, enabled: OptionalFlag
        let valueWritable: Bool, selectionWritable: Bool, selectedTextWritable: Bool
    }
    func editor(_ node: AXUIElement) throws -> Editor {
        try validate()
        let metadata = try editorMetadata(node)
        return Editor(survey: self, node: node, metadata: metadata)
    }
    private func editorMetadata(_ node: AXUIElement) throws -> EditorMetadata {
        let deadline = ContinuousClock.now.advanced(by: inspectionBudget)
        return try Self.withMetadataPhase(sourceID: sourceID, application: application, window: window,
            deadline: deadline, validateSource: validateSource, metadataBinding: metadataBinding,
            authorizeMetadataScope: authorizeMetadataScope, readAudit: readAudit) { validateMetadata in
            let io = Reader(application: application, window: window, deadline: deadline,
                validate: validateMetadata, readAudit: readAudit, diagnosticPhase: .editorMetadata)
            try io.check()
            let names = try io.names(node), role = try io.string(node, kAXRoleAttribute)
            try io.requireOriginalWindowMembership(node, role: role, use: .surveyRow)
            guard try Self.visibleOriginalAncestry(from: node, access: ancestryAccess(io)) else {
                throw io.incomplete(.editorVisibility)
            }
            let subrole = try io.optionalString(node, kAXSubroleAttribute, names: names, diagnosticRole: role) ?? ""
            let protection = try io.protectedFlag(node, names: names, diagnosticRole: role), hidden = try io.flag(node, "AXHidden", names: names, diagnosticRole: role)
            let enabled = try io.flag(node, kAXEnabledAttribute, names: names, diagnosticRole: role)
            let valueWritable = try io.writable(node, kAXValueAttribute, diagnosticRole: role)
            let selectionWritable = try io.writable(node, kAXSelectedTextRangeAttribute, diagnosticRole: role)
            let selectedTextWritable = try io.writable(node, kAXSelectedTextAttribute, diagnosticRole: role)
            do {
                try Self.admitEditorMetadata(role: role, subrole: subrole, protection: protection, hidden: hidden,
                    enabled: enabled, valueWritable: valueWritable, selectionWritable: selectionWritable, selectedTextWritable: selectedTextWritable)
            } catch {
                _ = io.incomplete(.editorCapability, role: role)
                throw error
            }
            try io.check()
            return EditorMetadata(role: role, subrole: subrole, protected: protection, hidden: hidden, enabled: enabled,
                valueWritable: valueWritable, selectionWritable: selectionWritable, selectedTextWritable: selectedTextWritable)
        }
    }
    /// This is a policy predicate, not a way to mint an Editor capability.
    /// A text area without AXEnabled needs actual writable value AND selected
    /// text AND selection. Selection access alone is not editing permission.
    static func admitEditorMetadata(role: String, subrole: String, protection: OptionalFlag, hidden: OptionalFlag,
                                    enabled: OptionalFlag, valueWritable: Bool, selectionWritable: Bool,
                                    selectedTextWritable: Bool) throws {
        guard ["AXTextField", "AXTextArea"].contains(role), !secure(role: role, subrole: subrole),
              !subrole.localizedCaseInsensitiveContains("search"), protection != .reported(true), hidden != .reported(true),
              valueWritable, selectionWritable, selectedTextWritable else { throw NativeOrdinaryWindowPolicySource.Failure.incomplete }
        switch enabled {
        case .reported(true): break
        case .unreported where role == "AXTextArea": break
        default: throw NativeOrdinaryWindowPolicySource.Failure.incomplete
        }
    }

    private static let supportedRoles: Set<String> = [
        "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXTabGroup", "AXToolbar",
        "AXTextField", "AXTextArea", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXStaticText", "AXImage", "AXScrollBar", "AXSlider",
        "AXList", "AXOutline", "AXTable", "AXRow", "AXColumn", "AXCell",
        "AXWebArea", "AXLink", "AXHeading",
        "AXMenuButton", "AXComboBox", "AXSearchField", "AXSegmentedControl", "AXDisclosureTriangle",
        "AXTab", "AXSplitter", "AXIncrementor", "AXDateField", "AXColorWell",
        "AXProgressIndicator", "AXBusyIndicator", "AXValueIndicator", "AXRelevanceIndicator", "AXLevelIndicator",
        "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem",
        "AXPopover", "AXDrawer", "AXGrowArea", "AXHandle", "AXMatte",
        "AXRuler", "AXRulerMarker", "AXLayoutArea", "AXLayoutItem", "AXHelpTag",
        "AXBrowser", "AXGrid"
    ]
    private static let terminalRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXStaticText", "AXImage", "AXScrollBar", "AXSlider",
        "AXSplitGroup", "AXTabGroup", "AXToolbar",
        "AXList", "AXOutline", "AXTable", "AXRow", "AXColumn", "AXCell",
        "AXWebArea", "AXLink", "AXHeading",
        "AXMenuButton", "AXComboBox", "AXSearchField", "AXSegmentedControl", "AXDisclosureTriangle",
        "AXTab", "AXSplitter", "AXIncrementor", "AXDateField", "AXColorWell",
        "AXProgressIndicator", "AXBusyIndicator", "AXValueIndicator", "AXRelevanceIndicator", "AXLevelIndicator",
        "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem",
        "AXPopover", "AXDrawer", "AXGrowArea", "AXHandle", "AXMatte",
        "AXRuler", "AXRulerMarker", "AXLayoutArea", "AXLayoutItem", "AXHelpTag",
        "AXBrowser", "AXGrid"
    ]
    private static func secure(role: String, subrole: String) -> Bool {
        [role, subrole].contains { $0.localizedCaseInsensitiveContains("secure") || $0.localizedCaseInsensitiveContains("password") }
    }
    private static func intersectsDisplay(_ frame: CGRect) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { frame.intersects(CGDisplayBounds($0)) }
    }

    private static func incomplete(_ origin: NativeReadAudit.MetadataOrigin,
        phase: NativeReadAudit.MetadataPhase, attribute: NativeReadAudit.MetadataAttribute = .structural,
        role: String? = nil, readAudit: NativeReadAudit?) -> NativeOrdinaryWindowPolicySource.Failure {
        NativeReadAudit.incompleteMetadata(readAudit, .init(phase: phase, origin: origin,
            attribute: attribute, role: role.map(NativeReadAudit.MetadataRole.init) ?? .unclassified,
            status: .notApplicable, valueType: .notApplicable, advertised: nil))
        return .incomplete
    }

    /// Exact deadline decision used by Reader.check. A missed deadline keeps
    /// its diagnostic and the same .incomplete outward error.
    static func requireMetadataDeadline(_ deadline: ContinuousClock.Instant,
                                        now: ContinuousClock.Instant = ContinuousClock.now,
                                        readAudit: NativeReadAudit? = nil) throws {
        guard now < deadline else {
            readAudit?.record(.policyDeadlineRefusal, since: now)
            throw NativeOrdinaryWindowPolicySource.Failure.incomplete
        }
    }

    private final class ScanCache {
        private var verifiedPIDByHash: [CFHashCode: [AXUIElement]] = [:]
        private var verifiedWindowByHash: [CFHashCode: [AXUIElement]] = [:]
        private var parentEnumeratedByHash: [CFHashCode: [AXUIElement]] = [:]

        func isPIDVerified(_ element: AXUIElement) -> Bool {
            verifiedPIDByHash[CFHash(element)]?.contains(where: { CFEqual($0, element) }) == true
        }
        func markPIDVerified(_ element: AXUIElement) {
            let hash = CFHash(element)
            if verifiedPIDByHash[hash]?.contains(where: { CFEqual($0, element) }) != true {
                verifiedPIDByHash[hash, default: []].append(element)
            }
        }
        func isWindowVerified(_ element: AXUIElement) -> Bool {
            verifiedWindowByHash[CFHash(element)]?.contains(where: { CFEqual($0, element) }) == true
        }
        func markWindowVerified(_ element: AXUIElement) {
            let hash = CFHash(element)
            if verifiedWindowByHash[hash]?.contains(where: { CFEqual($0, element) }) != true {
                verifiedWindowByHash[hash, default: []].append(element)
            }
        }
        func isEnumeratedFromVerifiedWindowParent(_ element: AXUIElement) -> Bool {
            parentEnumeratedByHash[CFHash(element)]?.contains(where: { CFEqual($0, element) }) == true
        }
        func markEnumeratedFromVerifiedWindowParent(_ element: AXUIElement) {
            let hash = CFHash(element)
            if parentEnumeratedByHash[hash]?.contains(where: { CFEqual($0, element) }) != true {
                parentEnumeratedByHash[hash, default: []].append(element)
            }
        }
    }

    private struct Reader {
        let application: DesktopApplicationIdentity, window: AXUIElement
        let deadline: ContinuousClock.Instant
        let validate: @MainActor () throws -> Void
        let readAudit: NativeReadAudit?
        let diagnosticPhase: NativeReadAudit.MetadataPhase
        let cache = ScanCache()

        func incomplete(_ origin: NativeReadAudit.MetadataOrigin, name: String? = nil,
                        status: AXError? = nil, value: CFTypeRef? = nil, role: String? = nil,
                        advertised: Bool? = nil) -> NativeOrdinaryWindowPolicySource.Failure {
            NativeReadAudit.incompleteMetadata(readAudit, .init(phase: diagnosticPhase, origin: origin,
                attribute: name.map(NativeReadAudit.MetadataAttribute.init) ?? .structural,
                role: role.map(NativeReadAudit.MetadataRole.init) ?? .unclassified,
                status: status.map(NativeReadAudit.MetadataStatus.init) ?? .notApplicable,
                valueType: status == nil ? .notApplicable : .init(value), advertised: advertised))
            return .incomplete
        }
        func check() throws {
            try Task.checkCancellation(); try validate()
            try NativeStandardControlSurvey.requireMetadataDeadline(deadline, readAudit: readAudit)
        }
        private func ensureSameProcess(_ node: AXUIElement) throws {
            if cache.isPIDVerified(node) { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid == application.processID else {
                throw NativeOrdinaryWindowPolicySource.Failure.unavailable
            }
            AXUIElementSetMessagingTimeout(node, 0.04)
            cache.markPIDVerified(node)
        }
        func raw(_ node: AXUIElement, _ name: String, stage: NativeReadAudit.Stage = .policyMetadata) throws -> (AXError, CFTypeRef?) {
            try check(); try ensureSameProcess(node)
            var value: CFTypeRef?
            let status = NativeReadAudit.measure(readAudit, stage) { AXUIElementCopyAttributeValue(node, name as CFString, &value) }
            try check(); return (status, value)
        }
        /// One technical-only batch; no labels, field values, selections or
        /// images. Both live scope guards remain around the SDK call. No
        /// response survives this row or replaces later full survey validation.
        func rowMetadata(_ node: AXUIElement, names: Set<String>) throws -> NativeTechnicalRowBatch.Metadata {
            try check(); try ensureSameProcess(node)
            var values: CFArray?
            let status = NativeReadAudit.measure(readAudit, .policyMetadata) {
                AXUIElementCopyMultipleAttributeValues(node, NativeTechnicalRowBatch.attributeNames as CFArray, [], &values)
            }
            try check()
            return try NativeTechnicalRowBatch.decode(status: status, values: values, names: names) {
                origin, name, status, value, role, advertised in
                incomplete(origin, name: name, status: status, value: value, role: role, advertised: advertised)
            }
        }
        func names(_ node: AXUIElement) throws -> Set<String> {
            try check(); try ensureSameProcess(node)
            var value: CFArray?
            let status = NativeReadAudit.measure(readAudit, .policyMetadata) { AXUIElementCopyAttributeNames(node, &value) }
            try check()
            guard status == .success, let values = value as? [String], values.count <= 256 else {
                NativeReadAudit.incompleteMetadata(readAudit, .init(phase: diagnosticPhase, origin: .attributeNames,
                    attribute: .namesRequired, role: .unclassified, status: .init(status),
                    valueType: .init(value), advertised: nil))
                throw NativeOrdinaryWindowPolicySource.Failure.incomplete
            }
            return Set(values)
        }
        func string(_ node: AXUIElement, _ name: String) throws -> String {
            let (status, value) = try raw(node, name)
            guard status == .success, let string = value as? String, string.utf8.count <= 1_024 else {
                throw incomplete(.requiredText, name: name, status: status, value: value)
            }
            return string
        }
        func optionalString(_ node: AXUIElement, _ name: String, names: Set<String>, diagnosticRole: String? = nil) throws -> String? {
            let (status, value) = try raw(node, name)
            if status == .attributeUnsupported, !names.contains(name), value == nil { return nil }
            guard status == .success, let string = value as? String, string.utf8.count <= 1_024 else {
                throw incomplete(.optionalText, name: name, status: status, value: value, role: diagnosticRole, advertised: names.contains(name))
            }
            return string
        }
        func flag(_ node: AXUIElement, _ name: String, names: Set<String>, diagnosticRole: String? = nil) throws -> OptionalFlag {
            let (status, value) = try raw(node, name)
            do {
                return try NativeStandardControlSurvey.optionalFlag(status: status,
                    advertised: names.contains(name), value: value)
            } catch {
                _ = incomplete(.optionalFlag, name: name, status: status, value: value, role: diagnosticRole, advertised: names.contains(name))
                throw error
            }
        }
        func protectionFlags(_ node: AXUIElement, names: Set<String>, diagnosticRole: String? = nil) throws -> [OptionalFlag] {
            try [flag(node, "AXProtectedContent", names: names, diagnosticRole: diagnosticRole),
                flag(node, "AXContainsProtectedContent", names: names, diagnosticRole: diagnosticRole)]
        }
        func protectedFlag(_ node: AXUIElement, names: Set<String>, diagnosticRole: String? = nil) throws -> OptionalFlag {
            NativeStandardControlSurvey.aggregateProtection(try protectionFlags(node, names: names, diagnosticRole: diagnosticRole))
        }
        func requiredBool(_ node: AXUIElement, _ name: String, names: Set<String>? = nil, diagnosticRole: String? = nil) throws -> Bool {
            let resolvedNames = try names ?? self.names(node)
            guard case .reported(let value) = try flag(node, name, names: resolvedNames, diagnosticRole: diagnosticRole) else {
                throw incomplete(.requiredBoolean, name: name, role: diagnosticRole)
            }
            return value
        }
        func elements(_ node: AXUIElement, _ name: String) throws -> [AXUIElement] {
            var (status, value) = try raw(node, name)
            // An app may briefly miss its window-list IPC while processing
            // focus events. Repeat this metadata-only read once with the
            // same source guard and original survey deadline.
            if name == kAXWindowsAttribute, status == .cannotComplete, value == nil {
                (status, value) = try raw(node, name)
            }
            guard status == .success, let elements = value as? [AXUIElement], elements.count <= 2_048,
                  elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
                throw incomplete(.elementArray, name: name, status: status, value: value)
            }
            return elements
        }
        func element(_ node: AXUIElement, _ name: String) throws -> AXUIElement {
            let (status, value) = try raw(node, name)
            guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw incomplete(.element, name: name, status: status, value: value)
            }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        func verifyScannedChildWindowMembership(_ node: AXUIElement, names: Set<String>, role: String) throws {
            if cache.isWindowVerified(node) { return }
            if cache.isEnumeratedFromVerifiedWindowParent(node) {
                if names.contains(kAXWindowAttribute) {
                    let (status, value) = try raw(node, kAXWindowAttribute)
                    if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                        let reported = unsafeDowncast(value, to: AXUIElement.self)
                        guard CFEqual(reported, window) else {
                            throw incomplete(.retainedWindowMembership, name: kAXWindowAttribute, status: status, value: value, role: role)
                        }
                    } else if status != .attributeUnsupported && status != .noValue {
                        throw incomplete(.element, name: kAXWindowAttribute, status: status, value: value, role: role)
                    }
                }
                cache.markWindowVerified(node)
                return
            }
            try requireOriginalWindowMembership(node, role: role, use: .surveyRow)
        }
        /// Only these two capture consumers may replace a missing shortcut
        /// with positive current parent/direct-child evidence. Generic element
        /// lookup, editor membership and private visibility remain strict.
        func requireOriginalWindowMembership(_ node: AXUIElement, role: String,
                                             use: NativeWindowParentMembership.Use) throws {
            if cache.isWindowVerified(node) { return }
            let (status, value) = try raw(node, kAXWindowAttribute)
            let reported: AXUIElement?
            if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                reported = unsafeDowncast(value, to: AXUIElement.self)
            } else { reported = nil }
            let shortcut = NativeWindowParentMembership.shortcut(status: status,
                valuePresent: value != nil, element: reported)
            let missing: Bool
            if case .missingValue = shortcut { missing = true } else { missing = false }
            if missing {
                NativeReadAudit.recordWindowMembership(readAudit, event: .missing,
                    use: use, phase: diagnosticPhase, role: role)
            }
            let access = NativeWindowParentMembership.Access(originalWindow: window,
                identical: { CFEqual($0, $1) }, validate: { try self.check() },
                liveRole: { try self.string($0, kAXRoleAttribute) },
                parent: { try self.element($0, kAXParentAttribute) },
                directChildren: { try self.elements($0, kAXChildrenAttribute) })
            do {
                let basis = try NativeWindowParentMembership.require(node, shortcut: shortcut,
                    expectedRole: role, access: access)
                if basis == .currentParentChain {
                    NativeReadAudit.recordWindowMembership(readAudit, event: .verified,
                        use: use, phase: diagnosticPhase, role: role)
                }
                cache.markWindowVerified(node)
            } catch let failure as NativeWindowParentMembership.Failure {
                if missing {
                    NativeReadAudit.recordWindowMembership(readAudit, event: .refused,
                        use: use, phase: diagnosticPhase, role: role, failure: failure)
                }
                throw incomplete(failure == .differentWindow ? .retainedWindowMembership : .element,
                    name: kAXWindowAttribute, status: status, value: value, role: role)
            } catch {
                if missing {
                    NativeReadAudit.recordWindowMembership(readAudit, event: .refused,
                        use: use, phase: diagnosticPhase, role: role)
                }
                // Cancellation, source/privacy/lease/deadline and actual Reader
                // errors retain their original typed failure and diagnostics.
                throw error
            }
        }

        func children(_ node: AXUIElement, role: String, advertised: Bool) throws -> [AXUIElement] {
            let (status, value) = try raw(node, kAXChildrenAttribute)
            if status == .success {
                guard let elements = value as? [AXUIElement], elements.count <= 2_048,
                      elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
                    throw incomplete(.childrenArray, name: kAXChildrenAttribute, status: status,
                        value: value, role: role, advertised: advertised)
                }
                return elements
            }
            guard value == nil else {
                throw incomplete(.childrenUnexpectedValue, name: kAXChildrenAttribute, status: status,
                    value: value, role: role, advertised: advertised)
            }
            // A terminal role alone is insufficient: re-query exact PID/role
            // and retained-window membership before accepting absent children.
            let currentRole = try string(node, kAXRoleAttribute)
            try requireOriginalWindowMembership(node, role: currentRole, use: .terminalChildren)
            let live = currentRole.utf8.elementsEqual(role.utf8)
            do {
                return try NativeStandardControlSurvey.terminalChildren(role: role, status: status,
                    value: Optional<[AXUIElement]>.none, liveOriginalLeaf: live)
            } catch {
                _ = incomplete(.terminalChildrenCoverage, name: kAXChildrenAttribute, status: status,
                    value: value, role: role, advertised: advertised)
                throw error
            }
        }
        func writable(_ node: AXUIElement, _ name: String, diagnosticRole: String? = nil) throws -> Bool {
            try check(); var writable = DarwinBoolean(false)
            let status = NativeReadAudit.measure(readAudit, .focusedCapabilityMetadata) { AXUIElementIsAttributeSettable(node, name as CFString, &writable) }
            try check()
            guard status == .success else { throw incomplete(.writableCapability, name: name, status: status, role: diagnosticRole) }
            return writable.boolValue
        }
        func rawLabelBatch(_ node: AXUIElement) throws -> NativeControlLabelBatch.RawResponse {
            try check(); try ensureSameProcess(node)
            var value: CFArray?
            let status = NativeReadAudit.measure(readAudit, .policyLabel) {
                AXUIElementCopyMultipleAttributeValues(node, NativeControlLabelBatch.attributeNames as CFArray,
                    AXCopyMultipleAttributeOptions(rawValue: 0), &value)
            }
            try check(); var pidAfter: pid_t = 0
            guard AXUIElementGetPid(node, &pidAfter) == .success, pidAfter == application.processID else { throw NativeOrdinaryWindowPolicySource.Failure.unavailable }
            return .init(status: status, values: value)
        }
        func boundedLabels(_ node: AXUIElement, advertisedNames: Set<String>, validatePrivateScope: @MainActor () throws -> Void) throws -> String {
            return try NativeControlLabelBatch.read(advertisedNames: advertisedNames, validatePrivateScope: validatePrivateScope,
                transport: { try self.rawLabelBatch(node) },
                incomplete: { origin, name, status, value, advertised in
                    self.incomplete(origin, name: name, status: status, value: value, advertised: advertised)
                })
        }
        func frame(_ node: AXUIElement) throws -> CGRect {
            let (pStatus, pRaw) = try raw(node, kAXPositionAttribute), (sStatus, sRaw) = try raw(node, kAXSizeAttribute)
            guard pStatus == .success, sStatus == .success, let pRaw, let sRaw,
                  CFGetTypeID(pRaw) == AXValueGetTypeID(), CFGetTypeID(sRaw) == AXValueGetTypeID() else {
                if readAudit != nil {
                    if pStatus != .success || pRaw.map({ CFGetTypeID($0) != AXValueGetTypeID() }) != false {
                        _ = incomplete(.frameAttributes, name: kAXPositionAttribute, status: pStatus, value: pRaw)
                    } else {
                        _ = incomplete(.frameAttributes, name: kAXSizeAttribute, status: sStatus, value: sRaw)
                    }
                }
                throw NativeOrdinaryWindowPolicySource.Failure.incomplete
            }
            let p = unsafeDowncast(pRaw, to: AXValue.self), s = unsafeDowncast(sRaw, to: AXValue.self)
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
                  AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size),
                  [point.x, point.y, size.width, size.height].allSatisfy(\.isFinite), size.width > 0, size.height > 0 else {
                throw incomplete(.frameValue, name: kAXPositionAttribute, status: .success, value: pRaw)
            }
            return CGRect(origin: point, size: size)
        }
    }
}
