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
    }
    let scope: NativeVisualTaskScope
    let windowRequirement: WindowRequirement
    private let validateAcknowledgedInputGrant: @MainActor () throws -> Void

    private init(scope: NativeVisualTaskScope, windowRequirement: WindowRequirement,
                 validateAcknowledgedInputGrant: @escaping @MainActor () throws -> Void) {
        self.scope = scope; self.windowRequirement = windowRequirement
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

    func validate() throws {
        try scope.validate(); try validateAcknowledgedInputGrant(); try scope.validate()
    }
    func admit(_ application: NativeWindowTaskAdapter.ApplicationAdmission) throws {
        try validate(); try application.validate()
        let original = try scope.admitRead(application.application.bundleID)
        guard original.application == application.application else { throw NativeVisualTaskFailure.staleTask }
        try original.validate(); try validate()
    }
    func authorizeMetadata(_ target: NativeOriginalPolicyTarget) throws {
        try validate(); try target.validateSource()
        let application = try scope.admitRead(target.application.bundleID)
        guard application.application == target.application else { throw NativeVisualTaskFailure.staleTask }
        try application.validate(); try target.validateSource(); try validate()
    }
    func inspect(_ target: NativeOriginalPolicyTarget) throws -> NativeOrdinaryWindowPolicySource.Facts {
        try target.inspectMetadata(authorizeMetadata: { try self.authorizeMetadata(target) })
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
