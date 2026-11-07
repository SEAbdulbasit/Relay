import Foundation

/// Mail requests remain local and require a displayed, one-use approval for every write.
@MainActor
final class MailWorkflowTools {
    private struct Pending {
        let callFingerprint: String
        let message: MailWorkflowMessage?
        let review: MailWorkflowReview?
        var prepared = false
        var approved = false
    }

    private let workflow: MailWorkflow
    private var pending: [String: Pending] = [:]

    init(workflow: MailWorkflow = MailWorkflow()) { self.workflow = workflow }

    func reviewReason(_ call: ToolCall) throws -> String? {
        switch call.name {
        case "create_mail_draft":
            let message = try decodeMessage(call)
            pending[call.id] = Pending(callFingerprint: ToolPolicy.fingerprint(call), message: message, review: nil)
            func addresses(_ values: [MailWorkflowRecipient]) -> String {
                values.isEmpty ? "None" : values.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: "\n")
            }
            return "Create this draft in Apple Mail\n\nFrom\n\(message.sender)\n\nTo\n\(addresses(message.to))\n\nCc\n\(addresses(message.cc))\n\nBcc\n\(addresses(message.bcc))\n\nSubject\n\(message.subject)\n\nBody\n\(message.body)\n\nMail may sync this draft through its existing account. Sending requires another exact review."
        case "send_mail":
            let review = try workflow.reviewForDisplay(identifier("review_id", call))
            pending[call.id] = Pending(callFingerprint: ToolPolicy.fingerprint(call), message: nil, review: review)
            return review.text + "\n\nThis approval submits the exact message to Apple Mail for sending. Recipient delivery requires separate evidence."
        default: return nil
        }
    }

    func prepareReview(_ call: ToolCall) throws {
        guard var entry = pending[call.id], entry.callFingerprint == ToolPolicy.fingerprint(call) else {
            throw MailWorkflowFailure.reviewNotDisplayed
        }
        entry.prepared = true
        pending[call.id] = entry
    }

    func authorize(_ call: ToolCall) throws {
        guard var entry = pending[call.id], entry.prepared, entry.callFingerprint == ToolPolicy.fingerprint(call) else {
            throw MailWorkflowFailure.reviewNotDisplayed
        }
        if let review = entry.review {
            try workflow.approve(review.id, displayedFingerprint: review.fingerprint)
        }
        entry.approved = true
        pending[call.id] = entry
    }

    func execute(_ call: ToolCall) async throws -> ToolResult {
        if call.name == "prepare_mail_send" {
            let reviewID = try await workflow.prepareSendReview(draftID: identifier("draft_id", call))
            let summary = JSONValue.object(["review_id": .string(reviewID.uuidString),
                                            "state": .string("Review prepared. Request send_mail with this ID to display the exact draft for approval.")]).pretty
            return ToolResult(summary: summary,
                              evidence: "Read the current contents of one draft created by Relay in this session.", verified: true)
        }
        guard let entry = pending.removeValue(forKey: call.id), entry.approved,
              entry.callFingerprint == ToolPolicy.fingerprint(call) else { throw MailWorkflowFailure.reviewNotDisplayed }
        if call.name == "create_mail_draft", let message = entry.message {
            let draft = try await workflow.createDraft(message, requestID: call.id)
            return ToolResult(summary: JSONValue.object(["draft_id": .string(draft.id.uuidString), "state": .string("Draft created")]).pretty,
                              evidence: "Apple Mail returned the draft's sender, recipients, subject, body, and attachment state. Sending requires a new exact review.",
                              verified: true)
        }
        guard call.name == "send_mail", let review = entry.review else { throw MailWorkflowFailure.reviewUnavailable }
        let receipt = try await workflow.sendApproved(review.id)
        let summary: String
        switch receipt.status {
        case .acceptedByMail: summary = "Apple Mail accepted the reviewed message for sending."
        case .rejectedByMail: summary = "Apple Mail did not accept the send request. Inspect Mail before another request."
        case .uncertain: summary = "The send outcome is uncertain. Inspect Mail before another request."
        }
        return ToolResult(summary: summary, evidence: receipt.evidence, verified: receipt.status == .acceptedByMail)
    }

    func cancel() {
        pending.removeAll()
        workflow.cancelPendingReviews()
    }

    private func identifier(_ name: String, _ call: ToolCall) throws -> UUID {
        guard let text = call.arguments[name]?.string, let id = UUID(uuidString: text) else { throw MailWorkflowFailure.unknownDraft }
        return id
    }

    private func decodeMessage(_ call: ToolCall) throws -> MailWorkflowMessage {
        guard let text = call.arguments["message_json"]?.string, text.utf8.count <= 75_000,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys).isSubset(of: ["sender", "to", "cc", "bcc", "subject", "body"]) else {
            throw MailWorkflowFailure.invalidMessage
        }
        for key in ["to", "cc", "bcc"] where object[key] != nil {
            guard let recipients = object[key] as? [[String: Any]],
                  recipients.allSatisfy({ Set($0.keys).isSubset(of: ["address", "name"]) }) else {
                throw MailWorkflowFailure.invalidMessage
            }
        }
        guard let message = try? JSONDecoder().decode(MailWorkflowMessage.self, from: Data(text.utf8)) else {
            throw MailWorkflowFailure.invalidMessage
        }
        try message.validate()
        return message
    }
}
