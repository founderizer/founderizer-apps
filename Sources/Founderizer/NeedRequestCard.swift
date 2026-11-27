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

    func makeBody(configuration: Configuration) -> some View {
        OptionRow(configuration: configuration, marked: marked, gives: gives)
    }

    private struct OptionRow: View {
        let configuration: ButtonStyleConfiguration
        let marked: Bool
        let gives: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        private var lit: Bool { (hovered || marked) && isEnabled }
        /// The violet of a number key's mark, or the hairline. **The answer that the agent recommends has its badge and
        /// no edge of its own** (the owner, 20 November 2026: "the recommended options should only have the badge, not
        /// the border over the option, otherwise it looks alraedy selected"): its edge was the agent's colour.
        private var edge: Color {
            if marked && isEnabled { return FleetStyle.accent }
            return FleetStyle.hairline(lit ? 0.18 : 0.10)
        }

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .fill(Color.white.opacity(gives ? (configuration.isPressed ? 0.78 : lit ? 1 : 0.94) : lit ? 0.09 : 0.05))
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
                        .strokeBorder(edge, lineWidth: marked && isEnabled ? 1 : FleetStyle.edgeWidth(contrast))))
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
/// capsule, it is the capsule's edge, and a light tint of the glyph's light step is the word. **The row keeps the look
/// of every other option** (the owner, 20 November 2026: "the recommended options should only have the badge, not the
/// border over the option, otherwise it looks alraedy selected"): its edge took the colour too. VoiceOver reads the
/// word on the row (its value or hint), so the badge itself is hidden from it.
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
    /// Owner feature `need_clarify` (API 1.272): Needs clarification is open, its field where its link stood.
    @State private var clarifying = false
    /// His message under the card, until the hub has it.
    @State private var clarifyText = ""
    /// It is on its way: the field waits for the hub's receipt.
    @State private var clarifySending = false
    @FocusState private var clarifyFocused: Bool
    /// He pressed the link now: the field takes the cursor once it stands.
    @State private var cursorToClarify = false
    /// He chose to keep what looks like a key in this message, as `keyAllowed` in his answer.
    @State private var clarifyKeyAllowed = false
    /// On a step, the keys that came while the field of Needs clarification had no cursor yet: they go to it once it
    /// has the cursor (`key`, `awaitClarifyCursor`).
    @State private var clarifyHeld: [NSEvent] = []
    /// On a step, from the press of Needs clarification until the field's editor has the keys: the page's keys wait.
    @State private var awaitingClarifyCursor = false
    /// **The card's own window, or nil in a chat** (`NeedWindows`): the chat's keys go to the field of the chat's card
    /// only (`FleetStore.clarifying`), so a card in its own window neither takes them nor changes where they go.
    @Environment(\.needWindow) private var cardWindow
    /// In the card's own window: the watch of that window's keys while they wait for the field of Needs clarification
    /// (`holdWindowKeys`). A card in a chat and a step have none.
    @State private var windowKeys = ClarifyWindowKeys()
    /// The card takes his message under it (`OwnerNeed.clarifies`): the hub says so, and the item is open.
    private var clarifies: Bool { need.clarifies(features: store.state?.ui_features) }
    /// His talk over the answers of an open item in a chat's card (`OwnerNeed.shownTalk`). An answered chat card shows
    /// it in its parts, and the step on Needs you over its answers itself (`NeedStep.answers`), where it stays when he
    /// answers.
    private var talk: [NeedMessage] { need.isOpen && !onStep ? need.shownTalk(features: store.state?.ui_features) : [] }
    /// **The card stands on a page of the main window** (a chat; `cardOnPage`): with the step of Needs you, the place of
    /// a held answer is the page that shows (`AnswerHolds.Place`); in the card's own window, that window, which becomes
    /// the badge of it (`NeedWindows`); else a card that is on neither (the job's detail card).
    @Environment(\.cardOnPage) private var cardOnPage
    private var holdPlace: AnswerHolds.Place {
        onStep || cardOnPage ? .page(store.destination.page) : cardWindow != nil ? .window : .card
    }
    /// The guard's own key for the field of Needs clarification, beside the answer's (`guardKey`).
    private var clarifyGuardKey: String { "need-clarify-\(need.id)" }
    private var clarifyWords: String { clarifyText.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// As the hub counts a message: code points, not the characters that he sees (`OwnerCommand.needTalk`).
    private var canClarify: Bool {
        store.canWrite && !clarifySending && !clarifyWords.isEmpty && clarifyWords.unicodeScalars.count <= NeedTalk.most
    }
    /// **His unsent message under each card, in memory only** (as the key card's words, `SecretRequestForm`): the
    /// request at hand is a new view each time it comes to hand, and the words were gone after a click on another
    /// card. Never on the disk, because a key pasted there by mistake must not stay; words that look like a key are not
    /// kept at all. By the hub, its generation and the item.
    @MainActor private static var clarifyDrafts: [String: String] = [:]
    private var clarifyDraftKey: String { "\(store.hub.absoluteString) \(store.state?.db ?? "") \(need.id)" }
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
    /// Owner feature `need_recommended` (API 1.269): the row of the answer that the agent recommends, or nil
    /// (`OwnerNeed.recommendedRow`).
    private var recommendation: NeedRecommended.Row? {
        need.recommendedRow(features: store.state?.ui_features, replies: Self.quickReplies)
    }
    /// What the badge stands on, which its fill covers: the canvas under the request at hand, a card in a chat.
    private var ground: Color { onStep ? FleetStyle.canvas : FleetStyle.surface }
    /// The place in `tops` of the row of the agent's own words (`NeedRecommended.Row.words`), beside the options' indexes
    /// and the field's -1.
    private static let recommendedWords = -2
    /// The room at the end of a row of options that combine, after its tick.
    private var tickInset: CGFloat { onStep ? 10 : 6 }
    /// Owner feature `need_pictures` (API 1.285): the pictures of the options, one over each option's words, or nil
    /// (`OwnerNeed.optionPictures`).
    private var pictures: [MessageAttachment]? { need.optionPictures(features: store.state?.ui_features) }
    /// The picture that the preview window shows now; nil while it is closed.
    @State private var previewed: URL?
    /// The pictures in one row, and a second row for the rest: three, as drawn, and **two in the card's own window**
    /// (`NeedWindows`), which is 420 points wide and 340 at least: three there were squares of about 100 points, and the
    /// iPhone's card, of about that width, draws two.
    private var picturesInARow: Int { cardWindow == nil ? 3 : 2 }

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

    /// One option of an item whose options combine: its words, and its tick at the right, which a press anywhere on the
    /// row turns. `fills`: as high as it is given, as the words under the pictures of one row are.
    private func tickRow(_ index: Int, option: String, marks: Bool, fills: Bool = false) -> some View {
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
        .frame(minHeight: onStep ? FormMetrics.row : nil, maxHeight: fills ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: FormMetrics.inner).fill(Color.white.opacity(0.05)))
        .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
        .onTapGesture { if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) } }
        .accessibilityIdentifier("need-tick-\(need.id)-\(index)")
        // its badge ends before the tick's column, which stays clear
        .recommendedBadge(by: marks ? need.by : nil, ground: ground, inset: tickInset + IconMetrics.side)
    }

    /// Send, with how many options he ticked, under options that combine.
    private var sendTicked: some View {
        HStack {
            Spacer()
            Button("Send \(ticked.count)") {
                guard !(onStep && SecondClick.isNow) else { return }
                let chosen = Array(ticked)
                answered?(false, 0)
                holdTicked(chosen)
            }.buttonStyle(FleetPrimaryButtonStyle()).disabled(ticked.isEmpty || !store.canWrite)
                .accessibilityIdentifier("need-send-ticked-\(need.id)")
            // On a step it stands in the middle, as a step's one button does.
            if onStep { Spacer() }
        }
    }

    /// **The options as pictures** (owner feature `need_pictures`; the owner's "Yes, as drawn" of 21 November 2026 to
    /// the drawings of Needs you and of a chat's card): three in a row, and a second row for a fourth to a sixth, each
    /// picture over its option's words (two in a row in the card's own window, `picturesInARow`). **A press on a
    /// picture opens it whole in the preview window, and answers nothing**: he looks at it before he chooses. A press
    /// on the words answers at once, as an option's row does, and
    /// the number keys mark or tick them as they do the rows (`key`). Where the options combine, the words have their
    /// tick, and Send stands under the pictures. The badge of the answer that the agent recommends stands on the top
    /// edge of its picture, the top of its option.
    private func pictureOptions(_ pictures: [MessageAttachment], recommended: NeedRecommended.Row?) -> some View {
        let waiting = AnswerWaits.shared.press(of: need)
        let inARow = picturesInARow
        let rows = stride(from: 0, to: pictures.count, by: inARow).map {
            Array($0..<min($0 + inARow, pictures.count))
        }
        return VStack(alignment: .leading, spacing: onStep ? 12 : 10) {
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: onStep ? 12 : 10) {
                    ForEach(0..<inARow, id: \.self) { column in
                        if column < row.count {
                            pictureOption(row[column], picture: pictures[row[column]],
                                          marks: recommended == .option(row[column]), waiting: waiting)
                        } else {
                            // the place of an option that the row does not have, so each picture keeps its width
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
                // each option's words as high as the highest in its row
                .fixedSize(horizontal: false, vertical: true)
                // the room over a row for the badge's upper half, for each of its pictures, so they stand at one height
                .padding(.top, row.contains { recommended == .option($0) } ? RecommendedBadge.room : 0)
            }
            if need.combines { sendTicked }
        }
        // **The pictures are read one after another, in the order of the options** (as the iPhone's card does): six
        // large pictures read at once can each end "Not loaded" on a slow link. A picture whose bytes are here costs
        // nothing; a change of hub or generation, and the hub's answer after a break, read again what did not come.
        .task(id: "\(store.isFresh) \(store.filesGeneration) \(pictures.map(\.sha256))") {
            guard store.isFresh else { return }
            for file in pictures where store.heldBytes(of: file) == nil {
                if Task.isCancelled { return }
                await store.load(file)
            }
        }
    }

    /// One option of `pictureOptions`: its picture, which opens, and under it its words, which answer or tick.
    private func pictureOption(_ index: Int, picture: MessageAttachment, marks: Bool,
                               waiting: WaitingPresses.Press?) -> some View {
        let option = need.choices[index]
        let sending = waiting?.choice == index
        return VStack(spacing: 8) {
            Button { preview(picture) } label: {
                PictureTile(store: store, file: picture, side: .center, square: true, readsItself: false)
            }
                .buttonStyle(.plain)
                .help(String(l10n: "Open the picture of \(option)"))
                .accessibilityLabel(String(l10n: "The picture of \(option)"))
                .accessibilityIdentifier("need-picture-\(need.id)-\(index)")
                // the picture takes its whole square first; the words take the rest of the row's height
                .layoutPriority(1)
            // What did not happen when he opened it, under the picture, as under a chat's file.
            if let problem = store.fileProblems[picture.id] {
                Text(problem).font(FormMetrics.detail).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            if need.combines {
                tickRow(index, option: option, marks: false, fills: true)
            } else {
                Button {
                    guard !(onStep && SecondClick.isNow) else { return }
                    marked = nil
                    answered?(false, tops[index] ?? 0)
                    holdOption(index)
                } label: {
                    row(option, sendingSince: sending ? waiting?.since : nil).frame(maxHeight: .infinity)
                }
                    .buttonStyle(NeedOptionButtonStyle(marked: marked == index))
                    .stands(in: Self.space, on: onStep) { tops[index] = $0 }
                    .accessibilityValue(sending ? "Sending" : marks ? "Recommended" : "")
                    .accessibilityIdentifier("need-option-\(need.id)-\(index)")
            }
        }
        .frame(maxWidth: .infinity)
        .recommendedBadge(by: marks ? need.by : nil, ground: ground, makesRoom: false)
    }

    /// The picture whole, in the preview window, as a chat's file opens (`ChatFileCopy`): its bytes from the hub, checked,
    /// written where only this user can read them.
    private func preview(_ file: MessageAttachment) {
        Task {
            guard let data = await store.bytes(of: file) else { return }
            let result = await Task.detached(priority: .userInitiated) { Result { try ChatFileCopy.written(data, of: file) } }.value
            switch result {
            case .success(let place):
                previewed = place
                store.setFileProblem(nil, for: file.id)
            case .failure:
                store.setFileProblem(String(l10n: "This file did not open on this Mac."), for: file.id)
            }
        }
    }

    var body: some View {
        // owner feature need_recommended: the row that has the badge of the answer that the agent recommends
        let recommended = recommendation
        VStack(alignment: .leading, spacing: 8) {
            // owner feature need_clarify: his talk with the manager under the card, over its answers (also where the
            // card takes no more of it, as after a switch of the manager: the talk stays his record)
            if !talk.isEmpty { NeedTalkLines(talk: talk, font: words).padding(.bottom, 2) }
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
                            .buttonStyle(NeedOptionButtonStyle())
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
                            .buttonStyle(NeedOptionButtonStyle())
                            .stands(in: Self.space, on: onStep) { tops[index] = $0 }
                            .accessibilityValue(marks ? "Recommended" : "")
                            .accessibilityIdentifier("quick-\(reply.lowercased())-\(need.id)")
                            .recommendedBadge(by: marks ? need.by : nil, ground: ground)
                    }
                }
            } else if let pictures {
                // owner feature need_pictures: the options as pictures, over their words
                pictureOptions(pictures, recommended: recommended)
            } else if need.combines {
                // **Options that combine** (the owner's yes of 9 November 2026): a tick at the right of each row, and one
                // Send with how many he ticked; it stays off while none is ticked.
                VStack(alignment: .leading, spacing: onStep ? 8 : 7) {
                    ForEach(Array(need.choices.enumerated()), id: \.offset) { index, option in
                        tickRow(index, option: option, marks: recommended == .option(index))
                    }
                    sendTicked
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
                            holdOption(index)
                        } label: {
                            row(option, sendingSince: sending ? waiting?.since : nil, gives: gives)
                        }
                            .buttonStyle(NeedOptionButtonStyle(marked: marked == index, gives: gives))
                            .stands(in: Self.space, on: onStep) { tops[index] = $0 }
                            .accessibilityValue(sending ? "Sending" : marks ? "Recommended" : "")
                            .accessibilityIdentifier("need-option-\(need.id)-\(index)")
                            .recommendedBadge(by: marks ? need.by : nil, ground: ground)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let held = store.heldKey, held.composer == guardKey {
                    KeyHoldBanner(hold: held.hold, agent: need.by, narrow: cardWindow != nil) {
                        saveHeldKey(held, words: text)
                    } goOn: {
                        keepHeldKey(held, words: text, allowed: $keyAllowed)
                    }
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
            // owner feature need_clarify: the quiet link Needs clarification under his answer, and its field in its place
            if clarifies {
                if clarifying { clarifyBox } else { clarifyLink }
            }
        }
        .coordinateSpace(.named(Self.space))
        .quickLookPreview($previewed)
        // The keys of the request at hand, through the page's one watch; a card in a chat has none.
        .background { if let keys { StepKeysBox(keys: keys, need: need.id, take: key) } }
        .task { if takesCursor { focused = true } }
        // owner feature need_clarify: his unsent message of this card, kept while he looked at another one
        .onAppear {
            restoreClarifyDraft()
            // the options that he had ticked, on a card whose answer he took back (`AnswerHolds.undo`)
            let back = AnswerHolds.shared.restoredTicks(of: need.id)
            if !back.isEmpty { ticked = back }
        }
        // in the card's own window only: the window's keys wait for the field of Needs clarification (`holdWindowKeys`)
        .modifier(ClarifyWindowKeysPlace(keys: cardWindow == nil ? nil : windowKeys))
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
        // **From the press of Needs clarification until its field has the cursor, the step's keys are its words** (the
        // owner, 21 November 2026: "I clicked on discuss and typed, dont remember where"; on his busy Mac the keys came
        // before the field took them, and "2" and Return pressed option 2): a key waits and goes to the field once it
        // has the cursor, so a number marks no option and Return presses none (`awaitClarifyCursor`). After that the
        // page's keys are as before, also after Escape leaves the field.
        if awaitingClarifyCursor {
            clarifyHeld.append(event)
            clarifyFocused = true
            return true
        }
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
                holdTicked(chosen)
            } else if let option = marked, choices.indices.contains(option) {
                marked = nil
                answered?(false, tops[option] ?? 0)
                holdOption(option)
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

    /// The task of the press, which a held answer awaits (`AnswerHolds`); nil where the request has a press already.
    @discardableResult
    func press(_ need: OwnerNeed, choice: Int, store: FleetStore) -> Task<Void, Never>? {
        guard presses.press(choice, need: need.id, at: .now) else { return nil }
        let hub = store.hub, database = store.state?.db
        return Task { @MainActor in
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
        guard let database = store.state?.db else { return }
        let store = store, id = need.id, hub = store.hub
        let shown = PendingRequest(hub: hub, database: database, client: store.installation, needID: id,
                                   text: text.wrappedValue)
        AnswerHolds.shared.hold(need, store: store, place: holdPlace, shown: shown,
                                names: store.cardNames(for: need)) {
            // **It waits while the hub cannot take it**, as a press does (review): another answer can be on its way
            // when the wait ends, and a send then went nowhere
            guard await store.writable(), store.hub == hub, store.state?.db == database else { return }
            await store.send(needID: id)
        }
    }

    /// **His press of an option waits 5 seconds, with Undo** (`AnswerHolds`: the badge of the page, or the folded card's
    /// line in the card's own window), and then goes as a press went before: through `AnswerWaits`, with the signature
    /// of a door's call and the grant of a Give.
    ///
    /// **A press that opens a page or a flow on this Mac goes at once, with no wait and no badge**: the first option of an
    /// item for his phone opens Settings › Servers, and of a GitHub App item starts that app's flow (`FleetStore.answer`).
    /// Held, the page changed by itself 5 seconds after the card had completed (F12, A1). As his next answer, it sends
    /// the answer that waited before it.
    private func holdOption(_ index: Int) {
        guard need.choices.indices.contains(index), let database = store.state?.db else { return }
        let store = store, need = need
        if index == 0, need.add_device == 1 || need.github_app != nil {
            AnswerHolds.shared.releaseAll()
            AnswerWaits.shared.press(need, choice: index, store: store)
            return
        }
        let shown = PendingRequest(hub: store.hub, database: database, client: store.installation, needID: need.id,
                                   choice: index, text: need.choices[index])
        AnswerHolds.shared.hold(need, store: store, place: holdPlace, shown: shown,
                                names: store.cardNames(for: need)) {
            await AnswerWaits.shared.press(need, choice: index, store: store)?.value
        }
    }

    /// The options that he ticked wait as a press does (`holdOption`), and Undo ticks them again.
    private func holdTicked(_ chosen: [Int]) {
        let ticked = Array(Set(chosen)).sorted()
        guard !ticked.isEmpty, ticked.allSatisfy(need.choices.indices.contains), let database = store.state?.db else { return }
        let store = store, need = need, hub = store.hub
        let shown = PendingRequest(hub: hub, database: database, client: store.installation, needID: need.id,
                                   choices: ticked, text: ticked.map { need.choices[$0] }.joined(separator: "; "))
        AnswerHolds.shared.hold(need, store: store, place: holdPlace, shown: shown, ticked: Set(ticked),
                                names: store.cardNames(for: need)) {
            // it waits while the hub cannot take it, as a press does (`holdOption`)
            guard await store.writable(), store.hub == hub, store.state?.db == database else { return }
            await store.answer(need, choices: ticked)
        }
    }

    /// One of the app's three replies, or the agent's recommended words, pressed: its words are the answer, with the
    /// files that wait in the box, and they go by the path of words that he wrote (`FleetStore.send`: the outbox, its
    /// receipt and its retry). **His box is never their place** (the owner's report of 22 November 2026: he pressed
    /// Done, and "Done" stood in his Your answer box): they wait 5 seconds with Undo as an option's press does
    /// (`AnswerHolds`), and his own words stay in the box as they were, through Undo and after. **A press whose wait
    /// ends while the hub cannot take it, or while a file of the box still goes up, waits, and goes when it can**, as an
    /// option's press does (`AnswerWaits`): only to the hub and generation of the press, while the request is open. No
    /// clock ends the wait; an upload ends, or fails. Not covered, as for an option's press: a reply whose box holds a
    /// file that failed to go up or waits with no upload, or whose send another write takes the turn from, goes nowhere,
    /// and no line says so.
    private func sendQuickReply(_ reply: String, from index: Int) {
        guard let database = store.state?.db else { return }
        answered?(false, tops[index] ?? 0)
        let store = store, id = need.id, hub = store.hub, composer = composer
        let shown = PendingRequest(hub: hub, database: database, client: store.installation, needID: id, text: reply)
        AnswerHolds.shared.hold(need, store: store, place: holdPlace, shown: shown,
                                names: store.cardNames(for: need)) { @MainActor in
            // The store's own pace for a write that waits for it (`FleetStore.writable`), and a file of the box that
            // still goes up: the reply carries the box's files.
            while !store.canWrite || composer.map({ Self.uploading(in: $0, store: store) }) == true {
                guard store.hub == hub, store.state?.db == database, store.storageError == nil,
                      store.openNeeds.contains(where: { $0.id == id }) else { return }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard store.hub == hub, store.state?.db == database else { return }
            await store.send(needID: id, words: reply)
        }
    }

    /// A file of this box goes up now: its upload runs (`FleetStore.uploading`). A file that waits with no upload (one
    /// that a quit cut off, "Waiting") or whose upload failed is none: no wait for it would ever end, a quit's neither.
    private static func uploading(in composer: String, store: FleetStore) -> Bool {
        store.stagedFiles(for: composer).contains { store.uploading.contains($0.requestID) }
    }

    /// "Save it as a secret": the key goes into the secure form and out of his words (the answer, or his message under
    /// the card). The agent that asked gets its name in its chat, when the owner has one with it. **From the card's own
    /// window, the main window comes to the front with the app** (`NeedWindowLink.showMainWindow`): the secure form is
    /// a card over the main window's page, which stands behind his browser while he works in the card's window, so
    /// the press showed nothing there.
    private func saveHeldKey(_ held: HeldKey, words: Binding<String>) {
        store.heldKey = nil
        var key: String?
        if held.hold == .paste { key = KeyCut.onClipboard() }
        else if let cut = KeyCut.split(words.wrappedValue) { words.wrappedValue = cut.rest; key = cut.key }
        store.secretForm = SecretPreset(tell: store.canChat(with: need.by) ? need.by : nil, key: key, kept: SecretValueKept())
        cardWindow?.showMainWindow()
    }

    /// "Paste it anyway" or "Keep it": the owner's choice, and no second question while the key is in his words.
    private func keepHeldKey(_ held: HeldKey, words: Binding<String>, allowed: Binding<Bool>) {
        store.heldKey = nil
        allowed.wrappedValue = true
        if held.hold == .paste, let pasted = NSPasteboard.general.string(forType: .string) { words.wrappedValue += pasted }
    }

    // MARK: Needs clarification (owner feature need_clarify, owner API 1.272)

    /// **Needs clarification**: the key card's link and words (`StepClarifyLink` on a step, in the violet of Details; in
    /// a chat's card, the card's small muted words), under his answer, with the hand of a link. A press puts the field
    /// in its place.
    @ViewBuilder private var clarifyLink: some View {
        let help = String(l10n: "Write to \(need.by.agentLabel) about this request")
        if onStep {
            // in the middle, as a step's one link and its one button stand
            StepClarifyLink { openClarify() }
                .help(help).accessibilityIdentifier("need-clarify-\(need.id)")
                .frame(maxWidth: .infinity)
        } else {
            Button { openClarify() } label: {
                Text("Needs clarification").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .pointerStyle(.link)
                .padding(.vertical, -IconMetrics.reach).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                .help(help).accessibilityIdentifier("need-clarify-\(need.id)")
        }
    }

    /// His press of the link: the field stands, and takes the cursor once it does (`clarifyBox`). Not from the second
    /// click of a double-click on the request before this one (`SecondClick`).
    private func openClarify() {
        guard !(onStep && SecondClick.isNow) else { return }
        clarifying = true
        cursorToClarify = true
        // **The keys leave the field that has them at once, and the next ones are the card's** (the owner, 21 November
        // 2026, of his first message under a card: "I clicked on discuss and typed, dont remember where"; his words went
        // to the chat's box, which kept the keys until the field came): until this field takes them, a chat sends a key
        // that it would send to its box here (`FleetStore.clarifying`, `FleetView.typeIntoBox`), and a step's keys wait
        // for it (`key`).
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isKeyWindow), window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
        if onStep { awaitClarifyCursor() } else if cardWindow == nil { store.clarifying = (need.id, clarifyText) } else {
            holdWindowKeys()
        }
    }

    /// **In the card's own window, its keys wait for the field as a step's keys do** (the owner, 21 November 2026, of
    /// his first message under a card: "I clicked on discuss and typed, dont remember where"; in the window the keys that
    /// came before the field took them were lost): from the press until the field's editor has the keys, at most 2 s,
    /// each key of the card's window that types or edits words waits (`ClarifyWindowKeys`), and goes to the field in its
    /// order once the field has the cursor (`awaitClarifyCursor`). A key of another window is not the card's, and a
    /// shortcut, Escape, Return and Tab do what they did. The chat's route (`FleetStore.clarifying`) stays the chat card's.
    private func holdWindowKeys() {
        windowKeys.hold(while: { awaitingClarifyCursor }) { event in
            clarifyHeld.append(event)
            clarifyFocused = true
        }
        awaitClarifyCursor(in: windowKeys.window)
    }

    /// The chat's open Needs clarification field is no longer this one (sent, closed, or gone from the chat). Never
    /// from the card's own window, whose field the chat's keys do not reach.
    private func leaveClarify() {
        if cardWindow == nil, store.clarifying?.need == need.id { store.clarifying = nil }
    }

    /// **On a step, the page's keys wait for the field until its editor has the keys**, up to 2 s at the pace of a draw,
    /// as a chat's box waits for its field (`ComposerCaret`): then the keys that waited go to it, first in the queue and
    /// in their order, and the page leaves a key to a field that has the cursor (`PageKeys`). A field that never takes
    /// the cursor drops them, so that no key of his words reaches the options. `own`: the card's own window, whose field
    /// it waits for while that window has the keyboard (`holdWindowKeys`); nil on a step, the key window.
    private func awaitClarifyCursor(in own: NSWindow? = nil) {
        awaitingClarifyCursor = true
        Task { @MainActor in
            for _ in 0..<100 {
                guard awaitingClarifyCursor else { return }
                if let window = own ?? NSApp.keyWindow ?? NSApp.windows.first(where: \.isKeyWindow), window.isKeyWindow,
                   let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                    awaitingClarifyCursor = false
                    let keys = clarifyHeld
                    clarifyHeld = []
                    for key in keys.reversed() { NSApp.postEvent(key, atStart: true) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            awaitingClarifyCursor = false
            clarifyHeld = []
        }
    }

    /// **The field of Needs clarification**, as the key card's: the box of his answer with no files and no replies, its
    /// words "Message to <agent>", one line at rest and a line more for each line he writes, Send with Return. Words that
    /// look like a key wait for his choice, as in his answer (`KeyHoldBanner`).
    private var clarifyBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let held = store.heldKey, held.composer == clarifyGuardKey {
                KeyHoldBanner(hold: held.hold, agent: need.by, narrow: cardWindow != nil) {
                    saveHeldKey(held, words: $clarifyText)
                } goOn: {
                    keepHeldKey(held, words: $clarifyText, allowed: $clarifyKeyAllowed)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(String(l10n: "Message to \(need.by.agentLabel)"), text: $clarifyText, axis: .vertical)
                    .focused($clarifyFocused)
                    .accessibilityIdentifier("need-clarify-words-\(need.id)")
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        sendClarify()
                        return .handled
                    }
                    .composerField(alone: true, lines: 1...8, font: onStep ? SetupMetrics.textFont : ChatStyle.font,
                                   line: onStep ? Self.stepLine : ChatStyle.line)
                    .onChange(of: clarifyText) { _, now in
                        // the chat's box sends a key here once the field has these words (`FleetView.typeIntoBox`)
                        if cardWindow == nil, store.clarifying?.need == need.id { store.clarifying = (need.id, now) }
                        // kept while the card is open, in memory: never words that look like a key
                        let kept = now.trimmingCharacters(in: .whitespacesAndNewlines)
                        Self.clarifyDrafts[clarifyDraftKey] = kept.isEmpty || KeyInText.contains(now) ? nil : now
                        guard guards else { return }
                        if !KeyInText.contains(now) {
                            clarifyKeyAllowed = false
                            if store.heldKey == HeldKey(composer: clarifyGuardKey, hold: .text) { store.heldKey = nil }
                        } else if !clarifyKeyAllowed && store.heldKey == nil {
                            store.heldKey = HeldKey(composer: clarifyGuardKey, hold: .text)
                        }
                    }
                SendSlot(shows: canClarify) {
                    Button { sendClarify() } label: { SendMark() }
                        .buttonStyle(FleetIconButtonStyle(filled: true)).disabled(!canClarify)
                        .help("Send this message").accessibilityLabel("Send message")
                        .accessibilityIdentifier("need-clarify-send-\(need.id)")
                }
            }
            .padding(onStep ? (FormMetrics.row - IconMetrics.side) / 2 : ComposerCapsule<EmptyView, EmptyView>.inset)
            .background(FleetStyle.composer, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
                .strokeBorder(FleetStyle.hairline(0.32), lineWidth: FleetStyle.edgeWidth(contrast)))
            .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
            .onTapGesture { clarifyFocused = true }
            .keyPasteGuard(store: store, composer: clarifyFocused && guards ? clarifyGuardKey : nil)
            // while it goes: his words stand, and nothing takes a second send
            .disabled(clarifySending)
        }
        // The cursor comes once the field stands, as the key card's field takes it: set in the press that makes the
        // field, it could stay where it was.
        .task { if cursorToClarify { clarifyFocused = true; cursorToClarify = false } }
        // a key that the chat would have sent to its box (`FleetStore.clarifyKeys`): this field takes the keyboard
        .onChange(of: store.clarifyKeys) { _, _ in
            if cardWindow == nil, store.clarifying?.need == need.id { clarifyFocused = true }
        }
        .onDisappear { leaveClarify(); clarifyHeld = []; awaitingClarifyCursor = false }
    }

    /// His message goes to the manager, and the item stays open (`OwnerCommand.needTalk`). Once the hub has it, the
    /// field goes and the link comes back; his message stands in the card's talk from the next reading.
    private func sendClarify() {
        guard !(onStep && SecondClick.isNow), canClarify else { return }
        if guards && !clarifyKeyAllowed && KeyInText.contains(clarifyText) {
            store.heldKey = HeldKey(composer: clarifyGuardKey, hold: .text)
            return
        }
        let words = clarifyWords, command = OwnerCommand.needTalk(need: need.id)
        clarifySending = true
        Task {
            let sent = await store.command(command, note: words)
            // **Gone from the field once the outbox has it**: a request that the hub did not confirm yet goes again from
            // the outbox (its line says so), and words left here would go a second time with a second Send. Words that
            // the hub refused stay here, with the request line's reason.
            if sent || (store.pending?.command == command && store.pending?.refusal == nil) {
                clarifyText = ""
                clarifying = false
                leaveClarify()
                Self.clarifyDrafts[clarifyDraftKey] = nil
            }
            clarifySending = false
        }
    }

    /// His unsent message of this card comes back with the card (`clarifyDrafts`), and the words of cards that closed
    /// on this hub go.
    private func restoreClarifyDraft() {
        let here = "\(store.hub.absoluteString) \(store.state?.db ?? "") "
        let open = Set(store.openNeeds.map { here + String($0.id) })
        Self.clarifyDrafts = Self.clarifyDrafts.filter { !$0.key.hasPrefix(here) || open.contains($0.key) }
        if clarifies, !clarifying, let draft = Self.clarifyDrafts[clarifyDraftKey] {
            clarifyText = draft
            clarifying = true
        }
    }
}

/// **His talk with the manager under a card** (Needs clarification, owner feature `need_clarify`): his messages at the
/// right in the chat's own bubble, the agent's replies at the left with its glyph, compact, over the card's answers. The
/// words are plain text, as he and the agent wrote them.
struct NeedTalkLines: View {
    let talk: [NeedMessage]
    /// The words of the card's answers: 13 points in a chat's card, the step's 15 on Needs you.
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(talk.enumerated()), id: \.offset) { _, line in
                if line.fromOwner {
                    Text(line.text).font(font).foregroundStyle(FleetStyle.text).textSelection(.enabled)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(ChatStyle.bubble, in: RoundedRectangle(cornerRadius: ChatStyle.bubbleRadius))
                        .padding(.leading, 48)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityElement(children: .ignore).accessibilityLabel(Text("You: \(line.text)"))
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        AgentGlyph(name: line.who, presence: .online, size: GlyphSize.inline, dot: false).padding(.top, 1)
                        Text(line.text).font(font).foregroundStyle(FleetStyle.text).textSelection(.enabled)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.trailing, 48)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(line.who.agentLabel): \(line.text)"))
                }
            }
        }
    }
}

