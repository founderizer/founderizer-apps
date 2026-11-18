import AppKit
import FleetCore
import FleetOwnerAPI
import Foundation

/// **The app's side of the link's write tools** (`OwnerLinkTools` in FleetOwnerAPI; the secrets plan, steps B and
/// E): a thin adapter from each tool's logic (`SaveBotToken.answer`, `PrepareReport.answer`, `SaveSecret.answer`,
/// `GrantSecret.answer`, `ShareSecret.answer`, `AnswerSecret.answer`, `AnswerDoor.answer`, tested there with
/// stand-ins) to the app's own engine, on the board of `SetupChannel`.
/// Nothing of it shows on the screen, and nothing of a request (its line, its fields, its value part) is written
/// to the app's log.
///
/// **`save_bot_token`** sends the token as the Discord page's Save does (`DiscordBotPage.save()`): only while the
/// store's reading is current and has a database, with the store's hub, database and installation, through
/// `ChatAppsClient.saveToken`. Unlike the page, it makes no account: the account must be a Discord account that the
/// fleet's chat apps page lists (`ChatAppsClient.read`), whose bridge state also decides `replace`. It takes no command
/// lock: the app does the write, as its form does. With `from` clipboard the app reads `NSPasteboard.general` itself,
/// last, and clears it after a save that the hub confirmed (step C).
///
/// **`save_secret`** saves a new login or API key as Add secret's form does for a new value with no grant
/// (`SecretEntryView`): the item is sealed here to the central vault's key, only while that key is the one that this
/// Mac pinned; the hub gets the entry of its list (`SecretEntryView.register`, as it is); and the hub passes the
/// sealed copy on to the vault (`VaultClient.intake`). It gives the secret to no agent, replaces nothing and sets no
/// site itself. Its work outlives its call, in a table of its own (`LinkWork`). The desk is `secretDesk`, closure by
/// closure.
///
/// **`grant_secret`** gives one secret to one agent, or takes it back, as Give and Take back of the Secrets page do
/// (`SecretsPage.grant`): the owner's signed statement through `GrantSigning.send` (`POST /ui/vault/grant`) and the
/// hub's grant through `SecretsClient.grant` (`POST /ui/secrets/grant`), in the page's own order. It asks the owner
/// nothing (the owner's "No touch" of 15 November 2026), and it signs only for the server of its own one read of
/// the team. One call writes at a time, in the line that it shares with `answer_secret_request` (`GrantSecret.Line`).
/// The desk is `grantDesk`, closure by closure.
///
/// **`share_secret`** sets who may give one secret, or ends it, as "Who may give it" of the Secrets page does
/// (`SecretsPage.saveStanding`): the owner's signed `pool` statement through `GrantSigning.send(pool:...)`
/// (`POST /ui/vault/grant`) and the hub's standing through `ResourcesClient.saveStanding` (`POST /ui/resources`), in
/// the page's own order. It asks the owner nothing, and it writes against the base of its own read of the
/// resources. One call of it writes at a time, in a line of its own (an instance of `ShareSecret.Line`). The desk is
/// `shareDesk`, closure by closure.
///
/// **`answer_secret_request`** answers one request of an agent for a secret with a secret of the list, as "Answer with
/// it" of the request's form does (`SecretEntryView.answerWith` and `proceed`): each give of the call as
/// `grant_secret`'s, through the same two functions, and then the answer through `SecretsClient.answer`
/// (`POST /ui/needs/<need>/secret`), in the form's own order. A request for the door gets the form's give to the
/// door, signed for the door's own name (`GrantSigning.send` with the machine `door`). It asks the owner nothing, and
/// it takes no give back. Both tools write grants, so they share one line of writes: the one instance of
/// `GrantSecret.Line` that `add` makes. The desk is `answerDesk`, closure by closure.
///
/// **`answer_needs_you`, for a door card's signed press alone** (Run it once, and Full access on the card's server):
/// the program sends that one press of the tool to the app, which signs it by the rule of the owner's own press
/// (`DoorCallSigning.maker`) and sends it as that press does (`HubClient.send`, `POST /ui/needs/<need>`), with no
/// question to the owner. Every other answer of the tool goes from the program to the hub. The desk is `doorDesk`,
/// closure by closure.
///
/// **A text for the report form**: one that the owner's own agent wrote (`prepare_problem_report`), or the app's own
/// words of the problem that a button reports (the manager band's Report a problem). The form takes it, and says
/// whether it shows it or keeps the owner's own text.
struct ReportAsk: Equatable {
    enum Outcome: Equatable {
        case shown
        case ownText
    }

    let id = UUID()
    let text: String
    /// The owner's own agent wrote it, and the report then says so (`ProblemReport.writtenByAgent`); false for the
    /// app's own words.
    var byAgent = true
    var outcome: Outcome?
}

@MainActor
enum LinkTools {
    /// The hub, the database and the installation that one call reads and sends with.
    struct Place: Sendable {
        let hub: URL
        let database: String
        let client: String
    }

