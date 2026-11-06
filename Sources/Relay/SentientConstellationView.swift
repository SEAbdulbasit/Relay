import AppKit
import SwiftUI
import Combine

// MARK: - 1. SkyGraph (Ported from Sentient OS SkyGraph.swift)

struct SkyNode: Identifiable, Equatable {
    let url: URL
    let title: String
    let domain: Int              // index into SkyGraph.domains · -1 = Overview sun
    var degree: Int
    let isRoot: Bool
    let recentlyChanged: Bool
    let preview: String
    let markdownBody: String
    let twinklePhase: Double
    let twinkleSpeed: Double

    var id: URL { url }
}

struct SkyEdge: Equatable {
    let a: Int
    let b: Int
    let sameDomain: Bool
}

struct SkyGraph {
    private static let maximumRelationships = 64
    let nodes: [SkyNode]
    let edges: [SkyEdge]
    let adjacency: [[Int]]
    let domains: [String]
    let rootIndex: Int?
    let maxDegree: Int
    private let wikiTargets: [String: Int]

    fileprivate struct EdgePair: Hashable { let a: Int; let b: Int }

    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    func linkedNodes(from url: URL) -> [SkyNode] {
        guard let index = nodes.firstIndex(where: { $0.url == url }) else { return [] }
        return adjacency[index].map { nodes[$0] }
    }

    func linkedNode(for link: KnowledgeWikiLink, among neighbors: [SkyNode]) -> SkyNode? {
        if let relationship = link.relationship {
            return neighbors.first { $0.url == relationship.url }
        }
        guard let index = wikiTargets[Self.wikiKey(link.target)] else { return nil }
        return neighbors.first { $0.url == nodes[index].url }
    }

    private static func wikiKey(_ title: String) -> String {
        title.hasSuffix(".md") ? String(title.dropLast(3)) : title
    }

    private static func isNamedDocument(_ node: SkyNode) -> Bool {
        !node.isRoot && node.url.host != "group" && KnowledgeRelationship.Kind.from(node.url) == nil
    }

    /// Group links describe membership. Other links come from explicit wikilinks or source provenance.
    static func build(records: [KnowledgeRecord], customNotes: [URL: (title: String, domain: String, body: String)] = [:],
                      generatedNotes: [GeneratedKnowledgeNote] = [], folders: [LocalMarkdownFolder] = []) -> SkyGraph {
        guard !records.isEmpty || !customNotes.isEmpty || !folders.isEmpty else {
            return finish(nodes: [], pairs: [], domains: [])
        }
        let currentSources = Dictionary(records.map { ($0.sourcePath, $0) }, uniquingKeysWith: { first, _ in first })
        let currentGenerated = generatedNotes.filter { note in
            guard let source = currentSources[note.sourcePath] else { return false }
            return GeneratedKnowledgeVault.name(for: source) == note.id
        }
        var domains: [String] = []
        if !records.isEmpty { domains.append("Indexed Sources") }
        if !currentGenerated.isEmpty { domains.append(GeneratedKnowledgeNote.domain) }
        let folderDomains = Set(folders.map(\.graphDomain))
        if customNotes.values.contains(where: { !folderDomains.contains($0.domain) }) { domains.append("Your Notes") }
        domains.append(contentsOf: folders.map(\.graphDomain))
        var nodes: [SkyNode] = []
        var pairs = Set<EdgePair>()
        var indices: [String: [Int]] = [:]
        var sourceIndices: [String: Int] = [:]
        var documentText: [Int: (body: String, allowsRelationships: Bool)] = [:]

        func add(_ title: String, _ preview: String, _ body: String, domain: Int, root: Bool = false, url: URL) -> Int {
            let index = nodes.count
            let hash = stableHash(title)
            nodes.append(SkyNode(url: url, title: title, domain: domain, degree: 0, isRoot: root,
                                 recentlyChanged: false, preview: preview, markdownBody: body,
                                 twinklePhase: Double(hash % 6283) / 1000.0,
                                 twinkleSpeed: 1.1 + Double((hash >> 16) % 1000) / 1000.0 * 2.1))
            if isNamedDocument(nodes[index]) { indices[wikiKey(title), default: []].append(index) }
            return index
        }
        func link(_ a: Int, _ b: Int) {
            if a != b { pairs.insert(EdgePair(a: min(a, b), b: max(a, b))) }
        }
        let indexed = "\(records.count) indexed \(records.count == 1 ? "source" : "sources")"
        let generated = "\(currentGenerated.count) generated \(currentGenerated.count == 1 ? "note" : "notes")"
        let editable = "\(customNotes.count) editable \(customNotes.count == 1 ? "note" : "notes")"
        let root = add("Overview", "Current selected sources and notes.",
                       "# Your knowledge\n\n\(indexed), \(generated) and \(editable).\n\nChoose a source to read it. To connect a person or project, use Add link when editing a note. The graph shows up to \(maximumRelationships) people and projects.",
                       domain: -1, root: true, url: URL(string: "relay-vault://overview")!)
        for (domain, name) in domains.enumerated() {
            let displayName = LocalMarkdownFolder.displayName(for: name)
            let groupURL = URL(string: "relay-vault://group")!.appendingPathComponent(name)
            let hub = add(displayName, "Browse \(displayName.lowercased()).", "# \(displayName)\n\nSelect a source or note from the list.",
                          domain: domain, url: groupURL)
            link(root, hub)
            if name == "Indexed Sources" {
                for record in records {
                    let preview = record.text.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? "Indexed source excerpt."
                    let body = "# \(record.title)\n\nSource: \(record.sourcePath)\n\n\(record.text)"
                    let index = add(record.title, String(preview.prefix(140)), body, domain: domain,
                                    url: URL(fileURLWithPath: record.sourcePath))
                    sourceIndices[record.sourcePath] = index
                    documentText[index] = (record.text, URL(fileURLWithPath: record.sourcePath).pathExtension.lowercased() == "md")
                    link(hub, index)
                }
            } else if name == GeneratedKnowledgeNote.domain {
                for note in currentGenerated {
                    let preview = note.highlights.first ?? "Model-selected source highlights."
                    let index = add(note.title, String(preview.prefix(140)), note.markdownBody, domain: domain, url: note.graphURL)
                    link(hub, index)
                    if let source = sourceIndices[note.sourcePath] { link(index, source) }
                }
            } else {
                for (url, note) in customNotes.sorted(by: { $0.key.absoluteString < $1.key.absoluteString }) {
                    let noteDomain = folderDomains.contains(note.domain) ? note.domain : "Your Notes"
                    guard noteDomain == name else { continue }
                    let preview = note.body.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? "Your local note."
                    let index = add(note.title, String(preview.prefix(140)), note.body, domain: domain, url: url)
                    documentText[index] = (note.body, true)
                    link(hub, index)
                }
            }
        }
        var relationships: [URL: (relationship: KnowledgeRelationship, documents: Set<Int>)] = [:]
        let wikiTargets = indices.compactMapValues { $0.count == 1 ? $0.first : nil }
        for index in documentText.keys.sorted() {
            guard let document = documentText[index] else { continue }
            for line in KnowledgeWikiLink.lines(in: document.body) where line.allowsLinks {
                for wikiLink in KnowledgeWikiLink.inLine(line.text) {
                    if let relationship = wikiLink.relationship {
                        guard document.allowsRelationships else { continue }
                        let url = relationship.url
                        if relationships[url] != nil {
                            relationships[url]?.documents.insert(index)
                        } else if relationships.count < maximumRelationships {
                            relationships[url] = (relationship, [index])
                        }
                    } else if let targetIndex = wikiTargets[wikiKey(wikiLink.target)] {
                        link(index, targetIndex)
                    }
                }
            }
        }
        for kind in KnowledgeRelationship.Kind.allCases {
            let entries = relationships.filter { $0.value.relationship.kind == kind }
                .sorted { $0.value.relationship.name.localizedStandardCompare($1.value.relationship.name) == .orderedAscending }
            guard !entries.isEmpty else { continue }
            let domain = domains.count
            domains.append(kind.domain)
            let hub = add(kind.domain, "Browse linked \(kind.domain.lowercased()).", "", domain: domain,
                          url: URL(string: "relay-vault://group")!.appendingPathComponent(kind.domain))
            link(root, hub)
            for (url, entry) in entries {
                let count = entry.documents.count
                let index = add(entry.relationship.name, "Linked in \(count) \(count == 1 ? "document" : "documents").", "", domain: domain, url: url)
                link(hub, index)
                for document in entry.documents { link(index, document) }
            }
        }
        return finish(nodes: nodes, pairs: pairs, domains: domains, wikiTargets: wikiTargets)
    }

