import SwiftUI

/// An explicit selection UI. Initialization and appearance perform no source IO.
struct CalendarSelectionView: View {
    @Bindable var source: CalendarSource
    @State private var draft: CalendarSelectionDraft
    @State private var message: String?
    @State private var writeMessage: String?

    init(source: CalendarSource) {
        self.source = source
        _draft = State(initialValue: CalendarSelectionDraft(catalogEpoch: source.selectionCatalog.epoch,
                                                           selectedIDs: source.selectedCalendarIDs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalendarSelectionContent(calendars: source.calendars, catalog: source.selectionCatalog,
                hasAccess: source.hasAccess, isLoading: source.isLoading,
                committedSelection: CalendarSelectionValue(source.selectedCalendarIDs),
                draft: $draft, message: $message, useSelection: { selection in
                    try source.applySelection(selection)
                })
            writeSelection
        }
        .onChange(of: source.selectionEpoch) { _, _ in resetDraft(); message = nil }
        .onChange(of: source.selectionCatalog.epoch) { _, _ in
            writeMessage = nil
            if source.selectionCatalog.invalidation == .cleared { resetDraft(); message = nil }
        }
    }

    private var writeSelection: some View {
        let epoch = source.selectionCatalog.epoch
        let writable = source.calendars.filter(\.allowsContentModifications)
        let canChoose = source.selectionCatalog.isCurrent && !source.isLoading
        return VStack(alignment: .leading, spacing: 6) {
            Text("Calendar for event creation").font(.system(size: 13, weight: .medium))
            Text("Choose one writable calendar for this session. Relay asks you to review each event before saving.")
                .font(.system(size: 12.5))
                .foregroundStyle(RelayTheme.muted)
            HStack {
                Menu {
                    ForEach(writable, id: \.exactID) { calendar in
                        Button(destinationLabel(calendar, among: writable)) {
                            selectWriteDestination(calendar.id, epoch: epoch)
                        }
                    }
                } label: {
                    if let selected = source.writeCalendar {
                        Text(destinationLabel(selected, among: writable))
                    } else {
                        Text("Choose writable calendar…")
                    }
                }
                .disabled(!canChoose || writable.isEmpty)
                .accessibilityLabel("Calendar for event creation")
                .accessibilityIdentifier("calendar.writeDestination")
                if source.writeCalendar != nil {
                    Button("Clear write destination") { selectWriteDestination(nil, epoch: epoch) }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .accessibilityIdentifier("calendar.clearWriteDestination")
                }
            }
            if let writeMessage {
                Text(writeMessage).font(.system(size: 12.5)).foregroundStyle(RelayColors.accentCoral)
            } else if !canChoose {
                Text("Refresh calendars to review the available write destinations.")
                    .font(.system(size: 12.5)).foregroundStyle(RelayTheme.muted)
            } else if writable.isEmpty {
                Text("No writable calendars are available.")
                    .font(.system(size: 12.5)).foregroundStyle(RelayTheme.muted)
            }
        }
    }

    private func selectWriteDestination(_ id: String?, epoch: UUID) {
        do {
            try source.selectWriteCalendar(id: id, catalogEpoch: epoch)
            writeMessage = nil
        } catch {
            writeMessage = error.localizedDescription
        }
    }

    private func destinationLabel(_ calendar: CalendarSource.CalendarInfo,
                                  among calendars: [CalendarSource.CalendarInfo]) -> String {
        let label = calendar.accountTitle.isEmpty ? calendar.title : "\(calendar.title) (\(calendar.accountTitle))"
        let duplicate = calendars.contains {
            !$0.id.utf8.elementsEqual(calendar.id.utf8)
                && $0.title == calendar.title && $0.accountTitle == calendar.accountTitle
        }
        return duplicate ? "\(label) · \(calendar.id)" : label
    }

    private func resetDraft() {
        draft = CalendarSelectionDraft(catalogEpoch: source.selectionCatalog.epoch, selectedIDs: source.selectedCalendarIDs)
    }
}