    static func add(to board: SetupBoard, store: @escaping @MainActor () -> FleetStore?) {
        let client = ChatAppsClient()
        let desk = SaveBotToken.Desk<BotToken, Place>(
            token: { BotToken(pasted: $0) },
            isAccountID: { ChatApps.isAccountID($0) },
            ready: {
                guard let store = store(), store.writesNow, let database = store.state?.db else { return nil }
                return Place(hub: store.hub, database: database, client: store.installation)
            },
            accounts: { place in
                do {
                    return try await client.read(hub: place.hub, database: place.database).accounts
                        .map { SaveBotToken.Account(id: $0.id, app: $0.app, state: $0.state) }
                } catch {
                    throw failure(error)
                }
            },
            save: { place, account, token in
                do {
                    let receipt = try await client.saveToken(hub: place.hub, database: place.database,
                                                             client: place.client, account: account, token: token)
                    // An older hub that gives no `replaced` is said as null, never as "not replaced".
                    return SaveBotToken.Receipt(set: receipt.set ?? (token != nil), replaced: receipt.replaced)
                } catch {
                    throw failure(error)
                }
            },
            readClipboard: { gate.read { readPasteboard() } },
            clearClipboard: { count in clearPasteboard(ifStill: count) })
        board.add(set: OwnerSetupTools.set, tool: SaveBotToken.name, value: .optional) { fields, value in
            await SaveBotToken.answer(fields: fields, value: value, desk: desk)
        }
        // `prepare_problem_report`: the agent's text goes into the app's own report form, and the owner sends it.
        let reports = PrepareReport.Desk(holdsKey: { KeyInText.contains($0) },
                                         show: { text in await showReport(text, store: store()) })
        board.add(set: OwnerSetupTools.set, tool: PrepareReport.name, value: .none) { fields, value in
            await PrepareReport.answer(fields: fields, value: value, desk: reports)
        }
        // `save_secret`: a new login or API key into the central vault. One table of work for the tool, which lives
        // as long as the board: a save that its call left goes on there, and a later call reads its state.
        let secrets = secretDesk(store: store)
        let work = LinkWork()
        board.add(set: OwnerSetupTools.set, tool: SaveSecret.name, value: .optional) { fields, value in
            await SaveSecret.answer(fields: fields, value: value, desk: secrets, work: work)
        }
        // `grant_secret`: one secret to one agent with the owner's signature, or its end. One line of writes, which
        // lives as long as the board: one call writes at a time, and its writes end without it. The line is also
        // `answer_secret_request`'s (below): both tools write grants, and their writes must not cross.
        let grants = grantDesk(store: store)
        let line = GrantSecret.Line()
        board.add(set: OwnerSetupTools.set, tool: GrantSecret.name, value: .none) { fields, value in
            await GrantSecret.answer(fields: fields, value: value, desk: grants, line: line)
        }
        // `answer_secret_request`: the signed gives of one call and the answer of an agent's request for a secret,
        // in the same line of writes as `grant_secret`.
        let answers = answerDesk(store: store)
        board.add(set: OwnerSetupTools.set, tool: AnswerSecret.name, value: .none) { fields, value in
            await AnswerSecret.answer(fields: fields, value: value, desk: answers, line: line)
        }
        // `share_secret`: who may give one secret, with the owner's signature, or its end. A line of writes of the
        // tool's own, which lives as long as the board: one call of it writes at a time, and its writes end without it.
        let shares = shareDesk(store: store)
        let shareLine = ShareSecret.Line()
        board.add(set: OwnerSetupTools.set, tool: ShareSecret.name, value: .none) { fields, value in
            await ShareSecret.answer(fields: fields, value: value, desk: shares, line: shareLine)
        }
        // `answer_needs_you`, for a door card's signed press alone: Run it once or Full access, signed by the rule of
        // the owner's own press, and sent. One write, so no line of writes.
        let doors = doorDesk(store: store)
        board.add(set: OwnerSetupTools.set, tool: AnswerDoor.name, value: .none) { fields, value in
            await AnswerDoor.answer(fields: fields, value: value, desk: doors)
        }
    }

    // ------------------------------------------------------------ the vault (`save_secret`)

    /// The form's own kind for the tool's. No default: a third kind of the tool is a build error here.
    nonisolated static func kind(_ kind: SaveSecret.Kind) -> LoginSecret.Kind {
        switch kind {
        case .login: return .login
        case .apiKey: return .apiKey
        }
    }

    /// **The secret of the tool's fields as the form's own type holds it** (`SecretOfFields` in FleetCore): the one
    /// helper for the check of the fields, the maker of the item and the address of the hub's step.
    nonisolated static func form(_ fields: SaveSecret.Fields) -> SecretOfFields {
        SecretOfFields(kind: kind(fields.kind), env: fields.env, url: fields.url, username: fields.username)
    }

    /// The tool's answer for the key to seal to. No default: a sixth answer of `VaultSealKey` is a build error here.
    /// The tool's own sixth answer, `moved`, is no answer of that rule: the desk gives it before the rule is asked.
    nonisolated static func sealKey(_ key: VaultSealKey) -> SaveSecret.SealKey {
        switch key {
        case .key(let recipient): return .key(recipient)
        case .noVault: return .noVault
        case .noPin: return .noPin
        case .otherKey: return .otherKey
        case .noRecovery: return .noRecovery
        }
    }

