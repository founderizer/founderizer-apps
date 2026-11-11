import Darwin
import FleetVaultIPC
import Foundation
import Security

public actor VaultBroker {
    public let configuration: VaultConfiguration
    private let keychain: VaultKeychain
    private let identity: VaultIdentity
    private let hub: VaultHub
    /// The bundled `age` and `age-keygen`, which lock a handover and the fleet's own store.
    private let helpers: URL
    /// The logins that this machine made (`create`), with their journal in the helper's Keychain group.
    private var journal: VaultWriter?
    /// The requests that this machine sends (`request`), with their journal in the same group. A `cancel` uses it
    /// without this actor, so it does not wait for a job that runs.
    nonisolated let calls: VaultCalls

    public init(configuration: VaultConfiguration, bundle: Bundle = .main) {
        self.init(configuration: configuration, bundle: bundle, protocolClasses: nil)
    }

    /// `protocolClasses` and `calls` only for tests: a fake hub in place of the network, and a journal in memory.
    init(configuration: VaultConfiguration, bundle: Bundle, protocolClasses: [AnyClass]?, calls: VaultCalls? = nil) {
        self.configuration = configuration
        keychain = VaultKeychain(agent: configuration.agent)
        helpers = bundle.bundleURL.appendingPathComponent("Contents/Helpers")
        identity = VaultIdentity(keychain: keychain, programs: helpers)
        hub = VaultHub(configuration: configuration, protocolClasses: protocolClasses)
        self.calls = calls ?? VaultCalls(store: VaultJournalKeychain(keychain: keychain, item: "calls"))
    }

    /// What this vault needs before it asks the hub anything: the fleet's own store on this machine. It needs no
    /// owner step, as a Linux machine's `store-init` is part of its install: the first request makes the store key,
    /// the handover key and an empty store, and a key or a store that is there is kept, because a new key would leave
    /// every saved value unreadable.
    private func ready() throws {
        try identity.createIfMissing()
        _ = try openedStore()
    }

    /// What opens this broker's logins, made for one request: the fleet's own store (`vault.py`'s `opened_store`). A
    /// store that does not open refuses here, before the hub's one-use job is spent.
    private func openedStore() throws -> any VaultStore {
        try VaultLocalStore(keychain: keychain, programs: helpers)
    }

    public func handle(_ data: Data, uid: uid_t) async -> Data {
        do {
            guard uid == configuration.workerUID else { throw VaultFailure.request }
            let request = try VaultRequest(data: data)
            if request.operation == .cancel { return cancel(data, uid: uid) }
            if request.operation == .chrome {
                // One harmless script, in the setup of a Mac: macOS asks its question for this app now, with a person
                // there, because a later sign-in has nobody to answer it.
                let answered = await VaultBrowser.scriptable()
                return try JSONSerialization.data(withJSONObject: ["ok": answered, "v": 2]) + Data([10])
            }
            // This request's caller is a local value: a request that overlaps at an await never sees it.
            let caller = Self.caller(for: request, configuration: configuration)
            let response: [String: Any]
            if request.operation == .status {
                try ready()
                response = Self.status(agent: configuration.agent, user: NSUserName(), recipient: try identity.recipient(),
                                       creates: true, requests: VaultCurl.isAvailable, deposits: true, withdrawals: true)
            } else if request.operation == .request {
                // Local setup first, as for a sign-in: the hub confirms the job once, and that is not used up for nothing.
                try ready()
                guard calls.recover() else { throw VaultFailure.keychain }
                guard VaultCurl.isAvailable else { throw VaultFailure.dependency }
                _ = try identity.recipient()
                let store = try openedStore()
                let reply = await Self.call(request, as: caller, hub: hub, calls: calls) { job in
                    try await self.savedLogin(for: job, operation: .request, caller: caller, store: store).login
                }
                return try JSONSerialization.data(withJSONObject: reply) + Data([10])
            } else if request.operation == .create || request.operation == .capture {
                // The machine's own store comes first: without it, nothing is asked and nothing is made.
                guard (try? ready()) != nil else { throw VaultFailure.creates }
                let reply = await Self.create(request, as: caller, hub: hub, writer: try saves(), address: configuration.hub.absoluteString) {
                    page, selector in try await VaultBrowser.capture(page: page, selector: selector)
                }
                return try JSONSerialization.data(withJSONObject: reply) + Data([10])
            } else if request.operation == .deposit {
                // A store or a key that does not open refuses here, before the hub gives the copy.
                try ready()
                _ = try identity.recipient()
                let store = try VaultLocalStore(keychain: keychain, programs: helpers), opener = identity
                let reply = await Self.deposit(request, as: caller, hub: hub, unseal: { try opener.open($0) }) {
                    try store.put(id: $0, name: $1, value: $2, note: VaultLocalStore.delivered)
                }
                return try JSONSerialization.data(withJSONObject: reply) + Data([10])
            } else if request.operation == .withdraw {
                // A store that does not open refuses here, before the hub's job is used.
                let store = try VaultLocalStore(keychain: keychain, programs: helpers)
                let reply = await Self.withdraw(request, as: caller, hub: hub) { try store.remove(id: $0, note: VaultLocalStore.delivered) }
                return try JSONSerialization.data(withJSONObject: reply) + Data([10])
            } else if request.operation == .read {
                // Local setup first: without this machine's store nothing is asked.
                try ready()
                let store = try openedStore()
                let reply = await Self.read(as: caller, hub: hub) { try store.secret(id: $0) }
                return try JSONSerialization.data(withJSONObject: reply) + Data([10])
            } else if request.operation == .probe {
                // A vault whose store does not open opens nothing, and says so for each login with the fixed code of a
                // vault that has nothing to open with (`no_token`, the same code as the Linux broker's).
                let store = try? openedStore()
                let job = try await hub.confirmProbe(request, as: caller)
                let results = store.map { $0.probe(job: job) }
                    ?? job.logins.map { VaultProbeResult(login: $0, reason: .no_token) }
                struct Reply: Encodable { let ok = true; let v = 2; let job: Int; let results: [VaultProbeResult] }
                return try JSONEncoder().encode(Reply(job: job.id, results: results)) + Data([10])
            } else {
                // Check local setup before consuming a one-use job, then ask the hub before reading a login.
                try ready()
                _ = try identity.recipient()
                let store = try openedStore()
                let job = try await hub.confirm(request, as: caller)
                let (login, source) = try await savedLogin(for: job, operation: request.operation, caller: caller, store: store)
                if request.operation == .handover, let expected = job.source, source != expected { throw VaultFailure.sourceMismatch }
                try await hub.protect(login, job: job, as: caller)
                switch request.operation {
                case .signin:
                    let authenticator = try await VaultBrowser.signIn(login)
                    response = ["ok": true, "v": 2, "job": job.id, "origin": login.origin,
                                "label": login.label, "authenticator": authenticator]
                case .handover:
                    let stamp = VaultProvenance.stamp(job: job.id, project: job.project, source: source)
                    let ciphertext = try identity.seal(login.sealedPayload(provenance: stamp), recipient: job.recipient!)
                    guard login.protectedValues.allSatisfy({ !ciphertext.contains($0.value) }) else {
                        throw VaultFailure.handover
                    }
                    response = ["ok": true, "v": 2, "job": job.id, "to": job.target!,
                                "label": login.label, "ciphertext": ciphertext]
                case .status, .chrome, .probe, .create, .capture, .request, .cancel, .read, .deposit, .withdraw: throw VaultFailure.request
                }
                // Metadata is untrusted too. A vault item can put its password in its name or URL.
                let encoded = try JSONSerialization.data(withJSONObject: response)
                let text = String(decoding: encoded, as: UTF8.self)
                for (_, value) in login.protectedValues {
                    let escaped = try VaultBrowser.jsonString(value).dropFirst().dropLast()
                    guard !text.contains(value), !text.contains(escaped) else { throw VaultFailure.login }
                }
                return encoded + Data([10])
            }
            return try JSONSerialization.data(withJSONObject: response) + Data([10])
        } catch {
            let message = (error as? VaultFailure)?.rawValue ?? "The vault could not complete this job."
            return try! JSONSerialization.data(withJSONObject: ["ok": false, "v": 2, "error": message]) + Data([10])
        }
    }

    /// The login of a confirmed job, after the checks of its use, and the reference of the store that it comes from.
    private func savedLogin(for job: VaultJob, operation: VaultRequest.Operation, caller: VaultCaller,
                            store: any VaultStore) async throws -> (login: VaultLogin, source: String?) {
        if job.createdBy != nil {
            // The hub allows this use only because a job of the same task made the login, and the hub knows that from
            // the helper's report. This vault's own journal must have that creation with this login, and a key that
            // was read on another address is not used there by that permission.
            if let refusal = await Self.refusal(ofMadeUse: job, operation: operation, caller: caller, writer: try saves()) { throw refusal }
        }
        // A login on a model provider's own site is never used, whoever saved it (`vault.py`'s `check_login`).
        if job.login.hasPrefix("bws://") {
            return (try VaultProviderSites.checked(try store.login(secretID: String(job.login.dropFirst(6)))), job.login.lowercased())
        }
        // A copy is used only after its provenance matches the hub's record and this job's project.
        let (ciphertext, label, record) = try await hub.sealed(job, as: caller)
        let payload = try identity.open(ciphertext)
        let source = try VaultProvenance.check(payload: payload, record: record, usingProject: job.project)
        return (try VaultProviderSites.checked(try VaultLogin(data: payload, label: label)), source)
    }

    /// The `cancel` operation: the requests of one task attempt end, and no later one starts. It asks the hub nothing,
    /// because the end of a request is always safe, and it does not wait for a job that runs. Only a caller with the
    /// agent key of a request ends that request (`VaultCallScope`). `stopped` is said only after the vault itself took
    /// the status of each child that it ended.
    public nonisolated func cancel(_ data: Data, uid: uid_t) -> Data {
        var reply: [String: Any]
        do {
            guard uid == configuration.workerUID else { throw VaultFailure.request }
            let request = try VaultRequest(data: data)
            guard request.operation == .cancel, let scope = request.scope else { throw VaultFailure.request }
            guard let ended = calls.cancel(scope) else { throw VaultFailure.cancelUnproved }
            reply = ["ok": true, "v": 2, "task": scope.task, "attempt": scope.attempt, "stopped": true, "ended": ended]
        } catch {
            reply = ["ok": false, "v": 2, "error": (error as? VaultFailure)?.rawValue ?? "The vault could not complete this job."]
        }
        return try! JSONSerialization.data(withJSONObject: reply) + Data([10])
    }

    /// The agent that a job acts for at the hub: the request's caller with its key or, for a request without caller
    /// fields, the configured store agent without a credential, as before shared brokers.
    static func caller(for request: VaultRequest, configuration: VaultConfiguration) -> VaultCaller {
        request.caller ?? VaultCaller(agent: configuration.agent, key: nil)
    }

    /// `backend` says which store this broker opens: always `store`, the fleet's own on this machine. The hub and
    /// `fleet.py check <agent>` read this word, so it stays in every answer. The store's identity does not change;
    /// `callers` says that this broker accepts job requests that name a caller.
    /// `creates` and `captures` say that the vault can make a login (`create`) and save a key that a page shows
    /// (`capture`). `requests` says that this broker sends requests with a saved value (`request`) and ends them
    /// (`cancel`). `deposits` says that it takes a key or a login that the owner delivers from Founderizer (`deposit`),
    /// and `withdrawals` that it gives such a secret back when no agent of the machine holds it any more (`withdraw`).
    /// The hub asks a machine for a withdrawal only when its broker says `withdrawals`.
    static func status(agent: String, user: String, recipient: String, creates: Bool = false, requests: Bool = false,
                       deposits: Bool = false, withdrawals: Bool = false) -> [String: Any] {
        var status: [String: Any] = ["ok": true, "v": 2, "agent": agent, "store": "keychain", "backend": VaultBackend.store.rawValue,
                                     "user": user, "recipient": recipient, "callers": true]
        if creates { status["creates"] = true; status["captures"] = true }
        if requests { status["requests"] = true }
        if deposits { status["deposits"] = true }
        if withdrawals { status["withdrawals"] = true }
        return status
    }

    private func saves() throws -> VaultWriter {
        if let journal { return journal }
        let keychain = keychain, helpers = helpers
        // The fleet's own store makes a login by itself: no library, no project and no one-time setup.
        let session: @Sendable () throws -> (items: any VaultItems, project: String) = {
            guard let store = try? VaultLocalStore(keychain: keychain, programs: helpers) else { throw VaultWriteRefusal.setup }
            return (store, VaultLocalStore.place)
        }
        let made = try VaultWriter(store: VaultJournalKeychain(keychain: keychain), limit: 1_048_576, session: session)
        journal = made
        return made
    }

    /// The `create` and `capture` operations: one new login for a confirmed job of the calling agent. For a create
    /// the vault makes the password. For a capture it reads the key from the page (`read`: the page's address, as the
    /// hub confirmed it, and the selector give the value), and only when its journal has no record of the request: a
    /// known request never reads a page again, and the journal sends at most one create call for a request also when
    /// two calls come together.
    /// The answer is the login's reference, or one fixed sentence. `unknown` says that the item can exist: the same
    /// request again only looks for it, or finishes the hub's steps, and never sends a second create call.
    static func create(_ request: VaultRequest, as caller: VaultCaller, hub: VaultHub, writer: VaultWriter, address: String,
                       read: @Sendable (String, String) async throws -> String = { _, _ in throw VaultFailure.browser }) async -> [String: Any] {
        func refused(_ failure: VaultFailure) -> [String: Any] { ["ok": false, "v": 2, "error": failure.rawValue] }
        func unknown(_ failure: VaultFailure) -> [String: Any] { ["ok": false, "v": 2, "unknown": true, "error": failure.rawValue] }
        let job: VaultCreateJob
        do { job = try await hub.confirmCreate(request, as: caller) } catch { return refused((error as? VaultFailure) ?? .hub) }
        let made = job.creation
        // No login is made, and no page is read, on a model provider's own site (`vault.py`'s `creation`).
        guard !VaultProviderSites.contains(address: made.url), !VaultProviderSites.contains(address: made.source) else {
            return refused(.modelProvider)
        }
        // A capture reads its page before the writer's step, and only for a request that the journal does not know.
        var captured: String?
        if made.kind == .capture, await writer.record(requestID: made.requestID) == nil {
            guard made.readOrigin != nil, let selector = made.selector else { return refused(.hub) }
            do { captured = try await read(made.source ?? made.url, selector) } catch { return refused((error as? VaultFailure) ?? .browser) }
        }
        let record: VaultWriteRecord
        do {
            let key = captured
            record = try await writer.create(requestID: made.requestID, binding: made.binding, title: made.label, hub: address, db: made.db,
                                             mark: job.mark) {
                switch made.kind {
                case .create: return try made.value()
                case .capture:
                    // No value: another call made the record after this one looked. The journal then gives that record.
                    guard let key else { throw VaultWriteRefusal.request }
                    return try made.value(password: key)
                }
            }
        } catch VaultWriteRefusal.check { return unknown(.saveUnknown) }
        catch VaultWriteRefusal.setup { return refused(.creates) }
        catch let refusal as VaultWriteRefusal { return ["ok": false, "v": 2, "error": refusal.rawValue] }
        catch { return refused((error as? VaultFailure) ?? .dependency) }
        switch record.state {
        case .failed, .discarded: return refused(.saveRefused)
        case .creating, .unknown: return unknown(.saveUnknown)
        case .created, .registered:
            guard let login = record.login else { return unknown(.saveUnknown) }
            if record.state == .created {
                // The hub learns the reference and gets the fingerprints before the helper gets the answer. The item
                // exists now, so every failure here stays `unknown`, also a refused key: the same request again
                // finishes these steps, and the job must not close as failed.
                do {
                    let salts = try await hub.created(job: job.id, login: login, as: caller)
                    let prints = try await writer.fingerprints(requestID: record.request_id, salts: salts)
                    if !prints.items.isEmpty { try await hub.protect(prints.items, job: job.id, as: caller) }
                    _ = try await writer.close(requestID: record.request_id, registered: true)
                } catch VaultFailure.key { return unknown(.key) } catch { return unknown(.saveUnregistered) }
            }
            return ["ok": true, "v": 2, "job": job.id, "login": login]
        }
    }

    /// The `request` operation: one request to the origin of a saved login, with its value. The order of the steps
    /// keeps the value in the vault until the request is on record: the hub's confirmation, the login and its
    /// fingerprints, a curl child that waits, the journal's record of that child, and only then the request itself.
    /// "Nothing was sent" is certain: the child got no request, or curl did not find or did not reach the host. Every
    /// other end without a complete answer is `unknown`, also a timeout. A request is never started a second time.
    /// `limit`: the seconds of the transfer. `plain`: the hosts that are reached without TLS.
    static func call(_ request: VaultRequest, as caller: VaultCaller, hub: VaultHub, calls: VaultCalls, limit: Int = 60,
                     plain: @Sendable (String) -> Bool = VaultConfiguration.privateHost,
                     login: @Sendable (VaultJob) async throws -> VaultLogin) async -> [String: Any] {
        func refused(_ failure: VaultFailure?) -> [String: Any] {
            ["ok": false, "v": 2, "error": failure?.rawValue ?? "The vault could not complete this job."]
        }
        func unknown(_ failure: VaultFailure) -> [String: Any] { ["ok": false, "v": 2, "unknown": true, "error": failure.rawValue] }
        let job: VaultJob, call: VaultCall, scope: VaultCallScope, plan: VaultCall.Plan
        do {
            (job, call) = try await hub.confirmCall(request, as: caller)
            guard let named = VaultCallScope(db: call.db, task: job.task, attempt: call.attempt, caller: caller) else { return refused(.caller) }
            scope = named
            // A request that was started, and a stopped task attempt, read no login. The first one can have been
            // sent, so its answer is never that nothing was sent.
            switch calls.refusal(of: call, scope: scope) {
            case .repeated?: return unknown(.callRepeated)
            case .stopped?: return refused(.callStopped)
            case .unsaved?: return refused(.keychain)
            case .started?, nil: break
            }
            let saved = try await login(job)
            try await hub.protect(saved, job: job, as: caller)
            plan = try call.plan(for: saved, limit: limit, plain: plain)
        } catch { return refused(error as? VaultFailure) }
        guard let child = try? VaultCurl.start(withBody: plan.body != nil) else { return refused(.dependency) }
        // The child waits and has nothing. It gets its request only when the journal has it and no `cancel` named it.
        let entry: VaultCalls.Running
        switch calls.begin(job: job.id, call: call, scope: scope, child: child) {
        case .started(let started): entry = started
        case let other:
            child.abandon()
            switch other {
            case .repeated: return unknown(.callRepeated)
            case .stopped: return refused(.callStopped)
            default: return refused(.keychain)
            }
        }
        guard calls.release(entry) else {
            child.abandon()
            calls.end(entry)
            return refused(.callStopped)
        }
        // From here the request can be on its way: only curl's own answer says something else.
        let keep = VaultAnswer.keep(for: plan.forms)
        let result = await withCheckedContinuation { (done: CheckedContinuation<VaultCurl.Result, Never>) in
            DispatchQueue.global().async { done.resume(returning: child.run(plan, keep: keep, limit: limit)) }
        }
        let canceled = calls.end(entry)
        if result.exit == 0, let status = VaultAnswer.status(in: result.note) {
            return VaultAnswer.reply(job: job.id, status: status, kept: result.kept, total: result.total, forms: plan.forms)
        }
        // curl's exit status 6 and 7: the host's name was not found, and no connection was made.
        if result.exit == 6 || result.exit == 7 { return refused(.callUnreachable) }
        if result.exit == nil, canceled { return unknown(.callCanceled).merging(["canceled": true]) { _, new in new } }
        return unknown(.callUnknown)
    }

    /// The `deposit` operation (owner feature `central_vault`): one key or login that the owner typed into
    /// Founderizer, sealed by the central vault to this machine's pinned vault key, goes into this machine's own store under the
    /// reference that it has in the owner's vault. The helper names only the delivery. The hub gives the copy, which is
    /// opened here (`unseal`); the hub compares the fingerprints of what it holds with the owner's before anything is
    /// saved (`put`: the store's id, the name and the value), and the store refuses another value under that reference.
    /// The answer holds no part of the value: `saved` is `new`, or `same` when this vault had it already.
    static func deposit(_ request: VaultRequest, as caller: VaultCaller, hub: VaultHub, unseal: (Data) throws -> Data,
                        put: (String, String, String) throws -> String) async -> [String: Any] {
        func refused(_ failure: VaultFailure) -> [String: Any] { ["ok": false, "v": 2, "error": failure.rawValue] }
        let delivery: VaultDeposit
        do { delivery = try await hub.confirmDeposit(request, as: caller) } catch { return refused((error as? VaultFailure) ?? .hub) }
        let value: (stored: String, secret: VaultSecret)
        do {
            guard let payload = try? unseal(delivery.ciphertext) else { throw VaultFailure.depositCopy }
            value = try VaultDeposit.value(payload, item: delivery.item)
        } catch { return refused((error as? VaultFailure) ?? .depositItem) }
        do { try await hub.compare(value.secret, deposit: delivery, as: caller) } catch {
            return refused((error as? VaultFailure) ?? .depositValue)
        }
        let saved: String
        do { saved = try put(delivery.storeID, delivery.title, value.stored) } catch { return refused((error as? VaultFailure) ?? .store) }
        return ["ok": true, "v": 2, "deposit": delivery.id, "login": delivery.login, "saved": saved]
    }

    /// The `withdraw` operation (helper feature `secret_withdrawals`): one secret that the owner's vault delivered into
    /// this machine's store, and that no agent of this machine holds any more, leaves that store. The helper names only
    /// the withdrawal; the hub names the reference, and `remove` takes the item out only when a delivery saved it. The
    /// answer is `removed`, or `absent` when the store did not have it, so a withdrawal that is asked again ends the
    /// same way (`vault.py`'s `withdraw`).
    static func withdraw(_ request: VaultRequest, as caller: VaultCaller, hub: VaultHub,
                         remove: (String) throws -> String) async -> [String: Any] {
        func refused(_ failure: VaultFailure) -> [String: Any] { ["ok": false, "v": 2, "error": failure.rawValue] }
        let withdrawal: VaultWithdrawal
        do { withdrawal = try await hub.confirmWithdrawal(request, as: caller) } catch { return refused((error as? VaultFailure) ?? .hub) }
        let removed: String
        do { removed = try remove(withdrawal.storeID) } catch { return refused((error as? VaultFailure) ?? .store) }
        return ["ok": true, "v": 2, "withdrawal": withdrawal.id, "login": withdrawal.login, "removed": removed]
    }

    /// The `read` operation (owner feature secrets): the API keys that the calling agent reads in its sessions, as
    /// `{variable name: value}`. The hub names them for the caller now; the vault reads each value itself and registers
    /// its fingerprints before it gives it, so that the hub masks it in texts. A value that it cannot read or protect is
    /// in `missing`. The answer has values: the worker's user may read exactly these.
    static func read(as caller: VaultCaller, hub: VaultHub, value: (String) throws -> VaultSecret) async -> [String: Any] {
        let named: [VaultRead]
        do { named = try await hub.confirmRead(as: caller) } catch {
            return ["ok": false, "v": 2, "error": ((error as? VaultFailure) ?? .hub).rawValue]
        }
        var env: [String: String] = [:], missing: [String] = []
        for item in named {
            do {
                let secret = try value(String(item.login.dropFirst(6)))
                try await hub.protect(secret, read: item, as: caller)
                env[item.env] = secret.password
            } catch { missing.append(item.env) }
        }
        return ["ok": true, "v": 2, "env": env, "missing": missing]
    }

    /// True when this vault's own journal has the creation that the hub names for a sign-in (`created_by`), with the
    /// job's reference, for the calling agent. Only then does the vault read and use the login for that exception.
    static func madeHere(_ job: VaultJob, operation: VaultRequest.Operation, caller: VaultCaller, writer: VaultWriter) async -> Bool {
        await refusal(ofMadeUse: job, operation: operation, caller: caller, writer: writer) == nil
    }

    /// Why the vault does not use a login by the permission of the task that made it, or nil. The journal comes
    /// first. Then the address: a key that was read on one origin and is used on another gets nothing from this
    /// permission. The owner's grant, which has no `created_by`, does not come here and does not change.
    static func refusal(ofMadeUse job: VaultJob, operation: VaultRequest.Operation, caller: VaultCaller, writer: VaultWriter) async -> VaultFailure? {
        guard let made = job.createdBy, [.signin, .request].contains(operation), made.agent == caller.agent, job.login.hasPrefix("bws://"),
              await writer.made(requestID: made.requestID, binding: made.binding, login: job.login) else { return .notMadeHere }
        return made.usesItsSource ? nil : .captureUse
    }

    public static func loadConfiguration() throws -> VaultConfiguration {
        let config = try VaultConfiguration(data: protectedConfiguration())
        guard config.workerUID == getuid() else { throw VaultFailure.configuration }
        return config
    }

    /// The bytes of the one configuration file, after the checks of its whole path. The worker broker reads it, and on
    /// the owner's Mac it only says that this Mac is the owner's (`VaultOldItems.isOwner`).
    static func protectedConfiguration() throws -> Data {
        let path = "/Library/Application Support/Fleet Vault/config.json"
        // Check the entire path: a root-owned file in an agent-writable folder is not protected.
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_uid == 0,
                  info.st_mode & 0o022 == 0, info.st_mode & S_IFMT != S_IFLNK else { throw VaultFailure.configuration }
            current.deleteLastPathComponent()
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VaultFailure.configuration }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0, info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size < 8192,
              let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() else { throw VaultFailure.configuration }
        return data
    }

    public static func verifySignature(bundle: Bundle = .main) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        let expected = "anchor apple generic and certificate leaf[subject.OU] = \"6EBZ756H9Q\" and identifier \"local.agent-fleet.vault\""
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(expected as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw VaultFailure.dependency
        }
    }
}

