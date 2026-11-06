import AppKit
import ApplicationServices
import CryptoKit
import Foundation

/// Stages a local file path in AppKit's Go to Folder sheet. The user chooses the file.
@MainActor
struct NativeAttachmentStaging {
    private let pid: pid_t
    private let field: AXUIElement
    private let sheet: AXUIElement
    let file: URL
    let appName: String
    let bundleID: String
    let fingerprint: String

    init(path: String, app: NSRunningApplication, grants: [ScopeGrant]) throws {
        guard AXIsProcessTrusted() else {
            throw RelayError.message("Enable Relay in System Settings → Privacy & Security → Accessibility before staging a file path.")
        }
        guard let bundleID = app.bundleIdentifier, !app.isTerminated else { throw Self.unavailable }
        let file = try ToolPolicy.scopedURL(path, grants: grants)
        guard !file.path.contains(where: \.isNewline), !file.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw RelayError.message("The selected file path contains characters the chooser cannot stage safely.")
        }
        let data = try LocalStateFile.read(file, maximumBytes: 16 * 1_024 * 1_024)
        let chooser = try Self.chooser(pid: app.processIdentifier)
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(chooser.field, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue, let previous = Self.attribute(chooser.field, kAXValueAttribute) as? String,
              previous.utf8.count <= 4_096 else {
            throw Self.unavailable
        }
        self.pid = app.processIdentifier
        self.field = chooser.field
        self.sheet = chooser.sheet
        self.file = file
        self.appName = app.localizedName ?? bundleID
        self.bundleID = bundleID
        let identity = [bundleID, String(app.processIdentifier), String(CFHash(chooser.panel)), String(CFHash(chooser.sheet)),
                        String(CFHash(chooser.field)), file.path, previous, SHA256.hash(data: data).description]
        self.fingerprint = SHA256.hash(data: Data(identity.joined(separator: "\0").utf8)).description
    }

    func stage() throws -> ToolResult {
        try Task.checkCancellation()
        AXUIElementSetMessagingTimeout(field, 0.3)
        let result = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, file.path as CFString)
        guard result == .success else {
            throw RelayError.message("The chooser returned AX error \(result.rawValue). Check the field before retrying.")
        }
        let current = try? Self.chooser(pid: pid)
        let observed = current.flatMap { Self.attribute($0.field, kAXValueAttribute) as? String }
        let verified = current.map { CFEqual($0.field, field) && CFEqual($0.sheet, sheet) } == true
            && observed?.utf8.elementsEqual(file.path.utf8) == true
        return ToolResult(summary: verified ? "Staged \(file.lastPathComponent) in \(appName)’s file chooser. Choose the file to continue."
                                            : "Requested path entry in \(appName)’s file chooser. Check the field before continuing.",
                          evidence: verified ? "Read back the exact scoped path in the same Go to Folder field. The file was not opened, attached or uploaded."
                                             : "The path write was accepted, but the exact value could not be verified in the same chooser. No selection was dispatched.",
                          verified: verified)
    }

    static func isChooserControl(_ control: AXUIElement) -> Bool {
        var current: AXUIElement? = control
        for _ in 0..<12 {
            guard let element = current else { break }
            AXUIElementSetMessagingTimeout(element, 0.03)
            let id = attribute(element, kAXIdentifierAttribute) as? String
            if id == "open-panel" || id == "GoToWindow" || id == "PathTextField" { return true }
            current = self.element(attribute(element, kAXParentAttribute))
        }
        return false
    }

    static func canUseHelperControls(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.1)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty, windows.count <= 32 else {
            return false
        }
        let focused = element(attribute(root, kAXFocusedWindowAttribute))
        var queue = windows + (focused.map { [$0] } ?? [])
        var seen: [AXUIElement] = []
        var cursor = 0
        while cursor < queue.count {
            guard cursor < 96 else { return false }
            let node = queue[cursor]
            cursor += 1
            guard !seen.contains(where: { CFEqual($0, node) }) else { continue }
            seen.append(node)
            AXUIElementSetMessagingTimeout(node, 0.03)
            guard attribute(node, kAXRoleAttribute) as? String != nil, !isChooserControl(node) else { return false }
            queue.append(contentsOf: sheetChildren(of: node))
        }
        return true
    }

    private static var unavailable: RelayError {
        .message("In the target app, open its standard file chooser and press Command–Shift–G. Leave the Go to Folder field open, then retry staging.")
    }

    private static func chooser(pid: pid_t) throws -> (panel: AXUIElement, sheet: AXUIElement, field: AXUIElement) {
        guard AXIsProcessTrusted() else { throw unavailable }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.1)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var queue: [(AXUIElement, AXUIElement?, AXUIElement?)] = windows.prefix(20).map { ($0, nil, nil) }
        var matches: [(AXUIElement, AXUIElement, AXUIElement)] = []
        var cursor = 0
        while cursor < queue.count, cursor < 96 {
            try Task.checkCancellation()
            let (node, panel, sheet) = queue[cursor]
            cursor += 1
            AXUIElementSetMessagingTimeout(node, 0.03)
            let id = attribute(node, kAXIdentifierAttribute) as? String
            let role = attribute(node, kAXRoleAttribute) as? String
            let openPanel = id == "open-panel" && ["AXWindow", "AXSheet"].contains(role ?? "") ? node : panel
            let goSheet = openPanel != nil && id == "GoToWindow" && ["AXWindow", "AXSheet"].contains(role ?? "") ? node : sheet
            if let openPanel, let goSheet, id == "PathTextField", role == "AXTextField",
               !matches.contains(where: { CFEqual($0.2, node) }) {
                var nodePID: pid_t = 0
                guard AXUIElementGetPid(node, &nodePID) == .success, nodePID == pid else { throw unavailable }
                matches.append((openPanel, goSheet, node))
            }
            // Walk standard window and sheet relationships. Only the small Go to Folder
            // sheet is searched for a path field, never the chooser's file listing.
            let children = goSheet != nil ? (attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []) : sheetChildren(of: node)
            queue.append(contentsOf: children.prefix(max(0, 96 - queue.count)).map { ($0, openPanel, goSheet) })
        }
        guard matches.count == 1, let match = matches.first else { throw unavailable }
        return match
    }

    private static func sheetChildren(of node: AXUIElement) -> [AXUIElement] {
        let sheets = attribute(node, "AXSheets") as? [AXUIElement] ?? []
        let children = (attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(40).filter { child in
            AXUIElementSetMessagingTimeout(child, 0.03)
            return (attribute(child, kAXRoleAttribute) as? String) == "AXSheet" && !sheets.contains { CFEqual($0, child) }
        }
        return sheets + children
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
