import Foundation

/// **The door's parts on a business's servers** (new-projects plan N8 (b), DevOps plan 4.8 and 4.9, API 1.100): this
/// Mac puts them in place over its own root SSH, one server each round, with nothing on the owner's screen. The first
/// server is the canary; the others wait for the manager's `door_rollout`. Everything comes from the door: `host/` of
/// the release that the door runs and checked, the release keys that it pinned and its public SSH key. Nothing comes
/// from the hub. Once the door's file holds a server, the door checks the server's second sshd itself (test 1, as code).
public enum DoorHosts {
    /// The releases that `install.sh` covers.
    public static let covered = ["ubuntu:24.04", "ubuntu:26.04"]
    /// A business's CI runners come first: they hold no app.
    public static let ciTag = "tag:ci-runner"
    /// What a server says of its own release.
    public static let releaseProgram = ". /etc/os-release; echo \"release=${ID:-?}:${VERSION_ID:-?}\""
    /// The revision that the door runs: a stop holds until it, or the app, changes.
    public static let revisionProgram = "basename \"$(readlink -f /opt/fleet-door/current)\""
    /// What the door gives for one install, as root: its public SSH key, the revision that it runs, and, in base64, a
    /// tar of `host/`'s install files and the release keys that it pinned at its own install.
    public static let bundleProgram = "set -e; d=$(mktemp -d); trap 'rm -rf \"$d\"' EXIT; c=/opt/fleet-door/current; "
        + "for f in install.sh ops-root ops-read inventory app-release; do cp \"$c/host/$f\" \"$d/\"; done; "
        + "cp /etc/fleet-door/release-key.pub \"$d/\"; "
        + "if [ -f /etc/fleet-door/early-key.pub ]; then cp /etc/fleet-door/early-key.pub \"$d/\"; fi; "
        + "echo \"door-key=$(cat /var/lib/fleet-door/ssh/id_ed25519.pub)\"; "
        + "echo \"revision=$(basename \"$(readlink -f \"$c\")\")\"; "
        + "echo \"bundle=$(tar -C \"$d\" -cf - . | base64 -w0)\""

    /// What the door gave for one install.
    public struct Bundle: Equatable, Sendable {
        public let doorKey: String
        public let revision: String
        /// The tar of the install files, in base64, which goes to the server on its standard input.
        public let tar: String

