import AppKit
import ApplicationServices
import Foundation

/// A one-shot, memory-only insertion in the actual originally focused AX editor.
/// The owning task must serialize it with its native control FIFO and authorize this exact
/// prepared effect. No helper index, label or screenshot coordinate is translated to AX.
@MainActor final class NativeFocusedAXInsertion {
    nonisolated enum Failure: Error, Equatable {
        case inactive, stopped, consumed, wrongOwner, unavailableEditor, changedSource
        case invalidText, invalidSelection, expired, cancelled, authorizationChanged
    }
    nonisolated enum Uncertainty: Equatable, Sendable {
        case writeRejected, readbackUnavailable, readbackMismatch, formattingChanged, caretMismatch, stoppedAfterDispatch, expiredAfterDispatch
    }
    nonisolated enum Outcome: Equatable, Sendable {
        case inserted
        case unchanged
        case notDispatched(Failure)
        case uncertain(Uncertainty)
    }
    struct Metadata: Equatable {
        let role: String
        let subrole: String
        let protected: Bool?
        let hidden: Bool?
        let enabled: Bool?
        let selectionWritable: Bool
    }
    struct Contents {
        let value: String
        let selection: NSRange
        let selectedText: String
        /// Actual complete native attributed text, not guessed authored fonts or parsed RTF.
        let attributedValue: NSAttributedString
    }
    struct Access {
        /// Pins the exact original PID/launch/path/window/editor for source review.
        let validateOriginalTarget: @MainActor () throws -> Void
        let validateInputTarget: @MainActor () throws -> Void
        /// Must not read field contents. Privacy admission precedes `contents` every time.
        let metadata: @MainActor () throws -> Metadata
        let qualifiedLabels: @MainActor () throws -> NativeControlFocus.Labels
        let contents: @MainActor () throws -> Contents
        /// One AXSelectedText write. This capability never changes selection or presses a key.
        let writeSelectedText: @MainActor (String) throws -> Void

        init(validateOriginalTarget: @escaping @MainActor () throws -> Void,
             validateInputTarget: (@MainActor () throws -> Void)? = nil,
             metadata: @escaping @MainActor () throws -> Metadata,
             qualifiedLabels: @escaping @MainActor () throws -> NativeControlFocus.Labels = { .init(label: nil, identifier: nil) },
             contents: @escaping @MainActor () throws -> Contents,
             writeSelectedText: @escaping @MainActor (String) throws -> Void) {
            self.validateOriginalTarget = validateOriginalTarget
            self.validateInputTarget = validateInputTarget ?? validateOriginalTarget
            self.metadata = metadata; self.qualifiedLabels = qualifiedLabels
            self.contents = contents; self.writeSelectedText = writeSelectedText
        }
    }
    struct Authorization {
        /// Remains valid after consuming review. Pins the original task/source-grant revision.
        let validateTaskSource: @MainActor () throws -> Void
        /// Binds the exact unconsumed review to `prepared.id`.
        let revalidate: @MainActor () throws -> Void
        /// Consumes that one-use policy permit only at final input admission.
        let consume: @MainActor () throws -> Void
    }
    final class PreparedInsertion {
        let id = UUID()
        let selection: NSRange
        let expectedUTF16Count: Int
        let expectedCaret: NSRange
        var sourceBindingID: UUID { owner }
        var literalText: String? { payload?.literal }
        fileprivate let owner: UUID
        fileprivate var payload: Payload?
        fileprivate init(owner: UUID, literal: String, expected: String, selection: NSRange) {
            self.owner = owner; self.selection = selection; expectedUTF16Count = expected.utf16.count
            expectedCaret = NSRange(location: selection.location + literal.utf16.count, length: 0)
            payload = Payload(literal: literal, expected: expected)
        }
        fileprivate struct Payload { let literal: String; let expected: String }
        fileprivate func clear() { payload = nil }
    }
    private struct State {
        let metadata: Metadata
        let contents: Contents
        let formatting: NativeAttributedTextSnapshot
        let descriptor: NativeControlTargetDescriptor
        func matches(_ other: Self) -> Bool {
            metadata == other.metadata && descriptor == other.descriptor && contents.selection == other.contents.selection
                && formatting.matches(other.formatting)
                && contents.value.utf16.elementsEqual(other.contents.value.utf16)
                && contents.selectedText.utf16.elementsEqual(other.contents.selectedText.utf16)
        }
    }
    nonisolated static let maximumFieldBytes = 16_384
    nonisolated static let maximumInsertionBytes = 4_096
    private let owner = UUID()
    private let revocation = NativeInputRevocation()
    private let admissionGate: NativeInputRevocation?
    private let access: Access
    private let sessionIsActive: @MainActor () -> Bool
    private let now: @MainActor () -> ContinuousClock.Instant
    private var source: State?
    private var prepared: PreparedInsertion?
    private var stopped = false
    private var used = false
    private(set) var verifiedCaret: NSRange?
    var focusedTargetDescriptor: NativeControlTargetDescriptor? { source?.descriptor }

