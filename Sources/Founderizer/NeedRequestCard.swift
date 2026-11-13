import AppKit
import FleetCore
import SwiftUI

/// What an agent asks the owner, on the request's card in a chat (`NeedRequestCard`), read as blocks: lines run
/// together into a paragraph, and a line that begins with a number or a dash becomes a row of its own, so a list of
/// steps reads as a list and not as a wall. Its words are a message's 14 points. The request at hand on Needs you
/// draws the same words as a message does (`NeedStep`, `MessageText`).
struct NeedBody: View {
    let text: String
    /// How many blocks to show; nil shows every one.
    var limit: Int?
    /// The most lines of each block, for a folded card whose one paragraph is long; nil shows every line.
    var lines: Int?

    struct Block: Identifiable { let id: Int; let marker: String?; let text: String }

    static func blocks(of text: String) -> [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let found = marker(of: line) {
                out.append(Block(id: out.count, marker: found.0, text: found.1))
            } else if let last = out.last, last.marker == nil {
                out[out.count - 1] = Block(id: last.id, marker: nil, text: last.text + " " + line)
            } else {
                out.append(Block(id: out.count, marker: nil, text: line))
            }
        }
        return out
    }

    /// "1." or "2)" or "-" at the start of a line, and what follows it.
    private static func marker(of line: String) -> (String, String)? {
        if let first = line.first, "-•*".contains(first), line.count > 2, Array(line)[1] == " " {
            return ("•", String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        return (String(digits) + ".", rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        let shown = limit.map { Array(Self.blocks(of: text).prefix($0)) } ?? Self.blocks(of: text)
        let spacing: CGFloat = 3
        // **Its words in the size of the place it stands in** (fix round 2): a message's 14 in a chat; they took the
        // page's 12.5, a size of their own beside the chat's 14.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shown) { block in
                if let marker = block.marker {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).font(ChatStyle.title)
                            .foregroundStyle(FleetStyle.muted).frame(minWidth: 18, alignment: .trailing)
                        Text(block.text).lineSpacing(spacing).textSelection(.enabled).lineLimit(lines)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(block.text).lineSpacing(spacing).textSelection(.enabled).lineLimit(lines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.font(ChatStyle.font)
    }
}

/// One offered answer, as a target: a row that lifts under the pointer and dims on the press. **Neutral grey** (the
/// owner's yes of 28 October 2026, D-8): it was violet, the colour that now has one job — a link, the focus, the
/// selected tab and the brand's mark — and the rows of a request read as a list of choices without it.
struct NeedOptionButtonStyle: ButtonStyle {
    /// A number key marked this option, on the request at hand (`NeedAnswerBox`): it is lit as under the pointer, **with
    /// the violet edge of the keyboard's focus**, as a field that has the cursor, and Return presses it. Lit alone, it
    /// looked the same as the row under the pointer, and two rows were lit when the pointer stood on another one.
    var marked = false

    func makeBody(configuration: Configuration) -> some View { OptionRow(configuration: configuration, marked: marked) }

    private struct OptionRow: View {
        let configuration: ButtonStyleConfiguration
        let marked: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        private var lit: Bool { (hovered || marked) && isEnabled }

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .fill(Color.white.opacity(lit ? 0.09 : 0.05))
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
                        .strokeBorder(marked && isEnabled ? FleetStyle.accent : FleetStyle.hairline(lit ? 0.18 : 0.10),
                                      lineWidth: marked && isEnabled ? 1 : FleetStyle.edgeWidth(contrast))))
                .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.55)
                .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
                .onHover { hovered = $0 }
        }
    }
}

