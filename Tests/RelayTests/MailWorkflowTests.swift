import CoreServices
import Foundation
import Testing
@testable import Relay

private actor MailWorkflowFixture {
    var snapshot: MailWorkflowSnapshot?
    var creates = 0
    var sends = 0
    var failSend = false
    var reply = true
    var readGate: CheckedContinuation<Void, Never>?
    var holdRead = false
    var readStarted = false
    var createMismatch = false
    var holdSend = false
    var sendStarted = false
    var sendGate: CheckedContinuation<Bool, Never>?

    nonisolated var transport: MailWorkflowTransport {
        MailWorkflowTransport(create: { try await self.create($0) }, read: { try await self.read($0) }, send: { snapshot, _ in try await self.send(snapshot) })
    }

    func create(_ message: MailWorkflowMessage) -> MailWorkflowSnapshot {
        creates += 1
        let contents = createMismatch ? MailWorkflowMessage(sender: message.sender, to: message.to, cc: message.cc, bcc: message.bcc,
                                                           subject: message.subject, body: "Changed by Mail") : message
        let result = MailWorkflowSnapshot(reference: .init(processID: 42, launchedAt: Date(timeIntervalSince1970: 1), messageID: 7), message: contents, attachmentCount: 0)
        snapshot = result
        return result
    }

    func read(_ reference: MailWorkflowDraftReference) async throws -> MailWorkflowSnapshot {
        readStarted = true
        if holdRead { await withCheckedContinuation { readGate = $0 } }
        guard let snapshot, snapshot.reference == reference else { throw MailWorkflowFailure.staleDraft }
        return snapshot
    }

    func send(_ snapshot: MailWorkflowSnapshot) async throws -> Bool {
        sends += 1
        sendStarted = true
        if holdSend { return await withCheckedContinuation { sendGate = $0 } }
        if failSend { throw MailWorkflowFailure.eventFailed(Int32(errAETimeout)) }
        return reply
    }

    func alterBody(_ body: String, attachments: Int = 0) {
        guard let current = snapshot else { return }
        let message = MailWorkflowMessage(sender: current.message.sender, to: current.message.to, cc: current.message.cc, bcc: current.message.bcc,
                                          subject: current.message.subject, body: body)
        snapshot = MailWorkflowSnapshot(reference: current.reference, message: message, attachmentCount: attachments)
    }

    func setFailSend() { failSend = true }
    func mismatchDraftCreation() { createMismatch = true }
    func pauseRead() { holdRead = true; readStarted = false }
    func releaseRead() { holdRead = false; readGate?.resume(); readGate = nil }
    func pauseSend() { holdSend = true; sendStarted = false }
    func releaseSend() { holdSend = false; sendGate?.resume(returning: true); sendGate = nil }
}

@MainActor
private final class MailWorkflowTestClock {
    var date = Date(timeIntervalSince1970: 1000)
}

@MainActor
struct MailWorkflowTests {
    private func message() -> MailWorkflowMessage {
        .init(sender: "Relay Fixture <sender@example.invalid>", to: [.init(address: "to@example.invalid", name: "To Fixture")],
              cc: [.init(address: "copy@example.invalid")], bcc: [.init(address: "blind@example.invalid")],
              subject: "Synthetic Mail review", body: "Café 🌍\nمرحبا\nA second line.")
    }

