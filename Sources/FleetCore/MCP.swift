import Foundation

/// How a remote server of the owner signs in (UI-API.md, "Custom MCP servers (owner feature `mcp`)"): nothing, the
/// hub's own Connect in the browser, or an API key of the Secrets page that the agent reads.
public enum MCPAuth: String, Codable, CaseIterable, Sendable {
    case none, oauth, key

    public var title: String {
        switch self {
        case .none: String(l10n: "No sign-in")
        case .oauth: String(l10n: "Connect in the browser")
        case .key: String(l10n: "An API key")
        }
    }
    public var subtitle: String {
        switch self {
        case .none: "A server that gives its tools to everybody"
        case .oauth: "You sign in once; the hub keeps the access and gives each task session a short-lived token"
        case .key: "A key of the Secrets page, which the agent reads in its sessions"
        }
    }
}

/// What a server runs: a remote server at an address, or a program of the agent's machine.
public enum MCPKind: String, CaseIterable, Sendable {
    case remote, local

    public var title: String { self == .remote ? String(l10n: "A remote server") : String(l10n: "A program on the server") }
}

/// **The hub's rules of a program server, as this app keeps them** (`lifecycle.py`: `SETTING_NAME`, `SETTING_REFUSED`,
/// `KEY_ENV`, `ENV_RESERVED`, `KEY_SUFFIXES`, `MCP_PROGRAM`, `NPM_PACKAGE`, `PYPI_PACKAGE`, `PACKAGE_VERSION`,
/// `PACKAGE_DAY`, the limits of `mcp_server`, and `hub.MCP_FIND_WORDS`). Each is a plain literal on one line, with one
/// name, so that a Python test can read this file and hold each against the hub's own. A pattern is matched whole, as
/// `re.fullmatch` does it; a name is matched in capitals, which is the hub's `IGNORECASE` for an ASCII name.
public enum MCPRules {
    /// A program's own variable (`SETTING_NAME`).
    public static let settingName = "[A-Za-z_][A-Za-z0-9_]{0,59}"
    /// The names that no setting and no program variable of the form may have, in capitals (`SETTING_REFUSED`). The hub
    /// also takes one with a key's ending as the variable of a key, as before (`lifecycle.key_variable`).
    public static let refusedNames = "(?:FLEET|BWS|LD|DYLD|ANTHROPIC|CLAUDE|CODEX|XAI|NODE|NPM_CONFIG|UV|PIP|PIPX|POETRY|CONDA|VIRTUAL_ENV|GIT|OPENSSL|CURL|REQUESTS|HTTPLIB2|GCONV|MALLOC|GLIBC|JAVA|JDK|_JAVA|GEM|BUNDLE|DENO|BUN|ELECTRON|GRPC|XDG)(?:_[A-Z0-9_]*)?|PYTHON[A-Z0-9_]*|PERL[A-Z0-9_]*|RUBY[A-Z0-9_]*|SSL[A-Z0-9_]*|[A-Z0-9_]*_PROXY|[A-Z0-9_]*_CA_BUNDLE|PATH|HOME|SHELL|USER|LOGNAME|TMPDIR|TEMP|TMP|TERM|TERMINFO|TERMCAP|PWD|OLDPWD|IFS|ENV|BASH_ENV|ZDOTDIR|CDPATH|GLOBIGNORE|SHELLOPTS|BASHOPTS|PROMPT_COMMAND|PS[1-4]|HISTFILE|INPUTRC|LANG|LANGUAGE|LC_[A-Z_]*|TZ|TZDIR|LOCPATH|NLSPATH|HOSTALIASES|RES_OPTIONS|LOCALDOMAIN|CLASSPATH|BROWSER|EDITOR|VISUAL|PAGER|LESSOPEN|LESSCLOSE|MANPAGER"
    /// The name of an API key in a session (`KEY_ENV`), with one of `keyEndings` and none of `reservedNames`.
    public static let keyName = "[A-Z][A-Z0-9_]{0,59}"
    /// The names that a session's start or a runtime sets or reads itself, which no key may have (`ENV_RESERVED`). A
    /// key that the form makes has none of `refusedNames` (`NODE_AUTH_TOKEN`) and none of `fleetKeys` either.
    public static let reservedNames = "(?:FLEET|BWS|LD|DYLD|ANTHROPIC|CLAUDE|CODEX|XAI)_[A-Z0-9_]*|PATH|HOME|SHELL|USER|LOGNAME|TMPDIR|TERM|PWD|IFS|ENV|BASH_ENV|ZDOTDIR|NODE_OPTIONS|PYTHONPATH|PYTHONHOME"
    /// The keys that Fleet itself puts in a task session (`FLEET_KEYS`): no server takes its key from one, because the
    /// session's own value wins over an API key of the same name.
    public static let fleetKeys = ["GH_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN"]
    /// The endings of an API key's variable (`KEY_SUFFIXES`).
    public static let keyEndings = ["_KEY", "_TOKEN", "_SECRET", "_PASSWORD", "_PAT"]
    /// A variable is a key when its name has one of `keyEndings`, or one of these among its words (`SECRET_WORDS`,
    /// `MCP.flagWords`); a flag of an argument takes a secret when one of its words is one of them.
    public static let secretWords = ["KEY", "APIKEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "PWD", "PAT", "CREDENTIAL", "CREDENTIALS", "COOKIE", "AUTH", "AUTHORIZATION", "DSN", "PRIVATE", "BEARER"]
    /// A flag of an argument (`FLAG`): `--access-token`, `--api-key`, `-p`.
    public static let flag = "--?[A-Za-z0-9][A-Za-z0-9_-]*"
    /// A URL with a user part, or with a password in it, anywhere in a value (`CREDENTIAL_URL`): no plain value holds
    /// one. A raw literal, so its text is the hub's.
    public static let credentialURL = #"[A-Za-z][A-Za-z0-9+.-]*://(?:[^/@\s]+|[^@\s]*:[^@\s]*)@"#
    /// The programs that no `command` server may run (`MCP_RUNNERS`): they fetch, wrap or interpret another program.
    public static let refusedCommands = ["npx", "npm", "pnpm", "pnpx", "yarn", "yarnpkg", "corepack", "bun", "bunx", "deno", "node", "nodejs", "uv", "uvx", "pip", "pip3", "pipx", "poetry", "conda", "mamba", "micromamba", "pixi", "nix", "go", "cargo", "docker", "podman", "nerdctl", "env", "sudo", "doas", "sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh", "python", "python3", "ruby", "perl", "php", "java", "osascript", "xargs"]
    /// The interpreters with their version in their name, which no `command` server may run either (`MCP_RUNNER`).
    public static let refusedCommandPattern = "(?:python|pypy)[0-9.]*|node[0-9.]*|ruby[0-9.]*|perl[0-9.]*|php[0-9.]*"
    /// The endings of a host of this machine or of a private network, which no remote of Find a server may have
    /// (`hub.mcp_registry_remote`).
    public static let privateHostEndings = [".local", ".localhost", ".localdomain", ".internal", ".lan", ".home.arpa", ".intranet", ".corp"]
    /// The name of a program (`MCP_PROGRAM`): a `command`, and the program of a package.
    public static let program = "[A-Za-z0-9][A-Za-z0-9._-]{0,63}"
    /// A package of npm (`NPM_PACKAGE`).
    public static let npmName = "(?:@[a-z0-9][a-z0-9._~-]{0,99}/)?[a-z0-9][a-z0-9._~-]{0,99}"
    /// A package of PyPI (`PYPI_PACKAGE`).
    public static let pypiName = "[A-Za-z0-9](?:[A-Za-z0-9._-]{0,98}[A-Za-z0-9])?"
    /// One exact version (`PACKAGE_VERSION`).
    public static let version = "[0-9][0-9A-Za-z.+!_-]{0,63}"
    /// The day of a package's dependencies, in UTC (`PACKAGE_DAY`).
    public static let day = "20[0-9]{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])"
    /// The words of Find a server (`MCP_FIND_WORDS`), after their white space at both ends goes.
    public static let findWords = "[A-Za-z0-9][A-Za-z0-9 ._@/-]{0,59}"
    /// The most plain settings of one program server (`MCP_SETTINGS_MOST`).
    public static let settingsMost = 16
    /// The most characters of one plain value (`MCP_SETTING_MOST`).
    public static let valueMost = 500
    /// The most keys of one program server (its `env`).
    public static let keysMost = 8
    /// The most arguments of one package server (`MCP_ARGS_MOST`).
    public static let argsMost = 16
    /// The most characters of one argument (`MCP_ARG_MOST`).
    public static let argMost = 300
}

/// The registry of a program server's package (owner feature `mcp_packages`, UI-API.md 1.187): the helper of each
/// agent's server installs the package from there, as the agent's own OS user.
public enum MCPRegistry: String, CaseIterable, Sendable {
    case npm, pypi

