import Foundation

/// The owner signs a machine's runtime in from the app (`machine_signin`, UI-API.md "Sign a machine in").
///
/// The provider's own flow runs on the machine the credential belongs to: the hub starts it there, passes on the link
/// it prints, and types back the code the owner got from the provider. That is the condition on which a platform may
/// host the unmodified Claude Code at all — the end user signs in through the provider's own flow, and nobody else
/// collects, stores or intermediates the credential. So this app:
///
///   - never asks a provider for a lasting token (`claude setup-token` and anything like it is out of the question),
///   - opens the link in the owner's own browser and nowhere else,
///   - keeps the code in the one request body that carries it: not in a command label, a note or anything saved,
///   - offers no sign-in for Grok, because xAI's terms do not let a third party run it this way.
///
/// The link comes from the machine, so it is checked here as well as in the hub: only the provider's own host, only
/// over HTTPS, and with no user part. A machine must not be able to put a page of its own in front of the owner.
public struct MachineLogin: Decodable, Equatable, Sendable {
    public static let feature = "machine_signin"
    /// The runtimes a sign-in can be driven for. Grok is not one of them and never will be here.
    public static let runtimes = ["claude", "codex"]
    /// The hosts each provider's own sign-in may be on. **`claude.com` is one of them**: that is the host Claude
    /// Code's own `/login` printed on 20 October 2026, and without it the owner was offered no link at all — the
    /// hub takes the link from `RUNTIMES["claude"]["sign_in"]["url"]`, and this list must say the same.
    static let hosts = ["claude": ["claude.ai", "claude.com", "console.anthropic.com"],
                        "codex": ["auth.openai.com"]]

    public let id: Int
    public let runtime: String
    /// `signing_out`, `starting`, `needs_owner`, `signing_in`, `done` or `failed`.
    public let state: String
    public let detail: String?
    public let started_at: Double
    public let updated_at: Double
    /// The provider's own sign-in link, while the sign-in waits for the owner.
    public let url: String?
    /// A code the runtime printed for the owner to type into the provider's page (Codex's device sign-in).
    public let shows_code: String?
    /// True when the provider gives the owner a code to paste back here (Claude Code's sign-in).
    public let wants_code: Bool
    /// True on a `failed` sign-in that ended only because the owner's own step did not come in time (owner API 1.88).
    /// nil from a hub before it.
    public let timed_out: Bool?

    public static func canSignIn(_ runtime: String) -> Bool { runtimes.contains(runtime) }

    /// The code as it may be sent, which is what the machine that types it allows (`fleet.LOGIN_CODE`): letters,
    /// digits, and the dot, underscore, hash and dash. Anything else is refused before it is sent, because it
    /// would be typed into a terminal on that machine.
    ///
    /// **Claude's own code is `code#state`**, two random parts and a hash, about ninety characters. A rule of
    /// forty-one without a hash left the owner with the code in the field and Send grey (21 October 2026).
    public static func code(_ given: String) -> String? {
        let code = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.range(of: "^[A-Za-z0-9][A-Za-z0-9._#-]{3,200}$", options: .regularExpression) != nil else { return nil }
        return code
    }

    /// The link to open, only when it is this provider's own address. nil for anything else.
    public var signInURL: URL? {
        guard state == "needs_owner", let url, let link = URL(string: url), link.scheme == "https",
              let host = link.host?.lowercased(), MachineLogin.hosts[runtime]?.contains(host) == true,
              link.user == nil, link.password == nil, link.port == nil else { return nil }
        return link
    }

    /// **It failed, and he hears of it.** One that only waited too long for him did not (`timed_out`): the owner, 6
    /// November 2026, of "No code came back in 14 minutes." under his provider cards: "that orange message does not
    /// make sense for the user! what is that?!". The way on is to sign in again, which every page of it offers.
    public var isFailure: Bool { state == "failed" && timed_out != true }