    /// Synthetic seams are used only by pure tests. Production binds actual AX objects below.
    init(access: Access, sessionIsActive: @escaping @MainActor () -> Bool,
         admissionGate: NativeInputRevocation? = nil,
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) throws {
        self.access = access; self.sessionIsActive = sessionIsActive; self.now = now; self.admissionGate = admissionGate
        try requireActive()
        let first = try readCurrent(), second = try readCurrent()
        guard first.matches(second) else { throw Failure.changedSource }
        source = second
    }

    func prepare(_ literal: String) throws -> PreparedInsertion {
        try requireActive()
        guard !used, let source else { throw Failure.consumed }
        let current = try readCurrent()
        guard source.matches(current) else { throw Failure.changedSource }
        let expected = try Self.expectedValue(value: source.contents.value, selection: source.contents.selection,
            selectedText: source.contents.selectedText, literal: literal, multiline: source.metadata.role == "AXTextArea")
        prepared?.clear()
        let next = PreparedInsertion(owner: owner, literal: literal, expected: expected, selection: source.contents.selection)
        prepared = next
        return next
    }

    /// Logical admission is synchronous and precedes exactly one write. Stop before admission
    /// prevents it; an already admitted AX call may finish and is uncertain if Stop intervenes.
    /// Any execution attempt consumes this binding, including known preflight refusals.
    func execute(_ insertion: PreparedInsertion, authorization: Authorization,
                 notAfter: ContinuousClock.Instant? = nil) -> Outcome {
        guard insertion.owner == owner else { return .notDispatched(.wrongOwner) }
        guard !used, insertion === prepared, let payload = insertion.payload, let source else { return .notDispatched(.consumed) }
        used = true
        defer { self.source = nil; prepared?.clear(); prepared = nil }
        let localDeadline = now().advanced(by: .seconds(2))
        let deadline = min(localDeadline, notAfter ?? localDeadline)
        let ticket = (admissionGate ?? revocation).ticket()
        do {
            try requireActive()
            guard now() < deadline else { throw Failure.expired }
            try authorization.validateTaskSource()
            try access.validateInputTarget()
            try authorization.revalidate()
            guard source.matches(try readCurrent()) else { throw Failure.changedSource }
            try requireActive()
            guard now() < deadline else { throw Failure.expired }
            if payload.expected.utf16.elementsEqual(source.contents.value.utf16) { return .unchanged }
            try authorization.consume()
            // Recheck the original bytes/range after potentially slow policy/review work.
            try requireActive()
            try authorization.validateTaskSource()
            guard source.matches(try readCurrent()) else { throw Failure.changedSource }
            try requireActive()
            try authorization.validateTaskSource()
            try access.validateInputTarget()
            if Task.isCancelled { throw Failure.cancelled }
            switch ticket.admit(now: now(), notAfter: deadline) {
            case .admitted: break
            case .expired: throw Failure.expired
            case .revoked: throw Failure.stopped
            case .consumed: throw Failure.consumed
            }
        } catch let error as Failure { return .notDispatched(error) }
        catch is CancellationError { return .notDispatched(.cancelled) }
        catch { return .notDispatched(.authorizationChanged) }

        do { try access.writeSelectedText(payload.literal) }
        catch { return .uncertain(.writeRejected) }
        guard !stopped, sessionIsActive(), !Task.isCancelled, admissionGate?.isActive != false else { return .uncertain(.stoppedAfterDispatch) }
        guard now() < deadline else { return .uncertain(.expiredAfterDispatch) }
        do {
            // A write may revoke the task/source grant. Do not fetch any private
            // post-action field contents after that boundary, even if the write succeeded.
            try authorization.validateTaskSource()
            try access.validateInputTarget()
            let after = try readCurrent()
            guard now() < deadline else { return .uncertain(.expiredAfterDispatch) }
            guard after.metadata == source.metadata else { return .uncertain(.readbackUnavailable) }
            guard after.contents.value.utf16.elementsEqual(payload.expected.utf16) else { return .uncertain(.readbackMismatch) }
            guard source.formatting.preservesUnchangedRegions(after: after.formatting,
                replaced: source.contents.selection, insertedUTF16Count: payload.literal.utf16.count) else { return .uncertain(.formattingChanged) }
            guard after.contents.selection == insertion.expectedCaret else { return .uncertain(.caretMismatch) }
            try authorization.validateTaskSource()
            try requireActive()
            verifiedCaret = after.contents.selection
            return .inserted
        } catch { return .uncertain(.readbackUnavailable) }
    }

