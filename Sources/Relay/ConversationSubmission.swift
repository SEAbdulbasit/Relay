import Foundation
import Observation

/// Local delivery state only; a saved message is not an executable capability.
@Observable @MainActor final class ConversationSubmission {
    enum Status: Equatable { case pending, saved, failed, stopped }
    let messageID: UUID
    let text: String
    private(set) var status: Status = .pending
    @ObservationIgnored private var observers: [@MainActor (Status) -> Void] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Status, Never>] = []
    var isPending: Bool { status == .pending }
    init(messageID: UUID, text: String) { self.messageID = messageID; self.text = text }
    func waitForAcknowledgment() async -> Status {
        guard isPending else { return status }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func onAcknowledgment(_ observer: @escaping @MainActor (Status) -> Void) {
        if isPending { observers.append(observer) } else { observer(status) }
    }
    func resolve(_ value: Status) {
        guard isPending, value != .pending else { return }
        status = value
        let callbacks = observers; observers.removeAll()
        for callback in callbacks { callback(value) }
        let current = waiters; waiters.removeAll()
        for waiter in current { waiter.resume(returning: value) }
    }
}
