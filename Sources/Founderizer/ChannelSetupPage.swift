import AppKit
import FleetCore
import SwiftUI

// The steps of an agent's channel (CHAT-APPS.md 18; the owner's "Yes, build it" of 14 November 2026 to their clickable
// mock): each one centered step on a page, as an agent's setup is (`SetupPage`, `SetupStep`), in place of the agent's
// People page.
//
//   WhatsApp   1. Link <agent>'s WhatsApp number: the QR code of the bridge.
//   Discord    1. Add a Discord bot for <agent>, 2. Add it to your server (`DiscordBotPage`).
//   Telegram   1. Add a Telegram bot for <agent> (`TelegramBotPage`; CHAT-APPS.md 19, the owner's "Yes, build it" of
//              15 November 2026 to its seven pictures).
//   All three  then "Who can write to <agent>?", with You first: a click on You opens "Write to <agent> from your
//              phone" (or "from your Discord", "from your Telegram"), the owner's own link; and "<agent> is on
//              WhatsApp" (or Discord, Telegram), with Done. An agent that no person can write to (the fleet's
//              manager) has the owner's own link in place of the tiles.
//
// He named three faults of the cards before these steps: "it says remove number when I haven't entered or linked any,
// it shows Removed outside of the card all the time", and "I need an entire experience, including choosing who each
// can talk to". So nothing of a channel stays when he leaves before a phone linked, and a change that worked is the
// card's own new state. On 15 November 2026 he asked for himself among the people who can write: "there should be an
// option to add the owner himself! ... like the same person who created the hub and talks to the agents on the app".
// To the mock of the You tile he chose "Only the You tile": his own link opens from that tile, and no longer by itself
// before the tiles.

/// Which steps stand in place of an agent's People page.
enum ChannelSetup: Equatable {
    /// Connect and Link again of the WhatsApp card.
    case whatsApp
    /// Connect of the Discord card (`adding`), or Fix token and Change token.
    case discord(adding: Bool)
    /// Connect of the Telegram card (`adding`), or Fix token and Change token.
    case telegram(adding: Bool)
    /// The owner's own link alone, from a connected card's menu: Link my phone, Link my Discord, Link my Telegram.
    case me(app: String)
}

/// **WhatsApp, step one: the agent's own number.** The page asks the hub for the number's QR code when it opens, and
/// its title is moving words until the bridge gives one. The code changes by itself until the phone links; then the
/// steps that both apps share follow (`ChannelFollowSteps`). Back before the phone linked leaves nothing: the number
/// that this visit made, or found left over with no phone ever, is taken away again. A number that worked (Link again)
/// stays.
struct WhatsAppSetupPage: View {
    @Bindable var store: FleetStore
    let agent: String
    /// The hub serves the people: the steps after the number show.
    let follows: Bool
    /// The number's account, written now when the agent has none, and the hub asked for its QR code: the account's ID.
    /// Its argument says whether the step still wants it.
    let start: @MainActor (@MainActor () -> Bool) async throws -> String
    /// Takes away a number that no phone linked.
    let remove: (String) async -> Void
    let refresh: () async -> Void
    let close: () -> Void

    /// The number whose code shows, and its last link reading.
    @State private var account: String?
    @State private var link: ChatLinkReading?
    /// When Founderizer asked for a code: until the bridge answers, an older state of the link does not count.
    @State private var asked: Date?
    @State private var starting = false
    @State private var problem: String?
    /// This page drew a code for the number that it links now.
    @State private var drew = false
    /// What the number was when these steps opened, which decides what Back does with it.
    private enum Found { case made, leftOver, worked }
    @State private var found: Found?
    /// The hub's time when Founderizer last asked for a code.
    @State private var askedAt: Double = 0
    /// This page saw the phone link.
    @State private var linked = false
    @State private var leaving = false
    private let client = ChatAppsClient()

    private var name: String { ChatAppWords.agent(agent) }
    /// The accounts as the Channels page last read them: the store's reading, so a wait reads the newest one.
    private var accounts: ChatAppsSnapshot? { store.reading("channels.accounts.\(agent)") }
    private var number: ChatAppsSnapshot.Account? { accounts?.channel("whatsapp", of: agent) }
    private var code: String? {
        guard asked == nil, let link, link.state == "waiting", let qr = link.qr, !qr.isEmpty else { return nil }
        return qr
    }

