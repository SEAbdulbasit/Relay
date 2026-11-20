import Foundation
import Testing
@testable import Relay

/// Actual-used pure orchestration/comparison only. No NSRunningApplication,
/// process binding, positive witness, ACK, AX source or permission is fabricated.
@MainActor @Suite struct NativeMetadataProcessQueryTests {
    private typealias Scope = DesktopApplicationTarget.MetadataQueryScope
    private typealias Key = DesktopApplicationTarget.MetadataQueryKey
    private final class Sentinel: Error, @unchecked Sendable {}

    @Test(arguments: ["owner", "session", "source"])
    func changedObserverIdentityRefusesAnAggregateBeforeItsTechnicalBody(_ field: String) throws {
        typealias Identity = TargetBoundNativeObservation.MetadataLeaseIdentity
        let original = Identity(owner: UUID(), session: UUID(), sourceID: UUID())
        let changed = Identity(owner: field == "owner" ? UUID() : original.owner,
            session: field == "session" ? UUID() : original.session,
            sourceID: field == "source" ? UUID() : original.sourceID)
        let scope = Scope()
        var technical = 0
        #expect(throws: TargetBoundNativeObservation.Failure.staleRequest) {
            try scope.run(before: { try original.requireSame(as: changed) }, after: {}) { _ in technical += 1 }
        }
        #expect(technical == 0)
    }

    @Test func changedObserverSessionOnExitRefusesBeforeSurveyReadAndRetiresItsProof() throws {
        typealias Identity = TargetBoundNativeObservation.MetadataLeaseIdentity
        let original = Identity(owner: UUID(), session: UUID(), sourceID: UUID())
        var current = original
        let scope = Scope(), earlier = Sentinel()
        var escaped: Scope.Lifetime?, post = 0, surveyReads = 0
        #expect(throws: TargetBoundNativeObservation.Failure.staleRequest) {
            try scope.run(before: { try original.requireSame(as: current) }, after: {
                post += 1; try original.requireSame(as: current)
            }) { lifetime in
                escaped = lifetime
                current = .init(owner: original.owner, session: UUID(), sourceID: original.sourceID)
                throw earlier
            }
            surveyReads += 1
        }
        #expect(post == 1 && surveyReads == 0)
        let retired = try #require(escaped)
        #expect(throws: Scope.Failure.expired) { try retired.check() }
    }

    private func key(object: NSObject, pid: Int32 = 42, raw: String = "file:///Applications/Caf\u{e9}.app/",
                     birth: UInt64 = 7) -> Key {
        let date = Date(timeIntervalSince1970: 100)
        return .init(object: ObjectIdentifier(object), identity: .init(processID: pid, launchedAt: date,
            bundleID: "owned.synthetic", bundleURL: URL(fileURLWithPath: "/Applications/Owned.app")),
            facts: .init(processID: pid, launchedAt: date, bundleIDUTF8: Data("owned.synthetic".utf8),
                rawBundleURLUTF8: Data(raw.utf8), isFileURL: true, terminated: false), kernelStart: birth)
    }

    @Test(arguments: ["object", "process", "raw-utf8", "kernel", "zero-kernel"])
    func onlyTheSameObjectAndWholeBoundProcessFactsCanShare(_ change: String) throws {
        let object = NSObject(), other = NSObject(), original = key(object: object)
        try original.requireSame(as: key(object: object))
        let changed: Key
        switch change {
        case "object": changed = key(object: other)
        case "process": changed = key(object: object, pid: 43)
        case "raw-utf8": changed = key(object: object, raw: "file:///Applications/Cafe\u{301}.app/")
        case "kernel": changed = key(object: object, birth: 8)
        default: changed = key(object: object, birth: 0)
        }
        #expect(throws: DesktopApplicationTarget.MetadataProcessFailure.changed) { try changed.requireSame(as: original) }
    }

    @Test(arguments: [false, true])
    func bothExitsRetireAnEscapedLifetimeBeforeAnyLaterWork(_ failBody: Bool) throws {
        let scope = Scope(), original = Sentinel()
        var escaped: Scope.Lifetime?, before = 0, after = 0, body = 0
        do {
            let result = try scope.run(before: { before += 1 }, after: { after += 1 }) { lifetime in
                escaped = lifetime; try lifetime.check(); body += 1
                if failBody { throw original }
                return 42
            }
            #expect(!failBody && result == 42)
        } catch { #expect(failBody && (error as? Sentinel) === original) }
        #expect(before == 1 && after == 1 && body == 1)
        let retired = try #require(escaped)
        #expect(throws: Scope.Failure.expired) { try retired.check(); body += 1 }
        #expect(body == 1)
    }

    @Test func caughtNestedEntryPoisonsTheOuterQueryAndNeverRunsAnotherProofOrBody() throws {
        let scope = Scope()
        var before = 0, after = 0, nested = 0
        do {
            try scope.run(before: { before += 1 }, after: { after += 1 }) { lifetime in
                #expect(throws: Scope.Failure.reentrant) {
                    try scope.run(before: { nested += 1 }, after: { nested += 1 }) { _ in nested += 1 }
                }
                #expect(throws: Scope.Failure.reentrant) { try lifetime.check() }
            }
            Issue.record("A caught reentrant query returned success")
        } catch { #expect((error as? Scope.Failure) == .reentrant) }
        #expect(before == 1 && after == 1 && nested == 0)
        // The actual process lease keeps this poisoned scope; catching cannot
        // remint a fresh aggregate inside that same lexical lease.
        #expect(throws: Scope.Failure.reentrant) {
            try scope.run(before: { nested += 1 }, after: { nested += 1 }) { _ in nested += 1 }
        }
        #expect(nested == 0)
        let fresh = Scope()
        let value = try fresh.run(before: {}, after: {}) { lifetime in try lifetime.check(); return 7 }
        #expect(value == 7)
    }

    @Test func caughtMismatchedComparisonPoisonsTheActualSharedLifetimeAndLaterEntries() throws {
        let scope = Scope(), object = NSObject()
        let first = key(object: object), changed = key(object: object, birth: 8)
        var post = 0, later = 0
        do {
            try scope.run(before: {}, after: { post += 1 }) { lifetime in
                #expect(throws: DesktopApplicationTarget.MetadataProcessFailure.changed) {
                    try lifetime.validate { try changed.requireSame(as: first) }
                }
            }
            Issue.record("A caught mismatched process query returned success")
        } catch { #expect((error as? DesktopApplicationTarget.MetadataProcessFailure) == .changed) }
        #expect(post == 1)
        #expect(throws: DesktopApplicationTarget.MetadataProcessFailure.changed) {
            try scope.run(before: { later += 1 }, after: {}) { _ in later += 1 }
        }
        #expect(later == 0)
    }

    @Test func aPostProofRefusalOverridesTheBodyErrorAndStillRetiresTheLifetime() throws {
        let scope = Scope(), body = Sentinel(), post = Sentinel()
        var escaped: Scope.Lifetime?, exits = 0
        do {
            try scope.run(before: {}, after: { exits += 1; throw post }) { lifetime in
                escaped = lifetime; throw body
            }
            Issue.record("A failed current process proof returned success")
        } catch { #expect((error as? Sentinel) === post) }
        #expect(exits == 1)
        let retired = try #require(escaped)
        #expect(throws: Scope.Failure.expired) { try retired.check() }
    }

    @Test func failedEntryNeverRunsItsBodyOrPostProofAndDoesNotLeaveAReusableLifetime() throws {
        let scope = Scope(), entry = Sentinel()
        var body = 0, after = 0
        do {
            try scope.run(before: { throw entry }, after: { after += 1 }) { _ in body += 1 }
            Issue.record("A failed initial process proof ran its body")
        } catch { #expect((error as? Sentinel) === entry) }
        #expect(body == 0 && after == 0)
        try scope.run(before: {}, after: { after += 1 }) { lifetime in try lifetime.check(); body += 1 }
        #expect(body == 1 && after == 1)
    }

    @Test func cancellationFromTheFinalProofRemainsCancellationAndRetiresTheOriginalLifetime() throws {
        let scope = Scope()
        var escaped: Scope.Lifetime?
        #expect(throws: CancellationError.self) {
            try scope.run(before: {}, after: { throw CancellationError() }) { lifetime in escaped = lifetime }
        }
        let retired = try #require(escaped)
        #expect(throws: Scope.Failure.expired) { try retired.check() }
    }
}
