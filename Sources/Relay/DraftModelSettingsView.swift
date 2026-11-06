import SwiftUI
import UniformTypeIdentifiers

struct DraftModelSettingsView: View {
    let preferences: DraftModelPreferences
    let busy: Bool
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drafting model").font(.system(size: 14, weight: .semibold))
            Text(preferences.model?.model ?? "Use the active chat model").font(.relayCaption).foregroundStyle(RelayTheme.muted)
            if let selected = preferences.model {
                Picker("Backend", selection: Binding(get: { selected.computeBackend }, set: { preferences.selectBackend($0) })) {
                    Text("CPU").tag("cpu")
                    Text("GPU").tag("gpu")
                }.pickerStyle(.segmented).disabled(busy)
            }
            HStack {
                Button("Choose separate local model…") { choosing = true }
                if preferences.model != nil { Button("Use chat model") { preferences.useChatModel() } }
            }.buttonStyle(RelaySecondaryButtonStyle()).disabled(busy)
            Text(preferences.status).font(.relayCaption).foregroundStyle(RelayTheme.muted)
        }
        .fileImporter(isPresented: $choosing,
                      allowedContentTypes: [UTType(filenameExtension: "litertlm") ?? .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { preferences.select(url) }
        }
    }
}
