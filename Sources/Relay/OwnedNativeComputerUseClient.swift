import CryptoKit
import Darwin
import Foundation
import Security

/// A model-free owned native connection. Typed mutations require trusted final preflight;
/// the production control-session policy denies unqualified effects by default.
/// Native receipts remain opaque and do not authorize Relay actions or prove a window's identity.
actor OwnedNativeComputerUseClient {
    nonisolated enum Failure: Error, Equatable {
        case unavailableRuntime, invalidWorkspace, closed, busy, malformedResponse
        case unsupportedCatalog, duplicateRequest, timeout, outputLimit, unexpectedServerRequest
        case transportWrite
        case unsupportedKeyboardText
        case requestTimedOut(Method)
        case processExited(Int32), rpc(code: Int?, message: String)
    }

    nonisolated enum Method: String, Sendable {
        case initialize, threadStart = "thread/start", catalog = "mcpServerStatus/list"
        case state = "mcpServer/tool/call"
    }

    nonisolated struct Transport: Sendable {
        var request: @Sendable (Method, [String: JSONValue], Duration) async throws -> JSONValue
        var initialized: @Sendable () async throws -> Void
        var close: @Sendable () async -> Void
        var input: (@Sendable (Method, [String: JSONValue], Duration, InputAdmission) async throws -> JSONValue)? = nil
    }

    nonisolated struct Descriptor: Sendable, Equatable {
        let name: String
        /// Exact native schema, annotations and metadata, without Relay reinterpretation.
        let raw: JSONValue
        var inputSchema: JSONValue? { raw.object?["inputSchema"] }
    }

    nonisolated struct Catalog: Sendable, Equatable {
        let tools: [Descriptor]
        let server: JSONValue
    }

    nonisolated struct NativeResult: Sendable, Equatable {
        let raw: JSONValue
        let content: [JSONValue]
        let isError: Bool
    }

    /// Finite native primitives, never raw tools/arguments or AX-to-native index translation.
    /// Key spellings and screenshot-pixel geometry require owned-fixture qualification.
    nonisolated enum Command: Sendable, Equatable {
        case click(NativeVisionFrame.PixelPoint)
        case drag(from: NativeVisionFrame.PixelPoint, to: NativeVisionFrame.PixelPoint)
        case key(NativeControlKey)
        case typeUnsentText(String)

        /// The qualified provider emits physical key events and drops non-layout Unicode.
        /// Refuse it before dispatch; literal Unicode must choose a bound AX edit up front.
        static func supportsLiteralKeyboardText(_ text: String) -> Bool {
            NativeControlSession.validUnsentText(text) && text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
        }

        var tool: String {
            switch self { case .click: "click"; case .drag: "drag"; case .key: "press_key"; case .typeUnsentText: "type_text" }
        }

        func arguments(app: String) throws -> [String: JSONValue] {
            var values: [String: JSONValue] = ["app": .string(app)]
            func point(_ point: NativeVisionFrame.PixelPoint) throws {
                guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
                      point.x < 8_192, point.y < 8_192 else { throw Failure.malformedResponse }
            }
            switch self {
            case .click(let target):
                try point(target)
                values.merge(["x": .number(target.x), "y": .number(target.y), "click_count": .number(1), "mouse_button": .string("left")]) { _, rhs in rhs }
            case .drag(let from, let to):
                try point(from); try point(to)
                values.merge(["from_x": .number(from.x), "from_y": .number(from.y), "to_x": .number(to.x), "to_y": .number(to.y)]) { _, rhs in rhs }
            case .key(let key): values["key"] = .string(key.rawValue)
            case .typeUnsentText(let text):
                guard NativeControlSession.validUnsentText(text) else { throw Failure.malformedResponse }
                guard Self.supportsLiteralKeyboardText(text) else { throw Failure.unsupportedKeyboardText }
                values["text"] = .string(text)
            }
            return values
        }
    }

    /// Only official embedded dependencies are discovered. Nothing is imported from another
    /// app's private runtime/profile, and no credential/configuration files are read.
    nonisolated struct Runtime: Sendable {
        let cli: URL
        let helper: URL
        private let cliIdentity: Data
        private let helperIdentity: Data

        private init(cli: URL, helper: URL, cliIdentity: Data, helperIdentity: Data) {
            self.cli = cli; self.helper = helper
            self.cliIdentity = cliIdentity; self.helperIdentity = helperIdentity
        }

        static func discover() throws -> Self {
            let parents = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
            for parent in parents {
                for name in ["ChatGPT.app", "Codex.app"] {
                    let app = parent.appendingPathComponent(name, isDirectory: true)
                    let cli = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                    let helper = app.appendingPathComponent("Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")
                    if let cliIdentity = identity(cli, identifier: "codex"),
                       let helperIdentity = identity(helper, identifier: "com.openai.sky.CUAService.cli") {
                        return Self(cli: cli.resolvingSymlinksInPath(), helper: helper.resolvingSymlinksInPath(),
                                    cliIdentity: cliIdentity, helperIdentity: helperIdentity)
                    }
                }
            }
            throw Failure.unavailableRuntime
        }

        fileprivate func validate() throws {
            guard Self.identity(cli, identifier: "codex") == cliIdentity,
                  Self.identity(helper, identifier: "com.openai.sky.CUAService.cli") == helperIdentity else {
                throw Failure.unavailableRuntime
            }
        }

        private static func identity(_ url: URL, identifier: String) -> Data? {
            guard FileManager.default.isExecutableFile(atPath: url.path),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            var code: SecStaticCode?
            var requirement: SecRequirement?
            var signing: CFDictionary?
            let rule = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and identifier \"\(identifier)\""
            guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
                  SecRequirementCreateWithString(rule as CFString, SecCSFlags(), &requirement) == errSecSuccess,
                  let code, let requirement,
                  SecStaticCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess,
                  SecCodeCopySigningInformation(code, SecCSFlags(), &signing) == errSecSuccess,
                  let values = signing as? [String: Any] else { return nil }
            return values[kSecCodeInfoUnique as String] as? Data
        }
    }

    private enum Status { case new, opening, ready, closed }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let timer: Task<Void, Never>
    }
    private struct Receipt { let result: NativeResult; let bytes: Int }
    private let transport: Transport
    private let serverName = "relay_native"
    private var status = Status.new
    private var threadID: String?
    private var discovered: Catalog?
    private var busy = false
    private var waiters: [Waiter] = []
    private var consumed: [Data: Data] = [:]
    private var receipts: [Data: Receipt] = [:]
    private var receiptOrder: [Data] = []
    private var receiptBytes = 0
    private var closeTask: Task<Void, Never>?
    private let clock = ContinuousClock()

    init(transport: Transport) { self.transport = transport }

    deinit {
        guard status != .closed else { return }
        let cleanup = transport.close
        Task { await cleanup() }
    }

    static func open(runtime: Runtime) async throws -> OwnedNativeComputerUseClient {
        let process = try OwnedNativeObservationProcess(runtime: runtime)
        do {
            try await process.launch()
            let client = OwnedNativeComputerUseClient(transport: process.transport)
            _ = try await client.start(workspace: process.workspace)
            return client
        } catch { await process.close(); throw error }
    }

    /// Handshake and discovery only. This never sends turn/start or calls a native tool.
    @discardableResult
    func start(workspace: URL) async throws -> Catalog {
        if status == .ready, let discovered { return discovered }
        guard status != .closed else { throw Failure.closed }
        guard status == .new else { throw Failure.busy }
        guard workspace.isFileURL, workspace.path.hasPrefix("/"),
              workspace.standardizedFileURL == workspace else { throw Failure.invalidWorkspace }
        status = .opening
        do {
            _ = try await transport.request(.initialize, [
                "clientInfo": .object(["name": .string("relay_native_observation"), "version": .string("1")]),
                "capabilities": .object(["experimentalApi": .bool(true)])], .seconds(15))
            try ensureOpening()
            try await transport.initialized()
            try ensureOpening()
            let result = try await transport.request(.threadStart, ["cwd": .string(workspace.path),
                "ephemeral": .bool(true), "sandbox": .string("danger-full-access"), "approvalPolicy": .string("never")], .seconds(15))
            try ensureOpening()
            guard let id = result.object?["thread"]?.object?["id"]?.string, !id.isEmpty, id.utf8.count <= 1_024 else {
                throw Failure.malformedResponse
            }
            threadID = id
            let response = try await transport.request(.catalog, ["threadId": .string(id),
                "serverName": .string(serverName), "detail": .string("toolsAndAuthOnly"), "limit": .number(1)], .seconds(20))
            try ensureOpening()
            let catalog = try Self.decodeCatalog(response, serverName: serverName)
            discovered = catalog
            status = .ready
            return catalog
        } catch { await close(); throw error }
    }

    func catalog() throws -> Catalog {
        guard status == .ready, let discovered else { throw Failure.closed }
        return discovered
    }

    /// State-only primitive. The caller must admit an exact target before capture and validate
    /// returned provenance. Discovery is not permission proof; this result grants no action.
    func state(requestID: String, app: String, timeout: Duration = .seconds(90)) async throws -> NativeResult {
        try await call(requestID: requestID, app: app, tool: "get_app_state", arguments: ["app": .string(app)], timeout: timeout, preflight: nil)
    }

    /// A single-use read capability valid only while this mutation owns the native FIFO.
    /// It cannot capture another app and expires before dispatch/queue release.
    nonisolated struct ReservedState: Sendable {
        /// The actual already-owned reservation deadline; never a fresh focus budget.
        let notAfter: ContinuousClock.Instant
        let capture: @Sendable (String, String) async throws -> NativeResult
        func state(requestID: String, app: String) async throws -> NativeResult { try await capture(requestID, app) }
    }
    nonisolated struct InputAdmission: Sendable {
        let notAfter: ContinuousClock.Instant
        private let ticket: NativeInputRevocation.Ticket
        private let source: NativeInputRevocation
        init(notAfter: ContinuousClock.Instant, revocation: NativeInputRevocation) {
            self.notAfter = notAfter; ticket = revocation.ticket(); source = revocation
        }
        private init(notAfter: ContinuousClock.Instant, ticket: NativeInputRevocation.Ticket, source: NativeInputRevocation) {
            self.notAfter = notAfter; self.ticket = ticket; self.source = source
        }
        fileprivate func bound(to revocation: NativeInputRevocation, notAfter deadline: ContinuousClock.Instant) throws -> Self {
            guard source === revocation else { throw Failure.closed }
            return Self(notAfter: min(notAfter, deadline), ticket: ticket, source: source)
        }
        /// Logical dispatch admission, not an atomic claim about delivered bytes/UI effects.
        func begin(at now: ContinuousClock.Instant = .now) throws {
            // Task cancellation can arrive before the MainActor Stop handler runs.
            // Reject in this same propagated task before logical input admission.
            if Task.isCancelled { throw MutationFailure.notDispatched(CancellationError()) }
            switch ticket.admit(now: now, notAfter: notAfter) {
            case .admitted: return
            case .revoked: throw MutationFailure.notDispatched(Failure.closed)
            case .expired: throw MutationFailure.notDispatched(Failure.timeout)
            case .consumed: throw MutationFailure.notDispatched(Failure.duplicateRequest)
            }
        }
    }
    nonisolated enum MutationFailure: Error {
        case notDispatched(any Error)
        case uncertain(any Error)
    }

    /// Final preparation runs inside the same queue reservation as helper dispatch. The
    /// reservation permits a fresh pinned state read without recursively acquiring the FIFO.
    func mutate(requestID: String, app: String, command: Command, revocation: NativeInputRevocation,
                timeout: Duration = .seconds(90), preflight: @escaping @MainActor @Sendable (ReservedState) async throws -> InputAdmission) async throws -> NativeResult {
        do {
            return try await call(requestID: requestID, app: app, tool: command.tool,
                arguments: command.arguments(app: app), timeout: timeout, revocation: revocation, preflight: preflight)
        } catch let error as MutationFailure { throw error }
        catch { throw MutationFailure.notDispatched(error) }
    }

    /// Qualified local AX execution under this same owned FIFO. Only preparation can
    /// throw; execution returns an explicit attempted/not-dispatched outcome and readback
    /// cannot throw it away. There is no native input RPC or provider-typing fallback.
    nonisolated struct AXInsertionOperation: Sendable {
        let execute: @MainActor @Sendable () -> NativeFocusedAXInsertion.Outcome
        let readback: @MainActor @Sendable (ReservedState, NativeFocusedAXInsertion.Outcome) async -> Void
    }

    func reserveAXInsertion(requestID: String, app: String, fingerprint: Data, revocation: NativeInputRevocation,
                            timeout: Duration = .seconds(90),
                            prepare: @escaping @MainActor @Sendable (ReservedState) async throws -> AXInsertionOperation) async throws -> NativeFocusedAXInsertion.Outcome {
        do {
            guard !requestID.isEmpty, requestID.utf8.count <= 1_024, fingerprint.count == 32,
                  !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, app.utf8.count <= 4_096,
                  timeout > .zero, timeout <= .seconds(90) else { throw Failure.malformedResponse }
            let deadline = clock.now.advanced(by: timeout)
            try await acquire(until: deadline)
            defer { reservationRevocation = nil; reservation = nil; release() }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard status == .ready, revocation.isActive else { throw Failure.closed }
                let key = Self.requestKey(requestID)
                guard consumed[key] == nil else { throw Failure.duplicateRequest }
                // The original ID is never eligible for another operation, even after a
                // preflight refusal or an evicted receipt. No random retry ID is minted.
                consumed[key] = try Self.requestFingerprint(tool: "relay_focused_ax_insertion", arguments: [
                    "app": .string(app), "effect": .string(fingerprint.base64EncodedString())])
                let id = UUID()
                reservation = Reservation(id: id, app: app, deadline: deadline, maximumReads: 2)
                reservationRevocation = revocation
                let read = ReservedState(notAfter: deadline, capture: { [self] requestID, target in
                    try await stateInReservation(id, requestID: requestID, app: target)
                })
                let operation = try await prepare(read)
                try Task.checkCancellation()
                guard clock.now < deadline else { throw Failure.timeout }
                guard status == .ready, revocation.isActive,
                      reservation?.id == id, reservation?.reads == 1, reservation?.inFlight == false else { throw Failure.closed }
                // The same gate is checked by the actual AX capability after this actor hop.
                // A close/Stop that wins final admission prevents the write; after admission
                // the typed outcome stays attempted/uncertain and is never replaced by a throw.
                let outcome = await operation.execute()
                await operation.readback(read, outcome)
                if !revocation.isActive || status != .ready || Task.isCancelled {
                    switch outcome {
                    case .inserted, .uncertain: return .uncertain(.stoppedAfterDispatch)
                    case .unchanged, .notDispatched: return outcome
                    }
                }
                return outcome
            } onCancel: { Task { await self.close() } }
        } catch MutationFailure.notDispatched(let error) { throw MutationFailure.notDispatched(error) }
        catch MutationFailure.uncertain(let error) { throw MutationFailure.notDispatched(error) }
        catch { throw MutationFailure.notDispatched(error) }
    }

    private struct Reservation {
        let id: UUID
        let app: String
        let deadline: ContinuousClock.Instant
        var maximumReads = 1
        var reads = 0
        var inFlight = false
    }
    private var reservation: Reservation?
    private var reservationRevocation: NativeInputRevocation?

    private func call(requestID: String, app: String, tool: String, arguments: [String: JSONValue], timeout: Duration,
                      revocation: NativeInputRevocation? = nil, preflight: (@MainActor @Sendable (ReservedState) async throws -> InputAdmission)?) async throws -> NativeResult {
        guard !requestID.isEmpty, requestID.utf8.count <= 1_024,
              !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, app.utf8.count <= 4_096,
              timeout > .zero, timeout <= .seconds(90) else { throw Failure.malformedResponse }
        let deadline = clock.now.advanced(by: timeout)
        try await acquire(until: deadline)
        defer { reservationRevocation = nil; reservation = nil; release() }
        try Task.checkCancellation()
        guard status == .ready, revocation?.isActive != false else { throw Failure.closed }
        guard let descriptor = discovered?.tools.first(where: { $0.name == tool }) else { throw Failure.unsupportedCatalog }
        if preflight != nil, !Self.acceptsMutationSchema(descriptor.inputSchema, tool: tool, arguments: arguments) {
            throw Failure.unsupportedCatalog
        }
        let key = Self.requestKey(requestID), fingerprint = try Self.requestFingerprint(tool: tool, arguments: arguments)
        if let old = consumed[key], old != fingerprint || receipts[key] == nil { throw Failure.duplicateRequest }
        var admission: InputAdmission?
        if let preflight {
            guard let revocation else { throw Failure.unavailableRuntime }
            reservationRevocation = revocation
            let id = UUID()
            reservation = Reservation(id: id, app: app, deadline: deadline)
            let read = ReservedState(notAfter: deadline, capture: { [self] requestID, target in
                try await stateInReservation(id, requestID: requestID, app: target)
            })
            // No queued native request can run between this read/validation and dispatch.
            admission = try await preflight(read).bound(to: revocation, notAfter: deadline)
            // close() revokes this same gate and clears its reservation while
            // the MainActor preflight awaits. Preserve that definitive close
            // before diagnosing an otherwise malformed live reservation.
            try Task.checkCancellation()
            guard status == .ready, revocation.isActive else { throw Failure.closed }
            guard reservation?.id == id, reservation?.inFlight == false else {
                await close(); throw Failure.busy
            }
            reservation = nil
        }
        try Task.checkCancellation()
        guard status == .ready, revocation?.isActive != false else { throw Failure.closed }
        if let receipt = receipts[key] { return receipt.result }
        return try await perform(requestID: requestID, tool: tool, arguments: arguments, deadline: deadline,
                                 admission: admission)
    }

    private func stateInReservation(_ id: UUID, requestID: String, app: String) async throws -> NativeResult {
        try Task.checkCancellation()
        guard status == .ready, var reserved = reservation, reserved.id == id,
              !reserved.inFlight, reserved.reads < reserved.maximumReads, !requestID.isEmpty, requestID.utf8.count <= 1_024,
              reserved.app.utf16.elementsEqual(app.utf16) else { throw Failure.closed }
        reserved.reads += 1; reserved.inFlight = true; reservation = reserved
        defer { if reservation?.id == id { reservation?.inFlight = false } }
        return try await perform(requestID: requestID, tool: "get_app_state", arguments: ["app": .string(app)],
                                 deadline: reserved.deadline, admission: nil)
    }

    private nonisolated static func requestKey(_ id: String) -> Data { Data(SHA256.hash(data: Data(id.utf8))) }
    private nonisolated static func requestFingerprint(tool: String, arguments: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(JSONValue.object(["tool": .string(tool), "arguments": .object(arguments)]))))
    }

    private func perform(requestID: String, tool: String, arguments: [String: JSONValue],
                         deadline: ContinuousClock.Instant, admission: InputAdmission?) async throws -> NativeResult {
        try Task.checkCancellation()
        guard status == .ready, let threadID else { throw Failure.closed }
        let key = Self.requestKey(requestID), fingerprint = try Self.requestFingerprint(tool: tool, arguments: arguments)
        if let old = consumed[key] {
            guard old == fingerprint, let receipt = receipts[key] else { throw Failure.duplicateRequest }
            return receipt.result
        }
        guard clock.now < deadline else { throw Failure.timeout }
        if let admission {
            guard transport.input != nil else { throw Failure.unavailableRuntime }
            guard clock.now < admission.notAfter else { throw Failure.timeout }
        }
        // Consume before the actual send boundary, including a lost response. The child
        // transport checks admission again immediately before its write, after any actor hop.
        consumed[key] = fingerprint
        do {
            let result = try await withTaskCancellationHandler {
                let params: [String: JSONValue] = ["threadId": .string(threadID), "server": .string(serverName),
                    "tool": .string(tool), "arguments": .object(arguments)]
                if let admission, let input = transport.input {
                    return try await input(.state, params, clock.now.duration(to: deadline), admission)
                }
                return try await transport.request(.state, params, clock.now.duration(to: deadline))
            } onCancel: { Task { await self.close() } }
            try Task.checkCancellation()
            guard status == .ready else { throw Failure.closed }
            let receipt = try Self.decodeResult(result), bytes = result.pretty.utf8.count
            receipts[key] = Receipt(result: receipt, bytes: bytes)
            receiptOrder.append(key); receiptBytes += bytes
            while receiptOrder.count > 8 || receiptBytes > 32 * 1_048_576 {
                let oldest = receiptOrder.removeFirst()
                receiptBytes -= receipts.removeValue(forKey: oldest)?.bytes ?? 0
            }
            return receipt
        } catch let error as MutationFailure {
            // A partial JSON write permanently poisons this owned stream. Never append
            // another request or continue/retry its truncated frame on the same pipe.
            if case .uncertain = error { await close() }
            throw error
        } catch {
            await close()
            if admission != nil { throw MutationFailure.uncertain(error) }
            throw error
        }
    }

    private nonisolated static func acceptsMutationSchema(_ value: JSONValue?, tool: String,
                                                           arguments: [String: JSONValue]) -> Bool {
        let expected: [String: String]
        switch tool {
        case "click": expected = ["app": "string", "x": "number", "y": "number", "click_count": "integer", "mouse_button": "string"]
        case "drag": expected = ["app": "string", "from_x": "number", "from_y": "number", "to_x": "number", "to_y": "number"]
        case "press_key": expected = ["app": "string", "key": "string"]
        case "type_text": expected = ["app": "string", "text": "string"]
        default: return false
        }
        guard let schema = value?.object, schema["type"] == .string("object"),
              schema["additionalProperties"] == .bool(false), let properties = schema["properties"]?.object,
              case .array(let required) = schema["required"], required.allSatisfy({ $0.string != nil }),
              Set(required.compactMap(\.string)).isSubset(of: Set(arguments.keys)),
              Set(arguments.keys) == Set(expected.keys) else { return false }
        for (field, type) in expected where properties[field]?.object?["type"] != .string(type) { return false }
        if tool == "click", case .array(let buttons) = properties["mouse_button"]?.object?["enum"],
           !buttons.contains(.string("left")) { return false }
        return true
    }

    func close() async {
        if let closeTask { await closeTask.value; return }
        guard status != .closed else { return }
        reservationRevocation?.revoke()
        status = .closed; threadID = nil; discovered = nil; reservation = nil
        let queued = waiters; waiters.removeAll()
        for waiter in queued { waiter.timer.cancel(); waiter.continuation.resume(throwing: Failure.closed) }
        consumed.removeAll(); receipts.removeAll(); receiptOrder.removeAll(); receiptBytes = 0
        let transport = transport
        let task = Task { await transport.close() }
        closeTask = task
        await task.value
    }

    private func ensureOpening() throws {
        try Task.checkCancellation()
        guard status == .opening else { throw Failure.closed }
    }

    private func acquire(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard status == .ready else { throw Failure.closed }
        guard clock.now < deadline else { throw Failure.timeout }
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task {
                    do { try await clock.sleep(until: deadline) } catch { return }
                    removeWaiter(id, error: Failure.timeout)
                }
                waiters.append(Waiter(id: id, continuation: continuation, timer: timer))
            }
        } onCancel: { Task { await self.removeWaiter(id, error: CancellationError()) } }
    }

    private func removeWaiter(_ id: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timer.cancel(); waiter.continuation.resume(throwing: error)
    }

    private func release() {
        guard !waiters.isEmpty else { busy = false; return }
        let waiter = waiters.removeFirst()
        waiter.timer.cancel(); waiter.continuation.resume()
    }

    private nonisolated static func decodeCatalog(_ response: JSONValue, serverName: String) throws -> Catalog {
        guard response.pretty.utf8.count <= 1_048_576,
              case .array(let servers) = response.object?["data"] else { throw Failure.malformedResponse }
        let matches = servers.filter { $0.object?["name"]?.string == serverName }
        guard matches.count == 1, let server = matches.first,
              let values = server.object?["tools"]?.object,
              server.object?["toolsError"] == nil || server.object?["toolsError"] == .null,
              server.object?["runtimeStatus"] == nil || server.object?["runtimeStatus"] == .null
                || server.object?["runtimeStatus"] == .string("connected") else { throw Failure.unsupportedCatalog }
        let known: Set<String> = ["get_app_state", "list_apps", "click", "drag", "perform_secondary_action",
                                  "press_key", "scroll", "select_text", "set_value", "type_text"]
        var tools: [Descriptor] = [], seen = Set<String>()
        for value in values.values {
            guard let name = value.object?["name"]?.string, known.contains(name) else { continue }
            guard seen.insert(name).inserted, value.object?["inputSchema"]?.object != nil else { throw Failure.unsupportedCatalog }
            tools.append(Descriptor(name: name, raw: value))
        }
        guard seen.contains("get_app_state") else { throw Failure.unsupportedCatalog }
        guard let stateSchema = tools.first(where: { $0.name == "get_app_state" })?.inputSchema?.object,
              stateSchema["type"] == .string("object"),
              stateSchema["properties"]?.object?["app"]?.object?["type"] == .string("string"),
              stateSchema["required"] == .array([.string("app")]) else { throw Failure.unsupportedCatalog }
        return Catalog(tools: tools.sorted { $0.name < $1.name }, server: server)
    }

    private nonisolated static func decodeResult(_ response: JSONValue) throws -> NativeResult {
        guard response.pretty.utf8.count <= 32 * 1_048_576,
              case .array(let content) = response.object?["content"] else { throw Failure.malformedResponse }
        let error = response.object?["isError"]
        guard error == nil || error == .null || error == .bool(false) || error == .bool(true) else { throw Failure.malformedResponse }
        return NativeResult(raw: response, content: content, isError: error == .bool(true))
    }

    /// JSON's optional escaped slash is not a valid TOML escape. Configuration paths must
    /// therefore use an encoder distinct from the JSON-RPC wire formatter.
    nonisolated static func configurationLiteral(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// Bounded stdio framing for the official app-server. Only this child and its temporary profile
/// are owned. It never restarts/terminates another installation's GUI service or grants access.
private actor OwnedNativeObservationProcess {
    typealias Failure = OwnedNativeComputerUseClient.Failure
    nonisolated let workspace: URL
    private let runtime: OwnedNativeComputerUseClient.Runtime
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var buffer = Data()
    private var pending: (Int, CheckedContinuation<JSONValue, Error>)?
    private var sequence = 0
    private var launched = false
    private var closed = false

    init(runtime: OwnedNativeComputerUseClient.Runtime) throws {
        self.runtime = runtime
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayNativeObservation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        workspace = root
    }

    nonisolated var transport: OwnedNativeComputerUseClient.Transport {
        .init(request: { [self] method, params, timeout in try await request(method, params: params, timeout: timeout) },
              initialized: { [self] in try await initialized() }, close: { [self] in await close() },
              input: { [self] method, params, timeout, admission in
                  try await request(method, params: params, timeout: timeout, inputAdmission: admission)
              })
    }

    func launch() throws {
        guard !closed, !launched else { throw Failure.closed }
        try runtime.validate()
        let inherited = ProcessInfo.processInfo.environment
        var environment = inherited.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG"].contains($0.key) }
        environment["CODEX_HOME"] = workspace.path
        environment["CODEX_CLI_PATH"] = runtime.cli.path
        let settings: [(String, JSONValue)] = [
            ("mcp_servers", .object([:])), ("features.apps", .bool(false)), ("features.plugins", .bool(false)),
            ("features.computer_use", .bool(false)), ("features.hooks", .bool(false)), ("analytics.enabled", .bool(false)),
            ("feedback.enabled", .bool(false)), ("check_for_update_on_startup", .bool(false)),
            ("cli_auth_credentials_store", .string("ephemeral")),
            ("mcp_servers.relay_native.command", .string(runtime.helper.path)),
            ("mcp_servers.relay_native.args", .array([.string("mcp")])),
            ("mcp_servers.relay_native.required", .bool(true)),
            ("mcp_servers.relay_native.startup_timeout_sec", .number(15)),
            ("mcp_servers.relay_native.tool_timeout_sec", .number(95))]
        process.executableURL = runtime.cli
        process.arguments = ["--no-daemon", "app-server", "--listen", "stdio://"]
            + (try settings.flatMap { ["-c", $0.0 + "=" + (try OwnedNativeComputerUseClient.configurationLiteral($0.1))] })
        process.environment = environment; process.currentDirectoryURL = workspace
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.terminated(status) }
        }
        try process.run(); launched = true
        let stdout = output.fileHandleForReading.fileDescriptor
        let stderr = errors.fileHandleForReading.fileDescriptor
        stdoutTask = Task.detached { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while !Task.isCancelled {
                let count = Darwin.read(stdout, &bytes, bytes.count)
                if count > 0 { await self?.receive(Data(bytes.prefix(count))) }
                else if count == 0 { await self?.receive(Data()); break }
                else if errno != EINTR { await self?.fail(Failure.closed); break }
            }
        }
        // Drain without retaining diagnostics that could contain provider/profile data.
        stderrTask = Task.detached {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while !Task.isCancelled {
                let count = Darwin.read(stderr, &bytes, bytes.count)
                if count == 0 || (count < 0 && errno != EINTR) { break }
            }
        }
    }

    private func initialized() throws { try write(.object(["method": .string("initialized")])) }

    private func request(_ method: OwnedNativeComputerUseClient.Method, params: [String: JSONValue], timeout: Duration,
                         inputAdmission: OwnedNativeComputerUseClient.InputAdmission? = nil) async throws -> JSONValue {
        do {
            try Task.checkCancellation()
            guard !closed, launched else { throw Failure.closed }
            guard pending == nil else { throw Failure.busy }
            // Numeric JSON-RPC IDs remain exact through the IEEE-754 integer domain;
            // no arbitrary million-call application lifetime cap is imposed.
            guard timeout > .zero, sequence < 9_007_199_254_740_991 else { throw Failure.timeout }
        } catch {
            if inputAdmission != nil { throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(error) }
            throw error
        }
        sequence += 1
        let id = sequence
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (id, continuation)
                do {
                    try write(.object(["id": .number(Double(id)), "method": .string(method.rawValue), "params": .object(params)]), inputAdmission: inputAdmission)
                    deadlineTask = Task {
                        do { try await Task.sleep(for: timeout) } catch { return }
                        if pending?.0 == id { await fail(Failure.requestTimedOut(method)) }
                    }
                } catch {
                    pending = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { Task { await self.close() } }
    }

    private func write(_ json: JSONValue, inputAdmission: OwnedNativeComputerUseClient.InputAdmission? = nil) throws {
        guard !closed else { throw Failure.closed }
        var bytes = Data(json.pretty.utf8)
        guard bytes.count <= 1_048_576 else { throw Failure.outputLimit }
        bytes.append(0x0A)
        if let inputAdmission {
            // This actor retains the Pipe and admits no await during writer/flag restore.
            // Owned close cannot interleave or close/reuse this descriptor mid-write.
            try NativeInputWriter.write(bytes, to: input.fileHandleForWriting.fileDescriptor, admission: inputAdmission)
            return
        }
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }

    private func receive(_ data: Data) async {
        guard !closed else { return }
        guard !data.isEmpty else { await fail(Failure.closed); return }
        buffer.append(data)
        guard buffer.count <= 32 * 1_048_576 else { await fail(Failure.outputLimit); return }
        while let newline = buffer.firstIndex(of: 0x0A), !closed {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: line), let object = json.object else {
                await fail(Failure.malformedResponse); return
            }
            if object["method"] != nil, let id = object["id"] {
                try? write(.object(["id": id, "error": .object(["code": .number(-32601),
                    "message": .string("Relay observation client declines server requests")])]))
                await fail(Failure.unexpectedServerRequest); return
            }
            guard let id = object["id"]?.int, let request = pending else { continue }
            guard id == request.0 else { await fail(Failure.malformedResponse); return }
            pending = nil; deadlineTask?.cancel(); deadlineTask = nil
            if let error = object["error"], error != .null {
                request.1.resume(throwing: Failure.rpc(code: error.object?["code"]?.int,
                    message: String((error.object?["message"]?.string ?? "Native RPC failed").prefix(1_000))))
            } else if let result = object["result"] {
                request.1.resume(returning: result)
            } else { request.1.resume(throwing: Failure.malformedResponse) }
        }
    }

    private func terminated(_ status: Int32) async { if !closed { await fail(Failure.processExited(status)) } }
    private func fail(_ error: any Error) async {
        let continuation = pending?.1; pending = nil
        continuation?.resume(throwing: error)
        await close()
    }

    func close() async {
        if let drain { await drain.value; return }
        guard !closed else { return }
        closed = true
        deadlineTask?.cancel(); deadlineTask = nil
        pending?.1.resume(throwing: CancellationError()); pending = nil
        buffer.removeAll()
        try? input.fileHandleForWriting.close()
        let process = process, workspace = workspace, launched = launched
        let worker = Task.detached {
            if launched, process.isRunning {
                let escalation = Task.detached {
                    try? await Task.sleep(for: .milliseconds(400))
                    if process.isRunning { process.terminate() }
                    try? await Task.sleep(for: .seconds(2))
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                }
                process.waitUntilExit()
                escalation.cancel()
            }
            try? FileManager.default.removeItem(at: workspace)
        }
        drain = worker
        await worker.value
        stdoutTask?.cancel(); stderrTask?.cancel()
        try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        process.terminationHandler = nil
    }
}
