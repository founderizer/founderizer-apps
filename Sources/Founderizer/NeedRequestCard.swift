import AppKit
import FleetCore
import SwiftUI

/// One offered answer, as a target: a row that lifts under the pointer and dims on the press. **Neutral grey** (the
/// owner's yes of 28 October 2026, D-8): it was violet, the colour that now has one job — a link, the focus, the
/// selected tab and the brand's mark — and the rows of a request read as a list of choices without it.
struct NeedOptionButtonStyle: ButtonStyle {
    /// A number key marked this option, on the request at hand (`NeedAnswerBox`): it is lit as under the pointer, **with
    /// the violet edge of the keyboard's focus**, as a field that has the cursor, and Return presses it. Lit alone, it
    /// looked the same as the row under the pointer, and two rows were lit when the pointer stood on another one.
    var marked = false
    /// **The first option of an item that carries its grant** (`OwnerNeed.give`; the owner's "Give + No" of 19 November
    /// 2026 to its mockup): the press that gives it, which is the card's one main action, so it is white, as the main
    /// action of a page is (`FleetPrimaryButtonStyle`), with dark words (`NeedAnswerBox.row`).
    var gives = false
    /// **The answer that the agent recommends** (owner feature `need_recommended`; the owner's pick "B: badge on the
    /// edge" of 20 November 2026): its row's edge in that agent's own colour, under its badge (`RecommendedBadge`); nil
    /// on every other row. The violet edge of a number key's mark stands over it.
    var recommended: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        OptionRow(configuration: configuration, marked: marked, gives: gives, recommended: recommended)
    }

    private struct OptionRow: View {
        let configuration: ButtonStyleConfiguration
        let marked: Bool
        let gives: Bool
        let recommended: Color?
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        private var lit: Bool { (hovered || marked) && isEnabled }
        /// The violet of a number key's mark, the agent's colour of the answer that it recommends, or the hairline.
        private var edge: Color {
            if marked && isEnabled { return FleetStyle.accent }
            if let recommended { return recommended.opacity(RecommendedBadge.edge(lit: lit, contrast: contrast)) }
            return FleetStyle.hairline(lit ? 0.18 : 0.10)
        }

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .fill(Color.white.opacity(gives ? (configuration.isPressed ? 0.78 : lit ? 1 : 0.94) : lit ? 0.09 : 0.05))
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
                        .strokeBorder(edge, lineWidth: (marked && isEnabled) || recommended != nil
                                      ? 1 : FleetStyle.edgeWidth(contrast))))
                .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.55)
                .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
                .onHover { hovered = $0 }
        }
    }
}

/// **The badge of the answer that the agent recommends** (owner feature `need_recommended`, API 1.269; the owner's pick
/// "B: badge on the edge" of three pictures, 20 November 2026, after "use the agent icon, and maybe like a badge or
/// something, not that thumb icon"): a capsule on the top edge of that answer's row, at its trailing side and half over
/// the edge, with the glyph of the agent that raised the request, at rest and with no dot, and the word Recommended, in
/// that agent's own colour (`AgentTint`, the colour of a control that speaks to the agent): a dark tint of it fills the
/// capsule, it is the capsule's edge, and a light tint of the glyph's light step is the word. The row's own edge takes
/// the colour too (`NeedOptionButtonStyle.recommended`). VoiceOver reads the word on the row (its value or hint), so the
/// badge itself is hidden from it.
struct RecommendedBadge: View {
    let agent: String
    /// What the badge stands on, which its fill covers, so the row's edge does not show through it: the canvas under the
    /// request at hand on Needs you, a card's surface in a chat.
    let ground: Color
    @Environment(\.glyphTeam) private var team

    /// **The glyph's side: the size of the badge's words**, as the badge of a name in a request's words draws its glyph
    /// at its words' size (`CardBadges`), and not one of `GlyphSize`'s sizes; 14 points, as the picture that he picked
    /// drew it. The capsule is then 19 points high, so its lower half stays in the row's room above its first line.
    static let glyph: CGFloat = 14
    /// The room over the row of the badge, so the half of it over the row stands clear of what is above.
    static let room: CGFloat = 8
    /// From the row's trailing edge to the badge's, on a row with no tick at its end.
    static let inset: CGFloat = 12
    /// Over and under the words of a recommended row of options that combine, which has 4 points over its words: a
    /// first line that wraps stands under the badge, as on any other row, and one line stays in its tick's middle.
    static let wordsRoom: CGFloat = 6

    /// The agent's own colour, as a control that speaks to it wears it (`AgentTint`): the middle of its glyph's gradient.
    @MainActor static func colour(of agent: String, team: [String]) -> Color { AgentTint(agent: agent, team: team).fill }

    /// How much of that colour the row's edge takes: all of it under the pointer and with Increase Contrast.
    @MainActor static func edge(lit: Bool, contrast: ColorSchemeContrast) -> Double {
        lit || contrast == .increased || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.75
    }

