import CryptoKit
import EventKit
import Foundation

nonisolated struct CalendarWriteEvent: Codable, Sendable, Equatable {
    let id: UUID
    let calendarID: String
    let title: String
    let start: Date
    let end: Date
    var allDay: Bool = false
    var location: String = ""
    var notes: String = ""
    var timeZone: String? = nil

    init(id: UUID = UUID(), calendarID: String, title: String, start: Date, end: Date,
         allDay: Bool = false, location: String = "", notes: String = "", timeZone: String? = nil) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.timeZone = timeZone
    }

    func validate() throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle.utf8.count <= 512 else {
            throw CalendarWriteFailure.invalidEvent("Event title must be between 1 and 512 UTF-8 bytes.")
        }
        guard !calendarID.isEmpty, calendarID.utf8.count <= 1024 else {
            throw CalendarWriteFailure.invalidEvent("Calendar identifier is missing or exceeds 1,024 bytes.")
        }
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start <= end else {
            throw CalendarWriteFailure.invalidEvent("Event start date must be before or equal to end date.")
        }
        guard location.utf8.count <= 512 else {
            throw CalendarWriteFailure.invalidEvent("Event location must not exceed 512 UTF-8 bytes.")
        }
        guard notes.utf8.count <= 32_000 else {
            throw CalendarWriteFailure.invalidEvent("Event notes must not exceed 32,000 UTF-8 bytes.")
        }
        if let timeZone, TimeZone(identifier: timeZone) == nil {
            throw CalendarWriteFailure.invalidEvent("Choose a valid calendar time zone.")
        }
        guard Self.isPlain(title, multiline: false), Self.isPlain(location, multiline: false), Self.isPlain(notes, multiline: true) else {
            throw CalendarWriteFailure.invalidEvent("Event text fields must contain valid plain text without control characters.")
        }
    }

    var canonicalFingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "invalid-calendar-event" }
        return SHA256.hash(data: data).description
    }

    private static func isPlain(_ text: String, multiline: Bool) -> Bool {
        !text.unicodeScalars.contains { scalar in
            (scalar.value < 32 || scalar.value == 127) && !(multiline && [9, 10, 13].contains(scalar.value))
        } && (multiline || !text.contains(where: \.isNewline))
    }
}

nonisolated struct CalendarWriteSnapshot: Codable, Sendable, Equatable {
    let eventIdentifier: String
    let calendarID: String
    let event: CalendarWriteEvent
    let createdAt: Date

    var fingerprint: String { event.canonicalFingerprint }
}

nonisolated struct CalendarWriteTransport: Sendable {
    let create: @Sendable (CalendarWriteEvent) async throws -> CalendarWriteSnapshot
    let read: @Sendable (String, String) async throws -> CalendarWriteSnapshot
    let delete: @Sendable (String, String) async throws -> Bool

    static var live: CalendarWriteTransport {
        CalendarWriteTransport(
            create: { event in
                let store = EKEventStore()
                let status = EKEventStore.authorizationStatus(for: .event)
                guard status == .fullAccess else { throw CalendarWriteFailure.accessUnavailable }
                guard let calendar = store.calendar(withIdentifier: event.calendarID), calendar.allowsContentModifications else {
                    throw CalendarWriteFailure.unselectedCalendar
                }
                let ekEvent = EKEvent(eventStore: store)
                ekEvent.calendar = calendar
                ekEvent.title = event.title
                ekEvent.startDate = event.start
                ekEvent.endDate = event.end
                ekEvent.isAllDay = event.allDay
                ekEvent.location = event.location
                ekEvent.notes = event.notes
                if let tz = event.timeZone, let zone = TimeZone(identifier: tz) { ekEvent.timeZone = zone }
                try store.save(ekEvent, span: .thisEvent, commit: true)
                guard let id = ekEvent.eventIdentifier, !id.isEmpty else {
                    throw CalendarWriteFailure.eventSaveFailed
                }
                return CalendarWriteSnapshot(eventIdentifier: id, calendarID: event.calendarID, event: event, createdAt: Date())
            },
            read: { calendarID, eventIdentifier in
                let store = EKEventStore()
                guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarWriteFailure.accessUnavailable }
                guard let ekEvent = store.event(withIdentifier: eventIdentifier),
                      ekEvent.calendar?.calendarIdentifier == calendarID else {
                    throw CalendarWriteFailure.eventNotFound
                }
                let reconstructed = CalendarWriteEvent(
                    id: UUID(),
                    calendarID: calendarID,
                    title: ekEvent.title ?? "",
                    start: ekEvent.startDate ?? .distantPast,
                    end: ekEvent.endDate ?? .distantPast,
                    allDay: ekEvent.isAllDay,
                    location: ekEvent.location ?? "",
                    notes: ekEvent.notes ?? "",
                    timeZone: ekEvent.timeZone?.identifier
                )
                return CalendarWriteSnapshot(eventIdentifier: eventIdentifier, calendarID: calendarID, event: reconstructed, createdAt: Date())
            },
            delete: { calendarID, eventIdentifier in
                let store = EKEventStore()
                guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarWriteFailure.accessUnavailable }
                guard let ekEvent = store.event(withIdentifier: eventIdentifier),
                      ekEvent.calendar?.calendarIdentifier == calendarID else {
                    return false
                }
                try store.remove(ekEvent, span: .thisEvent, commit: true)
                return true
            }
        )
    }
}