    var body: some View {
        Group {
            // Only what this page saw: an old report of the bridge about an account of this name is no link.
            if linked {
                if follows {
                    ChannelFollowSteps(store: store, app: "whatsapp", agent: agent, flow: true, refresh: refresh, close: close)
                } else {
                    // A hub without the people has no further step: the card says Connected.
                    Color.clear.task { close() }
                }
            } else {
                SetupPage {
                    SetupBack(action: leave).keyboardShortcut(.cancelAction).accessibilityIdentifier("whatsapp-back")
                } step: {
                    step.animation(.easeInOut(duration: 0.18), value: code)
                }
                .foregroundStyle(FleetStyle.text)
                .task { await begin() }
                .task(id: account) {
                    link = nil
                    while let id = account, !Task.isCancelled {
                        await readLink(id)
                        do { _ = try await store.nap(2) } catch { return }
                    }
                }
            }
        }
        .accessibilityIdentifier("whatsapp-setup")
    }

    private var mark: some View {
        BrandMark(app: "whatsapp", size: SetupMetrics.mark).foregroundStyle(BrandMark.color("whatsapp"))
    }

    @ViewBuilder private var step: some View {
        if let code {
            SetupStep(title: String(l10n: "Link \(name)'s WhatsApp number")) { mark } content: {
                // A little wider than a field: WhatsApp's own path is one line.
                SetupSteps([String(l10n: "Take the phone with its own number, not yours"),
                            String(l10n: "WhatsApp › Settings › Linked devices › Link a device"),
                            String(l10n: "Scan this code")], width: SetupMetrics.field + 40)
                QRCodeView(text: code, size: 196).accessibilityIdentifier("whatsapp-qr")
            }
        } else if let problem {
            // What stopped it, in one orange line over the one way on.
            SetupStep(title: String(l10n: "Link \(name)'s WhatsApp number")) { mark } content: {
                SetupWarning(problem).accessibilityIdentifier("whatsapp-problem")
                if store.writesNow {
                    Button("Try again") { Task { await begin() } }
                        .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("whatsapp-again")
                }
            }
        } else {
            SetupStep(title: String(l10n: "Getting the code for \(name)"), waits: true) { mark }
                .accessibilityIdentifier("whatsapp-waiting")
        }
    }

    /// The number, and the hub asked for its code. A refusal is the step's orange line, with Try again. While the hub
    /// does not answer, the step waits under its moving title: the window's own notice says an outage.
    private func begin() async {
        guard !starting, account == nil, !linked else { return }
        starting = true; problem = nil
        defer { starting = false }
        do {
            // Back ends this wait too: nothing was made yet, so Back has nothing to take away.
            while (!store.writesNow || accounts == nil) && !leaving { _ = try await store.nap(1) }
            guard !leaving else { return }
            if found == nil { found = number.map { $0.neverLinked ? .leftOver : .worked } ?? .made }
            let id = try await start { !leaving }
            link = nil; asked = Date(); drew = false; account = id
            // The hub's time now: its last state's time and the time since that reading.
            askedAt = (store.state?.time ?? 0) + Date().timeIntervalSince(store.lastSuccess ?? Date())
        } catch is CancellationError {
        } catch HubError.invalidResponse {
            // The hub took the write and gave nothing that this page can go on with.
            problem = String(l10n: "The hub gave no code.")
        } catch {
            problem = ChatAppWords.reason(error)
        }
    }

    /// One reading of the number's link. A reading that fails is read again in 2 seconds, and the window's own notice
    /// says an outage: the page says nothing of it.
    private func readLink(_ id: String) async {
        guard let db = store.state?.db, let reading = try? await client.link(hub: store.hub, database: db, account: id),
              account == id else { return }
        link = reading
        if let at = asked, reading.state == "waiting" || reading.state == "linked" || Date().timeIntervalSince(at) > 30 {
            asked = nil
        }
        guard asked == nil else { return }
        if reading.state == "waiting", reading.qr?.isEmpty == false { drew = true }
        if reading.state == "linked" {
            await refresh()
            linked = true
        } else if reading.state == "error" || reading.state == "logged_out" {
            // The link ended with no scan: the bridge's reason, or what this page saw, and Try again asks for a new code.
            problem = ChatApps.clean(reading.error)
                ?? (drew ? String(l10n: "The code was not scanned.") : String(l10n: "The hub gave no code."))
            account = nil
        }
    }

