import SwiftUI

struct WritingProfileView: View {
    @Bindable var profile: WritingProfile
    var canLearn = false
    var learn: (([String]) async throws -> WritingStyleSuggestion)?
    @State private var sample = ""
    @State private var learning: Task<Void, Never>?
    @State private var learningStatus: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Writing style").font(.system(size: 18, weight: .semibold))
            Text("Approve a few writing preferences. Only approved preferences guide replies. You can ask the local model to suggest a style from your examples, then edit it before saving.")
                .font(.system(size: 13.5)).foregroundStyle(RelayTheme.muted).lineSpacing(4)
            darkField("Tone — for example, warm and direct", text: $profile.preferredTone)
            darkField("Length — for example, concise", text: $profile.length)
            darkMultilineField("Other writing preferences", text: $profile.additionalInstructions, lineLimit: 2...5)
            DisclosureGroup("Optional writing examples") {
                VStack(alignment: .leading, spacing: 12) {
                    darkMultilineField("Paste an example you want to save locally", text: $sample, lineLimit: 3...6)
                    Button("Add example to pending profile") {
                        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        profile.sampleTexts.append(sample); sample = ""
                    }.buttonStyle(RelaySecondaryButtonStyle()).disabled(sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if learn != nil {
                        HStack {
                            Button("Suggest style locally") { suggestStyle() }
                                .buttonStyle(RelaySecondaryButtonStyle())
                                .disabled(!canLearn || profile.sampleTexts.isEmpty || learning != nil)
                            if let learning { Button("Stop") { learning.cancel() } }
                        }
                        if let learningStatus { Text(learningStatus).font(.relayCaption).foregroundStyle(RelayTheme.muted) }
                    }
                    ForEach(Array(profile.sampleTexts.enumerated()), id: \.offset) { index, text in
                        HStack(alignment: .top) {
                            Text(text).lineLimit(4).textSelection(.enabled)
                            Spacer()
                            Button("Remove") { profile.sampleTexts.remove(at: index) }.buttonStyle(RelaySecondaryButtonStyle())
                        }
                    }
                }.padding(.top, 10)
            }
            .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentAmethyst))
            HStack {
                Button("Approve and save style") { try? profile.save() }.buttonStyle(RelayPrimaryButtonStyle())
                Button("Clear writing profile") { profile.clear() }.buttonStyle(RelaySecondaryButtonStyle())
            }
            Text(profile.status).font(.system(size: 13)).foregroundStyle(RelayTheme.muted)
            if let error = profile.errorMessage { Text(error).font(.system(size: 13)).foregroundStyle(RelayColors.accentCoral) }
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(18)
        .relayGlassCard(cornerRadius: 14)
        .onDisappear { learning?.cancel() }
    }

    private func suggestStyle() {
        guard let learn, learning == nil else { return }
        let examples = profile.sampleTexts
        let initial = [profile.preferredTone, profile.length, profile.additionalInstructions]
        learningStatus = "Finding style patterns on this Mac…"
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
            } catch is CancellationError { learningStatus = "Style analysis stopped." }
            catch { learningStatus = error.localizedDescription }
        }
    }

    private func darkField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(RelayColors.textDim))
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
    }

    private func darkMultilineField(_ placeholder: String, text: Binding<String>, lineLimit: ClosedRange<Int>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundStyle(RelayColors.textDim), axis: .vertical)
            .lineLimit(lineLimit)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(.white)
            .padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.11), lineWidth: 1))
    }
}
