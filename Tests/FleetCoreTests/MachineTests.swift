import Foundation
import Testing
@testable import FleetCore

struct MachineTests {
    @Test func screenSharingUsesExistingSSHTrustAndOnlyOneLocalForward() throws {
        let connection = ScreenSharingConnection(address: "100.96.100.4", user: "sam", port: 2222)
        let master = try #require(connection.masterArguments(controlPath: "/private/tmp/fleet-vnc-test/c"))
        #expect(master.contains("StrictHostKeyChecking=yes"))
        #expect(master.contains("ClearAllForwardings=yes"))
        #expect(master.contains("ForwardAgent=no"))
        #expect(master.contains("PermitLocalCommand=no"))
        #expect(master.contains("ControlPersist=no"))
        #expect(!master.contains("-F")) // Keep the owner's configured identity and known hosts.
        #expect(!master.contains("-L"))
        #expect(Array(master.suffix(5)) == ["-p", "2222", "-l", "sam", "100.96.100.4"])
        let forward = try #require(connection.forwardArguments(controlPath: "/private/tmp/fleet-vnc-test/c", localPort: 49152))
        #expect(Array(forward.prefix(8)) == ["-F", "/dev/null", "-S", "/private/tmp/fleet-vnc-test/c", "-O", "forward", "-L", "127.0.0.1:49152:127.0.0.1:5900"])
        #expect(connection.forwardArguments(controlPath: "/tmp/c", localPort: 22) == nil)
        #expect(connection.forwardArguments(controlPath: "/tmp/c", localPort: 65536) == nil)
        for bad in [ScreenSharingConnection(address: "100.96.100.4;id", user: "sam", port: 22),
                    ScreenSharingConnection(address: "100.96.100.4", user: "-oProxyCommand=id", port: 22),
                    ScreenSharingConnection(address: "100.96.100.4", user: "sam", port: 0)] {
            #expect(bad.masterArguments(controlPath: "/tmp/c") == nil)
            #expect(bad.forwardArguments(controlPath: "/tmp/c", localPort: 49152) == nil)
        }
    }

    /// **What an agent's own sessions use** (the owner's yes of 4 November 2026): read with its machine, and a figure that
    /// cannot be read is nil and never hides the list.
    @Test func anAgentsOwnUseReadsWithItsMachine() throws {
        let json = #"{"db":"db","machines":[{"agent":"ivy","machine":"mini","role":"worker","update":{},"runtime":{},"security":{},"os":{},"use":{"cpu_percent":4.2,"memory":2469606195}},{"agent":"kai","machine":"mini","role":"worker","update":{},"runtime":{},"security":{},"os":{},"use":{"cpu_percent":null,"memory":-5}},{"agent":"leo","machine":"box","role":"lead","update":{},"runtime":{},"security":{},"os":{}}]}"#
        let list = try JSONDecoder().decode(MachineList.self, from: Data(json.utf8))
        try list.validate(database: "db")
        #expect(list.machines[0].use == AgentUse(cpu_percent: 4.2, memory: 2_469_606_195))
        #expect(list.machines[1].use == AgentUse(cpu_percent: nil, memory: nil))
        #expect(list.machines[2].use == nil)
        let decimal = (0.5).formatted(.number.precision(.fractionLength(1))).dropFirst().first.map(String.init) ?? "."
        #expect(LoadWords.memory(2_469_606_195) == "2\(decimal)3 GB")
        #expect(LoadWords.memory(640 * 1024 * 1024) == "640 MB")
        // Never four figures: 1012 MB is "1,0 GB", and 999 MB stays.
        #expect(LoadWords.memory(1012 * 1024 * 1024) == "1\(decimal)0 GB")
        #expect(LoadWords.memory(999 * 1024 * 1024) == "999 MB")
        #expect(AgentUse(cpu_percent: 130, memory: nil).cpu == 100)
    }

