import Foundation

/// **`share_secret`: who may give one secret of the fleet, with the owner's signature, or its end** (the owner, 16
/// November 2026, to "the pool's signed tool next (who may give a secret)": "Yes, build it"). It does what "Who may
/// give it" on the app's Secrets page does (`SecretsPage.saveStanding`): the app signs the owner's statement that puts
/// the secret into the grantable pool with the owner key of this Mac and sends it to the central vault through the
/// hub (`POST /ui/vault/grant`), and the hub writes the owner's standing for the secret (`POST /ui/resources`): the
/// fleet manager may then give the secret itself to any worker or lead, at most at `max`. With `max` null the hub ends
/// the standing first, and the app then signs the statement that takes the secret out of the pool.
///
/// **Why the app signs.** On a fleet with a central vault, the vault seals a secret's value for a server only for a
/// grant that the owner signed for an agent on that server, or for a secret that the owner signed into the grantable
/// pool (`vault.py` `sealable`). A give of the fleet manager is a grant in the fleet's list with no signature, so it
/// brings a value to a server only for a secret of that pool, or to a server for which the owner signed a grant of
/// that secret. `share_resource` of both programs writes the standing with no signature.
///
/// **No question to the owner** (the owner, 15 November 2026, to "Should every change that your agent makes the app
/// sign need your touch (Touch ID)?": "No touch"). So a program that runs as the owner's user on this Mac can make the
/// app sign any secret of the list into the pool (`OWNER-MCP-BOUNDARY.md`, section 7b).
///
/// **The order keeps the vault the narrower of the two**, as the app's own control keeps it (`GrantSigning` in the
/// app): a standing signs first and writes the hub second; a take-back ends the hub's standing first and the pool
/// statement second. When the hub refuses the standing, the app reads the fleet's resources again and takes its pool
/// statement back when that read shows no standing for the secret. A 409 of the standing is decided by that read
/// too, by the app's own rule for a conflict (`HubError.conflict`): only a base that moved was the stale one, and
/// the standing goes one time more only when this secret's standing did not change with it.
///
/// **It reuses `grant_secret`'s parts where the meaning is the same** (`GrantSecret`): the fleet's list, the vault's
/// page and its rule (`Vault.Central.of`), the form of a reference and its sentence, the levels, the error of a key
/// that made no signature, the line of writes (an instance of its own), the reading of a write's end (`sent`) and the
/// bound of the hub's words (`withHubWords`). The tool has no value part: it moves no secret's value, and no answer
/// has one. The app's side is `LinkTools.shareDesk`, closure by closure.
public enum ShareSecret {
    public static let name = "share_secret"
    public static let fields = ["login", "max"]

    /// The levels of a standing for a secret (`hub.py` `RESOURCE_LEVELS["secret"]`): the two levels of a grant.
    public typealias Level = GrantSecret.Level
    /// The fleet's list as one read gives it (`GET /ui/team`).
    public typealias Team = GrantSecret.Team
    /// The vault's page as one read gives it (`GET /ui/vault`), with its rule for the central vault.
    public typealias Vault = GrantSecret.Vault
    /// The one error of the signing closure that says "not signed, and nothing was sent".
    public typealias NotSigned = GrantSecret.NotSigned
    /// The tool's one line of writes: `grant_secret`'s type, with an instance of the tool's own, so that one call of
    /// THIS tool writes at a time. The owner's own controls and `grant_secret` are not in its line.
    public typealias Line = GrantSecret.Line

    /// The one audience of a standing that the hub keeps: every worker and lead (`hub.py` `RESOURCE_AUDIENCE`;
    /// `ResourceList.everyone` in FleetCore, which this library does not link; a test holds the two equal).
    public static let audience = "workers"

    /// The id of a secret among the fleet's resources (`hub.py` `resource_ids`): `secret:` and its reference.
    public static func resourceID(_ login: String) -> String { "secret:" + login }

