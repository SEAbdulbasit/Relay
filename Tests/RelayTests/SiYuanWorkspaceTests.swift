import CryptoKit
import Foundation
import Testing
@testable import Relay

@MainActor struct SiYuanWorkspaceTests {
    private static let notebook = "20260101000000-book001"
    private static let parent = "20260101000001-parent1"
    private static let child = "20260101000002-child01"
    private static let database = "20260101000003-table01"
    private static let row = "20260101000004-row0001"

    @Test func selectedWorkspaceReadsOpenNotebookBreadcrumbsAndDatabaseInBlockOrder() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Project Orchard", body: [])
        try f.note(Self.child, under: Self.parent, title: "Launch decision", body: [Self.paragraph("Before database"), Self.av(), Self.paragraph("After database")])
        try f.database("Friday")
        try f.book("20260101000000-closed1", name: "Closed", closed: true)
        try f.note("20260101000000-secret1", book: "20260101000000-closed1", title: "Secret", body: [Self.paragraph("Closed notebook private marker")])
        try f.book("20210808180117-6v0mkxr", name: "Guide")
        try f.note("20260101000000-guide01", book: "20210808180117-6v0mkxr", title: "Guide", body: [Self.paragraph("Guide marker")])
        try f.book("20260101000000-crypto1", name: "Encrypted", encrypted: true)
        try f.note("20260101000000-crypto2", book: "20260101000000-crypto1", title: "Cipher", body: [Self.paragraph("Must skip even if plaintext residue exists")])
        try f.writeJSON(["Type":"NodeDocument","Children":[Self.paragraph("History marker")]], relative: "history/old.sy")
        let knowledge = LocalKnowledge(persistenceURL: f.state)
        await knowledge.index(grants: f.grants)
        let record = try #require(knowledge.records.first)
        #expect(knowledge.records.count == 1)
        #expect(record.text.contains("SiYuan: Work › Project Orchard › Launch decision"))
        #expect(record.text.range(of: "Before database")!.lowerBound < record.text.range(of: "Friday")!.lowerBound)
        #expect(record.text.range(of: "Friday")!.lowerBound < record.text.range(of: "After database")!.lowerBound)
        #expect(record.sourceDependencies?.count == 4)
        #expect(record.sourceIdentity == SiYuanWorkspaceReader.identity(root: try f.canonical.path, documentID: Self.child))
        #expect(record.contentHash != record.evidenceFingerprint)
        #expect(record.contentHash == SiYuanWorkspaceReader.digest(try Data(contentsOf: f.noteURL(Self.child, under: Self.parent))))
        #expect(knowledge.search(query: "Friday", grants: f.grants).first?.excerpt.contains("Asha") == true)
        for excluded in ["Closed notebook private marker", "Guide marker", "plaintext residue", "History marker"] { #expect(!record.text.contains(excluded)) }
        #expect(record.coverageNote?.contains("plaintext notebooks") == true)
    }

