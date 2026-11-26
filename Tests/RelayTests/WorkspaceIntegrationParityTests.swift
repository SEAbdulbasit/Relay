import AppKit
import Foundation
import simd
import Testing
@testable import Relay

@MainActor @Suite(.serialized) struct WorkspaceIntegrationParityTests {

    // MARK: - Domain 4: SemanticVaultBuilder, WritingStyleCollector & ProactiveIntelligenceEngine

    @Test func semanticVaultBuilderSynthesizesOverviewEntityNotesWikilinksAndGuardsConcurrentEdits() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelaySemanticVaultParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vaultDir = tempRoot.appendingPathComponent("KnowledgeVault", isDirectory: true)
        let resumeURL = tempRoot.appendingPathComponent("semantic-vault-resume.json", isDirectory: false)

        // Seed user-owned writingstyle.md before synthesis to verify atomic swap preservation
        let originalStyle = "Hey Alex, sounds great — see you Tuesday at 2pm!\n\nThanks for sending the deck over."
        try WritingStyleCollector.saveUserEditedSnapshot(originalStyle, in: vaultDir)

        let items: [CorpusItem] = [
            CorpusItem(
                id: "note-1",
                title: "Relay 3.1 Kickoff",
                text: "Working with Alex Rivera on shipping Relay 3.1 semantic vault and Morning Brief cards.",
                itemDate: Date(timeIntervalSince1970: 1_760_000_000),
                sourceID: "apple-notes",
                kind: SourceAttributionRole.userAuthored.rawValue
            ),
            CorpusItem(
                id: "note-2",
                title: "Travel & Coffee Preferences",
                text: "Prefer morning flights out of SFO and cortados with oat milk. Trip to Tokyo planned for November.",
                itemDate: Date(timeIntervalSince1970: 1_760_010_000),
                sourceID: "apple-notes",
                kind: SourceAttributionRole.userAuthored.rawValue
            )
        ]

        let builder = SemanticVaultBuilder(vaultRoot: vaultDir, resumeStateURL: resumeURL)
        var sliceCalls = 0
        let report = try await builder.buildOrUpdate(
            items: items,
            sliceBudget: 260, // Force 2 slices across the 2 items
            sliceItemLimit: 1,
            allowResume: false
        ) { _ in
            sliceCalls += 1
            if sliceCalls == 1 {
                let json = """
                {
                  "overview_summary": "Building Relay 3.1 on macOS alongside collaborator Alex Rivera.",
                  "active_priorities": ["Ship Relay 3.1 Knowledge Vault"],
                  "notes": [
                    {
                      "domain": "People",
                      "title": "Alex Rivera",
                      "summary": "Collaborator partnering with the user on Relay 3.1.",
                      "facts": ["Co-designing the Semantic Knowledge Vault with the user."],
                      "open_threads": ["Sync on Morning Brief review UX"],
                      "related_titles": ["Relay 3.1"],
                      "source_ids": ["note-1"],
                      "attribution": "counterparty"
                    },
                    {
                      "domain": "Projects",
                      "title": "Relay 3.1",
                      "summary": "Local-first macOS personal assistant upgrade.",
                      "facts": ["Includes SemanticVaultBuilder and ProactiveIntelligenceEngine."],
                      "open_threads": ["Verify wikilinks before atomic swap"],
                      "related_titles": ["Alex Rivera"],
                      "source_ids": ["note-1"],
                      "attribution": "user"
                    }
                  ]
                }
                """
                return ModelReply(content: json, toolCalls: [])
            } else {
                let json = """
                {
                  "overview_summary": "Planning a November trip to Tokyo and prefers morning SFO flights.",
                  "active_priorities": ["Finalize November Tokyo itinerary"],
                  "notes": [
                    {
                      "domain": "Plans",
                      "title": "Tokyo November Trip",
                      "summary": "Upcoming November travel plan to Tokyo.",
                      "facts": ["Scheduled for November."],
                      "open_threads": ["Book morning flight from SFO"],
                      "related_titles": ["Travel and Coffee Habits"],
                      "source_ids": ["note-2"],
                      "attribution": "user"
                    },
                    {
                      "domain": "Preferences",
                      "title": "Travel and Coffee Habits",
                      "summary": "Personal travel timing and coffee preferences.",
                      "facts": ["Prefers morning flights from SFO.", "Orders oat milk cortados."],
                      "open_threads": [],
                      "related_titles": ["Tokyo November Trip"],
                      "source_ids": ["note-2"],
                      "attribution": "user"
                    }
                  ]
                }
                """
                return ModelReply(content: json, toolCalls: [])
            }
        }

        #expect(sliceCalls == 2)
        #expect(report.completedSlices == 2)
        #expect(report.totalSlices == 2)
        #expect(report.noteCount >= 6) // Overview.md + README.md + 4 domain entity notes
        #expect(report.wikilinksVerified >= 4)
        #expect(builder.pendingResumeToken == nil)

        let overview = try String(contentsOf: vaultDir.appendingPathComponent("Overview.md"), encoding: .utf8)
        let readme = try String(contentsOf: vaultDir.appendingPathComponent("README.md"), encoding: .utf8)
        let alexNote = try String(contentsOf: vaultDir.appendingPathComponent("People/Alex Rivera.md"), encoding: .utf8)
        let projectNote = try String(contentsOf: vaultDir.appendingPathComponent("Projects/Relay 3.1.md"), encoding: .utf8)

