import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

/// Actual owned URLSession + SQLite + production Store review/receipt path.
/// Default off: no real service, account, credentials, native input or model.
@MainActor @Suite(.serialized) struct MainAgentMCPStoreHTTPTests {
    nonisolated private static let enabled = ProcessInfo.processInfo.environment["RELAY_MAIN_MCP_LOOPBACK_PROTOCOL_TEST"] == "1"
    private let marker = "OWNED_PRIVATE_MCP_BODY"
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() { try Task.checkCancellation(); try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
    }
    private func payload(_ input: [ModelMessage], tool: String) throws -> [String: JSONValue] {
        let message = try #require(input.last { $0.role == "tool" && $0.toolName == tool })
        let result = try JSONDecoder().decode(ToolResult.self, from: Data(message.content.utf8))
        return try #require(try JSONDecoder().decode(JSONValue.self, from: Data(result.summary.utf8)).object)
    }
    private func target(_ input: [ModelMessage], kind: String) throws -> String {
        let catalog = try payload(input, tool: "mcp_catalog")
        guard case .array(let entries) = catalog["entries"] else { throw MainAgentMCPTools.Failure.unavailable }
        let entry = try #require(entries.compactMap(\.object).first { $0["kind"] == .string(kind) })
        if kind != "resource" { #expect(Data((try #require(entry["name"]?.string)).utf8) == Data("cafe\u{301}_read".utf8)) }
        #expect(catalog["account_identity"] == .string("not_attested"))
        return try #require(entry["target_id"]?.string)
    }
    private func read(_ id: String, resource: Bool = false, providerID: String = "owned-mcp-read-🌍") -> Relay.ToolCall {
        .init(id: providerID, name: "mcp_read", arguments: ["target_id": .string(id),
            "arguments_json": .string(resource ? "{}" : #"{"region":"Café 🌍"}"#)])
    }
    private func start(_ f: Fixture, complete: @escaping @MainActor ([ModelMessage], [ToolDefinition], ModelConfiguration) async throws -> ModelReply,
                       execute: (@MainActor (Relay.ToolCall) async throws -> ToolResult)? = nil,
                       grants: [ScopeGrant] = [], executeFileRead: (@MainActor (Relay.ToolCall, FileReadExecutionScope) async throws -> ToolResult)? = nil) async throws -> AssistantStore {
        let store = AssistantStore(persistenceURL: nil, complete: complete, conversationHistory: f.history, execute: execute, executeFileRead: executeFileRead, fileReadWorker: f.worker)
        f.store = store; await store.waitForConversationTaskToSettle()
        await awaitMCPQuietWindow()
        await store.directMCP.connect(address: f.endpoint.absoluteString, token: "SYNTHETIC-MCP-READ-KEY-8206")
        try #require(store.directMCP.endpoint != nil, Comment(rawValue: store.directMCP.status))
        #expect(!store.directMCP.taskReadsEnabled)
        store.directMCP.setTaskReadsEnabled(true)
        store.grants = grants
        store.draft = "Read the selected MCP service's owned report. Do not write or repeat an uncertain request."
        let ticket = try #require(store.send()); #expect(await ticket.waitForAcknowledgment() == .saved)
        return store
    }

    @Test(.enabled(if: Self.enabled), arguments: [false, true])
    func actualCatalogReviewReadAndSavedReceiptReachTheNextMainModelTurn(_ resource: Bool) async throws {
        let f = try await Fixture.start(), kind = resource ? "resource" : "server_labeled_read_tool"
        var turns = 0, generic = 0
        do {
            let store = try await start(f, complete: { input, definitions, _ in
                turns += 1
                #expect(definitions.contains { $0.name == "mcp_catalog" } && definitions.contains { $0.name == "mcp_read" })
                #expect(!definitions.contains { $0.name == "cafe\u{301}_read" || $0.name == "write_fixture" })
                #expect(!input.filter { $0.role == "system" }.contains { $0.content.contains("UNTRUSTED_CATALOG_INSTRUCTION") })
                let actual = try LocalModelClient.prepareNativeTextContext(messages: input, tools: definitions)
                #expect(actual.availableHistoryBytes >= 6_000)
                if turns == 1 { return .init(content: "", toolCalls: [.init(id: "owned-mcp-catalog", name: "mcp_catalog", arguments: [:])]) }
                if turns == 2 { return .init(content: "", toolCalls: [self.read(try self.target(input, kind: kind), resource: resource)]) }
                let result = try self.payload(input, tool: "mcp_read")
                #expect(result["text"]?.string?.contains(self.marker) == true)
                #expect(result["call_returned"] == .bool(true) && result["goal_verified"] == .bool(false))
                return .init(content: "The approved report snapshot returned. No remote action was verified.", toolCalls: [])
            }, execute: { _ in generic += 1; throw MainAgentMCPTools.Failure.unavailable })
            try await wait { store.pendingReview != nil }
            let review = try #require(store.pendingReview)
            #expect(review.call.name == "mcp_read" && review.reason.contains(f.endpoint.absoluteString))
            #expect(review.reason.contains("account identity") && !review.reason.contains("SYNTHETIC-MCP-READ-KEY"))
            #expect((try await f.state())["read-started", default: 0] == 0)
            store.approveReview(); await store.waitForConversationTaskToSettle(); await store.directMCP.drain()
            let counts = try await f.state(), rows = try await f.records()
            #expect(turns == 3 && generic == 0 && store.pendingReview == nil && store.phase == .needsInput)
            #expect(counts["read-started", default: 0] == 1 && counts["read-returned", default: 0] == 1)
            #expect(counts["bad-credential", default: 0] == 0 && counts["wrong-tool-bytes", default: 0] == 0)
            #expect(counts["wrong-arguments", default: 0] == 0 && counts["wrong-resource", default: 0] == 0)
            let intent = try #require(rows.compactMap { row -> JournalIntent? in if case .intent(let value) = row.event.payload, value.toolName == "mcp_read" { value } else { nil } }.first)
            #expect(intent.effect == .unknown && intent.toolCallID.bytes == Data("owned-mcp-read-🌍".utf8))
            #expect(rows.filter { if case .result(let value) = $0.event.payload { value.callDigest == intent.callDigest && value.kind == .returnedUnverified } else { false } }.count == 1)
            #expect(!String(decoding: try JSONEncoder().encode(rows.map(\.event)), as: UTF8.self).contains(self.marker))
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test(.enabled(if: Self.enabled), arguments: ["decline", "catalog", "disconnect"])
    func actualReviewCannotAuthorizeAForeignChangedOrDeclinedRead(_ change: String) async throws {
        let f = try await Fixture.start(); var turns = 0
        do {
            let store = try await start(f, complete: { input, _, _ in
                turns += 1
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: "mcp_catalog", arguments: [:])]) }
                if turns == 2 { return .init(content: "", toolCalls: [self.read(try self.target(input, kind: "server_labeled_read_tool"))]) }
                #expect(!input.contains { $0.content.contains(self.marker) })
                return .init(content: "The remote read was not dispatched.", toolCalls: [])
            })
            try await wait { store.pendingReview != nil }
            if change == "decline" { store.denyReview() }
            else {
                if change == "catalog" { _ = try await f.control("change-catalog") }
                else { store.directMCP.disconnect() }
                store.approveReview()
            }
            await store.waitForConversationTaskToSettle(); await store.directMCP.drain()
            #expect((try await f.state())["read-started", default: 0] == 0 && store.pendingReview == nil)
            #expect(!store.activity.contains { $0.detail.contains(self.marker) })
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test(.enabled(if: Self.enabled), arguments: ["stop", "connection", "provider", "lost_ack"])
    func actualResultCommitRevocationOrStorageLossCannotPublishTheFirstPrivateBody(_ change: String) async throws {
        let f = try await Fixture.start(), gate = CommitGate()
        var turns = 0
        do {
            let core = try await f.history.journalForTesting()
            if change == "lost_ack" { await core.injectResultFault(.afterCommit, forToolName: "mcp_read") }
            await core.atNextResultBoundary(.afterCommit, forToolName: "mcp_read") { gate.pause() }
            let store = try await start(f, complete: { input, _, _ in
                turns += 1
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: "mcp_catalog", arguments: [:])]) }
                if turns == 2 { return .init(content: "", toolCalls: [self.read(try self.target(input, kind: "server_labeled_read_tool"))]) }
                #expect(!input.contains { $0.content.contains(self.marker) })
                return .init(content: "The recorded request was not repeated.", toolCalls: [])
            })
            try await wait { store.pendingReview != nil }; store.approveReview()
            try await wait { gate.entered }; #expect(!gate.expired, "The actual result-COMMIT gate must still be held before revocation.")
            if change == "stop" { store.stop() }
            else if change == "connection" { store.directMCP.setTaskReadsEnabled(false) }
            else if change == "provider" { store.configuration.model = "replacement-provider-revision" }
            gate.release(); await store.waitForConversationTaskToSettle(); #expect(!gate.expired, "The owned result-COMMIT barrier must not silently self-expire.")
            if change == "lost_ack" { try await store.retryConversationStorage() }
            await store.directMCP.drain()
            #expect((try await f.state())["read-started", default: 0] == 1)
            #expect(!store.activity.contains { $0.detail.contains(self.marker) } && !store.messages.contains { $0.text.contains(self.marker) })
            let records = try await f.records()
            let intent = try #require(records.compactMap { row -> JournalIntent? in if case .intent(let value) = row.event.payload, value.toolName == "mcp_read" { value } else { nil } }.first)
            #expect(records.filter { if case .result(let value) = $0.event.payload { value.callDigest == intent.callDigest } else { false } }.count == 1)
            #expect(!String(decoding: try JSONEncoder().encode(records.map(\.event)), as: UTF8.self).contains(self.marker))
            await f.close()
        } catch { gate.release(); await f.close(); throw error }
    }

