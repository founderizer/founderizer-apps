import Foundation

/// One answer of `python3 fleet.py verify` on one machine of a fleet (PRODUCT.md 4.1).
///
/// The command is the one health check of the whole product: the app, the installing agent and the support duty all
/// read this one shape. `says` is the line the check wrote for a person, and `fix` is the one thing that puts it
/// right, or nil when nothing is wrong.
public struct VerifyCheck: Codable, Equatable, Identifiable, Sendable {
    public let check: String
    /// `ok`, `warn` or `fail`. A warn is not a failure: the machine is ready with warnings.
    public let state: String
    public let says: String
    public let fix: String?
    /// The exact command of that fix, where it has one (PRODUCT.md 4.1). A hub since 30 October 2026 keeps it apart,
    /// so that `fix` is his words alone; an older one sends none and wrote the command inside `fix`. No screen shows
    /// it: only the prompt that Report a problem copies for his agent carries it (`TroublePrompt`). `isValid` does
    /// not read it, so a line he never sees cannot make his checks unreadable.
    public let command: String?
    public var id: String { check }

    public init(check: String, state: String, says: String, fix: String? = nil, command: String? = nil) {
        self.check = check; self.state = state; self.says = says; self.fix = fix; self.command = command
    }

    public var failed: Bool { state == "fail" }
    public var warned: Bool { state == "warn" }
    public var passed: Bool { state == "ok" }

    /// The shape 4.1 freezes, and nothing else: an id of its own, one of the three states, one line of at most 300
    /// characters, and a fix that an `ok` does not carry.
    public var isValid: Bool {
        check.range(of: "^[a-z][a-z0-9_]{0,30}$", options: .regularExpression) != nil &&
            ["ok", "warn", "fail"].contains(state) && !says.isEmpty && says.count <= 300 &&
            (fix.map { !$0.isEmpty && $0.count <= 300 } ?? true) && !(passed && fix != nil)
    }

    /// The title of this check on the owner's own checklist.
    public var title: String { VerifyChecklist.title(check) }
    /// The mark of its state, for a row that says it without words.
    public var symbol: String {
        failed ? "xmark.circle.fill" : warned ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }
}

/// The checklist of one machine: what `verify` answered there, as the app shows it (PRODUCT.md P3).
///
/// **A check that does not apply to this machine is absent from the array, and a missing id is never a pass**
/// (4.1, and the first thing P1 asks a reader to get right). So this holds the answers it got, counts READY from
/// those, and never fills an id it was not given: a worker has no `hub_answers` and no `owner_claimed`, and a
/// machine that runs no agent of its own has no `services`, `runtime_installed` or `runtime_signed_in`.
public struct VerifyChecklist: Equatable, Sendable {
    /// The feature name of 4.7, for the day a hub serves this array itself.
    public static let feature = "verify"
    /// The ids of this version, in the one order they come in (4.1).
    public static let ids = ["services", "hub_answers", "owner_claimed", "tailnet", "firewall", "clock", "disk",
                             "runtime_installed", "runtime_signed_in", "desktop", "selftest", "version", "team"]
    /// At most this many answers are read, which leaves room for an id a later version adds.
    static let limit = 32
    /// The id of the check that a machine fails until its owner signs it in to their provider account. No
    /// installer can pass it: signing in is the owner's own step, with the provider's own page, and it is the next
    /// thing they do after an install.
    public static let signInCheck = "runtime_signed_in"
    /// What both installers print as their last line, whatever the checks came to: `READY`, or `NOT READY: <ids>`.
    public static let readyLine = "READY"

    /// The answers, in the order of `ids`; an id this app does not know comes after them, in the order it arrived.
    public let checks: [VerifyCheck]
    /// When the command ran, where the reader knows it.
    public let readAt: Double?

    public init(checks: [VerifyCheck], readAt: Double? = nil) {
        self.checks = VerifyChecklist.ordered(checks); self.readAt = readAt
    }

    /// **What a closer look found counts only in the launch that ran it** (`lookedNow`): a server's page puts it on
    /// its face then, and Report a problem reads it then. A look this app keeps from an earlier launch is a reading,
    /// behind Details on the page, and in Report a problem its server counts as not read, so a failure of last week
    /// never reads as one of now. The one rule for both.
    public static func found(_ checklist: VerifyChecklist?, lookedNow: Bool) -> VerifyChecklist? {
        lookedNow ? checklist : nil
    }

    /// `READY` when nothing failed. A warn is not a failure, and an empty answer is not a pass: a machine that said
    /// nothing has not been checked.
    public var isReady: Bool { !checks.isEmpty && !checks.contains(where: \.failed) }
    public var failing: [VerifyCheck] { checks.filter(\.failed) }
    /// Nothing failed but the sign-in, which is the owner's own next step and not a broken install.
    public var onlyNeedsSignIn: Bool {
        !failing.isEmpty && failing.allSatisfy { $0.check == VerifyChecklist.signInCheck }
    }
    public var warning: [VerifyCheck] { checks.filter(\.warned) }

