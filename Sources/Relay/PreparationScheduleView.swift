import AppKit
import SwiftUI

struct PreparationScheduleView: View {
    @Bindable var scheduler: PreparationScheduler
    let suggestionsEnabled: Bool
    var pluggedInScheduler: PluggedInAnalysisScheduler? = nil
    @State private var showsWakeSetup = false
    @State private var wakeSetup: PreparationWakeSetup?
    @State private var wakeFeedback: String?
    @State private var scheduleError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let pluggedInScheduler {
                PluggedInAnalysisScheduleView(scheduler: pluggedInScheduler)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RelayIconBadge(icon: "sun.horizon.fill", color: RelayColors.accentGold, size: 38, iconSize: 17)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Daily Morning Brief Schedule")
                            .font(.relayHeadline)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text(suggestionsEnabled ? "Relay prepares your daily brief locally at the scheduled hour while the app is open." : "Turn on proactive suggestions above to schedule a daily Morning Brief.")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    Spacer()
                    Toggle("Schedule Morning Brief", isOn: Binding(get: { scheduler.enabled }, set: { scheduler.setEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!suggestionsEnabled)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Scheduled local time")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                        Spacer()
                        Picker("Hour", selection: Binding(
                            get: { scheduler.hour },
                            set: { newHour in
                                do {
                                    try scheduler.setTime(hour: newHour, minute: scheduler.minute)
                                    scheduleError = nil
                                } catch {
                                    scheduleError = error.localizedDescription
                                }
                            }
                        )) {
                            ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 68)
                        Text(":").font(.relayMono).accessibilityHidden(true)
                        Picker("Minute", selection: Binding(
                            get: { scheduler.minute },
                            set: { newMinute in
                                do {
                                    try scheduler.setTime(hour: scheduler.hour, minute: newMinute)
                                    scheduleError = nil
                                } catch {
                                    scheduleError = error.localizedDescription
                                }
                            }
                        )) {
                            ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 68)
                    }
                    .disabled(!suggestionsEnabled || scheduler.isPreparing)

                    scheduleStatus
                }
                .padding(14)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )

