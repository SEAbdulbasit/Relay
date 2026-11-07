import AppKit
import Foundation

/// Deliberately inert AX target. Only the test host's explicit temporary oracle path is written.
@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var secondaryWindow: NSWindow?
    private var secondaryInput: NSTextView?
    private var secondaryScroll: NSScrollView?
    private let input = NSTextField(string: "")
    private let result = NSTextField(labelWithString: "Not applied")
    private var clickCount = 0
    private var draftInput: NSTextView?
    private var draftOracleTimer: Timer?
    private var lastOracleState: OracleState?
    private var delivery: NSPopUpButton?
    private var checkbox: NSButton?
    private var disclosure: NSButton?
    private var checkboxPressCount = 0
    private var disclosurePressCount = 0
    private var radioButtons: [NSButton] = []
    private var radioPressCount = 0
    private var choiceTable: NSTableView?
    private var rowLabels = ["Alpha note", "Beta note — café", "Gamma note"]
    private var rowSelectionCount = 0
    private var rowActivationCount = 0
    private var rowClickCount = 0
    private var revertingSelection = false
    private let environment = ProcessInfo.processInfo.environment
    private var launchToken: String { environment["RELAY_FIXTURE_TOKEN"] ?? fallbackToken }
    private let fallbackToken = UUID().uuidString

    func applicationDidFinishLaunching(_ notification: Notification) {
        let includeDraft = environment["RELAY_FIXTURE_INCLUDE_DRAFT"] == "1"
        let includeSelection = environment["RELAY_FIXTURE_INCLUDE_SELECTION"] == "1"
        let includeBinary = environment["RELAY_FIXTURE_INCLUDE_BINARY_CONTROLS"] == "1"
        let includeChoices = environment["RELAY_FIXTURE_INCLUDE_CHOICES"] == "1"
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: includeChoices ? 600 : includeDraft ? 460 : includeBinary ? 410 : includeSelection ? 360 : 300),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        let screenMarker = environment["RELAY_FIXTURE_SCREEN_MARKER"]
        window.title = screenMarker.map { "Relay Capture Fixture " + $0 } ?? "Relay Accessibility Fixture"
        window.identifier = NSUserInterfaceItemIdentifier("relay.fixture.window")
        window.isReleasedWhenClosed = false
        window.delegate = self
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
        if includeSelection {
            let selection = NSPopUpButton(frame: .zero, pullsDown: false)
            selection.addItems(withTitles: ["Standard", "Express — café", "-Priority"])
            if environment["RELAY_FIXTURE_DUPLICATE_SELECTION"] == "1" {
                selection.menu?.addItem(NSMenuItem(title: "Express — café", action: nil, keyEquivalent: ""))
            }
            if environment["RELAY_FIXTURE_DISABLED_SELECTION"] == "1" {
                selection.autoenablesItems = false
                selection.item(at: 1)?.isEnabled = false
            }
            selection.setAccessibilityLabel("Fixture delivery method")
            selection.setAccessibilityIdentifier("relay.fixture.delivery")
            selection.target = self
            selection.action = #selector(writeOracle)
            delivery = selection
            controls.append(selection)
        }
        if includeBinary {
            let checkbox = NSButton(checkboxWithTitle: environment["RELAY_FIXTURE_BINARY_CONSEQUENTIAL"] == "1" ? "Disable security" : "Show fixture labels",
                                    target: self, action: #selector(changeCheckbox))
            checkbox.setAccessibilityIdentifier("relay.fixture.checkbox")
            checkbox.allowsMixedState = environment["RELAY_FIXTURE_BINARY_MIXED"] == "1"
            checkbox.state = checkbox.allowsMixedState ? .mixed : .off
            checkbox.isEnabled = environment["RELAY_FIXTURE_BINARY_DISABLED"] != "1"
            self.checkbox = checkbox
            controls.append(checkbox)
            let disclosure = NSButton(title: "Fixture details", target: self, action: #selector(changeDisclosure))
            disclosure.bezelStyle = .disclosure
            disclosure.setButtonType(.onOff)
            disclosure.setAccessibilityLabel("Fixture details")
            disclosure.setAccessibilityIdentifier("relay.fixture.disclosure")
            self.disclosure = disclosure
            controls.append(disclosure)
        }
        if includeChoices {
            controls.append(makeRadioChoices())
            let table = makeChoiceTable()
            controls.append(table)
            table.heightAnchor.constraint(equalToConstant: 130).isActive = true
            table.widthAnchor.constraint(equalToConstant: 500).isActive = true
            let change = NSButton(title: "Change fixture choice labels", target: self, action: #selector(changeChoiceLabels))
            change.setAccessibilityIdentifier("relay.fixture.changeChoices")
            controls.append(change)
        }
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
        if environment["RELAY_FIXTURE_INCLUDE_SECOND_WINDOW"] == "1" { makeSecondaryWindow() }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let draftInput {
            window.makeFirstResponder(draftInput)
            draftInput.setSelectedRange(NSRange(location: (draftInput.string as NSString).length, length: 0))
        }
        // Poll the fixture's own state independently of AX and keyboard notifications.
        if (draftInput != nil || secondaryInput != nil), environment["RELAY_FIXTURE_STATE_PATH"] != nil {
            draftOracleTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self,
                                                     selector: #selector(writeOracle), userInfo: nil, repeats: true)
        }
        writeOracle()
        if let attachmentDirectory = environment["RELAY_FIXTURE_ATTACHMENT_DIRECTORY"] {
            openAttachmentFixture(directory: attachmentDirectory)
        }
    }

    private func openAttachmentFixture(directory: String) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            if response == .OK {
                let marker = URL(fileURLWithPath: directory).appendingPathComponent("file-was-chosen")
                try? Data().write(to: marker)
            }
        }
    }

    private func makeSecondaryWindow() {
        let frame = window.frame.offsetBy(dx: 80, dy: -60)
        let secondary = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        secondary.title = "Relay Fixture Second Window"
        secondary.delegate = self
        secondary.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        scroll.setAccessibilityIdentifier("relay.fixture.secondary.scroll")
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        if let text = scroll.documentView as? NSTextView {
            text.setAccessibilityIdentifier("relay.fixture.secondary.input")
            text.setAccessibilityLabel("Secondary fixture multiline input")
            text.isRichText = false
            secondaryInput = text
        }
        secondary.contentView = scroll
        secondaryWindow = secondary
        secondaryScroll = scroll
        secondary.orderFront(nil)
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

    private func makeRadioChoices() -> NSStackView {
        var titles = ["Compact", "Comfortable — café", "Expanded"]
        if environment["RELAY_FIXTURE_CHOICE_DUPLICATE"] == "1" { titles[2] = titles[1] }
        if environment["RELAY_FIXTURE_CHOICE_CONSEQUENTIAL"] == "1" { titles[1] = "Disable security" }
        radioButtons = titles.enumerated().map { index, title in
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(selectRadio(_:)))
            button.tag = index
            button.state = index == 0 ? .on : .off
            button.isEnabled = !(index == 1 && environment["RELAY_FIXTURE_CHOICE_DISABLED"] == "1")
            button.setAccessibilityIdentifier("relay.fixture.radio.\(index)")
            return button
        }
        let group = NSStackView(views: radioButtons)
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        group.setAccessibilityElement(true)
        group.setAccessibilityRole(.radioGroup)
        group.setAccessibilityLabel("Fixture layout choice")
        group.setAccessibilityIdentifier("relay.fixture.radios")
        return group
    }

    private func makeChoiceTable() -> NSScrollView {
        if environment["RELAY_FIXTURE_ROW_DUPLICATE"] == "1" { rowLabels[2] = rowLabels[1] }
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fixtureName"))
        column.width = 480
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 28
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickRow)
        table.doubleAction = #selector(activateRow)
        table.setAccessibilityLabel("Fixture notes")
        table.setAccessibilityIdentifier("relay.fixture.table")
        choiceTable = table
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        rowSelectionCount = 0
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowLabels.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: rowLabels[row])
        label.isEnabled = !(row == 1 && environment["RELAY_FIXTURE_ROW_DISABLED"] == "1")
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        view.setAccessibilityIdentifier("relay.fixture.row.\(row)")
        view.setAccessibilityEnabled(!(row == 1 && environment["RELAY_FIXTURE_ROW_DISABLED"] == "1"))
        return view
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !(row == 1 && environment["RELAY_FIXTURE_ROW_DISABLED"] == "1")
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !revertingSelection else { return }
        rowSelectionCount += 1
        if environment["RELAY_FIXTURE_ROW_REVERT"] == "1", choiceTable?.selectedRow != 0 {
            revertingSelection = true
            choiceTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            revertingSelection = false
        }
        writeOracle()
    }
    @objc private func selectRadio(_ sender: NSButton) {
        radioPressCount += 1
        let selection = environment["RELAY_FIXTURE_CHOICE_REVERT"] == "1" ? 0 : sender.tag
        for button in radioButtons { button.state = button.tag == selection ? .on : .off }
        writeOracle()
    }
    @objc private func clickRow() { rowClickCount += 1; writeOracle() }
    @objc private func activateRow() { rowActivationCount += 1; writeOracle() }
    @objc private func changeChoiceLabels() {
        radioButtons[1].title = "Changed radio label"
        rowLabels[1] = "Changed row content"
        choiceTable?.reloadData()
        writeOracle()
    }

    @objc private func applyInput() {
        clickCount += 1
        result.stringValue = input.stringValue
        writeOracle()
    }

    @objc private func changeCheckbox() {
        checkboxPressCount += 1
        if environment["RELAY_FIXTURE_BINARY_REVERT"] == "1" { checkbox?.state = .off }
        writeOracle()
    }

    @objc private func changeDisclosure() {
        disclosurePressCount += 1
        writeOracle()
    }

    func controlTextDidChange(_ notification: Notification) { writeOracle() }
    func windowDidBecomeKey(_ notification: Notification) { writeOracle() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { draftOracleTimer?.invalidate() }

    @objc private func writeOracle() {
        guard let path = environment["RELAY_FIXTURE_STATE_PATH"], path.hasPrefix("/"), !path.contains("\0") else { return }
        let draft = draftInput.map {
            DraftState(text: $0.string, focused: window.isKeyWindow && window.firstResponder === $0,
                       selectionLocation: $0.selectedRange().location, selectionLength: $0.selectedRange().length)
        }
        let state = OracleState(input: input.stringValue, result: result.stringValue,
                                clickCount: clickCount, launchToken: launchToken, draft: draft,
                                secondaryInput: secondaryInput?.string, focusedWindow: NSApplication.shared.keyWindow?.title,
                                secondaryScrollOffset: secondaryScroll.map { $0.contentView.bounds.minY }, delivery: delivery?.titleOfSelectedItem,
                                checkboxValue: checkbox.map { $0.state.rawValue }, checkboxPressCount: checkboxPressCount,
                                disclosureValue: disclosure.map { $0.state.rawValue }, disclosurePressCount: disclosurePressCount,
                                radioSelection: radioButtons.first(where: { $0.state == .on })?.tag, radioPressCount: radioPressCount,
                                selectedRow: choiceTable?.selectedRow, rowSelectionCount: rowSelectionCount,
                                rowActivationCount: rowActivationCount, rowClickCount: rowClickCount,
                                rowLabels: choiceTable == nil ? nil : rowLabels)
        if state == lastOracleState { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            lastOracleState = state
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
        let secondaryInput: String?
        let focusedWindow: String?
        let secondaryScrollOffset: Double?
        let delivery: String?
        let checkboxValue: Int?
        let checkboxPressCount: Int
        let disclosureValue: Int?
        let disclosurePressCount: Int
        let radioSelection: Int?
        let radioPressCount: Int
        let selectedRow: Int?
        let rowSelectionCount: Int
        let rowActivationCount: Int
        let rowClickCount: Int
        let rowLabels: [String]?
    }
}

let application = NSApplication.shared
let delegate = FixtureDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