    private static func finish(nodes: [SkyNode], pairs: Set<EdgePair>, domains: [String], wikiTargets: [String: Int] = [:]) -> SkyGraph {
        var nodes = nodes
        var adjacency = [[Int]](repeating: [], count: nodes.count)
        let edges = pairs.sorted { ($0.a, $0.b) < ($1.a, $1.b) }.map { p in
            nodes[p.a].degree += 1
            nodes[p.b].degree += 1
            adjacency[p.a].append(p.b)
            adjacency[p.b].append(p.a)
            return SkyEdge(
                a: p.a,
                b: p.b,
                sameDomain: nodes[p.a].domain == nodes[p.b].domain && nodes[p.a].domain >= 0
            )
        }
        return SkyGraph(
            nodes: nodes,
            edges: edges,
            adjacency: adjacency,
            domains: domains,
            rootIndex: nodes.firstIndex(where: \.isRoot),
            maxDegree: max(nodes.map(\.degree).max() ?? 1, 1),
            wikiTargets: wikiTargets
        )
    }
}

// MARK: - 2. SkySimulation (Ported from Sentient OS SkySimulation.swift)

enum SkyTuning {
    static let ringRadius: CGFloat = 270
    static let repulsion: CGFloat = 1700
    static let repulsionCutoff: CGFloat = 300
    static let springSameRest: CGFloat = 62
    static let springSameK: CGFloat = 0.036
    static let springCrossRest: CGFloat = 185
    static let springCrossK: CGFloat = 0.0065
    static let anchorPull: CGFloat = 0.020
    static let centerPull: CGFloat = 0.0010
    static let damping: CGFloat = 0.80
    static let maxSpeed: CGFloat = 14
    static let alphaDecay: Double = 0.986
    static let sleepAlpha: Double = 0.012
    static let dragAlpha: Double = 0.35
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed != 0 ? seed : 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class SkySimulation {
    private(set) var pos: [CGPoint]
    private var vel: [CGPoint]
    private(set) var alpha: Double = 1
    let anchors: [CGPoint]
    private let graph: SkyGraph
    private var dragIndex: Int?
    private var dragTarget: CGPoint = .zero

    var isAwake: Bool { alpha > 0 || dragIndex != nil }

    init(graph: SkyGraph, entrance: Bool) {
        self.graph = graph
        let d = max(graph.domains.count, 1)
        let anchors = (0..<graph.domains.count).map { i -> CGPoint in
            let ang = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(d)
            return CGPoint(x: cos(ang) * SkyTuning.ringRadius, y: sin(ang) * SkyTuning.ringRadius)
        }
        self.anchors = anchors

        var rng = SplitMix64(seed: 0xC0FFEE ^ UInt64(graph.nodes.count))
        pos = graph.nodes.map { n in
            if n.isRoot { return .zero }
            let anchor = (n.domain >= 0 && n.domain < anchors.count) ? anchors[n.domain] : .zero
            let toward = anchor == .zero ? CGFloat.random(in: -.pi ... .pi, using: &rng) : atan2(anchor.y, anchor.x)
            let ang = toward + CGFloat.random(in: -0.55...0.55, using: &rng)
            let r = SkyTuning.ringRadius * CGFloat.random(in: 1.75...2.45, using: &rng)
            return CGPoint(x: cos(ang) * r, y: sin(ang) * r)
        }
        vel = [CGPoint](repeating: .zero, count: graph.nodes.count)
        if !entrance { settle() }
    }

    private func anchorPoint(_ domain: Int) -> CGPoint {
        domain >= 0 && domain < anchors.count ? anchors[domain] : .zero
    }

    func step(elapsed: TimeInterval) {
        guard isAwake else { return }
        let n = max(1, min(3, Int((elapsed * 60).rounded())))
        for _ in 0..<n { substep() }
    }

    func settle() {
        for _ in 0..<1500 {
            substep()
            if alpha == 0 { break }
        }
    }

    private func substep() {
        let count = graph.nodes.count
        guard count > 0 else { return }
        var force = [CGPoint](repeating: .zero, count: count)
        let cutoff2 = SkyTuning.repulsionCutoff * SkyTuning.repulsionCutoff

        for i in 0..<count {
            for j in (i + 1)..<count {
                var d = CGPoint(x: pos[i].x - pos[j].x, y: pos[i].y - pos[j].y)
                var dist2 = d.x * d.x + d.y * d.y
                if dist2 > cutoff2 { continue }
                if dist2 < 0.01 {
                    d = CGPoint(x: 0.017 * CGFloat(i - j), y: 0.013)
                    dist2 = d.x * d.x + d.y * d.y
                }
                let dist = sqrt(max(dist2, 25))
                let f = SkyTuning.repulsion / max(dist2, 25)
                let dir = CGPoint(x: d.x / dist, y: d.y / dist)
                force[i] = CGPoint(x: force[i].x + dir.x * f, y: force[i].y + dir.y * f)
                force[j] = CGPoint(x: force[j].x - dir.x * f, y: force[j].y - dir.y * f)
            }
        }

        for e in graph.edges {
            let rest = e.sameDomain ? SkyTuning.springSameRest : SkyTuning.springCrossRest
            let k = e.sameDomain ? SkyTuning.springSameK : SkyTuning.springCrossK
            let d = CGPoint(x: pos[e.b].x - pos[e.a].x, y: pos[e.b].y - pos[e.a].y)
            let dist = max(hypot(d.x, d.y), 0.01)
            let f = (dist - rest) * k
            let dir = CGPoint(x: d.x / dist, y: d.y / dist)
            force[e.a] = CGPoint(x: force[e.a].x + dir.x * f, y: force[e.a].y + dir.y * f)
            force[e.b] = CGPoint(x: force[e.b].x - dir.x * f, y: force[e.b].y - dir.y * f)
        }

        for i in 0..<count {
            let n = graph.nodes[i]
            let pull = SkyTuning.anchorPull * (n.domain >= 0 ? 1 : 0.5)
            let anchor = anchorPoint(n.domain)
            force[i] = CGPoint(
                x: force[i].x + (anchor.x - pos[i].x) * pull - pos[i].x * SkyTuning.centerPull,
                y: force[i].y + (anchor.y - pos[i].y) * pull - pos[i].y * SkyTuning.centerPull
            )
        }

        let heat = CGFloat(0.2 + 0.8 * alpha)
        for i in 0..<count {
            if graph.nodes[i].isRoot { pos[i] = .zero; vel[i] = .zero; continue }
            if i == dragIndex { pos[i] = dragTarget; vel[i] = .zero; continue }
            var vx = (vel[i].x + force[i].x * heat) * SkyTuning.damping
            var vy = (vel[i].y + force[i].y * heat) * SkyTuning.damping
            let speed = hypot(vx, vy)
            if speed > SkyTuning.maxSpeed {
                vx *= SkyTuning.maxSpeed / speed
                vy *= SkyTuning.maxSpeed / speed
            }
            vel[i] = CGPoint(x: vx, y: vy)
            pos[i] = CGPoint(x: pos[i].x + vx, y: pos[i].y + vy)
        }

        if dragIndex == nil {
            alpha *= SkyTuning.alphaDecay
            if alpha < SkyTuning.sleepAlpha { alpha = 0 }
        } else {
            alpha = max(alpha, SkyTuning.dragAlpha)
        }
    }

    func beginDrag(_ i: Int) {
        guard graph.nodes.indices.contains(i), !graph.nodes[i].isRoot else { return }
        dragIndex = i
        dragTarget = pos[i]
        alpha = max(alpha, SkyTuning.dragAlpha)
    }

    func drag(to world: CGPoint) {
        guard dragIndex != nil else { return }
        dragTarget = world
    }

    func endDrag() { dragIndex = nil }
}

// MARK: - 3. NightSkyModel & SkyRenderer (Ported from Sentient OS NightSkyModel.swift & SkyRenderer.swift)

struct SkyCamera {
    var pan: CGPoint = .zero
    var zoom: CGFloat = 1
    var initialized = false
}

struct SkyPulse {
    let edge: Int
    let start: TimeInterval
    let duration: TimeInterval
}

struct SkyHoverInfo: Equatable {
    let url: URL
    let title: String
    let domainName: String
    let domainIndex: Int
    let preview: String
    let recentlyChanged: Bool
    let degree: Int
    let anchor: CGPoint
}

@MainActor
final class NightSkyModel: ObservableObject {
    @Published private(set) var graph: SkyGraph?
    @Published private(set) var hoverInfo: SkyHoverInfo?

