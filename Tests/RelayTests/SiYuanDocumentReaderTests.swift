import Foundation
import Testing
@testable import Relay

@MainActor
struct SiYuanDocumentReaderTests {
    @Test func rendersStoredDocumentMeaningInOrderWithoutJSONMetadataOrLinkTargets() throws {
        let data = Data(Self.richFixture.utf8)
        let result = try SiYuanDocumentReader.read(data)
        let expected = #"""
        # Orchard launch

        ## Decisions

        Café team chose the blue plan. Read guide. Formula E=mc^2.

        3. Prepare launch
        4. Review the plan

        - [x] Draft finished
        - [ ] Review remains

        - Parent
          - Nested detail

        > Quoted context

        > Decision
        > Ship on Friday

        ```swift
        let value = "café"
        print(value)
        ```

        | Phase | Owner |
        | Launch | Asha |

        Planning tab

        Keep every tab's body.
        """#
        #expect(result.text.utf8.elementsEqual(expected.utf8))
        #expect(result.title == "Orchard launch")
        #expect(!result.truncated && result.omittedNodes == 0)
        #expect(result.coverage.hasPrefix(SiYuanDocumentReader.coveragePrefix))
        #expect(result.coverage.contains("Related documents, assets, database rows and remote content were not read"))
        for metadata in ["NodeDocument", "TextMarkAHref", "https://example.invalid/DO_NOT_FETCH", "20261107090000-a1b2c3d"] {
            #expect(!result.text.contains(metadata))
        }
        #expect(Data(Self.richFixture.utf8) == data, "Reading must not alter the supplied source.")
    }

    @Test func unsupportedExternalAndExecutableBlocksAreDeclaredGapsNotResolvedContent() throws {
        let external: [[String: Any]] = [
            ["Type": "NodeAttributeView", "AttributeViewID": "../../private/secret"],
            ["Type": "NodeBlockQueryEmbed", "Children": [["Type": "NodeBlockQueryEmbedScript", "Data": "select * from secrets"]]],
            ["Type": "NodeHTMLBlock", "Data": "<script>fetch('https://example.invalid/private')</script>"],
            ["Type": "NodeWidget", "Data": "<iframe src='file:///private/secret'>"],
            ["Type": "NodeFutureContainer", "Children": [Self.text("Hidden unknown semantics must not masquerade as source text")]],
            ["Type": "NodeImage", "Children": [["Type": "NodeLinkText", "Data": "Architecture sketch"], ["Type": "NodeLinkDest", "Data": "https://example.invalid/image"]]]
        ]
        let result = try SiYuanDocumentReader.read(Self.document(children: [Self.paragraph("Visible known context")] + external))
        #expect(result.text == "# Fixture\n\nVisible known context\n\nArchitecture sketch")
        #expect(result.omittedNodes == 6 && result.coverage.contains("Omitted 6"))
        for excluded in ["secrets", "fetch(", "file:///", "Hidden unknown", "example.invalid"] { #expect(!result.text.contains(excluded)) }
    }

    @Test func richTableCellsRetainAuthoritativeSourceAndDiscloseLayoutLoss() throws {
        let rich: [String: Any] = ["Type": "NodeTableCell", "Properties": ["colspan": "2"],
            "TableCellRich": ["spec": 1, "format": "kramdown", "content": "- First\n- Second | caveat"],
            "Children": [Self.text("Outdated inline projection must not replace rich source")]]
        let table: [String: Any] = ["Type": "NodeTable", "Children": [["Type": "NodeTableRow", "Children": [rich]]]]
        let result = try SiYuanDocumentReader.read(Self.document(children: [table]))
        #expect(result.text.contains("| - First / - Second \\| caveat |"))
        #expect(!result.text.contains("Outdated inline projection"))
        #expect(result.coverage.contains("Rich table cells") && result.coverage.contains("Merged table cells"))
    }

    @Test func compatibleTextMarksMathAndUnicodeRemainLiteral() throws {
        let literal = "NFD cafe\u{301} — مرحبًا 🌍 { [ \\\""
        let paragraph: [String: Any] = ["Type": "NodeParagraph", "Children": [
            ["Type": "NodeTextMark", "TextMarkType": "strong em", "TextMarkTextContent": literal],
            ["Type": "NodeSoftBreak"],
            ["Type": "NodeTextMark", "TextMarkType": "inline-math", "TextMarkInlineMathContent": "x^2"],
            ["Type": "NodeKramdownSpanIAL", "Data": "{: style=\"MUST_NOT_APPEAR\"}"],
            ["Type": "NodeText"]
        ]]
        let result = try SiYuanDocumentReader.read(Self.document(title: "Team / Orchard", children: [paragraph]))
        #expect(result.text.utf8.elementsEqual(("# Team / Orchard\n\n" + literal + "\nx^2").utf8))
        #expect(!result.text.contains("MUST_NOT_APPEAR"))
        let titleOnly = try SiYuanDocumentReader.read(Self.document(children: []))
        #expect(titleOnly.text.isEmpty, "A title-only note is not useful indexed document content.")
    }

    @Test(arguments: ["{", "encrypted notebook ciphertext", "[]", "{\"Type\":\"NodeParagraph\"}", "{\"Type\":\"NodeDocument\",\"Spec\":\"99\"}", "{\"Type\":\"NodeDocument\",\"Children\":[false]}", "{\"Type\":\"NodeDocument\",\"Children\":{}}", "{\"Type\":\"NodeDocument\",\"Children\":[{\"Type\":\"NodeText\",\"Data\":3}]}" ])
    func malformedEncryptedAndUnsupportedTreesNeverFallBackToRawJSON(raw: String) {
        #expect(throws: SiYuanDocumentReader.Failure.self) { try SiYuanDocumentReader.read(Data(raw.utf8)) }
    }

    @Test func limitsBoundBytesNodesDepthTimeAndUTF8Output() throws {
        let data = try Self.document(children: [Self.paragraph(String(repeating: "🌍é", count: 100))])
        var limits = SiYuanDocumentReader.Limits()
        limits.maximumInputBytes = data.count - 1
        #expect(throws: SiYuanDocumentReader.Failure.inputLimit) { try SiYuanDocumentReader.read(data, limits: limits) }
        limits = .init(); limits.maximumNodes = 2
        #expect(throws: SiYuanDocumentReader.Failure.structureLimit) { try SiYuanDocumentReader.read(data, limits: limits) }
        limits = .init(); limits.maximumDepth = 1
        #expect(throws: SiYuanDocumentReader.Failure.structureLimit) { try SiYuanDocumentReader.read(data, limits: limits) }
        limits = .init(); limits.maximumTextBytes = 39
        let bounded = try SiYuanDocumentReader.read(data, limits: limits)
        #expect(bounded.text.utf8.count <= 39 && !bounded.text.contains("�") && bounded.truncated)
        #expect(bounded.coverage.contains("omitted text is not searchable"))
        var tick = 0
        #expect(throws: SiYuanDocumentReader.Failure.timeLimit) {
            try SiYuanDocumentReader.read(data, uptime: { defer { tick += 1 }; return Double(tick) })
        }
        let deeplyNested = "{\"Type\":\"NodeDocument\",\"Children\":" + String(repeating: "[", count: 200) + "0" + String(repeating: "]", count: 200) + "}"
        #expect(throws: SiYuanDocumentReader.Failure.structureLimit) { try SiYuanDocumentReader.read(Data(deeplyNested.utf8)) }
    }

    @Test func alreadyCancelledExtractionPublishesNothing() async throws {
        let data = try Self.document(children: [Self.paragraph("Do not publish a cancelled extraction")])
        let pending = Task { try SiYuanDocumentReader.read(data) }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test func explicitFolderIndexesHumanContentSearchesAndPurgesAfterChangeOrRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-siyuan-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let note = selected.appendingPathComponent("20261107090000-a1b2c3d.sy")
        let data = Data(Self.richFixture.utf8)
        try data.write(to: note)
        try Self.document(title: "Outside", children: [Self.paragraph("Outside confidential material")]).write(to: root.appendingPathComponent("outside.sy"))
        try Data("encrypted opaque payload".utf8).write(to: selected.appendingPathComponent("encrypted.sy"))
        try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("escape.sy"), withDestinationURL: root.appendingPathComponent("outside.sy"))
        let state = root.appendingPathComponent("index.data")
        let grants = [ScopeGrant(path: selected.path)]
        let knowledge = LocalKnowledge(persistenceURL: state)
        await knowledge.index(grants: grants)
        let record = try #require(knowledge.records.first)
        #expect(knowledge.records.count == 1 && record.title == "Orchard launch")
        #expect(record.sourcePath == (try ToolPolicy.canonicalURL(note.path)).path)
        #expect(record.coverageNote?.hasPrefix(SiYuanDocumentReader.coveragePrefix) == true)
        #expect(knowledge.search(query: "Asha", grants: grants).first?.excerpt.contains("Launch | Asha") == true)
        #expect(knowledge.search(query: "NodeDocument", grants: grants).isEmpty)
        #expect(knowledge.search(query: "confidential", grants: grants).isEmpty)
        #expect(try Data(contentsOf: note) == data)
        let restored = LocalKnowledge(persistenceURL: state)
        #expect(restored.search(query: "Friday", grants: grants).count == 1)
        let changed = Self.richFixture.replacingOccurrences(of: "Friday", with: "Monday")
        #expect(changed.utf8.count == data.count)
        try Data(changed.utf8).write(to: note)
        try FileManager.default.setAttributes([.modificationDate: record.modifiedAt], ofItemAtPath: note.path)
        #expect(restored.search(query: "Friday", grants: grants).isEmpty && restored.records.isEmpty)
        await restored.index(grants: grants)
        #expect(restored.search(query: "Monday", grants: grants).count == 1)
        #expect(restored.search(query: "Monday", grants: []).isEmpty && restored.records.isEmpty)
    }

    @Test func savedRawJSONWithoutParserProvenanceIsNotRestoredAsSiYuanKnowledge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-siyuan-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.sy")
        let state = root.appendingPathComponent("index.data")
        let record = KnowledgeRecord(sourcePath: try ToolPolicy.canonicalURL(note.path).path, title: "note.sy",
            text: "NodeDocument raw JSON is not an extracted note", modifiedAt: .distantPast, contentHash: "synthetic", byteCount: 1)
        struct Saved: Encodable { let version = 2; let records: [KnowledgeRecord] }
        try JSONEncoder().encode(Saved(records: [record])).write(to: state)
        #expect(LocalKnowledge(persistenceURL: state).records.isEmpty)
    }

    private static func text(_ value: String) -> [String: Any] { ["Type": "NodeText", "Data": value] }
    private static func paragraph(_ value: String) -> [String: Any] { ["Type": "NodeParagraph", "Children": [text(value)]] }
    private static func document(title: String = "Fixture", children: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Type": "NodeDocument", "Spec": "6", "Properties": ["title": title], "Children": children], options: [.sortedKeys])
    }

    private static let richFixture = #"""
    {"ID":"20261107090000-a1b2c3d","Spec":"3","Type":"NodeDocument","Properties":{"id":"20261107090000-a1b2c3d","title":"Orchard launch","updated":"20261107090000"},"Children":[
      {"Type":"NodeHeading","HeadingLevel":2,"Children":[{"Type":"NodeHeadingC8hMarker","Data":"## "},{"Type":"NodeText","Data":"Decisions"}]},
      {"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Café team chose the "},{"Type":"NodeTextMark","TextMarkType":"strong","TextMarkTextContent":"blue plan"},{"Type":"NodeText","Data":". Read "},{"Type":"NodeTextMark","TextMarkType":"a","TextMarkAHref":"https://example.invalid/DO_NOT_FETCH","TextMarkTextContent":"guide"},{"Type":"NodeText","Data":". Formula "},{"Type":"NodeTextMark","TextMarkType":"inline-math","TextMarkInlineMathContent":"E=mc^2"},{"Type":"NodeText","Data":"."}]},
      {"Type":"NodeList","ListData":{"Typ":1,"Start":3},"Children":[{"Type":"NodeListItem","ListData":{"Typ":1},"Children":[{"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Prepare launch"}]}]},{"Type":"NodeListItem","ListData":{"Typ":1},"Children":[{"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Review the plan"}]}]}]},
      {"Type":"NodeList","ListData":{"Typ":3},"Children":[{"Type":"NodeListItem","Children":[{"Type":"NodeTaskListItemMarker","TaskListItemMarker":88},{"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Draft finished"}]}]},{"Type":"NodeListItem","Children":[{"Type":"NodeTaskListItemMarker","TaskListItemMarker":32},{"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Review remains"}]}]}]},
      {"Type":"NodeList","Children":[{"Type":"NodeListItem","Children":[{"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Parent"}]},{"Type":"NodeList","Children":[{"Type":"NodeListItem","Children":[{"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Nested detail"}]}]}]}]}]},
      {"Type":"NodeBlockquote","Children":[{"Type":"NodeBlockquoteMarker","Data":"> "},{"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Quoted context"}]}]},
      {"Type":"NodeCallout","CalloutType":"NOTE","CalloutTitle":"Decision","Children":[{"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Ship on Friday"}]}]},
      {"Type":"NodeCodeBlock","Children":[{"Type":"NodeCodeBlockFenceOpenMarker","Data":"```"},{"Type":"NodeCodeBlockFenceInfoMarker","CodeBlockInfo":"c3dpZnQ="},{"Type":"NodeCodeBlockCode","Data":"let value = \"café\"\nprint(value)\n"},{"Type":"NodeCodeBlockFenceCloseMarker","Data":"```"}]},
      {"Type":"NodeTable","Children":[{"Type":"NodeTableHead","Children":[{"Type":"NodeTableRow","Children":[{"Type":"NodeTableCell","Children":[{"Type":"NodeText","Data":"Phase"}]},{"Type":"NodeTableCell","Children":[{"Type":"NodeText","Data":"Owner"}]}]}]},{"Type":"NodeTableRow","Children":[{"Type":"NodeTableCell","Children":[{"Type":"NodeText","Data":"Launch"}]},{"Type":"NodeTableCell","Children":[{"Type":"NodeText","Data":"Asha"}]}]}]},
      {"Type":"NodeTabs","Children":[{"Type":"NodeTabItem","TabItemTitle":"Planning tab","Children":[{"Type":"NodeParagraph","Children":[{"Type":"NodeText","Data":"Keep every tab's body."}]}]}]}
    ]}
    """#
}
