import Foundation
import Testing
@testable import FleetCore

/// **The guide's kept state and its file** (`GuideState`, `GuideStore`, `GuidePlaces`), and the events that the app
/// writes for the model (`GuideAppEvent`). Each test has a scratch folder of its own, and removes it.
struct GuideStateTests {
    private final class Scratch {
        let places = GuidePlaces(root: FileManager.default.temporaryDirectory.appendingPathComponent("guide-state-\(UUID().uuidString)"))
        deinit { places.remove() }

        /// The state as the file on the disk has it now, read new.
        var onDisk: GuideState? { (try? Data(contentsOf: places.state)).flatMap(GuideState.read) }
    }

    static func newState() -> GuideState {
        GuideState(program: "/Users/owner/.local/share/claude/versions/2.1.312", programVersion: "2.1.312",
                   programIsAppsOwn: false, session: .init(id: "00000000-0000-4000-8000-000000000001", label: "example-label"),
                   account: GuideAccount(kind: .plan, plan: "max"))
    }

    static let team = GuideTeam(agents: [
        .init(name: "iris", role: "Payments", does: "Checks each refund and each failed payment.",
              uses: [.init(kind: .key, name: "Stripe")], asksFirst: "above €50", needsBrowser: false),
        .init(name: "otto", role: "Developer", does: "Fixes the bugs of the shop.",
              uses: [.init(kind: .repo, name: "northwind/shop")], asksFirst: nil, needsBrowser: false),
    ], use: .business)

    // MARK: the file

    @Test func theStateComesBackFromItsFileAsItWas() throws {
        var state = Self.newState()
        _ = state.owner(says: "I run a shop, and refunds take my time.", at: Date(timeIntervalSince1970: 1_800_000_000))
        state.guide(says: "Which shop?\n<suggestions>\nA web shop\nA market stall\n</suggestions>")
        let card = state.show(team: Self.team)
        _ = state.press(card, at: Date(timeIntervalSince1970: 1_800_000_100))
        state.limit = .init(resetsAt: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(GuideState.read(try state.file()) == state)
    }

    @Test func aFileThatWasCutInTheMiddleOfAWriteIsNotReadAsAState() throws {
        let scratch = Scratch()
        var state = Self.newState()
        _ = state.show(team: Self.team)
        let whole = try state.file()
        for cut in [1, whole.count / 3, whole.count / 2, whole.count - 1] {
            #expect(GuideState.read(whole.prefix(cut)) == nil)
        }
        #expect(GuideState.read(Data()) == nil)
        #expect(GuideState.read(Data("{}".utf8)) == nil)
        // The same through the store: the first run then goes on without the guide.
        try scratch.places.make()
        try whole.prefix(whole.count / 2).write(to: scratch.places.state)
        #expect(GuideStore.open(scratch.places) == nil)
        try whole.write(to: scratch.places.state)
        #expect(GuideStore.open(scratch.places)?.now == state)
    }

    @Test func aFileOfANewerFormIsNotRead() throws {
        var object = try JSONSerialization.jsonObject(with: Self.newState().file()) as! [String: Any]
        object["version"] = GuideState.form + 1
        #expect(GuideState.read(try JSONSerialization.data(withJSONObject: object)) == nil)
        object["version"] = 0
        #expect(GuideState.read(try JSONSerialization.data(withJSONObject: object)) == nil)
    }

    @Test func theFileIsTheOwnersAloneAndAWriteLeavesNoOtherFile() throws {
        let scratch = Scratch()
        let store = try GuideStore(Self.newState(), in: scratch.places)
        try store.change { $0.guide(says: "Hello.") }
        let mode = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int }
        #expect(mode(scratch.places.state) == 0o600)
        #expect(mode(scratch.places.root) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.places.root.path).sorted() == ["state.json", "work"])
        store.end()
        #expect(!FileManager.default.fileExists(atPath: scratch.places.root.path))
    }