public final class VaultSocket: @unchecked Sendable {
    private let config: VaultConfiguration
    private let handle: @Sendable (Data, uid_t) async -> Data
    private let cancel: @Sendable (Data, uid_t) -> Data
    private let recover: @Sendable () -> Void
    private var listener: Int32 = -1
    /// One job at a time, in the order in which the requests come.
    private let jobs = DispatchQueue(label: "fleet.vault.jobs")
    /// The connections that are open: those that the vault reads, serves or keeps for their turn.
    private let open = DispatchSemaphore(value: 64)

    public convenience init(configuration: VaultConfiguration, broker: VaultBroker) {
        self.init(configuration: configuration, handle: { await broker.handle($0, uid: $1) }, cancel: { broker.cancel($0, uid: $1) },
                  recover: { broker.calls.recover() })
    }

    /// `handle` and `cancel` apart only for tests: a job that takes long, without a Keychain.
    init(configuration: VaultConfiguration, handle: @escaping @Sendable (Data, uid_t) async -> Data,
         cancel: @escaping @Sendable (Data, uid_t) -> Data, recover: @escaping @Sendable () -> Void = {}) {
        config = configuration; self.handle = handle; self.cancel = cancel; self.recover = recover
    }

    public func start() throws {
        let folder = URL(fileURLWithPath: config.socket).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = stat()
        guard lstat(folder.path, &directory) == 0, directory.st_uid == getuid(),
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_mode & 0o077 == 0 else { throw VaultFailure.socket }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard config.socket.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw VaultFailure.socket }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            config.socket.utf8CString.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        func withAddress<T>(_ action: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
            withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                action($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            } }
        }
        var existing = stat()
        if lstat(config.socket, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid() else { throw VaultFailure.socket }
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw VaultFailure.socket }
            let alive = withAddress { Darwin.connect(probe, $0, $1) } == 0
            close(probe)
            guard !alive else { throw VaultFailure.socket }
            guard unlink(config.socket) == 0 else { throw VaultFailure.socket }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VaultFailure.socket }
        let previous = umask(0o077)
        let bound = withAddress { Darwin.bind(fd, $0, $1) }; umask(previous)
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { close(fd); throw VaultFailure.socket }
        listener = fd
        DispatchQueue(label: "fleet.vault.socket").async {
            // Before the first request: what an earlier vault process left is ended.
            self.recover()
            self.serve(fd)
        }
    }

    private func serve(_ fd: Int32) {
        while true {
            let peer = accept(fd, nil, nil)
            if peer < 0 { if errno == EINTR { continue }; return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(peer, &uid, &gid) == 0, uid == config.workerUID, open.wait(timeout: .now()) == .success else { close(peer); continue }
            // Each connection is read apart from the others: a `cancel` does not wait for a slow line or for a job.
            let requester = uid
            DispatchQueue.global().async {
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
                while data.count <= 8192 && !data.contains(10) {
                    let size = recv(peer, &bytes, min(bytes.count, 8193 - data.count), 0)
                    if size <= 0 { break }; data.append(contentsOf: bytes.prefix(size))
                }
                // One bounded line only; never process a second operation on this connection.
                if data.last != 10 || data.dropLast().contains(10) { data = Data() }
                self.take(data, uid: requester) { reply in
                    reply.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let sent = send(peer, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                            if sent <= 0 { break }; offset += sent
                        }
                    }
                    close(peer); self.open.signal()
                }
            }
        }
    }

    /// One request line and where its reply goes. A `cancel` is served at once, also while a job runs: it must be
    /// able to end that job's request. A `status` reading does not wait either: it only reads, and a helper that gets
    /// no reading in time cannot say what this broker can do. Every other operation waits for its turn, one job at a
    /// time as before.
    func take(_ data: Data, uid: uid_t, reply: @escaping @Sendable (Data) -> Void) {
        let operation = (try? VaultRequest(data: data))?.operation
        if operation == .cancel { return reply(cancel(data, uid)) }
        if operation == .status {
            Task { reply(await self.handle(data, uid)) }
            return
        }
        jobs.async {
            let finished = DispatchSemaphore(value: 0)
            Task {
                reply(await self.handle(data, uid))
                finished.signal()
            }
            finished.wait()
        }
    }
}
