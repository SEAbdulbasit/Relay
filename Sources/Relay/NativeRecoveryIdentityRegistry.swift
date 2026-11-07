import ApplicationServices
import Foundation

/// In-memory recovery bookkeeping. Callers supply already-validated captured
/// identities; this registry never queries AX, activates an app or grants access.
/// Equality is established with retained CF objects, never CFHash or a tree path.
@MainActor
final class NativeRecoveryIdentityRegistry {
    nonisolated struct WindowID: Hashable, Sendable {
        fileprivate let value: UUID
        var opaqueValue: String { value.uuidString }
    }
    nonisolated struct ControlID: Hashable, Sendable {
        fileprivate let value: UUID
        var opaqueValue: String { value.uuidString }
    }

    private struct WindowEntry {
        let id: WindowID
        let target: DesktopApplicationIdentity
        let window: AXUIElement
        let documentFingerprint: String
        let browser: BrowserPageReader.CurrentDocumentTarget?
        var used: UInt64
    }
    private struct ControlEntry {
        let id: ControlID
        let window: WindowID
        let element: AXUIElement
        let identityFingerprint: String
        var used: UInt64
    }

    private let maximumWindows: Int
    private let maximumControls: Int
    private var windows: [WindowEntry] = []
    private var controls: [ControlEntry] = []
    private var clock: UInt64 = 0

    init(maximumWindows: Int = 128, maximumControls: Int = 512) {
        self.maximumWindows = max(1, min(maximumWindows, 128))
        self.maximumControls = max(1, min(maximumControls, 512))
    }

    /// Only call after the containing process/window/document capture has passed
    /// its pre/post checks. A browser needs its positive exact tab/document proof.
    func registerWindow(target: DesktopApplicationIdentity, window: AXUIElement,
                        documentFingerprint: String,
                        browser: BrowserPageReader.CurrentDocumentTarget?) -> WindowID? {
        let isBrowser = ["com.google.Chrome", "com.apple.Safari"].contains(target.bundleID)
        guard !documentFingerprint.isEmpty, isBrowser == (browser != nil) else { return nil }
        if let browser {
            guard BrowserPageReader.capturedDocumentBelongs(browser, processID: target.processID,
                launchedAt: target.launchedAt, window: window) else { return nil }
        }
        clock &+= 1
        if let index = windows.firstIndex(where: { entry in
            guard entry.target == target, CFEqual(entry.window, window),
                  entry.documentFingerprint == documentFingerprint else { return false }
            switch (entry.browser, browser) {
            case (nil, nil): return true
            case (.some(let before), .some(let after)):
                return BrowserPageReader.sameCapturedDocument(before, after)
            default: return false
            }
        }) {
            windows[index].used = clock
            return windows[index].id
        }
        if windows.count >= maximumWindows, let oldest = windows.min(by: { $0.used < $1.used }) {
            windows.removeAll { $0.id == oldest.id }
            controls.removeAll { $0.window == oldest.id }
        }
        let id = WindowID(value: UUID())
        windows.append(WindowEntry(id: id, target: target, window: window,
            documentFingerprint: documentFingerprint, browser: browser, used: clock))
        return id
    }

    /// The actual AX control must be retained. Mutable values are excluded from
    /// identity: the operation key already binds the requested value. A helper ref, label, role or
    /// structural position cannot substitute for its object identity.
    func registerControl(element: AXUIElement, in window: WindowID,
                         identityFingerprint: String) -> ControlID? {
        guard contains(window), !identityFingerprint.isEmpty else { return nil }
        clock &+= 1
        if let index = controls.firstIndex(where: {
            $0.window == window && CFEqual($0.element, element) && $0.identityFingerprint == identityFingerprint
        }) {
            controls[index].used = clock
            return controls[index].id
        }
        if controls.count >= maximumControls, let oldest = controls.min(by: { $0.used < $1.used }) {
            controls.removeAll { $0.id == oldest.id }
        }
        let id = ControlID(value: UUID())
        controls.append(ControlEntry(id: id, window: window, element: element,
            identityFingerprint: identityFingerprint, used: clock))
        return id
    }

    func contains(_ id: WindowID) -> Bool { windows.contains { $0.id == id } }
    func contains(_ id: ControlID) -> Bool {
        controls.contains { $0.id == id && contains($0.window) }
    }

    func removeAll() {
        windows.removeAll()
        controls.removeAll()
    }
}
