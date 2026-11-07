import CoreGraphics
import Foundation

/// Original read-only grouping over an inert AX tree. App profiles require their
/// declared transcript structure; an unfamiliar chat UI never becomes a generic
/// whole-window capture. No source database, clipboard, network or app is read.
nonisolated enum SummaryConversationSnapshot {
    enum Profile: String, Sendable, CaseIterable {
        case whatsApp, messages, claude, chatGPT, codex, slack
        var bundleID: String {
            switch self {
            case .whatsApp: "net.whatsapp.WhatsApp"
            case .messages: "com.apple.MobileSMS"
            case .claude: "com.anthropic.claudefordesktop"
            case .chatGPT: "com.openai.chat"
            case .codex: "com.openai.codex"
            case .slack: "com.tinyspeck.slackmacgap"
            }
        }
    }
    struct Node: Sendable {
        let parent: Int
        let role: String
        var identifier = ""
        var classes: [String] = []
        var description = ""
        var value = ""
        var title = ""
        var subrole = ""
        var document = ""
        var frame: CGRect? = nil
        var protected = false
        var editable = false
        var hidden = false
        var domID = ""
    }
    struct Limits: Sendable {
        var maximumNodes = 8_000
        var maximumInputBytes = 400_000
        var maximumTextBytes = 8_000
        var maximumDepth = 80
        var maximumSeconds: TimeInterval = 2
    }
    struct Item: Sendable, Equatable {
        let ordinal: Int
        let text: String
        let anchor: String
        let sender: String?
        let timestamp: String?
        let identity: String?
        let visible: Bool
        let message: Bool
    }
    struct Selection: Sendable {
        let profile: Profile
        let title: String
        let items: [Item]
        let text: String
        let coverage: String
        let truncated: Bool
        let offscreenMessages: Int
        let transcriptRoot: Int
    }
    enum Failure: Error, Equatable, LocalizedError {
        case invalidTree, limit, missingTranscript, ambiguousTranscript, noVisibleMessage, oversizedMessage
        var errorDescription: String? {
            switch self {
            case .invalidTree: "The chat did not expose a consistent readable conversation tree."
            case .limit: "The conversation tree exceeds this bounded capture's limits."
            case .missingTranscript: "This app did not expose its supported conversation container. No whole-window fallback was used."
            case .ambiguousTranscript: "More than one conversation container is available. Choose the intended thread before summarizing."
            case .noVisibleMessage: "No visible message identifies the conversation boundary. Open the intended chat first."
            case .oversizedMessage: "A complete boundary message exceeds the summary text budget. Select the intended text explicitly instead."
            }
        }
    }

    static func profile(bundleID: String) -> Profile? { Profile.allCases.first { $0.bundleID == bundleID } }

    static func select(_ nodes: [Node], profile: Profile, limits requested: Limits = .init()) throws -> Selection {
        try Task.checkCancellation()
        let maxNodes = max(0, min(requested.maximumNodes, 8_000))
        let maxBytes = max(0, min(requested.maximumInputBytes, 400_000))
        let maxDepth = max(0, min(requested.maximumDepth, 80))
        let outputLimit = max(0, min(requested.maximumTextBytes, 26_000))
        let began = ProcessInfo.processInfo.systemUptime
        let seconds = requested.maximumSeconds.isFinite ? max(0, min(requested.maximumSeconds, 3)) : 2
        func check() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - began < seconds else { throw Failure.limit }
        }
        guard !nodes.isEmpty, nodes.count <= maxNodes else { throw Failure.limit }
        var bytes = 0, depths: [Int] = []
        var children: [Int: [Int]] = [:]
        for (index, node) in nodes.enumerated() {
            try check()
            guard node.parent >= -1, node.parent < index, node.role.utf8.count <= 128,
                  node.classes.count <= 128 else { throw Failure.invalidTree }
            let depth = node.parent >= 0 ? depths[node.parent] + 1 : 0
            guard depth <= maxDepth else { throw Failure.limit }
            depths.append(depth); children[node.parent, default: []].append(index)
            for text in [node.role, node.identifier, node.description, node.value, node.title, node.subrole, node.document, node.domID] + node.classes {
                guard text.utf8.count <= maxBytes - bytes, !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Failure.limit }
                bytes += text.utf8.count
            }
        }
        func ancestry(_ index: Int) -> [Int] {
            var result: [Int] = [], cursor = index
            while cursor >= 0 { result.append(cursor); cursor = nodes[cursor].parent }
            return result
        }
        func descends(_ index: Int, from root: Int) -> Bool { ancestry(index).contains(root) }
        func eligible(_ index: Int) -> Bool {
            !ancestry(index).contains { node in
                nodes[node].protected || nodes[node].hidden || nodes[node].subrole == "AXSecureTextField"
                    || ["AXToolbar", "AXMenu", "AXMenuBar"].contains(nodes[node].role)
            }
        }
        let roots = nodes.indices.filter { index in
            guard eligible(index) else { return false }
            switch profile {
            case .whatsApp: return nodes[index].identifier == "ChatMessagesTableView"
            case .messages: return nodes[index].identifier == "TranscriptCollectionView"
            case .claude: return nodes[index].classes.contains("epitaxy-chat-panel-body")
            case .chatGPT, .codex: return nodes[index].classes.contains("thread-scroll-container") && nodes[index].description == "Conversation"
            case .slack: return nodes[index].classes.contains("p-message_pane")
            }
        }
        guard !roots.isEmpty else { throw Failure.missingTranscript }
        guard roots.count == 1, let root = roots.first else { throw Failure.ambiguousTranscript }
        try check()
        guard var viewport = nodes[root].frame, valid(viewport) else { throw Failure.noVisibleMessage }
        let native = profile == .whatsApp || profile == .messages
        var title = profile.rawValue + " conversation"
        if native {
            let headerID = profile == .whatsApp ? "NavigationBar_HeaderViewButton" : "ConversationTitle"
            let headers = nodes.indices.filter { eligible($0) && nodes[$0].identifier == headerID }
            guard headers.count == 1, let header = headers.first else { throw Failure.ambiguousTranscript }
            title = clean(nodes[header].description.isEmpty ? nodes[header].title : nodes[header].description)
            guard !title.isEmpty else { throw Failure.missingTranscript }
            if let frame = nodes[header].frame, valid(frame) {
                let y = max(viewport.minY, frame.maxY + 8)
                viewport = CGRect(x: viewport.minX, y: y, width: viewport.width, height: max(0, viewport.maxY - y))
            }
            let composerID = profile == .whatsApp ? "ChatBar_ComposerTextView" : "MessageEntryView"
            let composers = nodes.filter { $0.identifier == composerID }
            if composers.count > 1 { throw Failure.ambiguousTranscript }
            if let frame = composers.first?.frame, valid(frame) {
                viewport.size.height = max(0, min(viewport.maxY, frame.minY - 4) - viewport.minY)
            }
        } else if profile == .slack,
                  let label = nodes.indices.first(where: { descends($0, from: root) && nodes[$0].role == "AXList" && !nodes[$0].description.isEmpty }) {
            title = clean(nodes[label].description)
        }
        func visible(_ frame: CGRect?) -> Bool {
            guard let frame, valid(frame) else { return false }
            let intersection = frame.intersection(viewport)
            return !intersection.isNull && intersection.width > 1 && intersection.height > 1
        }
        var items: [Item] = []
        func append(_ index: Int, text: String, anchor: String, message: Bool = true,
                    sender: String? = nil, timestamp: String? = nil, identity: String? = nil, isVisible: Bool? = nil) {
            guard !clean(text).isEmpty else { return }
            items.append(Item(ordinal: index, text: clean(text), anchor: clean(anchor), sender: sender,
                timestamp: timestamp, identity: identity, visible: isVisible ?? visible(nodes[index].frame), message: message))
        }
        if profile == .whatsApp {
            for index in nodes.indices where descends(index, from: root) && eligible(index) {
                try check()
                if nodes[index].identifier == "WAMessageBubbleTableViewCell" {
                    append(index, text: nodes[index].description, anchor: nodes[index].description)
                } else if nodes[index].role == "AXHeading" {
                    // This is interface chrome, not a message or a boundary.
                    // Message bubbles containing these words remain intact;
                    // date separators retain their useful conversation context.
                    let heading = clean(nodes[index].description)
                    if heading.range(of: #"^(?:[0-9]+\s+)?unread\s+messages?$"#,
                                     options: [.regularExpression, .caseInsensitive]) != nil { continue }
                    append(index, text: nodes[index].description, anchor: "", message: false)
                }
            }
        } else if profile == .messages {
            for index in children[root] ?? [] where eligible(index) {
                try check()
                if !nodes[index].description.isEmpty {
                    let body = nodes.indices.first { descends($0, from: index) && eligible($0) && nodes[$0].identifier == "CKBalloonTextView" }
                    append(index, text: nodes[index].description, anchor: body.map { nodes[$0].value } ?? "")
                } else if let label = nodes.indices.first(where: { descends($0, from: index) && eligible($0) && nodes[$0].role == "AXStaticText" && !nodes[$0].description.isEmpty }) {
                    append(label, text: nodes[label].description, anchor: "", message: false)
                }
            }
        } else {
            var order: [Int] = [], groups: [Int: [Int]] = [:], labels: [Int: String] = [:]
            var aiOwner: Int?
            let ai = profile == .chatGPT || profile == .codex
            let bannedClasses: Set<String> = ["c-message_kit__reaction_bar", "c-timestamp", "group/agent-activity",
                "group/activity-header", "group/status", "group/turn-diff-header", "ProseMirror"]
            for index in nodes.indices where descends(index, from: root) && eligible(index) {
                try check()
                let node = nodes[index]
                if ai, node.role == "AXHeading", node.classes.contains("sr-only"),
                   ["You said:", "ChatGPT said:", "Codex said:", "Assistant:"].contains(node.title) {
                    aiOwner = index; labels[index] = node.title.hasPrefix("You") ? "You:" : "Assistant:"
                }
                guard ["AXStaticText", "AXTextArea", "AXLink"].contains(node.role), !node.editable else { continue }
                if node.role == "AXLink", (children[index] ?? []).contains(where: { nodes[$0].role == "AXStaticText" }) { continue }
                let text = node.value.isEmpty ? node.title : node.value
                guard !clean(text).isEmpty else { continue }
                let ancestors = ancestry(index).prefix { $0 != root }
                let excluded = ancestors.contains { parent in
                    let candidate = nodes[parent]
                    return candidate.editable || ["AXButton", "AXPopUpButton"].contains(candidate.role)
                        || !Set(candidate.classes).isDisjoint(with: bannedClasses)
                        || (candidate.classes.contains("sr-only") && !(profile == .slack && candidate.role == "AXList"))
                }
                guard !excluded else { continue }
                let owner: Int?
                if ai { owner = aiOwner }
                else if profile == .claude { owner = ancestors.first { nodes[$0].subrole == "AXDocumentArticle" } }
                else { owner = ancestors.first { nodes[$0].classes.contains("c-message_kit__hover") } }
                guard let owner else { continue }
                if groups[owner] == nil { order.append(owner) }
                groups[owner, default: []].append(index)
            }
            for owner in order {
                try check()
                let content = groups[owner] ?? []
                let body = content.map { clean(nodes[$0].value.isEmpty ? nodes[$0].title : nodes[$0].value) }.joined(separator: "\n")
                var sender: String?, timestamp: String?, identity: String?
                if profile == .claude {
                    let heading = nodes.indices.first { descends($0, from: owner) && nodes[$0].role == "AXHeading" && nodes[$0].classes.contains("sr-only") }
                    if let heading {
                        let title = clean(nodes[heading].title)
                        if title.hasPrefix("You said:") || title == "You:" || title == "User:" { sender = "You" }
                        else if title.hasPrefix("Claude said:") || title == "Claude:" { sender = "Claude" }
                    }
                } else if profile == .slack {
                    sender = nodes.indices.first { descends($0, from: owner) && nodes[$0].classes.contains("c-message__sender_button") }.map { nodes[$0].title }
                    timestamp = nodes.indices.first { descends($0, from: owner) && nodes[$0].classes.contains("c-timestamp") }.map { nodes[$0].title }
                    identity = nodes[owner].parent >= 0 ? nodes[nodes[owner].parent].domID : nil
                }
                let label = labels[owner] ?? [sender, timestamp].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                let hasGeometry = content.contains { nodes[$0].frame != nil }
                append(owner, text: label.isEmpty ? body : label + "\n" + body, anchor: body,
                    sender: sender, timestamp: timestamp, identity: identity,
                    isVisible: hasGeometry ? content.contains { visible(nodes[$0].frame) } : visible(nodes[owner].frame))
            }
        }
        guard let beginning = items.firstIndex(where: { $0.message && $0.visible }) else { throw Failure.noVisibleMessage }
        let loaded = Array(items[beginning...])
        let packed = try pack(loaded, maximumBytes: outputLimit)
        try check()
        let offscreen = loaded.count { $0.message && !$0.visible }
        let coverage = "Current \(profile.rawValue) conversation only, beginning with the complete first visible message and later loaded messages. Sidebar, composer, controls and earlier messages excluded."
            + (profile == .slack ? " Slack virtualizes unloaded history; this is a loaded-message excerpt." : " Unloaded or local-database history was not read.")
            + (packed.omitted > 0 ? " \(packed.omitted) intervening loaded items were omitted to retain complete boundary and newest messages; no message body was cut." : "")
            + (profile == .claude && packed.items.contains(where: { $0.message && $0.sender == nil })
                ? " Some captured articles had no recognized speaker heading; their speakers are unknown." : "")
        return Selection(profile: profile, title: DocumentSummarySource.prefix(title, bytes: 512), items: packed.items,
            text: packed.text, coverage: coverage, truncated: packed.omitted > 0 || profile == .slack,
            offscreenMessages: offscreen, transcriptRoot: root)
    }

    private static func pack(_ items: [Item], maximumBytes: Int) throws -> (items: [Item], text: String, omitted: Int) {
        let full = items.map(\.text).joined(separator: "\n")
        if full.utf8.count <= maximumBytes { return (items, full, 0) }
        let messages = items.indices.filter { items[$0].message }
        guard let first = messages.first, let last = messages.last else { throw Failure.noVisibleMessage }
        let gap = "\n[Intervening loaded messages omitted]\n"
        var indices = Set([first, last])
        var bytes = items[first].text.utf8.count + (first == last ? 0 : items[last].text.utf8.count + gap.utf8.count)
        guard bytes <= maximumBytes else { throw Failure.oversizedMessage }
        if last > first + 1 {
            for index in stride(from: last - 1, through: first + 1, by: -1) {
                let size = items[index].text.utf8.count + 1
                if size <= maximumBytes - bytes { indices.insert(index); bytes += size }
                else { break }
            }
        }
        let retained = indices.sorted().map { items[$0] }
        var parts: [String] = []
        var previous: Int?
        for index in indices.sorted() {
            if let previous { parts.append(index == previous + 1 ? "\n" : gap) }
            parts.append(items[index].text); previous = index
        }
        let text = parts.joined()
        guard text.utf8.count <= maximumBytes else { throw Failure.limit }
        return (retained, text, items.count - retained.count)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 1 && frame.height > 1
    }
    static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { ![0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
