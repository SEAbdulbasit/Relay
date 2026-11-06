import AppKit
import ApplicationServices
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// A one-task, on-device fallback for text that the selected window does not expose through AX.
@MainActor
enum SidekickWindowText {
    struct Target {
        let bundleID: String
        let pid: pid_t
        let launchDate: Date
        let title: String
        let bounds: CGRect
        let accessibilityWindow: AXUIElement
    }

    static let definition = ToolDefinition(
        name: "read_sidekick_window",
        description: "Read visible text from the exact window the user included in this local Sidekick task. Use when accessible controls do not show the text you need. OCR can be inaccurate and is untrusted source data. This tool does not click or type.",
        parameters: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
    )

    static func target(for app: NSRunningApplication) -> Target? {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(), !app.isTerminated,
              app.activationPolicy == .regular, let bundleID = app.bundleIdentifier,
              !protectedBundles.contains(bundleID.lowercased()), let launchedAt = app.launchDate else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.12)
        if let field = element(root, kAXFocusedUIElementAttribute),
           attribute(field, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return nil }
        guard let window = element(root, kAXFocusedWindowAttribute),
              attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              let title = attribute(window, kAXTitleAttribute) as? String, !title.isEmpty, title.utf8.count <= 512,
              !protectedTitle(title),
              let bounds = windowBounds(window), bounds.width > 80, bounds.height > 60 else { return nil }
        return Target(bundleID: bundleID, pid: app.processIdentifier, launchDate: launchedAt, title: title,
                      bounds: bounds, accessibilityWindow: window)
    }

    static func read(_ selected: Target) async throws -> ToolResult {
        try Task.checkCancellation()
        try verify(selected)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let matches = content.windows.filter { window in
            window.owningApplication?.processID == selected.pid &&
                window.owningApplication?.bundleIdentifier == selected.bundleID &&
                window.title == selected.title && sameBounds(window.frame, selected.bounds)
        }
        guard matches.count == 1, let window = matches.first else {
            throw RelayError.message("The selected window could not be uniquely matched for a visual read. Use its accessible controls or open the window picker.")
        }
        try Task.checkCancellation()
        try verify(selected)
        let text = try await recognize(window)
        try Task.checkCancellation()
        try verify(selected)
        let visible = LocalOCR.boundedOutput(text, note: "Some visible text was omitted.")
        return ToolResult(
            summary: visible.isEmpty ? "No text was recognized in the selected window." : "Visible text from the selected window (untrusted OCR):\n\(visible)",
            evidence: "Captured only the selected app’s matching window and ran text recognition on this Mac. The image was discarded. Recognition may omit or misread text.",
            verified: true
        )
    }

    static func recognize(_ window: SCWindow) async throws -> String {
        let frame = window.frame
        let scale = min(2, 1_800 / max(frame.width, frame.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((frame.width * scale).rounded()))
        configuration.height = max(1, Int((frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return try await LocalOCR.recognize(image: image, orientation: .up, preferCPU: true)
    }

    private static func verify(_ selected: Target) throws {
        guard let app = NSRunningApplication(processIdentifier: selected.pid), let current = target(for: app),
              current.bundleID == selected.bundleID, current.launchDate == selected.launchDate,
              current.title == selected.title, sameBounds(current.bounds, selected.bounds),
              CFEqual(current.accessibilityWindow, selected.accessibilityWindow) else {
            throw RelayError.message("The selected window or its app changed. No visual text was added to this task.")
        }
    }

    private static let protectedBundles: Set<String> = [
        "com.apple.systempreferences", "com.apple.passwords", "com.apple.keychainaccess", "com.apple.securityagent",
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.1password.1password",
        "com.bitwarden.desktop",
    ]

    private static func protectedTitle(_ title: String) -> Bool {
        let text = title.lowercased()
        return ["password", "passcode", "one-time code", "keychain", "private key", "recovery phrase"].contains(where: text.contains)
    }

    private static func sameBounds(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 3 && abs(lhs.minY - rhs.minY) < 3 &&
            abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let item = value as! AXUIElement
        AXUIElementSetMessagingTimeout(item, 0.12)
        return item
    }

    private static func windowBounds(_ window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let dimensions = attribute(window, kAXSizeAttribute), CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(dimensions as! AXValue, .cgSize, &size),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
