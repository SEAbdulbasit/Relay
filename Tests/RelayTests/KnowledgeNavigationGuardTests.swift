import Foundation
import Testing
@testable import Relay

@MainActor
struct KnowledgeNavigationGuardTests {
    @Test func unchangedReaderExecutesIntentImmediatelyWithoutASave() {
        var guardState = KnowledgeUnsavedChangesGuard<() -> Void>()
        var departures = 0
        var saves = 0
        guardState.request({ departures += 1 }, hasUnsavedChanges: false)?()
        #expect(departures == 1)
        #expect(guardState.pendingAction == nil)
        #expect(guardState.resolve(.save, save: { saves += 1; return true }) == nil)
        #expect(saves == 0 && departures == 1)
    }

    @Test func cancellingParentDepartureKeepsDraftAndSideEffectsUntouched() {
        let navigation = KnowledgeNavigationGuard()
        var guardState = KnowledgeUnsavedChangesGuard<KnowledgeNavigationGuard.Action>()
        var page = "Knowledge"
        var threadChanges = 0
        var draft = "Unsaved café note"
        navigation.install(owner: UUID()) { action in
            guardState.request(action, hasUnsavedChanges: true)?()
        }
        navigation.request { page = "Home"; threadChanges += 1 }
        #expect(page == "Knowledge" && threadChanges == 0)
        guardState.resolve(.cancel)?()
        #expect(page == "Knowledge" && threadChanges == 0 && draft == "Unsaved café note")
        // A stale alert callback cannot save or execute the canceled intent.
        guardState.resolve(.save, save: { draft = "Incorrect stale save"; return true })?()
        #expect(draft == "Unsaved café note" && threadChanges == 0)
    }

    @Test func saveFailureDoesNotLeaveReaderOrDiscardItsDraft() {
        var guardState = KnowledgeUnsavedChangesGuard<() -> Void>()
        var departures = 0
        var saves = 0
        let draft = "Keep this unsaved body"
        guardState.request({ departures += 1 }, hasUnsavedChanges: true)?()
        guardState.resolve(.save, save: { saves += 1; return false })?()
        #expect(saves == 1 && departures == 0 && draft == "Keep this unsaved body")
        #expect(guardState.pendingAction == nil)
        // A new deliberate request is required after the failed alert.
        guardState.resolve(.discard)?()
        #expect(departures == 0)
    }

    @Test func discardReleasesOnlyTheCurrentDeferredIntentExactlyOnce() {
        var guardState = KnowledgeUnsavedChangesGuard<() -> Void>()
        var first = 0, current = 0
        guardState.request({ first += 1 }, hasUnsavedChanges: true)?()
        guardState.request({ current += 1 }, hasUnsavedChanges: true)?()
        guardState.resolve(.discard)?()
        guardState.resolve(.discard)?()
        #expect(first == 0 && current == 1)
    }

    @Test func saveThenMoveEditorResolvesRenamedCurrentNoteRatherThanOriginalSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-guarded-note-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KnowledgeVaultManager(directoryURL: directory)
        let original = try manager.saveNote(title: "Original", body: "Saved body")
        var selectedURL = original.graphURL
        var opened: LocalMarkdownNote?
        var saveError: (any Error)?
        var guardState = KnowledgeUnsavedChangesGuard<() -> Void>()
        guardState.request({
            opened = (try? manager.loadNotes())?.first { $0.graphURL == selectedURL }
        }, hasUnsavedChanges: true)?()
        #expect(opened == nil)
        guardState.resolve(.save, save: {
            do {
                let saved = try manager.saveNote(title: "Renamed café", body: "Unsaved body now approved", replacing: original)
                selectedURL = saved.graphURL
                return true
            } catch { saveError = error; return false }
        })?()
        #expect(saveError == nil)
        #expect(opened?.title == "Renamed café")
        #expect(opened?.body.contains("Unsaved body now approved") == true)
        #expect(opened?.graphURL == selectedURL && selectedURL == original.graphURL)
        #expect(FileManager.default.fileExists(atPath: original.url.path))
    }

    @Test func chatDraftIsStagedOnlyAfterDecisionAndUsesFreshSavedContent() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-guarded-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KnowledgeVaultManager(directoryURL: directory)
        let original = try manager.saveNote(title: "Original", body: "Old saved body")
        let graphURL = original.graphURL
        var composerDraft = "Keep this unsent request"
        var guardState = KnowledgeUnsavedChangesGuard<() -> Void>()
        let stageChat = {
            if let current = (try? manager.loadNotes())?.first(where: { $0.graphURL == graphURL }) {
                composerDraft = "Using \(current.title): \(current.body)"
            }
        }
        guardState.request(stageChat, hasUnsavedChanges: true)?()
        guardState.resolve(.cancel)?()
        #expect(composerDraft == "Keep this unsent request")
        guardState.request(stageChat, hasUnsavedChanges: true)?()
        guardState.resolve(.save, save: {
            (try? manager.saveNote(title: "Updated", body: "Fresh approved content", replacing: original)) != nil
        })?()
        #expect(composerDraft.contains("Fresh approved content") && composerDraft.contains("Updated"))
        #expect(!composerDraft.contains("Old saved body"))
    }

    @Test func retiredReaderCannotClearReplacementNavigationOwner() {
        let navigation = KnowledgeNavigationGuard()
        let retired = UUID(), replacement = UUID()
        var oldRequests = 0, currentRequests = 0, departures = 0
        navigation.install(owner: retired) { _ in oldRequests += 1 }
        navigation.install(owner: replacement) { action in currentRequests += 1; action() }
        navigation.remove(owner: retired)
        navigation.request { departures += 1 }
        #expect(oldRequests == 0 && currentRequests == 1 && departures == 1)
        navigation.remove(owner: replacement)
        navigation.request { departures += 1 }
        #expect(currentRequests == 1 && departures == 2)
    }
}