    func stop() {
        guard !stopped else { return }
        revocation.revoke(); stopped = true; source = nil; prepared?.clear(); prepared = nil; verifiedCaret = nil
    }

    /// A post-action scope fence only. It reads no field values or attributed text.
    func validateOriginalFocus() throws {
        try requireActive(); try access.validateOriginalTarget(); try access.validateInputTarget(); try requireActive()
    }
    func validateSourcePreview() throws {
        try requireActive()
        guard let source, source.matches(try readCurrent()) else { throw Failure.changedSource }
    }
    func usesAdmissionGate(_ gate: NativeInputRevocation) -> Bool { admissionGate === gate }

    private func requireActive() throws {
        if Task.isCancelled { stop(); throw Failure.cancelled }
        guard !stopped else { throw Failure.stopped }
        guard admissionGate?.isActive != false else { stop(); throw Failure.stopped }
        guard sessionIsActive() else { stop(); throw Failure.inactive }
    }
    private func readCurrent() throws -> State {
        try requireActive(); try access.validateOriginalTarget()
        let metadata = try access.metadata()
        guard ["AXTextArea", "AXTextField"].contains(metadata.role),
              !metadata.subrole.localizedCaseInsensitiveContains("secure"),
              !metadata.subrole.localizedCaseInsensitiveContains("password"),
              !metadata.subrole.localizedCaseInsensitiveContains("search"),
              metadata.protected == false, metadata.hidden == false,
              metadata.enabled == true, metadata.selectionWritable else { throw Failure.unavailableEditor }
        // Metadata/ancestry queries can yield to another process. A close or Stop
        // delivered during them must not start a new private field-content read.
        try requireActive(); try access.validateOriginalTarget(); try requireActive()
        let labels = try access.qualifiedLabels()
        try requireActive(); try access.validateOriginalTarget(); try requireActive()
        let contents = try access.contents()
        guard contents.value.utf8.count <= Self.maximumFieldBytes else { throw Failure.unavailableEditor }
        try Self.validateSelection(value: contents.value, range: contents.selection, selectedText: contents.selectedText)
        let formatting = try NativeAttributedTextSnapshot(contents.attributedValue, expectedValue: contents.value)
        try requireActive(); try access.validateOriginalTarget()
        let frozen = Contents(value: contents.value, selection: contents.selection, selectedText: contents.selectedText,
            attributedValue: formatting.actual)
        let descriptor = try NativeControlTargetDescriptor(role: metadata.role, label: labels.label,
            identifier: labels.identifier, selection: .init(location: contents.selection.location,
                length: contents.selection.length, originalUTF16Count: contents.value.utf16.count))
        return State(metadata: metadata, contents: frozen, formatting: formatting, descriptor: descriptor)
    }

