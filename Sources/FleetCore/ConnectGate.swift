import Foundation

/// **Turning the connected apps on and off** (the build specification of the MCP address, section 7; the owner's yes of
/// 13 November 2026 to the pictures 2a to 2f of Settings › Servers). Pure logic, with no view: the root step on the
/// hub's machine and what it printed, the owner's sentence for each real stop, the steps of a Turn on and of a Turn off,
/// and what the group "Connect an app" shows. The Mac app runs the steps from its store (`ConnectSwitchModel`).
///
/// Turn on: his Tailscale access token once (`ConnectNetworkAnswer`, the seam of the token's calls), then by itself the
/// root step `hubsetup.py connect on`, then `POST /ui/connect/settings {on: true}`, then the wait until the hub serves
/// `connected_apps`. Turn off: `POST /ui/connect/settings {on: false}`, then the root step `connect off`. Each step skips
/// what is done, so Try again runs every step again.
public enum ConnectTurn: String, Equatable, Sendable {
    case on, off
}

/// Why a turn on or off stopped, in the owner's words, and whether Try again can work. A stop that needs work on the
/// machine has Report a problem instead. `keyAgain`: Try again opens his Tailscale key page again, because the token is
/// not kept. `said`: the words of the hub's own message, for Report a problem only: no row of the page shows them.
public struct ConnectStop: Equatable, Sendable {
    public let words: String
    public let retries: Bool
    public let keyAgain: Bool
    public let said: String

    public init(words: String, retries: Bool, keyAgain: Bool = false, said: String = "") {
        self.words = words; self.retries = retries; self.keyAgain = keyAgain; self.said = said
    }

    /// The same stop, with the words of the message that it was read from.
    func saying(_ said: String) -> ConnectStop {
        ConnectStop(words: words, retries: retries, keyAgain: keyAgain, said: String(said.prefix(300)))
    }
}

/// What the calls of his pasted Tailscale token came to (`TailscaleFleetKey.connectNetwork`: the two policy lines, the
/// tag on the hub's device, MagicDNS and HTTPS certificates). `done`: the network is ready, and the steps go on by
/// themselves. `addLines`: another tool keeps the Tailscale policy, so he adds these lines there and pastes a key again
/// (`PolicyLines`).
public enum ConnectNetworkAnswer: Equatable, Sendable {
    case done
    case addLines(String)
}

public enum ConnectGate {
    // MARK: the root step

    /// **The run, as root on the hub's machine**, in the pattern of `HubTCP.program`: first the bridge across the key
    /// change of 4 November 2026 and `kit-clone`, as in the central vault's install; when one of them fails, the run
    /// stops there. Then `hubsetup.py connect on|off` of root's own clone, with the default hub user, as the central
    /// vault's install has it. The text has no "$": a user who is not root runs it through `sudo -n -i` (`HubTCP`).
    public static func program(turn: ConnectTurn, in kit: String = CentralVaultRemote.rootKit) -> String {
        let step = "python3 \(kit)/hubsetup.py"
        return CentralVaultRemote.bridge(in: kit) + "; \(step) kit-clone || exit 1; \(step) connect \(turn.rawValue)"
    }

    /// What one run came to.
    public enum Outcome: Equatable, Sendable {
        /// The step ended well: `state` is "made", "there" or "off", and `address` the public address after `on`.
        case done(state: String, address: String?)
        case stopped(ConnectStop)
    }

