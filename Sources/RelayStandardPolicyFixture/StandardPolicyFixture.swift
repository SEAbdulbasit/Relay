import AppKit
import Foundation
import PolicyMetadataProcess

/// Standard AppKit controls only. There are deliberately no accessibility
/// overrides for hidden/protected flags or any source/control read methods.
@MainActor final class StandardPolicyFixture: NSObject, NSApplicationDelegate {
    private let scene: String, nonce: UUID, reportURL: URL
    private var window: NSWindow?
    private var monitor: Any?, timer: Timer?
    private var inputEvents: [String: Int] = [:]
    private var lastPointerLocations: [String: [CGFloat]] = [:]
    private var lastNavigationKeyCode: UInt16?
    private var buttonActions = 0, textChanges = 0
    private var fields: [NSTextField] = [], editors: [NSTextView] = []
    private var applicationActivations = 0, applicationResignations = 0
    private var monitorInstalled = false
    private var initialFieldValues: [String] = []
    private var initialEditorValues: [String] = []
    init(scene: String, nonce: UUID, reportURL: URL) {
        self.scene = scene; self.nonce = nonce; self.reportURL = reportURL
    }
    private var isGestureScene: Bool { scene == "control-pointer" || scene == "control-navigation" }
    func installMonitorBeforeStartup() {
        // Install before changing activation policy or ordering our first window. The event is returned
        // unchanged; no global tap, interception or synthetic event is used.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown,
            .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return event
        }
        monitorInstalled = monitor != nil
    }
    private func record(_ event: NSEvent) {
        inputEvents[String(event.type.rawValue), default: 0] += 1
        guard isGestureScene, let window, event.window === window else { return }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            let point = event.locationInWindow
            lastPointerLocations[String(event.type.rawValue)] = [point.x, point.y]
        case .keyDown:
            // Navigation virtual codes only. Character data is never recorded.
            let navigationCodes: Set<UInt16> = [115, 119, 123, 124, 125, 126]
            lastNavigationKeyCode = navigationCodes.contains(event.keyCode) ? event.keyCode : nil
        default:
            break
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let style: NSWindow.StyleMask = isGestureScene ? [.titled] : [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: .init(x: 80, y: 100, width: 640, height: 420),
            styleMask: style, backing: .buffered, defer: false)
        window.title = "Relay standard policy " + nonce.uuidString + " " + scene
        window.identifier = .init("owned-standard-policy-window")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        if isGestureScene {
            let editor: NSTextField?
            if scene == "control-navigation" {
                let field = NSTextField(string: "Owned navigation fixture")
                field.frame = .init(x: 24, y: 340, width: 360, height: 28)
                field.setAccessibilityIdentifier("owned-navigation-field")
                fields = [field]
                window.contentView?.addSubview(field)
                editor = field
            } else {
                let label = NSTextField(labelWithString: "Owned pointer fixture")
                label.frame = .init(x: 24, y: 340, width: 360, height: 28)
                window.contentView?.addSubview(label)
                editor = nil
            }
            start(window, initialResponder: editor)
            return
        }
        let plain = NSTextField(string: ""); plain.identifier = .init("owned-plain-field")
        plain.setAccessibilityIdentifier("owned-plain-field"); plain.placeholderString = "Owned empty field"
        fields.append(plain)
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 560, height: 100))
        editor.setAccessibilityIdentifier("owned-text-view"); editor.string = ""; editors.append(editor)
        let scroller = NSScrollView(); scroller.documentView = editor; scroller.hasVerticalScroller = true
        scroller.heightAnchor.constraint(equalToConstant: 100).isActive = true
        let apply = NSButton(title: "Apply layout", target: self, action: #selector(buttonPressed))
        apply.setAccessibilityIdentifier("owned-apply-button")
        let disabled = NSButton(title: "Disabled option", target: self, action: #selector(buttonPressed)); disabled.isEnabled = false
        disabled.setAccessibilityIdentifier("owned-disabled-button")
        let unrelated = NSButton(title: "Send", target: self, action: #selector(buttonPressed))
        unrelated.setAccessibilityIdentifier("owned-unrelated-send-button")
        var views: [NSView] = [plain, scroller, apply, disabled, unrelated]
        if scene.hasPrefix("control") {
            // Setup data only. The fixture receives no expected input literal,
            // never intercepts an AX setter and never manufactures a write.
            let untouched = NSTextField(string: "Keep unrelated 🧭 exactly")
            untouched.setAccessibilityIdentifier("owned-unrelated-field")
            untouched.isEditable = false; untouched.isSelectable = true
            fields.append(untouched); views.insert(untouched, at: 1)
            if scene == "control-readonly" { plain.isEditable = false; plain.isSelectable = true }
        }
        if scene == "secure" || scene == "control-secure" {
            let secure = NSSecureTextField(string: ""); secure.setAccessibilityIdentifier("owned-secure-field")
            fields.append(secure); views.append(secure)
        }
        if scene == "hidden" {
            let hidden = NSTextField(string: ""); hidden.setAccessibilityIdentifier("owned-hidden-field")
            hidden.isHidden = true; fields.append(hidden); views.append(hidden)
        }
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        }
        start(window, initialResponder: scene.hasPrefix("control") ? plain : nil)
    }
    private func start(_ window: NSWindow, initialResponder: NSTextField?) {
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSControl.textDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: nil)
        self.window = window
        initialFieldValues = fields.map(\.stringValue)
        initialEditorValues = editors.map(\.string)
        window.orderFront(nil) // No activation, click or input posting.
        if let initialResponder {
            // The held harness separately activates this exact owned process
            // BEFORE the task. No reactivation or responder adoption mid-task.
            _ = window.makeFirstResponder(initialResponder)
        }
        writeReport(state: "ready")
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeReport(state: "ready") }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { applicationActivations += 1; writeReport(state: "ready") }
    func applicationDidResignActive(_ notification: Notification) { applicationResignations += 1; writeReport(state: "ready") }
    @objc private func buttonPressed() { buttonActions += 1; writeReport(state: "ready") }
    @objc private func textChanged(_ note: Notification) {
        guard let object = note.object as? NSView,
              fields.contains(where: { $0 === object }) || editors.contains(where: { $0 === object }) else { return }
        textChanges += 1; writeReport(state: "ready")
    }
    private func writeReport(state: String) {
        let currentFields = fields.map(\.stringValue), currentEditors = editors.map(\.string)
        let unchanged = currentFields.count == initialFieldValues.count && currentEditors.count == initialEditorValues.count
            && zip(currentFields, initialFieldValues).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
            && zip(currentEditors, initialEditorValues).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
        let report: [String: Any] = ["nonce": nonce.uuidString, "scene": scene, "pid": ProcessInfo.processInfo.processIdentifier,
            "state": state, "windowNumber": window?.windowNumber ?? -1, "localMonitorInstalledBeforeWindow": monitorInstalled, "activationRequestedByFixture": false,
            "inputEventCounts": inputEvents, "buttonActions": buttonActions, "textChanges": textChanges,
            "ownedEditorValuesUnchanged": unchanged,
            "coverage": "Own AppKit state/counters only; never a replacement for actual accessibility flag support. No field contents are retained."]
        var finalReport = report
        if scene.hasPrefix("control") {
            finalReport["ownedFieldValues"] = currentFields
            finalReport["ownedFieldUTF16"] = currentFields.map { Array($0.utf16).map(Int.init) }
            finalReport["ownedTextViewValues"] = currentEditors
            finalReport["ownedTextViewUTF16"] = currentEditors.map { Array($0.utf16).map(Int.init) }
            if let editor = fields.first?.currentEditor() as? NSTextView {
                let range = editor.selectedRange()
                finalReport["actualFieldEditor"] = ["string": editor.string, "utf16": Array(editor.string.utf16).map(Int.init),
                    "selectionLocation": range.location, "selectionLength": range.length]
            }
            finalReport["applicationActivations"] = applicationActivations
            finalReport["applicationResignations"] = applicationResignations
            finalReport["applicationActive"] = NSApplication.shared.isActive
            finalReport["windowKey"] = window?.isKeyWindow == true
            finalReport["coverage"] = "Only own genuine AppKit values, field editor/caret, notifications and unchanged local events. No accessibility getter/setter overrides; no model or input sender."
        }
        if isGestureScene {
            finalReport["lastPointerLocationsInWindow"] = lastPointerLocations
            if let lastNavigationKeyCode { finalReport["lastNavigationKeyCode"] = lastNavigationKeyCode }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: finalReport, options: [.sortedKeys, .prettyPrinted])
            if data.count > 65_536 {
                finalReport.removeValue(forKey: "ownedFieldValues"); finalReport.removeValue(forKey: "ownedFieldUTF16")
                finalReport.removeValue(forKey: "ownedTextViewValues"); finalReport.removeValue(forKey: "ownedTextViewUTF16")
                finalReport.removeValue(forKey: "actualFieldEditor"); finalReport["oracleOverflow"] = true
                try JSONSerialization.data(withJSONObject: finalReport, options: [.sortedKeys, .prettyPrinted]).write(to: reportURL, options: .atomic)
            } else { try data.write(to: reportURL, options: .atomic) }
        }
        catch { FileHandle.standardError.write(Data("Owned fixture metadata report failed.\n".utf8)) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); writeReport(state: "willTerminate")
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