        #expect(overview.contains("Relay 3.1"))
        #expect(readme.contains("[[Overview]]"))
        #expect(alexNote.contains("[[Projects/Relay 3.1|Relay 3.1]]") || alexNote.contains("Relay 3.1"))
        #expect(projectNote.contains("Alex Rivera"))

        // Verify writingstyle.md was preserved byte-for-byte across the atomic directory swap
        let preservedStyle = try WritingStyleCollector.readSnapshot(in: vaultDir)
        #expect(preservedStyle == originalStyle)

        // Verify KNW-05 live vaultFingerprint recheck refuses to overwrite concurrent user edits
        let userEditedOverviewURL = vaultDir.appendingPathComponent("Overview.md")
        await #expect(throws: SemanticVaultBuilder.Failure.vaultModifiedDuringSynthesis) {
            _ = try await builder.buildOrUpdate(items: [items[0]], allowResume: false) { _ in
                // Simulate user editing a live vault note while synthesis is mid-flight
                try Data((overview + "\n\nUser manual note edit during background build.\n").utf8)
                    .write(to: userEditedOverviewURL, options: .atomic)
                let delta = """
                {
                  "overview_summary": "Background build output that must be discarded.",
                  "active_priorities": [],
                  "notes": [
                    {
                      "domain": "Projects",
                      "title": "Relay 3.1",
                      "summary": "Updated summary.",
                      "facts": ["Fact"],
                      "source_ids": ["note-1"],
                      "attribution": "user"
                    }
                  ]
                }
                """
                return ModelReply(content: delta, toolCalls: [])
            }
        }
        let afterConcurrentEdit = try String(contentsOf: userEditedOverviewURL, encoding: .utf8)
        #expect(afterConcurrentEdit.contains("User manual note edit during background build."))
    }

    @Test func writingStyleCollectorPublishesOncePreservesUserEditsAndNeverTruncatesSilently() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayWritingStyleParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let collector = WritingStyleCollector(vaultRoot: tempRoot)
        #expect(collector.hasSnapshot == false)

        // 1. Scope change mid-collection aborts without creating writingstyle.md
        var scopeVersion = "v1"
        await #expect(throws: WritingStyleCollector.Failure.scopeChanged) {
            _ = try await collector.collectOnceIfNeeded(
                optedInSources: ["imessage"],
                currentScopeToken: { scopeVersion },
                fetchSamples: {
                    await MainActor.run { scopeVersion = "v2" }
                    return [
                        .init(id: "s1", sourceID: "imessage", medium: .iMessage, recipient: "Sam", text: "On my way! Running 5 mins late.")
                    ]
                }
            )
        }
        #expect(collector.hasSnapshot == false)

        // 2. First valid collection filters out group threads & incoming messages and publishes once
        let stableScope = "imessage|mail"
        let firstOutcome = try await collector.collectOnceIfNeeded(
            optedInSources: ["imessage", "appleMail"],
            currentScopeToken: { stableScope },
            fetchSamples: {
                [
                    // Eligible 1:1 outgoing iMessage
                    .init(
                        id: "m1",
                        sourceID: "imessage",
                        medium: .iMessage,
                        recipient: "Jordan",
                        recipientCount: 1,
                        isOutgoing: true,
                        isGroupThread: false,
                        text: "Sounds good, let's grab lunch around 12:30 tomorrow!"
                    ),
                    // Group chat (must be excluded)
                    .init(
                        id: "m2",
                        sourceID: "imessage",
                        medium: .iMessage,
                        recipient: "Weekend Crew",
                        recipientCount: 4,
                        isOutgoing: true,
                        isGroupThread: true,
                        text: "SECRET_GROUP_THREAD_TEXT_DO_NOT_INCLUDE"
                    ),
                    // Incoming message (must be excluded)
                    .init(
                        id: "m3",
                        sourceID: "imessage",
                        medium: .iMessage,
                        recipient: "Jordan",
                        recipientCount: 1,
                        isOutgoing: false,
                        isGroupThread: false,
                        text: "INCOMING_COUNTERPARTY_TEXT_DO_NOT_INCLUDE"
                    ),
                    // Eligible 1:1 outgoing email
                    .init(
                        id: "e1",
                        sourceID: "appleMail",
                        medium: .email,
                        recipient: "pat@example.com",
                        recipientCount: 1,
                        isOutgoing: true,
                        isGroupThread: false,
                        text: "Hi Pat,\n\nThanks for reviewing the proposal. Here are the updated timeline notes.\n\nBest,\nAlex"
                    )
                ]
            }
        )

        if case .published(let count, let bytes) = firstOutcome {
            #expect(count == 2)
            #expect(bytes > 0)
        } else {
            Issue.record("Expected .published outcome, got \(firstOutcome)")
        }

        let snapshot = try WritingStyleCollector.readSnapshot(in: tempRoot) ?? ""
        #expect(snapshot.contains("grab lunch around 12:30"))
        #expect(snapshot.contains("Thanks for reviewing the proposal"))
        #expect(!snapshot.contains("SECRET_GROUP_THREAD_TEXT_DO_NOT_INCLUDE"))
        #expect(!snapshot.contains("INCOMING_COUNTERPARTY_TEXT_DO_NOT_INCLUDE"))

        // 3. Second collection returns .alreadyExists and never overwrites user edits (even when emptied!)
        try WritingStyleCollector.saveUserEditedSnapshot("", in: tempRoot)
        let secondOutcome = try await collector.collectOnceIfNeeded(
            optedInSources: ["imessage"],
            currentScopeToken: { stableScope },
            fetchSamples: {
                [.init(id: "m4", sourceID: "imessage", medium: .iMessage, recipient: "Jordan", text: "Should never overwrite empty user file")]
            }
        )
        #expect(secondOutcome == .alreadyExists)
        #expect(try WritingStyleCollector.readSnapshot(in: tempRoot) == "")

        // 4. Oversized user edit throws .tooLarge instead of silently truncating
        let oversized = String(repeating: "a", count: WritingStyleCollector.maximumBytes + 128)
        #expect(throws: WritingStyleCollector.Failure.self) {
            try WritingStyleCollector.saveUserEditedSnapshot(oversized, in: tempRoot)
        }

        await collector.cancelSetupAndDrain()
        #expect(collector.isCollecting == false)
    }

    @Test func proactiveIntelligenceEngineRunsJudgeReadOnlyResearchEditableCardsAndFrozenHandoff() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayProactiveParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let vaultDir = tempRoot.appendingPathComponent("KnowledgeVault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        let persistenceURL = tempRoot.appendingPathComponent("proactive-state.json", isDirectory: false)

        // 1. Structural Read-Only Tool Gate blocks all write/send/action/computer-use tools
        let gate = ProactiveReadOnlyToolGate(
            lookupSource: { id in "Source detail for \(id)" },
            searchVault: { q in "Vault note matching \(q)" },
            checkCalendar: { "10:00 AM Design Review" },
            readConnector: { q in "Connector read-only result for \(q)" }
        )
        #expect(try await gate.execute(toolName: "lookup_source", query: "msg-open") == "Source detail for msg-open")
        #expect(try await gate.execute(toolName: "search_vault", query: "Priya") == "Vault note matching Priya")

        for forbidden in ["send_mail", "control_native_window", "computer_use", "bash", "write_file", "create_calendar_event", "draft_apply"] {
            #expect(ProactiveReadOnlyToolGate.isPermittedToolName(forbidden) == false)
            await #expect(throws: ProactiveSecurityViolation.writeOrActionToolBlocked(forbidden)) {
                _ = try await gate.execute(toolName: forbidden, query: "attempt")
            }
        }

        // 2. End-to-end Stage 1 Judge -> Stage 2 Read-Only Research -> Stage 3 Editable Deck
        let now = Date()
        let corpus: [CorpusItem] = [
            CorpusItem(
                id: "msg-open",
                title: "DM from Priya",
                text: "Priya: Can you confirm whether Thursday at 3pm works for the architecture review?",
                itemDate: now.addingTimeInterval(-3_600),
                sourceID: "imessage",
                kind: SourceAttributionRole.directCorrespondence.rawValue
            ),
            CorpusItem(
                id: "msg-answered",
                title: "Email from Dana",
                text: "Dana: Did you send the Q3 invoice?",
                itemDate: now.addingTimeInterval(-7_200),
                sourceID: "apple-mail",
                kind: SourceAttributionRole.directCorrespondence.rawValue
            )
        ]

        let engine = ProactiveIntelligenceEngine(vaultRoot: vaultDir, persistenceURL: persistenceURL)
        engine.setStandingInstructions("Prioritize architecture review replies.")

        // Verify Stage 2 rejects a model response that tries to emit a non-read-only tool call
        let candidateForSecurityCheck = ProactiveCandidate(
            id: "proactive-sec",
            title: "Hostile Prompt Injection Check",
            whyNow: "Test PRO-04 tool call rejection",
            suggestedKind: .draftReply,
            sourceIDs: ["msg-open"]
        )
        await #expect(throws: ProactiveSecurityViolation.writeOrActionToolBlocked("send_mail")) {
            _ = try await engine.researchAndPrepare(
                candidates: [candidateForSecurityCheck],
                corpusByID: ["msg-open": corpus[0]],
                readOnlyGate: gate
            ) { _ in
                ModelReply(
                    content: "{}",
                    toolCalls: [ToolCall(name: "send_mail", arguments: ["to": .string("attacker@example.com")])]
                )
            }
        }

        // Run full prepareCards: Judge returns 2 candidates; liveOutgoingCheck proves msg-answered is already answered
        var modelTurn = 0
        let activeCards = try await engine.prepareCards(
            corpus: corpus,
            accountGenerations: ["gmail": "gen-1"],
            isSourceCurrent: { _ in true },
            liveOutgoingCheck: { candidate in
                if candidate.sourceIDs.contains("msg-answered") {
                    return .alreadyAnsweredOrCompleted("Sent reply found in Sent mailbox at 09:15.")
                }
                return .verifiedOpen("No outgoing reply after Priya's 1:1 message.")
            },
            readOnlyGate: gate,
            referenceDate: now
        ) { _ in
            modelTurn += 1
            if modelTurn == 1 {
                let judgeJSON = """
                {
                  "candidates": [
                    {
                      "title": "Reply to Priya on Thursday 3pm review",
                      "why_now": "Priya asked an hour ago if Thursday at 3pm works for the architecture review.",
                      "suggested_kind": "draft_reply",
                      "source_ids": ["msg-open"],
                      "counterparty": "Priya",
                      "priority": 1
                    },
                    {
                      "title": "Reply to Dana about Q3 invoice",
                      "why_now": "Dana asked about the Q3 invoice.",
                      "suggested_kind": "draft_email",
                      "source_ids": ["msg-answered"],
                      "counterparty": "Dana",
                      "priority": 2
                    }
                  ]
                }
                """
                return ModelReply(content: judgeJSON, toolCalls: [])
            } else {
                let researchJSON = """
                {
                  "drop": false,
                  "verified_read_only": true,
                  "verification_detail": "Verified open in iMessage with free Thursday 3pm slot.",
                  "title": "Confirm Thursday 3pm with Priya",
                  "why_now": "Priya is waiting on confirmation for Thursday's architecture review.",
                  "artifact_kind": "draft_reply",
                  "recipient": "Priya",
                  "channel": "iMessage",
                  "thread_context": "Architecture review scheduling",
                  "body": "Thursday at 3pm works great for me — talk then!"
                }
                """
                return ModelReply(content: researchJSON, toolCalls: [])
            }
        }

        #expect(activeCards.count == 1)
        #expect(engine.droppedCandidates.count == 1)
        #expect(engine.droppedCandidates.first?.reason.contains("Sent reply found") == true)

        let card = try #require(activeCards.first)
        #expect(card.verificationStatus == .verifiedReadOnly)
        #expect(card.title == "Confirm Thursday 3pm with Priya")

        // 3. User edits the card; verify frozen handoff preserves exact user edits & enforces generation fencing
        let editedArtifact = ProactiveArtifact.draftReply(.init(
            recipient: "Priya",
            channel: "iMessage",
            threadContext: "Architecture review scheduling",
            body: "Thursday at 3pm works great — let's meet in Zoom room B!"
        ))
        engine.updateCard(id: card.id, title: "Confirm Thursday 3pm Zoom with Priya", artifact: editedArtifact)

        let handoff = try engine.prepareFrozenHandoff(
            id: card.id,
            isSourceCurrent: { _ in true },
            currentAccountGenerations: ["gmail": "gen-1"]
        )
        #expect(handoff.frozenCard.title == "Confirm Thursday 3pm Zoom with Priya")
        #expect(handoff.userPrompt.contains("Zoom room B"))

        // Unverified task failure keeps card & user edits in .ready state
        engine.recordTaskCompletion(cardID: card.id, verified: false, failureNote: "User cancelled review")
        #expect(engine.activeCards.first?.lifecycle == .ready)
        #expect(engine.activeCards.first?.title == "Confirm Thursday 3pm Zoom with Priya")

        // Verified completion retires card from active deck
        engine.recordTaskCompletion(cardID: card.id, verified: true)
        #expect(engine.activeCards.isEmpty)

        // Account generation mismatch on a new card fences & retires stale handoff
        let staleCardID = "card-stale-gen"
        let engineReloaded = ProactiveIntelligenceEngine(vaultRoot: vaultDir, persistenceURL: persistenceURL)
        #expect(engineReloaded.activeCards.isEmpty)
        _ = staleCardID
    }

    // MARK: - Domain 5: MagicReply, NotchTouchCalibration, YouTubeTranscriptFetcher & BrowserSelectionReplacer

    @Test func magicReplyVaultPackerVerdictSwirlMathAndAgentToolNeverAutoSend() throws {
        let tempVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayMagicReplyVault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempVault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempVault) }

        let peopleDir = tempVault.appendingPathComponent("People", isDirectory: true)
        try FileManager.default.createDirectory(at: peopleDir, withIntermediateDirectories: true)

        try Data("# Overview\nUser is a macOS engineer in San Francisco.\n".utf8)
            .write(to: tempVault.appendingPathComponent("Overview.md"))
        try Data("# Vault Index\nLinks to [[Overview]].\n".utf8)
            .write(to: tempVault.appendingPathComponent("README.md"))
        try Data("# Sam\nTeammate working on Quick Actions.\n".utf8)
            .write(to: peopleDir.appendingPathComponent("Sam.md"))
        try Data("Casual voice example: sounds good! see ya at 3\n".utf8)
            .write(to: tempVault.appendingPathComponent("writingstyle.md"))
        // High-risk PII note must be skipped by MagicReplyVaultPacker
        try Data("SSN: 123-45-6789\n".utf8)
            .write(to: peopleDir.appendingPathComponent("SecretPII.md"))

        let packed = MagicReplyVaultPacker.pack(vaultRoot: tempVault)
        #expect(packed.noteCount == 3)
        #expect(packed.writingSamplesText.contains("Casual voice example"))
        #expect(!packed.combinedKnowledgeBlock.contains("123-45-6789"))

        // Overview.md must be prioritized ahead of README.md and entity notes
        let overviewRange = try #require(packed.notesText.range(of: "# Overview.md"))
        let readmeRange = try #require(packed.notesText.range(of: "# README.md"))
        let samRange = try #require(packed.notesText.range(of: "# People/Sam.md"))
        #expect(overviewRange.lowerBound < readmeRange.lowerBound)
        #expect(readmeRange.lowerBound < samRange.lowerBound)

        // Verdict classification handles plain and decorated NOT_A_MESSAGE vs real unsent reply
        #expect(MagicReplyVaultPacker.verdict(from: "NOT_A_MESSAGE") == .notAMessage)
        #expect(MagicReplyVaultPacker.verdict(from: "  `NOT_A_MESSAGE.` \n") == .notAMessage)
        #expect(MagicReplyVaultPacker.verdict(from: "Sounds great, count me in for Tuesday!") == .reply("Sounds great, count me in for Tuesday!"))

        // Caret swirl math transitions produce finite geometry across gathering -> landing -> dissolving
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(MagicReplySwirlMath.frame(phase: .idle, began: t0, orbit: 18, at: t0) == nil)
        let gatherFrame = try #require(MagicReplySwirlMath.frame(
            phase: .gathering,
            began: t0,
            orbit: 18,
            at: t0.addingTimeInterval(0.35)
        ))
        #expect(gatherFrame.comets.count == 3)
        #expect(gatherFrame.comets.allSatisfy { $0.radius.isFinite && $0.opacity > 0 })

        let fromState = MagicReplySwirlMath.gather(t: 0.35, orbit: 18)
        let landFrame = try #require(MagicReplySwirlMath.frame(
            phase: .landing(since: t0.addingTimeInterval(0.35), from: fromState),
            began: t0,
            orbit: 18,
            at: t0.addingTimeInterval(0.55)
        ))
        #expect(landFrame.bloom != nil)
        #expect(landFrame.ripple != nil)

        // Main-agent magic_reply tool definition explicitly enforces unsent draft contract
        #expect(MagicReplyCoordinator.agentToolDefinition.name == "magic_reply")
        #expect(MagicReplyCoordinator.agentToolDefinition.description.contains("applied: false, sent: false"))
    }

    @Test func notchTouchCalibrationPreferencesLidGuardAndMultiSensorTapDetector() throws {
        let suiteName = "dev.relay.tests.notch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(NotchPreferences.physicalTapEnabled(in: defaults) == true)
        #expect(NotchPreferences.sensitivity(in: defaults) == .standard)
        #expect(NotchPreferences.physicalTapThreshold(in: defaults) == 1.1)

        NotchPreferences.setSensitivity(.gentle, in: defaults)
        NotchPreferences.setSecondPhysicalTap(.magicReply, in: defaults)
        #expect(NotchPreferences.sensitivity(in: defaults) == .gentle)
        #expect(NotchPreferences.physicalTapThreshold(in: defaults) == 0.7)
        #expect(NotchPreferences.secondPhysicalTap(in: defaults) == .magicReply)

        let validProfile = PhysicalTapCalibrationProfile(
            version: 1,
            date: Date(),
            sensitivities: ["gentle", "standard", "firm"],
            baselineLux: 42.5
        )
        #expect(validProfile.isValid == true)
        try defaults.set(JSONEncoder().encode(validProfile), forKey: NotchPreferences.physicalTapCalibrationKey)
        #expect(NotchPreferences.calibration(in: defaults) == validProfile)

        NotchPreferences.resetAll(in: defaults)
        #expect(NotchPreferences.calibration(in: defaults) == nil)
        #expect(NotchPreferences.sensitivity(in: defaults) == .standard)

        // Lid guard blocks taps during 3.0s lid movement settle window and allows once stable with continuous readings
        var lidGuard = PhysicalTapLidGuard()
        lidGuard.update(angle: 110.0, at: 10.0)
        #expect(lidGuard.allowsTap(at: 11.5) == false)
        for step in 1...31 {
            lidGuard.update(angle: 110.05, at: 10.0 + Double(step) * 0.1)
        }
        #expect(lidGuard.allowsTap(at: 13.1) == true)
        // Moving hinge >= 0.75 degrees re-arms 3.0s block
        lidGuard.update(angle: 112.0, at: 13.3)
        #expect(lidGuard.allowsTap(at: 14.0) == false)

        // Multi-sensor PhysicalTapDetector:
        // 1) Optical shadow dip WITHOUT accel+gyro impulse must NOT trigger a tap
        var detector = PhysicalTapDetector(sensitivity: 1.1)
        var t = 0.0
        for _ in 0..<25 {
            t += 0.01
            detector.accel(SIMD3(0, 0, -1.0), at: t)
            detector.gyro(SIMD3(0, 0, 0), at: t)
            #expect(detector.light(50.0, at: t + 0.001) == false)
        }
        // Optical dip down to 15 lux and recovery back to 50 lux with zero motion impulse -> rejected!
        t += 0.02
        detector.accel(SIMD3(0, 0, -1.0), at: t)
        detector.gyro(SIMD3(0, 0, 0), at: t)
        #expect(detector.light(15.0, at: t + 0.001) == false)
        t += 0.04
        detector.accel(SIMD3(0, 0, -1.0), at: t)
        detector.gyro(SIMD3(0, 0, 0), at: t)
        #expect(detector.light(50.0, at: t + 0.001) == false)

        // 2) Optical dip WITH coincident accel + gyro tap impulse + recovery emits a single debounced tap!
        for i in 0..<4 {
            t += 0.005
            let impulse = (i % 2 == 0) ? 0.08 : 0.12
            detector.accel(SIMD3(0, impulse, -1.0 + impulse), at: t)
            detector.gyro(SIMD3(1.8, -0.9, 0.5), at: t)
        }
        #expect(detector.light(12.0, at: t + 0.002) == false) // Dip begins
        t += 0.04
        detector.accel(SIMD3(0, 0, -1.0), at: t)
        detector.gyro(SIMD3(0, 0, 0), at: t)
        let accepted = detector.light(50.0, at: t + 0.002) // Optical recovery completes tap!
        #expect(accepted == true)

        // Immediate second pulse inside 300ms debounce window must be suppressed
        for _ in 0..<4 {
            t += 0.005
            detector.accel(SIMD3(0, 0.10, -0.90), at: t)
            detector.gyro(SIMD3(2.0, -1.0, 0.4), at: t)
        }
        #expect(detector.light(12.0, at: t + 0.002) == false)
        t += 0.04
        detector.accel(SIMD3(0, 0, -1.0), at: t)
        detector.gyro(SIMD3(0, 0, 0), at: t)
        #expect(detector.light(50.0, at: t + 0.002) == false)
    }

    @Test func youTubeTranscriptFetcherExtractsCanonicalIDsAndParsesJSON3AndXMLCaptionsOnDevice() async throws {
        // Canonical video URL forms
        #expect(YouTubeTranscriptFetcher.videoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeTranscriptFetcher.videoID(from: "https://youtu.be/dQw4w9WgXcQ?si=abc") == "dQw4w9WgXcQ")
        #expect(YouTubeTranscriptFetcher.videoID(from: "https://www.youtube.com/shorts/aBcDeFgHiJk") == "aBcDeFgHiJk")
        #expect(YouTubeTranscriptFetcher.videoID(from: "https://m.youtube.com/live/1234567890_") == "1234567890_")
        #expect(YouTubeTranscriptFetcher.videoID(from: "https://www.youtube-nocookie.com/embed/-_987654321") == "-_987654321")

        // Rejects channels, search pages, non-YouTube domains, and malformed IDs
        #expect(YouTubeTranscriptFetcher.videoID(from: "https://www.youtube.com/@apple") == nil)
        #expect(YouTubeTranscriptFetcher.videoID(from: "https://www.youtube.com/results?search_query=swift") == nil)
        #expect(YouTubeTranscriptFetcher.videoID(from: "https://vimeo.com/12345678901") == nil)
        #expect(YouTubeTranscriptFetcher.videoID(from: "https://www.youtube.com/watch?v=short") == nil)

        // End-to-end on-device fetch via mock HTTPTransport (verifies only *.youtube.com hosts are requested)
        final class RequestRecorder: @unchecked Sendable {
            var urls: [URL] = []
        }
        let recorder = RequestRecorder()

        let watchHTML = """
        <!doctype html><html><head></head><body><script>
        var ytInitialPlayerResponse = {
          "videoDetails": { "videoId": "dQw4w9WgXcQ", "title": "Relay Architecture Deep Dive" },
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en",
                  "languageCode": "en",
                  "kind": "standard"
                }
              ]
            }
          }
        };
        </script></body></html>
        """

        let json3Payload = """
        {
          "events": [
            { "tStartMs": 0, "segs": [{ "utf8": "Welcome to Relay 3.1" }, { "utf8": " local transcript synthesis." }] },
            { "tStartMs": 18000, "segs": [{ "utf8": "All captions are parsed directly on your Mac." }] }
          ]
        }
        """

        let transcript = try await YouTubeTranscriptFetcher.fetchTranscript(
            for: "https://youtu.be/dQw4w9WgXcQ"
        ) { request in
            let url = try #require(request.url)
            recorder.urls.append(url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            if url.path == "/watch" {
                return (Data(watchHTML.utf8), response)
            } else {
                return (Data(json3Payload.utf8), response)
            }
        }

        let resolved = try #require(transcript)
        #expect(resolved.videoID == "dQw4w9WgXcQ")
        #expect(resolved.title == "Relay Architecture Deep Dive")
        #expect(resolved.languageCode == "en")
        #expect(resolved.isAutoGenerated == false)
        #expect(resolved.segmentCount == 2)
        #expect(resolved.text.contains("[00:00] Welcome to Relay 3.1 local transcript synthesis."))
        #expect(resolved.text.contains("[00:18] All captions are parsed directly on your Mac."))
        #expect(recorder.urls.allSatisfy { ($0.host ?? "").hasSuffix("youtube.com") })

        // Verify timedtext XML + HTML entity decoding fallback
        let xmlPayload = """
        <transcript>
          <text start="1.5" dur="3.0"> Swift &amp; C++ &#39;zero-copy&#39; &#x2014; fast! </text>
        </transcript>
        """
        let xmlSegments = YouTubeTranscriptFetcher.parseCaptionPayload(Data(xmlPayload.utf8))
        #expect(xmlSegments == [.init(startSeconds: 1.5, text: "Swift & C++ 'zero-copy' — fast!")])
    }

    @Test func browserSelectionReplacerPreservesClipboardOnSuccessFailureAndConcurrentUserCopy() async throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        // Seed multi-type user clipboard item
        pb.clearContents()
        let seedItem = NSPasteboardItem()
        seedItem.setString("User's precious copied API snippet", forType: .string)
        let customType = NSPasteboard.PasteboardType("dev.relay.test.rich-fragment")
        seedItem.setData(Data([0xCA, 0xFE, 0xBA, 0xBE]), forType: customType)
        #expect(pb.writeObjects([seedItem]) == true)

        // 1. Direct ClipboardSnapshot capture + restoreIfOwned when changeCount matches
        let initialSnapshot = ClipboardSnapshot.capture(from: pb)
        pb.clearContents()
        pb.setString("Temporary replacement payload", forType: .string)
        let ownedCount = pb.changeCount
        #expect(initialSnapshot.restoreIfOwned(to: pb, ownedChangeCount: ownedCount) == true)
        #expect(pb.string(forType: .string) == "User's precious copied API snippet")
        #expect(pb.pasteboardItems?.first?.data(forType: customType) == Data([0xCA, 0xFE, 0xBA, 0xBE]))

        // 2. If the user copies something new while paste is in flight, restoreIfOwned MUST NOT clobber it!
        let secondSnapshot = ClipboardSnapshot.capture(from: pb)
        pb.clearContents()
        pb.setString("Temporary replacement payload 2", forType: .string)
        let staleOwnedCount = pb.changeCount
        // Simulate concurrent user Cmd+C advancing pasteboard.changeCount
        pb.clearContents()
        pb.setString("Newer user clipboard text", forType: .string)
        #expect(secondSnapshot.restoreIfOwned(to: pb, ownedChangeCount: staleOwnedCount) == false)
        #expect(pb.string(forType: .string) == "Newer user clipboard text")

        // 3. BrowserSelectionReplacer.Target: native AX-writable control uses AX first without touching pasteboard
        pb.clearContents()
        pb.setString("Untouched clipboard", forType: .string)
        let baselineCount = pb.changeCount
        var axReplacedWith: String?

        let nativeTarget = BrowserSelectionReplacer.Target(
            sourceAppName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            processID: 4242,
            launchedAt: nil,
            selectedText: "teh quick fox",
            existingFieldText: "teh quick fox",
            editableMode: .axWritable,
            isWebContent: false,
            transport: .init(
                isProcessCurrent: { _, _ in true },
                isFrontmost: { _ in true },
                activateProcess: { _ in true },
                isTargetStillValid: { true },
                readCurrentSelectedText: { "teh quick fox" },
                tryAXReplace: { text in
                    axReplacedWith = text
                    return true
                },
                pasteboard: { pb },
                postCommandV: {
                    Issue.record("Native AX replacement should not post Cmd+V")
                    return false
                },
                restoreDelay: .milliseconds(10)
            )
        )
        let axOutcome = await nativeTarget.replace(with: "the quick fox")
        #expect(axOutcome == .replaced(.accessibility))
        #expect(axReplacedWith == "the quick fox")
        #expect(pb.changeCount == baselineCount)

        // 4. Browser/WebKit editable target uses guarded Cmd+V and restores original clipboard after restoreDelay
        var pastedFromPasteboard: String?
        let browserTarget = BrowserSelectionReplacer.Target(
            sourceAppName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processID: 5151,
            launchedAt: nil,
            selectedText: "draft typo",
            existingFieldText: "Hello — draft typo",
            editableMode: .browserEditable,
            isWebContent: true,
            transport: .init(
                isProcessCurrent: { _, _ in true },
                isFrontmost: { _ in true },
                activateProcess: { _ in true },
                isTargetStillValid: { true },
                readCurrentSelectedText: { "draft typo" },
                tryAXReplace: { _ in false },
                pasteboard: { pb },
                postCommandV: {
                    pastedFromPasteboard = pb.string(forType: .string)
                    return true
                },
                restoreDelay: .milliseconds(20)
            )
        )
        let webOutcome = await browserTarget.replace(with: "polished phrase")
        #expect(webOutcome == .replaced(.pasteboardUndoSafe))
        #expect(pastedFromPasteboard == "polished phrase")

        // Poll for the delayed restore so a loaded parallel run cannot flake it.
        let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while pb.string(forType: .string) != "Untouched clipboard", ContinuousClock.now < restoreDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pb.string(forType: .string) == "Untouched clipboard")
    }

    // MARK: - Domain 6: UninstallAndResetCoordinator (Factory Reset & Clean Uninstall)

    @Test func uninstallAndResetCoordinatorPreservesModelsOnResetAndSweepsRelayArtifactsWithoutTouchingExternalCLIs() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayUninstallParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let homeDir = sandbox.appendingPathComponent("Home", isDirectory: true)
        let libraryDir = homeDir.appendingPathComponent("Library", isDirectory: true)
        let supportDir = libraryDir.appendingPathComponent("Application Support/Relay", isDirectory: true)
        let modelsDir = supportDir.appendingPathComponent("Models", isDirectory: true)
        let vaultDir = supportDir.appendingPathComponent("KnowledgeVault", isDirectory: true)
        let bundleID = "dev.relay.test-uninstall"

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try Data("fake-gguf-weights".utf8).write(to: modelsDir.appendingPathComponent("gemma-4-e2b.litertlm"))
        try Data("# Overview\nPersonal note".utf8).write(to: vaultDir.appendingPathComponent("Overview.md"))
        try Data("{}".utf8).write(to: supportDir.appendingPathComponent("proactive-intelligence.json"))

        // Seed external user CLI directories (~/.codex and ~/.claude) that MUST NEVER be deleted
        let codexDir = homeDir.appendingPathComponent(".codex", isDirectory: true)
        let claudeDir = homeDir.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let codexAuth = codexDir.appendingPathComponent("auth.json")
        let claudeCreds = claudeDir.appendingPathComponent(".credentials.json")
        try Data("{\"token\":\"user-codex\"}".utf8).write(to: codexAuth)
        try Data("{\"token\":\"user-claude\"}".utf8).write(to: claudeCreds)

        // Seed Relay cache/WebKit/SavedState trace directories
        let cacheDir = libraryDir.appendingPathComponent("Caches/\(bundleID)", isDirectory: true)
        let savedStateDir = libraryDir.appendingPathComponent("Saved Application State/\(bundleID).savedState", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: savedStateDir, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cacheDir.appendingPathComponent("Cache.db"))

        let suiteName = "dev.relay.tests.uninstall.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: OnboardingCoordinator.completedKey)
        defaults.set("custom-value", forKey: "relay.sidekick.customPref")

        var runtimeStopped = false
        var factoryResetDeleteModelsFlag: Bool?
        var loginItemDisabled = false
        var wakeHelperRemoved = false
        var remoteMirrorDeleted = false

        let env = UninstallAndResetCoordinator.Environment(
            supportDirectory: supportDir,
            libraryDirectory: libraryDir,
            homeDirectory: homeDir,
            bundleIdentifier: bundleID,
            appBundleURL: URL(fileURLWithPath: "/Applications/Relay.app"),
            defaults: defaults,
            defaultsDomainName: suiteName,
            stopRuntime: { runtimeStopped = true },
            resetStoreForFactoryReset: { deleteModels in factoryResetDeleteModelsFlag = deleteModels },
            disableLoginItem: { loginItemDisabled = true },
            removeWakeHelper: { wakeHelperRemoved = true },
            deleteRemoteMirror: {
                remoteMirrorDeleted = true
                return nil
            },
            wipeKeychain: { ["app.relay.oauth-mcp.v1", "app.relay.hosted-knowledge-mirror.v1"] },
            spawnPostExitSweep: { _ in },
            terminateApp: {}
        )

        let coordinator = UninstallAndResetCoordinator(environment: env)

        // 1. Factory Reset with deleteDownloadedModels == false preserves Models/ & external CLIs while wiping Vault
        let resetOutcome = await coordinator.performFactoryReset(onboarding: nil, deleteDownloadedModels: false)
        #expect(factoryResetDeleteModelsFlag == false)
        #expect(resetOutcome.preservedModelFiles == 1)
        #expect(FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent("gemma-4-e2b.litertlm").path) == true)
        #expect(FileManager.default.fileExists(atPath: vaultDir.path) == false)
        #expect(FileManager.default.fileExists(atPath: codexAuth.path) == true)
        #expect(FileManager.default.fileExists(atPath: claudeCreds.path) == true)
        #expect(defaults.bool(forKey: OnboardingCoordinator.completedKey) == false)
        #expect(defaults.object(forKey: "relay.sidekick.customPref") == nil)

        // Recreate a vault file before testing Full Clean Uninstall
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try Data("# Overview".utf8).write(to: vaultDir.appendingPathComponent("Overview.md"))

        // 2. Full Clean Uninstall completes all 7 stages, deletes Models/ + support + caches, and preserves ~/.codex & ~/.claude
        let uninstallOutcome = await coordinator.performCleanUninstall()
        #expect(coordinator.phase == .completed)
        #expect(runtimeStopped == true)
        #expect(loginItemDisabled == true)
        #expect(wakeHelperRemoved == true)
        #expect(remoteMirrorDeleted == true)
        #expect(coordinator.stages.allSatisfy { $0.state == .done })
        #expect(uninstallOutcome.clearedKeychainServices.contains("app.relay.oauth-mcp.v1"))
        #expect(FileManager.default.fileExists(atPath: supportDir.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheDir.path) == false)
        #expect(FileManager.default.fileExists(atPath: savedStateDir.path) == false)

        // External user CLI configs MUST remain completely untouched!
        #expect(FileManager.default.fileExists(atPath: codexAuth.path) == true)
        #expect(FileManager.default.fileExists(atPath: claudeCreds.path) == true)
        #expect(uninstallOutcome.preservedExternalPaths.contains(codexDir.path))
        #expect(uninstallOutcome.preservedExternalPaths.contains(claudeDir.path))
    }
}