    private(set) var sim: SkySimulation?
    var camera = SkyCamera()
    var minimumZoom: CGFloat = 0.35

    private(set) var glow: [Double] = []
    private(set) var hoverIndex: Int?
    private(set) var focusIndex: Int?
    private(set) var focusNeighbors: Set<Int> = []
    private(set) var focusBlend: Double = 0
    private(set) var highlightIndex: Int?
    private var highlightBlend: Double = 0

    private(set) var pulses: [SkyPulse] = []
    private var nextPulseAt: TimeInterval = .infinity
    let dust = SkyRenderer.makeDust()

    private var lastTick: TimeInterval?
    private var dragging = false

    init() {
        load(records: [], entrance: false)
    }

    func load(records: [KnowledgeRecord], customNotes: [URL: (title: String, domain: String, body: String)] = [:],
              generatedNotes: [GeneratedKnowledgeNote] = [], folders: [LocalMarkdownFolder] = [], entrance: Bool = false) {
        let g = SkyGraph.build(records: records, customNotes: customNotes, generatedNotes: generatedNotes, folders: folders)
        sim = SkySimulation(graph: g, entrance: entrance)
        graph = g
        glow = [Double](repeating: 0, count: g.nodes.count)
        hoverIndex = nil
        hoverInfo = nil
        focusIndex = nil
        focusNeighbors = []
        focusBlend = 0
    }

