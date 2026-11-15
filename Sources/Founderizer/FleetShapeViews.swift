import AppKit
import FleetCore
import FleetMark
import SwiftUI

// The first run's new pages, as the owner approved their ten pictures on 14 November 2026 ("Yes, as shown"; then
// "build it!"): the page "Name your manager", the page "Your fleet's servers" with its slider, and the card "Your
// fleet" with its graph. Their rules are `FleetShape.swift` and `FleetGraphLayout.swift` in FleetCore. **No page of
// the app shows them yet**: the conversation that leads to them is not built, so the first run is today's first run.

/// The measures of the three views. The graph's places are `FleetGraphLayout`'s.
enum ShapeMetrics {
    /// A machine's box and a part's tile: a row's fill and edge, and a tile's fill.
    static let islandFill = Color.white.opacity(0.05), islandEdge = Color.white.opacity(0.10)
    static let tileFill = Color.white.opacity(0.07), tileInk = Color(white: 0.82)
    /// A line of the graph: a field's edge, white 0.32 at 1.5 pt. A dotted line is the same line in dots.
    static let line = Color.white.opacity(0.32), lineWidth: CGFloat = 1.5
    static let dots: [CGFloat] = [0.1, 5.2]
    /// The graph's words: a part's name, and the one muted line under it.
    static let nameFont = Font.system(size: 13, weight: .medium), underFont = Font.system(size: 12)
    static let nameLine: CGFloat = 18, underLine: CGFloat = 16
    /// The small mark at the top right of a machine's box, which says what the box is.
    static let kindMark: CGFloat = 11, kindInset: CGFloat = 10
    /// The card "Your fleet": its width is the graph's with the card's inset at each side.
    static let cardInset: CGFloat = 16
    /// The slider: its width is the step's column, and its track stands 30 pt in at each end. **It looks like a thing
    /// that moves** (the owner, 15 November 2026: "make it more obvious that the slider can move"): a thicker track,
    /// filled up to the knob, and a knob that is a raised capsule with two chevrons in it.
    static let trackInset: CGFloat = 30, trackHeight: CGFloat = 6, stepDot: CGFloat = 10
    static let knobWidth: CGFloat = 46, knobHeight: CGFloat = 28, knobChevron: CGFloat = 10
    static let trackFill = Color.white.opacity(0.10), trackDone = Color.white.opacity(0.34)
    static let stepFill = Color(white: 0.42), stepDone = Color.white.opacity(0.62)
    static let sliderHeight: CGFloat = 84, trackY: CGFloat = 40, countsY: CGFloat = 74
    /// **The page's levels of type** (the owner, 15 November 2026: "improve the style even more, all labels look the
    /// same, no visual hierarchy"): the card's headline, the chosen step, the other steps, the slider's two ends, and
    /// the card's last line, which says what the step risks.
    static let headlineFont = Font.system(size: 17, weight: .semibold)
    static let chosenFont = Font.system(size: 15, weight: .semibold), stepFont = Font.system(size: 13)
    static let endFont = Font.system(size: 12, weight: .medium), riskFont = Font.system(size: 13)
    /// The room of the step's second sentence: two lines, so that the card keeps its height from step to step.
    static let riskHeight: CGFloat = 42
    /// **The page "Your fleet's servers"**: its column, as wide as a step with three cards in a row; a server's box
    /// with its one line of words over what runs on it; and each thing that runs there, a 36-pt mark over its name in a
    /// 64-pt column.
    static let serversWidth: CGFloat = SetupMetrics.cardsWidth
    static let serverMark: CGFloat = 36, serverTile: CGFloat = 64, serverGap: CGFloat = 10
    /// The manager's mark on the page "Name your manager": larger than a step's mark, because the page is about it.
    static let managerMark: CGFloat = 72

    /// The width of a role's words in the graph's type, for the start of a dotted line.
    @MainActor static func nameWidth(_ words: String) -> CGFloat {
        (words as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width.rounded(.up)
    }
}

// MARK: - Name your manager

/// **The page "Name your manager"**: the manager's own mark, the title with one line under it that says what a manager
/// is, the field with a name in it, and Continue. The mark is the one that a manager of that name gets, so it follows
/// the name. Continue and Return go on only with a name that the installer takes; with any other words the field wears
/// its orange edge and Continue does not show.
///
/// **It asks for no AI provider** (the owner, 15 November 2026, of the two provider cards of picture 01: "the
/// codex/claude etc will be on a future step because we're adding so many AI providers and options , right??? like
/// grok google etc.. and during onboarding we don't even have a server yet!"): the manager's own setup asks for it,
/// once its server runs.
struct NameManagerPage: View {
    @Binding var name: String
    /// The hub's own words when it refused the name (the manager's own setup, where Continue renames the manager).
    var stopped: String?
    /// A request is on its way: Continue waits for it.
    var busy = false
    let go: () -> Void

