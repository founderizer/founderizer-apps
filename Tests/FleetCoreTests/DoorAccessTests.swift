import Foundation
import Testing
@testable import FleetCore

/// The door's access file as this Mac keeps it by itself (DevOps plan C5, D8 "Servers go by business"): a server's
/// business is its `tag:business-<name>`, the business's DevOps agent is the one agent alone on the box with its
/// `tag:operator-<name>`, and both come from this Mac's own Tailscale, never from the hub. The rest of the file stays as
/// the owner's Mac session wrote it. The tags of the policy are not on the devices yet (plan 2.27), so these read
/// fixtures.
struct DoorAccessTests {
    static let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    static func peer(_ name: String, _ address: String, _ tags: [String]) -> String {
        let list = tags.map { "\"\($0)\"" }.joined(separator: ", ")
        return #""\#(name)": {"DNSName": "\#(name).tail0.ts.net.", "HostName": "x-\#(name)", "TailscaleIPs": ["\#(address)", "fd7a:115c::1"], "Tags": [\#(list)]}"#
    }

    static func status(_ more: [String] = []) -> String {
        let peers = [peer("door", "100.64.0.5", ["tag:door"]),
                     peer("web-1", "100.64.1.1", ["tag:business-one", "tag:hetzner-server"]),
                     peer("web-2", "100.64.2.1", ["tag:business-two"]),
                     peer("shared-1", "100.64.1.9", ["tag:business-one", "tag:business-two", "tag:ci-runner"]),
                     peer("fleet-1", "100.64.1.4", ["tag:business-one", "tag:fleet"]),
                     peer("site-1", "100.64.1.6", ["tag:business-one"]),
                     peer("new-1", "100.64.1.7", ["tag:business-one"]),
                     peer("box-one", "100.64.0.11", ["tag:fleet", "tag:operator-one"]),
                     peer("box-two", "100.64.0.12", ["tag:fleet", "tag:operator-two"]),
                     peer("box-hub", "100.64.0.13", ["tag:fleet"]),
                     peer("laptop", "100.64.0.20", [])] + more
        return """
            {"BackendState": "Running",
             "Self": {"DNSName": "owners-mac.tail0.ts.net.", "TailscaleIPs": ["100.64.0.1"]},
             "Peer": {\(peers.joined(separator: ",\n"))}}
            """
    }

