import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

extension ModelManifest {
    static var gemma4E2B: ModelManifest { .recommended }
}

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
        let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let available = capacity?.volumeAvailableCapacity.map(Int64.init) ?? 0
        return evaluate(architecture: architecture, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                        memoryBytes: ProcessInfo.processInfo.physicalMemory, freeBytes: available)
    }
}

enum OnboardingProviderChoice: String, CaseIterable, Identifiable, Sendable {
    case onDeviceGemma = "gemma"
    case customLiteRT = "custom_litert"
    case claudeCLI = "claude_cli"
    case chatGPTCodex = "chatgpt_codex"
    case openRouter = "openrouter"
    case lmStudio = "lm_studio"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDeviceGemma: "On-Device Gemma 4"
        case .customLiteRT: "Import .litertlm"
        case .claudeCLI: "Claude Subscription"
        case .chatGPTCodex: "ChatGPT Subscription"
        case .openRouter: "OpenRouter API"
        case .lmStudio: "LM Studio Local"
        }
    }

    var badge: String {
        switch self {
        case .onDeviceGemma, .customLiteRT, .lmStudio: "100% Local"
        case .claudeCLI, .chatGPTCodex: "Existing CLI"
        case .openRouter: "Cloud API"
        }
    }

    var subtitle: String {
        switch self {
        case .onDeviceGemma: "Run on this Mac. No account needed."
        case .customLiteRT: "Choose a compatible model already on disk."
        case .claudeCLI: "Use your existing Claude Code sign-in."
        case .chatGPTCodex: "Use your existing Codex sign-in."
        case .openRouter: "Connect with your OpenRouter API key."
        case .lmStudio: "Connect a model served by LM Studio."
        }
    }

    var symbolName: String {
        switch self {
        case .onDeviceGemma: "cpu.fill"
        case .customLiteRT: "internaldrive.fill"
        case .claudeCLI: "sparkles"
        case .chatGPTCodex: "terminal.fill"
        case .openRouter: "network"
        case .lmStudio: "server.rack"
        }
    }
}

@Observable @MainActor
final class OnboardingCoordinator {
    static let completedKey = "relay.setup.completed.v1"
    static let stepKey = "relay.setup.step"
    static let providerChoiceKey = "relay.setup.providerChoice"
    static let gemmaVariantKey = "relay.setup.gemmaVariant"
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenCaptureSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var step: Int {
        didSet {
            let clamped = min(4, max(0, step))
            if step != clamped {
                step = clamped
                return
            }
            defaults.set(clamped, forKey: Self.stepKey)
        }
    }

    var selectedProvider: OnboardingProviderChoice {
        didSet {
            defaults.set(selectedProvider.rawValue, forKey: Self.providerChoiceKey)
        }
    }

    private(set) var completed: Bool
    let hardware: MacReadiness
    var accessibilityGranted = AXIsProcessTrusted()
    var screenCaptureGranted = CGPreflightScreenCaptureAccess()
    let download: ModelDownload
    let e4bDownload: ModelDownload
    var selectedGemmaVariant: ModelManifest {
        didSet { defaults.set(selectedGemmaVariant.filename, forKey: Self.gemmaVariantKey) }
    }
    var isPreparingModel = false
    var modelSetupError: String?
    enum CalculatorTrialState {
        case idle
        case running
        case checked(expression: String, result: ToolResult)
        case failed(String)
    }
    private(set) var calculatorTrial: CalculatorTrialState = .idle

    /// A genuine invocation of the same read-only calculator used by workspace tools.
    /// This intentionally does not impersonate a conversation task or its journal.
    func tryLocalCalculator(_ expression: String,
                            execute: ((ToolCall) async throws -> ToolResult)? = nil) async {
        if case .running = calculatorTrial { return }
        calculatorTrial = .running
        do {
            let call = ToolCall(name: "calculate", arguments: ["expression": .string(expression)])
            let result: ToolResult
            if let execute { result = try await execute(call) }
            else { result = try await MacTools().execute(call) }
            try Task.checkCancellation()
            guard result.verified else {
                calculatorTrial = .failed("The calculator returned an unchecked result. Try again; no checked outcome is available.")
                return
            }
            calculatorTrial = .checked(expression: expression, result: result)
        } catch is CancellationError {
            calculatorTrial = .failed("Calculation interrupted. You can try again.")
        } catch {
            calculatorTrial = .failed(error.localizedDescription)
        }
    }

    var magicReplyDemoCompleted = false
    var notchQuickAccessExplored = false

    var recommendedGemmaVariant: ModelManifest {
        hardware.memoryGB >= 16 ? .gemma4E4B : .gemma4E2B
    }

