import CryptoKit
import Foundation

nonisolated struct PortableKnowledgeEntry: Codable, Equatable, Sendable {
    let title: String
    let folder: String?
    let markdown: String

    var displayTitle: String { folder.map { $0 + " / " + title } ?? title }
}

nonisolated enum PortableKnowledgeArchiveError: LocalizedError, Equatable {
    case selectionCount
    case invalidNote
    case oversized
    case changedSelection
    case invalidCode
    case unreadableArchive
    case authenticationFailed
    case nonlocalArchive

    var errorDescription: String? {
        switch self {
        case .selectionCount: "Select between 1 and \(PortableKnowledgeArchive.maximumNotes) notes."
        case .invalidNote: "A selected note has invalid text or exceeds the per-note size limit."
        case .oversized: "The archive exceeds the 1 MiB content limit. Select fewer notes."
        case .changedSelection: "A selected note changed or was removed. Review the current notes and select them again."
        case .invalidCode: "Enter the complete recovery code that starts with RELAY1-."
        case .unreadableArchive: "This file is not a supported Relay knowledge archive."
        case .authenticationFailed: "The recovery code does not match, or the archive was changed or damaged."
        case .nonlocalArchive: "Choose a downloaded archive on a local volume."
        }
    }
}

nonisolated enum PortableKnowledgeArchive {
    static let maximumNotes = 32
    static let maximumNoteBytes = 65_536
    private static let maximumPayloadBytes = 1_048_576
    private static let header = Data("RELAY-KNOWLEDGE-1\n".utf8)
    private static let sealedOverhead = 12 + 16 // CryptoKit’s default GCM nonce and tag.
    static let maximumArchiveBytes = maximumPayloadBytes + header.count + sealedOverhead
    private static let codePrefix = "RELAY1-"

    struct Sealed: Sendable {
        let recoveryCode: String
        private let encryptedBytes: Data

        fileprivate init(recoveryCode: String, encryptedBytes: Data) {
            self.recoveryCode = recoveryCode
            self.encryptedBytes = encryptedBytes
        }

        func write(to url: URL) throws {
            try LocalPrivateFileWriter.write(data: encryptedBytes, to: url,
                                             maximumBytes: PortableKnowledgeArchive.maximumArchiveBytes,
                                             createOnly: true)
        }
    }

    private struct Payload: Codable {
        let notes: [PortableKnowledgeEntry]
    }

    /// Re-read approved note identities and compare the exact bytes before sealing.
    /// Paths are only used locally to find the note. They are never serialized.
    @MainActor static func currentEntries(selected: [LocalMarkdownNote], in current: [LocalMarkdownNote]) throws -> [PortableKnowledgeEntry] {
        guard (1...maximumNotes).contains(selected.count),
              Set(selected.map(\.url)).count == selected.count else { throw PortableKnowledgeArchiveError.selectionCount }
        return try selected.map { approved in
            guard let fresh = current.first(where: { $0.url == approved.url }),
                  fresh.folderName == approved.folderName,
                  Data(fresh.sharingMarkdown.utf8) == Data(approved.sharingMarkdown.utf8) else {
                throw PortableKnowledgeArchiveError.changedSelection
            }
            return PortableKnowledgeEntry(title: fresh.title, folder: fresh.folderName, markdown: fresh.sharingMarkdown)
        }
    }

    static func seal(_ notes: [PortableKnowledgeEntry]) throws -> Sealed {
        try validate(notes)
        let payload = try JSONEncoder().encode(Payload(notes: notes))
        guard payload.count <= maximumPayloadBytes else { throw PortableKnowledgeArchiveError.oversized }

        // A new 256-bit key and random default GCM nonce are generated for every export.
        // The version header is authenticated. Only combined ciphertext reaches the writer.
        let key = SymmetricKey(size: .bits256)
        let box = try AES.GCM.seal(payload, using: key, authenticating: header)
        guard let combined = box.combined else { throw PortableKnowledgeArchiveError.unreadableArchive }
        let code = key.withUnsafeBytes { recoveryCode(for: Data($0)) }
        return Sealed(recoveryCode: code, encryptedBytes: header + combined)
    }

    static func open(at url: URL, recoveryCode: String) throws -> [PortableKnowledgeEntry] {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else {
            throw PortableKnowledgeArchiveError.nonlocalArchive
        }
        let bytes = try LocalStateFile.read(url, maximumBytes: maximumArchiveBytes)
        return try open(bytes, recoveryCode: recoveryCode)
    }

    static func open(_ encrypted: Data, recoveryCode: String) throws -> [PortableKnowledgeEntry] {
        guard encrypted.count > header.count + sealedOverhead,
              encrypted.count <= maximumArchiveBytes, encrypted.starts(with: header) else {
            throw PortableKnowledgeArchiveError.unreadableArchive
        }
        let key = try key(from: recoveryCode)
        let payload: Data
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted.dropFirst(header.count))
            payload = try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw PortableKnowledgeArchiveError.authenticationFailed
        }

        // Authentication happens before JSON decoding or presentation. No note is extracted.
        guard payload.count <= maximumPayloadBytes,
              let decoded = try? JSONDecoder().decode(Payload.self, from: payload) else {
            throw PortableKnowledgeArchiveError.unreadableArchive
        }
        try validate(decoded.notes)
        return decoded.notes
    }

    private static func validate(_ notes: [PortableKnowledgeEntry]) throws {
        guard (1...maximumNotes).contains(notes.count) else { throw PortableKnowledgeArchiveError.selectionCount }
        var total = 0
        for note in notes {
            guard !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  note.title.utf8.count <= 255, !note.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !note.markdown.isEmpty, !note.markdown.contains("\0"), note.markdown.utf8.count <= maximumNoteBytes else {
                throw PortableKnowledgeArchiveError.invalidNote
            }
            if let folder = note.folder {
                guard !folder.isEmpty, folder.utf8.count <= 120, !folder.hasPrefix("."),
                      !folder.contains("/"), !folder.contains(":"),
                      !folder.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw PortableKnowledgeArchiveError.invalidNote
                }
                total += folder.utf8.count
            }
            total += note.title.utf8.count + note.markdown.utf8.count
            guard total <= maximumPayloadBytes else { throw PortableKnowledgeArchiveError.oversized }
        }
    }

    private static func recoveryCode(for bytes: Data) -> String {
        codePrefix + bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func key(from entered: String) throws -> SymmetricKey {
        guard entered.utf8.count <= 128 else { throw PortableKnowledgeArchiveError.invalidCode }
        let code = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = code.dropFirst(codePrefix.count)
        guard code.hasPrefix(codePrefix), encoded.utf8.count == 43,
              encoded.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                                       (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32, recoveryCode(for: bytes) == code else {
            throw PortableKnowledgeArchiveError.invalidCode
        }
        return SymmetricKey(data: bytes)
    }
}
