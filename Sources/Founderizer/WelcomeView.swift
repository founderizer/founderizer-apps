import AppKit
import FleetCore
import FleetMark
import SwiftUI

/// **The first page of the first run: the team, its title and its two ways** (the owner, 14 November 2026: "it has to
/// be a specific page, the first page! the onboarding needs to be MUCH nicer, think about this... users JUST installed
/// founderizer! we need some nice visuals, effects, etc... and the option to set it up manually OR copy a prompt and let
/// Claude/Code do it for them"; and to its moving mock, `founderizer-plans/agent-install-pictures/welcome.html`: "I like
/// it!!", then "Yes, build it"). The manager's mark over six agents' marks on a flat arc, the title, and two cards: "Set
/// it up yourself", to the VPS page, and the second way, which copies the prompt for the owner's own agent. The second
/// way names the programs that this Mac has (`AgentPrograms`) and shows no program's logo (his words of the same day: "I
/// have Codex and Claude, not only claude. Your images show the claude icon only... maybe we should not show any
/// specific icon there?"); with neither program on this Mac it is not there, and the first way stands alone in the
/// middle. The two cards stand at one height, the height of the taller one.
///
/// **One sequence of about six seconds, then stillness** (the mock's own times): the manager arrives, its lines grow
/// from it, inner ones first, and each agent arrives where its line ends; the title and the cards fade in; then the
/// manager breathes once and sends one small dot down each line, one after the other, and each agent makes its one
/// move when its dot arrives. **Nothing loops**: every motion is a SwiftUI keyframe timeline with an end (UI-PATTERNS,
/// "Show motion that continues": a SwiftUI animation is right for one short change, never for one without an end), and
/// in this app a mark moves only while its agent works. **A page that plays starts empty**: each timeline's first value
/// is the start of the arrival, so the first frame is the bare canvas and never the settled page; each ends on the
/// settled page exactly, which is what a page that does not play shows from its first frame (Reduce Motion). The one
/// answer after that is to the pointer: over a card, the marks' dots move a little toward it.
///
/// **The page fits its window with no scroll**: in a window of 1280 × 800 or more it is the mock's; in a shorter or a
/// narrower one the team, its lines and their places take one smaller scale, and the two gaps with them.
struct WelcomePage: View {
    let programs: Set<AgentPrograms.Program>
    /// False for a picture of the settled page; the page plays its sequence once when it shows.
    var plays = true
    let setUp: () -> Void
    let letAgent: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The height that the setup page has for its step (`SetupPage`).
    @Environment(\.setupRoom) private var room
    /// Counts the plays of the sequence: one, when the page shows.
    @State private var play = 0
    /// Whether this page plays its sequence: decided at its first frame, so a timeline's first value never changes.
    @State private var starts: Bool?
    /// The card under the pointer: 0 the first way, 1 the second.
    @State private var hovered: Int?
    /// The width of the page's column, and the heights of the title and of the cards, which no scale changes.
    @State private var width: CGFloat = 0
    @State private var titleHeight: CGFloat = 0
    @State private var waysHeight: CGFloat = 0

    var body: some View {
        let starts = starts ?? (plays && !reduceMotion)
        let scale = scale
        VStack(spacing: 0) {
            WelcomeTeam(play: play, starts: starts, look: look)
                .frame(width: TeamPlan.size.width, height: TeamPlan.size.height)
                .scaleEffect(scale)
                .frame(width: TeamPlan.size.width * scale, height: TeamPlan.size.height * scale)
                .animation(reduceMotion ? nil : SetupMetrics.lookCurve, value: hovered)
            VStack(spacing: 0) {
                Text("Your own team of AI agents").font(SetupMetrics.welcomeTitleFont).foregroundStyle(FleetStyle.text)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
                ways
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { waysHeight = $0 }
                    .padding(.top, SetupMetrics.welcomeTitleGap * scale)
            }
            .padding(.top, SetupMetrics.welcomeTeamGap * scale)
            .keyframeAnimator(initialValue: starts ? 0.0 : 1.0, trigger: play) { view, shown in view.opacity(shown) } keyframes: { _ in
                // The title and the cards come at 0.9 s, in half a second.
                KeyframeTrack {
                    MoveKeyframe(0)
                    LinearKeyframe(0, duration: 0.9)
                    LinearKeyframe(1, duration: 0.5, timingCurve: .easeOut)
                }
            }
        }
        // In the middle of the page's column, as a setup step stands (`SetupStep`).
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear {
            self.starts = starts
            if starts { play += 1 }
        }
    }