    @Test func aChangeThatTheFileCannotTakeIsNotMade() throws {
        let scratch = Scratch()
        let store = try GuideStore(Self.newState(), in: scratch.places)
        let card = try store.change { $0.show(team: Self.team) }
        // The folder is gone, so the file cannot be written.
        scratch.places.remove()
        #expect(throws: (any Error).self) { try store.change { _ = $0.press(card) } }
        #expect(store.now.card(card)?.state == .shown)
    }

    // MARK: a press

    @Test func aPressIsInTheFileBeforeItsFirstStepRuns() throws {
        let scratch = Scratch()
        let store = try GuideStore(Self.newState(), in: scratch.places)
        let card = try store.change { $0.show(team: Self.team) }
        #expect(scratch.onDisk?.card(card)?.state == .shown)

        let event = try store.change { $0.press(card, at: Date(timeIntervalSince1970: 1_800_000_000)) }
        // The file holds the press, and no step ran yet.
        #expect(event == .team(card: card))
        #expect(scratch.onDisk?.card(card)?.state == .pressed)
        #expect(scratch.onDisk?.card(card)?.pressedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(scratch.onDisk?.card(card)?.steps == [])
        #expect(scratch.onDisk?.waiting == [.team(card: card)])

        // A step is in the file before its call, with its request id and no result.
        let step = try #require(try store.change { $0.begin(step: "add_agent:iris", of: card) })
        #expect(scratch.onDisk?.card(card)?.steps.map(\.id) == [step.id])
        #expect(scratch.onDisk?.card(card)?.steps.first?.result == nil)
    }

    @Test func aStepThatRanIsNotRunASecondTimeAndOneThatWasCutKeepsItsRequestID() throws {
        let scratch = Scratch()
        let store = try GuideStore(Self.newState(), in: scratch.places)
        let card = try store.change { $0.show(team: Self.team) }
        try store.change { _ = $0.press(card) }
        let first = try #require(try store.change { $0.begin(step: "add_agent:iris", of: card) })

        // A quit here, and a new start: the step comes back with the same id and no result, so its call goes again
        // under the same request id.
        let again = try #require(GuideStore.open(scratch.places))
        let same = try #require(try again.change { $0.begin(step: "add_agent:iris", of: card) })
        #expect(same.id == first.id)
        #expect(same.result == nil)
        try again.change { $0.end(step: same.id, result: "done") }

        // One more quit: the step has its result, and it is not run again.
        let third = try #require(GuideStore.open(scratch.places))
        #expect(try third.change { $0.begin(step: "add_agent:iris", of: card) }?.result == "done")
        #expect(third.now.card(card)?.steps.count == 1)
        let other = try #require(try third.change { $0.begin(step: "add_agent:otto", of: card) })
        #expect(other.id != first.id)
        try third.change { $0.carriedOut(card) }
        #expect(GuideStore.open(scratch.places)?.now.card(card)?.carriedOut == true)
    }

