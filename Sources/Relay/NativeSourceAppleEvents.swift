import AppKit
import CoreServices
import Foundation

/// The only events this adapter sends are `core/getd` reads for the fixed selection
/// and item properties in the installed Notes and Mail scripting dictionaries.
nonisolated enum NativeSourceAppleEvents {
    static let maximumSelection = 8
    private static let maximumItemBytes = 8_192
    private static let maximumReplyBytes = 1_048_576
    private static let requiredEventTimeout: TimeInterval = 2
    private static let optionalDateTimeout: TimeInterval = 0.25

    enum Property: Equatable {
        case selection, title, sender, body, protected, sentAt, receivedAt

        var isOptionalDate: Bool { self == .sentAt || self == .receivedAt }

        func code(for kind: NativePersonalSourceKind) -> AEKeyword {
            switch self {
            case .selection: fourCC(kind == .notes ? "seln" : "slct")
            case .title: fourCC(kind == .notes ? "pnam" : "subj")
            case .sender: fourCC("sndr")
            case .body: fourCC(kind == .notes ? "text" : "ctnt")
            case .protected: fourCC("pwpr")
            case .sentAt: fourCC("drcv")
            case .receivedAt: fourCC("rdrc")
            }
        }
    }

    enum Failure: LocalizedError {
        case appUnavailable, permissionNeeded, permissionDenied, noSelection, selectionTooLarge
        case malformedSelection, selectionChanged, unavailableProperty, expired, eventFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .appUnavailable: "Open the Apple app and select the items you want to capture first."
            case .permissionNeeded: "macOS Automation permission is required. Use the explicit Capture button to request it."
            case .permissionDenied: "macOS Automation access is denied. Check Relay’s access in System Settings → Privacy & Security → Automation."
            case .noSelection: "Select one or more items in the Apple app, then capture the selection."
            case .selectionTooLarge: "Select up to \(maximumSelection) items at a time. No item content was read."
            case .malformedSelection: "The Apple app did not return an identifiable selection. No source snapshot was saved."
            case .selectionChanged: "The selected item identities changed while Relay was reading them. The update was discarded."
            case .unavailableProperty: "An item property was unavailable or exceeded the safe response size."
            case .expired: "The Apple app did not finish responding within the capture limit. The previous snapshot was kept."
            case .eventFailed(let status): "The Apple app could not read the selection (Automation error \(status)). The previous snapshot was kept."
            }
        }
    }

    @MainActor static func captureSelected(_ kind: NativePersonalSourceKind, requestPermission: Bool) async throws -> NativePersonalSourceBatch {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleIdentifier)
        guard apps.count == 1, let app = apps.first, !app.isTerminated,
              app.bundleURL?.standardizedFileURL.path == kind.bundlePath, let launchedAt = app.launchDate else {
            throw Failure.appUnavailable
        }
        return try await capture(kind, identity: .init(pid: app.processIdentifier, launchedAt: launchedAt),
                                 requestPermission: requestPermission)
    }

    @MainActor static func refreshCaptured(_ scope: NativePersonalSourceScope) async throws -> NativePersonalSourceBatch {
        try assertApplication(scope.kind, identity: scope.application)
        return try await capture(scope.kind, identity: scope.application, requestPermission: false, scope: scope)
    }

    @concurrent private static func capture(_ kind: NativePersonalSourceKind, identity: NativePersonalSourceScope.Application,
                                            requestPermission: Bool, scope: NativePersonalSourceScope? = nil) async throws -> NativePersonalSourceBatch {
        try Task.checkCancellation()
        try assertApplication(kind, identity: identity)
        let address = NSAppleEventDescriptor(processIdentifier: identity.pid)
        guard let descriptor = address.aeDesc else { throw Failure.appUnavailable }
        let status = AEDeterminePermissionToAutomateTarget(descriptor, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), requestPermission)
        try Task.checkCancellation()
        guard status == noErr else { throw failure(for: status) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        let read: (Property, NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor = { property, item in
            try Task.checkCancellation()
            try assertApplication(kind, identity: identity)
            let time = clock.now.duration(to: deadline).components
            let seconds = Double(time.seconds) + Double(time.attoseconds) / 1e18
            guard seconds > 0 else { throw Failure.expired }
            // A missing date should not take the remaining budget from the final selection check.
            if property.isOptionalDate, seconds < requiredEventTimeout + optionalDateTimeout { throw Failure.unavailableProperty }
            let subject = try propertySpecifier(property.code(for: kind), container: item)
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                targetDescriptor: address, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(subject, forKeyword: AEKeyword(keyDirectObject))
            let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract, .dontRecord,
                .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
            let timeout = min(seconds, property.isOptionalDate ? optionalDateTimeout : requiredEventTimeout)
            let reply: NSAppleEventDescriptor
            do { reply = try event.sendEvent(options: options, timeout: timeout) }
            catch { throw failure(for: OSStatus((error as NSError).code), property: property) }
            try Task.checkCancellation()
            if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), number.int32Value != 0 {
                throw failure(for: number.int32Value, property: property)
            }
            guard let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)), result.data.count <= maximumReplyBytes else {
                throw Failure.unavailableProperty
            }
            return result
        }
        if let scope { return try readCaptured(scope, read: read) }
        return try readSelected(kind, application: identity, read: read)
    }

    private static func assertApplication(_ kind: NativePersonalSourceKind, identity: NativePersonalSourceScope.Application) throws {
        guard let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated,
              app.bundleIdentifier == kind.bundleIdentifier, app.launchDate == identity.launchedAt,
              app.bundleURL?.standardizedFileURL.path == kind.bundlePath else { throw Failure.appUnavailable }
    }

    private static func failure(for status: OSStatus, property: Property? = nil) -> Failure {
        switch status {
        case OSStatus(errAEEventWouldRequireUserConsent): .permissionNeeded
        case OSStatus(errAEEventNotPermitted): .permissionDenied
        case OSStatus(procNotFound): .appUnavailable
        case OSStatus(errAETimeout): property?.isOptionalDate == true ? .unavailableProperty : .expired
        case OSStatus(errAENoSuchObject), OSStatus(errAECoercionFail): .unavailableProperty
        default: .eventFailed(status)
        }
    }

    private static func propertySpecifier(_ property: AEKeyword, container: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: DescType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(typeCode: property), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        guard let specifier = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw Failure.malformedSelection }
        return specifier
    }

    /// Fixtures replace the Apple-event transport. Production and tests run the same
    /// selection validation, field allowlist, protected-note check and consistency read.
    static func readSelected(_ kind: NativePersonalSourceKind, application: NativePersonalSourceScope.Application? = nil,
                             read: (Property, NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor) throws -> NativePersonalSourceBatch {
        let references = try selectedReferences(read(.selection, nil), kind: kind)
        var items: [NativePersonalSourceItem] = []
        var retainedReferences: [Data] = []
        var skipped = 0
        for reference in references {
            try Task.checkCancellation()
            do {
                if kind == .notes {
                    let flag = try read(.protected, reference)
                    let unlocked = flag.descriptorType == DescType(typeFalse) ||
                        (flag.descriptorType == DescType(typeBoolean) && flag.data.count == 1 && !flag.booleanValue)
                    guard unlocked else { skipped += 1; continue }
                }
                let title = boundedLabel(try read(.title, reference).stringValue, maximum: 384) ?? "Untitled item"
                let sender = kind == .mail ? boundedLabel(try read(.sender, reference).stringValue, maximum: 384) : nil
                let raw = try read(.body, reference)
                guard raw.data.count <= maximumReplyBytes,
                      let text = plainText(raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { skipped += 1; continue }
                let bounded = NativePersonalSources.bounded(text, maximumBytes: maximumItemBytes)
                let sentAt = kind == .mail ? try optionalDate(read(.sentAt, reference)) : nil
                let receivedAt = kind == .mail ? try optionalDate(read(.receivedAt, reference)) : nil
                items.append(NativePersonalSourceItem(id: NativePersonalSourceScope.itemID(for: reference.data), title: title, sender: sender,
                    text: bounded, textLimited: bounded.utf8.count < text.utf8.count, sentAt: sentAt, receivedAt: receivedAt))
                retainedReferences.append(reference.data)
            } catch Failure.unavailableProperty {
                skipped += 1
            }
        }
        let current = try selectedReferences(read(.selection, nil), kind: kind)
        guard current.map(\.data) == references.map(\.data) else { throw Failure.selectionChanged }
        let scope = application.map { NativePersonalSourceScope(kind: kind, application: $0, references: retainedReferences) }
        return NativePersonalSourceBatch(items: items, skipped: skipped, scope: scope)
    }

    /// The captured references replace only the local selection lookup. No selection
    /// event is sent to the app, so selecting another item cannot expand a refresh.
    static func readCaptured(_ scope: NativePersonalSourceScope,
                             read: (Property, NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor) throws -> NativePersonalSourceBatch {
        guard !scope.references.isEmpty, scope.references.count <= maximumSelection,
              Set(scope.references).count == scope.references.count else { throw Failure.malformedSelection }
        let list = NSAppleEventDescriptor.list()
        for (offset, data) in scope.references.enumerated() {
            guard !data.isEmpty, data.count <= 4_096,
                  let reference = NSAppleEventDescriptor(descriptorType: DescType(typeObjectSpecifier), data: data) else {
                throw Failure.malformedSelection
            }
            list.insert(reference, at: offset + 1)
        }
        return try readSelected(scope.kind, application: scope.application) { property, reference in
            property == .selection ? list : try read(property, reference)
        }
    }

    private static func optionalDate(_ read: @autoclosure () throws -> NSAppleEventDescriptor) throws -> Date? {
        do {
            let reply = try read()
            guard reply.descriptorType == DescType(typeLongDateTime), let date = reply.dateValue,
                  (Date.distantPast...Date.distantFuture).contains(date) else { return nil }
            return date
        } catch Failure.unavailableProperty {
            return nil
        }
    }

    private static func selectedReferences(_ reply: NSAppleEventDescriptor, kind: NativePersonalSourceKind) throws -> [NSAppleEventDescriptor] {
        let references: [NSAppleEventDescriptor]
        switch reply.descriptorType {
        case DescType(typeNull): throw Failure.noSelection
        case DescType(typeAEList):
            let count = reply.numberOfItems
            guard count > 0 else { throw Failure.noSelection }
            guard count <= maximumSelection else { throw Failure.selectionTooLarge }
            references = (1...count).compactMap { reply.atIndex($0) }
            guard references.count == count else { throw Failure.malformedSelection }
        case DescType(typeObjectSpecifier): references = [reply]
        default: throw Failure.malformedSelection
        }
        let expected = fourCC(kind == .notes ? "note" : "mssg")
        let keyTypes: Set<DescType> = [DescType(typeUnicodeText), DescType(typeUTF8Text), DescType(typeChar),
                                      DescType(typeSInt32), DescType(typeSInt64)]
        guard references.allSatisfy({ reference in
            guard reference.descriptorType == DescType(typeObjectSpecifier),
                  reference.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == expected,
                  reference.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formUniqueID),
                  let key = reference.forKeyword(AEKeyword(keyAEKeyData)), !key.data.isEmpty,
                  keyTypes.contains(key.descriptorType) else { return false }
            return !reference.data.isEmpty && reference.data.count <= 4_096
        }),
            Set(references.map(\.data)).count == references.count else { throw Failure.malformedSelection }
        return references
    }

    private static func plainText(_ descriptor: NSAppleEventDescriptor) -> String? {
        if let text = descriptor.stringValue { return text }
        guard descriptor.descriptorType == DescType(typeStyledText) else { return nil }
        return descriptor.forKeyword(AEKeyword(keyAEText))?.stringValue
    }

    private static func boundedLabel(_ label: String?, maximum: Int) -> String? {
        guard let label else { return nil }
        let normalized = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : NativePersonalSources.bounded(normalized, maximumBytes: maximum)
    }

    static func fourCC(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