    /// The two ways, in the VPS page's row of cards (`SetupMetrics.cardsWidth`), at one height.
    private var ways: some View {
        HStack(alignment: .top, spacing: SetupMetrics.wayGap) {
            SetupChoice(title: String(l10n: "Set it up yourself"), line: String(l10n: "Step by step"),
                        mark: { IconTile(size: SetupMetrics.wayTile) { WayChevrons(size: SetupMetrics.wayMark) } },
                        fillsRow: true, choose: setUp)
                .frame(width: Self.cardWidth).onHover { pointer(0, $0) }
                .accessibilityIdentifier("first-run-welcome-self")
            if let title = AgentPrograms.wayTitle(programs) {
                SetupChoice(title: title, line: String(l10n: "Copy one prompt"),
                            mark: { IconTile(size: SetupMetrics.wayTile) { PromptMark(size: SetupMetrics.wayMark) } },
                            fillsRow: true, choose: letAgent)
                    .frame(width: Self.cardWidth).onHover { pointer(1, $0) }
                    .accessibilityIdentifier("first-run-welcome-agent")
            }
        }
        // The row is as high as its taller card, and both cards take that height (`SetupChoice.fillsRow`).
        .fixedSize(horizontal: false, vertical: true)
    }

    private static var cardWidth: CGFloat { (SetupMetrics.cardsWidth - SetupMetrics.wayGap) / 2 }

    /// **One scale for the team, its lines, their places and the two gaps**: 1 where the page fits as the mock has it;
    /// less in a column narrower than the team, and in a window too short for the page with no scroll (`SetupPage`
    /// scrolls a step taller than its room less the band of the window's buttons).
    private var scale: CGFloat {
        let team = TeamPlan.size
        var scale: CGFloat = 1
        if width > 0 { scale = min(scale, width / team.width) }
        if let room {
            let free = room - FleetSpace.lights - titleHeight - waysHeight - 1
            scale = min(scale, free / (team.height + SetupMetrics.welcomeTeamGap + SetupMetrics.welcomeTitleGap))
        }
        return max(SetupMetrics.welcomeLeastScale, scale)
    }

    private func pointer(_ card: Int, _ inside: Bool) {
        if inside { hovered = card } else if hovered == card { hovered = nil }
    }

    /// **Where the marks' dots look** (the mock: up to 7 % of a mark's size toward the card under the pointer, and 6 %
    /// down), as a part of the mark's size. A card alone in the middle is straight under the team.
    private var look: CGSize {
        guard let hovered, !reduceMotion else { return .zero }
        let side: CGFloat = AgentPrograms.names(programs) == nil ? 0 : hovered == 0 ? -0.07 : 0.07
        return CGSize(width: side, height: 0.06)
    }
}

/// **The page after the press on the second way**: a setup step, with Back at the page's top left to the welcome page,
/// the prompt's mark, the title with the names of the programs on this Mac, the prompt in a box of the step's width in
/// the app's own words (never a monospaced font: the owner reads one as a terminal), with its address on a line of its
/// own (`AgentPrompt.lines`), and Copy, which says Copied once the prompt is on the clipboard, as the app's other copy
/// buttons do. What is copied is the prompt on one line (`AgentPrompt.shown`).
struct PastePage: View {
    let programs: Set<AgentPrograms.Program>
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        SetupStep(title: AgentPrograms.pasteTitle(programs)) {
            IconTile(size: SetupMetrics.mark) { PromptMark(size: SetupMetrics.promptMark) }
        } content: {
            Text(verbatim: AgentPrompt.lines(AgentPrompt.shown)).font(SetupMetrics.textFont).foregroundStyle(FleetStyle.text)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SetupMetrics.promptPadding)
                .background(SetupMetrics.promptFill, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(FleetStyle.line, lineWidth: 0.5))
                .frame(width: SetupMetrics.width)
                .accessibilityIdentifier("first-run-prompt")
            Button(copied ? "Copied" : "Copy") { copy() }.buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("first-run-prompt-copy")
        }
    }
}

// MARK: - The team

/// The team of the welcome page: the manager, six agents on a flat arc and the hairlines between them, at the places of
/// the mock (`make_welcome.py`: `MANAGER`, `AGENTS`, `agent_at`, `line`), here relative to the team's own box.
private enum TeamPlan {
    /// How an agent answers the work that reaches it: the one move its mark makes while its agent works.
    enum Move { case breathe, rock, quarterTurn, sixthTurn }

