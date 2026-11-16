import Foundation
import Testing
@testable import FleetCore

// **An agent on a key or on the owner's own model server** (the AI providers build, step 5, lane 5A): the words of
// its pages, the hub's rule of a model server's address, the hub's codes as the app's own words, and the setup with no
// sign-in. Example names only: the agent Iris, the servers app-1 and mac-1.

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private func agent(_ extra: [String: Any] = [:]) throws -> FleetAgent {
    var fields: [String: Any] = ["name": "iris", "role": "worker", "runtime": "opencode", "can": [], "active": false]
    fields.merge(extra) { _, new in new }
    return try JSONDecoder().decode(FleetAgent.self, from: json(fields))
}

private func job(_ state: String, steps: [String]? = ["user", "checkout", "runtime", "service"], step: String? = "runtime",
                 detail: String? = nil, code: String? = nil, names: [String: String]? = nil, label: String? = "Gemini",
                 signIn: String? = nil) throws -> ServerJob {
    var fields: [String: Any] = ["id": 7, "kind": "install", "agent": "iris", "runtime": "opencode", "state": state,
                                 "step": step.map { $0 as Any } ?? NSNull(), "detail": detail.map { $0 as Any } ?? NSNull(),
                                 "prompt": NSNull(), "created": 1, "updated": 2]
    if let steps { fields["steps"] = steps }
    if let label { fields["provider_label"] = label }
    if let code { fields["code"] = code }
    if let names { fields["names"] = names }
    if let signIn { fields["sign_in"] = signIn }
    return try JSONDecoder().decode(ServerJob.self, from: json(fields))
}

struct ModelAccountsTests {
    // MARK: the providers and their pages

    /// His answer 12: each AI by the name he picked, never by the program that runs it.
    @Test func eachProviderIsNamedAsHePickedIt() {
        #expect(ModelProvider.allCases.map(\.label) == ["Gemini", "Grok", "OpenCode Go", "OpenRouter", "Ollama Cloud", "Model server"])
        #expect(!ModelProvider.allCases.map(\.label).contains { $0 == "OpenCode" || $0.contains("Opencode") })
        #expect(ModelProvider.allCases.map(\.runtime) == ["opencode", "grok", "opencode", "opencode", "opencode", "opencode"])
        #expect(ModelProvider.sellers == [.openCodeGo, .openRouter, .ollamaCloud])
        #expect(ModelProvider.own.kind == "server" && ModelProvider.gemini.kind == "key")
        #expect(ModelProvider.own.title == "Model server")
    }

