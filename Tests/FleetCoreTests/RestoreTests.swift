import Foundation
import Testing
@testable import FleetCore

/// Putting a copy of the fleet back (owner API 1.5). Everything here can be checked without a hub: reading a copy
/// and saying what is in it, deciding whether the choice is offered at all, the 409 that means this hub already
/// holds work, and the wait for a generation that moves.
///
/// `Fixtures/copy.zip` is written by `zipfile` with the same calls `hub.py`'s `backup_bundle` makes, so the app's
/// own reader is tested against the writer it has to read, and not against itself.

private func fixtureCopy() throws -> URL {
    try #require(Bundle.module.url(forResource: "copy", withExtension: "zip", subdirectory: "Fixtures"))
}

private func manifest(_ fields: [String: Any]) throws -> FleetManifest {
    var all: [String: Any] = [
        "format": 1, "made_at": 1_792_400_000.0, "fleet_id": "0f1e2d3c4b5a6978",
        "agents": ["manager", "vps"],
        "files": ["fleet.sqlite3": ["bytes": 4096, "sha256": String(repeating: "a", count: 64)]]]
    all.merge(fields) { _, new in new }
    return try JSONDecoder().decode(FleetManifest.self, from: JSONSerialization.data(withJSONObject: all))
}

// MARK: - reading the copy

@Test func readsWhatIsInACopyBeforeAnythingIsSent() throws {
    let copy = try ChosenCopy.read(fixtureCopy())
    #expect(copy.manifest.format == 1)
    #expect(copy.manifest.fleet_id == "0f1e2d3c4b5a6978")
    #expect(copy.manifest.agents == ["manager", "studio", "vps", "worker4"])
    #expect(copy.manifest.agentsLine == "4 agents")
    #expect(copy.manifest.agentNames == "Manager, Studio, Vps, Worker4")
    #expect(copy.manifest.recordsSound == true)
    #expect(copy.manifest.made_at == 1_792_400_000.0)
    #expect(copy.bytes == 1387)
    // The records are listed, weighed and digested, and the configuration comes with them.
    #expect(copy.manifest.files["fleet.sqlite3"]?.bytes == 18_816)
    #expect(copy.manifest.files.keys.sorted()
        == ["config/profiles/manager.md", "config/team.json", "fleet.sqlite3"])
}

/// The one loss a restore cannot undo, and the copy is the only thing that names it.
@Test func namesTheMachinesWhoseVaultKeyNoCopyCarries() throws {
    let copy = try ChosenCopy.read(fixtureCopy())
    let line = try #require(copy.manifest.vaultLine)
    #expect(line.contains("Studio") && line.contains("Vps"))
    #expect(try manifest(["vault": [:]]).vaultLine == nil)
    let one = try manifest(["vault": ["studio": ["machine": "studio", "mode": "broker"]]])
    #expect(one.vaultLine?.contains("Studio's own vault") == true)
}

@Test func refusesAFileThatIsNotACopyOfAFleet() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("restore-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let empty = folder.appendingPathComponent("empty.zip")
    try Data().write(to: empty)
    #expect(throws: RestoreError.empty) { _ = try ChosenCopy.read(empty) }

    let prose = folder.appendingPathComponent("letter.zip")
    try Data("this is not a zip, it is a sentence".utf8).write(to: prose)
    #expect(throws: RestoreError.notACopy) { _ = try ChosenCopy.read(prose) }

    #expect(throws: RestoreError.cannotRead("this Mac cannot read that file.")) {
        _ = try ChosenCopy.read(folder.appendingPathComponent("there-is-no-such-file.zip"))
    }
}

/// A copy of a format this app does not read says so by its number, because the owner can then tell whether it is
/// his app or his copy that is old.
@Test func refusesAManifestThisAppDoesNotRead() throws {
    #expect(throws: RestoreError.otherFormat(2)) { try manifest(["format": 2]).check() }
    #expect(throws: RestoreError.notACopy) { try manifest(["files": [:]]).check() }
    #expect(throws: RestoreError.notACopy) { try manifest(["made_at": 0]).check() }
    #expect(throws: RestoreError.notACopy) { try manifest(["fleet_id": "NOT HEX"]).check() }
    // A member that is not the records and not one of the owner's own files: the hub refuses it with 422, and
    // the app does not send 256 MiB to find that out.
    #expect(throws: RestoreError.notACopy) {
        try manifest(["files": ["fleet.sqlite3": ["bytes": 1, "sha256": String(repeating: "a", count: 64)],
                                "etc/passwd": ["bytes": 1, "sha256": String(repeating: "b", count: 64)]]]).check()
    }
    #expect(throws: Never.self) { try manifest([:]).check() }
}

