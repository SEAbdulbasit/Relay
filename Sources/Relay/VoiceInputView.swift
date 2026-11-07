import SwiftUI
@preconcurrency import Speech

struct VoiceInputView: View {
    @Bindable var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @State private var languages: [Language] = []
    private struct Language: Identifiable { let id: String; let title: String }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Voice input", systemImage: "mic").font(.system(size: 19, weight: .semibold))
                Spacer()
                RelayIconButton(
                    icon: "xmark",
                    label: "Close voice input and discard transcript",
                    size: 32
                ) {
                    store.voice.cancel()
                    dismiss()
                }
                .help("Stop microphone and discard this transcript")
                .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Speak. Review. Send.").font(.system(size: 28, weight: .semibold)).tracking(-0.7)
                    Text("Dictate on this Mac, then review your words. Start may request microphone and Speech permission. No hosted recognition fallback.")
                        .font(.system(size: 15)).lineSpacing(4)
                    Picker("Language", selection: Binding(get: { store.voice.localeIdentifier }, set: { store.setVoiceLocale($0) })) {
                        ForEach(languages) { language in Text(language.title).tag(language.id) }
                    }.font(.system(size: 15)).disabled(store.voice.isBusy || languages.isEmpty)
                    Picker("Recording limit", selection: Binding(get: { store.voice.maximumDuration }, set: { store.voice.setMaximumDuration($0) })) {
                        Text("10 seconds").tag(TimeInterval(10))
                        Text("30 seconds").tag(TimeInterval(30))
                        Text("60 seconds").tag(TimeInterval(60))
                    }.font(.system(size: 15)).disabled(store.voice.isBusy)
                    DisclosureGroup("How local dictation works") {
                        Text("Recording stops at the selected limit; permission dialogs do not count. The limit lasts for this session. On-device availability depends on your language and installed macOS speech assets. Nothing is submitted automatically.")
                            .font(.system(size: 14)).foregroundStyle(RelayTheme.muted).lineSpacing(4).padding(.top, 8)
                    }.font(.system(size: 14))
                    HStack {
                        if store.voice.isRecording { Circle().fill(Color.red).frame(width: 9, height: 9) }
                        Text(store.voice.status).font(.system(size: 15))
                    }
                    if let error = store.voice.errorMessage { Text(error).font(.system(size: 14)).textSelection(.enabled) }
                    ScrollView {
                        Text(store.voice.transcript.isEmpty ? "Your transcript will appear here." : store.voice.transcript)
                            .font(.system(size: 16)).lineSpacing(4).textSelection(.enabled)
                            .accessibilityLabel("Dictation transcript")
                            .accessibilityValue(store.voice.transcript.isEmpty ? "No transcript yet" : store.voice.transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 160).padding(16).background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                    Text("Maximum \(Int(store.voice.maximumDuration)) seconds. Closing this window or using Stop cancels capture. Review the transcript before adding it to your draft.")
                        .font(.system(size: 14)).lineSpacing(4)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.visible)
            HStack {
                if store.voice.isBusy {
                    Button(store.voice.isRecording ? "Stop recording" : store.voice.phase == .requestingPermission ? "Cancel permission wait" : "Stop voice input") { store.voice.stop() }.buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button("Start local dictation") { Task { await store.voice.start() } }
                        .buttonStyle(RelaySecondaryButtonStyle()).disabled(store.isRunning || store.isClearingConversation || languages.isEmpty)
                }
                Spacer()
                Button(store.draft.isEmpty ? "Use transcript" : "Append to my draft") {
                    if store.useVoiceTranscript() { dismiss() }
                }.buttonStyle(RelayPrimaryButtonStyle()).tint(RelayTheme.accent).disabled(store.voice.isBusy || store.voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.system(size: 15))
        }.padding(28).frame(width: 600, height: 640)
            .background(RelayTheme.background).foregroundStyle(.white).tint(RelayTheme.accent)
            .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentCoral))
            .onAppear {
                store.speech.stop()
                store.speechDiagnostic.stop()
                languages = SFSpeechRecognizer.supportedLocales().compactMap { locale -> Language? in
                    guard let id = try? LocalVoiceInput.validatedLocale(locale.identifier) else { return nil }
                    return Language(id: id, title: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let current = store.voice.localeIdentifier.replacingOccurrences(of: "_", with: "-")
                let language = Locale(identifier: current).language.languageCode?.identifier ?? "en"
                if let preferred = languages.first(where: { $0.id.lowercased() == current.lowercased() })
                    ?? languages.first(where: { $0.id.lowercased().hasPrefix(language.lowercased() + "-") })
                    ?? languages.first(where: { $0.id == "en-us" }) ?? languages.first {
                    store.setVoiceLocale(preferred.id)
                }
            }
            .onDisappear { store.voice.cancel() }
    }
}
