import Foundation
import Testing
@testable import FleetCore

/// The hub's part of the fleet's shape (owner features `fleet_shape`, `hub_shared_later`, `manager_rename`): the kept
/// step in the list of servers, the two commands with their receipts, the root step of one server later, and which page
/// the manager's first setup shows before its server's page. Synthetic data only.
struct FleetShapeHubTests {
    private static let all = [FleetShapeHub.kept, FleetShapeHub.later, FleetShapeHub.rename]

    /// A list of servers with the hub's own row and one other, as `GET /ui/servers` gives them.
    private static func list(shape: String? = nil, shared: Bool? = nil, joined: Bool = false, available: Bool = false,
                             hubName: String = "hub") throws -> ServerList {
        func row(_ name: String, hub: Bool, joined: Bool, available: Bool) -> String {
            #"{"name":"\#(name)","kind":"linux","address":"100.64.0.1","user":"fleet","hub":\#(hub),"joined":\#(joined),"#
                + #""agents":[],"reading":null,"available":\#(available),"why":[],"job":null,"load":null}"#
        }
        let more = (shape.map { #","shape":\#($0)"# } ?? "") + (shared.map { #","hub_shared":\#($0)"# } ?? "")
        let json = #"{"db":"db","time":1000,"desired_revision":null,"servers":["#
            + row(hubName, hub: true, joined: joined, available: available) + ","
            + row("worker-1", hub: false, joined: true, available: true) + #"],"join":null\#(more)}"#
        return try JSONDecoder().decode(ServerList.self, from: Data(json.utf8))
    }

    /// **The kept step in the list of servers**: one of the slider's three, or nil. A hub before the feature sends no
    /// key; a fleet that kept none sends null; and a value that this app does not know never fails the list's read.
    @Test func theListOfServersReadsTheKeptStep() throws {
        for step in ServersStep.allCases {
            #expect(try Self.list(shape: #"{"step":"\#(step.rawValue)"}"#).keptStep == step)
        }
        #expect(try Self.list().keptStep == nil)
        #expect(try Self.list().shape == nil)
        #expect(try Self.list(shape: "null").keptStep == nil)
        for other in [#"{"step":"three"}"#, #"{"step":2}"#, #"{"step":null}"#, "{}", #""two""#, "2", "[]", "true"] {
            let list = try Self.list(shape: other)
            #expect(list.keptStep == nil, "\(other)")
            #expect(list.servers.count == 2, "\(other)")
        }
        #expect(try Self.list(hubName: "alpha-1").hubRow?.name == "alpha-1")
    }

    /// **The installer's word for the kept step**: `FLEET_SHAPE_STEP` for "2 servers" and "1 per agent", and none for
    /// "1 server", whose own word writes the step (the installer refuses the two together with another value).
    @Test func theInstallersWordForTheKeptStep() {
        #expect(FleetShapeHub.installWord(.one) == nil)
        #expect(FleetShapeHub.installWord(.two) == "FLEET_SHAPE_STEP=two")
        #expect(FleetShapeHub.installWord(.each) == "FLEET_SHAPE_STEP=each")
        #expect([FleetShapeHub.kept, FleetShapeHub.later, FleetShapeHub.rename]
                == ["fleet_shape", "hub_shared_later", "manager_rename"])
    }

    // MARK: the two commands

    @Test func theShapeCommandSendsTheStepAgainstTheTeamItRead() async throws {
        let base = String(repeating: "a", count: 64), id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"test","replayed":false,"step":"one","#
                + #""hub_shared":true,"root_step":true,"revision":"\#(String(repeating: "c", count: 40))","#
                + #""sha256":"\#(String(repeating: "d", count: 64))"}"#
        }
        let receipt = try await HubClient().keepShape(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                      client: "test", requestID: id, sha256: base, step: .one)
        #expect((receipt.step, receipt.hub_shared, receipt.root_step) == ("one", true, true))
        #expect(hub.received.starts(with: Data("POST /ui/servers/shape HTTP/1.1\r\n".utf8)))
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: hub.received)) as? [String: String])
        #expect(body == ["base_sha256": base, "step": "one", "db": "db", "request_id": id.uuidString.lowercased()])
    }

    /// A receipt for another step, or for another request, is not taken; an answer with no `root_step` is one with no
    /// root step to do; and a hash that is none never leaves this Mac.
    @Test func aShapeReceiptForAnotherStepIsNotTaken() async throws {
        let id = UUID(), base = String(repeating: "a", count: 64)
        func answer(step: String, request: String, more: String = "") throws -> OneAnswer {
            try OneAnswer(status: "200 OK") { _ in
                #"{"ok":true,"request_id":"\#(request)","step":"\#(step)","hub_shared":false\#(more),"revision":"r","sha256":"s"}"#
            }
        }
        let other = try answer(step: "each", request: id.uuidString.lowercased())
        await #expect(throws: HubError.self) {
            try await HubClient().keepShape(hub: URL(string: "http://127.0.0.1:\(other.port)")!, database: "db",
                                            client: "test", requestID: id, sha256: base, step: .two)
        }
        let replay = try answer(step: "two", request: UUID().uuidString.lowercased())
        await #expect(throws: HubError.self) {
            try await HubClient().keepShape(hub: URL(string: "http://127.0.0.1:\(replay.port)")!, database: "db",
                                            client: "test", requestID: id, sha256: base, step: .two)
        }
        let plain = try answer(step: "two", request: id.uuidString.lowercased())
        let receipt = try await HubClient().keepShape(hub: URL(string: "http://127.0.0.1:\(plain.port)")!, database: "db",
                                                      client: "test", requestID: id, sha256: base, step: .two)
        #expect(receipt.root_step == nil && !receipt.hub_shared)
        await #expect(throws: HubError.self) {
            try await HubClient().keepShape(hub: URL(string: "http://127.0.0.1:1")!, database: "db", client: "test",
                                            sha256: "abc", step: .two)
        }
    }

    /// The hub's refusal of "1 server" comes back with the hub's own words, which the page shows.
    @Test func aRefusedShapeCommandGivesTheHubsWords() async throws {
        let hub = try OneAnswer(status: "409 Conflict") { _ in
            #"{"ok":false,"error":"The hub runs on a Mac, which takes no agents beside it.","why":["hub_on_mac"]}"#
        }
        do {
            _ = try await HubClient().keepShape(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                client: "test", sha256: String(repeating: "a", count: 64), step: .one)
            Issue.record("the refusal was taken as a receipt")
        } catch let HubError.refusal(refused) {
            #expect(refused.status == 409)
            #expect(refused.hubWords.contains("The hub runs on a Mac"))
        }
    }

    @Test func theManagersRenameSendsTheNewNameAndReadsAnAnswerWithNoServer() async throws {
        let base = String(repeating: "a", count: 64), id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"test","replayed":false,"agent":"juno","#
                + #""was":"manager","server":null,"job":null,"revision":"\#(String(repeating: "c", count: 40))","#
                + #""sha256":"\#(String(repeating: "d", count: 64))"}"#
        }
        let receipt = try await HubClient().nameManager(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                        client: "test", requestID: id, agent: "manager", sha256: base,
                                                        name: "juno")
        #expect((receipt.agent, receipt.was) == ("juno", "manager"))
        #expect(hub.received.starts(with: Data("POST /ui/team/agents/manager/rename HTTP/1.1\r\n".utf8)))
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: hub.received)) as? [String: String])
        #expect(body == ["base_sha256": base, "name": "juno", "db": "db", "request_id": id.uuidString.lowercased()])
    }

    /// A name that the installer refuses for a manager, and the name that it has, never leave this Mac; and a receipt
    /// for another name is not taken.
    @Test func aManagersNameThatTheHubRefusesNeverLeavesThisMac() async throws {
        let base = String(repeating: "a", count: 64)
        for name in ["Juno", "j", "juno ", "1juno", "owner", "hub", "pilot", "server", "vault-1", "login-x",
                     String(repeating: "a", count: 27), "manager"] {
            await #expect(throws: HubError.self, "\(name)") {
                try await HubClient().nameManager(hub: URL(string: "http://127.0.0.1:1")!, database: "db", client: "test",
                                                  agent: "manager", sha256: base, name: name)
            }
        }
        let id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","agent":"other","was":"manager","server":null,"#
                + #""job":null,"revision":"r","sha256":"s"}"#
        }
        await #expect(throws: HubError.self) {
            try await HubClient().nameManager(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                              client: "test", requestID: id, agent: "manager", sha256: base, name: "juno")
        }
    }

    // MARK: the root step

    /// **The root step's text**: the bridge and `kit-clone` first, which stop the run when they fail, then
    /// `one-server` of root's own clone. It has no "$", because a user who is not root runs it through `sudo -n -i`,
    /// and no argument, so nothing that the hub says goes into a command that root runs.
    @Test func theRootStepRunsRootsOwnCloneWithNoArgument() {
        let program = OneServerRemote.program()
        #expect(program.hasPrefix(CentralVaultRemote.bridge() + "; "))
        #expect(program.hasSuffix("; python3 /usr/local/lib/founderizer-kit/hubsetup.py kit-clone || exit 1; "
                                  + "python3 /usr/local/lib/founderizer-kit/hubsetup.py one-server"))
        #expect(!program.contains("$"))
        #expect(!program.contains("--hub-user"))
        #expect(OneServerRemote.program(in: "/tmp/kit").hasSuffix("python3 /tmp/kit/hubsetup.py one-server"))
    }

    /// **The outcome is the last line that is an answer**: progress comes before it, and after a stop the program
    /// writes its own line to standard error after it. A run with no answer is read by its last line.
    @Test func theRootStepsOutcomeIsItsLastAnswer() {
        let done = #"{"ok": true, "server": "hub", "vault": "made", "service": "made"}"#
        #expect(OneServerRemote.outcome("Cloning the kit\nMaking the vault\n\(done)\n") == .done)
        #expect(OneServerRemote.outcome(#"{"ok": true, "server": "hub", "vault": "there", "service": "there"}"#) == .done)
        let stop = #"{"ok": false, "error": "The hub's server has no systemd."}"#
        #expect(OneServerRemote.outcome("step 1\n\(stop)\nFounderizer install stopped: The hub's server has no systemd.")
                == .stopped("The hub's server has no systemd."))
        // The last answer counts, also after an earlier one of a step before it.
        #expect(OneServerRemote.outcome("\(done)\n\(stop)") == .stopped("The hub's server has no systemd."))
        #expect(OneServerRemote.outcome("\(stop)\n\(done)") == .done)
        #expect(OneServerRemote.outcome(#"{"ok": false}"#) == .stopped("It gave no reason."))
        #expect(OneServerRemote.outcome(#"{"ok": false, "error": "  "}"#) == .stopped("It gave no reason."))
        #expect(OneServerRemote.outcome("sudo: a password is required\n") == .stopped("sudo: a password is required"))
        #expect(OneServerRemote.outcome("") == .stopped("It gave no reason."))
        #expect(OneServerRemote.outcome(#"{"state": "made"}"# + "\nlast line") == .stopped("last line"))
        let long = String(repeating: "x", count: 500)
        #expect(OneServerRemote.outcome(#"{"ok": false, "error": "\#(long)"}"#) == .stopped(String(repeating: "x", count: 300)))
    }

    // MARK: the pages before the server's page

    /// **A hub without both parts of the slider shows the pages of before**, whatever else it says: the slider has
    /// the step "1 server", and the name's page ends in the slider's.
    @Test func aHubWithoutThePartsShowsThePagesOfBefore() throws {
        let list = try Self.list()
        for features in [[], ["manager_server"], [FleetShapeHub.kept], [FleetShapeHub.later], [FleetShapeHub.rename],
                         [FleetShapeHub.kept, FleetShapeHub.rename], [FleetShapeHub.later, FleetShapeHub.rename]] {
            #expect(ManagerSetupStart.page(features: features, named: false, list: list) == .server, "\(features)")
            #expect(ManagerSetupStart.page(features: features, named: false, list: nil) == .server, "\(features)")
        }
    }

    /// **No kept step: the name, then the servers.** A hub that cannot rename the manager starts at the servers.
    @Test func withNoKeptStepTheSetupAsksTheNameThenTheServers() throws {
        for shape in [nil, "null", #"{"step":"three"}"#] {
            let list = try Self.list(shape: shape)
            #expect(ManagerSetupStart.page(features: Self.all, named: false, list: list) == .name)
            #expect(ManagerSetupStart.page(features: Self.all, named: true, list: list) == .servers)
            let noRename = [FleetShapeHub.kept, FleetShapeHub.later]
            #expect(ManagerSetupStart.page(features: noRename, named: false, list: list) == .servers)
        }
        // Until a read answers, nothing says which page it is.
        #expect(ManagerSetupStart.page(features: Self.all, named: false, list: nil) == .unread)
        #expect(ManagerSetupStart.page(features: Self.all, named: true, list: nil) == .unread)
    }

    /// **A kept step ends the two pages**, also for a setup that is opened again and whatever `named` says: "2
    /// servers" and "1 per agent" go on to the server's page of before.
    @Test func aKeptStepOfTwoOrEachGoesOnToTheServersPage() throws {
        for step in ["two", "each"] {
            for named in [false, true] {
                let list = try Self.list(shape: #"{"step":"\#(step)"}"#, shared: false)
                #expect(ManagerSetupStart.page(features: Self.all, named: named, list: list) == .server)
            }
        }
    }

    /// **"1 server" is kept**: the root step while the hub's own server has no server service, then the hub's reading
    /// of it, then the hub's row by its own name for the AI provider's press.
    @Test func withOneServerKeptTheHubsServerIsMadeReadyThenTakesTheManager() throws {
        let one = #"{"step":"one"}"#
        func page(shared: Bool?, joined: Bool, available: Bool, hubName: String = "hub") throws -> ManagerSetupStart {
            ManagerSetupStart.page(features: Self.all, named: false,
                                   list: try Self.list(shape: one, shared: shared, joined: joined, available: available,
                                                       hubName: hubName))
        }
        #expect(try page(shared: true, joined: false, available: false) == .sharing(rootStep: true))
        #expect(try page(shared: true, joined: true, available: false) == .sharing(rootStep: false))
        #expect(try page(shared: true, joined: true, available: true) == .onHub("hub"))
        #expect(try page(shared: true, joined: true, available: true, hubName: "alpha-1") == .onHub("alpha-1"))
        // A row that says available with no server service is not one to give the manager.
        #expect(try page(shared: true, joined: false, available: true) == .sharing(rootStep: true))
        // The step without the hub's word that its server takes agents: nothing for this Mac to run, the page waits.
        #expect(try page(shared: false, joined: true, available: true) == .sharing(rootStep: false))
        #expect(try page(shared: nil, joined: false, available: false) == .sharing(rootStep: false))
    }

    /// **A hub without both parts never reads the kept step**: with "1 server" kept it shows the pages of before, so
    /// this Mac's root step, which the page of that step leads to, cannot come from a hub that lacks the part for it.
    @Test func aHubWithoutThePartsShowsThePagesOfBeforeWhateverStepIsKept() throws {
        for step in ["one", "two", "each"] {
            for (shared, joined, available) in [(true, false, false), (true, true, true), (false, false, false)] {
                let list = try Self.list(shape: #"{"step":"\#(step)"}"#, shared: shared, joined: joined, available: available)
                for features in [[], [FleetShapeHub.kept], [FleetShapeHub.later], [FleetShapeHub.kept, FleetShapeHub.rename],
                                 [FleetShapeHub.later, FleetShapeHub.rename]] {
                    #expect(ManagerSetupStart.page(features: features, named: true, list: list) == .server,
                            "\(step) \(features)")
                }
            }
        }
    }

    /// "2 servers" and "1 per agent" go on to the server's page also while the hub's own server still takes agents
    /// (an agent still runs there, so the hub could not take the word away).
    @Test func aKeptStepOfTwoOrEachGoesOnAlsoWhileTheHubsServerTakesAgents() throws {
        for step in ["two", "each"] {
            for (joined, available) in [(false, false), (true, false), (true, true)] {
                let list = try Self.list(shape: #"{"step":"\#(step)"}"#, shared: true, joined: joined, available: available)
                #expect(ManagerSetupStart.page(features: Self.all, named: false, list: list) == .server)
            }
        }
    }

    /// "1 server" is kept and the list has no row of the hub's own server: nothing for this Mac to run and no server
    /// to give the manager, so the page waits for a reading that has the row.
    @Test func withOneServerKeptAndNoRowOfTheHubThePageWaits() throws {
        let json = #"{"db":"db","time":1000,"desired_revision":null,"servers":[],"join":null,"shape":{"step":"one"},"#
            + #""hub_shared":true}"#
        let list = try JSONDecoder().decode(ServerList.self, from: Data(json.utf8))
        #expect(list.hubRow == nil)
        #expect(ManagerSetupStart.page(features: Self.all, named: false, list: list) == .sharing(rootStep: false))
    }

    /// **Only a manager with no server gets these pages**, on a visit that read the hub's features, and not once a
    /// server joined for it on this Mac: each other agent, and each other moment, has the pages of before.
    @Test func onlyAManagerWithNoServerGetsThePages() throws {
        let list = try Self.list()
        func page(role: String? = "manager", placed: Bool? = false, joined: Bool = false, features: [String]? = Self.all,
                  named: Bool = false) -> ManagerSetupStart {
            ManagerSetupStart.page(role: role, placed: placed, joined: joined, features: features, named: named, list: list)
        }
        #expect(page() == .name)
        #expect(page(named: true) == .servers)
        #expect(page(role: "worker") == .server)
        #expect(page(role: "lead") == .server)
        #expect(page(role: nil, placed: nil) == .server)        // the state does not list the agent
        #expect(page(placed: true) == .server)
        #expect(page(placed: nil) == .server)
        #expect(page(joined: true) == .server)
        #expect(page(features: nil) == .server)                 // no read of this visit yet
        #expect(page(features: []) == .server)
        // The same for a kept "1 server": no page of that step, and so no root step, for another agent.
        let one = try Self.list(shape: #"{"step":"one"}"#, shared: true)
        for (role, placed, joined) in [("worker", false, false), ("manager", true, false), ("manager", false, true)] {
            #expect(ManagerSetupStart.page(role: role, placed: placed, joined: joined, features: Self.all, named: true,
                                           list: one) == .server)
        }
        #expect(ManagerSetupStart.page(role: "manager", placed: false, joined: false, features: Self.all, named: true,
                                       list: one) == .sharing(rootStep: true))
    }

    /// The pages in the steps of the manager's setup: the name is the step Manager, the AI provider comes next, and the
    /// slider's page is the step Servers, as the server's page and the install on it after it.
    @Test func thePagesInTheStepsOfTheManagersSetup() {
        #expect(ManagerSetupSteps.names == ["Manager", "AI provider", "Servers", "Sign in"])
        #expect(ManagerSetupSteps.current(.name) == 0)
        #expect(ManagerSetupSteps.current(.provider) == 1)
        #expect(ManagerSetupSteps.current(.servers) == 2)
        #expect(ManagerSetupSteps.current(.server) == 2)
        #expect(ManagerSetupSteps.current(.installing(runtime: "codex")) == 2)
        #expect(ManagerSetupSteps.current(.signIn(runtime: "codex")) == 3)
        #expect(ManagerSetupSteps.current(.activate) == 4)
    }

    /// **The manager's own setup asks for its name and its AI provider before the servers** (the owner, 16 November
    /// 2026: "agent onboarding should ask first for the name and AI provider before the server page"): the provider
    /// that he chose waits on this Mac for the server, and the install that gives the manager both is the page once the
    /// server is there. A command that the hub refused shows the provider's page again.
    @Test func theManagersSetupAsksForTheProviderBeforeTheServers() {
        func page(_ start: ManagerSetupStart, renaming: Bool = false, provider: String? = nil, placeOn: String? = nil,
                  refused: Bool = false) -> AgentSetupPage {
            start.page(renaming: renaming, provider: provider, placeOn: placeOn, refused: refused)
        }
        #expect(page(.name) == .name)
        #expect(page(.name, provider: "claude") == .name)
        #expect(page(.servers, renaming: true) == .name)
        #expect(page(.unread) == .servers)                      // the moving title, until the list answers
        for start in [ManagerSetupStart.servers, .sharing(rootStep: true), .sharing(rootStep: false), .onHub("hub"), .server] {
            #expect(page(start) == .provider, "\(start)")
            #expect(page(start, placeOn: "hub") == .provider, "\(start)")
        }
        #expect(page(.servers, provider: "claude") == .servers)
        #expect(page(.sharing(rootStep: true), provider: "claude") == .servers)
        #expect(page(.server, provider: "claude") == .server)
        #expect(page(.server, provider: "claude", placeOn: "vps-2") == .installing(runtime: "claude"))
        #expect(page(.onHub("hub"), provider: "codex", placeOn: "hub") == .installing(runtime: "codex"))
        #expect(page(.onHub("hub"), provider: "codex", placeOn: "hub", refused: true) == .provider)
        #expect(page(.server, provider: "codex", placeOn: "vps-2", refused: true) == .provider)
    }
}