@main struct StandardPolicyFixtureMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        func argument(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1] }
        guard let scene = argument("--scene"), ["ordinary", "secure", "hidden", "control", "control-secure", "control-readonly", "control-pointer", "control-navigation"].contains(scene),
              let raw = argument("--nonce"), let nonce = UUID(uuidString: raw), let path = argument("--report") else { return }
        let report = URL(fileURLWithPath: path), temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let parent = report.deletingLastPathComponent().resolvingSymlinksInPath()
        guard report.lastPathComponent == "fixture-state.json", parent.deletingLastPathComponent().deletingLastPathComponent() == temporary,
              parent.deletingLastPathComponent().lastPathComponent.hasPrefix("relay-standard-policy-"),
              parent.lastPathComponent.utf8.elementsEqual(nonce.uuidString.utf8) else { return }
        // Early private startup receipt lets the independent supervisor
        // reconcile this exact nonce/PID even if later AppKit setup stalls.
        let starting: [String: Any] = ["nonce": nonce.uuidString, "scene": scene,
            "pid": ProcessInfo.processInfo.processIdentifier, "state": "starting"]
        do { try JSONSerialization.data(withJSONObject: starting, options: .sortedKeys).write(to: report, options: .atomic) }
        catch { return }
        let app = NSApplication.shared
        let delegate = StandardPolicyFixture(scene: scene, nonce: nonce, reportURL: report)
        delegate.installMonitorBeforeStartup()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate; app.run(); withExtendedLifetime(delegate) {}
    }
}