    var body: some View {
        let colour = Self.colour(of: agent, team: team)
        HStack(spacing: 5) {
            AgentGlyph(name: agent, presence: .online, size: Self.glyph, dot: false)
            Text("Recommended").font(FormMetrics.detail).lineLimit(1)
        }
        .foregroundStyle(GlyphTeams.look(of: agent, in: team).light.mix(with: .white, by: 0.5))
        .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 2)
        .background(Capsule().fill(ground).overlay(Capsule().fill(colour.opacity(0.25))))
        .overlay(Capsule().strokeBorder(colour.opacity(0.8), lineWidth: 1))
        .fixedSize()
        // A press goes to the row under it, and the glyph makes no jump under the pointer.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The answer to one request, where the request is: three replies that send at once, a box that sends on Return,
/// the plus of its files and the send button. The draft is the store's, so the card and the window below it hold
/// the same text. Files reach it as they reach the chat's composer: the plus, a dropped file and Cmd+V.
struct NeedAnswerBox: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    /// The owner chose to keep what looks like a key in this answer: no second question while it is there.
    @State private var keyAllowed = false
    /// Owner feature `need_talk` (API 1.106): the options he ticked, on an item whose options combine.
    @State private var ticked: Set<Int> = []
    /// **Under the request at hand on Needs you** (`NeedStep`; the owner's yes of 11 November 2026 to its picture), the
    /// box takes the step's one size: its words at 15 points, its rows and its field 44 high. In a chat it keeps the
    /// card's 13.
    @Environment(\.stepText) private var stepText
    private var onStep: Bool { stepText != nil }
    private var words: Font { FormMetrics.onStep(stepText) ?? FormMetrics.text }
    /// The height of a line of the step's words, for the field that grows by lines.
    private static let stepLine: CGFloat = 18
    /// The option that a number key marked, on a step: Return presses it (`key`).
    @State private var marked: Int?
    /// The page's keys, on a step (`StepKeys`): the box gives it its own (`key`). Nil in a chat, whose card has no keys.
    var keys: StepKeys? = nil
    /// He writes (`NeedsBoard.writes`): the field takes the cursor as the request comes to hand.
    var takesCursor = false
    /// An answer went, on a step: true when it went from the field, false for an option or the ticked ones.
    /// Also where the answer that he gave stands under the box's top (`tops`), for the step's move of it.
    var answered: ((Bool, CGFloat) -> Void)? = nil
    /// Where each option stands under the box's top, by its number, and the field of Your answer under -1: on a step,
    /// the answer that he gave moves from there to the top as the others go (`NeedStep`).
    @State private var tops: [Int: CGFloat] = [:]
    private static let space = "need-answer-box"
    /// The names of the hub's agents, for the colour of the answer that an agent recommends (`RecommendedBadge`).
    @Environment(\.glyphTeam) private var team
    /// Owner feature `need_recommended` (API 1.269): the row of the answer that the agent recommends, or nil
    /// (`OwnerNeed.recommendedRow`).
    private var recommendation: NeedRecommended.Row? {
        need.recommendedRow(features: store.state?.ui_features, replies: Self.quickReplies)
    }
    /// The agent's own colour on the edge of that row.
    private var tint: Color { RecommendedBadge.colour(of: need.by, team: team) }
    /// What the badge stands on, which its fill covers: the canvas under the request at hand, a card in a chat.
    private var ground: Color { onStep ? FleetStyle.canvas : FleetStyle.surface }
    /// The place in `tops` of the row of the agent's own words (`NeedRecommended.Row.words`), beside the options' indexes
    /// and the field's -1.
    private static let recommendedWords = -2
    /// The room at the end of a row of options that combine, after its tick.
    private var tickInset: CGFloat { onStep ? 10 : 6 }

    /// Three answers that fit almost every request. **A press sends it at once, as his words** (the owner, 18 November
    /// 2026: "If I click done, I want to send it directly! not paste it into the text input!"): it only filled the box,
    /// and he sent it with a second press. They are the fallback: an item that offers its own options (API 1.18) shows
    /// those instead, and pressing one of those sends it, because the agent asked for exactly that answer.
    private static let quickReplies = ["Done", "Not now", "Tell me more"]

