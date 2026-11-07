import Foundation
import CoreFoundation

/// Pure, bounded plaintext AttributeView decoding. Values are source data; asset
/// labels and URLs are never opened, and formulas/templates are never evaluated.
nonisolated enum SiYuanAttributeViewReader {
    struct Document: Sendable {
        let text: String
        let coverage: String
    }
    enum Failure: Error { case malformed, limit }

    static func read(_ data: Data, maximumRows: Int = 50, maximumTextBytes: Int = 65_536, expectedID: String? = nil) throws -> Document {
        let object = try SiYuanJSON.object(data, maximumBytes: 2_097_152)
        if let storedID = object["id"] {
            guard let value = try SiYuanJSON.string(storedID), SiYuanJSON.validID(value), expectedID == nil || expectedID == value else { throw Failure.malformed }
        }
        guard let columns = object["keyValues"] as? [[String: Any]], !columns.isEmpty, columns.count <= 64 else { throw Failure.malformed }
        let rowsLimit = max(0, min(50, maximumRows))
        var decoded: [(name: String, kind: String, values: [String: [String: Any]])] = []
        var order: [String] = []
        var omitted = 0
        for (columnIndex, column) in columns.enumerated() {
            try Task.checkCancellation()
            guard let key = column["key"] as? [String: Any], let values = column["values"] as? [[String: Any]], values.count <= 10_000 else { throw Failure.malformed }
            var mapped: [String: [String: Any]] = [:]
            for value in values {
                guard let id = value["blockID"] as? String, SiYuanJSON.validID(id), mapped[id] == nil else { throw Failure.malformed }
                mapped[id] = value
                if columnIndex == 0 { order.append(id) }
            }
            decoded.append((try SiYuanJSON.string(key["name"]) ?? "Column", try SiYuanJSON.string(key["type"]) ?? "", mapped))
        }
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " / ").replacingOccurrences(of: "\r", with: " ")
        }
        var lines = ["Database: " + (try SiYuanJSON.string(object["name"]) ?? "Untitled"),
                     "| " + decoded.map { escaped($0.name) }.joined(separator: " | ") + " |"]
        for id in order.prefix(rowsLimit) {
            try Task.checkCancellation()
            let cells = try decoded.map { column -> String in
                guard let value = column.values[id] else { return "" }
                let kind = try SiYuanJSON.string(value["type"]) ?? column.kind
                let payload = value[kind]
                switch kind {
                case "text", "block", "url", "email", "phone", "template":
                    // Stored template output only, never source execution.
                    return escaped(try SiYuanJSON.string((payload as? [String: Any])?["content"]) ?? "")
                case "number":
                    guard let number = payload as? [String: Any] else { throw Failure.malformed }
                    if try SiYuanJSON.boolean(number["isNotEmpty"]) != true { return "" }
                    if let formatted = try SiYuanJSON.string(number["formattedContent"]), !formatted.isEmpty { return escaped(formatted) }
                    guard let content = try SiYuanJSON.number(number["content"]) else { return "" }
                    return String(content)
                case "checkbox":
                    return try SiYuanJSON.boolean((payload as? [String: Any])?["checked"]) == true ? "[x]" : "[ ]"
                case "select", "mSelect", "mAsset":
                    guard let values = payload as? [[String: Any]], values.count <= 256 else { throw Failure.malformed }
                    return try values.compactMap { try SiYuanJSON.string($0["name"]) ?? SiYuanJSON.string($0["content"]) }.map(escaped).joined(separator: ", ")
                case "date", "created", "updated":
                    guard let date = payload as? [String: Any] else { throw Failure.malformed }
                    if kind == "date", try SiYuanJSON.boolean(date["isNotEmpty"]) != true { return "" }
                    guard let milliseconds = try SiYuanJSON.number(date["content"]), milliseconds > 0, milliseconds < 253_402_300_800_000 else { return "" }
                    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: milliseconds / 1000))
                default: omitted += 1; return ""
                }
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        let raw = lines.joined(separator: "\n")
        let text = SiYuanJSON.prefix(raw, bytes: max(0, min(maximumTextBytes, 65_536)))
        var coverage = "Plaintext AttributeView stored values only; formulas, relations, assets and remote content were not resolved. Dates are shown as UTC instants."
        if order.count > rowsLimit { coverage += " First \(rowsLimit) of \(order.count) rows retained." }
        if omitted > 0 { coverage += " \(omitted) unsupported cell values omitted." }
        if text != raw { coverage += " Database text was truncated at the declared UTF-8 limit." }
        return Document(text: text, coverage: coverage)
    }
}

/// Shared format primitives; no filesystem or resource resolver.
nonisolated enum SiYuanJSON {
    static func object(_ data: Data, maximumBytes: Int) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumBytes else { throw SiYuanAttributeViewReader.Failure.limit }
        var depth = 0, quoted = false, escaped = false
        for (index, byte) in data.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; guard depth <= 64 else { throw SiYuanAttributeViewReader.Failure.limit } }
            else if byte == 125 || byte == 93 { depth -= 1 }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SiYuanAttributeViewReader.Failure.malformed }
        return object
    }
    static func validID(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{14}-[0-9a-z]{7}$"#, options: .regularExpression) != nil
    }
    static func string(_ raw: Any?) throws -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let text = raw as? String, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9,10,13].contains($0.value) }) else { throw SiYuanAttributeViewReader.Failure.malformed }
        return text
    }
    static func boolean(_ raw: Any?) throws -> Bool? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw SiYuanAttributeViewReader.Failure.malformed }
        return number.boolValue
    }
    static func number(_ raw: Any?) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw SiYuanAttributeViewReader.Failure.malformed }
        return number.doubleValue
    }
    static func prefix(_ text: String, bytes: Int) -> String {
        var data = Data(text.utf8.prefix(max(0, bytes)))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
}
