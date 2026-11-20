import Foundation

@MainActor
final class CalendarWriteWorkflowTools {
    private struct Pending {
        let callFingerprint: String
        let event: CalendarWriteEvent?
        let review: CalendarWriteReview?
        var prepared = false
        var approved = false
    }

    let workflow: CalendarWriteWorkflow
    private var writeDestinationID: String?

    static let selectedDestinationAlias = "selected"
    private var pending: [String: Pending] = [:]

    init(workflow: CalendarWriteWorkflow = CalendarWriteWorkflow()) {
        self.workflow = workflow
    }

    func setWriteDestination(_ calendar: CalendarSource.CalendarInfo?) {
        pending.removeAll()
        writeDestinationID = calendar?.id
        let title = calendar.map { target in
            target.accountTitle.isEmpty ? target.title : "\(target.title) (\(target.accountTitle))"
        }
        workflow.setWriteDestination(id: calendar?.id, title: title)
    }

    static let names: Set<String> = ["create_calendar_event", "commit_calendar_event", "rollback_calendar_event"]

    func configureTestCalendar(id: String, title: String, isSelected: Bool = true) {
        workflow.configureTestCalendar(id: id, title: title, isSelected: isSelected)
        if isSelected { writeDestinationID = id }
    }

    func reviewReason(_ call: ToolCall) throws -> String? {
        switch call.name {
        case "create_calendar_event":
            let event = try decodeEvent(call)
            let review = try? workflow.reviewForDisplay(optionalIdentifier("review_id", call) ?? UUID())
            pending[call.id] = Pending(callFingerprint: ToolPolicy.fingerprint(call), event: event, review: review)
            return "Stage this calendar event for review.\n\nTitle: \(event.title)\nStart: \(event.start.ISO8601Format())\nEnd: \(event.end.ISO8601Format())\nCalendar: \(event.calendarID)\nLocation: \(event.location.isEmpty ? "None" : event.location)\nNotes: \(event.notes.isEmpty ? "None" : event.notes)\n\nWriting requires explicit review and will be verified by an exact readback."
        case "commit_calendar_event":
            let reviewID = try requiredIdentifier("review_id", call)
            let review = try workflow.reviewForDisplay(reviewID)
            pending[call.id] = Pending(callFingerprint: ToolPolicy.fingerprint(call), event: nil, review: review)
            return review.reviewText
        case "rollback_calendar_event":
            let reviewID = try requiredIdentifier("review_id", call)
            pending[call.id] = Pending(callFingerprint: ToolPolicy.fingerprint(call), event: nil, review: nil)
            return "Safely delete/rollback previously created event for review \(reviewID.uuidString) from the calendar."
        default:
            return nil
        }
    }

    func prepareReview(_ call: ToolCall) throws {
        guard var entry = pending[call.id], entry.callFingerprint == ToolPolicy.fingerprint(call) else {
            throw CalendarWriteFailure.reviewNotDisplayed
        }
        entry.prepared = true
        pending[call.id] = entry
    }

    func authorize(_ call: ToolCall) throws {
        guard var entry = pending[call.id], entry.prepared, entry.callFingerprint == ToolPolicy.fingerprint(call) else {
            throw CalendarWriteFailure.reviewNotDisplayed
        }
        if let review = entry.review {
            try workflow.approve(review.id, displayedFingerprint: review.fingerprint)
        }
        entry.approved = true
        pending[call.id] = entry
    }

