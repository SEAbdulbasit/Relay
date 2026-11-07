import AppKit
import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor struct OwnedNativeComputerUseClientTests {
    @Test func runtimePathsUseTOMLCompatibleStringsRatherThanJSONOnlySlashEscapes() throws {
        let path = "/Applications/Synthetic App.app/Contents/MacOS/fixture"
        let literal = try OwnedNativeComputerUseClient.configurationLiteral(.string(path))
        #expect(literal == "\"\(path)\"")
        #expect(!literal.contains("\\/"))
        #expect(try OwnedNativeComputerUseClient.configurationLiteral(.string("quote\"and\\backslash")) == #""quote\"and\\backslash""#)
    }

    @Test func handshakeDiscoversOnlyNativeCatalogWithoutModelOrCaptureRequests() async throws {
        let fixture = NativeObservationTransportFixture()
        let client = OwnedNativeComputerUseClient(transport: fixture.transport)
        let catalog = try await client.start(workspace: workspace)
        #expect(catalog.tools.map(\.name) == ["get_app_state", "set_value"])
        #expect(catalog.tools.first?.inputSchema == NativeObservationTransportFixture.schema)
        #expect(catalog.tools.last?.raw.object?["annotations"]?.object?["destructiveHint"] == .bool(false))
        _ = try await client.start(workspace: workspace)
        let events = await fixture.events
        #expect(events.map(\.method) == ["initialize", "initialized", "thread/start", "mcpServerStatus/list"])
        #expect(events[2].params["ephemeral"] == .bool(true))
        #expect(events[2].params["approvalPolicy"] == .string("never"))
        #expect(events[3].params["threadId"] == .string("synthetic-thread"))
        #expect(events[3].params["serverName"] == .string("relay_native"))
        #expect(!events.contains { $0.method == "turn/start" || $0.method == "mcpServer/tool/call" })
        await client.close()
        #expect(await fixture.closeCount == 1)
    }

    @Test func preservesOpaqueIndicesUnicodeImagesAndStructuredResultsWithoutClaimingVerification() async throws {
        let fixture = NativeObservationTransportFixture()
        let result = JSONValue.object(["content": .array([
            .object(["type": .string("text"), "text": .string("Synthetic window · café 🌍 [opaque-α/42]")]),
            .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("synthetic-only")])]),
            "structuredContent": .object(["opaque": .string("native/session/window/element"), "unknown": .number(42)]),
            "_meta": .object(["native-version": .string("fixture-v1")]), "isError": .bool(false)])
        await fixture.setResult(result)
        let client = try await ready(fixture)
        let received = try await client.state(requestID: "read-1", app: "/Applications/Synthetic Fixture.app")
        #expect(received.raw == result)
        #expect(received.content.count == 2)
        #expect(!received.isError)
        let call = try #require(await fixture.events.last)
        #expect(call.method == "mcpServer/tool/call")
        #expect(call.params["tool"] == .string("get_app_state"))
        #expect(call.params["arguments"] == .object(["app": .string("/Applications/Synthetic Fixture.app")]))
        await client.close()
    }

    @Test func duplicateReadReturnsReceiptButChangedTargetCannotReuseItsID() async throws {
        let fixture = NativeObservationTransportFixture()
        let client = try await ready(fixture)
        let first = try await client.state(requestID: "read", app: "Synthetic Fixture")
        #expect(try await client.state(requestID: "read", app: "Synthetic Fixture") == first)
        await #expect(throws: OwnedNativeComputerUseClient.Failure.duplicateRequest) {
            try await client.state(requestID: "read", app: "Another Synthetic Fixture")
        }
        #expect(await fixture.stateCallCount == 1)
        await client.close()
    }

    @Test func evictedReceiptsRemainConsumedAndCannotTriggerAnotherRead() async throws {
        let fixture = NativeObservationTransportFixture()
        let client = try await ready(fixture)
        for index in 0..<9 { _ = try await client.state(requestID: "read-\(index)", app: "Synthetic Fixture") }
        await #expect(throws: OwnedNativeComputerUseClient.Failure.duplicateRequest) {
            try await client.state(requestID: "read-0", app: "Synthetic Fixture")
        }
        #expect(await fixture.stateCallCount == 9)
        await client.close()
    }

    @Test func nativeErrorIsAnOpaqueObservationAndDoesNotEndTheSession() async throws {
        let fixture = NativeObservationTransportFixture()
        let error = JSONValue.object(["content": .array([.object(["type": .string("text"),
            "text": .string("Synthetic stale element; inspect state")])]), "isError": .bool(true),
            "structuredContent": .object(["code": .string("synthetic_stale")])])
        await fixture.setResult(error)
        let client = try await ready(fixture)
        let response = try await client.state(requestID: "error", app: "Synthetic Fixture")
        #expect(response.isError && response.raw == error)
        _ = try await client.state(requestID: "fresh", app: "Synthetic Fixture")
        #expect(await fixture.closeCount == 0)
        await client.close()
    }

    @Test func stateCallsUseFIFOAndQueuedCancellationDoesNotCancelTheOwner() async throws {
        let fixture = NativeObservationTransportFixture()
        let client = try await ready(fixture)
        await fixture.pause()
        let first = Task { try await client.state(requestID: "first", app: "First Synthetic Fixture") }
        try await waitUntil { await fixture.stateCallCount == 1 }
        let cancelled = Task { try await client.state(requestID: "cancel", app: "Cancelled Synthetic Fixture") }
        // Wait for actor entry rather than assuming task-creation order equals FIFO admission.
        for _ in 0..<20 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let third = Task { try await client.state(requestID: "third", app: "Third Synthetic Fixture") }
        for _ in 0..<20 { await Task.yield() }
        #expect(await fixture.stateCallCount == 1)
        await fixture.releaseOne()
        _ = try await first.value
        try await waitUntil { await fixture.stateCallCount == 2 }
        await fixture.releaseOne()
        _ = try await third.value
        let apps = await fixture.events.filter { $0.method == "mcpServer/tool/call" }.compactMap { $0.params["arguments"]?.object?["app"]?.string }
        #expect(apps == ["First Synthetic Fixture", "Third Synthetic Fixture"])
        #expect(await fixture.closeCount == 0)
        await client.close()
    }

    @Test func queuedDeadlineExpiresBeforeDispatchAndOwnerStillCompletes() async throws {
        let fixture = NativeObservationTransportFixture()
        let client = try await ready(fixture)
        await fixture.pause()
        let first = Task { try await client.state(requestID: "first", app: "Synthetic Fixture") }
        try await waitUntil { await fixture.stateCallCount == 1 }
        await #expect(throws: OwnedNativeComputerUseClient.Failure.timeout) {
            try await client.state(requestID: "expired", app: "Expired Synthetic Fixture", timeout: .milliseconds(20))
        }
        #expect(await fixture.stateCallCount == 1)
        await fixture.releaseOne(); _ = try await first.value
        await client.close()
    }

    @Test func cancellingInFlightReadClosesItsSessionAndDoesNotDispatchQueuedRead() async throws {
        let fixture = NativeObservationTransportFixture()
        let client = try await ready(fixture)
        await fixture.pause()
        let first = Task { try await client.state(requestID: "first", app: "Synthetic Fixture") }
        try await waitUntil { await fixture.stateCallCount == 1 }
        let queued = Task { try await client.state(requestID: "queued", app: "Other Synthetic Fixture") }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: (any Error).self) { try await queued.value }
        #expect(await fixture.closeCount == 1)
        #expect(await fixture.stateCallCount == 1)
    }

    @Test func stopClosesTransportOnceAndDropsQueuedAndLateResults() async throws {
        let fixture = NativeObservationTransportFixture()
        let client = try await ready(fixture)
        await fixture.pause()
        let first = Task { try await client.state(requestID: "first", app: "Synthetic Fixture") }
        try await waitUntil { await fixture.stateCallCount == 1 }
        let queued = Task { try await client.state(requestID: "next", app: "Other Synthetic Fixture") }
        for _ in 0..<20 { await Task.yield() }
        await client.close(); await client.close()
        await #expect(throws: (any Error).self) { try await first.value }
        await #expect(throws: (any Error).self) { try await queued.value }
        #expect(await fixture.closeCount == 1)
        #expect(await fixture.stateCallCount == 1)
        await #expect(throws: OwnedNativeComputerUseClient.Failure.closed) {
            try await client.state(requestID: "late", app: "Synthetic Fixture")
        }
    }

    @Test func malformedCatalogClosesAndDoesNotCapture() async throws {
        let fixture = NativeObservationTransportFixture()
        await fixture.setCatalog(.object(["data": .array([.object(["name": .string("wrong_server"), "tools": .object([:])])])]))
        let client = OwnedNativeComputerUseClient(transport: fixture.transport)
        await #expect(throws: OwnedNativeComputerUseClient.Failure.unsupportedCatalog) {
            try await client.start(workspace: workspace)
        }
        #expect(await fixture.closeCount == 1)
        #expect(await fixture.stateCallCount == 0)
    }

    @Test func unknownToolsAreExcludedAndDuplicateNativeNamesRefuseTheCatalog() async throws {
        let fixture = NativeObservationTransportFixture()
        let duplicate = JSONValue.object(["name": .string("get_app_state"), "inputSchema": NativeObservationTransportFixture.schema])
        await fixture.setCatalog(NativeObservationTransportFixture.catalog(["one": duplicate, "two": duplicate]))
        let client = OwnedNativeComputerUseClient(transport: fixture.transport)
        await #expect(throws: OwnedNativeComputerUseClient.Failure.unsupportedCatalog) {
            try await client.start(workspace: workspace)
        }
        #expect(await fixture.closeCount == 1)
    }

    @Test func transportFailureClosesWithoutAutomaticallyReplayingReadOrStartingModel() async throws {
        let fixture = NativeObservationTransportFixture()
        let client = try await ready(fixture)
        await fixture.failNextState()
        await #expect(throws: OwnedNativeComputerUseClient.Failure.timeout) {
            try await client.state(requestID: "lost", app: "Synthetic Fixture")
        }
        #expect(await fixture.stateCallCount == 1)
        #expect(await fixture.closeCount == 1)
        await #expect(throws: OwnedNativeComputerUseClient.Failure.closed) {
            try await client.state(requestID: "lost", app: "Synthetic Fixture")
        }
    }

    @Test func droppingAnIdleClientStillClosesItsOwnedTransport() async throws {
        let fixture = NativeObservationTransportFixture()
        func useAndRelease() async throws {
            let client = try await ready(fixture)
            _ = try await client.catalog()
        }
        try await useAndRelease()
        try await waitUntil { await fixture.closeCount == 1 }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_NATIVE_CATALOG_TEST"] == "1"))
    func installedOfficialRuntimeCanDiscoverCatalogWithoutLoginOrNativeToolCalls() async throws {
        let runtime = try OwnedNativeComputerUseClient.Runtime.discover()
        let client = try await OwnedNativeComputerUseClient.open(runtime: runtime)
        do {
            let catalog = try await client.catalog()
            #expect(catalog.tools.contains { $0.name == "get_app_state" })
            #expect(catalog.tools.contains { $0.name == "type_text" })
            #expect(catalog.tools.contains { $0.name == "drag" })
            await client.close()
        } catch { await client.close(); throw error }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_NATIVE_STATE_FIXTURE_TEST"] == "1"))
    func nativeStateCanReadOnlyTheExclusivelyOwnedInertFixtureWithoutModelOrMutation() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath) { fixture in
            try fixture.requireExclusiveProcess()
            let path = try #require(fixture.application.bundleURL?.resolvingSymlinksInPath().path)
            let runtime = try OwnedNativeComputerUseClient.Runtime.discover()
            let client = try await OwnedNativeComputerUseClient.open(runtime: runtime)
            do {
                let receipt = try await client.state(requestID: UUID().uuidString, app: path, timeout: .seconds(30))
                try fixture.requireExclusiveProcess()
                print("Native fixture receipt fields: \((receipt.raw.object?.keys.sorted() ?? []).joined(separator: ","))")
                print("Native fixture structured fields: \((receipt.raw.object?["structuredContent"]?.object?.keys.sorted() ?? []).joined(separator: ","))")
                let texts = receipt.content.compactMap { $0.object?["type"] == .string("text") ? $0.object?["text"]?.string : nil }
                if receipt.isError { print("Native fixture read error: \(texts.joined(separator: "\n").prefix(2_000))") }
                try #require(!receipt.isError, "The native provider did not return fixture state; no permission flow or action is attempted.")
                // The random launch token was not provided to the native tool or process.
                #expect(texts.joined(separator: "\n").contains(fixture.token))
                let images = receipt.content.filter { $0.object?["type"] == .string("image") }
                #expect(images.contains { value in
                    guard let encoded = value.object?["data"]?.string, let data = Data(base64Encoded: encoded) else { return false }
                    return NSImage(data: data) != nil
                })
                let raw = Data(receipt.raw.pretty.utf8)
                let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/verification/native-observation-fixture-state.json")
                try raw.write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                await client.close()
            } catch { await client.close(); throw error }
        }
    }

    private var workspace: URL { URL(fileURLWithPath: "/private/tmp/RelaySyntheticNativeWorkspace", isDirectory: true) }
    private func ready(_ fixture: NativeObservationTransportFixture) async throws -> OwnedNativeComputerUseClient {
        let client = OwnedNativeComputerUseClient(transport: fixture.transport)
        try await client.start(workspace: workspace)
        return client
    }
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Synthetic transport did not reach the expected state")
        throw OwnedNativeComputerUseClient.Failure.timeout
    }
}