    static var access: [String: Any] {
        DoorAccess.file(#"""
            {"v": 1, "hub": {"address": "100.64.0.2", "port": 8765},
             "agents": {"ops-one": {"address": "100.64.0.11", "business": "one", "github": {"one-org/ops": "read"}},
                        "ops-two": {"business": "two"},
                        "builder": {"address": "100.64.0.13", "business": "one", "servers": {"old-1": "fix"}}},
             "hosts": {"old-1": {"address": "100.64.1.99", "port": 2244, "host_key": "\#(key)", "business": "one", "mode": "fix", "kind": "app"}},
             "credentials": {"cloudflare:one": {"secret": "bws://00000001-0000-4000-8000-000000000000", "account_id": "b"}},
             "never": {"hosts": ["site-1"]},
             "pools": {"one": {"one-org/tools": "write"}}}
            """#)!
    }

    static var devices: [DoorAccess.Device] { DoorAccess.devices(status: status()) }

    static func readings(_ names: [String]) -> [String: DoorAccess.HostReading] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, DoorAccess.HostReading(hostKey: key, mode: "fix", fleet: name == "fleet-1"))
        })
    }

    static let both: [String: DoorAccess.Operator?] = ["one": DoorAccess.Operator(agent: "ops-one", address: "100.64.0.11"),
                                                       "two": DoorAccess.Operator(agent: "ops-two", address: "100.64.0.12")]

    static func facts(hosts: [String] = ["web-1", "web-2", "shared-1", "fleet-1"],
                      operators: [String: DoorAccess.Operator?] = both) -> DoorAccess.Facts {
        DoorAccess.Facts(devices: devices, hosts: readings(hosts), operators: operators)
    }

    static func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    static func agent(_ file: [String: Any], _ name: String) -> [String: Any] {
        (file["agents"] as? [String: Any])?[name] as? [String: Any] ?? [:]
    }

    @Test func theDoorTheServersAndTheOperatorBoxesComeFromThisMacsTailscale() {
        let devices = Self.devices
        #expect(devices.first { $0.name == "web-1" }?.address == "100.64.1.1")
        #expect(devices.first { $0.name == "shared-1" }?.businesses == ["one", "two"])
        #expect(DoorAccess.door(in: devices)?.address == "100.64.0.5")
        #expect(DoorAccess.door(in: DoorAccess.devices(status: Self.status([Self.peer("door-2", "100.64.0.6", ["tag:door"])]))) == nil)
        let boxes = DoorAccess.operatorBoxes(devices: devices)
        #expect(boxes["one"]??.name == "box-one")
        #expect(boxes["two"]??.name == "box-two")
        #expect(DoorAccess.devices(status: "not json").isEmpty)
    }

    @Test func anOperatorTagThatTwoBoxesCarryOrABoxOfTwoBusinessesNamesNoBox() {
        let twice = DoorAccess.operatorBoxes(devices: DoorAccess.devices(status: Self.status([
            Self.peer("box-x", "100.64.0.31", ["tag:operator-one"])])))
        #expect(twice["one"] != nil && twice["one"]! == nil)
        let double = DoorAccess.operatorBoxes(devices: DoorAccess.devices(status: Self.status([
            Self.peer("box-y", "100.64.0.32", ["tag:operator-three", "tag:operator-four"])])))
        #expect(double["three"]! == nil && double["four"]! == nil)
    }

    @Test func theOperatorsNameIsTheOneAgentUserOnItsBox() {
        #expect(DoorAccess.operatorAgent(users: DoorAccess.boxUsers(output: "fleet-ops-one\n")) == "ops-one")
        #expect(DoorAccess.operatorAgent(users: DoorAccess.boxUsers(output: "fleet-ops-one,fleet-builder\n")) == nil)
        #expect(DoorAccess.operatorAgent(users: DoorAccess.boxUsers(output: "\n")) == nil)
        #expect(DoorAccess.operatorAgent(users: ["root"]) == nil)
        #expect(DoorAccess.operatorAgent(users: ["fleet-Bad_Name"]) == nil)
    }

    @Test func eachBusinessServerGoesToItsOperatorAtFixAndNoOtherAgentHoldsOne() {
        let plan = DoorAccess.plan(current: Self.access, facts: Self.facts())
        let file = Self.object(plan.file)
        #expect(Self.agent(file, "ops-one")["servers"] as? [String: String] == ["web-1": "fix", "shared-1": "fix", "fleet-1": "fix"])
        #expect(Self.agent(file, "ops-two")["servers"] as? [String: String] == ["web-2": "fix", "shared-1": "fix"])
        #expect(Self.agent(file, "ops-two")["address"] as? String == "100.64.0.12")
        #expect(plan.holdings == ["ops-one": ["web-1": "fix", "shared-1": "fix", "fleet-1": "fix"],
                                  "ops-two": ["web-2": "fix", "shared-1": "fix"]])
        #expect(Self.agent(file, "builder")["servers"] == nil)
        #expect(Self.agent(file, "builder")["address"] as? String == "100.64.0.13")
        #expect(Self.agent(file, "ops-one")["github"] as? [String: String] == ["one-org/ops": "read"])
        #expect(plan.changed)
    }

    static func hubDoor(credentials: [String: DoorAccess.HubDoor.Credential] = [:],
                        agents: [String: DoorAccess.HubDoor.Agent] = [
                            "otto": .init(address: "100.64.0.11", user: "fleet-ops-one"),
                            "theo": .init(address: "100.64.0.12", user: "fleet-someone-else")]) -> DoorAccess.HubDoor {
        DoorAccess.HubDoor(door: .init(address: "100.64.0.5", port: 8766), credentials: credentials, agents: agents, db: "g")
    }

    /// DevOps plan 13, item 3: an Operator's entry takes the hub's name when the hub shows the box's own OS user at the
    /// box's address, with every field of its entry. The box still decides who operates, so a name that the hub gives
    /// to another OS user changes nothing.
    @Test func anOperatorTakesTheHubsNameForTheAgentThatItsBoxShows() {
        var facts = Self.facts()
        facts.hub = Self.hubDoor()
        let plan = DoorAccess.plan(current: Self.access, facts: facts)
        let file = Self.object(plan.file)
        #expect(Self.agent(file, "ops-one").isEmpty)
        #expect(Self.agent(file, "otto")["github"] as? [String: String] == ["one-org/ops": "read"])
        #expect(Self.agent(file, "otto")["servers"] as? [String: String] == ["web-1": "fix", "shared-1": "fix", "fleet-1": "fix"])
        #expect(Self.agent(file, "ops-two")["address"] as? String == "100.64.0.12")     // theo's helper names another user
        #expect(Self.agent(file, "theo").isEmpty)
        #expect(plan.holdings["otto"] != nil && plan.holdings["ops-one"] == nil)
    }

    /// API 1.101: the manager's door_hold. A server held at parts gets no entry, so nobody holds it through the door; one
    /// held at rule-only keeps its entry and its Operator, as rule-only, so only rule calls run there. judged is the old
    /// name of rule-only, which a hub still gives for a hold that it kept from before, and it reads the same.
    @Test func aHeldServerGetsNoEntryOrIsRuleOnly() {
        var facts = Self.facts()
        var hub = Self.hubDoor()
        for name in ["rule-only", "judged"] {
            hub.holds = ["web-1": name, "web-2": "parts"]
            facts.hub = hub
            let file = Self.object(DoorAccess.plan(current: Self.access, facts: facts).file)
            let hosts = file["hosts"] as? [String: Any] ?? [:]
            #expect((hosts["web-1"] as? [String: Any])?["mode"] as? String == "rule-only", "\(name)")
            #expect(hosts["web-2"] == nil)
            #expect(Self.agent(file, "otto")["servers"] as? [String: String] == ["web-1": "fix", "shared-1": "fix", "fleet-1": "fix"])
            #expect((Self.agent(file, "ops-two")["servers"] as? [String: String])?["web-2"] == nil)
            #expect(hub.heldOut == ["web-2"] && hub.ruleOnly == ["web-1"], "\(name)")
        }
        hub.holds = nil
        #expect(hub.heldOut.isEmpty && hub.digest != { var held = hub; held.holds = ["web-2": "parts"]; return held.digest }())
    }

    /// DevOps plan 13, item 3: a key that a card asked for the door is written with its secret and keeps its other
    /// fields, and it is in the providers of each agent that the hub names. One that the hub no longer lists goes, and
    /// the door's other credentials and providers stay. Without the hub's view the file keeps what it has.
    @Test func eachKeyThatACardAskedForTheDoorIsInItsRulesForTheAgentThatAsked() {
        var current = Self.access
        var agents = current["agents"] as! [String: Any]
        var one = agents["ops-one"] as! [String: Any]
        one["providers"] = ["aws:one", "hetzner:old"]
        agents["ops-one"] = one
        current["agents"] = agents
        var credentials = current["credentials"] as! [String: Any]
        credentials["aws:one"] = ["role": "arn:aws:iam::1:role/door"]
        credentials["hetzner:old"] = ["secret": "bws://00000003-0000-4000-8000-000000000000"]
        current["credentials"] = credentials
        var facts = Self.facts()
        facts.hub = Self.hubDoor(credentials: [
            "cloudflare:one": .init(secret: "bws://00000002-0000-4000-8000-000000000000", agents: ["otto"]),
            "model": .init(secret: "bws://00000004-0000-4000-8000-000000000000", agents: []),
            "app:shop:STRIPE_SECRET_KEY": .init(secret: "bws://00000005-0000-4000-8000-000000000000", agents: ["otto"]),
            "app:shop:lower": .init(secret: "bws://00000006-0000-4000-8000-000000000000", agents: ["otto"]),
            "app:Shop:KEY": .init(secret: "bws://00000007-0000-4000-8000-000000000000", agents: ["otto"])])
        let file = Self.object(DoorAccess.plan(current: current, facts: facts).file)
        let written = file["credentials"] as? [String: Any] ?? [:]
        #expect(written["cloudflare:one"] as? [String: String]
                == ["secret": "bws://00000002-0000-4000-8000-000000000000", "account_id": "b"])
        // the door calls no model since 11 November 2026: model is a name that it does not know, so it never reaches it
        #expect(written["model"] == nil && written["aws:one"] != nil && written["hetzner:old"] == nil)
        // new-projects plan N4: an app's setting is app:<app>:<NAME>, and a name of another shape never reaches the door
        #expect(written["app:shop:STRIPE_SECRET_KEY"] as? [String: String]
                == ["secret": "bws://00000005-0000-4000-8000-000000000000"])
        #expect(written["app:shop:lower"] == nil && written["app:Shop:KEY"] == nil)
        #expect(Self.agent(file, "otto")["providers"] as? [String] == ["app:shop:STRIPE_SECRET_KEY", "aws:one", "cloudflare:one"])
        #expect(Self.agent(file, "builder")["providers"] == nil)
        let kept = Self.object(DoorAccess.plan(current: current, facts: Self.facts()).file)["credentials"] as? NSDictionary
        #expect(kept == credentials as NSDictionary)
    }

    /// API 1.99: the door's own vault key, read over SSH, is pinned when the hub reads the central vault and holds
    /// another key under door, or none; a hub with no status of the central vault, or from before, pins nothing.
    @Test func theDoorsVaultKeyIsPinnedWhenTheCentralVaultHoldsAnotherOrNone() throws {
        let key = "age1" + String(repeating: "q", count: 58)
        #expect(DoorAccess.recipient(key + "\n") == key)
        #expect(DoorAccess.recipient("") == nil && DoorAccess.recipient(key + "\n" + key) == nil)
        #expect(DoorAccess.recipient("AGE-SECRET-KEY-1QQQ") == nil && DoorAccess.recipient("age1short") == nil)
        func view(_ more: String) throws -> DoorAccess.HubDoor {
            try JSONDecoder().decode(DoorAccess.HubDoor.self,
                                     from: Data(#"{"door": null, "credentials": {}, "agents": {}, "db": "g"\#(more)}"#.utf8))
        }
        #expect(try !view("").needsPin(of: key))                               // a hub before API 1.99
        #expect(try !view(#", "vault_pin": null, "vault_read": false"#).needsPin(of: key))
        #expect(try view(#", "vault_pin": null, "vault_read": true"#).needsPin(of: key))
        #expect(try view(#", "vault_pin": "age1other", "vault_read": true"#).needsPin(of: key))
        #expect(try !view(#", "vault_pin": "\#(key)", "vault_read": true"#).needsPin(of: key))
        #expect(try view(#", "vault_pin": null, "vault_read": true"#).digest
                != view(#", "vault_pin": "\#(key)", "vault_read": true"#).digest)
    }

    /// DevOps plan 13, item 4: once the hub asks the door for every token, the door makes them from each agent's grants
    /// as the hub gives them. An Operator's entry gets its grants in place of the old ones; an agent with no entry gets
    /// one with its grants alone only when the door's code takes such an entry; a name the door refuses is left out.
    @Test func eachAgentsGitHubGrantsComeFromTheHub() {
        var facts = Self.facts()
        facts.hub = Self.hubDoor(agents: [
            "otto": .init(address: "100.64.0.11", user: "fleet-ops-one", repos: ["one-org/ops": "write", "bad name": "read"]),
            "mia": .init(address: "100.64.0.40", user: "fleet-mia", repos: ["one-org/shop": "deploy", "one-org/x": "admin"]),
            "kai": .init(address: "100.64.0.41", user: "fleet-kai", repos: [:])])
        var plan = DoorAccess.plan(current: Self.access, facts: facts)
        var file = Self.object(plan.file)
        #expect(Self.agent(file, "otto")["github"] as? [String: String] == ["one-org/ops": "write"])
        #expect(Self.agent(file, "mia").isEmpty)                        // the door's code does not take it yet
        // so the round says no word that the file holds the hub's view (API 1.234): a restart for mia's grant would
        // start with no token. kai has no grant to leave out.
        #expect(plan.leftOut == ["mia"])
        facts.tokensOnly = true
        plan = DoorAccess.plan(current: Self.access, facts: facts)
        file = Self.object(plan.file)
        #expect(Self.agent(file, "mia") as NSDictionary == ["github": ["one-org/shop": "deploy"]] as NSDictionary)
        #expect(Self.agent(file, "kai").isEmpty)
        #expect(plan.leftOut.isEmpty)
        #expect(Self.agent(file, "builder")["address"] as? String == "100.64.0.13")     // not the hub's: it stays
    }

    /// Plan 13, item 4: an App uses one key for all its installations, so the new key of an App becomes the key of
    /// each account of that App, and the credential of another App stays.
    @Test func anAppsNewKeyBecomesTheKeyOfEachOfItsAccounts() {
        let old = "bws://00000005-0000-4000-8000-000000000000", new = "bws://00000006-0000-4000-8000-000000000000"
        var access = Self.access
        access["credentials"] = ["github:One-Org": ["secret": old, "app_id": "42"],
                                 "github:solo": ["secret": old, "app_id": "42"],
                                 "github:other": ["secret": "bws://00000007-0000-4000-8000-000000000000", "app_id": "7"]]
        let file = DoorAccess.withGitHubApp(access, owner: "one-org", login: new, appID: "42")
        let credentials = file["credentials"] as? [String: [String: String]] ?? [:]
        #expect(credentials["github:one-org"] == ["secret": new, "app_id": "42"])
        #expect(credentials["github:One-Org"] == nil)
        #expect(credentials["github:solo"]?["secret"] == new)
        #expect(credentials["github:other"]?["secret"] == "bws://00000007-0000-4000-8000-000000000000")
    }

    /// New-projects plan N8, in DevOps plan 5.12: each Operator's GitHub entries come from the hub's grants. Its reads
    /// reach each account of which the door holds an App, and it gets a commit target of kind app for each repository
    /// that it holds and that no other agent writes. A target that the app did not write stays.
    @Test func anOperatorsGitHubProvidersAndCommitTargetsComeFromTheHubsGrants() {
        var access = DoorAccess.withGitHubApp(Self.access, owner: "One-Org", login: "bws://00000005-0000-4000-8000-000000000000",
                                              appID: "42")
        var agents = access["agents"] as? [String: Any] ?? [:]
        var one = agents["ops-one"] as? [String: Any] ?? [:]
        one["providers"] = ["github:old", "aws:one"]
        one["repos"] = ["one-org/records": ["kind": "devops"], "one-org/cluster": ["kind": "gitops", "sync": "sync.yml"],
                        "one-org/shop": ["kind": "app", "deploy": "deploy.yml"], "one-org/gone": ["kind": "app"]]
        agents["ops-one"] = one
        access["agents"] = agents
        var facts = Self.facts()
        facts.hub = Self.hubDoor(agents: [
            "otto": .init(address: "100.64.0.11", user: "fleet-ops-one",
                          repos: ["one-org/records": "read", "one-org/shop": "read", "one-org/new": "read", "other/x": "read"]),
            "mia": .init(address: "100.64.0.40", user: "fleet-mia", repos: ["one-org/shop": "write", "one-org/new2": "deploy"])])
        let file = Self.object(DoorAccess.plan(current: access, facts: facts).file)
        let otto = Self.agent(file, "otto")
        #expect(otto["providers"] as? [String] == ["aws:one", "github:One-Org"])
        let targets = otto["repos"] as? [String: [String: String]] ?? [:]
        #expect(targets["one-org/records"] == ["kind": "app"])                  // its records commits: checked forms or own calls
        #expect(targets["one-org/new"] == ["kind": "app"])
        #expect(targets["other/x"] == ["kind": "app"])
        #expect(targets["one-org/shop"] == ["kind": "app", "deploy": "deploy.yml"])    // mia writes it: kept as written
        #expect(targets["one-org/cluster"] == ["kind": "gitops", "sync": "sync.yml"])
        #expect(targets["one-org/gone"] == nil && targets["one-org/new2"] == nil)
        #expect(Self.agent(file, "mia")["repos"] == nil && Self.agent(file, "mia")["providers"] == nil)
    }

    /// DevOps plan X3 (API 1.111): the manager's door_gitops gives Operators a GitOps repository through the door, with
    /// no GitHub grant. Each named agent of the file gets {kind: gitops, sync} in place of a target of another kind for
    /// that repository, a GitOps target that the hub no longer gives goes, and a name that the file does not hold, or a
    /// caller that is no file name, gives nothing. A hub before 1.111 leaves the file's GitOps targets as they are.
    @Test func theManagersGitOpsRepositoryBecomesItsOperatorsTargetWithItsCaller() {
        var access = Self.access
        var agents = access["agents"] as? [String: Any] ?? [:]
        var one = agents["ops-one"] as? [String: Any] ?? [:]
        one["repos"] = ["one-org/cluster": ["kind": "gitops", "sync": "old.yml"],
                        "Acme/GitOps": ["kind": "app", "deploy": "deploy.yml"]]
        agents["ops-one"] = one
        access["agents"] = agents
        var facts = Self.facts()
        var hub = Self.hubDoor(agents: ["otto": .init(address: "100.64.0.11", user: "fleet-ops-one")])
        hub.gitops = ["acme/gitops": .init(sync: "argocd-sync.yml", agents: ["otto", "nobody"]),
                      "acme/bad": .init(sync: "../dispatches", agents: ["otto"])]
        facts.hub = hub
        let file = Self.object(DoorAccess.plan(current: access, facts: facts).file)
        let targets = Self.agent(file, "otto")["repos"] as? [String: [String: String]] ?? [:]
        #expect(targets == ["acme/gitops": ["kind": "gitops", "sync": "argocd-sync.yml"]])
        #expect(Self.agent(file, "nobody").isEmpty)
        let given = hub.digest
        hub.gitops = nil
        facts.hub = hub
        #expect(hub.digest != given)
        let before = Self.object(DoorAccess.plan(current: access, facts: facts).file)
        let kept = Self.agent(before, "otto")["repos"] as? [String: [String: String]] ?? [:]
        #expect(kept["one-org/cluster"] == ["kind": "gitops", "sync": "old.yml"])
        #expect(kept["Acme/GitOps"] == ["kind": "app", "deploy": "deploy.yml"])
    }

    /// The vault takes the App key only as one line with no white space, which it can fingerprint.
    @Test func anAppKeyGoesToTheVaultAsOneLineThatHasAFingerprint() throws {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAx\n-----END RSA PRIVATE KEY-----\n"
        let value = GitHubAppKey.vaultValue(pem)
        #expect(value.hasPrefix("pem:") && !value.contains(where: \.isWhitespace) && value.count >= 8)
        #expect(Data(base64Encoded: String(value.dropFirst(4))).map { String(decoding: $0, as: UTF8.self) } == pem)
        var secret = LoginSecret()
        secret.kind = .apiKey
        secret.env = GitHubAppKey.variable(owner: "One-Org")
        secret.password = value
        #expect(secret.problem == nil)
        let salts = SecretSalts(login: "bws://00000005-0000-4000-8000-000000000000", password: String(repeating: "a", count: 32),
                                totp: String(repeating: "b", count: 32))
        #expect(try SecretFingerprint.of(try secret.value(), salts: salts).count == 1)
        secret.password = pem
        #expect(try SecretFingerprint.of(try secret.value(), salts: salts).isEmpty)       // why it was refused
    }

    @Test func theDoorsAppKeysAndTheProgramsOfTheMove() {
        let access = DoorAccess.withGitHubApp(Self.access, owner: "One-Org", login: "bws://00000005-0000-4000-8000-000000000000",
                                              appID: "42")
        #expect(DoorAccess.gitHubApps(access).map(\.owner) == ["One-Org"])
        #expect(DoorAccess.gitHubApps(access).first?.appID == "42")
        let held = DoorAccess.heldProgram(login: "bws://00000005-0000-4000-8000-000000000000")
        #expect(held?.hasPrefix("test -s /var/lib/fleet-door/secrets/") == true && held?.contains("held=yes") == true)
        #expect(DoorAccess.heldProgram(login: "bws://x; rm -rf /") == nil)
        #expect(DoorAccess.tokensProbe.contains("tokens_only"))
    }

    /// DevOps plan 13, item 2: a door with no follow timer yet takes the hub's release once, through its own root
    /// command; the hub's address comes from the door's file and goes into a shell line only when it is an address.
    @Test func aDoorWithNoFollowTimerTakesTheHubsReleaseOnce() {
        let program = DoorAccess.followProgram(hub: "100.64.0.2", port: 8765)
        #expect(program?.contains("'http://100.64.0.2:8765/door/release' | /usr/local/sbin/door-update") == true)
        #expect(program?.contains("is-enabled fleet-door-follow.timer") == true)
        #expect(DoorAccess.followProgram(hub: "100.64.0.2; rm -rf /", port: 8765) == nil)
        #expect(DoorAccess.followProgram(hub: "100.64.0.2", port: 0) == nil)
    }

    @Test func theHubsViewOfTheDoorDecodes() throws {
        let json = #"{"door": {"address": "100.64.0.5", "port": 8766}, "credentials": {"cloudflare:one": {"secret": "bws://00000002-0000-4000-8000-000000000000", "agents": ["otto"]}}, "agents": {"otto": {"address": "100.64.0.11", "user": "fleet-ops-one"}, "manager": {"address": "100.64.0.13", "user": null}}, "db": "g"}"#
        let view = try JSONDecoder().decode(DoorAccess.HubDoor.self, from: Data(json.utf8))
        #expect(view.door == .init(address: "100.64.0.5", port: 8766))
        #expect(view.name(of: .init(agent: "ops-one", address: "100.64.0.11")) == "otto")
        #expect(view.name(of: .init(agent: "ops-one", address: "100.64.0.99")) == nil)
        let none = try JSONDecoder().decode(DoorAccess.HubDoor.self, from: Data(#"{"door": null, "credentials": {}, "agents": {}, "db": "g"}"#.utf8))
        #expect(none.door == nil)
        #expect(none.mark == nil)
        let marked = #"{"door": null, "credentials": {}, "agents": {}, "db": "g", "mark": "0123456789abcdef0123456789abcdef"}"#
        #expect(try JSONDecoder().decode(DoorAccess.HubDoor.self, from: Data(marked.utf8)).mark == "0123456789abcdef0123456789abcdef")
    }

    /// API 1.234: each read of `GET /ui/door` by this app says which view the door's file holds (`held`), empty when
    /// it names none, as the GitHub App flow's read does. A read with no `held` is an app before that word, for which
    /// the hub takes two reads after a grant as the door having it: a read that loses the word ends a restart's wait
    /// while the door's file may not have the grant yet, and the new session has no token.
    @Test func eachReadOfTheHubsViewSaysWhatTheDoorsFileHolds() throws {
        func items(_ held: String) throws -> [String: String] {
            let url = DoorSetupClient.viewURL(hub: URL(string: "http://100.64.0.2:8765")!, database: "g", held: held)
            #expect(url.path == "/ui/door")
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            return Dictionary(parts.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }
        #expect(try items("0123456789abcdef0123456789abcdef") == ["db": "g", "renew": "form", "held": "0123456789abcdef0123456789abcdef"])
        #expect(try items("") == ["db": "g", "renew": "form", "held": ""])
    }

    /// The Support session's case (plan v50): the hub, or the file, can call an agent a business's DevOps agent, and
    /// that gives it nothing. Only the box with the business's operator tag names the Operator, and here no box has it.
    @Test func anAgentThatTheHubCallsADevOpsAgentOnABoxWithNoOperatorTagGetsNoServer() {
        let devices = DoorAccess.devices(status: Self.status())
        #expect(!devices.contains { $0.name == "box-hub" && !$0.operates.isEmpty })
        let operators: [String: DoorAccess.Operator?] = ["one": nil, "two": Self.both["two"]!]       // one: checked, no box
        let checked = DoorAccess.Facts(devices: devices, hosts: Self.readings(["web-1", "web-2", "shared-1", "fleet-1"]),
                                       operators: operators)
        let file = Self.object(DoorAccess.plan(current: Self.access, facts: checked).file)
        #expect(Self.agent(file, "builder")["servers"] == nil)          // it held servers of one; it holds none now
        #expect(Self.agent(file, "ops-one")["servers"] == nil)          // the file named it; no box does
        #expect(Self.agent(file, "ops-two")["servers"] as? [String: String] == ["web-2": "fix", "shared-1": "fix"])
    }

    @Test func theModeIsTheHostsOwnAndRuleOnlyWhereTwoBusinessesOrTheFleetMeet() {
        let hosts = Self.object(DoorAccess.plan(current: Self.access, facts: Self.facts()).file)["hosts"] as? [String: Any] ?? [:]
        let web = hosts["web-1"] as? [String: Any] ?? [:]
        #expect(web["address"] as? String == "100.64.1.1")
        #expect(web["port"] as? Int == 2244)
        #expect(web["host_key"] as? String == Self.key)
        #expect(web["business"] as? String == "one")
        #expect(web["mode"] as? String == "fix")
        #expect(web["kind"] as? String == "app")
        #expect((hosts["shared-1"] as? [String: Any])?["mode"] as? String == "rule-only")
        #expect((hosts["fleet-1"] as? [String: Any])?["mode"] as? String == "rule-only")
        #expect((hosts["fleet-1"] as? [String: Any])?["kind"] as? String == "fleet")
    }

    @Test func theNeverListTheDoorAndUntaggedHostsAreLeftOutAndANewHostWaitsForItsParts() {
        let plan = DoorAccess.plan(current: Self.access, facts: Self.facts())
        let hosts = Self.object(plan.file)["hosts"] as? [String: Any] ?? [:]
        #expect(Set(hosts.keys) == ["web-1", "web-2", "shared-1", "fleet-1"])     // not site-1, door, boxes, laptop, old-1
        #expect(plan.waiting == ["new-1"])
    }

    @Test func aHostOrAnOperatorBoxThatDidNotAnswerThisRoundKeepsItsPlace() {
        let written = Self.object(DoorAccess.plan(current: Self.access, facts: Self.facts()).file)
        let quiet = DoorAccess.plan(current: written, facts: Self.facts(hosts: ["web-2", "shared-1", "fleet-1"], operators: [:]))
        let file = Self.object(quiet.file)
        #expect(((file["hosts"] as? [String: Any])?["web-1"] as? [String: Any])?["host_key"] as? String == Self.key)
        #expect(quiet.holdings["ops-one"]?["web-1"] == "fix")
        #expect(quiet.holdings["ops-two"]?["web-2"] == "fix")
        #expect(!quiet.changed)
    }

    /// 7 November 2026: an install that stopped after it made the second sshd's key looked like a host with parts. A
    /// host that answers with no second sshd running leaves the door's file, and the program reads the key only then.
    @Test func aHostWithNoSecondSshdRunningLeavesTheFile() {
        let written = Self.object(DoorAccess.plan(current: Self.access, facts: Self.facts()).file)
        var facts = Self.facts(hosts: ["web-2", "shared-1", "fleet-1"], operators: [:])
        facts.bare = ["web-1"]
        let plan = DoorAccess.plan(current: written, facts: facts)
        #expect((Self.object(plan.file)["hosts"] as? [String: Any])?["web-1"] == nil)
        #expect(plan.changed)
        #expect(DoorAccess.hostProgram.hasPrefix("systemctl is-active --quiet ops-sshd.service && cat "))
    }

    @Test func theSameFactsTwiceWriteNothing() {
        let first = DoorAccess.plan(current: Self.access, facts: Self.facts())
        let second = DoorAccess.plan(current: Self.object(first.file), facts: Self.facts())
        #expect(!second.changed)
        var moved = Self.facts()
        moved.hosts["web-1"] = DoorAccess.HostReading(hostKey: Self.other, mode: "fix", fleet: false)
        #expect(DoorAccess.plan(current: Self.object(first.file), facts: moved).changed)
    }

    @Test func anOperatorOfTwoBusinessesHoldsNoneAndItsBoxAddressIsItsAlone() {
        let greedy: [String: DoorAccess.Operator?] = ["one": DoorAccess.Operator(agent: "ops-one", address: "100.64.0.11"),
                                                      "two": DoorAccess.Operator(agent: "ops-one", address: "100.64.0.11")]
        let file = Self.object(DoorAccess.plan(current: Self.access, facts: Self.facts(operators: greedy)).file)
        #expect(Self.agent(file, "ops-one")["servers"] == nil)
        let moved: [String: DoorAccess.Operator?] = ["one": DoorAccess.Operator(agent: "ops-one", address: "100.64.0.13"),
                                                     "two": Self.both["two"]!]
        let after = Self.object(DoorAccess.plan(current: Self.access, facts: Self.facts(operators: moved)).file)
        #expect(Self.agent(after, "ops-one")["address"] as? String == "100.64.0.13")
        #expect(Self.agent(after, "builder")["address"] == nil)          // that box holds ops-one alone now
    }

    @Test func theOwnerKeyAndTheFleetGoInOnlyFromTheMacThatHoldsTheKey() {
        var facts = Self.facts()
        #expect(Self.object(DoorAccess.plan(current: Self.access, facts: facts).file)["owner_keys"] == nil)
        facts.owner = DoorAccess.OwnerPin(key: "BKey", fleet: "0f1e2d3c4b5a6978")
        let plan = DoorAccess.plan(current: Self.access, facts: facts)
        let file = Self.object(plan.file)
        #expect(file["owner_keys"] as? [String] == ["BKey"])
        #expect(file["fleet"] as? String == "0f1e2d3c4b5a6978")
        #expect(plan.changed)
        #expect(!DoorAccess.plan(current: file, facts: Self.facts()).changed)      // a Mac with no key keeps them
    }

    @Test func everyOtherPartOfTheFileStaysAsTheOwnersMacSessionWroteIt() {
        let file = Self.object(DoorAccess.plan(current: Self.access, facts: Self.facts()).file)
        for key in ["hub", "credentials", "never", "pools"] {
            #expect(DoorAccess.canonical([key: file[key] as Any]) == DoorAccess.canonical([key: Self.access[key] as Any]), "\(key)")
        }
        #expect(file["v"] as? Int == 1)
    }

    // MARK: the fleet's own servers (API 1.210)

    /// The fixture's network with the fleet's own servers on it: two servers that run agents, the hub's server at the
    /// hub's address of the door's file, a Mac, and the manager's server.
    static var fleetDevices: [DoorAccess.Device] {
        DoorAccess.devices(status: status([
            peer("agents-1", "100.64.0.3", ["tag:fleet"]), peer("agents-2", "100.64.0.7", ["tag:old-worker"]),
            peer("hub-1", "100.64.0.2", ["tag:fleet"]), peer("mac-1", "100.64.0.9", ["tag:mac"]),
            peer("manager-box", "100.64.0.10", ["tag:fleet"]), peer("moved-1", "100.64.0.40", [])]))
    }

    static func fleetHub(holder: String? = nil, manager: String? = "manager") -> DoorAccess.HubDoor {
        var hub = hubDoor(agents: ["otto": .init(address: "100.64.0.11", user: "fleet-ops-one"),
                                   "ops-two": .init(address: "100.64.0.12", user: "fleet-ops-two"),
                                   "manager": .init(address: "100.64.0.10", user: "fleet-manager"),
                                   "builder": .init(address: "100.64.0.13", user: "fleet-builder")])
        hub.fleet = .init(servers: ["agents-1": "100.64.0.3", "agents-2": "100.64.0.7", "hub-1": "100.64.0.2",
                                    "fleet-1": "100.64.1.4",          // it carries a business tag: it goes with its business
                                    "ghost-1": "100.64.0.99",         // this Mac's Tailscale shows no such device
                                    "moved-1": "100.64.0.41",         // another address than this Mac's Tailscale gives
                                    "box-one": "100.64.0.11", "manager-box": "100.64.0.10"],
                          holder: holder, manager: manager)
        return hub
    }

    static func fleetFacts(_ holder: DoorAccess.FleetHolder, hub: DoorAccess.HubDoor = fleetHub(),
                           marked: [String] = ["agents-1", "hub-1", "box-one", "manager-box"]) -> DoorAccess.Facts {
        var hosts = readings(["web-1", "web-2", "shared-1", "fleet-1"])
        for name in ["agents-1", "agents-2", "hub-1", "box-one", "manager-box"] {
            hosts[name] = DoorAccess.HostReading(hostKey: other, mode: "rule-only", fleet: marked.contains(name))
        }
        var facts = DoorAccess.Facts(devices: fleetDevices, hosts: hosts, operators: both, hub: hub)
        facts.fleetHolder = holder
        return facts
    }

    /// The owner, 17 November 2026, after three of the fleet's own servers ran out of memory and each time a card asked
    /// him for a root command: "someone should probably have root, I dont want to be doing devops work on the fleet!"
    /// The hub proposes the fleet's servers, and this Mac takes one only when its own Tailscale shows it under that
    /// name at that address, with no business tag, and when it is not the door, not on the never list and not held.
    @Test func theFleetsOwnServersAreTheHubsListAsThisMacsTailscaleShowsIt() {
        var hub = Self.fleetHub()
        #expect(DoorAccess.fleetServers(access: Self.access, devices: Self.fleetDevices, hub: hub)
                == ["agents-1", "agents-2", "box-one", "manager-box", "hub-1"])       // by name, the hub's server last
        #expect(DoorAccess.fleetServers(access: Self.access, devices: Self.fleetDevices, hub: nil).isEmpty)
        #expect(DoorAccess.fleetServers(access: Self.access, devices: Self.fleetDevices, hub: Self.hubDoor()).isEmpty)
        hub.holds = ["agents-2": "parts", "agents-1": "rule-only"]
        var access = Self.access
        access["never"] = ["hosts": ["site-1", "manager-box"]]
        #expect(DoorAccess.fleetServers(access: access, devices: Self.fleetDevices, hub: hub)
                == ["agents-1", "box-one", "hub-1"])
        hub.fleet = .init(servers: ["door": "100.64.0.5", "Bad Name": "100.64.0.3"])
        #expect(DoorAccess.fleetServers(access: Self.access, devices: Self.fleetDevices, hub: hub).isEmpty)
        // a tag business-fleet names no business: the name is the fleet's own in the door's file
        let tagged = DoorAccess.Device(name: "x", address: "100.64.0.6", tags: ["tag:business-fleet", "tag:operator-fleet"])
        #expect(tagged.businesses.isEmpty && tagged.operates.isEmpty)
        #expect(DoorAccess.fleetBusiness == "fleet")
    }

    /// Who holds them, by the owner's two decisions: the DevOps agent that he names, and with no DevOps agent the
    /// manager. The hub's view only proposes: an agent that is no Operator needs its own server's word (`.box`).
    @Test func theHolderIsTheNamedAgentTheOneDevOpsAgentOrTheManager() {
        let devices = Self.fleetDevices
        let otto = DoorAccess.Operator(agent: "otto", address: "100.64.0.11")
        let two = DoorAccess.Operator(agent: "ops-two", address: "100.64.0.12")
        func candidate(_ hub: DoorAccess.HubDoor?, _ operators: [String: DoorAccess.Operator?] = Self.both) -> DoorAccess.FleetCandidate {
            DoorAccess.fleetCandidate(hub: hub, devices: devices, operators: operators)
        }
        #expect(candidate(Self.fleetHub(holder: "otto")) == .agent(otto))           // the Operator, by the hub's name of it
        #expect(candidate(Self.fleetHub(holder: "ops-two")) == .agent(two))
        #expect(candidate(Self.fleetHub(holder: "builder")) == .box(agent: "builder", address: "100.64.0.13"))
        #expect(candidate(Self.fleetHub(holder: "ghost")) == .nobody)               // the hub shows no server for it
        #expect(candidate(Self.fleetHub()) == .nobody)                              // two DevOps agents, and none named
        #expect(candidate(Self.fleetHub(), ["one": Self.both["one"]!, "two": nil]) == .agent(otto))
        #expect(candidate(Self.fleetHub(), ["one": nil, "two": nil])
                == .box(agent: "manager", address: "100.64.0.10"))                  // no DevOps agent: the manager
        #expect(candidate(Self.fleetHub(manager: nil), ["one": nil, "two": nil]) == .nobody)
        // An operator box that was not read this round (here box-two): without a name the round does not know how
        // many DevOps agents there are, and the named agent can be the one on that box. A named agent that a read
        // box shows, or whose server is no such box, is not held up by it.
        let onlyOne: [String: DoorAccess.Operator?] = ["one": Self.both["one"]!]
        #expect(candidate(Self.fleetHub(), onlyOne) == .keep)
        #expect(candidate(Self.fleetHub(holder: "ops-two"), onlyOne) == .keep)
        #expect(candidate(Self.fleetHub(holder: "otto"), onlyOne) == .agent(otto))
        #expect(candidate(Self.fleetHub(holder: "builder"), onlyOne) == .box(agent: "builder", address: "100.64.0.13"))
        #expect(candidate(nil) == .keep && candidate(Self.hubDoor()) == .keep)      // a hub before API 1.210
    }

    @Test func aMachineOfTheFleetIsAHostAtRuleOnlyForTheOneAgentThatHoldsThem() {
        let otto = DoorAccess.Operator(agent: "otto", address: "100.64.0.11")
        let plan = DoorAccess.plan(current: Self.access, facts: Self.fleetFacts(.agent(otto)))
        let file = Self.object(plan.file)
        let hosts = file["hosts"] as? [String: Any] ?? [:]
        for name in ["agents-1", "hub-1", "box-one", "manager-box"] {
            let host = hosts[name] as? [String: Any] ?? [:]
            #expect(host["business"] as? String == "fleet" && host["mode"] as? String == "rule-only"
                    && host["kind"] as? String == "fleet" && host["host_key"] as? String == Self.other, "\(name)")
        }
        #expect((hosts["agents-1"] as? [String: Any])?["address"] as? String == "100.64.0.3")
        #expect(hosts["agents-2"] == nil && plan.waiting.contains("agents-2"))      // its parts have no mark of the fleet
        #expect(hosts["ghost-1"] == nil && hosts["moved-1"] == nil && hosts["mac-1"] == nil)
        // a server with a business tag goes with its business, as before
        #expect((hosts["fleet-1"] as? [String: Any])?["business"] as? String == "one")
        // the holder: its business's servers at Fix, and the fleet's own, its own server among them
        let held = Self.agent(file, "otto")["servers"] as? [String: String] ?? [:]
        #expect(held == ["web-1": "fix", "shared-1": "fix", "fleet-1": "fix", "agents-1": "fix", "hub-1": "fix",
                         "box-one": "fix", "manager-box": "fix"])
        #expect(Self.agent(file, "otto")["business"] as? String == "one")
        #expect((Self.agent(file, "ops-two")["servers"] as? [String: String])?.keys.sorted() == ["shared-1", "web-2"])
        // the hub's record: patch for a machine of the fleet, which is no Fix there
        #expect(plan.holdings["otto"] == ["web-1": "fix", "shared-1": "fix", "fleet-1": "fix", "agents-1": "patch",
                                          "hub-1": "patch", "box-one": "patch", "manager-box": "patch"])
        // the same facts again write nothing
        #expect(!DoorAccess.plan(current: file, facts: Self.fleetFacts(.agent(otto))).changed)
    }

    @Test func anAgentThatIsNoOperatorHoldsThemUnderTheFleetsOwnBusiness() {
        let manager = DoorAccess.Operator(agent: "manager", address: "100.64.0.10")
        var access = Self.access
        var agents = access["agents"] as? [String: Any] ?? [:]
        agents["stale"] = ["address": "100.64.0.10", "business": "one"]      // an old entry at the manager's address
        access["agents"] = agents
        let plan = DoorAccess.plan(current: access, facts: Self.fleetFacts(.agent(manager)))
        let file = Self.object(plan.file)
        let entry = Self.agent(file, "manager")
        #expect(entry["business"] as? String == "fleet" && entry["address"] as? String == "100.64.0.10")
        #expect((entry["servers"] as? [String: String])?.keys.sorted() == ["agents-1", "box-one", "hub-1", "manager-box"])
        #expect(Self.agent(file, "stale")["address"] == nil)                 // the address is the holder's alone
        #expect(plan.holdings["manager"] == ["box-one": "patch", "hub-1": "patch", "manager-box": "patch", "agents-1": "patch"])
        #expect((Self.agent(file, "otto")["servers"] as? [String: String])?["agents-1"] == nil)
        // nobody: the hosts stay, and no agent holds them
        let none = DoorAccess.plan(current: file, facts: Self.fleetFacts(.nobody))
        let after = Self.object(none.file)
        #expect((after["hosts"] as? [String: Any])?["agents-1"] != nil)
        #expect(Self.agent(after, "manager")["servers"] == nil && none.holdings["manager"] == nil)
        // keep: a round that could not say leaves the holder that the file shows, at its address
        let kept = DoorAccess.plan(current: file, facts: Self.fleetFacts(.keep))
        #expect(!kept.changed && kept.holdings["manager"]?["agents-1"] == "patch")
    }

    /// What a fault of the hub must not reach (found by a reviewer of this change): the hub proposes the holder with a
    /// name and an address. An entry of the file under that name can hold a business's servers at Fix, a provider's
    /// account or a database, and only an operator box gives such an entry its address. Were the hub's address
    /// taken, the agent at that address would have all of that.
    @Test func theHubsAddressNeverMovesAnEntryThatHoldsMoreThanTheFleetsServers() {
        var access = Self.access
        var agents = access["agents"] as? [String: Any] ?? [:]
        agents["ops-one"] = ["address": "100.64.0.11", "business": "one", "servers": ["web-1": "fix"]]
        agents["builder"] = ["address": "100.64.0.13", "business": "one", "databases": ["shop-db": "data"]]
        agents["reader"] = ["github": ["one-org/ops": "read"]]                // its GitHub grants alone, from the hub
        access["agents"] = agents
        var hosts = access["hosts"] as? [String: Any] ?? [:]
        hosts["web-1"] = ["address": "100.64.1.1", "port": 2244, "host_key": Self.key, "business": "one", "mode": "fix", "kind": "app"]
        access["hosts"] = hosts
        // this round: no device carries the operator tag of one, so the file's holder of one stays (ops-one)
        func planned(_ agent: String, _ address: String) -> [String: Any] {
            var facts = Self.fleetFacts(.agent(.init(agent: agent, address: address)), hub: Self.hubDoor(agents: [:]))
            facts.hub?.fleet = Self.fleetHub().fleet
            facts.devices = Self.fleetDevices.filter { $0.name != "box-one" }
            facts.operators = ["two": Self.both["two"]!]
            return Self.object(DoorAccess.plan(current: access, facts: facts).file)
        }
        // the holder of a business's servers, at the address that the hub gives for it
        var entry = Self.agent(planned("ops-one", "100.64.0.10"), "ops-one")
        #expect(entry["address"] as? String == "100.64.0.11")                       // its own, as the file had it
        #expect((entry["servers"] as? [String: String])?["web-1"] == "fix")
        #expect((entry["servers"] as? [String: String])?["agents-1"] == nil)        // and none of the fleet's servers
        // an entry with a database's login
        entry = Self.agent(planned("builder", "100.64.0.10"), "builder")
        #expect(entry["address"] as? String == "100.64.0.13" && entry["servers"] == nil)
        #expect(entry["databases"] as? [String: String] == ["shop-db": "data"])
        // at the address that the file already has, each of them holds the fleet's servers
        entry = Self.agent(planned("ops-one", "100.64.0.11"), "ops-one")
        #expect(entry["address"] as? String == "100.64.0.11" && (entry["servers"] as? [String: String])?["agents-1"] == "fix")
        #expect((entry["servers"] as? [String: String])?["web-1"] == "fix")
        // an entry with GitHub grants alone, and an agent with no entry, take the address that their own server proved
        entry = Self.agent(planned("reader", "100.64.0.10"), "reader")
        #expect(entry["address"] as? String == "100.64.0.10" && entry["business"] as? String == "fleet")
        #expect((entry["servers"] as? [String: String])?["agents-1"] == "fix")
        #expect((Self.agent(planned("manager", "100.64.0.10"), "manager")["servers"] as? [String: String])?["agents-1"] == "fix")
    }

    /// The other side of that guard (found in the confirm round of the reviews): a holder whose entry holds only the
    /// fleet's own servers moves with its server. Without this, a manager that the owner moved to another server
    /// lost the fleet's servers for good, and nothing said so.
    @Test func aHolderWhoseEntryHoldsOnlyTheFleetsServersMovesWithItsServer() {
        let manager = DoorAccess.Operator(agent: "manager", address: "100.64.0.10")
        var file = Self.object(DoorAccess.plan(current: Self.access, facts: Self.fleetFacts(.agent(manager))).file)
        #expect(Self.agent(file, "manager")["address"] as? String == "100.64.0.10")
        // the owner moved the manager to another server: the hub and that server say so
        let moved = DoorAccess.Operator(agent: "manager", address: "100.64.0.40")
        var after = Self.object(DoorAccess.plan(current: file, facts: Self.fleetFacts(.agent(moved))).file)
        #expect(Self.agent(after, "manager")["address"] as? String == "100.64.0.40")
        #expect((Self.agent(after, "manager")["servers"] as? [String: String])?["agents-1"] == "fix")
        // an entry that lost its address (an Operator took it in a round that could not say who holds) gets one again
        var agents = file["agents"] as? [String: Any] ?? [:]
        var entry = agents["manager"] as? [String: Any] ?? [:]
        entry["address"] = nil
        agents["manager"] = entry
        file["agents"] = agents
        after = Self.object(DoorAccess.plan(current: file, facts: Self.fleetFacts(.agent(moved))).file)
        #expect(Self.agent(after, "manager")["address"] as? String == "100.64.0.40")
        #expect((Self.agent(after, "manager")["servers"] as? [String: String])?["agents-1"] == "fix")
        // with a key of a key card in its entry too, which the hub gives as it gives the GitHub grants
        entry["address"] = "100.64.0.10"
        entry["providers"] = ["hetzner:fleet"]
        agents["manager"] = entry
        file["agents"] = agents
        after = Self.object(DoorAccess.plan(current: file, facts: Self.fleetFacts(.agent(moved))).file)
        #expect(Self.agent(after, "manager")["address"] as? String == "100.64.0.40")
        // but not with an account that a Mac session wrote, a database, or a server that is none of the fleet's own
        for (key, value) in [("providers", ["aws:one"] as Any), ("databases", ["shop-db": "data"] as Any),
                             ("servers", ["agents-1": "fix", "web-1": "fix"] as Any), ("business", "one" as Any)] {
            var more = entry
            more[key] = value
            agents["manager"] = more
            file["agents"] = agents
            let kept = Self.agent(Self.object(DoorAccess.plan(current: file, facts: Self.fleetFacts(.agent(moved))).file), "manager")
            #expect(kept["address"] as? String == "100.64.0.10", "\(key)")
            #expect((kept["servers"] as? [String: String])?["agents-1"] == nil, "\(key)")
        }
    }

    /// And the corner of an Operator of this round (the same review): the hub names the agent on the operator box of one
    /// business as the file's holder of another business. The rule of two businesses gives it neither business, so
    /// no line gives its entry that box's address, and the fleet's part does not either: the entry keeps its
    /// address, with its database.
    @Test func anOperatorOfThisRoundThatTheHubNamesAsAnotherEntryGetsNoAddressFromTheFleetsPart() {
        var access = Self.access
        var agents = access["agents"] as? [String: Any] ?? [:]
        agents["otto"] = ["address": "100.64.0.99", "business": "three", "servers": ["old-1": "fix"],
                          "databases": ["shop-db": "data"]]
        agents["ops-one"] = nil
        agents["builder"] = nil
        access["agents"] = agents
        var hosts = access["hosts"] as? [String: Any] ?? [:]
        hosts["old-1"] = ["address": "100.64.1.99", "port": 2244, "host_key": Self.key, "business": "three", "mode": "fix", "kind": "app"]
        access["hosts"] = hosts
        var facts = Self.fleetFacts(.agent(.init(agent: "otto", address: "100.64.0.11")))        // the box of one
        facts.devices = Self.fleetDevices + [DoorAccess.Device(name: "old-1", address: "100.64.1.99", tags: ["tag:business-three"])]
        facts.hosts["old-1"] = DoorAccess.HostReading(hostKey: Self.key, mode: "fix", fleet: false)
        let file = Self.object(DoorAccess.plan(current: access, facts: facts).file)
        let entry = Self.agent(file, "otto")
        #expect(entry["address"] as? String == "100.64.0.99")
        #expect(entry["databases"] as? [String: String] == ["shop-db": "data"])
        #expect((entry["servers"] as? [String: String])?["agents-1"] == nil)
    }

    /// `.keep` (a box that did not answer): the holder that the file shows stays. When it is an Operator of this round,
    /// its address is this round's, and an agent that only stays takes no address from another agent.
    @Test func aKeptHolderHasThisRoundsAddressAndTakesNoAddressAway() {
        let otto = DoorAccess.Operator(agent: "otto", address: "100.64.0.11")
        let first = Self.object(DoorAccess.plan(current: Self.access, facts: Self.fleetFacts(.agent(otto))).file)
        // the box of one moved to another address, and this round could not say who holds the fleet's servers
        var facts = Self.fleetFacts(.keep)
        facts.operators = ["one": DoorAccess.Operator(agent: "ops-one", address: "100.64.0.31"), "two": Self.both["two"]!]
        var hub = Self.hubDoor(agents: ["otto": .init(address: "100.64.0.31", user: "fleet-ops-one"),
                                        "ops-two": .init(address: "100.64.0.12", user: "fleet-ops-two")])
        hub.fleet = Self.fleetHub().fleet
        facts.hub = hub
        let moved = Self.object(DoorAccess.plan(current: first, facts: facts).file)
        #expect(Self.agent(moved, "otto")["address"] as? String == "100.64.0.31")
        #expect((Self.agent(moved, "otto")["servers"] as? [String: String])?["agents-1"] == "fix")
        // A kept holder that is no Operator keeps the file's address. When this round gives that address to an
        // Operator (its server got an operator tag), the Operator has it alone, as the door asks: the kept holder
        // has no address then, so it calls nothing until a round can say who holds the fleet's servers.
        let manager = DoorAccess.Operator(agent: "manager", address: "100.64.0.10")
        let file = Self.object(DoorAccess.plan(current: Self.access, facts: Self.fleetFacts(.agent(manager))).file)
        let kept = Self.object(DoorAccess.plan(current: file, facts: Self.fleetFacts(.keep)).file)
        #expect(Self.agent(kept, "manager")["address"] as? String == "100.64.0.10")
        #expect((Self.agent(kept, "manager")["servers"] as? [String: String])?["agents-1"] == "fix")
        var taken = Self.fleetFacts(.keep)
        taken.operators = ["one": Self.both["one"]!, "two": DoorAccess.Operator(agent: "ops-two", address: "100.64.0.10")]
        let after = Self.object(DoorAccess.plan(current: file, facts: taken).file)
        #expect(Self.agent(after, "ops-two")["address"] as? String == "100.64.0.10")
        #expect(Self.agent(after, "manager")["address"] == nil)
        let addresses = (after["agents"] as? [String: Any] ?? [:]).values.compactMap { ($0 as? [String: Any])?["address"] as? String }
        #expect(Set(addresses).count == addresses.count)                 // no address two times: the door takes the file
    }

    /// The door refuses a whole file that has an agent at the hub's address, and it knows a caller by its address: an
    /// agent on the hub's server, or at the door's own address, holds nothing, and the file stays one that the door takes.
    @Test func anAgentAtTheHubsOrTheDoorsAddressHoldsNoneOfThem() {
        for address in ["100.64.0.2", "100.64.0.5"] {
            let plan = DoorAccess.plan(current: Self.access,
                                       facts: Self.fleetFacts(.agent(.init(agent: "manager", address: address))))
            let file = Self.object(plan.file)
            #expect(Self.agent(file, "manager").isEmpty && plan.holdings["manager"] == nil, "\(address)")
            #expect((file["hosts"] as? [String: Any])?["agents-1"] != nil)
        }
        let bad = DoorAccess.plan(current: Self.access,
                                  facts: Self.fleetFacts(.agent(.init(agent: "Not A Name", address: "100.64.0.10"))))
        #expect(bad.holdings["Not A Name"] == nil)
    }

    @Test func aFleetServerThatDidNotAnswerKeepsItsPlaceAndOneWithNoSshdLeaves() {
        let otto = DoorAccess.Operator(agent: "otto", address: "100.64.0.11")
        let first = Self.object(DoorAccess.plan(current: Self.access, facts: Self.fleetFacts(.agent(otto))).file)
        var facts = Self.fleetFacts(.agent(otto))
        facts.hosts["agents-1"] = nil                                        // SSH did not answer this round
        let kept = Self.object(DoorAccess.plan(current: first, facts: facts).file)
        #expect(((kept["hosts"] as? [String: Any])?["agents-1"] as? [String: Any])?["mode"] as? String == "rule-only")
        #expect((Self.agent(kept, "otto")["servers"] as? [String: String])?["agents-1"] == "fix")
        facts.bare = ["agents-1"]                                            // it answered, and its second sshd is gone
        let gone = DoorAccess.plan(current: first, facts: facts)
        #expect((Self.object(gone.file)["hosts"] as? [String: Any])?["agents-1"] == nil && gone.holdings["otto"]?["agents-1"] == nil)
        // an old entry of another kind under a fleet server's name is no entry of the fleet: it is not kept as one
        var old = first
        var hosts = old["hosts"] as? [String: Any] ?? [:]
        hosts["agents-1"] = ["address": "100.64.0.3", "port": 2244, "host_key": Self.key, "business": "one", "mode": "fix", "kind": "app"]
        old["hosts"] = hosts
        facts.bare = []
        #expect((Self.object(DoorAccess.plan(current: old, facts: facts).file)["hosts"] as? [String: Any])?["agents-1"] == nil)
    }

    @Test func theHubsViewGivesTheFleetAndTheRoundReadsAChangeOfIt() throws {
        let json = #"{"door": null, "credentials": {}, "agents": {}, "db": "g", "fleet": {"servers": {"agents-1": "100.64.0.3"}, "holder": "otto", "manager": "manager"}}"#
        let view = try JSONDecoder().decode(DoorAccess.HubDoor.self, from: Data(json.utf8))
        #expect(view.fleet == .init(servers: ["agents-1": "100.64.0.3"], holder: "otto", manager: "manager"))
        var other = view
        other.fleet = .init(servers: ["agents-1": "100.64.0.3"], holder: nil, manager: "manager")
        #expect(view.digest != other.digest)
        other.fleet = nil
        #expect(view.digest != other.digest)
        let none = try JSONDecoder().decode(DoorAccess.HubDoor.self, from: Data(#"{"door": null, "credentials": {}, "agents": {}, "db": "g"}"#.utf8))
        #expect(none.fleet == nil)
        #expect(DoorAccess.fleetProgram == "test -x /usr/local/sbin/fleet-agent-user && echo fleet-machine=yes; true")
        // the probe reads the install script's own line for the option (the hub's test_host_parts holds that line)
        #expect(DoorAccess.fleetProbe == "grep -qs -- '--fleet) FLEET=1' /opt/fleet-door/current/host/install.sh && echo fleet=yes; true")
        #expect(DoorAccess.hostProgram.contains("if test -e /etc/ops-root/fleet || test -e /etc/ops-root/fleet-kit; then echo fleet=yes; fi"))
        let body = Self.object(try ServerGrantCommand.body(requestID: UUID(), database: "g", agent: "otto", server: "agents-1", level: "patch"))
        #expect(body["level"] as? String == "patch")
        #expect((try? ServerGrantCommand.body(requestID: UUID(), database: "g", agent: "otto", server: "agents-1", level: "root")) == nil)
    }

    @Test func aHostSaysItsKeyItsModeAndWhetherItIsTheFleets() {
        #expect(DoorAccess.HostReading(output: "\(Self.key) root@web-1\nmode=fix\n")
                    == DoorAccess.HostReading(hostKey: Self.key, mode: "fix", fleet: false))
        #expect(DoorAccess.HostReading(output: "\(Self.key)\nmode=\nfleet=yes\n")
                    == DoorAccess.HostReading(hostKey: Self.key, mode: "rule-only", fleet: true))
        #expect(DoorAccess.HostReading(output: "mode=fix\n") == nil)
        #expect(DoorAccess.HostReading(output: "ssh-rsa AAAA root@x\nmode=fix\n") == nil)
    }

    @Test func theHubRecordsWhatChangedAndTakesBackWhatWent() throws {
        let changes = DoorAccess.changes(wanted: ["ops-one": ["web-1": "fix", "web-3": "fix"]],
                                         recorded: ["ops-one": ["web-1": "fix", "old-1": "fix"], "builder": ["web-1": "read"]])
        #expect(changes.map { "\($0.agent) \($0.server) \($0.level ?? "-")" } == ["builder web-1 -", "ops-one old-1 -", "ops-one web-3 fix"])
        let body = Self.object(try ServerGrantCommand.body(requestID: UUID(), database: "gen-1", agent: "ops-one", server: "web-1", level: nil))
        #expect(body["level"] is NSNull)
        #expect(body["server"] as? String == "web-1")
        #expect((try? ServerGrantCommand.body(requestID: UUID(), database: "gen-1", agent: "ops-one", server: "web 1", level: "fix")) == nil)
    }

    @Test func theGitHubKeyOfAnOwnerIsOneCredentialOfTheFile() {
        var access = Self.access
        var credentials = access["credentials"] as? [String: Any] ?? [:]
        credentials["github:One-Org"] = ["secret": "bws://00000002-0000-4000-8000-000000000000", "app_id": "1"]
        access["credentials"] = credentials
        let file = DoorAccess.withGitHubApp(access, owner: "one-org", login: "bws://00000003-0000-4000-8000-000000000000", appID: "42")
        let after = file["credentials"] as? [String: Any] ?? [:]
        #expect(after["github:One-Org"] == nil)
        #expect(after["github:one-org"] as? [String: String] == ["secret": "bws://00000003-0000-4000-8000-000000000000", "app_id": "42"])
        #expect(after["cloudflare:one"] != nil)
    }

    /// The value after each `flag` of `ssh`'s arguments.
    private static func after(_ flag: String, in arguments: [String]) -> [String] {
        arguments.indices.filter { arguments[$0] == flag && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    }

    /// 7 November 2026: a server with no connection that the app keeps got root with every key of the SSH agent and of
    /// `Host *`, eight tries where its sshd stops at six, each round, until its fail2ban shut this Mac out for an hour.
    ///
    /// 19 November 2026: a server whose root SSH answers only on port 2222 got no door parts, because the round went to
    /// port 22. The round takes the port, and root's own key, from the entry of `~/.ssh/config` that gives the server's
    /// address as its `HostName`, or that has the server's name in Tailscale. It takes nothing from an entry through
    /// another host, from an entry for another user (its port can be another program's), or from an entry with the
    /// port of the door's own second sshd.
    @Test func aServerWithNoKeptConnectionIsOfferedOnlyTheConfiguredKeyFiles() async throws {
        let arguments = try #require(DoorAccess.sshArguments(kept: nil, address: "100.96.20.60", program: DoorAccess.hostProgram))
        #expect(Array(arguments.prefix(2)) == ["-o", "IdentitiesOnly=yes"])
        #expect(arguments.contains("StrictHostKeyChecking=yes") && arguments.contains("BatchMode=yes") && !arguments.contains("-i"))
        #expect(Array(arguments.suffix(2)) == ["root@100.96.20.60", DoorAccess.hostProgram])
        #expect(Self.after("-p", in: arguments) == ["22"])

        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("door-ssh-" + UUID().uuidString)
        let folder = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("""
        Host shop-root
          HostName 100.96.20.60
        Host shop-jump
          HostName 100.96.20.61
        Host shop-deploy
          HostName 100.96.10.20
        Host shop-ops
          HostName 100.96.200.70
        """.utf8).write(to: folder.appendingPathComponent("config"))
        try Data().write(to: folder.appendingPathComponent("shop_root"))
        // what `ssh -G` prints: for a name that no entry names, what the configuration gives every host
        let every = "user me\nport 22\nidentityfile ~/.ssh/id_ed25519\n"
        let prints = [
            "shop-root": "hostname 100.96.20.60\nuser root\nport 2222\nidentityfile ~/.ssh/shop_root\nidentityfile ~/.ssh/id_ed25519\n",
            "shop-jump": "hostname 100.96.20.61\nuser root\nport 2200\nidentityfile ~/.ssh/id_ed25519\nproxyjump bastion\n",
            "shop-deploy": "hostname 100.96.10.20\nuser deploy\nport 2022\nidentityfile ~/.ssh/shop_root\nidentityfile ~/.ssh/id_ed25519\n",
            "shop-ops": "hostname 100.96.200.70\nuser root\nport \(DoorAccess.sshdPort)\nidentityfile ~/.ssh/id_ed25519\n",
            "shop-testing-4": "hostname shop-testing-4.tail1234.ts.net\nuser me\nport 2223\nidentityfile ~/.ssh/id_ed25519\n",
            "shop-testing-5": "hostname 203.0.113.9\nuser me\nport 2224\nidentityfile ~/.ssh/id_ed25519\n",
            "shop-testing-6": "hostname shop-testing-6\nuser root\nport 2225\nidentityfile ~/.ssh/id_ed25519\nproxyjump bastion\n",
        ]
        func configured(_ name: String, _ address: String, byName: Bool = true) async -> DoorAccess.Configured? {
            await DoorAccess.configured(DoorAccess.Device(name: name, address: address, tags: []), address: address,
                                        byName: byName, home: home.path, localUser: "me",
                                        run: { _, arguments, _, _ in
                let asked = arguments.last ?? ""
                return LocalShell.Answer(status: 0, output: prints[asked] ?? "hostname \(asked)\n" + every)
            })
        }
        // the entry by HostName: its port, and its own key for root, as the one key of the try
        let key = folder.appendingPathComponent("shop_root").path
        let found = await configured("shop-testing-1", "100.96.20.60")
        #expect(found == DoorAccess.Configured(port: 2222, key: key))
        let candidates = DoorAccess.LoginKeys.candidates(configured: found?.key, kept: ["/Users/o/.ssh/fleet_root", key])
        #expect(candidates == [key, "/Users/o/.ssh/fleet_root"])
        #expect(DoorAccess.LoginKeys.candidates(configured: nil, kept: ["/Users/o/.ssh/fleet_root"]) == ["/Users/o/.ssh/fleet_root"])
        let moved = try #require(DoorAccess.sshArguments(kept: nil, address: "100.96.20.60", program: "true",
                                                         key: candidates.first, port: found?.port ?? 22))
        #expect(Self.after("-p", in: moved) == ["2222"] && Self.after("-i", in: moved) == [key])
        #expect(Array(moved.prefix(2)) == ["-o", "IdentitiesOnly=yes"] && moved.contains("StrictHostKeyChecking=yes"))
        #expect(Array(moved.suffix(2)) == ["root@100.96.20.60", "true"])
        // no entry: port 22, as before; an entry through another host is not used
        #expect(await configured("shop-testing-9", "100.96.1.50") == nil)
        #expect(await configured("shop-testing-2", "100.96.20.61") == nil)
        // an entry for another user gives nothing: its port can be another program's, and its key is not root's
        #expect(await configured("shop-testing-3", "100.96.10.20") == nil)
        // the port of the door's own second sshd is never root's
        #expect(await configured("shop-testing-7", "100.96.200.70") == nil)
        // the entry with the server's name in Tailscale, when its host is that server
        #expect(await configured("shop-testing-4", "100.96.100.4") == DoorAccess.Configured(port: 2223))
        #expect(await configured("shop-testing-4", "100.96.100.4", byName: false) == nil)
        #expect(await configured("shop-testing-5", "100.96.100.130") == nil)
        #expect(await configured("shop-testing-6", "100.96.100.131") == nil)
        // a kept connection keeps its user and its key, at the address that Tailscale gives, with IdentitiesOnly once
        let kept = InstallTarget(host: "203.0.113.163", user: "root", identityFile: "/Users/o/.ssh/shop_hetzner")
        let keyed = try #require(DoorAccess.sshArguments(kept: kept, address: "100.96.200.70", program: "true"))
        #expect(keyed.filter { $0 == "IdentitiesOnly=yes" }.count == 1 && keyed.contains("/Users/o/.ssh/shop_hetzner"))
        #expect(Array(keyed.suffix(2)) == ["root@100.96.200.70", "true"])
        // a kept user that is not root becomes root with sudo, as before
        let admin = try #require(DoorAccess.sshArguments(kept: InstallTarget(host: "h", user: "admin"), address: "100.64.1.1",
                                                         program: "true"))
        #expect(!admin.contains("IdentitiesOnly=yes") && admin.contains("admin@100.64.1.1"))
        #expect(admin.last == "sudo -n -i -- /bin/sh -c 'true'")
        #expect(DoorAccess.sshArguments(kept: nil, address: "100.64.1.1; reboot", program: "true") == nil)
    }

    /// A server that refused this Mac's login gets no try in the next rounds: it is tried again an hour later, or at once
    /// when its device changes, and a new start of the app reads the same record. A server that `ssh` did not reach,
    /// and a program that failed after the login, start no wait.
    @Test func aRefusedLoginWaitsAnHourOrForAChangedDevice() throws {
        #expect(DoorAccess.loginRefused(status: 255, output: "root@100.96.20.60: Permission denied (publickey).\r\n"))
        #expect(DoorAccess.loginRefused(status: 255, output: "Received disconnect from 100.96.20.60 port 22:2: Too many "
                                        + "authentication failures\nDisconnected from 100.96.20.60 port 22\n"))
        #expect(DoorAccess.loginRefused(status: 255, output: "No ED25519 host key is known for 100.96.20.60 and you have "
                                        + "requested strict checking.\nHost key verification failed.\n"))
        #expect(!DoorAccess.loginRefused(status: 255, output: "ssh: connect to host 100.96.20.60 port 22: Connection refused\n"))
        #expect(!DoorAccess.loginRefused(status: 255, output: "ssh: connect to host 100.96.20.60 port 22: Operation timed out\n"))
        #expect(!DoorAccess.loginRefused(status: 1, output: "cat: /etc/fleet-door/access.json: Permission denied (13)\n"))

        let server = DoorAccess.Device(name: "shop-testing-1", address: "100.96.20.60",
                                       tags: ["tag:business-shop", "tag:hetzner-server"])
        #expect(DoorAccess.line(server) == "shop-testing-1 100.96.20.60 tag:business-shop,tag:hetzner-server")
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        var refusals = DoorAccess.Refusals()
        #expect(!refusals.waits(server, now: start))
        refusals.note(server, refused: true, now: start)
        #expect(refusals.waits(server, now: start.addingTimeInterval(300)))            // the next round
        #expect(refusals.waits(server, now: start.addingTimeInterval(3599)))
        #expect(!refusals.waits(server, now: start.addingTimeInterval(3600)))          // an hour later
        #expect(!refusals.waits(server, now: start.addingTimeInterval(-60)))           // a clock that went back
        // the same server with another address or other tags is a changed device: it is tried at once
        #expect(!refusals.waits(DoorAccess.Device(name: server.name, address: "100.96.20.61", tags: server.tags),
                                now: start.addingTimeInterval(300)))
        #expect(!refusals.waits(DoorAccess.Device(name: server.name, address: server.address, tags: ["tag:business-shop"]),
                                now: start.addingTimeInterval(300)))

        // the record outlives the app's run, for each hub
        let defaults = try #require(UserDefaults(suiteName: "door-refusals-\(UUID().uuidString)"))
        let hub = URL(string: "http://100.64.0.2:8765")!
        refusals.save(hub: hub, in: defaults)
        #expect(DoorAccess.Refusals.read(hub: hub, in: defaults).waits(server, now: start.addingTimeInterval(300)))
        #expect(!DoorAccess.Refusals.read(hub: URL(string: "http://100.64.0.3:8765")!, in: defaults)
                    .waits(server, now: start.addingTimeInterval(300)))

        // 7 November 2026: one key that this Mac already uses for root, besides ~/.ssh/config's, the next one after a
        // refusal, and a key that let it in stays
        let keys = ["/Users/o/.ssh/fleet_root", "/Users/o/.ssh/other_root"]
        var login = DoorAccess.LoginKeys()
        #expect(login.key(for: server, candidates: []) == nil)
        #expect(login.key(for: server, candidates: keys) == keys[0])
        login.refused(server, key: keys[0])
        #expect(login.key(for: server, candidates: keys) == keys[1])
        login.refused(server, key: keys[1])
        #expect(login.key(for: server, candidates: keys) == keys[0])
        login.save(hub: hub, in: defaults)
        #expect(DoorAccess.LoginKeys.read(hub: hub, in: defaults) == login)
        let args = try #require(DoorAccess.sshArguments(kept: nil, address: "100.96.20.60", program: "true", key: keys[0]))
        #expect(args.contains("IdentitiesOnly=yes") && args.contains(keys[0]) && args.contains("root@100.96.20.60"))
        #expect(!(DoorAccess.sshArguments(kept: nil, address: "100.96.20.60", program: "true") ?? []).contains("-i"))

        // a login that got in ends the wait at once
        refusals.note(server, refused: false, now: start.addingTimeInterval(600))
        #expect(!refusals.waits(server, now: start.addingTimeInterval(700)) && refusals.at.isEmpty)
    }
}
