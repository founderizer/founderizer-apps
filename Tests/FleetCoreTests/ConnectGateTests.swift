import Foundation
import Testing
@testable import FleetCore

/// Turn on and Turn off of the connected apps (`ConnectGate`): the root step's program, what its run printed, the
/// owner's sentence for each real stop, the steps with stand-ins, and what the group "Connect an app" shows. Example
/// names only.
///
/// The messages below are pinned copies of the hub's own (`hubsetup.py` `cmd_connect`, `connect_on`, `connect_off`,
/// `hub_account`, `tailnet_name`; `hub.py` `capp_funnel_ok`), because the public copy of the apps has no `hubsetup.py`.
/// The hub's test `test_connected_apps.GateWords` holds each phrase of `ConnectGate.matches` against the real files.
struct ConnectGateTests {
    private let kit = "/usr/local/lib/founderizer-kit"

    // MARK: the program

    @Test func theProgramBridgesClonesAndRunsTheStepAsRoot() {
        let step = "python3 \(kit)/hubsetup.py"
        #expect(ConnectGate.program(turn: .on)
                == CentralVaultRemote.bridge() + "; \(step) kit-clone || exit 1; \(step) connect on")
        #expect(ConnectGate.program(turn: .off)
                == CentralVaultRemote.bridge() + "; \(step) kit-clone || exit 1; \(step) connect off")
        // sudo -i would let root's login shell expand a "$"
        #expect(!ConnectGate.program(turn: .on).contains("$") && !ConnectGate.program(turn: .off).contains("$"))
    }

    // MARK: what the run printed

    @Test func aRunThatEndedWellIsDone() {
        let printed = """
            Founderizer: the user founderizer-connect is there
            Founderizer: Funnel publishes https://hub-1.tail1234.ts.net to the gate
            {"ok": true, "name": "hub-1.tail1234.ts.net", "address": "https://hub-1.tail1234.ts.net/mcp", "state": "made"}
            """
        #expect(ConnectGate.outcome(printed) == .done(state: "made", address: "https://hub-1.tail1234.ts.net/mcp"))
        #expect(ConnectGate.outcome(#"{"ok": true, "state": "off"}"#, turn: .off) == .done(state: "off", address: nil))
    }

    /// After a stop, `hubsetup.py` writes its own line to standard error after the object: the object is the answer.
    @Test func theAnswerIsTheLastObjectAndNotTheLineAfterIt() {
        let printed = """
            Founderizer: made the system user founderizer-connect, with no login and no home
            {"ok": false, "error": "Tailscale Funnel on port 443 could not be put in place: Logged out."}
            Founderizer install stopped: Tailscale Funnel on port 443 could not be put in place: Logged out.
            """
        guard case .stopped(let stop) = ConnectGate.outcome(printed) else { Issue.record("no stop"); return }
        #expect(stop.words == "Setting up connected apps on your hub's server failed.")
        #expect(stop.retries && !stop.keyAgain)
        #expect(stop.said == "Tailscale Funnel on port 443 could not be put in place: Logged out.")
    }

    // MARK: his sentence for each real stop

    /// The table "The real stops, and his sentence for each" of the pictures he approved, one row each.
    @Test func eachRealStopHasHisSentenceAndItsControl() {
        let rows: [(said: String, words: String, retries: Bool)] = [
            ("run it as root on the hub's machine: sudo python3 /usr/local/lib/founderizer-kit/hubsetup.py connect on",
             "Founderizer could not run the setup as root on your hub's server.", false),
            ("the connect gate is installed only from root's own clone, /usr/local/lib/founderizer-kit, which kit-clone "
             + "makes: never from a folder that the hub's user can change",
             "Founderizer could not run the setup as root on your hub's server.", false),
            ("there is no user fleet on this machine: name the user the hub runs as with --hub-user.",
             "Your hub's user is missing on its server.", false),
            ("the hub never runs as root, so root cannot be the one user the central vault answers.",
             "Your hub's user is missing on its server.", false),
            ("Tailscale gives this machine no full DNS name: turn on MagicDNS for the private network.",
             "MagicDNS is off on your private network. Turn it on in Tailscale's DNS page.", true),
            ("this machine's Tailscale already publishes hub-1.tail1234.ts.net:443/ to http://127.0.0.1:3000, so the "
             + "connect gate is not put in place. Nothing was changed.",
             "Your hub's server already publishes another address on port 443. Founderizer does not change it.", false),
            ("/usr/local/lib/founderizer-kit/gate.py is not readable, so the connect gate cannot be installed.",
             "This release's files are missing on your hub's server.", false),
            ("the user founderizer-connect is there with another group (staff). Nothing more was changed.",
             "Your hub's server already has a user named founderizer-connect for something else.", false),
            ("the folder /var/lib/founderizer-connect could not be put in place: install: invalid group",
             "Setting up connected apps on your hub's server failed.", true),
            ("the gate is failed 3 seconds after its start. Read `journalctl -u founderizer-connect -n 30` on this machine.",
             "Connected apps did not keep running on your hub's server.", false),
            ("the hub cannot read the Tailscale serve status, so its socket for connected apps stays closed: timed out",
             "Your hub cannot read Tailscale's state.", true),
            ("Tailscale Funnel does not publish only the gate (http://127.0.0.1:8767), so the hub's socket for connected "
             + "apps stays closed. Funnel: hub-1.tail1234.ts.net:8443/ to http://127.0.0.1:9000",
             "Your hub's server already publishes another address on port 443. Founderizer does not change it.", false),
            ("connect on stopped (KeyError).", "Turning on stopped on your hub's server.", true),
        ]
        for row in rows {
            let stop = ConnectGate.stop(row.said)
            #expect(stop.words == row.words, "\(row.said)")
            #expect(stop.retries == row.retries, "\(row.said)")
            #expect(stop.said == row.said)
        }
    }

    /// Funnel status that does not show the gate alone: the policy lacks the funnel attribute, so Try again opens his
    /// key page, because the token is not kept.
    @Test func aPolicyWithoutTheFunnelAttributeAsksForTheKeyAgain() {
        let stop = ConnectGate.stop("`tailscale funnel status --json` does not show https://hub-1.tail1234.ts.net "
            + "published to http://127.0.0.1:8767 alone. The Tailscale policy may not give this machine the funnel attribute.")
        #expect(stop.words == "Tailscale does not let your hub's server publish the address yet.")
        #expect(stop.retries && stop.keyAgain)
        // The three stops of the look at the machine's rights (`hubsetup.py` CONNECT_NO_FUNNEL, CONNECT_NO_HTTPS and
        // CONNECT_FUNNEL_WAITS), which a real Funnel test added: the same sentence, and the key page again.
        for said in ["the policy of the private network does not give this machine the funnel attribute, so Tailscale "
                        + "Funnel cannot publish the address. Nothing was changed.",
                     "HTTPS certificates are off for the private network, so Tailscale Funnel cannot publish the "
                        + "address. Nothing was changed.",
                     "Tailscale did not turn Funnel on in 60 seconds: the private network does not let this machine "
                        + "publish the address yet."] {
            let stop = ConnectGate.stop(said)
            #expect(stop.words == "Tailscale does not let your hub's server publish the address yet.", "\(said)")
            #expect(stop.retries && stop.keyAgain, "\(said)")
            #expect(stop.said == said)
        }
        // A Funnel that Tailscale refuses in its own words stays the stop of a part, with Try again and no key page.
        let part = ConnectGate.stop("Tailscale Funnel on port 443 could not be put in place: Logged out.")
        #expect(part.words == "Setting up connected apps on your hub's server failed.")
        #expect(part.retries && !part.keyAgain)
    }

    @Test func theStopsOfTurnOff() {
        let funnel = ConnectGate.stop("`tailscale funnel --https=443 off` failed: no serve config", turn: .off)
        #expect(funnel.words == "Tailscale did not stop publishing the address." && funnel.retries)
        let service = ConnectGate.stop("the service founderizer-connect could not be stopped: Failed to stop", turn: .off)
        #expect(service.words == "Connected apps did not stop on your hub's server." && service.retries)
        #expect(ConnectGate.stop("connect off stopped (OSError).", turn: .off).words == "Turning off stopped on your hub's server.")
    }

    @Test func aMessageThatMatchesNothingCanBeTriedAgain() {
        for said in ["", "Founderizer install stopped: the release is not signed"] {
            let stop = ConnectGate.stop(said)
            #expect(stop.words == "Turning on stopped on your hub's server." && stop.retries && !stop.keyAgain)
        }
        // whatever the hub calls a part, the sentence is the one of every part, and the hub's words are not in it
        let odd = ConnectGate.stop("a part: with a colon could not be put in place: x")
        #expect(odd.words == "Setting up connected apps on your hub's server failed." && odd.retries)
        // A run with no object is read by its last line.
        #expect(ConnectGate.outcome("Founderizer install stopped: no signed release")
                == .stopped(ConnectStop(words: "Turning on stopped on your hub's server.", retries: true,
                                        said: "Founderizer install stopped: no signed release")))
    }

    @Test func sudoThatAsksForAPasswordIsTheRootStop() {
        guard case .stopped(let stop) = ConnectGate.outcome("sudo: a password is required") else { Issue.record("no stop"); return }
        #expect(stop.words == "Founderizer could not run the setup as root on your hub's server." && !stop.retries)
    }

    // MARK: the steps

    /// What the stand-ins were asked, in order.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ call: String) { lock.lock(); all.append(call); lock.unlock() }
        var list: [String] { lock.lock(); defer { lock.unlock() }; return all }
    }

    private struct Down: LocalizedError { var errorDescription: String? { "ssh: connect to host 100.64.0.2 port 22: Operation timed out" } }

    private func steps(_ calls: Calls, printed: @escaping @Sendable (ConnectTurn) throws -> LocalShell.Answer = { turn in
        LocalShell.Answer(status: 0, output: #"{"ok": true, "state": "\#(turn == .on ? "made" : "off")"}"#)
    }, setting: @escaping @Sendable (Bool) throws -> Void = { _ in }, readyAfter: Int = 0) -> ConnectGate.Steps {
        ConnectGate.Steps(
            rootStep: { turn in calls.add("root \(turn.rawValue)"); return try printed(turn) },
            setting: { on in calls.add("setting \(on)"); try setting(on) },
            ready: { let waited = calls.list.filter { $0 == "wait" }.count; calls.add("ready?"); return waited >= readyAfter },
            wait: { calls.add("wait") })
    }

    @Test func turnOnRunsTheRootStepThenTheSettingThenWaitsForTheHub() async {
        let calls = Calls()
        #expect(await ConnectGate.turnOn(steps(calls, readyAfter: 2)) == nil)
        // the hub's reason is asked after each round of the wait, and never before the first
        #expect(calls.list == ["root on", "setting true", "ready?", "wait", "ready?", "ready?", "wait", "ready?"])
    }

    @Test func aRootStepThatStopsStopsTheRun() async {
        let calls = Calls()
        let stop = await ConnectGate.turnOn(steps(calls, printed: { _ in
            LocalShell.Answer(status: 1, output: #"{"ok": false, "error": "Tailscale gives this machine no full DNS name: turn on MagicDNS for the private network."}"#)
        }))
        #expect(stop?.words == "MagicDNS is off on your private network. Turn it on in Tailscale's DNS page.")
        #expect(calls.list == ["root on"])
    }

    @Test func aServerThatDoesNotAnswerIsUnreached() async {
        let thrown = await ConnectGate.turnOn(steps(Calls(), printed: { _ in throw Down() }))
        #expect(thrown?.words == "Founderizer could not reach your hub's server." && thrown?.retries == true)
        #expect(thrown?.said == "ssh: connect to host 100.64.0.2 port 22: Operation timed out")
        let refused = await ConnectGate.turnOn(steps(Calls(), printed: { _ in
            LocalShell.Answer(status: 255, output: "ssh: connect to host 100.64.0.2 port 22: Connection refused")
        }))
        #expect(refused?.words == "Founderizer could not reach your hub's server.")
    }

    /// A hub that refuses the setting leaves nothing published: the root step is taken back.
    @Test func aRefusedSettingStopsTheRunAndTakesTheRootStepBack() async {
        let calls = Calls()
        let stop = await ConnectGate.turnOn(steps(calls, setting: { _ in throw HubError.invalidResponse }))
        #expect(stop?.words == "Turning on stopped on your hub's server." && stop?.retries == true)
        #expect(calls.list == ["root on", "setting true", "root off"])
        // The hub took the write and only its answer was lost: the hub says on, so nothing is taken back and the
        // wait goes on to its end.
        let lost = Calls()
        var took = steps(lost, setting: { _ in throw HubError.invalidResponse }, readyAfter: 1)
        took.isOn = { lost.add("on?"); return true }
        #expect(await ConnectGate.turnOn(took) == nil)
        #expect(lost.list == ["root on", "setting true", "on?", "ready?", "wait", "ready?"])
        // The hub does not answer: nothing is taken back on a guess, and the stop shows with Try again.
        let silent = Calls()
        var unknown = steps(silent, setting: { _ in throw HubError.invalidResponse })
        unknown.isOn = { silent.add("on?"); return nil }
        #expect(await ConnectGate.turnOn(unknown)?.retries == true)
        #expect(silent.list == ["root on", "setting true", "on?"])
    }

    /// The hub is on and says why no connected app can reach it: the wait ends with his sentence for that reason.
    @Test func theWaitEndsWhenTheHubSaysWhyItDoesNotWork() async {
        let calls = Calls()
        var all = steps(calls, readyAfter: 99)
        all.closed = {
            calls.add("closed?")
            return calls.list.filter { $0 == "wait" }.count < 2 ? nil
                : "the hub cannot read the Tailscale serve status, so its socket for connected apps stays closed: timed out"
        }
        let stop = await ConnectGate.turnOn(all)
        #expect(stop?.words == "Your hub cannot read Tailscale's state." && stop?.retries == true)
        #expect(calls.list == ["root on", "setting true", "ready?", "wait", "ready?", "closed?", "ready?", "wait", "ready?",
                               "closed?"])
    }

    /// A host key that this Mac does not know: the server was not reached, and a second try cannot work.
    @Test func anUnknownHostKeyIsNoMatterOfASecondTry() async {
        let stop = await ConnectGate.turnOn(steps(Calls(), printed: { _ in
            LocalShell.Answer(status: 255, output: "No ED25519 host key is known for 100.64.0.2 and you have requested "
                + "strict checking.\nHost key verification failed.")
        }))
        #expect(stop?.words == "Founderizer could not reach your hub's server." && stop?.retries == false)
    }

    /// Every part of the root step has one sentence, and the part's name is only in what the stop carries for a
    /// report (the owner's answer of 13 November 2026: "Yes, replace it").
    @Test func everyPartHasOneSentenceAndItsNameIsOnlyInTheReport() {
        for said in ["the user founderizer-connect could not be put in place: x",
                     "the folder /var/lib/founderizer-connect could not be put in place: x",
                     "the gate's program could not be put in place: x",
                     "the service founderizer-connect could not be put in place: x",
                     "the mark of the gate's start could not be put in place: x",
                     "Tailscale Funnel on port 443 could not be put in place: x"] {
            let stop = ConnectGate.stop(said)
            #expect(stop.words == "Setting up connected apps on your hub's server failed.", "\(said)")
            #expect(stop.retries && !stop.keyAgain)
            #expect(stop.said == said)
        }
    }

    /// "The gate" is a word of the code. No sentence that the owner reads names it: each says "connected apps" (his
    /// answer of 13 November 2026: "Yes, replace it"). This holds every sentence that a stop can have.
    @Test func noSentenceThatHeReadsNamesTheGate() {
        var sentences = ConnectGate.matches.map(\.stop.words)
        sentences += [ConnectGate.unreached.words, ConnectGate.notRoot.words, ConnectGate.cutOff(.on).words,
                      ConnectGate.cutOff(.off).words, ConnectGate.stop("no such message").words,
                      ConnectGate.stop("no such message", turn: .off).words]
        // each real message of the hub that has the word in it
        for said in ["the gate is failed 3 seconds after its start. Read `journalctl -u founderizer-connect -n 30` on this machine.",
                     "the gate's program could not be put in place: x", "the mark of the gate's start could not be put in place: x",
                     "the gate of the connected apps does not forward to the hub's socket on this machine: `hubsetup.py connect "
                        + "on` as root puts it right",
                     "the service founderizer-connect could not be stopped: x",
                     "Tailscale Funnel does not publish only the gate (http://127.0.0.1:8767), so the hub's socket for "
                        + "connected apps stays closed. Funnel: hub-1.tail1234.ts.net:8443/ to http://127.0.0.1:9000"] {
            sentences.append(ConnectGate.stop(said).words)
            sentences.append(ConnectGate.stop(said, turn: .off).words)
        }
        #expect(sentences.count >= 30)
        for sentence in sentences {
            #expect(!sentence.lowercased().contains("gate"), "\(sentence)")
            #expect(!sentence.isEmpty && sentence.hasSuffix("."))
        }
        #expect(ConnectGate.stop("the gate is failed 3 seconds after its start.").words
                == "Connected apps did not keep running on your hub's server.")
        #expect(ConnectGate.stop("the service founderizer-connect could not be stopped: x", turn: .off).words
                == "Connected apps did not stop on your hub's server.")
    }

    /// A turn that runs is kept for its hub, so that a quit shows its row at the next launch; its end takes it away.
    @Test func aTurnThatAQuitCutOffIsKeptForItsHub() throws {
        let defaults = try #require(UserDefaults(suiteName: "connect-gate-tests-\(UUID().uuidString)"))
        let hub = try #require(URL(string: "http://100.64.0.2:8765")), other = try #require(URL(string: "http://100.64.0.3:8765"))
        #expect(ConnectGate.kept(hub, in: defaults) == nil)
        ConnectGate.keep(.off, for: hub, in: defaults)
        #expect(ConnectGate.kept(hub, in: defaults) == .off && ConnectGate.kept(other, in: defaults) == nil)
        #expect(ConnectGate.keptKey(hub) == "connectTurn.100.64.0.2:8765")
        // two hubs on one host with other ports are two hubs
        let beside = try #require(URL(string: "http://100.64.0.2:8766"))
        #expect(ConnectGate.kept(beside, in: defaults) == nil)
        ConnectGate.keep(nil, for: hub, in: defaults)
        #expect(ConnectGate.kept(hub, in: defaults) == nil)
        #expect(ConnectGate.cutOff(.on).words == "Turning on stopped on your hub's server." && ConnectGate.cutOff(.on).retries)
        #expect(ConnectGate.cutOff(.off).words == "Turning off stopped on your hub's server.")
    }

    @Test func turnOffWritesTheSettingFirstThenTheRootStep() async {
        let calls = Calls()
        #expect(await ConnectGate.turnOff(steps(calls)) == nil)
        #expect(calls.list == ["setting false", "root off"])
        let stopped = Calls()
        let stop = await ConnectGate.turnOff(steps(stopped, setting: { _ in throw HubError.invalidResponse }))
        #expect(stop?.words == "Turning off stopped on your hub's server.")
        #expect(stopped.list == ["setting false"])
    }

    // MARK: what the group shows

    private func reading(on: Bool, canTurnOn: Bool?, stopped: String? = nil) throws -> ConnectState {
        var fields: [String: Any] = ["db": "db", "on": on, "address": NSNull(), "connections": [], "gate": ["version": NSNull(), "ok": false]]
        if let canTurnOn { fields["can_turn_on"] = canTurnOn }
        if let stopped { fields["stopped"] = stopped }
        return try JSONDecoder().decode(ConnectState.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func theGroupComesFromTheHubsAnswersAndTheRun() throws {
        let offer = ["mobile", "connect_offer"]
        let off = try reading(on: false, canTurnOn: true)
        #expect(ConnectGate.show(features: offer, state: off, run: .idle, canAct: true) == .off(turnOn: true))
        // no write now, no answer yet, or a hub that cannot turn it on: no group
        #expect(ConnectGate.show(features: offer, state: off, run: .idle, canAct: false) == .nothing)
        #expect(ConnectGate.show(features: offer, state: nil, run: .idle, canAct: true) == .nothing)
        #expect(ConnectGate.show(features: offer, state: try reading(on: false, canTurnOn: nil), run: .idle, canAct: true) == .nothing)
        // a hub that names neither feature, or serves connected_apps: not this group
        #expect(ConnectGate.show(features: ["mobile"], state: off, run: .idle, canAct: true) == .nothing)
        #expect(ConnectGate.show(features: offer + ["connected_apps"], state: off, run: .turningOn, canAct: true) == .nothing)
        // the run, and the wait that the hub's answer says after a quit
        #expect(ConnectGate.show(features: offer, state: off, run: .turningOn, canAct: true) == .turningOn)
        #expect(ConnectGate.show(features: offer, state: try reading(on: true, canTurnOn: false), run: .idle, canAct: true) == .turningOn)
        // the root step of a Turn off: no picture has that moment, so no group shows
        #expect(ConnectGate.show(features: offer, state: off, run: .turningOff, canAct: true) == .nothing)
        // on, and the hub says why it does not work: the row with his sentence for that reason, so the wait has an end
        let closed = try reading(on: true, canTurnOn: false, stopped: "Tailscale Funnel does not publish only the gate "
            + "(http://127.0.0.1:8767), so the hub's socket for connected apps stays closed. Funnel: "
            + "hub-1.tail1234.ts.net:8443/ to http://127.0.0.1:9000")
        guard case .stopped(let why, .on) = ConnectGate.show(features: offer, state: closed, run: .idle, canAct: true) else {
            Issue.record("no row"); return
        }
        #expect(why.words == "Your hub's server already publishes another address on port 443. Founderizer does not change it.")
        #expect(!why.retries)
        let noGate = try reading(on: true, canTurnOn: false, stopped: "the gate of the connected apps does not forward to "
            + "the hub's socket on this machine: `hubsetup.py connect on` as root puts it right")
        #expect(ConnectGate.show(features: offer, state: noGate, run: .idle, canAct: true)
                == .stopped(ConnectGate.stop(noGate.stopped ?? ""), .on))
        #expect(ConnectGate.stop(noGate.stopped ?? "").words == "Connected apps did not keep running on your hub's server.")
        #expect(ConnectGate.stop(noGate.stopped ?? "").retries)      // the root step starts the gate again
        // Funnel was turned off on the hub's machine: a Try again that runs the root step, with no key page
        let noFunnel = ConnectGate.stop("Tailscale Funnel publishes nothing on the hub's machine, so the hub's socket for "
            + "connected apps stays closed: `hubsetup.py connect on` as root turns it on")
        #expect(noFunnel.words == "Tailscale does not let your hub's server publish the address yet.")
        #expect(noFunnel.retries && !noFunnel.keyAgain)
        // a run of this launch comes before the hub's reason, and an empty reason is none
        #expect(ConnectGate.show(features: offer, state: closed, run: .turningOn, canAct: true) == .turningOn)
        #expect(ConnectGate.show(features: offer, state: try reading(on: true, canTurnOn: false, stopped: ""), run: .idle,
                                 canAct: true) == .turningOn)
        #expect(try reading(on: false, canTurnOn: true).stopped == nil)
        let stop = ConnectGate.unreached
        #expect(ConnectGate.show(features: offer, state: off, run: .stopped(stop, .off), canAct: true) == .stopped(stop, .off))
        #expect(ConnectGate.show(features: offer, state: off, run: .keyPage, canAct: true) == .off(turnOn: true))
    }

    @Test func theWaitEndsWhenTheHubServesTheFeatureOrNamesNeither() {
        #expect(!ConnectGate.ready(features: ["connect_offer"]))
        #expect(ConnectGate.ready(features: ["connect_offer", "connected_apps"]))
        #expect(ConnectGate.ready(features: ["mobile"]) && ConnectGate.ready(features: nil))
    }

    // MARK: Report a problem

    @Test func reportAProblemCarriesTheStop() {
        let stop = ConnectGate.stop("the gate is failed 3 seconds after its start.")
        let found = FleetTrouble.read(connectionError: nil, storageError: nil, isFresh: true, state: nil, health: nil,
                                      machines: [], servers: [], checklists: [:], at: 0, connectStop: (stop, .on))
        let row = found.findings.first { $0.id == "hub/connect" }
        #expect(row?.title == "Connected apps did not turn on")
        #expect(row?.says == "Connected apps did not keep running on your hub's server.")
        let none = FleetTrouble.read(connectionError: nil, storageError: nil, isFresh: true, state: nil, health: nil,
                                     machines: [], servers: [], checklists: [:], at: 0)
        #expect(!none.findings.contains { $0.id == "hub/connect" })
    }
}
