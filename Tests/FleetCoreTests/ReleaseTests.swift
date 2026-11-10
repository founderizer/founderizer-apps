import Foundation
import Testing
@testable import FleetCore

/// The Updates screen (PRODUCT.md 4.3), and what stays of the old subscription until our open channel answers every
/// fleet (4.2 and 4.5): a record that no screen shows, and the key of the website's link. `Fixtures/releases.json` is
/// the answer of the hub's own `GET /ui/releases`, taken from `ui_fixture.py`, so this reads the shape the hub really
/// serves and not one this app guessed.
struct ReleaseTests {
    private func fixture() throws -> ReleaseState {
        let url = try #require(Bundle.module.url(forResource: "releases", withExtension: "json", subdirectory: "Fixtures"))
        let state = try JSONDecoder().decode(ReleaseState.self, from: try Data(contentsOf: url))
        try state.validate(database: state.db)
        return state
    }

    private func state(_ changes: [String: String] = [:]) throws -> ReleaseState {
        var body = """
        {"db": "d", "time": 1792267877, "revision": "aac4cb2196e5b72f1a5295f085780acb1c08cbc1", "branch": "config",
         "channel": "https://founderizer.com", "upstream": "https://github.com/miguelpieras/founderizer-fleet.git",
         "automatic": AUTO, "have_release_key": KEY, "idle": IDLE, "open_tasks": TASKS, "running": RUNNING,
         "last_check": CHECKED,
         "entitlement": ENTITLEMENT, "releases": [ROWS]}
        """
        let defaults = ["AUTO": "false", "KEY": "true", "IDLE": "true", "TASKS": "[]", "RUNNING": "false",
                        "ENTITLEMENT": Self.live, "ROWS": Self.offered, "CHECKED": Self.checked]
        for (name, value) in defaults.merging(changes, uniquingKeysWith: { _, new in new }) {
            body = body.replacingOccurrences(of: name, with: value)
        }
        return try JSONDecoder().decode(ReleaseState.self, from: Data(body.utf8))
    }

    /// **The releases reading this Mac keeps with the fleet's reads back whole, and only for its own hub generation** (the
    /// second review of 30 October 2026): the sidebar's Update row draws from it in a launch's first frame.
    @Test func aKeptReleasesReadingReadsBackForItsOwnGeneration() throws {
        let read = try state()
        let data = try JSONEncoder().encode(read)
        let kept = try #require(ReleaseState.kept(data, database: "d"))
        #expect(kept == read)
        #expect(kept.offered?.version == "2026.10.3" && kept.stand.take != nil)
        // Another hub generation, or a file that is no reading, keeps nothing.
        #expect(ReleaseState.kept(data, database: "another") == nil)
        #expect(ReleaseState.kept(Data("not json".utf8), database: "d") == nil)
    }

    private func health(revision: String?) throws -> FleetHealth {
        var body: [String: Any] = ["db": "d", "ok": true, "time": 100, "hub": ["integrity": [String: Any]()],
                                   "helpers": [Any](), "warnings": [Any]()]
        if let revision { body["revision"] = revision }
        return try JSONDecoder().decode(FleetHealth.self, from: JSONSerialization.data(withJSONObject: body))
    }

    /// **A kept releases reading still draws when this launch's health names another hub revision** (review A, round 5 of
    /// 30 October 2026): that revision is the head of the configuration branch, which every setting and every delivered
    /// task output moves. Dropped on it, a waiting release's Update row went at the health read and came back at the
    /// releases read.
    @Test func aKeptReleasesReadingStillDrawsWhenTheHubIsOnAnotherRevision() throws {
        let read = try state()
        let health = try health(revision: "0123456789abcdef0123456789abcdef01234567")
        #expect(health.revision != read.revision)
        let kept = KeptReading(read)
        // It draws for the hub generation the health is of, and for no other.
        #expect(kept.reading(of: health.db) == read)
        #expect(kept.reading(of: "another") == nil)
    }

