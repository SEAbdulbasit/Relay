import Foundation

// This adapter requires the actual Relay capture capability. It is deliberately
// excluded from the tiny transport-only harness rather than replaced by a stub.
extension LMStudioVisionAttachment {
    @MainActor static func prepare(_ input: NativeVisionPlanningInput) throws -> Self {
        try input.validate()
        return Self(jpeg: input.frame.jpeg, annotation: input.frame.annotation, validate: { try input.validate() })
    }
}