/// The answer to one request, where the request is: a quick reply to start from, a box that sends on Return,
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

    /// Three answers that fit almost every request. They fill the box, and the owner sends or edits first. They
    /// are the fallback: an item that offers its own options (API 1.18) shows those instead, and pressing one of
    /// those sends it, because the agent asked for exactly that answer.
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
    private func row(_ words: String, sendingSince: ContinuousClock.Instant? = nil) -> some View {
        HStack(spacing: 8) {
            Text(words).font(self.words).foregroundStyle(FleetStyle.text)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let since = sendingSince { Held(since: since) { SendingWords() } }
        }
        .padding(.horizontal, onStep ? 14 : 12).padding(.vertical, onStep ? 11 : 10)
        .frame(minHeight: onStep ? FormMetrics.row : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if need.choices.isEmpty {
                // **One look for an answer option** (T-22): the app's own three replies are rows like the ones an
                // agent offers, though they only fill the box below and the owner sends or edits first. A page showed
                // 24-pt dark chips under one request and 36-pt violet rows under the next.
                VStack(alignment: .leading, spacing: onStep ? 8 : 7) {
                    ForEach(Self.quickReplies, id: \.self) { reply in
                        Button {
                            // Not from the second click of a double-click: it would fill the next request's box with
                            // words that one Return sends (`SecondClick`).
                            guard !(onStep && SecondClick.isNow) else { return }
                            if trimmed.isEmpty { text.wrappedValue = reply }
                            focused = true
                        } label: { row(reply) }
                            .buttonStyle(NeedOptionButtonStyle()).accessibilityIdentifier("quick-\(reply.lowercased())-\(need.id)")
                    }
                }
            } else if need.combines {
                // **Options that combine** (the owner's yes of 9 November 2026): a tick at the right of each row, and one
                // Send with how many he ticked; it stays off while none is ticked.
                VStack(alignment: .leading, spacing: onStep ? 8 : 7) {
                    ForEach(Array(need.choices.enumerated()), id: \.offset) { index, option in
                        HStack(spacing: 8) {
                            Text(option).font(words).foregroundStyle(FleetStyle.text)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: Binding(get: { ticked.contains(index) }, set: { on in
                                if on { ticked.insert(index) } else { ticked.remove(index) }
                            })).labelsHidden().toggleStyle(FleetCheckboxStyle()).accessibilityLabel(option)
                        }
                        .padding(.leading, onStep ? 14 : 12).padding(.trailing, onStep ? 10 : 6).padding(.vertical, 4)
                        .frame(minHeight: onStep ? FormMetrics.row : nil)
                        .background(RoundedRectangle(cornerRadius: FormMetrics.inner).fill(Color.white.opacity(0.05)))
                        .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
                        .onTapGesture { if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) } }
                        .accessibilityIdentifier("need-tick-\(need.id)-\(index)")
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
                        Button {
                            guard !(onStep && SecondClick.isNow) else { return }
                            marked = nil
                            answered?(false, tops[index] ?? 0)
                            AnswerWaits.shared.press(need, choice: index, store: store)
                        } label: {
                            row(option, sendingSince: sending ? waiting?.since : nil)
                        }
                            .buttonStyle(NeedOptionButtonStyle(marked: marked == index))
                            .stands(in: Self.space, on: onStep) { tops[index] = $0 }
                            .accessibilityValue(sending ? "Sending" : "")
                            .accessibilityIdentifier("need-option-\(need.id)-\(index)")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion { Text("Sending…").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
            else { ShimmeringWords(text: "Sending…") }
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

/// What the owner answered: the words, and the files that went with them, because an answer may be files alone.
/// The files are the ones on the message that answered this request.
struct NeedAnswerGiven: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed

    private var files: [MessageAttachment] {
        store.state?.messages.last { $0.need_id == need.id }?.attachments ?? []
    }

    var body: some View {
        let answer = need.answer ?? ""
        if !answer.isEmpty || !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if answer.isEmpty {
                    Text("Your answer").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                } else {
                    DetailField(title: "Your answer", value: answer)
                }
                if !files.isEmpty { MessageFilesView(store: store, files: files, alignment: .leading) }
            }
        }
    }
}

