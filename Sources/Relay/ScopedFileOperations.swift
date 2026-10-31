import CryptoKit
import Darwin
import Foundation

/// Selected local files only. No deletion, trash, directory moves, overwrite or executable action.
@MainActor
enum ScopedFileOperations {
    /// Metadata only: a filename match does not establish that cloud-backed bytes are local.
    struct SearchMatch: Sendable, Equatable { let path: String; let name: String; let bytes: Int }
    struct SearchResult: Sendable {
        let matches: [SearchMatch]
        let visitedEntries: Int
        let truncated: Bool
        let skippedSymlinks: Int
        let warnings: [String]
    }
    nonisolated struct FileIdentity: Codable, Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let mode: UInt16
        let links: UInt64
        let flags: UInt32
    }
    nonisolated struct DirectoryIdentity: Codable, Sendable, Equatable { let device: UInt64; let inode: UInt64 }
    nonisolated struct MovePreview: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        let sourceInput: String
        let destinationInput: String
        let sourcePath: String
        let destinationPath: String
        let sourceIdentity: FileIdentity
        let sourceParentIdentity: DirectoryIdentity
        let destinationParentIdentity: DirectoryIdentity
        let contentSHA256: String
        let scopeFingerprint: String
        let preparedAt: Date
        var reviewText: String {
            "Move regular file:\n\(sourcePath)\nTo:\n\(destinationPath)\n\(sourceIdentity.bytes) bytes; SHA-256 \(contentSHA256). No overwrite. To reverse, prepare and review a new move from the destination back to the source."
        }
    }
    nonisolated struct MoveResult: Sendable {
        let verified: Bool
        let summary: String
        let evidence: String
        let sourcePath: String
        let destinationPath: String
    }
    nonisolated private static let maximumMoveBytes: Int64 = 67_108_864

    static func search(query: String, grants: [ScopeGrant]) async throws -> SearchResult {
        let query = try validatedQuery(query)
        guard !grants.isEmpty, grants.count <= 20 else { throw RelayError.message("Filename search needs between 1 and 20 explicitly selected files or folders.") }
        var matches: [SearchMatch] = []
        var visited = 0, skipped = 0, outputBytes = 0
        var truncated = false
        var warnings: [String] = []
        var seenPaths = Set<String>()
        let deadline = Date().addingTimeInterval(10)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .volumeIsLocalKey]
        func inspect(_ candidate: URL, enumerator: FileManager.DirectoryEnumerator?) throws -> Bool {
            try Task.checkCancellation()
            guard Date() < deadline, visited < 5000, matches.count < 100 else { truncated = true; return false }
            visited += 1
            let values = try candidate.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                // DirectoryEnumerator does not follow symlinks; skipDescendants on a leaf
                // would incorrectly apply to the next real directory on this Foundation build.
                skipped += 1; return true
            }
            if values.isHidden == true || candidate.lastPathComponent.hasPrefix(".") || ["node_modules", "DerivedData", "Pods"].contains(candidate.lastPathComponent) {
                if values.isDirectory == true { enumerator?.skipDescendants() }
                return true
            }
            let isLocal = try values.volumeIsLocal ?? URL(fileURLWithPath: candidate.path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
            guard isLocal == true else {
                if values.isDirectory == true { enumerator?.skipDescendants() }
                if warnings.count < 5 { warnings.append("A nonlocal or unqualified filesystem entry was excluded; results may be incomplete.") }
                return true
            }
            if let enumerator, enumerator.level > 8 {
                if values.isDirectory == true { enumerator.skipDescendants() }
                truncated = true; return true
            }
            guard values.isRegularFile == true else { return true }
            let resolved = try ToolPolicy.scopedURL(candidate.path, grants: grants)
            guard Self.filenameMatches(resolved.lastPathComponent, query: query),
                  seenPaths.insert(resolved.path).inserted else { return true }
            let cost = resolved.path.utf8.count + resolved.lastPathComponent.utf8.count + 96
            guard outputBytes + cost <= 9000 else { truncated = true; return false }
            outputBytes += cost
            matches.append(SearchMatch(path: resolved.path, name: resolved.lastPathComponent, bytes: values.fileSize ?? 0))
            return true
        }
        for grant in grants {
            try Task.checkCancellation()
            guard Date() < deadline, visited < 5000, matches.count < 100 else { truncated = true; break }
            do {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: grant.path)) != nil { skipped += 1; continue }
                let root = try ToolPolicy.scopedURL(grant.path, grants: grants)
                let values = try root.resourceValues(forKeys: keys)
                guard values.isHidden != true, !root.lastPathComponent.hasPrefix(".") else { continue }
                guard values.volumeIsLocal == true else {
                    if warnings.count < 5 { warnings.append("A selected nonlocal or unqualified filesystem root was excluded.") }
                    continue
                }
                if values.isRegularFile == true { if try !inspect(root, enumerator: nil) { break }; continue }
                guard values.isDirectory == true else { continue }
                if let topChildren = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]), topChildren.count > 50 {
                    for child in topChildren {
                        if let cv = try? child.resourceValues(forKeys: keys), cv.isRegularFile == true, cv.isSymbolicLink != true {
                            _ = try? inspect(child, enumerator: nil)
                        }
                    }
                }
                var enumerationFailed = false
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }) else { continue }
                while let file = enumerator.nextObject() as? URL {
                    do { if try !inspect(file, enumerator: enumerator) { break } }
                    catch is CancellationError { throw CancellationError() }
                    catch { if warnings.count < 5 { warnings.append("A selected entry could not be inspected; results may be incomplete.") } }
                    if visited % 32 == 0 { await Task.yield() }
                }
                if enumerationFailed, warnings.count < 5 { warnings.append("A selected directory enumeration stopped on an access error; results are incomplete.") }
            } catch is CancellationError { throw CancellationError() }
            catch { if warnings.count < 5 { warnings.append("A selected search root could not be inspected; results may be incomplete.") } }
        }
        try Task.checkCancellation()
        return SearchResult(matches: matches, visitedEntries: visited, truncated: truncated || !warnings.isEmpty, skippedSymlinks: skipped, warnings: warnings)
    }

    static func validatedQuery(_ raw: String) throws -> String {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !raw.contains("/") else {
            throw RelayError.message("Filename search accepts literal single-line filename text, not a path or keyboard control.")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256 else { throw RelayError.message("Filename search requires 1 to 256 UTF-8 bytes.") }
        return value
    }

    static func prepareMove(source: String, destination: String, grants: [ScopeGrant]) async throws -> MovePreview {
        let sourceURL = try moveURL(source, grants: grants)
        let destinationURL = try moveURL(destination, grants: grants)
        guard sourceURL != destinationURL else { throw RelayError.message("Move source and destination must differ.") }
        let sourceParent = try openDirectory(sourceURL.deletingLastPathComponent())
        defer { close(sourceParent) }
        let destinationParent = try openDirectory(destinationURL.deletingLastPathComponent())
        defer { close(destinationParent) }
        try requireAbsent(destinationURL.lastPathComponent, in: destinationParent)
        let sourceFD = try openRegularFile(sourceURL.lastPathComponent, parent: sourceParent)
        defer { close(sourceFD) }
        let before = try fileIdentity(sourceFD)
        let sourceParentID = try directoryIdentity(sourceParent), destinationParentID = try directoryIdentity(destinationParent)
        guard before.device == destinationParentID.device else { throw RelayError.message("This qualified move supports one filesystem only; cross-volume copy/delete is not performed.") }
        let scope = try scopeFingerprint(grants)
        let hash = try await hashFile(sourceFD)
        try Task.checkCancellation()
        guard before == (try fileIdentity(sourceFD)), scope == (try scopeFingerprint(grants)),
              sourceURL == (try moveURL(source, grants: grants)), destinationURL == (try moveURL(destination, grants: grants)),
              try directoryAtPathMatches(sourceURL.deletingLastPathComponent(), expected: sourceParentID),
              try directoryAtPathMatches(destinationURL.deletingLastPathComponent(), expected: destinationParentID),
              try entryIdentity(sourceURL.lastPathComponent, parent: sourceParent) == before else {
            throw RelayError.message("Source or scope changed while the move preview was prepared. Nothing was moved.")
        }
        try requireAbsent(destinationURL.lastPathComponent, in: destinationParent)
        return MovePreview(id: UUID(), sourceInput: source, destinationInput: destination,
            sourcePath: sourceURL.path, destinationPath: destinationURL.path, sourceIdentity: before,
            sourceParentIdentity: sourceParentID, destinationParentIdentity: destinationParentID,
            contentSHA256: hash, scopeFingerprint: scope, preparedAt: Date())
    }

    /// Requires the exact preview already shown to the user; caller owns the one-use review ticket.
    static func executeMove(_ preview: MovePreview, grants: [ScopeGrant],
                            isStillAuthorized: @MainActor () -> Bool = { true }) async throws -> MoveResult {
        try Task.checkCancellation()
        guard Date().timeIntervalSince(preview.preparedAt) >= 0, Date().timeIntervalSince(preview.preparedAt) < 120,
              try scopeFingerprint(grants) == preview.scopeFingerprint else {
            throw RelayError.message("The move preview expired or selected grants changed. Prepare and review a new preview.")
        }
        let sourceURL = try moveURL(preview.sourceInput, grants: grants), destinationURL = try moveURL(preview.destinationInput, grants: grants)
        guard sourceURL.path == preview.sourcePath, destinationURL.path == preview.destinationPath else { throw RelayError.message("A reviewed path changed. Nothing was moved.") }
        let sourceParent = try openDirectory(sourceURL.deletingLastPathComponent())
        defer { close(sourceParent) }
        let destinationParent = try openDirectory(destinationURL.deletingLastPathComponent())
        defer { close(destinationParent) }
        guard try directoryIdentity(sourceParent) == preview.sourceParentIdentity,
              try directoryIdentity(destinationParent) == preview.destinationParentIdentity else { throw RelayError.message("A reviewed parent directory changed. Nothing was moved.") }
        try requireAbsent(destinationURL.lastPathComponent, in: destinationParent)
        let sourceFD = try openRegularFile(sourceURL.lastPathComponent, parent: sourceParent)
        defer { close(sourceFD) }
        guard try fileIdentity(sourceFD) == preview.sourceIdentity else { throw RelayError.message("Source identity changed after preview. Nothing was moved.") }
        let hash = try await hashFile(sourceFD)
        try Task.checkCancellation()
        guard hash == preview.contentSHA256, try fileIdentity(sourceFD) == preview.sourceIdentity,
              try entryIdentity(sourceURL.lastPathComponent, parent: sourceParent) == preview.sourceIdentity,
              try scopeFingerprint(grants) == preview.scopeFingerprint,
              sourceURL == (try moveURL(preview.sourceInput, grants: grants)), destinationURL == (try moveURL(preview.destinationInput, grants: grants)),
              try directoryAtPathMatches(sourceURL.deletingLastPathComponent(), expected: preview.sourceParentIdentity),
              try directoryAtPathMatches(destinationURL.deletingLastPathComponent(), expected: preview.destinationParentIdentity),
              Date().timeIntervalSince(preview.preparedAt) >= 0, Date().timeIntervalSince(preview.preparedAt) < 120 else {
            throw RelayError.message("Source, path or scope changed after review. Nothing was moved.")
        }
        // Re-enter the caller's live authorization boundary after hashing suspended this task.
        // No await may occur between this check and the exclusive rename below.
        try Task.checkCancellation()
        guard isStillAuthorized() else {
            throw RelayError.message("Live move authorization changed or Stop was accepted. Nothing was moved; prepare and review the current state again.")
        }
        try Task.checkCancellation()
        // File-descriptor-relative exclusive rename avoids overwrite and cross-volume copy/delete.
        let result = sourceURL.lastPathComponent.withCString { source in
            destinationURL.lastPathComponent.withCString { destination in
                renameatx_np(sourceParent, source, destinationParent, destination, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw RelayError.message("Exclusive move failed without permission to overwrite: \(String(cString: strerror(errno))). Inspect the original paths before retrying.") }
        do {
            let destinationFD = try openRegularFile(destinationURL.lastPathComponent, parent: destinationParent)
            defer { close(destinationFD) }
            let finalHash = try await hashFile(destinationFD)
            guard try fileIdentity(destinationFD) == preview.sourceIdentity, finalHash == preview.contentSHA256,
                  entryAbsent(sourceURL.lastPathComponent, in: sourceParent),
                  sourceURL == (try moveURL(preview.sourceInput, grants: grants)), destinationURL == (try moveURL(preview.destinationInput, grants: grants)),
                  try directoryAtPathMatches(sourceURL.deletingLastPathComponent(), expected: preview.sourceParentIdentity),
                  try directoryAtPathMatches(destinationURL.deletingLastPathComponent(), expected: preview.destinationParentIdentity) else {
                throw RelayError.message("Post-move path, identity or content readback differed.")
            }
            return MoveResult(verified: true, summary: "Moved \(sourceURL.lastPathComponent) to \(destinationURL.lastPathComponent).",
                evidence: "Exclusive filesystem rename completed. Source is absent; destination device/inode, size, modification state and SHA-256 matched the reviewed source. Reverse by reviewing a new move from \(destinationURL.path) back to \(sourceURL.path); no automatic undo was performed.", sourcePath: sourceURL.path, destinationPath: destinationURL.path)
        } catch {
            return MoveResult(verified: false, summary: "Move dispatched; outcome needs inspection.",
                evidence: "The exclusive rename returned success, but complete post-move verification failed: \(error.localizedDescription). Inspect \(sourceURL.path) and \(destinationURL.path) before retrying; no automatic rollback or replay was attempted.", sourcePath: sourceURL.path, destinationPath: destinationURL.path)
        }
    }

    private static func moveURL(_ input: String, grants: [ScopeGrant]) throws -> URL {
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !input.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: (input as NSString).expandingTildeInPath)) == nil else {
            throw RelayError.message("This move supports visible regular files, not symlinks or hidden paths.")
        }
        let url = try ToolPolicy.scopedURL(input, grants: grants, writing: true)
        try validateOrdinaryMoveLocation(url)
        guard !url.pathComponents.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) else {
            throw RelayError.message("Resolved move paths must not enter hidden files or folders.")
        }
        // Renaming changes directory entries. File-only grants do not authorize their parent
        // namespace and would disappear after a successful move, preventing scoped reversal.
        _ = try ToolPolicy.scopedURL(url.deletingLastPathComponent().path, grants: grants, writing: true)
        guard try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else {
            throw RelayError.message("This move supports local selected filesystems only.")
        }
        return url
    }

    /// Folder selection is not authorization to install launch configuration or alter app/system data.
    static func validateOrdinaryMoveLocation(_ input: URL) throws {
        guard input.isFileURL else { throw RelayError.message("Move locations must be local file URLs.") }
        // Foundation may rewrite an existing /private/etc root to /etc while leaving its
        // nonexistent child destination unchanged. Resolve every component consistently.
        let url = try ToolPolicy.canonicalURL(input.path)
        let excluded = try ["/System", "/Library", "/Applications", "/bin", "/sbin", "/usr", "/private/etc", "/private/var/db", NSHomeDirectory() + "/Library", NSHomeDirectory() + "/Applications"]
            .map { try ToolPolicy.canonicalURL($0).path.precomposedStringWithCanonicalMapping.lowercased() }
        let comparablePath = url.path.precomposedStringWithCanonicalMapping.lowercased()
        guard !excluded.contains(where: { comparablePath == $0 || comparablePath.hasPrefix($0 + "/") }),
              !url.pathComponents.dropLast().contains(where: { component in
                  ["app", "framework", "kext"].contains((component as NSString).pathExtension.lowercased())
              }) else {
            throw RelayError.message("This move tool handles ordinary selected documents, not system, application, Library or launch-configuration locations. A folder grant does not enable security administration.")
        }
    }

    static func scopeFingerprint(_ grants: [ScopeGrant]) throws -> String {
        let rows = try grants.map { grant in "\(grant.id.uuidString)|\(try ToolPolicy.canonicalURL(grant.path).path)|\(grant.writable)" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(rows.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func openDirectory(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RelayError.message("A selected parent directory is missing or became a symlink.") }
        return fd
    }
    nonisolated private static func openRegularFile(_ name: String, parent: Int32) throws -> Int32 {
        // Check the directory entry without opening content first: opening a dataless provider
        // file for reading can itself request materialization from its account service.
        _ = try entryIdentity(name, parent: parent)
        let fd = name.withCString { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw RelayError.message("Source/destination regular file is unavailable or is a symlink.") }
        do { _ = try fileIdentity(fd); return fd } catch { close(fd); throw error }
    }
    nonisolated private static func fileIdentity(_ fd: Int32) throws -> FileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumMoveBytes else {
            throw RelayError.message("Moves support one regular file up to 64 MB, without symlinks or multiple hard links.")
        }
        try validateMaterializedFlags(info.st_flags)
        return identity(info)
    }
    nonisolated static func validateMaterializedFlags(_ flags: UInt32) throws {
        guard flags & UInt32(SF_DATALESS) == 0 else {
            throw RelayError.message("Offline move refused: this file is an unmaterialized/dataless cloud or FileProvider placeholder. Make it available locally directly in its owning app before preparing a new move; Relay will not request a download.")
        }
    }
    nonisolated private static func identity(_ info: stat) -> FileIdentity {
        FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), bytes: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            mode: UInt16(info.st_mode), links: UInt64(info.st_nlink), flags: info.st_flags)
    }
    nonisolated private static func directoryIdentity(_ fd: Int32) throws -> DirectoryIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw RelayError.message("Selected parent is not a directory.") }
        return DirectoryIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }
    nonisolated private static func directoryAtPathMatches(_ url: URL, expected: DirectoryIdentity) throws -> Bool {
        let fd = try openDirectory(url)
        defer { close(fd) }
        return try directoryIdentity(fd) == expected
    }
    nonisolated private static func entryIdentity(_ name: String, parent: Int32) throws -> FileIdentity {
        var info = stat()
        guard name.withCString({ fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
              info.st_mode & S_IFMT == S_IFREG else { throw RelayError.message("Reviewed source directory entry changed or became a symlink.") }
        try validateMaterializedFlags(info.st_flags)
        return identity(info)
    }
    nonisolated private static func entryAbsent(_ name: String, in parent: Int32) -> Bool {
        var info = stat()
        return name.withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) } != 0 && errno == ENOENT
    }
    nonisolated private static func requireAbsent(_ name: String, in parent: Int32) throws {
        guard entryAbsent(name, in: parent) else { throw RelayError.message("Destination already exists or cannot be inspected. This move never overwrites.") }
    }
    @concurrent private static func hashFile(_ fd: Int32) async throws -> String {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw RelayError.message("Could not read the reviewed regular file.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var digest = SHA256(), total: Int64 = 0
        while true {
            try Task.checkCancellation()
            _ = try fileIdentity(fd) // Recheck SF_DATALESS and regular-file bounds before each read.
            let data = try handle.read(upToCount: 65_536) ?? Data()
            if data.isEmpty { break }
            total += Int64(data.count)
            guard total <= maximumMoveBytes else { throw RelayError.message("Source grew beyond the 64 MB move limit.") }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func filenameMatches(_ filename: String, query: String) -> Bool {
        let normFile = filename
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let normQuery = query
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        if normFile.range(of: normQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        let rawTokens = normQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard rawTokens.count >= 2 else { return false }
        let stopWords: Set<String> = ["with", "name", "named", "file", "for", "the", "find", "search"]
        let substantive = rawTokens.filter { !stopWords.contains($0) }
        let activeTokens = substantive.isEmpty ? rawTokens : substantive
        return activeTokens.allSatisfy { token in
            normFile.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
