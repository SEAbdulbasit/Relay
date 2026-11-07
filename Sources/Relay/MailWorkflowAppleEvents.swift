import AppKit
import CoreServices
import Foundation

/// The installed Mail.sdef defines outgoing message bcke, recipient classes
/// trcp/crcp/brcp, and the emsg/send command. No AppleScript source is evaluated.
nonisolated enum MailWorkflowAppleEvents {
    typealias Exchange = (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor
    static let bundleID = "com.apple.mail"
    static let bundlePath = "/System/Applications/Mail.app"

    static let live = MailWorkflowTransport(
        create: { message in
            let identity = try await runningIdentity()
            return try await createLive(message, identity: identity)
        },
        read: { reference in try await readLive(reference) },
        send: { snapshot, expiresAt in try await sendLive(snapshot, expiresAt: expiresAt) }
    )

    /// Only a user-initiated Settings action may call this. It asks macOS for
    /// Automation access without reading a message or dispatching a Mail command.
    @MainActor static func requestAccess() async throws {
        let identity = try runningIdentity()
        try await requestPermission(identity)
    }

    @concurrent private static func requestPermission(_ identity: MailWorkflowDraftReference) async throws {
        try Task.checkCancellation()
        try assertApplication(identity)
        let address = NSAppleEventDescriptor(processIdentifier: identity.processID)
        guard let descriptor = address.aeDesc else { throw MailWorkflowFailure.appUnavailable }
        let status = AEDeterminePermissionToAutomateTarget(descriptor, AEEventClass(kAECoreSuite), AEEventID(kAECreateElement), true)
        if status == OSStatus(errAEEventWouldRequireUserConsent) { throw MailWorkflowFailure.permissionNeeded }
        if status == OSStatus(errAEEventNotPermitted) { throw MailWorkflowFailure.permissionDenied }
        guard status == noErr else { throw MailWorkflowFailure.eventFailed(status) }
        try assertApplication(identity)
    }

    @MainActor private static func runningIdentity() throws -> MailWorkflowDraftReference {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first, app.bundleURL?.standardizedFileURL.path == bundlePath,
              let launchedAt = app.launchDate else { throw MailWorkflowFailure.appUnavailable }
        return MailWorkflowDraftReference(processID: app.processIdentifier, launchedAt: launchedAt, messageID: 0)
    }

    @concurrent private static func createLive(_ message: MailWorkflowMessage, identity: MailWorkflowDraftReference) async throws -> MailWorkflowSnapshot {
        try create(message, identity: identity, exchange: liveExchange(identity))
    }

    @concurrent private static func readLive(_ reference: MailWorkflowDraftReference) async throws -> MailWorkflowSnapshot {
        try read(reference, exchange: liveExchange(reference))
    }

    @concurrent private static func sendLive(_ snapshot: MailWorkflowSnapshot, expiresAt: Date) async throws -> Bool {
        try send(snapshot, expiresAt: expiresAt, exchange: liveExchange(snapshot.reference, sendDeadline: expiresAt))
    }

    private static func liveExchange(_ identity: MailWorkflowDraftReference, sendDeadline: Date? = nil) -> Exchange {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        return { event in
            try Task.checkCancellation()
            try assertApplication(identity)
            let address = NSAppleEventDescriptor(processIdentifier: identity.processID)
            guard let descriptor = address.aeDesc else { throw MailWorkflowFailure.appUnavailable }
            let permission = AEDeterminePermissionToAutomateTarget(descriptor, event.eventClass, event.eventID, false)
            if permission == OSStatus(errAEEventWouldRequireUserConsent) { throw MailWorkflowFailure.permissionNeeded }
            if permission == OSStatus(errAEEventNotPermitted) { throw MailWorkflowFailure.permissionDenied }
            guard permission == noErr else { throw MailWorkflowFailure.eventFailed(permission) }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else { throw MailWorkflowFailure.eventFailed(OSStatus(errAETimeout)) }
            let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract, .dontRecord,
                .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
            if event.eventClass == cc("emsg"), event.eventID == cc("send") {
                guard let sendDeadline else { throw MailWorkflowFailure.reviewExpired }
                try assertSendLease(sendDeadline, now: Date())
            }
            let reply: NSAppleEventDescriptor
            do { reply = try event.sendEvent(options: options, timeout: min(seconds, 2)) }
            catch { throw MailWorkflowFailure.eventFailed(Int32((error as NSError).code)) }
            if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                throw MailWorkflowFailure.eventFailed(error.int32Value)
            }
            let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
            guard result.data.count <= 262_144 else { throw MailWorkflowFailure.malformedReply }
            return result
        }
    }

    private static func assertApplication(_ identity: MailWorkflowDraftReference) throws {
        guard let app = NSRunningApplication(processIdentifier: identity.processID), !app.isTerminated,
              app.bundleIdentifier == bundleID, app.launchDate == identity.launchedAt,
              app.bundleURL?.standardizedFileURL.path == bundlePath else { throw MailWorkflowFailure.staleDraft }
    }

    static func create(_ message: MailWorkflowMessage, identity: MailWorkflowDraftReference, exchange: Exchange) throws -> MailWorkflowSnapshot {
        try message.validate()
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(.init(string: message.sender), forKeyword: cc("sndr"))
        properties.setDescriptor(.init(string: message.subject), forKeyword: cc("subj"))
        properties.setDescriptor(.init(string: message.body), forKeyword: cc("ctnt"))
        properties.setDescriptor(.init(boolean: true), forKeyword: cc("pvis"))
        properties.setDescriptor(.init(typeCode: cc("msng")), forKeyword: cc("tnrg"))
        var created: MailWorkflowDraftReference?
        do {
            let result = try exchange(makeEvent(classCode: cc("bcke"), properties: properties, container: nil, identity: identity))
            guard result.descriptorType == DescType(typeObjectSpecifier),
                  result.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == cc("bcke") else { throw MailWorkflowFailure.malformedReply }
            let id = try integer(exchange(getEvent(try property(cc("ID  "), of: result), identity: identity)))
            guard id > 0 else { throw MailWorkflowFailure.malformedReply }
            let reference = MailWorkflowDraftReference(processID: identity.processID, launchedAt: identity.launchedAt, messageID: id)
            created = reference
            let messageObject = try object(reference)
            for (kind, recipients) in [(cc("trcp"), message.to), (cc("crcp"), message.cc), (cc("brcp"), message.bcc)] {
                for recipient in recipients {
                    let properties = NSAppleEventDescriptor.record()
                    properties.setDescriptor(.init(string: recipient.address), forKeyword: cc("radd"))
                    properties.setDescriptor(.init(string: recipient.name), forKeyword: cc("pnam"))
                    let collection = try specifier(kind, form: OSType(formAbsolutePosition), key: .init(enumCode: OSType(kAEAll)), container: messageObject)
                    let location = NSAppleEventDescriptor.record()
                    location.setDescriptor(collection, forKeyword: AEKeyword(keyAEObject))
                    location.setDescriptor(.init(enumCode: OSType(kAEEnd)), forKeyword: AEKeyword(keyAEPosition))
                    guard let insertion = location.coerce(toDescriptorType: cc("insl")) else { throw MailWorkflowFailure.malformedReply }
                    _ = try exchange(makeEvent(classCode: kind, properties: properties, container: insertion, identity: reference))
                }
            }
            let save = event(cc("core"), cc("save"), identity: reference)
            save.setParam(messageObject, forKeyword: AEKeyword(keyDirectObject))
            _ = try exchange(save)
            return try read(reference, exchange: exchange)
        } catch let failure as MailWorkflowFailure {
            if created == nil {
                switch failure {
                case .permissionNeeded, .permissionDenied, .appUnavailable, .staleDraft: throw failure
                default: break
                }
            }
            throw MailWorkflowFailure.creationUncertain(created)
        } catch {
            throw MailWorkflowFailure.creationUncertain(created)
        }
    }

    static func read(_ reference: MailWorkflowDraftReference, exchange: Exchange) throws -> MailWorkflowSnapshot {
        guard reference.messageID > 0 else { throw MailWorkflowFailure.staleDraft }
        let first = try readOnce(reference, exchange: exchange)
        let second = try readOnce(reference, exchange: exchange)
        guard first.fingerprint == second.fingerprint else { throw MailWorkflowFailure.messageChanged }
        return second
    }

    private static func readOnce(_ reference: MailWorkflowDraftReference, exchange: Exchange) throws -> MailWorkflowSnapshot {
        let message = try object(reference)
        func readText(_ code: AEKeyword, of container: NSAppleEventDescriptor) throws -> String {
            let result = try exchange(getEvent(try property(code, of: container), identity: reference))
            guard [DescType(typeUnicodeText), DescType(typeUTF8Text), DescType(typeChar)].contains(result.descriptorType),
                  let text = result.stringValue, text.utf8.count <= 65_536 else { throw MailWorkflowFailure.malformedReply }
            return text
        }
        let actualID = try integer(exchange(getEvent(try property(cc("ID  "), of: message), identity: reference)))
        guard actualID == reference.messageID else { throw MailWorkflowFailure.staleDraft }
        let sender = try readText(cc("sndr"), of: message)
        let subject = try readText(cc("subj"), of: message)
        let body = try readText(cc("ctnt"), of: message)
        var groups: [[MailWorkflowRecipient]] = []
        var total = 0
        for kind in [cc("trcp"), cc("crcp"), cc("brcp")] {
            let count = Int(try countElements(kind, of: message, identity: reference, exchange: exchange))
            total += count
            guard count >= 0, total <= 30 else { throw MailWorkflowFailure.malformedReply }
            var recipients: [MailWorkflowRecipient] = []
            for index in 0..<count {
                let recipient = try specifier(kind, form: OSType(formAbsolutePosition), key: .init(int32: Int32(index + 1)), container: message)
                recipients.append(MailWorkflowRecipient(address: try readText(cc("radd"), of: recipient), name: try readText(cc("pnam"), of: recipient)))
            }
            groups.append(recipients)
        }
        let content = try property(cc("ctnt"), of: message)
        let attachments = Int(try countElements(cc("atts"), of: content, identity: reference, exchange: exchange))
        guard attachments >= 0, attachments <= 100 else { throw MailWorkflowFailure.malformedReply }
        let envelope = MailWorkflowMessage(sender: sender, to: groups[0], cc: groups[1], bcc: groups[2], subject: subject, body: body)
        try envelope.validate()
        return MailWorkflowSnapshot(reference: reference, message: envelope, attachmentCount: attachments)
    }

    static func send(_ expected: MailWorkflowSnapshot, expiresAt: Date, now: () -> Date = Date.init, exchange: Exchange) throws -> Bool {
        try expected.validateForSending()
        try assertSendLease(expiresAt, now: now())
        try assertNoAutomaticCopies(expected.reference, exchange: exchange)
        let current = try read(expected.reference, exchange: exchange)
        guard current.fingerprint == expected.fingerprint else { throw MailWorkflowFailure.messageChanged }
        try Task.checkCancellation()
        try assertNoAutomaticCopies(expected.reference, exchange: exchange)
        try assertSendLease(expiresAt, now: now())
        let command = event(cc("emsg"), cc("send"), identity: expected.reference)
        command.setParam(try object(expected.reference), forKeyword: AEKeyword(keyDirectObject))
        let result = try exchange(command)
        guard [DescType(typeBoolean), DescType(typeTrue), DescType(typeFalse)].contains(result.descriptorType) else { throw MailWorkflowFailure.malformedReply }
        return result.booleanValue
    }

    private static func assertNoAutomaticCopies(_ reference: MailWorkflowDraftReference, exchange: Exchange) throws {
        for setting in [cc("abcm"), cc("accm")] {
            let value = try exchange(getEvent(try property(setting, of: .null()), identity: reference))
            guard [DescType(typeBoolean), DescType(typeTrue), DescType(typeFalse)].contains(value.descriptorType) else { throw MailWorkflowFailure.malformedReply }
            guard !value.booleanValue else { throw MailWorkflowFailure.automaticRecipients }
        }
    }

    private static func assertSendLease(_ expiresAt: Date, now: Date) throws {
        guard (0..<120).contains(now.timeIntervalSince(expiresAt.addingTimeInterval(-120))) else { throw MailWorkflowFailure.reviewExpired }
    }

    private static func countElements(_ kind: AEKeyword, of container: NSAppleEventDescriptor, identity: MailWorkflowDraftReference, exchange: Exchange) throws -> Int32 {
        let command = event(cc("core"), cc("cnte"), identity: identity)
        command.setParam(try specifier(kind, form: OSType(formAbsolutePosition), key: .init(enumCode: OSType(kAEAll)), container: container), forKeyword: AEKeyword(keyDirectObject))
        return try integer(exchange(command))
    }

    private static func integer(_ value: NSAppleEventDescriptor) throws -> Int32 {
        guard [DescType(typeSInt16), DescType(typeSInt32), DescType(typeSInt64)].contains(value.descriptorType),
              let bounded = value.coerce(toDescriptorType: DescType(typeSInt32)) else { throw MailWorkflowFailure.malformedReply }
        return bounded.int32Value
    }

    private static func object(_ reference: MailWorkflowDraftReference) throws -> NSAppleEventDescriptor {
        try specifier(cc("bcke"), form: OSType(formUniqueID), key: .init(int32: reference.messageID), container: .null())
    }

    private static func property(_ code: AEKeyword, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(DescType(typeProperty), form: OSType(formPropertyID), key: .init(typeCode: code), container: container)
    }

    private static func specifier(_ kind: DescType, form: OSType, key: NSAppleEventDescriptor, container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: kind), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let value = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw MailWorkflowFailure.malformedReply }
        return value
    }

    private static func makeEvent(classCode: DescType, properties: NSAppleEventDescriptor, container: NSAppleEventDescriptor?, identity: MailWorkflowDraftReference) -> NSAppleEventDescriptor {
        let command = event(cc("core"), cc("crel"), identity: identity)
        command.setParam(.init(typeCode: classCode), forKeyword: AEKeyword(keyAEObjectClass))
        command.setParam(properties, forKeyword: AEKeyword(keyAEPropData))
        if let container { command.setParam(container, forKeyword: AEKeyword(keyAEInsertHere)) }
        return command
    }

    private static func getEvent(_ object: NSAppleEventDescriptor, identity: MailWorkflowDraftReference) -> NSAppleEventDescriptor {
        let command = event(cc("core"), cc("getd"), identity: identity)
        command.setParam(object, forKeyword: AEKeyword(keyDirectObject))
        return command
    }

    private static func event(_ eventClass: AEEventClass, _ id: AEEventID, identity: MailWorkflowDraftReference) -> NSAppleEventDescriptor {
        .init(eventClass: eventClass, eventID: id, targetDescriptor: .init(processIdentifier: identity.processID),
              returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    static func cc(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
