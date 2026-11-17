import Foundation

// **An agent on a key or on the owner's own model server** (the AI providers build, ai-providers-spec.md version 4;
// the owner's answers to its pictures in ai-providers-step-5-answers.md). Such an agent runs on an entry of team.json
// `accounts` with a `kind`: "key" (an API key in the vault) or "server" (a model server by its address). The program
// that runs it is the account's, OpenCode or Grok Build, and **the app never names that program where it names the
// agent's AI** (his answer 12: "The name I picked"): it says Gemini, Grok, OpenCode Go, OpenRouter, Ollama Cloud, or
// Model server, with that provider's logo. Only for an agent on a Linux server (version 1).

/// **The AIs that Other models offers**, by the hub's own provider names (`lifecycle.KEY_PROVIDERS`, and `own` for the
/// owner's model server).
public enum ModelProvider: String, CaseIterable, Sendable, Identifiable {
    case gemini = "google", grok = "xai", openCodeGo = "opencode-go", openRouter = "openrouter", ollamaCloud = "ollama-cloud"
    case own

    public var id: String { rawValue }

    /// The sellers of open models, in the order of their page (picture 5).
    public static let sellers: [ModelProvider] = [.openCodeGo, .openRouter, .ollamaCloud]

    /// **The name he picked, where the app names such an agent's AI** (his answer 12): the hub's label of the provider
    /// (`KEY_PROVIDERS[...]["label"]`, `OWN_SERVER["label"]`). The providers' names are names: they have no Spanish.
    public var label: String {
        switch self {
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .openCodeGo: "OpenCode Go"
        case .openRouter: "OpenRouter"
        case .ollamaCloud: "Ollama Cloud"
        case .own: String(l10n: "Model server")
        }
    }

    /// The hub's feature word for the new pages (`UI_FEATURES`).
    public static let feature = "model_accounts"

    /// The account's title in team.json: the hub's own label, in English as team.json keeps it.
    public var title: String { self == .own ? "Model server" : label }

    /// The account's kind: a key, or the owner's model server.
    public var kind: String { self == .own ? "server" : "key" }

    /// The program that runs an agent of this provider (`lifecycle.ACCOUNT_PROGRAMS`): Grok Build for Grok, OpenCode
    /// for each other one. It is never shown where the agent's AI is named.
    public var runtime: String { self == .grok ? "grok" : "opencode" }

    /// A seller of several makers' models: the account names its model, which he pastes on the model page.
    public var sellsManyMakers: Bool { Self.sellers.contains(self) }

    /// The name of the provider inside the program, which the app puts before a model's name (round 2, item 19: "the
    /// app adds the seller's part itself"). nil for Grok, whose model has no part before it.
    public var prefix: String? {
        switch self {
        case .grok: nil
        default: rawValue
        }
    }

    /// The key's site, for the vault's form (`KEY_PROVIDERS[...]["site"]`): the vault keeps the key for that address.
    public var keySite: String {
        switch self {
        case .gemini: "https://generativelanguage.googleapis.com"
        case .grok: "https://api.x.ai"
        case .openCodeGo: "https://opencode.ai"
        case .openRouter: "https://openrouter.ai"
        case .ollamaCloud: "https://ollama.com"
        case .own: ""
        }
    }

    /// The first part of the key's variable name (`variable(agent:taken:)`).
    var variableStem: String {
        switch self {
        case .gemini: "GEMINI"
        case .grok: "GROK"
        case .openCodeGo: "OPENCODE_GO"
        case .openRouter: "OPENROUTER"
        case .ollamaCloud: "OLLAMA"
        case .own: "MODEL_SERVER"
        }
    }

    /// The last part of the account's id (`accountID(agent:taken:)`).
    var accountStem: String {
        switch self {
        case .gemini: "gemini"
        case .grok: "grok"
        case .openCodeGo: "opencode-go"
        case .openRouter: "openrouter"
        case .ollamaCloud: "ollama"
        case .own: "model-server"
        }
    }

    /// The logo of `ProviderLogo` (FleetMark), or nil for the model server, whose mark is the server symbol.
    public var logo: String? {
        switch self {
        case .gemini: "gemini"
        case .grok: "grok"
        case .openCodeGo: "opencode"
        case .openRouter: "openrouter"
        case .ollamaCloud: "ollama"
        case .own: nil
        }
    }

    /// The provider of a hub's account entry, or nil for a label of today (no kind) and for a provider that this
    /// app does not know.
    public init?(account: TeamAccount?) {
        guard let account, account.kind != nil, let provider = ModelProvider(rawValue: account.provider) else { return nil }
        self = provider
    }

    // MARK: the words of its pages

