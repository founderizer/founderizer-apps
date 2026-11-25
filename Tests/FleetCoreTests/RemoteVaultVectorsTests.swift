import Foundation
import Testing
@testable import FleetCore

/// **The vectors of the central vault's root steps and of the key registration's proof read** (windows-app-plan-v2.md,
/// 5.6, piece L6, the remote part of the vault's vectors): what the Windows app's library
/// (`windows/Founderizer.Setup/RootJobs`) runs on the hub's server and on each server over SSH, and how it reads the
/// answer, made by FleetCore's own code for fixed example inputs (no real key, no real address).
///
/// - `CentralVaultRemote`: the install with the owner's public key, with and without `--keep-owner`; the bridge across
///   the key change of 4 November 2026, for given release keys; the two reads of a server's vault key and what they
///   printed; the install's answer.
/// - `OwnerMacKeyRegistration`: the path that the hub names, the program that reads the proof as the file's own user,
///   and the value in what it printed.
///
/// A file of its own beside `vault-seal.json` (piece L5 writes that one), so that two pieces that run side by side
/// never edit one file. With `FOUNDERIZER_VECTORS_OUT` set, the test writes the file into that folder
/// (`app/vectors/make_vectors.py` does, and its `--check` compares); without it, the test holds the committed file equal
/// to what FleetCore gives now.
struct RemoteVaultVectorsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")
    static let file = "remote-vault.json"
    static let madeBy = "app/Tests/FleetCoreTests/RemoteVaultVectorsTests.swift"
    static let throughSudo = InstallTarget(host: "100.80.1.2", user: "admin", port: 2222, becomeRoot: true)

    static func wire(_ program: String, runs: InstallPlan.Runs = .root) -> String {
        InstallPlan(job: .join, target: throughSudo, steps: [], redactions: [])
            .arguments(for: program, reaching: throughSudo, runs: runs).last!
    }

    static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    /// An owner key's public half as the app gives it (`OwnerKey.publicKey`): 65 bytes, 04 first. Not a key of any
    /// fleet: the install reads its form alone.
    static let ownerKey = (Data([4]) + Data((1...64).map { UInt8($0) })).base64EncodedString()
    /// Two release keys of the tests (32 bytes each), and a line that is no key.
    static let testKeys = [Data(repeating: 7, count: 32).base64EncodedString(),
                           Data(repeating: 9, count: 32).base64EncodedString()]

    static func recipient(_ byte: UInt8) -> String { AgeSeal.bech32("age", Data(repeating: byte, count: 32)) }

    static func document() throws -> [String: Any] {
        let short = Data([4] + [UInt8](repeating: 1, count: 63)).base64EncodedString()
        let compressed = (Data([2]) + Data((1...64).map { UInt8($0) })).base64EncodedString()
        let installs: [(String, String, Bool)] = [
            ("the app's own install", ownerKey, true), ("the owner's Set up", ownerKey, false),
            ("a key that is too short", short, true), ("a key whose first byte is not 04", compressed, true),
            ("no base64", "not a key!", true), ("an empty key", "", false),
        ]
        let bridges: [(String, String)] = [
            ("two keys", testKeys.joined(separator: "\n")),
            ("two keys with space and a line that is no key", "  \(testKeys[0])  \nnot a key\n\n\(testKeys[1])\n"),
            ("no key", ""),
            ("this build's keys", AppUpdate.shippedKeys + "\n" + AppUpdate.earlyKeys),
        ]
        let one = recipient(7), other = recipient(9)
        var broken = Array(one)
        broken[broken.count - 1] = broken.last == "q" ? "p" : "q"
        let brokerOutputs = [
            "# public key: \(one)\n",
            "Welcome\n  # public key: \(one)  \n",
            "# public key: \(one)\n# public key: \(one)\n",
            "# public key: \(one)\n# public key: \(other)\n",
            "# public key: \(String(broken))\n",
            "# public key: \(one.uppercased())\n",
            "#public key: \(one)\n",
            "# public key: None\n",
            "Host key verification failed.\n",
            "",
        ]
        let installedOutputs = [
            "Cloning…\n{\"ok\": true, \"recipient\": \"\(one)\", \"fleet\": \"0123456789abcdef\"}\n",
            "{\"ok\": true, \"recipient\": \"\(one)\", \"fleet\": \"0123456789abcdef\"}\nsome words after it\n",
            "{\"ok\": false, \"owner\": \"other\"}\n",
            "{\"ok\": false, \"error\": \"the vault's store is held by another process\"}\n",
            "{\"ok\": false}\n",
            "{\"ok\": false, \"error\": \"\(String(repeating: "a", count: 320))\"}\n",
            "{\"ok\": true, \"recipient\": \"\(String(broken))\", \"fleet\": \"0123456789abcdef\"}\n",
            "{\"ok\": true, \"recipient\": \"\(one)\", \"fleet\": \"0123456789ABCDEF\"}\n",
            "{\"ok\": true, \"recipient\": \"\(one)\"}\n",
            "{\"ok\": \"yes\", \"recipient\": \"\(one)\", \"fleet\": \"0123456789abcdef\"}\n",
            "{\"ok\": true, \"recipient\": \"\(one)\", \"fleet\": \"0123456789abcdef\"}\n{\"ok\": false, \"owner\": \"other\"}\n",
            "{\"ok\": false, \"owner\": \"other\"}\n{\"ok\": true, \"recipient\": \"\(one)\", \"fleet\": \"0123456789abcdef\"}\n",
            "  {\"ok\": true, \"recipient\": \"\(one)\", \"fleet\": \"0123456789abcdef\"}  \n",
            "[1, 2]\n{not json\n",
            "",
        ]
        let saids: [String?] = [
            "/home/fleet/.founderizer/owner-key.proof", "/var/lib/fleet/owner-key.proof", "owner-key.proof",
            "/home/fleet/../root/owner-key.proof", "/home/fleet/./owner-key.proof", "/home/fleet//owner-key.proof",
            "/home/fleet/owner-key.prooff", "/home/fleet/other.proof", "/home/fl eet/owner-key.proof",
            "/home/fleet/owner-key.proof/", "/" + String(repeating: "a", count: 497) + "/owner-key.proof", nil, "",
        ]
        let value = String(repeating: "A", count: 21) + "-_" + String(repeating: "z", count: 20)
        let proofOutputs = [
            "founderizer-proof:\(value)\nfounderizer-addresses:1: lo    inet 127.0.0.1/8\n",
            "sudo: a line\nfounderizer-proof:\(value)\r\nfounderizer-addresses:\n",
            "founderizer-proof:\(value)x\n",
            "founderizer-proof:\(String(value.dropLast()))\n",
            "founderizer-proof:\n",
            "founderizer-proof:\(String(repeating: "B", count: 43))\nfounderizer-proof:\(value)\n",
            "founderizer-proof: \(value)\n",
            "no mark at all\n",
            "",
        ]
        // This computer's Tailscale, as `tailscale status --json` gives it: the hub's node, a Linux server, a Mac server,
        // two nodes that share one first label (one of them shared in from another tailnet), and a node with no ID.
        func node(_ id: String?, _ name: String, _ address: String, _ os: String?) -> [String: Any] {
            var node: [String: Any] = ["DNSName": name + ".", "TailscaleIPs": [address]]
            if let id { node["ID"] = id }
            if let os { node["OS"] = os }
            return node
        }
        let tailnet: [String: Any] = [
            "Self": node("n0", "pc.tail1234.ts.net", "100.64.0.1", "windows"),
            "Peer": ["a": node("n1", "hub.tail1234.ts.net", "100.64.0.2", "linux"),
                     "b": node("n2", "app-1.tail1234.ts.net", "100.64.0.7", "linux"),
                     "c": node("n3", "studio.tail1234.ts.net", "100.64.0.9", "macOS"),
                     "d": node("n4", "twin.tail1234.ts.net", "100.64.0.11", "linux"),
                     "e": node("n5", "twin.example.ts.net", "100.64.0.12", "linux"),
                     "f": node(nil, "old-1.tail1234.ts.net", "100.64.0.31", nil)]]
        let status = String(data: try JSONSerialization.data(withJSONObject: tailnet, options: [.sortedKeys]), encoding: .utf8)!
        let hosts = ["100.64.0.2", "hub", "hub.tail1234.ts.net", "HUB.tail1234.ts.net.", "100.64.0.9", "studio", "twin",
                     "100.64.0.11", "twin.example.ts.net", "old-1", "100.64.0.31", "100.64.0.99", "[100.64.0.7]", "pc", ""]
        let trusts: [(String?, [String], String, Bool)] = [
            ("mac", ["macOS"], "admin", false), ("mac", ["linux"], "admin", false), ("mac", ["macOS"], "root", false),
            ("linux", ["macOS"], "admin", false), ("linux", ["linux"], "root", false), ("linux", ["linux"], "fleet", false),
            ("linux", ["linux"], "fleet", true), (nil, ["macOS"], "admin", false), ("mac", [], "admin", false),
            ("mac", ["macOS", "linux"], "admin", true),
        ]
        let refusals: [(String, String?, Bool)] = [(one, nil, false), (one, one, false), (one, other, false),
                                                   (one, other, true), (one, nil, true)]
        let stops: [(String, String)] = [("100.64.0.2", "http://100.64.0.2:8765"), ("hub", "http://100.64.0.2:8765"),
                                         ("100.64.0.7", "http://100.64.0.2:8765"), ("100.64.0.2", "http://100.64.0.99:8765"),
                                         ("twin", "http://100.64.0.11:8765"), ("100.64.0.11", "http://100.64.0.11:8765")]
        return [
            "tailnet": ["status": status, "hosts": hosts.map { host -> [String: Any] in
                let peer = MacNetwork.peer(of: host, in: status)
                return ["host": host, "node": orNull(MacNetwork.node(of: host, in: status)), "device": orNull(peer?.name),
                        "os": orNull(peer.map { Array($0.os).sorted() })]
            }] as [String: Any],
            "hub_machine_stops": stops.map { item -> [String: Any] in
                let (host, hub) = item
                return ["host": host, "hub": hub, "machine": "hub",
                        "stop": orNull(CentralVaultRemote.hubMachineStop(target: InstallTarget(host: host), hub: URL(string: hub)!,
                                                                         machine: "hub", status: status)),
                        "stop_without_tailscale": orNull(CentralVaultRemote.hubMachineStop(
                            target: InstallTarget(host: host), hub: URL(string: hub)!, machine: "hub", status: nil))]
            },
            "trust_reads": trusts.map { item -> [String: Any] in
                let (kind, os, user, kept) = item
                let read = CentralVaultRemote.trustRead(kind: kind, os: Set(os), user: user, kept: kept)
                return ["kind": orNull(kind), "os": os, "user": user, "kept": kept,
                        "read": orNull(read.map { $0 == .root ? "root" : "agents" })]
            },
            "pin_refusals": refusals.map { item -> [String: Any] in
                let (printed, held, setUp) = item
                return ["printed": printed, "held": orNull(held), "set_up": setUp,
                        "refusal": orNull(CentralVaultPins.refusal(of: printed, held: held, setUp: setUp))]
            },
            "about": "The central vault's root steps and the key registration's proof read, as the owner's computer runs "
                + "them over SSH (windows-app-plan-v2.md, 5.6, piece L6), made by FleetCore's own code.",
            "made_by": madeBy,
            "root_kit": CentralVaultRemote.rootKit, "hub_kit": InstallPlan.hubKit,
            "broker_config": CentralVaultRemote.brokerConfig,
            "installs": installs.map { item -> [String: Any] in
                let (name, key, keep) = item
                let program = CentralVaultRemote.install(ownerKey: key, keepOwner: keep)
                return ["name": name, "owner_key": key, "keep_owner": keep, "program": orNull(program),
                        "through_sudo": orNull(program.map { wire($0) })]
            },
            "bridges": bridges.map { name, keys in
                ["name": name, "keys": keys, "bridge": CentralVaultRemote.bridge(keys: keys)] as [String: Any]
            },
            "read_broker_key": ["program": CentralVaultRemote.readBrokerKey,
                                "through_sudo": wire(CentralVaultRemote.readBrokerKey)],
            "read_mac_vault_key": ["program": CentralVaultRemote.readMacVaultKey,
                                   "as_login": wire(CentralVaultRemote.readMacVaultKey, runs: .login)],
            "broker_keys": brokerOutputs.map { ["output": $0, "key": orNull(CentralVaultRemote.brokerKey(in: $0))] },
            "installed": installedOutputs.map { output -> [String: Any] in
                let answer: Any
                switch CentralVaultRemote.installed(output) {
                case .installed(let recipient, let fleet)?:
                    answer = ["kind": "installed", "recipient": recipient, "fleet": fleet]
                case .refused(let says)?: answer = ["kind": "refused", "says": says]
                case .otherOwner?: answer = ["kind": "other_owner"]
                case nil: answer = NSNull()
                }
                return ["output": output, "answer": answer]
            },
            "proof": [
                "file": OwnerMacKeyRegistration.proofFile,
                "paths": saids.map { ["said": orNull($0), "path": orNull(OwnerMacKeyRegistration.path($0))] },
                "programs": ["/home/fleet/.founderizer/owner-key.proof", "/var/lib/fleet's/owner-key.proof"].map {
                    path -> [String: Any] in
                    let program = OwnerMacKeyRegistration.program(path: path)
                    return ["path": path, "program": program, "as_login": wire(program, runs: .login),
                            "through_sudo": wire(program)]
                },
                "values": proofOutputs.map { ["output": $0, "value": orNull(OwnerMacKeyRegistration.value($0))] },
            ] as [String: Any],
        ]
    }

    static func encoded(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    @Test("The vault's remote vectors are what FleetCore gives now")
    func theRemoteVaultVectorsAreTheCommittedFile() throws {
        let made = try Localized.$bundle.withValue(WordsVectorsTests.noTable) { try Self.encoded(Self.document()) }
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            try made.write(to: URL(fileURLWithPath: out).appendingPathComponent(Self.file))
            return
        }
        let committed = try Data(contentsOf: Self.folder.appendingPathComponent(Self.file))
        #expect(committed == made, "app/vectors/\(Self.file) is not what FleetCore gives: run app/vectors/make_vectors.py")
    }
}
