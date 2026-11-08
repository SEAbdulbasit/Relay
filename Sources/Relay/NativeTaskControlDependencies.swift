import Foundation

/// Trusted app composition, never a model argument. Active Relay does not pass
/// the production candidate until its complete factory/policy/UI gates pass.
@MainActor struct NativeTaskControlDependencies {
    typealias Make = @MainActor (NativeVisualTaskScope, NativeLocalTaskInputAuthority) throws -> NativeTaskControlDependencies
    let factory: NativeVisualTaskConnectionFactory
    let inspect: NativeOrdinaryVisualPolicy.Inspect

    static let unavailable = NativeTaskControlDependencies(factory: .unavailable, inspect: { _, _ in
        throw NativeVisualTaskFailure.unavailableDependency("qualified ordinary semantic inspection")
    })

    /// Real client/controller/window-policy composition. There is no fixture
    /// app allowlist, alternate executor or model-provided safety assertion.
    static func productionCandidate(scope: NativeVisualTaskScope,
                                    inputAuthority: NativeLocalTaskInputAuthority) throws -> NativeTaskControlDependencies {
        let production = try NativeProductionTaskConnectionFactory(scope: scope, inputAuthority: inputAuthority)
        let inspector = NativeOrdinarySemanticInspector(authority: inputAuthority,
            target: { try production.policyTarget($0) })
        return NativeTaskControlDependencies(factory: .init(missingDependencies: [], open: { candidateScope, policy in
            guard candidateScope === scope else { throw NativeVisualTaskFailure.staleTask }
            return try await production.open(policy: policy)
        }), inspect: { context, candidateScope in try inspector.inspect(context, scope: candidateScope) })
    }
}
