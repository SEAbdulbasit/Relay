import Foundation
import Darwin

nonisolated enum LocalPrivateFileWriteError: LocalizedError, Equatable {
    case outputTooLarge
    case invalidDestination
    case unsafeDestination
    case destinationChanged
    case privateStagingFailed
    case outcomeUncertain

    var errorDescription: String? {
        switch self {
        case .outputTooLarge: "The private file exceeds its configured size limit. Nothing was written."
        case .invalidDestination: "Choose an ordinary file in an existing local directory. Nothing was written."
        case .unsafeDestination: "The destination is a link, nonregular file or unavailable local placeholder. It was not replaced."
        case .destinationChanged: "The destination or staging file changed before installation. The export did not replace it."
        case .privateStagingFailed: "A private file could not be prepared. The existing destination was not replaced."
        case .outcomeUncertain: "The private file may have been written, but its final state could not be verified. Inspect the destination before retrying; do not assume it is unchanged."
        }
    }
}

/// Hooks are test-only fault injection; the production overload uses none. They do not grant
/// source access or execute conversation content.
nonisolated struct LocalPrivateFileWriteHooks {
    var afterPrivateStageCreated: ((URL) throws -> Void)? = nil
    var beforeCommit: (() throws -> Void)? = nil
    var afterCommit: (() throws -> Void)? = nil
}

