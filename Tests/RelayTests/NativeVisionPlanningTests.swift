import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@preconcurrency import LiteRTLM
@testable import Relay

@MainActor
struct NativeVisionPlanningTests {
    private var messages: [ModelMessage] { [.init(role: "system", content: "Synthetic scoped local image test."),
                                           .init(role: "user", content: "Describe the visible image.")] }

    @Test func boundsImageInMemoryAndPreservesNativePixelTransform() async throws {
        let frame = try await NativeVisionFrame.prepare(image: image(width: 3_200, height: 1_000), observationID: UUID())
        #expect(frame.nativePixels == .init(width: 3_200, height: 1_000))
        #expect(frame.preparedPixels == .init(width: 1_536, height: 480))
        #expect(frame.jpeg.count <= NativeVisionFrame.maximumPreparedBytes && !frame.originalSHA256.isEmpty)
        #expect(try frame.nativePoint(fromPrepared: .init(x: 768, y: 240)) == .init(x: 1_600, y: 500))
        #expect(throws: NativeVisionFailure.invalidImage) { try frame.nativePoint(fromPrepared: .init(x: 1_536, y: 2)) }
        #expect(throws: NativeVisionFailure.invalidImage) { try frame.nativePoint(fromPrepared: .init(x: .nan, y: 2)) }
    }

    @Test func mismatchedImageDimensionsAndNonImagesAreRejected() async throws {
        let valid = try image(width: 8, height: 6)
        for value in [TargetBoundNativeObservation.Image(data: valid.data, mimeType: valid.mimeType, width: 9, height: 6),
                      TargetBoundNativeObservation.Image(data: valid.data, mimeType: "image/jpeg", width: 8, height: 6),
                      TargetBoundNativeObservation.Image(data: Data("not an image".utf8), mimeType: "image/jpeg", width: 8, height: 6)] {
            await #expect(throws: NativeVisionFailure.invalidImage) { try await NativeVisionFrame.prepare(image: value, observationID: UUID()) }
        }
    }

    @Test func imageIsOnlyInTransientNativeMessageAndTextHistoryStaysUnchanged() async throws {
        let (folder, config) = try modelFixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let textRuntime = VisionRuntimeFixture(), visionRuntime = VisionRuntimeFixture()
        let client = LocalModelClient(runtimeFactory: { _, _, _ in textRuntime }, visionRuntimeFactory: { _, _, _ in visionRuntime })
        let frame = try await NativeVisionFrame.prepare(image: image(width: 16, height: 12), observationID: UUID())
        let vision = try NativeVisionPlanningInput(frame: frame, sourceIsCurrent: { true })
        let history = messages
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let serializedBefore = try encoder.encode(history)
        let reply = try await client.complete(messages: history, tools: [], configuration: config, vision: vision)
        #expect(reply.content == "Synthetic local answer." && reply.toolCalls.isEmpty)
        #expect(visionRuntime.initialMessages.count == history.filter { $0.role != "system" }.count)
        #expect(visionRuntime.imagePayloads == [frame.jpeg] && visionRuntime.sentRoles == [.user])
        #expect(textRuntime.imagePayloads.isEmpty)
        #expect(try encoder.encode(history) == serializedBefore)
        #expect(!String(decoding: serializedBefore, as: UTF8.self).contains(frame.jpeg.base64EncodedString()))
        client.unload()
    }

    @Test func textVisionAndTextAgainUseSeparateRuntimeIdentitiesWithoutChangingTextMessages() async throws {
        let (folder, config) = try modelFixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let textRuntime = VisionRuntimeFixture(), visionRuntime = VisionRuntimeFixture()
        var textLoads = 0, visionLoads = 0
        let client = LocalModelClient(runtimeFactory: { _, _, _ in textLoads += 1; return textRuntime },
            visionRuntimeFactory: { _, _, _ in visionLoads += 1; return visionRuntime })
        _ = try await client.complete(messages: messages, tools: [], configuration: config)
        let frame = try await NativeVisionFrame.prepare(image: image(width: 4, height: 3), observationID: UUID())
        let input = try NativeVisionPlanningInput(frame: frame, sourceIsCurrent: { true })
        _ = try await client.complete(messages: messages, tools: [], configuration: config, vision: input)
        _ = try await client.complete(messages: messages, tools: [], configuration: config)
        #expect(textLoads == 2 && visionLoads == 1 && textRuntime.imagePayloads.isEmpty)
        #expect(textRuntime.sentTexts == ["Describe the visible image.", "Describe the visible image."])
        client.unload()
    }

