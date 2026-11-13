import FleetVaultIPC
import Foundation
import CryptoKit

final class VaultHub: @unchecked Sendable {
    private let configuration: VaultConfiguration
    private let session: URLSession
    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    /// `protocolClasses` only for tests: a fake hub in place of the network.
    init(configuration: VaultConfiguration, protocolClasses: [AnyClass]? = nil) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: Redirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    /// This broker puts provenance into each copy and checks it (owner API 1.10), so it says so to the hub.
    /// A sign-in and a request also say that this broker checks its own journal before it uses a login that a `create`
    /// job made (`creation`). The hub gives that use only to a broker that says so: an older broker would not read
    /// `created_by`.
    static func confirmBody(_ request: VaultRequest) throws -> Data {
        guard let job = request.job, [.signin, .handover, .request].contains(request.operation) else { throw VaultFailure.request }
        var body: [String: Any] = ["job": job, "kind": request.operation.rawValue, "provenance": VaultProvenance.version]
        if request.operation != .handover { body["creation"] = VaultCreation.version }
        return try JSONSerialization.data(withJSONObject: body)
    }

    // Every hub call of a job names the job's own caller: its agent in the route and its key in the header.
    func confirm(_ request: VaultRequest, as caller: VaultCaller) async throws -> VaultJob {
        let data = try await send(path: "/helper/vault/\(caller.agent)", method: "POST", body: Self.confirmBody(request), as: caller)
        let job = try VaultJob(data: data, request: request)
        // DevOps plan 0.3: a handover's confirmation is a job only once the owner's pin of its recipient passes, so the
        // broker never reads, protects or seals a login for a key that the owner did not pin (VaultOwnerPin).
        if request.operation == .handover { try VaultOwnerPin.check(job, configuration: configuration) }
        return job
    }

    /// The hub's confirmation of a save job (`create` or `capture`). It can be asked again while the job is open and
    /// gives the same values.
    func confirmCreate(_ request: VaultRequest, as caller: VaultCaller) async throws -> VaultCreateJob {
        guard [.create, .capture].contains(request.operation), let job = request.job else { throw VaultFailure.request }
        let body = try JSONSerialization.data(withJSONObject: ["job": job, "kind": request.operation.rawValue])
        let data = try await send(path: "/helper/vault/\(caller.agent)", method: "POST", body: body, as: caller)
        return try VaultCreateJob(data: data, request: request, agent: caller.agent)
    }

