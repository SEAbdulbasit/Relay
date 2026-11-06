import SwiftUI

struct PrivateSourceQuestionView: View {
    let store: AssistantStore
    @State private var kind: NativePersonalSourceKind = .notes
    @State private var question = ""
    @State private var answer: String?
    @State private var error: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        DisclosureGroup("Ask a private source question") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ask about the selected items you captured. The question and answer stay here for this session; Relay does not add them to chat, exports, or the knowledge index.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted)
                Picker("Captured source", selection: $kind) {
                    ForEach(NativePersonalSourceKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .disabled(work != nil)
                TextField("Ask about this selection", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4).disabled(work != nil)
                HStack {
                    Button("Answer locally") { ask() }.buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(store.isRunning || !store.actionsReady || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || store.nativeSources.items(for: kind).isEmpty || work != nil)
                    if let work { Button("Stop") { work.cancel() } }
                }
                if !store.actionsReady { Text("Load and check a local model first.").font(.relayCaption).foregroundStyle(RelayTheme.muted) }
                if let error { Text(error).font(.relayCaption).foregroundStyle(RelayTheme.muted) }
                if let answer { Text(answer).textSelection(.enabled).accessibilityIdentifier("nativeSources.privateAnswer") }
            }
            .padding(.vertical, 8)
        }
        .onChange(of: store.nativeSourceRevision) { _, _ in clear() }
        .onChange(of: kind) { _, _ in clear() }
        .onDisappear { clear() }
    }

    private func ask() {
        guard work == nil else { return }
        let question = self.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf8.count <= 2_000 else {
            error = "Enter a question of up to 2,000 UTF-8 bytes."
            return
        }
        answer = nil
        error = nil
        let selected = kind
        let revision = store.nativeSourceRevision
        work = Task { @MainActor in
            defer { work = nil }
            do {
                guard store.nativeSourceRevision == revision else { return }
                let reply = try await store.askNativeSource(selected, question: question)
                try Task.checkCancellation()
                guard store.nativeSourceRevision == revision else { return }
                answer = reply
            } catch is CancellationError {
                if !Task.isCancelled { error = "Private answer stopped." }
            } catch {
                if !Task.isCancelled, store.nativeSourceRevision == revision { self.error = error.localizedDescription }
            }
        }
    }

    private func clear() {
        work?.cancel()
        answer = nil
        error = nil
        question = ""
    }
}
