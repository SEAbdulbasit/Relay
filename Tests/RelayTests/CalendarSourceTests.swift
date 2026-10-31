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
