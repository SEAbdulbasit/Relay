import AppKit
import Foundation
import Testing
@testable import Relay

@MainActor struct SidekickContentCanvasTests {
    @Test func everyPhaseUsesTheSameCanvasAndKeepsTheCutoutAnchor() {
        let layout = SidekickPanelLayout(screen: .init(x: 0, y: 0, width: 1_440, height: 900),
            visibleTop: 868, notchInset: 32, notchWidth: 220)
        let surface = layout.frame(for: .init(width: 530, height: 420), compact: false)
        let canvas = layout.canvas(containing: surface)
        #expect(canvas.contains(surface) && canvas.height == 452 && canvas.width == 570)
        #expect(canvas.maxY == layout.topEdge && canvas.maxY == layout.hardwareOpening?.maxY)
        #expect(canvas == layout.canvas)
        let compact = layout.frame(for: .init(width: 210, height: 34), compact: true)
        #expect(compact == layout.hardwareOpening)
        #expect(layout.canvas(containing: compact) == layout.canvas)
        for size in [CGSize(width: 512, height: 125), CGSize(width: 420, height: 64),
                     CGSize(width: 530, height: 140), CGSize(width: 530, height: 240),
                     CGSize(width: 530, height: 256), CGSize(width: 530, height: 260)] {
            let phase = layout.frame(for: size, compact: false)
            #expect(layout.canvas(containing: phase) == canvas)
            #expect(canvas.contains(phase) && phase.maxY == compact.maxY)
        }
    }
    @Test(arguments: [false, true]) func nonNotchedAndNegativeOriginDisplaysContainTheirSurface(_ negative: Bool) {
        let screen = negative ? CGRect(x: -1_920, y: -300, width: 1_920, height: 1_080) : CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let layout = SidekickPanelLayout(screen: screen, visibleTop: screen.maxY - 28, notchInset: 0, notchWidth: 0)
        let surface = layout.frame(for: .init(width: 530, height: 420), compact: false)
        let canvas = layout.canvas(containing: surface)
        #expect(canvas.contains(surface) && screen.contains(canvas))
        #expect(canvas.maxY == screen.maxY - 32)
    }
    @Test func narrowShortDisplayBoundsBothSurfaceAndCanvas() {
        let screen = CGRect(x: -320, y: 100, width: 320, height: 240)
        let layout = SidekickPanelLayout(screen: screen, visibleTop: 316, notchInset: 0, notchWidth: 0)
        let surface = layout.frame(for: .init(width: 530, height: 420), compact: false)
        let canvas = layout.canvas(containing: surface)
        #expect(screen.contains(surface) && screen.contains(canvas) && canvas.contains(surface))
        #expect(canvas.width <= 304 && canvas.height <= 208)
        #expect(surface.height < 350, "The actual view must use the Open Relay/Decline fallback.")
    }
    @Test func notchedShortDisplayIncludesItsInsetWithoutExtendingBelowTheScreen() {
        let screen = CGRect(x: 200, y: -200, width: 640, height: 360)
        let layout = SidekickPanelLayout(screen: screen, visibleTop: 128, notchInset: 32, notchWidth: 180)
        let surface = layout.frame(for: .init(width: 530, height: 420), compact: false)
        #expect(screen.contains(surface) && screen.contains(layout.canvas(containing: surface)))
        #expect(surface.maxY == screen.maxY && surface.height == 352)
    }
    @Test func mirroredGeometryAndDisconnectedDisplaySelectionDoNotReuseAnAbsentDisplay() {
        let layout = SidekickPanelLayout(screen: .init(x: -1_000, y: 0, width: 1_000, height: 800), visibleTop: 776, notchInset: 0, notchWidth: 0)
        let a = SidekickDisplayDescriptor(id: 7, name: "Owned primary", layout: layout)
        let b = SidekickDisplayDescriptor(id: 8, name: "Owned mirror", layout: layout)
        #expect(a.layout.canvas == b.layout.canvas)
        #expect(SidekickDisplayDescriptor.mainDisplay(in: [a], preferredID: b.id)?.id == a.id)
        #expect(SidekickDisplayDescriptor.mainDisplay(in: [], preferredID: b.id) == nil)
        #expect(SidekickDisplayDescriptor.entryDisplays(in: [a,b,b], mainDisplayID: a.id, pinned: true).map(\.id) == [b.id])
    }
}