    /// The tool's answer for the room in the list. No default, as `sealKey`.
    nonisolated static func room(_ room: SecretRoom) -> SaveSecret.Room {
        switch room {
        case .free: return .free
        case .held: return .held
        case .full: return .full
        case .unread: return .unread
        }
    }

    /// **The hub's features for one save**: the store's, only while the store still shows the hub and the database
    /// that the save sends with (`ShownFeatures`). nil says one thing only: the app's reading moved (another hub,
    /// another database, no state or no store). A hub that names no features, while the store shows it, is the
    /// empty list.
    static func features(of store: FleetStore?, at place: Place) -> [String]? {
        guard let store else { return nil }
        return ShownFeatures.of(store.state?.ui_features, hub: store.hub, database: store.state?.db,
                                sendsTo: (place.hub, place.database))
    }

    /// **The app's engine for `save_secret`**, closure by closure (`SaveSecret.Desk`). Each request ends by the time
    /// limit of its own client, so no run of the work waits without a bound. No closure keeps a reference to an
    /// item's bytes, and none writes anything of a request to the log.
    static func secretDesk(store: @escaping @MainActor () -> FleetStore?) -> SaveSecret.Desk<Place> {
        let vault = VaultClient(), lists = HubClient()
        return SaveSecret.Desk<Place>(
            // The form's own type on the fields alone, asked with a stand-in for the value that is no secret; the
            // title and the variable are read only from a secret that the type took. The maker of the item asks
            // the type again with the value itself, and hands out the type's own bytes: it keeps no reference.
            secret: { fields in
                let typed = form(fields)
                guard let name = typed.name(standIn: String(repeating: "x", count: SaveSecret.valueLeast)) else {
                    return nil
                }
                let draft = SaveSecret.Draft(title: name.title, kind: fields.kind, variable: name.variable)
                return SaveSecret.Secret(draft: draft) { text in typed.item(value: text) }
            },
            // As `save_bot_token`'s, and only while the hub serves Add secret's form (`SecretEntryView.isOffered`).
            ready: {
                guard let store = store(), store.writesNow, let database = store.state?.db,
                      SecretEntryView.isOffered(by: store) else { return nil }
                return Place(hub: store.hub, database: database, client: store.installation)
            },
            // The vault's reading (20 seconds for a request, 30 in all), the pin that the form uses, through the
            // reading's fleet id, and the served features. A read that failed is thrown as it is.
            //
            // **A store that moved during the read is `moved`, before the rule is asked.** The app shows another
            // hub or database now, so its features are not those of the hub that this call reads: "no vault is
            // served" is not known then. A hub that the store still shows and that does not name the feature is
            // `noVault`, by the rule.
            sealKey: { place in
                let reading = try await vault.reading(hub: place.hub, database: place.database)
                guard let shown = features(of: store(), at: place) else { return .moved }
                let pin = reading?.fleetID.flatMap { CentralVaultPins.recipient(hub: place.hub, fleet: $0) }
                return sealKey(VaultSealKey.of(reading, served: shown.contains(CentralVault.feature), pin: pin))
            },
            // The list's read (10 seconds for a request, 15 in all). A read that failed is thrown as it is.
            room: { place, draft in
                let team = try await lists.team(hub: place.hub, database: place.database)
                return room(SecretRoom.of(title: draft.title, kind: kind(draft.kind), logins: team.logins, but: nil))
            },
            seal: { item, key in try? AgeSeal.seal(item, to: key) },
            // The form's own hub step, as it is: the salts (10 and 15 seconds), then the entry (20 and 30), under a
            // new request id of the hub at each call (`SecretsClient.add`). **`address:` gives an API key its
            // site**: without it the hub gets no address, and a key of a well-known service gets none. It goes only
            // for an API key (the form's own rule; never for a login), and only while the store still shows this
            // place's hub and database. The tool sets no site itself.
            register: { place, reference, draft, fields, item in
                let address = form(fields).address(features: features(of: store(), at: place))
                do {
                    try await SecretEntryView.register(reference, title: draft.title, kind: kind(draft.kind),
                                                       variable: draft.variable, address: address, value: item,
                                                       hub: place.hub, database: place.database,
                                                       installation: place.client)
                } catch {
                    throw failure(error)                  // a refusal carries the hub's own status, and no other
                }
            },
            // The vault's step, with no statement (20 seconds for a request, 30 in all).
            intake: { place, reference, sealed in
                do {
                    _ = try await vault.intake(hub: place.hub, database: place.database, client: place.client,
                                               login: reference, ciphertext: sealed)
                } catch {
                    throw failure(error)
                }
            },
            // **Started, and not waited for.** `FleetStore.refresh()` waits for a read that is on its way and for
            // its own read after it, and that read does more than its request; the work must end without it. The
            // entry is in the hub by now: the app's pages show it when this read ends.
            refresh: {
                guard let store = store() else { return }
                Task { @MainActor in await store.refresh() }
            },
            newReference: { "bws://" + UUID().uuidString.lowercased() },
            // The same gate and the same two functions as `save_bot_token`.
            readClipboard: { gate.read { readPasteboard() } },
            clearClipboard: { count in clearPasteboard(ifStill: count) })
    }

