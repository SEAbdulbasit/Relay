import AppKit
import Foundation
import SQLite3
import Testing
@testable import Relay
@testable import RelayJournal

@MainActor @Suite(.serialized) struct AuditRoadmapVerificationTests {

    // MARK: - [P0-SEC-01] Keychain Service Constant Parity & Prefix Sweep

    @Test func knownRelayKeychainServicesContainsAllActiveRelayKeychainServiceConstants() {
        let services = Set(UninstallAndResetCoordinator.knownRelayKeychainServices)
        #expect(services.contains(KeychainOAuthGrantStore.defaultService))
        #expect(KeychainOAuthGrantStore.defaultService == "com.relay.oauth-mcp.grants")
        #expect(services.contains(MagicReplyKeychain.service))
        #expect(MagicReplyKeychain.service == "com.relay.macos.magicreply")
        #expect(services.contains(OpenRouterCredentials.service))
        #expect(services.contains(CustomResponsesCredentials.serviceName))

        var deletedQueries: [[String: Any]] = []
        let swept = UninstallAndResetCoordinator.deleteRelayKeychainEntries(
            deleteItem: { query in
                deletedQueries.append(query)
                return errSecSuccess
            },
            copyItems: { _, resultPtr in
                let mockItems: [[String: Any]] = [
                    [kSecAttrService as String: "com.relay.custom-plugin.token", kSecAttrAccount as String: "acc1"],
                    [kSecAttrService as String: "com.thirdparty.unrelated", kSecAttrAccount as String: "acc2"]
                ]
                resultPtr.pointee = mockItems as CFArray
                return errSecSuccess
            }
        )

        #expect(swept.contains(KeychainOAuthGrantStore.defaultService))
        #expect(swept.contains(MagicReplyKeychain.service))
        #expect(swept.contains(OpenRouterCredentials.service))
        #expect(swept.contains(CustomResponsesCredentials.serviceName))
        #expect(swept.contains("com.relay.custom-plugin.token"))
        #expect(!swept.contains("com.thirdparty.unrelated"))
    }

    // MARK: - [P0-DESIGN-01] & [P1-DESIGN-02] RelayColors.resolvedNSColor & Light Mode Elevation

    @Test func resolvedNSColorNeverMutatesUserDefaultsOrFiresDidChangeNotifications() throws {
        let defaults = UserDefaults.standard
        let originalRaw = defaults.string(forKey: RelayAppearanceMode.storageKey)
        defer {
            if let originalRaw {
                defaults.set(originalRaw, forKey: RelayAppearanceMode.storageKey)
            } else {
                defaults.removeObject(forKey: RelayAppearanceMode.storageKey)
            }
        }

        defaults.set(RelayAppearanceMode.dark.rawValue, forKey: RelayAppearanceMode.storageKey)

        final class NotificationCounter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
        }
        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let darkCanvas = RelayColors.resolvedNSColor(RelayColors.canvas, for: .dark)
        let lightCanvas = RelayColors.resolvedNSColor(RelayColors.canvas, for: .light)
        let darkPitch = RelayColors.resolvedNSColor(RelayColors.pitch, for: .dark)
        let lightPitch = RelayColors.resolvedNSColor(RelayColors.pitch, for: .light)
        let lightCard = RelayColors.resolvedNSColor(RelayColors.cardBG, for: .light)
        let lightSurface = RelayColors.resolvedNSColor(RelayColors.surface, for: .light)
        let lightSurfaceElevated = RelayColors.resolvedNSColor(RelayColors.surfaceElevated, for: .light)

        #expect(counter.count == 0, "RelayColors.resolvedNSColor must never mutate UserDefaults during color resolution")
        #expect(defaults.string(forKey: RelayAppearanceMode.storageKey) == RelayAppearanceMode.dark.rawValue)

        func luminance(_ color: NSColor) throws -> CGFloat {
            let srgb = try #require(color.usingColorSpace(.sRGB))
            return 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
        }

        let darkCanvasLum = try luminance(darkCanvas)
        let lightCanvasLum = try luminance(lightCanvas)
        let darkPitchLum = try luminance(darkPitch)
        let lightPitchLum = try luminance(lightPitch)
        let lightCardLum = try luminance(lightCard)
        let lightSurfaceLum = try luminance(lightSurface)
        let lightSurfaceElevatedLum = try luminance(lightSurfaceElevated)

