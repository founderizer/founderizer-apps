import Foundation

public struct TaskHold: Decodable, Identifiable, Sendable {
    public let id: Int
    public let task: Int
    public let kind: String
    public let state: String
    public let attempt: Int
    public let detail: String?
    public let released: Double?
    public let resume_mode: String?
    /// Who holds the task: `owner`, `hub`, or an agent. nil from a hub that does not say.
    public let by: String?
    /// A Stop in an agent's name: only the restart that the task's requester asked for (`restart_task`) makes one. After
    /// the helper's proof the hub starts the task again by itself. The owner's Stop takes the hold over: then nothing
    /// starts by itself and only the owner resumes the task.
    public var isAgentStop: Bool { kind == "stop" && state != "released" && by.map { !["owner", "hub"].contains($0) } == true }
}

extension HubState {
    /// The attempt of a task that a confirmed hold ended, while that hold holds the task: the helper proved that no
    /// process of the attempt remains. A hold that is only requested, or that was not confirmed, proves nothing.
    public func stoppedAttempt(of task: Int) -> Int? { holds?.first { $0.task == task && $0.state == "stopped" }?.attempt }
}

public struct TaskOutcome: Decodable, Identifiable, Sendable {
    public let id: Int
    public let task: Int
    public let attempt: Int
    public let title: String
    public let kind: String
    public let state: String
    public let note: String?
}

public struct RuntimeLimit: Decodable, Sendable {
    public let since: Double
    public let until: Double
    public let reset_known: Bool
    public let task: Int?
}