    /// Back: out of the steps. The number that this visit made, or found left over, goes with it, so its card says
    /// Connect again. It decides on a reading made now, after a start that is on its way has ended.
    private func leave() {
        guard !leaving else { return }
        leaving = true
        Task {
            while starting { try? await Task.sleep(for: .milliseconds(100)) }
            await refresh()
            if let number, found == .made || found == .leftOver, !scanned(number) { await remove(number.id) }
            close()
        }
    }

    /// A phone took this number in this visit: after Founderizer asked for the code, the hub's link says so, or the
    /// bridge reported its number. Before the ask, what the hub holds of an account of this name is an older one's
    /// (the hub empties the link when it takes the ask).
    private func scanned(_ number: ChatAppsSnapshot.Account) -> Bool {
        guard askedAt > 0 else { return false }
        if number.link?.state == "linked" { return true }
        return (number.status_at ?? 0) > askedAt && (number.isConnected || number.user != nil)
    }
}

/// **The steps that both apps share, after the channel is connected.**
///
///   1. **Who can write to <agent>?** (only for an agent that people can reach: not the fleet's manager, and not one
///      that cannot hold a conversation) **You** first, then each person of the fleet as a tile, and New person. You is
///      ticked while the owner has an ID of this app, and is then no button: the hub knows that ID on every account of
///      the app. Else a click on You opens step two, which comes back here with You ticked. A click on a person gives
///      the person this agent, and asks first for their number or ID of this app when they have none. A person who
///      could write here already is ticked and is no button: their own page changes that. New person opens Add person,
///      with this agent.
///   2. **Write to <agent> from your phone** (or "from your Discord"): the owner's own link. The hub makes a one-time
///      code once it knows where the code goes (this agent's own number, or its bot); for WhatsApp a QR code opens the
///      chat with that number, with the message ready, and for Discord the message stands with Copy over Open Discord.
///      Until then the title is moving words. The page goes on by itself when the hub has bound the sender, and makes
///      a new code by itself when one ends. Back goes to the tiles. For an agent with no tiles this page is the first
///      step, with Skip as the one quiet link under it, and an owner who has an ID of this app already passes over it.
///   3. **<agent> is on WhatsApp**: what these steps did, and Done.
///
/// From a connected card's menu (Link my phone, Link my Discord) the page is step two alone (`flow` false).
/// The accounts and the people are the Channels page's own readings, which it reads again every 2 seconds while
/// these steps show.
struct ChannelFollowSteps: View {
    @Bindable var store: FleetStore
    let app: String
    let agent: String
    /// The steps of a channel that was just connected; false for the owner's link alone.
    let flow: Bool
    let refresh: () async -> Void
    let close: () -> Void

    private enum Page: Equatable { case me, who, handle(Int), newPerson, done }
    /// What a tick of the tiles wrote for one person: it is undone when the tick goes.
    private struct Tick: Equatable {
        var agent = false
        var handle: PersonInput.HandleInput?
    }

    /// The page that he went to; nil is the page that the steps open on.
    @State private var chosen: Page?
    @State private var code: LinkCode?
    /// The owner's IDs of this app when the code was made, and when it was made.
    @State private var before: Set<String> = []
    @State private var made = Date()
    @State private var problem: String?
    @State private var ticked: [Int: Tick] = [:]
    /// The people that New person made from these steps.
    @State private var newPeople: Set<Int> = []
    @State private var draft = PersonInput.HandleInput()
    @State private var writing: Int?
    /// Telegram: the invite of the person whose page shows (CHAT-APPS.md 19.4), and that person.
    @State private var invite: LinkCode?
    @State private var invited: Int?
    private let chat = ChatAppsClient()
    private let client = PeopleClient()

