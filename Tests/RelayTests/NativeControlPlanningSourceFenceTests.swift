import Foundation
import Testing
@testable import Relay

@Suite @MainActor struct NativeControlPlanningSourceFenceTests {
    private enum SyntheticProviderError: Error { case failed }

    @Test(arguments: ["editor", "selection", "value", "style"])
    func planningSourceFenceValidatesTheActualCompositeBeforeAndAfterInference(_ drift: String) async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan()
        try rig.session.validatePlanningObservation(observation)
        #expect(rig.session.isCurrentForPlanning(observation))
        Self.change(drift, rig)
        #expect(throws: (any Error).self) { try rig.session.validatePlanningObservation(observation) }
        #expect(!rig.session.isCurrentForPlanning(observation))
        #expect(rig.commands.isEmpty && rig.textWrites == 0)
    }

    @Test func readOnlyPlanningValidationNeverReadsFocusedEditorValues() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.read()
        try rig.session.validatePlanningObservation(observation)
        #expect(rig.session.isCurrentForPlanning(observation))
        #expect(rig.textReads == 0 && rig.labelReads == 0 && rig.focusCaptures == 0 && rig.insertionCaptures == 0)
    }

    @Test func actualReadOnlyPlanningCatalogOmitsKeyAndTextAndRejectsAnUnadvertisedReply() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.read()
        var calls = 0
        await #expect(throws: (any Error).self) {
            try await NativeWindowControlPlanningPhase.plan(taskID: UUID(), runRevision: 1,
                originalObjective: "Inspect only the original synthetic canvas.", requestedStep: "Read the original window again.",
                observation: observation, session: rig.session, taskIsCurrent: { true }, complete: { _, tools, input in
                    calls += 1; try input.validate()
                    #expect(Set(tools.map(\.name)) == Set([NativeWindowControlTools.observeName, NativeWindowControlTools.pointerName]))
                    return .init(content: "", toolCalls: [.init(id: "unadvertised-key", name: NativeWindowControlTools.keyName,
                        arguments: ["observation_id": .string(observation.snapshot.id.uuidString), "key": .string("Left"),
                            "intended_effect": .string("A model label cannot authorize reading the focused editor")])])
                })
        }
        #expect(calls == 1 && rig.textReads == 0 && rig.labelReads == 0 && rig.commands.isEmpty)
    }

    @Test func actualCompositePlanningCatalogCanAdvertiseOnlyItsQualifiedEditorWrappers() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan()
        let operation = try await NativeWindowControlPlanningPhase.plan(taskID: UUID(), runRevision: 1,
            originalObjective: "Inspect the original authorized editor.", requestedStep: "Propose an ordinary navigation step.",
            observation: observation, session: rig.session, taskIsCurrent: { true }, complete: { _, tools, input in
                try input.validate()
                #expect(Set(tools.map(\.name)) == Set(NativeWindowControlTools.visualDefinitions.map(\.name)))
                return .init(content: "", toolCalls: [.init(id: "accepted-original-key", name: NativeWindowControlTools.keyName,
                    arguments: ["observation_id": .string(observation.snapshot.id.uuidString), "key": .string("Left"),
                        "intended_effect": .string("Navigate in the actual original editor")])])
            })
        #expect(operation.call.id == "accepted-original-key" && operation.frame.observationID == observation.snapshot.id)
        #expect(rig.commands.isEmpty && rig.textWrites == 0)
    }

    @Test(arguments: [false, true])
    func actualModelSuccessAndErrorBothRefuseAChangedCompositeSource(_ providerThrows: Bool) async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan()
        var calls = 0
        do {
            _ = try await NativeWindowControlPlanningPhase.plan(taskID: UUID(), runRevision: 1,
                originalObjective: "Use only this original authorized synthetic editor.", requestedStep: "Propose one ordinary step.",
                observation: observation, session: rig.session, taskIsCurrent: { true }, complete: { _, _, _ in
                    calls += 1; Self.change("style", rig)
                    if providerThrows { throw SyntheticProviderError.failed }
                    return .init(content: "", toolCalls: [.init(id: "late-original-read", name: NativeWindowControlTools.observeName,
                        arguments: ["observation_id": .string(observation.snapshot.id.uuidString)])])
                })
            Issue.record("A changed pre-inference editor/style snapshot survived the reply boundary.")
        } catch is SyntheticProviderError {
            Issue.record("The original provider error must not bypass changed-source validation.")
        } catch { #expect(error is NativeFocusedAXInsertion.Failure || error is NativeControlSession.Failure || error is NativeVisionFailure) }
        #expect(calls == 1 && rig.commands.isEmpty && rig.textWrites == 0)
    }

    @Test func revokedPlanningGrantPreventsPrivateValueReadsOnTheModelErrorPath() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan()
        var readsAtRevocation = -1
        await #expect(throws: NativeControlSession.Failure.unqualifiedEffect) {
            try await NativeWindowControlPlanningPhase.plan(taskID: UUID(), runRevision: 1,
                originalObjective: "Use the original synthetic editor.", requestedStep: "Propose one ordinary step.",
                observation: observation, session: rig.session, taskIsCurrent: { true }, complete: { _, _, _ in
                    rig.planningAuthorized = false; readsAtRevocation = rig.textReads
                    throw SyntheticProviderError.failed
                })
        }
        #expect(readsAtRevocation >= 0 && readsAtRevocation == rig.textReads)
        #expect(rig.commands.isEmpty && rig.textWrites == 0)
    }

    private static func change(_ drift: String, _ rig: NextNativeControlRig) {
        switch drift {
        case "editor": rig.editorVersion += 1
        case "selection": rig.selection = .init(location: 1, length: 2)
        case "value": rig.field = "External field content changed"
        default:
            rig.fieldStorage.addAttribute(NSAttributedString.Key("AXFont"),
                value: ["AXFontName": "Synthetic Bold", "AXFontSize": NSNumber(value: 19)],
                range: NSRange(location: 0, length: rig.fieldStorage.length))
        }
    }
}
