import Foundation
import Testing
@testable import Relay

struct ManagedPreparationWakeTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let owner = ManagedPreparationWakeConfiguration.owner(for: 501)

    @Test func replacesOnlyOwnedWakeAndLeavesExistingNearTermWakeAlone() {
        let first = now.addingTimeInterval(300)
        let second = now.addingTimeInterval(600)
        var canceled: [Date] = []
        var scheduled: [Date] = []
        var rows = [first]
        let events = ManagedPreparationWakeEvents(
            read: { requestedOwner in
                #expect(requestedOwner == owner)
                return rows
            },
            cancel: { date, requestedOwner in
                #expect(requestedOwner == owner)
                canceled.append(date)
                rows.removeAll { $0 == date }
                return true
            },
            schedule: { date, requestedOwner in
                #expect(requestedOwner == owner)
                scheduled.append(date)
                rows.append(date)
                return true
            }
        )

        #expect(events.reconcile(owner: owner, epoch: first.timeIntervalSince1970, now: first.addingTimeInterval(-5)))
        #expect(canceled.isEmpty && scheduled.isEmpty)
        #expect(events.reconcile(owner: owner, epoch: second.timeIntervalSince1970, now: now))
        #expect(canceled == [first] && scheduled == [second])
        #expect(events.reconcile(owner: owner, epoch: 0, now: now))
        #expect(canceled == [first, second] && scheduled == [second])
    }

    @Test func failedCancellationOrInvalidRequestCannotCreateAnotherWake() {
        var scheduled: [Date] = []
        let events = ManagedPreparationWakeEvents(
            read: { _ in [now.addingTimeInterval(300)] },
            cancel: { _, _ in false },
            schedule: { date, _ in scheduled.append(date); return true }
        )
        #expect(!events.reconcile(owner: owner, epoch: now.timeIntervalSince1970 + 600, now: now))
        #expect(!events.reconcile(owner: owner, epoch: 0, now: now))
        #expect(!events.reconcile(owner: owner, epoch: .nan, now: now))
        #expect(!events.reconcile(owner: owner, epoch: now.timeIntervalSince1970 + 7 * 24 * 3600, now: now))
        #expect(!events.reconcile(owner: "unrelated.app", epoch: 0, now: now))
        #expect(scheduled.isEmpty)
    }

    @Test func managedOwnerNamesCannotAliasManualOrUnrelatedEvents() {
        #expect(ManagedPreparationWakeConfiguration.owns(owner))
        #expect(!ManagedPreparationWakeConfiguration.owns("dev.relay.assistant.preparation.501"))
        #expect(!ManagedPreparationWakeConfiguration.owns(ManagedPreparationWakeConfiguration.ownerPrefix + "0501"))
        #expect(!ManagedPreparationWakeConfiguration.owns(ManagedPreparationWakeConfiguration.ownerPrefix + "0"))
    }
}