    // ------------------------------------------------------------ a signed grant (`grant_secret`)

    /// The app's own level for the tool's. No default: a third level of the tool is a build error here.
    nonisolated static func level(_ level: GrantSecret.Level) -> SecretGrant {
        switch level {
        case .use: return .use
        case .read: return .read
        }
    }

    /// **The fleet's list as the tool reads it**, from one read of the team: each secret of the catalog with its
    /// kind, its variable name, its title (which only `answer_secret_request` reads) and its grants, and each
    /// agent with its role and the server that the hub names for it. nil for a page with no catalog that the app
    /// can read: the tool then says that the list was not read.
    nonisolated static func fleetList(_ team: TeamSnapshot) -> GrantSecret.Team? {
        guard let logins = team.logins else { return nil }
        let secrets = logins.mapValues {
            GrantSecret.Team.Secret(apiKey: $0.isAPIKey, env: $0.env, title: $0.title, grants: $0.grants ?? [:])
        }
        let agents = team.members.map {
            ($0.agent, GrantSecret.Team.Agent(role: $0.role, machine: $0.placement?.machine))
        }
        return GrantSecret.Team(secrets: secrets, agents: Dictionary(agents) { first, _ in first })
    }

    /// **Whether this Mac's clock and the hub's differ by more than an hour**, for the desks of the three tools that
    /// sign a give or a pool statement: the rule of the app's own controls that sign (`VaultPlan.clockProblem`, with
    /// the hub's time of the store's last answered read and this Mac's time of that answer). **It fails closed**: nil,
    /// which the tools answer as "not ready", when the store has no answer of the hub in this launch, and when it no
    /// longer shows the call's hub and database. A kept reading counts as current until the launch's first read ends
    /// (`isFresh`), and it gives no clock: the program's first call after it started the app comes in that moment.
    static func clockApart(_ store: FleetStore?, at place: Place) -> Bool? {
        guard let store, store.hub == place.hub, let state = store.state, state.db == place.database,
              let answered = store.lastSuccess else { return nil }
        return VaultPlan.clockProblem(hubTime: state.time, readAt: answered.timeIntervalSince1970) != nil
    }

    /// The vault's page as the tool reads it: the fleet's id as `GrantSigning` reads it (`fleetID`), and what the
    /// page says of the central vault, by the tool's own rule (`GrantSecret.Vault.Central.of`) over the page's
    /// central part, that part's `ok` and the page's `error`. A hub with no such page (nil) names no fleet and
    /// has no reading.
    nonisolated static func vaultFacts(_ reading: VaultReading?) -> GrantSecret.Vault {
        GrantSecret.Vault(fleet: reading?.fleetID,
                          central: .of(central: reading?.central.map(\.ok), error: reading?.error))
    }

    /// **The app's engine for `grant_secret`**, closure by closure (`GrantSecret.Desk`). Each request ends by the
    /// time limit of its own client (the team's read 10 seconds for a request and 15 in all; the vault's read, the
    /// signed statement and the hub's grant 20 and 30 each), so the writes of a call, which run without their
    /// caller, never wait without a bound. No closure writes anything of a request to the log, and none shows
    /// anything on the screen.
    static func grantDesk(store: @escaping @MainActor () -> FleetStore?) -> GrantSecret.Desk<Place> {
        let vault = VaultClient(), lists = HubClient(), secrets = SecretsClient()
        return GrantSecret.Desk<Place>(
            // The condition under which the Secrets page lets the owner change a grant (`SecretsPage.canChange`
            // without its own `working`): a current reading with a database, and a hub that serves the page with
            // its grants (`SecretEntryView.isOffered`).
            ready: {
                guard let store = store(), store.writesNow, let database = store.state?.db,
                      SecretEntryView.isOffered(by: store) else { return nil }
                return Place(hub: store.hub, database: database, client: store.installation)
            },
            // `signed_grants`, from the features of the hub that the store still shows: a store that moved is nil,
            // which the tool reads as "not ready" and never as "not listed".
            signs: { place in features(of: store(), at: place).map { $0.contains(GrantSigning.feature) } },
            // The list's read that `secretDesk` uses. A read that failed is thrown as it is, and a page with no
            // catalog is thrown too.
            team: { place in
                guard let found = fleetList(try await lists.team(hub: place.hub, database: place.database)) else {
                    throw HubError.invalidResponse
                }
                return found
            },
            // The vault's reading. A read that failed is thrown as it is.
            vault: { place in vaultFacts(try await vault.reading(hub: place.hub, database: place.database)) },
            // Whether the key is there, with no read of it.
            holdsKey: { fleet in OwnerKeychain.isHeld(fleet: fleet) },
            isMachine: { CentralVault.isMachine($0) },
            // The rule of the app's own controls that sign, which fails closed (`clockApart(_:at:)`).
            clockApart: { place in clockApart(store(), at: place) },
            // One statement, made, signed and sent, for the fleet and the server that the tool read. A key that
            // could not be read, and a key that made no signature, are that function's `NotSigned`: nothing was
            // sent then, and the tool gets its own error for it, never a failure of the hub.
            sign: { place, statement in
                do {
                    try await GrantSigning.send(grantOn: statement.machine, login: statement.login,
                                                agent: statement.agent, fleet: statement.fleet,
                                                client: place.client, hub: place.hub, database: place.database)
                } catch is GrantSigning.NotSigned {
                    throw GrantSecret.NotSigned()
                } catch {
                    throw failure(error)                  // a refusal carries the hub's own status and its words
                }
            },
            // The hub's grant, or its end for nil, under a new request id of the hub at each call.
            grant: { place, login, agent, wanted in
                do {
                    let receipt = try await secrets.grant(hub: place.hub, database: place.database,
                                                          client: place.client, login: login, agent: agent,
                                                          grant: wanted.map(level))
                    let access = receipt.vault.map {
                        GrantSecret.Receipt.Access(before: $0.before, after: $0.after, missing: $0.missing)
                    }
                    return GrantSecret.Receipt(changed: receipt.changed, access: access)
                } catch {
                    throw failure(error)
                }
            },
            // Started, and not waited for, as `secretDesk`'s.
            refresh: {
                guard let store = store() else { return }
                Task { @MainActor in await store.refresh() }
            })
    }

