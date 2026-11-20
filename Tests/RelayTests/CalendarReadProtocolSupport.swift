import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

/// Synthetic immutable backend only. It does not call EventKit, request access,
/// fabricate an SDK object or qualify the actual OS producer.
nonisolated final class CalendarProtocolBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var title = "OWNED_EVENT_CONTEXT"
    private var calls = 0
    private var failure = false
    private var nextPause: CalendarProtocolBarrier?
    var count: Int { lock.withLock { calls } }
    func change(_ value: String) { lock.withLock { title = value } }
    func fail() { lock.withLock { failure = true } }
    func pauseNext(_ barrier: CalendarProtocolBarrier) { lock.withLock { nextPause = barrier } }
    func read(_ query: CalendarReadQuery, current: @Sendable () -> Bool) throws -> CalendarReadSnapshot {
        let state = lock.withLock {
            calls += 1
            let value = (title, failure, nextPause)
            nextPause = nil
            return value
        }
        let result = Self.snapshot(query, title: state.0)
        state.2?.pause()
        guard current() else { throw CalendarReadFailure.unavailable }
        if state.1 { throw NSError(domain: "PRIVATE_SDK_FIELD_MUST_NOT_ESCAPE", code: 91,
                                   userInfo: [NSLocalizedDescriptionKey: state.0]) }
        return result
    }
    static func event(_ query: CalendarReadQuery, index: Int = 0, title: String = "OWNED_EVENT_CONTEXT") -> CalendarReadEvent {
        let start = query.start.addingTimeInterval(Double(index + 1) * 60)
        return .init(calendarID: query.identifiers[0], itemID: Data("item-\(index)".utf8), eventID: Data("event-\(index)".utf8),
            occurrence: start, title: title, calendarName: "Owned synthetic calendar",
            start: start, end: start.addingTimeInterval(30), allDay: false, timeZoneID: nil,
            status: .tentative, fieldLimited: false)
    }
    static func snapshot(_ query: CalendarReadQuery, title: String = "OWNED_EVENT_CONTEXT") -> CalendarReadSnapshot {
        .init(query: query, events: [event(query, title: title)], producerLimited: false, byteLimited: false, capturedAt: Date())
    }
}

nonisolated final class CalendarProtocolBarrier: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var began = false, released = false
    var entered: Bool { lock.withLock { began } }
    func pause() {
        lock.withLock { began = true }
        _ = semaphore.wait(timeout: .now() + 8)
    }
    func release() {
        let shouldSignal = lock.withLock { let value = !released; released = true; return value }
        if shouldSignal { semaphore.signal() }
    }
}

@MainActor final class CalendarProtocolFixture {
    let source: CalendarSource
    let backend: CalendarProtocolBackend
    let worker: CalendarEventReadWorker
    let root: URL, history: AssistantConversationHistory
    let context: MultiAgentContinuation.Context, run: AssistantConversationHistory.Run
    let proposal = UUID()
    var current: MultiAgentContinuation.Context?, active = true
    init() throws {
        // Existing status-only initializer, never an event query.
        let source = CalendarSource(), backend = CalendarProtocolBackend()
        let context = MultiAgentContinuation.Context(logicalTaskID: UUID(), configuration: .init(), scopeID: UUID(), sourceRevision: 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-calendar-protocol-" + UUID().uuidString)
        self.source = source; self.backend = backend; self.context = context; self.current = context; self.root = root
        worker = CalendarEventReadWorker(readForTesting: { query, current in try backend.read(query, current: current) })
        run = try .init(logicalTaskID: context.logicalTaskID, cause: .newRequest)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json"))
        source.selectedCalendarIDs = ["owned-synthetic-selection"]
    }
    func call(_ id: String = "calendar-caf\u{e9}") -> Relay.ToolCall {
        .init(id: id, name: "read_calendar", arguments: ["days": .string("7")])
    }
    func scope(_ call: Relay.ToolCall, proposal: UUID? = nil) throws -> CalendarReadExecutionScope {
        try .init(run: run, proposalID: proposal ?? self.proposal, call: call, context: context, source: source.calendarReadSeed(),
            currentContext: { [weak self] in self?.current }, currentSource: { [weak self] in self?.source.calendarReadSeed() },
            isCurrent: { [weak self] in self?.active == true }, start: Date(timeIntervalSince1970: 1_700_000_000))
    }
    func produce(_ call: Relay.ToolCall? = nil, proposal: UUID? = nil) async throws -> CalendarEventReadWorker.ProducedResult {
        let call = call ?? self.call()
        return try await worker.read(call: call, scope: scope(call, proposal: proposal))
    }
    func settled(_ registry: CalendarReadResultSources, call: Relay.ToolCall? = nil, proposal: UUID? = nil)
        async throws -> (ToolResult, AssistantConversationHistory.CalendarReadSettlement) {
        let call = call ?? self.call(), proposal = proposal ?? self.proposal
        let scope = try scope(call, proposal: proposal)
        var token: AssistantConversationHistory.CalendarReadSettlement?, registrationError: (any Error)?
        let result = try await history.perform(call, proposalID: proposal, run: run,
            validate: { try scope.validateCurrent(call: call) },
            action: { try await self.worker.read(call: call, scope: scope).result }, result: { $0 },
            unsavedResult: { _ in Issue.record("Unexpected calendar result save failure in success fixture.") },
            settledCalendarReadResult: { result, value in
                token = value
                do { try registry.registerSettled(call: call, result: result, run: self.run,
                    proposalID: proposal, context: self.context, settlement: value) }
                catch { registrationError = error }
            })
        if let registrationError { throw registrationError }
        return (result, try #require(token))
    }
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
        active = false; current = nil
        await worker.drain(); try? await history.close(); try? FileManager.default.removeItem(at: root)
    }
}

@MainActor func waitForCalendarBarrier(_ barrier: CalendarProtocolBarrier) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !barrier.entered { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(2)) }
}
@MainActor func withCalendarProtocol(_ body: @MainActor (CalendarProtocolFixture) async throws -> Void) async throws {
    let fixture = try CalendarProtocolFixture()
    do { try await body(fixture); await fixture.close() }
    catch { await fixture.close(); throw error }
}
