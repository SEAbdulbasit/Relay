import EventKit
import Foundation
import Observation
import Testing
@testable import Relay

struct CalendarSourceTests {
    @Test @MainActor func selectionAndForgetInvalidateDerivedContextWithoutRequestingPermission() {
        let source = CalendarSource()
        var invalidations = 0
        source.onContextInvalidated = { invalidations += 1 }
        source.selectedCalendarIDs = ["synthetic-calendar"]
        #expect(invalidations == 1)
        source.selectedCalendarIDs = ["synthetic-calendar"]
        #expect(invalidations == 1)
        source.clear()
        #expect(invalidations == 2)
        source.clear()
        #expect(invalidations == 3)
        #expect(source.events.isEmpty)
    }
    /// Actual Source/installed Observation behavior. Initialization checks OS
    /// status only; this test never requests access, lists calendars or reads events.
    @Test @MainActor func byteDistinctSelectionAlwaysStoresNewBytesWithdrawsOnceAndNotifiesObservers() {
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        let source = CalendarSource(), observed = CalendarSelectionObservationCount()
        var invalidations = 0
        var callbackKeys: Set<Data> = []
        source.onContextInvalidated = { [weak source] in
            invalidations += 1
            callbackKeys = CalendarSelectionIdentity.keys(source?.selectedCalendarIDs ?? [])
        }
        source.selectedCalendarIDs = [composed]
        #expect(invalidations == 1 && callbackKeys == [Data(composed.utf8)])
        let firstEpoch = source.selectionEpoch
        withObservationTracking { _ = source.selectedCalendarIDs } onChange: { observed.increment() }
        source.errorMessage = "Owned old error"
        source.selectedCalendarIDs = [decomposed]
        #expect(source.selectionEpoch != firstEpoch && observed.value == 1)
        #expect(CalendarSelectionIdentity.keys(source.selectedCalendarIDs) == [Data(decomposed.utf8)])
        #expect(source.selectedCalendarIDs.first.map { Data($0.utf8) } == Data(decomposed.utf8))
        #expect(invalidations == 2 && callbackKeys == [Data(decomposed.utf8)])
        #expect(source.events.isEmpty && source.errorMessage == nil)
        #expect(source.status == "Selection changed. Refresh to read this scope.")
        let secondEpoch = source.selectionEpoch, unchanged = CalendarSelectionObservationCount()
        withObservationTracking { _ = source.selectedCalendarIDs } onChange: { unchanged.increment() }
        source.selectedCalendarIDs = [decomposed]
        #expect(source.selectionEpoch == secondEpoch && unchanged.value == 0 && invalidations == 2)
        source.onContextInvalidated = nil
    }
    @Test @MainActor func databaseChangesInvalidateSelectedContentWithoutDroppingItsScope() {
        let source = CalendarSource()
        var scopeInvalidations = 0, contentInvalidations = 0
        source.onContextInvalidated = { scopeInvalidations += 1 }
        source.onContentInvalidated = { contentInvalidations += 1 }
        source.selectedCalendarIDs = ["owned-synthetic-selection"]
        #expect(scopeInvalidations == 1)
        source.calendarDatabaseChanged()
        #expect(contentInvalidations == 1 && scopeInvalidations == 1)
        #expect(source.selectedCalendarIDs == ["owned-synthetic-selection"] && source.events.isEmpty)
        source.calendarDatabaseChanged()
        #expect(contentInvalidations == 2 && scopeInvalidations == 1)
    }

    @Test @MainActor func unselectedDatabaseChangesDoNotInvalidateUnrelatedContent() {
        let source = CalendarSource()
        var invalidations = 0
        source.onContentInvalidated = { invalidations += 1 }
        source.calendarDatabaseChanged()
        #expect(invalidations == 0 && source.events.isEmpty)
    }

    @Test @MainActor func databaseChangeStopsAReplyThatAlreadyReadCalendarContext() async throws {
        let fixture = try CalendarProtocolFixture()
        let directory = fixture.root, lateFile = directory.appending(path: "late.txt")
        var sends = 0, writes = 0, reads = 0, secondInputHadCalendar = false
        var blocked: CheckedContinuation<Void, Never>?
        let store = AssistantStore(persistenceURL: nil, complete: { messages, _, _ in
            sends += 1
            if sends == 1 {
                return ModelReply(content: "", toolCalls: [fixture.call()])
            }
            secondInputHadCalendar = messages.contains { $0.content.contains("OWNED_EVENT_CONTEXT") }
            await withCheckedContinuation { blocked = $0 }
            return ModelReply(content: "LATE_CALENDAR_REPLY", toolCalls: [.init(name: "write_file", arguments: ["path": .string(lateFile.path), "content": .string("late")])])
        }, conversationHistory: fixture.history, execute: { _ in
            writes += 1
            return ToolResult(summary: "Unexpected late write", evidence: "Inert executor", verified: true)
        }, executeCalendarRead: { call, scope in
            // The actual immutable protocol result is saved and admitted using
            // the real receipt path. This is not an EventKit data qualification.
            reads += 1
            return try await fixture.worker.read(call: call, scope: scope).result
        }, calendarReadWorker: fixture.worker)
        do {
            await store.waitForConversationTaskToSettle()
            store.grants = [.init(path: directory.path, writable: true)]
            store.calendarSource.selectedCalendarIDs = ["owned-synthetic-selection"]
            store.draft = "Read my selected calendar and describe the events."
            let submission = try #require(store.send())
            #expect(await submission.waitForAcknowledgment() == .saved)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while blocked == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            #expect(blocked != nil && secondInputHadCalendar && reads == 1)
            store.calendarSource.calendarDatabaseChanged()
            blocked?.resume(); blocked = nil
            await store.waitForConversationTaskToSettle()
            #expect(writes == 0 && !store.isRunning)
            #expect(!store.messages.contains { $0.text.contains("LATE_CALENDAR_REPLY") })
            #expect(!FileManager.default.fileExists(atPath: lateFile.path))
            #expect(store.calendarSource.selectedCalendarIDs == ["owned-synthetic-selection"])
            #expect(store.selectionNotice?.contains("Calendar data changed") == true)
            store.stop(); await store.waitForConversationTaskToSettle(); await fixture.close()
        } catch {
            store.stop(); blocked?.resume(); blocked = nil
            await store.waitForConversationTaskToSettle(); await fixture.close(); throw error
        }
    }

