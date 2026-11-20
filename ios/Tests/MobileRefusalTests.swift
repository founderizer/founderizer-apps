import FleetCore
import Foundation
import Testing
@testable import FleetMobile

/// **The Spanish of the real catalog** (`app/Localization/Localizable.xcstrings`) as a table of words for a check's own task,
/// as the Mac's tests have it (`SpanishTable` in `FleetCoreTests`, of which this is the few lines that the phone's checks
/// need): a check that runs under it runs the real Spanish and not a copy of it, so an edit of a line fails the check that
/// holds its words. Nothing outside the check's task sees it, and the folder that it writes is removed after.
enum PhoneSpanish {
    /// The catalog, from this file's place in `app/ios/Tests`.
    static let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Localization").appendingPathComponent("Localizable.xcstrings")

    /// The Spanish text of each key of the catalog that has one text (the keys with plural forms have none here).
    static func words() throws -> [String: String] {
        let data = try Data(contentsOf: catalog)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        var out: [String: String] = [:]
        for (key, entry) in strings {
            let spanish = (entry["localizations"] as? [String: Any])?["es"] as? [String: Any]
            if let unit = spanish?["stringUnit"] as? [String: Any], let value = unit["value"] as? String { out[key] = value }
        }
        return out
    }

    /// Runs `body` with the catalog's Spanish as the table of the language of the device, for this task only.
    static func run<T>(_ body: () throws -> T) throws -> T {
        let table = try words()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spanish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("es.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let strings = table.map { "\"\(escaped($0.key))\" = \"\(escaped($0.value))\";" }.joined(separator: "\n")
        try strings.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: folder))
        return try Localized.$bundle.withValue(bundle) { try body() }
    }

    /// A text as the old-style `.strings` file writes it.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

/// **`app/vectors/refusal-codes.json`**, the hub's refusal words by code (UI-API.md 1.181), as the Mac's tests read it
/// (`RefusalVectors`): each code with the English of its sentence, `{name}` where a name goes, and the names that it holds.
enum PhoneRefusalVectors {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors").appendingPathComponent("refusal-codes.json")

    /// The value of each name in a check: a server, an address and an agent's role.
    static let examples = ["server": "vps-2", "address": "100.64.0.9", "agent": "Customer Support"]

    struct Entry {
        let code: String
        let template: String
        let holes: [String]

        /// What the hub writes into `error`: the English with each name filled.
        var english: String {
            holes.reduce(template) { $0.replacingOccurrences(of: "{\($1)}", with: PhoneRefusalVectors.examples[$1] ?? $1) }
        }

        /// The key of the app's sentence for this code: the English with `%@` where a name goes.
        var key: String {
            holes.reduce(template) { $0.replacingOccurrences(of: "{\($1)}", with: "%@") }
        }

        /// The names in the order that the English holds them, a name that it holds twice twice: what the app's sentence
        /// puts into its `%@`, one after the other (`holes` lists each name once).
        var places: [String] {
            template.components(separatedBy: "{").dropFirst().compactMap { part in
                part.range(of: "}").map { String(part[..<$0.lowerBound]) }
            }.filter(holes.contains)
        }

        var names: [String: RefusalName] {
            Dictionary(uniqueKeysWithValues: holes.map { ($0, RefusalName.text(PhoneRefusalVectors.examples[$0] ?? $0)) })
        }

        /// The refusal that the hub sends for this code, as `HubRefusal.read` makes it.
        func refusal(status: Int = 409) -> HubRefusal {
            HubRefusal(status: status, hubWords: english, code: code, names: names)
        }
    }

    static func load() throws -> [Entry] {
        let data = try Data(contentsOf: file)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let codes = try #require(json["codes"] as? [String: String])
        let holes = try #require(json["holes"] as? [String: [String]])
        return codes.keys.sorted().map { Entry(code: $0, template: codes[$0] ?? "", holes: holes[$0] ?? []) }
    }
}

/// **A refusal of the hub, on the phone** (the iPhone piece of `hub-refusal-words-design.md`; the owner's "Yes, as shown" of
/// 16 November 2026). A refusal is one `HubRefusal`, which the one decoder makes of an answer: the hub's English line, its
/// code and its names. The phone says the app's own words for a code that it knows, in the language of the device, and the
/// hub's English for every other; **on an English phone it says the same characters as before**. A request that the hub
/// refused keeps the refusal as fields, and the line under it is made when it is read.
@Suite("A refusal of the hub, on the phone")
struct MobileRefusalTests {
    private let hub = try! MobileClient.address("http://100.96.10.20:8765")

