import Foundation
import Testing
@testable import Relay

/// Actual read/task wrappers and opaque admissions, with inert process facts.
/// These cannot create a genuine saved ACK, application binding or live lease.
@MainActor @Suite struct NativeAcknowledgedMetadataAdmissionTests {
    private enum Refusal: Error, Equatable { case custom }
    private func identity() -> DesktopApplicationIdentity {
        .init(processID: 991, launchedAt: Date(timeIntervalSince1970: 991),
            bundleID: "test.opaque.metadata", bundleURL: URL(fileURLWithPath: "/Applications/Opaque.app"))
    }

    @Test func aCallerSuccessClosureCannotMintASealedApplicationMetadataLease() throws {
        var full = 0, metadataBodies = 0
        let admission = NativeWindowTaskAdapter.ApplicationAdmission(application: identity(), validate: { full += 1 })
        #expect(!admission.hasSealedMetadataApplicationAdmission)
        for _ in 0..<1_100 { try admission.validate() }
        #expect(full == 1_100)
        #expect(throws: NativeWindowTaskAdapter.Failure.unadmittedApplication) {
            try admission.withMetadataLease { _ in metadataBodies += 1 }
        }
        #expect(metadataBodies == 0 && full == 1_100)
    }

    @Test func actualReadOwnerRetainsEveryOpaqueValidatorAndNeverPromotesItToTheSealedRoute() throws {
        var current = true, allow = true, full = 0, resolves = 0
        let expected = identity()
        let owner = NativeLocalTaskReadAuthority.localUserInvocation(taskID: UUID(), taskIsCurrent: { current }, resolve: { _ in
            resolves += 1
            return .init(application: expected, validate: {
                full += 1
                guard allow else { throw Refusal.custom }
            })
        })
        let admitted = try owner.admit(expected.bundleID)
        #expect(!admitted.hasSealedMetadataApplicationAdmission)
        let before = full
        for _ in 0..<1_100 { try admitted.validate() }
        #expect(full == before + 1_100 && resolves == 1)
        allow = false
        #expect(throws: Refusal.custom) { try admitted.validate() }
        let afterRefusal = full
        current = false
        #expect(throws: NativeWindowTaskAdapter.Failure.inactiveTask) { try admitted.validate() }
        #expect(full == afterRefusal && resolves == 1)
    }

    @Test func chainedActualReadOwnersKeepBothLivePredicatesAndTheOriginalCustomPolicy() throws {
        var firstCurrent = true, secondCurrent = true, full = 0, firstChecks = 0, secondChecks = 0
        let expected = identity()
        let first = NativeLocalTaskReadAuthority.localUserInvocation(taskID: UUID(), taskIsCurrent: {
            firstChecks += 1; return firstCurrent
        }, restrictions: [.init(application: expected, validate: { full += 1 })])
        let original = try first.admit(expected.bundleID)
        let second = NativeLocalTaskReadAuthority.localUserInvocation(taskID: UUID(), taskIsCurrent: {
            secondChecks += 1; return secondCurrent
        }, restrictions: [original])
        let wrapped = try second.admit(expected.bundleID)
        #expect(!wrapped.hasSealedMetadataApplicationAdmission)
        let f = firstChecks, s = secondChecks, n = full
        try wrapped.validate()
        #expect(firstChecks == f + 1 && secondChecks == s + 1 && full == n + 1)
        firstCurrent = false
        #expect(throws: NativeWindowTaskAdapter.Failure.inactiveTask) { try wrapped.validate() }
        #expect(full == n + 1)
        firstCurrent = true; secondCurrent = false
        let lastFirst = firstChecks
        #expect(throws: NativeWindowTaskAdapter.Failure.inactiveTask) { try wrapped.validate() }
        #expect(firstChecks == lastFirst && full == n + 1)
    }

    @Test func aRetainedAdmissionCannotKeepItsOriginalReadOwnerAlive() throws {
        let expected = identity()
        var owner: NativeLocalTaskReadAuthority? = .localUserInvocation(taskID: UUID(), taskIsCurrent: { true },
            restrictions: [.init(application: expected, validate: {})])
        weak var original = owner
        let admitted = try #require(owner).admit(expected.bundleID)
        owner = nil
        #expect(original == nil)
        #expect(throws: NativeWindowTaskAdapter.Failure.inactiveTask) { try admitted.validate() }
        #expect(!admitted.hasSealedMetadataApplicationAdmission)
    }

    @Test func taskCancellationRefusesBeforeTheOpaquePolicyRunsAgain() async throws {
        let expected = identity(); var full = 0
        let owner = NativeLocalTaskReadAuthority.localUserInvocation(taskID: UUID(), taskIsCurrent: { true },
            restrictions: [.init(application: expected, validate: { full += 1 })])
        let admitted = try owner.admit(expected.bundleID), before = full
        let work = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try admitted.validate() }
        }
        await work.value
        #expect(full == before)
    }
}
