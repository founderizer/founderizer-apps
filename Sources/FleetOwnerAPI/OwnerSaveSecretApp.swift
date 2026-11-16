import Foundation

// **The app's side of `save_secret`** (the secrets plan, step E3; `agent-install-secrets-e-spec-v2.md`, section 3,
// "Order in the app", "The work" and "The desk"): the desk, the answer to one call, the work that outlives its call,
// and the box that holds the value while the work needs it. `OwnerSaveSecret.swift` has the part that both sides
// share: the fields, their forms and every fixed sentence. The tool is in `OwnerLinkTools.names`, and the app calls
// `answer` from its board, with the desk that `LinkTools.secretDesk` wires to the app's own engine.
//
// **What is the call's, and what is the table's.** A call checks: the fields, the table (`LinkWork.check`), the
// value, the fleet's reading, the vault's key, the room in the list, and last the clipboard. All of that is the
// call's own, and the end of the call ends it: nothing was sent. Then the call begins the work (`LinkWork.begin`),
// and from there the work is the table's: the entry in the hub's list, then the value in the vault. The call only
// waits on it (`LinkWork.wait`), and its end ends its wait and never the work.

extension SaveSecret {
    // ------------------------------------------------------------ the desk

    /// **A secret's name in the hub's list**, as the form's own type gives it (`LoginSecret` in FleetCore): its
    /// title ("host · user name" for a login, the variable name for a key), its kind and, for a key, its variable
    /// name. It reaches the list, its git history and the log, and the answer of a save that is done.
    public struct Draft: Equatable, Sendable {
        public let title: String
        public let kind: Kind
        public let variable: String?

        public init(title: String, kind: Kind, variable: String?) {
            self.title = title
            self.kind = kind
            self.variable = variable
        }
    }

    /// **The secret of one call's fields, as the form's own type took it**: its name, and the maker of its item.
    /// The desk gives both in one answer (`Desk.secret`), so the tool has no title of a secret that the type did
    /// not take.
    public struct Secret {
        public let draft: Draft
        /// **The item of the secret with this value**: the bytes that the vault keeps (`LoginSecret.value()`, with
        /// the text as its password or its key), or nil when the type does not take the secret with this value.
        ///
        /// **The maker must keep no reference to the `Data` that it gives.** The tool copies the bytes into its own
        /// box and then writes zeros over that `Data`. The tool cannot do that wipe alone: it reaches only bytes
        /// that no other holder shares. With another holder, the zeros go into a new copy (copy on write), and the
        /// bytes that the holder shares stay as they were.
        public let item: (String) -> Data?

        public init(draft: Draft, item: @escaping (String) -> Data?) {
            self.draft = draft
            self.item = item
        }
    }

    /// **The key that a value is sealed to, or why nothing is sealed now.** Six answers. The first five are the
    /// answers of `VaultSealKey.of` in FleetCore, which this library does not link: the wiring maps that enum to
    /// this one with a `switch` that has no default, so a sixth answer there is a build error in the wiring and
    /// never one of these by mistake. The sixth, `moved`, is the wiring's own, and no answer of that rule.
    public enum SealKey: Equatable, Sendable {
        /// The central vault's key, which is the one that this Mac pinned.
        case key(String)
        case noVault, noPin, otherKey, noRecovery
        /// **The app shows another hub or another database than the one that this call reads with** (or no fleet
        /// at all): the app's own reading moved while the key was read. What the app shows now says nothing about
        /// the hub that the call reads, so nothing says whether that hub serves the vault: this is not `noVault`.
        /// In a call's check it is "not ready", and nothing was sent; in a later run of the work it is "not known".
        case moved
    }

    /// **Whether the hub's list takes one new entry of this name**: the answers of `SecretRoom.of` in FleetCore,
    /// mapped as `SealKey` is.
    public enum Room: Equatable, Sendable { case free, held, full, unread }