    /// **The title of its key page** (picture 3, his "Yes, as shown"): "Your Gemini key". Ollama Cloud's is "Your
    /// Ollama key", as in the picture's table.
    public var keyTitle: String {
        switch self {
        case .gemini: String(l10n: "Your Gemini key")
        case .grok: String(l10n: "Your Grok key")
        case .openCodeGo: String(l10n: "Your OpenCode Go key")
        case .openRouter: String(l10n: "Your OpenRouter key")
        case .ollamaCloud: String(l10n: "Your Ollama key")
        case .own: String(l10n: "Your model server's key")
        }
    }

    /// **The steps of its key page, over the vault's Key field** (picture 3's table), the first with the provider's
    /// own page as its link. Each link and each name is the provider's own, as read on its site on 16 November 2026
    /// (his condition on picture 3; the lane note lists each change from the picture). The model server's key page has
    /// no steps: he set that key on his own server.
    public var keySteps: [String] {
        let page = keyPage?.absoluteString ?? ""
        switch self {
        case .gemini: return [String(l10n: "Open [Google AI Studio](\(page))"), String(l10n: "Create API key, then copy it")]
        case .grok: return [String(l10n: "Open [API Keys](\(page)) in SpaceXSI Console"), String(l10n: "Create API key, then copy it")]
        case .openCodeGo: return [String(l10n: "Open [Personal API keys](\(page)) in OpenCode"), String(l10n: "Add API key, then copy it")]
        case .openRouter: return [String(l10n: "Open [API keys](\(page)) in OpenRouter"), String(l10n: "Create API Key, then copy it")]
        case .ollamaCloud: return [String(l10n: "Open [API keys](\(page)) in Ollama"), String(l10n: "Create a key, then copy it")]
        case .own: return []
        }
    }

    /// The provider's own page where a key is made.
    public var keyPage: URL? {
        switch self {
        case .gemini: URL(string: "https://aistudio.google.com/api-keys")
        case .grok: URL(string: "https://console.x.ai/team/default/api-keys")
        case .openCodeGo: URL(string: "https://opencode.ai/auth")
        case .openRouter: URL(string: "https://openrouter.ai/keys")
        case .ollamaCloud: URL(string: "https://ollama.com/settings/keys")
        case .own: nil
        }
    }

    /// **The title of a seller's model page** (picture 5): "Your OpenRouter model", with the seller's name as its key
    /// page has it.
    public var modelTitle: String {
        switch self {
        case .openCodeGo: String(l10n: "Your OpenCode Go model")
        case .openRouter: String(l10n: "Your OpenRouter model")
        case .ollamaCloud: String(l10n: "Your Ollama model")
        default: ""
        }
    }

    /// The two steps of a seller's model page (picture 5): the seller's list of models, then the copy of a name.
    public var modelSteps: [String] {
        guard let page = modelsPage?.absoluteString else { return [] }
        let first: String
        switch self {
        case .openCodeGo: first = String(l10n: "Open [Models](\(page)) in OpenCode")
        case .openRouter: first = String(l10n: "Open [Models](\(page)) in OpenRouter")
        case .ollamaCloud: first = String(l10n: "Open [Models](\(page)) in Ollama")
        default: return []
        }
        return [first, String(l10n: "Copy the name of a model")]
    }

    /// The seller's own page of its models, with the names that its model page takes.
    public var modelsPage: URL? {
        switch self {
        case .openCodeGo: URL(string: "https://opencode.ai/docs/console/go/#endpoints")
        case .openRouter: URL(string: "https://openrouter.ai/models")
        case .ollamaCloud: URL(string: "https://ollama.com/search?c=cloud")
        default: nil
        }
    }

    /// **The seller's own list of its models, which answers with no key** (round 2, item 18: "the Mac never sends the
    /// key for this read"). Each answered 200 with no key on 16 November 2026.
    public var modelsList: URL? {
        switch self {
        case .openCodeGo: URL(string: "https://opencode.ai/inference/go/v1/models")
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/models")
        case .ollamaCloud: URL(string: "https://ollama.com/api/tags")
        default: nil
        }
    }

    // MARK: what the add writes

