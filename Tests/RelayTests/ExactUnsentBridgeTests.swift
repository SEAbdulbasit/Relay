import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@MainActor private func withExactBridgeHistory(_ body: @MainActor (AssistantConversationHistory, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-exact-bridge-" + UUID().uuidString)
    let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json"))
    do { try await body(history, root); try await history.close(); try FileManager.default.removeItem(at: root) }
    catch { try? await history.close(); try? FileManager.default.removeItem(at: root); throw error }
}

@MainActor private func exactBridgeRecords(_ history: AssistantConversationHistory) async throws -> [JournalRecord] {
    let core = try await history.journalForTesting(), scope = try await core.scope()
    return try await core.page(expectedScope: scope).records
}

@MainActor @Suite(.serialized) struct ExactUnsentBridgeTests {
    private enum Refusal: Error, Equatable { case noEffect, unexpectedOpen }

    @Test func directScopeHasNoModelIdentityAndActualGenericFactoryCannotOpenIt() async throws {
        let logical = UUID(), run = try AssistantConversationHistory.Run(logicalTaskID: logical, cause: .newRequest)
        var scopeCurrent = true, opens = 0, reads = 0
        // Synthetic task metadata only for an actual zero-open rejection. No
        // AX object, real saved ACK, policy survey or input capability is made.
        let read = NativeLocalTaskReadAuthority.localUserInvocation(taskID: logical, taskIsCurrent: { scopeCurrent })
        let scope = try NativeVisualTaskScope(directExactUnsent: logical, runRevision: 1, run: run,
            originalObjective: AssistantStore.exactUnsentRequestText("literal"), readAuthority: read,
            validateAcknowledgedStoreRun: { guard scopeCurrent else { throw CancellationError() } })
        let input = try NativeLocalTaskInputAuthority.localUserInvocation(scope: scope, windowRequirement: .appScoped,
            validateAcknowledgedInputGrant: { guard scopeCurrent else { throw CancellationError() } })
        let platform = NativeProductionTaskConnectionFactory.Platform(open: { _, _ in opens += 1; throw Refusal.unexpectedOpen },
            observeRead: { _, _ in reads += 1; throw Refusal.unexpectedOpen })
        let factory = try NativeProductionTaskConnectionFactory(scope: scope, inputAuthority: input, platform: platform)
        let policy = NativeOrdinaryVisualPolicy(inspect: { _, _ in throw Refusal.unexpectedOpen }, review: { _, _, _ in false })
        #expect(scope.executionKind == .directExactUnsent && scope.inferenceIdentity == nil)
        do { _ = try await factory.open(policy: policy); Issue.record("Generic factory accepted a direct scope.") }
        catch let failure as NativeExactUnsentFailure { #expect(failure == .directAdapterUnavailable) }
        #expect(opens == 0 && reads == 0)
        scopeCurrent = false
        #expect(throws: (any Error).self) { try scope.validate() }
    }

    @Test func literalBytesAndOrdinaryComposerStayIndependentWithoutAnySourceMaker() {
        let defaultsName = "relay-exact-literal-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: defaultsName) else { Issue.record("Owned defaults unavailable."); return }
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let controller = NotchOverlayController(preferences: defaults, presentsPanels: false, frontmostPID: { nil })
        controller.promptText = "ordinary unsent prompt"
        controller.exactLiteral = "caf\u{e9}"
        let nfc = Data(controller.exactLiteral.utf8)
        controller.exactLiteral = "cafe\u{301}"
        #expect(nfc != Data(controller.exactLiteral.utf8))
        #expect(Data(controller.exactLiteral.utf8) == Data("cafe\u{301}".utf8))
        controller.exactLiteral = "   "
        #expect(Data(controller.exactLiteral.utf8) == Data("   ".utf8))
        #expect(controller.composerText == "ordinary unsent prompt")
        controller.chooseExactTextAction()
        #expect(!controller.isExactTextMode && !controller.exactTextActionAvailable)
        #expect(controller.promptText == "ordinary unsent prompt" && controller.exactLiteral == "   ")
        #expect(AssistantStore.exactUnsentRequestText("   ").hasSuffix("\n\n   "))
    }

    @Test func genuineOrdinaryStoreTicketCannotBecomeAnExactSavedOwnerOrACK() async throws {
        try await withExactBridgeHistory { history, root in
            var modelCalls = 0, effects = 0
            let store = AssistantStore(persistenceURL: root.appendingPathComponent("store.json"), complete: { _, _, _ in
                modelCalls += 1; return ModelReply(content: "An informational answer.", toolCalls: [])
            }, conversationHistory: history, execute: { _ in effects += 1; throw Refusal.noEffect })
            await store.waitForConversationTaskToSettle()
            store.draft = "Give an informational answer without taking an action."
            let ticket = try #require(store.send())
            await store.waitForConversationTaskToSettle()
            #expect(ticket.status == .saved && effects == 0 && modelCalls == 1)
            let rows = try await exactBridgeRecords(history)
            let user = try #require(rows.first { $0.event.id.bytes == Data(ticket.messageID.uuidString.utf8) })
            guard case let .user(text) = user.event.payload else { Issue.record("Actual user row missing."); return }
            #expect(Data(text.text.utf8) == Data(ticket.text.utf8))
            let unrelated = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            #expect(throws: (any Error).self) { try NativeExactUnsentAcknowledgment.bindSavedMessage(ticket, run: unrelated) }
            #expect(!store.actionsReady)
            store.stop(); await store.waitForConversationTaskToSettle()
        }
    }

    @Test(arguments: [JournalFault.beforeCommit, .afterCommit])
    func realNativeIntentFaultCannotCreateAnEffectOrSettlement(_ fault: JournalFault) async throws {
        try await withExactBridgeHistory { history, _ in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            try await history.prepare(run)
            let core = try await history.journalForTesting(), proposal = UUID()
            let call = ToolCall(id: "direct-exact-unsent:" + UUID().uuidString, name: "native_exact_unsent_focus", arguments: [:])
            var actions = 0, unsaved = 0, saved = 0
            await core.injectIntentFault(fault)
            do {
                _ = try await history.performNativeTextEffect(call, proposalID: proposal, phase: .focus, run: run, validate: {},
                    action: { _ in actions += 1; throw Refusal.noEffect }, unsavedEffect: { _ in unsaved += 1 }, settledEffect: { _, _ in saved += 1 })
                Issue.record("Actual intent fault was ignored.")
            } catch let error as JournalError {
                if case .beforeCommit = fault { #expect(error == .injectedBeforeCommit) }
                else { #expect(error == .acknowledgmentLost) }
            }
            #expect(actions == 0 && unsaved == 0 && saved == 0)
            let rows = try await exactBridgeRecords(history)
            let intents = rows.filter { if case .intent = $0.event.payload { return true }; return false }
            if case .beforeCommit = fault { #expect(intents.isEmpty) }
            else {
                #expect(intents.count == 1)
                do {
                    _ = try await history.performNativeTextEffect(call, proposalID: proposal, phase: .focus, run: run, validate: {},
                        action: { _ in actions += 1; throw Refusal.noEffect }, unsavedEffect: { _ in unsaved += 1 }, settledEffect: { _, _ in saved += 1 })
                    Issue.record("Lost intent acknowledgment reexecuted.")
                } catch let error as JournalError { #expect(error == .duplicateIntent) }
                #expect(actions == 0 && saved == 0)
            }
        }
    }

    @Test func genuineResultSaveRepairCannotFabricateAMissingNativeSidecar() async throws {
        try await withExactBridgeHistory { history, _ in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            try await history.prepare(run)
            let core = try await history.journalForTesting()
            let call = ToolCall(id: "direct-exact-unsent:" + UUID().uuidString, name: "native_exact_unsent_focus", arguments: [:])
            var actions = 0, unsaved = 0, saved = 0
            await core.injectResultFault(.afterCommit, forToolName: call.name)
            do {
                _ = try await history.performNativeTextEffect(call, proposalID: UUID(), phase: .focus, run: run, validate: {},
                    action: { _ in actions += 1; throw Refusal.noEffect }, unsavedEffect: { _ in unsaved += 1 }, settledEffect: { _, _ in saved += 1 })
                Issue.record("Actual result acknowledgment fault was ignored.")
            } catch let error as JournalError { #expect(error == .acknowledgmentLost) }
            #expect(actions == 1 && unsaved == 0 && saved == 0)
            try await history.retryResultSaves()
            let rows = try await exactBridgeRecords(history)
            let outcomes = rows.compactMap { record -> JournalToolOutcome? in if case let .result(value) = record.event.payload { return value }; return nil }
            #expect(outcomes.count == 1 && outcomes.first?.kind == .effectUncertain)
            #expect(actions == 1 && saved == 0)
        }
    }
}
