import AppKit
import CoreServices
import Foundation

/// A process-targeted URL event. Successful dispatch does not verify a tab or navigation.
nonisolated enum BrowserURLDispatch {
    static let eventCode: OSType = 0x4755524C // GURL
    static let timeout: TimeInterval = 2

    struct Target: Sendable, Equatable {
        let processID: pid_t
        let launchedAt: Date
        let bundleID: String
        let bundleURL: URL
    }

    struct Request: Sendable {
        let destination: String
        let target: Target
        let preparedAt: Date
        let deadline: Date

        fileprivate init(destination: String, target: Target, preparedAt: Date, deadline: Date) {
            self.destination = destination
            self.target = target
            self.preparedAt = preparedAt
            self.deadline = deadline
        }
    }

    enum Failure: LocalizedError {
        case invalidDestination, invalidApplication, applicationChanged, expired
        case permissionNeeded, permissionDenied, permissionCheckFailed(OSStatus), dispatchUncertain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidDestination: "The browser URL must be an explicit HTTP or HTTPS destination without credentials or control characters."
            case .invalidApplication: "The captured application must be the selected running Chrome or Safari instance."
            case .applicationChanged: "The selected browser process changed before URL dispatch. Inspect the intended browser before trying again."
            case .expired: "The browser navigation deadline expired or its clock changed before dispatch. No URL was dispatched."
            case .permissionNeeded: "macOS Automation permission is required for the selected browser. No URL was dispatched."
            case .permissionDenied: "macOS denied Automation access to the selected browser. No URL was dispatched."
            case .permissionCheckFailed(let status): "Browser Automation permission could not be checked (\(status)). No URL was dispatched."
            case .dispatchUncertain(let status): "The browser URL event did not return a confirmed acceptance (\(status)). Its effects are uncertain. Inspect the selected browser before another navigation request."
            }
        }
    }

    /// Call only after the ordinary browser destination review. This API never asks
    /// macOS to grant Automation permission and never falls back to another app.
    @MainActor static func open(_ url: URL, in application: NSRunningApplication, applicationURL: URL,
                               deadline: Date = Date().addingTimeInterval(30)) async throws {
        guard !application.isTerminated, let launchedAt = application.launchDate,
              let bundleID = application.bundleIdentifier, let actualURL = application.bundleURL,
              canonical(actualURL) == canonical(applicationURL) else { throw Failure.invalidApplication }
        let target = Target(processID: application.processIdentifier, launchedAt: launchedAt,
                            bundleID: bundleID, bundleURL: canonical(applicationURL))
        let request = try prepare(url, target: target, deadline: deadline)
        try await dispatch(request)
    }

    @MainActor static func prepare(_ url: URL, target: Target, deadline: Date = Date().addingTimeInterval(30), now: Date = Date()) throws -> Request {
        let validated: URL
        do { validated = try BrowserAutomation.validatedURL(url.absoluteString) }
        catch { throw Failure.invalidDestination }
        guard target.processID > 0, target.launchedAt.timeIntervalSince1970.isFinite,
              ["com.google.Chrome", "com.apple.Safari"].contains(target.bundleID),
              target.bundleURL.isFileURL, target.bundleURL.pathExtension.lowercased() == "app",
              target.bundleURL.host == nil || target.bundleURL.host == "" || target.bundleURL.host == "localhost",
              target.bundleURL.user == nil, target.bundleURL.password == nil,
              target.bundleURL.query == nil, target.bundleURL.fragment == nil else { throw Failure.invalidApplication }
        let request = Request(destination: validated.absoluteString,
                              target: Target(processID: target.processID, launchedAt: target.launchedAt,
                                             bundleID: target.bundleID, bundleURL: canonical(target.bundleURL)),
                              preparedAt: now, deadline: deadline)
        try checkDeadline(request, now: now)
        return request
    }

    @concurrent private static func dispatch(_ request: Request) async throws {
        try perform(request, isCurrent: isCurrent, preflight: { address, eventClass, eventID, askUser in
            guard let target = address.aeDesc else { return OSStatus(procNotFound) }
            return AEDeterminePermissionToAutomateTarget(target, eventClass, eventID, askUser)
        }, send: { event, options, timeout in
            try event.sendEvent(options: options, timeout: timeout)
        })
    }

    /// The injected boundaries exercise the same identity, permission and one-send
    /// sequence as production without sending a URL to a real browser.
    static func perform(_ request: Request, now: () -> Date = Date.init, isCurrent: (Target) -> Bool,
                        preflight: (NSAppleEventDescriptor, AEEventClass, AEEventID, Bool) -> OSStatus,
                        send: (NSAppleEventDescriptor, NSAppleEventDescriptor.SendOptions, TimeInterval) throws -> NSAppleEventDescriptor) throws {
        try Task.checkCancellation()
        try checkDeadline(request, now: now())
        guard isCurrent(request.target) else { throw Failure.applicationChanged }
        let address = NSAppleEventDescriptor(processIdentifier: request.target.processID)
        let permission = preflight(address, AEEventClass(eventCode), AEEventID(eventCode), false)
        switch permission {
        case noErr: break
        case OSStatus(errAEEventWouldRequireUserConsent): throw Failure.permissionNeeded
        case OSStatus(errAEEventNotPermitted): throw Failure.permissionDenied
        default: throw Failure.permissionCheckFailed(permission)
        }
        try Task.checkCancellation()
        guard isCurrent(request.target) else { throw Failure.applicationChanged }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(eventCode), eventID: AEEventID(eventCode),
            targetDescriptor: address, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(.init(string: request.destination), forKeyword: AEKeyword(keyDirectObject))
        let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract, .dontRecord,
            .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
        let dispatchTime = now()
        try checkDeadline(request, now: dispatchTime)
        let remaining = min(timeout, request.deadline.timeIntervalSince(dispatchTime))
        let reply: NSAppleEventDescriptor
        do { reply = try send(event, options, remaining) }
        catch { throw Failure.dispatchUncertain(OSStatus(clamping: (error as NSError).code)) }
        guard reply.descriptorType == DescType(typeAppleEvent) else { throw Failure.dispatchUncertain(OSStatus(errAECoercionFail)) }
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw Failure.dispatchUncertain(error.int32Value)
        }
    }

    private static func checkDeadline(_ request: Request, now: Date) throws {
        let remaining = request.deadline.timeIntervalSince(now)
        guard now.timeIntervalSince1970.isFinite, request.preparedAt.timeIntervalSince1970.isFinite,
              request.deadline.timeIntervalSince1970.isFinite, now >= request.preparedAt,
              remaining > 0, remaining <= 30 else { throw Failure.expired }
    }

    private static func isCurrent(_ target: Target) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: target.processID), !application.isTerminated,
              application.launchDate == target.launchedAt, application.bundleIdentifier == target.bundleID,
              let bundleURL = application.bundleURL else { return false }
        return canonical(bundleURL) == target.bundleURL
    }

    private static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
}
