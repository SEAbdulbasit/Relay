import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Relay

@Suite("Notch design parity")
@MainActor
struct NotchDesignParityTests {
    @Test func notchShapeFlaresTopConcaveEarsAndSkirtLeavesTopEdgeOpen() {
        let rect = CGRect(x: 0, y: 0, width: 420, height: 180)
        let shape = NotchShape(topCornerRadius: 9, bottomCornerRadius: 18, isIsland: false)
        let skirt = NotchSkirtShape(topCornerRadius: 9, bottomCornerRadius: 18, isIsland: false)

        let shapePath = shape.path(in: rect)
        let skirtPath = skirt.path(in: rect)

        #expect(shapePath.boundingRect.minX == 0)
        #expect(shapePath.boundingRect.maxX == rect.width)
        #expect(shapePath.boundingRect.minY == 0)
        #expect(shapePath.boundingRect.maxY == rect.height)

        // Upper concave bezel ear flares outward to x = 5 at y = 1 (so x = 7 is inside the ear at y = 1),
        // while vertical walls sit inward at topCornerRadius = 9 (so x = 7 is outside at midY).
        #expect(shapePath.contains(CGPoint(x: 7, y: 1)))
        #expect(shapePath.contains(CGPoint(x: rect.maxX - 7, y: 1)))
        #expect(!shapePath.contains(CGPoint(x: 7, y: rect.midY)))
        #expect(!shapePath.contains(CGPoint(x: rect.maxX - 7, y: rect.midY)))
        #expect(shapePath.contains(CGPoint(x: rect.midX, y: rect.maxY - 2)))

        // Open skirt must never close the top bezel seam back to minX.
        var shapeHasCloseSubpath = false
        shapePath.cgPath.applyWithBlock { element in
            if element.pointee.type == .closeSubpath {
                shapeHasCloseSubpath = true
            }
        }
        var skirtHasCloseSubpath = false
        skirtPath.cgPath.applyWithBlock { element in
            if element.pointee.type == .closeSubpath {
                skirtHasCloseSubpath = true
            }
        }
        #expect(shapeHasCloseSubpath)
        #expect(!skirtHasCloseSubpath)
    }