public enum ControlAction: String, Codable, Sendable { case pause, stop, resume, resume_check }
public enum OutcomeFinding: String, Codable, Sendable { case done, not_done }
public enum OwnerCommand: Codable, Equatable, Sendable {
    case steer(task: Int, attempt: Int)
    case goalState(id: Int, revision: Int, action: GoalAction)
    case triggerState(id: Int, revision: Int, action: TriggerAction)
    case profile(agent: String, sha256: String)
    case teamLines(sha256: String)
    case agentSettings(agent: String, sha256: String)
    case agentActivation(agent: String, sha256: String, active: Bool)
    /// Give or remove one agent's use of its machine's vault store. It sends only `vault`, never saved settings again.
    case agentVault(agent: String, sha256: String, access: VaultAccess)
    /// Let one agent make new logins with `create_login`, or stop that (`login_create`). It sends only `vault_create`.
    case agentVaultCreate(agent: String, sha256: String, on: Bool)
    /// Switch one agent to another provider (`runtime_switch`). It sends only `runtime`; the hub resets the model, the
    /// effort and the account label to the new provider's defaults.
    case agentRuntime(agent: String, sha256: String, runtime: String)
    case teamAccount(id: String, sha256: String, delete: Bool)
    case agentIdentity(agent: String, sha256: String)
    /// Save or remove one of the owner's own devices (MOBILE-APP.md 7). A removal also makes that device's key, its
    /// codes and its tries invalid at once.
    case ownerDevice(device: String, sha256: String, delete: Bool)
    /// One enrollment code for one device. The hub keeps only its SHA-256, so a repeat of this command answers with
    /// `code: null`: the page then offers a new code.
    case ownerDeviceCode(device: String)
    /// One enrollment code for a phone that `team.json` does not hold yet (`device_by_code`; the owner, 3 November
    /// 2026: Add device shows the QR at once, with no fields). The phone that brings it is added with the address it
    /// calls from. A repeat answers with `code: null`, as for a device's own code.
    case newDeviceCode
    case machineUpdate(agent: String)
    case machineCheck(agent: String)
    /// Start that agent's standing manager session again (`manager_start`). The helper's own loop starts a session
    /// that went by itself, so this is the owner's hand on the same switch: for a start that keeps failing, and for
    /// the ten seconds he does not want to wait. It only asks; a session that runs is left alone.
    case managerStart(agent: String)
    /// Start this machine's own runtime sign-in (`machine_signin`). The provider's flow runs on that machine; the hub
    /// passes the link along and the credential is written where it belongs. Grok has no sign-in path.
    /// `replace`: the owner wants a DIFFERENT account of this provider, so the hub signs the runtime out first and
    /// in again, as one job. Without it the hub refuses a sign-in while one is live, which is every machine that
    /// works.
    case machineSignin(agent: String, runtime: String, replace: Bool)
    /// The code the provider gave the owner, on its way to that machine. The hub holds it for one reader and writes
    /// it nowhere, so this command's own label and record must not carry it either.
    case machineSigninCode(agent: String, code: String)
    case control(task: Int, action: ControlAction)
    case outcome(id: Int, finding: OutcomeFinding)
    /// Owner feature `need_talk` (API 1.106): his message in the discussion of one open Needs-you item. Nothing makes
    /// one since Discuss left the app (API 1.158): only a request that an app before 0.1.205 saved in its outbox holds
    /// one, so the outbox still reads it, and the hub's 404 gives the request line its Discard.
    case needTalk(need: Int)
    public var requiredFeature: String {
        switch self {
        case .needTalk: return NeedTalk.feature
        case .steer: return "task_steering"
        case .goalState: return "goals"
        case .triggerState(_, _, .check_now): return "trigger_checks"
        case .triggerState: return "triggers"
        case .profile: return "profiles"
        case .teamLines: return "reporting_lines"
        // **An agent's role is a setting of its own** (team.json `title`, the owner's yes of 3 November 2026 to a Role
        // field under Rename…): it goes to the route of its settings, which takes it on every hub that has agent setup.
        // It stood under "projects", which no hub has offered since that concept went (18 October 2026).
        case .agentSettings, .agentActivation, .agentIdentity: return "agent_setup"
        case .agentVault: return VaultAccess.feature
        case .agentVaultCreate: return LoginCreateControl.feature
        case .agentRuntime: return RuntimeSwitch.feature
        case .teamAccount: return "projects"
        case .newDeviceCode: return OwnerDevices.codeAlone
        case .ownerDevice, .ownerDeviceCode: return OwnerDevices.feature
        case .machineCheck: return "machine_check"
        case .managerStart: return ManagerSession.feature
        case .machineSignin, .machineSigninCode: return MachineLogin.feature
        default: break
        }
        if case .machineUpdate = self { return "machines" }
        return "task_controls"
    }
    public var route: String {
        switch self {
        case .needTalk(let need): "ui/needs/\(need)/talk"
        case .steer(let task, _): "ui/tasks/\(task)/steer"
        case .goalState(let id, _, _): "ui/goals/\(id)/state"
        case .triggerState(let id, _, _): "ui/triggers/\(id)/state"
        case .profile(let agent, _): "ui/profiles/\(agent)"
        case .teamLines: "ui/team/lines"
        case .agentSettings(let agent, _), .agentActivation(let agent, _, _), .agentVault(let agent, _, _), .agentVaultCreate(let agent, _, _),
             .agentRuntime(let agent, _, _), .agentIdentity(let agent, _): "ui/team/agents/\(agent)"
        case .teamAccount: "ui/team/accounts"
        case .ownerDevice: "ui/owner/devices"
        case .ownerDeviceCode(let device): "ui/owner/devices/\(device)/code"
        case .newDeviceCode: "ui/owner/devices/code"
        case .machineUpdate(let agent): "ui/machines/\(agent)/update"
        case .machineCheck(let agent): "ui/machines/\(agent)/check"
        case .managerStart(let agent): "ui/machines/\(agent)/manager"
        case .machineSignin(let agent, _, _): "ui/machines/\(agent)/signin"
        case .machineSigninCode(let agent, _): "ui/machines/\(agent)/signin/code"
        case .control(let task, _): "ui/tasks/\(task)/control"
        case .outcome(let id, _): "ui/outcomes/\(id)"
        }
    }
    public var fields: [String: String] {
        switch self {
        case .steer, .goalState, .triggerState, .profile, .teamLines, .agentSettings,
             .agentActivation, .agentVault, .agentVaultCreate, .agentRuntime, .teamAccount, .agentIdentity,
             .ownerDevice, .ownerDeviceCode, .newDeviceCode, .needTalk: [:]
        case .machineUpdate(let agent), .machineCheck(let agent), .managerStart(let agent): ["agent": agent]
        // `fields` is this command in text, for the window's own request line; the body it sends is `bodyFields`.
        case .machineSignin(_, let runtime, let replace):
            replace ? ["runtime": runtime, "replace": "true"] : ["runtime": runtime]
        case .machineSigninCode(_, let code): ["code": code]
        case .control(_, let action): ["action": action.rawValue]
        case .outcome(_, let finding): ["finding": finding.rawValue]
        }
    }
    public var label: String {
        switch self {
        case .steer: String(l10n: "Guide the task")
        case .goalState(_, _, let action):
            switch action {
            case .pause: String(l10n: "Pause the goal")
            case .resume: String(l10n: "Resume the goal")
            case .done: String(l10n: "Done the goal")
            case .drop: String(l10n: "Drop the goal")
            case .reopen: String(l10n: "Reopen the goal")
            }
        // **No hub number** (the polish of 30 October 2026): "Run schedule 3" stood in the request line.
        case .triggerState(_, _, let action):
            switch action {
            case .run_now: String(l10n: "Run schedule")
            case .check_now: String(l10n: "Check schedule")
            case .pause: String(l10n: "Pause schedule")
            case .resume: String(l10n: "Resume schedule")
            case .delete: String(l10n: "Delete schedule")
            }
        case .profile(let agent, _): String(l10n: "Edit \(agent.agentLabel) profile")
        case .teamLines: String(l10n: "Edit reporting lines")
        case .agentSettings(let agent, _): String(l10n: "Configure \(agent.agentLabel)")
        case .agentActivation(let agent, _, let active):
            active ? String(l10n: "Activate \(agent.agentLabel)") : String(l10n: "Deactivate \(agent.agentLabel)")
        case .agentVault(let agent, _, let access): access == .broker ? String(l10n: "Give \(agent.agentLabel) vault access") :
            String(l10n: "Remove vault access of \(agent.agentLabel)")
        case .agentVaultCreate(let agent, _, let on):
            on ? String(l10n: "Let \(agent.agentLabel) save new logins") : String(l10n: "Stop new logins of \(agent.agentLabel)")
        case .agentRuntime(let agent, _, let runtime): String(l10n: "Switch \(agent.agentLabel) to \(providerName(runtime))")
        case .teamAccount(let id, _, let delete): delete ? String(l10n: "Delete account \(id)") : String(l10n: "Save account \(id)")
        case .agentIdentity(let agent, _): String(l10n: "Edit \(agent.agentLabel) identity")
        case .ownerDevice(let device, _, let delete):
            delete ? String(l10n: "Remove the device \(device)") : String(l10n: "Save the device \(device)")
        case .ownerDeviceCode(let device): String(l10n: "New code for \(device)")
        case .newDeviceCode: String(l10n: "New code for a new device")
        case .machineUpdate(let agent): String(l10n: "Update \(agent.agentLabel)")
        case .machineCheck(let agent): String(l10n: "Check \(agent.agentLabel)")
        case .managerStart(let agent): String(l10n: "Start the session of \(agent.agentLabel)")
        case .machineSignin(let agent, let runtime, let replace):
            replace ? String(l10n: "Use another \(providerName(runtime)) account for \(agent.agentLabel)")
                    : String(l10n: "Sign \(agent.agentLabel) in to \(providerName(runtime))")
        case .machineSigninCode(let agent, _): String(l10n: "Send the sign-in code to \(agent.agentLabel)")
        case .control(_, let action):
            switch action {
            case .pause: String(l10n: "Pause the task")
            case .stop: String(l10n: "Stop the task")
            case .resume: String(l10n: "Resume the task")
            case .resume_check: String(l10n: "Resume Check the task")
            }
        case .outcome: String(l10n: "Set the outcome")
        case .needTalk: String(l10n: "Ask about a request")
        }
    }

