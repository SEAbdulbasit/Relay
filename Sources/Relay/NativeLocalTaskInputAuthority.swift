import Foundation

/// The app creates this live capability only after its local submission is
/// acknowledged. Source text, model risk labels, history and tool selection
/// cannot recreate it or turn an app-scoped task into a pinned-window task.
@MainActor final class NativeLocalTaskInputAuthority {
    enum WindowRequirement {
        case appScoped
        /// This exact in-memory source belongs to its original session. Until
        /// an actual transferable anchor exists, a new owner must refuse it.
        case pinned(NativeControlSession.OriginalSource)
        /// Initial same-invocation identity only. Its real saved-message bridge
        /// and direct effect adapter are deliberately unavailable in slice one.
        case initialExactUnsent(NativeExactUnsentPurpose)
    }
    let scope: NativeVisualTaskScope
    let windowRequirement: WindowRequirement
    let metadataContext: AssistantStore.ExactUnsentSavedInvocation.MetadataContext?
    private let validateAcknowledgedInputGrant: @MainActor () throws -> Void
    private var initialMetadataSettled = false

    private init(scope: NativeVisualTaskScope, windowRequirement: WindowRequirement,
                 metadataContext: AssistantStore.ExactUnsentSavedInvocation.MetadataContext? = nil,
                 validateAcknowledgedInputGrant: @escaping @MainActor () throws -> Void) {
        self.scope = scope; self.windowRequirement = windowRequirement
        self.metadataContext = metadataContext
        self.validateAcknowledgedInputGrant = validateAcknowledgedInputGrant
    }

    /// Trusted UI/Store invocation code supplies its actual live local input
    /// contract. There is no default true grant and no app-name allowlist.
    static func localUserInvocation(scope: NativeVisualTaskScope, windowRequirement: WindowRequirement,
                                    validateAcknowledgedInputGrant: @escaping @MainActor () throws -> Void) throws -> NativeLocalTaskInputAuthority {
        let authority = NativeLocalTaskInputAuthority(scope: scope, windowRequirement: windowRequirement,
            validateAcknowledgedInputGrant: validateAcknowledgedInputGrant)
        try authority.validate()
        return authority
    }

    /// This factory accepts only the real Store context already bound to the
    /// direct scope. The original input grant has no caller-supplied callback.
    static func directExactUnsentInvocation(scope: NativeVisualTaskScope,
        windowRequirement: WindowRequirement) throws -> NativeLocalTaskInputAuthority {
        guard let context = scope.metadataContext else { throw NativeVisualTaskFailure.staleTask }
        if case .pinned = windowRequirement { throw NativeVisualTaskFailure.staleTask }
        let authority = NativeLocalTaskInputAuthority(scope: scope, windowRequirement: windowRequirement,
            metadataContext: context, validateAcknowledgedInputGrant: { try context.validateInputGrant() })
        try authority.validate()
        return authority
    }

    func markInitialMetadataSettled() {
        initialMetadataSettled = true
    }

    func exactUnsentSessionLiveness() -> @MainActor () -> Bool {
        return { [weak self] in
            guard let self else { return false }
            if self.initialMetadataSettled {
                return (try? self.validateMetadataOwner()) != nil
            }
            return (try? self.validate()) != nil
        }
    }

