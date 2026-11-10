import Foundation

/// The owner's default model and reasoning for one AI provider (owner feature `default_models`, owner API 1.108): the
/// runtime fact `default_model` of team.json. The owner, 9 November 2026: "we should be able to choose the default
/// model and reasoning effort for each agent, depending on the ai provider. There should be a default for each
/// somewhere under settings, and then each agent can be changed individually". His yes of the same day: a "Default
/// models" section in Settings › General, one row per provider with a Model and a Reasoning menu, and an agent's first
/// option "Default (Opus)".
public struct ModelDefault: Codable, Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public init(model: String? = nil, effort: String? = nil) { self.model = model; self.effort = effort }
    public var isEmpty: Bool { model == nil && effort == nil }
    enum CodingKeys: String, CodingKey { case model, effort }
    /// Both keys always, null for the provider's own: the hub's check takes exactly these two.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(model, forKey: .model)
        try values.encode(effort, forKey: .effort)
    }
}

/// `GET /ui/settings`, as the Default models section reads it: each provider's default, and the models that its
/// servers report (`models`, merged by the hub). The other settings and facts of that page are not this app's.
public struct DefaultModelsPage: Decodable, Sendable {
    public let db: String
    public let defaults: [String: ModelDefault]
    public let models: [String: [RuntimeModels.Option]]

    enum CodingKeys: String, CodingKey { case db, runtime_facts, models }
    private struct Facts: Decodable { let default_model: Fact? }
    private struct Fact: Decodable { let value: ModelDefault? }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        db = try values.decode(String.self, forKey: .db)
        let facts = (try? values.decodeIfPresent([String: Facts].self, forKey: .runtime_facts)) ?? nil
        defaults = (facts ?? [:]).compactMapValues { $0.default_model?.value }.filter { !$0.value.isEmpty }
        models = (try? values.decodeIfPresent([String: [RuntimeModels.Option]].self, forKey: .models)) ?? [:]
    }

    public init(db: String, defaults: [String: ModelDefault], models: [String: [RuntimeModels.Option]]) {
        self.db = db; self.defaults = defaults; self.models = models
    }

    /// The providers that get a row: each one whose servers report models, and one whose default is set even while
    /// no server reports it, so that he can still see and clear it. Claude Code first, then Codex, then by name.
    public var runtimes: [String] {
        Set(models.filter { !$0.value.isEmpty }.keys).union(defaults.keys)
            .sorted { (DefaultModels.order($0), $0) < (DefaultModels.order($1), $1) }
    }

    /// The efforts that `model` takes among a provider's options: its own; with no model, those of the list's default
    /// model, else (Claude, whose list marks none) of every model, as the hub checks a default.
    public func efforts(_ runtime: String, for model: String?) -> [String] {
        DefaultModels.efforts(models[runtime] ?? [], for: model)
    }
}

/// The hub's answer to `POST /ui/settings`.
public struct SettingsReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let changed: [String]
}

public enum DefaultModels {
    public static let feature = "default_models"

    static func order(_ runtime: String) -> Int { ["claude": 0, "codex": 1][runtime] ?? 2 }

    /// The efforts of `model` among `options`; with no model or one that is not listed, those of the list's one
    /// default model, else those of every model (fleet.run_settings, hub.default_model_check).
    public static func efforts(_ options: [RuntimeModels.Option], for model: String?) -> [String] {
        if let model, let entry = options.first(where: { $0.model == model }) { return entry.efforts }
        let defaults = options.filter(\.default)
        if model == nil, defaults.count == 1 { return defaults[0].efforts }
        var all: [String] = []
        for option in options { for effort in option.efforts where !all.contains(effort) { all.append(effort) } }
        return all
    }

    /// The listed entry of `model`, or with no model the list's one default (fleet.run_settings).
    static func entry(_ options: [RuntimeModels.Option], for model: String?) -> RuntimeModels.Option? {
        if let model { return options.first { $0.model == model } }
        let defaults = options.filter(\.default)
        return defaults.count == 1 ? defaults[0] : nil
    }

    /// The model and the effort that a new session of an agent gets, as its helper picks them (fleet.run_settings),
    /// short of the list's own default model: its own model, else the owner's default where its server's list offers
    /// it; its own effort, which gives way where it has no model of its own and the model that it gets does not offer
    /// it; else the default's effort where that model offers it. Its own values alone from a helper that does not take
    /// defaults yet (helper feature `default_models`) and without a current list of the agent's runtime.
    public static func session(_ chosen: ModelDefault?, model: String?, effort: String?, machine models: RuntimeModels?,
                               runtime: String?, takes: Bool) -> ModelDefault {
        var out = ModelDefault(model: model, effort: effort)
        guard let models, models.isFor(runtime) else { return out }
        let wanted = takes ? chosen : nil
        if model == nil, let name = wanted?.model, models.offers(name) { out.model = name }
        let efforts = efforts(models.options, for: out.model)
        if model == nil, let own = effort, let listed = entry(models.options, for: out.model), !listed.efforts.contains(own) {
            out.effort = nil
        }
        if out.effort == nil, let level = wanted?.effort, efforts.contains(level) { out.effort = level }
        return out
    }
}

extension RuntimeModels {
    /// True when this list offers `model`: a listed one, or a full `claude-*` name where Claude takes other names.
    public func offers(_ model: String) -> Bool {
        options.contains { $0.model == model } || (other_names && runtime == "claude" && model.hasPrefix("claude-"))
    }
}

/// `GET /ui/settings` and the one write of the Default models section.
public final class DefaultModelsClient: Sendable {
    /// One session for every client of this kind: General makes one at each read and each save.
    private static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60        // the hub commits and pushes team.json before it answers
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()
    private var session: URLSession { Self.shared }

    public init() {}

    public func read(hub: URL, database: String) async throws -> DefaultModelsPage {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/settings"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let page = try JSONDecoder().decode(DefaultModelsPage.self, from: await fetch(request))
        guard page.db == database else { throw HubError.invalidResponse }
        return page
    }

    /// One provider's default; an empty one takes it away (null: the provider's own). The same `requestID` again is
    /// the same request: the hub answers a repeat of one it carried out with its receipt.
    public func save(hub: URL, database: String, client: String, runtime: String, value: ModelDefault,
                     requestID: String = UUID().uuidString.lowercased()) async throws -> SettingsReceipt {
        var request = URLRequest(url: hub.appendingPathComponent("ui/settings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try Self.body(runtime: runtime, value: value, requestID: requestID, database: database)
        let receipt = try JSONDecoder().decode(SettingsReceipt.self, from: await fetch(request))
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client else { throw HubError.invalidResponse }
        return receipt
    }

    static func body(runtime: String, value: ModelDefault, requestID: String, database: String) throws -> Data {
        let fact: Any = value.isEmpty ? NSNull() : ["model": value.model.map { $0 as Any } ?? NSNull(),
                                                    "effort": value.effort.map { $0 as Any } ?? NSNull()]
        return try JSONSerialization.data(withJSONObject: ["request_id": requestID, "db": database,
                                                           "runtime_facts": [runtime: ["default_model": fact]]],
                                          options: [.sortedKeys])
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Unexpected HTTP response."
            throw HubError.refusal(response.statusCode, String(message.prefix(500)))
        }
        return data
    }

    private struct ErrorBody: Decodable { let error: String }
}