    /// **Its words with the item's own title, not the hub's number** (fix round 3c, COPY; as D-2 did for "N-3"): the
    /// window's request line said "Pause G-3" and "Set outcome O-5". `label` stays for a reading that does not hold the
    /// item. A schedule's title is in the schedules' own reading (`schedules`), the one Behaviour draws (the polish of 30
    /// October 2026: "Run schedule 3").
    public func label(in state: HubState?, schedules: [FleetTrigger] = []) -> String {
        func task(_ id: Int) -> String? { state?.tasks.first { $0.id == id }.map { String(l10n: "“\($0.title)”") } }
        switch self {
        case .goalState(let id, _, let action):
            if let goal = state?.goals?.first(where: { $0.id == id }) {
                return switch action {
                case .pause: String(l10n: "Pause “\(goal.title)”")
                case .resume: String(l10n: "Resume “\(goal.title)”")
                case .done: String(l10n: "Done “\(goal.title)”")
                case .drop: String(l10n: "Drop “\(goal.title)”")
                case .reopen: String(l10n: "Reopen “\(goal.title)”")
                }
            }
        case .outcome(let id, _):
            if let outcome = state?.outcomes?.first(where: { $0.id == id }) {
                let title = task(outcome.task) ?? String(l10n: "“\(outcome.title)”")
                return String(l10n: "Set the outcome of \(title)")
            }
        case .steer(let id, _):
            if let title = task(id) { return String(l10n: "Guide \(title)") }
        case .control(let id, let action):
            if let title = task(id) {
                return switch action {
                case .pause: String(l10n: "Pause \(title)")
                case .stop: String(l10n: "Stop \(title)")
                case .resume: String(l10n: "Resume \(title)")
                case .resume_check: String(l10n: "Resume Check \(title)")
                }
            }
        case .triggerState(let id, _, let action):
            if let schedule = schedules.first(where: { $0.id == id }) {
                return switch action {
                case .run_now: String(l10n: "Run “\(schedule.task.title)”")
                case .check_now: String(l10n: "Check “\(schedule.task.title)”")
                case .pause: String(l10n: "Pause “\(schedule.task.title)”")
                case .resume: String(l10n: "Resume “\(schedule.task.title)”")
                case .delete: String(l10n: "Delete “\(schedule.task.title)”")
                }
            }
        case .needTalk(let need):
            if let item = state?.needs.first(where: { $0.id == need }) { return String(l10n: "Ask about “\(item.title)”") }
        default: break
        }
        return label
    }