    @Test func dateRangeIsBoundedAndRejectsInvalidDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let range = try CalendarSource.validatedRange(start: start, days: 31, calendar: calendar)
        #expect(range.start == start)
        #expect(range.duration == 31 * 86_400)
        for days in [-1, 0, 32, Int.max] {
            #expect(throws: (any Error).self) { try CalendarSource.validatedRange(start: start, days: days) }
        }
        #expect(throws: (any Error).self) { try CalendarSource.validatedRange(start: Date(timeIntervalSinceReferenceDate: .infinity), days: 1) }
    }

    @Test func emptySelectionNeverExpandsToAllCalendars() throws {
        let calendars = [CalendarSource.CalendarInfo(id: "personal", title: "Personal"), CalendarSource.CalendarInfo(id: "work", title: "Work")]
        #expect(try CalendarSource.selectedCalendars(from: calendars, ids: []).isEmpty)
        #expect(try CalendarSource.selectedCalendars(from: calendars, ids: ["work"]) == [calendars[1]])
        #expect(throws: (any Error).self) { try CalendarSource.selectedCalendars(from: calendars, ids: ["missing"]) }
    }

    @Test func selectionHasSizeAndIdentifierBounds() {
        let tooMany = Set((0..<21).map { "calendar-\($0)" })
        for ids in [tooMany, Set([""]), Set([String(repeating: "x", count: 1025)])] {
            #expect(throws: (any Error).self) { try CalendarSource.selectedCalendars(from: [], ids: ids) }
        }
    }

    @Test func permissionCopyDistinguishesOSFullAccessFromProductSelection() {
        #expect(CalendarSource.permissionExplanation.contains("full Calendar access"))
        #expect(CalendarSource.permissionExplanation.contains("review each action"))
        #expect(CalendarSource.authorizationDescription(.writeOnly).contains("cannot read"))
        #expect(CalendarSource.authorizationDescription(.denied).contains("denied"))
        #expect(CalendarSource.authorizationDescription(.notDetermined).contains("explicitly"))
        #expect(CalendarSource.authorizationDescription(.fullAccess).contains("reviewed event creation"))
    }

    #if DEBUG
    @Test @MainActor func writeDestinationRequiresAnExplicitCurrentWritableCalendar() throws {
        let source = CalendarSource()
        let writable = CalendarSource.CalendarInfo(id: "owned-write", title: "Writable", allowsContentModifications: true)
        let readOnly = CalendarSource.CalendarInfo(id: "owned-read", title: "Read Only")
        var selections: [CalendarSource.CalendarInfo?] = []
        source.onWriteCalendarChanged = { selections.append($0) }
        source.setWriteCalendarCatalogForTesting([writable, readOnly])
        let epoch = source.selectionCatalog.epoch

        #expect(source.writeCalendar == nil)
        #expect(throws: (any Error).self) { try source.selectWriteCalendar(id: readOnly.id, catalogEpoch: epoch) }
        try source.selectWriteCalendar(id: writable.id, catalogEpoch: epoch)
        #expect(source.writeCalendar == writable)
        #expect(source.selectedCalendarIDs.isEmpty)
        source.calendarDatabaseChanged()
        #expect(source.writeCalendar == writable)
        #expect(throws: (any Error).self) { try source.selectWriteCalendar(id: writable.id, catalogEpoch: epoch) }
        source.setWriteCalendarCatalogForTesting([readOnly])
        #expect(source.writeCalendar == nil)

        source.setWriteCalendarCatalogForTesting([writable])
        try source.selectWriteCalendar(id: writable.id, catalogEpoch: source.selectionCatalog.epoch)
        source.setWriteCalendarCatalogForTesting([], hasAccess: false)
        #expect(source.writeCalendar == nil)
        #expect(selections == [writable, nil, writable, nil])
    }
    #endif

    @Test func displayTextIsBoundedWithoutRetainingEventMetadata() {
        #expect(CalendarSource.boundedTitle("  Meeting  ") == "Meeting")
        #expect(CalendarSource.boundedTitle(String(repeating: "🌍", count: 1000)).count == 512)
        let event = CalendarSource.EventInfo(id: "opaque", title: "Meeting", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60), calendarName: "Selected")
        #expect(Set(Mirror(reflecting: event).children.compactMap(\.label)) == ["id", "title", "start", "end", "calendarName"])
    }
}

nonisolated private final class CalendarSelectionObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