    /// Owner feature attachments: the composer of this request, where its files wait until it is answered. An
    /// answer that goes into a conversation carries none (API 1.17), so that request has no composer.
    private var composer: String? { need.takesFiles ? FleetStore.stageKey(need: need.id) : nil }
    /// Empty while his answer is on its way, as the chat's field (fix round 3, item 11).
    private var text: Binding<String> {
        Binding(get: { store.answerText(for: need) }, set: { store.answers[String(need.id)] = $0 })
    }
    private var trimmed: String { text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The guard's own key for this box, beside the composers of the chats.
    private var guardKey: String { "need-answer-\(need.id)" }
    private var guards: Bool { SecretEntryView.isOffered(by: store) }
    /// Files alone are an answer, as they are a message; a file that is still going up holds the send.
    private var canSend: Bool {
        store.canWrite && !(composer.map(store.filesAreWaiting) ?? false) && trimmed.count <= 16_000
            && (!trimmed.isEmpty || !(composer.map(store.readyFiles) ?? []).isEmpty)
    }

    /// One answer the agent offered: its own words on their own row, the whole width of the request, so that
    /// pressing one is plainly the thing to do. The words wrap and are drawn as a plain label, never as markup,
    /// and nothing is cut: the hub refuses a label that is too long, which is where that belongs.
    ///
    /// **The option he pressed says "Sending…" at its end while its answer waits** (fix round 2, items 1 and 51; the
    /// phone's words), a second after the wait began (`Held`), so a press that goes at once shows nothing that blinks
    /// away; a press on another option moves the words to it.
    private func row(_ words: String, sendingSince: ContinuousClock.Instant? = nil, gives: Bool = false) -> some View {
        HStack(spacing: 8) {
            // the press that gives the item's grant: its key before its words, which are dark on its white
            if gives {
                Image(systemName: "key.fill").font(IconMetrics.symbol(onStep ? 13 : 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.92)).accessibilityHidden(true)
            }
            Text(words).font(self.words).foregroundStyle(gives ? Color.black.opacity(0.92) : FleetStyle.text)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let since = sendingSince { Held(since: since) { SendingWords(onWhite: gives) } }
        }
        .padding(.horizontal, onStep ? 14 : 12).padding(.vertical, onStep ? 11 : 10)
        .frame(minHeight: onStep ? FormMetrics.row : nil)
    }

    var body: some View {
        // owner feature need_recommended: the row that has the badge of the answer that the agent recommends
        let recommended = recommendation
        VStack(alignment: .leading, spacing: 8) {
            if need.choices.isEmpty {
                // **One look for an answer option** (T-22): the app's own three replies are rows like the ones an
                // agent offers, and a press sends one as an option's press does. A page showed 24-pt dark chips under
                // one request and 36-pt violet rows under the next.
                VStack(alignment: .leading, spacing: onStep ? 8 : 7) {
                    // **The agent's own words over the app's three replies** (owner API 1.269): a row whose press sends
                    // them as his answer in words, as a reply's press sends its words.
                    if case .words(let words) = recommended {
                        Button {
                            guard !(onStep && SecondClick.isNow) else { return }
                            sendQuickReply(words, from: Self.recommendedWords)
                        } label: { row(words) }
                            .buttonStyle(NeedOptionButtonStyle(recommended: tint))
                            .stands(in: Self.space, on: onStep) { tops[Self.recommendedWords] = $0 }
                            .accessibilityValue("Recommended")
                            .accessibilityIdentifier("need-recommended-\(need.id)")
                            .recommendedBadge(by: need.by, ground: ground)
                    }
                    ForEach(Array(Self.quickReplies.enumerated()), id: \.offset) { index, reply in
                        let marks = recommended == .reply(index)
                        Button {
                            // Not from the second click of a double-click: it would answer the next request too
                            // (`SecondClick`).
                            guard !(onStep && SecondClick.isNow) else { return }
                            sendQuickReply(reply, from: index)
                        } label: { row(reply) }
                            .buttonStyle(NeedOptionButtonStyle(recommended: marks ? tint : nil))
                            .stands(in: Self.space, on: onStep) { tops[index] = $0 }
                            .accessibilityValue(marks ? "Recommended" : "")
                            .accessibilityIdentifier("quick-\(reply.lowercased())-\(need.id)")
                            .recommendedBadge(by: marks ? need.by : nil, ground: ground)
                    }
                }
            } else if need.combines {
                // **Options that combine** (the owner's yes of 9 November 2026): a tick at the right of each row, and one
                // Send with how many he ticked; it stays off while none is ticked.
                VStack(alignment: .leading, spacing: onStep ? 8 : 7) {
                    ForEach(Array(need.choices.enumerated()), id: \.offset) { index, option in
                        let marks = recommended == .option(index)
                        HStack(spacing: 8) {
                            Text(option).font(words).foregroundStyle(FleetStyle.text)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, marks ? RecommendedBadge.wordsRoom : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: Binding(get: { ticked.contains(index) }, set: { on in
                                if on { ticked.insert(index) } else { ticked.remove(index) }
                            })).labelsHidden().toggleStyle(FleetCheckboxStyle()).accessibilityLabel(option)
                                .accessibilityHint(marks ? "Recommended" : "")
                        }
                        .padding(.leading, onStep ? 14 : 12).padding(.trailing, tickInset).padding(.vertical, 4)
                        .frame(minHeight: onStep ? FormMetrics.row : nil)
                        .background(RoundedRectangle(cornerRadius: FormMetrics.inner).fill(Color.white.opacity(0.05)))
                        // owner feature need_recommended: the edge of the answer that the agent recommends
                        .overlay {
                            if marks {
                                RoundedRectangle(cornerRadius: FormMetrics.inner)
                                    .strokeBorder(tint.opacity(RecommendedBadge.edge(lit: false, contrast: contrast)),
                                                  lineWidth: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
                        .onTapGesture { if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) } }
                        .accessibilityIdentifier("need-tick-\(need.id)-\(index)")
                        // its badge ends before the tick's column, which stays clear
                        .recommendedBadge(by: marks ? need.by : nil, ground: ground, inset: tickInset + IconMetrics.side)
                    }
                    HStack {
                        Spacer()
                        Button("Send \(ticked.count)") {
                            guard !(onStep && SecondClick.isNow) else { return }
                            let chosen = Array(ticked)
                            answered?(false, 0)
                            Task { await store.answer(need, choices: chosen) }
                        }.buttonStyle(FleetPrimaryButtonStyle()).disabled(ticked.isEmpty || !store.canWrite)
                            .accessibilityIdentifier("need-send-ticked-\(need.id)")
                        // On a step it stands in the middle, as a step's one button does.
                        if onStep { Spacer() }
                    }
                }
            } else {
                let waiting = AnswerWaits.shared.press(of: need)
                VStack(alignment: .leading, spacing: onStep ? 8 : 7) {
                    ForEach(Array(need.choices.enumerated()), id: \.offset) { index, option in
                        // **Never drawn grey** (fix round 2): a press that comes while the hub cannot take it waits, and
                        // goes when it can, its option saying "Sending…" meanwhile (`AnswerWaits`).
                        let sending = waiting?.choice == index
                        // the lane "Give on a card": the first option of an item that carries its grant gives it, white
                        // on Needs you and in a chat (the owner's "Give + No" and "Yes, chat too", 19 November 2026)
                        let gives = index == 0 && need.give != nil
                        // owner feature need_recommended: the answer that the agent recommends, with its badge
                        let marks = recommended == .option(index)
                        Button {
                            guard !(onStep && SecondClick.isNow) else { return }
                            marked = nil
                            answered?(false, tops[index] ?? 0)
                            AnswerWaits.shared.press(need, choice: index, store: store)
                        } label: {
                            row(option, sendingSince: sending ? waiting?.since : nil, gives: gives)
                        }
                            .buttonStyle(NeedOptionButtonStyle(marked: marked == index, gives: gives,
                                                               recommended: marks ? tint : nil))
                            .stands(in: Self.space, on: onStep) { tops[index] = $0 }
                            .accessibilityValue(sending ? "Sending" : marks ? "Recommended" : "")
                            .accessibilityIdentifier("need-option-\(need.id)-\(index)")
                            .recommendedBadge(by: marks ? need.by : nil, ground: ground)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let held = store.heldKey, held.composer == guardKey {
                    KeyHoldBanner(hold: held.hold, agent: need.by) { saveHeldKey(held) } goOn: { keepHeldKey(held) }
                }
                if let composer { StagedFilesStrip(store: store, composer: composer) }
                HStack(alignment: .bottom, spacing: 8) {
                    if store.supportsAttachments, let composer {
                        AttachFilesButton(store: store, composer: composer)
                    }
                    // His words, as the phone's (T-12): the request's number is the hub's.
                    TextField("Your answer", text: text, axis: .vertical)
                        .focused($focused)
                        .accessibilityIdentifier("owner-answer")
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }
                            guard canSend else { return .handled }
                            sendAnswer()
                            return .handled
                        }
                        // **One line at rest, centred on the plus and Send, and a line more for each line he writes**,
                        // to eight, as the chat's composer is (`composerField`; the owner, 10 November 2026: "this
                        // should initially be one row only, and expanded if user enters a new line while typuing").
                        // It stood two lines high, its words at the top over a plus at the bottom.
                        .composerField(alone: !(store.supportsAttachments && composer != nil), lines: 1...8,
                                       font: onStep ? SetupMetrics.textFont : ChatStyle.font,
                                       line: onStep ? Self.stepLine : ChatStyle.line)
                        .onChange(of: text.wrappedValue) { _, now in
                            guard guards else { return }
                            if !KeyInText.contains(now) {
                                keyAllowed = false
                                if store.heldKey == HeldKey(composer: guardKey, hold: .text) { store.heldKey = nil }
                            } else if !keyAllowed && store.heldKey == nil {
                                store.heldKey = HeldKey(composer: guardKey, hold: .text)
                            }
                        }
                    // The chat's Send: only while it can send (`SendSlot`), in the violet of what he presses (D-8).
                    SendSlot(shows: canSend) {
                        Button { sendAnswer() } label: { SendMark() }
                            .buttonStyle(FleetIconButtonStyle(filled: true)).disabled(!canSend)
                            .help("Send this answer").accessibilityLabel("Send answer")
                            .accessibilityIdentifier("send-answer")
                    }
                }
                if let composer, let words = store.fileError(for: composer) {
                    Text(words).font(FormMetrics.detail).foregroundStyle(.orange).help(store.fileCause(for: composer) ?? "")
                }
            }
                // The composer's room around its 28-point controls, so the box at rest is the composer's 40 points; on a
                // step, a row's 44, as the options over it.
                .padding(onStep ? (FormMetrics.row - IconMetrics.side) / 2 : ComposerCapsule<EmptyView, EmptyView>.inset)
                // The radius of what stands in a card (`FormMetrics.inner`), not more than its card's 13 (T-21, fix
                // round): it was the chat composer's 20 inside a card of 13.
                .background(FleetStyle.composer, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                // **The field's edge, and the whole box takes the click** (fix round 2), as every field's does
                // (`fleetField`): its edge read 1.6:1 on its card, and a click on its 10 points of room went nowhere.
                .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .strokeBorder(FleetStyle.hairline(0.32), lineWidth: FleetStyle.edgeWidth(contrast)))
                .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
                .stands(in: Self.space, on: onStep) { tops[-1] = $0 }
                .onTapGesture { focused = true }
                // The clipboard reaches the box that the owner writes in: a page can show several open requests.
                .pasteAttachments(store: store, composer: focused ? composer : nil)
                .keyPasteGuard(store: store, composer: focused && guards ? guardKey : nil)
                .stageDroppedFiles(store: store, composer: composer)
            // No "Connection required" under it (D-2): the notice over the page is the one sign of an outage, as in
            // the chat's composer.
        }
        .coordinateSpace(.named(Self.space))
        // The keys of the request at hand, through the page's one watch; a card in a chat has none.
        .background { if let keys { StepKeysBox(keys: keys, need: need.id, take: key) } }
        .task { if takesCursor { focused = true } }
    }

    /// **The keys of the request at hand**, while no field has the cursor (`PageKeys`): a number marks that option, and
    /// Return presses the marked one (**the owner's choice of 11 November 2026: "Keep mark + Return"**, when he was
    /// asked whether a number alone should send, as the page's picture had said: "keys 1 to 9 press an option"). **One
    /// key alone sends nothing**: an answer cannot be taken back, so a number that he pressed by mistake only lights a
    /// row.
    /// **A mark holds only until the next key**: Return presses it, Escape and every other key take it away, so words
    /// that he types with no cursor in a field ("2 hours", Return) send nothing. On options that combine, a number ticks
    /// its option, and Return sends the ticked ones. With nothing marked or ticked, Return puts the cursor in Your
    /// answer.
    private func key(_ event: NSEvent) -> Bool {
        let choices = need.choices
        if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
            // A number with no option is a key as any other: the mark goes.
            guard digit <= choices.count else { marked = nil; return false }
            // A key that he holds marks once: its repeats would take the mark away and put it back.
            guard !event.isARepeat else { return true }
            if need.combines {
                if ticked.contains(digit - 1) { ticked.remove(digit - 1) } else { ticked.insert(digit - 1) }
            } else {
                marked = marked == digit - 1 ? nil : digit - 1
            }
            return true
        }
        switch event.keyCode {
        case 36, 76:        // Return and Enter
            // A Return that he holds presses once: its repeats would reach the request that comes to hand next.
            guard !event.isARepeat else { return true }
            if need.combines {
                guard !ticked.isEmpty else { focused = true; return true }
                guard store.canWrite else { return true }
                let chosen = Array(ticked)
                answered?(false, 0)
                Task { await store.answer(need, choices: chosen) }
            } else if let option = marked, choices.indices.contains(option) {
                marked = nil
                answered?(false, tops[option] ?? 0)
                AnswerWaits.shared.press(need, choice: option, store: store)
            } else {
                focused = true
            }
            return true
        case 53:            // Escape
            guard marked != nil else { return false }
            marked = nil
            return true
        default:
            // Any other key: he does not answer with the number that he pressed before it.
            marked = nil
            return false
        }
    }
}

