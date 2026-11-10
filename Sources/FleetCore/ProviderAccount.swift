import Foundation

/// What the hub's readings say about the email of a route's provider account. It is the runtime's own identity: an
/// owner's account label never stands for it, and an old reading never looks current.
public enum AccountEmail: Equatable, Sendable {
    /// The email of a current reading.
    case current(String)
    /// The last reading had this email, but the reading is old or the hub state is not current.
    case old(String)
    /// The readings give no email: an older helper, an API key, a local model, or no reading yet.
    case unknown

    /// nil on a hub without the `account_email` feature.
    public init?(limits: AccountLimits?, at time: Double, fresh: Bool, features: [String]) {
        guard features.contains(AccountLimits.emailFeature) else { return nil }
        if fresh, let email = limits?.currentEmail(at: time) { self = .current(email) }
        else if let email = limits?.account_email { self = .old(email) }
        else { self = .unknown }
    }

    /// The words of a compact line.
    public var words: String {
        switch self {
        case .current(let email): email
        case .old: "Email reading is old"
        case .unknown: "Email not reported"
        }
    }

    /// The address the last reading named, current or not; nil when no reading named one.
    public var address: String? {
        switch self {
        case .current(let email), .old(let email): email
        case .unknown: nil
        }
    }
}

/// **One agent's provider and account, in the owner's own words.**
///
/// The card on an agent's page answers one question — which account does this agent run on, how much of it is left,
/// and how do I change it — and every line it draws comes from here, so the chat panel, the Agents table and the
/// agent's own page never say one fact two ways. The owner, 20 October 2026, with a picture of the two of them:
/// "regarding the manager, there should be some consistency in the views!"
///
/// **What is not here is the point.** A hub word (`fleet-manager`, "worker user"), a row that reports only that
/// things are as they should be ("Account label: Not labelled" on a fleet that labels no account), and a number he
/// never acts on (the recorded tokens) are not lines of this card: the first two are gone and the third is behind
/// the row, with everything else that is true but not a decision.
public struct ProviderAccountFacts: Equatable, Sendable {
    /// The provider the agent runs on, as the hub names it (`claude`, `codex`, `grok`).
    public let runtime: String
    public let email: AccountEmail?
    /// The plan the provider itself reported ("Claude Max 5x", "plus"), never an owner's label.
    public let plan: String?
    public let localModel: Bool
    /// **The provider reported no window for the week.** It is a silence and not a zero: his Studio's account
    /// reports a day and a Fable window and no week at all, so two rows of 0% read as an empty week — the very
    /// number he would move his manager onto. The account's own line says it, and no row of 0% draws it.
    public let weekMissing: Bool
    /// What the agent's machine last said about that provider's sign-in; nil when it has not said.
    public let signedIn: Bool?
    /// The reading is the last one known, not the current one.
    public let stale: Bool
    public let collectedAt: Double?
    /// The other agents whose allowance is this same account (`account_key`), in the hub's order.
    public let sharedWith: [String]
    /// The tokens the hub has recorded for this agent, across its routes.
    public let tokens: Int64?
    /// The reading's own error, in the hub's words.
    public let error: String?

    public init(runtime: String, email: AccountEmail?, plan: String?, localModel: Bool = false,
                weekMissing: Bool = false, signedIn: Bool? = nil, stale: Bool = false, collectedAt: Double? = nil,
                sharedWith: [String] = [], tokens: Int64? = nil, error: String? = nil) {
        self.runtime = runtime; self.email = email; self.plan = plan; self.localModel = localModel
        self.weekMissing = weekMissing; self.signedIn = signedIn; self.stale = stale; self.collectedAt = collectedAt
        self.sharedWith = sharedWith; self.tokens = tokens; self.error = error
    }

    /// **The account, as its own title.** It is the address the provider reported, because that is how the owner
    /// knows one account from another. An account with no address says so; it is never named by an owner's label.
    public var title: String {
        if localModel { return "Local model" }
        return email?.address ?? "Account not reported"
    }

    /// The one muted line under it: the provider, the plan the provider reported, a week it did not report, and the
    /// two things that are news — that this provider is signed out on that machine, and that the reading is old.
    public var detail: String { line(age: true) }

    /// **The same line without the age of the reading**, where that age belongs behind the row: the second account
    /// of desktop tasks is nothing he can act on here, and "last reading" at the end of four words read as a
    /// fragment rather than as English (the owner, 20 October 2026: "what do they even mean").
    public var detailWithoutAge: String { line(age: false) }

    private func line(age: Bool) -> String {
        if localModel { return "No account of a provider" }
        var parts = [providerName(runtime)]
        // **A plan whose name the provider's own name already carries is said once.** His plan field for one Claude
        // account reads "Claude", and "Claude Code · Claude" is the provider twice; "Claude Max 5x" is a plan and stays.
        if let plan = Self.planName(plan), !providerName(runtime).lowercased().contains(plan.lowercased()) {
            parts.append(plan)
        }
        // **A window the provider does not report is a silence, and this is where it is said.** Never a 0% row.
        if weekMissing { parts.append("week not reported") }
        // **An allowance two agents spend is a different number**, so this one clause is on the face of the row
        // and not behind it: without it the share moves for no reason he can see.
        if !sharedWith.isEmpty {
            parts.append("shared with \(sharedWith.map(\.agentLabel).formatted(.list(type: .and)))")
        }
        if signedIn == false { parts.append("not signed in") }
        let oldReading = if case .old = email { true } else { stale }
        if age && oldReading { parts.append("last reading") }
        return parts.joined(separator: " · ")
    }

