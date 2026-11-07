import Foundation
import CoreFoundation

/// Read-only conversion of an explicitly selected plaintext .sy AST. It has no
/// URL, workspace, asset, database, plugin or network reader. Unknown content is
/// a declared coverage gap, never an instruction to resolve another resource.
/// Format: siyuan-note/siyuan/docs/SY-FORMAT.md at d3af9d5782082b379d45a69eedf4ebcfe8ba6889.
nonisolated enum SiYuanDocumentReader {
    static let coveragePrefix = "SiYuan plaintext AST v1."

    struct Limits: Sendable {
        var maximumInputBytes = 2_097_152
        var maximumTextBytes = 65_536
        var maximumNodes = 10_000
        var maximumDepth = 48
        var maximumSeconds: TimeInterval = 1
    }

    struct Document: Sendable {
        let title: String?
        let text: String
        let coverage: String
        let truncated: Bool
        let omittedNodes: Int
        let attributeViewIDs: [String]
    }

    enum Failure: Error, Equatable, LocalizedError {
        case inputLimit, malformed, unsupportedSpecification, structureLimit, timeLimit
        var errorDescription: String? {
            switch self {
            case .inputLimit: "The SiYuan note exceeds the bounded input limit."
            case .malformed: "The selected SiYuan note is not a supported plaintext document tree. Encrypted or malformed notes were not indexed."
            case .unsupportedSpecification: "This SiYuan document specification is not supported. Its original file was left unchanged."
            case .structureLimit: "The SiYuan note exceeds the node or nesting limit."
            case .timeLimit: "The SiYuan note exceeded its local extraction time limit."
            }
        }
    }

    static func read(_ data: Data, limits requested: Limits = .init(),
                     attributeViews: [String: SiYuanAttributeViewReader.Document] = [:],
                     uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> Document {
        try Task.checkCancellation()
        var limits = requested
        limits.maximumInputBytes = max(0, min(requested.maximumInputBytes, 2_097_152))
        limits.maximumTextBytes = max(0, min(requested.maximumTextBytes, 65_536))
        limits.maximumNodes = max(0, min(requested.maximumNodes, 10_000))
        limits.maximumDepth = max(0, min(requested.maximumDepth, 48))
        limits.maximumSeconds = requested.maximumSeconds.isFinite ? max(0, min(requested.maximumSeconds, 1)) : 1
        guard !data.isEmpty, data.count <= limits.maximumInputBytes else { throw Failure.inputLimit }
        let began = uptime()
        func check() throws {
            try Task.checkCancellation()
            guard uptime() - began < limits.maximumSeconds else { throw Failure.timeLimit }
        }
        // Bound nesting before asking Foundation to allocate a recursive JSON
        // graph. Braces inside strings and escaped quotes do not affect depth.
        var depth = 0, inString = false, escaped = false
        for (index, byte) in data.enumerated() {
            if index % 1_024 == 0 { try check() }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= limits.maximumDepth * 2 + 8 else { throw Failure.structureLimit }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        try check()
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw Failure.malformed }
        guard let root = json as? [String: Any], root["Type"] as? String == "NodeDocument" else { throw Failure.malformed }
        if let spec = root["Spec"], !(spec is NSNull) {
            guard let value = spec as? String, ["0", "1", "2", "3", "4", "5", "6"].contains(value) else {
                throw Failure.unsupportedSpecification
            }
        }
        var decoder = Decoder(limits: limits, check: check)
        let tree = try decoder.node(root, depth: 0)
        var renderer = Renderer(maximumBytes: limits.maximumTextBytes, check: check, attributeViews: attributeViews)
        let body = try renderer.block(tree)
        let title = try string("title", in: root["Properties"] as? [String: Any] ?? [:])
            .map { prefix($0.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 512) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let titleWasTruncated = (root["Properties"] as? [String: Any])?["title"] as? String
        var output = Buffer(maximumBytes: limits.maximumTextBytes)
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let title { output.append("# " + title + "\n\n") }
            output.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let truncated = renderer.truncated || output.truncated
        var notes = [coveragePrefix, attributeViews.isEmpty
            ? "Rendered the selected document's stored text in block order. Related documents, assets, database rows and remote content were not read."
            : "Rendered the selected document and supplied plaintext database values in stored block order. Related documents, assets and remote content were not resolved."]
        notes.append(contentsOf: renderer.databaseCoverage.sorted())
        if renderer.omitted > 0 { notes.append("Omitted \(renderer.omitted) unsupported or external-content nodes; their content is not searchable.") }
        if renderer.richCells > 0 { notes.append("Rich table cells retain their stored Markdown source as text; layout was not rendered.") }
        if renderer.tableSpans > 0 { notes.append("Merged table cells retain stored row order; visual spans were not reconstructed.") }
        if (titleWasTruncated?.utf8.count ?? 0) > 512 { notes.append("The document title was shortened to 512 UTF-8 bytes.") }
        if truncated { notes.append("Text was bounded at \(limits.maximumTextBytes) UTF-8 bytes; omitted text is not searchable.") }
        try check()
        return Document(title: title, text: output.text, coverage: notes.joined(separator: " "),
                        truncated: truncated, omittedNodes: renderer.omitted, attributeViewIDs: decoder.attributeViewIDs.sorted())
    }

    private static func string(_ key: String, in object: [String: Any]) throws -> String? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }) else {
            throw Failure.malformed
        }
        return value
    }

    private static func integer(_ key: String, in object: [String: Any]) throws -> Int? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              abs(number.doubleValue) <= 1_000_000 else { throw Failure.malformed }
        return number.intValue
    }

    private struct Node {
        let kind: String
        let data: String
        let label: String
        let heading: Int
        let listKind: Int
        let number: Int?
        let checked: Bool
        let language: String
        let richCell: String?
        let attributeViewID: String?
        let tableSpan: Bool
        let children: [Node]
    }

    private struct Decoder {
        let limits: Limits
        let check: () throws -> Void
        var count = 0
        var attributeViewIDs: Set<String> = []

        mutating func node(_ object: [String: Any], depth: Int) throws -> Node {
            try check()
            count += 1
            guard count <= limits.maximumNodes, depth <= limits.maximumDepth else { throw Failure.structureLimit }
            guard let kind = try string("Type", in: object), !kind.isEmpty, kind.utf8.count <= 64 else { throw Failure.malformed }
            let rawChildren: [Any]
            if let raw = object["Children"] {
                guard let array = raw as? [Any] else { throw Failure.malformed }
                rawChildren = array
            } else { rawChildren = [] }
            var children: [Node] = []
            for raw in rawChildren {
                guard let child = raw as? [String: Any] else { throw Failure.malformed }
                children.append(try node(child, depth: depth + 1))
            }
            let properties = object["Properties"] as? [String: Any] ?? [:]
            let list = object["ListData"] as? [String: Any] ?? [:]
            let marker = try integer("TaskListItemMarker", in: object)
            let checked: Bool
            if let marker {
                guard (32...126).contains(marker) else { throw Failure.malformed }
                checked = marker != 32
            } else if let raw = object["TaskListItemChecked"] ?? list["Checked"] {
                guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure.malformed }
                checked = value.boolValue
            } else { checked = false }
            var richCell: String?
            if let raw = object["TableCellRich"] {
                guard let rich = raw as? [String: Any], try integer("spec", in: rich) == 1,
                      try string("format", in: rich) == "kramdown", let content = try string("content", in: rich) else { throw Failure.malformed }
                richCell = content
            }
            let encodedLanguage = try string("CodeBlockInfo", in: object) ?? ""
            let language = Data(base64Encoded: encodedLanguage).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            var attributeViewID: String?
            if kind == "NodeAttributeView" {
                var reference = try string("AttributeViewID", in: object)
                if reference == nil, let markup = try string("Data", in: object),
                   let range = markup.range(of: #"data-av-id="[0-9]{14}-[0-9a-z]{7}""#, options: .regularExpression) {
                    reference = String(markup[range].dropFirst(12).dropLast())
                }
                if let reference, SiYuanJSON.validID(reference) {
                    attributeViewID = reference
                    attributeViewIDs.insert(reference)
                }
            }
            var label = try string("TextMarkTextContent", in: object) ?? string("TextMarkInlineMathContent", in: object)
                ?? string("TabItemTitle", in: object) ?? string("CalloutTitle", in: object) ?? ""
            if kind == "NodeTextMark" {
                let marks = (try string("TextMarkType", in: object) ?? "").split(separator: " ")
                if marks.contains("inline-math") { label = try string("TextMarkInlineMathContent", in: object) ?? label }
                if marks.contains("tag"), !label.isEmpty { label = "#" + label + "#" }
                if marks.contains("inline-memo"), let memo = try string("TextMarkInlineMemoContent", in: object), !memo.isEmpty {
                    label += " (note: " + memo + ")"
                }
            }
            return Node(kind: kind, data: try string("Data", in: object) ?? "",
                label: label,
                heading: try integer("HeadingLevel", in: object) ?? 2,
                listKind: try integer("Typ", in: list) ?? 0,
                number: try integer("Num", in: list) ?? integer("Start", in: list), checked: checked,
                language: language.utf8.count <= 64 && language.allSatisfy({ $0.isLetter || $0.isNumber || "_+-#".contains($0) }) ? language : "",
                richCell: richCell, attributeViewID: attributeViewID,
                tableSpan: ["colspan", "rowspan"].contains { (properties[$0] as? String).flatMap(Int.init).map { $0 > 1 } == true },
                children: children)
        }
    }

    private struct Buffer {
        let maximumBytes: Int
        var text = ""
        var bytes = 0
        var truncated = false
        var full: Bool { bytes >= maximumBytes }
        mutating func append(_ value: String) {
            let remaining = max(0, maximumBytes - bytes)
            guard value.utf8.count > remaining else { text += value; bytes += value.utf8.count; return }
            let excerpt = SiYuanDocumentReader.prefix(value, bytes: remaining)
            text += excerpt; bytes += excerpt.utf8.count; truncated = true
        }
    }

    private struct Renderer {
        let maximumBytes: Int
        let check: () throws -> Void
        let attributeViews: [String: SiYuanAttributeViewReader.Document]
        var databaseCoverage: Set<String> = []
        var truncated = false
        var omitted = 0
        var richCells = 0
        var tableSpans = 0

        mutating func join(_ children: [Node], separator: String) throws -> String {
            var result = Buffer(maximumBytes: maximumBytes)
            for child in children {
                try check()
                if result.full { truncated = true; break }
                let piece = try block(child)
                if !piece.isEmpty {
                    if !result.text.isEmpty { result.append(separator) }
                    result.append(piece)
                }
            }
            truncated = truncated || result.truncated
            return result.text
        }

        mutating func block(_ node: Node) throws -> String {
            try check()
            switch node.kind {
            case "NodeDocument", "NodeSuperBlock", "NodeTabs": return try join(node.children, separator: "\n\n")
            case "NodeParagraph": return try join(node.children, separator: "")
            case "NodeHeading": return String(repeating: "#", count: min(6, max(1, node.heading))) + " " + (try join(node.children, separator: ""))
            case "NodeText", "NodeLinkText", "NodeBlockRefText", "NodeBlockRefDynamicText", "NodeCodeSpanContent", "NodeBackslashContent", "NodeInlineMathContent", "NodeMathBlockContent", "NodeCodeBlockCode": return bounded(node.data)
            case "NodeTextMark": return bounded(node.label)
            case "NodeSoftBreak", "NodeBr", "NodeHardBreak": return "\n"
            case "NodeLink", "NodeBlockRef", "NodeStrong", "NodeEmphasis", "NodeStrikethrough", "NodeMark", "NodeCodeSpan", "NodeInlineMath", "NodeBackslash": return try join(node.children, separator: "")
            case "NodeThematicBreak": return "---"
            case "NodeBlockquote": return try quoted(join(node.children, separator: "\n\n"))
            case "NodeCallout":
                let title = node.label.isEmpty ? "Note" : bounded(node.label)
                return try quoted(title + "\n" + join(node.children, separator: "\n\n"))
            case "NodeTabItem":
                let body = try join(node.children, separator: "\n\n")
                return node.label.isEmpty ? body : bounded(node.label) + "\n\n" + body
            case "NodeList", "NodeMindmap":
                var result = Buffer(maximumBytes: maximumBytes)
                for (index, child) in node.children.enumerated() {
                    guard !result.full else { truncated = true; break }
                    if child.kind != "NodeListItem" && child.kind != "NodeMindmapItem" { omitted += 1; continue }
                    let prefix: String
                    let listKind = child.listKind == 0 ? node.listKind : child.listKind
                    if listKind == 3 {
                        let marker = child.children.first { $0.kind == "NodeTaskListItemMarker" }
                        prefix = (marker?.checked ?? child.checked) ? "- [x] " : "- [ ] "
                    } else if listKind == 1 {
                        let start = node.number.flatMap { $0 > 0 ? $0 : nil } ?? 1
                        let number = child.number.flatMap { $0 > 0 ? $0 : nil } ?? (start + index)
                        prefix = "\(number). "
                    }
                    else { prefix = "- " }
                    let content = try join(child.children, separator: "\n")
                    if !result.text.isEmpty { result.append("\n") }
                    result.append(prefix + content.replacingOccurrences(of: "\n", with: "\n  "))
                }
                truncated = truncated || result.truncated
                return result.text
            case "NodeListItem", "NodeMindmapItem": return try join(node.children, separator: "\n")
            case "NodeCodeBlock":
                let code = try join(node.children.filter { $0.kind == "NodeCodeBlockCode" }, separator: "")
                var run = 0, longest = 0
                for character in code { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
                if longest >= 8 { return "    " + code.replacingOccurrences(of: "\n", with: "\n    ") }
                let fence = String(repeating: "`", count: max(3, longest + 1))
                let language = node.language.isEmpty ? node.children.first(where: { $0.kind == "NodeCodeBlockFenceInfoMarker" })?.language ?? "" : node.language
                return fence + language + "\n" + code + (code.hasSuffix("\n") ? "" : "\n") + fence
            case "NodeMathBlock": return try join(node.children.filter { $0.kind == "NodeMathBlockContent" }, separator: "")
            case "NodeTable", "NodeTableHead": return try join(node.children, separator: "\n")
            case "NodeTableRow": return "| " + (try join(node.children, separator: " | ")) + " |"
            case "NodeTableCell":
                if node.tableSpan { tableSpans += 1 }
                let content: String
                if let rich = node.richCell { richCells += 1; content = bounded(rich) }
                else { content = try join(node.children, separator: "") }
                return content.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " / ")
            case "NodeImage": omitted += 1; return try join(node.children.filter { $0.kind == "NodeLinkText" }, separator: "")
            case "NodeAttributeView":
                if let id = node.attributeViewID, let view = attributeViews[id] {
                    databaseCoverage.insert(view.coverage)
                    return bounded(view.text)
                }
                omitted += 1; return ""
            case "NodeBlockQueryEmbed", "NodeHTMLBlock", "NodeIFrame", "NodeVideo", "NodeAudio", "NodeWidget", "NodeCustomBlock": omitted += 1; return ""
            default:
                if !Self.markers.contains(node.kind) { omitted += 1 }
                return ""
            }
        }

        mutating func bounded(_ text: String) -> String {
            if text.utf8.count > maximumBytes { truncated = true }
            return SiYuanDocumentReader.prefix(text, bytes: maximumBytes)
        }

        private func quoted(_ text: String) -> String {
            text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        }

        private static let markers: Set<String> = ["NodeKramdownBlockIAL", "NodeKramdownSpanIAL", "NodeHeadingC8hMarker", "NodeBlockquoteMarker", "NodeTaskListItemMarker", "NodeBang", "NodeOpenBracket", "NodeCloseBracket", "NodeOpenParen", "NodeCloseParen", "NodeLinkDest", "NodeLinkSpace", "NodeLinkTitle", "NodeCodeBlockFenceOpenMarker", "NodeCodeBlockFenceInfoMarker", "NodeCodeBlockFenceCloseMarker", "NodeMathBlockOpenMarker", "NodeMathBlockCloseMarker", "NodeSuperBlockOpenMarker", "NodeSuperBlockLayoutMarker", "NodeSuperBlockCloseMarker", "NodeOpenBrace", "NodeCloseBrace"]
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var data = Data(text.utf8.prefix(max(0, bytes)))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
}
