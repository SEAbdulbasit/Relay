import Foundation
import Observation
import ServiceManagement
import Synchronization

@MainActor @Observable
final class ManagedPreparationWake {
    private(set) var status = "Managed wake is off."
    private(set) var isRequested: Bool
    private(set) var allowsClosedLidPreparation: Bool
    private(set) var awakeStatus: String?
    private(set) var isRemoving = false
    var canRemove: Bool {
        service.status != .notRegistered && service.status != .notFound
    }
    var requiresApproval: Bool { service.status == .requiresApproval }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    @ObservationIgnored private let service: SMAppService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var awakeTask: Task<Void, Never>?
    @ObservationIgnored private var desiredDate: Date?
    @ObservationIgnored private var revision = 0
    private static let requestKey = "preparation.managedWakeRequested"
    private static let closedLidKey = "preparation.closedLidRequested"

    init?(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let plist = ManagedPreparationWakeConfiguration.service + ".plist"
        let location = bundle.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + plist)
        guard bundle.bundleIdentifier == "dev.relay.assistant",
              FileManager.default.fileExists(atPath: location.path) else { return nil }
        service = .daemon(plistName: plist)
        self.defaults = defaults
        let requested = defaults.bool(forKey: Self.requestKey)
        isRequested = requested
        allowsClosedLidPreparation = requested && defaults.bool(forKey: Self.closedLidKey)
    }

    func enable() {
        guard !isRemoving else { return }
        guard ManagedPreparationWakeService.signedRequirement() != nil else {
            status = "Managed wake needs an Apple-signed Relay build."
            return
        }
        do {
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
            setRequested(true)
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            status = "macOS couldn’t register the wake helper. Check Login Items and try again."
        }
    }

    func setClosedLidPreparation(_ value: Bool) {
        allowsClosedLidPreparation = value && isRequested
        defaults.set(allowsClosedLidPreparation, forKey: Self.closedLidKey)
        if !allowsClosedLidPreparation { stopClosedLidPreparation() }
    }

    func startClosedLidPreparation() {
        guard isRequested, allowsClosedLidPreparation, !isRemoving, service.status == .enabled,
              awakeTask == nil else { return }
        let token = UUID()
        awakeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.awakeTask = nil }
            guard !Task.isCancelled else { return }
            let active = await self.contact(.begin, token: token)
            if !Task.isCancelled {
                self.awakeStatus = active
                    ? "The helper confirmed a temporary awake hold."
                    : "The helper couldn’t start a closed-lid hold. Keep the lid open."
            }
            if active {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { break }
                    guard await self.contact(.heartbeat, token: token) else { break }
                }
            }
            let restored = await self.contact(.end, token: token)
            if active || !restored {
                self.awakeStatus = restored
                    ? "The helper confirmed normal sleep was restored."
                    : "Sleep restoration is pending. The wake helper will retry."
            }
        }
    }

    func stopClosedLidPreparation() { awakeTask?.cancel() }

    func refresh(_ date: Date?) {
        desiredDate = date
        revision &+= 1
        guard isRequested, worker == nil, !isRemoving else { return }
        worker = Task { [weak self] in await self?.reconcileLatest() }
    }

    func remove() async {
        guard !isRemoving else { return }
        isRemoving = true
        setRequested(false)
        setClosedLidPreparation(false)
        defer { isRemoving = false }
        await worker?.value
        await awakeTask?.value
        if service.status == .enabled {
            guard await contact(.end, token: UUID()), await contact(epoch: 0) else {
                status = "Relay couldn’t confirm sleep restoration and wake cancellation. The helper is still installed."
                return
            }
        } else if let dates = ManagedPreparationWakeEvents.system.read(
            ManagedPreparationWakeConfiguration.owner(for: getuid())
        ), dates.isEmpty, ManagedPreparationSleepSystem.recoveryMarkerIsAbsent {
            // An unapproved or removed daemon can be unregistered only after
            // observing that its exact wake events are already absent.
        } else {
            status = "Approve the helper in Login Items to cancel its pending wake before removing it."
            return
        }
        do {
            if service.status != .notRegistered && service.status != .notFound { try await service.unregister() }
            disconnect()
            status = "Managed wake is off."
        } catch {
            status = "The wake was canceled. macOS couldn’t remove the helper."
        }
    }

    private func reconcileLatest() async {
        defer { worker = nil }
        while isRequested && !isRemoving {
            let request = revision
            let date = desiredDate
            switch service.status {
            case .requiresApproval:
                status = "Allow the wake helper in System Settings → Login Items."
            case .notRegistered, .notFound:
                status = "The wake helper is unavailable. Set it up again."
            case .enabled:
                let accepted = await contact(epoch: date?.timeIntervalSince1970 ?? 0)
                guard !isRemoving else { return }
                if request != revision { continue }
                if accepted, let date {
                    status = "macOS accepted Relay’s wake for \(date.formatted(date: .abbreviated, time: .shortened))."
                } else if accepted {
                    status = "Managed wake is ready. No wake is scheduled."
                } else {
                    status = "The wake helper couldn’t confirm the schedule. Relay will retry."
                }
            @unknown default:
                status = "macOS reported an unknown wake helper status."
            }
            if request == revision { return }
        }
    }

    private func contact(epoch: Double) async -> Bool {
        await contact { helper, reply in helper.reconcileWake(epoch: epoch, reply: reply) }
    }

    private func contact(_ operation: ManagedPreparationAwakeOperation, token: UUID) async -> Bool {
        await contact { helper, reply in
            helper.updateAwakeLease(operation: operation.rawValue, token: token.uuidString, reply: reply)
        }
    }

    private func contact(_ call: (ManagedPreparationWakeProtocol, @escaping (Bool) -> Void) -> Void) async -> Bool {
        if connection == nil {
            guard let requirement = ManagedPreparationWakeService.signedRequirement() else { return false }
            let next = NSXPCConnection(machServiceName: ManagedPreparationWakeConfiguration.service, options: .privileged)
            next.setCodeSigningRequirement(requirement)
            next.remoteObjectInterface = NSXPCInterface(with: ManagedPreparationWakeProtocol.self)
            next.resume()
            connection = next
        }
        guard let connection else { return false }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let reply = Mutex<CheckedContinuation<Bool?, Never>?>(continuation)
            let finish: @Sendable (Bool?) -> Void = { result in
                reply.withLock { pending in
                    let continuation = pending
                    pending = nil
                    continuation?.resume(returning: result)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { finish(nil) }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(nil) }
            guard let helper = proxy as? ManagedPreparationWakeProtocol else { finish(nil); return }
            call(helper) { finish($0) }
        }
        if result == nil, self.connection === connection { disconnect() }
        return result ?? false
    }

    private func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    private func setRequested(_ value: Bool) {
        isRequested = value
        defaults.set(value, forKey: Self.requestKey)
    }
}
