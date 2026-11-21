import AppKit
import Foundation
import Observation
import Security
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class UninstallAndResetCoordinator {
    enum Phase: Equatable {
        case confirm
        case running
        case completed
        case failed(String)
    }

    enum StageID: String, CaseIterable, Identifiable, Sendable {
        case stopping
        case helper
        case cloud
        case keychain
        case knowledge
        case model
        case traces

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stopping: "Stop active tasks & background schedulers"
            case .helper: "Remove login item & wake schedule helper"
            case .cloud: "Remove hosted encrypted mirror snapshot"
            case .keychain: "Delete Relay API keys & tokens from Keychain"
            case .knowledge: "Erase learned knowledge, vault & conversation history"
            case .model: "Delete downloaded local AI models"
            case .traces: "Clear Relay caches, saved window state & preferences"
            }
        }
    }

    enum StageState: Equatable, Sendable {
        case pending
        case active
        case done
        case skipped(String)
    }

    struct StageStatus: Identifiable, Equatable, Sendable {
        let id: StageID
        var state: StageState = .pending
    }

    struct FactoryResetOutcome: Equatable, Sendable {
        let removedPaths: [String]
        let preservedModelFiles: Int
        let preservedExternalPaths: [String]
        let warnings: [String]
        var clearedKeychainServices: [String] = []
    }

    struct UninstallOutcome: Equatable, Sendable {
        let removedPaths: [String]
        let clearedKeychainServices: [String]
        let clearedDefaultsDomain: String?
        let preservedExternalPaths: [String]
        let skippedNotes: [String]
    }

    struct Environment {
        var supportDirectory: URL
        var libraryDirectory: URL
        var homeDirectory: URL
        var bundleIdentifier: String
        var appBundleURL: URL
        var defaults: UserDefaults
        var defaultsDomainName: String?
        var stopRuntime: @MainActor () async -> Void
        var resetStoreForFactoryReset: @MainActor (_ deleteDownloadedModels: Bool) async -> Void
        var disableLoginItem: @MainActor () throws -> Void
        var removeWakeHelper: @MainActor () async throws -> Void
        var deleteRemoteMirror: @MainActor () async -> String?
        var wipeKeychain: @MainActor () -> [String]
        var spawnPostExitSweep: @MainActor (_ script: String) throws -> Void
        var terminateApp: @MainActor () -> Void

        @MainActor
        static func live(store: AssistantStore) -> Self {
            let bundleID = Bundle.main.bundleIdentifier ?? "dev.relay.assistant"
            let support = URL.applicationSupportDirectory.appending(path: "Relay", directoryHint: .isDirectory)
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL.homeDirectory.appending(path: "Library", directoryHint: .isDirectory)
            return Self(
                supportDirectory: support,
                libraryDirectory: library,
                homeDirectory: URL.homeDirectory,
                bundleIdentifier: bundleID,
                appBundleURL: Bundle.main.bundleURL,
                defaults: .standard,
                defaultsDomainName: Bundle.main.bundleIdentifier,
                stopRuntime: {
                    await store.prepareForCleanUninstall()
                },
                resetStoreForFactoryReset: { deleteModels in
                    await store.performFactoryResetCleanup(deleteDownloadedModels: deleteModels)
                },
                disableLoginItem: {
                    if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                        try SMAppService.mainApp.unregister()
                    }
                },
                removeWakeHelper: {
                    if let managed = ManagedPreparationWake() {
                        await managed.remove()
                    }
                },
                deleteRemoteMirror: {
                    let mirror = HostedKnowledgeMirror.shared
                    if mirror.isEnabled {
                        await mirror.disable()
                    } else if mirror.deletionPending {
                        await mirror.synchronize(immediate: true)
                    }
                    if mirror.deletionPending {
                        return "Hosted mirror deletion could not reach the remote server; local mirror credentials will still be erased."
                    }
                    return nil
                },
                wipeKeychain: {
                    UninstallAndResetCoordinator.deleteRelayKeychainEntries()
                },
                spawnPostExitSweep: { script in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", script]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                },
                terminateApp: {
                    Darwin.exit(0)
                }
            )
        }
    }

    static let knownRelayKeychainServices: [String] = [
        OpenRouterCredentials.service,
        CustomResponsesCredentials.serviceName,
        KeychainOAuthGrantStore.defaultService,
        MagicReplyKeychain.service,
        "app.relay.hosted-knowledge-mirror.v1",
        "app.relay.oauth-mcp.v1",
        "app.relay.claude-cli.v1"
    ]

    private(set) var phase: Phase = .confirm
    private(set) var stages: [StageStatus] = StageID.allCases.map { StageStatus(id: $0) }
    private(set) var lastUninstallOutcome: UninstallOutcome?
    private(set) var lastFactoryResetOutcome: FactoryResetOutcome?
    private(set) var isPerformingFactoryReset = false
    private(set) var factoryResetError: String?

    @ObservationIgnored private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    convenience init(store: AssistantStore) {
        self.init(environment: .live(store: store))
    }

    var skippedSummary: [String] {
        stages.compactMap { item in
            if case .skipped(let reason) = item.state { return reason }
            return nil
        }
    }

    // MARK: - Factory Reset (SYS-09)

    @discardableResult
    func performFactoryReset(
        onboarding: OnboardingCoordinator?,
        deleteDownloadedModels: Bool = false,
        deferReturnToSetupOnWarnings: Bool = false
    ) async -> FactoryResetOutcome {
        guard !isPerformingFactoryReset else {
            return lastFactoryResetOutcome ?? FactoryResetOutcome(
                removedPaths: [], preservedModelFiles: 0, preservedExternalPaths: [], warnings: []
            )
        }
        NotificationCenter.default.post(name: Notification.Name("relay.willEraseLocalData"), object: nil)
        isPerformingFactoryReset = true
        factoryResetError = nil
        defer { isPerformingFactoryReset = false }

        var warnings: [String] = []
        var removedPaths: [String] = []

        // 1. Close open floating panels/overlays and stop active tasks, voice/speech, MCP server, and clear in-memory store state.
        NotchOverlayController.shared.hideFloatingNotchPanel()
        QuickTextActionPanelController.shared.close()
        DocumentSummaryPanelController.shared.closeAll()
        await environment.resetStoreForFactoryReset(deleteDownloadedModels)

        // 2. Remove remote hosted mirror if active.
        if let mirrorNote = await environment.deleteRemoteMirror() {
            warnings.append(mirrorNote)
        }

        // 3. Wipe Relay Keychain credentials (both legacy and Data Protection Keychain; never touches ~/.codex or ~/.claude).
        let clearedKeychain = environment.wipeKeychain()

        // 4. Remove support contents except Models/ (unless deleteDownloadedModels == true).
        let fm = FileManager.default
        let support = environment.supportDirectory.standardizedFileURL
        let modelsDir = support.appending(path: "Models", directoryHint: .isDirectory).standardizedFileURL
        var preservedModels = 0

        if fm.fileExists(atPath: support.path) {
            let children = (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                let canonical = child.standardizedFileURL
                if !deleteDownloadedModels && canonical.path == modelsDir.path {
                    let modelItems = (try? fm.contentsOfDirectory(atPath: modelsDir.path)) ?? []
                    preservedModels = modelItems.count
                    continue
                }
                do {
                    try fm.removeItem(at: canonical)
                    removedPaths.append(canonical.path)
                } catch {
                    warnings.append("Could not remove \(canonical.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // 5. Reset Relay setup/feature preferences so the user returns cleanly to Onboarding.
        Self.resetFactoryDefaults(environment.defaults)
        if warnings.isEmpty || !deferReturnToSetupOnWarnings {
            onboarding?.returnToSetup()
        }

        let preservedExternal = Self.verifyExternalUserPathsPreserved(homeDirectory: environment.homeDirectory)
        let outcome = FactoryResetOutcome(
            removedPaths: removedPaths,
            preservedModelFiles: preservedModels,
            preservedExternalPaths: preservedExternal,
            warnings: warnings,
            clearedKeychainServices: clearedKeychain
        )
        lastFactoryResetOutcome = outcome
        return outcome
    }

    // MARK: - Full Clean Uninstall (SYS-10)

    @discardableResult
    func performCleanUninstall() async -> UninstallOutcome {
        NotificationCenter.default.post(name: Notification.Name("relay.willEraseLocalData"), object: nil)
        phase = .running
        stages = StageID.allCases.map { StageStatus(id: $0) }
        var removedPaths: [String] = []
        var skippedNotes: [String] = []

        // Stage 1: Stop active runtime & background tasks
        setStage(.stopping, to: .active)
        await environment.stopRuntime()
        setStage(.stopping, to: .done)

        // Stage 2: Disable login item & wake schedule helper
        setStage(.helper, to: .active)
        var helperNotes: [String] = []
        do {
            try environment.disableLoginItem()
        } catch {
            helperNotes.append("Login item: \(error.localizedDescription)")
        }
        do {
            try await environment.removeWakeHelper()
        } catch {
            helperNotes.append("Wake helper: \(error.localizedDescription)")
        }
        if helperNotes.isEmpty {
            setStage(.helper, to: .done)
        } else {
            let note = helperNotes.joined(separator: " ")
            skippedNotes.append(note)
            setStage(.helper, to: .skipped(note))
        }

        // Stage 3: Delete remote encrypted knowledge mirror snapshot if active
        setStage(.cloud, to: .active)
        if let cloudNote = await environment.deleteRemoteMirror() {
            skippedNotes.append(cloudNote)
            setStage(.cloud, to: .skipped(cloudNote))
        } else {
            setStage(.cloud, to: .done)
        }

        // Stage 4: Wipe Relay Keychain credentials (preserving ~/.codex and ~/.claude)
        setStage(.keychain, to: .active)
        let clearedServices = environment.wipeKeychain()
        setStage(.keychain, to: .done)

        // Stage 5: Erase learned knowledge, vault, checkpoints & conversation state
        setStage(.knowledge, to: .active)
        let fm = FileManager.default
        let support = environment.supportDirectory.standardizedFileURL
        let modelsDir = support.appending(path: "Models", directoryHint: .isDirectory).standardizedFileURL
        var knowledgeError: String?
        if fm.fileExists(atPath: support.path) {
            let children = (try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)) ?? []
            for child in children where child.standardizedFileURL.path != modelsDir.path {
                do {
                    try fm.removeItem(at: child)
                    removedPaths.append(child.standardizedFileURL.path)
                } catch {
                    knowledgeError = error.localizedDescription
                }
            }
        }
        if let knowledgeError {
            let note = "Some support files were busy and will be swept on exit (\(knowledgeError))."
            skippedNotes.append(note)
            setStage(.knowledge, to: .skipped(note))
        } else {
            setStage(.knowledge, to: .done)
        }

        // Stage 6: Remove downloaded local models & support container
        setStage(.model, to: .active)
        var modelError: String?
        if fm.fileExists(atPath: modelsDir.path) {
            do {
                try fm.removeItem(at: modelsDir)
                removedPaths.append(modelsDir.path)
            } catch {
                modelError = error.localizedDescription
            }
        }
        if fm.fileExists(atPath: support.path) {
            do {
                try fm.removeItem(at: support)
                removedPaths.append(support.path)
            } catch {
                modelError = modelError ?? error.localizedDescription
            }
        }
        if let modelError {
            let note = "Model directory will finish deleting on exit (\(modelError))."
            skippedNotes.append(note)
            setStage(.model, to: .skipped(note))
        } else {
            setStage(.model, to: .done)
        }

        // Stage 7: Clear Relay caches, saved state, WebKit/HTTP storage & UserDefaults domain
        setStage(.traces, to: .active)
        for traceURL in traceDirectories() where fm.fileExists(atPath: traceURL.path) {
            if (try? fm.removeItem(at: traceURL)) != nil {
                removedPaths.append(traceURL.standardizedFileURL.path)
            }
        }
        let clearedDomain = clearDefaults()
        setStage(.traces, to: .done)

        let preservedExternal = Self.verifyExternalUserPathsPreserved(homeDirectory: environment.homeDirectory)
        let outcome = UninstallOutcome(
            removedPaths: removedPaths,
            clearedKeychainServices: clearedServices,
            clearedDefaultsDomain: clearedDomain,
            preservedExternalPaths: preservedExternal,
            skippedNotes: skippedNotes
        )
        lastUninstallOutcome = outcome
        phase = .completed
        return outcome
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([environment.appBundleURL])
    }

    func finishAndQuit() {
        let prefsPlist = environment.libraryDirectory
            .appending(path: "Preferences", directoryHint: .isDirectory)
            .appending(path: "\(environment.bundleIdentifier).plist")
        let script = Self.postExitCleanupScript(
            supportPath: environment.supportDirectory.path,
            tracePaths: traceDirectories().map(\.path),
            preferencesPlistPath: prefsPlist.path,
            parentPID: getpid()
        )
        try? environment.spawnPostExitSweep(script)
        environment.terminateApp()
    }

    // MARK: - Helpers & Testable Primitives

    private func setStage(_ id: StageID, to state: StageState) {
        if let index = stages.firstIndex(where: { $0.id == id }) {
            stages[index].state = state
        }
    }

    func traceDirectories() -> [URL] {
        let id = environment.bundleIdentifier
        let lib = environment.libraryDirectory
        return [
            lib.appending(path: "Caches", directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory),
            lib.appending(path: "HTTPStorages", directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory),
            lib.appending(path: "WebKit", directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory),
            lib.appending(path: "Saved Application State", directoryHint: .isDirectory).appending(path: "\(id).savedState", directoryHint: .isDirectory)
        ]
    }

    private func clearDefaults() -> String? {
        for key in Array(environment.defaults.dictionaryRepresentation().keys) where Self.isRelayPreferenceKey(key) {
            environment.defaults.removeObject(forKey: key)
        }
        if let domain = environment.defaultsDomainName, !domain.isEmpty {
            environment.defaults.removePersistentDomain(forName: domain)
            environment.defaults.synchronize()
            return domain
        }
        environment.defaults.synchronize()
        return nil
    }

    static func resetFactoryDefaults(_ defaults: UserDefaults) {
        for key in Array(defaults.dictionaryRepresentation().keys) where isRelayPreferenceKey(key) {
            defaults.removeObject(forKey: key)
        }
        defaults.set(false, forKey: OnboardingCoordinator.completedKey)
        defaults.set(0, forKey: OnboardingCoordinator.stepKey)
    }

    static func isRelayPreferenceKey(_ key: String) -> Bool {
        key.hasPrefix("relay.")
            || key.hasPrefix("preparation.")
            || key.hasPrefix("nativeWindowControl.")
            || key.hasPrefix("notch.")
            || key.hasPrefix("magicReply.")
            || key == "hosted-knowledge-mirror.v1"
            || key == SidekickTaskContext.instructionsPreference
    }

    static func deleteRelayKeychainEntries() -> [String] {
        var deleted: Set<String> = []
        if MagicReplyKeychain.destroyAllKeys() {
            deleted.insert(MagicReplyKeychain.service)
        }
        let swept = deleteRelayKeychainEntries(
            deleteItem: { SecItemDelete($0 as CFDictionary) },
            copyItems: { SecItemCopyMatching($0 as CFDictionary, $1) }
        )
        deleted.formUnion(swept)
        return deleted.sorted()
    }

    static func deleteRelayKeychainEntries(
        deleteItem: ([String: Any]) -> OSStatus,
        copyItems: ([String: Any], UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    ) -> [String] {
        var deleted: Set<String> = []
        let allServices = Array(Set(knownRelayKeychainServices + [
            KeychainOAuthGrantStore.defaultService,
            MagicReplyKeychain.service,
            OpenRouterCredentials.service,
            CustomResponsesCredentials.serviceName,
            "app.relay.magic-reply.v1"
        ])).sorted()

        // Delete from BOTH legacy macOS Keychain and Data Protection Keychain (`kSecUseDataProtectionKeychain: true`).
        for service in allServices {
            if service == OpenRouterCredentials.service {
                let openRouterExactQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: OpenRouterCredentials.service,
                    kSecAttrAccount as String: OpenRouterCredentials.account,
                    kSecAttrSynchronizable as String: false,
                    kSecUseDataProtectionKeychain as String: true
                ]
                if deleteItem(openRouterExactQuery) == errSecSuccess {
                    deleted.insert(service)
                }
            }
            for useDataProtection in [false, true] {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service
                ]
                if useDataProtection {
                    query[kSecUseDataProtectionKeychain as String] = true
                }
                if deleteItem(query) == errSecSuccess {
                    deleted.insert(service)
                }
            }
        }

        // Also sweep any additional Relay-namespaced generic password items (app.relay.* / dev.relay.* / com.relay.*)
        // across BOTH legacy Keychain and Data Protection Keychain while never touching ~/.codex, ~/.claude,
        // or third-party Keychain services.
        for useDataProtection in [false, true] {
            var listQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            if useDataProtection {
                listQuery[kSecUseDataProtectionKeychain as String] = true
            }
            var result: CFTypeRef?
            if copyItems(listQuery, &result) == errSecSuccess,
               let items = result as? [[String: Any]] {
                for item in items {
                    guard let service = item[kSecAttrService as String] as? String,
                          service.hasPrefix("app.relay.") || service.hasPrefix("dev.relay.") || service.hasPrefix("com.relay.") else {
                        continue
                    }
                    var deleteQuery: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service
                    ]
                    if let account = item[kSecAttrAccount as String] as? String {
                        deleteQuery[kSecAttrAccount as String] = account
                    }
                    if useDataProtection {
                        deleteQuery[kSecUseDataProtectionKeychain as String] = true
                    }
                    if deleteItem(deleteQuery) == errSecSuccess {
                        deleted.insert(service)
                    }
                }
            }
        }
        return deleted.sorted()
    }

    static func verifyExternalUserPathsPreserved(homeDirectory: URL) -> [String] {
        let fm = FileManager.default
        let candidates = [
            homeDirectory.appending(path: ".codex", directoryHint: .isDirectory),
            homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
        ]
        return candidates.filter { fm.fileExists(atPath: $0.path) }.map { $0.standardizedFileURL.path }
    }

    nonisolated static func postExitCleanupScript(
        supportPath: String,
        tracePaths: [String],
        preferencesPlistPath: String,
        parentPID: pid_t
    ) -> String {
        func shellQuote(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var targets = [shellQuote(supportPath), shellQuote(preferencesPlistPath)]
        targets.append(contentsOf: tracePaths.map(shellQuote))
        let joined = targets.joined(separator: " ")
        return """
        i=0
        while kill -0 \(parentPID) 2>/dev/null && [ $i -lt 50 ]; do
          sleep 0.1
          i=$((i + 1))
        done
        rm -rf \(joined) >/dev/null 2>&1 || true
        """
    }
}

// MARK: - Danger Button Style & Factory Reset Sheet (SYS-09)

struct RelayDangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RelayPageStyle.body.weight(.medium))
            .foregroundStyle(enabled ? RelayColors.buttonInk : RelayColors.textDim)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minHeight: RelayControlHeight.bar)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled ? RelayColors.accentCoral : RelayColors.subtleFill)
                    .overlay {
                        if enabled {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(configuration.isPressed ? 0.12 : (hovered ? 0.06 : 0)))
                        }
                    }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(enabled ? RelayColors.accentCoral.opacity(0.65) : RelayColors.borderSubtle.opacity(0.5), lineWidth: 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? RelayColors.focusRing : .clear, lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}

