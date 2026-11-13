import Foundation

/// What one item of an export becomes: a login (a sign-in page, a user name and a password, and an optional
/// authenticator seed) or an API key (a variable name and the key, and an optional service address). It holds the
/// values in memory only, for the time of one import.
struct Candidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case login, apiKey }
    var kind: Kind
    var url = ""
    var username = ""
    var password = ""
    var totp = ""
    var env = ""
}

/// One item of an export as the import shows it: its name in the export, and what it becomes, or why it is not
/// imported. The name is the export's own title, never a value.
struct Found: Equatable, Sendable {
    let name: String
    let candidate: Candidate?
    let skipped: Skip?
    /// The name of the vault that holds the item, where the file names one (a 1Password `.1pux`).
    var vault: String? = nil
}

/// Why an item is not imported. Each kind has one line on the screen, with its count.
enum Skip: String, Equatable, Sendable, CaseIterable {
    case note, card, identity, sshKey, document, noValue, otherKind, archived, unreadable, noAddress
}

/// What an export file holds, read in this process.
struct ExportReading: Equatable, Sendable {
    enum Source: Equatable, Sendable { case bitwarden, bitwardenSecrets, onePassword }
    let source: Source
    let found: [Found]
}

enum ExportReader {
    enum Failure: Error, Equatable {
        /// The file is not an export that the import knows.
        case notAnExport
        /// The file is locked with a password of the export's own, and none or a wrong one was given.
        case password(wrong: Bool)
        /// The file is encrypted with the Bitwarden account's own key, which only Bitwarden opens.
        case lockedToAccount
        /// The file, or its data, is larger than the import reads.
        case tooLarge
        /// The file is damaged.
        case damaged
    }

    /// The most bytes of an export's data that the import reads, and the most items.
    static let dataLimit = 67_108_864, itemLimit = 20_000

    // MARK: Bitwarden

