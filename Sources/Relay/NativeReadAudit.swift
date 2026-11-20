import ApplicationServices
import Foundation

/// Optional inert diagnostics. This value conveys no source identity, argument,
/// image, callback authority or input permission. A nil audit changes no query.
/// Samples count attempts (including errors), never prove delivery or success.
nonisolated final class NativeReadAudit: Sendable {
    enum Stage: String, Sendable, CaseIterable {
        case policySurvey, policyLabelsPhase
        case policyMetadata, policyLabel, policySourceValidation, policyMetadataLeaseValidation
        case policyMetadataReferenceValidation, policyMetadataScopeAuthorization, policyMetadataQueryProcessProof
        case policyMetadataSavedOwnerProof
        case policyMetadataObserverOwnerValidation, policyMetadataCurrentValidation, policyMetadataTrustValidation
        case policyMetadataWindowPIDValidation, policyMetadataRootPIDValidation, policyMetadataProcessFenceValidation
        case policyMetadataSealedScope, policyMetadataOpaqueScope
        case policyMetadataIncompleteReason, policySurveyMismatch, policyMetadataPhaseFailure
        case policyWindowMembershipAttempt, policyWindowMembershipVerified, policyWindowMembershipRefused
        case policyProtectedRefusal, policyIncompleteRefusal, policyUnavailableRefusal
        case policyChangedContextRefusal, policyDedicatedRefusal, policyOtherRefusal, policyDeadlineRefusal
        case focusedIdentityMetadata, focusedCapabilityMetadata
        case retainedEditorIdentityValidation, retainedEditorOwnerValidation, retainedEditorProcessValidation
        case retainedEditorPIDValidation, retainedEditorFocusedWindowRead, retainedEditorFocusedEditorRead, retainedEditorWindowRead
        case retainedWindowInfoValidation, retainedWindowInfoRequiredBatchRead, retainedWindowInfoOptionalAttributesRead
        case retainedUniqueWindowValidation, retainedUniqueWindowListRead, retainedUniqueWindowTitleRead, retainedUniqueWindowCurrentValidation
        case editorLabel, editorValue, editorSelection, editorSelectedText, editorStyle
        case nativeStateWriteAttempt
    }
    /// Refusal tags observe actual typed inspection exits. They grant no source
    /// or input authority and never carry provider/source error text.
    struct Sample: Sendable {
        let stage: Stage
        let elapsed: Duration
        let metadata: MetadataDiagnostic?
        init(stage: Stage, elapsed: Duration, metadata: MetadataDiagnostic? = nil) {
            self.stage = stage; self.elapsed = elapsed; self.metadata = metadata
        }
    }

    /// Closed technical classifications only. No source string, raw role,
    /// attribute name, path, label, value, pointer or error text can be stored.
    enum MetadataPhase: String, Sendable, Codable, CaseIterable {
        case initialCapture, revalidation, labelPreparation, editorMetadata, synchronousPhase
    }
    enum MetadataOrigin: String, Sendable, Codable, CaseIterable {
        case exactUnsentOperationRefusal
        case phaseEntryRefusal, phaseBodyRefusal, phaseExitRefusal, policyInspectionRefusal
        case attributeNames, requiredText, optionalText, optionalFlag, requiredBoolean
        case elementArray, element, childrenArray, childrenUnexpectedValue, terminalChildrenCoverage
        case nodeBound, pendingChildrenBound, unsupportedRoleOrSubrole, retainedWindowMembership
        case frameAttributes, frameValue, ancestryCycle, ancestryBound, ancestryNodeMissing
        case ancestryParentMissing, ancestryMembership, editorMembership, editorVisibility, editorCapability, writableCapability
        case labelValue, labelBound
        case windowMissingSurvey, windowMissingTerminal, windowVerifiedSurvey, windowVerifiedTerminal
        case windowRefusedSurvey, windowRefusedTerminal
        case windowParentCycle, windowParentNodeBound, windowParentChildBound
        case windowParentMissingChild, windowParentDuplicateChild, windowParentChangedParent, windowParentChangedRole
        case windowParentInvalidWindowRole, windowParentUnexpectedRoot
        case surveyRowCountChanged, surveyRowIdentityChanged, surveyChildCountChanged, surveyChildIdentityChanged
        case surveyRowAdded, surveyRowRemoved, surveyRowOrderChanged
        case surveyRowRoleChanged, surveyRowSubroleChanged, surveyRowProtectionChanged, surveyRowVisibilityChanged
        case surveyApplicationVisibilityChanged, surveyOtherMetadataDigestChanged
    }
    enum MetadataAttribute: String, Sendable, Codable, CaseIterable {
        case namesRequired, roleRequired, subroleOptional, hiddenOptional
        case protectedContentOptional, containsProtectedContentOptional, minimizedRequired, modalRequired
        case windowsRequired, windowRequired, parentRequired, childrenOrQualifiedTerminal
        case positionRequired, sizeRequired, valueWritable, selectionWritable, selectedTextWritable
        case titleOptional, descriptionOptional, identifierOptional, structural, otherMetadata
        init(_ name: String) {
            switch name {
            case kAXRoleAttribute: self = .roleRequired
            case kAXSubroleAttribute: self = .subroleOptional
            case "AXHidden": self = .hiddenOptional
            case "AXProtectedContent": self = .protectedContentOptional
            case "AXContainsProtectedContent": self = .containsProtectedContentOptional
            case kAXMinimizedAttribute: self = .minimizedRequired
            case kAXModalAttribute: self = .modalRequired
            case kAXWindowsAttribute: self = .windowsRequired
            case kAXWindowAttribute: self = .windowRequired
            case kAXParentAttribute: self = .parentRequired
            case kAXChildrenAttribute: self = .childrenOrQualifiedTerminal
            case kAXPositionAttribute: self = .positionRequired
            case kAXSizeAttribute: self = .sizeRequired
            case kAXValueAttribute: self = .valueWritable
            case kAXSelectedTextRangeAttribute: self = .selectionWritable
            case kAXSelectedTextAttribute: self = .selectedTextWritable
            case kAXTitleAttribute: self = .titleOptional
            case kAXDescriptionAttribute: self = .descriptionOptional
            case kAXIdentifierAttribute: self = .identifierOptional
            default: self = .otherMetadata
            }
        }
    }
    enum MetadataRole: String, Sendable, Codable, CaseIterable {
        case unclassified, window, group, scrollArea, splitGroup, tabGroup, toolbar
        case textArea, textField, secureTextField, staticText, button, checkBox, radioButton, popUpButton, image, other
        init(_ role: String) {
            switch role {
            case "AXWindow": self = .window
            case "AXGroup": self = .group
            case "AXScrollArea": self = .scrollArea
            case "AXSplitGroup": self = .splitGroup
            case "AXTabGroup": self = .tabGroup
            case "AXToolbar": self = .toolbar
            case "AXTextArea": self = .textArea
            case "AXTextField": self = .textField
            case "AXSecureTextField": self = .secureTextField
            case "AXStaticText": self = .staticText
            case "AXButton": self = .button
            case "AXCheckBox": self = .checkBox
            case "AXRadioButton": self = .radioButton
            case "AXPopUpButton": self = .popUpButton
            case "AXImage": self = .image
            default: self = .other
            }
        }
    }
    enum MetadataStatus: String, Sendable, Codable, CaseIterable {
        case notApplicable, success, failure, illegalArgument, invalidElement, invalidObserver, cannotComplete
        case attributeUnsupported, actionUnsupported, notificationUnsupported, notImplemented
        case notificationAlreadyRegistered, notificationNotRegistered, apiDisabled, noValue
        case parameterizedAttributeUnsupported, notEnoughPrecision, other
        init(_ status: AXError) {
            // AXError.h's fixed SDK codes. Unknown codes remain a closed case.
            switch status.rawValue {
            case 0: self = .success
            case -25200: self = .failure
            case -25201: self = .illegalArgument
            case -25202: self = .invalidElement
            case -25203: self = .invalidObserver
            case -25204: self = .cannotComplete
            case -25205: self = .attributeUnsupported
            case -25206: self = .actionUnsupported
            case -25207: self = .notificationUnsupported
            case -25208: self = .notImplemented
            case -25209: self = .notificationAlreadyRegistered
            case -25210: self = .notificationNotRegistered
            case -25211: self = .apiDisabled
            case -25212: self = .noValue
            case -25213: self = .parameterizedAttributeUnsupported
            case -25214: self = .notEnoughPrecision
            default: self = .other
            }
        }
    }
    enum MetadataValueType: String, Sendable, Codable, CaseIterable {
        case notApplicable, missing, string, boolean, number, array, element, axValue, other
        init(_ value: CFTypeRef?) {
            guard let value else { self = .missing; return }
            switch CFGetTypeID(value) {
            case CFStringGetTypeID(): self = .string
            case CFBooleanGetTypeID(): self = .boolean
            case CFNumberGetTypeID(): self = .number
            case CFArrayGetTypeID(): self = .array
            case AXUIElementGetTypeID(): self = .element
            case AXValueGetTypeID(): self = .axValue
            default: self = .other
            }
        }
    }
    enum PolicyFailureDomain: String, Sendable, Codable { case exactUnsent, policy, phase, observer, controller, scope, read, cancellation, budget, unknown }
    enum PolicyFailureCode: String, Sendable, Codable {
        case protectedContext, incomplete, unavailable, changedContext, dedicatedContext, expired
        case inactiveSession, stopped, busy, staleRequest, ambiguousApplication, unavailableWindow
        case missingExclusiveApplication, multipleExclusiveApplications, changedExclusiveApplication
        case changedTarget, malformedHeader, wrongApplication, wrongWindow, nativeError, noUsableState
        case staleObservation, consumed, wrongOwner, invalidAction, unqualifiedEffect, changedPixels
        case changedFocus, unavailableFocus, invalidImage, conflictingRequest
        case staleTask, staleProposal, duplicateAttempt, reviewDeclined, protectedEffect
        case dedicatedWorkflow, unavailableDependency, noInput
        case inactiveTask, invalidApplication, noObservation, changedObservation, consumedTurn
        case unavailableOriginalRead, unqualifiedMutation, invalidProtocolHistory, unadmittedApplication
        case changedOriginal, revoked, wrongTask, invalidLiteral, wrongMessage
        case acknowledgmentBridgeUnavailable, directAdapterUnavailable, alreadyPrepared
        case cancelled, activeWork, lifetime, unknown
    }
    struct PolicyFailure: Sendable, Codable, Equatable {
        let domain: PolicyFailureDomain
        let code: PolicyFailureCode
    }

    struct MetadataDiagnostic: Sendable, Codable, Equatable {
        let phase: MetadataPhase
        let origin: MetadataOrigin
        let attribute: MetadataAttribute
        let role: MetadataRole
        let status: MetadataStatus
        let valueType: MetadataValueType
        let advertised: Bool?
        let failure: PolicyFailure?
        init(phase: MetadataPhase, origin: MetadataOrigin, attribute: MetadataAttribute,
             role: MetadataRole, status: MetadataStatus, valueType: MetadataValueType,
             advertised: Bool?, failure: PolicyFailure? = nil) {
            self.phase = phase; self.origin = origin; self.attribute = attribute; self.role = role
            self.status = status; self.valueType = valueType; self.advertised = advertised; self.failure = failure
        }
    }
    struct MetadataBuffer: Sendable {
        static let maximumSamples = 64
        private(set) var samples: [MetadataDiagnostic] = []
        private(set) var omitted = 0
        mutating func append(_ diagnostic: MetadataDiagnostic) {
            if samples.count < Self.maximumSamples { samples.append(diagnostic) }
            else if omitted < Int.max { omitted += 1 }
        }
    }

    @MainActor static func incompleteMetadata(_ audit: NativeReadAudit?,
        _ diagnostic: @autoclosure () -> MetadataDiagnostic) {
        guard let audit else { return }
        // Lazy construction preserves nil-audit behavior and performs no AX IO.
        audit.sink(Sample(stage: .policyMetadataIncompleteReason, elapsed: .zero, metadata: diagnostic()))
    }
    enum WindowMembershipEvent: Sendable { case missing, verified, refused }
    @MainActor static func recordWindowMembership(_ audit: NativeReadAudit?, event: WindowMembershipEvent,
        use: NativeWindowParentMembership.Use, phase: MetadataPhase, role: String,
        failure: NativeWindowParentMembership.Failure? = nil) {
        guard let audit else { return }
        let stage: Stage
        switch event {
        case .missing: stage = .policyWindowMembershipAttempt
        case .verified: stage = .policyWindowMembershipVerified
        case .refused: stage = .policyWindowMembershipRefused
        }
        let origin: MetadataOrigin
        switch failure {
        case .some(.cycle): origin = .windowParentCycle
        case .some(.nodeBound): origin = .windowParentNodeBound
        case .some(.childBound): origin = .windowParentChildBound
        case .some(.missingChild): origin = .windowParentMissingChild
        case .some(.duplicateChild): origin = .windowParentDuplicateChild
        case .some(.changedParent): origin = .windowParentChangedParent
        case .some(.changedRole): origin = .windowParentChangedRole
        case .some(.invalidWindowRole): origin = .windowParentInvalidWindowRole
        case .some(.unexpectedRoot): origin = .windowParentUnexpectedRoot
        default:
            switch (event, use) {
            case (.missing, .surveyRow): origin = .windowMissingSurvey
            case (.missing, .terminalChildren): origin = .windowMissingTerminal
            case (.verified, .surveyRow): origin = .windowVerifiedSurvey
            case (.verified, .terminalChildren): origin = .windowVerifiedTerminal
            case (.refused, .surveyRow): origin = .windowRefusedSurvey
            case (.refused, .terminalChildren): origin = .windowRefusedTerminal
            }
        }
        // This describes the actual missing shortcut and its alternate proof,
        // never an extra AX query, private value or reusable admission token.
        audit.sink(Sample(stage: stage, elapsed: .zero, metadata: .init(phase: phase, origin: origin,
            attribute: .windowRequired, role: .init(role), status: .noValue, valueType: .missing, advertised: nil)))
    }

    @MainActor func recordSurveyMismatch(origin: MetadataOrigin, role: String?) {
        sink(Sample(stage: .policySurveyMismatch, elapsed: .zero,
            metadata: .init(phase: .revalidation, origin: origin, attribute: .structural,
                role: role.map { MetadataRole($0) } ?? .unclassified,
                status: .notApplicable, valueType: .notApplicable, advertised: nil)))
    }

    private let sink: @Sendable (Sample) -> Void
    init(sink: @escaping @Sendable (Sample) -> Void) { self.sink = sink }
    func record(_ stage: Stage, since start: ContinuousClock.Instant) {
        sink(Sample(stage: stage, elapsed: start.duration(to: .now)))
    }
    /// Error VALUES and descriptions never enter diagnostics; only this fixed table does.
    @MainActor static func classifyPolicyFailure(_ error: any Error) -> PolicyFailure {
        if let failure = error as? NativeOrdinaryWindowPolicySource.Failure {
            let code: PolicyFailureCode = switch failure {
            case .protectedContext: .protectedContext
            case .incomplete: .incomplete
            case .unavailable: .unavailable
            case .changedContext: .changedContext
            case .dedicatedContext: .dedicatedContext
            }
            return .init(domain: .policy, code: code)
        }
        if error is NativeMetadataPhase.Failure { return .init(domain: .phase, code: .expired) }
        if let failure = error as? TargetBoundNativeObservation.Failure {
            let code: PolicyFailureCode = switch failure {
            case .inactiveSession: .inactiveSession
            case .stopped: .stopped
            case .busy: .busy
            case .staleRequest: .staleRequest
            case .ambiguousApplication: .ambiguousApplication
            case .missingExclusiveApplication: .missingExclusiveApplication
            case .multipleExclusiveApplications: .multipleExclusiveApplications
            case .changedExclusiveApplication: .changedExclusiveApplication
            case .unavailableWindow: .unavailableWindow
            case .changedTarget: .changedTarget
            case .malformedHeader: .malformedHeader
            case .wrongApplication: .wrongApplication
            case .wrongWindow: .wrongWindow
            case .nativeError: .nativeError
            case .noUsableState: .noUsableState
            }
            return .init(domain: .observer, code: code)
        }
        if let failure = error as? NativeControlSession.Failure {
            let code: PolicyFailureCode = switch failure {
            case .inactiveSession: .inactiveSession
            case .stopped: .stopped
            case .staleObservation: .staleObservation
            case .consumed: .consumed
            case .wrongOwner: .wrongOwner
            case .invalidAction: .invalidAction
            case .unqualifiedEffect: .unqualifiedEffect
            case .changedPixels: .changedPixels
            case .changedFocus: .changedFocus
            case .unavailableFocus: .unavailableFocus
            case .invalidImage: .invalidImage
            case .busy: .busy
            case .conflictingRequest: .conflictingRequest
            }
            return .init(domain: .controller, code: code)
        }
        if let failure = error as? NativeVisualTaskFailure {
            let code: PolicyFailureCode = switch failure {
            case .stopped: .stopped
            case .staleTask: .staleTask
            case .staleProposal: .staleProposal
            case .duplicateAttempt: .duplicateAttempt
            case .reviewDeclined: .reviewDeclined
            case .protectedEffect: .protectedEffect
            case .dedicatedWorkflow: .dedicatedWorkflow
            case .unavailableDependency: .unavailableDependency
            case .noInput: .noInput
            }
            return .init(domain: .scope, code: code)
        }
        if let failure = error as? NativeWindowTaskAdapter.Failure {
            let code: PolicyFailureCode = switch failure {
            case .inactiveTask: .inactiveTask
            case .stopped: .stopped
            case .busy: .busy
            case .invalidApplication: .invalidApplication
            case .noObservation: .noObservation
            case .changedObservation: .changedObservation
            case .consumedTurn: .consumedTurn
            case .wrongOwner: .wrongOwner
            case .unavailableOriginalRead: .unavailableOriginalRead
            case .unqualifiedMutation: .unqualifiedMutation
            case .invalidProtocolHistory: .invalidProtocolHistory
            case .unadmittedApplication: .unadmittedApplication
            }
            return .init(domain: .read, code: code)
        }
        if let failure = error as? NativeExactUnsentFailure {
            let code: PolicyFailureCode = switch failure {
            case .unavailable: .unavailable
            case .changedOriginal: .changedOriginal
            case .protectedContext: .protectedContext
            case .revoked: .revoked
            case .wrongTask: .wrongTask
            case .invalidLiteral: .invalidLiteral
            case .wrongMessage: .wrongMessage
            case .acknowledgmentBridgeUnavailable: .acknowledgmentBridgeUnavailable
            case .directAdapterUnavailable: .directAdapterUnavailable
            case .alreadyPrepared: .alreadyPrepared
            }
            return .init(domain: .exactUnsent, code: code)
        }
        if let failure = error as? DesktopApplicationTarget.MetadataProcessFailure {
            switch failure {
            case .changed: return .init(domain: .observer, code: .changedTarget)
            case .expired: return .init(domain: .phase, code: .expired)
            }
        }
        if error is CancellationError { return .init(domain: .cancellation, code: .cancelled) }
        if let failure = error as? TaskRunBudget.Limit {
            switch failure {
            case .activeWork: return .init(domain: .budget, code: .activeWork)
            case .lifetime: return .init(domain: .budget, code: .lifetime)
            }
        }
        return .init(domain: .unknown, code: .unknown)
    }

    @MainActor static func recordPhaseFailure(_ audit: NativeReadAudit?, origin: MetadataOrigin, error: any Error) {
        guard let audit else { return }
        audit.sink(Sample(stage: .policyMetadataPhaseFailure, elapsed: .zero,
            metadata: .init(phase: .synchronousPhase, origin: origin, attribute: .structural,
                role: .unclassified, status: .notApplicable, valueType: .notApplicable,
                advertised: nil, failure: classifyPolicyFailure(error))))
    }

    @MainActor static func inspectPolicy<Value>(_ audit: NativeReadAudit?, operation: () throws -> Value) rethrows -> Value {
        guard let audit else { return try operation() }
        let started = ContinuousClock.now
        do { return try operation() }
        catch {
            let stage: Stage
            switch error as? NativeOrdinaryWindowPolicySource.Failure {
            case .some(.protectedContext): stage = .policyProtectedRefusal
            case .some(.incomplete): stage = .policyIncompleteRefusal
            case .some(.unavailable): stage = .policyUnavailableRefusal
            case .some(.changedContext): stage = .policyChangedContextRefusal
            case .some(.dedicatedContext): stage = .policyDedicatedRefusal
            case nil: stage = .policyOtherRefusal
            }
            if stage == .policyOtherRefusal {
                // Preserve the existing stage/count and rethrow the original error.
                audit.sink(Sample(stage: stage, elapsed: started.duration(to: .now),
                    metadata: .init(phase: .synchronousPhase, origin: .policyInspectionRefusal,
                        attribute: .structural, role: .unclassified, status: .notApplicable,
                        valueType: .notApplicable, advertised: nil, failure: classifyPolicyFailure(error))))
            } else { audit.record(stage, since: started) }
            throw error
        }
    }
    static func measure<Value>(_ audit: NativeReadAudit?, _ stage: Stage, operation: () throws -> Value) rethrows -> Value {
        guard let audit else { return try operation() }
        let started = ContinuousClock.now
        defer { audit.record(stage, since: started) }
        return try operation()
    }
}
