import FleetCore
import SwiftUI

/// **The names in a request's words are links, and a step on one page of the app opens it** (the lane "Give on a
/// card"; the owner, 19 November 2026: "auto-detect and format an agent, so it becomes a link too", then his picks of
/// the mockup: repositories, servers and app pages, and Open the page). `CardNames` finds the names; this is where the
/// card opens what they name, in this window.
extension FleetStore {
    /// The names that a request's words link: the agents of the hub's reading with their roles, the repositories of
    /// the Apps page's last reading and of the grants of the open requests, and the servers of the Servers page's
    /// last reading. Nothing is read for it: a name that no kept reading holds stays plain words. One book serves every
    /// card, and it is made again only when what it is made of changes (`cardBook`): a card's words are drawn at each
    /// reading of the hub.
    var cardNames: CardNames { books(quiet: false).card }

    /// **The book of a chat's messages** (`MessageText.chatNames`): the same names by the chat's stricter rules
    /// (`ChatNames`), made again with the card's book. **A chat reads the pages' readings that it is made of with no
    /// watch** (`quietReading`): the chat draws again at each reading of the hub, which brings what changed; the Servers
    /// page's reading, which the live round writes every 15 seconds, drew the whole chat again each time (a review of
    /// 21 November 2026: about 5 ms for 200 rows, also during a scroll).
    var chatNames: ChatNames { books(quiet: true).chat }

    /// The symbol of each server by its name, for its badge in a chat's message (`cardServerSymbols`), kept with the
    /// chat's book and read as it is.
    var chatServerSymbols: [String: String] { books(quiet: true).symbols }