extension FleetStore {
    /// The files that went with his answer to `need`: the ones on the message that answered it.
    func answerFiles(of need: OwnerNeed) -> [MessageAttachment] {
        state?.messages.last { $0.need_id == need.id }?.attachments ?? []
    }
}

/// **His answer as a card shows it** (F23 N1; the owner, 23 November 2026: "We should ALWAYS use the name", and "The
/// name with the role in grey"): an option that he pressed is the agent's words, and an agent that it names by its
/// whole role shows by its name with the role beside it (`RoleNames`); **words that he typed keep a role as he wrote
/// it** (`RoleNames.written`), as his bubble in a chat does. VoiceOver reads what the card shows.
enum HisAnswer {
    /// **The answer is words that he typed**: an answer in words (`inWords`: no option that he pressed, no form), that
    /// no one else wrote for him: not the hub's or an agent's end of the item (`answered_by`: "Closed by the hub: …",
    /// "Withdrawn by …"), and not the agent's recommended words, which a press of their row sends (`recommended`). Those
    /// are the agent's or the hub's words, which show an agent by its name.
    static func typed(_ need: OwnerNeed, _ answer: String, inWords: Bool) -> Bool {
        let words = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return inWords && need.answered_by == nil
            && words != need.recommended?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words of `answer` (`MessageBlock.inline`), marked as his own where he typed them (`inWords`, `typed`).
    static func words(_ answer: String, inWords: Bool) -> AttributedString {
        let words = MessageBlock.inline(answer)
        return inWords ? RoleNames.written(words) : words
    }

    /// What VoiceOver reads of `answer`: its words as the card draws them, a name and its role beside it as one
    /// (`RoleNames.words`), and as written where no names are read.
    static func spoken(_ answer: String, inWords: Bool, names: CardNames?,
                       roles: [String: String] = AgentNames.shared.roles) -> String {
        let words = Self.words(answer, inWords: inWords)
        return String((names.map { RoleNames.words(words, names: $0, roles: roles) } ?? words).characters)
    }
}

/// What the owner answered: the words, and the files that went with them, because an answer may be files alone.
/// The files are the ones on the message that answered this request.
struct NeedAnswerGiven: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    let names: CardNames

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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your answer").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    // **His answer whole, as the card's words are drawn** (the owner, 20 November 2026: "ok but use
                    // always the agent badges and icons!!"): the chat's look, and each name that the card links as its
                    // badge (`CardNames`), where it was plain text of 12 points; words that he typed keep a role as he
                    // wrote it (`HisAnswer`)
                    if !answer.isEmpty {
                        MessageText(text: answer, chat: true, card: true, names: names,
                                    asWritten: HisAnswer.typed(need, answer, inWords: need.answeredInWords))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
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
    /// **The card in a window of its own** (`NeedWindows`; the owner's "Yes, as drawn" of 21 November 2026), or nil in a
    /// chat: there it has no icon to open a window, its long part is open from the start, the window's ground is its
    /// fill and it draws no edge, its names open their pages through the window, and it tells the window its key save.
    @Environment(\.needWindow) private var cardWindow
    /// He opened or closed the card's long part, or nil for the card as it starts: closed in a chat, open in a window.
    @State private var opened: Bool?
    private var expanded: Bool {
        get { opened ?? (cardWindow != nil) }
        nonmutating set { opened = newValue }
    }
    /// His answer as the outbox saved it, kept from the frame it went until the reading says the request is answered
    /// (`WordsOnTheirWay`): the store lets the request go with its receipt, a round trip before that reading.
    @State private var sent: PendingRequest?
    /// **His key save on this card**, as its form tells it (`KeySaveCard`): the card stands as its title and the ring,
    /// then the check, and folds once the check has drawn itself.
    @State private var keySave = KeySaveCard()
    /// The width that its key's form draws (`SecretFormWidth`), which his talk over it takes; nil until it said so.
    @State private var formWidth: CGFloat?
    /// The width of a form page's cards, where the card stands on one; in a chat, nil, and the card takes the column's.
    @Environment(\.formMeasure) private var measure
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// **His answer on its way: the card folds in the frame he sends it, with his words** (fix round 3, item 11), as it
    /// folds once the reading says it is answered. It folded only with that reading, a round trip after the hub's
    /// receipt.
    private var onItsWay: PendingRequest? {
        holding?.shown ?? store.answerOnItsWay(to: need, kept: sent) ?? AnswerHolds.shared.leaving(need, in: store)?.shown
    }
    /// **His answer waits 5 seconds, with Undo** (`AnswerHolds`): the card stands folded as with an answer on its way.
    private var holding: AnswerHolds.Held? { AnswerHolds.shared.held(need, in: store) }
    /// **Undo stands at the end of the folded card's line while his answer waits, where the mark will stand**
    /// (`undoOnLine`; his yes of 21 November 2026), in a chat too, for an answer given on that chat's page: the owner,
    /// 26 November 2026, of the badge at the foot of the sidebar: "it is very far from where I clicked, it should be
    /// somewhere in the same area where I just clicked the card". The sidebar's badge shows that answer only on another
    /// page (`AnswerBadge.inSidebar`). **An answer has its one Undo where he gave it**, on every surface of the card (a
    /// review of 26 November 2026): one given elsewhere stands folded here with its check, and its Undo is the
    /// sidebar's badge, the card's own window or the card where he gave it. The place of this card is the one that its
    /// answers take (`NeedAnswerBox.holdPlace`): a chat's page, the card's own window, else a card on no page (the
    /// job's detail card).
    @Environment(\.cardOnPage) private var onPage
    private var undoOnLine: Bool {
        guard let holding else { return false }
        let here: AnswerHolds.Place = onPage ? .page(store.destination.page) : cardWindow != nil ? .window : .card
        return holding.place == here
    }
    /// The task that his answer let go on, where the reading has it (owner feature `need_marks`).
    private var answeredTask: FleetTask? { store.answered(need).task }
    /// **The turning mark, the orange mark and the gray mark of his pause open the task** (his "Both (Recommended)",
    /// "Yes, open task" and "Gray pause, as the row", 21 November 2026): its panel, with Resume, Stop and the guidance
    /// box. The check and the red mark open nothing.
    private var markOpensTask: Bool {
        guard holding == nil, onItsWay == nil, answeredTask != nil else { return false }
        switch store.answered(need).mark {
        case .working(_, let agent?, _): return !agent.isEmpty
        case .attention, .paused: return true
        default: return false
        }
    }
    /// **Pause at the end of the answer line while the task works** (his "Both (Recommended)"): the Pause of the task's
    /// panel (`TaskHoldControls`), on a task that the hub can pause and that no hold holds. After it the mark is the
    /// orange paused mark of the task's row, and Pause goes.
    private var pausable: FleetTask? {
        guard markOpensTask, case .working = store.answered(need).mark, let task = answeredTask,
              TaskHoldControls.shows(task, in: store.state),
              !(store.state?.holds?.contains { $0.task == task.id && $0.state != "released" } ?? false) else { return nil }
        return task
    }

    /// What it needs from him. A secret request's is the hub's one sentence about its form, which is right below it, and
    /// an item that carries its grant has none: Give is its step (`OwnerNeed.give`).
    private var todo: String { need.asksForSecret || need.give != nil ? "" : need.todo }
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
        return givenWords.isEmpty ? String(l10n: "Answered") : givenWords
    }
    /// What VoiceOver reads of his answer on the folded card: the words that it shows (`HisAnswer.spoken`).
    private func spokenAnswer(names: CardNames?) -> String {
        guard ranAnswer == nil, !need.answeredWithKey, !givenWords.isEmpty else { return answerWords }
        return HisAnswer.spoken(givenWords, inWords: typed, names: names)
    }
    /// His answer is words that he typed (`HisAnswer.typed`), which keep a role as he wrote it.
    private var typed: Bool { HisAnswer.typed(need, givenWords, inWords: inWords) }
    /// The words of his answer, on their way or as the reading has them, or "" for an answer of files alone.
    private var givenWords: String {
        (onItsWay?.text ?? need.answer)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                let names = need.answeredWithKey || ranAnswer != nil ? nil : store.cardNames(for: need)
                let files = store.answerFiles(of: need)
                VStack(alignment: .leading, spacing: 0) {
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded = true } } label: {
                        folded(names: names).padding(FormMetrics.rowInset)
                            .padding(.bottom, files.isEmpty ? 0 : 8 - FormMetrics.rowInset)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                        // **The whole folded card is the press, and shows it** (the area of Needs-you, 20 November
                        // 2026, from the owner: "if I click on it it expands magically because there is no hint at
                        // all"): the hand, a soft fill and its chevron in the words' colour under the pointer
                        .buttonStyle(CardFoldStyle(fill: files.isEmpty ? .whole : .top))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(need.shownTitle), answered: \(spokenAnswer(names: names))"))
                        .accessibilityValue(foldedMarkWords)
                        .accessibilityHint("Shows the whole request")
                        .accessibilityActions {
                            if holding != nil { Button("Undo") { undo() } }
                            if pausable != nil { Button("Pause") { pause() } }
                            if markOpensTask { Button("Open the task") { openTask() } }
                        }
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
        // in its own window, the window's ground is the card's fill, and the card draws none and no edge
        .background(cardWindow == nil ? FleetStyle.surface : .clear, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        // **The edge of every card of a form** (fix round 3, item 58; T-41): with Increase Contrast a one-point edge that
        // reads 4:1, where the request card had none (1.11:1).
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
            .strokeBorder(cardWindow == nil ? FleetStyle.hairline(0.08) : .clear, lineWidth: FleetStyle.edgeWidth(contrast)))
        // Owner feature attachments: a file dropped anywhere on an open request is staged in its answer, as a
        // file dropped anywhere in a conversation is staged in that chat's composer.
        .stageDroppedFiles(store: store,
                           composer: need.isOpen && need.takesFiles ? FleetStore.stageKey(need: need.id) : nil,
                           mark: true)
        .frame(maxWidth: measure ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        // a name in its words opens its page in this window (`FleetStore.openCardLink`); from the card's own window, in
        // the main window, which comes to the front (`NeedWindowLink.open`)
        .environment(\.openURL, OpenURLAction { cardWindow?.open($0) ?? store.openCardLink($0) })
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
        // its own window closes once the hub has his answer and no save holds the card (`NeedWindowEnd`)
        .onChange(of: keySave, initial: true) { _, now in cardWindow?.card(keySave: now) }
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

    /// **What VoiceOver reads of the folded card's mark** (`AnsweredMarkView`), after its title and his answer: the
    /// button reads none of its children, so the mark's words are its value. Empty where no mark stands: a written
    /// answer, the key card, the Run card, and an answer on its way.
    private var foldedMarkWords: String {
        guard !need.answeredWithKey, ranAnswer == nil, !inWords, onItsWay == nil else { return "" }
        return store.answered(need).mark.words
    }

    /// What a press of Run answered (owner feature `need_run`), or nil.
    private var ranAnswer: NeedRunAnswer? { NeedRunAnswer.of(need, onItsWay: onItsWay) }

    /// The folded card of an answered request: its title, medium (`titleFont`), with the down chevron at the end of its
    /// line, and what he answered under it. **Words that he wrote take the chat's look, 8 points under the title, and a
    /// long answer folds to six lines** (`FoldedWords`; the area of Needs-you, 20 November 2026, from the owner: "that
    /// wall of small text is unreadable"): they stood whole at 12 points muted. The option that he pressed keeps its
    /// check and its line of 12 points muted, and a press of Run its mark. Each name in his answer is its badge (his
    /// "use always the agent badges and icons!!"). **A request that a saved key answered is one line**: its title, the
    /// check where the check of his save drew itself (`keyHead`), and the chevron.
    @ViewBuilder private func folded(names: CardNames?) -> some View {
        if need.answeredWithKey {
            keyHead(saved: true, draws: false, folded: true)
        } else {
            let written = ranAnswer == nil && inWords ? givenWords : ""
            VStack(alignment: .leading, spacing: written.isEmpty ? 4 : 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(heading).font(titleFont).foregroundStyle(FleetStyle.text).lineLimit(1)
                    Spacer(minLength: 0)
                    FoldChevron(opens: true)
                }
                if let ran = ranAnswer {
                    // a press of Run: its mark says how the command ended, "Ran on <Mac>" where it ran
                    HStack(spacing: 5) {
                        Image(systemName: ran.symbol).font(IconMetrics.symbol(10, weight: .semibold)).accessibilityHidden(true)
                        Text(ran.words).lineLimit(1)
                    }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                } else if !written.isEmpty {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        FoldedWords(words: written, names: names, typed: typed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        lineEnd.font(FormMetrics.detail)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        // owner feature need_marks: what came of his answer, in the check's place (`AnsweredMarkView`)
                        if !inWords && !undoOnLine {
                            AnsweredMarkView(mark: onItsWay == nil ? store.answered(need).mark : nil,
                                             moves: store.marksMove, names: names,
                                             opens: markOpensTask ? { openTask() } : nil)
                        }
                        CardBadgeText.text(HisAnswer.words(answerWords, inWords: typed), names: names,
                                           size: FormMetrics.detailSize)
                            .lineLimit(1).tint(FleetStyle.link)
                        lineEnd
                    }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .cardBadges()
                }
            }
        }
    }

    /// **The end of the folded card's answer line**: Undo while his answer waits, in a chat, in the card's own window and
    /// on the job's detail card (`undoOnLine`; his "Yes, 5 seconds": "Undo at the end of its answer line", with no words
    /// beside it and no count), else Pause while the task works. Each is its own press inside the folded card's, which opens
    /// nothing. VoiceOver's action Undo stays on the folded card wherever it stands.
    @ViewBuilder private var lineEnd: some View {
        if undoOnLine {
            Spacer(minLength: 8)
            Button("Undo") { undo() }
                .buttonStyle(.plain).font(FormMetrics.detail.weight(.medium)).foregroundStyle(FleetStyle.link)
                .pointerStyle(.link)
                .accessibilityIdentifier("need-undo-\(need.id)")
        } else if pausable != nil {
            Spacer(minLength: 8)
            // the task panel's Pause, at the size of the line, so the card keeps its height when it comes and goes, and
            // its press reaches nothing of the title's line over it (review)
            IconButton(symbol: "pause", words: String(l10n: "Pause"), size: 10, side: 20, tint: FleetStyle.text) { pause() }
                .disabled(!store.canWrite)
                .accessibilityIdentifier("need-pause-\(need.id)")
        }
    }

    /// Undo: his answer goes nowhere, and the card opens as it was (`AnswerHolds.undo`); on Needs you it comes to hand
    /// again.
    private func undo() {
        AnswerHolds.shared.undo(need, store: store)
        if store.destination == .needs { store.selectedNeed = need.id }
    }

    /// The task's Pause, as its panel sends it (`TaskHoldControls`).
    private func pause() {
        guard let task = pausable else { return }
        Task { await store.command(.control(task: task.id, action: .pause)) }
    }

    /// The task opens as a task opens from a link of the app (`showLinked`); from the card's own window the main window
    /// comes to the front with it (`NeedWindowLink.showMainWindow`).
    private func openTask() {
        guard let task = answeredTask else { return }
        store.showLinked(.task(task.id))
        cardWindow?.showMainWindow()
    }

    /// **The key's name in the title of a request for its new value is the key's badge** (the owner's "Yes, both" of 21
    /// November 2026 to its drawing, "New value for DOOR_BACKBLAZE_ACME_KEY"), and no other card's title has badges
    /// (the area Needs-you and the manager): a press opens the key's own card over the page, as the badge in the words
    /// does (`FleetStore.openCardLink`). Only where one secret of the list has that name (`cardSecrets`), so the badge
    /// always opens a card, and only where that one secret is the key that the request replaces: a key of the same name
    /// made after the old one went is another key (review); else the title is its words.
    private var titleKey: (name: String, key: Bool)? {
        guard let asked = need.secret, let replaced = asked.replaces, let name = asked.env, !name.isEmpty,
              SecretEntryView.isOffered(by: store), let kept: LoginReading = store.reading("secrets.logins.fleet"),
              SecretsList.reference(named: name, in: kept.catalog) == replaced,
              let entry = kept.catalog[replaced] else { return nil }
        return (name, entry.isAPIKey)
    }
    private var titleNames: CardNames? { titleKey.map { CardNames(agents: [], secrets: [$0]) } }

    /// **A Replace card reads the secrets list once where the kept list lacks the key that it replaces** (Fable's read
    /// of 22 November 2026): the store reads the list once a launch (`PageReadings.prefetch`), so a key that the fleet
    /// took after that read, as on the morning of his drawing, had no badge in the title until Settings › Secrets
    /// opened. One read for each request a launch (`keyListReads`), through the store's one read of that reading
    /// (`FleetStore.read`), and kept only while the hub and its generation stay and while no newer list came meanwhile
    /// (Settings › Secrets, another card). A read that fails, or that a card's leave cut off, changes nothing and may
    /// come again. The same read gives the card's words their badge of that key (`CardLinks`).
    private func readKeyList() async {
        guard need.isOpen, let replaced = need.secret?.replaces, SecretEntryView.isOffered(by: store),
              let database = store.state?.db else { return }
        let name = "secrets.logins.fleet", hub = store.hub
        let kept: LoginReading? = store.reading(name)
        let once = "\(hub.absoluteString)\n\(database)\n\(replaced)"
        guard kept?.catalog[replaced] == nil, Self.keyListReads.insert(once).inserted else { return }
        let before = store.readingKept(name), reader = SecretsPage.prefetch.read
        // (`prefetch.read` gives any reading; this one is the list's)
        let list = try? await store.read(name) { () async throws -> LoginReading? in
            try await reader(hub, database, "") as? LoginReading
        }
        // a read that a card's leave cut off, or that failed, may come again at the card's next appearance
        guard let list, !Task.isCancelled else { Self.keyListReads.remove(once); return }
        guard store.hub == hub, store.state?.db == database, store.readingKept(name) == before else { return }
        store.keep(list, as: name)
    }

    /// The requests whose card read the secrets list for its key, by hub, generation and reference (`readKeyList`).
    @MainActor private static var keyListReads: Set<String> = []

    /// The card's title: its words, with the key's badge on a request for a key's new value (`titleNames`) where
    /// `badges`. The badge's look and press come from `cardBadges` on the view around it, which stands over the title's
    /// own press (its fold), so the badge takes its press and the rest of the title keeps its own.
    @ViewBuilder private func titleWords(badges: Bool) -> some View {
        if badges, let names = titleNames, let key = titleKey {
            // the badge's name in the link colour of every badge, not the window's accent (review)
            CardBadgeText.text(Self.marked(key.name, in: heading), names: names, size: ChatStyle.size).font(titleFont)
                .tint(FleetStyle.link)
        } else {
            Text(heading).font(titleFont)
        }
    }

    /// The title's words with the key's name as an inline code, its last place in them: **in this title the name is the
    /// hub's own word for the key** ("New value for {env}"), so a name of letters only (TOKEN) is a badge as one with a
    /// digit or an underscore is (`CardNames`, `wholeCode`), and VoiceOver's "Open TOKEN" has a badge to go with it
    /// (Fable's read of 22 November 2026). The badge's words lose the code's look (`CardBadgeText`).
    static func marked(_ name: String, in heading: String) -> AttributedString {
        var words = AttributedString(heading)
        if let range = words.range(of: name, options: .backwards) { words[range].inlinePresentationIntent = .code }
        return words
    }

    /// **A key request's card while his save runs, and folded once a saved key answered it**: its title and the mark at
    /// its end (`KeySaveMark`), with no words. The two stand alike to the point, so the folded card takes the place of
    /// the card whose check has drawn itself with no change on the screen. **The folded card's chevron stands after the
    /// check** (`FoldChevron`), at the end of the line as on every folded card; while his save runs its room is there
    /// and empty, so the check does not move when the folded card takes the card's place.
    private func keyHead(saved: Bool, draws: Bool, folded: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 8) {
            // words, with no badge: the folded card takes this one's place with no change on the screen (review), and the
            // badge goes with the card's collapse as his save begins
            titleWords(badges: false).foregroundStyle(FleetStyle.text).lineLimit(1)
            Spacer(minLength: 8)
            KeySaveMark(saved: saved, draws: draws)
            FoldChevron(opens: true).opacity(folded ? 1 : 0)
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
                        VStack(alignment: .leading, spacing: 8) {
                            // owner feature need_clarify: **his talk with the manager over the key's form**, as the answer
                            // box draws it over its answers (`NeedAnswerBox`), and as Needs you draws it over every
                            // request's answers: a key request that took another's place carries his question
                            let talk = need.isOpen ? need.shownTalk(features: store.state?.ui_features) : []
                            if !talk.isEmpty {
                                NeedTalkLines(talk: talk, font: FormMetrics.text)
                                    // his bubble ends where the form under it ends (`SecretFormWidth`)
                                    .frame(maxWidth: formWidth ?? SecretEntryView.width(of: need, onStep: false),
                                           alignment: .leading)
                                    .padding(.bottom, 2)
                            }
                            SecretRequestForm(store: store, need: need, onLook: { took($0) }) {
                                withAnimation(reduceMotion ? nil : FleetMotion.keySave) { keySave.end() }
                            }
                        }
                        .onPreferenceChange(SecretFormWidth.self) { width in if let width { formWidth = width } }
                        // the request's note shows only with Details open (`requestNoteShows`)
                        .environment(\.requestNoteShows, expanded)
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
        let names = store.cardNames(for: need)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline) {
                        titleWords(badges: true).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        // No orange "Needs you" on a request that waits (D-2): every open request needs him. **One
                        // opened again has the up chevron where the folded card has its down one** (the owner, 20
                        // November 2026: "To collapse it, only when I click on Answered... again no hint"): the word
                        // "Answered" stood there, and VoiceOver still says it
                        if !need.isOpen { FoldChevron(opens: false) }
                    }.padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                }
                    // the hand on the title's row, which folds the card or opens its long part, before the padding
                    // that gives its reach back to the layout
                    .buttonStyle(CardFoldStyle())
                    // the key badge's press for VoiceOver, which reaches the title as the button's words (review), on the
                    // button alone (Fable's read of 22 November 2026)
                    .accessibilityActions {
                        if let key = titleKey, let url = CardNames.Target.secret(key.name, key: key.key).url {
                            Button(String(l10n: "Open \(key.name)")) { _ = cardWindow?.open(url) ?? store.openCardLink(url) }
                        }
                    }
                    .accessibilityValue(need.isOpen ? "" : String(l10n: "Answered"))
                    // the key's badge in a Replace card's title, over the title's own press (`titleWords`)
                    .cardBadges(titleNames != nil, links: false)
                    .padding(.vertical, -IconMetrics.reach)
                    // a key that the fleet took after the app's read of the list (`readKeyList`)
                    .task(id: need.secret?.replaces) { await readKeyList() }
                // owner feature need_takeover (the owner's "Yes, as drawn"): Take over at the right of the title, beside
                // the title's own button and not in it, so that each press does one thing
                if let way = takeOverWay {
                    NeedTakeOverButton(need: need.id, connection: way) {
                        // the take-over card over the main window, also from the request's own window
                        Task { await store.takeOver(need, from: cardWindow) }
                    }
                }
                // **Open in its own window** (the owner's "Yes, as drawn" of 21 November 2026): on an open card whose
                // answer is not on its way, at the end of the title's line, after Take over; never in the window itself
                if need.isOpen, onItsWay == nil, cardWindow == nil {
                    IconButton(symbol: "rectangle.inset.topright.filled", words: String(l10n: "Open in its own window"),
                               size: 12, side: IconMetrics.small) { NeedWindows.open(store: store, need: need) }
                        // its middle on the title's capitals, and no room of its own over and under the title's line
                        .padding(.vertical, -3)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                        .accessibilityIdentifier("need-window-\(need.id)")
                }
            }

            // The reason and the task are two parts of one message: a message's room between them. A take-over has
            // neither: its title is its step.
            if !need.why.isEmpty || !task.isEmpty {
                VStack(alignment: .leading, spacing: ChatStyle.blockSpacing) {
                    if expanded || short {
                        MessageText(text: need.why, chat: true, card: true, names: names, values: true)
                    } else {
                        // **An older long card folds to three lines** (the owner, 9 November 2026: "MUCH better so they
                        // are shorter"): the start of its reason, until Show all opens the rest.
                        CardBadgeText.reason(need.why, names: names, size: ChatStyle.size)
                            .font(ChatStyle.font).lineSpacing(ChatStyle.lineSpacing).tint(FleetStyle.link)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            .cardBadges()
                    }
                    // owner feature need_run: the block of its command has Run (the owner's "Yes, as drawn")
                    if !task.isEmpty {
                        MessageText(text: task, chat: true, card: true, run: NeedRunTarget.of(need, store: store),
                                    names: names, values: true)
                        CardPageButton(store: store, need: need, names: names, task: task)
                    }
                }
            }
            // **The link stands where he pressed it, and what it opens comes under it**, as on Needs you
            // (`NeedStep`; the owner, 20 November 2026: "The Details link seems to be positioned incorrectly"):
            // the details came in over it, and the link went down under them.
            if hasMore {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            // the door's card shows its script there, as the owner approved it ("Yes, as shown")
                            Text(need.details != nil ? (need.door_host != nil ? "Script" : "Details")
                                 : expanded ? "Show less" : "Show all")
                            if need.details != nil {
                                // down while a press opens in place, up while it folds: a right chevron would say
                                // another page (the owner, 20 November 2026: "taht chevron looks like gooing to a
                                // different page, not Expand")
                                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(IconMetrics.symbol(9, weight: .semibold))
                            }
                        }.padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        // the hand under the pointer, as a link shows it (`NeedStep.moreLink` too), over all that a
                        // click reaches: before the padding that gives the reach back to the layout
                        .pointerStyle(.link)
                        .padding(.vertical, -IconMetrics.reach).font(FormMetrics.detail).foregroundStyle(FleetStyle.link)
                        // whether what it opens is open, as Needs you's link says it (`NeedStep.moreLink`)
                        .accessibilityValue(expanded ? String(localized: "Open (a state)", defaultValue: "Open",
                                                              bundle: Localized.bundle, locale: Localized.digits)
                                            : String(l10n: "Closed"))
                        .accessibilityIdentifier("need-more-\(need.id)")
                    Spacer(minLength: 8)
                }
            }
            if expanded, let details = need.details {
                // **The door's card shows its script line for line** (API 1.125, review point 5.6): one code block, as
                // the request at hand on Needs you draws it, which this Mac hashes before it signs Run it once
                // (`DoorCall.checked`).
                MessageText(text: details, chat: true, script: need.door_script != nil, card: true,
                            names: need.door_script != nil ? nil : names, values: need.door_script == nil)
            }
            if expanded, !todo.isEmpty, task.isEmpty {
                Text("What it needs from you").font(FormMetrics.detailTitle)
                    .foregroundStyle(FleetStyle.muted).padding(.top, 2)
                MessageText(text: todo, chat: true, card: true, names: names, values: true)
            }
            // owner feature need_clarify: **an answered card keeps his talk with the manager, read only**, before his
            // answer as it came (the area of Needs-you, 20 November 2026: "the talk stands in the card" holds after his
            // answer too); an open card has it over its answers (`NeedAnswerBox`)
            if !need.isOpen {
                let talk = need.shownTalk(features: store.state?.ui_features)
                if !talk.isEmpty { NeedTalkLines(talk: talk, font: FormMetrics.text) }
            }
            NeedAnswerGiven(store: store, need: need, names: names)
            // Who asks, by the name the sidebar gives it and its glyph before it (D-8), and when: a clock time today
            // (T-12). **Copy prompt at the right end of the line** (the owner's "Yes, as drawn" of 21 November 2026), on
            // a request with steps for him outside the app while no answer of his is on its way (`NeedPrompt.offers`);
            // every other card keeps its line as it was.
            if NeedPrompt.offers(need) && onItsWay == nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    fromLine
                    Spacer(minLength: 8)
                    NeedPromptButton(need: need)
                }
            } else {
                fromLine
            }
        }
    }

    /// Who asks and when, in the card's last line.
    private var fromLine: some View {
        AgentNamed(agent: need.by) {
            Text("From \(need.by.agentLabel) · \(messageTime(need.raised))")
        }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
    }

}

