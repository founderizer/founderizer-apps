import Foundation

/// **A door card's signed press, for `answer_needs_you`** (the owner, 17 November 2026, of a door card of one of his
/// servers that his own agent could not press for him: "why can't you press Full access on <server> for me?"). The
/// door's card of a call that the door refused has two answers that let something through: its first option, the yes
/// (choice 0; "Run it once" on the door's card of a run), the owner's signed yes to the item's door call, and, on the
/// door's card of a run ("Run one root script on <server>?"), Full access on <server> (choice 1), the owner's signed
/// mode of that server. The hub takes either one only with a statement in its form beside it (`hub.py`
/// `phone_submit`, `door_call_statement`, `door_mode_statement`), and the door checks the owner key's signature of it,
/// against the owner keys of its own access file. Only the app holds that key. So for such a press, `answer_needs_you`
/// of the program sends the press to the app, and the app signs it as the owner's own press of that option signs it
/// (`DoorCallSigning.maker` in the app) and sends it (`POST /ui/needs/<need>` with `choice`, `statement` and
/// `signature`). Every other answer goes to the hub as before, with no signature, as `owner_mcp.py` sends it.
///
/// **No question to the owner** (the owner, 15 November 2026: "No touch"). So a program that runs as the owner's user
/// on this Mac can make the app sign the yes to any door call that a card of the fleet asks for, and Full access on
/// the server of any door card of a run (`OWNER-MCP-BOUNDARY.md`, section 7b). The guide, and not the tool, says that
/// the owner's agent presses only the option that the owner chose.
///
/// **What the app signs is what the owner's own press signs, and nothing more.** The app reads the item itself, in a
/// read of the hub's state of its own, and signs by the one function of the card's own press: Run it once of the door's
/// card of a run only for the script that the card shows (`DoorCall.checked`), and Full access only on the door's own
/// card of that server (`DoorCall.names`). The request takes no statement, no hash, no server and no script from its
/// caller: only the item's id, the option, and the hub's generation that the program read, so that the app presses the
/// item that the program read and no item of the same id of another hub or database.
///
/// This file has the program's choice of the route (`press`), the fields of the request on the link and their forms,
/// the fixed sentences, the app's desk and the app's answer to one request. The app's side is `LinkTools.doorDesk`,
/// closure by closure.
public enum AnswerDoor {
    /// The request's name on the link: the program sends a door card's press under the name of the tool that the agent
    /// called. It is in `OwnerLinkTools.writes` and not in `OwnerLinkTools.names`: `answer_needs_you` is a tool of the
    /// table, and only this press of it goes on the link.
    public static let name = "answer_needs_you"
    public static let fields = ["need", "choice", "db"]
    /// The largest id of a Needs-you item that the request takes, as `answer_secret_request` takes it.
    static let needMost = 2_147_483_647
    /// The longest generation of the hub that the request takes, in bytes. The hub's own is 12 hex characters.
    static let generationMost = 128

    /// **The two options of a door card that carry the owner's signed statement**: the yes, the first option of every
    /// door card ("Run it once" on the door's card of a run), and Full access on <server>, the second option of the
    /// door's card of a run.
    public enum Press: Int64, Sendable {
        case runOnce = 0
        case fullAccess = 1

        /// The kind of the statement that the app signs for this press (`OwnerStatement` in FleetCore).
        var kind: String { self == .runOnce ? "door-call" : "door-mode" }
    }

    /// **The program's own sentences of `answer_needs_you`**, after the table's words of the tool
    /// (`OwnerTools.programTable`): only this program sends a door card's signed press, so these words are no words of
    /// `owner_mcp.py`'s table, whose server cannot sign (the hub refuses such a press from it).
    public static let description = "On the door's card (an item with door_call), choice 0, the card's yes (Run it "
        + "once on the door's card of a run), and, on a card with door_host, choice 1 (Full access on that server) "
        + "need the signature of the owner's key: this program gives such a press to the Founderizer app on this Mac, "
        + "which signs it as the owner's own press does and sends it. Only the Mac that set up Founderizer Vault holds "
        + "that key. Such a press answers need, choice, answered, signed, server (on a card with a server) and note. "
        + "Press one of the two only when the owner chose it: the yes lets the card's one call through, and Full "
        + "access lets each later root script on that server through, and no page of the app sets the server back to "
        + "Auto in this version."