    /// Its own name, which is the same in every language.
    public var title: String { self == .npm ? "npm" : "PyPI" }

    /// The line that runs one of its packages, as servers publish it: what a pick of Find a server writes in the
    /// Program line.
    public func line(_ package: String) -> String { self == .npm ? "npx -y \(package)" : "uvx \(package)" }

    /// A package's name as this registry writes it and the hub takes it: npm's lower-case form with an optional
    /// `@scope/`, PyPI's form.
    public func takes(_ name: String) -> Bool { MCP.whole(name, self == .npm ? MCPRules.npmName : MCPRules.pypiName) }
}

/// A package that the Program line names (`npx -y notes-mcp@1.2.0`, `uvx mcp-server-odoo`): the hub's lookup gives the
/// version that a server may take now (`POST /ui/mcp/package`).
public struct MCPPackageRef: Hashable, Sendable {
    public let registry: MCPRegistry
    public let name: String
    /// The version that the line names; nil takes the newest one that is at least 7 days old.
    public let version: String?
    /// The program of the package to run (`uvx --from <package> <program>`, `npx -p <package> <program>`); nil runs
    /// the package's own.
    public let bin: String?

    public init(registry: MCPRegistry, name: String, version: String? = nil, bin: String? = nil) {
        self.registry = registry; self.name = name; self.version = version; self.bin = bin
    }

    /// One lookup's key: the same package and version ask once.
    public var key: String { "\(registry.rawValue)/\(name)/\(version ?? "")" }
}

/// What the Program line of the form runs: a program that the machine has, which takes no argument, or a package that
/// the agent's helper installs, with its arguments.
public enum MCPProgramLine: Equatable, Sendable {
    case command(program: String)
    case package(MCPPackageRef, args: [String])

    public var args: [String] {
        switch self {
        case .command: []
        case .package(_, let args): args
        }
    }
}

/// Why the form does not take a Program line, in the words of its message line: only for the lines that a person
/// writes with the best of reasons. A line that is only written wrong says nothing but its field's orange edge.
public enum MCPLineRefusal: Equatable, Sendable {
    /// A Docker or Podman image.
    case image
    /// A program that installs, fetches or runs other code by itself, or a program of the machine with arguments:
    /// only a package of npm or PyPI takes them, and its line begins with npx or uvx.
    case runner
    /// A key in the line, after this flag (`--token sk-…`): a key goes in a row of its own, never in `team.json`.
    case flag(String)

    public var words: String {
        switch self {
        case .image: String(l10n: "Founderizer runs no Docker image: use the server's npm or PyPI package.")
        case .runner: String(l10n: "Founderizer installs npm and PyPI programs itself: write the line with npx or uvx.")
        case .flag(let flag): String(l10n: "The key after \(flag) goes in a row of its own, never in the line.")
        }
    }
}

/// One variable of a program server in the form (UI-API.md 1.187): a plain setting that `team.json` keeps, or a key,
/// whose value goes into the central vault as an API key of the Secrets page and which `env` maps to that key.
public struct MCPVariable: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The program's own variable.
    public var name: String
    /// A setting's value, or the key itself. A key is in this form's memory only, until Add puts it into the vault.
    public var value: String
    /// The server's own variable, from a pick or a paste: its name is the row's label. false: a row that the owner
    /// added, or one that a pasted flag of a key made, whose name he types.
    public let named: Bool
    /// The registry marks it secret, or the paste gave it the name of a secret.
    public let secret: Bool
    /// The registry's words about it, for the hover.
    public let about: String

    public init(name: String, value: String = "", named: Bool = true, secret: Bool = false, about: String = "") {
        id = UUID(); self.name = name; self.value = value; self.named = named; self.secret = secret; self.about = about
    }

    /// Its value is a key: a secure field, and the vault. **One rule for every row** (`MCP.isSecretName`): a row
    /// whose name the rule calls a key's is a key row, also a row of a pick and a row that he added.
    public var isKey: Bool { secret || MCP.isSecretName(name) }
}

/// One key of the form that Add puts into the vault: a key row with a value, or a remote server's key.
public struct MCPKeyValue: Equatable, Sendable {
    public let id: UUID
    /// The program's own variable; `MCP.remoteKey` for a remote server's key.
    public let name: String
    public let value: String
}

/// The package of a program server, as `team.json` keeps it (`lifecycle.mcp_package`): the version and the day that
/// the hub's lookup gave.
public struct MCPPackageSpec: Equatable, Sendable {
    public let registry: MCPRegistry
    public let name: String
    public let version: String
    /// The day (UTC) as of which every dependency is taken, at least 7 days back.
    public let asOf: String
    public let bin: String?

    public init(registry: MCPRegistry, name: String, version: String, asOf: String, bin: String? = nil) {
        self.registry = registry; self.name = name; self.version = version; self.asOf = asOf; self.bin = bin
    }

    var object: [String: String] {
        var object = ["registry": registry.rawValue, "name": name, "version": version, "as_of": asOf]
        if let bin { object["bin"] = bin }
        return object
    }
}

/// One owner MCP server, as the hub takes it in `POST /ui/team/mcp`. It holds no secret: a `key` server names the
/// variable of an API key of the Secrets page, and a program's `env` the variables of such keys, never their values.
public struct MCPServerSpec: Equatable, Sendable {
    public let title: String
    /// A remote server's address; nil for a program.
    public let url: String?
    /// A program of the machine; nil for a package and for a remote server.
    public let command: String?
    /// A program that the agent's helper installs (`mcp_packages`).
    public let package: MCPPackageSpec?
    /// A package's arguments; a program of the machine takes none.
    public let args: [String]
    /// A program's plain settings, {its own variable: the value}.
    public let settings: [String: String]
    public let auth: MCPAuth
    /// For a url server with `auth` `key`: the variable name of the API key. Add gives it once the key is in the vault.
    public var key: String?
    /// For a program: {its own variable: the variable name of an API key}. Add gives it once each key is in the vault.
    public var env: [String: String]

    public init(title: String, url: String? = nil, command: String? = nil, package: MCPPackageSpec? = nil,
                args: [String] = [], settings: [String: String] = [:], auth: MCPAuth = .none, key: String? = nil,
                env: [String: String] = [:]) {
        self.title = title; self.url = url; self.command = command; self.package = package; self.args = args
        self.settings = settings; self.auth = auth; self.key = key; self.env = env
    }

    /// The `server` object of the write. `args` and `settings` go only where they have something, so a program server
    /// without them is one that a hub without `mcp_packages` takes (`MCPDraft.server(features:resolved:)`).
    public var object: [String: Any] {
        var object: [String: Any] = ["title": title]
        if let url {
            object["url"] = url
            if auth != .none { object["auth"] = auth.rawValue }
            if let key, auth == .key { object["key"] = key }
        } else {
            if let package { object["package"] = package.object } else { object["command"] = command ?? "" }
            if !args.isEmpty { object["args"] = args }
            if !settings.isEmpty { object["settings"] = settings }
            if !env.isEmpty { object["env"] = env }
        }
        return object
    }
}

