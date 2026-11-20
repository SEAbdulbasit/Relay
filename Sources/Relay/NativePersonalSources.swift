import Foundation
import Observation
import CryptoKit

nonisolated enum NativePersonalSourceKind: String, CaseIterable, Sendable, Identifiable {
    case notes, mail

    var id: String { rawValue }
    var displayName: String { self == .notes ? "Apple Notes" : "Apple Mail" }
    var itemsName: String { self == .notes ? "notes" : "messages" }
    var bundleIdentifier: String { self == .notes ? "com.apple.Notes" : "com.apple.mail" }
    var bundlePath: String { self == .notes ? "/System/Applications/Notes.app" : "/System/Applications/Mail.app" }
}

nonisolated struct NativeNotesAttribution: Sendable, Equatable {
    let noteID: String
    let folder: String?
    let createdAt: Date
    let updatedAt: Date?
}

nonisolated struct NativePersonalSourceItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let sender: String?
    let text: String
    let textLimited: Bool
    let sentAt: Date?
    let receivedAt: Date?
    let notesAttribution: NativeNotesAttribution?

    init(id: String, title: String, sender: String?, text: String, textLimited: Bool,
         sentAt: Date? = nil, receivedAt: Date? = nil, notesAttribution: NativeNotesAttribution? = nil) {
        self.id = id
        self.title = title
        self.sender = sender
        self.text = text
        self.textLimited = textLimited
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.notesAttribution = notesAttribution
    }

    fileprivate var labels: [String] {
        [sender.map { "Sender: \($0)" }, sentAt.map { "Sent: \($0.ISO8601Format())" },
         receivedAt.map { "Received: \($0.ISO8601Format())" }].compactMap { $0 }
            + (notesAttribution.map { value in
                ["Note ID: " + value.noteID, value.folder.map { "Folder: " + $0 },
                 "Created: " + value.createdAt.ISO8601Format(), value.updatedAt.map { "Updated: " + $0.ISO8601Format() }].compactMap { $0 }
            } ?? [])
    }

    fileprivate var searchableFields: [String] {
        [title, text] + [sender, sentAt?.ISO8601Format(), receivedAt?.ISO8601Format(), notesAttribution?.folder, notesAttribution?.noteID].compactMap { $0 }
    }
}

nonisolated struct NativePersonalSourceBatch: Sendable {
    let items: [NativePersonalSourceItem]
    let skipped: Int
    var scope: NativePersonalSourceScope? = nil
    var notesBackup: NotesBackupIdentity? = nil
    var notesImport: NotesImportCoverage? = nil
}

nonisolated struct NativePersonalSourceScope: Equatable, Sendable {
    struct Application: Equatable, Sendable {
        let pid: Int32
        let launchedAt: Date
    }

    let kind: NativePersonalSourceKind
    let application: Application
    let references: [Data]

    static func itemID(for reference: Data) -> String {
        SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined()
    }

    func containsOnly(_ items: [NativePersonalSourceItem], kind: NativePersonalSourceKind) -> Bool {
        self.kind == kind && !references.isEmpty && references.count <= NativeSourceAppleEvents.maximumSelection
            && Set(references).count == references.count
            && references.allSatisfy { !$0.isEmpty && $0.count <= 4_096 }
            && references.count == items.count && Set(items.map(\.id)) == Set(references.map(Self.itemID))
    }
}

/// Captured content and optional refresh scopes stay in memory for this session.
@Observable @MainActor
final class NativePersonalSources {
    typealias Capture = @MainActor (NativePersonalSourceKind, Bool) async throws -> NativePersonalSourceBatch
    typealias Refresh = @MainActor (NativePersonalSourceScope) async throws -> NativePersonalSourceBatch

    nonisolated struct Snapshot: Sendable {
        let capturedAt: Date
        let items: [NativePersonalSourceItem]
        let skipped: Int
        let scope: NativePersonalSourceScope?
        let notesBackup: NotesBackupIdentity?
        let notesImport: NotesImportCoverage?
    }

