import Foundation
import Testing
@testable import FleetCore

/// **Why an installer stopped, as a fixed name** (`InstallCause`, the plan `install-stop-cause-plan.md`): each stop
/// sentence of ours has its cause, the error of an install gives one only for the installer's own stop, the names
/// are their own, and every stop sentence of the installers has a row or a place among the sentences that read as
/// `other`.
struct InstallCauseTests {
    /// **The sentences as the installers print them**, with example values where theirs have a variable.
    @Test func eachSentenceOfOursHasItsCause() {
        let cases: [(String, InstallCause)] = [
            ("Run the line as root (for example after sudo -i).", .needsRoot),
            ("This system is centos 9. Use Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13.", .systemNotSupported),
            ("This system has no /etc/os-release. Use Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13.",
             .systemNotSupported),
            ("macOS 13.6 is too old. Use macOS 14 or later.", .systemNotSupported),
            ("systemd is required: the hub runs as a systemd user service.", .noSystemd),
            ("This machine cannot reach the Founderizer hub at http://100.64.0.7:8765. Check that Tailscale is "
                + "connected, and the Tailscale access rules for the hub's ports 8765 and 9418.", .hubNoAnswer),
            ("The hub did not answer (502). Check the private network, then run the line again.", .hubNoAnswer),
            ("Your hub did not answer. Try again.", .hubNoAnswer),
            ("<urlopen error [Errno 111] Connection refused>", .hubNoAnswer),
            ("Remote end closed connection without response", .hubNoAnswer),
            ("timed out", .hubNoAnswer),
            ("Could not get the Founderizer repository from git://100.64.0.7:9418/fleet.git. Check the Tailscale "
                + "access rules for the hub's port 9418.", .codeNotFetched),
            ("Could not clone the Founderizer repository from https://example.com/founderizer.git.", .codeNotFetched),
            ("The checkout of agent-1 could not be cloned from git://100.64.0.7/agent-1.git. Check that fleet-git runs.",
             .codeNotFetched),
            ("This join code is not valid. Copy the line again from Founderizer: Settings, Servers, Add server.",
             .joinCodeRefused),
            ("This join code was already used. Make a new code in Founderizer: Settings, Servers, Add server.",
             .joinCodeRefused),
            ("A newer join code replaced this code. Copy the newest line from Founderizer.", .joinCodeRefused),
            ("This join code expired. Make a new code in Founderizer: Settings, Servers, Add server.", .joinCodeExpired),
            ("Too many wrong join codes from this address. Wait 10 minutes, then try again.", .joinCodeRefused),
            ("This server is in your fleet already, as worker-2.", .serverNameRefused),
            ("The hub could not read this server's name in Tailscale. Run the line again in a minute.",
             .serverNameUnread),
            ("This server is called x in Tailscale, and a server's name in Fleet has 2 to 31 letters.",
             .serverNameRefused),
            ("Your fleet has a server named worker-2. Rename one of the two in Tailscale, then run the line again.",
             .serverNameRefused),
            ("This server is called hub in Tailscale, and Fleet keeps that name for itself. Rename this server in "
                + "Tailscale, then run the line again.", .serverNameRefused),
            ("The hub cannot save the new server now. Run the line again in a few minutes.", .hubBusy),
            ("Could not install Tailscale.", .privateNetwork),
            ("No Tailscale auth key came in.", .privateNetwork),
            ("Tailscale did not join with that auth key.", .privateNetwork),
            ("Tailscale gave no address for this machine. Check: tailscale status", .privateNetwork),
            ("Tailscale's service did not start.", .privateNetwork),
            ("This Mac is not on your private network.", .privateNetwork),
            ("The firewall of this machine could not be set: the line above says why. Run the line again.", .firewall),
            ("the firewall of this server could not be set: the line above says why. Run the line again.", .firewall),
            ("The firewall did not turn on.", .firewall),
            ("The root helpers of this machine's agent users and its vault broker could not be put in place.",
             .agentUsers),
            ("The OS users of this machine's agents could not be made.", .agentUsers),
            ("The OS user agent-1 of agent-1 is not there. Run the line again.", .agentUsers),
            ("The user services of agent-1 are not reachable (/run/user/1001).", .agentUsers),
            ("The vault of this machine could not be set up. Nothing of the owner's was read or changed.", .vault),
            ("This Mac joined your fleet, but its vault did not install.", .vault),
            ("The fleet patch policy could not be written: the line above says why. Run the line again.", .updates),
            ("The server service did not start: Failed to start fleet-server.service", .service),
            ("fleet-hub is not running. Look at: systemctl --user status fleet-hub", .service),
            ("fleet-agent-1 did not start. Look at: systemctl --user status fleet-agent-1", .service),
            ("the hub is installed but it does not answer. Look at: systemctl --user status fleet-hub", .service),
            // A kit whose folder ends in "hub" holds "hub did not answer": the claim's row comes first.
            ("the hub's own copy of hubsetup.py in /home/fleet/hub did not answer, so the owner claim cannot start.",
             .hubClaim),
            ("the owner claim did not finish: the line above says why.", .hubClaim),
            ("claude did not install for agent-1. Install it as agent-1, then run the line again.", .agentProgram),
            ("Claude Code did not install. Try again.", .agentProgram),
            ("Codex did not install. Look at this server in Founderizer.", .agentProgram),
            ("Homebrew is not installed. Install it from https://brew.sh, then run the line again.", .homebrew),
            ("Homebrew could not install tmux python.", .homebrew),
            // Homebrew that did not install Tailscale is Homebrew's: its row comes before the private network's.
            ("Homebrew could not install tailscale.", .homebrew),
            ("Homebrew could not be downloaded.", .homebrew),
            ("Homebrew's package has no valid signature.", .homebrew),
            ("Homebrew did not install.", .homebrew),
            // Another program's text at the end of a sentence is not read: the sentence's own part comes first.
            ("The server service did not start: urlopen error; this system is busy; run the line as root", .service),
            ("the hub's own copy of hubsetup.py in /home/fleet/kit did not answer, so the owner claim cannot start. "
                + "It said: run the line as root; this system is old; urlopen error", .hubClaim),
            // A name never holds a row's part: each part has two words or more.
            ("Your fleet has a server named homebrew-1. Rename one of the two in Tailscale.", .serverNameRefused),
            ("Run the line in Terminal as the Mac user that will run the agents, not as root.", .wrongMacUser),
            // Not ours to name: these read as `other`.
            ("FLEET_REBOOT_TIME is for Ubuntu only: the fleet patch policy is Ubuntu's.", .other),
            ("No join code. Copy the whole line from Founderizer: Settings, Servers, Add server.", .other),
            ("E: Could not get lock /var/lib/dpkg/lock-frontend.", .other),
            ("ssh: connect to host 100.64.0.9 port 22: Connection timed out", .other),
            ("", .other),
        ]
        for (sentence, cause) in cases {
            #expect(InstallCause.of(sentence: sentence) == cause, "\(sentence)")
        }
        #expect(InstallCause.of(sentence: "  TIMED OUT \n") == .hubNoAnswer)
    }