    // ------------------------------------------------------------ the program's side

    /// **The fields that go on the link when this call of `answer_needs_you` is a door card's signed press**, else nil,
    /// and the call goes to the hub as before (`OwnerTools.answerNeed`). A signed press is a `choice` of 0 or 1, as a
    /// JSON integer, with no `answer` and no `choices` (the hub refuses those together, in its own words), on an item of
    /// the hub's state that has a door call: the yes on every such item, and Full access only on an item that also
    /// names its server (`door_host`: the door's card of a run). The item's answer does not decide the route: the app
    /// says whether the item has its answer already, and with which option, so that the same call again after a lost
    /// answer reads that and sends nothing. The hub would refuse an unsigned press of such an item before it looks at
    /// the item's answer, with words that ask for the signature.
    ///
    /// `need` is read by `answer_needs_you`'s own rule (`OwnerTools.wholeNumber`) before any request, so a wrong `need`
    /// gets the same refusal on both routes. The state is read only for a choice of 0 or 1: one `GET /ui/state`, which
    /// also gives the generation that a command after it carries (`OwnerHub.state`), so that each call makes the hub
    /// one read and one write at most. `owner_mcp.py` keeps its generation from one call to the next, so in a long
    /// session this read is one request more than it makes for the same answer.
    static func press(_ args: [String: JSONValue], on hub: OwnerHub) throws -> [String: JSONValue]? {
        guard case .int(let choice)? = args["choice"], let press = Press(rawValue: choice) else { return nil }
        for other in ["answer", "choices"] where !(args[other]?.isNull ?? true) { return nil }
        let need = try OwnerTools.wholeNumber(args, "need")
        guard (1...Int64(needMost)).contains(need) else { return nil }
        let state = try hub.state()
        guard case .string(let generation)? = state["db"],
              let item = state["needs"]?.array?.first(where: { $0["id"] == .int(need) }),
              signs(item, press) else { return nil }
        return ["need": .int(need), "choice": .int(press.rawValue), "db": .string(generation)]
    }

    /// Whether this press of this item, as the hub's state gives the item, carries a signed statement: the item has a
    /// door call (a text that is not empty), and for Full access also its server. The app decides by the same facts of
    /// its own read (`Card.signs`).
    static func signs(_ item: JSONValue, _ press: Press) -> Bool {
        func text(_ key: String) -> Bool { item[key]?.string.map { !$0.isEmpty } ?? false }
        return text("door_call") && (press == .runOnce || text("door_host"))
    }

    // ------------------------------------------------------------ the fields, in the app

    /// One request, as the app reads it.
    struct Read: Equatable {
        let need: Int
        let press: Press
        let generation: String
    }

    /// **The checks of the fields, in a fixed order**: a field named like a value, a field that the request does not
    /// take, `need`, `choice`, and then `db`. Only a JSON integer is a `need` or a `choice`. No refusal quotes anything
    /// of the request. The program makes each field itself, so a refusal here is of a request that this program did
    /// not make.
    static func read(_ fields: [String: JSONValue]) -> Result<Read, OwnerChannel.Refusal> {
        if fields.keys.contains(where: OwnerLinkTools.namedLikeAValue) {
            return .failure(.init(OwnerLinkTools.neverAField))
        }
        guard fields.keys.allSatisfy({ Self.fields.contains($0) }) else { return .failure(.init(only)) }
        guard case .int(let id)? = fields["need"], (1...Int64(needMost)).contains(id) else {
            return .failure(.init(needWord))
        }
        guard case .int(let choice)? = fields["choice"], let press = Press(rawValue: choice) else {
            return .failure(.init(choiceWord))
        }
        guard case .string(let generation)? = fields["db"], (1...generationMost).contains(generation.utf8.count) else {
            return .failure(.init(generationWord))
        }
        return .success(Read(need: Int(id), press: press, generation: generation))
    }

    // ------------------------------------------------------------ the fixed sentences

    // Each names only the tool's own fields and quotes nothing that the caller sent. The parts that are not fixed: the
    // character code of a script's hidden character, which the app's own check makes ("U+202E"), and the hub's own
    // words after a certain refusal of the hub (`GrantSecret.withHubWords`), which stand last. A sentence says
    // "Nothing was sent." exactly when the app sent nothing.