    var hasInstalledModel: Bool {
        download.installedURL != nil
            || download.existingFileAvailable
            || ModelManifest.resolveInstalledURL(for: download.manifest, in: download.directory) != nil
            || e4bDownload.installedURL != nil
            || ModelManifest.resolveInstalledURL(for: e4bDownload.manifest, in: e4bDownload.directory) != nil
            || e4bDownload.existingFileAvailable
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparationRevision = 0
    @ObservationIgnored private let prepareOverride: ((AssistantStore) async -> Void)?

    init(defaults: UserDefaults = .standard, hardware: MacReadiness = .current(), download: ModelDownload? = nil,
         e4bDownload: ModelDownload? = nil, prepare: ((AssistantStore) async -> Void)? = nil) {
        self.defaults = defaults
        self.hardware = hardware
        let primaryDownload = download ?? ModelDownload()
        let resolvedE4B = e4bDownload ?? ModelDownload(manifest: .gemma4E4B, directory: primaryDownload.directory)
        self.download = primaryDownload
        self.e4bDownload = resolvedE4B
        let recommended: ModelManifest = hardware.memoryGB >= 16 ? .gemma4E4B : .gemma4E2B
        if let savedFilename = defaults.string(forKey: Self.gemmaVariantKey),
           let saved = [ModelManifest.gemma4E2B, .gemma4E4B].first(where: { $0.filename == savedFilename }) {
            selectedGemmaVariant = saved
        } else if download != nil || e4bDownload != nil {
            let hasE4B = resolvedE4B.installedURL != nil
                || resolvedE4B.existingFileAvailable
                || ModelManifest.resolveInstalledURL(for: resolvedE4B.manifest, in: resolvedE4B.directory) != nil
            let hasE2B = primaryDownload.installedURL != nil
                || primaryDownload.existingFileAvailable
                || ModelManifest.resolveInstalledURL(for: primaryDownload.manifest, in: primaryDownload.directory) != nil
            if hasE4B && !hasE2B {
                selectedGemmaVariant = .gemma4E4B
            } else if hasE2B && !hasE4B {
                selectedGemmaVariant = .gemma4E2B
            } else {
                selectedGemmaVariant = recommended
            }
        } else {
            selectedGemmaVariant = recommended
        }
        prepareOverride = prepare
        completed = defaults.bool(forKey: Self.completedKey)
        step = min(4, max(0, defaults.integer(forKey: Self.stepKey)))
        if let raw = defaults.string(forKey: Self.providerChoiceKey),
           let saved = OnboardingProviderChoice(rawValue: raw) {
            selectedProvider = saved
        } else {
            selectedProvider = .onDeviceGemma
        }
    }

    func downloader(for manifest: ModelManifest) -> ModelDownload {
        manifest.filename == ModelManifest.gemma4E4B.filename ? e4bDownload : download
    }

    func isModelInstalled(_ manifest: ModelManifest) -> Bool {
        let target = downloader(for: manifest)
        return target.installedURL != nil
            || target.existingFileAvailable
            || ModelManifest.resolveInstalledURL(for: manifest, in: target.directory) != nil
    }

    func startModelDownload(_ manifest: ModelManifest) {
        selectedGemmaVariant = manifest
        downloader(for: manifest).start()
    }

    func activateModel(_ manifest: ModelManifest, store: AssistantStore) async {
        guard !isPreparingModel, !download.isBusy, !e4bDownload.isBusy, !store.isRunning else { return }
        guard hardware.supported else { modelSetupError = hardware.summary; return }
        selectedGemmaVariant = manifest
        modelSetupError = nil

        let target = downloader(for: manifest)
        if !target.hasCurrentVerifiedInstallation {
            await target.verifyExisting()
        }
        guard !Task.isCancelled else {
            modelSetupError = "Model setup canceled. No model load was started."
            return
        }
        guard let url = target.installedURL else {
            modelSetupError = target.errorMessage ?? (target.phase == .cancelled ? target.status : "No verified recommended model is available. Download it or import a compatible model.")
            return
        }
        store.configuration.backend = .liteRTLM
        store.configuration.modelPath = url.path
        store.configuration.model = manifest.displayName
        store.saveConfiguration()
        await loadModel(store: store)
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility(
        prompt: () -> Bool = { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) },
        isTrusted: () -> Bool = { AXIsProcessTrusted() },
        openURL: ((URL) -> Void)? = nil
    ) {
        _ = prompt()
        accessibilityGranted = isTrusted()
        if !accessibilityGranted {
            if let openURL {
                openURL(Self.accessibilitySettingsURL)
            } else {
                openAccessibilitySettings()
            }
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
    }

    @discardableResult
    func requestScreenCapture(
        request: () -> Bool = { CGRequestScreenCaptureAccess() },
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() },
        openURL: ((URL) -> Void)? = nil
    ) -> Bool {
        _ = request()
        let granted = preflight()
        screenCaptureGranted = granted
        if !granted {
            if let openURL {
                openURL(Self.screenCaptureSettingsURL)
            } else {
                openScreenCaptureSettings()
            }
        }
        return granted
    }

    func openScreenCaptureSettings() {
        NSWorkspace.shared.open(Self.screenCaptureSettingsURL)
    }

    func useInstalledModel(store: AssistantStore) async {
        guard !isPreparingModel, !download.isBusy, !e4bDownload.isBusy, !store.isRunning else { return }
        guard hardware.supported else { modelSetupError = hardware.summary; return }
        modelSetupError = nil

        if download.hasCurrentVerifiedInstallation || download.existingFileAvailable {
            // Reuse this session's verification only while file identity and mtime/ctime match.
            if !download.hasCurrentVerifiedInstallation { await download.verifyExisting() }
            guard !Task.isCancelled else { modelSetupError = "Model setup canceled. No model load was started."; return }
            if let url = download.installedURL {
                store.configuration.backend = .liteRTLM
                store.configuration.modelPath = url.path
                store.saveConfiguration()
                await loadModel(store: store)
                return
            }
            if !e4bDownload.hasCurrentVerifiedInstallation && !e4bDownload.existingFileAvailable {
                modelSetupError = download.errorMessage ?? (download.phase == .cancelled ? download.status : "No verified recommended model is available. Download it or import a compatible model.")
                return
            }
        }

        if e4bDownload.hasCurrentVerifiedInstallation || e4bDownload.existingFileAvailable {
            if !e4bDownload.hasCurrentVerifiedInstallation { await e4bDownload.verifyExisting() }
            guard !Task.isCancelled else { modelSetupError = "Model setup canceled. No model load was started."; return }
            if let url = e4bDownload.installedURL {
                store.configuration.backend = .liteRTLM
                store.configuration.modelPath = url.path
                store.configuration.model = e4bDownload.manifest.displayName
                store.saveConfiguration()
                await loadModel(store: store)
                return
            }
            modelSetupError = e4bDownload.errorMessage ?? (e4bDownload.phase == .cancelled ? e4bDownload.status : "No verified recommended model is available. Download it or import a compatible model.")
            return
        }

        if !download.hasCurrentVerifiedInstallation { await download.verifyExisting() }
        guard !Task.isCancelled else { modelSetupError = "Model setup canceled. No model load was started."; return }
        guard let url = download.installedURL else {
            modelSetupError = download.errorMessage ?? (download.phase == .cancelled ? download.status : "No verified recommended model is available. Download it or import a compatible model.")
            return
        }
        store.configuration.backend = .liteRTLM
        store.configuration.modelPath = url.path
        store.saveConfiguration()
        await loadModel(store: store)
    }

    func loadModel(store: AssistantStore) async {
        guard !isPreparingModel, !store.isRunning, !download.isBusy, !e4bDownload.isBusy else { return }
        guard store.configuration.backend != .liteRTLM || hardware.supported else { modelSetupError = hardware.summary; return }
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

    @discardableResult
    func grantCommonLocalFolder(_ directory: FileManager.SearchPathDirectory, store: AssistantStore) -> Bool {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return false }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: canonical.path) else { return false }
        if !store.grants.contains(where: { $0.path == canonical.path }) {
            store.grants.append(ScopeGrant(path: canonical.path, writable: false))
        }
        return true
    }

