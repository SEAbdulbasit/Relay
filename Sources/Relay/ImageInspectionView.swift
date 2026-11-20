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
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        RelayIconBadge(icon: "viewfinder", color: RelayColors.accentBlue, size: 38, iconSize: 17)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inspect an image or window")
                                .font(.relayDisplayTitle.weight(.semibold))
                                .foregroundStyle(RelayColors.textPrimary)
                                .accessibilityIdentifier("imageInspection.heading")
                            Text("Use your active model to describe an image or live window, then optionally hand the verified description to a task.")
                                .font(.relayCaption)
                                .foregroundStyle(RelayColors.textSecondary)
                                .lineSpacing(3)
                        }
                        Spacer(minLength: 8)
                        RelayIconButton(icon: "xmark", label: "Close", size: 28, iconSize: 12) {
                            dismiss()
                        }
                        .accessibilityIdentifier("imageInspection.closeHeader")
                    }

                    if configuration.backend == .lmStudio {
                        Text("LM Studio first verifies vision support with a synthetic marker before sending your selected image.")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.accentGold)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button("Choose image…", systemImage: "photo") {
                            pickerError = nil
                            showFiles = true
                        }
                        Button("Choose window…", systemImage: "macwindow") {
                            pickerError = nil
                            inspection.chooseWindow()
                        }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(inspection.isBusy || otherWorkInProgress)

                    if let source = inspection.image, let preview = NSImage(data: source.jpeg) {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 190)
                                .padding(10)
                                .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                                )
                                .accessibilityLabel("Image to inspect: \(source.label)")
                            Text(source.label)
                                .font(.relayCaption)
                                .foregroundStyle(RelayColors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    TextField("Ask about the image", text: $inspection.question, prompt: Text(""), axis: .vertical)
                        .font(.relayBody)
                        .foregroundStyle(RelayColors.textPrimary)
                        .textFieldStyle(.plain)
                        .relayTextFieldPrompt("Ask about the image", when: inspection.question.isEmpty)
                        .lineLimit(2...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(RelayColors.borderDefault, lineWidth: 1)
                        )
                        .disabled(inspection.isBusy)

                    if let answer = inspection.answer {
                        ScrollView {
                            Text(answer)
                                .font(.relayBody)
                                .foregroundStyle(RelayColors.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(maxHeight: 180)
                        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                        )
                        .accessibilityIdentifier("imageInspection.answer")

                        DisclosureGroup("Start a task using this description", isExpanded: $reviewingTask) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Relay uses up to 2,000 bytes of the description as context and checks the live app before acting.")
                                    .font(.relayCaption)
                                    .foregroundStyle(RelayColors.textSecondary)
                                TextField("What should Relay do?", text: $taskRequest, prompt: Text(""), axis: .vertical)
                                    .font(.relayBody)
                                    .foregroundStyle(RelayColors.textPrimary)
                                    .textFieldStyle(.plain)
                                    .relayTextFieldPrompt("What should Relay do?", when: taskRequest.isEmpty)
                                    .lineLimit(2...3)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(RelayColors.borderDefault, lineWidth: 1)
                                    )
                                if let taskError {
                                    Text(taskError)
                                        .font(.relayCaption)
                                        .foregroundStyle(RelayColors.accentCoral)
                                }
                                Button("Start Task") {
                                    do {
                                        try onStartTask(taskRequest, answer)
                                        dismiss()
                                    } catch {
                                        taskError = error.localizedDescription
                                    }
                                }
                                .buttonStyle(RelayPrimaryButtonStyle())
                                .disabled(!canStartTask || otherWorkInProgress || inspection.isBusy
                                          || taskRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if !canStartTask {
                                    Text("Configure and verify a workspace model to start a task.")
                                        .font(.relayCaption)
                                        .foregroundStyle(RelayColors.textSecondary)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .font(.relayBody.weight(.medium))
                    }

                    Text(pickerError ?? inspection.status)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("imageInspection.status")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            }
            .accessibilityIdentifier("imageInspection.content")

            Divider().overlay(RelayTheme.line)

            HStack(spacing: 10) {
                Button("Close") { dismiss() }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if inspection.isBusy {
                    Button("Stop") { inspection.stop() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                }
                Button("Inspect") {
                    pickerError = nil
                    inspection.inspect(configuration: configuration, textModelIsLoaded: textModelIsLoaded)
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(otherWorkInProgress || inspection.isBusy || inspection.image == nil
                          || !configuration.hasConfiguredInferenceModel
                          || inspection.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .accessibilityIdentifier("imageInspection.footer")
        }
        .padding(24)
        .frame(width: 540, height: 640)
        .background(RelayTheme.background)
        .foregroundStyle(RelayTheme.ink)
        .tint(RelayColors.accentBlue)
        .relayPreferredAppearance()
        .disclosureGroupStyle(RelayDisclosureGroupStyle())
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let files):
                if let file = files.first { inspection.loadFile(file) }
            case .failure:
                pickerError = "The image file could not be selected."
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