    nonisolated static func expectedValue(value: String, selection: NSRange, selectedText: String,
                                         literal: String, multiline: Bool) throws -> String {
        guard !literal.isEmpty, literal.utf8.count <= maximumInsertionBytes,
              multiline || !literal.contains(where: \.isNewline),
              !literal.unicodeScalars.contains(where: { scalar in
                  (scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value))
                      && !(multiline && [9, 10, 13].contains(scalar.value))
              }) else { throw Failure.invalidText }
        try validateSelection(value: value, range: selection, selectedText: selectedText)
        let units = Array(value.utf16)
        let end = selection.location + selection.length
        let expected = String(decoding: Array(units[..<selection.location]) + Array(literal.utf16) + Array(units[end...]), as: UTF16.self)
        guard expected.utf8.count <= maximumFieldBytes else { throw Failure.invalidText }
        return expected
    }
    nonisolated private static func validateSelection(value: String, range: NSRange, selectedText: String) throws {
        let units = Array(value.utf16)
        guard value.utf8.count <= maximumFieldBytes, range.location != NSNotFound,
              range.location >= 0, range.length >= 0, range.location <= units.count,
              range.length <= units.count - range.location else { throw Failure.invalidSelection }
        let end = range.location + range.length
        func boundary(_ index: Int) -> Bool {
            index == 0 || index == units.count || !((0xD800...0xDBFF).contains(units[index - 1]) && (0xDC00...0xDFFF).contains(units[index]))
        }
        guard boundary(range.location), boundary(end),
              units[range.location..<end].elementsEqual(selectedText.utf16) else { throw Failure.invalidSelection }
    }

    /// Caller supplies the already retained ORIGINAL AX window, never a native helper index.
    static func capture(application identity: DesktopApplicationIdentity, originalWindow: AXUIElement,
                        validateOriginalTarget: @escaping @MainActor () throws -> Void,
                        sessionIsActive: @escaping @MainActor () -> Bool,
                        admissionGate: NativeInputRevocation? = nil) throws -> NativeFocusedAXInsertion {
        let binding = try captureForReview(application: identity, originalWindow: originalWindow,
            validateOriginalSource: validateOriginalTarget, validateForInput: validateOriginalTarget,
            sessionIsActive: sessionIsActive, admissionGate: admissionGate)
        try binding.access.validateInputTarget()
        return binding
    }

    static func captureForReview(application identity: DesktopApplicationIdentity, originalWindow: AXUIElement,
                        validateOriginalSource: @escaping @MainActor () throws -> Void,
                        validateForInput: @escaping @MainActor () throws -> Void,
                        sessionIsActive: @escaping @MainActor () -> Bool,
                        admissionGate: NativeInputRevocation? = nil) throws -> NativeFocusedAXInsertion {
        guard sessionIsActive(), !Task.isCancelled, AXIsProcessTrusted(),
              !protectedBundles.contains(identity.bundleID.lowercased()),
              let app = NSRunningApplication(processIdentifier: identity.processID),
              DesktopApplicationTarget.matches(identity, application: app) else { throw Failure.unavailableEditor }
        try validateOriginalSource()
        let root = AXUIElementCreateApplication(identity.processID)
        AXUIElementSetMessagingTimeout(root, 0.05)
        guard let editor = element(root, kAXFocusedUIElementAttribute),
              let window = element(root, kAXFocusedWindowAttribute), CFEqual(window, originalWindow) else { throw Failure.changedSource }
        let validate: @MainActor () throws -> Void = {
            try validateOriginalSource()
            guard sessionIsActive(), !Task.isCancelled, AXIsProcessTrusted(),
                  DesktopApplicationTarget.matches(identity, application: app),
                  let currentWindow = element(root, kAXFocusedWindowAttribute), CFEqual(currentWindow, originalWindow),
                  let currentEditor = element(root, kAXFocusedUIElementAttribute), CFEqual(currentEditor, editor),
                  let editorWindow = element(editor, kAXWindowAttribute), CFEqual(editorWindow, originalWindow) else { throw Failure.changedSource }
            var pid: pid_t = 0
            guard AXUIElementGetPid(editor, &pid) == .success, pid == identity.processID else { throw Failure.changedSource }
            try validateSourceHierarchy(editor: editor, window: originalWindow, pid: identity.processID)
        }
        let validateInput: @MainActor () throws -> Void = {
            try validate()
            try validateForInput()
            guard app.isActive, let front = NSWorkspace.shared.frontmostApplication,
                  DesktopApplicationTarget.matches(identity, application: front) else { throw Failure.changedSource }
            try validate()
        }
        let access = Access(validateOriginalTarget: validate, validateInputTarget: validateInput, metadata: {
            AXUIElementSetMessagingTimeout(editor, 0.05)
            var writable = DarwinBoolean(false)
            let settable = AXUIElementIsAttributeSettable(editor, kAXSelectedTextAttribute as CFString, &writable) == .success && writable.boolValue
            return Metadata(role: attribute(editor, kAXRoleAttribute) as? String ?? "", subrole: attribute(editor, kAXSubroleAttribute) as? String ?? "",
                protected: NativeControlFocus.protectedValue([attribute(editor, "AXProtectedContent") as? Bool, attribute(editor, "AXContainsProtectedContent") as? Bool]),
                hidden: attribute(editor, "AXHidden") as? Bool, enabled: attribute(editor, kAXEnabledAttribute) as? Bool, selectionWritable: settable)
        }, qualifiedLabels: {
            // readCurrent has already admitted privacy/plain-editor metadata.
            try validate()
            let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
                .compactMap { attribute(editor, $0) as? String }.first { !$0.isEmpty }
            let identifier = (attribute(editor, kAXIdentifierAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .init(label: label, identifier: identifier)
        }, contents: {
            guard let value = attribute(editor, kAXValueAttribute) as? String, value.utf8.count <= maximumFieldBytes,
                  let range = selectedRange(editor), let selected = attribute(editor, kAXSelectedTextAttribute) as? String else { throw Failure.unavailableEditor }
            try validateSelection(value: value, range: range, selectedText: selected)
            let attributed = try attributedValue(editor: editor, value: value)
            return Contents(value: value, selection: range, selectedText: selected, attributedValue: attributed)
        }, writeSelectedText: { literal in
            AXUIElementSetMessagingTimeout(editor, 0.3)
            guard AXUIElementSetAttributeValue(editor, kAXSelectedTextAttribute as CFString, literal as CFString) == .success else { throw Failure.unavailableEditor }
        })
        return try NativeFocusedAXInsertion(access: access, sessionIsActive: sessionIsActive, admissionGate: admissionGate)
    }

    static func validateSourceHierarchy(editor: AXUIElement, window: AXUIElement, pid: pid_t) throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        var node: AXUIElement? = editor, visited: [AXUIElement] = []
        for _ in 0..<20 {
            guard ContinuousClock.now < deadline, let current = node, !visited.contains(where: { CFEqual($0, current) }) else { break }
            visited.append(current); AXUIElementSetMessagingTimeout(current, 0.05)
            var currentPID: pid_t = 0
            guard AXUIElementGetPid(current, &currentPID) == .success, currentPID == pid else { break }
            let role = attribute(current, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(current, kAXSubroleAttribute) as? String ?? ""
            let protected = NativeControlFocus.protectedValue([attribute(current, "AXProtectedContent") as? Bool,
                attribute(current, "AXContainsProtectedContent") as? Bool])
            let label = try hierarchyLabel(role: role, subrole: subrole, protected: protected,
                hidden: attribute(current, "AXHidden") as? Bool, readLabel: {
                    [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute]
                        .map { attribute(current, $0) as? String ?? "" }.joined(separator: " ").lowercased()
                })
            try QuickSelectionCapture.validateControl(role: role, subrole: subrole, label: label,
                isModal: attribute(current, kAXModalAttribute) as? Bool == true)
            if CFEqual(current, window) { return }
            node = element(current, kAXParentAttribute)
        }
        throw Failure.unavailableEditor
    }
    /// Privacy metadata must admit a hierarchy node before any of its labels are fetched.
    static func hierarchyLabel(role: String, subrole: String, protected: Bool?, hidden: Bool?,
                               readLabel: () throws -> String) throws -> String {
        guard !role.isEmpty, !["AXWebArea", "AXHTMLArea", "AXHTMLContent"].contains(role),
              !role.localizedCaseInsensitiveContains("secure"), !subrole.localizedCaseInsensitiveContains("secure"),
              !role.localizedCaseInsensitiveContains("password"), !subrole.localizedCaseInsensitiveContains("password"),
              protected != true, hidden != true else { throw Failure.unavailableEditor }
        let label = try readLabel()
        guard !["passcode", "one-time code", "security code", "credit card", "secret key", "recovery phrase", "address bar", "address and search"].contains(where: label.lowercased().contains) else { throw Failure.unavailableEditor }
        return label
    }
    private static func attributedValue(editor: AXUIElement, value: String) throws -> NSAttributedString {
        var range = CFRange(location: 0, length: value.utf16.count)
        guard let parameter = AXValueCreate(.cfRange, &range) else { throw Failure.unavailableEditor }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(editor, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &raw) == .success,
              let attributed = raw as? NSAttributedString, attributed.string.utf16.elementsEqual(value.utf16) else { throw Failure.unavailableEditor }
        return attributed
    }
    private static func selectedRange(_ editor: AXUIElement) -> NSRange? {
        guard let raw = attribute(editor, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &raw) == .success ? raw : nil
    }
    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(node, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }
    private static let protectedBundles: Set<String> = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
        "com.apple.systempreferences", "com.apple.passwords", "com.apple.keychainaccess", "com.1password.1password", "com.bitwarden.desktop"]
}

