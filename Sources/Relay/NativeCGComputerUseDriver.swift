import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Built-in first-party macOS computer-use driver implementing `OwnedNativeComputerUseClient.Transport`
/// via `ScreenCaptureKit` (with deterministic AX-layout PNG fallback when Screen Recording is unavailable)
/// and target-bound `CGEvent` pointer, scroll, key-chord, and full UTF-16 Unicode keyboard synthesis.
actor NativeCGComputerUseDriver {
    nonisolated enum DriverError: Error, LocalizedError, Equatable, Sendable {
        case closed
        case unsupportedTool(String)
        case invalidArguments(String)
        case accessibilityPermissionRequired
        case applicationNotFound(String)
        case protectedApplication(String)
        case windowUnavailable(String)
        case secureFieldFocused
        case pointOutOfBounds(x: Double, y: Double, width: Double, height: Double)
        case eventCreationFailed
        case imageEncodingFailed

        var errorDescription: String? {
            switch self {
            case .closed:
                return "Native macOS computer-use driver is closed."
            case .unsupportedTool(let name):
                return "Unsupported native computer-use tool '\(name)'."
            case .invalidArguments(let detail):
                return "Invalid arguments for native computer-use tool: \(detail)."
            case .accessibilityPermissionRequired:
                return "Computer use requires macOS Accessibility permission. Grant Relay access in System Settings -> Privacy & Security -> Accessibility, then try again."
            case .applicationNotFound(let app):
                return "Target application '\(app)' is not running."
            case .protectedApplication(let bundleID):
                return "Computer use is prohibited on protected security/system surface '\(bundleID)'."
            case .windowUnavailable(let app):
                return "No accessible standard window is available for '\(app)'."
            case .secureFieldFocused:
                return "Computer-use input is refused while a password or secure text field is focused."
            case .pointOutOfBounds(let x, let y, let width, let height):
                return "Target coordinate (\(NativeCGComputerUseDriver.formatCoordinate(x)), \(NativeCGComputerUseDriver.formatCoordinate(y))) is outside window bounds (\(NativeCGComputerUseDriver.formatCoordinate(width))x\(NativeCGComputerUseDriver.formatCoordinate(height)))."
            case .eventCreationFailed:
                return "CoreGraphics event synthesis could not create the requested event."
            case .imageEncodingFailed:
                return "Failed to encode target window screenshot as PNG."
            }
        }
    }

    nonisolated enum MouseButtonKind: String, Sendable, Equatable {
        case left
        case right
    }

    nonisolated struct SynthesizedEvent: Sendable, Equatable {
        nonisolated enum Kind: Sendable, Equatable {
            case click(point: CGPoint, button: MouseButtonKind, count: Int)
            case drag(from: CGPoint, to: CGPoint, steps: Int)
            case scroll(point: CGPoint, deltaX: Int32, deltaY: Int32)
            case key(keyCode: CGKeyCode, flagsRawValue: UInt64)
            case unicodeChunks([[UInt16]])
        }
        let pid: pid_t
        let kind: Kind
    }

    nonisolated struct ElementSummary: Sendable, Equatable {
        let index: Int
        let depth: Int
        let role: String
        let subrole: String
        let title: String
        let valuePreview: String?
        let enabled: Bool
        let focused: Bool
        let frame: CGRect?
    }

    nonisolated struct ObservedWindowState: Sendable, Equatable {
        let pid: pid_t
        let bundleID: String
        let bundlePath: String
        let appName: String
        let windowTitle: String
        let windowBounds: CGRect
        let isSecureFieldFocused: Bool
        let elements: [ElementSummary]
        let pngData: Data?
        let imageWidth: Int
        let imageHeight: Int
    }

    nonisolated struct Backend: Sendable {
        var inspectAppState: @Sendable (String) async throws -> ObservedWindowState
        var prepareInputTarget: @Sendable (String) async throws -> ObservedWindowState
        var postEvent: @Sendable (SynthesizedEvent) async throws -> Void

        static func live(
            readAudit: NativeReadAudit? = nil,
            isAccessibilityTrusted: (@Sendable () -> Bool)? = nil
        ) -> Self {
            Self(
                inspectAppState: { app in
                    try await NativeCGComputerUseDriver.captureLiveAppState(
                        appSpecifier: app,
                        includeScreenshot: true,
                        readAudit: readAudit,
                        isAccessibilityTrusted: isAccessibilityTrusted
                    )
                },
                prepareInputTarget: { app in
                    try await NativeCGComputerUseDriver.captureLiveAppState(
                        appSpecifier: app,
                        includeScreenshot: false,
                        readAudit: readAudit,
                        isAccessibilityTrusted: isAccessibilityTrusted
                    )
                },
                postEvent: { event in
                    try await NativeCGComputerUseDriver.dispatchLiveCGEvent(
                        event,
                        isAccessibilityTrusted: isAccessibilityTrusted
                    )
                }
            )
        }
    }

    nonisolated static let serverName = "relay_native"
    nonisolated static let maxScrollDelta: Double = 100_000

    nonisolated static func clampedScrollDelta(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        let clamped = min(max(rounded, -maxScrollDelta), maxScrollDelta)
        return Int32(clamped)
    }

    nonisolated static func formatCoordinate(_ value: Double) -> String {
        guard value.isFinite else {
            if value.isNaN { return "NaN" }
            return value < 0 ? "-Inf" : "Inf"
        }
        let truncated = value.rounded(.towardZero)
        if let exact = Int(exactly: truncated) {
            return String(exact)
        }
        return String(truncated)
    }

    nonisolated static let protectedBundleIDs: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.apple.securityagent",
        "com.apple.tccui",
        "com.apple.coreservices.uiagent",
        "com.apple.loginwindow",
        "com.apple.keychainaccess",
        "com.apple.passwords"
    ]

    private struct FrameMapping: Sendable {
        let windowBounds: CGRect
        let imageWidth: Int
        let imageHeight: Int
    }

    private let backend: Backend
    private var isClosed = false
    private var threadIdentifier = "relay-native-cg-thread"
    private var lastFramesByPID: [pid_t: FrameMapping] = [:]

    init(backend: Backend = .live()) {
        self.backend = backend
    }

    nonisolated static func makeTransport(
        readAudit: NativeReadAudit? = nil,
        backend: Backend? = nil
    ) -> OwnedNativeComputerUseClient.Transport {
        let driver = NativeCGComputerUseDriver(backend: backend ?? .live(readAudit: readAudit))
        return OwnedNativeComputerUseClient.Transport(
            request: { method, params, _ in
                try await driver.handleRequest(method: method, params: params, admission: nil)
            },
            initialized: {
                try await driver.markInitialized()
            },
            close: {
                await driver.shutdown()
            },
            input: { method, params, _, admission in
                try await driver.handleRequest(method: method, params: params, admission: admission)
            }
        )
    }

    private func markInitialized() throws {
        guard !isClosed else { throw OwnedNativeComputerUseClient.Failure.closed }
    }

    func shutdown() {
        isClosed = true
        lastFramesByPID.removeAll()
    }

    func handleRequest(
        method: OwnedNativeComputerUseClient.Method,
        params: [String: JSONValue],
        admission: OwnedNativeComputerUseClient.InputAdmission?
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !isClosed else { throw OwnedNativeComputerUseClient.Failure.closed }

        switch method {
        case .initialize:
            return .object([
                "protocolVersion": .string("2025-03-26"),
                "serverInfo": .object([
                    "name": .string("relay_native_cg_driver"),
                    "version": .string("3.1.0")
                ]),
                "capabilities": .object([:])
            ])

        case .threadStart:
            let freshID = "relay-cg-\(UUID().uuidString.lowercased())"
            threadIdentifier = freshID
            return .object([
                "thread": .object([
                    "id": .string(freshID)
                ])
            ])

        case .catalog:
            return .object([
                "data": .array([
                    .object([
                        "name": .string(Self.serverName),
                        "runtimeStatus": .string("connected"),
                        "tools": .object(Self.catalogTools)
                    ])
                ])
            ])

        case .state:
            guard let tool = params["tool"]?.string else {
                throw OwnedNativeComputerUseClient.Failure.malformedResponse
            }
            let arguments = params["arguments"]?.object ?? [:]
            return try await executeTool(name: tool, arguments: arguments, admission: admission)
        }
    }

    // MARK: - Tool Execution

    private func executeTool(
        name: String,
        arguments: [String: JSONValue],
        admission: OwnedNativeComputerUseClient.InputAdmission?
    ) async throws -> JSONValue {
        switch name {
        case "list_apps":
            let apps = await MainActor.run {
                NSWorkspace.shared.runningApplications
                    .filter { !$0.isTerminated && $0.activationPolicy == .regular }
                    .compactMap { app -> String? in
                        guard let bundleID = app.bundleIdentifier else { return nil }
                        let title = app.localizedName ?? bundleID
                        let path = app.bundleURL?.standardizedFileURL.path ?? ""
                        return "\(title) (bundleID \(bundleID), pid \(app.processIdentifier), path \(path))"
                    }
                    .sorted()
            }
            return Self.toolResult(text: apps.joined(separator: "\n"))

        case "get_app_state":
            guard let app = arguments["app"]?.string, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DriverError.invalidArguments("Missing required 'app' string")
            }
            let observed = try await backend.inspectAppState(app)
            let png: (data: Data, width: Int, height: Int)
            if let existing = observed.pngData, observed.imageWidth > 0, observed.imageHeight > 0 {
                png = (existing, observed.imageWidth, observed.imageHeight)
            } else {
                png = try Self.renderWireframePNG(for: observed)
            }
            lastFramesByPID[observed.pid] = FrameMapping(
                windowBounds: observed.windowBounds,
                imageWidth: png.width,
                imageHeight: png.height
            )
            let stateText = Self.formatAppStateText(observed)
            return .object([
                "isError": .bool(false),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(stateText)
                    ]),
                    .object([
                        "type": .string("image"),
                        "mimeType": .string("image/png"),
                        "data": .string(png.data.base64EncodedString())
                    ])
                ])
            ])

        case "click":
            return try await performPointerClick(arguments: arguments, admission: admission)

        case "drag":
            return try await performPointerDrag(arguments: arguments, admission: admission)

        case "scroll":
            return try await performScroll(arguments: arguments, admission: admission)

        case "press_key":
            return try await performKeyPress(arguments: arguments, admission: admission)

        case "type_text":
            return try await performUnicodeTyping(arguments: arguments, admission: admission)

        default:
            throw OwnedNativeComputerUseClient.Failure.unsupportedCatalog
        }
    }

    private func performPointerClick(
        arguments: [String: JSONValue],
        admission: OwnedNativeComputerUseClient.InputAdmission?
    ) async throws -> JSONValue {
        let app: String
        let rawX: Double
        let rawY: Double
        let button: MouseButtonKind
        let clickCount: Int
        let target: ObservedWindowState
        let screenPoint: CGPoint
        do {
            guard let appArg = arguments["app"]?.string,
                  let xArg = Self.number(arguments["x"]),
                  let yArg = Self.number(arguments["y"]) else {
                throw OwnedNativeComputerUseClient.Failure.malformedResponse
            }
            let buttonRaw = arguments["mouse_button"]?.string ?? "left"
            guard let parsedButton = MouseButtonKind(rawValue: buttonRaw) else {
                throw OwnedNativeComputerUseClient.Failure.malformedResponse
            }
            let rawClickCount: Double
            if let countVal = arguments["click_count"] {
                guard let parsedCount = Self.number(countVal), parsedCount.isFinite else {
                    throw OwnedNativeComputerUseClient.Failure.malformedResponse
                }
                rawClickCount = parsedCount
            } else {
                rawClickCount = 1
            }
            app = appArg
            rawX = xArg
            rawY = yArg
            button = parsedButton
            clickCount = Int(min(max(rawClickCount.rounded(.towardZero), 1), 3))

            target = try await backend.prepareInputTarget(app)
            try Self.verifyWritableTarget(target)
            screenPoint = try resolveScreenPoint(x: rawX, y: rawY, target: target)
        } catch {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(error)
            }
            throw error
        }

        if let admission {
            try admission.begin()
        }
        do {
            try await backend.postEvent(
                SynthesizedEvent(pid: target.pid, kind: .click(point: screenPoint, button: button, count: clickCount))
            )
        } catch DriverError.accessibilityPermissionRequired {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(DriverError.accessibilityPermissionRequired)
            }
            throw DriverError.accessibilityPermissionRequired
        }
        return Self.toolResult(
            text: "Clicked (\(button.rawValue), count=\(clickCount)) at (\(Self.formatCoordinate(screenPoint.x)), \(Self.formatCoordinate(screenPoint.y))) in \(target.appName)."
        )
    }

    private func performPointerDrag(
        arguments: [String: JSONValue],
        admission: OwnedNativeComputerUseClient.InputAdmission?
    ) async throws -> JSONValue {
        let app: String
        let fromX: Double
        let fromY: Double
        let toX: Double
        let toY: Double
        let target: ObservedWindowState
        let startPoint: CGPoint
        let endPoint: CGPoint
        do {
            guard let appArg = arguments["app"]?.string,
                  let fx = Self.number(arguments["from_x"]),
                  let fy = Self.number(arguments["from_y"]),
                  let tx = Self.number(arguments["to_x"]),
                  let ty = Self.number(arguments["to_y"]) else {
                throw OwnedNativeComputerUseClient.Failure.malformedResponse
            }
            app = appArg
            fromX = fx
            fromY = fy
            toX = tx
            toY = ty

            target = try await backend.prepareInputTarget(app)
            try Self.verifyWritableTarget(target)
            startPoint = try resolveScreenPoint(x: fromX, y: fromY, target: target)
            endPoint = try resolveScreenPoint(x: toX, y: toY, target: target)
        } catch {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(error)
            }
            throw error
        }

        if let admission {
            try admission.begin()
        }
        do {
            try await backend.postEvent(
                SynthesizedEvent(pid: target.pid, kind: .drag(from: startPoint, to: endPoint, steps: 12))
            )
        } catch DriverError.accessibilityPermissionRequired {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(DriverError.accessibilityPermissionRequired)
            }
            throw DriverError.accessibilityPermissionRequired
        }
        return Self.toolResult(
            text: "Dragged from (\(Self.formatCoordinate(startPoint.x)), \(Self.formatCoordinate(startPoint.y))) to (\(Self.formatCoordinate(endPoint.x)), \(Self.formatCoordinate(endPoint.y))) in \(target.appName)."
        )
    }

    private func performScroll(
        arguments: [String: JSONValue],
        admission: OwnedNativeComputerUseClient.InputAdmission?
    ) async throws -> JSONValue {
        let app: String
        let rawX: Double
        let rawY: Double
        let deltaX: Int32
        let deltaY: Int32
        let target: ObservedWindowState
        let screenPoint: CGPoint
        do {
            guard let appArg = arguments["app"]?.string,
                  let xArg = Self.number(arguments["x"]),
                  let yArg = Self.number(arguments["y"]) else {
                throw OwnedNativeComputerUseClient.Failure.malformedResponse
            }
            let rawDeltaX: Double
            if let dxVal = arguments["delta_x"] {
                guard let parsed = Self.number(dxVal), parsed.isFinite else {
                    throw OwnedNativeComputerUseClient.Failure.malformedResponse
                }
                rawDeltaX = parsed
            } else {
                rawDeltaX = 0
            }
            let rawDeltaY: Double
            if let dyVal = arguments["delta_y"] {
                guard let parsed = Self.number(dyVal), parsed.isFinite else {
                    throw OwnedNativeComputerUseClient.Failure.malformedResponse
                }
                rawDeltaY = parsed
            } else {
                rawDeltaY = 0
            }
            app = appArg
            rawX = xArg
            rawY = yArg
            deltaX = Self.clampedScrollDelta(rawDeltaX)
            deltaY = Self.clampedScrollDelta(rawDeltaY)

            target = try await backend.prepareInputTarget(app)
            try Self.verifyWritableTarget(target)
            screenPoint = try resolveScreenPoint(x: rawX, y: rawY, target: target)
        } catch {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(error)
            }
            throw error
        }

        if let admission {
            try admission.begin()
        }
        do {
            try await backend.postEvent(
                SynthesizedEvent(pid: target.pid, kind: .scroll(point: screenPoint, deltaX: deltaX, deltaY: deltaY))
            )
        } catch DriverError.accessibilityPermissionRequired {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(DriverError.accessibilityPermissionRequired)
            }
            throw DriverError.accessibilityPermissionRequired
        }
        return Self.toolResult(
            text: "Scrolled (\(deltaX), \(deltaY)) at (\(Self.formatCoordinate(screenPoint.x)), \(Self.formatCoordinate(screenPoint.y))) in \(target.appName)."
        )
    }

    private func performKeyPress(
        arguments: [String: JSONValue],
        admission: OwnedNativeComputerUseClient.InputAdmission?
    ) async throws -> JSONValue {
        let keySpec: String
        let resolvedKey: (keyCode: CGKeyCode, flags: CGEventFlags)
        let target: ObservedWindowState
        do {
            guard let app = arguments["app"]?.string,
                  let keyArg = arguments["key"]?.string,
                  !keyArg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OwnedNativeComputerUseClient.Failure.malformedResponse
            }
            keySpec = keyArg
            resolvedKey = try Self.parseKeyChord(keySpec)
            target = try await backend.prepareInputTarget(app)
            try Self.verifyWritableTarget(target)
        } catch {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(error)
            }
            throw error
        }

        if let admission {
            try admission.begin()
        }
        do {
            try await backend.postEvent(
                SynthesizedEvent(pid: target.pid, kind: .key(keyCode: resolvedKey.keyCode, flagsRawValue: resolvedKey.flags.rawValue))
            )
        } catch DriverError.accessibilityPermissionRequired {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(DriverError.accessibilityPermissionRequired)
            }
            throw DriverError.accessibilityPermissionRequired
        }
        return Self.toolResult(text: "Pressed key '\(keySpec)' in \(target.appName).")
    }

    private func performUnicodeTyping(
        arguments: [String: JSONValue],
        admission: OwnedNativeComputerUseClient.InputAdmission?
    ) async throws -> JSONValue {
        guard let app = arguments["app"]?.string,
              let text = arguments["text"]?.string,
              NativeControlSession.validUnsentText(text) else {
            let err = OwnedNativeComputerUseClient.Failure.malformedResponse
            if admission != nil { throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(err) }
            throw err
        }

        let chunks = Self.chunkUTF16PreservingSurrogatePairs(text, maxCodeUnitsPerChunk: 20)
        let target: ObservedWindowState
        do {
            target = try await backend.prepareInputTarget(app)
            try Self.verifyWritableTarget(target)
        } catch {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(error)
            }
            throw error
        }

        if let admission {
            try admission.begin()
        }
        do {
            try await backend.postEvent(
                SynthesizedEvent(pid: target.pid, kind: .unicodeChunks(chunks))
            )
        } catch DriverError.accessibilityPermissionRequired {
            if admission != nil {
                throw OwnedNativeComputerUseClient.MutationFailure.notDispatched(DriverError.accessibilityPermissionRequired)
            }
            throw DriverError.accessibilityPermissionRequired
        }
        return Self.toolResult(text: "Typed \(text.count) characters into \(target.appName).")
    }

    private func resolveScreenPoint(x: Double, y: Double, target: ObservedWindowState) throws -> CGPoint {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0 else {
            throw DriverError.pointOutOfBounds(x: x, y: y, width: target.windowBounds.width, height: target.windowBounds.height)
        }
        let bounds = target.windowBounds
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            throw DriverError.windowUnavailable(target.appName)
        }

        let localX: Double
        let localY: Double
        if let mapping = lastFramesByPID[target.pid], mapping.imageWidth > 0, mapping.imageHeight > 0 {
            guard x <= Double(mapping.imageWidth), y <= Double(mapping.imageHeight) else {
                throw DriverError.pointOutOfBounds(x: x, y: y, width: Double(mapping.imageWidth), height: Double(mapping.imageHeight))
            }
            localX = (x / Double(mapping.imageWidth)) * bounds.width
            localY = (y / Double(mapping.imageHeight)) * bounds.height
        } else {
            guard x <= bounds.width, y <= bounds.height else {
                throw DriverError.pointOutOfBounds(x: x, y: y, width: bounds.width, height: bounds.height)
            }
            localX = x
            localY = y
        }

        let clampedLocalX = min(max(0.5, localX), max(0.5, bounds.width - 0.5))
        let clampedLocalY = min(max(0.5, localY), max(0.5, bounds.height - 0.5))
        let globalPoint = CGPoint(x: bounds.origin.x + clampedLocalX, y: bounds.origin.y + clampedLocalY)
        guard bounds.insetBy(dx: -1.0, dy: -1.0).contains(globalPoint) else {
            throw DriverError.pointOutOfBounds(x: x, y: y, width: bounds.width, height: bounds.height)
        }
        return globalPoint
    }

    nonisolated private static func verifyWritableTarget(_ target: ObservedWindowState) throws {
        if protectedBundleIDs.contains(target.bundleID.lowercased()) {
            throw DriverError.protectedApplication(target.bundleID)
        }
        if target.isSecureFieldFocused {
            throw DriverError.secureFieldFocused
        }
    }

    // MARK: - Surrogate-Safe UTF-16 Chunking & Key Parsing

    nonisolated static func chunkUTF16PreservingSurrogatePairs(
        _ text: String,
        maxCodeUnitsPerChunk: Int = 20
    ) -> [[UInt16]] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }
        let limit = max(2, maxCodeUnitsPerChunk)
        var chunks: [[UInt16]] = []
        var index = 0
        while index < units.count {
            var end = min(index + limit, units.count)
            if end < units.count,
               UTF16.isLeadSurrogate(units[end - 1]),
               UTF16.isTrailSurrogate(units[end]) {
                end -= 1
            }
            chunks.append(Array(units[index..<end]))
            index = end
        }
        return chunks
    }

    nonisolated static func parseKeyChord(_ raw: String) throws -> (keyCode: CGKeyCode, flags: CGEventFlags) {
        let tokens = raw
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let keyToken = tokens.last, !keyToken.isEmpty else {
            throw DriverError.invalidArguments("Empty key specification")
        }

        var flags: CGEventFlags = []
        for modifier in tokens.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "meta", "super":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "alt", "opt", "option":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            default:
                throw DriverError.invalidArguments("Unknown key modifier '\(modifier)'")
            }
        }

        guard let keyCode = virtualKeyCode(for: keyToken) else {
            throw DriverError.invalidArguments("Unsupported key '\(keyToken)'")
        }
        return (keyCode, flags)
    }

    nonisolated private static func virtualKeyCode(for token: String) -> CGKeyCode? {
        switch token.lowercased() {
        case "left", "arrowleft": return 123
        case "right", "arrowright": return 124
        case "down", "arrowdown": return 125
        case "up", "arrowup": return 126
        case "home": return 115
        case "end": return 119
        case "pageup", "page_up": return 116
        case "pagedown", "page_down": return 121
        case "return", "enter": return 36
        case "tab": return 48
        case "escape", "esc": return 53
        case "space": return 49
        case "delete", "backspace": return 51
        case "forwarddelete", "forward_delete": return 117
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "=", "equal": return 24
        case "9": return 25
        case "7": return 26
        case "-", "minus": return 27
        case "8": return 28
        case "0": return 29
        case "]": return 30
        case "o": return 31
        case "u": return 32
        case "[": return 33
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "'": return 39
        case "k": return 40
        case ";": return 41
        case "\\": return 42
        case ",": return 43
        case "/": return 44
        case "n": return 45
        case "m": return 46
        case ".": return 47
        case "`": return 50
        default: return nil
        }
    }

    // MARK: - CUA Header & State Formatting

    nonisolated static func formatAppStateText(_ state: ObservedWindowState) -> String {
        let cleanTitle = sanitizeSingleLine(state.windowTitle)
        let cleanApp = sanitizeSingleLine(state.appName.isEmpty ? state.bundleID : state.appName)
        var lines: [String] = [
            "Computer Use state (CUA App Version: 1)",
            "<app_state>",
            "App=\(state.bundlePath) (bundleID \(state.bundleID), pid \(state.pid))",
            "Window: \"\(cleanTitle)\", App: \(cleanApp)"
        ]

        var usedBytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        let maxBytes = 240_000
        var focusedDescription: String?

        for element in state.elements {
            let indent = String(repeating: "\t", count: min(8, max(1, element.depth)))
            var parts = ["\(indent)\(element.index) \(element.role)"]
            if !element.subrole.isEmpty {
                parts.append("(\(element.subrole))")
            }
            if !element.title.isEmpty {
                parts.append("\"\(sanitizeSingleLine(element.title))\"")
            }
            if let valuePreview = element.valuePreview, !valuePreview.isEmpty {
                parts.append("value=\"\(sanitizeSingleLine(valuePreview))\"")
            }
            if !element.enabled {
                parts.append("disabled")
            }
            if let frame = element.frame,
               frame.origin.x.isFinite,
               frame.origin.y.isFinite,
               frame.width.isFinite,
               frame.height.isFinite {
                parts.append("[\(formatCoordinate(frame.origin.x)),\(formatCoordinate(frame.origin.y)) \(formatCoordinate(frame.width))x\(formatCoordinate(frame.height))]")
            }
            let row = parts.joined(separator: " ")
            if usedBytes + row.utf8.count + 256 > maxBytes {
                break
            }
            lines.append(row)
            usedBytes += row.utf8.count + 1
            if element.focused {
                focusedDescription = "The focused UI element is \(element.index) \(element.role)"
            }
        }

        if let focusedDescription {
            lines.append(focusedDescription)
        }
        lines.append("</app_state>")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func sanitizeSingleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: - Live AX Inspection + ScreenCaptureKit / Wireframe Capture

    nonisolated static func captureLiveAppState(
        appSpecifier: String,
        includeScreenshot: Bool,
        readAudit: NativeReadAudit? = nil,
        isAccessibilityTrusted: (@Sendable () -> Bool)? = nil
    ) async throws -> ObservedWindowState {
        let axSnapshot = try await MainActor.run {
            try Self.inspectAXWindowOnMain(
                appSpecifier: appSpecifier,
                readAudit: readAudit,
                isAccessibilityTrusted: isAccessibilityTrusted
            )
        }

        guard includeScreenshot else {
            return axSnapshot
        }

        if CGPreflightScreenCaptureAccess(),
           let captured = try? await Self.captureWindowScreenshotPNG(
               pid: axSnapshot.pid,
               bundleID: axSnapshot.bundleID,
               windowTitle: axSnapshot.windowTitle,
               windowBounds: axSnapshot.windowBounds
           ) {
            return ObservedWindowState(
                pid: axSnapshot.pid,
                bundleID: axSnapshot.bundleID,
                bundlePath: axSnapshot.bundlePath,
                appName: axSnapshot.appName,
                windowTitle: axSnapshot.windowTitle,
                windowBounds: axSnapshot.windowBounds,
                isSecureFieldFocused: axSnapshot.isSecureFieldFocused,
                elements: axSnapshot.elements,
                pngData: captured.data,
                imageWidth: captured.width,
                imageHeight: captured.height
            )
        }

        let wireframe = try Self.renderWireframePNG(for: axSnapshot)
        return ObservedWindowState(
            pid: axSnapshot.pid,
            bundleID: axSnapshot.bundleID,
            bundlePath: axSnapshot.bundlePath,
            appName: axSnapshot.appName,
            windowTitle: axSnapshot.windowTitle,
            windowBounds: axSnapshot.windowBounds,
            isSecureFieldFocused: axSnapshot.isSecureFieldFocused,
            elements: axSnapshot.elements,
            pngData: wireframe.data,
            imageWidth: wireframe.width,
            imageHeight: wireframe.height
        )
    }

    @MainActor
    private static func inspectAXWindowOnMain(
        appSpecifier: String,
        readAudit: NativeReadAudit?,
        isAccessibilityTrusted: (@Sendable () -> Bool)? = nil
    ) throws -> ObservedWindowState {
        guard isAccessibilityTrusted?() ?? AXIsProcessTrusted() else {
            throw DriverError.accessibilityPermissionRequired
        }
        guard let running = resolveRunningApplication(appSpecifier), !running.isTerminated else {
            throw DriverError.applicationNotFound(appSpecifier)
        }
        let pid = running.processIdentifier
        let bundleID = running.bundleIdentifier ?? appSpecifier
        if protectedBundleIDs.contains(bundleID.lowercased()) {
            throw DriverError.protectedApplication(bundleID)
        }
        let bundlePath = running.bundleURL?.standardizedFileURL.path ?? appSpecifier
        let appName: String
        if let localizedName = running.localizedName, !localizedName.isEmpty {
            appName = localizedName
        } else {
            appName = bundleID
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.15)

        let focusedElement = copyAXElement(appElement, kAXFocusedUIElementAttribute, readAudit: readAudit)
        let isSecureFocused: Bool = {
            guard let focusedElement else { return false }
            let role = copyAXString(focusedElement, kAXRoleAttribute, readAudit: readAudit) ?? ""
            let subrole = copyAXString(focusedElement, kAXSubroleAttribute, readAudit: readAudit) ?? ""
            return isSecureRole(role: role, subrole: subrole)
        }()

        guard let window = selectTargetWindow(appElement: appElement, readAudit: readAudit) else {
            if !(isAccessibilityTrusted?() ?? AXIsProcessTrusted()) {
                throw DriverError.accessibilityPermissionRequired
            }
            throw DriverError.windowUnavailable(appName)
        }
        AXUIElementSetMessagingTimeout(window, 0.15)

        let windowTitle = copyAXString(window, kAXTitleAttribute, readAudit: readAudit) ?? ""
        let bounds = copyAXBounds(window, readAudit: readAudit) ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        guard bounds.width >= 1, bounds.height >= 1 else {
            throw DriverError.windowUnavailable(appName)
        }

        var elements: [ElementSummary] = []
        var stack: [(element: AXUIElement, depth: Int)] = [(window, 1)]
        var visited: [AXUIElement] = []

        while let current = stack.popLast(), elements.count < 180 {
            if visited.contains(where: { CFEqual($0, current.element) }) {
                continue
            }
            visited.append(current.element)
            AXUIElementSetMessagingTimeout(current.element, 0.08)

            let role = copyAXString(current.element, kAXRoleAttribute, readAudit: readAudit) ?? "AXGroup"
            let subrole = copyAXString(current.element, kAXSubroleAttribute, readAudit: readAudit) ?? ""
            let secure = isSecureRole(role: role, subrole: subrole)
            let title = secure
                ? "[REDACTED]"
                : (copyAXString(current.element, kAXTitleAttribute, readAudit: readAudit)
                    ?? copyAXString(current.element, kAXDescriptionAttribute, readAudit: readAudit)
                    ?? "")
            let valuePreview: String? = {
                if secure { return "[REDACTED]" }
                guard ["AXStaticText", "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXDateField"].contains(role) else {
                    return nil
                }
                guard let raw = copyAXScalarString(current.element, kAXValueAttribute, readAudit: readAudit), !raw.isEmpty else {
                    return nil
                }
                return String(raw.prefix(240))
            }()
            let enabled = copyAXBool(current.element, kAXEnabledAttribute, readAudit: readAudit) ?? true
            let isFocused = focusedElement.map { CFEqual($0, current.element) } ?? false
            let elementBounds = copyAXBounds(current.element, readAudit: readAudit).map { rect in
                CGRect(
                    x: rect.origin.x - bounds.origin.x,
                    y: rect.origin.y - bounds.origin.y,
                    width: rect.width,
                    height: rect.height
                )
            }

            let index = elements.count + 1
            elements.append(
                ElementSummary(
                    index: index,
                    depth: current.depth,
                    role: role,
                    subrole: subrole,
                    title: String(title.prefix(160)),
                    valuePreview: valuePreview,
                    enabled: enabled,
                    focused: isFocused,
                    frame: elementBounds
                )
            )

            if current.depth < 9, !secure, let children = copyAXChildren(current.element, readAudit: readAudit) {
                for child in children.prefix(48).reversed() {
                    stack.append((child, current.depth + 1))
                }
            }
        }

        return ObservedWindowState(
            pid: pid,
            bundleID: bundleID,
            bundlePath: bundlePath,
            appName: appName,
            windowTitle: windowTitle,
            windowBounds: bounds,
            isSecureFieldFocused: isSecureFocused,
            elements: elements,
            pngData: nil,
            imageWidth: 0,
            imageHeight: 0
        )
    }

    @MainActor
    private static func resolveRunningApplication(_ specifier: String) -> NSRunningApplication? {
        let trimmed = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }

        if trimmed.hasPrefix("/") {
            let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            if let exact = running.first(where: { $0.bundleURL?.standardizedFileURL.path == standardized }) {
                return exact
            }
        }
        if let byBundle = running.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return byBundle
        }
        return running.first(where: { $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame })
    }

    @MainActor
    private static func selectTargetWindow(appElement: AXUIElement, readAudit: NativeReadAudit?) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let candidate = copyAXElement(appElement, attr, readAudit: readAudit),
               (copyAXBool(candidate, kAXMinimizedAttribute, readAudit: readAudit) ?? false) == false {
                return candidate
            }
        }
        if let windows = copyAXChildren(appElement, attribute: kAXWindowsAttribute, readAudit: readAudit) {
            return windows.first { (copyAXBool($0, kAXMinimizedAttribute, readAudit: readAudit) ?? false) == false }
                ?? windows.first
        }
        return nil
    }

    nonisolated private static func captureWindowScreenshotPNG(
        pid: pid_t,
        bundleID: String,
        windowTitle: String,
        windowBounds: CGRect
    ) async throws -> (data: Data, width: Int, height: Int) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == pid && window.frame.width >= 16 && window.frame.height >= 16
        }
        let best = candidates.min { lhs, rhs in
            let lhsTitlePenalty = (lhs.title == windowTitle) ? 0.0 : 500.0
            let rhsTitlePenalty = (rhs.title == windowTitle) ? 0.0 : 500.0
            return lhsTitlePenalty + frameDistance(lhs.frame, windowBounds) < rhsTitlePenalty + frameDistance(rhs.frame, windowBounds)
        }
        guard let matchedWindow = best else {
            throw DriverError.windowUnavailable(bundleID)
        }

        let frame = matchedWindow.frame
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            throw DriverError.windowUnavailable(bundleID)
        }
        let maxDimension = max(frame.width, frame.height, 1.0)
        let scale = min(2.0, 2_048.0 / maxDimension)
        let width = Int(min(4_096, max(1, (frame.width * scale).rounded())))
        let height = Int(min(4_096, max(1, (frame.height * scale).rounded())))

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: matchedWindow)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let pngData = try encodePNG(image)
        return (pngData, image.width, image.height)
    }

    nonisolated private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        abs(lhs.origin.x - rhs.origin.x)
            + abs(lhs.origin.y - rhs.origin.y)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    nonisolated static func renderWireframePNG(for state: ObservedWindowState) throws -> (data: Data, width: Int, height: Int) {
        guard state.windowBounds.width.isFinite, state.windowBounds.height.isFinite,
              state.windowBounds.width > 0, state.windowBounds.height > 0 else {
            throw DriverError.imageEncodingFailed
        }
        let maxEdge = max(state.windowBounds.width, state.windowBounds.height, 1.0)
        let scale = min(1.0, 1_600.0 / maxEdge)
        let width = Int(min(2_048, max(64, (state.windowBounds.width * scale).rounded())))
        let height = Int(min(2_048, max(64, (state.windowBounds.height * scale).rounded())))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw DriverError.imageEncodingFailed
        }

        context.setFillColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setStrokeColor(red: 0.25, green: 0.30, blue: 0.38, alpha: 1.0)
        context.setLineWidth(1.0)
        for element in state.elements.dropFirst() {
            guard let frame = element.frame, frame.width > 1, frame.height > 1 else { continue }
            let scaledX = frame.origin.x * scale
            let scaledY = Double(height) - ((frame.origin.y + frame.height) * scale)
            let rect = CGRect(
                x: scaledX,
                y: scaledY,
                width: frame.width * scale,
                height: frame.height * scale
            ).intersection(CGRect(x: 0, y: 0, width: Double(width), height: Double(height)))
            guard !rect.isNull, !rect.isEmpty else { continue }
            context.stroke(rect)
        }

        guard let cgImage = context.makeImage() else {
            throw DriverError.imageEncodingFailed
        }
        return (try encodePNG(cgImage), cgImage.width, cgImage.height)
    }

    nonisolated private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw DriverError.imageEncodingFailed
        }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= NativeVisionFrame.maximumOriginalBytes else {
            throw DriverError.imageEncodingFailed
        }
        return data as Data
    }

    // MARK: - Live CGEvent Synthesis

    nonisolated static func dispatchLiveCGEvent(
        _ event: SynthesizedEvent,
        isAccessibilityTrusted: (@Sendable () -> Bool)? = nil
    ) async throws {
        guard isAccessibilityTrusted?() ?? AXIsProcessTrusted() else {
            throw DriverError.accessibilityPermissionRequired
        }

        await MainActor.run {
            if let running = NSRunningApplication(processIdentifier: event.pid), !running.isTerminated, !running.isActive {
                _ = running.activate()
            }
        }

        guard isAccessibilityTrusted?() ?? AXIsProcessTrusted() else {
            throw DriverError.accessibilityPermissionRequired
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw DriverError.eventCreationFailed
        }

        switch event.kind {
        case .click(let point, let button, let count):
            let moveType: CGEventType = .mouseMoved
            let downType: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
            let upType: CGEventType = (button == .right) ? .rightMouseUp : .leftMouseUp
            let cgButton: CGMouseButton = (button == .right) ? .right : .left

            if let move = CGEvent(mouseEventSource: source, mouseType: moveType, mouseCursorPosition: point, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }
            for step in 1...max(1, count) {
                guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
                      let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else {
                    throw DriverError.eventCreationFailed
                }
                down.setIntegerValueField(.mouseEventClickState, value: Int64(step))
                up.setIntegerValueField(.mouseEventClickState, value: Int64(step))
                down.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(12))
                up.post(tap: .cghidEventTap)
                if step < count {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }

        case .drag(let from, let to, let steps):
            guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left),
                  let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left) else {
                throw DriverError.eventCreationFailed
            }
            move.post(tap: .cghidEventTap)
            down.post(tap: .cghidEventTap)
            let totalSteps = max(4, steps)
            for index in 1...totalSteps {
                let progress = Double(index) / Double(totalSteps)
                let current = CGPoint(
                    x: from.x + (to.x - from.x) * progress,
                    y: from.y + (to.y - from.y) * progress
                )
                guard let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: current, mouseButton: .left) else {
                    throw DriverError.eventCreationFailed
                }
                drag.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(8))
            }
            guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) else {
                throw DriverError.eventCreationFailed
            }
            up.post(tap: .cghidEventTap)

        case .scroll(let point, let deltaX, let deltaY):
            if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }
            guard let scroll = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
            ) else {
                throw DriverError.eventCreationFailed
            }
            scroll.post(tap: .cghidEventTap)

        case .key(let keyCode, let flagsRawValue):
            let flags = CGEventFlags(rawValue: flagsRawValue)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                throw DriverError.eventCreationFailed
            }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(8))
            up.post(tap: .cghidEventTap)

        case .unicodeChunks(let chunks):
            for chunk in chunks where !chunk.isEmpty {
                var units = chunk
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw DriverError.eventCreationFailed
                }
                down.flags = []
                up.flags = []
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                if chunks.count > 1 {
                    try await Task.sleep(for: .milliseconds(4))
                }
            }
        }
    }

    // MARK: - Low-Level AX Helpers

    @MainActor
    private static func copyAXRaw(
        _ element: AXUIElement,
        _ attribute: String,
        readAudit: NativeReadAudit?
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = NativeReadAudit.measure(readAudit, .policyMetadata) {
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        }
        guard status == .success else { return nil }
        return value
    }

    @MainActor
    private static func copyAXString(_ element: AXUIElement, _ attribute: String, readAudit: NativeReadAudit?) -> String? {
        copyAXRaw(element, attribute, readAudit: readAudit) as? String
    }

    @MainActor
    private static func copyAXScalarString(_ element: AXUIElement, _ attribute: String, readAudit: NativeReadAudit?) -> String? {
        guard let raw = copyAXRaw(element, attribute, readAudit: readAudit) else { return nil }
        if let str = raw as? String { return str }
        if let num = raw as? NSNumber { return num.stringValue }
        return nil
    }

    @MainActor
    private static func copyAXBool(_ element: AXUIElement, _ attribute: String, readAudit: NativeReadAudit?) -> Bool? {
        guard let raw = copyAXRaw(element, attribute, readAudit: readAudit),
              CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(raw, to: CFBoolean.self))
    }

    @MainActor
    private static func copyAXElement(_ element: AXUIElement, _ attribute: String, readAudit: NativeReadAudit?) -> AXUIElement? {
        guard let raw = copyAXRaw(element, attribute, readAudit: readAudit),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    @MainActor
    private static func copyAXChildren(
        _ element: AXUIElement,
        attribute: String = kAXChildrenAttribute,
        readAudit: NativeReadAudit?
    ) -> [AXUIElement]? {
        guard let raw = copyAXRaw(element, attribute, readAudit: readAudit) as? [AnyObject] else { return nil }
        return raw.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
        }
    }

    @MainActor
    private static func copyAXBounds(_ element: AXUIElement, readAudit: NativeReadAudit?) -> CGRect? {
        guard let posRaw = copyAXRaw(element, kAXPositionAttribute, readAudit: readAudit),
              let sizeRaw = copyAXRaw(element, kAXSizeAttribute, readAudit: readAudit),
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        let posVal = unsafeDowncast(posRaw, to: AXValue.self)
        let sizeVal = unsafeDowncast(sizeRaw, to: AXValue.self)
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &point),
              AXValueGetValue(sizeVal, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    nonisolated private static func isSecureRole(role: String, subrole: String) -> Bool {
        role.localizedCaseInsensitiveContains("secure")
            || role.localizedCaseInsensitiveContains("password")
            || subrole.localizedCaseInsensitiveContains("secure")
            || subrole.localizedCaseInsensitiveContains("password")
    }

    // MARK: - Catalog Schema Helpers

    nonisolated private static func toolResult(text: String, isError: Bool = false) -> JSONValue {
        .object([
            "isError": .bool(isError),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ])
        ])
    }

    nonisolated private static func number(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        if case .number(let n) = value { return n }
        return nil
    }

    nonisolated private static func schema(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string))
        ])
    }

    nonisolated static let catalogTools: [String: JSONValue] = [
        "get_app_state": .object([
            "name": .string("get_app_state"),
            "inputSchema": schema(
                properties: ["app": .object(["type": .string("string")])],
                required: ["app"]
            )
        ]),
        "list_apps": .object([
            "name": .string("list_apps"),
            "inputSchema": schema(properties: [:], required: [])
        ]),
        "click": .object([
            "name": .string("click"),
            "inputSchema": schema(
                properties: [
                    "app": .object(["type": .string("string")]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                    "click_count": .object(["type": .string("integer")]),
                    "mouse_button": .object([
                        "type": .string("string"),
                        "enum": .array([.string("left"), .string("right")])
                    ])
                ],
                required: ["app", "x", "y", "click_count", "mouse_button"]
            )
        ]),
        "drag": .object([
            "name": .string("drag"),
            "inputSchema": schema(
                properties: [
                    "app": .object(["type": .string("string")]),
                    "from_x": .object(["type": .string("number")]),
                    "from_y": .object(["type": .string("number")]),
                    "to_x": .object(["type": .string("number")]),
                    "to_y": .object(["type": .string("number")])
                ],
                required: ["app", "from_x", "from_y", "to_x", "to_y"]
            )
        ]),
        "scroll": .object([
            "name": .string("scroll"),
            "inputSchema": schema(
                properties: [
                    "app": .object(["type": .string("string")]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                    "delta_x": .object(["type": .string("number")]),
                    "delta_y": .object(["type": .string("number")])
                ],
                required: ["app", "x", "y", "delta_x", "delta_y"]
            )
        ]),
        "press_key": .object([
            "name": .string("press_key"),
            "inputSchema": schema(
                properties: [
                    "app": .object(["type": .string("string")]),
                    "key": .object(["type": .string("string")])
                ],
                required: ["app", "key"]
            )
        ]),
        "type_text": .object([
            "name": .string("type_text"),
            "inputSchema": schema(
                properties: [
                    "app": .object(["type": .string("string")]),
                    "text": .object(["type": .string("string")])
                ],
                required: ["app", "text"]
            )
        ])
    ]
}
