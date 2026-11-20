import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Grounded one-time Welcome Letter & Exportable Keepsake Card (`PRO-11`).
///
/// Synthesizes a warm, strictly factual first-analysis welcome note from real cross-domain
/// notes in `KnowledgeVault/`. Never fabricates patterns when vault evidence is sparse,
/// never writes stray files into `KnowledgeVault/`, and exports the exact user-reviewed text
/// as a `@2x` PNG keepsake card without overwriting existing files.
public struct WelcomeKeepsake: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kicker: String
    public var title: String
    public var recipientName: String?
    public var bodyMarkdown: String
    public var groundedNoteTitles: [String]
    public var createdAt: Date
    public var isOpened: Bool
    public var isRetired: Bool

    public init(
        id: UUID = UUID(),
        kicker: String = "From your first vault synthesis",
        title: String = "What stands out across your notes",
        recipientName: String? = nil,
        bodyMarkdown: String,
        groundedNoteTitles: [String] = [],
        createdAt: Date = Date(),
        isOpened: Bool = false,
        isRetired: Bool = false
    ) {
        self.id = id
        self.kicker = kicker
        self.title = title
        self.recipientName = recipientName
        self.bodyMarkdown = bodyMarkdown
        self.groundedNoteTitles = groundedNoteTitles
        self.createdAt = createdAt
        self.isOpened = isOpened
        self.isRetired = isRetired
    }
}

@Observable @MainActor
public final class WelcomeKeepsakeGenerator {
    public static let shared = WelcomeKeepsakeGenerator()
    typealias ModelCompletion = ([ModelMessage]) async throws -> ModelReply

    public enum GenerationOutcome: Sendable, Equatable {
        case created(WelcomeKeepsake)
        case alreadyCreated(WelcomeKeepsake)
        case alreadyRetired
        case insufficientEvidence
    }

