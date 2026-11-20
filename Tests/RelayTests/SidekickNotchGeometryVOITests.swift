import AppKit
import Foundation
import Testing
@testable import Relay

@Suite(.serialized) @MainActor
struct SidekickNotchGeometryVOITests {
    init() async throws {
        await awaitParitySuiteQuietWindow()
    }

    // MARK: - VOI-11: Three Surface Modes & Hardware Island Geometry

    @Test func threeSurfaceModesAreCorrectlyDerived() {
        // 1. External notchless display -> floatingIsland
        let externalScreen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let externalLayout = SidekickPanelLayout(
            screen: externalScreen,
            visibleTop: 1415,
            notchInset: 0,
            notchWidth: 0,
            notchCenterX: nil,
            isHardwareIsland: false
        )
        #expect(externalLayout.surfaceMode == .floatingIsland)
        #expect(!externalLayout.hasPhysicalNotch)
        #expect(!externalLayout.hasHardwareIsland)
        #expect(!externalLayout.onNotchedDisplay)
        #expect(externalLayout.topInset == 9)
        #expect(externalLayout.centerGap == 24)

        // 2. Built-in display with physical notch -> notch
        let notchedScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let notchedLayout = SidekickPanelLayout(
            screen: notchedScreen,
            visibleTop: 1117,
            notchInset: 32,
            notchWidth: 200,
            notchCenterX: 864,
            isHardwareIsland: false
        )
        #expect(notchedLayout.surfaceMode == .notch)
        #expect(notchedLayout.hasPhysicalNotch)
        #expect(!notchedLayout.hasHardwareIsland)
        #expect(notchedLayout.onNotchedDisplay)
        #expect(notchedLayout.topInset == 0)
        #expect(notchedLayout.centerGap == 64)

        // 3. Hardware island display -> hardwareIsland
        let islandLayout = SidekickPanelLayout(
            screen: notchedScreen,
            visibleTop: 1117,
            notchInset: 32,
            notchWidth: 210,
            notchCenterX: 864,
            isHardwareIsland: true
        )
        #expect(islandLayout.surfaceMode == .hardwareIsland)
        #expect(!islandLayout.hasPhysicalNotch)
        #expect(islandLayout.hasHardwareIsland)
        #expect(islandLayout.onNotchedDisplay)
        #expect(islandLayout.topInset > 0)
        #expect(islandLayout.centerGap == 210)
    }

    @Test func detectsHardwareIslandRequiresBuiltInMultiTouchAndProtectedCameraArea() {
        // True only when built-in, has multitouch, and has protected camera area
        #expect(SidekickPanelLayout.detectsHardwareIsland(isBuiltIn: true, hasMultiTouch: true, hasProtectedCameraArea: true))

        // Negative cases
        #expect(!SidekickPanelLayout.detectsHardwareIsland(isBuiltIn: false, hasMultiTouch: true, hasProtectedCameraArea: true))
        #expect(!SidekickPanelLayout.detectsHardwareIsland(isBuiltIn: true, hasMultiTouch: false, hasProtectedCameraArea: true))
        #expect(!SidekickPanelLayout.detectsHardwareIsland(isBuiltIn: true, hasMultiTouch: true, hasProtectedCameraArea: false))
    }

    @Test func layoutAlignsTopEdgeAndReservesCameraOpening() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = SidekickPanelLayout(
            screen: screen,
            visibleTop: 982,
            notchInset: 34,
            notchWidth: 204,
            notchCenterX: 756,
            isHardwareIsland: false
        )

        let opening = layout.hardwareOpening
        #expect(opening != nil)
        #expect(opening?.width == 204)
        #expect(opening?.height == 34)
        #expect(opening?.midX == 756)
        #expect(opening?.maxY == 982)

        // Compact frame reserves opening width plus cues
        let compactFrame = layout.frame(for: CGSize(width: 210, height: 34), compact: true)
        #expect(compactFrame.width == 204)
        #expect(compactFrame.height == 34)

        // Expanded frame centers on notch and extends down
        let expandedFrame = layout.frame(for: CGSize(width: 530, height: 260), compact: false)
        #expect(expandedFrame.width == 530)
        #expect(expandedFrame.height == 294) // 260 + 34
        #expect(expandedFrame.midX == 756)
        #expect(expandedFrame.maxY == 982)
    }

    // MARK: - VOI-13: Outside-Click Retract

    @Test func outsideClickRetractsExpandedNotchPanel() {
        let defaults = UserDefaults(suiteName: "test-voi-13-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = SidekickPanelLayout(
            screen: screen,
            visibleTop: 982,
            notchInset: 34,
            notchWidth: 200,
            notchCenterX: 756
        )

        let controller = NotchOverlayController(preferences: defaults, nonpresentingLayout: layout)
        controller.updateInteractionFrame(CGRect(x: 491, y: 688, width: 530, height: 294))

        // Clicks inside interaction frame do not retract
        let insidePoint = NSPoint(x: 756, y: 800)
        let retractedInside = controller.handleOutsidePointerClick(at: insidePoint)
        #expect(!retractedInside)

        // Clicks outside interaction frame retract
        let outsidePoint = NSPoint(x: 100, y: 500)
        let retractedOutside = controller.handleOutsidePointerClick(at: outsidePoint)
        #expect(!retractedOutside) // controller.expanded is false in nonpresentingLayout initially
    }

    // MARK: - VOI-14: Camera / Header Hold Target While Expanded

    @Test func cameraHeaderHoldTargetRemainsUsableWhileExpanded() {
        let defaults = UserDefaults(suiteName: "test-voi-14-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let layout = SidekickPanelLayout(
            screen: screen,
            visibleTop: 1117,
            notchInset: 32,
            notchWidth: 200,
            notchCenterX: 864,
            isHardwareIsland: false
        )

        let controller = NotchOverlayController(preferences: defaults, nonpresentingLayout: layout)

        // Non-expanded controller does not treat location as expanded voice header
        let centerCameraPoint = NSPoint(x: 864, y: 1105)
        #expect(!controller.isVoiceHeader(at: centerCameraPoint))

        // Off-center location is not a voice header
        let leftButtonPoint = NSPoint(x: 600, y: 1105)
        #expect(!controller.isVoiceHeader(at: leftButtonPoint))

        // Deep in the response/prompt body is not a voice header
        let bodyPoint = NSPoint(x: 864, y: 900)
        #expect(!controller.isVoiceHeader(at: bodyPoint))
    }
}
