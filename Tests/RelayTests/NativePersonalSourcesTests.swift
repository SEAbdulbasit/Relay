import CoreServices
import Foundation
import Testing
@testable import Relay

@MainActor
struct NativePersonalSourcesTests {
    private func reference(_ kind: NativePersonalSourceKind, _ id: String, form: OSType = OSType(formUniqueID)) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: NativeSourceAppleEvents.fourCC(kind == .notes ? "note" : "mssg")), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(.init(string: id), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
        return try #require(record.coerce(toDescriptorType: DescType(typeObjectSpecifier)))
    }

    private func selection(_ references: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (offset, reference) in references.enumerated() { list.insert(reference, at: offset + 1) }
        return list
    }

    private func item(_ id: String, title: String, sender: String? = nil, text: String) -> NativePersonalSourceItem {
        .init(id: id, title: title, sender: sender, text: text, textLimited: false)
    }

    @Test func notesNeverRequestProtectedTitleOrBody() throws {
        let locked = try reference(.notes, "locked")
        let open = try reference(.notes, "open")
        let list = selection([locked, open])
        var lockRequests: [NativeSourceAppleEvents.Property] = []
        var selectionReads = 0
        let batch = try NativeSourceAppleEvents.readSelected(.notes) { property, reference in
            if property == .selection { selectionReads += 1; return list }
            let id = reference?.forKeyword(AEKeyword(keyAEKeyData))?.stringValue
            if id == "locked" { lockRequests.append(property); return .init(boolean: true) }
            #expect(id == "open")
            switch property {
            case .protected: return .init(boolean: false)
            case .title: return .init(string: " Notes fixture  ")
            case .body: return .init(string: "ملاحظة خاصة بالمثال 🌍\nSecond line")
            default: throw NativeSourceAppleEvents.Failure.unavailableProperty
            }
        }
        #expect(lockRequests == [.protected])
        #expect(selectionReads == 2)
        #expect(batch.skipped == 1)
        #expect(batch.items.map(\.title) == ["Notes fixture"])
        #expect(batch.items.first?.text == "ملاحظة خاصة بالمثال 🌍\nSecond line")
    }

    @Test func mailReadsOnlySelectedBodyAndMetadataWithinItsBudget() throws {
        let message = try reference(.mail, "fixture message")
        let selection = selection([message])
        var requested: [NativeSourceAppleEvents.Property] = []
        let text = String(repeating: "Café 🌍 ", count: 1200)
        let batch = try NativeSourceAppleEvents.readSelected(.mail) { property, reference in
            requested.append(property)
            switch property {
            case .selection: #expect(reference == nil); return selection
            case .title: return .init(string: "Synthetic subject")
            case .sender: return .init(string: "Fixture Sender <fixture@example.invalid>")
            case .body: return .init(string: text)
            default: throw NativeSourceAppleEvents.Failure.unavailableProperty
            }
        }
        #expect(requested == [.selection, .title, .sender, .body, .selection])
        #expect(batch.items.first?.sender == "Fixture Sender <fixture@example.invalid>")
        let result = try #require(batch.items.first)
        #expect(result.text.utf8.count <= 8192)
        #expect(result.textLimited)
        #expect(!result.text.contains("�"))
    }

    @Test func selectionScopeRejectsOversizedForeignAndNonUniqueReferencesBeforeItemReads() throws {
        let tooMany = try (0...NativeSourceAppleEvents.maximumSelection).map { try reference(.notes, String($0)) }
        let foreign = try reference(.mail, "mail ref")
        let nonUnique = try reference(.notes, "ambiguous ordinal", form: OSType(formAbsolutePosition))
        for references in [tooMany, [foreign], [nonUnique]] {
            var itemReads = 0
            #expect(throws: NativeSourceAppleEvents.Failure.self) {
                try NativeSourceAppleEvents.readSelected(.notes) { property, _ in
                    if property != .selection { itemReads += 1 }
                    return selection(references)
                }
            }
            #expect(itemReads == 0)
        }
    }

    @Test func scopeChangeCannotPublishCapturedContent() throws {
        let original = selection([try reference(.mail, "initial")])
        let changed = selection([try reference(.mail, "changed")])
        var selectionReads = 0
        let error = #expect(throws: NativeSourceAppleEvents.Failure.self) {
            try NativeSourceAppleEvents.readSelected(.mail) { property, _ in
                if property == .selection { selectionReads += 1; return selectionReads == 1 ? original : changed }
                return .init(string: "Synthetic fixture text")
            }
        }
        if case .selectionChanged = error {} else { Issue.record("Expected changed selection failure") }
        #expect(selectionReads == 2)
    }

    @Test func captureReadSearchAndForgetAreScopedByApp() async throws {
        var captured: [NativePersonalSourceKind] = []
        var invalidated: [NativePersonalSourceKind] = []
        let notes = item("notes", title: "Notes project", text: "Notes fixture body")
        let mail = item("mail", title: "Mail project", sender: "Fixture Sender", text: "Mail fixture body")
        let sources = NativePersonalSources { kind, prompt in
            #expect(!prompt)
            captured.append(kind)
            return NativePersonalSourceBatch(items: [kind == .notes ? notes : mail], skipped: 0)
        }
        sources.onContextInvalidated = { invalidated.append($0) }
        #expect(throws: RelayError.self) { try sources.read(kind: .notes) }
        await sources.captureSelection(.notes, requestPermission: false)
        await sources.captureSelection(.mail, requestPermission: false)
        #expect(try sources.read(kind: .mail, query: "fixture sender").summary.contains("Mail fixture body"))
        #expect(try !sources.read(kind: .notes).summary.contains("Mail fixture body"))
        #expect(try sources.read(kind: .notes, query: "Fixture Sender").summary.contains("No matching text"))
        #expect(captured == [.notes, .mail])
        await sources.captureSelection(.notes, requestPermission: false)
        sources.forget(.notes)
        #expect(invalidated == [.notes, .notes])
        #expect(throws: RelayError.self) { try sources.read(kind: .notes) }
        #expect(try sources.read(kind: .mail).verified)
    }

    @Test func cancellationCannotPublishASelectionReturnedLate() async throws {
        var finish: CheckedContinuation<Void, Never>?
        let note = item("fixture", title: "Fixture", text: "Late synthetic note")
        let sources = NativePersonalSources { _, _ in
            await withCheckedContinuation { finish = $0 }
            return NativePersonalSourceBatch(items: [note], skipped: 0)
        }
        let capture = Task { await sources.captureSelection(.notes, requestPermission: false) }
        for _ in 0..<1000 where finish == nil { await Task.yield() }
        let completion = try #require(finish)
        sources.cancelCapture()
        completion.resume()
        await capture.value
        #expect(!sources.isCapturing)
        #expect(sources.status(for: .notes).contains("Capture stopped"))
        #expect(throws: RelayError.self) { try sources.read(kind: .notes) }
    }
}