    func isCommonLocalFolderGranted(_ directory: FileManager.SearchPathDirectory, store: AssistantStore) -> Bool {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return false }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        return store.grants.contains(where: { $0.path == canonical.path })
    }

    func toggleCommonLocalFolder(_ directory: FileManager.SearchPathDirectory, store: AssistantStore) {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = store.grants.first(where: { $0.path == canonical.path }) {
            store.removeGrant(existing.id)
        } else {
            _ = grantCommonLocalFolder(directory, store: store)
        }
    }

    func selectedPersonalSourceCount(store: AssistantStore) -> Int {
        let liveCount = store.nativeSources.liveSources.enabledSources.count
        let calendarCount = store.preparation.calendarRefreshIDs.isEmpty ? 0 : 1
        let folderCount = store.grants.count
        return liveCount + calendarCount + folderCount
    }

    func finish() {
        guard !download.isBusy, !e4bDownload.isBusy, !isPreparingModel else { return }
        completed = true
        defaults.set(true, forKey: Self.completedKey)
    }

    func returnToSetup() {
        completed = false
        step = 0
        modelSetupError = nil
        magicReplyDemoCompleted = false
        notchQuickAccessExplored = false
        refreshPermissions()
        defaults.set(false, forKey: Self.completedKey)
    }
}
