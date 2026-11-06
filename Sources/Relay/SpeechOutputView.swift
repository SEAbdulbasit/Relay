import SwiftUI

struct SpeechOutputView: View {
    @Bindable var speech: LocalSpeechOutput
    @Bindable var diagnostic: LocalSpeechDiagnostic
    var taskBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                OnboardingWhisper("VOICE CONFIGURATION")
                Text("Read Aloud & Local Speech")
                    .display(26)
                    .foregroundStyle(.white)
                Text("Listen to a response, or dictate a draft. Always on your terms.")
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineSpacing(3)
            }
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(get: { speech.isEnabled }, set: {
                    speech.isEnabled = $0
                    if $0 { speech.refreshVoices() }
                })) {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RelayColors.accentCoral)
                        Text("Read aloud")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch).disabled(diagnostic.isBusy)
                Text("Adds a speaker button to replies. Nothing plays automatically.")
                    .font(.system(size: 13.5)).foregroundStyle(RelayTheme.muted)
                if speech.isEnabled {
                    Divider().overlay(RelayTheme.line)
                    Picker("Installed voice", selection: $speech.selectedVoiceID) {
                        Text("Choose a voice…").tag(Optional<String>.none)
                        ForEach(speech.availableVoices) { voice in
                            Text("\(voice.name) · \(voice.language)").tag(Optional(voice.id))
                        }
                    }.font(.system(size: 14)).disabled(diagnostic.isBusy)
                    HStack {
                        Button("Refresh voices") { speech.refreshVoices() }.disabled(diagnostic.isBusy)
                        if speech.isActive { Button("Stop audio") { speech.stop() } }
                    }.buttonStyle(RelaySecondaryButtonStyle())
                    Text(speech.status).font(.system(size: 13)).foregroundStyle(RelayTheme.muted).textSelection(.enabled)
                }
                if let error = speech.errorMessage { Text(error).font(.system(size: 13)).textSelection(.enabled) }
                DisclosureGroup("About local voices") {
                    Text("Relay uses installed Apple voices, excludes Personal Voice and never requests voice downloads or a hosted fallback. Audio cannot run tools or send messages. Read aloud starts off each session. Stop (⌘.) also stops audio.")
                        .font(.system(size: 13)).foregroundStyle(RelayTheme.muted).lineSpacing(3).padding(.top, 8)
                }.font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .relayLitCard(accent: RelayColors.accentCoral, cornerRadius: RelayTheme.radius)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RelayColors.accentCoral)
                    Text("Check local speech")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text("Test a generated phrase in memory. No microphone, playback, file or chat message.")
                    .font(.system(size: 13.5)).foregroundStyle(RelayTheme.muted).lineSpacing(3)
                HStack(spacing: 10) {
                    Button("Run speech check") { speech.stop(); diagnostic.start() }
                        .disabled(taskBusy || diagnostic.isBusy)
                    if diagnostic.isBusy {
                        Button("Stop check") { diagnostic.stop() }
                        ProgressView().controlSize(.small)
                    }
                }.buttonStyle(RelaySecondaryButtonStyle())
                if diagnostic.phase != .idle {
                    Text(diagnostic.status).font(.system(size: 13)).foregroundStyle(RelayTheme.muted).textSelection(.enabled)
                }
                DisclosureGroup("Permission & test details") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The test needs existing Speech access and uses on-device recognition only. Recheck may show a macOS Speech permission prompt; it never starts a test or recording automatically.")
                        Button("Recheck Speech access") { speech.stop(); diagnostic.recheckSpeechAccess() }
                            .buttonStyle(RelaySecondaryButtonStyle()).disabled(taskBusy || diagnostic.isBusy)
                        if let elapsed = diagnostic.elapsedSeconds {
                            Text("\(diagnostic.audioFrames) audio frames · \(elapsed, specifier: "%.1f") seconds. One synthetic phrase checks recognition support, not microphone accuracy or offline operation.")
                        }
                    }.font(.system(size: 13)).foregroundStyle(RelayTheme.muted).lineSpacing(3).padding(.top, 8)
                }.font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .relayGlassCard(cornerRadius: RelayTheme.radius)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mic").foregroundStyle(RelayTheme.ink)
                Text("To dictate, use the microphone in your conversation. Review the transcript before adding it to your draft.")
                    .font(.system(size: 14)).foregroundStyle(RelayTheme.muted).lineSpacing(3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .relayGlassCard(cornerRadius: 10)
        }
        .foregroundStyle(RelayTheme.ink)
        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentCoral))
        .onChange(of: taskBusy) { _, busy in if busy { diagnostic.stop() } }
        .onDisappear { diagnostic.stop() }
    }
}