/// A copy made while the central vault answered with a recovery key carries its sealed store as `vault/central.json`
/// (the hub's `CENTRAL_MEMBER`), which only the owner's recovery code opens: the app sends such a copy too.
@Test func takesACopyThatCarriesTheCentralVault() throws {
    let files: [String: Any] = ["fleet.sqlite3": ["bytes": 4096, "sha256": String(repeating: "a", count: 64)],
                                "vault/central.json": ["bytes": 2048, "sha256": String(repeating: "c", count: 64)],
                                "config/team.json": ["bytes": 100, "sha256": String(repeating: "d", count: 64)]]
    #expect(FleetManifest.centralMember == "vault/central.json")
    #expect(throws: Never.self) { try manifest(["files": files]).check() }
    // Only that one name of the folder: another member there is no part of a copy.
    #expect(throws: RestoreError.notACopy) {
        try manifest(["files": files.merging(["vault/other.json": ["bytes": 1, "sha256": String(repeating: "e", count: 64)]]) { a, _ in a }]).check()
    }
}

/// The hub that made the copy runs SQLite's own check every six hours, and the copy carries what it last said.
@Test func saysWhenTheHubItselfDoubtedTheRecords() throws {
    #expect(try manifest(["integrity": "ok"]).recordsSound == true)
    #expect(try manifest(["integrity": "*** in database main ***\nPage 4 is never used"]).recordsSound == false)
    #expect(try manifest([:]).recordsSound == nil)
}

// MARK: - what he must reconnect afterwards

/// A restored fleet has its records and its configuration, and none of the credentials the old hub kept on its own
/// disk. The GitHub App key is first because it is one file and every task that touches code stops without it.
@Test func saysWhatMustBeReconnected() throws {
    let after = try ChosenCopy.read(fixtureCopy()).afterwards
    #expect(after.knows)
    #expect(after.steps.map(\.place) == [.apps, .apps, .mcps, .nowhere])
    #expect(after.steps[0].title.contains("GitHub"))
    #expect(after.steps[1].detail.contains("your 2 Google accounts"))
    #expect(after.steps[2].detail.contains("The one MCP server"))
    #expect(after.steps[3].detail.contains("3 files"))
    #expect(after.steps[3].place.label == nil)          // nothing in the app puts the attachments back
    #expect(after.nothing == nil)                       // this hub had all four, so there is no "and no" line
}

@Test func leavesOutWhatThatHubNeverHad() throws {
    let after = RestoreAfterwards(try manifest(["hub_only": [
        "google": ["present": false], "github_app": ["present": true],
        "mcp": ["present": true, "servers": 0], "attachments": ["present": false]]]))
    #expect(after.knows)
    #expect(after.steps.map(\.place) == [.apps])
    #expect(after.steps[0].title.contains("GitHub"))
    let said = try #require(after.nothing)
    #expect(said.contains("no Google account connected") && said.contains("no MCP server connected"))
}

@Test func aHubThatHadNoneOfThemSaysSo() throws {
    let after = RestoreAfterwards(try manifest(["hub_only": [
        "google": ["present": false], "github_app": ["present": false],
        "mcp": ["present": false], "attachments": ["present": false]]]))
    #expect(after.knows)
    #expect(after.steps.isEmpty)
    #expect(after.nothing?.contains("no GitHub App") == true)
}

/// A copy from a hub older than `hub_only` says nothing about what that hub held, and silence must not read as
/// "there is nothing to reconnect". The live hub's own copy of 20 October 2026 is exactly this one.
@Test func aCopyThatDoesNotSayWhatItsHubHeldSaysThat() throws {
    let after = RestoreAfterwards(try manifest([:]))
    #expect(!after.knows)
    #expect(after.steps.isEmpty)
    let said = try #require(after.nothing)
    #expect(said.contains("does not say") && said.contains("GitHub App key first"))
}

// MARK: - a hub that already holds work

