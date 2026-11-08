import Foundation
import Testing
@testable import Relay

@MainActor @Suite struct NativeTaskControlBatchTests {
    private var visual: ToolCall { .init(name: NativeWindowControlTools.outerName,
        arguments: ["bundle_id": .string("test.admitted"), "instruction": .string("One ordinary step")]) }
    @Test func anOuterVisualStepAndAnotherPotentialMutationAreRejectedBeforeEitherDispatches() {
        for next in [visual, ToolCall(name: "set_value", arguments: ["element_id": .string("old")]),
                     ToolCall(name: "press_control", arguments: ["element_id": .string("old")])] {
            #expect(throws: ModelProtocolError.self) { try DesktopActionBatch.validate([visual, next]) }
        }
    }
    @Test func visualInvalidationPreventsLaterScopedReadButAllowsIndependentFreshInspection() throws {
        #expect(DesktopActionBatch.invalidatesReferences(visual))
        let scoped = ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.admitted"), "window_id": .string("old-window")])
        #expect(throws: ModelProtocolError.self) { try DesktopActionBatch.validate([visual, scoped]) }
        let fresh = ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.admitted")])
        try DesktopActionBatch.validate([visual, fresh])
        try DesktopActionBatch.validate([fresh, visual])
    }
}
