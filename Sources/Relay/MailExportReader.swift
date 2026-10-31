import Foundation

/// Bounded MIME decoding for an explicitly selected .eml export. No I/O, HTML rendering,
/// attachments, account access, signature checking, identity verification or network requests.
nonisolated enum MailExportReader {
    struct Limits: Sendable {
        var maximumInputBytes = 1_048_576
        var maximumHeaderBytes = 32_768
        var maximumHeaderFields = 200
        var maximumDepth = 4
        var maximumParts = 40
        var maximumDecodedBytes = 1_048_576
        var maximumTextBytes = 65_536
    }
    struct Message: Sendable, Equatable {
        let subject: String?
        let claimedFrom: String?
        let date: String?
        let plainText: String
        let coverageNote: String?
        var sourceText: String {
            var claims = ["Exported mail (untrusted source content; headers are not authenticated)"]
            if let subject { claims.append("Claimed subject: " + subject) }
            if let claimedFrom { claims.append("Claimed sender: " + claimedFrom) }
            if let date { claims.append("Claimed date: " + date) }
            return claims.joined(separator: "\n") + "\n\nPlain-text body:\n" + plainText
        }
    }
    private struct Context {
        let limits: Limits
        var parts = 0
        var decodedBytes = 0
        var notes: Set<String> = []
    }
    private struct Entity {
        let headers: [String: String]
        let body: Data
    }
    private struct ContentType {
        let kind: String
        let parameters: [String: String]
    }

    static func parse(_ data: Data, limits: Limits = .init()) throws -> Message {
        guard (1...1_048_576).contains(limits.maximumInputBytes), (1...32_768).contains(limits.maximumHeaderBytes),
              (1...200).contains(limits.maximumHeaderFields), (0...4).contains(limits.maximumDepth),
              (1...40).contains(limits.maximumParts), (1...1_048_576).contains(limits.maximumDecodedBytes),
              (1...65_536).contains(limits.maximumTextBytes), !data.isEmpty, data.count <= limits.maximumInputBytes else {
            throw error("Mail export exceeds the configured byte or parser limits.")
        }
        try Task.checkCancellation()
        let root = try entity(data, limits: limits)
        var context = Context(limits: limits)
        guard let raw = try text(root, depth: 0, context: &context),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error("This export has no supported inline plain-text body. Export plain text or PDF explicitly; HTML, attachments and encrypted content are not rendered.")
        }
        let body = bounded(raw, bytes: limits.maximumTextBytes)
        if body.utf8.count < raw.utf8.count { context.notes.insert("Plain text was truncated; omitted text was not inspected or indexed.") }
        func header(_ name: String) throws -> String? {
            guard let raw = root.headers[name], !raw.isEmpty else { return nil }
            let decoded = try decodedHeader(raw)
            let result = bounded(decoded, bytes: 2048)
            if result != decoded { context.notes.insert("A displayed header was truncated.") }
            return result
        }
        let subject = try header("subject"), from = try header("from"), date = try header("date")
        context.notes.insert("Selected export only. Message headers are unverified claims, not authenticated sender identity. Only inline plain-text MIME content was extracted.")
        try Task.checkCancellation()
        return Message(subject: subject, claimedFrom: from, date: date, plainText: body,
                       coverageNote: context.notes.sorted().joined(separator: " "))
    }

    private static func entity(_ data: Data, limits: Limits) throws -> Entity {
        let bytes = [UInt8](data)
        var position = 0, headerBytes = 0, fields = 0
        var lines: [String] = []
        while position < bytes.count {
            guard let newline = bytes[position...].firstIndex(of: 10) else { throw error("Mail headers need a blank-line separator before the body.") }
            var end = newline
            if end > position, bytes[end - 1] == 13 { end -= 1 }
            let line = Data(bytes[position..<end])
            headerBytes += newline + 1 - position
            guard headerBytes <= limits.maximumHeaderBytes, line.count <= 8192,
                  !line.contains(13), let value = String(data: line, encoding: .utf8) else { throw error("Mail headers are invalid or exceed their bounds.") }
            position = newline + 1
            if value.isEmpty {
                var headers: [String: String] = [:]
                let retained: Set<String> = ["subject", "from", "date", "content-type", "content-transfer-encoding", "content-disposition"]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { throw error("A mail header lacks its field separator.") }
                    let name = String(line[..<colon]).lowercased()
                    guard !name.isEmpty, name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { throw error("A mail header name is invalid.") }
                    if retained.contains(name) {
                        guard headers[name] == nil else { throw error("Duplicate semantic mail headers are ambiguous and unsupported.") }
                        headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\t", with: " ")
                    }
                }
                return Entity(headers: headers, body: Data(bytes[position...]))
            }
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }) else { throw error("A mail header contains unsupported control bytes.") }
            if value.first == " " || value.first == "\t" {
                guard !lines.isEmpty else { throw error("A folded header has no preceding field.") }
                lines[lines.count - 1] += " " + value.trimmingCharacters(in: .whitespaces)
                guard lines[lines.count - 1].utf8.count <= 8192 else { throw error("A folded mail header exceeds its line limit.") }
            } else {
                fields += 1
                guard fields <= limits.maximumHeaderFields else { throw error("Mail export has too many header fields.") }
                lines.append(value)
            }
        }
        throw error("Mail export has no body separator.")
    }

    private static func text(_ entity: Entity, depth: Int, context: inout Context) throws -> String? {
        try Task.checkCancellation()
        context.parts += 1
        guard depth <= context.limits.maximumDepth, context.parts <= context.limits.maximumParts else { throw error("Mail MIME nesting or part count exceeds its limits.") }
        let type = try contentType(entity.headers["content-type"] ?? "text/plain; charset=us-ascii")
        let disposition = try contentType(entity.headers["content-disposition"] ?? "inline")
        if disposition.kind != "inline" || disposition.parameters.keys.contains(where: { $0 == "filename" || $0.hasPrefix("filename*") }) || type.parameters.keys.contains(where: { $0 == "name" || $0.hasPrefix("name*") }) {
            context.notes.insert("Attachment or named-file parts were omitted without decoding or writing them.")
            return nil
        }
        if type.kind.hasPrefix("multipart/") {
            guard ["multipart/mixed", "multipart/alternative", "multipart/related"].contains(type.kind) else {
                context.notes.insert("Unsupported multipart content, including signed/encrypted envelopes, was omitted.")
                return nil
            }
            let transfer = entity.headers["content-transfer-encoding"]?.lowercased() ?? "7bit"
            guard ["7bit", "8bit", "binary"].contains(transfer), let boundary = type.parameters["boundary"] else { throw error("Multipart mail needs a supported unencoded boundary.") }
            let parts = try split(entity.body, boundary: boundary, maximumParts: context.limits.maximumParts)
            var bodies: [String] = []
            for part in parts {
                if let body = try text(try self.entity(part, limits: context.limits), depth: depth + 1, context: &context), !body.isEmpty {
                    if type.kind != "multipart/alternative" || bodies.isEmpty { bodies.append(body) }
                    else { context.notes.insert("Only one plain-text alternative was retained.") }
                }
            }
            return bodies.isEmpty ? nil : bodies.joined(separator: "\n\n")
        }
        guard type.kind == "text/plain" else {
            context.notes.insert("HTML, nontext parts and attached/forwarded messages were omitted; remote content was not fetched.")
            return nil
        }
        if type.parameters["format"]?.lowercased() == "flowed" { context.notes.insert("Flowed plain-text lines were preserved without reflowing them.") }
        let transfer = entity.headers["content-transfer-encoding"]?.lowercased() ?? "7bit"
        let decoded: Data
        switch transfer {
        case "7bit":
            guard entity.body.allSatisfy({ $0 < 128 }) else { throw error("A declared 7-bit mail body contains non-ASCII bytes.") }
            decoded = entity.body
        case "8bit", "binary": decoded = entity.body
        case "base64": decoded = try base64(entity.body)
        case "quoted-printable": decoded = try quotedPrintable(entity.body)
        default: throw error("Mail content-transfer encoding is unsupported.")
        }
        let value = try decode(decoded, charset: type.parameters["charset"] ?? "us-ascii")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { throw error("Decoded mail text contains unsupported control characters.") }
        context.decodedBytes += value.utf8.count
        guard context.decodedBytes <= context.limits.maximumDecodedBytes else { throw error("Decoded mail text exceeds its byte budget.") }
        return value
    }

    /// Handles semicolons only outside quoted MIME parameters; never interprets filenames.
    private static func contentType(_ raw: String) throws -> ContentType {
        var pieces: [String] = [], current = "", quoted = false, escaped = false
        for character in raw {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle(); current.append(character); continue }
            if character == ";", !quoted { pieces.append(current); current = "" } else { current.append(character) }
        }
        guard !quoted, !escaped else { throw error("MIME parameter quoting is malformed.") }
        pieces.append(current)
        let kind = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
        guard !kind.isEmpty else { throw error("MIME content type is empty.") }
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equal = piece.firstIndex(of: "=") else { throw error("MIME parameter is malformed.") }
            let name = piece[..<equal].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\""), value.count >= 2 { value.removeFirst(); value.removeLast() }
            guard !name.isEmpty, parameters[name] == nil else { throw error("MIME parameters are duplicate or ambiguous.") }
            parameters[name] = value
        }
        return ContentType(kind: kind, parameters: parameters)
    }

    private static func split(_ data: Data, boundary: String, maximumParts: Int) throws -> [Data] {
        let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'()+_,-./:=? ".utf8)
        guard !boundary.isEmpty, boundary.utf8.count <= 70, boundary.last != " ", boundary.utf8.allSatisfy({ allowed.contains($0) }) else { throw error("MIME boundary is invalid or too long.") }
        let open = Array(("--" + boundary).utf8), close = open + [45, 45], bytes = [UInt8](data)
        var position = 0, start: Int?, result: [Data] = []
        while position < bytes.count {
            try Task.checkCancellation()
            let end = bytes[position...].firstIndex(of: 10) ?? bytes.count
            var lineEnd = end
            if lineEnd > position, bytes[lineEnd - 1] == 13 { lineEnd -= 1 }
            while lineEnd > position, [9, 32].contains(bytes[lineEnd - 1]) { lineEnd -= 1 }
            let line = Array(bytes[position..<lineEnd])
            let next = min(bytes.count, end + 1)
            if line == open || line == close {
                if let start {
                    var bodyEnd = position
                    if bodyEnd >= 2, bytes[bodyEnd - 2] == 13, bytes[bodyEnd - 1] == 10 { bodyEnd -= 2 }
                    else if bodyEnd >= 1, bytes[bodyEnd - 1] == 10 { bodyEnd -= 1 }
                    guard result.count < maximumParts else { throw error("MIME part count exceeds its bound.") }
                    result.append(Data(bytes[start..<max(start, bodyEnd)]))
                }
                if line == close { return result }
                start = next
            }
            position = next
        }
        throw error("Multipart mail has no closing boundary. Partial MIME bodies are not treated as complete mail.")
    }

    private static func base64(_ input: Data) throws -> Data {
        let clean = Data(input.filter { ![9, 10, 13, 32].contains($0) })
        guard clean.count % 4 == 0, let decoded = Data(base64Encoded: clean), decoded.base64EncodedData() == clean else { throw error("Mail base64 is invalid or noncanonical.") }
        return decoded
    }
    private static func quotedPrintable(_ data: Data, stripTrailingWhitespace: Bool = true) throws -> Data {
        let bytes = [UInt8](data)
        var result = Data(), index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 61 {
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
                if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
                guard index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else { throw error("Mail quoted-printable escape is malformed.") }
                result.append(high * 16 + low); index += 3
            } else {
                guard byte == 9 || byte == 10 || byte == 13 || (32...126).contains(byte) else { throw error("Quoted-printable mail contains unsupported literal bytes.") }
                if stripTrailingWhitespace && (byte == 9 || byte == 32) {
                    var next = index
                    while next < bytes.count, bytes[next] == 9 || bytes[next] == 32 { next += 1 }
                    if next == bytes.count || bytes[next] == 10 || bytes[next] == 13 { index = next; continue }
                    result.append(contentsOf: bytes[index..<next]); index = next; continue
                }
                result.append(byte); index += 1
            }
        }
        return result
    }
    private static func hex(_ value: UInt8) -> UInt8? {
        switch value { case 48...57: return value - 48; case 65...70: return value - 55; case 97...102: return value - 87; default: return nil }
    }
    private static func decode(_ data: Data, charset: String) throws -> String {
        let encoding: String.Encoding
        switch charset.lowercased() {
        case "utf-8", "utf8": encoding = .utf8
        case "us-ascii", "ascii":
            guard data.allSatisfy({ $0 < 128 }) else { throw error("ASCII mail contains bytes outside its declared charset.") }
            encoding = .ascii
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        default: throw error("Mail charset is unsupported. Export UTF-8 plain text instead.")
        }
        guard let text = String(data: data, encoding: encoding) else { throw error("Mail bytes do not decode in the declared charset.") }
        return text
    }
    private static func decodedHeader(_ raw: String) throws -> String {
        let expression = try NSRegularExpression(pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?]*)\?="#)
        let matches = expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        var result = "", cursor = raw.startIndex, previousEncoded = false
        for match in matches {
            guard let range = Range(match.range, in: raw), match.range.length <= 75,
                  let charsetRange = Range(match.range(at: 1), in: raw), let kindRange = Range(match.range(at: 2), in: raw),
                  let payloadRange = Range(match.range(at: 3), in: raw) else { throw error("Encoded mail header exceeds its bounds.") }
            let prefix = String(raw[cursor..<range.lowerBound])
            guard !prefix.contains("=?") else { throw error("Encoded mail header is malformed.") }
            if !previousEncoded || !prefix.trimmingCharacters(in: .whitespaces).isEmpty { result += prefix }
            let payload = String(raw[payloadRange])
            guard payload.utf8.allSatisfy({ (33...126).contains($0) }) else { throw error("Encoded mail header contains whitespace or invalid bytes.") }
            let bytes = raw[kindRange].lowercased() == "b" ? try base64(Data(payload.utf8)) : try quotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8), stripTrailingWhitespace: false)
            result += try decode(bytes, charset: String(raw[charsetRange]))
            cursor = range.upperBound; previousEncoded = true
        }
        let suffix = raw[cursor...]
        guard !suffix.contains("=?") else { throw error("Encoded mail header is malformed.") }
        result += suffix
        guard !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw error("Encoded mail header is malformed or contains decoded controls.") }
        return result
    }
    private static func bounded(_ value: String, bytes: Int) -> String {
        var data = Data(value.utf8.prefix(bytes))
        while !data.isEmpty { if let text = String(data: data, encoding: .utf8) { return text }; data.removeLast() }
        return ""
    }
    private static func error(_ message: String) -> RelayError { .message(message) }
}
