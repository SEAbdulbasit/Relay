import Foundation
import Testing
@testable import Relay

/// Metadata/disposition tests only. No physical input or device/model runtime.
@Suite(.serialized) @MainActor struct OrdinaryGoalEvidenceTests {
    @Test func reportsUnknownDeliveryAndFocusOnlyFactsCannotBecomeGoalSeeds() async throws {
        let rig = NextNativeControlRig()
        let observation = try await rig.read()
        let returned = OwnedNativeComputerUseClient.NativeResult(raw: .object([:]), content: [], isError: false)
        #expect(NativeGoalEffectSeed.canCover(.controller(.readback(native: returned, observation: observation))))
        #expect(!NativeGoalEffectSeed.canCover(.uncertain("Unknown execute throw")))
        #expect(!NativeGoalEffectSeed.canCover(.focusOnly(.restored, reason: "Gesture refused")))
        #expect(!NativeGoalEffectSeed.canCover(.controller(.focusOnly(.alreadyFocused, reason: "No gesture"))))
        #expect(!NativeGoalEffectSeed.canCover(.controller(.textUnchanged(observation: observation, focus: .restored))))
        #expect(!NativeGoalEffectSeed.canCover(.controller(.uncertain(.nativeFailure, observation: observation))))
        #expect(!NativeGoalEffectSeed.canCover(.controller(.readback(native: returned, observation: observation, focus: .uncertain("Unknown focus")))))
        #expect(!NativeGoalEffectSeed.canCover(.controller(.readback(native: returned, observation: observation, focus: .refused("No focus")))))
        let failed = OwnedNativeComputerUseClient.NativeResult(raw: .object([:]), content: [], isError: true)
        #expect(!NativeGoalEffectSeed.canCover(.controller(.readback(native: failed, observation: observation))))
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && rig.textReads == 0)
        rig.session.stop(); await rig.session.drain()
    }

    @Test func originalUnverifiedMetadataSurvivesRevocationAndResumeWithoutAnActionCountCap() throws {
        let task = UUID(), run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
        let coverage = OrdinaryGoalCoverage(logicalTaskID: task)
        let call = ToolCall(id: "provider-id-reused-later", name: "calculate", arguments: ["expression": .string("1+1")])
        let accepted = UUID()
        coverage.recordUnverified(call: call, proposalID: accepted, run: run)
        coverage.recordUnverified(call: call, proposalID: accepted, run: run)
        #expect(coverage.unverifiedCount == 1)
        coverage.recordUnverified(call: call, proposalID: UUID(), run: run)
        #expect(coverage.unverifiedCount == 2)
        coverage.revokeCapabilities()
        let resumed = try AssistantConversationHistory.Run(logicalTaskID: task, predecessor: run, cause: .resume)
        let unavailable = try coverage.begin(unverifiedCount: coverage.unverifiedCount, run: resumed)
        #expect(coverage.unverifiedCount == 2 && unavailable == nil)
        for _ in 0..<1_100 { coverage.recordUnverified(call: call, proposalID: UUID(), run: resumed) }
        #expect(coverage.unverifiedCount == 1_102)
        let newTask = OrdinaryGoalCoverage(logicalTaskID: UUID())
        newTask.recordUnverified(call: call, proposalID: UUID(), run: resumed)
        #expect(newTask.unverifiedCount == 0) // An old run never taints a replacement logical task.
    }
}