    public static let tool = OwnerTable.Tool(
        name: name, description: """
            Access: Sets who may give one secret of the fleet, with the owner's signature, as Who may give it on \
            the \
            Founderizer app's Secrets page does. On a fleet with a central vault, the vault sends a secret's value \
            to a server only for a grant that the owner's key signed, or for a secret that the owner's key signed \
            into the grantable pool. A give of the fleet manager has no signature: it brings the value to a server \
            only for a secret of that pool, or to a server for which the owner signed a grant of that secret. This \
            tool makes the Founderizer app sign the secret into the pool with \
            the owner's key on this Mac and send it, and then the hub writes the standing: the fleet manager may then \
            give the secret itself to any worker or lead, at most at max. login: the secret's reference as \
            fleet_read(page="team") gives it under logins: bws:// and a UUID in lower case, with no secret: before \
            it. max: use, read or null, and it must be given. use lets the manager give the secret for use: an agent \
            uses it and never sees it. read is only for an API key: an agent that the manager gives it to at read \
            has the key's value in its sessions as a variable, so set read only when the owner asked for it. null \
            makes the owner the only one who gives the secret again: the hub ends the standing first, and the app \
            then ends the owner's signed pool statement. The grants that the manager gave from the standing stay in \
            the fleet's list, and the central vault takes its copy back from each server for which the owner signed \
            no grant of the secret, where that server's vault takes withdrawals, at the first pass of the hub at \
            which that server takes part: a server that is off or not pinned keeps its copy until then. When the hub \
            refuses the standing, the app reads the fleet's resources again and takes its pool statement back when \
            the hub has no standing for this secret. Only the Mac that set up Founderizer Vault holds the owner's \
            key and can sign. On a hub that takes no signed pool statement, the tool sends nothing: share_resource \
            sets who may give a secret there. While the hub has no reading of a central vault, the tool sends \
            nothing too: the fleet has none, or the hub has not read it since it started, and only on a fleet that \
            has none does share_resource set a standing for a secret in this tool's place. It answers login, max, to \
            (workers, for a \
            standing), signed true, changed (whether the hub changed its standing) and note. After a standing, when \
            the central vault holds the value, it sends it to the server of each worker or lead that the fleet's \
            list gives the secret to, now and after each give of the fleet manager, where that server's vault takes \
            deliveries, at the hub's next pass, usually within a minute (a delivery that failed waits up to six \
            hours before the next try). One call writes at a time: a call that comes while another one is at its \
            writes is refused. No answer has a secret's value.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "login": .object(["type": .string("string")]),
                "max": .object(["type": .array([.string("string"), .string("null")]),
                                "enum": .array([.string("use"), .string("read"), .null])]),
            ]),
            "required": .array([.string("login"), .string("max")]),
            "additionalProperties": .bool(false),
        ]),
        annotations: .object(["readOnlyHint": .bool(false)]), kind: .swift, route: "", fields: [], what: name,
        revisionPage: nil, requestIDFromArguments: false, feature: nil)

    // ------------------------------------------------------------ the fixed sentences

    // Each names only the tool's own fields, and none quotes anything that the caller sent: not a reference and not
    // a level. The one part that is not fixed is the hub's own words after a certain refusal of the hub
    // (`GrantSecret.withHubWords`), which come after the tool's own sentence. A sentence says "Nothing was sent."
    // exactly when the app sent no write, and none says "signed" for a call that signed nothing. No sentence says
    // that an agent can read a login: a login is used and never seen. The sentences that are `grant_secret`'s own
    // words, for the same fact and with no tool's name in them, are its sentences.

    static let only = "share_secret takes only login and max. Nothing was sent."
    static let noPart = "share_secret takes no part after its request line. Nothing was sent."
    /// The form of a reference, in `grant_secret`'s own words.
    static let loginWord = GrantSecret.loginWord
    /// A call with no `max` is never a take-back: a field that was forgotten ends no standing.
    static let needsMax = "share_secret needs max: use, read, or null so that only the owner gives the secret again. "
        + "A call with no max ends no standing. Nothing was sent."
    static let maxWord = "max must be use, read or null: the most that the fleet manager may give, with read only for "
        + "an API key, or null so that only the owner gives the secret again. Nothing was sent."

    static let notReady = "The Founderizer app's reading of the fleet is not current now, or the app has no fleet. "
        + "Call share_secret again in a moment. Nothing was sent."
    /// The hub that the app shows does not list `resource_grants`: it keeps no standing at all.
    static let noStandings = "This hub keeps no standing for any resource: on it the fleet manager gives nothing "
        + "itself, and only the owner gives a secret. Nothing was sent."
    /// The hub lists `resource_grants` and not `signed_grants`: it passes no signed statement on, and the app's own
    /// control writes the standing there with no signature, as `share_resource` does.
    static let noSignedPool = "This hub takes no signed pool statement, so the app signs nothing for it: "
        + "share_resource sets who may give a secret on such a fleet. Nothing was sent."
    static let teamUnread = "The Founderizer app could not read the fleet's list from the hub. Call share_secret "
        + "again in a moment. Nothing was sent."
    static let resourcesUnread = "The Founderizer app could not read the fleet's resources from the hub. Call "
        + "share_secret again in a moment. Nothing was sent."
    static let vaultUnread = "The Founderizer app could not read the central vault's status from the hub. Call "
        + "share_secret again in a moment. Nothing was sent."
    static let noFleet = "The hub did not say which fleet this is, so the app cannot sign for it. Call share_secret "
        + "again in a moment. Nothing was sent."
    /// The hub's page has no central vault (`central` is null), which is not "this fleet has no central vault"
    /// (`GrantSecret.Vault.Central.of`): the words name `share_resource` only for a fleet that has none, in this
    /// tool's place (`share_resource` sets standings on a fleet with a vault too, where its own check lets it).
    static let noVaultReading = "The hub has no reading of a central vault now: this fleet has none, or the hub has "
        + "not read it since it started. Call share_secret again in a minute. If the same answer comes again, ask "
        + "the owner whether this fleet has Founderizer Vault: only on a fleet that has none does share_resource "
        + "set a standing for a secret in this tool's place. Nothing was sent."
    /// The hub has a reading of the central vault, and its newest read of the vault failed (the page's `error`).
    static let vaultSilent = "The hub's last reading of the central vault failed, so the vault may not answer now. "
        + "Call share_secret again in a minute. Nothing was sent."
    /// In `grant_secret`'s own words.
    static let noOwnerKey = GrantSecret.noOwnerKey
    /// The same fact for a take-back, with the one thing that the caller can still do from this Mac, and what it
    /// leaves behind.
    static let noOwnerKeyTakeBack = "This Mac holds no owner key for this fleet, so the app on it cannot sign: only "
        + "the Mac that set up Founderizer Vault signs. share_resource with no max ends the hub's standing, and the "
        + "owner's signed pool statement then stays in the vault until that Mac ends it: while it stays, the central "
        + "vault can still send the value to the server of each worker or lead that the fleet's list gives the "
        + "secret to. Nothing was sent."
    /// One sentence for a secret that the fleet's list does not have and for one that the hub's resources do not
    /// have: the hub reads both from its `team.json`. In `grant_secret`'s own words.
    static let noSecret = GrantSecret.noSecret
    /// Stricter than the app's page, on purpose, as `grant_secret`: a login is used and never seen.
    static let readNeedsKey = "max read is only for an API key: a login is used and never seen. For a login the only "
        + "max is use: call again with max use only when the owner wants that. Nothing was sent."
    /// As `GrantSecret.clockApart`, for a standing: its pool statement is signed first. A take-back does not wait for
    /// the clocks: its hub step comes first, and an end only narrows.
    static let clockApart = "This Mac's clock and the hub's clock differ by more than an hour, so the app signs no "
        + "pool statement now. Ask the owner to check this Mac's date and time (System Settings, General, Date & "
        + "Time), and then call share_secret again. If this Mac's clock is right, the hub's clock is probably wrong: "
        + "tell the owner. A take-back (max null) does not wait for the clocks. Nothing was sent."
    static let busy = "Another call of share_secret is at its writes now. Call again when it has answered. Nothing "
        + "was sent."
    /// The call's connection ended before its first write. Nobody reads this. In `grant_secret`'s own words.
    static let ended = GrantSecret.ended

    // After a write went out.

    /// **The first write of a standing, when this Mac holds the key and the app could not sign with it** (`NotSigned`
    /// from the desk, after `holdsKey` said yes). Nothing was sent, and the same call later can go.
    static let notSignedNow = "This Mac held an owner key for this fleet a moment ago, and the app could not sign "
        + "with it now: the Mac can be locked, the key can be gone, or macOS did not let the app read it. Nothing "
        + "was sent. Call share_secret again later."
    /// A standing, the signed `pool` statement, a certain refusal: the vault kept nothing, and the hub's standing was
    /// not asked. The hub refuses here a statement for a secret that a model account names (`pool_statement_refusal`).
    static let poolRefused = "The hub refused the owner's signed pool statement, so nothing was changed."
    /// A standing, the signed `pool` statement, no known outcome. The hub's standing was not asked.
    static let poolNotKnown = "Whether the vault took the owner's signed pool statement is not known, and the hub's "
        + "standing was not changed. If the vault took it, then while it stands with no standing the central vault "
        + "can send the value to the server of each worker or lead that the fleet's list gives the secret to. Call "
        + "share_secret again in the same way: a second statement of the same pool is no error, because the vault "
        + "keeps the newer one."
    /// A standing, the statement taken, the hub's standing with no known outcome.
    static let standingNotKnown = "The app signed the secret into the grantable pool with the owner's key, and "
        + "whether the hub wrote the standing is not known. While the signed pool statement stands with no "
        + "standing, the central vault can send the value to the server of each worker or lead that the fleet's list "
        + "gives the secret to. Read fleet_read(page=\"resources\"): if this secret's standing there is not the one "
        + "of this call (no standing, or another max), call share_secret again in the same way."
    /// A standing, the statement taken, a 409 of the hub's standing, and the resources could not be read after it:
    /// the hub did not write the standing, and the next step is the same call again.
    static let standingUnwritten = "The hub refused the standing, and the app could not read the fleet's resources "
        + "after it, so the standing was not written. The owner's signed pool statement is in the vault, and while it "
        + "stands with no standing the central vault can send the value to the server of each worker or lead that "
        + "the fleet's list gives the secret to. Call share_secret again in the same way; call it with max null only "
        + "if the owner no longer wants the standing."
    /// A standing, the statement taken, a 409 of the hub's standing, and the read after it shows that this secret's
    /// standing changed while the call ran (the owner's own control can have changed it): the app sends no standing
    /// again, and it decides by that read. It comes before the sentence of what the app decided.
    static let standingChanged = "The hub's standing for this secret changed while this call ran, so the app did not "
        + "send its standing again."
    /// The last sentence of a standing whose standing changed while the call ran: the owner's own control can have
    /// changed it, and a new call would read that change as the first read and write over it.
    static let askOwnerFirst = "Before any further call of share_secret for this secret, read "
        + "fleet_read(page=\"resources\") and ask the owner which standing they want."
    /// The last sentence of the same case when the refusal names its own step, the end of the statement that the
    /// call left: that end needs no question, and a standing after it does, because the standing that ended can be
    /// the owner's own newer click.
    static let askOwnerAfterEnd = "After that, send no standing for this secret again before you asked the owner "
        + "which standing they want."
    /// A standing, the statement taken, the hub's standing refused, the resources read again with no standing for
    /// this secret, and the signed `unpool` taken. It does not say "nothing is changed": a pass of the hub can have
    /// delivered the value between the `pool` and the `unpool` (`signed_receipt` calls `central_due`).
    static let standingRefusedTakenBack = "The hub refused the standing, and the app took the owner's signed pool "
        + "statement back: the hub has no standing for this secret, and the secret is out of the grantable pool. If "
        + "the central vault sent the value to a server while the statement stood, it takes it back from each server "
        + "for which the owner signed no grant of it, where that server's vault takes withdrawals, at the first pass "
        + "of the hub at which that server takes part (its vault reports to the hub, and the owner's pin is its "
        + "vault's key)."
    /// The same, when the signed `unpool` did not go, or whether it went is not known. The words send the caller to
    /// the resources first, as `standingRefusedUnread` does.
    static let standingRefusedStatementLeft = "The hub refused the standing, and the app could not take the owner's "
        + "signed pool statement back: it can stay in the vault with no standing in the hub, and while it stays the "
        + "central vault can send the value to the server of each worker or lead that the fleet's list gives the "
        + "secret to. Read fleet_read(page=\"resources\"). If this secret has no standing there, call share_secret "
        + "with max null to end the signed pool statement. If it has one, change nothing: the signed pool statement "
        + "stands for it."
    /// The same refusal, when the resources read again have a standing for this secret, at any level: the owner's
    /// own control can have written it since the call's first read, and the pool statement is the one that it needs.
    static let standingRefusedHubHasOne = "The hub refused this call. The hub has a standing for this secret, which "
        + "stays as it is, and the owner's signed pool statement stands for it."
    /// The same refusal, when the resources could not be read again: nothing says whether the pool statement has its
    /// standing. The words send the caller to the resources first.
    static let standingRefusedUnread = "The hub refused the standing. The app signed the secret into the grantable "
        + "pool before that and could not read the fleet's resources after it. Read fleet_read(page=\"resources\"). If "
        + "this secret has no standing there, call share_secret with max null to end the signed pool statement. If it "
        + "has one, change nothing: the signed pool statement stands for it."
    /// A take-back, the hub's end, a certain refusal (a 409 whose read after it shows the same base among them): the
    /// pool statement was not asked to end.
    static let endRefused = "The hub refused the end of the standing, so nothing was changed."
    /// A take-back, the hub's end, a 409, and the resources could not be read after it: no second send.
    static let endUnread = "The hub refused the end of the standing, and the app could not read the fleet's resources "
        + "after it. This call changed nothing: it did not change the hub's standing, and it did not touch the "
        + "owner's signed pool statement. Call share_secret again."
    /// A take-back, the hub's end, a 409, and the read after it shows a standing for this secret that is not the one
    /// of the call's first read (another level, or one where there was none; the owner's own control can have set
    /// it): no second send, and the owner decides. A standing that ended meanwhile is no such case: the call goes on
    /// to the signed end.
    static let endChanged = "The hub's standing for this secret changed while this call ran, so the app sent no end of "
        + "it again: this call changed nothing, and it did not touch the owner's signed pool statement. Read "
        + "fleet_read(page=\"resources\") and ask the owner which standing they want."
    /// A take-back, the hub's end, a 409, one more send with the base of the read after it, and a second 409.
    static let endMoved = "The hub refused the end of the standing, and the app could not end it in one more try "
        + "either. This call changed nothing: it did not change the hub's standing, and it did not touch the owner's "
        + "signed pool statement. Call share_secret again."
    /// A take-back, the hub's end, no known outcome.
    static let endNotKnown = "Whether the hub ended the standing is not known, and the owner's signed pool statement "
        + "is not ended. Call share_secret again in the same way."
    /// A take-back, the hub's end taken (a change, or no change for a hub with no standing), and the signed `unpool`
    /// did not go, with a refusal or with no known outcome.
    static let unpoolFailed = "The hub has no standing for this secret now, so only the owner gives it. The vault did "
        + "not take the end of the owner's signed pool statement, or whether it did is not known: a pool statement of "
        + "this secret can stay there, and while it stays the central vault can still send the value to the server "
        + "of each worker or lead that the fleet's list gives the secret to. Call share_secret with max null again to "
        + "end it: the hub's end is then no change, and the end of the statement is sent again."

    /// The program's words when its request went out and no answer came back (the app did not answer in time, or the
    /// link ended): the app may have signed, and it may have written the standing. The page `resources` of
    /// `fleet_read` has the hub's standing, and its page `vault` the central vault's pool as the hub last read it.
    public static let notKnownHere = "The Founderizer app did not answer in time, or the link ended, so what the app "
        + "signed and wrote for this call is not known. Call share_secret again in the same way: that is safe for a "
        + "standing and for a take-back, and the app then signs the pool statement or its end again. fleet_read with "
        + "the pages resources and vault shows the hub's standing and the signed pool as the hub last read it "
        + "(central.pool), which can be a minute old."

    // The notes of an answer, as fixed English sentences.

    /// A standing that the hub had already: the repair of a standing with no signature.
    static let noteSame = "The hub had this standing already, so it changed nothing, and the owner's signed pool "
        + "statement is in the vault now."
    /// The standing changes no grant (`hub.py` `save_resource`), so each note of a standing says so.
    static let noteUse = "The fleet manager may now give the secret itself to any worker or lead, at most at use. The "
        + "grants in the fleet's list do not change with the standing."
    static let noteRead = "The fleet manager may now give the secret itself to any worker or lead, at most at read: "
        + "the key's value then goes into the sessions of each agent that the manager gives it to at read. The grants "
        + "in the fleet's list do not change with the standing."
    /// The hub tells the manager of each standing that changed (`hub.py` `save_resource`).
    static let noteTold = "The hub told the fleet manager that the standing changed."
    /// The hub's reconciler delivers a secret of the pool to the server of each worker or lead that holds it in the
    /// list, where that server takes part, and only a reference that the central vault has (`hub.py`
    /// `central_plan`, `deposit_machines`); a delivery that failed waits `CENTRAL_RETRY`.
    static let noteDelivery = "When the central vault holds the value, it sends it to the server of each worker or "
        + "lead that the fleet's list gives the secret to, now and after each give of the fleet manager, where that "
        + "server's vault takes deliveries, at the hub's next pass (usually within a minute; a delivery that failed "
        + "waits up to six hours before the next try)."
    /// After the `unpool`, a copy goes back from a server for which the owner signed no grant of the secret, where
    /// its vault takes withdrawals, and only a copy of a value that the central vault holds (`central_plan`,
    /// `can_withdraw`). A pass skips a server that does not take part then (no carrier that reports its vault, or a
    /// pin that is not its broker's key), so such a server keeps its copy until the first pass at which it takes part.
    static let noteTakenBack = "The hub ended the standing, so only the owner gives this secret now, and the app "
        + "ended the owner's signed pool statement. The grants that the fleet manager gave from it stay in the "
        + "fleet's list. " + copyBack
    /// The end of a copy, as each note of a take-back says it: the sentence, and its words after "takes its copy
    /// back" for a note that begins the sentence with a condition.
    static let copyBackFrom = "from each server for which the owner signed no grant of it, where that server's vault "
        + "takes withdrawals, at the first pass of the hub at which that server takes part (its vault reports to the "
        + "hub, and the owner's pin is its vault's key): a server that is off or not pinned keeps its copy until then, "
        + "and a withdrawal that failed waits up to six hours before the next try."
    static let copyBack = "The central vault takes its copy back " + copyBackFrom
    /// A take-back whose read after a 409 shows that another writer ended the standing while the call ran: the app
    /// sent no end of it, and it ended the pool statement.
    static let noteEndedMeanwhile = "The hub's standing for this secret ended while this call ran, so the app sent no "
        + "end of it again, and it sent the end of the owner's signed pool statement to the vault. If the secret was in "
        + "the pool, the central vault takes its copy back " + copyBackFrom
    static let noteNoStanding = "The hub had no standing for this secret, so it changed nothing, and the app sent the "
        + "end of the owner's signed pool statement to the vault. If the secret was in the pool, the central vault "
        + "takes its copy back " + copyBackFrom

    // ------------------------------------------------------------ the fields, on both sides

    /// One call, as the tool reads it. `max` nil is a take-back.
    struct Read: Equatable {
        let login: String
        let max: Level?
    }

    /// **The checks of the fields, in a fixed order**, the same in the program and in the app: a field named like a
    /// value, a field that the tool does not take (`to` among them: the hub keeps one audience), `login`, and then
    /// `max`. A `max` that is absent is refused, and only a JSON null is a take-back.
    static func read(_ fields: [String: JSONValue]) -> Result<Read, OwnerChannel.Refusal> {
        if fields.keys.contains(where: OwnerLinkTools.namedLikeAValue) {
            return .failure(.init(OwnerLinkTools.neverAField))
        }
        guard fields.keys.allSatisfy({ Self.fields.contains($0) }) else { return .failure(.init(only)) }
        guard case .string(let login)? = fields["login"], GrantSecret.isReference(login) else {
            return .failure(.init(loginWord))
        }
        switch fields["max"] {
        case nil:
            return .failure(.init(needsMax))
        case .null?:
            return .success(Read(login: login, max: nil))
        case .string(let word)?:
            guard let max = Level(rawValue: word) else { return .failure(.init(maxWord)) }
            return .success(Read(login: login, max: max))
        default:
            return .failure(.init(maxWord))
        }
    }

    // ------------------------------------------------------------ the program's side

    /// **What the program sends to the app**: the two fields as the read took them, with `max` as a JSON null for a
    /// take-back. The program reads no file and not its standard input for this tool.
    public static func plan(_ fields: [String: JSONValue]) -> Result<[String: JSONValue], OwnerChannel.Refusal> {
        read(fields).map { read in
            ["login": .string(read.login), "max": read.max.map { JSONValue.string($0.rawValue) } ?? .null]
        }
    }

    // ------------------------------------------------------------ the app's side

    /// **What the hub that the app shows lists** of the two features that the tool needs, from the features of the
    /// store (`LinkTools.features(of:at:)`).
    public struct Features: Equatable, Sendable {
        /// `signed_grants`: the hub passes the owner's signed statements on to the central vault, the pool's too.
        public let signs: Bool
        /// `resource_grants`: the hub keeps the owner's standing of each resource (`GET` and `POST /ui/resources`).
        public let standings: Bool

        public init(signs: Bool, standings: Bool) {
            self.signs = signs
            self.standings = standings
        }
    }

    /// **The fleet's resources as one read gives them** (`GET /ui/resources`): the base that a standing goes against,
    /// and each resource's standing now.
    public struct Resources: Equatable, Sendable {
        /// The SHA-256 of the hub's `team.json` that this read has: a standing's write goes against it.
        public let sha256: String
        /// The ids of the page's resources (`secret:<reference>` for each secret of the catalog).
        public let ids: Set<String>
        /// The level of each resource's standing now (the page's `grant.max`), by the resource's id: a resource with
        /// no entry has no standing, and only the owner gives it.
        public let standings: [String: String]

        public init(sha256: String, ids: Set<String>, standings: [String: String] = [:]) {
            self.sha256 = sha256
            self.ids = ids
            self.standings = standings
        }

        /// The level of this secret's standing in this read, or nil for none.
        func standing(of login: String) -> String? { standings[ShareSecret.resourceID(login)] }
    }

    /// **One statement for the app to make, sign and send**: the owner's `pool` of the secret (the fleet manager may
    /// give it), or its `unpool` (only the owner gives it).
    public struct Statement: Equatable, Sendable {
        public let fleet: String
        public let login: String
        public let inPool: Bool

        public init(fleet: String, login: String, inPool: Bool) {
            self.fleet = fleet
            self.login = login
            self.inPool = inPool
        }
    }

    /// **The app's engine for the tool**, as closures, so that a test gives stand-ins: the library does not link
    /// FleetCore, and no test reads a Keychain or reaches a hub. `Place` is the hub, the database and the
    /// installation that one call reads and sends with.
    ///
    /// **Each closure that asks the hub must end** by the time limit of the request that it makes: the writes of a
    /// call run to their end also after the call's caller went away, and the tool takes no other call's writes while
    /// they run (`Line`).
    ///
    /// **A failure of `sign` or of `standing` is thrown as `SaveBotToken.HubFailure`** (`LinkTools.failure`): a
    /// refusal carries only the hub's own status and its own words. A status under 500 is a certain refusal; no
    /// answer, an answer that could not be read, a status of 500 or more and every other error count as "not known".
    /// A read that failed is a read that failed, whatever it throws.
    @MainActor
    public struct Desk<Place: Sendable> {
        /// The hub, its database and the installation when the app's reading is current, has a database, and the
        /// hub serves the Secrets page with its grants (as `grant_secret`'s), else nil.
        public var ready: () -> Place?
        /// The two features, from the features of the hub that the app still shows (`LinkTools.features(of:at:)`).
        /// nil says one thing only: the app's reading moved to another hub or database, which is "not ready" and
        /// never "not listed".
        public var features: (Place) -> Features?
        /// One read of the fleet's list (`HubClient.team`). A read that failed, and a page with no catalog, are
        /// thrown.
        public var team: (Place) async throws -> Team
        /// One read of the fleet's resources (`ResourcesClient.read`). A read that failed is thrown.
        public var resources: (Place) async throws -> Resources
        /// One read of the vault's page (`VaultClient.reading`). A read that failed is thrown.
        public var vault: (Place) async throws -> Vault
        /// Whether this Mac holds an owner key for the fleet of this id, without reading it
        /// (`OwnerKeychain.isHeld(fleet:)`).
        public var holdsKey: (String) -> Bool
        /// As `GrantSecret.Desk.clockApart`: whether this Mac's clock and the hub's differ by more than an hour, and
        /// nil ("not ready") with no answer of the hub in this launch for this place. Asked only for a standing.
        public var clockApart: (Place) -> Bool?
        /// **Makes one statement, signs it with the owner key of this Mac and sends it** (`GrantSigning` in the app,
        /// `POST /ui/vault/grant`). It throws `NotSigned` when the key could not be read or made no signature:
        /// nothing was sent then. An error of the send itself is a `HubFailure`.
        public var sign: (Place, Statement) async throws -> Void
        /// The hub's standing of the secret (`ResourcesClient.saveStanding`, `POST /ui/resources`), against a base
        /// (the SHA-256 of a read of the resources): at most at the level, for every worker and lead (`audience`),
        /// or its end for nil. It gives the receipt's `changed`.
        public var standing: (_ place: Place, _ base: String, _ login: String, _ max: Level?) async throws -> Bool
        /// The app reads the fleet again (`FleetStore.refresh`), started and not waited for.
        public var refresh: () async -> Void

        public init(ready: @escaping () -> Place?, features: @escaping (Place) -> Features?,
                    team: @escaping (Place) async throws -> Team,
                    resources: @escaping (Place) async throws -> Resources,
                    vault: @escaping (Place) async throws -> Vault, holdsKey: @escaping (String) -> Bool,
                    clockApart: @escaping (Place) -> Bool?, sign: @escaping (Place, Statement) async throws -> Void,
                    standing: @escaping (Place, String, String, Level?) async throws -> Bool,
                    refresh: @escaping () async -> Void) {
            self.ready = ready
            self.features = features
            self.team = team
            self.resources = resources
            self.vault = vault
            self.holdsKey = holdsKey
            self.clockApart = clockApart
            self.sign = sign
            self.standing = standing
            self.refresh = refresh
        }
    }

    // ------------------------------------------------------------ the answer to one call

    /// **The app's answer to one call**, in a fixed order. The app trusts nothing of the program's checks: it makes
    /// each of them itself.
    ///
    /// 1. The fields, each in its form (`read`). No part after the request line.
    /// 2. A current reading of the fleet, with a hub that serves the Secrets page (`Desk.ready`).
    /// 3. The hub lists `resource_grants` and `signed_grants` (`Desk.features`), in this order: a hub with neither
    ///    keeps no standing at all, and only a hub that keeps standings is one where `share_resource` sets one. A
    ///    reading that moved is "not ready".
    /// 4. Three reads: the fleet's list, the fleet's resources and the vault's page. Then, each with its own
    ///    sentence: the page names the fleet; the hub has a reading of a central vault; the hub's newest read of that
    ///    vault did not fail (`Vault.Central.of`); this Mac holds the fleet's owner key. Then, **for a standing
    ///    only**: the list and the resources have the secret; `read` only for an API key; and the hub answered the
    ///    app in this launch, and its clock and this Mac's do not differ by more than an hour (`Desk.clockApart`:
    ///    with no such answer, "not ready"). **A take-back makes no
    ///    check of the secret**: an end goes for whatever the hub has, and the hub answers in its own words.
    /// 5. No other call of the tool is at its writes (`Line`).
    /// 6. The call still has its caller: a call whose connection ended sends nothing.
    /// 7. The writes, in a task of the line's own. **A standing**: the signed `pool`, and then the hub's standing
    ///    against the base of the read of step 4. **A take-back**: the hub's end of the standing against that base,
    ///    and then the signed `unpool`. A 409 of the hub's standing gets one more read of the resources, by the app's
    ///    own rule for a conflict (`HubError.conflict`: only a base that moved was the stale one), and `conflict`
    ///    says what it leads to.
    /// 8. From the first write on, the call goes to its end also when its caller went away.
    ///
    /// **No `await` stands between the look of step 5, the look of step 6 and the start of the writes.**
    ///
    /// **When the hub refuses the standing after the vault took the pool statement**, the app reads the resources one
    /// time more and decides by that read alone, never by the read of step 4: between the two, the owner's own
    /// control can have written a standing, and an `unpool` would then end the statement that it needs. No standing
    /// for this secret in that read: the app signs the `unpool` and sends it. A standing there, at any level: no
    /// `unpool`. A read that failed: no `unpool`, and the words say what can be left. For a 409 that read is the one
    /// of `conflict`, and a second send comes before the decision only when the base moved and this secret's
    /// standing did not.
    ///
    /// **The answer** of a call whose writes all went: `login`, `max`, `to` (`workers`, for a standing), `signed`
    /// true, `changed` (the hub's receipt) and `note`. Then the app reads the fleet again, started and not waited for.
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
        // 3. The two features.
        guard let listed = desk.features(place) else { return .refused(notReady) }
        guard listed.standings else { return .refused(noStandings) }
        guard listed.signs else { return .refused(noSignedPool) }
        // 4. The three reads, and what they must show.
        let team: Team, resources: Resources, vault: Vault
        do { team = try await desk.team(place) } catch { return .refused(teamUnread) }
        do { resources = try await desk.resources(place) } catch { return .refused(resourcesUnread) }
        do { vault = try await desk.vault(place) } catch { return .refused(vaultUnread) }
        guard let fleet = vault.fleet else { return .refused(noFleet) }
        switch vault.central {
        case .noReading: return .refused(noVaultReading)
        case .silent: return .refused(vaultSilent)
        case .answers: break
        }
        guard desk.holdsKey(fleet) else { return .refused(read.max == nil ? noOwnerKeyTakeBack : noOwnerKey) }
        if let max = read.max {
            guard let secret = team.secrets[read.login], resources.ids.contains(resourceID(read.login)) else {
                return .refused(noSecret)
            }
            if max == .read && !secret.apiKey { return .refused(readNeedsKey) }
            guard let apart = desk.clockApart(place) else { return .refused(notReady) }
            guard !apart else { return .refused(clockApart) }
        }
        // The base of the writes, and this secret's standing in the same read: a 409 is judged against both.
        let first = Before(base: resources.sha256, standing: resources.standing(of: read.login))
        // 5 and 6, and then the start of the writes, with no `await` between the three.
        guard !line.busy else { return .refused(busy) }
        if Task.isCancelled { return .refused(ended) }
        let writes = line.begin {
            if let max = read.max {
                return await share(read, max, fleet: fleet, first: first, place: place, desk: desk)
            }
            return await takeBack(read, fleet: fleet, first: first, place: place, desk: desk)
        }
        // The line was free one line above, so this is a line that nothing reaches.
        guard let writes else { return .refused(busy) }
        // 8. The wait for the writes' end takes no cancel: the call goes on to its end without its caller.
        return await writes.value
    }

    /// **The base of a call's writes, and this secret's standing in the same read** (step 4): what a 409 of the
    /// standing is judged against.
    struct Before: Equatable, Sendable {
        let base: String
        /// The level of this secret's standing in that read, or nil for none.
        let standing: String?
    }

    /// **What a 409 of the hub's standing leads to**, by one more read of the resources, as the app's own rule for a
    /// conflict says (`HubError.conflict`): the hub answers 409 for a base that moved (`team_changed`), for a
    /// generation that changed and when its checkout cannot take the commit (`commit_kit_file`), and only a base
    /// that moved was the stale one. A second send goes only when this secret's standing did not change with the
    /// base: one that changed can be the owner's own newer click, and a second send would undo it.
    enum Conflict: Equatable {
        /// The read failed: no second send.
        case unread
        /// The base did not move: a certain refusal, decided by this read.
        case refused(Resources)
        /// The base moved, and this secret's standing with it: no second send, and the decision is this read's.
        case changed(Resources)
        /// The base moved, and this secret's standing is the one of the call's first read: one more send with this
        /// read's base.
        case moved(Resources)
    }

    @MainActor
    static func conflict<Place>(_ login: String, first: Before, place: Place, desk: Desk<Place>) async -> Conflict {
        guard let now = try? await desk.resources(place) else { return .unread }
        if now.sha256 == first.base { return .refused(now) }
        return now.standing(of: login) == first.standing ? .moved(now) : .changed(now)
    }

    /// **The writes of a standing**: the signed `pool`, then the hub's standing, and after a certain refusal of the
    /// standing one more read of the resources and, only when it shows no standing for this secret, the signed
    /// `unpool`. A 409 goes by `conflict`: its read decides, or one more send with its base goes first.
    @MainActor
    private static func share<Place>(_ read: Read, _ max: Level, fleet: String, first: Before, place: Place,
                                     desk: Desk<Place>) async -> OwnerChannel.Answer {
        let pool = Statement(fleet: fleet, login: read.login, inPool: true)
        switch await GrantSecret.sent({ try await desk.sign(place, pool) }) {
        case .took: break
        // The check of step 4 said that this Mac holds the key: the words do not say that it holds none.
        case .notSigned: return .refused(notSignedNow)
        case .refused(let status, let said):
            return .refused(GrantSecret.withHubWords(poolRefused, status: status, said))
        case .notKnown: return .refused(poolNotKnown)
        }
        var outcome = await GrantSecret.sent({ try await desk.standing(place, first.base, read.login, max) })
        if case .refused(409, let said) = outcome {
            switch await conflict(read.login, first: first, place: place, desk: desk) {
            case .unread:
                return .refused(GrantSecret.withHubWords(standingUnwritten, status: 409, said))
            case .refused(let now):
                return await decide(read, fleet: fleet, status: 409, said, by: now, place: place, desk: desk)
            case .changed(let now):
                return await decide(read, fleet: fleet, status: 409, said, by: now, changed: true, place: place,
                                    desk: desk)
            case .moved(let now):
                outcome = await GrantSecret.sent({ try await desk.standing(place, now.sha256, read.login, max) })
            }
        }
        switch outcome {
        case .took(let changed):
            await desk.refresh()
            return .result(result(read, changed: changed))
        case .notSigned, .notKnown:
            return .refused(standingNotKnown)
        case .refused(let status, let said):
            // The resources as they are now, and never as the call's first read had them.
            guard let now = try? await desk.resources(place) else {
                return .refused(GrantSecret.withHubWords(standingRefusedUnread, status: status, said))
            }
            return await decide(read, fleet: fleet, status: status, said, by: now, place: place, desk: desk)
        }
    }

    /// **The decision after a certain refusal of the standing**, by a read of the resources that came after it: with
    /// no standing for this secret there, the signed `unpool`; with one, at any level, nothing more. `changed`: this
    /// secret's standing changed while the call ran, and the words say so first.
    @MainActor
    private static func decide<Place>(_ read: Read, fleet: String, status: Int, _ said: String, by now: Resources,
                                      changed: Bool = false, place: Place,
                                      desk: Desk<Place>) async -> OwnerChannel.Answer {
        let lead = changed ? standingChanged + " " : "", tail = changed ? " " + askOwnerFirst : ""
        guard now.standing(of: read.login) == nil else {
            return .refused(GrantSecret.withHubWords(lead + standingRefusedHubHasOne + tail, status: status, said))
        }
        let end = Statement(fleet: fleet, login: read.login, inPool: false)
        // Not `askOwnerFirst` here: the step of this sentence is the end of the statement that this call left, with
        // `max` null, which can write over no change of the owner's, because the hub has no standing for this secret.
        // After that end, a standing waits for the owner's word (`askOwnerAfterEnd`).
        guard case .took = await GrantSecret.sent({ try await desk.sign(place, end) }) else {
            let after = changed ? " " + askOwnerAfterEnd : ""
            return .refused(GrantSecret.withHubWords(lead + standingRefusedStatementLeft + after, status: status, said))
        }
        return .refused(GrantSecret.withHubWords(lead + standingRefusedTakenBack + tail, status: status, said))
    }

    /// **The writes of a take-back**: the hub's end of the standing, then the signed `unpool`. A 409 goes by
    /// `conflict`: a read that failed, a base that did not move and a standing at another level now end the call with
    /// nothing changed by it; a standing that ended meanwhile goes on to the signed end; and only a base that moved
    /// with this secret's standing as it was gets one more send. After the hub's end the standing changed, so the app
    /// reads the fleet again also when the signed end did not go.
    @MainActor
    private static func takeBack<Place>(_ read: Read, fleet: String, first: Before, place: Place,
                                        desk: Desk<Place>) async -> OwnerChannel.Answer {
        var outcome = await GrantSecret.sent({ try await desk.standing(place, first.base, read.login, nil) })
        var meanwhile = false       // another writer ended the hub's standing while this call ran
        if case .refused(409, let said) = outcome {
            switch await conflict(read.login, first: first, place: place, desk: desk) {
            case .unread: return .refused(GrantSecret.withHubWords(endUnread, status: 409, said))
            case .refused: return .refused(GrantSecret.withHubWords(endRefused, status: 409, said))
            case .changed(let now):
                // The hub has no standing for this secret now, as this call asks: the end of the hub is done, by
                // another writer (`share_resource` with no max ends it and leaves the pool statement), so the
                // signed end goes, as for a call that found no standing. A standing at another level is the owner's
                // to decide.
                guard now.standing(of: read.login) == nil else {
                    return .refused(GrantSecret.withHubWords(endChanged, status: 409, said))
                }
                meanwhile = true
                outcome = .took(false)
            case .moved(let now):
                outcome = await GrantSecret.sent({ try await desk.standing(place, now.sha256, read.login, nil) })
                if case .refused(409, let again) = outcome {
                    return .refused(GrantSecret.withHubWords(endMoved, status: 409, again))
                }
            }
        }
        let changed: Bool
        switch outcome {
        case .took(let taken): changed = taken
        case .refused(let status, let said):
            return .refused(GrantSecret.withHubWords(endRefused, status: status, said))
        case .notSigned, .notKnown: return .refused(endNotKnown)
        }
        let end = Statement(fleet: fleet, login: read.login, inPool: false)
        let signed = await GrantSecret.sent { try await desk.sign(place, end) }
        await desk.refresh()
        switch signed {
        case .took: return .result(result(read, changed: changed, meanwhile: meanwhile))
        case .refused(let status, let said):
            return .refused(GrantSecret.withHubWords(unpoolFailed, status: status, said))
        case .notSigned, .notKnown: return .refused(unpoolFailed)
        }
    }

    /// The answer of a call whose writes all went.
    static func result(_ read: Read, changed: Bool, meanwhile: Bool = false) -> JSONValue {
        var answer: [String: JSONValue] = [
            "login": .string(read.login), "max": read.max.map { JSONValue.string($0.rawValue) } ?? .null,
            "signed": .bool(true), "changed": .bool(changed),
            "note": .string(meanwhile ? noteEndedMeanwhile : note(read.max, changed: changed)),
        ]
        if read.max != nil { answer["to"] = .string(audience) }
        return .object(answer)
    }

    /// **The note of an answer**, of fixed sentences. For a standing: that the hub had it already, when the hub
    /// changed nothing; then what the fleet manager may now give, for `use` or for `read`; that the hub told the
    /// manager, when the standing changed; then when the value reaches a server. For a take-back: what ended.
    static func note(_ max: Level?, changed: Bool) -> String {
        guard let max else { return changed ? noteTakenBack : noteNoStanding }
        var sentences: [String] = changed ? [] : [noteSame]
        sentences.append(max == .read ? noteRead : noteUse)
        if changed { sentences.append(noteTold) }
        sentences.append(noteDelivery)
        return sentences.joined(separator: " ")
    }
}