    private var whatsApp: Bool { app == "whatsapp" }
    private var telegram: Bool { app == "telegram" }
    private var name: String { ChatAppWords.agent(agent) }
    private var people: PeopleSnapshot? { store.reading("channels.people.\(agent)") }
    private var account: ChatAppsSnapshot.Account? {
        (store.reading("channels.accounts.\(agent)") as ChatAppsSnapshot?)?.channel(app, of: agent)
    }
    /// The owner can write from this app already, and on Telegram to this bot too (CHAT-APPS.md 19.4).
    private var ownerLinked: Bool {
        let handles = people.map { !$0.handles(of: app).isEmpty } == true
        return account?.ownerLinked(handles: handles) ?? handles
    }
    private var canWrite: Bool { store.writesNow && store.state?.db != nil && writing == nil }
    /// People can write to a worker and to a lead that can hold a conversation, never to the fleet's manager (the hub
    /// refuses it) and not to an agent that other people cannot reach yet (`People.cannotChat`): such an agent's steps
    /// have no tiles, and the owner's own link stands in their place.
    private var takesPeople: Bool {
        guard let one = store.state?.agents.first(where: { $0.name == agent }), ["worker", "lead"].contains(one.role) else { return false }
        return People.cannotChat(role: one.role, runtime: one.runtime, active: one.active) == nil
    }
    /// The step after the owner's own link: back to the tiles that opened it, or the end.
    private var next: Page { takesPeople ? .who : .done }
    /// The page that shows. **It is whole in its first frame**: the steps of a new channel open on the tiles; for an
    /// agent with no tiles they open on the owner's own link, or on the end when the owner can write from this app
    /// already.
    private var page: Page { chosen ?? (flow ? (takesPeople ? .who : (ownerLinked ? .done : .me)) : .me) }
    /// Skip stands under the owner's own link only where that link is a step of its own: in the steps of an agent with
    /// no tiles. Opened from You, the page's Back is the way out.
    private var skips: Bool { flow && !takesPeople }
    /// The hub knows where a code of this app goes: the agent's own number, or its bot's ID.
    private var hasAddress: Bool { account?.isConnected == true && (account?.user ?? account?.name) != nil }

    var body: some View {
        Group {
            if page == .newPerson {
                // Add person is a setup of its own, with its own Back: this agent is theirs from its first step.
                AddPersonView(store: store, roles: people?.roleList ?? [], existing: people?.peopleList.count ?? 0, handle: nil,
                              agent: agent, back: { chosen = .who },
                              // Telegram: a new person writes from it only after their invite (CHAT-APPS.md 19.4)
                              added: { id in newPeople.insert(id); chosen = telegram ? .handle(id) : .who; Task { await refresh() } })
            } else {
                SetupPage {
                    SetupBack(action: back).keyboardShortcut(.cancelAction).accessibilityIdentifier("channel-steps-back")
                } step: {
                    Group {
                        switch page {
                        case .me: me
                        case .who: who
                        // A person who is gone while their page shows: the tiles again.
                        case .handle(let id): if let person = people?.person(id) { handle(person) } else { who }
                        case .done: done
                        case .newPerson: EmptyView()
                        }
                    }.animation(.easeInOut(duration: 0.18), value: page)
                }
                .foregroundStyle(FleetStyle.text)
            }
        }
        .task { await watchLink() }
        .accessibilityIdentifier("channel-steps-\(app)")
    }

    private var mark: some View {
        BrandMark(app: app, size: SetupMetrics.mark).foregroundStyle(BrandMark.color(app))
    }

    /// One page back; out of the steps from the first one. A page that the steps passed over is passed over again.
    private func back() {
        problem = nil
        switch page {
        case .me: if flow && takesPeople { chosen = .who } else { close() }
        case .who: close()
        case .handle, .newPerson: chosen = .who
        case .done: if takesPeople { chosen = .who } else if ownerLinked { close() } else { chosen = .me }
        }
    }

    // MARK: the owner's own link

    /// Where the code goes: this agent's own number or bot, and no other agent's.
    private var target: URL? {
        guard let id = account?.id else { return nil }
        return code?.targets.first { $0.account == id }?.link
    }

