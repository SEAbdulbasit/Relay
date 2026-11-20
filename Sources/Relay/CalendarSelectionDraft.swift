import Foundation

/// UI catalog freshness only. This is not an EventKit read receipt or task grant.
nonisolated struct CalendarSelectionCatalog: Sendable, Equatable {
    enum Invalidation: Sendable, Equatable { case initial, refresh, databaseChange, authorizationChange, cleared }
    private(set) var epoch = UUID()
    private(set) var isCurrent = false
    private(set) var invalidation: Invalidation = .initial

    @discardableResult
    mutating func invalidate(_ reason: Invalidation) -> UUID {
        epoch = UUID()
        isCurrent = false
        invalidation = reason
        return epoch
    }

    /// Only the caller that completed the still-current catalog request publishes.
    @discardableResult
    mutating func publish(expectedEpoch: UUID) -> Bool {
        guard epoch == expectedEpoch else { return false }
        isCurrent = true
        return true
    }
}

/// An uncommitted user selection. Editing it never changes the source scope.
nonisolated struct CalendarSelectionDraft: Sendable, Equatable {
    enum Failure: LocalizedError, Equatable {
        case accessUnavailable, busy, staleCatalog
        var errorDescription: String? {
            switch self {
            case .accessUnavailable: "Calendar access is unavailable. Choose access explicitly before selecting calendars."
            case .busy: "Wait for the current calendar request to finish before changing the selection."
            case .staleCatalog: "Refresh calendars and review the updated list before using this selection."
            }
        }
    }

    private(set) var catalogEpoch: UUID
    private(set) var selectedIDs: Set<String>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.catalogEpoch == rhs.catalogEpoch && CalendarSelectionIdentity.same(lhs.selectedIDs, rhs.selectedIDs)
    }

    init(catalogEpoch: UUID, selectedIDs: Set<String>) {
        self.catalogEpoch = catalogEpoch
        self.selectedIDs = selectedIDs
    }

    func isEditable(catalog: CalendarSelectionCatalog, hasAccess: Bool, isLoading: Bool) -> Bool {
        hasAccess && !isLoading && catalog.isCurrent && catalogEpoch == catalog.epoch
    }

    func unavailableIDs(in available: [CalendarSource.CalendarInfo]) -> Set<String> {
        CalendarSelectionIdentity.unavailable(selectedIDs, available: available.map(\.id))
    }

    /// Deliberately preserves choices, including missing IDs, for user review.
    mutating func review(catalog: CalendarSelectionCatalog, hasAccess: Bool, isLoading: Bool) throws {
        try Self.requireAvailable(catalog: catalog, hasAccess: hasAccess, isLoading: isLoading)
        catalogEpoch = catalog.epoch
    }

    mutating func setSelected(_ selected: Bool, id: String, available: [CalendarSource.CalendarInfo],
                             catalog: CalendarSelectionCatalog, hasAccess: Bool, isLoading: Bool) throws {
        try requireCurrent(catalog: catalog, hasAccess: hasAccess, isLoading: isLoading)
        // Validate the actual row even when removing it; no title-based mapping.
        _ = try CalendarSource.selectedCalendars(from: available, ids: [id])
        let proposed: Set<String>
        if selected { proposed = try CalendarSelectionIdentity.inserting(id, into: selectedIDs) }
        else { proposed = CalendarSelectionIdentity.removing(id, from: selectedIDs) }
        _ = try CalendarSource.selectedCalendars(from: available, ids: proposed)
        selectedIDs = proposed
    }

    mutating func removeUnavailable(in available: [CalendarSource.CalendarInfo],
                                    catalog: CalendarSelectionCatalog, hasAccess: Bool, isLoading: Bool) throws {
        try requireCurrent(catalog: catalog, hasAccess: hasAccess, isLoading: isLoading)
        let proposed = CalendarSelectionIdentity.retaining(selectedIDs, available: available.map(\.id))
        _ = try CalendarSource.selectedCalendars(from: available, ids: proposed)
        selectedIDs = proposed
    }

    func validatedSelection(available: [CalendarSource.CalendarInfo], catalog: CalendarSelectionCatalog,
                            hasAccess: Bool, isLoading: Bool) throws -> Set<String> {
        try requireCurrent(catalog: catalog, hasAccess: hasAccess, isLoading: isLoading)
        _ = try CalendarSource.selectedCalendars(from: available, ids: selectedIDs)
        return selectedIDs
    }

    private func requireCurrent(catalog: CalendarSelectionCatalog, hasAccess: Bool, isLoading: Bool) throws {
        try Self.requireAvailable(catalog: catalog, hasAccess: hasAccess, isLoading: isLoading)
        guard catalogEpoch == catalog.epoch else { throw Failure.staleCatalog }
    }

    private static func requireAvailable(catalog: CalendarSelectionCatalog, hasAccess: Bool, isLoading: Bool) throws {
        guard hasAccess else { throw Failure.accessUnavailable }
        guard !isLoading else { throw Failure.busy }
        guard catalog.isCurrent else { throw Failure.staleCatalog }
    }
}
