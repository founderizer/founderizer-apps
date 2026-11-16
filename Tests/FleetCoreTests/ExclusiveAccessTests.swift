import Foundation
import Testing

/// **No change through an optional chain reads what it changes** (a user's report of 16 November 2026: the Mac app
/// stopped with SIGABRT at the end of each install that stopped, from 0.1.243 on). A call or an assignment through
/// `x?.` holds `x` from the start of the chain to the end of the change, also while its arguments are read, so a read
/// of `x` among them is a second access to `x` at the same time. For a stored property of a class (each `@Observable`
/// model's), Swift checks that only while the app runs, and stops the app there: no build and no test of a target
/// sees it. So this reads the source of the apps. The fix is a `let` of the value before the change. A plain call
/// (`x.change(x.value)`) and a forced one (`x!.change(x!.value)`) read their arguments before the access begins, and
/// a call of a method that does not change its value (`x?.word(x?.value)`, two reads) is allowed: they are not this
/// case. Which methods change their value is read from the code by their names (`mutatingNames`).
struct ExclusiveAccessTests {
    /// The rule's own reading, on the shapes that Swift stops and on the ones that it lets through.
    @Test func theReadingFindsTheShapesThatStopTheApp() {
        let changes: Set<String> = ["place", "note", "hide", "append"]
        func overlaps(_ text: String) -> [String] { Self.overlaps(in: text, mutating: changes) }
        // The line of 16 November 2026, and its fix.
        #expect(overlaps("log?.place(hub: log?.record.kind == .hub ? claimedHub() : nil, host: host)") == ["1: log?.place("])
        #expect(overlaps("let kind = log?.record.kind\nlog?.place(hub: kind == .hub ? claimedHub() : nil)").isEmpty)
        // An assignment, a compound one, a member's change, a subscript's chain, `self.`, a path, a call over lines,
        // an interpolation.
        #expect(overlaps("log?.count = (log?.count ?? 0) + 1").count == 1)
        #expect(overlaps("log?.count += log?.count ?? 0").count == 1)
        #expect(overlaps("log?.steps.append(log?.count ?? 0)").count == 1)
        #expect(overlaps("records[id]?.note(records.count)").count == 1)
        #expect(overlaps("self.log?.place(hub: log?.hub)").count == 1)
        #expect(overlaps("log?.place(hub: nil, host: self.log?.host)").count == 1)
        #expect(overlaps("model.log?.place(hub: model.log?.hub)").count == 1)
        #expect(overlaps("let a = 1\nlog?.place(hub: nil,\n           host: log?.host)") == ["2: log?.place("])
        #expect(overlaps("log?.place(hub: \"\\(log?.hub ?? \"\")\")").count == 1)
        // Not these: a method that changes nothing, a label of that name, the name in a string or in a comment, the
        // next statement, a member of another value, a longer name, a forced chain, a plain call and a comparison.
        #expect(overlaps("ask.working?.stateWord(holds: holds, limited: ask.working?.owner ?? \"\")").isEmpty)
        #expect(overlaps("log?.place(log: nil)").isEmpty)
        #expect(overlaps("log?.hide([\"log?.x\"]) // log?.place(hub: log?.hub)").isEmpty)
        #expect(overlaps("/* a /* b */ log?.place(hub: log?.hub) */ log?.hide([])").isEmpty)
        #expect(overlaps("let a = #\"log?.place(hub: log?.hub)\"#\nlet b = \"\"\"\nlog?.place(hub: log?.hub)\n\"\"\"").isEmpty)
        #expect(overlaps("work?.cancel(); work = nil").isEmpty)
        #expect(overlaps("log?.place(hub: other.log)").isEmpty)
        #expect(overlaps("log?.place(hub: logged)").isEmpty)
        #expect(overlaps("log!.place(hub: log!.hub)").isEmpty)
        #expect(overlaps("log.place(hub: log.hub)").isEmpty)
        #expect(overlaps("if log?.kind == .hub { log = nil }").isEmpty)
        // The names of the methods that change their value: the code's own, with none from a comment or a string.
        let names = Self.mutatingNames(in: ["public mutating func place(hub: String?) {}\n// mutating func said()",
                                            "let a = \"mutating func quoted()\"\nmutating  func note() {}"])
        #expect(names.isSuperset(of: ["place", "note", "append", "removeAll"]))
        #expect(!names.contains("said") && !names.contains("quoted"))
    }

