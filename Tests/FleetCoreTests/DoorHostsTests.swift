import Foundation
import Testing
@testable import FleetCore

/// New-projects plan N8 (b), DevOps plan 4.8 and 4.9 (API 1.100): this Mac puts the door's parts on a business's
/// servers over its own root SSH, the canary first and the others after the manager's door_rollout, one each round,
/// with everything from the door and nothing from the hub, and the door then checks each server's second sshd itself.
struct DoorHostsTests {
    static let key = "ssh-ed25519 " + String(repeating: "A", count: 68) + " door"

    static func device(_ name: String, _ tags: [String]) -> DoorAccess.Device {
        DoorAccess.Device(name: name, address: "100.64.9.\(abs(name.hashValue) % 200)", tags: tags)
    }

    static let devices = [
        device("app-b", ["tag:business-one", "tag:hetzner-server"]),
        device("app-a", ["tag:business-one", "tag:hetzner-server"]),
        device("ci-2", ["tag:business-one", "tag:ci-runner"]),
        device("ci-1", ["tag:business-one", "tag:ci-runner"]),
        device("two-z", ["tag:business-two", "tag:hetzner-server"]),
        device("two-a", ["tag:business-two"]),
        device("worker-1", ["tag:business-one", "tag:claude-code-dev"]),
        device("the-door", ["tag:door"]),
        device("gone", ["tag:business-one"]),
        device("plain", ["tag:hetzner-server"])]

