import AppKit
import FleetCore
import SwiftUI

/// The owner's own GitHub App, on their own hub (`POST /ui/github-app`, owner feature `github_app`).
///
/// It is the last step that used to need a console: the App's `.pem` file had to be copied onto the hub machine by
/// hand. Now the owner chooses the file GitHub downloaded, and the hub writes it on their own machine, mode 600,
/// and proves it can sign before it replaces a working one.
///
/// The key is in the one request body that carries it. This app does not keep it, does not log it and does not put
/// it in a field that a screenshot would show: it is read from the file the owner chose, sent, and dropped.
struct GitHubAppSection: View {
    let store: FleetStore
    /// What the hub says it has now, from `GET /ui/team`.
    let app: IntegrationsSnapshot.GitHubApp?
    /// Read the team again after a change.
    let refresh: () async -> Void

    @State private var appID = ""
    @State private var keyPath: String?
    @State private var busy = false
    @State private var steps = false
    @State private var note: (text: String, warning: Bool)?

    private var offered: Bool { store.state?.ui_features?.contains(GitHubAppForm.feature) == true }
    private var canChange: Bool { offered && store.isFresh && !busy }
    private var has: Bool { app?.app == true }
    /// Whether to ask for an App at all. With one in place this card is its head row, and while Founderizer has
    /// not read the hub yet it asks for nothing, so no credential form flashes up and is taken away again.
    private var needsOne: Bool { IntegrationsSnapshot.GitHubApp.asksForOne(app) }
    private var holdsFile: Bool { IntegrationsSnapshot.GitHubApp.holdsFile(app) }
    /// The Needs-you item for the App's new key is open (plan 13, item 4): the form takes the new key of the App in
    /// place, with its ID filled in, and offers neither the steps that make a new App nor Remove.
    private var renewing: Bool { app?.renew == true }