    /// **No such change in the apps' code**: each Swift file of the Mac app, its services and programs, FleetCore and
    /// the iPhone app (`Sources`, `ios`), their tests apart.
    @Test func noChangeThroughAnOptionalChainReadsItsOwnStart() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var files: [(path: String, text: String)] = []
        for folder in ["Sources", "ios"] {
            let listed = try #require(FileManager.default.enumerator(at: app.appendingPathComponent(folder),
                                                                     includingPropertiesForKeys: nil))
            for case let file as URL in listed where file.pathExtension == "swift" && !file.path.contains("/ios/Tests/") {
                files.append((String(file.path.dropFirst(app.path.count + 1)), try String(contentsOf: file, encoding: .utf8)))
            }
        }
        #expect(files.count > 300 && files.contains { $0.path == "Sources/Founderizer/MachineInstallView.swift" },
                "\(files.count) files")
        let changes = Self.mutatingNames(in: files.map(\.text))
        #expect(changes.contains("place"), "the install record's own change is no mutating func any more")
        let found = files.flatMap { file in Self.overlaps(in: file.text, mutating: changes).map { "\(file.path):\($0)" } }
        #expect(found.isEmpty, "read the value into a let before the change: \(found)")
    }

    /// The standard library's methods that change their value, which a model's array, set, dictionary, text or number
    /// calls through an optional chain.
    static let standardChanges: Set<String> = [
        "append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "removeValue", "removeSubrange",
        "popLast", "updateValue", "merge", "formUnion", "formIntersection", "formSymmetricDifference", "subtract",
        "sort", "reverse", "shuffle", "swapAt", "replaceSubrange", "reserveCapacity", "toggle", "negate"]

    /// The names of the methods that change their value: each `mutating func` of the texts' code (not of a comment or a
    /// string), and the standard library's (`standardChanges`).
    static func mutatingNames(in texts: [String]) -> Set<String> {
        let declared = try! NSRegularExpression(pattern: #"\bmutating\s+func\s+([A-Za-z_]\w*)"#)
        var names = standardChanges
        for text in texts {
            let code = Self.code(of: text) as NSString
            for match in declared.matches(in: code as String, range: NSRange(location: 0, length: code.length)) {
                names.insert(code.substring(with: match.range(at: 1)))
            }
        }
        return names
    }

    /// The changes through an optional chain in a text whose arguments, or whose right side, read the chain's own
    /// start: each as its line and its start ("12: log?.place("). A call is a change when its method's name is in
    /// `mutating`; an assignment always is.
    static func overlaps(in text: String, mutating: Set<String>) -> [String] {
        // The start (`log`, `self.log`, `model.log`), a subscript's brackets, `?.`, the members down to the one that
        // changes, and a call's bracket or an assignment's sign (not `==`).
        let change = try! NSRegularExpression(pattern: #"(?<![\w.$])((?:self\.)?[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)"#
                                              + #"(?:\[[^\]\n]*\])?\?\.(?:[A-Za-z_]\w*\??\.)*([A-Za-z_]\w*)\s*(\(|[-+*/]?=(?!=))"#)
        let code = Self.code(of: text)
        let units = Array(code.utf16)
        let whole = code as NSString
        var found: [String] = []
        for match in change.matches(in: code, range: NSRange(location: 0, length: whole.length)) {
            var start = whole.substring(with: match.range(at: 1))
            if start.hasPrefix("self.") { start.removeFirst(5) }
            let opener = match.range(at: 3)
            let call = whole.substring(with: opener) == "("
            guard !call || mutating.contains(whole.substring(with: match.range(at: 2))) else { continue }
            let from = opener.location + opener.length
            let to = call ? Self.closing(units, from: from) : Self.statementEnd(units, from: from)
            let read = whole.substring(with: NSRange(location: from, length: to - from))
            // The start as a whole name, with or without `self.`, and not as a label (`log:`).
            let reads = try! NSRegularExpression(pattern: #"(?<![\w.$])(?:self\.)?"#
                                                 + NSRegularExpression.escapedPattern(for: start) + #"(?![\w:])"#)
            guard reads.firstMatch(in: read, range: NSRange(location: 0, length: (read as NSString).length)) != nil else {
                continue
            }
            let line = units[..<match.range.location].reduce(1) { $1 == 10 ? $0 + 1 : $0 }
            found.append("\(line): \(whole.substring(with: match.range).filter { !$0.isWhitespace })")
        }
        return found
    }

    /// Where the call whose bracket opened just before `from` closes it.
    static func closing(_ units: [UInt16], from: Int) -> Int {
        var depth = 1, index = from
        while index < units.count {
            if units[index] == 40 { depth += 1 } else if units[index] == 41 { depth -= 1; if depth == 0 { return index } }
            index += 1
        }
        return index
    }

    /// Where the right side of an assignment that begins at `from` ends: at the end of its line or at a `;`, or at a
    /// bracket that closes one that it did not open.
    static func statementEnd(_ units: [UInt16], from: Int) -> Int {
        var depth = 0, index = from
        while index < units.count {
            switch units[index] {
            case 40, 91, 123: depth += 1
            case 41, 93, 125:
                if depth == 0 { return index }
                depth -= 1
            case 10, 59: if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return index
    }

    /// What the string is inside of: a string literal, with the bytes that end it and the ones that open an
    /// interpolation in it, or the code of an interpolation, with its depth of brackets.
    enum Inside {
        case string(end: [UInt8], interpolation: [UInt8], escapes: Bool)
        case interpolation(depth: Int)
    }

    /// The text with its comments and the insides of its string literals as spaces, its new lines kept: what a rule of
    /// the code reads. The code of an interpolation in a string stays code.
    static func code(of text: String) -> String {
        var bytes = Array(text.utf8)
        let count = bytes.count
        let newline = UInt8(ascii: "\n"), space = UInt8(ascii: " "), quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#")
        let backslash = UInt8(ascii: "\\"), open = UInt8(ascii: "("), close = UInt8(ascii: ")")
        let lineComment = Array("//".utf8), commentOpens = Array("/*".utf8), commentCloses = Array("*/".utf8)
        let threeQuotes = Array("\"\"\"".utf8)
        func at(_ index: Int, _ word: [UInt8]) -> Bool {
            guard index + word.count <= count else { return false }
            for offset in 0..<word.count where bytes[index + offset] != word[offset] { return false }
            return true
        }
        func blank(_ from: Int, _ to: Int) {
            for index in from..<min(to, count) where bytes[index] != newline { bytes[index] = space }
        }
        var inside: [Inside] = []
        var index = 0
        while index < count {
            if case .string(let end, let interpolation, let escapes)? = inside.last {
                if at(index, end) {
                    index += end.count
                    inside.removeLast()
                } else if at(index, interpolation) {
                    blank(index, index + interpolation.count)
                    index += interpolation.count
                    inside.append(.interpolation(depth: 1))
                } else {
                    // An escape takes the character after it, so `\"` ends nothing.
                    let width = escapes && bytes[index] == backslash ? 2 : 1
                    blank(index, index + width)
                    index += width
                }
                continue
            }
            if at(index, lineComment) {
                var end = index
                while end < count && bytes[end] != newline { end += 1 }
                blank(index, end)
                index = end
            } else if at(index, commentOpens) {
                var depth = 0, end = index
                repeat {
                    if at(end, commentOpens) { depth += 1; end += 2 }
                    else if at(end, commentCloses) { depth -= 1; end += 2 }
                    else { end += 1 }
                } while depth > 0 && end < count
                blank(index, end)
                index = end
            } else if bytes[index] == hash || bytes[index] == quote {
                var first = index
                while first < count && bytes[first] == hash { first += 1 }
                if first < count && bytes[first] == quote {
                    let hashes = Array(repeating: hash, count: first - index)
                    let multiline = at(first, threeQuotes)
                    inside.append(.string(end: (multiline ? threeQuotes : [quote]) + hashes,
                                          interpolation: [backslash] + hashes + [open], escapes: hashes.isEmpty))
                    index = first + (multiline ? 3 : 1)
                } else {
                    index = max(first, index + 1)       // `#if`, `#selector` and the like
                }
            } else {
                if case .interpolation(let depth)? = inside.last {
                    if bytes[index] == open {
                        inside[inside.count - 1] = .interpolation(depth: depth + 1)
                    } else if bytes[index] == close {
                        if depth == 1 {
                            blank(index, index + 1)
                            inside.removeLast()
                            index += 1
                            continue
                        }
                        inside[inside.count - 1] = .interpolation(depth: depth - 1)
                    }
                }
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