    private(set) var snapshots: [NativePersonalSourceKind: Snapshot] = [:]
    private var statuses: [NativePersonalSourceKind: String] = [:]
    private var refreshEnabled: Set<NativePersonalSourceKind> = []
    private var stale: Set<NativePersonalSourceKind> = []
    private(set) var capturing: NativePersonalSourceKind?
    private(set) var refreshing: NativePersonalSourceKind?
    var isCapturing: Bool { capturing != nil || notesForgetTask != nil }

    @ObservationIgnored var onContextInvalidated: ((NativePersonalSourceKind) -> Void)?
    @ObservationIgnored var isBusy: () -> Bool = { false }
    @ObservationIgnored private let capture: Capture
    @ObservationIgnored private let refresh: Refresh
    @ObservationIgnored private let automaticRefresh: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pendingCapture: Task<NativePersonalSourceBatch, Error>?
    @ObservationIgnored private var refreshTimer: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let notesImporter: NotesDatabaseIngestion
    let liveSources: LiveLocalSourcesCoordinator
    private(set) var hasNotesImportCache = false
    @ObservationIgnored private var notesForgetTask: Task<Void, Never>?
    @ObservationIgnored private var notesForgetOwner: UUID?

    convenience init(capture: Capture? = nil) {
        self.init(capture: capture, refresh: nil)
    }

    init(capture: Capture? = nil, refresh: Refresh?, automaticRefresh: Bool = true, now: @escaping () -> Date = Date.init,
         notesImporter: NotesDatabaseIngestion = .shared,
         liveSources: LiveLocalSourcesCoordinator? = nil) {
        let isTestHarness = capture != nil || refresh != nil
        self.capture = capture ?? { try await NativeSourceAppleEvents.captureSelected($0, requestPermission: $1) }
        self.refresh = refresh ?? { try await NativeSourceAppleEvents.refreshCaptured($0) }
        self.automaticRefresh = automaticRefresh
        self.now = now
        self.notesImporter = notesImporter
        self.liveSources = liveSources ?? LiveLocalSourcesCoordinator(
            directoryURL: isTestHarness ? nil : LiveLocalSourcesCoordinator.defaultDirectoryURL,
            fullDiskAccessProbe: isTestHarness ? { FullDiskAccessStatus(granted: false, matchedProbe: "none", errnoCode: ENOENT) } : nil
        )
        self.liveSources.onContextChanged = { [weak self] in
            self?.onContextInvalidated?(.notes)
        }
    }

    func status(for kind: NativePersonalSourceKind) -> String {
        statuses[kind] ?? "No selection captured in this session."
    }

    func items(for kind: NativePersonalSourceKind) -> [NativePersonalSourceItem] { snapshots[kind]?.items ?? [] }

    func canRefresh(_ kind: NativePersonalSourceKind) -> Bool { snapshots[kind]?.scope != nil }

    func isRefreshEnabled(_ kind: NativePersonalSourceKind) -> Bool { refreshEnabled.contains(kind) }

    func setRefreshEnabled(_ enabled: Bool, for kind: NativePersonalSourceKind) {
        if enabled {
            guard canRefresh(kind), capturing != kind else { return }
            refreshEnabled.insert(kind)
            statuses[kind] = "Keeping these captured \(kind.itemsName) fresh while Relay runs."
        } else {
            refreshEnabled.remove(kind)
            if refreshing == kind {
                revision += 1
                pendingCapture?.cancel()
            }
            statuses[kind] = stale.contains(kind)
                ? "Automatic refresh is off. Refresh now or capture again before using this source."
                : "Automatic refresh is off. The last captured snapshot is available."
        }
        updateRefreshTimer()
    }

    func refreshCaptured(_ kind: NativePersonalSourceKind) async {
        guard !isCapturing, !isBusy(), !Task.isCancelled, let scope = snapshots[kind]?.scope else { return }
        await run(kind, scope: scope, requestPermission: false)
    }

    func refreshEnabledSources() async {
        for kind in NativePersonalSourceKind.allCases where refreshEnabled.contains(kind) {
            guard !isCapturing, !isBusy(), !Task.isCancelled else { return }
            await refreshCaptured(kind)
        }
    }