    @Test func onlyTheNewestCardThatShowsCanBePressed() {
        var state = Self.newState()
        let first = state.show(team: Self.team)
        let second = state.show(team: Self.team)
        #expect(first != second)
        #expect(state.card(first)?.state == .replaced)
        #expect(state.press(first) == nil)
        #expect(state.begin(step: "add_agent:iris", of: second) == nil)       // not pressed yet
        #expect(state.press(second) == .team(card: second))
        #expect(state.press(second) == nil)                                    // a press is one press
        #expect(state.pressedTeam == Self.team)
        // A card of another kind takes no button from the team card.
        let servers = state.show(servers: [.init(name: "build-1", role: .hub)])
        #expect(state.card(second)?.state == .pressed)
        #expect(state.press(servers, servers: [.init(name: "build-1", role: .agents)])
                == .servers(card: servers, roles: [.init(name: "build-1", role: .agents)]))
        #expect(state.thread.compactMap(\.card) == [first, second, servers])
    }

    @Test func aRepairsCardIsPressedOrLeftOut() {
        var state = Self.newState()
        state.note(.installStopped(server: "build-3", kind: .heldLock))
        let card = state.show(repair: "build-3")
        #expect(state.leaveOut(card) == .repair(server: "build-3", result: .leftOut))
        #expect(state.card(card)?.state == .leftOut)
        #expect(state.installStops["build-3"] == nil)
        #expect(state.press(card) == nil)
    }

    // MARK: the conversation

    @Test func aMessageThatTheGuardRefusesIsNotKept() {
        var state = Self.newState()
        #expect(state.owner(says: "My key is " + GuideExampleKey.text) == .failure(.looksLikeAKey))
        #expect(state.owner(says: "   ") == .failure(.empty))
        #expect(state.ownerWords.isEmpty && state.thread.isEmpty)
        #expect(state.owner(says: " The shop is northwind/shop. ") == .success("The shop is northwind/shop."))
        #expect(state.owner(says: "Sort my mail and draft the replies", pressedRow: true) == .success("Sort my mail and draft the replies"))
        #expect(state.ownerWords.map(\.pressedRow) == [false, true])
        // A pressed row is his answer, but its words are the model's: the name rule does not read it.
        #expect(state.typed == ["The shop is northwind/shop."])
        #expect(state.thread.map(\.owner) == [0, 1])
    }

    @Test func theGuidesWordsAreKeptAsTheyAreDrawn() {
        var state = Self.newState()
        state.guide(says: "Is this fleet for personal use or for a business?\n<suggestions>\nPersonal use\nA business\n</suggestions>")
        state.guide(says: "<suggestions>\nOnly one row\n</suggestions>")
        #expect(state.thread.count == 1)
        #expect(state.thread[0].text == "Is this fleet for personal use or for a business?")
        #expect(state.thread[0].rows == ["Personal use", "A business"])
    }

    // MARK: the events

    @Test func anEventTellsTheStateWhatItSaysOfTheSetup() {
        var state = Self.newState()
        let fact = GuideServerFact(name: "build-1", address: "203.0.113.5", system: "Ubuntu 24.04", memoryGB: 8, ports: [80, 443],
                                   roles: [.hub, .agents, .apps, .out], needsPassword: false, stop: nil)
        state.note(.serversChecked([fact]))
        state.note(.fleet(.up)); state.note(.fleet(.up)); state.note(.fleet(.vaultReady))
        state.note(.installStopped(server: "build-1", kind: .portInUse))
        state.note(.page("fleet_servers", GuidePageResult(.done), step: .two), at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(state.checked == [fact])
        #expect(state.fleet == [.up, .vaultReady])
        #expect(state.installStops == ["build-1": .portInUse])
        #expect(state.pages.map(\.name) == ["fleet_servers"])
        #expect(state.waiting.count == 6)
        state.note(.repair(server: "build-1", result: .repaired))
        #expect(state.installStops.isEmpty)
        state.taken(6)
        #expect(state.waiting == [.repair(server: "build-1", result: .repaired)])
        state.taken(5)
        #expect(state.waiting.isEmpty)
    }

    private static func object(_ event: GuideAppEvent) throws -> NSDictionary {
        let message = event.message
        #expect(message.hasPrefix("<app-event>{") && message.hasSuffix("}</app-event>"))
        let json = message.dropFirst(GuideAppEvent.open.count).dropLast(GuideAppEvent.close.count)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }

    @Test func eachEventIsOneObjectBetweenTheMarksWithTheNamesOfTheSpec() throws {
        #expect(try Self.object(.start(provider: .claudeCode, account: GuideAccount(kind: .plan, plan: "max"), manager: " Juno ", stand: .new))
                == ["event": "start", "provider": "claude_code", "account": "plan", "plan": "max", "manager": "Juno", "setup": "new"])
        #expect(try Self.object(.team(card: "c1")) == ["event": "team", "card": "c1"])
        #expect(try Self.object(.page("fleet_servers", GuidePageResult(.done), step: .each))
                == ["event": "page", "page": "fleet_servers", "result": "done", "step": "each"])
        #expect(try Self.object(.page("provider_token", GuidePageResult(.stopped, words: "The token has too few rights.")))
                == ["event": "page", "page": "provider_token", "result": "stopped", "stop": "The token has too few rights."])
        #expect(try Self.object(.servers(card: "c2", roles: [.init(name: "build-1", role: .hub), .init(name: "build-2", role: .out)]))
                == ["event": "servers", "card": "c2", "servers": [["name": "build-1", "role": "hub"], ["name": "build-2", "role": "out"]]])
        #expect(try Self.object(.installStopped(server: "build-3", kind: .halfInstalledPackage))
                == ["event": "install_stopped", "server": "build-3", "kind": "half_installed_package", "repairable": true])
        #expect(try Self.object(.installStopped(server: "build-3", kind: .other))
                == ["event": "install_stopped", "server": "build-3", "kind": "other", "repairable": false])
        #expect(try Self.object(.repair(server: "build-3", result: .notRepaired(.needsRestart)))
                == ["event": "repair", "server": "build-3", "result": "not_repaired", "reason": "needs_restart"])
        #expect(try Self.object(.secret(.saved, service: "Stripe", holder: "Payments"))
                == ["event": "secret", "result": "saved", "service": "Stripe", "holder": "Payments"])
        #expect(try Self.object(.build(.install, .running)) == ["event": "build", "step": "install", "result": "running"])
        #expect(try Self.object(.fleet(.teamMade)) == ["event": "fleet", "result": "team_made"])
        let fact = GuideServerFact(name: "build-1", address: "203.0.113.5", system: "Ubuntu 24.04", memoryGB: 8, ports: [80, 443],
                                   roles: [.agents, .out], needsPassword: true, stop: nil)
        #expect(try Self.object(.serversChecked([fact])) == ["event": "servers_checked", "servers": [[
            "name": "build-1", "address": "203.0.113.5", "system": "Ubuntu 24.04", "memory_gb": 8, "ports": [80, 443],
            "roles": ["agents", "out"], "needs_password": true,
        ]]])
    }

    @Test func aManagersNameThatTheHubDoesNotTakeIsNotInTheStartEvent() throws {
        let event = GuideAppEvent.start(provider: .claudeCode, account: GuideAccount(kind: .key), manager: "two words", stand: .building)
        #expect(try Self.object(event) == ["event": "start", "provider": "claude_code", "account": "key", "setup": "building"])
    }

    @Test func theResumedEventIsTheAppsOwnAccountFromTheKeptState() throws {
        var state = Self.newState()
        _ = state.owner(says: "The shop is northwind/shop.")
        _ = state.owner(says: "A business", pressedRow: true)
        // A message that is in the file from before a guard knew its shape passes the guard again, and stays out.
        state.ownerWords.append(.init(text: "old words with " + GuideExampleKey.text, at: Date(), pressedRow: false))
        let old = state.show(team: Self.team)
        let team = state.show(team: Self.team)
        _ = state.press(team)
        let servers = state.show(servers: [.init(name: "build-1", role: .hub)])
        state.note(.page("fleet_servers", GuidePageResult(.done)))
        state.note(.page("provider_token", GuidePageResult(.back)))
        #expect(try Self.object(.resumed(from: state)) == [
            "event": "resumed", "provider": "claude_code", "account": "plan", "plan": "max",
            "pressed": [["card": team, "kind": "team"]], "can_be_pressed": [["card": servers, "kind": "servers"]],
            "pages_done": ["fleet_servers"],
            "owner_messages": [["text": "The shop is northwind/shop.", "pressed_suggestion": false],
                               ["text": "A business", "pressed_suggestion": true]],
        ])
        #expect(state.card(old)?.state == .replaced)
    }
}