    @Test func staleSourceBeforeLoadAndAfterAnUncooperativeReplyCannotReturnAProposal() async throws {
        let (folder, config) = try modelFixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = VisionRuntimeFixture()
        var current = true, loads = 0
        let client = LocalModelClient(runtimeFactory: nil, visionRuntimeFactory: { _, _, _ in loads += 1; return runtime })
        let frame = try await NativeVisionFrame.prepare(image: image(width: 4, height: 3), observationID: UUID())
        let input = try NativeVisionPlanningInput(frame: frame, sourceIsCurrent: { current })
        current = false
        await #expect(throws: NativeVisionFailure.staleObservation) {
            try await client.complete(messages: messages, tools: [], configuration: config, vision: input)
        }
        #expect(loads == 0)
        current = true
        runtime.beforeReply = { current = false }
        await #expect(throws: NativeVisionFailure.staleObservation) {
            try await client.complete(messages: messages, tools: [], configuration: config, vision: input)
        }
        #expect(loads == 1 && runtime.imagePayloads.count == 1)
        client.unload()
    }

    @Test func actualSchemaAndTextBudgetRejectBeforeLoadingWeights() async throws {
        let (folder, config) = try modelFixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var loads = 0
        let runtime = VisionRuntimeFixture()
        let client = LocalModelClient(runtimeFactory: nil, visionRuntimeFactory: { _, _, _ in loads += 1; return runtime })
        let frame = try await NativeVisionFrame.prepare(image: image(width: 4, height: 3), observationID: UUID())
        let input = try NativeVisionPlanningInput(frame: frame, sourceIsCurrent: { true })
        let large = ToolDefinition(name: "calculate", description: String(repeating: "long schema ", count: 600), parameters: .object([:]))
        await #expect(throws: NativeVisionFailure.textBudget) {
            try await client.complete(messages: messages, tools: [large], configuration: config, vision: input)
        }
        #expect(loads == 0)
        #expect(throws: NativeVisionFailure.textBudget) {
            try NativeVisionPlanningBudget.validate(messages: messages, systemPrompt: "S", tools: [],
                actualNativeSchemaBytes: NativeVisionPlanningBudget.maximumTextBytes, annotation: "native frame")
        }
        client.unload()
    }

    @Test func emptyVisualReplyKeepsTheExistingTypedProtocolRecovery() async throws {
        let (folder, config) = try modelFixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = VisionRuntimeFixture()
        runtime.answer = LiteRTLM.Message("", role: .model)
        let client = LocalModelClient(runtimeFactory: nil, visionRuntimeFactory: { _, _, _ in runtime })
        let frame = try await NativeVisionFrame.prepare(image: image(width: 4, height: 3), observationID: UUID())
        let input = try NativeVisionPlanningInput(frame: frame, sourceIsCurrent: { true })
        do {
            _ = try await client.complete(messages: messages, tools: [], configuration: config, vision: input)
            Issue.record("An empty visual reply must retain the typed empty-response error.")
        } catch ModelProtocolError.emptyResponse {
            // This exact case is consumed by the application's bounded protocol recovery.
        } catch { throw error }
        client.unload()
    }

    @Test func cancellationCancelsNativeImageSessionAndRejectsItsLateReply() async throws {
        let (folder, config) = try modelFixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = VisionRuntimeFixture()
        var waiting: CheckedContinuation<Void, Never>?
        runtime.pauseBeforeReply = { await withCheckedContinuation { waiting = $0 } }
        let client = LocalModelClient(runtimeFactory: nil, visionRuntimeFactory: { _, _, _ in runtime })
        let frame = try await NativeVisionFrame.prepare(image: image(width: 4, height: 3), observationID: UUID())
        let input = try NativeVisionPlanningInput(frame: frame, sourceIsCurrent: { true })
        let request = Task { try await client.complete(messages: messages, tools: [], configuration: config, vision: input) }
        for _ in 0..<200 where waiting == nil { try await Task.sleep(for: .milliseconds(2)) }
        try #require(waiting != nil)
        request.cancel()
        waiting?.resume(); waiting = nil
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(runtime.cancellations.count > 0)
        client.unload()
    }

    private func modelFixture() throws -> (URL, ModelConfiguration) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RelayVisionModel-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = folder.appendingPathComponent("synthetic.litertlm")
        try Data([1]).write(to: model)
        return (folder, ModelConfiguration(modelPath: model.path))
    }

    private func image(width: Int, height: Int) throws -> TargetBoundNativeObservation.Image {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return .init(data: data as Data, mimeType: "image/png", width: width, height: height)
    }
}

@MainActor
private final class VisionRuntimeFixture: LocalModelRuntime {
    var initialMessages: [LiteRTLM.Message] = []
    var imagePayloads: [Data] = []
    var sentTexts: [String] = []
    var sentRoles: [LiteRTLM.Role] = []
    var answer = LiteRTLM.Message("Synthetic local answer.", role: .model)
    var beforeReply: (() -> Void)?
    var pauseBeforeReply: (() async -> Void)?
    let cancellations = VisionCancellationCount()
    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
        initialMessages = config.initialMessages
        return VisionSessionFixture(runtime: self)
    }
}

@MainActor
private final class VisionSessionFixture: LocalConversationSession {
    unowned let runtime: VisionRuntimeFixture
    nonisolated let cancellations: VisionCancellationCount
    init(runtime: VisionRuntimeFixture) { self.runtime = runtime; cancellations = runtime.cancellations }
    func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
        runtime.sentRoles.append(message.role)
        runtime.sentTexts.append(message.toString)
        for content in message.contents { if case .imageData(let data) = content { runtime.imagePayloads.append(data) } }
        runtime.beforeReply?()
        await runtime.pauseBeforeReply?()
        return runtime.answer
    }
    nonisolated func cancel() { cancellations.increment() }
}

nonisolated private final class VisionCancellationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    nonisolated func increment() { lock.lock(); value += 1; lock.unlock() }
    nonisolated var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
