import Foundation

/// Capability context contains only app state and the device clock. Calendar
/// titles, account names and identifiers stay on this Mac until local review.
@MainActor
enum CalendarPlannerSupport {
    static func instructions(hasWriteDestination: Bool, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let clock = ISO8601DateFormatter()
        clock.timeZone = timeZone
        let clockContext = "Device date/time: \(clock.string(from: now)); time zone: \(timeZone.identifier). Resolve relative dates here."
        if !hasWriteDestination {
            return "\nCalendar creation is supported. No write destination is selected. Setup: Settings → Sources → Apple Calendar; grant access/refresh, then choose Calendar for event creation. Explain this setup, not unsupported tools. \(clockContext)\n"
        }
        return "\nCalendar: calendar_id=selected. Ask missing title/duration; retain prior answers. Stage→commit review_id; user approval/readback required. Invitations/attendees are not supported. Use requested local time with ISO8601 offset. \(clockContext)\n"
    }

    static func addingContext(to messages: [ModelMessage], hasWriteDestination: Bool) -> [ModelMessage] {
        var result = messages
        let context = instructions(hasWriteDestination: hasWriteDestination)
        if let index = result.firstIndex(where: { $0.role == "system" }) { result[index].content += context }
        else { result.insert(ModelMessage(role: "system", content: context), at: 0) }
        return result
    }
}
