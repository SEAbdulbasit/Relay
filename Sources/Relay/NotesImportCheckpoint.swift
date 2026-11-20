import CryptoKit
import Darwin
import Foundation

/// Each ordinary 0600 file atomically contains BOTH one item's decoded result
/// and its progress key. There is no separately advanced high-water cursor.
/// Restoring this cache grants no source access: a new explicit backup read
/// must establish the same whole-file identity and actual row/blob key first.
nonisolated struct NotesImportCheckpoint {
    enum Event: Sendable { case willCommit, didCommit }
    typealias Observer = @Sendable (Event) throws -> Void
    enum Disposition: String, Codable, Sendable { case decoded, empty, undownloaded, oversized, malformed }
    struct Key: Codable, Equatable, Sendable {
        let noteID: String
        let created: Double
        let blobDigest: String
        static func == (a: Self, b: Self) -> Bool {
            Data(a.noteID.utf8) == Data(b.noteID.utf8) && a.created == b.created && a.blobDigest == b.blobDigest
        }
    }
    struct Value: Codable, Sendable {
        let version: Int
        let sourceIdentity: String
        let key: Key
        let disposition: Disposition
        let text: String?
        let textDigest: String?
        let limited: Bool
    }
    let root: URL
    let sourceIdentity: String
    let observer: Observer?
    // JSON can expand each admitted UTF-8 control byte to six ASCII bytes.
    // Source text remains capped at 8 KiB; this is its encoded record bound.
    static let maximumRecordBytes = 65_536

    func load(_ key: Key) throws -> Value? {
        let file = try location(key, creating: false)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try LocalStateFile.read(file, maximumBytes: Self.maximumRecordBytes)
        guard let value = try? JSONDecoder().decode(Value.self, from: data),
              value.version == NotesBodyDecoder.version, value.sourceIdentity == sourceIdentity,
              value.key == key, value.key.created.isFinite else { throw NotesDatabaseIngestion.Failure.checkpoint }
        if value.disposition == .decoded || value.disposition == .empty {
            guard let text = value.text, text.utf8.count <= NotesBodyDecoder.maximumTextBytes,
                  !text.contains("\0"), value.textDigest == Self.digest(Data(text.utf8)),
                  (value.disposition == .empty) == text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NotesDatabaseIngestion.Failure.checkpoint
            }
        } else {
            guard value.text == nil, value.textDigest == nil, !value.limited else { throw NotesDatabaseIngestion.Failure.checkpoint }
        }
        return value
    }

    func commit(key: Key, disposition: Disposition, text: NotesBodyDecoder.Text? = nil) throws -> Value {
        try Task.checkCancellation()
        let value = Value(version: NotesBodyDecoder.version, sourceIdentity: sourceIdentity, key: key,
            disposition: disposition, text: text?.value,
            textDigest: text.map { Self.digest(Data($0.value.utf8)) }, limited: text?.limited ?? false)
        let data = try JSONEncoder().encode(value)
        let file = try location(key, creating: true)
        try observer?(.willCommit)
        try Task.checkCancellation()
        try LocalPrivateFileWriter.write(data: data, to: file, maximumBytes: Self.maximumRecordBytes)
        // A lost acknowledgement here leaves the actual complete item+key on
        // disk. A fresh explicit same-source import finds it; no split marker.
        try observer?(.didCommit)
        return value
    }

    private func location(_ key: Key, creating: Bool) throws -> URL {
        guard Self.isDigest(sourceIdentity),
              !key.noteID.isEmpty, key.noteID.utf8.count <= 512, key.created.isFinite else {
            throw NotesDatabaseIngestion.Failure.checkpoint
        }
        if creating { try Self.ensureDirectory(root) }
        else if FileManager.default.fileExists(atPath: root.path) { try Self.requireDirectory(root) }
        let directory = root.appending(path: sourceIdentity, directoryHint: .isDirectory)
        if creating {
            let sources = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard sources.count < 16 || sources.contains(where: { $0.lastPathComponent == sourceIdentity }) else {
                throw NotesDatabaseIngestion.Failure.checkpoint
            }
            try Self.ensureDirectory(directory)
        } else if FileManager.default.fileExists(atPath: directory.path) { try Self.requireDirectory(directory) }
        return directory.appending(path: Self.digest(Data(key.noteID.utf8)) + ".json")
    }

    static func ensureDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(url)
    }
    private static func requireDirectory(_ url: URL) throws {
        var value = stat()
        guard url.isFileURL, url.path.withCString({ lstat($0, &value) }) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), value.st_uid == getuid(),
              value.st_mode & mode_t(0o077) == 0, value.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw NotesDatabaseIngestion.Failure.checkpoint
        }
    }

    /// Only this dedicated private cache is removed; original backups are never
    /// touched. Refuse unexpected links/subtrees instead of traversing them.
    static func forget(_ root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try requireDirectory(root)
        let sources = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard sources.count <= 16 else { throw NotesDatabaseIngestion.Failure.checkpoint }
        for source in sources {
            guard isDigest(source.lastPathComponent) else {
                throw NotesDatabaseIngestion.Failure.checkpoint
            }
            try requireDirectory(source)
            let entries = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            guard entries.count <= NotesDatabaseIngestion.maximumNotes else { throw NotesDatabaseIngestion.Failure.checkpoint }
            for entry in entries {
                guard entry.pathExtension == "json", isDigest(entry.deletingPathExtension().lastPathComponent) else {
                    throw NotesDatabaseIngestion.Failure.checkpoint
                }
                // Cleanup inspects only owned entry metadata, never decodes or
                // restores private note text just to offer Forget after relaunch.
                var metadata = stat()
                guard entry.path.withCString({ lstat($0, &metadata) }) == 0,
                      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == getuid(),
                      metadata.st_mode & mode_t(0o077) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0,
                      metadata.st_size >= 0, metadata.st_size <= Int64(maximumRecordBytes) else {
                    throw NotesDatabaseIngestion.Failure.checkpoint
                }
            }
        }
        try FileManager.default.removeItem(at: root)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