    // ------------------------------------------------------------ a signed answer (`answer_secret_request`)

    /// **The app's engine for `answer_secret_request`**, closure by closure (`AnswerSecret.Desk`). Each request ends
    /// by the time limit of its own client (the state's read and the team's read 10 seconds for a request and 15 in
    /// all; the vault's read, the signed statement, the hub's grant and the answer 20 and 30 each), so the writes of a
    /// call, which run without their caller, never wait without a bound. No closure writes anything of a request to
    /// the log, and none shows anything on the screen.
    static func answerDesk(store: @escaping @MainActor () -> FleetStore?) -> AnswerSecret.Desk<Place> {
        let vault = VaultClient(), lists = HubClient(), secrets = SecretsClient()
        return AnswerSecret.Desk<Place>(
            // As `grantDesk`'s: a current reading with a database, and a hub that serves the Secrets page.
            ready: {
                guard let store = store(), store.writesNow, let database = store.state?.db,
                      SecretEntryView.isOffered(by: store) else { return nil }
                return Place(hub: store.hub, database: database, client: store.installation)
            },
            // As `grantDesk`'s: a store that moved is nil.
            signs: { place in features(of: store(), at: place).map { $0.contains(GrantSigning.feature) } },
            // One read of the hub's state, whole (it has no query for one database), and the tool's own read of its
            // bytes for the item of this id and the place's database. A read that failed is thrown as it is. The
            // state can be large, so the parse runs off the main actor.
            request: { place, need in
                let reading = try await lists.stateReading(at: place.hub)
                let data = reading.data, database = place.database
                return await Task.detached {
                    AnswerSecret.request(in: data, need: need, database: database)
                }.value
            },
            // The list's read of `grantDesk`, with each secret's title. A read that failed is thrown as it is, and
            // a page with no catalog too.
            team: { place in
                guard let found = fleetList(try await lists.team(hub: place.hub, database: place.database)) else {
                    throw HubError.invalidResponse
                }
                return found
            },
            // The vault's reading, as `grantDesk`'s.
            vault: { place in vaultFacts(try await vault.reading(hub: place.hub, database: place.database)) },
            holdsKey: { fleet in OwnerKeychain.isHeld(fleet: fleet) },
            isMachine: { CentralVault.isMachine($0) },
            // The rule of the app's own controls that sign, which fails closed (`clockApart(_:at:)`).
            clockApart: { place in clockApart(store(), at: place) },
            // One statement, made, signed and sent, as `grantDesk`'s.
            sign: { place, statement in
                do {
                    try await GrantSigning.send(grantOn: statement.machine, login: statement.login,
                                                agent: statement.agent, fleet: statement.fleet,
                                                client: place.client, hub: place.hub, database: place.database)
                } catch is GrantSigning.NotSigned {
                    throw GrantSecret.NotSigned()
                } catch {
                    throw failure(error)                  // a refusal carries the hub's own status and its words
                }
            },
            // The hub's grant at a level, under a new request id of the hub at each call. Never an end.
            grant: { place, login, agent, wanted in
                do {
                    let receipt = try await secrets.grant(hub: place.hub, database: place.database,
                                                          client: place.client, login: login, agent: agent,
                                                          grant: level(wanted))
                    let access = receipt.vault.map {
                        GrantSecret.Receipt.Access(before: $0.before, after: $0.after, missing: $0.missing)
                    }
                    return GrantSecret.Receipt(changed: receipt.changed, access: access)
                } catch {
                    throw failure(error)
                }
            },
            // The answer of the request, under a new request id of the app at each call. The hub's words to the
            // agent come back in the receipt and go nowhere from here. The hub's refusal of a request that has its
            // answer (its code `request_answered`, as the form reads it) is the tool's own error.
            answer: { place, need, login in
                do {
                    _ = try await secrets.answer(hub: place.hub, database: place.database, client: place.client,
                                                 need: need, requestID: UUID(), login: login)
                } catch HubError.refusal(let refused) where refused.status == 409 && refused.means(.requestAnswered) {
                    throw AnswerSecret.Answered()
                } catch {
                    throw failure(error)
                }
            },
            // Started, and not waited for, as `secretDesk`'s.
            refresh: {
                guard let store = store() else { return }
                Task { @MainActor in await store.refresh() }
            })
    }