    private var agentName: String? { ManagerName.agentName(name) }

    var body: some View {
        SetupStep(title: String(l10n: "Name your manager"),
                  detail: String(l10n: "It leads your team and is your main assistant.")) {
            AgentGlyph(name: agentName ?? ManagerName.fallback, size: ShapeMetrics.managerMark, dot: false)
                .environment(\.glyphTeam, [agentName ?? ManagerName.fallback])
        } content: {
            SetupField(placeholder: String(l10n: "Name"), text: $name, wrong: !name.isEmpty && agentName == nil) {
                if agentName != nil, !busy { go() }
            }
            .accessibilityIdentifier("first-run-manager-name")
            if let stopped { SetupWarning(stopped).accessibilityIdentifier("manager-name-stopped") }
            // Continue keeps its room while it does not show, so that the page does not move while he types.
            SetupAction {
                Button("Continue") { go() }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .opacity(agentName == nil ? 0 : 1).disabled(agentName == nil || busy).accessibilityHidden(agentName == nil)
                    .accessibilityIdentifier("first-run-manager-continue")
            }
        }
    }
}

// MARK: - Your fleet's servers

/// **The page "Your fleet's servers"** (pictures 04 to 06, and the owner's words of 15 November 2026: "expand more
/// the other screes, more breathing and better grahic for the servers etc so it is more clear and visually attractive,
/// also add subtitles"): the title with one line under it, the slider from the lower cost to the more secure, one card
/// for the chosen step with a box for each server and what runs on it, the step's two sentences, and Continue.
/// It shows no price: it stands before the provider's token.
///
/// **Before a team exists the card draws the agents to come** (`ServersSketch`): in the first run the fleet is the hub
/// and the manager, and without those agents the last two steps would be the same drawing.
struct FleetServersPage: View {
    let plan: FleetPlan
    @Binding var step: ServersStep
    /// What stopped the step that he chose, in orange over Continue: the hub's own words, or the words of this Mac's
    /// step on the hub's server (the manager's own setup, where Continue keeps the step on the hub).
    var stopped: String?
    /// A request is on its way: Continue waits for it.
    var busy = false
    let go: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    /// The words under each step: a count for a team, and the sketch's words before one exists.
    private var counts: [String] {
        ServersStep.allCases.map { plan.agents.isEmpty ? ServersSketch.words($0) : plan.count($0).serverWords }
    }

    var body: some View {
        SetupStep(title: String(l10n: "Your fleet's servers"), width: ShapeMetrics.serversWidth,
                  detail: String(l10n: "Fewer servers cost less. More servers keep your agents apart.")) {
            IconTile(symbol: "server.rack", size: SetupMetrics.mark).accessibilityHidden(true)
        } content: {
            ServersSlider(step: $step, counts: counts).padding(.top, 6)
            // The card reads from the top: the step's headline, its servers, and what it risks in the quiet line under them.
            VStack(spacing: 16) {
                Text(step.fact).font(ShapeMetrics.headlineFont).foregroundStyle(FleetStyle.text)
                ServerBoxes(plan: plan, step: step)
                Text(step.risk).font(ShapeMetrics.riskFont).foregroundStyle(FleetStyle.muted).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: ShapeMetrics.riskHeight, alignment: .top)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
                .strokeBorder(FleetStyle.line, lineWidth: FleetStyle.edgeWidth(contrast)))
            .environment(\.glyphTeam, plan.names).environment(\.glyphDots, false)
            if let stopped { SetupWarning(stopped).accessibilityIdentifier("fleet-servers-stopped") }
            // In a window too low for the page, Continue stays in view at the window's bottom (`SetupAction`).
            SetupAction {
                Button("Continue") { go() }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(busy)
                    .accessibilityIdentifier("first-run-servers-continue")
            }
        }
    }
}

