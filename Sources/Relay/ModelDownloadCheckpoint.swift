import CryptoKit
import Darwin
import Foundation

/// Private, model-directory-rooted resume state. Never installs or replaces a model destination.
actor ModelDownloadCheckpoint {
    nonisolated struct State: Sendable { let offset: Int64; let etag: String?; let partialURL: URL }
    nonisolated private struct Metadata: Codable, Sendable {
        let version: Int
        let sourceURL: String
        let filename: String
        let size: Int64
        let sha256: String
        let partialLeaf: String
        let device: UInt64
        let inode: UInt64
        let offset: Int64
        let etag: String?
        let prefixSHA256: String
    }
    nonisolated private struct Stamp: Sendable, Equatable {
        let device: UInt64; let inode: UInt64; let bytes: Int64; let seconds: Int64; let nanos: Int64
        let changedSeconds: Int64; let changedNanos: Int64
    }
    private var rootFD: Int32 = -1, lockFD: Int32 = -1, partialFD: Int32 = -1
    private var rootURL: URL?, rootStamp: Stamp?, partialStamp: Stamp?
    private var manifest: ModelManifest?, partialLeaf = "", metadataLeaf: String?, metadataStamp: Stamp?
    private var offset: Int64 = 0, etag: String?, digest = SHA256()
    private var busy = false, sealed = false
    nonisolated private static let chunkLimit: Int64 = 33_554_432

    func open(manifest: ModelManifest, directory: URL) async throws -> State {
        guard !busy, rootFD < 0 else { throw failure("Close the previous checkpoint operation before opening another.") }
        busy = true; defer { busy = false }
        try Self.validate(manifest)
        guard directory.isFileURL else { throw failure("Checkpoint directory must be local.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard root >= 0 else { throw failure("Model directory must be an existing non-symlink directory.") }
        rootFD = root; rootURL = directory.standardizedFileURL
        do {
            var directoryInfo = stat()
            guard fstat(rootFD, &directoryInfo) == 0, directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o022 == 0 else {
                throw failure("Model directory must be owned by this user and not writable by other users.")
            }
            var filesystem = statfs()
            guard fstatfs(rootFD, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
                throw failure("Checkpoint storage requires a local filesystem; network-mounted model directories are not supported.")
            }
            rootStamp = Self.stamp(directoryInfo)
            lockFD = openat(rootFD, ".relay-download.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard lockFD >= 0 else { throw failure("Could not open the private checkpoint lock.") }
            _ = try privateStamp(lockFD, maximum: 0)
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw failure("Another model checkpoint operation is active. Wait for it to close before retrying.") }
            self.manifest = manifest
            let leaves = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { Self.generatedLeaf($0, prefix: ".relay-download-checkpoint-", suffix: ".json") }
            guard leaves.count <= 64 else { throw failure("Too many checkpoint records are present. Preserve and inspect this directory before retrying.") }
            var candidates: [(String, Metadata, Stamp)] = []
            for leaf in leaves {
                do {
                    let fd = openat(rootFD, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard fd >= 0 else { throw failure("Checkpoint metadata is not a private regular file.") }
                    defer { Darwin.close(fd) }
                    let stamp = try privateStamp(fd, maximum: 8192)
                    let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 8193) ?? Data()
                    guard data.count <= 8192 else { throw failure("Checkpoint metadata exceeds its limit.") }
                    let record = try JSONDecoder().decode(Metadata.self, from: data)
                    guard record.version == 1, record.sourceURL == manifest.sourceURL.absoluteString, record.filename == manifest.filename,
                          record.size == manifest.size, record.sha256 == manifest.sha256,
                          Self.generatedLeaf(record.partialLeaf, prefix: ".relay-download-", suffix: ".partial"),
                          (0...manifest.size).contains(record.offset), Self.validHash(record.prefixSHA256),
                          record.etag.map(Self.isStrongETag) ?? (record.offset == 0 || record.offset == manifest.size) else {
                        throw failure("Checkpoint metadata does not match the pinned model.")
                    }
                    candidates.append((leaf, record, stamp))
                } catch { try quarantine(leaf) }
            }
            for candidate in candidates.sorted(by: { $0.1.offset > $1.1.offset }) {
                do {
                    let record = candidate.1
                    let fd = openat(rootFD, record.partialLeaf, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard fd >= 0 else { throw failure("Partial checkpoint file is unavailable.") }
                    var keep = false
                    defer { if !keep { Darwin.close(fd) } }
                    let stamp = try privateStamp(fd, maximum: manifest.size)
                    guard stamp.device == record.device, stamp.inode == record.inode, stamp.bytes >= record.offset else {
                        throw failure("Partial file identity or length changed.")
                    }
                    let restored = try await Self.hashPrefix(fd, length: record.offset)
                    guard Self.hex(restored) == record.prefixSHA256,
                          try privateStamp(fd, maximum: manifest.size) == stamp else { throw failure("Partial prefix checksum changed.") }
                    try checkRoot()
                    guard try entryStamp(record.partialLeaf) == stamp else { throw failure("Partial directory entry changed while restoring its prefix.") }
                    guard ftruncate(fd, record.offset) == 0, fsync(fd) == 0 else { throw failure("Could not remove an uncheckpointed partial tail.") }
                    partialFD = fd; partialLeaf = record.partialLeaf; partialStamp = try privateStamp(fd, maximum: manifest.size)
                    offset = record.offset; etag = record.etag; digest = restored
                    metadataLeaf = candidate.0; metadataStamp = candidate.2
                    // A crash can leave the prior committed metadata alongside a newer one.
                    // Archive only unchanged, validated records for this same owned partial;
                    // never unlink partial bytes or metadata belonging to another identity.
                    for other in candidates where other.0 != candidate.0 && other.1.partialLeaf == record.partialLeaf
                        && other.1.device == record.device && other.1.inode == record.inode && other.1.offset <= record.offset {
                        if let current = try? entryStamp(other.0), current == other.2 {
                            try? quarantine(other.0, superseded: true)
                        }
                    }
                    keep = true
                    return try state()
                } catch is CancellationError { throw CancellationError() }
                catch { try quarantine(candidate.0) }
            }
            partialLeaf = ".relay-download-\(UUID().uuidString).partial"
            partialFD = openat(rootFD, partialLeaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard partialFD >= 0, fchmod(partialFD, 0o600) == 0 else { throw failure("Could not create a new private partial file.") }
            offset = 0; etag = nil; digest = SHA256(); sealed = false
            partialStamp = try privateStamp(partialFD, maximum: manifest.size)
            try persistCheckpoint()
            return try state()
        } catch { closeDescriptors(); throw error }
    }

    func append(chunkURL: URL, expectedOffset: Int64, etag newETag: String?) async throws -> State {
        guard !busy, !sealed, let manifest, partialFD >= 0, expectedOffset == offset else { throw failure("Checkpoint append offset or operation state changed.") }
        busy = true; defer { busy = false }
        try checkRoot(); try checkPartial()
        guard chunkURL.isFileURL else { throw failure("A downloaded chunk must be a local temporary file.") }
        let chunk = Darwin.open(chunkURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard chunk >= 0 else { throw failure("Downloaded chunk is unavailable or is a symlink.") }
        defer { Darwin.close(chunk) }
        let chunkStamp = try privateStamp(chunk, maximum: Self.chunkLimit, requirePrivateMode: false)
        guard chunkStamp.bytes > 0, chunkStamp.bytes <= manifest.size - offset,
              newETag.map(Self.isStrongETag) ?? (offset == 0 && chunkStamp.bytes == manifest.size),
              etag == nil || etag == newETag else { throw failure("Chunk length or strong ETag does not match this resumable transfer.") }
        let oldOffset = offset, oldETag = etag, oldDigest = digest, oldStamp = partialStamp
        do {
            let input = FileHandle(fileDescriptor: chunk, closeOnDealloc: false)
            var received: Int64 = 0
            while received < chunkStamp.bytes {
                try Task.checkCancellation(); try checkRoot(); try checkPartial()
                let bytes = try input.read(upToCount: Int(min(1_048_576, chunkStamp.bytes - received))) ?? Data()
                guard !bytes.isEmpty else { throw failure("Downloaded chunk ended early.") }
                try writeAll(bytes, fd: partialFD, at: oldOffset + received)
                digest.update(data: bytes); received += Int64(bytes.count)
                partialStamp = try privateStamp(partialFD, maximum: manifest.size)
                await Task.yield()
            }
            try Task.checkCancellation()
            guard try privateStamp(chunk, maximum: Self.chunkLimit, requirePrivateMode: false) == chunkStamp else { throw failure("Downloaded chunk changed while appending.") }
            offset += received; etag = newETag
            guard fsync(partialFD) == 0 else { throw failure("Partial bytes could not be synchronized to disk.") }
            try persistCheckpoint()
            return try state()
        } catch {
            let owned = try? privateStamp(partialFD, maximum: manifest.size)
            let named = try? entryStamp(partialLeaf)
            let safeRoot = (try? checkRoot()) != nil
            let safeIdentity = owned?.device == oldStamp?.device && owned?.inode == oldStamp?.inode
                && named?.device == oldStamp?.device && named?.inode == oldStamp?.inode
            guard safeRoot, safeIdentity else {
                sealed = true
                throw failure("Append failed after checkpoint storage identity changed. Untrusted storage was preserved without truncation; inspect it before retrying.")
            }
            let rollbackSucceeded = ftruncate(partialFD, oldOffset) == 0 && fsync(partialFD) == 0
            offset = oldOffset; etag = oldETag; digest = oldDigest
            partialStamp = rollbackSucceeded ? (try? privateStamp(partialFD, maximum: manifest.size)) : oldStamp
            if !rollbackSucceeded { sealed = true; throw failure("Checkpoint append failed and rollback could not be verified. Preserve and inspect the partial file before retrying.") }
            throw error
        }
    }

    func checkpoint() throws -> State {
        guard !busy, !sealed else { throw failure("Checkpoint is busy or finalized.") }
        try checkRoot(); try checkPartial(); try persistCheckpoint(); return try state()
    }
    func fullDigest() throws -> String {
        guard !busy, let manifest, offset == manifest.size else { throw failure("The model transfer is not complete.") }
        try checkRoot(); try checkPartial(); return Self.hex(digest)
    }
    func finalURL() throws -> URL {
        guard let manifest, try fullDigest() == manifest.sha256 else { throw failure("Complete model SHA-256 does not match the pinned manifest.") }
        sealed = true
        return try state().partialURL // Caller must install exclusively; this actor never overwrites a model.
    }
    func discardOwned() throws {
        guard !busy else { throw failure("Wait for the current checkpoint operation before discarding it.") }
        try checkRoot()
        if partialFD >= 0 {
            if let current = try entryStamp(partialLeaf), let stamp = partialStamp {
                guard current.device == stamp.device, current.inode == stamp.inode else { throw failure("Partial directory entry was replaced. Unknown data was preserved.") }
                guard unlinkat(rootFD, partialLeaf, 0) == 0 else { throw failure("Owned partial could not be removed.") }
            }
        }
        if let leaf = metadataLeaf, let expected = metadataStamp, let current = try entryStamp(leaf) {
            guard current == expected else { throw failure("Checkpoint metadata was replaced. Unknown data was preserved.") }
            guard unlinkat(rootFD, leaf, 0) == 0 else { throw failure("Owned checkpoint metadata could not be removed.") }
        }
        closeDescriptors()
    }
    func close() throws {
        guard !busy else { throw failure("Wait for the current checkpoint operation before closing it.") }
        closeDescriptors()
    }
    deinit {
        if partialFD >= 0 { Darwin.close(partialFD) }
        if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        if rootFD >= 0 { Darwin.close(rootFD) }
    }

    nonisolated static func isStrongETag(_ value: String) -> Bool {
        guard value.utf8.count >= 2, value.utf8.count <= 512, value.first == "\"", value.last == "\"", !value.hasPrefix("W/") else { return false }
        return value.dropFirst().dropLast().unicodeScalars.allSatisfy { $0.value == 0x21 || (0x23...0x7e).contains($0.value) }
    }
    nonisolated private static func validate(_ manifest: ModelManifest) throws {
        guard manifest.filename == URL(fileURLWithPath: manifest.filename).lastPathComponent,
              !manifest.filename.hasPrefix("."), manifest.filename.hasSuffix(".litertlm"), manifest.filename.utf8.count <= 200,
              manifest.size > 0, manifest.size <= 8_589_934_592, validHash(manifest.sha256),
              manifest.sourceURL.scheme == "https", manifest.sourceURL.host != nil, manifest.sourceURL.user == nil,
              manifest.sourceURL.password == nil, manifest.sourceURL.query == nil, manifest.sourceURL.fragment == nil,
              manifest.sourceURL.absoluteString.utf8.count <= 4096 else { throw RelayError.message("Resume requires a bounded query-free HTTPS pinned model manifest.") }
    }
    private func state() throws -> State {
        guard let rootURL, partialFD >= 0 else { throw failure("Checkpoint is closed.") }
        return State(offset: offset, etag: etag, partialURL: rootURL.appendingPathComponent(partialLeaf))
    }
    private func persistCheckpoint() throws {
        guard let manifest, let partialStamp else { throw failure("Checkpoint has no owned partial.") }
        try checkRoot(); try checkPartial()
        let record = Metadata(version: 1, sourceURL: manifest.sourceURL.absoluteString, filename: manifest.filename,
            size: manifest.size, sha256: manifest.sha256, partialLeaf: partialLeaf,
            device: partialStamp.device, inode: partialStamp.inode, offset: offset, etag: etag, prefixSHA256: Self.hex(digest))
        let data = try JSONEncoder().encode(record)
        guard data.count <= 8192 else { throw failure("Checkpoint metadata exceeds 8 KB.") }
        let temporary = ".relay-checkpoint-write-\(UUID().uuidString).tmp"
        let final = ".relay-download-checkpoint-\(UUID().uuidString).json"
        let fd = openat(rootFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Could not create private checkpoint metadata.") }
        defer {
            if let owned = try? privateStamp(fd, maximum: 8192), let current = try? entryStamp(temporary), current == owned { _ = unlinkat(rootFD, temporary, 0) }
            Darwin.close(fd)
        }
        guard fchmod(fd, 0o600) == 0 else { throw failure("Checkpoint metadata permissions could not be made private.") }
        try writeAll(data, fd: fd, at: 0)
        guard fsync(fd) == 0, renameatx_np(rootFD, temporary, rootFD, final, UInt32(RENAME_EXCL)) == 0 else { throw failure("Could not atomically commit checkpoint metadata.") }
        let oldLeaf = metadataLeaf, oldStamp = metadataStamp
        metadataLeaf = final; metadataStamp = try entryStamp(final)
        guard fsync(rootFD) == 0 else { throw failure("Checkpoint directory could not be synchronized.") }
        if let oldLeaf, let oldStamp, let current = try entryStamp(oldLeaf), current == oldStamp { _ = unlinkat(rootFD, oldLeaf, 0) }
    }
    private func quarantine(_ leaf: String, superseded: Bool = false) throws {
        let category = superseded ? "retired" : "invalid"
        let backup = ".relay-download-\(category)-\(UUID().uuidString).json"
        guard renameatx_np(rootFD, leaf, rootFD, backup, UInt32(RENAME_EXCL)) == 0 else { throw failure("Invalid checkpoint metadata could not be preserved safely. Nothing was overwritten.") }
        _ = fsync(rootFD)
    }
    private func checkRoot() throws {
        guard let rootURL, let rootStamp else { throw failure("Checkpoint directory is closed.") }
        var current = stat()
        guard lstat(rootURL.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              Self.stamp(current).device == rootStamp.device, Self.stamp(current).inode == rootStamp.inode else {
            throw failure("The model directory identity changed. Checkpoint operation stopped.")
        }
    }
    private func checkPartial() throws {
        guard let manifest, let expected = partialStamp,
              try privateStamp(partialFD, maximum: manifest.size) == expected,
              let path = try entryStamp(partialLeaf), path == expected else { throw failure("Owned partial identity, permissions or contents changed.") }
    }
    private func privateStamp(_ fd: Int32, maximum: Int64, requirePrivateMode: Bool = true) throws -> Stamp {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              (!requirePrivateMode || info.st_mode & 0o777 == 0o600), info.st_size >= 0, info.st_size <= maximum,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { throw failure("Checkpoint/chunk must be an owned, single-link, materialized regular file within its size and permission bounds.") }
        return Self.stamp(info)
    }
    private func entryStamp(_ leaf: String) throws -> Stamp? {
        var info = stat()
        if fstatat(rootFD, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw failure("Checkpoint directory entry could not be inspected.")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600 else {
            throw failure("Checkpoint entry was replaced with untrusted data; it was preserved.")
        }
        return Self.stamp(info)
    }
    nonisolated private static func stamp(_ info: stat) -> Stamp {
        Stamp(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), bytes: info.st_size,
              seconds: Int64(info.st_mtimespec.tv_sec), nanos: Int64(info.st_mtimespec.tv_nsec),
              changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
    nonisolated private static func generatedLeaf(_ value: String, prefix: String, suffix: String) -> Bool {
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return false }
        let middle = String(value.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: middle)?.uuidString == middle
    }
    nonisolated private static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    nonisolated private static func hex(_ digest: SHA256) -> String { digest.finalize().map { String(format: "%02x", $0) }.joined() }
    nonisolated private static func hashPrefix(_ fd: Int32, length: Int64) async throws -> SHA256 {
        var digest = SHA256(), readOffset: Int64 = 0
        while readOffset < length {
            try Task.checkCancellation()
            let count = Int(min(1_048_576, length - readOffset))
            var buffer = Data(count: count)
            let readCount = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(readOffset)) }
            guard readCount == count else { throw RelayError.message("Checkpoint prefix could not be read completely.") }
            digest.update(data: buffer); readOffset += Int64(count)
            await Task.yield()
        }
        return digest
    }
    private func writeAll(_ data: Data, fd: Int32, at offset: Int64) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = pwrite(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written, off_t(offset + Int64(written)))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(count < 0 ? errno : EIO),
                                  userInfo: [NSLocalizedDescriptionKey: "Checkpoint bytes could not be written. Check available space and storage access."])
                }
                written += count
            }
        }
    }
    // Explicitly unlock before close: a concurrently forked subprocess can retain
    // this open file description until exec, even with O_CLOEXEC. Closing our copy
    // alone would leave a phantom active operation during an immediate reopen.
    private func closeDescriptors() {
        if partialFD >= 0 { Darwin.close(partialFD) }; if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); Darwin.close(lockFD) }; if rootFD >= 0 { Darwin.close(rootFD) }
        rootFD = -1; lockFD = -1; partialFD = -1; rootURL = nil; rootStamp = nil; partialStamp = nil
        manifest = nil; partialLeaf = ""; metadataLeaf = nil; metadataStamp = nil; offset = 0; etag = nil; digest = SHA256(); sealed = false
    }
    private func failure(_ text: String) -> RelayError { .message(text) }
}
