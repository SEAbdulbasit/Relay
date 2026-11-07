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

    private func capturedNote(_ id: String = "pinned", text: String = "Initial fixture text") throws -> NativePersonalSourceBatch {
        let list = selection([try reference(.notes, id)])
        return try NativeSourceAppleEvents.readSelected(.notes, application: .init(pid: 42, launchedAt: .distantPast)) { property, _ in
            switch property {
            case .selection: return list
            case .protected: return .init(boolean: false)
            case .title: return .init(string: "Pinned fixture")
            case .body: return .init(string: text)
            default: throw NativeSourceAppleEvents.Failure.unavailableProperty
            }
        }
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

    @Test func mailReadsOnlySelectedBodyAndMetadataWithinItsBudget() async throws {
        let message = try reference(.mail, "fixture message")
        let selection = selection([message])
        var requested: [NativeSourceAppleEvents.Property] = []
        let text = String(repeating: "Café 🌍 ", count: 1200)
        let sentAt = Date(timeIntervalSince1970: 1_794_000_000)
        let batch = try NativeSourceAppleEvents.readSelected(.mail) { property, reference in
            requested.append(property)
            switch property {
            case .selection: #expect(reference == nil); return selection
            case .title: return .init(string: "Synthetic subject")
            case .sender: return .init(string: "Fixture Sender <fixture@example.invalid>")
            case .body: return .init(string: text)
            case .sentAt: return .init(date: sentAt)
            case .receivedAt: throw NativeSourceAppleEvents.Failure.unavailableProperty
            default: throw NativeSourceAppleEvents.Failure.unavailableProperty
            }
        }
        #expect(requested == [.selection, .title, .sender, .body, .sentAt, .receivedAt, .selection])
        #expect(NativeSourceAppleEvents.Property.sentAt.code(for: .mail) == NativeSourceAppleEvents.fourCC("drcv"))
        #expect(NativeSourceAppleEvents.Property.receivedAt.code(for: .mail) == NativeSourceAppleEvents.fourCC("rdrc"))
        #expect(batch.items.first?.sender == "Fixture Sender <fixture@example.invalid>")
        let result = try #require(batch.items.first)
        #expect(result.sentAt == sentAt)
        #expect(result.receivedAt == nil)
        #expect(result.text.utf8.count <= 8192)
        #expect(result.textLimited)
        #expect(!result.text.contains("�"))

        let sources = NativePersonalSources { _, _ in batch }
        await sources.captureSelection(.mail, requestPermission: false)
        let read = try sources.read(kind: .mail, query: String(sentAt.ISO8601Format().prefix(10)))
        #expect(read.summary.contains("Sent: \(sentAt.ISO8601Format())"))
        #expect(!read.summary.contains("Received:"))
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

    @Test func refreshReadsOnlyPinnedReferencesAndDefersDuringOtherWork() async throws {
        let original = try capturedNote()
        let scope = try #require(original.scope)
        var captures = 0
        var refreshes = 0
        var busy = true
        var invalidations = 0
        let sources = NativePersonalSources(capture: { _, prompt in
            #expect(!prompt)
            captures += 1
            return original
        }, refresh: { received in
            refreshes += 1
            #expect(received == scope)
            return try NativeSourceAppleEvents.readCaptured(received) { property, reference in
                #expect(property != .selection)
                #expect(reference?.forKeyword(AEKeyword(keyAEKeyData))?.stringValue == "pinned")
                switch property {
                case .protected: return .init(boolean: false)
                case .title: return .init(string: "Pinned fixture")
                case .body: return .init(string: "Updated fixture text")
                default: throw NativeSourceAppleEvents.Failure.unavailableProperty
                }
            }
        }, automaticRefresh: false)
        sources.isBusy = { busy }
        sources.onContextInvalidated = { _ in invalidations += 1 }
        await sources.captureSelection(.notes, requestPermission: false)
        #expect(sources.canRefresh(.notes))
        #expect(!sources.isRefreshEnabled(.notes))
        sources.setRefreshEnabled(true, for: .notes)
        await sources.refreshEnabledSources()
        #expect(refreshes == 0)
        busy = false
        await sources.refreshEnabledSources()
        #expect(refreshes == 1)
        #expect(captures == 1)
        #expect(invalidations == 1)
        #expect(try sources.read(kind: .notes).summary.contains("Updated fixture text"))
        await sources.refreshEnabledSources()
        #expect(invalidations == 1)
    }

    @Test func aNewlyLockedNoteIsRemovedFromFutureRefreshScopeBeforeItsContentIsRead() async throws {
        let locked = try reference(.notes, "now locked")
        let available = try reference(.notes, "still available")
        let scope = NativePersonalSourceScope(kind: .notes, application: .init(pid: 42, launchedAt: .distantPast),
                                               references: [locked.data, available.data])
        var lockedProperties: [NativeSourceAppleEvents.Property] = []
        let batch = try NativeSourceAppleEvents.readCaptured(scope) { property, reference in
            #expect(property != .selection)
            let id = reference?.forKeyword(AEKeyword(keyAEKeyData))?.stringValue
            if id == "now locked" {
                lockedProperties.append(property)
                return .init(boolean: true)
            }
            #expect(id == "still available")
            switch property {
            case .protected: return .init(boolean: false)
            case .title: return .init(string: "Available fixture")
            case .body: return .init(string: "Readable fixture")
            default: throw NativeSourceAppleEvents.Failure.unavailableProperty
            }
        }
        #expect(lockedProperties == [.protected])
        #expect(batch.skipped == 1)
        #expect(batch.scope?.references == [available.data])
        #expect(batch.scope?.containsOnly(batch.items, kind: .notes) == true)
        let originalItems = scope.references.map {
            item(NativePersonalSourceScope.itemID(for: $0), title: "Captured fixture", text: "Original fixture text")
        }
        let original = NativePersonalSourceBatch(items: originalItems, skipped: 0, scope: scope)
        var refreshes = 0
        let sources = NativePersonalSources(capture: { _, _ in original }, refresh: { received in
            refreshes += 1
            #expect(received.references == (refreshes == 1 ? scope.references : [available.data]))
            return batch
        }, automaticRefresh: false)
        await sources.captureSelection(.notes, requestPermission: false)
        sources.setRefreshEnabled(true, for: .notes)
        await sources.refreshEnabledSources()
        await sources.refreshEnabledSources()
        #expect(refreshes == 2)
        #expect(sources.items(for: .notes).map(\.text) == ["Readable fixture"])
    }

    @Test func refreshCannotAddANewSelectedItemOrSurviveRevokedPermission() async throws {
        let original = try capturedNote()
        let outsider = try capturedNote("unapproved", text: "Never authorized for refresh")
        var permissionRevoked = false
        var invalidations = 0
        let sources = NativePersonalSources(capture: { _, _ in original }, refresh: { _ in
            if permissionRevoked { throw NativeSourceAppleEvents.Failure.permissionDenied }
            return outsider
        }, automaticRefresh: false)
        sources.onContextInvalidated = { _ in invalidations += 1 }
        await sources.captureSelection(.notes, requestPermission: false)
        sources.setRefreshEnabled(true, for: .notes)
        await sources.refreshEnabledSources()
        #expect(sources.items(for: .notes).isEmpty)
        #expect(!sources.isRefreshEnabled(.notes))
        #expect(!sources.canRefresh(.notes))
        #expect(invalidations == 1)
        #expect(throws: RelayError.self) { try sources.read(kind: .notes) }

        await sources.captureSelection(.notes, requestPermission: false)
        sources.setRefreshEnabled(true, for: .notes)
        permissionRevoked = true
        await sources.refreshEnabledSources()
        #expect(sources.items(for: .notes).isEmpty)
        #expect(!sources.isRefreshEnabled(.notes))
        #expect(invalidations == 2)
    }

    @Test func transientRefreshFailureBlocksOldContextUntilTheSameScopeRecovers() async throws {
        let original = try capturedNote()
        var failing = true
        var invalidations = 0
        let sources = NativePersonalSources(capture: { _, _ in original }, refresh: { _ in
            if failing { throw NativeSourceAppleEvents.Failure.expired }
            return original
        }, automaticRefresh: false)
        sources.onContextInvalidated = { _ in invalidations += 1 }
        await sources.captureSelection(.notes, requestPermission: false)
        sources.setRefreshEnabled(true, for: .notes)
        await sources.refreshEnabledSources()
        #expect(sources.isRefreshEnabled(.notes))
        #expect(sources.canRefresh(.notes))
        #expect(throws: RelayError.self) { try sources.read(kind: .notes) }
        #expect(invalidations == 1)
        failing = false
        await sources.refreshEnabledSources()
        #expect(try sources.read(kind: .notes).summary.contains("Initial fixture text"))
        #expect(invalidations == 2)
    }

    @Test(arguments: [true, false]) func disarmingWhileRefreshFinishesCannotPublishLateContext(forget: Bool) async throws {
        let original = try capturedNote()
        var finish: CheckedContinuation<NativePersonalSourceBatch, Never>?
        let sources = NativePersonalSources(capture: { _, _ in original }, refresh: { _ in
            await withCheckedContinuation { finish = $0 }
        }, automaticRefresh: false)
        await sources.captureSelection(.notes, requestPermission: false)
        sources.setRefreshEnabled(true, for: .notes)
        let refreshing = Task { await sources.refreshEnabledSources() }
        for _ in 0..<1_000 where finish == nil { await Task.yield() }
        let completion = try #require(finish)
        if forget { sources.forget(.notes) }
        else { sources.setRefreshEnabled(false, for: .notes) }
        completion.resume(returning: original)
        await refreshing.value
        #expect(!sources.isRefreshEnabled(.notes))
        #expect(sources.items(for: .notes).isEmpty == forget)
        #expect(sources.canRefresh(.notes) != forget)
        if forget { #expect(throws: RelayError.self) { try sources.read(kind: .notes) } }
        else { #expect(try sources.read(kind: .notes).summary.contains("Initial fixture text")) }
    }
}
