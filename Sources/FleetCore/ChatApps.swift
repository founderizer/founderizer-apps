import Foundation

// Chat apps (owner features `chat_apps` and `people`): the owner messages each agent from its own WhatsApp number and
// Discord bot, the agent's Channels. The hub keeps the accounts in team.json, the owner's own IDs (handles) and the
// link codes; a bridge on the hub machine talks to the two apps. An agent can write to the owner first
// (`reports[].pushed`), and agents message each other (`GET /ui/agent-messages`). A Discord token goes to the hub once,
// from the view's state only (`BotToken`). Round 3 (CHAT-APPS.md 17): each account belongs to exactly one agent, and
// `ChannelCard` gives the state of each card of the agent's Channels page.

/// A yes-or-no field that the hub gives as a boolean or as 0 and 1 (`reports[].pushed`).
public struct HubFlag: Decodable, Equatable, Sendable {
    public let value: Bool
    public init(_ value: Bool) { self.value = value }
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let flag = try? single.decode(Bool.self) { value = flag } else { value = try single.decode(Int.self) != 0 }
    }
}

/// `messages[].origin`: the chat app that an owner message came from. nil for a message from this app.
public struct MessageOrigin: Decodable, Equatable, Sendable {
    public let app: String
    public let account: String?
    public let label: String?
}

/// `reports[].delivery`: the newest outbound message of a reply that answers a chat-app message.
public struct ReportDelivery: Decodable, Equatable, Sendable {
    public let app: String
    public let account: String?
    /// `queued`, `sending`, `sent`, `delivered`, `read`, `failed` or `unknown`.
    public let state: String
    public let at: Double?
    public let error: String?
    /// The outbound item, for Send again.
    public let outbound: Int?

    /// Not sent, or not known to be sent: the line is orange.
    public var isProblem: Bool { state == "failed" || state == "unknown" }
    /// Only the owner decides to send a part again whose outcome is not known, or that failed.
    public var canSendAgain: Bool { isProblem && (outbound ?? 0) > 0 }

    /// The delivery line: "Sent to WhatsApp · Read 14:03". `time` gives the short time of `at`.
    public func words(time: (Double) -> String) -> String {
        let app = ChatApps.title(self.app), when = at.map { time($0) }
        switch state {
        case "queued": return String(l10n: "Waiting to send to \(app)")
        case "sending": return String(l10n: "Sending to \(app)…")
        case "sent": return when.map { String(l10n: "Sent to \(app) · \($0)") } ?? String(l10n: "Sent to \(app)")
        case "delivered":
            return when.map { String(l10n: "Sent to \(app) · Delivered \($0)") } ?? String(l10n: "Sent to \(app) · Delivered")
        case "read": return when.map { String(l10n: "Sent to \(app) · Read \($0)") } ?? String(l10n: "Sent to \(app) · Read")
        case "failed":
            let reason = (error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.isEmpty { return String(l10n: "Not sent to \(app).") }
            return reason.hasSuffix(".") ? String(l10n: "Not sent: \(reason)") : String(l10n: "Not sent: \(reason).")
        case "unknown": return String(l10n: "Delivery to \(app) not confirmed")
        default: return String(l10n: "\(app) delivery: \(state)")
        }
    }
}

/// `/ui/state` `chat_apps`: Pause all, and the number of enabled accounts that are not connected or not linked.
public struct ChatAppsSummary: Decodable, Equatable, Sendable {
    public let paused: Bool
    public let problems: Int
}

/// How a state shows: its mark color.
public enum ChatTone: Equatable, Sendable {
    /// Green: connected or receiving.
    case good
    /// A gray ring: waiting, or an old reading.
    case waiting
    /// Orange: the owner has something to do.
    case problem
    /// A gray ring: nothing there yet, or turned off.
    case off
}

/// A status: a dot and one or two words. `detail` is the longer reason for the hover text. `readingAt` is set when the
/// words come from an old reading: the hover text then says "Last reading" with that time.
public struct ChatStateWords: Equatable, Sendable {
    public let words: String
    public let tone: ChatTone
    public var detail: String?
    public var readingAt: Double?

    public init(words: String, tone: ChatTone, detail: String? = nil, readingAt: Double? = nil) {
        self.words = words; self.tone = tone; self.detail = detail; self.readingAt = readingAt
    }
}

/// `GET /ui/chat-apps?db=`: the accounts of team.json with what the bridge last reported for each.
public struct ChatAppsSnapshot: Decodable, Sendable {
    public struct Link: Decodable, Equatable, Sendable {
        /// `waiting`, `linked`, `logged_out` or `error`.
        public let state: String
        public let expires: Double?
        public let error: String?
    }

    public struct Account: Decodable, Identifiable, Equatable, Sendable {
        public let id: String
        public let app: String
        public let label: String
        public let agents: [String]
        public let enabled: Bool?
        /// The bridge's state: `connected`, `connecting`, `missing_token`, `logged_out` or `error`; nil before its
        /// first report.
        public let state: String?
        public let user: String?
        /// The bot's name, or the WhatsApp number.
        public let name: String?
        public let error: String?
        public let invite_url: String?
        public let status_at: Double?
        public let link: Link?
        /// When a message last came in on this account (hub time); nil when none ever did.
        public let last_event: Double?
        /// A message of one of the owner's handles came in through this account (hub 1.243; nil from an older hub). A
        /// Telegram bot writes first to the owner only then: each bot needs his own Start (CHAT-APPS.md 19.4).
        public let owner_wrote: Bool?

