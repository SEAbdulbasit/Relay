import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeView: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AssistantStore
    var startInConstellation: Bool = false
    var isSettingsPane: Bool = false
    var requestedNote: KnowledgeNoteDestination? = nil
    var navigationGuard: KnowledgeNavigationGuard? = nil
    var onOpenWorkspace: (() -> Void)? = nil

    @StateObject private var skyModel = NightSkyModel()
    @Bindable private var semanticVault = SemanticVaultBuilder.shared
    @Bindable private var writingStyle = WritingStyleCollector.shared
    @State private var fullGalaxyMode: Bool = false
    @State private var didApplyInitialMode = false
    @State private var expandedDomains: Set<String> = [
        GeneratedKnowledgeNote.domain, "Your Notes",
        "Local folder: People", "Local folder: Projects", "Local folder: Plans", "Local folder: Preferences",
        "People", "Projects", "Plans", "Preferences"
    ]
    @State private var selectedNodeURL: URL? = nil
    @State private var readerBackStack: [URL] = []
    @State private var vaultNotes: [LocalMarkdownNote] = []
    @State private var vaultFolders: [LocalMarkdownFolder] = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var noteEditor: VaultNoteEditor.Request?
    @State private var consolidationEntity: CrossSourceKnowledge.Entity?
    @State private var showSharingSheet = false
    @State private var showWritingStyleSheet = false
    @State private var writingStyleDraft = ""
    @State private var writingStyleError: String?
    @State private var vaultStatus: String?
    @State private var vaultLoadError: String?
    @State private var vaultFilter = ""
    @State private var showClearIndexConfirmation = false
    @State private var showAllIndexedFiles = false
    @State private var selectedDomainFilter: VaultDomainFilter = .all

    private enum VaultDomainFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case people = "People"
        case projects = "Projects"
        case plans = "Plans"
        case preferences = "Preferences"
        case sources = "Sources"

        var id: String { rawValue }

        func matches(domainName: String) -> Bool {
            let display = LocalMarkdownFolder.displayName(for: domainName).lowercased()
            let raw = domainName.lowercased()
            switch self {
            case .all:
                return true
            case .people:
                return display == "people" || raw.contains("people")
            case .projects:
                return display == "projects" || raw.contains("projects")
            case .plans:
                return display == "plans" || raw.contains("plans")
            case .preferences:
                return display == "preferences" || raw.contains("preferences")
            case .sources:
                return display.contains("source") || raw.contains("source") || domainName == GeneratedKnowledgeNote.domain
            }
        }
    }

    // Inline Reader editing & Save/Discard/Cancel guard (`KNW-10`, `KNW-12`)
    @State private var inlineEditingNote: LocalMarkdownNote?
    @State private var inlineEditTitle = ""
    @State private var inlineEditBody = ""
    @State private var showUnsavedEditsAlert = false
    @State private var readerNavigation = KnowledgeUnsavedChangesGuard<PendingReaderAction>()
    @State private var navigationOwner = UUID()
    @State private var notePendingDeletion: LocalMarkdownNote?
    @State private var recoveryDrafts: [KnowledgeDraftStore.Record] = []
    @State private var recoveryDraft: KnowledgeDraftStore.Record?
    @State private var draftRecoveryError: String?
    @State private var showNoteTrash = false
    @State private var draftWritesSuppressed = false

    private var draftStore: KnowledgeDraftStore {
        KnowledgeDraftStore(vaultDirectory: KnowledgeVaultManager.shared.vaultDirectory)
    }

    private var pendingRecoveryDrafts: [KnowledgeDraftStore.Record] {
        recoveryDrafts.filter { $0.graphURL != inlineEditingNote?.graphURL }
    }

    private var inlineTitleBinding: Binding<String> {
        Binding(get: { inlineEditTitle }, set: { inlineEditTitle = $0; checkpointInlineDraft() })
    }

    private var inlineBodyBinding: Binding<String> {
        Binding(get: { inlineEditBody }, set: { inlineEditBody = $0; checkpointInlineDraft() })
    }

    private enum PendingReaderAction {
        case leaveWorkspace(@MainActor () -> Void)
        case openNoteSheet
        case chatWithEditableNote(URL)
        case openRequestedNote(KnowledgeNoteDestination)
        case selectNode(SkyNode, recordHistory: Bool)
        case selectOverview(URL)
        case goBack
        case toggleConstellation
        case openNewNote
        case openTrash
        case reviewDraft(KnowledgeDraftStore.Record)
    }

    private var hasUnsavedInlineEdits: Bool {
        guard let editing = inlineEditingNote else { return false }
        return inlineEditTitle != editing.title || inlineEditBody != editing.body
    }

    private var hasVaultContent: Bool {
        !store.knowledge.records.isEmpty || !store.nativeSources.liveSources.knowledgeRecords().isEmpty || !vaultNotes.isEmpty || !vaultFolders.isEmpty
    }

    @State private var exportError: String?

    private var activeNode: SkyNode? {
        guard let graph = skyModel.graph else { return nil }
        if let url = selectedNodeURL, let found = graph.nodes.first(where: { $0.url == url }) {
            return found
        }
        if let rootIdx = graph.rootIndex, graph.nodes.indices.contains(rootIdx) {
            return graph.nodes[rootIdx]
        }
        return graph.nodes.first
    }

    var body: some View {
        Group {
            if isSettingsPane {
                settingsKnowledgeBody
            } else {
                workspaceKnowledgeVaultBody
            }
        }
        .foregroundStyle(RelayColors.textPrimary)
        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentGold))
        .onChange(of: store.knowledge.records) { _, _ in
            store.knowledgeSearch.invalidateSources()
            store.suggestions.purge(records: store.knowledge.records)
            updateVaultGraph()
        }
        .onChange(of: store.generatedKnowledge.notes) { _, notes in
            if let copy = noteEditor?.sourceCopy, !notes.contains(where: { $0.id == copy.noteID }) {
                noteEditor = nil
                vaultStatus = "The source changed or access was removed before the editable copy was saved."
            }
            updateVaultGraph()
        }
        .onAppear {
            draftWritesSuppressed = false
            navigationGuard?.install(owner: navigationOwner) { action in
                requestGuardedReaderAction(.leaveWorkspace(action))
            }
            store.knowledge.purgeStale(grants: store.grants)
            store.suggestions.purge(records: store.knowledge.records)
            if !isSettingsPane {
                store.generatedKnowledge.reconcile(records: store.knowledge.records)
                reloadVaultNotes(entrance: !reducedMotion)
                reloadRecoveryDrafts()
                if !didApplyInitialMode {
                    didApplyInitialMode = true
                    fullGalaxyMode = startInConstellation
                }
            }
        }
        .onDisappear {
            checkpointInlineDraft()
            navigationGuard?.remove(owner: navigationOwner)
        }
        .onChange(of: requestedNote, initial: true) { _, destination in
            guard !isSettingsPane, let destination else { return }
            requestGuardedReaderAction(.openRequestedNote(destination))
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("relay.willEraseLocalData"))) { _ in
            // Explicit reset/uninstall must not be undone by a retiring editor.
            draftWritesSuppressed = true
            inlineEditingNote = nil
            inlineEditTitle = ""
            inlineEditBody = ""
            recoveryDraft = nil
            recoveryDrafts = []
            draftRecoveryError = nil
            showNoteTrash = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.knowledge.purgeStale(grants: store.grants)
            store.suggestions.purge(records: store.knowledge.records)
            if !isSettingsPane {
                store.generatedKnowledge.reconcile(records: store.knowledge.records)
                reloadVaultNotes()
            }
        }
        .sheet(item: $recoveryDraft, onDismiss: reloadRecoveryDrafts) { record in
            KnowledgeDraftRecoverySheet(record: record, drafts: draftStore, vault: .shared,
                onRestore: restoreRecoveryDraft,
                onSavedCopy: { saved, warning in
                    reloadVaultNotes()
                    selectedNodeURL = saved.graphURL
                    fullGalaxyMode = false
                    reloadRecoveryDrafts()
                    vaultStatus = warning ?? "Saved recovered copy “\(saved.title)”."
                }, onDiscard: reloadRecoveryDrafts)
        }
        .sheet(isPresented: $showNoteTrash) {
            NoteTrashSheet(vault: .shared) { restored in
                reloadVaultNotes()
                selectedNodeURL = restored.graphURL
                fullGalaxyMode = false
            }
        }
        .sheet(item: $noteEditor) { request in
            VaultNoteEditor(request: request, folders: vaultFolders) { saved in
                reloadVaultNotes()
                selectedNodeURL = saved.graphURL
                fullGalaxyMode = false
                skyModel.highlight(saved.graphURL)
            }
        }
        .sheet(isPresented: $showSharingSheet) {
            knowledgeSharingModal
        }
        .sheet(isPresented: $showWritingStyleSheet) {
            writingStyleModal
        }
        .sheet(item: $consolidationEntity) { entity in
            ConsolidationReviewView(entity: entity, vault: store.generatedKnowledge,
                records: { store.knowledge.records },
                isCurrent: { store.knowledge.revalidate($0, grants: store.grants) },
                authorizationScopeIDs: store.grants.map(\.id),
                isAuthorized: { $0.isAuthorized(grants: store.grants) },
                canGenerate: { !store.isRunning && !store.voice.isBusy && !store.knowledge.isIndexing && store.workspaceActionsReady },
                generate: { await store.consolidateKnowledge(entityURL: entity.id, expectedSourcePaths: entity.sourcePaths) }) { saved in
                    reloadVaultNotes()
                    selectedNodeURL = saved.graphURL
                    fullGalaxyMode = false
                    skyModel.highlight(saved.graphURL)
                }
        }
        .confirmationDialog("Clear the local file index?", isPresented: $showClearIndexConfirmation, titleVisibility: .visible) {
            Button("Clear Index", role: .destructive) {
                store.invalidateDerivedContext(reason: "Local index cleared.")
                store.knowledge.clear()
                skyModel.load(records: store.knowledge.records, entrance: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes indexed file excerpts and derived context. Your original files, source access, and vault notes stay in place. You can index your sources again.")
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
                .accessibilityIdentifier("knowledge.folderName")
            Button("Create folder") { createVaultFolder() }
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Organize editable Markdown notes in Relay’s local vault.")
        }
        .alert("Save changes to this note?", isPresented: $showUnsavedEditsAlert) {
            Button("Save") {
                if let action = readerNavigation.resolve(.save, save: saveInlineEdits) {
                    runReaderAction(action)
                }
            }
            Button("Discard", role: .destructive) {
                guard discardInlineDraft() else { return }
                inlineEditingNote = nil
                if let action = readerNavigation.resolve(.discard) { runReaderAction(action) }
            }
            Button("Cancel", role: .cancel) {
                _ = readerNavigation.resolve(.cancel)
            }
        } message: {
            Text("You have unsaved edits in “\(inlineEditingNote?.title ?? "this note")”.")
        }
        .confirmationDialog(
            "Move “\(notePendingDeletion?.title ?? "Note")” to Trash?",
            isPresented: Binding(
                get: { notePendingDeletion != nil },
                set: { if !$0 { notePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let note = notePendingDeletion {
                Button("Move to Trash", role: .destructive) {
                    deleteVaultNote(note)
                    notePendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                notePendingDeletion = nil
            }
        } message: {
            Text("The note is kept locally in Recently deleted notes, where you can restore it. Its existing recovery drafts are kept separately.")
        }
    }

    private var workspaceKnowledgeVaultBody: some View {
        return VStack(spacing: 0) {
            header
            if !pendingRecoveryDrafts.isEmpty || draftRecoveryError != nil {
                recoveryBanner
            }

            Rectangle().fill(RelayColors.borderSubtle).frame(height: 1)

            if !hasVaultContent {
                emptyKnowledgeState
            } else if fullGalaxyMode {
                NightSkyView(model: skyModel, showsHUD: true) { clickedNode in
                    performSelectVaultNode(clickedNode, recordHistory: true)
                    fullGalaxyMode = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    vaultLeftSidebar
                        .frame(width: 256)
                        .frame(maxHeight: .infinity)
                        .background(RelayColors.pitch)
                    Rectangle().fill(RelayColors.borderSubtle).frame(width: 1)
                    vaultMiddleMarkdownPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RelayColors.canvas)
                }
            }
            if let vaultStatus = vaultLoadError ?? vaultStatus {
                Rectangle().fill(RelayColors.borderSubtle).frame(height: 1)
                Text(vaultStatus)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.horizontal, RelayTheme.inset)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RelayColors.pitch)
                    .textSelection(.enabled)
            }
        }
        .background(RelayColors.canvas)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerContent(showCounts: true).labelStyle(.titleAndIcon)
            headerContent(showCounts: false).labelStyle(.iconOnly)
        }
        .frame(height: 44)
        .background(RelayColors.pitch.opacity(0.45))
    }

    private func headerContent(showCounts: Bool) -> some View {
        let noteCount = vaultNotes.count
        let combinedRecords = store.knowledge.records + store.nativeSources.liveSources.knowledgeRecords()
        let sourceCount = Set(combinedRecords.map(\.sourcePath)).count
        return HStack(spacing: RelaySpace.sm) {
            // Segmented Vault / Constellation mode switcher
            HStack(spacing: 4) {
                knowledgeModePill(
                    title: "Library",
                    icon: "books.vertical",
                    isSelected: !fullGalaxyMode,
                    disabled: false
                ) {
                    if fullGalaxyMode {
                        requestGuardedReaderAction(.toggleConstellation)
                    }
                }
                knowledgeModePill(
                    title: "Constellation",
                    icon: "sparkles",
                    isSelected: fullGalaxyMode,
                    disabled: !hasVaultContent
                ) {
                    if !fullGalaxyMode {
                        requestGuardedReaderAction(.toggleConstellation)
                    }
                }
            }
            .padding(3)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )
            .accessibilityIdentifier("knowledge.toggleConstellation")

            if showCounts {
                Text("\(sourceCount) \(sourceCount == 1 ? "source" : "sources") · \(noteCount) \(noteCount == 1 ? "note" : "notes")")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .accessibilityIdentifier("knowledge.libraryCount")
            }
            Spacer(minLength: RelaySpace.xs)

            Button("New note", systemImage: "square.and.pencil") {
                requestGuardedReaderAction(.openNewNote)
            }
            .buttonStyle(RelayPrimaryButtonStyle())
            .accessibilityIdentifier("knowledge.newNote")

            Menu {
                Button("Refresh library", systemImage: "arrow.clockwise") {
                    store.knowledge.purgeStale(grants: store.grants)
                    store.suggestions.purge(records: store.knowledge.records)
                    store.generatedKnowledge.reconcile(records: store.knowledge.records)
                    reloadVaultNotes(entrance: false)
                }
                .accessibilityIdentifier("knowledge.refresh")
                Button("New folder…", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    showNewFolder = true
                }
                .accessibilityIdentifier("knowledge.newFolder")
                Divider()
                Button(writingStyle.hasSnapshot ? "Writing style…" : "Create writing style…", systemImage: "pencil.and.scribble") {
                    openWritingStyleEditor()
                }
                .accessibilityIdentifier("knowledge.editWritingStyle")
                Button("Recently deleted notes…", systemImage: "trash") {
                    requestGuardedReaderAction(.openTrash)
                }
                .accessibilityIdentifier("knowledge.recentlyDeletedNotes")
                Button("Share knowledge…", systemImage: "square.and.arrow.up") { showSharingSheet = true }
                    .accessibilityIdentifier("knowledge.share")
            } label: {
                Label("Library actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("knowledge.libraryActions")

        }
        .padding(.horizontal, RelaySpace.lg)
        .frame(height: 44)
    }

    private func knowledgeModePill(
        title: String,
        icon: String,
        isSelected: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.relayCaptionStrong)
                    .lineLimit(1)
            }
            .foregroundStyle(
                disabled
                    ? RelayColors.textDim
                    : (isSelected ? RelayColors.textPrimary : RelayColors.textSecondary)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minHeight: 24)
            .background(
                isSelected ? RelayColors.surfaceElevated : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? RelayColors.borderDefault : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(RelayPressStyle())
        .disabled(disabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Left Column: `Your knowledge` + `◎ Overview` + Collapsible Domain Folders

    private var vaultLeftSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(RelayColors.textMuted)
                    TextField("Filter vault…", text: $vaultFilter)
                        .textFieldStyle(.plain)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textPrimary)
                        .relayTextFieldPrompt("Filter vault…", when: vaultFilter.isEmpty, font: .relayCaption)
                        .accessibilityIdentifier("knowledge.filterTitles")
                    if !vaultFilter.isEmpty {
                        Button {
                            vaultFilter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(RelayColors.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RelayColors.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 2)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                    ForEach(VaultDomainFilter.allCases) { chip in
                        let isSelected = selectedDomainFilter == chip
                        Button {
                            selectedDomainFilter = (selectedDomainFilter == chip && chip != .all) ? .all : chip
                        } label: {
                            Text(chip.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(
                                    isSelected ? RelayColors.surfaceElevated : RelayColors.subtleFill,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(isSelected ? RelayColors.accentGold.opacity(0.65) : RelayColors.borderSubtle, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("knowledge.domainChip.\(chip.rawValue.lowercased())")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

                if let graph = skyModel.graph {
                    // Overview Row (`◎ Overview`)
                    if let rootIdx = graph.rootIndex {
                        let rootNode = graph.nodes[rootIdx]
                        let isOverviewSelected = activeNode?.url == rootNode.url
                        KnowledgeSidebarOverviewRow(isSelected: isOverviewSelected) {
                            requestGuardedReaderAction(.selectOverview(rootNode.url))
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                    }

                    // Domain Folders (`› 📁 Indexed Sources`, etc.)
                    ForEach(orderedDomainIndices(in: graph), id: \.self) { dIdx in
                        let domainName = graph.domains[dIdx]
                        let relationshipKind = KnowledgeRelationship.Kind.allCases.first { $0.domain == domainName }
                        let isFiltering = !vaultFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedDomainFilter != .all
                        let domainNodes = filteredDomainNodes(in: graph, domainIndex: dIdx, domainName: domainName)
                        let isExpanded = expandedDomains.contains(domainName) || (isFiltering && !domainNodes.isEmpty)
                        let groupURL = graph.nodes.first { $0.url.host == "group" && $0.domain == dIdx }?.url
                        let isGroupSelected = groupURL != nil && selectedNodeURL == groupURL

                        if (!isFiltering || !domainNodes.isEmpty) && selectedDomainFilter.matches(domainName: domainName) {
                            VStack(alignment: .leading, spacing: 3) {
                                KnowledgeSidebarFolderRow(
                                    title: collectionTitle(domainName),
                                    count: domainNodes.count,
                                    color: RelayColors.workbenchAccent,
                                    isExpanded: isExpanded,
                                    isSelected: isGroupSelected,
                                    relationshipKind: relationshipKind
                                ) {
                                    let willExpand = !expandedDomains.contains(domainName)
                                    withAnimation(reducedMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86)) {
                                        if willExpand {
                                            expandedDomains.insert(domainName)
                                        } else {
                                            expandedDomains.remove(domainName)
                                        }
                                    }
                                    if willExpand, selectedNodeURL == nil, let firstNode = domainNodes.first {
                                        selectVaultNode(firstNode)
                                    }
                                }

                                if isExpanded {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(domainNodes) { node in
                                            sidebarNoteRow(node)
                                        }
                                    }
                                    .transition(.opacity)
                                }
                            }
                            .padding(.horizontal, 10)
                        }
                    }
                }

                if let graph = skyModel.graph,
                   !vaultFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   graph.domains.indices.allSatisfy({ filteredDomainNodes(in: graph, domainIndex: $0, domainName: graph.domains[$0]).isEmpty }) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("No matching items").font(.relayCaptionStrong)
                        Text("Try a different word or choose All to search every collection.")
                            .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                        Button("Clear filters") { vaultFilter = ""; selectedDomainFilter = .all }
                            .buttonStyle(RelayGhostButtonStyle())
                    }
                    .padding(16)
                    .accessibilityIdentifier("knowledge.noFilterResults")
                }

                DisclosureGroup("Create from sources") {
                    generatedKnowledgeControls.padding(.top, 8)
                }
                .font(.relayCaptionStrong)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            .padding(.bottom, 18)
        }
    }

    private func collectionTitle(_ name: String) -> String {
        if name == "Indexed Sources" { return "Sources" }
        if name == GeneratedKnowledgeNote.domain { return "Generated highlights" }
        return LocalMarkdownFolder.displayName(for: name)
    }

    private func orderedDomainIndices(in graph: SkyGraph) -> [Int] {
        let folderPrefix = LocalMarkdownFolder.domainPrefix
        let generatedDomain = GeneratedKnowledgeNote.domain
        return graph.domains.indices.sorted { lhs, rhs in
            func rank(_ name: String) -> Int {
                if name == "Your Notes" || name.hasPrefix(folderPrefix) { return 0 }
                if name == generatedDomain { return 1 }
                if name == "Indexed Sources" { return 3 }
                return 2
            }
            let a = rank(graph.domains[lhs]), b = rank(graph.domains[rhs])
            return a == b ? lhs < rhs : a < b
        }
    }

    private func deskOverview(graph: SkyGraph) -> some View {
        let records = store.knowledge.records + store.nativeSources.liveSources.knowledgeRecords()
        let notes = vaultNotes.prefix(6).map { note in
            KnowledgeDeskOverview.Item(id: note.graphURL, title: note.title,
                detail: note.folderName.map { "Your note · " + $0 } ?? "Your note · Markdown",
                preview: String(note.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180)), icon: "doc.text")
        }
        let currentGenerated = store.generatedKnowledge.notes.filter { note in graph.nodes.contains { $0.url == note.graphURL } }
        let generated = currentGenerated.prefix(3).map { note in
            KnowledgeDeskOverview.Item(id: note.graphURL, title: note.title,
                detail: "Generated · " + note.sourceTitle, preview: note.highlights.first ?? "", icon: "text.badge.star")
        }
        let collections = orderedDomainIndices(in: graph).compactMap { index -> KnowledgeDeskOverview.Item? in
            let name = graph.domains[index]
            guard let group = graph.nodes.first(where: { $0.url.host == "group" && $0.domain == index }) else { return nil }
            let count = graph.nodes.filter { !$0.isRoot && $0.url.host != "group" && $0.domain == index }.count
            guard count > 0 else { return nil }
            return .init(id: group.url, title: collectionTitle(name),
                detail: "\(count) \(count == 1 ? "item" : "items")", preview: "", icon: name == "Indexed Sources" ? "tray.full" : "folder")
        }
        return KnowledgeDeskOverview(noteCount: vaultNotes.count, sourceCount: Set(records.map(\.sourcePath)).count,
            generatedCount: currentGenerated.count, notes: notes, generatedNotes: generated, collections: collections,
            onOpen: { url in
                if let node = graph.nodes.first(where: { $0.url == url }) {
                    if node.url.host == "group", graph.domains.indices.contains(node.domain) {
                        vaultFilter = ""
                        selectedDomainFilter = .all
                        expandedDomains.insert(graph.domains[node.domain])
                    }
                    selectVaultNode(node)
                }
            }, onNewNote: { requestGuardedReaderAction(.openNewNote) }, onBrowseSources: {
                vaultFilter = ""
                selectedDomainFilter = .sources
                expandedDomains.insert("Indexed Sources")
                if let group = graph.nodes.first(where: { $0.url.host == "group" && $0.title == "Indexed Sources" }) {
                    selectVaultNode(group)
                }
            })
    }

    private func filteredDomainNodes(in graph: SkyGraph, domainIndex: Int, domainName: String) -> [SkyNode] {
        guard selectedDomainFilter.matches(domainName: domainName) else { return [] }
        let query = vaultFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryTitle = LocalMarkdownFolder.displayName(for: domainName)
        return graph.nodes.filter { node in
            guard !node.isRoot, node.domain == domainIndex, node.url.host != "group" else { return false }
            guard !query.isEmpty else { return true }
            return node.title.localizedStandardContains(query)
                || categoryTitle.localizedStandardContains(query)
                || node.preview.localizedStandardContains(query)
                || node.markdownBody.localizedStandardContains(query)
        }
    }

    private var generatedKnowledgeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if semanticVault.isBuilding {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Slice \(max(1, semanticVault.completedSlices + 1))/\(max(1, semanticVault.totalSlices))")
                        .font(.relayMonoSmall)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Button("Stop vault synthesis") { semanticVault.cancel() }
            } else {
                Button(semanticVault.canResume ? "Resume Vault Synthesis" : "Synthesize Vault", systemImage: "wand.and.stars") {
                    runSemanticVaultSynthesis()
                }
                .disabled(store.isRunning || store.voice.isBusy || store.knowledge.isIndexing || !store.workspaceActionsReady)
                .accessibilityIdentifier("knowledge.synthesizeVault")
            }

            if store.generatedKnowledge.isGenerating {
                ProgressView().controlSize(.small)
                Button("Stop generation") { store.generatedKnowledge.cancel() }
            } else {
                Button("Generate highlights", systemImage: "sparkles") {
                    Task { await store.generateKnowledgeNotes() }
                }
                .disabled(store.isRunning || store.voice.isBusy || store.knowledge.isIndexing ||
                          store.knowledge.records.isEmpty || !store.actionsReady)
                .accessibilityIdentifier("knowledge.generateHighlights")
            }
            Text(semanticVault.isBuilding || semanticVault.lastReport != nil
                 ? semanticVault.status
                 : (store.actionsReady ? store.generatedKnowledge.status : "Configure a model to synthesize notes or highlights."))
                .font(.relayMicro)
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(2)
                .accessibilityIdentifier("knowledge.generationStatus")
        }
        .buttonStyle(RelaySecondaryButtonStyle())
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayColors.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 0.75)
        )
    }

    private func selectVaultNode(_ node: SkyNode) {
        requestGuardedReaderAction(.selectNode(node, recordHistory: true))
    }

    private func performSelectVaultNode(_ node: SkyNode, recordHistory: Bool) {
        if KnowledgeRelationship.Kind.from(node.url) != nil {
            let sourcePaths = Set((skyModel.graph?.linkedNodes(from: node.url) ?? []).filter(\.url.isFileURL).map(\.url.path))
            let records = store.knowledge.records.filter { sourcePaths.contains($0.sourcePath) }
            for record in records { _ = store.knowledge.revalidate(record, grants: store.grants) }
            if records.contains(where: { !store.knowledge.records.contains($0) }) {
                updateVaultGraph()
                guard skyModel.graph?.nodes.contains(where: { $0.url == node.url }) == true else {
                    vaultStatus = "The linked sources changed or access was removed."
                    return
                }
            }
        } else if node.url.isFileURL {
            let allRecords = store.knowledge.records + store.nativeSources.liveSources.knowledgeRecords()
            guard let record = allRecords.first(where: { $0.sourcePath == node.url.path }),
                  (!store.knowledge.records.contains(record) || store.knowledge.revalidate(record, grants: store.grants)) else {
                vaultStatus = "This source changed or access was removed."
                return
            }
        } else if node.url.host == "generated" {
            guard let note = store.generatedKnowledge.notes.first(where: { $0.graphURL == node.url }),
                  let source = generatedSource(for: note) else {
                vaultStatus = "The generated note’s source is no longer current."
                return
            }
            guard store.knowledge.revalidate(source, grants: store.grants) else {
                vaultStatus = "The generated note’s source changed or access was removed."
                return
            }
        }
        if recordHistory, let previousURL = activeNode?.url, previousURL != node.url {
            readerBackStack.append(previousURL)
            if readerBackStack.count > 32 { readerBackStack.removeFirst() }
        }
        inlineEditingNote = nil
        selectedNodeURL = node.url
        skyModel.highlight(node.url)
    }

    private func requestGuardedReaderAction(_ action: PendingReaderAction) {
        if let approved = readerNavigation.request(action, hasUnsavedChanges: hasUnsavedInlineEdits) {
            inlineEditingNote = nil
            runReaderAction(approved)
        } else {
            showUnsavedEditsAlert = true
        }
    }

    private func runReaderAction(_ action: PendingReaderAction) {
        switch action {
        case .leaveWorkspace(let leave):
            leave()
        case .openNoteSheet:
            // Save may rename the note. Resolve the updated selection after
            // reloading instead of opening the stale pre-alert note snapshot.
            reloadVaultNotes()
            guard let selectedNodeURL,
                  let current = vaultNotes.first(where: { $0.graphURL == selectedNodeURL }) else {
                vaultStatus = "This note is no longer available. Choose it again before opening the editor."
                return
            }
            noteEditor = .init(note: current)
        case .chatWithEditableNote(let graphURL):
            reloadVaultNotes()
            guard let current = vaultNotes.first(where: { $0.graphURL == graphURL }) else {
                vaultStatus = "This note is no longer available. Choose it again before starting a chat."
                return
            }
            chatWithNote(title: current.title, markdownBody: current.body)
        case .openRequestedNote(let destination):
            reloadVaultNotes()
            guard let note = destination.resolve(in: vaultNotes),
                  let node = skyModel.graph?.nodes.first(where: { $0.url == note.graphURL }) else {
                vaultStatus = "This note is no longer available. Search again or choose another note."
                return
            }
            vaultFilter = ""
            selectedDomainFilter = .all
            expandedDomains.insert(note.folderName.map { LocalMarkdownFolder.domainPrefix + $0 } ?? "Your Notes")
            fullGalaxyMode = false
            performSelectVaultNode(node, recordHistory: true)
        case .selectNode(let node, let recordHistory):
            performSelectVaultNode(node, recordHistory: recordHistory)
        case .selectOverview(let rootURL):
            if let prev = activeNode?.url, prev != rootURL {
                readerBackStack.append(prev)
            }
            selectedNodeURL = rootURL
            skyModel.highlight(rootURL)
        case .goBack:
            guard let targetURL = readerBackStack.popLast() else { return }
            if let targetNode = skyModel.graph?.nodes.first(where: { $0.url == targetURL }) {
                performSelectVaultNode(targetNode, recordHistory: false)
            } else {
                selectedNodeURL = targetURL
                skyModel.highlight(targetURL)
            }
        case .toggleConstellation:
            fullGalaxyMode.toggle()
            if fullGalaxyMode, let currentURL = activeNode?.url {
                skyModel.highlight(currentURL)
            }
        case .openNewNote:
            noteEditor = .init()
        case .openTrash:
            showNoteTrash = true
        case .reviewDraft(let record):
            recoveryDraft = record
        }
    }

    private func startInlineEditing(_ note: LocalMarkdownNote) {
        reloadRecoveryDrafts()
        if let existing = recoveryDrafts.first(where: { $0.graphURL == note.graphURL }) {
            recoveryDraft = existing
            return
        }
        inlineEditingNote = note
        inlineEditTitle = note.title
        inlineEditBody = note.body
    }

    @discardableResult
    private func saveInlineEdits() -> Bool {
        guard let original = inlineEditingNote else { return true }
        do {
            let saved = try KnowledgeVaultManager.shared.saveNote(
                title: inlineEditTitle,
                body: inlineEditBody,
                replacing: original
            )
            let cleared = discardInlineDraft()
            inlineEditingNote = nil
            reloadVaultNotes()
            if selectedNodeURL == original.graphURL {
                selectedNodeURL = saved.graphURL
            }
            skyModel.highlight(saved.graphURL)
            vaultStatus = cleared ? "Saved “\(saved.title)”." : "Saved “\(saved.title)”. The old recovery checkpoint could not be cleared."
            return true
        } catch {
            vaultStatus = error.localizedDescription
            return false
        }
    }

    private var recoveryBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingRecoveryDrafts.isEmpty {
                HStack(spacing: 12) {
                    Label("\(pendingRecoveryDrafts.count) unsaved \(pendingRecoveryDrafts.count == 1 ? "draft" : "drafts") on this Mac", systemImage: "clock.arrow.circlepath")
                        .font(.relayCaptionStrong)
                    Spacer()
                    Menu("Review drafts") {
                        ForEach(pendingRecoveryDrafts) { draft in
                            Button(draft.title.isEmpty ? draft.originalTitle : draft.title) { requestGuardedReaderAction(.reviewDraft(draft)) }
                        }
                    }
                    .accessibilityIdentifier("knowledge.reviewRecoveryDrafts")
                }
            }
            if let draftRecoveryError {
                Text(draftRecoveryError).font(.relayCaption).foregroundStyle(RelayColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(RelayColors.workbenchTint)
        .accessibilityIdentifier("knowledge.recoveryBanner")
    }

    private func reloadRecoveryDrafts() {
        guard !isSettingsPane else { return }
        do {
            let loaded = try draftStore.load()
            recoveryDrafts = loaded.records
            draftRecoveryError = loaded.unreadableCount == 0 ? nil : "\(loaded.unreadableCount) recovery \(loaded.unreadableCount == 1 ? "file could" : "files could") not be read. The files have been kept."
        } catch { draftRecoveryError = "Draft recovery could not be opened: " + error.localizedDescription }
    }

    private func checkpointInlineDraft() {
        guard !draftWritesSuppressed, !isSettingsPane else { return }
        guard let note = inlineEditingNote else { return }
        do {
            let saved = try draftStore.checkpoint(note: note, title: inlineEditTitle, body: inlineEditBody)
            recoveryDrafts.removeAll { $0.graphURL == note.graphURL }
            if let saved { recoveryDrafts.insert(saved, at: 0) }
            draftRecoveryError = nil
        } catch { draftRecoveryError = "The latest edit could not be checkpointed. Keep this window open: " + error.localizedDescription }
    }

    @discardableResult
    private func discardInlineDraft() -> Bool {
        guard let note = inlineEditingNote else { return true }
        do {
            try draftStore.discard(note: note)
            recoveryDrafts.removeAll { $0.graphURL == note.graphURL }
            draftRecoveryError = nil
            return true
        } catch {
            draftRecoveryError = "The recovery draft could not be cleared: " + error.localizedDescription
            return false
        }
    }

    private func restoreRecoveryDraft(_ record: KnowledgeDraftStore.Record) -> Bool {
        guard !draftWritesSuppressed else { return false }
        guard inlineEditingNote == nil else { return false }
        reloadVaultNotes()
        guard let original = draftStore.matchingOriginal(for: record, notes: vaultNotes),
              let node = skyModel.graph?.nodes.first(where: { $0.url == original.graphURL }) else { return false }
        performSelectVaultNode(node, recordHistory: true)
        fullGalaxyMode = false
        expandedDomains.insert(original.folderName.map { LocalMarkdownFolder.domainPrefix + $0 } ?? "Your Notes")
        inlineEditingNote = original
        inlineEditTitle = record.title
        inlineEditBody = record.body
        checkpointInlineDraft()
        return true
    }

    private func runSemanticVaultSynthesis() {
        vaultStatus = nil
        store.knowledge.purgeStale(grants: store.grants)
        let localCorpus = MorningBriefCorpusBridge.buildCorpus(from: store)
        Task { @MainActor in
            _ = try? await writingStyle.collectOnceFromLiveSources(store.nativeSources.liveSources)
            do {
                let cloudCorpus = await MorningBriefCorpusBridge.fetchConnectedCloudCorpus(from: store)
                let report = try await semanticVault.buildOrUpdate(
                    items: localCorpus + cloudCorpus,
                    isSourceCurrent: { [weak store] item in
                        guard let store else { return false }
                        return MorningBriefCorpusBridge.isSourceCurrent(item.id, store: store)
                    },
                    complete: { messages in
                        try await store.auxiliaryText(messages)
                    }
                )
                reloadVaultNotes(entrance: false)
                vaultStatus = "Synthesized Knowledge Vault (\(report.noteCount) notes, \(report.wikilinksVerified) verified wikilinks)."
            } catch is CancellationError {
                vaultStatus = semanticVault.status
            } catch {
                vaultStatus = error.localizedDescription
            }
        }
    }

    private var knowledgeSharingModal: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Share Knowledge Vault")
                    .font(.relayHeadline.weight(.semibold))
                Spacer()
                Button("Done") { showSharingSheet = false }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LocalKnowledgeMCPSettingsView(server: store.knowledgeSharing)
                    PortableKnowledgeSharingView()
                    HostedKnowledgeMirrorSettingsView(mirror: .shared)
                }
            }
        }
        .padding(22)
        .frame(width: 640, height: 500)
        .background(RelayTheme.background)
        .foregroundStyle(RelayTheme.ink)
        .relayPreferredAppearance()
    }

    private func openWritingStyleEditor() {
        do {
            writingStyleDraft = try WritingStyleCollector.readSnapshot(in: WritingStyleCollector.shared.vaultRoot) ?? ""
            writingStyleError = nil
        } catch {
            writingStyleDraft = ""
            writingStyleError = error.localizedDescription
        }
        showWritingStyleSheet = true
    }

    private func saveWritingStyleSnapshot() {
        do {
            try WritingStyleCollector.saveUserEditedSnapshot(
                writingStyleDraft,
                in: WritingStyleCollector.shared.vaultRoot
            )
            writingStyle.refreshStatus()
            writingStyleError = nil
            showWritingStyleSheet = false
            vaultStatus = "Saved \(WritingStyleCollector.fileName) (\(writingStyleDraft.utf8.count) bytes)."
        } catch {
            writingStyleError = error.localizedDescription
        }
    }

    private var writingStyleModal: some View {
        let byteCount = writingStyleDraft.utf8.count
        let maxBytes = WritingStyleCollector.maximumBytes
        let overLimit = byteCount > maxBytes
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(writingStyle.hasSnapshot ? "Edit Writing Style" : "Create Writing Style")
                        .font(.relayHeadline.weight(.semibold))
                        .accessibilityIdentifier("knowledge.writingStyleTitle")
                    Text("Stored locally at KnowledgeVault/\(WritingStyleCollector.fileName). Guides Magic Reply and Morning Card drafts and is never overwritten automatically.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                Text("\(byteCount.formatted()) / \(maxBytes.formatted()) bytes")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(overLimit ? RelayColors.accentCoral : RelayColors.textSecondary)
                    .accessibilityIdentifier("knowledge.writingStyleByteCount")
            }

            TextEditor(text: $writingStyleDraft)
                .font(.system(size: 13.5, design: .monospaced))
                .foregroundStyle(RelayColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RelayColors.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(overLimit ? RelayColors.accentCoral : RelayColors.borderDefault, lineWidth: 1)
                )
                .accessibilityIdentifier("knowledge.writingStyleEditor")

            if let writingStyleError {
                Text(writingStyleError)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("knowledge.writingStyleError")
            } else if overLimit {
                Text("Exceeds the \(maxBytes.formatted())-byte ceiling by \((byteCount - maxBytes).formatted()) bytes. Shorten before saving; Relay never truncates your examples silently.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.accentCoral)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    showWritingStyleSheet = false
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button("Save Writing Style") {
                    saveWritingStyleSnapshot()
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .accessibilityIdentifier("knowledge.saveWritingStyle")
            }
        }
        .padding(22)
        .frame(width: 640, height: 480)
        .background(RelayTheme.background)
        .foregroundStyle(RelayTheme.ink)
        .relayPreferredAppearance()
    }

    private func generatedSource(for note: GeneratedKnowledgeNote) -> KnowledgeRecord? {
        store.knowledge.records.first {
            $0.sourcePath == note.sourcePath && GeneratedKnowledgeVault.name(for: $0) == note.id
        }
    }

    private func copyGeneratedNote(_ note: GeneratedKnowledgeNote) {
        guard let source = generatedSource(for: note), store.knowledge.revalidate(source, grants: store.grants) else {
            vaultStatus = "The generated note’s source changed or access was removed."
            return
        }
        let title = note.title.components(separatedBy: .controlCharacters).joined(separator: " ")
        noteEditor = .init(sourceCopy: .init(noteID: note.id, title: GeneratedKnowledgeVault.boundedUTF8(title, limit: 200),
                                             body: note.markdownBody) {
            store.knowledge.revalidate(source, grants: store.grants)
        })
    }

    private func sidebarNoteRow(_ node: SkyNode) -> some View {
        let isSelected = activeNode?.url == node.url
        return KnowledgeSidebarNoteRow(
            title: node.title,
            color: RelayColors.workbenchAccent,
            isSelected: isSelected
        ) {
            selectVaultNode(node)
        }
    }

    // MARK: - Selected-note & Overview Reader + Inline Markdown Editor

    @ViewBuilder
    private var vaultMiddleMarkdownPane: some View {
        if let node = activeNode, let graph = skyModel.graph {
            let overviewVaultNote: LocalMarkdownNote? = node.isRoot
                ? vaultNotes.first(where: { $0.url.lastPathComponent.caseInsensitiveCompare("Overview.md") == .orderedSame })
                : nil
            let effectiveNode: SkyNode = {
                if let overviewVaultNote,
                   let skyOverview = graph.nodes.first(where: { $0.url == overviewVaultNote.graphURL }) {
                    return skyOverview
                }
                return node
            }()
            let editableNote = overviewVaultNote ?? vaultNotes.first(where: { $0.graphURL == node.url })
            let generated = store.generatedKnowledge.notes.first(where: { $0.graphURL == node.url })
            let source = node.url.isFileURL
                ? (store.knowledge.records + store.nativeSources.liveSources.knowledgeRecords()).first(where: { $0.sourcePath == node.url.path })
                : nil
            let relationshipKind = KnowledgeRelationship.Kind.from(node.url)
            let neighbors = graph.linkedNodes(from: effectiveNode.url)
            let isInlineEditingCurrentNote = inlineEditingNote != nil && inlineEditingNote?.id == editableNote?.id
            let outgoingNodes = outgoingLinkedNodes(
                for: effectiveNode,
                bodyOverride: isInlineEditingCurrentNote ? inlineEditBody : nil,
                in: graph
            )
            let backlinkNodes = incomingBacklinkNodes(
                for: effectiveNode,
                outgoing: outgoingNodes,
                neighbors: neighbors,
                in: graph
            )

            if node.isRoot && overviewVaultNote == nil {
                deskOverview(graph: graph)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                        if !readerBackStack.isEmpty {
                            Button {
                                requestGuardedReaderAction(.goBack)
                            } label: {
                                Label("Back", systemImage: "chevron.left")
                            }
                            .buttonStyle(RelayBackButtonStyle())
                            .accessibilityIdentifier("knowledge.readerBack")
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            Text(editableNote != nil ? "YOUR NOTE" : generated != nil ? "GENERATED HIGHLIGHTS" : relationshipKind != nil ? "LINKED CONTEXT" : node.url.host == "group" ? "COLLECTION" : "SOURCE EXCERPT")
                                .font(.relayEyebrow)
                                .tracking(1.2)
                                .foregroundStyle(RelayColors.workbenchAccent)
                            if let relationshipKind {
                                RelayBadge(
                                    relationshipKind.title,
                                    icon: relationshipKind.icon,
                                    tint: RelayColors.accentGold,
                                    prominent: true
                                )
                            }
                            Text(node.isRoot ? "Overview" : node.url.host == "group" ? collectionTitle(node.title) : node.title)
                                .font(.relayWorkbenchTitle)
                                .foregroundStyle(RelayColors.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier(relationshipKind.map { "knowledge.linked.\($0.rawValue)" } ?? "knowledge.readerTitle")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack(spacing: 8) {
                        if let editing = inlineEditingNote, editing.id == editableNote?.id {
                            Button("Note details…") {
                                requestGuardedReaderAction(.openNoteSheet)
                            }
                            .accessibilityIdentifier("knowledge.openNoteSheet")

                            Button("Cancel") {
                                requestGuardedReaderAction(.selectNode(node, recordHistory: false))
                            }
                            .accessibilityIdentifier("knowledge.cancelInlineEdit")

                            Button("Save a copy…") {
                                checkpointInlineDraft()
                                guard draftRecoveryError == nil,
                                      let checkpoint = recoveryDrafts.first(where: { $0.graphURL == editing.graphURL }) else { return }
                                inlineEditingNote = nil
                                recoveryDraft = checkpoint
                            }
                            .disabled(!hasUnsavedInlineEdits)
                            .accessibilityIdentifier("knowledge.recoverInlineDraftCopy")

                            Button("Save") {
                                _ = saveInlineEdits()
                            }
                            .buttonStyle(RelayPrimaryButtonStyle())
                            .accessibilityIdentifier("knowledge.saveInlineEdit")
                        } else if relationshipKind != nil,
                                  let entity = CrossSourceKnowledge.entities(in: store.knowledge.records).first(where: { $0.id == node.url }),
                                  (2...CrossSourceKnowledge.maximumSources).contains(entity.sourcePaths.count) {
                            Button("Source brief…") { consolidationEntity = entity }
                                .disabled(store.isRunning || store.voice.isBusy || !store.workspaceActionsReady)
                                .accessibilityIdentifier("knowledge.consolidateEntity")
                        } else if let generated {
                            Button("Chat with Note", systemImage: "bubble.left.and.text.bubble.right") {
                                chatWithNote(title: generated.title, markdownBody: generated.markdownBody)
                            }
                            .accessibilityIdentifier("knowledge.chatWithNote")
                            Button("Make editable copy…") { copyGeneratedNote(generated) }
                                .accessibilityIdentifier("knowledge.copyGeneratedNote")
                        } else if let note = editableNote {
                            Button("Chat with Note", systemImage: "bubble.left.and.text.bubble.right") {
                                requestGuardedReaderAction(.chatWithEditableNote(note.graphURL))
                            }
                            .accessibilityIdentifier("knowledge.chatWithNote")
                            Button("Edit Note", systemImage: "square.and.pencil") {
                                startInlineEditing(note)
                            }
                            .accessibilityIdentifier("knowledge.editNote")
                            if !node.isRoot {
                                Menu {
                                Button(role: .destructive) {
                                    notePendingDeletion = note
                                } label: {
                                    Label("Move to Trash…", systemImage: "trash")
                                        .foregroundStyle(RelayColors.accentCoral)
                                }
                                .foregroundStyle(RelayColors.accentCoral)
                                .tint(RelayColors.accentCoral)
                                .accessibilityIdentifier("knowledge.deleteNote")
                                } label: {
                                    Label("Note actions", systemImage: "ellipsis")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        } else if let source {
                            Button("Chat with Note", systemImage: "bubble.left.and.text.bubble.right") {
                                chatWithNote(title: source.title, markdownBody: source.text)
                            }
                            .accessibilityIdentifier("knowledge.chatWithNote")
                            Button("Export source note…") { exportSourceNote(source) }
                                .accessibilityIdentifier("knowledge.exportSourceNote")
                        }
                        }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 20)

                    Rectangle().fill(RelayColors.borderSubtle).frame(height: 1).padding(.horizontal, 32)

                    if let editing = inlineEditingNote, editing.id == editableNote?.id {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Note title", text: inlineTitleBinding)
                                .textFieldStyle(.plain)
                                .font(.relayHeadline)
                                .relayTextField(cornerRadius: 10)
                                .accessibilityIdentifier("knowledge.inlineTitle")

                            TextEditor(text: inlineBodyBinding)
                                .font(.relayMono)
                                .foregroundStyle(RelayColors.textPrimary)
                                .scrollContentBackground(.hidden)
                                .padding(12)
                                .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(RelayColors.borderDefault, lineWidth: 1)
                                )
                                .accessibilityIdentifier("knowledge.inlineBodyEditor")

                            Text(draftRecoveryError ?? "Unsaved edits are checkpointed on this Mac. Save updates the note.")
                                .font(.relayCaption)
                                .foregroundStyle(draftRecoveryError == nil ? RelayColors.textMuted : RelayColors.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("knowledge.inlineDraftStatus")

                            VaultWikilinkAutocompleteBar(
                                text: inlineBodyBinding,
                                candidates: VaultWikilinkAutocomplete.candidates(from: graph, vaultNotes: vaultNotes),
                                excludingTitle: inlineEditTitle
                            )

                            if relationshipKind == nil && (!outgoingNodes.isEmpty || !backlinkNodes.isEmpty) {
                                linkedNotesAndBacklinksCard(
                                    outgoing: outgoingNodes,
                                    backlinks: backlinkNodes
                                )
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                VStack(alignment: .leading, spacing: 14) {
                                        if let coverage = source?.coverageNote {
                                            Text(coverage)
                                                .font(.relayCaption)
                                                .foregroundStyle(RelayColors.textSecondary)
                                                .textSelection(.enabled)
                                        }
                                        if let generated {
                                            generatedReader(generated)
                                        } else if relationshipKind != nil {
                                            relationshipReader(neighbors: neighbors)
                                        } else {
                                            renderedMarkdownView(effectiveNode, graph: graph, neighbors: neighbors)
                                        }
                                    }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 24)

                                if relationshipKind == nil && (!outgoingNodes.isEmpty || !backlinkNodes.isEmpty) {
                                    linkedNotesAndBacklinksCard(
                                        outgoing: outgoingNodes,
                                        backlinks: backlinkNodes
                                    )
                                }
                            }
                            .padding(.horizontal, 28).padding(.bottom, 24)
                            .frame(maxWidth: RelayTheme.readingMaxWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedNotesAndBacklinksCard(
        outgoing: [SkyNode],
        backlinks: [SkyNode]
    ) -> some View {
        if !outgoing.isEmpty || !backlinks.isEmpty {
            RelaySurfaceCard(padding: 18, cornerRadius: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    RelayMonoCaps("LINKED NOTES & SOURCES", size: 10, tracking: 1.2, color: RelayColors.textMuted)

                    if !outgoing.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Links in this note")
                                .font(.relayCaptionStrong)
                                .foregroundStyle(RelayColors.textSecondary)
                            FlowLayoutWikilinks(nodes: outgoing) { targetNode in
                                selectVaultNode(targetNode)
                            }
                        }
                    }

                    if !outgoing.isEmpty && !backlinks.isEmpty {
                        Rectangle()
                            .fill(RelayColors.borderSubtle)
                            .frame(height: 1)
                    }

                    if !backlinks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Referenced by (Backlinks)")
                                .font(.relayCaptionStrong)
                                .foregroundStyle(RelayColors.textSecondary)
                            FlowLayoutWikilinks(nodes: backlinks) { targetNode in
                                selectVaultNode(targetNode)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func outgoingLinkedNodes(
        for node: SkyNode,
        bodyOverride: String? = nil,
        in graph: SkyGraph
    ) -> [SkyNode] {
        let candidates = graph.nodes.filter { $0.url.host != "group" && !$0.isRoot && $0.url != node.url }
        let body = bodyOverride ?? node.markdownBody
        var seen = Set<URL>()
        var result: [SkyNode] = []
        for line in KnowledgeWikiLink.lines(in: body) where line.allowsLinks {
            for link in KnowledgeWikiLink.inLine(line.text) {
                if let target = graph.linkedNode(for: link, among: candidates)
                    ?? candidates.first(where: { $0.title.caseInsensitiveCompare(link.target) == .orderedSame }) {
                    if seen.insert(target.url).inserted {
                        result.append(target)
                    }
                }
            }
        }
        return result
    }

    private func incomingBacklinkNodes(
        for node: SkyNode,
        outgoing: [SkyNode],
        neighbors: [SkyNode],
        in graph: SkyGraph
    ) -> [SkyNode] {
        let outgoingURLs = Set(outgoing.map(\.url))
        var seen = Set<URL>()
        var result: [SkyNode] = []
        let nonGroupNeighbors = neighbors.filter { $0.url.host != "group" && !$0.isRoot && $0.url != node.url }

        for candidate in graph.nodes where candidate.url.host != "group" && !candidate.isRoot && candidate.url != node.url {
            let candidateOutgoing = outgoingLinkedNodes(for: candidate, in: graph)
            if candidateOutgoing.contains(where: { $0.url == node.url }) {
                if seen.insert(candidate.url).inserted {
                    result.append(candidate)
                }
            }
        }

        for neighbor in nonGroupNeighbors where !outgoingURLs.contains(neighbor.url) {
            if seen.insert(neighbor.url).inserted {
                result.append(neighbor)
            }
        }
        return result
    }

    private func relationshipReader(neighbors: [SkyNode]) -> some View {
        let documents = neighbors.filter { $0.url.host != "group" }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 10) {
            Text(documents.count == 1 ? "1 linked document" : "\(documents.count) linked documents")
                .font(.relayCaptionStrong)
                .foregroundStyle(RelayColors.textSecondary)
            ForEach(documents) { document in
                Button {
                    selectVaultNode(document)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: document.url.isFileURL ? "doc.text" : "note.text")
                            .font(.relayCallout)
                            .foregroundStyle(RelayColors.accentGold)
                        Text(document.title)
                            .font(.relayBodyStrong)
                            .foregroundStyle(RelayColors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.relayMicro)
                            .foregroundStyle(RelayColors.textMuted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(RelayPressStyle())
            }
        }
    }

    private func generatedReader(_ note: GeneratedKnowledgeNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relay’s local model selected verbatim excerpts from the indexed text.")
                .font(.relayCallout)
                .foregroundStyle(RelayColors.textSecondary)
            if let source = skyModel.graph?.nodes.first(where: { $0.url == note.sourceURL }) {
                Button("Read source: " + note.sourceTitle) { selectVaultNode(source) }
                    .buttonStyle(RelaySecondaryButtonStyle())
            }
            DisclosureGroup("Source details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.sourcePath)
                    Text("Modified: " + note.modifiedAt.formatted())
                    Text("SHA-256: " + note.sourceHash)
                    Text(note.coverage)
                }
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textSecondary)
                .textSelection(.enabled)
                .padding(.top, 6)
            }
            ForEach(Array(note.highlights.enumerated()), id: \.offset) { _, excerpt in
                Text(excerpt)
                    .font(.relayBody)
                    .foregroundStyle(RelayColors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
            }
        }
    }

    private enum VaultMarkdownBlock {
        case spacer
        case heading(level: Int, text: String)
        case bullet(text: String)
        case numbered(prefix: String, text: String)
        case blockquote(text: String)
        case codeBlock(language: String, code: String)
        case table(rows: [[String]])
        case paragraph(text: String, allowsLinks: Bool)
    }

    private func parseVaultMarkdownBlocks(_ rawLines: ArraySlice<(text: String, allowsLinks: Bool)>) -> [VaultMarkdownBlock] {
        let items = Array(rawLines)
        var blocks: [VaultMarkdownBlock] = []
        var idx = 0

        while idx < items.count {
            let line = items[idx]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            // 1. Fenced code block (` ```lang ... ``` ` or `~~~`)
            if !line.allowsLinks,
               let firstChar = trimmed.first,
               (firstChar == "`" || firstChar == "~") {
                let fenceLength = trimmed.prefix(while: { $0 == firstChar }).count
                if fenceLength >= 3 {
                    let language = String(trimmed.dropFirst(fenceLength)).trimmingCharacters(in: .whitespaces)
                    var codeLines: [String] = []
                    idx += 1
                    while idx < items.count {
                        let inner = items[idx]
                        let innerTrimmed = inner.text.trimmingCharacters(in: .whitespaces)
                        let closeCount = innerTrimmed.prefix(while: { $0 == firstChar }).count
                        if closeCount >= fenceLength && innerTrimmed.dropFirst(closeCount).allSatisfy(\.isWhitespace) {
                            idx += 1
                            break
                        }
                        codeLines.append(inner.text)
                        idx += 1
                    }
                    blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
                    continue
                }
            }

            // 2. Markdown table (`| col | col |`)
            if line.allowsLinks, Self.isMarkdownTableRow(trimmed) {
                var tableRows: [[String]] = []
                while idx < items.count {
                    let candidate = items[idx]
                    let candidateTrimmed = candidate.text.trimmingCharacters(in: .whitespaces)
                    guard candidate.allowsLinks, Self.isMarkdownTableRow(candidateTrimmed) else { break }
                    if !Self.isMarkdownTableSeparatorRow(candidateTrimmed) {
                        let cells = Self.parseMarkdownTableCells(candidateTrimmed)
                        if !cells.isEmpty {
                            tableRows.append(cells)
                        }
                    }
                    idx += 1
                }
                if !tableRows.isEmpty {
                    blocks.append(.table(rows: tableRows))
                }
                continue
            }

            if trimmed.isEmpty {
                blocks.append(.spacer)
            } else if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") {
                // HTML comment: omit
            } else if line.allowsLinks, trimmed.hasPrefix("# ") {
                blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
            } else if line.allowsLinks, trimmed.hasPrefix("## ") {
                blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
            } else if line.allowsLinks, trimmed.hasPrefix("### ") {
                blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
            } else if line.allowsLinks, trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(text: String(trimmed.dropFirst(2))))
            } else if line.allowsLinks, let numbered = Self.parseNumberedListItem(trimmed) {
                blocks.append(.numbered(prefix: numbered.prefix, text: numbered.body))
            } else if line.allowsLinks, trimmed.hasPrefix(">") {
                let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(.blockquote(text: content))
            } else {
                blocks.append(.paragraph(text: trimmed, allowsLinks: line.allowsLinks))
            }
            idx += 1
        }
        return blocks
    }

    private static func parseNumberedListItem(_ trimmed: String) -> (prefix: String, body: String)? {
        let digits = trimmed.prefix(while: \.isWholeNumber)
        guard !digits.isEmpty else { return nil }
        let remainder = trimmed.dropFirst(digits.count)
        guard remainder.hasPrefix(". ") else { return nil }
        return ("\(digits).", String(remainder.dropFirst(2)))
    }

    private static func isMarkdownTableRow(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("|") else { return false }
        return trimmed.dropFirst().contains("|")
    }

    private static func isMarkdownTableSeparatorRow(_ trimmed: String) -> Bool {
        let cells = parseMarkdownTableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.trimmingCharacters(in: .whitespaces)
            return !stripped.isEmpty && stripped.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseMarkdownTableCells(_ trimmed: String) -> [String] {
        var inner = trimmed
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func renderedMarkdownView(_ node: SkyNode, graph: SkyGraph, neighbors: [SkyNode]) -> some View {
        let allLines = KnowledgeWikiLink.lines(in: node.markdownBody)
        let header = node.isRoot ? "# Your knowledge" : "# \(node.title)"
        let lines = allLines.first?.text == header
            ? allLines.dropFirst().drop(while: { $0.text.trimmingCharacters(in: .whitespaces).isEmpty })
            : allLines[...]
        let blocks = parseVaultMarkdownBlocks(lines)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .spacer:
                    Spacer().frame(height: 4)
                case .heading(let level, let text):
                    if level == 1 {
                        wikilinkHighlightedText(text, graph: graph, neighbors: neighbors)
                            .font(.relayLargeTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                            .padding(.bottom, 4)
                    } else if level == 2 {
                        wikilinkHighlightedText(text, graph: graph, neighbors: neighbors)
                            .font(.relayHeadline)
                            .foregroundStyle(RelayColors.accentGold)
                            .padding(.top, 4)
                    } else {
                        wikilinkHighlightedText(text, graph: graph, neighbors: neighbors)
                            .font(.relaySubheadline.weight(.semibold))
                            .foregroundStyle(RelayColors.textBright)
                            .padding(.top, 2)
                    }
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(RelayColors.accentAmethyst)
                        wikilinkHighlightedText(text, graph: graph, neighbors: neighbors)
                    }
                case .numbered(let prefix, let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text(prefix)
                            .font(.relayMonoSmall)
                            .foregroundStyle(RelayColors.accentGold)
                            .frame(minWidth: 18, alignment: .trailing)
                        wikilinkHighlightedText(text, graph: graph, neighbors: neighbors)
                    }
                case .blockquote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(RelayColors.accentGold.opacity(0.75))
                            .frame(width: 3)
                        wikilinkHighlightedText(text, graph: graph, neighbors: neighbors)
                            .italic()
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                case .codeBlock(let language, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? "code" : language)
                                .font(.relayMonoSmall)
                                .foregroundStyle(RelayColors.textMuted)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                vaultStatus = "Copied code block."
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.relayMicro)
                            }
                            .buttonStyle(RelayGhostButtonStyle())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RelayColors.surface.opacity(0.45))

                        Rectangle()
                            .fill(RelayColors.borderSubtle)
                            .frame(height: 1)

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(verbatim: code)
                                .font(.relayMono)
                                .foregroundStyle(RelayColors.textPrimary)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(RelayColors.pitch, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
                case .table(let rows):
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, cells in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                    wikilinkHighlightedText(cell, graph: graph, neighbors: neighbors)
                                        .font(rowIdx == 0 ? .relayCaptionStrong : .relayCaption)
                                        .foregroundStyle(rowIdx == 0 ? RelayColors.textPrimary : RelayColors.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(rowIdx == 0 ? RelayColors.pitch.opacity(0.6) : Color.clear)

                            if rowIdx < rows.count - 1 {
                                Rectangle()
                                    .fill(RelayColors.borderSubtle)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
                case .paragraph(let text, let allowsLinks):
                    wikilinkHighlightedText(text, graph: graph, neighbors: neighbors, allowsLinks: allowsLinks)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let target = neighbors.first(where: { $0.url == url }) else { return .discarded }
            selectVaultNode(target)
            return .handled
        })
    }

    private var emptyKnowledgeState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(RelayColors.textSecondary)
                .accessibilityHidden(true)

            Text("No notes yet")
                .font(.relayLargeTitle)
                .foregroundStyle(RelayColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Create a note, or add files and folders to make them searchable on this Mac.")
                .font(.relayBody)
                .foregroundStyle(RelayColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                if store.grants.isEmpty {
                    Button("Choose files…", systemImage: "doc.badge.plus") { store.chooseFiles() }
                    Button("Choose folder…", systemImage: "folder.badge.plus") { store.chooseFolder() }
                } else {
                    Button(store.knowledge.isIndexing ? "Indexing…" : "Index selected sources") {
                        Task { await store.knowledge.index(grants: store.grants) }
                    }
                    .disabled(store.knowledge.isIndexing)
                }
            }
            .buttonStyle(RelaySecondaryButtonStyle())
            if !store.grants.isEmpty {
                Text(store.knowledge.status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(RelayTheme.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inlineMarkdownSegment(_ segment: Substring, allowsInlineMarkdown: Bool) -> AttributedString {
        let raw = String(segment)
        guard allowsInlineMarkdown, !raw.isEmpty,
              (raw.contains("*") || raw.contains("`") || raw.contains("_") || raw.contains("~")) else {
            return AttributedString(raw)
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }

    private func wikilinkHighlightedText(_ line: String, graph: SkyGraph, neighbors: [SkyNode], allowsLinks: Bool = true) -> some View {
        var text = AttributedString()
        var start = line.startIndex
        if allowsLinks {
            for link in KnowledgeWikiLink.inLine(line) {
                text.append(inlineMarkdownSegment(line[start..<link.range.lowerBound], allowsInlineMarkdown: true))
                var label = AttributedString(link.label)
                if let target = graph.linkedNode(for: link, among: neighbors) {
                    label.link = target.url
                    label.foregroundColor = RelayColors.knowledgeLink
                    label.underlineStyle = .single
                }
                text.append(label)
                start = link.range.upperBound
            }
        }
        text.append(inlineMarkdownSegment(line[start...], allowsInlineMarkdown: allowsLinks))
        return Text(text)
            .font(.relayBody)
            .foregroundStyle(RelayColors.textSecondary)
            .lineSpacing(5)
            .textSelection(.enabled)
    }

    // MARK: - 2. Settings Knowledge Pane (`SettingsView` -> `Knowledge` Tab)

    private var settingsKnowledgeBody: some View {
        settingsOverviewWorkspace
    }

    private var settingsOverviewWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                let sourceCount = store.grants.count
                let fileCount = store.knowledge.records.count
                HStack {
                    Label("\(sourceCount) authorized \(sourceCount == 1 ? "source" : "sources") · \(fileCount) indexed \(fileCount == 1 ? "file" : "files")", systemImage: "doc.text.magnifyingglass")
                        .font(.relayHeadline)
                        .foregroundStyle(RelayColors.textPrimary)
                    Spacer()
                    RelayMonoCaps(text: "LOCAL INDEX", color: RelayColors.accentEmerald, size: 10)
                }
                Text("Indexes authorized local files and SiYuan workspaces in place (up to 200 files / 10 MB, or 1,000 SiYuan documents). Your original files are never copied or modified.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineSpacing(3)

                HStack(spacing: 10) {
                    if store.knowledge.isIndexing {
                        ProgressView().controlSize(.small)
                        Button("Cancel indexing") { store.knowledge.cancel() }
                    } else {
                        Button("Index selected sources") {
                            Task {
                                await store.knowledge.index(grants: store.grants)
                                skyModel.load(records: store.knowledge.records, entrance: false)
                            }
                        }
                        .disabled(store.grants.isEmpty)
                    }
                    Button("Refresh sources") {
                        store.knowledge.purgeStale(grants: store.grants)
                        store.suggestions.purge(records: store.knowledge.records)
                        skyModel.load(records: store.knowledge.records, entrance: false)
                    }
                    .disabled(store.knowledge.isIndexing)

                    Spacer()

                    if !store.knowledge.records.isEmpty {
                        Button("Export Markdown…") { export() }
                            .disabled(store.knowledge.isIndexing)
                        Button("Clear Index") {
                            showClearIndexConfirmation = true
                        }
                        .disabled(store.knowledge.isIndexing)
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Text(store.knowledge.status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)

                Divider().overlay(RelayTheme.line)

                SemanticSearchView(search: store.knowledgeSearch, taskBusy: store.isRunning)

                if !store.knowledge.records.isEmpty {
                    Divider().overlay(RelayTheme.line)
                    VStack(alignment: .leading, spacing: 8) {
                        RelayMonoCaps(text: "INDEXED LOCAL FILES", color: RelayColors.textSecondary, size: 10)
                        if store.knowledge.records.count > 8 {
                            Button(showAllIndexedFiles ? "Show fewer indexed files" : "Show all \(store.knowledge.records.count) indexed files") {
                                showAllIndexedFiles.toggle()
                            }
                            .buttonStyle(RelayGhostButtonStyle())
                        }
                        ForEach(showAllIndexedFiles ? store.knowledge.records : Array(store.knowledge.records.prefix(8))) { record in
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.title)
                                        .font(.relayBodyStrong)
                                        .foregroundStyle(RelayColors.textPrimary)
                                    Text(record.sourcePath)
                                        .font(.relayCaption)
                                        .foregroundStyle(RelayColors.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("Forget") {
                                    store.invalidateDerivedContext(reason: "Indexed source forgotten.")
                                    store.knowledge.removeSource(path: record.sourcePath)
                                    skyModel.load(records: store.knowledge.records, entrance: false)
                                }
                                .buttonStyle(RelaySecondaryButtonStyle())
                            }
                            .padding(10)
                            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .padding(20)
            .relayGlassCard(cornerRadius: RelayTheme.radius)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RelayIconBadge(icon: "lock.shield.fill", color: RelayColors.accentAmethyst, size: 38, iconSize: 17)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vault Sharing & Encrypted Archives")
                            .font(.relayHeadline)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Share selected notes locally via MCP, export encrypted `.relaynotes` archives, or sync through an encrypted mirror.")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    Spacer()
                }
                LocalKnowledgeMCPSettingsView(server: store.knowledgeSharing)
                PortableKnowledgeSharingView()
                HostedKnowledgeMirrorSettingsView(mirror: .shared)
            }
            .padding(20)
            .relayGlassCard(cornerRadius: RelayTheme.radius)

            if let exportError {
                Text(exportError)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.accentCoral)
            }
        }
    }

    private func chatWithNote(title: String, markdownBody: String) {
        let trimmed = markdownBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = GeneratedKnowledgeVault.boundedUTF8(trimmed, limit: 2_000)
        store.draft = "Using my note “\(title)”:\n\n\(excerpt)\n\n"
        onOpenWorkspace?()
        NotificationCenter.default.post(name: Notification.Name("relay.switchToWorkspace"), object: nil)
        if isSettingsPane {
            dismiss()
        } else if let url = URL(string: "relay://workspace") {
            NSWorkspace.shared.open(url)
        }
    }

    private func deleteVaultNote(_ note: LocalMarkdownNote) {
        do {
            _ = try KnowledgeVaultManager.shared.trashNote(note)
            if inlineEditingNote?.id == note.id {
                inlineEditingNote = nil
            }
            readerBackStack.removeAll { $0 == note.graphURL }
            if selectedNodeURL == note.graphURL {
                selectedNodeURL = nil
            }
            reloadVaultNotes()
            vaultStatus = "Moved “\(note.title)” to Trash. Restore it from Library actions → Recently deleted notes."
        } catch {
            vaultStatus = "Could not move the note to Trash: " + error.localizedDescription
        }
    }

    private func createVaultFolder() {
        do {
            let folder = try KnowledgeVaultManager.shared.createFolder(named: newFolderName)
            expandedDomains.insert(folder.graphDomain)
            reloadVaultNotes()
            vaultStatus = "Created “" + folder.name + "”. Choose it when you create a note."
        } catch {
            vaultStatus = "Could not create the folder: " + error.localizedDescription
        }
    }

    private func reloadVaultNotes(entrance: Bool = false) {
        do {
            let folders = try KnowledgeVaultManager.shared.loadFolders()
            let loaded = try KnowledgeVaultManager.shared.loadNotes()
            if let editing = inlineEditingNote, !loaded.contains(where: { $0.graphURL == editing.graphURL }) {
                checkpointInlineDraft()
                if draftRecoveryError == nil { inlineEditingNote = nil }
            }
            vaultLoadError = nil
            guard loaded != vaultNotes || folders != vaultFolders || entrance ||
                  skyModel.graph?.nodes.isEmpty != false else { return }
            expandedDomains.formUnion(Set(folders.map(\.graphDomain)).subtracting(vaultFolders.map(\.graphDomain)))
            vaultFolders = folders
            vaultNotes = loaded
        } catch {
            vaultNotes = []
            vaultFolders = []
            vaultLoadError = "Could not open local notes: " + error.localizedDescription
        }
        updateVaultGraph(entrance: entrance)
    }

    private func updateVaultGraph(entrance: Bool = false) {
        guard !isSettingsPane else { return }
        let combinedRecords = store.knowledge.records + store.nativeSources.liveSources.knowledgeRecords()
        skyModel.load(records: combinedRecords, customNotes: vaultNotes.graphNotes,
                      generatedNotes: store.generatedKnowledge.notes, folders: vaultFolders, entrance: entrance)
    }

    private func exportSourceNote(_ record: KnowledgeRecord) {
        let panel = NSSavePanel()
        panel.title = "Export indexed source as Markdown"
        panel.message = "This snapshot includes an indexed excerpt and the source path. Choose a private folder."
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Relay source note.md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        store.knowledge.purgeStale(grants: store.grants)
        guard store.knowledge.records.contains(record) else {
            vaultStatus = "The source changed or access was removed. Reindex before exporting."
            return
        }
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !store.knowledge.records.contains(where: { $0.sourcePath == target.path }) else {
            vaultStatus = "Choose a separate file for the exported note."
            return
        }
        do {
            try LocalPrivateFileWriter.write(data: IndexedSourceMarkdown.data(for: record), to: destination,
                                             maximumBytes: 512 * 1_024)
            vaultStatus = "Exported indexed excerpt to " + destination.lastPathComponent + "."
        } catch {
            vaultStatus = "Could not export the source note: " + error.localizedDescription
        }
    }

    private func export() {
        store.knowledge.purgeStale(grants: store.grants)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Relay knowledge.md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        store.knowledge.purgeStale(grants: store.grants)
        do { try store.knowledge.exportMarkdown().write(to: destination, atomically: true, encoding: .utf8); exportError = nil }
        catch { exportError = "Could not export the index: \(error.localizedDescription)" }
    }
}

private struct FlowLayoutWikilinks: View {
    let nodes: [SkyNode]
    let onSelect: (SkyNode) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(nodes) { node in
                Button {
                    onSelect(node)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(node.title)
                            .font(.relayMicro)
                            .lineLimit(1)
                    }
                    .foregroundStyle(RelayColors.knowledgeLink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RelayColors.knowledgeLink.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(RelayColors.knowledgeLink.opacity(0.28), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(RelayPressStyle())
            }
        }
    }
}

private struct KnowledgeSidebarOverviewRow: View {
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "circle.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? RelayColors.workbenchAccent : RelayColors.textSecondary)
                Text("Overview")
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textBright)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .background(
                isSelected ? RelayColors.activeFill : (isHovered ? RelayColors.hoverFill : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
    }
}

private struct KnowledgeSidebarFolderRow: View {
    let title: String
    let count: Int
    let color: Color
    let isExpanded: Bool
    let isSelected: Bool
    let relationshipKind: KnowledgeRelationship.Kind?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(isExpanded ? RelayColors.textPrimary : RelayColors.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: relationshipKind?.icon ?? (isExpanded ? "folder.fill" : "folder"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color.opacity(0.95))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RelayColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.relayMonoSmall)
                    .foregroundStyle(RelayColors.textMuted)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .background(
                isSelected ? RelayColors.activeFill : (isHovered ? RelayColors.hoverFill : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .accessibilityLabel(relationshipKind == nil ? "\(title) folder, \(count) \(count == 1 ? "item" : "items")" : "\(title), \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

private struct KnowledgeSidebarNoteRow: View {
    let title: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color.opacity(isSelected ? 1.0 : 0.65))
                    .frame(width: 5.5, height: 5.5)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? RelayColors.textPrimary : (isHovered ? RelayColors.textBright : RelayColors.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, 26)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .background(
                isSelected ? RelayColors.activeFill : (isHovered ? RelayColors.hoverFill : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
    }
}

extension CalendarSelectionView {
    init(calendar: CalendarSource, taskBusy: Bool = false) {
        self.init(source: calendar)
    }
}
