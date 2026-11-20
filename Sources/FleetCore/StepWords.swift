import Foundation

/// **A task's steps in the owner's words** (his "Yes, build it" of 17 November 2026 to the pictures of the Task page).
/// A thread named a step by its call's title, and the title of a shell command is the command: four lines of
/// `Bash: S=/tmp/…; for i in $(seq 1 40); do …` for one step, and `Edit: /home/fleet-atlas/fleet-work/.tasks/…` for an
/// edit. One rule for every place that names a step: the agent's own line for the call (`says`), else the hub's own
/// words for its kind and its file (`hub.py` `doing_words`, which name what a session does now in the sidebar: the
/// same words in both places); nil keeps the call's title.
public enum StepWords {
    /// The words of one call: the agent's own line, or the hub's words for its kind. Nil for a call of an MCP server (a
    /// Fleet tool included), whose title is its name, for a search for tools, and for a kind that has no words.
    public static func of(_ event: RuntimeEvent, locations: [RuntimeEvent.Location] = []) -> String? {
        if let says = event.says?.trimmingCharacters(in: .whitespacesAndNewlines), !says.isEmpty { return says }
        guard event.server == nil, !(event.title ?? "").hasPrefix("fleet: "), !isToolSearch(event.title) else { return nil }
        let file = (locations.first ?? event.locations?.first).map { fileName($0.path) } ?? ""
        switch event.kind {
        case "read": return file.isEmpty ? String(l10n: "Reading a file") : String(l10n: "Reading \(file)")
        case "edit": return file.isEmpty ? String(l10n: "Editing a file") : String(l10n: "Editing \(file)")
        case "delete": return file.isEmpty ? String(l10n: "Deleting a file") : String(l10n: "Deleting \(file)")
        case "move": return file.isEmpty ? String(l10n: "Moving a file") : String(l10n: "Moving \(file)")
        case "search": return ["WebSearch", "web_search"].contains(label(event.title)) ? String(l10n: "Searching the web")
            : String(l10n: "Searching the files")
        case "execute": return String(l10n: "Running a command")
        case "fetch": return String(l10n: "Reading a web page")
        default: return nil
        }
    }

    /// **A search for tools is no step**: Claude Code loading its own tools ("ToolSearch: select:…"), for which the
    /// hub's `doing_words` says nothing. A fold of a thread said "1 step" for one, with nothing of the work in it.
    public static func isToolSearch(_ title: String?) -> Bool { label(title) == "ToolSearch" }

    /// **What a child agent was asked**, from its call's title ("Agent: Independent review of the diff"), or nil: two
    /// children of one task were "general-purpose" and "general-purpose", their kind and nothing that told them apart.
    public static func childTitle(_ title: String?) -> String? {
        guard let title, let colon = title.range(of: ": "), ["Agent", "Task"].contains(String(title[..<colon.lowerBound]))
        else { return nil }
        let words = title[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// **A changed file from its repository's root**: a path in an agent's clones, `~/fleet-work/<owner>/<name>/…` or a
    /// task's own `~/fleet-work/.tasks/<agent>/<generation>/<window>/<owner>/<name>/…` (fleet.py `task_place`), as the
    /// repository ("owner/name") and the path in it. Nil for any other path, which shows whole. The panel showed
    /// `/home/fleet-atlas/fleet-work/.tasks/atlas/0123456789ab/T-12/acme/api/src/…` in two lines.
    public static func inRepository(_ path: String) -> (repository: String, path: String)? {
        var parts = path.split(separator: "/").map(String.init)
        guard let work = parts.firstIndex(of: "fleet-work") else { return nil }
        parts.removeFirst(work + 1)
        if parts.first == ".tasks" {
            guard parts.count >= 7 else { return nil }
            parts.removeFirst(4)
        }
        guard parts.count >= 3, !parts[0].hasPrefix("."), !parts[1].hasPrefix(".") else { return nil }
        return ("\(parts[0])/\(parts[1])", parts[2...].joined(separator: "/"))
    }

    /// The words of the newest step that has not ended in the attempt `attempt` and says something: what a thread's
    /// live line says while the hub names no call of a turn that runs, as when a call works in the background.
    public static func running(in timeline: ActivityTimeline, attempt: Int) -> String? {
        for row in timeline.rows.reversed() where row.event.type == "tool_call" && row.event.parent == nil
            && row.event.attempt == attempt && !["completed", "failed"].contains(row.status ?? "") {
            if let words = of(row.event, locations: row.locations) { return words }
        }
        return nil
    }

    static func fileName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? "" }

    /// The tool of a title, "Bash" of "Bash: ls": the part before its first ": ".
    private static func label(_ title: String?) -> String {
        guard let title else { return "" }
        return title.range(of: ": ").map { String(title[..<$0.lowerBound]) } ?? title
    }
}