        public var isEnabled: Bool { enabled != false }
        /// **No phone holds this WhatsApp number now**: it is not connected, the bridge knows no number for it, and the
        /// hub's link of it is not a phone's. A linked number whose bridge starts again keeps its link in the hub, so it
        /// is never read as this while it reconnects.
        public var holdsNoPhone: Bool {
            app == "whatsapp" && state != "connected" && user == nil && name == nil && link?.state != "linked"
        }
        /// **A WhatsApp number that no phone ever linked**: no phone holds it, and no message ever came in on it. The
        /// app wrote the account to ask for a QR code, and nobody scanned one. It is no number of the owner's, so its
        /// card offers Connect, which takes this account (the owner, 14 November 2026: "it says remove number when I
        /// haven't entered or linked any"). A number that worked and lost its link has had a message.
        public var neverLinked: Bool { holdsNoPhone && last_event == nil }
        /// The Invite to server link, only as a Discord address.
        public var inviteURL: URL? { ChatApps.safeLink(invite_url, hosts: ["discord.com"]) }
        /// On and connected (Discord) or linked (WhatsApp), in the bridge's last report.
        public var isConnected: Bool { isEnabled && state == "connected" }
        /// The account of this agent alone: only it answers there.
        public func belongs(to agent: String) -> Bool { agents == [agent] }
        /// The owner's own link is done on this account: he has an ID of its app (`handles`), and on Telegram he also
        /// wrote to this bot, which can write to him first only then. A hub before 1.243 says nothing of the bot.
        public func ownerLinked(handles: Bool) -> Bool { handles && (app != "telegram" || owner_wrote != false) }
    }

    public let db: String
    public let paused: Bool
    /// The last contact of the bridge (hub time), or nil when the bridge never connected.
    public let bridge_seen: Double?
    /// The hub gave `bridge_seen` as `true`, without a time.
    public let bridgeSeenWithoutTime: Bool
    public let accounts: [Account]
    /// The team.json version that the page read: the hub's, or the client's from `GET /ui/team`. Writes send it back
    /// as `base_sha256`.
    public internal(set) var sha256: String?

    enum CodingKeys: String, CodingKey { case db, paused, bridge_seen, accounts, sha256 }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        db = try values.decode(String.self, forKey: .db)
        paused = try values.decode(Bool.self, forKey: .paused)
        accounts = try values.decode([Account].self, forKey: .accounts)
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
        if let time = try? values.decodeIfPresent(Double.self, forKey: .bridge_seen) {
            bridge_seen = time; bridgeSeenWithoutTime = false
        } else {
            bridge_seen = nil; bridgeSeenWithoutTime = (try? values.decodeIfPresent(Bool.self, forKey: .bridge_seen)) == true
        }
    }

    /// The account of one app that an agent's card shows. Each account belongs to one agent (CHAT-APPS.md 17.1), so an
    /// account of several agents from an older team.json shows on no card. Of the agent's own accounts: a connected
    /// one, else one that is on, else the first.
    public func channel(_ app: String, of agent: String) -> Account? {
        let own = accounts.filter { $0.app == app && $0.belongs(to: agent) }
        return own.first(where: \.isConnected) ?? own.first(where: \.isEnabled) ?? own.first
    }

    /// **The account that a person's Telegram invite to this agent goes through** (CHAT-APPS.md 19.4), or nil when
    /// none can take one now: a Telegram account of this agent alone that is on, whose bot has said its name, which the
    /// link needs; a connected one first. It is the hub's own test (`new_invite_code`, `telegram_link`), so a person's
    /// Add handle offers Telegram only where the hub makes the link; `channel` also gives an account that is off, whose
    /// card still shows.
    public func telegramInviteAccount(of agent: String) -> Account? {
        let takers = accounts.filter { account in
            account.app == "telegram" && account.belongs(to: agent) && account.isEnabled
                && (account.name ?? "").range(of: "^[A-Za-z][A-Za-z0-9_]{3,31}$", options: .regularExpression) != nil
        }
        return takers.first(where: \.isConnected) ?? takers.first
    }

    /// A person's Telegram invite to this agent can be made now (`telegramInviteAccount`).
    public func canInviteOnTelegram(to agent: String) -> Bool { telegramInviteAccount(of: agent) != nil }

    /// A channel of this agent needs the owner: its card is orange. The sidebar's dot and the card read the same state.
    public func needsOwner(_ agent: String, serverTime: Double?) -> Bool {
        ChatApps.apps.contains { app in ChannelCard(app: app, agent: agent, in: self, serverTime: serverTime).needsOwner }
    }

    /// The bridge's dot in Settings: online while it calls the hub, offline after three minutes without a call.
    public func bridgeStatus(serverTime: Double?) -> ChatStateWords {
        if bridgeSeenWithoutTime { return ChatStateWords(words: "Bridge online", tone: .good) }
        guard let bridge_seen else { return ChatStateWords(words: "No bridge", tone: .problem, detail: "The bridge has not connected yet.") }
        if let serverTime, serverTime - bridge_seen > ChatApps.statusAge {
            return ChatStateWords(words: "Bridge offline", tone: .problem, detail: "The bridge is not in contact.", readingAt: bridge_seen)
        }
        return ChatStateWords(words: "Bridge online", tone: .good)
    }

