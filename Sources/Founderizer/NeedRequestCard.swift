import AppKit
import FleetCore
import SwiftUI

/// What an agent asks the owner, read as blocks: lines run together into a paragraph, and a line that begins
/// with a number or a dash becomes a row of its own, so a list of steps reads as a list and not as a wall.
struct NeedBody: View {
    let text: String
    /// How many blocks to show; nil shows every one.
    var limit: Int?
    /// The most lines of each block, for a folded card whose one paragraph is long; nil shows every line.
    var lines: Int?
    /// The window where the owner reads the whole request: larger text, with more space between its lines.
    var reading = false
    /// Its words on a card (`NeedRequestCard`) in a chat, at a message's 14; on Needs you a row's 13.
    var chat = false

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
        let spacing: CGFloat = reading ? 6 : 3
        // **Its words in the size of the place it stands in** (fix round 2): the request window's 14, a message's 14 in
        // a chat, a row's 13 on Needs you; they took the page's 12.5, a size of their own beside the chat's 14.
        let chat = reading || self.chat
        VStack(alignment: .leading, spacing: reading ? 12 : 8) {
            ForEach(shown) { block in
                if let marker = block.marker {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).font(chat ? ChatStyle.title : FormMetrics.title)
                            .foregroundStyle(FleetStyle.muted).frame(minWidth: 18, alignment: .trailing)
                        Text(block.text).lineSpacing(spacing).textSelection(.enabled).lineLimit(lines)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(block.text).lineSpacing(spacing).textSelection(.enabled).lineLimit(lines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.font(chat ? ChatStyle.font : FormMetrics.text)
    }
}

/// One offered answer, as a target: a row that lifts under the pointer and dims on the press. **Neutral grey** (the
/// owner's yes of 28 October 2026, D-8): it was violet, the colour that now has one job — a link, the focus, the
/// selected tab and the brand's mark — and the rows of a request read as a list of choices without it.
struct NeedOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { OptionRow(configuration: configuration) }

    private struct OptionRow: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        private var lit: Bool { hovered && isEnabled }

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .fill(Color.white.opacity(lit ? 0.09 : 0.05))
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
                        .strokeBorder(FleetStyle.hairline(lit ? 0.18 : 0.10), lineWidth: FleetStyle.edgeWidth(contrast))))
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
            Text(words).font(FormMetrics.text).foregroundStyle(FleetStyle.text)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let since = sendingSince { Held(since: since) { SendingWords() } }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if need.choices.isEmpty {
                // **One look for an answer option** (T-22): the app's own three replies are rows like the ones an
                // agent offers, though they only fill the box below and the owner sends or edits first. A page showed
                // 24-pt dark chips under one request and 36-pt violet rows under the next.
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Self.quickReplies, id: \.self) { reply in
                        Button {
                            if trimmed.isEmpty { text.wrappedValue = reply }
                            focused = true
                        } label: { row(reply) }
                            .buttonStyle(NeedOptionButtonStyle()).accessibilityIdentifier("quick-\(reply.lowercased())-\(need.id)")
                    }
                }
            } else if need.combines {
                // **Options that combine** (the owner's yes of 9 November 2026): a tick at the right of each row, and one
                // Send with how many he ticked; it stays off while none is ticked.
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(need.choices.enumerated()), id: \.offset) { index, option in
                        HStack(spacing: 8) {
                            Text(option).font(FormMetrics.text).foregroundStyle(FleetStyle.text)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: Binding(get: { ticked.contains(index) }, set: { on in
                                if on { ticked.insert(index) } else { ticked.remove(index) }
                            })).labelsHidden().toggleStyle(FleetCheckboxStyle()).accessibilityLabel(option)
                        }
                        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: FormMetrics.inner).fill(Color.white.opacity(0.05)))
                        .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
                        .onTapGesture { if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) } }
                        .accessibilityIdentifier("need-tick-\(need.id)-\(index)")
                    }
                    HStack {
                        Spacer()
                        Button("Send \(ticked.count)") {
                            let chosen = Array(ticked)
                            Task { await store.answer(need, choices: chosen) }
                        }.buttonStyle(FleetPrimaryButtonStyle()).disabled(ticked.isEmpty || !store.canWrite)
                            .accessibilityIdentifier("need-send-ticked-\(need.id)")
                    }
                }
            } else {
                let waiting = AnswerWaits.shared.press(of: need)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(need.choices.enumerated()), id: \.offset) { index, option in
                        // **Never drawn grey** (fix round 2): a press that comes while the hub cannot take it waits, and
                        // goes when it can, its option saying "Sending…" meanwhile (`AnswerWaits`).
                        let sending = waiting?.choice == index
                        Button { AnswerWaits.shared.press(need, choice: index, store: store) } label: {
                            row(option, sendingSince: sending ? waiting?.since : nil)
                        }
                            .buttonStyle(NeedOptionButtonStyle())
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
                        .composerField(alone: !(store.supportsAttachments && composer != nil), lines: 1...8)
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
                // The composer's room around its 28-point controls, so the box at rest is the composer's 40 points.
                .padding(ComposerCapsule<EmptyView, EmptyView>.inset)
                // The radius of what stands in a card (`FormMetrics.inner`), not more than its card's 13 (T-21, fix
                // round): it was the chat composer's 20 inside a card of 13.
                .background(FleetStyle.composer, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                // **The field's edge, and the whole box takes the click** (fix round 2), as every field's does
                // (`fleetField`): its edge read 1.6:1 on its card, and a click on its 10 points of room went nowhere.
                .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .strokeBorder(FleetStyle.hairline(0.32), lineWidth: FleetStyle.edgeWidth(contrast)))
                .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
                .onTapGesture { focused = true }
                // The clipboard reaches the box that the owner writes in: a page can show several open requests.
                .pasteAttachments(store: store, composer: focused ? composer : nil)
                .keyPasteGuard(store: store, composer: focused && guards ? guardKey : nil)
                .stageDroppedFiles(store: store, composer: composer)
            // No "Connection required" under it (D-2): the notice over the page is the one sign of an outage, as in
            // the chat's composer.
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
                  let current = store.openNeeds.first(where: { $0.id == need.id }), current.choices == need.choices
            else { return }
            await store.answer(current, choice: press.choice)
        }
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
        if guards && !keyAllowed && KeyInText.contains(text.wrappedValue) {
            store.heldKey = HeldKey(composer: guardKey, hold: .text)
            return
        }
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

