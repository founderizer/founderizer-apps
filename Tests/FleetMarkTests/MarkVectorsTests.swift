import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FleetMark

/// **The vectors of an agent's mark, from FleetMark itself** (`app/vectors/agent-marks.json`): for each name its shape,
/// its tone, its two colours, its phase and its next looks; the looks of whole teams; and for each shape its motion,
/// the anchor of its inner mark, and its outline and inner mark as path data in a square of 100. The Windows app's
/// library (`windows/Founderizer.Core`) draws the same marks from this file: its tests hold its marks equal to it.
///
/// With `FOUNDERIZER_VECTORS_OUT` set, the test writes the file into that folder (`app/vectors/make_vectors.py` does,
/// and its `--check` compares); without it, the test holds the committed file equal to what FleetMark gives now.
struct MarkVectorsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")
    static let file = "agent-marks.json"

    /// The sample fleet's agents, the owner's fleet as AgentMarkTests holds it, and example names of every form that
    /// team.json takes (a-z, 0-9, - and _).
    static let names = ["manager", "wren", "theo", "pax", "orla", "vps", "studio", "mini", "scout", "dev-lead",
                        "web_dev", "worker-1", "worker-2", "support", "ops", "qa", "x", "alpha", "beta", "gamma",
                        "delta", "nova", "iris", "juno", "atlas", "ada", "leo", "mia", "ivy", "sales-bot", "a1b2c3",
                        "research", "billing", "design", "growth", "Manager"]

    /// Teams in the hub's order: the sample fleet, the owner's fleet, and teams larger than the eleven shapes and the
    /// nine hues, where the team rule starts again.
    static let teams: [[String]] = [
        ["manager", "wren", "theo", "pax", "orla"],
        ["manager", "vps", "studio", "mini", "scout"],
        ["manager", "nova", "iris", "juno", "atlas", "ada", "leo", "mia", "ivy", "alpha", "beta", "gamma", "delta"],
        ["support", "ops", "qa", "x", "sales-bot", "research", "billing", "design", "growth", "worker-1", "worker-2",
         "dev-lead", "web_dev", "a1b2c3"],
        ["manager", "manager", "wren"],
    ]

    struct Look: Codable { let name: String; let kind: String; let tone: Int; let phase: Double }
    struct Named: Codable {
        let name: String; let kind: String; let tone: Int; let light: [Double]; let deep: [Double]; let phase: Double
        let next: [Look]
    }
    struct Team: Codable { let names: [String]; let looks: [Look] }
    struct Shape: Codable {
        let kind: String; let motion: String; let core_anchor: [Double]; let outline: String; let core: String
    }
    struct Document: Codable {
        let about: String; let made_by: String; let core_opacity: Double; let tone_count: Int; let kinds: [String]
        let names: [Named]; let teams: [Team]; let shapes: [Shape]
    }

    static func number(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        let rounded = (value * scale).rounded() / scale
        return rounded == 0 ? 0 : rounded
    }

    static func rgb(_ color: Color) -> [Double] {
        let resolved = NSColor(color).usingColorSpace(.sRGB)!
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent].map { number(Double($0), places: 3) }
    }

    /// A path as SVG path data: M, L, Q, C and Z, each number with at most two decimals.
    static func data(_ path: Path) -> String {
        func n(_ value: CGFloat) -> String {
            var text = String(format: "%.2f", Double(value))
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text == "-0" ? "0" : text
        }
        func p(_ point: CGPoint) -> String { "\(n(point.x)) \(n(point.y))" }
        var parts: [String] = []
        path.forEach { element in
            switch element {
            case .move(let to): parts.append("M\(p(to))")
            case .line(let to): parts.append("L\(p(to))")
            case .quadCurve(let to, let control): parts.append("Q\(p(control)) \(p(to))")
            case .curve(let to, let one, let two): parts.append("C\(p(one)) \(p(two)) \(p(to))")
            case .closeSubpath: parts.append("Z")
            }
        }
        return parts.joined(separator: " ")
    }

    static func look(_ name: String, _ look: GlyphLook) -> Look {
        Look(name: name, kind: look.kind.rawValue, tone: look.tone, phase: look.phase)
    }

    static func document() throws -> Data {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        let named = names.map { name -> Named in
            let first = GlyphLook(name: name)
            return Named(name: name, kind: first.kind.rawValue, tone: first.tone, light: rgb(first.light),
                         deep: rgb(first.deep), phase: first.phase,
                         next: (1...3).map { look(name, GlyphLook(name: name, attempt: $0)) })
        }
        let teams = teams.map { team -> Team in
            let looks = GlyphLook.team(team)
            var seen = Set<String>()
            return Team(names: team, looks: team.filter { seen.insert($0).inserted }.map { look($0, looks[$0]!) })
        }
        let shapes = GlyphKind.allCases.map { kind -> Shape in
            let motion: String = switch kind.motion { case .turn: "turn"; case .breathe: "breathe"; case .rock: "rock" }
            return Shape(kind: kind.rawValue, motion: motion,
                         core_anchor: [number(kind.coreAnchor.x, places: 3), number(kind.coreAnchor.y, places: 3)],
                         outline: data(GlyphOutline(kind: kind).path(in: square)),
                         core: data(GlyphCore(kind: kind).path(in: square)))
        }
        let document = Document(
            about: "An agent's mark as FleetMark gives it (Sources/FleetMark/AgentMark.swift): GlyphLook of each name and of "
                + "each team, and each shape's motion, inner-mark anchor, outline and inner mark as SVG path data in a "
                + "square of 100. Colours are sRGB from 0 to 1. The gradient runs from light at the top left to deep at the "
                + "bottom right; the inner mark is white at core_opacity, and the moon's is its light colour.",
            made_by: "app/Tests/FleetMarkTests/MarkVectorsTests.swift", core_opacity: GlyphLook.coreOpacity,
            tone_count: GlyphLook.toneCount, kinds: GlyphKind.allCases.map(\.rawValue), names: named, teams: teams,
            shapes: shapes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document) + Data("\n".utf8)
    }

    @Test("The marks' vectors are what FleetMark gives now")
    func theMarksVectorsAreTheCommittedFile() throws {
        let made = try Self.document()
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            try made.write(to: URL(fileURLWithPath: out).appendingPathComponent(Self.file))
            return
        }
        let committed = try Data(contentsOf: Self.folder.appendingPathComponent(Self.file))
        #expect(committed == made, "app/vectors/\(Self.file) is not what FleetMark gives: run app/vectors/make_vectors.py")
    }
}