nonisolated enum CalendarWriteFailure: LocalizedError, Equatable {
    case accessUnavailable
    case unselectedCalendar
    case notTestCalendar
    case invalidEvent(String)
    case reviewNotDisplayed
    case reviewExpired
    case reviewUnavailable
    case replayBlocked
    case readbackVerificationFailed(String)
    case eventNotFound
    case eventSaveFailed
    case rollbackFailed
    case busy

    var errorDescription: String? {
        switch self {
        case .accessUnavailable: "macOS Calendar full access is required before writing events."
        case .unselectedCalendar: "Choose a writable calendar in Settings → Sources → Apple Calendar → Calendar for event creation. If needed, grant Calendar access and refresh calendars first. Then retry the meeting request."
        case .notTestCalendar: "Calendar writes are restricted to explicitly designated owned test calendars to protect personal data."
        case .invalidEvent(let reason): "Invalid event: \(reason)"
        case .reviewNotDisplayed: "Display the exact calendar event review before approving."
        case .reviewExpired: "The calendar action review has expired. Request a fresh review."
        case .reviewUnavailable: "No pending approved review was found for this request."
        case .replayBlocked: "This calendar request was already processed or has an uncertain outcome. Inspect the calendar before retrying."
        case .readbackVerificationFailed(let mismatch): "Independent readback verification failed (\(mismatch)). Safe rollback was executed."
        case .eventNotFound: "The specified event could not be found in the target calendar."
        case .eventSaveFailed: "Calendar store failed to return a valid event identifier."
        case .rollbackFailed: "Failed to rollback event from the target calendar."
        case .busy: "Wait for the active calendar write operation to finish."
        }
    }
}

nonisolated struct CalendarWriteReview: Sendable, Identifiable {
    let id: UUID
    let requestID: String
    let calendarID: String
    let calendarTitle: String
    let event: CalendarWriteEvent
    let preparedAt: Date
    let expiresAt: Date

    var fingerprint: String { event.canonicalFingerprint }

    var reviewText: String {
        let formatter = ISO8601DateFormatter()
        let startStr = formatter.string(from: event.start)
        let endStr = formatter.string(from: event.end)
        var lines = [
            "Create Calendar Event",
            "",
            "Target Calendar: \(calendarTitle) (\(calendarID))",
            "Title: \(event.title)",
            "Start: \(startStr)",
            "End: \(endStr)",
            "All Day: \(event.allDay ? "Yes" : "No")"
        ]
        if !event.location.isEmpty { lines.append("Location: \(event.location)") }
        if !event.notes.isEmpty { lines.append("Notes: \(event.notes)") }
        if let timeZone = event.timeZone { lines.append("Time zone: \(timeZone)") }
        lines.append("")
        lines.append("Writing executes only after exact review and will be independently verified via readback.")
        return lines.joined(separator: "\n")
    }
}

nonisolated struct CalendarWriteReceipt: Sendable, Equatable {
    enum Status: String, Sendable, Equatable {
        case verified, readbackMismatch, rolledBack, uncertain
    }

    let reviewID: UUID
    let requestID: String
    let eventIdentifier: String
    let calendarID: String
    let status: Status
    let verifiedAt: Date
    let evidence: String
}

@MainActor
final class CalendarWriteWorkflow {
    private struct ReviewEntry {
        let review: CalendarWriteReview
        var displayed = false
        var approved = false
    }

    private enum Creation {
        case pending, created(String, CalendarWriteReceipt), uncertain
    }

