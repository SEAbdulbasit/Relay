import AppKit
import Foundation

/// Stable process identity. A PID alone can be reused after an app exits.
nonisolated struct DesktopApplicationIdentity: Equatable, Sendable {
    let processID: pid_t
    let launchedAt: Date
    let bundleID: String
    let bundleURL: URL
}

@MainActor
enum DesktopApplicationTarget {
    static func identity(of application: NSRunningApplication) -> DesktopApplicationIdentity? {
        guard !application.isTerminated, application.processIdentifier > 0,
              let launchedAt = application.launchDate, launchedAt.timeIntervalSince1970.isFinite,
              let bundleID = application.bundleIdentifier, !bundleID.isEmpty,
              let bundleURL = application.bundleURL, bundleURL.isFileURL else { return nil }
        return DesktopApplicationIdentity(processID: application.processIdentifier, launchedAt: launchedAt,
            bundleID: bundleID, bundleURL: bundleURL.resolvingSymlinksInPath().standardizedFileURL)
    }

    static func select(_ applications: [NSRunningApplication], foreground: pid_t?) -> NSRunningApplication? {
        guard !applications.isEmpty, Set(applications.map(\.processIdentifier)).count == applications.count else { return nil }
        if applications.count == 1 {
            guard let application = applications.first, identity(of: application) != nil else { return nil }
            return application
        }
        guard let foreground, let application = applications.first(where: { $0.processIdentifier == foreground }),
              let selected = identity(of: application),
              applications.allSatisfy({ other in
                  guard other.bundleIdentifier == selected.bundleID else { return false }
                  // macOS can omit the launch date or bundle URL for an unrelated
                  // process. It is never selected or controlled. Known conflicting
                  // application copies still refuse; the foreground identity must
                  // always be complete before any observation or mutation.
                  return other.bundleURL.map { $0.resolvingSymlinksInPath().standardizedFileURL == selected.bundleURL } ?? true
              }) else { return nil }
        guard select(applications.compactMap { identity(of: $0) }, foreground: foreground) == selected else { return nil }
        return application
    }

    nonisolated static func select(_ candidates: [DesktopApplicationIdentity], foreground: pid_t?) -> DesktopApplicationIdentity? {
        guard let first = candidates.first,
              Set(candidates.map(\.processID)).count == candidates.count else { return nil }
        if candidates.count == 1 { return first }
        // A display-name collision between different applications is not a profile.
        guard candidates.allSatisfy({ $0.bundleID == first.bundleID && $0.bundleURL == first.bundleURL }),
              let foreground else { return nil }
        return candidates.first { $0.processID == foreground }
    }

    static func matches(_ identity: DesktopApplicationIdentity, application: NSRunningApplication) -> Bool {
        Self.identity(of: application) == identity
    }
}