    func validate() throws {
        try scope.validate(); try validateAcknowledgedInputGrant(); try scope.validate()
        if case .initialExactUnsent(let purpose) = windowRequirement { try purpose.validateCurrent(scope: scope) }
    }
    /// Known revocation/ACK ownership only for this direct task's synchronous
    /// metadata scan and observer liveness. The actual bound application
    /// admission and observer reference STILL check the live process on every
    /// metadata query; strong private/input/source boundaries use validate().
    func validateMetadataOwner() throws {
        guard scope.executionKind == .directExactUnsent,
              case .initialExactUnsent(let purpose) = windowRequirement else {
            try validate(); return
        }
        try validateAcknowledgedInputGrant()
        try purpose.validateMetadataOwner(scope: scope)
    }
    func admit(_ application: NativeWindowTaskAdapter.ApplicationAdmission) throws {
        try validate(); try application.validate()
        if case .initialExactUnsent(let purpose) = windowRequirement { try purpose.validateApplication(application.application) }
        let original = try scope.admitRead(application.application.bundleID)
        guard original.application == application.application else { throw NativeVisualTaskFailure.staleTask }
        try original.validate(); try validate()
    }
    func authorizeMetadata(_ target: NativeOriginalPolicyTarget) throws {
        try validate(); try target.validateSource()
        if case .initialExactUnsent(let purpose) = windowRequirement { try purpose.validateApplication(target.application) }
        let application = try scope.admitRead(target.application.bundleID)
        guard application.application == target.application else { throw NativeVisualTaskFailure.staleTask }
        try application.validate(); try target.validateSource(); try validate()
    }
    /// Scope only: call ONLY inside the actual reader's original-source bracket.
    /// Independent private-query admission continues to use authorizeMetadata.
    func authorizeMetadataScope(_ identity: DesktopApplicationIdentity) throws {
        try validate()
        if case .initialExactUnsent(let purpose) = windowRequirement { try purpose.validateApplication(identity) }
        let application = try scope.admitRead(identity.bundleID)
        guard application.application == identity else { throw NativeVisualTaskFailure.staleTask }
        try application.validate(); try validate()
    }
    func inspect(_ target: NativeOriginalPolicyTarget) throws -> NativeOrdinaryWindowPolicySource.Facts {
        try target.inspectMetadata(authorizeMetadata: { try self.authorizeMetadataScope(target.application) },
            metadataScope: metadataScopeBinding(for: target.application))
    }

    func metadataScopeBinding(for application: DesktopApplicationIdentity) -> NativeMetadataScopeBinding {
        .inputRequired(self, application: application)
    }
    fileprivate var hasSealedMetadataApplicationAdmission: Bool {
        guard scope.executionKind == .directExactUnsent,
              case .initialExactUnsent(let purpose) = windowRequirement else { return false }
        return purpose.hasSealedMetadataApplicationAdmission
    }

    /// This is called BEFORE the controller captures focused labels, values,
    /// selections or style, not after a model has already received them. The
    /// controller invokes the returned fence around each composite read and
    /// revalidates its actual editor/source/image preview around inference.
    func privateEditorPlanningGrant(for target: NativeOriginalPolicyTarget) throws -> @MainActor () throws -> Void {
        let original = try inspect(target)
        try original.admitPrivateEditorPlanning()
        return {
            try self.authorizeMetadata(target)
            let current = try self.inspect(target)
            try current.admitPrivateEditorPlanning()
            guard current.sourceID == original.sourceID, current.application == original.application,
                  current.digest == original.digest else { throw NativeOrdinaryWindowPolicySource.Failure.changedContext }
        }
    }
}

/// A factory tied to an actual live owner, not a cached authorization verdict.
/// Only a synchronous metadata phase may hold its returned authorization.
@MainActor final class NativeMetadataScopeBinding {
    private enum Owner { case inputRequired, controlRead }
    private let owner: Owner
    private weak var inputAuthority: NativeLocalTaskInputAuthority?
    private weak var controlReadFactory: NativeProductionTaskConnectionFactory?
    let application: DesktopApplicationIdentity

    private init(input: NativeLocalTaskInputAuthority, application: DesktopApplicationIdentity) {
        owner = .inputRequired; inputAuthority = input; self.application = application
    }
    private init(controlRead: NativeProductionTaskConnectionFactory, application: DesktopApplicationIdentity) {
        owner = .controlRead; controlReadFactory = controlRead; self.application = application
    }
    fileprivate static func inputRequired(_ authority: NativeLocalTaskInputAuthority,
                                          application: DesktopApplicationIdentity) -> NativeMetadataScopeBinding {
        .init(input: authority, application: application)
    }
    static func controlRead(_ factory: NativeProductionTaskConnectionFactory,
                            application: DesktopApplicationIdentity) -> NativeMetadataScopeBinding {
        .init(controlRead: factory, application: application)
    }

