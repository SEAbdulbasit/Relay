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
    @State private var expandedDomains: Set<String> = ["Indexed Sources", GeneratedKnowledgeNote.domain, "Your Notes", "People", "Projects"]
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

    private var workspaceKnowledgeVaultBody: some View {
        let noteCount = vaultNotes.count
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your knowledge")
                        .font(.relayHeadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(store.knowledge.records.count) indexed · \(noteCount) \(noteCount == 1 ? "note" : "notes")")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer(minLength: 8)
                Button("New note", systemImage: "square.and.pencil") { noteEditor = .init() }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("knowledge.newNote")
                RelayIconButton(icon: "folder.badge.plus", label: "New folder", size: 36) {
                    newFolderName = ""
                    showNewFolder = true
                }
                .accessibilityIdentifier("knowledge.newFolder")
                Button(fullGalaxyMode ? "Reader" : "Constellation", systemImage: fullGalaxyMode ? "books.vertical" : "sparkles") {
                    fullGalaxyMode.toggle()
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(!hasVaultContent)
            }
            .padding(.horizontal, RelayTheme.inset)
            .frame(height: 58)
            .background(RelayColors.pitch)

            Rectangle().fill(RelayTheme.line).frame(height: 1)

            if !hasVaultContent {
                emptyKnowledgeState
            } else if fullGalaxyMode {
                NightSkyView(model: skyModel, showsHUD: true) { clickedNode in
                    selectVaultNode(clickedNode)
                    fullGalaxyMode = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    vaultLeftSidebar
                        .frame(width: 228)
                        .frame(maxHeight: .infinity)
                        .background(RelayColors.canvas)
                    Rectangle().fill(RelayTheme.line).frame(width: 1)
                    vaultMiddleMarkdownPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RelayColors.pitch)
                }
            }
            if let vaultStatus = vaultLoadError ?? vaultStatus {
                Text(vaultStatus)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.horizontal, RelayTheme.inset)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .background(RelayColors.pitch)
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
                        let relationshipKind = KnowledgeRelationship.Kind.allCases.first { $0.domain == domainName }
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
                                isExpanded: isExpanded,
                                relationshipKind: relationshipKind
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
            guard let record = store.knowledge.records.first(where: { $0.sourcePath == node.url.path }),
                  store.knowledge.revalidate(record, grants: store.grants) else {
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
            let source = node.url.isFileURL ? store.knowledge.records.first(where: { $0.sourcePath == node.url.path }) : nil
            let relationshipKind = KnowledgeRelationship.Kind.from(node.url)
            let neighbors = graph.linkedNodes(from: node.url)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let relationshipKind {
                            Text(relationshipKind.title)
                                .font(.relayCaption)
                                .foregroundStyle(RelayColors.textSecondary)
                        }
                        Text(node.isRoot ? "Overview" : node.title)
                            .font(.system(size: 26, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(relationshipKind.map { "knowledge.linked.\($0.rawValue)" } ?? "knowledge.readerTitle")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let generated {
                        Button("Make editable copy…") { copyGeneratedNote(generated) }
                            .accessibilityIdentifier("knowledge.copyGeneratedNote")
                    } else if let note = vaultNotes.first(where: { $0.graphURL == node.url }) {
                        Button("Edit note") { noteEditor = .init(note: note) }
                            .accessibilityIdentifier("knowledge.editNote")
                    } else if let source {
                        Button("Export source note…") { exportSourceNote(source) }
                            .accessibilityIdentifier("knowledge.exportSourceNote")
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
                ScrollView {
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
                            renderedMarkdownView(node, graph: graph, neighbors: neighbors)
                        }
                        let related = neighbors.filter { $0.url.host != "group" }
                        if relationshipKind == nil, !related.isEmpty {
                            Divider().overlay(Color.white.opacity(0.07)).padding(.top, 8)
                            Text("Linked notes and sources").font(.system(size: 14, weight: .medium))
                                .foregroundStyle(RelayColors.textMuted)
                            FlowLayoutWikilinks(nodes: Array(related.prefix(6))) { targetNode in
                                selectVaultNode(targetNode)
                            }
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 24)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func relationshipReader(neighbors: [SkyNode]) -> some View {
        let documents = neighbors.filter { $0.url.host != "group" }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 12) {
            Text(documents.count == 1 ? "1 linked document" : "\(documents.count) linked documents")
                .foregroundStyle(RelayColors.textSecondary)
            ForEach(documents) { document in
                Button {
                    selectVaultNode(document)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: document.url.isFileURL ? "doc" : "note.text")
                            .foregroundStyle(RelayColors.textMuted)
                        Text(document.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RelayColors.textMuted)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func generatedReader(_ note: GeneratedKnowledgeNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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

    private func renderedMarkdownView(_ node: SkyNode, graph: SkyGraph, neighbors: [SkyNode]) -> some View {
        let allLines = KnowledgeWikiLink.lines(in: node.markdownBody)
        let header = node.isRoot ? "# Your knowledge" : "# \(node.title)"
        let lines = allLines.first?.text == header
            ? allLines.dropFirst().drop(while: { $0.text.trimmingCharacters(in: .whitespaces).isEmpty })
            : allLines[...]
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Spacer().frame(height: 4)
                } else if line.allowsLinks, trimmed.hasPrefix("# ") {
                    wikilinkHighlightedText(String(trimmed.dropFirst(2)), graph: graph, neighbors: neighbors)
                        .display(26)
                        .foregroundStyle(.white).padding(.bottom, 4)
                } else if line.allowsLinks, trimmed.hasPrefix("## ") {
                    wikilinkHighlightedText(String(trimmed.dropFirst(3)), graph: graph, neighbors: neighbors)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RelayColors.accentGold).padding(.top, 4)
                } else if line.allowsLinks, trimmed.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(RelayColors.accentAmethyst)
                        wikilinkHighlightedText(String(trimmed.dropFirst(2)), graph: graph, neighbors: neighbors)
                    }
                } else {
                    wikilinkHighlightedText(trimmed, graph: graph, neighbors: neighbors, allowsLinks: line.allowsLinks)
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
                .font(.system(size: 27, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Create a note, or add files and folders to make them searchable on this Mac.")
                .font(.relayBody)
                .foregroundStyle(RelayColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 385)

            HStack(spacing: 10) {
                if store.grants.isEmpty {
                    Button("Choose files…", systemImage: "doc.badge.plus") { store.chooseFiles() }
                    Button("Choose folder…", systemImage: "folder.badge.plus") { store.chooseFolder() }
                } else {
                    Button(store.knowledge.isIndexing ? "Indexing…" : "Index selected sources") {
                        Task { await store.knowledge.index(grants: store.grants); refreshSearch() }
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

    private func wikilinkHighlightedText(_ line: String, graph: SkyGraph, neighbors: [SkyNode], allowsLinks: Bool = true) -> some View {
        var text = AttributedString()
        var start = line.startIndex
        if allowsLinks {
            for link in KnowledgeWikiLink.inLine(line) {
                text.append(AttributedString(line[start..<link.range.lowerBound]))
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
        text.append(AttributedString(line[start...]))
        return Text(text)
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
                let sourceCount = store.grants.count
                let fileCount = store.knowledge.records.count
                HStack {
                    Label("\(sourceCount) authorized \(sourceCount == 1 ? "source" : "sources") · \(fileCount) indexed \(fileCount == 1 ? "file" : "files")", systemImage: "books.vertical")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    RelayMonoCaps(text: "LOCAL INDEX", color: RelayColors.accentEmerald, size: 10)
                }
                Text("Indexes Markdown, text, CSV, JSON, PDF, and .eml mail exports locally (up to 200 files / 10 MB). Choose a WhatsApp text export directly to include recent messages with names and times.")
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
            Text("Relay prepares suggestions on this Mac. Open Morning Brief from the workspace toolbar to review them and see their sources.")
                .font(.system(size: 13)).foregroundStyle(RelayTheme.muted).lineSpacing(3)
            Toggle("Draft up to two tasks for each scheduled brief",
                   isOn: Binding(get: { store.suggestions.scheduledDraftsEnabled },
                                 set: { store.suggestions.setScheduledDraftsEnabled($0) }))
                .toggleStyle(.switch)
                .disabled(!store.suggestions.enabled)
            Text("Uses your local model and keeps up to two drafts on this Mac for 24 hours while their sources stay current.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
            HStack {
                Button("Prepare brief now") {
                    store.knowledge.purgeStale(grants: store.grants)
                    store.suggestions.prepare(records: store.knowledge.records)
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(!store.suggestions.enabled || store.knowledge.isIndexing || store.preparation.isPreparing)

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
    let relationshipKind: KnowledgeRelationship.Kind?
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
                Image(systemName: relationshipKind?.icon ?? (isExpanded ? "folder.fill" : "folder"))
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