    @Test func islandCapsuleModeAndAnimatableInterpolationBehaveConsistently() {
        let rect = CGRect(x: 0, y: 0, width: 440, height: 160)
        var island = NotchShape(topCornerRadius: 9, bottomCornerRadius: 22, isIsland: true)
        let path = island.path(in: rect)

        #expect(!path.contains(CGPoint(x: 1.5, y: 1.5)))
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))

        island.animatableData = AnimatablePair(12.5, 19.25)
        #expect(island.topCornerRadius == 12.5)
        #expect(island.bottomCornerRadius == 19.25)

        let physicalRadii = sidekickRadii(
            attached: true,
            isHardwareIsland: false,
            expanded: true,
            showsStatus: false,
            size: CGSize(width: 440, height: 180)
        )
        #expect(physicalRadii.top == 9)
        #expect(physicalRadii.bottom == 20)

        let floatingRadii = sidekickRadii(
            attached: false,
            isHardwareIsland: false,
            expanded: true,
            showsStatus: false,
            size: CGSize(width: 440, height: 180)
        )
        #expect(floatingRadii.top == floatingRadii.bottom)
        #expect(floatingRadii.top == 22)
    }

    @Test func primaryHandleAndSecondaryDisplayAcceptTopBezelPointsAndRejectOutside() throws {
        let suite = "RelayTests.NotchDesignParity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let layout = SidekickPanelLayout(
            screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleTop: 945,
            notchInset: 37,
            notchWidth: 186
        )
        let controller = NotchOverlayController(preferences: defaults, nonpresentingLayout: layout)
        let compactFrame = layout.frame(
            for: CGSize(width: 210, height: 37),
            compact: true,
            expandedCue: false,
            showsStatus: false
        )
        controller.updateInteractionFrame(compactFrame)

        // Exact top bezel line (pointer.y == screen.maxY) must be accepted for Fitts's-Law clicking.
        #expect(controller.primaryHandleAcceptsPointer(CGPoint(x: compactFrame.midX, y: layout.screen.maxY)))
        #expect(controller.primaryHandleAcceptsPointer(CGPoint(x: compactFrame.midX, y: compactFrame.minY + 4)))

        // Points outside the horizontal wings or below the notch must be rejected.
        #expect(!controller.primaryHandleAcceptsPointer(CGPoint(x: compactFrame.minX - 24, y: layout.screen.maxY - 6)))
        #expect(!controller.primaryHandleAcceptsPointer(CGPoint(x: compactFrame.midX, y: compactFrame.minY - 12)))

        // Concave lower wall inset rejection when expanded (topCornerRadius = 9).
        controller.open()
        let expandedFrame = layout.frame(
            for: CGSize(width: 430, height: 220),
            compact: false,
            expandedCue: true,
            showsStatus: false
        )
        controller.updateInteractionFrame(expandedFrame)
        #expect(controller.primaryHandleAcceptsPointer(CGPoint(x: expandedFrame.midX, y: layout.screen.maxY)))
        #expect(!controller.primaryHandleAcceptsPointer(CGPoint(x: expandedFrame.minX + 1.5, y: expandedFrame.minY + 24)))

        let descriptor = SidekickDisplayDescriptor(id: 2, name: "Built-in Retina Display", layout: layout)
        let entryFrame = descriptor.entryFrame(for: .idle)
        #expect(descriptor.acceptsPointer(CGPoint(x: entryFrame.midX, y: layout.screen.maxY), for: .idle))
        #expect(!descriptor.acceptsPointer(CGPoint(x: entryFrame.minX - 30, y: entryFrame.midY), for: .idle))
    }

    @Test func compactHardwareStatusLabelsMatchLumenPolish() {
        #expect(SidekickCompactCue.idle.hardwareStatusLabel == "Sidekick")
        #expect(SidekickCompactCue(kind: .resultReady).hardwareStatusLabel == "All set")
    }

    @Test func notchLayoutMetricsGuaranteeEarSafeInnerPaddingAndWingSymmetry() {
        let notchedMetrics = NotchLayoutMetrics(
            attached: true,
            isHardwareIsland: false,
            topCornerRadius: 9,
            notchWidth: 186,
            centerGap: 64,
            frameWidth: 512,
            notchInset: 37
        )
        #expect(notchedMetrics.earInset == 9)
        #expect(notchedMetrics.headerHorizontalPadding == 23)
        #expect(notchedMetrics.bodyHorizontalPadding == 25)
        #expect(notchedMetrics.wingGap == 186)
        #expect(notchedMetrics.wingWidth * 2 + notchedMetrics.wingGap + notchedMetrics.headerHorizontalPadding * 2 == 512)

        let islandMetrics = NotchLayoutMetrics(
            attached: false,
            isHardwareIsland: false,
            topCornerRadius: 22,
            notchWidth: 0,
            centerGap: 0,
            frameWidth: 512,
            notchInset: 0
        )
        #expect(islandMetrics.earInset == 0)
        #expect(islandMetrics.headerHorizontalPadding == 14)
        #expect(islandMetrics.bodyHorizontalPadding == 16)
        #expect(islandMetrics.wingGap == 0)
        #expect(islandMetrics.wingWidth == 0)
    }

    @Test func expandedPresentationSizesStayWithinCanvasAndLeaveComposerHeadroom() throws {
        let suite = "RelayTests.NotchDesignParity.Sizes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let notchedLayout = SidekickPanelLayout(
            screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleTop: 945,
            notchInset: 37,
            notchWidth: 186
        )
        let store = AssistantStore(persistenceURL: nil)
        let notchedController = NotchOverlayController(preferences: defaults, nonpresentingLayout: notchedLayout)
        notchedController.connect(store: store, available: true, openWorkspace: {})
        notchedController.open()

        let composeNotched = notchedController.presentationContentSize(for: store)
        #expect(composeNotched.width <= 530)
        #expect(composeNotched.height >= 136)
        #expect(composeNotched.height <= 420)
        let expandedNotchedFrame = notchedLayout.frame(for: composeNotched, compact: false)
        #expect(notchedLayout.canvas(containing: expandedNotchedFrame).contains(expandedNotchedFrame))

        let islandLayout = SidekickPanelLayout(
            screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleTop: 1052,
            notchInset: 0,
            notchWidth: 0
        )
        let islandController = NotchOverlayController(preferences: defaults, nonpresentingLayout: islandLayout)
        islandController.connect(store: store, available: true, openWorkspace: {})
        islandController.open()

        let composeIsland = islandController.presentationContentSize(for: store)
        #expect(composeIsland.width <= 530)
        #expect(composeIsland.height >= 172)
        #expect(composeIsland.height <= 420)
        let expandedIslandFrame = islandLayout.frame(for: composeIsland, compact: false)
        #expect(islandLayout.canvas(containing: expandedIslandFrame).contains(expandedIslandFrame))
    }

    @Test func unifiedObsidianDesignSystemTokensAreConsistent() throws {
        #expect(RelaySpace.xxs < RelaySpace.xs)
        #expect(RelaySpace.xs < RelaySpace.sm)
        #expect(RelaySpace.sm < RelaySpace.md)
        #expect(RelaySpace.md < RelaySpace.lg)
        #expect(RelaySpace.lg < RelaySpace.xl)
        #expect(RelayControlHeight.compact < RelayControlHeight.pill)
        #expect(RelayControlHeight.pill < RelayControlHeight.bar)
        #expect(RelayControlHeight.bar < RelayControlHeight.composer)
        #expect(RelayControlHeight.composer < RelayControlHeight.header)

        func luminance(_ color: Color) throws -> CGFloat {
            let nsColor = try #require(NSColor(color).usingColorSpace(.sRGB))
            return 0.2126 * nsColor.redComponent + 0.7152 * nsColor.greenComponent + 0.0722 * nsColor.blueComponent
        }

        let pitchL = try luminance(RelayColors.pitch)
        let canvasL = try luminance(RelayColors.canvas)
        let cardL = try luminance(RelayColors.cardBG)
        let surfaceL = try luminance(RelayColors.surface)
        let elevatedL = try luminance(RelayColors.surfaceElevated)
        let textL = try luminance(RelayColors.textPrimary)

        #expect(pitchL < canvasL)
        #expect(canvasL < cardL)
        #expect(cardL < surfaceL)
        #expect(surfaceL < elevatedL)
        #expect(elevatedL < textL)
    }

    @Test func relayBrandGlyphMenuBarAndAppIconAreValid() throws {
        let glyphFrame = CGRect(x: 36, y: 43, width: 28, height: 6)
        let glyphBounds = RelayShortcutGlyph().path(in: glyphFrame).boundingRect
        #expect(glyphBounds == glyphFrame)

        let idleMenuBarIcon = RelayBrandMenuBarIcon.image(active: false)
        let activeMenuBarIcon = RelayBrandMenuBarIcon.image(active: true)
        #expect(idleMenuBarIcon.isTemplate == true)
        #expect(activeMenuBarIcon.isTemplate == true)
        #expect(idleMenuBarIcon.size == NSSize(width: 18, height: 18))
        #expect(activeMenuBarIcon.size == NSSize(width: 18, height: 18))

        let icnsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Relay.icns")
        let icnsData = try Data(contentsOf: icnsURL)
        #expect(icnsData.count > 20_000)
        #expect(String(data: icnsData.prefix(4), encoding: .ascii) == "icns")
        let loadedIcon = try #require(NSImage(contentsOf: icnsURL))
        #expect(loadedIcon.isValid)
        #expect(loadedIcon.size.width >= 128 && loadedIcon.size.height >= 128)
    }

    @Test func idleNotchHoverUsesCleanSymmetricalSwellWithoutOffCenterDot() throws {
        let suite = "RelayTests.NotchDesignParity.HoverClean.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let layout = SidekickPanelLayout(
            screen: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
            visibleTop: 1_130,
            notchInset: 38,
            notchWidth: 220,
            notchCenterX: 900
        )
        let compactIdleFrame = layout.frame(
            for: CGSize(width: 220, height: 38),
            compact: true,
            expandedCue: false,
            showsStatus: false
        )
        #expect(compactIdleFrame == layout.hardwareOpening)
        #expect(compactIdleFrame.width == 220)
        #expect(compactIdleFrame.height == 38)
        #expect(compactIdleFrame.midX == 900)
        #expect(compactIdleFrame.maxY == 1_169)

        let compactHoveredFrame = layout.frame(
            for: CGSize(width: 220, height: 38),
            compact: true,
            expandedCue: true,
            showsStatus: false
        )
        #expect(compactHoveredFrame.midX == 900)
        #expect(compactHoveredFrame.width == 244)
        #expect(compactHoveredFrame.height == 43)
        #expect(compactHoveredFrame.maxY == 1_169)

        let store = AssistantStore(persistenceURL: nil)
        let controller = NotchOverlayController(preferences: defaults, nonpresentingLayout: layout)
        controller.connect(store: store, available: true, openWorkspace: {})
        controller.setHoveringNotchForTesting(true)

        let canvas = layout.canvas(containing: compactHoveredFrame)
        let renderer = ImageRenderer(content: NotchOverlayBar(store: store, controller: controller))
        renderer.scale = 1.0
        renderer.proposedSize = .init(canvas.size)
        let cgImage = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        #expect(bitmap.pixelsWide == Int(canvas.width))
        #expect(bitmap.pixelsHigh == Int(canvas.height))

        var opaqueBlackPixels = 0
        let width = bitmap.pixelsWide
        let midX = width / 2
        for y in 0..<min(bitmap.pixelsHigh, 80) {
            for x in 0..<width {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.alphaComponent > 0.05 {
                    let chroma = max(color.redComponent, max(color.greenComponent, color.blueComponent))
                        - min(color.redComponent, min(color.greenComponent, color.blueComponent))
                    #expect(chroma <= 0.04, "Found unexpected chromatic pixel at (\(x), \(y)): \(color)")
                }
                if color.alphaComponent > 0.95 && color.redComponent < 0.05 {
                    opaqueBlackPixels += 1
                }
            }
        }
        #expect(opaqueBlackPixels >= 8_000)

        for y in 0..<56 {
            for dx in 0..<150 {
                let leftColor = try #require(bitmap.colorAt(x: midX - 1 - dx, y: y)?.usingColorSpace(.sRGB))
                let rightColor = try #require(bitmap.colorAt(x: midX + dx, y: y)?.usingColorSpace(.sRGB))
                #expect(
                    abs(leftColor.alphaComponent - rightColor.alphaComponent) <= 0.05,
                    "Alpha asymmetry at y=\(y), dx=\(dx): left=\(leftColor.alphaComponent) right=\(rightColor.alphaComponent)"
                )
                #expect(
                    abs(leftColor.redComponent - rightColor.redComponent) <= 0.05,
                    "Brightness asymmetry at y=\(y), dx=\(dx)"
                )
            }
        }
        #expect(controller.hoveringNotch)
    }

    @Test func expandedNotchNeverRendersPixelsBelowNotchOutline() async throws {
        let suite = "RelayTests.NotchDesignParity.NoOverflow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-notch-overflow-" + UUID().uuidString)
        let stateURL = root.appendingPathComponent("state.json")
        let source = ChatMessage(role: "assistant", text: "Which browser or app is the video playing in?")
        var history = AssistantConversationHistory(stateURL: stateURL)
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        try history.stage(source, run: run, grants: [])
        _ = try await history.flush()
        try await history.finish(run, outcome: .responseDelivered)
        try await history.close()
        history = AssistantConversationHistory(stateURL: stateURL)

        let layout = SidekickPanelLayout(
            screen: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
            visibleTop: 1_130,
            notchInset: 38,
            notchWidth: 220,
            notchCenterX: 900
        )
        let store = AssistantStore(persistenceURL: stateURL, conversationHistory: history)
        await store.waitForConversationTaskToSettle()
        let controller = NotchOverlayController(preferences: defaults, nonpresentingLayout: layout)
        controller.connect(store: store, available: true, openWorkspace: {})
        controller.open()

        let emptySize = controller.presentationContentSize(for: store)

        controller.promptText = "Line 1\nLine 2\nLine 3"
        let multilineSize = controller.presentationContentSize(for: store)
        #expect(multilineSize.height > emptySize.height)

        controller.promptText = ""
        controller.setErrorMessageForTesting("Choose a workspace model in Relay before sending a task.")
        let errorSize = controller.presentationContentSize(for: store)
        #expect(errorSize.height > emptySize.height)
        controller.setErrorMessageForTesting(nil)

        func verifyNoOverflowAndOpaqueBlackInterior(label: String) throws {
            let contentSize = controller.presentationContentSize(for: store)
            let frame = layout.frame(for: contentSize, compact: false)
            let canvas = layout.canvas(containing: frame)
            let renderer = ImageRenderer(content: NotchOverlayBar(store: store, controller: controller))
            renderer.scale = 1.0
            renderer.proposedSize = .init(canvas.size)
            let cgImage = try #require(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            #expect(bitmap.pixelsWide == Int(canvas.width))
            #expect(bitmap.pixelsHigh == Int(canvas.height))

            // Physical notch interior (top-band center and lower body margins) must remain deep opaque obsidian.
            let interiorColor = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20)?.usingColorSpace(.sRGB))
            #expect(interiorColor.alphaComponent > 0.98, "\(label): expected opaque top notch interior")

            let lowerBodyColor = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(frame.height) - 6)?.usingColorSpace(.sRGB))
            #expect(lowerBodyColor.alphaComponent > 0.98, "\(label): expected opaque lower notch shell")

            // Zero bright text or chromatic pixels may ever bleed below frame.height.
            let startY = Int(ceil(frame.height)) + 1
            for y in startY..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.alphaComponent > 0.05 {
                        #expect(
                            color.redComponent <= 0.15 && color.greenComponent <= 0.15 && color.blueComponent <= 0.15,
                            "\(label): found non-shadow pixel below notch box at (\(x), \(y)) vs frameHeight=\(frame.height): \(color)"
                        )
                    }
                }
            }
        }

        controller.promptText = ""
        controller.setErrorMessageForTesting(nil)
        try verifyNoOverflowAndOpaqueBlackInterior(label: "empty-compose")

        controller.promptText = "Line 1\nLine 2\nLine 3"
        try verifyNoOverflowAndOpaqueBlackInterior(label: "multiline-compose")

        let replyPrepared = await store.prepareConversationReply(to: source.id)
        #expect(replyPrepared)
        let replySize = controller.presentationContentSize(for: store)
        #expect(replySize.height >= multilineSize.height + 70)
        try verifyNoOverflowAndOpaqueBlackInterior(label: "pending-reply-multiline-compose")

        controller.setErrorMessageForTesting("Choose a workspace model in Relay before sending a task.")
        try verifyNoOverflowAndOpaqueBlackInterior(label: "pending-reply-multiline-error-compose")

        try? await history.close()
        try? FileManager.default.removeItem(at: root)
    }

    @Test func conversationalQueriesDoNotAttachActiveWorkWindowWhenIncludesCurrentAppIsFalse() async throws {
        let suite = "RelayTests.NotchDesignParity.WorkWindow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AssistantStore.isConversationalCapabilityQuery("what can you do"))
        #expect(AssistantStore.isConversationalCapabilityQuery("What can you do?"))
        #expect(AssistantStore.isConversationalCapabilityQuery("how can you help me"))
        #expect(!AssistantStore.isConversationalCapabilityQuery("Summarize the current tab in Chrome"))

        // Never attach activeWorkWindow when includesCurrentApp == false
        #expect(!NotchOverlayController.shouldAttachWorkWindow(for: "what can you do", includesCurrentApp: false))
        #expect(!NotchOverlayController.shouldAttachWorkWindow(for: "Summarize this page", includesCurrentApp: false))

        // Conversational capability prompts never attach activeWorkWindow even if includesCurrentApp is true
        #expect(!NotchOverlayController.shouldAttachWorkWindow(for: "what can you do", includesCurrentApp: true))
        #expect(NotchOverlayController.shouldAttachWorkWindow(for: "Summarize this page", includesCurrentApp: true))

        let layout = SidekickPanelLayout(
            screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleTop: 945,
            notchInset: 37,
            notchWidth: 186
        )
        let store = AssistantStore(persistenceURL: nil, codexComplete: { _, _ in
            ModelReply(content: "I can help you summarize pages, draft replies, and automate tasks.", toolCalls: [])
        }, codexCheck: {})
        await store.selectWorkspaceCodex()
        let controller = NotchOverlayController(preferences: defaults, nonpresentingLayout: layout)
        controller.connect(store: store, available: true, openWorkspace: {})
        controller.open()

        controller.setCurrentAppForTesting(NSRunningApplication.current)
        controller.setActiveWorkWindowForTesting(
            SidekickWorkWindow(
                pid: ProcessInfo.processInfo.processIdentifier,
                bundleIdentifier: "com.google.antigravity",
                appName: "Antigravity",
                launchDate: nil,
                windowTitle: "Relay",
                axWindow: nil
            )
        )
        controller.includesCurrentApp = false
        controller.promptText = "what can you do"
        controller.submit(store: store)

        #expect(controller.activeWorkWindow == nil)
        await store.waitForConversationTaskToSettle()
    }

    @Test func relayAppearanceModeAndAdaptiveColorsAndResponsiveContentWidthWorkProperly() throws {
        let previousRaw = UserDefaults.standard.string(forKey: RelayAppearanceMode.storageKey)
        defer {
            if let previousRaw {
                UserDefaults.standard.set(previousRaw, forKey: RelayAppearanceMode.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RelayAppearanceMode.storageKey)
            }
        }

        // Reading and composition remain bounded inside the wider workbench.
        #expect(RelayTheme.contentWidth >= 1000)
        #expect(RelayTheme.readingMaxWidth > 0)
        #expect(RelayTheme.readingMaxWidth < RelayTheme.contentWidth)
        #expect(RelayTheme.composerMaxWidth >= RelayTheme.readingMaxWidth)
        #expect(RelayTheme.composerMaxWidth <= RelayTheme.contentWidth)
        #expect(RelayTheme.wideContentWidth >= RelayTheme.contentWidth)

        // RelayAppearanceMode cases & metadata
        #expect(RelayAppearanceMode.allCases == [.dark, .light, .system])
        #expect(RelayAppearanceMode.dark.displayName == "Night")
        #expect(RelayAppearanceMode.light.displayName == "Light")
        #expect(RelayAppearanceMode.system.displayName == "System")
        #expect(RelayAppearanceMode.dark.colorScheme == .dark)
        #expect(RelayAppearanceMode.light.colorScheme == .light)
        #expect(RelayAppearanceMode.system.colorScheme == nil)
        #expect(RelayAppearanceMode.fromStored("night") == .dark)
        #expect(RelayAppearanceMode.fromStored("light") == .light)
        #expect(RelayAppearanceMode.fromStored("system") == .system)

        func luminance(_ nsColor: NSColor) throws -> CGFloat {
            let srgb = try #require(nsColor.usingColorSpace(.sRGB))
            return 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
        }

        // Dark mode adaptive resolved colors (Upgraded Antigravity Slate & Graphite palette)
        let darkPitch = try luminance(RelayColors.resolvedNSColor(RelayColors.pitch, for: .dark))
        let darkCanvas = try luminance(RelayColors.resolvedNSColor(RelayColors.canvas, for: .dark))
        let darkCard = try luminance(RelayColors.resolvedNSColor(RelayColors.cardBG, for: .dark))
        let darkSurface = try luminance(RelayColors.resolvedNSColor(RelayColors.surface, for: .dark))
        let darkSurfaceElevated = try luminance(RelayColors.resolvedNSColor(RelayColors.surfaceElevated, for: .dark))
        let darkText = try luminance(RelayColors.resolvedNSColor(RelayColors.textPrimary, for: .dark))
        #expect(darkCanvas > 0.06, "Dark mode canvas should be Slate (#161A22), not pitch black")
        #expect(darkPitch < darkCanvas)
        #expect(darkCanvas < darkCard)
        #expect(darkCard < darkSurface)
        #expect(darkSurface < darkSurfaceElevated)
        #expect(darkSurfaceElevated < darkText)
        #expect(darkText > 0.85)

        // Light mode adaptive resolved colors
        let lightPitch = try luminance(RelayColors.resolvedNSColor(RelayColors.pitch, for: .light))
        let lightCard = try luminance(RelayColors.resolvedNSColor(RelayColors.cardBG, for: .light))
        let lightText = try luminance(RelayColors.resolvedNSColor(RelayColors.textPrimary, for: .light))
        #expect(lightPitch > 0.88)
        #expect(lightCard >= lightPitch)
        #expect(lightText < 0.15)
    }

    @Test func multiThreadConversationHistoryPersistenceAndLeftSidebarArchiveWorkCleanly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "relay-thread-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let persistenceURL = root.appending(path: "history.sqlite")
        let store = AssistantStore(persistenceURL: persistenceURL)

        let firstUser = ChatMessage(role: "user", text: "Summarize my week in Calendar", date: Date(timeIntervalSinceNow: -3600))
        let firstAssistant = ChatMessage(role: "assistant", text: "You have 4 product design reviews and 2 engineering syncs.", date: Date(timeIntervalSinceNow: -3580))
        store.messages = [firstUser, firstAssistant]
        let firstThreadID = store.activeThreadID

        #expect(store.threadArchive.threads.count == 1)
        #expect(store.threadArchive.threads.first?.id == firstThreadID)
        #expect(store.threadArchive.threads.first?.title == "Summarize my week in Calendar")

        // Starting a new thread preserves the first thread in the archive and resets active messages
        store.startNewThread()
        await store.waitForConversationTaskToSettle()
        #expect(store.messages.isEmpty)
        #expect(store.activeThreadID != firstThreadID)
        #expect(store.threadArchive.threads.contains(where: { $0.id == firstThreadID }))

        // Populate a second thread
        let secondUser = ChatMessage(role: "user", text: "Draft a release note for Relay 2.0", date: Date())
        let secondAssistant = ChatMessage(role: "assistant", text: "Relay 2.0 introduces the Antigravity Slate theme and Left Sidebar history.", date: Date())
        store.messages = [secondUser, secondAssistant]
        let secondThreadID = store.activeThreadID

        #expect(store.threadArchive.threads.count == 2)

        // Switching back to the first thread restores its messages into the workspace
        let switched = store.selectThread(firstThreadID)
        #expect(switched)
        #expect(store.activeThreadID == firstThreadID)
        #expect(store.messages.map(\.text) == ["Summarize my week in Calendar", "You have 4 product design reviews and 2 engineering syncs."])

        // Verify disk persistence of WorkspaceThreadArchive
        let reloadedArchive = WorkspaceThreadArchive(storageURL: store.threadArchive.storageURL)
        #expect(reloadedArchive.threads.count == 2)
        #expect(reloadedArchive.thread(for: firstThreadID)?.title == "Summarize my week in Calendar")
        #expect(reloadedArchive.thread(for: secondThreadID)?.title == "Draft a release note for Relay 2.0")

        // Deleting the active thread switches to the remaining thread
        store.deleteThread(firstThreadID)
        #expect(store.threadArchive.threads.count == 1)
        #expect(store.activeThreadID == secondThreadID)
        #expect(store.messages.first?.text == "Draft a release note for Relay 2.0")

        // Clearing thread history empties the archive
        store.clearThreadHistory()
        await store.waitForConversationTaskToSettle()
        #expect(store.threadArchive.threads.isEmpty)
    }

    @Test func inlineWindowOrImageAttachmentSubmitsDirectlyInWorkspaceMessagesAndActivityWithoutModalSheet() async throws {
        var capturedMessages: [ModelMessage] = []
        let store = AssistantStore(persistenceURL: nil, complete: { messages, _, _ in
            capturedMessages = messages
            return ModelReply(content: "Inspected the Safari Product Spec window directly in the conversation and activity stream.", toolCalls: [])
        })

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: 96,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 96 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        let cgImage = try #require(context.makeImage())
        let attachedImage = try InspectionImage.encode(cgImage, label: "Window: Safari — Product Spec")

        store.imageInspection.attachImage(attachedImage)
        store.showImageInspection = true
        #expect(store.imageInspection.image?.label == "Window: Safari — Product Spec")
        #expect(!store.isForegroundInteractionBusy)

        // Submitting with empty draft auto-fills the inspection prompt, consumes the attachment,
        // closes the inline picker state without any modal sheet, and streams into messages + activity.
        store.draft = ""
        let submission = store.submitComposerMessage()
        #expect(submission != nil)
        #expect(store.imageInspection.image == nil)
        #expect(store.showImageInspection == false)
        #expect(store.showActivity == true)

        await store.waitForConversationTaskToSettle()

        #expect(store.messages.count == 2)
        #expect(store.messages.first?.role == "user")
        #expect(store.messages.first?.text.contains("window: safari — product spec") == true)
        #expect(store.messages.last?.role == "assistant")
        #expect(store.messages.last?.text.contains("Inspected the Safari Product Spec window directly") == true)

        #expect(store.activity.contains(where: { $0.name == "Inspecting Window: Safari — Product Spec" }))
        #expect(store.activity.contains(where: { $0.name == "Inspected Window: Safari — Product Spec" && $0.status == "verified" }))
        #expect(capturedMessages.contains(where: { $0.content.contains("Reviewed window description") && $0.content.contains("Window: Safari — Product Spec") }))

        // Attach a follow-up window target so the inline visual context bar in MainView.composer
        // is rendered alongside the live conversation and Activity sidebar with all controls enabled.
        store.actionsReady = true
        let followUpImage = try InspectionImage.encode(cgImage, label: "Window: Safari — Product Spec (Q4 SLA Table)")
        store.imageInspection.attachImage(followUpImage)
        store.draft = "Compare the API latency budget in this window against our Q4 SLA targets."
        store.showActivity = true

        let windowSize = CGSize(width: 1380, height: 860)
        let hosting = NSHostingView(
            rootView: MainView(store: store)
                .frame(width: windowSize.width, height: windowSize.height)
                .environment(\.colorScheme, .dark)
        )
        hosting.frame = CGRect(origin: .zero, size: windowSize)
        let previewWindow = NSWindow(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        previewWindow.appearance = NSAppearance(named: .darkAqua)
        previewWindow.contentView = hosting
        previewWindow.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        previewWindow.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        if let bitmapRep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmapRep)
            if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                let screenshotURL = URL(fileURLWithPath: "/Users/abdulbasit/.gemini/antigravity/brain/3f21399f-0692-4150-8aac-c7acd7e76650/scratch/relay_v4_inline_inspect.png")
                try? FileManager.default.createDirectory(at: screenshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? pngData.write(to: screenshotURL)
            }
        }

        // Also render History sidebar in Dark Mode to verify the redesigned
        // chronological thread rows, vertical turn timeline, Antigravity response card, and inline visual target bar.
        store.showActivity = false
        let historyHostingDark = NSHostingView(
            rootView: MainView(store: store)
                .frame(width: windowSize.width, height: windowSize.height)
                .environment(\.colorScheme, .dark)
        )
        historyHostingDark.frame = CGRect(origin: .zero, size: windowSize)
        previewWindow.appearance = NSAppearance(named: .darkAqua)
        previewWindow.contentView = historyHostingDark
        previewWindow.displayIfNeeded()
        historyHostingDark.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        previewWindow.displayIfNeeded()
        historyHostingDark.layoutSubtreeIfNeeded()

        if let bitmapRep = historyHostingDark.bitmapImageRepForCachingDisplay(in: historyHostingDark.bounds) {
            historyHostingDark.cacheDisplay(in: historyHostingDark.bounds, to: bitmapRep)
            if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                let transcriptDarkURL = URL(fileURLWithPath: "/Users/abdulbasit/.gemini/antigravity/brain/3f21399f-0692-4150-8aac-c7acd7e76650/scratch/relay_v5_transcript_dark.png")
                try? pngData.write(to: transcriptDarkURL)
            }
        }

        // Now start a new thread to render the 2x2 1-Click Welcome Screen in both Dark Mode and Light Mode
        store.clearAttachedInspectionImage()
        store.draft = ""
        store.startNewThread()
        await store.waitForConversationTaskToSettle()

        let welcomeHostingDark = NSHostingView(
            rootView: MainView(store: store)
                .frame(width: windowSize.width, height: windowSize.height)
                .environment(\.colorScheme, .dark)
        )
        welcomeHostingDark.frame = CGRect(origin: .zero, size: windowSize)
        previewWindow.appearance = NSAppearance(named: .darkAqua)
        previewWindow.contentView = welcomeHostingDark
        previewWindow.displayIfNeeded()
        welcomeHostingDark.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        previewWindow.displayIfNeeded()
        welcomeHostingDark.layoutSubtreeIfNeeded()

        if let bitmapRep = welcomeHostingDark.bitmapImageRepForCachingDisplay(in: welcomeHostingDark.bounds) {
            welcomeHostingDark.cacheDisplay(in: welcomeHostingDark.bounds, to: bitmapRep)
            if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                let welcomeDarkURL = URL(fileURLWithPath: "/Users/abdulbasit/.gemini/antigravity/brain/3f21399f-0692-4150-8aac-c7acd7e76650/scratch/relay_v5_welcome_dark.png")
                try? pngData.write(to: welcomeDarkURL)
            }
        }

        UserDefaults.standard.set(RelayAppearanceMode.light.rawValue, forKey: RelayAppearanceMode.storageKey)
        defer { UserDefaults.standard.set(RelayAppearanceMode.dark.rawValue, forKey: RelayAppearanceMode.storageKey) }
        let welcomeHostingLight = NSHostingView(
            rootView: MainView(store: store)
                .frame(width: windowSize.width, height: windowSize.height)
                .environment(\.colorScheme, .light)
        )
        welcomeHostingLight.frame = CGRect(origin: .zero, size: windowSize)
        previewWindow.appearance = NSAppearance(named: .aqua)
        previewWindow.contentView = welcomeHostingLight
        previewWindow.displayIfNeeded()
        welcomeHostingLight.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        previewWindow.displayIfNeeded()
        welcomeHostingLight.layoutSubtreeIfNeeded()

        if let bitmapRep = welcomeHostingLight.bitmapImageRepForCachingDisplay(in: welcomeHostingLight.bounds) {
            welcomeHostingLight.cacheDisplay(in: welcomeHostingLight.bounds, to: bitmapRep)
            if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                let welcomeLightURL = URL(fileURLWithPath: "/Users/abdulbasit/.gemini/antigravity/brain/3f21399f-0692-4150-8aac-c7acd7e76650/scratch/relay_v5_welcome_light.png")
                try? pngData.write(to: welcomeLightURL)
            }
        }
    }
}