    static let only = "answer_needs_you takes only need, choice and db on the app's link. Nothing was sent."
    static let noPart = "answer_needs_you takes no part after its request line. Nothing was sent."
    static let needWord = "need must be the id of the Needs-you item, a whole number from 1 to 2147483647. Nothing was "
        + "sent."
    static let choiceWord = "On the app's link, choice must be 0 (the card's yes) or 1 (Full access on the card's "
        + "server). Nothing was sent."
    static let generationWord = "db must be the hub's generation that the program read. Nothing was sent."

    static let notReady = "The Founderizer app's reading of the fleet is not current now, or the app has no fleet. Call "
        + "answer_needs_you again in a moment. Nothing was sent."
    /// The app reads another hub, or another database of the hub, than the program's read of this call, or its own
    /// read of the item is of another database than its reading: an item of the same id there can be another item, so
    /// the words send the caller to the item again before any other call.
    static let otherFleet = "The reads of this call are not all of one hub and one database of it, so an item of that "
        + "id can be another item now. Read the item again with fleet_overview, and call answer_needs_you again only "
        + "for the card and the option that the owner chose. Nothing was sent."
    static let itemUnread = "The Founderizer app could not read the item from the hub. Call answer_needs_you again in "
        + "a moment. Nothing was sent."
    static let noItem = "The fleet has no Needs-you item of that id: fleet_overview gives the items under needs_you. "
        + "Nothing was sent."
    /// The app's own read shows no signed statement for this press of this item, where the program's read of a moment
    /// before showed one. Both read the same database of the same hub, and an item's door call and server never change,
    /// so this is a line that nothing should reach.
    static let notDoorPress = "By the app's own read of the hub, that option of that item carries no signed statement, "
        + "so the app signs and sends nothing. Tell the owner. Nothing was sent."
    /// The item's answer is this option: the owner pressed it, or a call before this one, whose answer was lost, sent it.
    static let answeredWithThis = "That item has its answer already, with this option: the owner pressed it, or an "
        + "earlier call sent it. Nothing was sent."
    static let answeredAlready = "That item has its answer already, with another answer, and an item takes one answer. "
        + "Nothing was sent."
    /// The app's reading moved to another hub or database during the call.
    static let moved = otherFleet
    static let notOffered = "This hub does not take that signed answer yet: it lists no door_calls for the yes, or no "
        + "door_modes for Full access. The hub takes releases by itself: read fleet_read(page=\"releases\"). "
        + "Nothing was sent."
    static let vaultUnread = "The Founderizer app could not read the central vault's status from the hub, which names "
        + "the fleet that the app signs for. Call answer_needs_you again in a moment. Nothing was sent."
    static let noFleet = "The hub did not say which fleet this is, so the app cannot sign for it. Call answer_needs_you "
        + "again in a moment. Nothing was sent."
    static let noOwnerKey = "This Mac holds no owner key for this fleet, so the app on it cannot sign this press: only "
        + "the Mac that set up Founderizer Vault signs. The owner presses it in Founderizer on that Mac. Nothing was "
        + "sent."
    /// This Mac held the key a moment ago (`Signed.notSignedNow`): the key's item could not be read, or the key made
    /// no signature.
    static let notSignedNow = "This Mac held an owner key for this fleet a moment ago, and the app could not sign with "
        + "it now: the Mac can be locked, the key can be gone, or macOS did not let the app read it. Call "
        + "answer_needs_you again later. Nothing was sent."
    /// The call's connection ended before its write. Nobody reads this.
    static let ended = "The call ended before its write. Nothing was sent."

    /// What the owner's own press says when the app signs nothing on a card, said to the owner's agent: the card must
    /// be raised again.
    static let newCard = "Tell the owner: the agent that raised the card can raise a new one."

    /// **Why the app signs nothing on a door card**, as the owner's own press says it (`DoorCall.Refusal` and
    /// `DoorCall.olderHub` in FleetCore, which this library does not link; `LinkTools.cardStop` maps each case of the
    /// app's own, with no default).
    public enum CardStop: Equatable, Sendable {
        /// A card of a run with no script, from a hub that sends no script yet (before owner API 1.125).
        case olderHub
        /// The card carries no script.
        case noScript
        /// The card's title or answers do not name the server of its call.
        case otherServer
        /// The script holds a character that is not printable ASCII or a line feed: its code, as "U+XXXX".
        case hidden(String)
        /// The script is longer than a card shows whole, or padded with blanks.
        case padded
        /// The card's own words hold code beside the script.
        case decoy
        /// What the card draws under Script is not the script that it carries.
        case notShown
        /// The hash of the server and the script is not the hash that the hub gave.
        case otherHash
    }

