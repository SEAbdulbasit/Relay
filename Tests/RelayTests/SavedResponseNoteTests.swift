import Foundation
import Testing
@testable import Relay

@Suite("Saved response workflow")
@MainActor
struct SavedResponseNoteTests {
    private func withVault(_ body: (KnowledgeVaultManager, URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("relay-response-save-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try body(KnowledgeVaultManager(directoryURL: temporary.appendingPathComponent("vault", isDirectory: true)), temporary)
    }

    @Test func repeatSaveAfterRestartKeepsTheExactNoteAndUserEdits() throws {
        try withVault { vault, _ in
            let id = UUID()
            let original = try vault.saveResponseNote(messageID: id, title: "Checked arithmetic", body: "7 × 8 = 56.")
            let edited = try vault.saveNote(title: "My edited result", body: "Kept and edited by the user.", replacing: original)
            let restarted = KnowledgeVaultManager(directoryURL: vault.vaultDirectory)
            let repeated = try restarted.saveResponseNote(messageID: id, title: "A different title", body: "Must not replace edits.")
            #expect(repeated.id == edited.id)
            #expect(repeated.sharingMarkdown == edited.sharingMarkdown)
            #expect(try restarted.loadNotes().count == 1)
        }
    }

    @Test func movedCaptureResolvesCurrentFolderWithoutCreatingAnotherNote() throws {
        try withVault { vault, _ in
            let id = UUID()
            let original = try vault.saveResponseNote(messageID: id, title: "Result", body: "Actual saved content.")
            _ = try vault.createFolder(named: "Research")
            let moved = vault.vaultDirectory.appendingPathComponent("Research").appendingPathComponent(original.url.lastPathComponent)
            try FileManager.default.moveItem(at: original.url, to: moved)
            let resolved = try #require(try vault.savedResponseNote(messageID: id))
            let repeated = try vault.saveResponseNote(messageID: id, title: "Different", body: "Do not overwrite.")
            #expect(resolved.folderName == "Research")
            #expect(repeated.graphURL == resolved.graphURL)
            #expect(repeated.body == original.body)
            #expect(try vault.loadNotes().count == 1)
        }
    }

    @Test func ambiguousCopiesFailWithoutChangingEitherFile() throws {
        try withVault { vault, _ in
            let id = UUID()
            let original = try vault.saveResponseNote(messageID: id, title: "Result", body: "Preserve both copies.")
            _ = try vault.createFolder(named: "Copies")
            let duplicate = vault.vaultDirectory.appendingPathComponent("Copies").appendingPathComponent(original.url.lastPathComponent)
            try FileManager.default.copyItem(at: original.url, to: duplicate)
            let before = try Data(contentsOf: original.url)
            #expect(throws: (any Error).self) {
                try vault.saveResponseNote(messageID: id, title: "Overwrite", body: "Not permitted.")
            }
            #expect(try Data(contentsOf: original.url) == before)
            #expect(try Data(contentsOf: duplicate) == before)
        }
    }

    @Test func failedOversizedSaveCanRetryWithoutPartialNoteOrDuplicate() throws {
        try withVault { vault, _ in
            let id = UUID()
            #expect(throws: (any Error).self) {
                try vault.saveResponseNote(messageID: id, title: "Too large", body: String(repeating: "x", count: KnowledgeVaultManager.maximumNoteBytes + 1))
            }
            #expect(try vault.loadNotes().isEmpty)
            let saved = try vault.saveResponseNote(messageID: id, title: "Retry", body: "A bounded result.")
            #expect(saved.body == "A bounded result.")
            #expect(try vault.loadNotes().count == 1)
        }
    }

    @Test func symlinkAtCaptureDestinationCannotReplaceAnUnrelatedFile() throws {
        try withVault { vault, temporary in
            let id = UUID()
            vault.ensureDefaultVaultFilesExist()
            let unrelated = temporary.appendingPathComponent("unrelated.md")
            let bytes = Data("Private unrelated content.".utf8)
            try bytes.write(to: unrelated)
            let candidate = vault.vaultDirectory.appendingPathComponent("response-" + id.uuidString.lowercased() + ".md")
            try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: unrelated)
            #expect(throws: (any Error).self) {
                try vault.saveResponseNote(messageID: id, title: "Result", body: "Must not replace target.")
            }
            #expect(try Data(contentsOf: unrelated) == bytes)
        }
    }

    @Test func trashedCaptureRequiresRestoreAndIsNotSilentlyRecreated() throws {
        try withVault { vault, _ in
            let id = UUID()
            let original = try vault.saveResponseNote(messageID: id, title: "Result", body: "Kept in Trash until restored.")
            let entry = try vault.trashNote(original)
            #expect(throws: (any Error).self) {
                try vault.saveResponseNote(messageID: id, title: "Again", body: "Do not create a duplicate.")
            }
            #expect(try vault.loadNotes().isEmpty)
            let restored = try vault.restoreNote(entry)
            let repeated = try vault.saveResponseNote(messageID: id, title: "Again", body: "Do not replace restored content.")
            #expect(repeated.graphURL == restored.graphURL)
            #expect(repeated.sharingMarkdown == original.sharingMarkdown)
            #expect(try vault.loadNotes().count == 1)
        }
    }
}
