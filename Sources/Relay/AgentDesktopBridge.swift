import Darwin
import Foundation

/// Bridge to Vercel Labs' `agent-desktop` (`vercel-labs/agent-desktop`) native macOS CLI and C FFI (`libagent_desktop_ffi.dylib`).
/// Bundled inside `Relay.app/Contents/MacOS/agent-desktop` and `Relay.app/Contents/Frameworks/libagent_desktop_ffi.dylib`,
/// and updatable anytime via `Scripts/update-agent-desktop.sh` or from Settings → Engine.
nonisolated struct AgentDesktopStatus: Sendable, Equatable {
    var available: Bool
    var version: String
    var target: String
    var ffiLoaded: Bool
    var ffiAbiMajor: Int32
    var binaryPath: String
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool
}

nonisolated struct AgentDesktopEnvelope: Sendable {
    var ok: Bool
    var command: String
    var version: String
    var rawJSON: String
    var snapshotID: String?
    var refCount: Int?
    var formattedSummary: String
    var errorCode: String?
    var errorMessage: String?
    var errorSuggestion: String?
    var retrySafe: Bool

    /// Successful dispatch alone is not proof of the requested value. v1.0.2 can
    /// return ok=true with delivered_unverified when readback is unavailable.
    func verifiesTextValue(_ expected: String) -> Bool {
        guard ok, command == "set-value",
              let bytes = rawJSON.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let payload = envelope["data"] as? [String: Any],
              let disposition = payload["disposition"] as? [String: Any],
              disposition["delivery"] as? String == "delivered_verified",
              let state = payload["post_state"] as? [String: Any],
              let observedValue = state["value"] as? String else { return false }
        return observedValue == expected
    }
}

