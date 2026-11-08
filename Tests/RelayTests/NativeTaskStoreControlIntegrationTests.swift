import AppKit
import ApplicationServices
import Dispatch
import Foundation
import Testing
@preconcurrency import LiteRTLM
@testable import Relay
@testable import RelayJournal

/// Actual Store, router, finite controller, policy and journal. Only model and
/// OS transport/editor metadata are inert. This qualifies wiring, not OS input.
@Suite(.serialized) @MainActor struct NativeTaskStoreControlIntegrationTests {
    @Test func ordinaryRegisteredStepSettlesInnerCheckpointsWithoutAnOuterIntent() async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        var mainTurns = 0, protocolMessages: [ModelMessage] = []
        let store = rig.store(complete: { messages, tools, _ in
            mainTurns += 1
            if messages.contains(where: { $0.role == "tool" && $0.toolCallID == "outer-original" }) { protocolMessages = messages }
            if mainTurns <= 2 { #expect(tools.contains { $0.name == NativeWindowControlTools.outerName }) }
            else { #expect(tools.isEmpty) }
            #expect(!tools.contains { NativeWindowControlTools.visualDefinitions.map(\.name).contains($0.name) })
            return mainTurns == 1 ? .init(content: "", toolCalls: [rig.outer()])
                : .init(content: "The original editor navigation was dispatched and read back; no semantic goal claim.", toolCalls: [])
        })
        try await rig.start(store)
        #expect(store.errorMessage == nil && rig.canvas.commands.count == 1)
        #expect(rig.opens == 1 && rig.closes == 1 && rig.runtime.images.count == 2)
        #expect(rig.budgets == 1 && mainTurns >= 2)
        let intents = try await rig.intents()
        #expect(intents.map(\.toolName) == ["native_control_prepare", NativeWindowControlTools.keyName, NativeWindowReadTool.name])
        #expect(store.phase == .needsInput) // Plain narration is not a goal verdict.
        #expect(!intents.contains { $0.toolName == NativeWindowControlTools.outerName })
        #expect(protocolMessages.filter { $0.role == "assistant" && $0.toolCalls.contains { $0.id == "outer-original" } }.count == 1)
        #expect(protocolMessages.filter { $0.role == "tool" && $0.toolCallID == "outer-original" }.count == 1)
        #expect(ContextWindow.isWellFormed(protocolMessages.filter { $0.role != "system" }))
        try rig.expectNoImageHistory(store, messages: protocolMessages)
        store.stop(); rig.client.unload()
    }

    @Test(arguments: [false, true])
    func ordinaryGoalAssessmentKeepsCompletionUnverifiedWithoutChangingTheInputReceipt(_ supportsGoal: Bool) async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        var mainTurns = 0, signalGreen = false, verdicts = 0, editorReadsBeforeGoal = 0
        rig.canvas.dispatchHook = {
            signalGreen = supportsGoal
            rig.runtime.readAnswer = signalGreen ? "Owned signal is green." : "Owned signal is red."
        }
        let store = rig.store(complete: { input, tools, _ in
            mainTurns += 1
            if input.first?.content.contains("ROLE: Independent goal assessment") == true {
                verdicts += 1; #expect(tools.isEmpty)
                #expect(rig.canvas.textReads == editorReadsBeforeGoal) // Controller read path only, not a provider-wide AX claim.
                #expect(input.contains { $0.role == "tool" && $0.content.contains(signalGreen ? "signal is green" : "signal is red") })
                return try Self.goalVerdict(input, satisfied: signalGreen)
            }
            if mainTurns == 2 { editorReadsBeforeGoal = rig.canvas.textReads }
            return mainTurns == 1 ? .init(content: "", toolCalls: [rig.outer()])
                : .init(content: "The input receipt alone does not establish the requested state.", toolCalls: [])
        })
        defer { store.stop(); rig.client.unload() }
        store.configuration = .init(modelPath: rig.model.path)
        store.draft = "Leave the owned signal in its green observable state."
        let ticket = try #require(store.send(nativeReadRestrictions: [rig.admission]))
        #expect(await ticket.waitForAcknowledgment() == .saved)
        await store.waitForConversationTaskToSettle()
        #expect(verdicts == 1 && mainTurns == 3 && rig.canvas.commands.count == 1)
        #expect(rig.opens == 1 && rig.closes == 1 && rig.budgets == 1 && rig.runtime.images.count == 2)
        #expect(store.phase == .needsInput) // No trusted whole-objective adapter exists.
        let intents = try await rig.intents(), outcomes = try await rig.outcomes()
        let effect = try #require(intents.first { $0.toolName == NativeWindowControlTools.keyName })
        #expect(outcomes.first { $0.invocationID == effect.invocationID }?.kind == .returnedUnverified)
        #expect(intents.filter { $0.toolName == NativeWindowReadTool.name }.count == 1)
        #expect(!store.messages.contains { $0.text.contains("exact physical action was verified") })
    }