    func tick(now: TimeInterval, size: CGSize) {
        guard let sim, let graph else { return }
        if !camera.initialized, size.width > 40, size.height > 40 {
            camera.zoom = min(max(min(size.width, size.height) / (SkyTuning.ringRadius * 2 * 1.48), minimumZoom), 1.15)
            camera.initialized = true
        }
        let dt = lastTick.map { min(max(now - $0, 0), 1.0 / 20) } ?? 1.0 / 60
        lastTick = now

        sim.step(elapsed: dt)

        let rate = 1 - exp(-dt * 9)
        for i in glow.indices {
            var target: Double = 0
            if i == hoverIndex { target = 1 }
            else if hoverIndex != nil && focusNeighbors.contains(i) { target = 0.78 }
            if i == highlightIndex { target = max(target, highlightBlend) }
            glow[i] += (target - glow[i]) * rate
        }
        let globalTarget: Double = hoverIndex != nil ? 1 : 0
        focusBlend += (globalTarget - focusBlend) * rate
        if hoverIndex == nil && focusBlend < 0.02 {
            focusIndex = nil
            focusNeighbors = []
        }

        if highlightIndex != nil {
            highlightBlend -= dt / 2.6
            if highlightBlend <= 0 { highlightBlend = 0; highlightIndex = nil }
        }

        if sim.alpha < 0.35, !graph.edges.isEmpty {
            if nextPulseAt == .infinity { nextPulseAt = now + Double.random(in: 1.5...3.0) }
            if now >= nextPulseAt {
                pulses.append(SkyPulse(edge: Int.random(in: 0..<graph.edges.count), start: now, duration: 1.35))
                nextPulseAt = now + Double.random(in: 3.2...6.5)
            }
        }
        pulses.removeAll { now - $0.start > $0.duration }
    }

    func fitToContent(in size: CGSize, padding: CGFloat = 32) {
        guard let positions = sim?.pos, let first = positions.first,
              size.width > 2 * padding, size.height > 2 * padding else { return }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in positions {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let scale = min((size.width - 2 * padding) / max(1, maxX - minX + 110),
                        (size.height - 2 * padding) / max(1, maxY - minY + 110))
        camera.zoom = min(1.25, max(minimumZoom, scale))
        camera.pan = CGPoint(x: -(minX + maxX) / 2 * camera.zoom, y: -(minY + maxY) / 2 * camera.zoom)
        camera.initialized = true
        objectWillChange.send()
    }

    func toScreen(_ w: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + camera.pan.x + w.x * camera.zoom,
                y: size.height / 2 + camera.pan.y + w.y * camera.zoom)
    }

    func toWorld(_ s: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (s.x - size.width / 2 - camera.pan.x) / camera.zoom,
                y: (s.y - size.height / 2 - camera.pan.y) / camera.zoom)
    }

    func panBy(dx: CGFloat, dy: CGFloat) {
        camera.pan.x += dx
        camera.pan.y += dy
        hoverInfo = nil
        hoverIndex = nil
    }

    func zoom(by factor: CGFloat, at s: CGPoint, size: CGSize) {
        let newZoom = min(max(camera.zoom * factor, minimumZoom), 3.8)
        let w = toWorld(s, size: size)
        camera.zoom = newZoom
        camera.pan = CGPoint(x: s.x - size.width / 2 - w.x * newZoom,
                             y: s.y - size.height / 2 - w.y * newZoom)
        hoverInfo = nil
        hoverIndex = nil
        objectWillChange.send()
    }

    func hitTest(_ s: CGPoint, size: CGSize) -> Int? {
        guard let sim, let graph else { return nil }
        let w = toWorld(s, size: size)
        let reach = max(18 / camera.zoom, 11)
        var best: (i: Int, d: CGFloat)?
        for i in graph.nodes.indices {
            let d = hypot(sim.pos[i].x - w.x, sim.pos[i].y - w.y)
            if d < reach && d < (best?.d ?? .infinity) { best = (i, d) }
        }
        return best?.i
    }

    func updateHover(_ s: CGPoint, size: CGSize) {
        guard !dragging else { return }
        let hit = hitTest(s, size: size)
        guard hit != hoverIndex else { return }
        hoverIndex = hit
        if let h = hit, let graph, let sim {
            focusIndex = h
            focusNeighbors = Set(graph.adjacency[h])
            let n = graph.nodes[h]
            hoverInfo = SkyHoverInfo(
                url: n.url,
                title: n.title,
                domainName: n.isRoot ? "PERSONAL KNOWLEDGE SUN" : (n.domain >= 0 && n.domain < graph.domains.count ? graph.domains[n.domain] : "Vault"),
                domainIndex: n.domain,
                preview: n.preview,
                recentlyChanged: n.recentlyChanged,
                degree: n.degree,
                anchor: toScreen(sim.pos[h], size: size)
            )
        } else {
            hoverInfo = nil
        }
    }

    func clearHover() {
        hoverIndex = nil
        hoverInfo = nil
    }

    func beginDrag(_ i: Int) {
        dragging = true
        clearHover()
        sim?.beginDrag(i)
    }

    func dragStar(to s: CGPoint, size: CGSize) {
        sim?.drag(to: toWorld(s, size: size))
    }

    func endDrag() {
        dragging = false
        sim?.endDrag()
    }

    func highlight(_ url: URL) {
        guard let graph, let i = graph.nodes.firstIndex(where: { $0.url == url }) else { return }
        highlightIndex = i
        highlightBlend = 1.0
    }

