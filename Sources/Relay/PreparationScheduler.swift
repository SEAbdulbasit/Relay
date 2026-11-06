import AppKit
import Foundation
import Observation

nonisolated enum DailyPreparationPolicy {
    enum Decision: Equatable { case waiting, handled, clockMovedBack, missed, due(day: String) }
    static func decision(now: Date, hour: Int, minute: Int, lastHandledDay: String?, timeZone: TimeZone) throws -> Decision {
        guard now.timeIntervalSinceReferenceDate.isFinite, now >= .distantPast, now <= .distantFuture, (0...23).contains(hour), (0...59).contains(minute) else {
            throw RelayError.message("Choose a valid local preparation time.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0)
        if let lastHandledDay, lastHandledDay > day { return .clockMovedBack }
        if lastHandledDay == day { return .handled }
        guard let scheduled = scheduledTime(on: now, hour: hour, minute: minute, calendar: calendar) else {
            throw RelayError.message("Today's local preparation time could not be determined.")
        }
        if now < scheduled { return .waiting }
        if now.timeIntervalSince(scheduled) > 6 * 3600 { return .missed }
        return .due(day: day)
    }

    static func scheduledTime(on day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute),
              let date = calendar.nextDate(
                after: calendar.startOfDay(for: day).addingTimeInterval(-1),
                matching: DateComponents(hour: hour, minute: minute),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first
              ), calendar.isDate(date, inSameDayAs: day) else { return nil }
        return date
    }
    static func validDayKey(_ value: String) -> Bool {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
        let checked = calendar.dateComponents([.year, .month, .day], from: date)
        return checked.year == parts[0] && checked.month == parts[1] && checked.day == parts[2]
    }
    static func dayKey(_ now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let date = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0)
    }
}

/// Optional preparation for current local sources while Relay is running.
@Observable @MainActor
final class PreparationScheduler {
    private(set) var enabled = false
    private(set) var hour = 9
    private(set) var minute = 0
    private(set) var lastPreparedAt: Date?
    private(set) var status = "Scheduled preparation is off. Nothing runs automatically."
    private(set) var errorMessage: String?
    var isBusy: () -> Bool = { false }
    var prepare: (() throws -> String)?
    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private let automaticTimers: Bool
    @ObservationIgnored private let lowPower: () -> Bool
    @ObservationIgnored private let thermalLimited: () -> Bool
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let systemTimeZone: () -> TimeZone
    @ObservationIgnored private let onExternalPower: () -> Bool
    @ObservationIgnored private let scheduledWakeDates: () -> [Date]?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var lastHandledDay: String?
    @ObservationIgnored private var lastOutcome: Outcome?
    private enum Outcome: String, Codable { case reserved, prepared, missed, failed }
    private struct Saved: Codable {
        let version: Int
        let enabled: Bool
        let hour: Int
        let minute: Int
        let lastHandledDay: String?
        let lastOutcome: Outcome?
        let lastPreparedAt: Date?
    }

