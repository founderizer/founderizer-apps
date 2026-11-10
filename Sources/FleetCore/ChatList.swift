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
        let moved = tasks.filter { $0.owner == agent && !$0.isTerminal }
            .map { $0.last_activity ?? $0.started ?? $0.created }.max()
        if let doing = AgentActivity.doingNow(agent, tasks: tasks), let moved, moved >= last?.created ?? 0 {
            return doing
        }
        switch last {
        case .report(let report): return plain(report.text)
        case .message(let message):
            // A message of files alone is its files, as the chat shows it.
            let files = (message.attachments ?? []).map(\.name).joined(separator: ", ")
            return (plain(message.text) ?? plain(files)).map { "You: \($0)" }
        case nil: return nil
        }
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