    func execute(_ call: ToolCall) async throws -> ToolResult {
        switch call.name {
        case "create_calendar_event":
            let event = try decodeEvent(call)
            let review = try await workflow.stageEvent(requestID: call.id, event: event)
            let summary = JSONValue.object([
                "review_id": .string(review.id.uuidString),
                "state": .string("Review prepared. Call commit_calendar_event with this review_id after displaying for approval.")
            ]).pretty
            return ToolResult(
                summary: summary,
                evidence: "Staged event creation in the selected calendar. Exact review required before writing.",
                verified: true
            )
        case "commit_calendar_event":
            guard let entry = pending.removeValue(forKey: call.id), entry.approved,
                  entry.callFingerprint == ToolPolicy.fingerprint(call),
                  let review = entry.review else {
                throw CalendarWriteFailure.reviewNotDisplayed
            }
            let receipt = try await workflow.executeApproved(review.id)
            let summary = JSONValue.object([
                "status": .string(receipt.status.rawValue)
            ]).pretty
            return ToolResult(
                summary: summary,
                evidence: receipt.status == .verified
                    ? "Event created and independently checked in the selected calendar."
                    : "The calendar write was not verified. Inspect Calendar before retrying.",
                verified: receipt.status == .verified
            )
        case "rollback_calendar_event":
            let reviewID = try requiredIdentifier("review_id", call)
            guard let entry = pending.removeValue(forKey: call.id), entry.approved,
                  entry.callFingerprint == ToolPolicy.fingerprint(call) else {
                throw CalendarWriteFailure.reviewNotDisplayed
            }
            let rolledBack = try await workflow.rollback(reviewID: reviewID)
            let summary = JSONValue.object([
                "review_id": .string(reviewID.uuidString),
                "rolled_back": .bool(rolledBack)
            ]).pretty
            return ToolResult(
                summary: summary,
                evidence: rolledBack ? "Event successfully rolled back from calendar." : "Rollback failed or event not found.",
                verified: rolledBack
            )
        default:
            throw CalendarWriteFailure.invalidEvent("Unsupported calendar tool call: \(call.name)")
        }
    }

    func cancel() {
        pending.removeAll()
        workflow.invalidatePendingReviews()
    }

    private func requiredIdentifier(_ name: String, _ call: ToolCall) throws -> UUID {
        guard let text = call.arguments[name]?.string else {
            throw CalendarWriteFailure.invalidEvent("Missing identifier parameter '\(name)'.")
        }
        guard let id = UUID(uuidString: text) else {
            throw CalendarWriteFailure.invalidEvent("Invalid UUID for '\(name)'.")
        }
        return id
    }

    private func optionalIdentifier(_ name: String, _ call: ToolCall) -> UUID? {
        guard let text = call.arguments[name]?.string else { return nil }
        return UUID(uuidString: text)
    }

    private func decodeEvent(_ call: ToolCall) throws -> CalendarWriteEvent {
        guard let text = call.arguments["event_json"]?.string, text.utf8.count <= 65_536,
              let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalendarWriteFailure.invalidEvent("event_json must be a valid JSON object.")
        }
        guard let calendarID = dict["calendar_id"] as? String,
              let title = dict["title"] as? String,
              let startStr = dict["start"] as? String,
              let endStr = dict["end"] as? String else {
            throw CalendarWriteFailure.invalidEvent("Missing required fields: calendar_id, title, start, end.")
        }
        let formatter = ISO8601DateFormatter()
        guard let start = formatter.date(from: startStr),
              let end = formatter.date(from: endStr) else {
            throw CalendarWriteFailure.invalidEvent("Dates must be formatted in ISO8601.")
        }
        let allDay = dict["all_day"] as? Bool ?? false
        let location = dict["location"] as? String ?? ""
        let notes = dict["notes"] as? String ?? ""
        let timeZone = dict["time_zone"] as? String

        let resolvedCalendarID: String
        if calendarID == Self.selectedDestinationAlias {
            guard let writeDestinationID else { throw CalendarWriteFailure.unselectedCalendar }
            resolvedCalendarID = writeDestinationID
        } else { resolvedCalendarID = calendarID }
        let event = CalendarWriteEvent(
            calendarID: resolvedCalendarID,
            title: title,
            start: start,
            end: end,
            allDay: allDay,
            location: location,
            notes: notes,
            timeZone: timeZone
        )
        try event.validate()
        return event
    }

    static var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "create_calendar_event",
                description: "Stage selected Calendar event; returns review_id. Exact review then commit required. No attendees.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "event_json": .object(["type": .string("string"), "description": .string("JSON: calendar_id=selected,title,start/end(ISO8601); optional all_day,location,notes,time_zone")])
                    ]),
                    "required": .array([.string("event_json")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            ToolDefinition(
                name: "commit_calendar_event",
                description: "Write reviewed event using one-use review_id; verify exact readback.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "review_id": .object(["type": .string("string"), "description": .string("Stage review UUID")])
                    ]),
                    "required": .array([.string("review_id")]),
                    "additionalProperties": .bool(false)
                ])
            ),
            ToolDefinition(
                name: "rollback_calendar_event",
                description: "Review and undo event created by review_id.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "review_id": .object(["type": .string("string"), "description": .string("Stage review UUID")])
                    ]),
                    "required": .array([.string("review_id")]),
                    "additionalProperties": .bool(false)
                ])
            )
        ]
    }
}
