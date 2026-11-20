import CryptoKit
import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@MainActor @Suite(.serialized) struct ConversationReplyTests {
    init() async throws {
        await awaitParitySuiteQuietWindow()
    }
    @Test func oldVisibleTextWireRemainsByteExactAndNewReplyIsNeverAutomaticHistoryInput() throws {
        let old = Data(#"{"omissions":[],"origin":"user","sourceRequirements":[],"text":"Older user message"}"#.utf8)
        let value = try JSONDecoder().decode(JournalVisibleText.self, from: old)
        #expect(value.reply == nil && value.automaticallyEligibleForInference)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(value) == old)
    }
    @Test func exactNativeUTF16SelectionNeverRepairsHalfAnEmojiOrNormalizesAQuote() throws {
        let text = "A🧪cafe\u{301}\u{fffd}Z"
        for range in [NSRange(location: 1, length: 1), NSRange(location: 2, length: 1),
                      NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)] {
            #expect(throws: ConversationReplySelection.Failure.unavailable) {
                _ = try ConversationReplySelection.quote(text, range: range)
            }
        }
        let emoji = try ConversationReplySelection.quote(text, range: NSRange(location: 1, length: 2))
        #expect(Data(emoji.utf8) == Data("🧪".utf8))
        let accent = try ConversationReplySelection.quote(text, range: NSRange(location: 3, length: 5))
        #expect(Data(accent.utf8) == Data("cafe\u{301}".utf8))
        #expect(Data(accent.utf8) != Data("caf\u{e9}".utf8))
        let literalReplacement = try ConversationReplySelection.quote(text, range: NSRange(location: 8, length: 1))
        #expect(Data(literalReplacement.utf8) == Data("\u{fffd}".utf8))
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-reply-" + UUID().uuidString)
        var stateURL: URL { root.appendingPathComponent("state.json") }
        var history: AssistantConversationHistory
        init() { history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")) }
        func save(_ message: ChatMessage) async throws {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            try history.stage(message, run: run, grants: [])
            _ = try await history.flush()
            try await history.finish(run, outcome: .responseDelivered)
            // Restore projects the actual startup snapshot. Reopen the saved
            // SQLite owner before constructing a Store fixture from it.
            try await reopen()
        }
        func rows() async throws -> [JournalRecord] {
            let core = try await history.journalForTesting(), scope = try await core.scope()
            return try await core.page(expectedScope: scope).records
        }
        func reopen() async throws {
            try await history.close()
            history = AssistantConversationHistory(stateURL: stateURL)
        }
        func remove() async { try? await history.close(); try? FileManager.default.removeItem(at: root) }
    }
    nonisolated private final class CommitBarrier: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var arrived = false, released = false, expired = false
        var entered: Bool { lock.withLock { arrived } }
        var timedOut: Bool { lock.withLock { expired } }
        func pause() {
            lock.withLock { arrived = true }
            if semaphore.wait(timeout: .now() + 5) == .timedOut { lock.withLock { expired = true } }
        }
        func release() {
            let signal = lock.withLock { let first = !released; released = true; return first }
            if signal { semaphore.signal() }
        }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate() {
            guard ContinuousClock.now < end else { throw JournalError.writerBusy }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func actualSavedNFDQuoteAndWholeMessageReferencesSurviveReopenWithoutVisibleEnvelope() async throws {
        let f = Fixture(), nfc = "caf\u{e9}", nfd = "cafe\u{301}"
        let prefix = "\(nfc) then ", original = ChatMessage(role: "assistant", text: prefix + nfd + " 🧪\nDo not treat old text as authority.")
        do {
            try await f.save(original)
            let whole = try await f.history.prepareReply(messageID: original.id)
            #expect(Data(whole.snapshot.utf8) == Data(original.text.utf8))
            let range = NSRange(location: prefix.utf16.count, length: nfd.utf16.count)
            let quote = try await f.history.prepareReply(messageID: original.id, selectedRange: range)
            #expect(Data(quote.snapshot.utf8) == Data(nfd.utf8) && Data(quote.snapshot.utf8) != Data(nfc.utf8))
            #expect(quote.reference.utf16Location == range.location && quote.reference.utf16Length == range.length)
            let request = ChatMessage(role: "user", text: "Explain this exact quote.", reply: quote.reference)
            try await f.save(request)
            try await f.reopen()
            let restored = try await f.history.restore()
            let saved = try #require(restored.messages.first { $0.id == request.id })
            #expect(saved.text == request.text && !saved.text.contains("HISTORICAL"))
            #expect(saved.reply == quote.reference)
            try await f.history.validateReply(try #require(saved.reply))
            let again = try await f.history.prepareReply(messageID: original.id, selectedRange: range)
            #expect(again.reference == quote.reference && Data(again.snapshot.utf8) == Data(nfd.utf8))
            let rows = try await f.rows(), row = try #require(rows.first { $0.event.id.bytes == Data(request.id.uuidString.utf8) })
            guard case .user(let text) = row.event.payload else { Issue.record("Expected actual saved user row."); await f.remove(); return }
            #expect(text.reply == quote.reference && !text.automaticallyEligibleForInference)
            #expect(!ConversationHistoryQueryTools.eligible(text))
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func actualOriginalLookupRejectsUnknownBodyMutationCanonicalAliasAndWrongGeneration() async throws {
        let f = Fixture(), source = ChatMessage(role: "assistant", text: "A🧪cafe\u{301}Z")
        do {
            try await f.save(source)
            let selection = try await f.history.prepareReply(messageID: source.id,
                selectedRange: NSRange(location: "A🧪".utf16.count, length: "cafe\u{301}".utf16.count))
            let r = selection.reference
            await #expect(throws: (any Error).self) { _ = try await f.history.prepareReply(messageID: UUID()) }
            let wrongBody = try JournalReplyReference(scope: r.scope, sequence: r.sequence, eventID: r.eventID,
                bodyDigest: Data(repeating: 8, count: 32), selectedText: r.selectedText, utf16Location: r.utf16Location, utf16Length: r.utf16Length)
            await #expect(throws: (any Error).self) { try await f.history.validateReply(wrongBody) }
            let alias = try JournalReplyReference(scope: r.scope, sequence: r.sequence, eventID: r.eventID,
                bodyDigest: r.bodyDigest, selectedText: "caf\u{e9}", utf16Location: r.utf16Location, utf16Length: "caf\u{e9}".utf16.count)
            await #expect(throws: (any Error).self) { try await f.history.validateReply(alias) }
            #expect(throws: (any Error).self) { _ = try ConversationReplySelection.quote(source.text, range: NSRange(location: 2, length: 1)) }
            let core = try await f.history.journalForTesting(), original = try #require(try await core.record(sequence: r.sequence, expectedScope: r.scope))
            let mutated = JournalEvent(id: original.event.id, taskID: original.event.taskID, attemptID: original.event.attemptID,
                createdAtMilliseconds: original.event.createdAtMilliseconds, payload: .assistant(try .init("Changed body", origin: .source)))
            await #expect(throws: JournalError.conflictingID) { _ = try await core.appendBatch([mutated], expectedScope: r.scope) }
            try await f.history.validateReply(r)
            try await f.history.clear()
            await #expect(throws: (any Error).self) { try await f.history.validateReply(r) }
            await #expect(throws: (any Error).self) { _ = try await f.history.prepareReply(messageID: source.id) }
            let cleared = try await f.history.restore()
            #expect(cleared.messages.isEmpty)
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func lostAcknowledgmentRepairsOneActualReplyRowWithoutChangingOriginalOrReference() async throws {
        let f = Fixture(), source = ChatMessage(role: "assistant", text: "Exact earlier answer 🧪")
        do {
            try await f.save(source)
            let reply = try await f.history.prepareReply(messageID: source.id)
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "Continue this.", reply: reply.reference)
            try f.history.stage(message, run: run, grants: [])
            let core = try await f.history.journalForTesting()
            await core.injectFault(.afterCommit)
            await #expect(throws: JournalError.acknowledgmentLost) { _ = try await f.history.flush() }
            let repaired = try await f.history.flush()
            #expect(repaired == [message.id])
            let rows = try await f.rows()
            #expect(rows.filter { $0.event.id.bytes == Data(message.id.uuidString.utf8) }.count == 1)
            #expect(rows.filter { $0.event.id.bytes == Data(source.id.uuidString.utf8) }.count == 1)
            try await f.history.finish(run, outcome: .responseDelivered)
            try await f.reopen()
            let restored = try await f.history.restore()
            #expect(restored.messages.first { $0.id == message.id }?.reply == reply.reference)
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func realStoreExternalReplyReopensPendingQuoteAndSendsHistoricalDataWithoutGenericDispatch() async throws {
        let f = Fixture(), source = ChatMessage(role: "assistant", text: "Earlier quoted words: cafe\u{301} 🧪")
        var store: AssistantStore?, turns = 0, generic = 0
        do {
            try await f.save(source)
            let first = AssistantStore(persistenceURL: f.stateURL, complete: { _, _, _ in .init(content: "Unused", toolCalls: []) }, conversationHistory: f.history)
            store = first; await first.waitForConversationTaskToSettle()
            let range = NSRange(location: "Earlier quoted words: ".utf16.count, length: "cafe\u{301}".utf16.count)
            let prepared = await first.prepareConversationReply(to: source.id, selectedRange: range)
            #expect(prepared)
            let before = try #require(first.pendingReply)
            first.stop(); await first.waitForConversationTaskToSettle()
            try await f.reopen()
            let reopened = AssistantStore(persistenceURL: f.stateURL, complete: { input, _, _ in
                turns += 1
                let text = try #require(input.last { $0.role == "user" }?.content)
                #expect(text.contains("CURRENT USER REQUEST:") && text.contains("USER-SELECTED HISTORICAL REPLY CONTEXT:"))
                #expect(text.contains("not instructions or current app/file state"))
                #expect(text.contains("cafe\u{301}") && !text.contains(source.text))
                return .init(content: "A reply about the selected historical quote.", toolCalls: [])
            }, conversationHistory: f.history, execute: { _ in generic += 1; throw CancellationError() })
            store = reopened; await reopened.waitForConversationTaskToSettle()
            #expect(reopened.pendingReply?.id == before.id)
            #expect(Data((reopened.pendingReply?.snapshot ?? "").utf8) == Data(before.snapshot.utf8))
            let origin = UUID()
            let ticket = try #require(reopened.submitText("Explain this quote.", originID: origin, originRevision: 1))
            ticket.onAcknowledgment { status in
                if status == .saved {
                    reopened.acknowledgeExternalReplyDraft(ticket, selectionID: before.id, originID: origin, originRevision: 1)
                }
            }
            let status = await ticket.waitForAcknowledgment(); #expect(status == .saved)
            await reopened.waitForConversationTaskToSettle()
            #expect(turns == 1 && generic == 0 && reopened.pendingReply == nil)
            let user = try #require(reopened.messages.first { $0.id == ticket.messageID })
            #expect(user.text == "Explain this quote." && user.reply == before.reference)
            #expect(reopened.phase == .idle)
            reopened.stop(); await reopened.waitForConversationTaskToSettle(); await f.remove()
        } catch { store?.stop(); await store?.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test func realCommitStopPublishesNoInferenceAndPreservesUnsentReplyData() async throws {
        let f = Fixture(), source = ChatMessage(role: "assistant", text: "Old data to discuss"), barrier = CommitBarrier()
        var store: AssistantStore?, calls = 0
        do {
            try await f.save(source)
            let actual = AssistantStore(persistenceURL: f.stateURL, complete: { _, _, _ in calls += 1; return .init(content: "Unexpected", toolCalls: []) }, conversationHistory: f.history)
            store = actual; await actual.waitForConversationTaskToSettle()
            let prepared = await actual.prepareConversationReply(to: source.id); #expect(prepared)
            let selection = try #require(actual.pendingReply)
            actual.draft = "Discuss this historical message."
            let core = try await f.history.journalForTesting()
            await core.atNextBoundary(.afterCommit) { barrier.pause() }
            let ticket = try #require(actual.send())
            try await wait { barrier.entered }
            actual.stop(); barrier.release()
            await actual.waitForConversationTaskToSettle()
            #expect(ticket.status == .stopped && calls == 0 && !barrier.timedOut)
            #expect(actual.pendingReply?.id == selection.id && actual.draft == ticket.text)
            #expect(actual.phase == .stopped)
            await f.remove()
        } catch { barrier.release(); store?.stop(); await store?.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test func savedObserverCannotClearNewReplyAndCanonicalDraftEdit() async throws {
        let f = Fixture(), original = ChatMessage(role: "assistant", text: "Original A"), next = ChatMessage(role: "assistant", text: "Next B")
        let barrier = CommitBarrier()
        var store: AssistantStore?
        do {
            try await f.save(original); try await f.save(next)
            let actual = AssistantStore(persistenceURL: f.stateURL, complete: { _, _, _ in .init(content: "Answer", toolCalls: []) }, conversationHistory: f.history)
            store = actual; await actual.waitForConversationTaskToSettle()
            let prepared = await actual.prepareConversationReply(to: original.id); #expect(prepared)
            actual.draft = "caf\u{e9}"
            let core = try await f.history.journalForTesting()
            await core.atNextBoundary(.afterCommit) { barrier.pause() }
            let ticket = try #require(actual.send())
            try await wait { barrier.entered }
            actual.draft = "cafe\u{301}"
            // Actual saved callback executes after the original selection was
            // cleared. A new user selection must survive the old task's exit.
            var selectedNext: Task<Bool, Never>?
            var keptReplyForEditedDraft = false
            ticket.onAcknowledgment { status in
                if status == .saved {
                    keptReplyForEditedDraft = actual.pendingReply?.reference.eventID.bytes == Data(original.id.uuidString.utf8)
                    selectedNext = Task { @MainActor in await actual.prepareConversationReply(to: next.id) }
                }
            }
            barrier.release()
            let status = await ticket.waitForAcknowledgment(); #expect(status == .saved)
            let nextPrepared = await selectedNext?.value; #expect(nextPrepared == true)
            await actual.waitForConversationTaskToSettle()
            #expect(Data(actual.draft.utf8) == Data("cafe\u{301}".utf8))
            #expect(keptReplyForEditedDraft && !barrier.timedOut)
            #expect(actual.pendingReply?.reference.eventID.bytes == Data(next.id.uuidString.utf8))
            let submitted = try #require(actual.messages.first { $0.id == ticket.messageID })
            #expect(submitted.reply?.eventID.bytes == Data(original.id.uuidString.utf8))
            actual.stop(); await actual.waitForConversationTaskToSettle(); await f.remove()
        } catch { barrier.release(); store?.stop(); await store?.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test(arguments: [false, true])
    func actualSidekickSavedCallbackClearsOnlyItsUneditedReplyComposer(_ edit: Bool) async throws {
        let f = Fixture(), source = ChatMessage(role: "assistant", text: "Sidekick historical reply target"), barrier = CommitBarrier()
        let suite = "relay-reply-sidekick-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        let controller = NotchOverlayController(preferences: preferences, presentsPanels: false)
        var store: AssistantStore?, calls = 0
        do {
            try await f.save(source)
            let actual = AssistantStore(persistenceURL: f.stateURL, complete: { _, _, _ in calls += 1; return .init(content: "Historical answer", toolCalls: []) }, conversationHistory: f.history)
            store = actual; await actual.waitForConversationTaskToSettle()
            // Headless dependency is the actual injected completion closure;
            // no provider/model readiness or native authority is being tested.
            actual.actionsReady = true
            let prepared = await actual.prepareConversationReply(to: source.id); #expect(prepared)
            let selection = try #require(actual.pendingReply)
            controller.promptText = "caf\u{e9}"
            let core = try await f.history.journalForTesting()
            await core.atNextBoundary(.afterCommit) { barrier.pause() }
            controller.submit(store: actual)
            let ticket = try #require(controller.pendingSubmission)
            try await wait { barrier.entered }
            if edit { controller.promptText = "cafe\u{301}" }
            barrier.release()
            let status = await ticket.waitForAcknowledgment(); #expect(status == .saved)
            await actual.waitForConversationTaskToSettle()
            if edit {
                #expect(Data(controller.promptText.utf8) == Data("cafe\u{301}".utf8))
                #expect(actual.pendingReply?.id == selection.id)
            } else {
                #expect(controller.promptText.isEmpty && actual.pendingReply == nil)
            }
            #expect(calls == 1 && !barrier.timedOut && controller.pendingSubmission == nil)
            actual.stop(); await actual.waitForConversationTaskToSettle()
            preferences.removePersistentDomain(forName: suite); await f.remove()
        } catch {
            barrier.release(); store?.stop(); await store?.waitForConversationTaskToSettle()
            preferences.removePersistentDomain(forName: suite); await f.remove(); throw error
        }
    }

    @Test func actualReopenedOriginalBeyondManyPagesWorksWithoutBeingInTheVisibleMessageWindow() async throws {
        let f = Fixture(), source = ChatMessage(role: "assistant", text: "OLDER_SAVED_EXACT_TARGET_cafe\u{301}")
        var store: AssistantStore?, calls = 0
        do {
            try await f.save(source)
            let filler = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            try await f.history.prepare(filler)
            let core = try await f.history.journalForTesting(), scope = try await core.scope()
            let events = try (0..<1005).map { index in
                JournalEvent(id: try JournalOpaqueID(UUID().uuidString), taskID: filler.taskID, attemptID: filler.attemptID,
                    payload: .user(try .init("Later history row \(index)", origin: .user)))
            }
            for start in stride(from: 0, to: events.count, by: 32) {
                _ = try await core.appendBatch(Array(events[start..<min(start + 32, events.count)]), expectedScope: scope)
            }
            try await f.history.finish(filler, outcome: .responseDelivered)
            try await f.reopen()
            let first = AssistantStore(persistenceURL: f.stateURL, complete: { _, _, _ in .init(content: "Unused", toolCalls: []) }, conversationHistory: f.history)
            store = first; await first.waitForConversationTaskToSettle()
            let prepared = await first.prepareConversationReply(to: source.id); #expect(prepared)
            let selected = try #require(first.pendingReply)
            first.stop(); await first.waitForConversationTaskToSettle(); try await f.reopen()
            let actual = AssistantStore(persistenceURL: f.stateURL, complete: { input, _, _ in
                calls += 1
                #expect(input.contains { $0.role == "user" && $0.content.contains(source.text) })
                return .init(content: "A reply to the exact original saved target.", toolCalls: [])
            }, conversationHistory: f.history)
            store = actual; await actual.waitForConversationTaskToSettle()
            #expect(actual.messages.count > 1000 && actual.pendingReply?.id == selected.id)
            // Retain only the last visible window. The original remains in
            // actual SQLite and is validated by scope/sequence, never UI text.
            actual.messages = Array(actual.messages.suffix(40))
            #expect(!actual.messages.contains { $0.id == source.id })
            actual.draft = "Discuss my selected earlier message."
            let ticket = try #require(actual.send())
            let status = await ticket.waitForAcknowledgment(); #expect(status == .saved)
            await actual.waitForConversationTaskToSettle()
            #expect(calls == 1 && actual.pendingReply == nil)
            #expect(actual.messages.first { $0.id == ticket.messageID }?.reply == selected.reference)
            actual.stop(); await actual.waitForConversationTaskToSettle(); await f.remove()
        } catch { store?.stop(); await store?.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }

    @Test func actualPendingSnapshotRoleIsValidatedAgainstTheSavedOriginalBeforeCommit() async throws {
        let f = Fixture(), source = ChatMessage(role: "assistant", text: "A saved assistant snapshot")
        do {
            try await f.save(source)
            let actual = try await f.history.prepareReply(messageID: source.id)
            let forgedRole = try ConversationReplySelection(reference: actual.reference, snapshot: actual.snapshot, role: "user")
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "Discuss this.", reply: actual.reference)
            try f.history.stage(message, run: run, grants: [], replySelection: forgedRole)
            await #expect(throws: (any Error).self) { _ = try await f.history.flush() }
            let rows = try await f.rows()
            #expect(!rows.contains { $0.event.id.bytes == Data(message.id.uuidString.utf8) })
            await f.remove()
        } catch { await f.remove(); throw error }
    }

    @Test func clearedOriginalCannotEnterInferenceOrBecomeNewUserAuthority() async throws {
        let f = Fixture(), source = ChatMessage(role: "assistant", text: "Saved original that will be cleared")
        var store: AssistantStore?, turns = 0
        do {
            try await f.save(source)
            let actual = AssistantStore(persistenceURL: f.stateURL, complete: { _, _, _ in turns += 1; return .init(content: "Unexpected", toolCalls: []) }, conversationHistory: f.history)
            store = actual; await actual.waitForConversationTaskToSettle()
            let prepared = await actual.prepareConversationReply(to: source.id); #expect(prepared)
            let selected = try #require(actual.pendingReply)
            // Reset actual SQLite behind the still-visible old UI. The durable
            // reference's generation must refuse before any private inference.
            try await f.history.clear()
            actual.draft = "Explain that earlier message."
            let ticket = try #require(actual.send())
            let status = await ticket.waitForAcknowledgment(); #expect(status == .failed)
            await actual.waitForConversationTaskToSettle()
            #expect(turns == 0 && actual.pendingReply?.id == selected.id)
            #expect(actual.draft == ticket.text)
            let rows = try await f.rows()
            #expect(!rows.contains { $0.event.id.bytes == Data(ticket.messageID.uuidString.utf8) })
            actual.stop(); await actual.waitForConversationTaskToSettle(); await f.remove()
        } catch { store?.stop(); await store?.waitForConversationTaskToSettle(); await f.remove(); throw error }
    }
}