/// Private local-file persistence: mode0600 and empty ACL before bytes, bounded readback.
/// The caller owns destination authority and any overwrite review. No network APIs are used.
nonisolated enum LocalPrivateFileWriter {
    static let maximumSupportedBytes = 32 * 1_024 * 1_024

    static func write(data: Data, to url: URL, maximumBytes: Int, hooks: LocalPrivateFileWriteHooks = .init()) throws {
        guard (0...maximumSupportedBytes).contains(maximumBytes), data.count <= maximumBytes else { throw LocalPrivateFileWriteError.outputTooLarge }
        guard url.isFileURL, url.baseURL == nil, !url.hasDirectoryPath, url.path.hasPrefix("/"),
              !url.path(percentEncoded: false).contains("\0"), url.path.utf8.count <= 4_096,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw LocalPrivateFileWriteError.invalidDestination }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255, !name.contains("/") else { throw LocalPrivateFileWriteError.invalidDestination }
        let parent = url.deletingLastPathComponent()
        let parentFD = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard parentFD >= 0 else { throw LocalPrivateFileWriteError.invalidDestination }
        defer { Darwin.close(parentFD) }
        var volume = statfs()
        guard fstatfs(parentFD, &volume) == 0 else { throw LocalPrivateFileWriteError.invalidDestination }
        try validateLocalVolume(flags: volume.f_flags)
        var parentIdentity = stat()
        guard fstat(parentFD, &parentIdentity) == 0, parentIdentity.st_flags & UInt32(SF_DATALESS) == 0 else { throw LocalPrivateFileWriteError.invalidDestination }
        let original = try destination(name, parent: parentFD)
        let stageName = ".relay-private-write-" + UUID().uuidString + ".tmp"
        let stageURL = parent.appendingPathComponent(stageName)
        let stageFD = stageName.withCString {
            openat(parentFD, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        }
        guard stageFD >= 0 else { throw LocalPrivateFileWriteError.privateStagingFailed }
        var stageIdentity = stat()
        let hasStageIdentity = fstat(stageFD, &stageIdentity) == 0
        defer {
            // Do not delete an unrelated entry if another actor replaced our random name.
            if hasStageIdentity, let entry = try? rawEntry(stageName, parent: parentFD), sameNode(entry, stageIdentity) {
                stageName.withCString { _ = unlinkat(parentFD, $0, 0) }
            }
            Darwin.close(stageFD)
        }
        var commitAttempted = false
        do {
            guard hasStageIdentity, fchmod(stageFD, mode_t(0o600)) == 0 else { throw LocalPrivateFileWriteError.privateStagingFailed }
            // A shared folder may supply inherited ACL grants that chmod alone cannot remove.
            // Clear those grants before private data reaches this newly created descriptor.
            guard let emptyACL = acl_init(0) else { throw LocalPrivateFileWriteError.privateStagingFailed }
            defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
            guard acl_set_fd(stageFD, emptyACL) == 0 else { throw LocalPrivateFileWriteError.privateStagingFailed }
            try requirePrivateRegular(stageFD)
            try hooks.afterPrivateStageCreated?(stageURL)
            let handle = FileHandle(fileDescriptor: stageFD, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            guard fsync(stageFD) == 0 else { throw LocalPrivateFileWriteError.privateStagingFailed }
            guard lseek(stageFD, 0, SEEK_SET) == 0 else { throw LocalPrivateFileWriteError.privateStagingFailed }
            let stagedReadback = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard stagedReadback == data else { throw LocalPrivateFileWriteError.privateStagingFailed }
            try requirePrivateRegular(stageFD)
            try hooks.beforeCommit?()
            guard parentPathMatches(parent, parentIdentity),
                  try sameSnapshot(original, destination(name, parent: parentFD)),
                  sameNode(try rawEntry(stageName, parent: parentFD), stageIdentity) else { throw LocalPrivateFileWriteError.destinationChanged }
            commitAttempted = true
            // New destinations use exclusive rename. Existing-file replacement is preceded
            // by a conservative identity check, not an inode compare-and-swap: ordinary
            // rename cannot eliminate another writer's race after the final check. It never
            // follows a swapped symlink to write through it, but may replace that entry.
            let result = stageName.withCString { source in
                name.withCString { target in
                    if original == nil { return renameatx_np(parentFD, source, parentFD, target, UInt32(RENAME_EXCL)) }
                    return renameat(parentFD, source, parentFD, target)
                }
            }
            guard result == 0 else { throw LocalPrivateFileWriteError.outcomeUncertain }
            try hooks.afterCommit?()
            guard parentPathMatches(parent, parentIdentity),
                  let installed = try destination(name, parent: parentFD), sameNode(installed, stageIdentity) else { throw LocalPrivateFileWriteError.outcomeUncertain }
            try requirePrivateRegular(stageFD)
            let readback = try LocalStateFile.read(url, maximumBytes: maximumBytes)
            guard readback == data else { throw LocalPrivateFileWriteError.outcomeUncertain }
            // Directory fsync supports crash durability where provided. If it fails after
            // commit, report uncertainty rather than falsely promising durable installation.
            guard fsync(parentFD) == 0 else { throw LocalPrivateFileWriteError.outcomeUncertain }
        } catch {
            if commitAttempted { throw LocalPrivateFileWriteError.outcomeUncertain }
            if let error = error as? LocalPrivateFileWriteError { throw error }
            throw LocalPrivateFileWriteError.privateStagingFailed
        }
    }

    static func validateLocalVolume(flags: UInt32) throws {
        guard flags & UInt32(MNT_LOCAL) != 0 else { throw LocalPrivateFileWriteError.invalidDestination }
    }

    private static func rawEntry(_ name: String, parent: Int32) throws -> stat {
        var value = stat()
        guard name.withCString({ fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw LocalPrivateFileWriteError.destinationChanged }
        return value
    }
    private static func destination(_ name: String, parent: Int32) throws -> stat? {
        var value = stat()
        let result = name.withCString { fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            guard errno == ENOENT else { throw LocalPrivateFileWriteError.invalidDestination }
            return nil
        }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_flags & UInt32(SF_DATALESS) == 0 else { throw LocalPrivateFileWriteError.unsafeDestination }
        return value
    }
    private static func requirePrivateRegular(_ descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_mode & mode_t(0o777) == mode_t(0o600), value.st_uid == geteuid(),
              value.st_flags & UInt32(SF_DATALESS) == 0 else { throw LocalPrivateFileWriteError.privateStagingFailed }
    }
    private static func sameNode(_ first: stat, _ second: stat) -> Bool { first.st_dev == second.st_dev && first.st_ino == second.st_ino }
    private static func sameSnapshot(_ first: stat?, _ second: stat?) -> Bool {
        switch (first, second) {
        case (nil, nil): true
        case (.some(let first), .some(let second)):
            sameNode(first, second) && first.st_size == second.st_size && first.st_mode == second.st_mode && first.st_flags == second.st_flags &&
                first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
                first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
        default: false
        }
    }
    private static func parentPathMatches(_ parent: URL, _ expected: stat) -> Bool {
        var current = stat()
        return parent.path.withCString { lstat($0, &current) } == 0 &&
            current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && sameNode(current, expected)
    }
}