        public init?(output: String) {
            var found: [String: String] = [:]
            for line in output.split(whereSeparator: \.isNewline) {
                guard let equals = line.firstIndex(of: "=") else { continue }
                found[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
            guard let key = found["door-key"], DoorHosts.isDoorKey(key),
                  let revision = found["revision"], revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
                  let tar = found["bundle"], !tar.isEmpty, tar.count <= 8_000_000,
                  tar.range(of: "^[A-Za-z0-9+/]+=*$", options: .regularExpression) != nil else { return nil }
            doorKey = key; self.revision = revision; self.tar = tar
        }
    }

    /// The door's public key, as `install.sh --door-key` takes it.
    public static func isDoorKey(_ text: String) -> Bool {
        text.range(of: "^ssh-ed25519 [A-Za-z0-9+/=]{60,100}( [A-Za-z0-9@._-]{1,64})?$", options: .regularExpression) != nil
    }

    /// The install on one server, as root, with the bundle on its standard input: a folder that only root reaches,
    /// `install.sh` at Fix, and the folder goes. Its last line is the second sshd's host key. nil for a mode or a key
    /// that is not one.
    /// `fleet`: a machine of the fleet, which gets its mark (`install.sh --fleet`) and only ever rule-only.
    public static func installProgram(mode: String, doorKey: String, fleet: Bool = false) -> String? {
        guard ["fix", "rule-only"].contains(mode), isDoorKey(doorKey), !fleet || mode == "rule-only" else { return nil }
        return "set -eu; d=$(mktemp -d /root/.door-parts.XXXXXX); trap 'rm -rf \"$d\"' EXIT; "
            + "base64 -d | tar -xf - -C \"$d\" --no-same-owner; "
            + "bash \"$d/install.sh\" --level fix --mode \(mode)\(fleet ? " --fleet" : "") --door-key '\(doorKey)'"
    }

    /// **Why the door's install on a server stopped, in fixed words only** (19 November 2026): the reason of the hub's
    /// `failed` word, which the hub quotes in the manager's [hub] line. The server runs the install as root and prints
    /// all of its output, so a server that an attacker holds writes every line of it. Until that day the last line went
    /// to the manager as it was; now no line of it goes. A stop line of `install.sh` (`installStops`, with status 1) or
    /// of this Mac's `ssh` (`sshStops`, with status 255) gives the words of its kind, and any other output the general
    /// words (`installOther`). Such a server can still choose which of these words the manager reads, never their text.
    /// `status` is nil when SSH did not run; `timedOut`: the call took the whole wait (`probeWait`, the one timeout of
    /// `DoorSync.ssh`; ssh ends with 255 at `LocalShell`'s SIGTERM, so the time says it). The reason ends with a full
    /// stop, because the hub's line goes on after it.
    public static func installStop(status: Int32?, output: String, timedOut: Bool) -> String {
        let cause: String
        if timedOut {
            cause = "the owner's Mac ended it after \(Int(probeWait)) s"
        } else if let status {
            let last = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? ""
            let stops = status == 1 ? installStops : status == 255 ? sshStops : []
            cause = stops.first { last.range(of: $0.line, options: .regularExpression) != nil }?.said ?? installOther
        } else {
            cause = "the owner's Mac's SSH to the server did not run"
        }
        return "the install stopped: \(cause)."
    }

    /// The stop lines of `install.sh`, as whole lines: each `die` prints "install.sh: <words>" and ends with status 1.
    /// One pattern on each line, of the regular expressions that Python reads too: `test_host_parts` holds each `die`
    /// of install.sh to one of them.
    static let installStops: [(line: String, said: String)] = [
        (#"^install\.sh: (unknown option .*|--[a-z-]+ .*)$"#,
         "the door's install script refused the options that the owner's Mac gave it"),
        (#"^install\.sh: run it as root$"#, "it did not run as root"),
        (#"^install\.sh: .* is not a release that the door's tests covered \(.*\)$"#,
         "the server runs a release that the door's install does not cover"),
        (#"^install\.sh: a machine of the fleet takes --level fix --mode rule-only and no other: --remove takes its mark away$"#,
         "the server has the mark of a machine of the fleet, which takes the mode rule-only and no other"),
        (#"^install\.sh: \S+ is not beside this script$"#, "a file of the door's parts was not in the door's bundle"),
        (#"^install\.sh: Tailscale gives this host no address: the second sshd listens there$"#,
         "Tailscale gives the server no address for the second sshd"),
        (#"^install\.sh: port [0-9]+ is in use on this host$"#, "another program uses the second sshd's port on the server"),
        (#"^install\.sh: the second sshd did not start: journalctl -u ops-sshd$"#,
         "the second sshd did not start on the server"),
    ]

    /// The last lines of this Mac's own `ssh` when it did not run the install to its end (status 255), as whole lines.
    /// A line of the server's own text ("Received disconnect from" and its words, a banner) is none of these.
    static let sshStops: [(line: String, said: String)] = [
        (#"^ssh: connect to host \S+ port [0-9]+: .*$"#, "the owner's Mac could not connect to the server over SSH"),
        (#"^Host key verification failed\.$"#, "the server's host key is not the one that the owner's Mac knows"),
        (#"^\S+@\S+: Permission denied \(.*\)\.$"#, "the server refused the owner's Mac's SSH login"),
        (#"^(kex_exchange_identification: .*|Connection timed out during banner exchange)$"#, sshClosed),
        (#"^Connection (closed|reset) by \S+ port [0-9]+$"#, sshClosed),
        (#"^(Connection to \S+ closed by remote host\.|Timeout, server \S+ not responding\.)$"#, sshClosed),
        (#"^client_loop: send disconnect: .*$"#, sshClosed),
    ]
    static let sshClosed = "the SSH connection to the server closed before the install ended"

    /// The words of every other output.
    static let installOther = "its output has no stop line that the owner's Mac knows"

    /// The door's own check of one server's second sshd (`door.py probe`, test 1 as code), as the door's user, whose
    /// key it uses. `first` (API 1.241), only for a door whose code takes it (`DoorAccess.firstProbe`): the check stops
    /// at a first connection that fails, and says why in fixed words, in about 15 s in place of more than 120 s.
    public static func probeProgram(host: String, first: Bool = false) -> String? {
        guard DoorAccess.isName(host) else { return nil }
        return "runuser -u door -- /usr/bin/python3 -I /opt/fleet-door/current/door.py probe \(host)" + (first ? " --first" : "")
    }

    /// What the door's check said: whether it passed, the names of the checks that failed, and (API 1.241) why it
    /// stopped at its first connection, in the door's fixed words (`door.FIRST_CAUSES`), which the hub quotes to the
    /// manager. Text of another form is never passed on: a host chooses some of ssh's own words.
    public struct Check: Equatable, Sendable {
        public let passed: Bool
        public let failed: [String]
        public let stopped: String?

        public init(passed: Bool, failed: [String], stopped: String? = nil) {
            self.passed = passed; self.failed = failed; self.stopped = stopped
        }
    }

    /// The form of the door's causes: lower-case words, digits and a few signs, as `door.FIRST_LINES` writes them
    /// (`test_door` holds each of them to this pattern). A second guard only: the door writes its causes itself, from a
    /// fixed list, and a lower-case sentence of another kind would pass this pattern.
    static let causeWords = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9 ,.'-]{0,118}$")

    /// The `Check` of `probeProgram`'s JSON line, or nil when it printed none.
    public static func probe(_ output: String, host: String) -> Check? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["host"] as? String == host, let passed = object["passed"] as? Bool,
                  let checks = object["checks"] as? [[Any]] else { continue }
            let failed = checks.compactMap { check -> String? in
                guard check.count == 3, let name = check[0] as? String, let ok = check[1] as? Bool else { return "?" }
                return ok ? nil : name
            }
            var stopped: String?
            if ["connect", "login"].contains(object["stopped"] as? String) {
                let cause = object["cause"] as? String ?? ""
                let fixed = causeWords.firstMatch(in: cause, range: NSRange(cause.startIndex..., in: cause)) != nil
                stopped = fixed ? cause : "the door's check stopped at its first connection"
            }
            return Check(passed: passed && failed.isEmpty && stopped == nil, failed: failed, stopped: stopped)
        }
        return nil
    }

    /// The seconds that the owner's Mac waits for the door's check: the `timeout` of `DoorSync.ssh` (`LocalShell`'s
    /// limit), which must stay the same number.
    public static let probeWait: TimeInterval = 120

    /// The fixed words of a check that made no step (API 1.241), which the hub quotes to the manager: the door's own
    /// cause; else the Mac's: the call took the whole wait (ssh ends with 255 at `LocalShell`'s SIGTERM, so the time
    /// says it, not the status), no answer at all, ssh's own failure (255) with no line of the check's, or an answer
    /// with no line of the check's.
    public static func noStepCause(_ check: Check?, status: Int32?, timedOut: Bool) -> String {
        if let stopped = check?.stopped { return stopped }
        if timedOut { return "the door's check gave no answer in \(Int(probeWait)) s" }
        switch status {
        case nil: return "the owner's Mac got no answer from the door over SSH"
        case 255?: return "the owner's Mac's SSH to the door failed"
        default: return "the door's check printed no answer"
        }
    }

    /// The fixed words of an installed server that the door's file does not hold (API 1.241): its second sshd gave no
    /// key (`bare`), its root SSH gave no answer (no reading this round), or it gave its key and the door did not take
    /// the new file.
    public static func waitCause(host: String, bare: Set<String>, answered: Set<String>) -> String {
        if bare.contains(host) { return "its second sshd gave the owner's Mac no key" }
        if !answered.contains(host) { return "the owner's Mac got no answer from it over SSH as root" }
        return "the door's file does not hold it yet: the door did not take the new file"
    }

    /// The rounds in a row that the first installed server may make no step before the hub hears it (API 1.241): the
    /// round after an install waits for the door's file by design, and a server that reboots gets a second one.
    public static let quietRounds = 2

    /// One more round in which `host`, the first installed server of the order, made no step, for `cause` (fixed
    /// words). Gives the cause to report as `unchecked`: from the third round in a row, each cause once until the server
    /// makes a step, so that a cause that comes and goes gives the manager one line each, not one each round. The
    /// caller marks it with `reported` once the hub took it.
    public static func noStep(host: String, cause: String, state: inout State) -> String? {
        var waiting = state.waiting?.host == host ? state.waiting! : State.Waiting(host: host, rounds: 0, cause: cause)
        waiting.rounds += 1
        waiting.cause = cause
        state.waiting = waiting
        return waiting.rounds > quietRounds && !waiting.told.contains(cause) ? cause : nil
    }

    /// The hub took `cause` as `host`'s `unchecked` word.
    public static func reported(_ cause: String, host: String, state: inout State) {
        guard state.waiting?.host == host, state.waiting?.told.contains(cause) == false else { return }
        state.waiting?.told.append(cause)
    }

    /// `host`'s check answered: it passed, or it reached the server and a check failed. Its count ends.
    public static func stepped(host: String, state: inout State) {
        if state.waiting?.host == host { state.waiting = nil }
    }

    /// The `id:version` of `releaseProgram`'s output, or nil.
    public static func release(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            line.hasPrefix("release=") ? String(line.dropFirst("release=".count)) : nil
        }.first
    }

    /// The servers that get the door's parts, in their order: by business, a business's CI runners first, then by name;
    /// after every business's server, the fleet's own servers (`DoorAccess.fleetServers`, the hub's server last).
    /// The door, a server on the `never` list (`DoorAccess.servers`), a machine of the fleet that carries a business
    /// tag and a server that the manager's `door_hold` holds at `parts` are not in it.
    public static func order(access: [String: Any], devices: [DoorAccess.Device], fleet: Set<String>,
                             heldOut: Set<String> = [], fleetServers: [String] = []) -> [String] {
        let tags = Dictionary(devices.map { ($0.name, $0.tags) }, uniquingKeysWith: { first, _ in first })
        let found = DoorAccess.servers(access: access, devices: devices)
            .filter { !fleet.contains($0.key) && !heldOut.contains($0.key) }
        func rank(_ name: String) -> (String, Int, String) {
            ((found[name] ?? []).sorted().first ?? "", (tags[name] ?? []).contains(ciTag) ? 0 : 1, name)
        }
        return found.keys.sorted { rank($0) < rank($1) } + fleetServers.filter { found[$0] == nil && !heldOut.contains($0) }
    }

    /// What this Mac did with each server, for one hub and database: `installed` (it waits for the door's file and its
    /// check) or `passed`, and the one stop, with the app's build and the door's revision that it holds for.
    public struct State: Codable, Equatable, Sendable {
        public struct Stop: Codable, Equatable, Sendable {
            public var host: String
            public var reason: String
            public var app: String
            public var door: String

            public init(host: String, reason: String, app: String, door: String) {
                self.host = host; self.reason = reason; self.app = app; self.door = door
            }
        }
        /// The first installed server whose rounds make no step (API 1.241): its rounds in a row, its newest cause and
        /// the causes that the hub took as its `unchecked` word. A field added later must be optional, or a stored
        /// state without it fails to decode as a whole.
        public struct Waiting: Codable, Equatable, Sendable {
            public var host: String
            public var rounds: Int
            public var cause: String
            public var told: [String] = []

            public init(host: String, rounds: Int, cause: String, told: [String] = []) {
                self.host = host; self.rounds = rounds; self.cause = cause; self.told = told
            }
        }
        public var hosts: [String: String] = [:]
        public var stop: Stop? = nil
        /// Optional, so that a state stored before API 1.241 decodes as it was, with its hosts and its stop.
        public var waiting: Waiting? = nil

        public init() {}

        /// The end of a stop, at a new build of the app or a new release of the door (API 1.241): its server goes back to
        /// its check when the door's file holds it (`holds`: the set that `next` gets), so that a check that failed runs
        /// again, and else to its install, as before.
        public mutating func clearStop(holds: Set<String>) {
            guard let stop else { return }
            hosts[stop.host] = holds.contains(stop.host) ? "installed" : nil
            self.stop = nil
        }

        static func key(hub: URL, database: String) -> String { "doorHosts|\(hub.absoluteString)|\(database)" }

        public static func read(hub: URL, database: String, in defaults: UserDefaults = AppDefaults.store) -> State {
            defaults.data(forKey: key(hub: hub, database: database)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
                ?? State()
        }

        public func save(hub: URL, database: String, in defaults: UserDefaults = AppDefaults.store) {
            defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(hub: hub, database: database))
        }
    }

    /// The one step of a round.
    public enum Step: Equatable, Sendable {
        case probe(String)
        case install(String)
        case wait
    }

    /// The next step: the door's check of a server that this Mac gave the parts and that the door's file holds now;
    /// else the first server with no parts while none passed (the canary, which is waited for while it does not
    /// answer); else, after the manager's `door_rollout`, the next one with no parts, past those that do not answer.
    /// `inFile`: the servers of the door's file. `answered`: the servers whose second sshd gave its key this round.
    /// `skipped`: the servers that did not answer this Mac's SSH, or run a release that the install does not cover.
    public static func next(order: [String], state: State, inFile: Set<String>, answered: Set<String>, rollout: Bool,
                            skipped: Set<String>) -> Step {
        if let host = order.first(where: { state.hosts[$0] == "installed" }) {
            return inFile.contains(host) ? .probe(host) : .wait
        }
        let open = order.filter { state.hosts[$0] == nil && !inFile.contains($0) && !answered.contains($0) }
        guard order.contains(where: { state.hosts[$0] == "passed" }) else {
            guard let canary = open.first, !skipped.contains(canary) else { return .wait }
            return .install(canary)
        }
        guard rollout, let host = open.first(where: { !skipped.contains($0) }) else { return .wait }
        return .install(host)
    }
}
