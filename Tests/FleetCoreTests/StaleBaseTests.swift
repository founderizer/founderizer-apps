import Foundation
import Testing
@testable import FleetCore

// A 409 from a base that simply moved, and the one retry it deserves.
//
// Every write that carries `base_revision` or `base_sha256` can meet this: the owner's page read a version, an agent
// committed something, and the hub refuses the owner's press. It used to be treated as final and dropped. These are
// the tests that say which commands go again against the fresh base, and which stay the owner's to see.

@Test func everyWriteThatCarriesABaseSaysWhichKindItIs() throws {
    let digest = String(repeating: "a", count: 64)
    #expect(OwnerCommand.goalState(id: 3, revision: 7, action: .pause).base == .revision(7))
    #expect(OwnerCommand.triggerState(id: 3, revision: 7, action: .pause).base == .revision(7))
    #expect(OwnerCommand.teamLines(sha256: digest).base == .file(sha256: digest))
    #expect(OwnerCommand.profile(agent: "vps", sha256: digest).base == .file(sha256: digest))
    #expect(OwnerCommand.agentRuntime(agent: "vps", sha256: digest, runtime: "codex").base == .file(sha256: digest))
    // A command with no base cannot be rebased, and nothing claims otherwise.
    #expect(OwnerCommand.machineCheck(agent: "vps").base == nil)
    #expect(OwnerCommand.control(task: 4, action: .pause).base == nil)
    #expect(!OwnerCommand.machineCheck(agent: "vps").rebasesSafely)
}

@Test func aStateActionAndAOneFieldWriteGoAgainstTheFreshBase() throws {
    let fresh = String(repeating: "b", count: 64), old = String(repeating: "a", count: 64)
    #expect(OwnerCommand.goalState(id: 3, revision: 7, action: .resume).rebased(to: .revision(9))
            == .goalState(id: 3, revision: 9, action: .resume))
    #expect(OwnerCommand.triggerState(id: 3, revision: 7, action: .run_now).rebased(to: .revision(9))
            == .triggerState(id: 3, revision: 9, action: .run_now))
    #expect(OwnerCommand.agentActivation(agent: "vps", sha256: old, active: true).rebased(to: .file(sha256: fresh))
            == .agentActivation(agent: "vps", sha256: fresh, active: true))
    #expect(OwnerCommand.agentVault(agent: "vps", sha256: old, access: .broker).rebased(to: .file(sha256: fresh))
            == .agentVault(agent: "vps", sha256: fresh, access: .broker))
    #expect(OwnerCommand.agentVaultCreate(agent: "vps", sha256: old, on: true).rebased(to: .file(sha256: fresh))
            == .agentVaultCreate(agent: "vps", sha256: fresh, on: true))
    #expect(OwnerCommand.agentRuntime(agent: "vps", sha256: old, runtime: "codex").rebased(to: .file(sha256: fresh))
            == .agentRuntime(agent: "vps", sha256: fresh, runtime: "codex"))
    // A removal names the one thing it removes, so a newer file does not change what it means.
    #expect(OwnerCommand.teamAccount(id: "studio", sha256: old, delete: true).rebased(to: .file(sha256: fresh))
            == .teamAccount(id: "studio", sha256: fresh, delete: true))
    #expect(OwnerCommand.ownerDevice(device: "iphone", sha256: old, delete: true).rebased(to: .file(sha256: fresh))
            == .ownerDevice(device: "iphone", sha256: fresh, delete: true))
}

@Test func aWholeFormSaveStaysTheOwnersToSeeAgain() throws {
    let fresh = String(repeating: "b", count: 64), old = String(repeating: "a", count: 64)
    // Each of these is fields the owner wrote against the version he read: sending them against a newer one would
    // drop whatever changed meanwhile without telling him.
    let forms: [OwnerCommand] = [.profile(agent: "vps", sha256: old), .teamLines(sha256: old),
                                 .agentSettings(agent: "vps", sha256: old), .agentIdentity(agent: "vps", sha256: old),
                                 .teamAccount(id: "studio", sha256: old, delete: false),
                                 .ownerDevice(device: "iphone", sha256: old, delete: false)]
    for form in forms {
        #expect(!form.rebasesSafely)
        #expect(form.rebased(to: .file(sha256: fresh)) == nil)
    }
    // A base of the other kind is not a base for this command either.
    #expect(OwnerCommand.goalState(id: 3, revision: 7, action: .pause).rebased(to: .file(sha256: fresh)) == nil)
    #expect(OwnerCommand.agentActivation(agent: "vps", sha256: old, active: false).rebased(to: .revision(9)) == nil)
}

@Test func theBaseIsReadFromTheHubAndNotFromTheRefusalsProse() async throws {
    let digest = String(repeating: "c", count: 64)
    let team = try OneAnswer(status: "200 OK") { _ in
        #"{"db":"db","revision":"\#(String(repeating: "e", count: 40))","sha256":"\#(digest)","#
            + #""lines":[{"agent":"manager","role":"manager","reports_to":null},"#
            + #"{"agent":"vps","role":"worker","reports_to":"manager"}],"open_tasks":{}}"#
    }
    let base = try await HubClient().currentBase(
        for: .agentActivation(agent: "vps", sha256: String(repeating: "a", count: 64), active: true),
        hub: URL(string: "http://127.0.0.1:\(team.port)")!, database: "db")
    #expect(base == .file(sha256: digest))
    #expect(team.received.starts(with: Data("GET /ui/team?db=db HTTP/1.1\r\n".utf8)))

    let goal = try OneAnswer(status: "200 OK") { _ in
        #"{"db":"db","goal":{"id":4,"revision":9,"title":"Ship","text":"Ship it","state":"active","#
            + #""created":1000.0,"updated":1000.0,"spent":0,"request_id":"r","#
            + #""limits":{"money":null,"tokens":null,"deadline":null,"not_to_do":[]}},"spends":[],"history":[]}"#
    }
    let revision = try await HubClient().currentBase(for: .goalState(id: 4, revision: 7, action: .pause),
                                                     hub: URL(string: "http://127.0.0.1:\(goal.port)")!, database: "db")
    #expect(revision == .revision(9))
    #expect(goal.received.starts(with: Data("GET /ui/goals/4?db=db HTTP/1.1\r\n".utf8)))
}