    /// **The model as the account names it**: the seller's part, then the name he pasted as the seller writes it
    /// (round 2, item 19). A name that has the part already keeps it once.
    public func accountModel(_ pasted: String) -> String? {
        let name = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, name.range(of: #"^[A-Za-z0-9._:/\[\]-]+$"#, options: .regularExpression) != nil
        else { return nil }
        guard let prefix else { return name }
        let full = name.hasPrefix(prefix + "/") ? name : prefix + "/" + name
        return full.count <= 120 ? full : nil
    }

    /// **The id of the new agent's account**: the agent's name and the provider ("iris-gemini"), one that the team has
    /// not, in team.json's form of an account id (`^[a-z][a-z0-9-]{1,30}$`).
    public func accountID(agent: String, taken: Set<String>) -> String {
        let stem = "-" + accountStem
        var head = String(agent.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(31 - stem.count - 2))
        while head.hasSuffix("-") { head.removeLast() }
        if head.isEmpty || !(head.first?.isLetter ?? false) { head = "agent" }
        let first = head + stem
        guard taken.contains(first) else { return first }
        for number in 2... {
            let next = "\(head)\(stem)-\(number)"
            if !taken.contains(next) { return next }
        }
        return first
    }

    /// **The variable name of the agent's key** in the vault ("GEMINI_IRIS_API_KEY"), one that no key of the list has,
    /// so that the vault's form never replaces another agent's key. The provider comes first: a name that starts with
    /// FLEET_, CLAUDE_, CODEX_, XAI_ or another reserved part never reaches a session (`lifecycle.key_env`).
    public func variable(agent: String, taken: Set<String>) -> String {
        let stem = variableStem + "_"
        var middle = String(agent.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(60 - stem.count - 10))
        while middle.hasSuffix("_") { middle.removeLast() }
        let base = middle.isEmpty ? stem : stem + middle + "_"
        let first = base + "API_KEY"
        guard taken.contains(first) else { return first }
        for number in 2... {
            let next = base + "\(number)_API_KEY"
            if !taken.contains(next) { return next }
        }
        return first
    }
}

/// **An agent's account with a kind**, as the app draws it: its provider, its kind and the address of a model server.
public struct ModelAccount: Equatable, Sendable {
    public let id: String
    public let provider: ModelProvider
    public let address: String?
    public let model: String?
    public let secret: String?

    public init?(id: String, entry: TeamAccount?) {
        guard let entry, let provider = ModelProvider(account: entry) else { return nil }
        self.id = id; self.provider = provider; address = entry.address; model = entry.model; secret = entry.secret
    }

    public var isServer: Bool { provider == .own }

    /// **The Account row's words** (picture 6): "Key" for a key, the server's address for a model server.
    public var accountWords: String { isServer ? (address ?? "") : String(l10n: "Key") }

    /// **The Usage row's words** (picture 6): a key and a model server have no allowance.
    public var usageWords: String { isServer ? String(l10n: "Local model") : String(l10n: "Paid per use") }

    /// The model as he named it, without the provider's part ("qwen/qwen3.8-max" for "openrouter/qwen/qwen3.8-max").
    public static func shownModel(_ model: String?, provider: ModelProvider) -> String? {
        guard let model, !model.isEmpty else { return nil }
        let part = provider == .own ? "own" : provider.prefix
        if let part, model.hasPrefix(part + "/") { return String(model.dropFirst(part.count + 1)) }
        return model
    }
}

/// **An agent's account with a kind, as `GET /ui/state` gives it** on each agent (`model_account`): its kind, its
/// provider, the name that the owner picked and a model server's address. Never its key.
public struct AgentModelAccount: Decodable, Equatable, Sendable {
    public let kind: String
    public let provider: String
    public let label: String?
    public let address: String?

    /// The Account row's words (picture 6): "Key", or the model server's address.
    public var accountWords: String { kind == "server" ? (address ?? "") : String(l10n: "Key") }
    /// The Usage row's words (picture 6): a key and a model server have no allowance.
    public var usageWords: String { kind == "server" ? String(l10n: "Local model") : String(l10n: "Paid per use") }
}

/// **Why an agent's account cannot work now** (owner API 1.186, `agents[].account_problem`): the hub's own record of
/// the newest turn on the account, until a later turn works.
public struct AccountProblem: Decodable, Equatable, Sendable {
    public let code: String
    public let error: String

    /// **The owner's words of picture 7** ("Yes, as shown"), in the device's language, or the hub's text for a code
    /// that has none here.
    public var words: String {
        switch code {
        case "key_no_credit": String(l10n: "The key has no credit.")
        case "server_no_answer": String(l10n: "Its model server does not answer.")
        default: error
        }
    }
}

extension TeamSnapshot {
    /// The account with a kind of this agent, or nil for an agent on a plan.
    public func modelAccount(of agent: String) -> ModelAccount? {
        guard let id = members.first(where: { $0.agent == agent })?.account else { return nil }
        return ModelAccount(id: id, entry: accounts?[id])
    }
}

// MARK: the address of a model server

/// **The address of the owner's model server, by the hub's own rule** (`hub.account_address`, spec 3.8), so that
/// "Your model server" says what is wrong after Return, under the hood and with no write (round 2, item 13). The hub's
/// refusal at the save gives the same words.
public enum ModelServerAddress {
    public static let most = 200

