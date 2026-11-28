import FleetCore
import SwiftUI

/// **"Asked by me" on the Tasks page: his asks, in the iPhone's grouped look** (owner feature `ask_follow_ups`; the
/// owner, 25 November 2026: "If i asked for something this morning, there should be a way to easily see 4 hours later,
/// when many other tasks from agents themselves have been done, what is the response/status of the one thing I asked",
/// then of round 1: "Mobile design looks better", and "Yes, this" to round 2, `my-asks-tracking-2026-11-25/r1`).
///
/// One column of `width` points at the left, as the board's lanes stand: the heading "Open" with its count, as a lane's
/// heading, over one rounded group of rows, then "Done" over the rows that ended in the last seven days, and "N
/// earlier", which opens the rest of his list by day (`AskedByMe`). A group is a card's surface with its hairline edge
/// and the card's radius, and its rows are parted by hairlines that begin where their words begin. **A row**: the
/// state mark in one column, the name (semibold while it has an answer that he has not seen, `AskSeen`), how long ago
/// it moved at the right, what waits for him in orange (a request's line opens it on Needs you), the newest answer in
/// two lines at most, the agent that has it now with "working" or the time it resumes, and a chevron. A click opens the
/// ask in the card over the window (`AskDetail`). A follow-up of his is on the row of the ask that it goes on with:
/// the list says no word of a join.
struct AskedList: View {
    @Bindable var store: FleetStore
    let list: AskedByMe
    let state: HubState
    /// What he has seen of each ask, on this Mac (`AskSeen`).
    @AppStorage(AskSeen.key, store: AppDefaults.store) private var seenWords = ""
    /// The rows of "N earlier" show.
    @State private var showsEarlier = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// The list's column, as wide as the picture of round 2 drew it.
    static let width: CGFloat = 820

