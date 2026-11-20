import Foundation
import Testing
@testable import FleetCore

/// The tunnel and the address of Screen Sharing for a take-over (`ScreenSharingConnection`; build plan 04, S6): a Mac's
/// own screen as before, and an agent's screen on a Linux server at its own port, as root with this Mac's record of the
/// server, with the one-time password in the address only.
struct ScreenSharingTests {
    private let mac = ScreenSharingConnection(address: "100.64.0.3", user: "owner-example", port: 22)

    /// A server's entry of `GET /ui/servers` whose reading names its parts and two agents' users and ports.
    private func server(state: String = "ready", users: [String: Any]? = nil, kind: String = "linux") throws -> ServerEntry {
        let reading: [String: Any] = [
            "source": "server", "os": ["name": "Ubuntu 24.04"], "runtimes": [:], "reported_at": 1_000_000.0,
            "stale": false, "user": "fleet",
            "agents": users ?? ["alpha": ["user": "fleet-alpha", "uid": 1002], "beta": ["user": "fleet-beta", "uid": 1003]],
            "browser": ["state": state, "missing": [], "files": [:], "unit": "active", "added": true, "worker": 1000,
                        "ports": [["user": "fleet-alpha", "devtools": 9301, "screen": 5911],
                                  ["user": "fleet-beta", "devtools": 9302, "screen": 5912]]]]
        let entry: [String: Any] = ["name": "app-1", "hub": false, "joined": true, "kind": kind, "agents": ["alpha", "beta"],
                                    "address": "100.80.1.7", "available": true, "why": [], "reading": reading]
        return try JSONDecoder().decode(ServerEntry.self, from: JSONSerialization.data(withJSONObject: entry))
    }