    /// **Why it did not finish, without the step the button already is.** The hub's words end in "Start it again"
    /// because they are read where there is nothing to press; on a row that carries Try again, that sentence is
    /// the same instruction twice. Nothing for one that only waited too long for him.
    public var reason: String? {
        guard isFailure else { return nil }
        var words = (detail ?? String(l10n: "The sign-in did not finish.")).trimmingCharacters(in: .whitespaces)
        for tail in ["Start the sign-in again.", "Start it again.", "Try again."] where words.hasSuffix(tail) {
            words = String(words.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        }
        return words.isEmpty ? String(l10n: "The sign-in did not finish.") : words
    }

    /// The code the runtime printed, when it is one.
    public var deviceCode: String? {
        guard let shows_code, MachineLogin.code(shows_code) != nil else { return nil }
        return shows_code
    }

    /// This sign-in is still going on. `signing_out` is the first half of a change of account: no provider starts
    /// a second sign-in while one is live, so the runtime signs out first, in the same job.
    public var isOpen: Bool { ["signing_out", "starting", "needs_owner", "signing_in"].contains(state) }
    /// **The code he sent is still on its way**: this sign-in has not moved since it went (`sentFrom`, its
    /// `updated_at` at the send). One that waits for a code again since then lost that code on the way: the hub puts a
    /// sign-in back when it restarted before the machine took the code (owner API 1.92), and the page asks again.
    public func codeOnItsWay(sentFrom: Double?) -> Bool { state == "needs_owner" && updated_at == sentFrom }
    /// It is signing the old account out, so the agent is already stopped and nothing of the new one is there yet.
    public var isSigningOut: Bool { state == "signing_out" }
    /// It is waiting for the owner to open the link.
    public var waitsForOwner: Bool { state == "needs_owner" && signInURL != nil }
    /// It is waiting for the code the provider gave the owner.
    public var waitsForCode: Bool { waitsForOwner && wants_code }

    /// One line for the machine's row, in the owner's own words.
    public var summary: String {
        switch state {
        case "signing_out": return String(l10n: "Signing out of the account it used…")
        case "starting": return String(l10n: "Starting the sign-in on that server…")
        case "needs_owner":
            if wants_code { return String(l10n: "Open the link, then paste the code it gives you.") }
            return deviceCode.map { String(l10n: "Open the link and enter \($0) there.") } ?? String(l10n: "Open the link to finish the sign-in.")
        case "signing_in": return String(l10n: "The code went to the server…")
        case "done": return detail ?? String(l10n: "Signed in.")
        default: return detail ?? String(l10n: "The sign-in did not finish.")
        }
    }
}

/// The one line a machine's Sign-in row says, and how it says it.
public struct SignInLine: Equatable, Sendable {
    public let says: String
    /// It is a failure to act on, so the row says it in orange. Progress is not a failure and is not orange.
    public let warn: Bool

    public init(says: String, warn: Bool) { self.says = says; self.warn = warn }
}

extension MachineStatus {
    /// The runtime this machine would be signed in to: the one it loaded, else the agent's own.
    public var signInRuntime: String? {
        if let name = runtime.name, MachineLogin.canSignIn(name) { return name }
        return runtimes?.byName.keys.first(where: MachineLogin.canSignIn)
    }

    /// True when this machine's runtime says it is not signed in, so the owner has something to do.
    public var needsSignIn: Bool {
        guard let name = signInRuntime else { return false }
        let reading = runtimes?.byName[name] ?? (runtime.name == name ? runtime : nil)
        return reading?.signed_in == false
    }

    /// This machine waits for the owner's own sign-in: its runtime says it is not signed in, or a sign-in is
    /// going on now. It is what puts the sign-in on the face of a server's page and takes it off again — one that
    /// has started stays there until it ends, whatever the machine's last reading said.
    public var waitsForSignIn: Bool { needsSignIn || login?.isOpen == true }

    /// What the Sign-in row says, in one line and never two.
    ///
    /// **The machine's own `runtime_signed_in` reading is the truth, and a sign-in attempt goes stale against
    /// it.** A sign-in that failed is news only while the machine still reports that it is not signed in; once it
    /// reports that it is, that attempt is history and the row says nothing at all. The owner saw the opposite:
    /// the same failure in grey and in orange at once, and both still there after the machine had been signed in.
    /// One that only waited too long for him is no news at all (`MachineLogin.isFailure`): the row says what it says
    /// when there was no attempt.
    ///
    /// `alreadySaid`: the page has said already that this machine is not signed in. A server's page says it in
    /// its own state row — "Waiting for your sign-in" — so the card under it says only what that row does not:
    /// the attempt that is going on, or the one that failed, and nothing at all while there is no attempt.
    public func signInLine(working: Bool, alreadySaid: Bool = false) -> SignInLine? {
        if working { return SignInLine(says: String(l10n: "Working…"), warn: false) }
        if let login, login.isOpen { return SignInLine(says: login.summary, warn: false) }
        guard needsSignIn else { return nil }
        if let login, login.isFailure { return SignInLine(says: login.summary, warn: true) }
        return alreadySaid ? nil : SignInLine(says: String(l10n: "Not signed in on this server."), warn: false)
    }
}

extension ServerEntry {
    /// The agents of this server that wait for the owner's sign-in, each with its machine's own reading, in the
    /// server's order of agents. Empty for a server whose agents are all signed in, which is what leaves the page
    /// of a machine that is well with nothing new on it.
    public func signIns(_ readings: [MachineStatus]) -> [MachineStatus] {
        agents.compactMap { agent in readings.first { $0.agent == agent } }.filter(\.waitsForSignIn)
    }
}