/// **Needs clarification on Needs you** (the request at hand, a key request's card as every other one; the owner's answer
/// of 23 November 2026 to how it looks at rest: "The violet of Details, with the hand"): the words in the place and at
/// the size of the quiet grey link that it was (`SetupLink`), in the colour of Details (`FleetStyle.link`), so that it
/// reads as a link like Details on the same card, with the hand under the pointer while it can be pressed, over all that
/// a click reaches. A card in a chat keeps its own look.
struct StepClarifyLink: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // The click reaches over and under the words (`IconMetrics.reach`), and the step does not move for it.
        Button(action: action) {
            Text(String(l10n: "Needs clarification")).padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .pointerStyle(isEnabled ? .link : nil)
            .padding(.vertical, -IconMetrics.reach).font(SetupMetrics.textFont)
            // while it cannot be pressed (a save, a reading that is not current), its muted words of before: the violet
            // says that a press goes
            .foregroundStyle(isEnabled ? FleetStyle.link : FleetStyle.muted)
    }
}

extension EnvironmentValues {
    /// The pointer is over a press that opens or folds in place (`CardFoldStyle`): its chevron takes the words' colour
    /// (`FoldChevron`).
    @Entry var cardFoldHovered = false
}

/// **The press that opens a folded request card, or folds an opened one** (the area of Needs-you, 20 November 2026,
/// from the owner: "if I click on it it expands magically because there is no hint at all"): the hand under the
/// pointer, and the chevron of the card's title line in the words' colour while the pointer is over the press
/// (`FoldChevron`). The folded card is the press whole, with the soft fill of a row that opens (`FleetRowButtonStyle`)
/// in the card's own corners: only its top ones where the files of his answer stand under it, in the card. The title's
/// row of an opened card takes no fill. **The lines of a key form's Who can use it are such a press too**
/// (`SecretEntryView.accessFold`), at the top of their card while its rows are open. A save of the form disables them:
/// then no hand, no fill and no light in the chevron.
struct CardFoldStyle: ButtonStyle {
    enum Fill { case off, whole, top }
    var fill = Fill.off

