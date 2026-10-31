import Foundation
import Testing
@testable import Relay

@MainActor
struct KnowledgeGraphTruthfulnessTests {
    private func record(_ title: String, path: String, text: String) -> KnowledgeRecord {
        KnowledgeRecord(sourcePath: path, title: title, text: text,
                        modifiedAt: Date(timeIntervalSince1970: 0), contentHash: "fixture",
                        byteCount: text.utf8.count)
    }

    @Test func emptySourcesDoNotManufacturePersonalKnowledge() {
        let graph = SkyGraph.build(records: [])
        #expect(graph.nodes.isEmpty)
        #expect(graph.edges.isEmpty)
        #expect(graph.domains.isEmpty)
        #expect(graph.rootIndex == nil)
        // Revoking every source must also return an empty view, not fallback examples.
        let prior = SkyGraph.build(records: [record("Orchard", path: "/fixture/orchard.md", text: "Apple harvest")])
        #expect(!prior.nodes.isEmpty)
        #expect(SkyGraph.build(records: []).nodes.isEmpty)
    }

    @Test func recordsAppearWithTheirActualContentAndNoInventedRelationship() throws {
        let first = record("Orchard", path: "/fixture/orchard.md", text: "The apple harvest is Friday.")
        let second = record("Garden", path: "/fixture/garden.md", text: "The garden needs water.")
        let graph = SkyGraph.build(records: [first, second])
        #expect(Set(graph.nodes.map(\.title)) == ["Overview", "Indexed Sources", "Orchard", "Garden"])
        let a = try #require(graph.nodes.firstIndex(where: { $0.url == URL(fileURLWithPath: first.sourcePath) }))
        let b = try #require(graph.nodes.firstIndex(where: { $0.url == URL(fileURLWithPath: second.sourcePath) }))
        #expect(graph.nodes[a].markdownBody.contains(first.text))
        #expect(graph.nodes[b].markdownBody.contains(second.text))
        #expect(!graph.adjacency[a].contains(b))
        #expect(graph.nodes.allSatisfy { !$0.recentlyChanged })
    }

    @Test func ambiguousWikilinkDoesNotGuessBetweenDuplicateTitles() throws {
        let source = record("Index", path: "/fixture/index.md", text: "See [[Meeting.md]].")
        let one = record("Meeting.md", path: "/fixture/work/meeting.md", text: "Work meeting")
        let two = record("Meeting.md", path: "/fixture/home/meeting.md", text: "Home meeting")
        let graph = SkyGraph.build(records: [source, one, two])
        let index = try #require(graph.nodes.firstIndex(where: { $0.title == "Index" }))
        for path in [one.sourcePath, two.sourcePath] {
            let target = try #require(graph.nodes.firstIndex(where: { $0.url == URL(fileURLWithPath: path) }))
            #expect(!graph.adjacency[index].contains(target))
        }
    }

    @Test func explicitNotesPreserveExactBodyAndOnlyResolveAvailableLinks() throws {
        let draftURL = try #require(URL(string: "relay-vault://custom/draft"))
        let planURL = try #require(URL(string: "relay-vault://custom/plan"))
        let body = "# My draft\n\nCafé 🌙 — compare [[Plan.md|the plan]] and [[Missing note]]."
        let notes: [URL: (title: String, domain: String, body: String)] = [
            draftURL: ("Draft", "Notes", body),
            planURL: ("Plan.md", "Notes", "# Plan\n\nUser-authored plan.")
        ]
        let graph = SkyGraph.build(records: [], customNotes: notes)
        #expect(Set(graph.nodes.map(\.title)) == ["Overview", "Your Notes", "Draft", "Plan.md"])
        let draft = try #require(graph.nodes.firstIndex(where: { $0.url == draftURL }))
        let plan = try #require(graph.nodes.firstIndex(where: { $0.url == planURL }))
        #expect(graph.nodes[draft].markdownBody == body)
        #expect(graph.adjacency[draft].contains(plan))
        #expect(!graph.nodes.contains(where: { $0.title == "Missing note" }))
    }
}
