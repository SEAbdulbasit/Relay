import Foundation
import Testing
@testable import Relay

@MainActor
struct LocalNoteTrashTests {
    private func withVault(_ body: (KnowledgeVaultManager, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-note-trash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultRoot = root.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: false)
        try body(KnowledgeVaultManager(directoryURL: vaultRoot), vaultRoot)
    }

    @Test func deletedNoteSurvivesManagerRestartAndRestoresExactFolderIdentityAndBytes() throws {
        try withVault { vault, root in
            _ = try vault.createFolder(named: "Research")
            let note = try vault.saveNote(title: "A useful result", body: "A literal result.\n\nUnicode: café 🌿", folder: "Research")
            let bytes = try Data(contentsOf: note.url)
            let entry = try vault.trashNote(note)
            #expect(try vault.loadNotes().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: note.url.path))
            let reopened = KnowledgeVaultManager(directoryURL: root)
            #expect(try reopened.trashedNotes() == [entry])
            let restored = try reopened.restoreNote(entry)
            #expect(restored.graphURL == note.graphURL)
            #expect(restored.folderName == "Research")
            #expect(try Data(contentsOf: restored.url) == bytes)
            #expect(try reopened.trashedNotes().isEmpty)
            #expect(try reopened.loadNotes().count == 1)
        }
    }

    @Test func staleDeleteNeverRemovesAnExternallyEditedNote() throws {
        try withVault { vault, _ in
            let note = try vault.saveNote(title: "Original", body: "Before")
            try "# Updated\n\nAfter".write(to: note.url, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) { try vault.trashNote(note) }
            #expect(try String(contentsOf: note.url, encoding: .utf8) == "# Updated\n\nAfter")
            #expect(try vault.trashedNotes().isEmpty)
        }
    }

    @Test func restoreCollisionPreservesBothCurrentFileAndDeletedBytes() throws {
        try withVault { vault, _ in
            let note = try vault.saveNote(title: "Original", body: "Keep deleted bytes")
            let entry = try vault.trashNote(note)
            try "# Replacement\n\nKeep current bytes".write(to: note.url, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) { try vault.restoreNote(entry) }
            #expect(try String(contentsOf: note.url, encoding: .utf8) == "# Replacement\n\nKeep current bytes")
            #expect(try vault.trashedNotes() == [entry])
        }
    }

    @Test func restoringRecreatesOnlyTheOriginalMissingOrdinaryFolder() throws {
        try withVault { vault, root in
            _ = try vault.createFolder(named: "Plans")
            let note = try vault.saveNote(title: "Plan", body: "Recover me", folder: "Plans")
            let entry = try vault.trashNote(note)
            try FileManager.default.removeItem(at: root.appendingPathComponent("Plans"))
            let restored = try vault.restoreNote(entry)
            #expect(restored.graphURL == note.graphURL)
            #expect(restored.body == "Recover me")
        }
    }

    @Test func trashDirectorySymlinkDoesNotMoveNoteOrWriteOutsideVault() throws {
        try withVault { vault, root in
            let note = try vault.saveNote(title: "Note", body: "Keep me")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root.deletingLastPathComponent().appendingPathComponent(".Vault.relay-trash"), withDestinationURL: outside)
            #expect(throws: (any Error).self) { try vault.trashNote(note) }
            #expect(FileManager.default.fileExists(atPath: note.url.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    @Test func replacedSourceSymlinkNeverReadsOrDeletesItsTarget() throws {
        try withVault { vault, root in
            let note = try vault.saveNote(title: "Note", body: "Original")
            let external = root.appendingPathComponent("private.txt")
            try Data("Private target".utf8).write(to: external)
            try FileManager.default.removeItem(at: note.url)
            try FileManager.default.createSymbolicLink(at: note.url, withDestinationURL: external)
            #expect(throws: (any Error).self) { try vault.trashNote(note) }
            #expect(try String(contentsOf: external, encoding: .utf8) == "Private target")
        }
    }

    @Test func tamperedRecoveryPathCannotEscapeTheVault() throws {
        try withVault { vault, root in
            let note = try vault.saveNote(title: "Note", body: "Recoverable")
            let entry = try vault.trashNote(note)
            let forged = LocalNoteTrashEntry(id: entry.id, title: entry.title, deletedAt: entry.deletedAt, originalRelativePath: "../escape.md")
            let manifest = root.deletingLastPathComponent().appendingPathComponent(".Vault.relay-trash/\(entry.id.uuidString)/entry.json")
            try JSONEncoder().encode(forged).write(to: manifest)
            #expect(throws: (any Error).self) { try vault.restoreNote(forged) }
            #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.md").path))
            #expect(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent(".Vault.relay-trash/\(entry.id.uuidString)/note.md").path))
        }
    }

    @Test func replacementFolderSymlinkBlocksRestoreWithoutLosingTrash() throws {
        try withVault { vault, root in
            _ = try vault.createFolder(named: "Folder")
            let note = try vault.saveNote(title: "Note", body: "Recoverable", folder: "Folder")
            let entry = try vault.trashNote(note)
            let folder = root.appendingPathComponent("Folder")
            try FileManager.default.removeItem(at: folder)
            let outside = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
            #expect(throws: (any Error).self) { try vault.restoreNote(entry) }
            #expect(try vault.trashedNotes() == [entry])
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    @Test func externallyLongHeadingAndLegalMacBackslashFolderRemainRecoverable() throws {
        try withVault { vault, _ in
            _ = try vault.createFolder(named: "Notes\\2026")
            let saved = try vault.saveNote(title: "Before", body: "Literal bytes", folder: "Notes\\2026")
            let markdown = "# " + String(repeating: "🌿", count: 300) + "\n\nLiteral bytes"
            try markdown.write(to: saved.url, atomically: true, encoding: .utf8)
            let notes = try vault.loadNotes()
            let note = try #require(notes.first)
            let entry = try vault.trashNote(note)
            #expect(entry.title.utf8.count <= 200)
            #expect(try vault.trashedNotes() == [entry])
            let restored = try vault.restoreNote(entry)
            #expect(restored.graphURL == note.graphURL)
            #expect(restored.sharingMarkdown == markdown)
        }
    }

    @Test func interruptedTrashBundleDoesNotHideOtherRecoverableNotes() throws {
        try withVault { vault, root in
            let note = try vault.saveNote(title: "Valid", body: "Recover this")
            let entry = try vault.trashNote(note)
            let incomplete = LocalNoteTrashEntry(id: UUID(), title: "Interrupted", deletedAt: Date(), originalRelativePath: "missing.md")
            let bundle = root.deletingLastPathComponent().appendingPathComponent(".Vault.relay-trash/\(incomplete.id.uuidString)")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            try JSONEncoder().encode(incomplete).write(to: bundle.appendingPathComponent("entry.json"))
            let listing = try vault.noteTrashListing()
            #expect(listing.entries == [entry])
            #expect(listing.unreadableCount == 1)
            #expect(throws: (any Error).self) { try vault.trashedNotes() }
            let restored = try vault.restoreNote(entry)
            #expect(restored.sharingMarkdown == note.sharingMarkdown)
            #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("entry.json").path))
        }
    }
}