    /// Called only by the explicit source control. The OS permission dialog is optional for
    /// callers that are qualifying an already authorized source without triggering a prompt.
    func captureSelection(_ kind: NativePersonalSourceKind, requestPermission: Bool = true) async {
        guard !isCapturing, !Task.isCancelled else { return }
        refreshEnabled.remove(kind)
        updateRefreshTimer()
        await run(kind, scope: nil, requestPermission: requestPermission)
    }

    /// Dedicated explicit backup selection, never a home/Library lookup or an
    /// automatic import. Resumption always rereads the same actual chosen file.
    func importNotesBackup(_ selected: URL) async {
        guard !isCapturing, !isBusy(), notesForgetTask == nil, !Task.isCancelled else { return }
        hasNotesImportCache = true
        refreshEnabled.remove(.notes); updateRefreshTimer()
        await run(.notes, scope: nil, requestPermission: false, notesBackup: selected)
    }

    private func run(_ kind: NativePersonalSourceKind, scope: NativePersonalSourceScope?, requestPermission: Bool,
                     notesBackup: URL? = nil) async {
        capturing = kind
        refreshing = scope == nil ? nil : kind
        statuses[kind] = scope == nil ? "Reading the selected \(kind.itemsName) on this Mac…" : "Refreshing the captured \(kind.itemsName)…"
        let expected = revision
        let task = Task {
            if let notesBackup { return try await notesImporter.importBackup(notesBackup) }
            if let scope { return try await refresh(scope) }
            return try await capture(kind, requestPermission)
        }
        pendingCapture = task
        defer { pendingCapture = nil; capturing = nil; refreshing = nil }

        do {
            let batch = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard revision == expected, !task.isCancelled else { throw CancellationError() }
            try batch.notesBackup?.validateCurrent()
            guard batch.notesBackup == nil || (kind == .notes && scope == nil && notesBackup != nil) else {
                throw NotesDatabaseIngestion.Failure.backup
            }
            guard !batch.items.isEmpty else {
                if scope != nil { throw NativeSourceAppleEvents.Failure.noSelection }
                throw RelayError.message("None of the selected \(kind.itemsName) exposed usable plain text. The previous snapshot was kept.")
            }
            if let capturedScope = batch.scope, !capturedScope.containsOnly(batch.items, kind: kind) {
                throw NativeSourceAppleEvents.Failure.malformedSelection
            }
            if let scope {
                guard let refreshedScope = batch.scope, refreshedScope.application == scope.application,
                      Set(refreshedScope.references).isSubset(of: Set(scope.references)) else {
                    throw NativeSourceAppleEvents.Failure.selectionChanged
                }
            }
            let previous = snapshots[kind]
            let wasStale = stale.remove(kind) != nil
            snapshots[kind] = Snapshot(capturedAt: now(), items: batch.items, skipped: batch.skipped, scope: batch.scope,
                notesBackup: batch.notesBackup, notesImport: batch.notesImport)
            statuses[kind] = (scope == nil ? "Captured " : "Refreshed ") + "\(batch.items.count) for this session."
                + (batch.skipped > 0 ? " Skipped \(batch.skipped) protected or unavailable items." : "")
                + (batch.items.contains(where: \.textLimited) ? " Some text exceeded the capture limit." : "")
                + (batch.notesImport.map { " " + $0.description } ?? "")
            if let previous, scope == nil || wasStale || previous.items != batch.items || previous.skipped != batch.skipped {
                onContextInvalidated?(kind)
            }
        } catch is CancellationError {
            if revision == expected { statuses[kind] = "Capture stopped. The previous snapshot was kept." }
        } catch {
            guard revision == expected, !task.isCancelled else { return }
            if scope == nil { statuses[kind] = error.localizedDescription }
            else { refreshFailed(kind, error: error) }
        }
    }

