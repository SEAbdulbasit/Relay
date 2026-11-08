import EventKit
import Foundation
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
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-calendar-revocation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lateFile = directory.appending(path: "late.txt")
        var sends = 0, writes = 0, secondInputHadCalendar = false
        var blocked: CheckedContinuation<Void, Never>?
        let store = AssistantStore(persistenceURL: nil, complete: { messages, _, _ in
            sends += 1
            if sends == 1 {
                return ModelReply(content: "", toolCalls: [.init(name: "read_calendar", arguments: ["days": .string("7")])])
            }
            secondInputHadCalendar = messages.contains { $0.content.contains("OWNED_EVENT_CONTEXT") }
            await withCheckedContinuation { blocked = $0 }
            return ModelReply(content: "LATE_CALENDAR_REPLY", toolCalls: [.init(name: "write_file", arguments: ["path": .string(lateFile.path), "content": .string("late")])])
        }, execute: { call in
            if call.name == "read_calendar" {
                // No EventKit account or event access: only the Store boundary
                // is exercised with an inert calendar result.
                return ToolResult(summary: "OWNED_EVENT_CONTEXT", evidence: "Synthetic selected-event body", verified: true)
            }
            writes += 1
            return ToolResult(summary: "Unexpected late write", evidence: "Inert executor", verified: true)
        })
        store.grants = [.init(path: directory.path, writable: true)]
        store.calendarSource.selectedCalendarIDs = ["owned-synthetic-selection"]
        store.draft = "Read my selected calendar and describe the events."
        store.send()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while blocked == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(blocked != nil && secondInputHadCalendar)
        store.calendarSource.calendarDatabaseChanged()
        blocked?.resume(); blocked = nil
        await store.waitForConversationTaskToSettle()
        #expect(writes == 0 && !store.isRunning)
        #expect(!store.messages.contains { $0.text.contains("LATE_CALENDAR_REPLY") })
        #expect(!FileManager.default.fileExists(atPath: lateFile.path))
        #expect(store.calendarSource.selectedCalendarIDs == ["owned-synthetic-selection"])
        #expect(store.selectionNotice?.contains("Calendar data changed") == true)
        store.stop()
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

    @Test func permissionCopyDistinguishesOSFullAccessFromProductReadOnly() {
        #expect(CalendarSource.permissionExplanation.contains("full Calendar access"))
        #expect(CalendarSource.permissionExplanation.contains("no calendar creation, editing or deletion"))
        #expect(CalendarSource.authorizationDescription(.writeOnly).contains("cannot read"))
        #expect(CalendarSource.authorizationDescription(.denied).contains("denied"))
        #expect(CalendarSource.authorizationDescription(.notDetermined).contains("explicitly"))
        #expect(CalendarSource.authorizationDescription(.fullAccess).contains("only reads"))
    }

    @Test func displayTextIsBoundedWithoutRetainingEventMetadata() {
        #expect(CalendarSource.boundedTitle("  Meeting  ") == "Meeting")
        #expect(CalendarSource.boundedTitle(String(repeating: "🌍", count: 1000)).count == 512)
        let event = CalendarSource.EventInfo(id: "opaque", title: "Meeting", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60), calendarName: "Selected")
        #expect(Set(Mirror(reflecting: event).children.compactMap(\.label)) == ["id", "title", "start", "end", "calendarName"])
    }
}