    func sunOverlay(size: CGSize) -> (center: CGPoint, diameter: CGFloat, opacity: Double)? {
        guard let graph, let sim, let root = graph.rootIndex, camera.initialized else { return nil }
        let zf = CGFloat(pow(Double(camera.zoom), 0.62))
        let reveal = min(1, (1 - sim.alpha) * 3 + 0.15)
        return (toScreen(sim.pos[root], size: size), 30 * zf, reveal)
    }

    func hoverCardRect(in size: CGSize) -> CGRect? {
        guard let info = hoverInfo else { return nil }
        let w = min(265, max(1, size.width - 32)), h: CGFloat = 118
        var x = info.anchor.x + 24
        if x + w > size.width - 16 { x = info.anchor.x - 24 - w }
        var y = info.anchor.y + 24
        if y + h > size.height - 16 { y = info.anchor.y - 24 - h }
        x = min(max(16, x), max(16, size.width - w - 16))
        y = min(max(16, y), max(16, size.height - h - 16))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

struct SkyRenderer {
    private static let palette: [(r: Double, g: Double, b: Double)] = [
        (1.00, 0.80, 0.55),  // gold
        (0.45, 0.85, 0.78),  // teal
        (0.72, 0.62, 1.00),  // violet
        (1.00, 0.62, 0.70),  // rose
        (0.55, 0.75, 1.00),  // sky
        (0.68, 0.88, 0.62),  // sage
        (1.00, 0.72, 0.55),  // peach
        (0.60, 0.62, 0.98),  // indigo
        (0.55, 0.92, 0.80),  // mint
        (0.82, 0.70, 0.98)   // lavender
    ]
    private static let dawn = (r: 0.333, g: 0.757, b: 0.941)

    static func domainColor(_ d: Int, alpha: Double = 1) -> Color {
        guard d >= 0 else { return Color(red: 1, green: 0.93, blue: 0.85, opacity: alpha) }
        let c = palette[d % palette.count]
        return Color(red: c.r, green: c.g, blue: c.b, opacity: alpha)
    }

    private static func coreColor(_ d: Int, alpha: Double) -> Color {
        guard d >= 0 else { return Color(red: 1, green: 0.96, blue: 0.9, opacity: alpha) }
        let c = palette[d % palette.count]
        return Color(red: 0.78 + 0.22 * c.r, green: 0.78 + 0.22 * c.g, blue: 0.78 + 0.22 * c.b, opacity: alpha)
    }

    struct Speck {
        let base: CGPoint
        let size: CGFloat
        let alpha: Double
        let parallax: CGFloat
        let drift: CGPoint
        let phase: Double
    }

    static func makeDust() -> [Speck] {
        var rng = SplitMix64(seed: 0xD057)
        func layer(count: Int, parallax: CGFloat, sizes: ClosedRange<CGFloat>, alpha: ClosedRange<Double>) -> [Speck] {
            (0..<count).map { _ in
                Speck(
                    base: CGPoint(x: CGFloat.random(in: 0...1, using: &rng), y: CGFloat.random(in: 0...1, using: &rng)),
                    size: CGFloat.random(in: sizes, using: &rng),
                    alpha: Double.random(in: alpha, using: &rng),
                    parallax: parallax,
                    drift: CGPoint(x: CGFloat.random(in: -2.2...2.2, using: &rng), y: CGFloat.random(in: -1.6...1.6, using: &rng)),
                    phase: Double.random(in: 0...6.28, using: &rng)
                )
            }
        }
        return layer(count: 150, parallax: 0.22, sizes: 0.7...1.4, alpha: 0.03...0.07)
             + layer(count: 90, parallax: 0.45, sizes: 1.1...2.1, alpha: 0.05...0.10)
    }

    static func draw(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel, t: TimeInterval) {
        guard let graph = model.graph, let sim = model.sim else { return }
        let cam = model.camera
        let zf = CGFloat(pow(Double(cam.zoom), 0.62))

        let heat = sim.alpha
        let starReveal = min(1, (1 - heat) * 3 + 0.15)
        let threadReveal = max(0, min(1, (0.55 - heat) / 0.45))

        let focusSet: Set<Int> = {
            guard let f = model.focusIndex else { return [] }
            return model.focusNeighbors.union([f])
        }()

        drawDust(ctx, size: size, model: model, t: t)
        drawConstellationLabels(ctx, size: size, model: model, graph: graph, sim: sim, reveal: threadReveal, dim: 1 - 0.5 * model.focusBlend)
        drawBreath(ctx, size: size, model: model, t: t, reveal: threadReveal)
        drawThreads(ctx, size: size, model: model, graph: graph, sim: sim, reveal: threadReveal, focusSet: focusSet, zf: zf)
        drawPulses(ctx, size: size, model: model, graph: graph, sim: sim, t: t, reveal: threadReveal)
        drawSunOcclusion(ctx, size: size, model: model, graph: graph, sim: sim, zf: zf)
        drawStars(ctx, size: size, model: model, graph: graph, sim: sim, t: t, zf: zf, starReveal: starReveal, focusSet: focusSet)
        drawTitles(ctx, size: size, model: model, graph: graph, sim: sim, zf: zf, reveal: starReveal, focusSet: focusSet)
    }

    private static func sunClearance(_ zf: CGFloat) -> CGFloat { 22 * zf }

    private static func pulledIn(_ p: CGPoint, toward q: CGPoint, by d: CGFloat) -> CGPoint {
        let dx = q.x - p.x, dy = q.y - p.y
        let len = hypot(dx, dy)
        guard len > d else { return q }
        return CGPoint(x: p.x + dx / len * d, y: p.y + dy / len * d)
    }

    private static func drawSunOcclusion(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                         graph: SkyGraph, sim: SkySimulation, zf: CGFloat) {
        guard let root = graph.rootIndex else { return }
        let p = model.toScreen(sim.pos[root], size: size)
        let r = sunClearance(zf)
        ctx.fill(
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.72),
                    .init(color: .black.opacity(0), location: 1)
                ]),
                center: p,
                startRadius: 0,
                endRadius: r
            )
        )
    }

    private static func drawDust(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel, t: TimeInterval) {
        let margin: CGFloat = 80
        let tileW = size.width + margin * 2
        let tileH = size.height + margin * 2
        guard tileW > 0, tileH > 0 else { return }
        for s in model.dust {
            var x = (s.base.x * tileW + s.drift.x * t + model.camera.pan.x * s.parallax).truncatingRemainder(dividingBy: tileW)
            var y = (s.base.y * tileH + s.drift.y * t + model.camera.pan.y * s.parallax).truncatingRemainder(dividingBy: tileH)
            if x < 0 { x += tileW }
            if y < 0 { y += tileH }
            let a = s.alpha * (0.75 + 0.25 * sin(t * 0.7 + s.phase))
            ctx.fill(Path(ellipseIn: CGRect(x: x - margin, y: y - margin, width: s.size, height: s.size)), with: .color(.white.opacity(a)))
        }
    }

    private static func drawBreath(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel, t: TimeInterval, reveal: Double) {
        guard reveal > 0.3 else { return }
        let period = 11.0
        let phase = t.truncatingRemainder(dividingBy: period) / period
        guard phase < 0.5 else { return }
        let p = phase / 0.5
        let ease = 1 - pow(1 - p, 2)
        let center = model.toScreen(.zero, size: size)
        let r = (40 + 520 * ease) * model.camera.zoom
        ctx.fill(
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(Gradient(colors: [.white.opacity(0.032 * (1 - p) * reveal), .clear]), center: center, startRadius: 0, endRadius: r)
        )
    }

    private static func drawThreads(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                    graph: SkyGraph, sim: SkySimulation,
                                    reveal: Double, focusSet: Set<Int>, zf: CGFloat) {
        guard reveal > 0.01 else { return }
        let dim = 1 - 0.55 * model.focusBlend
        let root = graph.rootIndex
        let clear = sunClearance(zf)

        func endpoints(_ e: SkyEdge) -> (CGPoint, CGPoint)? {
            var a = model.toScreen(sim.pos[e.a], size: size)
            var b = model.toScreen(sim.pos[e.b], size: size)
            if e.a == root { a = pulledIn(a, toward: b, by: clear) }
            if e.b == root { b = pulledIn(b, toward: a, by: clear) }
            return hypot(b.x - a.x, b.y - a.y) > 2 ? (a, b) : nil
        }

        var same = Path()
        var cross = Path()
        for e in graph.edges {
            guard let (a, b) = endpoints(e) else { continue }
            if e.sameDomain { same.move(to: a); same.addLine(to: b) }
            else { cross.move(to: a); cross.addLine(to: b) }
        }
        ctx.stroke(same, with: .color(.white.opacity(0.085 * reveal * dim)), lineWidth: 0.85)
        ctx.stroke(cross, with: .color(.white.opacity(0.055 * reveal * dim)), lineWidth: 0.85)

        func ignite(_ center: Int, intensity: Double) {
            guard intensity > 0.02 else { return }
            for e in graph.edges where e.a == center || e.b == center {
                guard let (pa, pb) = endpoints(e) else { continue }
                var p = Path()
                p.move(to: pa)
                p.addLine(to: pb)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [
                        domainColor(graph.nodes[e.a].domain, alpha: 0.9 * intensity),
                        domainColor(graph.nodes[e.b].domain, alpha: 0.9 * intensity)
                    ]),
                    startPoint: pa,
                    endPoint: pb
                )
                var wide = ctx
                wide.opacity = 0.28 * intensity
                wide.stroke(p, with: shading, lineWidth: 4.5)
                ctx.stroke(p, with: shading, lineWidth: 1.35)
            }
        }
        if let f = model.focusIndex { ignite(f, intensity: model.focusBlend * reveal) }
        if let h = model.highlightIndex, h != model.focusIndex, model.glow.indices.contains(h) {
            ignite(h, intensity: model.glow[h] * 0.7 * reveal)
        }
    }

    private static func drawPulses(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                   graph: SkyGraph, sim: SkySimulation, t: TimeInterval, reveal: Double) {
        for pulse in model.pulses {
            guard graph.edges.indices.contains(pulse.edge) else { continue }
            let e = graph.edges[pulse.edge]
            let progress = max(0, min(1, (t - pulse.start) / pulse.duration))
            let envelope = sin(.pi * progress) * reveal
            guard envelope > 0.01 else { continue }
            let a = model.toScreen(sim.pos[e.a], size: size)
            let b = model.toScreen(sim.pos[e.b], size: size)
            let head = CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
            let tailP = max(0, progress - 0.13)
            let tail = CGPoint(x: a.x + (b.x - a.x) * tailP, y: a.y + (b.y - a.y) * tailP)
            var trail = Path()
            trail.move(to: tail)
            trail.addLine(to: head)
            ctx.stroke(
                trail,
                with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.6 * envelope)]), startPoint: tail, endPoint: head),
                lineWidth: 1.3
            )
            let r = 4.5 * max(model.camera.zoom, 0.6)
            ctx.fill(
                Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(Gradient(colors: [.white.opacity(0.92 * envelope), .clear]), center: head, startRadius: 0, endRadius: r)
            )
        }
    }

    static func starRadius(_ n: SkyNode, maxDegree: Int, zf: CGFloat) -> CGFloat {
        let degN = sqrt(Double(n.degree) / Double(max(maxDegree, 1)))
        let world: CGFloat = n.isRoot ? 9 : (2.5 + 3.4 * CGFloat(degN))
        return world * zf
    }

    private static func drawStars(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                  graph: SkyGraph, sim: SkySimulation, t: TimeInterval, zf: CGFloat,
                                  starReveal: Double, focusSet: Set<Int>) {
        let margin: CGFloat = 80
        for (i, n) in graph.nodes.enumerated() {
            let p = model.toScreen(sim.pos[i], size: size)
            guard p.x > -margin, p.x < size.width + margin, p.y > -margin, p.y < size.height + margin else { continue }

            let g = model.glow.indices.contains(i) ? model.glow[i] : 0
            let dim = (focusSet.isEmpty || focusSet.contains(i)) ? 1.0 : 1.0 - 0.62 * model.focusBlend
            let twinkle = 0.86 + 0.14 * sin(t * n.twinkleSpeed + n.twinklePhase)
            let bright = twinkle * dim * starReveal
            let r = starRadius(n, maxDegree: graph.maxDegree, zf: zf)

            if n.isRoot {
                let halo = r * 7
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                    with: .radialGradient(Gradient(colors: [.white.opacity(0.12 * bright * (1 + 0.6 * g)), .clear]), center: p, startRadius: 0, endRadius: halo)
                )
                continue
            }

            let degN = sqrt(Double(n.degree) / Double(max(graph.maxDegree, 1)))
            let haloR = r * 3.6 * (1 + 0.8 * g)
            ctx.fill(
                Path(ellipseIn: CGRect(x: p.x - haloR, y: p.y - haloR, width: haloR * 2, height: haloR * 2)),
                with: .radialGradient(
                    Gradient(colors: [domainColor(n.domain, alpha: (0.18 + 0.10 * degN) * bright * (1 + 1.7 * g)), .clear]),
                    center: p,
                    startRadius: 0,
                    endRadius: haloR
                )
            )

            if n.recentlyChanged {
                let aR = r * 5
                let aA = (0.11 + 0.07 * sin(t * 1.5 + n.twinklePhase)) * dim * starReveal
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - aR, y: p.y - aR, width: aR * 2, height: aR * 2)),
                    with: .radialGradient(Gradient(colors: [Color(red: dawn.r, green: dawn.g, blue: dawn.b, opacity: aA), .clear]), center: p, startRadius: 0, endRadius: aR)
                )
            }

            let coreR = r * (1 + 0.30 * g)
            ctx.fill(
                Path(ellipseIn: CGRect(x: p.x - coreR, y: p.y - coreR, width: coreR * 2, height: coreR * 2)),
                with: .color(coreColor(n.domain, alpha: min(1, 0.12 + 0.9 * bright + 0.25 * g)))
            )

            if g > 0.02 {
                let ringR = r * 2.15 + 1.5
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: p.x - ringR, y: p.y - ringR, width: ringR * 2, height: ringR * 2)),
                    with: .color(domainColor(n.domain, alpha: 0.58 * g)),
                    lineWidth: 1.1
                )
            }
        }
    }

    private static func drawConstellationLabels(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                                graph: SkyGraph, sim: SkySimulation,
                                                reveal: Double, dim: Double) {
        let zoom = model.camera.zoom
        let labelA = max(0, min(1, (1.95 - Double(zoom)) / 0.9)) * reveal * dim
        guard labelA > 0.02, !graph.domains.isEmpty else { return }

        var sums = [CGPoint](repeating: .zero, count: graph.domains.count)
        var counts = [Int](repeating: 0, count: graph.domains.count)
        for (i, n) in graph.nodes.enumerated() where n.domain >= 0 && n.domain < graph.domains.count {
            sums[n.domain] = CGPoint(x: sums[n.domain].x + sim.pos[i].x, y: sums[n.domain].y + sim.pos[i].y)
            counts[n.domain] += 1
        }
        for (d, name) in graph.domains.enumerated() where counts[d] > 0 {
            let avg = CGPoint(x: sums[d].x / CGFloat(counts[d]), y: sums[d].y / CGFloat(counts[d]))
            let dist = max(1, hypot(avg.x, avg.y))
            let pushedWorld = CGPoint(
                x: avg.x + (avg.x / dist) * 58,
                y: avg.y + (avg.y / dist) * 48
            )
            let labelPos = model.toScreen(pushedWorld, size: size)
            var txt = ctx.resolve(
                Text(name)
                    .font(.system(size: 11.5, weight: .regular))
            )
            txt.shading = .color(.white.opacity(0.46 * labelA))
            ctx.draw(txt, at: labelPos, anchor: .center)
        }
    }

    private static func drawTitles(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                   graph: SkyGraph, sim: SkySimulation, zf: CGFloat,
                                   reveal: Double, focusSet: Set<Int>) {
        let zoom = Double(model.camera.zoom)
        guard zoom > 0.72 || model.focusIndex != nil || model.highlightIndex != nil else { return }
        let margin: CGFloat = 40

        struct Candidate {
            let i: Int
            let anchor: CGPoint
            let alpha: Double
            let priority: Double
        }
        var candidates: [Candidate] = []
        for (i, n) in graph.nodes.enumerated() {
            let degN = sqrt(Double(n.degree) / Double(max(graph.maxDegree, 1)))
            let threshold = n.isRoot ? 0.65 : 1.25 - 0.45 * degN
            let g = model.glow.indices.contains(i) ? model.glow[i] : 0
            var a = max(0, min(1, (zoom - threshold) / 0.4))
            if i == model.focusIndex || i == model.highlightIndex || focusSet.contains(i) {
                a = max(a, g * 0.95)
            }
            if !focusSet.isEmpty && !focusSet.contains(i) { a *= 1 - 0.62 * model.focusBlend }
            guard a > 0.03 else { continue }
            let p = model.toScreen(sim.pos[i], size: size)
            guard p.x > -margin, p.x < size.width + margin, p.y > -margin, p.y < size.height + margin else { continue }
            let r = n.isRoot ? sunClearance(zf) : starRadius(n, maxDegree: graph.maxDegree, zf: zf)
            let priority: Double = i == model.focusIndex ? 3 : (i == model.highlightIndex ? 2 : degN)
            candidates.append(Candidate(i: i, anchor: CGPoint(x: p.x, y: p.y + r + 12), alpha: a, priority: priority))
        }

        candidates.sort { $0.priority != $1.priority ? $0.priority > $1.priority : $0.i < $1.i }
        var placed: [CGRect] = []
        if let card = model.hoverCardRect(in: size) { placed.append(card) }
        for c in candidates {
            var txt = ctx.resolve(Text(graph.nodes[c.i].title).font(.system(size: 11, weight: .medium, design: .default)))
            txt.shading = .color(.white.opacity(0.68 * c.alpha * reveal))
            let sz = txt.measure(in: CGSize(width: 360, height: 60))
            let rect = CGRect(x: c.anchor.x - sz.width / 2, y: c.anchor.y - sz.height / 2, width: sz.width, height: sz.height).insetBy(dx: -6, dy: -3)
            guard !placed.contains(where: { $0.intersects(rect) }) else { continue }
            placed.append(rect)
            ctx.draw(txt, at: c.anchor, anchor: .center)
        }
    }
}