    func cancelCapture() {
        guard let pendingCapture, let capturing else { return }
        if refreshing == capturing {
            refreshEnabled.remove(capturing)
            updateRefreshTimer()
        }
        pendingCapture.cancel()
        statuses[capturing] = "Stopping capture…"
    }

    @discardableResult
    func forget(_ kind: NativePersonalSourceKind) -> Task<Void, Never>? {
        if capturing == kind {
            revision += 1
            cancelCapture()
        }
        let wasCaptured = snapshots.removeValue(forKey: kind) != nil
        refreshEnabled.remove(kind)
        stale.remove(kind)
        updateRefreshTimer()
        statuses[kind] = "Selection forgotten for this session."
        if kind == .notes, hasNotesImportCache { _ = beginForgettingNotesImports() }
        if wasCaptured { onContextInvalidated?(kind) }
        return kind == .notes ? notesForgetTask : nil
    }

    /// Explicit user cleanup remains available after relaunch, without loading
    /// any cache index/body or assuming an in-memory snapshot still exists.
    @discardableResult
    func forgetSavedNotesImports() -> Task<Void, Never> {
        _ = forget(.notes)
        return beginForgettingNotesImports()
    }

    private func beginForgettingNotesImports() -> Task<Void, Never> {
        if let notesForgetTask { return notesForgetTask }
        let importer = notesImporter, owner = UUID(), expected = revision
        notesForgetOwner = owner
        let task = Task { [weak self] in
            let removed: Bool
            do { try await importer.forget(); removed = true }
            catch { removed = false }
            guard let self, self.notesForgetOwner == owner else { return }
            self.hasNotesImportCache = !removed
            if self.revision == expected {
                self.statuses[.notes] = removed
                    ? "Captured Notes and saved backup-import progress forgotten. Original backups are unchanged."
                    : "Captured Notes forgotten. Saved import progress could not be removed; use Forget saved imports to try again."
            }
            self.notesForgetTask = nil
            self.notesForgetOwner = nil
        }
        notesForgetTask = task
        return task
    }

