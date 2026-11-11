import Foundation
import Testing
@testable import FleetCore

/// The app installs a Linux machine of a fleet over the owner's own SSH connection (PRODUCT.md P3). The whole path
/// is proved here against a stand-in `ssh`: every command the app sends, every line it keeps, and the two things
/// that must never be written down — the Tailscale auth key and the one-time join code.
struct MachineInstallTests {
    /// A stand-in `ssh`: it records each remote program and its standard input, and answers as a machine would.
    private final class StandInSSH {
        let folder: URL
        var path: String { folder.appendingPathComponent("ssh").path }

        init(_ answers: String) throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fleet-install-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            dir="$(dirname "$0")"
            program=""; destination=""
            for a in "$@"; do destination="$program"; program="$a"; printf '%s\\n' "$a" >> "$dir/argv"; done
            printf '%s\\n' "$program" >> "$dir/programs"
            printf '%s\\n' "$destination" >> "$dir/destinations"
            n=$(cat "$dir/count" 2>/dev/null || echo 0)
            n=$((n + 1))
            printf '%s\\n' "$n" > "$dir/count"
            cat > "$dir/stdin-$n"
            \(answers)
            """
            try script.write(to: folder.appendingPathComponent("ssh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                 ofItemAtPath: folder.appendingPathComponent("ssh").path)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        private func read(_ name: String) -> String {
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        var programs: [String] { read("programs").split(separator: "\n").map(String.init) }
        /// The `user@host` of each connection, in order.
        var destinations: [String] { read("destinations").split(separator: "\n").map(String.init) }
        var arguments: String { read("argv") }
        var inputs: String { (1...12).map { read("stdin-\($0)") }.joined() }
    }

    private static let checklist = """
    [{"check": "tailnet", "state": "ok", "says": "100.90.1.2, as team.json gives it", "fix": null},
     {"check": "services", "state": "ok", "says": "fleet-writer is active", "fix": null},
     {"check": "runtime_signed_in", "state": "fail", "says": "claude is not signed in",
      "fix": "Machines, this machine, Sign in."}]
    """

    /// What the check of a server (`ServerCheck.script`) prints on a server that can take the install. The check reads
    /// its script on standard input, so its program is `/bin/sh -s`.
    static let ready = ["user=root", "uid=0", "sudo=root", "os_id=ubuntu", "os_version=24.04", "os_name=Ubuntu",
                        "arch=x86_64", "memory_mb=3911", "disk_free_mb=70000", "systemd=yes", "ipv4_route=yes",
                        "reach=github.com yes", "reach=tailscale.com yes", "reach=claude.ai yes", "reach=chatgpt.com yes",
                        "cloud_init=done", "dpkg_lock=no", "listen=tcp/22/sshd", "listen=tcp/443/caddy", "ufw=inactive",
                        "tailscale=none", "end=yes"]

    /// The stand-in's answer to the check: `ready`, with `changes` in place of the keys they name.
    static func checked(_ changes: [String] = []) -> String {
        let keys = Set(changes.map { $0.split(separator: "=").first.map(String.init) ?? $0 })
        let lines = ready.filter { line in !keys.contains(line.split(separator: "=").first.map(String.init) ?? "") } + changes
        return "*\"/bin/sh -s\"*) printf '%s\\n' " + lines.map { "'\($0)'" }.joined(separator: " ") + " ;;"
    }

    private static let ubuntu = checked()

    private func join(_ standIn: StandInSSH, key: String = "tskey-auth-kNMMmP9-secret",
                      code: String = "7KMQ2PRJ4TVW") async throws -> (VerifyChecklist, [InstallProgress]) {
        let target = InstallTarget(host: "198.51.100.7", user: "root", identityFile: "/Users/me/.ssh/id_ed25519")
        let plan = InstallPlan.join(target: target, line: "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=\(code) sh",
                                    code: code, authKey: key)
        let installer = MachineInstaller(plan: plan, authKey: key, ssh: standIn.path)
        let seen = Progressed()
        let checklist = try await installer.run { seen.add($0) }
        return (checklist, seen.all)
    }

    private final class Progressed: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [InstallProgress] = []
        func add(_ one: InstallProgress) { lock.lock(); steps.append(one); lock.unlock() }
        var all: [InstallProgress] { lock.lock(); defer { lock.unlock() }; return steps }
    }

    @Test func aMachineJoinsAndAnswersItsOwnChecklist() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *tailscale*) echo "100.90.1.2" ;;
          *FLEET_JOIN*) echo "Fleet: this machine is the server writer-box"; echo "Fleet: the server service runs" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
        ;;
        esac
        """)
        let (checklist, progress) = try await join(standIn)
        // The three answers the machine gave, in the order of 4.1, and the eight ids it did not answer are absent.
        #expect(checklist.checks.map(\.check) == ["services", "tailnet", "runtime_signed_in"])
        #expect(checklist.isReady == false)
        #expect(checklist.line == "NOT READY: runtime_signed_in")
        #expect(checklist.failing.first?.fix == "Machines, this machine, Sign in.")
        // Every step ran, in the order of the plan, and each one is reported twice: running, then done.
        #expect(progress.filter { $0.state == .done }.map(\.step) == ["read", "network", "join", "verify"])
        #expect(progress.contains { $0.state == .failed } == false)
    }

    /// Both installers let SSH in over the private network only (`hubsetup.py firewall`), so every step after the
    /// network step goes to the address the machine got there, and that is the connection kept for it.
    @Test func afterTheNetworkStepTheInstallReachesTheMachineOnItsPrivateAddress() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *tailscale*) echo "100.90.1.2" ;;
          *FLEET_JOIN*) echo "Fleet: this machine is the server writer-box" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
        ;;
        esac
        """)
        let key = "tskey-auth-kNMMmP9-secret"
        let target = InstallTarget(host: "198.51.100.7", user: "root", identityFile: "/Users/me/.ssh/id_ed25519")
        let plan = InstallPlan.join(target: target, line: "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=CODE sh",
                                    code: "CODE12345678", authKey: key)
        let installer = MachineInstaller(plan: plan, authKey: key, ssh: standIn.path)
        _ = try await installer.run { _ in }
        #expect(standIn.destinations == ["root@198.51.100.7", "root@198.51.100.7", "root@100.90.1.2", "root@100.90.1.2"])
        let reached = await installer.reached
        #expect(reached == InstallTarget(host: "100.90.1.2", user: "root", identityFile: "/Users/me/.ssh/id_ed25519"))
        #expect(standIn.arguments.contains("/Users/me/.ssh/id_ed25519"))
    }

    @Test func aNetworkStepThatGaveNoAddressLeavesTheAddressThatWasGiven() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *tailscale*) echo "Tailscale is up" ;;
          *FLEET_JOIN*) echo "Fleet: this machine is the server writer-box" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
        ;;
        esac
        """)
        _ = try await join(standIn)
        #expect(Set(standIn.destinations) == ["root@198.51.100.7"])
        #expect(InstallPlan.privateAddress(in: ["fleet-on-network", "100.90.1.2"]) == "100.90.1.2")
        #expect(InstallPlan.privateAddress(in: ["203.0.113.9", "10.0.0.4", "100.128.0.1"]) == nil)
    }

    @Test func aCleanInstallEndsInItsChecklistAndNotInAFailure() async throws {
        // Both installers end in `verify`, and `verify` fails `runtime_signed_in` on every fresh machine, because
        // the installer signs in to nothing. So the join line ends in failure on a clean install, and the owner
        // must not be told that it failed.
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *tailscale*) echo "100.90.1.2" ;;
          *FLEET_JOIN*)
            echo "Fleet: this machine is the server writer-box"
            echo "fail  runtime_signed_in: claude is installed and not signed in"
            echo "NOT READY: runtime_signed_in"
            exit 1 ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
        ;;
        esac
        """)
        let (checklist, progress) = try await join(standIn)
        #expect(progress.contains { $0.state == .failed } == false, "a clean install was reported as a failure")
        #expect(progress.filter { $0.state == .done }.map(\.step) == ["read", "network", "join", "verify"])
        #expect(checklist.onlyNeedsSignIn)
        #expect(checklist.summary.contains("not signed in to your provider yet"))
    }

    @Test func aJoinThatNeverReachedTheChecksIsAFailure() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *tailscale*) echo "100.90.1.2" ;;
          *FLEET_JOIN*) echo "Fleet join stopped: the hub refused this code" >&2; exit 1 ;;
        esac
        """)
        let (checklist, progress) = await attempt(standIn)
        #expect(checklist == nil)
        let failed = progress.last { $0.state == .failed }
        #expect(failed?.step == "join")
        #expect(failed?.detail == "Join the fleet: Fleet join stopped: the hub refused this code")
        #expect(standIn.programs.contains { $0.contains("verify --json") } == false)
    }

    @Test func theTailscaleKeyTravelsOnStandardInputAndNowhereElse() async throws {
        let key = "tskey-auth-kNMMmP9-neverInAnArgument"
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *tailscale*) echo "100.90.1.2" ;;
          *FLEET_JOIN*) echo "Fleet: the server service runs" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
        ;;
        esac
        """)
        let (_, progress) = try await join(standIn, key: key)
        #expect(standIn.arguments.contains(key) == false)
        #expect(standIn.inputs.contains(key))
        for step in progress {
            #expect(step.lines.allSatisfy { !$0.contains(key) })
        }
    }

    @Test func theOneTimeJoinCodeIsInNoLineTheAppKeeps() async throws {
        let code = "7KMQ2PRJ4TVW"
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *tailscale*) echo "100.90.1.2" ;;
          *FLEET_JOIN*) echo "Fleet: joined with FLEET_JOIN=\(code)" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
        ;;
        esac
        """)
        let (_, progress) = try await join(standIn, code: code)
        for step in progress {
            #expect(step.lines.allSatisfy { !$0.contains(code) }, "a kept line carried the join code")
        }
        // The code is in the one place it must be: the line the hub itself wrote, which the app runs unchanged.
        #expect(standIn.programs.contains { $0.contains("FLEET_JOIN=\(code)") })
    }

    @Test func theOwnersKeyIsPassedToSSHAndNeverReadHere() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *) echo "" ;;
        esac
        exit 1
        """)
        _ = try? await join(standIn)
        let arguments = standIn.arguments
        #expect(arguments.contains("/Users/me/.ssh/id_ed25519"))
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("NumberOfPasswordPrompts=0"))
    }

    @Test func aMachineThatIsNotRootStopsBeforeAnythingIsChanged() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.checked(["user=deploy", "uid=1000", "sudo=password"]))
        esac
        """)
        await #expect(throws: InstallError.notRoot("root")) { try await join(standIn) }
        #expect(standIn.programs.count == 1, "a step ran after the machine said it is not root")
    }

    @Test func anotherSystemStopsWithItsOwnLine() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.checked(["os_id=fedora", "os_version=41", "os_name=Fedora Linux"]))
        esac
        """)
        await #expect(throws: InstallError.checkStopped(InstallPlan.joinSystems)) {
            try await join(standIn)
        }
        #expect(standIn.programs.count == 1, "a step ran after the check stopped the install")
        #expect(InstallError.checkStopped(InstallPlan.joinSystems).plain(host: "h") == InstallPlan.joinSystems)
        // The join and the hub's own installer take the same systems (hub.sh and join.sh).
        #expect(InstallPlan.joinSystems == "This install needs Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13.")
        #expect(InstallPlan.hubSystems == InstallPlan.joinSystems)
    }

    @Test func aFailedStepStopsTheInstallAndSaysWhatTheMachineSaid() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *tailscale*) echo "tailscale up: the key is not valid" >&2; exit 1 ;;
        esac
        """)
        let (_, progress) = await attempt(standIn)
        let failed = progress.last { $0.state == .failed }
        #expect(failed?.step == "network")
        #expect(failed?.detail == "The private network: tailscale up: the key is not valid")
        #expect(standIn.programs.contains { $0.contains("FLEET_JOIN") } == false)
    }

    private func attempt(_ standIn: StandInSSH) async -> (VerifyChecklist?, [InstallProgress]) {
        let seen = Progressed()
        let key = "tskey-auth-kNMMmP9-secret"
        let plan = InstallPlan.join(target: InstallTarget(host: "198.51.100.7"),
                                    line: "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=CODE sh",
                                    code: "CODE12345678", authKey: key)
        let installer = MachineInstaller(plan: plan, authKey: key, ssh: standIn.path)
        let checklist = try? await installer.run { seen.add($0) }
        return (checklist, seen.all)
    }

    // ---- the hub: the first machine, which has no hub to ask for a line

    @Test func theFirstMachineIsClaimedByThisMacAndNoConsole() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *"git clone"*|*"rev-parse"*) echo 4f1c0ab; echo /root/fleet-kit/hub.sh ;;
          *"hub.sh --check"*) echo "Fleet step 1 of 13: base packages" ;;
          *"tailscale ip -4"*) echo 100.64.0.9 ;;
          *setsid*) exit 0 ;;
          *"tail -n 60"*)
            if [ "$n" -gt 5 ]; then
              echo 'Fleet: FLEET_CLAIM=7KMQ-2PRJ-4TVW sh -c "$(curl -fsS http://100.64.0.9:8765/claim)"'
            else
              echo "Fleet step 8 of 13: the owner claim"
            fi ;;
          *"tail -n 40"*) echo "READY" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
        ;;
        esac
        """)
        let claimed = Claimed()
        let plan = InstallPlan.hub(target: InstallTarget(host: "198.51.100.7"),
                                   source: "https://founderizer.com/fleet.git", authKey: "tskey-auth-secret-00")
        let installer = MachineInstaller(plan: plan, authKey: "tskey-auth-secret-00", ssh: standIn.path) { code, url in
            claimed.set(code: code, url: url)
        }
        let seen = Progressed()
        let checklist = try await installer.run { seen.add($0) }
        #expect(claimed.code == "7KMQ2PRJ4TVW")
        #expect(claimed.url?.absoluteString == "http://100.64.0.9:8765/claim")
        #expect(checklist.checks.count == 3)
        #expect(seen.all.filter { $0.state == .done }.map(\.step)
                == ["read", "network", "code", "plan", "start", "wait_claim", "claim", "wait_ready", "verify"])
        // The installer lets SSH in over the private network only, so the hub is installed and read over it.
        #expect(standIn.destinations.first == "root@198.51.100.7")
        #expect(Set(standIn.destinations.dropFirst(2)) == ["root@100.64.0.9"])
        #expect(await installer.reached.host == "100.64.0.9")
        #expect(standIn.programs.contains { $0.contains("hub.sh < /dev/null") })
        // The app gives the manager a server of its own, and says so to the plan and to the install.
        #expect(standIn.programs.contains { $0.contains("FLEET_MANAGER_SERVER=later sh /root/fleet-kit/hub.sh --check") })
        #expect(standIn.programs.contains { $0.contains("'FLEET_MANAGER_SERVER=later sh /root/fleet-kit/hub.sh < /dev/null") })
        #expect(standIn.inputs.contains("tskey-auth-secret-00"), "the key went on standard input to the network step")
    }

    private final class Claimed: @unchecked Sendable {
        private let lock = NSLock()
        private var pair: (String, URL)?
        func set(code: String, url: URL) { lock.lock(); pair = (code, url); lock.unlock() }
        var code: String? { lock.lock(); defer { lock.unlock() }; return pair?.0 }
        var url: URL? { lock.lock(); defer { lock.unlock() }; return pair?.1 }
    }

    @Test func anInstallerIsReadWhicheverBrandItPrints() async throws {
        // The installers are renamed in their own repository, so this app reads both wordings until they are not
        // needed. The side that moves first widens; this side follows.
        for line in ["Fleet install stopped: this machine has no /etc/os-release",
                     "Founderizer install stopped: this machine has no /etc/os-release",
                     "Fleet join stopped: the hub cannot be reached",
                     "Founderizer join stopped: the hub cannot be reached"] {
            #expect(InstallPlan.stopLine(in: ["Fleet step 3 of 13", line]) == line)
        }
        #expect(InstallPlan.stopLine(in: ["Fleet step 3 of 13", "Founderizer: the server service runs"]) == nil)
    }

    @Test func anInstallerThatStoppedIsNotWaitedForToTheEnd() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *"rev-parse"*) echo 4f1c0ab ;;
          *"hub.sh --check"*) echo "Fleet step 1 of 13" ;;
          *"tailscale ip -4"*) echo 100.64.0.9 ;;
          *setsid*) exit 0 ;;
          *"tail -n 60"*) echo "Fleet install stopped: this machine has no /etc/os-release" ;;
        esac
        """)
        let plan = InstallPlan.hub(target: InstallTarget(host: "198.51.100.7"), source: "https://founderizer.com/fleet.git",
                                   authKey: "tskey-auth-secret-00")
        let installer = MachineInstaller(plan: plan, authKey: "tskey-auth-secret-00", ssh: standIn.path) { _, _ in }
        await #expect(throws: InstallError.step("Wait for the link code",
                                                "Fleet install stopped: this machine has no /etc/os-release")) {
            try await installer.run { _ in }
        }
    }

    @Test func aHubWithNoKeyMustAlreadyBeOnTheNetworkOrTheKeyIsAsked() async throws {
        let plan = InstallPlan.hub(target: InstallTarget(host: "198.51.100.7"), source: "https://founderizer.com/fleet.git",
                                   authKey: nil)
        let network = try #require(plan.steps.first { $0.id == "network" })
        guard case .run(let program) = network.action else { Issue.record("no network step to run"); return }
        #expect(program.hasPrefix("tailscale status >/dev/null 2>&1 && tailscale ip -4"))
        #expect(InstallPlan.needsNetworkKey(program), "a machine that is not on the network asks for the key")
        #expect(plan.steps.map(\.id).firstIndex(of: "network") == 1)
    }

    // ---- the link code, which comes off a machine's own screen

    @Test func aLinkCodeIsForgivenItsSpacesAndItsCase() {
        #expect(ClaimCode.read("7kmq-2prj-4tvw") == "7KMQ2PRJ4TVW")
        #expect(ClaimCode.read(" 7KMQ 2PRJ 4TVW ") == "7KMQ2PRJ4TVW")
        #expect(ClaimCode.grouped("7KMQ2PRJ4TVW") == "7KMQ-2PRJ-4TVW")
        #expect(ClaimCode.read("7KMQ-2PRJ") == nil)
        #expect(ClaimCode.read("7KMQ-2PRJ-4TVW-9999") == nil)
        // I, O, 0 and 1 are not in the alphabet, so they are not read as characters of a code.
        #expect(ClaimCode.read("IOIO-2PRJ-4TVW") == nil)
    }

    @Test func aMachineCannotPointThisMacAtAnAddressOfItsOwn() {
        let good = "FLEET_CLAIM=7KMQ-2PRJ-4TVW sh -c \"$(curl -fsS http://100.64.0.9:8765/claim)\""
        #expect(ClaimCode.found(in: good)?.claim.absoluteString == "http://100.64.0.9:8765/claim")
        for elsewhere in ["FLEET_CLAIM=7KMQ-2PRJ-4TVW sh -c \"$(curl -fsS http://203.0.113.9:8765/claim)\"",
                          "FLEET_CLAIM=7KMQ-2PRJ-4TVW sh -c \"$(curl -fsS http://10.0.0.1:8765/claim)\"",
                          "FLEET_CLAIM=7KMQ-2PRJ-4TVW sh -c \"$(curl -fsS https://founderizer.com/claim)\"",
                          "FLEET_CLAIM=SHORT sh -c \"$(curl -fsS http://100.64.0.9:8765/claim)\""] {
            #expect(ClaimCode.found(in: elsewhere) == nil, "\(elsewhere) was claimed")
        }
    }

    /// The first run matches this refusal by its words and shows them (review A4): it is never "The hub did not take
    /// the claim.", because nothing was sent.
    @Test func theClaimGoesOnlyToTheFleetsOwnNetwork() async throws {
        for elsewhere in ["https://founderizer.com/claim", "http://203.0.113.9:8765/claim",
                          "http://100.64.0.9:8765/state"] {
            await #expect(throws: InstallError.step("Claim the hub", MachineInstaller.notOnYourNetwork)) {
                try await MachineInstaller.sendClaim(code: "7KMQ2PRJ4TVW", to: URL(string: elsewhere)!)
            }
        }
    }

    // ---- the plan itself

    @Test func aUserThatBecomesRootCarriesEveryCommandThroughSudo() {
        let plan = InstallPlan.join(target: InstallTarget(host: "h", user: "deploy", becomeRoot: true),
                                    line: "line", code: "CODE12345678", authKey: "key-0000")
        let arguments = plan.arguments(for: "tailscale ip -4")
        #expect(arguments.last == "sudo -n -i -- /bin/sh -c 'tailscale ip -4'")
        #expect(InstallPlan.join(target: InstallTarget(host: "h"), line: "line", code: "CODE12345678",
                                 authKey: "key-0000").arguments(for: "tailscale ip -4").last == "tailscale ip -4")
    }

    @Test func verifyRunsAsTheUserWhoseServicesItReads() {
        let plan = InstallPlan.join(target: InstallTarget(host: "h"), line: "line", code: "CODE12345678",
                                    authKey: "key-0000")
        let program = plan.steps.last.map { step -> String in
            if case .verify(let command) = step.action { return command }
            return ""
        }
        #expect(program?.contains("runuser -u fleet") == true)
        #expect(program?.contains("fleet-server && python3 fleet.py verify --json") == true)
    }

    @Test func whatTheOwnerGivesIsCheckedBeforeAnythingIsReached() {
        #expect(InstallTarget(host: "198.51.100.7").isValid)
        #expect(InstallTarget(host: "box.example.com", user: "deploy", port: 2222).isValid)
        #expect(InstallTarget(host: "").problem != nil)
        #expect(InstallTarget(host: "198.51.100.7; rm -rf /").problem != nil)
        #expect(InstallTarget(host: "h", user: "Root").problem != nil)
        #expect(InstallTarget(host: "h", port: 0).problem != nil)
        #expect(InstallTarget(host: "h", identityFile: "id_ed25519").problem != nil)
        #expect(InstallTarget(host: "h", identityFile: "/Users/me/.ssh/id_ed25519").isValid)
    }

    // MARK: the private network, by a link that the owner approves

    private static let tags = "tag:claude-code-dev,tag:terminal-relay-worker"
    private static let hubLine = "command -v tailscale >/dev/null || for try in 1 2 3; do "
        + "DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=1200 -q install </dev/null >/dev/null 2>&1; "
        + "curl -fsSL https://tailscale.com/install.sh | sh && command -v tailscale >/dev/null && break; "
        + "sleep 20; done; "
        + "tailscale status >/dev/null 2>&1 || tailscale up --advertise-tags=\(tags) --accept-dns=false; "
        + "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=7KMQ2PRJ4TVW sh"

    /// The owner, 31 October 2026, after three servers stopped here: the install shows the link and goes on by itself.
    @Test func aServerOffTheNetworkShowsTheLinkAndGoesOnOnceHeApprovesIt() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *fleet-machine-name=*)
            reads=$(cat "$dir/reads" 2>/dev/null || echo 0); reads=$((reads + 1)); printf '%s' "$reads" > "$dir/reads"
            echo "fleet-machine-name=worker-9"
            if [ "$reads" -lt 2 ]; then
              echo "To authenticate, visit:"; echo; printf '\\thttps://login.tailscale.com/a/5e519a012741\\n'
            else
              echo "fleet-on-network"; echo "100.90.1.2"
            fi ;;
          *setsid*) ;;
          *FLEET_JOIN*) echo "Fleet: this machine is the server worker-9" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
          ;;
        esac
        """)
        let target = InstallTarget(host: "198.51.100.7", user: "root", identityFile: "/Users/me/.ssh/id_ed25519")
        let plan = InstallPlan.join(target: target, line: Self.hubLine, code: "7KMQ2PRJ4TVW", authKey: nil)
        let seen = Progressed()
        _ = try await MachineInstaller(plan: plan, authKey: "", ssh: standIn.path).run { seen.add($0) }

        let start = try #require(standIn.programs.first { $0.contains("setsid") })
        #expect(start.contains("tailscale up --advertise-tags=\(Self.tags) --accept-dns=false --timeout=15m"))
        let waiting = try #require(seen.all.first { $0.step == "network" && !$0.lines.isEmpty && $0.state == .running })
        let link = try #require(NetworkSignIn.found(in: waiting.lines))
        #expect(link.url.absoluteString == "https://login.tailscale.com/a/5e519a012741")
        #expect(link.server == "worker-9")
        #expect(seen.all.contains { $0.step == "network" && $0.state == .done })
        #expect(seen.all.contains { $0.step == "join" && $0.state == .done })
    }

    @Test func aMachineOnTheNetworkAlreadySeesNoLink() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *fleet-machine-name=*) echo "fleet-machine-name=worker-9"; echo "fleet-on-network"; echo "100.90.1.2" ;;
          *FLEET_JOIN*) echo "Fleet: this machine is the server worker-9" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
          ;;
        esac
        """)
        let target = InstallTarget(host: "198.51.100.7", user: "root", identityFile: "/Users/me/.ssh/id_ed25519")
        let plan = InstallPlan.join(target: target, line: Self.hubLine, code: "7KMQ2PRJ4TVW", authKey: nil)
        let seen = Progressed()
        _ = try await MachineInstaller(plan: plan, authKey: "", ssh: standIn.path).run { seen.add($0) }
        #expect(seen.all.allSatisfy { NetworkSignIn.found(in: $0.lines) == nil })
    }

    @Test func aSignInThatEndsSaysWhyInItsOwnWay() {
        // Tailscale refused the tags: the one question of the private network, with the credential.
        let refused = NetworkSignIn.read(["fleet-machine-name=box", "backend error: requested tags [tag:x] are invalid "
                                          + "or not permitted", "fleet-sign-in-ended 1"])
        #expect(refused == .ended(says: NetworkSignIn.notOnNetwork))
        #expect(InstallPlan.needsNetworkKey(NetworkSignIn.notOnNetwork))
        // Nobody approved it: a new link, by Try again, and no credential.
        let late = NetworkSignIn.read(["timeout waiting for Tailscale service to enter a Running state", "fleet-sign-in-ended 1"])
        #expect(late == .ended(says: NetworkSignIn.notApproved))
        #expect(InstallPlan.needsNetworkKey(NetworkSignIn.notApproved) == false)
        #expect(InstallError.step("The private network", NetworkSignIn.notApproved).plain(host: "h") == NetworkSignIn.notApproved)
        // Tailscale refused its flags, in a line that repeats `--timeout=15m0s`: neither late, nor a credential's matter.
        let flags = NetworkSignIn.read(["Error: changing settings via 'tailscale up' requires mentioning all",
                                        "tailscale up --accept-dns=false --hostname=box --timeout=15m0s", "fleet-sign-in-ended 1"])
        #expect(flags == .ended(says: NetworkSignIn.notStarted))
        #expect(NetworkSignIn.read(["sh: tailscale: not found", "fleet-sign-in-ended 127"]) == .ended(says: NetworkSignIn.notStarted))
        #expect(NetworkSignIn.read(["Operation not permitted", "fleet-sign-in-ended 1"]) == .ended(says: NetworkSignIn.notStarted))
        #expect(InstallPlan.needsNetworkKey(NetworkSignIn.notStarted) == false)
        #expect(InstallError.step("The private network", NetworkSignIn.notStarted).plain(host: "h") == NetworkSignIn.notStarted)
        // Approved, a moment before Tailscale says that it runs: the next read has it.
        #expect(NetworkSignIn.read(["fleet-sign-in-ended 0"]) == .waiting(nil))
    }

    /// The step's own shell text, run by a real `sh`: a stand-in `ssh` would prove nothing of it. A stand-in `tailscale`
    /// answers as the machine's would, and `setsid`, which a Mac has not, only runs what it is given.
    private final class Machine {
        let folder: URL
        var log: String { folder.appendingPathComponent("up.log").path }

        init(up: String, status: String) throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fleet-signin-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("tailscale", """
            #!/bin/sh
            case "$1" in
              status) \(status) ;;
              ip) echo 100.90.1.2 ;;
              up) printf '%s\\n' "$*" > "\(folder.path)/up-args"; \(up) ;;
            esac
            """)
            try write("setsid", "#!/bin/sh\nexec \"$@\"\n")
        }

        private func write(_ name: String, _ text: String) throws {
            let path = folder.appendingPathComponent(name)
            try text.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        /// The program as the plan wrote it, with this machine's log in place of the real one.
        func run(_ program: String) throws -> (status: Int32, lines: [String]) {
            let shell = Process(), out = Pipe()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", program.replacingOccurrences(of: NetworkSignIn.log, with: log)]
            shell.environment = ["PATH": folder.path + ":/usr/bin:/bin"]
            shell.standardOutput = out; shell.standardError = out; shell.standardInput = FileHandle.nullDevice
            try shell.run()
            shell.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (shell.terminationStatus, text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        }

        /// Reads until the background sign-in has written `mark`: the start does not wait for it.
        func read(_ program: String, until mark: String) async throws -> [String] {
            for _ in 0..<100 {
                let lines = try run(program).lines
                if lines.contains(where: { $0.contains(mark) }) { return lines }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return try run(program).lines
        }
    }

    private func signInText(tags: [String] = []) throws -> (start: String, check: String) {
        guard case .signIn(let start, let check, _, _) = NetworkSignIn.action(install: "", tags: tags) else {
            throw InstallError.noChecklist
        }
        return (start, check)
    }

    @Test func theSignInStartsInTheBackgroundAndItsLinkReachesTheLog() async throws {
        // Tailscale prints the link on standard error, and then waits.
        let machine = try Machine(up: "printf '\\thttps://login.tailscale.com/a/5e519a012741\\n' >&2; sleep 30", status: "exit 1")
        try "stale https://login.tailscale.com/a/000000000000\nfleet-sign-in-ended 1\n".write(toFile: machine.log, atomically: true, encoding: .utf8)
        let text = try signInText(tags: ["tag:a"])
        let started = Date()
        #expect(try machine.run(text.start).status == 0)
        #expect(Date().timeIntervalSince(started) < 5)      // it does not wait for the approval
        let lines = try await machine.read(text.check, until: "5e519a012741")
        #expect(NetworkSignIn.found(in: lines)?.url.absoluteString == "https://login.tailscale.com/a/5e519a012741")
        #expect(NetworkSignIn.read(lines) != .ended(says: NetworkSignIn.notStarted))      // not the old log's end
        let mode = try FileManager.default.attributesOfItem(atPath: machine.log)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)                    // the link is his to open, and the server may have other users
        let args = try String(contentsOfFile: machine.folder.appendingPathComponent("up-args").path, encoding: .utf8)
        #expect(args.contains("--advertise-tags=tag:a --accept-dns=false --timeout=15m"))
    }

    @Test func aSignInThatFailsLeavesItsStatusInTheLog() async throws {
        let machine = try Machine(up: "echo 'requested tags [tag:a] are invalid or not permitted' >&2; exit 3", status: "exit 1")
        let text = try signInText(tags: ["tag:a"])
        _ = try machine.run(text.start)
        let lines = try await machine.read(text.check, until: "fleet-sign-in-ended")
        #expect(lines.contains("fleet-sign-in-ended 3"))
        #expect(NetworkSignIn.read(lines) == .ended(says: NetworkSignIn.notOnNetwork))
    }

    @Test func aMachineOnTheNetworkStartsNoSignIn() throws {
        let machine = try Machine(up: "touch up-ran", status: "exit 0")
        try "fleet-sign-in-ended 1\n".write(toFile: machine.log, atomically: true, encoding: .utf8)
        let text = try signInText()
        #expect(try machine.run(text.start).status == 0)
        #expect(FileManager.default.fileExists(atPath: machine.folder.appendingPathComponent("up-args").path) == false)
        #expect(FileManager.default.fileExists(atPath: machine.log) == false)      // an earlier try's end is not this one's
    }

    @Test func onlyARunningTailscaleIsOnTheNetwork() throws {
        let text = try signInText()
        let starting = try Machine(up: ":", status: "echo '{ \"BackendState\": \"Starting\" }'; exit 0")
        let read = try starting.run(text.check)
        #expect(read.status == 0)            // a read that found nothing is no failed read
        #expect(NetworkSignIn.read(read.lines) == .waiting(nil))
        let running = try Machine(up: ":", status: "echo '{ \"BackendState\": \"Running\" }'; exit 0")
        try "the sign-in's words\n".write(toFile: running.log, atomically: true, encoding: .utf8)
        #expect(NetworkSignIn.read(try running.run(text.check).lines) == .on)
        #expect(FileManager.default.fileExists(atPath: running.log) == false)
    }

    /// One read that does not reach the machine is not the end of the wait: he may be approving the link just then.
    @Test func aReadThatFailsDoesNotEndTheWait() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.ubuntu)
          *fleet-machine-name=*)
            reads=$(cat "$dir/reads" 2>/dev/null || echo 0); reads=$((reads + 1)); printf '%s' "$reads" > "$dir/reads"
            if [ "$reads" -lt 2 ]; then echo "ssh: connect to host 198.51.100.7 port 22: Connection refused"; exit 255; fi
            echo "fleet-machine-name=worker-9"; echo "fleet-on-network" ;;
          *FLEET_JOIN*) echo "Fleet: this machine is the server worker-9" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
          ;;
        esac
        """)
        let target = InstallTarget(host: "198.51.100.7", user: "root", identityFile: "/Users/me/.ssh/id_ed25519")
        let plan = InstallPlan.join(target: target, line: Self.hubLine, code: "7KMQ2PRJ4TVW", authKey: nil)
        _ = try await MachineInstaller(plan: plan, authKey: "", ssh: standIn.path).run { _ in }
    }

    /// `git` on the server refused its own key: status 128, and not the owner's SSH key.
    @Test func aRefusalThatIsNotSshsOwnIsNotHisKey() async throws {
        let standIn = try StandInSSH("""
        echo "git@github.com: Permission denied (publickey)."
        echo "Founderizer install stopped: the code could not be fetched."
        exit 128
        """)
        let plan = InstallPlan.join(target: InstallTarget(host: "203.0.113.9"), line: Self.hubLine, code: "7KMQ2PRJ4TVW",
                                    authKey: nil)
        await #expect {
            _ = try await MachineInstaller(plan: plan, authKey: "", ssh: standIn.path).run { _ in }
        } throws: { error in
            (error as? InstallError)?.plain(host: "203.0.113.9") == "The code could not be fetched."
        }
    }

    /// A link that nobody approved, one that never came and a machine that stopped answering each end the wait in
    /// their own words at its deadline.
    @Test func theWaitEndsAtItsDeadline() async throws {
        func says(_ answer: String) async throws -> String? {
            let standIn = try StandInSSH("case \"$program\" in *fleet-machine-name*) \(answer) ;; esac")
            let step = InstallStep(id: "network", title: "The private network", says: "",
                                   action: .signIn(start: ":", check: "fleet-machine-name", every: 0.01, within: 0.2))
            let plan = InstallPlan(job: .join, target: InstallTarget(host: "203.0.113.9"), steps: [step], redactions: [])
            do {
                _ = try await MachineInstaller(plan: plan, authKey: "", ssh: standIn.path).run { _ in }
                return nil
            } catch { return (error as? InstallError)?.plain(host: "203.0.113.9") }
        }
        #expect(try await says(#"echo "fleet-machine-name=box"; echo "https://login.tailscale.com/a/5e519a012741""#)
                == NetworkSignIn.notApproved)
        #expect(try await says(#"echo "fleet-machine-name=box""#) == NetworkSignIn.notStarted)
        // Tailscale gave up with no link: nobody had one to approve.
        #expect(try await says(#"echo "timeout waiting for Tailscale service to enter a Running state"; echo "fleet-sign-in-ended 1""#)
                == NetworkSignIn.notStarted)
        let lost = try await says(#"echo "ssh: connect to host 203.0.113.9 port 22: Connection refused"; exit 255"#)
        #expect(lost?.contains("took too long") == true)
    }

    @Test func theNewestLinkIsTheOne() {
        let link = NetworkSignIn.found(in: ["https://login.tailscale.com/a/000000000000", "https://login.tailscale.com/a/111111111111"])
        #expect(link?.url.absoluteString == "https://login.tailscale.com/a/111111111111")
    }

    /// The link comes from a machine, and the screen opens it where he is an admin of his tailnet.
    @Test func onlyTailscalesOwnSignInPageIsALink() {
        for line in ["https://evil.example/a/5e519a012741", "https://login.tailscale.com.evil.example/a/5e519a012741",
                     "http://login.tailscale.com/a/5e519a012741", "https://login.tailscale.com/a/5e519a012741?next=x",
                     "https://login.tailscale.com/admin/users", "see https://login.tailscale.com/a/5e519a012741",
                     "x://a/https://login.tailscale.com/a/5e519a012741"] {
            #expect(NetworkSignIn.found(in: [line]) == nil, "\(line)")
        }
        let link = NetworkSignIn.found(in: ["fleet-machine-name=Not A Name", "https://login.tailscale.com/a/1ca8dadd014fac"])
        #expect(link?.server == nil)
    }

    /// The tags stand inside single quotes on the server, so only what is a tag goes.
    @Test func theTagsAreTheHubsAndNothingElse() {
        #expect(NetworkSignIn.tags(inLine: Self.hubLine) == ["tag:claude-code-dev", "tag:terminal-relay-worker"])
        #expect(NetworkSignIn.tags(inLine: "curl http://h/join | FLEET_JOIN=x sh").isEmpty)
        #expect(NetworkSignIn.tags(inLine: "tailscale up --advertise-tags=tag:a,$(reboot) --accept-dns=false").isEmpty)
    }

    /// With many keys in the agent the server hangs up, and the line that says why is not the last one.
    @Test func aKeyTheServerRefusedIsSaidEvenWhenSshGoesOnPrinting() async throws {
        let standIn = try StandInSSH("""
        echo "Received disconnect from 203.0.113.9 port 22:2: Too many authentication failures"
        echo "Disconnected from 203.0.113.9 port 22"
        exit 255
        """)
        let plan = InstallPlan.join(target: InstallTarget(host: "203.0.113.9"), line: Self.hubLine, code: "7KMQ2PRJ4TVW",
                                    authKey: nil)
        await #expect {
            _ = try await MachineInstaller(plan: plan, authKey: "", ssh: standIn.path).run { _ in }
        } throws: { error in
            (error as? InstallError)?.plain(host: "203.0.113.9")
                == "203.0.113.9 did not take your SSH key. Choose its key."
        }
    }

    // MARK: the check of the server, as the first step of both installs

    @Test func bothInstallsBeginWithTheCheckOfTheServer() {
        let target = InstallTarget(host: "198.51.100.7")
        for plan in [InstallPlan.hub(target: target, source: InstallPlan.defaultSource, authKey: nil),
                     InstallPlan.join(target: target, line: Self.hubLine, code: "7KMQ2PRJ4TVW", authKey: nil)] {
            let first = plan.steps.first
            #expect(first?.id == "read")
            #expect(first?.title == ServerCheck.title)
            #expect(first?.action == .check(every: ServerCheck.waitEvery, within: ServerCheck.waitWithin))
        }
        #expect(InstallPlan.hub(target: target, source: InstallPlan.defaultSource, authKey: nil).steps.map(\.id)
                == ["read", "network", "code", "plan", "start", "wait_claim", "claim", "wait_ready", "verify"])
        #expect(InstallPlan.join(target: target, line: Self.hubLine, code: "7KMQ2PRJ4TVW", authKey: nil).steps.map(\.id)
                == ["read", "network", "join", "verify"])
    }

    /// The check runs as the user this Mac logs in as, with `sudo -n` only inside it, and its script never stands in an
    /// argument: the server's login shell would parse it.
    @Test func theCheckRunsAsTheLoginUserWithItsScriptOnStandardInput() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          \(Self.checked(["user=deploy", "uid=1000", "sudo=nopasswd"]))
          *tailscale*) echo "100.90.1.2" ;;
          *FLEET_JOIN*) echo "Fleet: this machine is the server writer-box" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
        ;;
        esac
        """)
        let target = InstallTarget(host: "198.51.100.7", user: "deploy", becomeRoot: true)
        let plan = InstallPlan.join(target: target, line: "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=CODE sh",
                                    code: "CODE12345678", authKey: "tskey-auth-kNMMmP9-secret")
        let seen = Progressed()
        _ = try await MachineInstaller(plan: plan, authKey: "tskey-auth-kNMMmP9-secret", ssh: standIn.path).run { seen.add($0) }
        #expect(standIn.programs.first == "/bin/sh -s")
        #expect(standIn.programs.dropFirst().allSatisfy { $0.hasPrefix("sudo -n -i -- /bin/sh -c ") })
        let script = try String(contentsOf: standIn.folder.appendingPathComponent("stdin-1"), encoding: .utf8)
        #expect(script == ServerCheck.script)
        // The check's own answer is the step's line: the server in a few words, and what changes.
        let read = try #require(seen.all.last { $0.step == "read" && $0.state == .done })
        #expect(read.lines == ["Ubuntu 24.04 · 4 GB · x86", "SSH moves to Tailscale. Port 443 stays open."])
    }

    /// A server still busy with its first start is read again until it is not, with its reason as the step's line.
    @Test func aServerBusyWithItsFirstStartIsWaitedFor() async throws {
        let standIn = try StandInSSH("""
        case "$program" in
          *"/bin/sh -s"*)
            reads=$(cat "$dir/reads" 2>/dev/null || echo 0); reads=$((reads + 1)); printf '%s' "$reads" > "$dir/reads"
            if [ "$reads" -lt 3 ]; then state=running; else state=done; fi
            printf '%s\\n' \(Self.ready.filter { !$0.hasPrefix("cloud_init") }.map { "'\($0)'" }.joined(separator: " ")) \
              "cloud_init=$state" ;;
          *verify*) cat <<'ANSWER'
        \(Self.checklist)
        ANSWER
        ;;
        esac
        """)
        let plan = InstallPlan(job: .join, target: InstallTarget(host: "198.51.100.7"), steps: [
            InstallStep(id: "read", title: ServerCheck.title, says: "", action: .check(every: 0.01, within: 30)),
            InstallStep(id: "verify", title: "Check the server", says: "", action: .verify("verify")),
        ], redactions: [])
        let seen = Progressed()
        _ = try await MachineInstaller(plan: plan, authKey: "", ssh: standIn.path).run { seen.add($0) }
        #expect(standIn.programs.filter { $0 == "/bin/sh -s" }.count == 3)
        #expect(seen.all.contains { $0.step == "read" && $0.state == .running
                    && $0.lines == ["The server is still setting itself up after its first start."] })
        #expect(seen.all.contains { $0.step == "read" && $0.state == .done })
    }

    @Test func aBusyServerThatNeverEndsItsFirstStartTimesOut() async throws {
        let standIn = try StandInSSH("case \"$program\" in \(Self.checked(["dpkg_lock=yes"])) esac")
        let plan = InstallPlan(job: .join, target: InstallTarget(host: "198.51.100.7"), steps: [
            InstallStep(id: "read", title: ServerCheck.title, says: "", action: .check(every: 0.01, within: 0.1)),
        ], redactions: [])
        await #expect(throws: InstallError.timedOut(ServerCheck.title)) {
            _ = try await MachineInstaller(plan: plan, authKey: "", ssh: standIn.path).run { _ in }
        }
    }

    /// A server that cannot take the install stops at the check, in the check's own line, before anything changes.
    @Test func aStopOfTheCheckStopsTheInstallBeforeAnythingChanges() async throws {
        let standIn = try StandInSSH("case \"$program\" in \(Self.checked(["memory_mb=460"])) esac")
        let says = "This server has 460 MB of memory, and a server for agents needs about 2 GB. Choose a plan with more memory."
        await #expect(throws: InstallError.checkStopped(says)) { try await join(standIn) }
        #expect(standIn.programs == ["/bin/sh -s"])
        #expect(InstallError.checkStopped(says).plain(host: "198.51.100.7") == says)
        // The hub's own VPS needs about 1 GB.
        let hub = try StandInSSH("case \"$program\" in \(Self.checked(["memory_mb=960"])) *) exit 1 ;; esac")
        let plan = InstallPlan.hub(target: InstallTarget(host: "198.51.100.7"), source: InstallPlan.defaultSource,
                                   authKey: "tskey-auth-secret-00")
        await #expect(throws: InstallError.self) {
            _ = try await MachineInstaller(plan: plan, authKey: "tskey-auth-secret-00", ssh: hub.path) { _, _ in }.run { _ in }
        }
        #expect(hub.programs.count == 2, "the hub's check let 960 MB through, and the next step ran")
    }

    // MARK: a sudo that asks for a password

    private static let sudoServer = """
    case "$program" in
      \(checked(["user=deploy", "uid=1000", "sudo=password"]))
      *tailscale*) cat "$dir/stdin-$n"; echo; echo "100.90.1.2" ;;
      *FLEET_JOIN*) echo "Fleet: this machine is the server writer-box" ;;
      *verify*) cat <<'ANSWER'
    \(checklist)
    ANSWER
    ;;
    esac
    """

    private func sudoJoin(_ standIn: StandInSSH, password: PasswordOnce.Password?) async throws -> [InstallProgress] {
        let target = InstallTarget(host: "198.51.100.7", user: "deploy", becomeRoot: true)
        let plan = InstallPlan.join(target: target, line: "curl -fsS http://100.64.0.1:8765/join | FLEET_JOIN=CODE sh",
                                    code: "CODE12345678", authKey: "tskey-auth-kNMMmP9-secret")
        let seen = Progressed()
        _ = try await MachineInstaller(plan: plan, authKey: "tskey-auth-kNMMmP9-secret", ssh: standIn.path,
                                       sudoPassword: password).run { seen.add($0) }
        return seen.all
    }

    /// **The password, once**, for a `sudo` that asks for it: each root step gets it on the first line of its standard
    /// input for `sudo -S`, and nowhere else. The check itself never sees it, no kept line holds it, and the install
    /// clears it when it ends.
    @Test func aSudoThatAsksForAPasswordIsFedItFromMemory() async throws {
        let secret = "correct horse battery"
        let standIn = try StandInSSH(Self.sudoServer)
        let password = PasswordOnce.Password(secret)
        let progress = try await sudoJoin(standIn, password: password)
        #expect(standIn.programs.first == "/bin/sh -s")
        for program in standIn.programs.dropFirst() {
            #expect(program.hasPrefix("sudo -S -k -p '' -i -- /bin/sh -c "), "\(program)")
        }
        let check = try String(contentsOf: standIn.folder.appendingPathComponent("stdin-1"), encoding: .utf8)
        #expect(check == ServerCheck.script)
        for n in 2...4 {
            let input = try String(contentsOf: standIn.folder.appendingPathComponent("stdin-\(n)"), encoding: .utf8)
            #expect(input.hasPrefix(secret + "\n"), "step \(n) did not carry the password first")
        }
        // The auth key comes after the password, on the same input.
        let network = try String(contentsOf: standIn.folder.appendingPathComponent("stdin-2"), encoding: .utf8)
        #expect(network == secret + "\ntskey-auth-kNMMmP9-secret")
        #expect(standIn.arguments.contains(secret) == false)
        // The stand-in printed what it was given: no kept line holds the password.
        for step in progress { #expect(step.lines.allSatisfy { !$0.contains(secret) }) }
        #expect(progress.contains { $0.step == "network" && $0.lines.contains { $0.contains("(not shown)") } })
        #expect(password.isEmpty, "the install kept the password after it ended")
    }

    @Test func withoutThePasswordASudoThatAsksForOneStopsAtTheCheck() async throws {
        let standIn = try StandInSSH(Self.sudoServer)
        await #expect(throws: InstallError.needsPassword(.sudo)) { _ = try await sudoJoin(standIn, password: nil) }
        #expect(standIn.programs == ["/bin/sh -s"])
        // A password that an earlier install cleared is no password.
        let cleared = PasswordOnce.Password("correct horse battery")
        cleared.clear()
        let again = try StandInSSH(Self.sudoServer)
        await #expect(throws: InstallError.needsPassword(.sudo)) { _ = try await sudoJoin(again, password: cleared) }
    }

    /// A `sudo` that asks nothing is never handed the password, which it would pass on to the program.
    @Test func aSudoThatAsksNothingIsNeverHandedThePassword() async throws {
        let standIn = try StandInSSH(Self.sudoServer.replacingOccurrences(of: "sudo=password", with: "sudo=nopasswd"))
        let password = PasswordOnce.Password("correct horse battery")
        _ = try await sudoJoin(standIn, password: password)
        #expect(standIn.programs.dropFirst().allSatisfy { $0.hasPrefix("sudo -n -i -- /bin/sh -c ") })
        #expect(standIn.inputs.contains("correct horse battery") == false)
        #expect(password.isEmpty)
    }

    @Test func aSudoWithAPasswordReadsItFromStandardInputAndNoArgument() {
        let plan = InstallPlan.join(target: InstallTarget(host: "h", user: "deploy", becomeRoot: true), line: "line",
                                    code: "CODE12345678", authKey: nil)
        #expect(plan.arguments(for: "tailscale ip -4", runs: .rootWithPassword).last
                == "sudo -S -k -p '' -i -- /bin/sh -c 'tailscale ip -4'")
        #expect(plan.arguments(for: "/bin/sh -s", runs: .login).last == "/bin/sh -s")
        // Root needs no sudo at all.
        let root = InstallPlan.join(target: InstallTarget(host: "h"), line: "line", code: "CODE12345678", authKey: nil)
        #expect(root.arguments(for: "tailscale ip -4", runs: .rootWithPassword).last == "tailscale ip -4")
    }

    /// A bare server may have no curl, which Tailscale's installer comes over: the install brings it first. Its
    /// `apt-get update` is tried again after 15 seconds when the first updates of the server hold the lock of the
    /// package lists. A try of the installer counts only when `tailscale` is there after it: a curl that gives no
    /// script leaves `sh` with 0, and that try is made again, three times at most.
    @Test func theTailscaleInstallBringsCurlToAServerWithout() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fleet-curl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Tailscale's installer as curl gives it: it puts `tailscale` where `command -v` looks in the case with curl.
        let installer = "echo tailscale-installed; ln -sf /usr/bin/true \(folder.path)/with/tailscale"
        // apt-get says what it got. Its first `update` finds the lock of the package lists held, as apt says it.
        let lists = "case \" $* \" in *\" update \"*) test -e \(folder.path)/listed || { : > \(folder.path)/listed; "
            + "echo 'E: Could not get lock /var/lib/apt/lists/lock.' >&2; exit 100; } ;; esac"
        for (name, text) in [("apt-get", "echo \"apt-get $*\" >> \"\(folder.path)/ran\"\n\(lists)"),
                             ("curl", "echo '\(installer)'"), ("sleep", "echo \"$1\" >> \"\(folder.path)/slept\"")] {
            let path = folder.appendingPathComponent(name).path
            try "#!/bin/sh\n\(text)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        func install(curl: Bool) throws -> (out: String, ran: String, slept: String) {
            for file in ["ran", "slept", "listed"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            }
            let shell = Process(), out = Pipe()
            shell.executableURL = URL(fileURLWithPath: "/bin/dash")
            shell.arguments = ["-c", InstallPlan.tailscaleInstall]
            // `command -v` looks only here: no tailscale, and curl when the case has it.
            let bin = folder.appendingPathComponent(curl ? "with" : "without")
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["apt-get", "sleep"] + (curl ? ["curl"] : []) {
                try? FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(name).path,
                                                            withDestinationPath: folder.appendingPathComponent(name).path)
            }
            shell.environment = ["PATH": bin.path + ":/bin"]
            shell.standardOutput = out; shell.standardError = out
            try shell.run(); shell.waitUntilExit()
            let read = { (name: String) in
                (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            }
            return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), read("ran"),
                    read("slept"))
        }
        let without = try install(curl: false)
        #expect(without.ran.contains("install curl ca-certificates"), "\(without)")
        // Its first `update` found the lock of the lists held, so it was tried again after 15 seconds.
        #expect(without.ran.split(separator: "\n").filter { $0.hasSuffix(" -q update") }.count == 2, "\(without)")
        // The stand-in apt-get brings no curl, so no try got a script: each one waited for the lock, three in all.
        #expect(without.ran.split(separator: "\n").filter { $0.hasSuffix(" -q install") }.count == 3, "\(without)")
        #expect(without.slept == "15\n20\n20\n20\n", "\(without)")
        let with = try install(curl: true)
        #expect(!with.ran.contains("install curl"), "apt-get installed curl on a server that has it")
        // Tailscale's installer runs apt-get with no wait of its own: the lock is waited for first.
        #expect(with.ran == "apt-get -o DPkg::Lock::Timeout=\(InstallPlan.aptLockWait) -q install\n", "\(with)")
        #expect(with.out.contains("tailscale-installed") && with.slept.isEmpty, "\(with)")
    }

    /// **The keyed network step's `tailscale up` has `--reset`, and waits 300 seconds at most**
    /// (`InstallPlan.keyedNetwork`). This app's own sign-in runs `tailscale up` with the tags of the hub's join line
    /// and no key (`NetworkSignIn`). When the tailnet refuses those tags, or nobody approves the link, the owner gives
    /// the key, and this step runs on the same machine. Tailscale kept the settings of the sign-in, and it refuses a
    /// `tailscale up` that does not name each of them again, unless it has `--reset`: until 11 November 2026 the key
    /// never brought such a machine up. With no `--timeout`, `tailscale up` waits for ever on a tailnet that approves
    /// each new machine by hand, until the step's own time ends, and the key file stays. Such a machine has its
    /// address already, but nothing reaches it there until an admin approves it: the step gives no address then, and
    /// ends with Tailscale's words. The step's own shell text runs under dash, with the stand-in `tailscale` of
    /// `NetworkPromptRootTests`.
    @Test func theKeyedNetworkStepBringsUpAMachineThatTheSignInLeftAndWaitsFiveMinutesAtMost() throws {
        guard case .sendAuthKey(let step) = InstallPlan.keyedNetwork,
              case .signIn(let start, _, _, _) = NetworkSignIn.action(install: "", tags: ["tag:founderizer"]) else {
            Issue.record("the keyed network step sends no key, or the sign-in is no sign-in")
            return
        }
        let up = try #require(start.range(of: "tailscale up [^;']*", options: .regularExpression))
        let signIn = start[up].split(separator: " ").dropFirst(2).map(String.init)
        for approval in [false, true] {
            let folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fleet-keyed-" + UUID().uuidString)
            let bin = folder.appendingPathComponent("bin"), state = folder.appendingPathComponent("state")
            for part in [bin, state] {
                try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: folder) }
            let tailscale = bin.appendingPathComponent("tailscale")
            try NetworkPromptRootTests.StandInServer.tailscale.write(to: tailscale, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tailscale.path)
            let kept = try NetworkPromptRootTests.StandInServer.earlierUp(signIn, tailscale: tailscale, state: state)
            #expect(kept.contains("--advertise-tags=tag:founderizer"), "the sign-in kept \(kept)")
            if approval { try Data("yes\n".utf8).write(to: state.appendingPathComponent("approval")) }
            let keyFile = folder.appendingPathComponent("fleet-authkey"), input = folder.appendingPathComponent("input")
            try "tskey-auth-k0000-secret\n".write(to: input, atomically: true, encoding: .utf8)
            let shell = Process(), out = Pipe()
            shell.executableURL = URL(fileURLWithPath: "/bin/dash")
            shell.arguments = ["-c", step.replacingOccurrences(of: InstallPlan.authKeyFile, with: keyFile.path)]
            shell.environment = ["PATH": bin.path + ":/bin", "STATE": state.path]
            shell.standardInput = try FileHandle(forReadingFrom: input)
            shell.standardOutput = out; shell.standardError = out
            try shell.run(); shell.waitUntilExit()
            let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let read = { (name: String) in
                (try? String(contentsOf: state.appendingPathComponent(name), encoding: .utf8)) ?? ""
            }
            let who = approval ? "on a tailnet that approves each machine by hand" : "after the sign-in"
            #expect(read("key") == "tskey-auth-k0000-secret\n", "\(who): Tailscale got no key: \(said)")
            #expect(!FileManager.default.fileExists(atPath: keyFile.path), "\(who): the key file stayed")
            #expect(read("up-waits") == "300s\n", "\(who): tailscale up waited \(read("up-waits")), not 300s at most")
            if approval {
                let last = said.split(separator: "\n").last.map(String.init) ?? ""
                #expect(shell.terminationStatus != 0
                        && last.hasPrefix("timeout waiting for Tailscale service to enter a Running state")
                        && !said.contains("waits here for ever") && !said.contains("100.64.2.1"), "\(who): \(said)")
            } else {
                #expect(shell.terminationStatus == 0 && said.hasSuffix("100.64.2.1\n"), "\(who): \(said)")
            }
        }
    }

    /// **A hub with no key takes the address of its machine only while Tailscale runs there** (`InstallPlan.onNetwork`).
    /// A machine that waits for an admin's approval (NeedsMachineAuth) has its address already: `tailscale ip -4` prints
    /// it. Only `tailscale status` says that Tailscale does not run. Until 11 November 2026 the step took that address,
    /// and the install went on to it. Nothing answered there, so the owner got an SSH time-out. Now the step ends with
    /// Tailscale's own line for such a machine, and the app does not ask for a key: the machine waits for the approval.
    /// A machine with no sign-in, with a stopped Tailscale or with no Tailscale still gets the question for the key.
    /// The step's shell text runs under this Mac's `/bin/sh` and under dash, with the stand-in `tailscale` of
    /// `NetworkPromptRootTests`. `RootThroughSudoTests` proves that the same text reaches `/bin/sh` unchanged through
    /// `sudo`.
    @Test func aHubWithNoKeyTakesTheAddressOnlyWhileTailscaleRuns() throws {
        let plan = InstallPlan.hub(target: InstallTarget(host: "198.51.100.7"), source: InstallPlan.defaultSource,
                                   authKey: nil)
        let network = try #require(plan.steps.first { $0.id == "network" })
        guard case .run(let program) = network.action else {
            Issue.record("the network step of a hub with no key runs no program")
            return
        }
        // Each machine: whether it has Tailscale, and the state that the stand-in keeps for it (none: no sign-in).
        let machines: [(who: String, tailscale: Bool, backend: String?)] = [
            ("a machine where Tailscale runs", true, "Running"),
            ("a machine that waits for an admin's approval", true, "NeedsMachineAuth"),
            ("a machine with no sign-in", true, nil),
            ("a machine where Tailscale is stopped", true, "Stopped"),
            ("a machine with no Tailscale", false, nil)]
        for sh in NetworkPromptRootTests.shells {
            for machine in machines {
                let folder = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("fleet-on-network-" + UUID().uuidString)
                let bin = folder.appendingPathComponent("bin"), state = folder.appendingPathComponent("state")
                for part in [bin, state] {
                    try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
                }
                defer { try? FileManager.default.removeItem(at: folder) }
                if machine.tailscale {
                    let tailscale = bin.appendingPathComponent("tailscale")
                    try NetworkPromptRootTests.StandInServer.tailscale.write(to: tailscale, atomically: true,
                                                                             encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tailscale.path)
                }
                if let backend = machine.backend {
                    try "\(backend)\n".write(to: state.appendingPathComponent("backend"), atomically: true,
                                             encoding: .utf8)
                }
                let shell = Process(), out = Pipe()
                shell.executableURL = URL(fileURLWithPath: sh)
                shell.arguments = ["-c", program]
                shell.environment = ["PATH": bin.path + ":/usr/bin:/bin", "STATE": state.path]
                shell.standardInput = FileHandle.nullDevice
                shell.standardOutput = out; shell.standardError = out
                try shell.run(); shell.waitUntilExit()
                let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let last = said.split(separator: "\n").last.map(String.init) ?? ""
                // The stop as the app reads it: the runner keeps the step's last line (`MachineInstaller`), and the
                // screen asks for the key when `needsNetworkKey` finds it in the whole stop (`MachineInstallModel`).
                let stop = InstallError.step(network.title, last)
                let asksForKey = InstallPlan.needsNetworkKey(stop.errorDescription ?? "")
                let who = "\(machine.who), under \(sh)"
                switch machine.backend {
                case "Running":
                    #expect(shell.terminationStatus == 0 && said == "100.64.2.1\n", "\(who): \(said)")
                    #expect(InstallPlan.privateAddress(in: [last]) == "100.64.2.1", "\(who): \(said)")
                case "NeedsMachineAuth":
                    #expect(shell.terminationStatus != 0 && !said.contains("100.64.2.1"), "\(who): \(said)")
                    #expect(last == "Machine is not yet approved by tailnet admin." && !asksForKey, "\(who): \(said)")
                    #expect(stop.plain(host: "198.51.100.7") == "It stopped at “\(network.title)”.", "\(who)")
                default:
                    #expect(shell.terminationStatus != 0 && last == NetworkSignIn.notOnNetwork && asksForKey,
                            "\(who): \(said)")
                }
            }
        }
    }

    /// **The code step's git comes only after an update that worked, and `apt-get update` gets up to 10 tries, 15
    /// seconds apart** (`InstallPlan.gitInstall`, INSTALL-PROMPT.md A3's first line). `update` tries the lock of the
    /// package lists once, and the first updates of a new server hold it while they read the lists.
    @Test func theGitInstallGivesAptGetUpdateTenTries() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fleet-git-" + UUID().uuidString)
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // apt-get says what it got. Its `update` finds the lock of the lists held while `stops` has tries left.
        let apt = "echo \"apt-get $*\" >> \(folder.path)/ran\ncase \" $* \" in *\" update \"*)\n"
            + "  n=$(cat \(folder.path)/stops)\n"
            + "  if [ \"$n\" -gt 0 ]; then echo \"$((n - 1))\" > \(folder.path)/stops\n"
            + "    echo 'E: Could not get lock /var/lib/apt/lists/lock.' >&2; exit 100; fi ;;\nesac"
        for (name, text) in [("apt-get", apt), ("sleep", "echo \"$1\" >> \(folder.path)/slept")] {
            let path = bin.appendingPathComponent(name).path
            try "#!/bin/sh\n\(text)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        for (stops, installs) in [(1, true), (9, true), (10, false)] {
            for file in ["ran", "slept"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            }
            try "\(stops)\n".write(to: folder.appendingPathComponent("stops"), atomically: true, encoding: .utf8)
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/dash")
            shell.arguments = ["-c", InstallPlan.gitInstall]
            shell.environment = ["PATH": bin.path + ":/bin"]     // no git here
            shell.standardOutput = FileHandle.nullDevice; shell.standardError = FileHandle.nullDevice
            try shell.run(); shell.waitUntilExit()
            let read = { (name: String) in
                (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            }
            let ran = read("ran").split(separator: "\n")
            #expect(ran.filter { $0.hasSuffix(" -q update") }.count == min(stops + 1, 10), "\(stops): \(ran)")
            #expect(ran.contains { $0.hasSuffix(" install git") } == installs, "\(stops): \(ran)")
            #expect(read("slept") == String(repeating: "15\n", count: min(stops, 9)), "\(stops): \(read("slept"))")
            #expect(shell.terminationStatus == (installs ? 0 : 100), "\(stops): \(shell.terminationStatus)")
        }
    }

    @Test func aKeyIsLookedForInThePersonsOwnSshFolder() {
        #expect(InstallTarget.keyFolder.path == NSHomeDirectory() + "/.ssh")
    }

    /// **A stop in a few plain words** (fix round 3, item 51): `ssh`'s and the machine's own last line are not his.
    @Test func aStopIsSaidInAFewPlainWords() {
        let host = "203.0.113.9"
        #expect(InstallError.step("Read the server", "ssh: connect to host 203.0.113.9 port 22: Connection refused")
                    .plain(host: host) == "This Mac could not reach 203.0.113.9 over SSH.")
        #expect(InstallError.step("Read the server", "ssh: Could not resolve hostname box: nodename nor servname provided")
                    .plain(host: "box") == "This Mac could not reach box over SSH.")
        #expect(InstallError.step("Read the server", "The server answered 255.").plain(host: host)
                    == "This Mac could not reach 203.0.113.9 over SSH.")
        #expect(InstallError.step("Read the server", "root@203.0.113.9: Permission denied (publickey).").plain(host: host)
                    == "203.0.113.9 did not take your SSH key. Choose its key.")
        #expect(InstallError.step("Read the server", "Received disconnect from 203.0.113.9 port 22:2: Too many "
                                  + "authentication failures").plain(host: host)
                    == "203.0.113.9 did not take your SSH key. Choose its key.")
        // The installer's own reason, and this app's own line, are his words already.
        #expect(InstallError.step("Finish the install", "Founderizer install stopped: the disk is full.").plain(host: host)
                    == "The disk is full.")
        for systems in [InstallPlan.joinSystems, InstallPlan.hubSystems] {
            #expect(InstallError.step("Read the server", systems).plain(host: host) == systems)
        }
        // A package mirror that timed out on the server is not this Mac failing to reach it: where it stopped.
        #expect(InstallError.step("Install the hub", "E: Failed to fetch http://deb.example/x  Connection timed out")
                    .plain(host: host) == "It stopped at “Install the hub”.")
        #expect(InstallError.notRoot("deploy").plain(host: host) == InstallError.notRoot("deploy").errorDescription)
    }
}