    struct Agent {
        let dx: CGFloat
        let kind: GlyphKind
        /// The place of its hue in `GlyphLook`'s list.
        let tone: Int
        let move: Move
    }

    /// From left to right: circle sky, sparkle amber, hexagon blue, diamond orchid, clover coral, flower rose.
    static let agents = [Agent(dx: -360, kind: .circle, tone: 4, move: .breathe),
                         Agent(dx: -216, kind: .sparkle, tone: 1, move: .quarterTurn),
                         Agent(dx: -72, kind: .hexagon, tone: 5, move: .breathe),
                         Agent(dx: 72, kind: .diamond, tone: 7, move: .rock),
                         Agent(dx: 216, kind: .clover, tone: 0, move: .quarterTurn),
                         Agent(dx: 360, kind: .flower, tone: 8, move: .sixthTurn)]
    /// The manager: the mint squircle.
    static let manager = GlyphLook(kind: .squircle, tone: 3)

    /// The mock's window put the manager's middle at y 208 and its top at 158; the team's box starts at that top.
    private static let top: CGFloat = 208 - SetupMetrics.welcomeManager / 2
    static var size: CGSize {
        let outer = agents.map { abs($0.dx) }.max() ?? 0
        return CGSize(width: 2 * outer + SetupMetrics.welcomeAgent, height: 368 + SetupMetrics.welcomeAgent / 2 - top)
    }
    static var managerAt: CGPoint { CGPoint(x: size.width / 2, y: 208 - top) }
    static func at(_ agent: Agent) -> CGPoint {
        CGPoint(x: size.width / 2 + agent.dx, y: 368 - 0.00014 * agent.dx * agent.dx - top)
    }

    /// The line from the manager to an agent: it leaves down and arrives down.
    static func line(_ agent: Agent) -> Path {
        let from = managerAt, to = at(agent)
        var path = Path()
        path.move(to: from)
        path.addCurve(to: to, control1: CGPoint(x: from.x, y: from.y + 96), control2: CGPoint(x: to.x, y: to.y - 96))
        return path
    }

    /// When each line starts to grow: the inner agents first, 0.07 s apart from 0.28 s.
    static func grows(_ index: Int) -> Double {
        let order = agents.indices.sorted { abs(agents[$0].dx) < abs(agents[$1].dx) || abs(agents[$0].dx) == abs(agents[$1].dx) && $0 < $1 }
        return 0.28 + 0.07 * Double(order.firstIndex(of: index) ?? 0)
    }

    /// The order in which the manager sends work down the lines, 0.45 s apart from 2 s (the mock's `turns`).
    static let turns = [2, 4, 0, 5, 1, 3]
    static func sent(_ index: Int) -> Double { 2.0 + 0.45 * Double(turns.firstIndex(of: index) ?? 0) }

    /// The mock's curves.
    static let arrive = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))
    static let draw = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.3, y: 0.7), endControlPoint: UnitPoint(x: 0.2, y: 1))
    static let travel = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.4, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))
    static let turn = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.3, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))
}

/// The team and its one sequence. `starts`: the page plays, so every timeline's first value is the start of the
/// arrival (nothing shows); else it is the settled page. Every timeline ends on the settled page exactly.
private struct WelcomeTeam: View {
    let play: Int
    let starts: Bool
    /// Where the dots look, as a part of a mark's size.
    let look: CGSize

