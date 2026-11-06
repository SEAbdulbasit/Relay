import AppKit
import Foundation
import Network
import Observation
import Security

/// A short-lived server for explicitly approved Markdown note revisions on this Mac.
@Observable @MainActor
final class LocalKnowledgeMCPServer {
    static let maximumNotes = 8
    private static let maximumConnections = 8
    private(set) var endpoint: URL?
    private(set) var token: String?
    private(set) var expiresAt: Date?
    private(set) var status = "Local sharing is off."
    var isActive: Bool { expiresAt != nil }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var notes: [LocalMCPNote] = []
    @ObservationIgnored private var peers: [UUID: Peer] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var expiration: Task<Void, Never>?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?

    private struct Peer {
        let connection: NWConnection
        var buffer = Data()
        let deadline: Task<Void, Never>
    }

    func start(notes: [LocalMarkdownNote]) throws {
        let approved = notes.map { note in
            LocalMCPNote(url: note.url.standardizedFileURL, title: String(decoding: note.title.utf8.prefix(200), as: UTF8.self),
                         markdown: note.sharingMarkdown)
        }
        try start(approvedNotes: approved)
    }

    func start(approvedNotes: [LocalMCPNote]) throws {
        guard listener == nil else { throw RelayError.message("Stop the current share before starting another.") }
        guard !approvedNotes.isEmpty, approvedNotes.count <= Self.maximumNotes,
              Set(approvedNotes.map(\.url)).count == approvedNotes.count else {
            throw RelayError.message("Choose up to \(Self.maximumNotes) distinct Vault notes.")
        }
        guard approvedNotes.allSatisfy(\.isCurrent) else {
            throw RelayError.message("A selected note changed or became unavailable. Refresh and select its current version.")
        }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw RelayError.message("Relay couldn’t create a local access token.")
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)

        self.listener = listener
        notes = approvedNotes
        token = random.map { String(format: "%02x", $0) }.joined()
        expiresAt = Date().addingTimeInterval(15 * 60)
        status = "Starting local sharing…"
        let run = UUID()
        generation = run
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state, generation: run) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, self.generation == run else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == run else { return }
                self.stop(reason: "Local sharing ended when the Mac went to sleep.")
            }
        }
        expiration = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            guard let self, self.generation == run, !Task.isCancelled else { return }
            self.stop(reason: "Local sharing expired. Start a new share to create another token.")
        }
        listener.start(queue: .main)
    }

    func stop() { stop(reason: "Local sharing is off.") }

    private func stop(reason: String) {
        generation = UUID()
        listener?.cancel()
        listener = nil
        for peer in peers.values {
            peer.deadline.cancel()
            peer.connection.cancel()
        }
        peers.removeAll()
        expiration?.cancel()
        expiration = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        notes.removeAll()
        endpoint = nil
        token = nil
        expiresAt = nil
        status = reason
    }

    private func listenerChanged(_ state: NWListener.State, generation run: UUID) {
        guard generation == run else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue, port > 0 else {
                stop(reason: "Relay couldn’t verify the local sharing port.")
                return
            }
            endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")
            status = notes.count == 1 ? "Sharing one selected note on this Mac." : "Sharing \(notes.count) selected notes on this Mac."
        case .failed, .waiting:
            stop(reason: "Relay couldn’t open a loopback-only sharing connection.")
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard peers.count < Self.maximumConnections else { connection.cancel(); return }
        let id = UUID()
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.close(id)
        }
        peers[id] = Peer(connection: connection, deadline: deadline)
        connection.start(queue: .main)
        receive(id)
    }

    private func receive(_ id: UUID) {
        peers[id]?.connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] bytes, _, complete, error in
            MainActor.assumeIsolated { self?.received(id, bytes: bytes, complete: complete, failed: error != nil) }
        }
    }

    private func received(_ id: UUID, bytes: Data?, complete: Bool, failed: Bool) {
        guard var peer = peers[id] else { return }
        guard !failed else { close(id); return }
        if let bytes { peer.buffer.append(bytes) }
        peers[id] = peer
        switch LocalMCPHTTP.parse(peer.buffer) {
        case .incomplete:
            if complete { send(LocalMCPHTTP.Response(400), to: id) }
            else { receive(id) }
        case .rejected(let response):
            send(response, to: id)
        case .complete(let request):
            guard let port = listener?.port?.rawValue, let token else { close(id); return }
            let response = LocalKnowledgeMCPProtocol.respond(request, port: port, token: token) {
                let priorCount = notes.count
                notes.removeAll { !$0.isCurrent }
                if notes.count != priorCount {
                    status = "A selected note changed or became unavailable. Start a new share to approve the current version."
                }
                return notes
            }
            send(response, to: id)
        }
    }

    private func send(_ response: LocalMCPHTTP.Response, to id: UUID) {
        peers[id]?.connection.send(content: response.bytes, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.deadline.cancel()
        peer.connection.cancel()
    }

    isolated deinit { stop() }
}
