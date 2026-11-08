import Foundation

/// Ignored candidate. These finite schemas are not registered or dispatched by
/// active Relay. A decoded proposal is data, never an authorization capability.
@MainActor enum NativeWindowControlTools {
    static let outerName = "control_native_window"
    static let observeName = "native_observation"
    static let pointerName = "native_pointer"
    static let keyName = "native_key"
    static let textName = "native_type_unsent"

    static let outerDefinition = definition(outerName,
        "Perform one ordinary interface step in a task-admitted app through local vision. Scope and dedicated workflows remain enforced. Ambiguous gestures need exact local review; dispatch alone is not verified completion. A step may return an unverified no-input report.",
        ["bundle_id": string("Original task-admitted app bundle ID"),
         "instruction": string("One ordinary step within the original user task, at most 1024 UTF-8 bytes")],
        required: ["bundle_id", "instruction"])

    static let visualDefinitions = [
        definition(observeName, "Refresh only the original window, or report that this step appears satisfied, unavailable or indeterminate. Reports are unverified data, never goal proof or authority. No input.",
            ["observation_id": string("Current observation ID"), "image_id": string("Attached original image ID"),
             "disposition": enumeration(["refresh", "appears_satisfied", "unavailable", "cannot_determine"]),
             "detail": string("Omit for refresh; terminal reports need 1 to 512 UTF-8 bytes of untrusted printable detail")],
            required: ["observation_id", "image_id", "disposition"]),
        definition(pointerName, "Propose one ordinary click or straight drag in the attached image. This is not permission to act.",
            ["observation_id": string("Current observation ID"), "image_id": string("Attached image ID"),
             "kind": enumeration(["click", "drag"]), "x": integer("Start x pixel"), "y": integer("Start y pixel"),
             "end_x": integer("Drag end x pixel; omit for click"), "end_y": integer("Drag end y pixel; omit for click"),
             "intended_effect": string("Ordinary intended effect; untrusted proposal, not authority")],
            required: ["observation_id", "image_id", "kind", "x", "y", "intended_effect"]),
        definition(keyName, "Propose one navigation key in the original focused control. No Return, modifiers or shortcuts.",
            ["observation_id": string("Current observation ID"), "key": enumeration(NativeControlKey.allCases.map(\.rawValue)),
             "intended_effect": string("Ordinary intended effect; not authority")],
            required: ["observation_id", "key", "intended_effect"]),
        definition(textName, "Propose literal unsent text in the original focused editor through qualified AX insertion. No keyboard fallback.",
            ["observation_id": string("Current observation ID"), "text": string("Exact single-paragraph literal; at most 4096 UTF-8 bytes"),
             "intended_effect": string("Ordinary intended effect; not authority")],
            required: ["observation_id", "text", "intended_effect"])
    ]

    enum Proposal {
        case observeOriginal
        case report(NativeObservationReport)
        case input(NativeControlSession.Action, intendedEffect: String)
    }

    static func requestedStep(_ call: ToolCall) throws -> (bundleID: String, instruction: String) {
        try ToolPolicy.validate(call, against: [outerDefinition])
        guard let bundle = call.arguments["bundle_id"]?.string, !bundle.isEmpty, bundle.utf8.count <= 255,
              bundle.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              let instruction = call.arguments["instruction"]?.string, instruction.utf8.count <= 1024,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !instruction.contains("\0") else {
            throw RelayError.message("Choose one app selector and a bounded ordinary step; no scope was granted.")
        }
        return (bundle, instruction)
    }

    /// No identity is minted here. The task owner must attach the journal's
    /// stable accepted-reply capability and exact original call ID afterward.
    static func decode(_ reply: ModelReply, observationID: UUID, frame: NativeVisionFrame) throws -> (ToolCall, Proposal) {
        guard reply.toolCalls.count == 1, let call = reply.toolCalls.first else {
            throw RelayError.message("The visual phase must propose exactly one finite operation; nothing was dispatched.")
        }
        try ToolPolicy.validate(call, against: visualDefinitions)
        guard call.arguments["observation_id"]?.string?.utf8.elementsEqual(observationID.uuidString.utf8) == true,
              frame.observationID == observationID else {
            throw RelayError.message("The visual proposal uses an old or unknown observation; nothing was dispatched.")
        }
        if call.name == observeName {
            guard call.arguments["image_id"]?.string?.utf8.elementsEqual(frame.id.uuidString.utf8) == true,
                  let disposition = call.arguments["disposition"]?.string else {
                throw RelayError.message("The observation disposition must identify its current original image; no input was requested.")
            }
            if disposition == "refresh" {
                guard call.arguments["detail"] == nil else { throw RelayError.message("A refresh cannot include report detail; no input was requested.") }
                return (call, .observeOriginal)
            }
            guard let kind = NativeObservationReport.Kind(rawValue: disposition), let detail = call.arguments["detail"]?.string else {
                throw RelayError.message("Choose one closed observation report with bounded detail; no input was requested.")
            }
            return (call, .report(try NativeObservationReport(kind: kind, detail: detail)))
        }
        guard let effect = call.arguments["intended_effect"]?.string,
              !effect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              effect.utf8.count <= 512, !effect.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
            throw RelayError.message("A bounded ordinary effect description is required; it grants no authority.")
        }
        let action: NativeControlSession.Action
        switch call.name {
        case pointerName:
            guard call.arguments["image_id"]?.string?.utf8.elementsEqual(frame.id.uuidString.utf8) == true,
                  let kind = call.arguments["kind"]?.string else {
                throw RelayError.message("The pointer proposal must identify the attached current image.")
            }
            let start = try point(x: "x", y: "y", call: call, frame: frame)
            switch kind {
            case "click":
                guard call.arguments["end_x"] == nil, call.arguments["end_y"] == nil else {
                    throw RelayError.message("A click cannot contain drag coordinates.")
                }
                action = .click(image: frame.id, point: start)
            case "drag":
                let end = try point(x: "end_x", y: "end_y", call: call, frame: frame)
                guard start != end else { throw RelayError.message("A drag needs distinct start and end pixels.") }
                action = .drag(image: frame.id, from: start, to: end)
            default: throw RelayError.message("Only a finite click or straight drag is supported.")
            }
        case keyName:
            guard let raw = call.arguments["key"]?.string, let key = NativeControlKey(rawValue: raw) else {
                throw RelayError.message("Only the six advertised navigation keys are supported.")
            }
            action = .key(key)
        case textName:
            guard let text = call.arguments["text"]?.string, NativeControlSession.validUnsentText(text) else {
                throw RelayError.message("Unsent text must be a bounded literal paragraph without control characters or submission keys.")
            }
            action = .typeUnsentText(text)
        default: throw RelayError.message("Unsupported visual operation; nothing was dispatched.")
        }
        return (call, .input(action, intendedEffect: effect))
    }

    private static func point(x: String, y: String, call: ToolCall, frame: NativeVisionFrame) throws -> NativeVisionFrame.PixelPoint {
        guard case .number(let xValue) = call.arguments[x], case .number(let yValue) = call.arguments[y],
              xValue.isFinite, yValue.isFinite, xValue.rounded() == xValue, yValue.rounded() == yValue else {
            throw RelayError.message("Pointer coordinates must be finite integer pixels in the attached image.")
        }
        let point = NativeVisionFrame.PixelPoint(x: xValue, y: yValue)
        _ = try frame.nativePoint(fromPrepared: point)
        return point
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
    private static func enumeration(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }
    private static func definition(_ name: String, _ description: String, _ properties: [String: JSONValue], required: [String]) -> ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: .object(["type": .string("object"),
            "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)]))
    }
}
