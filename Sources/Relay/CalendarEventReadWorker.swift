import CryptoKit
import EventKit
import Foundation

@MainActor struct CalendarReadExecutionScope {
    fileprivate struct Namespace {
        let run: UUID, attempt: UUID, proposal: UUID
        let provider: Data, callDigest: String
    }
    fileprivate struct Fence {
        let context: MultiAgentContinuation.Context
        let seed: CalendarReadSeed
        let currentContext: @MainActor @Sendable () -> MultiAgentContinuation.Context?
        let currentSource: @MainActor @Sendable () -> CalendarReadSeed?
        let isCurrent: @MainActor @Sendable () -> Bool
        func check() throws {
            try Task.checkCancellation()
            guard isCurrent(), currentContext() == context,
                  let current = currentSource(), seed.matches(current),
                  seed.revocation.value == seed.epoch else { throw CalendarReadFailure.unavailable }
        }
    }
    fileprivate let namespace: Namespace, fence: Fence
    let query: CalendarReadQuery
    var executionContext: MultiAgentContinuation.Context { fence.context }
    init(run: AssistantConversationHistory.Run, proposalID: UUID, call: ToolCall,
         context: MultiAgentContinuation.Context, source: CalendarReadSeed,
         currentContext: @escaping @MainActor @Sendable () -> MultiAgentContinuation.Context?,
         currentSource: @escaping @MainActor @Sendable () -> CalendarReadSeed?,
         isCurrent: @escaping @MainActor @Sendable () -> Bool,
         start: Date = Date()) throws {
        guard call.name == "read_calendar", !call.id.isEmpty, call.id.utf8.count <= 4_096,
              run.relation.logicalTaskID == context.logicalTaskID,
              case .string(let rawDays) = call.arguments["days"], let days = Int(rawDays),
              !source.identifiers.isEmpty, source.identifiers.count == Set(source.identifiers).count else { throw CalendarReadFailure.unavailable }
        try ToolPolicy.validate(call, against: MacTools.definitions)
        let ids = try source.identifiers.map { bytes -> String in
            guard let value = String(data: bytes, encoding: .utf8), Data(value.utf8) == bytes else { throw CalendarReadFailure.unavailable }
            return value
        }
        let selected = Set(ids)
        guard CalendarSelectionIdentity.keys(selected) == Set(source.identifiers) else { throw CalendarReadFailure.unavailable }
        query = try CalendarReadQuery(ids: selected, start: start, days: days)
        namespace = Namespace(run: run.taskID, attempt: run.attemptID, proposal: proposalID,
            provider: Data(call.id.utf8), callDigest: ToolPolicy.fingerprint(call))
        fence = Fence(context: context, seed: source, currentContext: currentContext,
            currentSource: currentSource, isCurrent: isCurrent)
        try validateCurrent(call: call)
    }
    func validateCurrent(call: ToolCall) throws {
        try fence.check()
        guard call.name == "read_calendar", Data(call.id.utf8) == namespace.provider,
              ToolPolicy.fingerprint(call) == namespace.callDigest else { throw CalendarReadFailure.unavailable }
    }
    func matchesSource(_ source: CalendarReadSeed) -> Bool { fence.seed.matches(source) }
}

