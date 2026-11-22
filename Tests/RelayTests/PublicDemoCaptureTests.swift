import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Relay

/// Opt-in, offscreen exports. Never constructs AssistantStore, reads a vault,
/// opens an account, captures the desktop, or invokes a tool/model.
@MainActor
struct PublicDemoCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RENDER_PUBLIC_DEMOS"] == "1"))
    func exportFictionalComponentWalkthroughs() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RELAY_PUBLIC_DEMO_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousAppearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        defer { NSApplication.shared.appearance = previousAppearance }

        let replies = ["", "Thursday at 2 PM works for me. I’ll bring the sample launch checklist so we can review it together.",
                       "Thursday at 2 works. I’ll bring the sample checklist."]
        var replyFrames: [CGImage] = []
        for index in replies.indices {
            let content = PublicDemoFrame(title: "Magic Reply", step: ["Choose a context", "Review the unsent reply", "Try a shorter tone"][index]) {
                MagicReplyPracticeCard(
                    shortcutTitle: "Right Command", senderName: "Avery · fictional teammate",
                    incomingText: "Can we review the sample Project Maple launch checklist on Thursday at 2 PM?",
                    selectedApp: "Sample Mail", appChoices: ["Sample Mail"],
                    selectedTone: index == 2 ? "Shorter" : "Your Voice", toneChoices: ["Your Voice", "Shorter"],
                    stage: index == 0 ? .waitingForTrigger : .drafted, reply: replies[index],
                    onSelectApp: { _ in }, onSelectTone: { _ in }, onTry: {}, onReset: {}
                )
            }
            replyFrames.append(try render(content))
        }
        try export(replyFrames, durations: [2, 3, 3], poster: 1, name: "magic-reply-fictional", to: directory)

        var planFrames: [CGImage] = []
        for concise in [false, true] {
            let plan = ProactiveArtifact.ActionPlanDraft(
                targetAppOrSite: "Project Maple · fictional workspace",
                goal: concise ? "Prepare a short checklist for review." : "Prepare the fictional Project Maple launch review.",
                steps: concise ? ["Review the sample design notes.", "Draft a short team update for review."]
                    : ["Review the sample design notes.", "Check the fictional release checklist.", "Draft a short team update for review."],
                notes: "Illustrative sample only. No live sources or external actions."
            )
            let card = ProactivePreparedCard(
                id: "public-fictional-maple", title: "Review a sample launch plan",
                whyNow: "A fictional project review is coming up. Review the suggested steps before taking action.",
                artifact: .actionPlan(plan), sourceIDs: [], sourceTitles: ["Fictional sample brief"],
                verificationStatus: .unverified, verificationDetail: "No live sources are connected in this preview.",
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
            )
            planFrames.append(try render(PublicDemoFrame(title: "Morning Brief", step: concise ? "A shorter plan after review" : "Read the suggested plan") {
                ProactiveMorningCardView(card: card, isStoreBusy: false, canLaunch: false,
                    onUpdate: { _, _ in }, onSnooze: { _ in }, onDismiss: {}, onLaunch: {})
                    .padding(20).relayPagePanel()
            }))
        }
        try export(planFrames, durations: [4, 4], poster: 0, name: "morning-brief-fictional", to: directory)
    }

    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 1.4
        renderer.isOpaque = true
        let result = try #require(renderer.cgImage)
        #expect(result.width == 1260 && result.height == 868)
        return result
    }

    private func export(_ frames: [CGImage], durations: [Double], poster: Int, name: String, to directory: URL) throws {
        let gifURL = directory.appendingPathComponent(name + ".gif")
        let destination = try #require(CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (frame, duration) in zip(frames, durations) {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == frames.count)
        let posterData = try #require(NSBitmapImageRep(cgImage: frames[poster]).representation(using: .png, properties: [:]))
        try posterData.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

private struct PublicDemoFrame<Content: View>: View {
    let title: String
    let step: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                RelayMark(size: 24)
                Text("Relay").font(RelayPageStyle.sectionTitle)
                Spacer()
                Text("Fictional UI preview").font(RelayPageStyle.caption).foregroundStyle(RelayColors.textSecondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(RelayPageStyle.title)
                Spacer()
                Text(step).font(RelayPageStyle.body).foregroundStyle(RelayColors.textSecondary)
            }
            content()
            Spacer(minLength: 0)
            Text("Illustrative UI states · sample data only · no live AI, account, or task execution")
                .font(RelayPageStyle.caption).foregroundStyle(RelayColors.textSecondary)
        }
        .padding(28)
        .frame(width: 900, height: 620)
        .foregroundStyle(RelayColors.textPrimary)
        .background(RelayColors.canvas)
    }
}
