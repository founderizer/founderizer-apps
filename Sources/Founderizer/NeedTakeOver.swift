import FleetCore
import SwiftUI

/// **Take over** (owner feature `need_takeover`, API 1.217; the owner's "Yes, as drawn" of 16 November 2026 to the
/// pictures of `superbot-ideas/02-take-over-design.md`): the button of an agent's request for one step on its own
/// screen, at the right of the title of its card and under the title of its step on Needs you. Its press opens that
/// agent's machine in Screen Sharing through this Mac's SSH tunnel, as the machine's page does
/// (`MachineAccessButtons`), and it shows a spinner while it connects. It looks as Run does on a command
/// (`NeedRunViews`): one kind of action on a card, one look.
struct NeedTakeOverButton: View {
    let need: Int
    let connection: ScreenSharingConnection
    let press: () -> Void
    private var screen: ScreenSharingSession { .shared }

    var body: some View {
        let busy = screen.busy.contains(connection)
        Button(action: press) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "display").font(IconMetrics.symbol(10, weight: .semibold))
                }
                Text("Take over")
            }
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.text).lineLimit(1).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(FleetStyle.hairline(0.16), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(Text("Take over"))
        .accessibilityIdentifier("need-takeover-\(need)")
    }
}

/// What went wrong with a press of Take over on this view, in the orange line of a card's small size and the words of
/// the machine's page. Only after a press here: an error of the same machine from another press is that place's.
struct NeedTakeOverLine: View {
    let connection: ScreenSharingConnection
    let pressed: Bool

    var body: some View {
        if pressed, let detail = ScreenSharingSession.shared.errors[connection] {
            Text(detail).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension OwnerNeed {
    /// The Screen Sharing way to the machine of the agent that asks, on an open take-over whose machine has one, from
    /// the machines' readings that the store keeps (`FleetStore.runMachines`); nil on every other item.
    @MainActor func takeOverWay(in store: FleetStore) -> ScreenSharingConnection? {
        guard isOpen, asksForTakeover else { return nil }
        return store.runMachines?.first { $0.agent == by }?.screenSharingConnection
    }
}

extension FleetStore {
    /// The machines' readings for a take-over's card: read once, and a few times more while no reading came (a
    /// count, not a clock: the card then shows no Take over, and he answers in words).
    func readTakeOverMachines() async {
        await readRunMachines()
        var tries = 0
        while runMachines == nil, tries < 3 {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }      // the card went away
            tries += 1
            await readRunMachines(now: true)
        }
    }

    /// His press of Take over: the machines' readings again, so the press uses the address of now, then Screen Sharing
    /// of the asking agent's machine, while the item is still open. A tunnel that a press of Take over opened is
    /// closed when its items are answered (`closeAnsweredTakeOvers`); one that he opened before, from the machine's
    /// page, stays as he opened it.
    func takeOver(_ need: OwnerNeed) async {
        await readRunMachines(now: true)
        guard let now = state?.needs.first(where: { $0.id == need.id }), let way = now.takeOverWay(in: self) else {
            return          // answered meanwhile, or its machine has no way in now
        }
        let screen = ScreenSharingSession.shared
        let ours = !screen.opened.contains(way) || takeOvers.values.contains(way)
        await screen.open(way)
        if ours, screen.opened.contains(way) { takeOvers[need.id] = way }
    }

    /// The tunnels that a press of Take over opened, for items that the reading shows answered or gone (the design's
    /// R3: the way in closes at his answer), wherever he answered: in a card, on Needs you, on the iPhone, in a chat app.
    /// A record whose tunnel closed another way (Disconnect on the machine's page, a lost link) is dropped first, so
    /// that a tunnel he opened again from the machine's page stays; and a tunnel that another open take-over of the
    /// same machine still uses stays until that one is answered too.
    func closeAnsweredTakeOvers() {
        guard !takeOvers.isEmpty, let needs = state?.needs else { return }
        let screen = ScreenSharingSession.shared
        takeOvers = takeOvers.filter { screen.opened.contains($0.value) }
        let answered = takeOvers.filter { record in needs.first(where: { $0.id == record.key })?.isOpen != true }
        for id in answered.keys { takeOvers[id] = nil }
        for way in Set(answered.values) where !takeOvers.values.contains(way) {
            Task { await screen.close(way) }
        }
    }
}
