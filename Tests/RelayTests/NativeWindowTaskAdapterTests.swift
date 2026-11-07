import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Relay

/// Ignored draft tests; not compiled or executed yet. No real application,
/// Accessibility query, native input, model, account or source is used.
@MainActor
struct NativeWindowTaskAdapterTests {
    @Test func foreignModelAppCannotWidenTheOriginalTaskButAnAdmittedMultiAppTaskWorks() async throws {
        let fixture = NativeWindowTaskFixture()
        let single = fixture.adapter(allowed: [fixture.first.bundleID])
        await #expect(throws: (any Error).self) { try await single.observe(bundleID: fixture.second.bundleID) }
        #expect(fixture.initialCalls.isEmpty)
        let multiple = fixture.adapter(allowed: [fixture.first.bundleID, fixture.second.bundleID])
        _ = try await multiple.observe(bundleID: fixture.first.bundleID)
        _ = try await multiple.observe(bundleID: fixture.second.bundleID)
        #expect(fixture.initialCalls == [fixture.first.bundleID, fixture.second.bundleID])
        multiple.stop(); await multiple.drain()
    }

    @Test func exactTaskAndProtocolAreRetainedWhileImagesStayOutsideSerializableMessages() async throws {
        let fixture = NativeWindowTaskFixture()
        fixture.includeImage = true
        let adapter = fixture.adapter()
        let receipt = try await adapter.observe(bundleID: fixture.first.bundleID)
        let exact = "Read cafe\u{301} 🌍 exactly; do not write anything."
        let call = ToolCall(id: "prior-read", name: "calculate", arguments: ["expression": .string("2+2")])
        let history = [ModelMessage(role: "assistant", content: "", toolCalls: [call]),
            ModelMessage(role: "tool", content: "{\"summary\":\"4\",\"evidence\":\"Arithmetic\",\"verified\":true}", toolCallID: call.id, toolName: call.name)]
        let turn = try adapter.prepareTurn(objective: exact, completeHistory: history)
        #expect(turn.visionInput != nil && turn.tools.isEmpty)
        #expect(turn.messages.contains { $0.role == "user" && $0.content.utf8.elementsEqual(exact.utf8) })
        let retained = Array(turn.messages.dropFirst(2).prefix(history.count))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(retained) == encoder.encode(history))
        let image = try #require(turn.visionInput?.frame.jpeg)
        let serialized = String(decoding: try encoder.encode(turn.messages), as: UTF8.self)
        #expect(!serialized.contains(image.base64EncodedString()))
        #expect(!receipt.summary.contains(image.base64EncodedString()))
        adapter.stop(); await adapter.drain()
    }

    @Test func changedSourceForeignAndConsumedPlanningTicketsCannotPublishReplies() async throws {
        let fixture = NativeWindowTaskFixture()
        let adapter = fixture.adapter(), other = fixture.adapter()
        _ = try await adapter.observe(bundleID: fixture.first.bundleID)
        let turn = try adapter.prepareTurn(objective: "Read the window.", completeHistory: [])
        #expect(throws: NativeWindowTaskAdapter.Failure.wrongOwner) {
            try other.accept(.init(content: "Read result.", toolCalls: []), for: turn)
        }
        let answer = try adapter.accept(.init(content: "Read result.", toolCalls: []), for: turn)
        #expect(answer.content == "Read result.")
        #expect(throws: NativeWindowTaskAdapter.Failure.consumedTurn) {
            try adapter.accept(answer, for: turn)
        }
        let old = try adapter.prepareTurn(objective: "Read the window.", completeHistory: [])
        _ = try await adapter.refreshOriginal()
        #expect(throws: NativeWindowTaskAdapter.Failure.changedObservation) {
            try adapter.accept(answer, for: old)
        }
        adapter.stop(); other.stop(); await adapter.drain(); await other.drain()
    }

    @Test func readOnlyPhaseCannotAdmitAnActionBecauseTheModelSaysItIsSafe() async throws {
        let fixture = NativeWindowTaskFixture(), adapter = fixture.adapter()
        _ = try await adapter.observe(bundleID: fixture.first.bundleID)
        let turn = try adapter.prepareTurn(objective: "Read the window.", completeHistory: [])
        let proposal = ModelReply(content: "This is safe.", toolCalls: [ToolCall(name: "press_control", arguments: [:])])
        #expect(throws: NativeWindowTaskAdapter.Failure.unqualifiedMutation) { try adapter.accept(proposal, for: turn) }
        #expect(fixture.mutationCount == 0)
        adapter.stop(); await adapter.drain()
    }

    @Test func missingImageAllowsTextOnlyReadingAndBudgetCannotDeleteExactUserBytes() async throws {
        let fixture = NativeWindowTaskFixture(), adapter = fixture.adapter()
        _ = try await adapter.observe(bundleID: fixture.first.bundleID)
        let turn = try adapter.prepareTurn(objective: "Read the accessible text.", completeHistory: [])
        #expect(turn.visionInput == nil && turn.tools.isEmpty)
        #expect(throws: NativeVisionFailure.textBudget) {
            try adapter.prepareTurn(objective: String(repeating: "Exact cafe\u{301} request. ", count: 400), completeHistory: [])
        }
        adapter.stop(); await adapter.drain()
    }

    @Test func stoppedOrSteeredStoreOwnershipRejectsLateCaptureAndLateModelReply() async throws {
        for stop in [false, true] {
            let fixture = NativeWindowTaskFixture(), adapter = fixture.adapter()
            fixture.pause = true
            let capture = Task { try await adapter.observe(bundleID: fixture.first.bundleID) }
            for _ in 0..<200 where fixture.waiting == nil { await Task.yield() }
            try #require(fixture.waiting != nil)
            if stop { adapter.stop() } else { fixture.taskRevision += 1 }
            fixture.release()
            await #expect(throws: (any Error).self) { try await capture.value }
            #expect(!adapter.hasCurrentObservation)
            adapter.stop(); await adapter.drain()
        }
        let fixture = NativeWindowTaskFixture(), adapter = fixture.adapter()
        _ = try await adapter.observe(bundleID: fixture.first.bundleID)
        let turn = try adapter.prepareTurn(objective: "Read it.", completeHistory: [])
        adapter.releaseObservation()
        #expect(throws: (any Error).self) { try adapter.accept(.init(content: "Late answer.", toolCalls: []), for: turn) }
        adapter.stop(); await adapter.drain()
    }

    @Test func scopeRevocationDuringCaptureCannotRetainTheResult() async throws {
        let fixture = NativeWindowTaskFixture(), adapter = fixture.adapter()
        fixture.pause = true
        let capture = Task { try await adapter.observe(bundleID: fixture.first.bundleID) }
        for _ in 0..<200 where fixture.waiting == nil { await Task.yield() }
        try #require(fixture.waiting != nil)
        fixture.scopeCurrent = false; fixture.release()
        await #expect(throws: (any Error).self) { try await capture.value }
        #expect(!adapter.hasCurrentObservation)
        adapter.stop(); await adapter.drain()
    }
}

