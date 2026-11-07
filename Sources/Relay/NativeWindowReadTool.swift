import Foundation

@MainActor enum NativeWindowReadTool {
    static let name = "inspect_native_window"
    static let definition = ToolDefinition(name: name,
        description: "Read the exact native window of an app already admitted by this user task, using local vision when AX text is insufficient. Ask one specific question. This is read-only; model interpretation is not independent outcome proof. It cannot admit another app or perform input.",
        parameters: .object(["type": .string("object"), "properties": .object([
            "bundle_id": .object(["type": .string("string"), "description": .string("Original task-admitted app bundle ID")]),
            "question": .object(["type": .string("string"), "description": .string("Specific read-only question about that current window, up to 1024 UTF-8 bytes")])
        ]), "required": .array([.string("bundle_id"), .string("question")]), "additionalProperties": .bool(false)]))
}
