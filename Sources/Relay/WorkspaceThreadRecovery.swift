import Foundation
import Observation

/// Identity and recovery metadata only. Stored prose is never re-staged as a new invocation.
@Observable @MainActor
final class WorkspaceThreadRecovery {
    nonisolated struct State: Codable {
        var version = 1
        var selectedThreadID: UUID?
        var runOwners: [UUID: UUID] = [:]
        var trash: [SavedConversationThread] = []
        var retiredThreadIDs: Set<UUID> = []
    }
    private(set) var state = State()
    private(set) var failure: String?
    let url: URL?

    init(url: URL?) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoded = try JSONDecoder().decode(State.self, from: LocalStateFile.read(url, maximumBytes: AssistantStore.maximumStateBytes))
            guard decoded.version == 1 else { throw RelayError.message("Conversation recovery metadata uses an unsupported version.") }
            state = decoded
        } catch {
            failure = "Conversation recovery metadata could not be read. Its file is preserved. \(error.localizedDescription)"
        }
    }

    func commit(_ value: State) throws {
        guard failure == nil else { throw RelayError.message(failure!) }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try LocalPrivateFileWriter.write(data: JSONEncoder().encode(value), to: url, maximumBytes: AssistantStore.maximumStateBytes)
        }
        state = value
    }

    /// Only the already-authorized factory reset may replace unreadable metadata.
    func resetForFactoryReset(selectedThreadID: UUID) throws {
        let next = State(selectedThreadID: selectedThreadID)
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try LocalPrivateFileWriter.write(data: JSONEncoder().encode(next), to: url, maximumBytes: AssistantStore.maximumStateBytes)
        }
        state = next
        failure = nil
    }

    func select(_ id: UUID) throws {
        guard state.selectedThreadID != id else { return }
        var next = state; next.selectedThreadID = id
        try commit(next)
    }

    func bind(runID: UUID, to threadID: UUID) throws {
        if let owner = state.runOwners[runID] {
            guard owner == threadID else { throw RelayError.message("Conversation journal ownership changed. Start a new request.") }
            return
        }
        var next = state; next.runOwners[runID] = threadID; next.selectedThreadID = threadID
        try commit(next)
    }
}