    /// **A kept releases reading goes when a releases read of this launch fails** (review A, rounds 4 and 5): the next
    /// read came 300 s later, and the row stood that long for what the last launch read.
    @Test func aKeptReleasesReadingGoesWhenAReleasesReadFails() throws {
        var kept = KeptReading(try state())
        #expect(kept.reading != nil)
        kept.readFailed()
        #expect(kept.reading == nil)
    }

    private static let live = """
    {"fleet": "0123456789abcdef", "have_token": true, "plan": "monthly", "until": 2000000000, "machines": 5,
     "agents": 10, "verified": true, "stored_at": 1789675872, "expired": false, "channel_said": null,
     "channel_at": null}
    """
    private static let lapsed = """
    {"fleet": "0123456789abcdef", "have_token": true, "plan": "monthly", "until": 1789675872, "machines": 5,
     "agents": 10, "verified": true, "stored_at": 1789675872, "expired": true,
     "channel_said": "this subscription is not live", "channel_at": 1792267272}
    """
    private static let none = """
    {"fleet": null, "have_token": false, "plan": null, "until": null, "machines": null, "agents": null,
     "verified": false, "stored_at": null, "expired": null, "channel_said": null, "channel_at": null}
    """
    private static func row(_ fields: String) -> String {
        """
        {"id": 3, "revision": "cccccccccccccccccccccccccccccccccccccccc", "version": "2026.10.3",
         "notes": "https://founderizer.com/releases/2026.10.3", "minimum": null, "pinned": null, "reached": null,
         "seen_at": 1792267272, "started_at": null, "finished_at": null, "automatic": false, "applied": false,
         \(fields)}
        """
    }
    private static let checked = """
    {"at": 1792267272, "says": null, "status": 200}
    """
    private static let offered = row("\"hold\": false, \"state\": \"verified\", \"step\": null, \"says\": null")
    /// A release whose own update run started, so that `newestRun` is this row.
    private static func started(state: String, step: String, says: String? = nil, reached: Bool = false) -> String {
        row("""
            "hold": false, "state": "\(state)", "step": "\(step)",
            "says": \(says.map { "\"\($0)\"" } ?? "null")
            """)
            .replacingOccurrences(of: "\"started_at\": null", with: "\"started_at\": 1792267300")
            .replacingOccurrences(of: "\"applied\": false", with: "\"applied\": \(reached)")
            .replacingOccurrences(of: "\"reached\": null",
                                  with: reached ? "\"reached\": \"aac4cb2196e5b72f1a5295f085780acb1c08cbc1\"" : "\"reached\": null")
    }
    private static let held = row("\"hold\": true, \"state\": \"held\", \"step\": null, \"says\": null")

    @Test func theHubsOwnAnswerIsReadAsItIs() throws {
        let state = try fixture()
        #expect(state.revision?.hasPrefix("aac4cb21") == true)
        #expect(state.channel == "https://founderizer.com")
        #expect(state.releases.count == 3)
        #expect(state.offered?.version == "2026.10.3")
        #expect(state.current?.version == "2026.10.1")
        #expect(state.newestRun?.version == "2026.10.2")
        #expect(state.entitlement.have_token && state.entitlement.machines == 4 && state.entitlement.agents == 6)
        // The fixture's fleet ships no release key, so its hub would refuse every manifest. The screen says that
        // and nothing about being up to date, because a fleet that cannot check a release is not up to date.
        #expect(state.stand.value == "Nothing to check")
        #expect(state.stand.take == nil)
        #expect(state.stand.says == "This build has no release key.")
    }

    @Test func aRunThatRolledBackSaysSoInTheHubsOwnWords() throws {
        let run = try #require(try fixture().newestRun)
        #expect(run.state == "rolled_back")
        #expect(run.step == "selftest")
        #expect(run.summary.contains("The fleet stays at aac4cb2196e5."))
        #expect(run.needsOwner == false)
        #expect(run.pinned?.hasPrefix("aac4cb21") == true)
    }