/// One owner MCP server as the owner writes it in the form, and the server that the hub takes.
public struct MCPDraft: Equatable, Sendable {
    public var title: String = ""
    public var kind: MCPKind = .remote
    /// For `remote`: the server's address.
    public var address: String = ""
    /// For `local`: the Program line, a program of the machine or a package with the program that runs it
    /// (`notes-mcp`, `uvx mcp-server-odoo`, `npx -y notes-mcp /srv/notes`).
    public var command: String = ""
    /// For `remote`: how it signs in.
    public var auth: MCPAuth = .oauth
    /// For `remote` with `auth` `key`: the key itself, in its secure field. It is in this form's memory only, until
    /// Add puts it into the central vault as the API key `<SERVER>_KEY`.
    public var remoteKey: String = ""
    /// The remote key's own id, for the vault step that Add makes of it once (`MCPKeyValue`).
    public let remoteKeyID = UUID()
    /// For `local`: its settings and its keys, in the form's order.
    public var variables: [MCPVariable] = []
    /// The form came from a pick of Find a server: a remote one that the hub's Connect finds no OAuth for is a server
    /// with no sign-in, and Add saves it so.
    public private(set) var picked = false

    public init() {}

    /// The form after a pick of Find a server: a remote server with its address and how it signs in, or a program
    /// with its package, the fixed values of its required arguments after it, and a row for each of its settings and
    /// keys. A setting whose name is a key's is a key row, whose default is no key.
    public init(found: MCPFound) {
        title = found.title
        picked = true
        if found.kind == "remote" {
            kind = .remote
            address = found.url ?? ""
            auth = found.auth == "key" ? .key : .oauth
        } else {
            kind = .local
            auth = .none
            if let package = found.package, let registry = MCPRegistry(rawValue: package.registry) {
                command = ([registry.line(package.name)] + (found.args ?? [])).joined(separator: " ")
            }
            let settings = (found.settings ?? []).compactMap { setting in
                MCP.settingName(setting.name).map { name in
                    MCPVariable(name: name, value: MCP.isSecretName(name) ? ""
                                    : setting.default.flatMap { MCP.plainValue($0) ? $0 : nil } ?? "",
                                about: setting.description ?? "")
                }
            }
            let keys = (found.keys ?? []).compactMap { key in
                MCP.settingName(key.name).map { MCPVariable(name: $0, secret: true, about: key.description ?? "") }
            }
            variables = settings + keys
        }
    }

    /// What the Program line runs; nil for a remote server and for a line that the form does not take.
    public var line: MCPProgramLine? { kind == .local ? MCP.line(command) : nil }

    /// The package that the Program line names, for the hub's lookup; nil for any other line.
    public var package: MCPPackageRef? {
        if case .package(let package, _) = line { return package }
        return nil
    }

    /// Why the form does not take its Program line, for its message line; nil while it takes it, and for a line that is
    /// only written wrong.
    public var refusal: MCPLineRefusal? { kind == .local ? MCP.refusal(line: command) : nil }

    /// The server for `POST /ui/team/mcp`, or nil while the form is not one that this hub takes. A program's `env` and a
    /// remote server's `key` are empty here: Add gives them once each key is in the vault (`keyValues`). `resolved`: the
    /// hub's lookup of the package that the line names. **Arguments, settings and packages go only to a hub with
    /// `mcp_packages`**, which refuses none of them; a hub without it refuses every server that has one, so the form
    /// stays off there, as it does for a key whose variable has no key's ending, which such a hub refuses too.
    public func server(features: [String], resolved: MCPPackageVersion? = nil) -> MCPServerSpec? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.count), !name.contains("\n") else { return nil }
        switch kind {
        case .remote:
            guard let url = MCP.address(address) else { return nil }
            if auth == .key { guard MCP.isKeyValue(remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil } }
            return MCPServerSpec(title: name, url: url, auth: auth)
        case .local:
            guard let line, let parts = rows() else { return nil }
            let packages = features.contains(MCP.packagesFeature)
            guard packages || (line.args.isEmpty && parts.settings.isEmpty
                               && parts.keys.allSatisfy({ MCP.keyVariable($0.name) == $0.name })) else { return nil }
            switch line {
            case .command(let program):
                return MCPServerSpec(title: name, command: program, settings: parts.settings)
            case .package(let package, let args):
                guard packages, let spec = resolved?.spec(for: package) else { return nil }
                return MCPServerSpec(title: name, package: spec, args: args, settings: parts.settings)
            }
        }
    }

    /// The keys that Add puts into the vault: each key row with a value, or a remote server's key. Empty while a row is
    /// one the hub refuses.
    public var keyValues: [MCPKeyValue] {
        switch kind {
        case .local: return rows()?.keys ?? []
        case .remote:
            let key = remoteKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return auth == .key && MCP.isKeyValue(key) ? [MCPKeyValue(id: remoteKeyID, name: MCP.remoteKey, value: key)] : []
        }
    }

    /// The settings to send and the keys to put into the vault, or nil while a row is one that the hub refuses: a name
    /// that no program may have, a name twice, a value with `$` or a control character, a key that the vault refuses,
    /// or more of them than the hub takes. A row with no value is not sent, and a row that he added and left empty
    /// counts for nothing.
    private func rows() -> (settings: [String: String], keys: [MCPKeyValue])? {
        var settings: [String: String] = [:], keys: [MCPKeyValue] = [], names = Set<String>()
        for row in variables {
            let own = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !row.named && own.isEmpty && value.isEmpty { continue }
            guard MCP.settingName(own) != nil, names.insert(own).inserted else { return nil }
            if value.isEmpty { continue }
            if row.isKey {
                guard MCP.isKeyValue(value) else { return nil }
                keys.append(MCPKeyValue(id: row.id, name: own, value: value))
            } else {
                guard MCP.plainValue(value) else { return nil }
                settings[own] = value
            }
        }
        guard settings.count <= MCPRules.settingsMost, keys.count <= MCPRules.keysMost else { return nil }
        return (settings, keys)
    }

    /// The name that the hub will keep this server under, from the title; nil while the title gives none.
    public var name: String? { MCP.name(from: title) }
    /// True while the form is complete enough to send.
    public func isComplete(features: [String], resolved: MCPPackageVersion? = nil) -> Bool {
        server(features: features, resolved: resolved) != nil && name != nil
    }
    /// How a remote server can sign in. A program has no sign-in of its own: its keys are rows of their own.
    public var choices: [MCPAuth] { MCPAuth.allCases }

    /// "+ Add a setting": one empty row, whose name and value the owner types.
    public mutating func addSetting() { variables.append(MCPVariable(name: "", named: false)) }
}

/// The hub's answer of `POST /ui/mcp/package`: the version of a package that a server may take now, and the day as of
/// which its dependencies are taken.
public struct MCPPackageVersion: Decodable, Equatable, Sendable {
    public let registry: String
    public let name: String
    public let version: String
    public let as_of: String
    /// The day it was published.
    public let published: String?
    /// The registry's newest release, which can be younger than 7 days.
    public let newest: String?
    /// The programs of that npm version; empty for PyPI.
    public let bins: [String]?

    public init(registry: String, name: String, version: String, as_of: String, published: String? = nil,
                newest: String? = nil, bins: [String]? = nil) {
        self.registry = registry; self.name = name; self.version = version; self.as_of = as_of
        self.published = published; self.newest = newest; self.bins = bins
    }

    /// The package of the server for the line's package: the version that the hub gave, when it answers this very
    /// package (and the version that the line names, if it names one).
    public func spec(for package: MCPPackageRef) -> MCPPackageSpec? {
        guard registry == package.registry.rawValue, name == package.name, package.version.map({ $0 == version }) ?? true,
              MCP.version(version) != nil, MCP.whole(as_of, MCPRules.day)
        else { return nil }
        return MCPPackageSpec(registry: package.registry, name: name, version: version, asOf: as_of, bin: package.bin)
    }

    /// The version beside the Program line, with its registry: "0.9.0 · PyPI".
    public var words: String { "\(version) · \(MCPRegistry(rawValue: registry)?.title ?? registry)" }
}

