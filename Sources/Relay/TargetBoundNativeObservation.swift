import AppKit
import ApplicationServices
import Foundation
import ImageIO

/// Read-only admission for the native provider. Native indices are never AX references and
/// screenshots are transient memory, not ToolResult/chat/persistence payloads.
@MainActor
final class TargetBoundNativeObservation {
    nonisolated enum Failure: Error, Equatable {
        case inactiveSession, stopped, busy, staleRequest, ambiguousApplication, unavailableWindow
        case changedTarget, malformedHeader, wrongApplication, wrongWindow, nativeError, noUsableState
    }

    nonisolated struct WindowInfo: Sendable, Equatable {
        let title: String
        let role: String
        let identifier: String
        let document: String
        let url: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let minimized: Bool
        let hidden: Bool?
        let modal: Bool?

        func matchesExactly(_ other: Self) -> Bool {
            zip([title, role, identifier, document, url], [other.title, other.role, other.identifier, other.document, other.url])
                .allSatisfy { $0.utf16.elementsEqual($1.utf16) }
                && x == other.x && y == other.y && width == other.width && height == other.height
                && minimized == other.minimized && hidden == other.hidden && modal == other.modal
        }
    }

    struct Preparation {
        let application: DesktopApplicationIdentity
        let window: WindowInfo
        let sourceID: UUID
        /// Capture safety: provider app-only reads must still select this exact AX window.
        let validate: @MainActor () throws -> Void
        let validateSource: @MainActor () throws -> Void
        let validateInput: (@MainActor () throws -> Void)?
        fileprivate let originalAXWindow: AXUIElement?
        fileprivate let originalFocus: NativeOriginalWindowFocus?

        init(application: DesktopApplicationIdentity, window: WindowInfo,
             validate: @escaping @MainActor () throws -> Void,
             sourceID: UUID = UUID(), validateSource: (@MainActor () throws -> Void)? = nil,
             validateInput: (@MainActor () throws -> Void)? = nil,
             originalAXWindow: AXUIElement? = nil, originalFocus: NativeOriginalWindowFocus? = nil) {
            self.application = application; self.window = window; self.validate = validate; self.sourceID = sourceID
            self.validateSource = validateSource ?? validate; self.validateInput = validateInput
            self.originalAXWindow = originalAXWindow; self.originalFocus = originalFocus
        }
    }

    struct Backend {
        let capture: @MainActor (String, String) async throws -> OwnedNativeComputerUseClient.NativeResult
        let close: @MainActor () async -> Void

        init(client: OwnedNativeComputerUseClient) {
            capture = { requestID, app in try await client.state(requestID: requestID, app: app) }
            close = { await client.close() }
        }

        init(capture: @escaping @MainActor (String, String) async throws -> OwnedNativeComputerUseClient.NativeResult,
             close: @escaping @MainActor () async -> Void) {
            self.capture = capture; self.close = close
        }
    }

    struct Request {
        fileprivate let owner: UUID
        fileprivate let revision: UUID
        fileprivate let preparation: Preparation
    }

    /// A retained exact-target capability. It never selects the currently active window.
    /// Snapshot generations may change while this target's original metadata remains pinned.
    struct TargetLease {
        fileprivate let owner: UUID
        fileprivate let session: UUID
        fileprivate let preparation: Preparation
        var sourceID: UUID { preparation.sourceID }
        func validate() throws { try preparation.validate() }
        func validateOriginalSource() throws { try preparation.validateSource() }
    }

    nonisolated struct Image: Sendable {
        let data: Data
        let mimeType: String
        let width: Int
        let height: Int
    }

    /// Deliberately not Codable. Consumers must check isCurrent before using source data.
    nonisolated struct Snapshot: Sendable {
        let id: UUID
        let application: DesktopApplicationIdentity
        let window: WindowInfo
        let text: String
        let references: [String]
        let images: [Image]
        let imageCoverage: String?
        fileprivate let owner: UUID
        fileprivate let revision: UUID
    }

    nonisolated struct Header: Sendable, Equatable {
        let path: String
        let bundleID: String
        let processID: pid_t
        let windowTitle: String
    }