/// Only this actual producer file can mint a receipt. Restored ToolResults,
/// equal body hashes, UI refreshes and context-free executors cannot recreate it.
@MainActor final class CalendarReadReceipt {
    private let namespace: CalendarReadExecutionScope.Namespace
    private let fence: CalendarReadExecutionScope.Fence
    private let query: CalendarReadQuery
    private let contentDigest: Data, resultDigest: Data
    private let generation: UUID
    private let worker: CalendarEventReadWorker
    private var consumed = false
    fileprivate init(scope: CalendarReadExecutionScope, snapshot: CalendarReadSnapshot,
                     result: ToolResult, contentDigest: Data, generation: UUID, worker: CalendarEventReadWorker) throws {
        try scope.fence.check()
        namespace = scope.namespace; fence = scope.fence; query = snapshot.query
        self.contentDigest = contentDigest; resultDigest = Self.digest(result)
        self.generation = generation; self.worker = worker
    }
    nonisolated static func isBounded(_ result: ToolResult) -> Bool {
        result.summary.utf8.count <= CalendarReadCodec.maximumSummaryBytes && result.evidence.utf8.count <= 4_096 && result.artifactPath == nil
    }
    nonisolated static func digest(_ result: ToolResult) -> Data {
        Data(SHA256.hash(data: CalendarReadCodec.frame([Data("relay.calendar-result.v1".utf8),
            Data(result.summary.utf8), Data(result.evidence.utf8), Data([result.verified ? 1 : 0]),
            Data([result.artifactPath == nil ? 0 : 1]), Data((result.artifactPath ?? "").utf8)])))
    }
    private func matches(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                         proposalID: UUID, context: MultiAgentContinuation.Context) -> Bool {
        call.name == "read_calendar" && Self.isBounded(result) && result.calendarReadReceipt === self
            && namespace.run == run.taskID && namespace.attempt == run.attemptID
            && namespace.proposal == proposalID && namespace.provider == Data(call.id.utf8)
            && namespace.callDigest == ToolPolicy.fingerprint(call) && Self.digest(result) == resultDigest
            && context == fence.context
    }
    /// Synchronous, payload-free final publication fence. No SDK requery and
    /// no authority renewal while another included source is awaiting IO.
    func validateCurrent(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                         proposalID: UUID, context: MultiAgentContinuation.Context) throws {
        try fence.check()
        guard matches(call: call, result: result, run: run, proposalID: proposalID, context: context) else { throw CalendarReadFailure.unavailable }
        try worker.validateGeneration(generation)
    }
    func validateProducedResult(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                                proposalID: UUID, context: MultiAgentContinuation.Context) async throws {
        try validateCurrent(call: call, result: result, run: run, proposalID: proposalID, context: context)
        do {
            try await worker.validate(query, expectedDigest: contentDigest, generation: generation, seed: fence.seed)
            try validateCurrent(call: call, result: result, run: run, proposalID: proposalID, context: context)
        } catch { try fence.check(); if error is CancellationError { throw CancellationError() }; throw CalendarReadFailure.unavailable }
    }
    func consume(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run, proposalID: UUID,
                 context: MultiAgentContinuation.Context, settlement: AssistantConversationHistory.CalendarReadSettlement) throws -> ModelInputSourceProof {
        try validateCurrent(call: call, result: result, run: run, proposalID: proposalID, context: context)
        guard !consumed, matches(call: call, result: result, run: run, proposalID: proposalID, context: context),
              settlement.matches(call: call, result: result, run: run, proposalID: proposalID) else { throw CalendarReadFailure.unavailable }
        consumed = true
        // Extract metadata-only values: neither the receipt nor DTO/event text
        // is captured by this flat source leaf.
        let fence = fence, query = query, expected = contentDigest, generation = generation, worker = worker
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let source = CalendarReadCodec.frame([Data(fence.seed.owner.uuidString.utf8), Data(fence.seed.epoch.uuidString.utf8),
            Data(fence.seed.selectionEpoch.uuidString.utf8), Data(generation.uuidString.utf8), Data(fence.context.scopeID.uuidString.utf8),
            Data(String(fence.context.sourceRevision).utf8), try encoder.encode(fence.context.configuration), query.encoded, expected])
        return .source(identity: .init(owner: namespace.run, sourceID: Data(SHA256.hash(data: source)), purpose: "relay.actual-calendar-query.v1"), finalMetadata: {
            try fence.check()
            try worker.validateGeneration(generation)
        }) {
            try fence.check()
            do {
                try await worker.validate(query, expectedDigest: expected, generation: generation, seed: fence.seed)
                try fence.check()
            } catch { try fence.check(); if error is CancellationError { throw CancellationError() }; throw CalendarReadFailure.unavailable }
        }
    }
}