    @Test func unconfiguredVaultDoesNotHideMachineList() throws {
        let json = #"{"db":"db","machines":[{"agent":"manager","machine":"hub","role":"manager","update":{},"runtime":{},"security":{"vault":{"mode":null,"isolated":null}},"os":{}},{"agent":"studio","machine":"mac-studio","role":"worker","update":{},"runtime":{},"security":{"vault":{"mode":"file","isolated":false}},"os":{}}]}"#
        let list = try JSONDecoder().decode(MachineList.self, from: Data(json.utf8))
        try list.validate(database: "db")
        #expect(list.machines.count == 2)
        #expect(list.machines[0].security.vault?.isolated == nil)
        #expect(list.machines[1].security.vault?.isolated == false)
    }

    @Test func machineCheckReceiptKeepsSavedIdentityAndDoesNotClaimCompletion() throws {
        let pending = PendingRequest(hub: URL(string: "http://localhost:8765")!, database: "db", client: "test", command: .machineCheck(agent: "vps"), text: "")
        let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(pending))
        #expect(restored.route == "ui/machines/vps/check")
        #expect(restored.command?.requiredFeature == "machine_check")
        #expect(try restored.body() == pending.body())
        let check: [String: Any] = ["id": 7, "state": "requested", "requested_at": 1000.0]
        let fields: [String: Any] = ["ok": true, "request_id": pending.requestID.uuidString, "client": "test", "replayed": false, "agent": "vps", "check": check]
        func receipt(_ fields: [String: Any]) throws -> ControlReceipt {
            try JSONDecoder().decode(ControlReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        #expect(try receipt(fields).matches(pending))
        #expect(try receipt(fields).check?.isPending == true)
        var wrong = fields; wrong["agent"] = "studio"
        #expect(try !receipt(wrong).matches(pending))
        wrong = fields; wrong["request_id"] = UUID().uuidString
        #expect(try !receipt(wrong).matches(pending))
        wrong = fields; wrong["check"] = ["id": 7, "state": "completed", "requested_at": 1000.0, "completed_at": 1001.0]
        #expect(try !receipt(wrong).matches(pending))
    }

    @Test func machineCheckReportsRequireAValidTerminalStateAndTime() throws {
        func check(_ state: String, completed: Double? = nil) throws -> MachineCheck {
            var fields: [String: Any] = ["id": 1, "state": state, "requested_at": 1000.0]
            if let completed { fields["completed_at"] = completed }
            return try JSONDecoder().decode(MachineCheck.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        #expect(try check("requested").isValid)
        #expect(try !check("requested", completed: 1001).isValid)
        for state in ["completed", "failed", "offline"] {
            #expect(try check(state, completed: 1001).isValid)
            #expect(try !check(state).isValid)
            #expect(try !check(state, completed: 999).isValid)
        }
        #expect(try !check("healthy", completed: 1001).isValid)
    }

    @Test func missingAndStaleMachineDataNeverBecomeHealthy() throws {
        let json = #"{"db":"db","desired_revision":null,"machines":[{"agent":"vps","machine":"vps","role":"worker","update":{},"runtime":{},"security":{},"os":{}}]}"#
        let list = try JSONDecoder().decode(MachineList.self, from: Data(json.utf8))
        try list.validate(database: "db")
        #expect(throws: HubError.self) { try list.validate(database: "other") }
        let missing = try #require(list.machines.first)
        #expect(!missing.isCurrent(at: 2000))
        #expect(missing.security.pending_security == nil)
        #expect(missing.runtime.signed_in == nil)
        let sample = json.replacingOccurrences(of: "\"os\":{}", with: "\"os\":{},\"reported_at\":1000,\"stale\":false")
        let current = try JSONDecoder().decode(MachineList.self, from: Data(sample.utf8)).machines[0]
        #expect(current.isCurrent(at: 1599))
        #expect(!current.isCurrent(at: 1600))
        #expect(!current.isCurrent(at: 990))
    }

    @Test func everyAgentButALeadWithoutTheFeatureUpdatesThroughTheHub() throws {
        /// The one rule the machine page's button, the Health page's Update button and the server page's SSH row
        /// all read. The manager on the hub machine is in it since 19 October 2026: its helper has its own home,
        /// its own checkout and its own user service, so the hub's route reaches it like a worker's. While it was
        /// out, a release left the hub machine behind and Health drew a button the hub refused.
        func reading(_ role: String) throws -> MachineStatus {
            try JSONDecoder().decode(MachineStatus.self, from: Data("""
            {"agent": "a", "machine": "m", "role": "\(role)", "update": {}, "runtime": {}, "security": {}, "os": {}}
            """.utf8))
        }
        for leads in [false, true] {
            #expect(try reading("manager").updatesThroughHub(leads: leads))
            #expect(try reading("worker").updatesThroughHub(leads: leads))
            #expect(try reading("lead").updatesThroughHub(leads: leads) == leads)
        }
    }

    @Test func updateReceiptIsBoundToWorkerClientAndSavedID() throws {
        let pending = PendingRequest(hub: URL(string: "http://localhost:8765")!, database: "db", client: "test", command: .machineUpdate(agent: "vps"), text: "")
        let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(pending))
        #expect(restored.route == "ui/machines/vps/update")
        #expect(restored.command?.requiredFeature == "machines")
        #expect(try restored.body() == pending.body())
        let object: [String: Any] = ["ok": true, "request_id": pending.requestID.uuidString, "client": "test", "replayed": false, "agent": "vps", "state": "requested", "desired_revision": String(repeating: "a", count: 40)]
        func receipt(_ fields: [String: Any]) throws -> ControlReceipt { try JSONDecoder().decode(ControlReceipt.self, from: JSONSerialization.data(withJSONObject: fields)) }
        #expect(try receipt(object).matches(pending))
        var wrong = object; wrong["agent"] = "studio"
        #expect(try !receipt(wrong).matches(pending))
        wrong = object; wrong["client"] = "someone-else"
        #expect(try !receipt(wrong).matches(pending))
        wrong = object; wrong["desired_revision"] = "main"
        #expect(try !receipt(wrong).matches(pending))
    }
}

@Test func machineLinksUseOnlyConfiguredAccountsAndLiteralAddresses() throws {
    func machine(address: String = "100.64.0.10", user: String = "fleet", port: Int = 22, configured: Bool = true) throws -> MachineStatus {
        var fields: [String: Any] = ["agent": "vps", "machine": "vps", "role": "worker", "address": address,
                                     "update": [:], "runtime": [:], "security": [:], "os": [:]]
        if configured { fields["access"] = ["ssh": ["user": user, "port": port], "screen_sharing": [:]] }
        return try JSONDecoder().decode(MachineStatus.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    #expect(try machine().sshURL?.absoluteString == "ssh://fleet@100.64.0.10:22")
    #expect(try machine().screenSharingURL?.absoluteString == "vnc://100.64.0.10")
    #expect(try machine(address: "fd7a:115c:a1e0::1", port: 2222).sshURL?.absoluteString == "ssh://fleet@[fd7a:115c:a1e0::1]:2222")
    #expect(try machine(configured: false).sshURL == nil)
    #expect(try machine(configured: false).screenSharingURL == nil)
    for address in ["example.com", "100.64.0.10/path", "100.64.0.10?command=id", "user@100.64.0.10", "100.64.0.10;open"] {
        #expect(try machine(address: address).sshURL == nil)
        #expect(try machine(address: address).screenSharingURL == nil)
    }
    for user in ["-oProxyCommand=x", "root@other", "fleet;id", "user/name", ""] { #expect(try machine(user: user).sshURL == nil) }
    #expect(try machine(port: 0).sshURL == nil)
    #expect(try machine(port: 65536).sshURL == nil)
}