    func makeBody(configuration: Configuration) -> some View { Press(configuration: configuration, fill: fill) }

    private struct Press: View {
        let configuration: ButtonStyleConfiguration
        let fill: Fill
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let lit = hovered && isEnabled
            configuration.label
                .environment(\.cardFoldHovered, lit)
                .background {
                    if fill != .off {
                        let corner = FormMetrics.radius, under = fill == .whole ? corner : 0
                        UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: under,
                                               bottomTrailingRadius: under, topTrailingRadius: corner)
                            .fill(Color.white.opacity(configuration.isPressed ? FleetRowButtonStyle.pressFill
                                                      : lit ? FleetRowButtonStyle.hoverFill : 0))
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .pointerStyle(isEnabled ? .link : nil)
        }
    }
}

/// **The chevron at the end of a line that opens in place**, a request card's title line and the last line of a key
/// form's Who can use it (`SecretEntryView`): down while a press opens, and up while a press folds (the owner, 20 November
/// 2026, of a chevron that pointed right: "taht chevron looks like gooing to a different page, not Expand"). Muted, in
/// the words' colour under the pointer (`CardFoldStyle`).
struct FoldChevron: View {
    /// Folded, a press opens: down. Open, a press folds: up.
    let opens: Bool
    @Environment(\.cardFoldHovered) private var hovered