/// One request in the Needs you page, and in the chat of the agent that asked it: the title, the first lines of it,
/// and its answer where it is read. The rest opens with one click, so a long request does not fill the column.
///
/// **An answered request folds to two lines** (the owner's yes of 28 October 2026, D-7): its title and "✓ Correos",
/// the rest on a click, as Grok Bot folds a question card it answered. Needs you keeps every request, and an answered
/// one took as much room as an open one.
struct NeedRequestCard: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    /// In the chat of the agent that asked it (D-7), where no request is the selected one of Needs you.
    var inChat = false
    @State private var expanded = false
    /// Owner feature `need_talk` (API 1.106): Discuss is open, and the words of his next message in it.
    @State private var discussing = false
    @State private var message = ""
    @State private var talking = false
    /// His answer as the outbox saved it, kept from the frame it went until the reading says the request is answered
    /// (`WordsOnTheirWay`): the store lets the request go with its receipt, a round trip before that reading.
    @State private var sent: PendingRequest?
    /// On Needs you, a form page, the card takes the form's width as every card there does (D-8); in a chat, the column's.
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
    /// **The card's words in the sizes of the place it stands in** (fix round 2): in a chat its title and its body
    /// (`NeedBody`) take the chat's 14 points, on Needs you a row's 13, the title medium; its small lines are 12 in both,
    /// where they were 11 and 11.5, and its body took the page's 12.5: sizes of their own in the chat's column. Its
    /// option rows keep 13 in both, the size of a button's words (D-8 item 10).
    private var titleFont: Font { inChat ? ChatStyle.title : FormMetrics.title }
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
        // reads 4:1, where the request card had none (1.11:1); the selected request's violet over it.
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
            .strokeBorder(FleetStyle.hairline(0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
            .stroke(!inChat && store.selectedNeed == need.id ? FleetStyle.accent.opacity(0.4) : .clear))
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
                    // No orange "Needs you" on a request that waits (D-2): on Needs you and in the chat every open
                    // request needs him. "Answered" stays, on one opened again.
                    if !need.isOpen { Text("Answered").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
                }.padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach)

            // **An older long card folds to three lines** (the owner, 9 November 2026: "MUCH better so they are shorter"):
            // its one long paragraph showed whole under the two-block fold. Show all opens the rest.
            NeedBody(text: need.why, limit: expanded || short ? nil : 1, lines: expanded || short ? nil : 3, chat: inChat)
            if expanded, let details = need.details {
                NeedBody(text: details, chat: inChat)
            }
            if expanded, !todo.isEmpty {
                Text("What it needs from you").font(FormMetrics.detailTitle)
                    .foregroundStyle(FleetStyle.muted).padding(.top, 2)
                NeedBody(text: todo, chat: inChat)
            }
            if hasMore || discussable {
                HStack(spacing: 10) {
                    if hasMore {
                        Button {
                            withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                        } label: {
                            HStack(spacing: 3) {
                                Text(need.details != nil ? "Details" : expanded ? "Show less" : "Show all")
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
            if discussable && (discussing || !talk.isEmpty) { discussion }
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

    /// **His discussion of the item** (the owner's yes of 9 November 2026, "a button to clarify or to discuss"): his
    /// messages in the chat's bubble, the replies as the chat draws an agent's words, and a field of its own. It is no
    /// answer: the options and Your answer stay below it until he decides.
    private var discussion: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(talk.enumerated()), id: \.offset) { _, line in
                if line.fromOwner {
                    Text(line.text).font(FormMetrics.text).foregroundStyle(FleetStyle.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(ChatStyle.bubble, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(line.text).font(FormMetrics.text).foregroundStyle(FleetStyle.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("\(line.who.agentLabel): \(line.text)")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(manager.agentLabel)", text: $message, axis: .vertical)
                    .textFieldStyle(.plain).font(FormMetrics.text).growingField(1...6)
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
        let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.canWrite && !talking && !words.isEmpty && words.count <= NeedTalk.most
    }

    private func sendMessage() {
        guard canTalk else { return }
        let words = message
        talking = true
        Task {
            if await store.talk(need, text: words) { message = "" }
            talking = false
        }
    }
}

/// **The list of Needs you** (D-4): the manager's open requests, then the tasks that only the owner can move (`tasks`),
/// then the requests he answered. **A request he answers while he looks keeps its place, and so does every other card**
/// (fix round 3b; D-7 item 2, B-MOT-12): it folds where it stands in the frame he answers (`WordsOnTheirWay`), and the
/// reading that confirms the answer moves nothing (`NeedsOrder`); "Nothing needs you" waits for his next visit while a
/// request he answered on this one stands at the top. That reading sorted the list again, a round trip after the fold.
struct NeedsList<Tasks: View>: View {
    @Bindable var store: FleetStore
    /// The owner has tasks to move: `tasks` draws them between the two groups.
    let hasTasks: Bool
    let tasks: Tasks
    /// What this visit drew, and where.
    @State private var order = NeedsOrder()

    init(store: FleetStore, hasTasks: Bool, @ViewBuilder tasks: () -> Tasks) {
        self.store = store; self.hasTasks = hasTasks; self.tasks = tasks()
    }

    var body: some View {
        let needs = store.state?.needs ?? []
        let groups = order.groups(of: needs)
        // **The blocks of a page, 22 points apart** (margins row 18): the requests and the card of his tasks stood 12
        // apart, where every other page puts its blocks `FleetSpace.block` apart.
        LazyVStack(alignment: .leading, spacing: FleetSpace.block) {
            if groups.top.isEmpty && !hasTasks {
                FormSection { FormEmpty("Nothing needs you", symbol: "checkmark.circle") }
            }
            ForEach(groups.top) { need in NeedRequestCard(store: store, need: need) }
            if hasTasks { tasks }
            ForEach(groups.bottom) { need in NeedRequestCard(store: store, need: need) }
        }
        .onChange(of: needs.map { [$0.id, $0.isOpen ? 1 : 0] }, initial: true) { _, _ in
            order.keep(store.state?.needs ?? [])
        }
    }
}

/// The same request as a window over the Dashboard, so that the owner answers it where he saw it.
struct NeedSheet: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    let close: () -> Void

    /// What the request itself takes, so a short one is a short window and a long one is as tall as the screen
    /// allows before it scrolls.
    @State private var read: CGFloat = 0
    /// What its answer takes. An item that offers its own answers has a row for each, which wraps, so this is no
    /// longer a constant: a short request with four offered answers needs the room for them.
    @State private var answer: CGFloat = 0

    private var window: CGSize { (NSApp.mainWindow ?? NSApp.keyWindow)?.frame.size ?? CGSize(width: 1280, height: 900) }
    static func width(of window: CGSize) -> CGFloat { min(max(660, window.width * 0.58), 1020) }
    /// The room the window takes beside the two it measures: its title, the dividers, the paddings and the two
    /// buttons under the answer.
    private static let chrome: CGFloat = 138
    static func height(of window: CGSize, content: CGFloat, answer: CGFloat) -> CGFloat {
        min(max(380, content + answer + chrome), min(window.height * 0.82, 920))
    }

    private struct ReadHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private struct AnswerHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                // Its title without the hub's number, and "Answered" only once it is (D-2), as on the card.
                Text(need.title).font(ChatStyle.title)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if !need.isOpen { Text("Answered").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            Divider().overlay(FleetStyle.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    NeedBody(text: need.why, reading: true)
                    if let details = need.details { NeedBody(text: details, reading: true) }
                    if !need.todo.isEmpty, !need.asksForSecret {        // a secret's form is the answer below
                        Text("What it needs from you").font(FormMetrics.detailTitle)
                            .foregroundStyle(FleetStyle.muted)
                        NeedBody(text: need.todo, reading: true)
                    }
                    NeedAnswerGiven(store: store, need: need)
                    AgentNamed(agent: need.by) {
                        Text("From \(need.by.agentLabel) · \(messageTime(need.raised))")
                    }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                }
                .frame(maxWidth: 720, alignment: .leading)        // a line nobody has to track back across
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 22)
                .background(GeometryReader { shown in
                    Color.clear.preference(key: ReadHeight.self, value: shown.size.height)
                })
            }
            Divider().overlay(FleetStyle.line)
            VStack(alignment: .leading, spacing: 10) {
                if need.isOpen {
                    Group {
                        if need.asksForSecret { SecretRequestForm(store: store, need: need) }
                        else { NeedAnswerBox(store: store, need: need) }
                    }
                        .background(GeometryReader { shown in
                            Color.clear.preference(key: AnswerHeight.self, value: shown.size.height)
                        })
                }
                HStack {
                    Button("Open in Needs you") {
                        store.selectedNeed = need.id
                        store.destination = .needs
                        close()
                    }.buttonStyle(FleetOutlineButtonStyle())
                    Spacer()
                    Button("Close", action: close).buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.escape, modifiers: [])
                }
            }.padding(.horizontal, 24).padding(.vertical, 20)
        }
        // A sheet takes the size of its content, so it is measured against the window it opens over: large enough
        // to read a long request without scrolling it through a small pane, and never wider than a line can be
        // followed across.
        .frame(width: Self.width(of: window), height: Self.height(of: window, content: read, answer: answer))
        .onPreferenceChange(ReadHeight.self) { read = $0 }
        .onPreferenceChange(AnswerHeight.self) { answer = $0 }
        .background(FleetStyle.rail)
        // A card over the window is a window of its own, which the window's team does not reach: the glyph before the
        // asker's name and Send's colour take it from here.
        .environment(\.glyphTeam, store.state?.agents.map(\.name) ?? [])
            // A file dropped anywhere in the window is staged in the answer below it, as on the request's card.
            .stageDroppedFiles(store: store,
                               composer: need.isOpen && need.takesFiles ? FleetStore.stageKey(need: need.id) : nil,
                               mark: true)
    }
}
