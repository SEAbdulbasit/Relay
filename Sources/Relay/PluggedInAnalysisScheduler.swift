import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import Observation

// MARK: - User Presence & Power State Monitors

nonisolated enum UserPresenceMonitor {
    /// Seconds since the last HID input event (mouse, trackpad, keyboard, scroll) in the active GUI session.
    static func systemIdleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    @MainActor
    static var isRelayFrontmost: Bool {
        NSApplication.shared.isActive
    }
}

nonisolated enum AnalysisPowerState {
    enum Block: String, Codable, Sendable, Equatable {
        case onBattery = "on_battery"
        case lowBattery = "low_battery"
        case lowPowerMode = "low_power_mode"
        case thermal = "thermal_pressure"
        case unknownPower = "unknown_power"

        var summary: String {
            switch self {
            case .onBattery: "Paused on battery power — connect to AC power to resume."
            case .lowBattery: "Waiting for battery charge to reach at least 15% on AC power."
            case .lowPowerMode: "Paused while macOS Low Power Mode is enabled."
            case .thermal: "Paused while Mac thermal pressure is elevated."
            case .unknownPower: "Waiting for macOS to report the power source."
            }
        }
    }

    struct Snapshot: Sendable, Equatable {
        let onACPower: Bool
        let batteryPercent: Int?
        let lowPowerMode: Bool
        let thermalState: ProcessInfo.ThermalState
        var powerKnown: Bool = true

        var block: Block? {
            if !powerKnown { return .unknownPower }
            if !onACPower { return .onBattery }
            if lowPowerMode { return .lowPowerMode }
            if thermalState == .serious || thermalState == .critical { return .thermal }
            if let batteryPercent, batteryPercent < 15 { return .lowBattery }
            return nil
        }

        var isHealthyForAnalysis: Bool {
            block == nil
        }
    }

    static func currentSnapshot() -> Snapshot {
        let powerInfo = readIOPowerInfo()
        return Snapshot(
            onACPower: powerInfo.onAC,
            batteryPercent: powerInfo.percent,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState,
            powerKnown: powerInfo.known
        )
    }

    private static func readIOPowerInfo() -> (onAC: Bool, percent: Int?, known: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return (false, nil, false)
        }
        guard let state = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?,
              state == kIOPSACPowerValue as String || state == kIOPSBatteryPowerValue as String else {
            return (false, nil, false)
        }
        let onAC = (state == kIOPSACPowerValue as String)

        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return (onAC, nil, true)
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
                  let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int,
                  maxCap > 0 else { continue }
            let pct = Int((Double(current) / Double(maxCap) * 100.0).rounded())
            return (onAC, max(0, min(100, pct)), true)
        }
        return (onAC, nil, true)
    }
}

// MARK: - Plugged-In Idle Analysis Scheduler (ING-05, TRI-07, OVR-09)

@Observable @MainActor
final class PluggedInAnalysisScheduler {
    static let interval: TimeInterval = 4 * 60 * 60          // 4 hours between completed cycles
    static let idleSeconds: TimeInterval = 270               // 4.5 minutes of system HID idleness
    static let failureRetryInterval: TimeInterval = 15 * 60  // 15 minutes backoff after transient error
    static let maximumPersistedRuns = 25
    static let maximumRunSeconds: TimeInterval = 20 * 60

    nonisolated enum RunOutcome: String, Codable, Sendable, Equatable {
        case completed
        case pausedForActivity = "paused_for_activity"
        case pausedOnBattery = "paused_on_battery"
        case pausedForThermal = "paused_for_thermal"
        case pausedForSleep = "paused_for_sleep"
        case pausedForForegroundTask = "paused_for_foreground_task"
        case stopped
        case failed
        case timedOut = "timed_out"
    }

    nonisolated struct RunSummary: Codable, Sendable, Equatable {
        var itemsIngested: Int
        var vaultNotesUpdated: Int
        var proactiveCardsPrepared: Int

        init(itemsIngested: Int = 0, vaultNotesUpdated: Int = 0, proactiveCardsPrepared: Int = 0) {
            self.itemsIngested = itemsIngested
            self.vaultNotesUpdated = vaultNotesUpdated
            self.proactiveCardsPrepared = proactiveCardsPrepared
        }
    }