    public func validate(database: String) throws {
        guard db == database, Set(accounts.map(\.id)).count == accounts.count, accounts.allSatisfy({ ChatApps.isAccountID($0.id) }),
              sha256.map({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) != false
        else { throw HubError.invalidResponse }
    }
}

/// One card of an agent's Channels (CHAT-APPS.md 17.2 and 18): the agent's own WhatsApp number or Discord bot, one
/// status, at most one main action, and the other actions for the card's "…" menu. A channel that is not connected is
/// its mark, its name and Connect, for both apps, and a number that no phone ever linked is not connected.
public struct ChannelCard: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Not connected: no number or no bot, or a number that no phone ever linked.
        case none
        /// The bridge has not reported the account yet, or it connects.
        case connecting
        case connected
        /// WhatsApp: logged out, or the link failed.
        case unlinked
        /// Discord: no token, or the bridge could not connect the bot.
        case failed
        /// Turned off in team.json (an older app version could do this).
        case off
    }

    public enum Action: String, Equatable, Sendable { case connect, linkAgain, fixToken, turnOn }
    /// `linkMe` is the owner's own link (Link my phone, Link my Discord): only in `menu(for:)`, while they have no ID
    /// of the app.
    public enum MenuItem: String, Equatable, Sendable { case linkMe, invite, changeToken, unlink, remove }

    public let app: String
    public let account: ChatAppsSnapshot.Account?
    public let kind: Kind
    public let status: ChatStateWords
    public let action: Action?
    public let menu: [MenuItem]

    public init(app: String, agent: String, in snapshot: ChatAppsSnapshot?, serverTime: Double?) {
        self.app = app
        let account = snapshot?.channel(app, of: agent)
        self.account = account
        let whatsApp = app == "whatsapp"
        // Its words are for a reader of the screen (the card's accessibility value): the card draws its mark, its name
        // and Connect, and no status.
        let none = ChatStateWords(words: String(l10n: "Not connected"), tone: .off)
        guard let account else {
            kind = .none; action = .connect; menu = []; status = none
            return
        }
        // Turned off comes first: the bridge does not run such an account, so Connect could not work on it.
        guard account.isEnabled else {
            kind = .off; action = .turnOn; menu = [.remove]
            status = ChatStateWords(words: String(l10n: "Turned off"), tone: .off)
            return
        }
        guard !account.neverLinked else {
            kind = .none; action = .connect; menu = []; status = none
            return
        }
        let reason = ChatApps.clean(account.link?.error) ?? ChatApps.clean(account.error)
        var kind: Kind, action: Action?, menu: [MenuItem] = [.remove], status: ChatStateWords
        switch (whatsApp, account.state) {
        case (_, "connected"):
            kind = .connected; status = ChatStateWords(words: String(l10n: "Connected"), tone: .good)
            menu = whatsApp ? [.unlink, .remove] : (account.inviteURL == nil ? [] : [.invite]) + [.changeToken, .remove]
        case (_, nil) where account.link == nil, (_, "connecting") where account.link?.state != "waiting":
            kind = .connecting; status = ChatStateWords(words: String(l10n: "Connecting…"), tone: .waiting)
        case (false, "missing_token"):
            kind = .failed; action = .fixToken
            status = ChatStateWords(words: String(l10n: "No token"), tone: .problem, detail: String(l10n: "The hub server has no token for this bot."))
        case (false, let state):
            kind = .failed; action = .fixToken
            status = ChatStateWords(words: state == "logged_out" ? String(l10n: "Logged out") : ChatApps.shortReason(account.error), tone: .problem,
                                    detail: reason ?? String(l10n: "The bridge could not connect the bot."))
        case (true, _):
            kind = .unlinked; action = .linkAgain
            status = ChatStateWords(words: String(l10n: "Unlinked"), tone: .problem, detail: reason)
        }
        // A bridge report older than three minutes is the last reading, never a current state.
        if let serverTime, let at = account.status_at, serverTime - at > ChatApps.statusAge {
            status.readingAt = at
            if status.tone == .good { status = ChatStateWords(words: status.words, tone: .waiting, detail: status.detail, readingAt: at) }
        }
        self.kind = kind; self.action = action; self.menu = menu; self.status = status
    }

    /// The card's title: the number or the bot's name while it is connected, else the app's name.
    public var title: String {
        guard kind == .connected, let account else { return ChatApps.title(app) }
        if app == "whatsapp" { return (account.name ?? account.user).map { ChatApps.masked($0, app: app) } ?? ChatApps.title(app) }
        // A Telegram bot is known by its username, which Telegram writes with an @.
        if app == "telegram", let name = account.name, !name.isEmpty { return "@" + name }
        return account.name ?? account.label
    }

    /// Orange: the owner has something to do.
    public var needsOwner: Bool { status.tone == .problem }

    /// The owner has no ID of this app yet, and this card's account can take the owner's code: the card's menu then has
    /// Link my phone (or Link my Discord), the owner's own link ("Write to <agent> from your phone").
    public func asksForOwnerLink(_ people: PeopleSnapshot?) -> Bool {
        guard kind == .connected, let people else { return false }
        let handles = !people.handles(of: app).isEmpty
        return !(account?.ownerLinked(handles: handles) ?? handles)
    }

    /// The card's "…" menu: the owner's own link first, only while it is still to do.
    public func menu(for people: PeopleSnapshot?) -> [MenuItem] {
        (asksForOwnerLink(people) ? [.linkMe] : []) + menu
    }
}

/// The Discord page (17.3) after Save: the bridge's first report after the send says how the new token went.
public enum DiscordProgress: Equatable, Sendable {
    /// No token was sent from this page yet.
    case paste
    case connecting
    case connected(String)
    case refused(String)

    /// `sentAt` is the hub time of the send: an older report is about the old token.
    public init(bot: ChatAppsSnapshot.Account?, sentAt: Double?) {
        guard let sentAt else { self = .paste; return }
        guard let bot, (bot.status_at ?? 0) > sentAt else { self = .connecting; return }
        switch bot.state {
        case "connected": self = .connected(bot.name ?? bot.label)
        case "error", "logged_out": self = .refused(bot.state == "logged_out" ? String(l10n: "Logged out") : ChatApps.shortReason(bot.error))
        default: self = .connecting
        }
    }
}

/// `GET /ui/chat-apps/<id>/link?db=`: the link of a WhatsApp number, with the current QR text while it waits for a scan.
public struct ChatLinkReading: Decodable, Equatable, Sendable {
    public let state: String?
    public let qr: String?
    public let expires: Double?
    public let error: String?
}

