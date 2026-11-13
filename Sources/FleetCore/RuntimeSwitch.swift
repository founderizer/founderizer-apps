import Foundation

public func providerName(_ runtime: String) -> String {
    switch runtime {
    case "claude": "Claude Code"
    case "codex": "Codex"
    case "grok": "Grok Build"
    default: runtime.capitalized
    }
}

/// One reasoning level as the owner reads it, wherever it stands: "xhigh" is "Extra high", and every other level is the
/// provider's own word with a capital ("Low", "Max", "Ultra"). The owner's yes of 10 November 2026 to the Default models
/// card listed "Automatic, Low, Medium, High, Extra high, Max"; the menus said "Xhigh".
public func reasoningName(_ level: String) -> String {
    switch level {
    case "xhigh": "Extra high"
    default: level.prefix(1).uppercased() + level.dropFirst()
    }
}

/// The first choice of a model or reasoning menu while the owner chose none: the provider decides. It said "Provider's
/// own" until the owner, 10 November 2026: "both dropdowns there don't make any sense!! what do they even mean?".
public let automaticChoice = String(l10n: "Automatic")

/// `runtime_switch` of a `GET /ui/team` line: whether the hub can switch this agent to its other provider now. The
/// hub decides, also for an agent that cannot switch at all (`manager_not_supported`, `runtime_not_supported`, with
/// `to` null for a runtime that cannot switch); the app shows its reasons and sends the one command. A reading that
/// cannot be read counts as not ready, so the app never offers a switch from it.
public struct RuntimeSwitch: Decodable, Equatable, Sendable {
    /// What keeps the agent busy: a switch waits until it is idle. Active code checks and credential jobs count as
    /// busy too, without a field of their own.
    public struct Busy: Decodable, Equatable, Sendable {
        public let open_tasks: [String]
        public let chats_waiting: Int
        public let desktop: String?
        enum CodingKeys: String, CodingKey { case open_tasks, chats_waiting, desktop }
        public init(from decoder: Decoder) throws {
            let values = try? decoder.container(keyedBy: CodingKeys.self)
            open_tasks = (try? values?.decodeIfPresent([String].self, forKey: .open_tasks)) ?? []
            chats_waiting = max(0, (try? values?.decodeIfPresent(Int.self, forKey: .chats_waiting)) ?? 0)
            let text: String? = (try? values?.decodeIfPresent(String.self, forKey: .desktop)) ?? nil
            let task: Int? = (try? values?.decodeIfPresent(Int.self, forKey: .desktop)) ?? nil
            desktop = text ?? task.map { "T-\($0)" }
        }
    }
    /// The provider that a switch would give, or nil when the agent's runtime cannot switch.
    public let to: String?
    public let ready: Bool
    public let missing: [String]
    public let busy: Busy?
    /// The only runtimes that Fleet switches between.
    public static let runtimes = ["codex", "claude"]
    /// The reasons that the target runtime's own setup can fix on the agent's machine.
    public static let setupReasons: Set<String> = ["runtime_not_installed", "runtime_not_signed_in", "runtime_sign_in_unknown"]
    /// The target runtime needs its own setup first. The other reasons stay, and the switch stays a separate step.
    public var needsSetup: Bool { to != nil && !ready && missing.contains(where: Self.setupReasons.contains) }
    public static let feature = "runtime_switch"
    enum CodingKeys: String, CodingKey { case to, ready, missing, busy }