                DisclosureGroup("Morning Brief options & wake schedule") {
                    VStack(alignment: .leading, spacing: 16) {
                        refreshScope
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Include selected calendars", isOn: Binding(
                                get: { !scheduler.calendarRefreshIDs.isEmpty },
                                set: { scheduler.setCalendarRefreshEnabled($0) }
                            ))
                            .toggleStyle(.switch)
                            .font(.relayBodyStrong)
                            .disabled(!suggestionsEnabled || scheduler.eligibleCalendarRefreshIDs().isEmpty)
                            detail("Choose calendars in Settings → Sources. Their next seven days appear in this session only.")
                        }
                        if scheduler.usesEnhancedPreparation {
                            Button("Refresh and prepare now") { scheduler.refreshNow() }
                                .buttonStyle(RelaySecondaryButtonStyle())
                                .disabled(!suggestionsEnabled || scheduler.isBusy() || scheduler.isPreparing)
                        }
                        Divider().overlay(RelayTheme.line)
                        MorningBriefNotificationView(notifications: scheduler.notifications)
                        wakeDisclosure
                    }
                    .padding(.top, 12)
                }
                .font(.relayBodyStrong)
                .foregroundStyle(RelayColors.textPrimary)
                .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentGold))
            }
            .padding(20)
            .relayGlassCard(cornerRadius: RelayTheme.radius)
        }
    }

    private var scheduleStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if scheduler.isPreparing { ProgressView().controlSize(.small).accessibilityHidden(true) }
                detail(scheduler.status)
            }
            if scheduler.enabled {
                detail("Relay can catch up within six hours of the scheduled time after a pause, wake, or relaunch.")
            }
            if let date = scheduler.lastPreparedAt {
                detail("Last prepared \(date.formatted(date: .abbreviated, time: .shortened))")
            }
            if let error = scheduleError ?? scheduler.errorMessage {
                Text(error).font(.relayCaption).foregroundStyle(RelayColors.accentCoral).textSelection(.enabled)
            }
            if scheduler.isPreparing {
                Button("Stop preparation") { scheduler.cancelCurrentPreparation() }
                    .buttonStyle(RelaySecondaryButtonStyle())
            }
        }
    }

    private var refreshScope: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Refresh sources").font(.relayBody.weight(.semibold))
            let sources = scheduler.eligibleRefreshSources()
            if sources.isEmpty {
                detail("Index a source to choose it for scheduled refresh.")
            } else {
                detail("Relay checks whether indexed files are still current. Choose which sources to reindex on schedule. Selected folders can add new supported files.")
            }
            ForEach(sources) { source in
                Toggle(isOn: Binding(get: { scheduler.refreshGrantIDs.contains(source.id) },
                                     set: { scheduler.setRefreshSource(source.id, enabled: $0) })) {
                    Text(source.path).lineLimit(1).truncationMode(.middle)
                }
                .help(source.path)
                .disabled(!suggestionsEnabled)
            }
        }
    }

    private func detail(_ value: String) -> some View {
        Text(value).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var wakeDisclosure: some View {
        DisclosureGroup("Wake this Mac for preparation", isExpanded: $showsWakeSetup) {
            VStack(alignment: .leading, spacing: 9) {
                if let managed = scheduler.managedWake {
                    managedWakeControls(managed)
                    Divider()
                }
                detail("Plan one wake from sleep. Keep Relay open and the Mac connected to power. During a scheduled source refresh, Relay can delay idle sleep for up to 20 minutes.")
                detail("Review the date before running the command in Terminal with administrator authorization. Use the cancellation command to remove a pending wake.")
                if let wakeSetup {
                    Text(wakeSetup.status)
                        .accessibilityIdentifier("preparation.wakeStatus")
                    if let request = wakeSetup.request {
                        wakeCommand(request, cancel: false)
                    }
                    ForEach(wakeSetup.pending, id: \.self) { date in
                        if let cancel = wakeSetup.cancellations.first(where: { $0.date == date }) {
                            wakeCommand(cancel, cancel: true)
                        } else {
                            Text("Pending wake at \(date.formatted(date: .abbreviated, time: .shortened)). This local time is ambiguous, so Relay can’t prepare an exact cancellation.")
                        }
                    }
                }
                Button("Check macOS wake schedule") { refreshWakeSetup() }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("preparation.refreshWake")
                if let wakeFeedback { Text(wakeFeedback) }
            }
            .font(.relayCaption)
            .padding(.top, 8)
        }
        .onChange(of: showsWakeSetup) { _, expanded in if expanded { refreshWakeSetup() } }
        .onChange(of: scheduler.enabled) { _, _ in if showsWakeSetup { refreshWakeSetup() } }
        .onChange(of: scheduler.hour) { _, _ in if showsWakeSetup { refreshWakeSetup() } }
        .onChange(of: scheduler.minute) { _, _ in if showsWakeSetup { refreshWakeSetup() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if showsWakeSetup { refreshWakeSetup() }
        }
        .accessibilityIdentifier("preparation.wakeSetup")
    }

    private func managedWakeControls(_ managed: ManagedPreparationWake) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detail("Managed wake schedules daily preparation while Relay is open and this Mac is plugged in. macOS may require approval in Login Items.")
            Text(managed.status).accessibilityIdentifier("preparation.managedWakeStatus")
            if !managed.isRequested {
                Button("Set up managed wake") {
                    managed.enable()
                    scheduler.refreshManagedWake()
                }
                .disabled(managed.isRemoving)
                .buttonStyle(RelaySecondaryButtonStyle())
            }
            if managed.requiresApproval {
                Button("Open Login Items") { managed.openLoginItems() }
                    .buttonStyle(RelaySecondaryButtonStyle())
            }
            if managed.isRequested {
                Toggle("Allow scheduled preparation with the lid closed", isOn: Binding(
                    get: { managed.allowsClosedLidPreparation },
                    set: { managed.setClosedLidPreparation($0) }
                ))
                .disabled(managed.isRemoving)
                detail("On power, the wake helper temporarily prevents system sleep for up to 20 minutes while Relay prepares the brief. Normal sleep resumes when preparation ends or you stop it.")
                if let awakeStatus = managed.awakeStatus {
                    Text(awakeStatus).accessibilityIdentifier("preparation.closedLidStatus")
                }
            }
            if managed.canRemove || managed.isRequested {
                Button("Remove wake helper") { Task { await managed.remove() } }
                    .disabled(managed.isRemoving)
                    .buttonStyle(RelaySecondaryButtonStyle())
            }
        }
    }

    private func wakeCommand(_ request: PreparationWakeCommand, cancel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(request.date.formatted(date: .abbreviated, time: .shortened)) · \(TimeZone.autoupdatingCurrent.identifier)")
            Text(request.command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Button(cancel ? "Copy cancellation command" : "Copy wake command") { copy(request, cancel: cancel) }
                .buttonStyle(RelaySecondaryButtonStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
    }

    private func refreshWakeSetup() {
        wakeSetup = scheduler.wakeSetup()
        scheduler.refreshManagedWake()
        wakeFeedback = nil
    }

    private func copy(_ reviewed: PreparationWakeCommand, cancel: Bool) {
        let fresh = scheduler.wakeSetup()
        wakeSetup = fresh
        let stillCurrent = cancel ? fresh.cancellations.contains(reviewed) : fresh.request == reviewed
        guard stillCurrent else {
            wakeFeedback = "The schedule or power state changed. Review the updated information."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        wakeFeedback = pasteboard.setString(reviewed.command, forType: .string)
            ? "Command copied. Check the wake schedule after applying it in Terminal."
            : "The command couldn’t be copied. You can select its text above."
    }
}

@MainActor
struct PluggedInAnalysisScheduleView: View {
    @Bindable var scheduler: PluggedInAnalysisScheduler
    @State private var showRecentRuns = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "bolt.batteryblock.fill", color: RelayColors.accentGold, size: 38, iconSize: 17)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background preparation")
                        .font(.relayHeadline)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Sync selected sources and prepare notes while your Mac is plugged in and idle. Runs at most every 4 hours, after 4.5 minutes of inactivity. Requests a pause when you return or unplug, keeping completed work.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Enable plugged-in idle analysis", isOn: Binding(
                    get: { scheduler.enabled },
                    set: { scheduler.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("pluggedInAnalysis.toggle")
            }

            HStack(spacing: 10) {
                if scheduler.isRunningCycle {
                    ProgressView().controlSize(.small)
                        .accessibilityIdentifier("pluggedInAnalysis.progress")
                    Button("Stop") {
                        scheduler.cancelCurrentCycle()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("pluggedInAnalysis.stop")
                } else {
                    Button("Prepare now") {
                        scheduler.runManualCycleNow()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(scheduler.interactionBusy())
                    .accessibilityIdentifier("pluggedInAnalysis.runNow")
                }
                Text(scheduler.status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pluggedInAnalysis.status")
            }

            if let err = scheduler.lastErrorMessage {
                Text(err)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("pluggedInAnalysis.error")
            }

            Divider().overlay(RelayTheme.line)

            DisclosureGroup(
                scheduler.recentRuns.isEmpty
                    ? "Recent Run History"
                    : "Recent Run History · \(scheduler.recentRuns.count)",
                isExpanded: $showRecentRuns
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if scheduler.recentRuns.isEmpty {
                        Text("No background analysis runs recorded yet.")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textMuted)
                            .padding(.top, 4)
                    } else {
                        ForEach(scheduler.recentRuns.prefix(10)) { run in
                            recentRunRow(run)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.relayBodyStrong)
            .foregroundStyle(RelayColors.textPrimary)
            .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentGold))
            .accessibilityIdentifier("pluggedInAnalysis.recentRuns")
        }
        .padding(20)
        .relayLitCard(accent: RelayColors.accentGold, cornerRadius: RelayTheme.radius)
    }

    private func recentRunRow(_ run: PluggedInAnalysisScheduler.RunRecord) -> some View {
        let badge = outcomeBadge(for: run.outcome)
        let durationSeconds = max(1, Int(run.activeSeconds.rounded()))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.relayCaptionStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                Text("· \(durationSeconds)s")
                    .font(.relayMonoSmall)
                    .foregroundStyle(RelayColors.textMuted)
                Spacer()
                RelayBadge(badge.label, icon: badge.icon, tint: badge.tint, prominent: run.outcome == .completed)
            }
            HStack(spacing: 12) {
                Label("\(run.summary.itemsIngested) items ingested", systemImage: "tray.and.arrow.down")
                Label("\(run.summary.vaultNotesUpdated) notes updated", systemImage: "books.vertical")
                if run.summary.proactiveCardsPrepared > 0 {
                    Label("\(run.summary.proactiveCardsPrepared) cards", systemImage: "sun.horizon")
                }
            }
            .font(.relayCaption)
            .foregroundStyle(RelayColors.textSecondary)

            if let message = run.message, !message.isEmpty {
                Text(message)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
    }

    private func outcomeBadge(for outcome: PluggedInAnalysisScheduler.RunOutcome) -> (label: String, icon: String, tint: Color) {
        switch outcome {
        case .completed:
            return ("Completed", "checkmark.circle.fill", RelayColors.accentEmerald)
        case .pausedForActivity:
            return ("Paused · Activity", "pause.circle.fill", RelayColors.accentAmber)
        case .pausedOnBattery:
            return ("Paused · Battery", "battery.25", RelayColors.accentAmber)
        case .pausedForThermal:
            return ("Paused · Thermal", "thermometer.high", RelayColors.accentAmber)
        case .pausedForSleep:
            return ("Paused · Sleep", "moon.zzz.fill", RelayColors.accentAmber)
        case .pausedForForegroundTask:
            return ("Paused · Foreground", "person.wave.2.fill", RelayColors.accentBlue)
        case .stopped:
            return ("Stopped", "stop.circle", RelayColors.textMuted)
        case .failed:
            return ("Failed", "exclamationmark.triangle.fill", RelayColors.accentCoral)
        case .timedOut:
            return ("Time limit", "clock.badge.exclamationmark", RelayColors.accentAmber)
        }
    }
}
