#if DEBUG
import Foundation

/// Opt-in DEBUG-only closed timing data. It observes actual boundaries, never
/// source/query/body/provider data, and cannot change a verdict or operation.
nonisolated final class WorkerSettlementDiagnostics: @unchecked Sendable {
    enum Stage: String, Sendable {
        case reserved, physicalQueued, physicalStarted, physicalEnded
        case timeoutFired, cancelReceived, waiterInstalled, continuationResumed, waiterReturned
        case resolvedValue, resolvedFailure, resolvedTimeout, resolvedCancelled
        case actorSettlementEntered, actorSettlementExited
        case testWaitStarted, testCancellationRequested
    }
    struct Event: Sendable {
        let operationID: UUID
        let stage: Stage
        let instant: ContinuousClock.Instant
        let mainThread: Bool
    }
    private let lock = NSLock()
    private var events: [Event] = []
    func record(_ stage: Stage, operationID: UUID) {
        let event = Event(operationID: operationID, stage: stage, instant: .now, mainThread: Thread.isMainThread)
        lock.withLock {
            if events.count == 48 { events.removeFirst() }
            events.append(event)
        }
    }
    var snapshot: [Event] { lock.withLock { events } }
    var technicalSummary: String {
        let values = snapshot.sorted { $0.instant < $1.instant }
        guard let start = values.first?.instant else { return "worker-trace-empty" }
        return values.map { value in
            "\(value.stage.rawValue):\(Self.milliseconds(start.duration(to: value.instant)))ms:main=\(value.mainThread)"
        }.joined(separator: ";")
    }
    static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        let (whole, overflow) = parts.seconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return Int64.max }
        let (total, totalOverflow) = whole.addingReportingOverflow(parts.attoseconds / 1_000_000_000_000_000)
        return totalOverflow ? Int64.max : total
    }
}
#endif