    public func bodyFields(text: String) throws -> [String: Any] {
        switch self {
        case .needTalk(let need):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard need > 0, !words.isEmpty, words.count <= NeedTalk.most else { throw HubError.invalidResponse }
            return ["text": words]
        case .steer(let task, let attempt):
            let normalized = normalizedOwnerText(text)
            guard task > 0, attempt > 0, !normalized.isEmpty, normalized.count <= 4000 else { throw HubError.invalidResponse }
            return ["text": normalized, "expected_attempt": attempt]
        case .goalState(let id, let revision, let action):
            guard id > 0, revision > 0, text.count <= 2000 else { throw HubError.invalidResponse }
            return ["base_revision": revision, "action": action.rawValue, "note": text]
        case .triggerState(let id, let revision, let action):
            guard id > 0, revision > 0, text.isEmpty else { throw HubError.invalidResponse }
            return ["base_revision": revision, "action": action.rawValue]
        case .teamLines(let hash):
            guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
            let input = try JSONDecoder().decode(TeamLinesInput.self, from: Data(text.utf8))
            guard input.isValid else { throw HubError.invalidResponse }
            var result = try payloadFields(input); result["base_sha256"] = hash
            return result
        case .agentSettings(let agent, let hash), .agentActivation(let agent, let hash, _):
            guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
            if case .agentActivation(_, _, let active) = self {
                guard text.isEmpty else { throw HubError.invalidResponse }
                return ["base_sha256": hash, "active": active]
            }
            let input = try JSONDecoder().decode(AgentSettingsInput.self, from: Data(text.utf8))
            guard input.isValid else { throw HubError.invalidResponse }
            var result = try payloadFields(input.normalized); result["base_sha256"] = hash
            return result
        case .teamAccount(let id, let hash, let delete):
            guard id.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil,
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
            if delete {
                guard text.isEmpty else { throw HubError.invalidResponse }
                return ["base_sha256": hash, "account": id, "delete": true]
            }
            let input = try JSONDecoder().decode(AccountInput.self, from: Data(text.utf8)).normalized
            guard input.account == id, input.isValid else { throw HubError.invalidResponse }
            return ["base_sha256": hash, "account": id, "provider": input.entry.provider, "title": input.entry.title]
        case .agentVault(let agent, let hash, let access):
            guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, text.isEmpty else { throw HubError.invalidResponse }
            return ["base_sha256": hash, "vault": access.rawValue]
        case .agentVaultCreate(let agent, let hash, let on):
            guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, text.isEmpty else { throw HubError.invalidResponse }
            return ["base_sha256": hash, "vault_create": on]
        case .agentRuntime(let agent, let hash, let runtime):
            guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  RuntimeSwitch.runtimes.contains(runtime), text.isEmpty else { throw HubError.invalidResponse }
            return ["base_sha256": hash, "runtime": runtime]
        case .agentIdentity(let agent, let hash):
            guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
            let input = try JSONDecoder().decode(AgentIdentityInput.self, from: Data(text.utf8)).normalized
            var result = try payloadFields(input); result["base_sha256"] = hash
            return result
        case .ownerDevice(let device, let hash, let delete):
            guard OwnerDevices.isName(device),
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
            if delete {
                guard text.isEmpty else { throw HubError.invalidResponse }
                return ["base_sha256": hash, "device": device, "delete": true]
            }
            let input = try JSONDecoder().decode(OwnerDeviceInput.self, from: Data(text.utf8)).normalized
            guard input.device == device, OwnerDevices.label(input.label) != nil,
                  OwnerDevices.isAddress(input.address) else { throw HubError.invalidResponse }
            return ["base_sha256": hash, "device": device, "label": input.label, "address": input.address]
        case .ownerDeviceCode(let device):
            // The route carries the device, and the hub takes no other field: only `request_id` and `db`, which
            // `PendingRequest.body()` adds.
            guard OwnerDevices.isName(device), text.isEmpty else { throw HubError.invalidResponse }
            return [:]
        case .newDeviceCode:
            guard text.isEmpty else { throw HubError.invalidResponse }
            return [:]
        case .machineSignin(_, let runtime, let replace):
            // Grok has no sign-in path, here or in the hub: xAI's terms do not let a third party run it this way.
            guard MachineLogin.canSignIn(runtime), text.isEmpty else { throw HubError.invalidResponse }
            // `replace` is part of the body, so a repeat of one request_id is the same request and a change of
            // mind is a new one.
            return ["runtime": runtime, "replace": replace]
        case .machineSigninCode(_, let code):
            // The one code the provider gave the owner. It goes in this body and nowhere else: not in the label, not
            // in a note and not in anything this app keeps.
            guard let code = MachineLogin.code(code), text.isEmpty else { throw HubError.invalidResponse }
            return ["code": code]
        case .profile(let agent, let hash):
            guard agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
            let input = try JSONDecoder().decode(ProfileInput.self, from: Data(text.utf8))
            guard input.isValid else { throw HubError.invalidResponse }
            var result = try payloadFields(input); result["base_sha256"] = hash
            return result
        default: return fields.merging(["note": text]) { _, new in new }
        }
    }

