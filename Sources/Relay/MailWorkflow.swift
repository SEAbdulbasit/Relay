import CryptoKit
import Foundation

nonisolated struct MailWorkflowRecipient: Codable, Sendable, Equatable {
    let address: String
    var name: String = ""

    init(address: String, name: String = "") {
        self.address = address
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case address, name }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        address = try values.decode(String.self, forKey: .address)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

nonisolated struct MailWorkflowMessage: Codable, Sendable, Equatable {
    let sender: String
    let to: [MailWorkflowRecipient]
    var cc: [MailWorkflowRecipient] = []
    var bcc: [MailWorkflowRecipient] = []
    let subject: String
    let body: String

    init(sender: String, to: [MailWorkflowRecipient], cc: [MailWorkflowRecipient] = [], bcc: [MailWorkflowRecipient] = [], subject: String, body: String) {
        self.sender = sender
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case sender, to, cc, bcc, subject, body }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sender = try values.decode(String.self, forKey: .sender)
        to = try values.decode([MailWorkflowRecipient].self, forKey: .to)
        cc = try values.decodeIfPresent([MailWorkflowRecipient].self, forKey: .cc) ?? []
        bcc = try values.decodeIfPresent([MailWorkflowRecipient].self, forKey: .bcc) ?? []
        subject = try values.decode(String.self, forKey: .subject)
        body = try values.decode(String.self, forKey: .body)
    }

    func validate() throws {
        _ = try Self.senderAddress(sender)
        let recipients = to + cc + bcc
        guard !to.isEmpty, recipients.count <= 30,
              subject.utf8.count <= 1_000, body.utf8.count <= 65_536,
              Self.isPlain(subject, multiline: false), Self.isPlain(body, multiline: true) else {
            throw MailWorkflowFailure.invalidMessage
        }
        var addresses = Set<String>()
        for recipient in recipients {
            guard Self.isAddress(recipient.address), recipient.name.utf8.count <= 200,
                  Self.isPlain(recipient.name, multiline: false),
                  addresses.insert(recipient.address.lowercased()).inserted else { throw MailWorkflowFailure.invalidMessage }
        }
    }

    func matchesRequestedContents(_ requested: MailWorkflowMessage) -> Bool {
        guard let senderAddress = try? Self.senderAddress(sender), let requestedSender = try? Self.senderAddress(requested.sender),
              Self.addressKey(senderAddress) == Self.addressKey(requestedSender),
              subject.utf8.elementsEqual(requested.subject.utf8), body.utf8.elementsEqual(requested.body.utf8) else { return false }
        func sameRecipients(_ actual: [MailWorkflowRecipient], _ expected: [MailWorkflowRecipient]) -> Bool {
            actual.count == expected.count && zip(actual, expected).allSatisfy { actual, expected in
                Self.addressKey(actual.address) == Self.addressKey(expected.address)
                    && (expected.name.isEmpty || actual.name.utf8.elementsEqual(expected.name.utf8))
            }
        }
        return sameRecipients(to, requested.to) && sameRecipients(cc, requested.cc) && sameRecipients(bcc, requested.bcc)
    }

    private static func addressKey(_ address: String) -> String {
        let pieces = address.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return address }
        return String(pieces[0]) + "@" + pieces[1].lowercased()
    }

    static func senderAddress(_ sender: String) throws -> String {
        guard sender.utf8.count <= 512, isPlain(sender, multiline: false) else { throw MailWorkflowFailure.invalidMessage }
        if isAddress(sender) { return sender }
        guard let open = sender.firstIndex(of: "<"), let close = sender.firstIndex(of: ">"), close == sender.index(before: sender.endIndex),
              sender[..<open].allSatisfy({ $0 != ">" }), open < close else { throw MailWorkflowFailure.invalidMessage }
        let address = String(sender[sender.index(after: open)..<close])
        guard isAddress(address) else { throw MailWorkflowFailure.invalidMessage }
        return address
    }

    private static func isPlain(_ text: String, multiline: Bool) -> Bool {
        !text.unicodeScalars.contains { scalar in
            (scalar.value < 32 || scalar.value == 127) && !(multiline && [9, 10, 13].contains(scalar.value))
        } && (multiline || !text.contains(where: \.isNewline))
    }

    private static func isAddress(_ address: String) -> Bool {
        guard (3...254).contains(address.utf8.count), address.utf8.allSatisfy({ $0 < 128 }) else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64,
              !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains("..") else { return false }
        let local = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-")
        guard parts[0].unicodeScalars.allSatisfy(local.contains) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        let domain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.count >= 2 && labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-") && label.unicodeScalars.allSatisfy(domain.contains)
        }
    }
}