    var body: some View {
        let size = TeamPlan.size
        ZStack(alignment: .topLeading) {
            ForEach(TeamPlan.agents.indices, id: \.self) { index in
                let line = TeamPlan.line(TeamPlan.agents[index])
                KeyframeAnimator(initialValue: starts ? 0.0 : 1.0, trigger: play) { grown in
                    line.trimmedPath(from: 0, to: grown)
                        .stroke(SetupMetrics.teamLine, style: StrokeStyle(lineWidth: SetupMetrics.teamLineWidth, lineCap: .round))
                } keyframes: { _ in
                    KeyframeTrack {
                        MoveKeyframe(0)
                        LinearKeyframe(0, duration: TeamPlan.grows(index))
                        LinearKeyframe(1, duration: 0.6, timingCurve: TeamPlan.draw)
                    }
                }
            }
            ForEach(TeamPlan.agents.indices, id: \.self) { index in
                WorkDot(line: TeamPlan.line(TeamPlan.agents[index]), sent: TeamPlan.sent(index), play: play)
            }
            WelcomeMark(look: TeamPlan.manager, size: SetupMetrics.welcomeManager, dot: UnitPoint(x: 0.655, y: 0.345),
                        dotSize: 0.19, eyes: look, timeline: .manager, play: play, starts: starts)
                .position(TeamPlan.managerAt)
            ForEach(TeamPlan.agents.indices, id: \.self) { index in
                let agent = TeamPlan.agents[index]
                WelcomeMark(look: GlyphLook(kind: agent.kind, tone: agent.tone), size: SetupMetrics.welcomeAgent,
                            dot: .center, dotSize: 0.18, eyes: look,
                            timeline: .agent(arrives: TeamPlan.grows(index) + 0.34, moves: TeamPlan.sent(index) + 0.72,
                                             move: agent.move),
                            play: play, starts: starts)
                    .position(TeamPlan.at(agent))
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// One small white dot that goes from the manager to an agent once, at its time: work sent down that line. It shows
/// only while it travels.
private struct WorkDot: View {
    let line: Path
    let sent: Double
    let play: Int

    private struct Travel { var along = 1.0; var opacity = 0.0 }

    var body: some View {
        KeyframeAnimator(initialValue: Travel(), trigger: play) { travel in
            let at = travel.along > 0 ? line.trimmedPath(from: 0, to: travel.along).currentPoint : line.currentPoint
            Circle().fill(Color.white).frame(width: SetupMetrics.workDot, height: SetupMetrics.workDot)
                .opacity(travel.opacity)
                .position(at ?? .zero)
        } keyframes: { _ in
            KeyframeTrack(\.along) {
                MoveKeyframe(0)
                LinearKeyframe(0, duration: sent)
                LinearKeyframe(1, duration: 0.8, timingCurve: TeamPlan.travel)
            }
            KeyframeTrack(\.opacity) {
                MoveKeyframe(0)
                LinearKeyframe(0, duration: sent)
                LinearKeyframe(0.9, duration: 0.096)
                LinearKeyframe(0.9, duration: 0.584)
                LinearKeyframe(0, duration: 0.12)
            }
        }
    }
}

/// One mark of the welcome page: the shape and the hues of `FleetMark` with the mock's dot, a white dot with a soft ring,
/// in place of the mark's inner mark. `GlyphLook` gives the hues; `AgentGlyph` is not used, because these marks are
/// nobody's and move by this page's timeline only.
private struct WelcomeMark: View {
    enum Timeline {
        case manager
        case agent(arrives: Double, moves: Double, move: TeamPlan.Move)
    }

    let look: GlyphLook
    let size: CGFloat
    /// The dot's middle, in the mark's square.
    let dot: UnitPoint
    /// The dot's side, as a part of the mark's; its ring is 1.75 times as wide.
    let dotSize: CGFloat
    /// Where the dot looks (`WelcomePage.look`).
    let eyes: CGSize
    let timeline: Timeline
    let play: Int
    /// The page plays: the mark's first value is the start of its arrival.
    let starts: Bool

    private struct Pose { var scale = 1.0; var opacity = 1.0; var angle = 0.0 }

    var body: some View {
        KeyframeAnimator(initialValue: starts ? Pose(scale: 0.5, opacity: 0, angle: 0) : Pose(), trigger: play) { pose in
            figure(angle: pose.angle).scaleEffect(pose.scale).opacity(pose.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.scale) { scale }
            KeyframeTrack(\.opacity) { opacity }
            KeyframeTrack(\.angle) { angle }
        }
        .frame(width: size, height: size)
    }

    /// **Only the outline turns or rocks**: its gradient stays fixed in the mark's square, so the light corner is at the
    /// top left before, during and after a turn; and the dot stays where it looks.
    private func figure(angle: Double) -> some View {
        ZStack {
            GlyphOutline(kind: look.kind).rotation(.degrees(angle))
                .fill(LinearGradient(colors: [look.light, look.deep], startPoint: UnitPoint(x: 0.08, y: 0.08),
                                     endPoint: UnitPoint(x: 0.92, y: 0.92)))
            ZStack {
                Circle().fill(SetupMetrics.markDotRing).frame(width: size * dotSize * 1.75, height: size * dotSize * 1.75)
                Circle().fill(SetupMetrics.markDot).frame(width: size * dotSize, height: size * dotSize)
            }
            .position(x: size * (dot.x + eyes.width), y: size * (dot.y + eyes.height))
        }
        .frame(width: size, height: size)
    }

    /// When the mark arrives (scale 0.5 to 1 with its opacity, 0.8 s) and when it makes its one move.
    private var times: (arrives: Double, moves: Double, move: TeamPlan.Move) {
        switch timeline {
        case .manager: (0, 1.75, .breathe)
        case let .agent(arrives, moves, move): (arrives, moves, move)
        }
    }

    @KeyframeTrackContentBuilder<Double> private var scale: some KeyframeTrackContent<Double> {
        let (arrives, moves, move) = times
        MoveKeyframe(0.5)
        LinearKeyframe(0.5, duration: arrives)
        LinearKeyframe(1, duration: 0.8, timingCurve: TeamPlan.arrive)
        LinearKeyframe(1, duration: moves - arrives - 0.8)
        // A breath: to 1.14 at 45 % of one second, and back.
        LinearKeyframe(move == .breathe ? 1.14 : 1, duration: 0.45, timingCurve: .easeInOut)
        LinearKeyframe(1, duration: 0.55, timingCurve: .easeInOut)
    }

    @KeyframeTrackContentBuilder<Double> private var opacity: some KeyframeTrackContent<Double> {
        let arrives = times.arrives
        MoveKeyframe(0)
        LinearKeyframe(0, duration: arrives)
        LinearKeyframe(1, duration: 0.8, timingCurve: TeamPlan.arrive)
    }

    /// A quarter turn (sparkle, clover) or a sixth (flower) ends where the shape looks as it began, and then stands at
    /// 0° again in no time, which shows the same outline, and stays there for a last moment of the timeline: so the
    /// timeline's last value is 0° and the settled mark is the one that never turned (a jump that ended the timeline
    /// was not held: the mark stayed at 90°, a few pixels off the settled page). A rock goes 9° to each side and back,
    /// in 1.1 s.
    @KeyframeTrackContentBuilder<Double> private var angle: some KeyframeTrackContent<Double> {
        let (_, moves, move) = times
        MoveKeyframe(0)
        LinearKeyframe(0, duration: moves)
        switch move {
        case .breathe: LinearKeyframe(0, duration: 1)
        case .quarterTurn:
            LinearKeyframe(90, duration: 1.1, timingCurve: TeamPlan.turn)
            MoveKeyframe(0)
            LinearKeyframe(0, duration: 0.05)
        case .sixthTurn:
            LinearKeyframe(60, duration: 1.1, timingCurve: TeamPlan.turn)
            MoveKeyframe(0)
            LinearKeyframe(0, duration: 0.05)
        case .rock:
            LinearKeyframe(-9, duration: 0.33, timingCurve: .easeInOut)
            LinearKeyframe(9, duration: 0.44, timingCurve: .easeInOut)
            LinearKeyframe(0, duration: 0.33, timingCurve: .easeInOut)
        }
    }
}

// MARK: - The line marks of the two ways

/// The product's chevrons as a line mark (`FounderizerMark.chevrons`, without the plate), in the colour of the tile's
/// words: the mark of "Set it up yourself".
struct WayChevrons: View {
    let size: CGFloat

    var body: some View {
        // The mock draws the chevrons' box from 96 to 416 of the original 512, with strokes of 44 and 54 there.
        let scale = size / 320, widths: [CGFloat] = [44, 54]
        ZStack {
            ForEach(0..<FounderizerMark.chevrons.count, id: \.self) { index in
                Path { path in
                    let points = FounderizerMark.chevrons[index].points.map { CGPoint(x: ($0.x - 96) * scale, y: ($0.y - 96) * scale) }
                    path.addLines(points)
                }
                .stroke(style: StrokeStyle(lineWidth: widths[index] * scale, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

/// **A plain prompt: a ">" and a short line** (the mark of the second way, and of the page after its press). Never a
/// program's own logo: the way is the same for Claude Code and for Codex.
struct PromptMark: View {
    let size: CGFloat

    var body: some View {
        // The mock's 22-point drawing, with a stroke of 2.3 there.
        let scale = size / 22
        Path { path in
            path.addLines([CGPoint(x: 3.5, y: 5), CGPoint(x: 10.5, y: 11), CGPoint(x: 3.5, y: 17)].map { $0.applying(.init(scaleX: scale, y: scale)) })
            path.move(to: CGPoint(x: 12.5 * scale, y: 17 * scale))
            path.addLine(to: CGPoint(x: 19 * scale, y: 17 * scale))
        }
        .stroke(style: StrokeStyle(lineWidth: 2.3 * scale, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
    }
}
