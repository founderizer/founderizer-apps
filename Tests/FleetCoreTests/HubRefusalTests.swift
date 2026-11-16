import Foundation
import Testing
@testable import FleetCore

/// **A refusal of the hub as one value** (`HubRefusal`, the design `hub-refusal-words-design.md`; UI-API.md 1.181): the
/// status, the hub's own English line, its `code` and the `names` inside the words, read in one place for every funnel
/// of the app. Nothing of the app's own words is in these tests: the hub's English is what shows, character for character,
/// until a code has words of its own in a table (`RefusalWordsTests`).
struct HubRefusalTests {
    private func read(_ json: String, status: Int = 409) -> HubRefusal {
        HubRefusal.read(status: status, body: Data(json.utf8))
    }

    // MARK: what the decoder reads

    @Test func aBodyWithACodeAndNamesGivesAllOfThem() {
        let refusal = read(#"{"error":"vps-2 sent no reading in the last 10 minutes: check that it is on","code":"server_silent","names":{"server":"vps-2"}}"#)
        #expect(refusal.status == 409)
        #expect(refusal.hubWords == "vps-2 sent no reading in the last 10 minutes: check that it is on")
        #expect(refusal.code == "server_silent")
        #expect(refusal.names == ["server": "vps-2"])
        // With no table of words for a language, the hub's own English stands.
        #expect(refusal.words == "vps-2 sent no reading in the last 10 minutes: check that it is on")
    }

    @Test func aBodyWithACodeAndNoNamesHasNoNames() {
        let refusal = read(#"{"error":"hub generation changed; refresh state","code":"hub_changed"}"#)
        #expect(refusal.code == "hub_changed")
        #expect(refusal.names.isEmpty)
        #expect(refusal.words == "hub generation changed; refresh state")
    }

    @Test func aBodyWithNoCodeIsTheOldHubsAnswer() {
        let refusal = read(#"{"error":"no such agent"}"#, status: 404)
        #expect(refusal.status == 404 && refusal.hubWords == "no such agent")
        #expect(refusal.code == nil && refusal.names.isEmpty)
        #expect(refusal.words == "no such agent")
    }

    @Test func aCodeThatThisAppDoesNotKnowIsKeptAndTheHubsEnglishStands() {
        let refusal = read(#"{"error":"a sentence of a later hub","code":"a_code_of_a_later_hub"}"#)
        #expect(refusal.code == "a_code_of_a_later_hub")
        #expect(refusal.words == "a sentence of a later hub")
    }

    @Test func aCodeWhoseNameIsMissingKeepsTheHubsEnglish() {
        // The words of `server_silent` hold a server: with no `names` the sentence cannot be made, and the hub's own stands.
        let refusal = read(#"{"error":"vps-2 sent no reading in the last 10 minutes: check that it is on","code":"server_silent"}"#)
        #expect(refusal.code == "server_silent" && refusal.names["server"] == nil)
        #expect(refusal.words == "vps-2 sent no reading in the last 10 minutes: check that it is on")
    }

    @Test func aNameIsATextOrAWholeNumberAndAnythingElseIsLeftOut() {
        let refusal = read(#"{"error":"x","names":{"server":"vps-2","tasks":3,"half":1.5,"yes":true,"none":null,"list":[1],"deep":{"a":1}}}"#)
        #expect(refusal.names == ["server": .text("vps-2"), "tasks": .number(3)])
        #expect(refusal.names["tasks"]?.written == "3" && refusal.names["server"]?.written == "vps-2")
        // A text of digits stays a text: the hub said it was one.
        #expect(read(#"{"error":"x","names":{"address":"100"}}"#).names["address"] == .text("100"))
    }

    @Test func aCodeThatIsNoCodeIsIgnoredAndTheWordsStay() {
        for bad in [#""Hub Changed""#, #""x""#, #""hub-changed""#, "5", "null", #""""#, #""\#(String(repeating: "a", count: 41))""#] {
            let refusal = read(#"{"error":"hub generation changed; refresh state","code":\#(bad)}"#)
            #expect(refusal.code == nil, "\(bad)")
            #expect(refusal.hubWords == "hub generation changed; refresh state", "\(bad)")
        }
        #expect(read(#"{"error":"x","code":"ab"}"#).code == "ab")
        #expect(read(#"{"error":"x","code":"\#(String(repeating: "a", count: 40))"}"#).code?.count == 40)
    }

    @Test func aNameIsCutAtTwoHundredCharactersAndAnAnswerCarriesFewNames() {
        let long = String(repeating: "é", count: 300)
        #expect(read(#"{"error":"x","names":{"server":"\#(long)"}}"#).names["server"] == .text(String(repeating: "é", count: 200)))
        let many = (0..<40).map { #""n\#($0)":\#($0)"# }.joined(separator: ",")
        #expect(read(#"{"error":"x","names":{\#(many)}}"#).names.count == 16)
        #expect(read(#"{"error":"x","names":{"Not A Key":"v","":"v"}}"#).names.isEmpty)
    }

    @Test func theWordsAreBoundedAndTrimmedAsEveryFunnelDid() {
        #expect(read(#"{"error":"  no such agent \n"}"#).hubWords == "no such agent")
        #expect(read(#"{"error":"\#(String(repeating: "a", count: 900))"}"#).hubWords.count == 500)
    }

    @Test func nothingInABodyMakesTheReadFail() {
        for body in ["", "not json", "[]", "[1,2]", "null", "5", #"{"error":5}"#, #"{"error":null}"#, #"{"error":"   "}"#,
                     #"{"error":["a"]}"#, #"{"code":"hub_changed"}"#, #"{"names":"vps-2"}"#, "{"] {
            let refusal = read(body, status: 500)
            #expect(refusal.status == 500, "\(body)")
            #expect(!refusal.hubWords.isEmpty, "\(body)")
        }
        for body in ["", "not json", "[]", #"{"error":5}"#, #"{"error":"   "}"#] {
            #expect(read(body).hubWords == HubError.unexplained, "\(body)")
        }
        // A code without words still has its code, for a screen that has words for it.
        #expect(read(#"{"code":"hub_changed"}"#).code == "hub_changed")
        #expect(read(#"{"error":"x","names":"vps-2"}"#).names.isEmpty)
    }

    // MARK: the value

    @Test func aRefusalSurvivesTheDiskAndAnOlderRecordHasNoCodeAndNoNames() throws {
        let refusal = HubRefusal(status: 409, hubWords: "vps-2 sent no reading in the last 10 minutes: check that it is on",
                                 code: "server_silent", names: ["server": "vps-2", "tasks": 3])
        let data = try JSONEncoder().encode(refusal)
        #expect(try JSONDecoder().decode(HubRefusal.self, from: data) == refusal)
        let older = try JSONDecoder().decode(HubRefusal.self, from: Data(#"{"status":403,"hubWords":"owner only"}"#.utf8))
        #expect(older == HubRefusal(status: 403, hubWords: "owner only"))
        #expect(older.code == nil && older.names.isEmpty)
    }

    @Test func theFallbackSentenceIsTheHubsNoWordsAndSaidIsNilForIt() {
        let none = HubRefusal(status: 503, hubWords: HubError.unexplained)
        #expect(none.words == "Unexpected HTTP response.")
        #expect(none.said == nil)
        #expect(HubRefusal(status: 503, hubWords: "   ").said == nil)
        #expect(HubRefusal(status: 503, hubWords: "  the hub is restarting ").said == "the hub is restarting")
    }

    // MARK: the error that carries it

    /// **The English is what it was.** An error says its status and the hub's own line, for every status, with a code
    /// or with none: nothing of the new fields shows on a device whose language is English.
    @Test func theEnglishOfAnErrorIsUnchangedWithOrWithoutACode() {
        let plain = HubError.refusal(HubRefusal(status: 409, hubWords: "hub generation changed; refresh state"))
        let coded = HubError.refusal(read(#"{"error":"hub generation changed; refresh state","code":"hub_changed"}"#))
        for error in [plain, coded] {
            #expect(error.errorDescription == "Hub refused the request (409): hub generation changed; refresh state")
            #expect(HubError.said(error) == "hub generation changed; refresh state")
            #expect(error.conflict && !error.definitiveRefusal)
        }
        let silent = HubError.refusal(HubRefusal(status: 503, hubWords: HubError.unexplained))
        #expect(silent.errorDescription == "Hub refused the request (503): Unexpected HTTP response.")
        #expect(HubError.said(silent) == nil)
        #expect(silent.definitiveRefusal && !silent.conflict)
    }

    @Test func theAnswerOfAHubThatSendsACodeReachesTheScreenAsItsEnglish() async throws {
        let refusal = try OneAnswer(status: "409 Conflict") { _ in
            #"{"error":"vps-2 sent no reading in the last 10 minutes: check that it is on","code":"server_silent","names":{"server":"vps-2"}}"#
        }
        do {
            _ = try await HubClient().servers(hub: URL(string: "http://127.0.0.1:\(refusal.port)")!, database: "db")
            Issue.record("The stand-in answered 409, so the read cannot succeed.")
        } catch let HubError.refusal(refused) {
            #expect(refused.code == "server_silent" && refused.names == ["server": "vps-2"])
            #expect(HubError.refusal(refused).errorDescription
                    == "Hub refused the request (409): vps-2 sent no reading in the last 10 minutes: check that it is on")
        }
    }
}
