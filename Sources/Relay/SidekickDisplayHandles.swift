import AppKit
import Observation
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
        entryFrame(for: .idle)
    }

    func entryFrame(for cue: SidekickCompactCue) -> CGRect {
        layout.frame(
            for: cue.compactSurfaceSize(onNotchedDisplay: layout.onNotchedDisplay),
            compact: true,
            expandedCue: layout.onNotchedDisplay
        )
    }

    func acceptsPointer(_ pointer: CGPoint, for cue: SidekickCompactCue) -> Bool {
        guard [pointer.x, pointer.y].allSatisfy(\.isFinite) else { return false }
        let frame = entryFrame(for: cue)
        if !layout.onNotchedDisplay && cue.isIdle {
            return SidekickRestingHandleLayout.acceptsPointer(pointer, inCanvas: frame)
        }
        var hitBounds = frame
        if layout.onNotchedDisplay {
            hitBounds.size.height += 2
        }
        guard hitBounds.contains(pointer) else { return false }
        let clampedY = max(2, min(frame.height - 1, frame.maxY - pointer.y))
        let local = CGPoint(x: pointer.x - frame.minX, y: clampedY)
        return sidekickOutline(
            attached: layout.onNotchedDisplay,
            isHardwareIsland: layout.hasHardwareIsland,
            expanded: false,
            showsStatus: cue.isActive,
            size: frame.size
        )
        .path(in: CGRect(origin: .zero, size: frame.size))
        .contains(local)
    }
}

/// Each display gets an entry point; there remains one task, draft and review.
/// These nonactivating handles never capture context or take keyboard focus.
@Observable @MainActor
private final class SidekickDisplayPresentation {
    var hoveredDisplayID: UInt32?
    var cue: SidekickCompactCue = .idle
}

@MainActor
final class SidekickDisplayHandles {
    var onOpen: (UInt32) -> Void = { _ in }
    var canHold: () -> Bool = { false }
    var onHold: (UInt32) -> Bool = { _ in false }
    var onRelease: (Bool) -> Void = { _ in }

    private let presentation = SidekickDisplayPresentation()
    private var hoveredDisplayID: UInt32? {
        get { presentation.hoveredDisplayID }
        set { presentation.hoveredDisplayID = newValue }
    }
    private var cue: SidekickCompactCue {
        get { presentation.cue }
        set { presentation.cue = newValue }
    }

    private var panels: [UInt32: DisplayEntryPanel] = [:]
    private var hosts: [UInt32: SidekickHitGatedHostingView<DisplayEntryView>] = [:]
    private var gestures: [UInt32: SidekickHoldGesture] = [:]
    private var contexts: [UInt32: (display: SidekickDisplayDescriptor, store: AssistantStore)] = [:]

