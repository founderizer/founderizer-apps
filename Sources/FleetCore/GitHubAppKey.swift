import Foundation
import Security

/// **The owner's GitHub App key, proved on this Mac before the door gets it** (DevOps plan C5).
///
/// With a door, the hub holds no GitHub key: the key goes into the central vault with the door as its holder, and the
/// door's access file names it for one GitHub owner (`credentials["github:<owner>"]`). Before it goes, this Mac asks
/// GitHub which App the key signs for and who owns it (`GET /app`, with a JWT that the key signs here), as the hub did
/// with its own copy. The key lives in memory for this one call: nothing here writes it anywhere.
public enum GitHubAppKey {
    public enum Failure: LocalizedError, Equatable, Sendable {
        case key, sign, refused(Int), otherApp(String), answer

        public var errorDescription: String? {
            switch self {
            case .key: return String(l10n: "That file holds no RSA private key that this Mac can read.")
            case .sign: return String(l10n: "This Mac could not sign with that key.")
            case .refused(let status): return String(l10n: "GitHub did not take this key for that App ID (\(status)).")
            case .otherApp(let id): return String(l10n: "That key belongs to App \(id), not to the App ID you gave.")
            case .answer: return String(l10n: "GitHub's answer about the App was not one Founderizer reads.")
            }
        }
    }

    /// GitHub's answer to `GET /app`: the App's id and its owner's login.
    public struct App: Decodable, Equatable, Sendable {
        public struct Owner: Decodable, Equatable, Sendable { public let login: String }
        public let id: Int
        public let owner: Owner
    }

    /// The App that the key signs for, as GitHub says, and only when its id is the one the owner gave.
    public static func app(appID: String, pem: String, session: URLSession = .shared) async throws -> App {
        var request = URLRequest(url: URL(string: "https://api.github.com/app")!)
        request.setValue("Bearer \(try jwt(appID: appID, pem: pem))", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.refused(status) }
        guard let app = try? JSONDecoder().decode(App.self, from: data),
              app.owner.login.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil else { throw Failure.answer }
        guard String(app.id) == appID else { throw Failure.otherApp(String(app.id)) }
        return app
    }

    /// The accounts on which the App is installed, as GitHub says (`GET /app/installations`): the owners for which the
    /// door makes tokens with this one key (DevOps plan 13, item 4).
    public static func installations(appID: String, pem: String, session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.github.com/app/installations?per_page=100")!)
        request.setValue("Bearer \(try jwt(appID: appID, pem: pem))", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.refused(status) }
        struct Installation: Decodable {
            struct Account: Decodable { let login: String }
            let account: Account
        }
        guard let list = try? JSONDecoder().decode([Installation].self, from: data) else { throw Failure.answer }
        let logins = list.map(\.account.login).filter { $0.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil }
        return Array(Set(logins)).sorted()
    }

    /// A JWT of the App, as GitHub takes it: RS256, issued a minute back, for nine minutes.
    public static func jwt(appID: String, pem: String, now: Date = Date()) throws -> String {
        guard let der = der(pem) else { throw Failure.key }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { throw Failure.key }
        let time = Int(now.timeIntervalSince1970)
        let signed = base64url(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)) + "."
            + base64url(Data(#"{"exp":\#(time + 540),"iat":\#(time - 60),"iss":\#(appID)}"#.utf8))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)
        else { throw Failure.sign }
        return signed + "." + base64url(signature as Data)
    }

    /// The key of a PEM file as Security reads it, PKCS#1 DER, from either kind of file that GitHub downloads: an RSA
    /// private key, or a PKCS#8 private key that holds one.
    static func der(_ pem: String) -> Data? {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, let data = Data(base64Encoded: lines.filter { !$0.hasPrefix("-----") }.joined()) else { return nil }
        switch first {
        case "-----BEGIN RSA PRIVATE KEY-----": return data
        case "-----BEGIN PRIVATE KEY-----": return pkcs1(pkcs8: data)
        default: return nil
        }
    }

    /// The RSAPrivateKey inside a PKCS#8 PrivateKeyInfo: SEQUENCE { INTEGER 0, SEQUENCE { rsaEncryption, NULL },
    /// OCTET STRING { RSAPrivateKey } }. nil for anything else.
    static func pkcs1(pkcs8 data: Data) -> Data? {
        let bytes = [UInt8](data)
        var at = 0
        func element(_ tag: UInt8) -> Range<Int>? {
            guard at < bytes.count, bytes[at] == tag, at + 1 < bytes.count else { return nil }
            var length = Int(bytes[at + 1]), start = at + 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...3).contains(count), start + count <= bytes.count else { return nil }
                length = bytes[start..<(start + count)].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            guard start + length <= bytes.count else { return nil }
            return start..<(start + length)
        }
        guard let outer = element(0x30) else { return nil }
        at = outer.lowerBound
        guard let version = element(0x02), bytes[version] == [0] else { return nil }
        at = version.upperBound
        guard let algorithm = element(0x30) else { return nil }
        let rsaEncryption: [UInt8] = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
        guard Array(bytes[algorithm].prefix(rsaEncryption.count)) == rsaEncryption else { return nil }
        at = algorithm.upperBound
        guard let key = element(0x04) else { return nil }
        return Data(bytes[key])
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The App key as the central vault keeps it for the door: "pem:" and the PEM text in standard base64, on one line.
    /// A vault makes a fingerprint only of a value with no white space, and the central vault takes no value without
    /// one, so the PEM itself, with its line breaks, was refused at each round on 6 November 2026. The door turns it back
    /// into the PEM before it signs (`door_providers.app_jwt`).
    public static func vaultValue(_ pem: String) -> String { "pem:" + Data(pem.utf8).base64EncodedString() }

    /// The variable name of one owner's App key in the catalog: GITHUB_APP_, the owner in capitals, and _KEY, at most
    /// 60 characters. The hub takes an API key's name only when it ends as a key's name does (`lifecycle.key_env`:
    /// _KEY, _TOKEN, _SECRET, _PASSWORD or _PAT); without the ending, the move of the hub's App key to the door was
    /// refused at each round on 6 November 2026.
    public static func variable(owner: String) -> String {
        "GITHUB_APP_" + String(owner.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }).prefix(45) + "_KEY"
    }
}