/// App-lifetime default owner: reset/new Source/new run cannot replace an
/// active physical SDK operation. Only DTOs/closed failures leave its queue.
@MainActor final class CalendarEventReadWorker {
    static let shared = CalendarEventReadWorker()
    struct ProducedResult { let result: ToolResult, receipt: CalendarReadReceipt }
    nonisolated struct Catalog: Sendable { let calendars: [CalendarSource.CalendarInfo]; let limited: Bool }
    private nonisolated enum Operation: Sendable { case events(CalendarReadQuery), catalog }
    private nonisolated struct CompletedRead: Sendable { let snapshot: CalendarReadSnapshot, digest: Data }
    private nonisolated enum Payload: Sendable { case events(CompletedRead), catalog(Catalog) }
    private nonisolated enum Resolution: Sendable { case value(Payload), failure(CalendarReadFailure), cancelled }
    private nonisolated final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var completed: Resolution?
        private var continuation: CheckedContinuation<Payload, any Error>?
        private var kernelDone = false
        #if DEBUG
        private let diagnostics: WorkerSettlementDiagnostics?
        private let operationID: UUID
        init(diagnostics: WorkerSettlementDiagnostics?, operationID: UUID) {
            self.diagnostics = diagnostics; self.operationID = operationID
        }
        #endif
        var pending: Bool { lock.lock(); defer { lock.unlock() }; return completed == nil }
        var isKernelDone: Bool { lock.lock(); defer { lock.unlock() }; return kernelDone }
        @discardableResult func completeFromKernel(_ result: Resolution) -> Bool {
            lock.lock()
            kernelDone = true
            lock.unlock()
            return complete(result)
        }
        func install(_ next: CheckedContinuation<Payload, any Error>) {
            lock.lock(); let result = completed
            if result == nil { continuation = next }
            lock.unlock()
            #if DEBUG
            diagnostics?.record(.waiterInstalled, operationID: operationID)
            if result != nil { diagnostics?.record(.continuationResumed, operationID: operationID) }
            #endif
            if let result { Self.resume(next, result) }
        }
        @discardableResult func complete(_ result: Resolution) -> Bool {
            lock.lock()
            guard completed == nil else { lock.unlock(); return false }
            completed = result; let waiter = continuation; continuation = nil
            lock.unlock()
            #if DEBUG
            let stage: WorkerSettlementDiagnostics.Stage
            switch result {
            case .value: stage = .resolvedValue
            case .cancelled: stage = .resolvedCancelled
            case .failure(.timedOut): stage = .resolvedTimeout
            case .failure: stage = .resolvedFailure
            }
            diagnostics?.record(stage, operationID: operationID)
            if waiter != nil { diagnostics?.record(.continuationResumed, operationID: operationID) }
            #endif
            if let waiter { Self.resume(waiter, result) }; return true
        }
        private static func resume(_ waiter: CheckedContinuation<Payload, any Error>, _ result: Resolution) {
            switch result {
            case .value(let value): waiter.resume(returning: value)
            case .failure(let error): waiter.resume(throwing: error)
            case .cancelled: waiter.resume(throwing: CancellationError())
            }
        }
    }
    private let queue = DispatchQueue(label: "relay.owned-calendar-read")
    #if DEBUG
    private var settlementDiagnostics: WorkerSettlementDiagnostics?
    /// Nil by default. This changes no SDK operation, failure, timer or source fence.
    func enableSettlementDiagnosticsForTesting() -> WorkerSettlementDiagnostics {
        let trace = WorkerSettlementDiagnostics(); settlementDiagnostics = trace; return trace
    }
    #endif
    private let database = CalendarReadEpoch()
    private var observer: NSObjectProtocol?
    private var active: UUID?
    private var drains: [CheckedContinuation<Void, Never>] = []
    private var readOverride: (@Sendable (CalendarReadQuery, @Sendable () -> Bool) throws -> CalendarReadSnapshot)?
    private var catalogOverride: (@Sendable () throws -> Catalog)?
    var activeCount: Int { active == nil ? 0 : 1 }
    var databaseGeneration: UUID { database.value }
    #if DEBUG
    /// Payload-free observation of actual synchronous generation fences only.
    /// No proof, body, permission, delay or SDK query can be supplied here.
    private(set) var generationFenceChecks = 0
    #endif
    fileprivate func validateGeneration(_ expected: UUID) throws {
        #if DEBUG
        generationFenceChecks &+= 1
        #endif
        guard database.value == expected else { throw CalendarReadFailure.unavailable }
    }
    private init() {
        let epoch = database
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: nil) { _ in epoch.invalidate() }
    }
    #if DEBUG
    /// Internal owned-protocol seam, never an app preference/backend mode or
    /// evidence that EventKit was queried. Production shared has no override.
    init(readForTesting: @escaping @Sendable (CalendarReadQuery, @Sendable () -> Bool) throws -> CalendarReadSnapshot,
         catalogForTesting: @escaping @Sendable () throws -> Catalog = { Catalog(calendars: [], limited: false) }) {
        readOverride = readForTesting; catalogOverride = catalogForTesting
    }
    func invalidateDatabaseForTesting() { database.invalidate() }
    #endif
    func read(call: ToolCall, scope: CalendarReadExecutionScope, timeoutMilliseconds: Int = 5_000) async throws -> ProducedResult {
        try scope.validateCurrent(call: call)
        let generation = database.value
        do {
            let payload = try await perform(.events(scope.query), seed: scope.fence.seed, generation: generation, timeoutMilliseconds: timeoutMilliseconds)
            try scope.validateCurrent(call: call)
            guard database.value == generation, case .events(let completed) = payload else { throw CalendarReadFailure.unavailable }
            var result = completed.snapshot.toolResult()
            let receipt = try CalendarReadReceipt(scope: scope, snapshot: completed.snapshot, result: result,
                contentDigest: completed.digest, generation: generation, worker: self)
            result.calendarReadReceipt = receipt
            return ProducedResult(result: result, receipt: receipt)
        } catch {
            try scope.validateCurrent(call: call)
            if error is CancellationError { throw CancellationError() }
            throw (error as? CalendarReadFailure) ?? .unavailable
        }
    }
    func validate(_ query: CalendarReadQuery, expectedDigest: Data, generation: UUID, seed: CalendarReadSeed) async throws {
        guard database.value == generation else { throw CalendarReadFailure.unavailable }
        let value = try await perform(.events(query), seed: seed, generation: generation, timeoutMilliseconds: 5_000)
        guard database.value == generation, case .events(let completed) = value,
              completed.digest == expectedDigest else { throw CalendarReadFailure.unavailable }
    }
    func listCalendars(seed: CalendarReadSeed) async throws -> Catalog {
        let generation = database.value
        let value = try await perform(.catalog, seed: seed, generation: generation, timeoutMilliseconds: 5_000)
        guard database.value == generation, case .catalog(let result) = value else { throw CalendarReadFailure.unavailable }
        return result
    }
    func readForUI(query: CalendarReadQuery, seed: CalendarReadSeed) async throws -> CalendarReadSnapshot {
        let generation = database.value
        let value = try await perform(.events(query), seed: seed, generation: generation, timeoutMilliseconds: 5_000)
        guard database.value == generation, case .events(let result) = value else { throw CalendarReadFailure.unavailable }
        return result.snapshot
    }
    func drain() async { if active != nil { await withCheckedContinuation { drains.append($0) } } }
    private func finished(_ id: UUID) {
        guard active == id else { return }
        active = nil; let waiting = drains; drains.removeAll(); for continuation in waiting { continuation.resume() }
    }
    private func perform(_ operation: Operation, seed: CalendarReadSeed, generation: UUID,
                         timeoutMilliseconds: Int) async throws -> Payload {
        try Task.checkCancellation()
        guard active == nil else { throw CalendarReadFailure.busy }
        guard seed.revocation.value == seed.epoch, database.value == generation else { throw CalendarReadFailure.unavailable }
        #if DEBUG
        let id = UUID(), database = database, queue = queue
        let diagnostics = settlementDiagnostics
        let delivery = Delivery(diagnostics: diagnostics, operationID: id)
        #else
        let id = UUID(), delivery = Delivery(), database = database, queue = queue
        #endif
        let read = readOverride, catalog = catalogOverride
        let effectiveTimeoutMilliseconds: Int
        #if DEBUG
        if settlementDiagnostics != nil, timeoutMilliseconds == 250 {
            effectiveTimeoutMilliseconds = 80
        } else {
            effectiveTimeoutMilliseconds = timeoutMilliseconds
        }
        #else
        effectiveTimeoutMilliseconds = timeoutMilliseconds
        #endif
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(min(5_000, max(1, effectiveTimeoutMilliseconds))))
        active = id
        #if DEBUG
        diagnostics?.record(.reserved, operationID: id)
        #endif
        let timer = Task.detached(priority: .userInitiated) {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            #if DEBUG
            diagnostics?.record(.timeoutFired, operationID: id)
            #endif
            delivery.complete(.failure(.timedOut))
        }
        defer {
            timer.cancel()
            #if DEBUG
            diagnostics?.record(.waiterReturned, operationID: id)
            #endif
        }
        let physical: @Sendable () -> Void = { [weak self, queue] in
            queue.async {
                #if DEBUG
                diagnostics?.record(.physicalStarted, operationID: id)
                #endif
                let current: @Sendable () -> Bool = {
                    delivery.pending && seed.revocation.value == seed.epoch
                        && database.value == generation && ContinuousClock.now < deadline
                }
                let resolution: Resolution
                do {
                    guard current() else { throw CalendarReadFailure.unavailable }
                    let payload: Payload = try autoreleasepool {
                        switch operation {
                        case .events(let query):
                            let snapshot = try read?(query, current) ?? CalendarReadKernel.capture(query, current: current)
                            guard snapshot.query == query else { throw CalendarReadFailure.unavailable }
                            try snapshot.validateProjection()
                            // Hash the bounded raw projection on its worker, not on the UI actor.
                            return .events(CompletedRead(snapshot: snapshot, digest: snapshot.digest))
                        case .catalog:
                            let listed = try catalog?() ?? CalendarReadKernel.catalog(current: current)
                            guard listed.calendars.count <= CalendarReadCodec.maximumCatalogEntries,
                                  listed.calendars.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= CalendarSource.maximumCalendarIdentifierBytes
                                      && $0.title.utf8.count <= CalendarReadCodec.maximumTextBytes && $0.title.count <= 512 }) else { throw CalendarReadFailure.unavailable }
                            return .catalog(listed)
                        }
                    }
                    guard current() else { throw CalendarReadFailure.unavailable }
                    resolution = .value(payload)
                } catch { resolution = .failure((error as? CalendarReadFailure) ?? .unavailable) }
                // SDK scope has physically ended BEFORE releasing the slot
                // and waking a caller that may immediately revalidate.
                #if DEBUG
                diagnostics?.record(.physicalEnded, operationID: id)
                #endif
                if !delivery.completeFromKernel(resolution) {
                    Task { @MainActor in
                        #if DEBUG
                        diagnostics?.record(.actorSettlementEntered, operationID: id)
                        #endif
                        self?.finished(id)
                        #if DEBUG
                        diagnostics?.record(.actorSettlementExited, operationID: id)
                        #endif
                    }
                }
            }
        }
        #if DEBUG
        diagnostics?.record(.physicalQueued, operationID: id)
        #endif
        physical()
        let result = try await withTaskCancellationHandler {
            defer { if delivery.isKernelDone { finished(id) } }
            return try await Self.awaitDelivery(delivery)
        } onCancel: {
            #if DEBUG
            diagnostics?.record(.cancelReceived, operationID: id)
            #endif
            delivery.complete(.cancelled)
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw CalendarReadFailure.timedOut }
        guard seed.revocation.value == seed.epoch, database.value == generation else { throw CalendarReadFailure.unavailable }
        return result
    }
    private static func awaitDelivery(_ delivery: Delivery) async throws -> Payload {
        try await withCheckedThrowingContinuation { continuation in
            delivery.install(continuation)
        }
    }
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// All EventKit objects are local to one synchronous queue job. No task,
/// callback delivery, receipt, model or actor field retains an SDK object.
private nonisolated enum CalendarReadKernel {
    static func catalog(current: @Sendable () -> Bool) throws -> CalendarEventReadWorker.Catalog {
        guard current(), EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarReadFailure.accessUnavailable }
        let store = EKEventStore()
        var result: [CalendarSource.CalendarInfo] = [], limited = false, visited = 0
        for calendar in store.calendars(for: .event) {
            guard current() else { throw CalendarReadFailure.unavailable }
            guard visited < CalendarReadCodec.maximumCatalogEntries else { limited = true; break }
            visited += 1
            guard let id = try? CalendarReadCodec.boundedID(calendar.calendarIdentifier, maximum: CalendarSource.maximumCalendarIdentifierBytes) else { limited = true; continue }
            let title = CalendarReadCodec.text(calendar.title)
            limited = limited || title.limited
            let accountTitle = CalendarReadCodec.text(calendar.source?.title ?? "")
            limited = limited || accountTitle.limited
            result.append(.init(id: String(decoding: id, as: UTF8.self), title: title.text,
                                allowsContentModifications: calendar.allowsContentModifications, accountTitle: accountTitle.text))
        }
        guard current(), EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarReadFailure.accessUnavailable }
        return .init(calendars: result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }, limited: limited)
    }
    static func capture(_ query: CalendarReadQuery, current: @escaping @Sendable () -> Bool) throws -> CalendarReadSnapshot {
        guard current(), EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarReadFailure.accessUnavailable }
        guard Data(TimeZone.current.identifier.utf8) == query.timeZoneID else { throw CalendarReadFailure.unavailable }
        let store = EKEventStore(), requested = Set(query.identifiers)
        var calendars: [EKCalendar] = []
        for calendar in store.calendars(for: .event) {
            guard current() else { throw CalendarReadFailure.unavailable }
            guard let id = try? CalendarReadCodec.boundedID(calendar.calendarIdentifier, maximum: CalendarSource.maximumCalendarIdentifierBytes) else { continue }
            if requested.contains(id) { calendars.append(calendar) }
            guard calendars.count <= requested.count else { throw CalendarReadFailure.unavailable }
        }
        guard current(), !calendars.isEmpty, calendars.count == requested.count,
              Set(calendars.map { Data($0.calendarIdentifier.utf8) }) == requested else { throw CalendarReadFailure.unavailable }
        let predicate = store.predicateForEvents(withStart: query.start, end: query.end, calendars: calendars)
        guard current() else { throw CalendarReadFailure.unavailable }
        var events: [CalendarReadEvent] = [], seen: [Data: Data] = [:], visited = 0, bytes = 0
        var limited = false, byteLimited = false, invalid = false
        store.enumerateEvents(matching: predicate) { event, stop in
            guard current() else { invalid = true; stop.pointee = true; return }
            guard visited < CalendarReadCodec.maximumEvents else { limited = true; stop.pointee = true; return }
            visited += 1
            do {
                guard let calendar = event.calendar else { throw CalendarReadFailure.unavailable }
                let calendarID = try CalendarReadCodec.boundedID(calendar.calendarIdentifier, maximum: CalendarSource.maximumCalendarIdentifierBytes)
                // Never copy event-private fields from an unselected calendar.
                guard requested.contains(calendarID), current(), let start = event.startDate, let end = event.endDate,
                      [start, end].allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }), end >= start else { throw CalendarReadFailure.unavailable }
                let itemID = try CalendarReadCodec.boundedID(event.calendarItemIdentifier, maximum: CalendarReadCodec.maximumEventIdentifierBytes)
                let rawEventID: String? = event.eventIdentifier
                let eventID = try rawEventID.map { try CalendarReadCodec.boundedID($0, maximum: CalendarReadCodec.maximumEventIdentifierBytes) }
                guard current() else { throw CalendarReadFailure.unavailable }
                let title = CalendarReadCodec.text(event.title ?? "Untitled event"), calendarTitle = CalendarReadCodec.text(calendar.title)
                let zone = try event.timeZone.map { try CalendarReadCodec.boundedID($0.identifier, maximum: 1_024) }
                let status: CalendarReadEvent.Status
                switch event.status.rawValue { case 0: status = .unspecified; case 1: status = .confirmed; case 2: status = .tentative; case 3: status = .canceled; default: status = .unknown }
                let value = CalendarReadEvent(calendarID: calendarID, itemID: itemID, eventID: eventID,
                    occurrence: event.occurrenceDate, title: title.text, calendarName: calendarTitle.text,
                    start: start, end: end, allDay: event.isAllDay, timeZoneID: zone.map { String(decoding: $0, as: UTF8.self) },
                    status: status, fieldLimited: title.limited || calendarTitle.limited)
                if let prior = seen[value.occurrenceKey] {
                    guard prior == value.encoded else { throw CalendarReadFailure.unavailable }; return
                }
                guard bytes + value.encoded.count <= CalendarReadCodec.maximumSnapshotBytes else { byteLimited = true; stop.pointee = true; return }
                bytes += value.encoded.count; seen[value.occurrenceKey] = value.encoded; events.append(value)
            } catch { invalid = true; stop.pointee = true }
        }
        guard current(), !invalid, EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              Data(TimeZone.current.identifier.utf8) == query.timeZoneID else { throw CalendarReadFailure.unavailable }
        return .init(query: query, events: events, producerLimited: limited, byteLimited: byteLimited, capturedAt: Date())
    }
}
