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
    public static func installProgram(mode: String, doorKey: String) -> String? {
        guard ["fix", "rule-only"].contains(mode), isDoorKey(doorKey) else { return nil }
        return "set -eu; d=$(mktemp -d /root/.door-parts.XXXXXX); trap 'rm -rf \"$d\"' EXIT; "
            + "base64 -d | tar -xf - -C \"$d\" --no-same-owner; "
            + "bash \"$d/install.sh\" --level fix --mode \(mode) --door-key '\(doorKey)'"
    }

    /// The door's own check of one server's second sshd (`door.py probe`, test 1 as code), as the door's user, whose
    /// key it uses.
    public static func probeProgram(host: String) -> String? {
        guard DoorAccess.isName(host) else { return nil }
        return "runuser -u door -- /usr/bin/python3 -I /opt/fleet-door/current/door.py probe \(host)"
    }

    /// (passed, the names of the checks that failed) of `probeProgram`'s JSON line, or nil when it printed none.
    public static func probe(_ output: String, host: String) -> (passed: Bool, failed: [String])? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["host"] as? String == host, let passed = object["passed"] as? Bool,
                  let checks = object["checks"] as? [[Any]] else { continue }
            let failed = checks.compactMap { check -> String? in
                guard check.count == 3, let name = check[0] as? String, let ok = check[1] as? Bool else { return "?" }
                return ok ? nil : name
            }
            return (passed && failed.isEmpty, failed)
        }
        return nil
    }

    /// The `id:version` of `releaseProgram`'s output, or nil.
    public static func release(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            line.hasPrefix("release=") ? String(line.dropFirst("release=".count)) : nil
        }.first
    }

    /// The servers that get the door's parts, in their order: by business, a business's CI runners first, then by name.
    /// The door, a server on the `never` list (`DoorAccess.servers`), a machine of the fleet and a server that the
    /// manager's `door_hold` holds at `parts` are not in it.
    public static func order(access: [String: Any], devices: [DoorAccess.Device], fleet: Set<String>,
                             heldOut: Set<String> = []) -> [String] {
        let tags = Dictionary(devices.map { ($0.name, $0.tags) }, uniquingKeysWith: { first, _ in first })
        let found = DoorAccess.servers(access: access, devices: devices)
            .filter { !fleet.contains($0.key) && !heldOut.contains($0.key) }
        func rank(_ name: String) -> (String, Int, String) {
            ((found[name] ?? []).sorted().first ?? "", (tags[name] ?? []).contains(ciTag) ? 0 : 1, name)
        }
        return found.keys.sorted { rank($0) < rank($1) }
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
        public var hosts: [String: String] = [:]
        public var stop: Stop? = nil

        public init() {}

        static func key(hub: URL, database: String) -> String { "doorHosts|\(hub.absoluteString)|\(database)" }

        public static func read(hub: URL, database: String, in defaults: UserDefaults = .standard) -> State {
            defaults.data(forKey: key(hub: hub, database: database)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
                ?? State()
        }

        public func save(hub: URL, database: String, in defaults: UserDefaults = .standard) {
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
