import Foundation
import CryptoKit

/// Files are usable only through explicit grants. Resolve symlinks before comparing components.
enum ToolPolicy {
    nonisolated static func scopedURL(_ path: String, grants: [ScopeGrant], writing: Bool = false) throws -> URL {
        guard path.count <= 4096, path.hasPrefix("/") || path.hasPrefix("~/") else { throw RelayError.message("Use an absolute path from the selected files or folders.") }
        let url = try canonicalURL(path)
        let manager = FileManager.default
        let allowed = grants.contains { grant in
            guard !writing || grant.writable else { return false }
            guard let root = try? canonicalURL(grant.path) else { return false }
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &directory) else { return false }
            if directory.boolValue { return url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") }
            return url.path == root.path
        }
        guard allowed else { throw RelayError.message(writing ? "This destination is not inside a writable selected file or folder. Add it in Context and enable writing." : "This path is outside the selected files and folders. Ask the user to grant access.") }
        return url
    }

    /// Foundation does not consistently resolve a symlink when the final output does not yet
    /// exist. Walk every component (including dangling links) before permitting a new write.
    nonisolated static func canonicalURL(_ path: String) throws -> URL {
        var components = (path as NSString).expandingTildeInPath.split(separator: "/").map(String.init)
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        var links = 0
        while !components.isEmpty {
            try Task.checkCancellation()
            let part = components.removeFirst()
            if part == "." { continue }
            if part == ".." { resolved.deleteLastPathComponent(); continue }
            let candidate = resolved.appendingPathComponent(part)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) {
                links += 1
                guard links <= 40 else { throw RelayError.message("Too many symbolic links in selected path.") }
                if destination.hasPrefix("/") { resolved = URL(fileURLWithPath: "/", isDirectory: true) }
                components = destination.split(separator: "/").map(String.init) + components
            } else { resolved = candidate }
        }
        return resolved
    }

    static func fingerprint(_ call: ToolCall) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(call)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileFingerprint(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_048_576 else { throw RelayError.message("Only regular UTF-8 files up to 1 MB can be replaced by this tool.") }
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func artifactFingerprint(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 10_485_760 else { throw RelayError.message("Existing document must be a regular file up to 10 MB.") }
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func webURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            throw RelayError.message("Only an explicit HTTP or HTTPS URL without embedded credentials can be opened.")
        }
        return url
    }

    static func validate(_ call: ToolCall, against definitions: [ToolDefinition]) throws {
        guard let definition = definitions.first(where: { $0.name == call.name }), let schema = definition.parameters.object, let properties = schema["properties"]?.object else { throw RelayError.message("Unsupported tool: \(call.name).") }
        let required: [String]
        if case .array(let values) = schema["required"] { required = values.compactMap(\.string) } else { required = [] }
        guard Set(call.arguments.keys).isSubset(of: Set(properties.keys)) else { throw RelayError.message("Unexpected arguments for \(call.name).") }
        for name in required where call.arguments[name] == nil { throw RelayError.message("Missing argument \(name) for \(call.name).") }
        for (name, value) in call.arguments {
            guard let field = properties[name]?.object, let type = field["type"]?.string else { throw RelayError.message("Invalid tool schema.") }
            let valid: Bool = switch (type, value) {
            case ("string", .string(let text)): text.count <= 1_048_576
            case ("boolean", .bool): true
            case ("integer", .number(let number)): number.isFinite && number.rounded() == number
            default: false
            }
            guard valid else { throw RelayError.message("Invalid \(name) for \(call.name): expected \(type).") }
        }
    }
}

/// Complete semantic inputs used by a pending AX button review. Values are not logged;
/// only the digest is retained in the one-use authorization ticket.
nonisolated struct AXReviewField: Codable, Sendable, Equatable {
    enum AvailabilityEvidence: String, Codable, Sendable {
        case writableNativeTextArea
    }
    var identity: String
    var label: String
    var value: String
    var enabled: Bool?
    var availabilityEvidence: AvailabilityEvidence? = nil

    var availabilityDescription: String {
        if let enabled { return "enabled=\(enabled)" }
        if availabilityEvidence == .writableNativeTextArea {
            return "AXEnabled not reported; text value, focus and selection are writable"
        }
        return "AXEnabled not reported"
    }
}

nonisolated struct AXReviewContext: Codable, Sendable, Equatable {
    var windowIdentity: String
    var title: String
    var buttonFingerprint: String
    var fields: [AXReviewField]

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "invalid-context" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
