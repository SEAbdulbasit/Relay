import Foundation
import Testing
@testable import Relay

/// Only inert operations: no actual official/fake process, signature query,
/// workspace, credentials, provider, model, AX, UI, permission or input.
@Suite struct OwnedNativeProcessStartDeliveryTests {
    private nonisolated struct SyntheticMetadata: Sendable, Equatable {
        let processIdentifier: Int32
        let executable: URL
        let reviewedCodeDirectoryHash: Data
        let workspace: URL
    }
    private nonisolated enum Event: Sendable, Equatable {
        case launch, armedCleanup, payload, received(SyntheticMetadata)
    }
    private enum SyntheticFailure: Error, Equatable { case failedLaunch, rejectedReceipt }
    private nonisolated final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Event] = []
        func append(_ value: Event) { lock.withLock { values.append(value) } }
        var snapshot: [Event] { lock.withLock { values } }
    }
    private var metadata: SyntheticMetadata {
        .init(processIdentifier: 123, executable: URL(fileURLWithPath: "/Synthetic Official.app/Contents/MacOS/codex"),
            reviewedCodeDirectoryHash: Data([1, 7, 9]),
            workspace: URL(fileURLWithPath: "/Owned/RelayNativeObservation-00000000-0000-0000-0000-000000000001", isDirectory: true))
    }
    @Test func successfulLaunchArmsCleanupBeforeDeliveringTheExactMetadata() throws {
        let events = Events(), expected = metadata
        try OwnedNativeProcessStartDelivery.perform(observer: { events.append(.received($0)) },
            launch: { events.append(.launch) }, didLaunch: { events.append(.armedCleanup) },
            payload: { events.append(.payload); return expected })
        #expect(events.snapshot == [.launch, .armedCleanup, .payload, .received(expected)])
    }
    @Test func nilObserverPreservesLaunchAndDoesNotEvaluateAnyMetadata() throws {
        let events = Events(), expected = metadata
        let observer: (@Sendable (SyntheticMetadata) throws -> Void)? = nil
        try OwnedNativeProcessStartDelivery.perform(observer: observer,
            launch: { events.append(.launch) }, didLaunch: { events.append(.armedCleanup) },
            payload: { events.append(.payload); return expected })
        #expect(events.snapshot == [.launch, .armedCleanup])
    }
    @Test func launchFailurePropagatesBeforeCleanupMarkPayloadOrNotification() {
        let events = Events(), expected = metadata
        #expect(throws: SyntheticFailure.failedLaunch) {
            try OwnedNativeProcessStartDelivery.perform(observer: { events.append(.received($0)) },
                launch: { events.append(.launch); throw SyntheticFailure.failedLaunch },
                didLaunch: { events.append(.armedCleanup) },
                payload: { events.append(.payload); return expected })
        }
        #expect(events.snapshot == [.launch])
    }
    @Test func nilObserverDoesNotSwallowTheOriginalLaunchError() {
        let events = Events(), expected = metadata
        let observer: (@Sendable (SyntheticMetadata) throws -> Void)? = nil
        #expect(throws: SyntheticFailure.failedLaunch) {
            try OwnedNativeProcessStartDelivery.perform(observer: observer,
                launch: { events.append(.launch); throw SyntheticFailure.failedLaunch },
                didLaunch: { events.append(.armedCleanup) },
                payload: { events.append(.payload); return expected })
        }
        #expect(events.snapshot == [.launch])
    }
    @Test func receiptRejectionPropagatesAfterTheActualLaunchMark() {
        let events = Events(), expected = metadata
        #expect(throws: SyntheticFailure.rejectedReceipt) {
            try OwnedNativeProcessStartDelivery.perform(observer: { value in
                events.append(.received(value)); throw SyntheticFailure.rejectedReceipt
            }, launch: { events.append(.launch) }, didLaunch: { events.append(.armedCleanup) },
                payload: { events.append(.payload); return expected })
        }
        #expect(events.snapshot == [.launch, .armedCleanup, .payload, .received(expected)])
        // This proves synchronous error/order only. It does not qualify an
        // actual official CLI launch or cleanup; the owned harness must do so.
    }
}
