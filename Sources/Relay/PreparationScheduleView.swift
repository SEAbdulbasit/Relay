import AppKit
import SwiftUI

struct PreparationScheduleView: View {
    @Bindable var scheduler: PreparationScheduler
    let suggestionsEnabled: Bool
    @State private var showsWakeSetup = false
    @State private var wakeSetup: PreparationWakeSetup?
    @State private var wakeFeedback: String?

    var body: some View {
        DisclosureGroup("Morning Brief schedule") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Prepare a daily brief", isOn: Binding(get: { scheduler.enabled }, set: { scheduler.setEnabled($0) }))
                        .toggleStyle(.switch)
                        .disabled(!suggestionsEnabled)
                    detail(suggestionsEnabled ? "Relay prepares the brief on this Mac while the app is running." : "Turn on proactive suggestions to schedule a brief.")
                    HStack(spacing: 8) {
                        Text("Local time")
                        Picker("Hour", selection: Binding(get: { scheduler.hour }, set: { try? scheduler.setTime(hour: $0, minute: scheduler.minute) })) {
                            ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 64)
                        Text(":").accessibilityHidden(true)
                        Picker("Minute", selection: Binding(get: { scheduler.minute }, set: { try? scheduler.setTime(hour: scheduler.hour, minute: $0) })) {
                            ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 64)
                    }
                    .disabled(!suggestionsEnabled || scheduler.isPreparing)
                    scheduleStatus
                }
                refreshScope
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Include selected calendars", isOn: Binding(
                        get: { !scheduler.calendarRefreshIDs.isEmpty },
                        set: { scheduler.setCalendarRefreshEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(!suggestionsEnabled || scheduler.eligibleCalendarRefreshIDs().isEmpty)
                    detail("Choose calendars in Knowledge. Their next seven days appear in this session only.")
                }
                if scheduler.usesEnhancedPreparation {
                    Button("Refresh and prepare now") { scheduler.refreshNow() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(!suggestionsEnabled || scheduler.isBusy() || scheduler.isPreparing)
                }
                Divider()
                MorningBriefNotificationView(notifications: scheduler.notifications)
                wakeDisclosure
            }.padding(.top, 12)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentGold))
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
            if let error = scheduler.errorMessage {
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
        DisclosureGroup("Wake the Mac for the next brief", isExpanded: $showsWakeSetup) {
            VStack(alignment: .leading, spacing: 9) {
                detail("Plan one wake from sleep. Keep Relay open and the Mac connected to power. macOS manages waking and returning to sleep.")
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
            .font(.system(size: 14))
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

    private func wakeCommand(_ request: PreparationWakeCommand, cancel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(request.date.formatted(date: .abbreviated, time: .shortened)) · \(TimeZone.autoupdatingCurrent.identifier)")
            Text(request.command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Button(cancel ? "Copy cancellation command" : "Copy wake command") { copy(request, cancel: cancel) }
                .buttonStyle(RelaySecondaryButtonStyle())
        }
    }

    private func refreshWakeSetup() {
        wakeSetup = scheduler.wakeSetup()
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
