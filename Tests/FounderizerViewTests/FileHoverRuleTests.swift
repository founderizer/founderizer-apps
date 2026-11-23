import Foundation
import Testing

/// **Each icon of a chat file shows its own words under the pointer, and the file's words ("Open <name> (<size>)") show
/// on the rest of its row or picture**, read from the source of `AttachmentViews.swift`. A hover inside a view that has
/// a hover does not show: the outer one shows, also an empty one (macOS 27.0, found by the App shell area's F19/F20
/// builder on 23 November 2026); a hover on a background is beside the views over it, and hides none of theirs. The
/// bugs that this catches: a `.help` comes back on the file's press (`MessageFilesView`) or on a row or a picture around
/// its icons, so the eye, the save icon, the "…" and ↻ show the file's words in place of their own; the file's words go
/// from its row's kind and name, its row's fill (its gaps and its room), its picture or its plate. VoiceOver's words of
/// the file are `OwnFileMenuTests`'. A real hover is not tested: the Mac shows its tooltip in a window on the screen.
struct FileHoverRuleTests {
    /// The views that hold an icon with words of its own: a `.help` around one of them hides its words.
    static let icons = ["IconButton(", "SaveFileIcon(", "OwnFileMenu(", "FileRowLook(", "PictureTile(", "item(", "plate(",
                        "menu"]
    static let words = #"Open \(file.name) (\(file.sizeWords))"#

    @Test func eachIconOfAFileKeepsItsWordsAndTheFilesWordsAreOnItsOwnContent() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer/AttachmentViews.swift")
        let text = Array(try String(contentsOf: file, encoding: .utf8)), code = Self.code(text)
        let helps = Self.modified(".help(", in: code, text: text)
        #expect(helps.count >= 5, "the source has fewer hovers than the file's row and its fill, its picture, its plate and its menu")
        for help in helps {
            let held = Self.icons.filter { Self.holds(help.view, $0) }
            #expect(held.isEmpty, "\(help.call) is around \(held): their own words do not show")
        }
        // The file's words, where nothing with words of its own is inside them.
        #expect(helps.contains { $0.call == ".help(openWords)" && $0.view.contains("Text(name)") },
                "the file's row has no words on its kind and name")
        #expect(helps.contains { $0.call == ".help(openWords)" && $0.view.contains("RoundedRectangle(cornerRadius: FormMetrics.inner).fill(") },
                "the file's row has no words on its fill: its gaps and its room show none")
        #expect(helps.contains { $0.call == ".help(words)" && $0.view.contains("Image(decorative:") },
                "a picture has no words on itself")
        #expect(helps.contains { $0.call == ".help(words)" && $0.view.contains("Image(systemName: file.symbol)") },
                "a picture that did not come has no words on its plate")
        let source = String(text)
        func given(_ label: String) -> Bool {
            source.range(of: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: "\(label): String(l10n: \"\(Self.words)\")"),
                         options: .regularExpression) != nil
        }
        #expect(given("openWords"), "the row is not given the file's words")
        #expect(given("words"), "the picture is not given the file's words")
    }

    /// Is `name` called (or, for a plain word, named) in `view`, as a whole name?
    static func holds(_ view: String, _ name: String) -> Bool {
        let word = name.hasSuffix("(") ? String(name.dropLast()) : name
        return view.range(of: "(?<![A-Za-z0-9_.])\(word)" + (name.hasSuffix("(") ? #"\("# : "(?![A-Za-z0-9_])"),
                          options: .regularExpression) != nil
    }

    /// Each call of the modifier `name` in the code, its whole text, and the view that it modifies: back over the chain
    /// of modifiers before it, to the start of its statement or to the bracket that holds it.
    static func modified(_ name: String, in code: [Character], text: [Character]) -> [(call: String, view: String)] {
        let pattern = Array(name)
        var found: [(call: String, view: String)] = []
        for at in code.indices where code[at...].starts(with: pattern) {
            var end = at + pattern.count, depth = 1
            while end < code.count, depth > 0 {
                if code[end] == "(" { depth += 1 } else if code[end] == ")" { depth -= 1 }
                end += 1
            }
            var start = at - 1, open = 0
            walk: while start >= 0 {
                switch code[start] {
                case ")", "]", "}": open += 1
                case "(", "[", "{":
                    if open == 0 { break walk }
                    open -= 1
                case "," where open == 0, ";" where open == 0: break walk
                case "\n" where open == 0:
                    // a line that does not begin with a modifier is the start of the chain (a comment is blank)
                    if code[(start + 1)...].first(where: { $0 != " " && $0 != "\n" }) != "." { break walk }
                default: break
                }
                start -= 1
            }
            found.append((call: String(text[at..<end]), view: String(code[(start + 1)..<at])))
        }
        return found
    }

    /// The source with each comment blanked and the inside of each string literal written as "x", in place: what is
    /// left of its brackets is code.
    static func code(_ text: [Character]) -> [Character] {
        var code = text, at = 0
        func blank(_ range: Range<Int>, _ with: Character) { for k in range where code[k] != "\n" { code[k] = with } }
        while at < text.count {
            let rest = text[at...]
            if rest.starts(with: "//") {
                let end = text[at...].firstIndex(of: "\n") ?? text.count
                blank(at..<end, " ")
                at = end
            } else if text[at] == "\"" {
                let quotes = rest.starts(with: "\"\"\"") ? 3 : 1
                let end = stringEnd(text, at + quotes, quotes: quotes)
                blank((at + quotes)..<max(at + quotes, end - quotes), "x")
                at = end
            } else {
                at += 1
            }
        }
        return code
    }

    /// The index after the end of the string literal whose words begin at `at`, past its interpolations.
    static func stringEnd(_ text: [Character], _ at: Int, quotes: Int) -> Int {
        var k = at
        while k < text.count {
            if text[k] == "\\", k + 1 < text.count {
                k = text[k + 1] == "(" ? interpolationEnd(text, k + 2) : k + 2
            } else if text[k...].starts(with: repeatElement(Character("\""), count: quotes)) {
                return k + quotes
            } else {
                k += 1
            }
        }
        return k
    }

    /// The index after the `)` that closes the interpolation whose code begins at `at`.
    static func interpolationEnd(_ text: [Character], _ at: Int) -> Int {
        var k = at, depth = 1
        while k < text.count {
            if text[k] == "\"" { k = stringEnd(text, k + 1, quotes: 1); continue }
            if text[k] == "(" { depth += 1 } else if text[k] == ")" { depth -= 1; if depth == 0 { return k + 1 } }
            k += 1
        }
        return k
    }
}
