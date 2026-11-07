import AppKit
import Foundation

/// Independent interruptions must all end before interactive work resumes.
/// A display waking never implies that its user session became active.
nonisolated struct WorkspaceSessionState: Sendable {
    enum Interruption: Hashable, Sendable { case inactiveSession, systemSleep, screensSleep }
    private(set) var interruptions = Set<Interruption>()
    var isActive: Bool { interruptions.isEmpty }

    static let notifications: [Notification.Name] = [
        NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
        NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
        NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification
    ]

    mutating func suspend(_ reason: Interruption) { interruptions.insert(reason) }
    mutating func resume(_ reason: Interruption) { interruptions.remove(reason) }

    @discardableResult
    mutating func consume(_ name: Notification.Name) -> Bool {
        switch name {
        case NSWorkspace.willSleepNotification: suspend(.systemSleep)
        case NSWorkspace.didWakeNotification: resume(.systemSleep)
        case NSWorkspace.screensDidSleepNotification: suspend(.screensSleep)
        case NSWorkspace.screensDidWakeNotification: resume(.screensSleep)
        case NSWorkspace.sessionDidResignActiveNotification: suspend(.inactiveSession)
        case NSWorkspace.sessionDidBecomeActiveNotification: resume(.inactiveSession)
        default: return false
        }
        return true
    }
}
