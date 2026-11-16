import FleetCore
import FleetMark
import Observation
import SwiftUI

/// **The pages after Other models, on Add agent** (the AI providers build; the owner's yes of 11 November 2026 to
/// Other models and its four cards, and his answers of 14 November 2026 to pictures 1 to 5 and to round 2,
/// `~/dev/founderizer-plans/ai-providers-step-5-answers.md`). For an agent on a Linux server that takes such an agent:
///
///   - **Other models**: Gemini, Grok, Open models and Your own model server, each with its line on hover.
///   - **Open models**: OpenCode Go, OpenRouter and Ollama Cloud.
///   - **The key page** ("Your Gemini key"): the provider's steps, then the vault's own form, its Key field and Save.
///   - **The model page** of a seller ("Your OpenRouter model"): its two steps and the Model field. He pastes a name as
///     the seller writes it; the app checks it against the seller's own list, read with no key, and adds the seller's
///     part itself.
///   - **Your model server**: the Address field, which the app checks by the hub's rule, then "Your model server's
///     key" for every address but a loopback one whose agent is alone on its server.
///
/// The last page's press goes on to Add agent's server step, whose press adds the agent (the owner, 16 November 2026:
/// the name and the AI before the server), or adds it on a form that came with its server
/// (`AddAgentModel.start(store:provider:...)`): the account, the agent with it, and its read grant. What the hub refuses
/// of the account then is that page's one orange line. Back goes one page back.
@MainActor @Observable
final class OtherModels {
    enum Page: Equatable {
        case choices, sellers, address
        case key(ModelProvider)
        case model(ModelProvider)
    }

    private(set) var pages: [Page] = []
    var page: Page? { pages.last }
    /// The account's id of this add, kept for a second press after a refusal.
    var account: String?
    /// The key that the key page saved in the vault, its provider and its variable name: a second press after a
    /// refusal goes on with it, and saves no second key.
    var secret: String?
    var secretOf: ModelProvider?
    var variable: String?
    /// What he typed on the address page, and the address in the hub's form once it passed the hub's rule.
    var address = ""
    var checkedAddress: String?
    /// What he pasted on a seller's model page.
    var modelName = ""
    /// The one orange line of the page he is on.
    var line: String?
    /// The seller's list is being read.
    var checking = false

    func open(_ page: Page) { pages.append(page); line = nil }
    func back() { if !pages.isEmpty { pages.removeLast() }; line = nil }
    func leave() {
        pages = []; account = nil; secret = nil; secretOf = nil; variable = nil; address = ""; checkedAddress = nil
        modelName = ""; line = nil; checking = false
    }
}

struct OtherModelsPages: View {
    @Bindable var store: FleetStore
    @Bindable var model: AddAgentModel
    /// The press on the last page: Add agent's server step with this provider, or the agent on the server that the form
    /// came with.
    let add: (ModelProvider) -> Void
    /// "Adding <Name>" stands while the add runs and until the agent's own setup takes the window.
    let adding: Bool
    private var other: OtherModels { model.other }

