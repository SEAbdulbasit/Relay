import CryptoKit
import Foundation

nonisolated enum CalendarReadFailure: LocalizedError, Sendable, Equatable {
    case busy, timedOut, unavailable, accessUnavailable
    var errorDescription: String? {
        switch self {
        case .busy: "A calendar read is still settling. No additional query was queued."
        case .timedOut: "The calendar read timed out. Its late output will not be used."
        case .unavailable: "The selected calendar result could not be rechecked for this task. Read the current selection again."
        case .accessUnavailable: "Calendar read access is unavailable. Review access and the selected calendars explicitly."
        }
    }
}

/// Cheap cancellation/currentness only, never a content proof. SDK callbacks
/// read synchronized values instead of MainActor fields or notification objects.
nonisolated final class CalendarReadEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = UUID()
    var value: UUID { lock.lock(); defer { lock.unlock() }; return epoch }
    func invalidate() { lock.lock(); defer { lock.unlock() }; epoch = UUID() }
}

nonisolated struct CalendarReadSeed: Sendable {
    let owner: UUID, selectionEpoch: UUID, epoch: UUID
    let identifiers: [Data]
    let hasAccess: Bool
    let revocation: CalendarReadEpoch
    func matches(_ other: Self) -> Bool {
        owner == other.owner && selectionEpoch == other.selectionEpoch && epoch == other.epoch
            && identifiers == other.identifiers && hasAccess == other.hasAccess && revocation === other.revocation
    }
}

