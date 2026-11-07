import Foundation
import Testing
@testable import Relay

@MainActor
struct NativeReadFailureTests {
    @Test func providerFailureRetainsBoundedTechnicalTextWithoutImagesRawObjectsOrSourceBodies() throws {
        let body = "PRIVATE_APP_BODY_MUST_NOT_APPEAR"
        let image = "PRIVATE_IMAGE_BASE64_MUST_NOT_APPEAR"
        let content: [JSONValue] = [
            .object(["type": .string("text"), "text": .string("ScreenCaptureKit failed -3811.\n<app_state>\(body)</app_state>")]),
            .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(image)]),
            .object(["type": .string("resource"), "text": .string(body)])
        ]
        let result = OwnedNativeComputerUseClient.NativeResult(raw: .object([
            "content": .array(content), "private_source": .string(body), "structuredContent": .object([
                "code": .number(-3811), "kind": .string("capture"), "stage": .string("state"), "private": .string(body)])
        ]), content: content, isError: true)
        let failure = NativeReadProviderError(result: result)
        #expect(failure.detail.contains("ScreenCaptureKit failed -3811"))
        #expect(failure.detail.contains("code=-3811") && failure.detail.contains("stage=state"))
        #expect(failure.detail.utf8.count <= NativeProviderFailureText.maximumBytes)
        #expect(!failure.localizedDescription.contains(body) && !failure.localizedDescription.contains(image))
        #expect(!failure.localizedDescription.contains("private_source"))
        let success = OwnedNativeComputerUseClient.NativeResult(raw: result.raw, content: content, isError: false)
        #expect(NativeProviderFailureText.detail(success) == nil, "Successful source text cannot be relabelled as an error.")
    }

    @Test func hugeJsonImageLookingTextAndControlBytesCannotDumpANativeResult() {
        let raw = #"{"content":[{"type":"image","data":"PRIVATE_PAYLOAD"}],"message":"Fresh state is required","private":"SECRET"}"#
        let content: [JSONValue] = [.object(["type": .string("text"), "text": .string(raw)]),
            .object(["type": .string("text"), "text": .string("data:image/png;base64,PRIVATE_IMAGE")]),
            .object(["type": .string("text"), "text": .string(String(repeating: "A", count: 500))]),
            .object(["type": .string("text"), "text": .string("Read failed\u{0}\u{1b}. " + String(repeating: "bounded detail ", count: 400))])]
        let value = NativeReadProviderError(result: .init(raw: .object([:]), content: content, isError: true))
        #expect(value.detail.contains("Fresh state is required") && value.detail.contains("Read failed"))
        #expect(value.detail.utf8.count <= 1024)
        #expect(!value.detail.contains("PRIVATE_") && !value.detail.contains("SECRET") && !value.detail.contains("\u{0}"))
    }

    @Test func observerFailuresHaveSpecificActionableReadFeedback() {
        let failures: [TargetBoundNativeObservation.Failure] = [.inactiveSession, .stopped, .busy, .staleRequest,
            .ambiguousApplication, .unavailableWindow, .changedTarget, .malformedHeader, .wrongApplication,
            .wrongWindow, .nativeError, .noUsableState]
        #expect(Set(failures.map(\.localizedDescription)).count == failures.count)
        #expect(failures.allSatisfy { !$0.localizedDescription.contains("couldn’t be completed") && $0.localizedDescription.utf8.count < 512 })
    }

    @Test func ordinaryNativeFailureDoesNotDisableLaterExplicitReads() async throws {
        var failing = true, captures = 0, closed = 0
        let observer = TargetBoundNativeObservation(backend: .init(capture: { _, _ in
            captures += 1
            if failing {
                let content: [JSONValue] = [.object(["type": .string("text"), "text": .string("Synthetic capture unavailable -3811; inspect state again.")])]
                return .init(raw: .object([:]), content: content, isError: true)
            }
            return successfulState()
        }, close: { closed += 1 }), sessionIsActive: { true })
        let preparation = preparation()
        do {
            _ = try await observer.observe(observer.prepare(preparation))
            Issue.record("A provider failure cannot publish native state.")
        } catch let error as NativeReadProviderError {
            #expect(error.detail.contains("-3811"))
        }
        #expect(observer.latest == nil && captures == 1 && closed == 0)
        failing = false
        let fresh = try await observer.observe(observer.prepare(preparation))
        #expect(observer.isCurrent(fresh) && captures == 2 && closed == 0)
        observer.stop(); await observer.drain()
    }

    @Test func deadReadConnectionIsReplacedOnlyOnTheNextExplicitRead() async throws {
        var active = true, factories = 0, captures = 0, closes = 0
        let application = preparation().application
        let owner = NativeWindowTaskAdapter.Ownership(taskID: UUID(), isCurrent: { active },
            admitApplication: { _ in .init(application: application, validate: {}) })
        let service = NativeWindowReadService(ownership: owner, makeBackend: { _ in
            factories += 1
            let isFirst = factories == 1
            let observer = TargetBoundNativeObservation(backend: .init(capture: { _, _ in
                captures += 1
                if isFirst { throw OwnedNativeComputerUseClient.Failure.closed }
                return successfulState()
            }, close: { closes += 1 }), sessionIsActive: { active })
            return .init(initial: { _ in
                let snapshot = try await observer.observe(observer.prepare(preparation()))
                return .init(snapshot: snapshot, isCurrent: { observer.isCurrent(snapshot) }, refreshOriginal: nil)
            }, stop: { observer.stop() }, drain: { await observer.drain() })
        }, complete: { _ in .init(content: "Synthetic readable state.", toolCalls: []) })
        let call = ToolCall(name: NativeWindowReadTool.name, arguments: ["bundle_id": .string(application.bundleID), "question": .string("Read the chosen window.")])
        await #expect(throws: NativeReadTransportError.self) { try await service.read(call, objective: "Read only this window.") }
        #expect(factories == 1 && captures == 1 && closes == 1,
            "No automatic replay or replacement read occurs inside the failed request.")
        let result = try await service.read(ToolCall(name: call.name, arguments: call.arguments), objective: "Read only this window.")
        #expect(result.verified && factories == 2 && captures == 2)
        active = false; service.stop(); await service.drain()
        #expect(closes == 2)
    }

    private func preparation() -> TargetBoundNativeObservation.Preparation {
        .init(application: .init(processID: 4747, launchedAt: Date(timeIntervalSince1970: 1000), bundleID: "test.native.failure",
            bundleURL: URL(fileURLWithPath: "/Applications/Native Failure.app")),
            window: .init(title: "Native Failure", role: "AXWindow", identifier: "failure.window", document: "task://read",
                url: "", x: 0, y: 0, width: 560, height: 300, minimized: false, hidden: false, modal: false), validate: {})
    }
    private func successfulState() -> OwnedNativeComputerUseClient.NativeResult {
        let text = """
            Computer Use state (CUA App Version: 1001824)
            <app_state>
            App=/Applications/Native Failure.app/ (bundleID test.native.failure, pid 4747)
            Window: "Native Failure", App: Native Failure.
            0 standard window Native Failure, ID: failure.window
            1 static text Synthetic current state
            </app_state>
            """
        let content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        return .init(raw: .object(["content": .array(content)]), content: content, isError: false)
    }
}
