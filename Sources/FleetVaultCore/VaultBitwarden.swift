import Darwin
import Foundation

/// What the broker's own operations ask of a store, whichever one this vault opens (`vault.py`'s two stores behind
/// `opened_store`): one login, one value, and which logins of a probe job it can open.
/// One store is opened for one request and used by that request alone — the broker serves one job at a time — so a
/// store crosses a task boundary (`request` reads its login inside the call) and is `Sendable` by that use.
protocol VaultStore: Sendable {
    func login(secretID: String) throws -> VaultLogin
    func secret(id: String) throws -> VaultSecret
    func probe(job: VaultProbeJob) -> [VaultProbeResult]
}

/// A Bitwarden Secrets Manager project, read with this machine's own access token. The token stays in this process;
/// each call signs in with it, as before, and `read` signs in once for all of its values.
final class VaultBitwardenStore: VaultStore, @unchecked Sendable {
    private let sdk: VaultBitwarden
    private let token: Data
    private var signedIn = false

    init(sdk: VaultBitwarden, token: Data) { self.sdk = sdk; self.token = token }

    func login(secretID: String) throws -> VaultLogin { try sdk.login(token: token, secretID: secretID) }

    func secret(id: String) throws -> VaultSecret {
        if !signedIn { try sdk.authenticate(token: token); signedIn = true }
        return try sdk.secret(id: id)
    }

    func probe(job: VaultProbeJob) -> [VaultProbeResult] { sdk.probe(token: token, job: job) }
}

/// The SDK is in the hardened helper process. There is no token-bearing child process.
final class VaultBitwarden: VaultItems {
    typealias Create = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias Run = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    typealias FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private let library: UnsafeMutableRawPointer
    private let client: UnsafeMutableRawPointer
    private let destroy: Destroy
    private let run: Run
    private let freeString: FreeString