/// One request in the chat of the agent that asked it (D-7): the title, the first lines of it, and its answer where it
/// is read. The rest opens with one click, so a long request does not fill the column. On Needs you the same request
/// is a card of the lane and the request at hand (`NeedsBoard`), which share its answers (`NeedAnswerBox`), its secure
/// form and its discussion (`NeedDiscussion`).
///
/// **An answered request folds to two lines** (the owner's yes of 28 October 2026, D-7): its title and "✓ Correos",
/// the rest on a click, as Grok Bot folds a question card it answered. An answered one took as much room as an open
/// one.
struct NeedRequestCard: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    @State private var expanded = false
    /// Owner feature `need_talk` (API 1.106): Discuss is open, and the words of his next message in it.
    @State private var discussing = false
    /// His answer as the outbox saved it, kept from the frame it went until the reading says the request is answered
    /// (`WordsOnTheirWay`): the store lets the request go with its receipt, a round trip before that reading.
    @State private var sent: PendingRequest?
    /// The width of a form page's cards, where the card stands on one; in a chat, nil, and the card takes the column's.
    @Environment(\.formMeasure) private var measure
    @Environment(\.colorSchemeContrast) private var contrast

    /// **His answer on its way: the card folds in the frame he sends it, with his words** (fix round 3, item 11), as it
    /// folds once the reading says it is answered. It folded only with that reading, a round trip after the hub's
    /// receipt.
    private var onItsWay: PendingRequest? { store.answerOnItsWay(to: need, kept: sent) }

    /// What it needs from him. A secret request's is the hub's one sentence about its form, which is right below it.
    private var todo: String { need.asksForSecret ? "" : need.todo }

    private var hasMore: Bool {
        need.details != nil || !short || !todo.isEmpty
    }
    /// **A short card** (the owner's yes of 9 November 2026): an item from a hub with `need_talk` has a why of one or two
    /// sentences, shown whole, and its long part behind Details. An older item keeps Show all.
    private var short: Bool { need.details != nil || need.why.count <= NeedTalk.why }
    /// Discuss, apart from his answer: an open item that is no conversation's question, on a hub that takes it.
    private var discussable: Bool {
        need.isOpen && need.conversation == nil && store.state?.ui_features?.contains(NeedTalk.feature) == true
    }
    private var talk: [NeedMessage] { need.talk ?? [] }
    /// The request's title, folded or whole, **without its number** (D-2, the owner's yes of 28 October 2026): "N-3" is
    /// the hub's bookkeeping, and the agents' own words name a request by what it asks.
    private var heading: String { need.title }
    /// **The card's words in the sizes of the chat it stands in** (fix round 2): its title and its body (`NeedBody`) take
    /// the chat's 14 points, the title medium; its small lines are 12, where they were 11 and 11.5, and its body took
    /// the page's 12.5: sizes of their own in the chat's column. Its option rows keep 13, the size of a button's words
    /// (D-8 item 10).
    private var titleFont: Font { ChatStyle.title }
    /// What he answered, in the folded card's second line: his words or the option he pressed.
    private var answerWords: String {
        let answer = (onItsWay?.text ?? need.answer)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return answer.isEmpty ? "Answered" : answer
    }

    var body: some View {
        Group {
            if (!need.isOpen || onItsWay != nil) && !expanded {
                Button { withAnimation(.easeInOut(duration: 0.12)) { expanded = true } } label: {
                    folded.padding(FormMetrics.rowInset).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(need.title), answered: \(answerWords)")
                    .accessibilityHint("Shows the whole request")
                    .accessibilityIdentifier("need-folded-\(need.id)")
            } else {
                // **A card's content 16 points in, folded and whole** (margins row 19), as the rows of every form card:
                // the request's title stood 2 points left of the form rows' titles on the same page.
                whole.padding(FormMetrics.rowInset)
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
        .onChange(of: store.pending?.requestID, initial: true) { _, _ in
            if let request = store.answerOnItsWay(to: need) { sent = request }
        }
    }

    /// The two lines of an answered request: its title, medium (`titleFont`), and what he answered with a check, 12
    /// points muted.
    private var folded: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(titleFont).foregroundStyle(FleetStyle.text).lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(IconMetrics.symbol(10, weight: .semibold))
                Text(answerWords).lineLimit(1)
            }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        }
    }

    private var whole: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(heading).font(titleFont).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    // No orange "Needs you" on a request that waits (D-2): every open request needs him. "Answered" stays,
                    // on one opened again.
                    if !need.isOpen { Text("Answered").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
                }.padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach)

            // **An older long card folds to three lines** (the owner, 9 November 2026: "MUCH better so they are shorter"):
            // its one long paragraph showed whole under the two-block fold. Show all opens the rest.
            NeedBody(text: need.why, limit: expanded || short ? nil : 1, lines: expanded || short ? nil : 3)
            if expanded, let details = need.details {
                // **The door's card shows its script line for line** (API 1.125, review point 5.6): one code block, as
                // the request at hand on Needs you draws it, which this Mac hashes before it signs Run it once
                // (`DoorCall.checked`). NeedBody joins lines into one paragraph, and two lines of a script are two
                // commands.
                if need.door_script != nil { MessageText(text: details, chat: true, script: true) } else { NeedBody(text: details) }
            }
            if expanded, !todo.isEmpty {
                Text("What it needs from you").font(FormMetrics.detailTitle)
                    .foregroundStyle(FleetStyle.muted).padding(.top, 2)
                NeedBody(text: todo)
            }
            if hasMore || discussable {
                HStack(spacing: 10) {
                    if hasMore {
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
                        }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).font(FormMetrics.detail).foregroundStyle(FleetStyle.link)
                            .accessibilityIdentifier("need-more-\(need.id)")
                    }
                    Spacer(minLength: 8)
                    if discussable && !discussing && talk.isEmpty {
                        Button { discussing = true } label: { Label("Discuss", systemImage: "bubble.left.and.bubble.right") }
                            .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("need-discuss-\(need.id)")
                    }
                }
            }
            if discussable && (discussing || !talk.isEmpty) { NeedDiscussion(store: store, need: need) }
            NeedAnswerGiven(store: store, need: need)
            // Who asks, by the name the sidebar gives it and its glyph before it (D-8), and when: a clock time today
            // (T-12).
            AgentNamed(agent: need.by) {
                Text("From \(need.by.agentLabel) · \(messageTime(need.raised))")
            }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            if need.isOpen {
                if need.asksForSecret { SecretRequestForm(store: store, need: need) }
                else { NeedAnswerBox(store: store, need: need) }
            }
        }
    }

}

