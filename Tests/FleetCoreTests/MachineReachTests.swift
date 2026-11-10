import Foundation
import Testing
@testable import FleetCore

/// The facts the server page must take from the hub's own report instead of asking the owner for them: the
/// machine's address, and the user and port the fleet has on record for it.
struct MachineReachTests {
    /// The hub's own four machines, as `GET /ui/machines` answered on 20 October 2026. The Mac has no `access`
    /// entry, which is the case the page must say out loud.
    private static let json = #"""
    {"db":"db","machines":[
     {"agent":"manager","machine":"hub","role":"manager","address":"100.96.10.20",
      "access":{"ssh":{"user":"fleet","port":22,"available":true},"screen_sharing":null},
      "update":{},"runtime":{},"security":{},"os":{"name":"Ubuntu 24.04.4 LTS"}},
     {"agent":"vps","machine":"vps","role":"worker","address":"100.96.100.130",
      "access":{"ssh":{"user":"root","port":2222,"available":true},"screen_sharing":null},
      "update":{},"runtime":{},"security":{},"os":{"name":"Ubuntu 24.04.4 LTS"}},
     {"agent":"studio","machine":"mac-studio","role":"worker","address":"100.96.100.4",
      "access":{"ssh":null,"screen_sharing":null},
      "update":{},"runtime":{},"security":{},"os":{"name":"macOS 15.7.3"}}]}
    """#

    private static func readings() throws -> [MachineStatus] {
        try JSONDecoder().decode(MachineList.self, from: Data(json.utf8)).machines
    }

    @Test func theFleetsOwnRecordAnswersEveryFieldThePageUsedToAskFor() throws {
        let readings = try Self.readings()
        let hub = try #require(MachineReach.of("hub", in: readings))
        let known = try #require(hub.onRecord)
        #expect(known.address == "100.96.10.20")
        #expect(known.user == "fleet")
        #expect(known.port == 22)
        #expect(MachineReach.sentence(machine: "hub", user: known.user, address: known.address, port: known.port,
                                      identityFile: nil)
                == "Founderizer reaches hub as fleet at 100.96.10.20, with the key your SSH agent holds.")
    }

    @Test func aPortThatIsNotTwentyTwoAndAChosenKeyBothShowInTheLine() throws {
        let vps = try #require(try MachineReach.of("vps", in: Self.readings())?.onRecord)
        #expect(vps.port == 2222)
        #expect(MachineReach.sentence(machine: "vps", user: vps.user, address: vps.address, port: vps.port,
                                      identityFile: "/Users/owner/.ssh/id_ed25519")
                == "Founderizer reaches vps as root at 100.96.100.130 on port 2222, with the key id_ed25519.")
    }

    /// A machine the fleet reports without an `access` entry has no connection on record. That is not the same
    /// answer as a machine the hub has not reported at all, and only the first of them is said on the page.
    @Test func aMachineWithoutAnAccessEntryHasNoConnectionOnRecord() throws {
        let readings = try Self.readings()
        let studio = try #require(MachineReach.of("mac-studio", in: readings))
        #expect(studio.address == "100.96.100.4")
        #expect(studio.user == nil)
        #expect(studio.onRecord == nil)
        #expect(MachineReach.nothingOnRecord("mac-studio")
                == "The fleet has no connection to mac-studio on record: it knows no SSH user for that server. "
                + "Give the one you reach it with.")
        #expect(MachineReach.of("worker4", in: readings) == nil)
    }

    /// The hub's record is data, not an instruction: a user name or a port that could not be used as given is
    /// read as missing, and the page asks for one instead of building a command around it.
    @Test func aRecordThatCouldNotBeUsedReadsAsMissing() {
        #expect(MachineReach(address: "100.96.10.20", user: "fleet", port: 0).onRecord == nil)
        #expect(MachineReach(address: "100.96.10.20", user: "-oProxyCommand=id", port: 22).onRecord == nil)
        #expect(MachineReach(address: "", user: "fleet", port: 22).onRecord == nil)
        #expect(MachineReach(address: "100.96.10.20", user: nil, port: 22).onRecord == nil)
    }

    // ---- the control that puts a machine's connection on record (owner feature `machine_access`)

    /// **The control is there exactly where there is something to ask for.** A machine whose connection the fleet
    /// already has gets nothing new, which is the owner's own rule of 20 October 2026: no row that reports only
    /// that everything is fine. And a hub that does not serve the route is asked for nothing at all.
    @Test func theRecordControlShowsOnlyForAMachineWithNoConnectionOnRecord() throws {
        let readings = try Self.readings()
        let features = ["machines", MachineAccessForm.feature]
        let studio = try #require(readings.first { $0.machine == "mac-studio" })
        let hub = try #require(readings.first { $0.machine == "hub" })
        let vps = try #require(readings.first { $0.machine == "vps" })
        #expect(MachineAccessForm.isAsked(of: studio, features: features))
        #expect(!MachineAccessForm.isAsked(of: hub, features: features))
        #expect(!MachineAccessForm.isAsked(of: vps, features: features))
        // A hub without the route, and a machine the app has not read yet, are asked about nothing.
        #expect(!MachineAccessForm.isAsked(of: studio, features: ["machines"]))
        #expect(!MachineAccessForm.isAsked(of: studio, features: nil))
        #expect(!MachineAccessForm.isAsked(of: nil, features: features))
    }

    /// The form asks one question: the user. The port is 22 and Screen Sharing is off until he says otherwise.
    @Test func theFormAsksForTheUserAndDefaultsTheRest() {
        let empty = MachineAccessForm()
        #expect(empty.port == "22")
        #expect(!empty.screenSharing)
        #expect(empty.problem == "Give the user you reach this server as.")
        var form = MachineAccessForm(user: " sam ")
        #expect(form.isValid)
        #expect(form.trimmedUser == "sam")
        #expect(form.portNumber == 22)
        form.user = "-oProxyCommand=id"
        #expect(form.problem?.hasPrefix("A user name is up to 32 characters") == true)
        form.user = "sam"
        for port in ["0", "70000", "", "twenty-two"] {
            form.port = port
            #expect(form.problem == "A port is a number from 1 to 65535.", "port \(port)")
        }
        form.port = "2222"
        #expect(form.isValid)
    }

    /// What the hub would refuse is refused here first, so a 409 never tells him what the app already knew: the
    /// fleet may be recorded as `root`, or as the user that machine's agents run as, and as nothing else.
    @Test func aUserTheFleetMayNotUseIsRefusedBeforeItIsSent() {
        #expect(MachineAccessForm(user: "sam").notAllowed(workerUser: "sam") == nil)
        #expect(MachineAccessForm(user: "root").notAllowed(workerUser: "sam") == nil)
        let refused = try? #require(MachineAccessForm(user: "somebody").notAllowed(workerUser: "sam"))
        #expect(refused?.contains("run as sam") == true)
        #expect(refused?.contains("root or as sam") == true)
        // A machine whose helper reported no user has nothing to compare against: his own word stands.
        #expect(MachineAccessForm(user: "somebody").notAllowed(workerUser: nil) == nil)
        #expect(MachineAccessForm(user: "somebody").notAllowed(workerUser: "") == nil)
    }

    /// The installers let SSH into a Linux machine over the private network only (`hubsetup.py firewall`), so a
    /// connection kept with the public address typed at its install goes to the address the fleet reports.
    @Test func aKeptPublicAddressGoesToThePrivateAddressTheFleetReports() {
        let reach = MachineReach(address: "100.96.100.130", user: "root", port: 22)
        let kept = InstallTarget(host: "198.51.100.7", user: "deploy", port: 2222, identityFile: "/Users/me/.ssh/id",
                                 becomeRoot: true)
        #expect(reach.reaching(kept) == InstallTarget(host: "100.96.100.130", user: "deploy", port: 2222,
                                                      identityFile: "/Users/me/.ssh/id", becomeRoot: true))
        for stays in ["box.example.com", "192.168.1.20", "100.90.1.2", "10.0.0.4", "fd7a:115c:a1e0::1"] {
            let other = InstallTarget(host: stays)
            #expect(reach.reaching(other) == other, "\(stays) is not a public address")
        }
        // A fleet that reports no private address, or a public one, leaves the kept connection as it is.
        #expect(MachineReach(address: nil).reaching(kept) == kept)
        #expect(MachineReach(address: "203.0.113.5").reaching(kept) == kept)
    }

    @Test func aPublicAddressIsOneOnTheInternetWrittenAsOne() {
        for yes in ["198.51.100.7", "203.0.113.9", "172.32.0.1", "100.128.0.1", "2001:db8::1"] {
            #expect(InstallTarget.isPublicAddress(yes), "\(yes)")
        }
        for no in ["10.1.2.3", "172.16.0.1", "192.168.0.1", "100.64.0.1", "100.127.255.254", "127.0.0.1", "169.254.1.1",
                   "0.0.0.0", "224.0.0.1", "fd7a:115c:a1e0::1", "fe80::1", "::1", "box", "box.example.com", ""] {
            #expect(!InstallTarget.isPublicAddress(no), "\(no)")
        }
    }
}
