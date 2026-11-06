import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

nonisolated struct PreparationWakeCommand: Equatable, Identifiable, Sendable {
    let date: Date
    let command: String
    var id: Date { date }
}

nonisolated struct PreparationWakeSetup: Equatable, Sendable {
    let status: String
    var request: PreparationWakeCommand?
    var pending: [Date] = []
    var cancellations: [PreparationWakeCommand] = []

    static func make(
        now: Date, timeZone: TimeZone, hour: Int, minute: Int, lastHandledDay: String?,
        enabled: Bool, onExternalPower: Bool, powerLimited: Bool, scheduledDates: [Date]?
    ) -> Self {
        guard now.timeIntervalSinceReferenceDate.isFinite, now >= .distantPast, now <= .distantFuture else {
            return Self(status: "Relay couldn’t determine the current date for wake planning.")
        }
        guard let scheduledDates, scheduledDates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            return Self(status: "Relay couldn’t check the macOS wake schedule.")
        }
        let pending = Array(Set(scheduledDates.filter { $0 > now })).sorted()
        if !pending.isEmpty {
            let cancellations = pending.compactMap { command(for: $0, timeZone: timeZone, cancel: true) }
            return Self(status: "macOS lists a pending wake for Relay. Cancel it before requesting a different time.",
                        pending: pending, cancellations: cancellations)
        }
        guard enabled else { return Self(status: "Enable daily preparation to plan a wake.") }
        guard onExternalPower, !powerLimited else {
            return Self(status: "Connect this Mac to power and wait for power or temperature limits to clear.")
        }
        let today = DailyPreparationPolicy.dayKey(now, timeZone: timeZone)
        guard lastHandledDay.map({ $0 <= today }) ?? true else {
            return Self(status: "This Mac’s date is before the last handled day. Wake planning is paused.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let earliest = now.addingTimeInterval(5 * 60)
        guard let todayTime = DailyPreparationPolicy.scheduledTime(on: now, hour: hour, minute: minute, calendar: calendar) else {
            return Self(status: "Relay couldn’t determine the next local preparation time.")
        }
        let date: Date?
        if todayTime >= earliest, lastHandledDay != today {
            date = todayTime
        } else {
            date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)).flatMap {
                DailyPreparationPolicy.scheduledTime(on: $0, hour: hour, minute: minute, calendar: calendar)
            }
        }
        guard let date, let request = command(for: date, timeZone: timeZone, cancel: false) else {
            return Self(status: "The next preparation time can’t be represented as an exact macOS wake request. Choose a different time.")
        }
        return Self(status: "No Relay wake is scheduled. Review the next time before applying the command.", request: request)
    }

    private static func command(for date: Date, timeZone: TimeZone, cancel: Bool) -> PreparationWakeCommand? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = fields.year, (2000...2068).contains(year),
              let month = fields.month, let day = fields.day, let hour = fields.hour,
              let minute = fields.minute, let second = fields.second,
              date.timeIntervalSinceReferenceDate.rounded() == date.timeIntervalSinceReferenceDate else { return nil }
        let beforeDay = calendar.startOfDay(for: date).addingTimeInterval(-1)
        let wallTime = DateComponents(hour: hour, minute: minute, second: second)
        let first = calendar.nextDate(after: beforeDay, matching: wallTime, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: beforeDay, matching: wallTime, matchingPolicy: .strict, repeatedTimePolicy: .last)
        // pmset takes local wall time without a UTC offset. Reject both occurrences of a repeated time.
        guard first == date, last == date else { return nil }
        let time = String(format: "%02d/%02d/%02d %02d:%02d:%02d", month, day, year % 100, hour, minute, second)
        let action = cancel ? "schedule cancel" : "schedule"
        return PreparationWakeCommand(date: date, command: "sudo /usr/bin/pmset \(action) wake '\(time)' '\(PreparationWakeSystem.owner)'")
    }
}

/// Reads the documented system queue. The reviewed Terminal command is the only write path.
nonisolated enum PreparationWakeSystem {
    static let owner = "dev.relay.assistant.preparation.\(getuid())"

    static func scheduledDates() -> [Date]? {
        guard let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() else { return [] }
        guard let rows = events as? [[String: Any]] else { return nil }
        return relayWakeDates(in: rows)
    }

    static func relayWakeDates(in rows: [[String: Any]]) -> [Date]? {
        var dates: [Date] = []
        for row in rows where row[kIOPMPowerEventAppNameKey] as? String == owner
            && row[kIOPMPowerEventTypeKey] as? String == kIOPMAutoWake {
            guard let date = row[kIOPMPowerEventTimeKey] as? Date,
                  date.timeIntervalSinceReferenceDate.isFinite else { return nil }
            dates.append(date)
        }
        return dates
    }

    static func isOnExternalPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return source as String == kIOPSACPowerValue
    }

    static func isThermallyLimited() -> Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        case .nominal, .fair: return false
        @unknown default: return true
        }
    }
}
