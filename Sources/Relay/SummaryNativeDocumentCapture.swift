import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// Invocation-bound reading only: no activation, scrolling, editing, clipboard,
/// screenshot, file/database access, hosted request, persistence or text logging.
@MainActor enum SummaryNativeDocumentCapture {
    nonisolated enum Mode: Sendable, Equatable {
        case document
        case conversation(SummaryConversationSnapshot.Profile)
    }
    nonisolated struct Window: Sendable {
        let token: String
        let title: String
        let document: String
        let frame: CGRect
        func matches(_ other: Self) -> Bool {
            token == other.token && title.utf16.elementsEqual(other.title.utf16)
                && document.utf16.elementsEqual(other.document.utf16) && frame == other.frame
        }
    }
    nonisolated struct Binding: Sendable {
        let application: DesktopApplicationIdentity
        let applicationName: String
        let window: Window
        func matches(_ other: Self) -> Bool {
            application == other.application && applicationName.utf16.elementsEqual(other.applicationName.utf16)
                && window.matches(other.window)
        }
    }
    nonisolated struct Tree: Sendable {
        let nodes: [SummaryConversationSnapshot.Node]
        var limited = false
    }
    struct Provider {
        let inspect: @MainActor () throws -> Binding
        let read: @Sendable () async throws -> Tree
    }
    struct Request {
        let mode: Mode
        fileprivate let binding: Binding
        fileprivate let provider: Provider
        fileprivate let isActive: @MainActor () -> Bool
        fileprivate let limits: Limits
        fileprivate let preparedCaptureTime: Date?
    }
    nonisolated struct Limits: Sendable {
        var maximumNodes = 8_000
        var maximumInputBytes = 400_000
        var maximumTextBytes = 8_000
        var maximumDepth = 80
        var maximumSeconds: TimeInterval = 5
    }
    /// Ephemeral data, deliberately not Codable. A PDF URL is metadata only;
    /// no file was opened or authorized by this capture.
    nonisolated struct Snapshot: Sendable {
        let mode: Mode
        let origin: Binding
        let text: String
        let title: String
        let application: String
        let documentURL: URL?
        let coverage: String
        let truncated: Bool
        let capturedAt: Date
        let offscreenMessages: Int
        let messages: [SummaryConversationSnapshot.Item]
        var requiresPDFRead: Bool { text.isEmpty && documentURL?.pathExtension.lowercased() == "pdf" }
    }
    nonisolated enum Failure: Error, Equatable, LocalizedError {
        case permission, unsupportedProfile, inactive, changedOrigin, unavailable, limit
        var errorDescription: String? {
            switch self {
            case .permission: "Allow Accessibility to read the chosen document."
            case .unsupportedProfile: "This app has no qualified native document or conversation profile. Select text or choose a PDF explicitly."
            case .inactive: "The summary capture stopped or its interactive session ended."
            case .changedOrigin: "The original process, window or document changed during capture. No replacement source was read."
            case .unavailable: "The chosen window did not expose one readable document. No whole-app or other-window fallback was used."
            case .limit: "This source exceeds the bounded native capture limits. Select a smaller source."
            }
        }
    }