    @Test func theOrderIsByBusinessCIRunnersFirstThenByName() {
        let access: [String: Any] = ["never": ["hosts": ["gone"]]]
        #expect(DoorHosts.order(access: access, devices: Self.devices, fleet: ["worker-1"])
                == ["ci-1", "ci-2", "app-a", "app-b", "two-a", "two-z"])
        // a server that the manager's door_hold holds at parts gets none (API 1.101)
        #expect(DoorHosts.order(access: access, devices: Self.devices, fleet: ["worker-1"], heldOut: ["app-a"])
                == ["ci-1", "ci-2", "app-b", "two-a", "two-z"])
    }

    @Test func theCanaryComesFirstAndTheOthersWaitForTheManager() {
        let order = ["ci-1", "ci-2", "app-a"]
        var state = DoorHosts.State()
        #expect(DoorHosts.next(order: order, state: state, inFile: [], answered: [], rollout: false, skipped: [])
                == .install("ci-1"))
        // a canary that does not answer is waited for, never passed over
        #expect(DoorHosts.next(order: order, state: state, inFile: [], answered: [], rollout: true, skipped: ["ci-1"])
                == .wait)
        state.hosts["ci-1"] = "installed"
        #expect(DoorHosts.next(order: order, state: state, inFile: [], answered: ["ci-1"], rollout: true, skipped: [])
                == .wait)                                      // its key is read, and the door's file is written next
        #expect(DoorHosts.next(order: order, state: state, inFile: ["ci-1"], answered: ["ci-1"], rollout: false,
                               skipped: []) == .probe("ci-1"))
        state.hosts["ci-1"] = "passed"
        #expect(DoorHosts.next(order: order, state: state, inFile: ["ci-1"], answered: ["ci-1"], rollout: false,
                               skipped: []) == .wait)          // test 6 and door_rollout come first
        #expect(DoorHosts.next(order: order, state: state, inFile: ["ci-1"], answered: ["ci-1"], rollout: true,
                               skipped: []) == .install("ci-2"))
        #expect(DoorHosts.next(order: order, state: state, inFile: ["ci-1"], answered: ["ci-1"], rollout: true,
                               skipped: ["ci-2"]) == .install("app-a"))
        // a server that has parts of its own, or that the door's file holds already, gets nothing from this Mac
        #expect(DoorHosts.next(order: order, state: state, inFile: ["ci-1", "ci-2"], answered: ["ci-1", "app-a"],
                               rollout: true, skipped: []) == .wait)
    }

    @Test func theStateIsKeptForEachHubAndDatabase() throws {
        let defaults = try #require(UserDefaults(suiteName: "door-hosts-\(UUID().uuidString)"))
        let hub = URL(string: "http://100.64.0.2:8765")!
        var state = DoorHosts.State()
        state.hosts["ci-1"] = "passed"
        state.stop = .init(host: "ci-2", reason: "the install stopped", app: "142", door: String(repeating: "a", count: 40))
        state.save(hub: hub, database: "g1", in: defaults)
        #expect(DoorHosts.State.read(hub: hub, database: "g1", in: defaults) == state)
        #expect(DoorHosts.State.read(hub: hub, database: "g2", in: defaults) == DoorHosts.State())
    }

    @Test func theBundleIsTheDoorsKeyItsRevisionAndATar() {
        let revision = String(repeating: "c", count: 40)
        let bundle = DoorHosts.Bundle(output: "door-key=\(Self.key)\nrevision=\(revision)\nbundle=aGVsbG8=\n")
        #expect(bundle?.doorKey == Self.key && bundle?.revision == revision && bundle?.tar == "aGVsbG8=")
        #expect(DoorHosts.Bundle(output: "door-key=ssh-rsa AAAA\nrevision=\(revision)\nbundle=aGVsbG8=") == nil)
        #expect(DoorHosts.Bundle(output: "door-key=\(Self.key)\nrevision=main\nbundle=aGVsbG8=") == nil)
        #expect(DoorHosts.Bundle(output: "door-key=\(Self.key)\nrevision=\(revision)\nbundle=$(id)") == nil)
        #expect(DoorHosts.Bundle(output: "door-key=\(Self.key)\nrevision=\(revision)") == nil)
    }

    @Test func theInstallRunsAtFixFromARootFolderAndTakesOnlyItsOwnKinds() throws {
        let program = try #require(DoorHosts.installProgram(mode: "fix", doorKey: Self.key))
        #expect(program.contains("mktemp -d /root/.door-parts.XXXXXX") && program.contains("trap 'rm -rf"))
        #expect(program.hasSuffix("bash \"$d/install.sh\" --level fix --mode fix --door-key '\(Self.key)'"))
        #expect(DoorHosts.installProgram(mode: "rule-only", doorKey: Self.key) != nil)
        #expect(DoorHosts.installProgram(mode: "read", doorKey: Self.key) == nil)
        #expect(DoorHosts.installProgram(mode: "fix", doorKey: Self.key + "'; reboot; '") == nil)
        #expect(DoorHosts.probeProgram(host: "ci-1")
                == "runuser -u door -- /usr/bin/python3 -I /opt/fleet-door/current/door.py probe ci-1")
        #expect(DoorHosts.probeProgram(host: "ci-1; reboot") == nil)
    }

    @Test func theDoorsCheckAndTheReleaseAreReadFromTheirOwnLines() {
        let passed = #"{"host": "ci-1", "passed": true, "checks": [["no TTY", true, ""], ["no scp", true, ""]]}"#
        #expect(DoorHosts.probe(passed, host: "ci-1")?.passed == true)
        let failed = #"{"host": "ci-1", "passed": false, "checks": [["no TTY", false, "0: up"], ["no scp", true, ""]]}"#
        #expect(DoorHosts.probe("noise\n" + failed, host: "ci-1").map { [$0.passed ? "y" : "n"] + $0.failed }
                == ["n", "no TTY"])
        #expect(DoorHosts.probe(passed, host: "ci-2") == nil && DoorHosts.probe("ci-1 is no host", host: "ci-1") == nil)
        #expect(DoorHosts.release("release=ubuntu:24.04\n") == "ubuntu:24.04")
        #expect(DoorHosts.release("Permission denied") == nil)
        #expect(DoorHosts.covered.contains("ubuntu:26.04") && !DoorHosts.covered.contains("ubuntu:22.04"))
    }
}
