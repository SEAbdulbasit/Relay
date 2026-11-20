import SwiftUI
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

extension AssistantStore {
    var modelSource: LocalBackend {
        if workspaceUsesClaude { return .claudeCLI }
        if workspaceUsesCodex || workspaceUsesCodexCLI { return .codexCLI }
        return configuration.backend
    }
}

struct DiagnosticsView: View {
    let store: AssistantStore
    @State private var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "stethoscope", color: RelayColors.accentEmerald, size: 38, iconSize: 17)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Technical Diagnostics Report")
                        .font(.relayHeadline)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Export technical status and counts as a local JSON file. Chats, source text, filenames, personal paths, and writing samples are excluded. Nothing is uploaded.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                }
                Spacer()
                Button("Export technical report…") { export() }
                    .buttonStyle(RelaySecondaryButtonStyle())
            }
            if let status {
                Text(status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(RelayColors.textPrimary)
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Relay-technical-report.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var input = DiagnosticsInput()
        input.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        input.appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        input.runtimeVersion = "0.18.1"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        input.osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        input.architecture = .appleSilicon
        #else
        input.architecture = .intel
        #endif
        input.computeBackend = DiagnosticsComputeBackend(rawValue: store.configuration.computeBackend) ?? .unknown
        switch store.modelSource {
        case .liteRTLM:
            input.runtime = "LiteRT-LM"
            input.inferenceMode = "localOnly"
            input.modelSelected = !store.configuration.modelPath.isEmpty
        case .lmStudio:
            input.runtime = "LMStudio"
            input.inferenceMode = "localServer"
            input.modelSelected = store.configuration.hasConfiguredInferenceModel
        case .claudeCLI:
            input.runtime = "ClaudeCLI"
            input.inferenceMode = "cli"
            input.modelSelected = store.workspaceUsesClaude || store.configuration.hasConfiguredInferenceModel
        case .codexCLI:
            input.runtime = "CodexCLI"
            input.inferenceMode = "cli"
            input.modelSelected = store.workspaceUsesCodex || store.workspaceUsesCodexCLI || store.configuration.hasConfiguredInferenceModel
        case .openRouter:
            input.runtime = "OpenRouter"
            input.inferenceMode = "cloudAPI"
            input.modelSelected = store.configuration.hasConfiguredInferenceModel
        case .customResponses:
            input.runtime = "CustomResponses"
            input.inferenceMode = "responsesAPI"
            input.modelSelected = store.configuration.hasConfiguredInferenceModel
        }
        // Readiness proves both load and tool probe; failure alone does not establish unloading.
        input.modelLoaded = store.workspaceActionsReady ? true : (store.textModelIsLoaded ? true : nil)
        input.toolProbe = store.workspaceActionsReady ? .passed : .notRun
        input.accessibility = AXIsProcessTrusted() ? .allowed : .denied
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            input.microphone = .allowed
        case .denied, .restricted:
            input.microphone = .denied
        case .notDetermined:
            input.microphone = .notRequested
        @unknown default:
            input.microphone = .unknown
        }
        if CGPreflightScreenCaptureAccess() {
            input.screenRecording = .allowed
        } else {
            switch store.screenCaptureCheckStatus {
            case .notRun:
                input.screenRecording = .notRequested
            default:
                input.screenRecording = .denied
            }
        }
        input.runState = DiagnosticsRunState(rawValue: String(describing: store.phase)) ?? .unknown
        input.quickAccessEnabled = store.quickAccess.enabled
        input.indexedSourceCount = store.knowledge.records.count
        input.approvedMemoryCount = store.memories.count
        input.recentActivityCount = store.activity.count
        input.recentFailureCount = store.activity.filter { $0.status.contains("failed") }.count
        if !input.modelSelected { input.issues.append(.modelNotConfigured) }
        if input.accessibility == .denied { input.issues.append(.accessibilityDenied) }
        if store.quickAccess.errorMessage != nil { input.issues.append(.shortcutUnavailable) }
        do { try LocalDiagnostics.exportJSON(input).write(to: url, options: .atomic); status = "Technical report saved locally. Nothing was uploaded." }
        catch { status = "Could not save the report: \(error.localizedDescription)" }
    }
}
