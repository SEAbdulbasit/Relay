import Darwin
import Foundation

/// The helper owns a single, bounded system-wide sleep hold.
nonisolated struct ManagedPreparationAwakeLease {
    enum RecoveryMarker { case absent, owned, invalid }

    struct System {
        let marker: () -> RecoveryMarker
        let createMarker: () -> Bool
        let removeMarker: () -> Bool
        let sleepDisabled: () -> Bool?
        let setSleepDisabled: (Bool) -> Bool
        let onExternalPower: () -> Bool
    }

    private struct Active {
        let owner: ObjectIdentifier
        let token: UUID
        let ceiling: TimeInterval
        var expires: TimeInterval
    }

    private let system: System
    private var active: Active?
    private static let heartbeatLimit: TimeInterval = 45
    private static let absoluteLimit: TimeInterval = 20 * 60

    init(system: System) { self.system = system }

    mutating func begin(owner: ObjectIdentifier, token: UUID, now: TimeInterval) -> Bool {
        guard active == nil, system.onExternalPower(), system.marker() == .absent,
              system.sleepDisabled() == false, system.createMarker() else { return false }
        guard system.setSleepDisabled(true), system.sleepDisabled() == true else {
            _ = restoreSleep()
            return false
        }
        active = Active(owner: owner, token: token, ceiling: now + Self.absoluteLimit,
                        expires: now + Self.heartbeatLimit)
        return true
    }

    mutating func heartbeat(owner: ObjectIdentifier, token: UUID, now: TimeInterval) -> Bool {
        guard check(now: now), let active, active.owner == owner, active.token == token else { return false }
        self.active?.expires = min(active.ceiling, now + Self.heartbeatLimit)
        return true
    }

    mutating func end(owner: ObjectIdentifier, token: UUID? = nil) -> Bool {
        guard let active else { return restoreSleep() }
        guard active.owner == owner, token == nil || token == active.token else { return false }
        self.active = nil
        return restoreSleep()
    }

    @discardableResult
    mutating func check(now: TimeInterval) -> Bool {
        if let active, now < active.expires, now < active.ceiling, system.onExternalPower() { return true }
        active = nil
        _ = restoreSleep()
        return false
    }

    private func restoreSleep() -> Bool {
        switch system.marker() {
        case .absent: return true
        case .invalid: return false
        case .owned:
            if system.sleepDisabled() != false {
                guard system.setSleepDisabled(false), system.sleepDisabled() == false else { return false }
            }
            return system.removeMarker()
        }
    }
}

nonisolated enum ManagedPreparationSleepSystem {
    private static let recoveryPath = "/private/var/db/dev.relay.assistant.preparation-wake-recovery"

    static var system: ManagedPreparationAwakeLease.System {
        .init(marker: marker, createMarker: createMarker, removeMarker: removeMarker,
              sleepDisabled: sleepDisabled, setSleepDisabled: setSleepDisabled,
              onExternalPower: PreparationWakeSystem.isOnExternalPower)
    }

    static var recoveryMarkerIsAbsent: Bool { marker() == .absent }

    private static func marker() -> ManagedPreparationAwakeLease.RecoveryMarker {
        var info = stat()
        if lstat(recoveryPath, &info) != 0 { return errno == ENOENT ? .absent : .invalid }
        return isOwned(info) ? .owned : .invalid
    }

    private static func isOwned(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o777 == 0o600
            && info.st_uid == 0 && info.st_nlink == 1 && info.st_size == 0
    }

    private static func lockMarker() -> FileHandle? {
        let fd = open(recoveryPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, isOwned(info), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func createMarker() -> Bool {
        let fd = open(recoveryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return false }
        defer { _ = close(fd) }
        let directory = open("/private/var/db", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return false }
        defer { _ = close(directory) }
        return fsync(fd) == 0 && fsync(directory) == 0
    }

    private static func removeMarker() -> Bool {
        guard let lock = lockMarker() else { return false }
        return withExtendedLifetime(lock) { unlink(recoveryPath) == 0 }
    }

    static func parseSleepDisabled(_ output: String) -> Bool? {
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> Substring? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "SleepDisabled" else { return nil }
            return fields[1]
        }
        guard values.count == 1 else { return nil }
        switch values[0] {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }

    private static func sleepDisabled() -> Bool? {
        guard let output = pmset(arguments: ["-g"]) else { return nil }
        return parseSleepDisabled(output)
    }

    private static func setSleepDisabled(_ value: Bool) -> Bool {
        guard let lock = lockMarker() else { return false }
        // The subprocess inherits the lock on stdin. A replacement daemon
        // cannot remove the recovery marker while an orphaned write finishes.
        return pmset(arguments: ["-a", "disablesleep", value ? "1" : "0"], input: lock) != nil
    }

    private static func pmset(arguments: [String], input: FileHandle = .nullDevice) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