    var body: some View {
        Image(systemName: opens ? "chevron.down" : "chevron.up")
            .font(IconMetrics.symbol(11, weight: .semibold))
            .foregroundStyle(hovered ? FleetStyle.text : FleetStyle.muted)
            .accessibilityHidden(true)
    }
}

/// **His own words on a folded request card** (the area of Needs-you, 20 November 2026, from the owner: "that wall of
/// small text is unreadable"): the chat's look (14 points in the words' colour, with its line spacing), each name that
/// the card links as its badge (`CardBadgeText`; his "use always the agent badges and icons!!"), a role as he wrote it
/// (`HisAnswer`), and a long answer folds to six lines whose last fades, as a long message of his does (`OwnerBubble`).
/// A click opens the card, which shows the words whole under "Your answer". **The six lines are a limit of the text,
/// not a frame over it**: a frame would keep the press of a badge under the fold, over the chat's next rows, because a
/// badge's press stands on every line of the text's layout (`CardBadge.parts`).
private struct FoldedWords: View {
    let words: String
    let names: CardNames?
    /// The words are his own (`HisAnswer.typed`), not the hub's or an agent's end of the item.
    let typed: Bool
    /// The height of the words whole, and of the lines that show: the last line fades only where words are cut.
    @State private var whole: CGFloat = 0
    @State private var shown: CGFloat = 0
    static let lines = 6