/// `GET /ui/people?db=`: the owner's own IDs on the chat apps and the open link codes.
public struct PeopleSnapshot: Decodable, Sendable {
    public struct Handle: Decodable, Equatable, Sendable {
        public let app: String
        /// The platform ID: a Discord user ID, or a WhatsApp JID.
        public let id: String
        public let alias: String?
        public let name: String?
        public let linked: Double?
        public var key: String { "\(app)/\(id)" }
    }
    public struct Owner: Decodable, Sendable { public let handles: [Handle] }

    /// Who wrote to one account and got no answer, as the hub keeps it: the hub answers the owner and nobody
    /// else, so a message from anyone else is counted, kept as a masked preview, and dropped. The hub keeps the
    /// last twenty of each account.
    ///
    /// This is the one place the owner can see that somebody tried to reach an agent of theirs. It is not a
    /// conversation and it never becomes one here: nothing in this app or in the hub can answer these people.
    public struct Ignored: Decodable, Equatable, Sendable {
        /// The account that was written to, as `ChatAppsSnapshot.Account.id` names it.
        public let account: String
        /// How many were ignored today.
        public let today: Int
        public let last: [Message]

        public struct Message: Decodable, Equatable, Sendable, Identifiable {
            /// The platform id of the sender: a Discord user id, or a WhatsApp JID.
            public let sender: String?
            /// The name the app itself gives for them, when it gives one.
            public let name: String?
            /// The first 200 characters of what they wrote, with any registered login masked by the hub.
            public let preview: String?
            public let ts: Double
            public var id: String { "\(sender ?? "")/\(ts)" }

            /// Who it was, in the owner's own words: a name when the app gave one, else the id it gave.
            public var who: String {
                let said = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !said.isEmpty { return String(said.prefix(80)) }
                let id = (sender ?? "").split(separator: "@").first.map(String.init) ?? ""
                return id.isEmpty ? String(l10n: "Somebody") : String(id.prefix(40))
            }

            /// What they wrote, bounded as the hub bounds it, or nil when the message carried no text.
            public var said: String? {
                let text = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : String(text.prefix(200))
            }
        }

        /// How many of each account the hub keeps (`CHAT_IGNORED_KEEP`).
        public static let kept = 20
        /// The newest first, as the hub orders them, and never more than the hub keeps.
        public var messages: [Message] { Array(last.prefix(Ignored.kept)) }
    }
    public struct Code: Decodable, Equatable, Sendable {
        public let app: String
        public let expires: Double
    }
    public let db: String
    public let owner: Owner
    public let codes: [Code]?
    /// One entry for each account of this fleet, which the hub sends whether or not anybody wrote.
    public let ignored: [Ignored]?
    /// API 1.17: the three roles with what each one means and which tools that role's window gets. The app never
    /// writes these words itself. nil on a hub without the people of 1.17. The types are in `People.swift`.
    public let roles: [Role]?
    /// API 1.17: every person the owner added, with their handles, their agents and their conversations.
    public let people: [Person]?

    public func handles(of app: String) -> [Handle] { owner.handles.filter { $0.app == app } }
    /// The open code of one app, as the hub keeps it: its time, never its text.
    public func code(of app: String) -> Code? { codes?.first { $0.app == app } }

    /// Who wrote to this account and was not answered, when anybody did.
    public func ignored(of account: String) -> Ignored? {
        guard let found = ignored?.first(where: { $0.account == account }),
              !found.messages.isEmpty || found.today > 0 else { return nil }
        return found
    }

    /// A handle of `app` that was not there when the code was made: the hub bound it.
    public func newHandle(of app: String, before: Set<String>) -> Handle? {
        handles(of: app).first { !before.contains($0.key) }
    }

    /// The hub took the owner's code of `app`: a new ID of that app, or, while the code still works (`codeOpen`), the
    /// hub no longer has it and the app has an ID (the same ID linked again).
    public func bound(_ app: String, before: Set<String>, codeOpen: Bool) -> Bool {
        newHandle(of: app, before: before) != nil || (codeOpen && codes != nil && code(of: app) == nil && !handles(of: app).isEmpty)
    }

    public func validate(database: String) throws {
        guard db == database else { throw HubError.invalidResponse }
    }
}

/// The answer to `POST /ui/people/codes`: an owner link code for one app, and where to send it.
public struct LinkCode: Decodable, Sendable {
    public struct Target: Decodable, Equatable, Sendable {
        public let account: String
        public let label: String?
        public let url: String?
        /// The address to show as a QR code and as a link: only a Discord, WhatsApp or Telegram address over HTTPS.
        public var link: URL? { ChatApps.safeLink(url, hosts: ["discord.com", "wa.me", "t.me"]) }
    }
    public let ok: Bool
    public let request_id: String
    public let client: String
    /// nil in a replay: the hub keeps no code.
    public let code: String?
    public let expires: Double
    public let targets: [Target]
    /// The code as the owner types it: `XXXX-XXXX`.
    public var display: String { ChatApps.displayCode(code ?? "") }

    /// **The link of this code on one account's bot**, or nil: the account of a person's Telegram invite. An answer
    /// with none for it is the line "The hub gave no link." (CHAT-APPS.md 19.4), on a person's page as on the setup
    /// steps, never a form that waits for ever.
    public func link(on account: String?) -> URL? {
        guard let account else { return nil }
        return targets.first { $0.account == account }?.link
    }

    /// Where to send the code: the first of `accounts` that has a link, else any target with a link, else the first
    /// of `accounts`, else the first target.
    public func target(preferring accounts: [String]) -> Target? {
        let preferred = accounts.compactMap { id in targets.first { $0.account == id } }
        return preferred.first { $0.link != nil } ?? targets.first { $0.link != nil } ?? preferred.first ?? targets.first
    }
}