    /// **The account as the value of its own row**, beside the AI provider row that names the provider: the address the
    /// provider reported, "Not signed in" while the machine says the provider is signed out there, else that no
    /// address is known.
    public var accountWords: String {
        if localModel { return "Local model" }
        if signedIn == false { return "Not signed in" }
        return email?.address ?? "Not reported"
    }

    /// **The muted line under the account row, only where it has news**: the plan the provider reported, the agents
    /// that spend this same allowance, and that the address is from an old reading. The provider is its own row, and
    /// a week the provider did not report is said on the usage row.
    public var accountDetail: String? {
        guard !localModel, signedIn != false else { return nil }
        var parts: [String] = []
        if let plan = Self.planName(plan), !providerName(runtime).lowercased().contains(plan.lowercased()) {
            parts.append(plan)
        }
        if !sharedWith.isEmpty {
            parts.append("shared with \(sharedWith.map(\.agentLabel).formatted(.list(type: .and)))")
        }
        let oldReading = if case .old = email { true } else { stale }
        if oldReading, email?.address != nil { parts.append("last reading") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// **Behind the row, everything true that is not a decision**: when the reading was taken, which other agents
    /// spend this same allowance, what the hub has recorded, and what went wrong with the reading.
    public func help(date: (Double) -> String) -> String {
        var lines: [String] = []
        if localModel { lines.append("A local model has no provider account and no allowance.") }
        if let collectedAt { lines.append("\(stale ? "Last reading" : "Read"): \(date(collectedAt))") }
        if !sharedWith.isEmpty {
            lines.append("Same account as \(sharedWith.map(\.agentLabel).formatted(.list(type: .and))): one allowance between them.")
        }
        if let tokens { lines.append("\(tokens.formatted()) tokens recorded") }
        if let error, !error.isEmpty { lines.append(error) }
        return lines.joined(separator: "\n")
    }

    /// The plan as the provider wrote it. A provider that writes it in lower case ("plus", "free") gets a capital;
    /// one that wrote its own name ("Claude Max 5x") keeps it, because `capitalized` would make that "5X".
    static func planName(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan == plan.lowercased() ? plan.capitalized : plan
    }
}

extension UsageWindow {
    /// **The window's short name**: its length in few characters ("5 h", "7 d"), with the model the provider scoped it
    /// to ("7 d (Fable)"), as the Agents table and the Dashboard name it — one notation for one fact on every screen
    /// (T-08). "Today" named a window of five hours, beside "5 h" for the same window on the Agents table. One with no
    /// length keeps whatever the provider called it. The provider's own label can carry its name ("codex / 5 hours"),
    /// and the row stands under the account's own provider, so the name is said once.
    public var shortTitle: String {
        guard let minutes = window_minutes, minutes > 0 else { return label }
        let model = label.range(of: #"\([^)]*\)"#, options: .regularExpression).map { String(label[$0]) }
        return [shortLabel, model].compactMap { $0 }.joined(separator: " ")
    }

    /// **A week of the plan itself**: a window of a week or longer that the provider scoped to no model. Claude Code
    /// reports that one as `weekly_all`; an account that reports only a `weekly_scoped` window has not said what the
    /// week of the plan stands at.
    public var isWholeWeek: Bool {
        guard let minutes = window_minutes, minutes >= 10_080 else { return false }
        return label.range(of: #"\([^)]*\)"#, options: .regularExpression) == nil
    }

}

extension AccountLimits {
    /// **The windows of this account that the owner reads**: the one that comes back inside a day and the week of
    /// the plan, which are the two he decides on, in the provider's own order. A window the provider scoped to one
    /// model is there only once something has been spent in it: an untouched `7 days (Fable)` is a row that says
    /// things are fine, and he cuts those.
    ///
    /// It replaces the rule that drew the worst window alone. Two bars say where the account stands; one bar and a
    /// clock time said less and asked more (the owner, 21 October 2026).
    public func ownWindows(at time: Double) -> [UsageWindow] {
        windows.filter { window in
            let scoped = window.label.range(of: #"\([^)]*\)"#, options: .regularExpression) != nil
            return !scoped || window.used_percent.rounded() > 0
        }
    }

    /// **The provider reported no week of the plan.** A reading that gives windows but no whole week has left unsaid
    /// the one number a choice of account is made on. A reading with no window at all says nothing here, because then
    /// the whole reading is the silence and the account's row says that instead.
    public var weekMissing: Bool { !windows.isEmpty && !windows.contains(where: \.isWholeWeek) }
}