    // ---- where this fleet stands: the one line and the one button the Updates screen draws

    @Test func anUpdateIsOfferedWhenNothingStopsIt() throws {
        let ready = try state().stand
        #expect(ready.take?.version == "2026.10.3")
        #expect(ready.waiting == false)
        #expect(ready.says == "Your fleet has not taken one of our releases yet.")
    }

    @Test func aHeldReleaseSaysSoAndOffersNothing() throws {
        let stopped = try state(["ROWS": Self.held])
        #expect(stopped.offered == nil)
        #expect(stopped.stand.take == nil)
        #expect(stopped.stand.value == "Held")
        #expect(stopped.stand.says == "Release 2026.10.3 is held by us. No fleet takes it.")
    }

    @Test func aFleetWithNoReleaseKeyIsNotCalledUpToDate() throws {
        let safe = try state(["KEY": "false"]).stand
        #expect(safe.take == nil)
        #expect(safe.value == "Nothing to check")
        #expect(safe.says == "This build has no release key.")
        // With nothing published either, one line says both halves of the truth.
        let empty = try state(["KEY": "false", "ROWS": ""]).stand
        #expect(empty.says == "We have published no release yet, and this build carries no key to check one "
                + "with. Your fleet is not behind.")
    }

    @Test func aChannelThatHasPublishedNothingIsNotUpToDateEither() throws {
        let nothing = try state(["ROWS": ""]).stand
        #expect(nothing.value == "Nothing to check")
        #expect(nothing.says == "We have published no release yet. Your fleet is not behind.")
        #expect(nothing.warn == false, "a channel with no release on it is not the owner's problem to act on")
    }

    @Test func aFleetOurChannelRefusedIsToldWhatTheChannelAnswered() throws {
        // Founderizer has no subscription, so no line speaks of one. Today's channel still refuses a fleet whose hub
        // holds no token: the screen says that as the channel's answer, in the hub's words, as any other refusal.
        let refused = try state(["ENTITLEMENT": Self.none, "ROWS": "", "CHECKED": """
        {"at": 1792267272, "says": "the release channel refused this fleet's entitlement", "status": 401}
        """]).stand
        #expect(refused.value == "Cannot check")
        #expect(refused.says == "the release channel refused this fleet's entitlement")
        #expect(refused.take == nil && refused.warn)
        // Before the hub has asked at all, which is the state a fleet is in right after its install: that is what the
        // line says, and not "We have published no release yet", which was never what happened.
        let unasked = try state(["ENTITLEMENT": Self.none, "ROWS": "", "CHECKED": """
        {"at": null, "says": null, "status": null}
        """]).stand
        #expect(unasked.says == "Your fleet has not asked our channel yet.")
        #expect(unasked.value == "Nothing to check" && unasked.take == nil && unasked.warn == false)
        // And a fleet that does carry releases keeps its offer: this app refuses nothing itself.
        #expect(try state(["ENTITLEMENT": Self.none]).stand.take?.version == "2026.10.3")
    }

    @Test func anUpdateWaitsForTheFleetsOwnWork() throws {
        let busy = try state(["IDLE": "false", "TASKS": "[12, 13]"]).stand
        #expect(busy.take?.version == "2026.10.3", "the release it would take, once it can")
        #expect(busy.waiting)
        #expect(busy.says == "It waits until no task runs.")
        // Fix round 3, item 1: no button while it waits; the row's value says what for.
        #expect(busy.value == "Waits for 2 tasks")
        #expect(try state(["IDLE": "false", "TASKS": "[12]"]).stand.value == "Waits for a task")
        // Plan P0: only a check runs, so the hub names no task; the line says what it waits for, and no empty list.
        let checking = try state(["IDLE": "false", "TASKS": "[]"]).stand
        #expect(checking.waiting && checking.says == "It waits until no check runs.")
        #expect(checking.value == "Waits for a check")
    }

    @Test func aRunThatIsGoingOnSaysThatFirst() throws {
        let running = try state(["RUNNING": "true", "ROWS": Self.started(state: "updating", step: "merge")]).stand
        #expect(running.value == "Updating")
        #expect(running.take == nil)
        #expect(running.says == "This fleet is updating to 2026.10.3…")
    }

    @Test func aRunThatFailedIsTheOneThingToActOn() throws {
        let stand = try state(["ROWS": Self.started(state: "failed", step: "push",
                                                    says: "the push to config was refused")]).stand
        #expect(stand.warn)
        #expect(stand.value == "Did not finish")
        #expect(stand.says == "the push to config was refused")
    }

    @Test func onlyAReleaseThisFleetReachedMakesItUpToDate() throws {
        let stand = try state(["ROWS": Self.started(state: "done", step: "follow", reached: true)]).stand
        #expect(stand.value == "2026.10.3")
        #expect(stand.take == nil)
        #expect(stand.says.hasPrefix("Your fleet runs the newest release. Asked "))
        // A fleet on a revision no release of ours reached says that, instead of claiming to be current.
        let stray = try state(["ROWS": Self.row("\"hold\": false, \"state\": \"kept\", \"step\": null, \"says\": null")]).stand
        #expect(stray.says == "Your fleet has not taken one of our releases yet.")
        #expect(stray.value == "Unknown")
    }

    @Test func noLineOfTheUpdatesScreenNamesARevision() throws {
        // The owner, 19 October 2026: "IDs like the attached are not useful at all for the viewer." The screen
        // names a version or says plainly that there is none, and the revision stays where the app needs it.
        let revision = "aac4cb2196e5"
        let stands = [try fixture().stand, try state().stand,
                      try state(["ROWS": Self.started(state: "done", step: "follow", reached: true)]).stand,
                      try state(["ROWS": Self.row("\"hold\": false, \"state\": \"kept\", \"step\": null, "
                                                 + "\"says\": null")]).stand,
                      try state(["ROWS": ""]).stand, try state(["ROWS": Self.held]).stand,
                      try state(["IDLE": "false", "TASKS": "[12]"]).stand]
        for stand in stands {
            #expect(stand.says.contains(revision) == false, "the line names a revision: \(stand.says)")
            #expect(stand.value.contains(revision) == false, "the value names a revision: \(stand.value)")
        }
        // The one exception is a run that failed, where the line is the hub's own diagnosis and the owner is
        // the one who has to act on it. It is passed on as it is written.
        let broken = try state(["ROWS": Self.started(state: "failed", step: "merge",
                                                     says: "the merge left \(revision) in place")]).stand
        #expect(broken.says.contains(revision))
    }

    @Test func aChannelThatRefusedTheLastCheckSaysSoAndOffersNothing() throws {
        let refused = try state(["ROWS": "", "CHECKED": """
        {"at": 1792267272, "says": "our channel answered 503", "status": 503}
        """]).stand
        #expect(refused.warn)
        #expect(refused.value == "Cannot check")
        #expect(refused.says == "our channel answered 503")
    }

    // ---- what the hub still holds of the old subscription: read, and shown nowhere

    @Test func noLineOfTheUpdatesScreenSpeaksOfASubscription() throws {
        // Founderizer is free and open source since 10 November 2026: no subscription and no account. Whatever the hub
        // holds of the old one — a live token, one that ran out, none — the screen says where the fleet stands, and
        // never names a plan, a key, a price or an end.
        let words = ["subscription", "plan", "claim", "lapsed", "account", "renew", "price", "pay"]
        let unasked = #"{"at": null, "says": null, "status": null}"#
        for entitlement in [Self.live, Self.lapsed, Self.none] {
            for rows in [Self.offered, "", Self.held] {
                for checked in [Self.checked, unasked] {
                    let stand = try state(["ENTITLEMENT": entitlement, "ROWS": rows, "CHECKED": checked]).stand
                    let said = (stand.says + " " + stand.value).lowercased()
                    for word in words { #expect(!said.contains(word), "\(word) in: \(said)") }
                }
            }
        }
    }

    @Test func aTokenThatRanOutStopsNothingInTheApp() throws {
        // Our open channel answers every fleet, so a fleet whose old token ran out still learns of each release, and
        // the one that waits is offered. The app itself never refused one.
        let over = try state(["ENTITLEMENT": Self.lapsed]).stand
        #expect(over.take?.version == "2026.10.3" && over.warn == false)
        // While today's channel still refuses such a fleet, its answer is what the screen says.
        let refused = try state(["ENTITLEMENT": Self.lapsed, "ROWS": "", "CHECKED": """
        {"at": 1792267272, "says": "the release channel answered 402", "status": 402}
        """]).stand
        #expect(refused.value == "Cannot check" && refused.warn && refused.says == "the release channel answered 402")
    }

    @Test func aHubThatSendsLessOfTheOldRecordStillReads() throws {
        // A hub may send the record without some of its fields, or not at all: both read as a fleet with no token,
        // and the Updates screen draws as before.
        let part = try state(["ENTITLEMENT": #"{"fleet": "0123456789abcdef"}"#])
        #expect(part.entitlement.fleet == "0123456789abcdef")
        #expect(!part.entitlement.have_token && !part.entitlement.verified && part.entitlement.until == nil)
        #expect(part.stand.take?.version == "2026.10.3")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(try state())) as? [String: Any])
        object["entitlement"] = nil
        let without = try JSONDecoder().decode(ReleaseState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(without.entitlement == .none && without.entitlement.fleet == nil)
        #expect(without.stand.take?.version == "2026.10.3")
        // And it reads back from what this Mac keeps of it.
        #expect(ReleaseState.kept(try JSONEncoder().encode(without), database: "d") == without)
    }

    @Test func theAppHasNowhereToKeepTheTokenItself() throws {
        // The hub never serves the token, and this model has no field for one: a read that carries a token keeps
        // nothing of it. The token is in the one request body that hands it to the hub and nowhere else.
        let withToken = Self.live.replacingOccurrences(of: "\"have_token\": true",
                                                       with: "\"have_token\": true, \"token\": \"claims.signature\"")
        let entitlement = try state(["ENTITLEMENT": withToken]).entitlement
        #expect(entitlement.have_token)
        let fields = try JSONEncoder().encode(EntitlementMirror(entitlement))
        #expect(String(decoding: fields, as: UTF8.self).contains("claims.signature") == false)
    }

    private struct EntitlementMirror: Encodable {
        let fleet: String?, plan: String?, until: Double?, machines: Int?, agents: Int?, verified: Bool
        init(_ entitlement: Entitlement) {
            fleet = entitlement.fleet; plan = entitlement.plan; until = entitlement.until
            machines = entitlement.machines; agents = entitlement.agents; verified = entitlement.verified
        }
    }

    @Test func onlyOurOwnNotesPageIsOpened() throws {
        let release = try #require(try state().releases.first)
        #expect(release.notesLink(channel: "https://founderizer.com") != nil)
        #expect(release.notesLink(channel: "https://example.com") == nil)
        let elsewhere = try #require(try state(["ROWS": Self.offered.replacingOccurrences(
            of: "https://founderizer.com/releases/2026.10.3",
            with: "http://founderizer.com.evil.example/releases")]).releases.first)
        #expect(elsewhere.notesLink(channel: "https://founderizer.com") == nil)
    }

    // ---- the key of the website's link, which is traded with nothing on the screen (`ClaimFromLink`)

    @Test func aKeyIsSentAsItCame() {
        #expect(ClaimKey.toSend("  FZ-7KMQ-2PRJ-4TVW  ") == "FZ-7KMQ-2PRJ-4TVW")
        // The website forgives case, spaces, hyphens and a missing prefix, so the app does not clean the key up.
        #expect(ClaimKey.toSend("fz 7kmq 2prj 4tvw") == "fz 7kmq 2prj 4tvw")
        #expect(ClaimKey.toSend("7KMQ2PRJ4TVW") == "7KMQ2PRJ4TVW")
        #expect(ClaimKey.toSend("short") == nil)
        #expect(ClaimKey.toSend("FZ-7KMQ-2PRJ-4TVW; rm -rf /") == nil)
        #expect(ClaimKey.toSend("") == nil)
    }

    @Test func theWebsitesLinkCarriesTheKeyAndNoOtherLinkDoes() throws {
        func key(_ link: String) throws -> String? { ClaimKey.fromLink(try #require(URL(string: link))) }
        #expect(try key("founderizer://claim?key=FZ-7KMQ-2PRJ-4TVW") == "FZ-7KMQ-2PRJ-4TVW")
        #expect(try key("FOUNDERIZER://CLAIM?key=FZ-7KMQ-2PRJ-4TVW") == "FZ-7KMQ-2PRJ-4TVW")
        #expect(try key("founderizer://claim?key=FZ%207KMQ%202PRJ%204TVW") == "FZ 7KMQ 2PRJ 4TVW")
        #expect(try key("founderizer://claim?key=short") == nil)
        #expect(try key("founderizer://claim?other=FZ-7KMQ-2PRJ-4TVW") == nil)
        #expect(try key("founderizer://enroll?key=FZ-7KMQ-2PRJ-4TVW") == nil)
        #expect(try key("https://claim/?key=FZ-7KMQ-2PRJ-4TVW") == nil)
    }

    @Test func anAppThatWasNeverLinkedReadsNoOnesHub() throws {
        let address = try #require(URL(string: HubClient.defaultAddress))
        #expect(address.host() == "fleet.invalid", "a name under .invalid never resolves (RFC 2606)")
        #expect(!HubClient.defaultAddress.contains("100."), "no fleet's private address")
        _ = try HubClient.address(HubClient.defaultAddress)
    }

    @Test func aFleetIdIsSixteenHexCharactersAndSaysNothingAboutItsOwner() {
        let made = FleetID.make()
        #expect(FleetID.isValid(made))
        #expect(made.count == 16)
        #expect(FleetID.make() != made)
        #expect(FleetID.isValid("0123456789ABCDEF") == false)
        #expect(FleetID.isValid("0123456789abcde") == false)
    }

    @Test func anAnswerForAnotherFleetIsNotTakenAsOurOwn() throws {
        let answer = try JSONDecoder().decode(ClaimedEntitlement.self, from: Data("""
        {"token": "eyJmbGVldCI6ICIwMTIzNDU2Nzg5YWJjZGVmIn0.c2lnbmF0dXJl", "fleet": "0123456789abcdef",
         "plan": "monthly", "until": 2000000000, "machines": 5, "agents": 10}
        """.utf8))
        #expect(answer.isFor(fleet: "0123456789abcdef"))
        #expect(answer.isFor(fleet: "fedcba9876543210") == false)
    }

    @Test func theClaimGoesOnlyToAnHTTPSChannel() async throws {
        await #expect(throws: ClaimError.notOurSite) {
            try await ClaimCall().claim(key: "FZ-7KMQ-2PRJ-4TVW", fleet: "0123456789abcdef",
                                        channel: "http://founderizer.com")
        }
        await #expect(throws: ClaimError.notAKey) {
            try await ClaimCall().claim(key: "no", fleet: "0123456789abcdef", channel: "https://founderizer.com")
        }
    }
}
