import CryptoKit
import Darwin
import Foundation
import PolicyMetadataProcess
@testable import Relay

/// Held fixture diagnostics only. This cannot launch/signal a process, read a
/// source body, grant input, or fabricate the sealed ProcessStarted payload.
nonisolated final class StandardControlRuntimeWitness: Sendable {
    enum Failure: Error { case manifest, lifetime, parent, workspace, file, deadline, receipt }
    private let directory: URL
    private let expectedPath: URL
    private let expectedSHA256: String
    private let expectedCodeDirectoryHash: Data
    private let nonce: UUID
    private let scene: String
    private let host: Identity
    private struct Identity: Sendable, Equatable {
        let pid: Int32, start: UInt64, path: String
        static func read(_ pid: Int32) throws -> Identity {
            var start: UInt64 = 0, bytes = [CChar](repeating: 0, count: 4_096)
            let status = bytes.withUnsafeMutableBufferPointer { relay_policy_process_identity(pid, &start, $0.baseAddress, $0.count) }
            guard status == 0, start > 0 else { throw Failure.lifetime }
            return .init(pid: pid, start: start, path: String(cString: bytes))
        }
    }
    init(sceneDirectory: URL, nonce: UUID, scene: String, runtimeManifest: [String: Any]) throws {
        guard let cli = (runtimeManifest["runtime"] as? [String: [String: Any]])?["cli"],
              let path = cli["path"] as? String, path.hasPrefix("/"), !path.contains("\0"),
              let hash = cli["sha256"] as? String, hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let code = cli["codeDirectoryHash"] as? String, let data = Data(base64Encoded: code), !data.isEmpty else { throw Failure.manifest }
        expectedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath(); expectedSHA256 = hash
        expectedCodeDirectoryHash = data; self.nonce = nonce; self.scene = scene
        host = try Identity.read(ProcessInfo.processInfo.processIdentifier)
        directory = sceneDirectory.appendingPathComponent("runtime-processes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Self.ownedDirectory(directory)
    }
    /// Runs synchronously inline after Process.run, without a MainActor hop.
    /// Receipt failure throws before initialize; the real open owner closes CLI.
    func record(_ started: OwnedNativeComputerUseClient.ProcessStarted) throws {
        let actual = try Identity.read(started.processIdentifier)
        guard actual.pid != host.pid, actual.start >= host.start,
              actual.path.utf8.elementsEqual(expectedPath.path.utf8),
              actual.path.utf8.elementsEqual(started.executable.url.path.utf8),
              started.executable.codeDirectoryHash == expectedCodeDirectoryHash,
              try Identity.read(host.pid) == host else { throw Failure.lifetime }
        var parent: Int32 = 0
        guard relay_policy_process_parent(actual.pid, &parent) == 0, parent == host.pid else { throw Failure.parent }
        try Self.ownedDirectory(started.workspace)
        let workspace = started.workspace.resolvingSymlinksInPath(), temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard workspace.deletingLastPathComponent() == temporary,
              workspace.lastPathComponent.hasPrefix("RelayNativeObservation-"),
              UUID(uuidString: String(workspace.lastPathComponent.dropFirst("RelayNativeObservation-".count))) != nil else { throw Failure.workspace }
        let argv = try Self.arguments(of: actual.pid, expectedExecutable: expectedPath)
        // Deliberately never decode/log kernel environment data. The C bridge
        // returns only kernel argc entries and wipes its temporary whole buffer.
        let hash = try Self.hash(expectedPath)
        guard hash == expectedSHA256, try Identity.read(actual.pid) == actual else { throw Failure.lifetime }
        try Self.ownedDirectory(directory)
        let receipt: [String: Any] = ["nonce": nonce.uuidString, "scene": scene,
            "processIdentifier": actual.pid, "kernelStart": actual.start, "executable": actual.path,
            "executableSHA256": hash, "codeDirectoryHash": started.executable.codeDirectoryHash.base64EncodedString(),
            "workspace": started.workspace.path, "canonicalWorkspace": workspace.path,
            "hostPID": host.pid, "hostKernelStart": host.start, "parentPID": parent,
            "argc": argv.count, "argvBase64": argv.map { $0.base64EncodedString() },
            "source": "Actual Process.run callback; diagnostic only, not signaling/input/helper authority."]
        let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
        guard bytes.count <= 16_384 else { throw Failure.receipt }
        let path = directory.appendingPathComponent("\(actual.pid)-\(actual.start).json")
        let fd = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw Failure.receipt }
        defer { Darwin.close(fd) }
        var position = 0
        try bytes.withUnsafeBytes { raw in
            guard let start = raw.baseAddress else { throw Failure.receipt }
            while position < bytes.count {
                let count = Darwin.write(fd, start.advanced(by: position), bytes.count - position)
                if count > 0 { position += count }
                else if count == 0 || errno != EINTR { throw Failure.receipt }
            }
        }
        guard fsync(fd) == 0, try Identity.read(actual.pid) == actual else { throw Failure.receipt }
        try Self.ownedDirectory(directory)
    }
    func registeredCount() throws -> Int {
        try Self.ownedDirectory(directory)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
    }
    static func arguments(of pid: Int32, expectedExecutable: URL) throws -> [Data] {
        var argumentBytes = [CChar](repeating: 0, count: 65_536), used = 0, argumentCount: Int32 = 0
        let status = argumentBytes.withUnsafeMutableBufferPointer {
            relay_policy_process_arguments(pid, $0.baseAddress, $0.count, &used, &argumentCount)
        }
        guard status == 0, used > 0, used <= argumentBytes.count, argumentCount > 0 else { throw Failure.lifetime }
        let raw = Data(argumentBytes.prefix(used).map { UInt8(bitPattern: $0) })
        let parts = raw.split(separator: 0, omittingEmptySubsequences: false)
        guard parts.last?.isEmpty == true, parts.count == Int(argumentCount) + 1 else { throw Failure.lifetime }
        let argv = parts.dropLast().map(Data.init)
        guard argv.first == Data(expectedExecutable.path.utf8) else { throw Failure.lifetime }
        return argv
    }
    private static func ownedDirectory(_ path: URL) throws {
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.workspace }
    }
    private static func hash(_ path: URL) throws -> String {
        let fd = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.file }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size > 0,
              before.st_size <= 512 * 1_024 * 1_024 else { throw Failure.file }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var hash = SHA256(), read: Int64 = 0, bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { read += Int64(count); guard read <= before.st_size else { throw Failure.file }; hash.update(data: Data(bytes.prefix(count))) }
            else if count == 0 { break }
            else if errno != EINTR { throw Failure.file }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, read == before.st_size, before.st_dev == after.st_dev,
              before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.file }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
