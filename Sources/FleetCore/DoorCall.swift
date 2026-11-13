import CryptoKit
import Foundation

/// **The hash of a door call, computed on the owner's Mac** (review point 5.6 of 11 November 2026).
///
/// The door refuses a host's `run`, a root script with no box, and gives the call's hash. The manager takes it to the
/// owner as the card "Run one root script on <server>?", and the owner's "Run it once" is his signature of that hash.
/// Before this, the Mac signed the hash that the hub gave, and the script on the card was the manager's words: the
/// card could show one script and the hash could be of another. Now the card carries the script itself
/// (`OwnerNeed.door_script`, API 1.125), and the Mac signs only when
///
/// 1. the card's title and answers name the server of the hash,
/// 2. what the card draws under Script is exactly that script, by the same parser that draws it (`MessageBlock`),
/// 3. the script is printable ASCII with line feeds, short enough to show whole and not padded with blanks,
/// 4. the card's other words hold no code that would stand beside the script as a second one, and
/// 5. the hash that this Mac computes from that server and that script is the hash that the hub gave.
///
/// The hash is the door's own (`door.call_hash`): SHA-256 of the JSON of `[target, action, arguments]` as Python's
/// `json.dumps` writes it, then the content's bytes. `test_door.CALL_HASHES` holds the examples that both sides are
/// tested with.
public enum DoorCall {
    /// The action of a root script with no box, which takes no arguments and the script as its content.
    public static let run = "run"

