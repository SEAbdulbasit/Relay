import SwiftUI

/// Presentation-only selector body. It owns no EventKit/store/source capability.
/// The production wrapper supplies the fixed guarded commit; inert render callers
/// can exercise the same body without constructing CalendarSource.
struct CalendarSelectionContent: View {
    let calendars: [CalendarSource.CalendarInfo]
    let catalog: CalendarSelectionCatalog
    let hasAccess: Bool
    let isLoading: Bool
    let committedSelection: CalendarSelectionValue
    @Binding var draft: CalendarSelectionDraft
    @Binding var message: String?
    let useSelection: @MainActor (CalendarSelectionDraft) throws -> Void

    private var canEdit: Bool {
        draft.isEditable(catalog: catalog, hasAccess: hasAccess, isLoading: isLoading)
    }
    private var missingCount: Int { draft.unavailableIDs(in: calendars).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !catalog.isCurrent {
                Text("Refresh calendars to choose the current list. Nothing is selected automatically.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted)
            } else if draft.catalogEpoch != catalog.epoch {
                Text("The calendar list changed. Review it before using your choices.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted)
                Button("Review updated list") {
                    perform { try draft.review(catalog: catalog, hasAccess: hasAccess, isLoading: isLoading) }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(!hasAccess || isLoading)
                .accessibilityIdentifier("calendar.selection.review")
            }

            if !calendars.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(calendars.enumerated()), id: \.offset) { index, calendar in
                            Toggle(isOn: Binding(get: { CalendarSelectionIdentity.contains(draft.selectedIDs, id: calendar.id) }, set: { selected in
                                perform {
                                    try draft.setSelected(selected, id: calendar.id, available: calendars,
                                        catalog: catalog, hasAccess: hasAccess, isLoading: isLoading)
                                }
                            })) {
                                Text(calendar.title).font(.relayBody).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!canEdit || (!CalendarSelectionIdentity.contains(draft.selectedIDs, id: calendar.id)
                                && draft.selectedIDs.count >= CalendarSource.maximumSelectedCalendars))
                            .accessibilityIdentifier("calendar.selection.row.\(index)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 48, maxHeight: 240)
                .accessibilityIdentifier("calendar.selection.list")
            } else if catalog.isCurrent {
                Text("No calendars are available in the current list.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted)
            }

            Text("\(draft.selectedIDs.count) of \(CalendarSource.maximumSelectedCalendars) selected")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted)
                .accessibilityIdentifier("calendar.selection.count")
            if canEdit && missingCount > 0 {
                Text("\(missingCount) selected \(missingCount == 1 ? "calendar is" : "calendars are") unavailable. Remove them explicitly or refresh the list.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted)
                Button("Remove unavailable") {
                    perform { try draft.removeUnavailable(in: calendars, catalog: catalog,
                        hasAccess: hasAccess, isLoading: isLoading) }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .accessibilityIdentifier("calendar.selection.removeUnavailable")
            }

            HStack {
                Button("Reset changes") { resetDraft(); message = nil }
                    .disabled(isLoading || CalendarSelectionValue(draft.selectedIDs) == committedSelection)
                    .accessibilityIdentifier("calendar.selection.reset")
                Button("Use selected calendars") {
                    perform { try useSelection(draft) }
                }
                .disabled(!canEdit || missingCount > 0)
                .accessibilityIdentifier("calendar.selection.use")
            }
            .buttonStyle(RelaySecondaryButtonStyle())
            if let message {
                Text(message).font(.relayCaption).foregroundStyle(RelayTheme.muted)
                    .accessibilityIdentifier("calendar.selection.message")
            }
        }
    }

    private func resetDraft() {
        draft = committedSelection.draft(catalogEpoch: catalog.epoch)
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); message = nil }
        catch { message = error.localizedDescription }
    }
}
