import Foundation
import Darwin
import CryptoKit

/// Metadata checks only; no artifact bytes are opened. The caller supplies current grant policy.
public enum JournalArtifactAccess {
    public static func capture(visiblePath: String, isAuthorized: (String) throws -> Bool) throws -> JournalArtifactReference {
        _ = try JournalArtifactReference(visiblePath: visiblePath)
        guard try isAuthorized(visiblePath) else { throw JournalError.unsafeLocation }
        let value = try metadata(visiblePath)
        guard try isAuthorized(visiblePath), try metadata(visiblePath) == value else { throw JournalError.unsafeLocation }
        return try JournalArtifactReference(visiblePath: visiblePath, canonicalPath: value.canonicalPath, identityDigest: value.digest)
    }
    public static func validate(_ reference: JournalArtifactReference, isAuthorized: (String) throws -> Bool) throws {
        guard let path = reference.canonicalPath, let digest = reference.identityDigest else { throw JournalError.unsafeLocation }
        guard try isAuthorized(reference.visiblePath) else { throw JournalError.unsafeLocation }
        let value = try metadata(reference.visiblePath)
        guard Data(value.canonicalPath.utf8) == Data(path.utf8), value.digest == digest,
              try isAuthorized(reference.visiblePath), try metadata(reference.visiblePath) == value else { throw JournalError.unsafeLocation }
    }
    private struct Metadata: Equatable { let canonicalPath: String; let digest: Data }
    private static func metadata(_ path: String) throws -> Metadata {
        var named = stat()
        guard path.withCString({ lstat($0, &named) }) == 0, named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), named.st_flags & UInt32(SF_DATALESS) == 0 else { throw JournalError.unsafeLocation }
        guard let raw = path.withCString({ realpath($0, nil) }) else { throw JournalError.unsafeLocation }
        defer { free(raw) }
        let canonical = String(cString: raw)
        var resolved = stat()
        guard canonical.withCString({ lstat($0, &resolved) }) == 0,
              resolved.st_dev == named.st_dev, resolved.st_ino == named.st_ino else { throw JournalError.unsafeLocation }
        // Explicit fields avoid stat padding and do not claim a content checksum.
        let fields = "\(resolved.st_dev)|\(resolved.st_ino)|\(resolved.st_size)|\(resolved.st_mode)|\(resolved.st_nlink)|\(resolved.st_mtimespec.tv_sec)|\(resolved.st_mtimespec.tv_nsec)|\(resolved.st_ctimespec.tv_sec)|\(resolved.st_ctimespec.tv_nsec)"
        return Metadata(canonicalPath: canonical, digest: Data(SHA256.hash(data: Data(fields.utf8))))
    }
}
