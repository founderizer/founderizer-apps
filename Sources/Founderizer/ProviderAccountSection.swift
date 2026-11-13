import FleetCore
import SwiftUI

/// **One agent's account and its usage, as two rows of the agent's Overview.** It answers one question — which
/// account does this agent run on, how much of it is left, and how do I change it — and it is the only place in the
/// app that answers it, so no page shows a second shape of one fact.
///
/// The owner went looking for a way to point his manager at a different Claude account while that one sat at 92% of
/// its week and another of his sat at 0%, found nothing where he looked, opened Change provider instead, and said
/// (20 October 2026): "clicking on Change is super confusing!! I clicked there because there was no way to switch
/// the claude account to a different one. it should be much much simpler!! … we can't have hidden sections inside
/// hidden sections with multiple information rows".
///
/// So it is two rows, in the form of the Overview's other two (25 October 2026: "Show Server, AI Provider, Account
/// and Usage, that's it!!"), and nothing else:
///
///   1. **Account**: the address its provider reported, and the one button he was looking for — **Use another
///      account**, which is the per-machine sign-in (`machine_signin`) under the name of the thing he wants, or Sign
///      in while it is signed out. The provider itself is the AI provider row above it, so it is not said again here.
///   2. **Usage**: each of the account's windows, the day and the week, as a bar and its share, because that is the
///      fact a choice of account is made on. An account two agents share says so under the account.
///
/// A sign-in that goes on is its own screen, which the account row opens again; one that failed says why on that row.
/// An agent whose desktop tasks run on a second account (Codex on a Mac) has one more account row. The account label, the recorded tokens
/// and the age of a reading are behind the rows.
struct ProviderAccountSection: View {
    @Bindable var store: FleetStore
    let agent: String
    /// The agent's machine, from the page's own reading. The page polls faster while a sign-in is open.
    let machine: MachineStatus?
    /// Draw the card around the rows. False where the page's own card holds them, as the Overview's does.
    var card = true

    private var time: Double { store.state?.time ?? 0 }
    private var features: [String] { store.state?.ui_features ?? [] }
    private var line: FleetAgent? { store.state?.agents.first { $0.name == agent } }

    var body: some View {
        if let line {
            if card { FormSection { rows(line) } } else { rows(line) }
        }
    }

    @ViewBuilder private func rows(_ line: FleetAgent) -> some View {
        accountRow(line)
        desktopRow(line)
        usageRow(line)
    }

    // MARK: the account

    /// The account the agent runs on, and the one step that changes it. **Switch account is the per-machine
    /// sign-in** (`POST /ui/machines/<agent>/signin`), which is one mechanism and was only ever on the Machines page
    /// under the word "Sign in" — a name for the first one, not for the thing he wanted.
    @ViewBuilder private func accountRow(_ agentState: FleetAgent) -> some View {
        let facts = self.facts(agentState)
        let replacing = machine?.needsSignIn != true
        FormRow("Account", symbol: "person.crop.circle", detail: facts.accountDetail, warning: signInFailure) {
            HStack(spacing: FleetSpace.actions) {
                Text(signInShown ? String(l10n: "Signing in…") : facts.accountWords).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    .truncationMode(.middle).textSelection(.enabled)
                // **The sign-in is a screen of its own** (`SignInWizard`), so this row has one button and no steps:
                // what it costs, the provider's page and the code it gives are that wizard's own pages. One that is
                // going on is that wizard's too, and Continue opens it where it is; one that failed says why here.
                // **Never grey**: it opens the sign-in's own screen, which reads the machine and waits for the hub
                // itself, so nothing about this reading's age or a request on its way stops the press (it stood
                // disabled while the reading was read again, and flipped under the pointer).
                if canSignIn(agentState) {
                    Button(signInShown ? "Continue" : replacing ? "Switch account" : "Sign in") { store.destination = .signIn(agent) }
                        .buttonStyle(FleetOutlineButtonStyle())
                        .help(String(l10n: "Opens the sign-in: \(providerName(agentState.runtime))'s own page, in your own browser, with whichever account you want this agent to use."))
                        .accessibilityIdentifier("use-another-account")
                }
            }
        }.help(facts.help { fleetDate($0) }).accessibilityIdentifier("provider-account")
    }

    /// The facts behind the account row, in one place (`ProviderAccountFacts` in FleetCore), so the chat panel, the
    /// Agents table and this row never name one account two ways.
    private func facts(_ agentState: FleetAgent) -> ProviderAccountFacts {
        let limits = agentState.accountLimits
        let bar = UsageBar.bars(for: store.state?.agents ?? [], time: time, isFresh: store.isFresh)[agent]
        return ProviderAccountFacts(
            runtime: agentState.runtime,
            email: AccountEmail(limits: limits, at: time, fresh: store.isFresh, features: features),
            plan: limits?.plan, localModel: agentState.local_model == true,
            weekMissing: limits?.weekMissing == true,
            signedIn: machine?.stale == true ? nil : machine?.runtime.signed_in,
            stale: !store.isFresh || limits?.isStale(at: time) == true, collectedAt: limits?.collected_at,
            sharedWith: bar?.sharedWith ?? [], tokens: agentState.usage?.combinedTokens?.total,
            error: agentState.usageError ?? limits?.error)
    }

    /// Fleet drives this provider's own sign-in, and this hub offers it. Grok has none, here or anywhere.
    private func canSignIn(_ agentState: FleetAgent) -> Bool {
        agentState.local_model != true && features.contains(MachineLogin.feature) &&
            MachineLogin.canSignIn(machine?.signInRuntime ?? agentState.runtime)
    }