    // ------------------------------------------------------------ a signed standing (`share_secret`)

    /// **The fleet's resources as the tool reads them**, from one read of the resources page: its base, the id of
    /// each resource, and the level of each standing now (the page's `grant.max`, at any level), by its id.
    nonisolated static func standings(_ list: ResourceList) -> ShareSecret.Resources {
        let held = list.resources.compactMap { resource in resource.grant.map { (resource.id, $0.max) } }
        return ShareSecret.Resources(sha256: list.sha256, ids: Set(list.resources.map(\.id)),
                                     standings: Dictionary(held) { first, _ in first })
    }

    /// **The app's engine for `share_secret`**, closure by closure (`ShareSecret.Desk`). Each request ends by the
    /// time limit of its own client (the team's read 10 seconds for a request and 15 in all; the vault's read and the
    /// signed statement 20 and 30 each; the resources' read and the standing 60 and 90 each), so the writes of a
    /// call, which run without their caller, never wait without a bound. No closure writes anything of a request to
    /// the log, and none shows anything on the screen.
    static func shareDesk(store: @escaping @MainActor () -> FleetStore?) -> ShareSecret.Desk<Place> {
        let vault = VaultClient(), lists = HubClient(), owned = ResourcesClient()
        return ShareSecret.Desk<Place>(
            // As `grantDesk`'s: a current reading with a database, and a hub that serves the Secrets page.
            ready: {
                guard let store = store(), store.writesNow, let database = store.state?.db,
                      SecretEntryView.isOffered(by: store) else { return nil }
                return Place(hub: store.hub, database: database, client: store.installation)
            },
            // `signed_grants` and `resource_grants`, from the features of the hub that the store still shows: a store
            // that moved is nil, which the tool reads as "not ready" and never as "not listed".
            features: { place in
                features(of: store(), at: place).map {
                    ShareSecret.Features(signs: $0.contains(GrantSigning.feature),
                                         standings: $0.contains(ResourceList.feature))
                }
            },
            // The list's read of `grantDesk`. A read that failed is thrown as it is, and a page with no catalog too.
            team: { place in
                guard let found = fleetList(try await lists.team(hub: place.hub, database: place.database)) else {
                    throw HubError.invalidResponse
                }
                return found
            },
            // The resources' read, which the client checks for its database and its form. A read that failed is
            // thrown as it is.
            resources: { place in standings(try await owned.read(hub: place.hub, database: place.database)) },
            // The vault's reading, as `grantDesk`'s.
            vault: { place in vaultFacts(try await vault.reading(hub: place.hub, database: place.database)) },
            holdsKey: { fleet in OwnerKeychain.isHeld(fleet: fleet) },
            // As `grantDesk`'s.
            clockApart: { place in clockApart(store(), at: place) },
            // One pool statement, made, signed and sent, for the fleet that the tool read. A key that could not be
            // read, and a key that made no signature, are that function's `NotSigned`: nothing was sent then.
            sign: { place, statement in
                do {
                    try await GrantSigning.send(pool: statement.inPool, login: statement.login, fleet: statement.fleet,
                                                client: place.client, hub: place.hub, database: place.database)
                } catch is GrantSigning.NotSigned {
                    throw ShareSecret.NotSigned()
                } catch {
                    throw failure(error)                  // a refusal carries the hub's own status and its words
                }
            },
            // The hub's standing for the secret against the tool's base, for every worker and lead, or its end for
            // nil, under a new request id of the hub at each call.
            standing: { place, base, login, max in
                let standing = max.map { ResourceStanding.grantable(max: $0.rawValue, to: ResourceList.everyone) }
                    ?? .ownerOnly
                do {
                    return try await owned.saveStanding(hub: place.hub, database: place.database, client: place.client,
                                                        sha256: base, resource: ShareSecret.resourceID(login),
                                                        standing: standing).changed
                } catch {
                    throw failure(error)
                }
            },
            // Started, and not waited for, as `secretDesk`'s.
            refresh: {
                guard let store = store() else { return }
                Task { @MainActor in await store.refresh() }
            })
    }

    // ------------------------------------------------------------ a door card's signed press (`answer_needs_you`)