    /// **The app's engine for the tool**, as closures, so that a test gives stand-ins. The library does not link
    /// FleetCore, so each call of it is a closure here. `Place` is the hub, the database and the installation that
    /// one save reads and sends with: plain values that can pass to a closure that leaves the main actor for its
    /// request, and that the work keeps for its later runs.
    ///
    /// **Each send must end.** The work runs in the table (`LinkWork`), which uses no clock: a run that never
    /// returns keeps the table busy, and the box with the value alive, until the app quits. So `sealKey`, `room`,
    /// `register`, `intake` and `refresh` must each end by a bounded wait of their own (the time limit of the
    /// request that they make), whatever the hub does. `clearClipboard` must not wait at all. `readClipboard` is
    /// the one closure that can wait with no limit (macOS asks the owner): the tool calls it only in a call,
    /// before the work begins, and never in a run.
    ///
    /// **No closure gets the hub's words to the caller.** A failure of `register` or `intake` is thrown as
    /// `SaveBotToken.HubFailure`; the tool reads only its status, because the hub's words can hold a field's text.
    ///
    /// **`HubFailure.refused` must carry only the hub's own status**: the status that the hub itself answered to
    /// this request, never a number that the wiring made. The first run reads a status under 500 as "nothing was
    /// saved", so a number that the wiring made up for an error of its own would be a false "nothing was saved".
    ///
    /// **An error of `register` or `intake` that is no `HubFailure` counts as "not known"**, as no answer does,
    /// also at the first run, and also for a throw before the send (a command that the app's own code refused to
    /// write). The words then say "not known" where nothing was sent: that is safe, and it costs the caller a call.
    @MainActor
    public struct Desk<Place: Sendable> {
        /// **The secret of these fields as the form's own type holds it, or nil when that type does not take the
        /// fields** (a `LoginSecret` with `problem == nil`). One closure gives the name AND the maker of the item,
        /// so a title is never read from a secret that the type refused: for an address in which the type reads no
        /// host, its title is the WHOLE address, with the path and the query (`SaveSecret.isSite`), and a title
        /// goes into the hub's list. The type has no check of the fields alone (its `problem` wants a value), so
        /// the wiring asks it with a stand-in for the value, which no rule of a field reads; the maker of the item
        /// asks it again with the value itself.
        ///
        /// **The stand-in** is no secret, and it is a text that the type takes as a password: not empty, and of
        /// the value's least length or more. For example the letter x `SaveSecret.valueLeast` times. An empty one
        /// fails safe: the type then takes no fields at all, and every call is refused.
        public var secret: (Fields) -> Secret?
        /// The hub, its database and the installation when the app's reading is current and the hub serves the
        /// form (`store.isFresh`, a state with a database, `SecretEntryView.isOffered`), else nil.
        public var ready: () -> Place?
        /// The key to seal to: the vault's reading (`VaultClient.reading`), the pin that the form uses, through the
        /// reading's fleet id (`CentralVaultPins.recipient(hub:fleet:)`), and `VaultSealKey.of`. A read that
        /// failed is thrown. In a call's check, the tool then says that it could not read the vault's status
        /// (`vaultUnread`), and not that the vault does not answer the hub, which is not known then. In a later
        /// run of the work, the outcome of that run is "not known".
        ///
        /// **`moved`, before the rule is asked**: after the read, the app shows another hub or another database
        /// than this place's. The hub's features, which say whether it serves the vault, are then those of another
        /// hub, so the wiring answers `moved` and never `noVault` for it.
        public var sealKey: (Place) async throws -> SealKey
        /// The room in the hub's list for a new entry of this name: the list's read (`HubClient.team`) and
        /// `SecretRoom.of`. A read that failed is thrown.
        public var room: (Place, Draft) async throws -> Room
        /// The item's bytes sealed to the vault's key (`AgeSeal.seal`), as an armored text, or nil.
        public var seal: (Data, String) -> String?
        /// **The hub's step**: the entry in the list with the fingerprints of the item, under the reference
        /// (`SecretEntryView.register`). The fields are there for an API key's address, which goes with the entry
        /// as the form sends it (`SecretCommand.address(for:features:)`): only for a key, and only while the store
        /// still shows this place's hub and database.
        ///
        /// **The closure must keep no reference to the `Data`**, and nothing that it calls may keep one after the
        /// call. The `Data` is a copy for this one call, and the tool writes zeros over it when the call has
        /// returned. That wipe reaches only bytes that no other holder shares: with another holder, the zeros go
        /// into a new copy (copy on write), and the holder's bytes stay.
        ///
        /// A `HubFailure.refused` from here carries only the hub's own status, and an error that is no
        /// `HubFailure` counts as "not known", also for a throw before the send (see the doc of `Desk`).
        public var register: (Place, String, Draft, Fields, Data) async throws -> Void
        /// **The vault's step**: the sealed copy for the reference (`VaultClient.intake`, with no statement).
        public var intake: (Place, String, String) async throws -> Void
        /// The app reads the fleet again (`FleetStore.refresh`), so that its own pages show the new entry.
        public var refresh: () async -> Void
        /// A new reference: `bws://` and a new UUID in lower case.
        public var newReference: () -> String
        /// One read of the clipboard, through the gate that `save_bot_token` uses (`SaveBotToken.ClipboardGate`).
        public var readClipboard: () async -> SaveBotToken.Clipboard
        /// Clears the clipboard only when its change count is still the one given (the read's), and says whether
        /// it cleared.
        public var clearClipboard: (Int) async -> Bool

