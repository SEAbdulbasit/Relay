import Foundation
import Testing
@testable import Relay

@MainActor
struct MailWorkflowToolTests {
    @Test func unsupportedMessageFieldsCannotBeSilentlyDroppedFromTheReview() throws {
        let tools = MailWorkflowTools()
        for extra in ["\"attachments\":[\"/tmp/file.txt\"]", "\"reply_to\":\"other@example.test\""] {
            let call = ToolCall(name: "create_mail_draft", arguments: ["message_json": .string("""
                {"sender":"sender@example.test","to":[{"address":"recipient@example.test"}],"subject":"Fixture","body":"Fixture body",\(extra)}
                """)])
            #expect(throws: MailWorkflowFailure.self) { try tools.reviewReason(call) }
            #expect(throws: MailWorkflowFailure.self) { try tools.prepareReview(call) }
        }
        let unsupportedRecipient = ToolCall(name: "create_mail_draft", arguments: ["message_json": .string("""
            {"sender":"sender@example.test","to":[{"address":"recipient@example.test","hidden":"Ignored value"}],"subject":"Fixture","body":"Fixture body"}
            """)])
        #expect(throws: MailWorkflowFailure.self) { try tools.reviewReason(unsupportedRecipient) }
        let minimal = ToolCall(name: "create_mail_draft", arguments: ["message_json": .string("""
            {"sender":"sender@example.test","to":[{"address":"recipient@example.test"}],"subject":"Fixture","body":"Fixture body"}
            """)])
        #expect(try tools.reviewReason(minimal)?.contains("recipient@example.test") == true)
    }

    @Test func toolsRequireDisplayedReviewsAndRejectEditedOrReplayedSends() async throws {
        let message = MailWorkflowMessage(sender: "sender@example.test", to: [.init(address: "recipient@example.test")],
                                          subject: "Synthetic review", body: "Fixture body — café")
        let oracle = MailToolOracle(message)
        let workflow = MailWorkflow(transport: .init(create: { try await oracle.create($0) },
                                                     read: { _ in await oracle.read() }, send: { snapshot, _ in await oracle.send(snapshot) }))
        let tools = MacTools(mailWorkflow: workflow)
        let create = ToolCall(name: "create_mail_draft", arguments: [
            "message_json": .string(String(decoding: try JSONEncoder().encode(message), as: UTF8.self))
        ])
        #expect(throws: MailWorkflowFailure.self) { try tools.prepareReview(create) }
        await #expect(throws: MailWorkflowFailure.self) { try await tools.execute(create) }
        #expect(await oracle.creations == 0)
        try approve(create, using: tools, containing: "recipient@example.test")
        let result = try await tools.execute(create)
        #expect(result.verified)
        let draftID = try identifier("draft_id", in: result)
        #expect(await oracle.creations == 1)
        let prepare = ToolCall(name: "prepare_mail_send", arguments: ["draft_id": .string(draftID)])
        let prepared = try await tools.execute(prepare)
        let send = ToolCall(name: "send_mail", arguments: ["review_id": .string(try identifier("review_id", in: prepared))])
        try approve(send, using: tools, containing: message.body)
        await oracle.changeBody("Changed after approval")
        await #expect(throws: MailWorkflowFailure.self) { try await tools.execute(send) }
        #expect(await oracle.sends == 0)

        let current = try await tools.execute(prepare)
        let approvedSend = ToolCall(name: "send_mail", arguments: ["review_id": .string(try identifier("review_id", in: current))])
        try approve(approvedSend, using: tools, containing: "Changed after approval")
        let receipt = try await tools.execute(approvedSend)
        #expect(receipt.verified)
        #expect(receipt.evidence.contains("delivery has not been independently verified"))
        #expect(await oracle.sends == 1)
        await #expect(throws: MailWorkflowFailure.self) { try await tools.execute(approvedSend) }
        #expect(await oracle.sends == 1)
    }

    @Test func stopInvalidatesTheDisplayedCreationTicket() async throws {
        let message = MailWorkflowMessage(sender: "sender@example.test", to: [.init(address: "recipient@example.test")],
                                          subject: "Synthetic draft", body: "Do not create after Stop.")
        let oracle = MailToolOracle(message)
        let tools = MacTools(mailWorkflow: MailWorkflow(transport: .init(create: { try await oracle.create($0) },
            read: { _ in await oracle.read() }, send: { snapshot, _ in await oracle.send(snapshot) })))
        let call = ToolCall(name: "create_mail_draft", arguments: [
            "message_json": .string(String(decoding: try JSONEncoder().encode(message), as: UTF8.self))
        ])
        try approve(call, using: tools, containing: message.body)
        tools.invalidateApprovals()
        await #expect(throws: MailWorkflowFailure.self) { try await tools.execute(call) }
        #expect(await oracle.creations == 0)
    }

    private func approve(_ call: ToolCall, using tools: MacTools, containing text: String) throws {
        let displayed = try #require(tools.reviewReason(for: call))
        #expect(displayed.contains(text))
        try tools.prepareReview(call)
        try tools.authorize(call)
    }

    private func identifier(_ key: String, in result: ToolResult) throws -> String {
        let data = Data(result.summary.utf8)
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        return try #require(object.object?[key]?.string)
    }
}

private actor MailToolOracle {
    private var snapshot: MailWorkflowSnapshot
    private(set) var creations = 0
    private(set) var sends = 0

    init(_ message: MailWorkflowMessage) {
        snapshot = MailWorkflowSnapshot(reference: .init(processID: 123, launchedAt: Date(), messageID: 1),
                                        message: message, attachmentCount: 0)
    }
    func create(_ message: MailWorkflowMessage) throws -> MailWorkflowSnapshot {
        try message.validate()
        creations += 1
        return snapshot
    }
    func read() -> MailWorkflowSnapshot { snapshot }
    func send(_ requested: MailWorkflowSnapshot) -> Bool {
        guard requested == snapshot else { return false }
        sends += 1
        return true
    }
    func changeBody(_ body: String) {
        let old = snapshot.message
        let updated = MailWorkflowMessage(sender: old.sender, to: old.to, cc: old.cc, bcc: old.bcc, subject: old.subject, body: body)
        snapshot = MailWorkflowSnapshot(reference: snapshot.reference, message: updated, attachmentCount: 0)
    }
}
