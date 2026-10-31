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
        let start = calendar.startOfDay(for: now)
        guard let scheduled = calendar.nextDate(after: start.addingTimeInterval(-1), matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
              calendar.isDate(scheduled, inSameDayAs: now) else { throw RelayError.message("Today's local preparation time could not be determined.") }
        if now < scheduled { return .waiting }
        if now.timeIntervalSince(scheduled) > 6 * 3600 { return .missed }
        return .due(day: day)
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

/// Optional app-running preparation only. Never wakes the Mac, launches other apps, runs
/// a model, connects to the network or dispatches computer actions.
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
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
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

    init(persistenceURL: URL? = nil, automaticTimers: Bool = true, lowPower: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }, clock: @escaping () -> Date = { Date() }) {
        self.persistenceURL = persistenceURL
        self.automaticTimers = automaticTimers
        self.lowPower = lowPower
        self.clock = clock
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
        persist()
    }
    func tick(now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) {
        guard enabled, !isPreparing else { return }
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
    private func startTimer() {
        guard automaticTimers, timer == nil, enabled else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in if let self { self.tick(now: self.clock()) } }
        }
        // The saved opt-in is explicit. This checks only an already-enabled schedule.
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.enabled, !Task.isCancelled else { return }
                self.tick(now: self.clock())
            }
        }
        tick(now: clock())
    }
    private func stopTimer() {
        timer?.cancel(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
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
    isolated deinit {
        timer?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