    init(libraryURL: URL, region: String) throws {
        guard ["eu", "us"].contains(region), let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw VaultFailure.dependency
        }
        guard let initSymbol = dlsym(library, "init"), let freeSymbol = dlsym(library, "free_mem"),
              let runSymbol = dlsym(library, "run_command"), let stringSymbol = dlsym(library, "fleet_free_string") else {
            dlclose(library); throw VaultFailure.dependency
        }
        let create = unsafeBitCast(initSymbol, to: Create.self)
        let domain = region == "eu" ? "bitwarden.eu" : "bitwarden.com"
        let settings = "{\"apiUrl\":\"https://api.\(domain)\",\"identityUrl\":\"https://identity.\(domain)\",\"userAgent\":\"Founderizer Vault\",\"deviceType\":\"SDK\"}"
        guard let client = settings.withCString({ create($0) }) else { dlclose(library); throw VaultFailure.dependency }
        self.library = library; self.client = client
        destroy = unsafeBitCast(freeSymbol, to: Destroy.self)
        run = unsafeBitCast(runSymbol, to: Run.self)
        freeString = unsafeBitCast(stringSymbol, to: FreeString.self)
    }
    deinit { destroy(client); dlclose(library) }

    private func command(_ object: [String: Any]) throws -> [String: Any] {
        guard let input = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8),
              let output = input.withCString({ run($0, client) }) else { throw VaultFailure.provider }
        defer { freeString(output) }
        let length = strnlen(output, 1_048_577)
        guard length <= 1_048_576,
              let response = try? JSONSerialization.jsonObject(with: Data(bytes: output, count: length)) as? [String: Any],
              response["success"] as? Bool == true,
              let data = response["data"] as? [String: Any] else { throw VaultFailure.provider }
        return data
    }

    func authenticate(token: Data) throws {
        guard let token = String(data: token, encoding: .utf8) else { throw VaultFailure.keychain }
        _ = try command(["loginAccessToken": ["accessToken": token]])
    }

    func login(token: Data, secretID: String) throws -> VaultLogin {
        try authenticate(token: token)
        let item = try command(["secrets": ["get": ["id": secretID]]])
        guard let id = item["id"] as? String, id.lowercased() == secretID.lowercased(),
              let label = item["key"] as? String, !label.isEmpty,
              let value = item["value"] as? String else { throw VaultFailure.provider }
        return try VaultLogin(data: Data(value.utf8), label: label)
    }

    // MARK: the writer of the owner's Mac (after `authenticate`). The calls above are the worker broker's and do not change.

    private static func isID(_ text: String) -> Bool { UUID(uuidString: text) != nil }

    func organization(ofProject project: String) throws -> String {
        guard Self.isID(project) else { throw VaultFailure.provider }
        let data = try command(["projects": ["get": ["id": project]]])
        guard (data["id"] as? String)?.lowercased() == project.lowercased(),
              let organization = data["organizationId"] as? String, Self.isID(organization) else { throw VaultFailure.provider }
        return organization
    }

    /// The SDK lists the item names of an organization; the project and the name select here.
    func items(named name: String, project: String, organization: String) throws -> [String] {
        guard let rows = try command(["secrets": ["list": ["organizationId": organization]]])["data"] as? [[String: Any]] else {
            throw VaultFailure.provider
        }
        return try rows.compactMap { row in
            guard let id = row["id"] as? String, Self.isID(id), let key = row["key"] as? String,
                  let projects = row["projectIds"] as? [String] else { throw VaultFailure.provider }
            return key == name && projects.contains { $0.lowercased() == project.lowercased() } ? id : nil
        }
    }

    func notes(of ids: [String]) throws -> [String: String] {
        guard let rows = try command(["secrets": ["getByIds": ["ids": ids]]])["data"] as? [[String: Any]] else {
            throw VaultFailure.provider
        }
        var notes: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as? String, let note = row["note"] as? String else { throw VaultFailure.provider }
            notes[id] = note
        }
        return notes
    }

    /// Exactly one create call. Only an answer of the server with a 4xx status proves that nothing was made; no answer,
    /// an answer that cannot be read and a 5xx status leave the outcome unknown. The error text is never passed on.
    func create(name: String, value: String, note: String, project: String, organization: String) -> VaultCreateOutcome {
        let request: [String: Any] = ["secrets": ["create": ["organizationId": organization, "key": name, "value": value,
                                                             "note": note, "projectIds": [project]]]]
        guard let json = try? JSONSerialization.data(withJSONObject: request), let input = String(data: json, encoding: .utf8) else { return .refused }
        guard let output = input.withCString({ run($0, client) }) else { return .unknown }
        defer { freeString(output) }
        let length = strnlen(output, 1_048_577)
        guard length <= 1_048_576,
              let response = try? JSONSerialization.jsonObject(with: Data(bytes: output, count: length)) as? [String: Any] else { return .unknown }
        if response["success"] as? Bool == true {
            guard let id = (response["data"] as? [String: Any])?["id"] as? String, Self.isID(id) else { return .unknown }
            return .created(id)
        }
        let message = response["errorMessage"] as? String ?? ""
        return message.range(of: #"^Received error message from server: \[4[0-9]{2}[ \]]"#, options: .regularExpression) != nil ? .refused : .unknown
    }

    /// The secret values of one item, after `authenticate`: also an API key without an address (owner feature secrets).
    func secret(id: String) throws -> VaultSecret {
        let item = try command(["secrets": ["get": ["id": id]]])
        guard let found = item["id"] as? String, found.lowercased() == id.lowercased(),
              let value = item["value"] as? String else { throw VaultFailure.provider }
        return try VaultSecret(data: Data(value.utf8))
    }

    func probe(token: Data, job: VaultProbeJob) -> [VaultProbeResult] {
        do { try authenticate(token: token) }
        catch { return job.logins.map { VaultProbeResult(login: $0, reason: .error) } }
        let deadline = Date().addingTimeInterval(30)
        return job.logins.map { login in
            guard Date() < deadline else { return VaultProbeResult(login: login, reason: .timeout) }
            do {
                let id = String(login.dropFirst(6))
                let item = try command(["secrets": ["get": ["id": id]]])
                guard let found = item["id"] as? String, found.lowercased() == id.lowercased(),
                      let value = item["value"] as? String else { return VaultProbeResult(login: login, reason: .bad_format) }
                return VaultProbeResult.inspect(login: login, value: Data(value.utf8))
            } catch { return VaultProbeResult(login: login, reason: .error) }
        }
    }
}
