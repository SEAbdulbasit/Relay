import Foundation
import Testing
@testable import Relay

/// Synthetic clock/power/lease fixtures: never changes login items, power settings,
/// permissions, real source checkpoints, or the user's scheduler preferences.
@MainActor
struct PluggedInAnalysisReliabilityTests {
    private let instant = Date(timeIntervalSince1970: 1_795_176_000)
    private var healthy: AnalysisPowerState.Snapshot {
        .init(onACPower: true, batteryPercent: 90, lowPowerMode: false, thermalState: .nominal)
    }

    @Test func unknownPowerNeverStartsAutomaticWork() {
        var runs = 0
        var power = healthy
        power.powerKnown = false
        let scheduler = PluggedInAnalysisScheduler(persistenceURL: nil, automaticPolling: false,
            powerProvider: { power }, idleSecondsProvider: { 900 }, acquireSleepActivity: { _ in {} })
        scheduler.runCycle = { runs += 1; return .init() }
        scheduler.setEnabled(true)
        scheduler.evaluateTick()
        #expect(!scheduler.isRunningCycle && runs == 0)
        #expect(scheduler.status == AnalysisPowerState.Block.unknownPower.summary)
    }

    @Test func manualWorkDoesNotStartDuringSleepOrThermalPressure() async {
        var power = healthy
        var runs = 0
        var holds = 0
        let scheduler = PluggedInAnalysisScheduler(persistenceURL: nil, automaticPolling: false,
            powerProvider: { power }, acquireSleepActivity: { _ in holds += 1; return { holds -= 1 } })
        scheduler.runCycle = { runs += 1; return .init() }
        scheduler.handleWillSleep()
        scheduler.runManualCycleNow()
        #expect(!scheduler.isRunningCycle && holds == 0 && runs == 0)
        scheduler.handleDidWake()
        power = .init(onACPower: false, batteryPercent: 90, lowPowerMode: false, thermalState: .critical)
        scheduler.runManualCycleNow()
        #expect(!scheduler.isRunningCycle && holds == 0 && runs == 0)
        power = healthy
        scheduler.runManualCycleNow()
        await scheduler.waitForCurrentCycle()
        #expect(runs == 1 && holds == 0)
        #expect(scheduler.recentRuns.first?.outcome == .completed)
    }

    @Test func stopBeforeAsyncEntryNeverCallsThePipeline() async {
        var runs = 0
        var holds = 0
        let scheduler = PluggedInAnalysisScheduler(persistenceURL: nil, automaticPolling: false,
            powerProvider: { healthy }, acquireSleepActivity: { _ in holds += 1; return { holds -= 1 } })
        scheduler.runCycle = { runs += 1; return .init() }
        scheduler.runManualCycleNow()
        scheduler.cancelCurrentCycle()
        await scheduler.waitForCurrentCycle()
        #expect(runs == 0 && holds == 0)
        #expect(scheduler.recentRuns.first?.outcome == .stopped)
        #expect(!scheduler.awaitingIdleContinuation)
    }

