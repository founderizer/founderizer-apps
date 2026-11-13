import Foundation
import Testing
@testable import FleetCore

struct ServersTests {
    /// A `GET /ui/servers` answer of the real hub code (ui_fixture.py): the hub with its manager, a Linux server whose
    /// new agent waits for the Claude Code sign-in, and a free Mac; an open join code.
    private func sample() throws -> ServerList {
        let url = try #require(Bundle.module.url(forResource: "servers", withExtension: "json", subdirectory: "Fixtures"))
        let list = try JSONDecoder().decode(ServerList.self, from: Data(contentsOf: url))
        try list.validate(database: "db")
        return list
    }

    @Test func decodesTheHubsServers() throws {
        let list = try sample()
        #expect(list.servers.map(\.name) == ["hub", "box", "mini-2"])
        #expect(list.available.map(\.name) == ["mini-2"])
        #expect(list.server(of: "scout")?.name == "box")
        #expect(list.server(of: "manager")?.hub == true)
        let mac = try #require(list.servers.last)
        #expect(mac.isMac && mac.symbol == "desktopcomputer" && mac.joined && mac.agents.isEmpty)
        #expect(mac.reading?.runtimes["claude"]?.signed_in == true)
        #expect(mac.reading?.current == true)
        #expect(list.join?.state == "open")
        #expect(throws: HubError.self) { try list.validate(database: "another") }
    }

