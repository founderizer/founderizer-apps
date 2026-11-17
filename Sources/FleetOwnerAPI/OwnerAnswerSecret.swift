import Foundation

/// **`answer_secret_request`: the signed answer to an agent's request for a secret** (the secrets plan,
/// `agent-install-secrets-plan.md`, section 2; the owner, 16 November 2026: "Yes, build it"). It does what the press
/// "Answer with it" does in the secure form of a request on Needs you (`SecretEntryView.answerWith` and `proceed` in
/// the app), for a secret that the fleet's list has already: each agent of `give` gets the secret with the owner's
/// signed grant, as `grant_secret` gives it, and then the request gets its answer (`POST /ui/needs/<need>/secret`
/// with `login`), whose words to the agent are the hub's own: the secret's name, its reference and who holds it,
/// never a value.
///
/// **The gives come first**, so that the hub's answer names the agents that hold the secret, and a task that waits
/// on the request goes on with it when the agent that asked holds the secret then (`hub.py` `answer_secret`: `gave`,
/// `secret_wakes`).
///
/// **The tool has no value part and no source**: it moves no secret's value, reads no file and not the standard
/// input, and no answer has a value. A new value goes into the vault first with `save_secret`; this tool then
/// answers with the reference that the save gave.
///
/// **No question to the owner** (the owner, 15 November 2026: "No touch"). So a program that runs as the owner's
/// user on this Mac can make the app answer any open request of the fleet with any fitting secret of the list, and
/// give it with the owner's signature to any worker or lead (`OWNER-MCP-BOUNDARY.md`, section 7b). The guide, and
/// not the tool, says that the owner's agent answers only with the secret and the agents that the owner named.
///
/// **It writes grants, as `grant_secret` does, so the two tools share one line of writes** (`GrantSecret.Line`):
/// two calls whose grant writes cross can end with a grant in the list whose signature the other call ended.
///
/// **It never takes a give back because of the answer.** When the request was closed first (by the owner, an agent
/// or the hub), the gives of the call stand, and the words send the caller to the owner: only the owner says whether
/// those agents keep the secret.
///
/// This file has the whole tool: its fields and their forms, its fixed sentences, the read of a request, the app's
/// desk and the answer to one call. The app's side is `LinkTools.answerDesk`, closure by closure.
public enum AnswerSecret {
    public static let name = "answer_secret_request"
    public static let fields = ["need", "login", "give"]

    /// The most agents of one call: the hub's own bound of a request's proposal (`hub.py` `SECRET_GIVE_MAX`; a
    /// test holds the two equal).
    static let giveMost = 12
    /// The largest id of a Needs-you item that the tool takes, as `decline_secret_request` takes it.
    static let needMost = 2_147_483_647

