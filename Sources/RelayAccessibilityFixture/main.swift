import AppKit
import Foundation

/// Deliberately inert AX target. Only the test host's explicit temporary oracle path is written.
@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private let input = NSTextField(string: "")
    private let result = NSTextField(labelWithString: "Not applied")
    private var clickCount = 0
    private var draftInput: NSTextView?
    private var draftOracleTimer: Timer?
    private var lastOracleState: OracleState?
    private let environment = ProcessInfo.processInfo.environment
    private var launchToken: String { environment["RELAY_FIXTURE_TOKEN"] ?? fallbackToken }
    private let fallbackToken = UUID().uuidString

    func applicationDidFinishLaunching(_ notification: Notification) {
        let includeDraft = environment["RELAY_FIXTURE_INCLUDE_DRAFT"] == "1"
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: includeDraft ? 460 : 300),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        let screenMarker = environment["RELAY_FIXTURE_SCREEN_MARKER"]
        window.title = screenMarker.map { "Relay Capture Fixture " + $0 } ?? "Relay Accessibility Fixture"
        window.identifier = NSUserInterfaceItemIdentifier("relay.fixture.window")
        window.isReleasedWhenClosed = false
        let content = NSView()
        window.contentView = content

        let heading = NSTextField(labelWithString: "Harmless accessibility test controls")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let inputLabel = NSTextField(labelWithString: "Fixture input")
        input.identifier = NSUserInterfaceItemIdentifier("relay.fixture.input")
        input.setAccessibilityIdentifier("relay.fixture.input")
        input.setAccessibilityLabel("Fixture input")
        input.placeholderString = "Type test text"
        input.delegate = self

        let apply = NSButton(title: "Apply", target: self, action: #selector(applyInput))
        apply.bezelStyle = .rounded
        apply.identifier = NSUserInterfaceItemIdentifier("relay.fixture.apply")
        apply.setAccessibilityIdentifier("relay.fixture.apply")
        let disabled = NSButton(title: "Disabled action", target: nil, action: nil)
        disabled.isEnabled = false
        disabled.identifier = NSUserInterfaceItemIdentifier("relay.fixture.disabled")
        disabled.setAccessibilityIdentifier("relay.fixture.disabled")
        let buttons = NSStackView(views: [apply, disabled])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        result.identifier = NSUserInterfaceItemIdentifier("relay.fixture.result")
        result.setAccessibilityIdentifier("relay.fixture.result")
        result.setAccessibilityLabel("Fixture result")
        result.isSelectable = true
        result.lineBreakMode = .byTruncatingTail
        let token = NSTextField(labelWithString: launchToken)
        token.identifier = NSUserInterfaceItemIdentifier("relay.fixture.token")
        token.setAccessibilityIdentifier("relay.fixture.token")
        token.setAccessibilityLabel("Fixture launch token")
        token.font = .monospacedSystemFont(ofSize: 10, weight: .regular)

        let secret = NSSecureTextField(string: "fixture-dummy-secret")
        secret.identifier = NSUserInterfaceItemIdentifier("relay.fixture.secret")
        secret.setAccessibilityIdentifier("relay.fixture.secret")
        secret.setAccessibilityLabel("Dummy secure field")
        secret.isEditable = true

        let includeSecure = environment["RELAY_FIXTURE_INCLUDE_SECURE"] == "1"
        var controls: [NSView] = [heading, inputLabel, input, buttons, result, token]
        if let screenMarker {
            let marker = NSTextField(labelWithString: "RELAY SCREEN CHECK " + screenMarker)
            marker.font = .monospacedSystemFont(ofSize: 28, weight: .bold)
            controls.append(marker)
        }
        if includeSecure { controls.append(secret) }
        let draftScroll = includeDraft ? makeDraftControl() : nil
        if let draftScroll {
            controls.append(NSTextField(labelWithString: "Fixture multiline draft"))
            controls.append(draftScroll)
        }
        let stack = NSStackView(views: controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor),
            result.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        if includeSecure { secret.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if let draftScroll {
            NSLayoutConstraint.activate([
                draftScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                draftScroll.heightAnchor.constraint(equalToConstant: 110)
            ])
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let draftInput {
            window.makeFirstResponder(draftInput)
            draftInput.setSelectedRange(NSRange(location: (draftInput.string as NSString).length, length: 0))
            // Poll the fixture's own state independently of AX and keyboard notifications.
            // Only write on a change, including when another control takes focus.
            if environment["RELAY_FIXTURE_STATE_PATH"] != nil {
                draftOracleTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self,
                                                         selector: #selector(writeOracle), userInfo: nil, repeats: true)
            }
        }
        writeOracle()
    }

    private func makeDraftControl() -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.identifier = NSUserInterfaceItemIdentifier("relay.fixture.draft")
        textView.setAccessibilityIdentifier("relay.fixture.draft")
        textView.setAccessibilityLabel("Fixture multiline draft")
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = "Existing draft — café 🌍\nKeep this second line."
        draftInput = textView
        return scroll
    }

    @objc private func applyInput() {
        clickCount += 1
        result.stringValue = input.stringValue
        writeOracle()
    }

    func controlTextDidChange(_ notification: Notification) { writeOracle() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { draftOracleTimer?.invalidate() }

    @objc private func writeOracle() {
        guard let path = environment["RELAY_FIXTURE_STATE_PATH"], path.hasPrefix("/"), !path.contains("\0") else { return }
        let draft = draftInput.map {
            DraftState(text: $0.string, focused: window.isKeyWindow && window.firstResponder === $0,
                       selectionLocation: $0.selectedRange().location, selectionLength: $0.selectedRange().length)
        }
        let state = OracleState(input: input.stringValue, result: result.stringValue,
                                clickCount: clickCount, launchToken: launchToken, draft: draft)
        if draft != nil, state == lastOracleState { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            if draft != nil { lastOracleState = state }
        } catch {
            // Missing oracle is a test failure; never invent successful application state.
            fputs("Fixture oracle write failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private struct DraftState: Encodable, Equatable {
        let text: String
        let focused: Bool
        let selectionLocation: Int
        let selectionLength: Int
    }

    private struct OracleState: Encodable, Equatable {
        let input: String
        let result: String
        let clickCount: Int
        let launchToken: String
        let draft: DraftState?
    }
}

let application = NSApplication.shared
let delegate = FixtureDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