/// **A server's keys go with it** (the owner, 15 November 2026: "Yes, give the keys too", whose option said: "The app
/// signs a \"Reads it\" grant for each key that the server names, when it gives the server. Taking the server back
/// takes those grants back only where no other server of the agent needs them."). The rule is here, and the app signs
/// and writes what it gives (`MCPKeyGrants`).
public enum MCPServerKeys {
    /// The keys of the Secrets page that a server of the owner needs in a session: its `needs`, without Fleet's own
    /// variables (`FLEET_MCP_*`, the token that the hub's Connect gives). Fleet's own tools need none of them: the
    /// GitHub tool's `GH_TOKEN` is Fleet's, and no key of the Secrets page ever goes with it.
    public static func variables(of tool: IntegrationsSnapshot.Tool?) -> [String] {
        guard let tool, tool.isCustom else { return [] }
        return (tool.needs ?? []).filter { !$0.hasPrefix("FLEET_") }
    }

    /// The API key of the fleet that has this variable, by its reference: one at most, because the catalog takes no
    /// second key of one name.
    public static func login(of variable: String, in logins: [String: TeamLogin]) -> String? {
        logins.filter { $0.value.isAPIKey && $0.value.env == variable }.keys.sorted().first
    }

    /// The grants of one give or take of `server` for `agent`. **Giving**: `read` for each of its keys of which the
    /// agent holds no grant at all; a key that it uses or reads already stays as it is. **Taking it back**: the end of
    /// the grant of each key that the form made for this very server (`MCP.isFormKey`), only where the agent reads it
    /// and no other server of the owner that it still has (`agentTools`, after the change) needs it. A key that the
    /// owner named himself on the Secrets page is never taken back, and a key that the fleet does not hold is left out.
    public static func grants(server: String, agent: String, giving: Bool, tools: [String: IntegrationsSnapshot.Tool],
                              agentTools: [String], logins: [String: TeamLogin]) -> [(login: String, grant: SecretGrant?)] {
        let others = Set(agentTools.filter { $0 != server }.flatMap { variables(of: tools[$0]) })
        return variables(of: tools[server]).compactMap { variable in
            guard let login = login(of: variable, in: logins) else { return nil }
            let held = logins[login]?.grants?[agent]
            if giving { return held == nil ? (login, .read) : nil }
            return held == SecretGrant.read.rawValue && !others.contains(variable) && MCP.isFormKey(variable, of: server)
                ? (login, nil) : nil
        }
    }
}

/// One server of the official MCP Registry that Fleet can run, as `POST /ui/mcp/find` gives it (`mcp_find`). Anybody
/// can publish to that registry: its words are data, and its row names who published it.
public struct MCPFound: Decodable, Identifiable, Equatable, Sendable {
    public struct Variable: Decodable, Equatable, Sendable {
        public let name: String
        public let description: String?
        public let required: Bool?
        public let `default`: String?
    }
    public struct Package: Decodable, Equatable, Sendable {
        public let registry: String
        public let name: String
        public let version: String?
    }
    public let id: String
    public let title: String
    /// The host of its site or repository, else its name's namespace.
    public let publisher: String?
    public let description: String?
    public let version: String?
    /// `remote` or `program`.
    public let kind: String
    public let url: String?
    /// A remote server's: `oauth` or `key`.
    public let auth: String?
    /// A remote server's transport (`streamable-http`, `sse`), where the hub names it, as `transport` or as `type`.
    public let transport: String?
    public let type: String?
    public let package: Package?
    public let settings: [Variable]?
    public let keys: [Variable]?
    /// A program's required arguments, with their fixed values, which a pick writes after its package.
    public let args: [String]?

    public var isProgram: Bool { kind == "program" }

