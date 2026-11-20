import Foundation
import Testing
@testable import Relay

@MainActor
struct KnowledgeDraftRecoveryTests {
    private func fixture() throws -> (URL, KnowledgeVaultManager, KnowledgeDraftStore) {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("relay-draft-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let vault = KnowledgeVaultManager(directoryURL: container.appendingPathComponent("Vault", isDirectory: true))
        _ = try vault.loadNotes()
        return (container, vault, KnowledgeDraftStore(vaultDirectory: vault.vaultDirectory))
    }

    @Test func restartRetainsExactFolderIdentityAndNewestEditWithoutSavingTheNote() throws {
        let (container, vault, drafts) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        _ = try vault.createFolder(named: "Plans")
        let first = try vault.saveNote(title: "Same title", body: "Original root")
        let nested = try vault.saveNote(title: "Same title", body: "Original nested", folder: "Plans")
        _ = try drafts.checkpoint(note: nested, title: "Edited title", body: "First change")
        let last = try #require(try drafts.checkpoint(note: nested, title: "Edited title", body: "Final café\n[[Project]]"))
        let restarted = KnowledgeDraftStore(vaultDirectory: vault.vaultDirectory)
        let records = try restarted.load().records
        #expect(records == [last])
        #expect(records[0].graphURL == nested.graphURL && records[0].graphURL != first.graphURL)
        let original = try #require(restarted.matchingOriginal(for: records[0], notes: try vault.loadNotes()))
        #expect(original.body == "Original nested")
        #expect(try vault.loadNotes().count == 2)
        #expect(!restarted.directoryURL.path.hasPrefix(vault.vaultDirectory.path + "/"))
        let permissions = try FileManager.default.attributesOfItem(atPath: restarted.directoryURL.appendingPathComponent(last.id + ".json").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func changedSourceCannotBeAdoptedAndRecoveryCopyPreservesBothVersions() throws {
        let (container, vault, drafts) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let note = try vault.saveNote(title: "Plan", body: "Original")
        let record = try #require(try drafts.checkpoint(note: note, title: "Plan edits", body: "Unsaved changes"))
        let changed = try vault.saveNote(title: "Plan", body: "Changed elsewhere", replacing: note)
        #expect(drafts.sourceState(for: record, notes: try vault.loadNotes()) == .changed)
        #expect(drafts.matchingOriginal(for: record, notes: try vault.loadNotes()) == nil)
        let copy = try drafts.saveRecoveredCopy(record, title: record.title, body: record.body, vault: vault)
        #expect(copy.graphURL != note.graphURL && copy.body == "Unsaved changes")
        let all = try vault.loadNotes()
        #expect(all.first(where: { $0.graphURL == changed.graphURL })?.body == "Changed elsewhere")
        #expect(all.count == 2)
        #expect(try drafts.load().records.isEmpty)
    }

    @Test func missingSourceRecoveryCreatesNewIdentityAndDoesNotResurrectOldPath() throws {
        let (container, vault, drafts) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let note = try vault.saveNote(title: "Plan", body: "Original")
        let record = try #require(try drafts.checkpoint(note: note, title: "Plan", body: "Keep me"))
        try FileManager.default.removeItem(at: note.url)
        #expect(drafts.sourceState(for: record, notes: try vault.loadNotes()) == .missing)
        let copy = try drafts.saveRecoveredCopy(record, title: record.title, body: record.body, vault: vault)
        #expect(copy.url != note.url && copy.body == "Keep me")
        #expect(!FileManager.default.fileExists(atPath: note.url.path))
    }

    @Test func invalidSaveOrOversizedCheckpointRetainsPreviouslyCommittedDraft() throws {
        let (container, vault, drafts) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let note = try vault.saveNote(title: "Plan", body: "Original")
        let record = try #require(try drafts.checkpoint(note: note, title: "Plan", body: "Last safe checkpoint"))
        #expect(throws: (any Error).self) {
            _ = try drafts.saveRecoveredCopy(record, title: "", body: "Unsaved", vault: vault)
        }
        #expect(throws: (any Error).self) {
            _ = try drafts.checkpoint(note: note, title: "Plan", body: String(repeating: "x", count: 524_289))
        }
        #expect(try drafts.load().records == [record])
        #expect(try vault.loadNotes().first?.body == "Original")
    }

    @Test func undoToOriginalAndExplicitDiscardClearOnlyTheirExactDraft() throws {
        let (container, vault, drafts) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let a = try vault.saveNote(title: "A", body: "Original A")
        let b = try vault.saveNote(title: "B", body: "Original B")
        _ = try drafts.checkpoint(note: a, title: "A", body: "Draft A")
        let recordB = try #require(try drafts.checkpoint(note: b, title: "B", body: "Draft B"))
        #expect(try drafts.checkpoint(note: a, title: a.title, body: a.body) == nil)
        #expect(try drafts.load().records == [recordB])
        try drafts.discard(recordB)
        #expect(try drafts.load().records.isEmpty)
        #expect(try vault.loadNotes().count == 2)
    }

    @Test func unreadableCheckpointDoesNotHideValidSiblingOrDestroyItsBytes() throws {
        let (container, vault, drafts) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let note = try vault.saveNote(title: "Plan", body: "Original")
        let record = try #require(try drafts.checkpoint(note: note, title: "Plan", body: "Keep me"))
        let corruptURL = drafts.directoryURL.appendingPathComponent("broken.json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: corruptURL)
        let loaded = try drafts.load()
        #expect(loaded.records == [record] && loaded.unreadableCount == 1)
        #expect(try Data(contentsOf: corruptURL) == corrupt)
    }

    @Test func recoveryDirectorySymlinkFailsClosedAndKeepsOriginalUntouched() throws {
        let (container, vault, drafts) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let note = try vault.saveNote(title: "Plan", body: "Original")
        let elsewhere = container.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: drafts.directoryURL, withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { _ = try drafts.checkpoint(note: note, title: "Plan", body: "Private edit") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect(try vault.loadNotes().first?.body == "Original")
    }

    @Test func draftFromDifferentVaultCannotBeSavedIntoAnUnrelatedVault() throws {
        let (container, vault, drafts) = try fixture()
        defer { try? FileManager.default.removeItem(at: container) }
        let other = KnowledgeVaultManager(directoryURL: container.appendingPathComponent("Other", isDirectory: true))
        _ = try other.loadNotes()
        let note = try vault.saveNote(title: "Plan", body: "Original")
        let record = try #require(try drafts.checkpoint(note: note, title: "Plan", body: "Keep me"))
        #expect(throws: (any Error).self) {
            _ = try drafts.saveRecoveredCopy(record, title: record.title, body: record.body, vault: other)
        }
        #expect(try other.loadNotes().isEmpty)
        #expect(try drafts.load().records == [record])
    }
}
