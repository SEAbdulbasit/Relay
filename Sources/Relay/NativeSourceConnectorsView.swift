import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Controls both live checkpointed local SQLite source ingestion (Apple Notes, Apple Mail,
/// iMessage, WhatsApp) and explicit session highlight / standalone backup capture.
@MainActor
struct NativeSourceConnectorsView: View {
    let sources: NativePersonalSources
    let busy: Bool
    var store: AssistantStore? = nil

    @State private var expandedScopePicker: LiveLocalSourceKind?
    @State private var syncErrorMessage: String?

    private var live: LiveLocalSourcesCoordinator { sources.liveSources }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            liveSourcesSection
            DisclosureGroup("Capture selected items for this session") {
                sessionHighlightSection.padding(.top, 12)
            }
            if let store {
                DisclosureGroup("Private questions & imported archives") {
                    offRecordQuestionsAndArchivesSection(store: store).padding(.top, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayFormSection()
    }

    // MARK: - Live Checkpointed Sources Section

    private var liveSourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "tray.full")
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apps on this Mac")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Choose the apps you want to include. Relay reads local copies and keeps your originals unchanged.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if live.isSyncing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Button("Stop") {
                            live.cancelSync()
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .accessibilityIdentifier("liveSources.stopSync")
                    }
                } else {
                    Button("Sync Now") {
                        syncErrorMessage = nil
                        Task {
                            do {
                                _ = try await live.runIncrementalIngestion()
                                syncErrorMessage = live.lastErrorMessage
                            } catch is CancellationError {
                                syncErrorMessage = nil
                            } catch {
                                live.recordSyncError(error)
                                syncErrorMessage = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(busy || live.enabledSources.isEmpty)
                    .accessibilityIdentifier("liveSources.syncNow")
                }
            }

            fullDiskAccessBanner

            VStack(spacing: 8) {
                ForEach(LiveLocalSourceKind.allCases, id: \.self) { kind in
                    if kind != .whatsapp || live.isWhatsAppInstalled || live.isEnabled(.whatsapp) {
                        liveSourceRow(kind)
                    }
                }
            }

            HStack(spacing: 8) {
                if live.isSyncing {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                }
                Text(live.status)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("liveSources.status")
            }

            if let errorMessage = syncErrorMessage ?? live.lastErrorMessage {
                Text(errorMessage)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("liveSources.error")
            }
        }
    }

    @ViewBuilder
    private var fullDiskAccessBanner: some View {
        let fda = live.fullDiskAccessStatus
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: fda.granted ? "checkmark.shield.fill" : "lock.shield")
                .foregroundStyle(fda.granted ? RelayColors.accentEmerald : RelayColors.accentAmber)
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text(fda.granted ? "Full Disk Access Granted" : "Full Disk Access Needed for Live Notes, Mail & iMessage")
                    .font(.relayCaptionStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                Text(fda.guidanceSummary)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !fda.granted {
                Button("Open Full Disk Access…") {
                    _ = live.openFullDiskAccessSettings()
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .accessibilityIdentifier("liveSources.openFullDiskAccess")
            }
            Button("Check") {
                _ = live.refreshFullDiskAccessStatus()
            }
            .buttonStyle(RelaySecondaryButtonStyle())
            .accessibilityIdentifier("liveSources.checkFullDiskAccess")
        }
        .padding(12)
        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
    }

    private func liveSourceRow(_ kind: LiveLocalSourceKind) -> some View {
        let enabled = live.isEnabled(kind)
        let count = live.items(for: kind).count
        let icon: String = switch kind {
        case .notes: "note.text"
        case .appleMail: "envelope.badge.shield.half.filled"
        case .imessage: "message.fill"
        case .whatsapp: "bubble.left.and.bubble.right.fill"
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label(kind.title, systemImage: icon)
                    .font(.relayBodyStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                Spacer()
                if kind != .notes, enabled {
                    Button(expandedScopePicker == kind ? "Hide Scope" : "Choose Scope…") {
                        if expandedScopePicker == kind {
                            expandedScopePicker = nil
                        } else {
                            expandedScopePicker = kind
                            Task { await live.refreshPickers() }
                        }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("liveSources.scope.\(kind.rawValue)")
                }
                if count > 0 {
                    Button("Forget Live") {
                        syncErrorMessage = nil
                        live.forgetSource(kind)
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(busy || live.isSyncing)
                    .accessibilityIdentifier("liveSources.forget.\(kind.rawValue)")
                }
                Toggle("Include \(kind.title)", isOn: Binding(
                    get: { live.isEnabled(kind) },
                    set: { newValue in
                        syncErrorMessage = nil
                        live.setEnabled(kind, newValue)
                        if newValue {
                            Task {
                                do {
                                    _ = try await live.runIncrementalIngestion(sources: [kind])
                                    syncErrorMessage = live.lastErrorMessage
                                } catch is CancellationError {
                                    syncErrorMessage = nil
                                } catch {
                                    live.recordSyncError(error)
                                    syncErrorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(busy && !enabled)
                .accessibilityIdentifier("liveSources.toggle.\(kind.rawValue)")
            }

            Text(live.sourceStatuses[kind] ?? sourceSummary(kind))
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if expandedScopePicker == kind {
                scopeSelectorView(for: kind)
            }
        }
        .padding(12)
        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(enabled ? RelayColors.accentBlue.opacity(0.35) : RelayColors.borderSubtle, lineWidth: 1)
        )
    }

    private func sourceSummary(_ kind: LiveLocalSourceKind) -> String {
        switch kind {
        case .notes: "Notes and ideas saved in Apple Notes."
        case .appleMail: "Inbox and sent mail. Excludes junk, trash, drafts, and bulk mail."
        case .imessage: "The conversations you choose from Messages."
        case .whatsapp: "The conversations you choose from WhatsApp on this Mac."
        }
    }

    @ViewBuilder
    private func scopeSelectorView(for kind: LiveLocalSourceKind) -> some View {
        switch kind {
        case .imessage:
            chatPickerList(
                chats: live.availableIMessageChats,
                selected: live.selectedIMessageChatGUIDs,
                emptyText: live.fullDiskAccessStatus.granted ? "No recent iMessage conversations found." : "Grant Full Disk Access to list conversations.",
                onToggle: { id, isSelected in
                    var updated = live.selectedIMessageChatGUIDs
                    if isSelected { updated.insert(id) } else { updated.remove(id) }
                    live.setSelectedIMessageChats(updated)
                },
                onClearFilter: { live.setSelectedIMessageChats([]) }
            )
        case .whatsapp:
            chatPickerList(
                chats: live.availableWhatsAppChats,
                selected: live.selectedWhatsAppChatJIDs,
                emptyText: "No local WhatsApp conversations found.",
                onToggle: { id, isSelected in
                    var updated = live.selectedWhatsAppChatJIDs
                    if isSelected { updated.insert(id) } else { updated.remove(id) }
                    live.setSelectedWhatsAppChats(updated)
                },
                onClearFilter: { live.setSelectedWhatsAppChats([]) }
            )
        case .appleMail:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(live.selectedMailAccountIDs.isEmpty ? "All Mail accounts included" : "\(live.selectedMailAccountIDs.count) account(s) selected")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayTheme.muted)
                    Spacer()
                    if !live.selectedMailAccountIDs.isEmpty {
                        Button("Include All") { live.setSelectedMailAccounts([]) }
                            .buttonStyle(RelaySecondaryButtonStyle())
                    }
                }
                if live.availableMailAccounts.isEmpty {
                    Text(live.fullDiskAccessStatus.granted ? "No Mail accounts discovered yet." : "Grant Full Disk Access to discover Mail accounts.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayTheme.muted)
                } else {
                    ForEach(live.availableMailAccounts, id: \.id) { account in
                        Toggle("\(account.displayName) (\(account.mailboxCount) mailboxes)", isOn: Binding(
                            get: { live.selectedMailAccountIDs.contains(account.id) },
                            set: { chosen in
                                var next = live.selectedMailAccountIDs
                                if chosen { next.insert(account.id) } else { next.remove(account.id) }
                                live.setSelectedMailAccounts(next)
                            }
                        ))
                        .font(RelayPageStyle.caption)
                    }
                }
            }
            .padding(8)
            .background(RelayTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )
        case .notes:
            EmptyView()
        }
    }

    private func chatPickerList(
        chats: [LiveChatDescriptor],
        selected: Set<String>,
        emptyText: String,
        onToggle: @escaping (String, Bool) -> Void,
        onClearFilter: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selected.isEmpty ? "All eligible conversations included" : "\(selected.count) conversation(s) selected")
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayTheme.muted)
                Spacer()
                if !selected.isEmpty {
                    Button("Include All") { onClearFilter() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                }
            }
            if chats.isEmpty {
                Text(emptyText)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayTheme.muted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(chats.prefix(40)), id: \.id) { chat in
                            Toggle("\(chat.title) (\(chat.messageCount))", isOn: Binding(
                                get: { selected.contains(chat.id) },
                                set: { onToggle(chat.id, $0) }
                            ))
                            .font(RelayPageStyle.caption)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(8)
        .background(RelayTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Session Selection & Standalone Backup Section (Preserves Existing Flows)

    private var sessionHighlightSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session Highlights & Standalone Backups")
                .font(.system(size: 14, weight: .semibold))
            Text("Select up to 8 notes or messages in the Apple app to capture for this session without Full Disk Access, or import a standalone Notes backup.")
                .font(RelayPageStyle.caption).foregroundStyle(RelayTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(NativePersonalSourceKind.allCases) { kind in
                connector(kind)
            }
            HStack(alignment: .top, spacing: 12) {
                Button("Import Notes backup…", action: chooseNotesBackup)
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(busy || sources.isCapturing)
                Button("Forget saved imports") { _ = sources.forgetSavedNotesImports() }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(busy || sources.isCapturing)
                Text("Choose a standalone Notes database backup outside Library folders. Plain text, folder and dates are imported; attachments and formatting are omitted. Private per-note progress is saved so the same backup can resume after interruption.")
                    .font(RelayPageStyle.caption).foregroundStyle(RelayTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func offRecordQuestionsAndArchivesSection(store: AssistantStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Off-Record Source Q&A & Standalone Chat Archives")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RelayColors.textPrimary)
            Text("Ask one-off local questions over captured session highlights or standalone Messages (.db) / WhatsApp (.txt) exports without adding anything to chat history or the knowledge index.")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            PrivateSourceQuestionView(store: store)

            DisclosureGroup("Standalone Chat Archives (Messages & WhatsApp)") {
                ChatArchiveView(store: store)
                    .padding(.top, 8)
            }
            .font(.relayBodyStrong)
            .foregroundStyle(RelayColors.textPrimary)
        }
    }

    private func chooseNotesBackup() {
        guard !busy, !sources.isCapturing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["sqlite", "sqlite3", "db"].compactMap { UTType(filenameExtension: $0) }
        panel.title = "Import an Apple Notes backup"
        panel.message = "Choose a complete standalone copy, without WAL/journal sidecars, outside Library folders. Relay will not open or scan your live Notes store."
        if panel.runModal() == .OK, let selected = panel.url {
            Task { await sources.importNotesBackup(selected) }
        }
    }

    private func connector(_ kind: NativePersonalSourceKind) -> some View {
        let items = sources.items(for: kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label(kind.displayName, systemImage: kind == .notes ? "note.text" : "envelope")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if sources.capturing == kind {
                    ProgressView().controlSize(.small)
                    Button(sources.refreshing == kind ? "Stop refresh" : "Stop capture") { sources.cancelCapture() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button("Capture selected \(kind.itemsName)") {
                        Task { await sources.captureSelection(kind) }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(busy || sources.isCapturing)
                }
                if !items.isEmpty || (kind == .notes && sources.hasNotesImportCache) {
                    Button("Forget") { _ = sources.forget(kind) }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .accessibilityLabel("Forget captured \(kind.itemsName)")
                }
            }
            Text(sources.status(for: kind))
                .font(RelayPageStyle.caption).foregroundStyle(RelayTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if sources.canRefresh(kind) {
                HStack(spacing: 10) {
                    Toggle("Keep these items up to date", isOn: Binding(
                        get: { sources.isRefreshEnabled(kind) },
                        set: { sources.setRefreshEnabled($0, for: kind) }))
                        .toggleStyle(.switch)
                        .disabled(!sources.isRefreshEnabled(kind) && (busy || sources.isCapturing))
                        .help("Refreshes only the captured items once a minute while Relay runs. Capture again after Notes or Mail restarts. Text stays in this Relay session.")
                        .accessibilityIdentifier("nativeSources.autoRefresh.\(kind.rawValue)")
                    Spacer(minLength: 4)
                    Button("Refresh now") { Task { await sources.refreshCaptured(kind) } }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(busy || sources.isCapturing)
                        .accessibilityIdentifier("nativeSources.refresh.\(kind.rawValue)")
                }
                .font(RelayPageStyle.caption)
            }
            ForEach(Array(items.prefix(8))) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .foregroundStyle(RelayTheme.ink)
                        .lineLimit(1)
                    if let date = item.sentAt ?? item.receivedAt {
                        Text((item.sentAt == nil ? "Received " : "Sent ") + date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(RelayTheme.muted)
                    }
                    if let attribution = item.notesAttribution {
                        Text([attribution.folder, attribution.createdAt.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(RelayTheme.muted)
                    }
                }
                .font(RelayPageStyle.caption)
                .textSelection(.enabled)
            }
            if items.count > 8 {
                Text("Showing 8 of \(items.count) imported notes. Search the captured source to find another note.")
                    .font(RelayPageStyle.caption).foregroundStyle(RelayTheme.muted)
            }
        }
    }
}