    /// The version a write goes against: the `team.json` file it read, or the goal's or schedule's own revision.
    /// The hub refuses a write against one that is no longer current with 409.
    public enum Base: Equatable, Sendable { case file(sha256: String), revision(Int) }

    public var base: Base? {
        switch self {
        case .goalState(_, let revision, _), .triggerState(_, let revision, _): .revision(revision)
        case .profile(_, let sha256), .teamLines(let sha256), .agentSettings(_, let sha256),
             .agentActivation(_, let sha256, _), .agentVault(_, let sha256, _), .agentVaultCreate(_, let sha256, _),
             .agentRuntime(_, let sha256, _), .teamAccount(_, let sha256, _), .agentIdentity(_, let sha256),
             .ownerDevice(_, let sha256, _): .file(sha256: sha256)
        default: nil
        }
    }

    /// Whether this command still means what the owner meant when it is sent against another base.
    ///
    /// A state action and a write of one field do: the base is only the hub's guard against two writers at once,
    /// and nothing in the body depends on the rest of the file. A whole-form save does **not** — the owner wrote
    /// those fields against the version he read, so sending them against a newer one would quietly drop whatever
    /// changed meanwhile. Those stay a conflict he is shown, which is what his own editors already draw.
    public var rebasesSafely: Bool {
        switch self {
        case .goalState, .triggerState, .agentActivation, .agentVault, .agentVaultCreate, .agentRuntime: true
        case .teamAccount(_, _, let delete), .ownerDevice(_, _, let delete): delete
        default: false
        }
    }

    /// The same command against `base`, or nil when it carries no base, `base` is of the other kind, or a rebase
    /// would not keep its meaning.
    public func rebased(to base: Base) -> OwnerCommand? {
        guard rebasesSafely else { return nil }
        switch (self, base) {
        case (.goalState(let id, _, let action), .revision(let revision)):
            return .goalState(id: id, revision: revision, action: action)
        case (.triggerState(let id, _, let action), .revision(let revision)):
            return .triggerState(id: id, revision: revision, action: action)
        case (.agentActivation(let agent, _, let active), .file(let sha256)):
            return .agentActivation(agent: agent, sha256: sha256, active: active)
        case (.agentVault(let agent, _, let access), .file(let sha256)):
            return .agentVault(agent: agent, sha256: sha256, access: access)
        case (.agentVaultCreate(let agent, _, let on), .file(let sha256)):
            return .agentVaultCreate(agent: agent, sha256: sha256, on: on)
        case (.agentRuntime(let agent, _, let runtime), .file(let sha256)):
            return .agentRuntime(agent: agent, sha256: sha256, runtime: runtime)
        case (.teamAccount(let id, _, let delete), .file(let sha256)):
            return .teamAccount(id: id, sha256: sha256, delete: delete)
        case (.ownerDevice(let device, _, let delete), .file(let sha256)):
            return .ownerDevice(device: device, sha256: sha256, delete: delete)
        default: return nil
        }
    }
}