    /// Its muted line in the list: "acme.example · PyPI · What it does".
    public var line: String {
        let place = isProgram ? package.flatMap { MCPRegistry(rawValue: $0.registry)?.title } : String(l10n: "remote")
        return [publisher, place, description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A server that the form can take: a package of npm or PyPI, whose fixed arguments are words of its Program line,
    /// or **a remote server that the hub's Connect and its check can speak to**: streamable HTTP, at an `https` address
    /// of a name in the public DNS (`MCP.isPublicHost`).
    var isUsable: Bool {
        guard !title.isEmpty else { return false }
        if kind == "remote" {
            guard let url, MCP.address(url) == url, let parts = URLComponents(string: url), parts.scheme == "https",
                  let host = parts.host, MCP.isPublicHost(host) else { return false }
            return (transport ?? type).map { $0 == "streamable-http" } ?? true
        }
        guard isProgram, let package, let registry = MCPRegistry(rawValue: package.registry),
              (args ?? []).count <= MCPRules.argsMost, (args ?? []).allSatisfy(MCP.argument) else { return false }
        return registry.takes(package.name)
    }
}

/// The servers of one search. A server that this app cannot read, or cannot run, is left out, and the others stay.
public struct MCPFindings: Decodable, Sendable {
    public let servers: [MCPFound]
    public let more: Bool

    private enum Keys: String, CodingKey { case servers, more }
    private struct Lossy: Decodable {
        let found: MCPFound?
        init(from decoder: Decoder) throws { found = try? MCPFound(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        servers = try container.decode([Lossy].self, forKey: .servers).compactMap(\.found).filter(\.isUsable)
        more = (try? container.decode(Bool.self, forKey: .more)) ?? false
    }
}

/// Why the owner must sign one of his servers in again (the owner's "Yes, all three", 15 November 2026; UI-API.md 1.187,
/// "When an access ends").
public enum MCPSignIn: Equatable, Sendable {
    /// Its access ended for good, with the hub's words of it where it gave some.
    case ended(String?)
    /// It has no connection.
    case notConnected
    /// Its access cannot renew and ends at this time (seconds since 1970), within 14 days.
    case ends(Double)
}

extension IntegrationsSnapshot.Tool {
    /// How long before an access that cannot renew ends its row asks for a new sign-in (`hub.MCP_RENEW_SOON`).
    public static let renewal: Double = 14 * 86_400

    /// Why this server needs a new sign-in at the hub's time `now`, or nil: only an owner's server that signs in with the
    /// hub's Connect (`auth` `oauth`) can need one. **A hub that says `ended`** asks for one only at a definite end of the
    /// access, with no connection, or in the 14 days before an access that cannot renew ends: any other `problem` is an
    /// outage, which a new sign-in does not help. A hub from before it asks for one at any `problem`. Without the hub's
    /// time an end to come says nothing.
    public func signIn(at now: Double?) -> MCPSignIn? {
        guard isCustom, kind == .oauth else { return nil }
        let said = problem.flatMap { $0.isEmpty ? nil : $0 }
        if let ended {
            if ended { return .ended(said) }
        } else if let said {
            return .ended(said)
        }
        if connected != true { return .notConnected }
        if let ends = access_ends, let now, ends - now <= Self.renewal { return .ends(ends) }
        return nil
    }
}

public enum MCP {
    public static let feature = "mcp"
    /// Program servers with arguments, plain settings and packages, and `POST /ui/mcp/package` (UI-API.md 1.187).
    public static let packagesFeature = "mcp_packages"
    /// Find a server: `POST /ui/mcp/find`.
    public static let findFeature = "mcp_find"
    /// The name of a remote server's key among the keys of the form (`MCPKeyValue`): its variable is `<SERVER>_KEY`.
    public static let remoteKey = "KEY"

    /// A server's own published configuration, as the owner copies it from that server's page, turned into the form.
    /// Every shape in use is one object for the server, under `mcpServers` or `servers` or on its own:
    ///
    ///     {"mcpServers": {"notes": {"command": "npx", "args": ["-y", "notes-mcp"], "env": {"NOTES_TOKEN": "sk-…"}}}}
    ///     {"crm": {"url": "https://mcp.example.com/"}}
    ///
    /// **A key in the pasted text is never kept.** An `env` entry is a plain setting with its value only when it is
    /// plainly no secret (`isSecretName`, `holdsCredentials`); every other one is a key row with no value, which the
    /// owner fills in its secure field. A flag of a key goes out of the line with its value (`--token sk-…`,
    /// `--api-key=sk-…`), and a key row named after it takes its place. A pasted token is dropped on the floor here.
    public static func read(snippet: String) -> MCPDraft? {
        for entry in entries(of: snippet) {
            if let draft = server(entry.value, named: entry.name) { return draft }
        }
        return nil
    }

    /// Why a pasted configuration that the form does not take is no server for Founderizer, for the message line: a
    /// Docker image, or a program that installs or runs code by itself. nil for any other text.
    public static func refusal(snippet: String) -> MCPLineRefusal? {
        for entry in entries(of: snippet) {
            guard let command = entry.value["command"] as? String else { continue }
            let args = withoutKeys((entry.value["args"] as? [Any] ?? []).compactMap { $0 as? String }).args
            if let refused = refusal(line: ([command] + args).joined(separator: " ")) { return refused }
        }
        return nil
    }

    /// The servers of a pasted snippet, in the order that they are tried: under `mcpServers` or `servers`, the object
    /// itself, then each of its entries.
    private static func entries(of snippet: String) -> [(name: String?, value: [String: Any])] {
        guard let data = snippet.data(using: .utf8), data.count <= 64_000,
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var found: [(name: String?, value: [String: Any])] = []
        for wrapper in ["mcpServers", "servers"] {
            if let inner = top[wrapper] as? [String: Any] { found += each(of: inner) }
        }
        found.append((top["name"] as? String, top))
        return found + each(of: top)
    }

    private static func each(of servers: [String: Any]) -> [(name: String?, value: [String: Any])] {
        servers.keys.sorted().compactMap { key -> (name: String?, value: [String: Any])? in
            guard let value = servers[key] as? [String: Any] else { return nil }
            return (key, value)
        }
    }

    private static func server(_ entry: [String: Any], named: String?) -> MCPDraft? {
        var draft = MCPDraft()
        draft.title = (entry["title"] as? String ?? entry["name"] as? String ?? named ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = entry["url"] as? String ?? entry["endpoint"] as? String {
            guard address(url) != nil else { return nil }
            draft.kind = .remote
            draft.address = url
            // What it signs in with is the owner's to say: a snippet cannot prove it, and a wrong guess would
            // either ask him for a key he does not need or skip one he does.
            draft.auth = .oauth
        } else if let command = entry["command"] as? String {
            // Each flag of a key goes with its value, and a key row takes its place. What is left is a line that the form
            // takes, or a program of the machine with arguments, which fills the form and keeps Add off (`refusal` says
            // why). An image or another program that installs or runs code is no paste at all (`refusal(snippet:)`).
            let pasted = withoutKeys((entry["args"] as? [Any] ?? []).compactMap { $0 as? String })
            let kept = ([command] + pasted.args).joined(separator: " ")
            guard line(kept) != nil || (program(kept) != nil && !refusedCommand(command)) else { return nil }
            draft.kind = .local
            draft.command = kept
            draft.auth = .none
            draft.variables = variables(pasted: entry["env"] as? [String: Any] ?? [:])
            for flag in pasted.flags {
                let name = flag.drop { $0 == "-" }.uppercased().replacingOccurrences(of: "-", with: "_")
                if settingName(name) != nil, !draft.variables.contains(where: { $0.name == name }) {
                    draft.variables.append(MCPVariable(name: name, named: false, secret: true))
                }
            }
        } else {
            return nil
        }
        return draft.title.isEmpty ? nil : draft
    }

    /// The rows of a pasted `env`: the plain settings first, then the keys, each by its name. A name that no program
    /// server may have is left out; a key's value, and a plain value that the hub would refuse, stay empty.
    static func variables(pasted env: [String: Any]) -> [MCPVariable] {
        var settings: [MCPVariable] = [], keys: [MCPVariable] = []
        for name in env.keys.sorted() {
            guard settingName(name) != nil else { continue }
            let value = env[name] as? String ?? ""
            if isSecretName(name) || holdsCredentials(value) {
                keys.append(MCPVariable(name: name, secret: true))
            } else {
                settings.append(MCPVariable(name: name, value: plainValue(value) ? value : ""))
            }
        }
        return settings + keys
    }

    /// A pasted line's arguments without each flag of a key and its value (`--token sk-…`, `--token=sk-…`), and those
    /// flags, for the key rows that take their place. A value that begins with `-` is the next flag, and stays.
    static func withoutKeys(_ args: [String]) -> (args: [String], flags: [String]) {
        var kept: [String] = [], flags: [String] = [], skip = false
        for (index, arg) in args.enumerated() {
            if skip { skip = false; continue }
            let flag = String(arg.prefix { $0 != "=" })
            guard isSecretFlag(flag) else { kept.append(arg); continue }
            if !flags.contains(flag) { flags.append(flag) }
            skip = !arg.contains("=") && index + 1 < args.count && !args[index + 1].hasPrefix("-")
        }
        return (kept, flags)
    }

    /// A flag that takes a secret (`lifecycle.secret_flag`): a flag (`MCPRules.flag`) with one of `MCPRules.secretWords`
    /// among its words between `-` and `_`, in capitals: `--token`, `--api-key`, `--auth`, `--key-file`, `--bearer`.
    public static func isSecretFlag(_ flag: String) -> Bool {
        whole(flag, MCPRules.flag) && flagWords(flag).contains { MCPRules.secretWords.contains($0) }
    }

    /// The words of a flag's name, in capitals (`lifecycle.flag_words`): split at `-` and `_`, and where a lower case
    /// letter or a digit meets a capital, so `--accessToken` gives ACCESS and TOKEN as `--access-token` does.
    public static func flagWords(_ flag: String) -> [String] {
        var words: [String] = [], word = "", last: Character?
        for character in flag {
            if character == "-" || character == "_" {
                if !word.isEmpty { words.append(word.uppercased()) }
                word = ""
            } else {
                if character.isUppercase, let last, last.isLowercase || last.isNumber, !word.isEmpty {
                    words.append(word.uppercased())
                    word = ""
                }
                word.append(character)
            }
            last = character
        }
        if !word.isEmpty { words.append(word.uppercased()) }
        return words
    }

    /// **The first flag of a line with a key after it**, as the hub refuses it (`lifecycle.mcp_server`): a flag that
    /// takes a secret with its value after `=` or as the next argument. Only the flag, never what follows it, so no
    /// value ever reaches a message. A flag with no value is no key.
    public static func secretFlag(in args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let flag = String(parts[0]), given = parts.count > 1
            let value = given && !parts[1].isEmpty
            guard isSecretFlag(flag), value || index + 1 < args.count && !args[index + 1].hasPrefix("-") else { continue }
            return flag
        }
        return nil
    }

    /// The hub's name for a server, from its title: lower case, `a-z 0-9 -`, 1 to 31 characters, starting with a
    /// letter. nil when the title gives no such name.
    public static func name(from title: String) -> String? {
        var text = ""
        for character in title.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                text.append(character)
            } else if !text.isEmpty && !text.hasSuffix("-") {
                text.append("-")
            }
        }
        while text.hasSuffix("-") { text.removeLast() }
        while let first = text.first, !first.isLetter { text.removeFirst() }
        text = String(text.prefix(31))
        while text.hasSuffix("-") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// One server address as the hub takes it: `https` anywhere, `http` on `127.0.0.1` or `localhost`, with a host, no
    /// user part and no `#fragment`, at most 300 characters. A pasted address without a scheme gets `https://`.
    public static func address(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        if !value.contains("://") { value = "https://" + value }
        // The hub refuses a text that a session would replace with its own variable (`lifecycle.MCP_EXPANDS`)
        guard !["${", "{env:", "{file:"].contains(where: { value.contains($0) }),
              value.count <= 300, let parts = URLComponents(string: value), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && (host == "127.0.0.1" || host == "localhost"))
        else { return nil }
        return value
    }

    /// **A host name of the public DNS** (`hub.mcp_public_name`), read as the hub reads it: without its brackets and its
    /// trailing dots, in lower case. With a dot; no address in any form, which a resolver takes as an address (dotted,
    /// IPv6 with or without brackets, a name whose labels are all numbers or `0x` numbers: `0x7f.1`); not `localhost`;
    /// and no ending of a private network (`MCPRules.privateHostEndings`).
    static func isPublicHost(_ host: String) -> Bool {
        var name = Substring(host)
        while let first = name.first, first == "[" || first == "]" { name = name.dropFirst() }
        while let last = name.last, last == "[" || last == "]" { name = name.dropLast() }
        while name.hasSuffix(".") { name = name.dropLast() }
        let text = name.lowercased()
        let labels = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !text.contains(":"), labels.count >= 2, text != "localhost",
              !MCPRules.privateHostEndings.contains(where: text.hasSuffix) else { return false }
        return !labels.allSatisfy { whole($0, "0x[0-9a-f]*|[0-9]+") }
    }

    /// One program line of the machine split into its words: the name of a program (1 to 64 characters
    /// `A-Z a-z 0-9 . _ -`) and up to 16 arguments (`argument`). It is no shell line. The form takes a program with no
    /// argument only (`line`).
    public static func program(_ text: String) -> (program: String, args: [String])? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first, words.count <= MCPRules.argsMost + 1, whole(program, MCPRules.program),
              words.dropFirst().allSatisfy(argument)
        else { return nil }
        return (program, Array(words.dropFirst()))
    }

    /// One argument: 1 to 300 visible ASCII characters, none of which a shell reads (`"'|;&$` and the backquote, `<>`),
    /// so a line that looks like a shell line is never taken for one, and no text that a session would replace
    /// (`replaced`). The hub takes more (`lifecycle.plain_value`).
    static func argument(_ text: String) -> Bool {
        (1...MCPRules.argMost).contains(text.unicodeScalars.count)
            && text.unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
            && !text.contains(where: { "\"'|;&$`<>".contains($0) }) && !replaced(text)
    }

    /// A text of `{env:...}` or `{file:...}`, which OpenCode replaces with a variable or a file of the session: the hub
    /// refuses it in a setting and an argument (`lifecycle.MCP_EXPANDS`), and `$` is refused there already.
    static func replaced(_ text: String) -> Bool { text.contains("{env:") || text.contains("{file:") }

    /// **What the Program line runs** (UI-API.md 1.187): a package with the program that servers publish to run it —
    /// `npx [-y] <package>[@<version>]` or `npx [-y] -p <package> <program>`, and `bunx` and `pnpm dlx` the same, for
    /// npm; `uvx <package>[==<version>]`, `uvx --from <package> <program>` and `pipx run <package>` for PyPI — with the
    /// arguments after it, or a program of the machine with none. nil for a line that the form does not take: one that
    /// no hub takes, a program of `MCPRules.refusedCommands` (they fetch or run other code, which would go round the
    /// owner's rule that the helper installs no version newer than 7 days and runs no install script), a program of
    /// the machine with arguments, and a line with a flag of a key (`refusal` says why).
    public static func line(_ text: String) -> MCPProgramLine? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        let rest = Array(words.dropFirst())
        switch first {
        case "npx", "bunx": return npm(rest)
        case "pnpm": return rest.first == "dlx" ? npm(Array(rest.dropFirst())) : nil
        case "uvx": return uvx(rest)
        case "pipx": return rest.first == "run" ? pypi(Array(rest.dropFirst()), bin: nil) : nil
        default:
            guard rest.isEmpty, !refusedCommand(first), let program = program(text) else { return nil }
            return .command(program: program.program)
        }
    }