    @Test func exactDisplayedReviewIsRequiredAndOneUse() async throws {
        let fake = MailWorkflowFixture()
        let workflow = MailWorkflow(transport: fake.transport)
        let requested = message()
        let draft = try await workflow.createDraft(requested, requestID: "request-one")
        let repeated = try await workflow.createDraft(requested, requestID: "request-one")
        #expect(draft.id == repeated.id)
        #expect(await fake.creates == 1)
        let reviewID = try await workflow.prepareSendReview(draftID: draft.id)
        #expect(throws: (any Error).self) { try workflow.approve(reviewID, displayedFingerprint: draft.snapshot.fingerprint) }
        let review = try workflow.reviewForDisplay(reviewID)
        #expect(review.text.contains("to@example.invalid"))
        #expect(review.text.contains("copy@example.invalid"))
        #expect(review.text.contains("blind@example.invalid"))
        #expect(review.text.contains(requested.subject))
        #expect(review.text.contains(requested.body))
        #expect(throws: (any Error).self) { try workflow.approve(reviewID, displayedFingerprint: "changed") }
        try workflow.approve(reviewID, displayedFingerprint: review.fingerprint)
        let receipt = try await workflow.sendApproved(reviewID)
        #expect(receipt.status == .acceptedByMail)
        #expect(await fake.sends == 1)
        await #expect(throws: (any Error).self) { try await workflow.sendApproved(reviewID) }
        await #expect(throws: (any Error).self) { try await workflow.prepareSendReview(draftID: draft.id) }
        #expect(workflow.receipt(for: reviewID)?.status == .acceptedByMail)
    }

    @Test func changedContentsAndAttachmentsPreventAnySend() async throws {
        let fake = MailWorkflowFixture()
        let workflow = MailWorkflow(transport: fake.transport)
        let draft = try await workflow.createDraft(message(), requestID: "change")
        let id = try await workflow.prepareSendReview(draftID: draft.id)
        let review = try workflow.reviewForDisplay(id)
        try workflow.approve(id, displayedFingerprint: review.fingerprint)
        await fake.alterBody("Changed after approval")
        await #expect(throws: (any Error).self) { try await workflow.sendApproved(id) }
        #expect(await fake.sends == 0)
        await fake.alterBody("New attached version", attachments: 1)
        await #expect(throws: (any Error).self) { try await workflow.prepareSendReview(draftID: draft.id) }
        #expect(await fake.sends == 0)
    }

    @Test func mismatchedDraftReadbackCannotClaimVerifiedOrRepeatCreation() async throws {
        let fake = MailWorkflowFixture()
        await fake.mismatchDraftCreation()
        let workflow = MailWorkflow(transport: fake.transport)
        await #expect(throws: (any Error).self) { try await workflow.createDraft(message(), requestID: "mismatch") }
        await #expect(throws: (any Error).self) { try await workflow.createDraft(message(), requestID: "mismatch") }
        #expect(await fake.creates == 1)
        #expect(await fake.sends == 0)
    }

    @Test func timeoutAfterDispatchBlocksReplayAndRetainsUncertainty() async throws {
        let fake = MailWorkflowFixture()
        let workflow = MailWorkflow(transport: fake.transport)
        let draft = try await workflow.createDraft(message(), requestID: "timeout")
        let id = try await workflow.prepareSendReview(draftID: draft.id)
        let review = try workflow.reviewForDisplay(id)
        try workflow.approve(id, displayedFingerprint: review.fingerprint)
        await fake.setFailSend()
        #expect(try await workflow.sendApproved(id).status == .uncertain)
        #expect(workflow.receipt(for: id)?.status == .uncertain)
        await #expect(throws: (any Error).self) { try await workflow.sendApproved(id) }
        await #expect(throws: (any Error).self) { try await workflow.prepareSendReview(draftID: draft.id) }
        #expect(await fake.sends == 1)
    }

    @Test func expiryClockRollbackAndCancelRequireFreshReview() async throws {
        let fake = MailWorkflowFixture()
        var now = Date(timeIntervalSince1970: 1000)
        let workflow = MailWorkflow(transport: fake.transport, now: { now })
        let draft = try await workflow.createDraft(message(), requestID: "clock")
        let old = try await workflow.prepareSendReview(draftID: draft.id)
        now = now.addingTimeInterval(121)
        #expect(throws: (any Error).self) { try workflow.reviewForDisplay(old) }
        let backwards = try await workflow.prepareSendReview(draftID: draft.id)
        now = now.addingTimeInterval(-1)
        #expect(throws: (any Error).self) { try workflow.reviewForDisplay(backwards) }
        let cancelled = try await workflow.prepareSendReview(draftID: draft.id)
        let displayed = try workflow.reviewForDisplay(cancelled)
        try workflow.approve(cancelled, displayedFingerprint: displayed.fingerprint)
        workflow.cancelPendingReviews()
        await #expect(throws: (any Error).self) { try await workflow.sendApproved(cancelled) }
        #expect(await fake.sends == 0)
    }

