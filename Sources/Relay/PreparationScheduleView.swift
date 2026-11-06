import AppKit
import SwiftUI

struct PreparationScheduleView: View {
    @Bindable var scheduler: PreparationScheduler
    let suggestionsEnabled: Bool
    @State private var showsWakeSetup = false
    @State private var wakeSetup: PreparationWakeSetup?
    @State private var wakeFeedback: String?

    var body: some View {
        DisclosureGroup("Prepare a brief each day · optional") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Schedule a local source brief", isOn: Binding(get: { scheduler.enabled }, set: { scheduler.setEnabled($0) }))
                    .disabled(!suggestionsEnabled)
                Text("Prepares quotations from your selected sources while Relay is open, using this Mac’s current time zone. Enable source suggestions first.")
                    .font(.system(size: 14)).lineSpacing(4)
                HStack {
                    Text("Around")
                    Picker("Hour", selection: Binding(get: { scheduler.hour }, set: { try? scheduler.setTime(hour: $0, minute: scheduler.minute) })) {
                        ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) }
                    }.frame(width: 90)
                    Text(":")
                    Picker("Minute", selection: Binding(get: { scheduler.minute }, set: { try? scheduler.setTime(hour: scheduler.hour, minute: $0) })) {
                        ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) }
                    }.frame(width: 100)
                }.font(.system(size: 15))
                Text("A missed run can catch up within six hours after wake or launch. Busy tasks, Low Power Mode and high temperatures can delay it. Relay makes one automatic attempt per local day. Use the manual button to retry.")
                    .font(.system(size: 14)).lineSpacing(4)
                Text("While scheduling stays enabled, today’s cards rebuild from current authorized index records when Relay reopens. Source changes can remove cards; prepare manually after reindexing.").font(.system(size: 14)).lineSpacing(4)
                Text(scheduler.status).font(.system(size: 14))
                if let date = scheduler.lastPreparedAt { Text("Last prepared: \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 14)) }
                if let error = scheduler.errorMessage { Text(error).font(.system(size: 14)).textSelection(.enabled) }
                wakeDisclosure
            }.padding(.top, 12)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentGold))
    }

    private var wakeDisclosure: some View {
        DisclosureGroup("Wake the Mac for the next brief", isExpanded: $showsWakeSetup) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Plan one wake from sleep on a supported Mac. Keep Relay open, stay logged in and leave your Mac connected to power. macOS controls whether the Mac wakes and when it returns to sleep.")
                Text("Review the date below before running the command in Terminal with administrator authorization. Turning off preparation leaves any existing macOS wake request in place until you cancel it.")
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