    @Test(.timeLimit(.minutes(1))) func userStopCannotBecomeResumableWhileLateCallbackDrains() async {
        let entered = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<Void, Never>?
        var idle: TimeInterval = 300
        var holds = 0
        var runs = 0
        let scheduler = PluggedInAnalysisScheduler(persistenceURL: nil, automaticPolling: false,
            now: { instant }, powerProvider: { healthy }, idleSecondsProvider: { idle },
            acquireSleepActivity: { _ in holds += 1; return { holds -= 1 } })
        scheduler.runCycle = {
            runs += 1
            await withCheckedContinuation { finish = $0; entered.continuation.yield() }
            return .init(itemsIngested: 99)
        }
        scheduler.setEnabled(true)
        scheduler.evaluateTick()
        var signal = entered.stream.makeAsyncIterator()
        _ = await signal.next()
        scheduler.cancelCurrentCycle()
        #expect(holds == 0)
        idle = 0
        scheduler.evaluateTick()
        scheduler.handleWillSleep()
        finish?.resume(); finish = nil
        await scheduler.waitForCurrentCycle()
        #expect(scheduler.recentRuns.first?.outcome == .stopped)
        #expect(scheduler.lastCompletedAt == nil)
        #expect(!scheduler.awaitingIdleContinuation)
        idle = 300
        scheduler.handleDidWake()
        #expect(runs == 1 && !scheduler.isRunningCycle)
        #expect(holds == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["sleep", "battery", "thermal", "activity", "foreground"])
    func interruptionsReleaseLeaseAndResumeOnlyAfterEligibilityReturns(_ reason: String) async {
        let entered = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<Void, Never>?
        var power = healthy
        var idle: TimeInterval = 300
        var busy = false
        var holds = 0
        var runs = 0
        let scheduler = PluggedInAnalysisScheduler(persistenceURL: nil, automaticPolling: false,
            now: { instant }, powerProvider: { power }, idleSecondsProvider: { idle },
            acquireSleepActivity: { _ in holds += 1; return { holds -= 1 } })
        scheduler.interactionBusy = { busy }
        scheduler.runCycle = {
            runs += 1
            if runs == 1 {
                await withCheckedContinuation { finish = $0; entered.continuation.yield() }
            }
            return .init(itemsIngested: 2)
        }
        scheduler.setEnabled(true)
        scheduler.evaluateTick()
        var signal = entered.stream.makeAsyncIterator()
        _ = await signal.next()
        #expect(holds == 1)
        switch reason {
        case "sleep": scheduler.handleWillSleep()
        case "battery": power = .init(onACPower: false, batteryPercent: 90, lowPowerMode: false, thermalState: .nominal)
        case "thermal": power = .init(onACPower: true, batteryPercent: 90, lowPowerMode: false, thermalState: .serious)
        case "activity": idle = 0
        default: busy = true
        }
        scheduler.evaluateTick()
        #expect(holds == 0 && scheduler.isRunningCycle)
        finish?.resume(); finish = nil
        await scheduler.waitForCurrentCycle()
        #expect(scheduler.awaitingIdleContinuation)
        #expect(scheduler.lastCompletedAt == nil)
        scheduler.evaluateTick()
        #expect(runs == 1)
        power = healthy; idle = 300; busy = false
        scheduler.handleDidWake()
        await scheduler.waitForCurrentCycle()
        #expect(runs == 2 && holds == 0)
        #expect(scheduler.recentRuns.first?.outcome == .completed)
        #expect(!scheduler.awaitingIdleContinuation)
    }

    @Test(.timeLimit(.minutes(1))) func interruptedRunRestoresResumeMarkerWithoutWaitingFourHours() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-analysis-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("schedule.json")
        let entered = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<Void, Never>?
        let first = PluggedInAnalysisScheduler(persistenceURL: url, automaticPolling: false,
            now: { instant }, powerProvider: { healthy }, idleSecondsProvider: { 300 }, acquireSleepActivity: { _ in {} })
        first.runCycle = {
            await withCheckedContinuation { finish = $0; entered.continuation.yield() }
            return .init()
        }
        first.setEnabled(true)
        first.evaluateTick()
        var signal = entered.stream.makeAsyncIterator()
        _ = await signal.next()
        // Copy the durable state while in progress, as observed by a new process after abrupt exit.
        let crashSnapshot = try Data(contentsOf: url)
        first.cancelCurrentCycle()
        let stoppedSnapshot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(stoppedSnapshot["interruptedRun"] as? Bool == false, "Explicit Stop must be durable before the callback settles")
        finish?.resume(); finish = nil
        await first.waitForCurrentCycle()
        try crashSnapshot.write(to: url)
        let restored = PluggedInAnalysisScheduler(persistenceURL: url, automaticPolling: false,
            now: { instant }, powerProvider: { healthy }, idleSecondsProvider: { 300 }, acquireSleepActivity: { _ in {} })
        var resumedRuns = 0
        restored.runCycle = { resumedRuns += 1; return .init(itemsIngested: 1) }
        #expect(restored.enabled && restored.awaitingIdleContinuation)
        restored.evaluateTick()
        await restored.waitForCurrentCycle()
        #expect(resumedRuns == 1)
        #expect(restored.recentRuns.first?.outcome == .completed)
        let completed = PluggedInAnalysisScheduler(persistenceURL: url, automaticPolling: false,
            now: { instant }, powerProvider: { healthy }, acquireSleepActivity: { _ in {} })
        #expect(!completed.awaitingIdleContinuation)
    }

    @Test func automaticWorkFailsClosedIfReservationCannotBeSaved() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("relay-analysis-blocker-" + UUID().uuidString)
        try Data("regular file".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        var holds = 0
        var runs = 0
        let scheduler = PluggedInAnalysisScheduler(persistenceURL: blocker.appendingPathComponent("schedule.json"), automaticPolling: false,
            now: { instant }, powerProvider: { healthy }, idleSecondsProvider: { 300 },
            acquireSleepActivity: { _ in holds += 1; return { holds -= 1 } })
        scheduler.runCycle = { runs += 1; return .init() }
        scheduler.setEnabled(true)
        scheduler.evaluateTick()
        #expect(runs == 0 && holds == 0 && !scheduler.isRunningCycle)
        #expect(scheduler.lastErrorMessage != nil)
        #expect(scheduler.status.contains("could not save"))
    }

