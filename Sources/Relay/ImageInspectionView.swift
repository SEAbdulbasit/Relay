import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageInspectionView: View {
    @Bindable var inspection: ImageInspectionController
    let configuration: ModelConfiguration
    let textModelIsLoaded: Bool
    let otherWorkInProgress: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showFiles = false
    @State private var pickerError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inspect an image or window").font(.title2.weight(.semibold))
            Text("Use the local model to answer questions about one image. The image and answer stay in this panel until you close it.")
                .font(.callout).foregroundStyle(.secondary)
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
                          || configuration.modelPath.isEmpty || inspection.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    }
}