/// **A person's Telegram invite as this Mac made it** (CHAT-APPS.md 19.4). The hub keeps no code, and a new invite of a
/// person replaces their open one, so a page that made a new one at each visit stopped the link that the owner had sent
/// already. A visit shows the kept invite again while it works for another hour, is for the same agent and the same bot
/// (its account and its username, which the link names), for the same person (with their `added` time, a second guard:
/// since owner API 1.232 a removed person's number never comes back), and the person took no Telegram link since; else
/// it asks the hub for a new one. **It keeps only an invite with a link on its bot**: one with none would show "The hub
/// gave no link." at each visit for its 7 days, and make no new one.
public struct KeptInvite: Sendable {
    public let invite: LinkCode
    public let agent: String
    /// The bot's account and its username, which the link names.
    public let bot: String
    public let added: Double?
    /// The person's Telegram handles when the invite was made.
    public let handles: [String]

    /// The invite to keep for this person's next visit, or nil when it has no link on its bot.
    public init?(_ invite: LinkCode, person: PeopleSnapshot.Person, agent: String, bot: ChatAppsSnapshot.Account?) {
        guard invite.link(on: bot?.id) != nil else { return nil }
        self.invite = invite
        self.agent = agent
        self.bot = Self.name(of: bot)
        self.added = person.added
        self.handles = Self.telegramHandles(of: person)
    }

    /// A visit shows this invite again: the same person, agent and bot, no Telegram link of the person's since, and
    /// more than an hour left by the hub's clock (`ChatApps.remaining`).
    public func serves(_ person: PeopleSnapshot.Person, agent: String, bot: ChatAppsSnapshot.Account?,
                       serverTime: Double, readAt: Date, now: Date) -> Bool {
        self.agent == agent && bot != nil && self.bot == Self.name(of: bot) && added == person.added
            && handles == Self.telegramHandles(of: person)
            && ChatApps.remaining(expires: invite.expires, serverTime: serverTime, readAt: readAt, now: now) > 3600
    }

    static func name(of bot: ChatAppsSnapshot.Account?) -> String { bot.map { "\($0.id) \($0.name ?? "")" } ?? "" }

    static func telegramHandles(of person: PeopleSnapshot.Person) -> [String] {
        person.handles.filter { $0.app == "telegram" }.map(\.handle).sorted()
    }
}

/// A Discord or Telegram bot token that the owner pasted, for one send with `POST /ui/chat-apps/<id>/token`. It lives
/// only in a view's state and in that request: it never prints, never goes into a draft or the pending outbox, and its
/// description and mirror hide the value.
public struct BotToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String
    /// The app whose form the token has: `discord` or `telegram`.
    let app: String

    /// The pasted text without spaces and line ends at its ends, if it has the hub's form: 50 to 100 characters of
    /// `A-Z a-z 0-9 . _ -`.
    public init?(pasted: String) {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (50...100).contains(text.count), text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) })
        else { return nil }
        value = text; app = "discord"
    }

    /// A Telegram bot's token as @BotFather gives it (CHAT-APPS.md 19.1): the bot's number, a colon and its key, of
    /// 30 to 80 characters of `A-Z a-z 0-9 _ -`.
    public init?(telegram pasted: String) {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "^[0-9]{5,20}:[A-Za-z0-9_-]{30,80}$", options: .regularExpression) != nil else { return nil }
        value = text; app = "telegram"
    }

    public var description: String { app == "telegram" ? "Telegram bot token (hidden)" : "Discord bot token (hidden)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The answer to `POST /ui/chat-apps/<id>/token`: whether the hub has a token file for the bot now, and whether it
/// replaced one. It never holds the token.
public struct TokenReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let id: String?
    public let set: Bool?
    public let replaced: Bool?
}

/// `GET /ui/agent-messages`: one message between two agents (`message_agent`). The owner reads them; only agents
/// send them, and a message has its sender's authority, never the owner's.
public struct AgentMessage: Decodable, Identifiable, Equatable, Sendable {
    /// The number of `AM-<n>`.
    public let id: Int
    public let sender: String
    public let recipient: String
    public let text: String
    /// The number of the message that this one answers.
    public let inReplyTo: Int?
    public let created: Double
    public let read_at: Double?

    public var label: String { "AM-\(id)" }

    public init(id: Int, sender: String, recipient: String, text: String, inReplyTo: Int? = nil, created: Double, read_at: Double? = nil) {
        self.id = id; self.sender = sender; self.recipient = recipient; self.text = text; self.inReplyTo = inReplyTo
        self.created = created; self.read_at = read_at
    }

    enum CodingKeys: String, CodingKey { case id, sender, recipient, text, in_reply_to, created, read_at }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let number = try Self.number(values, .id) else { throw HubError.invalidResponse }
        id = number
        sender = try values.decode(String.self, forKey: .sender)
        recipient = try values.decode(String.self, forKey: .recipient)
        text = try values.decode(String.self, forKey: .text)
        inReplyTo = try Self.number(values, .in_reply_to)
        created = try values.decode(Double.self, forKey: .created)
        read_at = try values.decodeIfPresent(Double.self, forKey: .read_at)
    }

    /// `AM-12`, `12` or the number 12; nil for null or no field.
    private static func number(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int? {
        guard values.contains(key), try !values.decodeNil(forKey: key) else { return nil }
        if let number = try? values.decode(Int.self, forKey: key) { return number > 0 ? number : nil }
        let text = try values.decode(String.self, forKey: key)
        let digits = text.hasPrefix("AM-") ? String(text.dropFirst(3)) : text
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let number = Int(digits), number > 0 else { throw HubError.invalidResponse }
        return number
    }
}

/// One page of `GET /ui/agent-messages?db=&agent=&after=`: at most 200 messages that the agent sent or got, oldest
/// first, after the message `after`.
public struct AgentMessagesPage: Decodable, Sendable {
    public let db: String
    public let messages: [AgentMessage]

    public func validate(database: String, agent: String, after: Int) throws {
        let ids = messages.map(\.id)
        guard db == database, ids.count <= AgentMessages.pageSize, ids == ids.sorted(), Set(ids).count == ids.count,
              ids.allSatisfy({ $0 > after }), messages.allSatisfy({ $0.sender == agent || $0.recipient == agent })
        else { throw HubError.invalidResponse }
    }
}