public struct ControlReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let replayed: Bool
    public let changed: ReceiptChanges?
    public let agent: String?
    public let state: String?
    public let desired_revision: String?
    public let check: MachineCheck?
    public let goal: FleetGoal?
    public let trigger: FleetTrigger?
    public let run: TriggerRun?
    public let sha256: String?
    public let commit: String?
    public let revision: String?
    public let unchanged: Bool?
    public let steer: TaskSteer?
    public let hold: TaskHold?
    public let outcome: TaskOutcome?
    public let updates_requested: [String]?
    public let settings_pending: Bool?
    public let activation: Activation?
    public let project: String?
    public let account: String?
    /// An owner device command (MOBILE-APP.md 7): the device and its label. `code` is the enrollment code, which this
    /// answer alone carries: the hub keeps only its SHA-256, so a repeat of the same request gives nil and the page
    /// offers a new code. The code goes in no note, no file and no log; it lives in this answer and in the page.
    public let device: String?
    public let label: String?
    public let code: String?
    public let expires: Double?
    public let deleted: Bool?
    /// A vault command (`vault_access`): the agent's open tasks at that moment. They continue without login access.
    public let open_tasks: [Int]?
    /// `machine_signin`: the sign-in this command started or carried the code for. It never holds the link or the
    /// code, because a command's answer is kept in the hub's own record of it.
    public let login: MachineLogin?
    /// `need_talk`: the item that his message is about, and its discussion with that message in it.
    public let need: Int?
    public let talk: [NeedMessage]?
    public struct Activation: Decodable, Sendable { public let check: Int; public let checked_at: Double }
    public func matches(_ pending: PendingRequest) -> Bool {
        guard ok, request_id.lowercased() == pending.requestID.uuidString.lowercased(), client == pending.client,
              let command = pending.command else { return false }
        switch command {
        case .needTalk(let id):
            return need == id && talk?.contains { $0.fromOwner } == true
        case .steer:
            return steer?.matches(pending) == true
        case .goalState(let id, let revision, let action):
            return goal?.id == id && goal?.revision == revision + 1 && goal?.state == action.resultingState && goal?.isValid == true
        case .triggerState(let id, let revision, let action):
            guard let trigger, trigger.isValid, trigger.id == id else { return false }
            if action == .run_now || action == .check_now {
                return trigger.revision == revision && run?.isValid == true && run?.manual == true &&
                    run?.revision == revision && trigger.last_run == run && (run?.check_now == true) == (action == .check_now)
            }
            let expected = action == .pause ? "paused" : action == .resume ? "active" : "deleted"
            return trigger.revision == revision + 1 && trigger.state == expected && run == nil
        case .profile(let agent, _):
            return self.agent == agent && sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
                revision?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil && unchanged != nil &&
                (unchanged == true || commit?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil)
        case .teamLines:
            guard sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  revision?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                  case .lines(let changes)? = changed,
                  let input = try? JSONDecoder().decode(TeamLinesInput.self, from: Data(pending.text.utf8)), input.isValid,
                  Set(changes.map(\.agent)).count == changes.count else { return false }
            return changes.allSatisfy { change in
                input.lines.contains { $0.agent == change.agent && $0.role == change.after.role && $0.reports_to == change.after.reports_to }
            }
        case .agentSettings(let agent, _), .agentActivation(let agent, _, _):
            guard self.agent == agent, sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  revision?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                  let changes = changed?.settingChanges,
                  Set(changes.map(\.field)).count == changes.count,
                  let updates_requested, Set(updates_requested).isSubset(of: [agent]), settings_pending != nil else { return false }
            if case .agentActivation(_, _, let active) = command {
                guard changes.allSatisfy({ $0.field == "active" && $0.after == .flag(active) }) else { return false }
                if active && !changes.isEmpty {
                    return activation.map { $0.check > 0 && $0.checked_at.isFinite && $0.checked_at > 0 } == true
                }
                return activation == nil
            }
            guard let input = try? JSONDecoder().decode(AgentSettingsInput.self, from: Data(pending.text.utf8)), input.isValid,
                  activation == nil else { return false }
            var expected: [String: AgentSettingValue] = ["model": input.model.map(AgentSettingValue.text) ?? .none,
                "effort": input.effort.map(AgentSettingValue.text) ?? .none, "can": .list(input.normalized.can)]
            if let screen = input.screen { expected["screen"] = .screen(screen) }
            return changes.allSatisfy { expected[$0.field] == $0.after }
        case .agentVault(let agent, _, let access):
            guard self.agent == agent, sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  revision?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil, activation == nil,
                  let changes = changed?.settingChanges, Set(changes.map(\.field)).count == changes.count,
                  let updates_requested, Set(updates_requested).isSubset(of: [agent]), settings_pending != nil else { return false }
            // The vault access only (`changed` is empty when it was already so); `open_tasks` is not part of the match.
            return changes.allSatisfy { $0.field == "vault" && $0.after == .text(access.rawValue) }
        case .agentVaultCreate(let agent, _, let on):
            guard self.agent == agent, sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, activation == nil,
                  let changes = changed?.settingChanges, Set(changes.map(\.field)).count == changes.count else { return false }
            // The permission only (`changed` is empty when it was already so).
            return changes.allSatisfy { $0.field == "vault_create" && $0.after == .flag(on) }
        case .agentRuntime(let agent, _, let runtime):
            guard self.agent == agent, sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  revision?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil, activation == nil,
                  let changes = changed?.settingChanges, Set(changes.map(\.field)).count == changes.count,
                  let updates_requested, Set(updates_requested).isSubset(of: [agent]), settings_pending != nil else { return false }
            // The same runtime again changes nothing. A switch changes `runtime` to the one asked for, and clears only
            // the model, the effort and the account label.
            if changes.isEmpty { return updates_requested.isEmpty }
            return changes.contains { $0.field == "runtime" && $0.after == .text(runtime) } && changes.allSatisfy {
                ($0.field == "runtime" && $0.after == .text(runtime)) || (["model", "effort", "account"].contains($0.field) && $0.after == .none)
            }
        case .teamAccount(let id, _, let delete):
            return account == id && deleted == delete && changed?.flag != nil &&
                sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
                revision?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil
        case .agentIdentity(let agent, _):
            guard self.agent == agent, sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  revision?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil, activation == nil,
                  let changes = changed?.settingChanges, Set(changes.map(\.field)).count == changes.count,
                  let input = try? JSONDecoder().decode(AgentIdentityInput.self, from: Data(pending.text.utf8)).normalized else { return false }
            let expected: [String: AgentSettingValue] = ["title": input.title.map(AgentSettingValue.text) ?? .none,
                "expertise": .list(input.expertise), "account": input.account.map(AgentSettingValue.text) ?? .none]
            return changes.allSatisfy { expected[$0.field] == $0.after }
        case .ownerDevice(let name, _, let delete):
            return device == name && deleted == delete && changed?.flag != nil &&
                sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
                revision?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil
        case .ownerDeviceCode(let name):
            // A code, or a repeat of this request, which the hub answers with `code: null` because it keeps none.
            // Both are the hub's answer to this command; the page tells them apart by the code.
            guard device == name, label != nil, expires?.isFinite == true, expires ?? 0 > 0 else { return false }
            return code.map(OwnerDevices.isCode) ?? replayed
        case .newDeviceCode:
            // The same answer for a device that does not exist yet: no device and no label.
            guard device == nil, expires?.isFinite == true, expires ?? 0 > 0 else { return false }
            return code.map(OwnerDevices.isCode) ?? replayed
        case .machineUpdate(let agent):
            return self.agent == agent && ["current", "requested"].contains(state ?? "") &&
                desired_revision?.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil
        case .machineCheck(let agent):
            return self.agent == agent && check?.isValid == true && check?.isPending == true
        case .managerStart(let agent):
            // The hub asked that machine's helper; it does not wait for the session itself, because the helper
            // reports its windows in its own status (`manager_warning` ends the episode when the session runs).
            return self.agent == agent && state == "requested"
        case .machineSignin(let agent, let runtime, _):
            return self.agent == agent && login?.runtime == runtime && login?.isOpen == true
        case .machineSigninCode(let agent, _):
            // The answer says the code reached the machine. It carries no code back, and this app sends none again.
            return self.agent == agent && login?.state == "signing_in"
        case .control(let task, let action):
            guard let hold, hold.task == task, hold.id > 0 else { return false }
            if action == .resume || action == .resume_check { return hold.state == "released" }
            // A Stop hold is also the answer to a Pause: the task is held at least as firmly. The hub gives it, as a
            // change, for a Pause on a stop that was not confirmed and on the stop of a restart.
            return (hold.kind == action.rawValue || hold.kind == "stop" || changed?.flag == false) &&
                ["requested", "stopped", "not_confirmed"].contains(hold.state)
        case .outcome(let id, let finding):
            return outcome?.id == id && outcome?.state == finding.rawValue
        }
    }
}

