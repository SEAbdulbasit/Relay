import AppKit
import Foundation
import ImageIO
import Testing
@testable import Relay

/// All images are locally rendered synthetic pixels. No model, app capture,
/// screen permission, real endpoint or action dispatcher participates.
@MainActor struct LMStudioVisionRoutingTests {
    @MainActor private final class Source { var current = true; var validations = 0 }
    @MainActor private final class ProbeQueue {
        var values: [LMStudioVisionProbe]
        init(_ values: [LMStudioVisionProbe]) { self.values = values }
        func next() throws -> LMStudioVisionProbe {
            guard !values.isEmpty else { throw LMStudioFailure.visionProbeFailed }
            return values.removeFirst()
        }
    }
    private func configuration(port: Int = 1234) throws -> ModelConfiguration {
        .init(backend: .lmStudio, lmStudio: try .init(endpoint: LMStudioEndpoint(port: port), modelID: "synthetic-server-model"))
    }
    private func imageURLs(_ request: URLRequest) throws -> [String] {
        let payload = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        guard case .array(let messages) = payload.object?["messages"] else { return [] }
        return messages.flatMap { message -> [String] in
            guard case .array(let content) = message.object?["content"] else { return [] }
            return content.compactMap { $0.object?["image_url"]?.object?["url"]?.string }
        }
    }
    private func textParts(_ request: URLRequest) throws -> String {
        let payload = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        guard case .array(let messages) = payload.object?["messages"] else { return "" }
        return messages.flatMap { message -> [String] in
            if let text = message.object?["content"]?.string { return [text] }
            guard case .array(let content) = message.object?["content"] else { return [] }
            return content.compactMap { $0.object?["text"]?.string }
        }.joined(separator: "\n")
    }
    @Test func markerRendererProducesFreshBoundedRealJPEGWithoutPromptMetadata() throws {
        let one = try LMStudioVisionProbe.make(), two = try LMStudioVisionProbe.make()
        #expect(one.expectedMarker.count == 8 && one.expectedMarker != two.expectedMarker && one.jpeg != two.jpeg)
        #expect(one.jpeg.count <= LMStudioVisionAttachment.maximumJPEGBytes)
        let source = try #require(CGImageSourceCreateWithData(one.jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == LMStudioVisionProbe.width)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == LMStudioVisionProbe.height)
        let type = try #require(CGImageSourceGetType(source))
        #expect(type as String == "public.jpeg")
    }
    @Test func syntheticProbePrecedesPrivateImageAndNeverPromptsItsSecretOrFilename() async throws {
        let probe = try LMStudioVisionProbe.make(), userImage = try LMStudioVisionProbe.make()
        let fixture = LMStudioIntegrationFixture(); await fixture.setProbeAnswer(probe.expectedMarker)
        let server = LMStudioClient(transport: fixture.transport)
        let router = LocalInferenceRouter(server: server, visionProbeFactory: { probe })
        let answer = try await router.inspect(.init(jpeg: userImage.jpeg, label: "PRIVATE-FILENAME-MUST-STAY-LOCAL"),
            question: "Describe the synthetic image.", configuration: configuration(), sourceIsCurrent: { true })
        #expect(answer == "Synthetic endpoint answer.")
        let requests = await fixture.requests
        try #require(requests.count == 2)
        #expect(try imageURLs(requests[0]) == ["data:image/jpeg;base64," + probe.jpeg.base64EncodedString()])
        #expect(try imageURLs(requests[1]) == ["data:image/jpeg;base64," + userImage.jpeg.base64EncodedString()])
        #expect(try !textParts(requests[0]).contains(probe.expectedMarker))
        #expect(try requests.allSatisfy { !(try textParts($0)).contains("PRIVATE-FILENAME-MUST-STAY-LOCAL") })
        let receiptSelection = try #require(configuration().lmStudio?.selection)
        #expect(await server.visionIsVerified(for: receiptSelection))
    }
    @Test func wrongMarkerReturnsNoPrivateImageAndLeavesNoVisionReceipt() async throws {
        let probe = try LMStudioVisionProbe.make(), privateImage = try LMStudioVisionProbe.make()
        let fixture = LMStudioIntegrationFixture(), server = LMStudioClient(transport: fixture.transport)
        let router = LocalInferenceRouter(server: server, visionProbeFactory: { probe })
        await #expect(throws: LMStudioFailure.visionProbeFailed) {
            try await router.inspect(.init(jpeg: privateImage.jpeg, label: "synthetic-private"), question: "Describe synthetic pixels",
                configuration: configuration(), sourceIsCurrent: { true })
        }
        let requests = await fixture.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(try imageURLs(request) == ["data:image/jpeg;base64," + probe.jpeg.base64EncodedString()])
        let receiptSelection = try #require(configuration().lmStudio?.selection)
        #expect(await server.visionIsVerified(for: receiptSelection) == false)
    }
    @Test func sourceRevocationDuringProbePreventsPrivateSendAndKeepsLeaseUntilDrain() async throws {
        let probe = try LMStudioVisionProbe.make(), fixture = LMStudioIntegrationFixture(), source = Source()
        await fixture.setProbeAnswer(probe.expectedMarker); await fixture.hold()
        let router = LocalInferenceRouter(server: LMStudioClient(transport: fixture.transport), visionProbeFactory: { probe })
        let selected = try configuration()
        let pending = Task { try await router.inspect(.init(jpeg: probe.jpeg, label: "synthetic"), question: "Describe synthetic image",
            configuration: selected, sourceIsCurrent: { source.current }) }
        try await awaitLMStudioCondition { await fixture.requests.count == 1 }
        source.current = false
        let other = router.fork()
        await #expect(throws: LocalInferenceFailure.busy) {
            try await other.complete(messages: [.init(role: "user", content: "SYNTHETIC unrelated")], tools: [], configuration: selected)
        }
        await fixture.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        await router.drain(); #expect(await fixture.requests.count == 1)
    }
    @Test func modelSwitchDuringProbeRejectsItsLateVerdictWithoutPrivateSend() async throws {
        let probe = try LMStudioVisionProbe.make(), fixture = LMStudioIntegrationFixture()
        await fixture.setProbeAnswer(probe.expectedMarker); await fixture.hold()
        let server = LMStudioClient(transport: fixture.transport), router = LocalInferenceRouter(server: server, visionProbeFactory: { probe })
        let selected = try configuration()
        let pending = Task { try await router.inspect(.init(jpeg: probe.jpeg, label: "synthetic"), question: "Describe synthetic image",
            configuration: selected, sourceIsCurrent: { true }) }
        try await awaitLMStudioCondition { await fixture.requests.count == 1 }
        router.selectionDidChange(try configuration(port: 2345))
        await fixture.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        await router.drain()
        #expect(await fixture.requests.count == 1)
        let receiptSelection = try #require(selected.lmStudio?.selection)
        #expect(await server.visionIsVerified(for: receiptSelection) == false)
    }
    @Test func explicitFailedRecheckRevokesAnEarlierSuccessfulReceipt() async throws {
        let probe = try LMStudioVisionProbe.make(), fixture = LMStudioIntegrationFixture()
        await fixture.setProbeAnswer(probe.expectedMarker)
        let server = LMStudioClient(transport: fixture.transport), router = LocalInferenceRouter(server: server, visionProbeFactory: { probe })
        let selected = try configuration()
        try await router.checkVision(configuration: selected)
        let priorSelection = try #require(selected.lmStudio?.selection)
        #expect(await server.visionIsVerified(for: priorSelection))
        await fixture.setProbeAnswer("WRONG")
        await #expect(throws: LMStudioFailure.visionProbeFailed) { try await router.checkVision(configuration: selected) }
        let receiptSelection = try #require(selected.lmStudio?.selection)
        #expect(await server.visionIsVerified(for: receiptSelection) == false)
        #expect(await fixture.requests.count == 2)
    }
    @Test func actualNativeVisionCapabilityRoutesStructuredPlanningWithoutExecutingAnAction() async throws {
        let probe = try LMStudioVisionProbe.make(), userImage = try LMStudioVisionProbe.make(), source = Source()
        let fixture = LMStudioIntegrationFixture(); await fixture.setProbeAnswer(probe.expectedMarker); await fixture.setMode(.calculate)
        let router = LocalInferenceRouter(server: LMStudioClient(transport: fixture.transport), visionProbeFactory: { probe })
        let frame = try await NativeVisionFrame.prepare(image: .init(data: userImage.jpeg, mimeType: "image/jpeg",
            width: LMStudioVisionProbe.width, height: LMStudioVisionProbe.height), observationID: UUID())
        let input = try NativeVisionPlanningInput(frame: frame, sourceIsCurrent: { source.current })
        let tool = ToolDefinition(name: "calculate", description: "Synthetic planning only", parameters: .object(["type": .string("object")]))
        let reply = try await router.complete(messages: [.init(role: "user", content: "SYNTHETIC planning only")], tools: [tool],
            configuration: configuration(), vision: input)
        #expect(reply.toolCalls.count == 1 && reply.toolCalls[0].name == "calculate")
        #expect(await fixture.requests.count == 2)
        source.current = false
        await #expect(throws: NativeVisionFailure.staleObservation) {
            try await router.complete(messages: [.init(role: "user", content: "SYNTHETIC stale")], tools: [tool], configuration: configuration(), vision: input)
        }
        #expect(await fixture.requests.count == 2)
    }
    @Test func privateImageSourceIsRecheckedAfterEncodingBeforeTransportOpen() async throws {
        let probe = try LMStudioVisionProbe.make(), fixture = LMStudioIntegrationFixture(), source = Source()
        await fixture.setProbeAnswer(probe.expectedMarker)
        let client = LMStudioClient(transport: fixture.transport), selected = try #require(configuration().lmStudio?.selection)
        try await client.verifyVision(selection: selected, syntheticImage: .init(jpeg: probe.jpeg, annotation: "Synthetic only", validate: {}), expectedMarker: probe.expectedMarker)
        let privateAttachment = LMStudioVisionAttachment(jpeg: probe.jpeg, annotation: "Synthetic user frame", validate: {
            source.validations += 1
            guard source.validations < 2 else { throw CancellationError() }
        })
        await #expect(throws: CancellationError.self) {
            try await client.complete(messages: [.init(role: "user", content: "SYNTHETIC private frame")], tools: [], selection: selected, vision: privateAttachment)
        }
        let requests = await fixture.requests
        #expect(source.validations == 2 && requests.count == 1)
    }
    @Test func sourceRevokedWhilePrivateInferenceIsPendingDiscardsItsLateAnswer() async throws {
        let probe = try LMStudioVisionProbe.make(), fixture = LMStudioIntegrationFixture(), source = Source()
        await fixture.setProbeAnswer(probe.expectedMarker)
        let router = LocalInferenceRouter(server: LMStudioClient(transport: fixture.transport), visionProbeFactory: { probe })
        let selected = try configuration()
        try await router.checkVision(configuration: selected)
        await fixture.hold()
        let pending = Task { try await router.inspect(.init(jpeg: probe.jpeg, label: "synthetic"), question: "Describe synthetic image",
            configuration: selected, sourceIsCurrent: { source.current }) }
        try await awaitLMStudioCondition { await fixture.requests.count == 2 }
        source.current = false; await fixture.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }
    @Test func cancellationDuringProbeKeepsLeaseUntilDrainAndCannotEnableALateReceipt() async throws {
        let probe = try LMStudioVisionProbe.make(), fixture = LMStudioIntegrationFixture()
        await fixture.setProbeAnswer(probe.expectedMarker); await fixture.hold()
        let server = LMStudioClient(transport: fixture.transport), router = LocalInferenceRouter(server: server, visionProbeFactory: { probe })
        let selected = try configuration()
        let pending = Task { try await router.inspect(.init(jpeg: probe.jpeg, label: "synthetic"), question: "Describe synthetic image",
            configuration: selected, sourceIsCurrent: { true }) }
        try await awaitLMStudioCondition { await fixture.requests.count == 1 }
        pending.cancel()
        let other = router.fork()
        await #expect(throws: LocalInferenceFailure.busy) {
            try await other.complete(messages: [.init(role: "user", content: "SYNTHETIC unrelated")], tools: [], configuration: selected)
        }
        await fixture.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        await router.drain()
        let receiptSelection = try #require(selected.lmStudio?.selection)
        #expect(await server.visionIsVerified(for: receiptSelection) == false)
        #expect(await fixture.requests.count == 1)
    }
    @Test func privateVisionErrorRevokesCachedVerdictAndRetryProbesBeforePrivateInput() async throws {
        let first = try LMStudioVisionProbe.make(), second = try LMStudioVisionProbe.make(), userImage = try LMStudioVisionProbe.make()
        let probes = ProbeQueue([first, second]), fixture = LMStudioIntegrationFixture()
        await fixture.setProbeAnswer(first.expectedMarker)
        let server = LMStudioClient(transport: fixture.transport), router = LocalInferenceRouter(server: server, visionProbeFactory: { try probes.next() })
        let selected = try configuration(), receiptSelection = try #require(selected.lmStudio?.selection)
        try await router.checkVision(configuration: selected)
        #expect(await server.visionIsVerified(for: receiptSelection))
        await fixture.failNextReply()
        await #expect(throws: LMStudioFailure.unavailable) {
            try await router.inspect(.init(jpeg: userImage.jpeg, label: "synthetic-private"), question: "Describe synthetic image",
                configuration: selected, sourceIsCurrent: { true })
        }
        #expect(await server.visionIsVerified(for: receiptSelection) == false)
        await fixture.setProbeAnswer(second.expectedMarker)
        let answer = try await router.inspect(.init(jpeg: userImage.jpeg, label: "synthetic-private"), question: "Describe synthetic image",
            configuration: selected, sourceIsCurrent: { true })
        #expect(answer == "Synthetic endpoint answer.")
        let requests = await fixture.requests
        try #require(requests.count == 4)
        #expect(try imageURLs(requests[0]) == ["data:image/jpeg;base64," + first.jpeg.base64EncodedString()])
        #expect(try imageURLs(requests[1]) == ["data:image/jpeg;base64," + userImage.jpeg.base64EncodedString()])
        #expect(try imageURLs(requests[2]) == ["data:image/jpeg;base64," + second.jpeg.base64EncodedString()])
        #expect(try imageURLs(requests[3]) == ["data:image/jpeg;base64," + userImage.jpeg.base64EncodedString()])
    }
    @Test func imageControllerReachesSelectedEndpointWithoutNativeLoadOrChatDraftChanges() async throws {
        let probe = try LMStudioVisionProbe.make(), userImage = try LMStudioVisionProbe.make(), fixture = LMStudioIntegrationFixture()
        await fixture.setProbeAnswer(probe.expectedMarker)
        var nativeLoads = 0
        let store = AssistantStore(persistenceURL: nil, modelClient: LocalModelClient(runtimeFactory: { _, _, _ in
            nativeLoads += 1; throw CancellationError()
        }), lmStudioClient: LMStudioClient(transport: fixture.transport), lmStudioVisionProbeFactory: { probe })
        store.configuration = try configuration(); store.draft = "Keep my unrelated draft."
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-owned-vision-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "PRIVATE-FILENAME.jpg"); try userImage.jpeg.write(to: file)
        store.imageInspection.loadFile(file)
        try await awaitLMStudioCondition { !store.imageInspection.isBusy }
        store.imageInspection.inspect(configuration: store.configuration, textModelIsLoaded: false)
        try await awaitLMStudioCondition { !store.imageInspection.isBusy }
        #expect(store.imageInspection.answer == "Synthetic endpoint answer." && nativeLoads == 0)
        #expect(store.draft == "Keep my unrelated draft." && store.messages.isEmpty)
        let requests = await fixture.requests
        #expect(requests.count == 2)
        #expect(try requests.allSatisfy { !(try textParts($0)).contains("PRIVATE-FILENAME") })
    }
}
