import Foundation

@MainActor enum NativeWindowReadTool {
    static let name = "inspect_native_window"
    static let definition = ToolDefinition(name: name,
        description: "Local-vision read of exact task-admitted app window when AX insufficient. One specific question; interpretation!=independent outcome proof. No new app/input.",
        parameters: .object(["type": .string("object"), "properties": .object([
            "bundle_id": .object(["type": .string("string"), "description": .string("Task-admitted app bundle ID")]),
            "question": .object(["type": .string("string"), "description": .string("Read-only current-window question; ≤1024 UTF8 bytes")])
        ]), "required": .array([.string("bundle_id"), .string("question")]), "additionalProperties": .bool(false)]))
}
