import AppKit
import SwiftUI

nonisolated struct SidekickDisplayDescriptor: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let layout: SidekickPanelLayout

    static func mainDisplay(in displays: [Self], preferredID: UInt32? = nil) -> Self? {
        displays.first(where: { $0.id == preferredID })
            ?? displays.first(where: { $0.layout.onNotchedDisplay }) ?? displays.first
    }

    static func entryDisplays(in displays: [Self], mainDisplayID: UInt32?, pinned: Bool) -> [Self] {
        guard pinned else { return [] }
        var seen = Set<UInt32>()
        return displays.filter { $0.id != mainDisplayID && seen.insert($0.id).inserted }
    }

    var entryFrame: CGRect {
        layout.frame(for: CGSize(width: 210, height: 34), compact: true, expandedCue: layout.onNotchedDisplay)
    }
}

/// Each display gets an entry point; there remains one task, draft and review.
/// These nonactivating handles never capture context or take keyboard focus.
@MainActor
final class SidekickDisplayHandles {
    var onOpen: (UInt32) -> Void = { _ in }
    var canHold: () -> Bool = { false }
    var onHold: (UInt32) -> Bool = { _ in false }
    var onRelease: (Bool) -> Void = { _ in }
    private var panels: [UInt32: DisplayEntryPanel] = [:]
    private var gestures: [UInt32: SidekickHoldGesture] = [:]
    private var contexts: [UInt32: (display: SidekickDisplayDescriptor, store: AssistantStore)] = [:]

    func update(displays: [SidekickDisplayDescriptor], mainDisplayID: UInt32?, pinned: Bool, store: AssistantStore) {
        let entries = SidekickDisplayDescriptor.entryDisplays(in: displays, mainDisplayID: mainDisplayID, pinned: pinned)
        let ids = Set(entries.map(\.id))
        for id in Array(panels.keys) where !ids.contains(id) {
            gestures.removeValue(forKey: id)?.detach()
            panels.removeValue(forKey: id)?.close()
            contexts.removeValue(forKey: id)
        }
        for display in entries {
            let panel: DisplayEntryPanel
            if let existing = panels[display.id] { panel = existing }
            else {
                panel = DisplayEntryPanel(contentRect: display.entryFrame,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.title = "Relay Sidekick · \(display.name)"
                panel.identifier = NSUserInterfaceItemIdentifier("relay.sidekick.display.\(display.id)")
                panel.isFloatingPanel = true
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.becomesKeyOnlyIfNeeded = true
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                panels[display.id] = panel
            }
            if contexts[display.id]?.display != display || contexts[display.id]?.store !== store {
                gestures.removeValue(forKey: display.id)?.detach()
                let host = NSHostingView(rootView: DisplayEntryView(display: display, store: store) { [weak self] in
                    self?.onOpen(display.id)
                })
                panel.contentView = host
                gestures[display.id] = SidekickHoldGesture(view: host,
                    shouldBegin: { [weak self] in self?.canHold() == true },
                    begin: { [weak self] in self?.onHold(display.id) == true },
                    end: { [weak self] cancelled in self?.onRelease(cancelled) })
                contexts[display.id] = (display, store)
            }
            if panel.frame != display.entryFrame { panel.setFrame(display.entryFrame, display: true) }
            panel.orderFrontRegardless()
        }
    }

    func closeAll() {
        for gesture in gestures.values { gesture.detach() }
        for panel in panels.values { panel.close() }
        panels.removeAll()
        gestures.removeAll()
        contexts.removeAll()
    }

    isolated deinit {
        for gesture in gestures.values { gesture.detach() }
        for panel in panels.values { panel.close() }
    }
}

private final class DisplayEntryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct DisplayEntryView: View {
    let display: SidekickDisplayDescriptor
    let store: AssistantStore
    let open: () -> Void

    private var title: String {
        if store.voice.isRecording { "Microphone on" }
        else if store.voice.isBusy { "Finishing speech…" }
        else if store.pendingReview != nil { "Review pending" }
        else if store.isRunning { "Relay is working" }
        else { "Relay Sidekick" }
    }

    var body: some View {
        Button(action: open) {
            Group {
                if display.layout.onNotchedDisplay {
                    HStack {
                        Spacer()
                        Circle().fill(store.pendingReview != nil ? RelayColors.accentAmber : RelayColors.accentBlue)
                            .frame(width: 4, height: 4).padding(.trailing, 5)
                    }
                } else {
                    HStack(spacing: 7) {
                        if store.voice.isRecording {
                            Image(systemName: "mic.fill").foregroundStyle(RelayColors.accentCoral)
                        } else { RelayMark(size: 14) }
                        Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
            }
            .frame(width: display.entryFrame.width, height: display.entryFrame.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.black, in: UnevenRoundedRectangle(
            topLeadingRadius: display.layout.onNotchedDisplay ? 0 : 14, bottomLeadingRadius: 12,
            bottomTrailingRadius: 12, topTrailingRadius: display.layout.onNotchedDisplay ? 0 : 14))
        .preferredColorScheme(.dark)
        .accessibilityLabel("Open Sidekick on \(display.name). \(title)")
        .accessibilityIdentifier("sidekick.display.\(display.id).open")
    }
}