/// **The servers of a step, each a box with what runs on it**: one line of words over the box's content says what the
/// box is ("Server", or "Mac"), and each thing that runs there is its mark over its name: the hub, the manager by its
/// name, each agent by its role, and, before a team exists, each agent to come as a dotted ring over "Agent".
///
/// **A later change of a fleet that runs** (`change`, Settings › Servers; the owner's yes of 15 November 2026 to the
/// pictures in `~/dev/founderizer-plans/shape-change-later/`) draws the servers after it: a server that is there has its
/// name over its box, a server that the change makes says "New server" and has an edge in the dots of the agents to
/// come. While the change runs, an agent that is not on its new server yet is faint (`later`), and one that waits for
/// the owner wears its dot (`waits`). Without `change`, the first run's pages are drawn as before.
struct ServerBoxes: View {
    let plan: FleetPlan
    let step: ServersStep
    var change: ShapeChangePlan?
    var later: Set<String> = []
    var waits: [String: AgentPresence] = [:]

    /// `named`: an agent of a fleet that runs, by its own name (a later change).
    private enum Tile: Hashable { case hub, manager, agent(Int), next, named(String) }
    /// In a box, at most this many things stand in one row.
    private static let row = 6

    private var boxes: [(mac: Bool, tiles: [Tile], title: String?, new: Bool)] {
        if let change {
            return change.boxes.map { box in
                (box.mac, (box.hub ? [Tile.hub] : []) + box.agents.map(Tile.named),
                 box.server ?? String(l10n: "New server"), box.server == nil && !box.hub)
            }
        }
        guard !plan.agents.isEmpty else {
            return ServersSketch.servers(step).map { parts in
                (false, parts.map { $0 == .hub ? Tile.hub : $0 == .manager ? .manager : .next }, nil, false)
            }
        }
        return plan.places(step).map { place in
            (place.kind == .mac, place.parts.map { part in
                switch part {
                case .hub: Tile.hub
                case .manager: .manager
                case .agent(let index): .agent(index)
                }
            }, nil, false)
        }
    }

