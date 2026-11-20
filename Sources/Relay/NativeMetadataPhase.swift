import Foundation

/// A synchronous metadata scan's lifetime, not a source or private-read grant.
/// Only the actual observer binding selects the production query validators.
@MainActor final class NativeMetadataPhase {
    enum Failure: Error, Equatable { case expired }
    private var active = true
    private let deadline: ContinuousClock.Instant
    private let query: @MainActor () throws -> Void
    private let readAudit: NativeReadAudit?
    private let now: @MainActor () -> ContinuousClock.Instant

    private init(deadline: ContinuousClock.Instant, query: @escaping @MainActor () throws -> Void,
                 readAudit: NativeReadAudit?, now: @escaping @MainActor () -> ContinuousClock.Instant) {
        self.deadline = deadline; self.query = query; self.readAudit = readAudit; self.now = now
    }

    func check() throws {
        guard active else { throw Failure.expired }
        try Task.checkCancellation()
        try NativeStandardControlSurvey.requireMetadataDeadline(deadline, now: now(), readAudit: readAudit)
        try query()
        try Task.checkCancellation()
        try NativeStandardControlSurvey.requireMetadataDeadline(deadline, now: now(), readAudit: readAudit)
    }

    /// Charge the original deadline AFTER the real process/application lease
    /// has completed all of its lexical exits, including throwing exits. An
    /// existing strong/cancellation/body refusal stays primary; the deadline
    /// still records an overrun. An otherwise-successful late result refuses.
    static func finishLease<Value>(_ result: Result<Value, any Error>,
                                   deadline: ContinuousClock.Instant,
                                   now: ContinuousClock.Instant = .now,
                                   readAudit: NativeReadAudit? = nil) throws -> Value {
        let timing: Result<Void, any Error> = Result {
            try NativeStandardControlSurvey.requireMetadataDeadline(deadline, now: now, readAudit: readAudit)
        }
        switch result {
        case .failure(let original): throw original
        case .success(let value):
            try Task.checkCancellation()
            try timing.get()
            return value
        }
    }

    /// No async body: an escaping reference is retired before this returns or
    /// throws. The exit's strong failure overrides a stale source's body error.
    /// This state machine alone cannot manufacture an observer source binding.
    static func run<Value>(deadline: ContinuousClock.Instant,
                           boundary: @MainActor () throws -> Void,
                           query: @escaping @MainActor () throws -> Void,
                           readAudit: NativeReadAudit? = nil,
                           now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
                           body: @MainActor (NativeMetadataPhase) throws -> Value) throws -> Value {
        let phase = NativeMetadataPhase(deadline: deadline, query: query, readAudit: readAudit, now: now)
        defer { phase.active = false }
        func checkBoundary() throws {
            try boundary()
            try Task.checkCancellation()
            // Entry and exit source checks are charged to the same 750 ms
            // deadline; no successful scan can escape after its budget.
            try NativeStandardControlSurvey.requireMetadataDeadline(deadline, now: now(), readAudit: readAudit)
        }
        var entered = false
        let result = Result {
            try checkBoundary(); entered = true
            return try body(phase)
        }
        if case .failure(let error) = result {
            NativeReadAudit.recordPhaseFailure(readAudit, origin: entered ? .phaseBodyRefusal : .phaseEntryRefusal, error: error)
        }
        do { try checkBoundary() }
        catch {
            NativeReadAudit.recordPhaseFailure(readAudit, origin: .phaseExitRefusal, error: error)
            throw error
        }
        return try result.get()
    }
}