public struct RuntimeEvent: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let attempt: Int
    public let session: String
    public let seq: Int
    public let ts: Double?
    public let type: String
    public let runtime: String?
    public let requested_model: String?
    public let requested_effort: String?
    public let model: String?
    public let effort: String?
    public let text: String?
    public let tool_call_id: String?
    public let title: String?
    public let kind: String?
    public let status: String?
    public let output: String?
    public let message: String?
    public let entries: [PlanEntry]?
    public let parent: String?
    public let locations: [Location]?
    public let changes: [FileChange]?
    public let subagent: Subagent?
    public struct Location: Decodable, Equatable, Sendable { public let path: String }
    public struct Subagent: Decodable, Equatable, Sendable { public let name: String }
    public struct PlanEntry: Decodable, Equatable, Sendable { public let content: String; public let status: String }
    public var toolKey: RuntimeToolKey? { tool_call_id.map { RuntimeToolKey(attempt: attempt, session: session, parent: parent, call: $0) } }
    public var validDetails: Bool {
        runtime.map { $0.count <= 100 } != false &&
        [requested_model, requested_effort, model, effort].allSatisfy { $0.map { $0.count <= 160 } != false } &&
        locations.map { $0.count <= 20 && $0.allSatisfy { !$0.path.isEmpty && $0.path.count <= 300 } } != false &&
        changes.map { $0.count <= 50 && $0.allSatisfy(\.isValid) } != false &&
        subagent.map { !$0.name.isEmpty && $0.name.count <= 100 } != false
    }
}
public struct RuntimePage: Decodable, Sendable {
    public let db: String
    public let task: Int
    public let events: [RuntimeEvent]
    public let next: Int
    public let more: Bool
    /// The most events the hub puts in one page.
    public static let most = 500

    public func validate(database: String, task: Int, after: Int) throws {
        guard db == database, self.task == task, events.count <= Self.most, next >= after,
              events.map(\.id) == events.map(\.id).sorted(), Set(events.map(\.id)).count == events.count,
              events.allSatisfy({ $0.id > after && $0.attempt > 0 && $0.seq > 0 && $0.validDetails }),
              next == (events.last?.id ?? after), !more || !events.isEmpty else { throw HubError.invalidResponse }
    }
}