    var body: some View {
        let text = CardBadgeText.text(HisAnswer.words(words, inWords: typed), names: names, size: ChatStyle.size)
        let cut = whole > shown + 1
        look(text).lineLimit(Self.lines)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shown = $0 }
            .cardBadges()
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    if cut {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: ChatStyle.line)
                    }
                }
            }
            // the words whole and unseen, for their height alone: their layout reaches no badge and no link
            .background(alignment: .top) {
                look(text).lineLimit(nil).hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { whole = $0 }
                    .transformPreference(Text.LayoutKey.self) { $0 = [] }
            }
    }

    private func look(_ text: Text) -> some View {
        text.font(ChatStyle.font).lineSpacing(ChatStyle.lineSpacing).foregroundStyle(FleetStyle.text).tint(FleetStyle.link)
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
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
    /// one view with or without it, so a reading that brings the badge keeps the row's own state. `makesRoom` false:
    /// the row's line makes that room for each of its options (`pictureOptions`), so they stand at one height.
    func recommendedBadge(by agent: String?, ground: Color, inset: CGFloat = RecommendedBadge.inset,
                          makesRoom: Bool = true) -> some View {
        overlay(alignment: .topTrailing) {
            // The guide stands on a view that is always there: on the badge inside the `if`, the overlay did not read
            // it, and the badge hung inside the row.
            ZStack {
                if let agent { RecommendedBadge(agent: agent, ground: ground) }
            }
            .alignmentGuide(.top) { $0[VerticalAlignment.center] }
            .padding(.trailing, inset)
        }
        .padding(.top, agent == nil || !makesRoom ? 0 : RecommendedBadge.room)
    }
}
