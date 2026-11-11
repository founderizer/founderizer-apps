import FleetCore
import FleetMark
import SwiftUI

/// The share sheet's two pages: the agents, then the chosen agent's composer with what was shared in it.
struct ShareRoot: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack(path: $model.path) {
            ShareAgentsPage(model: model)
                .navigationDestination(for: String.self) { ShareComposePage(model: model, agent: $0) }
        }
        // The hub's order of the agents decides each mark, as in the app, so an agent wears the same mark here.
        .environment(\.markTeam, model.team)
    }
}

/// **The agents, as Chats lists them**: each one's mark and role, in the hub's order, and only the agents that take a
/// message. A tap opens its composer. The marks rest and carry no state: the reading is the app's last one, and the
/// list is for choosing, not for news.
struct ShareAgentsPage: View {
    let model: ShareModel

    var body: some View {
        List {
            ForEach(model.agents, id: \.self) { agent in
                Button { model.choose(agent) } label: { row(agent) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(agentName(agent))
                    .accessibilityIdentifier("share-to-\(agent)")
                    .listRowSeparator(.hidden)
                    .brandRows(cards: false)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .brandPage()
        .overlay {
            if model.agents.isEmpty {
                if let problem = model.listProblem, !model.readingHub {
                    ContentUnavailableView(problem, systemImage: "message")
                } else {
                    // As Chats: the mark stands until the list comes.
                    FounderizerMark(size: 96, plate: Brand.violet)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { CloseButton(model: model) }
        }
        .toolbarBackground(Brand.canvas, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .task { await model.readAgentsIfNeeded() }
    }

    private func row(_ agent: String) -> some View {
        HStack(spacing: 12) {
            AgentAvatar(name: agent, state: .online, base: 40, moves: false)
            Text(agentName(agent)).font(.headline)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        // The whole row takes the tap, as a row of Chats does.
        .contentShape(Rectangle())
    }
}

/// The sheet's way out: the system's own close button, or Cancel on a phone older than the glass.
private struct CloseButton: View {
    let model: ShareModel

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close) { model.cancel() }
                .disabled(model.sending)
                .accessibilityIdentifier("share-close")
        } else {
            Button("Cancel") { model.cancel() }
                .disabled(model.sending)
                .accessibilityIdentifier("share-close")
        }
    }
}

/// **The chosen agent's composer, as its chat draws it**: the agent's mark and role in the glass pill over the page,
/// and the one capsule of glass at the bottom, with the shared pictures and files in its row and the shared link or
/// text in its field, the cursor on the line under it for the owner's own words. Send is the agent's colour. The page
/// over the composer stays empty: the message is what the composer shows.
struct ShareComposePage: View {
    @Bindable var model: ShareModel
    let agent: String
    @Environment(\.markTeam) private var team
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var line: CGFloat = 22
    @FocusState private var focused: Bool

    var body: some View {
        Brand.canvas
            .ignoresSafeArea()
            .composerBar { composer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .principal) { pill }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) { pill }
                }
            }
            .toolbarBackground(Brand.canvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            // Back while a message is on its way would leave it with no word of how it ended.
            .navigationBarBackButtonHidden(model.sending)
            .onAppear {
                model.open(agent)
                focused = true
            }
    }

    /// The agent's mark and role in one glass pill, as over its chat; it opens nothing here.
    private var pill: some View {
        HStack(spacing: 8) {
            AgentMark(name: agent, size: 20, moves: false)
            Text(agentName(agent)).font(.headline).foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .titlePill()
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShareFileRow(model: model).padding(.horizontal, 14).padding(.top, 6)
            HStack(alignment: .bottom, spacing: 0) {
                let placeholder = typeSize.isAccessibilitySize ? "Message" : "Message \(agentName(agent))"
                TextField(text: $model.text, prompt: Text(placeholder).foregroundStyle(Brand.placeholder),
                          axis: .vertical) {
                    Text(placeholder)
                }
                // Ten lines, then it scrolls, as the chat's composer.
                .lineLimit(1...10)
                .textFieldStyle(.plain)
                .focused($focused)
                .disabled(model.sending || model.pending != nil)
                .padding(.vertical, 14)
                .padding(.leading, 15)
                .padding(.trailing, 6)
                .accessibilityIdentifier("share-text")
                let look = MarkTeam.look(of: agent, in: team)
                SendButton(enabled: model.canSend, label: "Send message", side: 36, fill: look.mid,
                           arrow: SendButton.arrow(on: look.mid)) {
                    await model.send(to: agent)
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(height: line + 28)
                .accessibilityIdentifier("share-send")
            }
            .padding(.leading, 3).padding(.trailing, 7)
            if let note {
                ComposerNote(words: note.words, isWarning: note.isWarning)
                    .padding(.leading, 18).padding(.trailing, 18).padding(.bottom, 12)
            }
        }
        // The whole capsule takes the tap, as the chat's does.
        .background {
            RoundedRectangle(cornerRadius: 25, style: .continuous).fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .onTapGesture { focused = true }
        }
        .composerGlass()
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    /// The one line under the field: "Sending…" while the message goes, then what went wrong, in the app's words.
    private var note: (words: String, isWarning: Bool)? {
        if model.sending { return ("Sending…", false) }
        if let note = model.note { return note }
        let count = model.trimmed.count
        if count > ShareModel.textLimit {
            return ("Use no more than \(ShareModel.textLimit.formatted()) characters.", true)
        }
        if count > ShareModel.textLimit - 500 {
            return ("\(count.formatted()) of \(ShareModel.textLimit.formatted()) characters", false)
        }
        return nil
    }
}

/// The shared pictures and files in the composer's row, as the chat stages its own: a 54-point square each, the
/// picture itself or the symbol of its kind, its name under it, and the x that takes it out.
private struct ShareFileRow: View {
    let model: ShareModel
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 54

    var body: some View {
        if !model.files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.files) { chip($0) }
                }
                .padding(.top, 8)
            }
            .scrollClipDisabled()
        }
    }

    private func chip(_ file: ShareFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.bubble)
                    if let picture = file.thumbnail {
                        Image(decorative: picture, scale: 1)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: file.isPicture ? "photo" : "doc")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                }
                .frame(width: side, height: side)
                if model.pending == nil && !model.sending {
                    // A 44-point touch around the 17-point mark, which keeps its place in the picture's corner.
                    Button { model.remove(file) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-13.5)
                    .padding(3)
                    .accessibilityLabel("Take \(file.name) out")
                }
            }
            Text(file.name)
                .font(.caption2).foregroundStyle(Brand.muted)
                .lineLimit(1).truncationMode(.middle).frame(width: side, alignment: .leading)
        }
        .accessibilityIdentifier("shared-\(file.name)")
    }
}
