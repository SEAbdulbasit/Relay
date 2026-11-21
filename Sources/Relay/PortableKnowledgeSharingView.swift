import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PortableKnowledgeSharingView: View {
    private enum Sheet: String, Identifiable {
        case create, open
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RelaySectionHeading(
                title: "Portable encrypted archive",
                detail: "Save selected Markdown notes as one encrypted file. Keep its recovery code separately. A copy of Relay can open the archive on another Mac, without a server.",
                icon: "archivebox"
            )
            HStack(spacing: 10) {
                Button("Create archive…", systemImage: "lock.doc") { sheet = .create }
                    .accessibilityIdentifier("knowledge.createPortableArchive")
                Button("Open archive…", systemImage: "lock.open") { sheet = .open }
                    .accessibilityIdentifier("knowledge.openPortableArchive")
                Spacer()
            }
            .buttonStyle(RelaySecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayFormSection()
        .sheet(item: $sheet) { choice in
            switch choice {
            case .create: CreateKnowledgeArchiveSheet()
            case .open: OpenKnowledgeArchiveSheet()
            }
        }
    }
}

private let portableArchiveFileType = UTType(filenameExtension: "relaynotes", conformingTo: .data) ?? .data

private struct CreateKnowledgeArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [LocalMarkdownNote] = []
    @State private var selection: Set<URL> = []
    @State private var status: String?
    @State private var recoveryCode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create encrypted archive")
                .font(RelayPageStyle.dialogTitle)
                .foregroundStyle(RelayColors.textPrimary)
            if let recoveryCode {
                Text("Keep the recovery code somewhere separate from the archive. Relay does not store it, and the file cannot be opened without it.")
                    .font(.relayBody)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(recoveryCode)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(RelayColors.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
                    .accessibilityIdentifier("knowledge.archiveRecoveryCode")
                Button("Copy recovery code", systemImage: "doc.on.doc") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if pasteboard.setString(recoveryCode, forType: .string) { status = "Recovery code copied." }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            } else {
                Text("Choose up to \(PortableKnowledgeArchive.maximumNotes) editable notes, with a total archive content limit of 1 MiB.")
                    .font(.relayBody)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if notes.isEmpty {
                    ContentUnavailableView("No editable notes", systemImage: "note.text",
                                           description: Text("Create or copy a note in Knowledge first."))
                        .frame(height: 190)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(notes) { note in
                                Toggle(isOn: Binding(
                                    get: { selection.contains(note.url) },
                                    set: { selected in
                                        if selected { selection.insert(note.url) } else { selection.remove(note.url) }
                                    }
                                )) {
                                    Text(note.folderName.map { $0 + " / " + note.title } ?? note.title)
                                        .font(.relayCallout)
                                        .foregroundStyle(RelayColors.textPrimary)
                                        .lineLimit(1)
                                }
                                .disabled(!selection.contains(note.url) && selection.count >= PortableKnowledgeArchive.maximumNotes)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 230)
                    .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
                    Text("\(selection.count) selected")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
            }
            if let status {
                Text(status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("knowledge.archiveExportStatus")
            }
            HStack {
                Spacer()
                Button(recoveryCode == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(RelaySecondaryButtonStyle())
                if recoveryCode == nil {
                    Button("Save encrypted archive…") { export() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("knowledge.savePortableArchive")
                }
            }
        }
        .padding(24)
        .frame(width: 525)
        .relayPageBackground()
        .relayPreferredAppearance()
        .onAppear { refreshNotes() }
    }

    private func refreshNotes() {
        do {
            notes = try KnowledgeVaultManager.shared.loadNotes()
            selection.formIntersection(notes.map(\.url))
        } catch {
            status = "Could not read the local notes: " + error.localizedDescription
        }
    }

    private func export() {
        let approved = notes.filter { selection.contains($0.url) }
        let panel = NSSavePanel()
        panel.title = "Save encrypted Relay notes"
        panel.message = "Choose a new archive file. You will receive its recovery code after saving."
        panel.allowedContentTypes = [portableArchiveFileType]
        panel.nameFieldStringValue = "Relay Knowledge.relaynotes"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let fresh = try KnowledgeVaultManager.shared.loadNotes()
            let entries = try PortableKnowledgeArchive.currentEntries(selected: approved, in: fresh)
            let sealed = try PortableKnowledgeArchive.seal(entries)
            do {
                try sealed.write(to: destination)
                recoveryCode = sealed.recoveryCode
                status = "Saved “" + destination.lastPathComponent + "”."
            } catch LocalPrivateFileWriteError.outcomeUncertain {
                recoveryCode = sealed.recoveryCode
                status = "The archive may have been saved. Keep this recovery code and check the selected file before trying again."
            }
        } catch {
            if error as? PortableKnowledgeArchiveError == .changedSelection {
                selection.removeAll()
                refreshNotes()
            }
            status = error.localizedDescription
        }
    }
}

private struct OpenKnowledgeArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var archiveURL: URL?
    @State private var recoveryCode = ""
    @State private var notes: [PortableKnowledgeEntry] = []
    @State private var selectedIndex = 0
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open encrypted archive")
                .font(RelayPageStyle.dialogTitle)
                .foregroundStyle(RelayColors.textPrimary)
            if notes.isEmpty {
                Text("Choose a Relay archive and enter its recovery code. Relay opens the notes read-only in this window.")
                    .font(.relayBody)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose archive…", systemImage: "folder") { chooseArchive() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .accessibilityIdentifier("knowledge.choosePortableArchive")
                    if let archiveURL {
                        Text(archiveURL.lastPathComponent)
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                SecureField("Recovery code", text: $recoveryCode)
                    .textFieldStyle(.plain)
                    .relayTextField()
                    .accessibilityIdentifier("knowledge.enterArchiveRecoveryCode")
            } else {
                Picker("Note", selection: $selectedIndex) {
                    ForEach(notes.indices, id: \.self) { index in
                        Text(notes[index].displayTitle).tag(index)
                    }
                }
                .accessibilityIdentifier("knowledge.openedArchiveNote")
                ScrollView {
                    Text(verbatim: notes[selectedIndex].markdown)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(RelayColors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .accessibilityIdentifier("knowledge.openedArchiveMarkdown")
                }
                .frame(height: 270)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            }
            if let status {
                Text(status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("knowledge.archiveOpenStatus")
            }
            HStack {
                Spacer()
                Button(notes.isEmpty ? "Cancel" : "Close archive") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(RelaySecondaryButtonStyle())
                if notes.isEmpty {
                    Button("Unlock archive") { openArchive() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(archiveURL == nil || recoveryCode.isEmpty)
                        .accessibilityIdentifier("knowledge.unlockPortableArchive")
                }
            }
        }
        .padding(24)
        .frame(width: 525)
        .relayPageBackground()
        .relayPreferredAppearance()
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = "Choose encrypted Relay notes"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [portableArchiveFileType]
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        archiveURL = selected
        recoveryCode = ""
        status = nil
    }

    private func openArchive() {
        guard let archiveURL else { return }
        do {
            let opened = try PortableKnowledgeArchive.open(at: archiveURL, recoveryCode: recoveryCode)
            selectedIndex = 0
            notes = opened
            recoveryCode = ""
            status = "\(opened.count) notes opened read-only."
        } catch {
            status = error.localizedDescription
        }
    }
}