    /// The address in the hub's one form, or the code of its words: `address` or `plain_http`.
    public static func check(_ typed: String) -> Result<String, ModelAccountRefusal> {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrong = Result<String, ModelAccountRefusal>.failure(ModelAccountRefusal(code: "address"))
        guard !value.isEmpty, value.count <= most, !value.contains(where: { "?#@\\".contains($0) }),
              value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return wrong }
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = parts.host, !rawHost.isEmpty, parts.user == nil, parts.password == nil else { return wrong }
        if let port = parts.port, port <= 0 || port > 65535 { return wrong }
        let path = parts.percentEncodedPath
        guard path.range(of: #"^(?:/[A-Za-z0-9._~-]+)*/?$"#, options: .regularExpression) != nil else { return wrong }
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let v4 = ipv4(host), v6 = host.contains(":")
        if v4 == nil && !v6 {
            let label = #"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
            guard host.range(of: "^\(label)(?:\\.\(label))*$", options: .regularExpression) != nil else { return wrong }
        }
        if v6, IPv6(host) == nil { return wrong }
        if scheme == "http" && !(isLoopback(host) || host.hasSuffix(".ts.net") || v4.map(isTailscale) == true) {
            return .failure(ModelAccountRefusal(code: "plain_http"))
        }
        let place = (v6 ? "[\(host)]" : host) + (parts.port.map { ":\($0)" } ?? "")
        var tail = path
        while tail.hasSuffix("/") { tail.removeLast() }
        return .success("\(scheme)://\(place)\(tail.isEmpty ? "/v1" : tail)")
    }

    /// 127.0.0.0/8, ::1 or localhost: only such a model server may have no key (spec 3.8).
    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" { return true }
        if let v4 = ipv4(host) { return v4.0 == 127 }
        return IPv6(host).map { $0 == [0, 0, 0, 0, 0, 0, 0, 1] } ?? false
    }

    /// The host of an address, as the check reads it.
    public static func host(_ address: String) -> String? {
        URLComponents(string: address)?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func isTailscale(_ v4: (Int, Int, Int, Int)) -> Bool { v4.0 == 100 && (64...127).contains(v4.1) }

    private static func ipv4(_ host: String) -> (Int, Int, Int, Int)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        guard numbers.count == 4 else { return nil }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    /// The eight groups of an IPv6 address, or nil.
    private static func IPv6(_ host: String) -> [Int]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { bytes in stride(from: 0, to: 16, by: 2).map { Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]) } }
    }
}

// MARK: the words of a refusal and of the check

/// **A refusal of the hub about an account with a kind, by its code** (the coordinator's decision D7): the hub gives
/// his approved English words as `error`, a stable `code` and the case's `names`; the app shows its own string for a
/// code that it knows, in the device's language, and the hub's text for another.
public struct ModelAccountRefusal: Error, Equatable, Sendable {
    public let code: String
    public let names: [String: String]

    public init(code: String, names: [String: String] = [:]) { self.code = code; self.names = names }

    /// The app's own words for the code (`RefusalWords`, in the language of the device), or nil for a code that has
    /// none there.
    public var words: String? { RefusalWords.sentence(code, names.mapValues(RefusalName.text), say: { String(l10n: $0) }) }
}

extension HubRefusal {
    /// **Sentence 3** (round 2, item 14): the server has an agent on a model server with no key. Add agent then shows
    /// the line under the name field, whichever page pressed the add (it reads the code, never the words).
    public var isOpenServer: Bool { code == "open" }
}

public enum ModelAccountWords {
    /// **Sentence 9 on the model page** (round 2, item 18): the name that the seller's list does not have.
    public static func noSuchModel(_ model: String, provider: ModelProvider) -> String {
        provider == .own ? String(l10n: "Your model server has no model named \(model).")
            : String(l10n: "\(provider.label) has no model named \(model).")
    }

    /// **The words of a check's `account` item, by its code** (items 4 and 11, and round 2 sentence 9 on the setup
    /// page): the sentence alone, with no prefix. nil for a code that has no approved words here.
    public static func check(_ code: String, names: [String: String]) -> String? {
        switch code {
        case "no_answer": String(l10n: "This server does not answer.")
        case "open_server": String(l10n: "This server answers with no key, and more than one agent can reach it.")
        case "no_tool_call": String(l10n: "No model here passed a tool call.")
        case "small_context": String(l10n: "Its context is smaller than 64,000 tokens.")
        case "no_key": String(l10n: "The vault gave no key for this account.")
        case "key_refused": String(l10n: "The provider refused the key.")
        case "not_offered":
            if let provider = names["provider"], let model = names["model"], let agent = names["agent"] {
                String(l10n: "\(provider) has no model named \(model). Delete \(agent), then add it again with another model.")
            } else { nil }
        default: nil
        }
    }
}