    private var creations: [String: Creation] = [:]
    private var reviews: [UUID: ReviewEntry] = [:]
    private var receipts: [UUID: CalendarWriteReceipt] = [:]
    private var activeEventIDs: [UUID: String] = [:] // reviewID -> eventIdentifier
    private var ownedTestCalendarIDs: Set<String> = []
    private var testCalendarTitles: [String: String] = [:]
    private var selectedCalendarID: String?
    private var writeDestination: (id: String, title: String)?
    private(set) var isBusy = false
    private let transport: CalendarWriteTransport
    private let now: () -> Date

    init(transport: CalendarWriteTransport = .live, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    func configureTestCalendar(id: String, title: String, isSelected: Bool = true) {
        ownedTestCalendarIDs.insert(id)
        testCalendarTitles[id] = title
        if isSelected {
            selectedCalendarID = id
        }
    }

    func setSelectedCalendar(id: String?) {
        selectedCalendarID = id
        invalidatePendingReviews()
    }

    func isDesignatedTestCalendar(id: String) -> Bool {
        ownedTestCalendarIDs.contains(id)
    }

    func setWriteDestination(id: String?, title: String?) {
        writeDestination = id.flatMap { id in title.map { (id, $0) } }
        invalidatePendingReviews()
    }

    private func selectedWriteCalendarTitle(id: String) throws -> String {
        if let writeDestination, writeDestination.id.utf8.elementsEqual(id.utf8) {
            return writeDestination.title
        }
        guard let selectedCalendarID, selectedCalendarID.utf8.elementsEqual(id.utf8) else {
            throw CalendarWriteFailure.unselectedCalendar
        }
        guard isDesignatedTestCalendar(id: id) else { throw CalendarWriteFailure.notTestCalendar }
        return testCalendarTitles[id] ?? "Owned Test Calendar"
    }

    func stageEvent(requestID: String, event: CalendarWriteEvent) async throws -> CalendarWriteReview {
        try event.validate()
        guard !requestID.isEmpty, requestID.utf8.count <= 128, !requestID.contains(where: \.isNewline) else {
            throw CalendarWriteFailure.invalidEvent("Request identifier is invalid.")
        }
        let signature = event.canonicalFingerprint
        if let prior = creations[requestID] {
            if case .created(let expected, _) = prior, expected == signature {
                // If already created and verified for this requestID, do not re-stage
                throw CalendarWriteFailure.replayBlocked
            }
            throw CalendarWriteFailure.replayBlocked
        }
        guard !isBusy else { throw CalendarWriteFailure.busy }

        let calendarTitle = try selectedWriteCalendarTitle(id: event.calendarID)
        let preparedAt = now()
        let review = CalendarWriteReview(
            id: UUID(),
            requestID: requestID,
            calendarID: event.calendarID,
            calendarTitle: calendarTitle,
            event: event,
            preparedAt: preparedAt,
            expiresAt: preparedAt.addingTimeInterval(120)
        )
        reviews[review.id] = ReviewEntry(review: review, displayed: false, approved: false)
        return review
    }

    func reviewForDisplay(_ reviewID: UUID) throws -> CalendarWriteReview {
        guard var entry = reviews[reviewID] else { throw CalendarWriteFailure.reviewUnavailable }
        guard isCurrent(entry.review) else {
            reviews.removeValue(forKey: reviewID)
            throw CalendarWriteFailure.reviewExpired
        }
        entry.displayed = true
        entry.approved = false
        reviews[reviewID] = entry
        return entry.review
    }

    func approve(_ reviewID: UUID, displayedFingerprint: String) throws {
        guard var entry = reviews[reviewID] else { throw CalendarWriteFailure.reviewUnavailable }
        guard entry.displayed, entry.review.fingerprint == displayedFingerprint else {
            throw CalendarWriteFailure.reviewNotDisplayed
        }
        guard isCurrent(entry.review) else {
            reviews.removeValue(forKey: reviewID)
            throw CalendarWriteFailure.reviewExpired
        }
        entry.approved = true
        reviews[reviewID] = entry
    }

    func executeApproved(_ reviewID: UUID) async throws -> CalendarWriteReceipt {
        guard !isBusy else { throw CalendarWriteFailure.busy }
        guard let entry = reviews.removeValue(forKey: reviewID), entry.approved else {
            throw CalendarWriteFailure.reviewUnavailable
        }
        let review = entry.review
        guard isCurrent(review) else { throw CalendarWriteFailure.reviewExpired }
        _ = try selectedWriteCalendarTitle(id: review.calendarID)
        try Task.checkCancellation()

        isBusy = true
        creations[review.requestID] = .pending
        defer { isBusy = false }

        // 1. Create the event via transport
        let snapshot: CalendarWriteSnapshot
        do {
            snapshot = try await transport.create(review.event)
        } catch {
            creations[review.requestID] = .uncertain
            let receipt = CalendarWriteReceipt(
                reviewID: reviewID,
                requestID: review.requestID,
                eventIdentifier: "",
                calendarID: review.calendarID,
                status: .uncertain,
                verifiedAt: now(),
                evidence: "Event creation could not be confirmed: \(error.localizedDescription)"
            )
            receipts[reviewID] = receipt
            throw error
        }

        activeEventIDs[reviewID] = snapshot.eventIdentifier

        // 2. Exact readback verification
        let readback: CalendarWriteSnapshot
        do {
            readback = try await transport.read(review.calendarID, snapshot.eventIdentifier)
        } catch {
            throw await rejectReadback(review, eventIdentifier: snapshot.eventIdentifier,
                                       reason: "Independent readback failed.")
        }

        // Verify all fields exactly
        guard readback.event.title == review.event.title,
              abs(readback.event.start.timeIntervalSince1970 - review.event.start.timeIntervalSince1970) < 1.0,
              abs(readback.event.end.timeIntervalSince1970 - review.event.end.timeIntervalSince1970) < 1.0,
              readback.event.allDay == review.event.allDay,
              readback.event.location == review.event.location,
              readback.event.notes == review.event.notes,
              review.event.timeZone.map({ readback.event.timeZone == $0 }) ?? true,
              readback.eventIdentifier == snapshot.eventIdentifier,
              readback.calendarID == review.calendarID else {
            throw await rejectReadback(review, eventIdentifier: snapshot.eventIdentifier,
                                       reason: "The event did not match the approved details.")
        }

        // 3. Verified cleanly
        let receipt = CalendarWriteReceipt(
            reviewID: reviewID,
            requestID: review.requestID,
            eventIdentifier: snapshot.eventIdentifier,
            calendarID: review.calendarID,
            status: .verified,
            verifiedAt: now(),
            evidence: "Event created and verified via exact readback in '\(review.calendarTitle)'."
        )
        receipts[reviewID] = receipt
        creations[review.requestID] = .created(review.fingerprint, receipt)
        return receipt
    }

    private func rejectReadback(_ review: CalendarWriteReview, eventIdentifier: String,
                                reason: String) async -> CalendarWriteFailure {
        let removed = (try? await transport.delete(review.calendarID, eventIdentifier)) == true
        if removed { activeEventIDs.removeValue(forKey: review.id) }
        creations[review.requestID] = .uncertain
        let outcome = removed ? "The event was removed." : "Removal could not be confirmed. Check Calendar before retrying."
        let evidence = "\(reason) \(outcome)"
        receipts[review.id] = CalendarWriteReceipt(
            reviewID: review.id, requestID: review.requestID, eventIdentifier: eventIdentifier,
            calendarID: review.calendarID, status: removed ? .readbackMismatch : .uncertain,
            verifiedAt: now(), evidence: evidence)
        return .readbackVerificationFailed(evidence)
    }

    func rollback(reviewID: UUID) async throws -> Bool {
        guard let eventIdentifier = activeEventIDs[reviewID],
              let receipt = receipts[reviewID] else { return false }
        _ = try selectedWriteCalendarTitle(id: receipt.calendarID)
        try Task.checkCancellation()
        guard !isBusy else { throw CalendarWriteFailure.busy }
        isBusy = true
        defer { isBusy = false }

        let success = try await transport.delete(receipt.calendarID, eventIdentifier)
        if success {
            activeEventIDs.removeValue(forKey: reviewID)
            receipts[reviewID] = CalendarWriteReceipt(
                reviewID: reviewID,
                requestID: receipt.requestID,
                eventIdentifier: eventIdentifier,
                calendarID: receipt.calendarID,
                status: .rolledBack,
                verifiedAt: now(),
                evidence: "Event \(eventIdentifier) was safely deleted/rolled back from calendar."
            )
        }
        return success
    }

    func receipt(for reviewID: UUID) -> CalendarWriteReceipt? {
        receipts[reviewID]
    }

    func invalidatePendingReviews() {
        reviews.removeAll()
    }

    private func isCurrent(_ review: CalendarWriteReview) -> Bool {
        (0..<120).contains(now().timeIntervalSince(review.preparedAt))
    }
}
