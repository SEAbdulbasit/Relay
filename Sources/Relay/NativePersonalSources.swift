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

nonisolated struct NativePersonalSourceItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let sender: String?
    let text: String
    let textLimited: Bool
    let sentAt: Date?
    let receivedAt: Date?

    init(id: String, title: String, sender: String?, text: String, textLimited: Bool,
         sentAt: Date? = nil, receivedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.sender = sender
        self.text = text
        self.textLimited = textLimited
        self.sentAt = sentAt
        self.receivedAt = receivedAt
    }

    fileprivate var labels: [String] {
        [sender.map { "Sender: \($0)" }, sentAt.map { "Sent: \($0.ISO8601Format())" },
         receivedAt.map { "Received: \($0.ISO8601Format())" }].compactMap { $0 }
    }

    fileprivate var searchableFields: [String] {
        [title, text] + [sender, sentAt?.ISO8601Format(), receivedAt?.ISO8601Format()].compactMap { $0 }
    }
}

nonisolated struct NativePersonalSourceBatch: Sendable {
    let items: [NativePersonalSourceItem]
    let skipped: Int
    var scope: NativePersonalSourceScope? = nil
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

    private struct Snapshot {
        let capturedAt: Date
        let items: [NativePersonalSourceItem]
        let skipped: Int
        let scope: NativePersonalSourceScope?
    }

    private var snapshots: [NativePersonalSourceKind: Snapshot] = [:]
    private var statuses: [NativePersonalSourceKind: String] = [:]
    private var refreshEnabled: Set<NativePersonalSourceKind> = []
    private var stale: Set<NativePersonalSourceKind> = []
    private(set) var capturing: NativePersonalSourceKind?
    private(set) var refreshing: NativePersonalSourceKind?
    var isCapturing: Bool { capturing != nil }

    @ObservationIgnored var onContextInvalidated: ((NativePersonalSourceKind) -> Void)?
    @ObservationIgnored var isBusy: () -> Bool = { false }
    @ObservationIgnored private let capture: Capture
    @ObservationIgnored private let refresh: Refresh
    @ObservationIgnored private let automaticRefresh: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pendingCapture: Task<NativePersonalSourceBatch, Error>?
    @ObservationIgnored private var refreshTimer: Task<Void, Never>?
    @ObservationIgnored private var revision = 0

    convenience init(capture: Capture? = nil) {
        self.init(capture: capture, refresh: nil)
    }

    init(capture: Capture? = nil, refresh: Refresh?, automaticRefresh: Bool = true, now: @escaping () -> Date = Date.init) {
        self.capture = capture ?? { try await NativeSourceAppleEvents.captureSelected($0, requestPermission: $1) }
        self.refresh = refresh ?? { try await NativeSourceAppleEvents.refreshCaptured($0) }
        self.automaticRefresh = automaticRefresh
        self.now = now
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

    private func run(_ kind: NativePersonalSourceKind, scope: NativePersonalSourceScope?, requestPermission: Bool) async {
        capturing = kind
        refreshing = scope == nil ? nil : kind
        statuses[kind] = scope == nil ? "Reading the selected \(kind.itemsName) on this Mac…" : "Refreshing the captured \(kind.itemsName)…"
        let expected = revision
        let task = Task {
            if let scope { return try await refresh(scope) }
            return try await capture(kind, requestPermission)
        }
        pendingCapture = task
        defer { pendingCapture = nil; capturing = nil; refreshing = nil }

        do {
            let batch = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard revision == expected, !task.isCancelled else { throw CancellationError() }
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
            snapshots[kind] = Snapshot(capturedAt: now(), items: batch.items, skipped: batch.skipped, scope: batch.scope)
            statuses[kind] = (scope == nil ? "Captured " : "Refreshed ") + "\(batch.items.count) for this session."
                + (batch.skipped > 0 ? " Skipped \(batch.skipped) protected or unavailable items." : "")
                + (batch.items.contains(where: \.textLimited) ? " Some text exceeded the capture limit." : "")
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

    func forget(_ kind: NativePersonalSourceKind) {
        if capturing == kind {
            revision += 1
            cancelCapture()
        }
        let wasCaptured = snapshots.removeValue(forKey: kind) != nil
        refreshEnabled.remove(kind)
        stale.remove(kind)
        updateRefreshTimer()
        statuses[kind] = "Selection forgotten for this session."
        if wasCaptured { onContextInvalidated?(kind) }
    }

    func read(kind: NativePersonalSourceKind, query: String? = nil) throws -> ToolResult {
        guard let snapshot = snapshots[kind] else {
            throw RelayError.message("Capture selected \(kind.itemsName) in Relay Settings before using \(kind.displayName) as a source.")
        }
        guard !stale.contains(kind) else {
            throw RelayError.message("The captured \(kind.itemsName) could not be verified on the last refresh. Refresh them or capture again before using this source.")
        }
        let term = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.utf8.count <= 256, !term.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw RelayError.message("Search the captured selection using plain text up to 256 UTF-8 bytes.")
        }
        let matches = snapshot.items.filter { item in
            term.isEmpty || item.searchableFields.contains { $0.localizedStandardContains(term) }
        }
        let header = "\(kind.displayName) selection captured at \(snapshot.capturedAt.ISO8601Format()) (untrusted source text)."
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