public enum AgentMessages {
    /// The owner feature of `GET /ui/agent-messages`.
    public static let feature = "agent_messages"
    /// The hub gives at most this many messages in one page.
    public static let pageSize = 200
    /// The messages that a page keeps in memory: the newest ones.
    public static let kept = 1000

    /// The messages after one more page: new numbers at the end, oldest first, at most `keep` of the newest.
    public static func merged(_ current: [AgentMessage], _ page: [AgentMessage], keep: Int = kept) -> [AgentMessage] {
        let known = Set(current.map(\.id))
        let all = (current + page.filter { !known.contains($0.id) }).sorted { $0.id < $1.id }
        return Array(all.suffix(max(0, keep)))
    }
}

/// The command fields of a chat apps write, and the fields of each answer.
public struct ChatReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let replayed: Bool?
    public let paused: Bool?
    public let sha256: String?
    public let changed: Bool?
}

/// One account as the owner saves it in team.json (`POST /ui/team/chat-apps`): for one agent, with no `default`
/// (CHAT-APPS.md 17.5). `unknown` is always `ignore`.
public struct ChatAccountInput: Equatable, Sendable {
    public var app: String
    public var label: String
    public var agents: [String]
    public var enabled: Bool

    public init(app: String, label: String, agents: [String], enabled: Bool = true) {
        self.app = app; self.label = label; self.agents = agents; self.enabled = enabled
    }

    public init(_ account: ChatAppsSnapshot.Account) {
        self.init(app: account.app, label: account.label, agents: account.agents, enabled: account.isEnabled)
    }

    /// The JSON object: `enabled` only when it is off.
    public var fields: [String: Any] {
        var fields: [String: Any] = ["app": app, "label": label, "agents": agents, "unknown": "ignore"]
        if !enabled { fields["enabled"] = false }
        return fields
    }
}

public enum ChatApps {
    public static let feature = "chat_apps"
    public static let peopleFeature = "people"
    /// The bridge reports every 60 seconds: an older report is an old reading.
    public static let statusAge: Double = 180
    /// The hub serves Telegram (CHAT-APPS.md 19, owner API 1.243): only then a Channels page shows its card.
    public static let telegramFeature = "telegram"
    /// The cards of a Channels page, in their order.
    public static let apps = ["whatsapp", "discord", "telegram"]

    /// The cards that a hub with these features serves: Telegram only where the hub knows it, so that Connect never
    /// writes an account that an older hub refuses.
    public static func shown(features: [String]?) -> [String] {
        apps.filter { $0 != "telegram" || features?.contains(telegramFeature) == true }
    }

    public static func title(_ app: String) -> String {
        switch app {
        case "discord": "Discord"
        case "whatsapp": "WhatsApp"
        case "telegram": "Telegram"
        default: app.capitalized
        }
    }

    public static func isAccountID(_ id: String) -> Bool { id.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil }

