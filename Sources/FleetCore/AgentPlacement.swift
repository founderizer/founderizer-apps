import Foundation

/// One machine of `GET /ui/team` (owner API 1.12, `agent_auth`): its agents, SSH access, worker user, the runtimes that
/// its helpers know, and whether one more agent can use it. The hub decides readiness; the app only shows it.
public struct TeamMachine: Decodable, Equatable, Sendable {
    public struct SSH: Decodable, Equatable, Sendable { public let user: String; public let port: Int }
    public struct Runtime: Decodable, Equatable, Sendable { public let version: String?; public let signed_in: Bool? }
    public struct Readiness: Decodable, Equatable, Sendable { public let ready: Bool; public let missing: [String] }
    public let address: String?
    public let agents: [String]
    public let ssh: SSH?
    public let worker_user: String?
    public let runtimes: [String: Runtime]
    public let add_agent: Readiness?
}

/// A machine as the Add agent form shows it: the runtimes a new agent can use, or why the machine cannot take one now.
public struct PlacementChoice: Identifiable, Equatable, Sendable {
    /// A runtime that the executor supports. Helpers report only the runtimes they know, so a missing reading is
    /// unknown: it does not show that the runtime is absent or signed out. The executor checks the selected one.
    public struct RuntimeOption: Identifiable, Equatable, Sendable {
        public let runtime: String
        public let signedIn: Bool?
        public var id: String { runtime }
        public var title: String { runtime == "codex" ? "Codex" : "Claude" }
        /// The reading in a few words. Setup never installs a runtime or signs it in.
        public var status: String {
            switch signedIn {
            case true?: return "Signed in."
            case false?: return "Not signed in. Setup checks again."
            case nil: return "Status unknown. Setup checks this server."
            }
        }
    }
    public let machine: String
    public let agents: [String]
    public let runtimes: [RuntimeOption]
    public let reasons: [String]
    public var id: String { machine }
    public var isReady: Bool { reasons.isEmpty }
    /// The first runtime that the machine reports as signed in, if any.
    public var preferredRuntime: String? { runtimes.first { $0.signedIn == true }?.runtime }
}

/// Add agent on an existing machine (owner API 1.12). The new agent gets its own checkout and service, starts inactive
/// with no credential access, and shares the machine's OS user, files and runtime sign-in with the agents there.
public enum AgentPlacement {
    public static let feature = "agent_auth"
    public static let capability = "existing_machine"
    static let namePattern = "^[a-z][a-z0-9-]{1,30}$"
    static let machinePattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

    /// Both the hub and the bundled executor must support it before the app offers it.
    public static func isOffered(features: [String]?, executor: SetupExecutor?) -> Bool {
        features?.contains(feature) == true && executor?.supportsExistingMachine == true
    }

    /// One choice for each machine, sorted by name. Only the hub's `add_agent.ready` makes a machine ready.
    public static func choices(_ machines: [String: TeamMachine]) -> [PlacementChoice] {
        machines.sorted { $0.key < $1.key }.map { name, machine in
            let runtimes = ["codex", "claude"].map { PlacementChoice.RuntimeOption(runtime: $0, signedIn: machine.runtimes[$0]?.signed_in) }
            var reasons: [String] = []
            if machine.add_agent?.ready != true {
                reasons = (machine.add_agent?.missing ?? []).map(reason)
                if reasons.isEmpty { reasons = ["Founderizer has not confirmed that this server can take another agent."] }
            }
            if name.range(of: machinePattern, options: .regularExpression) == nil { reasons = ["Founderizer cannot use this server name."] }
            return PlacementChoice(machine: name, agents: machine.agents.sorted(), runtimes: runtimes, reasons: reasons)
        }
    }

    /// The hub's `missing` codes in ordinary words. They give the fact and ask for no permission or sign-in change.
    public static func reason(_ code: String) -> String {
        let parts = code.split(separator: ":", maxSplits: 1).map(String.init)
        let agent = parts.count == 2 ? parts[1].agentLabel : "An agent"
        switch parts.first ?? "" {
        case "no_ssh": return "Founderizer has no SSH access to this server."
        case "ssh_user_not_allowed": return "Its SSH user is not root or the worker user."
        case "worker_user_unknown": return "Its worker user is not known."
        case "agent_without_key": return "\(agent) has no agent key yet."
        case "helper_without_agent_key": return "Founderizer on \(agent)'s server does not use agent keys yet."
        case "legacy_windows": return "\(agent) has sessions from before the update. Founderizer keeps them working until their next normal start."
        case "legacy_windows_unknown": return "Founderizer could not check the sessions of \(agent). It checks again when \(agent) next reports."
        case "helper_offline": return "\(agent) is not answering."
        case "broker_machine": return "Its vault broker cannot use agent keys yet."
        case "owner_address": return "This is the owner's computer."
        default: return "This server is not ready for another agent."
        }
    }

    /// Why the form cannot start, or nil. A resume needs only the saved name: that agent can be registered already and
    /// its machine not ready while it is half installed. The executor and the hub check everything again.
    public static func problem(name: String, on choice: PlacementChoice?, existing: Set<String>, resume: Bool) -> String? {
        guard name.range(of: namePattern, options: .regularExpression) != nil else {
            return "Use a name of 2 to 31 characters: a-z, 0-9 and -, starting with a letter."
        }
        if resume { return nil }
        guard let choice, choice.isReady else { return "Select a ready server." }
        return existing.contains(name) ? "An agent with this name exists." : nil
    }
}
