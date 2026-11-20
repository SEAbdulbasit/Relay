import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
struct CalendarSourceParityTests {
    init() async throws {
        await awaitParitySuiteQuietWindow()
    }

    // MARK: - 1. Fixed Local Window & Coverage (SRC-15)

    @Test func fixedLocalWindowCoversSevenDaysPriorToThirtyOneDaysForward() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let startOfDay = calendar.startOfDay(for: now)

        let selectedIDs: Set<String> = ["cal-work", "cal-personal"]
        let coverage = CalendarCoverage(now: now, ids: selectedIDs, calendar: calendar)

        // Lower bound must be exactly 7 days before startOfDay
        let expectedLower = calendar.date(byAdding: .day, value: -7, to: startOfDay)!
        #expect(coverage.lower == expectedLower)

        // Upper bound must be exactly 31 days after startOfDay
        let expectedUpper = calendar.date(byAdding: .day, value: 31, to: startOfDay)!
        #expect(coverage.upper == expectedUpper)

        // Matches selected IDs
        #expect(coverage.matches(ids: selectedIDs))
        #expect(!coverage.matches(ids: ["cal-work"]))

        // Schedule description notes window
        #expect(coverage.scheduleDescription.contains("Window:"))
        #expect(coverage.scheduleDescription.contains("end exclusive"))
    }

    // MARK: - 2. Interval Normalization (SRC-15)

    @Test func allDayIntervalNormalizationSpansExactDayBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_700_000_000) // mid-day
        let end = Date(timeIntervalSince1970: 1_700_050_000)

        // Non-all-day event preserves exact timestamps
        let (timedStart, timedEnd) = CalendarSnapshot.normalizeInterval(start: start, end: end, allDay: false, zone: calendar.timeZone)
        #expect(timedStart == start)
        #expect(timedEnd == end)

        // All-day event expands to start of day and day after end of day
        let (allDayStart, allDayEnd) = CalendarSnapshot.normalizeInterval(start: start, end: end, allDay: true, zone: calendar.timeZone)
        #expect(allDayStart == calendar.startOfDay(for: start))
        let expectedNextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        #expect(allDayEnd == expectedNextDay)
    }

    // MARK: - 3. Occurrence Identity & Recurrence Expansion (SRC-16)

    @Test func recurrenceOccurrencesGenerateStableCompositeIDs() {
        let calendarID = "cal-team-1"
        let itemID = "event-recurring-series-uuid"
        let occDate1 = Date(timeIntervalSince1970: 1_700_000_000)
        let occDate2 = Date(timeIntervalSince1970: 1_700_086_400) // next day

        let id1 = CalendarOccurrence.makeOccurrenceID(calendarID: calendarID, itemID: itemID, occurrenceDate: occDate1)
        let id2 = CalendarOccurrence.makeOccurrenceID(calendarID: calendarID, itemID: itemID, occurrenceDate: occDate2)

        #expect(id1 == "\(calendarID):\(itemID):1700000000")
        #expect(id2 == "\(calendarID):\(itemID):1700086400")
        #expect(id1 != id2, "Distinct recurrence instances must have distinct stable occurrence IDs")

        let occ1 = CalendarOccurrence(
            calendarID: calendarID,
            calendarName: "Team",
            itemID: itemID,
            title: "Daily Standup",
            start: occDate1,
            end: occDate1.addingTimeInterval(900),
            allDay: false,
            scheduleStatus: "confirmed",
            availability: "busy",
            participantResponse: "accepted",
            occurrenceDate: occDate1
        )
        #expect(occ1.id == id1)
        #expect(occ1.scheduleStatus == "confirmed")
        #expect(occ1.availability == "busy")
        #expect(occ1.participantResponse == "accepted")
    }

    // MARK: - 4. Atomic Snapshot Replacement & Change Detection (SRC-16)

    @Test func snapshotChangeDetectionDistinguishesMutationsAndAdditions() {
        let coverage = CalendarCoverage(lower: Date(timeIntervalSince1970: 0), upper: Date(timeIntervalSince1970: 100_000), selectionHash: "hash-1")

        let occ1 = CalendarOccurrence(
            calendarID: "cal-1",
            calendarName: "Work",
            itemID: "item-1",
            title: "Design Review",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000),
            allDay: false,
            location: "Room 101"
        )
        let occ2 = CalendarOccurrence(
            calendarID: "cal-1",
            calendarName: "Work",
            itemID: "item-2",
            title: "1-on-1 Sync",
            start: Date(timeIntervalSince1970: 3000),
            end: Date(timeIntervalSince1970: 4000),
            allDay: false
        )

        let initialSnapshot = CalendarSnapshot(coverage: coverage, occurrences: [occ1, occ2])

        // 1. Unchanged snapshot comparison
        let sameSnapshot = CalendarSnapshot(coverage: coverage, occurrences: [occ1, occ2])
        #expect(sameSnapshot.unchangedOccurrenceIDs(comparedTo: initialSnapshot) == Set([occ1.id, occ2.id]))
        #expect(sameSnapshot.changedOccurrenceIDs(comparedTo: initialSnapshot).isEmpty)

        // 2. Mutated location on occ1
        let mutatedOcc1 = CalendarOccurrence(
            calendarID: "cal-1",
            calendarName: "Work",
            itemID: "item-1",
            title: "Design Review",
            start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000),
            allDay: false,
            location: "Room 202" // Changed location!
        )
        let mutatedSnapshot = CalendarSnapshot(coverage: coverage, occurrences: [mutatedOcc1, occ2])
        #expect(mutatedSnapshot.unchangedOccurrenceIDs(comparedTo: initialSnapshot) == Set([occ2.id]))
        #expect(mutatedSnapshot.changedOccurrenceIDs(comparedTo: initialSnapshot) == Set([occ1.id]))

        // 3. Removed occ2 and added occ3
        let occ3 = CalendarOccurrence(
            calendarID: "cal-1",
            calendarName: "Work",
            itemID: "item-3",
            title: "New All Hands",
            start: Date(timeIntervalSince1970: 5000),
            end: Date(timeIntervalSince1970: 6000),
            allDay: false
        )
        let updatedSnapshot = CalendarSnapshot(coverage: coverage, occurrences: [occ1, occ3])
        let changed = updatedSnapshot.changedOccurrenceIDs(comparedTo: initialSnapshot)
        #expect(changed.contains(occ2.id)) // deleted
        #expect(changed.contains(occ3.id)) // added
        #expect(!changed.contains(occ1.id)) // unchanged
    }

    // MARK: - 5. Stale-Note Withdrawal Marker Text (SRC-16)

    @Test func snapshotMarkerTextExplicitlyInstructsStaleNoteWithdrawal() {
        let coverage = CalendarCoverage(lower: Date(timeIntervalSince1970: 0), upper: Date(timeIntervalSince1970: 100_000), selectionHash: "hash-1")
        let snapshot = CalendarSnapshot(coverage: coverage, occurrences: [])
        let marker = snapshot.markerText

        #expect(marker.contains("Apple Calendar schedule snapshot as of"))
        #expect(marker.contains("Only explicitly selected calendars synced to this Mac were read"))
        #expect(marker.contains("Replace earlier Apple Calendar schedule claims in this window with the current summaries"))
        #expect(marker.contains("Missing summaries do not prove deletion, attendance, or free time"))
    }
}