    /// The tool's reason for the app's own, when the app signs nothing on a door card. No default: a new case of
    /// `DoorCall.Refusal` is a build error here.
    nonisolated static func cardStop(_ stop: DoorCallSigning.Stop) -> AnswerDoor.CardStop {
        switch stop {
        case .olderHub: return .olderHub
        case .card(.noScript): return .noScript
        case .card(.otherServer): return .otherServer
        case .card(.hidden(let code)): return .hidden(code)
        case .card(.padded): return .padded
        case .card(.decoy): return .decoy
        case .card(.notShown): return .notShown
        case .card(.otherHash): return .otherHash
        }
    }

    /// The facts of an item that the tool decides by: its answer, the option that answered it, its door call and its
    /// server, from the item that the app reads as its cards read it.
    nonisolated static func card(_ need: OwnerNeed) -> AnswerDoor.Card {
        AnswerDoor.Card(open: need.answer == nil, chosen: need.chosen, doorCall: !(need.door_call ?? "").isEmpty,
                        host: need.door_host)
    }

    /// **The owner's signature of one press**, by the rule of the owner's own press (`DoorCallSigning.maker`), with
    /// the reason when it signs nothing: the features of the hub that the store still shows, the card, the fleet's id
    /// from the vault's reading, this Mac's owner key, and the signature. Nothing is sent here.
    static func signDoor(_ need: OwnerNeed, _ press: AnswerDoor.Press, place: Place,
                         store: FleetStore?) async -> AnswerDoor.Signed {
        guard let shown = features(of: store, at: place) else { return .moved }
        let make: (String) -> String
        switch DoorCallSigning.maker(for: need, choice: Int(press.rawValue), features: shown) {
        case nil: return .notOffered
        case .success(let found)?: make = found
        case .failure(let stop)?: return .card(cardStop(stop))
        }
        let reading: VaultReading?
        do { reading = try await VaultClient().reading(hub: place.hub, database: place.database) }
        catch { return .vaultUnread }
        guard let fleet = reading?.fleetID else { return .noFleet }
        guard OwnerKeychain.isHeld(fleet: fleet) else { return .noOwnerKey }
        let statement = make(fleet)
        guard let key = OwnerKeychain.key(fleet: fleet), let signature = try? key.sign(statement) else {
            return .notSignedNow
        }
        return .signed(statement: statement, signature: signature)
    }

    /// **The app's engine for a door card's signed press of `answer_needs_you`**, closure by closure
    /// (`AnswerDoor.Desk`). Each request ends by the time limit of its own client (the state's read and the answer 10
    /// seconds for a request and 15 in all, `HubClient`; the vault's read 20 and 30). No closure writes anything of a
    /// request to the log, and none shows anything on the screen: the card goes from Needs you at the store's next
    /// reading, as after the owner's own press on another of his devices.
    static func doorDesk(store: @escaping @MainActor () -> FleetStore?) -> AnswerDoor.Desk<Place, OwnerNeed> {
        let lists = HubClient()
        return AnswerDoor.Desk<Place, OwnerNeed>(
            // A current reading with a database, as for `save_bot_token`: a door card is no page of Secrets.
            ready: {
                guard let store = store(), store.isFresh, let database = store.state?.db else { return nil }
                return Place(hub: store.hub, database: database, client: store.installation)
            },
            database: { $0.database },
            // One read of the hub's state, whole, as the store reads it, and the item of this id, as its cards read
            // it. A read that failed, and bytes that are no state, are thrown as they are.
            item: { place, need in
                let state = try await lists.stateReading(at: place.hub).state
                guard state.db == place.database else { return .otherGeneration }
                guard let found = state.needs.first(where: { $0.id == need }) else { return .none }
                return .found(found, card(found))
            },
            sign: { place, need, press in await signDoor(need, press, place: place, store: store()) },
            // The answer as the owner's own press sends it (`FleetStore.answer(_:choice:)`): the item's id, the
            // option, and the signed statement beside it, under a new request id of the app. It is no request of the
            // outbox: nothing of it is kept on disk, and the store's own sends are not touched. The hub's refusal of
            // an item that has its answer (its code `request_answered`, as the form reads it) is the tool's own error.
            send: { place, need, press, statement, signature in
                let request = PendingRequest(hub: place.hub, database: place.database, client: place.client,
                                             needID: need, choice: Int(press.rawValue),
                                             approval: (statement, signature), text: "")
                do {
                    _ = try await lists.send(request)
                } catch HubError.refusal(let refused) where refused.status == 409 && refused.means(.requestAnswered) {
                    throw AnswerSecret.Answered()
                } catch {
                    throw failure(error)
                }
            },
            // Started, and not waited for, as `secretDesk`'s.
            refresh: {
                guard let store = store() else { return }
                Task { @MainActor in await store.refresh() }
            })
    }

    // ------------------------------------------------------------ the report form (`prepare_problem_report`)