    static func words(_ stop: CardStop) -> String {
        switch stop {
        case .olderHub:
            return "This hub sends no script with the door's card yet, so the app cannot check what Run it once would "
                + "sign, and it signs nothing. The hub takes releases by itself: read fleet_read(page=\"releases\"). "
                + "Nothing was sent."
        case .noScript:
            return "This card does not carry its script, so the app cannot check what Run it once would sign, and it "
                + "signs nothing. \(newCard) Nothing was sent."
        case .otherServer:
            return "This card's title and answers do not name the server of its call, so the app signs nothing. "
                + "\(newCard) Nothing was sent."
        case .hidden(let code):
            // The code is the app's own (U+ and four to six hex digits); anything else is not said.
            let shown = isCharacterCode(code) ? " (\(code))" : ""
            return "The card's script holds a character that is not plain text\(shown), so the app signs nothing. "
                + "\(newCard) Nothing was sent."
        case .padded:
            return "The card's script is too long, or has wide gaps that can hide a command, so the app signs "
                + "nothing. \(newCard) Nothing was sent."
        case .decoy:
            return "The card shows code outside its script, so the app signs nothing. \(newCard) Nothing was sent."
        case .notShown:
            return "The card does not show the whole script that it asks for, so the app signs nothing. \(newCard) "
                + "Nothing was sent."
        case .otherHash:
            return "The script on this card is not the script that the door refused, so the app signs nothing. "
                + "\(newCard) Nothing was sent."
        }
    }

