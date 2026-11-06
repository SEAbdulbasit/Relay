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

    let request: Request
    let folders: [LocalMarkdownFolder]
    let onSave: (LocalMarkdownNote) -> Void

    init(request: Request, folders: [LocalMarkdownFolder] = [], onSave: @escaping (LocalMarkdownNote) -> Void) {
        self.request = request
        self.folders = folders
        self.onSave = onSave
        _title = State(initialValue: request.note?.title ?? request.sourceCopy?.title ?? "")
        _bodyText = State(initialValue: request.note?.body ?? request.sourceCopy?.body ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.note == nil ? "New note" : "Edit note")
                .font(.title2.weight(.semibold))
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("knowledge.noteTitle")
                .focused($titleFocused)
            if request.note == nil, !folders.isEmpty {
                Picker("Folder", selection: $folderName) {
                    Text("Your Notes").tag("")
                    ForEach(folders) { folder in Text(folder.name).tag(folder.name) }
                }
                .accessibilityIdentifier("knowledge.noteFolder")
            } else if let folder = request.note?.folderName {
                Label(folder, systemImage: "folder").foregroundStyle(.secondary)
            }
            HStack {
                Text("Markdown").font(.callout).foregroundStyle(.secondary)
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
                .frame(minHeight: 220)
                .border(Color.secondary.opacity(0.35))
                .accessibilityLabel("Markdown body")
                .accessibilityIdentifier("knowledge.noteBody")
            if let status {
                Text(status).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Text(request.sourceCopy == nil ? "Saved as Markdown on this Mac." : "An editable snapshot kept separately from the source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save note") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("knowledge.saveNote")
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear { titleFocused = true }
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
            let saved = try KnowledgeVaultManager.shared.saveNote(title: title, body: bodyText, replacing: request.note,
                                                                 folder: folderName.isEmpty ? nil : folderName)
            onSave(saved)
            dismiss()
        } catch {
            status = error.localizedDescription
        }
    }
}