    public init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        let target: String? = (try? values?.decodeIfPresent(String.self, forKey: .to)) ?? nil
        let ready: Bool? = (try? values?.decodeIfPresent(Bool.self, forKey: .ready)) ?? nil
        to = target.flatMap { Self.runtimes.contains($0) ? $0 : nil }
        self.ready = to != nil && ready == true
        missing = (try? values?.decodeIfPresent([String].self, forKey: .missing)) ?? []
        busy = (try? values?.decodeIfPresent(Busy.self, forKey: .busy)) ?? nil
    }

    /// The hub's `missing` codes as short facts, in the hub's order. `current`: the agent's runtime now.
    public func reasons(current: String) -> [String] {
        if ready { return [] }
        if missing.isEmpty { return [String(l10n: "Founderizer cannot tell yet.")] }
        return missing.map { Self.reason($0, to: to, current: current, busy: busy) }
    }

    /// **The same reasons for a row that already names the provider**, with the machine named where the reason is
    /// about that machine. "Codex is not installed." says nothing about which of four machines; "Not installed on
    /// hub." is the fact and the place, in four words.
    public func rowReasons(current: String, machine: String, agent: String) -> [String] {
        if ready { return [] }
        if missing.isEmpty { return [String(l10n: "Founderizer cannot tell yet.")] }
        return missing.map { code in
            switch code {
            case "runtime_not_installed": String(l10n: "Not installed on \(machine).")
            case "runtime_not_signed_in": String(l10n: "Not signed in on \(machine).")
            case "runtime_sign_in_unknown": String(l10n: "Sign-in on \(machine) is not known.")
            // **What a switch would cost this agent, not what it would do to a word.** "Switching would change this
            // agent's permissions" states a fact, disables the button and offers nothing; the capability is his.
            case "access_not_equivalent":
                to.map { String(l10n: "\(providerName($0)) cannot do everything \(agent.agentLabel) does.") }
                    ?? String(l10n: "The other provider cannot do everything \(agent.agentLabel) does.")
            default: Self.reason(code, to: to, current: current, busy: busy)
            }
        }
    }

    public static func reason(_ code: String, to: String?, current: String, busy: Busy?) -> String {
        let name = to.map(providerName) ?? String(l10n: "The other provider")
        switch code {
        case "manager_not_supported": return String(l10n: "Switching the manager is not supported yet.")
        case "runtime_not_supported": return String(l10n: "\(providerName(current)) cannot switch.")
        case "helper_without_runtime_switch": return String(l10n: "Update Founderizer on its server first.")
        case "helper_status_unknown": return String(l10n: "No recent status from Founderizer on its server.")
        case "runtime_not_installed": return String(l10n: "\(name) is not installed.")
        case "runtime_not_signed_in": return String(l10n: "\(name) is not signed in.")
        case "runtime_sign_in_unknown": return String(l10n: "\(name) sign-in is unknown.")
        case "access_not_equivalent": return String(l10n: "\(name) cannot do everything this agent does.")
        case "settings_pending": return String(l10n: "Waiting for its current settings.")
        case "chat_not_bound": return String(l10n: "Link its existing chat first.")
        case "wakeup_rules_depend": return String(l10n: "Pause its code wake-up rules or change their runner first.")
        case "capability_not_supported": return String(l10n: "\(name) cannot give all its capabilities.")
        case "agent_busy":
            var parts: [String] = []
            if let busy {
                // The hub names the open tasks and the desktop's task by their numbers (T-90); he reads how many.
                if !busy.open_tasks.isEmpty {
                    parts.append(busy.open_tasks.count == 1 ? String(l10n: "1 task open") : String(l10n: "\(busy.open_tasks.count) tasks open"))
                }
                if busy.chats_waiting > 0 { parts.append(String(l10n: "\(busy.chats_waiting) chat waiting")) }
                if busy.desktop != nil { parts.append(String(l10n: "its desktop in use")) }
            }
            return parts.isEmpty ? String(l10n: "Busy.") : String(l10n: "Busy: \(parts.joined(separator: ", ")).")
        default: return String(l10n: "Cannot switch now.")
        }
    }

    /// Why no readiness can be shown, or nil when the hub's readiness decides: a hub without the feature, or a line
    /// without a reading.
    public static func unavailable(offered: Bool, readiness: RuntimeSwitch?) -> String? {
        if !offered { return String(l10n: "This hub cannot switch providers.") }
        return readiness == nil ? String(l10n: "No switch status yet.") : nil
    }
}

/// An agent's provider as Fleet can confirm it. team.json names the new runtime at once; the helper runs it only
/// after it has loaded it. So only a current reading whose loaded runtime (the machine's `runtime.name`) is the one
/// of team.json, with no settings pending, confirms it; a reading without a runtime name confirms nothing.
public struct ProviderState: Equatable, Sendable {
    public let configured: String
    public let loaded: String?
    public let pending: Bool
    /// A current machine reading exists.
    public let known: Bool

    public init(configured: String, machine: MachineStatus?, at time: Double) {
        let current = machine?.isCurrent(at: time) == true ? machine : nil
        self.configured = configured
        loaded = current?.runtime.name
        pending = current?.settings_pending == true
        known = current != nil
    }

    /// The helper has loaded the provider of team.json, with no settings pending.
    public var isConfirmed: Bool { known && loaded == configured && !pending }
    /// The provider that the helper still runs while team.json names another one.
    public var switchingFrom: String? { loaded.flatMap { $0 == configured ? nil : $0 } }
}