    private let owner = UUID()
    private var session = UUID()
    private var revision = UUID()
    private var generation: UInt64 = 0
    private var latestPreparation: Preparation?
    private var backend: Backend
    private let sessionIsActive: @MainActor () -> Bool
    private var activeSession = true
    private var stopped = false
    private var captureTask: Task<OwnedNativeComputerUseClient.NativeResult, Error>?
    private var captureID: UUID?
    private var cleanupTask: Task<Void, Never>?
    private var lastSnapshot: UUID?
    private var validateLatest: (@MainActor () throws -> Void)?
    private(set) var latest: Snapshot?

    init(client: OwnedNativeComputerUseClient, sessionIsActive: @escaping @MainActor () -> Bool) {
        backend = Backend(client: client)
        self.sessionIsActive = sessionIsActive
    }

    init(backend: Backend, sessionIsActive: @escaping @MainActor () -> Bool) {
        self.backend = backend; self.sessionIsActive = sessionIsActive
    }

    func prepare(application: NSRunningApplication) throws -> Request {
        try requireActive()
        return try prepare(Self.bind(application: application, requireCurrent: { [weak self] in
            guard let self else { throw Failure.stopped }
            try self.requireActive()
        }))
    }


    /// Metadata seam: production binds AX synchronously; tests supply inert metadata only.
    func prepare(_ preparation: Preparation) throws -> Request {
        try requireActive()
        guard captureTask == nil else { throw Failure.busy }
        try preparation.validate()
        guard Self.valid(preparation.window) else { throw Failure.unavailableWindow }
        return Request(owner: owner, revision: revision, preparation: preparation)
    }

    func observe(_ request: Request) async throws -> Snapshot {
        try await observe(request, capture: backend.capture)
    }

    private func observe(_ request: Request,
                         capture: @escaping @MainActor (String, String) async throws -> OwnedNativeComputerUseClient.NativeResult) async throws -> Snapshot {
        try requireActive()
        guard captureTask == nil else { throw Failure.busy }
        guard request.owner == owner, request.revision == revision else { throw Failure.staleRequest }
        invalidateSnapshot()
        try request.preparation.validate()
        guard generation < UInt64.max else { throw Failure.stopped }
        generation += 1
        let expectedRevision = revision
        let namespace = "native:\(session.uuidString):\(generation):"
        let task = Task { try await capture(UUID().uuidString, request.preparation.application.bundleURL.path) }
        let operation = UUID()
        captureID = operation
        captureTask = task
        defer { if captureID == operation { captureTask = nil; captureID = nil } }
        do {
            let result = try await withTaskCancellationHandler { try await task.value }
                onCancel: { task.cancel() }
            try requireCurrent(expectedRevision)
            try request.preparation.validate()
            guard !result.isError else { throw NativeReadProviderError(result: result) }
            let nativeText = try Self.stateText(result)
            let header = try Self.parseHeader(nativeText)
            try Self.validate(header, preparation: request.preparation)
            let decoded = await Self.decodeImages(result.content)
            try requireCurrent(expectedRevision)
            try request.preparation.validate()
            let scoped = Self.namespace(nativeText, prefix: namespace)
            guard !scoped.references.isEmpty || !decoded.images.isEmpty else { throw Failure.noUsableState }
            let snapshot = Snapshot(id: UUID(), application: request.preparation.application, window: request.preparation.window,
                text: scoped.text, references: scoped.references, images: decoded.images, imageCoverage: decoded.coverage,
                owner: owner, revision: expectedRevision)
            latest = snapshot; lastSnapshot = snapshot.id; validateLatest = request.preparation.validate
            latestPreparation = request.preparation
            return snapshot
        } catch {
            if revision == expectedRevision { invalidateSnapshot() }
            if let transport = error as? OwnedNativeComputerUseClient.Failure { throw NativeReadTransportError(transport) }
            throw error
        }
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        guard activeSession, sessionIsActive() else { stop(); return false }
        guard !stopped, snapshot.owner == owner, snapshot.revision == revision,
              snapshot.id == lastSnapshot else { return false }
        do { try validateLatest?(); return true }
        catch { invalidateSnapshot(); return false }
    }