    /// **A server's CPU, memory and disk** (the owner's yes of 4 November 2026): shares of what it read, the CPU at most
    /// 100, and a figure that cannot be read is nil and never loses the list.
    @Test func aServersLoadReadsAsSharesAndNeverLosesTheList() throws {
        let list = try JSONDecoder().decode(ServerList.self, from: Data(#"""
            {"db":"db","time":1000,"desired_revision":null,"join":null,"servers":[
             {"name":"worker-2","kind":"linux","address":"100.96.10.20","user":null,"hub":true,"joined":false,"agents":[],
              "reading":null,"available":false,"why":["hub_machine"],"job":null,
              "load":{"cpu_percent":5.0,"memory_used":1000000000,"memory_total":4000000000,"disk_used":12745678848,
                      "disk_total":80290492416,"at":1000}},
             {"name":"mini","kind":"mac","address":"100.96.100.4","user":"sam","hub":false,"joined":true,"agents":["ivy"],
              "reading":null,"available":true,"why":[],"job":null,
              "load":{"cpu_percent":250,"memory_used":"lots","memory_total":null,"disk_used":95,"disk_total":100,"at":300}},
             {"name":"box","kind":"linux","address":"100.96.100.130","user":null,"hub":false,"joined":true,"agents":[],
              "reading":null,"available":true,"why":[],"job":null,"load":"broken"},
             {"name":"old","kind":"linux","address":"100.96.100.131","user":null,"hub":false,"joined":true,"agents":[],
              "reading":null,"available":true,"why":[],"job":null}]}
            """#.utf8))
        try list.validate(database: "db")
        let hub = try #require(list.servers[0].load)
        #expect(hub.cpu == 5 && hub.memory == 25 && hub.isCurrent(at: 1000))
        #expect(hub.disk.map(LoadWords.percent) == "16%")
        let mini = try #require(list.servers[1].load)
        #expect(mini.cpu == 100 && mini.memory == nil && mini.disk == 95 && mini.disk ?? 0 >= ServerLoad.high)
        #expect(!mini.isCurrent(at: 1000))         // read 700 seconds before: gray
        #expect(list.servers[2].load == ServerLoad(cpu_percent: nil, memory_used: nil, memory_total: nil, disk_used: nil,
                                                   disk_total: nil, at: nil))
        #expect(list.servers[3].load == nil)        // a hub before the load readings
        let decimal = (0.5).formatted(.number.precision(.fractionLength(1))).dropFirst().first.map(String.init) ?? "."
        #expect(LoadWords.used(12_745_678_848, of: 80_290_492_416) == "11\(decimal)9 of 74\(decimal)8 GB used")
        #expect(LoadWords.used(900 * 1024 * 1024, of: 4 * 1024 * 1024 * 1024) == "0\(decimal)9 of 4\(decimal)0 GB used")
        #expect(LoadWords.percent(99.5) == "100%" && LoadWords.percent(0.4) == "0%")
        // Orange as soon as its words say 90%: 89,9 is "90%".
        #expect(ServerLoad.isHigh(89.9) && !ServerLoad.isHigh(89.4))
    }

    @Test func statesSayWhatGoesOnFirst() throws {
        let list = try sample()
        let box = list.servers[1], mac = list.servers[2], hub = list.servers[0]
        #expect(Servers.state(box, helpers: [], time: 1030, fresh: true) == ("Sign-in needed", true))
        // One of a unit in the singular (fix round 3, item 33: "1 seconds ago").
        #expect(Servers.age(999, now: 1000) == "1 second ago" && Servers.age(990, now: 1000) == "10 seconds ago")
        #expect(Servers.age(1000 - 100, now: 1000) == "1 minute ago" && Servers.age(0, now: 7200) == "2 hours ago")
        #expect(Servers.state(mac, helpers: [], time: 1030, fresh: true) == ("Connected", false))
        #expect(Servers.state(hub, helpers: [], time: 1030, fresh: true) == ("Connected", false))
        // While the hub does not answer, the last reading says nothing it does not know (fix round 1).
        #expect(Servers.state(mac, helpers: [], time: 1030, fresh: false) == ("Last reading", false))
        #expect(Servers.state(box, helpers: [], time: 1030, fresh: false) == ("Last reading", false))
        #expect(Servers.state(mac, helpers: [], time: 1000 + 700, fresh: true) == ("Not answering", true))
        #expect(Servers.reason("has_agent") == "It takes another agent once Founderizer there is updated.")
        #expect(Servers.reason("something new") == "It cannot take an agent now.")
    }

    /// **The row says what the server's page says** (`MachineConnection.of`). A server whose helpers had gone silent stayed
    /// "Connected" here for as long as its server service reported, while its page and Report a problem said "Not answering".
    @Test func aRowGoesByThePagesOwnRule() throws {
        let list = try sample()
        let hub = list.servers[0], box = list.servers[1], mac = list.servers[2]
        let silent = [FleetHealth.Helper(agent: "manager", last_seen: 900, offline: true)]
        let reporting = [FleetHealth.Helper(agent: "manager", last_seen: 1020, offline: false)]
        #expect(Servers.state(hub, helpers: silent, time: 1030, fresh: true) == ("Not answering", true))
        #expect(Servers.state(hub, helpers: reporting, time: 1030, fresh: true) == ("Connected", false))
        // Its reading is old and its helpers report: the page says Connected, so the row does.
        #expect(Servers.state(hub, helpers: reporting, time: 1000 + 700, fresh: true) == ("Connected", false))
        // Until the health is read, and on a server with no agent, the reading says it.
        #expect(Servers.state(hub, helpers: [], time: 1000 + 700, fresh: true) == ("Not answering", true))
        #expect(Servers.state(mac, helpers: silent, time: 1030, fresh: true) == ("Connected", false))
        // A job comes first, and a hub that does not answer says nothing it does not know.
        let scout = [FleetHealth.Helper(agent: "scout", last_seen: nil, offline: true)]
        #expect(Servers.state(box, helpers: scout, time: 1030, fresh: true) == ("Sign-in needed", true))
        #expect(Servers.state(hub, helpers: silent, time: 1030, fresh: false) == ("Last reading", false))
    }

    /// One server with these agents and a reading of that time, or none.
    private func server(_ agents: [String], read: Double?, current: Bool = true, available: Bool = false) throws -> ServerEntry {
        let reading: Any = read.map { ["source": "server", "os": ["name": "Ubuntu 24.04"], "runtimes": [:], "reported_at": $0,
                                       "stale": false, "current": current] as [String: Any] } ?? NSNull()
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: [
            "name": "box", "kind": "linux", "hub": false, "joined": true, "agents": agents, "reading": reading,
            "available": available, "why": []] as [String: Any]))
    }

    /// **A server with agents can take one more** (the owner, 3 November 2026: "this is confusing, since we allow
    /// multiple agents per server"): room for an agent is no news on any row, so no row says "Free".
    @Test func noServerIsCalledFree() throws {
        let shared = try server(["leo", "iris"], read: 1000, available: true)
        #expect(Servers.state(shared, helpers: [], time: 1030, fresh: true) == ("Connected", false))
        let empty = try server([], read: 1000, available: true)
        #expect(Servers.state(empty, helpers: [], time: 1030, fresh: true) == ("Connected", false))
        #expect(Servers.agentProblem(name: "kai", server: shared, existing: ["leo", "iris"]) == nil)
        #expect(Servers.reason("fix_holder") == "An agent there has full control of it.")
    }

    @Test func aRowAndItsPageSayOneWordInEveryCase() throws {
        let on = { (agent: String) in FleetHealth.Helper(agent: agent, last_seen: 1020, offline: false) }
        let off = { (agent: String) in FleetHealth.Helper(agent: agent, last_seen: 900, offline: true) }
        for read in [nil, 1000, 1000 - 700] as [Double?] {
            for agents in [[], ["a"], ["a", "b"]] {
                for helpers in [[], [on("a")], [off("a")], [on("b")], [on("a"), off("b")], [on("a"), on("b")]] {
                    let entry = try server(agents, read: read)
                    #expect(Servers.state(entry, helpers: helpers, time: 1030, fresh: true).words
                        == MachineConnection.of(entry, helpers: helpers, time: 1030, fresh: true).words)
                }
            }
        }
        // Only a current reading says what its revision is.
        #expect(Servers.state(try server(["a"], read: 1000, current: false), helpers: [on("a")], time: 1030, fresh: true)
            == ("Update available", false))
        #expect(Servers.state(try server(["a"], read: 1000 - 700, current: false), helpers: [on("a")], time: 1030, fresh: true)
            == ("Connected", false))
    }

    @Test func anOldHealthReadingSpeaksForNoHelper() throws {
        let health = try JSONDecoder().decode(FleetHealth.self, from: JSONSerialization.data(withJSONObject: [
            "db": "db", "ok": true, "time": 1000.0, "hub": ["integrity": [:]], "warnings": [],
            "helpers": [["agent": "a", "last_seen": 900.0, "offline": true]]] as [String: Any]))
        #expect(health.currentHelpers(at: 1044).map(\.agent) == ["a"])
        #expect(health.currentHelpers(at: 1045).isEmpty)
    }

    @Test func aSignInPromptIsUsedOnlyWhenItIsSafe() throws {
        let box = try sample().servers[1]
        let prompt = try #require(box.job?.prompt)
        #expect(prompt.terminalCommand == "su - fleet -c 'cd /home/fleet/fleet-scout && exec /home/fleet/.local/bin/claude'")
        #expect(prompt.signInURL == nil)
        func open(_ url: String, _ code: String) throws -> ServerJob.Prompt {
            try JSONDecoder().decode(ServerJob.Prompt.self, from: Data(
                #"{"kind":"open_url","purpose":"codex_login","url":"\#(url)","code":"\#(code)"}"#.utf8))
        }
        #expect(try open("https://auth.openai.com/codex/device", "ABCD-12345").signInURL != nil)
        #expect(try open("https://auth.openai.com/codex/device", "ABCD-12345").deviceCode == "ABCD-12345")
        #expect(try open("http://auth.openai.com/codex/device", "ABCD-12345").signInURL == nil)
        #expect(try open("https://auth.openai.com.evil.example/x", "ABCD-12345").signInURL == nil)
        #expect(try open("https://auth.openai.com/codex/device", "abc").deviceCode == nil)
        let bad = try JSONDecoder().decode(ServerJob.Prompt.self, from: Data(
            #"{"kind":"terminal","purpose":"claude_login","command":"claude\nrm -rf ~"}"#.utf8))
        #expect(bad.terminalCommand == nil)
        // Claude Code's sign-in is the machine's own now: the prompt names the sign-in the hub started, and carries no
        // link, no code and no command, so the card offers the agent's sign-in screen and never a console line.
        let machine = try JSONDecoder().decode(ServerJob.Prompt.self, from: Data(
            #"{"kind":"signin","purpose":"claude_login","agent":"ivy","login":7}"#.utf8))
        #expect(machine.kind == "signin")
        #expect(machine.signInURL == nil && machine.deviceCode == nil && machine.terminalCommand == nil)
    }

    @Test func namesAndChoices() throws {
        #expect(Servers.suggestedName(taken: ["hub", "vps", "mac-studio", "worker4"]) == "server-2")
        #expect(Servers.suggestedName(taken: ["server-2", "server-3"]) == "server-4")
        #expect(Servers.nameProblem("server-2", taken: []) == nil)
        #expect(Servers.nameProblem("vps", taken: ["vps"]) == "A server has this name.")
        #expect(Servers.nameProblem("Big Box", taken: []) != nil)
        let list = try sample()
        #expect(Servers.agentProblem(name: "coder", server: list.servers[2], existing: ["manager"]) == nil)
        #expect(Servers.agentProblem(name: "coder", server: nil, existing: []) == "Select a server.")
        // A server he picked that can no longer take one says why, as its row does.
        #expect(Servers.agentProblem(name: "coder", server: list.servers[1], existing: []) == Servers.reason("has_agent"))
        #expect(Servers.agentProblem(name: "manager", server: list.servers[2], existing: ["manager"]) == "An agent with this name exists.")
        #expect(Servers.agentProblem(name: "owner", server: list.servers[2], existing: []) != nil)
        #expect(Servers.providerWords(nil) == "Not installed")
        #expect(Servers.providerWords(list.servers[1].reading?.runtimes["claude"]) == "2.1.287 · Not signed in")
    }

    @Test func jobWordsGiveTheStepWhenTheServerGaveNoDetail() throws {
        func install(_ step: String, state: String = "running") throws -> ServerJob {
            try JSONDecoder().decode(ServerJob.self, from: Data("""
            {"id":3,"kind":"install","agent":"scout","runtime":"codex","state":"\(state)","step":"\(step)",
             "detail":null,"prompt":null,"created":1,"updated":2}
            """.utf8))
        }
        #expect(Servers.jobWords(try install("checkout")) == "The checkout of Scout.")
        // The first step of an install on a Linux server, which the hub added after this screen was written: with
        // no words of its own it read as "The install of Scout." while the server was making that user.
        #expect(Servers.jobWords(try install("user")) == "The OS user of Scout on the server.")
        #expect(Servers.jobWords(try install("user", state: "failed")) == "The OS user of Scout on the server.")
        #expect(try install("user").isOpen)
    }

    // MARK: The preparation of a provider before a switch (`POST /ui/servers/<server>/prepare`)

    private func preparation(_ state: String, step: String? = nil, detail: String? = nil) throws -> ServerJob {
        let quoted = { (text: String?) in text.map { "\"\($0)\"" } ?? "null" }
        return try JSONDecoder().decode(ServerJob.self, from: Data("""
            {"id":2,"kind":"prepare","agent":"scout","runtime":"codex","state":"\(state)","step":\(quoted(step)),
             "detail":\(quoted(detail)),"prompt":null,"created":1000,"updated":1010}
            """.utf8))
    }

    /// The fixture's joined Linux server box with its agent scout, whose newest job is now this one.
    private func box(_ job: ServerJob) throws -> ServerEntry {
        let entry = String(decoding: try JSONEncoder().encode(Job(job)), as: UTF8.self)
        return try JSONDecoder().decode(ServerEntry.self, from: Data("""
            {"name":"box","kind":"linux","address":"100.70.1.21","user":"fleet","hub":false,"joined":true,"agents":["scout"],
             "reading":{"source":"server","revision":null,"current":null,"os":{"name":"Debian GNU/Linux 12 (bookworm)",
             "kernel":"6.8.0"},"security":null,"runtimes":{},"user":"fleet","reported_at":1000,"stale":false},
             "available":false,"why":["has_agent","busy"],"job":\(entry)}
            """.utf8))
    }

    private struct Job: Encodable {
        let id: Int, kind: String, agent: String?, runtime: String?, state: String, step: String?, detail: String?
        let created: Double, updated: Double
        init(_ job: ServerJob) {
            id = job.id; kind = job.kind; agent = job.agent; runtime = job.runtime; state = job.state; step = job.step
            detail = job.detail; created = job.created; updated = job.updated
        }
    }

    private func readiness(_ json: String) throws -> RuntimeSwitch {
        try JSONDecoder().decode(RuntimeSwitch.self, from: Data(json.utf8))
    }

    @Test func aPreparationIsTheServersNewestJobForThatAgent() throws {
        let running = try box(preparation("running", step: "runtime"))
        let job = try #require(running.preparation(of: "scout"))
        #expect(job.isOpen && job.runtime == "codex")
        #expect(running.preparation(of: "other") == nil)
        #expect(try sample().servers[1].preparation(of: "scout") == nil)            // the install of scout
        #expect(Servers.steps(job).map(\.id) == ["runtime", "sign_in"])
        // An install on a Linux server starts at the agent's own OS user, which that server makes before anything
        // else; a Mac keeps one user for its agents, so a Mac install has no such step to show as done.
        let install = try #require(try sample().servers[1].job)
        #expect(Servers.steps(install).map(\.id) == ["user", "runtime", "checkout", "service", "sign_in"])
        #expect(Servers.steps(install, onMac: true).map(\.id) == ["runtime", "checkout", "service", "sign_in"])
        #expect(Servers.steps(job, onMac: true).map(\.id) == ["runtime", "sign_in"])
        #expect(Servers.state(running, helpers: [], time: 1030, fresh: true) == ("Preparing Codex for Scout…", false))
        #expect(Servers.state(try box(preparation("needs_owner", step: "sign_in")), helpers: [], time: 1030, fresh: true) ==
                ("Sign-in needed", true))
        // A failed preparation changes nothing for the agent: the row gives the server's reading.
        #expect(Servers.state(try box(preparation("failed", step: "sign_in")), helpers: [], time: 1030, fresh: true) == ("Connected", false))
    }

    @Test func preparationWordsFollowItsState() throws {
        #expect(Servers.jobWords(try preparation("queued")) == "The server starts to prepare Codex in a few seconds.")
        #expect(Servers.jobWords(try preparation("running", step: "runtime")) == "Codex on the server.")
        #expect(Servers.jobWords(try preparation("running", step: "runtime", detail: "Installing Codex 0.160.0.")) ==
                "Installing Codex 0.160.0.")
        #expect(Servers.jobWords(try preparation("needs_owner", step: "sign_in")) == "The sign-in of Codex.")
        #expect(Servers.jobWords(try preparation("done", step: "sign_in")) == "Codex is ready for Scout.")
        #expect(Servers.jobWords(try preparation("failed")) == "The preparation of Codex.")
        #expect(Servers.jobWords(try preparation("canceled")) == "The preparation of Codex ended: the server left Founderizer.")
    }

    /// Change provider shows the preparation of the switch's target while it goes on, after a failure, and after its
    /// end until the helper's new reading; never one of another provider or an install.
    @Test func changeProviderShowsOnlyThePreparationOfItsTarget() throws {
        let needs = try readiness(#"{"to":"codex","ready":false,"missing":["runtime_not_installed"],"busy":null}"#)
        let ready = try readiness(#"{"to":"codex","ready":true,"missing":[],"busy":null}"#)
        let back = try readiness(#"{"to":"claude","ready":false,"missing":["runtime_not_signed_in"],"busy":null}"#)
        for state in ["queued", "running", "needs_owner", "failed", "done"] {
            #expect(needs.shows(try preparation(state))?.state == state)
            #expect(back.shows(try preparation(state)) == nil)
        }
        #expect(ready.shows(try preparation("done")) == nil)
        #expect(ready.shows(try preparation("running")) != nil)
        #expect(needs.shows(try sample().servers[1].job) == nil)
        #expect(needs.shows(nil) == nil)
    }

    // MARK: A server's name is its name in Tailscale (`server_names`)

    /// Add server asks for a name only on a hub from before `server_names`; the form shows no Name row on one with it.
    @Test func onlyAnOlderHubIsAskedForTheServersName() {
        #expect(Servers.asksName(nil))
        #expect(Servers.asksName(["servers", "server_prepare"]))
        #expect(!Servers.asksName(["servers", "server_names"]))
    }

    private func joinAnswer(_ id: UUID, name: String) -> String {
        #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"test","replayed":false,"name":"\#(name)","#
            + #""kind":"linux","expires_at":2800.25,"code":"7KMQ-2PRJ-4TVW","line":"curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=7KMQ-2PRJ-4TVW sh"}"#
    }

    @Test func aHubThatNamesServersIsSentNoName() async throws {
        let id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in self.joinAnswer(id, name: "") }
        let code = try await HubClient().joinCode(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                  client: "test", requestID: id, name: nil, kind: "linux")
        #expect(code.name == "" && code.line != nil && code.expires_at == 2800.25)
        #expect(hub.received.starts(with: Data("POST /ui/servers/join HTTP/1.1\r\n".utf8)))
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: hub.received)) as? [String: String])
        #expect(body == ["kind": "linux", "db": "db", "request_id": id.uuidString.lowercased()])
    }

    @Test func anOlderHubIsSentTheTypedName() async throws {
        let id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in self.joinAnswer(id, name: "server-2") }
        let code = try await HubClient().joinCode(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                  client: "test", requestID: id, name: "server-2", kind: "linux")
        #expect(code.name == "server-2")
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: hub.received)) as? [String: String])
        #expect(body == ["name": "server-2", "kind": "linux", "db": "db", "request_id": id.uuidString.lowercased()])
        // An answer for another label is not taken, and a name the hub would refuse never leaves this Mac.
        let other = try OneAnswer(status: "200 OK") { _ in self.joinAnswer(id, name: "server-3") }
        await #expect(throws: HubError.self) {
            try await HubClient().joinCode(hub: URL(string: "http://127.0.0.1:\(other.port)")!, database: "db",
                                           client: "test", requestID: id, name: "server-2", kind: "linux")
        }
        await #expect(throws: HubError.self) {
            try await HubClient().joinCode(hub: URL(string: "http://127.0.0.1:1")!, database: "db", client: "test",
                                           name: "Big Box", kind: "linux")
        }
    }

    private func list(join: String) throws -> ServerList {
        try JSONDecoder().decode(ServerList.self, from: Data(#"{"db":"db","time":1030,"desired_revision":null,"servers":[],"join":\#(join)}"#.utf8))
    }

    private func code(name: String, kind: String = "linux", expires: Double = 2800.25) throws -> JoinCode {
        try JSONDecoder().decode(JoinCode.self, from: Data(#"{"ok":true,"request_id":"r","name":"\#(name)","kind":"\#(kind)","expires_at":\#(expires),"code":null,"line":null,"replayed":true}"#.utf8))
    }

    /// A code made with no name is found by its kind and its end, which the hub wrote once for both answers; the server
    /// that joined with it is named by the hub. A code made with a name is found by it, as before.
    @Test func theJoinIsFoundByItsCodeAndNotByAName() throws {
        let joined = try list(join: #"{"name":"","kind":"linux","created":1000.25,"expires_at":2800.25,"state":"joined","server":"worker-5"}"#)
        #expect(try code(name: "").state(in: joined)?.server == "worker-5")
        #expect(try code(name: "", expires: 2900.5).state(in: joined) == nil)           // a newer code's join
        #expect(try code(name: "", kind: "mac").state(in: joined) == nil)
        #expect(try code(name: "").state(in: nil) == nil)
        let older = try list(join: #"{"name":"server-2","kind":"linux","created":1000,"expires_at":2800,"state":"open","server":null}"#)
        #expect(try code(name: "server-2", expires: 2800).state(in: older)?.state == "open")
        #expect(try code(name: "server-3", expires: 2800).state(in: older) == nil)
        let join = try #require(joined.join)
        #expect(join.isOf(name: "", kind: "linux", expiresAt: 2800.25))
        #expect(!join.isOf(name: "server-2", kind: "linux", expiresAt: 2800.25))
    }

    /// The live fleet's renames: what this Mac keeps under a name follows the private address to its new name.
    @Test func aRenamedServerIsFoundByItsAddress() {
        let before = ["hub": "100.96.10.20", "vps": "100.70.1.21", "worker4": "100.70.1.24", "mac-studio": "100.70.1.30",
                      "box": "100.70.1.40"]
        let after = ["worker-2": "100.96.10.20", "worker-1": "100.70.1.21", "worker-4": "100.70.1.24",
                     "sams-mac-studio": "100.70.1.30", "box": "100.70.1.40"]
        #expect(Servers.renames(before: before, after: after) ==
                ["hub": "worker-2", "vps": "worker-1", "worker4": "worker-4", "mac-studio": "sams-mac-studio"])
        #expect(Servers.renames(before: after, after: after).isEmpty)
        // A server that left, a name kept for another address, and a name this Mac already keeps things under move nothing.
        #expect(Servers.renames(before: ["old": "100.70.1.9"], after: ["box": "100.70.1.40"]).isEmpty)
        #expect(Servers.renames(before: ["old": "203.0.113.9"], after: ["box": "100.70.1.40"]).isEmpty)
        #expect(Servers.renames(before: ["old": "100.70.1.40", "box": "100.70.1.41"], after: ["box": "100.70.1.40"]).isEmpty)
        // Never a guess: two gone names on one address, an address with no name, or one that two servers report.
        #expect(Servers.renames(before: ["a": "100.70.1.40", "b": "100.70.1.40"], after: ["box": "100.70.1.40"]).isEmpty)
        #expect(Servers.renames(before: ["a": ""], after: ["box": ""]).isEmpty)
        #expect(Servers.renames(before: ["a": "100.70.1.40"], after: ["box": "100.70.1.40", "box-2": "100.70.1.40"]).isEmpty)
    }

    @Test func thePrepareReceiptNamesItsJob() throws {
        let receipt = try JSONDecoder().decode(ServerPrepareReceipt.self, from: Data(
            #"{"agent":"scout","server":"box","runtime":"codex","job":2,"ok":true,"request_id":"0f8b6a52-5b8e-4a59-9d3c-4bb1d1c3e0a1","client":"app","replayed":false}"#.utf8))
        #expect(receipt.ok && receipt.job == 2 && receipt.server == "box" && receipt.runtime == "codex")
    }

    /// **The mark at the end of a server's card** (the owner's answer "Nothing" for a well server, 13 November 2026): no
    /// mark while it is connected, and one mark for each kind of state that needs something.
    @Test func aWellServerHasNoMark() {
        #expect(Servers.mark((Servers.connected, false)) == nil)
        #expect(Servers.mark((Servers.updateAvailable, false)) == .update)
        #expect(Servers.mark(("Sign-in needed", true)) == .attention)
        #expect(Servers.mark(("Not answering", true)) == .attention)
        #expect(Servers.mark(("Install of Scout failed", true)) == .attention)
        #expect(Servers.mark(("Installing Scout\u{2026}", false)) == .working)
        #expect(Servers.mark(("Removing Scout\u{2026}", false)) == .working)
        #expect(Servers.mark((Servers.lastReading, false)) == .unknown)
    }

    /// **The cards' layouts, the widest first** (the owner's choice C1 of 13 November 2026): the roles and the accounts
    /// at their widest, then at their least, then compact with bars and without; the view takes the first that fits.
    @Test func theCardsTryTheWidestLayoutFirst() {
        let parts = ServerCardLayout.Parts(percent: 30, label: 28, figures: 156, accountLeast: 74)
        #expect(ServerCardLayout.candidates(role: 140, account: 170, parts: parts) == [
            ServerCardLayout(mode: .wide, role: 140, account: 170, meters: true),
            ServerCardLayout(mode: .wide, role: 96, account: 156, meters: true),
            ServerCardLayout(mode: .compact, role: nil, account: nil, meters: true),
            ServerCardLayout(mode: .compact, role: nil, account: nil, meters: false),
        ])
        // Short roles and accounts narrower than the server's figures have nothing to give: no second wide layout, and
        // the account's column keeps the figures' width.
        #expect(ServerCardLayout.candidates(role: 40, account: 90, parts: parts) == [
            ServerCardLayout(mode: .wide, role: 40, account: 156, meters: true),
            ServerCardLayout(mode: .compact, role: nil, account: nil, meters: true),
            ServerCardLayout(mode: .compact, role: nil, account: nil, meters: false),
        ])
        // The widths that the view gives each wide line: 68 before the role, 34 to the account, two cells of 82 with
        // their gaps, and 34 at the end.
        #expect(parts.beforeRole == 68 && parts.roleToAccount == 34 && parts.end == 34)
        #expect(parts.cells(2, cell: parts.wideCell) == 188 && parts.cells(0, cell: parts.wideCell) == 0)
        #expect(parts.compactCell(meters: true) == 116 && parts.compactCell(meters: false) == 64)
    }
}