        public init(secret: @escaping (Fields) -> Secret?, ready: @escaping () -> Place?,
                    sealKey: @escaping (Place) async throws -> SealKey,
                    room: @escaping (Place, Draft) async throws -> Room, seal: @escaping (Data, String) -> String?,
                    register: @escaping (Place, String, Draft, Fields, Data) async throws -> Void,
                    intake: @escaping (Place, String, String) async throws -> Void,
                    refresh: @escaping () async -> Void, newReference: @escaping () -> String,
                    readClipboard: @escaping () async -> SaveBotToken.Clipboard,
                    clearClipboard: @escaping (Int) async -> Bool) {
            self.secret = secret
            self.ready = ready
            self.sealKey = sealKey
            self.room = room
            self.seal = seal
            self.register = register
            self.intake = intake
            self.refresh = refresh
            self.newReference = newReference
            self.readClipboard = readClipboard
            self.clearClipboard = clearClipboard
        }
    }

    // ------------------------------------------------------------ the box

    /// **The tool's box: what one save holds of its value.** The reference of the entry, which the app made; the
    /// item's bytes, until the hub has the entry; and the sealed copy, until the vault took it. Each is wiped
    /// (`OwnerChannel.wipe`) as soon as the save needs it no more, at each end of the save for good, and when the
    /// box goes (`deinit`).
    ///
    /// **One owner at a time.** From the making of the item to `LinkWork.begin` the call has the box. `begin` gets
    /// it inside the work's closure, and from there only that closure has it: no frame of a call keeps it, so the
    /// box goes when the table drops the closure. That is also the one wipe for a record that leaves the table by
    /// a count, with no call and no run (`LinkWork.keptMax`, `callsMax`), and for a closure that the table did not
    /// take (`busy`, or a join that another call began first).
    ///
    /// **The bytes are the box's own.** A closure of the desk gets a copy for one call, and the tool wipes that
    /// copy after the call.
    ///
    /// **The limits, said plainly.**
    /// - The text of the value (a `String`, in the call and in the form's own type) and a sealed copy as text are
    ///   copies that Swift cannot wipe. The wipe covers the bytes here and the copies that the tool hands out.
    /// - A wipe of a copy that the tool handed out reaches only bytes that no other holder shares, so each closure
    ///   of the desk must keep no reference to a `Data` of the item (`Secret.item`, `Desk.register`).
    /// - The call's value part (`OwnerChannel.Value`) is not the box's. It is the caller's, and it is wiped when
    ///   the call ends. So it lives through the call's wait too (up to `LinkWork.waitLimit`), also after the hub
    ///   has the entry: on the save path, on the join path and on the state path.
    ///
    /// **It prints as hidden** in every way that Swift prints a value (`description`, `debugDescription`, a mirror
    /// with no children), as `OwnerChannel.Value` and `SaveBotToken.Clipboard` do: its bytes are a secret.
    @MainActor
    final class Kept: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let reference: String
        /// The item: the JSON object that the vault keeps. Empty from the moment that the hub has the entry.
        private var item: [UInt8]
        /// The sealed copy, as the bytes of its text. Empty before the first seal and after the vault took it.
        private var sealed: [UInt8] = []
        /// Whether the hub confirmed the entry: a later run then goes on at the vault's step.
        private(set) var registered = false

        /// Takes a copy of the item's bytes, and writes zeros over the `Data` that brought them. The zeros reach
        /// those bytes only when no other holder shares the `Data`: with another holder they go into a new copy.
        /// So the maker of the item keeps no reference to it (`Secret.item`).
        init(reference: String, taking item: inout Data) {
            self.reference = reference
            self.item = [UInt8](item)
            OwnerChannel.wipe(&item)
        }

        deinit {
            OwnerChannel.wipe(&item)
            OwnerChannel.wipe(&sealed)
        }

