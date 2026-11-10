import SwiftUI

/// Fleet Mobile: the owner's phone app for the agents. It reaches the hub only over Tailscale, reads the owner routes
/// that the Mac app reads, and shows the fleet while the app is in front. The plan is `MOBILE-APP.md` in the Fleet
/// repository.
@main
struct FleetMobileApp: App {
    /// Pings and the answer buttons on them (`PushNotifications.swift`). iOS needs the delegate before any window, so
    /// that a press on a button also works when it starts the app in the background.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push
    @State private var store = MobileStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            // No colour scheme of its own: the phone decides, as it does for the system's own apps.
            MobileRoot(store: store)
                // `.inactive` is not leaving the app: the Face ID sheet, Control Centre and the app switcher
                // all raise it. Only `.background` drops this phone's key and stops the reads.
                .task { push.store = store; store.setForeground(phase != .background) }
                .onChange(of: phase) { _, now in store.setForeground(now != .background) }
                // The Mac's picture of a code, opened by the phone's camera: the phone joins with nothing typed.
                .onOpenURL { url in Task { await store.openLink(url) } }
        }
    }
}

/// The bottom bar: Chats, Needs you, Tasks. It is the platform's own pattern and it reaches with one hand; the Mac
/// app's rule against horizontal tabs comes from a desktop reference (MOBILE-APP.md 10, decision D6). The Needs-you
/// count is the badge: the open requests and the tasks only he can move, the Mac's Needs you count (D-4).
///
/// **There is no Fleet tab** (the owner's yes of 28 October 2026 to the map of D-4): the agents were listed twice, on
/// Chats and on Fleet. Settings is the round button at the top left of Chats, because it is rare, and the work that
/// stopped is the first group of Tasks.
///
/// **The marks are outlines, and they are drawn, not blocks.** A tab bar fills its symbols by itself, and solid white
/// shapes in a dark capsule are the other platform's bar, not this one — `square.grid.2x2` in particular is that
/// platform's own apps mark. `symbolVariants(.none)` takes the fill off, and the violet behind the chosen tab is what
/// says which one it is, so the fill has no work left to do.
struct MobileRoot: View {
    @Bindable var store: MobileStore

    var body: some View {
        TabView(selection: $store.tab) {
            Tab(value: MobileTab.chats) {
                NavigationStack(path: $store.chatRoute) {
                    ChatsPage(store: store)
                        .navigationDestination(for: ChatsRoute.self) { route in
                            switch route {
                            case .chat(let agent): ChatPage(store: store, agent: agent)
                            case .agent(let agent): AgentPage(store: store, agent: agent)
                            case .settings: SettingsPage(store: store)
                            case .enroll: EnrollPage(store: store)
                            }
                        }
                }
            } label: {
                TabMark("Chats", symbol: "message")
            }

            Tab(value: MobileTab.needs) {
                NavigationStack {
                    NeedsPage(store: store)
                }
            } label: {
                TabMark("Needs you", symbol: "exclamationmark.bubble")
            }
            .badge(store.needsYouCount)

            Tab(value: MobileTab.tasks) {
                NavigationStack(path: $store.taskRoute) {
                    TasksPage(store: store)
                        .navigationDestination(for: Int.self) { TaskPage(store: store, id: $0) }
                }
            } label: {
                TabMark("Tasks", symbol: "checklist")
            }
        }
        .onChange(of: store.openChat) { _, _ in store.markRepliesSeen() }
        // The hub's order of the agents decides each mark, so that no two agents of one team share a shape or a hue.
        .environment(\.markTeam, store.agents.map(\.name))
    }
}

/// One mark of the bottom bar: the symbol as it is drawn, and not as the bar would fill it.
///
/// A tab bar puts `.fill` on every symbol it is given, and a filled symbol at this size is a solid block with no
/// drawing left in it — a row of those in a dark capsule is the other platform's bar, not this one. The variant is
/// set on the image itself, which is nearer to it than the bar's own setting, so the outline wins. The violet
/// behind the chosen tab is what says which one it is.
struct TabMark: View {
    private let title: String
    private let symbol: String

    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }

    var body: some View {
        Label { Text(title) } icon: {
            Image(systemName: symbol).environment(\.symbolVariants, .none)
        }
    }
}

/// The pages of the Chats stack: an agent's chat and its own page over it, and Settings with Add this phone under it.
enum ChatsRoute: Hashable {
    case chat(String)
    case agent(String)
    case settings, enroll
}