/// **A press on a request's answer goes when the hub can take it** (fix round 2 of 29 October 2026, items 1 and 51):
/// the option rows of a request are drawn as they are, never grey — they were, at every launch until the first read
/// answered, and whenever the hub could not take a write. A press that comes then waits, and goes as soon as the store
/// can write, with the option pressed last, while that option says "Sending…" (`presses`, which the cards observe; the
/// phone's look). The store's own rule stands: nothing is sent on a reading this launch's hub has not confirmed
/// (`FleetStore.canWrite`). No clock ends the wait: the press is dropped when the request is answered or leaves, when its
/// options change, or when this Mac turns to another hub or hub generation, and a quit forgets it (the request stays
/// open).
@MainActor @Observable final class AnswerWaits {
    static let shared = AnswerWaits()
    /// The presses that wait, by request (`WaitingPresses`): the option pressed last, and when its wait began.
    private(set) var presses = WaitingPresses()

    /// The press that waits on this request, or nil.
    func press(of need: OwnerNeed) -> WaitingPresses.Press? { presses.press(of: need.id) }

    func press(_ need: OwnerNeed, choice: Int, store: FleetStore) {
        guard presses.press(choice, need: need.id, at: .now) else { return }
        let hub = store.hub, database = store.state?.db
        Task { @MainActor in
            // Its answer went, or it was dropped: the option's "Sending…" goes with it.
            defer { presses.end(need.id) }
            // The store's own pace for a write that waits for it (`FleetStore.save`).
            while !store.canWrite {
                guard store.hub == hub, store.state?.db == database,
                      store.openNeeds.contains(where: { $0.id == need.id }) else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard let press = presses.press(of: need.id), store.hub == hub, store.state?.db == database,
                  let current = store.openNeeds.first(where: { $0.id == need.id }), current.choices == need.choices,
                  current.signsTheSame(as: need)      // the card that he pressed on, not one that a later read brought
            else { return }
            await store.answer(current, choice: press.choice)
        }
    }
}

/// **The second click of a double-click sends no answer, on Needs you** (review of 11 November 2026). His answer brings
/// the next request to hand in the same frame, with its options where the options that he pressed stood: the second
/// click of a double-click fell on the next request, and answered it too, or pressed its Decline. Every control that
/// sends an answer there asks this first. Two clicks that are no double-click are his own two answers.
@MainActor enum SecondClick {
    static var isNow: Bool {
        // A click of this moment: a press that VoiceOver makes is no event, and the app's last event then is an older
        // one, which must not count.
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp,
              ProcessInfo.processInfo.systemUptime - event.timestamp < NSEvent.doubleClickInterval else { return false }
        return event.clickCount > 1
    }
}

/// "Sending…" on the option of a request whose answer waits: the moving words of a wait, as the chat's "Thinking" moves,
/// and still under Reduce Motion.
private struct SendingWords: View {
    /// On the white row of Give (`NeedOptionButtonStyle.gives`): dark words, 5.7:1 on its white, whose light is darker
    /// still. The muted grey read about 2.5:1 there.
    var onWhite = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Text("Sending…").font(FormMetrics.detail)
                    .foregroundStyle(onWhite ? Color.black.opacity(0.6) : FleetStyle.muted)
            } else {
                ShimmeringWords(text: String(l10n: "Sending…"),
                                base: onWhite ? NSColor.black.withAlphaComponent(0.6) : nil,
                                light: onWhite ? NSColor.black.withAlphaComponent(0.92) : nil)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

extension NeedAnswerBox {
    /// Sends the answer, unless it holds what looks like a key that the owner did not choose to keep.
    private func sendAnswer() {
        guard !(onStep && SecondClick.isNow) else { return }
        if guards && !keyAllowed && KeyInText.contains(text.wrappedValue) {
            store.heldKey = HeldKey(composer: guardKey, hold: .text)
            return
        }
        answered?(true, tops[-1] ?? 0)
        Task { await store.send(needID: need.id) }
    }

    /// One of the app's three replies, pressed: its words are the answer, with the files that wait in the box, and
    /// they go by the path of words that he wrote (`FleetStore.send`: the outbox, its receipt and its retry). Words
    /// that he had written in the box give way to them. **A press that comes while the hub cannot take it waits, and
    /// goes when it can**, as an option's press does (`AnswerWaits`): another answer still on its way held it, and the
    /// words only stood in the box. Meanwhile they stand there, and they stay there for Return or Send when the press
    /// cannot go: a file still going up, another hub or hub generation, or words that he changed while it waited. The
    /// wait ends when the request leaves, as `AnswerWaits`' does: no clock ends it.
    private func sendQuickReply(_ reply: String, from index: Int) {
        text.wrappedValue = reply
        guard !(composer.map(store.filesAreWaiting) ?? false) else { focused = true; return }
        answered?(false, tops[index] ?? 0)
        let store = store, id = need.id, hub = store.hub, database = store.state?.db
        Task { @MainActor in
            // The store's own pace for a write that waits for it (`FleetStore.writable`).
            while !store.canWrite {
                guard store.hub == hub, store.state?.db == database, store.storageError == nil,
                      store.openNeeds.contains(where: { $0.id == id }) else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard store.hub == hub, store.state?.db == database,
                  store.answers[String(id)]?.trimmingCharacters(in: .whitespacesAndNewlines) == reply else { return }
            await store.send(needID: id)
        }
    }

    /// "Save it as a secret": the key goes into the secure form and out of the answer. The agent that asked gets
    /// its name in its chat, when the owner has one with it.
    private func saveHeldKey(_ held: HeldKey) {
        store.heldKey = nil
        var key: String?
        if held.hold == .paste { key = KeyCut.onClipboard() }
        else if let cut = KeyCut.split(text.wrappedValue) { text.wrappedValue = cut.rest; key = cut.key }
        store.secretForm = SecretPreset(tell: store.canChat(with: need.by) ? need.by : nil, key: key)
    }

    /// "Paste it anyway" or "Keep it": the owner's choice, and no second question while the key is in the answer.
    private func keepHeldKey(_ held: HeldKey) {
        store.heldKey = nil
        keyAllowed = true
        if held.hold == .paste, let pasted = NSPasteboard.general.string(forType: .string) { text.wrappedValue += pasted }
    }
}

extension FleetStore {
    /// The files that went with his answer to `need`: the ones on the message that answered it.
    func answerFiles(of need: OwnerNeed) -> [MessageAttachment] {
        state?.messages.last { $0.need_id == need.id }?.attachments ?? []
    }
}

/// What the owner answered: the words, and the files that went with them, because an answer may be files alone.
/// The files are the ones on the message that answered this request.
struct NeedAnswerGiven: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed

    private var files: [MessageAttachment] { store.answerFiles(of: need) }

    var body: some View {
        let answer = need.answer ?? ""
        if let ran = NeedRunAnswer.of(need, onItsWay: nil) {
            // owner feature need_run: what his press of Run answered, and the end of the command's output under it
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: ran.symbol).font(IconMetrics.symbol(10, weight: .semibold)).accessibilityHidden(true)
                    Text(ran.words)
                }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .accessibilityElement(children: .ignore).accessibilityLabel(ran.spoken)
                NeedRunOutput(output: need.run_output ?? "")
            }
        } else if !answer.isEmpty || !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if answer.isEmpty {
                    Text("Your answer").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                } else {
                    DetailField(title: String(l10n: "Your answer"), value: answer)
                }
                if !files.isEmpty { MessageFilesView(store: store, files: files, alignment: .leading) }
            }
        }
    }
}

