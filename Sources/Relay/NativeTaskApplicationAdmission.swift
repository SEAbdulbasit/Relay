import AppKit
import ApplicationServices
import Foundation

/// Called only from a trusted original user app selection/invocation. This is
/// not a parser of model output, observed content or arbitrary app names.
@MainActor enum NativeTaskApplicationAdmission {
    enum Failure: Error { case unavailableOriginalWindow, changedOriginalScope }

    static func captureSelectedWindow(application: NSRunningApplication) throws -> NativeWindowTaskAdapter.ApplicationAdmission {
        try Task.checkCancellation()
        guard AXIsProcessTrusted(), let identity = DesktopApplicationTarget.identity(of: application) else {
            throw Failure.unavailableOriginalWindow
        }
        let root = AXUIElementCreateApplication(identity.processID)
        AXUIElementSetMessagingTimeout(root, 0.08)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func selectedWindow() throws -> AXUIElement {
            guard let raw = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw Failure.unavailableOriginalWindow
            }
            return unsafeDowncast(raw, to: AXUIElement.self)
        }
        func metadata(_ window: AXUIElement) throws -> [String] {
            AXUIElementSetMessagingTimeout(window, 0.08)
            guard attribute(window, kAXRoleAttribute) as? String == "AXWindow" else { throw Failure.unavailableOriginalWindow }
            return [kAXTitleAttribute, kAXDocumentAttribute, kAXURLAttribute].map { key in
                let raw = attribute(window, key)
                if let url = raw as? URL { return url.absoluteString }
                return raw as? String ?? ""
            }
        }
        let original = try selectedWindow(), fields = try metadata(original)
        guard fields[0].utf8.count <= 512, fields.dropFirst().allSatisfy({ $0.utf8.count <= 4096 }) else {
            throw Failure.unavailableOriginalWindow
        }
        let browser = ["com.google.Chrome", "com.apple.Safari"].contains(identity.bundleID)
            ? try BrowserPageReader.captureCurrentTarget(application: application, expectedWindow: original) : nil
        return .init(application: identity, validate: {
            try Task.checkCancellation()
            guard AXIsProcessTrusted(), DesktopApplicationTarget.matches(identity, application: application),
                  CFEqual(try selectedWindow(), original),
                  zip(fields, try metadata(original)).allSatisfy({ $0.utf16.elementsEqual($1.utf16) }) else {
                throw Failure.changedOriginalScope
            }
            if let browser { try BrowserPageReader.validateCurrentTarget(browser, expectedWindow: original) }
        })
    }
}
