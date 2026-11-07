import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageInspectionView: View {
    @Bindable var inspection: ImageInspectionController
    let configuration: ModelConfiguration
    let textModelIsLoaded: Bool
    let otherWorkInProgress: Bool
    let canStartTask: Bool
    let onStartTask: (String, String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showFiles = false
    @State private var pickerError: String?
    @State private var taskRequest = ""
    @State private var taskError: String?
    @State private var reviewingTask = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inspect an image or window").font(.title2.weight(.semibold))
            Text("Use the local model to describe one image or window. You can review the description before using it in a local task.")
                .font(.callout).foregroundStyle(.secondary)
            if configuration.backend == .lmStudio {
                Text("LM Studio first checks a synthetic marker for this model. Your selected image is sent only after that check and while this request remains active.")
                    .font(.callout).foregroundStyle(RelayColors.accentGold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose image…", systemImage: "photo") { pickerError = nil; showFiles = true }
                Button("Choose window…", systemImage: "macwindow") { pickerError = nil; inspection.chooseWindow() }
            }
            .disabled(inspection.isBusy || otherWorkInProgress)
            if let source = inspection.image, let preview = NSImage(data: source.jpeg) {
                Image(nsImage: preview).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 185)
                    .accessibilityLabel("Image to inspect: \(source.label)")
            }
            TextField("Ask about the image", text: $inspection.question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
                .disabled(inspection.isBusy)
            if let answer = inspection.answer {
                ScrollView { Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180)
                    .accessibilityIdentifier("imageInspection.answer")
                DisclosureGroup("Review a local task using this description", isExpanded: $reviewingTask) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Relay uses up to 2,000 bytes of the description as context and checks the live app before acting. Task results appear in the local conversation.")
                            .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                        TextField("What should Relay do?", text: $taskRequest, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...3)
                        if let taskError { Text(taskError).font(.relayCaption).foregroundStyle(RelayColors.accentCoral) }
                        Button("Start Local Task") {
                            do {
                                try onStartTask(taskRequest, answer)
                                dismiss()
                            } catch { taskError = error.localizedDescription }
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(!canStartTask || otherWorkInProgress || inspection.isBusy
                                  || taskRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !canStartTask {
                            Text("Load a local workspace model to start a task.").font(.relayCaption)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            Text(pickerError ?? inspection.status)
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .accessibilityIdentifier("imageInspection.status")
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if inspection.isBusy { Button("Stop") { inspection.stop() } }
                Button("Inspect locally") {
                    pickerError = nil
                    inspection.inspect(configuration: configuration, textModelIsLoaded: textModelIsLoaded)
                }
                .buttonStyle(.borderedProminent)
                .disabled(otherWorkInProgress || inspection.isBusy || inspection.image == nil
                          || !configuration.hasConfiguredInferenceModel
                          || inspection.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let files): if let file = files.first { inspection.loadFile(file) }
            case .failure: pickerError = "The image file could not be selected."
            }
        }
        .onDisappear { inspection.reset() }
        .onChange(of: inspection.answer) { _, _ in
            reviewingTask = false
            taskRequest = ""
            taskError = nil
        }
    }
}
