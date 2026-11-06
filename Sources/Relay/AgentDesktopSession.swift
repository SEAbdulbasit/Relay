import Foundation

/// Owns a private snapshot namespace and orders cursor setup/teardown across Stop and steering.
/// No traces or screenshots are enabled, and actions remain semantic/headless.
@MainActor
final class AgentDesktopSession {
    private(set) var id = "relay-" + UUID().uuidString.lowercased()
    private(set) var isRendered = false
    private(set) var lastCursorResult: AgentDesktopEnvelope?
    private var generation = 0
    private var configured = false
    private var started = false
    private var startup: Task<String, Error>?
    private var tail: Task<Bool, Never>?
    private let command: ([String], String) async throws -> AgentDesktopEnvelope

    init(command: @escaping ([String], String) async throws -> AgentDesktopEnvelope = { args, session in
        try await AgentDesktopBridge.runCommand(arguments: args, timeoutSeconds: 3, sessionID: session.isEmpty ? nil : session)
    }) {
        self.command = command
    }

    func prepare() async throws -> String {
        if started { return id }
        if startup == nil {
            let command = command
            startup = Task {
                let result = try await command(["session", "start", "--name", "Relay desktop control", "--no-trace"], "")
                guard result.ok,
                      let object = try? JSONSerialization.jsonObject(with: Data(result.rawJSON.utf8)) as? [String: Any],
                      let data = object["data"] as? [String: Any],
                      let id = data["session_id"] as? String, !id.isEmpty else {
                    throw RelayError.message("Could not create the desktop control session: \(result.formattedSummary)")
                }
                return id
            }
        }
        do {
            let prepared = try await startup!.value
            id = prepared
            started = true
            startup = nil
            return prepared
        } catch {
            startup = nil
            throw error
        }
    }

    func show(label: String) async -> Bool {
        generation += 1
        let expected = generation
        configured = true
        let previous = tail
        let command = command
        let operation = Task { [weak self] in
            _ = await previous?.value
            // A Stop queued before this setup starts prevents even its presentation.
            guard self?.generation == expected,
                  let id = try? await self?.prepare(), self?.generation == expected else { return false }
            let envelope = try? await command(["cursor-overlay", "enable", "--label", "Relay " + label,
                "--fill", "#AB65F5", "--rim", "#FFFFFF", "--accent", "#AB65F5", "--tremor", "0"], id)
            let rendered = envelope.map(Self.rendered) ?? false
            if self?.generation == expected {
                self?.isRendered = rendered
                self?.lastCursorResult = envelope
            }
            return rendered
        }
        tail = operation
        let rendered = await operation.value
        return generation == expected && !Task.isCancelled && rendered
    }

    @discardableResult
    func stop() -> Task<Bool, Never>? {
        generation += 1
        isRendered = false
        guard configured else { return tail }
        configured = false
        let previous = tail
        let command = command
        let operation = Task { [weak self] in
            _ = await previous?.value
            guard let self, self.started else { return true }
            return (try? await command(["cursor-overlay", "disable"], self.id))?.ok == true
        }
        tail = operation
        return operation
    }

    static func rendered(_ envelope: AgentDesktopEnvelope) -> Bool {
        guard envelope.ok, envelope.command == "cursor-overlay",
              let object = try? JSONSerialization.jsonObject(with: Data(envelope.rawJSON.utf8)) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return false }
        return data["rendered"] as? Bool == true
    }
}
