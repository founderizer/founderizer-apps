import Foundation

/// **`grant_secret`: one secret of the fleet to one agent with the owner's signature, or its end** (the secrets
/// plan, `agent-install-secrets-plan.md`, section 2; the owner, 16 November 2026: "Yes, build it"). It does what
/// Give and Take back of the app's Secrets page do: the app signs the owner's statement of the grant with the owner
/// key of this Mac and sends it to the central vault through the hub (`POST /ui/vault/grant`), and the hub writes
/// the grant into the fleet's list (`POST /ui/secrets/grant`).
///
/// **Why the app signs.** On a fleet with a central vault, the vault seals a secret's value for a server only for a
/// grant that the owner signed for an agent on that server, or for a secret of the signed pool (`vault.py`
/// `sealable`). Only the app holds the owner key. `grant_access` of both programs writes the list with no signature,
/// so a give from it brings a new secret's value to no server.
///
/// **No question to the owner** (the owner, 15 November 2026, to "Should every change that your agent makes the app
/// sign need your touch (Touch ID)?": "No touch"). So a program that runs as the owner's user on this Mac can make
/// the app sign a grant of any secret of the list to any worker or lead (`OWNER-MCP-BOUNDARY.md`, section 7b).
///
/// **The order keeps the vault the narrower of the two**, as the app's own controls keep it (`GrantSigning` in the
/// app): a give signs first and writes the list second; a take-back ends the list's grant first and the signature
/// second. When the hub refuses the grant of a give, the app reads the list again and ends its signature when that
/// read shows no grant.
///
/// **The tool has no value part and no source**: it moves no secret's value, and no answer has one. This file has
/// the whole tool: its fields and their forms, its fixed sentences, the app's desk and the answer to one call. The
/// app's side is `LinkTools.grantDesk`, closure by closure.
public enum GrantSecret {
    public static let name = "grant_secret"
    public static let fields = ["login", "agent", "level"]

    /// **The door's name as a holder of the central vault** (`DoorAccess.holder` in FleetCore, which this library
    /// does not link; a test holds the two equal). The hub reads a grant for this name as the door's own
    /// (`hub.py` `save_grant`), and the door is no agent of the team: this tool never signs for it and never
    /// writes for it, for a give and for a take-back. It is also the machine of the door's signed grant. Only
    /// `answer_secret_request` gives the door a secret, with the answer of a request for the door, as the app's form
    /// of that request does (`AnswerSecret`).
    static let door = "door"

    /// The roles of an agent that can hold a secret of the central vault: the hub delivers only what workers and
    /// leads hold (`hub.py` `central_plan`).
    static let holderRoles = ["worker", "lead"]

    /// The most Unicode scalars of the hub's own words that a refusal carries.
    static let hubWordsMost = 300

