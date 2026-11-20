import AppKit
import CryptoKit
import EventKit
import Foundation
import Observation

/// Explicit read and write scopes for calendars already available on this Mac.
@Observable @MainActor
final class CalendarSource {
    nonisolated struct CalendarInfo: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let allowsContentModifications: Bool
        let accountTitle: String
        var exactID: Data { Data(id.utf8) }

        init(id: String, title: String, allowsContentModifications: Bool = false, accountTitle: String = "") {
            self.id = id
            self.title = title
            self.allowsContentModifications = allowsContentModifications
            self.accountTitle = accountTitle
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.title == rhs.title
                && lhs.allowsContentModifications == rhs.allowsContentModifications
                && lhs.accountTitle == rhs.accountTitle
        }
    }
    nonisolated struct EventInfo: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendarName: String
    }

    var onContextInvalidated: (() -> Void)?
    var onContentInvalidated: (() -> Void)?
    var onWriteCalendarChanged: ((CalendarInfo?) -> Void)?
    @ObservationIgnored private var authorizationObservers: [NSObjectProtocol] = []

    var status: String
    var errorMessage: String?
    private(set) var isLoading = false
    private(set) var hasAccess: Bool
    private(set) var calendars: [CalendarInfo] = []
    private(set) var selectionCatalog = CalendarSelectionCatalog()
    private(set) var writeCalendar: CalendarInfo? {
        didSet {
            if oldValue != writeCalendar { onWriteCalendarChanged?(writeCalendar) }
        }
    }
    private(set) var events: [EventInfo] = []
    @ObservationIgnored private var storedSelectedCalendarIDs: Set<String> = []
    private(set) var selectionEpoch = UUID()
    var selectedCalendarIDs: Set<String> {
        get { _ = selectionEpoch; return storedSelectedCalendarIDs }
        set {
            let previous = storedSelectedCalendarIDs
            // Always store the actual bytes, independently of Observation's
            // Equatable notification optimization for Set<String>.
            storedSelectedCalendarIDs = newValue
            guard !CalendarSelectionIdentity.same(previous, newValue) else { return }
            readRevocation.invalidate()
            revision += 1
            events = []
            errorMessage = nil
            status = newValue.isEmpty ? "Choose calendars explicitly before reading events." : "Selection changed. Refresh to read this scope."
            selectionEpoch = UUID()
            onContextInvalidated?()
        }
    }
    @ObservationIgnored private let readOwner = UUID()
    @ObservationIgnored private let readRevocation = CalendarReadEpoch()
    @ObservationIgnored private let readWorker = CalendarEventReadWorker.shared
    // Used only by the explicit permission request, never for event queries.
    @ObservationIgnored private lazy var store = EKEventStore()
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var lastAuthorization: EKAuthorizationStatus
    @ObservationIgnored private static var cachedInitialAuthorization: EKAuthorizationStatus?
    #if DEBUG
    @ObservationIgnored private var fixtureAuthorization: EKAuthorizationStatus?
    #endif

    init() {
        let authorization: EKAuthorizationStatus
        if let cached = Self.cachedInitialAuthorization {
            authorization = cached
        } else {
            let current = EKEventStore.authorizationStatus(for: .event)
            Self.cachedInitialAuthorization = current
            authorization = current
        }
        lastAuthorization = authorization
        hasAccess = authorization == .fullAccess
        status = Self.authorizationDescription(authorization)
        authorizationObservers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.calendarDatabaseChanged() }
        })
        authorizationObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeAuthorization() }
        })
        // Initialization checks permission only. It neither prompts nor fetches calendar data.
    }

    nonisolated static let maximumSelectedCalendars = 20
    nonisolated static let maximumCalendarIdentifierBytes = 1024

    nonisolated static let permissionExplanation = "macOS requires full Calendar access. Relay reads only the calendars you select for reading. For event creation, choose a separate writable calendar for this session and review each action. Account syncing remains managed by macOS."

    /// Call only from an explicit user action after displaying permissionExplanation.
    func requestAccess() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        selectionCatalog.invalidate(.refresh)
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
            let catalogEpoch = selectionCatalog.epoch
            let seed = calendarReadSeed()
            let listed = try await readWorker.listCalendars(seed: seed)
            try Task.checkCancellation()
            guard expectedRevision == revision, seed.matches(calendarReadSeed()),
                  publishCatalog(listed.calendars, expectedEpoch: catalogEpoch) else { return }
            status = "Calendar access allowed. Select calendars explicitly before refreshing events."
                + (listed.limited ? " The calendar list or some of its labels is limited." : "")
        } catch is CancellationError {
            guard expectedRevision == revision else { return }
            status = "Calendar permission request was cancelled; no events were read."
        } catch {
            guard expectedRevision == revision else { return }
            synchronizeAuthorization()
            errorMessage = "Calendar access could not be requested. No events were read."
        }
    }

    @discardableResult
    func refresh(start: Date = Date(), days: Int = 7) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        events = []
        selectionCatalog.invalidate(.refresh)
        revision += 1
        let expectedRevision = revision
        let requestedIDs = selectedCalendarIDs
        defer { isLoading = false }
        do {
            _ = try Self.validatedRange(start: start, days: days)
            try Task.checkCancellation()
            synchronizeAuthorization()
            guard hasAccess else { throw CalendarReadFailure.accessUnavailable }
            let catalogEpoch = selectionCatalog.epoch
            let seed = calendarReadSeed()
            let listed = try await readWorker.listCalendars(seed: seed)
            try Task.checkCancellation()
            guard expectedRevision == revision, seed.matches(calendarReadSeed()),
                  publishCatalog(listed.calendars, expectedEpoch: catalogEpoch) else { return false }
            let selected = try Self.selectedCalendars(from: listed.calendars, ids: requestedIDs)
            guard !selected.isEmpty else {
                status = "Choose calendars explicitly before reading events. Nothing was read."
                return false
            }
            let query = try CalendarReadQuery(ids: requestedIDs, start: start, days: days)
            let snapshot = try await readWorker.readForUI(query: query, seed: seed)
            try Task.checkCancellation()
            guard expectedRevision == revision, seed.matches(calendarReadSeed()), hasAccess,
                  CalendarSelectionIdentity.same(requestedIDs, selectedCalendarIDs) else { return false }
            events = snapshot.events.sorted { $0.start < $1.start }.map {
                EventInfo(id: SHA256.hash(data: $0.occurrenceKey).map { String(format: "%02x", $0) }.joined(),
                          title: $0.title, start: $0.start, end: $0.end, calendarName: $0.calendarName)
            }
            status = "Read \(events.count) events from \(selected.count) selected calendars over \(days) days."
                + (snapshot.producerLimited || snapshot.byteLimited || snapshot.events.contains(where: \.fieldLimited)
                    ? " Coverage is limited; later events or field text may be omitted." : "")
                + (listed.limited ? " The available calendar list or some labels is limited." : "")
            return true
        } catch is CancellationError {
            guard expectedRevision == revision else { return false }
            events = []
            status = "Calendar read cancelled. No events retained."
        } catch {
            guard expectedRevision == revision else { return false }
            events = []
            // SDK errors and event fields never become user-visible error text.
            errorMessage = (error as? CalendarReadFailure)?.errorDescription ?? CalendarReadFailure.unavailable.errorDescription
        }
        return false
    }

    /// Immutable scope metadata only. This does not query calendars or grant access.
    func calendarReadSeed() -> CalendarReadSeed {
        CalendarReadSeed(owner: readOwner, selectionEpoch: selectionEpoch, epoch: readRevocation.value,
                         identifiers: CalendarSelectionIdentity.keys(selectedCalendarIDs).sorted { $0.lexicographicallyPrecedes($1) },
                         hasAccess: hasAccess, revocation: readRevocation)
    }

    /// Tool reads are execution-owned; they never first publish into the ambient UI cache.
    func readForTool(_ call: ToolCall, scope: CalendarReadExecutionScope,
                     worker: CalendarEventReadWorker = .shared) async throws -> ToolResult {
        try scope.validateCurrent(call: call)
        guard scope.matchesSource(calendarReadSeed()) else { throw CalendarReadFailure.unavailable }
        guard hasAccess else { throw CalendarReadFailure.accessUnavailable }
        return try await worker.read(call: call, scope: scope).result
    }

    /// Commits only an explicitly reviewed, still-current catalog draft. No event read or permission prompt.
    func applySelection(_ draft: CalendarSelectionDraft) throws {
        guard !isLoading else { throw CalendarSelectionDraft.Failure.busy }
        synchronizeAuthorization()
        let ids = try draft.validatedSelection(available: calendars, catalog: selectionCatalog,
                                              hasAccess: hasAccess, isLoading: isLoading)
        // The existing didSet owns the single scope invalidation, only when changed.
        selectedCalendarIDs = ids
    }

    /// Only a fresh catalog and a separate explicit user selection can enable writes.
    func selectWriteCalendar(id: String?, catalogEpoch: UUID) throws {
        guard let id else { writeCalendar = nil; return }
        guard !isLoading else { throw CalendarSelectionDraft.Failure.busy }
        synchronizeAuthorization()
        guard hasAccess else { throw CalendarSelectionDraft.Failure.accessUnavailable }
        guard selectionCatalog.isCurrent, selectionCatalog.epoch == catalogEpoch else {
            throw CalendarSelectionDraft.Failure.staleCatalog
        }
        let matches = try Self.selectedCalendars(from: calendars, ids: [id])
        guard matches.count == 1, let calendar = matches.first, calendar.allowsContentModifications else {
            throw RelayError.message("That calendar is not available for writing. Refresh calendars and choose a writable destination.")
        }
        writeCalendar = calendar
    }

    @discardableResult
    private func publishCatalog(_ listed: [CalendarInfo], expectedEpoch: UUID) -> Bool {
        guard hasAccess, selectionCatalog.publish(expectedEpoch: expectedEpoch) else { return false }
        calendars = listed
        if let selected = writeCalendar {
            let matches = listed.filter { $0.id.utf8.elementsEqual(selected.id.utf8) }
            if matches.count != 1 || matches.first != selected { writeCalendar = nil }
        }
        return true
    }

    /// Clears local scope/results. It does not revoke the macOS permission or delete calendar data.
    func clear() {
        let hadSelection = !selectedCalendarIDs.isEmpty
        readRevocation.invalidate()
        selectionCatalog.invalidate(.cleared)
        revision += 1
        writeCalendar = nil
        selectedCalendarIDs = []
        calendars = []
        events = []
        errorMessage = nil
        synchronizeAuthorization()
        status = "Local calendar selection and results cleared. macOS permission is unchanged."
        if !hadSelection { onContextInvalidated?() }
    }

    /// EventKit invalidates prior event objects after any database change.
    /// Keep the selected scope and refresh preference, but withdraw its body.
    func calendarDatabaseChanged() {
        // Catalog freshness is independent of whether event scope exists. This
        // does not invalidate an unrelated task when no calendar was selected.
        readRevocation.invalidate()
        selectionCatalog.invalidate(.databaseChange)
        let hadCurrentScope = !selectedCalendarIDs.isEmpty || !events.isEmpty || isLoading
        if hadCurrentScope {
            revision += 1
            events = []
            errorMessage = nil
        }
        let previouslyAllowed = hasAccess
        synchronizeAuthorization()
        // Permission loss already invalidated the scope through its callback.
        guard hadCurrentScope, !(previouslyAllowed && !hasAccess) else { return }
        status = hasAccess ? "Calendar data changed. Refresh to read current selected events." : status
        onContentInvalidated?()
    }

    func refreshAuthorizationStatus() { synchronizeAuthorization() }

    #if DEBUG
    func setWriteCalendarCatalogForTesting(_ calendars: [CalendarInfo], hasAccess: Bool = true) {
        fixtureAuthorization = hasAccess ? .fullAccess : .denied
        synchronizeAuthorization()
        let epoch = selectionCatalog.invalidate(.refresh)
        _ = publishCatalog(calendars, expectedEpoch: epoch)
    }
    #endif

    private func synchronizeAuthorization() {
        let previouslyAllowed = hasAccess
        let liveAuthorization = EKEventStore.authorizationStatus(for: .event)
        Self.cachedInitialAuthorization = liveAuthorization
        #if DEBUG
        let authorization = fixtureAuthorization ?? liveAuthorization
        #else
        let authorization = liveAuthorization
        #endif
        if lastAuthorization != authorization {
            readRevocation.invalidate()
            selectionCatalog.invalidate(.authorizationChange)
            lastAuthorization = authorization
        }
        hasAccess = authorization == .fullAccess
        if !hasAccess {
            writeCalendar = nil
            calendars = []
            events = []
            status = Self.authorizationDescription(authorization)
        }
        if previouslyAllowed && !hasAccess { revision += 1; onContextInvalidated?() }
    }

    nonisolated static func authorizationDescription(_ authorization: EKAuthorizationStatus) -> String {
        switch authorization {
        case .notDetermined: return "Calendar access is off. Connect explicitly to request macOS permission."
        case .restricted: return "Calendar access is restricted by macOS."
        case .denied: return "Calendar access was denied. Change it directly in macOS Settings if desired."
        case .writeOnly: return "macOS granted write-only access; Relay cannot read events and will not write them."
        case .fullAccess: return "macOS Calendar full access is allowed. Choose calendars explicitly for reading or reviewed event creation."
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
        guard ids.count <= maximumSelectedCalendars, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumCalendarIdentifierBytes }) else {
            throw RelayError.message("Select up to 20 calendars with valid identifiers.")
        }
        let requestedKeys = CalendarSelectionIdentity.keys(ids)
        let availableKeys = CalendarSelectionIdentity.keys(available.map(\.id))
        guard requestedKeys.isSubset(of: availableKeys) else {
            throw RelayError.message("A selected calendar is no longer available. Review the current selection before reading.")
        }
        return available.filter { requestedKeys.contains(Data($0.id.utf8)) }
    }

    nonisolated static func boundedTitle(_ title: String) -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(512))
    }

    func captureSnapshot(now: Date = Date()) throws -> CalendarSnapshot {
        guard hasAccess else { throw RelayError.message("Calendar access is unavailable.") }
        guard !selectedCalendarIDs.isEmpty else { throw RelayError.message("No calendars selected.") }
        let coverage = CalendarCoverage(now: now, ids: selectedCalendarIDs)
        let available = store.calendars(for: .event)
        let scoped = available.filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
        guard !scoped.isEmpty else { throw RelayError.message("None of the selected calendars are available.") }

        let predicate = store.predicateForEvents(withStart: coverage.lower, end: coverage.upper, calendars: scoped)
        var occurrences: [CalendarOccurrence] = []
        store.enumerateEvents(matching: predicate) { event, stop in
            guard let calendar = event.calendar, let rawStart = event.startDate, let rawEnd = event.endDate,
                  self.selectedCalendarIDs.contains(calendar.calendarIdentifier), rawEnd >= rawStart else { return }
            let zone = event.isAllDay ? TimeZone.current : (event.timeZone ?? .current)
            let (start, end) = CalendarSnapshot.normalizeInterval(start: rawStart, end: rawEnd, allDay: event.isAllDay, zone: zone)
            guard start < coverage.upper, end > coverage.lower || (start == end && start >= coverage.lower) else { return }

            let itemID = event.calendarItemIdentifier.isEmpty ? (event.eventIdentifier ?? UUID().uuidString) : event.calendarItemIdentifier
            let status = event.status == .confirmed ? "confirmed" : (event.status == .tentative ? "tentative" : "cancelled")
            let availability = event.availability == .free ? "free" : "busy"
            let response = event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .accepted ? "accepted" : "tentative"

            let occurrence = CalendarOccurrence(
                calendarID: calendar.calendarIdentifier,
                calendarName: Self.boundedTitle(calendar.title),
                itemID: itemID,
                title: Self.boundedTitle(event.title ?? "Untitled event"),
                start: start,
                end: end,
                allDay: event.isAllDay,
                timeZone: zone.identifier,
                location: event.location ?? "",
                notes: event.notes ?? "",
                scheduleStatus: status,
                availability: availability,
                participantResponse: response,
                occurrenceDate: event.occurrenceDate ?? start
            )
            occurrences.append(occurrence)
        }
        return CalendarSnapshot(capturedAt: now, coverage: coverage, occurrences: occurrences)
    }

    isolated deinit {
        readRevocation.invalidate()
        for observer in authorizationObservers { NotificationCenter.default.removeObserver(observer) }
    }

}
