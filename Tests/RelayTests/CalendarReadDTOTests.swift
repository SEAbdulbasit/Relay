import Foundation
import Testing
@testable import Relay

struct CalendarReadDTOTests {
    private func query(_ ids: Set<String> = ["owned"], days: Int = 7) throws -> CalendarReadQuery {
        try .init(ids: ids, start: Date(timeIntervalSince1970: 1_700_000_000), days: days)
    }
    @Test func exactIdentifiersAndQueryBoundsNeverExpandAnEmptySelection() throws {
        let a = try query(["caf\u{e9}"]), b = try query(["cafe\u{301}"])
        #expect(a != b && a.identifiers != b.identifiers)
        let invalid: [Set<String>] = [[], [""], [String(repeating: "x", count: 1_025)], Set((0..<21).map { "id-\($0)" })]
        for ids in invalid {
            #expect(throws: (any Error).self) { try query(ids) }
        }
        for days in [0, 32, Int.max] { #expect(throws: (any Error).self) { try query(days: days) } }
        #expect(try query([String(repeating: "x", count: 1_024)], days: 31).days == 31)
    }
    @Test func digestCoversActualFieldsAndCoverageButNotCaptureClockOrEnumerationOrder() throws {
        let q = try query(), a = CalendarProtocolBackend.event(q), b = CalendarProtocolBackend.event(q, index: 1)
        let first = CalendarReadSnapshot(query: q, events: [a,b], producerLimited: false, byteLimited: false, capturedAt: .distantPast)
        let later = CalendarReadSnapshot(query: q, events: [b,a], producerLimited: false, byteLimited: false, capturedAt: .distantFuture)
        try first.validateProjection(); try later.validateProjection()
        #expect(first.digest == later.digest)
        let changed = CalendarReadSnapshot(query: q, events: [a, CalendarProtocolBackend.event(q, index: 1, title: "Changed actual field")],
            producerLimited: false, byteLimited: false, capturedAt: .distantPast)
        #expect(changed.digest != first.digest)
        #expect(CalendarReadSnapshot(query: q, events: [a,b], producerLimited: true, byteLimited: false, capturedAt: .distantPast).digest != first.digest)
        #expect(first.toolResult().summary.contains("floating or unreported"))
        #expect(first.toolResult().summary.contains("Reported status: tentative"))
        #expect(first.toolResult().evidence.contains("does not establish free time"))
    }
    @Test func wholeRowFormattingKeepsByteAndRowCapsAndExplainsOmissions() throws {
        let q = try query(), title = String(repeating: "🌍", count: 512)
        let many = (0..<500).map { CalendarProtocolBackend.event(q, index: $0, title: title) }
        let snapshot = CalendarReadSnapshot(query: q, events: many, producerLimited: true, byteLimited: false, capturedAt: Date())
        try snapshot.validateProjection()
        let result = snapshot.toolResult(), rows = result.summary.split(separator: "\n")
        #expect(result.summary.utf8.count <= CalendarReadCodec.maximumSummaryBytes && rows.count <= 50 && rows.count < 500)
        #expect(rows.allSatisfy { $0.contains(title) && $0.hasSuffix("Reported status: tentative") })
        #expect(result.evidence.contains("omitted \(500 - rows.count) captured rows") && result.evidence.contains("coverage is limited"))
    }
    @Test func malformedDuplicatesAndOversizeInputsAreRefusedRatherThanEmptySuccess() throws {
        let q = try query(), event = CalendarProtocolBackend.event(q)
        for events in [[event,event], Array(repeating: event, count: 501), [CalendarProtocolBackend.event(q, title: String(repeating: "a", count: 2_049))]] {
            let value = CalendarReadSnapshot(query: q, events: events, producerLimited: false, byteLimited: false, capturedAt: Date())
            #expect(throws: CalendarReadFailure.self) { try value.validateProjection() }
        }
        let trimmed = CalendarReadCodec.text(String(repeating: "🌍", count: 1_000))
        #expect(trimmed.limited && trimmed.text.utf8.count <= 2_048 && trimmed.text.count <= 512)
        let empty = CalendarReadSnapshot(query: q, events: [], producerLimited: false, byteLimited: false, capturedAt: Date()).toolResult()
        let partial = CalendarReadSnapshot(query: q, events: [], producerLimited: true, byteLimited: false, capturedAt: Date()).toolResult()
        #expect(empty.summary != partial.summary && partial.evidence.contains("coverage is limited"))
    }
    @Test func actualAllDayTimezoneAndStatusProjectionDoesNotInventAttendanceOrEndNormalization() throws {
        let q = try query(), start = q.start, end = q.start.addingTimeInterval(86_400)
        let event = CalendarReadEvent(calendarID: q.identifiers[0], itemID: Data("all-day-item".utf8), eventID: nil,
            occurrence: nil, title: "Owned all-day event", calendarName: "Owned", start: start, end: end,
            allDay: true, timeZoneID: "Europe/London", status: .canceled, fieldLimited: false)
        let snapshot = CalendarReadSnapshot(query: q, events: [event], producerLimited: false, byteLimited: false, capturedAt: Date())
        try snapshot.validateProjection()
        let result = snapshot.toolResult()
        #expect(result.summary.contains(start.ISO8601Format() + " to " + end.ISO8601Format()))
        #expect(result.summary.contains("all-day | Timezone: Europe/London | Reported status: canceled"))
        #expect(result.evidence.contains("does not establish free time, deletion or attendance"))
    }

}