nonisolated struct MailWorkflowDraftReference: Codable, Sendable, Equatable {
    let processID: Int32
    let launchedAt: Date
    let messageID: Int32
}

nonisolated struct MailWorkflowSnapshot: Codable, Sendable, Equatable {
    let reference: MailWorkflowDraftReference
    let message: MailWorkflowMessage
    let attachmentCount: Int

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "invalid-mail-snapshot" }
        return SHA256.hash(data: data).description
    }

    func validateForSending() throws {
        try message.validate()
        guard reference.processID > 0, reference.messageID > 0, reference.launchedAt.timeIntervalSince1970.isFinite else { throw MailWorkflowFailure.staleDraft }
        guard attachmentCount == 0, !message.body.contains("\u{FFFC}") else { throw MailWorkflowFailure.unsupportedAttachment }
    }
}

nonisolated struct MailWorkflowTransport: Sendable {
    let create: @Sendable (MailWorkflowMessage) async throws -> MailWorkflowSnapshot
    let read: @Sendable (MailWorkflowDraftReference) async throws -> MailWorkflowSnapshot
    let send: @Sendable (MailWorkflowSnapshot, Date) async throws -> Bool
}

nonisolated enum MailWorkflowFailure: LocalizedError {
    case invalidMessage, appUnavailable, permissionNeeded, permissionDenied, staleDraft, busy, unknownDraft
    case reviewUnavailable, reviewNotDisplayed, reviewExpired, messageChanged, unsupportedAttachment, replayBlocked
    case malformedReply, automaticRecipients, capacityReached, eventFailed(Int32), creationUncertain(MailWorkflowDraftReference?)

    var errorDescription: String? {
        switch self {
        case .invalidMessage: "Use one explicit sender, at least one To recipient, and up to 30 unique email addresses. Subject and body limits are 1,000 and 65,536 UTF-8 bytes. Header fields must contain plain single-line text."
        case .appUnavailable: "Open the installed Apple Mail app before using this workflow."
        case .permissionNeeded: "Apple Mail Automation access is required. Enable it explicitly before using Mail workflows."
        case .permissionDenied: "macOS denied Apple Mail Automation access. Check Relay’s Automation access in System Settings."
        case .staleDraft: "The original Mail process or draft is no longer available. Inspect Mail before continuing."
        case .busy: "Wait for the current Mail workflow operation to finish."
        case .unknownDraft: "This draft was not created by Relay in the current session."
        case .reviewUnavailable: "Prepare a fresh review of the draft before sending."
        case .reviewNotDisplayed: "Show the exact Mail review before approving this message."
        case .reviewExpired: "The Mail review expired. Review the current draft again."
        case .messageChanged: "Mail’s sender, recipients, subject, body or attachments changed after review. Review the updated draft before sending."
        case .unsupportedAttachment: "This workflow sends plain text without attachments. Review and send attached files directly in Mail."
        case .replayBlocked: "This Mail request may already have taken effect. Inspect Mail before starting a new request."
        case .malformedReply: "Mail did not return a complete, bounded draft snapshot. Inspect the draft directly."
        case .automaticRecipients: "Mail is configured to add automatic Cc or Bcc recipients. Check these preferences and send directly in Mail."
        case .capacityReached: "This session reached its Mail draft limit. Inspect existing drafts in Mail before starting another session."
        case .eventFailed(let code): "Mail returned Automation error \(code). Inspect the draft before retrying."
        case .creationUncertain: "Mail draft creation did not finish cleanly. A partial draft may be open. Inspect Mail before creating another."
        }
    }
}