    func retainTarget(for snapshot: Snapshot) throws -> TargetLease {
        try requireActive()
        guard isCurrent(snapshot), let preparation = latestPreparation else { throw Failure.staleRequest }
        return TargetLease(owner: owner, session: session, preparation: preparation)
    }

    /// Refresh and readback use the same original process/window/document, even if another
    /// application's window became current. A changed original target is refused.
    func observeOriginal(_ lease: TargetLease) async throws -> Snapshot {
        try validateTarget(lease)
        return try await observe(prepare(lease.preparation))
    }

    /// A provider FIFO reservation avoids a second queue acquisition between pixel proof and
    /// input dispatch. The reservation itself admits only this original app's state read.
    func observeOriginal(_ lease: TargetLease, reserved: OwnedNativeComputerUseClient.ReservedState) async throws -> Snapshot {
        try validateTarget(lease)
        return try await observe(prepare(lease.preparation), capture: { requestID, app in
            try await reserved.state(requestID: requestID, app: app)
        })
    }

    func validateTarget(_ lease: TargetLease) throws {
        try validateOriginalSource(lease)
        try lease.preparation.validate()
    }

    /// Independent of image consumption and global/app-selected foreground focus.
    func validateOriginalSource(_ lease: TargetLease) throws {
        try requireActive()
        guard lease.owner == owner, lease.session == session else { throw Failure.staleRequest }
        try lease.preparation.validateSource()
        try requireActive()
    }

    func validateForInput(_ lease: TargetLease) throws {
        try validateOriginalSource(lease)
        guard let validate = lease.preparation.validateInput else { throw Failure.unavailableWindow }
        try validate(); try requireActive()
    }

    func originalAXWindow(_ lease: TargetLease) throws -> AXUIElement {
        try validateOriginalSource(lease)
        guard let original = lease.preparation.originalAXWindow else { throw Failure.unavailableWindow }
        return original
    }

    func restoreReviewedOriginalFocus(_ lease: TargetLease, authorization: NativeReviewedFocusAuthorization,
                                      gate: NativeInputRevocation,
                                      notAfter: ContinuousClock.Instant) async -> NativeReviewedFocusOutcome {
        do {
            try validateOriginalSource(lease)
            guard authorization.sourceID == lease.sourceID,
                  let binding = lease.preparation.originalFocus else { throw Failure.changedTarget }
            let outcome = await binding.restore(authorization: authorization, gate: gate, notAfter: notAfter)
            // Attempted focus facts must remain factual after Stop/source revocation.
            return outcome
        } catch { return .refused(NativeVisualStepOutcome.bounded(error.localizedDescription)) }
    }

    /// Invalidate immediately, before awaiting transport teardown. Resuming never captures.
    func stop() {
        let needsCleanup = !stopped
        stopped = true
        invalidateSnapshot()
        captureTask?.cancel(); captureTask = nil; captureID = nil
        guard needsCleanup else { return }
        let previous = cleanupTask, backend = backend
        cleanupTask = Task { await previous?.value; await backend.close() }
    }

    func drain() async { await cleanupTask?.value }

    func setSessionActive(_ active: Bool) {
        activeSession = active
        if !active { stop() }
    }

    func reconnect(client: OwnedNativeComputerUseClient) async throws {
        try await reconnect(backend: Backend(client: client))
    }