private actor NativeObservationTransportFixture {
    struct Event: Sendable { let method: String; let params: [String: JSONValue] }
    private(set) var events: [Event] = []
    private(set) var closeCount = 0
    private var result = JSONValue.object(["content": .array([.object(["type": .string("text"), "text": .string("Synthetic native state")])])])
    private var paused = false
    private var gates: [CheckedContinuation<Void, Error>] = []
    private var nextStateFails = false
    private var catalogResponse: JSONValue?
    static let schema = JSONValue.object(["type": .string("object"), "properties": .object(["app": .object(["type": .string("string")])]),
        "required": .array([.string("app")]), "additionalProperties": .bool(false)])

    nonisolated var transport: OwnedNativeComputerUseClient.Transport {
        .init(request: { [self] method, params, _ in try await request(method, params: params) },
              initialized: { [self] in await noteInitialized() }, close: { [self] in await close() })
    }
    var stateCallCount: Int { events.filter { $0.method == "mcpServer/tool/call" }.count }
    func setResult(_ value: JSONValue) { result = value }
    func setCatalog(_ value: JSONValue) { catalogResponse = value }
    func failNextState() { nextStateFails = true }
    func pause() { paused = true }
    func releaseOne() { if !gates.isEmpty { gates.removeFirst().resume() } }
    private func noteInitialized() { events.append(Event(method: "initialized", params: [:])) }
    private func close() {
        closeCount += 1
        let waiting = gates; gates.removeAll()
        for gate in waiting { gate.resume(throwing: CancellationError()) }
    }
    private func request(_ method: OwnedNativeComputerUseClient.Method, params: [String: JSONValue]) async throws -> JSONValue {
        events.append(Event(method: method.rawValue, params: params))
        switch method {
        case .initialize: return .object([:])
        case .threadStart: return .object(["thread": .object(["id": .string("synthetic-thread")])])
        case .catalog:
            if let catalogResponse { return catalogResponse }
            let descriptor: (String) -> JSONValue = { name in .object(["name": .string(name), "inputSchema": Self.schema,
                "annotations": .object(["destructiveHint": .bool(false)])]) }
            return Self.catalog(["get_app_state": descriptor("get_app_state"), "set_value": descriptor("set_value"),
                                 "arbitrary_command": descriptor("arbitrary_command")])
        case .state:
            if nextStateFails { nextStateFails = false; throw OwnedNativeComputerUseClient.Failure.timeout }
            if paused { try await withCheckedThrowingContinuation { gates.append($0) } }
            return result
        }
    }
    static func catalog(_ tools: [String: JSONValue]) -> JSONValue {
        .object(["data": .array([.object(["name": .string("relay_native"), "runtimeStatus": .string("connected"),
            "tools": .object(tools), "authStatus": .string("unsupported")])])])
    }
}