@MainActor private final class NativeWindowTaskFixture {
    let first = DesktopApplicationIdentity(processID: 4242, launchedAt: Date(timeIntervalSince1970: 1000),
        bundleID: "test.task.first", bundleURL: URL(fileURLWithPath: "/Applications/Task First.app"))
    let second = DesktopApplicationIdentity(processID: 4243, launchedAt: Date(timeIntervalSince1970: 1001),
        bundleID: "test.task.second", bundleURL: URL(fileURLWithPath: "/Applications/Task Second.app"))
    var taskRevision = 1, scopeCurrent = true, includeImage = false, pause = false
    var initialCalls: [String] = [], mutationCount = 0
    var waiting: CheckedContinuation<Void, Never>?
    private var observers: [TargetBoundNativeObservation] = []

    func adapter(allowed: Set<String>? = nil) -> NativeWindowTaskAdapter {
        let allowed = allowed ?? [first.bundleID], expected = taskRevision
        return NativeWindowTaskAdapter(ownership: .init(taskID: UUID(), isCurrent: { [self] in taskRevision == expected },
            admitApplication: { [self] bundle in
                guard allowed.contains(bundle), scopeCurrent,
                      let app = [first, second].first(where: { $0.bundleID == bundle }) else {
                    throw NativeWindowTaskAdapter.Failure.unadmittedApplication
                }
                return .init(application: app, validate: { [self] in
                    guard scopeCurrent else { throw NativeWindowTaskAdapter.Failure.unadmittedApplication }
                })
            }), backend: .init(initial: { [self] admission in
                initialCalls.append(admission.application.bundleID)
                let observer = TargetBoundNativeObservation(backend: .init(capture: { [self] _, _ in
                    let app = admission.application
                    let text = """
                        Computer Use state (CUA App Version: 1001824)
                        <app_state>
                        App=\(app.bundleURL.path)/ (bundleID \(app.bundleID), pid \(app.processID))
                        Window: "Task Window", App: Task.
                        0 standard window Task Window, ID: task.window
                        1 static text Visible synthetic fact
                        </app_state>
                        """
                    var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
                    if includeImage { content.append(try image()) }
                    return .init(raw: .object(["content": .array(content)]), content: content, isError: false)
                }, close: {}), sessionIsActive: { [self] in taskRevision == expected })
                observers.append(observer)
                if pause { await withCheckedContinuation { waiting = $0 } }
                let preparation = TargetBoundNativeObservation.Preparation(application: admission.application,
                    window: .init(title: "Task Window", role: "AXWindow", identifier: "task.window", document: "task://original",
                        url: "", x: 0, y: 0, width: 560, height: 300, minimized: false, hidden: false, modal: false),
                    validate: { try admission.validate() })
                let snapshot = try await observer.observe(observer.prepare(preparation))
                return source(snapshot, observer: observer, preparation: preparation)
            }, stop: { [self] in for observer in observers { observer.stop() } },
               drain: { [self] in for observer in observers { await observer.drain() } }))
    }

    private func source(_ snapshot: TargetBoundNativeObservation.Snapshot, observer: TargetBoundNativeObservation,
                        preparation: TargetBoundNativeObservation.Preparation) -> NativeWindowTaskAdapter.Capture {
        .init(snapshot: snapshot, isCurrent: { observer.isCurrent(snapshot) }, refreshOriginal: { [self] in
            let next = try await observer.observe(observer.prepare(preparation))
            return source(next, observer: observer, preparation: preparation)
        })
    }

    func release() { waiting?.resume(); waiting = nil; pause = false }

    private func image() throws -> JSONValue {
        let context = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bitmap = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, nil)
        try #require(CGImageDestinationFinalize(destination))
        return .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string((data as Data).base64EncodedString())])
    }
}