    /// **Why the form does not take a Program line** (`line`), for its message line: a flag of a key in it, an image, or
    /// a program that installs or runs other code, or that takes arguments as a program of the machine. nil for a line
    /// that the form takes, and for one that is only written wrong, which its field's orange edge says.
    public static func refusal(line text: String) -> MCPLineRefusal? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first?.lowercased() else { return nil }
        if let flag = secretFlag(in: Array(words.dropFirst())) { return .flag(flag) }
        if ["docker", "podman", "nerdctl"].contains(first) { return .image }
        guard line(text) == nil else { return nil }
        switch first {
        case "npx", "bunx", "uvx": return nil
        case "pnpm": if words.dropFirst().first == "dlx" { return nil }
        case "pipx": if words.dropFirst().first == "run" { return nil }
        default: break
        }
        if refusedCommand(first) { return .runner }
        // A program of the machine with arguments: only a package takes them.
        return words.count > 1 && program(text) != nil ? .runner : nil
    }

    /// A program that no `command` server may run (`MCPRules.refusedCommands`, `refusedCommandPattern`), in any case:
    /// a Mac's disk finds `NPX` as `npx`.
    public static func refusedCommand(_ program: String) -> Bool {
        let name = program.lowercased()
        return MCPRules.refusedCommands.contains(name) || whole(name, MCPRules.refusedCommandPattern)
    }

    private static func npm(_ words: [String]) -> MCPProgramLine? {
        var rest = words[...], named: String?
        while let flag = rest.first, flag.hasPrefix("-") {
            rest = rest.dropFirst()
            if flag == "-y" || flag == "--yes" { continue }
            if (flag == "-p" || flag == "--package"), named == nil, let given = rest.first {
                named = given
                rest = rest.dropFirst()
                continue
            }
            if flag.hasPrefix("--package="), named == nil {
                named = String(flag.dropFirst("--package=".count))
                continue
            }
            return nil
        }
        // `-p <package> <program>`: the program of the package to run comes after it.
        var bin: String?
        if named != nil {
            guard let program = rest.first, whole(program, MCPRules.program) else { return nil }
            bin = program
            rest = rest.dropFirst()
        }
        guard let spec = named ?? rest.first else { return nil }
        if named == nil { rest = rest.dropFirst() }
        var name = spec, version: String?
        // `@scope/name@1.2.3`: the version's `@` is the last one, and never the scope's first character.
        if let at = spec.lastIndex(of: "@"), at != spec.startIndex {
            name = String(spec[..<at])
            guard let given = tag(String(spec[spec.index(after: at)...])) else { return nil }
            version = given.isEmpty ? nil : given
        }
        let args = Array(rest)
        guard MCPRegistry.npm.takes(name), args.count <= MCPRules.argsMost, args.allSatisfy(argument),
              secretFlag(in: args) == nil else { return nil }
        return .package(MCPPackageRef(registry: .npm, name: name, version: version, bin: bin), args: args)
    }

    private static func uvx(_ words: [String]) -> MCPProgramLine? {
        if words.first == "--from" {
            guard words.count >= 3, whole(words[2], MCPRules.program) else { return nil }
            return pypi([words[1]] + words.dropFirst(3), bin: words[2])
        }
        return pypi(words, bin: nil)
    }

    private static func pypi(_ words: [String], bin: String?) -> MCPProgramLine? {
        guard let spec = words.first, !spec.hasPrefix("-") else { return nil }
        var name = spec, version: String?
        if let equals = spec.range(of: "==") {
            name = String(spec[..<equals.lowerBound])
            guard let given = MCP.version(String(spec[equals.upperBound...])) else { return nil }
            version = given
        } else if let at = spec.firstIndex(of: "@") {
            name = String(spec[..<at])
            guard let given = tag(String(spec[spec.index(after: at)...])) else { return nil }
            version = given.isEmpty ? nil : given
        }
        let args = Array(words.dropFirst())
        guard MCPRegistry.pypi.takes(name), args.count <= MCPRules.argsMost, args.allSatisfy(argument),
              secretFlag(in: args) == nil else { return nil }
        return .package(MCPPackageRef(registry: .pypi, name: name, version: version, bin: bin), args: args)
    }

    /// What follows a package's `@`: a version, or `latest`, which is the newest one that the owner's rule allows
    /// (""). nil for any other tag.
    private static func tag(_ text: String) -> String? { text == "latest" ? "" : version(text) }

    /// One exact version as the hub takes it (`MCPRules.version`: npm's semver, PEP 440).
    public static func version(_ text: String) -> String? { whole(text, MCPRules.version) ? text : nil }

    /// The words of Find a server as the hub takes them (`MCPRules.findWords`).
    public static func findWords(_ text: String) -> String? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return whole(words, MCPRules.findWords) ? words : nil
    }

    /// The name of a program server's own variable as the hub takes it for a setting (`lifecycle.setting_name`):
    /// `MCPRules.settingName` and none of `MCPRules.refusedNames`, which change how a runtime starts, what it loads or
    /// where its traffic goes. For the variable of a key the hub also takes a key's name (`lifecycle.key_variable`),
    /// and the form does not.
    public static func settingName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return whole(name, MCPRules.settingName) && !isRefused(name) ? name : nil
    }

    /// One of `MCPRules.refusedNames`, in any case. The name is ASCII (`settingName`), so its capitals are the hub's
    /// IGNORECASE.
    public static func isRefused(_ name: String) -> Bool { whole(name.uppercased(), MCPRules.refusedNames) }

    /// A plain value of a program server as the hub takes it (`lifecycle.plain_value`, `mcp_written`): at most 500
    /// characters, no `$` (Claude Code reads `${NAME}` in its MCP file), no `{env:` or `{file:` (`replaced`), no
    /// character above U+FFFF (Codex's TOML takes no surrogate pair), nothing that Python's `isprintable` refuses,
    /// and no URL with a password in it.
    public static func plainValue(_ value: String) -> Bool {
        value.unicodeScalars.count <= MCPRules.valueMost && !value.contains("$") && !replaced(value)
            && value.unicodeScalars.allSatisfy { $0.value <= 0xFFFF && printable($0) }
            && value.range(of: MCPRules.credentialURL, options: .regularExpression) == nil
    }

    /// Python's `str.isprintable` for one character: no control, format, surrogate, private or unassigned character
    /// and no separator but the space.
    static func printable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
    }

    /// **The one rule of a secret, for every row** (`lifecycle.secret_name`): a name is a key's when it has a key's
    /// ending (`MCPRules.keyEndings`), or a word that is one of `MCPRules.secretWords`, split as a flag's (`flagWords`:
    /// `DB_PASS`, `apiToken`). Its value goes into a secure field and the vault, and never into the settings, which
    /// the hub refuses for such a name too.
    public static func isSecretName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return MCPRules.keyEndings.contains(where: trimmed.uppercased().hasSuffix)
            || !Set(flagWords(trimmed)).isDisjoint(with: MCPRules.secretWords)
    }

    /// A pasted value with a person in it (a `postgres://` address with a user name and a password before its host,
    /// `https://user@acme.example`):
    /// a key, never a setting.
    static func holdsCredentials(_ value: String) -> Bool {
        guard value.contains("://"), let parts = URLComponents(string: value) else { return false }
        return parts.user?.isEmpty == false || parts.password?.isEmpty == false
    }

    /// The name of an API key in a session (`lifecycle.key_env`), in capitals: `MCPRules.keyName`, one of
    /// `MCPRules.keyEndings`, and none of `MCPRules.reservedNames`.
    public static func keyVariable(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard whole(value, MCPRules.keyName), MCPRules.keyEndings.contains(where: value.hasSuffix), !reserved(value) else { return nil }
        return value
    }

    /// The name of the API key of a server's key that the form makes (`sessionVariable`): a key's name
    /// (`keyVariable`), none of `MCPRules.fleetKeys`, which the hub refuses too, so no key stands in a session as
    /// `GH_TOKEN`, and none of `MCPRules.refusedNames`, which the hub still takes for the servers it had before.
    public static func isServerKey(_ name: String) -> Bool {
        keyVariable(name) == name && !isRefused(name) && !MCPRules.fleetKeys.contains(name)
    }

    /// One of `MCPRules.reservedNames`: a name that a session's start or a runtime sets or reads itself.
    static func reserved(_ name: String) -> Bool { whole(name, MCPRules.reservedNames) }

    /// A key that the central vault takes: 8 characters or more and no white space, so that the hub can find it in a
    /// text and mask it (`SecretFingerprint`), and no more than a vault's sealed copy holds (`LoginSecret`).
    public static func isKeyValue(_ value: String) -> Bool {
        var secret = LoginSecret()
        secret.kind = .apiKey
        secret.env = "MCP_KEY"
        secret.password = value
        return value.unicodeScalars.count >= 8 && !value.unicodeScalars.contains(where: SecretFingerprint.isWhitespace)
            && secret.problem == nil
    }

    /// **The variable of the API key that one key of a server goes into**, on the Secrets page: always the server's
    /// name, in capitals with `-` as `_`, and then the program's own variable (`ODOO_ODOO_API_KEY`), with `_KEY` after a
    /// name with no key's ending (`ACME_DATABASE_URL_KEY`); a remote server's key is `<SERVER>_KEY` (`MCP.remoteKey`).
    /// So no key of a server is ever named as a variable that a session holds already (`GH_TOKEN`). A name that the
    /// fleet has gets a number after the server's name (`ODOO_2_ODOO_API_KEY`), so a new key never takes the place of
    /// one of the fleet; a server's name that would begin a reserved name gets `MCP_` before it. `taken`: the
    /// variables of the fleet's API keys, and of the keys that this Add gave a variable already. nil only when no such
    /// name is free.
    public static func sessionVariable(for own: String, server: String, taken: Set<String>) -> String? {
        let capitals = own.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let ended = MCPRules.keyEndings.contains(where: { capitals.hasSuffix($0) || "_" + capitals == $0 })
            ? capitals : capitals + "_KEY"
        let head = keyHead(server)
        for number in 1...99 {
            let prefix = number == 1 ? head : head + "\(number)_"
            let room = 60 - prefix.count
            guard room >= 4 else { return nil }
            let name = prefix + String(ended.suffix(room))
            if isServerKey(name), !taken.contains(name) { return name }
        }
        return nil
    }

    /// The start of the name of every key that the form makes for one server (`sessionVariable`): the server's name in
    /// capitals with `-` as `_`, then `_`; with `MCP_` before it where that start would begin a name that no key may
    /// have (`NODE_…`, `CLAUDE_…`).
    static func keyHead(_ server: String) -> String {
        let head = server.uppercased().replacingOccurrences(of: "-", with: "_") + "_"
        return isServerKey(head + "X_KEY") ? head : "MCP_" + head
    }

    /// **A key that the form made for this server** (`sessionVariable`), by its variable: a key's name that begins with
    /// the server's own start (`keyHead`), with or without the number of a name that the fleet had then
    /// (`ODOO_ODOO_API_KEY`, `ODOO_2_ODOO_API_KEY`, `ACME_CRM_KEY`, `MCP_NODE_TOOLS_API_KEY`). A key of the Secrets page
    /// that the owner named after nothing, or after another server, is none, and is never taken back with this one.
    public static func isFormKey(_ variable: String, of server: String) -> Bool {
        let head = keyHead(server)
        return isServerKey(variable) && variable.hasPrefix(head) && variable.count > head.count
    }

    /// The hub's refusal of a Connect to a server that has no OAuth at all (`mcp.discover`, a 502): such a server needs
    /// no sign-in. The hub names it with the code `no_oauth`; an older hub, which gives no code, with its own words,
    /// in English, which the app compares and never looks up.
    public static func hasNoOAuth(_ error: Error) -> Bool {
        if let refused = error as? MCPRefusal { return refused.why.contains("no_oauth") }
        if case HubError.refusal(let refused) = error, refused.status == 502, refused.code == nil {
            let words = refused.hubWords        // an older hub's English, which gives no code and no why: never the app's
                                                // own words, and never a new hub's, whose server text could say them
            return words.contains("has no OAuth metadata")
        }
        return false
    }

    /// The whole of `text` matches `rule`, as Python's `re.fullmatch` reads it: no line end after it either.
    static func whole(_ text: String, _ rule: String) -> Bool {
        text.range(of: "^(?:\(rule))\\z", options: .regularExpression) != nil
    }

    /// One variable name as the hub takes it: `A-Z 0-9 _`, starting with a letter, at most 60 characters, and not a
    /// name that a session sets itself.
    public static func variable(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.range(of: "^[A-Z][A-Z0-9_]{0,59}$", options: .regularExpression) != nil,
              value.range(of: "^(FLEET|BWS|LD|DYLD|ANTHROPIC|CLAUDE|CODEX)_|^(PATH|HOME|SHELL|USER|LOGNAME|TMPDIR|TERM|PWD|IFS|ENV|BASH_ENV|ZDOTDIR|NODE_OPTIONS|PYTHONPATH|PYTHONHOME)$",
                         options: .regularExpression) == nil
        else { return nil }
        return value
    }

    /// The loopback address of a Connect; the hub takes `http://127.0.0.1:<port>/` only.
    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/" }
}

