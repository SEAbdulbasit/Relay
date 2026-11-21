import SwiftUI

struct WritingProfileView: View {
    @Bindable var profile: WritingProfile
    var canLearn = false
    var learn: (([String]) async throws -> WritingStyleSuggestion)?
    @State private var sample = ""
    @State private var learning: Task<Void, Never>?
    @State private var learningStatus: String?
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.quote")
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 24, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Writing Voice & Tone")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Approve standing writing preferences to guide replies. You can also ask your model to infer your style from examples before saving.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(3)
                }
                Spacer()
            }

            Text("Edits apply to future replies after you choose Approve & Save Style.")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)

            HStack(spacing: 12) {
                labeledField("Tone", placeholder: "e.g., Warm and direct", text: $profile.preferredTone)
                labeledField("Length", placeholder: "e.g., Concise", text: $profile.length)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Additional Instructions")
                    .font(RelayPageStyle.caption.weight(.medium))
                    .foregroundStyle(RelayColors.textSecondary)
                adaptiveMultilineField("Other standing writing preferences", text: $profile.additionalInstructions, lineLimit: 2...5)
            }

            DisclosureGroup("Style Examples (\(profile.sampleTexts.count))") {
                VStack(alignment: .leading, spacing: 12) {
                    adaptiveMultilineField("Paste an example message or email to save locally", text: $sample, lineLimit: 3...6)
                    RelayChipFlow(spacing: 8, alignment: .leading) {
                        Button("Add Example") {
                            let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            profile.sampleTexts.append(trimmed)
                            sample = ""
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.sampleTexts.count >= 5 || sample.utf8.count > 8_000 || profile.sampleTexts.reduce(0, { $0 + $1.utf8.count }) + sample.utf8.count > 20_000)

                        if learn != nil {
                            Button(learning != nil ? "Analyzing…" : "Suggest Style from Examples") {
                                suggestStyle()
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(!canLearn || profile.sampleTexts.isEmpty || learning != nil)

                            if let learning {
                                Button("Stop") { learning.cancel() }
                                    .buttonStyle(RelaySecondaryButtonStyle())
                            }
                        }
                    }

                    Text("Up to five examples, 8,000 bytes each and 20,000 bytes total. Examples stay local until you request style analysis using your workspace model.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                    if !sample.isEmpty && (sample.utf8.count > 8_000 || profile.sampleTexts.reduce(0, { $0 + $1.utf8.count }) + sample.utf8.count > 20_000) {
                        Label("Shorten this example to fit the saved sample limits.", systemImage: "exclamationmark.circle")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.accentCoral)
                    }

                    if let learningStatus {
                        Text(learningStatus)
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                    }

                    ForEach(Array(profile.sampleTexts.enumerated()), id: \.offset) { index, text in
                        HStack(alignment: .top, spacing: 12) {
                            Text(text)
                                .font(RelayPageStyle.caption)
                                .foregroundStyle(RelayColors.textPrimary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Remove") {
                                profile.sampleTexts.remove(at: index)
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                        }
                        .padding(10)
                        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                        )
                    }
                }
                .padding(.top, 8)
            }
            .font(RelayPageStyle.body.weight(.medium))
            .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.workbenchAccent))

            HStack(spacing: 10) {
                Button("Approve & Save Style") {
                    try? profile.save()
                }
                .buttonStyle(RelayPrimaryButtonStyle())

                Button("Clear Profile") {
                    showClearConfirmation = true
                }
                .buttonStyle(RelaySecondaryButtonStyle())

            }
            Text(profile.status)
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = profile.errorMessage {
                Text(error)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentCoral)
            }
        }
        .font(RelayPageStyle.body)
        .foregroundStyle(RelayColors.textPrimary)
        .relayFormSection()
        .onDisappear { learning?.cancel() }
        .confirmationDialog("Clear writing profile and examples?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear profile", role: .destructive) {
                learning?.cancel()
                profile.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your approved writing preferences and saved examples. Relay will stop applying this profile’s saved preferences.")
        }
    }

    private func suggestStyle() {
        guard let learn, learning == nil else { return }
        let examples = profile.sampleTexts
        let initial = [profile.preferredTone, profile.length, profile.additionalInstructions]
        learningStatus = "Finding style patterns with your workspace model…"
        learning = Task { @MainActor in
            defer { learning = nil }
            do {
                let suggestion = try await learn(examples)
                try Task.checkCancellation()
                guard profile.sampleTexts == examples, [profile.preferredTone, profile.length, profile.additionalInstructions] == initial else {
                    learningStatus = "The profile changed while Relay worked. No draft suggestions were applied."
                    return
                }
                profile.preferredTone = suggestion.tone
                profile.length = suggestion.length
                profile.additionalInstructions = suggestion.preferences
                learningStatus = "Suggestions filled the editable fields. Review them before approving."
            } catch is CancellationError {
                learningStatus = "Style analysis stopped."
            } catch {
                learningStatus = error.localizedDescription
            }
        }
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(RelayPageStyle.caption.weight(.medium))
                .foregroundStyle(RelayColors.textSecondary)
            adaptiveField(placeholder, text: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adaptiveField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(""))
            .textFieldStyle(.plain)
            .font(RelayPageStyle.body)
            .relayTextFieldPrompt(placeholder, when: text.wrappedValue.isEmpty, font: .relayBody)
            .accessibilityLabel(placeholder)
            .foregroundStyle(RelayColors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(RelayColors.borderDefault, lineWidth: 1)
            )
    }

    private func adaptiveMultilineField(_ placeholder: String, text: Binding<String>, lineLimit: ClosedRange<Int>) -> some View {
        TextField("", text: text, prompt: Text(""), axis: .vertical)
            .lineLimit(lineLimit)
            .textFieldStyle(.plain)
            .font(RelayPageStyle.body)
            .relayTextFieldPrompt(placeholder, when: text.wrappedValue.isEmpty, font: .relayBody)
            .accessibilityLabel(placeholder)
            .foregroundStyle(RelayColors.textPrimary)
            .padding(12)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(RelayColors.borderDefault, lineWidth: 1)
            )
    }
}