    /// The refusal that the phone makes of an answer of `status` with this body, the way a real answer is read.
    private func hubRefused(_ status: Int, _ body: String) -> MobileError {
        let response = HTTPURLResponse(url: hub, statusCode: status, httpVersion: nil, headerFields: nil)!
        do {
            _ = try MobileClient.check(response, data: Data(body.utf8))
            Issue.record("A \(status) must not read as an answer.")
        } catch let error as MobileError {
            return error
        } catch {
            Issue.record("Another error: \(error)")
        }
        return .noAnswer
    }

    /// The refusal inside an error, or a failed check.
    private func refusal(of error: MobileError) -> HubRefusal {
        guard case .refusal(let refusal, _) = error else {
            Issue.record("That is no refusal of the hub: \(error)")
            return HubRefusal(status: 0, hubWords: "")
        }
        return refusal
    }

    private func request() -> PendingRequest {
        PendingRequest(hub: hub, database: "gen-1", client: "local", text: "Ship it on Monday.")
    }

    private func outbox() -> Outbox {
        Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(UUID().uuidString)/pending.json"))
    }

    // MARK: What the phone reads

    @Test("A refusal with a code and names carries both, and its status")
    func aCodeAndNames() {
        let error = hubRefused(409, #"{"error": "vps-2 sent no reading in the last 10 minutes: check that it is on", "code": "server_silent", "names": {"server": "vps-2"}}"#)
        #expect(refusal(of: error) == HubRefusal(status: 409, hubWords: "vps-2 sent no reading in the last 10 minutes: check that it is on",
                                                  code: "server_silent", names: ["server": "vps-2"]))
        #expect(error.auth == nil && error.isDefinitive)
    }

    @Test("A refusal with a code and no names carries the code")
    func aCodeAndNoNames() {
        let read = refusal(of: hubRefused(409, #"{"error": "hub generation changed; refresh state", "code": "hub_changed"}"#))
        #expect(read.code == "hub_changed" && read.names.isEmpty && read.hubWords == "hub generation changed; refresh state")
    }

    @Test("A refusal with no code is the hub's line alone, as an older hub sends it")
    func noCode() {
        let read = refusal(of: hubRefused(409, #"{"error": "atlas is in setup"}"#))
        #expect(read == HubRefusal(status: 409, hubWords: "atlas is in setup"))
        #expect(read.code == nil && read.names.isEmpty && read.words == "atlas is in setup")
    }

    @Test("A code that the app does not know is carried, and the hub's line is what it says")
    func anUnknownCode() {
        let read = refusal(of: hubRefused(409, #"{"error": "the moon is in the wrong phase", "code": "moon_phase", "names": {"phase": "waning"}}"#))
        #expect(read.code == "moon_phase" && read.names == ["phase": "waning"])
        #expect(read.words == "the moon is in the wrong phase")
    }

    @Test("The reason of this phone's key is read from the same body, beside the hub's words and code")
    func theAuthReasonIsKept() {
        let error = hubRefused(403, #"{"error": "device key does not match", "auth": "device_key_mismatch", "code": "key_changed"}"#)
        #expect(error.auth == "device_key_mismatch" && error.isDefinitive)
        let read = refusal(of: error)
        #expect(read.hubWords == "device key does not match" && read.code == "key_changed")
        // A refusal of this phone's key says what to do, in the phone's own words, and never the hub's.
        #expect(error.errorDescription == MobileError.authWords("device_key_mismatch"))
        #expect(error.notSentWords == MobileError.authWords("device_key_mismatch"))
    }

    @Test("A refusal that carried no words says so in the phone's own sentence, not the Mac's")
    func noReason() throws {
        for body in ["", "{}", "not json", #"{"error": 5}"#, #"{"error": "  "}"#] {
            let error = hubRefused(409, body)
            #expect(refusal(of: error).hubWords == HubError.unexplained, "\(body)")
            #expect(error.errorDescription == "The hub refused it: The hub gave no reason.", "\(body)")
            #expect(error.notSentWords == "Not sent: The hub gave no reason.", "\(body)")
        }
        try PhoneSpanish.run {
            let error = hubRefused(409, "")
            #expect(error.errorDescription == "El hub lo rechazó: El hub no dio ningún motivo.")
            #expect(error.notSentWords == "No enviado: El hub no dio ningún motivo.")
        }
    }

    // MARK: An English phone says what it always said

    @Test("An English phone says the hub's line as it always did: a sentence, with no code or name in the way")
    func englishIsAsItWas() {
        let cases: [(HubRefusal, String)] = [
            (HubRefusal(status: 409, hubWords: "atlas is in setup"), "Atlas is in setup."),
            (HubRefusal(status: 409, hubWords: "hub generation changed; refresh state", code: "hub_changed"),
             "Hub generation changed; refresh state."),
            // The phone makes the hub's line a sentence, a name at its start included: its own way, kept.
            (HubRefusal(status: 409, hubWords: "vps-2 sent no reading in the last 10 minutes: check that it is on",
                        code: "server_silent", names: ["server": "vps-2"]),
             "Vps-2 sent no reading in the last 10 minutes: check that it is on."),
            (HubRefusal(status: 403, hubWords: "127.0.0.1 is not an owner device. See \"owner_devices\" in team.json.",
                        code: "not_owner_device", names: ["address": "127.0.0.1"]),
             "127.0.0.1 is not an owner device. See \"owner_devices\" in team.json."),
            (HubRefusal(status: 409, hubWords: "Customer Support is in the middle of a turn. Move it when the turn ends.",
                        code: "agent_mid_turn", names: ["agent": "Customer Support"]),
             "Customer Support is in the middle of a turn. Move it when the turn ends."),
            (HubRefusal(status: 404, hubWords: "no such agent", code: "no_such_agent"), "No such agent."),
            (HubRefusal(status: 503, hubWords: HubError.unexplained), "The hub gave no reason."),
        ]
        for (refusal, sentence) in cases {
            let error = MobileError.refusal(refusal, auth: nil)
            #expect(error.errorDescription == "The hub refused it: \(sentence)")
            #expect(error.notSentWords == "Not sent: \(sentence)")
        }
    }

    @Test("Every code of the hub's table reads on an English phone exactly as the hub's English did before codes")
    func everyCodeInEnglish() throws {
        let table = try PhoneRefusalVectors.load()
        #expect(table.count >= 25)
        for entry in table {
            let error = MobileError.refusal(entry.refusal(), auth: nil)
            // The old line was the hub's own English, made a sentence: nothing of the code or the table reaches it.
            #expect(error.errorDescription == "The hub refused it: \(MobileError.sentence(entry.english))", "\(entry.code)")
            #expect(error.notSentWords == "Not sent: \(MobileError.sentence(entry.english))", "\(entry.code)")
        }
    }

    // MARK: A phone in Spanish says the table's line

    @Test("A phone in Spanish says the table's line for a code that it knows, and a name stays as the hub wrote it")
    func spanishForAKnownCode() throws {
        try PhoneSpanish.run {
            let changed = MobileError.refusal(HubRefusal(status: 409, hubWords: "hub generation changed; refresh state",
                                                         code: "hub_changed"), auth: nil)
            #expect(changed.errorDescription == "El hub lo rechazó: El hub cambió. Actualiza y vuelve a intentarlo.")
            #expect(changed.notSentWords == "No enviado: El hub cambió. Actualiza y vuelve a intentarlo.")
            let silent = MobileError.refusal(HubRefusal(status: 409, hubWords: "vps-2 sent no reading in the last 10 minutes: check that it is on",
                                                        code: "server_silent", names: ["server": "vps-2"]), auth: nil)
            #expect(silent.notSentWords == "No enviado: vps-2 no envió ninguna lectura en los últimos 10 minutos: comprueba que esté encendido.")
        }
    }

    /// **What a phone in Spanish says for one code of the hub, and it needs no list of the codes that wait.** The words are the
    /// catalog's line where the catalog has one under the code's key, and the hub's own line, made a sentence, where it has
    /// none: a code that waits for the owner's yes to its words has no Spanish yet, and the phone then says what the hub
    /// said (`HubRefusal.words`). Each is read inside the Spanish frame, in the refusal, in "Not sent: ..." and in the line
    /// under a refused request. Run it inside `PhoneSpanish.run`. (It reads the catalog's plain lines under the key made of
    /// the hub's English with `%@` for each name, and puts the names into the line's `%@` one after the other, in the
    /// order that the English holds them, as the phone's format does for `browser_no_room`'s server and agent. A line
    /// with a positional `%1$@`, with a `%` of its own or with a name left out fails here; a code whose Spanish has
    /// plural or device forms is not among the plain lines, so it reads as one with no Spanish. When the first such
    /// code gets its Spanish, this check has to learn that form.)
    private func holdsInSpanish(_ entry: PhoneRefusalVectors.Entry, catalog spanish: [String: String]) {
        let words: String
        if let line = spanish[entry.key] {
            let values = entry.places.map { PhoneRefusalVectors.examples[$0] ?? $0 }
            #expect(line.components(separatedBy: "%@").count - 1 == values.count, "\(entry.code): a place for each name")
            words = values.reduce(line) { text, value in      // each name into the next %@, in the order of the English
                guard let at = text.range(of: "%@") else { return text }
                return text.replacingCharacters(in: at, with: value)
            }
            #expect(!words.contains("{") && !words.contains("%"), "\(entry.code)")
        } else {
            words = MobileError.sentence(entry.english)
        }
        let error = MobileError.refusal(entry.refusal(), auth: nil)
        #expect(error.errorDescription == "El hub lo rechazó: \(words)", "\(entry.code)")
        #expect(error.notSentWords == "No enviado: \(words)", "\(entry.code)")
        var refused = request()
        refused.refuse(entry.refusal())
        #expect(refused.notSentLine == "No enviado: \(words)", "\(entry.code)")
    }

    @Test("Every code of the hub's table reads in Spanish: the catalog's line where it has one, and the hub's own line where it has none")
    func everyCodeInSpanish() throws {
        let table = try PhoneRefusalVectors.load()
        let spanish = try PhoneSpanish.words()
        try PhoneSpanish.run {
            for entry in table { holdsInSpanish(entry, catalog: spanish) }
        }
    }

    /// **The 25 codes of slice 1**, whose Spanish the owner approved ("Yes, as shown" of 16 November 2026, to the table of
    /// `hub-refusal-words-design.md`). None of them waits: each has its line in the catalog. A code that the hub adds
    /// later is not in this list: until the owner says yes to its words it has none, and the phone says the hub's line.
    private static let sliceOne = [
        "hub_changed", "hub_changed_sending", "team_changed", "team_changed_lines", "no_such_agent", "no_such_server",
        "no_such_task", "login_as_text", "login_as_file", "login_not_shown", "command_reused", "command_reused_message",
        "command_reused_file", "command_reused_content", "command_interrupted", "revision_unreadable", "server_silent",
        "server_no_service", "request_answered", "request_unknown", "request_unknown_ended", "not_owner_device",
        "not_owner_device_no_code", "agent_mid_turn", "agent_open_signin",
    ]

    @Test("Each of the 25 codes of slice 1 has its Spanish line in the catalog: none of them waits for the owner")
    func sliceOneHasItsSpanish() throws {
        #expect(Self.sliceOne.count == 25 && Set(Self.sliceOne).count == 25)
        let table = try PhoneRefusalVectors.load()
        let spanish = try PhoneSpanish.words()
        for code in Self.sliceOne {
            let entry = try #require(table.first(where: { $0.code == code }), "\(code) is not in the vectors")
            _ = try #require(spanish[entry.key], "\(code) has no Spanish")
        }
    }

    @Test("A code that waits for the owner's yes has no Spanish, and a phone in Spanish says the hub's own line for it")
    func aCodeThatWaitsIsSaidInTheHubsWords() throws {
        let spanish = try PhoneSpanish.words()
        // Codes that the catalog cannot have, made up for this check, so that the vectors file is never edited.
        let moon = PhoneRefusalVectors.Entry(code: "made_up_moon", template: "the moon is not in the sky", holes: [])
        let seen = PhoneRefusalVectors.Entry(code: "made_up_moon_seen", template: "{server} cannot see the moon", holes: ["server"])
        try PhoneSpanish.run {
            for entry in [moon, seen] {
                #expect(spanish[entry.key] == nil, "\(entry.code) is in the catalog")
                holdsInSpanish(entry, catalog: spanish)
            }
            // The words themselves: the hub's English, made a sentence as the phone always made it, in the Spanish frame.
            #expect(MobileError.refusal(moon.refusal(), auth: nil).notSentWords == "No enviado: The moon is not in the sky.")
            #expect(MobileError.refusal(seen.refusal(), auth: nil).errorDescription == "El hub lo rechazó: Vps-2 cannot see the moon.")
            var refused = request()
            refused.refuse(seen.refusal())
            #expect(refused.notSentLine == "No enviado: Vps-2 cannot see the moon.")
        }
    }

    @Test("The hub's English stands in Spanish for a code that the app does not know, for no code, and for a name that the words need")
    func theHubsEnglishStandsInSpanish() throws {
        try PhoneSpanish.run {
            let unknown = MobileError.refusal(HubRefusal(status: 409, hubWords: "the moon is in the wrong phase", code: "moon_phase"), auth: nil)
            #expect(unknown.notSentWords == "No enviado: The moon is in the wrong phase.")
            let none = MobileError.refusal(HubRefusal(status: 409, hubWords: "atlas is in setup"), auth: nil)
            #expect(none.errorDescription == "El hub lo rechazó: Atlas is in setup.")
            // A known code whose name is missing: the app's sentence cannot be said, so the hub's line shows.
            let nameless = MobileError.refusal(HubRefusal(status: 409, hubWords: "vps-2 sent no reading in the last 10 minutes: check that it is on",
                                                          code: "server_silent"), auth: nil)
            #expect(nameless.notSentWords == "No enviado: Vps-2 sent no reading in the last 10 minutes: check that it is on.")
        }
    }

    // MARK: The line under a request that did not go

    @Test("A refused request keeps the hub's refusal as fields, and its line is made when it is read, in the language of that day")
    func theLineIsMadeWhenItIsRead() throws {
        let outbox = outbox()
        defer { try? FileManager.default.removeItem(at: outbox.file.deletingLastPathComponent()) }
        var refused = request()
        refused.refuse(because: hubRefused(409, #"{"error": "vps-2 sent no reading in the last 10 minutes: check that it is on", "code": "server_silent", "names": {"server": "vps-2"}}"#))
        try outbox.save(refused)
        let kept = try #require(try outbox.load())
        // What is on disk is the hub's own refusal and the mark, in English, whatever the language of the phone.
        #expect(kept.refusal == "Hub refused the request (409): vps-2 sent no reading in the last 10 minutes: check that it is on")
        #expect(kept.hubRefusal?.code == "server_silent" && kept.hubRefusal?.names == ["server": "vps-2"])
        // An English phone: the hub's line as it was when the phone made it at the send.
        #expect(kept.notSentLine == "Not sent: Vps-2 sent no reading in the last 10 minutes: check that it is on.")
        // The same record on a phone in Spanish: the table's line, and the record itself is as it was.
        try PhoneSpanish.run {
            #expect(kept.notSentLine == "No enviado: vps-2 no envió ninguna lectura en los últimos 10 minutos: comprueba que esté encendido.")
            #expect(kept.refusal == "Hub refused the request (409): vps-2 sent no reading in the last 10 minutes: check that it is on")
        }
    }

    @Test("A request that no refusal stopped has no line, and a refused one always has")
    func theMarkAndTheLine() {
        var waiting = request()
        #expect(waiting.refusal == nil && waiting.notSentLine == nil)
        waiting.refuse(because: .refusal(HubRefusal(status: 409, hubWords: "atlas is in setup"), auth: nil))
        #expect(waiting.refusal != nil && waiting.notSentLine == "Not sent: Atlas is in setup.")
        // A refusal that carried no words: the phone's own sentence.
        waiting.refuse(because: .refusal(HubRefusal(status: 503, hubWords: HubError.unexplained), auth: nil))
        #expect(waiting.refusal != nil && waiting.notSentLine == "Not sent: The hub gave no reason.")
    }

    @Test("A refusal of this phone's key keeps the phone's own words, as it did")
    func theKeyKeepsItsOwnWords() {
        var refused = request()
        let error = MobileError.refusal(HubRefusal(status: 403, hubWords: "device key does not match"), auth: "device_key_mismatch")
        refused.refuse(because: error)
        #expect(refused.hubRefusal == nil)
        #expect(refused.refusal == MobileError.authWords("device_key_mismatch"))
        #expect(refused.notSentLine == MobileError.authWords("device_key_mismatch"))
        // A definitive error of the phone's own that is no refusal keeps its words too.
        var routes = request()
        routes.refuse(because: .noPhoneRoutes)
        #expect(routes.hubRefusal == nil && routes.refusal == MobileError.noPhoneRoutes.errorDescription)
    }

    @Test("A request that an older version of the phone refused is read as it was, in either language")
    func anOlderRecord() throws {
        // The older phone wrote its own words as text: "Not sent: ..." made when it wrote them.
        var older = request()
        older.refusal = "Not sent: Atlas is in setup."
        let outbox = outbox()
        defer { try? FileManager.default.removeItem(at: outbox.file.deletingLastPathComponent()) }
        try outbox.save(older)
        let data = try Data(contentsOf: outbox.file)
        #expect(!String(decoding: data, as: UTF8.self).contains("hubRefusal"))
        let loaded = try #require(try outbox.load())
        #expect(loaded.refusedByHub == nil && loaded.hubRefusal == nil)
        #expect(loaded.notSentLine == "Not sent: Atlas is in setup.")
        try PhoneSpanish.run {
            #expect(loaded.notSentLine == "Not sent: Atlas is in setup.")
        }
        // Registered login text: a sentence of the app's own that no status stands in front of, kept as it is.
        var secret = request()
        secret.refusal = "The hub refused registered login text (422). Saved text and drafts were removed."
        #expect(secret.refusedByHub == nil && secret.notSentLine == secret.refusal)
    }

    // MARK: What a line decides by: a code, never the words

    @Test("A press on a ping reads what the hub refused by its code, also when the words are in Spanish")
    func thePressReadsTheCode() throws {
        func words(_ status: Int, _ code: String?, _ hubWords: String) -> String {
            NeedPress.words(MobileError.refusal(HubRefusal(status: status, hubWords: hubWords, code: code), auth: nil), need: 7)
        }
        try PhoneSpanish.run {
            // The code decides: the hub's words here say something else altogether.
            #expect(words(409, "request_answered", "x") == "Ya respondida.")
            #expect(words(409, "hub_changed", "x") == "Los registros del hub cambiaron después de la notificación. Abre Founderizer y responde allí.")
            #expect(words(409, "hub_changed_sending", "x") == "Los registros del hub cambiaron después de la notificación. Abre Founderizer y responde allí.")
            // A refusal with another code is read by that code alone, whatever the hub's words hold.
            let other = words(409, "command_reused", "owner request is already answered")
            #expect(other != "Ya respondida." && other.hasPrefix("El hub lo rechazó: "))
            // The status is the line's own test: a 404 is a request that is gone, whatever its code.
            #expect(words(404, "hub_changed", "x") == "Esta solicitud ya no está en el hub.")
        }
        #expect(words(409, "request_answered", "x") == "Already answered.")
        #expect(words(409, "hub_changed_sending", "x") == "The hub's records changed after the ping. Open Founderizer and answer there.")
        let other = words(409, "command_reused", "owner request is already answered")
        #expect(other != "Already answered." && other.hasPrefix("The hub refused it: ") && other.hasSuffix(" Open Founderizer to answer."))
    }

    @Test("A press on a ping reads the old phrase of the hub's English when the hub sends no code")
    func thePressReadsAnOlderHub() throws {
        func words(_ status: Int, _ hubWords: String) -> String {
            NeedPress.words(MobileError.refusal(HubRefusal(status: status, hubWords: hubWords), auth: nil), need: 7)
        }
        #expect(words(409, "owner request is already answered") == "Already answered.")
        #expect(words(409, "hub generation changed; refresh state before sending")
                == "The hub's records changed after the ping. Open Founderizer and answer there.")
        #expect(words(404, "owner request does not exist") == "This request is no longer on the hub.")
        try PhoneSpanish.run {
            #expect(words(409, "owner request is already answered") == "Ya respondida.")
            #expect(words(404, "owner request does not exist") == "Esta solicitud ya no está en el hub.")
        }
    }

    @Test("The enrollment of a phone that the hub does not know still says so, by the code or by the old phrase")
    func theEnrollmentRefusal() throws {
        func words(_ status: Int, _ code: String?, _ hubWords: String) -> String {
            MobileError.enrollWords(.refusal(HubRefusal(status: status, hubWords: hubWords, code: code), auth: nil))
        }
        let unknown = "Your hub does not know this phone. Add it on your Mac."
        // By the code, whatever the words say.
        #expect(words(403, "not_owner_device", "x") == unknown)
        #expect(words(403, "not_owner_device_no_code", "x") == unknown)
        // For a hub that sends no code: the phrase, as before.
        #expect(words(403, nil, "127.0.0.1 is not an owner device. See \"owner_devices\" in team.json.") == unknown)
        // Another refusal is the code that did not work, and too many of them is its own sentence.
        #expect(words(403, nil, "that code is not valid") == MobileError.codeDidNotWork)
        #expect(words(403, "code_not_valid", "127.0.0.1 is not an owner device") == MobileError.codeDidNotWork)
        #expect(words(429, nil, "too many wrong codes; wait an hour, then make a new code") == MobileError.tooManyCodes)
        try PhoneSpanish.run {
            #expect(words(403, "not_owner_device", "x") == "Tu hub no conoce este teléfono. Añádelo en tu Mac.")
            #expect(words(403, nil, "127.0.0.1 is not an owner device. See \"owner_devices\" in team.json.")
                    == "Tu hub no conoce este teléfono. Añádelo en tu Mac.")
        }
    }
}

/// **The words about a key request that stand in the phone's field** (`MobileStore.clarifyDrafts`, Needs
/// clarification): the store holds them in memory for each card of the request, and nothing writes them to the app's
/// settings, where the drafts of an answer are. A key that stayed in a file on the phone, after he pasted it into that
/// field by mistake, is the bug that this holds.
@Suite("The words about a key request", .serialized)
struct ClarifyDraftTests {
    @MainActor @Test("stay in memory only: no setting of the app holds them, and a new launch has none")
    func drafts() {
        let store = MobileStore()
        let words = "Which of the three accounts? sk-ant-api03-EXAMPLEEXAMPLEEXAMPLEEXAMPLE"
        store.setClarifyDraft(words, for: 7)
        #expect(store.clarifyDraft(for: 7) == words)
        // no setting of the app holds the words, under any name
        let kept = UserDefaults.standard.dictionaryRepresentation().map { "\($0.key) \($0.value)" }.joined(separator: "\n")
        #expect(!kept.contains("Which of the three accounts") && !kept.contains("EXAMPLEEXAMPLE"))
        store.setClarifyDraft("", for: 7)
        #expect(store.clarifyDraft(for: 7).isEmpty)
        store.setClarifyDraft(words, for: 8)
        #expect(MobileStore().clarifyDraft(for: 8).isEmpty)        // a new launch has none
    }
}

/// What depends on it: the item of a request on Needs you takes no touch while his answer to it is on its way, and
/// the agent's chat shows that answer as his message. A request that waits with no send must be neither: its line
/// says "Not sent" with Try again, which he must be able to press. The bug that this holds: after a start of the app
/// with a request in the Outbox, the item counted as answered, and Try again on Needs you took no touch.
@Suite("An answer that waits in the Outbox")
struct WaitingAnswerTests {
    @MainActor @Test("is on its way only while a send carries it, to its own request of this hub and generation")
    func goes() throws {
        let hub = try MobileClient.address("http://127.0.0.1:9")
        let request = PendingRequest(hub: hub, database: "gen-1", client: "local", needID: 7, text: "Refund it")
        #expect(MobileStore.goes(request, to: 7, of: hub, database: "gen-1", sending: true))
        // kept from before the start, or stopped by an error: nothing sends it, so the item is his to press
        #expect(!MobileStore.goes(request, to: 7, of: hub, database: "gen-1", sending: false))
        #expect(!MobileStore.goes(request, to: 8, of: hub, database: "gen-1", sending: true))
        #expect(!MobileStore.goes(request, to: 7, of: hub, database: "gen-2", sending: true))
        #expect(!MobileStore.goes(request, to: 7, of: hub, database: nil, sending: true))
        let other = try MobileClient.address("http://127.0.0.1:10")
        #expect(!MobileStore.goes(request, to: 7, of: other, database: "gen-1", sending: true))
    }
}