nonisolated struct MailWorkflowDraft: Sendable, Identifiable {
    let id: UUID
    let snapshot: MailWorkflowSnapshot
}

nonisolated struct MailWorkflowReview: Sendable, Identifiable {
    let id: UUID
    let draftID: UUID
    let snapshot: MailWorkflowSnapshot
    let preparedAt: Date
    let expiresAt: Date

    var fingerprint: String { snapshot.fingerprint }
    var text: String {
        func recipients(_ values: [MailWorkflowRecipient]) -> String {
            values.isEmpty ? "None" : values.map { $0.name.isEmpty ? $0.address : "\($0.address) (\($0.name))" }.joined(separator: "\n")
        }
        return "Send from Apple Mail\n\nFrom\n\(snapshot.message.sender)\n\nTo\n\(recipients(snapshot.message.to))\n\nCc\n\(recipients(snapshot.message.cc))\n\nBcc\n\(recipients(snapshot.message.bcc))\n\nSubject\n\(snapshot.message.subject)\n\nBody\n\(snapshot.message.body)\n\nAttachments\nNone"
    }
}

nonisolated struct MailWorkflowSendReceipt: Sendable {
    enum Status: String, Sendable { case acceptedByMail, rejectedByMail, uncertain }
    let reviewID: UUID
    let status: Status
    let evidence: String
}

/// Only the explicit review UI should call reviewForDisplay and approve. Model requests
/// receive draft/review IDs, never permission to approve their own content.
@MainActor
final class MailWorkflow {
    private struct ReviewEntry {
        let review: MailWorkflowReview
        var displayed = false
        var approved = false
    }
    private enum Creation {
        case pending, created(String, MailWorkflowDraft), uncertain
    }
    private var creations: [String: Creation] = [:]
    private var drafts: [UUID: MailWorkflowDraftReference] = [:]
    private var blockedDrafts = Set<UUID>()
    private var reviews: [UUID: ReviewEntry] = [:]
    private var receipts: [UUID: MailWorkflowSendReceipt] = [:]
    private var revision = 0
    private(set) var isBusy = false
    private let transport: MailWorkflowTransport
    private let now: () -> Date

    init(transport: MailWorkflowTransport = MailWorkflowAppleEvents.live, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.now = now
    }

    func createDraft(_ message: MailWorkflowMessage, requestID: String) async throws -> MailWorkflowDraft {
        try message.validate()
        guard !requestID.isEmpty, requestID.utf8.count <= 128, !requestID.contains(where: \.isNewline) else { throw MailWorkflowFailure.invalidMessage }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let signature = SHA256.hash(data: try encoder.encode(message)).description
        if let prior = creations[requestID] {
            if case .created(let expected, let draft) = prior, expected == signature { return draft }
            throw MailWorkflowFailure.replayBlocked
        }
        guard creations.count < 64 else { throw MailWorkflowFailure.capacityReached }
        guard !isBusy else { throw MailWorkflowFailure.busy }
        try Task.checkCancellation()
        isBusy = true
        creations[requestID] = .pending
        defer { isBusy = false }
        do {
            let snapshot = try await transport.create(message)
            try snapshot.message.validate()
            guard snapshot.reference.processID > 0, snapshot.reference.messageID > 0,
                  snapshot.reference.launchedAt.timeIntervalSince1970.isFinite, snapshot.attachmentCount == 0,
                  snapshot.message.matchesRequestedContents(message) else { throw MailWorkflowFailure.creationUncertain(snapshot.reference) }
            let draft = MailWorkflowDraft(id: UUID(), snapshot: snapshot)
            drafts[draft.id] = snapshot.reference
            creations[requestID] = .created(signature, draft)
            return draft
        } catch {
            creations[requestID] = .uncertain
            throw error
        }
    }

