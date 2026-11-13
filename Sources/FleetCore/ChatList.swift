import Foundation

/// **The agents' chats in the main sidebar, as a chat app lists its conversations.** The owner, 24 October 2026,
/// with Grok's list beside his own: "should be more like Grok (taller, with preview, and we could have some right
/// click extras) KEEP STYLE". He chose the extras himself: Pin to top, Mark as read or unread, and the agent's
/// details, Settings and server.
///
/// This is the part of it that is not drawing: which agent stands where, and the one line under each name. Both
/// are read out of what the app already holds, so the list asks the hub for nothing.
public enum ChatList {
    /// The agents in the order the sidebar lists them: the ones he pinned first, the newest pin at the top, then
    /// every other agent in the hub's own order. A pin of an agent the hub does not list is kept and not shown, so
    /// an agent that comes back after a rebuild under the same name is pinned again.
    public static func order(_ agents: [String], pinned: [String]) -> [String] {
        let present = pinned.filter(agents.contains)
        return present + agents.filter { !present.contains($0) }
    }

    /// **The line under an agent's name: the newest thing it did.** The last message of its chat, his own with
    /// "You: " in front so that he never reads his words as the agent's — or, when one of its open tasks moved
    /// after that message, what it is doing (`AgentActivity.doingNow`, the line that row had before), as a chat app
    /// says "typing…". A question the agent asks in its chat while it works is newer than its task, so it is not
    /// hidden behind the task. Nil before the first message, and the row then shows the name alone.
    public static func preview(_ agent: String, last: ChatEntry?, tasks: [FleetTask]) -> String? {
        if let doing = AgentActivity.doingNow(agent, tasks: tasks), let moved = moved(agent, tasks: tasks),
           moved >= last?.created ?? 0 {
            return doing
        }
        switch last {
        case .report(let report): return plain(report.text)
        case .message(let message):
            // A message of files alone is its files, as the chat shows it.
            let files = (message.attachments ?? []).map(\.name).joined(separator: ", ")
            return (plain(message.text) ?? plain(files)).map { String(l10n: "You: \($0)") }
        case nil: return nil
        }
    }

    /// When an agent's open tasks last moved, or nil with none.
    private static func moved(_ agent: String, tasks: [FleetTask]) -> Double? {
        tasks.filter { $0.owner == agent && !$0.isTerminal }.map { $0.last_activity ?? $0.started ?? $0.created }.max()
    }

    /// **When the line under an agent's name is from**: the time of what `preview` shows, which is the last move of
    /// its open tasks where the line says what it is doing, else the time of its last message. Nil with no line.
    public static func previewTime(_ agent: String, last: ChatEntry?, tasks: [FleetTask]) -> Double? {
        if AgentActivity.doingNow(agent, tasks: tasks) != nil, let moved = moved(agent, tasks: tasks),
           moved >= last?.created ?? 0 {
            return moved
        }
        return preview(agent, last: last, tasks: []) == nil ? nil : last?.created
    }

    /// **That time as a chat app writes it at the end of a conversation's row** (the owner, 13 November 2026, with
    /// the rows of a chat app beside his sidebar: "maybe I would like this relative time label on the side menu
    /// too"): the time of day for today, "Yesterday", the weekday within the last week, else the date in numbers.
    /// A time ahead of the clock (the hub's clock and this device's differ by seconds) reads as today's.
    public static func time(_ timestamp: Double, now: Double, calendar: Calendar = .current,
                            locale: Locale = .current) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: Date(timeIntervalSince1970: now))).day ?? 0
        func style(date: Date.FormatStyle.DateStyle? = nil, time: Date.FormatStyle.TimeStyle? = nil) -> Date.FormatStyle {
            Date.FormatStyle(date: date, time: time, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        }
        if days <= 0 { return date.formatted(style(time: .shortened)) }
        if days == 1 { return String(l10n: "Yesterday") }
        if days < 7 { return date.formatted(style().weekday(.wide)) }
        return date.formatted(style(date: .numeric))
    }

    /// The most a preview reads of a message. One line shows a few dozen characters of it; the rest is never
    /// drawn, and a long reply should not be parsed on every poll to be cut off anyway.
    static let reads = 400

    /// What a message of Markdown says, on one line: the words it shows, without the marks that make its headings,
    /// lists, quotes, emphasis, code and links. Nil when nothing is left.
    static func plain(_ text: String) -> String? {
        let lines = text.prefix(reads).split(whereSeparator: \.isNewline).compactMap { line -> String? in
            var line = line.trimmingCharacters(in: .whitespaces)
            // A fence and the rule under a table head carry no words of their own.
            if line.hasPrefix("```") || line.allSatisfy({ "|-: ".contains($0) }) { return nil }
            for mark in [#"^#{1,6}\s+"#, #"^(>\s*)+"#, #"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#] {
                line = line.replacingOccurrences(of: mark, with: "", options: .regularExpression)
            }
            if line.hasPrefix("|") { line = line.replacingOccurrences(of: "|", with: " ") }
            return line
        }
        let joined = lines.joined(separator: " ")
        let words = (try? AttributedString(markdown: joined,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? joined
        let line = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : line
    }
}
