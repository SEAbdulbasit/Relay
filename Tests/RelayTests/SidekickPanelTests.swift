import Foundation
import Testing
@testable import Relay

@MainActor
struct SidekickPanelTests {
    @Test func hardwareSurfaceRetractsIntoTheCutoutAndExpandsFromTheSameBezel() {
        let frame = CGRect(x: -1_440, y: 180, width: 1_440, height: 900)
        let notch = SidekickPanelLayout(screen: frame, visibleTop: 1_050, notchInset: 32, notchWidth: 230, notchCenterX: -710)
        let compact = notch.frame(for: CGSize(width: 210, height: 34), compact: true)
        #expect(compact == notch.hardwareOpening)
        #expect(compact.midX == -710)
        #expect(compact.maxY == frame.maxY)
        #expect(compact.minY == frame.maxY - 32)
        #expect(compact.width == 230)
        let hovered = notch.frame(for: CGSize(width: 210, height: 34), compact: true, expandedCue: true)
        #expect(hovered.contains(compact))
        #expect(hovered.height == compact.height + 5)
        let status = notch.frame(for: CGSize(width: 210, height: 34), compact: true, expandedCue: true, showsStatus: true)
        #expect(status.contains(hovered))
        #expect(status.midX == compact.midX)
        #expect(status.maxY == compact.maxY)
        #expect(status.width == compact.width + 180)
        let expanded = notch.frame(for: CGSize(width: 530, height: 256), compact: false)
        #expect(expanded.maxY == compact.maxY)
        #expect(expanded.width == 530)
        #expect(expanded.height - notch.notchInset == 256)
        #expect(notch.canvas.contains(expanded))
    }

    @Test func externalDisplayPanelStaysBelowItsMenuBar() {
        let frame = CGRect(x: -1_440, y: 180, width: 1_440, height: 900)
        let external = SidekickPanelLayout(screen: frame, visibleTop: 1_050, notchInset: 0, notchWidth: 0)
        let compact = external.frame(for: CGSize(width: 210, height: 34), compact: true)
        #expect(external.hardwareOpening == nil)
        #expect(compact.maxY == 1_046)
        #expect(compact.height == 34)
        #expect(compact.midX == frame.midX)
    }

    @Test func sidekickUsesTheVisibleProviderAndPreservesTheWorkspaceDraft() async throws {
        var hostedCalls = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            Issue.record("Sidekick used the local model while ChatGPT was selected.")
            throw RelayError.message("Unexpected local inference")
        }, codexComplete: { _, _ in
            hostedCalls += 1
            return ModelReply(content: "Sidekick fixture result", toolCalls: [])
        }, codexCheck: {})
        await store.selectWorkspaceCodex()
        store.draft = "Keep this independent draft."
        let controller = NotchOverlayController()
        controller.promptText = "Sidekick fixture request"
        controller.submit(store: store)
        #expect(store.draft == "Keep this independent draft.")
        let submission = try #require(controller.pendingSubmission)
        #expect(await submission.waitForAcknowledgment() == .saved)
        await Task.yield()
        #expect(controller.promptText.isEmpty)
        #expect(controller.submittedMessageID == submission.messageID)
        #expect(store.messages.first(where: { $0.id == submission.messageID })?.text == "Sidekick fixture request")

        await store.waitForConversationTaskToSettle()
        #expect(hostedCalls == 1)
        #expect(controller.latestResult(in: store.messages)?.text.contains("Sidekick fixture result") == true)
        controller.clearResult()
        #expect(controller.latestResult(in: store.messages) == nil)
    }

    @Test func unavailableModelKeepsTheSidekickDraftForRetry() {
        let store = AssistantStore(persistenceURL: nil)
        store.draft = "Keep the workspace draft."
        let controller = NotchOverlayController()
        controller.promptText = "Keep the Sidekick task."
        controller.submit(store: store)
        #expect(controller.promptText == "Keep the Sidekick task.")
        #expect(store.draft == "Keep the workspace draft.")
        #expect(store.messages.isEmpty)
        #expect(controller.errorMessage?.contains("Choose a workspace model") == true)
    }

    @Test func currentAppAndPreferencesOnlyReachTheSelectedLocalSidekickRun() async throws {
        let context = try #require(SidekickTaskContext(appID: "example.fixture.notes", instructions: "Use the notes fixture."))
        var localPrompts: [String] = []
        var hostedPrompts: [String] = []
        let store = AssistantStore(persistenceURL: nil, complete: { messages, _, _ in
            localPrompts.append(messages.map(\.content).joined(separator: "\n"))
            return ModelReply(content: "Fixture answer.", toolCalls: [])
        }, codexComplete: { messages, _ in
            hostedPrompts.append(messages.map(\.content).joined(separator: "\n"))
            return ModelReply(content: "Hosted fixture answer.", toolCalls: [])
        }, codexCheck: {})

        store.draft = "Read this window."
        store.send(useWorkspaceProvider: true, sidekickContext: context)
        try await waitForRun(store)
        let local = try #require(localPrompts.first)
        #expect(local.contains("example.fixture.notes"))
        #expect(local.contains("Use the notes fixture."))
        #expect(local.contains("observe_app before acting"))
        #expect(store.messages.first?.text == "Read this window.")

        store.draft = "A new local task."
        store.send()
        try await waitForRun(store)
        let next = try #require(localPrompts.last)
        #expect(!next.contains("example.fixture.notes"))
        #expect(!next.contains("Use the notes fixture."))

        await store.selectWorkspaceCodex()
        store.draft = "A hosted task."
        store.send(useWorkspaceProvider: true, sidekickContext: context)
        try await waitForRun(store)
        let hosted = try #require(hostedPrompts.first)
        #expect(!hosted.contains("example.fixture.notes"))
        #expect(!hosted.contains("Use the notes fixture."))
    }

    private func waitForRun(_ store: AssistantStore) async throws {
        await store.waitForConversationTaskToSettle()
        try #require(!store.isRunning)
    }
}