/// **His discussion of one open request** (the owner's yes of 9 November 2026, "a button to clarify or to discuss"): his
/// messages in the chat's bubble, the replies as the chat draws an agent's words, and a field of its own. It is no
/// answer: the options and Your answer stay with it until he decides. It stands in the request's card in a chat, and
/// under the request at hand on Needs you (`NeedStep`), where its words take the step's size.
struct NeedDiscussion: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    /// The words of his next message where the page keeps them (`StepMemory`), so a look at another request does not
    /// lose them; nil in a chat's card, which keeps its own.
    var draft: Binding<String>? = nil
    @State private var own = ""
    @State private var talking = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.stepText) private var stepText

    private var talk: [NeedMessage] { need.talk ?? [] }
    private var words: Font { FormMetrics.onStep(stepText) ?? FormMetrics.text }
    private var message: Binding<String> { draft ?? $own }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(talk.enumerated()), id: \.offset) { _, line in
                if line.fromOwner {
                    Text(line.text).font(words).foregroundStyle(FleetStyle.text).textSelection(.enabled)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(ChatStyle.bubble, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(line.text).font(words).foregroundStyle(FleetStyle.text).textSelection(.enabled)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("\(line.who.agentLabel): \(line.text)")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(manager.agentLabel)", text: message, axis: .vertical)
                    .textFieldStyle(.plain).font(words).multilineTextAlignment(.leading)
                    .growingField(1...6, line: stepText == nil ? ChatStyle.line : 18)
                    .onSubmit { sendMessage() }
                    .accessibilityIdentifier("need-talk-field-\(need.id)")
                SendSlot(shows: canTalk) {
                    Button { sendMessage() } label: { SendMark() }
                        .buttonStyle(FleetIconButtonStyle(filled: true)).disabled(!canTalk)
                        .help("Send this message").accessibilityLabel("Send message")
                        .accessibilityIdentifier("need-talk-send-\(need.id)")
                }
            }.padding(8)
                .background(FleetStyle.composer, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .strokeBorder(FleetStyle.hairline(0.32), lineWidth: FleetStyle.edgeWidth(contrast)))
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
            .strokeBorder(FleetStyle.hairline(0.10), lineWidth: FleetStyle.edgeWidth(contrast)))
    }

    /// The agent that answers his discussion: the manager, which holds every Needs-you item.
    private var manager: String { store.state?.agents.first { $0.role == "manager" }?.name ?? "manager" }
    private var canTalk: Bool {
        let words = message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.canWrite && !talking && !words.isEmpty && words.count <= NeedTalk.most
    }

    private func sendMessage() {
        guard canTalk else { return }
        let words = message.wrappedValue
        talking = true
        Task {
            if await store.talk(need, text: words) { message.wrappedValue = "" }
            talking = false
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
}
