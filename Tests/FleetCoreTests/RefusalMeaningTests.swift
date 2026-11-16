import Foundation
import Testing
@testable import FleetCore

/// **What the apps decide by in a refusal reads the code** (`RefusalMeaning`, `HubRefusal.means(_:)`): the hub's code
/// first, and for an older hub that sends none the phrase of its English that the apps looked for before. The words that the
/// owner reads decide nothing, in any language.
struct RefusalMeaningTests {
    private func refusal(_ words: String, code: String? = nil, names: [String: RefusalName] = [:]) -> HubRefusal {
        HubRefusal(status: 409, hubWords: words, code: code, names: names)
    }

    // MARK: the hub's table

    /// Each meaning's codes are the hub's, and their English holds the phrase that an older hub is read by: the code and
    /// the phrase say the same thing. No other code of the table has that phrase, or a refusal with a code and one without
    /// would be read differently.
    @Test func eachMeaningsCodesAreTheHubsAndAgreeWithItsPhrase() throws {
        let table = try RefusalVectors.load()
        for meaning in RefusalMeaning.allCases {
            #expect(!meaning.codes.isEmpty, "\(meaning)")
            for code in meaning.codes {
                let english = try #require(table.codes[code], "\(meaning) names \(code), which the hub's table does not have")
                #expect(english.lowercased().contains(meaning.phrase), "\(code): \(english)")
            }
            for (code, english) in table.codes where english.lowercased().contains(meaning.phrase) {
                #expect(meaning.codes.contains(code), "\(code) holds \"\(meaning.phrase)\" and is no code of \(meaning)")
            }
        }
    }

    // MARK: the code first

    @Test func aCodeIsReadWhateverTheWordsSay() {
        // The words may be in another language: the code decides.
        for (meaning, words) in [(RefusalMeaning.teamChanged, "La configuración del equipo cambió mientras tanto."),
                                 (.agentMidTurn, "juno está en medio de un turno."), (.agentOpenSignIn, "Termínalo o deja que caduque."),
                                 (.requestAnswered, "La solicitud ya tiene respuesta."), (.hubChanged, "El hub cambió."),
                                 (.notOwnerDevice, "no es un dispositivo del propietario.")] {
            for code in meaning.codes {
                #expect(refusal(words, code: code).means(meaning), "\(code)")
            }
        }
        // And a code of another meaning is not this one, also when the English holds the old phrase.
        let other = refusal("hub generation changed; team.json changed", code: "hub_changed")
        #expect(other.means(.hubChanged) && !other.means(.teamChanged))
        #expect(!refusal("no such agent", code: "no_such_agent").means(.teamChanged))
        // A code that this app does not know decides nothing here: a newer hub's other sentence.
        #expect(!refusal("team.json changed meanwhile; reload it", code: "a_code_of_a_later_hub").means(.teamChanged))
    }

    @Test func aMeaningThatHoldsANameIsReadByItsCodeWithOrWithoutTheName() {
        #expect(refusal("juno is in the middle of a turn. Move it when the turn ends.", code: "agent_mid_turn",
                        names: ["agent": "Studio"]).means(.agentMidTurn))
        #expect(refusal("x", code: "agent_open_signin").means(.agentOpenSignIn))
    }

    // MARK: an older hub

    /// A refusal with no code is the answer of a hub from before them: the apps read it by the English phrase, as they did,
    /// so that a new app never loses a retry on an old hub.
    @Test func anOlderHubSendsNoCodeAndItsEnglishPhraseDecidesAsItDid() {
        let older: [(RefusalMeaning, String)] = [
            (.teamChanged, "team.json changed meanwhile; reload it"), (.teamChanged, "team.json changed meanwhile; reload the reporting lines"),
            (.agentMidTurn, "juno is in the middle of a turn. Move it when the turn ends."),
            (.agentOpenSignIn, "juno has an open sign-in. Finish it or let it run out, then try again."),
            (.requestAnswered, "owner request is already answered"),
            (.hubChanged, "hub generation changed; refresh state"), (.hubChanged, "hub generation changed; refresh state before sending"),
            (.notOwnerDevice, "100.64.0.9 is not an owner device. See \"owner_devices\" in team.json."),
        ]
        for (meaning, words) in older {
            let refusal = refusal(words)
            #expect(refusal.means(meaning), "\(words)")
            // No other meaning reads it.
            for other in RefusalMeaning.allCases where other != meaning {
                #expect(!refusal.means(other), "\(other) read \(words)")
            }
        }
        for words in ["no such agent", "hub is starting", HubError.unexplained, ""] {
            for meaning in RefusalMeaning.allCases { #expect(!refusal(words).means(meaning), "\(meaning) read \(words)") }
        }
    }

    // MARK: no copy of the phrases

    /// The phrases that the Mac app compared are in `RefusalMeaning` alone: a line that looks for one in the hub's English
    /// again would stop working in the first language that the hub's words reach in.
    @Test func noLineOfTheMacAppLooksForAPhraseOfTheHubsEnglish() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found: [String] = []
        for folder in ["Sources/Founderizer", "Sources/FleetCore"] {
            let files = try #require(FileManager.default.enumerator(at: app.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "RefusalMeaning.swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for meaning in [RefusalMeaning.teamChanged, .agentMidTurn, .agentOpenSignIn, .requestAnswered] {
                    if text.contains("contains(\"\(meaning.phrase)\")") { found.append("\(file.lastPathComponent): \(meaning.phrase)") }
                }
            }
        }
        #expect(found.isEmpty, "read the code with HubRefusal.means(_:) in: \(found)")
    }
}