    public static let tool = OwnerTable.Tool(
        name: name, description: """
            Answers one request of an agent for a secret with a secret that the fleet's list has already, as Answer \
            with it does in the Founderizer app's form of that request on Needs you. First the app gives the secret \
            to each agent of give with the owner's signature, as grant_secret does. Then the hub answers the \
            request: the agent that asked gets the hub's own words, which name the secret, its reference and who \
            holds it, and never its value. need: the id of the Needs-you item, a whole number, as fleet_overview \
            gives it under needs_you; the item's kind is secret, and its secret says what it asks for. login: the \
            secret's reference as fleet_read(page="team") gives it under logins: bws:// and a UUID in lower case, \
            with no secret: before it. The secret must fit the request: an API key of the variable name that the \
            request names, or a login of the request's site. For a new value, save it first with save_secret and \
            answer with the reference of that save. give: an object that must be given, of at most 12 agents: \
            each key an agent's name, as fleet_read(page="team") gives it, and each value use or read. {} answers \
            the request and gives the secret to no agent. The agent that asked gets the secret only when give names \
            it or when it holds the secret already; the answer closes the request either way. use lets an agent use \
            the secret and never see it. read is only for an API key: it puts the key's value into that agent's \
            sessions as a variable, so give read only when the owner asked for it. Each agent must be a worker or a \
            lead. The request's own give is a proposal and no decision: answer only with the secret and the agents \
            that the owner named. The gives go one after the other in the order of the agents' names, and the first \
            one that fails stops the call: the gives before it stand, and the call does not answer the request. \
            A request that is for the door (its secret has door, or its give has the key door) is the owner's \
            to answer in the app. A request that has its answer takes no other one. A no is \
            decline_secret_request. Only the Mac that set up Founderizer Vault holds the owner's key and can sign a \
            give; with give {} the app signs nothing. It answers need, login, answered true, given (for each \
            agent: agent, level, server, changed, vault when the hub says it, and note) and note. One call of this \
            tool or of grant_secret writes at a time: a call that comes while another one is at its writes is \
            refused. No answer has a secret's value.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "need": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(Int64(needMost))]),
                "login": .object(["type": .string("string")]),
                "give": .object(["type": .string("object"), "maxProperties": .int(Int64(giveMost)),
                                 "additionalProperties": .object(["type": .string("string"),
                                                                  "enum": .array([.string("use"), .string("read")])])]),
            ]),
            "required": .array([.string("need"), .string("login"), .string("give")]),
            "additionalProperties": .bool(false),
        ]),
        annotations: .object(["readOnlyHint": .bool(false)]), kind: .swift, route: "", fields: [], what: name,
        revisionPage: nil, requestIDFromArguments: false, feature: nil)

    // ------------------------------------------------------------ the fixed sentences

    // Each names only the tool's own fields. None quotes what the caller sent, with one exception: a sentence about
    // one agent of `give` names that agent. Such a name passed the name's form (`GrantSecret.isAgentName`: a-z, 0-9
    // and "-"), the tool reads no file, so the name is a word of the caller's own, and the caller needs to know
    // which of up to 12 agents failed. Nothing else of a request is in a sentence: not the reference, not a level
    // and not the item's id. The one other part that is not fixed is the hub's own words after a certain refusal of
    // the hub (`GrantSecret.withHubWords`), which stand last. A sentence says "Nothing was sent." exactly when the
    // app sent no write.

    static let only = "answer_secret_request takes only need, login and give. Nothing was sent."
    static let noPart = "answer_secret_request takes no part after its request line. Nothing was sent."
    static let needWord = "need must be the id of the Needs-you item as fleet_overview gives it under needs_you: a "
        + "whole number from 1 to 2147483647, as a JSON number and not as a text. Nothing was sent."
    static let loginWord = "login must be the secret's reference as fleet_read(page=\"team\") gives it under logins: "
        + "bws:// and a UUID in lower case, with no secret: before it. Nothing was sent."
    /// A call with no `give` gives nothing and answers nothing: a field that was forgotten is no "no agent".
    static let needsGive = "answer_secret_request needs give: an object of the agents that get the secret, each with "
        + "use or read, or {} to answer the request and give the secret to no agent. Nothing was sent."
    static let giveWord = "give must be a JSON object of the agents that get the secret, each with use or read, or {} "
        + "for no agent. Nothing was sent."
    static let giveMany = "give takes at most 12 agents. Give the secret to the others with grant_secret. Nothing was "
        + "sent."
    static let giveAgentWord = "Each name in give must be an agent's name as fleet_read(page=\"team\") gives it: 2 to "
        + "31 characters of a-z, 0-9 and -, with a letter first. Nothing was sent."
    static let giveLevelWord = "Each agent in give must have use or read. use lets the agent use the secret and never "
        + "see it, and read is only for an API key. Nothing was sent."

    static let notReady = "The Founderizer app's reading of the fleet is not current now, or the app has no fleet. "
        + "Call answer_secret_request again in a moment. Nothing was sent."
    /// The hub that the app shows does not list `signed_grants`, and the call has a give.
    static let noSignedGrants = "This hub takes no signed grant, so the app signs nothing for it. On such a fleet, "
        + "give the secret to each agent with grant_access, and then call answer_secret_request with give {}. "
        + "Nothing was sent."
    static let requestUnread = "The Founderizer app could not read the request from the hub. Call "
        + "answer_secret_request again in a moment. Nothing was sent."
    static let teamUnread = "The Founderizer app could not read the fleet's list from the hub. Call "
        + "answer_secret_request again in a moment. Nothing was sent."
    static let vaultUnread = "The Founderizer app could not read the central vault's status from the hub. Call "
        + "answer_secret_request again in a moment. Nothing was sent."
    static let noRequest = "The fleet has no Needs-you item of that id: fleet_overview gives the items under "
        + "needs_you. Nothing was sent."
    static let notSecretRequest = "That Needs-you item asks for no secret, so this tool does not answer it: "
        + "answer_needs_you answers it, in the owner's words. Nothing was sent."
    /// The request has an answer, and its saved reference is this call's `login`: an earlier call of this tool, or
    /// the owner's own answer in the app. The second call of "call again in the same way" ends here.
    static let answeredWithThis = "That request has its answer already, with this secret. This call gave the secret "
        + "to no agent: grant_secret gives it to an agent. Nothing was sent."
    /// The request is closed in another way. The owner declined it or answered it with another secret; or the
    /// manager withdrew it (`hub.py` `t_withdraw_need`), or the hub closed it because its agent was removed. A
    /// request whose last waiting task ended with no answer is not closed but gone (`hub.py` `secret_waits_end`
    /// deletes it): that is `noRequest`.
    static let answeredAlready = "That request is closed already: the owner declined it or answered it with another "
        + "secret, or an agent or the hub closed it. A request takes one answer. Nothing was sent."
    /// The request names a door's credential, or its proposal names the door as a holder (`Request.door`). The hub
    /// writes the door's own credential with the answer of the first kind (`hub.py` `save_door_credential`), and
    /// the app's form gives the secret to the door with a signed grant of its own for both. This tool signs for no
    /// door, so it leaves the whole answer to the owner.
    static let doorRequest = "That request is for the door, and this tool does not answer such a request: the owner "
        + "answers it in the Founderizer app, on Needs you. Nothing was sent."
    static let noSecret = "The fleet's list has no secret of that reference: fleet_read(page=\"team\") gives the "
        + "references under logins. Nothing was sent."
    static let notFitting = "That secret does not fit the request: the request asks for the other kind of secret (an "
        + "API key or a login), for an API key of another variable name, or for a login of another site. "
        + "fleet_overview gives what the request asks for under needs_you, in secret. Nothing was sent."
    static let noFleet = "The hub did not say which fleet this is, so the app cannot sign for it. Call "
        + "answer_secret_request again in a moment. Nothing was sent."
    /// As `GrantSecret.noVaultReading`: "no reading" is not "no central vault", so the words send the caller to
    /// `grant_access` only after the owner said that the fleet has no vault.
    static let noVaultReading = "The hub has no reading of a central vault now: this fleet has none, or the hub has "
        + "not read it since it started. Call answer_secret_request again in a minute. If the same answer comes "
        + "again, ask the owner whether this fleet has Founderizer Vault: only on a fleet that has none, give the "
        + "secret to each agent with grant_access, and then call answer_secret_request with give {}. Nothing was sent."
    static let vaultSilent = "The hub's last reading of the central vault failed, so the vault may not answer now. "
        + "Call answer_secret_request again in a minute. Nothing was sent."
    static let noOwnerKey = "This Mac holds no owner key for this fleet, so the app on it cannot sign a give: only "
        + "the Mac that set up Founderizer Vault signs. Nothing was sent."
    /// The two tools that write grants share one line, and one sentence says so for both (`GrantSecret.busy`).
    static let busy = GrantSecret.busy
    /// The call's connection ended before its first write. Nobody reads this.
    static let ended = "The call ended before its first write. Nothing was sent."

    // The checks of one agent of `give`. Each names the agent.

    /// Also the answer for the door's name: the door is no agent of the team.
    static func noAgent(_ agent: String) -> String {
        "The fleet has no agent named \(agent): fleet_read(page=\"team\") gives the agents. Nothing was sent."
    }
    static func notWorker(_ agent: String) -> String {
        "The agent \(agent) is no worker and no lead, and the hub delivers a secret of the central vault only for a "
            + "worker or a lead. Nothing was sent."
    }
    static func noServer(_ agent: String) -> String {
        "The hub names no server for the agent \(agent), so there is no server to sign the grant for. Nothing was "
            + "sent."
    }
    static func readNeedsKey(_ agent: String) -> String {
        "give has read for the agent \(agent), and read is only for an API key: that secret is no API key, and a "
            + "login is used and never seen. Give it with use. Nothing was sent."
    }
    static func readsTwice(_ agent: String) -> String {
        "The agent \(agent) already reads another API key of the same variable name, and a session has one value "
            + "for one name. Ask the owner which of the two keys that agent reads. Nothing was sent."
    }

    // After a write went out.

    /// The agents that this call gave the secret to before a give that stopped it, in the order of their names.
    static func gaveBefore(_ agents: [String]) -> String {
        agents.isEmpty ? "Before that, this call gave the secret to no agent."
            : "Before that, this call gave the secret to: \(agents.joined(separator: ", ")). Those grants stand."
    }

    /// The agents that this call gave the secret to, when all its gives went.
    static func gave(_ agents: [String]) -> String {
        agents.isEmpty ? "This call gave the secret to no agent."
            : "This call gave the secret to: \(agents.joined(separator: ", ")). Those grants stand."
    }

    /// What a stop says of the request. Not "the request has no answer": the owner, an agent or the hub can have
    /// closed it while the gives ran, and the tool did not read it again.
    static let noAnswerYet = "This call did not answer the request."

    /// **The words for the give that stopped a call**: the agent, what its give left, the agents that got the secret
    /// before it, and that this call did not answer the request. The meanings are those of `grant_secret`'s
    /// sentences for the same ends. The hub's own words, when the end has them, stand last.
    static func stopped(_ end: GrantSecret.GiveEnd, agent: String, before: [String]) -> String {
        let rest = "\(gaveBefore(before)) \(noAnswerYet)"
        switch end {
        case .given:
            // No call asks for this: a give that went stops nothing.
            return rest
        case .notSignedNow:
            return "This Mac held an owner key for this fleet a moment ago, and the app could not sign the grant for "
                + "the agent \(agent) with it now: the Mac can be locked, the key can be gone, or macOS did not let "
                + "the app read it. The app sent nothing for that agent. \(rest) Call answer_secret_request again "
                + "later."
        case .signRefused(let status, let said):
            return GrantSecret.withHubWords(
                "The hub refused the owner's signed grant for the agent \(agent), so that give changed nothing. "
                    + rest, status: status, said)
        case .signNotKnown:
            return "Whether the vault took the owner's signed grant for the agent \(agent) is not known, and the "
                + "fleet's list was not changed for that agent. \(rest) Call answer_secret_request again in the same "
                + "way: a give that went is given again with no change, and a second signature of the same grant is "
                + "no error, because the vault keeps the newer one."
        case .grantNotKnown:
            return "The app signed the grant for the agent \(agent) with the owner's key, and whether the fleet's "
                + "list has that grant is not known. \(rest) Call answer_secret_request again in the same way: a "
                + "give that went is given again with no change."
        case .refusedTakenBack(let status, let said):
            return GrantSecret.withHubWords(
                "The hub refused the grant for the agent \(agent), and the app took the owner's signature of it "
                    + "back: the fleet's list has no grant of this secret for that agent, and the vault no signed "
                    + "grant of it for that agent. " + rest, status: status, said)
        case .refusedSignatureLeft(let status, let said):
            return GrantSecret.withHubWords(
                "The hub refused the grant for the agent \(agent), and the app could not take the owner's signature "
                    + "of it back: a signed grant of this secret for that agent stays in the vault with no grant in "
                    + "the fleet's list. Call grant_secret with this login, the agent \(agent) and level null to end "
                    + "it. " + rest, status: status, said)
        case .refusedListHasOne(let status, let said):
            return GrantSecret.withHubWords(
                "The hub refused the grant for the agent \(agent). The fleet's list has a grant of this secret for "
                    + "that agent, which stays as it is, and the owner's signature stands for it. " + rest,
                status: status, said)
        case .refusedListUnread(let status, let said):
            return GrantSecret.withHubWords(
                "The hub refused the grant for the agent \(agent). The app signed the grant before that and could "
                    + "not read the fleet's list after it. Read fleet_read(page=\"team\"). If the list has no grant "
                    + "of this secret for that agent, call grant_secret with this login, the agent \(agent) and "
                    + "level null to end the signed grant. If it has one, change nothing: the signature stands for "
                    + "it. " + rest, status: status, said)
        }
    }

    /// What the caller does about gives that stand when this call did not answer the request, because the request
    /// was closed first (by the owner, an agent or the hub) or the hub refused the answer: the tool takes nothing
    /// back, because only the owner says whether those agents keep the secret.
    static func askTheOwner(_ agents: [String]) -> String {
        agents.isEmpty ? ""
            : " Ask the owner whether those agents keep the secret: grant_secret with level null takes it back from "
                + "one agent."
    }

    /// The hub said that the request had its answer, and the read after it shows this call's `login` as its answer.
    static func hadAnswerWithThis(_ agents: [String]) -> String {
        "The request had its answer already, with this secret, from an answer before this one. \(gave(agents))"
    }

    /// The same, when the read shows a close of another kind: the request was closed first, by the owner (a
    /// decline, or another secret), by an agent or by the hub.
    static func closedFirst(_ agents: [String]) -> String {
        "The request was closed before this call's answer came: the owner declined it or answered it with another "
            + "secret, or an agent or the hub closed it. So the hub did not take this call's answer. "
            + "\(gave(agents))\(askTheOwner(agents))"
    }

    /// The same, when the read after it failed or did not show how the request was closed.
    static func answeredUnread(_ agents: [String]) -> String {
        "The request was closed already, and the app could not read how. \(gave(agents))\(askTheOwner(agents))"
    }

    /// A certain refusal of the answer by the hub, of another kind. The hub's words come after it. One such
    /// refusal is for a request that is gone (the hub's 404 `request_unknown_ended`): the gives of the call then
    /// stand for a request that no longer is, so the words send the caller to the owner.
    static func answerRefused(_ agents: [String]) -> String {
        "The hub refused the answer, so this call did not answer the request. \(gave(agents))\(askTheOwner(agents))"
    }

    /// The answer went out, with no known outcome.
    static func answerNotKnown(_ agents: [String]) -> String {
        "Whether the request has its answer is not known. \(gave(agents)) Call answer_secret_request again in the "
            + "same way: when the answer went, that call says that the request has its answer with this secret, and "
            + "it sends nothing."
    }

    /// The program's words when its request went out and no answer came back (the app did not answer in time, or
    /// the link ended): the app may have signed grants, written them and answered the request.
    public static let notKnownHere = "The Founderizer app did not answer in time, or the link ended, so what the "
        + "app signed, wrote and answered for this call is not known. Call answer_secret_request again in the same "
        + "way: that is safe, because a give that went is given again with no change, and the call sends nothing "
        + "when the request has its answer with this secret already. fleet_overview shows the request under "
        + "needs_you, and fleet_read with the pages team and vault shows the grants in the fleet's list and the "
        + "owner's signed grants."

    // The notes of an answer.

    static let noteAnswered = "The agent that asked got the hub's own words: the secret's name, its reference and "
        + "who holds it now, and never its value."
    static let noteNoGive = "This call gave the secret to no agent."

    // ------------------------------------------------------------ the fields, on both sides

    /// One agent of `give`, with its level.
    struct Give: Equatable {
        let agent: String
        let level: GrantSecret.Level
    }

    /// One call, as the tool reads it. `give` is in the byte order of the agents' names.
    struct Read: Equatable {
        let need: Int
        let login: String
        let give: [Give]
    }

    /// **The checks of the fields, in a fixed order**, the same in the program and in the app: a field named like
    /// a value, a field that the tool does not take, `need`, `login`, and then `give`: absent, no object, more than
    /// 12 agents, a name that is no agent's name, and a level that is not use or read. Only a JSON integer is a
    /// `need`: a text, a fraction and a boolean are refused. No refusal quotes anything of the request.
    static func read(_ fields: [String: JSONValue]) -> Result<Read, OwnerChannel.Refusal> {
        if fields.keys.contains(where: OwnerLinkTools.namedLikeAValue) {
            return .failure(.init(OwnerLinkTools.neverAField))
        }
        guard fields.keys.allSatisfy({ Self.fields.contains($0) }) else { return .failure(.init(only)) }
        guard case .int(let id)? = fields["need"], (1...Int64(needMost)).contains(id) else {
            return .failure(.init(needWord))
        }
        guard case .string(let login)? = fields["login"], GrantSecret.isReference(login) else {
            return .failure(.init(loginWord))
        }
        guard let wanted = fields["give"] else { return .failure(.init(needsGive)) }
        guard case .object(let named) = wanted else { return .failure(.init(giveWord)) }
        guard named.count <= giveMost else { return .failure(.init(giveMany)) }
        guard named.keys.allSatisfy(GrantSecret.isAgentName) else { return .failure(.init(giveAgentWord)) }
        var give: [Give] = []
        for (agent, word) in named {
            guard case .string(let text) = word, let level = GrantSecret.Level(rawValue: text) else {
                return .failure(.init(giveLevelWord))
            }
            give.append(Give(agent: agent, level: level))
        }
        // The byte order of the names: the order of the gives, of the checks of the agents and of the answer.
        give.sort { $0.agent.utf8.lexicographicallyPrecedes($1.agent.utf8) }
        return .success(Read(need: Int(id), login: login, give: give))
    }

    // ------------------------------------------------------------ the program's side

    /// **What the program sends to the app**: the three fields as the read took them, with `need` as an integer
    /// and `give` as an object of the levels' words. The program reads no file and not its standard input for this
    /// tool.
    public static func plan(_ fields: [String: JSONValue]) -> Result<[String: JSONValue], OwnerChannel.Refusal> {
        read(fields).map { read in
            let give = read.give.map { ($0.agent, JSONValue.string($0.level.rawValue)) }
            return ["need": .int(Int64(read.need)), "login": .string(read.login),
                    "give": .object(Dictionary(give) { first, _ in first })]
        }
    }

    // ------------------------------------------------------------ the request, as the hub's state has it

    /// **What one Needs-you item says of itself**, as the tool reads it from the hub's state (`hub.py`
    /// `need_view`, `need_secret`). It names a secret and never holds a value.
    public struct Request: Equatable, Sendable {
        /// The item asks for a secret: its `kind` is `secret`.
        public let isSecret: Bool
        /// The item has no answer: its `answer` is null or absent.
        public let open: Bool
        /// The request asks for an API key, and not for a login: its secret's `kind`, with the hub's own default
        /// (`api_key`) for a request that names none.
        public let apiKey: Bool
        /// An API key's variable name, as the request names it.
        public let env: String?
        /// The request's site: only a text that starts with `https://` and gives a host.
        public let site: String?
        /// **The request is for the door**: its secret has `door`, present and not null, or its proposal (`give`)
        /// is an object with the door's name as a key. The manager's proposal can name the door with no `door`
        /// (`hub.py` `t_request_secret`); the app's form then always gives the door the secret
        /// (`SecretEntryView.doorGrant`), and after an answer nothing else can. So this tool leaves both to the owner.
        public let door: Bool
        /// The reference of the secret that answered the request, when it has the form of a reference.
        public let saved: String?

        public init(isSecret: Bool = true, open: Bool = true, apiKey: Bool = true, env: String? = nil,
                    site: String? = nil, door: Bool = false, saved: String? = nil) {
            self.isSecret = isSecret
            self.open = open
            self.apiKey = apiKey
            self.env = env
            self.site = site
            self.door = door
            self.saved = saved
        }

        /// The site's host in lower case, or nil for a request with no site that parses.
        var host: String? { site.flatMap { URLComponents(string: $0)?.host?.lowercased() } }

        /// **Whether a secret of the list fits this request**, by the rule of the form's own list of secrets that
        /// fit (`NeedSecret.fits(title:)` in FleetCore, which this library does not link, and the hub's own check
        /// of the kind in `answer_secret`): the same kind; for an API key, its name (its variable name, else its
        /// title) is the request's variable name; for a login, its title starts with the request's host in lower
        /// case and " · ", or, for a request with no site that parses, its title holds " · ".
        ///
        /// **The tool trusts the hub's forms of `env` and `site`** and does not copy FleetCore's own checks of them
        /// (`LoginSecret.isVariable`, `LoginSecret.isAddress`): the hub writes only an `https://` site
        /// (`hub.py` `t_request_secret`, `SECRET_SITE`) and a variable name by its own rule (`env_name`). So for
        /// the rows that the hub writes, this fit equals the form's, and a test holds the two to each other over
        /// the same JSON.
        func fits(_ secret: GrantSecret.Team.Secret) -> Bool {
            guard secret.apiKey == apiKey else { return false }
            if apiKey {
                guard let env, let name = secret.env ?? secret.title else { return false }
                return name == env
            }
            guard let title = secret.title else { return false }
            return host.map { title.hasPrefix($0 + " · ") } ?? title.contains(" · ")
        }
    }

    /// What one read of the hub's state says of the item of one id.
    public enum RequestRead: Equatable, Sendable {
        case found(Request)
        /// The state has no item of that id.
        case none
        /// The state is of another database than the one that the call reads and sends with.
        case otherGeneration
        /// The bytes are no state that the tool can read.
        case unreadable
    }

    /// A JSON number that is a whole number, and no boolean (`JSONSerialization` gives both as `NSNumber`).
    private static func whole(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let exact = Int(exactly: number.doubleValue), number.intValue == exact else { return nil }
        return exact
    }

    /// **The item of one id in the bytes of the hub's state** (`GET /ui/state`): a pure function, so that a test
    /// calls it with real JSON. The state names its database (`db`), and has every item under `needs`, the
    /// answered ones too. Text of the state is data: the tool reads only the typed facts of `Request`, and none of
    /// them goes into a sentence.
    ///
    /// **What it takes as it comes.** An `id` is a whole JSON number, also one written with a fraction of zero
    /// (12.0 is 12), and never a boolean. A secret's `kind` that is not the text `login` (also one that is no text)
    /// is the hub's default, an API key. `env` and `site` are the hub's own forms, which the tool trusts
    /// (`Request.fits`). **`door` is strict on purpose**: each `door` that is present and not null makes a door
    /// request, also an empty text and a `false`, because a request that this tool wrongly leaves to the owner
    /// costs one answer in the app, and one that it wrongly answers leaves the door without its secret.
    public static func request(in data: Data, need: Int, database: String) -> RequestRead {
        guard let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let generation = state["db"] as? String, let items = state["needs"] as? [Any] else {
            return .unreadable
        }
        guard generation == database else { return .otherGeneration }
        guard let item = items.lazy.compactMap({ $0 as? [String: Any] }).first(where: { whole($0["id"]) == need })
        else { return .none }
        let secret = item["secret"] as? [String: Any] ?? [:]
        let answer = item["answer"]
        let site = (secret["site"] as? String).flatMap { text -> String? in
            guard text.hasPrefix("https://"), URLComponents(string: text)?.host?.isEmpty == false else { return nil }
            return text
        }
        // For the door: the request names a door's credential, or its proposal names the door as a holder.
        let proposal = secret["give"] as? [String: Any] ?? [:]
        let door = secret["door"].map { !($0 is NSNull) } ?? false || proposal[GrantSecret.door] != nil
        return .found(Request(
            isSecret: item["kind"] as? String == "secret", open: answer == nil || answer is NSNull,
            // The hub's default, and FleetCore's reading of it: a request that names no login asks for an API key.
            apiKey: secret["kind"] as? String != "login", env: secret["env"] as? String, site: site, door: door,
            saved: (secret["saved"] as? String).flatMap { GrantSecret.isReference($0) ? $0 : nil }))
    }

    // ------------------------------------------------------------ the app's side

    /// **The one error of the `answer` closure that says "the hub refused, because the request has its answer"**
    /// (the hub's code `request_answered`). The desk throws it, so that the logic reads no code of the hub.
    public struct Answered: Error, Equatable, Sendable {
        public init() {}
    }

    /// **The app's engine for the tool**, as closures, so that a test gives stand-ins: the library does not link
    /// FleetCore, and no test reads a Keychain or reaches a hub. `Place` is the hub, the database and the
    /// installation that one call reads and sends with.
    ///
    /// **Each closure that asks the hub must end** by the time limit of the request that it makes: the writes of a
    /// call run to their end also after the call's caller went away, and neither tool of the line takes another
    /// call's writes while they run (`GrantSecret.Line`).
    ///
    /// **A failure of `sign`, `grant` or `answer` is thrown as `SaveBotToken.HubFailure`** (`LinkTools.failure`),
    /// as for `GrantSecret.Desk`. Two errors have their own type: `GrantSecret.NotSigned` of `sign` (nothing was
    /// sent), and `Answered` of `answer`.
    @MainActor
    public struct Desk<Place: Sendable> {
        /// As `GrantSecret.Desk.ready`: the place when the app's reading is current, has a database, and the hub
        /// serves the Secrets page with its grants, else nil.
        public var ready: () -> Place?
        /// As `GrantSecret.Desk.signs`. Asked only for a call with a give.
        public var signs: (Place) -> Bool?
        /// One read of the hub's state (`HubClient.stateReading`), and what its bytes say of the item of this id
        /// for the place's database (`AnswerSecret.request(in:need:database:)`). A read that failed is thrown.
        public var request: (Place, Int) async throws -> RequestRead
        /// One read of the fleet's list, with each secret's title (`HubClient.team`). A read that failed, and a
        /// page with no catalog, are thrown.
        public var team: (Place) async throws -> GrantSecret.Team
        /// One read of the vault's page (`VaultClient.reading`). Asked only for a call with a give.
        public var vault: (Place) async throws -> GrantSecret.Vault
        /// Whether this Mac holds an owner key for the fleet of this id, without reading it. Asked only for a call
        /// with a give.
        public var holdsKey: (String) -> Bool
        /// The form of a server's name that a signed grant can carry (`CentralVault.isMachine`).
        public var isMachine: (String) -> Bool
        /// As `GrantSecret.Desk.sign`: makes one statement, signs it and sends it.
        public var sign: (Place, GrantSecret.Statement) async throws -> Void
        /// The hub's grant of the secret to the agent at a level (`SecretsClient.grant`). This tool never ends a
        /// grant in the list, so the closure takes no nil.
        public var grant: (Place, String, String, GrantSecret.Level) async throws -> GrantSecret.Receipt
        /// The answer of the request of this id with the secret of this reference, under a new request id of the
        /// app (`SecretsClient.answer`, `POST /ui/needs/<need>/secret`). It throws `Answered` for the hub's
        /// refusal of a request that has its answer.
        public var answer: (Place, Int, String) async throws -> Void
        /// The app reads the fleet again (`FleetStore.refresh`), started and not waited for.
        public var refresh: () async -> Void

        public init(ready: @escaping () -> Place?, signs: @escaping (Place) -> Bool?,
                    request: @escaping (Place, Int) async throws -> RequestRead,
                    team: @escaping (Place) async throws -> GrantSecret.Team,
                    vault: @escaping (Place) async throws -> GrantSecret.Vault,
                    holdsKey: @escaping (String) -> Bool, isMachine: @escaping (String) -> Bool,
                    sign: @escaping (Place, GrantSecret.Statement) async throws -> Void,
                    grant: @escaping (Place, String, String, GrantSecret.Level) async throws -> GrantSecret.Receipt,
                    answer: @escaping (Place, Int, String) async throws -> Void,
                    refresh: @escaping () async -> Void) {
            self.ready = ready
            self.signs = signs
            self.request = request
            self.team = team
            self.vault = vault
            self.holdsKey = holdsKey
            self.isMachine = isMachine
            self.sign = sign
            self.grant = grant
            self.answer = answer
            self.refresh = refresh
        }
    }

    // ------------------------------------------------------------ the answer to one call

    /// One give that went: the agent, its level, the server that the grant was signed for, and the hub's receipt.
    struct Given {
        let give: Give
        let server: String
        let receipt: GrantSecret.Receipt
    }

    /// **The app's answer to one call**, in a fixed order. The app trusts nothing of the program's checks: it
    /// makes each of them itself.
    ///
    /// 1. The fields, each in its form (`read`). No part after the request line.
    /// 2. A current reading of the fleet, with a hub that serves the Secrets page (`Desk.ready`).
    /// 3. **Only for a call with a give**: the hub lists `signed_grants` (`Desk.signs`). A reading that moved is
    ///    "not ready".
    /// 4. The reads, each with its own sentence when it fails: the request, the fleet's list, and **only for a call
    ///    with a give** the vault's page. Then, in this order:
    ///    - the request: the state is of the place's database; the item is there; it asks for a secret; it has no
    ///      answer (an answer with this `login` has its own sentence); it is not for the door (`Request.door`:
    ///      its secret has `door`, or its proposal names the door);
    ///    - the secret: the list has it, and it fits the request (`Request.fits`);
    ///    - **only for a call with a give**, as step 4 of `grant_secret`: the page names the fleet; the hub has a
    ///      reading of a central vault whose newest read did not fail; this Mac holds the fleet's owner key; then
    ///      for each agent of `give`, in the byte order of the names: it is not the door's name and the fleet has
    ///      it, it is a worker or a lead, the hub names a server for it, `read` only for an API key, and no second
    ///      key of one variable name read by that agent.
    /// 5. No other call of this tool or of `grant_secret` is at its writes (`GrantSecret.Line`).
    /// 6. The call still has its caller: a call whose connection ended sends nothing.
    /// 7. The writes, in a task of the line's own: each give in the byte order of the names
    ///    (`GrantSecret.give(login:agent:fleet:server:sign:grant:team:)`), where the first give that does not end
    ///    in a grant stops the call, with no later give and no answer; and then the answer of the request.
    /// 8. From the first write on, the call goes to its end also when its caller went away.
    ///
    /// **No `await` stands between the look of step 5, the look of step 6 and the start of the writes.**
    ///
    /// **A call with `give` `{}` reads no vault, asks for no key and signs nothing**: its one write is the answer.
    ///
    /// **When the hub refuses the answer because the request has one**, the app reads the request one time more
    /// and says what that read shows: this secret, or a close that came first (by the owner, an agent or the hub).
    /// It takes no give back: only the owner says whether the gives stay.
    ///
    /// **The answer** of a call whose writes all went: `need`, `login`, `answered` true, `given` (in the order of
    /// the names; for each agent `agent`, `level`, `server`, `changed`, `vault` when the receipt has it, and
    /// `note`) and `note`. Then the app reads the fleet again, started and not waited for.
    @MainActor
    public static func answer<Place>(fields: [String: JSONValue], value: OwnerChannel.Value?, desk: Desk<Place>,
                                     line: GrantSecret.Line) async -> OwnerChannel.Answer {
        // 1. The fields.
        guard value == nil else { return .refused(noPart) }
        let read: Read
        switch Self.read(fields) {
        case .failure(let refusal): return .refused(refusal.text)
        case .success(let taken): read = taken
        }
        let gives = !read.give.isEmpty
        // 2. A current reading.
        guard let place = desk.ready() else { return .refused(notReady) }
        // 3. Signed grants, only for a call that signs.
        if gives {
            guard let signs = desk.signs(place) else { return .refused(notReady) }
            guard signs else { return .refused(noSignedGrants) }
        }
        // 4. The reads, and what they must show.
        let found: RequestRead, team: GrantSecret.Team
        do { found = try await desk.request(place, read.need) } catch { return .refused(requestUnread) }
        do { team = try await desk.team(place) } catch { return .refused(teamUnread) }
        var vault: GrantSecret.Vault?
        if gives {
            do { vault = try await desk.vault(place) } catch { return .refused(vaultUnread) }
        }
        let request: Request
        switch found {
        case .unreadable: return .refused(requestUnread)
        case .otherGeneration: return .refused(notReady)
        case .none: return .refused(noRequest)
        case .found(let item): request = item
        }
        guard request.isSecret else { return .refused(notSecretRequest) }
        guard request.open else { return .refused(request.saved == read.login ? answeredWithThis : answeredAlready) }
        guard !request.door else { return .refused(doorRequest) }
        guard let secret = team.secrets[read.login] else { return .refused(noSecret) }
        guard request.fits(secret) else { return .refused(notFitting) }
        var fleet = ""
        var servers: [String: String] = [:]
        if let vault {
            guard let id = vault.fleet else { return .refused(noFleet) }
            switch vault.central {
            case .noReading: return .refused(noVaultReading)
            case .silent: return .refused(vaultSilent)
            case .answers: break
            }
            guard desk.holdsKey(id) else { return .refused(noOwnerKey) }
            fleet = id
            for give in read.give {
                let name = give.agent
                guard name != GrantSecret.door, let agent = team.agents[name] else { return .refused(noAgent(name)) }
                guard GrantSecret.holderRoles.contains(agent.role) else { return .refused(notWorker(name)) }
                guard let machine = agent.machine, desk.isMachine(machine) else { return .refused(noServer(name)) }
                if give.level == .read {
                    guard secret.apiKey else { return .refused(readNeedsKey(name)) }
                    guard !team.readsTwice(read.login, agent: name) else { return .refused(readsTwice(name)) }
                }
                servers[name] = machine
            }
        }
        // 5 and 6, and then the start of the writes, with no `await` between the three.
        guard !line.busy else { return .refused(busy) }
        if Task.isCancelled { return .refused(ended) }
        let writes = line.begin { [fleet, servers] in
            await Self.writes(read, fleet: fleet, servers: servers, place: place, desk: desk)
        }
        // The line was free one line above, so this is a line that nothing reaches.
        guard let writes else { return .refused(busy) }
        // 8. The wait for the writes' end takes no cancel: the call goes on to its end without its caller.
        return await writes.value
    }

    /// **The writes of one call**: each give in the order of the names, and then the answer of the request. The
    /// first give that does not end in a grant stops the call. After a give that went, the list changed, so the app
    /// reads the fleet again also when a later write did not go. **No refresh follows when the first give stops**,
    /// as in `grant_secret` for a give that did not end in a grant: the store reads after each of its own POSTs
    /// anyway (`HubWrites.note` in the app).
    @MainActor
    private static func writes<Place>(_ read: Read, fleet: String, servers: [String: String], place: Place,
                                      desk: Desk<Place>) async -> OwnerChannel.Answer {
        var given: [Given] = []
        var names: [String] { given.map(\.give.agent) }
        for give in read.give {
            // Each agent of `give` has its server from the checks; a give with none is a give that the checks
            // did not pass, and it stops the call as a give that was not signed.
            guard let server = servers[give.agent] else {
                return .refused(stopped(.notSignedNow, agent: give.agent, before: names))
            }
            let end = await GrantSecret.give(
                login: read.login, agent: give.agent, fleet: fleet, server: server,
                sign: { try await desk.sign(place, $0) },
                grant: { try await desk.grant(place, read.login, give.agent, give.level) },
                team: { try await desk.team(place) })
            guard case .given(let receipt) = end else {
                if !given.isEmpty { await desk.refresh() }
                return .refused(stopped(end, agent: give.agent, before: names))
            }
            given.append(Given(give: give, server: server, receipt: receipt))
        }
        do {
            try await desk.answer(place, read.need, read.login)
        } catch is Answered {
            // What the request has now, by one read more. No give is taken back: the request was closed first,
            // by the owner, an agent or the hub, and only the owner says whether the gives stay.
            let now = try? await desk.request(place, read.need)
            if !given.isEmpty { await desk.refresh() }
            guard case .found(let request)? = now, !request.open else { return .refused(answeredUnread(names)) }
            return .refused(request.saved == read.login ? hadAnswerWithThis(names) : closedFirst(names))
        } catch SaveBotToken.HubFailure.refused(let status, let said) where status < 500 {
            if !given.isEmpty { await desk.refresh() }
            return .refused(GrantSecret.withHubWords(answerRefused(names), status: status, said))
        } catch {
            if !given.isEmpty { await desk.refresh() }
            return .refused(answerNotKnown(names))
        }
        await desk.refresh()
        return .result(result(read, given))
    }

    /// **The answer of a call whose writes all went.** Each entry of `given` is `grant_secret`'s result for one
    /// agent, without `login` and `signed`. No free text of the hub is in it: the hub's words for an agent's vault
    /// access pass only as codes (`GrantSecret.code`), and the hub's words to the agent that asked are not in it.
    static func result(_ read: Read, _ given: [Given]) -> JSONValue {
        let entries: [JSONValue] = given.map { one in
            var entry: [String: JSONValue] = [
                "agent": .string(one.give.agent), "level": .string(one.give.level.rawValue),
                "server": .string(one.server), "changed": .bool(one.receipt.changed),
                "note": .string(GrantSecret.note(one.give.level, one.receipt)),
            ]
            if let access = one.receipt.access {
                var vault: [String: JSONValue] = [
                    "before": GrantSecret.code(access.before).map(JSONValue.string) ?? .null,
                    "after": GrantSecret.code(access.after).map(JSONValue.string) ?? .null,
                ]
                if let missing = access.missing {
                    vault["missing"] = .array(missing.compactMap(GrantSecret.code).map(JSONValue.string))
                }
                entry["vault"] = .object(vault)
            }
            return .object(entry)
        }
        let note = given.isEmpty ? "\(noteAnswered) \(noteNoGive)" : noteAnswered
        return .object(["need": .int(Int64(read.need)), "login": .string(read.login), "answered": .bool(true),
                        "given": .array(entries), "note": .string(note)])
    }
}
