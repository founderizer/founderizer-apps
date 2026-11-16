#if os(macOS)
import Foundation

/// **Why an installer stopped, as a fixed name** (the owner's "Yes, build it" of 16 November 2026 to the plan
/// `install-stop-cause-plan.md`, after a customer's report in which the reason of a join's stop was lost with the
/// app's crash). An installer that stops itself prints one sentence of ours after its stop mark: `join.sh`, `hub.sh`,
/// `server.py join` (also when it passes on the hub's refusal of a join), and a Mac's installer, whose sealed state
/// carries the sentence of `join.sh` or of its own `setup.sh`. That sentence is read here and dropped: no word,
/// address or name of it leaves this type, so the kept record (`InstallRecord.cause`) and `setup_diagnosis` may hold
/// the name. **The names differ from the names of the steps and of the stops** (`InstallRecord.StepID`,
/// `InstallRecord.Stop`), so that an agent never reads one for the other.
public enum InstallCause: String, Codable, CaseIterable, Sendable {
    case needsRoot = "needs_root"
    case systemNotSupported = "system_not_supported"
    case noSystemd = "no_systemd"
    case hubNoAnswer = "hub_no_answer"
    case codeNotFetched = "code_not_fetched"
    case joinCodeRefused = "join_code_refused"
    /// The one refusal of a join code that passes: the code expired before the join reached it (a slow package step).
    /// Each try asks the hub for a new code (`InstallRetry`).
    case joinCodeExpired = "join_code_expired"
    case serverNameRefused = "server_name_refused"
    /// The hub could not read the server's name in Tailscale yet, and keeps the code: one of the stops that pass.
    case serverNameUnread = "server_name_unread"
    case hubBusy = "hub_busy"
    case privateNetwork = "private_network"
    case firewall
    case agentUsers = "agent_users"
    case vault
    case updates
    /// The system's packages: an `apt-get` of an installer or of this app's own steps did not finish (a mirror that
    /// failed for a moment), with our own sentence for it since the plan of 16 November 2026.
    case packages
    case service
    case hubClaim = "hub_claim"
    case agentProgram = "agent_program"
    case homebrew
    case wrongMacUser = "wrong_mac_user"
    case other