/// What one Connect needs: the address to open in the owner's browser, and the `state` that must come back.
public struct MCPConnectStart: Sendable {
    public let url: URL
    public let state: String
    public let scopes: [String]
}

/// What the hub says after a Connect: the server's own name and its tools.
public struct MCPConnected: Sendable {
    public let name: String
    public let server: String?
    public let tools: [String]
    public let scopes: [String]
}

/// The commands of this page, without the command fields.
enum MCPCommand {
    case save(name: String, server: MCPServerSpec, sha256: String)
    case delete(name: String, sha256: String)
    /// `client`: the client that the owner registered himself, for a server that registers none.
    case connect(name: String, redirectURI: String, client: (id: String, secret: String?)?)
    case finish(state: String, code: String)
    case disconnect(name: String)
    /// Find a server (`mcp_find`): the servers of the MCP Registry for these words.
    case find(words: String)
    /// The version of a package that a program server may take now (`mcp_packages`).
    case package(MCPPackageRef)

    var route: String {
        switch self {
        case .save, .delete: "ui/team/mcp"
        case .connect: "ui/mcp/connect"
        case .finish: "ui/mcp/finish"
        case .disconnect: "ui/mcp/disconnect"
        case .find: "ui/mcp/find"
        case .package: "ui/mcp/package"
        }
    }