// MARK: - 4. Interactive NightSkyView + SkyHoverCard + SkyDoor (Sentient OS Constellation View)

struct NightSkyView: View {
    @ObservedObject var model: NightSkyModel
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scenePhase
    var showsHUD: Bool = true
    var onOpenNode: (SkyNode) -> Void

    @State private var dragStartLocation: CGPoint? = nil
    @State private var draggedStarIndex: Int? = nil
    @State private var lastPanLocation: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.black

                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reducedMotion || scenePhase != .active)) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, canvasSize in
                        if !model.camera.initialized || (!reducedMotion && scenePhase == .active) {
                            model.tick(now: now, size: canvasSize)
                        }
                        SkyRenderer.draw(ctx, size: canvasSize, model: model, t: now)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartLocation == nil {
                                dragStartLocation = value.startLocation
                                if let hit = model.hitTest(value.startLocation, size: size) {
                                    draggedStarIndex = hit
                                    model.beginDrag(hit)
                                } else {
                                    lastPanLocation = value.startLocation
                                }
                            }
                            if draggedStarIndex != nil {
                                model.dragStar(to: value.location, size: size)
                            } else if let last = lastPanLocation {
                                model.panBy(dx: value.location.x - last.x, dy: value.location.y - last.y)
                                lastPanLocation = value.location
                            }
                        }
                        .onEnded { value in
                            let dist = hypot(
                                value.location.x - (dragStartLocation?.x ?? value.location.x),
                                value.location.y - (dragStartLocation?.y ?? value.location.y)
                            )
                            if dist < 6, let hit = model.hitTest(value.location, size: size),
                               let graph = model.graph, graph.nodes.indices.contains(hit) {
                                onOpenNode(graph.nodes[hit])
                            }
                            if draggedStarIndex != nil {
                                model.endDrag()
                            }
                            dragStartLocation = nil
                            draggedStarIndex = nil
                            lastPanLocation = nil
                        }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let pt):
                        model.updateHover(pt, size: size)
                    case .ended:
                        model.clearHover()
                    }
                }

                // Floating SpinningLogo at the central Sun (Overview / README.md)
                if let sun = model.sunOverlay(size: size) {
                    SpinningLogo(size: sun.diameter, fast: false)
                        .opacity(sun.opacity)
                        .position(sun.center)
                        .allowsHitTesting(false)
                }

                // Hover Card (SkyHoverCard)
                if let info = model.hoverInfo, let rect = model.hoverCardRect(in: size) {
                    SkyHoverCard(info: info)
                        .frame(width: rect.width)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                // Bottom-left Whisper & Zoom Controls HUD
                if showsHUD, let graph = model.graph {
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(graph.nodes.count) STARS · \(graph.edges.count) CONNECTIONS · \(graph.domains.count) CONSTELLATIONS")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .tracking(1.6)
                                    .foregroundStyle(RelayColors.textSecondary)
                                Text("Hover a star to ignite connected notes · Drag stars to bend the constellation · Click any star to inspect its indexed excerpt")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(RelayColors.textMuted)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Button {
                                    model.zoom(by: 1.25, at: CGPoint(x: size.width / 2, y: size.height / 2), size: size)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .frame(width: 32, height: 32)
                                        .background(Color.white.opacity(0.08), in: Circle())
                                        .contentShape(Circle())
                                }
                                .buttonStyle(RelayPressStyle())
                                .help("Zoom in")

                                Button {
                                    model.zoom(by: 0.8, at: CGPoint(x: size.width / 2, y: size.height / 2), size: size)
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .frame(width: 32, height: 32)
                                        .background(Color.white.opacity(0.08), in: Circle())
                                        .contentShape(Circle())
                                }
                                .buttonStyle(RelayPressStyle())
                                .help("Zoom out")

                                Button {
                                    model.fitToContent(in: size)
                                } label: {
                                    Text("Fit")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .padding(.horizontal, 12)
                                        .frame(height: 32)
                                        .background(Color.white.opacity(0.08), in: Capsule())
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(RelayPressStyle())
                                .help("Fit galaxy to viewport")
                            }
                            .foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 18)
                    }
                }
            }
        }
    }
}