    func reconnect(backend next: Backend) async throws {
        stop()
        let expected = revision
        await drain()
        guard revision == expected, activeSession, sessionIsActive() else { await next.close(); throw Failure.inactiveSession }
        backend = next; session = UUID(); generation = 0; stopped = false
        revision = UUID()
    }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard activeSession, sessionIsActive() else { stop(); throw Failure.inactiveSession }
        guard !stopped else { throw Failure.stopped }
    }

    private func requireCurrent(_ expected: UUID) throws {
        try requireActive()
        guard revision == expected else { throw Failure.staleRequest }
    }

    private func invalidateSnapshot() {
        revision = UUID(); latest = nil; lastSnapshot = nil; validateLatest = nil; latestPreparation = nil
    }

    private nonisolated static func valid(_ window: WindowInfo) -> Bool {
        !window.title.isEmpty && window.title.utf8.count <= 8_192 && window.role == "AXWindow"
            && !window.minimized && window.hidden != true
            && [window.x, window.y, window.width, window.height].allSatisfy(\.isFinite)
            && window.width > 0 && window.height > 0 && window.width <= 32_768 && window.height <= 32_768
    }

    private static func bind(application: NSRunningApplication,
                             requireCurrent: @escaping @MainActor () throws -> Void) throws -> Preparation {
        try requireCurrent()
        guard AXIsProcessTrusted(), let identity = DesktopApplicationTarget.identity(of: application) else {
            throw Failure.ambiguousApplication
        }
        try requireExclusive(identity)
        let root = AXUIElementCreateApplication(identity.processID)
        AXUIElementSetMessagingTimeout(root, 0.12)
        let window = try selectedWindow(root)
        let initial = try windowInfo(window)
        guard valid(initial) else { throw Failure.unavailableWindow }
        let sourceID = UUID()
        let validateOriginalFacts: @MainActor () throws -> Void = {
            try requireCurrent()
            guard AXIsProcessTrusted(), DesktopApplicationTarget.matches(identity, application: application) else { throw Failure.changedTarget }
            try requireExclusive(identity)
            var pid: pid_t = 0
            guard AXUIElementGetPid(window, &pid) == .success, pid == identity.processID,
                  initial.matchesExactly(try windowInfo(window)) else { throw Failure.changedTarget }
            try requireCurrent()
        }
        // Initial binding still selects one original window once; it cannot recover
        // an unqualified first binding or substitute another current window later.
        let validateInitiallySelected: @MainActor () throws -> Void = {
            try validateOriginalFacts()
            guard CFEqual(try selectedWindow(root), window) else { throw Failure.changedTarget }
            try requireCurrent()
        }
        try uniqueWindow(window, title: initial.title, root: root, allowSiblingRecovery: false,
                         validateOriginal: validateInitiallySelected, requireCurrent: requireCurrent)
        let browser = isBrowser(identity)
            ? try BrowserPageReader.captureCurrentTarget(application: application, expectedWindow: window) : nil
        if let browser { try BrowserPageReader.validateCurrentTarget(browser, expectedWindow: window) }
        let validateOriginalDocument: @MainActor () throws -> Void = {
            try validateOriginalFacts()
            if let browser { try BrowserPageReader.validateCurrentTarget(browser, expectedWindow: window) }
            try requireCurrent()
        }
        let validateSource: @MainActor () throws -> Void = {
            try uniqueWindow(window, title: initial.title, root: root, allowSiblingRecovery: true,
                validateOriginal: validateOriginalDocument, requireCurrent: requireCurrent)
        }
        let validateCapture: @MainActor () throws -> Void = {
            try validateSource()
            // The native schema cannot choose an arbitrary window. Refuse before
            // calling it when this app's selected window is no longer the original.
            guard CFEqual(try selectedWindow(root), window) else { throw Failure.changedTarget }
            try validateSource()
        }
        let validateInput: @MainActor () throws -> Void = {
            try validateCapture()
            guard application.isActive, let front = NSWorkspace.shared.frontmostApplication,
                  DesktopApplicationTarget.matches(identity, application: front) else { throw Failure.changedTarget }
            try validateCapture()
        }
        let focus = NativeOriginalWindowFocus(sourceID: sourceID, application: application, identity: identity,
            originalWindow: window, validateOriginalSource: validateSource,
            validateForInput: validateInput, sessionIsActive: { (try? requireCurrent()) != nil })
        try requireCurrent()
        return Preparation(application: identity, window: initial, validate: validateCapture,
            sourceID: sourceID, validateSource: validateSource, validateInput: validateInput,
            originalAXWindow: window, originalFocus: focus)
    }

    private static func requireExclusive(_ identity: DesktopApplicationIdentity) throws {
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: identity.bundleID).filter { !$0.isTerminated }
        guard candidates.count == 1, let selected = candidates.first,
              DesktopApplicationTarget.matches(identity, application: selected) else { throw Failure.ambiguousApplication }
    }

    private static func isBrowser(_ identity: DesktopApplicationIdentity) -> Bool {
        let known: Set<String> = ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
                                  "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
        if known.contains(identity.bundleID) { return true }
        let types = Bundle(url: identity.bundleURL)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.contains { item in
            (item["CFBundleURLSchemes"] as? [String] ?? []).contains { ["http", "https"].contains($0.lowercased()) }
        }
    }

    private static func selectedWindow(_ root: AXUIElement) throws -> AXUIElement {
        guard let value = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw Failure.unavailableWindow
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func uniqueWindow(_ original: AXUIElement, title: String, root: AXUIElement,
                                     allowSiblingRecovery: Bool,
                                     validateOriginal: @escaping @MainActor () throws -> Void,
                                     requireCurrent: @escaping @MainActor () throws -> Void) throws {
        let backend = NativeWindowEnumeration.Backend<AXUIElement>(enumerate: {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
            guard status == .success else { throw NativeWindowEnumeration.ReadFailure(attribute: .windows, status: status) }
            guard let windows = value as? [AXUIElement] else { throw Failure.unavailableWindow }
            return windows
        }, title: { member in
            AXUIElementSetMessagingTimeout(member, 0.04)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(member, kAXTitleAttribute as CFString, &value)
            guard status == .success else { throw NativeWindowEnumeration.ReadFailure(attribute: .title, status: status) }
            guard let title = value as? String else { throw Failure.unavailableWindow }
            return title
        }, same: { CFEqual($0, $1) }, validateOriginal: validateOriginal, requireCurrent: requireCurrent)
        do {
            try NativeWindowEnumeration.validate(original: original, title: title,
                allowSiblingRecovery: allowSiblingRecovery, backend: backend)
        } catch let error as NativeWindowEnumeration.Failure {
            switch error {
            case .unavailableWindow: throw Failure.unavailableWindow
            case .wrongWindow: throw Failure.wrongWindow
            case .changedEnumeration: throw Failure.changedTarget
            }
        } catch is NativeWindowEnumeration.ReadFailure {
            throw Failure.unavailableWindow
        }
    }

    private static func windowInfo(_ window: AXUIElement) throws -> WindowInfo {
        AXUIElementSetMessagingTimeout(window, 0.08)
        guard let role = attribute(window, kAXRoleAttribute) as? String,
              let title = attribute(window, kAXTitleAttribute) as? String,
              let minimized = attribute(window, kAXMinimizedAttribute) as? Bool,
              let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { throw Failure.unavailableWindow }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { throw Failure.unavailableWindow }
        func text(_ name: String) -> String {
            let value = attribute(window, name)
            if let string = value as? String { return string }
            if let url = value as? URL { return url.absoluteString }
            return ""
        }
        return WindowInfo(title: title, role: role, identifier: text(kAXIdentifierAttribute), document: text(kAXDocumentAttribute),
            url: text(kAXURLAttribute), x: point.x, y: point.y, width: dimensions.width, height: dimensions.height,
            minimized: minimized, hidden: attribute(window, "AXHidden") as? Bool, modal: attribute(window, "AXModal") as? Bool)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    nonisolated static func parseHeader(_ text: String) throws -> Header {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(5).map(String.init)
        guard lines.count >= 4, lines[0].hasPrefix("Computer Use state (CUA App Version: "), lines[0].hasSuffix(")"),
              lines[1] == "<app_state>", lines[2].hasPrefix("App="), lines[2].hasSuffix(")"),
              let bundleStart = lines[2].range(of: " (bundleID ", options: .backwards),
              let pidStart = lines[2].range(of: ", pid ", options: .backwards), bundleStart.upperBound < pidStart.lowerBound else {
            throw Failure.malformedHeader
        }
        let version = lines[0].dropFirst("Computer Use state (CUA App Version: ".count).dropLast()
        guard !version.isEmpty, version.count <= 20, version.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw Failure.malformedHeader
        }
        var path = String(lines[2][lines[2].index(lines[2].startIndex, offsetBy: 4)..<bundleStart.lowerBound])
        if path.hasSuffix("/") && path != "/" { path.removeLast() }
        let bundle = String(lines[2][bundleStart.upperBound..<pidStart.lowerBound])
        let rawPID = lines[2][pidStart.upperBound..<lines[2].index(before: lines[2].endIndex)]
        guard path.hasPrefix("/"), !bundle.isEmpty, !rawPID.isEmpty,
              rawPID.allSatisfy({ $0.isASCII && $0.isNumber }), let pid = pid_t(rawPID), pid > 0,
              lines[3].hasPrefix("Window: \""), let titleEnd = lines[3].range(of: "\", App: ", options: .backwards),
              titleEnd.lowerBound >= lines[3].index(lines[3].startIndex, offsetBy: 9),
              titleEnd.upperBound < lines[3].endIndex else { throw Failure.malformedHeader }
        let title = String(lines[3][lines[3].index(lines[3].startIndex, offsetBy: 9)..<titleEnd.lowerBound])
        guard !title.isEmpty else { throw Failure.malformedHeader }
        return Header(path: path, bundleID: bundle, processID: pid, windowTitle: title)
    }

    private static func validate(_ header: Header, preparation: Preparation) throws {
        let identity = preparation.application
        guard header.processID == identity.processID, header.bundleID.utf16.elementsEqual(identity.bundleID.utf16),
              header.path.utf16.elementsEqual(identity.bundleURL.path.utf16) else { throw Failure.wrongApplication }
        guard header.windowTitle.utf16.elementsEqual(preparation.window.title.utf16) else { throw Failure.wrongWindow }
    }

    private nonisolated static func stateText(_ result: OwnedNativeComputerUseClient.NativeResult) throws -> String {
        guard let text = result.content.first?.object, text["type"] == .string("text"), let content = text["text"]?.string,
              content.utf8.count <= 256_000 else { throw Failure.malformedHeader }
        return content
    }

    private nonisolated static func namespace(_ text: String, prefix: String) -> (text: String, references: [String]) {
        var references: [String] = [], seen = Set<String>(), ids: [String: String] = [:]
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let leading = line.prefix { $0 == "\t" || $0 == " " }
            let remainder = line.dropFirst(leading.count)
            let digits = remainder.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 8, remainder.dropFirst(digits.count).first == " " else { return String(line) }
            let id = prefix + digits
            ids[String(digits)] = id
            if seen.insert(id).inserted { references.append(id) }
            return String(leading) + "[" + id + "]" + remainder.dropFirst(digits.count)
        }
        let focusedPrefix = "The focused UI element is "
        lines = lines.map { line in
            guard line.hasPrefix(focusedPrefix) else { return line }
            let remainder = line.dropFirst(focusedPrefix.count)
            let digits = remainder.prefix { $0.isASCII && $0.isNumber }
            guard let id = ids[String(digits)], remainder.dropFirst(digits.count).first == " " else { return line }
            return focusedPrefix + "[" + id + "]" + remainder.dropFirst(digits.count)
        }
        return (lines.joined(separator: "\n"), references)
    }

    private nonisolated struct DecodedImages: Sendable { let images: [Image]; let coverage: String? }

    @concurrent private static func decodeImages(_ content: [JSONValue]) async -> DecodedImages {
        var images: [Image] = [], bytes = 0, rejected = 0
        for value in content where value.object?["type"] == .string("image") {
            guard images.count < 4, let object = value.object, let encoded = object["data"]?.string,
                  encoded.utf8.count <= 12 * 1_048_576, let mime = object["mimeType"]?.string,
                  ["image/png", "image/jpeg"].contains(mime), let data = Data(base64Encoded: encoded),
                  data.count <= 8 * 1_048_576, bytes + data.count <= 12 * 1_048_576,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8_192, height <= 8_192,
                  width <= 32_000_000 / height,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_048, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                rejected += 1; continue
            }
            bytes += data.count
            images.append(Image(data: data, mimeType: mime, width: width, height: height))
        }
        return DecodedImages(images: images,
            coverage: rejected > 0 ? "Some native images were unavailable or invalid. Use the scoped accessibility text when sufficient; no coordinates are authorized." : nil)
    }
}
