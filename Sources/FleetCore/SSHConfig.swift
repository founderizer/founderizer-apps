import Foundation

#if os(macOS)
/// **The `Host` names of this Mac's own `~/.ssh/config` that give one address as their `HostName`** (the report of
/// 13 November 2026: a server chosen from a provider's list was checked as root on port 22 at its address, while the
/// person reached that same address as `deploy` through an alias, and the root logins it tried could make the server
/// refuse this Mac). A name is only a candidate: `ssh -G` says what each one really gives (`InstallTarget.named`).
///
/// It reads the files as `ssh` would find them: the configuration and each file that its `Include` lines name, with `~`,
/// a path relative to `~/.ssh` and a `*` or `?` in a file's own name, at most `depth` deep. A name with a pattern in
/// it (`*`, `?`, `!`) names no one server, and a name that `ssh` would read as one of its own options never goes.
public enum SSHConfig {
    /// At most this many names go to `ssh -G`, each a program of its own.
    static let most = 16
    /// `ssh` itself stops at 16 levels of `Include`.
    static let depth = 8

    /// The names whose own block sets `HostName` to `host`, in the order the files give them, each once.
    public static func aliases(of host: String, config: URL, home: String) -> [String] {
        var names: [String] = []
        for block in blocks(config, home: home, depth: depth)
        where block.hostname?.lowercased() == host.lowercased() {
            for name in block.names where !names.contains(name) && names.count < most { names.append(name) }
        }
        return names
    }

    /// One `Host` line and what its block says: the names it gives, and its `HostName`, if it has one.
    struct Block: Equatable {
        var names: [String]
        var hostname: String?
    }

    /// The `Host` blocks of one file and of the files it includes, in order. A `Match` block ends the one before it.
    static func blocks(_ file: URL, home: String, depth: Int) -> [Block] {
        guard depth > 0, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var found: [Block] = [], open: Block?
        for raw in text.split(whereSeparator: \.isNewline) {
            let words = self.words(String(raw))
            guard let keyword = words.first?.lowercased() else { continue }
            let values = Array(words.dropFirst())
            switch keyword {
            case "host":
                if let open { found.append(open) }
                open = Block(names: values.filter(isName))
            case "match":
                if let open { found.append(open) }
                open = nil
            case "hostname":
                if open?.hostname == nil { open?.hostname = values.first }
            case "include":
                // The included blocks come where the line is, and the block that the line stands in goes on after them.
                for path in values { for one in included(path, home: home) { found += blocks(one, home: home, depth: depth - 1) } }
            default: continue
            }
        }
        if let open { found.append(open) }
        return found
    }

    /// A line's keyword and its values, as `ssh` splits them: the keyword ends at a space, a tab or `=`, one `=` may
    /// stand between it and the values, and the values are split at spaces and tabs, with quotes taken off. A `#` line
    /// has none.
    static func words(_ line: String) -> [String] {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("#") else { return [] }
        let end = text.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" } ?? text.endIndex
        var rest = text[end...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("=") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return [String(text[..<end])] + rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.filter { !$0.isEmpty }
    }

    /// A name that names one server and that `ssh -G` can take as it is (`InstallTarget.named`'s own rule).
    static func isName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,252}$", options: .regularExpression) != nil
    }

    /// The files that one `Include` value names: `~/` from the home folder, a relative path from `~/.ssh`, and a `*` or
    /// `?` only in the file's own name, in the order of their names.
    static func included(_ value: String, home: String) -> [URL] {
        let path = value.hasPrefix("~/") ? home + value.dropFirst() : value.hasPrefix("/") ? value : home + "/.ssh/" + value
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard name.contains("*") || name.contains("?") else { return [url] }
        let folder = url.deletingLastPathComponent()
        guard !folder.path.contains("*"), !folder.path.contains("?"),
              let all = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return all.filter { fnmatch(name, $0, 0) == 0 }.sorted().map { folder.appendingPathComponent($0) }
    }
}
#endif