    @Test func cancellationDuringFinalReadCannotDispatch() async throws {
        let fake = MailWorkflowFixture()
        let workflow = MailWorkflow(transport: fake.transport)
        let draft = try await workflow.createDraft(message(), requestID: "cancel-read")
        let id = try await workflow.prepareSendReview(draftID: draft.id)
        let review = try workflow.reviewForDisplay(id)
        try workflow.approve(id, displayedFingerprint: review.fingerprint)
        await fake.pauseRead()
        let operation = Task { try await workflow.sendApproved(id) }
        for _ in 0..<100 {
            if await fake.readStarted { break }
            await Task.yield()
        }
        workflow.cancelPendingReviews()
        await fake.releaseRead()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(await fake.sends == 0)
    }

    @Test func reviewExpiringDuringTheFinalReadCannotDispatch() async throws {
        let fake = MailWorkflowFixture()
        let clock = MailWorkflowTestClock()
        let transport = MailWorkflowTransport(create: fake.transport.create, read: { reference in
            let snapshot = try await fake.read(reference)
            await MainActor.run { clock.date = clock.date.addingTimeInterval(121) }
            return snapshot
        }, send: fake.transport.send)
        let workflow = MailWorkflow(transport: transport, now: { clock.date })
        let draft = try await workflow.createDraft(message(), requestID: "read-expiry")
        let id = try await workflow.prepareSendReview(draftID: draft.id)
        let review = try workflow.reviewForDisplay(id)
        try workflow.approve(id, displayedFingerprint: review.fingerprint)
        await #expect(throws: (any Error).self) { try await workflow.sendApproved(id) }
        #expect(await fake.sends == 0)
    }

    @Test func cancellationAfterDispatchRetainsTheLateReceiptAndBlocksReplay() async throws {
        let fake = MailWorkflowFixture()
        let workflow = MailWorkflow(transport: fake.transport)
        let draft = try await workflow.createDraft(message(), requestID: "late-receipt")
        let id = try await workflow.prepareSendReview(draftID: draft.id)
        let review = try workflow.reviewForDisplay(id)
        try workflow.approve(id, displayedFingerprint: review.fingerprint)
        await fake.pauseSend()
        let operation = Task { try await workflow.sendApproved(id) }
        for _ in 0..<100 {
            if await fake.sendStarted { break }
            await Task.yield()
        }
        workflow.cancelPendingReviews()
        operation.cancel()
        await fake.releaseSend()
        #expect(try await operation.value.status == .acceptedByMail)
        #expect(workflow.receipt(for: id)?.status == .acceptedByMail)
        await #expect(throws: (any Error).self) { try await workflow.sendApproved(id) }
        await #expect(throws: (any Error).self) { try await workflow.prepareSendReview(draftID: draft.id) }
        #expect(await fake.sends == 1)
    }

    @Test func headersAndRecipientGroupsRejectAmbiguousAddresses() throws {
        let valid = message()
        try valid.validate()
        let malformed = MailWorkflowMessage(sender: valid.sender, to: [.init(address: "one@example.invalid\r\nBcc: hidden@example.invalid")], subject: valid.subject, body: valid.body)
        #expect(throws: (any Error).self) { try malformed.validate() }
        let duplicate = MailWorkflowMessage(sender: valid.sender, to: valid.to, bcc: valid.to, subject: valid.subject, body: valid.body)
        #expect(throws: (any Error).self) { try duplicate.validate() }
        let subject = MailWorkflowMessage(sender: valid.sender, to: valid.to, subject: "Header\nInjection", body: valid.body)
        #expect(throws: (any Error).self) { try subject.validate() }
        let changed = MailWorkflowMessage(sender: valid.sender, to: valid.to, cc: valid.cc, bcc: valid.bcc, subject: valid.subject, body: "Cafe\u{301} 🌍\nمرحبا\nA second line.")
        #expect(!changed.matchesRequestedContents(valid))
    }