    private func validateOwner() throws {
        switch owner {
        case .inputRequired:
            guard let inputAuthority else { throw NativeVisualTaskFailure.stopped }
            try inputAuthority.validateMetadataOwner()
        case .controlRead:
            guard let controlReadFactory else { throw NativeVisualTaskFailure.stopped }
            try controlReadFactory.validateControlReadMetadataOwner()
        }
    }
    func requireSealedMetadataAuthority(_ authority: NativeLocalTaskInputAuthority) throws {
        guard inputAuthority === authority, let context = authority.metadataContext,
              authority.scope.metadataContext === context else { throw NativeVisualTaskFailure.staleTask }
    }
    func markInitialMetadataSettled() {
        inputAuthority?.markInitialMetadataSettled()
    }
    private func bindApplication() throws -> NativeWindowTaskAdapter.ApplicationAdmission {
        try validateOwner()
        let admitted: NativeWindowTaskAdapter.ApplicationAdmission
        switch owner {
        case .inputRequired:
            guard let inputAuthority else { throw NativeVisualTaskFailure.stopped }
            admitted = try inputAuthority.scope.admitRead(application.bundleID)
        case .controlRead:
            guard let controlReadFactory else { throw NativeVisualTaskFailure.stopped }
            admitted = try controlReadFactory.bindControlReadMetadataApplication(application)
        }
        guard admitted.application == application else { throw NativeVisualTaskFailure.staleTask }
        try admitted.validate(); try validateOwner()
        return admitted
    }

    /// No async body, successful-result cache, replacement lookup or recovery
    /// constructor. An escaped reference is retired on every exit.
    func withAuthorization<Value>(readAudit: NativeReadAudit? = nil,
                                  _ body: @MainActor (Authorization) throws -> Value) throws -> Value {
        if inputAuthority?.hasSealedMetadataApplicationAdmission == true {
            // Only the actual ACK/original producer can supply this route.
            // Opaque/custom and general app admissions retain the old lazy
            // binding/full-per-query path below without a fast callback API.
            return try NativeReadAudit.measure(readAudit, .policyMetadataSealedScope) {
                let admitted = try bindApplication()
                guard admitted.hasSealedMetadataApplicationAdmission else { throw NativeVisualTaskFailure.staleTask }
                return try admitted.withMetadataLease { lease in
                    let authorization = Authorization(binding: self, admitted: admitted, metadataLease: lease)
                    defer { authorization.retire() }
                    try authorization.checkStrong()
                    let result = Result { try body(authorization) }
                    try authorization.checkStrong()
                    return try result.get()
                }
            }
        }
        return try NativeReadAudit.measure(readAudit, .policyMetadataOpaqueScope) {
            let authorization = Authorization(binding: self)
            defer { authorization.retire() }
            return try body(authorization)
        }
    }

    @MainActor final class Authorization {
        private enum State {
            case unbound, binding, bound(NativeWindowTaskAdapter.ApplicationAdmission)
            case refused(any Error), retired
        }
        private weak var binding: NativeMetadataScopeBinding?
        private var state: State = .unbound
        private var checking = false
        private var metadataLease: NativeWindowTaskAdapter.ApplicationAdmission.MetadataLease?
        fileprivate init(binding: NativeMetadataScopeBinding) { self.binding = binding }
        fileprivate init(binding: NativeMetadataScopeBinding, admitted: NativeWindowTaskAdapter.ApplicationAdmission,
                         metadataLease: NativeWindowTaskAdapter.ApplicationAdmission.MetadataLease) {
            self.binding = binding; self.metadataLease = metadataLease; state = .bound(admitted)
        }
        fileprivate func retire() { state = .retired; binding = nil; metadataLease = nil }
        fileprivate func checkStrong() throws {
            if case .retired = state { throw NativeMetadataPhase.Failure.expired }
            guard !checking else { state = .refused(NativeVisualTaskFailure.staleTask); throw NativeVisualTaskFailure.staleTask }
            checking = true; defer { checking = false }
            guard let binding, case .bound(let admitted) = state else { throw NativeVisualTaskFailure.staleTask }
            try Task.checkCancellation()
            try binding.validateOwner(); try admitted.validate(); try binding.validateOwner()
            guard case .bound = state else { throw NativeVisualTaskFailure.staleTask }
            try Task.checkCancellation()
        }