    @ViewBuilder private var me: some View {
        let title = whatsApp ? String(l10n: "Write to \(name) from your phone")
            : telegram ? String(l10n: "Write to \(name) from your Telegram") : String(l10n: "Write to \(name) from your Discord")
        if let code, let target {
            SetupStep(title: title) { mark } content: {
                if whatsApp {
                    SetupSteps([String(l10n: "Scan this code with your own phone"), String(l10n: "Send the message that is ready")])
                    QRCodeView(text: target.absoluteString, size: 196).accessibilityIdentifier("channel-me-qr")
                } else if telegram {
                    // The deep link of the agent's bot with the code in it: Telegram sends /start <code> (19.3).
                    SetupSteps([String(l10n: "Scan this code with your phone"), String(l10n: "Press Start")])
                    QRCodeView(text: target.absoluteString, size: 196).accessibilityIdentifier("channel-me-qr")
                } else {
                    SetupSteps([String(l10n: "Press Open Discord"), String(l10n: "Send the bot this message")])
                    message(code)
                }
                // While Receive messages is off in Settings, the hub takes no message: the page says why nothing comes.
                if store.state?.chat_apps?.paused == true {
                    SetupWarning(String(l10n: "Paused in Settings")).accessibilityIdentifier("channel-me-paused")
                }
                // The way on stays in view in a low window (`SetupAction`).
                SetupAction {
                    if whatsApp {
                        Link(destination: target) { Text("Open WhatsApp on this Mac") }
                            .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("channel-me-open")
                    } else if telegram {
                        Link(destination: target) { Text("Open Telegram") }
                            .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("channel-me-open")
                    } else {
                        Link(destination: target) { Text("Open Discord") }
                            .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("channel-me-open")
                    }
                    if skips { skip }
                }
            }
        } else if let problem {
            // What stopped it, in one orange line over the one way on.
            SetupStep(title: title) { mark } content: {
                SetupWarning(problem).accessibilityIdentifier("channel-me-problem")
                if store.isFresh {
                    Button("Try again") { self.problem = nil }
                        .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("channel-me-again")
                }
                if skips { skip }
            }
        } else {
            // No code yet. Where the link is a step of its own, Skip is there too: nothing holds him on a wait.
            SetupStep(title: String(l10n: "Getting your code"), waits: true) { mark } content: {
                if skips { skip }
            }
            .accessibilityIdentifier("channel-me-waiting")
        }
    }

    private var skip: some View {
        SetupLink(String(l10n: "Skip")) { problem = nil; chosen = next }.accessibilityIdentifier("channel-me-skip")
    }