    /// **Puts the agent's text into the report form** (`ReportProblemView`): the ask goes into the store, the app's
    /// report window opens and comes to the front (`AppFront.come`, so the window takes no key press until the
    /// owner's click), and the form takes the ask and says how (`ReportAsk.outcome`). The wait has no clock: it ends
    /// on the form's outcome, on another ask in its place, or on the end of the call.
    static func showReport(_ text: String, store: FleetStore?) async -> PrepareReport.Outcome {
        guard let store, let open = store.openReportWindow else { return .noWindow }
        let ask = ReportAsk(text: text)
        store.reportAsk = ask
        AppFront.come { open() }
        let once = ReportOnce()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { resume in
                once.resume = resume
                watch(report: ask.id, in: store, once: once)
            }
        } onCancel: {
            Task { @MainActor in once.finish(nil) }
        }
        if store.reportAsk?.id == ask.id { store.reportAsk = nil }
        switch outcome {
        case .shown?: return .shown
        case .ownText?: return .ownText
        case nil: return .ended
        }
    }

    /// The wait for the form's outcome: it ends once.
    @MainActor private final class ReportOnce: Sendable {
        nonisolated(unsafe) var resume: CheckedContinuation<ReportAsk.Outcome?, Never>?

        func finish(_ outcome: ReportAsk.Outcome?) {
            guard let resume else { return }
            self.resume = nil
            resume.resume(returning: outcome)
        }
    }

    private static func watch(report id: UUID, in store: FleetStore, once: ReportOnce) {
        guard store.reportAsk?.id == id else { return once.finish(nil) }
        if let outcome = store.reportAsk?.outcome { return once.finish(outcome) }
        withObservationTracking { _ = store.reportAsk } onChange: {
            Task { @MainActor in watch(report: id, in: store, once: once) }
        }
    }

    // ------------------------------------------------------------ the clipboard (`from` clipboard)

    /// One read at a time: a call that comes while macOS's question of an earlier one is up gets `busy`. One gate
    /// for `save_bot_token` and `save_secret`: the clipboard is one, whichever tool reads it.
    private static let gate = SaveBotToken.ClipboardGate()

    /// **One read of the clipboard**, for `save_bot_token` and `save_secret` with `from` clipboard, which read it only
    /// after every other check passed. On macOS 15.4 and later the owner's setting can deny the app the clipboard
    /// (`accessBehavior`): then nothing is read. Else the change count, the text, and the change count again; when the two counts differ,
    /// something wrote the clipboard during the read, and the read gives nothing. **It reads one time and never
    /// again**: when macOS asks, each read of new content is one more question, and one call brings one question at
    /// most. Nothing of the clipboard goes to a log.
    ///
    /// **It runs on the main thread, and it must.** Measured in this app on a test Mac (macOS 26.6.2, 14 November
    /// 2026): as macOS is today (`alwaysAllow`) a read gives the text at once. With macOS's `ask` behaviour switched on
    /// (the default of a later macOS), a read with no paste of the owner shows macOS's own alert ("Allow Paste",
    /// "Don't Allow Paste") and waits for the owner's answer with no limit; AppKit runs that wait on the calling
    /// thread, and on a thread that is not the main one it ends the app with an exception (`-[HIRunLoopSemaphore
    /// wait:] has been invoked on a secondary thread`). So this read is never moved to another thread. While the alert
    /// is up, the main thread is held in it. "Don't Allow Paste" gives nil, which is `nothing` here. A call whose
    /// caller went away before or during the wait sends nothing (`SaveBotToken.answer` and `SaveSecret.answer` check
    /// for a cancel before and after the read).
    static func readPasteboard() -> SaveBotToken.Clipboard {
        let board = NSPasteboard.general
        if #available(macOS 15.4, *), board.accessBehavior == .alwaysDeny { return .notAllowed }
        let before = board.changeCount
        let text = board.string(forType: .string)
        guard board.changeCount == before else { return .nothing }
        // A text above a value part's bound is no token and no secret's value: it never goes on to the tool's checks.
        // Its length here is the text's own stored count (UTF-16 units), with no pass over a clipboard of any size;
        // the tool's logic then holds it to the bound in bytes. The text goes on as it is: nothing is taken off it.
        guard let text, !text.isEmpty, (text as NSString).length <= OwnerChannel.valueMax else { return .nothing }
        return .text(text, count: before)
    }

    /// **Clears the clipboard after a confirmed save**, only when its change count is still the read's, and says
    /// whether it cleared. The limit that stays: a process that writes the clipboard between the compare and the clear
    /// loses its text, and a clipboard manager's history keeps its own copy of the token or of the secret's value.
    static func clearPasteboard(ifStill count: Int) -> Bool {
        let board = NSPasteboard.general
        guard board.changeCount == count else { return false }
        return board.clearContents() > count                  // the new count: the clear took place
    }

    /// The client's error as the tool's logic reads it: the hub's status and its own words (its route refuses in fixed
    /// sentences; a status of 500 or more is an outcome that is not known), no answer, or an answer that could not be
    /// read.
    nonisolated static func failure(_ error: Error) -> SaveBotToken.HubFailure {
        switch error {
        case HubError.refusal(let refused): return .refused(refused.status, refused.hubWords)
        case is URLError, HubError.unavailable: return .noAnswer
        default: return .unreadable
        }
    }
}
