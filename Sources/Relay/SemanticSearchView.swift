import SwiftUI

struct SemanticSearchView: View {
    @Bindable var search: KnowledgeSearchCoordinator
    var taskBusy: Bool
    var body: some View {
        DisclosureGroup("Search by meaning · optional") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Find related passages even when the wording differs. Preparing asks macOS for local language support; macOS manages its assets and may need internet during preparation. No source text is supplied in that step.")
                    .font(.system(size: 14)).lineSpacing(4)
                Picker("Language to check", selection: $search.language) {
                    Text("English").tag("en")
                    Text("Arabic").tag("ar")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Spanish").tag("es")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Chinese (Simplified)").tag("zh-Hans")
                }.font(.system(size: 15)).disabled(search.state == .preparing || search.state == .ready)
                HStack {
                    if search.state == .preparing {
                        ProgressView().controlSize(.small)
                        Button("Stop preparing") { search.turnOff() }
                    } else {
                        Button("Prepare local search") { search.prepare() }.disabled(taskBusy || search.state == .ready)
                    }
                    Button("Use keyword search only") { search.turnOff() }.disabled(search.state == .off)
                }.buttonStyle(RelaySecondaryButtonStyle())
                Text(search.status).font(.system(size: 14)).textSelection(.enabled)
                Text("Availability depends on this Mac and language. Searches use only the prepared model and current selected sources; no hosted search model is used. Passage limits apply. Results are candidates to review, not proof of a fact. This option starts off after relaunch.")
                    .font(.system(size: 14)).lineSpacing(4)
            }.padding(.top, 12)
        }
        .font(.system(size: 14.5, weight: .medium))
        .foregroundStyle(.white)
        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentGold))
    }
}
