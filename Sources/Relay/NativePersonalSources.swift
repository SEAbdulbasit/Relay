import Foundation
import Observation

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
}

nonisolated struct NativePersonalSourceBatch: Sendable {
    let items: [NativePersonalSourceItem]
    let skipped: Int
}

/// Explicit, session-only snapshots. Assistant reads never send Apple events or widen selection.
@Observable @MainActor
final class NativePersonalSources {
    typealias Capture = @MainActor (NativePersonalSourceKind, Bool) async throws -> NativePersonalSourceBatch

    private struct Snapshot {
        let capturedAt: Date
        let items: [NativePersonalSourceItem]
        let skipped: Int
    }

    private var snapshots: [NativePersonalSourceKind: Snapshot] = [:]
    private var statuses: [NativePersonalSourceKind: String] = [:]
    private(set) var capturing: NativePersonalSourceKind?
    var isCapturing: Bool { capturing != nil }

    @ObservationIgnored var onContextInvalidated: ((NativePersonalSourceKind) -> Void)?
    @ObservationIgnored private let capture: Capture
    @ObservationIgnored private var pendingCapture: Task<NativePersonalSourceBatch, Error>?
    @ObservationIgnored private var revision = 0

    init(capture: Capture? = nil) {
        self.capture = capture ?? { try await NativeSourceAppleEvents.captureSelected($0, requestPermission: $1) }
    }

    func status(for kind: NativePersonalSourceKind) -> String {
        statuses[kind] ?? "No selection captured in this session."
    }

    func items(for kind: NativePersonalSourceKind) -> [NativePersonalSourceItem] { snapshots[kind]?.items ?? [] }

    /// Called only by the explicit source control. The OS permission dialog is optional for
    /// callers that are qualifying an already authorized source without triggering a prompt.
    func captureSelection(_ kind: NativePersonalSourceKind, requestPermission: Bool = true) async {
        guard !isCapturing, !Task.isCancelled else { return }
        capturing = kind
        statuses[kind] = "Reading the selected \(kind.itemsName) on this Mac…"
        let expected = revision
        let task = Task { try await capture(kind, requestPermission) }
        pendingCapture = task
        defer { pendingCapture = nil; capturing = nil }

        do {
            let batch = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard revision == expected, !task.isCancelled else { throw CancellationError() }
            guard !batch.items.isEmpty else {
                throw RelayError.message("None of the selected \(kind.itemsName) exposed usable plain text. The previous snapshot was kept.")
            }
            let replacesSnapshot = snapshots[kind] != nil
            snapshots[kind] = Snapshot(capturedAt: Date(), items: batch.items, skipped: batch.skipped)
            statuses[kind] = "Captured \(batch.items.count) for this session."
                + (batch.skipped > 0 ? " Skipped \(batch.skipped) protected or unavailable items." : "")
                + (batch.items.contains(where: \.textLimited) ? " Some text exceeded the capture limit." : "")
            if replacesSnapshot { onContextInvalidated?(kind) }
        } catch is CancellationError {
            if revision == expected { statuses[kind] = "Capture stopped. The previous snapshot was kept." }
        } catch {
            if revision == expected, !task.isCancelled { statuses[kind] = error.localizedDescription }
        }
    }

    func cancelCapture() {
        guard let pendingCapture, let capturing else { return }
        pendingCapture.cancel()
        statuses[capturing] = "Stopping capture…"
    }

    func forget(_ kind: NativePersonalSourceKind) {
        if capturing == kind {
            revision += 1
            cancelCapture()
        }
        let wasCaptured = snapshots.removeValue(forKey: kind) != nil
        statuses[kind] = "Selection forgotten for this session."
        if wasCaptured { onContextInvalidated?(kind) }
    }

    func read(kind: NativePersonalSourceKind, query: String? = nil) throws -> ToolResult {
        guard let snapshot = snapshots[kind] else {
            throw RelayError.message("Capture selected \(kind.itemsName) in Relay Settings before using \(kind.displayName) as a source.")
        }
        let term = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.utf8.count <= 256, !term.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw RelayError.message("Search the captured selection using plain text up to 256 UTF-8 bytes.")
        }
        let matches = snapshot.items.filter { item in
            term.isEmpty || [item.title, item.sender ?? "", item.text].contains { $0.localizedStandardContains(term) }
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
            let heading = "\n\n\(item.title)" + (item.sender.map { "\nSender: \($0)" } ?? "") + "\n"
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