    init(
        persistenceURL: URL? = nil, automaticTimers: Bool = true,
        lowPower: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        clock: @escaping () -> Date = { Date() },
        systemTimeZone: @escaping () -> TimeZone = { .autoupdatingCurrent },
        thermalLimited: @escaping () -> Bool = PreparationWakeSystem.isThermallyLimited,
        onExternalPower: @escaping () -> Bool = PreparationWakeSystem.isOnExternalPower,
        scheduledWakeDates: @escaping () -> [Date]? = PreparationWakeSystem.scheduledDates
    ) {
        self.persistenceURL = persistenceURL
        self.automaticTimers = automaticTimers
        self.lowPower = lowPower
        self.clock = clock
        self.systemTimeZone = systemTimeZone
        self.thermalLimited = thermalLimited
        self.onExternalPower = onExternalPower
        self.scheduledWakeDates = scheduledWakeDates
        restore()
    }
    /// Called only after the owner has restored/revalidated source scope and installed callbacks.
    func activateSavedPreference() { if enabled { startTimer() } }
    func setEnabled(_ value: Bool) {
        enabled = value
        errorMessage = nil
        if value { status = "On while Relay is open. Uses this Mac's current time zone."; startTimer() }
        else { stopTimer(); status = "Scheduled preparation is off. Nothing runs automatically." }
        persist()
    }
    func setTime(hour: Int, minute: Int) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw RelayError.message("Choose an hour from 0–23 and minute from 0–59.") }
        self.hour = hour; self.minute = minute
        status = enabled ? "Preparation time updated. At most one automatic brief per local day." : "Time saved. Scheduled preparation remains off."
        if persist(), enabled, automaticTimers { evaluateSchedule() }
    }
    func tick(now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) {
        guard enabled, !isPreparing, !sleeping else { return }
        do {
            switch try DailyPreparationPolicy.decision(now: now, hour: hour, minute: minute, lastHandledDay: lastHandledDay, timeZone: timeZone) {
            case .waiting: status = "Waiting for today's local preparation time. Relay must stay open."
            case .clockMovedBack:
                status = "This Mac’s date is before the last handled day. Automatic preparation is paused; manual preparation remains available."
            case .handled:
                status = lastOutcome == .prepared ? "Today's automatic source brief is already prepared." : "Today's window was already handled. You can prepare a brief manually."
            case .missed:
                lastHandledDay = DailyPreparationPolicy.dayKey(now, timeZone: timeZone); lastOutcome = .missed
                status = "Today's six-hour preparation window passed. Prepare manually or wait for tomorrow."
                persist()
            case .due(let day):
                guard !isBusy() else { status = "Waiting for the current task, voice input or indexing to finish."; return }
                guard !lowPower() else { status = "Preparation paused in Low Power Mode. Nothing was prepared."; return }
                guard !thermalLimited() else { status = "Preparation is waiting for this Mac to cool down."; return }
                guard let prepare else { status = "Preparation is not connected to selected sources."; return }
                let priorDay = lastHandledDay
                let priorOutcome = lastOutcome
                lastHandledDay = day; lastOutcome = .reserved
                guard persist() else {
                    lastHandledDay = priorDay; lastOutcome = priorOutcome
                    status = "Automatic preparation paused because its run reservation could not be saved. Try manual preparation or check local storage."
                    return
                }
                isPreparing = true
                defer { isPreparing = false }
                do {
                    let summary = try prepare()
                    lastHandledDay = day; lastOutcome = .prepared; lastPreparedAt = now
                    status = (enabled ? "Source brief prepared. " : "Scheduling is off. A source brief completed before it was disabled. ") + String(summary.prefix(200))
                    errorMessage = nil
                    persist()
                } catch {
                    lastHandledDay = day; lastOutcome = .failed
                    status = "Automatic preparation failed. Inspect sources and try the manual button."
                    errorMessage = error.localizedDescription
                    persist()
                }
            }
        } catch { status = "Preparation could not determine its next run."; errorMessage = error.localizedDescription }
    }

    func wakeSetup() -> PreparationWakeSetup {
        PreparationWakeSetup.make(now: clock(), timeZone: systemTimeZone(), hour: hour, minute: minute,
                                  lastHandledDay: lastHandledDay, enabled: enabled,
                                  onExternalPower: onExternalPower(), powerLimited: lowPower() || thermalLimited(),
                                  scheduledDates: scheduledWakeDates())
    }

    func systemWillSleep() { sleeping = true }

    func systemDidWake() {
        sleeping = false
        evaluateSchedule()
    }

    private func evaluateSchedule() { tick(now: clock(), timeZone: systemTimeZone()) }

    private func startTimer() {
        guard automaticTimers, timer == nil, enabled else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, on: workspace) { $0.systemWillSleep() }
        observe(NSWorkspace.didWakeNotification, on: workspace) { $0.systemDidWake() }
        for name in [
            Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
            .NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
            NSApplication.didBecomeActiveNotification
        ] {
            observe(name, on: .default) { $0.evaluateSchedule() }
        }
        // The saved opt-in is explicit. This checks only an already-enabled schedule.
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.enabled, !Task.isCancelled else { return }
                self.evaluateSchedule()
            }
        }
        evaluateSchedule()
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter,
                         perform action: @escaping @MainActor @Sendable (PreparationScheduler) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    private func stopTimer() {
        timer?.cancel(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        sleeping = false
    }
    @discardableResult private func persist() -> Bool {
        guard let persistenceURL else { return true }
        do {
            let saved = Saved(version: 1, enabled: enabled, hour: hour, minute: minute, lastHandledDay: lastHandledDay, lastOutcome: lastOutcome, lastPreparedAt: lastPreparedAt)
            let data = try JSONEncoder().encode(saved)
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try LocalPrivateFileWriter.write(data: data, to: persistenceURL, maximumBytes: 8_192)
            return true
        } catch { errorMessage = "This schedule change could not be saved. Current-session state is shown; settings may differ after relaunch. " + error.localizedDescription; return false }
    }
    private func restore() {
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        guard let data = try? LocalStateFile.read(persistenceURL, maximumBytes: 8_192), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == 1, (0...23).contains(saved.hour), (0...59).contains(saved.minute),
              saved.lastHandledDay == nil || DailyPreparationPolicy.validDayKey(saved.lastHandledDay!),
              saved.lastPreparedAt == nil || saved.lastPreparedAt!.timeIntervalSinceReferenceDate.isFinite else {
            status = "Saved schedule could not be read safely. Preparation remains off."; return
        }
        enabled = saved.enabled; hour = saved.hour; minute = saved.minute
        lastHandledDay = saved.lastHandledDay; lastOutcome = saved.lastOutcome; lastPreparedAt = saved.lastPreparedAt
        status = enabled ? "Saved schedule is on; it starts only after selected sources are restored." : "Scheduled preparation is off."
    }
    isolated deinit { stopTimer() }
}