    /// **The checks that are about his machine**, and not about our own installation of it. The owner, 20 October
    /// 2026: "what is even a check?! … I dont care about internal commands." The firewall, the clock, the disk,
    /// the private network and his provider are facts about the machine he bought; the hub answering, his own
    /// address being claimed, the self-test, the revision and the team file are facts about our work on it.
    public static let aboutHisMachine = ["services", "tailnet", "firewall", "clock", "disk",
                                         "runtime_installed", "runtime_signed_in"]

    /// What a closer look says to him, in order: everything that is not a pass, because that is the news, then
    /// the passes that are about his own machine. A passing check of our own installation is not a sentence worth
    /// his attention, and `ourOwnPassed` counts those into one line instead.
    public var said: [VerifyCheck] {
        checks.filter { !$0.passed } + checks.filter { $0.passed && VerifyChecklist.aboutHisMachine.contains($0.check) }
    }

    /// How many passing checks of our own installation this look folded into one line.
    public var ourOwnPassed: Int {
        checks.filter { $0.passed && !VerifyChecklist.aboutHisMachine.contains($0.check) }.count
    }

    /// The last line the installers print, and the one line a row of machines carries.
    public var line: String {
        guard !checks.isEmpty else { return "Not checked" }
        return isReady ? "READY" : "NOT READY: " + failing.map(\.check).joined(separator: ", ")
    }

    /// What this machine's page says above the list, in the owner's own words.
    public var summary: String {
        guard !checks.isEmpty else { return "This server has not been checked yet." }
        if onlyNeedsSignIn {
            return "This server is in your fleet. It is not signed in to your provider yet, which is your own "
                + "next step: no installer can do it for you."
        }
        if !failing.isEmpty {
            let names = failing.map(\.title).joined(separator: ", ")
            return failing.count == 1 ? "\(names) failed. Its fix is below." : "\(failing.count) checks failed: \(names)."
        }
        if !warning.isEmpty {
            return "Ready, with \(warning.count) warning\(warning.count == 1 ? "" : "s")."
        }
        return "Ready. Every check of this server passed."
    }

    /// The answers of `verify --json`, as the command wrote them. A body that is not that array, or that carries an
    /// answer outside the frozen shape, is no answer at all.
    public static func decode(_ data: Data, readAt: Double? = nil) throws -> VerifyChecklist {
        guard data.count <= 65_536 else { throw HubError.invalidResponse }
        let answers = try JSONDecoder().decode([VerifyCheck].self, from: data)
        guard answers.count <= limit, Set(answers.map(\.check)).count == answers.count,
              answers.allSatisfy(\.isValid) else { throw HubError.invalidResponse }
        return VerifyChecklist(checks: answers, readAt: readAt)
    }

    /// The same array out of output that carries other lines around it, which is what an install over SSH gives.
    /// `verify --json` prints the array over several lines, so this takes the whole block and not one line: the
    /// candidates are read from the last to the first, and each one must decode to the frozen shape.
    public static func read(output: String, readAt: Double? = nil) -> VerifyChecklist? {
        guard output.count <= 262_144, let end = output.lastIndex(of: "]") else { return nil }
        var starts: [String.Index] = []
        var at = output.startIndex
        while let found = output[at...].firstIndex(of: "[") {
            let rest = output[output.index(after: found)...].drop(while: \.isWhitespace)
            if rest.first == "{" || rest.first == "]" { starts.append(found) }
            at = output.index(after: found)
            if at >= output.endIndex { break }
        }
        for start in starts.reversed() where start < end {
            if let found = try? decode(Data(output[start...end].utf8), readAt: readAt) { return found }
        }
        return nil
    }

    /// The title of one check, as the owner reads it.
    public static func title(_ id: String) -> String {
        switch id {
        case "services": return "Services"
        case "hub_answers": return "The hub answers"
        case "owner_claimed": return "Your own address"
        case "tailnet": return "Private network"
        case "firewall": return "Firewall"
        case "clock": return "Clock"
        case "disk": return "Disk space"
        case "runtime_installed": return "Provider installed"
        case "runtime_signed_in": return "Signed in"
        case "desktop": return "This Mac's desktop"
        case "selftest": return "Self-test"
        case "version": return "Revision"
        case "team": return "The team file"
        default: return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func ordered(_ checks: [VerifyCheck]) -> [VerifyCheck] {
        let place = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return checks.enumerated().sorted {
            (place[$0.element.check] ?? ids.count + $0.offset) < (place[$1.element.check] ?? ids.count + $1.offset)
        }.map(\.element)
    }
}
