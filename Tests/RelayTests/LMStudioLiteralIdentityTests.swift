import Foundation
import Testing
@testable import Relay

@MainActor struct LMStudioLiteralIdentityTests {
    private let nfc = "caf\u{00e9}"
    private let nfd = "cafe\u{0301}"
    private func configuration(_ id: String) throws -> ModelConfiguration {
        .init(backend: .lmStudio, modelPath: "/SYNTHETIC/preserved.litertlm", computeBackend: "gpu",
            lmStudio: try .init(endpoint: LMStudioEndpoint(), modelID: id))
    }
    @Test func modelConfigurationReceiptAndPickerKeysPreserveLiteralUTF8() throws {
        #expect(nfc == nfd) // The language's comparison is intentionally not the protocol contract.
        #expect(LMStudioProtocolID(nfc) != LMStudioProtocolID(nfd))
        let a = try configuration(nfc), b = try configuration(nfd)
        #expect(a != b && a.lmStudio != b.lmStudio && a.inferenceIdentity != b.inferenceIdentity)
        let aSelection = try #require(a.lmStudio?.selection), bSelection = try #require(b.lmStudio?.selection)
        #expect(aSelection != bSelection)
        let options = [LMStudioModelOption(value: nfc), LMStudioModelOption(value: nfd)]
        #expect(Set(options.map(\.id)).count == 2)
        #expect(LMStudioProtocolID.same(options[1].id.string, nfd))
        #expect(LocalInferenceIdentity.embedded(path: "/" + nfc, compute: "cpu") != .embedded(path: "/" + nfd, compute: "cpu"))
        let restored = try JSONDecoder().decode(ModelConfiguration.self, from: JSONEncoder().encode(b))
        let restoredID = try #require(restored.lmStudio?.modelID)
        #expect(LMStudioProtocolID.same(restoredID, nfd))
    }
    @Test func catalogAllowsByteDistinctIDsAndRejectsOnlyActualDuplicateBytes() async throws {
        let fixture = LMStudioIntegrationFixture(), client = LMStudioClient(transport: fixture.transport)
        await fixture.setModels([nfc, nfd])
        let models = try await client.listModels(endpoint: LMStudioEndpoint())
        #expect(models.map { LMStudioProtocolID($0) } == [LMStudioProtocolID(nfc), LMStudioProtocolID(nfd)])
        await fixture.setModels([nfc, nfc])
        await #expect(throws: LMStudioFailure.malformedResponse) { try await client.listModels(endpoint: LMStudioEndpoint()) }
    }
    @Test func StoreMembershipAndReadinessCannotAcceptAnUnlistedCanonicalAlias() async throws {
        let fixture = LMStudioIntegrationFixture(); await fixture.setModels([nfc])
        let store = AssistantStore(persistenceURL: nil, lmStudioClient: LMStudioClient(transport: fixture.transport))
        store.selectLocalProvider(.lmStudio)
        await store.discoverLMStudioModels()
        store.selectLMStudioModel(nfd)
        #expect(store.configuration.lmStudio?.modelID.isEmpty == true && !store.actionsReady)
        store.configuration = try configuration(nfd)
        await store.refreshModels()
        #expect(!store.actionsReady && store.errorMessage?.contains("not currently listed") == true)
        #expect(await fixture.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func byteOnlyModelChangeInvalidatesIdleReadinessAndInFlightSourceReply() async throws {
        let fixture = LMStudioIntegrationFixture(); await fixture.setModels([nfc, nfd])
        let store = AssistantStore(persistenceURL: nil, lmStudioClient: LMStudioClient(transport: fixture.transport))
        store.configuration = try configuration(nfc); await store.refreshModels()
        #expect(store.actionsReady)
        store.selectLMStudioModel(nfd)
        let selectedID = try #require(store.configuration.lmStudio?.modelID)
        #expect(!store.actionsReady && LMStudioProtocolID.same(selectedID, nfd))
        store.configuration = try configuration(nfc); await store.refreshModels(); await fixture.hold()
        let priorRequests = await fixture.requests.count
        let pending = Task { try await store.auxiliaryText([.init(role: "user", content: "SYNTHETIC source bound to literal model ID")]) }
        try await awaitLMStudioCondition { await fixture.requests.count == priorRequests + 1 }
        // Direct binding edits must be fenced even before a later Save/invalidate hook.
        store.configuration = try configuration(nfd)
        await fixture.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }
    @Test func visionReceiptCannotAuthorizeAByteDistinctCanonicalModelAlias() async throws {
        let probe = try LMStudioVisionProbe.make(), fixture = LMStudioIntegrationFixture()
        await fixture.setProbeAnswer(probe.expectedMarker)
        let client = LMStudioClient(transport: fixture.transport)
        let a = try #require(configuration(nfc).lmStudio?.selection), b = try #require(configuration(nfd).lmStudio?.selection)
        try await client.verifyVision(selection: a, syntheticImage: .init(jpeg: probe.jpeg, annotation: "Synthetic only", validate: {}), expectedMarker: probe.expectedMarker)
        #expect(await client.visionIsVerified(for: a))
        #expect(await client.visionIsVerified(for: b) == false)
        await #expect(throws: LMStudioFailure.visionNotVerified) {
            try await client.complete(messages: [.init(role: "user", content: "SYNTHETIC private frame")], tools: [], selection: b,
                vision: .init(jpeg: probe.jpeg, annotation: "Synthetic only", validate: {}))
        }
        #expect(await fixture.requests.count == 1)
    }
    @Test func historyRequiresExactResultIDAndRetainsTwoByteDistinctCalls() throws {
        let one = ToolCall(id: nfc, name: "calculate", arguments: [:]), two = ToolCall(id: nfd, name: "calculate", arguments: [:])
        let wrong = [ModelMessage(role: "assistant", content: "", toolCalls: [one]),
            .init(role: "tool", content: "synthetic", toolCallID: nfd, toolName: "calculate")]
        #expect(throws: LMStudioFailure.malformedHistory) { try LMStudioWireCodec.canonicalHistory(wrong) }
        let valid = [ModelMessage(role: "assistant", content: "", toolCalls: [one, two]),
            .init(role: "tool", content: "one", toolCallID: nfc, toolName: "calculate"),
            .init(role: "tool", content: "two", toolCallID: nfd, toolName: "calculate")]
        let ordered = try LMStudioWireCodec.canonicalHistory(valid)
        #expect(ordered[0].toolCalls.map { LMStudioProtocolID($0.id) } == [LMStudioProtocolID(nfc), LMStudioProtocolID(nfd)])
        #expect(ordered.dropFirst().compactMap(\.toolCallID).map { LMStudioProtocolID($0) } == [LMStudioProtocolID(nfc), LMStudioProtocolID(nfd)])
    }
    @Test func replyAndPriorIDBookkeepingUsesByteKeysWithoutNormalization() throws {
        func call(_ id: String) -> JSONValue { .object(["id": .string(id), "type": .string("function"),
            "function": .object(["name": .string("calculate"), "arguments": .string("{}")])]) }
        let both = try LMStudioWireCodec.finishReply(content: .null, toolCalls: .array([call(nfc), call(nfd)]), finish: "tool_calls",
            availableTools: ["calculate"], priorCallIDs: [])
        #expect(both.toolCalls.map { LMStudioProtocolID($0.id) } == [LMStudioProtocolID(nfc), LMStudioProtocolID(nfd)])
        let distinct = try LMStudioWireCodec.finishReply(content: .null, toolCalls: .array([call(nfd)]), finish: "tool_calls",
            availableTools: ["calculate"], priorCallIDs: [LMStudioProtocolID(nfc)])
        let distinctID = try #require(distinct.toolCalls.first?.id)
        #expect(LMStudioProtocolID.same(distinctID, nfd))
        #expect(throws: LMStudioFailure.malformedToolCall) {
            try LMStudioWireCodec.finishReply(content: .null, toolCalls: .array([call(nfc)]), finish: "tool_calls",
                availableTools: ["calculate"], priorCallIDs: [LMStudioProtocolID(nfc)])
        }
    }
    @Test func SSECallAndResponseIDsCannotDriftToCanonicalAliases() throws {
        func event(_ response: String, callID: String) throws -> Data {
            let value: JSONValue = .object(["id": .string(response), "choices": .array([.object(["index": .number(0),
                "delta": .object(["tool_calls": .array([.object(["index": .number(0), "id": .string(callID),
                    "function": .object(["name": .string("calculate"), "arguments": .string("")])])])]), "finish_reason": .null])])])
            return Data("data: ".utf8) + (try LMStudioWireCodec.jsonData(value)) + Data("\n\n".utf8)
        }
        var changedCall = LMStudioSSEDecoder(availableTools: ["calculate"])
        try changedCall.feed(event("response", callID: nfc))
        #expect(throws: LMStudioFailure.malformedToolCall) { try changedCall.feed(event("response", callID: nfd)) }
        var changedResponse = LMStudioSSEDecoder(availableTools: ["calculate"])
        try changedResponse.feed(event(nfc, callID: "call"))
        #expect(throws: LMStudioFailure.malformedResponse) { try changedResponse.feed(event(nfd, callID: "call")) }
    }
}
