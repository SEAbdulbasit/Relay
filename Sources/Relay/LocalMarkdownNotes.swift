import Foundation

struct LocalMarkdownFolder: Identifiable, Equatable {
    static let domainPrefix = "Local folder: "
    var id: String { name }
    let name: String

    var graphDomain: String { Self.domainPrefix + name }

    static func displayName(for domain: String) -> String {
        domain.hasPrefix(domainPrefix) ? String(domain.dropFirst(domainPrefix.count)) : domain
    }
}

struct LocalMarkdownNote: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    var graphURL: URL {
        let base = URL(string: "relay-vault://note")!
        let group = folderName.map { base.appendingPathComponent($0.precomposedStringWithCanonicalMapping) } ?? base
        return group.appendingPathComponent(url.lastPathComponent)
    }
    let folderName: String?
    let title: String
    let body: String
    fileprivate let markdown: String
    var sharingMarkdown: String { markdown }

    fileprivate init(url: URL, markdown: String, folderName: String?) {
        self.url = url
        self.folderName = folderName
        self.markdown = markdown
        let firstLineEnd = markdown.firstIndex(where: \.isNewline) ?? markdown.endIndex
        let heading = markdown[..<firstLineEnd]
        if heading.hasPrefix("# "), !heading.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty {
            title = String(heading.dropFirst(2))
            let afterHeading = markdown[firstLineEnd...].dropFirst()
            body = String(afterHeading.first?.isNewline == true ? afterHeading.dropFirst() : afterHeading)
        } else {
            title = url.deletingPathExtension().lastPathComponent
            body = markdown
        }
    }
}

extension KnowledgeVaultManager {
    static let maximumNoteBytes = 65_536
    private static let maximumNotes = 100
    private static let maximumFolders = 32

    func loadFolders() throws -> [LocalMarkdownFolder] {
        try loadFolders(in: notesDirectory())
    }

