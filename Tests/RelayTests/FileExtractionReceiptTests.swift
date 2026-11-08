import Dispatch
import Foundation
import Testing
@preconcurrency import LiteRTLM
@testable import Relay

/// Inert protocol endpoint only; the actual file/receipt/lease path is used.
@MainActor private final class ExtractionAdmissionRuntime: LocalModelRuntime {
    var creates = 0, sends = 0
    var received: [String] = []
    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
        creates += 1; return ExtractionAdmissionSession(owner: self)
    }
}
@MainActor private final class ExtractionAdmissionSession: LocalConversationSession {
    unowned let owner: ExtractionAdmissionRuntime
    init(owner: ExtractionAdmissionRuntime) { self.owner = owner }
    func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
        owner.sends += 1
        owner.received += message.contents.compactMap { if case let .text(value) = $0 { value } else { nil } }
        return LiteRTLM.Message("SYNTHETIC_INERT_REPLY", role: .model)
    }
    nonisolated func cancel() { }
}

/// Only owned temporary files and actual parser inputs. No model, app control,
/// OCR/Vision runtime, network, personal source or fabricated proof is used.
@Suite(.serialized) @MainActor struct FileExtractionReceiptTests {
    nonisolated private struct OldWire: Codable {
        let summary: String, evidence: String
        let verified: Bool
        let artifactPath: String?
    }
    @MainActor private final class Fixture {
        let root: URL, file: URL
        let run: AssistantConversationHistory.Run
        var context: MultiAgentContinuation.Context
        var current: MultiAgentContinuation.Context?
        var grants: [ScopeGrant]
        var live = true
        init(extension ext: String = "txt", data: Data = Data("OWNED_ACTUAL_INPUT\n".utf8)) throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "relay-actual-extraction-" + UUID().uuidString)
            let selected = directory.appending(path: "selected." + ext), task = UUID()
            let actualRun = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
            let actualContext = MultiAgentContinuation.Context(logicalTaskID: task,
                configuration: .init(modelPath: "/owned/inert-model"), scopeID: UUID(), sourceRevision: 1)
            root = directory; file = selected; run = actualRun; context = actualContext
            current = actualContext; grants = [ScopeGrant(path: directory.path)]
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try data.write(to: selected)
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        func call(_ id: String = "actual-call") -> Relay.ToolCall {
            Relay.ToolCall(id: id, name: "read_file", arguments: ["path": .string(file.path)])
        }
        func scope(_ call: Relay.ToolCall, proposal: UUID) throws -> FileReadExecutionScope {
            try FileReadExecutionScope(run: run, proposalID: proposal, call: call, context: context,
                currentContext: { [weak self] in self?.current },
                grants: { [weak self] in self?.grants ?? [] }, isCurrent: { [weak self] in self?.live == true })
        }
        func remove() throws { try FileManager.default.removeItem(at: root) }
    }
    private func withFixture(extension ext: String = "txt", data: Data = Data("OWNED_ACTUAL_INPUT\n".utf8),
        _ body: @MainActor (Fixture, FileExtractionWorker) async throws -> Void) async throws {
        let fixture = try Fixture(extension: ext, data: data)
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
        do { try await body(fixture, worker); await worker.drain(); try fixture.remove() }
        catch { await worker.drain(); try? fixture.remove(); throw error }
    }
    private func unavailable(_ action: @MainActor () async throws -> Void) async {
        do { try await action(); Issue.record("A stale or mismatched actual receipt was accepted.") }
        catch { #expect(error is FileExtractionWorker.Failure || error is CancellationError) }
    }
    private func consume(_ result: Relay.ToolResult, call: Relay.ToolCall, fixture: Fixture, proposal: UUID) throws -> ModelInputSourceProof {
        try #require(result.fileExtractionReceipt).consume(call: call, result: result,
            run: fixture.run, proposalID: proposal, context: fixture.context)
    }

    @Test func actualMacToolsReadUsesExplicitScopeAndKeepsTheExactOldWire() async throws {
        try await withFixture { fixture, worker in
            let tools = MacTools(); tools.grants = fixture.grants
            let call = fixture.call(), proposal = UUID()
            let result = try await tools.execute(call, fileReadScope: fixture.scope(call, proposal: proposal), fileReadWorker: worker)
            #expect(result.summary == "OWNED_ACTUAL_INPUT\n" && result.verified)
            let proof = try consume(result, call: call, fixture: fixture, proposal: proposal)
            try await proof.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let actual = try encoder.encode(result)
            let expected = try encoder.encode(OldWire(summary: result.summary, evidence: result.evidence,
                verified: result.verified, artifactPath: result.artifactPath))
            #expect(actual == expected)
            let restored = try JSONDecoder().decode(Relay.ToolResult.self, from: actual)
            #expect(restored.fileExtractionReceipt == nil && restored.summary == result.summary)
            let visibleOnly = try await tools.execute(fixture.call("unbound-call"), fileReadWorker: worker)
            #expect(visibleOnly.fileExtractionReceipt == nil && visibleOnly.summary == result.summary)
            await worker.drain()
            #expect(worker.activeCount == 0)
        }
    }

    @Test func receiptIsExactByteBoundToNamespaceCallAndResultAndConsumedOnce() async throws {
        try await withFixture { fixture, worker in
            let call = fixture.call("caf\u{00e9}"), proposal = UUID()
            let result = try await worker.extract(call: call, grants: fixture.grants, scope: fixture.scope(call, proposal: proposal))
            let receipt = try #require(result.fileExtractionReceipt)
            var otherID = call; otherID.id = "cafe\u{0301}"
            await unavailable { _ = try receipt.consume(call: otherID, result: result, run: fixture.run, proposalID: proposal, context: fixture.context) }
            await unavailable { _ = try receipt.consume(call: call, result: result, run: fixture.run, proposalID: UUID(), context: fixture.context) }
            let otherRun = try AssistantConversationHistory.Run(logicalTaskID: fixture.context.logicalTaskID, cause: .newRequest)
            await unavailable { _ = try receipt.consume(call: call, result: result, run: otherRun, proposalID: proposal, context: fixture.context) }
            var altered = result; altered.summary += "FORGED"
            await unavailable { _ = try receipt.consume(call: call, result: altered, run: fixture.run, proposalID: proposal, context: fixture.context) }
            var changedCall = call; changedCall.arguments["path"] = .string(fixture.root.appending(path: "other.txt").path)
            await unavailable { _ = try receipt.consume(call: changedCall, result: result, run: fixture.run, proposalID: proposal, context: fixture.context) }
            let proof = try consume(result, call: call, fixture: fixture, proposal: proposal)
            try await proof.validate()
            await unavailable { _ = try receipt.consume(call: call, result: result, run: fixture.run, proposalID: proposal, context: fixture.context) }
        }
    }

    @Test func transformedMailReceiptBindsActualRawMIMEBytes() async throws {
        let original = Data("From: claimed@example.invalid\r\nSubject: OWNED SUBJECT\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nOWNED MAIL BODY\r\n".utf8)
        try await withFixture(extension: "eml", data: original) { fixture, worker in
            let call = fixture.call(), proposal = UUID()
            let result = try await worker.extract(call: call, grants: fixture.grants, scope: fixture.scope(call, proposal: proposal))
            #expect(result.summary.contains("OWNED MAIL BODY") && result.summary.contains("OWNED SUBJECT"))
            #expect(Data(result.summary.utf8) != original)
            let proof = try consume(result, call: call, fixture: fixture, proposal: proposal)
            try await proof.validate()
            let changed = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "OWNED SUBJECT", with: "OTHER SUBJECT").utf8)
            try changed.write(to: fixture.file)
            await unavailable { try await proof.validate() }
        }
    }

    @Test func canonicalEquivalentResultTextStillRequiresItsExactActualUTF8Bytes() async throws {
        try await withFixture(data: Data("caf\u{00e9}".utf8)) { fixture, worker in
            let call = fixture.call(), proposal = UUID()
            let result = try await worker.extract(call: call, grants: fixture.grants, scope: fixture.scope(call, proposal: proposal))
            var altered = result; altered.summary = "cafe\u{0301}"
            #expect(altered.summary == result.summary)
            #expect(!altered.summary.utf8.elementsEqual(result.summary.utf8))
            await unavailable { _ = try consume(altered, call: call, fixture: fixture, proposal: proposal) }
            let proof = try consume(result, call: call, fixture: fixture, proposal: proposal)
            try await proof.validate()
        }
    }

    @Test func PDFReceiptBindsActualParserInputEvenWhenExtractedTextWouldBeUnchanged() async throws {
        let pdf = try await LocalArtifacts.makePDF(title: "OWNED PDF", body: "EXACT_PARSER_INPUT_BODY")
        try await withFixture(extension: "pdf", data: pdf) { fixture, worker in
            let call = fixture.call(), proposal = UUID()
            let result = try await worker.extract(call: call, grants: fixture.grants, scope: fixture.scope(call, proposal: proposal))
            #expect(result.summary.contains("EXACT_PARSER_INPUT_BODY") && result.summary.contains("[Page 1]"))
            let proof = try consume(result, call: call, fixture: fixture, proposal: proposal)
            try await proof.validate()
            var sameDocumentDifferentBytes = pdf; sameDocumentDifferentBytes.append(Data("\n% owned trailing comment\n".utf8))
            try sameDocumentDifferentBytes.write(to: fixture.file)
            await unavailable { try await proof.validate() }
        }
    }

    @Test func boundedPartialTextCanBeReusedOnlyWhileItsWholeActualInputIsCurrent() async throws {
        let bytes = Data((String(repeating: "x", count: 12_000) + "UNRETURNED_TAIL_A").utf8)
        try await withFixture(data: bytes) { fixture, worker in
            let call = fixture.call(), proposal = UUID()
            let result = try await worker.extract(call: call, grants: fixture.grants, scope: fixture.scope(call, proposal: proposal))
            #expect(result.summary.contains("Content truncated") && !result.summary.contains("UNRETURNED_TAIL_A"))
            let proof = try consume(result, call: call, fixture: fixture, proposal: proposal)
            try await proof.validate()
            try Data((String(repeating: "x", count: 12_000) + "UNRETURNED_TAIL_B").utf8).write(to: fixture.file)
            await unavailable { try await proof.validate() }
        }
    }

    @Test(arguments: ["inode", "grants", "config", "scope", "nilContext", "task", "stop"])
    func currentRawIdentityAndFullContextAreRequiredAtEveryPrivateAdmission(change: String) async throws {
        try await withFixture { fixture, worker in
            let call = fixture.call(), proposal = UUID()
            let result = try await worker.extract(call: call, grants: fixture.grants, scope: fixture.scope(call, proposal: proposal))
            let proof = try consume(result, call: call, fixture: fixture, proposal: proposal)
            switch change {
            case "inode": try Data("OWNED_ACTUAL_INPUT\n".utf8).write(to: fixture.file, options: .atomic)
            case "grants": fixture.grants = []
            case "config": fixture.current = .init(logicalTaskID: fixture.context.logicalTaskID,
                configuration: .init(modelPath: "/other/inert-model"), scopeID: fixture.context.scopeID, sourceRevision: fixture.context.sourceRevision)
            case "scope": fixture.current = .init(logicalTaskID: fixture.context.logicalTaskID,
                configuration: fixture.context.configuration, scopeID: UUID(), sourceRevision: fixture.context.sourceRevision)
            case "nilContext": fixture.current = nil
            case "task": fixture.current = .init(logicalTaskID: UUID(), configuration: fixture.context.configuration,
                scopeID: fixture.context.scopeID, sourceRevision: fixture.context.sourceRevision)
            default: fixture.live = false
            }
            await unavailable { try await proof.validate() }
        }
    }

    @Test func moreThan1024SameSourceProposalsRemainOneStableLeafWithoutAnActionCap() async throws {
        try await withFixture { fixture, worker in
            var combined: ModelInputSourceProof?
            for index in 0...1_024 {
                let call = fixture.call("actual-\(index)"), proposal = UUID()
                let result = try await worker.extract(call: call, grants: fixture.grants, scope: fixture.scope(call, proposal: proposal))
                combined = try ModelInputSourceProof.merging([combined, consume(result, call: call, fixture: fixture, proposal: proposal)])
                #expect(combined?.dependencyCount == 1)
            }
            try await #require(combined).validate()
            #expect(try Data(contentsOf: fixture.file) == Data("OWNED_ACTUAL_INPUT\n".utf8))
        }
    }

    @Test func malformedOrOversizeInputsNeverMintAReceiptAndReleaseTheSlot() async throws {
        for (ext, data) in [("pdf", Data("not a PDF".utf8)), ("txt", Data(repeating: 1, count: 1_048_577)),
                            ("eml", Data(repeating: 1, count: 1_048_577))] {
            try await withFixture(extension: ext, data: data) { fixture, worker in
                let call = fixture.call()
                do {
                    _ = try await worker.extract(call: call, grants: fixture.grants, scope: fixture.scope(call, proposal: UUID()))
                    Issue.record("Invalid bounded parser input unexpectedly returned a receipt.")
                } catch { }
                await worker.drain(); #expect(worker.activeCount == 0)
            }
        }
    }
}

