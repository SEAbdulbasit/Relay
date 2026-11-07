import AppKit
import Foundation
import Testing
@testable import Relay

/// Requires the ignored registered-tool integration. Opt-in only; not run yet.
/// Production Store, native reader, local text/vision inference and independent
/// owned-window oracle. No input, source grants, personal apps or permission UI.
@Suite(.serialized)
@MainActor
struct NativeWindowTaskModelIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_WINDOW_TASK_MODEL_TEST"] == "1"
        && ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"] != nil), .timeLimit(.minutes(5)))
    func ordinaryTaskReadsUnknownMarkerAndWritesOneExactArtifactThroughRegisteredNativeTool() async throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"])
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_NATIVE_VISION_CANVAS": "1"]) { fixture in
            let original = try oracle(fixture)
            let expected = try #require(original.visionMarker)
            let artifactFolder = FileManager.default.temporaryDirectory.appending(path: "native-read-artifact-" + UUID().uuidString,
                directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: artifactFolder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: artifactFolder) }
            let artifact = artifactFolder.appending(path: "observed-code.txt")
            // Qualify the independent source boundary first. This model-free
            // probe is closed before the ordinary task's owned connection opens.
            let native = try await OwnedNativeComputerUseClient.open(runtime: .discover())
            let observer = TargetBoundNativeObservation(client: native, sessionIsActive: { true })
            do {
                let snapshot = try await observer.observe(observer.prepare(application: fixture.application))
                try #require(snapshot.images.count == 1 && !snapshot.text.contains(expected),
                    "The marker must require real pixels, not AX text or a prompt value.")
                observer.stop(); await observer.drain()
            } catch { observer.stop(); await observer.drain(); throw error }

            let client = LocalModelClient()
            var generations = 0, readRequests = 0, writeRequests = 0
            var firstInput = "", receivedReadInterpretation = false
            let store = AssistantStore(persistenceURL: nil, complete: { messages, tools, configuration in
                try fixture.requireExclusiveProcess()
                generations += 1
                guard generations <= 8 else { throw RelayError.message("Native read task exceeded eight bounded planner turns.") }
                try #require(tools.contains { $0.name == NativeWindowReadTool.name })
                try #require(Set(tools.map(\.name)) == Set((MacTools.definitions + [NativeWindowReadTool.definition]).map(\.name)))
                if generations == 1 {
                    firstInput = String(decoding: try JSONEncoder().encode(messages), as: UTF8.self)
                    try #require(!firstInput.contains(expected), "The independent answer must not be supplied to the planner.")
                }
                for message in messages where message.role == "tool" && message.toolName == NativeWindowReadTool.name {
                    if let result = try? JSONDecoder().decode(ToolResult.self, from: Data(message.content.utf8)),
                       result.summary.contains(expected) { receivedReadInterpretation = true }
                }
                let reply = try await client.complete(messages: messages, tools: tools, configuration: configuration)
                try Task.checkCancellation()
                try fixture.requireExclusiveProcess()
                for call in reply.toolCalls {
                    guard [NativeWindowReadTool.name, "observe_app", "write_file"].contains(call.name) else {
                        throw RelayError.message("The model proposed a call outside the owned native read/artifact task. Nothing from that reply was dispatched.")
                    }
                    try ToolPolicy.validate(call, against: tools)
                    if call.name == "write_file" {
                        writeRequests += 1
                        guard writeRequests == 1, call.arguments["path"]?.string == artifact.path,
                              call.arguments["content"]?.string?.utf8.elementsEqual(expected.utf8) == true else {
                            throw RelayError.message("The proposed artifact did not contain the exact independently observed code at the one owned destination. Nothing from that reply was dispatched.")
                        }
                    } else {
                        guard call.arguments["bundle_id"]?.string == AccessibilityCheckRunner.fixtureBundleID else {
                            throw RelayError.message("The model proposed reading another app. Nothing from that reply was dispatched.")
                        }
                    }
                    if call.name == NativeWindowReadTool.name {
                        readRequests += 1
                        guard readRequests <= 3 else { throw RelayError.message("Native read task exceeded three explicit reads.") }
                    }
                }
                return reply
            }, modelClient: client)
            defer { store.stop(); client.unload() }
            store.configuration = .init(modelPath: modelPath,
                computeBackend: ProcessInfo.processInfo.environment["RELAY_GEMMA_TEST_BACKEND"] ?? "gpu",
                model: ProcessInfo.processInfo.environment["RELAY_GEMMA_TEST_MODEL_LABEL"] ?? "Gemma 4 E4B")
            store.grants = [.init(path: artifactFolder.path, writable: true)]
            store.draft = """
                Only inspect the already-running Relay Native Vision Fixture, bundle \(AccessibilityCheckRunner.fixtureBundleID).
                Read and report the exact character code drawn in its window. It is not in accessible text, so use the available local native-window visual read.
                Then save only that exact code, with no newline or extra text, to \(artifact.path). This one new text file is the requested artifact.
                Do not list, open or inspect another app. Do not click, type, drag, change permissions, write another file or perform UI input.
                """
            let began = ContinuousClock.now
            // Ordinary main-composer submission: no Sidekick context or fixture
            // admission override. Default task authority resolves the real app.
            store.send()
            while store.isRunning && began.duration(to: .now) < .seconds(250) {
                try await Task.sleep(for: .milliseconds(50))
            }
            let timedOut = store.isRunning
            if timedOut { store.stop() }
            #expect(!timedOut && store.errorMessage == nil)
            #expect(readRequests > 0 && receivedReadInterpretation)
            #expect(writeRequests == 1)
            #expect(try Data(contentsOf: artifact) == Data(expected.utf8))
            #expect(store.messages.last(where: { $0.role == "assistant" })?.text.contains(expected) == true)
            #expect(store.pendingReview == nil)
            let final = try oracle(fixture)
            #expect(final.visionMarker?.utf8.elementsEqual(expected.utf8) == true)
            #expect(final.input.isEmpty && final.result == "Not applied" && final.clickCount == 0)
            #expect(!store.activity.contains { ["set_value", "press_control", "scroll_control"].contains($0.name) })
            #expect(store.activity.filter { $0.name == "write_file" && $0.status == "verified" }.count == 1)
            let elapsed = began.duration(to: .now).components
            print("Native ordinary read/artifact workflow: generations=\(generations), explicitVisualReads=\(readRequests), artifactWrites=\(writeRequests), sourceMarkerAbsentFromInitialContext=\(!firstInput.contains(expected)), exactFinalMarker=\(store.messages.last?.text.contains(expected) == true), UIInputEffects=0, seconds=\(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18).")
        }
    }

    private struct Oracle: Decodable {
        let launchToken: String
        let visionMarker: String?
        let input: String
        let result: String
        let clickCount: Int
    }
    private func oracle(_ fixture: DesktopFixtureProcess) throws -> Oracle {
        try fixture.requireExclusiveProcess()
        let state = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: fixture.oracleURL))
        try #require(state.launchToken == fixture.token)
        return state
    }
}
