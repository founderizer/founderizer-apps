import FleetCore
import FleetMark
import SwiftUI

/// Chats: one row for each agent, with its state, the last line of the conversation, the time, and a mark when a
/// reply is unread (MOBILE-APP.md 10). The line comes from the compact read, which gives the newest 120 characters of
/// each conversation; the conversation itself is read when the owner opens it.
///
/// It is the platform's own list of conversations: a plain list, a round monogram with the agent's state on it, the
/// time at the right, and two lines of the last message.
///
/// **Settings is the round button at its top left, and a search field heads the list** (the owner's yes of 28 October
/// 2026 to the map of D-4, which took the Fleet tab away). The field keeps the rows whose name or last line hold what
/// he types.
struct ChatsPage: View {
    let store: MobileStore
    @Environment(\.dynamicTypeSize) private var typeSize
    /// What the owner typed in the search field.
    @State private var search = ""
    /// The search field has the cursor: a tap anywhere on its capsule gives it.
    @FocusState private var searching: Bool
    /// The corner's round control, and the room under it before the list's first row.
    private static let corner: CGFloat = 44
    private static let underCorner: CGFloat = 12
    /// **10 points under the line over the page while it shows**, as Needs you's first head stands under it (margins
    /// pass, fault 7): the corner's control touched the line.
    private var underLine: CGFloat { store.unavailableWords == nil && !store.sample ? 0 : 10 }

