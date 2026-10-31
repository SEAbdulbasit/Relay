import SwiftUI

struct WritingProfileView: View {
    @Bindable var profile: WritingProfile
    @State private var sample = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Writing style").font(.system(size: 20, weight: .semibold))
            Text("Approve a few writing preferences. Only saved preferences guide replies; examples stay local and are not automatically turned into instructions.")
                .font(.system(size: 14)).lineSpacing(4)
            TextField("Tone — for example, warm and direct", text: $profile.preferredTone).textFieldStyle(.roundedBorder)
            TextField("Length — for example, concise", text: $profile.length).textFieldStyle(.roundedBorder)
            TextField("Other writing preferences", text: $profile.additionalInstructions, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
            DisclosureGroup("Optional writing examples") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Paste an example you want to save locally", text: $sample, axis: .vertical)
                        .lineLimit(3...6).textFieldStyle(.roundedBorder)
                    Button("Add example to pending profile") {
                        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        profile.sampleTexts.append(sample); sample = ""
                    }.buttonStyle(RelaySecondaryButtonStyle()).disabled(sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(Array(profile.sampleTexts.enumerated()), id: \.offset) { index, text in
                        HStack(alignment: .top) {
                            Text(text).lineLimit(4).textSelection(.enabled)
                            Spacer()
                            Button("Remove") { profile.sampleTexts.remove(at: index) }.buttonStyle(RelaySecondaryButtonStyle())
                        }
                    }
                }.padding(.top, 10)
            }
            HStack {
                Button("Approve and save style") { try? profile.save() }.buttonStyle(RelayPrimaryButtonStyle())
                Button("Clear writing profile") { profile.clear() }.buttonStyle(RelaySecondaryButtonStyle())
            }
            Text(profile.status).font(.system(size: 14))
            if let error = profile.errorMessage { Text(error).font(.system(size: 14)).foregroundStyle(.white) }
        }.font(.system(size: 15)).foregroundStyle(.white)
            .padding(18).background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
