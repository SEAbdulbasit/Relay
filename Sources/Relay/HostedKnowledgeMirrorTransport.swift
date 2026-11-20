import CryptoKit
import Foundation

nonisolated struct HostedKnowledgeMirrorAccess: Decodable, Equatable, Sendable {
    let notesRead: Int
    let toolCalls: Int
    let lastAccessTimestamp: TimeInterval?

    var lastAccess: Date? { lastAccessTimestamp.map { Date(timeIntervalSince1970: $0) } }

    enum CodingKeys: String, CodingKey {
        case notesRead = "notes_read_24h"
        case toolCalls = "tool_calls_24h"
        case lastAccessTimestamp = "last_access"
    }
}

/// Wire format for a Sentient-compatible mirror operated by the user or their provider.
nonisolated enum HostedKnowledgeMirrorTransport {
    enum Failure: LocalizedError {
        case invalidEndpoint, invalidArchive, invalidCredential, requestFailed

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "Enter the HTTPS origin of a compatible mirror."
            case .invalidArchive: "The Markdown vault could not be safely packaged within the mirror’s limits."
            case .invalidCredential: "The mirror identity could not be loaded from Keychain."
            case .requestFailed: "The mirror did not accept the request. Check the service and try again."
            }
        }
    }

    static func origin(_ input: String) throws -> URL {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 512, raw.utf8.allSatisfy({ (33...126).contains($0) && $0 != 92 }),
              var parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(), !host.isEmpty,
              !host.contains(where: { "/\\?#@%".contains($0) }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.percentEncodedPath),
              parts.port.map({ (1...65_535).contains($0) }) ?? true else { throw Failure.invalidEndpoint }
        parts.scheme = "https"
        parts.host = host
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { throw Failure.invalidEndpoint }
        return url
    }

    static func password() -> String {
        let random = SymmetricKey(size: .bits256)
        return random.withUnsafeBytes { base64URL(Data($0.prefix(18))) }
    }

    static func userID(_ password: String) -> String {
        let key = derivedKey(password, info: "vault-user-id")
        return key.withUnsafeBytes { String(base64URL(Data($0)).prefix(20)) }
    }

    static func url(origin: URL, password: String, resource: String) -> URL {
        origin.appending(path: "u_\(userID(password))/p_\(password)/\(resource)")
    }

    static func seal(_ bytes: Data, password: String) throws -> Data {
        let box = try AES.GCM.seal(bytes, using: derivedKey(password, info: "vault-content-key"),
                                   authenticating: Data(userID(password).utf8))
        guard let combined = box.combined else { throw Failure.invalidArchive }
        return Data([1]) + combined
    }

    @concurrent static func snapshot(root: URL) async throws -> (fingerprint: String, notes: [String: Data]) {
        var limits = KnowledgeVaultValidation.Limits()
        limits.maximumTotalBytes = 58_000_000
        let snapshot = try KnowledgeVaultValidation.markdownSnapshot(root, limits: limits)
        // Reupload old snapshots once so existing mirrors also get composed paths.
        return ("nfc:" + snapshot.fingerprint, snapshot.notes)
    }

    @concurrent static func encryptedArchive(notes: [String: Data], password: String) async throws -> Data {
        try seal(zip(notes), password: password)
    }

    /// ZIP32 with UTF-8 paths and stored entries. Plaintext is never staged on disk.
    static func zip(_ notes: [String: Data]) throws -> Data {
        guard let entryCount = UInt16(exactly: notes.count) else { throw Failure.invalidArchive }
        var archive = Data()
        var central = Data()
        for (sourcePath, bytes) in notes.sorted(by: { $0.key < $1.key }) {
            // macOS can enumerate decomposed names. The mirror matches paths
            // byte for byte, so archive a stable, composed spelling for clients.
            let path = sourcePath.precomposedStringWithCanonicalMapping
            let name = Data(path.utf8)
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard let nameLength = UInt16(exactly: name.count),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.contains("\\"), !name.contains(0),
                  let size = UInt32(exactly: bytes.count), let offset = UInt32(exactly: archive.count) else {
                throw Failure.invalidArchive
            }

            var metadata = Data()
            metadata.appendLittleEndian(UInt16(20)) // minimum ZIP version
            metadata.appendLittleEndian(UInt16(0x800)) // UTF-8
            metadata.appendLittleEndian(UInt16(0)) // stored
            metadata.appendLittleEndian(UInt32(0x00210000)) // DOS date 1980-01-01
            metadata.appendLittleEndian(crc32(bytes))
            metadata.appendLittleEndian(size)
            metadata.appendLittleEndian(size)
            metadata.appendLittleEndian(nameLength)
            metadata.appendLittleEndian(UInt16(0)) // extra field length

            archive.appendLittleEndian(UInt32(0x04034b50))
            archive.append(metadata)
            archive.append(name)
            archive.append(bytes)

            central.appendLittleEndian(UInt32(0x02014b50))
            central.appendLittleEndian(UInt16(20)) // version made by
            central.append(metadata)
            central.appendLittleEndian(UInt16(0)) // comment length
            central.appendLittleEndian(UInt16(0)) // disk number
            central.appendLittleEndian(UInt16(0)) // internal attributes
            central.appendLittleEndian(UInt32(0)) // external attributes
            central.appendLittleEndian(offset)
            central.append(name)
        }
        guard archive.count + central.count + 22 <= 59_000_000 else { throw Failure.invalidArchive }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendLittleEndian(UInt32(0x06054b50))
        archive.appendLittleEndian(UInt32(0)) // both disk numbers
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(UInt32(central.count))
        archive.appendLittleEndian(centralOffset)
        archive.appendLittleEndian(UInt16(0)) // comment length
        return archive
    }

    static func send(_ request: URLRequest, session: URLSession) async throws {
        do {
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                throw Failure.requestFailed
            }
            switch request.httpMethod {
            case "POST":
                guard status == 200, data.count <= 4_096,
                      let receipt = try? JSONDecoder().decode(UploadReceipt.self, from: data),
                      receipt.ok, receipt.files >= 0, receipt.leaseDays > 0 else {
                    throw Failure.requestFailed
                }
            case "DELETE":
                guard status == 204 else { throw Failure.requestFailed }
            default:
                throw Failure.requestFailed
            }
        } catch {
            // URLSession errors can include the full bearer link. Never display or persist them.
            throw Failure.requestFailed
        }
    }

    static func readAccess(at url: URL, session: URLSession) async throws -> HostedKnowledgeMirrorAccess {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_096,
                  let access = try? JSONDecoder().decode(HostedKnowledgeMirrorAccess.self, from: data),
                  access.notesRead >= 0, access.toolCalls >= 0,
                  access.lastAccessTimestamp.map({ $0.isFinite && $0 >= 0 && $0 <= 253_402_300_799 }) ?? true else {
                throw Failure.requestFailed
            }
            return access
        } catch {
            // The request URL contains the mirror credential.
            throw Failure.requestFailed
        }
    }

    private struct UploadReceipt: Decodable {
        let ok: Bool
        let files: Int
        let leaseDays: Int

        enum CodingKeys: String, CodingKey {
            case ok, files
            case leaseDays = "lease_days"
        }
    }

    private static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func derivedKey(_ password: String, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
                               salt: Data("sentient-os-mirror-v1".utf8),
                               info: Data(info.utf8), outputByteCount: 32)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in
            (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0)
        }
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        ~bytes.reduce(UInt32.max) { crc, byte in
            (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
        }
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

nonisolated final class HostedMirrorNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
