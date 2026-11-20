import CryptoKit
import Darwin
import Foundation

/// The one actual filename producer. It opens only selected roots and their
/// descendants, reads directory entries/stat metadata, and never reads file
/// contents. The snapshot is an observation, not a lock on the filesystem.
nonisolated enum FilenameSearchTraversal {
    struct Metadata: Equatable, Sendable {
        let device: UInt64, inode: UInt64, mode: UInt16, links: UInt64, flags: UInt32
        let bytes: Int64, modifiedSeconds: Int64, modifiedNanos: Int64
        let changedSeconds: Int64, changedNanos: Int64
        init(_ value: stat) {
            device = UInt64(UInt32(bitPattern: value.st_dev)); inode = UInt64(value.st_ino)
            mode = UInt16(value.st_mode); links = UInt64(value.st_nlink); flags = value.st_flags
            bytes = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
        var kind: mode_t { mode_t(mode) & S_IFMT }
        var encoded: Data {
            FilenameSearchTraversal.frame([device, inode, UInt64(mode), links, UInt64(flags)].map { Data(String($0).utf8) }
                + [bytes, modifiedSeconds, modifiedNanos, changedSeconds, changedNanos].map { Data(String($0).utf8) })
        }
    }
    struct Root: Equatable, Sendable {
        let grantID: UUID, input: String, path: String, writable: Bool, metadata: Metadata
    }
    struct Match: Equatable, Sendable {
        let path: String, name: String, bytes: Int, metadata: Metadata
    }
    enum Limit: String, Sendable, Hashable, CaseIterable {
        case entries, matches, outputBytes, depth, nonlocal, unavailableEntry
    }
    struct Snapshot: Equatable, Sendable {
        let query: String, roots: [Root], matches: [Match]
        let visitedEntries: Int, skippedSymlinks: Int, limits: [Limit]
        let traversalDigest: Data
        var truncated: Bool { !limits.isEmpty }
        var sourceID: Data {
            Data(SHA256.hash(data: FilenameSearchTraversal.frame([Data("relay.filename-query.metadata.v1".utf8), Data(query.utf8),
                FilenameSearchTraversal.frame(roots.flatMap { [Data($0.grantID.uuidString.utf8), Data($0.input.utf8), Data($0.path.utf8),
                    Data([$0.writable ? 1 : 0]), $0.metadata.encoded] }), traversalDigest,
                FilenameSearchTraversal.frame(matches.flatMap { [Data($0.path.utf8), Data($0.name.utf8), $0.metadata.encoded] }),
                Data(String(visitedEntries).utf8), Data(String(skippedSymlinks).utf8),
                FilenameSearchTraversal.frame(limits.map { Data($0.rawValue.utf8) })])))
        }
    }
    enum Failure: Error { case unavailable, timedOut }
    // Existing traversal admission limits; no additional task/action count cap.
    static let maximumEntries = 5_000, maximumMatches = 100, maximumOutputBytes = 9_000, maximumDepth = 8

    static func frame(_ pieces: [Data]) -> Data {
        var result = Data()
        for piece in pieces {
            var size = UInt64(piece.count).bigEndian
            withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }; result.append(piece)
        }
        return result
    }
    static func grantDigest(_ grants: [ScopeGrant]) throws -> Data {
        guard (1...20).contains(grants.count), Set(grants.map(\.id)).count == grants.count,
              grants.allSatisfy({ $0.path.utf8.count <= 4_096 }) else { throw Failure.unavailable }
        return Data(SHA256.hash(data: FilenameSearchTraversal.frame(grants.sorted { $0.id.uuidString < $1.id.uuidString }.flatMap {
            [Data($0.id.uuidString.utf8), Data($0.path.utf8), Data([$0.writable ? 1 : 0])]
        })))
    }

    @concurrent static func capture(query: String, grants: [ScopeGrant], deadline: ContinuousClock.Instant,
                                    stillPending: @escaping @Sendable () -> Bool) async throws -> Snapshot {
        let query = try ScopedFileOperations.validatedQuery(query)
        _ = try grantDigest(grants)
        var state = State(query: query, grants: grants, deadline: deadline, stillPending: stillPending)
        for grant in grants.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try state.check()
            // Canonicalization is a grant check, not permission to adopt a new
            // root later. Both literal grant and actual root identity are bound.
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: (grant.path as NSString).expandingTildeInPath)) == nil else {
                throw Failure.unavailable
            }
            let url = try ToolPolicy.scopedURL(grant.path, grants: grants)
            let path = url.path
            guard !path.utf8.contains(0), path.utf8.count <= 4_096 else { throw Failure.unavailable }
            let before = try metadata(path: path)
            guard before.kind == S_IFDIR || before.kind == S_IFREG else { throw Failure.unavailable }
            let fd = open(path, (before.kind == S_IFDIR ? O_RDONLY | O_DIRECTORY : O_EVTONLY)
                | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unavailable }
            do {
                defer { close(fd) }
                guard try metadata(fd: fd) == before else { throw Failure.unavailable }
                state.roots.append(Root(grantID: grant.id, input: grant.path, path: path, writable: grant.writable, metadata: before))
                state.note("root", path: path, metadata: before)
                if !isLocal(fd) { state.limit(.nonlocal) }
                else if before.flags & UInt32(UF_HIDDEN) != 0 || url.lastPathComponent.hasPrefix(".") { state.note("hidden-root", path: path) }
                else if before.kind == S_IFREG {
                    guard state.visited < maximumEntries else { state.limit(.entries); continue }
                    state.visited += 1
                    try state.match(path: path, name: url.lastPathComponent, metadata: before)
                } else if !state.stopped { try state.directory(fd: fd, path: path, depth: 0) }
                else { state.noteSkippedWork() }
                try state.check()
                guard try metadata(fd: fd) == before, try metadata(path: path) == before,
                      try ToolPolicy.scopedURL(grant.path, grants: grants).path.utf8.elementsEqual(path.utf8) else { throw Failure.unavailable }
            }
        }
        try state.check()
        let limits = Limit.allCases.filter { state.limits.contains($0) }
        return Snapshot(query: query, roots: state.roots, matches: state.matches,
            visitedEntries: state.visited, skippedSymlinks: state.skipped, limits: limits,
            traversalDigest: Data(state.digest.finalize()))
    }

    private struct State {
        let query: String, grants: [ScopeGrant], deadline: ContinuousClock.Instant
        let stillPending: @Sendable () -> Bool
        var roots: [Root] = [], matches: [Match] = [], seen = Set<Data>()
        var visited = 0, skipped = 0, outputBytes = 0, limits = Set<Limit>(), digest = SHA256()
        var stopped: Bool { visited >= maximumEntries || matches.count >= maximumMatches || outputBytes >= maximumOutputBytes }
        func check() throws {
            try Task.checkCancellation()
            guard stillPending() else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
        }
        mutating func limit(_ value: Limit) { limits.insert(value) }
        mutating func noteSkippedWork() {
            if visited >= maximumEntries { limit(.entries) }
            if matches.count >= maximumMatches { limit(.matches) }
            if outputBytes >= maximumOutputBytes { limit(.outputBytes) }
        }
        mutating func note(_ kind: String, path: String, metadata: Metadata? = nil) {
            digest.update(data: FilenameSearchTraversal.frame([Data(kind.utf8), Data(path.utf8), metadata?.encoded ?? Data()]))
        }
        mutating func match(path: String, name: String, metadata: Metadata) throws {
            guard ScopedFileOperations.filenameMatches(name, query: query), seen.insert(Data(path.utf8)).inserted else { return }
            guard matches.count < maximumMatches else { limit(.matches); return }
            let cost = path.utf8.count + name.utf8.count + 96
            guard outputBytes + cost <= maximumOutputBytes else { limit(.outputBytes); return }
            outputBytes += cost
            matches.append(Match(path: path, name: name, bytes: max(0, Int(clamping: metadata.bytes)), metadata: metadata))
        }
        mutating func directory(fd: Int32, path: String, depth: Int) throws {
            try check()
            let before = try FilenameSearchTraversal.metadata(fd: fd)
            guard before.kind == S_IFDIR else { throw Failure.unavailable }
            let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0, let directory = fdopendir(duplicate) else {
                if duplicate >= 0 { close(duplicate) }; throw Failure.unavailable
            }
            // fdopendir owns only this duplicate. The original remains anchored.
            defer { closedir(directory) }
            var names: [Data] = []
            while true {
                try check(); errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw Failure.unavailable }; break
                }
                let length = Int(entry.pointee.d_namlen)
                guard length > 0, length <= Int(MAXNAMLEN) else { throw Failure.unavailable }
                let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Data($0.prefix(length)) }
                if bytes == Data(".".utf8) || bytes == Data("..".utf8) { continue }
                guard visited < maximumEntries else { limit(.entries); break }
                visited += 1; names.append(bytes)
            }
            names.sort { $0.lexicographicallyPrecedes($1) }
            for name in names { digest.update(data: FilenameSearchTraversal.frame([Data("member".utf8), Data(path.utf8), name])) }
            var observed: [(String, Metadata)] = []
            for raw in names {
                try check()
                guard let name = String(data: raw, encoding: .utf8), !raw.contains(0), !name.contains("/") else { throw Failure.unavailable }
                let childPath = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name).path
                let value = try FilenameSearchTraversal.metadata(name: name, parent: fd)
                observed.append((name, value)); note("entry", path: childPath, metadata: value)
                if value.kind == S_IFLNK { skipped += 1; continue }
                if value.flags & UInt32(UF_HIDDEN) != 0 || name.hasPrefix(".") || ["node_modules", "DerivedData", "Pods"].contains(name) { continue }
                if depth >= maximumDepth { limit(.depth); continue }
                if value.kind == S_IFREG {
                    let child = name.withCString { openat(fd, $0, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
                    guard child >= 0 else { throw Failure.unavailable }
                    do {
                        defer { close(child) }
                        guard try FilenameSearchTraversal.metadata(fd: child) == value else { throw Failure.unavailable }
                        if isLocal(child) { try match(path: childPath, name: name, metadata: value) }
                        else { limit(.nonlocal) }
                    }
                } else if value.kind == S_IFDIR {
                    if depth >= maximumDepth { limit(.depth); continue }
                    let child = name.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
                    guard child >= 0 else { throw Failure.unavailable }
                    do {
                        defer { close(child) }
                        guard try FilenameSearchTraversal.metadata(fd: child) == value else { throw Failure.unavailable }
                        if !isLocal(child) { limit(.nonlocal); continue }
                        // Only package metadata is queried; never file content.
                        let package = try URL(fileURLWithPath: childPath).resourceValues(forKeys: [.isPackageKey]).isPackage
                        guard let package else { throw Failure.unavailable }
                        if !package {
                            if !stopped { try self.directory(fd: child, path: childPath, depth: depth + 1) }
                            else { noteSkippedWork() }
                        }
                    }
                }
                if matches.count >= maximumMatches { limit(.matches); break }
                if limits.contains(.outputBytes) { break }
            }
            // Parent and all observed entries must still be the actual objects
            // enumerated. No unreadable entry is silently dropped from proof.
            for (name, expected) in observed {
                try check()
                guard try FilenameSearchTraversal.metadata(name: name, parent: fd) == expected else { throw Failure.unavailable }
            }
            guard try FilenameSearchTraversal.metadata(fd: fd) == before else { throw Failure.unavailable }
            note("directory-end", path: path, metadata: before)
        }
    }
    private static func metadata(fd: Int32) throws -> Metadata {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw Failure.unavailable }; return Metadata(value)
    }
    private static func metadata(path: String) throws -> Metadata {
        var value = stat(); guard path.withCString({ lstat($0, &value) }) == 0 else { throw Failure.unavailable }; return Metadata(value)
    }
    private static func metadata(name: String, parent: Int32) throws -> Metadata {
        var value = stat(); guard name.withCString({ fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw Failure.unavailable }; return Metadata(value)
    }
    private static func isLocal(_ fd: Int32) -> Bool {
        var value = statfs(); return fstatfs(fd, &value) == 0 && value.f_flags & UInt32(MNT_LOCAL) != 0
    }
}