    /// A new account ID: `<app>-<agent>`, with a number at the end when that ID is taken.
    public static func accountID(app: String, agent: String, taken: Set<String>) -> String {
        var stem = "\(app)-\(agent)"
        stem = String(stem.lowercased().map { $0 == "_" || $0 == "." || $0 == " " ? "-" : $0 }
            .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        stem = String(stem.prefix(36))
        while stem.hasSuffix("-") { stem.removeLast() }
        if !taken.contains(stem) { return stem }
        var number = 2
        while taken.contains("\(stem)-\(number)") { number += 1 }
        return "\(stem)-\(number)"
    }

    /// One agent's own number or bot: the account `whatsapp-<agent>`, `discord-<agent>` or `telegram-<agent>` (then
    /// `-2`, `-3` and so on) with that agent only, labelled as the apps name the agent (its name with capitals, or
    /// its role when one word of the role is the name: `agentLabel`), and the number of a second account ("Studio 2").
    public static func agentAccount(app: String, agent: String, taken: Set<String>) -> (id: String, account: ChatAccountInput) {
        let id = accountID(app: app, agent: agent, taken: taken), stem = accountID(app: app, agent: agent, taken: [])
        let suffix = id == stem ? "" : " " + id.dropFirst(stem.count + 1)
        let name = agent.agentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = label(String(name.prefix(40 - suffix.count)) + suffix) ?? ChatApps.title(app)
        return (id, ChatAccountInput(app: app, label: label, agents: [agent]))
    }

    /// A label as the hub takes it: 1 to 40 characters on one line, without spaces at the ends; else nil.
    public static func label(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(value.count), !value.contains(where: \.isNewline) else { return nil }
        return value
    }

    /// The seconds that a link code still works, on the hub's clock: `serverTime` is the hub time of the last state,
    /// read at `readAt`.
    public static func remaining(expires: Double, serverTime: Double, readAt: Date, now: Date) -> Double {
        max(0, expires - (serverTime + now.timeIntervalSince(readAt)))
    }

    /// A Discord error in one or two words; the full text goes to the hover text. Close code 4004 is a refused token.
    public static func shortReason(_ error: String?) -> String {
        let text = (error ?? "").lowercased()
        return text.contains("4004") || text.contains("authentication") || text.contains("token") ? String(l10n: "Token refused") : String(l10n: "Not connected")
    }

    /// A reason from the bridge without spaces at its ends, and with an end mark; nil for none.
    public static func clean(_ text: String?) -> String? {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.hasSuffix(".") ? value : value + "."
    }

    /// An owner code as the owner types it: `XXXX-XXXX`.
    public static func displayCode(_ code: String) -> String {
        let plain = code.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard plain.count == 8 else { return code.uppercased() }
        return "\(plain.prefix(4))-\(plain.suffix(4))"
    }

    /// A number on a card: a phone number is masked (`+34 6•• ••• 412`), a hidden WhatsApp ID says so, and
    /// a Discord ID stays.
    public static func masked(_ id: String, app: String) -> String {
        guard app == "whatsapp", !id.contains("•") else { return id }
        let user = id.split(separator: "@", maxSplits: 1).first.map(String.init) ?? id
        if id.hasSuffix("@lid") { return String(l10n: "Hidden number") }
        let digits = user.split(separator: ":").first.map { $0.filter(\.isNumber) } ?? ""
        guard digits.count >= 7 else { return digits.isEmpty ? String(l10n: "Hidden number") : "+•••\(digits.suffix(2))" }
        let start = Array(digits)
        return "+\(String(start[0..<2])) \(start[2])•• ••• \(digits.suffix(3))"
    }

    /// SVG path data with each command and number apart. CoreSVG does not read an arc's flags when they touch the next
    /// number ("0 01-5.03"), which the SVG grammar permits and the Simple Icons paths of the brand marks use.
    public static func spacedPath(_ path: String) -> String {
        let chars = Array(path)
        var tokens: [String] = [], index = 0, command: Character = " ", argument = 0
        while index < chars.count {
            let char = chars[index]
            if char.isLetter && char != "e" && char != "E" {
                command = char; argument = 0; tokens.append(String(char)); index += 1
            } else if char == " " || char == "," || char.isNewline {
                index += 1
            } else if "aA".contains(command), argument % 7 == 3 || argument % 7 == 4 {
                // An arc's large-arc and sweep flags: one character each.
                tokens.append(String(char)); argument += 1; index += 1
            } else {
                var end = index
                if "+-".contains(chars[end]) { end += 1 }
                var dot = false
                while end < chars.count, chars[end].isASCII && chars[end].isNumber || (chars[end] == "." && !dot) {
                    if chars[end] == "." { dot = true }
                    end += 1
                }
                if end < chars.count, "eE".contains(chars[end]) {
                    end += 1
                    if end < chars.count, "+-".contains(chars[end]) { end += 1 }
                    while end < chars.count, chars[end].isASCII && chars[end].isNumber { end += 1 }
                }
                end = max(end, index + 1)
                tokens.append(String(chars[index..<end])); argument += 1; index = end
            }
        }
        return tokens.joined(separator: " ")
    }

    /// A link from the hub that the app shows: HTTPS on one of `hosts` only.
    static func safeLink(_ text: String?, hosts: Set<String>) -> URL? {
        guard let text, let parts = URLComponents(string: text), parts.scheme == "https", let host = parts.host?.lowercased(),
              hosts.contains(host), parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
}

/// The chat apps routes of the owner address: the accounts, Pause all, the WhatsApp link, Send again, the Discord token,
/// the owner's link codes and handles, and the messages between agents. Each write is one command with a new request ID and the current `db`. A write that gets no answer
/// can have arrived: the page reads again before the owner tries again. An account write goes against the team.json
/// version that the page read (`base_sha256`); the hub refuses an old version (409).
public final class ChatAppsClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60        // an account write commits and pushes team.json first
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: ChatNoRedirect(), delegateQueue: nil)
    }

    /// The accounts, with the team.json version: from `GET /ui/team` before the accounts, so that a change between the
    /// two reads makes the next write fail (409) and not overwrite it.
    public func read(hub: URL, database: String) async throws -> ChatAppsSnapshot {
        let team = try JSONDecoder().decode(TeamVersion.self, from: await get("ui/team", hub: hub, database: database))
        guard team.db == database else { throw HubError.invalidResponse }
        var snapshot = try JSONDecoder().decode(ChatAppsSnapshot.self, from: await get("ui/chat-apps", hub: hub, database: database))
        if snapshot.sha256 == nil { snapshot.sha256 = team.sha256 }
        try snapshot.validate(database: database)
        return snapshot
    }

    public func people(hub: URL, database: String) async throws -> PeopleSnapshot {
        let snapshot = try JSONDecoder().decode(PeopleSnapshot.self, from: await get("ui/people", hub: hub, database: database))
        try snapshot.validate(database: database)
        return snapshot
    }

    /// The link state of one WhatsApp number and its current QR text.
    public func link(hub: URL, database: String, account: String) async throws -> ChatLinkReading {
        guard ChatApps.isAccountID(account) else { throw HubError.invalidResponse }
        return try JSONDecoder().decode(ChatLinkReading.self, from: await get("ui/chat-apps/\(account)/link", hub: hub, database: database))
    }

    /// One account in team.json; nil removes it.
    public func saveAccount(hub: URL, database: String, client: String, sha256: String, id: String,
                            account: ChatAccountInput?) async throws -> ChatReceipt {
        try await write(.account(sha256: sha256, id: id, account: account), hub: hub, database: database, client: client)
    }

    public func pause(hub: URL, database: String, client: String, paused: Bool) async throws -> ChatReceipt {
        let receipt = try await write(.pause(paused), hub: hub, database: database, client: client)
        guard receipt.paused == nil || receipt.paused == paused else { throw HubError.invalidResponse }
        return receipt
    }

    /// Asks the bridge to link a WhatsApp number (a QR code follows), or to log it out.
    public func link(hub: URL, database: String, client: String, account: String, unlink: Bool = false) async throws -> ChatReceipt {
        try await write(unlink ? .unlink(account) : .link(account), hub: hub, database: database, client: client)
    }

    /// Queues a new message with the text of an outbound item that failed or whose outcome is not known.
    public func sendAgain(hub: URL, database: String, client: String, outbound: Int) async throws -> ChatReceipt {
        try await write(.sendAgain(outbound), hub: hub, database: database, client: client)
    }

    /// A new owner link code for one app. It replaces the app's open code.
    public func makeCode(hub: URL, database: String, client: String, app: String) async throws -> LinkCode {
        let requestID = UUID().uuidString.lowercased()
        let code = try JSONDecoder().decode(LinkCode.self, from: await post(.code(app), requestID: requestID, hub: hub, database: database, client: client))
        guard code.ok, code.request_id.lowercased() == requestID, code.client == client, code.code?.isEmpty == false
        else { throw HubError.invalidResponse }
        return code
    }

    /// A person's invite link on Telegram (CHAT-APPS.md 19.4): one code for that person, for 7 days, in the deep link
    /// of `agent`'s bot. A new one replaces the open one.
    public func makeInvite(hub: URL, database: String, client: String, person: Int, agent: String) async throws -> LinkCode {
        let requestID = UUID().uuidString.lowercased()
        let code = try JSONDecoder().decode(LinkCode.self, from: await post(.invite(person: person, agent: agent), requestID: requestID,
                                                                           hub: hub, database: database, client: client))
        guard code.ok, code.request_id.lowercased() == requestID, code.client == client, code.code?.isEmpty == false
        else { throw HubError.invalidResponse }
        return code
    }

    /// Sends a Discord or Telegram bot's token to the hub, once and directly: the hub writes the bot's token file. nil
    /// removes the file. A send without an answer can have arrived; the caller asks the owner to paste the token again.
    public func saveToken(hub: URL, database: String, client: String, account: String, token: BotToken?) async throws -> TokenReceipt {
        let requestID = UUID().uuidString.lowercased()
        let receipt = try JSONDecoder().decode(TokenReceipt.self, from: await post(.token(account: account, token: token), requestID: requestID,
                                                                                  hub: hub, database: database, client: client))
        guard receipt.ok, receipt.request_id.lowercased() == requestID, receipt.client == client, receipt.id.map({ $0 == account }) != false,
              receipt.set.map({ $0 == (token != nil) }) != false
        else { throw HubError.invalidResponse }
        return receipt
    }

    /// One page of the messages that an agent sent to other agents or got from them, oldest first, after the message
    /// number `after` (0 for the first page).
    public func agentMessages(hub: URL, database: String, agent: String, after: Int) async throws -> AgentMessagesPage {
        guard !agent.isEmpty, after >= 0 else { throw HubError.invalidResponse }
        let page = try JSONDecoder().decode(AgentMessagesPage.self, from: await get(
            "ui/agent-messages", hub: hub, database: database, query: [.init(name: "agent", value: agent), .init(name: "after", value: String(after))]))
        try page.validate(database: database, agent: agent, after: after)
        return page
    }

    /// One command: its route and the fields of its body, without `request_id` and `db`.
    enum Command {
        case account(sha256: String, id: String, account: ChatAccountInput?)
        case pause(Bool)
        case link(String), unlink(String)
        case sendAgain(Int)
        case code(String)
        case token(account: String, token: BotToken?)
        /// A person's invite on Telegram (CHAT-APPS.md 19.4): a code for that person, in the deep link of the agent's bot.
        case invite(person: Int, agent: String)

        var route: String? {
            switch self {
            case .account(_, let id, _): ChatApps.isAccountID(id) ? "ui/team/chat-apps" : nil
            case .pause: "ui/chat-apps/pause"
            case .link(let account): ChatApps.isAccountID(account) ? "ui/chat-apps/\(account)/link" : nil
            case .unlink(let account): ChatApps.isAccountID(account) ? "ui/chat-apps/\(account)/unlink" : nil
            case .sendAgain(let outbound): outbound > 0 ? "ui/outbound/\(outbound)/again" : nil
            case .code: "ui/people/codes"
            case .token(let account, _): ChatApps.isAccountID(account) ? "ui/chat-apps/\(account)/token" : nil
            case .invite(let person, let agent): person > 0 && !agent.isEmpty ? "ui/people/codes" : nil
            }
        }

        var fields: [String: Any] {
            switch self {
            case .account(let sha256, let id, let account): ["base_sha256": sha256, "id": id, "account": account?.fields ?? NSNull()]
            case .pause(let paused): ["paused": paused]
            case .link, .unlink, .sendAgain: [:]
            case .code(let app): ["purpose": "owner", "app": app]
            case .token(_, let token): token.map { ["token": $0.value] } ?? ["delete": true]
            case .invite(let person, let agent): ["purpose": "invite", "app": "telegram", "person": person, "agent": agent]
            }
        }

        func body(requestID: String, database: String) throws -> Data {
            try IntegrationsClient.body(fields, requestID: requestID, database: database)
        }
    }

    private func write(_ command: Command, hub: URL, database: String, client: String) async throws -> ChatReceipt {
        let requestID = UUID().uuidString.lowercased()
        let receipt = try JSONDecoder().decode(ChatReceipt.self, from: await post(command, requestID: requestID, hub: hub, database: database, client: client))
        guard receipt.ok, receipt.request_id.lowercased() == requestID, receipt.client == client else { throw HubError.invalidResponse }
        return receipt
    }

    private func post(_ command: Command, requestID: String, hub: URL, database: String, client: String) async throws -> Data {
        guard let route = command.route else { throw HubError.invalidResponse }
        var request = URLRequest(url: hub.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try command.body(requestID: requestID, database: database)
        return try await perform(request)
    }

    private func get(_ route: String, hub: URL, database: String, query: [URLQueryItem] = []) async throws -> Data {
        var parts = URLComponents(url: hub.appendingPathComponent(route), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)] + query
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        // A read of the hub that is on its way already, through any client with the same time limits, is the answer to
        // the same read now (`HubReads`, fix round 2); a write never is.
        guard let key = HubReads.key(request, in: session.configuration) else { return try await fetch(request) }
        return try await HubReads.shared.share(key) { [self] in HubReads.Answer(data: try await fetch(request), response: nil) }.data
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
        guard data.count <= 4_194_304 else { throw HubError.invalidResponse }
        return data
    }

    private struct TeamVersion: Decodable { let db: String; let sha256: String }
}

private final class ChatNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
