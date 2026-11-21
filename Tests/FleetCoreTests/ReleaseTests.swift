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
        // The owner, 14 November 2026: "clicked on Update fleet, seems stuck". The run's word is a wait, which the page
        // draws in moving words; nothing else on the row is one.
        #expect(running.working)
        let still = [try state().stand, try state(["IDLE": "false", "TASKS": "[12]"]).stand,
                     try state(["ROWS": Self.started(state: "done", step: "follow", reached: true)]).stand,
                     try state(["ROWS": Self.started(state: "failed", step: "push", says: "refused")]).stand]
        #expect(still.allSatisfy { !$0.working })
    }

    @Test func aPressTheHubTookSaysUpdatingBeforeTheRunWritesItsRow() throws {
        // The run asks our channel first and marks the release updating only then: the white Update to … came back
        // after the press, and a second press got "already checking or updating" (the review of 14 November 2026).
        let started = try state(["RUNNING": "true"])
        #expect(started.stand.take?.version == "2026.10.3", "the hub's own row has not moved yet")
        let pressed = started.stand(pressed: true)
        #expect(pressed.working && pressed.take == nil)
        #expect(pressed.value == "Updating")
        #expect(pressed.says == "This fleet is updating to 2026.10.3…")
        // Without his press, or once nothing runs, the row is the hub's own.
        #expect(started.stand(pressed: false) == started.stand)
        let ended = try state()
        #expect(ended.stand(pressed: true) == ended.stand)
        // And the run's own row, once written, says the same.
        let running = try state(["RUNNING": "true", "ROWS": Self.started(state: "updating", step: "merge")])
        #expect(running.stand(pressed: true) == running.stand)
    }

    @Test func aRunThatFailedIsTheOneThingToActOn() throws {
        let stand = try state(["ROWS": Self.started(state: "failed", step: "push",
                                                    says: "the push to config was refused")]).stand
        #expect(stand.warn)
        #expect(stand.value == "Did not finish")
        #expect(stand.says == "the push to config was refused")
    }

    /// One row of the hub's answer, by its id, version and state; a `done` row reached its release.
    private static func release(_ id: Int, _ version: String, _ state: String) -> String {
        let revision = String(repeating: String(id % 10), count: 40)
        let done = state == "done"
        return """
        {"id": \(id), "revision": "\(revision)", "version": "\(version)", "notes": null, "minimum": null, "hold": false,
         "state": "\(state)", "step": \(done ? "\"follow\"" : "null"), "says": null, "pinned": null,
         "reached": \(done ? "\"\(revision)\"" : "null"), "seen_at": 1792267272,
         "started_at": \(done ? "1792267300" : "null"), "finished_at": \(done ? "1792267400" : "null"),
         "automatic": true, "applied": \(done)}
        """
    }

    /// **A release that no run took and that stands under the one this fleet runs is never offered** (the owner, 15
    /// November 2026): his fleet ran 2026.11.494, 2026.11.488 stood `verified` under it, and the page offered "Update to
    /// 2026.11.488", which his press could not take. A release above it is offered as before.
    @Test func aReleaseUnderTheOneTheFleetRunsIsNeverOffered() throws {
        let under = try state(["ROWS": [Self.release(352, "2026.11.494", "done"),
                                        Self.release(346, "2026.11.488", "verified")].joined(separator: ",")])
        #expect(under.offered == nil && under.stand.take == nil)
        #expect(under.stand.value == "2026.11.494")
        let above = try state(["ROWS": [Self.release(353, "2026.11.495", "verified"), Self.release(352, "2026.11.494", "done"),
                                        Self.release(346, "2026.11.488", "verified")].joined(separator: ",")])
        #expect(above.offered?.version == "2026.11.495" && above.stand.take?.version == "2026.11.495")
    }

    /// **A `passed` release is code the fleet runs** (owner API 1.177): never offered, and the fleet's version when no
    /// run took a newer one, as on a new hub whose checkout came at that release.
    @Test func aPassedReleaseIsWhatTheFleetRunsAndIsNotOffered() throws {
        let passed = try state(["ROWS": Self.release(5, "2026.11.494", "passed")])
        #expect(passed.offered == nil && passed.stand.take == nil)
        #expect(passed.current?.version == "2026.11.494" && passed.stand.value == "2026.11.494")
    }

    /// A release whose run stopped at the fetch, with the hub's own line.
    private static func unfetched(_ id: Int, _ version: String) -> String {
        release(id, version, "kept").replacingOccurrences(of: "\"step\": null, \"says\": null", with:
            "\"step\": \"fetch\", \"says\": \"This server could not download release \(version) from github.com. The "
            + "fetch of upstream failed: fatal: Failed to connect to github.com port 443\"")
    }
    private static let unreached = "Your fleet could not download release 2026.11.732: its server cannot reach the "
        + "address it takes releases from."

    /// **Only a release this fleet reached makes it up to date, and a newer one that it could not download says so** (the
    /// owner's test fleet, 21 November 2026): its server had no route to github.com, every release from 2026.11.714 to
    /// .732 stopped `kept` at the fetch, and the row said only "Unknown" for days; with an older release reached in
    /// view, it said "Your fleet runs the newest release" while every newer one stopped.
    @Test func onlyAReleaseThisFleetReachedMakesItUpToDate() throws {
        let stand = try state(["ROWS": Self.started(state: "done", step: "follow", reached: true)]).stand
        #expect(stand.value == "2026.10.3")
        #expect(stand.take == nil)
        #expect(stand.says.hasPrefix("Your fleet runs the newest release. Asked "))
        // A fleet on a revision no release of ours reached says that, instead of claiming to be current.
        let stray = try state(["ROWS": Self.row("\"hold\": false, \"state\": \"kept\", \"step\": null, \"says\": null")]).stand
        #expect(stray.says == "Your fleet has not taken one of our releases yet.")
        #expect(stray.value == "Unknown")
        let none = try state(["ROWS": [Self.unfetched(732, "2026.11.732"),
                                       Self.unfetched(731, "2026.11.731")].joined(separator: ",")]).stand
        #expect(none.says == Self.unreached && none.warn && none.value == "Did not finish" && none.take == nil)
        let behind = try state(["ROWS": [Self.unfetched(732, "2026.11.732"),
                                         Self.release(713, "2026.11.713", "done")].joined(separator: ",")])
        #expect(behind.stand.says == Self.unreached && behind.stand.warn && behind.current?.version == "2026.11.713")
    }

    /// The Spanish of that line is in the table.
    @Test func aReleaseThisFleetCouldNotDownloadSaysSoInSpanish() throws {
        let read = try state(["ROWS": Self.unfetched(732, "2026.11.732")])
        let says = try SpanishTable.run { read.stand.says }
        #expect(says == "Tu equipo no pudo descargar la versión 2026.11.732: su servidor no puede conectar con la "
                + "dirección de la que obtiene las versiones.")
    }

    /// A release whose newest run stopped at `step` with the hub's `cause` (owner API 1.293).
    private static func stopped(_ id: Int, _ version: String, _ state: String, step: String, cause: String) -> String {
        release(id, version, state).replacingOccurrences(of: "\"step\": null", with: "\"step\": \"\(step)\"")
            .replacingOccurrences(of: "\"applied\": false", with: "\"applied\": false, \"cause\": \"\(cause)\"")
    }

    /// **The row says the cause of the newest run, by its kind** (the reliability plan of 21 November 2026, W20 part 1):
    /// a network cause says that the fleet tries again by itself and takes the release when its server reaches the
    /// address again, `memory` that the server has too little memory for the checks, both in orange with "Did not
    /// finish"; a release that failed its checks is said as that, never as an address the server cannot reach, with
    /// the release the fleet runs at the right. A fleet that takes no release by itself, and a hub that gives no cause,
    /// keep the line of before.
    @Test func theRowSaysTheCauseOfTheNewestRun() throws {
        let offline = Self.stopped(732, "2026.11.732", "kept", step: "fetch", cause: "no_ipv4_route")
        let unreachable = try state(["AUTO": "true", "ROWS": offline])
        let network = unreachable.stand
        #expect(network.says == "Your fleet could not download release 2026.11.732 because its server cannot reach "
                + "the address it takes releases from; it tries again by itself and takes the release when its server "
                + "reaches that address again.")
        #expect(network.warn && network.value == "Did not finish" && network.take == nil)
        #expect(try state(["AUTO": "false", "ROWS": offline]).stand.says == Self.unreached)
        #expect(try state(["AUTO": "true", "ROWS": Self.unfetched(732, "2026.11.732")]).stand.says == Self.unreached)
        let short = try state(["AUTO": "true", "ROWS": Self.stopped(733, "2026.11.733", "kept", step: "room",
                                                                    cause: "memory")])
        let memory = short.stand
        #expect(memory.says == "Your fleet's server has too little memory for the checks of release 2026.11.733, so "
                + "your fleet did not take it.")
        #expect(memory.warn && memory.value == "Did not finish")
        let failed = try state(["AUTO": "true", "ROWS": [Self.stopped(734, "2026.11.734", "rolled_back", step: "selftest",
                                                                      cause: "check"),
                                                         Self.release(713, "2026.11.713", "done")].joined(separator: ",")]).stand
        #expect(failed.says == "Release 2026.11.734 did not pass its checks on your fleet, so your fleet stays on the "
                + "release it runs.")
        #expect(!failed.warn && failed.value == "2026.11.713")
        let raced = try state(["AUTO": "true", "ROWS": Self.stopped(735, "2026.11.735", "kept", step: "hold",
                                                                    cause: "busy")]).stand
        #expect(!raced.warn && raced.value == "Unknown")
        // A network cause at the push is the fleet's own repository: the release was downloaded, and the row says
        // nothing of an address that the server cannot reach.
        let pushed = try state(["AUTO": "true", "ROWS": [Self.stopped(736, "2026.11.736", "rolled_back", step: "push",
                                                                      cause: "http"),
                                                         Self.release(713, "2026.11.713", "done")].joined(separator: ",")]).stand
        #expect(!pushed.says.contains("download") && !pushed.warn && pushed.value == "2026.11.713")
        let full = try state(["AUTO": "true", "ROWS": Self.stopped(737, "2026.11.737", "rolled_back", step: "verify",
                                                                   cause: "disk")])
        #expect(full.stand.says == "Your fleet's server has too little free disk space for release 2026.11.737, so "
                + "your fleet did not take it.")
        #expect(full.stand.warn && full.stand.value == "Did not finish")
        let failing = try state(["AUTO": "true", "ROWS": Self.stopped(734, "2026.11.734", "rolled_back", step: "selftest",
                                                                      cause: "check")])
        let spanish = try SpanishTable.run {
            [unreachable.stand.says, short.stand.says, full.stand.says, failing.stand.says]
        }
        #expect(spanish == [
            "Tu equipo no pudo descargar la versión 2026.11.732 porque su servidor no puede conectar con la dirección "
                + "de la que obtiene las versiones; lo vuelve a intentar por sí solo e instalará la versión cuando su "
                + "servidor vuelva a conectar con esa dirección.",
            "El servidor de tu equipo tiene muy poca memoria para las comprobaciones de la versión 2026.11.733, así "
                + "que tu equipo no la instaló.",
            "El servidor de tu equipo tiene muy poco espacio libre en disco para la versión 2026.11.737, así que tu "
                + "equipo no la instaló.",
            "La versión 2026.11.734 no pasó sus comprobaciones en tu equipo, así que tu equipo sigue con la versión "
                + "que usa."])
    }

    /// **A run that stopped for a moment, which the sweep takes again, is no fault on the row** (the reviews of 21
    /// November 2026): a `kept` row at `hold`, from a pressed Update that raced a turn, names task codes, and a
    /// `rolled_back` row at `push` passed every check; drawn in orange they would show codes or false words.
    @Test func aRunTheSweepTakesAgainIsNoFaultOnTheRow() throws {
        let raced = try state(["ROWS": Self.row("\"hold\": false, \"state\": \"kept\", \"step\": \"hold\", \"says\": "
                                                + "\"This fleet started working before the update did: T-12\"")]).stand
        #expect(!raced.warn && !raced.says.contains("T-12") && raced.value == "Unknown")
        let pushed = try state(["ROWS": [Self.release(9, "2026.11.709", "rolled_back"),
                                         Self.release(8, "2026.11.708", "done")].joined(separator: ",")
                                    .replacingOccurrences(of: "\"state\": \"rolled_back\", \"step\": null",
                                                          with: "\"state\": \"rolled_back\", \"step\": \"push\"")]).stand
        #expect(!pushed.warn && pushed.value == "2026.11.708")
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
