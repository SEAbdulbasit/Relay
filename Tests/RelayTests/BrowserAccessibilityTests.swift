import Foundation
import ApplicationServices
import Testing
@testable import Relay

@MainActor
struct BrowserAccessibilityTests {
    @MainActor private final class PreparationReference {
        weak var value: BrowserAccessibility?
    }

    private var identity: BrowserAccessibility.Identity {
        .init(processID: 4242, launchedAt: Date(timeIntervalSince1970: 1),
              bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
    }

    @Test func repeatedReadsActivateAndWaitOnlyOnceForTheSameProcessLaunch() async throws {
        var instant = ContinuousClock.now
        var activations = 0
        var waits: [Duration] = []
        let preparation = BrowserAccessibility(now: { instant }, isCurrent: { _ in true }, waitUntilReady: { _ in }, activate: { _ in activations += 1 }, wait: { duration in
            waits.append(duration)
            instant = instant.advanced(by: duration)
        })
        try await preparation.prepare(identity)
        try await preparation.prepare(identity)
        #expect(activations == 1)
        #expect(waits == [BrowserAccessibility.activationWait])
    }

    @Test func cancelledWaitKeepsTheAttemptAndUsesOnlyItsRemainingTime() async throws {
        var instant = ContinuousClock.now
        var activations = 0
        var waits: [Duration] = []
        let preparation = BrowserAccessibility(now: { instant }, isCurrent: { _ in true }, waitUntilReady: { _ in }, activate: { _ in activations += 1 }, wait: { duration in
            waits.append(duration)
            if waits.count == 1 {
                instant = instant.advanced(by: .seconds(1))
                throw CancellationError()
            }
            instant = instant.advanced(by: duration)
        })
        await #expect(throws: CancellationError.self) { try await preparation.prepare(identity) }
        try await preparation.prepare(identity)
        #expect(activations == 1)
        #expect(waits == [.milliseconds(2_100), .milliseconds(1_100)])
    }

    @Test func reusedPIDWithAnotherLaunchGetsANewActivation() async throws {
        var instant = ContinuousClock.now
        var activations = 0
        let preparation = BrowserAccessibility(now: { instant }, isCurrent: { _ in true }, waitUntilReady: { _ in }, activate: { _ in activations += 1 }, wait: { instant = instant.advanced(by: $0) })
        try await preparation.prepare(identity)
        let restarted = BrowserAccessibility.Identity(processID: identity.processID, launchedAt: identity.launchedAt.addingTimeInterval(1), bundleURL: identity.bundleURL)
        try await preparation.prepare(restarted)
        #expect(activations == 2)
    }

    @Test func changedProcessAfterAwaitRefusesTheReadinessResult() async throws {
        var current = true
        let preparation = BrowserAccessibility(isCurrent: { _ in current }, waitUntilReady: { _ in }, activate: { _ in }, wait: { _ in current = false })
        await #expect(throws: (any Error).self) { try await preparation.prepare(identity) }
    }

    @Test func failedColdWindowReadinessDoesNotActivateOrCacheARequest() async throws {
        var instant = ContinuousClock.now
        var readyChecks = 0
        var activations = 0
        let preparation = BrowserAccessibility(now: { instant }, isCurrent: { _ in true }, waitUntilReady: { _ in
            readyChecks += 1
            if readyChecks == 1 { throw BrowserAccessibility.Failure.applicationNotReady }
        }, activate: { _ in activations += 1 }, wait: { instant = instant.advanced(by: $0) })
        await #expect(throws: BrowserAccessibility.Failure.self) { try await preparation.prepare(identity) }
        #expect(activations == 0)
        try await preparation.prepare(identity)
        #expect(readyChecks == 2 && activations == 1)
    }

    @Test func aSecondReadCompletingDuringReadinessCannotRepeatActivation() async throws {
        var instant = ContinuousClock.now
        var readyChecks = 0
        var activations = 0
        let reference = PreparationReference()
        let preparation = BrowserAccessibility(now: { instant }, isCurrent: { _ in true }, waitUntilReady: { _ in
            readyChecks += 1
            if readyChecks == 1 { try await reference.value?.prepare(identity) }
        }, activate: { _ in activations += 1 }, wait: { instant = instant.advanced(by: $0) })
        reference.value = preparation
        try await preparation.prepare(identity)
        #expect(readyChecks == 2 && activations == 1)
    }

    @Test func failedActivationIsNotCachedAndALaterReadCanTryOnce() async throws {
        var instant = ContinuousClock.now
        var activations = 0
        var waits = 0
        let preparation = BrowserAccessibility(now: { instant }, isCurrent: { _ in true }, waitUntilReady: { _ in }, activate: { _ in
            activations += 1
            if activations == 1 { throw BrowserAccessibility.Failure.applicationNotReady }
        }, wait: { instant = instant.advanced(by: $0); waits += 1 })
        await #expect(throws: BrowserAccessibility.Failure.self) { try await preparation.prepare(identity) }
        #expect(activations == 1 && waits == 0)
        try await preparation.prepare(identity)
        try await preparation.prepare(identity)
        #expect(activations == 2 && waits == 1)
    }

    @Test func chromiumForwardedNotImplementedIsAcceptedButCannotCompleteIsRefused() throws {
        // Observed with real Chrome 156: activation is processed, then AppKit's
        // forwarded result is -25208 (notImplemented, not actionUnsupported).
        let forwarded = try #require(AXError(rawValue: -25208))
        #expect(forwarded == .notImplemented)
        try BrowserAccessibility.validateActivationStatus(forwarded)
        #expect(throws: BrowserAccessibility.Failure.self) {
            try BrowserAccessibility.validateActivationStatus(.cannotComplete)
        }
    }
}
