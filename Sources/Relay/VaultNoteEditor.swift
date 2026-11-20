import SwiftUI

struct VaultNoteEditor: View {
    struct SourceCopy {
        let noteID: String
        let title: String
        let body: String
        let isCurrent: () -> Bool
    }

    struct Request: Identifiable {
        let id = UUID()
        var note: LocalMarkdownNote?
        var sourceCopy: SourceCopy?
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var title: String
    @State private var bodyText: String
    @State private var folderName = ""
    @State private var status: String?
    @State private var linkKind: KnowledgeRelationship.Kind = .person
    @State private var linkName = ""
    @State private var showsLinkPrompt = false
    @State private var autocompleteCandidates: [VaultWikilinkAutocomplete.Candidate] = []

    let request: Request
    let folders: [LocalMarkdownFolder]
    let onSave: (LocalMarkdownNote) -> Void

    init(request: Request, folders: [LocalMarkdownFolder] = [], onSave: @escaping (LocalMarkdownNote) -> Void) {
        self.request = request
        self.folders = folders
        self.onSave = onSave
        _title = State(initialValue: request.note?.title ?? request.sourceCopy?.title ?? "")
        _bodyText = State(initialValue: request.note?.body ?? request.sourceCopy?.body ?? "")
        _folderName = State(initialValue: request.note?.folderName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.note == nil ? "New note" : "Edit note")
                .font(.relayTitle)
                .foregroundStyle(RelayColors.textPrimary)
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .relayTextField(focused: titleFocused)
                .accessibilityIdentifier("knowledge.noteTitle")
                .focused($titleFocused)
            HStack(spacing: 10) {
                if !folders.isEmpty {
                    Picker("Folder", selection: $folderName) {
                        Text("Your Notes").tag("")
                        ForEach(folders) { folder in Text(folder.name).tag(folder.name) }
                        if !folderName.isEmpty && !folders.contains(where: { $0.name == folderName }) {
                            Text(folderName).tag(folderName)
                        }
                    }
                    .accessibilityIdentifier("knowledge.noteFolder")
                }
                TextField("Folder / category (optional)", text: $folderName)
                    .textFieldStyle(.plain)
                    .relayTextField()
                    .accessibilityIdentifier(folders.isEmpty ? "knowledge.noteFolder" : "knowledge.noteFolderInput")
            }
            HStack {
                Text("Markdown").font(.relayCallout).foregroundStyle(RelayColors.textSecondary)
                Spacer()
                Menu("Add link", systemImage: "link") {
                    ForEach(KnowledgeRelationship.Kind.allCases, id: \.self) { kind in
                        Button(kind.title, systemImage: kind.icon) {
                            linkKind = kind
                            linkName = ""
                            showsLinkPrompt = true
                        }
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("knowledge.addNoteLink")
            }
            TextEditor(text: $bodyText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(RelayColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 220)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
                .accessibilityLabel("Markdown body")
                .accessibilityIdentifier("knowledge.noteBody")
            VaultWikilinkAutocompleteBar(
                text: $bodyText,
                candidates: autocompleteCandidates,
                excludingTitle: title
            )
            if let status {
                Text(status).font(.relayCaption).foregroundStyle(RelayColors.textSecondary).textSelection(.enabled)
            }
            HStack {
                Text(request.sourceCopy == nil ? "Saved as Markdown on this Mac." : "An editable snapshot kept separately from the source.")
                    .font(.relayCallout)
                    .foregroundStyle(RelayColors.textSecondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(RelaySecondaryButtonStyle())
                Button("Save note") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("knowledge.saveNote")
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .background(RelayColors.canvas)
        .relayPreferredAppearance()
        .onAppear {
            titleFocused = true
            autocompleteCandidates = VaultWikilinkAutocomplete.loadVaultCandidates()
        }
        .alert("Link a \(linkKind.rawValue)", isPresented: $showsLinkPrompt) {
            TextField("Name", text: $linkName)
            Button("Add link") { addLink() }
                .disabled(KnowledgeRelationship(kind: linkKind, name: linkName) == nil)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func addLink() {
        guard let relationship = KnowledgeRelationship(kind: linkKind, name: linkName) else { return }
        let existing = KnowledgeWikiLink.lines(in: bodyText).lazy.filter(\.allowsLinks).contains { line in
            KnowledgeWikiLink.inLine(line.text).contains { $0.relationship?.url == relationship.url }
        }
        guard !existing else { return }
        bodyText = relationship.markdown + (bodyText.isEmpty ? "" : "\n\n" + bodyText)
    }

    private func save() {
        guard request.sourceCopy?.isCurrent() != false else {
            status = "The indexed source is no longer current. Reindex before making a copy."
            return
        }
        do {
            let trimmedFolder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetFolder: String? = trimmedFolder.isEmpty ? nil : trimmedFolder
            if let targetFolder, !folders.contains(where: { $0.name == targetFolder }) {
                _ = try? KnowledgeVaultManager.shared.createFolder(named: targetFolder)
            }
            let saved: LocalMarkdownNote
            if let existing = request.note, existing.folderName != targetFolder {
                saved = try KnowledgeVaultManager.shared.saveNote(
                    title: title,
                    body: bodyText,
                    replacing: nil,
                    folder: targetFolder
                )
                try? FileManager.default.removeItem(at: existing.url)
            } else {
                saved = try KnowledgeVaultManager.shared.saveNote(
                    title: title,
                    body: bodyText,
                    replacing: request.note,
                    folder: targetFolder
                )
            }
            onSave(saved)
            dismiss()
        } catch {
            status = error.localizedDescription
        }
    }
}

struct VaultWikilinkAutocomplete {
    struct Candidate: Identifiable, Equatable {
        let id: String
        let displayTitle: String
        let insertionTarget: String
        let icon: String
    }

    static func activeTrailingQuery(in text: String) -> (range: Range<String.Index>, query: String)? {
        if let openRange = text.range(of: "[[", options: .backwards) {
            let afterOpen = text[openRange.upperBound...]
            if !afterOpen.contains("]]") && !afterOpen.contains(where: \.isNewline) {
                return (openRange.lowerBound..<text.endIndex, String(afterOpen))
            }
        }
        var searchEnd = text.endIndex
        while searchEnd > text.startIndex {
            let prefix = text[..<searchEnd]
            let lineStart = prefix.lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
            let line = text[lineStart..<searchEnd]
            if let openRange = line.range(of: "[[", options: .backwards) {
                let afterOpen = line[openRange.upperBound...]
                if !afterOpen.contains("]]") && !afterOpen.contains(where: \.isNewline) {
                    return (openRange.lowerBound..<searchEnd, String(afterOpen))
                }
            }
            guard lineStart > text.startIndex else { break }
            searchEnd = text.index(before: lineStart)
        }
        return nil
    }

    static func matchingCandidates(
        for query: String,
        among candidates: [Candidate],
        excludingTitle: String? = nil
    ) -> [Candidate] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        let excluded = excludingTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let eligible = candidates.filter { candidate in
            guard !excluded.isEmpty else { return true }
            return candidate.displayTitle.lowercased() != excluded
                && candidate.insertionTarget.lowercased() != excluded
        }
        guard !trimmedQuery.isEmpty else {
            return Array(eligible.prefix(12))
        }
        let matches = eligible.filter { candidate in
            candidate.displayTitle.localizedStandardContains(trimmedQuery)
                || candidate.insertionTarget.localizedStandardContains(trimmedQuery)
        }
        let lowerQuery = trimmedQuery.lowercased()
        let sorted = matches.sorted { lhs, rhs in
            let lPrefix = lhs.displayTitle.lowercased().hasPrefix(lowerQuery) || lhs.insertionTarget.lowercased().hasPrefix(lowerQuery)
            let rPrefix = rhs.displayTitle.lowercased().hasPrefix(lowerQuery) || rhs.insertionTarget.lowercased().hasPrefix(lowerQuery)
            if lPrefix != rPrefix { return lPrefix }
            return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
        return Array(sorted.prefix(12))
    }

    static func apply(_ candidate: Candidate, in text: String, replacing range: Range<String.Index>) -> String {
        var copy = text
        copy.replaceSubrange(range, with: "[[\(candidate.insertionTarget)]]")
        return copy
    }

    static func candidates(from graph: SkyGraph?, vaultNotes: [LocalMarkdownNote]) -> [Candidate] {
        var seen = Set<String>()
        var result: [Candidate] = []

        func appendCandidate(displayTitle: String, insertionTarget: String, icon: String) {
            let key = insertionTarget.lowercased()
            guard !insertionTarget.isEmpty, seen.insert(key).inserted else { return }
            result.append(Candidate(id: key, displayTitle: displayTitle, insertionTarget: insertionTarget, icon: icon))
        }

        for note in vaultNotes {
            appendCandidate(displayTitle: note.title, insertionTarget: note.title, icon: "note.text")
        }

        if let graph {
            for node in graph.nodes where !node.isRoot && node.url.host != "group" {
                if let kind = KnowledgeRelationship.Kind.from(node.url) {
                    let target = "\(kind.title): \(node.title)"
                    appendCandidate(displayTitle: target, insertionTarget: target, icon: kind.icon)
                } else {
                    let icon = node.url.isFileURL ? "doc.text" : "note.text"
                    appendCandidate(displayTitle: node.title, insertionTarget: node.title, icon: icon)
                }
            }
        }
        return result
    }

    static func loadVaultCandidates() -> [Candidate] {
        let notes = (try? KnowledgeVaultManager.shared.loadNotes()) ?? []
        var seen = Set<String>()
        var result: [Candidate] = []

        func appendCandidate(displayTitle: String, insertionTarget: String, icon: String) {
            let key = insertionTarget.lowercased()
            guard !insertionTarget.isEmpty, seen.insert(key).inserted else { return }
            result.append(Candidate(id: key, displayTitle: displayTitle, insertionTarget: insertionTarget, icon: icon))
        }

        for note in notes {
            appendCandidate(displayTitle: note.title, insertionTarget: note.title, icon: "note.text")
            for line in KnowledgeWikiLink.lines(in: note.body) where line.allowsLinks {
                for link in KnowledgeWikiLink.inLine(line.text) {
                    if let rel = link.relationship {
                        let target = "\(rel.kind.title): \(rel.name)"
                        appendCandidate(displayTitle: target, insertionTarget: target, icon: rel.kind.icon)
                    } else {
                        appendCandidate(displayTitle: link.target, insertionTarget: link.target, icon: "note.text")
                    }
                }
            }
        }
        return result
    }
}

struct VaultWikilinkAutocompleteBar: View {
    @Binding var text: String
    let candidates: [VaultWikilinkAutocomplete.Candidate]
    var excludingTitle: String? = nil

    var body: some View {
        if let active = VaultWikilinkAutocomplete.activeTrailingQuery(in: text) {
            let matches = VaultWikilinkAutocomplete.matchingCandidates(
                for: active.query,
                among: candidates,
                excludingTitle: excludingTitle
            )
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "link")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RelayColors.accentGold)
                        Text(active.query.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Insert [[wikilink]]"
                             : "Matching “[[\(active.query)”")
                            .font(.relayMicro)
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(matches) { candidate in
                                Button {
                                    text = VaultWikilinkAutocomplete.apply(
                                        candidate,
                                        in: text,
                                        replacing: active.range
                                    )
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: candidate.icon)
                                            .font(.system(size: 9.5, weight: .semibold))
                                        Text("[[\(candidate.displayTitle)]]")
                                            .font(.relayMicro)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(RelayColors.knowledgeLink)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(RelayColors.knowledgeLink.opacity(0.12), in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(RelayColors.knowledgeLink.opacity(0.32), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(RelayPressStyle())
                                .accessibilityIdentifier("knowledge.wikilinkAutocomplete.\(candidate.id)")
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
                .accessibilityIdentifier("knowledge.wikilinkAutocompleteBar")
            }
        }
    }
}