    @Test(.timeLimit(.minutes(1))) func completedLongRunWaitsFourHoursAfterCompletion() async {
        var clock = instant
        let entered = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<Void, Never>?
        var runs = 0
        let scheduler = PluggedInAnalysisScheduler(persistenceURL: nil, automaticPolling: false,
            now: { clock }, powerProvider: { healthy }, idleSecondsProvider: { 900 },
            acquireSleepActivity: { _ in {} }, waitForRunLimit: { try await Task.sleep(for: .seconds(3_600)) })
        scheduler.runCycle = {
            runs += 1
            if runs == 1 { await withCheckedContinuation { finish = $0; entered.continuation.yield() } }
            return .init()
        }
        scheduler.setEnabled(true)
        scheduler.evaluateTick()
        var signal = entered.stream.makeAsyncIterator()
        _ = await signal.next()
        // Clock is injected independently of the watchdog's monotonic wait.
        clock = clock.addingTimeInterval(5 * 3_600)
        finish?.resume(); finish = nil
        await scheduler.waitForCurrentCycle()
        let completed = clock
        #expect(scheduler.nextScheduledDate == completed.addingTimeInterval(PluggedInAnalysisScheduler.interval))
        scheduler.evaluateTick()
        #expect(runs == 1 && !scheduler.isRunningCycle)
        clock = completed.addingTimeInterval(PluggedInAnalysisScheduler.interval - 1)
        scheduler.evaluateTick()
        #expect(runs == 1)
        clock = clock.addingTimeInterval(1)
        scheduler.evaluateTick()
        await scheduler.waitForCurrentCycle()
        #expect(runs == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func watchdogReleasesLeaseButKeepsDrainingSlotAndExplicitStopWins(explicitStop: Bool) async {
        var clock = instant
        let entered = AsyncStream<Void>.makeStream()
        let limit = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<Void, Never>?
        var runs = 0
        var held = 0
        var releases = 0
        let scheduler = PluggedInAnalysisScheduler(persistenceURL: nil, automaticPolling: false,
            now: { clock }, powerProvider: { healthy }, idleSecondsProvider: { 900 },
            acquireSleepActivity: { _ in
                held += 1
                return { held -= 1; releases += 1; released.continuation.yield() }
            }, waitForRunLimit: {
                var signal = limit.stream.makeAsyncIterator()
                _ = await signal.next()
            })
        scheduler.runCycle = {
            runs += 1
            await withCheckedContinuation { finish = $0; entered.continuation.yield() }
            return .init(itemsIngested: 99)
        }
        scheduler.setEnabled(true)
        scheduler.evaluateTick()
        var started = entered.stream.makeAsyncIterator()
        _ = await started.next()
        #expect(held == 1)
        limit.continuation.yield()
        var releaseSignal = released.stream.makeAsyncIterator()
        _ = await releaseSignal.next()
        #expect(held == 0 && releases == 1)
        #expect(scheduler.isRunningCycle && scheduler.status.contains("time limit"))
        clock = clock.addingTimeInterval(10 * 3_600)
        scheduler.runManualCycleNow()
        scheduler.evaluateTick()
        #expect(runs == 1, "A timed-out uncooperative pipeline must retain the physical draining slot")
        if explicitStop { scheduler.cancelCurrentCycle() }
        finish?.resume(); finish = nil
        await scheduler.waitForCurrentCycle()
        #expect(!scheduler.isRunningCycle && scheduler.lastCompletedAt == nil)
        #expect(releases == 1 && held == 0)
        #expect(scheduler.recentRuns.first?.outcome == (explicitStop ? .stopped : .timedOut))
        #expect(scheduler.recentRuns.first?.summary.itemsIngested == 0, "Late success is not published after timeout")
        if explicitStop {
            #expect(!scheduler.awaitingIdleContinuation)
            #expect(scheduler.retryAfter == clock.addingTimeInterval(PluggedInAnalysisScheduler.interval))
            scheduler.evaluateTick()
            #expect(runs == 1, "Explicit Stop must not immediately restart an attempt whose old cadence expired while draining")
        } else {
            #expect(scheduler.awaitingIdleContinuation)
            #expect(scheduler.retryAfter == clock.addingTimeInterval(PluggedInAnalysisScheduler.failureRetryInterval))
            #expect(scheduler.nextScheduledDate == scheduler.retryAfter)
            scheduler.evaluateTick()
            #expect(runs == 1, "Settled timeouts respect backoff before any automatic retry")
        }
    }

}