    func update(
        displays: [SidekickDisplayDescriptor],
        mainDisplayID: UInt32?,
        pinned: Bool,
        store: AssistantStore,
        cue: SidekickCompactCue = .idle
    ) {
        if self.cue != cue { self.cue = cue }
        let entries = SidekickDisplayDescriptor.entryDisplays(in: displays, mainDisplayID: mainDisplayID, pinned: pinned)
        let ids = Set(entries.map(\.id))
        for id in Array(panels.keys) where !ids.contains(id) {
            if hoveredDisplayID == id { hoveredDisplayID = nil }
            gestures.removeValue(forKey: id)?.detach()
            hosts.removeValue(forKey: id)
            panels.removeValue(forKey: id)?.close()
            contexts.removeValue(forKey: id)
        }
        for display in entries {
            let currentCue = SidekickCompactCue(
                store: store,
                ownsDictation: cue.ownsDictation,
                hasResult: cue.hasResult
            )
            let targetFrame = display.entryFrame(for: currentCue)
            let panel: DisplayEntryPanel
            if let existing = panels[display.id] { panel = existing }
            else {
                panel = DisplayEntryPanel(contentRect: targetFrame,
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
                panel.ignoresMouseEvents = true
                panels[display.id] = panel
            }
            if contexts[display.id]?.display != display || contexts[display.id]?.store !== store {
                gestures.removeValue(forKey: display.id)?.detach()
                let host = SidekickHitGatedHostingView(
                    rootView: DisplayEntryView(display: display, store: store, presentation: presentation) { [weak self] in
                        self?.handlePress(on: display.id)
                    }
                )
                host.sizingOptions = []
                panel.contentView = host
                hosts[display.id] = host
                gestures[display.id] = SidekickHoldGesture(view: host,
                    shouldBegin: { [weak self] in
                        self?.canBeginHold(on: display.id, at: NSEvent.mouseLocation) == true
                    },
                    begin: { [weak self] in
                        self?.beginHold(on: display.id, at: NSEvent.mouseLocation) == true
                    },
                    end: { [weak self] cancelled in self?.onRelease(cancelled) })
                contexts[display.id] = (display, store)
            }
            hosts[display.id]?.gatesToRestingHandleHitRect = !display.layout.onNotchedDisplay && currentCue.isIdle
            if panel.frame != targetFrame { panel.setFrame(targetFrame, display: true) }
            panel.orderFrontRegardless()
        }
    }

    func updatePointer(at pointer: CGPoint, cue: SidekickCompactCue) {
        if self.cue != cue { self.cue = cue }
        var nextHovered: UInt32?
        for (id, panel) in panels {
            guard let context = contexts[id] else { continue }
            let currentCue = SidekickCompactCue(
                store: context.store,
                ownsDictation: cue.ownsDictation,
                hasResult: cue.hasResult
            )
            let expectedFrame = context.display.entryFrame(for: currentCue)
            if panel.frame != expectedFrame {
                panel.setFrame(expectedFrame, display: true)
            }
            let isIdleNotchless = !context.display.layout.onNotchedDisplay && currentCue.isIdle
            hosts[id]?.gatesToRestingHandleHitRect = isIdleNotchless
            let accepts = context.display.acceptsPointer(pointer, for: currentCue)
            if accepts && (isIdleNotchless || context.display.layout.onNotchedDisplay) {
                nextHovered = id
            }
            if panel.ignoresMouseEvents == accepts {
                panel.ignoresMouseEvents = !accepts
            }
        }
        if hoveredDisplayID != nextHovered {
            hoveredDisplayID = nextHovered
        }
    }

    func resetPointer() {
        if hoveredDisplayID != nil { hoveredDisplayID = nil }
        for panel in panels.values where !panel.ignoresMouseEvents {
            panel.ignoresMouseEvents = true
        }
    }

    private func handlePress(on displayID: UInt32) {
        guard let context = contexts[displayID] else { return }
        let currentCue = SidekickCompactCue(
            store: context.store,
            ownsDictation: cue.ownsDictation,
            hasResult: cue.hasResult
        )
        let accepts = context.display.acceptsPointer(NSEvent.mouseLocation, for: currentCue)
        guard SidekickRestingHandleLayout.currentEventAllowsHandleActivation(acceptsPointer: accepts) else { return }
        onOpen(displayID)
    }

    private func canBeginHold(on displayID: UInt32, at pointer: CGPoint) -> Bool {
        guard canHold(), let context = contexts[displayID] else { return false }
        let currentCue = SidekickCompactCue(
            store: context.store,
            ownsDictation: cue.ownsDictation,
            hasResult: cue.hasResult
        )
        return context.display.acceptsPointer(pointer, for: currentCue)
    }

    private func beginHold(on displayID: UInt32, at pointer: CGPoint) -> Bool {
        guard canBeginHold(on: displayID, at: pointer) else { return false }
        return onHold(displayID)
    }

    func closeAll() {
        hoveredDisplayID = nil
        cue = .idle
        for gesture in gestures.values { gesture.detach() }
        for panel in panels.values { panel.close() }
        panels.removeAll()
        hosts.removeAll()
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
    @Bindable var store: AssistantStore
    @Bindable var presentation: SidekickDisplayPresentation
    let open: () -> Void

    private var cue: SidekickCompactCue {
        SidekickCompactCue(
            store: store,
            ownsDictation: presentation.cue.ownsDictation,
            hasResult: presentation.cue.hasResult
        )
    }

    private var entryFrame: CGRect {
        display.entryFrame(for: cue)
    }

    var body: some View {
        let currentCue = cue
        if !display.layout.onNotchedDisplay && currentCue.isIdle {
            SidekickRestingHandleButton(
                hovered: presentation.hoveredDisplayID == display.id,
                accessibilityLabel: "Open Sidekick on \(display.name). \(currentCue.title)",
                accessibilityIdentifier: "sidekick.display.\(display.id).open",
                action: open
            )
            .preferredColorScheme(.dark)
        } else {
            let isHovered = presentation.hoveredDisplayID == display.id
            let activeOrHovered = isHovered || currentCue.isActive
            let visualSize: CGSize = if display.layout.onNotchedDisplay, !activeOrHovered,
                                        let opening = display.layout.hardwareOpening {
                opening.size
            } else {
                entryFrame.size
            }
            let radii = sidekickRadii(
                attached: display.layout.onNotchedDisplay,
                isHardwareIsland: display.layout.hasHardwareIsland,
                expanded: false,
                showsStatus: currentCue.isActive,
                size: visualSize
            )
            let outline = NotchShape(
                topCornerRadius: radii.top,
                bottomCornerRadius: radii.bottom,
                isIsland: !display.layout.onNotchedDisplay || display.layout.hasHardwareIsland
            )
            let skirt = NotchSkirtShape(
                topCornerRadius: radii.top,
                bottomCornerRadius: radii.bottom,
                isIsland: !display.layout.onNotchedDisplay || display.layout.hasHardwareIsland
            )
            Button(action: open) {
                Group {
                    if display.layout.onNotchedDisplay {
                        Color.clear
                    } else {
                        HStack(spacing: 8) {
                            if currentCue.showsMicrophoneIcon {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(RelayColors.accentCoral)
                            } else {
                                RelayActivityMark(size: 14, fast: store.isRunning && store.pendingReview == nil)
                            }
                            Text(currentCue.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .padding(.horizontal, 10)
                    }
                }
                .frame(width: visualSize.width, height: visualSize.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background {
                outline.fill(.black.opacity(display.layout.onNotchedDisplay ? 1.0 : 0.90))
            }
            .overlay {
                if !display.layout.onNotchedDisplay || display.layout.hasHardwareIsland {
                    skirt.stroke(.white.opacity(0.16), lineWidth: 0.75).allowsHitTesting(false)
                } else if currentCue.isActive {
                    skirt.stroke(currentCue.indicatorColor.opacity(0.65), lineWidth: 1.0).allowsHitTesting(false)
                }
            }
            .clipShape(outline)
            .shadow(
                color: .black.opacity((!display.layout.onNotchedDisplay || activeOrHovered) ? 0.40 : 0),
                radius: 7,
                y: 2
            )
            .frame(width: entryFrame.width, height: entryFrame.height, alignment: .top)
            .preferredColorScheme(.dark)
            .accessibilityLabel("Open Sidekick on \(display.name). \(currentCue.title)")
            .accessibilityIdentifier("sidekick.display.\(display.id).open")
        }
    }
}