struct SkyHoverCard: View {
    let info: SkyHoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(SkyRenderer.domainColor(info.domainIndex))
                    .frame(width: 6, height: 6)
                Text(info.domainName.uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(SkyRenderer.domainColor(info.domainIndex))
                Spacer(minLength: 4)
                if info.recentlyChanged {
                    Text("RECENTLY INDEXED")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(RelayColors.accentCyan)
                }
            }

            Text(info.title)
                .font(.system(size: 16, weight: .semibold, design: .default))
                .foregroundStyle(.white)
                .lineLimit(1)

            if !info.preview.isEmpty {
                Text(info.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineSpacing(3)
                    .lineLimit(2)
            }

            HStack {
                Text("\(info.degree) connected notes")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayColors.textMuted)
                Spacer()
                Text("Click to open →")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayColors.knowledgeLink)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.95), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(SkyRenderer.domainColor(info.domainIndex, alpha: 0.42), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.65), radius: 18, y: 8)
    }
}

/// Sentient OS `SkyDoor`: top-right glowing pill toggling between `Constellation View` and `Markdown Reader`.
struct SkyDoorButton: View {
    let showingSky: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: showingSky ? "book.pages" : "sparkles")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(showingSky ? RelayColors.accentCyan : RelayColors.accentGold)
                Text(showingSky ? "Markdown Reader" : "Constellation View")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("⌘⇧G")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayColors.textMuted)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                RelayColors.accentGold.opacity(0.55),
                                RelayColors.accentAmethyst.opacity(0.55),
                                RelayColors.accentCyan.opacity(0.55)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(RelayPressStyle())
        .keyboardShortcut("g", modifiers: [.command, .shift])
    }
}
