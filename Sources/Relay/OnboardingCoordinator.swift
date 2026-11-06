import AppKit
import ApplicationServices
import Foundation
import Observation

nonisolated struct MacReadiness: Sendable {
    let architecture: String
    let memoryGB: Int
    let freeDiskGB: Int
    let supported: Bool
    let summary: String

    static func evaluate(architecture: String, osMajor: Int, memoryBytes: UInt64, freeBytes: Int64) -> MacReadiness {
        let memory = Int(memoryBytes / 1_073_741_824)
        let disk = Int(max(0, freeBytes) / 1_000_000_000)
        let supported = architecture == "arm64" && osMajor >= 15 && memory >= 8
        let summary: String
        if architecture != "arm64" { summary = "This build needs an Apple silicon Mac." }
        else if osMajor < 15 { summary = "This build needs macOS 15 or later." }
        else if memory < 8 { summary = "At least 8 GB of unified memory is required. 16 GB or more is recommended." }
        else { summary = "Apple silicon is supported. 16 GB or more is recommended; actual model performance depends on your Mac." }
        return MacReadiness(architecture: architecture, memoryGB: memory, freeDiskGB: disk, supported: supported, summary: summary)
    }

    static func current() -> MacReadiness {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "Intel"
        #endif
        // On first launch the app support directory may not exist yet. Query the volume
        // of its nearest existing parent without creating any directories during setup.
        var directory = URL.applicationSupportDirectory
        while !FileManager.default.fileExists(atPath: directory.path) {
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = capacity?.volumeAvailableCapacityForImportantUsage ?? capacity?.volumeAvailableCapacity.map(Int64.init) ?? 0
        return evaluate(architecture: architecture, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                        memoryBytes: ProcessInfo.processInfo.physicalMemory, freeBytes: available)
    }
}

@Observable @MainActor
final class OnboardingCoordinator {
    var step: Int {
        didSet {
            let clamped = min(4, max(0, step))
            if step != clamped {
                step = clamped
                return
            }
            defaults.set(clamped, forKey: "relay.setup.step")
        }
    }
    private(set) var completed: Bool
    let hardware: MacReadiness
    var accessibilityGranted = AXIsProcessTrusted()
    let download: ModelDownload
    var isPreparingModel = false
    var modelSetupError: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparationRevision = 0
    @ObservationIgnored private let prepareOverride: ((AssistantStore) async -> Void)?

    init(defaults: UserDefaults = .standard, hardware: MacReadiness = .current(), download: ModelDownload? = nil,
         prepare: ((AssistantStore) async -> Void)? = nil) {
        self.defaults = defaults
        self.hardware = hardware
        self.download = download ?? ModelDownload()
        prepareOverride = prepare
        completed = defaults.bool(forKey: "relay.setup.completed.v1")
        step = min(4, max(0, defaults.integer(forKey: "relay.setup.step")))
    }

    func refreshPermissions() { accessibilityGranted = AXIsProcessTrusted() }
    func requestAccessibility() {
        accessibilityGranted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func useInstalledModel(store: AssistantStore) async {
        guard !isPreparingModel, !download.isBusy, !store.isRunning else { return }
        guard hardware.supported else { modelSetupError = hardware.summary; return }
        modelSetupError = nil
        // Reuse this session's verification only while file identity and mtime/ctime match.
        if !download.hasCurrentVerifiedInstallation { await download.verifyExisting() }
        guard !Task.isCancelled else { modelSetupError = "Model setup canceled. No model load was started."; return }
        guard let url = download.installedURL else {
            modelSetupError = download.errorMessage ?? (download.phase == .cancelled ? download.status : "No verified recommended model is available. Download it or import a compatible model.")
            return
        }
        store.configuration.modelPath = url.path
        store.saveConfiguration()
        await loadModel(store: store)
    }

    func loadModel(store: AssistantStore) async {
        guard !isPreparingModel, !store.isRunning, !download.isBusy else { return }
        guard hardware.supported else { modelSetupError = hardware.summary; return }
        isPreparingModel = true
        modelSetupError = nil
        preparationRevision += 1
        let expected = preparationRevision
        let pending = Task {
            if let prepareOverride { await prepareOverride(store) }
            else { await store.refreshModels() }
        }
        preparationTask = pending
        await pending.value
        guard preparationRevision == expected else { return }
        preparationTask = nil
        isPreparingModel = false
        if !store.actionsReady { modelSetupError = store.errorMessage ?? store.modelStatus }
    }

    func cancelPreparation(store: AssistantStore) {
        guard isPreparingModel else { return }
        preparationRevision += 1
        preparationTask?.cancel()
        preparationTask = nil
        store.unloadModel()
        isPreparingModel = false
        modelSetupError = "Loading canceled. The model is not ready; you can try again or finish setup later."
    }

    func finish() {
        guard !download.isBusy, !isPreparingModel else { return }
        completed = true
        defaults.set(true, forKey: "relay.setup.completed.v1")
    }

    func returnToSetup() {
        completed = false
        step = 0
        modelSetupError = nil
        refreshPermissions()
        defaults.set(false, forKey: "relay.setup.completed.v1")
    }
}
