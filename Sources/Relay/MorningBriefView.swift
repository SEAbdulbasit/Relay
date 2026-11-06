import SwiftUI

struct MorningBriefView: View {
    let store: AssistantStore
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: Suggestion.ID?
    @State private var request = ""
    @State private var status: String?
    @State private var drafting: Task<Void, Never>?
    @State private var showAgenda = false

    private var cards: [Suggestion] { store.suggestions.suggestions.filter { !$0.dismissed } }
    private var selected: Suggestion? { cards.first { $0.id == selectedID } }
    private var taskBusy: Bool { store.isRunning || store.voice.isBusy || store.knowledge.isIndexing || drafting != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "sun.horizon", color: RelayColors.accentGold, size: 34, iconSize: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Morning Brief").font(.system(size: 22, weight: .semibold))
                    Text("Review suggestions from your selected sources and decide which task to start.")
                        .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !store.preparation.agenda.isEmpty { agenda }
            if cards.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(cards) { card in
                                Button { open(card.id) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(card.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
                                        HStack(spacing: 6) {
                                            if let dueDay = card.dueDay {
                                                Text("Due \(dueDay)").foregroundStyle(RelayColors.accentBlue)
                                                    .fixedSize(horizontal: true, vertical: false)
                                            }
                                            Text(sourceName(card)).foregroundStyle(RelayColors.textSecondary)
                                        }
                                        .font(.relayCaption).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(card.id == selectedID ? RelayColors.surfaceElevated : RelayColors.surface.opacity(0.45),
                                                in: RoundedRectangle(cornerRadius: 9))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(card.id == selectedID ? .isSelected : [])
                            }
                        }
                    }
                    .frame(width: 200)
                    Divider()
                    if let selected { detail(selected) }
                    else {
                        Text("Choose a suggestion to see its source and review the task.")
                            .foregroundStyle(RelayColors.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            if let status { Text(status).font(.relayCaption).foregroundStyle(RelayColors.textSecondary).textSelection(.enabled) }
        }
        .padding(22)
        .frame(width: 690, height: 470)
        .background(RelayTheme.background)
        .onAppear {
            store.suggestions.purge(records: store.knowledge.records)
            if let first = cards.first { open(first.id) }
        }
        .onChange(of: cards.map(\.id)) { _, ids in
            guard let selectedID, !ids.contains(selectedID) else { return }
            drafting?.cancel()
            self.selectedID = nil
            request = ""
        }
        .onDisappear { drafting?.cancel() }
    }

    private var agenda: some View {
        DisclosureGroup("Upcoming calendar · \(store.preparation.agenda.count)", isExpanded: $showAgenda) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.preparation.agenda) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarName)")
                                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 92)
            .padding(.top, 6)
        }
        .font(.system(size: 13, weight: .medium))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.horizon").font(.system(size: 28)).foregroundStyle(RelayColors.accentGold)
                .accessibilityHidden(true)
            Text("No suggestions ready").font(.system(size: 17, weight: .semibold))
            Text(store.suggestions.enabled
                 ? "Prepare a brief from your current index, or check your schedule in Knowledge settings."
                 : "Enable proactive suggestions in Knowledge settings to get started.")
                .font(.system(size: 13)).foregroundStyle(RelayColors.textSecondary).multilineTextAlignment(.center)
            if store.suggestions.enabled {
                Button("Prepare from current index") {
                    store.knowledge.purgeStale(grants: store.grants)
                    store.suggestions.prepare(records: store.knowledge.records)
                    if let first = cards.first { open(first.id) }
                    else { status = store.suggestions.status }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(taskBusy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ card: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card.title).font(.system(size: 16, weight: .semibold)).lineLimit(3)
            Text(card.sourcePaths.first ?? sourceName(card))
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if !card.matchingSourcePaths.isEmpty {
                let count = card.matchingSourcePaths.count
                Text("\(count) identical \(count == 1 ? "source copy" : "source copies") also indexed")
                    .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    .help(card.matchingSourcePaths.prefix(5).joined(separator: "\n"))
            }
            ScrollView {
                Text(card.excerpt).font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 58)
            Text("Task request").font(.system(size: 13, weight: .medium))
            TextEditor(text: $request)
                .font(.system(size: 13)).frame(minHeight: 64)
                .accessibilityLabel("Task request").disabled(drafting != nil)
            Text(!store.actionsReady ? "Load a local model in Settings to draft or start a task."
                 : store.workspaceUsesCodex ? "Starting this task switches the workspace to the local model."
                 : "Relay runs the request locally and shows any action that needs review.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
            HStack(spacing: 8) {
                if let drafting {
                    Button("Stop draft") { drafting.cancel() }
                } else {
                    Button("Improve draft") { improve(card.id) }.disabled(taskBusy || !store.actionsReady || !validRequest)
                }
                Menu("More") {
                    Button("Snooze until tomorrow") { hide(card.id, snooze: true) }
                    Button("Dismiss suggestion") { hide(card.id, snooze: false) }
                }
                .fixedSize().disabled(drafting != nil)
                Spacer()
                Button("Start Local Task") { start(card.id) }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(taskBusy || !validRequest || !store.actionsReady)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var validRequest: Bool {
        !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.utf8.count <= 2_000
    }

    private func sourceName(_ card: Suggestion) -> String {
        card.sourcePaths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Local source"
    }

    private func open(_ id: Suggestion.ID) {
        drafting?.cancel()
        selectedID = nil
        request = ""
        do {
            let card = try store.reviewBriefSuggestion(id)
            selectedID = id
            request = store.suggestions.preparedDrafts[id] ?? card.title
            status = store.suggestions.preparedDrafts[id] == nil ? nil : "Draft prepared on this Mac. Review and edit before starting."
        } catch { status = error.localizedDescription }
    }

    private func improve(_ id: Suggestion.ID) {
        guard drafting == nil else { return }
        let currentRequest = request
        status = "Preparing an editable draft on this Mac…"
        drafting = Task { @MainActor in
            defer { drafting = nil }
            do {
                let updated = try await store.draftBriefTask(id, request: currentRequest)
                guard !Task.isCancelled, selectedID == id else { return }
                request = updated
                status = "Review and edit the draft before starting."
            } catch is CancellationError {
                if selectedID == id { status = "Draft preparation stopped." }
            } catch {
                if !Task.isCancelled, selectedID == id { status = error.localizedDescription }
            }
        }
    }

    private func hide(_ id: Suggestion.ID, snooze: Bool) {
        do {
            _ = try store.reviewBriefSuggestion(id)
            if snooze {
                guard store.suggestions.snooze(id, days: 1) else {
                    status = store.suggestions.errorMessage
                    return
                }
            } else { store.suggestions.dismiss(id) }
            selectedID = nil
            request = ""
            status = nil
            if let first = cards.first { open(first.id) }
        } catch { status = error.localizedDescription }
    }

    private func start(_ id: Suggestion.ID) {
        do {
            try store.startBriefTask(id, request: request)
            dismiss()
            onStart()
        } catch { status = error.localizedDescription }
    }
}