    var fields: [String: Any] {
        switch self {
        case .save(let name, let server, let sha256): return ["base_sha256": sha256, "name": name, "server": server.object]
        case .delete(let name, let sha256): return ["base_sha256": sha256, "name": name, "delete": true]
        case .connect(let name, let redirectURI, let client):
            return ["name": name, "redirect_uri": redirectURI].merging(client.map {
                ["client": ["client_id": $0.id, "client_secret": $0.secret].compactMapValues { $0 } as [String: Any]]
            } ?? [:]) { _, new in new }
        case .finish(let state, let code): return ["state": state, "code": code]
        case .disconnect(let name): return ["name": name]
        case .find(let words): return ["words": words]
        case .package(let package):
            var fields: [String: Any] = ["registry": package.registry.rawValue, "name": package.name]
            if let version = package.version { fields["version"] = version }
            return fields
        }
    }

    /// A command that changes something at the hub, whose answer wakes the pages (`HubWrites`). A search and a lookup
    /// change nothing.
    var changes: Bool {
        switch self {
        case .find, .package: false
        default: true
        }
    }
}

/// The owner's MCP servers at the hub: one server added, changed or removed, the Connect of one server, and the two
/// lookups of the form (Find a server, a package's version). The page reads `GET /ui/team` with `IntegrationsClient`.
/// A write that gets no answer can have arrived; the next one, from a new reading, is safe, because the hub refuses an
/// old version (409).
public final class MCPClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60        // the hub talks to the server and commits team.json
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: NoMCPRedirect(), delegateQueue: nil)
    }

    /// One server added or changed. The hub keeps it under `name`.
    public func save(hub: URL, database: String, client: String, sha256: String, name: String,
                     server: MCPServerSpec) async throws {
        _ = try await write(.save(name: name, server: server, sha256: sha256), hub: hub, database: database, client: client)
    }

    /// One server removed, with the grants of every agent that had it and its saved connection.
    public func delete(hub: URL, database: String, client: String, sha256: String, name: String) async throws {
        _ = try await write(.delete(name: name, sha256: sha256), hub: hub, database: database, client: client)
    }

    public func connect(hub: URL, database: String, client: String, name: String, redirectURI: String,
                        own: (id: String, secret: String?)? = nil) async throws -> MCPConnectStart {
        let answer = try await write(.connect(name: name, redirectURI: redirectURI, client: own), hub: hub,
                                     database: database, client: client)
        guard let text = answer.url, let url = URL(string: text), let state = answer.state, !state.isEmpty,
              url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else { throw HubError.invalidResponse }
        return MCPConnectStart(url: url, state: state, scopes: answer.scopes ?? [])
    }

    public func finish(hub: URL, database: String, client: String, state: String, code: String) async throws -> MCPConnected {
        let answer = try await write(.finish(state: state, code: code), hub: hub, database: database, client: client)
        guard let name = answer.name, answer.connected == true else { throw HubError.invalidResponse }
        return MCPConnected(name: name, server: answer.server, tools: answer.tools ?? [], scopes: answer.scopes ?? [])
    }

    public func disconnect(hub: URL, database: String, client: String, name: String) async throws {
        _ = try await write(.disconnect(name: name), hub: hub, database: database, client: client)
    }

    /// Find a server (`mcp_find`): the servers of the official MCP Registry for these words that Fleet can run.
    public func find(hub: URL, database: String, client: String, words: String) async throws -> [MCPFound] {
        let data = try await send(.find(words: words), hub: hub, database: database, client: client)
        return try JSONDecoder().decode(MCPFindings.self, from: data).servers
    }

    /// The version of one package that a program server may take now, and the day of its dependencies
    /// (`mcp_packages`). An answer about another package is no answer.
    public func package(hub: URL, database: String, client: String, of package: MCPPackageRef) async throws -> MCPPackageVersion {
        let data = try await send(.package(package), hub: hub, database: database, client: client)
        let answer = try JSONDecoder().decode(MCPPackageVersion.self, from: data)
        guard answer.spec(for: package) != nil else { throw HubError.invalidResponse }
        return answer
    }

    static func body(_ command: MCPCommand, requestID: String, database: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: command.fields.merging(
            ["request_id": requestID, "db": database]) { _, new in new }, options: [.sortedKeys])
    }

    private struct Receipt: Decodable {
        let ok: Bool
        let request_id: String
        let client: String
        let name: String?
        let url: String?
        let state: String?
        let scopes: [String]?
        let server: String?
        let tools: [String]?
        let connected: Bool?
        let changed: Bool?
    }

    private func write(_ command: MCPCommand, hub: URL, database: String, client: String) async throws -> Receipt {
        try JSONDecoder().decode(Receipt.self, from: await send(command, hub: hub, database: database, client: client))
    }

    /// One command with a new `request_id`, and its receipt, which must be the answer to this very command.
    private func send(_ command: MCPCommand, hub: URL, database: String, client: String) async throws -> Data {
        let requestID = UUID().uuidString.lowercased()
        var request = URLRequest(url: hub.appendingPathComponent(command.route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try Self.body(command, requestID: requestID, database: database)
        let data = try await perform(request, changes: command.changes)
        let receipt = try JSONDecoder().decode(Envelope.self, from: data)
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client else { throw HubError.invalidResponse }
        return data
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let request_id: String
        let client: String
    }

    private func perform(_ request: URLRequest, changes: Bool) async throws -> Data {
        let (data, response) = try await session.hubData(for: request)
        if changes { HubWrites.note(request) }
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw Self.refusal(response.statusCode, data) }
        return data
    }

    /// The error of one refusal: the refusal as every client of the hub reads it (`HubRefusal.read`), with the codes of
    /// its cause where it gave some (`MCPRefusal`, the `why` of a 502 of a Connect).
    static func refusal(_ status: Int, _ data: Data) -> Error {
        let refused = HubRefusal.read(status: status, body: data)
        let why = (try? JSONDecoder().decode(WhyBody.self, from: data))?.why ?? []
        if !why.isEmpty { return MCPRefusal(status: status, words: refused.words, why: why) }
        return HubError.refusal(refused)
    }

    /// The `why` of a refusal, when it has one: a list of codes (owner feature hub_shared, and Connect's `no_oauth`).
    private struct WhyBody: Decodable {
        let why: [String]?

        private enum Keys: String, CodingKey { case why }
        init(from decoder: Decoder) throws {
            why = (try? decoder.container(keyedBy: Keys.self).decodeIfPresent([String].self, forKey: .why)) ?? nil
        }
    }
}

/// A refusal of the hub that names its cause with codes (`why`), besides its words: the one that the form acts on is
/// `no_oauth`, a server that has no OAuth at all (`MCP.hasNoOAuth`). Its words are the hub's own, as every refusal's.
public struct MCPRefusal: LocalizedError, Equatable, Sendable {
    public let status: Int
    public let words: String
    public let why: [String]

    public init(status: Int, words: String, why: [String]) { self.status = status; self.words = words; self.why = why }

    public var errorDescription: String? { words }
}

private final class NoMCPRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