    /// The agents whose name or last line hold the words of the search, in the hub's order; every agent while the
    /// field is empty.
    private var shown: [MobileAgent] {
        let words = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return store.agents }
        return store.agents.filter { agent in
            AgentNames.shared.matches(agent.name, words)        // its role or its name
                || (agent.last.map { MessageBlock.plain($0.preview).localizedStandardContains(words) } ?? false)
        }
    }

    var body: some View {
        List {
            // No search over a phone with no hub: there is nothing to find.
            if !store.hasNoHub {
                searchField
                    .listRowSeparator(.hidden)
                    .brandRows(cards: false)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
            }
            // Nothing of this hub was ever read and its read is on its way: after a second, the one loading line.
            if store.readsTheHub {
                LoadingLine("Reading the hub…")
                    .listRowSeparator(.hidden)
                    .brandRows(cards: false)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            ForEach(shown) { agent in
                Button { store.chatRoute.append(.chat(agent.name)) } label: { row(agent) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(spoken(agent))
                    .listRowSeparator(.hidden)
                    .brandRows(cards: false)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
        // **A row is as high as what it holds** (margins pass, fault 22): the list's 52-point least height put 3
        // points over the search field's 46, so it stood 15 points under the corner's control, not 12.
        .environment(\.defaultMinListRowHeight, 0)
        // The search field starts under the corner's control, as the first row of Fleet did under its own.
        .contentMargins(.top, Self.corner + Self.underCorner + underLine, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .brandPage()
        .overlay {
            // **One title and no second line** (the owner's yes of 28 October 2026 to D-2). A hub that does not
            // answer says so once, in the line over the page, and the launch mark stays until the list comes.
            if store.agents.isEmpty && store.snapshot != nil && store.showsCurrent {
                ContentUnavailableView("No agents yet", systemImage: "message")
            } else if store.snapshot == nil {
                // **The launch mark stays until the list comes** (the owner's yes of 28 October 2026 to D-8): the
                // violet plate with its white chevrons, 96 points, in the middle of the screen, where the launch
                // screen drew it, so nothing moves from the launch to the first frame. **A phone with no hub says under
                // it how to add one, and offers the sample fleet** (the owner's yes of 11 November 2026 to its picture).
                if store.hasNoHub && typeSize.isAccessibilitySize {
                    // At the largest sizes the words do not fit under a mark that stays still: they scroll with it.
                    ScrollView {
                        VStack(spacing: 24) {
                            FounderizerMark(size: 96, plate: Brand.violet).accessibilityHidden(true)
                            NoHubWords(store: store)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 48)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 24) {
                        FounderizerMark(size: 96, plate: Brand.violet)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        if store.hasNoHub { NoHubWords(store: store).frame(width: 300) }
                    }
                    // The mark's middle is the stack's middle, so the words hang under a mark that does not move.
                    .alignmentGuide(VerticalAlignment.center) { $0[.top] + 48 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                }
            }
        }
        .refreshable { await store.refresh() }
        .tabRootPage()
        // Settings: the page's one control, a round button over the page at its top left.
        .overlay(alignment: .topLeading) {
            NavigationLink(value: ChatsRoute.settings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .cornerControl()
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("open-settings")
            .padding(.leading, 16)
            .padding(.top, underLine)
        }
        // The connection line pushes the corner's control and the list down: the way to Settings stays in reach while
        // the hub does not answer, which is when Settings is wanted.
        .hubBanner(store)
    }

    /// The search field: a magnifier and the words, in the quiet fill of a composer's field.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Brand.muted)
                .accessibilityHidden(true)
            TextField(text: $search, prompt: Text("Search").foregroundStyle(Brand.placeholder)) {
                Text("Search")
            }
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($searching)
            .accessibilityIdentifier("chats-search")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        // **The whole capsule takes the tap** (fix round 2, item 53): only its 22-point line of words did.
        .background { Capsule().fill(Brand.bubble).onTapGesture { searching = true } }
    }

    private func row(_ agent: MobileAgent) -> some View {
        let unread = store.hasNewReply(from: agent.name)
        let state = store.snapshot.map { agent.mobileState(in: $0, isFresh: store.showsCurrent) } ?? .unknown
        // **At the accessibility text sizes the mark stands beside the name** (margins pass, fault 13): centred on the
        // row, it stood beside the preview's lines, about 100 points under the name.
        return HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            // **0.69 of the 58-point row** (fix round 2, item 56), as the references draw a list's marks (Grok Bot 28
            // in 44, 0.64): 42 stood in the row at 0.72, and 46 at 0.74 before it.
            AgentAvatar(name: agent.name, state: state, base: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                // At the accessibility text sizes a name and a time no longer share a line, so they stack.
                // **The time ends on the row's right edge, and the unread mark stands before it** (margins pass,
                // faults 3 and 12): a clear mark after the time kept its place in every row, so the times stood 14
                // points in from the edge that the search field and the cards keep, and at the accessibility sizes it
                // took a line of its own.
                heading {
                    Text(agentName(agent.name)).font(.headline)
                    if typeSize.isAccessibilitySize {
                        if agent.last != nil || unread {
                            HStack(spacing: 6) {
                                if let last = agent.last { time(last) }
                                if unread { unreadMark }
                            }
                        }
                    } else {
                        Spacer(minLength: 6)
                        if unread { unreadMark }
                        if let last = agent.last { time(last) }
                    }
                }
                // One line, as a list of conversations gives: the row is the name and the mark, and the words
                // under them are only enough to know which conversation this is.
                Text(lastLine(agent.last))
                    .font(.subheadline).foregroundStyle(Brand.muted)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        // **The whole row takes the tap** (fix round 2, item 53): a plain button takes it on its words only, so the
        // right of a row with a short line ("Noted, thanks.") opened nothing.
        .contentShape(Rectangle())
    }

    /// The row as VoiceOver reads it, each fact once: "Manager, Online, 15:29, Passed on to Nova…". It read the name
    /// twice, once for the mark and once for the words.
    private func spoken(_ agent: MobileAgent) -> String {
        let state = store.snapshot.map { agent.mobileState(in: $0, isFresh: store.showsCurrent) } ?? .unknown
        var parts = [agentName(agent.name), state.words]
        if let last = agent.last { parts.append(fleetTime(last.ts)) }
        if store.hasNewReply(from: agent.name) { parts.append("Unread reply") }
        parts.append(lastLine(agent.last))
        return parts.joined(separator: ", ")
    }

    private func time(_ last: MobilePreview) -> some View {
        Text(fleetTime(last.ts)).font(.subheadline).foregroundStyle(Brand.muted)
    }

    /// A reply he has not read: the one violet dot.
    private var unreadMark: some View {
        Circle().fill(Brand.accent)
            .frame(width: 8, height: 8)
            .accessibilityLabel("Unread reply")
    }

    private var heading: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
    }

    /// The last line of the conversation: who wrote it and its first words. Its words lose their Markdown marks here,
    /// as its bubble draws them, the owner's as an agent's (the Mac's list does the same).
    private func lastLine(_ last: MobilePreview?) -> String {
        // No full stop: an empty line in the Mac's form (fix round 2, item 35).
        guard let last else { return "No messages yet" }
        let text = last.isFromAgent ? MessageBlock.plain(last.preview) : "You: " + MessageBlock.plain(last.preview)
        return text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// **What a phone with no hub says under the launch mark** (the owner's yes of 11 November 2026 to its picture): where
/// on the Mac its code is made, and the sample fleet to look at first. The way in on the Mac is the code's picture,
/// which the phone's camera opens (`MobileStore.openLink`).
private struct NoHubWords: View {
    let store: MobileStore

    var body: some View {
        VStack(spacing: 8) {
            Text("Add this phone")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("In Founderizer on your Mac: Settings, Servers, Add device.")
                .font(.body)
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextAction(title: "See a sample fleet", font: .body) { store.startSample() }
                .padding(.top, 10)
                .accessibilityIdentifier("see-sample")
        }
        // Every line in the middle, also where the largest text sizes wrap the title and the action.
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("no-hub")
    }
}