    /// A Mac's own screen stays at loopback:5900 with the owner's SSH agent, as the machine's page opened it before.
    @Test func aMacsScreenIsItsOwnScreenSharing() throws {
        #expect(mac.remotePort == 5900 && mac.identityFile == nil && mac.agent == nil && mac.isValid)
        let forward = try #require(mac.forwardArguments(controlPath: "/tmp/c", localPort: 15000))
        #expect(forward.contains("127.0.0.1:15000:127.0.0.1:5900"))
        let master = try #require(mac.masterArguments(controlPath: "/tmp/c"))
        #expect(!master.contains("-i") && master.suffix(5) == ["-p", "22", "-l", "owner-example", "100.64.0.3"])
        let old = Data(#"{"address":"100.64.0.3","user":"owner-example","port":22}"#.utf8)    // a connection of before
        #expect(try JSONDecoder().decode(ScreenSharingConnection.self, from: old) == mac)
    }

    /// An agent's screen on its Linux server: the tunnel goes to that agent's port, with this Mac's key of the server,
    /// strictly to its known host; the key of the tunnel holds the agent, so two agents of one server have two.
    @Test func aLinuxAgentsScreenIsItsOwnPortWithTheServersKey() throws {
        let target = InstallTarget(host: "100.80.1.7", user: "root", port: 22, identityFile: "/Users/owner/.ssh/fleet_ed25519")
        let alpha = try #require(ScreenSharingConnection.linux(target: target, port: 5911, agent: "alpha"))
        let beta = try #require(ScreenSharingConnection.linux(target: target, port: 5912, agent: "beta"))
        #expect(Set([alpha, beta]).count == 2)
        let forward = try #require(alpha.forwardArguments(controlPath: "/tmp/c", localPort: 15000))
        #expect(forward.contains("127.0.0.1:15000:127.0.0.1:5911"))
        #expect(alpha.screenSharingAddress(localPort: 15000) == nil)       // only with its password (viewerAddress)
        let master = try #require(alpha.masterArguments(controlPath: "/tmp/c"))
        #expect(master.contains("StrictHostKeyChecking=yes") && master.contains("IdentitiesOnly=yes"))
        #expect(master[master.firstIndex(of: "-i")! + 1] == "/Users/owner/.ssh/fleet_ed25519")
        #expect(master.suffix(5) == ["-p", "22", "-l", "root", "100.80.1.7"])
        let sent = try JSONEncoder().encode(alpha)
        #expect(try JSONDecoder().decode(ScreenSharingConnection.self, from: sent) == alpha)
    }

    /// **Only x11vnc's greeting opens a Linux agent's screen** (the owner's yes of 20 November 2026 to this guard and
    /// to its words): a program that answers an agent's port with Apple's greeting (the way to Screen Sharing's
    /// warning) or with any other 12 bytes is another program, and the owner reads the approved words in his language,
    /// never the helper's code. A Mac's own screen opens for any whole greeting, as before; fewer than 12 bytes are no
    /// answer.
    @Test func onlyX11vncsGreetingOpensALinuxAgentsScreen() throws {
        let agent = ScreenSharingConnection(address: "100.80.1.7", user: "root", port: 22, remotePort: 5911,
                                            agent: "alpha")
        func line(_ text: String) -> [UInt8] { Array(text.utf8) }
        #expect(agent.greeting(line("RFB 003.008\n")) == .expected && mac.greeting(line("RFB 003.008\n")) == .expected)
        for other in ["RFB 003.889\n", "RFB 003.003\n", "RFB 003.007\n", "RFB 004.001\n", "HTTP/1.1 200"] {
            #expect(agent.greeting(line(other)) == .foreign, "\(other)")
        }
        #expect(agent.greeting(line("RFB 003.00") + [0xff, 0x0a]) == .foreign)
        #expect(mac.greeting(line("RFB 003.889\n")) == .expected && mac.greeting(line("HTTP/1.1 200")) == .none)
        for part in ["", "RFB 003.00"] {
            #expect(agent.greeting(line(part)) == .none && mac.greeting(line(part)) == .none, "\(part)")
        }
        #expect(agent.failureWords("SSH could not start.") == "SSH could not start.")
        #expect(mac.failureWords(ScreenGreeting.foreignDetail) == "Screen Sharing could not connect.")
        let english = agent.failureWords(ScreenGreeting.foreignDetail)
        #expect(english.hasSuffix("treat the logins of its browser as exposed."))
        let spanish = try SpanishTable.run { agent.failureWords(ScreenGreeting.foreignDetail) }
        #expect(spanish.hasSuffix("da por expuestos los inicios de sesión de su navegador."))
    }

    /// Only as root: the server's port rule lets root and its worker user reach an agent's screen-sharing port, and a
    /// user who becomes root with sudo would be refused there. A key's path or an agent's name of another shape is none.
    @Test func noLinuxWayButAsRootAndOfItsShape() {
        let sudo = InstallTarget(host: "100.80.1.7", user: "admin", port: 22, becomeRoot: true)
        #expect(ScreenSharingConnection.linux(target: sudo, port: 5911, agent: "alpha") == nil)
        let named = InstallTarget(host: "app-1.example", user: "root", port: 22)        // not an address
        #expect(ScreenSharingConnection.linux(target: named, port: 5911, agent: "alpha") == nil)
        let root = InstallTarget(host: "100.80.1.7", user: "root", port: 22)
        #expect(ScreenSharingConnection.linux(target: root, port: 0, agent: "alpha") == nil)
        #expect(ScreenSharingConnection.linux(target: root, port: 5911, agent: "Alpha;rm") == nil)
        for path in ["relative/key", "/Users/owner/../../etc/key", "/Users/owner/key\n-oProxyCommand=x"] {
            let way = ScreenSharingConnection(address: "100.80.1.7", user: "root", port: 22, remotePort: 5911,
                                              identityFile: path, agent: "alpha")
            #expect(!way.isValid, "\(path)")
        }
    }

    /// The one-time password goes into Screen Sharing's address only, with which it asks for nothing, with a user of
    /// the agent's own, so that Screen Sharing takes no sign-in that it keeps for 127.0.0.1 (which can be another
    /// Mac's); a password of another shape opens nothing, and a Mac's own screen has no such address (it opens at
    /// `screenSharingAddress`: MachineTests).
    @Test func thePasswordIsInTheAddressOnly() throws {
        let alpha = try #require(ScreenSharingConnection.linux(
            target: InstallTarget(host: "100.80.1.7", user: "root", port: 22), port: 5911, agent: "alpha"))
        #expect(alpha.viewerAddress(localPort: 15911, password: "Ab3dEf7h")?.absoluteString
                == "vnc://takeover-alpha:Ab3dEf7h@127.0.0.1:15911")
        for bad in ["short", "Ab3dEf7h9", "Ab3d@f7h", "Ab3d f7h", ""] {
            #expect(alpha.viewerAddress(localPort: 15911, password: bad) == nil, "\(bad)")
        }
        #expect(alpha.viewerAddress(localPort: 80, password: "Ab3dEf7h") == nil)
        #expect(mac.viewerAddress(localPort: 15911, password: "Ab3dEf7h") == nil)
    }

    /// The port of the agent's own user, from the server's own reading of ready parts; none for another server, parts
    /// that are not ready, or an agent whose user the reading does not name.
    @Test func theAgentsPortIsTheOneOfItsUserOnReadyParts() throws {
        #expect(try server().screenPort(of: "alpha") == 5911)
        #expect(try server().screenPort(of: "beta") == 5912)
        #expect(try server().screenPort(of: "gamma") == nil)
        #expect(try server(state: "missing").screenPort(of: "alpha") == nil)
        #expect(try server(kind: "mac").screenPort(of: "alpha") == nil)
        #expect(try server(users: ["alpha": ["user": "fleet-other", "uid": 1009]]).screenPort(of: "alpha") == nil)
    }

    /// An agent on a Linux server, by the servers list or by its machine's system, never takes a Mac's Screen Sharing
    /// way (its server's 5900 has no password and no rule); an agent on a Mac does.
    @Test func aLinuxAgentIsKnownByItsServerOrItsSystem() throws {
        let servers = [try server()]
        #expect(TakeOverLinux.onLinuxServer("alpha", servers: servers, systemName: "macOS 26.1"))
        #expect(TakeOverLinux.onLinuxServer("ivy", servers: nil, systemName: "Ubuntu 24.04.3 LTS"))
        #expect(!TakeOverLinux.onLinuxServer("ivy", servers: servers, systemName: "macOS 26.1"))
        #expect(!TakeOverLinux.onLinuxServer("ivy", servers: nil, systemName: nil))
        #expect(!TakeOverLinux.onLinuxServer("alpha", servers: [try server(kind: "mac")], systemName: nil))
    }

    /// Take over shows only for a helper that the hub's reading names online and that does the step: an offline helper,
    /// or one from before the step, gives none, and he answers in words. The reading's own mark decides, not the time
    /// at which the card is drawn again, so a card that stays on screen keeps its Take over.
    @Test func theHelperOpensTheScreenOnlyWhenItIsCurrentAndDoesTheStep() throws {
        func machine(_ fields: String) throws -> MachineStatus {
            let text = #"{"agent":"alpha","machine":"app-1","role":"worker","update":{},"runtime":{},"security":{},"#
                + #""os":{"name":"Ubuntu 24.04.3 LTS"},"# + fields + "}"
            return try JSONDecoder().decode(MachineStatus.self, from: Data(text.utf8))
        }
        let old = 1_000.0       // a reading from long ago that the hub still judged fresh when the app read it
        #expect(TakeOverLinux.helperReady(try machine(#""reported_at":\#(old),"stale":false,"features":["takeover_screen"]"#)))
        #expect(!TakeOverLinux.helperReady(try machine(#""reported_at":\#(old),"stale":true,"features":["takeover_screen"]"#)))
        #expect(!TakeOverLinux.helperReady(try machine(#""features":["takeover_screen"]"#)))      // it never reported
        #expect(!TakeOverLinux.helperReady(try machine(#""reported_at":\#(old),"stale":false,"features":["mcp_program"]"#)))
        #expect(!TakeOverLinux.helperReady(nil))
    }

    /// The hub's answer is a port of the agents' range and a password of 8 letters and digits, and it opens the
    /// tunnel's screen only for its own agent, server and port.
    @Test func theHubsAnswerIsOfItsShape() {
        let answer = TakeOverScreen(agent: "alpha", server: "app-1", port: 5911, password: "Ab3dEf7h")
        #expect(answer.opens(agent: "alpha", server: "app-1", port: 5911))
        #expect(!answer.opens(agent: "alpha", server: "app-2", port: 5911))     // another server's port of that number
        #expect(!answer.opens(agent: "alpha", server: nil, port: 5911))
        #expect(!answer.opens(agent: "beta", server: "app-1", port: 5911))
        #expect(!answer.opens(agent: "alpha", server: "app-1", port: 5912))
        #expect(TakeOverScreen(agent: "alpha", server: "app-1", port: 5911, password: "Ab3dEf7h").isValid)
        #expect(!TakeOverScreen(agent: "alpha", server: "app-1", port: 22, password: "Ab3dEf7h").isValid)
        #expect(!TakeOverScreen(agent: "alpha", server: "app-1", port: 5911, password: "Ab3dEf7").isValid)
    }
}
