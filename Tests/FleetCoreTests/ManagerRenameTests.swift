import Foundation
import Testing
@testable import FleetCore

/// A press of Continue on "Name your manager" (`ManagerRename`), against a hub whose answers can be lost.
@MainActor struct ManagerRenameTests {
    /// A hub that holds the manager's name: it renames, refuses a name that is gone, and can lose an answer.
    @MainActor private final class Hub {
        var manager = "juno"
        /// The commands that reached it, by the name that they ask for.
        var commands: [String] = []
        /// What the next command gets in place of the hub's own answer, after the hub did its work (`made`) or before.
        var next: (made: Bool, error: any Error)?
        /// Every time that the team is read: a change of the team that comes between two reads.
        var atRead: () -> Void = {}

        func press(was: String = "juno", wanted: String) async -> ManagerRename.Outcome {
            await ManagerRename.press(was: was, wanted: wanted, team: {
                atRead()
                return ManagerRename.Team(names: ["mail", manager], manager: manager, sha256: "the sha of \(manager)")
            }, rename: { sha256 in
                commands.append(wanted)
                let cut = next; next = nil
                if let cut, !cut.made { throw cut.error }
                guard sha256 == "the sha of \(manager)" else { throw Self.refusal(409, "team_changed") }
                guard manager == was else { throw Self.refusal(404, "no_such_agent") }
                manager = wanted
                if let cut { throw cut.error }
            })
        }

        static func refusal(_ status: Int, _ code: String) -> HubError {
            .refusal(HubRefusal(status: status, hubWords: "example", code: code))
        }
    }

    /// The hub renamed the manager and its answer was lost, and the window still has the old name: the next press finds
    /// the new name and sends nothing, also when he types the old name again or a third one. A bug here sends a rename
    /// of a name that is gone: its refusal takes the note away, and the window never goes to the manager's new page.
    @Test func aRenameWhoseAnswerWasLostIsFoundAtTheNextPress() async {
        for wanted in ["nova", "juno", "atlas"] {
            let hub = Hub()
            hub.next = (made: true, error: HubError.unavailable)
            #expect(await hub.press(wanted: "nova") == .unanswered)
            #expect(hub.manager == "nova")
            #expect(await hub.press(wanted: wanted) == .renamed(now: "nova"))
            #expect(hub.commands == ["nova"], "\(wanted)")
        }
    }

    /// The command that was lost on its way there renamed nothing: the next press goes on with the name, or sends the
    /// rename again. A bug here leaves him on the page of a name that the hub never took.
    @Test func aCommandThatNeverReachedTheHubIsSentAgain() async {
        let hub = Hub()
        hub.next = (made: false, error: HubError.unavailable)
        #expect(await hub.press(wanted: "nova") == .unanswered)
        #expect(await hub.press(wanted: "juno") == .keep)
        #expect(hub.commands == ["nova"])
        #expect(await hub.press(wanted: "nova") == .named)
        #expect(hub.manager == "nova" && hub.commands == ["nova", "nova"])
    }

    /// The rename of an earlier press lands between the read of the team and the command of this one: the hub says that
    /// the team changed, or that the name is gone, and the second read finds the new name with no second command. A bug
    /// here shows him the hub's error for a rename that was made.
    @Test func aRenameThatLandsMeanwhileIsFoundAtTheSecondRead() async {
        for (status, code) in [(409, "team_changed"), (404, "no_such_agent")] {
            let hub = Hub()
            hub.next = (made: false, error: Hub.refusal(status, code))
            var reads = 0
            hub.atRead = { reads += 1; if reads == 2 { hub.manager = "nova" } }
            #expect(await hub.press(wanted: "atlas") == .renamed(now: "nova"))
            #expect(hub.commands == ["atlas"] && reads == 2)
        }
    }

    /// The team is read again once, and then the hub's refusal stands: a team that changes at each read ends the press,
    /// and a refusal of the name itself is asked once.
    @Test func aRefusalStandsAtTheSecondRead() async {
        for (status, code, commands) in [(409, "team_changed", 2), (404, "no_such_agent", 2), (409, "name_taken", 1)] {
            let hub = Hub()
            hub.atRead = { hub.next = (made: false, error: Hub.refusal(status, code)) }
            let refused = HubRefusal(status: status, hubWords: "example", code: code)
            #expect(await hub.press(wanted: "nova") == .refused(refused))
            #expect(hub.commands.count == commands, "\(code)")
        }
    }

    /// The press reads the manager by its role in the hub's team, and every agent's name. A bug here takes the first
    /// agent for the manager, and the page goes to a worker.
    @Test func theTeamsManagerIsTheAgentWithTheManagersRole() throws {
        let team: [String: Any] = ["db": "db", "revision": String(repeating: "b", count: 40), "sha256": String(repeating: "c", count: 64),
                                   "open_tasks": [:], "lines": [["agent": "mail", "role": "worker", "reports_to": "nova"],
                                                                ["agent": "nova", "role": "manager", "reports_to": NSNull()]]]
        let read = ManagerRename.Team(try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: team)))
        #expect(read.names == ["mail", "nova"] && read.manager == "nova" && read.sha256 == String(repeating: "c", count: 64))
    }

    /// A window that went to another hub while the team was read sends that hub's command nowhere.
    @Test func aWindowThatWentToAnotherHubSendsNothing() async {
        var sent = 0
        let outcome = await ManagerRename.press(was: "juno", wanted: "nova", team: { throw CancellationError() },
                                                rename: { _ in sent += 1 })
        #expect(outcome == .moved && sent == 0)
    }

    /// The page goes to the manager's name in the first reading without the noted name. A bug here leaves the window on
    /// an agent that is gone, or takes it to an agent that is not the manager, or to another hub's manager.
    @Test func thePageFollowsTheManagerAndNoOtherAgent() throws {
        func reading(_ agents: [(String, String)], db: String = "named") throws -> HubState {
            try HubState.decode(JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": db, "time": 1000.0, "ui_features": [String](),
                "agents": agents.map { ["name": $0.0, "role": $0.1, "runtime": "claude", "can": [String]()] as [String: Any] },
                "tasks": [], "notes": [], "permissions": [], "needs": [], "messages": [], "reports": []]))
        }
        let hub = try #require(URL(string: "https://hub.example")), other = try #require(URL(string: "https://other.example"))
        let note = ManagerRenameNote(hub: hub, database: "named", was: "juno")
        let renamed = try reading([("mail", "worker"), ("nova", "manager")])
        #expect(note.follow(hub: hub, reading: renamed) == "nova")
        // The manager got another name than the one that this window asked for, and a worker has that one.
        #expect(note.follow(hub: hub, reading: try reading([("nova", "worker"), ("atlas", "manager")])) == "atlas")
        // The hub still has the old name, has no manager, or is another hub or another generation.
        #expect(note.follow(hub: hub, reading: try reading([("juno", "manager")])) == nil)
        #expect(note.follow(hub: hub, reading: try reading([("mail", "worker")])) == nil)
        #expect(note.follow(hub: other, reading: renamed) == nil)
        #expect(note.follow(hub: hub, reading: try reading([("nova", "manager")], db: "another")) == nil)
    }
}
