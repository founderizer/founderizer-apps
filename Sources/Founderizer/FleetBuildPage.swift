import FleetCore
import SwiftUI

/// **The first run's build page** (slice 3 of the one wizard; the owner's "that is brilliant!" of 16 November 2026 to
/// the build page's picture in `~/dev/founderizer-plans/one-wizard-build-page/`): the fleet as the page "Your fleet"
/// drew it, each server with its own line under its box (`FleetBuildLine`), the title over it ("Building your fleet",
/// moving while it builds), and what the owner does on the page under the fleet (`below`), nothing else. The first
/// run goes on by itself when the build ends: its page has no end of its own.
struct FleetBuildPage<Mark: View, Below: View>: View {
    let title: String
    let waits: Bool
    let plan: FleetPlan
    let step: ServersStep
    /// One line for each box of `ServerBoxes`, by its place: nil for a box that the build does not make (an agent's
    /// server to come).
    let rows: [FleetBuildRow?]
    /// A server's choice after a refusal of it (`ServerBoxChoice` with its `why` and its press), by the box's place.
    var choices: [ServerBoxChoice?] = []
    @ViewBuilder let mark: () -> Mark
    @ViewBuilder let below: () -> Below

    /// The page is as wide as the picture's graph: two servers with their lines and two agents' servers to come stand
    /// in one row.
    static var width: CGFloat { 700 }

    var body: some View {
        SetupStep(title: title, waits: waits, width: Self.width) { mark() } content: {
            VStack(spacing: SetupMetrics.gap) {
                ServerBoxes(plan: plan, step: step, choices: choices, rows: rows)
                below()
            }
        }
    }
}

/// **One server's line on the build page** (`FleetBuildRow`): its words, the minutes left in the muted colour after
/// them, the owner's turn in orange with no minutes, and under them the bar of four parts (VPS, Network, Install,
/// Checks) as the picture has it: a part that is done in the words' faded colour, the part that runs in green as far as
/// its steps ended, the rest empty. **The part that runs breathes** (the owner's "Yes, as drawn" of 22 November 2026 to
/// F4's picture P7: "each bar fills by the steps that ended, its part in work breathing"), at least as wide as it is
/// thick, so a part with no step ended yet still shows that it works; with Reduce Motion it stands still. A box with no
/// line keeps the line's room, so the boxes of a row stay level.
struct FleetBuildLine: View {
    let row: FleetBuildRow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The line's width, which its box takes at least: the words change as the build goes on, and the box keeps its size.
    /// The longest Spanish line ("Instalando actualizaciones de seguridad · 13 min", 273.9 points at 12, measured by
    /// the review of 17 November 2026) fits at its smallest size.
    static let width: CGFloat = 240
    static let part: CGFloat = 34, gap: CGFloat = 4, thickness: CGFloat = 3

    var body: some View {
        if row == nil {
            // A box with no line keeps only the line's height, so that the boxes of a row stay level and narrow.
            VStack(spacing: 7) {
                Text(verbatim: " ").font(ShapeMetrics.underFont).lineLimit(1)
                Color.clear.frame(height: Self.thickness)
            }
            .frame(width: 1).hidden()
        } else {
            line
        }
    }

    private var line: some View {
        VStack(spacing: 7) {
            words.font(ShapeMetrics.underFont).lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: Self.gap) {
                ForEach(0..<InstallPhases.names.count, id: \.self) { index in
                    let share = self.share(index), runs = index == running
                    Capsule().fill(Color.white.opacity(0.10))
                        .overlay(alignment: .leading) {
                            // The part that runs is its breath alone, whose light comes and goes; green with Reduce Motion.
                            Capsule().fill(share >= 1 ? FleetStyle.text.opacity(0.62)
                                           : runs && !reduceMotion ? Color.clear : Color.green)
                                .overlay { if runs, !reduceMotion { BreathingPart(color: NSColor(Color.green)) } }
                                .frame(width: runs ? max(Self.thickness, Self.part * share) : Self.part * share)
                        }
                        .frame(width: Self.part, height: Self.thickness)
                }
            }
            .opacity(row?.parts == nil ? 0 : 1)
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row?.words ?? "")
        .accessibilityHidden(row?.words == nil)
    }

    /// The part that runs: the first that is not full, while the row is no owner's turn.
    private var running: Int? {
        guard let row, !row.ownersTurn, let parts = row.parts else { return nil }
        return parts.firstIndex { $0 < 1 }
    }

    private func share(_ index: Int) -> CGFloat {
        guard let parts = row?.parts, parts.indices.contains(index) else { return 0 }
        return CGFloat(min(1, max(0, parts[index])))
    }

    private var words: Text {
        guard let row, let words = row.words else { return Text(verbatim: " ") }
        let main = Text(words).foregroundColor(row.ownersTurn ? .orange : FleetStyle.text)
        guard let minutes = row.minutes, !row.ownersTurn else { return main }
        return main + Text(verbatim: " · ").foregroundColor(FleetStyle.muted)
            + Text(String(l10n: "\(minutes) min")).foregroundColor(FleetStyle.muted)
    }
}