    public static let tool = OwnerTable.Tool(
        name: name, description: """
            Access: Gives one secret of the fleet to one agent with the owner's signature, or takes it back, as Give \
            and \
            Take back on the Founderizer app's Secrets page do. On a fleet with a central vault, the vault sends a \
            secret's value to a server only for a grant that the owner's key signed. This tool makes the Founderizer \
            app sign the grant with the owner's key on this Mac and send it, and then the hub writes the grant into \
            the fleet's list. login: the secret's reference as fleet_read(page="team") gives it under logins: bws:// \
            and a UUID in lower case, with no secret: before it. agent: the agent's name as that page gives it; \
            for a give, it must be a worker or a lead. level: use, read or null, and it must be given. use lets the \
            agent use the secret and never see it. read is only for an API key: it puts the key's value into that \
            agent's sessions as a variable, so give read only when the owner asked for it. null takes the secret \
            back: the hub ends the grant in the list, and the app ends the owner's signature of it. A give signs \
            first and writes the list second. When the hub refuses the grant, the app reads the list again and \
            takes its signature back when the list has no grant of this secret for this agent. Only the Mac that \
            set up Founderizer Vault holds the owner's key and can sign. On a hub that takes no signed grant, the \
            tool sends nothing: grant_access gives a secret there. While the hub has no reading of a central vault, \
            the tool sends nothing too: the fleet has none, or the hub has not read it since it started, and only \
            on a fleet that has none does grant_access give a secret in this tool's place. A grant that grant_access \
            wrote into the list \
            with no signature is repaired by the same give at the same level, which signs it. It answers login, \
            agent, level, signed true, server (the server that a give was signed for), changed (whether the hub \
            changed its list), vault (the agent's vault access before and after, with the hub's codes for what is \
            missing, when the hub says it) and note. After a give, when the central vault holds the value and that \
            server's vault takes deliveries, the central vault sends it at the hub's next pass, usually within a \
            minute (a delivery that failed waits up to six hours before the next try); fleet_read(page="vault") \
            then lists the secret under held for that server. One call writes at a time: a call that comes while \
            another one is at its writes is refused. No answer has a secret's value.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "login": .object(["type": .string("string")]),
                "agent": .object(["type": .string("string")]),
                "level": .object(["type": .array([.string("string"), .string("null")]),
                                  "enum": .array([.string("use"), .string("read"), .null])]),
            ]),
            "required": .array([.string("login"), .string("agent"), .string("level")]),
            "additionalProperties": .bool(false),
        ]),
        annotations: .object(["readOnlyHint": .bool(false)]), kind: .swift, route: "", fields: [], what: name,
        revisionPage: nil, requestIDFromArguments: false, feature: nil)

    // ------------------------------------------------------------ the fixed sentences

    // Each names only the tool's own fields, and none quotes anything that the caller sent: not a reference, not an
    // agent's name and not a level. The one part that is not fixed is the hub's own words after a certain refusal
    // of the hub (`withHubWords`), which come after the tool's own sentence, as `grant_access` gives them: they can
    // hold a reference, an agent's name or a variable's name, and never a value. A sentence says "Nothing was
    // sent." exactly when the app sent no write, and none says "signed" for a call that signed nothing. No
    // sentence says that an agent can read a login: a login is used and never seen.

    static let only = "grant_secret takes only login, agent and level. Nothing was sent."
    static let noPart = "grant_secret takes no part after its request line. Nothing was sent."
    static let loginWord = "login must be the secret's reference as fleet_read(page=\"team\") gives it under logins: "
        + "bws:// and a UUID in lower case, with no secret: before it. Nothing was sent."
    static let agentWord = "agent must be the agent's name as fleet_read(page=\"team\") gives it: 2 to 31 characters "
        + "of a-z, 0-9 and -, with a letter first. Nothing was sent."
    /// A call with no `level` is never a take-back: a field that was forgotten takes no access back.
    static let needsLevel = "grant_secret needs level: use, read, or null to take the secret back. A call with no "
        + "level takes nothing back. Nothing was sent."
    static let levelWord = "level must be use, read or null. use lets the agent use the secret and never see it, "
        + "read is only for an API key, and null takes the secret back. Nothing was sent."

    static let notReady = "The Founderizer app's reading of the fleet is not current now, or the app has no fleet. "
        + "Call grant_secret again in a moment. Nothing was sent."
    /// The hub that the app shows does not list `signed_grants`: it passes no signed statement on.
    static let noSignedGrants = "This hub takes no signed grant, so the app signs nothing for it: grant_access gives "
        + "a secret on such a fleet. Nothing was sent."
    static let teamUnread = "The Founderizer app could not read the fleet's list from the hub. Call grant_secret "
        + "again in a moment. Nothing was sent."
    static let vaultUnread = "The Founderizer app could not read the central vault's status from the hub. Call "
        + "grant_secret again in a moment. Nothing was sent."
    static let noFleet = "The hub did not say which fleet this is, so the app cannot sign for it. Call grant_secret "
        + "again in a moment. Nothing was sent."
    /// The hub's page has no central vault (`central` is null). **That is not "this fleet has no central vault"**:
    /// the hub keeps a reading only after its first good read since its start, so a fleet whose vault did not
    /// answer since then looks the same as a fleet with none (`hub.py` `central_read`). So the words do not send
    /// the caller to `grant_access`, which would write an unsigned grant on a fleet that has a vault.
    static let noVaultReading = "The hub has no reading of a central vault now: this fleet has none, or the hub has "
        + "not read it since it started. Call grant_secret again in a minute. If the same answer comes again, ask "
        + "the owner whether this fleet has Founderizer Vault: only on a fleet that has none does grant_access give "
        + "a secret in this tool's place. Nothing was sent."
    /// The hub has a reading of the central vault, and its newest read of the vault failed (the page's `error`).
    static let vaultSilent = "The hub's last reading of the central vault failed, so the vault may not answer now. "
        + "Call grant_secret again in a minute. Nothing was sent."
    static let noOwnerKey = "This Mac holds no owner key for this fleet, so the app on it cannot sign: only the Mac "
        + "that set up Founderizer Vault signs. Nothing was sent."
    /// **The first write of a give, when this Mac holds the key and the app could not sign with it** (`NotSigned`
    /// from the desk, after `holdsKey` said yes): the key's item could not be read, or the key made no signature.
    /// Not `noOwnerKey`: this Mac held a key a moment ago (it can be gone since). Nothing was sent, and the same
    /// call later can go.
    static let notSignedNow = "This Mac held an owner key for this fleet a moment ago, and the app could not sign "
        + "with it now: the Mac can be locked, the key can be gone, or macOS did not let the app read it. Nothing "
        + "was sent. Call grant_secret again later."
    /// The same fact for a take-back, with the one thing that the caller can still do from this Mac, and what it
    /// leaves behind.
    static let noOwnerKeyTakeBack = "This Mac holds no owner key for this fleet, so the app on it cannot sign: only "
        + "the Mac that set up Founderizer Vault signs. grant_access with level null ends the grant in the fleet's "
        + "list, and the owner's signed grant then stays in the vault until that Mac ends it. Nothing was sent."
    static let noSecret = "The fleet's list has no secret of that reference: fleet_read(page=\"team\") gives the "
        + "references under logins. Nothing was sent."
    /// Also the answer for the door's name, in a give and in a take-back: the door is no agent of the team.
    static let noAgent = "The fleet has no agent of that name: fleet_read(page=\"team\") gives the agents. Nothing "
        + "was sent."
    static let notWorker = "That agent is no worker and no lead, and the hub delivers a secret of the central vault "
        + "only for a worker or a lead. Nothing was sent."
    static let noServer = "The hub names no server for that agent, so there is no server to sign the grant for. "
        + "Nothing was sent."
    static let readNeedsKey = "level read is only for an API key, and that secret is no API key: a login is used "
        + "and never seen. Give it with level use. Nothing was sent."
    /// The hub's own rule (`hub.py` `read_twice`), said before the signature goes: the hub would refuse the grant.
    /// It names no take-back: which of the two keys the agent reads is the owner's to say.
    static let readsTwice = "That agent already reads another API key of the same variable name, and a session has "
        + "one value for one name. Ask the owner which of the two keys that agent reads. Nothing was sent."
    /// **A give while this Mac's clock and the hub's differ by more than an hour** (`Desk.clockApart`, the rule of the
    /// app's own controls that sign: `VaultPlan.clockProblem`). The owner's signed statement takes its time from this
    /// Mac's clock (`GrantClock.next`), and the vault keeps only a statement that is newer than the one that it holds
    /// for that grant (`central_signed` in vault.py): with a wrong clock, a statement can be refused, or be dated in
    /// the future. A take-back does not wait for the clocks: its hub step comes first, and an end only narrows.
    static let clockApart = "This Mac's clock and the hub's clock differ by more than an hour, so the app signs no "
        + "grant now. Ask the owner to check this Mac's date and time (System Settings, General, Date & Time), and "
        + "then call grant_secret again. If this Mac's clock is right, the hub's clock is probably wrong: tell the "
        + "owner. A take-back (level null) does not wait for the clocks. Nothing was sent."
    /// **One sentence for the two tools that write grants** (`AnswerSecret.busy` is this text): they share one
    /// line of writes, so the call that holds it can be a call of either tool.
    static let busy = "Another call of grant_secret or answer_secret_request is at its writes now. Call again when "
        + "it has answered. Nothing was sent."
    /// The call's connection ended before its first write. Nobody reads this.
    static let ended = "The call ended before its first write. Nothing was sent."

    // After a write went out.

    /// A give, the signed statement, a certain refusal: the vault kept nothing, and the list was not asked.
    static let signRefused = "The hub refused the owner's signed grant, so nothing was changed."
    /// A give, the signed statement, no known outcome. The list was not asked.
    static let signNotKnown = "Whether the vault took the owner's signed grant is not known, and the fleet's list was "
        + "not changed. Call grant_secret again in the same way: a second signature of the same grant is no error, "
        + "because the vault keeps the newer one."
    /// A give, the statement taken, the hub's grant refused, the list read again with no grant of this secret for
    /// this agent, and the signed end taken. It does not say "nothing is changed": a signed grant is the server's
    /// (`vault.py` `sealable`), so while it stood, another agent on that server that the list gives the secret to
    /// could get the value.
    static let grantRefusedTakenBack = "The hub refused the grant, and the app took the owner's signature of it "
        + "back: the fleet's list has no grant of this secret for this agent, and the vault no signed grant of it for "
        + "this agent."
    /// The same, when the signed end did not go.
    static let grantRefusedSignatureLeft = "The hub refused the grant, and the app could not take the owner's "
        + "signature of it back: a signed grant of this secret for this agent stays in the vault with no grant in "
        + "the fleet's list. Call grant_secret with level null to end it."
    /// The same refusal, when the list read again has a grant of this secret for this agent, at any level: the
    /// owner's own Give can have made it since the call's first read, and the signature is the one that it needs.
    static let grantRefusedListHasOne = "The hub refused this call. The fleet's list has a grant of this secret for "
        + "this agent, which stays as it is, and the owner's signature stands for it."
    /// The same refusal, when the list could not be read again: nothing says whether the signature has its grant.
    /// The words send the caller to the list first: the owner's own Give can have made a grant there, and a
    /// take-back would end it.
    static let grantRefusedListUnread = "The hub refused the grant. The app signed the grant before that and could "
        + "not read the fleet's list after it. Read fleet_read(page=\"team\"). If the list has no grant of this "
        + "secret for this agent, call grant_secret with level null to end the signed grant. If it has one, change "
        + "nothing: the signature stands for it."
    /// A give, the statement taken, the hub's grant with no known outcome.
    static let grantNotKnown = "The app signed the grant with the owner's key, and whether the fleet's list has the "
        + "grant is not known. Call grant_secret again in the same way, or read fleet_read(page=\"team\")."
    /// A take-back, the hub's end, a certain refusal: the signed grant was not asked to end.
    static let endRefused = "The hub refused the end of the grant, so nothing was changed."
    /// A take-back, the hub's end, no known outcome.
    static let endNotKnown = "Whether the hub ended the grant in the fleet's list is not known, and the owner's "
        + "signed grant is not ended. Call grant_secret again in the same way."
    /// A take-back, the hub's end taken, and the signed end did not go, with a refusal or with no known outcome.
    static let ungrantFailed = "The grant is ended in the fleet's list, so the agent's access is ended. The owner's "
        + "signed grant stays in the vault. Call grant_secret with level null again to end it: the hub's end is "
        + "then no change, and the end of the signature is sent again."

    /// The program's words when its request went out and no answer came back (the app did not answer in time, or
    /// the link ended): the app may have signed, and it may have written the list.
    public static let notKnownHere = "The Founderizer app did not answer in time, or the link ended, so what the "
        + "app signed and wrote for this call is not known. Call grant_secret again in the same way: that is safe "
        + "for a give and for a take-back. fleet_read with the pages team and vault shows the grant in the fleet's "
        + "list and the owner's signed grants."

    // The notes of an answer: what the Secrets page's own note says after a grant, as fixed English sentences.

    static let noteVaultOn = "The agent uses its server's vault now."
    static let noteNoVaultAccess = "The agent has the secret and no vault access yet, so it cannot use it now: "
        + "vault.missing has the hub's codes for what is missing."
    static let noteReads = "The agent reads the key as a variable in its sessions from their next start."
    /// A give of a grant that the list had already at this level: the repair of a grant with no signature.
    static let noteSame = "The fleet's list had this grant at this level already, so the hub changed nothing in "
        + "it, and the owner's signature of it is in the vault now."
    /// The hub's reconciler delivers only a reference that the central vault has (`hub.py` `central_plan`), to a
    /// server whose vault takes deliveries, one pass a minute, and a delivery that failed waits `CENTRAL_RETRY`.
    static let noteDelivery = "When the central vault holds the value and that server's vault takes deliveries, the "
        + "central vault sends it at the hub's next pass, usually within a minute (a delivery that failed waits up "
        + "to six hours before the next try); fleet_read(page=\"vault\") then lists the secret under held for that "
        + "server."
    static let noteTakenBack = "The hub ended the grant in the fleet's list, and the app ended the owner's signed "
        + "grant in the vault."
    static let noteNoGrant = "The fleet's list had no grant of this secret for this agent, so the hub changed "
        + "nothing in it, and the app sent the end of the owner's signed grant to the vault."

    /// **A sentence of the tool with the hub's own words after it**, for a certain refusal of the hub (its own
    /// status under 500). The hub's words pass as they came when they are a text of 1 to `hubWordsMost` Unicode
    /// scalars with no control and no format character in it; else fixed words say the status alone. Text of the
    /// hub is data: it stands last, after the tool's own sentence, and under the words that name it.
    ///
    /// **The bound counts Unicode scalars, never characters**: one letter with 100,000 combining marks after it is
    /// one character. The count stops at the bound, so a long text is not read to its end.
    static func withHubWords(_ sentence: String, status: Int, _ said: String) -> String {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        let plain = !said.isEmpty && said.unicodeScalars.prefix(hubWordsMost + 1).count <= hubWordsMost
            && !said.unicodeScalars.contains { hidden.contains($0.properties.generalCategory) }
        guard plain else { return "\(sentence) The hub answered with status \(status), and with no words that pass." }
        return "\(sentence) The hub's words (status \(status)): \(said)"
    }

    // ------------------------------------------------------------ the fields, on both sides

    /// The two levels of a grant, by the hub's own words (`hub.py` `save_grant`; `SecretGrant` in FleetCore).
    public enum Level: String, Equatable, Sendable { case use, read }

    /// One call, as the tool reads it. `level` nil is a take-back.
    struct Read: Equatable {
        let login: String
        let agent: String
        let level: Level?
    }

    /// **A secret's reference in the hub's one spelling**: `bws://` and a UUID in lower case with its hyphens, and
    /// not one byte more (`LoginSecret.isReference` in FleetCore; a test holds the two equal). A reference with
    /// `secret:` before it, with capital letters or with a line end after it is not one.
    public static func isReference(_ text: String) -> Bool {
        let start = "bws://"
        return text.hasPrefix(start) && LinkWork.isID(String(text.dropFirst(start.count)))
    }

    /// **An agent's name by the hub's own rule** (`hub.py` `AGENT_NAME`): a whole match of `[a-z][a-z0-9-]{1,30}`.
    public static func isAgentName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func small(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) }
        guard (2...31).contains(bytes.count), small(bytes[0]) else { return false }
        return bytes.allSatisfy { small($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    /// **The checks of the fields, in a fixed order**, the same in the program and in the app: a field named like
    /// a value, a field that the tool does not take, `login`, `agent`, and then `level`. A `level` that is absent
    /// is refused, and only a JSON null is a take-back.
    static func read(_ fields: [String: JSONValue]) -> Result<Read, OwnerChannel.Refusal> {
        if fields.keys.contains(where: OwnerLinkTools.namedLikeAValue) {
            return .failure(.init(OwnerLinkTools.neverAField))
        }
        guard fields.keys.allSatisfy({ Self.fields.contains($0) }) else { return .failure(.init(only)) }
        guard case .string(let login)? = fields["login"], isReference(login) else { return .failure(.init(loginWord)) }
        guard case .string(let agent)? = fields["agent"], isAgentName(agent) else { return .failure(.init(agentWord)) }
        switch fields["level"] {
        case nil:
            return .failure(.init(needsLevel))
        case .null?:
            return .success(Read(login: login, agent: agent, level: nil))
        case .string(let word)?:
            guard let level = Level(rawValue: word) else { return .failure(.init(levelWord)) }
            return .success(Read(login: login, agent: agent, level: level))
        default:
            return .failure(.init(levelWord))
        }
    }

    // ------------------------------------------------------------ the program's side

    /// **What the program sends to the app**: the three fields as the read took them, with `level` as a JSON null
    /// for a take-back. The program reads no file and not its standard input for this tool.
    public static func plan(_ fields: [String: JSONValue]) -> Result<[String: JSONValue], OwnerChannel.Refusal> {
        read(fields).map { read in
            ["login": .string(read.login), "agent": .string(read.agent),
             "level": read.level.map { JSONValue.string($0.rawValue) } ?? .null]
        }
    }

    // ------------------------------------------------------------ the app's side

    /// **The fleet's list as one read gives it** (`GET /ui/team`): each secret of the catalog with its grants, and
    /// each agent with its role and the server that the hub names for it.
    public struct Team: Equatable, Sendable {
        public struct Secret: Equatable, Sendable {
            /// The entry's kind is `api_key`.
            public let apiKey: Bool
            /// An API key's variable name.
            public let env: String?
            /// The entry's title in the list (a login's is its host, " · " and its user name), or nil for a read
            /// that did not take it. `grant_secret` does not read it; `answer_secret_request` reads it for its
            /// rule of a secret that fits a request (`AnswerSecret.Request.fits`).
            public let title: String?
            /// The agents that hold it, each with its level as the hub wrote it.
            public let grants: [String: String]

            public init(apiKey: Bool, env: String? = nil, title: String? = nil, grants: [String: String] = [:]) {
                self.apiKey = apiKey
                self.env = env
                self.title = title
                self.grants = grants
            }
        }

        public struct Agent: Equatable, Sendable {
            public let role: String
            public let machine: String?

            public init(role: String, machine: String?) {
                self.role = role
                self.machine = machine
            }
        }

        /// By reference.
        public let secrets: [String: Secret]
        /// By name.
        public let agents: [String: Agent]

        public init(secrets: [String: Secret], agents: [String: Agent]) {
            self.secrets = secrets
            self.agents = agents
        }

        /// Whether the list has a grant of this secret for this agent, at any level. The door's hold is never in this
        /// list: the team's page shows the grants of the agents only.
        func holds(_ login: String, agent: String) -> Bool { secrets[login]?.grants[agent] != nil }

        /// **The hub's rule `read_twice`**: this agent reads another API key of the variable name of this one. A
        /// session has one value for one name, so the hub refuses such a grant.
        func readsTwice(_ login: String, agent: String) -> Bool {
            guard let name = secrets[login]?.env else { return false }
            return secrets.contains {
                $0.key != login && $0.value.apiKey && $0.value.env == name
                    && $0.value.grants[agent] == Level.read.rawValue
            }
        }
    }

    /// **The vault's page as one read gives it** (`GET /ui/vault`): the fleet's id, and the central vault.
    public struct Vault: Equatable, Sendable {
        public enum Central: Equatable, Sendable {
            /// The page has no central vault (`central` is null), or the hub has no page of the vault: the hub has
            /// no reading. The fleet has no central vault, or the hub has not read it since it started; nothing
            /// on the page tells the two apart.
            case noReading
            /// The hub has a reading, and its newest read of the vault failed (the page's `error` is set), or the
            /// reading itself does not say ok.
            case silent
            case answers

            /// **What the page says of the central vault**, from the three things that it has: a central part
            /// or none (`ok` nil for none), that part's `ok`, and the page's `error` or none.
            ///
            /// The hub keeps a reading only after a read that the vault answered ok, so `central` is null
            /// until the first good read since the hub's start, on a fleet with no central vault and on a fleet
            /// whose vault did not answer yet (`hub.py` `central_read`, `vault_view`). A later read that fails
            /// keeps the last good reading and sets `error`. So:
            /// - no central part, with an `error` or with none: `noReading`;
            /// - a central part, and an `error` or an `ok` that is not true: `silent`;
            /// - a central part with `ok` true and no `error`: `answers`.
            public static func of(central ok: Bool?, error: String?) -> Central {
                guard let ok else { return .noReading }
                return ok && error == nil ? .answers : .silent
            }
        }

        public let fleet: String?
        public let central: Central

        public init(fleet: String?, central: Central) {
            self.fleet = fleet
            self.central = central
        }
    }

    /// **One statement for the app to make, sign and send**: the owner's `grant` of the secret to the agent on
    /// `machine`, or with no machine the `ungrant`.
    public struct Statement: Equatable, Sendable {
        public let fleet: String
        public let login: String
        public let agent: String
        public let machine: String?

        public init(fleet: String, login: String, agent: String, machine: String?) {
            self.fleet = fleet
            self.login = login
            self.agent = agent
            self.machine = machine
        }
    }

    /// **The hub's receipt of a grant or of its end** (`SecretGrantReceipt` in FleetCore): whether the list
    /// changed, and the agent's vault access when the grant had something to do with it.
    public struct Receipt: Equatable, Sendable {
        public struct Access: Equatable, Sendable {
            public let before: String
            public let after: String
            /// The hub's codes of what the agent's server lacks (`hub.py` `vault_grant`), or nil.
            public let missing: [String]?

            public init(before: String, after: String, missing: [String]? = nil) {
                self.before = before
                self.after = after
                self.missing = missing
            }
        }

        public let changed: Bool
        public let access: Access?

        public init(changed: Bool, access: Access? = nil) {
            self.changed = changed
            self.access = access
        }
    }

    /// **The one error of the signing closure that says "not signed, and nothing was sent"**: the owner key of
    /// this Mac could not be read (it went, the Mac is locked, or macOS did not let the app read it), or the key
    /// made no signature. Both happen before anything is sent, so the tool never reads this as "not known".
    public struct NotSigned: Error, Equatable, Sendable {
        public init() {}
    }

    /// **The app's engine for the tool**, as closures, so that a test gives stand-ins: the library does not link
    /// FleetCore, and no test reads a Keychain or reaches a hub. `Place` is the hub, the database and the
    /// installation that one call reads and sends with.
    ///
    /// **Each closure that asks the hub must end** by the time limit of the request that it makes: the writes of a
    /// call run to their end also after the call's caller went away, and the tool takes no other call's writes
    /// while they run (`Line`).
    ///
    /// **A failure of `sign` or `grant` is thrown as `SaveBotToken.HubFailure`** (`LinkTools.failure`): a refusal
    /// carries only the hub's own status and its own words. A status under 500 is a certain refusal; no answer, an
    /// answer that could not be read, a status of 500 or more and every other error count as "not known".
    @MainActor
    public struct Desk<Place: Sendable> {
        /// The hub, its database and the installation when the app's reading is current, has a database, and the
        /// hub serves the Secrets page with its grants (`store.isFresh`, a state with a database,
        /// `SecretEntryView.isOffered`: the condition under which that page lets the owner change a grant), else nil.
        public var ready: () -> Place?
        /// Whether the hub lists `signed_grants`, from the features of the hub that the app still shows
        /// (`LinkTools.features(of:at:)`). nil says one thing only: the app's reading moved to another hub or
        /// database, which is "not ready" and never "not listed".
        public var signs: (Place) -> Bool?
        /// One read of the fleet's list (`HubClient.team`). A read that failed, and a page with no catalog, are
        /// thrown.
        public var team: (Place) async throws -> Team
        /// One read of the vault's page (`VaultClient.reading`). A read that failed is thrown.
        public var vault: (Place) async throws -> Vault
        /// Whether this Mac holds an owner key for the fleet of this id that it can use (`OwnerKeychain.isHeld(fleet:)`:
        /// the item's presence answers until the run's first look, off the caller's actor, ends).
        public var holdsKey: (String) -> Bool
        /// The form of a server's name that a signed grant can carry (`CentralVault.isMachine`).
        public var isMachine: (String) -> Bool
        /// Whether this Mac's clock and the hub's differ by more than an hour, by the hub's answer to the app's last
        /// read in this launch, for the hub and the database of the place (`VaultPlan.clockProblem` with the hub's
        /// time of that answer and this Mac's time of it: the rule of the app's own controls that sign). nil when the
        /// app has no such answer: none in this launch yet (a kept reading gives no clock), or a reading that moved
        /// to another hub or database; the tool then answers "not ready". A give asks it last, and waits while it is
        /// true or nil; a take-back does not ask it.
        public var clockApart: (Place) -> Bool?
        /// **Makes one statement, signs it with the owner key of this Mac and sends it** (`GrantSigning` in the
        /// app, `POST /ui/vault/grant`). It throws `NotSigned` when the key could not be read or made no
        /// signature: nothing was sent then. An error of the send itself is a `HubFailure`.
        public var sign: (Place, Statement) async throws -> Void
        /// The hub's grant of the secret to the agent at a level, or its end for nil (`SecretsClient.grant`,
        /// `POST /ui/secrets/grant`).
        public var grant: (Place, String, String, Level?) async throws -> Receipt
        /// The app reads the fleet again (`FleetStore.refresh`), started and not waited for.
        public var refresh: () async -> Void

        public init(ready: @escaping () -> Place?, signs: @escaping (Place) -> Bool?,
                    team: @escaping (Place) async throws -> Team, vault: @escaping (Place) async throws -> Vault,
                    holdsKey: @escaping (String) -> Bool, isMachine: @escaping (String) -> Bool,
                    clockApart: @escaping (Place) -> Bool?, sign: @escaping (Place, Statement) async throws -> Void,
                    grant: @escaping (Place, String, String, Level?) async throws -> Receipt,
                    refresh: @escaping () async -> Void) {
            self.ready = ready
            self.signs = signs
            self.team = team
            self.vault = vault
            self.holdsKey = holdsKey
            self.isMachine = isMachine
            self.clockApart = clockApart
            self.sign = sign
            self.grant = grant
            self.refresh = refresh
        }
    }

    /// **The one line of writes of the tools that write grants**: `grant_secret` and `answer_secret_request`
    /// (`AnswerSecret`). One object for the two tools, which lives as long as the board (`LinkTools.add` makes it
    /// and gives it to both).
    ///
    /// **One call writes at a time.** Two calls whose writes cross can end with a grant in the list whose signature
    /// the other call ended, and both tools write grants. So while the writes of one call run, another call of
    /// either tool gets `busy`, and sends nothing.
    ///
    /// **The writes are not the call's.** A call of the link is one connection, and the listener cancels the call's
    /// task when the connection ends (`ChannelListener`). A cancel that reached a request of the app's clients
    /// would end it, and the write after it would not be sent: a give would leave a signature with no grant, and a
    /// take-back an ended grant with its signature. So the writes run in a task of this object's own, which is no
    /// child of the call's task and takes no cancel from it, and the call only waits for that task's end. No line
    /// of this file cancels it. The wait has no clock: it ends when the writes end, and each of them ends by the
    /// time limit of its own request.
    @MainActor
    public final class Line {
        /// Whether the writes of a call run now.
        public private(set) var busy = false

        public init() {}

        /// Starts the writes of one call in a task of the line's own, or gives nil while another call's writes
        /// run. It has no `await`: the look and the start are one step on the main actor.
        func begin(_ writes: @escaping @MainActor () async -> OwnerChannel.Answer) -> Task<OwnerChannel.Answer, Never>? {
            guard !busy else { return nil }
            busy = true
            return Task { @MainActor in
                let answer = await writes()
                self.busy = false
                return answer
            }
        }
    }

    // ------------------------------------------------------------ the answer to one call

    /// **The app's answer to one call**, in a fixed order. The app trusts nothing of the program's checks: it
    /// makes each of them itself.
    ///
    /// 1. The fields, each in its form (`read`). No part after the request line.
    /// 2. A current reading of the fleet, with a hub that serves the Secrets page (`Desk.ready`).
    /// 3. The hub lists `signed_grants` (`Desk.signs`). A reading that moved is "not ready".
    /// 4. One read of the fleet's list and one read of the vault's page. Then, each with its own sentence: the
    ///    page names the fleet; the hub has a reading of a central vault; the hub's newest read of that vault
    ///    did not fail (`Vault.Central.of`); this Mac holds the fleet's owner key. Then, **for a give only**: the
    ///    list has the secret; the fleet has the agent; the agent is a worker or a lead; the hub names a server
    ///    for it; `read` only for an API key; no second key of one variable name read by one agent; and the hub
    ///    answered the app in this launch, and its clock and this Mac's do not differ by more than an hour
    ///    (`Desk.clockApart`: with no such answer, "not ready"). **A
    ///    take-back makes none of the checks of a give but one**: an end goes for whatever the list has, and the
    ///    hub answers in its own words for an agent or a secret that it does not know. The one check is the
    ///    door's name, which is refused in a give and in a take-back with the words for an agent that the fleet
    ///    does not have: the hub would read that name as the door's own grant, and the door is never a holder of
    ///    this tool.
    /// 5. No other call of the tool is at its writes (`Line`).
    /// 6. The call still has its caller: a call whose connection ended sends nothing.
    /// 7. The writes, in a task of the line's own. **A give**: the signed `grant` for the server of step 4, and
    ///    then the hub's grant. **A take-back**: the hub's end of the grant, and then the signed `ungrant`.
    /// 8. From the first write on, the call goes to its end also when its caller went away.
    ///
    /// **No `await` stands between the look of step 5, the look of step 6 and the start of the writes.**
    ///
    /// **When the hub refuses the grant of a give after the vault took the signature**, the app reads the list one
    /// time more and decides by that read alone, never by the read of step 4: between the two, the owner's own
    /// Give in the app can have made the grant, and an `ungrant` would then end the signature that a real grant
    /// needs. No grant of this secret for this agent in that read: the app signs the `ungrant` and sends it, so
    /// that the vault's signed grants do not stay wider than the list. A grant there, at any level: no `ungrant`.
    /// A read that failed: no `ungrant`, and the words say what can be left.
    ///
    /// **The answer** of a call whose writes all went: `login`, `agent`, `level`, `signed` true, `server` (a give:
    /// the server that the grant was signed for), `changed` (the hub's receipt), `vault` (the agent's vault access
    /// when the receipt has it: `before`, `after`, and `missing` as the hub's own codes) and `note`. Then the app
    /// reads the fleet again, started and not waited for.
    @MainActor
    public static func answer<Place>(fields: [String: JSONValue], value: OwnerChannel.Value?, desk: Desk<Place>,
                                     line: Line) async -> OwnerChannel.Answer {
        // 1. The fields.
        guard value == nil else { return .refused(noPart) }
        let read: Read
        switch Self.read(fields) {
        case .failure(let refusal): return .refused(refusal.text)
        case .success(let taken): read = taken
        }
        // 2. A current reading.
        guard let place = desk.ready() else { return .refused(notReady) }
        // 3. Signed grants.
        guard let signs = desk.signs(place) else { return .refused(notReady) }
        guard signs else { return .refused(noSignedGrants) }
        // 4. The two reads, and what they must show.
        let team: Team, vault: Vault
        do { team = try await desk.team(place) } catch { return .refused(teamUnread) }
        do { vault = try await desk.vault(place) } catch { return .refused(vaultUnread) }
        guard let fleet = vault.fleet else { return .refused(noFleet) }
        switch vault.central {
        case .noReading: return .refused(noVaultReading)
        case .silent: return .refused(vaultSilent)
        case .answers: break
        }
        guard desk.holdsKey(fleet) else { return .refused(read.level == nil ? noOwnerKeyTakeBack : noOwnerKey) }
        let server: String?
        if let level = read.level {
            guard let secret = team.secrets[read.login] else { return .refused(noSecret) }
            guard read.agent != door, let agent = team.agents[read.agent] else { return .refused(noAgent) }
            guard holderRoles.contains(agent.role) else { return .refused(notWorker) }
            guard let machine = agent.machine, desk.isMachine(machine) else { return .refused(noServer) }
            if level == .read {
                guard secret.apiKey else { return .refused(readNeedsKey) }
                guard !team.readsTwice(read.login, agent: read.agent) else { return .refused(readsTwice) }
            }
            guard let apart = desk.clockApart(place) else { return .refused(notReady) }
            guard !apart else { return .refused(clockApart) }
            server = machine
        } else {
            guard read.agent != door else { return .refused(noAgent) }
            server = nil
        }
        // 5 and 6, and then the start of the writes, with no `await` between the three.
        guard !line.busy else { return .refused(busy) }
        if Task.isCancelled { return .refused(ended) }
        let writes = line.begin {
            if let level = read.level, let server {
                return await give(read, level, fleet: fleet, server: server, place: place, desk: desk)
            }
            return await takeBack(read, fleet: fleet, place: place, desk: desk)
        }
        // The line was free one line above, so this is a line that nothing reaches.
        guard let writes else { return .refused(busy) }
        // 8. The wait for the writes' end takes no cancel: the call goes on to its end without its caller.
        return await writes.value
    }

    /// How one write ended, as the tool reads it: the hub took it; the hub refused it for certain, with its status
    /// (under 500) and its words; the app made no signature, so nothing was sent; or the outcome is not known.
    /// `share_secret` (`ShareSecret`) reads its writes by the same rule.
    enum Sent<Taken: Sendable> {
        case took(Taken)
        case refused(Int, String)
        case notSigned
        case notKnown
    }

    @MainActor
    static func sent<Taken: Sendable>(_ send: () async throws -> Taken) async -> Sent<Taken> {
        do {
            return .took(try await send())
        } catch SaveBotToken.HubFailure.refused(let status, let said) where status < 500 {
            return .refused(status, said)
        } catch is NotSigned {
            return .notSigned
        } catch {
            return .notKnown
        }
    }

    /// **How one give ended**, as the two tools that give read it (`grant_secret`, and `answer_secret_request` for
    /// each agent of its `give`). Each tool maps an end to its own words. The cases with a status carry the hub's
    /// own status (under 500) and its own words.
    enum GiveEnd: Equatable, Sendable {
        /// The vault took the signed grant, and the hub took its grant: the hub's receipt.
        case given(Receipt)
        /// This Mac holds the key, and the app could not sign with it now. Nothing was sent.
        case notSignedNow
        /// The signed grant, a certain refusal: the vault kept nothing, and the list was not asked.
        case signRefused(Int, String)
        /// The signed grant, no known outcome. The list was not asked.
        case signNotKnown
        /// The signed grant taken, the hub's grant with no known outcome.
        case grantNotKnown
        /// The hub's grant refused, the list read again with no grant, and the signed end taken.
        case refusedTakenBack(Int, String)
        /// The same, when the signed end did not go.
        case refusedSignatureLeft(Int, String)
        /// The hub's grant refused, and the list read again has a grant of this secret for this agent.
        case refusedListHasOne(Int, String)
        /// The hub's grant refused, and the list could not be read again.
        case refusedListUnread(Int, String)
    }

    /// **The writes of one give**, for both tools: the signed `grant`, then the hub's grant, and after a certain
    /// refusal of that grant one more read of the list and, only when it shows no grant, the signed `ungrant`.
    /// `sign` makes, signs and sends one statement; `grant` is the hub's grant at the give's level; `holds` reads the
    /// list one time and says whether it has a grant of this secret for this holder now, at any level. Each is a
    /// closure of the calling tool's own desk.
    @MainActor
    static func give(login: String, agent: String, fleet: String, server: String,
                     sign: (Statement) async throws -> Void, grant: () async throws -> Receipt,
                     holds: () async throws -> Bool) async -> GiveEnd {
        let statement = Statement(fleet: fleet, login: login, agent: agent, machine: server)
        switch await sent({ try await sign(statement) }) {
        case .took: break
        // The caller's check said that this Mac holds the key: the words do not say that it holds none.
        case .notSigned: return .notSignedNow
        case .refused(let status, let said): return .signRefused(status, said)
        case .notKnown: return .signNotKnown
        }
        switch await sent({ try await grant() }) {
        case .took(let receipt):
            return .given(receipt)
        case .notSigned, .notKnown:
            return .grantNotKnown
        case .refused(let status, let said):
            // The list as it is now, and never as the call's first read had it.
            guard let held = try? await holds() else { return .refusedListUnread(status, said) }
            guard !held else { return .refusedListHasOne(status, said) }
            let end = Statement(fleet: fleet, login: login, agent: agent, machine: nil)
            guard case .took = await sent({ try await sign(end) }) else { return .refusedSignatureLeft(status, said) }
            return .refusedTakenBack(status, said)
        }
    }

    /// **The writes of a give of this tool** (`give(login:agent:fleet:server:sign:grant:holds:)`), and this tool's
    /// words for each end.
    @MainActor
    private static func give<Place>(_ read: Read, _ level: Level, fleet: String, server: String, place: Place,
                                    desk: Desk<Place>) async -> OwnerChannel.Answer {
        let end = await give(login: read.login, agent: read.agent, fleet: fleet, server: server,
                             sign: { try await desk.sign(place, $0) },
                             grant: { try await desk.grant(place, read.login, read.agent, level) },
                             holds: { try await desk.team(place).holds(read.login, agent: read.agent) })
        switch end {
        case .given(let receipt):
            await desk.refresh()
            return .result(result(read, server: server, receipt))
        case .notSignedNow: return .refused(notSignedNow)
        case .signRefused(let status, let said): return .refused(withHubWords(signRefused, status: status, said))
        case .signNotKnown: return .refused(signNotKnown)
        case .grantNotKnown: return .refused(grantNotKnown)
        case .refusedListUnread(let status, let said):
            return .refused(withHubWords(grantRefusedListUnread, status: status, said))
        case .refusedListHasOne(let status, let said):
            return .refused(withHubWords(grantRefusedListHasOne, status: status, said))
        case .refusedSignatureLeft(let status, let said):
            return .refused(withHubWords(grantRefusedSignatureLeft, status: status, said))
        case .refusedTakenBack(let status, let said):
            return .refused(withHubWords(grantRefusedTakenBack, status: status, said))
        }
    }

    /// **The writes of a take-back**: the hub's end of the grant, then the signed `ungrant`. After the hub's end
    /// the list changed, so the app reads the fleet again also when the signed end did not go.
    @MainActor
    private static func takeBack<Place>(_ read: Read, fleet: String, place: Place,
                                        desk: Desk<Place>) async -> OwnerChannel.Answer {
        let receipt: Receipt
        switch await sent({ try await desk.grant(place, read.login, read.agent, nil) }) {
        case .took(let taken): receipt = taken
        case .refused(let status, let said): return .refused(withHubWords(endRefused, status: status, said))
        case .notSigned, .notKnown: return .refused(endNotKnown)
        }
        let end = Statement(fleet: fleet, login: read.login, agent: read.agent, machine: nil)
        let signed = await sent { try await desk.sign(place, end) }
        await desk.refresh()
        switch signed {
        case .took: return .result(result(read, server: nil, receipt))
        case .refused(let status, let said): return .refused(withHubWords(ungrantFailed, status: status, said))
        case .notSigned, .notKnown: return .refused(ungrantFailed)
        }
    }

    /// **A code of the hub as an answer gives it**: 1 to 40 characters of a-z, 0-9 and "_", else nil. The hub's
    /// words for an agent's vault access (`none`, `broker`) and its codes of what is missing have this form, and a
    /// text of another form is no code: it is left out, so that no free text of the hub is in a result.
    static func code(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        let fits = (1...40).contains(bytes.count) && bytes.allSatisfy {
            (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F
        }
        return fits ? text : nil
    }

    /// The answer of a call whose writes all went.
    static func result(_ read: Read, server: String?, _ receipt: Receipt) -> JSONValue {
        var answer: [String: JSONValue] = [
            "login": .string(read.login), "agent": .string(read.agent),
            "level": read.level.map { JSONValue.string($0.rawValue) } ?? .null, "signed": .bool(true),
            "changed": .bool(receipt.changed), "note": .string(note(read.level, receipt)),
        ]
        if let server { answer["server"] = .string(server) }
        if let access = receipt.access {
            var vault: [String: JSONValue] = ["before": code(access.before).map(JSONValue.string) ?? .null,
                                              "after": code(access.after).map(JSONValue.string) ?? .null]
            if let missing = access.missing { vault["missing"] = .array(missing.compactMap(code).map(JSONValue.string)) }
            answer["vault"] = .object(vault)
        }
        return .object(answer)
    }

    /// **The note of an answer**, of fixed sentences. For a give: that the list had the grant already, when the
    /// hub changed nothing; then what the Secrets page's own note says (`SecretsPage.note`: the agent uses its
    /// server's vault now; or it has the secret and no vault access yet; or, with no word of the hub about its
    /// vault, a changed `read` grant is in its sessions from their next start); then when the value reaches the
    /// server. For a take-back: what ended.
    static func note(_ level: Level?, _ receipt: Receipt) -> String {
        guard let level else { return receipt.changed ? noteTakenBack : noteNoGrant }
        var sentences: [String] = receipt.changed ? [] : [noteSame]
        if let access = receipt.access {
            sentences.append(access.after == "broker" ? noteVaultOn : noteNoVaultAccess)
        } else if level == .read && receipt.changed {
            sentences.append(noteReads)
        }
        sentences.append(noteDelivery)
        return sentences.joined(separator: " ")
    }
}