    var body: some View {
        let seen = AskSeen(words: seenWords)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if list.isEmpty {
                    // what is true of his list: All can hold tasks that he did not ask for (the Mac validator, 26 November)
                    FormSection { FormEmpty("Nothing asked yet", symbol: "tray") }
                } else {
                    if !list.open.isEmpty {
                        heading(String(localized: "Open (a state)", defaultValue: "Open", bundle: Localized.bundle,
                                       locale: Localized.digits), count: list.open.count)
                        group(list.open, seen: seen).accessibilityIdentifier("asked-open")
                    }
                    if !list.done.isEmpty || !list.earlier.isEmpty {
                        heading(String(l10n: "Done"), count: list.done.count + list.earlier.count)
                            .padding(.top, list.open.isEmpty ? 0 : Self.between)
                        if !list.done.isEmpty { group(list.done, seen: seen).accessibilityIdentifier("asked-done") }
                        earlier(seen: seen)
                    }
                }
            }
            .frame(maxWidth: Self.width, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, FleetSpace.bottom)
        }
        // From the first time this Mac draws the list of a fleet, an answer is news; before it, none is.
        .task(id: state.db) {
            var marks = AskSeen(words: seenWords)
            marks.begin(db: state.db, at: state.time)
            if marks.words != seenWords { seenWords = marks.words }
        }
    }

    /// Between the group of Open and the heading of Done.
    private static let between: CGFloat = 18

    /// A part's heading with its count, as a lane's heading on the board.
    private func heading(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
            Text("\(count)").font(FormMetrics.detail).monospacedDigit().foregroundStyle(FleetStyle.muted)
        }
        .frame(minHeight: FormMetrics.headingRow).padding(.leading, 2).padding(.bottom, 4)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }

    /// One rounded group of rows, parted by hairlines that begin where the rows' words begin.
    private func group(_ rows: [AskedRow], seen: AskSeen) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle().fill(FleetStyle.line).frame(height: 1).padding(.leading, AskedRowView.wordsInset)
                }
                AskedRowView(store: store, row: row, state: state, unread: seen.unread(row, db: state.db))
            }
        }
        .background(FleetStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: FormMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
            .strokeBorder(FleetStyle.hairline(0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
    }

    /// **"N earlier"**: the rest of his list, which ended more than seven days ago, muted, as "more" of the board's
    /// Done; it opens them by the day that they ended, each day a group of its own.
    @ViewBuilder private func earlier(seen: AskSeen) -> some View {
        if !list.earlier.isEmpty {
            Button { showsEarlier.toggle() } label: {
                HStack(spacing: 6) {
                    Text("\(list.earlier.count) earlier")
                    Image(systemName: "chevron.right").font(IconMetrics.symbol(9, weight: .semibold))
                        .rotationEffect(.degrees(showsEarlier ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
                .padding(.horizontal, EndedRow.inset).frame(minHeight: EndedRow.height).contentShape(Rectangle())
            }
            .buttonStyle(FleetRowButtonStyle())
            .pointerStyle(.link)
            .accessibilityValue(showsEarlier ? String(localized: "Open (a state)", defaultValue: "Open", bundle: Localized.bundle,
                                                      locale: Localized.digits) : String(l10n: "Closed"))
            .accessibilityIdentifier("asked-earlier")
            .padding(.top, 6)
            if showsEarlier {
                let calendar = Calendar.current
                let days = Dictionary(grouping: list.earlier) { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.time)) }
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    Text(ActivityBoard.dayWords(day.timeIntervalSince1970, now: state.time))
                        .font(FormMetrics.detailTitle).foregroundStyle(FleetStyle.muted)
                        .padding(.leading, 2).frame(minHeight: FormMetrics.headingRow, alignment: .bottomLeading)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    group(days[day] ?? [], seen: seen)
                }
            }
        }
    }
}

/// **One row of "Asked by me"** (`AskedRow`; the picture r1). The whole row opens the ask in the card over the window;
/// its request's orange line is a button of its own, which opens that request on Needs you, so the row is no `Button`
/// (a button inside a button takes no click of its own) and takes the keyboard's focus itself, as a card of the board
/// does (`JobCard`).
struct AskedRowView: View {
    @Bindable var store: FleetStore
    let row: AskedRow
    let state: HubState
    /// It has an answer that he has not seen: its name is semibold.
    let unread: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The mark's size and its column, and the room around a row's words.
    static let mark: CGFloat = 15
    static let markColumn: CGFloat = 18
    static let gap: CGFloat = 12
    static let inset: CGFloat = 16
    /// Where a row's words begin: the hairline between two rows begins there.
    static let wordsInset = inset + markColumn + gap
    /// The chevron's room at the right.
    private static let chevron: CGFloat = 14

    /// Opens the request that it waits on, on Needs you, where he answers it; nil when it waits for none.
    private var openRequest: (() -> Void)? {
        guard let id = row.request else { return nil }
        return { store.selectedNeed = id; store.destination = .needs }
    }

    private func open() { store.show(.ask(row.id)) }

    /// The agent that has it now, and what it does: "working", or when it resumes.
    private var holderWords: String {
        let name = row.holder.agentLabel
        switch row.mark {
        case .working: return name + " · " + String(l10n: "working")
        case .waiting: return row.until.map { name + " · " + fleetResumes($0, now: state.time) } ?? name
        default: return name
        }
    }

    var body: some View {
        let time = activityAge(row.time, now: state.time)
        let waits = row.waitWords
        HStack(alignment: .top, spacing: Self.gap) {
            AskedMark(row: row, size: Self.mark, store: store)
                .frame(width: Self.markColumn, alignment: .leading).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.name).font(unread ? FormMetrics.text.weight(.semibold) : FormMetrics.text)
                        .foregroundStyle(FleetStyle.text).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(time).font(FormMetrics.detail).monospacedDigit().foregroundStyle(FleetStyle.muted).lineLimit(1).fixedSize()
                }
                if let waits {
                    // Orange is what needs him (D-8), and here it is words, because the words are the news.
                    if let openRequest {
                        Button(action: openRequest) {
                            Text(waits).lineLimit(2).multilineTextAlignment(.leading)
                                .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).foregroundStyle(.orange)
                            .help("Open this request on Needs you").accessibilityIdentifier("asked-request-\(row.id)")
                    } else {
                        Text(waits).lineLimit(2).foregroundStyle(.orange)
                    }
                }
                if let answer = row.answer {
                    Text(answer).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(FleetStyle.text.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    AgentGlyph(name: row.holder, size: GlyphSize.inline, ground: hovered ? FleetStyle.lifted : FleetStyle.surface)
                    Text(holderWords).lineLimit(1)
                    if row.mark == .failed, let word = row.failedWord { EndedRow.badge(word) }
                }
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).padding(.top, 2)
            }
            .font(FormMetrics.text)
        }
        .padding(.leading, Self.inset).padding(.trailing, Self.inset + Self.chevron + Self.gap).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
                .frame(width: Self.chevron).padding(.trailing, Self.inset).accessibilityHidden(true)
        }
        .background(hovered ? FleetStyle.lifted : Color.clear)
        .contentShape(Rectangle())
        // The whole row opens the ask; the request's line is a button of its own, which takes its own click.
        .onTapGesture(perform: open)
        .onHover { hovered = $0 }
        // the pointer's fill comes at once and goes over 0.15 s, as on a card of the board (`BoardCardLook`)
        .animation(hovered || reduceMotion ? nil : FleetMotion.pointerOut, value: hovered)
        // The keyboard reaches a row as it reaches a button: Return or Space opens the ask.
        .focusable(interactions: .activate)
        .contentShape(.focusEffect, Rectangle())
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in open(); return .handled }
        .help(Text(verbatim: [row.name, waits ?? row.answer].compactMap { $0 }.joined(separator: "\n")))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.name, time, waits, row.answer.map { String($0.prefix(280)) }, holderWords, row.failedWord]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityActions { if let openRequest { Button("Open the request", action: openRequest) } }
        .accessibilityIdentifier("asked-\(row.id)")
    }
}

/// **The state mark of an ask**, in the board's marks (`StandingMarkView`): the orange hand of what needs him, the
/// green mark of work that turns while its task is work now, the muted clock of what waits, the green check, the red
/// mark of a result that did not succeed, and the muted circle of one that somebody canceled.
struct AskedMark: View {
    let row: AskedRow
    let size: CGFloat
    let store: FleetStore

    var body: some View {
        switch row.mark {
        case .needsYou: StandingMarkView(mark: .waits, size: size, store: store)
        case .working: StandingMarkView(mark: .task(symbol: "circle.dotted", tint: .work, inWork: row.moves), size: size, store: store)
        case .waiting: StandingMarkView(mark: .task(symbol: "clock", tint: .quiet, inWork: false), size: size, store: store)
        case .done: StandingMarkView(mark: .ended(.done), size: size, store: store)
        case .failed: StandingMarkView(mark: .ended(.failed), size: size, store: store)
        case .canceled: StandingMarkView(mark: .ended(.quiet), size: size, store: store)
        }
    }
}
