import Foundation

nonisolated enum DiagnosticsPermissionStatus: String, Codable, Sendable {
    case allowed, denied, notRequested, unknown
}
nonisolated enum DiagnosticsCheckStatus: String, Codable, Sendable {
    case passed, failed, notRun, unknown
}
nonisolated enum DiagnosticsComputeBackend: String, Codable, Sendable {
    case cpu, gpu, unknown
}
nonisolated enum DiagnosticsArchitecture: String, Codable, Sendable {
    case appleSilicon, intel, unknown
}
nonisolated enum DiagnosticsRunState: String, Codable, Sendable {
    case idle, thinking, acting, awaitingReview, stopped, failed, needsInput, completed, unknown
}
nonisolated enum DiagnosticsIssueCode: String, Codable, Sendable {
    case modelNotConfigured, modelLoadFailed, toolProbeFailed
    case accessibilityDenied, accessibilityCommunicationFailed
    case sourceIndexUnavailable, localPersistenceFailed, shortcutUnavailable
    case taskLimitReached, unknownComponentFailure

    var recovery: String {
        switch self {
        case .modelNotConfigured: "Choose a compatible local .litertlm model in Settings."
        case .modelLoadFailed: "Check the local model package and selected CPU/GPU backend, then load it explicitly."
        case .toolProbeFailed: "Choose a tool-capable model and rerun the local capability check."
        case .accessibilityDenied: "Enable Relay's Accessibility permission directly in macOS, then check again."
        case .accessibilityCommunicationFailed: "Inspect the target app and refresh its accessible controls before retrying."
        case .sourceIndexUnavailable: "Review selected sources and run an explicit local reindex."
        case .localPersistenceFailed: "Check the app's local storage access. Unsaved changes may not survive relaunch."
        case .shortcutUnavailable: "Check for another app using the shortcut; quick access can remain off."
        case .taskLimitReached: "Inspect completed and uncertain effects before continuing with a narrower request."
        case .unknownComponentFailure: "Inspect the affected component in Relay Settings; no raw error content is included in this export."
        }
    }
}

/// Explicit technical values only. This API deliberately cannot accept chat transcripts,
/// source text, selected text, arbitrary errors, paths, model filenames or machine/user IDs.
/// Version strings are the sole free-text inputs and are restricted to numeric dotted versions.
nonisolated struct DiagnosticsInput: Sendable {
    var appVersion: String? = nil
    var appBuild: String? = nil
    var runtimeVersion: String? = nil
    var osVersion: String? = nil
    var architecture: DiagnosticsArchitecture = .unknown
    var computeBackend: DiagnosticsComputeBackend = .unknown
    var modelSelected = false
    var modelLoaded: Bool? = nil
    var toolProbe: DiagnosticsCheckStatus = .unknown
    var accessibility: DiagnosticsPermissionStatus = .unknown
    var microphone: DiagnosticsPermissionStatus = .unknown
    var screenRecording: DiagnosticsPermissionStatus = .unknown
    var runState: DiagnosticsRunState = .unknown
    var quickAccessEnabled = false
    var indexedSourceCount = 0
    var approvedMemoryCount = 0
    var recentActivityCount = 0
    var recentFailureCount = 0
    var issues: [DiagnosticsIssueCode] = []
}

nonisolated struct DiagnosticsIssue: Codable, Sendable {
    let code: DiagnosticsIssueCode
    let recovery: String
}

nonisolated struct DiagnosticsReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let app: String
    let runtime: String
    let inferenceMode: String
    let appVersion: String?
    let appBuild: String?
    let runtimeVersion: String?
    let osVersion: String?
    let architecture: DiagnosticsArchitecture
    let computeBackend: DiagnosticsComputeBackend
    let modelSelected: Bool
    let modelLoaded: Bool?
    let toolProbe: DiagnosticsCheckStatus
    let accessibility: DiagnosticsPermissionStatus
    let microphone: DiagnosticsPermissionStatus
    let screenRecording: DiagnosticsPermissionStatus
    let runState: DiagnosticsRunState
    let quickAccessEnabled: Bool
    let indexedSourceCount: Int
    let approvedMemoryCount: Int
    let recentActivityCount: Int
    let recentFailureCount: Int
    let issues: [DiagnosticsIssue]
    let privacyNotice: String
}

/// Constructs an inspectable local export. No system inspection, filesystem access, network,
/// telemetry or implicit collection occurs. A caller chooses if and where to save the bytes.
nonisolated enum LocalDiagnostics {
    static func makeReport(_ input: DiagnosticsInput, generatedAt: Date = Date()) -> DiagnosticsReport {
        var seen = Set<DiagnosticsIssueCode>()
        let issues = input.issues.prefix(100).filter { seen.insert($0).inserted }.prefix(20).map {
            DiagnosticsIssue(code: $0, recovery: $0.recovery)
        }
        return DiagnosticsReport(schemaVersion: 1, generatedAt: generatedAt, app: "Relay", runtime: "LiteRT-LM", inferenceMode: "localOnly",
                                 appVersion: safeVersion(input.appVersion), appBuild: safeVersion(input.appBuild),
                                 runtimeVersion: safeVersion(input.runtimeVersion), osVersion: safeVersion(input.osVersion),
                                 architecture: input.architecture, computeBackend: input.computeBackend,
                                 modelSelected: input.modelSelected, modelLoaded: input.modelLoaded, toolProbe: input.toolProbe,
                                 accessibility: input.accessibility, microphone: input.microphone, screenRecording: input.screenRecording,
                                 runState: input.runState, quickAccessEnabled: input.quickAccessEnabled,
                                 indexedSourceCount: boundedCount(input.indexedSourceCount), approvedMemoryCount: boundedCount(input.approvedMemoryCount),
                                 recentActivityCount: boundedCount(input.recentActivityCount), recentFailureCount: boundedCount(input.recentFailureCount),
                                 issues: issues,
                                 privacyNotice: "Contains technical status and aggregate counts only. Conversations, selected text, source content, filenames, personal paths, model files, writing samples and personal/device identifiers are excluded. Nothing is uploaded automatically.")
    }

    static func exportJSON(_ input: DiagnosticsInput, generatedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(makeReport(input, generatedAt: generatedAt))
        guard data.count <= 16_384 else { throw RelayError.message("The technical diagnostics export exceeded its bounded size.") }
        return data
    }

    private static func boundedCount(_ value: Int) -> Int { min(1_000_000, max(0, value)) }

    /// Reject instead of trying to scrub arbitrary strings: this preserves no fragments of
    /// a personal path, URL, chat message, secret or custom model name disguised as metadata.
    private static func safeVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard !raw.isEmpty, raw.utf8.count <= 32 else { return "[omitted]" }
        let segments = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(segments.count), segments.allSatisfy({ segment in
            (1...8).contains(segment.count) && segment.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return "[omitted]" }
        return raw
    }
}
