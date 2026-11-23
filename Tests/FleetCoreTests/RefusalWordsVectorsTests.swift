import Foundation
import Testing
@testable import FleetCore

/// **The app's own words for the hub's refusal codes** (`RefusalWords`, `HubRefusal.words`; the design
/// `hub-refusal-words-design.md`; UI-API.md 1.181), held to `app/vectors/refusal-codes.json`, the hub's own table:
///
/// - every code of the hub has a case here, with the same English and the same holes, so that a drift is a failed test and
///   never a screen;
/// - on a device whose language is English, for a code that is not known, for none, for a name that is missing and for a
///   language that has no words for the code, the hub's own line shows, character for character;
/// - in Spanish the words of the real catalog show, the owner's three lines verbatim, and a name stays as the hub wrote it.
struct RefusalWordsVectorsTests {
    /// **Codes that the hub has and the app has no words for yet.** A slice of the design waits for the
    /// owner's yes to its table before its Spanish ships (`hub-refusal-words-design.md`, "The order, and the size"): the
    /// hub's code is already in the vectors (COORDINATION.md rule 8), the app shows the hub's English for it, as for any
    /// code that it does not know, and the code is named here so that the test that holds every other code to a case
    /// stays green meanwhile. A code in this list that has a case is a fault: the case takes it out of the list.
    /// Waiting now: `knowledge_unread` (a knowledge file that the hub cannot read now, 20 November 2026),
    /// `profile_unread` (an agent's profile that the hub cannot read now, 20 November 2026),
    /// `signature_unchecked` (a phone's yes whose second check could not run, 20 November 2026) and
    /// `about_unreadable` (a message about a task to an agent whose chat cannot read it, 21 November 2026).
    /// `repo_vendor` (a grant of one of the product's own repositories) waited from 20 November 2026 until his "Yes,
    /// use it" of the same
    /// day. The 29 that
    /// waited (`time_passed`, the seven of Google's Connect and Disconnect, the twelve of
    /// the MCP form, `server_name_kept`, the two of the sealed Google file and the six of Telegram) have their cases and
    /// their Spanish since the owner's "Yes, all 29" of 19 November 2026, so the test below holds each of them to the
    /// hub's vector and to the catalog. A new code of the hub is named here until his yes to the Spanish of its slice.
    /// The five of a Drive folder waited from 20 November 2026 until his "Yes, ship them" of the same day.
    /// `card_words_from_tool` (an AI session's words to a card that has its own answers, 20 November 2026) waits too,
    /// and so do `secret_value_asked` (an answer of a request for a new value of a key with another key, or with
    /// that key before its new value, 21 November 2026) and `secret_app_setting` (a new value of an app's setting on
    /// a host, which changes on that host, 21 November 2026).
    /// `teams_off` and `teams_part_missing` (a part of Founderizer for Teams on a fleet that does not have it, or whose hub
    /// has not loaded it, 21 November 2026) wait for the owner's yes to their words and to their Spanish.
    /// `role_sets_contacts_off` and `role_no_set` (a role's set of access of Founderizer for Teams, with contacts.v2
    /// off, or for a role that has no set, 22 November 2026) wait for the same.
    /// The ten of a member's Founderizer app (`join_no_code`, `join_two`, `join_file`, `link_no_agent`,
    /// `link_active`, `link_channel`, `link_file`, `link_from_tool`: Founderizer for Teams, design 4, 22 November 2026;
    /// `link_key`, `link_most`: decision D72) wait for the same.
    private static let waiting: Set<String> = ["about_unreadable", "card_words_from_tool", "join_file", "join_no_code",
                                               "join_two", "knowledge_unread", "link_active", "link_channel",
                                               "link_file", "link_from_tool", "link_key", "link_most",
                                               "link_no_agent", "profile_unread",
                                               "role_no_set", "role_sets_contacts_off", "secret_app_setting",
                                               "secret_value_asked",
                                               "signature_unchecked", "teams_off", "teams_part_missing"]

    /// The codes that have a case: every code of the hub's table that is not waiting.
    private static func known(_ table: RefusalVectors.Table) -> [String] {
        table.codes.keys.filter { !waiting.contains($0) }.sorted()
    }

    private static func names(_ holes: [String]) -> [String: RefusalName] {
        Dictionary(uniqueKeysWithValues: holes.map { ($0, RefusalName.text("sample-\($0)")) })
    }

    /// The hub's English of a code, with each name as `names(_:)` gives it.
    private static func hubEnglish(_ code: String, _ table: RefusalVectors.Table) -> String {
        RefusalVectors.english(code, in: table) { "sample-\($0)" } ?? ""
    }

