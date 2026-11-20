import AppKit
import SwiftUI

/// The actual window hosting this workspace, without retaining its view/window.
/// Used only by the explicit navigation action before mounting the next page.
@MainActor final class WorkspaceWindowReference {
    private weak var owner: NSView?
    private(set) weak var window: NSWindow?

    func bind(_ window: NSWindow?, owner: NSView) {
        if let window { self.owner = owner; self.window = window }
        else if self.owner === owner { self.owner = nil; self.window = nil }
    }

    /// Failure keeps the existing page visible; never hide a refusing responder.
    func resignForNavigation() -> Bool {
        guard let window else { return false }
        return window.makeFirstResponder(nil)
    }
}

struct WorkspaceWindowProbe: NSViewRepresentable {
    let reference: WorkspaceWindowReference

    func makeNSView(context: Context) -> ProbeView { ProbeView(reference: reference) }
    func updateNSView(_ view: ProbeView, context: Context) { view.updateReference(reference) }

    final class ProbeView: NSView {
        private var reference: WorkspaceWindowReference
        init(reference: WorkspaceWindowReference) {
            self.reference = reference
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("WorkspaceWindowProbe requires an explicit reference") }
        func updateReference(_ next: WorkspaceWindowReference) {
            guard reference !== next else { return }
            reference.bind(nil, owner: self)
            reference = next
            reference.bind(window, owner: self)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference.bind(window, owner: self)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