    @Test func databaseOnlySameSizeSameDateDriftInvalidatesSearchRevisionAndGeneratedCheckpoint() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Orchard", body: [Self.av()]); try f.database("Friday")
        let knowledge = LocalKnowledge(persistenceURL: f.state); await knowledge.index(grants: f.grants)
        let before = try #require(knowledge.records.first)
        let revision = CrossSourceKnowledge.Revision(before)
        let originalName = GeneratedKnowledgeVault.name(for: before)
        let database = f.root.appendingPathComponent("data/storage/av/" + Self.database + ".json")
        let dependency = try #require(before.sourceDependencies?.first(where: { $0.path.hasSuffix(Self.database + ".json") }))
        try f.database("Monday")
        try FileManager.default.setAttributes([.modificationDate: dependency.modifiedAt], ofItemAtPath: database.path)
        let restored = LocalKnowledge(persistenceURL: f.state)
        #expect(restored.records.count == 1)
        #expect(restored.search(query: "Friday", grants: f.grants).isEmpty && restored.records.isEmpty)
        await restored.index(grants: f.grants)
        let after = try #require(restored.records.first)
        #expect(after.contentHash == before.contentHash && after.evidenceFingerprint != before.evidenceFingerprint)
        #expect(!revision.matches(after) && GeneratedKnowledgeVault.name(for: after) != originalName)
        #expect(restored.search(query: "Monday", grants: f.grants).count == 1)
        #expect(restored.search(query: "Monday", grants: []).isEmpty && restored.records.isEmpty)
    }

    @Test func dependencyRevisionInvalidatesSemanticCacheCardsAndDurableGeneratedNotes() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Orchard", body: [Self.paragraph("TODO: Review the launch"), Self.av()])
        try f.database("Friday")
        let knowledge = LocalKnowledge(persistenceURL: f.state); await knowledge.index(grants: f.grants)
        let before = try #require(knowledge.records.first)
        let cards = ProactiveSuggestions(persistenceURL: nil); cards.setEnabled(true)
        cards.prepare(records: knowledge.records)
        #expect(cards.suggestions.count == 1 && cards.suggestions.first?.sourceContentHash == before.evidenceFingerprint)
        let vectors = Vectors()
        let semantic = SemanticKnowledgeSearch(backend: vectors)
        let lexical = KnowledgeSearchCoordinator(knowledge: knowledge, service: semantic)
        lexical.currentGrants = { f.grants }
        let draftContext = try await FocusedDraftKnowledge.retrieve(query: "Orchard launch", knowledge: knowledge, search: lexical, currentGrants: { f.grants })
        #expect(draftContext.passages.count == 1)
        try draftContext.validate()
        _ = await semantic.prepare(language: "en")
        let first = await semantic.search(query: "Orchard", records: knowledge.records)
        #expect(first.hits.first?.sourceContentHash == before.evidenceFingerprint)
        #expect(await semantic.search(query: "Orchard", records: knowledge.records).coverage.cacheHits == 1)
        let vault = GeneratedKnowledgeVault(directoryURL: f.container.appendingPathComponent("generated"))
        var calls = 0
        await vault.generate(records: knowledge.records, isCurrent: { knowledge.revalidate($0, grants: f.grants) }) { _ in
            calls += 1; return ModelReply(content: #"{"highlights":[1]}"#, toolCalls: [])
        }
        #expect(vault.notes.count == 1 && calls == 1)
        let oldNote = try #require(vault.notes.first)
        #expect(oldNote.markdownBody.contains("data/storage/av/" + Self.database + ".json"))
        await vault.generate(records: knowledge.records, isCurrent: { knowledge.revalidate($0, grants: f.grants) }) { _ in
            calls += 1; return ModelReply(content: #"{"highlights":[1]}"#, toolCalls: [])
        }
        #expect(calls == 1, "Unchanged accepted documents reuse the durable generated checkpoint.")
        try f.database("Monday"); await knowledge.index(grants: f.grants)
        let after = try #require(knowledge.records.first)
        #expect(throws: (any Error).self) { try draftContext.validate() }
        cards.purge(records: knowledge.records)
        #expect(cards.suggestions.isEmpty)
        vault.reconcile(records: knowledge.records)
        #expect(vault.notes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.container.appendingPathComponent("generated/" + oldNote.id).path))
        let refreshed = await semantic.search(query: "Orchard", records: knowledge.records)
        #expect(refreshed.coverage.cacheHits == 0 && refreshed.hits.first?.sourceContentHash == after.evidenceFingerprint)
        await vault.generate(records: knowledge.records, isCurrent: { knowledge.revalidate($0, grants: f.grants) }) { _ in
            calls += 1; return ModelReply(content: #"{"highlights":[1]}"#, toolCalls: [])
        }
        #expect(calls == 2 && vault.notes.count == 1)
        #expect(vault.notes.first?.sourceHash == after.contentHash)
    }

    @Test func parentTitleAndNotebookStateChangesWithdrawDerivedChildrenAfterRestart() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Parent A", body: [])
        try f.note(Self.child, under: Self.parent, title: "Child", body: [Self.paragraph("Retained child material")])
        let knowledge = LocalKnowledge(persistenceURL: f.state); await knowledge.index(grants: f.grants)
        try f.note(Self.parent, title: "Parent B", body: [])
        #expect(knowledge.search(query: "Retained", grants: f.grants).isEmpty)
        await knowledge.index(grants: f.grants)
        #expect(knowledge.records.first?.text.contains("Parent B › Child") == true)
        try f.book(Self.notebook, name: "Work", closed: true)
        let restored = LocalKnowledge(persistenceURL: f.state)
        #expect(restored.search(query: "Retained", grants: f.grants).isEmpty)
        await restored.index(grants: f.grants)
        #expect(restored.records.isEmpty)
    }

    @Test func missingAndMalformedDatabasesHaveCoverageAndAreNeverRawJSONFallback() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Orchard", body: [Self.paragraph("Kept body"), Self.av()])
        let knowledge = LocalKnowledge(persistenceURL: f.state); await knowledge.index(grants: f.grants)
        let missing = try #require(knowledge.records.first)
        #expect(missing.coverageNote?.contains("database is missing") == true)
        #expect(missing.sourceDependencies?.contains(where: { $0.contentHash == "missing" }) == true)
        try f.database("Friday")
        #expect(knowledge.search(query: "Kept", grants: f.grants).isEmpty)
        await knowledge.index(grants: f.grants)
        #expect(knowledge.search(query: "Friday", grants: f.grants).count == 1)
        try f.write(Data("encrypted payload DO_NOT_INDEX".utf8), relative: "data/storage/av/" + Self.database + ".json")
        await knowledge.index(grants: f.grants)
        let encrypted = try #require(knowledge.records.first)
        #expect(encrypted.coverageNote?.contains("encrypted, unsupported or malformed database") == true)
        #expect(!encrypted.text.contains("DO_NOT_INDEX") && !encrypted.text.contains("keyValues"))
    }

    @Test func aliasesDeduplicateCopiedWorkspaceDiffersAndOldImportsStillAppear() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Current", body: [Self.paragraph("First eligible note")], updated: "20261107000000")
        let knowledge = LocalKnowledge(persistenceURL: f.state); await knowledge.index(grants: f.grants)
        try f.note(Self.child, title: "Old import", body: [Self.paragraph("Older imported note still appears")], updated: "19990101000000")
        try await knowledge.refresh(grants: f.grants)
        #expect(knowledge.records.count == 2)
        let alias = f.container.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
        await knowledge.index(grants: f.grants + [ScopeGrant(path: alias.path)])
        #expect(knowledge.records.count == 2 && Set(knowledge.records.compactMap(\.sourceIdentity)).count == 2)
        let copy = f.container.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: f.root, to: copy)
        await knowledge.index(grants: f.grants + [ScopeGrant(path: copy.path)])
        #expect(knowledge.records.count == 4 && Set(knowledge.records.compactMap(\.sourceIdentity)).count == 4)
    }

    @Test func genericAncestorCannotRecursivelyIndexAWorkspaceOrClosedNotebook() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Inside workspace", body: [Self.paragraph("Workspace marker")])
        let knowledge = LocalKnowledge(persistenceURL: f.state)
        await knowledge.index(grants: [ScopeGrant(path: f.container.path)])
        #expect(knowledge.records.isEmpty)
        #expect(knowledge.status.contains("Select that workspace folder directly"))
    }

    @Test func legacyFlatCacheCannotBypassClosedNotebookWorkspacePolicy() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Closed note", body: [Self.paragraph("Closed cached material")])
        try f.book(Self.notebook, name: "Work", closed: true)
        let url = try ToolPolicy.canonicalURL(f.noteURL(Self.parent).path)
        let data = try Data(contentsOf: url), parsed = try SiYuanDocumentReader.read(data)
        let date = try #require(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let record = KnowledgeRecord(sourcePath:url.path,title:"Closed note",text:parsed.text,modifiedAt:date,
            contentHash:SiYuanWorkspaceReader.digest(data),byteCount:data.count,coverageNote:parsed.coverage)
        struct OldIndex: Encodable { let version = 2; let records: [KnowledgeRecord] }
        let saved = try JSONEncoder().encode(OldIndex(records:[record]))
        try saved.write(to:f.state)
        let restored = LocalKnowledge(persistenceURL:f.state)
        #expect(restored.search(query:"Closed",grants:f.grants).isEmpty && restored.records.isEmpty)
        try saved.write(to:f.state)
        let explicitFile = LocalKnowledge(persistenceURL:f.state)
        #expect(explicitFile.search(query:"Closed",grants:[ScopeGrant(path:url.path)]).count == 1)
    }

    @Test func ordinaryConfAndDataFoldersStayGenericButDamagedWorkspaceDoesNotFallBack() async throws {
        let f = try Fixture(); defer { f.remove() }
        let generic = f.container.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:generic.appendingPathComponent("conf"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:generic.appendingPathComponent("data"),withIntermediateDirectories:true)
        try Data("Ordinary project file".utf8).write(to:generic.appendingPathComponent("readme.txt"))
        #expect(!SiYuanWorkspaceReader.recognizes(generic))
        let knowledge = LocalKnowledge(persistenceURL:nil)
        await knowledge.index(grants:[ScopeGrant(path:generic.path)])
        #expect(knowledge.records.count == 1 && knowledge.records.first?.title == "readme.txt")
        try f.note(Self.parent,title:"Closed",body:[Self.paragraph("Must not fall back to this body")])
        try f.book(Self.notebook,name:"Closed",closed:true)
        try FileManager.default.removeItem(at:f.root.appendingPathComponent("conf/conf.json"))
        #expect(SiYuanWorkspaceReader.recognizes(f.root))
        let damaged = LocalKnowledge(persistenceURL:nil)
        await damaged.index(grants:f.grants)
        #expect(damaged.records.isEmpty && damaged.status.contains("not indexed"))
    }

    @Test func linksOutsideWorkspaceAndChangedDependencyScopesFailClosed() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Orchard", body: [Self.av()])
        let outside = f.container.appendingPathComponent("outside.json")
        try JSONSerialization.data(withJSONObject: Self.avJSON("External secret")).write(to: outside)
        let av = f.root.appendingPathComponent("data/storage/av/" + Self.database + ".json")
        try FileManager.default.createDirectory(at: av.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: av, withDestinationURL: outside)
        let knowledge = LocalKnowledge(persistenceURL: f.state)
        await knowledge.index(grants: f.grants + [ScopeGrant(path: outside.path)])
        #expect(knowledge.records.isEmpty && knowledge.status.contains("not indexed"))
        #expect(knowledge.search(query: "External secret", grants: f.grants).isEmpty)
    }

    @Test func workspaceHasSeparateThousandNoteLimitAndGenericIndexStaysBounded() async throws {
        let f = try Fixture(); defer { f.remove() }
        for index in 0..<1_002 {
            let id = "20260101000000-" + String(format: "%07d", index)
            try f.note(id, title: "Note " + String(index), body: [Self.paragraph("Workspace searchable fixture " + String(index))])
        }
        let generic = f.container.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: generic, withIntermediateDirectories: true)
        for index in 0..<202 { try Data("Generic fixture".utf8).write(to: generic.appendingPathComponent(String(index) + ".txt")) }
        let grants = f.grants + [ScopeGrant(path: generic.path)]
        let knowledge = LocalKnowledge(persistenceURL: f.state)
        await knowledge.index(grants: grants)
        #expect(knowledge.records.count(where: { $0.workspaceRoot != nil }) == 1_000)
        #expect(knowledge.records.count(where: { $0.workspaceRoot == nil }) == 200)
        #expect(knowledge.status.contains("Coverage is partial") && knowledge.status.contains("Scan limits reached"))
        let restored = LocalKnowledge(persistenceURL: f.state)
        #expect(restored.records.count == 1_200)
    }

    @Test func sharedWorkspaceWindowKeepsNewestNotesAcrossRootOrder() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Older", body: [Self.paragraph("Old workspace")], updated: "19990101000000")
        let newer = f.container.appendingPathComponent("z-new-workspace")
        try FileManager.default.copyItem(at: f.root, to: newer)
        let path = newer.appendingPathComponent("data/" + Self.notebook + "/" + Self.parent + ".sy")
        try JSONSerialization.data(withJSONObject: ["Type":"NodeDocument","Spec":"2","Properties":["title":"Newer","updated":"20261107000000"],"Children":[Self.paragraph("Newest selected workspace")]]).write(to:path)
        var limits = KnowledgeLimits(); limits.maxWorkspaceNotes = 1
        let knowledge = LocalKnowledge(persistenceURL: f.state, limits: limits)
        await knowledge.index(grants: f.grants + [ScopeGrant(path:newer.path)])
        #expect(knowledge.records.count == 1 && knowledge.records.first?.title == "Newer")
        #expect(knowledge.status.contains("Coverage is partial"))
    }

    @Test func cancellationAndStaleOwnerCannotPublishPartialWorkspace() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.note(Self.parent, title: "Original", body: [Self.paragraph("Previously committed content")])
        let knowledge = LocalKnowledge(persistenceURL: f.state); await knowledge.index(grants: f.grants)
        let committed = knowledge.records
        for index in 0..<50 { try f.note("20260101000000-" + String(format: "%07d", index), title: "New", body: [Self.paragraph("Uncommitted")]) }
        let task = Task { await knowledge.index(grants: f.grants) }
        await Task.yield(); knowledge.cancel(); await task.value
        #expect(knowledge.records == committed)
        await #expect(throws: CancellationError.self) {
            try await SiYuanWorkspaceReader.snapshot(root: f.root, grants: f.grants, isCurrent: { false })
        }
        var limits = SiYuanWorkspaceReader.Limits(); limits.maximumTextBytes = 100
        let bounded = try await SiYuanWorkspaceReader.snapshot(root: f.root, grants: f.grants, limits: limits)
        #expect(bounded.records.reduce(0) { $0 + $1.text.utf8.count } <= 100)
        #expect(bounded.coverage.contains("Coverage is partial"))
    }

    @Test func attributeViewCellsAreBoundedLiteralAndNeverEvaluateFormulaOrReadAssets() throws {
        var object = Self.avJSON("Friday")
        let first = try #require(object["keyValues"] as? [[String: Any]])
        object["keyValues"] = first + [
            ["key":["name":"Unknown", "type":"relation"],"values":[["blockID":Self.row,"type":"relation","relation":["content":"DO_NOT_RESOLVE"]]]],
            ["key":["name":"Asset", "type":"mAsset"],"values":[["blockID":Self.row,"type":"mAsset","mAsset":[["name":"Sketch", "content":"file:///private/secret"]]]]],
            ["key":["name":"Done", "type":"checkbox"],"values":[["blockID":Self.row,"type":"checkbox","checkbox":["checked":true]]]]]
        let result = try SiYuanAttributeViewReader.read(JSONSerialization.data(withJSONObject: object))
        #expect(result.text.contains("Sketch") && result.text.contains("[x]"))
        #expect(!result.text.contains("DO_NOT_RESOLVE") && !result.text.contains("file:///private"))
        #expect(result.coverage.contains("unsupported cell values"))
        #expect(throws: (any Error).self) { try SiYuanAttributeViewReader.read(Data("encrypted".utf8)) }
        let tiny = try SiYuanAttributeViewReader.read(JSONSerialization.data(withJSONObject: object), maximumTextBytes: 11)
        #expect(tiny.text.utf8.count <= 11 && tiny.coverage.contains("truncated"))
        #expect(throws: (any Error).self) { try SiYuanAttributeViewReader.read(Data(("{\"a\":" + String(repeating:"[", count:80) + "0" + String(repeating:"]", count:80) + "}").utf8)) }
        let plain = KnowledgeRecord(sourcePath:"/tmp/generic",title:"Generic",text:"Text",modifiedAt:.distantPast,contentHash:"same",byteCount:4)
        #expect(plain.evidenceFingerprint == plain.contentHash)
    }

    @Test func attributeViewRowJoinOrderAndFiftyRowCapAreExplicit() throws {
        let ids = (0..<52).map { "20260101000000-" + String(format: "%07d", $0) }
        let first = ids.enumerated().map { index, id in ["blockID": id, "type":"text", "text":["content":"Row " + String(index)]] as [String: Any] }
        let second = ids.reversed().enumerated().map { _, id in ["blockID":id,"type":"number","number":["content":42,"isNotEmpty":true,"formattedContent":"42.00"]] as [String: Any] }
        let object: [String: Any] = ["name":"Bounded table","keyValues":[
            ["key":["name":"Name","type":"text"],"values":first],
            ["key":["name":"Amount","type":"number"],"values":second]]]
        let result = try SiYuanAttributeViewReader.read(JSONSerialization.data(withJSONObject:object))
        #expect(result.text.contains("| Row 0 | 42.00 |") && result.text.contains("| Row 49 | 42.00 |"))
        #expect(!result.text.contains("Row 50") && !result.text.contains("Row 51"))
        #expect(result.coverage.contains("First 50 of 52 rows"))
    }

    @Test func inlineMemosTagsAndLegacyMathRetainTheirStoredMeaning() throws {
        let tree: [String: Any] = ["Type":"NodeDocument","Children":[["Type":"NodeParagraph","Children":[
            ["Type":"NodeTextMark","TextMarkType":"tag","TextMarkTextContent":"Orchard"],
            ["Type":"NodeText","Data":" "],
            ["Type":"NodeTextMark","TextMarkType":"inline-memo","TextMarkTextContent":"Decision","TextMarkInlineMemoContent":"Review with Asha"],
            ["Type":"NodeText","Data":" "],
            ["Type":"NodeInlineMath","Children":[["Type":"NodeInlineMathContent","Data":"x^2"]]]]]]]
        let result = try SiYuanDocumentReader.read(JSONSerialization.data(withJSONObject:tree))
        #expect(result.text == "#Orchard# Decision (note: Review with Asha) x^2")
    }

    private actor Vectors: SemanticEmbeddingBackend {
        func prepare(language: String) -> SemanticEmbeddingDescriptor? { .init(language: language, revision: 1, dimension: 2) }
        func vector(for text: String) -> [Double]? { [1, 0] }
        func clear() {}
    }

    private static func paragraph(_ value: String) -> [String: Any] { ["Type":"NodeParagraph","Children":[["Type":"NodeText","Data":value]]] }
    private static func av() -> [String: Any] { ["Type":"NodeAttributeView","AttributeViewID":database] }
    private static func avJSON(_ day: String) -> [String: Any] {
        ["id":database,"name":"Launch","keyValues":[
            ["key":["name":"Day","type":"text"],"values":[["blockID":row,"type":"text","text":["content":day]]]],
            ["key":["name":"Owner","type":"text"],"values":[["blockID":row,"type":"text","text":["content":"Asha"]]]]]]
    }
    @MainActor private struct Fixture {
        let container: URL
        let root: URL
        var state: URL { container.appendingPathComponent("knowledge.json") }
        var canonical: URL { get throws { try ToolPolicy.canonicalURL(root.path) } }
        var grants: [ScopeGrant] { [ScopeGrant(path: root.path)] }
        init() throws {
            container = FileManager.default.temporaryDirectory.appendingPathComponent("relay-siyuan-workspace-" + UUID().uuidString)
            root = container.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try writeJSON(["system":["name":"Synthetic workspace"]], relative:"conf/conf.json")
            try book(SiYuanWorkspaceTests.notebook, name:"Work")
        }
        func remove() { try? FileManager.default.removeItem(at: container) }
        func write(_ data: Data, relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func writeJSON(_ object: [String: Any], relative: String) throws { try write(JSONSerialization.data(withJSONObject:object, options:[.sortedKeys]), relative:relative) }
        func book(_ id: String, name: String, closed: Bool = false, encrypted: Bool = false) throws {
            try writeJSON(["name":name,"closed":closed,"encrypted":encrypted], relative:"data/" + id + "/.siyuan/conf.json")
        }
        func noteURL(_ id: String, under parent: String? = nil, book: String = SiYuanWorkspaceTests.notebook) -> URL {
            root.appendingPathComponent("data/" + book + "/" + (parent.map { $0 + "/" } ?? "") + id + ".sy")
        }
        func note(_ id: String, under parent: String? = nil, book: String = SiYuanWorkspaceTests.notebook, title: String, body: [[String: Any]], updated: String = "20260101000000") throws {
            let url = noteURL(id, under:parent, book:book)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:["Type":"NodeDocument","Spec":"2","Properties":["title":title,"updated":updated],"Children":body],options:[.sortedKeys]).write(to:url)
        }
        func database(_ day: String) throws { try writeJSON(SiYuanWorkspaceTests.avJSON(day), relative:"data/storage/av/" + SiYuanWorkspaceTests.database + ".json") }
    }
}