    /// The hash of one call, as the door computes it: 64 hex characters.
    public static func hash(target: String, action: String, arguments: [String], content: Data) -> String {
        let list = "[" + text(target) + ", " + text(action) + ", [" + arguments.map(text).joined(separator: ", ") + "]]"
        var hasher = SHA256()
        hasher.update(data: Data(list.utf8))
        hasher.update(data: content)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One text as `json.dumps` writes it with its defaults: in double quotes, the quote and the backslash with a
    /// backslash before them, the five short escapes, and every other UTF-16 unit outside the printable ASCII ones
    /// (space to tilde) as `\uxxxx` in lower case, so a character above U+FFFF is its two surrogates.
    static func text(_ value: String) -> String {
        var out = "\""
        for unit in value.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out + "\""
    }

    /// The title of the door's card for one server, as the owner approved it and as the hub requires it of a card
    /// that carries its script.
    public static func title(host: String) -> String { "Run one root script on \(host)?" }

    /// The three answers of the door's card, which the hub writes itself.
    public static func answers(host: String) -> [String] { ["Run it once", "Full access on \(host)", "No"] }

    /// The script as the card's details: one code block (`hub.door_script_details`).
    public static func details(script: String) -> String {
        "```\n" + script + (script.hasSuffix("\n") ? "" : "\n") + "```"
    }

    /// The most characters and lines of a script that a card shows whole (`hub.DOOR_SCRIPT_CHARS`, `DOOR_SCRIPT_LINES`).
    public static let scriptCharacters = 4000
    public static let scriptLines = 200
    /// The widest run of spaces in a script, and the most blank lines in a row: more of either moves a command away
    /// from the words before it (`hub.DOOR_SCRIPT_GAP`, `DOOR_SCRIPT_BLANK`).
    public static let gapSpaces = 32
    public static let blankLines = 2

    /// The first character of a script that this Mac does not sign for, as U+XXXX, or nil. A script is printable
    /// ASCII and line feeds. Every other character can change what runs without changing what he reads: one that
    /// draws nothing (a zero-width mark, a variation selector, a filler), one that draws as a blank or as another
    /// letter or quote, one of a right-to-left script, which reorders the line on screen, and a tab, which the card
    /// draws to a tab stop: as no gap at all, or as a new row. No list of categories stops them all (the reviews of 12
    /// November 2026 found 263 that draw nothing), so the rule is what is allowed.
    public static func hidden(in script: String) -> String? {
        for scalar in script.unicodeScalars where !(scalar == "\n" || (0x20...0x7E).contains(scalar.value)) {
            return String(format: "U+%04X", scalar.value)
        }
        return nil
    }

    /// The lines of a script: the piece after its last line feed is no line.
    static func lines(of script: String) -> [Substring] {
        var lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        if script.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    /// True when a script is padded: a run of more than `gapSpaces` spaces, or more than `blankLines` blank lines in a
    /// row. The card wraps a script's long lines, so every character is on screen; padding would still put a command
    /// far from the line that it belongs to. It bounds the gap between two visible characters, not the script's
    /// height, which `scriptLines` and `scriptCharacters` bound.
    public static func padded(_ script: String) -> Bool {
        var blank = 0
        for line in lines(of: script) {
            var gap = 0, empty = true
            for scalar in line.unicodeScalars {
                if scalar == " " { gap += 1 } else { gap = 0; empty = false }
                if gap > gapSpaces { return true }
            }
            blank = empty ? blank + 1 : 0
            if blank > blankLines { return true }
        }
        return false
    }

    /// A server's name as the door's access file has it (`hub.SERVER_HOST`): lower-case letters, digits, dots and
    /// hyphens, at most 63, and a letter or a digit first. A name with another letter can look like another server.
    public static func isHost(_ host: String) -> Bool {
        let units = Array(host.utf8)
        guard let first = units.first, units.count <= 63, isLetterOrDigit(first) else { return false }
        return units.allSatisfy { isLetterOrDigit($0) || $0 == 0x2D || $0 == 0x2E }
    }

    private static func isLetterOrDigit(_ unit: UInt8) -> Bool { (0x61...0x7A).contains(unit) || (0x30...0x39).contains(unit) }

    /// The card is the door's card of this server: its title and its three answers name it, byte for byte, and the
    /// name is a server's. The Mac signs a server's mode (Full access) and a run only on such a card.
    public static func names(host: String, title: String, answers given: [String]) -> Bool {
        isHost(host) && same(title, Self.title(host: host)) && given.count == 3
            && zip(given, answers(host: host)).allSatisfy { same($0, $1) }
    }

    /// What the card draws for these details, when that is one code block and nothing else: its text, byte for byte as
    /// the app's own parser gives it to the view (`MessageBlock.parse`, `MessageText`). nil for anything else: words
    /// beside the block, two blocks, or no block.
    public static func shown(details: String) -> String? {
        let blocks = MessageBlock.parse(details)
        guard blocks.count == 1, blocks[0].kind == .code else { return nil }
        return blocks[0].text
    }

    /// Why this Mac does not sign on a door card.
    public enum Refusal: Error, Equatable, Sendable {
        /// The card carries no script: a hub or a manager from before API 1.125.
        case noScript
        /// The title or the answers do not name the server of the call, or the name is no server's.
        case otherServer
        /// The script holds a character that is not printable ASCII or a line feed.
        case hidden(String)
        /// The script is longer than a card shows whole, or padded with blanks.
        case padded
        /// The card's own words hold code, which would stand beside the script as a second script.
        case decoy
        /// What the card draws under Script is not the script that it carries.
        case notShown
        /// The hash of the server and the script is not the hash that the hub gave.
        case otherHash

        /// One plain line for the owner, where a write that did not go is said.
        public func line(by agent: String) -> String {
            switch self {
            case .noScript:
                "This card does not carry its script, so this Mac cannot check what Run it once would sign. Ask \(agent) for a new card."
            case .otherServer:
                "This card's title and answers do not name the server of its script, so nothing was signed. Ask \(agent) for a new card."
            case .hidden(let code):
                "The script holds a character that is not plain text (\(code)), so nothing was signed. Ask \(agent) for a new card."
            case .padded:
                "The script is too long or has wide gaps that can hide a command, so nothing was signed. Ask \(agent) for a new card."
            case .decoy:
                "This card shows code outside its script, so nothing was signed. Ask \(agent) for a new card."
            case .notShown:
                "The card does not show the whole script that it asks for, so nothing was signed. Ask \(agent) for a new card."
            case .otherHash:
                "The script on this card is not the script that the door refused, so nothing was signed. Ask \(agent) for a new card."
            }
        }
    }

    /// The line for a card with no script from a hub that sends none yet (before API 1.125, which the owner feature
    /// `door_mode_set` marks): a new card of that hub would carry no script either, so the hub is what changes.
    public static let olderHub = "This hub does not send the script of this card yet, so this Mac cannot check what Run it once would sign. Update the hub."

    /// The call hash of a door card, when this Mac computed it itself from what the card shows and it is the hash
    /// that the hub gave; else the reason why the Mac does not sign. Only for the door's card of a run: an item with a
    /// `door_host`. `words` are the card's other words that the views draw as Markdown (its why and what it needs
    /// from him): they hold no backtick, so that no second code block stands on the card beside the script.
    public static func checked(title: String, answers given: [String], host: String, call: String, script: String?,
                               details: String?, words: [String] = []) -> Result<String, Refusal> {
        guard let script, script.unicodeScalars.contains(where: { $0 != " " && $0 != "\n" && $0 != "\t" }) else {
            return .failure(.noScript)      // none, or blanks alone
        }
        guard names(host: host, title: title, answers: given) else { return .failure(.otherServer) }
        if let code = hidden(in: script) { return .failure(.hidden(code)) }
        guard script.unicodeScalars.count <= scriptCharacters, lines(of: script).count <= scriptLines,
              !padded(script) else { return .failure(.padded) }
        guard words.allSatisfy({ !$0.unicodeScalars.contains("`") }) else { return .failure(.decoy) }
        // What the view draws is the block's text; the script's last line feed ends the block's last line.
        let body = script.hasSuffix("\n") ? String(script.dropLast()) : script
        guard let details, same(details, Self.details(script: script)),
              let shown = shown(details: details), same(shown, body) else { return .failure(.notShown) }
        let computed = hash(target: host, action: run, arguments: [], content: Data(script.utf8))
        guard same(computed, call) else { return .failure(.otherHash) }
        return .success(computed)
    }

    /// The same bytes. A String's own `==` takes two spellings of one accented letter as equal, and they are two
    /// scripts with two hashes.
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
}

/// **A server's mode at the door** (the door-modes proposal; the owner's "Yes, as shown" of 11 November 2026 to the row
/// "Managed by <agent>" with Auto and Full access): Auto, the default, where a root script with no box needs his yes,
/// and Full access, where every root script of the agent that holds the server runs with no card.
public enum DoorMode: String, Sendable, CaseIterable, Equatable {
    case auto, full
}

/// The receipt of `POST /ui/door/mode` (owner feature `door_mode_set`, API 1.125). `changed` says that the hub carries
/// the statement now, not that the door took it: the hub checks no signature, and `GET /ui/servers` gives the door's
/// own word of each server (`mode_door`).
public struct DoorModeReceipt: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let host: String
    public let mode: String
    public let at: Int
    public let changed: Bool
}

/// `POST /ui/door/mode`: the owner's signed mode of one server, with no Needs-you item.
public enum DoorModeCommand {
    /// The hub carries a statement of this server that is as new as the one sent, or newer, of this time: the door
    /// takes only a newer one, so the next statement is signed with a later time.
    public struct Newer: Error, Equatable, Sendable {
        public let at: Int
        public let words: String
    }

