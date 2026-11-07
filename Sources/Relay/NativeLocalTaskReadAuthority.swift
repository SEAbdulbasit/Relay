import AppKit
import Foundation

/// Read authority is minted by app-owned local user-task submission, exactly
/// as ordinary MacTools reading is. It is never minted from a tool argument,
/// source content, a native catalog annotation or a model assertion.
@MainActor final class NativeLocalTaskReadAuthority {
    typealias Resolve = @MainActor (String) throws -> NativeWindowTaskAdapter.ApplicationAdmission
    let taskID: UUID
    private let taskIsCurrent: @MainActor () -> Bool
    private let restrictions: [NativeWindowTaskAdapter.ApplicationAdmission]?
    private let resolve: Resolve

    private init(taskID: UUID, taskIsCurrent: @escaping @MainActor () -> Bool,
                 restrictions: [NativeWindowTaskAdapter.ApplicationAdmission]?, resolve: @escaping Resolve) {
        self.taskID = taskID; self.taskIsCurrent = taskIsCurrent
        self.restrictions = restrictions; self.resolve = resolve
    }

    /// Only trusted UI/Store invocation code calls this. nil restrictions retain
    /// ordinary local multi-app task access; an explicit list narrows that task.
    static func localUserInvocation(taskID: UUID, taskIsCurrent: @escaping @MainActor () -> Bool,
                                    restrictions: [NativeWindowTaskAdapter.ApplicationAdmission]? = nil,
                                    resolve: Resolve? = nil) -> Self {
        Self(taskID: taskID, taskIsCurrent: taskIsCurrent, restrictions: restrictions,
            resolve: resolve ?? resolveActualApplication)
    }

    func admit(_ requestedBundleID: String) throws -> NativeWindowTaskAdapter.ApplicationAdmission {
        try Task.checkCancellation()
        guard taskIsCurrent() else { throw NativeWindowTaskAdapter.Failure.inactiveTask }
        guard !requestedBundleID.isEmpty, requestedBundleID.utf8.count <= 255,
              requestedBundleID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [45, 46, 95].contains($0) }) else {
            throw NativeWindowTaskAdapter.Failure.invalidApplication
        }
        let admission: NativeWindowTaskAdapter.ApplicationAdmission
        if let restrictions {
            let matches = restrictions.filter { $0.application.bundleID == requestedBundleID }
            guard matches.count == 1, let match = matches.first else { throw NativeWindowTaskAdapter.Failure.unadmittedApplication }
            admission = match
        } else { admission = try resolve(requestedBundleID) }
        guard admission.application.bundleID == requestedBundleID else { throw NativeWindowTaskAdapter.Failure.unadmittedApplication }
        try admission.validate()
        return .init(application: admission.application, validate: { [weak self] in
            guard let self, self.taskIsCurrent() else { throw NativeWindowTaskAdapter.Failure.inactiveTask }
            try admission.validate()
        })
    }

    private static func resolveActualApplication(_ bundleID: String) throws -> NativeWindowTaskAdapter.ApplicationAdmission {
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        guard let application = DesktopApplicationTarget.select(candidates,
            foreground: NSWorkspace.shared.frontmostApplication?.processIdentifier),
              let identity = DesktopApplicationTarget.identity(of: application), identity.bundleID == bundleID else {
            throw NativeWindowTaskAdapter.Failure.unadmittedApplication
        }
        return .init(application: identity, validate: {
            try Task.checkCancellation()
            guard DesktopApplicationTarget.matches(identity, application: application) else {
                throw NativeWindowTaskAdapter.Failure.unadmittedApplication
            }
        })
    }
}