/// Freezes the actual native AX attributed text and exact, bounded representations of
/// its safe attributes. A style run is not treated as authored typography: glyph fallback
/// is allowed in the new span, while every unmodified character keeps its original attributes.
@MainActor struct NativeAttributedTextSnapshot {
    private struct Span: Equatable {
        let location: Int
        var length: Int
        let attributes: Data
    }
    fileprivate let actual: NSAttributedString
    private let utf16: [UInt16]
    private let spans: [Span]
    private static let maximumRuns = 256
    private static let maximumAttributeBytes = 131_072

    init(_ attributed: NSAttributedString, expectedValue: String) throws {
        guard expectedValue.utf8.count <= NativeFocusedAXInsertion.maximumFieldBytes,
              attributed.length == expectedValue.utf16.count,
              attributed.string.utf16.elementsEqual(expectedValue.utf16) else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
        let frozen = NSMutableAttributedString(string: attributed.string)
        utf16 = Array(expectedValue.utf16)
        var collected: [Span] = [], byteCount = 0, failure: (any Error)?
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, stop in
            do {
                guard collected.count < Self.maximumRuns, range.location >= 0, range.length > 0,
                      range.location <= attributed.length, range.length <= attributed.length - range.location else {
                    throw NativeFocusedAXInsertion.Failure.unavailableEditor
                }
                let bytes = try Self.attributeBytes(attributes)
                byteCount += bytes.count
                guard byteCount <= Self.maximumAttributeBytes else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
                collected.append(Span(location: range.location, length: range.length, attributes: bytes))
                // All values were admitted above. Copy the only container-valued
                // attribute so a caller's mutable font dictionary cannot change the snapshot.
                let copied = attributes.mapValues { value -> Any in
                    if let font = value as? [String: Any] { return NSDictionary(dictionary: font, copyItems: true) }
                    if let string = value as? String { return NSString(string: string) }
                    if let number = value as? NSNumber { return number.copy() }
                    return value // Admitted CGColor/CGColorSpace objects are immutable.
                }
                frozen.setAttributes(copied, range: range)
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        var covered = 0
        for span in collected {
            guard span.location == covered else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
            covered += span.length
        }
        guard covered == attributed.length else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
        spans = collected
        actual = NSAttributedString(attributedString: frozen)
    }

    func matches(_ other: Self) -> Bool {
        utf16 == other.utf16 && region(NSRange(location: 0, length: utf16.count)) == other.region(NSRange(location: 0, length: other.utf16.count))
    }

    func preservesUnchangedRegions(after: Self, replaced: NSRange, insertedUTF16Count: Int) -> Bool {
        guard replaced.location >= 0, replaced.length >= 0, replaced.location <= utf16.count,
              replaced.length <= utf16.count - replaced.location, insertedUTF16Count >= 0,
              after.utf16.count == utf16.count - replaced.length + insertedUTF16Count else { return false }
        let prefix = NSRange(location: 0, length: replaced.location)
        let suffix = NSRange(location: replaced.location + replaced.length, length: utf16.count - replaced.location - replaced.length)
        let shiftedSuffix = NSRange(location: replaced.location + insertedUTF16Count, length: suffix.length)
        return sameRegion(prefix, after: after, other: prefix) && sameRegion(suffix, after: after, other: shiftedSuffix)
    }

    private func sameRegion(_ range: NSRange, after: Self, other: NSRange) -> Bool {
        guard range.length == other.length, range.location >= 0, other.location >= 0,
              range.location <= utf16.count, range.length <= utf16.count - range.location,
              other.location <= after.utf16.count, other.length <= after.utf16.count - other.location else { return false }
        return utf16[range.location..<(range.location + range.length)].elementsEqual(after.utf16[other.location..<(other.location + other.length)])
            && region(range) == after.region(other)
    }

    private func region(_ range: NSRange) -> [Span] {
        guard range.length > 0 else { return [] }
        let end = range.location + range.length
        var result: [Span] = []
        for span in spans {
            let start = max(span.location, range.location), stop = min(span.location + span.length, end)
            guard start < stop else { continue }
            if let last = result.last, last.location + last.length == start - range.location, last.attributes == span.attributes {
                result[result.count - 1].length += stop - start
            } else { result.append(Span(location: start - range.location, length: stop - start, attributes: span.attributes)) }
        }
        return result
    }

    private static func attributeBytes(_ attributes: [NSAttributedString.Key: Any]) throws -> Data {
        guard attributes.count <= 24 else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
        var record: [String: [String: String]] = [:]
        let colors: Set<String> = ["AXForegroundColor", "AXBackgroundColor", "AXUnderlineColor", "AXStrikethroughColor"]
        let numbers: Set<String> = ["AXUnderline", "AXSuperscript", "AXStrikethrough", "AXShadow", "AXAutocorrected", "AXMisspelled",
            "AXMarkedMisspelled", "AXATextAlignmentValue", "AXFontBold", "AXFontItalic"]
        for (key, value) in attributes {
            if key.rawValue == "AXFont" {
                guard let font = value as? [String: Any], font.count <= 6,
                      let name = font["AXFontName"] as? String, !name.isEmpty,
                      let size = font["AXFontSize"] as? NSNumber, size.doubleValue.isFinite,
                      CFGetTypeID(size) != CFBooleanGetTypeID(),
                      size.doubleValue > 0, size.doubleValue <= 4_096 else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
                var fields = ["type": "font"]
                for (fontKey, value) in font {
                    if ["AXFontName", "AXFontFamily", "AXVisibleName"].contains(fontKey), let string = value as? String {
                        fields[fontKey] = try exactString(string, maximumBytes: 512)
                    } else if ["AXFontSize", "AXFontBold", "AXFontItalic"].contains(fontKey), let number = value as? NSNumber {
                        fields[fontKey] = try exactNumber(number)
                    } else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
                }
                record[key.rawValue] = fields
            } else if colors.contains(key.rawValue) {
                let raw = value as AnyObject
                guard CFGetTypeID(raw) == CGColor.typeID else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
                let color = unsafeDowncast(raw, to: CGColor.self)
                guard let space = color.colorSpace, [.rgb, .monochrome].contains(space.model),
                      let components = color.components, components.count <= 5,
                      components.allSatisfy({ $0.isFinite }) else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
                let icc = space.copyICCData() as Data?
                guard (icc?.count ?? 0) <= 32_768, space.name != nil || icc != nil else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
                var fields = ["type": "color", "spaceModel": String(space.model.rawValue),
                    "spaceComponents": String(space.numberOfComponents), "icc": icc?.base64EncodedString() ?? "<unavailable>",
                    "spaceName": try space.name.map { try exactString($0 as String, maximumBytes: 512) } ?? "<unavailable>"]
                for (index, component) in components.enumerated() { fields["component\(index)"] = String(Double(component).bitPattern, radix: 16) }
                record[key.rawValue] = fields
            } else if numbers.contains(key.rawValue), let number = value as? NSNumber {
                record[key.rawValue] = ["type": "number", "value": try exactNumber(number)]
            } else if ["AXLanguage", "AXNaturalLanguage"].contains(key.rawValue), let string = value as? String {
                record[key.rawValue] = ["type": "string", "utf16": try exactString(string, maximumBytes: 128)]
            } else {
                // Includes AX/NS links, attachments, custom annotations, embedded objects
                // and every attribute whose safe exact representation is unqualified.
                throw NativeFocusedAXInsertion.Failure.unavailableEditor
            }
        }
        return try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    private static func exactString(_ string: String, maximumBytes: Int) throws -> String {
        guard string.utf8.count <= maximumBytes, !string.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) else {
            throw NativeFocusedAXInsertion.Failure.unavailableEditor
        }
        return Data(string.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }).base64EncodedString()
    }
    private static func exactNumber(_ number: NSNumber) throws -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool:" + (number.boolValue ? "1" : "0") }
        let encoding = String(cString: number.objCType)
        switch encoding {
        case "c", "s", "i", "l", "q": return encoding + ":" + String(number.int64Value)
        case "C", "S", "I", "L", "Q": return encoding + ":" + String(number.uint64Value)
        case "f":
            guard number.floatValue.isFinite else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
            return encoding + ":" + String(number.floatValue.bitPattern, radix: 16)
        case "d":
            guard number.doubleValue.isFinite else { throw NativeFocusedAXInsertion.Failure.unavailableEditor }
            return encoding + ":" + String(number.doubleValue.bitPattern, radix: 16)
        default: throw NativeFocusedAXInsertion.Failure.unavailableEditor
        }
    }
}
