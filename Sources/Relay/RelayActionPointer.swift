import AppKit
import ApplicationServices

/// A separate, click-through agent pointer. It never moves or captures the user's mouse.
@MainActor
final class RelayActionPointer {
    static let shared = RelayActionPointer()
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    static func appKitPoint(axRect: CGRect, primaryHeight: CGFloat) -> CGPoint? {
        guard [axRect.minX, axRect.minY, axRect.width, axRect.height, primaryHeight].allSatisfy(\.isFinite),
              axRect.width > 0, axRect.height > 0 else { return nil }
        return CGPoint(x: axRect.midX, y: primaryHeight - axRect.midY)
    }

    func show(element: AXUIElement, label: String) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { hide(); return }
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { hide(); return }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { hide(); return }
        show(axRect: CGRect(origin: position, size: size), label: label)
    }

    func show(axRect: CGRect, label: String) {
        guard let primary = NSScreen.screens.first,
              let point = Self.appKitPoint(axRect: axRect, primaryHeight: primary.frame.maxY),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { hide(); return }
        dismissal?.cancel()
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Relay Action Pointer"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isExcludedFromWindowsMenu = true
            self.panel = panel
        }
        guard let panel else { return }
        let width: CGFloat = 150
        let height: CGFloat = 48
        // Cursor tip sits at the real AX target. Keep its action badge inside the display.
        let origin = CGPoint(x: point.x, y: point.y - height)
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: false)
        let view = PointerView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.label = label
        view.badgeOnLeft = point.x + width > screen.frame.maxX
        if view.badgeOnLeft {
            panel.setFrameOrigin(CGPoint(x: point.x - width + 22, y: origin.y))
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
    }

    func finishAction() {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            self?.hide()
        }
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
    }

    private final class PointerView: NSView {
        var label = ""
        var badgeOnLeft = false
        override func draw(_ dirtyRect: NSRect) {
            let tipX: CGFloat = badgeOnLeft ? bounds.width - 22 : 0
            let pointer = NSBezierPath()
            pointer.move(to: CGPoint(x: tipX + 1, y: 47))
            pointer.line(to: CGPoint(x: tipX + 5, y: 23))
            pointer.line(to: CGPoint(x: tipX + 11, y: 30))
            pointer.line(to: CGPoint(x: tipX + 20, y: 30))
            pointer.close()
            NSColor.systemPurple.setFill()
            pointer.fill()
            NSColor.white.setStroke()
            pointer.lineWidth = 1.5
            pointer.stroke()
            let badge = CGRect(x: badgeOnLeft ? 0 : 22, y: 3, width: 126, height: 23)
            NSColor.systemPurple.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
            ("Relay · " + label as NSString).draw(in: badge.insetBy(dx: 7, dy: 4), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white
            ])
        }
    }
}