    nonisolated struct RunRecord: Codable, Identifiable, Sendable, Equatable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let activeSeconds: TimeInterval
        let outcome: RunOutcome
        let summary: RunSummary
        let message: String?
    }

    nonisolated private struct PersistedState: Codable, Sendable {
        static let currentVersion = 1
        var version = Self.currentVersion
        var enabled: Bool = false
        var lastStartedAt: Date?
        var lastCompletedAt: Date?
        var retryAfter: Date?
        var awaitingIdleContinuation: Bool = false
        var interruptedRun: Bool?
        var recentRuns: [RunRecord] = []
    }

    private(set) var enabled: Bool = false
    private(set) var isRunningCycle: Bool = false
    private(set) var lastStartedAt: Date?
    private(set) var lastCompletedAt: Date?
    private(set) var retryAfter: Date?
    private(set) var awaitingIdleContinuation: Bool = false
    private(set) var recentRuns: [RunRecord] = []
    private(set) var status: String = "Plugged-in background analysis is off."
    private(set) var lastErrorMessage: String?

    /// Invoked during an eligible plugged-in idle window (or manual run).
    /// Implementations should cooperate with `Task.checkCancellation()` at item/slice boundaries.
    @ObservationIgnored var runCycle: (@MainActor () async throws -> RunSummary)?
    /// Returns true when an interactive foreground assistant turn, voice capture, or speech session is active.
    @ObservationIgnored var interactionBusy: () -> Bool = { false }

    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private let automaticPolling: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let powerProvider: () -> AnalysisPowerState.Snapshot
    @ObservationIgnored private let idleSecondsProvider: () -> TimeInterval
    @ObservationIgnored private let acquireSleepActivity: (String) -> (() -> Void)
    @ObservationIgnored private let waitForRunLimit: () async throws -> Void
    @ObservationIgnored private var runLimitTask: Task<Void, Never>?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activeRunTask: Task<Void, Never>?
    @ObservationIgnored private var activeRunStartedAt: Date?
    @ObservationIgnored private var pendingSuspensionReason: RunOutcome?
    @ObservationIgnored private var releaseSleepActivity: (() -> Void)?
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    static var defaultPersistenceURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Relay", directoryHint: .isDirectory)
            .appending(path: "plugged-in-analysis.json")
    }

    init(
        persistenceURL: URL? = PluggedInAnalysisScheduler.defaultPersistenceURL,
        automaticPolling: Bool = true,
        now: @escaping () -> Date = Date.init,
        powerProvider: @escaping () -> AnalysisPowerState.Snapshot = AnalysisPowerState.currentSnapshot,
        idleSecondsProvider: @escaping () -> TimeInterval = UserPresenceMonitor.systemIdleSeconds,
        acquireSleepActivity: ((String) -> (() -> Void))? = nil,
        waitForRunLimit: (() async throws -> Void)? = nil
    ) {
        self.persistenceURL = persistenceURL
        self.automaticPolling = automaticPolling
        self.now = now
        self.powerProvider = powerProvider
        self.idleSecondsProvider = idleSecondsProvider
        self.acquireSleepActivity = acquireSleepActivity ?? { _ in
            // macOS releases this assertion at its deadline even if Relay's
            // executor stalls before the cooperative watchdog can run.
            PreparationWakeSystem.holdIdleSleep(for: Self.maximumRunSeconds) ?? {}
        }
        self.waitForRunLimit = waitForRunLimit ?? {
            try await Task.sleep(for: .seconds(Self.maximumRunSeconds))
        }
        restore()
        updateIdleStatusMessage()
        observeSystemSleep()
        if automaticPolling {
            start()
        }
    }

    var isPolling: Bool {
        pollTask != nil
    }

    func start() {
        guard pollTask == nil else { return }
        // Holds ZERO sleep/wake assertions while waiting; checks lightweight OS state once per second.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.evaluateTick()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if isRunningCycle {
            suspendActiveCycle(reason: .stopped)
        }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value, isRunningCycle, !activeCycleIsManual {
            suspendActiveCycle(reason: .stopped)
        }
        if !isRunningCycle {
            updateIdleStatusMessage()
        }
        persist()
    }

    /// Triggers an immediate manual cycle on user request (does not require 270s idle wait or AC power).
    func runManualCycleNow() {
        guard !isRunningCycle else { return }
        guard !sleeping else {
            status = "Paused while this Mac is sleeping. Try again after wake."
            return
        }
        let power = powerProvider()
        guard power.thermalState != .serious, power.thermalState != .critical else {
            status = AnalysisPowerState.Block.thermal.summary
            return
        }
        guard !interactionBusy() else {
            status = "Waiting for active foreground session to finish."
            return
        }
        beginCycle(manual: true)
    }

    func cancelCurrentCycle() {
        guard isRunningCycle else { return }
        suspendActiveCycle(reason: .stopped)
    }

    func waitForCurrentCycle() async {
        await activeRunTask?.value
    }

    /// Evaluates one scheduler tick deterministically (used both by the 1s poll loop and unit tests).
    func evaluateTick() {
        guard enabled || isRunningCycle else { return }
        let currentNow = now()
        let power = powerProvider()
        let idle = idleSecondsProvider()

        if isRunningCycle {
            if !enabled, !activeCycleIsManual {
                suspendActiveCycle(reason: .stopped)
                return
            }
            if sleeping {
                suspendActiveCycle(reason: .pausedForSleep)
                return
            }
            if let block = power.block {
                if activeCycleIsManual {
                    if block == .thermal || power.thermalState == .serious || power.thermalState == .critical {
                        suspendActiveCycle(reason: .pausedForThermal)
                        return
                    }
                } else {
                    let outcome: RunOutcome = (block == .thermal) ? .pausedForThermal : .pausedOnBattery
                    suspendActiveCycle(reason: outcome)
                    return
                }
            }
            if interactionBusy() {
                suspendActiveCycle(reason: .pausedForForegroundTask)
                return
            }
            if !activeCycleIsManual, idle < Self.idleSeconds {
                suspendActiveCycle(reason: .pausedForActivity)
                return
            }
            return
        }

        guard enabled else {
            return
        }
        guard !sleeping else {
            status = "Paused while this Mac is sleeping."
            return
        }
        if let block = power.block {
            status = block.summary
            return
        }
        if interactionBusy() {
            status = "Waiting for active foreground session to finish."
            return
        }
        guard isCadenceDue(at: currentNow) else {
            if let next = nextScheduledDate {
                status = "Up to date. Next plugged-in idle check after \(next.formatted(date: .omitted, time: .shortened))."
            }
            return
        }
        guard idle >= Self.idleSeconds else {
            let remaining = Int(ceil(Self.idleSeconds - idle))
            status = awaitingIdleContinuation
                ? "Ready to resume from checkpoint after \(remaining)s of idle time on AC power."
                : "Waiting for Mac to be idle on AC power (\(remaining)s remaining)."
            return
        }

        beginCycle(manual: false)
    }

    func handleWillSleep() {
        sleeping = true
        if isRunningCycle {
            suspendActiveCycle(reason: .pausedForSleep)
        } else {
            updateIdleStatusMessage()
        }
    }

    func handleDidWake() {
        sleeping = false
        updateIdleStatusMessage()
        evaluateTick()
    }

    func drainAndReset() async {
        pollTask?.cancel()
        pollTask = nil
        if let task = activeRunTask {
            task.cancel()
            _ = await task.result
        }
        endSleepActivity()
        enabled = false
        isRunningCycle = false
        activeCycleIsManual = false
        activeRunTask = nil
        activeRunStartedAt = nil
        pendingSuspensionReason = nil
        lastStartedAt = nil
        lastCompletedAt = nil
        retryAfter = nil
        awaitingIdleContinuation = false
        recentRuns.removeAll()
        lastErrorMessage = nil
        if let persistenceURL {
            try? FileManager.default.removeItem(at: persistenceURL)
        }
        status = "Plugged-in background analysis reset."
        if automaticPolling {
            start()
        }
    }

    // Successful cycles wait a full interval after completion. Explicit Stop
    // has its own durable suppression deadline instead of moving this anchor.
    private var cadenceAnchor: Date? { lastCompletedAt ?? lastStartedAt }

    var nextScheduledDate: Date? {
        if let retryAfter {
            return retryAfter
        }
        if awaitingIdleContinuation {
            return now()
        }
        if let base = cadenceAnchor {
            return base.addingTimeInterval(Self.interval)
        }
        return enabled ? now() : nil
    }

    // MARK: - Internal Execution Mechanics

    @ObservationIgnored private var activeCycleIsManual = false

    private func isCadenceDue(at currentNow: Date) -> Bool {
        if let retryAfter, currentNow < retryAfter {
            return false
        }
        // Interrupted cycles resume immediately on the next eligible AC + idle window!
        if awaitingIdleContinuation {
            return true
        }
        guard let anchor = cadenceAnchor else {
            return true
        }
        return currentNow.timeIntervalSince(anchor) >= Self.interval
    }

    private func beginCycle(manual: Bool) {
        guard let runner = runCycle else {
            let msg = "No background analysis pipeline is attached yet."
            lastErrorMessage = msg
            status = msg
            return
        }
        let start = now()
        isRunningCycle = true
        activeCycleIsManual = manual
        activeRunStartedAt = start
        pendingSuspensionReason = nil
        lastStartedAt = start
        retryAfter = nil
        lastErrorMessage = nil
        if manual {
            status = awaitingIdleContinuation
                ? "Resuming manual analysis from exact checkpoint…"
                : "Running manual source ingestion & vault consolidation…"
        } else {
            status = awaitingIdleContinuation
                ? "Resuming background analysis from exact checkpoint…"
                : "Running plugged-in source ingestion & vault consolidation…"
        }
        guard persist() || manual else {
            isRunningCycle = false
            activeCycleIsManual = false
            activeRunStartedAt = nil
            awaitingIdleContinuation = true
            status = "Background analysis could not save its run checkpoint. Check local storage, then retry."
            return
        }

        releaseSleepActivity = acquireSleepActivity("Relay plugged-in background analysis")

        activeRunTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let summary = try await runner()
                try Task.checkCancellation()
                self.finishCycle(outcome: .completed, summary: summary, errorMessage: nil)
            } catch is CancellationError {
                let reason = self.pendingSuspensionReason ?? .pausedForActivity
                self.finishCycle(outcome: reason, summary: .init(), errorMessage: nil)
            } catch {
                if Task.isCancelled, let reason = self.pendingSuspensionReason {
                    self.finishCycle(outcome: reason, summary: .init(), errorMessage: nil)
                } else {
                    self.finishCycle(outcome: .failed, summary: .init(), errorMessage: error.localizedDescription)
                }
            }
        }
        runLimitTask = Task { @MainActor [weak self, waitForRunLimit] in
            do {
                try await waitForRunLimit()
                try Task.checkCancellation()
                self?.suspendActiveCycle(reason: .timedOut)
            } catch { return }
        }
    }

    private func suspendActiveCycle(reason: RunOutcome) {
        guard isRunningCycle else { return }
        // A user's Stop remains terminal while an uncooperative callback drains.
        // Repeated polling must not turn it into an automatically resumable pause.
        if pendingSuspensionReason == .stopped { return }
        if pendingSuspensionReason != nil, reason != .stopped { return }
        pendingSuspensionReason = reason
        if reason == .stopped {
            awaitingIdleContinuation = false
            retryAfter = now().addingTimeInterval(Self.interval)
        } else {
            awaitingIdleContinuation = true
        }
        endSleepActivity()
        activeRunTask?.cancel()
        status = switch reason {
        case .pausedForActivity:
            "Paused immediately on user activity — will resume from exact checkpoint when idle."
        case .pausedOnBattery:
            "Paused immediately on battery power — will resume from exact checkpoint when plugged in."
        case .pausedForThermal:
            "Paused for thermal protection — will resume from exact checkpoint when cool."
        case .pausedForSleep:
            "Paused for system sleep — will resume from exact checkpoint after wake."
        case .pausedForForegroundTask:
            "Yielded to foreground assistant task — will resume when idle."
        case .timedOut:
            "Stopping analysis because it reached its 20-minute time limit. Waiting for the current operation to settle."
        default:
            "Stopping analysis…"
        }
        persist()
    }

    private func finishCycle(outcome: RunOutcome, summary: RunSummary, errorMessage: String?) {
        let ended = now()
        let started = activeRunStartedAt ?? ended
        let elapsed = max(0, ended.timeIntervalSince(started))
        let wasManual = activeCycleIsManual

        endSleepActivity()
        isRunningCycle = false
        activeCycleIsManual = false
        activeRunTask = nil
        activeRunStartedAt = nil
        pendingSuspensionReason = nil

        switch outcome {
        case .completed:
            awaitingIdleContinuation = false
            lastCompletedAt = ended
            retryAfter = nil
            lastErrorMessage = nil
            status = "Completed analysis (\(summary.itemsIngested) source item(s), \(summary.vaultNotesUpdated) vault note(s))."
        case .pausedForActivity, .pausedOnBattery, .pausedForThermal, .pausedForSleep, .pausedForForegroundTask:
            awaitingIdleContinuation = true
        case .stopped:
            awaitingIdleContinuation = false
            retryAfter = ended.addingTimeInterval(Self.interval)
            status = (enabled || wasManual) ? "Analysis stopped." : "Plugged-in background analysis is off."
        case .failed, .timedOut:
            let trimmed = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanError = (trimmed?.isEmpty == false) ? trimmed! : (outcome == .timedOut ? "Analysis reached its 20-minute time limit." : "Analysis failed.")
            lastErrorMessage = cleanError
            if enabled {
                awaitingIdleContinuation = true
                retryAfter = ended.addingTimeInterval(Self.failureRetryInterval)
                status = "Analysis paused after an error (\(cleanError)); will retry when plugged in and idle."
            } else {
                awaitingIdleContinuation = false
                status = "Analysis failed: \(cleanError)"
            }
        }

        let record = RunRecord(
            id: UUID(),
            startedAt: started,
            endedAt: ended,
            activeSeconds: elapsed,
            outcome: outcome,
            summary: summary,
            message: lastErrorMessage
        )
        recentRuns.insert(record, at: 0)
        if recentRuns.count > Self.maximumPersistedRuns {
            recentRuns = Array(recentRuns.prefix(Self.maximumPersistedRuns))
        }
        persist()
    }

    private func endSleepActivity() {
        runLimitTask?.cancel()
        runLimitTask = nil
        releaseSleepActivity?()
        releaseSleepActivity = nil
    }

    private func updateIdleStatusMessage() {
        guard !isRunningCycle else { return }
        if !enabled {
            status = "Plugged-in background analysis is off."
        } else if awaitingIdleContinuation {
            status = "Paused at checkpoint — will automatically resume when plugged in and idle."
        } else if let lastCompletedAt {
            status = "Last completed \(lastCompletedAt.formatted(date: .abbreviated, time: .shortened)). Runs every 4 hours when plugged in and idle."
        } else {
            status = "Enabled — runs automatically when plugged into AC power and idle for 4.5 minutes."
        }
    }

    private func observeSystemSleep() {
        let center = NSWorkspace.shared.notificationCenter
        let sleepToken = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        let wakeToken = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        }
        workspaceObservers = [sleepToken, wakeToken]
    }

    isolated deinit {
        pollTask?.cancel()
        activeRunTask?.cancel()
        runLimitTask?.cancel()
        releaseSleepActivity?()
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }
    }

    private func restore() {
        guard let persistenceURL,
              let data = try? LocalStateFile.read(persistenceURL, maximumBytes: 1_048_576),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.version == PersistedState.currentVersion else { return }
        enabled = state.enabled
        lastStartedAt = state.lastStartedAt
        lastCompletedAt = state.lastCompletedAt
        retryAfter = state.retryAfter
        awaitingIdleContinuation = state.awaitingIdleContinuation || state.interruptedRun == true
        recentRuns = state.recentRuns
    }

    @discardableResult private func persist() -> Bool {
        guard let persistenceURL else { return true }
        let dir = persistenceURL.deletingLastPathComponent()
        let state = PersistedState(
            enabled: enabled,
            lastStartedAt: lastStartedAt,
            lastCompletedAt: lastCompletedAt,
            retryAfter: retryAfter,
            awaitingIdleContinuation: awaitingIdleContinuation,
            interruptedRun: isRunningCycle && pendingSuspensionReason != .stopped,
            recentRuns: recentRuns
        )
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(state)
            try LocalPrivateFileWriter.write(data: data, to: persistenceURL, maximumBytes: 1_048_576)
            return true
        } catch {
            lastErrorMessage = "Background analysis settings or checkpoint could not be saved. Changes may not survive relaunch. " + error.localizedDescription
            return false
        }
    }
}