    /// Picture 3: "Your <provider> key" and two numbered steps, the first with the provider's own page as its link.
    @Test func eachKeyPageHasItsTitleAndTwoStepsWithTheProvidersOwnPage() {
        #expect(ModelProvider.gemini.keyTitle == "Your Gemini key")
        #expect(ModelProvider.ollamaCloud.keyTitle == "Your Ollama key")
        #expect(ModelProvider.own.keyTitle == "Your model server's key")
        for provider in ModelProvider.allCases where provider != .own {
            let steps = provider.keySteps
            #expect(steps.count == 2)
            #expect(provider.keyPage?.scheme == "https")
            #expect(steps.first?.contains("](\(provider.keyPage?.absoluteString ?? "-"))") == true)
        }
        // The model server's key page has no steps: he set that key on his own server.
        #expect(ModelProvider.own.keySteps.isEmpty)
        #expect(ModelProvider.gemini.keySteps == ["Open [Google AI Studio](https://aistudio.google.com/api-keys)",
                                                  "Create API key, then copy it"])
    }

    /// Picture 5: a seller's model page, and the seller's own list that answers with no key.
    @Test func aSellersModelPageHasTwoStepsAndAListThatNeedsNoKey() {
        #expect(ModelProvider.openRouter.modelTitle == "Your OpenRouter model")
        #expect(ModelProvider.openRouter.modelSteps == ["Open [Models](https://openrouter.ai/models) in OpenRouter",
                                                        "Copy the name of a model"])
        for seller in ModelProvider.sellers {
            #expect(seller.sellsManyMakers && seller.modelsList?.scheme == "https" && seller.modelSteps.count == 2)
        }
        #expect(ModelProvider.gemini.modelsList == nil && !ModelProvider.gemini.sellsManyMakers)
    }

    /// Round 2, item 19: the app adds the seller's part to the name that he pastes, once.
    @Test func theAppAddsTheSellersPartToThePastedName() {
        #expect(ModelProvider.openRouter.accountModel("qwen/qwen3.8-max") == "openrouter/qwen/qwen3.8-max")
        #expect(ModelProvider.openRouter.accountModel(" openrouter/qwen/qwen3.8-max ") == "openrouter/qwen/qwen3.8-max")
        #expect(ModelProvider.ollamaCloud.accountModel("glm-5.2") == "ollama-cloud/glm-5.2")
        #expect(ModelProvider.grok.accountModel("grok-4.7") == "grok-4.7")
        #expect(ModelProvider.openRouter.accountModel("") == nil)
        #expect(ModelProvider.openRouter.accountModel("a name with spaces") == nil)
        #expect(SellerModels.sellerName("openrouter/qwen/qwen3.8-max", provider: .openRouter) == "qwen/qwen3.8-max")
        #expect(ModelAccount.shownModel("openrouter/qwen/qwen3.8-max", provider: .openRouter) == "qwen/qwen3.8-max")
        #expect(ModelAccount.shownModel("own/qwen3-coder-30b", provider: .own) == "qwen3-coder-30b")
    }

    /// The new account and its key get names that the team does not have, and the key's variable never starts with
    /// a reserved part (FLEET_, CODEX_, XAI_...), which no session would get.
    @Test func theAccountAndTheKeyGetFreeNames() {
        #expect(ModelProvider.gemini.accountID(agent: "iris", taken: []) == "iris-gemini")
        #expect(ModelProvider.gemini.accountID(agent: "iris", taken: ["iris-gemini"]) == "iris-gemini-2")
        #expect(ModelProvider.own.accountID(agent: "a_very_long_agent_name_of_many_words", taken: [])
            .range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil)
        #expect(ModelProvider.gemini.variable(agent: "iris", taken: []) == "GEMINI_IRIS_API_KEY")
        #expect(ModelProvider.gemini.variable(agent: "iris", taken: ["GEMINI_IRIS_API_KEY"]) == "GEMINI_IRIS_2_API_KEY")
        #expect(ModelProvider.grok.variable(agent: "codex", taken: []) == "GROK_CODEX_API_KEY")
        for provider in ModelProvider.allCases {
            let name = provider.variable(agent: "fleet-lead", taken: [])
            #expect(name.range(of: "^[A-Z][A-Z0-9_]{0,59}$", options: .regularExpression) != nil)
            #expect(name.hasSuffix("_KEY"))
            #expect(!["FLEET_", "CODEX_", "CLAUDE_", "ANTHROPIC_", "XAI_", "BWS_"].contains { name.hasPrefix($0) })
        }
    }

    // MARK: the address of a model server, by the hub's rule

    /// `hub.account_address`: the same forms, the same refusals and the same codes (round 2, sentences 1 and 2).
    @Test func theAddressFollowsTheHubsRule() {
        func checked(_ typed: String) -> String? { if case .success(let address) = ModelServerAddress.check(typed) { address } else { nil } }
        func code(_ typed: String) -> String? { if case .failure(let refusal) = ModelServerAddress.check(typed) { refusal.code } else { nil } }
        #expect(checked("http://100.64.0.7:8000/v1") == "http://100.64.0.7:8000/v1")
        #expect(checked("http://100.64.0.7:8000") == "http://100.64.0.7:8000/v1")
        #expect(checked("HTTP://Box.Example.ts.net:11434/") == "http://box.example.ts.net:11434/v1")
        #expect(checked("http://127.0.0.1:8080/v1/") == "http://127.0.0.1:8080/v1")
        #expect(checked("http://localhost:1234") == "http://localhost:1234/v1")
        #expect(checked("http://[::1]:8000") == "http://[::1]:8000/v1")
        #expect(checked("https://models.example.com/api") == "https://models.example.com/api")
        // Plain http over the local network is the owner's sentence 1; each other wrong form his sentence 2.
        #expect(code("http://192.168.1.50:11434") == "plain_http")
        #expect(code("http://models.example.com") == "plain_http")
        #expect(code("models.example.com:8000") == "address")
        #expect(code("ftp://models.example.com") == "address")
        #expect(code("https://user@models.example.com") == "address")
        #expect(code("https://models.example.com/v1?key=1") == "address")
        #expect(code("https://models.example.com/v1#part") == "address")
        #expect(code("https://models.example.com/" + String(repeating: "a", count: 200)) == "address")
        #expect(code("") == "address")
        #expect(ModelServerAddress.isLoopback("127.0.0.1") && ModelServerAddress.isLoopback("localhost") && ModelServerAddress.isLoopback("::1"))
        #expect(!ModelServerAddress.isLoopback("100.64.0.7"))
    }

    // MARK: a seller's list

    @Test func aSellersListIsReadInItsOwnShape() throws {
        let openRouter = try json(["data": [["id": "qwen/qwen3.8-max"], ["id": "google/gemini-4-carbon"]]])
        #expect(SellerModels.names(openRouter, provider: .openRouter) == ["qwen/qwen3.8-max", "google/gemini-4-carbon"])
        let ollama = try json(["models": [["name": "glm-5.2", "model": "glm-5.2"]]])
        #expect(SellerModels.names(ollama, provider: .ollamaCloud) == ["glm-5.2"])
        #expect(SellerModels.names(Data("not json".utf8), provider: .openCodeGo) == nil)
        #expect(ModelAccountWords.noSuchModel("qwen/qwen3.9", provider: .openRouter) == "OpenRouter has no model named qwen/qwen3.9.")
    }

    // MARK: the hub's codes as the app's own words (D7)

    /// **The hub's English of each code that the app maps** (`hub.ACCOUNT_WORDS` on main, round 2 sentences 1 to 8),
    /// with each name as the hub writes it. The hub keeps them apart from `refusal_words.py`, so they are not in
    /// `app/vectors/refusal-codes.json` yet: this table holds `RefusalWords` to them until they move there.
    private static let accountEnglish: [(code: String, names: [String: RefusalName], english: String)] = [
        ("plain_http", [:], "Plain http works only over Tailscale or on the agent's own server. Use that machine's Tailscale address, or https."),
        ("address", [:], "Write the address as http:// or https://, then the host, and a port and a path if it has them."),
        ("pooled", [:], "The fleet manager may give this key. Set it to You alone in Settings › Secrets, then save again."),
        ("placement", [:], "Founderizer no longer has this key or address. Start again from Add agent."),
        ("open", ["server": "app-1"], "app-1 has an agent on a model server with no key, so it takes no other agent. Choose another server."),
        ("change", ["agent": "Writer", "provider": "Gemini"], "Writer stays on Gemini. For another AI, add a new agent."),
        ("change_server", ["agent": "Writer"], "Writer stays on its model server. For another AI, add a new agent."),
        ("mac", ["server": "mac-1", "provider": "Gemini"], "mac-1 is a Mac. An agent on Gemini needs a Linux server: choose another one."),
        ("older", ["server": "app-1"], "app-1 runs an older Founderizer that cannot do this yet. It updates itself when it has no job; then try again."),
    ]

    /// Each of the nine codes has its case in `RefusalWords`, with the hub's English and its holes: with a name missing
    /// the case says nothing, and the hub's own line stands.
    /// The People page names the provider that he picked, never the program (his answer 12; review M8).
    @Test func thePeoplePageNamesTheProviderHePicked() {
        #expect(People.cannotChat(role: "worker", runtime: "opencode", active: true, provider: .gemini)
            == "A session of Gemini cannot be locked down to a conversation yet, so other people never reach it.")
        #expect(People.cannotChat(role: "worker", runtime: "codex", active: true)
            == "A session of Codex cannot be locked down to a conversation yet, so other people never reach it.")
    }

    @Test func eachAccountCodeHasItsCaseWithTheHubsEnglish() {
        for entry in Self.accountEnglish {
            #expect(RefusalWords.sentence(entry.code, entry.names, say: RefusalWords.english) == entry.english, "\(entry.code)")
            for missing in entry.names.keys {
                var short = entry.names
                short[missing] = nil
                #expect(RefusalWords.sentence(entry.code, short, say: RefusalWords.english) == nil, "\(entry.code) without \(missing)")
            }
        }
        // The codes that have no place in the app keep the hub's English (D37 (c), round 2 items 10 to 12).
        for code in ["no_sign_in", "kind_kept", "in_use", "model_prefix", "path_names", "kind"] {
            #expect(RefusalWords.sentence(code, [:], say: RefusalWords.english) == nil, "\(code)")
        }
    }

    /// In Spanish each of the nine codes has the catalog's words, with its names as the hub wrote them.
    @Test func inSpanishEachAccountCodeHasItsWords() throws {
        let catalog = try SpanishTable.words()
        try SpanishTable.run(catalog) {
            for entry in Self.accountEnglish {
                let refusal = HubRefusal(status: 409, hubWords: entry.english, code: entry.code, names: entry.names)
                #expect(refusal.words != entry.english, "\(entry.code) was not translated")
                for name in entry.names.values { #expect(refusal.words.contains(name.written), "\(entry.code) lost \(name.written)") }
            }
            #expect(HubRefusal(status: 409, hubWords: "x", code: "older", names: ["server": "app-1"]).words
                    == "app-1 tiene una versión anterior de Founderizer que aún no puede hacerlo. Se actualiza sola cuando no tiene ningún trabajo; después, vuelve a intentarlo.")
        }
    }

    /// The add decides by the code, never by the words (review M1): sentence 3 sends him back to the name step, and a
    /// team.json that changed meanwhile is read again once. A refusal from an older hub with no code is read as before.
    @Test func theAddDecidesByTheCode() throws {
        let open = HubRefusal.read(status: 400, body: try json(["error": "app-1 has an agent …", "code": "open",
                                                               "names": ["server": "app-1"]]))
        #expect(open.isOpenServer && open.code == "open" && open.names["server"] == "app-1")
        #expect(!HubRefusal.read(status: 409, body: try json(["error": "x", "code": "older", "names": ["server": "app-1"]])).isOpenServer)
        // Its words are the hub's English on an English device, whatever the case says.
        #expect(open.words == "app-1 has an agent …")
        let changed = HubRefusal.read(status: 409, body: try json(["error": "team.json changed meanwhile; reload it",
                                                                  "code": "team_changed"]))
        #expect(changed.means(.teamChanged))
        #expect(HubRefusal.read(status: 409, body: try json(["error": "team.json changed"])).means(.teamChanged))
        // The address page says its line with no hub at all, in the same words (round 2, item 13).
        #expect(ModelAccountRefusal(code: "plain_http").words == Self.accountEnglish[0].english)
    }

    // MARK: the account fields and the agent's state

    @Test func anAccountWithAKindReadsAndWritesItsFourFields() throws {
        let entry = try JSONDecoder().decode(TeamAccount.self, from: json(
            ["provider": "own", "title": "Model server", "kind": "server", "address": "http://100.64.0.7:8000/v1"]))
        #expect(entry.kind == "server" && entry.address == "http://100.64.0.7:8000/v1" && entry.secret == nil)
        #expect(ModelProvider(account: entry) == .own)
        // A label of today writes as before: provider and title alone.
        let label = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TeamAccount(provider: "openai", title: "Codex Pro"))) as? [String: Any]
        #expect(Set(label.map { Array($0.keys) } ?? []) == ["provider", "title"])
        #expect(ModelProvider(account: TeamAccount(provider: "openai", title: "Codex Pro")) == nil)
    }

    /// Picture 6 and picture 7: the Account and Usage words, and the account's trouble in his words.
    @Test func theAgentsAccountAndItsTroubleAreInHisWords() throws {
        let iris = try agent(["model_account": ["kind": "key", "provider": "google", "label": "Gemini", "address": NSNull()],
                              "account_problem": ["code": "key_no_credit", "error": "The key has no credit.", "names": [:],
                                                  "at": 10, "task": 3]])
        #expect(iris.modelProvider == .gemini)
        #expect(iris.model_account?.accountWords == "Key" && iris.model_account?.usageWords == "Paid per use")
        #expect(iris.account_problem?.words == "The key has no credit.")
        let local = try agent(["model_account": ["kind": "server", "provider": "own", "label": "Model server",
                                                 "address": "http://100.64.0.7:8000/v1"],
                               "account_problem": ["code": "server_no_answer", "error": "x"]])
        #expect(local.model_account?.accountWords == "http://100.64.0.7:8000/v1" && local.model_account?.usageWords == "Local model")
        #expect(local.account_problem?.words == "Its model server does not answer.")
        // A shape that will not read is none, and never hides the agent.
        let odd = try agent(["model_account": "gemini", "account_problem": 4])
        #expect(odd.modelProvider == nil && odd.account_problem == nil && odd.name == "iris")
    }

    // MARK: the install and the setup with no sign-in

    /// Picture 10: User, Checkout, AI provider, Service, and no Sign-in; "3 of 4" in the install's title.
    @Test func theInstallHasFourRowsInItsOwnOrder() throws {
        let running = try job("running")
        #expect(Servers.steps(running).map(\.id) == ["user", "checkout", "runtime", "service"])
        let count = try #require(AgentSetupFlow.installCount(running, onMac: false))
        #expect(count.step == 3 && count.of == 4)
        #expect(AgentSetupFlow.installing("Gemini", on: "app-1", job: running, onMac: false) == "Installing Gemini on app-1 · 3 of 4")
        // `sign_in: "none"` with no `steps` (5H's message of 16 November 2026): the same four rows.
        #expect(Servers.steps(try job("running", steps: nil, signIn: "none")).map(\.id) == ["user", "checkout", "runtime", "service"])
        // A rename of such an agent: item 10's rows too, with no Sign-in row (review M8).
        let rename = try JSONDecoder().decode(ServerJob.self, from: json(
            ["id": 8, "kind": "rename", "agent": "iris", "runtime": "opencode", "state": "running", "step": "checkout",
             "detail": NSNull(), "prompt": NSNull(), "created": 1, "updated": 2, "sign_in": "none", "provider_label": "Gemini"]))
        #expect(Servers.steps(rename).map(\.id) == ["user", "checkout", "runtime", "service"])
        // A later hub that sends another type in a new field costs that field, never the job (review M12).
        let odd = try JSONDecoder().decode(ServerJob.self, from: json(
            ["id": 9, "kind": "install", "agent": "iris", "runtime": "opencode", "state": "running", "step": "user",
             "detail": NSNull(), "prompt": NSNull(), "created": 1, "updated": 2, "steps": "user", "code": 4,
             "names": ["provider": 3], "sign_in": ["none"], "provider_label": 7]))
        #expect(odd.steps == nil && odd.code == nil && odd.names == nil && odd.sign_in == nil && odd.provider_label == nil)
        #expect(odd.id == 9 && odd.state == "running")
        // A Claude or Codex install keeps its five rows.
        let plan = try job("running", steps: nil, label: nil)
        #expect(Servers.steps(plan).map(\.id) == ["user", "runtime", "checkout", "service", "sign_in"])
    }

    /// Owner API 1.186: the four install lines that name the AI, by their code, with the provider that he picked.
    @Test func theInstallsLinesNameTheProviderHePicked() throws {
        let failed = try job("failed", detail: "Opencode did not install. Try again.", code: "install_failed",
                             names: ["provider": "Gemini"])
        #expect(failed.shownDetail == "Gemini did not install. Try again.")
        #expect(AgentSetupFlow.stopped(runtime: "opencode", job: failed, machine: nil, provider: .gemini) == "Gemini did not install.")
        let offline = try job("failed", detail: "x", code: "install_offline", names: ["provider": "Model server", "server": "app-1"])
        #expect(offline.shownDetail == "Model server did not install: app-1 could not reach the internet. Try again when it can.")
        #expect(AgentSetupFlow.stopped(runtime: "opencode", job: offline, machine: nil, provider: .own)
            == "Model server did not install: app-1 could not reach the internet.")
        #expect(try job("running", detail: "x", code: "install_looking", names: ["provider": "OpenRouter"]).shownDetail == "Looking for OpenRouter.")
        // A code that the app does not know keeps the hub's detail.
        #expect(try job("running", detail: "The hub's words.", code: "later_code", names: [:]).shownDetail == "The hub's words.")
    }

    /// Picture 8: an agent on a key has no sign-in page: its install, then its activation.
    @Test func anAgentOnAKeyHasNoSignInPage() throws {
        let features = AgentSetupFlow.features
        let iris = try agent(["model_account": ["kind": "key", "provider": "google", "label": "Gemini"]])
        #expect(AgentSetupFlow.shows(iris, features: features))
        #expect(!AgentSetupFlow.shows(try agent(["active": true, "model_account": ["kind": "key", "provider": "google"]]), features: features))
        #expect(AgentSetupFlow.accountPage(job: try job("running"), runtime: "opencode") == .installing(runtime: "opencode"))
        #expect(AgentSetupFlow.accountPage(job: try job("done"), runtime: "opencode") == .activate)
        #expect(AgentSetupFlow.accountPage(job: try job("failed"), runtime: "opencode") == .activate)
        // An agent on a plan whose program has no sign-in keeps no setup page, as before.
        #expect(!AgentSetupFlow.shows(try agent(["runtime": "grok"]), features: features))
        // Its add ends when its setup ends: it has no chat to wait for.
        #expect(AgentSetupFlow.addingEnds(try agent(["active": true, "chat_ready": false,
                                                     "model_account": ["kind": "key", "provider": "google"]]), features: features))
    }

    /// Picture 4: the check's account item is its sentence alone, with no prefix, in the app's words for its code.
    @Test func theChecksAccountItemIsItsSentenceAlone() throws {
        func verify(_ item: [String: Any]) throws -> MachineVerification {
            try JSONDecoder().decode(MachineVerification.self, from: json(
                ["check": 3, "revision": "abc", "checked_at": 100, "items": [item]]))
        }
        let open = try verify(["kind": "account", "ref": "iris-model-server", "state": "failed", "required": true,
                               "detail": "This server answers with no key, and more than one agent can reach it.", "code": "open_server"])
        #expect(AgentSetupFlow.blocker(open) == "This server answers with no key, and more than one agent can reach it.")
        let model = try verify(["kind": "account", "ref": "iris-openrouter", "state": "failed", "required": true, "detail": "x",
                                "code": "not_offered", "names": ["provider": "OpenRouter", "model": "qwen3.9", "agent": "Writer"]])
        #expect(AgentSetupFlow.blocker(model) == "OpenRouter has no model named qwen3.9. Delete Writer, then add it again with another model.")
        // A code with no approved words here: the hub's detail, still with no prefix.
        let other = try verify(["kind": "account", "ref": "iris-model-server", "state": "failed", "required": true,
                                "detail": "The hub's own words.", "code": "path_names"])
        #expect(AgentSetupFlow.blocker(other) == "The hub's own words.")
        // Another item keeps its title before the detail, as before.
        let runtime = try verify(["kind": "runtime", "ref": "signed_in", "state": "failed", "required": true, "detail": "Not signed in."])
        #expect(AgentSetupFlow.blocker(runtime) == "Signed In: Not signed in.")
    }

    @Test func aServerTakesSuchAnAgentOnlyWhenTheHubSaysSoAndNeverAMac() throws {
        func server(_ kind: String, _ providers: [String]?) throws -> ServerEntry {
            var fields: [String: Any] = ["name": "app-1", "kind": kind, "address": "100.64.0.10", "user": "fleet", "hub": false,
                                         "joined": true, "agents": [], "reading": NSNull(), "available": true, "why": [],
                                         "job": NSNull(), "load": NSNull()]
            if let providers { fields["model_providers"] = providers }
            return try JSONDecoder().decode(ServerEntry.self, from: json(fields))
        }
        #expect(try server("linux", ["google", "xai", "own"]).takesModelAccounts)
        #expect(try !server("linux", []).takesModelAccounts)
        #expect(try !server("linux", nil).takesModelAccounts)
        #expect(try !server("mac", ["google"]).takesModelAccounts)
    }
}