    var body: some View {
        CenteredRows(spacing: ShapeMetrics.serverGap) {
            ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                VStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Image(systemName: box.mac ? "desktopcomputer" : "server.rack").font(IconMetrics.symbol(ShapeMetrics.kindMark))
                        Text(box.title ?? (box.mac ? String(l10n: "Mac") : String(l10n: "Server"))).font(ShapeMetrics.underFont)
                    }
                    .foregroundStyle(FleetStyle.muted).accessibilityHidden(true)
                    VStack(spacing: 10) {
                        ForEach(Array(stride(from: 0, to: box.tiles.count, by: Self.row)), id: \.self) { start in
                            HStack(alignment: .top, spacing: 4) {
                                ForEach(Array(box.tiles[start..<min(start + Self.row, box.tiles.count)].enumerated()), id: \.offset) { _, tile in
                                    VStack(spacing: 7) {
                                        mark(tile)
                                        Text(name(tile)).font(ShapeMetrics.nameFont)
                                            .foregroundStyle(tile == .next ? FleetStyle.muted : FleetStyle.text)
                                            .lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                    .frame(width: ShapeMetrics.serverTile)
                                    .opacity(agent(tile).map(later.contains) == true ? 0.35 : 1)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 12)
                .background(ShapeMetrics.islandFill, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                .overlay {
                    if box.new {
                        RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(ShapeMetrics.line,
                            style: StrokeStyle(lineWidth: ShapeMetrics.lineWidth, lineCap: .round, dash: ShapeMetrics.dots))
                    } else {
                        RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(ShapeMetrics.islandEdge, lineWidth: 0.5)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(box.title ?? (box.mac ? String(l10n: "A Mac") : String(l10n: "A server")))
            }
        }
        // Only a change's own states: without one, each glyph keeps what the window knows of its agent.
        .transformEnvironment(\.glyphPresence) { presence in if change != nil { presence = waits } }
    }

    /// The agent of a tile, for its state while a change runs.
    private func agent(_ tile: Tile) -> String? {
        switch tile {
        case .manager: plan.names.first
        case .agent(let index): plan.agents[index].name
        case .named(let name): name
        case .hub, .next: nil
        }
    }

    @ViewBuilder private func mark(_ tile: Tile) -> some View {
        switch tile {
        case .hub: HubTile(size: ShapeMetrics.serverMark)
        case .manager: AgentGlyph(name: plan.names[0], size: ShapeMetrics.serverMark, dot: waits[plan.names[0]] != nil)
        case .agent(let index): AgentGlyph(name: plan.agents[index].name, size: ShapeMetrics.serverMark,
                                           dot: waits[plan.agents[index].name] != nil)
        case .named(let name): AgentGlyph(name: name, size: ShapeMetrics.serverMark, dot: waits[name] != nil)
        case .next:
            Circle().strokeBorder(ShapeMetrics.line, style: StrokeStyle(lineWidth: ShapeMetrics.lineWidth, lineCap: .round, dash: [0.1, 5.2]))
                .frame(width: ShapeMetrics.serverMark, height: ShapeMetrics.serverMark).accessibilityHidden(true)
        }
    }

    private func name(_ tile: Tile) -> String {
        switch tile {
        case .hub: String(l10n: "Hub")
        case .manager: ManagerName.shown(plan.manager)
        case .agent(let index): plan.agents[index].role
        case .named(let name): name.agentLabel
        case .next: String(l10n: "Agent")
        }
    }
}

/// **The slider of the page "Your fleet's servers"**: "Lower cost" and "More secure" over its two ends, a dot for each
/// step on the track, the knob on the chosen one, and each step's count of servers under it, the chosen one in the
/// text's colour. A press on a step or on its count chooses it, and the arrow keys move it one step. **It shows that
/// it moves** (the owner, 15 November 2026: "make it more obvious that the slider can move"): the knob is a raised
/// capsule with two chevrons, the track is filled up to it, the pointer is an open hand over the slider and a closed
/// one while it drags, and the knob follows the drag itself, then settles on the nearest step when he lets go.
struct ServersSlider: View {
    @Binding var step: ServersStep
    /// The words under each step, in the steps' order.
    let counts: [String]
    /// **He let go of the knob** (Settings › Servers, whose slider opens the page of a change): at the end of a drag
    /// and of a press, at Return after the arrow keys, and at VoiceOver's own press. nil on the first run's page, where
    /// the step itself is the answer.
    var settled: ((ServersStep) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    /// Where a drag holds the knob, between the track's two ends; nil while nothing holds it.
    @State private var held: CGFloat?
    /// How far the knob's middle stands from the pointer in this drag: a knob that he takes at its edge stays under the
    /// pointer, and a press beside the knob slides it there.
    @State private var grab: CGFloat?
    /// True while a drag holds the knob. SwiftUI sets it back by itself when the drag ends and also when macOS cancels
    /// it, which calls no `onEnded`: the knob then settles all the same, and the pointer is an open hand again.
    @GestureState private var dragging = false
    /// **The pointer was the last to move the slider**: the knob then wears no focus ring. A press also gives the slider
    /// the keyboard's focus, and the ring is the keyboard's sign only (a Tab onto the slider, or an arrow key), as on the
    /// system's own controls: after a press it stood on the knob as a blue ring that nothing explained.
    @State private var byPointer = false

    private static let steps = ServersStep.allCases

    var body: some View {
        GeometryReader { room in
            // The track ends where the words under its two end steps still stand inside the slider.
            let inset = max(ShapeMetrics.trackInset, ([counts.first, counts.last].compactMap { $0 }.map(Self.width).max() ?? 0) / 2)
            let track = room.size.width - 2 * inset
            let x = { (index: Int) in inset + track * CGFloat(index) / CGFloat(Self.steps.count - 1) }
            let nearest = { (place: CGFloat) in
                Self.steps[min(max(Int(((place - inset) / track * CGFloat(Self.steps.count - 1)).rounded()), 0), Self.steps.count - 1)]
            }
            let chosen = Self.steps.firstIndex(of: step) ?? 0
            let knob = held ?? x(chosen)
            let clamp = { (place: CGFloat) in min(max(place, inset), inset + track) }
            ZStack(alignment: .topLeading) {
                // The two ends say what the track means, in the quietest words of the page.
                HStack {
                    Text("Lower cost")
                    Spacer()
                    Text("More secure")
                }
                .font(ShapeMetrics.endFont).foregroundStyle(FleetStyle.muted).frame(width: room.size.width)
                Capsule().fill(ShapeMetrics.trackFill)
                    .frame(width: track, height: ShapeMetrics.trackHeight)
                    .offset(x: inset, y: ShapeMetrics.trackY - ShapeMetrics.trackHeight / 2)
                // The track up to the knob.
                Capsule().fill(ShapeMetrics.trackDone)
                    .frame(width: max(ShapeMetrics.trackHeight, knob - inset), height: ShapeMetrics.trackHeight)
                    .offset(x: inset, y: ShapeMetrics.trackY - ShapeMetrics.trackHeight / 2)
                ForEach(Self.steps.indices, id: \.self) { index in
                    Circle().fill(x(index) <= knob + 0.5 ? ShapeMetrics.stepDone : ShapeMetrics.stepFill)
                        .frame(width: ShapeMetrics.stepDot, height: ShapeMetrics.stepDot)
                        .position(x: x(index), y: ShapeMetrics.trackY)
                    // The chosen step stands out by size and weight; the others are the quiet choices beside it.
                    Text(counts[index])
                        .font(index == chosen ? ShapeMetrics.chosenFont : ShapeMetrics.stepFont)
                        .foregroundStyle(index == chosen ? FleetStyle.text : FleetStyle.muted)
                        .fixedSize().position(x: x(index), y: ShapeMetrics.countsY)
                }
                SliderKnob(focused: focused && !byPointer).position(x: knob, y: ShapeMetrics.trackY)
            }
            .contentShape(Rectangle())
            .pointerStyle(held == nil ? .grabIdle : .grabActive)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { drag in
                    if grab == nil {
                        byPointer = true
                        let onKnob = abs(drag.startLocation.x - knob) <= ShapeMetrics.knobWidth / 2
                        grab = onKnob ? knob - drag.startLocation.x : 0
                        if !onKnob {
                            let place = clamp(drag.location.x)
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { held = place }
                            choose(nearest(place))
                            return
                        }
                    }
                    let place = clamp(drag.location.x + (grab ?? 0))
                    held = place
                    choose(nearest(place))
                }
                .onEnded { _ in settle() })
        }
        .frame(height: ShapeMetrics.sliderHeight)
        // Each change of the drag chose the nearest step already, so a drag that ends or that macOS cancels only lets
        // the knob settle on it.
        .onChange(of: dragging) { _, now in if !now { settle() } }
        .focusable().focused($focused).focusEffectDisabled()
        .onChange(of: focused) { _, now in if !now { byPointer = false } }
        .onMoveCommand { direction in
            byPointer = false
            let index = Self.steps.firstIndex(of: step) ?? 0
            switch direction {
            case .left where index > 0: choose(Self.steps[index - 1])
            case .right where index < Self.steps.count - 1: choose(Self.steps[index + 1])
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(l10n: "Servers, from lower cost to more secure"))
        .accessibilityValue(counts[Self.steps.firstIndex(of: step) ?? 0])
        .accessibilityAdjustableAction { direction in
            let index = Self.steps.firstIndex(of: step) ?? 0
            switch direction {
            case .increment where index < Self.steps.count - 1: choose(Self.steps[index + 1])
            case .decrement where index > 0: choose(Self.steps[index - 1])
            default: break
            }
        }
        .onKeyPress(.return) {
            guard let settled else { return .ignored }
            settled(step)
            return .handled
        }
        .modifier(SettlePress(settled: settled, step: step))
        .accessibilityIdentifier("first-run-servers-slider")
    }

    /// The width of a step's words in the chosen step's type, the widest that they take.
    private static func width(_ words: String) -> CGFloat {
        (words as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width.rounded(.up)
    }

    /// The drag let go of the knob: it slides to the step that the drag chose, at once with Reduce Motion.
    private func settle() {
        guard held != nil || grab != nil else { return }
        grab = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { held = nil }
        settled?(step)
    }

    private func choose(_ next: ServersStep) {
        guard next != step else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { step = next }
    }
}

/// VoiceOver's own press of the slider, only where it opens something (`ServersSlider.settled`): the first run's page
/// gets none, and its Continue stays the step's one press.
private struct SettlePress: ViewModifier {
    let settled: ((ServersStep) -> Void)?
    let step: ServersStep

    func body(content: Content) -> some View {
        if let settled { content.accessibilityAction { settled(step) } } else { content }
    }
}

/// **The slider's knob**: a raised capsule in the text's colour, with two chevrons that say it moves to the side. Its
/// shadow parts it from the track on the canvas and on a card alike. With the keyboard's focus on the slider, the
/// knob wears the focus ring.
private struct SliderKnob: View {
    var focused = false

    var body: some View {
        Capsule().fill(FleetStyle.text)
            .frame(width: ShapeMetrics.knobWidth, height: ShapeMetrics.knobHeight)
            .overlay {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: ShapeMetrics.knobChevron, weight: .bold))
                .foregroundStyle(FleetStyle.canvas.opacity(0.7))
            }
            .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2.5).padding(-4).opacity(focused ? 1 : 0))
            .accessibilityHidden(true)
    }
}

/// The hub's mark: the product's chevrons on a tile.
struct HubTile: View {
    var size: CGFloat

    var body: some View {
        FounderizerMark(size: size, plate: ShapeMetrics.tileFill, ink: ShapeMetrics.tileInk).accessibilityHidden(true)
    }
}

/// Rows of views in the middle of the room: a view that does not fit on a row starts the next one.
struct CenteredRows: Layout {
    var spacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]], used: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty, used + spacing + size.width > width { rows.append([]); used = 0 }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append((index, size))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let wide = rows.map { $0.reduce(-spacing) { $0 + spacing + $1.size.width } }.max() ?? 0
        let high = rows.reduce(-spacing) { $0 + spacing + ($1.map(\.size.height).max() ?? 0) }
        return CGSize(width: proposal.width ?? max(wide, 0), height: max(high, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let wide = row.reduce(-spacing) { $0 + spacing + $1.size.width }
            let high = row.map(\.size.height).max() ?? 0
            var x = bounds.midX - wide / 2
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (high - item.size.height) / 2), proposal: .unspecified)
                x += item.size.width + spacing
            }
            y += high + spacing
        }
    }
}