struct FactoryResetSheetView: View {
    let store: AssistantStore
    let onboarding: OnboardingCoordinator?
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: UninstallAndResetCoordinator
    @State private var deleteDownloadedModels = false
    @State private var completedWarnings: [String] = []

    init(store: AssistantStore, onboarding: OnboardingCoordinator?) {
        self.store = store
        self.onboarding = onboarding
        _coordinator = State(initialValue: UninstallAndResetCoordinator(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: completedWarnings.isEmpty ? "arrow.counterclockwise.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(RelayColors.accentAmber)
                VStack(alignment: .leading, spacing: 3) {
                    Text(completedWarnings.isEmpty ? "Factory Reset Relay" : "Factory Reset Completed with Warnings")
                        .font(RelayPageStyle.dialogTitle)
                        .foregroundStyle(RelayPalette.ink)
                    Text(completedWarnings.isEmpty
                         ? "Erase learned knowledge, conversations, and local setup, then return to Onboarding."
                         : "Relay erased local state, with the following notes before returning to Setup.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(RelayPalette.muted)
                }
            }

            if completedWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    resetBullet("Clears conversation history, proactive cards, writing style, and Knowledge Vault notes.")
                    resetBullet("Clears Relay Keychain API keys, OAuth grants, folder grants, and source checkpoints.")
                    resetBullet("Leaves your own files, ~/.codex, and ~/.claude completely untouched.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .relayFormSection()

                Toggle(isOn: $deleteDownloadedModels) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also delete downloaded on-device Gemma models")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(RelayPalette.ink)
                        Text("Keep this off to avoid re-downloading multi-gigabyte .litertlm files during setup.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(RelayPalette.muted)
                    }
                }
                .toggleStyle(.checkbox)

                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(coordinator.isPerformingFactoryReset)
                    Spacer()
                    Button(role: .destructive) {
                        Task {
                            let outcome = await coordinator.performFactoryReset(
                                onboarding: onboarding,
                                deleteDownloadedModels: deleteDownloadedModels,
                                deferReturnToSetupOnWarnings: true
                            )
                            if outcome.warnings.isEmpty {
                                dismiss()
                            } else {
                                completedWarnings = outcome.warnings
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if coordinator.isPerformingFactoryReset {
                                ProgressView().controlSize(.small)
                            }
                            Text(coordinator.isPerformingFactoryReset ? "Resetting…" : "Erase & Return to Setup")
                        }
                    }
                    .buttonStyle(RelayDangerButtonStyle())
                    .disabled(coordinator.isPerformingFactoryReset)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(completedWarnings.enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(RelayColors.accentAmber)
                                .padding(.top, 2)
                            Text(warning)
                                .font(.system(size: 12))
                                .foregroundStyle(RelayPalette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .relayFormSection()

                HStack {
                    Spacer()
                    Button("Done") {
                        onboarding?.returnToSetup()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(RelaySecondaryButtonStyle())
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .relayPageBackground()
        .relayPreferredAppearance()
        .interactiveDismissDisabled(coordinator.isPerformingFactoryReset)
    }

    private func resetBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(RelayPalette.muted)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(RelayPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Clean Uninstall Sheet (SYS-10)

struct CleanUninstallSheetView: View {
    let store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: UninstallAndResetCoordinator

    init(store: AssistantStore) {
        self.store = store
        _coordinator = State(initialValue: UninstallAndResetCoordinator(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            switch coordinator.phase {
            case .confirm:
                confirmationBody
            case .running, .completed:
                progressBody
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(RelayColors.accentCoral)
            }

            footerButtons
        }
        .padding(24)
        .frame(width: 520)
        .relayPageBackground()
        .relayPreferredAppearance()
        .interactiveDismissDisabled(coordinator.phase == .running)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: coordinator.phase == .completed ? "checkmark.seal.fill" : "trash.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(coordinator.phase == .completed ? RelayColors.accentEmerald : RelayColors.accentCoral)
            VStack(alignment: .leading, spacing: 3) {
                Text(coordinator.phase == .completed ? "Relay Data Removed" : "Clean Uninstall Relay")
                    .font(RelayPageStyle.dialogTitle)
                    .foregroundStyle(RelayPalette.ink)
                Text(coordinator.phase == .completed
                     ? "All Relay models, knowledge, credentials, helpers, and caches have been cleaned up."
                     : "Remove every file, model, Keychain secret, wake schedule, and cache Relay created on this Mac.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(RelayPalette.muted)
            }
        }
    }

    private var confirmationBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(UninstallAndResetCoordinator.StageID.allCases, id: \.self) { stage in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(RelayPalette.muted)
                    Text(stage.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(RelayPalette.inkSecondary)
                }
            }
            Divider().padding(.vertical, 4)
            Text("Your personal folders, Apple Notes/Mail/Messages, ~/.codex, and ~/.claude are never modified.")
                .font(RelayPageStyle.caption.weight(.medium))
                .foregroundStyle(RelayPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayFormSection()
    }

    private var progressBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(coordinator.stages, id: \.id) { stage in
                HStack(spacing: 10) {
                    stageIcon(for: stage.state)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.id.title)
                            .font(.system(size: 12.5, weight: stage.state == .active ? .semibold : .regular))
                            .foregroundStyle(RelayPalette.ink)
                        if case .skipped(let reason) = stage.state {
                            Text(reason)
                                .font(.system(size: 11))
                                .foregroundStyle(RelayColors.accentAmber)
                        }
                    }
                    Spacer()
                }
            }

            if coordinator.phase == .completed {
                Divider().padding(.vertical, 4)
                Text("Final step: click “Show App in Finder” to drag Relay.app to the Trash, or click “Quit & Sweep” to exit cleanly.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RelayPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayFormSection()
    }

    @ViewBuilder
    private func stageIcon(for state: UninstallAndResetCoordinator.StageState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 12))
                .foregroundStyle(RelayPalette.subtle)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(RelayColors.accentEmerald)
        case .skipped:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(RelayColors.accentAmber)
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 10) {
            switch coordinator.phase {
            case .confirm, .failed:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(RelaySecondaryButtonStyle())
                Spacer()
                Button(role: .destructive) {
                    Task { _ = await coordinator.performCleanUninstall() }
                } label: {
                    Text("Erase All Relay Data")
                }
                .buttonStyle(RelayDangerButtonStyle())

            case .running:
                Spacer()
                Text("Cleaning up Relay data…")
                    .font(.system(size: 12))
                    .foregroundStyle(RelayPalette.muted)

            case .completed:
                Button("Show App in Finder") {
                    coordinator.revealAppInFinder()
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                Spacer()
                Button("Quit & Sweep") {
                    coordinator.finishAndQuit()
                }
                .buttonStyle(RelayDangerButtonStyle())
            }
        }
    }
}
