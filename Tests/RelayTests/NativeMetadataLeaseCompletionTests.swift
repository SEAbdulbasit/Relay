import Foundation
import Testing
@testable import Relay

/// Actual shared finalizer and phase state machine; no process/AX/ACK factory
/// or source authorization is invented by these timing/lifetime tests.
@MainActor @Suite struct NativeMetadataLeaseCompletionTests {
    nonisolated private final class MarkerError: Error {}
    nonisolated private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [NativeReadAudit.Sample] = []
        var deadlines: Int { lock.withLock { storage.filter { $0.stage == .policyDeadlineRefusal }.count } }
        func record(_ value: NativeReadAudit.Sample) { lock.withLock { storage.append(value) } }
    }

    @Test func timelySuccessReturnsTheExactResultWithoutCreatingAuthorityOrADeadlineRefusal() throws {
        let samples = Samples(), start = ContinuousClock.now
        let result: Result<Int, any Error> = .success(42)
        let actual = try NativeMetadataPhase.finishLease(result,
            deadline: start.advanced(by: .milliseconds(750)), now: start, readAudit: .init { samples.record($0) })
        #expect(actual == 42 && samples.deadlines == 0)
    }

    @Test func otherwiseSuccessfulLateExitRefusesAndRecordsTheOriginalDeadline() throws {
        let samples = Samples(), start = ContinuousClock.now
        let result: Result<Int, any Error> = .success(42)
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeMetadataPhase.finishLease(result, deadline: start.advanced(by: .milliseconds(750)),
                now: start.advanced(by: .milliseconds(751)), readAudit: .init { samples.record($0) })
        }
        #expect(samples.deadlines == 1)
    }

    @Test func existingFailureObjectStaysIdenticalWhileItsLateExitIsCharged() throws {
        let original = MarkerError(), samples = Samples(), start = ContinuousClock.now
        let result: Result<Int, any Error> = .failure(original)
        do {
            _ = try NativeMetadataPhase.finishLease(result, deadline: start.advanced(by: .milliseconds(750)),
                now: start.advanced(by: .milliseconds(751)), readAudit: .init { samples.record($0) })
            Issue.record("A throwing lease must not become successful")
        } catch { #expect((error as? MarkerError) === original) }
        #expect(samples.deadlines == 1)
    }

    @Test func typedCancellationStaysCancellationAndDoesNotHideAnOverrun() throws {
        let samples = Samples(), start = ContinuousClock.now
        let result: Result<Int, any Error> = .failure(CancellationError())
        #expect(throws: CancellationError.self) {
            try NativeMetadataPhase.finishLease(result, deadline: start.advanced(by: .milliseconds(750)),
                now: start.advanced(by: .milliseconds(751)), readAudit: .init { samples.record($0) })
        }
        #expect(samples.deadlines == 1)
    }

    @Test func completedProtectedPhaseCannotSkipTheSubsequentLeaseExitDeadline() throws {
        let samples = Samples(), start = ContinuousClock.now
        let deadline = start.advanced(by: .milliseconds(750))
        var boundaries = 0, queries = 0
        var escaped: NativeMetadataPhase?
        let result: Result<Int, any Error> = Result {
            try NativeMetadataPhase.run(deadline: deadline, boundary: { boundaries += 1 },
                query: { queries += 1 }, now: { start }) { phase in
                escaped = phase
                throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
            }
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) {
            try NativeMetadataPhase.finishLease(result, deadline: deadline,
                now: start.advanced(by: .milliseconds(751)), readAudit: .init { samples.record($0) })
        }
        #expect(samples.deadlines == 1 && boundaries == 2 && queries == 0)
        let retired = try #require(escaped)
        #expect(throws: NativeMetadataPhase.Failure.expired) { try retired.check() }
        #expect(queries == 0)
    }

    @Test func actualStrongExitOverridesBodyAndStillSurvivesTheFinalDeadlineDecision() throws {
        let samples = Samples(), original = MarkerError(), start = ContinuousClock.now
        let deadline = start.advanced(by: .milliseconds(750))
        var boundaries = 0
        let result: Result<Int, any Error> = Result {
            try NativeMetadataPhase.run(deadline: deadline, boundary: {
                boundaries += 1
                if boundaries == 2 { throw original }
            }, query: {}, now: { start }) { _ in
                throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
            }
        }
        do {
            _ = try NativeMetadataPhase.finishLease(result, deadline: deadline,
                now: start.advanced(by: .milliseconds(751)), readAudit: .init { samples.record($0) })
            Issue.record("The original strong exit must refuse")
        } catch { #expect((error as? MarkerError) === original) }
        #expect(boundaries == 2 && samples.deadlines == 1)
    }

    @Test func nilAuditKeepsTheSameLateSuccessAndExistingFailureDecisions() throws {
        let start = ContinuousClock.now, deadline = start.advanced(by: .milliseconds(750))
        let success: Result<Int, any Error> = .success(42)
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeMetadataPhase.finishLease(success, deadline: deadline, now: start.advanced(by: .milliseconds(751)))
        }
        let failure: Result<Int, any Error> = .failure(NativeVisualTaskFailure.staleTask)
        #expect(throws: NativeVisualTaskFailure.staleTask) {
            try NativeMetadataPhase.finishLease(failure, deadline: deadline, now: start.advanced(by: .milliseconds(751)))
        }
    }

    @Test func currentCancellationAfterLeaseSettlementPreventsAFormerSuccess() async {
        let samples = Samples(), start = ContinuousClock.now
        let work = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let success: Result<Int, any Error> = .success(42)
            #expect(throws: CancellationError.self) {
                try NativeMetadataPhase.finishLease(success, deadline: start.advanced(by: .milliseconds(750)),
                    now: start.advanced(by: .milliseconds(751)), readAudit: .init { samples.record($0) })
            }
        }
        await work.value
        #expect(samples.deadlines == 1)
    }
}
