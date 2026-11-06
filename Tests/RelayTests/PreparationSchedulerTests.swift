import Foundation
import Testing
@testable import Relay

@MainActor
struct PreparationSchedulerTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test func disabledInitAndTickNeverPrepare() {
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        var count = 0
        scheduler.prepare = { count += 1; return "Synthetic" }
        scheduler.tick(now: date("2026-10-30T10:00:00Z"), timeZone: utc)
        #expect(!scheduler.enabled)
        #expect(count == 0)
    }
    @Test func sleepDefersPreparationAndWakeUsesCurrentTimeZoneOnce() {
        let now = date("2026-10-30T07:00:00Z")
        var zone = utc
        var count = 0
        let scheduler = PreparationScheduler(
            automaticTimers: false, lowPower: { false }, clock: { now },
            systemTimeZone: { zone }, thermalLimited: { false }
        )
        scheduler.prepare = { count += 1; return "Synthetic" }
        scheduler.setEnabled(true)
        scheduler.systemWillSleep()
        zone = TimeZone(identifier: "Asia/Riyadh")!
        scheduler.tick(now: now, timeZone: zone)
        #expect(count == 0)
        scheduler.systemDidWake()
        scheduler.systemDidWake()
        #expect(count == 1)
        #expect(scheduler.lastPreparedAt == now)
    }

    @Test func thermalLimitDelaysWithoutReservingTheDay() {
        let now = date("2026-10-30T10:00:00Z")
        var limited = true
        var count = 0
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false }, thermalLimited: { limited })
        scheduler.prepare = { count += 1; return "Synthetic" }
        scheduler.setEnabled(true)
        scheduler.tick(now: now, timeZone: utc)
        #expect(count == 0)
        #expect(scheduler.status.contains("cool down"))
        limited = false
        scheduler.tick(now: now.addingTimeInterval(60), timeZone: utc)
        #expect(count == 1)
    }
    @Test func busyAndLowPowerDelayWithoutDuplicatePreparation() {
        var busy = true
        var lowPower = true
        var count = 0
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { lowPower }, thermalLimited: { false })
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
        let first = PreparationScheduler(persistenceURL: url, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        first.prepare = { count += 1; return "Synthetic" }
        first.setEnabled(true)
        let now = date("2026-10-30T10:00:00Z")
        first.tick(now: now, timeZone: utc)
        let restored = PreparationScheduler(persistenceURL: url, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
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
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false }, thermalLimited: { false })
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
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false }, thermalLimited: { false })
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
        let scheduler = PreparationScheduler(persistenceURL: blocker.appendingPathComponent("schedule.json"), automaticTimers: false, lowPower: { false }, thermalLimited: { false })
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
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false }, thermalLimited: { false })
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
        var scheduler: PreparationScheduler? = PreparationScheduler(automaticTimers: true, lowPower: { false }, clock: { now }, thermalLimited: { false })
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        try scheduler?.setTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        var count = 0
        scheduler?.prepare = { count += 1; scheduler?.setEnabled(false); return "Synthetic" }
        scheduler?.setEnabled(true)
        #expect(count == 1)
        #expect(scheduler?.enabled == false)
        weak let reference = scheduler
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

    @Test(.timeLimit(.minutes(1))) func scheduledRefreshFindsNewNotesWithinOptedInScopeWithoutAChatRequest() async throws {
        let root = try ToolPolicy.canonicalURL(FileManager.default.temporaryDirectory.path).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        let other = root.appendingPathComponent("other")
        let unindexed = root.appendingPathComponent("unindexed")
        for folder in [selected, other, unindexed] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let original = selected.appendingPathComponent("original.md")
        try Data("Project notes for the review".utf8).write(to: original)
        let otherOriginal = other.appendingPathComponent("original.md")
        try Data("TODO: keep this indexed task".utf8).write(to: otherOriginal)

        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        let store = AssistantStore(persistenceURL: nil, preparationScheduler: scheduler)
        let selectedGrant = ScopeGrant(path: selected.resolvingSymlinksInPath().path)
        let otherGrant = ScopeGrant(path: other.path)
        let unindexedGrant = ScopeGrant(path: unindexed.path)
        store.grants = [selectedGrant, otherGrant, unindexedGrant]
        await store.knowledge.index(grants: [selectedGrant, otherGrant])
        store.setSuggestionsEnabled(true)
        scheduler.setRefreshSource(selectedGrant.id, enabled: true)
        scheduler.setRefreshSource(unindexedGrant.id, enabled: true)
        #expect(scheduler.refreshGrantIDs == [selectedGrant.id])
        scheduler.setEnabled(true)

        let newNote = selected.appendingPathComponent("deadline.md")
        let excluded = other.appendingPathComponent("excluded.md")
        try Data("TODO: prepare the launch brief by Friday".utf8).write(to: newNote)
        try Data("TODO: this folder has no refresh opt-in".utf8).write(to: excluded)
        let scheduledTime = date("2026-10-30T09:00:00Z")
        scheduler.tick(now: scheduledTime.addingTimeInterval(-1), timeZone: utc)
        #expect(!scheduler.isPreparing)
        scheduler.tick(now: scheduledTime, timeZone: utc)
        #expect(scheduler.isPreparing)
        while scheduler.isPreparing { try await Task.sleep(for: .milliseconds(1)) }
        #expect(scheduler.lastPreparedAt == scheduledTime)
        let suggestions = store.suggestions.suggestions
        #expect(suggestions.contains { $0.title == "prepare the launch brief by Friday" && $0.sourcePaths == [newNote.path] })
        #expect(suggestions.contains { $0.sourcePaths == [otherOriginal.path] })
        #expect(!store.knowledge.records.contains { $0.sourcePath == excluded.path })
        #expect(store.messages.isEmpty)

        try Data("TODO: a second run should not read this today".utf8).write(to: newNote)
        scheduler.tick(now: scheduledTime.addingTimeInterval(60), timeZone: utc)
        #expect(!scheduler.isPreparing)
        #expect(scheduler.lastPreparedAt == scheduledTime)
        store.knowledge.removeSource(path: newNote.path)
        #expect(scheduler.refreshGrantIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func stoppingARefreshCancelsWorkAndKeepsTheDailyReservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("schedule.json")
        let source = ScopeGrant(path: root.path)
        let scheduler = PreparationScheduler(persistenceURL: url, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        var attempts = 0
        scheduler.prepare = { "Previously indexed sources" }
        scheduler.eligibleRefreshSources = { [source] }
        scheduler.refreshAndPrepare = { _, ids, calendars in
            #expect(ids == [source.id])
            #expect(calendars.isEmpty)
            attempts += 1
            try await Task.sleep(for: .seconds(30))
            Issue.record("A stopped refresh finished its work.")
            return .init(summary: "Unexpected completion")
        }
        scheduler.setRefreshSource(source.id, enabled: true)
        scheduler.setEnabled(true)
        let time = date("2026-10-30T09:00:00Z")
        scheduler.tick(now: time, timeZone: utc)
        while attempts == 0 { try await Task.sleep(for: .milliseconds(1)) }
        scheduler.cancelCurrentPreparation()
        while scheduler.isPreparing { try await Task.sleep(for: .milliseconds(1)) }

        let restored = PreparationScheduler(persistenceURL: url, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        restored.prepare = scheduler.prepare
        restored.refreshAndPrepare = scheduler.refreshAndPrepare
        restored.tick(now: time.addingTimeInterval(60), timeZone: utc)
        #expect(restored.enabled)
        #expect(restored.refreshGrantIDs == [source.id])
        #expect(restored.lastPreparedAt == nil)
        #expect(!restored.isPreparing)
        #expect(attempts == 1)
    }

    @Test(.timeLimit(.minutes(1))) func wakingDuringCancellationResumesTheSameScopedRunOnce() async throws {
        let now = date("2026-10-30T09:10:00Z")
        let source = ScopeGrant(path: "/synthetic/selected")
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { false }, clock: { now },
                                             systemTimeZone: { utc }, thermalLimited: { false })
        var attempts = 0
        scheduler.prepare = { "Indexed-only brief" }
        scheduler.eligibleRefreshSources = { [source] }
        scheduler.refreshAndPrepare = { _, sources, calendars in
            #expect(sources == [source.id])
            #expect(calendars.isEmpty)
            attempts += 1
            if attempts == 1 { try await Task.sleep(for: .seconds(30)) }
            return .init(summary: "Completed selected sources")
        }
        scheduler.setRefreshSource(source.id, enabled: true)
        scheduler.setEnabled(true)
        scheduler.tick(now: now, timeZone: utc)
        while attempts == 0 { try await Task.sleep(for: .milliseconds(1)) }
        scheduler.systemWillSleep()
        scheduler.systemDidWake()
        while scheduler.isPreparing { try await Task.sleep(for: .milliseconds(1)) }
        scheduler.systemDidWake()
        #expect(attempts == 2)
        #expect(scheduler.lastPreparedAt == now)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func powerLimitDuringScheduledPreparationPausesAndResumesScopedWork(lowPowerMode: Bool) async throws {
        let now = date("2026-10-30T09:10:00Z")
        let source = ScopeGrant(path: "/synthetic/selected")
        var limited = false
        let scheduler = PreparationScheduler(automaticTimers: false, lowPower: { lowPowerMode && limited }, clock: { now },
                                             systemTimeZone: { utc }, thermalLimited: { !lowPowerMode && limited })
        var attempts = 0
        scheduler.prepare = { "Indexed-only brief" }
        scheduler.eligibleRefreshSources = { [source] }
        scheduler.refreshAndPrepare = { _, sources, calendars in
            #expect(sources == [source.id])
            #expect(calendars.isEmpty)
            attempts += 1
            if attempts == 1 { try await Task.sleep(for: .seconds(30)) }
            return .init(summary: "Completed selected sources")
        }
        scheduler.setRefreshSource(source.id, enabled: true)
        scheduler.setEnabled(true)
        scheduler.tick(now: now, timeZone: utc)
        while attempts == 0 { try await Task.sleep(for: .milliseconds(1)) }

        limited = true
        scheduler.tick(now: now, timeZone: utc)
        await scheduler.waitForCurrentPreparation()
        scheduler.tick(now: now, timeZone: utc)
        #expect(attempts == 1)
        #expect(scheduler.lastPreparedAt == nil)
        #expect(scheduler.status.contains(lowPowerMode ? "Low Power Mode" : "cool down"))

        limited = false
        scheduler.tick(now: now, timeZone: utc)
        await scheduler.waitForCurrentPreparation()
        scheduler.tick(now: now, timeZone: utc)
        #expect(attempts == 2)
        #expect(scheduler.lastPreparedAt == now)
    }

    @Test(.timeLimit(.minutes(1))) func relaunchResumesDraftingWithoutRedoingTheSavedDraft() async throws {
        let root = try ToolPolicy.canonicalURL(FileManager.default.temporaryDirectory.path).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("TODO: First local task\nTODO: Second local task".utf8).write(to: notes.appendingPathComponent("brief.md"))
        let stateURL = root.appendingPathComponent("state.json")
        let scheduleURL = root.appendingPathComponent("preparation-schedule.json")
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let clockParts = calendar.dateComponents([.hour, .minute], from: now)
        let scheduler = PreparationScheduler(persistenceURL: scheduleURL, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        var firstSessionCalls = 0
        let store = AssistantStore(persistenceURL: stateURL, complete: { _, tools, _ in
            #expect(tools.isEmpty)
            firstSessionCalls += 1
            if firstSessionCalls == 2 { try await Task.sleep(for: .seconds(30)) }
            return ModelReply(content: "First prepared draft.", toolCalls: [])
        }, preparationScheduler: scheduler)
        let grant = ScopeGrant(path: notes.path)
        store.grants = [grant]
        store.saveConfiguration()
        await store.knowledge.index(grants: [grant])
        store.setSuggestionsEnabled(true)
        store.suggestions.setScheduledDraftsEnabled(true)
        scheduler.setRefreshSource(grant.id, enabled: true)
        try scheduler.setTime(hour: try #require(clockParts.hour), minute: try #require(clockParts.minute))
        scheduler.setEnabled(true)
        scheduler.tick(now: now, timeZone: utc)
        while firstSessionCalls < 2 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(store.suggestions.preparedDrafts.values.sorted() == ["First prepared draft."])
        store.stopForTermination()
        await scheduler.waitForCurrentPreparation()

        let resumedSchedule = PreparationScheduler(persistenceURL: scheduleURL, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        var resumedCalls = 0
        let reopened = AssistantStore(persistenceURL: stateURL, complete: { messages, tools, _ in
            #expect(tools.isEmpty)
            #expect(messages.last?.content.contains("Second local task") == true)
            resumedCalls += 1
            return ModelReply(content: "Second prepared draft.", toolCalls: [])
        }, preparationScheduler: resumedSchedule)
        #expect(reopened.suggestions.preparedDrafts.values.sorted() == ["First prepared draft."])
        resumedSchedule.tick(now: Date(), timeZone: utc)
        await resumedSchedule.waitForCurrentPreparation()
        #expect(resumedCalls == 1)
        #expect(reopened.suggestions.preparedDrafts.values.sorted() == ["First prepared draft.", "Second prepared draft."])
        #expect(reopened.messages.isEmpty)
        reopened.removeGrant(grant.id)
        #expect(reopened.suggestions.preparedDrafts.isEmpty)
        #expect(AssistantStore(persistenceURL: stateURL).suggestions.preparedDrafts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func recoveryRequiresTheSameCalendarSessionAndBoundsAbruptExitRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let schedule = root.appendingPathComponent("schedule.json")
        let time = date("2026-10-30T09:00:00Z")
        let first = PreparationScheduler(persistenceURL: schedule, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        first.prepare = { "Indexed-only brief" }
        first.eligibleCalendarRefreshIDs = { ["session-only-calendar"] }
        first.setCalendarRefreshEnabled(true)
        first.refreshAndPrepare = { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return .init(summary: "Unexpected completion")
        }
        first.setEnabled(true)
        first.tick(now: time, timeZone: utc)
        let interruptedCalendarRun = try Data(contentsOf: schedule)
        first.pauseUntilNextWakeOrLaunch()
        await first.waitForCurrentPreparation()
        #expect(!String(decoding: interruptedCalendarRun, as: UTF8.self).contains("session-only-calendar"))
        let noCalendarSession = PreparationScheduler(persistenceURL: schedule, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        noCalendarSession.prepare = { Issue.record("Expired session scope was silently dropped."); return "Unexpected" }
        noCalendarSession.tick(now: time, timeZone: utc)
        #expect(!noCalendarSession.isPreparing)
        #expect(noCalendarSession.status.contains("settings changed"))

        let local = root.appendingPathComponent("local.json")
        let source = ScopeGrant(path: "/synthetic/selected")
        func makeLocal() -> PreparationScheduler {
            let scheduler = PreparationScheduler(persistenceURL: local, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
            scheduler.prepare = { "Indexed-only brief" }
            scheduler.eligibleRefreshSources = { [source] }
            scheduler.refreshAndPrepare = { _, _, _ in
                try await Task.sleep(for: .seconds(30))
                return .init(summary: "Unexpected completion")
            }
            return scheduler
        }
        let initial = makeLocal()
        initial.setRefreshSource(source.id, enabled: true)
        initial.setEnabled(true)
        initial.tick(now: time, timeZone: utc)
        let interrupted = try Data(contentsOf: local)
        initial.cancelCurrentPreparation()
        await initial.waitForCurrentPreparation()
        try interrupted.write(to: local, options: .atomic)

        let replay = makeLocal()
        replay.tick(now: time, timeZone: utc)
        #expect(replay.isPreparing)
        let interruptedAgain = try Data(contentsOf: local)
        replay.cancelCurrentPreparation()
        await replay.waitForCurrentPreparation()
        try interruptedAgain.write(to: local, options: .atomic)

        let final = makeLocal()
        final.tick(now: time, timeZone: utc)
        #expect(!final.isPreparing)
        #expect(final.status.contains("interrupted again"))
    }

    @Test(.timeLimit(.minutes(1))) func selectedCalendarAgendaRequiresASeparateSessionOptIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("schedule.json")
        let time = date("2026-10-30T09:00:00Z")
        let appointment = CalendarSource.EventInfo(id: "fixture-event", title: "Fixture launch review", start: time,
                                                    end: time.addingTimeInterval(1_800), calendarName: "Fixture")
        let scheduler = PreparationScheduler(persistenceURL: url, automaticTimers: false, lowPower: { false }, thermalLimited: { false })
        scheduler.eligibleCalendarRefreshIDs = { ["chosen-calendar"] }
        scheduler.prepare = { "Indexed-only brief" }
        scheduler.refreshAndPrepare = { _, sources, calendars in
            #expect(sources.isEmpty)
            #expect(calendars == ["chosen-calendar"])
            return .init(summary: "Read a fixture appointment", agenda: [appointment])
        }
        scheduler.setEnabled(true)
        scheduler.tick(now: time, timeZone: utc)
        #expect(scheduler.agenda.isEmpty)
        scheduler.setCalendarRefreshEnabled(true)
        scheduler.tick(now: time.addingTimeInterval(86_400), timeZone: utc)
        while scheduler.isPreparing { try await Task.sleep(for: .milliseconds(1)) }
        #expect(scheduler.agenda == [appointment])

        let restored = PreparationScheduler(persistenceURL: url, automaticTimers: false)
        #expect(restored.calendarRefreshIDs.isEmpty)
        #expect(restored.agenda.isEmpty)
        scheduler.setCalendarRefreshEnabled(false)
        #expect(scheduler.agenda.isEmpty)
    }
}