    /// **The outcome in what the run printed.** `cmd_connect` ends with one JSON object on standard output, `{"ok":
    /// true, "state": ..., "address": ...}` or `{"ok": false, "error": "<one sentence>"}`. The app reads standard output
    /// and standard error as one, and after a stop `hubsetup.py` writes its own line to standard error after that
    /// object ("Founderizer install stopped: ..."), so the answer is the last line that is such an object. A run with
    /// none (`sudo` refused, `kit-clone` stopped) is read by its own last line.
    public static func outcome(_ output: String, turn: ConnectTurn = .on) -> Outcome {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines.reversed() where line.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ok = object["ok"] as? Bool else { continue }
            if ok {
                return .done(state: object["state"] as? String ?? "", address: object["address"] as? String)
            }
            return .stopped(stop(object["error"] as? String ?? "", turn: turn))
        }
        if let refused = lines.first(where: { line in sudoRefusals.contains { line.contains($0) } }) {
            return .stopped(notRoot.saying(refused))
        }
        return .stopped(stop(lines.last ?? "", turn: turn))
    }

    // MARK: the stops, in his words

    /// One real stop: words of the hub's own message (`phrase`, which `test_connected_apps.GateWords` finds in
    /// `hubsetup.py` or `hub.py`), and his sentence for it with its control (the table "The real stops, and his
    /// sentence for each" of the pictures he approved, with his answer of 13 November 2026 about its words: "Yes,
    /// replace it"). No sentence that he reads names "the gate", which is a word of the code: it says "connected
    /// apps".
    struct Match {
        let phrase: String
        let stop: ConnectStop

        init(_ phrase: String, _ words: String, retries: Bool, keyAgain: Bool = false) {
            self.phrase = phrase
            self.stop = ConnectStop(words: words, retries: retries, keyAgain: keyAgain)
        }
    }

    static let rootWords = "Founderizer could not run the setup as root on your hub's server."
    static let busyPort = "Your hub's server already publishes another address on port 443. Founderizer does not change it."
    static let notPublished = "Tailscale does not let your hub's server publish the address yet."
    static let notRunning = "Connected apps did not keep running on your hub's server."

    /// In the order they are tried. A phrase can stand in more than one message of `hubsetup.py` (the vault's steps
    /// have "could not be put in place" too): only the messages of `connect on`, `connect off` and the hub's
    /// `capp_stopped` reach this list.
    static let matches: [Match] = [
        // cmd_connect: not root, or not root's own clone
        Match("run it as root on the hub's machine", rootWords, retries: false),
        Match("the connect gate is installed only from root's own clone", rootWords, retries: false),
        // hub_account: no user of the hub, or the hub runs as root
        Match("name the user the hub runs as with --hub-user", "Your hub's user is missing on its server.", retries: false),
        Match("the hub never runs as root", "Your hub's user is missing on its server.", retries: false),
        // tailnet_name: no full DNS name
        Match("Tailscale gives this machine no full DNS name",
              "MagicDNS is off on your private network. Turn it on in Tailscale's DNS page.", retries: true),
        // connect_conflicts: port 443 or Funnel holds another target
        Match("this machine's Tailscale already publishes", busyPort, retries: false),
        // gate.py not readable in root's clone
        Match("is not readable, so the connect gate cannot be installed",
              "This release's files are missing on your hub's server.", retries: false),
        // the user founderizer-connect with another group
        Match("is there with another group",
              "Your hub's server already has a user named founderizer-connect for something else.", retries: false),
        // connect_on's look at the machine's rights, before it changes anything, and a Funnel command that waits:
        // the private network does not give the hub's machine the funnel attribute or HTTPS certificates
        Match("does not give this machine the funnel attribute, so Tailscale Funnel cannot publish", notPublished,
              retries: true, keyAgain: true),
        Match("HTTPS certificates are off for the private network", notPublished, retries: true, keyAgain: true),
        Match("Tailscale did not turn Funnel on in", notPublished, retries: true, keyAgain: true),
        // a part could not be put in place (the user, the folder, the program, the service, the mark, Funnel): one
        // sentence for every part, and the part's name only in what the stop carries for a report (`said`)
        Match(" could not be put in place: ", "Setting up connected apps on your hub's server failed.", retries: true),
        // the gate is not running after its start
        Match("seconds after its start", notRunning, retries: false),
        // Funnel status does not show the gate alone: the policy lacks the funnel attribute
        Match("The Tailscale policy may not give this machine the funnel attribute", notPublished, retries: true,
              keyAgain: true),
        // the hub's own reason while the feature is on and does not work (`GET /ui/connect` `stopped`): capp_funnel_ok
        // and a gate that does not forward to the hub's socket
        Match("the hub cannot read the Tailscale serve status", "Your hub cannot read Tailscale's state.", retries: true),
        Match("Tailscale Funnel does not publish only the gate", busyPort, retries: false),
        // Funnel was turned off on the hub's machine: Try again runs the root step, which turns it on again
        Match("Tailscale Funnel publishes nothing on the hub's machine", notPublished, retries: true),
        // the root step starts the gate again, so this one has Try again (the hub's own message says so)
        Match("the gate of the connected apps does not forward to the hub's socket",
              notRunning, retries: true),
        // connect off
        Match("tailscale funnel --https=443 off` failed: ", "Tailscale did not stop publishing the address.", retries: true),
        Match(" could not be stopped: ", "Connected apps did not stop on your hub's server.", retries: true),
    ]

    /// What `sudo -n` prints when the SSH user may not become root with no password (sudo's own words, not the hub's).
    static let sudoRefusals = ["sudo: a password is required", "sudo: a terminal is required"]
    static let notRoot = ConnectStop(words: rootWords, retries: false)

    /// The app's SSH run to the hub's server did not answer, or could not start.
    public static let unreached = ConnectStop(words: "Founderizer could not reach your hub's server.", retries: true)

    /// A message that matches nothing: "Turning on stopped on your hub's server.", with Try again. For a Turn off the
    /// table has no such row, and its words are the same sentence for Turn off.
    static func other(_ turn: ConnectTurn) -> ConnectStop {
        ConnectStop(words: turn == .on ? "Turning on stopped on your hub's server."
                                       : "Turning off stopped on your hub's server.", retries: true)
    }

    /// The stop of a turn that a quit of the app cut off (`kept`): the sentence of a stop that matches nothing, with
    /// Try again, which runs every step again.
    public static func cutOff(_ turn: ConnectTurn) -> ConnectStop { other(turn) }

    /// **His sentence for one message of the hub**, by the first match whose words it holds. The hub's own words are
    /// in no row of the page: they go with the stop (`said`) for Report a problem, which shows them as its "Last
    /// error" fact, as the storage notice's report does.
    public static func stop(_ said: String, turn: ConnectTurn = .on) -> ConnectStop {
        for match in matches where said.contains(match.phrase) { return match.stop.saying(said) }
        return other(turn).saying(said)
    }

    // MARK: the steps

    #if os(macOS)
    /// **The steps after the token, by themselves** (Turn on), or the two steps of Turn off, each with its stand-in in
    /// the tests. `rootStep` runs `program(turn:)` as root on the hub's machine over the owner's SSH and gives what it
    /// printed; a throw, or the exit status 255 of `ssh`, is a run that did not reach the server. `setting` is
    /// `POST /ui/connect/settings`. `ready` says whether the hub serves `connected_apps` now, `closed` gives the hub's
    /// own reason while it is on and does not work (`ConnectState.stopped`), and `wait` waits for the hub's next
    /// change; no clock ends the wait. Only the Mac runs them (`LocalShell` is the Mac's).
    public struct Steps: Sendable {
        public var rootStep: @Sendable (ConnectTurn) async throws -> LocalShell.Answer
        public var setting: @Sendable (Bool) async throws -> Void
        public var ready: @Sendable () async -> Bool
        public var closed: @Sendable () async -> String?
        /// Whether the hub says that the feature is on (`GET /ui/connect`), or nil when it did not answer.
        public var isOn: @Sendable () async -> Bool?
        public var wait: @Sendable () async throws -> Void

        public init(rootStep: @escaping @Sendable (ConnectTurn) async throws -> LocalShell.Answer,
                    setting: @escaping @Sendable (Bool) async throws -> Void,
                    ready: @escaping @Sendable () async -> Bool,
                    closed: @escaping @Sendable () async -> String? = { nil },
                    isOn: @escaping @Sendable () async -> Bool? = { false },
                    wait: @escaping @Sendable () async throws -> Void) {
            self.rootStep = rootStep; self.setting = setting; self.ready = ready; self.closed = closed
            self.isOn = isOn; self.wait = wait
        }
    }

    /// What `ssh` says when this Mac does not know the server's host key: Try again cannot work.
    static let unknownHostKey = "Host key verification failed"

    /// The root step and what it came to.
    static func root(_ turn: ConnectTurn, _ steps: Steps) async -> ConnectStop? {
        let answer: LocalShell.Answer
        do { answer = try await steps.rootStep(turn) } catch {
            return unreached.saying((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        switch outcome(answer.output, turn: turn) {
        case .done: return nil
        case .stopped(let stop):
            // ssh's own status for a connection that it could not make, before any line of the step. A host key
            // that this Mac does not know is no matter of a second try.
            guard answer.status == 255, !answer.output.contains("{") else { return stop }
            if answer.output.contains(unknownHostKey) {
                return ConnectStop(words: unreached.words, retries: false).saying(unknownHostKey)
            }
            return unreached.saying(answer.lines.last ?? "")
        }
    }

    /// The hub's write, and its refusal in the same sentence as a stop that matches nothing.
    static func set(_ on: Bool, _ steps: Steps) async -> ConnectStop? {
        do { try await steps.setting(on); return nil } catch {
            return other(on ? .on : .off).saying(HubError.said(error) ?? error.localizedDescription)
        }
    }

    /// **Turn on, after the token**: the root step, the hub's setting, then the wait until the hub serves
    /// `connected_apps`. nil: on. A setting that failed is read from the hub before anything follows: a hub that is on
    /// took the write and only its answer was lost, so the wait goes on; a hub that is off refused it, so the root
    /// step is taken back (`connect off`) and nothing stays published; a hub that does not answer leaves everything as
    /// it is, and Try again finds out. The wait ends when the hub serves the feature, or says why it cannot (`closed`:
    /// his sentence for that reason), asked after each round of the wait and never before the first: the hub looks at
    /// its socket for some seconds after the write. A wait that is cut off (its task ended) is no stop: the hub's own
    /// answers show the wait again (`show`).
    public static func turnOn(_ steps: Steps) async -> ConnectStop? {
        if let stop = await root(.on, steps) { return stop }
        if let stop = await set(true, steps) {
            switch await steps.isOn() {
            case true?: break
            case false?:
                _ = await root(.off, steps)
                return stop
            case nil: return stop
            }
        }
        while await !steps.ready() {
            do { try await steps.wait() } catch { return nil }
            if await steps.ready() { break }
            if let why = await steps.closed() { return stop(why, turn: .on) }
        }
        return nil
    }

    /// **Turn off**: the hub's setting first (every connection ends, the socket closes), then the root step `connect
    /// off`. nil: off.
    public static func turnOff(_ steps: Steps) async -> ConnectStop? {
        if let stop = await set(false, steps) { return stop }
        return await root(.off, steps)
    }
    #endif

    // MARK: what the group shows

    /// What the store's run does now.
    public enum Run: Equatable, Sendable {
        case idle
        /// His Tailscale key page is open.
        case keyPage
        case turningOn
        case turningOff
        case stopped(ConnectStop, ConnectTurn)
    }

    /// What the group "Connect an app" shows while the hub does not serve `connected_apps` (the pictures 2a, 2c, 2d).
    public enum Show: Equatable, Sendable {
        /// No group.
        case nothing
        /// The empty card, and Turn on on its heading while `turnOn` (2a).
        case off(turnOn: Bool)
        /// "Turning on…" on the heading (2c).
        case turningOn
        /// The failure row in the card (2d, 2d-b): "Connected apps did not turn on", or "did not turn off".
        case stopped(ConnectStop, ConnectTurn)
    }

    /// **Worked out from the hub's answers and the store's run**, so that a quit or a sleep loses nothing: a hub that
    /// says on while it does not serve `connected_apps` yet is the wait, whatever this launch did. Only on a hub that
    /// names `connect_offer`; never while it serves `connected_apps` (the two approved groups show then, with Turn off).
    /// `canAct`: the hub takes a write now. The empty card with Turn on shows only while no step runs, the hub says it
    /// can be turned on, and it takes a write; a key page that he left by another way than Back keeps it. During the
    /// root step of a Turn off no group shows: no picture has that moment. A hub that is on and says why it does not
    /// work (`ConnectState.stopped`) is the failure row with his sentence for that reason, so that the wait has an end.
    public static func show(features: [String]?, state: ConnectState?, run: Run, canAct: Bool) -> Show {
        let features = features ?? []
        guard features.contains(ConnectedApps.offer), !features.contains(ConnectedApps.feature) else { return .nothing }
        switch run {
        case .stopped(let stop, let turn): return .stopped(stop, turn)
        case .turningOff: return .nothing
        case .turningOn: return .turningOn
        case .idle, .keyPage:
            guard let state else { return .nothing }
            if state.on {
                if let why = state.stopped, !why.isEmpty { return .stopped(stop(why, turn: .on), .on) }
                return .turningOn
            }
            return state.canTurnOn && canAct ? .off(turnOn: true) : .nothing
        }
    }

    // MARK: a turn that a quit cut off

    /// **The turn that runs now is kept for each hub in this Mac's settings**, and taken away when it ends, well or
    /// with a stop that the page shows. A turn that is still there at the next launch was cut off by a quit: the page
    /// then shows the row of a stop with Try again, and every step of it skips what is done. It is no secret: the
    /// hub's host and port, and the word "on" or "off".
    public static func keptKey(_ hub: URL) -> String {
        "connectTurn." + (hub.host ?? "") + (hub.port.map { ":\($0)" } ?? "")
    }

    public static func kept(_ hub: URL, in defaults: UserDefaults = .standard) -> ConnectTurn? {
        defaults.string(forKey: keptKey(hub)).flatMap(ConnectTurn.init(rawValue:))
    }

    public static func keep(_ turn: ConnectTurn?, for hub: URL, in defaults: UserDefaults = .standard) {
        if let turn { defaults.set(turn.rawValue, forKey: keptKey(hub)) } else { defaults.removeObject(forKey: keptKey(hub)) }
    }

    /// The steps of a Turn on are done when the hub serves `connected_apps`, or when it names neither feature (another
    /// way turned them off, or a release without them): then nothing is left to wait for.
    public static func ready(features: [String]?) -> Bool {
        let features = features ?? []
        return features.contains(ConnectedApps.feature) || !features.contains(ConnectedApps.offer)
    }
}