    /// A name that a later version of the app wrote reads as `other`, so that its record stays readable.
    public init(from decoder: Decoder) throws {
        self = InstallCause(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }

    /// **One row**: a stable part of a stop sentence, in small letters and with no variable in it, and its cause.
    /// `whole`: the sentence is that part and nothing else.
    struct Row: Sendable {
        let part: String
        let cause: InstallCause
        var whole = false
    }

    /// **The rows, in their order**: the first row that a sentence holds decides. Each part has two words or more,
    /// so that no name or path in a sentence holds it. A sentence that ends in another program's own text comes
    /// first, so that no row reads that text: the service's start ends in its system's words, and the claim in what
    /// `hubsetup.py` said. Then a longer part stands before a shorter one that another sentence also holds ("homebrew
    /// could not install" before "could not install tailscale", for a Mac whose Homebrew did not install Tailscale).
    /// A test reads every stop sentence of the installers and holds each to a row, or to its list of sentences that
    /// read as `other`.
    static let rows: [Row] = [
        // A sentence that ends in another program's text.
        Row(part: "the server service did not start", cause: .service),
        Row(part: "did not answer, so the owner claim", cause: .hubClaim),
        // Who runs the line, and on what.
        Row(part: "as the mac user that will run the agents", cause: .wrongMacUser),
        Row(part: "run the line as root", cause: .needsRoot),
        Row(part: "this system is ", cause: .systemNotSupported),
        Row(part: "this system has no /etc/os-release", cause: .systemNotSupported),
        Row(part: " is too old. use macos", cause: .systemNotSupported),
        Row(part: "systemd is required", cause: .noSystemd),
        // A Mac's Homebrew, before the private network: Homebrew can be what did not install Tailscale.
        Row(part: "homebrew is not installed", cause: .homebrew),
        Row(part: "homebrew could not install", cause: .homebrew),
        Row(part: "homebrew could not be downloaded", cause: .homebrew),
        Row(part: "homebrew's package has no valid signature", cause: .homebrew),
        Row(part: "homebrew did not install", cause: .homebrew),
        // A new hub's claim.
        Row(part: "the owner claim did not finish", cause: .hubClaim),
        Row(part: "before the option --manager-name", cause: .hubClaim),
        // The hub, from the server: join.sh's check, server.py's own words, and the words that Python's urllib gives
        // server.py when the hub does not answer, which it passes on.
        Row(part: "cannot reach the founderizer hub at", cause: .hubNoAnswer),
        Row(part: "hub did not answer", cause: .hubNoAnswer),
        Row(part: "urlopen error", cause: .hubNoAnswer),
        Row(part: "remote end closed connection", cause: .hubNoAnswer),
        Row(part: "timed out", cause: .hubNoAnswer, whole: true),
        // The fleet's code: from the hub's port 9418 for a server that joins, from the repository for a new hub.
        Row(part: "could not get the founderizer repository", cause: .codeNotFetched),
        Row(part: "could not clone the founderizer repository", cause: .codeNotFetched),
        Row(part: "could not be cloned from git://", cause: .codeNotFetched),
        // The hub's refusals of a join (hub.py join_server), which server.py passes on.
        Row(part: "join code is not valid", cause: .joinCodeRefused),
        Row(part: "join code was already used", cause: .joinCodeRefused),
        Row(part: "a newer join code replaced", cause: .joinCodeRefused),
        Row(part: "join code expired", cause: .joinCodeExpired),
        Row(part: "too many wrong join codes", cause: .joinCodeRefused),
        Row(part: "this server is in your fleet already", cause: .serverNameRefused),
        Row(part: "could not read this server's name in tailscale", cause: .serverNameUnread),
        Row(part: "and a server's name in fleet has", cause: .serverNameRefused),
        Row(part: "your fleet has a server named", cause: .serverNameRefused),
        Row(part: "keeps that name for itself", cause: .serverNameRefused),
        Row(part: "the hub cannot save the new server now", cause: .hubBusy),
        // The private network: never a bare "tailscale", which other sentences hold.
        Row(part: "could not install tailscale", cause: .privateNetwork),
        Row(part: "no tailscale auth key", cause: .privateNetwork),
        Row(part: "tailscale did not join", cause: .privateNetwork),
        Row(part: "tailscale gave no address", cause: .privateNetwork),
        Row(part: "tailscale's service did not start", cause: .privateNetwork),
        Row(part: "this mac is not on your private network", cause: .privateNetwork),
        // The system's packages: the package steps of join.sh and hub.sh, and this app's own steps that install git or
        // Tailscale's curl (`InstallPlan.packagesStop`).
        Row(part: "package lists could not be updated", cause: .packages),
        Row(part: "the packages of this system could not be installed", cause: .packages),
        // The server's own steps.
        Row(part: "firewall of this", cause: .firewall),
        Row(part: "the firewall did not turn on", cause: .firewall),
        Row(part: "the root helpers of this machine's agent users", cause: .agentUsers),
        Row(part: "os users of this machine's agents", cause: .agentUsers),
        Row(part: "the os user ", cause: .agentUsers),
        Row(part: "the user services of ", cause: .agentUsers),
        Row(part: "the agents of this machine could not be read", cause: .agentUsers),
        Row(part: "vault of this", cause: .vault),
        Row(part: "its vault did not install", cause: .vault),
        Row(part: "fleet patch policy could not be written", cause: .updates),
        Row(part: "the server service of this server could not be made", cause: .service),
        Row(part: "could not write the fleet-", cause: .service),
        Row(part: "did not start. look at", cause: .service),
        Row(part: "fleet-hub is not running", cause: .service),
        Row(part: "the hub is installed but it does not answer", cause: .service),
        Row(part: "did not install for ", cause: .agentProgram),
        Row(part: "claude code did not install", cause: .agentProgram),
        Row(part: "codex did not install", cause: .agentProgram),
    ]

    /// **The cause of the error that ended an install**: the installer's own stop sentence, which an
    /// `InstallError.step` carries after a stop mark (`InstallPlan.stopMarks`), read by the rows; `other` for a
    /// sentence that no row holds. nil for every other stop, whose kind (`InstallRecord.Stop.of`) says all that the
    /// app knows. A Mac's stop is not read here: its sentence is read only from that Mac's sealed state
    /// (`of(sentence:)`), never from a refusal that came in the clear.
    public static func of(_ error: Error) -> InstallCause? {
        guard case .step(_, let says)? = error as? InstallError,
              InstallRecord.Stop.of(error) == .installerStopped,
              let mark = InstallPlan.stopMarks.first(where: says.contains),
              let sentence = says.components(separatedBy: mark).last else { return nil }
        return of(sentence: sentence)
    }

    /// **The cause that an install's stop keeps** (`MachineInstallModel.finish`): the stop sentence of a Mac's sealed
    /// state when there is one (`sealed`), else the error's own (`of(_:)`). A refusal of a Mac that came in the clear
    /// is no sealed state, so it gives none.
    public static func of(_ error: Error, sealed: String?) -> InstallCause? {
        sealed.map(of(sentence:)) ?? of(error)
    }

    /// The cause of one stop sentence, without its mark: the first row that it holds, else `other`.
    public static func of(sentence: String) -> InstallCause {
        let said = sentence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.first { $0.whole ? said == $0.part : said.contains($0.part) }?.cause ?? .other
    }
}
#endif
