import Foundation

/// Error-only text projection. Never serializes the raw native result or an
/// image/resource block. Provider words remain untrusted tool feedback.
nonisolated enum NativeProviderFailureText {
    static let maximumBytes = 1024

    static func detail(_ result: OwnedNativeComputerUseClient.NativeResult) -> String? {
        guard result.isError else { return nil }
        var parts: [String] = []
        for object in [result.raw.object?["structuredContent"]?.object,
                       result.raw.object?["error"]?.object].compactMap({ $0 }) {
            for key in ["code", "kind", "stage"] {
                if let value = technicalScalar(object[key]) { parts.append(key + "=" + value) }
            }
            if let message = object["message"]?.string { append(message, to: &parts) }
        }
        for block in result.content.prefix(4) {
            guard let object = block.object, object["type"]?.string == "text", let text = object["text"]?.string else { continue }
            append(text, to: &parts)
        }
        let combined = bounded(parts.joined(separator: " | "), bytes: maximumBytes)
        return combined.isEmpty ? nil : combined
    }

    static func textDetail(_ text: String, maximumBytes: Int) -> String {
        var parts: [String] = []
        append(text, to: &parts)
        return bounded(parts.joined(separator: " | "), bytes: maximumBytes)
    }

    private static func append(_ text: String, to parts: inout [String]) {
        var prefix = bounded(text, bytes: 2048)
        // A failed read can still include app state. Its body is source data,
        // not a diagnostic message and is not copied into the failure.
        for marker in ["Computer Use state (CUA App Version:", "<app_state>"] {
            if let range = prefix.range(of: marker) { prefix = String(prefix[..<range.lowerBound]) }
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            // A JSON-looking error is projected only through known message/code
            // fields. Never print a JSON native result, even when malformed.
            guard let data = trimmed.data(using: .utf8), let object = try? JSONDecoder().decode(JSONValue.self, from: data).object else { return }
            if let code = technicalScalar(object["code"]) { parts.append("code=" + code) }
            if let message = object["message"]?.string { appendPlain(message, to: &parts) }
            return
        }
        appendPlain(trimmed, to: &parts)
    }

    private static func appendPlain(_ text: String, to parts: inout [String]) {
        for line in text.split(whereSeparator: \.isNewline).prefix(8) {
            let value = String(line), lower = value.lowercased()
            guard !lower.contains("base64"), !lower.contains("data:image/") else { continue }
            let opaque = value.utf8.count > 160 && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 47, 61].contains($0)
            }
            guard !opaque else { continue }
            let safe = bounded(value, bytes: 384)
            if !safe.isEmpty, !parts.contains(where: { $0.utf8.elementsEqual(safe.utf8) }) { parts.append(safe) }
        }
    }

    static func bounded(_ value: String, bytes: Int) -> String {
        var result = "", count = 0
        for original in value.unicodeScalars {
            let scalar: Unicode.Scalar = original.value == 9 ? " " : original
            guard [10, 13].contains(scalar.value) || !CharacterSet.controlCharacters.contains(scalar) else { continue }
            guard count + scalar.utf8.count <= bytes else { break }
            result.unicodeScalars.append(scalar); count += scalar.utf8.count
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func technicalScalar(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let text: String
        switch value {
        case .string(let value): text = value
        case .number(let number) where number.isFinite: text = String(number)
        default: return nil
        }
        guard !text.isEmpty, text.utf8.count <= 80, text.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [32, 45, 46, 58, 95].contains($0)
        }) else { return nil }
        return text
    }
}

nonisolated struct NativeReadProviderError: LocalizedError, Equatable, Sendable {
    let detail: String
    init(result: OwnedNativeComputerUseClient.NativeResult) {
        detail = NativeProviderFailureText.detail(result) ?? "The native provider returned an error without usable text details."
    }
    var errorDescription: String? {
        "Native window read failed: \(detail) Request fresh state for the intended target or another suitable read-only source. This error grants no input authority; no mutation was retried."
    }
}

nonisolated struct NativeReadTransportError: LocalizedError, Equatable, Sendable {
    let detail: String
    let needsFreshConnection: Bool
    init(_ failure: OwnedNativeComputerUseClient.Failure) {
        switch failure {
        case .closed: detail = "The owned native connection closed."; needsFreshConnection = true
        case .processExited(let code): detail = "The owned native client exited with code \(code)."; needsFreshConnection = true
        case .timeout: detail = "The native connection timed out."; needsFreshConnection = true
        case .requestTimedOut(let method): detail = "Native request \(method.rawValue) timed out."; needsFreshConnection = true
        case .rpc(let code, let message):
            detail = "Native RPC \(code.map(String.init) ?? "unknown code"): " + NativeProviderFailureText.textDetail(message, maximumBytes: 768)
            needsFreshConnection = false
        case .unavailableRuntime: detail = "The signed native runtime is unavailable or changed; check the local runtime."; needsFreshConnection = true
        case .unexpectedServerRequest: detail = "The native connection requested an unsupported client action; it was not approved."; needsFreshConnection = false
        case .unsupportedCatalog: detail = "The native tool catalog is incompatible with this reader."; needsFreshConnection = false
        case .duplicateRequest: detail = "The native request ID was already consumed or changed; it was not replayed."; needsFreshConnection = false
        case .malformedResponse: detail = "The native connection returned a malformed response."; needsFreshConnection = false
        case .outputLimit: detail = "The native response exceeded its bounded output limit."; needsFreshConnection = false
        case .invalidWorkspace: detail = "The owned temporary native workspace is invalid."; needsFreshConnection = false
        case .busy: detail = "A native connection request is already in progress."; needsFreshConnection = false
        }
    }
    var errorDescription: String? {
        detail + " The read did not publish new app state. A fresh model-requested read may reassess the connection; never replay a mutation because a read failed."
    }
}

extension TargetBoundNativeObservation.Failure: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .inactiveSession: "The Mac session is inactive. Resume only in the active session and request fresh native state."
        case .stopped: "Native reading was stopped. No late observation was published; resume with a fresh read."
        case .busy: "A native read is already in progress. Wait for it or stop it before requesting another read."
        case .staleRequest: "The native read request expired. Request fresh state instead of reusing its old references."
        case .ambiguousApplication: "The intended app's process or launch identity is unavailable or ambiguous. Resolve the exact running app before reading it again."
        case .unavailableWindow: "The intended app has no qualified readable native window. Inspect its actual window state or use another suitable read-only source."
        case .changedTarget: "The original process, window, document or browser tab changed during reading. No replacement source was published. Inspect fresh state before continuing."
        case .malformedHeader: "The native response did not provide valid app/window provenance. No state was published; request fresh state or inspect the native runtime error."
        case .wrongApplication: "The native response belongs to another process or application. It was not published. Resolve the intended app and request fresh state."
        case .wrongWindow: "The native response cannot be bound to the exact intended window. It was not published. Inspect the intended window again."
        case .nativeError: "The native provider reported a read error without usable details. Request fresh state or another read-only method; this is not permission to replay an input."
        case .noUsableState: "The native response contained no usable accessibility state or decoded image. Request fresh state or another read-only method; do not guess unseen pixels."
        }
    }
}