public struct TaskSteer: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let task: Int
    public let attempt: Int
    public let text: String
    public let created: Double
    public let read_at: Double?
    public let request_id: String
    public let client: String
    public var isValid: Bool { id > 0 && task > 0 && attempt > 0 && !text.isEmpty && text.count <= 4000 && created.isFinite }
    public func deliveryLabel(currentAttempt: Int) -> String {
        read_at != nil ? "Read" : currentAttempt > attempt ? String(l10n: "Not delivered · task restarted") : String(l10n: "Received")
    }
    public func matches(_ pending: PendingRequest) -> Bool {
        guard case .steer(let task, let attempt) = pending.command else { return false }
        return isValid && self.task == task && self.attempt == attempt && client == pending.client &&
            request_id.lowercased() == pending.requestID.uuidString.lowercased() && text == normalizedOwnerText(pending.text)
    }
}

public struct FileChange: Decodable, Equatable, Identifiable, Sendable {
    public let path: String
    public let action: String
    public let added: Int?
    public let removed: Int?
    public var id: String { path }
    public var isValid: Bool {
        !path.isEmpty && path.count <= 300 && ["add", "modify", "delete", "move"].contains(action) &&
            (added == nil || added! >= 0) && (removed == nil || removed! >= 0)
    }
}

public struct RuntimeToolKey: Hashable, Identifiable, Sendable {
    public let attempt: Int
    public let session: String
    public let parent: String?
    public let call: String
    public var id: Self { self }
}

public struct ActivityRow: Identifiable, Sendable {
    public let event: RuntimeEvent
    public var status: String?
    public var output: String?
    public var locations: [RuntimeEvent.Location]
    public var changes: [FileChange]
    public var subagent: RuntimeEvent.Subagent?
    var updatedAt: Double?
    /// The ID of the last event that changed this row: its own event, or its latest update.
    public internal(set) var lastEventID: Int
    public var id: Int { event.id }
    /// A tool call with no finish in the record, in an attempt that is over: an attempt before the task's `current`
    /// one, or the attempt `stopped` that a confirmed hold ended. It runs no more, and its result is not known. The
    /// record does not change: `status` stays what the runtime reported last.
    public func endedWithoutResult(current: Int, stopped: Int? = nil) -> Bool {
        event.type == "tool_call" && !["completed", "failed"].contains(status ?? "") && (event.attempt < current || event.attempt == stopped)
    }
}
public struct ActivityTimeline: Sendable {
    public private(set) var rows: [ActivityRow] = []
    public private(set) var runtimes: [Int: Set<String>] = [:]
    public private(set) var models: [RuntimeModelUse] = []
    private var tools: [RuntimeToolKey: Int] = [:]
    public private(set) var plan: [RuntimeEvent.PlanEntry] = []
    public init() {}
    public mutating func append(_ events: [RuntimeEvent]) {
        for event in events {
            if event.type == "session", event.parent == nil, let runtime = event.runtime, !runtime.isEmpty {
                runtimes[event.attempt, default: []].insert(runtime)
            }
            if event.type == "model", event.parent == nil {
                let use = RuntimeModelUse(event: event)
                if !models.contains(where: { $0.id == use.id }) { models.append(use) }
            }
            if event.type == "plan" {
                if event.parent == nil { plan = event.entries ?? []; continue }
            }
            if event.type == "tool_call_update", let key = event.toolKey, let index = tools[key] {
                rows[index].status = event.status ?? rows[index].status
                rows[index].output = event.output ?? rows[index].output
                rows[index].locations = event.locations ?? rows[index].locations
                rows[index].changes = event.changes ?? rows[index].changes
                rows[index].subagent = event.subagent ?? rows[index].subagent
                rows[index].updatedAt = event.ts ?? rows[index].updatedAt
                rows[index].lastEventID = event.id
            } else if ["agent_message", "agent_thought", "tool_call", "error", "truncated", "plan"].contains(event.type) {
                if let key = event.toolKey { tools[key] = rows.count }
                rows.append(ActivityRow(event: event, status: event.status, output: event.output,
                                        locations: event.locations ?? [], changes: event.changes ?? [], subagent: event.subagent,
                                        updatedAt: event.ts, lastEventID: event.id))
            }
        }
    }
    public func children(of key: RuntimeToolKey) -> [ActivityRow] {
        rows.filter { $0.event.attempt == key.attempt && $0.event.session == key.session && $0.event.parent == key.call }
    }
    public var changedFiles: [FileChange] {
        // Updates replace a tool's report. The latest completed report for each
        // path is shown; these counts are not a net repository diff.
        // Child transcripts can arrive after newer parent activity. Compare
        // completion times, with event order breaking ties or missing times.
        var files: [String: (change: FileChange, time: Double?, eventID: Int)] = [:]
        for row in rows where row.status == "completed" {
            for change in row.changes {
                if let previous = files[change.path] {
                    if let time = row.updatedAt, let oldTime = previous.time, time != oldTime {
                        if time < oldTime { continue }
                    } else if row.lastEventID < previous.eventID { continue }
                }
                files[change.path] = (change, row.updatedAt, row.lastEventID)
            }
        }
        return files.values.map(\.change).sorted { $0.path < $1.path }
    }
}
