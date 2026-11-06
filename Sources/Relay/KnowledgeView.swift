import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeView: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Bindable var store: AssistantStore
    var startInConstellation: Bool = false
    var isSettingsPane: Bool = false

    @StateObject private var skyModel = NightSkyModel()
    @State private var fullGalaxyMode: Bool = false
    @State private var expandedDomains: Set<String> = ["Indexed Sources", GeneratedKnowledgeNote.domain, "Your Notes"]
    @State private var selectedNodeURL: URL? = nil
    @State private var vaultNotes: [LocalMarkdownNote] = []
    @State private var vaultFolders: [LocalMarkdownFolder] = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var noteEditor: VaultNoteEditor.Request?
    @State private var vaultStatus: String?
    @State private var vaultLoadError: String?
    @State private var vaultFilter = ""

    private var hasVaultContent: Bool { !store.knowledge.records.isEmpty || !vaultNotes.isEmpty || !vaultFolders.isEmpty }

    @State private var query = ""
    @State private var results: [KnowledgeSearchResult] = []
    @State private var exportError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchError: String?
    @State private var searchPending = false

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
        .foregroundStyle(.white)
        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentGold))
        .onChange(of: store.knowledge.records) { _, _ in
            store.knowledgeSearch.invalidateSources()
            store.suggestions.purge(records: store.knowledge.records)
            updateVaultGraph()
            refreshSearch()
        }
        .onChange(of: store.generatedKnowledge.notes) { _, notes in
            if let copy = noteEditor?.sourceCopy, !notes.contains(where: { $0.id == copy.noteID }) {
                noteEditor = nil
                vaultStatus = "The source changed or access was removed before the editable copy was saved."
            }
            updateVaultGraph()
        }
        .onChange(of: store.grants.map { $0.id }) { _, _ in refreshSearch() }
        .onChange(of: store.knowledgeSearch.state) { _, _ in refreshSearch() }
        .onAppear {
            store.knowledge.purgeStale(grants: store.grants)
            store.suggestions.purge(records: store.knowledge.records)
            if !isSettingsPane {
                store.generatedKnowledge.reconcile(records: store.knowledge.records)
                reloadVaultNotes(entrance: !reducedMotion)
            }
            refreshSearch()
        }
        .onDisappear { searchTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.knowledge.purgeStale(grants: store.grants)
            store.suggestions.purge(records: store.knowledge.records)
            if !isSettingsPane {
                store.generatedKnowledge.reconcile(records: store.knowledge.records)
                reloadVaultNotes()
            }
            refreshSearch()
        }
        .sheet(item: $noteEditor) { request in
            VaultNoteEditor(request: request, folders: vaultFolders) { saved in
                reloadVaultNotes()
                selectedNodeURL = saved.graphURL
                fullGalaxyMode = false
                skyModel.highlight(saved.graphURL)
            }
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
    }

    // MARK: - 1. Main Workspace Knowledge Vault (1:1 Match with Sentient OS `readme_knowledge.jpg`)

    private var workspaceKnowledgeVaultBody: some View {
        VStack(spacing: 0) {
            // Top Chrome Bar inside the Knowledge Vault Frame
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    RelayIconBadge(icon: "books.vertical.fill", color: RelayColors.accentGold, size: 24, iconSize: 11)
                    Text("Knowledge Vault")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                }

                Spacer()

                Text("\(store.knowledge.records.count) indexed · \(vaultNotes.count) notes")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

                Button("New note", systemImage: "square.and.pencil") {
                    noteEditor = .init()
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .accessibilityIdentifier("knowledge.newNote")

                Button("New folder", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    showNewFolder = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(RelaySecondaryButtonStyle())
                .help("New folder")
                .accessibilityIdentifier("knowledge.newFolder")

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        fullGalaxyMode.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: fullGalaxyMode ? "sidebar.left" : "sparkles")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(fullGalaxyMode ? "Split View" : "Full Constellation")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(RelayColors.accentGold)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(RelayColors.accentGold.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(RelayColors.accentGold.opacity(0.28), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RelayPressStyle())
                .disabled(!hasVaultContent)
            }
            .padding(.horizontal, 20)
            .frame(height: 46)
            .background(Color(red: 0.065, green: 0.068, blue: 0.082))

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            if !hasVaultContent {
                emptyKnowledgeState
            } else if fullGalaxyMode {
                NightSkyView(model: skyModel, showsHUD: true) { clickedNode in
                    selectVaultNode(clickedNode)
                    withAnimation(.easeInOut(duration: 0.24)) {
                        fullGalaxyMode = false
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        vaultLeftSidebar
                            .frame(width: geometry.size.width >= 900 ? 215 : 180)
                            .frame(maxHeight: .infinity)
                            .background(Color(red: 0.052, green: 0.054, blue: 0.068))
                        Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                        vaultMiddleMarkdownPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(red: 0.042, green: 0.044, blue: 0.056))
                        if geometry.size.width >= 900 {
                            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                            NightSkyView(model: skyModel, showsHUD: false) { clickedNode in
                                selectVaultNode(clickedNode)
                            }
                            .frame(width: max(260, geometry.size.width * 0.34))
                            .frame(maxHeight: .infinity)
                            .background(Color(red: 0.038, green: 0.040, blue: 0.052))
                        }
                    }
                }
            }
            if let vaultStatus = vaultLoadError ?? vaultStatus {
                Text(vaultStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .background(RelayColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
    }

    // MARK: - Left Column: `Your knowledge` + `◎ Overview` + Collapsible Domain Folders

    private var vaultLeftSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                RelayMonoCaps("YOUR KNOWLEDGE", size: 9.5, tracking: 1.8, color: RelayColors.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                generatedKnowledgeControls

                TextField("Filter titles", text: $vaultFilter)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10)
                    .accessibilityIdentifier("knowledge.filterTitles")

                if let graph = skyModel.graph {
                    // Overview Row (`◎ Overview`)
                    if let rootIdx = graph.rootIndex {
                        let rootNode = graph.nodes[rootIdx]
                        let isOverviewSelected = activeNode?.url == rootNode.url
                        KnowledgeSidebarOverviewRow(isSelected: isOverviewSelected) {
                            selectedNodeURL = rootNode.url
                            skyModel.highlight(rootNode.url)
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    }

                    // Domain Folders (`› 📁 Indexed Sources`, etc.)
                    ForEach(Array(graph.domains.enumerated()), id: \.offset) { dIdx, domainName in
                        let isExpanded = expandedDomains.contains(domainName)
                        let domainNodes = graph.nodes.filter {
                            !$0.isRoot && $0.domain == dIdx && $0.url.host != "group" &&
                                (vaultFilter.isEmpty || $0.title.localizedStandardContains(vaultFilter))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            KnowledgeSidebarFolderRow(
                                title: LocalMarkdownFolder.displayName(for: domainName),
                                count: domainNodes.count,
                                color: SkyRenderer.domainColor(dIdx),
                                isExpanded: isExpanded
                            ) {
                                let willExpand = !expandedDomains.contains(domainName)
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
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
                        .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var generatedKnowledgeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            Text(store.actionsReady ? store.generatedKnowledge.status : "Load a local model to generate highlights.")
                .font(.system(size: 11))
                .foregroundStyle(RelayColors.textSecondary)
                .accessibilityIdentifier("knowledge.generationStatus")
        }
        .buttonStyle(RelaySecondaryButtonStyle())
        .padding(.horizontal, 10)
        .padding(.bottom, 5)
    }

    private func selectVaultNode(_ node: SkyNode) {
        if node.url.host == "generated" {
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
        selectedNodeURL = node.url
        skyModel.highlight(node.url)
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
            color: SkyRenderer.domainColor(node.domain),
            isSelected: isSelected
        ) {
            selectVaultNode(node)
        }
    }

    // MARK: - Read-only selected-source reader

    @ViewBuilder
    private var vaultMiddleMarkdownPane: some View {
        if let node = activeNode, let graph = skyModel.graph {
            let generated = store.generatedKnowledge.notes.first(where: { $0.graphURL == node.url })
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(node.isRoot ? "Overview" : node.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RelayColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let generated {
                        Button("Make editable copy…") { copyGeneratedNote(generated) }
                            .accessibilityIdentifier("knowledge.copyGeneratedNote")
                    } else if let note = vaultNotes.first(where: { $0.graphURL == node.url }) {
                        Button("Edit note") { noteEditor = .init(note: note) }
                            .accessibilityIdentifier("knowledge.editNote")
                    } else if node.url.isFileURL,
                              let record = store.knowledge.records.first(where: { $0.sourcePath == node.url.path }) {
                        Button("Export source note…") { exportSourceNote(record) }
                            .accessibilityIdentifier("knowledge.exportSourceNote")
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let generated {
                            generatedReader(generated)
                        } else {
                            renderedMarkdownView(bodyText: node.markdownBody, isRoot: node.isRoot, graph: graph)
                        }
                        if let nodeIdx = graph.nodes.firstIndex(where: { $0.url == node.url }) {
                            let neighbors = graph.adjacency[nodeIdx].compactMap { idx in
                                graph.nodes.indices.contains(idx) ? graph.nodes[idx] : nil
                            }
                            if !neighbors.isEmpty {
                                Divider().overlay(Color.white.opacity(0.07)).padding(.top, 8)
                                Text("Connected sources").font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(RelayColors.textMuted)
                                FlowLayoutWikilinks(nodes: Array(neighbors.prefix(6))) { targetNode in
                                    selectVaultNode(targetNode)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func generatedReader(_ note: GeneratedKnowledgeNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source highlights").display(26)
            Text("Relay’s local model selected verbatim excerpts from the indexed text.")
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
                .font(.system(size: 12))
                .foregroundStyle(RelayColors.textSecondary)
                .textSelection(.enabled)
                .padding(.top, 6)
            }
            ForEach(Array(note.highlights.enumerated()), id: \.offset) { _, excerpt in
                Text(excerpt)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .relayGlassCard(cornerRadius: 8)
            }
        }
    }

    private func renderedMarkdownView(bodyText: String, isRoot: Bool, graph: SkyGraph) -> some View {
        let lines = bodyText.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, rawLine in
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Spacer().frame(height: 4)
                } else if trimmed.hasPrefix("# ") {
                    Text(String(trimmed.dropFirst(2)))
                        .display(26)
                        .foregroundStyle(.white).padding(.bottom, 4)
                } else if trimmed.hasPrefix("## ") {
                    Text(String(trimmed.dropFirst(3)))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RelayColors.accentGold).padding(.top, 4)
                } else if trimmed.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(RelayColors.accentAmethyst)
                        wikilinkHighlightedText(String(trimmed.dropFirst(2)), graph: graph)
                    }
                } else {
                    wikilinkHighlightedText(trimmed, graph: graph)
                }
            }
        }
    }

    private var emptyKnowledgeState: some View {
        ZStack {
            RelayAtmosphere(focused: false)
                .opacity(0.65)

            VStack(spacing: 22) {
                RelayPrismOrb(size: 84)

                VStack(spacing: 12) {
                    OnboardingWhisper("CONSTELLATION VAULT · LOCAL SOURCES")
                    Text("Your knowledge starts here")
                        .display(28)
                        .foregroundStyle(.white)
                    Text("Choose files or folders, then index them to read, search, and explore their connected graph. Only your selected sources appear here.")
                        .font(.system(size: 14.5, weight: .regular, design: .default))
                        .foregroundStyle(RelayColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 460)
                }

                HStack(spacing: 12) {
                    Button {
                        store.chooseFiles()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Choose files…")
                        }
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())

                    Button {
                        store.chooseFolder()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Choose folder…")
                        }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())

                    Button(store.knowledge.isIndexing ? "Indexing…" : "Index selected sources") {
                        Task { await store.knowledge.index(grants: store.grants); refreshSearch() }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(store.grants.isEmpty || store.knowledge.isIndexing)
                }

                Text(store.knowledge.status)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(RelayColors.textMuted)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 34)
            .frame(width: 580)
            .relayLitCard(accent: RelayColors.accentGold, cornerRadius: 20)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wikilinkHighlightedText(_ line: String, graph: SkyGraph) -> some View {
        let clean = line.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        return Text(clean)
            .font(.system(size: 15))
            .foregroundStyle(RelayColors.textSecondary)
            .lineSpacing(5)
            .textSelection(.enabled)
    }

    // MARK: - 2. Settings Knowledge Pane (`SettingsView` -> `Knowledge` Tab)

    private var settingsKnowledgeBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                OnboardingWhisper("LOCAL SOURCES & CONSTELLATION")
                Text("Knowledge & Sources")
                    .display(26)
                    .foregroundStyle(.white)
                Text("Index selected files locally. Your original files stay in place.")
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineSpacing(3)
            }

            HStack(spacing: 10) {
                Button("Add files…", systemImage: "doc.badge.plus") { store.chooseFiles() }
                Button("Add folder…", systemImage: "folder.badge.plus") { store.chooseFolder() }
                Button("Show Vault in Finder", systemImage: "folder") {
                    KnowledgeVaultManager.shared.revealVaultInFinder()
                }
            }
            .buttonStyle(RelaySecondaryButtonStyle())

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("\(store.grants.count) authorized sources · \(store.knowledge.records.count) indexed files", systemImage: "books.vertical")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    RelayMonoCaps(text: "LOCAL INDEX", color: RelayColors.accentEmerald, size: 10)
                }
                Text("Indexes Markdown, text, CSV, JSON, PDF, and .eml mail exports locally (up to 200 files / 10 MB).")
                    .font(.system(size: 13))
                    .foregroundStyle(RelayTheme.muted)
                    .lineSpacing(3)

                HStack {
                    if store.knowledge.isIndexing {
                        ProgressView().controlSize(.small)
                        Button("Cancel indexing") { store.knowledge.cancel() }
                    } else {
                        Button("Index selected sources") {
                            Task {
                                await store.knowledge.index(grants: store.grants)
                                skyModel.load(records: store.knowledge.records, entrance: false)
                                refreshSearch()
                            }
                        }
                        .disabled(store.grants.isEmpty)
                    }
                    Spacer()
                    Button("Refresh sources") {
                        store.knowledge.purgeStale(grants: store.grants)
                        store.suggestions.purge(records: store.knowledge.records)
                        skyModel.load(records: store.knowledge.records, entrance: false)
                        refreshSearch()
                    }
                    .disabled(store.knowledge.isIndexing)
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Text(store.knowledge.status)
                    .font(.system(size: 12.5))
                    .foregroundStyle(RelayTheme.muted)
                    .textSelection(.enabled)
            }
            .padding(20)
            .relayGlassCard(cornerRadius: 16)

            suggestionsSection
            calendarSection
            SemanticSearchView(search: store.knowledgeSearch, taskBusy: store.isRunning || store.voice.isBusy)

            if !store.knowledge.records.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    RelayMonoCaps(text: "INDEXED LOCAL FILES", color: RelayColors.textSecondary, size: 10)
                    ForEach(store.knowledge.records.prefix(12)) { record in
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.title).font(.system(size: 14, weight: .medium))
                                Text(record.sourcePath).font(.system(size: 12)).foregroundStyle(RelayTheme.muted).lineLimit(1)
                            }
                            Spacer()
                            Button("Forget") {
                                store.invalidateDerivedContext(reason: "Indexed source forgotten.")
                                store.knowledge.removeSource(path: record.sourcePath)
                                skyModel.load(records: store.knowledge.records, entrance: false)
                                refreshSearch()
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                        }
                        .padding(12)
                        .relayGlassCard(cornerRadius: 10)
                    }
                    HStack {
                        Button("Export as Markdown…") { export() }.disabled(store.knowledge.isIndexing)
                        Button("Clear local index") {
                            store.invalidateDerivedContext(reason: "Local index cleared.")
                            store.knowledge.clear()
                            skyModel.load(records: store.knowledge.records, entrance: false)
                            results = []
                        }.disabled(store.knowledge.isIndexing)
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                }
            }
            if let exportError { Text(exportError).font(.system(size: 13)).foregroundStyle(RelayColors.accentCoral) }
        }
    }

    // MARK: - Suggestions & Calendar Sections

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proactive Briefings").font(.system(size: 16, weight: .semibold))
            Toggle(isOn: Binding(get: { store.suggestions.enabled }, set: { store.setSuggestionsEnabled($0) })) {
                Text("Enable proactive suggestions from indexed sources")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            Text("Prepares local morning briefing cards with source citations. Runs only on your Mac.")
                .font(.system(size: 13)).foregroundStyle(RelayTheme.muted).lineSpacing(3)
            HStack {
                Button("Prepare brief now") {
                    store.knowledge.purgeStale(grants: store.grants)
                    store.suggestions.prepare(records: store.knowledge.records)
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(!store.suggestions.enabled || store.knowledge.isIndexing)

                Spacer()
                Text(store.suggestions.status).font(.system(size: 12.5)).foregroundStyle(RelayTheme.muted)
            }
            PreparationScheduleView(scheduler: store.preparation, suggestionsEnabled: store.suggestions.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .relayGlassCard(cornerRadius: RelayTheme.radius)
    }

    private var calendarSection: some View {
        DisclosureGroup("Calendar context · optional") {
            VStack(alignment: .leading, spacing: 12) {
                Text(CalendarSource.permissionExplanation).font(.system(size: 13)).foregroundStyle(RelayTheme.muted).lineSpacing(3)
                HStack {
                    Button(store.calendarSource.hasAccess ? "Refresh calendars" : "Choose calendar access…") {
                        Task { await store.calendarSource.requestAccess() }
                    }.disabled(store.calendarSource.isLoading)
                    Button("Read next 7 days") { Task { await store.calendarSource.refresh(days: 7) } }
                        .disabled(!store.calendarSource.hasAccess || store.calendarSource.selectedCalendarIDs.isEmpty || store.calendarSource.isLoading)
                    Button("Forget calendar context") { store.calendarSource.clear() }
                }.buttonStyle(RelaySecondaryButtonStyle())
                Text(store.calendarSource.status).font(.system(size: 12.5)).foregroundStyle(RelayTheme.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .relayGlassCard(cornerRadius: 12)
            .padding(.top, 8)
        }
        .font(.system(size: 14, weight: .medium))
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
        skyModel.load(records: store.knowledge.records, customNotes: vaultNotes.graphNotes,
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

    private func refreshSearch() {
        searchTask?.cancel()
        searchError = nil
        let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { results = []; searchPending = false; return }
        searchPending = true
        searchTask = Task {
            defer { if !Task.isCancelled { searchPending = false } }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let found = try await store.knowledgeSearch.search(query: requested)
                guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == requested else { return }
                results = found
            } catch is CancellationError { if !Task.isCancelled { results = [] } }
            catch {
                guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == requested else { return }
                results = []; searchError = "Search changed or could not finish. Try again with the current sources."
            }
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
                            .font(.system(size: 11, weight: .medium))
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
            HStack(spacing: 9) {
                Image(systemName: "circle.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSelected ? RelayColors.accentGold : RelayColors.textSecondary)
                Text("Overview")
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.84))
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                        ? RelayColors.accentGold.opacity(0.15)
                        : (isHovered ? Color.white.opacity(0.06) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected
                        ? RelayColors.accentGold.opacity(0.32)
                        : (isHovered ? Color.white.opacity(0.10) : Color.clear),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct KnowledgeSidebarFolderRow: View {
    let title: String
    let count: Int
    let color: Color
    let isExpanded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isExpanded ? color.opacity(0.18) : Color.white.opacity(isHovered ? 0.09 : 0.04))
                        .frame(width: 20, height: 20)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(isExpanded ? color : RelayColors.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color.opacity(0.95))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isExpanded ? color : RelayColors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.05), in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isHovered ? color.opacity(0.28) : Color.white.opacity(0.04), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(title) folder, \(count) sources")
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
                    .frame(width: 6, height: 6)
                    .shadow(color: isSelected ? color.opacity(0.6) : .clear, radius: 4)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(isHovered ? 0.90 : 0.72))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, 22)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                        ? color.opacity(0.16)
                        : (isHovered ? Color.white.opacity(0.05) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? color.opacity(0.32) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