    @Test func twoDifferentOriginalSourcesCannotBeCertifiedByTheLatestSeed() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; var turns = 0
        let store = rig.store(complete: { input, _, _ in
            turns += 1
            #expect(input.first?.content.contains("ROLE: Independent goal assessment") != true)
            if turns == 1 { return .init(content: "", toolCalls: [rig.outer()]) }
            if turns == 2 { rig.selectSecondary = true; return .init(content: "", toolCalls: [rig.outer()]) }
            return .init(content: "Both original windows still require whole-goal verification.", toolCalls: [])
        })
        defer { store.stop(); rig.client.unload() }
        try await rig.start(store)
        #expect(turns == 3 && store.phase == .needsInput && rig.canvas.commands.count == 2)
        #expect(rig.runtime.images.count == 2 && rig.opens == 1 && rig.closes == 1)
        #expect(try await rig.intents().filter { $0.toolName == NativeWindowReadTool.name }.isEmpty)
    }

    @Test func goalReadRetainsTheOriginalSourceInsteadOfCallingTheNewSelectionResolver() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; var turns = 0
        rig.runtime.readAnswer = "ORIGINAL_A_STATE"
        rig.answers[rig.secondaryCanvas.sourceID] = "FOREIGN_B_BODY"
        let store = rig.store(complete: { input, _, _ in
            turns += 1
            if input.first?.content.contains("ROLE: Independent goal assessment") == true {
                #expect(input.map(\.content).joined().contains("ORIGINAL_A_STATE"))
                #expect(!input.map(\.content).joined().contains("FOREIGN_B_BODY"))
                return try Self.goalVerdict(input, satisfied: true)
            }
            if turns == 1 { return .init(content: "", toolCalls: [rig.outer()]) }
            rig.selectSecondary = true // Only an app-level re-selection would now choose B.
            return .init(content: "Check the actual original source.", toolCalls: [])
        })
        defer { store.stop(); rig.client.unload() }
        try await rig.start(store)
        #expect(turns == 3 && store.phase == .needsInput && rig.canvas.commands.count == 1)
        #expect(rig.secondaryCanvas.captureCount == 0 && rig.secondaryCanvas.commands.isEmpty)
        #expect(rig.runtime.images.count == 2 && rig.opens == 1 && rig.closes == 1)
    }

    @Test(arguments: ["missing_effect", "wrong_read", "physical_count", "tool_request"])
    func incompleteOrPhysicalDeliveryVerdictsCannotOverrideTheUnverifiedReceipt(_ defect: String) async throws {
        let rig = try StoreRig(); defer { rig.remove() }; var turns = 0
        let forbidden = rig.folder.appending(path: "not-written.txt")
        let store = rig.store(complete: { input, tools, _ in
            turns += 1
            if input.first?.content.contains("ROLE: Independent goal assessment") == true {
                #expect(tools.isEmpty)
                var reply = try Self.goalVerdict(input, satisfied: true)
                var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(reply.content.utf8))
                switch defect {
                case "missing_effect": object["effect_ids"] = .array([])
                case "wrong_read": object["read_ids"] = .array([.string(UUID().uuidString)])
                case "physical_count": object["basis"] = .string("delivery_or_count")
                default: reply.toolCalls = [.init(name: "write_file", arguments: ["path": .string(forbidden.path), "content": .string("must not dispatch")])]
                }
                reply.content = JSONValue.object(object).pretty; return reply
            }
            return turns == 1 ? .init(content: "", toolCalls: [rig.outer()]) : .init(content: "The requested state needs an independent check.", toolCalls: [])
        })
        defer { store.stop(); rig.client.unload() }
        try await rig.start(store)
        #expect(turns == 3 && store.phase == .needsInput && rig.canvas.commands.count == 1)
        #expect(!FileManager.default.fileExists(atPath: forbidden.path))
        #expect(rig.runtime.images.count == 2)
    }

    @Test func anUncoveredLegacyUnverifiedResultBlocksTheNativeGoalOverride() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; var turns = 0
        let store = rig.store(complete: { input, _, _ in
            turns += 1
            #expect(input.first?.content.contains("ROLE: Independent goal assessment") != true)
            if turns == 1 { return .init(content: "", toolCalls: [rig.outer()]) }
            if turns == 2 { return .init(content: "", toolCalls: [.init(name: "calculate", arguments: ["expression": .string("1+1")])]) }
            return .init(content: "The unrelated result remains unverified.", toolCalls: [])
        }, execute: { call in
            try #require(call.name == "calculate")
            return .init(summary: "Inert unrelated unverified result.", evidence: "Synthetic result; no calculator or process was used.", verified: false)
        })
        defer { store.stop(); rig.client.unload() }
        try await rig.start(store)
        #expect(turns == 3 && store.phase == .needsInput && rig.canvas.commands.count == 1)
        #expect(rig.runtime.images.count == 1)
        #expect(try await rig.intents().filter { $0.toolName == NativeWindowReadTool.name }.isEmpty)
    }

    @Test func noInputReportUncertaintyCannotCreateGoalCoverage() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; rig.runtime.kind = .report; var turns = 0
        let store = rig.store(complete: { input, _, _ in
            turns += 1; #expect(input.first?.content.contains("ROLE: Independent goal assessment") != true)
            return turns == 1 ? .init(content: "", toolCalls: [rig.outer()]) : .init(content: "The report is unverified.", toolCalls: [])
        })
        defer { store.stop(); rig.client.unload() }
        try await rig.start(store)
        #expect(turns == 2 && store.phase == .needsInput && rig.canvas.commands.isEmpty)
        #expect(rig.runtime.images.count == 1)
    }

    @Test func unsavedOriginalEffectCannotMintGoalEligibilityOrRepeatInputDuringRepair() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; var turns = 0
        let core = try await rig.history.journalForTesting()
        await core.injectResultFault(.afterCommit, forToolName: NativeWindowControlTools.keyName)
        let store = rig.store(complete: { input, _, _ in
            turns += 1; #expect(input.first?.content.contains("ROLE: Independent goal assessment") != true)
            return .init(content: "", toolCalls: [rig.outer()])
        })
        defer { store.stop(); rig.client.unload() }
        try await rig.start(store)
        #expect(turns == 1 && rig.canvas.commands.count == 1 && rig.runtime.images.count == 1)
        #expect(store.phase != .idle)
        try await rig.history.retryResultSaves()
        #expect(turns == 1 && rig.canvas.commands.count == 1)
        #expect(try await rig.intents().filter { $0.toolName == NativeWindowReadTool.name }.isEmpty)
    }

    @Test(arguments: [false, true])
    func sourceDriftOrStopDuringGoalVerdictCannotPublishCompletionOrRepeatTheGesture(_ stop: Bool) async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        var turns = 0, waiting: CheckedContinuation<Void, Never>?
        let store = rig.store(complete: { input, tools, _ in
            turns += 1
            if input.first?.content.contains("ROLE: Independent goal assessment") == true {
                #expect(tools.isEmpty)
                await withCheckedContinuation { waiting = $0 }
                return try Self.goalVerdict(input, satisfied: true)
            }
            return turns == 1 ? .init(content: "", toolCalls: [rig.outer()]) : .init(content: "Inspect the postcondition independently.", toolCalls: [])
        })
        defer { waiting?.resume(); store.stop(); rig.client.unload() }
        store.configuration = .init(modelPath: rig.model.path); store.draft = "Leave the original owned window in the requested observable state."
        let ticket = try #require(store.send(nativeReadRestrictions: [rig.admission]))
        #expect(await ticket.waitForAcknowledgment() == .saved)
        try await until { waiting != nil }
        if stop { store.stop() } else { rig.canvas.sourceVersion += 1 }
        waiting?.resume(); waiting = nil
        await store.waitForConversationTaskToSettle()
        #expect(turns == 3 && rig.canvas.commands.count == 1 && rig.runtime.images.count == 2)
        #expect(store.phase != .idle)
        #expect(!store.activity.contains { $0.name == "Requested state checked" && $0.status == "goal assessed" })
        #expect(rig.opens == 1 && rig.closes == 1)
        if stop {
            store.resume(); await store.waitForConversationTaskToSettle()
            #expect(store.phase == .needsInput && rig.canvas.commands.count == 1 && rig.runtime.images.count == 2)
            #expect(turns == 4) // Same logical task keeps uncovered uncertainty; old owner is not adopted.
        }
    }

    @Test func actualLateUncertainEffectAfterStopRemainsAnUncoveredObligationOnContinue() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; var turns = 0
        let store = rig.store(complete: { input, _, _ in
            turns += 1
            #expect(input.first?.content.contains("ROLE: Independent goal assessment") != true)
            return turns == 1 ? .init(content: "", toolCalls: [rig.outer()])
                : .init(content: "The earlier input is still uncertain; no new input was requested.", toolCalls: [])
        })
        defer { store.stop(); rig.client.unload() }
        rig.canvas.dispatchHook = { [weak store] in store?.stop() }
        try await rig.start(store)
        #expect(store.phase == .stopped && rig.canvas.commands.count == 1 && turns == 1)
        rig.canvas.dispatchHook = nil
        store.resume(); await store.waitForConversationTaskToSettle()
        #expect(turns == 2 && store.phase == .needsInput && rig.canvas.commands.count == 1)
        #expect(rig.runtime.images.count == 1)
        let original = try #require(try await rig.intents().first { $0.toolName == NativeWindowControlTools.keyName })
        #expect(try await rig.outcomes().contains { $0.invocationID == original.invocationID && $0.kind == .effectUncertain })
    }

    @Test func aPhysicalCountObjectiveCannotFinishFromAFalseObservedStateSelfLabel() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; var turns = 0
        let originalValue = rig.canvas.field
        let store = rig.store(complete: { input, tools, _ in
            turns += 1
            if input.first?.content.contains("ROLE: Independent goal assessment") == true {
                #expect(tools.isEmpty)
                // Adversarial: exact IDs/coverage, false physical-goal classification.
                return try Self.goalVerdict(input, satisfied: true, basis: "observed_state")
            }
            return turns == 1 ? .init(content: "", toolCalls: [rig.outer()]) : .init(content: "The physical input requires proof.", toolCalls: [])
        })
        defer { store.stop(); rig.client.unload() }
        store.configuration = .init(modelPath: rig.model.path)
        store.draft = "Prove that the physical Left key was delivered exactly once. A preexisting editor state is not sufficient."
        let ticket = try #require(store.send(nativeReadRestrictions: [rig.admission]))
        #expect(await ticket.waitForAcknowledgment() == .saved)
        await store.waitForConversationTaskToSettle()
        #expect(turns == 3 && store.phase == .needsInput && rig.canvas.commands.count == 1)
        #expect(rig.canvas.field.utf8.elementsEqual(originalValue.utf8))
        #expect(store.messages.last?.text.contains("remain unverified") == true)
        #expect(!store.activity.contains { $0.status == "goal assessed" })
        let effect = try #require(try await rig.intents().first { $0.toolName == NativeWindowControlTools.keyName })
        #expect(try await rig.outcomes().first { $0.invocationID == effect.invocationID }?.kind == .returnedUnverified)
    }

    @Test(arguments: ["source", "stop", "unsaved_source", "unsaved_stop"])
    func auxiliaryReadCommitRevocationPublishesOnlyGenericFactsAndNeverItsPrivateBody(_ change: String) async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        let core = try await rig.history.journalForTesting(), barrier = GoalCommitBarrier()
        let sentinel = rig.runtime.secret
        var turns = 0, resumed = false
        if change.hasPrefix("unsaved") { await core.injectResultFault(.afterCommit, forToolName: NativeWindowReadTool.name) }
        await core.atNextResultBoundary(.afterCommit, forToolName: NativeWindowReadTool.name) { barrier.pause() }
        let store = rig.store(complete: { input, _, _ in
            turns += 1
            #expect(input.first?.content.contains("ROLE: Independent goal assessment") != true)
            if resumed {
                #expect(!input.map(\.content).joined().contains(sentinel))
                return .init(content: "The old input remains uncertain; no replacement or replay was requested.", toolCalls: [])
            }
            return turns == 1 ? .init(content: "", toolCalls: [rig.outer()]) : .init(content: "Check the state independently.", toolCalls: [])
        })
        defer { barrier.release(); store.stop(); rig.client.unload() }
        store.configuration = .init(modelPath: rig.model.path); store.draft = "Leave the owned source in the requested observable state."
        let ticket = try #require(store.send(nativeReadRestrictions: [rig.admission]))
        #expect(await ticket.waitForAcknowledgment() == .saved)
        do {
            try await until { barrier.entered }
            if change.hasSuffix("stop") { store.stop() } else { rig.canvas.sourceVersion += 1 }
            barrier.release(); await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && rig.canvas.commands.count == 1 && rig.runtime.images.count == 2)
            #expect(store.phase != .idle)
            #expect(!store.activity.contains { $0.detail.contains(sentinel) })
            #expect(!store.messages.contains { $0.text.contains(sentinel) })
            if change.hasPrefix("unsaved") { try await rig.history.retryResultSaves() }
            resumed = true; store.resume(); await store.waitForConversationTaskToSettle()
            #expect(turns == 3 && store.phase == .needsInput && rig.canvas.commands.count == 1)
            #expect(!store.activity.contains { $0.detail.contains(sentinel) })
            #expect(try await rig.intents().filter { $0.toolName == NativeWindowReadTool.name }.count == 1)
        } catch {
            store.stop(); barrier.release(); await store.waitForConversationTaskToSettle(); throw error
        }
    }

    private static func goalVerdict(_ input: [ModelMessage], satisfied: Bool, basis: String = "observed_state") throws -> ModelReply {
        let marker = "App-owned effect coverage IDs (not semantic proof): "
        let text = try #require(input.first { $0.role == "user" && $0.content.contains(marker) }?.content)
        let start = try #require(text.range(of: marker))
        let ids = try JSONDecoder().decode([String].self, from: Data(text[start.upperBound...].utf8))
        let readID = try #require(input.last { $0.role == "tool" }?.toolCallID)
        return .init(content: JSONValue.object(["goal": .string(satisfied ? "satisfied" : "not_established"),
            "basis": .string(basis), "coverage": .string("whole_objective"),
            "read_ids": .array([.string(readID)]), "effect_ids": .array(ids.map(JSONValue.string))]).pretty, toolCalls: [])
    }

    @Test func executorUsesTheSameServiceWhileNavigatorAndCriticRemainReadOnly() async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        var calls = 0
        let store = rig.store(multiAgent: true, complete: { _, tools, _ in
            calls += 1
            switch calls {
            case 1:
                #expect(tools.isEmpty)
                return .init(content: #"{"taskType":"automation","steps":[{"id":"one","role":"Executor","title":"Navigate the original editor once"}]}"#, toolCalls: [])
            case 2:
                #expect(tools.contains { $0.name == NativeWindowControlTools.outerName })
                return .init(content: "", toolCalls: [rig.outer()])
            default:
                #expect(!tools.contains { $0.name == NativeWindowControlTools.outerName })
                return .init(content: "The one navigation was read back; remaining semantic outcome is unverified.", toolCalls: [])
            }
        })
        try await rig.start(store)
        #expect(rig.canvas.commands.count == 1 && rig.opens == 1 && rig.closes == 1 && rig.budgets == 1)
        #expect(!ToolPartitioning.allowedToolNames(for: .navigator).contains(NativeWindowControlTools.outerName))
        #expect(!ToolPartitioning.allowedToolNames(for: .critic).contains(NativeWindowControlTools.outerName))
        #expect(try await rig.intents().map(\.toolName) == ["native_control_prepare", NativeWindowControlTools.keyName])
        store.stop(); rig.client.unload()
    }

    @Test func actualControlBranchExpiresOldNativeReferencesButPreservesLiteralSourceBytes() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; rig.runtime.kind = .report
        let stale = "E5F36812-278C-4BA6-950E-1DE69F747021"
        let literal = "source element_id=F693D753-0391-40F4-9F17-2892C31B7503 window_id=cafe\u{301}"
        var turns = 0
        let store = rig.store(complete: { messages, _, _ in
            turns += 1
            if turns == 1 {
                return .init(content: "", toolCalls: [.init(name: "observe_app", arguments: ["bundle_id": .string(rig.canvas.application.bundleID)])])
            }
            if turns == 2 { return .init(content: "", toolCalls: [rig.outer()]) }
            let previous = try #require(messages.last { $0.toolName == "observe_app" })
            let payload = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(previous.content.utf8)).object)
            let summary = try #require(payload["summary"]?.string)
            #expect(!summary.contains(stale))
            #expect(Data(summary.utf8).range(of: Data(literal.utf8)) != nil)
            #expect(payload["reference_status"]?.string?.contains("Expired") == true)
            return .init(content: "The unverified native report required no input.", toolCalls: [])
        }, execute: { call in
            try #require(call.name == "observe_app")
            return .init(summary: "element_id=\(stale) role=AXTextField title=Actual field description= identifier=field value=\(literal) enabled=unknown",
                evidence: "Native AX observation of an admitted synthetic process.", verified: true)
        })
        try await rig.start(store)
        #expect(turns >= 3 && rig.canvas.commands.isEmpty && rig.runtime.images.count == 1)
        #expect(DesktopActionBatch.invalidatesReferences(rig.outer()))
        store.stop(); rig.client.unload()
    }

    @Test func ordinaryComposerOmitsTheWholeNativeGroupWhenItsOriginalSourceChangesBeforeNextInference() async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        let secret = "PRIVATE_ORDINARY_NATIVE_" + UUID().uuidString
        rig.answers[rig.canvas.sourceID] = secret
        var turns = 0, closed = false
        let store = rig.store(complete: { input, _, _ in
            turns += 1
            if turns == 1 {
                return .init(content: "", toolCalls: [.init(id: "ordinary-native-read", name: NativeWindowReadTool.name,
                    arguments: ["bundle_id": .string(rig.canvas.application.bundleID), "question": .string("Read only the admitted original source.")])])
            }
            #expect(closed && !input.map(\.content).joined().contains(secret))
            #expect(!input.flatMap(\.toolCalls).contains { $0.id == "ordinary-native-read" })
            #expect(ContextWindow.isWellFormed(input.filter { $0.role != "system" }))
            #expect(input.contains { $0.content.contains("omitted_complete_groups") })
            return .init(content: "The earlier source changed; no input was repeated.", toolCalls: [])
        })
        rig.sourceValidationHook = { [weak store] source in
            guard let store, source == rig.canvas.sourceID, !closed, store.phase == .thinking,
                  rig.runtime.images.count == 1 else { return }
            closed = true; rig.canvas.sourceVersion += 1
        }
        try await rig.start(store)
        #expect(turns == 2 && rig.opens == 1 && rig.closes == 1 && rig.runtime.images.count == 1)
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0)
        #expect(store.activity.contains { $0.detail.contains(secret) })
        store.stop(); rig.client.unload()
    }

    @Test(arguments: [false, true])
    func ordinaryLateSourceDerivedWriteIsNeverAcceptedAfterDriftOrStop(_ stop: Bool) async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        let output = rig.folder.appending(path: "must-not-exist.txt")
        var waiting: CheckedContinuation<Void, Never>?, turns = 0
        let store = rig.store(complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "read-before-write", name: NativeWindowReadTool.name,
                arguments: ["bundle_id": .string(rig.canvas.application.bundleID), "question": .string("Inspect the original source before deciding.")])]) }
            #expect(input.contains { $0.role == "tool" && $0.content.contains(rig.runtime.secret) })
            await withCheckedContinuation { waiting = $0 }
            return .init(content: "Late source-derived narration.", toolCalls: [.init(id: "late-derived-write", name: "write_file",
                arguments: ["path": .string(output.path), "content": .string(rig.runtime.secret)])])
        })
        store.configuration = .init(modelPath: rig.model.path)
        store.grants = [.init(path: rig.folder.path, writable: true)]
        store.draft = "Inspect the admitted source, then decide whether to write only the owned output."
        let ticket = try #require(store.send(nativeReadRestrictions: [rig.admission]))
        #expect(await ticket.waitForAcknowledgment() == .saved)
        try await until { waiting != nil }
        if stop { store.stop() } else { rig.canvas.sourceVersion += 1 }
        waiting?.resume(); waiting = nil
        try await until { !store.isRunning }
        #expect(turns == 2 && !FileManager.default.fileExists(atPath: output.path))
        #expect(!store.activity.contains { $0.name == "write_file" && $0.status == "requested" })
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0 && rig.runtime.images.count == 1)
        #expect(store.phase == (stop ? .stopped : .failed))
        store.stop(); rig.client.unload()
    }

    @Test func actualStoreOmitsClosedAThenChangedBBeforeExecutorCriticAndSynthesisWhileFreshCProceeds() async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        let a = "PRIVATE_A_BODY_" + UUID().uuidString, b = "PRIVATE_B_BODY_" + UUID().uuidString, c = "PRIVATE_C_BODY_" + UUID().uuidString
        rig.answers = [rig.canvas.sourceID: a, rig.secondaryCanvas.sourceID: b, rig.thirdCanvas.sourceID: c]
        var turns = 0, actualInertEffects = 0, closedA = false, closedB = false
        let read: (String) -> Relay.ToolCall = { id in .init(id: id, name: NativeWindowReadTool.name,
            arguments: ["bundle_id": .string(rig.canvas.application.bundleID), "question": .string("Describe only the currently selected admitted synthetic source.")]) }
        let store = rig.store(multiAgent: true, complete: { messages, tools, _ in
            turns += 1
            let text = messages.map(\.content).joined()
            switch turns {
            case 1: return .init(content: #"{"steps":[{"id":"a","role":"Navigator","title":"Inspect source A"},{"id":"b","role":"Navigator","title":"Inspect source B"},{"id":"op","role":"Executor","title":"Run the inert operation and verify using fresh source C"}]}"#, toolCalls: [])
            case 2:
                #expect(!tools.contains { $0.name == NativeWindowControlTools.outerName })
                return .init(content: "", toolCalls: [read("same-provider-id")])
            case 3:
                #expect(closedA && !text.contains(a) && text.contains("omitted_native_results"))
                rig.selectSecondary = true
                return .init(content: "", toolCalls: [read("same-provider-id")])
            case 4:
                #expect(!text.contains(a) && text.contains(b))
                return .init(content: "", toolCalls: [.init(id: "actual-inert-effect", name: "open_app", arguments: ["app": .string("Inert owned counter")])])
            case 5:
                #expect(closedB && !text.contains(a) && !text.contains(b))
                #expect(!tools.contains { $0.name == NativeWindowControlTools.outerName })
                rig.selectThird = true
                return .init(content: "", toolCalls: [read("fresh-source-c")])
            case 6:
                #expect(tools.isEmpty && text.contains(c) && !text.contains(a) && !text.contains(b))
                return .init(content: "VERIFIED: The owned counter changed once and the actual fresh C readback is available; no physical device action is implied.", toolCalls: [])
            default:
                #expect(tools.isEmpty && !text.contains(a) && !text.contains(b) && !text.contains(c))
                return .init(content: "Private earlier details were omitted. The known inert result remains in Activity; no input was repeated.", toolCalls: [])
            }
        }, execute: { call in
            try #require(call.name == "open_app")
            actualInertEffects += 1
            return .init(summary: "The owned inert counter changed once.", evidence: "Actual in-memory test counter; no app was launched.", verified: true)
        })
        rig.sourceValidationHook = { [weak store] source in
            guard let store else { return }
            if source == rig.canvas.sourceID, !closedA,
               store.agentActivities.last(where: { $0.title == "Navigating & inspecting state" })?.detail == "Inspect source B" {
                rig.canvas.sourceVersion += 1; closedA = true
            }
            if source == rig.secondaryCanvas.sourceID, !closedB, store.activeAgentRole == .critic {
                rig.secondaryCanvas.sourceVersion += 1; closedB = true
            }
        }
        try await rig.start(store)
        #expect(turns == 7 && actualInertEffects == 1 && rig.opens == 1 && rig.closes == 1)
        #expect(store.errorMessage == nil && store.phase == .idle)
        #expect(rig.runtime.images.count == 3 && rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0)
        #expect(rig.secondaryCanvas.commands.isEmpty && rig.thirdCanvas.commands.isEmpty)
        // Model omission does not erase the actual facts originally delivered
        // to this user/task or hide their known dispatch state.
        #expect(store.activity.contains { $0.detail.contains(a) } && store.activity.contains { $0.detail.contains(b) })
        store.stop(); rig.client.unload()
    }

    @Test func actualExecutorCriticReadsThenUsesOnlyItsExactCurrentNativeSourceForTheVerdict() async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        var calls = 0, verdicts = 0
        let store = rig.store(multiAgent: true, complete: { messages, tools, _ in
            calls += 1
            switch calls {
            case 1: return .init(content: #"{"steps":[{"id":"one","role":"Executor","title":"Navigate the original editor once"}]}"#, toolCalls: [])
            case 2: return .init(content: "", toolCalls: [rig.outer()])
            case 3:
                #expect(tools.contains { $0.name == NativeWindowReadTool.name })
                return .init(content: "", toolCalls: [.init(id: "critic-read-id", name: NativeWindowReadTool.name,
                    arguments: ["bundle_id": .string(rig.canvas.application.bundleID), "question": .string("Is the original synthetic editor visible?")])])
            case 4:
                #expect(tools.isEmpty)
                #expect(messages.contains { $0.role == "tool" && $0.toolCallID == "critic-read-id" && $0.content.contains(rig.runtime.secret) })
                #expect(ContextWindow.isWellFormed(messages.filter { $0.role != "system" }))
                verdicts += 1
                return .init(content: "UNVERIFIED: The editor is visible, but generic input dispatch/readback alone does not prove the navigation's semantic outcome.", toolCalls: [])
            default: return .init(content: "The ordinary step remains unverified; no input was repeated.", toolCalls: [])
            }
        })
        try await rig.start(store)
        #expect(verdicts == 1 && rig.canvas.commands.count == 1)
        #expect(rig.opens == 1 && rig.closes == 1 && rig.runtime.images.count == 2)
        #expect(store.errorMessage == nil && store.phase == .needsInput)
        let intents = try await rig.intents()
        #expect(intents.map(\.toolName) == ["native_control_prepare", NativeWindowControlTools.keyName, NativeWindowReadTool.name])
        store.stop(); rig.client.unload()
    }

    @Test func unqualifiedCaptureRefusesTheSecondPrivateCriticSendEvenWhenReadSucceeded() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, tools, _ in
            turns += 1
            if turns == 1 { return .init(content: #"{"steps":[{"id":"one","role":"Critic","title":"Read original source"}]}"#, toolCalls: []) }
            if turns == 2 {
                return .init(content: "", toolCalls: [.init(id: "unqualified-read", name: NativeWindowReadTool.name,
                    arguments: ["bundle_id": .string(rig.canvas.application.bundleID), "question": .string("What is visible?")])])
            }
            Issue.record("A private Critic verdict must not be sent without its source capability")
            return .init(content: "UNVERIFIED", toolCalls: [])
        }, conversationHistory: rig.history, modelClient: rig.client, multiAgent: true,
            nativeWindowBackendFactory: { _ in
                .init(initial: { _ in
                    let observation = try await rig.canvas.read()
                    return .init(snapshot: observation.snapshot, isCurrent: { rig.canvas.session.isCurrent(observation) }, refreshOriginal: nil)
                }, stop: { rig.canvas.session.stop() }, drain: { await rig.canvas.session.drain() })
            })
        try await rig.start(store)
        #expect(turns == 2 && store.phase == .failed && rig.runtime.images.count == 1)
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0)
        store.stop(); rig.client.unload()
    }

    @Test func stoppedLatePrivateReportCannotPublishOrBecomeASourceFreeReceiptOnContinue() async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        rig.runtime.kind = .report
        var waiting: CheckedContinuation<Void, Never>?, mainTurns = 0
        rig.runtime.pause = { await withCheckedContinuation { waiting = $0 } }
        let store = rig.store(multiAgent: true, complete: { messages, tools, _ in
            mainTurns += 1
            if mainTurns == 1 {
                #expect(tools.isEmpty)
                return .init(content: #"{"taskType":"automation","steps":[{"id":"one","role":"Executor","title":"Report the original source without input"}]}"#, toolCalls: [])
            }
            if mainTurns == 3 {
                #expect(!tools.contains { $0.name == NativeWindowControlTools.outerName })
                #expect(!messages.map(\.content).joined().contains(rig.runtime.secret))
                return .init(content: "UNVERIFIED: The interrupted report was not re-created; obtain a new authorized source if needed.", toolCalls: [])
            }
            if mainTurns == 2 { return .init(content: "", toolCalls: [rig.outer()]) }
            #expect(!messages.map(\.content).joined().contains(rig.runtime.secret))
            return .init(content: "The stopped private report was not published or replayed.", toolCalls: [])
        })
        store.configuration = .init(modelPath: rig.model.path)
        store.draft = "Report only this admitted synthetic source."
        let ticket = try #require(store.send(nativeReadRestrictions: [rig.admission]))
        #expect(await ticket.waitForAcknowledgment() == .saved)
        try await until { waiting != nil }
        store.stop(); waiting?.resume(); waiting = nil
        try await until { !store.isRunning }
        #expect(!store.messages.contains { $0.text.contains(rig.runtime.secret) })
        #expect(!store.activity.contains { $0.detail.contains(rig.runtime.secret) })
        rig.runtime.pause = nil
        store.resume(); try await until { !store.isRunning }
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0)
        #expect(rig.runtime.images.count == 1 && rig.opens == 1)
        #expect(!store.messages.contains { $0.text.contains(rig.runtime.secret) })
        store.stop(); rig.client.unload()
    }

    @Test func completedPrivateReportTaintsLaterDerivedReceiptsAcrossStopContinue() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; rig.runtime.kind = .report
        var turns = 0, resumed = false
        let store = rig.store(multiAgent: true, complete: { messages, tools, _ in
            turns += 1
            if resumed {
                let context = messages.map(\.content).joined()
                #expect(!context.contains(rig.runtime.secret))
                #expect(context.contains("omitted"))
                return .init(content: "UNVERIFIED: Reconciliation needs a fresh admitted read; no report/input was replayed.", toolCalls: [])
            }
            if tools.isEmpty {
                return .init(content: #"{"taskType":"automation","steps":[{"id":"one","role":"Executor","title":"Report source status"}]}"#, toolCalls: [])
            }
            if turns == 2 { return .init(content: "", toolCalls: [rig.outer()]) }
            return .init(content: "The source status remains unverified; no further input.", toolCalls: [])
        })
        try await rig.start(store)
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0 && rig.runtime.images.count == 1)
        resumed = true; store.resume(); try await until { !store.isRunning }
        #expect(rig.runtime.images.count == 1 && rig.opens == 1)
        store.stop(); rig.client.unload()
    }

    @Test func unknownPointerReviewRetainsExactCurrentImageAndDeclineStopsEquivalentInput() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; rig.runtime.kind = .pointer; rig.requiresReview = true
        var turns = 0
        let store = rig.store(complete: { _, _, _ in
            turns += 1; return .init(content: "", toolCalls: [rig.outer()])
        })
        store.configuration = .init(modelPath: rig.model.path)
        store.draft = "Perform one ordinary gesture on the admitted original canvas."
        let ticket = try #require(store.send(nativeReadRestrictions: [rig.admission]))
        #expect(await ticket.waitForAcknowledgment() == .saved)
        try await until { store.pendingReview != nil }
        let review = try #require(store.pendingReview), visual = try #require(review.visualPresentation)
        #expect(visual.imageIsDecodable && review.canApprove)
        #expect(visual.frame.jpeg == rig.runtime.images.last)
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0)
        store.denyReview(); try await until { !store.isRunning }
        await store.waitForConversationTaskToSettle()
        #expect(store.phase == .needsInput && turns == 1 && rig.opens == 1 && rig.closes == 1)
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0 && store.pendingReview == nil)
        #expect(try await rig.intents().allSatisfy { $0.toolName != NativeWindowControlTools.pointerName })
        store.stop(); rig.client.unload()
    }

    @Test func inputFollowedByStopSavesItsOriginalFactBeforeReplacementPublicationFences() async throws {
        let rig = try StoreRig(); defer { rig.remove() }
        var turns = 0
        let store = rig.store(complete: { _, _, _ in
            turns += 1
            return turns == 1 ? .init(content: "", toolCalls: [rig.outer()])
                : .init(content: "The replacement request requires no device operation.", toolCalls: [])
        })
        rig.canvas.dispatchHook = { store.stop() }
        try await rig.start(store)
        #expect(rig.canvas.commands.count == 1 && store.phase == .stopped)
        let outcomes = try await rig.outcomes()
        #expect(outcomes.count == 2 && outcomes.last?.kind != .notDispatched && outcomes.last?.kind != .failedBeforeDispatch)
        store.draft = "Answer a new ordinary informational request without touching the device."
        let ticket = try #require(store.send())
        #expect(await ticket.waitForAcknowledgment() == .saved)
        try await until { !store.isRunning }
        #expect(rig.canvas.commands.count == 1 && turns == 2)
        store.stop(); rig.client.unload()
    }

    @Test func missingActionCompositionKeepsRegisteredReadAndNeverAdvertisesControl() async throws {
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, tools, _ in
            turns += 1
            #expect(tools.contains { $0.name == NativeWindowReadTool.name })
            #expect(!tools.contains { $0.name == NativeWindowControlTools.outerName })
            return .init(content: "No operation requested.", toolCalls: [])
        }, nativeTaskControl: { _, _ in throw NativeVisualTaskFailure.unavailableDependency("inert composition failure") })
        store.configuration = .init(modelPath: "/inert/not-loaded.litertlm")
        store.draft = "Explain this task without using an app."
        let ticket = try #require(store.send())
        #expect(await ticket.waitForAcknowledgment() == .saved)
        try await until { !store.isRunning }
        #expect(turns == 1 && store.errorMessage == nil)
        store.stop()
    }

    @Test func sameTaskBudgetCanRefuseBeforeNativeModelOrInput() async throws {
        let rig = try StoreRig(); defer { rig.remove() }; rig.expireAtOpen = true
        var turns = 0
        let store = rig.store(complete: { _, _, _ in
            turns += 1
            return .init(content: "", toolCalls: [rig.outer()])
        })
        try await rig.start(store)
        #expect(rig.budgets == 1 && rig.opens <= 1 && rig.runtime.images.isEmpty)
        #expect(rig.canvas.commands.isEmpty && rig.canvas.textWrites == 0)
        store.stop(); rig.client.unload()
    }

    private func until(_ done: @escaping @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !done() { try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
    }

    @MainActor private final class StoreRig {
        let canvas = NextNativeControlRig(), secondaryCanvas = NextNativeControlRig(), thirdCanvas = NextNativeControlRig(), runtime = Runtime()
        var selectSecondary = false, selectThird = false
        var sourceValidationHook: (@MainActor (UUID) -> Void)?
        var answers: [UUID: String] = [:]
        let folder: URL, model: URL, history: AssistantConversationHistory
        let clock = Clock()
        var opens = 0, closes = 0, budgets = 0, expireAtOpen = false, requiresReview = false
        lazy var client = LocalModelClient(runtimeFactory: { [runtime] _, _, _ in runtime }, visionRuntimeFactory: { [runtime] _, _, _ in runtime })
        var admission: NativeWindowTaskAdapter.ApplicationAdmission { .init(application: canvas.application, validate: {}) }
        init() throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "relay-native-store-pure-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            model = folder.appending(path: "inert.litertlm"); try Data([1]).write(to: model)
            history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json"))
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
        func outer() -> Relay.ToolCall {
            .init(id: "outer-original", name: NativeWindowControlTools.outerName,
                arguments: ["bundle_id": .string(canvas.application.bundleID), "instruction": .string("One original-window navigation or no-input status report.")])
        }
        func store(multiAgent: Bool = false,
                   complete: @escaping ([ModelMessage], [ToolDefinition], ModelConfiguration) async throws -> ModelReply,
                   execute: ((Relay.ToolCall) async throws -> ToolResult)? = nil) -> AssistantStore {
            AssistantStore(persistenceURL: nil, complete: complete, conversationHistory: history, execute: execute,
                modelClient: client, multiAgent: multiAgent, nativeTaskControl: { [self] scope, _ in
                    .init(factory: .init(missingDependencies: [], open: { [self] candidate, policy in
                        try #require(candidate === scope); try scope.validate(); opens += 1
                        if expireAtOpen { clock.set(2) }
                        canvas.session = NativeControlSession(backend: canvas.backend, sessionIsActive: { [self] in canvas.active }, authorizer: policy)
                        @MainActor func source(_ observation: NativeControlSession.Observation) throws -> NativeVisualTaskSource {
                            let original = try canvas.session.source(from: observation)
                            return .init(observation: observation, sourceID: original.id,
                                validateOriginalSource: {
                                    try scope.validate(); self.sourceValidationHook?(original.id)
                                    try self.canvas.session.validateOriginalSource(original)
                                },
                                validatePlanningObservation: { try scope.validate(); try self.canvas.session.validatePlanningObservation(observation) },
                                validateForInput: { try scope.validate(); try self.canvas.session.validateForInput(original) })
                        }
                        return .init(controller: canvas.session, observeRead: { [self] _ in
                            let selected = selectThird ? thirdCanvas : selectSecondary ? secondaryCanvas : canvas
                            runtime.readAnswer = answers[selected.sourceID] ?? runtime.readAnswer
                            return try source(await canvas.session.observeForRead(target: selected.target()))
                        },
                            refreshOriginal: { [self] previous in
                                let original = try canvas.session.source(from: previous.observation)
                                return try source(await canvas.session.refreshOriginalForRead(original))
                            }, refreshForInputPlanning: { [self] previous in
                                if runtime.kind == .report { return previous }
                                let original = try canvas.session.source(from: previous.observation)
                                return try source(await canvas.session.refreshOriginalForInputPlanning(original, authorizeInputPlanning: { try scope.validate() }))
                            }, prepareForReview: { [self] action, identity, previous, frame in
                                try await canvas.session.prepareForReview(action, request: identity.admission(scope: scope), from: previous.observation, frame: frame)
                            }, executeAdmitted: { [self] ticket in
                                do { return .controller(try await canvas.session.execute(ticket)) }
                                catch { return .uncertain("Inert controller execution remained uncertain.") }
                            }, closeOwnedClient: { [self] in closes += 1 })
                    }), inspect: { [self] _, scope in
                        try scope.validate()
                        return .init(boundary: requiresReview ? .review : .ordinary, permitsTaskAuthorizedFocus: false,
                            visualProof: .wholeFrame, validateSemanticContext: { try scope.validate() })
                    })
                }, runBudgetFactory: { [self] in budgets += 1; return TaskRunBudget(activeLimit: 1, now: { [clock] in clock.read() }) })
        }
        func start(_ store: AssistantStore) async throws {
            store.configuration = .init(modelPath: model.path)
            store.draft = "Perform one ordinary navigation in the admitted original editor; preserve all unrelated text."
            let ticket = try #require(store.send(nativeReadRestrictions: [admission]))
            #expect(await ticket.waitForAcknowledgment() == .saved)
            let end = ContinuousClock.now.advanced(by: .seconds(8))
            while store.isRunning { try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
            await store.waitForConversationTaskToSettle()
        }
        func intents() async throws -> [JournalIntent] {
            let core = try await history.journalForTesting(), expected = try await core.scope()
            var cursor: JournalCursor?, values: [JournalIntent] = []
            repeat {
                let page = try await core.page(after: cursor, expectedScope: expected)
                values += page.records.compactMap { row in if case .intent(let intent) = row.event.payload { intent } else { nil } }
                cursor = page.hasLater ? page.cursor : nil
            } while cursor != nil
            return values
        }
        func outcomes() async throws -> [JournalToolOutcome] {
            let core = try await history.journalForTesting(), expected = try await core.scope()
            let page = try await core.page(expectedScope: expected)
            return page.records.compactMap { if case .result(let outcome) = $0.event.payload { outcome } else { nil } }
        }
        func expectNoImageHistory(_ store: AssistantStore, messages: [ModelMessage]) throws {
            let all = String(decoding: try JSONEncoder().encode(messages), as: UTF8.self) + store.activity.map(\.detail).joined()
            for image in runtime.images { #expect(!all.contains(image.base64EncodedString())) }
        }
    }
    @MainActor private final class Runtime: LocalModelRuntime {
        enum Kind { case key, pointer, report }
        var kind = Kind.key, images: [Data] = []
        let secret = "PRIVATE_SOURCE_DETAIL_" + UUID().uuidString
        var readAnswer = "The original synthetic editor is visible."
        var pause: (@MainActor () async -> Void)?
        func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession { Session(self, toolFree: config.tools.isEmpty) }
        @MainActor final class Session: LocalConversationSession {
            unowned let runtime: Runtime
            let toolFree: Bool
            init(_ runtime: Runtime, toolFree: Bool) { self.runtime = runtime; self.toolFree = toolFree }
            func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
                for content in message.contents { if case .imageData(let bytes) = content { runtime.images.append(bytes) } }
                if toolFree { return LiteRTLM.Message(runtime.readAnswer + " " + runtime.secret, role: .model) }
                let text = message.toString
                let expression = try NSRegularExpression(pattern: "observation ([0-9A-F-]{36}), image ([0-9A-F-]{36})")
                let match = try #require(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
                let observation = String(text[try #require(Range(match.range(at: 1), in: text))])
                let image = String(text[try #require(Range(match.range(at: 2), in: text))])
                await runtime.pause?()
                let call: LiteRTLM.ToolCall
                if runtime.kind == .report {
                    call = .init(name: NativeWindowControlTools.observeName, id: "raw-id-reused-in-later-reply",
                        arguments: ["observation_id": observation, "image_id": image,
                            "disposition": "cannot_determine", "detail": runtime.secret])
                } else if runtime.kind == .pointer {
                    call = .init(name: NativeWindowControlTools.pointerName, id: "raw-id-reused-in-later-reply",
                        arguments: ["observation_id": observation, "image_id": image, "kind": "click",
                            "x": 1, "y": 1, "intended_effect": "Use the original marked canvas point"])
                } else {
                    call = .init(name: NativeWindowControlTools.keyName, id: "raw-id-reused-in-later-reply",
                        arguments: ["observation_id": observation, "key": "Left", "intended_effect": "Navigate the original editor once"])
                }
                return .init(contents: [], role: .model, toolCalls: [call])
            }
            nonisolated func cancel() {}
        }
    }
    nonisolated private final class GoalCommitBarrier: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var began = false, released = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return began }
        func pause() { lock.lock(); began = true; lock.unlock(); _ = semaphore.wait(timeout: .now() + 8) }
        func release() { lock.lock(); let signal = !released; released = true; lock.unlock(); if signal { semaphore.signal() } }
    }
    nonisolated private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var value: TimeInterval = 0
        func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ next: TimeInterval) { lock.lock(); value = next; lock.unlock() }
    }
}