    @discardableResult
    func createFolder(named requestedName: String) throws -> LocalMarkdownFolder {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeFolderName(name) else {
            throw RelayError.message("Enter a folder name up to 120 UTF-8 bytes, without a leading dot, slash or control character.")
        }
        let root = try notesDirectory()
        guard try loadFolders(in: root).count < Self.maximumFolders else {
            throw RelayError.message("Relay supports up to \(Self.maximumFolders) local note folders.")
        }
        let directory = root.appending(path: name, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch CocoaError.fileWriteFileExists {
            throw RelayError.message("That folder or file already exists.")
        }
        return LocalMarkdownFolder(name: name)
    }

    func loadNotes() throws -> [LocalMarkdownNote] {
        let root = try notesDirectory()
        let containers: [(name: String?, directory: URL)] = [(nil, root)] + (try loadFolders(in: root)).compactMap { folder in
            guard let directory = try? noteFolder(folder.name, in: root) else { return nil }
            return (folder.name, directory)
        }
        var notes: [LocalMarkdownNote] = []
        for container in containers {
            guard let items = FileManager.default.enumerator(at: container.directory, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
                throw RelayError.message("A local notes folder could not be read.")
            }
            for case let item as URL in items {
                guard isNoteFile(item, in: container.directory) else { continue }
                // Foundation may spell the same parent as /var or /private/var during enumeration.
                let url = container.directory.appending(path: item.lastPathComponent)
                guard let markdown = try? readNote(url) else { continue }
                notes.append(LocalMarkdownNote(url: url, markdown: markdown, folderName: container.name))
                if notes.count == Self.maximumNotes { break }
            }
            if notes.count == Self.maximumNotes { break }
        }
        return notes.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    @discardableResult
    func saveNote(title: String, body: String, replacing original: LocalMarkdownNote? = nil,
                  folder requestedFolder: String? = nil) throws -> LocalMarkdownNote {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 200, !name.contains(where: { $0.isNewline || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw RelayError.message("Enter a single-line title of up to 200 UTF-8 bytes.")
        }
        guard !body.contains("\0") else { throw RelayError.message("Notes must be ordinary Markdown text.") }
        let root = try notesDirectory()
        let folder = original == nil ? requestedFolder : original?.folderName
        let directory = try folder.map { try noteFolder($0, in: root) } ?? root
        let url: URL
        if let original {
            url = original.url
            guard isNoteFile(url, in: directory), let current = try? readNote(url), Data(current.utf8) == Data(original.markdown.utf8) else {
                throw RelayError.message("This note changed on disk. Keep a copy of your edits, then reopen the note.")
            }
        } else {
            guard try loadNotes().count < Self.maximumNotes else {
                throw RelayError.message("The vault can hold up to \(Self.maximumNotes) notes in Relay.")
            }
            url = directory.appending(path: "\(UUID().uuidString).md")
        }
        let markdown = "# \(name)\n\n\(body)"
        try LocalPrivateFileWriter.write(data: Data(markdown.utf8), to: url, maximumBytes: Self.maximumNoteBytes,
                                         createOnly: original == nil)
        return LocalMarkdownNote(url: url, markdown: markdown, folderName: folder)
    }

    private func notesDirectory() throws -> URL {
        let directory = vaultDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RelayError.message("The local notes folder must be an ordinary directory.")
        }
        return directory.resolvingSymlinksInPath()
    }

    private func loadFolders(in root: URL) throws -> [LocalMarkdownFolder] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return Array(names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .lazy.filter { (try? self.noteFolder($0, in: root)) != nil }
            .prefix(Self.maximumFolders)
            .map { LocalMarkdownFolder(name: $0) })
    }

    private func noteFolder(_ name: String, in root: URL) throws -> URL {
        guard Self.isSafeFolderName(name) else { throw RelayError.message("Invalid local note folder.") }
        let directory = root.appending(path: name, directoryHint: .isDirectory)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true else {
            throw RelayError.message("The note folder is no longer an ordinary local folder.")
        }
        return directory
    }

    private static func isSafeFolderName(_ name: String) -> Bool {
        let packageExtensions = ["app", "bundle", "framework", "plugin", "pkg", "xcworkspace", "xcodeproj"]
        return !name.isEmpty && name.utf8.count <= 120 && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":") &&
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            !packageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private func isNoteFile(_ url: URL, in directory: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == directory.path &&
            url.pathExtension.lowercased() == "md" &&
            url.lastPathComponent.lowercased() != "writingstyle.md" &&
            !url.lastPathComponent.hasPrefix(".")
    }

    private func readNote(_ url: URL) throws -> String {
        let data = try LocalStateFile.read(url, maximumBytes: Self.maximumNoteBytes)
        guard let markdown = String(data: data, encoding: .utf8), !markdown.contains("\0") else {
            throw RelayError.message("This note is not valid UTF-8 Markdown.")
        }
        return markdown
    }
}

extension Array where Element == LocalMarkdownNote {
    var graphNotes: [URL: (title: String, domain: String, body: String)] {
        Dictionary(uniqueKeysWithValues: map { note in
            let domain = note.folderName.map { LocalMarkdownFolder(name: $0).graphDomain } ?? "Your Notes"
            return (note.graphURL, (title: note.title, domain: domain, body: note.markdown))
        })
    }
}

/// A user-requested snapshot of a single indexed source. The excerpt is literal text so
/// embedded Markdown, images, and links cannot be mistaken for generated note content.
enum IndexedSourceMarkdown {
    static func data(for record: KnowledgeRecord) -> Data {
        let metadata = """
            Source title: \(record.title.debugDescription)
            Original source: \(record.sourcePath.debugDescription)
            Source modified: \(record.modifiedAt.ISO8601Format())
            SHA-256 of source: \(record.contentHash)
            Coverage: \(record.coverageNote ?? "Extracted text within Relay’s index limits.")
            """
        var longestTildeRun = 0
        var tildeRun = 0
        for character in metadata + "\n" + record.text {
            tildeRun = character == "~" ? tildeRun + 1 : 0
            longestTildeRun = max(tildeRun, longestTildeRun)
        }
        let fence = String(repeating: "~", count: max(3, longestTildeRun + 1))
        return Data("""
            # Indexed source

            \(fence)text
            \(metadata)
            \(fence)

            ## Indexed excerpt

            \(fence)text
            \(record.text)
            \(fence)

            """.utf8)
    }
}