    /// The message that binds its sender, in the step's own words, with Copy.
    private func message(_ code: LinkCode) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "link \(code.display)").textSelection(.enabled).accessibilityIdentifier("channel-me-code")
            Spacer(minLength: 8)
            MessageAction(symbol: "square.on.square", label: String(l10n: "Copy the message")) { copyMessage("link \(code.display)") }
                .foregroundStyle(FleetStyle.muted)
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(width: 260, height: SetupMetrics.fieldHeight)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(FleetStyle.line, lineWidth: 0.5))
    }

    /// While the owner's own link shows: a code once the hub knows where it goes, a new one when the one there ended,
    /// and the way on when the hub bound the sender. It looks once a second, at the readings that the Channels page
    /// keeps. After a refusal it waits for Try again.
    private func watchLink() async {
        while !Task.isCancelled {
            if page == .me, problem == nil, store.isFresh {
                let now = Date()
                if let open = code {
                    let left = ChatApps.remaining(expires: open.expires, serverTime: store.state?.time ?? 0,
                                                  readAt: store.lastSuccess ?? now, now: now)
                    if let people, people.bound(app, before: before, codeOpen: now > made.addingTimeInterval(1) && left > 0) {
                        code = nil
                        if flow { chosen = next } else { close(); return }
                    } else if left <= 0 {
                        await makeCode()
                    }
                } else if people != nil, hasAddress {
                    await makeCode()
                }
            }
            do { _ = try await store.nap(1) } catch { return }
        }
    }

    private func makeCode() async {
        guard store.writesNow, let db = store.state?.db, let people, let id = account?.id else { return }
        do {
            let new = try await chat.makeCode(hub: store.hub, database: db, client: store.installation, app: app)
            guard store.state?.db == db else { return }
            // A code is of use only with where it goes: this agent's own number or bot.
            // A refusal is said only on the link page: one that comes after he went back to the tiles is not a line
            // under them, and the link's next visit asks again.
            guard new.targets.contains(where: { $0.account == id && $0.link != nil }) else {
                code = nil
                if page == .me { problem = String(l10n: "The hub gave no code.") }
                return
            }
            before = Set(people.handles(of: app).map(\.key)); made = Date(); code = new
        } catch {
            code = nil
            if page == .me { problem = ChatAppWords.reason(error) }
        }
    }

    // MARK: the tiles

    /// The person can write to this agent from this app: the agent is theirs, the hub lets them talk to it, and they
    /// have a number or an ID of the app.
    private func reaches(_ person: PeopleSnapshot.Person) -> Bool {
        person.agents.contains { $0.agent == agent && $0.can_chat } && person.handles.contains { $0.app == app }
    }

    private var who: some View {
        SetupStep(title: String(l10n: "Who can write to \(name)?")) { mark } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                // You first, once the hub's people are read: the owner's own IDs come in that reading.
                if people != nil { you }
                ForEach(people?.peopleList ?? []) { tile($0) }
                // Add person chooses between the hub's roles: its tile is there once they are read.
                if people?.roleList.isEmpty == false { newPerson }
            }
            // A fleet of many people scrolls: Continue stays in view (`SetupAction`).
            SetupAction {
                if let problem { SetupWarning(problem).accessibilityIdentifier("channel-who-problem") }
                Button("Continue") { problem = nil; chosen = .done }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("channel-who-on")
            }
        }
    }

    /// **You**: the owner, on the same tile as a person, with no second line. Ticked while the owner has an ID of this
    /// app, and then no button, as a person who could write here before is: the hub knows that ID on every account of
    /// the app. Else a click opens the owner's own link, which comes back here once the hub has bound the sender.
    private var you: some View {
        Button {
            guard canWrite else { return }
            problem = nil; chosen = .me
        } label: {
            face(Text("You"), Text(verbatim: " "), on: ownerLinked)
        }
        .buttonStyle(FleetCardButtonStyle())
        .disabled(ownerLinked || !canWrite)
        .accessibilityLabel(Text("You"))
        .accessibilityValue(ownerLinked ? Text("Chosen") : Text("Not chosen"))
        .accessibilityIdentifier("channel-who-you")
    }

    /// One person: their name and what they are to him, and a check mark while they can write to this agent here.
    private func tile(_ person: PeopleSnapshot.Person) -> some View {
        let on = reaches(person), mine = ticked[person.id] != nil
        return Button {
            // Who could write here before these steps is theirs to change on their own page. A tile that is not ticked
            // ticks, also after a half of its write went in: the try sends the other half.
            guard !on || mine else { return }
            Task { if on { await untick(person) } else { await tick(person) } }
        } label: {
            face(Text(person.name), Text(person.roleWord), on: on)
        }
        .buttonStyle(FleetCardButtonStyle())
        // No button for who could write here before, or while a write is on its way: a card of this look does not fade.
        .disabled((on && !mine) || !canWrite)
        .accessibilityLabel(person.name)
        .accessibilityValue(on ? Text("Chosen") : Text("Not chosen"))
        .accessibilityIdentifier("channel-who-\(person.id)")
    }

    /// The face of a tile of somebody who can write here: the person mark, the name and a second line, and while they
    /// can write here a check mark and the accent edge.
    private func face(_ name: Text, _ detail: Text, on: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle").font(IconMetrics.symbol(34, weight: .light)).foregroundStyle(FleetStyle.muted)
                .frame(height: GlyphSize.hero).accessibilityHidden(true)
            name.fontWeight(.medium).foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
            detail.foregroundStyle(FleetStyle.muted).lineLimit(1)
        }
        .padding(.vertical, 18).padding(.horizontal, 12).frame(maxWidth: .infinity).contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if on {
                Image(systemName: "checkmark").font(IconMetrics.symbol(12, weight: .semibold))
                    .foregroundStyle(FleetStyle.text).padding(12)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(on ? FleetStyle.accent : .clear, lineWidth: 1.5))
    }

    private var newPerson: some View {
        Button { if canWrite { problem = nil; chosen = .newPerson } } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(IconMetrics.symbol(28, weight: .light)).foregroundStyle(FleetStyle.muted)
                    .frame(height: GlyphSize.hero).accessibilityHidden(true)
                Text("New person").fontWeight(.medium).foregroundStyle(FleetStyle.text).lineLimit(1)
                Text(verbatim: " ").accessibilityHidden(true)
            }
            .padding(.vertical, 18).padding(.horizontal, 12).frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .accessibilityIdentifier("channel-who-new")
    }

    /// A tick: the person gets this agent. One with no number or ID of this app is asked for it first.
    private func tick(_ person: PeopleSnapshot.Person) async {
        problem = nil
        guard person.handles.contains(where: { $0.app == app }) else {
            draft = .init(app: app)
            chosen = .handle(person.id)
            return
        }
        _ = await write(person, handle: nil)
    }

    /// What a tick writes: their number or ID of this app when they had none, then this agent on their list. True when
    /// the hub took all of it. A try after a half of it went in sends only the other half.
    private func write(_ person: PeopleSnapshot.Person, handle: PersonInput.HandleInput?) async -> Bool {
        guard canWrite, let db = store.state?.db else { return false }
        writing = person.id
        defer { writing = nil }
        var wrote = ticked[person.id] ?? Tick()
        var done = false
        do {
            if let handle, wrote.handle?.handle != handle.handle {
                _ = try await client.handle(hub: store.hub, database: db, client: store.installation, person: person.id, handle: handle)
                wrote.handle = handle
                ticked[person.id] = wrote
            }
            if !person.agentNames.contains(agent) {
                var input = PersonInput(person)
                input.agents = (person.agentNames + [agent]).sorted()
                _ = try await client.change(hub: store.hub, database: db, client: store.installation, person: person, to: input)
                wrote.agent = true
            }
            ticked[person.id] = wrote
            done = true
        } catch {
            problem = People.reason(error)
        }
        await refresh()
        // The hub says when this person cannot talk to this agent after all (their role, the agent's Shell box).
        if done, let entry = people?.person(person.id)?.agents.first(where: { $0.agent == agent }), !entry.can_chat, let says = entry.says {
            problem = says
        }
        return done
    }

    /// The tick goes: exactly what it wrote goes with it.
    private func untick(_ person: PeopleSnapshot.Person) async {
        guard canWrite, let db = store.state?.db, let wrote = ticked[person.id] else { return }
        problem = nil
        writing = person.id
        defer { writing = nil }
        do {
            if wrote.agent, person.agentNames.contains(agent) {
                var input = PersonInput(person)
                input.agents = person.agentNames.filter { $0 != agent }
                _ = try await client.change(hub: store.hub, database: db, client: store.installation, person: person, to: input)
            }
            if let handle = wrote.handle {
                _ = try await client.handle(hub: store.hub, database: db, client: store.installation, person: person.id,
                                            handle: handle, delete: true)
            }
            ticked[person.id] = nil
        } catch {
            problem = People.reason(error)
        }
        await refresh()
    }

    // MARK: their number or ID of this app

    @ViewBuilder private func handle(_ person: PeopleSnapshot.Person) -> some View {
        if telegram { invitePage(person) } else { typedHandle(person) }
    }

    private func typedHandle(_ person: PeopleSnapshot.Person) -> some View {
        SetupStep(title: whatsApp ? String(l10n: "\(person.name)'s phone number") : String(l10n: "\(person.name)'s Discord user ID")) {
            mark
        } content: {
            SetupField(placeholder: People.handlePlaceholder(app), text: $draft.typed,
                       wrong: !draft.typed.isEmpty && draft.problem != nil) { Task { await keep(person) } }
                .accessibilityIdentifier("channel-who-handle")
            // Where to find it stays under the field while he types; what is wrong with it is said under that.
            Text(People.handleHint(app)).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("channel-who-hint")
            if !draft.typed.isEmpty, let why = draft.problem {
                SetupWarning(why).accessibilityIdentifier("channel-who-handle-problem")
            } else {
                // The hub's refusal stays over the way on, which is there for the next try.
                if let problem { SetupWarning(problem).accessibilityIdentifier("channel-who-handle-refused") }
                if draft.problem == nil, canWrite {
                    Button("Add") { Task { await keep(person) } }
                        .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("channel-who-keep")
                }
            }
        }
        // What he types next is a new try: the refusal of the last one goes.
        .onChange(of: draft.typed) { problem = nil }
    }

    /// One press of Add, or Return: a second one while the first is on its way does nothing.
    private func keep(_ person: PeopleSnapshot.Person) async {
        guard draft.problem == nil, canWrite else { return }
        problem = nil
        if await write(person, handle: draft) { draft = .init(); chosen = .who }
    }

    // MARK: Telegram — a person's invite link (CHAT-APPS.md 19.4)

    /// Telegram's apps do not show a person their own ID, so the person gets a link of their own to the agent's bot. He
    /// sends it to them in any way; when they open it and press Start, the hub binds their Telegram to them. Continue
    /// gives them this agent now, so their first message after Start reaches it. The link works once, for 7 days.
    private func invitePage(_ person: PeopleSnapshot.Person) -> some View {
        let link = invited == person.id ? invite?.link(on: account?.id) : nil
        return SetupStep(title: String(l10n: "Invite \(person.name) on Telegram"), waits: link == nil && problem == nil) {
            mark
        } content: {
            if let link {
                QRCodeView(text: link.absoluteString, size: 196).accessibilityIdentifier("channel-invite-qr")
                HStack(spacing: 8) {
                    Text(verbatim: link.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityIdentifier("channel-invite-link")
                    Spacer(minLength: 8)
                    MessageAction(symbol: "square.on.square", label: String(l10n: "Copy link")) { copyMessage(link.absoluteString) }
                        .foregroundStyle(FleetStyle.muted)
                }
                .padding(.leading, 12).padding(.trailing, 6).frame(width: SetupMetrics.field, height: SetupMetrics.fieldHeight)
                .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(FleetStyle.line, lineWidth: 0.5))
                Text("\(person.name) opens it and presses Start. It works for 7 days.").foregroundStyle(FleetStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SetupAction {
                if let problem { SetupWarning(problem).accessibilityIdentifier("channel-invite-problem") }
                if link != nil || problem != nil {
                    Button("Continue") { Task { await keepInvite(person) } }
                        .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(!canWrite)
                        .accessibilityIdentifier("channel-invite-on")
                }
            }
        }
        // again when the app may write again (`writesNow`, as for the owner's own code): the link comes by itself
        .task(id: "\(person.id)/\(store.writesNow)") { await makeInvite(person) }
    }

    /// The person's invite, once for each visit of their page: a new one replaces the one before it at the hub.
    private func makeInvite(_ person: PeopleSnapshot.Person) async {
        guard invited != person.id, store.writesNow, let db = store.state?.db else { return }
        problem = nil
        do {
            let made = try await store.telegramInvite(for: person, agent: agent, bot: account) {
                try await chat.makeInvite(hub: store.hub, database: db, client: store.installation, person: person.id, agent: agent)
            }
            guard store.state?.db == db else { return }
            guard made.link(on: account?.id) != nil else {
                problem = String(l10n: "The hub gave no link.")
                return
            }
            invite = made; invited = person.id
        } catch {
            // a read that the page stopped (it went on, or the hub's reading turned old) says nothing
            if !Task.isCancelled { problem = People.reason(error) }
        }
    }

    /// Continue: the person gets this agent (their Telegram comes with their Start), and the tiles show again.
    private func keepInvite(_ person: PeopleSnapshot.Person) async {
        if await write(person, handle: nil) { invite = nil; invited = nil; chosen = .who }
    }

    // MARK: the end

    /// What these steps did, each line ticked: the channel, the owner's own link, and each person they gave it to
    /// (a tick, or New person) who can write here now.
    private var doneLines: [String] {
        var lines: [String] = []
        if let account {
            let shown = whatsApp ? (account.name ?? account.user).map { ChatApps.masked($0, app: app) }
                : telegram ? account.name.map { "@" + $0 } : account.name
            lines.append(shown ?? ChatApps.title(app))
        }
        if ownerLinked {
            lines.append(whatsApp ? String(l10n: "Your phone") : telegram ? String(l10n: "Your Telegram") : String(l10n: "Your Discord"))
        }
        lines += (people?.peopleList ?? []).filter { (ticked[$0.id] != nil || newPeople.contains($0.id)) && reaches($0) }.map(\.name)
        return lines
    }

    private var done: some View {
        SetupStep(title: String(l10n: "\(name) is on \(ChatApps.title(app))")) { mark } content: {
            VStack(alignment: .leading, spacing: 10) {
                // By their place: two people can have one name.
                ForEach(Array(doneLines.enumerated()), id: \.offset) { _, line in
                    Label {
                        Text(line).foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }.accessibilityIdentifier("channel-steps-done")
            // A long list scrolls: Done stays in view (`SetupAction`).
            SetupAction {
                Button("Done", action: close)
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("channel-done")
            }
        }
    }
}