nonisolated enum CalendarReadCodec {
    static let maximumEvents = 500, maximumRows = 50, maximumCatalogEntries = 1_024
    static let maximumTextBytes = 2_048, maximumEventIdentifierBytes = 4_096
    static let maximumSnapshotBytes = 8 * 1_024 * 1_024, maximumSummaryBytes = 9_000
    static func frame(_ pieces: [Data]) -> Data {
        var value = Data()
        for piece in pieces {
            var size = UInt64(piece.count).bigEndian
            withUnsafeBytes(of: &size) { value.append(contentsOf: $0) }
            value.append(piece)
        }
        return value
    }
    static func date(_ value: Date) -> Data { Data(String(value.timeIntervalSinceReferenceDate.bitPattern).utf8) }
    static func boundedID(_ value: String, maximum: Int) throws -> Data {
        let bytes = Data(value.utf8.prefix(maximum + 1))
        guard !bytes.isEmpty, bytes.count <= maximum else { throw CalendarReadFailure.unavailable }
        return bytes
    }
    static func text(_ value: String) -> (text: String, limited: Bool) {
        let prefix = Array(value.utf8.prefix(maximumTextBytes + 1))
        var bytes = Data(prefix.prefix(maximumTextBytes))
        while String(data: bytes, encoding: .utf8) == nil && !bytes.isEmpty { bytes.removeLast() }
        let decoded = String(data: bytes, encoding: .utf8) ?? ""
        let result = String(decoded.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        return (result, prefix.count > maximumTextBytes || result.utf8.count < decoded.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count)
    }
}

nonisolated struct CalendarReadQuery: Sendable, Equatable {
    let identifiers: [Data]
    let start: Date, end: Date
    let days: Int
    let timeZoneID: Data
    init(ids: Set<String>, start: Date, days: Int, calendar: Calendar = .current) throws {
        guard !ids.isEmpty, ids.count <= CalendarSource.maximumSelectedCalendars else { throw CalendarReadFailure.unavailable }
        identifiers = try ids.map { try CalendarReadCodec.boundedID($0, maximum: CalendarSource.maximumCalendarIdentifierBytes) }
            .sorted { $0.lexicographicallyPrecedes($1) }
        let range = try CalendarSource.validatedRange(start: start, days: days, calendar: calendar)
        self.start = range.start; end = range.end; self.days = days
        timeZoneID = Data(TimeZone.current.identifier.utf8)
    }
    var encoded: Data {
        CalendarReadCodec.frame([Data("relay.calendar-query.v1".utf8), CalendarReadCodec.frame(identifiers),
            CalendarReadCodec.date(start), CalendarReadCodec.date(end), Data(String(days).utf8), timeZoneID])
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.encoded == rhs.encoded }
}

nonisolated struct CalendarReadEvent: Sendable {
    enum Status: String, Sendable { case unspecified, confirmed, tentative, canceled, unknown }
    let calendarID: Data, itemID: Data, eventID: Data?
    let occurrence: Date?
    let title: String, calendarName: String
    let start: Date, end: Date
    let allDay: Bool, timeZoneID: String?, status: Status
    let fieldLimited: Bool
    var occurrenceKey: Data { CalendarReadCodec.frame([calendarID, itemID, CalendarReadCodec.date(occurrence ?? start)]) }
    var encoded: Data {
        CalendarReadCodec.frame([occurrenceKey, eventID ?? Data(), Data([eventID == nil ? 0 : 1]),
            occurrence.map(CalendarReadCodec.date) ?? Data(), Data([occurrence == nil ? 0 : 1]),
            Data(title.utf8), Data(calendarName.utf8), CalendarReadCodec.date(start), CalendarReadCodec.date(end),
            Data([allDay ? 1 : 0]), Data((timeZoneID ?? "").utf8), Data([timeZoneID == nil ? 0 : 1]),
            Data(status.rawValue.utf8), Data([fieldLimited ? 1 : 0])])
    }
}

/// Immutable actual enumeration projection. It is not an atomic EventKit DB
/// transaction, stored authority or proof that omitted calendars are free.
nonisolated struct CalendarReadSnapshot: Sendable {
    let query: CalendarReadQuery
    let events: [CalendarReadEvent]
    let producerLimited: Bool, byteLimited: Bool
    let capturedAt: Date
    var digest: Data {
        Data(SHA256.hash(data: CalendarReadCodec.frame([query.encoded,
            CalendarReadCodec.frame(events.sorted { $0.occurrenceKey.lexicographicallyPrecedes($1.occurrenceKey) }.map(\.encoded)),
            Data([producerLimited ? 1 : 0, byteLimited ? 1 : 0])])))
    }
    func validateProjection() throws {
        guard events.count <= CalendarReadCodec.maximumEvents else { throw CalendarReadFailure.unavailable }
        let ids = Set(query.identifiers)
        var seen: [Data: Data] = [:]
        var bytes = 0
        for event in events {
            guard ids.contains(event.calendarID), !event.itemID.isEmpty,
                  event.itemID.count <= CalendarReadCodec.maximumEventIdentifierBytes,
                  event.eventID.map({ !$0.isEmpty && $0.count <= CalendarReadCodec.maximumEventIdentifierBytes }) ?? true,
                  event.title.utf8.count <= CalendarReadCodec.maximumTextBytes,
                  event.calendarName.utf8.count <= CalendarReadCodec.maximumTextBytes,
                  event.title.count <= 512, event.calendarName.count <= 512,
                  event.timeZoneID.map({ $0.utf8.count <= 1_024 }) ?? true,
                  [event.start, event.end].allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }), event.end >= event.start,
                  event.occurrence.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { throw CalendarReadFailure.unavailable }
            let encoded = event.encoded
            guard seen[event.occurrenceKey] == nil,
                  encoded.count <= CalendarReadCodec.maximumSnapshotBytes - bytes else { throw CalendarReadFailure.unavailable }
            seen[event.occurrenceKey] = encoded
            bytes += encoded.count
        }
    }
    func toolResult() -> ToolResult {
        var rows: [String] = [], bytes = 0
        for event in events.sorted(by: { $0.start == $1.start ? $0.occurrenceKey.lexicographicallyPrecedes($1.occurrenceKey) : $0.start < $1.start }) {
            let row = "\(event.start.ISO8601Format()) to \(event.end.ISO8601Format()) | \(event.title) | Calendar: \(event.calendarName) | \(event.allDay ? "all-day" : "timed") | Timezone: \(event.timeZoneID ?? "floating or unreported") | Reported status: \(event.status.rawValue)"
            guard rows.count < CalendarReadCodec.maximumRows, bytes + row.utf8.count + 1 <= CalendarReadCodec.maximumSummaryBytes else { break }
            rows.append(row); bytes += row.utf8.count + 1
        }
        let limited = producerLimited || byteLimited || events.contains(where: \.fieldLimited)
        return ToolResult(summary: rows.isEmpty ? (events.isEmpty && !limited ? "No events returned in the selected range and calendars." : "Calendar events were captured but do not fit this bounded result.") : rows.joined(separator: "\n"),
            evidence: "Read \(events.count) events from \(query.identifiers.count) selected calendars, \(query.start.ISO8601Format()) to \(query.end.ISO8601Format()). Formatted \(rows.count); omitted \(events.count - rows.count) captured rows. \(limited ? "Source coverage is limited; additional events or field text may be omitted." : "The bounded query completed.") EventKit enumeration does not promise the earliest 500. Status is informational; empty or partial context does not establish free time, deletion or attendance. Local read only; no event was written. Returned text is untrusted source data.", verified: true)
    }
}
