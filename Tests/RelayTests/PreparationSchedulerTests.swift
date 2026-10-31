import Foundation
import Testing
@testable import Relay

@MainActor
struct PreparationSchedulerTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func disabledInitAndTickNeverPrepare() {
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false })
        var count = 0
        scheduler.prepare = { count += 1; return "Synthetic" }
        scheduler.tick(now: date("2026-10-30T10:00:00Z"), timeZone: utc)
        #expect(!scheduler.enabled)
        #expect(count == 0)
    }
    @Test func busyAndLowPowerDelayWithoutDuplicatePreparation() {
        var busy = true
        var lowPower = true
        var count = 0
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { lowPower })
        scheduler.isBusy = { busy }
        scheduler.prepare = { count += 1; return "Synthetic" }
        scheduler.setEnabled(true)
        let now = date("2026-10-30T10:00:00Z")
        scheduler.tick(now: now, timeZone: utc)
        #expect(count == 0)
        busy = false
        scheduler.tick(now: now, timeZone: utc)
        #expect(count == 0)
        lowPower = false
        scheduler.tick(now: now, timeZone: utc)
        scheduler.tick(now: now.addingTimeInterval(60), timeZone: utc)
        #expect(count == 1)
        #expect(scheduler.lastPreparedAt == now)
    }
    @Test func handledDaysPersistAndDoNotRepeatOnRelaunchOrClockRollback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("schedule.json")
        var count = 0
        let first = PreparationScheduler(persistenceURL: url, automaticTimers: false, lowPower: { false })
        first.prepare = { count += 1; return "Synthetic" }
        first.setEnabled(true)
        let now = date("2026-10-30T10:00:00Z")
        first.tick(now: now, timeZone: utc)
        let restored = PreparationScheduler(persistenceURL: url, automaticTimers: false, lowPower: { false })
        restored.prepare = { count += 1; return "Synthetic" }
        restored.tick(now: now, timeZone: utc)
        restored.tick(now: now.addingTimeInterval(-86_400), timeZone: utc)
        #expect(count == 1)
        #expect(restored.status.contains("date is before"))
        restored.tick(now: now.addingTimeInterval(86_400), timeZone: utc)
        #expect(count == 2)
    }
    @Test func failuresAreNotRetriedEveryMinuteAndDisableBlocksFutureTicks() {
        var attempts = 0
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false })
        scheduler.prepare = { attempts += 1; throw RelayError.message("Synthetic unavailable source") }
        scheduler.setEnabled(true)
        let now = date("2026-10-30T10:00:00Z")
        scheduler.tick(now: now, timeZone: utc)
        scheduler.tick(now: now.addingTimeInterval(60), timeZone: utc)
        #expect(attempts == 1)
        #expect(scheduler.errorMessage?.contains("Synthetic") == true)
        scheduler.setEnabled(false)
        scheduler.tick(now: now.addingTimeInterval(86_400), timeZone: utc)
        #expect(attempts == 1)
    }
    @Test func invalidAndMissedTimesDoNotPrepare() throws {
        #expect(throws: (any Error).self) { try DailyPreparationPolicy.decision(now: date("2026-10-30T10:00:00Z"), hour: 24, minute: 0, lastHandledDay: nil, timeZone: utc) }
        #expect(throws: (any Error).self) { try DailyPreparationPolicy.decision(now: .init(timeIntervalSinceReferenceDate: .infinity), hour: 9, minute: 0, lastHandledDay: nil, timeZone: utc) }
        #expect(try DailyPreparationPolicy.decision(now: date("2026-10-30T08:59:00Z"), hour: 9, minute: 0, lastHandledDay: nil, timeZone: utc) == .waiting)
        #expect(try DailyPreparationPolicy.decision(now: date("2026-10-30T16:00:00Z"), hour: 9, minute: 0, lastHandledDay: nil, timeZone: utc) == .missed)
        #expect(!DailyPreparationPolicy.validDayKey("2026-02-30"))
        #expect(DailyPreparationPolicy.validDayKey("2028-02-29"))
    }
    @Test func dstSkippedAndRepeatedTimesAreHandledOnceByLocalDay() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        #expect(try DailyPreparationPolicy.decision(now: date("2026-03-08T06:59:00Z"), hour: 2, minute: 30, lastHandledDay: nil, timeZone: zone) == .waiting)
        #expect(try DailyPreparationPolicy.decision(now: date("2026-03-08T07:00:00Z"), hour: 2, minute: 30, lastHandledDay: nil, timeZone: zone) == .due(day: "2026-03-08"))
        #expect(try DailyPreparationPolicy.decision(now: date("2026-11-01T05:30:00Z"), hour: 1, minute: 30, lastHandledDay: nil, timeZone: zone) == .due(day: "2026-11-01"))
        #expect(try DailyPreparationPolicy.decision(now: date("2026-11-01T06:30:00Z"), hour: 1, minute: 30, lastHandledDay: "2026-11-01", timeZone: zone) == .handled)
    }
    @Test func reentrantTickCannotPrepareTwice() {
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false })
        let now = date("2026-10-30T10:00:00Z")
        var count = 0
        scheduler.prepare = { count += 1; scheduler.tick(now: now, timeZone: self.utc); return "Synthetic" }
        scheduler.setEnabled(true)
        scheduler.tick(now: now, timeZone: utc)
        #expect(count == 1)
    }
    @Test func failedReservationNeverRunsAndOversizedRestoreStaysOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data("block".utf8).write(to: blocker)
        let scheduler = PreparationScheduler(persistenceURL: blocker.appendingPathComponent("schedule.json"), automaticTimers: false, lowPower: { false })
        var count = 0
        scheduler.prepare = { count += 1; return "Synthetic" }
        scheduler.setEnabled(true)
        scheduler.tick(now: date("2026-10-30T10:00:00Z"), timeZone: utc)
        #expect(count == 0)
        #expect(scheduler.errorMessage != nil)
        let oversized = root.appendingPathComponent("huge.json")
        try Data(repeating: 65, count: 20_000).write(to: oversized)
        #expect(!PreparationScheduler(persistenceURL: oversized, automaticTimers: false).enabled)
    }
    @Test func disablingInsidePreparationLeavesItOff() {
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false })
        var count = 0
        scheduler.prepare = { count += 1; scheduler.setEnabled(false); return "Synthetic" }
        scheduler.setEnabled(true)
        scheduler.tick(now: date("2026-10-30T10:00:00Z"), timeZone: utc)
        scheduler.tick(now: date("2026-10-31T10:00:00Z"), timeZone: utc)
        #expect(!scheduler.enabled)
        #expect(count == 1)
    }
    @Test func disablingInsideInitialAutomaticTickDoesNotRetainScheduler() throws {
        let now = date("2026-10-30T10:00:00Z")
        var scheduler: PreparationScheduler? = PreparationScheduler(automaticTimers: true, lowPower: { false }, clock: { now })
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        try scheduler?.setTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        var count = 0
        scheduler?.prepare = { count += 1; scheduler?.setEnabled(false); return "Synthetic" }
        scheduler?.setEnabled(true)
        #expect(count == 1)
        #expect(scheduler?.enabled == false)
        weak var reference = scheduler
        scheduler = nil
        #expect(reference == nil)
    }
    @Test func corruptSavedConfigurationRemainsOff() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("schedule.json")
        try Data(#"{"version":1,"enabled":true,"hour":9,"minute":0,"lastHandledDay":"2026-99-99"}"#.utf8).write(to: url)
        let scheduler = PreparationScheduler(persistenceURL: url, automaticTimers: false)
        #expect(!scheduler.enabled)
        #expect(scheduler.status.contains("could not be read safely"))
    }
}