nonisolated enum AgentDesktopBridge {
    static let expectedFfiAbiMajor: Int32 = 6

    /// Locates the bundled or vendored `agent-desktop` executable.
    static func resolveExecutableURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(execDir.appendingPathComponent("agent-desktop"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agent-desktop"))

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("Vendor/agent-desktop/bin/agent-desktop"))
        candidates.append(cwd.appendingPathComponent("build/Relay.app/Contents/MacOS/agent-desktop"))

        // Also resolve relative to this source file during `swift test`
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent("Vendor/agent-desktop/bin/agent-desktop"))
        candidates.append(repoRoot.appendingPathComponent("build/Relay.app/Contents/MacOS/agent-desktop"))

        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// Locates the bundled or vendored `libagent_desktop_ffi.dylib`.
    static func resolveFfiLibraryURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let frameworksDir = Bundle.main.privateFrameworksURL {
            candidates.append(frameworksDir.appendingPathComponent("libagent_desktop_ffi.dylib"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libagent_desktop_ffi.dylib"))

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("Vendor/agent-desktop/lib/libagent_desktop_ffi.dylib"))
        candidates.append(cwd.appendingPathComponent("build/Relay.app/Contents/Frameworks/libagent_desktop_ffi.dylib"))

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent("Vendor/agent-desktop/lib/libagent_desktop_ffi.dylib"))
        candidates.append(repoRoot.appendingPathComponent("build/Relay.app/Contents/Frameworks/libagent_desktop_ffi.dylib"))

        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// Verifies that `libagent_desktop_ffi.dylib` loads cleanly in-process and matches `AD_ABI_VERSION_MAJOR` (6).
    static func verifyFfiLibrary() -> (loaded: Bool, abiMajor: Int32) {
        guard let dylibURL = resolveFfiLibraryURL() else {
            return (false, 0)
        }
        guard let handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL) else {
            return (false, 0)
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "ad_init") else {
            return (false, 0)
        }
        typealias AdInitFunc = @convention(c) (UInt32) -> Int32
        let adInit = unsafeBitCast(sym, to: AdInitFunc.self)
        let rc = adInit(UInt32(expectedFfiAbiMajor))
        return (rc == 0, expectedFfiAbiMajor)
    }

    /// Dedicated state directory (`AGENT_DESKTOP_HOME`) with mode `0700` so snapshot refmaps stay private to Relay.
    private static func ensurePrivateHomeDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("Relay/agent-desktop", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmpDir = dir.appendingPathComponent("tmp", isDirectory: true)
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
        return dir
    }

    /// Queries the live status, version, FFI ABI check, and permission state of `agent-desktop`.
    static func queryStatus() async -> AgentDesktopStatus {
        let ffi = verifyFfiLibrary()
        guard let binaryURL = resolveExecutableURL() else {
            return AgentDesktopStatus(
                available: false,
                version: "Not installed",
                target: "aarch64",
                ffiLoaded: ffi.loaded,
                ffiAbiMajor: ffi.abiMajor,
                binaryPath: "Unavailable",
                accessibilityGranted: false,
                screenRecordingGranted: false
            )
        }

        let verEnv = try? await runCommand(arguments: ["version"], timeoutSeconds: 4)
        var versionStr = "1.0.2"
        var targetStr = "aarch64"
        if let raw = verEnv?.rawJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let data = obj["data"] as? [String: Any] {
            versionStr = (data["version"] as? String) ?? versionStr
            targetStr = (data["target"] as? String) ?? targetStr
        }

        var axGranted = false
        var screenGranted = false
        if let permEnv = try? await runCommand(arguments: ["permissions"], timeoutSeconds: 4),
           let raw = permEnv.rawJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let data = obj["data"] as? [String: Any] {
            if let ax = data["accessibility"] as? [String: Any] {
                axGranted = (ax["state"] as? String) == "granted"
            }
            if let sr = data["screen_recording"] as? [String: Any] {
                screenGranted = (sr["state"] as? String) == "granted"
            }
        }

        return AgentDesktopStatus(
            available: true,
            version: versionStr,
            target: targetStr,
            ffiLoaded: ffi.loaded,
            ffiAbiMajor: ffi.abiMajor,
            binaryPath: binaryURL.path,
            accessibilityGranted: axGranted,
            screenRecordingGranted: screenGranted
        )
    }

    /// Runs `agent-desktop snapshot` with optional `--skeleton`, `--root @ref`, and `--compact -i` flags.
    static func snapshot(
        app: String,
        windowID: String? = nil,
        rootRef: String? = nil,
        skeleton: Bool = false,
        interactiveOnly: Bool = true,
        sessionID: String? = nil
    ) async throws -> AgentDesktopEnvelope {
        var args = ["snapshot", "--app", app]
        if let windowID, !windowID.isEmpty {
            args.append(contentsOf: ["--window-id", windowID])
        }
        if let rootRef, !rootRef.isEmpty {
            args.append(contentsOf: ["--root", rootRef])
        }
        if skeleton {
            args.append("--skeleton")
        }
        if interactiveOnly {
            args.append("-i")
        }
        args.append("--compact")
        return try await runCommand(arguments: args, timeoutSeconds: 8, sessionID: sessionID)
    }

    /// Runs `agent-desktop find` to locate specific interactive refs by name, role, or text without dumping the full tree.
    static func find(
        app: String,
        query: String? = nil,
        role: String? = nil,
        sessionID: String? = nil
    ) async throws -> AgentDesktopEnvelope {
        var args = ["find", "--app", app]
        if let query, !query.isEmpty {
            args.append(contentsOf: ["--name", query])
        }
        if let role, !role.isEmpty {
            args.append(contentsOf: ["--role", role])
        }
        return try await runCommand(arguments: args, timeoutSeconds: 6, sessionID: sessionID)
    }

    /// Executes an `agent-desktop` ref action (`click`, `set-value`, `select`, `toggle`, `check`, `uncheck`, `expand`, `collapse`, `scroll`).
    static func act(
        command: String,
        ref: String,
        value: String? = nil,
        direction: String? = nil,
        sessionID: String? = nil
    ) async throws -> AgentDesktopEnvelope {
        guard ref.hasPrefix("@"), ref.contains(":e") else {
            throw RelayError.message("agent-desktop ref must be snapshot-qualified (for example @s8f3k2p9:e8).")
        }
        let allowedCommands: Set<String> = [
            "click", "double-click", "right-click",
            "set-value", "type", "clear", "focus",
            "select", "toggle", "check", "uncheck",
            "expand", "collapse", "scroll", "scroll-to"
        ]
        let normalized = command.lowercased()
        guard allowedCommands.contains(normalized) else {
            throw RelayError.message("Unsupported agent-desktop action '\(command)'.")
        }
        var args = [normalized, ref]
        if ["set-value", "type"].contains(normalized), let value {
            args.append(value)
        } else if normalized == "scroll", let direction {
            args.append(contentsOf: ["--direction", direction.lowercased()])
        }
        return try await runCommand(arguments: args, timeoutSeconds: 8, sessionID: sessionID)
    }

    /// Read live geometry using the same private snapshot namespace as the action.
    static func bounds(ref: String, sessionID: String? = nil) async throws -> CGRect? {
        guard ref.hasPrefix("@"), ref.contains(":e") else { return nil }
        let envelope = try await runCommand(arguments: ["get", ref, "--property", "bounds"], timeoutSeconds: 2, sessionID: sessionID)
        return liveBounds(envelope: envelope, ref: ref)
    }

    static func liveBounds(envelope: AgentDesktopEnvelope, ref: String) -> CGRect? {
        guard envelope.ok, envelope.command == "get",
              let object = try? JSONSerialization.jsonObject(with: Data(envelope.rawJSON.utf8)) as? [String: Any],
              let data = object["data"] as? [String: Any],
              data["live"] as? Bool == true, data["property"] as? String == "bounds",
              data["ref"] as? String == ref, let value = data["value"] as? [String: Any],
              let x = value["x"] as? Double, let y = value["y"] as? Double,
              let width = value["width"] as? Double, let height = value["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Runs `Scripts/update-agent-desktop.sh` if running inside the source workspace to pull the latest release from `vercel-labs/agent-desktop`.
    static func updateVendorBinaryIfPossible() async throws -> String {
        let fm = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("Scripts/update-agent-desktop.sh")
        guard fm.isExecutableFile(atPath: scriptURL.path) else {
            throw RelayError.message("Update script not found at \(scriptURL.path).")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path, "latest"]
            process.currentDirectoryURL = repoRoot
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: outStr.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(throwing: RelayError.message("agent-desktop update failed: \(errStr.isEmpty ? outStr : errStr)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Executes the bundled `agent-desktop` CLI and parses its JSON envelope into a compact human + LLM summary.
    static func runCommand(arguments: [String], timeoutSeconds: TimeInterval = 8, sessionID: String? = nil) async throws -> AgentDesktopEnvelope {
        guard let binaryURL = resolveExecutableURL() else {
            throw RelayError.message("Bundled agent-desktop binary is not available. Run ./Scripts/update-agent-desktop.sh.")
        }
        let homeDir = ensurePrivateHomeDirectory()

        var environment = ProcessInfo.processInfo.environment
        environment["AGENT_DESKTOP_HOME"] = homeDir.path
        // Never inherit a harness session/agent/trace into Relay's private namespace.
        environment.removeValue(forKey: "AGENT_DESKTOP_SESSION")
        environment.removeValue(forKey: "AGENT_DESKTOP_AGENT_ID")
        if let sessionID { environment["AGENT_DESKTOP_SESSION"] = sessionID }
        let output = try await AgentDesktopProcessRunner.run(
            executable: binaryURL, arguments: arguments, environment: environment,
            timeoutSeconds: timeoutSeconds
        )
        let rawOut = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawErr = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var envelope = parseEnvelope(rawJSON: rawOut.isEmpty ? rawErr : rawOut, defaultCommand: arguments.first ?? "unknown")
        if output.exitStatus != 0, envelope.ok {
            envelope.ok = false
            envelope.errorCode = "PROCESS_EXIT"
            envelope.errorMessage = "agent-desktop exited unsuccessfully; action effects are uncertain. Observe before retrying."
            envelope.formattedSummary = envelope.errorMessage!
        }
        return envelope
    }

    static func parseEnvelope(rawJSON: String, defaultCommand: String) -> AgentDesktopEnvelope {
        guard let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AgentDesktopEnvelope(
                ok: false,
                command: defaultCommand,
                version: "2.5",
                rawJSON: rawJSON,
                snapshotID: nil,
                refCount: nil,
                formattedSummary: rawJSON,
                errorCode: "PARSE_ERROR",
                errorMessage: rawJSON.isEmpty ? "Empty response from agent-desktop" : rawJSON,
                errorSuggestion: nil,
                retrySafe: false
            )
        }

        let ok = (obj["ok"] as? Bool) ?? false
        let command = (obj["command"] as? String) ?? defaultCommand
        let version = (obj["version"] as? String) ?? "2.5"

        if ok, let payload = obj["data"] as? [String: Any] {
            let snapshotID = payload["snapshot_id"] as? String
            let refCount = payload["ref_count"] as? Int
            let formatted = formatSuccessPayload(command: command, payload: payload, rawJSON: rawJSON)
            return AgentDesktopEnvelope(
                ok: true,
                command: command,
                version: version,
                rawJSON: rawJSON,
                snapshotID: snapshotID,
                refCount: refCount,
                formattedSummary: formatted,
                errorCode: nil,
                errorMessage: nil,
                errorSuggestion: nil,
                retrySafe: false
            )
        } else {
            let errObj = obj["error"] as? [String: Any]
            let code = (errObj?["code"] as? String) ?? "ERROR"
            let message = (errObj?["message"] as? String) ?? rawJSON
            let suggestion = errObj?["suggestion"] as? String
            var retrySafe = false
            if let disp = errObj?["disposition"] as? [String: Any],
               let retry = disp["retry"] as? String {
                retrySafe = (retry == "safe")
            }
            var summary = "[\(code)] \(message)"
            if let suggestion, !suggestion.isEmpty {
                summary += " Suggestion: \(suggestion)"
            }
            return AgentDesktopEnvelope(
                ok: false,
                command: command,
                version: version,
                rawJSON: rawJSON,
                snapshotID: nil,
                refCount: nil,
                formattedSummary: summary,
                errorCode: code,
                errorMessage: message,
                errorSuggestion: suggestion,
                retrySafe: retrySafe
            )
        }
    }

    /// Formats `snapshot` or `find` trees into a compact line-by-line summary of `@snapshot:eN` refs for `Gemma 4 E2B`.
    private static func formatSuccessPayload(command: String, payload: [String: Any], rawJSON: String) -> String {
        if command == "snapshot" {
            let app = (payload["app"] as? String) ?? "App"
            let snapID = (payload["snapshot_id"] as? String) ?? ""
            let refCount = (payload["ref_count"] as? Int) ?? 0
            var lines: [String] = ["agent-desktop snapshot (\(app), snapshot_id=\(snapID), refs=\(refCount)):"]
            if let tree = payload["tree"] as? [String: Any] {
                collectTreeLines(node: tree, depth: 0, into: &lines, limit: 160)
            }
            return lines.joined(separator: "\n")
        } else if command == "find" {
            var lines: [String] = ["agent-desktop find matches:"]
            if let matches = payload["matches"] as? [[String: Any]] {
                for match in matches.prefix(80) {
                    let ref = (match["ref_id"] as? String) ?? ""
                    let role = (match["role"] as? String) ?? "element"
                    let name = (match["name"] as? String) ?? ""
                    let val = (match["value"] as? String) ?? ""
                    lines.append("element_id=\(ref) role=\(role) title=\(name) value=\(val)")
                }
            } else {
                lines.append(rawJSON)
            }
            return lines.joined(separator: "\n")
        }
        return rawJSON
    }

    private static func collectTreeLines(node: [String: Any], depth: Int, into lines: inout [String], limit: Int) {
        guard lines.count < limit else { return }
        let ref = (node["ref_id"] as? String) ?? ""
        let role = (node["role"] as? String) ?? ""
        let name = (node["name"] as? String) ?? ""
        let value = (node["value"] as? String) ?? ""
        let actions = (node["available_actions"] as? [String])?.joined(separator: ",") ?? ""
        let states = (node["states"] as? [String]) ?? []
        let enabled = !states.contains("disabled")

        if !ref.isEmpty {
            var parts: [String] = ["element_id=\(ref)", "role=\(role)"]
            if !name.isEmpty { parts.append("title=\(name)") }
            if !value.isEmpty { parts.append("value=\(value)") }
            if !actions.isEmpty { parts.append("actions=[\(actions)]") }
            parts.append("enabled=\(enabled)")
            lines.append(parts.joined(separator: " "))
        }
        if ref.isEmpty, !name.isEmpty || !value.isEmpty,
           !role.localizedCaseInsensitiveContains("secure"),
           !role.localizedCaseInsensitiveContains("password") {
            lines.append("observed role=\(role) text=\(String((name.isEmpty ? value : name).prefix(1200))) [untrusted]")
        }
        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                collectTreeLines(node: child, depth: depth + 1, into: &lines, limit: limit)
            }
        }
    }
}
