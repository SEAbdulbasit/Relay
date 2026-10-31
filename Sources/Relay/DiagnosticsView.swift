import SwiftUI
import AppKit
import ApplicationServices
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    let store: AssistantStore
    @State private var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A useful report. No private content.").font(.system(size: 18, weight: .semibold))
            Text("Export technical status and counts as a local JSON file. Chats, source text, filenames, personal paths and writing samples are excluded. Nothing is uploaded.")
                .font(.system(size: 14)).lineSpacing(4)
            Button("Export technical report…") { export() }.buttonStyle(RelaySecondaryButtonStyle())
            if let status { Text(status).font(.system(size: 14)).textSelection(.enabled) }
        }.foregroundStyle(.white)
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
        input.modelSelected = !store.configuration.modelPath.isEmpty
        // Readiness proves both load and tool probe; failure alone does not establish unloading.
        input.modelLoaded = store.actionsReady ? true : nil
        input.toolProbe = store.actionsReady ? .passed : .notRun
        input.accessibility = AXIsProcessTrusted() ? .allowed : .denied
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
