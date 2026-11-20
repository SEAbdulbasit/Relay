import Darwin
import Dispatch
import Foundation
import Testing
@testable import Relay

/// Owned fixture IO must not monopolize the UI actor while unrelated
/// cancellation/deadline tests exercise the actual production boundaries.
nonisolated private enum FilenameQueryFixtureIO {
    @concurrent static func populate(folder: URL, prefix: String, count: Int) async throws {
        for index in 0..<count {
            try Task.checkCancellation()
            try Data().write(to: folder.appendingPathComponent("\(prefix)-\(index).txt"))
        }
    }
    @concurrent static func remove(_ root: URL) async {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class FilenameSearchFixture {
    let root: URL, selected: URL, outside: URL, file: URL
    let context: MultiAgentContinuation.Context, run: AssistantConversationHistory.Run, proposal = UUID()
    var current: MultiAgentContinuation.Context?, grants: [ScopeGrant], active = true
    let worker: FilenameSearchWorker
    init(timeout: Duration = .seconds(10)) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-query-proof-" + UUID().uuidString, isDirectory: true)
        selected = root.appendingPathComponent("selected", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        file = selected.appendingPathComponent("meeting-needle.txt")
        try Data("OWNED bytes are not search input".utf8).write(to: file)
        try Data("OUTSIDE source".utf8).write(to: outside.appendingPathComponent("private-needle.txt"))
        context = .init(logicalTaskID: UUID(), configuration: .init(), scopeID: UUID(), sourceRevision: 0)
        current = context; grants = [.init(path: selected.path)]; worker = FilenameSearchWorker(timeout: timeout)
        run = try .init(logicalTaskID: context.logicalTaskID, cause: .newRequest)
    }
    func call(_ query: String = "needle", id: String = "original-query") -> Relay.ToolCall {
        .init(id: id, name: "search_files", arguments: ["query": .string(query)])
    }
    func scope(_ call: Relay.ToolCall, proposal: UUID? = nil) throws -> FilenameSearchExecutionScope {
        try .init(run: run, proposalID: proposal ?? self.proposal, call: call, context: context,
            currentContext: { [self] in current }, grants: { [self] in grants }, isCurrent: { [self] in active })
    }
    func produce(_ call: Relay.ToolCall? = nil) async throws -> FilenameSearchWorker.ProducedResult {
        let value = call ?? self.call(); return try await worker.search(call: value, scope: scope(value))
    }
    func validate(_ value: FilenameSearchWorker.ProducedResult, call: Relay.ToolCall? = nil,
                  result: ToolResult? = nil, proposal: UUID? = nil,
                  run: AssistantConversationHistory.Run? = nil) async throws {
        try await value.receipt.validateProducedResult(call: call ?? self.call(), result: result ?? value.result,
            run: run ?? self.run, proposalID: proposal ?? self.proposal, context: context)
    }
    func close() async {
        active = false; current = nil; await worker.drain(); await FilenameQueryFixtureIO.remove(root)
    }
}

@MainActor struct FilenameSearchReceiptTests {
    @Test func actualSelectedQueryHasReusableDataValidationAndNoOutsideResult() async throws {
        let f = try FilenameSearchFixture()
        do {
            let expectedPath = try ToolPolicy.canonicalURL(f.file.path).path
            let produced = try await f.produce()
            #expect(produced.result.verified && produced.result.summary.contains(expectedPath))
            #expect(!produced.result.summary.contains("private-needle"))
            #expect(produced.result.evidence.contains("file contents were not read"))
            try await f.validate(produced); try await f.validate(produced)
            // No result parsing or body lookup creates another receipt.
            let secondCall = f.call()
            let second = try await f.worker.search(call: secondCall, scope: f.scope(secondCall, proposal: UUID()))
            #expect(produced.receipt !== second.receipt)
            #expect(try produced.receipt.sourceIdentity == second.receipt.sourceIdentity)
            let ordinary = try await ScopedFileOperations.search(query: "needle", grants: f.grants, worker: f.worker)
            #expect(ordinary.matches.count == 1 && ordinary.matches[0].path == expectedPath)
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test(arguments: ["rename", "replacement", "new_member", "nonmatching_member", "directory_replacement", "content_metadata"])
    func actualMetadataDriftRefusesTheOldQuery(_ change: String) async throws {
        let f = try FilenameSearchFixture()
        do {
            let value = try await f.produce()
            switch change {
            case "rename": try FileManager.default.moveItem(at: f.file, to: f.selected.appendingPathComponent("renamed-needle.txt"))
            case "replacement":
                let replacement = f.selected.appendingPathComponent("replacement.txt")
                try Data("OWNED bytes are not search input".utf8).write(to: replacement)
                try FileManager.default.removeItem(at: f.file); try FileManager.default.moveItem(at: replacement, to: f.file)
            case "new_member": try Data().write(to: f.selected.appendingPathComponent("another-needle.txt"))
            case "nonmatching_member": try Data().write(to: f.selected.appendingPathComponent("unrelated.txt"))
            case "directory_replacement":
                try FileManager.default.moveItem(at: f.selected, to: f.root.appendingPathComponent("old-selected"))
                try FileManager.default.createDirectory(at: f.selected, withIntermediateDirectories: false)
                try Data("OWNED bytes are not search input".utf8).write(to: f.file)
            default: try Data("metadata changes, not extraction".utf8).write(to: f.file)
            }
            await #expect(throws: FilenameSearchWorker.Failure.self) { try await f.validate(value) }
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test(arguments: ["grant", "grant_mode", "context", "configuration", "stop", "provider", "query", "proposal", "run", "result", "unicode_result"])
    func namespaceAndCurrentScopeCannotBeSubstituted(_ change: String) async throws {
        let f = try FilenameSearchFixture()
        do {
            let value = try await f.produce()
            var call = f.call(), result = value.result, proposal = f.proposal, run = f.run
            switch change {
            case "grant": f.grants = [.init(path: f.outside.path)]
            case "grant_mode": f.grants[0].writable.toggle()
            case "context": f.current = .init(logicalTaskID: f.context.logicalTaskID, configuration: f.context.configuration, scopeID: UUID(), sourceRevision: 0)
            case "configuration": var configuration = f.context.configuration; configuration.modelPath += "-changed"; f.current = .init(logicalTaskID: f.context.logicalTaskID, configuration: configuration, scopeID: f.context.scopeID, sourceRevision: 0)
            case "stop": f.active = false
            case "provider": call = f.call(id: "different-provider-id")
            case "query": call = f.call("meeting")
            case "proposal": proposal = UUID()
            case "run": run = try .init(logicalTaskID: f.context.logicalTaskID, predecessor: f.run, cause: .resume)
            case "result": result.summary += " forged.txt"
            default: result.evidence += " caf\u{65}\u{301}"
            }
            await #expect(throws: (any Error).self) { try await f.validate(value, call: call, result: result, proposal: proposal, run: run) }
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func hiddenAndSymlinkDescendantsNeverExpandScope() async throws {
        let f = try FilenameSearchFixture()
        do {
            try FileManager.default.createSymbolicLink(at: f.selected.appendingPathComponent("outside-link"), withDestinationURL: f.outside)
            try Data().write(to: f.selected.appendingPathComponent(".hidden-needle.txt"))
            let value = try await f.produce(); try await f.validate(value)
            #expect(!value.result.summary.contains("hidden") && !value.result.summary.contains("private-needle"))
            #expect(value.result.evidence.contains("excluded 1 symlinks"))
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func exactFileGrantAndNestedDirectoryQueryHavePositiveProofs() async throws {
        let f = try FilenameSearchFixture()
        do {
            f.grants = [.init(path: f.file.path)]
            let file = try await f.produce(); try await f.validate(file)
            #expect(file.result.summary.contains(f.file.path))
            f.grants = [.init(path: f.selected.path)]
            let nested = f.selected.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let found = nested.appendingPathComponent("nested-needle.txt"); try Data().write(to: found)
            let directory = try await f.produce(); try await f.validate(directory)
            #expect(directory.result.summary.contains(found.path))
            await #expect(throws: (any Error).self) { try await f.validate(file) }
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func providerAndResultUTF8SpellingsCannotAlias() async throws {
        let f = try FilenameSearchFixture()
        do {
            try Data().write(to: f.selected.appendingPathComponent("caf\u{e9}-needle.txt"))
            let original = f.call(id: "caf\u{e9}"), alias = f.call(id: "cafe\u{301}")
            #expect(original.id == alias.id && !original.id.utf8.elementsEqual(alias.id.utf8))
            let value = try await f.worker.search(call: original, scope: f.scope(original))
            try await f.validate(value, call: original)
            await #expect(throws: (any Error).self) { try await f.validate(value, call: alias) }
            var changed = value.result
            let composed = changed.summary.precomposedStringWithCanonicalMapping
            changed.summary = changed.summary.utf8.elementsEqual(composed.utf8)
                ? changed.summary.decomposedStringWithCanonicalMapping : composed
            #expect(changed.summary == value.result.summary)
            #expect(!changed.summary.utf8.elementsEqual(value.result.summary.utf8))
            await #expect(throws: (any Error).self) { try await f.validate(value, call: original, result: changed) }
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func stableTruncatedQueryRemainsExplicitlyIncomplete() async throws {
        let f = try FilenameSearchFixture()
        do {
            try await FilenameQueryFixtureIO.populate(folder: f.selected, prefix: "needle", count: 120)
            let value = try await f.produce()
            #expect(value.result.evidence.contains("more matches may exist"))
            #expect(value.result.summary.split(separator: "\n").count <= FilenameSearchTraversal.maximumMatches)
            try await f.validate(value)
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func exactEntryBudgetCannotDescribeAnUnvisitedSubtreeAsComplete() async throws {
        let f = try FilenameSearchFixture()
        do {
            let nested = f.selected.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data().write(to: nested.appendingPathComponent("unvisited-needle.txt"))
            // Existing matching file + this directory + 4998 nonmatches = the
            // exact actual producer cap, with no extra member to trip readdir.
            try await FilenameQueryFixtureIO.populate(folder: f.selected, prefix: "other", count: 4_998)
            let value = try await f.produce()
            #expect(value.result.evidence.contains("more matches may exist"))
            #expect(value.result.evidence.contains("entries"))
            #expect(!value.result.summary.contains("unvisited-needle.txt"))
            try await f.validate(value)
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func metadataWorkRunsAwayFromMainActorAndLateGrantChangeCannotPublish() async throws {
        let f = try FilenameSearchFixture(), gate = SearchMetadataGate()
        do {
            f.worker.pauseAfterNextTraversal { gate.pause() }
            let call = f.call(), scope = try f.scope(f.call())
            let task = Task { try await f.worker.search(call: call, scope: scope) }
            try await until { gate.entered }
            #expect(!gate.expired, "Actual4s metadata gate before revoke: \(gate.technicalSummary)")
            #expect(!gate.wasMainThread); f.grants.removeAll(); gate.release()
            await #expect(throws: (any Error).self) { _ = try await task.value }
            await f.close()
        } catch { gate.release(); await f.close(); throw error }
    }

    @Test(arguments: [false, true])
    func cancellationOrTimeoutKeepsThePhysicalSlotUntilDrain(_ timeout: Bool) async throws {
        let f = try FilenameSearchFixture(timeout: timeout ? .milliseconds(750) : .seconds(10)), gate = SearchMetadataGate()
        do {
            f.worker.pauseAfterNextTraversal { gate.pause() }
            let task = Task { try await f.produce() }
            try await until { gate.entered }
            #expect(!gate.expired, "Actual4s metadata gate before cancellation wait: \(gate.technicalSummary)")
            if !timeout { task.cancel() }
            await #expect(throws: (any Error).self) { _ = try await task.value }
            #expect(f.worker.activeCount == 1, "Actual4s metadata gate at physical-slot assertion: \(gate.technicalSummary)")
            await #expect(throws: FilenameSearchWorker.Failure.busy) { _ = try await f.produce() }
            gate.release(); await f.worker.drain(); #expect(f.worker.activeCount == 0)
            let current = try await f.produce(); try await f.validate(current)
            await f.close()
        } catch { gate.release(); await f.close(); throw error }
    }

    @Test(arguments: ["grant", "context", "stop"])
    func failedQueryStillChecksLiveScopeAfterItsAwait(_ change: String) async throws {
        let f = try FilenameSearchFixture(), gate = SearchMetadataGate()
        do {
            let call = f.call("bad/query"), scope = try f.scope(call)
            f.worker.pauseAfterNextTraversal { gate.pause() }
            let task = Task { try await f.worker.search(call: call, scope: scope) }
            try await until { gate.entered }
            #expect(!gate.expired, "Actual4s metadata gate before failed-query revoke: \(gate.technicalSummary)")
            switch change {
            case "grant": f.grants.removeAll()
            case "context": f.current = nil
            default: f.active = false
            }
            gate.release()
            do { _ = try await task.value; Issue.record("A revoked failed query unexpectedly returned a result.") }
            catch { #expect(!error.localizedDescription.contains("needle") && !error.localizedDescription.contains(f.selected.path)) }
            await f.close()
        } catch { gate.release(); await f.close(); throw error }
    }

    private func until(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() { guard ContinuousClock.now < deadline else { throw FilenameSearchWorker.Failure.timedOut }; try await Task.sleep(for: .milliseconds(2)) }
    }
}

/// Test-only finite delay after actual traversal. It cannot replace metadata.
nonisolated private final class SearchMetadataGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var began = false, released = false, main = true
    private var startedAt: ContinuousClock.Instant?, returnedAt: ContinuousClock.Instant?, releasedAt: ContinuousClock.Instant?
    private var didExpire = false
    var entered: Bool { lock.withLock { began } }
    var wasMainThread: Bool { lock.withLock { main } }
    var expired: Bool { lock.withLock { didExpire } }
    var technicalSummary: String {
        lock.withLock {
            guard let startedAt else { return "not-entered" }
            let end = returnedAt ?? .now
            let held = WorkerSettlementDiagnostics.milliseconds(startedAt.duration(to: end))
            let release = releasedAt.map { String(WorkerSettlementDiagnostics.milliseconds(startedAt.duration(to: $0))) } ?? "none"
            return "held_ms=\(held), expired=\(didExpire), returned=\(returnedAt != nil), explicit_release_ms=\(release)"
        }
    }
    func pause() {
        lock.withLock { began = true; main = Thread.isMainThread; startedAt = .now }
        let outcome = semaphore.wait(timeout: .now() + 4)
        lock.withLock { didExpire = outcome == .timedOut; returnedAt = .now }
    }
    func release() {
        let signal = lock.withLock { let signal = !released; released = true; if releasedAt == nil { releasedAt = .now }; return signal }
        if signal { semaphore.signal() }
    }
}