/// The route answers 409 for a hub that has worked, and the app then says what is there. What it can count is
/// what `/ui/state` carries, and the hub counts more than that, so the sentence says so rather than implying that
/// four numbers are the whole of what is about to be replaced.
@Test func saysWhatAHubHoldsBeforeItIsReplaced() {
    let holds = FleetHolds(agents: 4, tasks: 12, goals: 2, needs: 1, reports: 0)
    #expect(!holds.seesNothing)
    #expect(holds.says.contains("12 tasks, 2 goals and 1 thing that needed you"))
    #expect(holds.says.contains("conversations, duties and wake-up rules"))
    #expect(holds.says.contains("kept on the hub server"))

    let one = FleetHolds(agents: 1, tasks: 1, goals: 0, needs: 0, reports: 3)
    #expect(one.says.contains("1 task and 3 reports"))

    // A hub whose only work is a duty or a wake-up rule refuses the restore while this count is empty, so the
    // sentence never claims there is nothing there.
    let unseen = FleetHolds(agents: 2, tasks: 0, goals: 0, needs: 0, reports: 0)
    #expect(unseen.seesNothing)
    #expect(!unseen.says.contains("This hub holds"))
    #expect(unseen.says.contains("conversations, duties and wake-up rules"))
}

// MARK: - whether the choice is offered at all

private func hub(features: [String] = ["health", "restore"], agents: [String] = ["manager"],
                 tasks: [[String: Any]] = [], goals: [[String: Any]] = [],
                 needs: [[String: Any]] = []) throws -> HubState {
    let object: [String: Any] = [
        "schema_version": 1, "db": "dff7118cbef9", "time": 1000.0, "ui_features": features,
        "agents": agents.map { ["name": $0, "role": $0 == "manager" ? "manager" : "worker",
                                "runtime": "claude", "can": []] },
        "goals": goals, "tasks": tasks, "notes": [], "needs": needs, "permissions": [], "messages": [],
        "reports": []]
    return try HubState.decode(JSONSerialization.data(withJSONObject: object))
}

private func task(_ id: Int) -> [String: Any] {
    ["id": id, "title": "Something", "details": "", "done_when": "Checked", "needs": "none", "goal": "",
     "owner": "vps", "requester": "manager", "state": "working", "created": 900.0, "attempt": 1,
     "restarts": 0, "nudge_level": 0, "stop_sent": 0]
}

/// A hub from before this half of owner API 1.5 serves the two copy routes and not `POST /ui/restore`, so the app
/// must offer nothing it cannot do. `health` is not the same feature and does not stand in for it.
@Test func aHubThatCannotPutACopyBackIsNeverOfferedOne() throws {
    #expect(!RestoreOffer.inHealth(try hub(features: ["health"])))
    #expect(!RestoreOffer.atClaim(try hub(features: ["health"]), claimed: true))
    #expect(!RestoreOffer.inHealth(nil))
    #expect(!RestoreOffer.atClaim(nil, claimed: true))
    #expect(RestoreOffer.inHealth(try hub()))
}

/// The claim is the moment the owner asked for: on the day his machine dies he is standing in front of a fresh
/// hub, not hunting through Settings.
@Test func theChoiceIsOfferedOnAHubThisMacJustClaimed() throws {
    #expect(RestoreOffer.atClaim(try hub(), claimed: true))
    // A fleet with work on it, just claimed: still offered. The route's own 409 is what asks him again, and the
    // app must not decide for him that a hub he claimed is one he meant to keep.
    #expect(RestoreOffer.atClaim(try hub(agents: ["manager", "vps"], tasks: [task(1)]), claimed: true))
}

/// "I already have one" is not a claim. A hub with nothing on it is the same fresh hub by another road and gets
/// the choice; a working fleet he is reconnecting the app to does not, and has it on System status.
@Test func pointingTheAppAtAWorkingFleetIsNotAnInvitationToReplaceIt() throws {
    #expect(RestoreOffer.atClaim(try hub(), claimed: false))                        // one agent, no work
    #expect(!RestoreOffer.atClaim(try hub(agents: ["manager", "vps", "studio"]), claimed: false))
    #expect(!RestoreOffer.atClaim(try hub(tasks: [task(1)]), claimed: false))
    #expect(!RestoreOffer.atClaim(try hub(needs: [["id": 3, "title": "Which one?", "why": "", "todo": "",
                                                   "raised": 900.0, "by": "manager"]]), claimed: false))
    // Wherever the claim screen keeps quiet, System status still has it.
    #expect(RestoreOffer.inHealth(try hub(agents: ["manager", "vps", "studio"])))
}