        #expect(darkPitchLum < darkCanvasLum)
        #expect(lightPitchLum > 0.88)
        #expect(lightPitchLum < lightCanvasLum, "Light mode pitch (#F0F2F6) must be darker than canvas (#F7F8FA)")
        #expect(lightCanvasLum < lightCardLum, "Light mode canvas (#F7F8FA) must be darker than cardBG (#FFFFFF)")
        #expect(lightSurfaceLum < lightSurfaceElevatedLum, "Light mode surface (#F2F4F7) must be darker than surfaceElevated (#FFFFFF)")
    }

    // MARK: - [P1-SEC-02] MagicReplyEndpointValidator Loopback-Only HTTP Enforcement

    @Test func magicReplyEndpointValidatorRejectsNonLoopbackPlaintextHTTP() {
        // Loopback HTTP is permitted for local inference servers (e.g. LM Studio / local proxies)
        #expect(MagicReplyEndpointValidator.endpoint(from: "http://127.0.0.1:1234/v1") != nil)
        #expect(MagicReplyEndpointValidator.endpoint(from: "http://localhost:1234/v1") != nil)
        #expect(MagicReplyEndpointValidator.endpoint(from: "http://[::1]:1234/v1") != nil)

        // Remote HTTPS is permitted
        #expect(MagicReplyEndpointValidator.endpoint(from: "https://openrouter.ai/api/v1") != nil)
        #expect(MagicReplyEndpointValidator.endpoint(from: "https://api.openai.com/v1", api: .responses)?.absoluteString == "https://api.openai.com/v1/responses")

        // Remote or LAN plaintext HTTP must be rejected to prevent bearer token leakage
        #expect(MagicReplyEndpointValidator.endpoint(from: "http://openrouter.ai/api/v1") == nil)
        #expect(MagicReplyEndpointValidator.endpoint(from: "http://192.168.1.50:1234/v1") == nil)
        #expect(MagicReplyEndpointValidator.endpoint(from: "http://10.0.0.12:8080/v1") == nil)
        #expect(MagicReplyEndpointValidator.endpoint(from: "http://example.com/v1") == nil)
    }

    // MARK: - [P0-STATE-01] Multi-Thread Model History Continuity, Reply Lookup Fallback, Pin & Rename

    @Test func threadSwitchingPreservesModelMessagesAndSupportsFallbackReplyAndPinRename() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "relay-audit-thread-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var capturedSubmittedHistories: [[ModelMessage]] = []
        let persistenceURL = root.appending(path: "history.sqlite")
        let store = AssistantStore(persistenceURL: persistenceURL, complete: { messages, _, _ in
            capturedSubmittedHistories.append(messages)
            return ModelReply(content: "Ack turn \(messages.count)", toolCalls: [])
        })

        // Thread 1: populate conversation turns
        let t1User = ChatMessage(role: "user", text: "Design the Relay 2.0 security architecture.")
        let t1Assistant = ChatMessage(role: "assistant", text: "We use 0600 local files, Keychain grants, and loopback-only HTTP.")
        store.messages = [t1User, t1Assistant]
        let thread1ID = store.activeThreadID

        // Start Thread 2 (clears active SQLite journal generation)
        store.startNewThread()
        await store.waitForConversationTaskToSettle()
        let thread2ID = store.activeThreadID
        #expect(thread2ID != thread1ID)
        #expect(store.messages.isEmpty)

        let t2User = ChatMessage(role: "user", text: "Check my Tuesday calendar.")
        let t2Assistant = ChatMessage(role: "assistant", text: "You have a design critique at 10 AM.")
        store.messages = [t2User, t2Assistant]

        // Switch back to Thread 1
        #expect(store.selectThread(thread1ID) == true)
        #expect(store.activeThreadID == thread1ID)
        #expect(store.messages.map(\.id) == [t1User.id, t1Assistant.id])

        // 1) Verify reply/quote lookup succeeds on Thread 1 even after startNewThread rotated the journal
        let quoteRange = NSRange(location: 0, length: "We use 0600 local files".utf16.count)
        let replyPrepared = await store.prepareConversationReply(to: t1Assistant.id, selectedRange: quoteRange)
        #expect(replyPrepared == true)
        #expect(store.pendingReply?.snapshot == "We use 0600 local files")

        // 2) Verify follow-up turn on Thread 1 includes Thread 1's prior turns in modelMessages sent to the model
        store.clearConversationReply()
        store.draft = "Expand on the Keychain grant cleanup."
        _ = store.submitComposerMessage()
        await store.waitForConversationTaskToSettle()

        let lastHistory = try #require(capturedSubmittedHistories.last)
        #expect(lastHistory.contains(where: { $0.role == "user" && $0.content.contains("Design the Relay 2.0 security architecture.") }))
        #expect(lastHistory.contains(where: { $0.role == "assistant" && $0.content.contains("We use 0600 local files") }))

        // 3) Verify renameThread and togglePinThread sort pinned threads first and persist
        #expect(store.renameThread(id: thread1ID, title: "Security Architecture Spec") == true)
        #expect(store.threadArchive.thread(for: thread1ID)?.title == "Security Architecture Spec")
        #expect(store.threadArchive.thread(for: thread1ID)?.hasCustomTitle == true)

        #expect(store.togglePinThread(id: thread1ID) == true)
        #expect(store.threadArchive.thread(for: thread1ID)?.isPinned == true)
        #expect(store.threadArchive.threads.first?.id == thread1ID)
    }

    // MARK: - [P0-CONC-01] AgentDesktopProcessRunner EOF Drain & [P2-ERR-01] SQLite PRAGMA Table Identifier Guard

    @Test func processRunnerDrainsOutputUntilEOFAndSQLiteReaderValidatesTableIdentifiers() async throws {
        // Verify multi-line output drains completely after process exit
        let result = try await AgentDesktopProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'line1\\nline2\\nline3'"],
            timeoutSeconds: 5,
            outputLimit: 65_536
        )
        #expect(result.exitStatus == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "line1\nline2\nline3")

        // Verify LiveSourceSQLite.Reader.tableColumns rejects injection / non-identifier characters
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-pragma-guard-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempDB) }

        var rawDB: OpaquePointer?
        #expect(sqlite3_open(tempDB.path, &rawDB) == SQLITE_OK)
        _ = sqlite3_exec(rawDB, "CREATE TABLE valid_table_1 (id INTEGER PRIMARY KEY, body TEXT);", nil, nil, nil)
        sqlite3_close(rawDB)

        let reader = try LiveSourceSQLite.Reader(path: tempDB.path)
        #expect(reader.tableColumns("valid_table_1") == Set(["id", "body"]))
        #expect(reader.tableColumns("valid_table_1; DROP TABLE valid_table_1;--").isEmpty)
        #expect(reader.tableColumns("table-with-dash").isEmpty)
        #expect(reader.tableColumns("").isEmpty)
    }

    // MARK: - [P1-PERF-01] PluggedInAnalysisScheduler Guard & [P2-FEAT-08] Partial Selection Proofread

    @Test func schedulerSkipsProvidersWhenDisabledAndHomeDraftProofreadRespectsSelectedRange() async throws {
        var powerCalls = 0
        var idleCalls = 0
        let root = FileManager.default.temporaryDirectory
            .appending(path: "relay-scheduler-guard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scheduler = PluggedInAnalysisScheduler(
            persistenceURL: root.appending(path: "scheduler.json"),
            automaticPolling: false,
            powerProvider: {
                powerCalls += 1
                return .init(onACPower: true, batteryPercent: 100, lowPowerMode: false, thermalState: .nominal)
            },
            idleSecondsProvider: {
                idleCalls += 1
                return 900
            }
        )
        #expect(scheduler.enabled == false)
        scheduler.evaluateTick()
        #expect(powerCalls == 0, "Disabled scheduler must not poll powerProvider on background ticks")
        #expect(idleCalls == 0, "Disabled scheduler must not poll idleSecondsProvider on background ticks")

        // Verify partial selection proofreading replaces only the selected range in Home composer draft
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            ModelReply(content: #"{"corrected_text":"polished middle clause"}"#, toolCalls: [])
        })
        store.draft = "Keep prefix intact: rough mid clause :Keep suffix intact."
        let targetSubstring = "rough mid clause"
        let nsDraft = store.draft as NSString
        let selectedRange = nsDraft.range(of: targetSubstring)
        #expect(selectedRange.location != NSNotFound)

        let token = try #require(store.captureHomeComposerDraftForProofread(selectedRange: selectedRange))
        #expect(store.hasPreparedHomeDraft(token))
        let succeeded = await store.proofreadHomeDraft(handoffToken: token)
        #expect(succeeded == true)
        #expect(store.draft == "Keep prefix intact: polished middle clause :Keep suffix intact.")
    }

    // MARK: - [DESIGN-11] & [DESIGN-04] Dark Mode textDim Contrast Ratio & RelayTheme.accent Parity

    @Test func darkModeTextDimMeetsContrastThresholdAndRelayThemeAccentResolvesToAccentBlue() throws {
        func srgbRelativeLuminance(_ color: NSColor) throws -> Double {
            let srgb = try #require(color.usingColorSpace(.sRGB))
            func linearize(_ c: CGFloat) -> Double {
                let v = Double(c)
                return v <= 0.04045 ? (v / 12.92) : pow((v + 0.055) / 1.055, 2.4)
            }
            let r = linearize(srgb.redComponent)
            let g = linearize(srgb.greenComponent)
            let b = linearize(srgb.blueComponent)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        func contrastRatio(_ fg: NSColor, _ bg: NSColor) throws -> Double {
            let l1 = try srgbRelativeLuminance(fg)
            let l2 = try srgbRelativeLuminance(bg)
            let lighter = max(l1, l2)
            let darker = min(l1, l2)
            return (lighter + 0.05) / (darker + 0.05)
        }

        let darkTextDim = RelayColors.resolvedNSColor(RelayColors.textDim, for: .dark)
        let darkCanvas = RelayColors.resolvedNSColor(RelayColors.canvas, for: .dark)
        let darkSurface = RelayColors.resolvedNSColor(RelayColors.surface, for: .dark)

        let canvasContrast = try contrastRatio(darkTextDim, darkCanvas)
        let surfaceContrast = try contrastRatio(darkTextDim, darkSurface)

        #expect(canvasContrast > 3.1, "Dark mode RelayColors.textDim contrast against RelayColors.canvas (\(canvasContrast)) must exceed 3.1:1")
        #expect(surfaceContrast > 3.1, "Dark mode RelayColors.textDim contrast against RelayColors.surface (\(surfaceContrast)) must exceed 3.1:1")

        for mode in [RelayAppearanceMode.dark, RelayAppearanceMode.light] {
            let themeAccent = try #require(RelayColors.resolvedNSColor(RelayTheme.accent, for: mode).usingColorSpace(.sRGB))
            let blueAccent = try #require(RelayColors.resolvedNSColor(RelayColors.accentBlue, for: mode).usingColorSpace(.sRGB))
            #expect(abs(themeAccent.redComponent - blueAccent.redComponent) < 0.0001)
            #expect(abs(themeAccent.greenComponent - blueAccent.greenComponent) < 0.0001)
            #expect(abs(themeAccent.blueComponent - blueAccent.blueComponent) < 0.0001)
            #expect(abs(themeAccent.alphaComponent - blueAccent.alphaComponent) < 0.0001)
        }

        // Verify RelayColors.borderFocus is a neutral monochrome hairline (no blue focus outline)
        let darkFocus = try #require(RelayColors.resolvedNSColor(RelayColors.borderFocus, for: .dark).usingColorSpace(.sRGB))
        #expect(abs(darkFocus.redComponent - 1.0) < 0.0001)
        #expect(abs(darkFocus.greenComponent - 1.0) < 0.0001)
        #expect(abs(darkFocus.blueComponent - 1.0) < 0.0001)
        #expect(abs(darkFocus.alphaComponent - 0.24) < 0.0001)

        let lightFocus = try #require(RelayColors.resolvedNSColor(RelayColors.borderFocus, for: .light).usingColorSpace(.sRGB))
        #expect(abs(lightFocus.redComponent - (17.0 / 255.0)) < 0.001)
        #expect(abs(lightFocus.greenComponent - (19.0 / 255.0)) < 0.001)
        #expect(abs(lightFocus.blueComponent - (24.0 / 255.0)) < 0.001)
        #expect(abs(lightFocus.alphaComponent - 0.22) < 0.0001)
    }

    // MARK: - Rich Markdown Code Block Segment Parser Verification

    @Test func transcriptMarkdownSegmentParserSplitsMixedProseAndFencedCodeBlocks() {
        let sample = """
        Here is a quick overview with **inline markdown**:

        ```Swift
        struct Greeting {
            let message = "Hello, Relay!"
        }
        ```

        And an untagged shell snippet below:

        ```
        swift test --filter AuditRoadmapVerificationTests
        ```

        Final closing prose summary.
        """

        let segments = TranscriptMarkdownSegment.parse(sample)
        #expect(segments.count == 5)

        #expect(segments[0] == .prose("Here is a quick overview with **inline markdown**:"))
        #expect(segments[0].isCodeBlock == false)
        #expect(segments[0].language == nil)

        #expect(segments[1] == .codeBlock(
            language: "swift",
            code: """
            struct Greeting {
                let message = "Hello, Relay!"
            }
            """
        ))
        #expect(segments[1].isCodeBlock == true)
        #expect(segments[1].language == "swift")

        #expect(segments[2] == .prose("And an untagged shell snippet below:"))

        #expect(segments[3] == .codeBlock(
            language: "code",
            code: "swift test --filter AuditRoadmapVerificationTests"
        ))
        #expect(segments[3].isCodeBlock == true)
        #expect(segments[3].language == "code")

        #expect(segments[4] == .prose("Final closing prose summary."))
    }

    // MARK: - [P3-FEAT-NEXT-01] Clipboard Image Paste & [P3-FEAT-NEXT-02] Closed-Loop Workspace Composer Handoff

    @Test func pasteClipboardImageIfAvailableLoadsIsolatedPasteboardImageAndRejectsTextOnlyPasteboard() async throws {
        let store = AssistantStore(persistenceURL: nil)
        let isolatedPB = NSPasteboard.withUniqueName()
        defer { isolatedPB.releaseGlobally() }

        // 1) Empty pasteboard -> false
        isolatedPB.clearContents()
        #expect(store.pasteClipboardImageIfAvailable(from: isolatedPB) == false)
        #expect(store.showImageInspection == false)
        #expect(store.imageInspection.image == nil)

        // 2) Text-only pasteboard -> false
        isolatedPB.clearContents()
        isolatedPB.setString("plain text clipboard payload", forType: .string)
        #expect(store.pasteClipboardImageIfAvailable(from: isolatedPB) == false)
        #expect(store.showImageInspection == false)
        #expect(store.imageInspection.image == nil)

        // 3) Valid PNG image data on isolated pasteboard -> true, populates imageInspection & showImageInspection
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()

        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))

        isolatedPB.clearContents()
        isolatedPB.setData(pngData, forType: .png)

        let loaded = store.pasteClipboardImageIfAvailable(from: isolatedPB)
        #expect(loaded == true)
        #expect(store.showImageInspection == true)
        for _ in 0..<200 where store.imageInspection.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.imageInspection.isBusy == false)
        #expect(store.imageInspection.image != nil)
        #expect((store.imageInspection.image?.jpeg.count ?? 0) > 0)
    }

    @Test func handoffToWorkspaceComposerPopulatesDraftWithTitleAndBounded4KBExcerpt() {
        let store = AssistantStore(persistenceURL: nil)

        // Short context text stays intact
        store.handoffToWorkspaceComposer(
            title: "Q4 Architecture Summary",
            contextText: "Key takeaway: 0600 local files and loopback-only HTTP.",
            promptPrefix: "Ask a follow-up about"
        )
        #expect(store.draft == "Ask a follow-up about “Q4 Architecture Summary”:\n\nKey takeaway: 0600 local files and loopback-only HTTP.\n\n")

        // Oversized context text (> 4,000 UTF-8 bytes) is safely truncated at character boundary <= 4,000 UTF-8 bytes
        let oversizedContext = String(repeating: "Relay🔒", count: 900) // 9 bytes * 900 = 8,100 bytes
        #expect(oversizedContext.utf8.count > 4_000)

        store.handoffToWorkspaceComposer(
            title: "Large Transcript",
            contextText: oversizedContext
        )

        let prefix = "Follow up on “Large Transcript”:\n\n"
        let suffix = "\n\n"
        #expect(store.draft.hasPrefix(prefix))
        #expect(store.draft.hasSuffix(suffix))

        let excerptStart = store.draft.index(store.draft.startIndex, offsetBy: prefix.count)
        let excerptEnd = store.draft.index(store.draft.endIndex, offsetBy: -suffix.count)
        let excerpt = String(store.draft[excerptStart..<excerptEnd])
        #expect(excerpt.utf8.count <= 4_000)
        #expect(excerpt.utf8.count > 3_990)
        #expect(oversizedContext.hasPrefix(excerpt))
    }

    // MARK: - [ARCH-BUG-01] relay-live:// Indexing, Correspondence Attribution & SkyGraph URL Preservation

    @Test func relayLiveRecordsAreIndexedAndClassifiedAsCorrespondenceAndPreservedInSkyGraph() {
        let now = Date(timeIntervalSince1970: 1_763_500_000)
        let liveIMessageRecord = KnowledgeRecord(
            sourcePath: "relay-live://imessage/chat-42",
            title: "Alex Rivera",
            text: "Hey, can we move our 3 PM architecture sync to 4 PM?",
            modifiedAt: now,
            contentHash: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            byteCount: 54
        )
        let liveGroupRecord = KnowledgeRecord(
            sourcePath: "relay-live://imessage/group-99",
            title: "Relay Design Group",
            text: "Participants: Alex, Sam, Taylor\nLet's finalize the obsidian notch palette.",
            modifiedAt: now,
            contentHash: "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
            byteCount: 74
        )
        let liveMailRecord = KnowledgeRecord(
            sourcePath: "relay-live://apple_mail/message-108",
            title: "Q4 Security Audit Report",
            text: "Attached is the signed security audit checklist.",
            modifiedAt: now,
            contentHash: "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
            byteCount: 48
        )
        let liveNotesRecord = KnowledgeRecord(
            sourcePath: "relay-live://apple_notes/note-7",
            title: "Personal OKRs",
            text: "Ship Wave 7 with zero light-mode leaks.",
            modifiedAt: now,
            contentHash: "d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5",
            byteCount: 39
        )

        // 1) SemanticKnowledgeSearch.makeChunks indexes relay-live:// records
        let batch = SemanticKnowledgeSearch.makeChunks([
            liveIMessageRecord,
            liveGroupRecord,
            liveMailRecord,
            liveNotesRecord
        ])
        #expect(batch.considered == 4)
        #expect(batch.partial == false)
        let chunkPaths = Set(batch.chunks.map(\.path))
        #expect(chunkPaths.contains("relay-live://imessage/chat-42"))
        #expect(chunkPaths.contains("relay-live://imessage/group-99"))
        #expect(chunkPaths.contains("relay-live://apple_mail/message-108"))
        #expect(chunkPaths.contains("relay-live://apple_notes/note-7"))

        // 2) SemanticVaultBuilder.inferAttributionRole classifies iMessage & Apple Mail as correspondence
        let dmRole = SemanticVaultBuilder.inferAttributionRole(
            path: liveIMessageRecord.sourcePath,
            title: liveIMessageRecord.title,
            text: liveIMessageRecord.text
        )
        #expect(dmRole == .directCorrespondence)
        #expect(dmRole != .userAuthored)

        let groupRole = SemanticVaultBuilder.inferAttributionRole(
            path: liveGroupRecord.sourcePath,
            title: liveGroupRecord.title,
            text: liveGroupRecord.text
        )
        #expect(groupRole == .groupThread)
        #expect(groupRole != .userAuthored)

        let mailRole = SemanticVaultBuilder.inferAttributionRole(
            path: liveMailRecord.sourcePath,
            title: liveMailRecord.title,
            text: liveMailRecord.text
        )
        #expect(mailRole == .directCorrespondence)
        #expect(mailRole != .userAuthored)

        let notesRole = SemanticVaultBuilder.inferAttributionRole(
            path: liveNotesRecord.sourcePath,
            title: liveNotesRecord.title,
            text: liveNotesRecord.text
        )
        #expect(notesRole == .userAuthored)

        // 3) SkyGraph.build preserves relay-live:// URLs rather than mangling into file:/// paths
        let skyGraph = SkyGraph.build(records: [liveIMessageRecord, liveMailRecord])
        let nodeURLs = Set(skyGraph.nodes.map(\.url.absoluteString))
        #expect(nodeURLs.contains("relay-live://imessage/chat-42"))
        #expect(nodeURLs.contains("relay-live://apple_mail/message-108"))
    }

    // MARK: - [PERF-04] GeneratedKnowledgeVault.boundedUTF8 Multi-Byte UTF-8 Character Boundary Slicing

    @Test func boundedUTF8SlicesMultiByteTextAtValidCharacterBoundaries() {
        #expect(GeneratedKnowledgeVault.boundedUTF8("", limit: 16) == "")
        #expect(GeneratedKnowledgeVault.boundedUTF8("Relay", limit: 0) == "")
        #expect(GeneratedKnowledgeVault.boundedUTF8("Relay", limit: 10) == "Relay")

        // "é" is 2 UTF-8 bytes (0xC3 0xA9), "🔒" is 4 UTF-8 bytes (0xF0 0x9F 0x94 0x92), "日" is 3 UTF-8 bytes
        let sample = "Aé🔒日B" // byte offsets: A(1), é(2..3), 🔒(4..7), 日(8..10), B(11)
        #expect(sample.utf8.count == 11)

        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 1) == "A")
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 2) == "A")   // mid 2-byte 'é' -> walks back to "A"
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 3) == "Aé")
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 4) == "Aé")  // 1 byte into 4-byte '🔒'
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 5) == "Aé")  // 2 bytes into 4-byte '🔒'
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 6) == "Aé")  // 3 bytes into 4-byte '🔒'
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 7) == "Aé🔒")
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 8) == "Aé🔒") // 1 byte into 3-byte '日'
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 9) == "Aé🔒") // 2 bytes into 3-byte '日'
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 10) == "Aé🔒日")
        #expect(GeneratedKnowledgeVault.boundedUTF8(sample, limit: 11) == "Aé🔒日B")
    }

    // MARK: - [UX-02] Edit Earlier User Messages & Regenerate Assistant Responses

    @Test func editUserMessageAndBranchAndRegenerateAssistantMessageTruncateHistoryAndSeedDraft() {
        let store = AssistantStore(persistenceURL: nil)

        let u1 = ChatMessage(role: "user", text: "First question")
        let a1 = ChatMessage(role: "assistant", text: "First answer")
        let u2 = ChatMessage(role: "user", text: "Second question")
        let a2 = ChatMessage(role: "assistant", text: "Second answer")
        let u3 = ChatMessage(role: "user", text: "Third question")
        let a3 = ChatMessage(role: "assistant", text: "Third answer")

        store.messages = [u1, a1, u2, a2, u3, a3]

        // 1) Regenerate assistant message a3 -> truncates before u3 and seeds draft with u3.text
        let regenerated = store.regenerateAssistantMessage(id: a3.id)
        #expect(regenerated == true)
        #expect(store.messages.map(\.id) == [u1.id, a1.id, u2.id, a2.id])
        #expect(store.draft == "Third question")

        // 2) Edit earlier user message u2 without auto-submitting -> truncates to [u1, a1] and seeds draft
        let edited = store.editUserMessageAndBranch(
            id: u2.id,
            newText: "Second question (revised)",
            autoSubmit: false
        )
        #expect(edited == true)
        #expect(store.messages.map(\.id) == [u1.id, a1.id])
        #expect(store.draft == "Second question (revised)")

        // Non-existent or assistant ID on editUserMessageAndBranch returns false without mutating
        #expect(store.editUserMessageAndBranch(id: a1.id, newText: "Should fail", autoSubmit: false) == false)
        #expect(store.messages.map(\.id) == [u1.id, a1.id])
    }

    // MARK: - [UI-03] Markdown Table & Nested List Indentation Parsing in MainView

    @Test func mainViewParseProseBlocksParsesMarkdownTablesAndNestedListIndentation() {
        let markdown = """
        # Architecture Overview

        | Component | Latency | Status |
        | :--- | :---: | ---: |
        | Notch HUD | 1.2ms | Ready |
        | Vault Search | 4.8ms | Indexed |

        - Top level bullet
          - Two-space nested bullet
            - Four-space nested bullet
        1. First step
           1. Nested numbered step
        """

        let blocks = MainView.parseProseBlocks(markdown)
        #expect(blocks.count == 7)

        #expect(blocks[0] == .heading(level: 1, text: "Architecture Overview"))
        #expect(blocks[1] == .table(
            headers: ["Component", "Latency", "Status"],
            rows: [
                ["Notch HUD", "1.2ms", "Ready"],
                ["Vault Search", "4.8ms", "Indexed"]
            ]
        ))
        #expect(blocks[2] == .bulletItem(indent: 0, text: "Top level bullet"))
        #expect(blocks[3] == .bulletItem(indent: 1, text: "Two-space nested bullet"))
        #expect(blocks[4] == .bulletItem(indent: 2, text: "Four-space nested bullet"))
        #expect(blocks[5] == .numberedItem(indent: 0, number: "1.", text: "First step"))
        #expect(blocks[6] == .numberedItem(indent: 1, number: "1.", text: "Nested numbered step"))
    }
}
