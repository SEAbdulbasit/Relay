import Foundation
import Testing
@testable import Relay

@MainActor
struct NotchTruthfulnessTests {
    @Test(arguments: ["Northstar pilot", "Carl venue Wednesday", "Canva renewal", "Denver receipts", "writing preferences"])
    func absentSourcesNeverProduceRememberedPersonalNotes(query: String) {
        let controller = NotchOverlayController()
        controller.updateRememberedNote(for: query, records: [])
        #expect(controller.rememberedNoteTitle == nil)
    }

    @Test func rememberedNoteRequiresAnActualIndexedRecord() {
        let controller = NotchOverlayController()
        let record = KnowledgeRecord(sourcePath: "/synthetic/Launch.md", title: "Launch checklist", text: "Synthetic fixture", modifiedAt: .distantPast, contentHash: "fixture", byteCount: 17)
        controller.updateRememberedNote(for: "launch", records: [record])
        #expect(controller.rememberedNoteTitle == "Launch checklist")
        controller.updateRememberedNote(for: "unrelated", records: [record])
        #expect(controller.rememberedNoteTitle == nil)
    }

    @Test func unavailableDraftingNeverReplacesDraftOrInventsResult() {
        var completions = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            completions += 1
            throw RelayError.message("Drafting must remain inert")
        })
        store.draft = "Preserve this existing draft"
        let controller = NotchOverlayController()
        controller.lastDoubleTapDraft = "Old synthetic reply"
        controller.triggerDoubleTapDraft(store: store, sampleContext: "Synthetic context requesting a reply")
        #expect(controller.lastDoubleTapDraft == nil)
        #expect(!controller.isDoubleTapSwirling)
        #expect(store.draft == "Preserve this existing draft")
        #expect(store.messages.isEmpty)
        #expect(completions == 0)
        #expect(store.selectionNotice?.contains("unavailable") == true)
        #expect(store.selectionNotice?.contains("nothing was captured, pasted or sent") == true)
    }

    @Test func vaultContainerDoesNotSeedPersonalDataOrOverwriteExistingNote() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-vault-truth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = KnowledgeVaultManager(directoryURL: directory)
        manager.ensureDefaultVaultFilesExist()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let note = directory.appendingPathComponent("User.md")
        try "Keep my note".write(to: note, atomically: true, encoding: .utf8)
        manager.ensureDefaultVaultFilesExist()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["User.md"])
        #expect(try String(contentsOf: note, encoding: .utf8) == "Keep my note")
        #expect(manager.saveGiftKeepsakeToDesktop(recipientName: "Synthetic") == nil)
    }

    @Test func groundedReplyPromptUsesActualKnowledgeAndWritingProfileWhileBlockingPII() {
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            throw RelayError.message("Must not auto-send")
        })
        let controller = NotchOverlayController()
        let prompt = controller.prepareGroundedReplyPrompt(store: store, incomingText: "Can you share the launch timeline?")
        #expect(prompt != nil)
        #expect(store.draft.contains("Can you share the launch timeline?"))
        #expect(controller.rememberedNoteTitle == nil)
        #expect(store.messages.isEmpty)

        // PII input is rejected and never populates draft
        let previousDraft = store.draft
        let blocked = controller.prepareGroundedReplyPrompt(store: store, incomingText: "My SSN is 123-45-6789")
        #expect(blocked == nil)
        #expect(store.draft == previousDraft)
    }
}