    func prepareSendReview(draftID: UUID) async throws -> UUID {
        guard !isBusy else { throw MailWorkflowFailure.busy }
        guard let reference = drafts[draftID] else { throw MailWorkflowFailure.unknownDraft }
        guard !blockedDrafts.contains(draftID) else { throw MailWorkflowFailure.replayBlocked }
        isBusy = true
        let expected = revision
        defer { isBusy = false }
        let snapshot = try await transport.read(reference)
        try Task.checkCancellation()
        guard revision == expected, snapshot.reference == reference else { throw MailWorkflowFailure.staleDraft }
        try snapshot.validateForSending()
        reviews = reviews.filter { $0.value.review.draftID != draftID && $0.value.review.expiresAt > now() }
        let preparedAt = now()
        let review = MailWorkflowReview(id: UUID(), draftID: draftID, snapshot: snapshot, preparedAt: preparedAt, expiresAt: preparedAt.addingTimeInterval(120))
        reviews[review.id] = ReviewEntry(review: review)
        return review.id
    }

    func reviewForDisplay(_ reviewID: UUID) throws -> MailWorkflowReview {
        guard var entry = reviews[reviewID] else { throw MailWorkflowFailure.reviewUnavailable }
        guard isCurrent(entry.review) else { reviews.removeValue(forKey: reviewID); throw MailWorkflowFailure.reviewExpired }
        entry.displayed = true
        entry.approved = false
        reviews[reviewID] = entry
        return entry.review
    }

    func approve(_ reviewID: UUID, displayedFingerprint: String) throws {
        guard var entry = reviews[reviewID] else { throw MailWorkflowFailure.reviewUnavailable }
        guard entry.displayed, entry.review.fingerprint == displayedFingerprint else { throw MailWorkflowFailure.reviewNotDisplayed }
        guard isCurrent(entry.review) else { reviews.removeValue(forKey: reviewID); throw MailWorkflowFailure.reviewExpired }
        entry.approved = true
        reviews[reviewID] = entry
    }

    func sendApproved(_ reviewID: UUID) async throws -> MailWorkflowSendReceipt {
        guard !isBusy else { throw MailWorkflowFailure.busy }
        guard let entry = reviews.removeValue(forKey: reviewID), entry.approved else { throw MailWorkflowFailure.reviewUnavailable }
        let review = entry.review
        guard isCurrent(review) else { throw MailWorkflowFailure.reviewExpired }
        guard !blockedDrafts.contains(review.draftID), drafts[review.draftID] == review.snapshot.reference else { throw MailWorkflowFailure.replayBlocked }
        isBusy = true
        let expected = revision
        defer { isBusy = false }
        let current = try await transport.read(review.snapshot.reference)
        try Task.checkCancellation()
        guard revision == expected else { throw CancellationError() }
        guard isCurrent(review) else { throw MailWorkflowFailure.reviewExpired }
        guard current.fingerprint == review.snapshot.fingerprint else { throw MailWorkflowFailure.messageChanged }
        try current.validateForSending()
        // From this point the app may accept the send before a timeout or cancellation.
        // Consume every review for this draft and keep a permanent session replay barrier.
        blockedDrafts.insert(review.draftID)
        reviews = reviews.filter { $0.value.review.draftID != review.draftID }
        let receipt: MailWorkflowSendReceipt
        do {
            let accepted = try await transport.send(current, review.expiresAt)
            receipt = MailWorkflowSendReceipt(reviewID: reviewID, status: accepted ? .acceptedByMail : .rejectedByMail,
                evidence: accepted ? "Apple Mail returned success for one send command on the exact reviewed draft. Recipient delivery has not been independently verified."
                                   : "Apple Mail returned false for the send request. Inspect Mail before starting a new request.")
        } catch {
            receipt = MailWorkflowSendReceipt(reviewID: reviewID, status: .uncertain,
                evidence: "The send request may have reached Apple Mail, but its outcome is uncertain. Inspect Mail before sending again.")
        }
        receipts[reviewID] = receipt
        return receipt
    }

    func receipt(for reviewID: UUID) -> MailWorkflowSendReceipt? { receipts[reviewID] }

    private func isCurrent(_ review: MailWorkflowReview) -> Bool {
        (0..<120).contains(now().timeIntervalSince(review.preparedAt))
    }

    func cancelPendingReviews() {
        revision += 1
        reviews.removeAll()
    }
}
