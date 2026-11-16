import Foundation
import Testing
@testable import FleetCore

/// **A refused request keeps the hub's refusal as fields** (`PendingRequest.hubRefusal`, `refuse(_:)`, `refusedByHub`): its
/// status, its English line, its code and its names, with the English text beside them that the mark `refusal` and the
/// older readers stand on. A file that an older version wrote has its words only as that text, and is read as it was.
struct OutboxRefusalTests {
    private let hub = URL(string: "http://100.64.0.1:8765")!
    private let base = String(repeating: "a", count: 64)
    private let silent = HubRefusal(status: 409, hubWords: "vps-2 sent no reading in the last 10 minutes: check that it is on",
                                    code: "server_silent", names: ["server": "vps-2"])

    private func request(_ command: OwnerCommand? = nil) -> PendingRequest {
        PendingRequest(hub: hub, database: "db", client: "local", command: command, text: "hello")
    }

    private func file() -> Outbox {
        Outbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)/pending.json"))
    }

    // MARK: what a refusal writes

    @Test func aRefusedRequestKeepsItsFieldsAndTheEnglishTextTogether() throws {
        var refused = request()
        #expect(refused.refusal == nil && refused.hubRefusal == nil && refused.refusedByHub == nil)
        refused.refuse(silent)
        // The mark that every reader of `refusal` stands on, in the English that `refusalStatus(in:)` reads back, whatever
        // the language of the device.
        #expect(refused.refusal == "Hub refused the request (409): vps-2 sent no reading in the last 10 minutes: check that it is on")
        #expect(HubError.refusalStatus(in: refused.refusal ?? "") == 409)
        #expect(refused.hubRefusal == silent && refused.refusedByHub == silent)
    }

    @Test func theFieldsSurviveTheDiskAndTheRequestKeepsItsIdentity() throws {
        let outbox = file()
        defer { try? FileManager.default.removeItem(at: outbox.file.deletingLastPathComponent()) }
        let sent = request()
        try outbox.save(sent)
        #expect(try outbox.load()?.refusedByHub == nil)
        var refused = sent
        refused.refuse(silent)
        try outbox.save(refused)
        let loaded = try #require(try outbox.load())
        #expect(loaded == refused && loaded.requestID == sent.requestID)
        #expect(loaded.refusedByHub?.code == "server_silent" && loaded.refusedByHub?.names == ["server": "vps-2"])
    }

    // MARK: what an older version wrote

    @Test func aFileThatAnOlderVersionWroteIsReadAsItWas() throws {
        var older = request()
        older.refusal = "Hub refused the request (409): team.json changed meanwhile; reload it"
        let data = try JSONEncoder().encode(older)
        #expect(!String(decoding: data, as: UTF8.self).contains("hubRefusal"))
        let loaded = try JSONDecoder().decode(PendingRequest.self, from: data)
        #expect(loaded.hubRefusal == nil)
        #expect(loaded.refusedByHub == HubRefusal(status: 409, hubWords: "team.json changed meanwhile; reload it"))
        #expect(loaded.refusedByHub?.code == nil && loaded.refusedByHub?.names.isEmpty == true)
        // And a refusal of an older file that said nothing: the hub's fallback line.
        older.refusal = "Hub refused the request (503): Unexpected HTTP response."
        #expect(older.refusedByHub == HubRefusal(status: 503, hubWords: HubError.unexplained))
    }

    @Test func wordsThatNoStatusStandsInFrontOfAreTheAppsOwnAndStayAsTheyAre() throws {
        var own = request()
        own.refusal = "The hub refused registered login text (422). Saved text and drafts were removed."
        #expect(own.refusedByHub == nil)
        #expect(own.refusalLine == "The hub refused registered login text (422). Saved text and drafts were removed.")
        let none = request()
        #expect(none.refusalLine == nil)
    }

    // MARK: the words, in the language of the day they are read

    @Test func theLineIsMadeFromTheFieldsInTheLanguageOfTheDay() throws {
        var refused = request()
        refused.refuse(silent)
        #expect(refused.refusalLine == "Hub refused the request (409): vps-2 sent no reading in the last 10 minutes: check that it is on")
        let spanish = try LocalizedTests.table(["Hub refused the request (%lld): %@": "El hub rechazó la solicitud (%lld): %@"])
        Localized.$bundle.withValue(spanish) {
            #expect(refused.refusalLine == "El hub rechazó la solicitud (409): vps-2 sent no reading in the last 10 minutes: check that it is on")
            // What is kept on disk stays English: the words are made when they are read, never kept in a language.
            #expect(refused.refusal == "Hub refused the request (409): vps-2 sent no reading in the last 10 minutes: check that it is on")
            #expect(HubError.refusalStatus(in: refused.refusal ?? "") == 409)
        }
        // A request that an older version refused is said in the language of the day too, with its words as the hub's.
        var older = request()
        older.refusal = "Hub refused the request (409): team.json changed meanwhile; reload it"
        Localized.$bundle.withValue(spanish) {
            #expect(older.refusalLine == "El hub rechazó la solicitud (409): team.json changed meanwhile; reload it")
        }
    }

    // MARK: the outcome of a profile save

    @Test func aProfileSaveReadsTheFieldsAndTheOldText() {
        let command = OwnerCommand.profile(agent: "studio", sha256: base)
        var pending = request(command)
        #expect(ProfileSaveOutcome(pending: pending, command: command) == .waiting)
        #expect(ProfileSaveOutcome(pending: pending, command: .profile(agent: "vps", sha256: base)) == nil)
        #expect(ProfileSaveOutcome(pending: nil, command: command) == nil)

        pending.refuse(HubRefusal(status: 409, hubWords: "the profile changed meanwhile; reload it"))
        #expect(ProfileSaveOutcome(pending: pending, command: command) == .changedMeanwhile("the profile changed meanwhile; reload it"))
        pending.refuse(HubRefusal(status: 400, hubWords: "a line in Responsible for starts like a section title"))
        #expect(ProfileSaveOutcome(pending: pending, command: command) == .refused("a line in Responsible for starts like a section title"))

        // The text of an older version, and words that no status stands in front of.
        var older = request(command)
        older.refusal = "Hub refused the request (409): the profile changed meanwhile; reload it"
        #expect(ProfileSaveOutcome(pending: older, command: command) == .changedMeanwhile("the profile changed meanwhile; reload it"))
        older.refusal = "The hub refused registered login text (422). Saved text and drafts were removed."
        #expect(ProfileSaveOutcome(pending: older, command: command)
                == .refused("The hub refused registered login text (422). Saved text and drafts were removed."))
    }
}