@Suite(.serialized) @MainActor struct FileExtractionWorkerLifetimeTests {
    nonisolated private final class Barrier: @unchecked Sendable {
        private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
        private var started = false, released = false
        var entered: Bool { lock.withLock { started } }
        func pause() { lock.withLock { started = true }; gate.wait() }
        func release() { let signal = lock.withLock { let value = !released; released = true; return value }; if signal { gate.signal() } }
    }
    private func entered(_ barrier: Barrier) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !barrier.entered {
            guard ContinuousClock.now < deadline else { throw FileExtractionWorker.Failure.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func StopReturnsWhileRealSnapshotIsSuspendedAndKeepsOnePhysicalSlotUntilDrain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-extraction-lifetime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appending(path: "actual.txt"), bytes = Data("OWNED_CANCELLABLE_READ".utf8)
        try bytes.write(to: file)
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5)), barrier = Barrier()
        let grants = [ScopeGrant(path: root.path)]
        let call = Relay.ToolCall(id: "cancel-actual", name: "read_file", arguments: ["path": .string(file.path)])
        var privateOutputs = 0
        worker.pauseAfterNextSnapshot { barrier.pause() }
        let task = Task { @MainActor in
            _ = try await worker.extract(call: call, grants: grants, scope: nil)
            privateOutputs += 1
        }
        do {
            try await entered(barrier)
            let before = ContinuousClock.now
            task.cancel()
            do { try await task.value; Issue.record("Cancelled extraction published output.") } catch is CancellationError { }
            #expect(ContinuousClock.now - before < .seconds(1))
            #expect(privateOutputs == 0 && worker.activeCount == 1)
            do { _ = try await worker.extract(call: call, grants: grants, scope: nil); Issue.record("A second physical slot was queued.") }
            catch let error as FileExtractionWorker.Failure { #expect(error == .busy) }
            barrier.release(); await worker.drain()
            #expect(worker.activeCount == 0 && privateOutputs == 0)
            #expect(try Data(contentsOf: file) == bytes)
            try FileManager.default.removeItem(at: root)
        } catch {
            task.cancel(); barrier.release(); _ = await task.result; await worker.drain()
            try? FileManager.default.removeItem(at: root); throw error
        }
    }

