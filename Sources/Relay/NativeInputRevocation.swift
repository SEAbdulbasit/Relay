import Foundation

/// The lock protects only two booleans. No AX query, callback, allocation or IO runs under it.
/// Admission linearizes here: revocation wins before admission => no write; admission wins
/// first => in-flight work may still write/act and cancellation must remain uncertain.
nonisolated final class NativeInputRevocation: @unchecked Sendable {
    enum Decision: Sendable, Equatable { case admitted, revoked, expired, consumed }
    nonisolated final class Ticket: @unchecked Sendable {
        fileprivate let source: NativeInputRevocation
        fileprivate var used = false // protected exclusively by source.lock
        fileprivate init(source: NativeInputRevocation) { self.source = source }
        func admit(now: ContinuousClock.Instant, notAfter: ContinuousClock.Instant) -> Decision {
            source.admit(self, now: now, notAfter: notAfter)
        }
    }
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func ticket() -> Ticket { Ticket(source: self) }
    func revoke() { lock.lock(); active = false; lock.unlock() }
    private func admit(_ ticket: Ticket, now: ContinuousClock.Instant, notAfter: ContinuousClock.Instant) -> Decision {
        lock.lock(); defer { lock.unlock() }
        guard active else { return .revoked }
        guard !ticket.used else { return .consumed }
        guard now < notAfter else { return .expired }
        ticket.used = true
        return .admitted
    }
}
