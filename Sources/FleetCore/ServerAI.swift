import Foundation

/// **Which AI runs on a new server**, the owner's one choice in Add server (1 November 2026: "why are we asking for
/// chatgpt AND claude login if we still dont know what the user will choose?"). The hub keeps it, and on a Mac the
/// sitting shows only what it needs. A Linux server has no desktop, so `both` is a choice of a Mac alone.
public enum ServerAI: String, CaseIterable, Sendable {
    case claude, chatGPT, both

    /// The runtime of the first agent.
    public var runtime: String { self == .chatGPT ? "codex" : "claude" }

    /// A Mac's sitting for this choice has the ChatGPT app and Computer Use.
    public var hasChatGPT: Bool { self != .claude }

    /// The runtimes whose logos its card shows.
    public var logos: [String] {
        switch self {
        case .claude: ["claude"]
        case .chatGPT: ["codex"]
        case .both: ["claude", "codex"]
        }
    }

    public var title: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .both: "Both"
        }
    }

    /// The one line of its card on the page for a Mac.
    public var macLine: String {
        switch self {
        case .claude: "Browser tasks in Chrome."
        case .chatGPT: "Computer use, in any app."
        case .both: "Claude does the work. ChatGPT adds computer use."
        }
    }

    /// The one line of its card on the page for a Linux server, which has no desktop.
    public var linuxLine: String { self == .chatGPT ? "Codex." : "Claude Code." }

    public static let linuxChoices: [ServerAI] = [.claude, .chatGPT]
}
