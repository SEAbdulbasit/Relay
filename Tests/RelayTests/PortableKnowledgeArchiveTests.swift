import CryptoKit
import Foundation
import Testing
@testable import Relay

@MainActor
struct PortableKnowledgeArchiveTests {
    @Test func encryptedFileRoundTripsExactMarkdownWithoutWritingPlaintext() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "PRIVATE_SYNTHETIC_NOTE_SENTINEL"
        let entries = [
            PortableKnowledgeEntry(title: "Café notes", folder: "Project 🌍",
                                   markdown: "# Café notes\n\n\(marker)\n- [[Other note]]\n"),
            PortableKnowledgeEntry(title: "Other note", folder: nil, markdown: "# Other note\n\n日本語")
        ]
        let archive = try PortableKnowledgeArchive.seal(entries)
        let path = directory.appending(path: "work.relaynotes")
        try archive.write(to: path)
        let bytes = try Data(contentsOf: path)
        #expect(bytes.range(of: Data(marker.utf8)) == nil)
        #expect(bytes.range(of: Data(archive.recoveryCode.utf8)) == nil)
        #expect(archive.recoveryCode.hasPrefix("RELAY1-"))
        #expect(archive.recoveryCode.utf8.count == 50)
        #expect(try PortableKnowledgeArchive.open(at: path, recoveryCode: " \(archive.recoveryCode)\n") == entries)

        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["work.relaynotes"])

        let second = try PortableKnowledgeArchive.seal(entries)
        #expect(second.recoveryCode != archive.recoveryCode)
        #expect(throws: LocalPrivateFileWriteError.destinationChanged) { try second.write(to: path) }
        #expect(try Data(contentsOf: path) == bytes)
    }

    @Test func wrongRecoveryCodeAndTamperedOrTruncatedArchivesFailClosed() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = PortableKnowledgeEntry(title: "Fixture", folder: nil, markdown: "# Fixture\n\nEncrypted test")
        let archive = try PortableKnowledgeArchive.seal([note])
        let different = try PortableKnowledgeArchive.seal([note])
        let path = directory.appending(path: "fixture.relaynotes")
        try archive.write(to: path)
        let bytes = try Data(contentsOf: path)
        #expect(throws: PortableKnowledgeArchiveError.authenticationFailed) {
            try PortableKnowledgeArchive.open(bytes, recoveryCode: different.recoveryCode)
        }
        #expect(throws: PortableKnowledgeArchiveError.invalidCode) {
            try PortableKnowledgeArchive.open(bytes, recoveryCode: archive.recoveryCode + "=")
        }
        var changed = bytes
        changed[changed.count - 17] ^= 1
        #expect(throws: PortableKnowledgeArchiveError.authenticationFailed) {
            try PortableKnowledgeArchive.open(changed, recoveryCode: archive.recoveryCode)
        }
        var unknownFormat = bytes
        unknownFormat[unknownFormat.startIndex] ^= 1
        #expect(throws: PortableKnowledgeArchiveError.unreadableArchive) {
            try PortableKnowledgeArchive.open(unknownFormat, recoveryCode: archive.recoveryCode)
        }
        #expect(throws: PortableKnowledgeArchiveError.unreadableArchive) {
            try PortableKnowledgeArchive.open(bytes.prefix(12), recoveryCode: archive.recoveryCode)
        }
        let link = directory.appending(path: "linked.relaynotes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        #expect(throws: (any Error).self) {
            try PortableKnowledgeArchive.open(at: link, recoveryCode: archive.recoveryCode)
        }
    }

    @Test func refusesInvalidNoteBoundsEvenWhenAnArchiveAuthenticates() throws {
        let valid = PortableKnowledgeEntry(title: "Valid", folder: nil, markdown: "text")
        #expect(throws: PortableKnowledgeArchiveError.selectionCount) {
            try PortableKnowledgeArchive.seal(Array(repeating: valid, count: PortableKnowledgeArchive.maximumNotes + 1))
        }
        let large = PortableKnowledgeEntry(title: "Large", folder: nil,
                                          markdown: String(repeating: "a", count: PortableKnowledgeArchive.maximumNoteBytes))
        #expect(throws: PortableKnowledgeArchiveError.oversized) {
            try PortableKnowledgeArchive.seal(Array(repeating: large, count: 17))
        }
        let escaped = PortableKnowledgeEntry(title: "Escaping", folder: "../Outside", markdown: "text")
        #expect(throws: PortableKnowledgeArchiveError.invalidNote) { try PortableKnowledgeArchive.seal([escaped]) }

        let nonceHeader = Data("RELAY-KNOWLEDGE-1\n".utf8)
        let key = Data(repeating: 42, count: 32)
        let recovery = "RELAY1-" + key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let payload = try JSONSerialization.data(withJSONObject: [
            "notes": [["title": "Escaping", "folder": "../Outside", "markdown": "text"]]
        ])
        let combined = try #require(AES.GCM.seal(payload, using: SymmetricKey(data: key), authenticating: nonceHeader).combined)
        #expect(throws: PortableKnowledgeArchiveError.invalidNote) {
            try PortableKnowledgeArchive.open(nonceHeader + combined, recoveryCode: recovery)
        }
    }

    @Test func exportsOnlyTheUnchangedExplicitSelectionWithoutLocalPaths() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = KnowledgeVaultManager(directoryURL: directory)
        let selected = try vault.saveNote(title: "Chosen", body: "Include this.")
        _ = try vault.saveNote(title: "Private unselected", body: "Never include this.")
        let entries = try PortableKnowledgeArchive.currentEntries(selected: [selected], in: vault.loadNotes())
        #expect(entries.count == 1)
        #expect(entries.first?.title == "Chosen")
        #expect(entries.first?.markdown.contains(directory.path) == false)
        _ = try vault.saveNote(title: "Chosen", body: "Changed after selection.", replacing: selected)
        #expect(throws: PortableKnowledgeArchiveError.changedSelection) {
            try PortableKnowledgeArchive.currentEntries(selected: [selected], in: vault.loadNotes())
        }
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-portable-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