    static func prepare(application: NSRunningApplication, isActive: @escaping @MainActor () -> Bool,
                        limits: Limits = .init()) throws -> Request {
        let preparationBegan = ProcessInfo.processInfo.systemUptime
        guard isActive() else { throw Failure.inactive }
        // An unregistered test/agent host can expose an incomplete PID through
        // AppKit. The current-application identity still must never enter AX.
        guard !application.isEqual(NSRunningApplication.current),
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw Failure.unsupportedProfile }
        guard AXIsProcessTrusted() else { throw Failure.permission }
        guard let identity = DesktopApplicationTarget.identity(of: application) else { throw Failure.changedOrigin }
        let mode: Mode
        if let profile = SummaryConversationSnapshot.profile(bundleID: identity.bundleID) { mode = .conversation(profile) }
        else if ["com.apple.TextEdit", "com.apple.Preview"].contains(identity.bundleID) { mode = .document }
        else { throw Failure.unsupportedProfile }
        let app = AXUIElementCreateApplication(identity.processID)
        AXUIElementSetMessagingTimeout(app, 0.005)
        guard let window = element(app, "AXFocusedWindow") else { throw Failure.unavailable }
        AXUIElementSetMessagingTimeout(window, 0.005)
        guard string(window, "AXRole") == "AXWindow", let frame = rect(window), valid(frame) else { throw Failure.unavailable }
        let token = UUID().uuidString
        func inspect() throws -> Binding {
            guard isActive(), DesktopApplicationTarget.matches(identity, application: application) else { throw Failure.changedOrigin }
            let root = AXUIElementCreateApplication(identity.processID)
            AXUIElementSetMessagingTimeout(root, 0.005)
            guard let windows = attribute(root, "AXWindows") as? [AXUIElement], windows.count <= 256,
                  windows.contains(where: { CFEqual($0, window) }), let frame = rect(window), valid(frame) else { throw Failure.changedOrigin }
            return Binding(application: identity, applicationName: application.localizedName ?? identity.bundleID,
                window: Window(token: token, title: string(window, "AXTitle"), document: string(window, "AXDocument"), frame: frame))
        }
        let original = try inspect()
        var sourceInspector: @MainActor () throws -> Binding = inspect
        let read: @Sendable () async throws -> Tree
        let capturedAt: Date?
        if case .conversation(let profile) = mode {
            // MainActor does not freeze the external app. A generic window
            // title is insufficient: retain and compare the exact transcript
            // root and a validated app-provided conversation identity.
            var fast = bounded(limits); fast.maximumSeconds = max(0, min(fast.maximumSeconds, 0.25 - (ProcessInfo.processInfo.systemUptime - preparationBegan)))
            let frozen = try SummaryConversationCaptureBoundary.freeze(profile: profile, isActive: isActive,
                maximumSeconds: fast.maximumSeconds, inspect: {
                    guard original.matches(try inspect()) else { throw Failure.changedOrigin }
                    return try SummaryConversationAXIdentity.inspect(window: window, profile: profile)
                }, read: {
                    try scanSynchronously(AXTarget(window: window, limits: fast, profile: profile, timeout: 0.005))
                })
            let tree = frozen.tree
            let validateConversation = frozen.validate
            sourceInspector = {
                try validateConversation()
                return try inspect()
            }
            guard original.matches(try sourceInspector()) else { throw Failure.changedOrigin }
            read = { tree }; capturedAt = Date()
        } else {
            let target = AXTarget(window: window, limits: bounded(limits), profile: nil, timeout: 0.03)
            read = { try await scan(target) }; capturedAt = nil
        }
        let request = try prepare(mode: mode, binding: original, provider: Provider(inspect: sourceInspector, read: read),
                                  isActive: isActive, limits: limits, preparedCaptureTime: capturedAt)
        if capturedAt != nil, ProcessInfo.processInfo.systemUptime - preparationBegan > 0.25 { throw Failure.limit }
        return request
    }

    /// A trusted invocation capture can be queued without rereading a reused
    /// window. Tests use this same immutable handoff as production chat capture.
    static func prepareFrozen(mode: Mode, binding: Binding, tree: Tree,
                              inspect: @escaping @MainActor () throws -> Binding,
                              isActive: @escaping @MainActor () -> Bool, limits: Limits = .init(),
                              capturedAt: Date = Date()) throws -> Request {
        if case .conversation = mode, tree.limited { throw Failure.limit }
        return try prepare(mode: mode, binding: binding, provider: Provider(inspect: inspect, read: { tree }),
                           isActive: isActive, limits: limits, preparedCaptureTime: capturedAt)
    }

    /// Inert metadata/tree seam. Explicit app profiles are checked before any
    /// provider inspection/read. Production does not guess a chat by app name.
    static func prepare(mode: Mode, binding: Binding, provider: Provider,
                        isActive: @escaping @MainActor () -> Bool, limits: Limits = .init(), preparedCaptureTime: Date? = nil) throws -> Request {
        try Task.checkCancellation()
        guard isActive() else { throw Failure.inactive }
        if case .conversation(let profile) = mode, binding.application.bundleID != profile.bundleID { throw Failure.unsupportedProfile }
        guard preparedCaptureTime?.timeIntervalSince1970.isFinite != false,
              binding.application.processID > 0, binding.application.launchedAt.timeIntervalSince1970.isFinite,
              valid(binding.window.frame), binding.window.title.utf8.count <= 512, binding.window.document.utf8.count <= 4_096,
              binding.matches(try provider.inspect()) else { throw Failure.changedOrigin }
        return Request(mode: mode, binding: binding, provider: provider, isActive: isActive, limits: bounded(limits), preparedCaptureTime: preparedCaptureTime)
    }
    static func capture(_ request: Request) async throws -> Snapshot {
        try validate(request)
        let read = request.provider.read
        let worker = Task.detached(priority: .userInitiated) { try await read() }
        let tree = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try validate(request)
        let mode = request.mode, limits = request.limits, origin = request.binding
        let capturedAt = request.preparedCaptureTime ?? Date()
        let grouping = Task.detached(priority: .userInitiated) { try process(tree, mode: mode, origin: origin, limits: limits, capturedAt: capturedAt) }
        let result = try await withTaskCancellationHandler { try await grouping.value } onCancel: { grouping.cancel() }
        try validate(request)
        return result
    }

    /// Retains only the source identity and activity checks, never the frozen
    /// conversation tree. Queued and idle readers can revoke an origin without
    /// keeping a second hidden copy of text after a request stops or closes.
    static func authorization(for request: Request) -> @MainActor () -> Bool {
        let binding = request.binding, inspect = request.provider.inspect, isActive = request.isActive
        return {
            guard isActive(), let current = try? inspect() else { return false }
            return binding.matches(current)
        }
    }
    private static func validate(_ request: Request) throws {
        try Task.checkCancellation()
        guard request.isActive() else { throw Failure.inactive }
        guard request.binding.matches(try request.provider.inspect()) else { throw Failure.changedOrigin }
    }
    private static func bounded(_ requested: Limits) -> Limits {
        var result = requested
        result.maximumNodes = max(0, min(8_000, requested.maximumNodes))
        result.maximumInputBytes = max(0, min(400_000, requested.maximumInputBytes))
        result.maximumTextBytes = max(0, min(DocumentSummarySource.maximumTextBytes, requested.maximumTextBytes))
        result.maximumDepth = max(0, min(80, requested.maximumDepth))
        result.maximumSeconds = requested.maximumSeconds.isFinite ? max(0, min(5, requested.maximumSeconds)) : 5
        return result
    }

    nonisolated private static func process(_ tree: Tree, mode: Mode, origin: Binding, limits: Limits, capturedAt: Date) throws -> Snapshot {
        try Task.checkCancellation()
        if case .conversation(let profile) = mode {
            guard !tree.limited else { throw Failure.limit } // A cut tree can end mid-message.
            var bound = SummaryConversationSnapshot.Limits()
            bound.maximumNodes = limits.maximumNodes; bound.maximumInputBytes = limits.maximumInputBytes
            bound.maximumTextBytes = limits.maximumTextBytes; bound.maximumDepth = limits.maximumDepth
            let selected = try SummaryConversationSnapshot.select(tree.nodes, profile: profile, limits: bound)
            return Snapshot(mode: mode, origin: origin, text: selected.text, title: selected.title,
                application: origin.applicationName, documentURL: nil, coverage: selected.coverage,
                truncated: selected.truncated, capturedAt: capturedAt, offscreenMessages: selected.offscreenMessages, messages: selected.items)
        }
        guard tree.nodes.count <= limits.maximumNodes else { throw Failure.limit }
        let began = ProcessInfo.processInfo.systemUptime
        var bytes = 0, depths: [Int] = []
        for (index, node) in tree.nodes.enumerated() {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - began < limits.maximumSeconds else { throw Failure.limit }
            guard node.parent >= -1, node.parent < index else { throw Failure.unavailable }
            let depth = node.parent >= 0 ? depths[node.parent] + 1 : 0
            guard depth <= limits.maximumDepth else { throw Failure.limit }; depths.append(depth)
            for value in [node.role, node.value, node.title, node.description, node.identifier, node.document] + node.classes {
                guard value.utf8.count <= limits.maximumInputBytes - bytes else { throw Failure.limit }; bytes += value.utf8.count
            }
        }
        func path(_ index: Int) -> [Int] {
            var result: [Int] = [], cursor = index
            while cursor >= 0 { result.append(cursor); cursor = tree.nodes[cursor].parent }
            return result
        }
        func eligible(_ index: Int) -> Bool {
            !path(index).contains { tree.nodes[$0].protected || tree.nodes[$0].hidden || tree.nodes[$0].subrole == "AXSecureTextField"
                || ["AXToolbar", "AXMenu", "AXMenuBar"].contains(tree.nodes[$0].role) }
        }
        let documents = tree.nodes.indices.filter { eligible($0) && ["AXDocument", "AXTextArea"].contains(tree.nodes[$0].role) }
        let roots = documents.filter { index in !path(index).dropFirst().contains(where: { documents.contains($0) }) }
        let pdf = localPDF(origin.window.document)
        guard roots.count <= 1 else { throw Failure.unavailable }
        var pieces: [String] = []
        if let root = roots.first {
            for index in tree.nodes.indices where eligible(index) && path(index).contains(root) {
                let node = tree.nodes[index]
                guard ["AXStaticText", "AXTextArea", "AXHeading", "AXLink"].contains(node.role) else { continue }
                if path(index).dropFirst().contains(where: { !tree.nodes[$0].value.isEmpty && tree.nodes[$0].role == "AXTextArea" }) { continue }
                let text = node.value.isEmpty ? node.title : node.value
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if pieces.last.map({ $0.utf8.elementsEqual(text.utf8) }) != true { pieces.append(text) }
            }
        }
        let joined = pieces.joined(separator: "\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pdf != nil else { throw Failure.unavailable }
        let text = DocumentSummarySource.excerpt(joined, maximumBytes: limits.maximumTextBytes)
        let partial = tree.limited || text.utf8.count < joined.utf8.count
        let coverage = joined.isEmpty
            ? "Only the exact window's local PDF document URL was exposed. No file bytes, PDF pages, screenshots or other windows were read."
            : "Loaded accessible text from the exact originating native document window. Menus, toolbar, secure content and other windows excluded."
                + (partial ? " Capture is bounded; source excerpts or loaded content were omitted. Final document content is not guaranteed when the AX tree is incomplete." : "")
        return Snapshot(mode: mode, origin: origin, text: text, title: origin.window.title,
            application: origin.applicationName, documentURL: pdf, coverage: coverage,
            truncated: partial, capturedAt: capturedAt, offscreenMessages: 0, messages: [])
    }
    nonisolated private static func localPDF(_ raw: String) -> URL? {
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : URL(string: raw)
        guard let url, url.isFileURL, url.pathExtension.lowercased() == "pdf", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        return url
    }

    /// Immutable retained C reference, used by one read-only worker. All AppKit
    /// process inspection and request ownership remain on MainActor.
    nonisolated private final class AXTarget: @unchecked Sendable {
        let window: AXUIElement
        let limits: Limits
        let profile: SummaryConversationSnapshot.Profile?
        let timeout: Float
        init(window: AXUIElement, limits: Limits, profile: SummaryConversationSnapshot.Profile?, timeout: Float) {
            self.window = window; self.limits = limits; self.profile = profile; self.timeout = timeout
        }
    }

    nonisolated struct ScannedElement: Sendable {
        let node: SummaryConversationSnapshot.Node
        let childrenReadable: Bool
        let skipsChildren: Bool
    }

    /// The same lazy attribute boundary is used by AX capture and inert read
    /// spies. Excluded content is never fetched and then merely filtered out.
    nonisolated static func readElement(parent: Int, inside: Bool, profile: SummaryConversationSnapshot.Profile?,
                                       attribute: (String) -> CFTypeRef?, isValueSettable: () -> Bool,
                                       frame: () -> CGRect?) -> ScannedElement? {
        func string(_ name: String) -> String {
            let value = attribute(name)
            if let url = value as? URL { return url.absoluteString }
            return value as? String ?? ""
        }
        let role = string("AXRole"), subrole = string("AXSubrole")
        guard !["AXToolbar", "AXMenuBar", "AXMenu"].contains(role), subrole != "AXSecureTextField",
              (attribute("AXProtectedContent") as? Bool) != true,
              (attribute("AXHidden") as? Bool) != true else { return nil }
        let identifier = string("AXIdentifier"), classes = attribute("AXDOMClassList") as? [String] ?? []
        let knownComposer = ["ChatBar_ComposerTextView", "MessageEntryView"].contains(identifier) || classes.contains("ProseMirror")
        let editable = !knownComposer && (profile != nil || inside || ["AXDocument", "AXTextArea"].contains(role)) ? isValueSettable() : false
        let composer = knownComposer || (profile != nil && editable)
        let rootDescription = profile != nil && !composer && classes.contains("thread-scroll-container") ? string("AXDescription") : ""
        let transcript: Bool = switch profile {
        case .whatsApp: identifier == "ChatMessagesTableView"
        case .messages: identifier == "TranscriptCollectionView"
        case .claude: classes.contains("epitaxy-chat-panel-body")
        case .chatGPT, .codex: classes.contains("thread-scroll-container") && rootDescription == "Conversation"
        case .slack: classes.contains("p-message_pane")
        case nil: ["AXDocument", "AXTextArea"].contains(role)
        }
        let readable = inside || transcript
        let header = profile != nil && ["NavigationBar_HeaderViewButton", "ConversationTitle"].contains(identifier)
        let value = readable && !composer && ["AXStaticText", "AXTextArea", "AXHeading", "AXLink"].contains(role) ? string("AXValue") : ""
        // Native document extraction uses values/titles, never descriptions.
        // TextEdit returns AXError.failure for an optional description even
        // when its complete document value is available; do not fetch it.
        let description = profile != nil && !composer && (readable || header) ? string("AXDescription") : rootDescription
        let node = SummaryConversationSnapshot.Node(parent: parent, role: role, identifier: identifier,
            classes: classes, description: description, value: value,
            title: !composer && (readable || header) ? string("AXTitle") : "", subrole: subrole,
            frame: frame(), editable: editable, domID: string("AXDOMIdentifier"))
        return ScannedElement(node: node, childrenReadable: readable, skipsChildren: composer)
    }

    @concurrent private static func scan(_ target: AXTarget) async throws -> Tree {
        try scanSynchronously(target)
    }
    nonisolated private static func scanSynchronously(_ target: AXTarget) throws -> Tree {
        let began = ProcessInfo.processInfo.systemUptime
        var pending: [(AXUIElement, Int, Int, Bool)] = [(target.window, -1, 0, false)]
        var nodes: [SummaryConversationSnapshot.Node] = [], seen: [UInt: [AXUIElement]] = [:]
        var bytes = 0, limited = false
        func readableAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime - began < target.limits.maximumSeconds else {
                limited = true; return nil
            }
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
            case .success: return value
            case .attributeUnsupported, .noValue: return nil
            default: limited = true; return nil
            }
        }
        func readableFrame(_ element: AXUIElement) -> CGRect? {
            guard let position = readableAttribute(element, "AXPosition"), let size = readableAttribute(element, "AXSize"),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, sizeValue = CGSize.zero
            guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &sizeValue) else { limited = true; return nil }
            return CGRect(origin: point, size: sizeValue)
        }
        while let (item, parent, depth, inside) = pending.popLast() {
            try Task.checkCancellation()
            if nodes.count >= target.limits.maximumNodes || bytes >= target.limits.maximumInputBytes
                || ProcessInfo.processInfo.systemUptime - began >= target.limits.maximumSeconds { limited = true; break }
            if depth > target.limits.maximumDepth { limited = true; continue }
            let key = CFHash(item)
            if seen[key]?.contains(where: { CFEqual($0, item) }) == true { continue }
            seen[key, default: []].append(item); AXUIElementSetMessagingTimeout(item, target.timeout)
            guard let entry = readElement(parent: parent, inside: inside, profile: target.profile,
                attribute: { readableAttribute(item, $0) }, isValueSettable: {
                    var editable: DarwinBoolean = false
                    let status = AXUIElementIsAttributeSettable(item, "AXValue" as CFString, &editable)
                    if ![AXError.success, .attributeUnsupported, .noValue].contains(status) { limited = true }
                    return editable.boolValue
                }, frame: { readableFrame(item) }) else {
                if limited { break }
                continue
            }
            let node = entry.node
            let index = nodes.count
            let size = [node.role, node.identifier, node.description, node.value, node.title, node.subrole, node.document, node.domID].reduce(0) { $0 + $1.utf8.count }
                + node.classes.reduce(0) { $0 + $1.utf8.count }
            guard size <= target.limits.maximumInputBytes - bytes else { limited = true; break }
            nodes.append(node); bytes += size
            if limited { break }
            if entry.skipsChildren { continue }
            var count: CFIndex = 0
            let childStatus = AXUIElementGetAttributeValueCount(item, "AXChildren" as CFString, &count)
            if ![AXError.success, .attributeUnsupported, .noValue].contains(childStatus) { limited = true; break }
            if childStatus == .success, count > 0 {
                let available = max(0, target.limits.maximumNodes - nodes.count - pending.count)
                let limit = min(count, available)
                if count > available { limited = true }
                var children: [AXUIElement] = []
                for offset in stride(from: 0, to: limit, by: 128) {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime - began < target.limits.maximumSeconds else { limited = true; break }
                    var value: CFArray?
                    guard AXUIElementCopyAttributeValues(item, "AXChildren" as CFString, offset, min(128, limit - offset), &value) == .success,
                          let array = value as? [AXUIElement] else { limited = true; continue }
                    children += array
                }
                pending += children.reversed().map { ($0, index, depth + 1, entry.childrenReadable) }
            }
        }
        return Tree(nodes: nodes, limited: limited)
    }
    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    nonisolated private static func string(_ element: AXUIElement, _ name: String) -> String {
        let value = attribute(element, name)
        if let url = value as? URL { return url.absoluteString }
        return value as? String ?? ""
    }
    nonisolated private static func element(_ root: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(root, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }
    nonisolated private static func rect(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, "AXPosition"), let size = attribute(element, "AXSize"),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    nonisolated private static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 1 && frame.height > 1
    }
}