        nonisolated var description: String { "a box of save_secret (hidden)" }
        nonisolated var debugDescription: String { description }
        nonisolated var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }

        var holdsItem: Bool { !item.isEmpty }
        var holdsSealed: Bool { !sealed.isEmpty }

        /// A copy of the item for one call of the desk. The caller wipes it when that call has returned.
        func itemCopy() -> Data { Data(item) }

        /// The sealed copy as the vault's step sends it, or nil when the box has none.
        var sealedText: String? { sealed.isEmpty ? nil : String(decoding: sealed, as: UTF8.self) }

        /// Seals the item to a key and keeps the copy, in the place of an older one. False when the box has no
        /// item any more or the desk gave no copy.
        func seal(to key: String, with seal: (Data, String) -> String?) -> Bool {
            guard !item.isEmpty else { return false }
            var copy = itemCopy()
            defer { OwnerChannel.wipe(&copy) }
            guard let text = seal(copy, key), !text.isEmpty else { return false }
            OwnerChannel.wipe(&sealed)
            sealed = Array(text.utf8)
            return true
        }

        /// The hub has the entry: the item is needed no more.
        func entered() {
            registered = true
            OwnerChannel.wipe(&item)
            item = []
        }

        /// The vault took the sealed copy.
        func stored() {
            OwnerChannel.wipe(&sealed)
            sealed = []
        }

        /// An end for good: nothing of the value is needed any more.
        func wipe() {
            OwnerChannel.wipe(&item)
            item = []
            stored()
        }
    }

    // ------------------------------------------------------------ the answer to one call

    /// **The app's answer to one call**, in a fixed order:
    ///
    /// 1. The fields, each in its form (`read`), before anything else is looked at.
    /// 2. **A read of a save's state** (only `request_id`): the table's state of that id (`LinkWork.state(of:)`,
    ///    which is no counted call), or `noWork`. It reads no desk and changes nothing. A value part that came
    ///    with it is not looked at. That part is the caller's, as on every path of this function: its bytes are
    ///    wiped when the call ends (`OwnerChannel.Value`), and not before.
    /// 3. **What the table would do** (`LinkWork.check`), before the value part is looked at and before the
    ///    clipboard is read: other fields under this id, another save that runs, or the caller's repeat of a save
    ///    that the table has. A repeat joins that save at once: no value part of it is looked at, no clipboard is
    ///    read and no desk is asked, because the table runs the closure of the first call and never this call's.
    /// 4. The value part: none with `from` clipboard, one otherwise, and then its form. The value of a file or of
    ///    stdin is the one line that the text holds: the app takes off the one line end at its very end, and
    ///    nothing else (`value(of:line:)`). Then the form's own type takes the fields, and the value with them, or
    ///    the call is refused (`formRefused`).
    /// 5. A current reading of the fleet (`Desk.ready`).
    /// 6. The key to seal to (`Desk.sealKey`).
    /// 7. The room in the list for this name (`Desk.room`).
    /// 8. **The clipboard, last and once**, after every other check passed:
    ///    - a look whether the call still has a caller (`endedBeforeBegin` when it has none);
    ///    - **a second look at the table** (`LinkWork.check`, as in step 3), because steps 5 to 7 waited: a save
    ///      that began in that time is joined, or refuses this call, and the clipboard is not read;
    ///    - one read, with no `await` between that look and the read;
    ///    - the look for a caller again (`endedDuringRead`);
    ///    - then the text's form, as it is, with nothing taken off, and the type's check of it.
    /// 9. The look for a caller once more (`endedBeforeBegin`), and then `LinkWork.begin`. From here the work is
    ///    the table's.
    ///
    /// **`begin` is the decision.** Steps 5 to 8 wait, and another call can come in them: `begin` can still answer
    /// that another save runs, or that this id has other fields, or that the same call began in the meantime. The
    /// box of this call then goes at once, with its value wiped, and for the last of the three the call waits on
    /// the save that the other call began. With the clipboard, the second look of step 8 finds a save that began
    /// before the read; `begin` is still the decision if one can begin during the read (on macOS 26.6.2
    /// the read holds the main actor, so none can there).
    ///
    /// **No `await` stands between `begin` and the wait that follows it**: a run that ends fast with nothing saved
    /// removes its record, and a wait after that would find none.
    ///
    /// **The answers.** While the save runs: `request_id`, `state` running and `stage`. When it is done:
    /// `request_id`, `state` done, `reference`, `title`, `kind`, and `clipboard` (cleared or kept) after a save
    /// from the clipboard. Never the value, its length, a count or a fingerprint. Every other answer is one of the
    /// fixed sentences, and the value is compared with nothing that the caller sent.
    @MainActor
    public static func answer<Place>(fields: [String: JSONValue], value: OwnerChannel.Value?, desk: Desk<Place>,
                                     work: LinkWork) async -> OwnerChannel.Answer {
        await answer(fields: fields, value: value, desk: desk, work: work, made: nil)
    }

    /// `made`: for a test, a look at each box as the call makes it. The test keeps only a weak reference.
    @MainActor
    static func answer<Place>(fields: [String: JSONValue], value: OwnerChannel.Value?, desk: Desk<Place>,
                              work: LinkWork, made: ((Kept) -> Void)?) async -> OwnerChannel.Answer {
        // 1. The fields.
        let id: String, secret: Fields, from: String
        switch read(fields, app: true) {
        case .failure(let refusal):
            return .refused(refusal.text)
        case .success(.state(let asked)):
            // 2. A read of the state: never `wait`, which is a counted call.
            return said(work.state(of: asked), id: asked)
        case .success(.save(let given, let taken, let source, _)):
            // The app's read refuses a save with no id, so this is a line that nothing reaches.
            guard let given else { return .refused(appNeedsRequest) }
            id = given
            secret = taken
            from = source
        }
        // 3. The table, before the value.
        let digest = Self.digest(of: secret, from: from)
        switch work.check(id: id, digest: digest) {
        case .otherFields:
            return .refused(otherFields)
        case .busy:
            return .refused(busy)
        case .joined:
            if let refused = join(work, id: id, digest: digest) { return refused }
            return said(await work.wait(id), id: id)
        case .started:
            break
        }
        // 4 to 8. Each branch ends with the box, the place, the key and the name, or with the call's answer.
        let box: Kept, place: Place, key: String, draft: Draft, readCount: Int?
        if from == "clipboard" {
            guard value == nil else { return .refused(clipboardTakesNoPart) }
            guard let form = desk.secret(secret) else { return .refused(formRefused) }
            switch await fleet(desk, form.draft) {
            case .failure(let refusal):
                return .refused(refusal.text)
            case .success(let found):
                place = found.0
                key = found.1
            }
            switch await copied(desk, form, work: work, id: id, digest: digest, made: made) {
            case .answered(let answer):
                return answer
            case .read(let read, let count):
                box = read
                readCount = count
            }
            draft = form.draft
        } else {
            guard let value else { return .refused(noValue) }
            switch taken(value, secret, desk, made: made) {
            case .failure(let refusal):
                return .refused(refusal.text)
            case .success(let got):
                box = got.box
                draft = got.draft
            }
            switch await fleet(desk, draft) {
            case .failure(let refusal):
                return .refused(refusal.text)
            case .success(let found):
                place = found.0
                key = found.1
            }
            readCount = nil
        }
        // 9. A caller that went away in the waits above gets no save. Then `begin`, which takes the box out of
        // this frame, and with no `await` after it the wait.
        if Task.isCancelled { return .refused(endedBeforeBegin) }
        let parts = Parts(id: id, fields: secret, draft: draft, place: place, key: key, clipboard: readCount)
        if let refused = refusal(start(work, digest: digest, box: consume box, parts: parts, desk: desk)) { return refused }
        return said(await work.wait(id), id: id)
    }

    /// **The answer for a state of the table**: a work that runs is a result with its stage; a work that is done
    /// is its own answer; nothing saved and a failure are refusals with the work's words; and no record is
    /// `noWork`.
    static func said(_ state: LinkWork.State?, id: String) -> OwnerChannel.Answer {
        switch state {
        case nil:
            return .refused(noWork)
        case .running(let stage)?:
            return .result(.object(["request_id": .string(id), "state": .string("running"),
                                    "stage": .string(stage.rawValue)]))
        case .ended(.done(let answer))?:
            return .result(answer)
        case .ended(.nothing(let words))?, .ended(.failed(let words, _))?:
            return .refused(words)
        }
    }

    /// **The digest of one save** (`LinkWork.digest`): of the tool's name and the fields that the program sends
    /// for it, without `request_id`. The fields are written from the read call, so a field with null, which was
    /// not given, is no part of it.
    static func digest(of secret: Fields, from: String) -> [UInt8] {
        var fields: [String: JSONValue] = ["kind": .string(secret.kind.rawValue), "from": .string(from)]
        if let env = secret.env { fields["env"] = .string(env) }
        if let url = secret.url { fields["url"] = .string(url) }
        if let username = secret.username { fields["username"] = .string(username) }
        return LinkWork.digest(tool: name, fields: fields)
    }

    /// The refusal for a `begin` that started nothing and joined nothing, or nil: then the call waits on the work.
    private static func refusal(_ began: LinkWork.Begin) -> OwnerChannel.Answer? {
        switch began {
        case .otherFields: return .refused(otherFields)
        case .busy: return .refused(busy)
        case .started, .joined: return nil
        }
    }

    /// **The caller's repeat of a save that the table has**: `begin` with a closure that the table never runs,
    /// right after a `check` that said `joined`, with no `await` between the two. A nil answer says that the call
    /// joined: the caller of this function then waits on the work, with no `await` before that wait. The closure's
    /// words are for a table that does not keep its word: nothing of this call was sent.
    @MainActor
    private static func join(_ work: LinkWork, id: String, digest: [UInt8]) -> OwnerChannel.Answer? {
        refusal(work.begin(id: id, digest: digest) { _, _ in .nothing(noWork) })
    }

    /// **Step 4 for a value part** (from a file or from stdin): the one line that its text holds, in the value's
    /// form (`value(of:line:)`: only the one line end at the very end is taken off); then the type's check of the
    /// fields; then the item, in a box. The text of the value lives only in this function.
    @MainActor
    private static func taken<Place>(_ value: OwnerChannel.Value, _ secret: Fields, _ desk: Desk<Place>,
                                     made: ((Kept) -> Void)?) -> Result<(box: Kept, draft: Draft), OwnerChannel.Refusal> {
        guard let text = Self.value(of: value.text, line: true) else { return .failure(.init(notAValue)) }
        guard let form = desk.secret(secret), let box = boxed(form, text, desk, made: made) else {
            return .failure(.init(formRefused))
        }
        return .success((box, form.draft))
    }

    /// The box with the item of a secret and a value, or nil when the form's own type does not take the two.
    @MainActor
    private static func boxed<Place>(_ form: Secret, _ text: String, _ desk: Desk<Place>,
                                     made: ((Kept) -> Void)?) -> Kept? {
        guard var item = form.item(text) else { return nil }
        let box = Kept(reference: desk.newReference(), taking: &item)
        made?(box)
        return box
    }

    /// **Steps 5 to 7**: a current reading, the key to seal to, and the room in the list. A read of the vault's
    /// status that failed has its own sentence (`vaultUnread`): that the vault does not answer the hub (`noVault`)
    /// is not known when the hub did not answer this Mac. **A reading that moved while the key was read is "not
    /// ready"** (`notReady`, the sentence of step 5): the app shows another hub or database now, which is the same
    /// fact as a reading that is not current, and nothing was sent. The room is not asked then.
    @MainActor
    private static func fleet<Place>(_ desk: Desk<Place>,
                                     _ draft: Draft) async -> Result<(Place, String), OwnerChannel.Refusal> {
        guard let place = desk.ready() else { return .failure(.init(notReady)) }
        let key: String
        do {
            switch try await desk.sealKey(place) {
            case .key(let found): key = found
            case .noVault: return .failure(.init(noVault))
            case .noPin: return .failure(.init(noPin))
            case .otherKey: return .failure(.init(otherKey))
            case .noRecovery: return .failure(.init(noRecovery))
            case .moved: return .failure(.init(notReady))
            }
        } catch {
            return .failure(.init(vaultUnread))
        }
        do {
            switch try await desk.room(place, draft) {
            case .free: break
            case .held: return .failure(.init(held))
            case .full: return .failure(.init(full))
            case .unread: return .failure(.init(listUnread))
            }
        } catch {
            return .failure(.init(listUnread))
        }
        return .success((place, key))
    }

    /// What step 8 gives: the box with the item of the clipboard's text and the read's change count, or the call's
    /// answer (a refusal, or the answer of a save that the call joined with no read).
    private enum Copied {
        case read(Kept, count: Int)
        case answered(OwnerChannel.Answer)
    }

    /// **Step 8: the clipboard, once.** A call whose caller went away before the read reads nothing, so it brings
    /// no question of macOS that nobody waits for; one whose caller went away during the read sends nothing.
    ///
    /// **A second look at the table, right before the read.** The call waited in steps 5 to 7, and a save can
    /// have begun in that time: the same call from the same caller (two calls with one `request_id` and the same
    /// fields), or another save. Without this look the call would read the clipboard, macOS could ask the owner a
    /// second time, and only `begin` would say that the read was for nothing. So the call asks the table again,
    /// as in step 3, and acts as there: it joins a save of its own id with no read, or it is refused (another save
    /// runs, or other fields under its id). No `await` stands between this look and the read.
    ///
    /// **Two reads that overlap in time are the gate's job**, not this look's: the desk's `readClipboard` goes
    /// through `SaveBotToken.ClipboardGate`, and the second read gets `clipboardBusy`. This look closes the other
    /// case, a save that began while this call waited. `begin` stays the decision after the read, for a save that
    /// began during it.
    ///
    /// The reading of before the read is the one that sends: while macOS's question is up, the app's reading
    /// cannot renew. One sentence covers a clipboard with no text and a text that is no value. The clipboard's
    /// text lives only in this function.
    @MainActor
    private static func copied<Place>(_ desk: Desk<Place>, _ form: Secret, work: LinkWork, id: String,
                                      digest: [UInt8], made: ((Kept) -> Void)?) async -> Copied {
        if Task.isCancelled { return .answered(.refused(endedBeforeBegin)) }
        switch work.check(id: id, digest: digest) {
        case .otherFields:
            return .answered(.refused(otherFields))
        case .busy:
            return .answered(.refused(busy))
        case .joined:
            if let refused = join(work, id: id, digest: digest) { return .answered(refused) }
            return .answered(said(await work.wait(id), id: id))
        case .started:
            break
        }
        let copy = await desk.readClipboard()
        if Task.isCancelled { return .answered(.refused(endedDuringRead)) }
        switch copy {
        case .notAllowed:
            return .answered(.refused(clipboardDenied))
        case .busy:
            return .answered(.refused(clipboardBusy))
        case .nothing:
            return .answered(.refused(notOnClipboard))
        case .text(let copied, let count):
            // Bounded as a value part is, before any work on its text on the main actor. The clipboard's text is
            // taken as it is: nothing is taken off it, a line end at its end too.
            guard copied.utf8.count <= OwnerChannel.valueMax, let text = value(of: copied, line: false) else {
                return .answered(.refused(notOnClipboard))
            }
            guard let box = boxed(form, text, desk, made: made) else { return .answered(.refused(formRefused)) }
            return .read(box, count: count)
        }
    }

    /// **`begin`, with the work's closure as the one owner of the box.** This function takes the box from the
    /// call, and nothing of it stays behind when it returns: the table has the closure, or nothing has, and then
    /// the box goes here, with its value wiped.
    @MainActor
    private static func start<Place>(_ work: LinkWork, digest: [UInt8], box: consuming Kept, parts: Parts<Place>,
                                     desk: Desk<Place>) -> LinkWork.Begin {
        let kept = box
        return work.begin(id: parts.id, digest: digest) { stage, attempt in
            await run(kept, parts, desk: desk, stage: stage, attempt: attempt)
        }
    }

    // ------------------------------------------------------------ the work

    /// What one save sends with, which does not change from `begin` on.
    struct Parts<Place: Sendable> {
        let id: String
        let fields: Fields
        let draft: Draft
        /// The reading of the call that began the save: each run sends with it.
        let place: Place
        /// The vault's key as the call read it: the first run seals to it.
        let key: String
        /// The clipboard's change count at the read, for a save from the clipboard.
        let clipboard: Int?
    }

    /// How one send to the hub ended, as the work reads it: the hub took it, the hub refused it with a status, or
    /// the outcome is not known (no answer, an answer that could not be read, or another error). The hub's own
    /// words are not read: they can hold a field's text.
    private enum Sent { case took, refused(Int), notKnown }

    @MainActor
    private static func sent(_ send: () async throws -> Void) async -> Sent {
        do {
            try await send()
            return .took
        } catch SaveBotToken.HubFailure.refused(let status, _) {
            return .refused(status)
        } catch {
            return .notKnown
        }
    }

    /// **One run of the work** (`LinkWork.Run`): the entry in the hub's list, then the value in the vault.
    ///
    /// **Seal and register** (stage `registering`), while the hub did not confirm the entry. The first run seals
    /// to the key that its call read; a later run reads the key again. The item is sealed, and the entry goes to
    /// the hub under the box's reference, with an API key's address as the form sends it.
    /// - The hub confirmed: the item is wiped, and the run goes on.
    /// - No answer, an answer that could not be read, or a status of 500 and above: whether the hub has the entry
    ///   is not known. The item stays for the next run, which registers under the same reference.
    /// - **At the first run only**, a 503 (the vault does not answer the hub) and another status under 500 (the
    ///   hub refused the entry) mean that nothing was saved, and the work leaves the table.
    /// - **At the first run only**, an item that the desk could not seal is `sealFailed`: nothing was sent.
    /// - **At a later run, never "nothing was saved"**: an earlier run's request may have arrived, so the hub may
    ///   hold the entry. A 503, another refusal, a vault's key that cannot be read again and a seal that failed are
    ///   then all "not known". (The table would keep a `nothing` of a later run as a failure for good, and repeat
    ///   its words to the caller.)
    /// - **Another key at a later run ends the save, with its own words** (`otherKeyLater`). The run read the
    ///   vault's key again, and it is not the key that this Mac pinned. Nothing is sealed to it and nothing is
    ///   sent. The save ends for good at that run, the last one or not, and the box is wiped at once: "it goes on
    ///   under the same reference" would be untrue while the key differs, and the owner must know of the key now.
    ///   Every other answer of that read (no vault, no pin, no recovery key, a reading of the app that moved, a
    ///   read that failed) is "not known".
    ///
    /// **The intake** (stage `storing`): the sealed copy goes to the vault through the hub. A status under 500 is
    /// the vault's or the hub's own no: the list has an entry with no value, for good. Anything else can be tried
    /// again, and a later run sends the same copy.
    ///
    /// **After the intake**: the app reads the fleet again; the clipboard is cleared only when its count is still
    /// the read's; then the work is done.
    ///
    /// **The last run** (`LinkWork.triesMax`) ends with the final words, because the table makes that run final
    /// itself and keeps the run's words. At each end for good the box is wiped.
    @MainActor
    static func run<Place>(_ kept: Kept, _ parts: Parts<Place>, desk: Desk<Place>,
                           stage: @MainActor (LinkWork.Stage) -> Void, attempt: Int) async -> LinkWork.Ended {
        let reference = kept.reference
        let first = attempt <= 1, last = attempt >= LinkWork.triesMax
        /// An end that the same call can go on from keeps the box as it is; every other end wipes it.
        func ended(_ answer: LinkWork.Ended) -> LinkWork.Ended {
            if case .failed(_, again: true) = answer { return answer }
            kept.wipe()
            return answer
        }
        if !kept.registered {
            stage(.registering)
            let notKnown = LinkWork.Ended.failed(last ? registerNeverKnown(reference)
                                                      : registerNotKnown(reference, id: parts.id), again: !last)
            var key = parts.key
            if !first {
                switch try? await desk.sealKey(parts.place) {
                case .key(let read)?:
                    key = read
                case .otherKey?:
                    return ended(.failed(otherKeyLater(reference), again: false))
                case .noVault?, .noPin?, .noRecovery?, .moved?, nil:
                    return ended(notKnown)
                }
            }
            // A seal that failed at the first run sent nothing.
            guard kept.seal(to: key, with: desk.seal) else { return ended(first ? .nothing(sealFailed) : notKnown) }
            var item = kept.itemCopy()
            let hub = await sent { try await desk.register(parts.place, reference, parts.draft, parts.fields, item) }
            OwnerChannel.wipe(&item)
            switch hub {
            case .took:
                kept.entered()
            case .refused(503) where first:
                return ended(.nothing(noVault))
            case .refused(let status) where first && status < 500:
                return ended(.nothing(hubRefused(status: status)))
            case .refused, .notKnown:
                return ended(notKnown)
            }
        }
        stage(.storing)
        let notStored = LinkWork.Ended.failed(last ? neverInVault(reference) : notInVault(reference, id: parts.id),
                                              again: !last)
        // A box with an entry and no sealed copy cannot be: it is wiped only after the vault took it.
        guard let sealed = kept.sealedText else { return ended(.failed(neverInVault(reference), again: false)) }
        switch await sent({ try await desk.intake(parts.place, reference, sealed) }) {
        case .took:
            kept.stored()
        case .refused(let status) where status < 500:
            return ended(.failed(vaultRefused(reference), again: false))
        case .refused, .notKnown:
            return ended(notStored)
        }
        await desk.refresh()
        var answer: [String: JSONValue] = ["request_id": .string(parts.id), "state": .string("done"),
                                           "reference": .string(reference), "title": .string(parts.draft.title),
                                           "kind": .string(parts.draft.kind.rawValue)]
        if let count = parts.clipboard {
            answer["clipboard"] = .string(await desk.clearClipboard(count) ? "cleared" : "kept")
        }
        return ended(.done(.object(answer)))
    }
}
