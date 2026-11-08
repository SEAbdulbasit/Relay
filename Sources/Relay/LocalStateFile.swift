import Foundation
import Darwin

nonisolated enum LocalStateFileError: LocalizedError, Equatable {
    case invalidLimit
    case invalidURL
    case inspectionFailed(Int32)
    case openFailed(Int32)
    case notRegularFile
    case datalessFile
    case sizeLimitExceeded
    case changedDuringRead
    case readFailed

    var errorDescription: String? {
        switch self {
        case .invalidLimit: "Choose a local read limit from zero through 64 MiB."
        case .invalidURL: "Only an absolute local file URL without credentials or URL parameters can be read."
        case .inspectionFailed(let code): "The local file could not be inspected (POSIX \(code))."
        case .openFailed(let code): "The local file could not be opened safely (POSIX \(code))."
        case .notRegularFile: "Only a regular local file can be read; links, pipes and devices are excluded."
        case .datalessFile: "The file is not fully stored on this Mac. Download it explicitly before reading."
        case .sizeLimitExceeded: "The local file exceeds this read's size limit."
        case .changedDuringRead: "The local file changed during the read. Its contents were discarded."
        case .readFailed: "The local file could not be read completely. Its contents were discarded."
        }
    }
}

/// A bounded, non-hydrating-intent primitive for private state and explicitly selected local
/// files. It never follows a final symlink or opens a FIFO in blocking mode. Callers still own
/// source authorization and format validation; this function grants no additional access.
nonisolated enum LocalStateFile {
    static let maximumAllowedBytes = 64 * 1_024 * 1_024

    /// Metadata comes from the descriptor which supplied the returned bytes.
    /// No Codable path exists: this is a transient read observation, not authority.
    struct Metadata: Sendable, Equatable {
        let device: Int64, inode: UInt64, mode: UInt32, flags: UInt32
        let links: UInt64, size: Int64
        let modifiedSeconds: Int64, modifiedNanoseconds: Int64
        let changedSeconds: Int64, changedNanoseconds: Int64
        fileprivate init(_ value: stat) {
            device = Int64(value.st_dev); inode = UInt64(value.st_ino)
            mode = UInt32(value.st_mode); flags = value.st_flags
            links = UInt64(value.st_nlink); size = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }
    struct Snapshot: Sendable {
        let data: Data
        let metadata: Metadata
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try snapshot(url, maximumBytes: maximumBytes).data
    }

    static func snapshot(_ url: URL, maximumBytes: Int) throws -> Snapshot {
        guard (0...maximumAllowedBytes).contains(maximumBytes) else { throw LocalStateFileError.invalidLimit }
        guard url.isFileURL, url.baseURL == nil, url.path.hasPrefix("/"), !url.path(percentEncoded: false).contains("\0"), url.path.utf8.count <= 4_096,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw LocalStateFileError.invalidURL
        }
        let path = url.path
        // Check flags before opening known cloud stubs. O_NONBLOCK and the second metadata
        // check are also necessary because the directory entry can change after lstat.
        let pathBefore = try inspectPath(path)
        try validateMetadata(pathBefore, maximumBytes: maximumBytes)
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw LocalStateFileError.openFailed(errno) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw LocalStateFileError.inspectionFailed(errno) }
        try validateMetadata(before, maximumBytes: maximumBytes)
        try validateUnchanged(before: pathBefore, after: before)

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do { data = try handle.read(upToCount: maximumBytes + 1) ?? Data() }
        catch { throw LocalStateFileError.readFailed }
        guard data.count <= maximumBytes else { throw LocalStateFileError.sizeLimitExceeded }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw LocalStateFileError.inspectionFailed(errno) }
        try validateMetadata(after, maximumBytes: maximumBytes)
        try validateUnchanged(before: before, after: after)
        guard Int64(data.count) == before.st_size else { throw LocalStateFileError.readFailed }
        // A descriptor may remain valid after its name is moved/replaced. The path must
        // still identify the same stable regular file; never return a superseded source.
        let pathAfter = try inspectPath(path)
        try validateMetadata(pathAfter, maximumBytes: maximumBytes)
        try validateUnchanged(before: after, after: pathAfter)
        return Snapshot(data: data, metadata: Metadata(after))
    }

    /// Rechecks only current path metadata. A parser must consume Snapshot.data;
    /// this method never supplies substitute bytes or reopens the parser input.
    static func validateCurrent(_ metadata: Metadata, at url: URL, maximumBytes: Int) throws {
        let current = try inspectPath(url.path)
        try validateMetadata(current, maximumBytes: maximumBytes)
        guard Metadata(current) == metadata else { throw LocalStateFileError.changedDuringRead }
    }

    private static func inspectPath(_ path: String) throws -> stat {
        var value = stat()
        guard path.withCString({ lstat($0, &value) }) == 0 else { throw LocalStateFileError.inspectionFailed(errno) }
        return value
    }

    /// Internal pure checks permit testing metadata rejection without touching cloud files.
    static func validateMetadata(_ value: stat, maximumBytes: Int) throws {
        guard (0...maximumAllowedBytes).contains(maximumBytes) else { throw LocalStateFileError.invalidLimit }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw LocalStateFileError.notRegularFile }
        guard value.st_flags & UInt32(SF_DATALESS) == 0 else { throw LocalStateFileError.datalessFile }
        guard value.st_size >= 0, value.st_size <= Int64(maximumBytes) else { throw LocalStateFileError.sizeLimitExceeded }
    }

    static func validateUnchanged(before: stat, after: stat) throws {
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_flags == after.st_flags,
              before.st_nlink == after.st_nlink, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw LocalStateFileError.changedDuringRead
        }
    }
}