    @Test func messageJSONDefaultsOnlyTheOptionalRecipientFields() throws {
        let data = Data(#"{"sender":"sender@example.invalid","to":[{"address":"recipient@example.invalid"}],"subject":"Synthetic","body":"Exact body"}"#.utf8)
        let decoded = try JSONDecoder().decode(MailWorkflowMessage.self, from: data)
        try decoded.validate()
        #expect(decoded.to.first?.name == "")
        #expect(decoded.cc.isEmpty && decoded.bcc.isEmpty)
        #expect(decoded.body == "Exact body")
    }
}

@MainActor
private final class MailAppleEventFixture {
    let identity = MailWorkflowDraftReference(processID: 4242, launchedAt: Date(timeIntervalSince1970: 1), messageID: 7)
    var sender = ""
    var subject = ""
    var body = ""
    var recipients: [UInt32: [MailWorkflowRecipient]] = [:]
    var events: [(UInt32, UInt32)] = []
    var sendCount = 0
    var failRecipient = false
    var autoBcc = false
    var useWideIDs = false

    func exchange(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let cc = MailWorkflowAppleEvents.cc
        events.append((event.eventClass, event.eventID))
        #expect(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?.data == NSAppleEventDescriptor(processIdentifier: identity.processID).data)
        let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        if event.eventClass == cc("emsg"), event.eventID == cc("send") { sendCount += 1; return .init(boolean: true) }
        if event.eventID == cc("save") { return .null() }
        if event.eventID == cc("crel") {
            let kind = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyAEObjectClass))?.typeCodeValue)
            let properties = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)))
            if kind == cc("bcke") {
                sender = try #require(properties.forKeyword(cc("sndr"))?.stringValue)
                subject = try #require(properties.forKeyword(cc("subj"))?.stringValue)
                body = try #require(properties.forKeyword(cc("ctnt"))?.stringValue)
                #expect(properties.forKeyword(cc("pvis"))?.booleanValue == true)
            } else {
                if failRecipient { throw MailWorkflowFailure.eventFailed(-1708) }
                let location = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyAEInsertHere)))
                #expect(location.descriptorType == cc("insl"))
                recipients[kind, default: []].append(.init(address: try #require(properties.forKeyword(cc("radd"))?.stringValue),
                                                          name: try #require(properties.forKeyword(cc("pnam"))?.stringValue)))
            }
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(.init(typeCode: cc("bcke")), forKeyword: AEKeyword(keyAEDesiredClass))
            record.setDescriptor(.init(enumCode: OSType(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
            record.setDescriptor(.init(int32: identity.messageID), forKeyword: AEKeyword(keyAEKeyData))
            record.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
            return try #require(record.coerce(toDescriptorType: DescType(typeObjectSpecifier)))
        }
        if event.eventID == cc("cnte") {
            let kind = try #require(direct?.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue)
            return .init(int32: Int32(recipients[kind]?.count ?? 0))
        }
        let property = try #require(direct?.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue)
        if property == cc("abcm") { return .init(boolean: autoBcc) }
        if property == cc("accm") { return .init(boolean: false) }
        if property == cc("ID  ") {
            if useWideIDs {
                var value = Int64(identity.messageID)
                return try withUnsafeBytes(of: &value) { try #require(NSAppleEventDescriptor(descriptorType: DescType(typeSInt64), data: Data($0))) }
            }
            return .init(int32: identity.messageID)
        }
        if property == cc("sndr") { return .init(string: sender) }
        if property == cc("subj") { return .init(string: subject) }
        if property == cc("ctnt") { return .init(string: body) }
        let container = try #require(direct?.forKeyword(AEKeyword(keyAEContainer)))
        let kind = try #require(container.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue)
        let index = Int(try #require(container.forKeyword(AEKeyword(keyAEKeyData))?.int32Value)) - 1
        let values = recipients[kind] ?? []
        guard values.indices.contains(index) else { throw MailWorkflowFailure.malformedReply }
        return .init(string: property == cc("radd") ? values[index].address : values[index].name)
    }
}

@MainActor
struct MailWorkflowAppleEventTests {
    @Test func installedDictionaryFieldsAreTypedAndDataNeverBecomesScript() throws {
        let fake = MailAppleEventFixture()
        fake.useWideIDs = true
        let body = "tell application \"Mail\" to send every outgoing message\nمرحبا 🌍"
        let message = MailWorkflowMessage(sender: "sender@example.invalid", to: [.init(address: "to@example.invalid")],
                                          cc: [.init(address: "cc@example.invalid")], bcc: [.init(address: "bcc@example.invalid")],
                                          subject: "Synthetic", body: body)
        let created = try MailWorkflowAppleEvents.create(message, identity: fake.identity, exchange: fake.exchange)
        #expect(created.message.matchesRequestedContents(message))
        #expect(created.message.body.utf8.elementsEqual(body.utf8))
        #expect(fake.sendCount == 0)
        #expect(try MailWorkflowAppleEvents.send(created, expiresAt: Date().addingTimeInterval(120), exchange: fake.exchange))
        #expect(fake.sendCount == 1)
        let cc = MailWorkflowAppleEvents.cc
        #expect(fake.events.allSatisfy { eventClass, id in
            eventClass == cc("core") && [cc("crel"), cc("getd"), cc("cnte"), cc("save")].contains(id)
                || eventClass == cc("emsg") && id == cc("send")
        })
    }

    @Test func partialDraftIsRetainedWithoutCleanupOrAutomaticCreationRetry() throws {
        let fake = MailAppleEventFixture()
        fake.failRecipient = true
        let message = MailWorkflowMessage(sender: "sender@example.invalid", to: [.init(address: "to@example.invalid")], subject: "Synthetic", body: "Body")
        do {
            _ = try MailWorkflowAppleEvents.create(message, identity: fake.identity, exchange: fake.exchange)
            Issue.record("A failed recipient mutation was not reported.")
        } catch MailWorkflowFailure.creationUncertain(let reference) {
            #expect(reference == fake.identity)
        }
        #expect(fake.sendCount == 0)
        #expect(fake.events.filter { $0.1 == MailWorkflowAppleEvents.cc("crel") }.count == 2)
        #expect(!fake.events.contains { $0.1 == MailWorkflowAppleEvents.cc("delo") })
    }

    @Test func changedBodyAndAutomaticCopiesCannotReachTheSendCommand() throws {
        let fake = MailAppleEventFixture()
        let message = MailWorkflowMessage(sender: "sender@example.invalid", to: [.init(address: "to@example.invalid")], subject: "Synthetic", body: "Body")
        let created = try MailWorkflowAppleEvents.create(message, identity: fake.identity, exchange: fake.exchange)
        fake.body = "Changed in Mail"
        #expect(throws: (any Error).self) { try MailWorkflowAppleEvents.send(created, expiresAt: Date().addingTimeInterval(120), exchange: fake.exchange) }
        #expect(fake.sendCount == 0)
        fake.body = "Body"
        fake.autoBcc = true
        #expect(throws: (any Error).self) { try MailWorkflowAppleEvents.send(created, expiresAt: Date().addingTimeInterval(120), exchange: fake.exchange) }
        #expect(fake.sendCount == 0)
    }

    @Test func reviewExpiringDuringNativeReadbackCannotReachTheSendCommand() throws {
        let fake = MailAppleEventFixture()
        let message = MailWorkflowMessage(sender: "sender@example.invalid", to: [.init(address: "to@example.invalid")], subject: "Synthetic", body: "Body")
        let created = try MailWorkflowAppleEvents.create(message, identity: fake.identity, exchange: fake.exchange)
        let prepared = Date(timeIntervalSince1970: 1000)
        var now = prepared
        #expect(throws: (any Error).self) {
            try MailWorkflowAppleEvents.send(created, expiresAt: prepared.addingTimeInterval(120), now: { now }) { command in
                let reply = try fake.exchange(command)
                if command.eventID == MailWorkflowAppleEvents.cc("getd") { now = prepared.addingTimeInterval(121) }
                return reply
            }
        }
        #expect(fake.sendCount == 0)
    }
}
