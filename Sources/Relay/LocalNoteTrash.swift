import Foundation

nonisolated struct LocalNoteTrashEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let deletedAt: Date
    let originalRelativePath: String
}

/// Notes remain local and recoverable. No expiry or automatic purge is applied.
extension KnowledgeVaultManager {
    @discardableResult
    func trashNote(_ note: LocalMarkdownNote) throws -> LocalNoteTrashEntry {
        let root = try checkedTrashVaultRoot()
        let original = note.url.standardizedFileURL
        let relative = try noteRelativePath(original, root: root)
        let source = try checkedOriginalNote(relative, root: root, createFolder: false)
        let data = try LocalStateFile.read(source, maximumBytes: Self.maximumNoteBytes)
        guard data == Data(note.sharingMarkdown.utf8) else {
            throw RelayError.message("This note changed on disk. Reopen it before moving it to Trash.")
        }
        let trash = try checkedNoteTrashDirectory(root: root)
        guard try FileManager.default.contentsOfDirectory(atPath: trash.path).count < 1_000 else {
            throw RelayError.message("Recently deleted notes is full. Manage the vault’s sibling recovery folder before moving more notes to Trash.")
        }
        var displayTitle = String(note.title.prefix(200))
        while displayTitle.utf8.count > 200 { displayTitle.removeLast() }
        let entry = LocalNoteTrashEntry(id: UUID(), title: displayTitle, deletedAt: Date(), originalRelativePath: relative)
        let bundle = trash.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try LocalPrivateFileWriter.write(data: JSONEncoder().encode(entry), to: bundle.appendingPathComponent("entry.json"), maximumBytes: 4_096, createOnly: true)
            // Same-volume rename leaves the original intact if the move fails.
            try FileManager.default.moveItem(at: source, to: bundle.appendingPathComponent("note.md"))
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            throw error
        }
        return entry
    }

    func trashedNotes() throws -> [LocalNoteTrashEntry] {
        let listing = try noteTrashListing()
        guard listing.unreadableCount == 0 else {
            throw RelayError.message("Some deleted notes could not be inspected. Open Recently deleted notes to restore readable entries. Recovery files have been kept.")
        }
        return listing.entries
    }

    func noteTrashListing() throws -> (entries: [LocalNoteTrashEntry], unreadableCount: Int) {
        let root = try checkedTrashVaultRoot()
        let trash = try checkedNoteTrashDirectory(root: root)
        let bundles = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        var entries: [LocalNoteTrashEntry] = []
        var unreadableCount = 0
        for bundle in bundles {
            do { entries.append(try readTrashEntry(at: bundle, root: root)) }
            catch { unreadableCount += 1 }
        }
        return (entries.sorted { $0.deletedAt > $1.deletedAt }, unreadableCount)
    }

    @discardableResult
    func restoreNote(_ entry: LocalNoteTrashEntry) throws -> LocalMarkdownNote {
        let root = try checkedTrashVaultRoot()
        let trash = try checkedNoteTrashDirectory(root: root)
        let bundle = trash.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let stored = try readTrashEntry(at: bundle, root: root)
        guard stored == entry else { throw RelayError.message("This deleted note changed. Reopen Recently deleted notes and try again.") }
        guard try loadNotes().count < Self.maximumNotes else {
            throw RelayError.message("The vault is full. Move another note to Trash before restoring this one.")
        }
        let data = try LocalStateFile.read(bundle.appendingPathComponent("note.md"), maximumBytes: Self.maximumNoteBytes)
        guard let markdown = String(data: data, encoding: .utf8), !markdown.contains("\0") else {
            throw RelayError.message("The deleted note is not valid Markdown. Its saved bytes remain in the local Trash.")
        }
        let target = try checkedOriginalNote(entry.originalRelativePath, root: root, createFolder: true)
        // Create-only also refuses a dangling symlink or a file created after the check.
        try LocalPrivateFileWriter.write(data: data, to: target, maximumBytes: Self.maximumNoteBytes, createOnly: true)
        let components = entry.originalRelativePath.split(separator: "/")
        let restored = LocalMarkdownNote(url: target, markdown: markdown, folderName: components.count == 2 ? String(components[0]) : nil)
        // The note is already restored if housekeeping fails. Preserve the bundle
        // rather than undoing a successful restoration or overwriting anything.
        try? FileManager.default.removeItem(at: bundle)
        return restored
    }

    private func checkedTrashVaultRoot() throws -> URL {
        let root = vaultDirectory.standardizedFileURL
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try requireOrdinaryDirectory(root)
        return root.resolvingSymlinksInPath()
    }

    private func checkedNoteTrashDirectory(root: URL) throws -> URL {
        let directory = root.deletingLastPathComponent().appendingPathComponent("." + root.lastPathComponent + ".relay-trash", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try requireOrdinaryDirectory(directory)
        return directory
    }

    private func requireOrdinaryDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RelayError.message("The local notes and Trash folders must be ordinary directories.")
        }
    }

    private func noteRelativePath(_ url: URL, root: URL) throws -> String {
        guard url.path.hasPrefix(root.path + "/") else { throw RelayError.message("This note is outside the local vault.") }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        _ = try checkedOriginalNote(relative, root: root, createFolder: false)
        return relative
    }

    private func checkedOriginalNote(_ relative: String, root: URL, createFolder: Bool) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains(":") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              let leaf = parts.last, leaf.utf8.count <= 255, (leaf as NSString).pathExtension.lowercased() == "md", leaf.lowercased() != "writingstyle.md" else {
            throw RelayError.message("The deleted note has an invalid original location.")
        }
        var directory = root
        if parts.count == 2 {
            guard parts[0].utf8.count <= 120, !["app", "bundle", "framework", "plugin", "pkg", "xcworkspace", "xcodeproj"].contains((parts[0] as NSString).pathExtension.lowercased()) else {
                throw RelayError.message("The deleted note has an invalid folder.")
            }
            directory = root.appendingPathComponent(parts[0], isDirectory: true)
            if createFolder, !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try requireOrdinaryDirectory(directory)
        }
        return directory.appendingPathComponent(leaf)
    }

    private func readTrashEntry(at bundle: URL, root: URL) throws -> LocalNoteTrashEntry {
        try requireOrdinaryDirectory(bundle)
        let entry = try JSONDecoder().decode(LocalNoteTrashEntry.self, from: LocalStateFile.read(bundle.appendingPathComponent("entry.json"), maximumBytes: 4_096))
        guard entry.id.uuidString == bundle.lastPathComponent, entry.title.utf8.count <= 200 else {
            throw RelayError.message("A deleted note's recovery information is invalid. Its files remain in the local Trash.")
        }
        // Validate syntax without requiring a folder that may since have been removed.
        let relative = entry.originalRelativePath
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains(":") }),
              parts.last.map({ (String($0) as NSString).pathExtension.lowercased() == "md" && $0.lowercased() != "writingstyle.md" }) == true else {
            throw RelayError.message("A deleted note's original location is invalid.")
        }
        _ = try LocalStateFile.read(bundle.appendingPathComponent("note.md"), maximumBytes: Self.maximumNoteBytes)
        return entry
    }
}