/// The route answers 409 for two different things and the words beside the status are prose this app does not
/// read. So the hub is asked again, and what it answers decides: a generation that moved was a stale send and
/// nothing was written; the same generation is a hub that already holds work and must be asked about.
@Test func tellsAStaleSendFromAHubThatAlreadyHoldsAFleet() throws {
    let sent = "dff7118cbef9"
    #expect(RestoreConflict.read(sentWith: sent, now: try hub(tasks: [task(1)])) ==
            .holdsWork(FleetHolds(agents: 1, tasks: 1, goals: 0, needs: 0, reports: 0)))
    // The same hub, a generation on: the copy went nowhere, so nothing is replaced and nothing is asked.
    #expect(RestoreConflict.read(sentWith: "an-older-one", now: try hub()) == .staleGeneration)
    // It did not answer the second question either. The careful reading wins: he is asked before anything
    // replaces anything.
    #expect(RestoreConflict.read(sentWith: sent, now: nil) == .unknown)
    #expect(RestoreConflict.read(sentWith: sent, now: nil).holds == nil)
}

// MARK: - the wait

/// The hub stages the records and restarts itself to take them, and a new `db` is the one signal that it did: a
/// hub makes a new generation when it took a staged copy and at no other restart. So the hub going quiet is not a
/// failure while this runs, and nothing says the restore worked until that generation has really moved.
@Test func theWaitCallsARestartARestartAndNothingElseSuccess() {
    let watch = RestoreWatch(before: "dff7118cbef9", restarts: true)
    #expect(watch.read(.unreachable, waited: 1) == .restarting)
    #expect(watch.read(.unreachable, waited: 60) == .restarting)
    #expect(watch.read(.answered("dff7118cbef9"), waited: 30) == .restarting)
    #expect(watch.read(.answered("9a0c41e2ab77"), waited: 30) == .landed("9a0c41e2ab77"))
}

@Test func theWaitGivesUpAfterLongEnoughAndNeverOverAGenerationThatMoved() {
    let watch = RestoreWatch(before: "dff7118cbef9", restarts: true)
    #expect(watch.read(.unreachable, waited: RestoreWatch.patience + 1) == .lost)
    #expect(watch.read(.answered("dff7118cbef9"), waited: RestoreWatch.patience + 1) == .lost)
    // A slow machine is still a landing: the generation moved, however long it took.
    #expect(watch.read(.answered("9a0c41e2ab77"), waited: 10_000) == .landed("9a0c41e2ab77"))
    #expect(watch.read(.answered(""), waited: 5) == .restarting)
}

/// A fleet that turned the hub's restart command off gets no restart, so the records wait beside the database for
/// its next start. Watching for a generation that will not move until somebody restarts it would be a lie.
@Test func aHubThatDoesNotRestartItselfLeavesHimOneStep() {
    let watch = RestoreWatch(before: "dff7118cbef9", restarts: false)
    #expect(watch.read(.unreachable, waited: 0) == .staged)
    #expect(watch.read(.answered("dff7118cbef9"), waited: 600) == .staged)
    #expect(watch.read(.answered("9a0c41e2ab77"), waited: 1) == .landed("9a0c41e2ab77"))
}

// MARK: - the receipt

@Test func readsTheReceiptAndWhatItChanged() throws {
    let data = Data(#"""
    {"ok":true,"fleet_id":"0f1e2d3c4b5a6978","made_at":1792400000.0,"records_bytes":802816,
     "files":["config/team.json","fleet.sqlite3"],"changed":["team.json"],"removed":["profiles/old.md"],
     "keep_replaced":false,"restarting":true,"replayed":false}
    """#.utf8)
    let receipt = try JSONDecoder().decode(RestoreReceipt.self, from: data)
    #expect(receipt.ok)
    #expect(receipt.restarting)
    #expect(receipt.replayed == false)
    #expect(receipt.changed == ["team.json"])
    #expect(receipt.removed == ["profiles/old.md"])
    #expect(receipt.records_bytes == 802_816)
}
