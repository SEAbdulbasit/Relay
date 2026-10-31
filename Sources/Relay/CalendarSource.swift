import AppKit
import EventKit
import Foundation
import Observation

/// Explicitly enabled, product-read-only access to calendars already available on this Mac.
/// EventKit's macOS permission is *full access*, even though Relay exposes no calendar write API.
@Observable @MainActor
final class CalendarSource {
    nonisolated struct CalendarInfo: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
    }
    nonisolated struct EventInfo: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendarName: String
    }

    var onContextInvalidated: (() -> Void)?
    @ObservationIgnored private var authorizationObservers: [NSObjectProtocol] = []

    var status: String
    var errorMessage: String?
    private(set) var isLoading = false
    private(set) var hasAccess: Bool
    private(set) var calendars: [CalendarInfo] = []
    private(set) var events: [EventInfo] = []
    var selectedCalendarIDs: Set<String> = [] {
        didSet {
            if oldValue != selectedCalendarIDs {
                revision += 1
                events = []
                errorMessage = nil
                status = selectedCalendarIDs.isEmpty ? "Choose calendars explicitly before reading events." : "Selection changed. Refresh to read this scope."
                onContextInvalidated?()
            }
        }
    }
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var revision = 0

    init() {
        let authorization = EKEventStore.authorizationStatus(for: .event)
        hasAccess = authorization == .fullAccess
        status = Self.authorizationDescription(authorization)
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification] {
            authorizationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.synchronizeAuthorization() }
            })
        }
        // Initialization checks permission only. It neither prompts nor fetches calendar data.
    }

    nonisolated static let permissionExplanation = "macOS requires full Calendar access to read events. Relay uses that permission only to read calendars you explicitly select; it provides no calendar creation, editing or deletion. Account syncing remains managed by macOS."

    /// Call only from an explicit user action after displaying permissionExplanation.
    func requestAccess() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        revision += 1
        let expectedRevision = revision
        defer { isLoading = false }
        do {
            try Task.checkCancellation()
            _ = try await store.requestFullAccessToEvents()
            try Task.checkCancellation()
            guard expectedRevision == revision else { return }
            synchronizeAuthorization()
            guard hasAccess else { return }
            calendars = store.calendars(for: .event).map {
                CalendarInfo(id: $0.calendarIdentifier, title: Self.boundedTitle($0.title))
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            status = "Calendar access allowed. Select calendars explicitly before refreshing events."
        } catch is CancellationError {
            status = "Calendar permission request was cancelled; no events were read."
        } catch {
            synchronizeAuthorization()
            errorMessage = "Calendar access could not be requested: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func refresh(start: Date = Date(), days: Int = 7) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        events = []
        revision += 1
        let expectedRevision = revision
        let requestedIDs = selectedCalendarIDs
        defer { isLoading = false }
        do {
            let range = try Self.validatedRange(start: start, days: days)
            try Task.checkCancellation()
            synchronizeAuthorization()
            guard hasAccess else { throw RelayError.message("Calendar access is unavailable. Enable it explicitly before reading events.") }
            let available = store.calendars(for: .event)
            let visible = available.map { CalendarInfo(id: $0.calendarIdentifier, title: Self.boundedTitle($0.title)) }
            calendars = visible.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let selected = try Self.selectedCalendars(from: visible, ids: requestedIDs)
            guard !selected.isEmpty else {
                status = "Choose calendars explicitly before reading events. Nothing was read."
                return false
            }
            await Task.yield()
            try Task.checkCancellation()
            guard expectedRevision == revision, requestedIDs == selectedCalendarIDs else { return false }
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                synchronizeAuthorization()
                throw RelayError.message("Calendar permission changed before the read. No events were returned.")
            }
            // Never pass nil/empty calendars to EventKit: that would mean all calendars.
            let scoped = available.filter { requestedIDs.contains($0.calendarIdentifier) }
            let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: scoped)
            var result: [EventInfo] = []
            var truncated = false
            store.enumerateEvents(matching: predicate) { event, stop in
                guard let calendar = event.calendar, let start = event.startDate, let end = event.endDate,
                      requestedIDs.contains(calendar.calendarIdentifier), end >= start else { return }
                if result.count >= 500 { truncated = true; stop.pointee = true; return }
                let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
                result.append(EventInfo(id: identifier + "|" + String(start.timeIntervalSince1970),
                                        title: Self.boundedTitle(event.title ?? "Untitled event"),
                                        start: start, end: end,
                                        calendarName: Self.boundedTitle(calendar.title)))
            }
            try Task.checkCancellation()
            guard expectedRevision == revision, requestedIDs == selectedCalendarIDs,
                  EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                synchronizeAuthorization()
                return false
            }
            events = result.sorted { $0.start < $1.start }
            status = "Read \(events.count) events from \(selected.count) selected calendars over \(days) days."
                + (truncated ? " Limited to the first 500 returned events; later results may be omitted." : "")
            return true
        } catch is CancellationError {
            events = []
            status = "Calendar read cancelled. No events retained."
        } catch {
            events = []
            errorMessage = error.localizedDescription
        }
        return false
    }

    /// Clears local scope/results. It does not revoke the macOS permission or delete calendar data.
    func clear() {
        let hadSelection = !selectedCalendarIDs.isEmpty
        revision += 1
        selectedCalendarIDs = []
        calendars = []
        events = []
        errorMessage = nil
        synchronizeAuthorization()
        status = "Local calendar selection and results cleared. macOS permission is unchanged."
        if !hadSelection { onContextInvalidated?() }
    }

    func refreshAuthorizationStatus() { synchronizeAuthorization() }

    private func synchronizeAuthorization() {
        let previouslyAllowed = hasAccess
        let authorization = EKEventStore.authorizationStatus(for: .event)
        hasAccess = authorization == .fullAccess
        if !hasAccess { calendars = []; events = []; status = Self.authorizationDescription(authorization) }
        if previouslyAllowed && !hasAccess { revision += 1; onContextInvalidated?() }
    }

    nonisolated static func authorizationDescription(_ authorization: EKAuthorizationStatus) -> String {
        switch authorization {
        case .notDetermined: return "Calendar access is off. Connect explicitly to request macOS permission."
        case .restricted: return "Calendar access is restricted by macOS."
        case .denied: return "Calendar access was denied. Change it directly in macOS Settings if desired."
        case .writeOnly: return "macOS granted write-only access; Relay cannot read events and will not write them."
        case .fullAccess: return "macOS Calendar full access is allowed. Select calendars explicitly; Relay only reads them."
        @unknown default: return "Calendar permission status is unsupported. No events will be read."
        }
    }

    nonisolated static func validatedRange(start: Date, days: Int, calendar: Calendar = .current) throws -> DateInterval {
        guard start.timeIntervalSinceReferenceDate.isFinite, start >= .distantPast, start <= .distantFuture, (1...31).contains(days),
              let end = calendar.date(byAdding: .day, value: days, to: start), end > start,
              end.timeIntervalSince(start) <= 32 * 86_400 else {
            throw RelayError.message("Calendar reads require a valid start date and a range from 1 to 31 days.")
        }
        return DateInterval(start: start, end: end)
    }

    nonisolated static func selectedCalendars(from available: [CalendarInfo], ids: Set<String>) throws -> [CalendarInfo] {
        guard ids.count <= 20, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else {
            throw RelayError.message("Select up to 20 calendars with valid identifiers.")
        }
        let availableIDs = Set(available.map(\.id))
        guard ids.isSubset(of: availableIDs) else {
            throw RelayError.message("A selected calendar is no longer available. Review the current selection before reading.")
        }
        return available.filter { ids.contains($0.id) }
    }

    nonisolated static func boundedTitle(_ title: String) -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(512))
    }
    isolated deinit {
        for observer in authorizationObservers { NotificationCenter.default.removeObserver(observer) }
    }

}