    private static func refusal(_ code: String, _ table: RefusalVectors.Table, status: Int = 409) -> HubRefusal {
        HubRefusal(status: status, hubWords: hubEnglish(code, table), code: code, names: names(table.holes[code] ?? []))
    }

    // MARK: the table against the hub's

    @Test func everyCodeOfTheHubHasACaseWithTheSameEnglishAndTheSameHoles() throws {
        let table = try RefusalVectors.load()
        #expect(table.codes.count >= 25)
        for code in Self.waiting.sorted() {
            #expect(table.codes[code] != nil, "\(code) is waiting for its words but the hub has no such code")
            #expect(RefusalWords.sentence(code, Self.names(table.holes[code] ?? []), say: RefusalWords.english) == nil,
                    "\(code) has a case: take it out of `waiting`")
        }
        for code in Self.known(table) {
            let holes = table.holes[code] ?? []
            let names = Self.names(holes)
            // The same English: the key of the case, with the names in, is the hub's line character for character.
            #expect(RefusalWords.sentence(code, names, say: RefusalWords.english) == Self.hubEnglish(code, table), "\(code)")
            // The same holes: with a name missing the case says nothing, and a name that the words do not hold changes nothing.
            for missing in holes {
                var short = names
                short[missing] = nil
                #expect(RefusalWords.sentence(code, short, say: RefusalWords.english) == nil, "\(code) without \(missing)")
            }
            var more = names
            more["unrelated"] = "x"
            #expect(RefusalWords.sentence(code, more, say: RefusalWords.english) == Self.hubEnglish(code, table), "\(code)")
        }
        #expect(RefusalWords.sentence("a_code_of_a_later_hub", [:], say: RefusalWords.english) == nil)
    }

    @Test func aNumberIsAsGoodAsATextForAName() {
        let refusal = HubRefusal(status: 409, hubWords: "7 sent no reading in the last 10 minutes: check that it is on",
                                 code: "server_silent", names: ["server": 7])
        #expect(RefusalWords.sentence("server_silent", refusal.names, say: RefusalWords.english)
                == "7 sent no reading in the last 10 minutes: check that it is on")
    }

    // MARK: English, and every case where the hub's own line stands

    @Test func onADeviceInEnglishTheHubsOwnLineShowsForEveryCode() throws {
        let table = try RefusalVectors.load()
        for code in table.codes.keys.sorted() {
            let refusal = Self.refusal(code, table)
            #expect(RefusalWords.words(for: refusal) == nil, "\(code)")
            #expect(refusal.words == refusal.hubWords, "\(code)")
            #expect(HubError.refusal(refusal).errorDescription == "Hub refused the request (409): \(refusal.hubWords)", "\(code)")
        }
    }

    @Test func theHubsOwnLineStandsForACodeThatTheAppDoesNotKnowForNoCodeAndForAMissingName() throws {
        try SpanishTable.run {
            let unknown = HubRefusal(status: 409, hubWords: "a sentence of a later hub", code: "a_code_of_a_later_hub")
            #expect(unknown.words == "a sentence of a later hub")
            let none = HubRefusal(status: 404, hubWords: "no such agent")
            #expect(none.words == "no such agent")
            // The words of `server_silent` hold a server, and this refusal carries none: the hub's own line.
            let missing = HubRefusal(status: 409, hubWords: "vps-2 sent no reading in the last 10 minutes: check that it is on",
                                     code: "server_silent")
            #expect(missing.words == "vps-2 sent no reading in the last 10 minutes: check that it is on")
        }
    }

    /// A language whose table has no words for a code gives the key back, which is the English: the hub's line shows.
    @Test func aLanguageThatHasNoWordsForTheCodeShowsTheHubsLine() throws {
        let table = try RefusalVectors.load()
        try SpanishTable.run(["Some other key": "Otra clave"]) {
            for code in table.codes.keys.sorted() {
                let refusal = Self.refusal(code, table)
                #expect(refusal.words == refusal.hubWords, "\(code)")
            }
        }
    }

    // MARK: Spanish

    /// **The owner's three lines, verbatim** (16 November 2026), with a name as the hub wrote it.
    @Test func theThreeLinesThatTheOwnerApprovedAreAsHeSawThem() throws {
        try SpanishTable.run {
            #expect(HubRefusal(status: 409, hubWords: "hub generation changed; refresh state", code: "hub_changed").words
                    == "El hub cambió. Actualiza y vuelve a intentarlo.")
            #expect(HubRefusal(status: 409, hubWords: "team.json changed meanwhile; reload it", code: "team_changed").words
                    == "La configuración del equipo cambió mientras tanto. Vuelve a cargarla.")
            let silent = HubRefusal(status: 409, hubWords: "vps-2 sent no reading in the last 10 minutes: check that it is on",
                                    code: "server_silent", names: ["server": "vps-2"])
            #expect(silent.words == "vps-2 no envió ninguna lectura en los últimos 10 minutos: comprueba que esté encendido.")
        }
    }

    @Test func inSpanishEveryCodeHasItsWordsWithItsNamesAsTheHubWroteThem() throws {
        let table = try RefusalVectors.load()
        let catalog = try SpanishTable.words()
        try SpanishTable.run(catalog) {
            for code in Self.known(table) {
                let refusal = Self.refusal(code, table)
                // The key of the case is the hub's English with `%@` for each name, and its Spanish is the catalog's.
                var key = table.codes[code] ?? ""
                for name in table.holes[code] ?? [] { key = key.replacingOccurrences(of: "{\(name)}", with: "%@") }
                var spanish = try #require(catalog[key], "no Spanish for \(code): \(key)")
                for name in table.holes[code] ?? [] {
                    // A name can stand more than once in a sentence (drive_folder_unseen names its account twice).
                    let uses = max(1, (table.codes[code] ?? "").components(separatedBy: "{\(name)}").count - 1)
                    for _ in 0..<uses {
                        let at = try #require(spanish.range(of: "%@"), "\(code): the Spanish has no place for \(name)")
                        spanish.replaceSubrange(at, with: "sample-\(name)")
                    }
                }
                #expect(!spanish.contains("%"), "\(code): \(spanish)")
                #expect(refusal.words == spanish, "\(code)")
                #expect(refusal.words != refusal.hubWords, "\(code) was not translated")
                for name in table.holes[code] ?? [] { #expect(refusal.words.contains("sample-\(name)"), "\(code) lost \(name)") }
                // `said` is the same words, for a screen that shows the hub's sentence.
                #expect(HubError.said(HubError.refusal(refusal)) == spanish, "\(code)")
            }
        }
    }

    @Test func theWrapperAndTheFallbackAreInSpanishToo() throws {
        try SpanishTable.run {
            let changed = HubError.refusal(HubRefusal(status: 409, hubWords: "hub generation changed; refresh state", code: "hub_changed"))
            #expect(changed.errorDescription == "El hub rechazó la solicitud (409): El hub cambió. Actualiza y vuelve a intentarlo.")
            #expect(changed.conflict)
            // No words from the hub: the app's own fallback, in Spanish, and no sentence of the hub's to show.
            let silent = HubError.refusal(HubRefusal(status: 503, hubWords: HubError.unexplained))
            #expect(silent.errorDescription == "El hub rechazó la solicitud (503): Respuesta HTTP inesperada.")
            #expect(HubError.said(silent) == nil)
            // A refusal with no code keeps the hub's English inside the Spanish wrapper.
            #expect(HubError.refusal(HubRefusal(status: 404, hubWords: "no such agent")).errorDescription
                    == "El hub rechazó la solicitud (404): no such agent")
        }
    }

    // MARK: the lines that decide, in Spanish

    /// **Each line of the Mac app that decides by a refusal, under the Spanish table**: the words that the owner reads are
    /// Spanish, the old phrase is not in them, and the line still decides, by the code. An older hub (no code) is read by its
    /// English as before.
    @Test func theSevenLinesThatDecideStillDecideInSpanish() throws {
        let table = try RefusalVectors.load()
        // The line, the codes that it meets, and what it decides by.
        let lines: [(String, [String], RefusalMeaning)] = [
            ("AgentDeleteCard.send", ["team_changed", "team_changed_lines"], .teamChanged),
            ("AgentSetupWizard.rename", ["team_changed", "team_changed_lines"], .teamChanged),
            ("AgentSetupWizard.step", ["team_changed", "team_changed_lines"], .teamChanged),
            ("AgentSetupWizard.place", ["team_changed", "team_changed_lines"], .teamChanged),
            ("AgentSetupView.rename", ["team_changed", "team_changed_lines"], .teamChanged),
            ("AddAgentView.add", ["team_changed", "team_changed_lines"], .teamChanged),
            ("SecretEntryView.answer", ["request_answered"], .requestAnswered),
        ]
        try SpanishTable.run {
            for (line, codes, meaning) in lines {
                for code in codes {
                    let refusal = Self.refusal(code, table)
                    #expect(refusal.words != refusal.hubWords, "\(line): \(code) reached the owner in English")
                    #expect(!refusal.words.lowercased().contains(meaning.phrase), "\(line): \(code)")
                    #expect(refusal.means(meaning), "\(line): \(code) is no longer read")
                }
                // An older hub: no code, the English of the hub, which is what the line looked for before.
                let older = HubRefusal(status: 409, hubWords: Self.hubEnglish(codes[0], table))
                #expect(older.means(meaning), "\(line): an older hub")
            }
        }
    }
}
