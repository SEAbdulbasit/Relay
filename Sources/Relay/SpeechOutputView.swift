import SwiftUI

struct SpeechOutputView: View {
    @Bindable var speech: LocalSpeechOutput
    @Bindable var diagnostic: LocalSpeechDiagnostic
    var taskBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "speaker.wave.2")
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 24, height: 28)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Read Aloud & Local Speech")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Adds an on-device speaker button to replies. Uses installed Apple voices and never plays automatically.")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineSpacing(2)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(get: { speech.isEnabled }, set: {
                            speech.isEnabled = $0
                            if $0 { speech.refreshVoices() }
                        })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(diagnostic.isBusy)
                }

                if speech.isEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Text("Installed voice")
                                .font(RelayPageStyle.caption.weight(.medium))
                                .foregroundStyle(RelayColors.textSecondary)
                                .frame(width: 96, alignment: .leading)
                            Picker("Installed voice", selection: $speech.selectedVoiceID) {
                                Text("Choose a voice…").tag(Optional<String>.none)
                                ForEach(speech.availableVoices) { voice in
                                    Text("\(voice.name) · \(voice.language)").tag(Optional(voice.id))
                                }
                            }
                            .labelsHidden()
                            .disabled(diagnostic.isBusy)
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            Button("Refresh voices") { speech.refreshVoices() }
                                .disabled(diagnostic.isBusy)
                            if speech.isActive {
                                Button("Stop audio") { speech.stop() }
                            }
                            Spacer()
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())

                        Text(speech.status)
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 4)
                }

                if let error = speech.errorMessage {
                    Text(error)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.accentCoral)
                        .textSelection(.enabled)
                }

                DisclosureGroup("About local voices") {
                    Text("Relay uses installed Apple voices, excludes Personal Voice and never requests voice downloads or a hosted fallback. Audio cannot run tools or send messages. Read aloud starts off each session. Stop (⌘.) also stops audio.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(3)
                        .padding(.top, 8)
                }
                .font(RelayPageStyle.sectionTitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .relayFormSection()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "waveform")
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 24, height: 28)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Check Local Speech Recognition")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Test a generated phrase in memory. No microphone, playback, file, or chat message.")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineSpacing(2)
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button("Run speech check") { speech.stop(); diagnostic.start() }
                        .disabled(taskBusy || diagnostic.isBusy)
                    if diagnostic.isBusy {
                        Button("Stop check") { diagnostic.stop() }
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                if diagnostic.phase != .idle {
                    Text(diagnostic.status)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .textSelection(.enabled)
                }

                DisclosureGroup("Permission & test details") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The test needs existing Speech access and uses on-device recognition only. Recheck may show a macOS Speech permission prompt; it never starts a test or recording automatically.")
                        Button("Recheck Speech access") { speech.stop(); diagnostic.recheckSpeechAccess() }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(taskBusy || diagnostic.isBusy)
                        if let elapsed = diagnostic.elapsedSeconds {
                            Text("\(diagnostic.audioFrames) audio frames · \(elapsed, specifier: "%.1f") seconds. One synthetic phrase checks recognition support, not microphone accuracy or offline operation.")
                        }
                    }
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineSpacing(3)
                    .padding(.top, 8)
                }
                .font(RelayPageStyle.sectionTitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .relayFormSection()
        }
        .foregroundStyle(RelayTheme.ink)
        .font(RelayPageStyle.body)
        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.workbenchAccent))
        .onChange(of: taskBusy) { _, busy in if busy { diagnostic.stop() } }
        .onDisappear { diagnostic.stop() }
    }
}
