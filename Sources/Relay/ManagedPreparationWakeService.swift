import Darwin
import Foundation
import IOKit.pwr_mgt
import Security

nonisolated enum ManagedPreparationWakeConfiguration {
    static let service = "dev.relay.assistant.preparation-wake"
    static let argument = "--managed-preparation-wake"
    static let ownerPrefix = "dev.relay.assistant.managed-preparation."
    static let maximumLeadTime: TimeInterval = 36 * 60 * 60

    static func owner(for uid: uid_t) -> String { ownerPrefix + String(uid) }

    static func owns(_ owner: String) -> Bool {
        guard owner.hasPrefix(ownerPrefix), let uid = uid_t(owner.dropFirst(ownerPrefix.count)),
              uid != 0 else { return false }
        return owner == self.owner(for: uid)
    }
}

@objc nonisolated protocol ManagedPreparationWakeProtocol {
    func reconcileWake(epoch: Double, reply: @escaping (Bool) -> Void)
    func updateAwakeLease(operation: Int, token: String, reply: @escaping (Bool) -> Void)
}

nonisolated enum ManagedPreparationAwakeOperation: Int {
    case begin, heartbeat, end
}

/// Exact, single-owner IOKit wake operations. Zero is the sole cancellation sentinel.
nonisolated struct ManagedPreparationWakeEvents {
    let read: (String) -> [Date]?
    let cancel: (Date, String) -> Bool
    let schedule: (Date, String) -> Bool

    func reconcile(owner: String, epoch: Double, now: Date) -> Bool {
        guard ManagedPreparationWakeConfiguration.owns(owner), epoch.isFinite else { return false }
        let requested = epoch == 0 ? nil : Date(timeIntervalSince1970: epoch)
        if let requested {
            guard (0...ManagedPreparationWakeConfiguration.maximumLeadTime).contains(requested.timeIntervalSince(now)),
                  epoch.rounded() == epoch else { return false }
        }
        guard let dates = read(owner) else { return false }
        if dates == (requested.map { [$0] } ?? []) { return true }
        if let requested, requested.timeIntervalSince(now) < 60 { return false }
        var cleared = true
        for date in Set(dates) {
            if !cancel(date, owner) { cleared = false }
        }
        guard cleared else { return false }
        guard let requested else { return true }
        return schedule(requested, owner)
    }

    static var system: Self { Self(
        read: { owner in
            guard let rows = systemRows() else { return nil }
            return dates(in: rows, owner: owner)
        },
        cancel: { date, owner in
            IOPMCancelScheduledPowerEvent(date as NSDate, owner as CFString, kIOPMAutoWake as CFString) == kIOReturnSuccess
        },
        schedule: { date, owner in
            IOPMSchedulePowerEvent(date as NSDate, owner as CFString, kIOPMAutoWake as CFString) == kIOReturnSuccess
        }
    ) }

    static func systemRows() -> [[String: Any]]? {
        guard let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() else { return [] }
        return events as? [[String: Any]]
    }

    static func dates(in rows: [[String: Any]], owner: String) -> [Date]? {
        var dates: [Date] = []
        for row in rows where row[kIOPMPowerEventAppNameKey] as? String == owner
            && row[kIOPMPowerEventTypeKey] as? String == kIOPMAutoWake {
            guard let date = row[kIOPMPowerEventTimeKey] as? Date, date.timeIntervalSince1970.isFinite else { return nil }
            dates.append(date)
        }
        return dates
    }
}