/// One request in the chat of the agent that asked it (D-7): the title, the first lines of it, and its answer where it
/// is read. The rest opens with one click, so a long request does not fill the column. On Needs you the same request
/// is a card of the lane and the request at hand (`NeedsBoard`), which share its answers (`NeedAnswerBox`) and its
/// secure form. Your answer is also his reply when he asks something back: the manager answers it with a new request.
///
/// **An answered request folds to two lines** (the owner's yes of 28 October 2026, D-7): its title and "✓ Correos",
/// the rest on a click, as Grok Bot folds a question card it answered. An answered one took as much room as an open
/// one. **The check is for an option that he pressed** (the owner, 14 November 2026: "when I typed a custom answer
/// instead of choosign one of the suggested ones, do not show the CHECK animation because it is misleading"): words
/// that he wrote can ask something back or say no, so they stand with no check. **The folded card stands where he
/// answered, and says his answer** (`ChatRequestPlaces.Answered.atItsAnswer`; the owner, 19 November 2026: "maybe we
/// sohuld show a row/card with the reply there?", and "A: the card" to its picture): what he wrote stands on it whole,
/// with its files under it, and is no bubble of its own.
///
/// **A key request goes to its title and a mark when he saves** (`KeySaveLook`; the owner, 20 November 2026: "no text
/// needed, just a nice animation of loading and then a nice and smooth check"): from his press of Save, once the checks
/// that end with a line of their own are passed, the card is its title and a ring that turns at its end, the ring
/// becomes a check that draws itself, and the folded card of a request
/// that a saved key answered is that title and that check, with no words. The hub's words of the answer stand in the
/// whole card, a click away. A step that failed, or one that left words for him (a grant whose agent cannot use the
/// key yet, a request that had its answer already), opens the card again with the form's rows.
struct NeedRequestCard: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    /// **The thing that he asked for in this chat and that waits for this request** (`ChatAskPlaces.onCards`), or nil:
    /// while the card waits, its head (`ChatAskHead`) names it and opens its task, and it has no row of its own. A card
    /// that folds has no head: the row stands under its reply again.
    var ask: ChatAskRow? = nil
    @State private var expanded = false
    /// owner feature need_takeover: he pressed Take over on this card, so its error line may show
    @State private var pressedTakeOver = false
    /// His answer as the outbox saved it, kept from the frame it went until the reading says the request is answered
    /// (`WordsOnTheirWay`): the store lets the request go with its receipt, a round trip before that reading.
    @State private var sent: PendingRequest?
    /// **His key save on this card**, as its form tells it (`KeySaveCard`): the card stands as its title and the ring,
    /// then the check, and folds once the check has drawn itself.
    @State private var keySave = KeySaveCard()
    /// The width of a form page's cards, where the card stands on one; in a chat, nil, and the card takes the column's.
    @Environment(\.formMeasure) private var measure
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// **His answer on its way: the card folds in the frame he sends it, with his words** (fix round 3, item 11), as it
    /// folds once the reading says it is answered. It folded only with that reading, a round trip after the hub's
    /// receipt.
    private var onItsWay: PendingRequest? { store.answerOnItsWay(to: need, kept: sent) }

    /// What it needs from him. A secret request's is the hub's one sentence about its form, which is right below it, and
    /// an item that carries its grant has none: Give is its step (`OwnerNeed.give`).
    private var todo: String { need.asksForSecret || need.give != nil ? "" : need.todo }
    /// The names that the card's words link (`CardNames`): an agent, a repository, a server, a page of the app.
    private var names: CardNames { store.cardNames(for: need) }
    /// **His task stands on the card, under the reason** (the owner, 15 November 2026: "the task itself need to be
    /// very clear"; `OwnerNeed.taskInFront`): it stood behind Details, under "What it needs from you". An item with a
    /// door call keeps its words there, and so does a conversation's item.
    private var task: String { need.taskInFront ? todo : "" }

    private var hasMore: Bool {
        need.details != nil || !short || (!todo.isEmpty && task.isEmpty)
    }
    /// **A short card** (the owner's yes of 9 November 2026): an item from a hub with `need_talk` has a why of one or two
    /// sentences, shown whole, and its long part behind Details. An older item keeps Show all.
    private var short: Bool { need.details != nil || need.why.count <= NeedTalk.why }
    /// The request's title, folded or whole, **without its number** (D-2, the owner's yes of 28 October 2026): "N-3" is
    /// the hub's bookkeeping, and the agents' own words name a request by what it asks.
    private var heading: String { need.shownTitle }
    /// **The card's words in the sizes of the chat it stands in** (fix round 2): its title and its body take the chat's
    /// 14 points, the title medium; its small lines are 12, where they were 11 and 11.5, and its body took the page's
    /// 12.5: sizes of their own in the chat's column. Its option rows keep 13, the size of a button's words (D-8 item
    /// 10). **Its body is drawn as a message is** (`MessageText`; the owner, 15 November 2026: "formatted like the
    /// chat messages (links, code format etc)"): a link is a link, code is code with its copy icon, and steps are a
    /// list. It was plain text, so a command stood in a sentence with its backticks.
    private var titleFont: Font { ChatStyle.title }
    /// What he answered, in the folded card's second line: his words or the option he pressed.
    private var answerWords: String {
        if let ran = ranAnswer { return ran.spoken }        // a press of Run, in this Mac's words (VoiceOver too)
        if need.answeredWithKey { return String(l10n: "Saved") }     // the word behind the check of a saved key
        let answer = (onItsWay?.text ?? need.answer)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return answer.isEmpty ? String(l10n: "Answered") : answer
    }
    /// He answered in his own words, on their way or as the reading has them: no option that he pressed or ticked.
    private var inWords: Bool { onItsWay?.answersInWords ?? need.answeredInWords }

    var body: some View {
        Group {
            // a run that goes on keeps the card open, with its Stop, also when the item closed meanwhile; a key save
            // keeps it until its check has drawn itself, or with its failed step (`KeySaveCard.folds`)
            if keySave.folds(answered: (!need.isOpen || onItsWay != nil) && store.needRuns[need.id]?.busy != true,
                             expanded: expanded) {
                // **The files of his answer stand under it on the folded card**, as they stood under his message: the
                // card is his answer in the chat, and a file is pressed by itself, outside the card's own press.
                let files = store.answerFiles(of: need)
                VStack(alignment: .leading, spacing: 0) {
                    Button { withAnimation(.easeInOut(duration: 0.12)) { expanded = true } } label: {
                        folded.padding(FormMetrics.rowInset).padding(.bottom, files.isEmpty ? 0 : 8 - FormMetrics.rowInset)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(need.shownTitle), answered: \(answerWords)"))
                        .accessibilityHint("Shows the whole request")
                        .accessibilityIdentifier("need-folded-\(need.id)")
                    if !files.isEmpty {
                        MessageFilesView(store: store, files: files, alignment: .leading)
                            .padding([.horizontal, .bottom], FormMetrics.rowInset)
                    }
                }
            } else {
                // **A card's content 16 points in, folded and whole** (margins row 19), as the rows of every form card:
                // the request's title stood 2 points left of the form rows' titles on the same page.
                VStack(alignment: .leading, spacing: 0) {
                    if let ask, !keyCollapsed { ChatAskHead(store: store, row: ask) }
                    // **Nothing of the card's parts draws past its edge**: a key card closes over its form when his
                    // save starts and opens over it again (`KeySaveCard`), and what leaves or comes in that motion
                    // stays inside the card as it moves. The clip is here and not on the card: the folded card's
                    // button and the ask's head reach the card's edge, and their focus rings draw past it.
                    whole.padding(FormMetrics.rowInset).clipShape(RoundedRectangle(cornerRadius: FormMetrics.radius))
                }
            }
        }
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        // **The edge of every card of a form** (fix round 3, item 58; T-41): with Increase Contrast a one-point edge that
        // reads 4:1, where the request card had none (1.11:1).
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
            .strokeBorder(FleetStyle.hairline(0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
        // Owner feature attachments: a file dropped anywhere on an open request is staged in its answer, as a
        // file dropped anywhere in a conversation is staged in that chat's composer.
        .stageDroppedFiles(store: store,
                           composer: need.isOpen && need.takesFiles ? FleetStore.stageKey(need: need.id) : nil,
                           mark: true)
        .frame(maxWidth: measure ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        // a name in its words opens its page in this window (`FleetStore.openCardLink`)
        .environment(\.openURL, OpenURLAction { store.openCardLink($0) })
        .environment(\.cardServerSymbols, store.cardServerSymbols)
        .onChange(of: store.pending?.requestID, initial: true) { _, _ in
            if let request = store.answerOnItsWay(to: need) {
                // **A card that he opened (Details, Show all) folds too when his answer goes**: the fold is where
                // the chat says his answer, and the whole card says it only once the reading has it. His words
                // showed nowhere for that round trip.
                if sent?.requestID != request.requestID { expanded = false }
                sent = request
            }
        }
        // An answer that this card did not see go (the form of a key or a login, his phone, a tool of the app): a
        // card that he had opened folds with the reading that brings it. One that he opens after his own answer
        // went stays as he has it.
        .onChange(of: need.isOpen) { _, open in
            if !open, sent == nil { expanded = false }
        }
        // The check of his key save draws itself and goes quiet; then the folded card, with that check at rest, may
        // take the card's place.
        .task(id: keySave.look) {
            guard keySave.look == .saved else { return }
            do { try await Task.sleep(for: KeySaveMark.settles) } catch { return }
            keySave.settle()
        }
        // owner feature need_run: Run and its line read the store, and a command for a Mac of the fleet needs the
        // machines' readings for its Run to stand
        .environment(store)
        .task(id: need.isOpen ? need.run_on : nil) {
            if need.isOpen, let on = need.run_on, on != NeedRun.ownMac { await store.readRunMachines() }
        }
        // owner feature need_takeover: Take over stands once the machines' readings name the asking agent's way in
        .task(id: need.isOpen && need.asksForTakeover ? need.by : nil) {
            if need.isOpen, need.asksForTakeover { await store.readTakeOverMachines() }
        }
    }

    /// owner feature need_takeover: the Screen Sharing way to the asking agent's machine, on an open take-over whose
    /// answer is not on its way (an opened folded card shows no Take over).
    private var takeOverWay: ScreenSharingConnection? { onItsWay == nil ? need.takeOverWay(in: store) : nil }

    /// What a press of Run answered (owner feature `need_run`), or nil.
    private var ranAnswer: NeedRunAnswer? { NeedRunAnswer.of(need, onItsWay: onItsWay) }

    /// The two lines of an answered request: its title, medium (`titleFont`), and what he answered, 12 points muted:
    /// the option that he pressed with a check, on one line, and words that he wrote with none, whole: the card is
    /// where the chat says them. **A request that a saved key answered is one line**: its title and the check at its
    /// end, where the check of his save drew itself (`keyHead`).
    @ViewBuilder private var folded: some View {
        if need.answeredWithKey {
            keyHead(saved: true, draws: false)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(titleFont).foregroundStyle(FleetStyle.text).lineLimit(1)
                if let ran = ranAnswer {
                    // a press of Run: its mark says how the command ended, "Ran on <Mac>" where it ran
                    HStack(spacing: 5) {
                        Image(systemName: ran.symbol).font(IconMetrics.symbol(10, weight: .semibold)).accessibilityHidden(true)
                        Text(ran.words).lineLimit(1)
                    }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if !inWords { Image(systemName: "checkmark").font(IconMetrics.symbol(10, weight: .semibold)) }
                        Text(answerWords).lineLimit(inWords ? nil : 1).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                }
            }
        }
    }

    /// **A key request's card while his save runs, and folded once a saved key answered it**: its title and the mark at
    /// its end (`KeySaveMark`), with no words. The two stand alike to the point, so the folded card takes the place of
    /// the card whose check has drawn itself with no change on the screen.
    private func keyHead(saved: Bool, draws: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(heading).font(titleFont).foregroundStyle(FleetStyle.text).lineLimit(1)
            Spacer(minLength: 8)
            KeySaveMark(saved: saved, draws: draws)
        }
        .accessibilityElement(children: .combine)
    }

    /// The card is its title and the mark of his key save (`KeySaveCard.collapsed`).
    private var keyCollapsed: Bool { keySave.collapsed(expanded: expanded) }

    /// The form's look of his key save: the card goes to its title and the mark, or opens again, in one short motion,
    /// with the form under it (`KeptAway`). A save that starts closes Show all too, so the card has nothing open under
    /// the ring. VoiceOver says the check's word, because the Save that had its focus went with the form.
    private func took(_ look: KeySaveLook?) {
        var next = keySave
        guard next.take(look) else { return }
        withAnimation(reduceMotion ? nil : FleetMotion.keySave) {
            if look == .goes { expanded = false }
            keySave = next
        }
        if look == .saved { AccessibilityNotification.Announcement(String(l10n: "Saved")).post() }
    }

    /// The whole card: over its answer, its parts, or its title and the mark while his key save runs. **The answer
    /// stands in one place whatever the card draws over it**: a key's form finishes its save while the card is its
    /// title and the mark, and stays with a step that failed after the request had its answer (`KeySaveCard`).
    private var whole: some View {
        VStack(alignment: .leading, spacing: 0) {
            if keyCollapsed { keyHead(saved: keySave.look == .saved, draws: true) } else { parts }
            if need.asksForSecret ? keySave.showsForm(open: need.isOpen) : need.isOpen {
                Group {
                    if need.asksForSecret {
                        SecretRequestForm(store: store, need: need, onLook: { took($0) }) {
                            withAnimation(reduceMotion ? nil : FleetMotion.keySave) { keySave.end() }
                        }
                    } else {
                        NeedAnswerBox(store: store, need: need)
                    }
                }
                .padding(.top, keyCollapsed ? 0 : 10)
                .modifier(KeptAway(away: keyCollapsed))
            }
        }
    }

    /// The whole card's parts over its answer.
    private var parts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(heading).font(titleFont).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        // No orange "Needs you" on a request that waits (D-2): every open request needs him. "Answered"
                        // stays, on one opened again.
                        if !need.isOpen { Text("Answered").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
                    }.padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach)
                // owner feature need_takeover (the owner's "Yes, as drawn"): Take over at the right of the title, beside
                // the title's own button and not in it, so that each press does one thing
                if let way = takeOverWay {
                    NeedTakeOverButton(need: need.id, connection: way) {
                        // its error line shows once this press tried to open the screen, not an older error before it
                        Task { await store.takeOver(need); pressedTakeOver = true }
                    }
                }
            }
            if let way = takeOverWay { NeedTakeOverLine(connection: way, pressed: pressedTakeOver) }

            // The reason and the task are two parts of one message: a message's room between them. A take-over has
            // neither: its title is its step.
            if !need.why.isEmpty || !task.isEmpty {
                VStack(alignment: .leading, spacing: ChatStyle.blockSpacing) {
                    if expanded || short {
                        MessageText(text: need.why, chat: true, card: true, names: names)
                    } else {
                        // **An older long card folds to three lines** (the owner, 9 November 2026: "MUCH better so they
                        // are shorter"): the start of its reason, until Show all opens the rest.
                        CardBadgeText.text(MessageBlock.inline(need.why.components(separatedBy: .newlines)
                            .joined(separator: " ")), names: names, size: ChatStyle.size)
                            .font(ChatStyle.font).lineSpacing(ChatStyle.lineSpacing).tint(FleetStyle.link)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            .cardBadges()
                    }
                    // owner feature need_run: the block of its command has Run (the owner's "Yes, as drawn")
                    if !task.isEmpty {
                        MessageText(text: task, chat: true, card: true, run: NeedRunTarget.of(need, store: store),
                                    names: names)
                        CardPageButton(store: store, need: need, task: task)
                    }
                }
            }
            // **The link stands where he pressed it, and what it opens comes under it**, as on Needs you
            // (`NeedStep`; the owner, 20 November 2026: "The Details link seems to be positioned incorrectly"):
            // the details came in over it, and the link went down under them.
            if hasMore {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            // the door's card shows its script there, as the owner approved it ("Yes, as shown")
                            Text(need.details != nil ? (need.door_host != nil ? "Script" : "Details")
                                 : expanded ? "Show less" : "Show all")
                            if need.details != nil {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(IconMetrics.symbol(9, weight: .semibold))
                            }
                        }.padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        // the hand under the pointer, as a link shows it (`NeedStep.moreLink` too), over all that a
                        // click reaches: before the padding that gives the reach back to the layout
                        .pointerStyle(.link)
                        .padding(.vertical, -IconMetrics.reach).font(FormMetrics.detail).foregroundStyle(FleetStyle.link)
                        .accessibilityIdentifier("need-more-\(need.id)")
                    Spacer(minLength: 8)
                }
            }
            if expanded, let details = need.details {
                // **The door's card shows its script line for line** (API 1.125, review point 5.6): one code block, as
                // the request at hand on Needs you draws it, which this Mac hashes before it signs Run it once
                // (`DoorCall.checked`).
                MessageText(text: details, chat: true, script: need.door_script != nil, card: true,
                            names: need.door_script != nil ? nil : names)
            }
            if expanded, !todo.isEmpty, task.isEmpty {
                Text("What it needs from you").font(FormMetrics.detailTitle)
                    .foregroundStyle(FleetStyle.muted).padding(.top, 2)
                MessageText(text: todo, chat: true, card: true, names: names)
            }
            NeedAnswerGiven(store: store, need: need)
            // Who asks, by the name the sidebar gives it and its glyph before it (D-8), and when: a clock time today
            // (T-12).
            AgentNamed(agent: need.by) {
                Text("From \(need.by.agentLabel) · \(messageTime(need.raised))")
            }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        }
    }

}

private extension View {
    /// Tells where this view stands under the top of the space `name`, while `on`: the answer box on a step.
    @ViewBuilder func stands(in name: String, on: Bool, top: @escaping (CGFloat) -> Void) -> some View {
        if on {
            onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(name)).minY } action: { top($0) }
        } else {
            self
        }
    }

    /// The badge of the answer that `agent` recommends on this row (`RecommendedBadge`), when it is not nil: its middle
    /// on the row's top edge and its end `inset` from the row's, with room over the row for its upper half. The row is
    /// one view with or without it, so a reading that brings the badge keeps the row's own state.
    func recommendedBadge(by agent: String?, ground: Color, inset: CGFloat = RecommendedBadge.inset) -> some View {
        overlay(alignment: .topTrailing) {
            // The guide stands on a view that is always there: on the badge inside the `if`, the overlay did not read
            // it, and the badge hung inside the row.
            ZStack {
                if let agent { RecommendedBadge(agent: agent, ground: ground) }
            }
            .alignmentGuide(.top) { $0[VerticalAlignment.center] }
            .padding(.trailing, inset)
        }
        .padding(.top, agent == nil ? 0 : RecommendedBadge.room)
    }
}