    /// The hub's confirmation of a `request` job: the fields of a sign-in, and what the vault sends. The hub confirms
    /// such a job once only; the vault asks for each request and keeps no confirmation.
    func confirmCall(_ request: VaultRequest, as caller: VaultCaller) async throws -> (VaultJob, VaultCall) {
        guard request.operation == .request else { throw VaultFailure.request }
        // A body of the largest size can double in its JSON form.
        let data = try await send(path: "/helper/vault/\(caller.agent)", method: "POST", body: Self.confirmBody(request), as: caller,
                                  limit: 524_288)
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VaultFailure.hub }
        return (try VaultJob(data: data, request: request), try VaultCall(fields: fields))
    }

    /// Tells the hub which login a `create` job made, and gets the salts of that login's fingerprints.
    func created(job: Int, login: String, as caller: VaultCaller) async throws -> [String: String] {
        let body = try JSONSerialization.data(withJSONObject: ["job": job, "login": login])
        let data = try await send(path: "/helper/vault/\(caller.agent)/created", method: "POST", body: body, as: caller)
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["ok"] as? Bool == true,
              VaultRequest.integer(reply["job"]) == job, reply["login"] as? String == login,
              let salts = reply["fingerprint_salts"] as? [String: String], Set(salts.keys) == ["password", "totp"],
              salts.values.allSatisfy({ $0.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }) else { throw VaultFailure.hub }
        return salts
    }

    /// Registers the fingerprints that the writer made from its own item, for a `create` job.
    func protect(_ items: [VaultFingerprint], job: Int, as caller: VaultCaller) async throws {
        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "job": job, "fingerprints": items.map { ["kind": $0.kind, "hash": $0.hash, "len": $0.len] as [String: Any] }])
            let data = try await send(path: "/helper/vault/\(caller.agent)/fingerprints", method: "POST", body: body, as: caller)
            try Self.confirmProtection(data, job: job, count: items.count)
        } catch VaultFailure.key { throw VaultFailure.key } catch { throw VaultFailure.protection }
    }

    /// The API keys that the caller reads in its sessions (owner feature secrets), as the hub names them now. No value.
    func confirmRead(as caller: VaultCaller) async throws -> [VaultRead] {
        try VaultRead.list(await send(path: "/helper/vault/\(caller.agent)/read", method: "POST", body: Data("{}".utf8), as: caller))
    }

    /// Registers the fingerprints of a value that a session reads, before the vault gives it. The hub takes them only
    /// for a read grant of the caller.
    func protect(_ secret: VaultSecret, read: VaultRead, as caller: VaultCaller) async throws {
        let items = Self.fingerprints(secret, salts: read.salts)
        guard !items.isEmpty else { return }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["login": read.login, "fingerprints": items])
            let data = try await send(path: "/helper/vault/\(caller.agent)/fingerprints", method: "POST", body: body, as: caller)
            guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["ok"] as? Bool == true,
                  reply["login"] as? String == read.login,
                  let stored = VaultRequest.integer(reply["stored"]), let known = VaultRequest.integer(reply["known"]),
                  stored >= 0, known >= 0, stored + known == items.count else { throw VaultFailure.protection }
        } catch VaultFailure.key { throw VaultFailure.key } catch { throw VaultFailure.protection }
    }

    /// The copy of one delivery that this caller's helper carries (owner feature `central_vault`), with the
    /// secret's reference, name and kind and the salts of its fingerprints. The hub gives it again while the delivery
    /// waits, and a save under the same reference is the same save.
    func confirmDeposit(_ request: VaultRequest, as caller: VaultCaller) async throws -> VaultDeposit {
        guard request.operation == .deposit, let job = request.job else { throw VaultFailure.request }
        let body = try JSONSerialization.data(withJSONObject: ["job": job, "kind": "deposit"])
        let data = try await send(path: "/helper/vault/\(caller.agent)", method: "POST", body: body, as: caller)
        return try VaultDeposit(data: data, request: request)
    }

    /// Has the hub compare the fingerprints of a delivered value with those that the owner's vault registered under its
    /// reference, before anything is saved. Nothing is registered: a copy that holds another value is refused here.
    func compare(_ secret: VaultSecret, deposit: VaultDeposit, as caller: VaultCaller) async throws {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["deposit": deposit.id,
                                                                   "fingerprints": Self.fingerprints(secret, salts: deposit.salts)])
            let data = try await send(path: "/helper/vault/\(caller.agent)/fingerprints", method: "POST", body: body, as: caller)
            guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["ok"] as? Bool == true,
                  VaultRequest.integer(reply["deposit"]) == deposit.id else { throw VaultFailure.depositValue }
        } catch VaultFailure.key { throw VaultFailure.key } catch { throw VaultFailure.depositValue }
    }

    /// The secret that a withdrawal of this caller's helper names (helper feature `secret_withdrawals`): its reference
    /// and nothing else. The hub gives it again while the withdrawal waits, and a removal of what is not there is the
    /// same removal.
    func confirmWithdrawal(_ request: VaultRequest, as caller: VaultCaller) async throws -> VaultWithdrawal {
        guard request.operation == .withdraw, let job = request.job else { throw VaultFailure.request }
        let body = try JSONSerialization.data(withJSONObject: ["job": job, "kind": "withdraw"])
        let data = try await send(path: "/helper/vault/\(caller.agent)", method: "POST", body: body, as: caller)
        return try VaultWithdrawal(data: data, request: request)
    }

    func confirmProbe(_ request: VaultRequest, as caller: VaultCaller) async throws -> VaultProbeJob {
        guard request.operation == .probe, let job = request.job else { throw VaultFailure.request }
        let body = try JSONSerialization.data(withJSONObject: ["job": job, "kind": "probe"])
        let data = try await send(path: "/helper/vault/\(caller.agent)", method: "POST", body: body, as: caller)
        return try VaultProbeJob(data: data, request: request)
    }

    func sealed(_ job: VaultJob, as caller: VaultCaller) async throws -> (Data, String, SealedRecord) {
        guard job.login.hasPrefix("sealed:") else { throw VaultFailure.handover }
        var parts = URLComponents()
        parts.queryItems = [URLQueryItem(name: "agent", value: caller.agent), URLQueryItem(name: "task", value: job.task)]
        let data = try await send(path: "/sealed/\(job.login.dropFirst(7))?\(parts.percentEncodedQuery!)", as: caller)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ciphertext = object["ciphertext"] as? String,
              ciphertext.hasPrefix("-----BEGIN AGE ENCRYPTED FILE-----\n"), ciphertext.utf8.count <= 65536 else {
            throw VaultFailure.handover
        }
        return (Data(ciphertext.utf8), object["label"] as? String ?? job.login, try SealedRecord(object: object))
    }

    static func fingerprints(_ login: VaultLogin, job: VaultJob) -> [[String: Any]] { fingerprints(login.secret, salts: job.fingerprintSalts) }

    static func fingerprints(_ login: VaultLogin, salts: [String: String]) -> [[String: Any]] { fingerprints(login.secret, salts: salts) }

    /// `salts`: one for `password` and one for `totp`, as a job's `fingerprint_salts`.
    static func fingerprints(_ secret: VaultSecret, salts: [String: String]) -> [[String: Any]] {
        secret.protectedValues.filter { !$0.value.unicodeScalars.contains(where: VaultBrowser.isWhitespace) }.map { kind, value in
            let digest = SHA256.hash(data: Data((salts[kind]! + value).utf8))
            return ["kind": kind, "hash": digest.map { String(format: "%02x", $0) }.joined(),
                    "len": value.unicodeScalars.count]
        }
    }

    static func confirmProtection(_ data: Data, job: Int, count: Int) throws {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["ok"] as? Bool == true, VaultRequest.integer(reply["job"]) == job,
              let stored = VaultRequest.integer(reply["stored"]), (0...count).contains(stored),
              let known = VaultRequest.integer(reply["known"]), (0...count).contains(known),
              stored + known == count else { throw VaultFailure.protection }
    }

    func protect(_ login: VaultLogin, job: VaultJob, as caller: VaultCaller) async throws {
        let items = Self.fingerprints(login, job: job)
        guard !items.isEmpty else { return }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["job": job.id, "fingerprints": items])
            let data = try await send(path: "/helper/vault/\(caller.agent)/fingerprints", method: "POST", body: body, as: caller)
            try Self.confirmProtection(data, job: job.id, count: items.count)
        } catch VaultFailure.key { throw VaultFailure.key } catch { throw VaultFailure.protection }
    }

    /// One request of its own for each call, so overlapping jobs of different agents never share a caller or a key.
    private func send(path: String, method: String = "GET", body: Data? = nil, as caller: VaultCaller, limit: Int = 131_072) async throws -> Data {
        let base = configuration.hub.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else { throw VaultFailure.hub }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization = caller.authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            guard status == 200 || status == 403, response.expectedContentLength <= Int64(limit) else { throw VaultFailure.hub }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw VaultFailure.hub }; data.append(byte)
            }
            // The hub refused the caller's credential (owner API 1.12: 403 with `auth`). Every other refusal stays the hub's.
            if status == 403 {
                throw (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["auth"] is String ? VaultFailure.key : VaultFailure.hub
            }
            return data
        } catch VaultFailure.key { throw VaultFailure.key } catch { throw VaultFailure.hub }
    }
}
