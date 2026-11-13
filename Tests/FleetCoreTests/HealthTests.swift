import Foundation
import Testing
@testable import FleetCore

@Test func healthBindsGenerationAndDoesNotTurnMissingMeasuresIntoZero() throws {
    let data = Data(#"{"db":"generation","ok":true,"time":100,"hub":{"integrity":{}},"helpers":[],"warnings":[]}"#.utf8)
    let health = try JSONDecoder().decode(FleetHealth.self, from: data)
    try health.validate(database: "generation")
    #expect(health.hub.disk_free_bytes == nil)
    #expect(health.hub.db_bytes == nil)
    #expect(health.hub.integrity.result == nil)
    #expect(throws: (any Error).self) { try health.validate(database: "different") }
}

/// **The health reading this Mac keeps with the fleet's reads back whole, and only for its own hub generation** (the
/// polish of 30 October 2026): the Settings dot draws from it in a launch's first frame.
@Test func aKeptHealthReadingReadsBackForItsOwnGeneration() throws {
    let read = try JSONDecoder().decode(FleetHealth.self, from: JSONSerialization.data(withJSONObject: [
        "db": "generation", "ok": false, "time": 100,
        "hub": ["db_bytes": 100, "disk_free_bytes": 2048, "integrity": ["result": "ok", "at": 99]],
        "helpers": [["agent": "mini", "last_seen": 90, "offline": true]],
        "warnings": [["kind": "helper_offline", "detail": "Silent since 23:06.", "fix": "Check it.", "agent": "mini"],
                     ["kind": "backup_missing", "detail": "None saved yet."]],
        "backups_enabled": true]))
    let data = try JSONEncoder().encode(read)
    let kept = try #require(FleetHealth.kept(data, database: "generation"))
    #expect(kept.warnings.map(\.kind) == ["helper_offline", "backup_missing"])
    #expect(kept.warnings.first?.agent == "mini" && kept.warnings.first?.fix == "Check it.")
    #expect(FleetHealth.blocks(kept.warnings).map(\.title) == FleetHealth.blocks(read.warnings).map(\.title))
    #expect(kept.helpers.first?.offline == true && kept.hub.disk_free_bytes == 2048 && kept.takesCopies)
    // Another hub generation, or a file that is no reading, keeps nothing.
    #expect(FleetHealth.kept(data, database: "another") == nil)
    #expect(FleetHealth.kept(Data("not json".utf8), database: "generation") == nil)
}

/// **A kept health reading goes when a health read of this launch fails** (review B, round 4 of 30 October 2026): the
/// Settings dot showed the last launch's warnings until System status or Servers read the health again.
@Test func aKeptHealthReadingGoesWhenAHealthReadFails() throws {
    let read = try JSONDecoder().decode(FleetHealth.self, from: JSONSerialization.data(withJSONObject: [
        "db": "generation", "ok": false, "time": 100, "hub": ["integrity": [String: Any]()], "helpers": [Any](),
        "warnings": [["kind": "backup_missing", "detail": "None saved yet."]]]))
    var kept = KeptReading(read)
    #expect(kept.reading(of: "generation")?.warnings.map(\.kind) == ["backup_missing"])
    #expect(kept.reading(of: "another") == nil)
    kept.readFailed()
    #expect(kept.reading(of: "generation") == nil)
}

@Test func healthRejectsContradictoryOrDuplicateStatus() throws {
    func health(_ helpers: [[String: Any]], _ warnings: [[String: Any]], bytes: Int = 100) throws -> FleetHealth {
        try JSONDecoder().decode(FleetHealth.self, from: JSONSerialization.data(withJSONObject: [
            "db": "generation", "ok": true, "time": 100,
            "hub": ["db_bytes": bytes, "integrity": ["result": "ok", "at": 99]],
            "helpers": helpers, "warnings": warnings]))
    }
    #expect(throws: (any Error).self) { try health([], [["kind": "disk_low", "detail": "Low disk"]]).validate(database: "generation") }
    let helper: [String: Any] = ["agent": "vps", "offline": false]
    #expect(throws: (any Error).self) { try health([helper, helper], []).validate(database: "generation") }
    #expect(throws: (any Error).self) { try health([], [], bytes: -1).validate(database: "generation") }
}

/// Every warning the hub can raise carries the one line that puts it right and, when it is about one agent, that
/// agent. The owner, 19 October 2026: a screen that reports something wrong must carry the way to put it right,
/// so this is what decides the button, and no row may be left without one.
@Test func everyWarningKindHasOneActionBehindIt() throws {
    func warning(_ kind: String, agent: String? = nil) -> FleetHealth.Warning {
        FleetHealth.Warning(kind: kind, detail: "something", fix: "do this", agent: agent)
    }
    #expect(warning("backup_missing").act == .saveCopy)
    #expect(warning("backup_old").act == .saveCopy)
    #expect(warning("machine_behind", agent: "vps").act == .update(agent: "vps"))
    #expect(warning("machine_failed", agent: "vps").act == .update(agent: "vps"))
    #expect(warning("machine_stale", agent: "vps").act == .openMachine("vps"))
    #expect(warning("helper_offline", agent: "vps").act == .openMachine("vps"))
    #expect(warning("disk_low", agent: "manager").act == .openMachine("manager"))
    // A session that is not running is the one manager warning a button settles (`ManagerSession`). Its others are
    // not put right by a start, so they keep the page where its session and its machine are.
    #expect(warning("manager_down", agent: "manager").act == .startManager(agent: "manager"))
    #expect(warning("manager_down").act == .tellUs)
    #expect(warning("manager_switch_stalled", agent: "manager").act == .openAgent("manager"))
    #expect(warning("manager_limited", agent: "manager").act == .openAgent("manager"))
    #expect(warning("manager_screen", agent: "manager").act == .openAgent("manager"))
    #expect(warning("manager_silent", agent: "manager").act == .openAgent("manager"))
    // The hub's own records and a schema step they refused are ours, not his: saying so is the honest action.
    #expect(warning("integrity").act == .tellUs)
    #expect(warning("schema").act == .tellUs)
    // A hub from before this naming, or a kind this build does not know, still gets a button and never a blank row.
    #expect(warning("machine_behind").act == .tellUs)
    #expect(warning("something_new").act == .tellUs)
    #expect(warning("something_new", agent: "vps").act == .openMachine("vps"))
    for kind in ["backup_missing", "backup_old", "integrity", "schema", "disk_low", "helper_offline",
                 "machine_stale", "machine_behind", "machine_failed", "manager_down", "whatever_next"] {
        #expect(!warning(kind, agent: "vps").title.isEmpty)
        #expect(warning(kind, agent: "vps").act.label.isEmpty == false)
    }
    #expect(warning("machine_behind", agent: "vps").act.label == "Update Vps")
    #expect(warning("manager_down", agent: "manager").act.label == "Start the session")
    #expect(warning("manager_down", agent: "manager").title == "Manager's session is not running")
    #expect(warning("backup_missing").title == "No copy of your fleet")
    // The hub's kind is never his title: an agent near its limit is said in his words.
    #expect(warning("allowance_pace", agent: "mini").title == "Mini nears its usage limit")
}

@Test func theCopyAndItsWarningComeOffTheSameReading() throws {
    let data = Data(#"""
    {"db":"g","ok":false,"time":100,"backups_enabled":true,
     "backup":{"at":90,"bytes":4096,"sha256":"aa01","age":10},
     "hub":{"integrity":{}},"helpers":[],
     "warnings":[{"kind":"backup_old","detail":"The last confirmed backup is 2 days old.","fix":"Save a new copy."}]}
    """#.utf8)
    let health = try JSONDecoder().decode(FleetHealth.self, from: data)
    // A digest that is not one is a hub this app does not believe, so nothing is offered for confirming.
    #expect(throws: (any Error).self) { try health.validate(database: "g") }
    let good = Data(String(data: data, encoding: .utf8)!
        .replacingOccurrences(of: "\"aa01\"", with: "\"\(String(repeating: "a", count: 64))\"").utf8)
    let read = try JSONDecoder().decode(FleetHealth.self, from: good)
    try read.validate(database: "g")
    #expect(read.takesCopies)
    #expect(read.backup?.bytes == 4096)
    #expect(read.warnings.first?.act == .saveCopy)
    #expect(read.warnings.first?.fix == "Save a new copy.")
}

/// A hub from before owner API 1.5, and one whose team file turned the copy off: neither offers a copy button,
/// and neither raises a copy warning either.
@Test func aHubThatServesNoCopyIsNotOfferedOne() throws {
    let old = try JSONDecoder().decode(FleetHealth.self, from: Data(
        #"{"db":"g","ok":true,"time":1,"hub":{"integrity":{}},"helpers":[],"warnings":[]}"#.utf8))
    #expect(!old.takesCopies)
    #expect(old.backup == nil)
    let off = try JSONDecoder().decode(FleetHealth.self, from: Data(
        #"{"db":"g","ok":true,"time":1,"backups_enabled":false,"hub":{"integrity":{}},"helpers":[],"warnings":[]}"#.utf8))
    #expect(!off.takesCopies)
}

/// The name a copy is offered under comes from the hub, and a hub is still the network: it may not send this Mac
/// up a directory or write a dotfile.
@Test func theNameOfACopyCannotLeaveTheFolderTheOwnerPicks() {
    let time = Date(timeIntervalSince1970: 1_760_000_000)
    #expect(FleetCopy.name(fromDisposition: "attachment; filename=\"founderizer-abc-20261019T101500Z.zip\"")
            == "founderizer-abc-20261019T101500Z.zip")
    #expect(FleetCopy.name(fromDisposition: "attachment; filename=\"../../etc/passwd.zip\"", at: time)
            == "passwd.zip")
    for refused in ["attachment; filename=\"/etc/shadow\"", "attachment; filename=\".bashrc\"",
                    "attachment; filename=\"copy.command\"", "attachment", nil] {
        #expect(FleetCopy.name(fromDisposition: refused, at: time) == "founderizer-20251009T085320Z.zip")
    }
}

/// "The manager is not signed in" does not stand over the manager's own setup or sign-in, which is that sign-in; it
/// stands over every other page, and every other warning stands over its setup too.
@Test func theNotSignedInBandDoesNotStandOverTheManagersOwnSignIn() {
    #expect(ManagerSession.signedOutKind == "signed_out")
    #expect(!ManagerSession.bandShows(kind: "signed_out", overItsSetup: true))
    #expect(ManagerSession.bandShows(kind: "signed_out", overItsSetup: false))
    for kind in ["down", "limited", "screen", "silent", "switching", "switch_stalled", "", "SIGNED_OUT"] {
        #expect(ManagerSession.bandShows(kind: kind, overItsSetup: true))
    }
    #expect(ManagerSession.bandShows(kind: nil, overItsSetup: true))
}

/// The start of the manager's standing session (`manager_start`). The machine's own helper starts a session that
/// went by itself, so this is the owner's hand on the same switch, for the one warning a start settles.
@Test func onlyASessionThatIsNotRunningCarriesItsStart() throws {
    #expect(ManagerSession.feature == "manager_start")
    #expect(ManagerSession.startable(kind: "down"))
    for kind in ["limited", "screen", "silent", "switching", "switch_stalled", "", "DOWN"] {
        #expect(!ManagerSession.startable(kind: kind))
    }
    #expect(!ManagerSession.startable(kind: nil))
    let command = OwnerCommand.managerStart(agent: "manager")
    #expect(command.route == "ui/machines/manager/manager")
    #expect(command.requiredFeature == "manager_start")
    #expect(command.fields == ["agent": "manager"])
    #expect(command.label == "Start the session of Manager")
    // It carries no input of its own: the route names the agent, and the hub takes nothing else.
    let body = try command.bodyFields(text: "")
    #expect(body as? [String: String] == ["agent": "manager", "note": ""])
}

/// The kinds the hub raises that had no title of his: each says its thing in his words, never the hub's kind in Title
/// Case ("Timers Stalled"; fix round 2, T-37), in seven words at most.
@Test func everyWarningKindHasATitleInHisWords() {
    for kind in ["allowance_spent", "timers_stalled", "vault_behind", "tasks_stuck", "circles_stuck", "reports_undecided"] {
        let title = FleetHealth.Warning(kind: kind, detail: "x", agent: "mini").title
        #expect(title != kind.replacingOccurrences(of: "_", with: " ").capitalized)
        #expect(title.split(separator: " ").count <= 7)
    }
    #expect(FleetHealth.Warning(kind: "allowance_spent", detail: "x", agent: "nova").title == "Nova reached its usage limit")
    #expect(FleetHealth.Warning(kind: "timers_stalled", detail: "x").title == "The hub's timers stopped")
}

/// One block for one agent's server, saying each fact once: a server that sent no status beside a helper that is
/// silent is the same fact (fix round 2, T-37: "Silent since 23:06." and not also "No status for ten minutes.").
@Test func oneAgentsWarningsAreOneBlockThatSaysEachFactOnce() {
    let blocks = FleetHealth.blocks([
        .init(kind: "backup_missing", detail: "None saved yet.", fix: "Save one."),
        .init(kind: "helper_offline", detail: "Silent since 23:06.", fix: "Open Mini.", agent: "mini"),
        .init(kind: "machine_stale", detail: "No status for ten minutes.", fix: "Open Mini.", agent: "mini"),
        .init(kind: "allowance_pace", detail: "77% of its week is used.", fix: "Tell Manager.", agent: "nova"),
    ])
    #expect(blocks.map(\.title) == ["No copy of your fleet", "Mini is not answering", "Nova nears its usage limit"])
    #expect(blocks[1].detail == "Silent since 23:06.")
    #expect(blocks[1].fixes == ["Open Mini."])
    #expect(blocks[1].acts == [.openMachine("mini")])
    // A server that is only stale says so: the fact is its own then.
    let stale = FleetHealth.blocks([.init(kind: "machine_stale", detail: "No status for ten minutes.", agent: "vps")])
    #expect(stale.first?.detail == "No status for ten minutes.")
}

/// **Only an agent's server is one block** (review A1, fix round 2): the hub's `agent` names the page a button opens.
/// The manager's limit, its spent allowance, stuck tasks and undecided reports were one block "The manager needs you"
/// with two "Open Manager" buttons, and the hub's stalled timers carried the session's and the disk's facts.
@Test func warningsThatNameOneAgentAreBlocksOfTheirOwnUnlessTheyAreAboutItsServer() {
    let manager = FleetHealth.blocks([
        .init(kind: "manager_limited", detail: "The manager reached its usage limit.", fix: "Answer its limit menu.",
              agent: "manager"),
        .init(kind: "allowance_spent", detail: "All of its 7-day limit is used.", fix: "Sign Manager in to another account.",
              agent: "manager"),
        .init(kind: "tasks_stuck", detail: "2 tasks are stuck.", fix: "Tell Manager what to do with them.", agent: "manager"),
        .init(kind: "reports_undecided", detail: "3 reports wait for a decision.", fix: "Ask Manager to decide them.",
              agent: "manager"),
    ])
    #expect(manager.map(\.title) == ["The manager needs you", "Manager reached its usage limit", "Some tasks are stuck",
                                     "Reports wait for a decision"])
    #expect(manager.allSatisfy { $0.warnings.count == 1 && $0.fixes.count == 1 })
    let hub = FleetHealth.blocks([
        .init(kind: "timers_stalled", detail: "Since 14:53, nothing is restarted.", agent: "manager"),
        .init(kind: "manager_down", detail: "The manager session is not running.", agent: "manager"),
        .init(kind: "disk_low", detail: "The hub disk has 312 MiB free.", agent: "manager"),
    ])
    #expect(hub.map(\.title) == ["The hub's timers stopped", "Manager's session is not running",
                                 "The hub's disk is nearly full"])
    #expect(hub.map(\.detail) == ["Since 14:53, nothing is restarted.", "The manager session is not running.",
                                  "The hub disk has 312 MiB free."])
    // A silent helper and its server's own warnings stay one block; its usage is a block of its own, and an older
    // version is the block of every agent that runs one (4 November 2026).
    let mini = FleetHealth.blocks([
        .init(kind: "helper_offline", detail: "Silent since 23:06.", agent: "mini"),
        .init(kind: "machine_stale", detail: "No status for ten minutes.", agent: "mini"),
        .init(kind: "machine_behind", detail: "It runs an old revision.", agent: "mini"),
        .init(kind: "allowance_pace", detail: "77% of its week is used.", agent: "mini"),
    ])
    #expect(mini.map(\.title) == ["Mini is not answering", "Mini runs an older version", "Mini nears its usage limit"])
    #expect(mini[0].acts == [.openMachine("mini")])
    #expect(mini[1].acts == [.updateFleet(["mini"])])
    // No block has two buttons with one label.
    for block in manager + hub + mini { #expect(Set(block.acts.map(\.label)).count == block.acts.count) }
}

/// **A worker's usage line tells him to tell the manager, so its button opens the manager's chat** (fix round 3, item
/// 35): "Open Nova" opened Nova's server page under "Tell Manager what must not wait."
@Test func aWorkersUsageWarningOpensTheManagersChat() {
    let pace = FleetHealth.Warning(kind: "allowance_pace", detail: "77% of its week.", fix: "Tell Manager what must not wait.",
                                   agent: "nova")
    #expect(pace.act(manager: "manager") == .openAgent("manager"))
    #expect(pace.act(manager: "manager").label == "Open Manager")
    #expect(FleetHealth.blocks([pace], manager: "manager").first?.acts == [.openAgent("manager")])
    // The manager's own usage keeps its own button; without a manager's name nothing changes.
    let own = FleetHealth.Warning(kind: "allowance_spent", detail: "All of it.", agent: "manager")
    #expect(own.act(manager: "manager") == .openMachine("manager"))
    #expect(pace.act == .openMachine("nova"))
}

/// **A storage size keeps one decimal** (fix round 3b): "829,83 GB" became "829,8 GB" between two reads of System status.
@Test func aStorageSizeKeepsOneDecimal() {
    let decimal = (0.5).formatted(.number.precision(.fractionLength(1))).dropFirst().first.map(String.init) ?? "."
    #expect(FleetHealth.storageWords(512) == "512 B")
    #expect(FleetHealth.storageWords(830 * 1024) == "830 KB")
    #expect(FleetHealth.storageWords(891_000_000_000) == "829\(decimal)8 GB")
    #expect(FleetHealth.storageWords(890_975_000_000) == "829\(decimal)8 GB")
    #expect(FleetHealth.storageWords(1024 * 1024 * 1024) == "1\(decimal)0 GB")
}

/// **The agents that run an older version are one block with one button** (the owner, 4 November 2026, of eleven blocks
/// with one Update button each: "this should be a table and why woudl we want to update one but not the others? there
/// should be a button to update the fleet, and simplify this!").
@Test func theAgentsThatRunAnOlderVersionAreOneBlockWithOneButton() {
    let blocks = FleetHealth.blocks([
        .init(kind: "machine_behind", detail: "It runs an older version than the hub.", agent: "manager"),
        .init(kind: "backup_old", detail: "The last confirmed backup is 2 days old.", fix: "Save a new copy."),
        .init(kind: "machine_failed", detail: "It still runs the version it had.", agent: "leo"),
        .init(kind: "machine_behind", detail: "It runs an older version than the hub.", agent: "web-lead"),
        .init(kind: "machine_behind", detail: "No agent named.", agent: nil),
    ])
    #expect(blocks.map(\.title) == ["3 agents run an older version", "Your copy is old", "A server is behind"])
    #expect(blocks[0].updates == ["manager", "leo", "web-lead"])
    #expect(blocks[0].acts == [.updateFleet(["manager", "leo", "web-lead"])])
    #expect(blocks[0].acts.first?.label == "Update fleet")
    // Report a problem and the Settings dot read the names, and the one whose update failed says so.
    #expect(blocks[0].detail == "Manager, Leo (its update failed), Web-Lead.")
    #expect(blocks[0].fixes.isEmpty)
    // Every other block has no agents to update; one agent alone is named in the title.
    #expect(blocks[1].updates.isEmpty && blocks[2].updates.isEmpty)
    #expect(FleetHealth.blocks([.init(kind: "machine_behind", detail: "x", agent: "otto")]).first?.title
        == "Otto runs an older version")
}

/// **The hub's disk says how much is used, of what, and where** (the owner, 4 November 2026: "it is also not clear what
/// Free Space means, and how much we're using, and where it is"); a hub before the load readings sends neither field.
// The owner, 13 November 2026: "Same thing for other long actions where we actually know the progress".
@Test func updateFleetSaysWhichAgentsRequestIsOnItsWay() {
    #expect(FleetHealth.Warning.Act.updatingWords(1, of: 11) == "Updating 1 of 11…")
    #expect(FleetHealth.Warning.Act.updatingWords(11, of: 11) == "Updating 11 of 11…")
    // One agent has no count.
    #expect(FleetHealth.Warning.Act.updatingWords(1, of: 1) == "Updating…")
}

@Test func theHubsDiskComesWithItsSizeAndItsServer() throws {
    let health = try JSONDecoder().decode(FleetHealth.self, from: Data(#"""
        {"db":"g","ok":true,"time":100,"helpers":[],"warnings":[],"hub":{"disk_free_bytes":67544813568,
         "disk_total_bytes":80290492416,"machine":"worker-2","integrity":{}}}
        """#.utf8))
    try health.validate(database: "g")
    #expect(health.hub.disk_total_bytes == 80_290_492_416 && health.hub.machine == "worker-2")
    let decimal = (0.5).formatted(.number.precision(.fractionLength(1))).dropFirst().first.map(String.init) ?? "."
    #expect(LoadWords.used(80_290_492_416 - 67_544_813_568, of: 80_290_492_416) == "11\(decimal)9 of 74\(decimal)8 GB used")
    let negative = try JSONDecoder().decode(FleetHealth.self, from: Data(#"""
        {"db":"g","ok":true,"time":100,"helpers":[],"warnings":[],"hub":{"disk_total_bytes":-1,"integrity":{}}}
        """#.utf8))
    #expect(throws: (any Error).self) { try negative.validate(database: "g") }
}
