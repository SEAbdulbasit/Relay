import Foundation
import Testing
@testable import Relay

/// Pure selection/catalog state only. No CalendarSource instance or EventKit IO.
struct CalendarSelectionDraftTests {
    private func available(_ count: Int) -> [CalendarSource.CalendarInfo] {
        (0..<count).map { .init(id: "owned-calendar-\($0)", title: "Same calendar title") }
    }
    private func currentCatalog() -> CalendarSelectionCatalog {
        var value = CalendarSelectionCatalog()
        let published = value.publish(expectedEpoch: value.epoch)
        #expect(published)
        return value
    }

    @Test func uncommittedChoicesDoNotChangeCommittedScopeOrSelectByTitle() throws {
        let catalog = currentCatalog(), rows = available(42), committed: Set<String> = []
        var draft = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: committed)
        #expect(draft.selectedIDs.isEmpty)
        // A row after the first twenty remains selectable; duplicate titles do
        // not cause another source to be selected.
        try draft.setSelected(true, id: rows[35].id, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(try draft.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: false) == [rows[35].id])
        #expect(committed.isEmpty && rows.count == 42)
        let reset = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: committed)
        #expect(reset.selectedIDs.isEmpty)
    }

    @Test func twentyCalendarLimitStillAllowsUncheckingAndEmptyScope() throws {
        let catalog = currentCatalog(), rows = available(21)
        var draft = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: Set(rows.prefix(20).map(\.id)))
        #expect(CalendarSource.maximumSelectedCalendars == 20)
        #expect(throws: (any Error).self) {
            try draft.setSelected(true, id: rows[20].id, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        }
        #expect(draft.selectedIDs.count == 20 && !draft.selectedIDs.contains(rows[20].id))
        try draft.setSelected(false, id: rows[0].id, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        try draft.setSelected(true, id: rows[20].id, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(draft.selectedIDs.count == 20 && draft.selectedIDs.contains(rows[20].id))
        for id in Array(draft.selectedIDs) {
            try draft.setSelected(false, id: id, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        }
        #expect(try draft.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: false).isEmpty)
    }

    @Test func identifierAndCurrentSubsetUseTheExistingValidator() throws {
        let catalog = currentCatalog()
        let allowed = String(repeating: "é", count: 512), tooLong = allowed + "x"
        let rows = [CalendarSource.CalendarInfo(id: allowed, title: "Owned")]
        var draft = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: [])
        #expect(allowed.utf8.count == CalendarSource.maximumCalendarIdentifierBytes)
        try draft.setSelected(true, id: allowed, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        for id in ["", tooLong, "not-in-current-catalog"] {
            let malformed = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: [id])
            #expect(throws: (any Error).self) {
                try malformed.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: false)
            }
        }
        #expect(draft.selectedIDs == [allowed])
    }

    @Test func unavailableIDsRequireExplicitRemovalAndNeverMapToLookalikeTitles() throws {
        var catalog = currentCatalog()
        var draft = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: ["original-id"])
        let rows = [CalendarSource.CalendarInfo(id: "replacement-id", title: "Same calendar title")]
        catalog.invalidate(.databaseChange)
        let published = catalog.publish(expectedEpoch: catalog.epoch)
        #expect(published)
        #expect(!draft.isEditable(catalog: catalog, hasAccess: true, isLoading: false))
        try draft.review(catalog: catalog, hasAccess: true, isLoading: false)
        #expect(draft.selectedIDs == ["original-id"] && draft.unavailableIDs(in: rows) == ["original-id"])
        #expect(throws: (any Error).self) {
            try draft.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        }
        try draft.removeUnavailable(in: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(draft.selectedIDs.isEmpty && !draft.selectedIDs.contains("replacement-id"))
        try draft.setSelected(true, id: "replacement-id", available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(draft.selectedIDs == ["replacement-id"])
    }

    @Test(arguments: [CalendarSelectionCatalog.Invalidation.refresh, .databaseChange, .authorizationChange, .cleared])
    func everyCatalogInvalidationExpiresEvenAnEmptyScope(reason: CalendarSelectionCatalog.Invalidation) throws {
        var catalog = currentCatalog()
        let rows = available(1), oldEpoch = catalog.epoch
        var draft = CalendarSelectionDraft(catalogEpoch: oldEpoch, selectedIDs: [])
        catalog.invalidate(reason)
        #expect(catalog.epoch != oldEpoch && !catalog.isCurrent)
        #expect(throws: CalendarSelectionDraft.Failure.staleCatalog) {
            try draft.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        }
        let publishedOld = catalog.publish(expectedEpoch: oldEpoch)
        #expect(!publishedOld && !catalog.isCurrent)
        let published = catalog.publish(expectedEpoch: catalog.epoch)
        #expect(published)
        // A refreshed list does not silently re-authorize an old UI draft.
        #expect(throws: CalendarSelectionDraft.Failure.staleCatalog) {
            try draft.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        }
        try draft.review(catalog: catalog, hasAccess: true, isLoading: false)
        #expect(try draft.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: false).isEmpty)
    }

    @Test func permissionAndBusyGuardsPreventReviewEditsRemovalAndCommit() {
        let catalog = currentCatalog(), rows = available(1)
        var draft = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: ["missing"])
        #expect(throws: CalendarSelectionDraft.Failure.accessUnavailable) {
            try draft.review(catalog: catalog, hasAccess: false, isLoading: false)
        }
        #expect(throws: CalendarSelectionDraft.Failure.busy) {
            try draft.setSelected(true, id: rows[0].id, available: rows, catalog: catalog, hasAccess: true, isLoading: true)
        }
        #expect(throws: CalendarSelectionDraft.Failure.accessUnavailable) {
            try draft.removeUnavailable(in: rows, catalog: catalog, hasAccess: false, isLoading: false)
        }
        #expect(throws: CalendarSelectionDraft.Failure.busy) {
            try draft.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: true)
        }
        #expect(draft.selectedIDs == ["missing"])
    }

    @Test func anUnloadedOrLateCatalogCannotBecomeCurrentThroughAnOldPublish() {
        var catalog = CalendarSelectionCatalog()
        let initial = catalog.epoch
        let draft = CalendarSelectionDraft(catalogEpoch: initial, selectedIDs: [])
        #expect(!draft.isEditable(catalog: catalog, hasAccess: true, isLoading: false))
        catalog.invalidate(.refresh)
        let request = catalog.epoch
        catalog.invalidate(.databaseChange)
        let publishedInitial = catalog.publish(expectedEpoch: initial)
        #expect(!publishedInitial)
        let publishedRequest = catalog.publish(expectedEpoch: request)
        #expect(!publishedRequest)
        #expect(!catalog.isCurrent && catalog.invalidation == .databaseChange)
    }

    @Test func aDifferentCatalogCannotValidateEqualRowsAndSelection() {
        let first = currentCatalog(), other = currentCatalog(), rows = available(1)
        let draft = CalendarSelectionDraft(catalogEpoch: first.epoch, selectedIDs: [rows[0].id])
        #expect(throws: CalendarSelectionDraft.Failure.staleCatalog) {
            try draft.validatedSelection(available: rows, catalog: other, hasAccess: true, isLoading: false)
        }
        #expect(draft.selectedIDs == [rows[0].id])
    }

    @Test func opaqueMembershipAndRequestedScopeNeverMatchACanonicalAlias() throws {
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        #expect(composed == decomposed && Data(composed.utf8) != Data(decomposed.utf8))
        let first = CalendarSource.CalendarInfo(id: composed, title: "Same title")
        let second = CalendarSource.CalendarInfo(id: decomposed, title: "Same title")
        #expect(first != second && [first] != [second])
        let epoch = UUID()
        #expect(CalendarSelectionDraft(catalogEpoch: epoch, selectedIDs: [composed])
            != CalendarSelectionDraft(catalogEpoch: epoch, selectedIDs: [decomposed]))
        #expect(throws: (any Error).self) {
            try CalendarSource.selectedCalendars(from: [first], ids: [decomposed])
        }
        let selected = try CalendarSource.selectedCalendars(from: [first, second], ids: [decomposed])
        #expect(selected.count == 1 && selected.first.map { Data($0.id.utf8) } == Data(decomposed.utf8))
        #expect(!CalendarSelectionIdentity.contains([composed], id: decomposed))
        #expect(CalendarSelectionIdentity.contains([decomposed], id: decomposed))
        #expect(!CalendarSelectionIdentity.same([composed], [decomposed]))
        #expect(CalendarSelectionIdentity.same([composed, "other"], ["other", composed]))
    }

    @Test(arguments: [false, true])
    func addingAnotherCanonicalAliasRefusesAtomicallyAndDeselectsOnlyExactBytes(reverse: Bool) throws {
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        let original = reverse ? decomposed : composed, alias = reverse ? composed : decomposed
        let rows = [CalendarSource.CalendarInfo(id: original, title: "One"), .init(id: alias, title: "Two")]
        let catalog = currentCatalog()
        var draft = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: [original])
        #expect(CalendarSelectionIdentity.contains(draft.selectedIDs, id: original))
        #expect(!CalendarSelectionIdentity.contains(draft.selectedIDs, id: alias))
        #expect(throws: CalendarSelectionIdentity.Failure.conflictingIdentifier) {
            try draft.setSelected(true, id: alias, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        }
        #expect(CalendarSelectionIdentity.keys(draft.selectedIDs) == [Data(original.utf8)])
        try draft.setSelected(false, id: alias, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(CalendarSelectionIdentity.keys(draft.selectedIDs) == [Data(original.utf8)])
        try draft.setSelected(false, id: original, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(draft.selectedIDs.isEmpty)
        try draft.setSelected(true, id: alias, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(CalendarSelectionIdentity.keys(draft.selectedIDs) == [Data(alias.utf8)])
        #expect(CalendarSelectionIdentity.keys(try draft.validatedSelection(available: rows, catalog: catalog,
            hasAccess: true, isLoading: false)) == [Data(alias.utf8)])
    }

    @Test func missingAndResetPredicatesDoNotRetainARenamedByteAlias() throws {
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        let rows = [CalendarSource.CalendarInfo(id: decomposed, title: "Same title")]
        let catalog = currentCatalog()
        var draft = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: [composed])
        #expect(CalendarSelectionIdentity.keys(draft.unavailableIDs(in: rows)) == [Data(composed.utf8)])
        #expect(throws: (any Error).self) {
            try draft.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        }
        try draft.removeUnavailable(in: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(draft.selectedIDs.isEmpty)
        try draft.setSelected(true, id: decomposed, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(!CalendarSelectionIdentity.same(draft.selectedIDs, [composed]))
        let reset = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: [composed])
        #expect(CalendarSelectionIdentity.keys(reset.selectedIDs) == [Data(composed.utf8)])
        #expect(!CalendarSelectionIdentity.contains(reset.selectedIDs, id: decomposed))
    }

    @Test func unrelatedCatalogAliasesDoNotDisableOtherSelections() throws {
        let rows = [CalendarSource.CalendarInfo(id: "caf\u{e9}", title: "One"),
            .init(id: "cafe\u{301}", title: "Two"), .init(id: "unrelated", title: "Three")]
        let catalog = currentCatalog()
        var draft = CalendarSelectionDraft(catalogEpoch: catalog.epoch, selectedIDs: [])
        try draft.setSelected(true, id: "unrelated", available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(try draft.validatedSelection(available: rows, catalog: catalog, hasAccess: true, isLoading: false) == ["unrelated"])
        #expect(draft.unavailableIDs(in: rows).isEmpty)
    }

    @Test func committedViewValueDetectsByteChangeAndResetUsesTheActualNewCommit() throws {
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        let previous = CalendarSelectionValue([composed]), current = CalendarSelectionValue([decomposed])
        #expect(previous != current)
        #expect(CalendarSelectionValue(["other", composed]) == CalendarSelectionValue([composed, "other"]))
        let catalog = currentCatalog(), rows = [CalendarSource.CalendarInfo(id: composed, title: "One"),
            .init(id: decomposed, title: "Two")]
        var draft = previous.draft(catalogEpoch: catalog.epoch)
        try draft.setSelected(false, id: composed, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        try draft.setSelected(true, id: decomposed, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        // Actual Content disabled/reset operations use this exact value boundary.
        #expect(CalendarSelectionValue(draft.selectedIDs) == current)
        #expect(CalendarSelectionValue(draft.selectedIDs) != previous)
        draft = current.draft(catalogEpoch: catalog.epoch)
        #expect(CalendarSelectionIdentity.keys(draft.selectedIDs) == [Data(decomposed.utf8)])
        #expect(!CalendarSelectionIdentity.contains(draft.selectedIDs, id: composed))
        #expect(CalendarSelectionValue(draft.selectedIDs) == current)
        // Reset changes an edited draft to current, never the prior canonical alias.
        try draft.setSelected(false, id: decomposed, available: rows, catalog: catalog, hasAccess: true, isLoading: false)
        #expect(CalendarSelectionValue(draft.selectedIDs) != current)
        draft = current.draft(catalogEpoch: catalog.epoch)
        #expect(CalendarSelectionIdentity.keys(draft.selectedIDs) == [Data(decomposed.utf8)])
    }
}