    /// "U+" and four to six digits of 0-9 and A-F: the form of `DoorCall.hidden`'s answer.
    static func isCharacterCode(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (6...8).contains(bytes.count), bytes[0] == 0x55, bytes[1] == 0x2B else { return false }
        return bytes.dropFirst(2).allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) }
    }

    // After the write went out.

    /// A certain refusal of the hub, of another kind than an answer that came first. The hub's words come after it.
    static let refused = "The hub refused this answer, so the item has no answer from this call."
    /// The hub refused the answer because the item has one, and the read after it shows this option as that answer.
    static let hadAnswerWithThis = "The hub refused this answer because the item has its answer already, with this "
        + "option, from an answer before this one."
    /// The same, when the read shows another answer, or could not be made.
    static let answeredFirst = "The hub refused this answer because the item has its answer already: another answer "
        + "came first, or the app could not read which one."
    /// The answer went out, with no known outcome.
    static let notKnown = "Whether the hub took this answer is not known. Call answer_needs_you again in the same way: "
        + "when the item has its answer with this option, that call says so and sends nothing."

    /// The program's words when its request went out and no answer came back (the app did not answer in time, or the
    /// link ended): the app may have signed the press and sent it.
    public static let notKnownHere = "The Founderizer app did not answer in time, or the link ended, so whether the app "
        + "signed this press and the hub took it is not known. Call answer_needs_you again in the same way: when the "
        + "item has its answer already with this option, that call says so and sends nothing. fleet_overview shows "
        + "the item under needs_you."

    // The notes of an answer.

    static let noteRunOnce = "The hub keeps the owner's signed yes with the item. The door checks the signature itself, "
        + "and lets the item's one call through when the agent whose call the door refused sends that same call "
        + "again."
    static let noteFullAccess = "The hub keeps the owner's signed Full access as that server's mode. The door checks "
        + "the signature itself, and from its next read of the hub, within about a minute, it lets each later root "
        + "script on that server through."

    // ------------------------------------------------------------ the app's side

    /// **What one item says of itself, as the app reads it from the hub's state**: whether it has its answer, the index
    /// of the option that answered it, whether it has a door call, and its server. No text of it goes into a sentence;
    /// the server goes into a result only in a server's own form (`isHost`).
    public struct Card: Equatable, Sendable {
        public let open: Bool
        /// The option that the owner, or a call, pressed: nil for an open item and for an answer in words.
        public let chosen: Int?
        public let doorCall: Bool
        /// The server of the door's card of a run (`door_host`), or nil.
        public let host: String?

        public init(open: Bool, chosen: Int? = nil, doorCall: Bool, host: String? = nil) {
            self.open = open
            self.chosen = chosen
            self.doorCall = doorCall
            self.host = host
        }

        /// The rule of `AnswerDoor.signs`, on the app's own facts.
        func signs(_ press: Press) -> Bool { doorCall && (press == .runOnce || !(host ?? "").isEmpty) }
    }

    /// What one read of the hub's state says of the item of one id.
    public enum ItemRead<Item: Sendable>: Sendable {
        case found(Item, Card)
        /// The state has no item of that id.
        case none
        /// The state is of another database than the place's.
        case otherGeneration
    }

    /// **What the app's signature of one press gave**: the statement and its signature, or why the app signed nothing.
    public enum Signed: Equatable, Sendable {
        case signed(statement: String, signature: String)
        /// The app's reading moved to another hub or database during the call.
        case moved
        /// The hub does not list the feature of this press: `door_calls` for the yes, `door_modes` for Full access.
        case notOffered
        /// The card is not one that this Mac signs this press on, for the reason that the owner's own press says.
        case card(CardStop)
        /// The read of the central vault's status, which names the fleet, failed.
        case vaultUnread
        /// The hub did not say which fleet this is.
        case noFleet
        /// This Mac holds no owner key for this fleet.
        case noOwnerKey
        /// This Mac held the key a moment ago, and the app could not sign with it now.
        case notSignedNow
    }

    /// **The app's engine for the request**, as closures, so that a test gives stand-ins: the library does not link
    /// FleetCore, and no test reads a Keychain or reaches a hub. `Place` is the hub, the database and the installation
    /// that one request reads and sends with; `Item` is the app's own item (`OwnerNeed`), which only the app's own
    /// signing reads.
    ///
    /// **A failure of `send` is thrown as `SaveBotToken.HubFailure`** (`LinkTools.failure`): a refusal carries only the
    /// hub's own status and its own words. A status under 500 is a certain refusal; no answer, an answer that could not
    /// be read, a status of 500 or more and every other error count as "not known". The hub's refusal of an item that
    /// has its answer (its code `request_answered`) is `AnswerSecret.Answered`.
    @MainActor
    public struct Desk<Place: Sendable, Item: Sendable> {
        /// The hub, its database and the installation when the app's reading is current and has a database, else nil.
        public var ready: () -> Place?
        /// The database of a place.
        public var database: (Place) -> String
        /// One read of the hub's state, and the item of this id in it with its facts, for the place's database. A
        /// read that failed, and bytes that are no state, are thrown.
        public var item: (Place, Int) async throws -> ItemRead<Item>
        /// The owner's signature of this press of this item, by the one rule of the owner's own press.
        public var sign: (Place, Item, Press) async -> Signed
        /// The answer of the item with this press and its signed statement, under a new request id of the app.
        public var send: (Place, Int, Press, _ statement: String, _ signature: String) async throws -> Void
        /// The app reads the fleet again (`FleetStore.refresh`), started and not waited for.
        public var refresh: () async -> Void

        public init(ready: @escaping () -> Place?, database: @escaping (Place) -> String,
                    item: @escaping (Place, Int) async throws -> ItemRead<Item>,
                    sign: @escaping (Place, Item, Press) async -> Signed,
                    send: @escaping (Place, Int, Press, String, String) async throws -> Void,
                    refresh: @escaping () async -> Void) {
            self.ready = ready
            self.database = database
            self.item = item
            self.sign = sign
            self.send = send
            self.refresh = refresh
        }
    }

    /// **The app's answer to one request**, in a fixed order. The app trusts nothing of the program's checks: it makes
    /// each of them itself.
    ///
    /// 1. No part after the request line, and the fields, each in its form (`read`).
    /// 2. A current reading of the fleet with a database (`Desk.ready`), and that database is the one that the program
    ///    read (`db`).
    /// 3. One read of the item, of that database. It is there; this press of it carries a signed statement (a door
    ///    call, and for Full access its server); and it has no answer, else the words say whether its answer is this
    ///    option.
    /// 4. The signature (`Desk.sign`), by the rule of the owner's own press of that option: the hub lists the press's
    ///    feature, the card is one that this Mac signs that press on, the fleet's id, this Mac's owner key, and the
    ///    signature itself. Each "no" has its own sentence, and nothing is sent.
    /// 5. The call still has its caller: a call whose connection ended sends nothing.
    /// 6. The one write: the answer with the press and its signed statement (`Desk.send`).
    ///
    /// **When the hub refuses the answer because the item has one**, the app reads the item one time more and says
    /// whether that answer is this option. **The answer** of a write that went: `need`, `choice`, `answered` true,
    /// `signed` (`door-call` for the yes, `door-mode` for Full access), `server` (the card's server, in a server's
    /// own form), and `note`. Then the app reads the fleet again, started and not waited for.
    @MainActor
    public static func answer<Place, Item>(fields: [String: JSONValue], value: OwnerChannel.Value?,
                                           desk: Desk<Place, Item>) async -> OwnerChannel.Answer {
        // 1. The fields.
        guard value == nil else { return .refused(noPart) }
        let read: Read
        switch Self.read(fields) {
        case .failure(let refusal): return .refused(refusal.text)
        case .success(let taken): read = taken
        }
        // 2. A current reading of the database that the program read.
        guard let place = desk.ready() else { return .refused(notReady) }
        guard desk.database(place) == read.generation else { return .refused(otherFleet) }
        // 3. The item.
        let found: ItemRead<Item>
        do { found = try await desk.item(place, read.need) } catch { return .refused(itemUnread) }
        let item: Item, card: Card
        switch found {
        case .otherGeneration: return .refused(otherFleet)
        case .none: return .refused(noItem)
        case .found(let one, let facts): (item, card) = (one, facts)
        }
        guard card.signs(read.press) else { return .refused(notDoorPress) }
        guard card.open else {
            return .refused(card.chosen == Int(read.press.rawValue) ? answeredWithThis : answeredAlready)
        }
        // 4. The signature.
        let statement: String, signature: String
        switch await desk.sign(place, item, read.press) {
        case .signed(let made, let signed): (statement, signature) = (made, signed)
        case .moved: return .refused(moved)
        case .notOffered: return .refused(notOffered)
        case .card(let stop): return .refused(words(stop))
        case .vaultUnread: return .refused(vaultUnread)
        case .noFleet: return .refused(noFleet)
        case .noOwnerKey: return .refused(noOwnerKey)
        case .notSignedNow: return .refused(notSignedNow)
        }
        // 5 and 6: the caller, and then the one write.
        if Task.isCancelled { return .refused(ended) }
        do {
            try await desk.send(place, read.need, read.press, statement, signature)
        } catch is AnswerSecret.Answered {
            // Which answer the item has now, by one read more: the same press of an earlier call, or another answer.
            guard case .found(_, let now)? = try? await desk.item(place, read.need), !now.open,
                  now.chosen == Int(read.press.rawValue) else { return .refused(answeredFirst) }
            return .refused(hadAnswerWithThis)
        } catch SaveBotToken.HubFailure.refused(let status, let said) where status < 500 {
            return .refused(GrantSecret.withHubWords(refused, status: status, said))
        } catch {
            return .refused(notKnown)
        }
        await desk.refresh()
        return .result(result(read, card))
    }

    /// **A server's name as the door's access file has it** (`DoorCall.isHost` in FleetCore, `hub.py` `SERVER_HOST`; a
    /// test holds the two equal): lower-case letters, digits, dots and hyphens, at most 63, a letter or a digit first.
    static func isHost(_ host: String) -> Bool {
        let bytes = Array(host.utf8)
        func letterOrDigit(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) }
        guard let first = bytes.first, bytes.count <= 63, letterOrDigit(first) else { return false }
        return bytes.allSatisfy { letterOrDigit($0) || $0 == 0x2D || $0 == 0x2E }
    }

    /// The answer of a write that went. No free text of the hub or of the card is in it: the server only in a server's
    /// own form.
    static func result(_ read: Read, _ card: Card) -> JSONValue {
        var answer: [String: JSONValue] = [
            "need": .int(Int64(read.need)), "choice": .int(read.press.rawValue), "answered": .bool(true),
            "signed": .string(read.press.kind),
            "note": .string(read.press == .runOnce ? noteRunOnce : noteFullAccess),
        ]
        if let host = card.host, isHost(host) { answer["server"] = .string(host) }
        return .object(answer)
    }
}
