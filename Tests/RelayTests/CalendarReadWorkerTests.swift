import Foundation
import Testing
@testable import Relay

@MainActor struct CalendarReadWorkerTests {
    @Test func sameFixedQueryFreshlyRechecksContentWithoutRelyingOnNotifications() async throws {
        try await withCalendarProtocol { f in
            let produced = try await f.produce(), call = f.call()
            for _ in 0..<3 {
                try await produced.receipt.validateProducedResult(call: call, result: produced.result,
                    run: f.run, proposalID: f.proposal, context: f.context)
            }
            #expect(f.backend.count == 4 && produced.result.summary.contains("OWNED_EVENT_CONTEXT"))
            // No source epoch/notification changes: actual fresh-query bytes alone refuse.
            f.backend.change("DIFFERENT_UNDELIVERED_CONTENT")
            await #expect(throws: CalendarReadFailure.self) {
                try await produced.receipt.validateProducedResult(call: call, result: produced.result,
                    run: f.run, proposalID: f.proposal, context: f.context)
            }
            #expect(f.backend.count == 5)
        }
    }
    @Test(arguments: ["selection", "source", "database", "context", "nil_context", "configuration", "stop"])
    func everyCurrentnessFenceRefusesTheOldOutput(_ change: String) async throws {
        try await withCalendarProtocol { f in
            let value = try await f.produce()
            switch change {
            case "selection": f.source.selectedCalendarIDs = ["different-owned-selection"]
            case "source": f.source.clear()
            case "database": f.worker.invalidateDatabaseForTesting()
            case "context": f.current = .init(logicalTaskID: f.context.logicalTaskID, configuration: f.context.configuration, scopeID: UUID(), sourceRevision: 0)
            case "nil_context": f.current = nil
            case "configuration":
                var config = f.context.configuration; config.modelPath += "changed"
                f.current = .init(logicalTaskID: f.context.logicalTaskID, configuration: config, scopeID: f.context.scopeID, sourceRevision: 0)
            default: f.active = false
            }
            await #expect(throws: (any Error).self) {
                try await value.receipt.validateProducedResult(call: f.call(), result: value.result,
                    run: f.run, proposalID: f.proposal, context: f.context)
            }
        }
    }
    @Test(arguments: [false, true])
    func cancellationAndTimeoutReleaseTheWaiterButNeverRemintAPhysicalSlot(_ timeout: Bool) async throws {
        let f = try CalendarProtocolFixture(), barrier = CalendarProtocolBarrier()
        let diagnostics = f.worker.enableSettlementDiagnosticsForTesting()
        let call = f.call(), scope = try f.scope(call)
        f.backend.pauseNext(barrier)
        let task = Task { try await f.worker.read(call: call, scope: scope, timeoutMilliseconds: timeout ? 250 : 2_000) }
        do {
            try await waitForCalendarBarrier(barrier)
            let began = ContinuousClock.now
            if let operation = diagnostics.snapshot.last?.operationID {
                diagnostics.record(.testWaitStarted, operationID: operation)
                if !timeout { diagnostics.record(.testCancellationRequested, operationID: operation) }
            }
            if !timeout { task.cancel() }
            do {
                _ = try await task.value
                Issue.record("Cancelled or timed-out calendar read unexpectedly succeeded.")
            } catch is CancellationError {
                #expect(!timeout)
            } catch let error as CalendarReadFailure {
                #expect(timeout && error == .timedOut)
            }
            #expect(ContinuousClock.now - began < .seconds(1), "Calendar strict1s actual boundary trace: \(diagnostics.technicalSummary)")
            #expect(f.worker.activeCount == 1)
            f.source.clear(); f.source.selectedCalendarIDs = ["new-owned-selection"]
            let nextCall = f.call("new-owner-request"), nextScope = try f.scope(nextCall, proposal: UUID())
            await #expect(throws: CalendarReadFailure.busy) { _ = try await f.worker.read(call: nextCall, scope: nextScope) }
            #expect(f.backend.count == 1 && f.worker.activeCount == 1)
            barrier.release(); await f.worker.drain()
            #expect(f.worker.activeCount == 0)
            let fresh = try await f.worker.read(call: nextCall, scope: nextScope)
            #expect(fresh.result.verified && f.backend.count == 2)
            await f.close()
        } catch { task.cancel(); barrier.release(); _ = try? await task.value; await f.close(); throw error }
    }
    @Test(arguments: [false, true])
    func lateSuccessAndSDKErrorBothRecheckScopeAndNeverExposeRawErrors(_ fail: Bool) async throws {
        let f = try CalendarProtocolFixture(), barrier = CalendarProtocolBarrier()
        f.backend.pauseNext(barrier); if fail { f.backend.fail() }
        let call = f.call(), scope = try f.scope(call)
        let task = Task { try await f.worker.read(call: call, scope: scope) }
        do {
            try await waitForCalendarBarrier(barrier)
            f.source.selectedCalendarIDs = ["revoked-selection"]
            barrier.release()
            do { _ = try await task.value; Issue.record("Late private output was admitted.") }
            catch { #expect(!error.localizedDescription.contains("PRIVATE_SDK_FIELD") && !error.localizedDescription.contains("OWNED_EVENT_CONTEXT")) }
            await f.worker.drain(); #expect(f.worker.activeCount == 0)
            await f.close()
        } catch { task.cancel(); barrier.release(); _ = try? await task.value; await f.close(); throw error }
    }
    @Test func internalBackendErrorsAreClosedWithoutReturningAnEmptyAgenda() async throws {
        try await withCalendarProtocol { f in
            f.backend.fail()
            do { _ = try await f.produce(); Issue.record("A failed query returned success.") }
            catch {
                #expect(error is CalendarReadFailure)
                #expect(!error.localizedDescription.contains("OWNED_EVENT_CONTEXT") && !error.localizedDescription.contains("PRIVATE_SDK_FIELD"))
            }
            #expect(f.backend.count == 1 && f.worker.activeCount == 0)
        }
    }
    @Test func canonicallyEquivalentSelectedIDsAndReturnedTextRemainByteDistinctProofs() async throws {
        try await withCalendarProtocol { f in
            f.source.selectedCalendarIDs = ["caf\u{e9}"]
            f.backend.change("caf\u{e9}")
            let first = try await f.produce()
            f.backend.change("cafe\u{301}")
            await #expect(throws: CalendarReadFailure.self) {
                try await first.receipt.validateProducedResult(call: f.call(), result: first.result,
                    run: f.run, proposalID: f.proposal, context: f.context)
            }
            f.backend.change("caf\u{e9}")
            f.source.selectedCalendarIDs = ["cafe\u{301}"]
            await #expect(throws: CalendarReadFailure.self) {
                try await first.receipt.validateProducedResult(call: f.call(), result: first.result,
                    run: f.run, proposalID: f.proposal, context: f.context)
            }
        }
    }

    @Test func actualSourceBoundaryRejectsAnotherOwnersOtherwiseIdenticalScopeBeforeAQuery() async throws {
        try await withCalendarProtocol { f in
            let other = CalendarSource(); other.selectedCalendarIDs = f.source.selectedCalendarIDs
            let call = f.call(), scope = try f.scope(f.call())
            #expect(!scope.matchesSource(other.calendarReadSeed()))
            await #expect(throws: CalendarReadFailure.unavailable) {
                _ = try await other.readForTool(call, scope: scope, worker: f.worker)
            }
            #expect(f.backend.count == 0 && f.worker.activeCount == 0)
        }
    }

}