// MARK: - Your fleet

/// **The card "Your fleet"** (pictures 07 to 10): its name, the graph, and a foot with the count of machines and
/// Continue. The press makes nothing: the app's own pages rent and install.
struct FleetCard: View {
    let plan: FleetPlan
    let step: ServersStep
    let go: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your fleet").font(ShapeMetrics.nameFont).foregroundStyle(FleetStyle.text)
                .padding(ShapeMetrics.cardInset).accessibilityAddTraits(.isHeader)
            FleetGraph(plan: plan, step: step)
                .padding(EdgeInsets(top: 8, leading: ShapeMetrics.cardInset, bottom: 16, trailing: ShapeMetrics.cardInset))
            Rectangle().fill(FleetStyle.line).frame(height: FleetStyle.edgeWidth(contrast))
            HStack {
                Text(plan.count(step).words).font(.system(size: 13)).foregroundStyle(FleetStyle.text)
                Spacer()
                Button("Continue") { go() }
                    .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("fleet-card-continue")
            }
            .padding(.horizontal, ShapeMetrics.cardInset).padding(.vertical, 12)
        }
        .frame(width: FleetGraphLayout.width + 2 * ShapeMetrics.cardInset)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
            .strokeBorder(FleetStyle.line, lineWidth: FleetStyle.edgeWidth(contrast)))
    }
}