    private func books(quiet: Bool) -> (card: CardNames, chat: ChatNames, symbols: [String: String]) {
        let integrations: IntegrationsSnapshot? = quiet ? quietReading("apps.integrations.fleet")
                                                        : reading("apps.integrations.fleet")
        let servers: ServerList? = quiet ? quietReading("servers.list") : reading("servers.list")
        let agents = (state?.agents ?? []).map { (name: $0.name, role: $0.title) }
        let repos = (integrations?.repositories ?? []) + (state?.needs ?? []).flatMap { $0.give?.repos ?? [] }
        let names = servers?.servers.map(\.name) ?? []
        // the owner's own knowledge files (`HubState.knowledge`), and on a hub that gives the app an internal one the
        // agents' too, which the Knowledge page opens read-only (`HubState.internalKnowledge`)
        let files = (state?.knowledge ?? []).map(\.path)
            + (state?.readsInternalKnowledge == true ? (state?.internalKnowledge ?? []).map(\.path) : [])
        let symbols = (servers?.servers ?? []).map { [$0.name, $0.symbol] }
        // the names of the fleet's secrets (`cardSecrets`), read as the rest is read on this path
        let secrets: [(name: String, key: Bool)] = {
            guard SecretEntryView.isOffered(by: self) else { return [] }
            let kept: LoginReading? = quiet ? quietReading("secrets.logins.fleet") : reading("secrets.logins.fleet")
            return kept.map { SecretsList.badges($0.catalog) } ?? []
        }()
        var hasher = Hasher()
        for agent in agents { hasher.combine(agent.name); hasher.combine(agent.role) }
        hasher.combine(repos)
        hasher.combine(names)
        hasher.combine(files)
        hasher.combine(symbols)
        for secret in secrets { hasher.combine(secret.name); hasher.combine(secret.key) }
        let key = hasher.finalize()
        if let kept = cardBook, kept.key == key { return (kept.book, kept.chat, kept.symbols) }
        let book = CardNames(agents: agents, repositories: repos, servers: names, knowledge: files, secrets: secrets)
        // a new book with the same names keeps what the old one read (`ChatNames.keeping`)
        let chat = ChatNames(agents: agents, repositories: repos, servers: names, knowledge: files, secrets: secrets)
            .keeping(cardBook?.chat)
        let byName = Dictionary(symbols.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        cardBook = (key, book, chat, byName)
        return (book, chat, byName)
    }

    /// The book of the names of a request's words: the one book (`cardNames`).
    func cardNames(for need: OwnerNeed) -> CardNames { cardNames }

    /// The symbol of each server of the Servers page's last reading by its name, for its badge in a request's words: a
    /// Mac or a server rack (`ServerEntry.symbol`).
    var cardServerSymbols: [String: String] {
        let servers: ServerList? = reading("servers.list")
        return Dictionary((servers?.servers ?? []).map { ($0.name, $0.symbol) }, uniquingKeysWith: { first, _ in first })
    }

    /// A press of a name in a request's words: an agent's page, a server's page or a page of the app, in this window.
    /// Any other link, a repository's page on GitHub among them, opens as a link does.
    func openCardLink(_ url: URL) -> OpenURLAction.Result {
        guard let target = CardNames.Target(url: url) else { return .systemAction }
        switch target {
        // a link of the app's own that an agent wrote by hand opens only what the fleet has
        case .agent(let name):
            guard state?.agents.contains(where: { $0.name == name }) == true else { return .discarded }
            destination = .agent(name)
        case .server(let name):
            let servers: ServerList? = reading("servers.list")
            guard servers?.servers.contains(where: { $0.name == name }) == true else { return .discarded }
            destination = .server(name)
        case .page(let page):
            guard let place = Self.cardPage(page) else { return .discarded }
            destination = place
        case .knowledge(let path):
            let internalFile = state?.readsInternalKnowledge == true
                && state?.internalKnowledge?.contains(where: { $0.path == path }) == true
            guard state?.knowledge?.contains(where: { $0.path == path }) == true || internalFile else { return .discarded }
            knowledgeRead = path                // Settings › Knowledge opens it when it shows, as for the eye of a
            destination = .settings(.knowledge) // file's card on an agent's Can use (`KnowledgePage.poll`)
        case .repository: return .systemAction
        // **a secret's card over the page where he is** (`showSecret(named:)`); `.handled` brings the main window to
        // the front from a card's own window
        case .secret(let name, _): return showSecret(named: name) ? .handled : .discarded
        }
        return .handled
    }

    /// The page of the app that a key of `CardNames.pages` names, or nil for one that this app does not have.
    static func cardPage(_ page: String) -> Destination? {
        switch page {
        case "needs": return .needs
        case "activity": return .activity
        case "agents": return .agents
        default:
            if page.hasPrefix("settings/"), let tab = SettingsTab(rawValue: String(page.dropFirst("settings/".count))) {
                return .settings(tab)
            }
            if page.hasPrefix("app/"), let group = AppsGroup(rawValue: String(page.dropFirst("app/".count))) {
                return .app(group)
            }
            return nil
        }
    }

    /// The name of that page as this app writes it, in the Mac's language: the words of "Open <page>".
    static func cardPageWords(_ page: String) -> String? {
        switch cardPage(page) {
        case .needs: String(l10n: "Needs you")
        case .activity: String(l10n: "Tasks")
        case .agents: String(l10n: "Agents")
        case .settings(let tab): String(l10n: "Settings") + " › " + tab.title
        case .app(let group): String(l10n: "Settings") + " › " + SettingsTab.apps.title + " › " + group.title
        default: nil
        }
    }
}

/// **Open <page>** under a step that names one page of the app (the owner's "Open the page", 19 November 2026: "A card
/// whose step is on an app page gets a button that opens it"): an outline button, as every button that is not a page's
/// one main action. A step that names no page, or two, has none.
struct CardPageButton: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    /// The words of the step, which name the page.
    let task: String
    /// The room over it, and whether it stands in the middle, as the step's words do (`NeedStep.centred`): both only
    /// when it is there, so a step with no page keeps its look.
    var top: CGFloat = 0
    var centred = false
    /// The card's own window, when the button stands in one: the page opens in the main window, which stands behind
    /// the other app then, so its press brings the main window to the front too (`NeedWindowLink.showMainWindow`).
    @Environment(\.needWindow) private var cardWindow

    private var page: String? {
        guard need.isOpen, !task.isEmpty else { return nil }
        let pages = store.cardNames(for: need).pages(inMarkdown: task)
        return pages.count == 1 && FleetStore.cardPage(pages[0]) != nil ? pages[0] : nil
    }

    var body: some View {
        if let page, let words = FleetStore.cardPageWords(page), let place = FleetStore.cardPage(page) {
            Button("Open \(words)") {
                store.destination = place
                cardWindow?.showMainWindow()
            }
                .buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("need-open-page-\(need.id)")
                .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
                .padding(.top, top)
        }
    }
}
