import SwiftUI
@preconcurrency import Speech

struct VoiceInputView: View {
    @Bindable var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @State private var languages: [Language] = []
    private struct Language: Identifiable { let id: String; let title: String }

    private var trimmedTranscript: String {
        store.voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTranscript: Bool {
        !trimmedTranscript.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(store.voice.isRecording ? RelayColors.accentCoral.opacity(0.16) : RelayColors.surface)
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(store.voice.isRecording ? RelayColors.accentCoral.opacity(0.42) : RelayColors.borderSubtle, lineWidth: 0.75)
                        )
                    Image(systemName: store.voice.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(store.voice.isRecording ? RelayColors.accentCoral : RelayColors.textPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Input")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("On-device macOS speech recognition · Never uploaded for transcription")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            store.voice.errorMessage != nil
                                ? RelayColors.accentAmber
                                : (store.voice.isRecording ? RelayColors.accentCoral : (hasTranscript ? RelayColors.accentEmerald : RelayColors.textMuted))
                        )
                        .frame(width: 7, height: 7)
                    Text(store.voice.isRecording ? "Listening" : (hasTranscript ? "Ready" : "Standby"))
                        .font(.relayCaptionStrong)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RelayColors.surface, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 0.75))

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
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speak. Review. Send.")
                            .font(.system(size: 24, weight: .semibold))
                            .tracking(-0.5)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Dictate directly on this Mac, then add your words to the workspace composer or send immediately.")
                            .font(.relayBody)
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineSpacing(3)
                    }

                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Language")
                                .font(.relayCaptionStrong)
                                .foregroundStyle(RelayColors.textSecondary)
                            Picker("Language", selection: Binding(get: { store.voice.localeIdentifier }, set: { store.setVoiceLocale($0) })) {
                                ForEach(languages) { language in
                                    Text(language.title).tag(language.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(store.voice.isBusy || languages.isEmpty)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recording Limit")
                                .font(.relayCaptionStrong)
                                .foregroundStyle(RelayColors.textSecondary)
                            Picker("Recording limit", selection: Binding(get: { store.voice.maximumDuration }, set: { store.voice.setMaximumDuration($0) })) {
                                Text("10 seconds").tag(TimeInterval(10))
                                Text("30 seconds").tag(TimeInterval(30))
                                Text("60 seconds").tag(TimeInterval(60))
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(store.voice.isBusy)
                        }
                        .frame(width: 170, alignment: .leading)
                    }
                    .padding(14)
                    .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 0.75))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            if store.voice.isRecording {
                                Circle().fill(RelayColors.accentCoral).frame(width: 8, height: 8)
                            }
                            Text(store.voice.status)
                                .font(.relaySubheadline)
                                .foregroundStyle(RelayColors.textSecondary)
                            Spacer()
                            Text("Max \(Int(store.voice.maximumDuration))s")
                                .font(.relayCaption)
                                .foregroundStyle(RelayColors.textMuted)
                        }

                        if let error = store.voice.errorMessage {
                            Text(error)
                                .font(.relaySubheadline)
                                .foregroundStyle(RelayColors.accentAmber)
                                .textSelection(.enabled)
                        }

                        ScrollView {
                            Text(store.voice.transcript.isEmpty ? "Your transcript will appear here as you speak…" : store.voice.transcript)
                                .font(.system(size: 15.5, weight: .regular))
                                .foregroundStyle(store.voice.transcript.isEmpty ? RelayColors.textMuted : RelayColors.textPrimary)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .accessibilityLabel("Dictation transcript")
                                .accessibilityValue(store.voice.transcript.isEmpty ? "No transcript yet" : store.voice.transcript)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 164)
                        .padding(16)
                        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(store.voice.isRecording ? RelayColors.accentCoral.opacity(0.45) : RelayColors.borderSubtle, lineWidth: 0.75)
                        )
                    }

                    DisclosureGroup("How local dictation works") {
                        Text("Recording stops at the selected limit; permission dialogs do not count toward the timer. On-device availability depends on your language and installed macOS speech assets.")
                            .font(.relaySubheadline)
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineSpacing(3)
                            .padding(.top, 6)
                    }
                    .font(.relaySubheadline)
                    .foregroundStyle(RelayColors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)

            HStack(spacing: 10) {
                if store.voice.isBusy {
                    Button(store.voice.isRecording ? "Stop recording" : store.voice.phase == .requestingPermission ? "Cancel permission wait" : "Stop voice input") {
                        store.voice.stop()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button(hasTranscript ? "Record again" : "Start local dictation") {
                        Task { await store.voice.start() }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(store.isRunning || store.isClearingConversation || languages.isEmpty)
                }
                Spacer()
                Button(store.draft.isEmpty ? "Use transcript" : "Append to my draft") {
                    if store.voice.isBusy {
                        store.voice.stop()
                    }
                    if store.useVoiceTranscript() {
                        dismiss()
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(!hasTranscript)

                Button("Send") {
                    if store.voice.isBusy {
                        store.voice.stop()
                    }
                    if store.useVoiceTranscript() {
                        store.send(useWorkspaceProvider: true)
                        dismiss()
                    }
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .tint(RelayColors.accentBlue)
                .disabled(!hasTranscript || store.isRunning || store.isClearingConversation)
                .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 14, weight: .medium))
        }
        .padding(24)
        .frame(width: 600, height: 620)
        .background(RelayColors.canvas)
        .foregroundStyle(RelayColors.textPrimary)
        .tint(RelayColors.accentBlue)
        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentCoral))
        .relayPreferredAppearance()
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
