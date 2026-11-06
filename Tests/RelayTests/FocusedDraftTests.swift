import Foundation
import Testing
@testable import Relay

struct FocusedDraftTests {
    @Test func aCleanSingleTapCanOpenSidekickButASecondCleanTapIsDistinct() {
        var gesture = RightCommandDoubleTap()
        let down = gesture.recognize(rightCommand: true, commandOnly: true, down: true, at: 10.00, secondsSinceOrdinaryInput: 1)
        let first = gesture.recognize(rightCommand: true, commandOnly: true, down: false, at: 10.08, secondsSinceOrdinaryInput: 1)
        let nextDown = gesture.recognize(rightCommand: true, commandOnly: true, down: true, at: 10.19, secondsSinceOrdinaryInput: 1)
        let second = gesture.recognize(rightCommand: true, commandOnly: true, down: false, at: 10.27, secondsSinceOrdinaryInput: 1)
        #expect([down, first, nextDown, second] == [.ignored, .singleCandidate, .ignored, .double])
    }

    @Test func twoDeliberateRightCommandTapsTriggerOnce() {
        var gesture = RightCommandDoubleTap()
        let presses = [(true, 1.00), (false, 1.08), (true, 1.18), (false, 1.25), (false, 1.26)]
        let triggered = presses.map { down, time in
            gesture.consume(rightCommand: true, commandOnly: true, down: down, at: time, secondsSinceOrdinaryInput: 1)
        }
        #expect(triggered == [false, false, false, true, false])
    }

    @Test func commandShortcutsLongHoldsAndMouseInputDoNotDraft() {
        for (release, timeSinceInput, isRight, onlyCommand) in [
            (1.20, 0.03, true, true), // a Command keyboard shortcut or click
            (1.20, 1.00, false, true), // left Command
            (1.20, 1.00, true, false), // other modifier held
            (1.55, 1.00, true, true), // held rather than tapped
            (1.40, 0.28, true, true), // click between taps
            (1.70, 1.00, true, true) // second tap too late
        ] {
            var gesture = RightCommandDoubleTap()
            _ = gesture.consume(rightCommand: true, commandOnly: true, down: true, at: 1, secondsSinceOrdinaryInput: 1)
            _ = gesture.consume(rightCommand: true, commandOnly: true, down: false, at: 1.05, secondsSinceOrdinaryInput: 1)
            let secondPress = release == 1.70 ? 1.64 : 1.13
            _ = gesture.consume(rightCommand: true, commandOnly: true, down: true, at: secondPress, secondsSinceOrdinaryInput: 1)
            let triggered = gesture.consume(rightCommand: isRight, commandOnly: onlyCommand, down: false,
                                            at: release, secondsSinceOrdinaryInput: timeSinceInput)
            #expect(!triggered)
        }
    }

    @Test func insertionPreservesExistingUnicodeAndRejectsSelectionOrMalformedDraft() throws {
        let original = "مرحبا 🌍"
        try FocusedDraftText.validateEditor(value: original, caret: CFRange(location: original.utf16.count, length: 0))
        #expect(throws: (any Error).self) {
            try FocusedDraftText.validateEditor(value: original, caret: CFRange(location: 0, length: 2))
        }
        #expect(throws: (any Error).self) {
            try FocusedDraftText.validateEditor(value: original, caret: CFRange(location: 0, length: 0))
        }
        let result = try FocusedDraftText.insertion("  شكرًا!  ", into: original)
        #expect(result.expected == original + "\n\nشكرًا!")
        #expect(result.text == "\n\nشكرًا!")
        let joined = "👩‍💻 \u{200F}مرحبا"
        #expect(try FocusedDraftText.insertion(joined, into: "").expected == joined)
        for value in [" ", "\u{001B}send", String(repeating: "🌍", count: 501), "```text\nhi\n```"] {
            #expect(throws: (any Error).self) { try FocusedDraftText.insertion(value, into: original) }
        }
    }

    @Test func emptyContextRefusesToInventAReply() throws {
        #expect(throws: (any Error).self) { try FocusedDraftText.messages(editorText: "", thread: [], style: "") }
        let messages = try FocusedDraftText.messages(editorText: "", thread: ["How are you?"], style: "Brief")
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages[1].content.contains("How are you?"))
        #expect(!messages[0].content.contains("How are you?"))
    }
}
