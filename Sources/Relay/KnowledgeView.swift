import AppKit
import SwiftUI

struct KnowledgeView: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Bindable var store: AssistantStore
    var startInConstellation: Bool = false
    var isSettingsPane: Bool = false

    @StateObject private var skyModel = NightSkyModel()
    @State private var fullGalaxyMode: Bool = false
    @State private var expandedDomains: Set<Int> = [0, 1]
    @State private var selectedNodeURL: URL? = nil

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
        .onChange(of: store.knowledge.records) { _, _ in
            store.knowledgeSearch.invalidateSources()
            store.suggestions.purge(records: store.knowledge.records)
            skyModel.load(records: store.knowledge.records, entrance: false)
            refreshSearch()
        }
        .onChange(of: store.grants.map { $0.id }) { _, _ in refreshSearch() }
        .onChange(of: store.knowledgeSearch.state) { _, _ in refreshSearch() }
        .onAppear {
            store.knowledge.purgeStale(grants: store.grants)
            store.suggestions.purge(records: store.knowledge.records)
            if skyModel.graph == nil || skyModel.graph?.nodes.isEmpty == true {
                skyModel.load(records: store.knowledge.records, entrance: !reducedMotion)
            }
            refreshSearch()
        }
        .onDisappear { searchTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.knowledge.purgeStale(grants: store.grants)
            store.suggestions.purge(records: store.knowledge.records)
            refreshSearch()
        }
    }

    // MARK: - 1. Main Workspace Knowledge Vault (1:1 Match with Sentient OS `readme_knowledge.jpg`)

    private var workspaceKnowledgeVaultBody: some View {
        VStack(spacing: 0) {
            // Top Chrome Bar inside the Knowledge Vault Frame
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RelayColors.textSecondary)
                    Text("Knowledge")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                }

                Spacer()

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
                    .background(RelayColors.accentGold.opacity(0.12), in: Capsule())
                }
                .buttonStyle(RelayPressStyle())
                .disabled(store.knowledge.records.isEmpty)

                Text("Selected sources")
                    .font(.system(size: 12))
                    .foregroundStyle(RelayColors.textMuted)
                    .padding(.leading, 6)
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Color(red: 0.065, green: 0.068, blue: 0.082))

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            if store.knowledge.records.isEmpty {
                emptyKnowledgeState
            } else if fullGalaxyMode {
                NightSkyView(model: skyModel, showsHUD: true) { clickedNode in
                    selectedNodeURL = clickedNode.url
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
                                selectedNodeURL = clickedNode.url
                            }
                            .frame(width: max(260, geometry.size.width * 0.34))
                            .frame(maxHeight: .infinity)
                            .background(Color(red: 0.038, green: 0.040, blue: 0.052))
                        }
                    }
                }
            }
        }
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
                Text("Your knowledge")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RelayColors.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                if let graph = skyModel.graph {
                    // Overview Row (`◎ Overview`)
                    if let rootIdx = graph.rootIndex {
                        let rootNode = graph.nodes[rootIdx]
                        let isOverviewSelected = activeNode?.url == rootNode.url
                        Button {
                            selectedNodeURL = rootNode.url
                            skyModel.highlight(rootNode.url)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "record.circle")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(isOverviewSelected ? .white : RelayColors.textSecondary)
                                Text("Overview")
                                    .font(.system(size: 13.5, weight: isOverviewSelected ? .medium : .regular))
                                    .foregroundStyle(isOverviewSelected ? .white : RelayColors.textSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isOverviewSelected ? Color.white.opacity(0.08) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                    }

                    // Domain Folders (`› 📁 Projects`, `› 📁 People`, etc.)
                    ForEach(Array(graph.domains.enumerated()), id: \.offset) { dIdx, domainName in
                        let isExpanded = expandedDomains.contains(dIdx)
                        let domainNodes = graph.nodes.filter { !$0.isRoot && $0.domain == dIdx && $0.title != domainName }

                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    if expandedDomains.contains(dIdx) {
                                        expandedDomains.remove(dIdx)
                                    } else {
                                        expandedDomains.insert(dIdx)
                                    }
                                }
                                if let firstNode = domainNodes.first {
                                    selectedNodeURL = firstNode.url
                                    skyModel.highlight(firstNode.url)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(RelayColors.textMuted)
                                        .frame(width: 10)
                                    Image(systemName: "folder")
                                        .font(.system(size: 12))
                                        .foregroundStyle(SkyRenderer.domainColor(dIdx).opacity(0.85))
                                    Text(domainName)
                                        .font(.system(size: 13, weight: .regular))
                                        .foregroundStyle(RelayColors.textSecondary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)

                            if isExpanded {
                                ForEach(domainNodes) { node in
                                    sidebarNoteRow(node)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func sidebarNoteRow(_ node: SkyNode) -> some View {
        let isSelected = activeNode?.url == node.url
        return Button {
            selectedNodeURL = node.url
            skyModel.highlight(node.url)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(isSelected ? SkyRenderer.domainColor(node.domain) : Color.white.opacity(0.22))
                    .frame(width: 5, height: 5)
                Text(node.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : RelayColors.textMuted)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, 28)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Read-only selected-source reader

    @ViewBuilder
    private var vaultMiddleMarkdownPane: some View {
        if let node = activeNode, let graph = skyModel.graph {
            VStack(alignment: .leading, spacing: 0) {
                Text(node.isRoot ? "Overview" : node.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RelayColors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        renderedMarkdownView(bodyText: node.markdownBody, isRoot: node.isRoot, graph: graph)
                        if let nodeIdx = graph.nodes.firstIndex(where: { $0.url == node.url }) {
                            let neighbors = graph.adjacency[nodeIdx].compactMap { idx in
                                graph.nodes.indices.contains(idx) ? graph.nodes[idx] : nil
                            }
                            if !neighbors.isEmpty {
                                Divider().overlay(Color.white.opacity(0.07)).padding(.top, 8)
                                Text("Connected sources").font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(RelayColors.textMuted)
                                FlowLayoutWikilinks(nodes: Array(neighbors.prefix(6))) { targetNode in
                                    selectedNodeURL = targetNode.url
                                    skyModel.highlight(targetNode.url)
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

    private func renderedMarkdownView(bodyText: String, isRoot: Bool, graph: SkyGraph) -> some View {
        let lines = bodyText.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, rawLine in
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Spacer().frame(height: 4)
                } else if trimmed.hasPrefix("# ") {
                    Text(String(trimmed.dropFirst(2)))
                        .font(.system(size: 26, weight: .semibold)).tracking(-0.5)
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
        VStack(spacing: 16) {
            Image(systemName: "books.vertical").font(.system(size: 30)).foregroundStyle(RelayColors.textSecondary)
            Text("Your knowledge starts here").font(.system(size: 24, weight: .semibold))
            Text("Choose files or folders, then index them to read and search their excerpts. Only your selected sources appear here.")
                .font(.system(size: 15)).foregroundStyle(RelayColors.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button("Choose files…") { store.chooseFiles() }
                Button(store.knowledge.isIndexing ? "Indexing…" : "Index selected sources") {
                    Task { await store.knowledge.index(grants: store.grants); refreshSearch() }
                }.disabled(store.grants.isEmpty || store.knowledge.isIndexing)
            }.buttonStyle(RelaySecondaryButtonStyle())
            Text(store.knowledge.status).font(.system(size: 14)).foregroundStyle(RelayColors.textMuted)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Local sources").font(.system(size: 12, weight: .medium)).foregroundStyle(RelayColors.textSecondary)
                Text("Knowledge & Sources")
                    .font(.system(size: 20, weight: .medium))
                    .tracking(-0.4)
                Text("Index selected files locally. Your original files stay in place.")
                    .font(.system(size: 14))
                    .foregroundStyle(RelayTheme.muted)
                    .lineSpacing(4)
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
            Text("Proactive Briefings").font(.system(size: 17, weight: .semibold))
            Toggle("Enable proactive suggestions from indexed sources", isOn: Binding(get: { store.suggestions.enabled }, set: { store.setSuggestionsEnabled($0) }))
                .font(.system(size: 14))
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
        .padding(18)
        .relayGlassCard(cornerRadius: 14)
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
            }.padding(.top, 10)
        }
        .font(.system(size: 14, weight: .medium))
        .padding(16)
        .relayGlassCard(cornerRadius: 14)
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
                }
                .buttonStyle(RelayPressStyle())
            }
        }
    }
}