    var body: some View {
        // **A card with nothing to ask and nothing to say is not there.** An App in place is the quiet case and
        // gets no row, not even a tick: he asked for that, and the page below is shorter for it. It does stay
        // while there is a line of his own last save or removal to read — which is the whole of the bug this
        // condition replaced, where the card was taken away with that line inside it — and it is gone again the
        // next time he opens the page. Nothing shows while the hub has not been read, because a card that
        // appeared and was taken away again is what that bug looked like from his chair.
        if offered, needsOne || note != nil {
            // The hub's own problem with the file moves out of this footer and behind the mark, where the state
            // is. What stays here is the one thing this footer is for: what came of his own last save.
            FormSection(footer: note?.text) {
                // The row's title said the state — "No GitHub App yet" — and its symbol said it a second time,
                // with the consequence as a third line under both. The title is the thing now, the mark is the
                // answer, and the sentence is behind it. The heading over this card already says GitHub.
                FormRow("Your App", symbol: "app") {
                    HStack(spacing: 8) {
                        // The five steps are for making an App, so they are offered while he needs one — and
                        // stay closable if a save lands while they are open.
                        if (needsOne && !renewing) || steps {
                            // A verb (fix round 2: it was "On GitHub"), for what it does: it unfolds the five steps.
                            Button(steps ? "Hide steps" : "Show steps") { steps.toggle() }
                                .buttonStyle(FleetOutlineButtonStyle())
                        }
                        if has && !renewing {
                            Button("Remove") { Task { await remove() } }.buttonStyle(FleetOutlineButtonStyle())
                                .disabled(!canChange).accessibilityIdentifier("github-app-remove")
                        }
                        // Last, against the row's own edge: that button is "Show steps" and then "Hide
                        // steps", so a mark left of it would move when he opens them — and every other mark
                        // in this app is at this edge, which is what makes them one thing to look for.
                        StateMark(state: appMark.state, words: appMark.words, detail: appDetail,
                                  act: appAct, whoActs: appWhoActs)
                            .accessibilityIdentifier("github-app-state")
                    }
                }
                if steps { stepRows }
                if needsOne {
                    // No line under the App ID or the key (D-2): the field and the button say what goes there.
                    FormRow("App ID", symbol: "number") {
                        TextField(text: $appID, prompt: Text(verbatim: "")) { Text("123456") }
                            .fieldPlaceholder("123456", shows: appID.isEmpty)
                            .fleetField()
                            .frame(width: 150).accessibilityIdentifier("github-app-id")
                            .onAppear { if renewing, appID.isEmpty, let id = app?.app_id { appID = id } }
                    }
                    FormRow("Private key", symbol: "key",
                            detail: keyPath.map { "\(($0 as NSString).lastPathComponent) · delete your download after this" }) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) }
                            Button(keyPath == nil ? "Choose file" : "Change") { choose() }
                                .buttonStyle(FleetOutlineButtonStyle()).disabled(!canChange)
                                .accessibilityIdentifier("github-app-key")
                            // Replace, where the hub has a file it cannot use: a save takes that one's place. Only
                            // once there is a file and an App ID to save: no grey button.
                            if canChange && keyPath != nil && GitHubAppForm.appID(appID) != nil {
                                Button(holdsFile ? "Replace" : "Save") { Task { await save() } }
                                    .buttonStyle(FleetPrimaryButtonStyle())
                                    .accessibilityIdentifier("github-app-save")
                            }
                        }
                    }
                }
            }
        }
    }

    private var appMark: (state: MarkState, words: String) { IntegrationsSnapshot.GitHubApp.mark(app) }

    /// The sentence behind the mark: what his agents get, or what they do not get and why.
    private var appDetail: String {
        guard let app else { return "Founderizer is reading what your hub holds." }
        if app.app {
            return (app.app_id.map { "App \($0). " } ?? "") + "Agents get a one-hour token for their own repositories."
        }
        guard let problem = app.problem else { return "Your agents get no token until your hub has one." }
        return problem.hasSuffix(".") ? problem + " Your agents get no token until your hub can use one."
            : problem + ". Your agents get no token until your hub can use one."
    }

    /// A cross is never a dead end. With no App, the one thing to press is the five steps on GitHub — the same
    /// button this row carries, so it is reachable whichever of the two he finds first. With a file the hub cannot
    /// use, the thing to do is a save, and the two rows that take one are right below.
    private var appAct: (words: String, run: () -> Void)? {
        guard app?.app == false, app?.problem == nil else { return nil }
        return ("Show steps", { steps = true })
    }

    private var appWhoActs: String? {
        app?.app == false && app?.problem != nil
            ? "The App ID and the private key are in the two rows below: a save takes the place of the file that "
                + "is there." : nil
    }

    /// What the owner does on GitHub, folded away until they ask: five steps, and each one is a line.
    @ViewBuilder private var stepRows: some View {
        FormRow("1. New GitHub App", symbol: "1.circle",
                detail: "Settings → Developer settings → GitHub Apps. Name it Founderizer.") {
            Button("Open GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/settings/apps/new")!)
            }.buttonStyle(FleetOutlineButtonStyle())
        }
        FormRow("2. Its permissions", symbol: "2.circle",
                detail: "Webhook off. Contents and Pull requests: read and write. Metadata: read.")
        FormRow("3. Generate a private key", symbol: "3.circle", detail: "GitHub downloads one .pem file.")
        FormRow("4. Install it", symbol: "4.circle", detail: "On your account, on the repositories you choose.")
        FormRow("5. Here", symbol: "5.circle", detail: "The App ID and that file, below.")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose the private key GitHub downloaded"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        if panel.runModal() == .OK { keyPath = panel.url?.path; note = nil }
    }

    /// Reads the chosen file, sends it, and keeps nothing: the key lives for the length of this one call.
    private func save() async {
        guard let keyPath, let database = store.state?.db else { return }
        busy = true
        note = nil
        defer { busy = false }
        guard let key = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
            note = ("This Mac could not read that file.", true)
            return
        }
        if let problem = GitHubAppForm.problem(appID: appID, key: key) {
            note = (problem, true)
            return
        }
        // With a door, the hub holds no GitHub key (DevOps plan C5): the key goes to the central vault for the door, and
        // the door's access file names it for the App's owner, as GitHub says who that is.
        if await DoorKeys.hasDoor(store) {
            do {
                let app = try await GitHubAppKey.app(appID: GitHubAppForm.appID(appID) ?? appID, pem: key)
                let reference = try await DoorKeys.put(GitHubAppKey.vaultValue(key),
                                                       variable: GitHubAppKey.variable(owner: app.owner.login), store: store)
                if let problem = await store.doorModel().addGitHubApp(owner: app.owner.login, login: reference, appID: String(app.id)) {
                    note = (problem, true)
                    return
                }
                self.keyPath = nil
                note = ("The door has your GitHub App. Delete the .pem file you downloaded.", false)
            } catch {
                note = (HubError.said(error) ?? (error as? LocalizedError)?.errorDescription ?? "The door did not get the App. Try again.", true)
            }
            return
        }
        do {
            let receipt = try await IntegrationsClient().saveGitHubApp(hub: store.hub, database: database,
                                                                      client: store.installation, appID: appID,
                                                                      key: key)
            self.keyPath = nil
            note = (receipt.replaced == true ? "Your hub uses this App now. Delete the .pem file you downloaded."
                    : "Your hub has your GitHub App. Delete the .pem file you downloaded.", false)
            await refresh()
        } catch let HubError.refusal(_, words) {
            note = (words, true)
        } catch {
            note = ("The hub did not take the App. Try again.", true)
        }
    }

    private func remove() async {
        guard let database = store.state?.db else { return }
        busy = true
        note = nil
        defer { busy = false }
        do {
            _ = try await IntegrationsClient().removeGitHubApp(hub: store.hub, database: database,
                                                               client: store.installation)
            note = ("The App file is gone. Your agents get no token until you save another.", false)
            await refresh()
        } catch let HubError.refusal(_, words) {
            note = (words, true)
        } catch {
            note = ("The hub did not take that. Try again.", true)
        }
    }
}
