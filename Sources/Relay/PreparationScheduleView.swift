import SwiftUI

struct PreparationScheduleView: View {
    @Bindable var scheduler: PreparationScheduler
    let suggestionsEnabled: Bool
    var body: some View {
        DisclosureGroup("Prepare a brief each day · optional") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Schedule a local source brief", isOn: Binding(get: { scheduler.enabled }, set: { scheduler.setEnabled($0) }))
                    .disabled(!suggestionsEnabled)
                Text("Runs while Relay is open, in this Mac’s current time zone. It prepares source quotations only: no model calls, internet, app control or messages. Nothing wakes your Mac. Enable source suggestions first.")
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
                Text("A missed run can catch up within six hours after wake or launch. Busy tasks and Low Power Mode delay it. At most one reserved attempt per local day; use the manual button to retry.")
                    .font(.system(size: 14)).lineSpacing(4)
                Text("While scheduling stays enabled, today’s cards rebuild from current authorized index records when Relay reopens. Source changes can remove cards; prepare manually after reindexing.").font(.system(size: 14)).lineSpacing(4)
                Text(scheduler.status).font(.system(size: 14))
                if let date = scheduler.lastPreparedAt { Text("Last prepared: \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 14)) }
                if let error = scheduler.errorMessage { Text(error).font(.system(size: 14)).textSelection(.enabled) }
            }.padding(.top, 12)
        }.font(.system(size: 15)).foregroundStyle(.white)
    }
}
