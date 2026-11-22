import Foundation

/// **The lane of the Needs you page** (the owner's yes of 11 November 2026 to its picture, with the lane at the left,
/// after "that looks like another sidebar, I prefer something that's similar to the Tasks page"): the requests that
/// wait for him as the cards of one lane, and the requests that ended behind one row that opens them by day, as Ended's
/// "110 more" does on the Tasks board. The page showed every request as a card of its own, the answered ones under the
/// open ones: 53 answered cards under 9 open ones on his fleet that day.
public struct NeedsLane: Sendable {
    /// The requests that wait for him, the newest first. **A request whose answer is on its way is not one of them**:
    /// its card leaves the lane in the frame he answers, and the next request comes to hand (`successor`).
    public let open: [OwnerNeed]
    /// The requests that ended, by day, the newest first: answered, withdrawn or closed, and one whose answer is on its
    /// way.
    public let ended: [Day]
    /// How many requests ended: the number of the row that opens them.
    public let endedCount: Int

    /// The requests that ended on one day.
    public struct Day: Identifiable, Sendable {
        /// The start of the day, by this Mac's calendar.
        public let start: Double
        public let needs: [OwnerNeed]
        public var id: Double { start }
    }

    /// The lane of `needs`. `sent`: the requests whose answer is on its way (`WordsOnTheirWay`), which the reading
    /// still has open; such an answer is of this moment, `now`, the hub's time.
    /// `held`: the requests that stay in the lane whatever else is true of them: one that he answered a moment ago,
    /// while that answer settles on the page, whether the reading has the answer or not.
    public init(_ needs: [OwnerNeed], sent: Set<Int> = [], held: Set<Int> = [], now: Double, calendar: Calendar = .current) {
        let waits: (OwnerNeed) -> Bool = { held.contains($0.id) || ($0.isOpen && !sent.contains($0.id)) }
        open = needs.filter(waits).sorted { $0.id > $1.id }
        // owner API 1.274: a request that a new item replaced is no row of the ones that ended (`drawn`), unless his
        // answer to it is on its way
        let done = needs.filter { !waits($0) && ($0.replaced_by == nil || sent.contains($0.id)) }
            .map { (need: $0, at: $0.answered ?? ($0.isOpen ? now : $0.raised)) }
            .sorted { ($0.at, $0.need.id) > ($1.at, $1.need.id) }
        var days: [Day] = []
        for entry in done {
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: entry.at)).timeIntervalSince1970
            if let last = days.last, last.start == start {
                days[days.count - 1] = Day(start: start, needs: last.needs + [entry.need])
            } else {
                days.append(Day(start: start, needs: [entry.need]))
            }
        }
        ended = days
        endedCount = done.count
    }

    /// **The request that comes to hand when `id` leaves the lane**: the one that stood under it in `order`, the lane
    /// as it stood, else the one over it; nil when `id` was not in the lane or nothing of the lane is still open. So
    /// an answer to the fourth card brings the fifth, which takes its place, and not the first again.
    public static func successor(of id: Int, in order: [Int], open: Set<Int>) -> Int? {
        guard let index = order.firstIndex(of: id) else { return nil }
        return order[(index + 1)...].first(where: open.contains) ?? order[..<index].last(where: open.contains)
    }

    /// **The request at hand**: the one he chose, while it waits; when it left the lane, the one that takes its place
    /// (`successor`, by `order`, the lane as it stood before); with none chosen, or with a choice that the lane never
    /// held, the first of the lane. One rule for the page's first pass and for what it writes back, so that the pass in
    /// which a request leaves never shows the lane's first request for a frame.
    public static func atHand(chosen: Int?, order: [Int], open: [Int]) -> Int? {
        guard let chosen else { return open.first }
        if open.contains(chosen) { return chosen }
        return successor(of: chosen, in: order, open: Set(open)) ?? open.first
    }

    /// **The request that comes to hand when a new item replaced `id`** (owner API 1.274, `replaced_by`): the end of
    /// its chain (`chainEnd`), while that one waits in `open`, the lane. Nil while `id` waits in the lane, and when the
    /// end of its chain does not wait. The page kept the replaced request at hand as one that ended in another way, so
    /// he read the hub's "Replaced by ..." in the place of the new card (the owner's feedback of 22 November 2026,
    /// F13a).
    public static func replacement(of id: Int, in needs: [OwnerNeed], open: [Int]) -> Int? {
        guard !open.contains(id), let end = chainEnd(of: id, in: needs), open.contains(end) else { return nil }
        return end
    }

    /// **The last item of the chain of items that replaced `id`**, open or ended: the item that its `replaced_by`
    /// names, and the one that replaced that one, to the item that nothing replaced. Nil when nothing replaced `id`,
    /// when the reading does not hold an item of the chain, and on a loop. A request that ended stands at hand as this
    /// item, with his answer, and never with the hub's words of a replaced one.
    public static func chainEnd(of id: Int, in needs: [OwnerNeed]) -> Int? {
        let byID = Dictionary(needs.map { ($0.id, $0) }) { first, _ in first }
        var seen: Set<Int> = [id]
        var end: Int?
        var next = byID[id]?.replaced_by
        while let new = next {
            guard seen.insert(new).inserted, let need = byID[new] else { return nil }
            end = new
            next = need.replaced_by
        }
        return end
    }

    /// The words of the mark on a request that agents wait for, for its hover text and for VoiceOver: "ABC Lead waits
    /// for this", "ABC Lead and ABC Developer wait for this".
    public static func waitWords(_ agents: [String]) -> String {
        let names = agents.map(\.agentLabel)
        switch names.count {
        case 0: return ""
        case 1: return String(l10n: "\(names[0]) waits for this")
        default: return String(l10n: "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1]) wait for this")
        }
    }
}

extension HubState {
    /// **The agents whose work waits for each open request's answer**, by the request's id, each agent once, in the
    /// order of the hub's tasks: the other side of `ownerWaits`, where a task's card on the Tasks board names the
    /// request. The request's card on Needs you has a mark for it, so he sees which answers stop work.
    public var needWaits: [Int: [String]] {
        let waits = ownerWaits
        var agents: [Int: [String]] = [:]
        for task in tasks {
            guard case .request(let id, _)? = waits[task.id], agents[id]?.contains(task.owner) != true else { continue }
            agents[id, default: []].append(task.owner)
        }
        return agents
    }
}