    /// **The error of an install gives a cause only for the installer's own stop**: the sentence after its mark, of
    /// each mark; nil for a step that failed with no mark, for `ssh`'s own words, for every other error, and for a
    /// Mac's refusal, whose words may come in the clear (a Mac's cause is read from its sealed state only).
    @Test func theErrorOfAnInstallGivesACauseOnlyForTheInstallersStop() {
        func step(_ says: String) -> InstallError { .step("Join the fleet", says) }
        #expect(InstallCause.of(step("Founderizer join stopped: Could not get the Founderizer repository from "
                                     + "git://100.64.0.7:9418/fleet.git. Check the Tailscale access rules for the "
                                     + "hub's port 9418.")) == .codeNotFetched)
        #expect(InstallCause.of(step("Fleet join stopped: Run the line as root (for example after sudo -i).")) == .needsRoot)
        #expect(InstallCause.of(step("Founderizer install stopped: Could not install Tailscale.")) == .privateNetwork)
        #expect(InstallCause.of(step("Founderizer join stopped: <urlopen error timed out>")) == .hubNoAnswer)
        #expect(InstallCause.of(step("Founderizer join stopped: Something that no row knows.")) == .other)
        #expect(InstallCause.of(step("Founderizer join stopped: ")) == nil)
        #expect(InstallCause.of(step("E: Could not get lock /var/lib/dpkg/lock-frontend.")) == nil)
        #expect(InstallCause.of(step("ssh: connect to host 203.0.113.9 port 22: Connection refused")) == nil)
        #expect(InstallCause.of(MacLinkError.refused("Homebrew is not installed.")) == nil)
        #expect(InstallCause.of(InstallError.timedOut("Join the fleet")) == nil)
        #expect(InstallCause.of(URLError(.timedOut)) == nil)
        // **The cause that a stop keeps** (`of(_:sealed:)`, the model's one call): a Mac's sealed sentence when there
        // is one, else the error's own; a Mac's refusal with no sealed state gives none.
        let refused = MacLinkError.refused("Homebrew is not installed.")
        #expect(InstallCause.of(refused, sealed: "Homebrew is not installed.") == .homebrew)
        #expect(InstallCause.of(refused, sealed: "A sentence that no row knows.") == .other)
        #expect(InstallCause.of(refused, sealed: nil) == nil)
        #expect(InstallCause.of(step("Founderizer join stopped: The hub cannot save the new server now."), sealed: nil)
                == .hubBusy)
        #expect(InstallCause.of(step("E: Could not get lock /var/lib/dpkg/lock-frontend."), sealed: nil) == nil)
    }

    /// **The model keeps the cause as it keeps the stop** (`MachineInstallModel` in the app, which no test target
    /// imports, so its source is read): each line that clears the stop clears the cause, the stop takes the cause of
    /// `of(_:sealed:)`, and the one call that gives a sealed sentence gives the sealed state's.
    @Test func theModelKeepsTheCauseAsItKeepsTheStop() throws {
        let model = try String(contentsOf: Self.app.appendingPathComponent("Sources/Founderizer/MachineInstallView.swift"),
                               encoding: .utf8)
        let lines = model.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let clears = lines.filter { $0.contains("stop = nil") }
        #expect(clears.count >= 3)
        for line in clears { #expect(line.contains("cause = nil"), "\(line)") }
        #expect(lines.contains("cause = InstallCause.of(error, sealed: sealed)"))
        #expect(lines.contains("log?.stop(kind, says: InstallRecord.words(of: error, host: target.host), cause: cause,"))
        // The hub's install and a server's stop through `tries`, after the retry's decision (`InstallRetry`): one call
        // for both. A Mac's link stops through its own two.
        let finishes = lines.filter { $0.contains("finish(error:") && !$0.contains("func finish") }
        #expect(finishes.count >= 3)
        #expect(lines.contains("else { return finish(error: error) }"))
        #expect(finishes.filter { $0.contains("sealed:") }
                == ["if failure == nil { finish(error: MacLinkError.refused(state.says), sealed: state.says) }"])
    }

    /// **The names are snake case and their own**: none is the name of a step or of a kind of stop, so that an agent
    /// never reads one for another, and `other`, the last, is the one name that the three lists share. Each name but
    /// `other` is the cause of a row, each row's part is in small letters, and a name that a later version wrote
    /// reads as `other`.
    @Test func theNamesAreTheirOwn() throws {
        let names = InstallCause.allCases.map(\.rawValue)
        let snake = try NSRegularExpression(pattern: "^[a-z]+(_[a-z]+)*$")
        for name in names {
            #expect(snake.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil, "\(name)")
        }
        let theirs = Set(InstallRecord.StepID.allCases.map(\.rawValue) + InstallRecord.Stop.allCases.map(\.rawValue))
        #expect(Set(names).intersection(theirs) == ["other"])
        #expect(names.last == "other" && Set(names).count == names.count)
        #expect(Set(InstallCause.rows.map(\.cause)) == Set(InstallCause.allCases).subtracting([.other]))
        for row in InstallCause.rows { #expect(row.part == row.part.lowercased() && !row.part.isEmpty, "\(row.part)") }
        let read = try JSONDecoder().decode([InstallCause].self, from: Data(#"["code_not_fetched", "a_later_one"]"#.utf8))
        #expect(read == [.codeNotFetched, .other])
    }

    // MARK: the installers' own sentences

    static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let repository = app.deletingLastPathComponent()
    /// **The hub's files are in the private repository only**: the public copy of the apps has none of them, and
    /// skips the test. Where one is there, the test runs, and a file of the five that is gone fails it.
    static var repositoryHasAHubFile: Bool {
        ["join.sh", "hub.sh", "server.py", "hub.py", "refusal_words.py"].contains {
            FileManager.default.fileExists(atPath: repository.appendingPathComponent($0).path)
        }
    }

    /// The text that `pattern`'s first group takes in `text`, each time, with an escaped quote as a quote.
    static func captures(_ pattern: String, in text: String) throws -> [String] {
        try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]).replacingOccurrences(of: "\\\"", with: "\"") } }
    }

    /// **Every stop sentence of the installers has a row, or a place among the sentences that read as `other`**:
    /// `join.sh`, `hub.sh`, the stops of `server.py join` (`die`), the hub's refusals of a join (`join_server` in
    /// `hub.py`, with the English of each coded refusal there from `refusal_words.py`), a Mac's `setup.sh` and the
    /// stops of a Mac's installer. A new sentence fails here until somebody gives it a cause or a place below.
    @Test(.enabled(if: InstallCauseTests.repositoryHasAHubFile)) func everyStopSentenceHasItsPlace() throws {
        func read(_ path: String, in folder: URL = Self.repository) throws -> String {
            try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
        }
        // A shell's stop: a line that goes on in the next one is one sentence.
        func stops(_ path: String, in folder: URL = Self.repository) throws -> [String] {
            try Self.captures(#"\bstop "((?:[^"\\]|\\.)*)""#,
                              in: read(path, in: folder).replacingOccurrences(of: "\\\n", with: ""))
        }
        let hub = try read("hub.py")
        let start = try #require(hub.range(of: "def join_server("))
        let end = try #require(hub.range(of: "\ndef ", range: start.upperBound..<hub.endIndex))
        let joins = String(hub[start.lowerBound..<end.lowerBound])
        let words = try read("refusal_words.py")
        var sentences: [String: [String]] = [:]
        sentences["join.sh"] = try stops("join.sh")
        sentences["hub.sh"] = try stops("hub.sh")
        sentences["setup.sh"] = try stops("Installer/setup.sh", in: Self.app)
        sentences["server.py"] = try Self.captures(#"\bdie\((?:answer\.get\("error"\) or )?f?"((?:[^"\\]|\\.)*)""#,
                                                   in: read("server.py"))
        sentences["hub.py"] = try Self.captures(#"Refusal\(\d+,\s*f?"((?:[^"\\]|\\.)*)""#, in: joins)
            + Self.captures(#"code="(\w+)""#, in: joins).flatMap { code in
                try Self.captures("\"\(code)\":\\s*\\(?\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", in: words)
            }
        sentences["installer"] = try Self.captures(#"\bstop\("((?:[^"\\]|\\.)*)"\)"#,
                                                   in: read("Sources/FounderizerInstaller/InstallerApp.swift", in: Self.app))
        // At least this many of each, so that a reading that finds none does not pass.
        let least = ["join.sh": 15, "hub.sh": 40, "setup.sh": 15, "server.py": 6, "hub.py": 10, "installer": 3]
        for (file, count) in least {
            #expect(sentences[file, default: []].count >= count, "\(file): \(sentences[file, default: []].count)")
        }
        // The sentences that read as `other`: an option of the line, a folder or a file of the hub's own install,
        // a Mac's own tools and settings, and a few that say in their own words what to do. Each part is held to a
        // sentence, so that none stays here after its sentence has gone.
        let others = ["and the line says --kind", "fleet_reboot_time", "unknown option", "--port must", "--claim-wait must", "--runtime must",
                      "$name_rule", "fleet_shape_step", "fleet_hub_server=shared",
                      "is there and is not a founderizer checkout", "is not a copy of the founderizer repository",
                      "is not a git checkout with a commit", "could not make a folder for the auth key",
                      "could not make a temporary file", "the hub's own repository could not be made",
                      "this fleet's own id could not be made", "no join code",
                      "the hub gave an answer that founderizer cannot use", "has not joined your fleet",
                      "this address is", "developer tools", "could not be downloaded", "could not be installed",
                      "could not be opened", "has no valid signature", "chrome did not start",
                      "remote login did not turn on", "screen sharing did not turn on", "power settings did not change",
                      "this mac did not join your fleet", "not your hub's own join line",
                      "this installer has no setup step", "could not save the order", "needs your password to go on",
                      "gives no address of the releases", "where the hub takes its releases",
                      "lost its ipv4 route"]
        var used = Set<String>()
        for (file, list) in sentences {
            for sentence in list where InstallCause.of(sentence: sentence) == .other {
                let said = sentence.lowercased()
                let part = others.first { said.contains($0) }
                #expect(part != nil, "\(file): no cause and no place among the others: \(sentence)")
                if let part { used.insert(part) }
            }
        }
        #expect(used == Set(others), "parts that no sentence uses: \(Set(others).subtracting(used).sorted())")
    }
}