nonisolated final class ManagedPreparationWakeService: NSObject, NSXPCListenerDelegate, ManagedPreparationWakeProtocol, @unchecked Sendable {
    private let requirement: String
    private let queue = DispatchQueue(label: "dev.relay.assistant.managed-preparation")
    // Access only on queue. Connections for separate users have separate event owners.
    private var connections: Set<ObjectIdentifier> = []
    private var ownerConnections: [uid_t: ObjectIdentifier] = [:]
    private var awakeLease = ManagedPreparationAwakeLease(system: ManagedPreparationSleepSystem.system)

    private init(requirement: String) { self.requirement = requirement }

    static func run() {
        guard geteuid() == 0, let requirement = signedRequirement() else { return }
        let service = Self(requirement: requirement)
        service.removeStaleEvents()
        let watchdog = DispatchSource.makeTimerSource(queue: service.queue)
        watchdog.schedule(deadline: .now(), repeating: .seconds(3), leeway: .milliseconds(100))
        watchdog.setEventHandler { service.awakeLease.check(now: Self.monotonicTime()) }
        watchdog.resume()
        let listener = NSXPCListener(machServiceName: ManagedPreparationWakeConfiguration.service)
        listener.delegate = service
        listener.resume()
        withExtendedLifetime((service, listener, watchdog)) { dispatchMain() }
    }

    static func signedRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let metadata = info as? [String: Any],
              metadata[kSecCodeInfoIdentifier as String] as? String == "dev.relay.assistant",
              let team = metadata[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    private func removeStaleEvents() {
        guard let rows = ManagedPreparationWakeEvents.systemRows() else { return }
        let owners = Set(rows.compactMap { $0[kIOPMPowerEventAppNameKey] as? String })
        for owner in owners where ManagedPreparationWakeConfiguration.owns(owner) {
            _ = ManagedPreparationWakeEvents.system.reconcile(owner: owner, epoch: 0, now: Date())
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard uid != 0, uid != uid_t.max else { return false }
        let identity = ObjectIdentifier(connection)
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ManagedPreparationWakeProtocol.self)
        connection.exportedObject = self
        queue.sync { _ = connections.insert(identity) }
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            queue.async {
                self.connections.remove(identity)
                _ = self.awakeLease.end(owner: identity)
                guard self.ownerConnections[uid] == identity else { return }
                self.ownerConnections[uid] = nil
                self.cancelDisconnectedWake(for: uid, retries: 3)
            }
        }
        connection.resume()
        return true
    }

    private func cancelDisconnectedWake(for uid: uid_t, retries: Int) {
        guard ownerConnections[uid] == nil else { return }
        let owner = ManagedPreparationWakeConfiguration.owner(for: uid)
        if !ManagedPreparationWakeEvents.system.reconcile(owner: owner, epoch: 0, now: Date()), retries > 0 {
            queue.asyncAfter(deadline: .now() + 2) { self.cancelDisconnectedWake(for: uid, retries: retries - 1) }
        }
    }

    func reconcileWake(epoch: Double, reply: @escaping (Bool) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(false); return }
        let uid = connection.effectiveUserIdentifier
        let identity = ObjectIdentifier(connection)
        // XPC calls are serialized with disconnect cleanup. Reply on this callback
        // thread so the non-Sendable Objective-C reply never crosses a queue.
        let result = queue.sync {
            guard connections.contains(identity) else { return false }
            if let existing = ownerConnections[uid], existing != identity { return false }
            ownerConnections[uid] = identity
            return ManagedPreparationWakeEvents.system.reconcile(
                owner: ManagedPreparationWakeConfiguration.owner(for: uid), epoch: epoch, now: Date()
            )
        }
        reply(result)
    }

    func updateAwakeLease(operation: Int, token: String, reply: @escaping (Bool) -> Void) {
        guard let operation = ManagedPreparationAwakeOperation(rawValue: operation),
              let token = UUID(uuidString: token), let connection = NSXPCConnection.current() else {
            reply(false)
            return
        }
        let identity = ObjectIdentifier(connection)
        let uid = connection.effectiveUserIdentifier
        let result = queue.sync {
            guard connections.contains(identity) else { return false }
            if let existing = ownerConnections[uid], existing != identity { return false }
            ownerConnections[uid] = identity
            let now = Self.monotonicTime()
            switch operation {
            case .begin: return awakeLease.begin(owner: identity, token: token, now: now)
            case .heartbeat: return awakeLease.heartbeat(owner: identity, token: token, now: now)
            case .end: return awakeLease.end(owner: identity, token: token)
            }
        }
        reply(result)
    }

    private static func monotonicTime() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

}
