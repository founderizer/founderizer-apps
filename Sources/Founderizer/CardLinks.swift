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
    func cardNames(for need: OwnerNeed) -> CardNames {
        let integrations: IntegrationsSnapshot? = reading("apps.integrations.fleet")
        let servers: ServerList? = reading("servers.list")
        let agents = (state?.agents ?? []).map { (name: $0.name, role: $0.title) }
        let repos = (integrations?.repositories ?? []) + (state?.needs ?? []).flatMap { $0.give?.repos ?? [] }
        let names = servers?.servers.map(\.name) ?? []
        var hasher = Hasher()
        for agent in agents { hasher.combine(agent.name); hasher.combine(agent.role) }
        hasher.combine(repos)
        hasher.combine(names)
        let key = hasher.finalize()
        if let kept = cardBook, kept.key == key { return kept.book }
        let book = CardNames(agents: agents, repositories: repos, servers: names)
        cardBook = (key, book)
        return book
    }

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
        case .repository: return .systemAction
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

    private var page: String? {
        guard need.isOpen, !task.isEmpty else { return nil }
        let pages = store.cardNames(for: need).pages(inMarkdown: task)
        return pages.count == 1 && FleetStore.cardPage(pages[0]) != nil ? pages[0] : nil
    }

    var body: some View {
        if let page, let words = FleetStore.cardPageWords(page), let place = FleetStore.cardPage(page) {
            Button("Open \(words)") { store.destination = place }
                .buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("need-open-page-\(need.id)")
                .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
                .padding(.top, top)
        }
    }
}