    /// A Bitwarden `.json` export of the Password Manager, plain or locked with a password, or a Secrets Manager export.
    static func bitwarden(_ data: Data, password: String? = nil) throws -> ExportReading {
        guard data.count <= dataLimit else { throw Failure.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notAnExport }
        if object["secrets"] is [Any], object["items"] == nil {
            return ExportReading(source: .bitwardenSecrets, found: try secretsManager(object))
        }
        if object["encrypted"] as? Bool == true {
            guard object["passwordProtected"] as? Bool == true else { throw Failure.lockedToAccount }
            // A password that is empty or only white space is no password, as Bitwarden's own importer reads it.
            guard let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.password(wrong: false) }
            guard let salt = object["salt"] as? String, let kdf = object["kdfType"] as? Int, let iterations = object["kdfIterations"] as? Int,
                  let check = object["encKeyValidation_DO_NOT_EDIT"] as? String, let sealed = object["data"] as? String else {
                throw Failure.damaged
            }
            let key: [UInt8]
            do {
                key = try ExportCrypto.passwordKey(password: password, salt: salt, kdf: kdf, iterations: iterations,
                                                   memory: object["kdfMemory"] as? Int, parallelism: object["kdfParallelism"] as? Int)
            } catch { throw Failure.damaged }
            let keys = ExportCrypto.stretch(key)
            do { _ = try ExportCrypto.open(check, enc: keys.enc, mac: keys.mac) }
            catch ExportCrypto.Failure.password { throw Failure.password(wrong: true) }
            catch { throw Failure.damaged }
            guard let inner = try? ExportCrypto.open(sealed, enc: keys.enc, mac: keys.mac) else { throw Failure.damaged }
            guard let plain = try? JSONSerialization.jsonObject(with: inner) as? [String: Any], plain["encrypted"] as? Bool != true else {
                throw Failure.damaged
            }
            return ExportReading(source: .bitwarden, found: try passwordManager(plain))
        }
        guard object["items"] is [Any] else { throw Failure.notAnExport }
        return ExportReading(source: .bitwarden, found: try passwordManager(object))
    }

    private static func passwordManager(_ object: [String: Any]) throws -> [Found] {
        guard let items = object["items"] as? [[String: Any]] else { throw Failure.notAnExport }
        guard items.count <= itemLimit else { throw Failure.tooLarge }
        return items.map { item in
            let name = text(item["name"])
            switch item["type"] as? Int {
            case 1:
                let login = item["login"] as? [String: Any] ?? [:]
                let uris = (login["uris"] as? [[String: Any]] ?? []).map { text($0["uri"]) }
                return made(name: name, username: text(login["username"]), password: text(login["password"]),
                            urls: uris, totp: text(login["totp"]))
            case 2: return Found(name: name, candidate: nil, skipped: .note)
            case 3: return Found(name: name, candidate: nil, skipped: .card)
            case 4: return Found(name: name, candidate: nil, skipped: .identity)
            case 5: return Found(name: name, candidate: nil, skipped: .sshKey)
            default: return Found(name: name, candidate: nil, skipped: .otherKind)
            }
        }
    }

    private static func secretsManager(_ object: [String: Any]) throws -> [Found] {
        guard let secrets = object["secrets"] as? [[String: Any]] else { throw Failure.notAnExport }
        guard secrets.count <= itemLimit else { throw Failure.tooLarge }
        return secrets.map { secret in
            let name = text(secret["key"]), value = text(secret["value"])
            guard !value.isEmpty else { return Found(name: name, candidate: nil, skipped: .noValue) }
            // Bitwarden's own words for a value that its web app could not decrypt at the export: not a value.
            guard value != "[error: cannot decrypt]" else { return Found(name: name, candidate: nil, skipped: .unreadable) }
            if let login = jsonLogin(value) { return Found(name: name, candidate: login, skipped: nil) }
            return Found(name: name, candidate: Candidate(kind: .apiKey, password: value, env: variable(name)), skipped: nil)
        }
    }

    /// A login as the fleet kept it in a Secrets Manager item: one JSON object with a user name, a password and a web
    /// address, and a seed where it had one. Such an item is a login, not an API key whose key is a line of JSON. Any
    /// other value is the key itself.
    private static func jsonLogin(_ value: String) -> Candidate? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              let username = object["username"] as? String, !username.isEmpty, let password = object["password"] as? String,
              !password.isEmpty, let url = (object["url"] as? String).flatMap(webAddress) else { return nil }
        return Candidate(kind: .login, url: url, username: username, password: password, totp: object["totp"] as? String ?? "")
    }

    // MARK: 1Password

    /// A 1Password `.1pux` export: its `export.data`, the items of every vault of every account in it.
    static func onePassword(_ file: some ExportBytes) throws -> ExportReading {
        let data: Data
        do { data = try ZipEntry.read("export.data", from: file, limit: dataLimit) }
        catch ZipEntry.Failure.tooLarge { throw Failure.tooLarge }
        catch ZipEntry.Failure.missing { throw Failure.notAnExport }
        catch { throw Failure.damaged }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else { throw Failure.notAnExport }
        var found: [Found] = []
        for account in accounts {
            for vault in account["vaults"] as? [[String: Any]] ?? [] {
                let name = text((vault["attrs"] as? [String: Any])?["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                for item in vault["items"] as? [[String: Any]] ?? [] {
                    var one = onePasswordItem(item)
                    one.vault = name.isEmpty ? nil : name
                    found.append(one)
                    guard found.count <= itemLimit else { throw Failure.tooLarge }
                }
            }
        }
        return ExportReading(source: .onePassword, found: found)
    }

    private static func onePasswordItem(_ item: [String: Any]) -> Found {
        let overview = item["overview"] as? [String: Any] ?? [:], details = item["details"] as? [String: Any] ?? [:]
        let name = text(overview["title"])
        if let state = item["state"] as? String, state != "active" { return Found(name: name, candidate: nil, skipped: .archived) }
        let urls = [text(overview["url"])] + (overview["urls"] as? [[String: Any]] ?? []).map { text($0["url"]) }
        let fields = (details["sections"] as? [[String: Any]] ?? []).flatMap { $0["fields"] as? [[String: Any]] ?? [] }
        func field(_ id: String) -> String {
            for field in fields where text(field["id"]) == id {
                let value = field["value"] as? [String: Any] ?? [:]
                for kind in ["concealed", "string", "url", "totp"] where !text(value[kind]).isEmpty { return text(value[kind]) }
            }
            return ""
        }
        let totp = fields.lazy.compactMap { ($0["value"] as? [String: Any])?["totp"] as? String }.first { !$0.isEmpty } ?? ""
        switch text(item["categoryUuid"]) {
        case "001":
            let login = details["loginFields"] as? [[String: Any]] ?? []
            func designated(_ which: String) -> String { text(login.first { text($0["designation"]) == which }?["value"]) }
            return made(name: name, username: designated("username"), password: designated("password"), urls: urls, totp: totp)
        case "005":
            return made(name: name, username: "", password: text(details["password"]), urls: urls, totp: "")
        case "112":
            return made(name: name, username: "", password: field("credential"), urls: urls + [field("hostname")], totp: "")
        case "003": return Found(name: name, candidate: nil, skipped: .note)
        case "002": return Found(name: name, candidate: nil, skipped: .card)
        case "004": return Found(name: name, candidate: nil, skipped: .identity)
        case "114": return Found(name: name, candidate: nil, skipped: .sshKey)
        case "006": return Found(name: name, candidate: nil, skipped: .document)
        default: return Found(name: name, candidate: nil, skipped: .otherKind)
        }
    }

    /// A 1Password `.csv` export: one row for each item, with the columns that its first row names.
    static func onePasswordCSV(_ data: Data) throws -> ExportReading {
        guard data.count <= dataLimit else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notAnExport }
        let rows = csvRows(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
              let title = header.firstIndex(of: "title"), let password = header.firstIndex(of: "password") else { throw Failure.notAnExport }
        guard rows.count - 1 <= itemLimit else { throw Failure.tooLarge }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        let url = column(["url", "website"]), username = column(["username"]), otp = column(["otpauth", "one-time password"])
        let archived = column(["archived"])
        return ExportReading(source: .onePassword, found: rows.dropFirst().filter { $0.contains { !$0.isEmpty } }.map { row in
            func cell(_ index: Int?) -> String { index.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            if ["true", "yes", "1"].contains(cell(archived).lowercased()) {
                return Found(name: cell(title), candidate: nil, skipped: .archived)
            }
            return made(name: cell(title), username: cell(username), password: cell(password), urls: [cell(url)], totp: cell(otp))
        })
    }

    /// RFC 4180: fields split by commas, a field in double quotes can hold commas, line ends and "" for one quote.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, afterQuote = false
        var scalars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? { if let p = pending { pending = nil; return p }; return scalars.next() }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = scalars.next() {
                        if n == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; afterQuote = true; pending = n }
                    } else { quoted = false }
                } else { field.unicodeScalars.append(c) }
                continue
            }
            switch c {
            case "\"" where field.isEmpty && !afterQuote: quoted = true
            case ",": row.append(field); field = ""; afterQuote = false
            case "\r": continue
            case "\n": row.append(field); rows.append(row); row = []; field = ""; afterQuote = false
            default: field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: what an item becomes

    /// A login when the item has a user name, a password and a web address; an API key, with the item's name as its
    /// variable name, when it has a password and no user name. An item with a user name and no web address is not
    /// imported, because a login needs the page that it signs in to; an item with no password has nothing to import.
    private static func made(name: String, username: String, password: String, urls: [String], totp: String) -> Found {
        guard !password.isEmpty else { return Found(name: name, candidate: nil, skipped: .noValue) }
        let address = urls.lazy.compactMap(webAddress).first ?? ""
        if !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !address.isEmpty else { return Found(name: name, candidate: nil, skipped: .noAddress) }
            return Found(name: name, candidate: Candidate(kind: .login, url: address, username: username, password: password,
                                                          totp: totp), skipped: nil)
        }
        return Found(name: name, candidate: Candidate(kind: .apiKey, url: address, password: password, env: variable(name)), skipped: nil)
    }

    /// A web address from one address of an item: the address itself, or a host with no scheme ("example.com/login")
    /// as the browser extensions of both managers keep it, which gets https. An address of an app ("androidapp://…")
    /// or of any other scheme is none.
    static func webAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isWebAddress(trimmed) { return trimmed }
        guard !trimmed.isEmpty, !trimmed.contains("://"), !trimmed.contains(where: \.isWhitespace),
              let host = trimmed.split(separator: "/", maxSplits: 1).first, host.contains("."), !host.contains("@") else { return nil }
        let guess = "https://" + trimmed
        return isWebAddress(guess) ? guess : nil
    }

    static func isWebAddress(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return false }
        return true
    }

    /// The endings that the hub asks of an API key's variable name (`lifecycle.key_env`).
    static let keyEndings = ["_KEY", "_TOKEN", "_SECRET", "_PASSWORD", "_PAT"]

    /// The variable name of an API key from an item's name: its letters without accents in capitals, its digits, and
    /// one "_" for each run of other characters, never starting with a digit, with one of the endings that the hub asks
    /// (`_KEY` when the name has none), and at most 60 characters. A name with no letter or digit gives "".
    static func variable(_ name: String) -> String {
        var out = ""
        for scalar in name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased().unicodeScalars {
            if ("A" ... "Z").contains(scalar) || ("0" ... "9").contains(scalar) { out.unicodeScalars.append(scalar) }
            else if !out.isEmpty && !out.hasSuffix("_") { out.append("_") }
        }
        while out.hasSuffix("_") { out.removeLast() }
        guard !out.isEmpty else { return "" }
        if let first = out.unicodeScalars.first, ("0" ... "9").contains(first) { out = "KEY_" + out }
        if out.count > 60 || !keyEndings.contains(where: out.hasSuffix) {
            out = String(out.prefix(56))
            while out.hasSuffix("_") { out.removeLast() }
            out += "_KEY"
        }
        return out
    }

    private static func text(_ value: Any?) -> String { value as? String ?? "" }
}