    var body: some View {
        SetupPage {
            if !adding {
                SetupBack { other.back() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("other-models-back")
            }
        } step: {
            if adding {
                // As Add agent says it for an agent on a plan (`AddAgentView.step`).
                SetupStep(title: String(l10n: "Adding \(model.name)"), waits: true) {
                    AgentGlyph(name: model.key, size: SetupMetrics.mark)
                        .environment(\.glyphTeam, (store.state?.agents.map(\.name) ?? []) + [model.key])
                }
            } else {
                switch other.page {
                case .choices?: choices
                case .sellers?: sellers
                case .key(let provider)?: keyPage(provider)
                case .address?: addressPage
                case .model(let provider)?: modelPage(provider)
                case nil: EmptyView()
                }
            }
        }
    }

    // MARK: Other models and Open models

    /// **Other models** (his yes of 11 November 2026) with the hover lines of picture 2 ("Yes, these lines").
    private var choices: some View {
        SetupStep(title: String(l10n: "Other models")) {
            IconTile(symbol: "ellipsis", size: SetupMetrics.mark)
        } content: {
            VStack(spacing: 10) {
                card(logo: .gemini, title: "Gemini", help: String(l10n: "With an API key.")) { open(.key(.gemini)) }
                    .accessibilityIdentifier("other-models-gemini")
                card(logo: .grok, title: "Grok", help: String(l10n: "With an API key.")) { open(.key(.grok)) }
                    .accessibilityIdentifier("other-models-grok")
                card(symbol: "cube", title: String(l10n: "Open models"), help: String(l10n: "With a key from a seller.")) { other.open(.sellers) }
                    .accessibilityIdentifier("other-models-open")
                card(symbol: "server.rack", title: String(l10n: "Your own model server"),
                     help: String(l10n: "A model that runs on your own machine.")) { other.open(.address) }
                    .accessibilityIdentifier("other-models-own")
            }
        }
    }

    /// **Open models** (picture 5): the three sellers, with no hover lines (none was shown or approved).
    private var sellers: some View {
        SetupStep(title: String(l10n: "Open models")) {
            IconTile(symbol: "cube", size: SetupMetrics.mark)
        } content: {
            VStack(spacing: 10) {
                ForEach(ModelProvider.sellers) { seller in
                    card(logo: seller, title: seller.label, help: nil) { open(.key(seller)) }
                        .accessibilityIdentifier("other-models-\(seller.rawValue)")
                }
            }
        }
    }

    /// The key page of a provider, with its variable name chosen once as it opens (`ModelProvider.variable`).
    private func open(_ page: OtherModels.Page) {
        if case .key(let provider) = page, other.secretOf != provider {
            let taken = Set((model.team?.logins ?? [:]).values.compactMap(\.env))
            other.variable = provider.variable(agent: model.key, taken: taken)
            other.secret = nil; other.secretOf = nil
        }
        other.open(page)
    }

    // MARK: the key page

    /// **The key page** (picture 3, his "Yes, as shown"): the provider's mark, "Your Gemini key", its numbered steps
    /// with its own page as the first one's link, then the vault's own form on the step: its Key field and Save.
    /// **Your model server's key** (picture 4): the server's mark and the form, with no steps.
    private func keyPage(_ provider: ModelProvider) -> some View {
        SetupStep(title: provider.keyTitle) {
            hero(provider)
        } content: {
            if !provider.keySteps.isEmpty { SetupSteps(provider.keySteps) }
            SecretEntryView(store: store, preset: .keyStep(variable: other.variable ?? provider.variable(agent: model.key, taken: []),
                                                         site: provider.keySite),
                            note: other.line, again: other.secretOf == provider && other.secret != nil ? { next(provider) } : nil) { saved in
                guard let saved else { return }
                other.secret = saved; other.secretOf = provider
                next(provider)
            }
            .id("key-\(provider.rawValue)-\(other.variable ?? "")")
        }
    }

    /// After the key: a seller's model page, or the add.
    private func next(_ provider: ModelProvider) {
        if provider.sellsManyMakers, other.page != .model(provider) { other.open(.model(provider)) } else { add(provider) }
    }

    // MARK: the address page

    /// **Your model server** (picture 4): the server's mark and one field, Address; Return goes on. What the hub's rule
    /// refuses is one orange line under the field, with the field's orange edge (round 2, item 13).
    private var addressPage: some View {
        SetupStep(title: String(l10n: "Your model server")) {
            serverHero
        } content: {
            SetupField(placeholder: String(l10n: "Address"), text: Bindable(other).address, wrong: other.line != nil) { submitAddress() }
                .accessibilityIdentifier("other-models-address")
                .onChange(of: other.address) { other.line = nil }
            if let line = other.line { SetupWarning(line).accessibilityIdentifier("other-models-line") }
        }
    }

    private func submitAddress() {
        switch ModelServerAddress.check(other.address) {
        case .failure(let refusal): other.line = refusal.words
        case .success(let address):
            other.checkedAddress = address
            // A loopback server that only this agent reaches, alone on its server, may have no key (spec 3.8). With no
            // server yet, the server step then offers only servers with no agent (`AddAgentModel.alone`).
            if ModelServerAddress.host(address).map(ModelServerAddress.isLoopback) == true,
               model.given ? model.selected?.agents.isEmpty == true : true {
                other.secret = nil; other.secretOf = nil
                add(.own)
            } else {
                open(.key(.own))
            }
        }
    }

    // MARK: the model page

    /// **A seller's model page** (picture 5, his "Yes, paste the name"): the seller's mark, "Your OpenRouter model",
    /// its two steps, and the Model field; Return goes on. A name that the seller's own list does not have is one
    /// orange line under the field (round 2, sentence 9 and item 18).
    private func modelPage(_ provider: ModelProvider) -> some View {
        SetupStep(title: provider.modelTitle) {
            hero(provider)
        } content: {
            SetupSteps(provider.modelSteps)
            SetupField(placeholder: String(l10n: "Model"), text: Bindable(other).modelName, wrong: other.line != nil) {
                Task { await submitModel(provider) }
            }
            .accessibilityIdentifier("other-models-model")
            .onChange(of: other.modelName) { other.line = nil }
            if let line = other.line { SetupWarning(line).accessibilityIdentifier("other-models-line") }
        }
    }

    private func submitModel(_ provider: ModelProvider) async {
        guard !other.checking, !other.modelName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let name = SellerModels.sellerName(other.modelName, provider: provider)
        guard provider.accountModel(other.modelName) != nil else {
            other.line = ModelAccountWords.noSuchModel(name, provider: provider); return
        }
        other.checking = true
        // Under the hood, with no key: a list that does not answer lets the name go on, and the server's check says
        // it on the setup page when the seller has no such model.
        let names = await SellerModels.read(provider)
        other.checking = false
        if let names, !names.contains(name) {
            other.line = ModelAccountWords.noSuchModel(name, provider: provider); return
        }
        add(provider)
    }

    // MARK: marks and cards

    /// The provider's mark over its pages: its logo, or the server symbol for the owner's model server.
    @ViewBuilder private func hero(_ provider: ModelProvider) -> some View {
        if provider == .own { serverHero } else { ProviderIcon(provider: provider, size: SetupMetrics.mark) }
    }

    /// The server symbol in the text's colour, with no tile (picture 4).
    private var serverHero: some View {
        Image(systemName: "server.rack").font(IconMetrics.symbol(34 * 0.82)).foregroundStyle(FleetStyle.text)
            .frame(width: SetupMetrics.mark, height: SetupMetrics.mark).accessibilityHidden(true)
    }

    /// One card of one line in Add agent's look: its mark in a 28-point column, its name, and its line on hover.
    private func card(logo: ModelProvider, title: String, help: String?, action: @escaping () -> Void) -> some View {
        cardButton(title: title, help: help, action: action) { ProviderIcon(provider: logo, size: 28).accessibilityHidden(true) }
    }

    private func card(symbol: String, title: String, help: String?, action: @escaping () -> Void) -> some View {
        cardButton(title: title, help: help, action: action) {
            Image(systemName: symbol).font(IconMetrics.symbol(18)).foregroundStyle(FleetStyle.text).frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    private func cardButton<Mark: View>(title: String, help: String?, action: @escaping () -> Void,
                                        @ViewBuilder mark: () -> Mark) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                mark()
                Text(title).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text)
                Spacer(minLength: 8)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .help(help ?? "")
        .accessibilityHint(help ?? "")
    }
}
