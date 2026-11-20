import Foundation
import CryptoKit

/// Private recovery checkpoints are distinct from saved notes and never confer
/// execution authority. Each inline edit is committed before its binding returns.
@MainActor
final class KnowledgeDraftStore {
    nonisolated struct Record: Codable, Equatable, Identifiable, Sendable {
        let version: Int
        let relativePath: String
        let graphURL: URL
        let originalDigest: String
        let originalTitle: String
        var title: String
        var body: String
        var updatedAt: Date

        var id: String { KnowledgeDraftStore.key(relativePath) }
    }

    enum SourceState: Equatable { case unchanged, changed, missing }
    struct Loaded {
        let records: [Record]
        let unreadableCount: Int
    }

    static let maximumBytes = 1_048_576
    private let vaultDirectory: URL
    var directoryURL: URL {
        vaultDirectory.deletingLastPathComponent().appendingPathComponent("." + vaultDirectory.lastPathComponent + ".relay-drafts", isDirectory: true)
    }

    init(vaultDirectory: URL) { self.vaultDirectory = vaultDirectory.standardizedFileURL.resolvingSymlinksInPath() }

    @discardableResult
    func checkpoint(note: LocalMarkdownNote, title: String, body: String) throws -> Record? {
        let relative = try relativePath(for: note)
        if title == note.title && body == note.body {
            try remove(relativePath: relative)
            return nil
        }
        let record = Record(version: 1, relativePath: relative, graphURL: note.graphURL,
                            originalDigest: Self.digest(note.sharingMarkdown), originalTitle: note.title,
                            title: title, body: body, updatedAt: Date())
        try write(record)
        return record
    }

    func update(_ record: Record, title: String, body: String) throws -> Record {
        var changed = record
        changed.title = title
        changed.body = body
        changed.updatedAt = Date()
        try write(changed)
        return changed
    }

    func load() throws -> Loaded {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return Loaded(records: [], unreadableCount: 0)
        }
        try requireDirectory(directoryURL)
        let entries = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard entries.count <= 100 else { throw RelayError.message("Too many recovery files. Existing drafts have been kept.") }
        var records: [Record] = []
        var unreadable = 0
        for url in entries {
            do {
                let data = try LocalStateFile.read(url, maximumBytes: Self.maximumBytes)
                let record = try JSONDecoder().decode(Record.self, from: data)
                try validate(record)
                guard url.lastPathComponent == record.id + ".json" else { throw RelayError.message("Draft identity mismatch.") }
                records.append(record)
            } catch { unreadable += 1 }
        }
        return Loaded(records: records.sorted { $0.updatedAt > $1.updatedAt }, unreadableCount: unreadable)
    }

    func sourceState(for record: Record, notes: [LocalMarkdownNote]) -> SourceState {
        guard let note = notes.first(where: { $0.graphURL == record.graphURL }),
              (try? relativePath(for: note)) == record.relativePath else { return .missing }
        return Self.digest(note.sharingMarkdown) == record.originalDigest ? .unchanged : .changed
    }

    func matchingOriginal(for record: Record, notes: [LocalMarkdownNote]) -> LocalMarkdownNote? {
        guard sourceState(for: record, notes: notes) == .unchanged else { return nil }
        return notes.first { $0.graphURL == record.graphURL }
    }

    func discard(_ record: Record) throws {
        try validate(record)
        try remove(relativePath: record.relativePath)
    }

    func discard(note: LocalMarkdownNote) throws { try remove(relativePath: relativePath(for: note)) }

    /// A changed/missing original can only yield a new note. Never replace or
    /// resurrect a deleted source implicitly, even when its title matches.
    func saveRecoveredCopy(_ record: Record, title: String, body: String, vault: KnowledgeVaultManager) throws -> LocalMarkdownNote {
        try validate(record)
        guard vault.vaultDirectory.standardizedFileURL.resolvingSymlinksInPath() == vaultDirectory else {
            throw RelayError.message("Choose the vault that owns this draft.")
        }
        let note = try vault.saveNote(title: title, body: body)
        // If cleanup fails the saved copy remains intact and the recovery file
        // remains visible. The UI reports that outcome instead of hiding it.
        do { try discard(record) }
        catch { throw RecoveredCopyCleanupError(savedNote: note, underlying: error) }
        return note
    }

    struct RecoveredCopyCleanupError: Error {
        let savedNote: LocalMarkdownNote
        let underlying: Error
    }

    private func write(_ record: Record) throws {
        try validate(record)
        try requireDirectory(vaultDirectory)
        try requireDirectory(vaultDirectory.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(directoryURL)
        let destination = directoryURL.appendingPathComponent(record.id + ".json")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let count = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).filter { $0.hasSuffix(".json") }.count
            guard count < 100 else { throw RelayError.message("Recovery storage is full. Existing drafts have been kept.") }
        }
        let data = try JSONEncoder().encode(record)
        try LocalPrivateFileWriter.write(data: data, to: destination, maximumBytes: Self.maximumBytes)
    }

    private func remove(relativePath: String) throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try requireDirectory(directoryURL)
        let file = directoryURL.appendingPathComponent(Self.key(relativePath) + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RelayError.message("The recovery file is not an ordinary local file. It was kept.")
        }
        try FileManager.default.removeItem(at: file)
    }

    private func relativePath(for note: LocalMarkdownNote) throws -> String {
        let source = note.url.standardizedFileURL
        let prefix = vaultDirectory.path + "/"
        guard source.path.hasPrefix(prefix), source.resolvingSymlinksInPath() == source else {
            throw RelayError.message("The draft's original is outside this vault.")
        }
        return String(source.path.dropFirst(prefix.count))
    }

    private func validate(_ record: Record) throws {
        let components = record.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let expected = components.reduce(URL(string: "relay-vault://note")!) { $0.appendingPathComponent(String($1).precomposedStringWithCanonicalMapping) }
        guard record.version == 1, (1...2).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }),
              components.last?.hasSuffix(".md") == true, record.graphURL == expected,
              record.relativePath.utf8.count <= 400, record.originalTitle.utf8.count <= 200,
              record.title.utf8.count <= 16_384,
              record.originalDigest.count == 64, record.originalDigest.allSatisfy({ $0.isHexDigit }),
              record.title.utf8.count + record.body.utf8.count <= 524_288,
              !record.title.contains("\0"), !record.body.contains("\0") else {
            throw RelayError.message("The recovery draft is invalid or too large. Existing saved content was not changed.")
        }
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL else {
            throw RelayError.message("Recovery storage must be an ordinary local directory.")
        }
    }

    nonisolated private static func key(_ relativePath: String) -> String { digest(relativePath) }
    nonisolated private static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