    /// A sign-in is going on.
    private var signInShown: Bool { machine?.login?.isOpen == true }
    /// **A press that led nowhere says why, where he pressed.** The last sign-in failed and the runtime is still
    /// signed out: its words belong on the account's row, not only on the machine's own page.
    private var signInFailure: String? {
        guard let line = machine?.signInLine(working: false), line.warn else { return nil }
        return machine?.login?.reason ?? line.says
    }

    // MARK: the usage

    /// The height of one line of the row's words: a window's bar stands in the middle of it.
    private static let line = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13)).rounded(.up)

    /// **The account's own windows, each as a bar and its share**, in one row. The provider reports what it reports —
    /// a session and a week for Claude, five hours and a week for Codex — and both are the fact a choice of account
    /// is made on, so both stand. "Back at 13:30" for the end of a hold said nothing ("what does back at 13:30 mean??
    /// does not make sense, we dont need that! just say Usage Limit and the progress bar", 21 October 2026); when each
    /// window resets is under its bar, as a mark and a time (`ResetLine`; the owner, 10 November 2026: "could we show
    /// somewhere too WHEN it resets?", and his yes to "↻ 15:00" under every bar). The row's title stands on the bars'
    /// line, the resets hang under it, and the date in full is behind each bar with the exact share.
    ///
    /// **A number nobody can refresh is not shown at all.** A meter is read as where the account stands now, and
    /// "Not read since 8:42" under it did not undo that: his signed-out manager sat at a full week it could no
    /// longer spend. The row says the reading is not current, and the bars come back with the reading.
    @ViewBuilder private func usageRow(_ agentState: FleetAgent) -> some View {
        let limits = agentState.accountLimits
        let current = store.isFresh && limits.map { !$0.isStale(at: time) } == true
        let windows = agentState.local_model == true || !current ? [] : limits?.ownWindows(at: time) ?? []
        let hold = UsageBar.bars(for: store.state?.agents ?? [], time: time, isFresh: store.isFresh)[agent]?.limit
        FormRow("Usage", symbol: "gauge.with.dots.needle.50percent",
                detail: limits?.weekMissing == true && !windows.isEmpty ? String(l10n: "Week not reported") : nil,
                warning: hold.map { String(l10n: "Usage limit until \(fleetComingTime($0.until, now: time))") }) {
            if windows.isEmpty {
                Text(agentState.local_model == true ? "Local model" : limits == nil ? "Not reported" : "No current reading")
                    .foregroundStyle(FleetStyle.muted)
            } else {
                // Each window's first line stands at the top, and the reset hangs under its bar.
                HStack(alignment: .top, spacing: 18) {
                    ForEach(windows) { window in
                        // **The window's name never gives up its width** (fix round 2: "5 h" and "7 d" were cut to
                        // nothing at every width, leaving two bars nobody could tell apart): the bars give way first.
                        HStack(alignment: .top, spacing: 8) {
                            // In the text's colour, as the chat panel and Servers draw it (fix round 3, item 22).
                            Text(window.shortTitle).foregroundStyle(FleetStyle.text).lineLimit(1)
                                .fixedSize().frame(height: Self.line).layoutPriority(1)
                            VStack(alignment: .leading, spacing: 2) {
                                AllowanceMeter(used: window.used_percent, stale: false, width: nil)
                                    .frame(minWidth: 32, idealWidth: 90, maxWidth: 90).frame(height: Self.line)
                                ResetLine(window: window, now: time)
                            }
                            Text("\(Int(window.used_percent.rounded()))%").monospacedDigit()
                                .foregroundStyle(FleetStyle.text)
                                .frame(width: 38, height: Self.line, alignment: .trailing).layoutPriority(1)
                        }
                        .help(window.resets_at.map { String(l10n: "\(window.label): \(window.used_percent.formatted(.number.precision(.fractionLength(0...1))))% used · resets \(fleetDate(ResetLine.minute($0)))") }
                              ?? String(l10n: "\(window.label): \(window.used_percent.formatted(.number.precision(.fractionLength(0...1))))% used · reset not reported"))
                        .accessibilityIdentifier("allowance-\(window.id)")
                    }
                }
                // The row's title and mark stand on the bars' line, not in the middle of the bars and their resets.
                .alignmentGuide(VerticalAlignment.center) { _ in Self.line / 2 }
            }
        }.accessibilityIdentifier("agent-usage")
    }

    /// An agent whose desktop tasks run on a second account of their own (Codex on a Mac) says so in one row. It has
    /// no control: Fleet drives no sign-in for a desktop route.
    @ViewBuilder private func desktopRow(_ agentState: FleetAgent) -> some View {
        if let screen = agentState.usage?.screen?.limits,
           let email = AccountEmail(limits: screen, at: time, fresh: store.isFresh, features: features), email != .unknown {
            let facts = ProviderAccountFacts(runtime: screen.source.lowercased().contains("codex") ? "codex" : agentState.runtime,
                                             email: email, plan: screen.plan,
                                             stale: !store.isFresh || screen.isStale(at: time),
                                             collectedAt: screen.collected_at, error: screen.error)
            FormRow("Desktop tasks", mark: ProviderIcon(runtime: facts.runtime, size: 18), detail: facts.detailWithoutAge) {
                Text(facts.title).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }.help(facts.help { fleetDate($0) })
        }
    }
}
