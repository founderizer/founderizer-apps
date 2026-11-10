import Foundation

/// One block of an agent's words, as both apps draw them: a paragraph, a heading, a list item, a quote, a code block, a
/// rule or a table. It is the Mac's own reading of the Markdown that agents write (`MessageText`), moved here so that the
/// phone draws a reply the way the Mac draws it, from the same rules: the phone showed `**`, `#`, `>`, fences and `|---|`
/// as typed.
///
/// A block keeps its inline marks (bold, italic, inline code, links) in its text, because each app draws them with its
/// own fonts. A code block's text is literal. Markdown is for display only: a copy takes the words as they were
/// written. The owner's own messages are drawn by the same rules, in his bubble, on both apps.
public struct MessageBlock: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case paragraph, heading, code, item, quote, rule, table }

    public let kind: Kind
    public let text: String
    /// A list item's mark: "•" for "-", "*" and "+" at every level, and the number as written ("1.", "2)") for a
    /// numbered one. The indent says the level: a smaller "◦" one level in read as a second size of the same dot (the
    /// owner, 27 October 2026, of two dots: "why are they different?!?!").
    public let marker: String
    /// A list item's depth: 0 at the left, 1 for an item indented under another, and so on, at most 3.
    public let level: Int
    /// The rows of a table, the header first. Each cell keeps its inline marks.
    public let cells: [[String]]

    public init(kind: Kind, text: String, marker: String = "", level: Int = 0, cells: [[String]] = []) {
        self.kind = kind
        self.text = text
        self.marker = marker
        self.level = level
        self.cells = cells
    }

    /// The blocks of one text, in order.
    ///
    /// **A list reads as agents write it** (the owner, 10 November 2026, of the fleet's chats beside a Claude Code thread:
    /// "why the format of our text messages is so much worse and plain"): an item indented under another is one level
    /// in; a line right under an item, indented or not, goes on that item; and a fence indented in a list opens a code
    /// block, its lines without that indent. These three showed as typed: "  - sub" and "```" as words.
    public static func parse(_ text: String) -> [MessageBlock] {
        var result: [MessageBlock] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        var codeIndent = 0
        var table: [[String]]? = nil
        /// The indents of the open list's levels, the outermost first.
        var indents: [Int] = []
        /// The last block is an item that the next line goes on, when it is text.
        var openItem = false
        func flush() {
            if !paragraph.isEmpty {
                result.append(MessageBlock(kind: .paragraph, text: paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if let rows = table {
                result.append(MessageBlock(kind: .table, text: "", cells: rows))
                table = nil
            }
        }
        func endList() { indents = []; openItem = false }
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if var block = code {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    result.append(MessageBlock(kind: .code, text: block.joined(separator: "\n"))); code = nil
                } else {
                    block.append(String(line.dropFirst(min(codeIndent, leading(line))))); code = block
                }
                continue
            }
            // A table: a row of cells between "|", then a row of dashes. Its next rows of cells belong to it, and the
            // first other line ends it.
            if table != nil {
                if let row = tableRow(line) {
                    if !row.allSatisfy(isTableRule) { table?.append(row) }
                    continue
                }
                flush()
            } else if let row = tableRow(line), index + 1 < lines.count, let next = tableRow(lines[index + 1]),
                      next.allSatisfy(isTableRule) {
                flush(); endList(); table = [row]
                continue
            }
            let indent = leading(line)
            let trimmed = String(line.drop { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") {
                flush(); openItem = false
                code = []; codeIndent = indent
            } else if trimmed.isEmpty {
                // A blank line ends a paragraph and an item's lines; the list stays open for its next item.
                flush(); openItem = false
            } else if indent < 4, trimmed == "---" || trimmed == "***" {
                flush(); endList(); result.append(MessageBlock(kind: .rule, text: ""))
            } else if indent < 4, let range = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
                flush(); endList(); result.append(MessageBlock(kind: .heading, text: String(trimmed[range.upperBound...])))
            } else if let range = trimmed.range(of: "^(?:[-*+] |[0-9]+[.)] )", options: .regularExpression) {
                flush()
                while let last = indents.last, indent < last { indents.removeLast() }
                if indents.last.map({ indent > $0 }) ?? true { indents.append(indent) }
                let level = min(indents.count - 1, 3)
                let mark = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                result.append(MessageBlock(kind: .item, text: String(trimmed[range.upperBound...]),
                                           marker: mark.count == 1 ? "•" : mark, level: level))
                openItem = true
            } else if trimmed.hasPrefix("> ") {
                flush(); endList(); result.append(MessageBlock(kind: .quote, text: String(trimmed.dropFirst(2))))
            } else if openItem, let item = result.last {
                // A line under an item goes on it.
                result[result.count - 1] = MessageBlock(kind: .item, text: item.text + "\n" + trimmed, marker: item.marker,
                                                        level: item.level)
            } else {
                if indent < 2 { endList() }
                paragraph.append(indents.isEmpty ? line : trimmed)
            }
        }
        flush()
        if let code { result.append(MessageBlock(kind: .code, text: code.joined(separator: "\n"))) }
        return result
    }

    /// The width of a line's indent: a tab is four spaces.
    private static func leading(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    /// The cells of a table row: a line that starts with "|". A backslash before a "|" keeps it in its cell.
    private static func tableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.count > 1 else { return nil }
        var cells = trimmed.replacingOccurrences(of: "\\|", with: "\u{1}").components(separatedBy: "|").dropFirst()
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells = cells.dropLast() }
        return cells.isEmpty ? nil
            : cells.map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    /// A cell of the row under a table's header: dashes, with an optional ":" at each end.
    private static func isTableRule(_ cell: String) -> Bool { cell.range(of: "^:?-+:?$", options: .regularExpression) != nil }

    /// One block's inline marks read: bold, italic, inline code and links, as `AttributedString` carries them. A text
    /// whose marks do not read stays as it is.
    public static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// The words of a text without its marks, on one line: what a list of conversations shows of its newest message.
    /// `**`, `*`, `#`, `>`, backticks and the fences go, a link keeps its words, a table its cells, and a list item its
    /// words. A mark that the hub's cut left open (a preview is the first 120 characters) goes too.
    public static func plain(_ text: String) -> String {
        let words = parse(text).compactMap { block -> String? in
            switch block.kind {
            case .rule: nil
            case .code: block.text
            case .table: block.cells.map { $0.map { String(inline($0).characters) }.joined(separator: " ") }
                .joined(separator: " ")
            default: String(inline(block.text).characters)
            }
        }
        return words.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
