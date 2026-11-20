import Foundation
import Observation

@MainActor @Observable
final class HostedKnowledgeMirror {
    static let shared = HostedKnowledgeMirror(root: KnowledgeVaultManager.shared.vaultDirectory,
                                              defaults: .standard, startAutomatically: true)

    private struct State: Codable {
        let origin: URL
        var enabled = true
        var acceptedFingerprint: String?
        var acceptedAt: Date?
    }

    private static let stateKey = "hosted-knowledge-mirror.v1"
    private static let renewAfter: TimeInterval = 7 * 24 * 60 * 60

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: CustomResponsesCredentials.Store
    @ObservationIgnored private let send: (URLRequest) async throws -> Void
    @ObservationIgnored private let readAccess: (URL) async throws -> HostedKnowledgeMirrorAccess
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var observedFingerprint: String?
    private var state: State?
    private(set) var isBusy = false
    private(set) var status: String?
    private(set) var access: HostedKnowledgeMirrorAccess?
    private(set) var accessUnavailable = false
    private(set) var isRefreshingAccess = false

    var isEnabled: Bool { state?.enabled == true }
    var deletionPending: Bool { state?.enabled == false }
    var lastSync: Date? { state?.acceptedAt }
    var host: String? { state?.origin.absoluteString }

    init(root: URL, defaults: UserDefaults,
         keychain: CustomResponsesCredentials.Store = .keychain(service: "app.relay.hosted-knowledge-mirror.v1"),
         send: ((URLRequest) async throws -> Void)? = nil,
         readAccess: ((URL) async throws -> HostedKnowledgeMirrorAccess)? = nil,
         startAutomatically: Bool = false) {
        self.root = root
        self.defaults = defaults
        self.keychain = keychain
        if let send {
            self.send = send
            self.readAccess = readAccess ?? { _ in throw HostedKnowledgeMirrorTransport.Failure.requestFailed }
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: HostedMirrorNoRedirect(), delegateQueue: nil)
            self.send = { try await HostedKnowledgeMirrorTransport.send($0, session: session) }
            self.readAccess = readAccess ?? { try await HostedKnowledgeMirrorTransport.readAccess(at: $0, session: session) }
        }
        if let bytes = defaults.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode(State.self, from: bytes),
           let origin = try? HostedKnowledgeMirrorTransport.origin(saved.origin.absoluteString), origin == saved.origin {
            state = saved
        }
        if startAutomatically, state?.enabled == true { start() }
    }

    private func start() {
        guard state?.enabled == true else { return }
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            guard self?.state?.enabled == true else { return }
            await self?.synchronize(immediate: true)
            while !Task.isCancelled, let self, self.state?.enabled == true {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                guard self.state?.enabled == true else { return }
                await self.synchronize()
            }
        }
    }

    func enable(origin input: String) async {
        guard state == nil, !isBusy else { return }
        do {
            let origin = try HostedKnowledgeMirrorTransport.origin(input)
            let secret = HostedKnowledgeMirrorTransport.password()
            try keychain.write(origin.absoluteString, Data(secret.utf8))
            _ = try password(for: origin)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            save(.init(origin: origin))
            await synchronize(immediate: true)
            if scheduler == nil {
                start()
            }
        } catch let error as HostedKnowledgeMirrorTransport.Failure {
            status = error.localizedDescription
        } catch {
            status = "Relay could not prepare the local vault or save its mirror identity."
        }
    }

    func disable() async {
        guard var current = state, current.enabled else { return }
        scheduler?.cancel()
        scheduler = nil
        current.enabled = false
        current.acceptedAt = nil
        current.acceptedFingerprint = nil
        save(current)
        access = nil
        accessUnavailable = false
        status = "Sharing is off locally. Removing the hosted copy…"
        await synchronize(immediate: true)
    }

    func connectorURL() -> URL? {
        guard let state, state.enabled, state.acceptedAt != nil else { return nil }
        do {
            return HostedKnowledgeMirrorTransport.url(origin: state.origin, password: try password(for: state.origin), resource: "mcp")
        } catch {
            status = HostedKnowledgeMirrorTransport.Failure.invalidCredential.localizedDescription
            return nil
        }
    }

    func refreshAccess() async {
        guard let state, state.enabled, state.acceptedAt != nil, !isRefreshingAccess else { return }
        let origin = state.origin
        guard let credential = try? password(for: origin) else {
            access = nil
            accessUnavailable = true
            return
        }
        isRefreshingAccess = true
        defer { isRefreshingAccess = false }
        let url = HostedKnowledgeMirrorTransport.url(origin: origin, password: credential, resource: "stats")
        let result = try? await readAccess(url)
        guard isEnabled, self.state?.origin == origin, (try? password(for: origin)) == credential else { return }
        access = result
        accessUnavailable = result == nil
    }

    func synchronize(immediate: Bool = false) async {
        guard var current = state, !isBusy else { return }
        isBusy = true
        defer {
            isBusy = false
            if current.enabled, deletionPending {
                Task { await synchronize(immediate: true) }
            }
        }

        do {
            let password = try password(for: current.origin)
            let url = HostedKnowledgeMirrorTransport.url(origin: current.origin, password: password, resource: "vault")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            if !current.enabled {
                request.httpMethod = "DELETE"
                try await send(request)
                try? keychain.delete(current.origin.absoluteString)
                save(nil)
                status = "Hosted copy removed."
                return
            }

            let snapshot = try await HostedKnowledgeMirrorTransport.snapshot(root: root)
            guard isEnabled else { return }
            let requiresRenewal = current.acceptedAt.map { Date().timeIntervalSince($0) >= Self.renewAfter } ?? true
            guard snapshot.fingerprint != current.acceptedFingerprint || requiresRenewal else {
                observedFingerprint = nil
                status = nil
                return
            }

            // Persist only the accepted revision. Any edit that survives a quit, failure or in-flight upload
            // differs from that revision and is automatically retried on a later scan or at launch.
            if !immediate, snapshot.fingerprint != observedFingerprint {
                observedFingerprint = snapshot.fingerprint
                return
            }

            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = try await HostedKnowledgeMirrorTransport.encryptedArchive(notes: snapshot.notes, password: password)
            guard isEnabled else { return }
            try await send(request)
            guard isEnabled else { return }
            current.acceptedFingerprint = snapshot.fingerprint
            current.acceptedAt = Date()
            save(current)
            observedFingerprint = nil
            status = nil
        } catch {
            guard current.enabled == isEnabled else { return }
            status = current.enabled
                ? "Sync is pending. Check the vault, Keychain and mirror service. Relay will retry."
                : "Sharing is off locally. Relay will retry removing the hosted copy."
        }
    }

    private func password(for origin: URL) throws -> String {
        guard let bytes = try keychain.read(origin.absoluteString), bytes.count == 24,
              bytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let password = String(data: bytes, encoding: .utf8) else {
            throw HostedKnowledgeMirrorTransport.Failure.invalidCredential
        }
        return password
    }

    private func save(_ value: State?) {
        if let value, let bytes = try? JSONEncoder().encode(value) {
            defaults.set(bytes, forKey: Self.stateKey)
        } else {
            defaults.removeObject(forKey: Self.stateKey)
        }
        state = value
    }
}
