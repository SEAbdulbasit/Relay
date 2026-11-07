import Foundation
import Darwin

func canonicalJournalDirectory(_ url: URL) throws -> String {
    guard let pointer = url.path.withCString({ realpath($0, nil) }) else { throw JournalError.unsafeLocation }
    defer { free(pointer) }; return String(cString: pointer)
}

private struct JournalFileIdentity: Equatable {
    let device: dev_t, inode: ino_t, size: off_t, mode: mode_t, links: nlink_t, owner: uid_t, flags: UInt32
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size; mode = value.st_mode; links = value.st_nlink
        owner = value.st_uid; flags = value.st_flags; modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
    var isPrivateFile: Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFREG) && mode & 0o777 == 0o600 && owner == getuid() && links == 1 && flags & UInt32(SF_DATALESS) == 0 && size >= 0
    }
}

/// This lease excludes cooperating Relay writers. It does not constrain arbitrary external writers.
/// All content and validation snapshots remain inside a checked app-private local directory.
final class JournalFiles {
    let root: URL
    let path: String
    private let rootFD: Int32
    private let rootIdentity: JournalFileIdentity
    private var leaseFD: Int32 = -1
    private var mainNode: (dev_t, ino_t)?
    private let basename = "Conversation.sqlite"

    init(root: URL) throws {
        guard root.isFileURL, root.baseURL == nil, root.path.hasPrefix("/"), root.user == nil, root.password == nil,
              root.query == nil, root.fragment == nil, root.host == nil || root.host == "" || root.host == "localhost",
              !root.path.contains("\0"), root.path.utf8.count <= 4000 else { throw JournalError.unsafeLocation }
        self.root = root
        // SQLite NOFOLLOW also rejects system path aliases such as /var -> /private/var.
        // Final-directory lstat/open checks below still reject a supplied root symlink.
        var made = false
        if root.path.withCString({ mkdir($0, 0o700) }) == 0 { made = true }
        else if errno != EEXIST { throw JournalError.unsafeLocation }
        let descriptor = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw JournalError.unsafeLocation }
        var metadata = stat(), volume = statfs()
        if made {
            guard let acl = acl_init(0) else { Darwin.close(descriptor); throw JournalError.unsafeLocation }
            let code = acl_set_fd(descriptor, acl); acl_free(UnsafeMutableRawPointer(acl))
            guard code == 0 else { Darwin.close(descriptor); throw JournalError.unsafeLocation }
        }
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & 0o777 == 0o700, metadata.st_uid == getuid(), metadata.st_flags & UInt32(SF_DATALESS) == 0,
              fstatfs(descriptor, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              Self.hasNoExtendedACL(descriptor) else { Darwin.close(descriptor); throw JournalError.unsafeLocation }
        let canonical: String
        do { canonical = try canonicalJournalDirectory(root) }
        catch { Darwin.close(descriptor); throw error }
        path = canonical + "/Conversation.sqlite"
        rootFD = descriptor; rootIdentity = JournalFileIdentity(metadata)
        leaseFD = try openPrivate(".writer.lock", create: true, exclusive: false)
        guard flock(leaseFD, LOCK_EX | LOCK_NB) == 0 else { throw JournalError.writerBusy }
        try validateRoot()
    }
    deinit { if leaseFD >= 0 { flock(leaseFD, LOCK_UN); Darwin.close(leaseFD) }; Darwin.close(rootFD) }
    private static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?; errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == ENOENT
    }
    private func validateRoot() throws {
        var descriptor = stat(), named = stat()
        guard fstat(rootFD, &descriptor) == 0, root.path.withCString({ lstat($0, &named) }) == 0,
              descriptor.st_dev == rootIdentity.device, descriptor.st_ino == rootIdentity.inode,
              named.st_dev == descriptor.st_dev, named.st_ino == descriptor.st_ino,
              named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), named.st_mode & 0o777 == 0o700, named.st_uid == getuid(),
              Self.hasNoExtendedACL(rootFD) else { throw JournalError.unsafeLocation }
    }
    private func identity(_ name: String) throws -> JournalFileIdentity? {
        var value = stat()
        if name.withCString({ fstatat(rootFD, $0, &value, AT_SYMLINK_NOFOLLOW) }) != 0 {
            if errno == ENOENT { return nil }; throw JournalError.unsafeLocation
        }
        let identity = JournalFileIdentity(value)
        guard identity.isPrivateFile, identity.size <= 160 * 1024 * 1024 else { throw JournalError.unsafeLocation }
        return identity
    }
    private func openPrivate(_ name: String, create: Bool, exclusive: Bool) throws -> Int32 {
        let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0) | (exclusive ? O_EXCL : 0)
        let descriptor = name.withCString { openat(rootFD, $0, flags, 0o600) }
        guard descriptor >= 0 else { throw JournalError.unsafeLocation }
        var metadata = stat()
        if create, exclusive {
            guard let acl = acl_init(0) else { Darwin.close(descriptor); throw JournalError.unsafeLocation }
            let code = acl_set_fd(descriptor, acl); acl_free(UnsafeMutableRawPointer(acl))
            guard code == 0 else { Darwin.close(descriptor); throw JournalError.unsafeLocation }
        }
        guard fstat(descriptor, &metadata) == 0, JournalFileIdentity(metadata).isPrivateFile, Self.hasNoExtendedACL(descriptor) else {
            Darwin.close(descriptor); throw JournalError.unsafeLocation
        }
        return descriptor
    }
    func prepareNewOrValidate(_ validate: (String) throws -> Void) throws -> Bool {
        try validateRoot()
        let main = try identity(basename), wal = try identity(basename + "-wal"), shm = try identity(basename + "-shm")
        guard main != nil || (wal == nil && shm == nil) else { throw JournalError.corrupt }
        if main == nil {
            let descriptor = try openPrivate(basename, create: true, exclusive: true)
            defer { Darwin.close(descriptor) }
            guard fsync(descriptor) == 0, fsync(rootFD) == 0 else { throw JournalError.unsafeLocation }
            let created = try identity(basename)!
            mainNode = (created.device, created.inode)
            return true
        }
        let temporary = root.appendingPathComponent(".validation-" + UUID().uuidString, isDirectory: true)
        guard temporary.path.withCString({ mkdir($0, 0o700) }) == 0 else { throw JournalError.unsafeLocation }
        var owned = stat()
        guard temporary.path.withCString({ lstat($0, &owned) }) == 0 else { throw JournalError.unsafeLocation }
        defer {
            var current = stat()
            if temporary.path.withCString({ lstat($0, &current) }) == 0, current.st_dev == owned.st_dev, current.st_ino == owned.st_ino {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        try copy(basename, expected: main!, to: temporary.appendingPathComponent(basename))
        if let wal { try copy(basename + "-wal", expected: wal, to: temporary.appendingPathComponent(basename + "-wal")) }
        // SHM is intentionally rebuilt only in the private validation snapshot.
        try validate(canonicalJournalDirectory(temporary) + "/" + basename)
        try validateRoot()
        guard try identity(basename) == main, try identity(basename + "-wal") == wal, try identity(basename + "-shm") == shm else { throw JournalError.unsafeLocation }
        mainNode = (main!.device, main!.inode)
        return false
    }
    private func copy(_ name: String, expected: JournalFileIdentity, to destination: URL) throws {
        let input = try openPrivate(name, create: false, exclusive: false); defer { Darwin.close(input) }
        var before = stat(); guard fstat(input, &before) == 0, JournalFileIdentity(before) == expected else { throw JournalError.unsafeLocation }
        let output = destination.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard output >= 0 else { throw JournalError.unsafeLocation }; defer { Darwin.close(output) }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024), total: Int64 = 0
        while true {
            let count = Darwin.read(input, &bytes, bytes.count)
            guard count >= 0 else { throw JournalError.unsafeLocation }; if count == 0 { break }
            total += Int64(count); guard total <= expected.size else { throw JournalError.unsafeLocation }
            var written = 0
            while written < count {
                let result = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: written), count - written) }
                guard result > 0 else { throw JournalError.unsafeLocation }; written += result
            }
        }
        var after = stat(); guard total == expected.size, fstat(input, &after) == 0, JournalFileIdentity(after) == expected else { throw JournalError.unsafeLocation }
    }
    func validateLiveFiles() throws {
        try validateRoot()
        guard let main = try identity(basename), let mainNode, main.device == mainNode.0, main.inode == mainNode.1 else { throw JournalError.unsafeLocation }
        for name in [basename, basename + "-wal", basename + "-shm"] {
            if try identity(name) != nil {
                let descriptor = try openPrivate(name, create: false, exclusive: false); Darwin.close(descriptor)
            }
        }
    }
    func walBytes() throws -> Int { try Int(identity(basename + "-wal")?.size ?? 0) }
}
