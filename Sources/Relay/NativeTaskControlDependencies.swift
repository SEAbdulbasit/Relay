import ApplicationServices
import Foundation

/// Trusted app composition, never a model argument.
@MainActor struct NativeTaskControlDependencies {
    typealias Make = @MainActor (NativeVisualTaskScope, NativeLocalTaskInputAuthority) throws -> NativeTaskControlDependencies
    nonisolated static let enabledPreference = "nativeWindowControl.enabled"
    let factory: NativeVisualTaskConnectionFactory
    let inspect: NativeOrdinaryVisualPolicy.Inspect

    static let unavailable = NativeTaskControlDependencies(factory: .unavailable, inspect: { _, _ in
        throw NativeVisualTaskFailure.unavailableDependency("qualified ordinary semantic inspection")
    })

    static func appControl(scope: NativeVisualTaskScope,
                           inputAuthority: NativeLocalTaskInputAuthority) throws -> Self {
        try appControl(
            scope: scope,
            inputAuthority: inputAuthority,
            defaults: .standard,
            isAccessibilityTrusted: { AXIsProcessTrusted() }
        )
    }

    static func appControl(scope: NativeVisualTaskScope,
                           inputAuthority: NativeLocalTaskInputAuthority,
                           defaults: UserDefaults,
                           isAccessibilityTrusted: @escaping @Sendable () -> Bool) throws -> Self {
        guard isAppControlAllowed(defaults: defaults, isAccessibilityTrusted: isAccessibilityTrusted) else {
            return .unavailable
        }
        return try productionCandidate(scope: scope, inputAuthority: inputAuthority, validateAvailability: {
            guard isAppControlAllowed(defaults: defaults, isAccessibilityTrusted: isAccessibilityTrusted) else {
                throw NativeVisualTaskFailure.stopped
            }
        })
    }

    nonisolated static func isPreferenceEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard let stored = defaults.object(forKey: enabledPreference) else {
            return true
        }
        if let flag = stored as? Bool {
            return flag
        }
        if let number = stored as? NSNumber {
            return number.boolValue
        }
        return defaults.bool(forKey: enabledPreference)
    }

    nonisolated static func isAppControlAllowed(
        defaults: UserDefaults = .standard,
        isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    ) -> Bool {
        isPreferenceEnabled(defaults: defaults) && isAccessibilityTrusted()
    }

    static var isCurrentlyAvailable: Bool {
        isAppControlAllowed()
    }

    /// Real client/controller/window-policy composition. There is no fixture
    /// app allowlist, alternate executor or model-provided safety assertion.
    static func productionCandidate(scope: NativeVisualTaskScope,
                                    inputAuthority: NativeLocalTaskInputAuthority,
                                    readAudit: NativeReadAudit? = nil,
                                    processStarted: (@Sendable (OwnedNativeComputerUseClient.ProcessStarted) throws -> Void)? = nil,
                                    validateAvailability: @escaping @MainActor () throws -> Void = {}) throws -> NativeTaskControlDependencies {
        let production = try NativeProductionTaskConnectionFactory(scope: scope, inputAuthority: inputAuthority,
            readAudit: readAudit, processStarted: processStarted, validateAvailability: validateAvailability)
        let inspector = NativeOrdinarySemanticInspector(authority: inputAuthority,
            target: { try production.policyTarget($0) })
        return NativeTaskControlDependencies(factory: .init(missingDependencies: [], open: { candidateScope, policy in
            guard candidateScope === scope else { throw NativeVisualTaskFailure.staleTask }
            return try await production.open(policy: policy)
        }), inspect: { context, candidateScope in try inspector.inspect(context, scope: candidateScope) })
    }
}
