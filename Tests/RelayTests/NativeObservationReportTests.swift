import Foundation
import Testing
@preconcurrency import LiteRTLM
@testable import Relay

@Suite @MainActor struct NativeObservationReportTests {
    @Test(arguments: NativeObservationReport.Kind.allCases)
    func everyTerminalDispositionIsBoundedUnverifiedDataWithGenericSafeCallbacks(_ kind: NativeObservationReport.Kind) throws {
        let marker = "Synthetic private detail: cafe\u{301} 🌍"
        let report = try NativeObservationReport(kind: kind, detail: marker)
        #expect(!report.genericFact.verified && !report.genericFact.evidence.contains(marker))
        #expect(!report.genericFact.summary.contains(marker))
        var validations = 0
        let result = try report.authorizedResult { validations += 1 }
        #expect(validations == 2 && !result.verified && result.evidence.contains(marker))
        #expect(throws: NativeVisualTaskFailure.staleTask) {
            try report.authorizedResult { throw NativeVisualTaskFailure.staleTask }
        }
    }
    @Test(arguments: ["", "   ", "bad\nline", "bad\u{0}value", String(repeating: "x", count: 513), String(repeating: "🌍", count: 129)])
    func malformedOrOversizedDetailIsRefusedWithoutTruncation(_ detail: String) {
        #expect(throws: (any Error).self) { try NativeObservationReport(kind: .unavailable, detail: detail) }
    }
    @Test func boundary512ByteDetailIsAcceptedWithoutPretendingGoalVerification() throws {
        let report = try NativeObservationReport(kind: .appearsSatisfied, detail: String(repeating: "a", count: 512))
        #expect(!report.genericFact.verified)
        #expect(!(try report.authorizedResult {}).verified)
    }
    @Test(arguments: ["refresh", "appears_satisfied", "unavailable", "cannot_determine"])
    func finiteWrapperBindsActualOriginalObservationAndImage(_ disposition: String) async throws {
        let rig = NextNativeControlRig(), observation = try await rig.read(), frame = try await rig.frame(observation)
        var args: [String: JSONValue] = ["observation_id": .string(observation.snapshot.id.uuidString),
            "image_id": .string(frame.id.uuidString), "disposition": .string(disposition)]
        if disposition != "refresh" { args["detail"] = .string("Synthetic model report only") }
        let reply = ModelReply(content: "", toolCalls: [.init(id: "exact-provider-id", name: NativeWindowControlTools.observeName, arguments: args)])
        let (call, proposal) = try NativeWindowControlTools.decode(reply, observationID: observation.snapshot.id, frame: frame)
        #expect(call.id == "exact-provider-id")
        switch proposal {
        case .observeOriginal: #expect(disposition == "refresh")
        case .report(let report): #expect(report.kind.rawValue == disposition && !report.genericFact.verified)
        case .input: Issue.record("An observation disposition cannot manufacture input.")
        }
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && rig.textReads == 0)
    }
    @Test(arguments: ["missing", "unknown", "refresh-detail", "no-detail", "wrong-image", "old-observation", "extra-verified", "empty-detail"])
    func malformedDispositionCannotBecomeInputOrAnImplicitRefresh(_ fault: String) async throws {
        let rig = NextNativeControlRig(), observation = try await rig.read(), frame = try await rig.frame(observation)
        var args: [String: JSONValue] = ["observation_id": .string(observation.snapshot.id.uuidString),
            "image_id": .string(frame.id.uuidString), "disposition": .string("unavailable"), "detail": .string("Bounded synthetic detail")]
        switch fault {
        case "missing": args.removeValue(forKey: "disposition")
        case "unknown": args["disposition"] = .string("completed_and_verified")
        case "refresh-detail": args["disposition"] = .string("refresh")
        case "no-detail": args.removeValue(forKey: "detail")
        case "wrong-image": args["image_id"] = .string(UUID().uuidString)
        case "old-observation": args["observation_id"] = .string(UUID().uuidString)
        case "extra-verified": args["verified"] = .bool(true)
        default: args["detail"] = .string("")
        }
        let reply = ModelReply(content: "", toolCalls: [.init(name: NativeWindowControlTools.observeName, arguments: args)])
        #expect(throws: (any Error).self) { try NativeWindowControlTools.decode(reply, observationID: observation.snapshot.id, frame: frame) }
        #expect(rig.commands.isEmpty && rig.textWrites == 0)
    }
    @Test func registryUsesOnlyFourFiniteVisionWrappersAndTheActualSerializedSchemaBudget() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan(), frame = try await rig.frame(observation)
        let tools = NativeWindowControlTools.visualDefinitions
        #expect(tools.count == 4 && NativeWindowControlTools.observeName == "native_observation")
        #expect(!LiteRTLM.RelayNativeTools.supportedNames.contains("native_observe_original"))
        let manager = LiteRTLM.ToolManager(tools: try LiteRTLM.RelayNativeTools.makeTools(named: tools.map(\.name)))
        try NativeVisionPlanningBudget.validate(messages: [.init(role: "user", content: "Inspect the original synthetic step.")],
            systemPrompt: "Propose only ordinary data.", tools: tools,
            actualNativeSchemaBytes: manager.toolsJsonDescription.utf8.count, annotation: frame.annotation)
        let response = LiteRTLM.Message(contents: [], role: .model, toolCalls: [
            LiteRTLM.ToolCall(name: NativeWindowControlTools.observeName, id: "original-native-id",
                arguments: ["observation_id": "original", "image_id": "image", "disposition": "unavailable", "detail": "synthetic"])
        ])
        let parsed = try LocalModelClient.parseReply(response, availableTools: [NativeWindowControlTools.observeName])
        #expect(parsed.toolCalls.first?.name == NativeWindowControlTools.observeName)
    }
}