    public enum Failure: LocalizedError, Equatable {
        case busy
        case renderFailed
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .busy:
                return "Welcome keepsake synthesis is already running."
            case .renderFailed:
                return "Could not render the keepsake card image."
            case .exportFailed(let detail):
                return "Could not save the keepsake image: \(detail)"
            }
        }
    }

    private struct PersistedState: Codable, Equatable {
        var keepsake: WelcomeKeepsake?
        var hasConsumedEligibility: Bool
    }

    public private(set) var keepsake: WelcomeKeepsake?
    public private(set) var isGenerating = false
    public private(set) var status = ""

    @ObservationIgnored private let vaultRootProvider: @MainActor () -> URL
    @ObservationIgnored private let persistenceURL: URL
    @ObservationIgnored private var hasConsumedEligibility = false
    @ObservationIgnored private var activeTask: Task<GenerationOutcome, Error>?

    public init(vaultRoot: URL? = nil, persistenceURL: URL? = nil) {
        if let vaultRoot {
            self.vaultRootProvider = { vaultRoot }
        } else {
            self.vaultRootProvider = { KnowledgeVaultManager.shared.vaultDirectory }
        }
        if let persistenceURL {
            self.persistenceURL = persistenceURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
            self.persistenceURL = appSupport
                .appendingPathComponent("Relay", isDirectory: true)
                .appendingPathComponent("welcome-keepsake.json", isDirectory: false)
        }
        if let loaded = Self.loadState(at: self.persistenceURL) {
            self.keepsake = loaded.keepsake
            self.hasConsumedEligibility = loaded.hasConsumedEligibility
        }
    }

    public var vaultRoot: URL { vaultRootProvider() }

    /// Whether the one-time welcome keepsake eligibility has been consumed.
    public var hasGeneratedOnce: Bool {
        hasConsumedEligibility || keepsake != nil
    }

    /// Active keepsake card visible on Home / Morning Brief until retired by the user.
    public var activeKeepsake: WelcomeKeepsake? {
        guard let keepsake, !keepsake.isRetired else { return nil }
        return keepsake
    }

    public func cancelAndDrain() async {
        activeTask?.cancel()
        _ = try? await activeTask?.value
        activeTask = nil
        isGenerating = false
    }

    public func reset() {
        activeTask?.cancel()
        activeTask = nil
        isGenerating = false
        keepsake = nil
        hasConsumedEligibility = false
        try? FileManager.default.removeItem(at: persistenceURL)
    }

    public func markOpened() {
        guard var current = keepsake, !current.isOpened else { return }
        current.isOpened = true
        keepsake = current
        persist()
    }

    /// Updates the user-reviewed letter text (`PRO-11` — keepsake PNG always renders exact reviewed text).
    public func updateReviewedText(title: String? = nil, bodyMarkdown: String) {
        guard var current = keepsake else { return }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        current.bodyMarkdown = bodyMarkdown
        keepsake = current
        persist()
    }

    public func retire() {
        guard var current = keepsake else { return }
        current.isRetired = true
        keepsake = current
        hasConsumedEligibility = true
        persist()
    }

    // MARK: - Grounded One-Time Synthesis (`PRO-11`)

    @discardableResult
    func generateOnceIfEligible(
        recipientName: String? = nil,
        minimumSubstantiveNotes: Int = 2,
        minimumEvidenceBytes: Int = 200,
        complete: @escaping ModelCompletion
    ) async throws -> GenerationOutcome {
        guard !isGenerating, activeTask == nil else { throw Failure.busy }
        if let existing = keepsake {
            return existing.isRetired ? .alreadyRetired : .alreadyCreated(existing)
        }
        if hasConsumedEligibility {
            return .alreadyRetired
        }

        let evidence = Self.collectVaultEvidence(in: vaultRoot)
        guard evidence.noteTitles.count >= max(1, minimumSubstantiveNotes),
              evidence.totalSubstantiveBytes >= max(64, minimumEvidenceBytes) else {
            // Honest sparse-data behavior (`PRO-11`): do NOT fabricate a letter and do NOT burn eligibility!
            status = "Waiting for enough grounded notes in your Knowledge Vault before writing a welcome reflection."
            return .insufficientEvidence
        }

        isGenerating = true
        status = "Writing a grounded welcome reflection from your Knowledge Vault…"

        let task = Task { @MainActor () -> GenerationOutcome in
            try Task.checkCancellation()
            let messages = Self.buildPrompt(evidence: evidence, recipientName: recipientName)
            let reply = try await complete(messages)
            try Task.checkCancellation()

            guard let parsed = Self.parseLetter(
                reply.content,
                fallbackEvidence: evidence,
                recipientName: recipientName
            ) else {
                return .insufficientEvidence
            }
            self.keepsake = parsed
            self.hasConsumedEligibility = true
            self.persist()
            return .created(parsed)
        }

        activeTask = task
        defer {
            activeTask = nil
            isGenerating = false
        }

        let outcome = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        switch outcome {
        case .created:
            status = "Your welcome note is ready to read or save as a keepsake."
        case .insufficientEvidence:
            status = "Waiting for a grounded welcome reflection from your Knowledge Vault."
        case .alreadyCreated, .alreadyRetired:
            break
        }
        return outcome
    }

    // MARK: - Keepsake PNG Rendering & Non-Overwriting Export

    /// Renders the exact reviewed `WelcomeKeepsake` as `@2x` PNG data (`PRO-11`).
    public static func renderPNG(keepsake: WelcomeKeepsake, scale: CGFloat = 2.0) -> Data? {
        let renderer = ImageRenderer(content: WelcomeKeepsakeCardView(keepsake: keepsake))
        renderer.scale = max(1.0, scale)
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Saves the `@2x` PNG keepsake card to `directory` (defaulting to Desktop), selecting a unique
    /// filename so existing user files are never overwritten (`PRO-11`).
    @discardableResult
    public func saveKeepsakePNG(
        keepsake: WelcomeKeepsake? = nil,
        to directory: URL? = nil,
        scale: CGFloat = 2.0
    ) throws -> URL {
        guard let targetKeepsake = keepsake ?? self.keepsake else {
            throw Failure.renderFailed
        }
        guard let pngData = Self.renderPNG(keepsake: targetKeepsake, scale: scale) else {
            throw Failure.renderFailed
        }
        let folder = (directory ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true))
            .standardizedFileURL

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = Self.uniqueExportURL(in: folder, baseName: "Relay-Welcome-Keepsake", ext: "png")
            try pngData.write(to: destination, options: .withoutOverwriting)
            return destination
        } catch {
            throw Failure.exportFailed(error.localizedDescription)
        }
    }

    private static func uniqueExportURL(in directory: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)", isDirectory: false)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(counter).\(ext)", isDirectory: false)
            counter += 1
        }
        return candidate
    }

    // MARK: - Vault Evidence Collection (Read-Only, Zero Vault Mutations)

    private struct VaultEvidence: Sendable {
        var noteTitles: [String]
        var renderedDigest: String
        var totalSubstantiveBytes: Int
    }

    private static func collectVaultEvidence(in root: URL) -> VaultEvidence {
        var st = stat()
        guard root.path.withCString({ lstat($0, &st) }) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR else {
            return VaultEvidence(noteTitles: [], renderedDigest: "", totalSubstantiveBytes: 0)
        }

        let fm = FileManager.default
        var candidateURLs: [URL] = []
        let overviewURL = root.appendingPathComponent("Overview.md", isDirectory: false)
        if fm.fileExists(atPath: overviewURL.path) {
            candidateURLs.append(overviewURL)
        }
        for domain in SemanticVaultDomain.allCases {
            let dir = root.appendingPathComponent(domain.rawValue, isDirectory: true)
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                let sorted = files
                    .filter { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasPrefix(".") }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                candidateURLs.append(contentsOf: sorted)
            }
        }
        // Also support top-level user notes other than README.md / writingstyle.md.
        if let rootFiles = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for file in rootFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = file.lastPathComponent
                guard file.pathExtension.lowercased() == "md",
                      !name.hasPrefix("."),
                      name != "Overview.md",
                      name != "README.md",
                      name != WritingStyleCollector.fileName else { continue }
                candidateURLs.append(file)
            }
        }

        var titles: [String] = []
        var blocks: [String] = []
        var substantiveBytes = 0
        var budgetUsed = 0

        for url in candidateURLs.prefix(24) {
            var fileStat = stat()
            guard url.path.withCString({ lstat($0, &fileStat) }) == 0,
                  (fileStat.st_mode & S_IFMT) == S_IFREG,
                  let data = try? LocalStateFile.read(url, maximumBytes: 64_000),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let substantiveLines = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") && !$0.hasPrefix("- `") }
            let joinedSubstantive = substantiveLines.joined(separator: "\n")
            guard joinedSubstantive.utf8.count >= 24 else { continue }

            let title = url.deletingPathExtension().lastPathComponent
            if title != "Overview" {
                titles.append(title)
            }
            substantiveBytes += joinedSubstantive.utf8.count
            let snippet = GeneratedKnowledgeVault.boundedUTF8(joinedSubstantive, limit: 1_500)
            let block = "[\(title)]\n\(snippet)"
            if budgetUsed + block.utf8.count <= 24_000 {
                blocks.append(block)
                budgetUsed += block.utf8.count
            }
        }

        if titles.isEmpty, blocks.count == 1 {
            // Only Overview.md had substantive text — include Overview as 1 note if substantial.
            titles = ["Overview"]
        }

        return VaultEvidence(
            noteTitles: titles,
            renderedDigest: blocks.joined(separator: "\n\n"),
            totalSubstantiveBytes: substantiveBytes
        )
    }

    private struct LetterSchema: Codable {
        var kicker: String?
        var title: String?
        var bodyMarkdown: String?
        var insufficientEvidence: Bool?

        enum CodingKeys: String, CodingKey {
            case kicker
            case title
            case bodyMarkdown = "body_markdown"
            case insufficientEvidence = "insufficient_evidence"
        }
    }

    private static func buildPrompt(evidence: VaultEvidence, recipientName: String?) -> [ModelMessage] {
        let greetingHint = recipientName.flatMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "Address the user warmly as \(trimmed) if natural."
        } ?? "Do not invent a name if none is grounded in the notes."

        let system = """
            You write Relay's one-time Welcome Keepsake note after synthesizing the user's Knowledge Vault.
            STRICT RULES (PRO-11):
            1. Every observation MUST be grounded in the provided vault notes. Never invent projects, people, dates, habits, or overnight work that did not occur.
            2. Respect self-vs-other attribution: never claim a collaborator's role or goal belongs to the user.
            3. Keep the tone thoughtful, concise (2–3 short paragraphs, 90–190 words), concrete, and warm without flattery or clichés.
            4. If the notes do not contain enough grounded detail for a genuine observation, set `"insufficient_evidence": true` and `"body_markdown": ""`.
            5. \(greetingHint)
            6. Return ONLY valid JSON:
            {
              "insufficient_evidence": false,
              "kicker": "From your Knowledge Vault",
              "title": "Short grounded title (4-8 words)",
              "body_markdown": "2-3 grounded paragraphs in plain Markdown."
            }
            """
        let user = """
            GROUNDED VAULT NOTES (\(evidence.noteTitles.count) notes):
            \(evidence.renderedDigest)
            """
        return [
            ModelMessage(role: "system", content: system),
            ModelMessage(role: "user", content: user)
        ]
    }

    private static let refusalMarkers: [String] = [
        "i'm sorry, i can't",
        "i'm sorry, i cannot",
        "i am sorry, i cannot",
        "i am sorry, i can't",
        "sorry, i can't",
        "sorry, i cannot",
        "i cannot assist",
        "i can't assist",
        "i cannot fulfill",
        "i can't fulfill",
        "i cannot comply",
        "i can't comply",
        "i cannot generate",
        "i can't generate",
        "i cannot write",
        "i can't write",
        "i am unable to",
        "i'm unable to",
        "as an ai",
        "as a language model",
        "as an artificial intelligence",
        "i don't have access to",
        "i do not have access to",
        "cannot process this request",
        "unable to complete this request"
    ]

    private static func containsRefusalBoilerplate(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return refusalMarkers.contains { lower.contains($0) }
    }

    private static func parseLetter(
        _ rawText: String,
        fallbackEvidence: VaultEvidence,
        recipientName: String?
    ) -> WelcomeKeepsake? {
        guard let jsonString = SemanticVaultBuilder.extractJSONObject(from: rawText),
              let json = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LetterSchema.self, from: json) else {
            return nil
        }

        if decoded.insufficientEvidence == true {
            return nil
        }

        let body = (decoded.bodyMarkdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = body.split(whereSeparator: \.isWhitespace).count
        guard !body.isEmpty,
              body.count >= 24,
              wordCount >= 5,
              body.utf8.count <= 8_000,
              !body.hasPrefix("{"),
              !containsRefusalBoilerplate(body),
              !PIIScan.containsHighRiskPII(body) else {
            return nil
        }

        let resolvedKicker = (decoded.kicker?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "From your Knowledge Vault"
        let resolvedTitle = (decoded.title?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Threads across your notes"

        guard !containsRefusalBoilerplate(resolvedTitle),
              !PIIScan.containsHighRiskPII(resolvedTitle),
              !PIIScan.containsHighRiskPII(resolvedKicker) else {
            return nil
        }

        return WelcomeKeepsake(
            kicker: resolvedKicker,
            title: resolvedTitle,
            recipientName: recipientName,
            bodyMarkdown: GeneratedKnowledgeVault.boundedUTF8(body, limit: 2_400),
            groundedNoteTitles: Array(fallbackEvidence.noteTitles.prefix(12))
        )
    }

    private func persist() {
        let state = PersistedState(keepsake: keepsake, hasConsumedEligibility: hasConsumedEligibility)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? LocalPrivateFileWriter.write(data: data, to: persistenceURL, maximumBytes: 256_000, createOnly: false)
    }

    private static func loadState(at url: URL) -> PersistedState? {
        guard let data = try? LocalStateFile.read(url, maximumBytes: 256_000) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }
}

// MARK: - Keepsake Card & Sheet Views (`PRO-11`)

/// Export-grade archival stationery card rendered both on screen and into `@2x` PNG via `ImageRenderer`.
public struct WelcomeKeepsakeCardView: View {
    public let keepsake: WelcomeKeepsake

    public init(keepsake: WelcomeKeepsake) {
        self.keepsake = keepsake
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(keepsake.kicker.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color(red: 0.44, green: 0.38, blue: 0.31))
                Spacer()
                Text(keepsake.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.52, green: 0.46, blue: 0.39))
            }

            Text(keepsake.title)
                .font(.relayDisplayHero)
                .foregroundStyle(Color(red: 0.14, green: 0.12, blue: 0.10))
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(Color(red: 0.84, green: 0.79, blue: 0.72))
                .frame(height: 1)

            Group {
                if let attributed = try? AttributedString(
                    markdown: keepsake.bodyMarkdown,
                    options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attributed)
                } else {
                    Text(keepsake.bodyMarkdown)
                }
            }
            .font(.relayConversation)
            .lineSpacing(5)
            .foregroundStyle(Color(red: 0.19, green: 0.17, blue: 0.15))
            .fixedSize(horizontal: false, vertical: true)

            if !keepsake.groundedNoteTitles.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Grounded in: " + keepsake.groundedNoteTitles.prefix(4).joined(separator: " · "))
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(Color(red: 0.46, green: 0.40, blue: 0.33))
                .padding(.top, 6)
            }
        }
        .padding(34)
        .frame(width: 540, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.98, blue: 0.95),
                            Color(red: 0.96, green: 0.94, blue: 0.89)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(red: 0.85, green: 0.80, blue: 0.73), lineWidth: 1)
        )
    }
}

/// Interactive review, inline editing, and PNG export modal for the Welcome Keepsake (`PRO-11`).
public struct WelcomeLetterSheetView: View {
    @Bindable public var generator: WelcomeKeepsakeGenerator
    @Environment(\.dismiss) private var dismiss
    @State private var editedTitle = ""
    @State private var editedBody = ""
    @State private var isEditing = false
    @State private var exportNotice: String?

    public init(generator: WelcomeKeepsakeGenerator = .shared) {
        self.generator = generator
    }

    public var body: some View {
        VStack(spacing: 16) {
            if let current = generator.keepsake {
                HStack {
                    Text("Welcome Note")
                        .font(.relayTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Spacer()
                    Button(isEditing ? "Done Editing" : "Edit Text") {
                        if isEditing {
                            generator.updateReviewedText(title: editedTitle, bodyMarkdown: editedBody)
                        } else {
                            editedTitle = current.title
                            editedBody = current.bodyMarkdown
                        }
                        isEditing.toggle()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                }

                if isEditing {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Title", text: $editedTitle)
                            .textFieldStyle(.plain)
                            .relayTextField()
                        TextEditor(text: $editedBody)
                            .font(.relayConversation)
                            .foregroundStyle(RelayColors.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                            .padding(8)
                            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                            )
                    }
                } else {
                    ScrollView {
                        WelcomeKeepsakeCardView(keepsake: current)
                            .padding(.vertical, 4)
                    }
                }

                if let exportNotice {
                    Text(exportNotice)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                }

                HStack {
                    Button("Retire Note") {
                        generator.retire()
                        dismiss()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())

                    Spacer()

                    Button("Save Keepsake PNG…") {
                        if isEditing {
                            generator.updateReviewedText(title: editedTitle, bodyMarkdown: editedBody)
                            isEditing = false
                        }
                        exportViaSavePanel()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("welcome-keepsake-export")

                    Button("Close") {
                        if isEditing {
                            generator.updateReviewedText(title: editedTitle, bodyMarkdown: editedBody)
                        }
                        dismiss()
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                }
            } else {
                Text("No welcome note is available yet.")
                    .foregroundStyle(RelayColors.textSecondary)
                Button("Close") { dismiss() }
                    .buttonStyle(RelaySecondaryButtonStyle())
            }
        }
        .padding(22)
        .frame(minWidth: 610, minHeight: 520)
        .background(RelayColors.canvas)
        .relayPreferredAppearance()
        .onAppear {
            generator.markOpened()
            if let current = generator.keepsake {
                editedTitle = current.title
                editedBody = current.bodyMarkdown
            }
        }
    }

    private func exportViaSavePanel() {
        guard let current = generator.keepsake else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Relay-Welcome-Keepsake.png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let chosenURL = panel.url {
            if let png = WelcomeKeepsakeGenerator.renderPNG(keepsake: current, scale: 2.0) {
                do {
                    try png.write(to: chosenURL, options: .atomic)
                    exportNotice = "Saved keepsake card to \(chosenURL.lastPathComponent)."
                } catch {
                    exportNotice = "Could not save keepsake: \(error.localizedDescription)"
                }
            }
        }
    }
}