    /// The seconds that a statement's time may be ahead of the hub's and the door's clock (`door.mode_statement`).
    public static let ahead = 300

    /// The time of the next statement: now, and later than the newest statement that the hub carries for the server
    /// (`mode_at` of `GET /ui/servers`), so that two changes in one second are two statements of two times. nil when
    /// that would be further ahead than the door takes: this Mac's clock is far behind, and no statement of now
    /// would end the mode that stands.
    public static func time(now: Int, after newest: Int?) -> Int? {
        guard let newest, newest >= now else { return now }
        return newest - now < ahead ? newest + 1 : nil
    }

    public static func body(requestID: UUID, database: String, host: String, statement: String,
                            signature: String) throws -> Data {
        guard DoorCall.isHost(host), !statement.isEmpty, statement.utf8.count <= 1024, !statement.contains(where: \.isNewline),
              let der = Data(base64Encoded: signature), (8...80).contains(der.count) else { throw HubError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: ["request_id": requestID.uuidString.lowercased(), "db": database,
                                                           "host": host, "statement": statement, "signature": signature],
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The hub's 409 that names the time of its newest statement of the server, or nil for every other answer.
    public static func newer(status: Int, body: Data) -> Newer? {
        guard status == 409, let answer = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let number = answer["at"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let at = number as? Int else { return nil }
        return Newer(at: at, words: String((answer["error"] as? String ?? HubError.unexplained).prefix(500)))
    }

    /// The receipt, checked against what was sent.
    public static func receipt(_ data: Data, requestID: UUID, client: String, host: String, mode: DoorMode,
                               at: Int) throws -> DoorModeReceipt {
        let receipt = try JSONDecoder().decode(DoorModeReceipt.self, from: data)
        guard receipt.ok, receipt.request_id == requestID.uuidString.lowercased(), receipt.client == client,
              receipt.host == host, receipt.mode == mode.rawValue, receipt.at == at else { throw HubError.invalidResponse }
        return receipt
    }
}