    @Test func timeoutDiscardsLateBytesWithoutReleasingThePhysicalSlotEarly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-extraction-timeout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appending(path: "actual.txt")
        try Data("OWNED_TIMEOUT_INPUT".utf8).write(to: file)
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5)), barrier = Barrier()
        let call = Relay.ToolCall(id: "timeout-actual", name: "read_file", arguments: ["path": .string(file.path)])
        worker.pauseAfterNextSnapshot { barrier.pause() }
        var published = 0
        let task = Task { @MainActor in
            _ = try await worker.extract(call: call, grants: [ScopeGrant(path: root.path)], scope: nil)
            published += 1
        }
        do {
            try await entered(barrier)
            do { try await task.value; Issue.record("Expired extraction published private output.") }
            catch let error as FileExtractionWorker.Failure { #expect(error == .timedOut) }
            #expect(worker.activeCount == 1 && published == 0)
            barrier.release(); await worker.drain()
            #expect(worker.activeCount == 0 && published == 0)
            #expect(try Data(contentsOf: file) == Data("OWNED_TIMEOUT_INPUT".utf8))
            try FileManager.default.removeItem(at: root)
        } catch {
            task.cancel(); barrier.release(); _ = await task.result; await worker.drain()
            try? FileManager.default.removeItem(at: root); throw error
        }
    }

    @Test(arguments: ["source", "grants", "symlink"])
    func actualSnapshotCannotBePublishedAfterSourceOrGrantRevocationDuringTheRead(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-extraction-revoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let selected = root.appending(path: "selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let file = selected.appending(path: "actual.txt"), alias = selected.appending(path: "alias.txt")
        let outside = root.appending(path: "outside.txt")
        try Data("ORIGINAL_SNAPSHOT".utf8).write(to: file)
        try Data("OUTSIDE_SELECTED_SCOPE".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: file.path)
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let context = MultiAgentContinuation.Context(logicalTaskID: run.relation.logicalTaskID,
            configuration: .init(), scopeID: UUID(), sourceRevision: 0)
        var grants = [ScopeGrant(path: selected.path)]
        let call = Relay.ToolCall(id: "revoke-actual", name: "read_file", arguments: ["path": .string(alias.path)])
        let scope = try FileReadExecutionScope(run: run, proposalID: UUID(), call: call, context: context,
            currentContext: { context }, grants: { grants }, isCurrent: { true })
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5)), barrier = Barrier()
        worker.pauseAfterNextSnapshot { barrier.pause() }
        let task = Task { @MainActor in try await worker.extract(call: call, grants: grants, scope: scope) }
        do {
            try await entered(barrier)
            switch change {
            case "grants": grants = []
            case "source": try Data("CHANGED_SNAPSHOT".utf8).write(to: file)
            default:
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: outside.path)
            }
            barrier.release()
            var returnedPrivateOutput = false
            do { _ = try await task.value; returnedPrivateOutput = true }
            catch { }
            #expect(!returnedPrivateOutput)
            await worker.drain(); #expect(worker.activeCount == 0)
            #expect(try Data(contentsOf: file) == Data((change == "source" ? "CHANGED_SNAPSHOT" : "ORIGINAL_SNAPSHOT").utf8))
            #expect(try Data(contentsOf: outside) == Data("OUTSIDE_SELECTED_SCOPE".utf8))
            try FileManager.default.removeItem(at: root)
        } catch {
            task.cancel(); barrier.release(); _ = await task.result; await worker.drain()
            try? FileManager.default.removeItem(at: root); throw error
        }
    }

    @Test func flatProofRechecksCurrentGrantsAfterAnActualSuspendedRevalidation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-extraction-proof-grant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appending(path: "actual.txt"), bytes = Data("UNCHANGED_ACTUAL_INPUT".utf8)
        try bytes.write(to: file)
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let context = MultiAgentContinuation.Context(logicalTaskID: run.relation.logicalTaskID,
            configuration: .init(), scopeID: UUID(), sourceRevision: 0)
        var grants = [ScopeGrant(path: root.path)]
        let call = Relay.ToolCall(id: "grant-during-proof", name: "read_file", arguments: ["path": .string(file.path)])
        let proposal = UUID()
        let scope = try FileReadExecutionScope(run: run, proposalID: proposal, call: call, context: context,
            currentContext: { context }, grants: { grants }, isCurrent: { true })
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5)), barrier = Barrier()
        var pending: Task<Void, any Error>?
        do {
            let result = try await worker.extract(call: call, grants: grants, scope: scope)
            let proof = try #require(result.fileExtractionReceipt).consume(call: call, result: result,
                run: run, proposalID: proposal, context: context)
            worker.pauseAfterNextSnapshot { barrier.pause() }
            var inertPrivateSends = 0
            let validating = Task { @MainActor in try await proof.validate(); inertPrivateSends += 1 }
            pending = validating
            try await entered(barrier)
            grants = []
            barrier.release()
            do { try await validating.value; Issue.record("Revoked grants admitted the old proof.") }
            catch let error as FileExtractionWorker.Failure { #expect(error == .unavailable) }
            pending = nil
            #expect(inertPrivateSends == 0)
            grants = [ScopeGrant(path: root.path)]
            try await proof.validate()
            await worker.drain(); #expect(worker.activeCount == 0)
            #expect(try Data(contentsOf: file) == bytes)
            try FileManager.default.removeItem(at: root)
        } catch {
            pending?.cancel(); barrier.release(); _ = await pending?.result; await worker.drain()
            try? FileManager.default.removeItem(at: root); throw error
        }
    }

    @Test func cancelledActualExtractionProofCannotHoldTheInferenceLeaseOrAdmitLatePrivateInput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-extraction-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appending(path: "actual.txt"), model = root.appending(path: "inert.litertlm")
        let privateText = "OWNED_EXTRACTION_PRIVATE_MUST_NOT_SEND"
        try Data(privateText.utf8).write(to: file); try Data([1]).write(to: model)
        let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
        let configuration = ModelConfiguration(modelPath: model.path)
        let context = MultiAgentContinuation.Context(logicalTaskID: run.relation.logicalTaskID,
            configuration: configuration, scopeID: UUID(), sourceRevision: 0)
        let grants = [ScopeGrant(path: root.path)], proposal = UUID()
        let call = Relay.ToolCall(id: "blocked-proof-actual", name: "read_file", arguments: ["path": .string(file.path)])
        let scope = try FileReadExecutionScope(run: run, proposalID: proposal, call: call, context: context,
            currentContext: { context }, grants: { grants }, isCurrent: { true })
        let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5)), barrier = Barrier()
        let runtime = ExtractionAdmissionRuntime()
        let router = LocalInferenceRouter(embedded: LocalModelClient(runtimeFactory: { _,_,_ in runtime }), lease: LocalInferenceLease())
        var pending: Task<Relay.ModelReply, any Error>?
        do {
            let result = try await worker.extract(call: call, grants: grants, scope: scope)
            let proof = try #require(result.fileExtractionReceipt).consume(call: call, result: result,
                run: run, proposalID: proposal, context: context)
            worker.pauseAfterNextSnapshot { barrier.pause() }
            let completion = Task { @MainActor in
                try await router.complete(messages: [.init(role: "user", content: result.summary)], tools: [],
                    configuration: configuration, sourceAuthorization: proof.validator)
            }
            pending = completion
            try await entered(barrier)
            #expect(runtime.creates == 0 && runtime.sends == 0)
            completion.cancel()
            do { _ = try await completion.value; Issue.record("Cancelled private input completed.") } catch is CancellationError { }
            pending = nil
            #expect(worker.activeCount == 1)
            let independent = try await router.complete(messages: [.init(role: "user", content: "INDEPENDENT_SOURCE_FREE")],
                tools: [], configuration: configuration)
            #expect(independent.content == "SYNTHETIC_INERT_REPLY" && runtime.creates == 1 && runtime.sends == 1)
            #expect(!runtime.received.contains { $0.contains(privateText) })
            barrier.release(); await worker.drain()
            #expect(worker.activeCount == 0 && runtime.sends == 1)
            router.unload(); try FileManager.default.removeItem(at: root)
        } catch {
            pending?.cancel(); barrier.release(); _ = await pending?.result
            await worker.drain(); router.unload(); try? FileManager.default.removeItem(at: root); throw error
        }
    }
}