/// **The fleet as a graph.** A box is a machine, with a small mark that says which kind. The hub has no line: every
/// part talks to it. A solid line goes from the manager to each agent, and a dotted line from an agent to the one
/// thing it uses. What an agent does shows under the pointer.
struct FleetGraph: View {
    let plan: FleetPlan
    let step: ServersStep

    var body: some View {
        let layout = FleetGraphLayout(plan: plan, step: step, roleWidth: ShapeMetrics.nameWidth)
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.islands.enumerated()), id: \.offset) { _, island in
                RoundedRectangle(cornerRadius: FormMetrics.inner).fill(ShapeMetrics.islandFill)
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(ShapeMetrics.islandEdge, lineWidth: 0.5))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: island.kind == .mac ? "desktopcomputer" : "server.rack")
                            .font(IconMetrics.symbol(ShapeMetrics.kindMark)).foregroundStyle(FleetStyle.muted)
                            .padding(ShapeMetrics.kindInset)
                            .accessibilityLabel(island.kind == .mac ? String(l10n: "A Mac") : String(l10n: "A server"))
                    }
                    .frame(width: island.rect.width, height: island.rect.height)
                    .offset(x: island.rect.minX, y: island.rect.minY)
            }
            Path { path in
                for row in layout.rows {
                    let line = layout.line(to: row)
                    path.move(to: line.from)
                    path.addCurve(to: line.to, control1: line.control1, control2: line.control2)
                }
            }
            .stroke(ShapeMetrics.line, style: StrokeStyle(lineWidth: ShapeMetrics.lineWidth, lineCap: .round))
            Path { path in
                for row in layout.rows {
                    guard let dotted = row.dotted else { continue }
                    path.move(to: CGPoint(x: dotted.lowerBound, y: row.y))
                    path.addLine(to: CGPoint(x: dotted.upperBound, y: row.y))
                }
            }
            .stroke(ShapeMetrics.line, style: StrokeStyle(lineWidth: ShapeMetrics.lineWidth, lineCap: .round, dash: ShapeMetrics.dots))
            HubTile(size: FleetGraphLayout.hubTile)
                .position(layout.hubAt)
            under(String(l10n: "Hub"), nil, at: layout.hubAt)
            AgentGlyph(name: plan.names[0], size: FleetGraphLayout.manager, dot: false)
                .position(layout.managerAt)
            under(ManagerName.shown(plan.manager), String(l10n: "Manager"), at: layout.managerAt)
            ForEach(layout.rows, id: \.agent) { row in agent(row) }
        }
        .frame(width: FleetGraphLayout.width, height: layout.height, alignment: .topLeading)
        .environment(\.glyphTeam, plan.names).environment(\.glyphDots, false)
    }

    /// A part's words under its mark, in the middle: the hub's name, and the manager's name over its role.
    private func under(_ name: String, _ line: String?, at point: CGPoint) -> some View {
        VStack(spacing: 0) {
            Text(name).font(ShapeMetrics.nameFont).foregroundStyle(FleetStyle.text).frame(height: ShapeMetrics.nameLine)
            if let line {
                Text(line).font(ShapeMetrics.underFont).foregroundStyle(FleetStyle.muted).frame(height: ShapeMetrics.underLine)
            }
        }
        .lineLimit(1).frame(width: 88)
        .offset(x: point.x - 44, y: point.y + 22)
    }

    /// One agent on its axis: its mark, its role with what it asks first, and what it uses after the dotted line.
    @ViewBuilder private func agent(_ row: FleetGraphLayout.Row) -> some View {
        let agent = plan.agents[row.agent]
        AgentGlyph(name: agent.name, size: FleetGraphLayout.agentMark, dot: false)
            .position(x: FleetGraphLayout.markX + FleetGraphLayout.agentMark / 2, y: row.y)
            .help(agent.does ?? "")
        VStack(alignment: .leading, spacing: 0) {
            Text(agent.role).font(ShapeMetrics.nameFont).foregroundStyle(FleetStyle.text).frame(height: ShapeMetrics.nameLine)
            if let asks = agent.asksFirst {
                Text("Asks first: \(asks)").font(ShapeMetrics.underFont).foregroundStyle(FleetStyle.muted)
                    .frame(height: ShapeMetrics.underLine)
            }
        }
        .lineLimit(1).fixedSize()
        .offset(x: FleetGraphLayout.wordsX, y: row.y - ShapeMetrics.nameLine / 2)
        .help(agent.does ?? "")
        if let uses = agent.uses {
            UseTile(kind: uses.kind)
                .position(x: FleetGraphLayout.usesX + FleetGraphLayout.usesTile / 2, y: row.y)
            Text(uses.name).font(ShapeMetrics.nameFont).foregroundStyle(FleetStyle.text)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: FleetGraphLayout.width - FleetGraphLayout.usesWordsX, height: ShapeMetrics.nameLine, alignment: .leading)
                .offset(x: FleetGraphLayout.usesWordsX, y: row.y - ShapeMetrics.nameLine / 2)
        }
    }
}

/// The mark of what an agent uses, on a tile: a mailbox as Gmail's own mark, a repository as GitHub's, a key and a login
/// as the app's symbols for them.
struct UseTile: View {
    let kind: FleetPlan.Use.Kind

    var body: some View {
        Group {
            switch kind {
            case .mailbox: ServiceMark(service: .gmail, size: 16)
            case .repository: GitHubMark(size: 16).foregroundStyle(ShapeMetrics.tileInk)
            case .key: Image(systemName: "key").font(IconMetrics.symbol(13)).foregroundStyle(ShapeMetrics.tileInk)
            case .login: Image(systemName: "person.crop.circle").font(IconMetrics.symbol(13)).foregroundStyle(ShapeMetrics.tileInk)
            }
        }
        .frame(width: FleetGraphLayout.usesTile, height: FleetGraphLayout.usesTile)
        .background(ShapeMetrics.tileFill, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        .accessibilityHidden(true)
    }
}
