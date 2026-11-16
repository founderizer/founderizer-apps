import FleetCore
import SwiftUI

/// The state of one item's Run in this window (`FleetStore.needRuns`).
enum NeedRunState: Equatable {
    /// The command runs, for one press, by its own id: a press after Stop is a run of its own.
    case running(UUID)
    /// The command ended, and its answer waits until the hub can take a write, as a pressed option waits.
    case sending
    /// The run did not reach its Mac: what ssh or the shell said. Nothing went to the agent.
    case notReached(String)

    /// A run goes on, or its answer waits: Run takes no press, and the block keeps its button.
    var busy: Bool {
        switch self {
        case .running, .sending: true
        case .notReached: false
        }
    }
}

/// **The code block of a hand step's command that has Run** (owner feature `need_run`; the owner's "Yes, as drawn" of 16
/// November 2026, to a picture of his card with Run at the right of its command, Stop while it runs, the card folded
/// to "✓ Ran on <Mac>" when it ended, and one line under the command when the Mac was not reached). `MessageText`
/// gives it to the first code block whose text is `command`, and only that block shows Run.
struct NeedRunTarget: Equatable {
    let need: Int
    let command: String

    /// The block of `need`'s command that has Run on this Mac, or nil. A run that goes on keeps its block's Stop, also
    /// when the item closed meanwhile. Else Run stands where this Mac can run the command, and not while an answer to
    /// the item is on its way: a second press would run the command a second time.
    @MainActor static func of(_ need: OwnerNeed, store: FleetStore) -> NeedRunTarget? {
        let busy = store.needRuns[need.id]?.busy == true
        guard let command = NeedRun.command(of: need, running: busy) else { return nil }
        if busy { return NeedRunTarget(need: need.id, command: command) }
        // a run that did not reach its Mac keeps its line only while Run itself may stand
        guard store.runPlace(need) != nil, store.answerOnItsWay(to: need) == nil,
              store.pending?.needID != need.id else { return nil }
        return NeedRunTarget(need: need.id, command: command)
    }

    /// Where the item's command runs, by its name: the Mac of the fleet, or his own Mac.
    static func placeName(_ on: String?) -> String {
        guard let on, on != NeedRun.ownMac else { return String(l10n: "your Mac") }
        return on
    }
}

/// **Run, at the right of the command's block**, and Stop while the command runs: the button of a Run in Claude Code, in
/// the words of a button of this app. While the answer of a run that ended waits for the hub, it says "Sending…", as a
/// pressed option does, and takes no press.
struct NeedRunButton: View {
    let target: NeedRunTarget
    @Environment(FleetStore.self) private var store: FleetStore?

    var body: some View {
        if let store, let need = store.state?.needs.first(where: { $0.id == target.need }) {
            let state = store.needRuns[need.id]
            Button {
                switch state {
                case .running?: store.stopRun(need)
                case .sending?: break
                default: Task { await store.run(need) }
                }
            } label: {
                HStack(spacing: 5) {
                    switch state {
                    case .running?:
                        ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                        Text("Stop")
                    case .sending?:
                        ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                        Text("Sending…")
                    default:
                        Image(systemName: "play.fill").font(IconMetrics.symbol(9, weight: .semibold))
                        Text("Run")
                    }
                }
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.text).lineLimit(1).fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(FleetStyle.hairline(0.16), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state == nil || state?.busy == false ? Text("Run")
                                : state == .sending ? Text("Sending…") : Text("Stop"))
            .accessibilityIdentifier("need-run-\(need.id)")
        }
    }
}

/// **The one line under the command when the run did not reach its Mac** (orange, a card's small size, as every line
/// that says what went wrong): nothing went to the agent, and Run stays to try again.
struct NeedRunLine: View {
    let target: NeedRunTarget
    @Environment(FleetStore.self) private var store: FleetStore?

    var body: some View {
        if let store, case .notReached? = store.needRuns[target.need],
           let need = store.state?.needs.first(where: { $0.id == target.need }) {
            let words = need.run_on == NeedRun.ownMac ? String(l10n: "Could not run it on this Mac")
                : String(l10n: "Could not reach \(NeedRunTarget.placeName(need.run_on))")
            HStack(spacing: 5) {
                Image(systemName: "xmark").font(IconMetrics.symbol(10, weight: .semibold))
                Text(words)
            }
            .font(FormMetrics.detail).foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
        }
    }
}

/// **What a press of Run answered**, in the folded card and on an ended step: its mark, a check for exit status 0 and a
/// cross for another, and "Ran on <Mac>". nil for an item that was not answered by Run.
struct NeedRunAnswer {
    let status: Int
    let place: String

    static func of(_ need: OwnerNeed, onItsWay: PendingRequest?) -> NeedRunAnswer? {
        if let ran = onItsWay?.ran { return NeedRunAnswer(status: ran.status, place: NeedRunTarget.placeName(need.run_on)) }
        guard !need.isOpen, need.run_command != nil, let status = need.run_status else { return nil }
        return NeedRunAnswer(status: status, place: NeedRunTarget.placeName(need.run_on))
    }

    var symbol: String { status == 0 ? "checkmark" : "xmark" }
    var words: String { String(l10n: "Ran on \(place)") }
    /// The words that VoiceOver reads for it: the mark says nothing to it, so a run that failed says its exit status.
    var spoken: String { status == 0 ? words : words + ", " + String(l10n: "exit status \(status)") }
}

/// **The output of a command that he ran**, under his answer in the opened card: the end of it, as the hub keeps it, in
/// a well of the canvas's colour, as a code block on a card is drawn; it wraps, so no end of a line is off the card.
struct NeedRunOutput: View {
    let output: String

    var body: some View {
        let shown = output.trimmingCharacters(in: .newlines)
        if !shown.isEmpty {
            Text(verbatim: shown).font(ChatStyle.code).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        }
    }
}
