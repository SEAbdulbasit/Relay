import CryptoKit
import EventKit
import Foundation

nonisolated struct CalendarCoverage: Codable, Equatable, Sendable {
    let version: Int
    let lower: Date
    let upper: Date
    let selectionHash: String

    init(now: Date = Date(), ids: Set<String>, calendar: Calendar = .current) {
        self.version = 1
        let day = calendar.startOfDay(for: now)
        self.lower = calendar.date(byAdding: .day, value: -7, to: day) ?? day.addingTimeInterval(-7 * 86_400)
        self.upper = calendar.date(byAdding: .day, value: 31, to: day) ?? day.addingTimeInterval(31 * 86_400)
        self.selectionHash = CalendarSelectionIdentity.digest(ids.sorted())
    }

    init(lower: Date, upper: Date, selectionHash: String) {
        self.version = 1
        self.lower = lower
        self.upper = upper
        self.selectionHash = selectionHash
    }

    var scheduleDescription: String {
        let formatter = ISO8601DateFormatter()
        return "Window: \(formatter.string(from: lower)) to \(formatter.string(from: upper)), end exclusive."
    }

    func matches(ids: Set<String>) -> Bool {
        selectionHash == CalendarSelectionIdentity.digest(ids.sorted())
    }
}

nonisolated struct CalendarOccurrence: Identifiable, Equatable, Sendable {
    let id: String
    let calendarID: String
    let calendarName: String
    let itemID: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let timeZone: String
    let location: String
    let notes: String
    let scheduleStatus: String
    let availability: String
    let participantResponse: String
    let contentFingerprint: String

    init(calendarID: String, calendarName: String, itemID: String, title: String,
         start: Date, end: Date, allDay: Bool, timeZone: String = TimeZone.current.identifier,
         location: String = "", notes: String = "",
         scheduleStatus: String = "confirmed", availability: String = "busy",
         participantResponse: String = "accepted", occurrenceDate: Date? = nil) {
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.itemID = itemID
        self.title = CalendarSource.boundedTitle(title)
        self.start = start
        self.end = end
        self.allDay = allDay
        self.timeZone = timeZone
        self.location = String(location.prefix(512))
        self.notes = String(notes.prefix(3_000))
        self.scheduleStatus = scheduleStatus
        self.availability = availability
        self.participantResponse = participantResponse

        let occ = occurrenceDate ?? start
        self.id = CalendarOccurrence.makeOccurrenceID(calendarID: calendarID, itemID: itemID, occurrenceDate: occ)

        var digestData = Data()
        digestData.append(contentsOf: calendarID.utf8)
        digestData.append(contentsOf: itemID.utf8)
        digestData.append(contentsOf: title.utf8)
        digestData.append(contentsOf: String(start.timeIntervalSince1970).utf8)
        digestData.append(contentsOf: String(end.timeIntervalSince1970).utf8)
        digestData.append(contentsOf: (allDay ? "allDay" : "timed").utf8)
        digestData.append(contentsOf: location.utf8)
        digestData.append(contentsOf: notes.utf8)
        self.contentFingerprint = SHA256.hash(data: digestData).description
    }

    static func makeOccurrenceID(calendarID: String, itemID: String, occurrenceDate: Date) -> String {
        let timestamp = Int64(occurrenceDate.timeIntervalSince1970)
        return "\(calendarID):\(itemID):\(timestamp)"
    }

    var summaryText: String {
        let formatter = ISO8601DateFormatter()
        var text = "\(formatter.string(from: start)) to \(formatter.string(from: end)) | \(title) | Calendar: \(calendarName)"
        if allDay { text += " (All Day)" }
        if !location.isEmpty { text += " | Location: \(location)" }
        text += " | Status: \(scheduleStatus), Response: \(participantResponse)"
        return text
    }
}

nonisolated struct CalendarSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let coverage: CalendarCoverage
    let occurrences: [CalendarOccurrence]

    init(capturedAt: Date = Date(), coverage: CalendarCoverage, occurrences: [CalendarOccurrence]) {
        self.capturedAt = capturedAt
        self.coverage = coverage
        self.occurrences = occurrences.sorted { $0.start < $1.start }
    }

    var markerText: String {
        let formatter = ISO8601DateFormatter()
        return """
        Apple Calendar schedule snapshot as of \(formatter.string(from: capturedAt)).
        \(coverage.scheduleDescription)
        Only explicitly selected calendars synced to this Mac were read. Privacy-filtered summaries accompany this snapshot.
        Replace earlier Apple Calendar schedule claims in this window with the current summaries.
        Missing summaries do not prove deletion, attendance, or free time.
        Total occurrences in window: \(occurrences.count).
        """
    }

    func unchangedOccurrenceIDs(comparedTo earlier: CalendarSnapshot) -> Set<String> {
        let earlierMap = Dictionary(earlier.occurrences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(occurrences.filter { earlierMap[$0.id]?.contentFingerprint == $0.contentFingerprint }.map(\.id))
    }

    func changedOccurrenceIDs(comparedTo earlier: CalendarSnapshot) -> Set<String> {
        let earlierIDs = Set(earlier.occurrences.map(\.id))
        let currentIDs = Set(occurrences.map(\.id))
        let addedOrRemoved = earlierIDs.symmetricDifference(currentIDs)
        let earlierMap = Dictionary(earlier.occurrences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mutated = occurrences.filter {
            if let prior = earlierMap[$0.id] {
                return prior.contentFingerprint != $0.contentFingerprint
            }
            return false
        }.map(\.id)
        return addedOrRemoved.union(mutated)
    }

    static func normalizeInterval(start: Date, end: Date, allDay: Bool, zone: TimeZone = .current) -> (Date, Date) {
        guard allDay else { return (start, end) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        let exclusive = (end == last && end > first) ? last : (calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400))
        return (first, exclusive)
    }
}