    func read(kind: NativePersonalSourceKind, query: String? = nil) throws -> ToolResult {
        guard let snapshot = snapshots[kind] else {
            let liveKind: LiveLocalSourceKind = (kind == .notes) ? .notes : .appleMail
            if liveSources.isEnabled(liveKind), !liveSources.items(for: liveKind).isEmpty {
                return try readLiveSource(kind: liveKind, query: query)
            }
            throw RelayError.message("Capture selected \(kind.itemsName) in Relay Settings before using \(kind.displayName) as a source.")
        }
        guard !stale.contains(kind) else {
            throw RelayError.message("The captured \(kind.itemsName) could not be verified on the last refresh. Refresh them or capture again before using this source.")
        }
        try snapshot.notesBackup?.validateCurrent()
        let term = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.utf8.count <= 256, !term.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw RelayError.message("Search the captured selection using plain text up to 256 UTF-8 bytes.")
        }
        let matches = snapshot.items.filter { item in
            term.isEmpty || item.searchableFields.contains { $0.localizedStandardContains(term) }
        }
        let header = "\(kind.displayName) selection captured at \(snapshot.capturedAt.ISO8601Format()) (untrusted source text)."
            + (snapshot.notesImport.map { "\n" + $0.description } ?? "")
        guard !matches.isEmpty else {
            let coverage = snapshot.items.contains(where: \.textLimited) ? " Some text was omitted by capture limits." : ""
            return ToolResult(summary: header + "\nNo matching text in the captured selection.",
                              evidence: "Checked only the \(snapshot.items.count) captured items. The rest of \(kind.displayName) was not searched.\(coverage)", verified: true)
        }
        var summary = header
        var limited = false
        for item in matches {
            let heading = "\n\n" + ([item.title] + item.labels).joined(separator: "\n") + "\n"
            let remaining = 11_000 - summary.utf8.count - heading.utf8.count
            guard remaining > 0 else { limited = true; break }
            let body = Self.bounded(item.text, maximumBytes: remaining)
            summary += heading + body
            if item.textLimited || body.utf8.count < item.text.utf8.count { limited = true }
        }
        let coverage = limited ? " Some captured text was omitted by size limits." : ""
        let skipped = snapshot.skipped > 0 ? " \(snapshot.skipped) selected items were unavailable or protected at capture." : ""
        return ToolResult(summary: summary, evidence: "Read only the explicit in-memory selection snapshot, with no live app action.\(coverage)\(skipped)", verified: true)
    }

    func readLiveSource(kind: LiveLocalSourceKind, query: String? = nil) throws -> ToolResult {
        guard liveSources.isEnabled(kind) else {
            throw RelayError.message("Enable live \(kind.title) sync in Relay Settings before reading \(kind.title).")
        }
        let term = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.utf8.count <= 256, !term.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw RelayError.message("Search \(kind.title) using plain text up to 256 UTF-8 bytes.")
        }
        let items = liveSources.items(for: kind).sorted { $0.timestamp > $1.timestamp }
        guard !items.isEmpty else {
            throw RelayError.message("No \(kind.title) items have been synced yet. Run Sync Now in Relay Settings.")
        }
        let matches = items.filter { item in
            term.isEmpty
                || item.title.localizedStandardContains(term)
                || item.subtitle.localizedStandardContains(term)
                || item.body.localizedStandardContains(term)
        }
        let header = "Live \(kind.title) incremental index (\(items.count) checkpointed item(s); untrusted source text)."
        guard !matches.isEmpty else {
            return ToolResult(
                summary: header + "\nNo matching text in synced \(kind.title) items.",
                evidence: "Searched \(items.count) checkpointed \(kind.title) item(s).",
                verified: true
            )
        }
        var summary = header
        var limited = false
        for item in matches {
            let heading = "\n\n\(item.title)\n\(item.subtitle) · \(item.timestamp.ISO8601Format())\n"
            let remaining = 11_000 - summary.utf8.count - heading.utf8.count
            guard remaining > 0 else { limited = true; break }
            let body = Self.bounded(item.body, maximumBytes: remaining)
            summary += heading + body
            if body.utf8.count < item.body.utf8.count { limited = true }
        }
        let coverage = limited ? " Some synced text was omitted by size limits." : ""
        return ToolResult(
            summary: summary,
            evidence: "Read from local checkpointed \(kind.title) snapshot.\(coverage)",
            verified: true
        )
    }

    private func refreshFailed(_ kind: NativePersonalSourceKind, error: any Error) {
        let revoked: Bool
        if let failure = error as? NativeSourceAppleEvents.Failure {
            switch failure {
            case .permissionNeeded, .permissionDenied, .appUnavailable, .noSelection, .malformedSelection, .selectionChanged:
                revoked = true
            default: revoked = false
            }
        } else { revoked = false }
        if revoked {
            snapshots.removeValue(forKey: kind)
            refreshEnabled.remove(kind)
            stale.remove(kind)
            updateRefreshTimer()
            statuses[kind] = "Refresh stopped and the captured selection was cleared. Capture the items again to continue. " + error.localizedDescription
            onContextInvalidated?(kind)
        } else {
            let newlyStale = stale.insert(kind).inserted
            statuses[kind] = "Refresh could not finish. The previous snapshot is unavailable until a refresh succeeds. " + error.localizedDescription
            if newlyStale { onContextInvalidated?(kind) }
        }
    }

    private func updateRefreshTimer() {
        if refreshEnabled.isEmpty {
            refreshTimer?.cancel()
            refreshTimer = nil
        } else if automaticRefresh, refreshTimer == nil {
            refreshTimer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self else { return }
                    await self.refreshEnabledSources()
                }
            }
        }
    }

    isolated deinit {
        refreshTimer?.cancel()
        pendingCapture?.cancel()
    }

    nonisolated static func bounded(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        let scalars = value.unicodeScalars
        var end = scalars.startIndex
        var bytes = 0
        while end < scalars.endIndex {
            let next = bytes + scalars[end].utf8.count
            guard next <= maximumBytes else { break }
            bytes = next
            scalars.formIndex(after: &end)
        }
        return String(scalars[..<end])
    }
}