        var canShareCurrentProcessQuery: Bool {
            guard !checking, binding != nil, metadataLease != nil else { return false }
            if case .bound = state { return true }
            return false
        }
        func requireSealedMetadataAuthority(_ authority: NativeLocalTaskInputAuthority) throws {
            guard let binding, case .bound = state, metadataLease != nil else {
                throw NativeVisualTaskFailure.staleTask
            }
            try binding.requireSealedMetadataAuthority(authority)
        }
        func requireSealedProcess(authority: NativeLocalTaskInputAuthority, purpose: NativeExactUnsentPurpose,
                                  context: AssistantStore.ExactUnsentSavedInvocation.MetadataContext,
                                  currentQuery: DesktopApplicationTarget.MetadataProcessLease.QueryWitness) throws {
            try requireSealedMetadataAuthority(authority)
            guard let metadataLease, authority.metadataContext === context,
                  case .initialExactUnsent(let actualPurpose) = authority.windowRequirement,
                  actualPurpose === purpose else { throw NativeVisualTaskFailure.staleTask }
            try metadataLease.requireSealedProcess(purpose: purpose, scope: authority.scope, context: context, currentQuery: currentQuery)
        }
        func checkSealedTechnical(authority: NativeLocalTaskInputAuthority, purpose: NativeExactUnsentPurpose,
                                  currentQuery: DesktopApplicationTarget.MetadataProcessLease.QueryWitness) throws {
            if case .retired = state { throw NativeMetadataPhase.Failure.expired }
            guard !checking else {
                state = .refused(NativeVisualTaskFailure.staleTask)
                throw NativeVisualTaskFailure.staleTask
            }
            checking = true; defer { checking = false }
            try Task.checkCancellation()
            try requireSealedMetadataAuthority(authority)
            guard let metadataLease, case .initialExactUnsent(let actualPurpose) = authority.windowRequirement,
                  actualPurpose === purpose else { throw NativeVisualTaskFailure.staleTask }
            try metadataLease.checkSealedTechnical(purpose: purpose, scope: authority.scope, currentQuery: currentQuery)
            guard case .bound = state else { throw NativeVisualTaskFailure.staleTask }
            try Task.checkCancellation()
        }
        func check(currentQuery: DesktopApplicationTarget.MetadataProcessLease.QueryWitness? = nil) throws {
            if case .retired = state { throw NativeMetadataPhase.Failure.expired }
            guard !checking else {
                state = .refused(NativeVisualTaskFailure.staleTask)
                throw NativeVisualTaskFailure.staleTask
            }
            checking = true; defer { checking = false }
            guard let binding else { throw NativeVisualTaskFailure.stopped }
            switch state {
            case .unbound:
                // Mark before any caller/producer work. Entry failure or a
                // reentrant check cannot resolve a second application on exit.
                state = .binding
                do {
                    try Task.checkCancellation()
                    let admitted = try binding.bindApplication()
                    guard case .binding = state else { throw NativeVisualTaskFailure.staleTask }
                    state = .bound(admitted)
                } catch {
                    state = .refused(error); throw error
                }
            case .binding:
                state = .refused(NativeVisualTaskFailure.staleTask)
                throw NativeVisualTaskFailure.staleTask
            case .refused(let error): throw error
            case .bound: break
            case .retired: throw NativeMetadataPhase.Failure.expired
            }
            guard case .bound(let admitted) = state else { throw NativeVisualTaskFailure.staleTask }
            try Task.checkCancellation()
            try binding.validateOwner()
            if let metadataLease { try metadataLease.check(currentQuery: currentQuery) }
            else { try admitted.validate() }
            try binding.validateOwner()
            guard case .bound = state else { throw NativeVisualTaskFailure.staleTask }
            try Task.checkCancellation()
        }
    }
}