    @Test(.enabled(if: Self.enabled))
    func actualUncertainRemoteErrorCannotBeRetriedByChangingTheModelCallID() async throws {
        let f = try await Fixture.start(path: "error"); var turns = 0, targetID = "", reviewCount = 0
        do {
            let store = try await start(f, complete: { input, _, _ in
                turns += 1
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: "mcp_catalog", arguments: [:])]) }
                if turns == 2 { targetID = try self.target(input, kind: "server_labeled_read_tool"); return .init(content: "", toolCalls: [self.read(targetID)]) }
                #expect(!input.contains { $0.content.contains("PRIVATE_REMOTE_ERROR_MUST_NOT_ESCAPE") })
                if turns == 3 { return .init(content: "", toolCalls: [self.read(targetID, providerID: "different-model-call-id")]) }
                return .init(content: "The remote outcome is unconfirmed and was not repeated.", toolCalls: [])
            })
            try await wait { store.pendingReview != nil }; reviewCount += 1; store.approveReview()
            await store.waitForConversationTaskToSettle(); await store.directMCP.drain()
            #expect(turns == 4 && reviewCount == 1 && store.pendingReview == nil)
            #expect((try await f.state())["read-started", default: 0] == 1)
            #expect(!store.activity.contains { $0.detail.contains("PRIVATE_REMOTE_ERROR_MUST_NOT_ESCAPE") })
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test(.enabled(if: Self.enabled))
    func actualInFlightHTTPStopDrainsWithoutPublishingItsLatePrivateResponse() async throws {
        let f = try await Fixture.start(path: "slow"); var turns = 0
        do {
            let store = try await start(f, complete: { input, _, _ in
                turns += 1
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: "mcp_catalog", arguments: [:])]) }
                return .init(content: "", toolCalls: [self.read(try self.target(input, kind: "server_labeled_read_tool"))])
            })
            try await wait { store.pendingReview != nil }; store.approveReview()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (try await f.state())["read-started", default: 0] == 0 {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(2))
            }
            store.stop(); _ = try await f.control("release")
            await store.waitForConversationTaskToSettle(); await store.directMCP.drain()
            #expect(store.phase == .stopped && turns == 2)
            #expect(!store.activity.contains { $0.detail.contains(self.marker) } && !store.messages.contains { $0.text.contains(self.marker) })
            #expect((try await f.state())["read-started", default: 0] == 1)
            await f.close()
        } catch { _ = try? await f.control("release"); await f.close(); throw error }
    }

    @Test(.enabled(if: Self.enabled))
    func actualSelectedInputProofCannotBeLaunderedIntoTheRemoteSnapshotAfterCommit() async throws {
        let f = try await Fixture.start(), gate = CommitGate(), path = f.root.appending(path: "included-source.txt")
        let original = "ACTUAL_INCLUDED_PRIVATE_INPUT_A"
        try Data(original.utf8).write(to: path)
        let grants = [ScopeGrant(path: f.root.path)]; f.tools.grants = grants
        var turns = 0, reads = 0
        do {
            let core = try await f.history.journalForTesting()
            await core.atNextResultBoundary(.afterCommit, forToolName: "mcp_read") { gate.pause() }
            let store = try await start(f, complete: { input, _, _ in
                turns += 1
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: "read_file", arguments: ["path": .string(path.path)])]) }
                if turns == 2 {
                    #expect(input.contains { $0.content.contains(original) })
                    return .init(content: "", toolCalls: [.init(name: "mcp_catalog", arguments: [:])])
                }
                if turns == 3 {
                    #expect(input.contains { $0.content.contains(original) })
                    return .init(content: "", toolCalls: [self.read(try self.target(input, kind: "server_labeled_read_tool"))])
                }
                #expect(!input.contains { $0.content.contains(original) || $0.content.contains(self.marker) })
                return .init(content: "The earlier source could not be rechecked; no request was repeated.", toolCalls: [])
            }, grants: grants, executeFileRead: { call, scope in
                reads += 1; return try await f.tools.execute(call, fileReadScope: scope, fileReadWorker: f.worker)
            })
            #expect(store.grants == grants)
            try await wait { store.pendingReview != nil }; store.approveReview()
            try await wait { gate.entered }; #expect(!gate.expired, "The actual result-COMMIT gate must still be held before revocation.")
            try Data("CURRENT_CHANGED_INPUT_A".utf8).write(to: path)
            gate.release(); await store.waitForConversationTaskToSettle(); #expect(!gate.expired, "The owned result-COMMIT barrier must not silently self-expire."); await store.directMCP.drain()
            let finalCounts = try await f.state()
            #expect(reads == 1 && finalCounts["read-started", default: 0] == 1)
            #expect(!store.activity.contains { $0.name == "mcp_read" && $0.detail.contains(self.marker) })
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains(original) }, "Previously shown factual input must be preserved.")
            #expect(try Data(contentsOf: path) == Data("CURRENT_CHANGED_INPUT_A".utf8))
            await f.close()
        } catch { gate.release(); await f.close(); throw error }
    }

    @Test(.enabled(if: Self.enabled))
    func enabledMCPProfilePreservesTheFull4396ByteFreshObservationAndTwoModelTurns() async throws {
        let f = try await Fixture.start(); var turns = 0
        let controls = (0..<16).map { index in
            "element_id=fixture-control-\(index) role=AXStaticText title=Native fixture source row \(index) value=\(String(repeating: "ordinary bounded source text ", count: 5)) window_id=original-window"
        }.joined(separator: "\n")
        let fresh = controls + "\nelement_id=fresh-input-8431 role=AXTextField title=Fixture input value= identifier=relay.fixture.input window_id=original-window\n"
            + "element_id=fresh-apply-8431 role=AXButton title=Apply identifier=relay.fixture.apply window_id=original-window\n"
        do {
            let store = try await start(f, complete: { input, definitions, _ in
                turns += 1
                #expect(fresh.utf8.count == 4_396)
                let actual = try LocalModelClient.prepareNativeTextContext(messages: input, tools: definitions)
                #expect(actual.availableHistoryBytes >= 6_000)
                let systemBytes = input.filter { $0.role == "system" }.reduce(0) { $0 + $1.content.utf8.count }
                #expect(LocalModelClient.maximumContextBytes - systemBytes - (try JSONEncoder().encode(definitions)).count >= 6_000)
                if turns == 1 { return .init(content: "", toolCalls: [.init(name: "observe_app", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID)])]) }
                let message = try #require(input.last { $0.toolName == "observe_app" })
                let result = try JSONDecoder().decode(ToolResult.self, from: Data(message.content.utf8))
                #expect(Data(result.summary.utf8) == Data(fresh.utf8))
                return .init(content: "Whole fresh observation retained.", toolCalls: [])
            }, execute: { call in
                #expect(call.name == "observe_app")
                return ToolResult(summary: fresh, evidence: "Owned inert context fixture; no desktop read.", verified: true)
            })
            await store.waitForConversationTaskToSettle()
            #expect(turns == 2 && !store.isRunning && store.errorMessage == nil)
            await f.close()
        } catch { await f.close(); throw error }
    }

    /// An actual SDK delegate witness, never a server-effect or goal verdict.
    @Test(.enabled(if: Self.enabled), arguments: [false, true])
    func actualStreamAndHeadersCancellationRetainTheRequestUntilItsTaskDelegateCompletes(_ beforeHeaders: Bool) async throws {
        let f = try await Fixture.start(path: beforeHeaders ? "headers" : "stream")
        let events = CompletionEvents()
        let endpoint = try DirectMCPEndpoint(f.endpoint.absoluteString, token: "SYNTHETIC-MCP-READ-KEY-8206")
        let transport = DirectMCPTransport(endpoint: endpoint, completionAudit: { events.record($0) })
        let request = Task {
            try await transport.send(.call, wire: .init(version: DirectMCPWire.currentVersion, sessionID: nil),
                parameters: ["name": .string("cafe\u{301}_read"), "arguments": .object(["region": .string("Café 🌍")])])
        }
        do {
            let gate = beforeHeaders ? "headers-held" : "stream-result-sent"
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while (try await f.state())[gate, default: 0] == 0 {
                try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2))
            }
            if beforeHeaders {
                request.cancel(); transport.invalidate()
            }
            // Inspect the actual delegate and release witnesses when drain
            // returns, independently of awaiting the request task's result.
            await transport.drain()
            let observed = events.snapshot
            #expect(observed.map(\.phase) == [.created, .completed, .releasedAfterCompletion])
            let taskID = try #require(observed.first?.taskIdentifier)
            #expect(taskID > 0 && observed.allSatisfy { $0.taskIdentifier == taskID })
            let counts = try await f.state()
            #expect(counts["read-started", default: 0] == 1)
            #expect(counts["headers-gate-expired", default: 0] == 0 && counts["stream-gate-expired", default: 0] == 0)
            if beforeHeaders {
                #expect(counts["headers-held", default: 0] == 1 && counts["read-returned", default: 0] == 0,
                    "The server must still be holding its response headers when the actual client task settles.")
                do { _ = try await request.value; Issue.record("A canceled headers wait returned a response") }
                catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
            } else {
                #expect(counts["stream-result-sent", default: 0] == 1 && counts["stream-handler-ended", default: 0] == 0,
                    "The stream handler must still be held when the actual client task delegate has completed.")
                let reply = try await request.value
                #expect(reply.result["isError"] == .bool(false))
            }
            _ = try await f.control("release")
            transport.invalidate(); await transport.drain(); await f.close()
        } catch {
            request.cancel(); transport.invalidate()
            _ = try? await f.control("release")
            _ = try? await request.value; await transport.drain(); await f.close(); throw error
        }
    }
    nonisolated private final class CompletionEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [DirectMCPTransport.CompletionEvent] = []
        func record(_ value: DirectMCPTransport.CompletionEvent) { lock.withLock { if values.count < 16 { values.append(value) } } }
        var snapshot: [DirectMCPTransport.CompletionEvent] { lock.withLock { values } }
    }
    nonisolated private final class CommitGate: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var arrived = false, released = false, didExpire = false
        var entered: Bool { lock.withLock { arrived } }
        var expired: Bool { lock.withLock { didExpire } }
        func pause() {
            lock.withLock { arrived = true }
            if semaphore.wait(timeout: .now() + 8) == .timedOut { lock.withLock { didExpire = true } }
        }
        func release() {
            let signal = lock.withLock { let first = !released; released = true; return first }
            if signal { semaphore.signal() }
        }
    }
    @MainActor private final class Fixture {
        let root: URL, process: Process, endpoint: URL, history: AssistantConversationHistory
        var store: AssistantStore?
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
        let tools = MacTools()
        private init(root: URL, process: Process, endpoint: URL) {
            self.root = root; self.process = process; self.endpoint = endpoint
            history = AssistantConversationHistory(stateURL: root.appending(path: "state.json"))
        }
        static func start(path: String = "mcp") async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appending(path: "relay-owned-main-mcp-" + UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Scripts/Tests/test-main-agent-mcp-fixture.py")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, "--root", root.path, "--lifetime", "40"]
            process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let end = ContinuousClock.now.advanced(by: .seconds(5)); var ready: [String: JSONValue]?
                while ContinuousClock.now < end {
                    if let bytes = try? Relay.LocalStateFile.read(root.appending(path: "ready.json"), maximumBytes: 4_096) {
                        ready = try? JSONDecoder().decode([String: JSONValue].self, from: bytes)
                        if ready != nil { break }
                    }
                    try #require(process.isRunning); try await Task.sleep(for: .milliseconds(5))
                }
                let info = try #require(ready), port = try #require(info["port"]?.int)
                try #require(info["pid"] == .number(Double(process.processIdentifier)) && info["nonce"] == .string(root.lastPathComponent))
                try #require((1...65_535).contains(port) && ["mcp", "slow", "error", "stream", "headers"].contains(path))
                return .init(root: root, process: process, endpoint: try #require(URL(string: "http://127.0.0.1:\(port)/\(path)")))
            } catch {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                try? FileManager.default.removeItem(at: root); throw error
            }
        }
        func control(_ path: String) async throws -> [String: Int] {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
            config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let url = endpoint.deletingLastPathComponent().appending(path: path)
            let (bytes, response) = try await session.data(from: url)
            try #require((response as? HTTPURLResponse)?.statusCode == 200 && response.url == url)
            if path == "state" { return try JSONDecoder().decode([String: Int].self, from: bytes) }
            return [:]
        }
        func state() async throws -> [String: Int] { try await control("state") }
        func records() async throws -> [JournalRecord] {
            let core = try await history.journalForTesting(), scope = try await core.scope()
            var result: [JournalRecord] = [], cursor: JournalCursor?
            repeat {
                let page = try await core.page(after: cursor, expectedScope: scope)
                result += page.records; cursor = page.hasLater ? page.cursor : nil
            } while cursor != nil
            return result
        }
        func close() async {
            store?.stop(); await store?.waitForConversationTaskToSettle(); await store?.directMCP.drain(); store = nil
            await worker.drain(); try? await history.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
