import Foundation
import Testing

/// A made-up key and a made-up database address with a password, each written in two parts, so that no line of this
/// file has the whole shape of a key or of a connection string (GitHub's push protection refused made-up values of a
/// key's shape on 16 November 2026). The values at run time are the same.
private let madeUpKey = "sk-" + "live-41f9c2b8"
private let madeUpDatabase = "postgres://acme" + ":pw-41f9c2b8@db.acme.example/acme"
@testable import FleetCore

private let sha = String(repeating: "a", count: 64)
private let requestID = "11111111-2222-4333-8444-555555555555"

private func tool(_ fields: [String: Any]) -> [String: Any] {
    ["title": "x", "runtimes": ["claude", "codex"], "custom": true, "auth": "none", "needs": []].merging(fields) { _, new in new }
}

/// The catalog as `GET /ui/team` gives it: Fleet's GitHub server, the owner's connected CRM, a server with a key, and
/// a program server. Dev has the CRM and GitHub; Ops has nothing.
private func snapshot(crm: [String: Any] = tool(["title": "Acme CRM", "url": "https://mcp.acme.example/",
                                                 "auth": "oauth", "needs": ["FLEET_MCP_CRM"], "connected": true,
                                                 "connected_at": 1760600000, "scopes": ["acme"], "server": "acme-mcp",
                                                 "tools": ["crm_orders", "crm_stores"], "problem": NSNull()]),
                      tools: [String: Any]? = nil) throws -> IntegrationsSnapshot {
    let catalog: [String: Any] = tools ?? [
        "github": ["title": "GitHub", "command": "github-mcp-server", "args": ["stdio"],
                   "runtimes": ["claude", "codex"], "custom": false, "auth": "none", "needs": ["GH_TOKEN"]],
        "crm": crm,
        "shop": tool(["title": "Shop", "url": "https://shop.example.com/mcp", "auth": "key", "needs": ["SHOP_KEY"]]),
        "notes": tool(["title": "Notes", "command": "notes-mcp", "args": ["stdio"], "runtimes": ["claude"]])]
    let lines: [[String: Any]] = [
        ["agent": "manager", "role": "manager", "repos": [:], "tools": []],
        ["agent": "dev", "role": "worker", "repos": ["acme/web": "write"], "tools": ["crm", "github"]],
        ["agent": "ops", "role": "worker", "repos": [:], "tools": []]]
    let object: [String: Any] = ["db": "db", "revision": String(repeating: "b", count: 40), "sha256": sha,
                                 "lines": lines, "tools": catalog, "github": ["app": true, "problem": NSNull()]]
    return try JSONDecoder().decode(IntegrationsSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

private func sent(_ command: MCPCommand) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: MCPClient.body(command, requestID: requestID, database: "db")) as? [String: Any])
}

struct MCPTests {
    @Test func theCatalogKeepsFleetsOwnToolsApartFromTheOwnersServers() throws {
        let team = try snapshot()
        try team.validate(database: "db")
        #expect(team.catalog.map(\.name) == ["github"])
        #expect(team.servers.map(\.name) == ["crm", "notes", "shop"])
        #expect(team.agents(of: "crm") == ["dev"] && team.agents(of: "shop") == [])
        let crm = try #require(team.servers.first { $0.name == "crm" }?.tool)
        #expect(crm.isCustom && crm.kind == .oauth && crm.connected == true && !crm.needsOwner)
        #expect(crm.detail == "https://mcp.acme.example/" && crm.tools?.count == 2 && crm.server == "acme-mcp")
        let notes = try #require(team.servers.first { $0.name == "notes" }?.tool)
        #expect(notes.kind == .none && notes.detail == "notes-mcp stdio" && notes.runtimes == ["claude"])
        #expect(try #require(team.servers.first { $0.name == "shop" }?.tool).kind == .key)
        #expect(!team.free(name: "crm") && !team.free(name: "github") && !team.free(name: "fleet") && team.free(name: "books"))
    }

    @Test func aServerThatWaitsForTheOwnerSaysSo() throws {
        let waiting = try #require(try snapshot(crm: tool(["title": "Acme CRM", "url": "https://mcp.acme.example/",
                                                           "auth": "oauth", "needs": ["FLEET_MCP_CRM"],
                                                           "connected": false])).servers.first { $0.name == "crm" }?.tool)
        #expect(waiting.needsOwner && waiting.connected == false && waiting.tools == nil)
        let refused = try #require(try snapshot(crm: tool(["title": "Acme CRM", "url": "https://m.example.com/",
                                                           "auth": "oauth", "connected": true,
                                                           "problem": "invalid_grant. Connect this server again."]))
            .servers.first { $0.name == "crm" }?.tool)
        #expect(!refused.needsOwner && refused.problem?.hasPrefix("invalid_grant") == true)
    }

    @Test func aServerWithoutARefreshTokenSaysWhenItsAccessEnds() throws {
        let team = try snapshot(crm: tool(["title": "Acme CRM", "url": "https://admin.acme.example/mcp", "auth": "oauth",
                                           "needs": ["FLEET_MCP_CRM"], "connected": true, "connected_at": 1760600000,
                                           "scopes": ["mcp:tickets"], "server": "acme-crm", "tools": ["list_tickets"],
                                           "access_ends": 1792200000, "problem": NSNull()]))
        let crm = try #require(team.servers.first { $0.name == "crm" }?.tool)
        #expect(crm.access_ends == 1792200000 && crm.connected == true && !crm.needsOwner)
        #expect(crm.scopes == ["mcp:tickets"] && crm.detail == "https://admin.acme.example/mcp")
        // Every other server has no end: its connection lives on its refresh token.
        #expect(try #require(try snapshot().servers.first { $0.name == "crm" }?.tool).access_ends == nil)
    }

    @Test func aHubWithoutTheFeatureStillDecodes() throws {
        let old: [String: Any] = ["github": ["title": "GitHub", "command": "github-mcp-server", "args": ["stdio"],
                                             "runtimes": ["claude", "codex"]]]
        let team = try snapshot(tools: old)
        #expect(team.servers.isEmpty && team.catalog.map(\.name) == ["github"])
        #expect(try #require(team.tools?["github"]).isCustom == false)
    }

    @Test func theNameComesFromTheTitleAndIsAlwaysOneTheHubTakes() {
        #expect(MCP.name(from: "Acme CRM") == "acme-crm")
        #expect(MCP.name(from: "  Shop · Orders!  ") == "shop-orders")
        #expect(MCP.name(from: "2nd shop") == "nd-shop")              // a name starts with a letter
        #expect(MCP.name(from: String(repeating: "ab ", count: 20))?.count == 31)
        #expect(MCP.name(from: "---") == nil && MCP.name(from: "") == nil && MCP.name(from: "7") == nil)
        for name in [MCP.name(from: "Acme CRM"), MCP.name(from: "Café Notes"), MCP.name(from: "A B C")] {
            let value = name ?? ""
            #expect(value.range(of: "^[a-z][a-z0-9-]{0,30}$", options: .regularExpression) != nil, "\(value)")
        }
    }

    @Test func anAddressIsHttpsAndAProgramIsNoShellLine() {
        #expect(MCP.address("https://mcp.acme.example/") == "https://mcp.acme.example/")
        #expect(MCP.address(" mcp.acme.example ") == "https://mcp.acme.example")   // a pasted host
        #expect(MCP.address("http://127.0.0.1:5015/mcp") == "http://127.0.0.1:5015/mcp")
        for bad in ["http://mcp.example.com/", "https://u:p@mcp.example.com/", "https://mcp.example.com/#x",
                    "ftp://mcp.example.com/", "https://", "", "https://a b/", String(repeating: "x", count: 400),
                    "https://mcp.example.com/${FLEET_MCP_CRM}", "https://mcp.example.com/{env:SHOP_KEY}",
                    "https://mcp.example.com/{file:/srv/key}"] {
            #expect(MCP.address(bad) == nil, "\(bad)")
        }
        #expect(MCP.program("notes-mcp stdio")?.program == "notes-mcp")
        #expect(MCP.program("notes-mcp stdio --root /tmp")?.args == ["stdio", "--root", "/tmp"])
        #expect(MCP.program("notes-mcp --root {file:/srv/notes}") == nil && MCP.program("notes-mcp {env:X}") == nil)
        #expect(MCP.plainValue("{tenant}/x") && MCP.program("notes-mcp {tenant}")?.args == ["{tenant}"])
        for bad in ["", "/usr/bin/notes", "notes-mcp | tee x", "notes-mcp $HOME", "notes-mcp 'a b'",
                    "notes-mcp " + Array(repeating: "a", count: 17).joined(separator: " ")] {
            #expect(MCP.program(bad) == nil, "\(bad)")
        }
        #expect(MCP.variable(" acme_crm_key ") == "ACME_CRM_KEY" && MCP.variable("SHOP_KEY") == "SHOP_KEY")
        for bad in ["", "1KEY", "FLEET_X", "PATH", "CLAUDE_CODE", "A-B"] { #expect(MCP.variable(bad) == nil, "\(bad)") }
    }

    @Test func theFormGivesTheServerThatTheHubTakes() throws {
        var draft = MCPDraft()
        #expect(!draft.isComplete(features: []) && draft.auth == .oauth && draft.kind == .remote)
        draft.title = "Acme CRM"
        draft.address = "mcp.acme.example"
        #expect(draft.isComplete(features: []) && draft.name == "acme-crm")
        #expect(try #require(draft.server(features: [])).object as? [String: String]
                == ["title": "Acme CRM", "url": "https://mcp.acme.example", "auth": "oauth"])
        // A key server: the owner types its key in a secure field, and Add puts it into the vault as <SERVER>_KEY
        // before the server names that variable.
        draft.auth = .key
        #expect(!draft.isComplete(features: []) && draft.keyValues.isEmpty)    // no key yet
        draft.remoteKey = "short"
        #expect(!draft.isComplete(features: []) && draft.keyValues.isEmpty)    // a key that the vault refuses
        draft.remoteKey = " acme-crm-41f9c2b8 "
        var server = try #require(draft.server(features: []))
        #expect(server.object as? [String: String] == ["title": "Acme CRM", "url": "https://mcp.acme.example", "auth": "key"])
        #expect(draft.keyValues.map(\.name) == [MCP.remoteKey] && draft.keyValues.map(\.value) == ["acme-crm-41f9c2b8"])
        #expect(draft.keyValues.map(\.id) == [draft.remoteKeyID])
        server.key = MCP.sessionVariable(for: MCP.remoteKey, server: "acme-crm", taken: [])
        #expect(server.object as? [String: String]
                == ["title": "Acme CRM", "url": "https://mcp.acme.example", "auth": "key", "key": "ACME_CRM_KEY"])
        #expect(!String(describing: server.object).contains("41f9c2b8"))
        draft.auth = .none
        #expect(try #require(draft.server(features: [])).object as? [String: String]
                == ["title": "Acme CRM", "url": "https://mcp.acme.example"])
        #expect(draft.keyValues.isEmpty)                                      // no sign-in needs no key

        // A program: its line, with no sign-in of its own; its keys are rows (MCPProgramTests). A program of the
        // machine takes no argument, on any hub.
        var program = MCPDraft()
        program.title = "Notes"
        program.kind = .local
        program.command = "notes-mcp"
        let object = try #require(program.server(features: [])).object
        #expect(object["command"] as? String == "notes-mcp" && object["args"] == nil)
        #expect(object["auth"] == nil && object["env"] == nil && object["settings"] == nil && object["package"] == nil)
        program.command = "notes-mcp stdio"
        #expect(program.server(features: []) == nil && program.server(features: [MCP.packagesFeature]) == nil)
    }

    @Test func eachWriteHasItsCommandFieldsAndNoSecret() throws {
        let server = try #require({ () -> MCPServerSpec? in
            var draft = MCPDraft()
            draft.title = "Acme CRM"
            draft.address = "https://mcp.acme.example/"
            return draft.server(features: [])
        }())
        let save = try sent(.save(name: "acme-crm", server: server, sha256: sha))
        #expect(save["request_id"] as? String == requestID && save["db"] as? String == "db")
        #expect(save["name"] as? String == "acme-crm" && save["base_sha256"] as? String == sha)
        #expect((save["server"] as? [String: Any])?["url"] as? String == "https://mcp.acme.example/")
        #expect(try sent(.delete(name: "acme-crm", sha256: sha))["delete"] as? Bool == true)
        let connect = try sent(.connect(name: "acme-crm", redirectURI: MCP.redirectURI(port: 53111), client: nil))
        #expect(connect["redirect_uri"] as? String == "http://127.0.0.1:53111/" && connect["client"] == nil)
        #expect(connect["base_sha256"] == nil)                      // a Connect writes no team.json
        let own = try sent(.connect(name: "acme-crm", redirectURI: "http://127.0.0.1:1/",
                                    client: (id: "own-client", secret: nil)))
        #expect(own["client"] as? [String: String] == ["client_id": "own-client"])
        #expect(try sent(.finish(state: "state-1", code: "code-1")) as? [String: String]
                == ["request_id": requestID, "db": "db", "state": "state-1", "code": "code-1"])
        #expect(try sent(.disconnect(name: "acme-crm"))["name"] as? String == "acme-crm")
        for command in [MCPCommand.save(name: "acme-crm", server: server, sha256: sha), .delete(name: "acme-crm", sha256: sha),
                        .connect(name: "acme-crm", redirectURI: "http://127.0.0.1:1/", client: nil),
                        .disconnect(name: "acme-crm")] {
            #expect(command.route.hasPrefix("ui/"))
        }
    }

    /// **Sign in again** (the owner's "Yes, all three", 15 November 2026): the row of a server of the hub's Connect
    /// asks for a new sign-in at a definite end of its access (`ended`), when it has no connection, and in the 14 days
    /// before an access that cannot renew ends; never for an outage, which a sign-in does not help. A hub from before
    /// `ended` asks at any problem. No other server ever asks.
    @Test func aServerWhoseAccessEndsAsksForANewSignIn() throws {
        let now = 1_792_000_000.0
        func crm(_ fields: [String: Any]) throws -> IntegrationsSnapshot.Tool {
            try #require(try snapshot(crm: tool(["title": "Acme CRM", "url": "https://mcp.acme.example/", "auth": "oauth",
                                                 "needs": ["FLEET_MCP_CRM"], "connected": true].merging(fields) { _, new in new }))
                .servers.first { $0.name == "crm" }?.tool)
        }
        let refused = "invalid_grant. Connect this server again."
        #expect(try crm(["ended": false]).signIn(at: now) == nil)
        #expect(try crm(["ended": true, "problem": refused]).signIn(at: now) == .ended(refused))
        #expect(try crm(["ended": true]).signIn(at: now) == .ended(nil))
        #expect(try crm(["ended": false, "problem": "the server did not answer now"]).signIn(at: now) == nil)   // an outage
        #expect(try crm(["ended": false, "connected": false]).signIn(at: now) == .notConnected)
        #expect(try crm(["ended": false, "access_ends": now + 13 * 86_400]).signIn(at: now) == .ends(now + 13 * 86_400))
        #expect(try crm(["ended": false, "access_ends": now + 14 * 86_400]).signIn(at: now) == .ends(now + 14 * 86_400))
        #expect(try crm(["ended": false, "access_ends": now + 15 * 86_400]).signIn(at: now) == nil)
        #expect(try crm(["ended": false, "access_ends": now + 86_400]).signIn(at: nil) == nil)  // no hub time, no near end
        // A hub from before `ended`: today's rule, any problem.
        #expect(try crm([:]).signIn(at: now) == nil)
        #expect(try crm(["problem": refused]).signIn(at: now) == .ended(refused))
        #expect(try crm(["connected": false]).signIn(at: now) == .notConnected)
        #expect(try crm(["access_ends": now + 13 * 86_400]).signIn(at: now) == .ends(now + 13 * 86_400))
        let team = try snapshot()
        for name in ["shop", "notes", "github"] {
            #expect(team.tools?[name]?.signIn(at: now) == nil, "\(name)")
        }
    }

    @Test func theSwitchOfOneAgentKeepsTheOthers() throws {
        let team = try snapshot()
        let order = team.lines.map(\.agent)
        #expect(Integrations.agents(team.agents(of: "crm"), agent: "ops", on: true, order: order) == ["dev", "ops"])
        #expect(Integrations.agents(team.agents(of: "crm"), agent: "dev", on: false, order: order) == [])
        #expect(Integrations.agents(team.agents(of: "shop"), agent: "dev", on: true, order: order) == ["dev"])
    }
}

/// Reading a server's own published configuration, which is how the owner adds one without typing its parts: he
/// copies the snippet from that server's page and the form fills itself. A key in that snippet is never kept.
struct MCPSnippetTests {
    @Test func aPublishedSnippetFillsTheForm() throws {
        let remote = try #require(MCP.read(snippet: """
        {"mcpServers": {"crm": {"url": "https://mcp.example.com/sse"}}}
        """))
        #expect(remote.kind == .remote && remote.address == "https://mcp.example.com/sse")
        #expect(remote.title == "crm" && remote.name == "crm")
        #expect(remote.auth == .oauth)      // the owner says what it signs in with; a snippet cannot prove it
        #expect(remote.isComplete(features: []))

        let program = try #require(MCP.read(snippet: """
        {"mcpServers": {"notes": {"command": "npx", "args": ["-y", "notes-mcp"],
                                  "env": {"NOTES_TOKEN": "sk-live-41f9c2b8"}}}}
        """))
        #expect(program.kind == .local && program.command == "npx -y notes-mcp")
        #expect(program.package == MCPPackageRef(registry: .npm, name: "notes-mcp"))
        #expect(program.title == "notes")
    }

    /// The one that matters: a snippet usually carries a real token, and this app keeps no key out of the vault. The
    /// variable's name is kept, because the program reads it, as a key row; the value is dropped, and the owner gives
    /// the key in its secure field.
    @Test func aPastedKeyIsNeverKept() throws {
        let snippet = """
        {"mcpServers": {"notes": {"command": "notes-mcp", "env": {"NOTES_TOKEN": "sk-live-41f9c2b8"}}}}
        """
        let draft = try #require(MCP.read(snippet: snippet))
        #expect(draft.variables.map(\.name) == ["NOTES_TOKEN"])     // what the program reads
        #expect(draft.variables.allSatisfy { $0.isKey && $0.value.isEmpty })
        #expect(draft.keyValues.isEmpty)                            // nothing for the vault until he gives it
        for field in [draft.title, draft.address, draft.command, draft.remoteKey] + draft.variables.flatMap({ [$0.name, $0.value] }) {
            #expect(!field.contains("sk-live"), "a pasted key reached \(field)")
        }
        // And nothing of the value reaches the hub either.
        draftCarriesNoValue(draft)
    }

    private func draftCarriesNoValue(_ draft: MCPDraft) {
        guard let server = draft.server(features: [MCP.feature, MCP.packagesFeature]) else {
            Issue.record("the pasted program is a server the hub takes")
            return
        }
        let written = String(describing: server.object)
        #expect(!written.contains("sk-live"))
    }

    @Test func whatIsNotAServerIsNotRead() {
        for bad in ["", "not json", "{}", "{\"mcpServers\": {}}", "{\"mcpServers\": {\"x\": {\"url\": \"ftp://nope/\"}}}",
                    "{\"mcpServers\": {\"x\": {\"note\": \"nothing here\"}}}"] {
            #expect(MCP.read(snippet: bad) == nil, "\(bad) was read as a server")
        }
    }

    @Test func theOtherShapesInUseAreReadToo() throws {
        // A bare map of servers, and one object on its own with its name beside it.
        #expect(MCP.read(snippet: "{\"crm\": {\"url\": \"https://mcp.example.com/\"}}")?.address == "https://mcp.example.com/")
        let named = try #require(MCP.read(snippet: "{\"name\": \"CRM\", \"url\": \"https://mcp.example.com/\"}"))
        #expect(named.title == "CRM" && named.name == "crm")
    }

    /// A flag of a key in the pasted line goes out of it with its value, and a key row named after it takes its place,
    /// whose key goes to the program in its environment.
    @Test func aKeyAfterAFlagIsDropped() throws {
        let draft = try #require(MCP.read(snippet: """
        {"mcpServers": {"ctx": {"command": "npx", "args": ["-y", "ctx-mcp", "--api-key", "\(madeUpKey)",
                                                            "--access-token=tok-41f9c2b8", "--region", "eu", "--bearer"]}}}
        """))
        #expect(draft.command == "npx -y ctx-mcp --region eu")
        #expect(draft.variables.map(\.name) == ["API_KEY", "ACCESS_TOKEN", "BEARER"])
        #expect(draft.variables.allSatisfy { $0.isKey && !$0.named && $0.value.isEmpty })
        #expect(draft.line != nil && draft.refusal == nil)
        for field in [draft.command] + draft.variables.map(\.name) { #expect(!field.contains("41f9"), "\(field)") }
        var given = draft
        given.variables[0].value = "ctx-41f9c2b8"
        #expect(given.keyValues.map(\.name) == ["API_KEY"])
        // A flag takes a secret when one of its words is a word of a secret: it goes with its value; any other stays
        // with its own, and the next flag is no value.
        #expect(MCP.withoutKeys(["--key-file", "/srv/acme.pem", "--auth-url", "https://acme.example/auth", "-v"]).args == ["-v"])
        #expect(MCP.withoutKeys(["--key-file", "/srv/acme.pem"]).flags == ["--key-file"])
        let kept = ["--author", "acme", "--path", "/srv", "--keyboard", "us", "--compat", "1", "--region", "eu"]
        #expect(MCP.withoutKeys(kept).args == kept && MCP.withoutKeys(kept).flags.isEmpty)
        #expect(MCP.withoutKeys(["--token", "--verbose"]).args == ["--verbose"])
        #expect(MCP.withoutKeys(["--token", "--verbose"]).flags == ["--token"])
        for flag in ["--token", "--api-key", "--apikey", "--access-token", "--key", "--secret", "--password", "--pat", "--auth",
                     "--key-file", "--bearer", "--client_secret", "-k-token", "--PRIVATE-KEY", "--dsn"] {
            #expect(MCP.isSecretFlag(flag), "\(flag)")
        }
        for flag in ["--author", "--path", "--keyboard", "--compat", "--tokenizer", "--region", "-y", "token", "--", "---key"] {
            #expect(!MCP.isSecretFlag(flag), "\(flag)")
        }
        // A key typed into the line is no line, and the message names only its flag.
        #expect(MCP.refusal(line: "uvx acme-mcp --password=hunter-41f9c2b8") == .flag("--password"))
        #expect(MCP.line("uvx acme-mcp --password=hunter-41f9c2b8") == nil)
        #expect(MCP.refusal(line: "uvx acme-mcp --Api-Key hunter-41f9c2b8") == .flag("--Api-Key"))
        #expect(MCP.line("uvx acme-mcp --token") != nil && MCP.line("uvx acme-mcp --token --verbose") != nil)
        #expect(MCPLineRefusal.flag("--password").words.contains("--password"))
        #expect(!MCPLineRefusal.flag("--password").words.contains("hunter"))
    }

    @Test func aDockerImageOrAnotherInstallerIsNoServerAndSaysWhy() throws {
        let docker = """
        {"mcpServers": {"acme": {"command": "docker", "args": ["run", "-i", "--rm", "-e", "ACME_KEY", "acme/mcp"]}}}
        """
        #expect(MCP.read(snippet: docker) == nil && MCP.refusal(snippet: docker) == .image)
        let npm = "{\"mcpServers\": {\"acme\": {\"command\": \"npm\", \"args\": [\"exec\", \"acme-mcp\"]}}}"
        #expect(MCP.read(snippet: npm) == nil && MCP.refusal(snippet: npm) == .runner)
        // A program of the machine with arguments fills the form, and keeps Add off: only a package takes them.
        let plain = try #require(MCP.read(snippet: "{\"notes\": {\"command\": \"notes-mcp\", \"args\": [\"stdio\"]}}"))
        #expect(plain.command == "notes-mcp stdio" && plain.line == nil && plain.refusal == .runner)
        #expect(plain.server(features: [MCP.feature, MCP.packagesFeature]) == nil)
        #expect(MCP.refusal(snippet: "{\"crm\": {\"url\": \"https://mcp.example.com/\"}}") == nil)
        #expect(MCP.refusal(snippet: "not json") == nil)
    }
}

/// The program servers of owner API 1.187 (`mcp_packages`): the Program line that names a package or a program, its
/// settings and keys, and the server that the hub takes. The rules are the hub's (`lifecycle.mcp_server`,
/// `setting_name`, `plain_value`, `SETTING_REFUSED`, `key_env`), so Add stays off until the hub takes the server.
struct MCPProgramTests {
    private let features = [MCP.feature, MCP.packagesFeature]
    private let odoo = MCPPackageVersion(registry: "pypi", name: "mcp-server-odoo", version: "0.9.0", as_of: "2026-11-08")

    private func program(_ line: String, _ variables: [MCPVariable] = []) -> MCPDraft {
        var draft = MCPDraft()
        draft.title = "Odoo"
        draft.kind = .local
        draft.command = line
        draft.variables = variables
        return draft
    }

    @Test func aLineRunsAPackageOrAProgram() {
        #expect(MCP.line("npx -y @modelcontextprotocol/server-filesystem@2026.8.31 /srv/shared")
                == .package(MCPPackageRef(registry: .npm, name: "@modelcontextprotocol/server-filesystem", version: "2026.8.31"),
                            args: ["/srv/shared"]))
        #expect(MCP.line("npx --yes notes-mcp stdio") == .package(MCPPackageRef(registry: .npm, name: "notes-mcp"), args: ["stdio"]))
        #expect(MCP.line("npx notes-mcp@latest") == .package(MCPPackageRef(registry: .npm, name: "notes-mcp"), args: []))
        #expect(MCP.line("bunx notes-mcp") == .package(MCPPackageRef(registry: .npm, name: "notes-mcp"), args: []))
        #expect(MCP.line("pnpm dlx notes-mcp@1.2.0") == .package(MCPPackageRef(registry: .npm, name: "notes-mcp", version: "1.2.0"),
                                                                 args: []))
        // `-p <package> <program>`: the program of the package to run.
        #expect(MCP.line("npx -y -p @acme/tools@2.1.0 acme-mcp --verbose")
                == .package(MCPPackageRef(registry: .npm, name: "@acme/tools", version: "2.1.0", bin: "acme-mcp"), args: ["--verbose"]))
        #expect(MCP.line("npx --package=@acme/tools acme-mcp")
                == .package(MCPPackageRef(registry: .npm, name: "@acme/tools", bin: "acme-mcp"), args: []))
        #expect(MCP.line("uvx mcp-server-odoo") == .package(MCPPackageRef(registry: .pypi, name: "mcp-server-odoo"), args: []))
        #expect(MCP.line("uvx mcp-server-odoo==0.9.0 --transport stdio")
                == .package(MCPPackageRef(registry: .pypi, name: "mcp-server-odoo", version: "0.9.0"), args: ["--transport", "stdio"]))
        #expect(MCP.line("uvx mcp-server-odoo@latest") == .package(MCPPackageRef(registry: .pypi, name: "mcp-server-odoo"), args: []))
        #expect(MCP.line("uvx --from acme-tools acme-mcp --verbose")
                == .package(MCPPackageRef(registry: .pypi, name: "acme-tools", bin: "acme-mcp"), args: ["--verbose"]))
        #expect(MCP.line("pipx run acme-mcp serve") == .package(MCPPackageRef(registry: .pypi, name: "acme-mcp"), args: ["serve"]))
        #expect(MCP.line("notes-mcp") == .command(program: "notes-mcp"))
        // A program of the machine takes no argument, and a program that installs or runs other code is no program of
        // the machine: a package line, or nothing.
        for refused in ["", "npx", "npx -y", "npx -p notes-mcp", "npx Notes-MCP", "npx notes-mcp@next", "NPX -y notes-mcp",
                        "npx -y notes-mcp $HOME", "uvx --with acme acme-mcp", "uvx acme-mcp[cli]", "uvx --from acme-tools",
                        "pipx install acme-mcp", "pnpm notes-mcp", "npm exec notes-mcp", "yarn dlx notes-mcp",
                        "uv tool run acme-mcp", "docker run -i --rm acme/mcp", "/usr/local/bin/notes-mcp", "notes-mcp stdio",
                        "python3 -m acme_mcp", "node", "nodejs", "python3.12", "Python3", "bash", "sudo", "env", "go", "cargo",
                        "corepack", "nerdctl", "pnpx", "doas", "xargs", "osascript", "java", "pypy3", "node20", "php8.2"] {
            #expect(MCP.line(refused) == nil, "\(refused)")
        }
        for program in MCPRules.refusedCommands {
            #expect(MCP.refusedCommand(program) && MCP.refusedCommand(program.uppercased()), "\(program)")
        }
        #expect(MCP.refusedCommand("python3.12") && MCP.refusedCommand("python3.9") && !MCP.refusedCommand("python3.x"))
        #expect(!MCP.refusedCommand("notes-mcp") && !MCP.refusedCommand("python3-mcp") && !MCP.refusedCommand("gopher"))
        #expect(!MCP.refusedCommand("nodemon") && MCP.line("nodemon") == .command(program: "nodemon"))
    }

    /// **The message line says why**, for a line that a person writes with the best of reasons; a line that is only
    /// written wrong says it with its field's orange edge.
    @Test func theMessageLineSaysWhyALineIsRefused() {
        #expect(MCP.refusal(line: "docker run -i --rm acme/mcp") == .image)
        #expect(MCP.refusal(line: "podman run acme/mcp") == .image)
        for runner in ["npm exec acme-mcp", "yarn dlx acme-mcp", "bun x acme-mcp", "deno run npm:acme-mcp", "uv tool run acme-mcp",
                       "pip install acme-mcp", "pnpm install acme-mcp", "pipx install acme-mcp", "node server.js",
                       "python3 -m acme_mcp", "notes-mcp stdio"] {
            #expect(MCP.refusal(line: runner) == .runner, "\(runner)")
        }
        #expect(MCP.refusal(line: "npx -y acme-mcp --token tok-41f9c2b8") == .flag("--token"))
        for said in ["", "notes-mcp", "npx -y notes-mcp", "uvx mcp-server-odoo --transport stdio", "npx -y",
                     "uvx --with acme acme-mcp", "notes-mcp $HOME", "npx -y acme-mcp --token"] {
            #expect(MCP.refusal(line: said) == nil, "\(said)")
        }
        var draft = MCPDraft()
        draft.command = "docker run acme/mcp"
        #expect(draft.refusal == nil)                       // a remote server's form has no Program line
        draft.kind = .local
        #expect(draft.refusal == .image)
        #expect(MCPLineRefusal.image.words != MCPLineRefusal.runner.words)
    }

    @Test func thePasteSplitsItsEnvIntoSettingsAndKeys() throws {
        let draft = try #require(MCP.read(snippet: """
        {"mcpServers": {"odoo": {"command": "uvx", "args": ["mcp-server-odoo"],
                                 "env": {"ODOO_URL": "https://acme.example", "ODOO_DB": "acme", "ODOO_HOME": "${HOME}/odoo",
                                         "ODOO_API_KEY": "\(madeUpKey)", "ODOO_PASS": "acme-pass-41f9",
                                         "ODOO_AUTH_MODE": "basic", "ODOO_SERVER": "https://admin@acme.example",
                                         "SENTRY_DSN": "https://pub41f9@o1.ingest.example/1",
                                         "DATABASE_URL": "\(madeUpDatabase)",
                                         "NODE_OPTIONS": "--require ./x.js"}}}}
        """))
        #expect(draft.kind == .local && draft.package == MCPPackageRef(registry: .pypi, name: "mcp-server-odoo"))
        let settings = draft.variables.filter { !$0.isKey }, keys = draft.variables.filter(\.isKey)
        #expect(settings.map(\.name) == ["ODOO_DB", "ODOO_HOME", "ODOO_URL"])
        #expect(settings.map(\.value) == ["acme", "", "https://acme.example"])     // a value with $ is no plain value
        // A value is a setting only when it is plainly no secret: a name with a word of a secret, and an address with
        // a person in it, are keys, with no value.
        #expect(keys.map(\.name) == ["DATABASE_URL", "ODOO_API_KEY", "ODOO_AUTH_MODE", "ODOO_PASS", "ODOO_SERVER", "SENTRY_DSN"])
        #expect(keys.allSatisfy { $0.value.isEmpty && $0.named })
        #expect(!draft.variables.contains { $0.name == "NODE_OPTIONS" })           // a name that no server may have
        let written = String(describing: try #require(draft.server(features: features, resolved: odoo)).object)
        for value in ["41f9", "pw-", "admin", "basic"] { #expect(!written.contains(value), "\(value)") }
    }

    /// **One rule of a secret for every row**: a key's ending, or a word of its name that names a secret, split at `_`
    /// and where a lower case letter meets a capital (`lifecycle.secret_name`). A pick's
    /// setting and a row that he added with such a name are key rows too, and their value goes to the vault.
    @Test func oneRuleOfASecretForEveryRow() {
        for key in ["ODOO_API_KEY", "acme_token", "ACME_PAT", "API_KEY_ID", "DB_PASS", "DB_PWD", "OPENAI_APIKEY", "ACME_AUTH",
                    "SENTRY_DSN", "ACME_PRIVATE_URL", "GOOGLE_CREDENTIALS", "ACME_COOKIE", "ACME_PASSWD", "KEY", "ACME_BEARER",
                    "apiToken", "clientSecret", "dbPassword", "APIKey", "v2Token"] {
            #expect(MCP.isSecretName(key), "\(key)")
        }
        for plain in ["ODOO_URL", "ODOO_DB", "KEYBOARD", "ACME_TOKENIZER", "AUTHOR", "ACME_REGION", "PASSAGE", "monkey",
                      "odooUrl"] {
            #expect(!MCP.isSecretName(plain), "\(plain)")
        }
        #expect(MCPRules.keyEndings.allSatisfy { MCPRules.secretWords.contains(String($0.dropFirst())) })
        var added = MCPDraft()
        added.addSetting()
        added.variables[0].name = "ACME_AUTH"
        #expect(added.variables[0].isKey)
        added.variables[0].name = "ACME_REGION"
        #expect(!added.variables[0].isKey)
    }

    @Test func theHubsRefusedNamesAndValuesKeepAddOff() {
        for refused in ["NODE_OPTIONS", "node_env", "NODE", "PYTHONPATH", "pythonhome", "http_proxy", "HTTPS_PROXY", "LANG",
                        "LC_ALL", "TZ", "PATH", "HOME", "SHELL", "GIT_DIR", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "UV_INDEX_URL",
                        "PIP_INDEX_URL", "NPM_CONFIG_REGISTRY", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "FLEET_TOKEN",
                        "ANTHROPIC_API_KEY", "XAI_API_KEY", "BASH_ENV", "_JAVA_OPTIONS", "PS1", "1ODOO", "ODOO-URL", "",
                        String(repeating: "A", count: 61), "RUBYOPT", "rubylib", "SSLKEYLOGFILE", "SSL_CERT_DIR",
                        "GRPC_TRACE"] {
            #expect(MCP.settingName(refused) == nil, "\(refused)")
        }
        for taken in ["ODOO_URL", "odoo_db", "_ACME", "GITHUB_HOST", "NODEJS_ROOT", "UVICORN_HOST", "PYTH", "GRPCURL_ROOT",
                      "ACME_GH_TOKEN", "GH_TOKEN", "github_token", String(repeating: "A", count: 60)] {
            #expect(MCP.settingName(taken) == taken, "\(taken)")     // a program may read its key as GITHUB_TOKEN
        }
        // The session's own GitHub token is no name of a server's key (the hub's FLEET_KEYS), nor is a refused name.
        #expect(!MCP.isServerKey("GH_TOKEN") && !MCP.isServerKey("GITHUB_PERSONAL_ACCESS_TOKEN")
                && !MCP.isServerKey("NODE_AUTH_TOKEN") && MCP.isServerKey("GITHUB_TOKEN"))
        #expect(MCP.isServerKey("ACME_GH_TOKEN") && !MCP.isServerKey("acme_gh_token") && !MCP.isServerKey("ACME_REGION"))
        #expect(MCP.plainValue("") && MCP.plainValue("https://acme.example/odoo?db=acme") && MCP.plainValue("Café olé Ω")
                && MCP.plainValue(String(repeating: "a", count: 500)))
        for refused in ["$HOME", "${ODOO_KEY}", "{env:ODOO_KEY}", "x{file:/srv/key}",
                        "a\tb", "a\nb", "a\u{00A0}b", "a\u{200B}b", String(repeating: "a", count: 501),
                        "acme \u{1F642}", "a\u{10000}b", "postgres://acme" + ":pw-41f9@db.acme.example/acme",
                        "see https://acme" + ":pw@acme.example", "https://admin@acme.example",
                        "https://acme" + ":pw/41f9@acme.example"] {           // each address in two parts: see madeUpKey
            #expect(!MCP.plainValue(refused), "\(refused)")             // a user part, or a password, with a / too
        }
        #expect(MCP.plainValue("acme:eu@1") && MCP.plainValue("mailto:acme@acme.example")
                && MCP.plainValue("https://acme.example/@acme"))          // no user part of a URL
        // A row's value or name that the hub refuses keeps the server back.
        #expect(program("odoo-mcp", [MCPVariable(name: "ODOO_URL", value: "$ODOO")]).server(features: features) == nil)
        #expect(program("odoo-mcp", [MCPVariable(name: "ODOO_URL", value: "a"), MCPVariable(name: "ODOO_URL", value: "b")])
            .server(features: features) == nil)                                         // one name twice
        var added = program("odoo-mcp")
        added.addSetting()
        #expect(added.server(features: features) != nil)                                // an added row left empty is nothing
        added.variables[0].value = "eu"
        #expect(added.server(features: features) == nil)                                // a value needs its name
        added.variables[0].name = "NODE_ENV"
        #expect(added.server(features: features) == nil)
        added.variables[0].name = "ACME_REGION"
        #expect(added.server(features: features)?.settings == ["ACME_REGION": "eu"])
        // An added row with a key's name is a key: its value goes to the vault, never into the settings.
        added.variables[0].name = "acme_api_key"
        #expect(added.variables[0].isKey && added.server(features: features) == nil)   // "eu" is no key the vault takes
        added.variables[0].value = "acme-41f9c2b8"
        #expect(added.server(features: features)?.settings == [:] && added.keyValues.map(\.name) == ["acme_api_key"])
        for refused in ["short", "acme 41f9c2b8", "acme-41f9\tc2b8"] {
            added.variables[0].value = refused
            #expect(added.server(features: features) == nil, "\(refused)")
        }
        let many = (1...17).map { MCPVariable(name: "ACME_\($0)", value: "x") }
        #expect(program("odoo-mcp", many).server(features: features) == nil)
        #expect(program("odoo-mcp", Array(many.prefix(16))).server(features: features) != nil)
    }

    @Test func theServerHasItsPackageArgumentsSettingsAndEnv() throws {
        var draft = program("uvx mcp-server-odoo --transport stdio",
                            [MCPVariable(name: "ODOO_URL", value: " https://acme.example "), MCPVariable(name: "ODOO_DB", value: "acme"),
                             MCPVariable(name: "ODOO_YOLO"), MCPVariable(name: "ODOO_API_KEY", secret: true)])
        #expect(draft.server(features: features) == nil)                   // Add waits for the hub's version
        var server = try #require(draft.server(features: features, resolved: odoo))
        #expect(draft.keyValues.isEmpty)                                   // a key with no value goes nowhere
        draft.variables[3].value = "acme-odoo-41f9c2b8"
        #expect(draft.keyValues.map(\.name) == ["ODOO_API_KEY"] && draft.keyValues.map(\.value) == ["acme-odoo-41f9c2b8"])
        server.env = ["ODOO_API_KEY": "ACME_ODOO_KEY"]                      // what Add gives it once the key is in the vault
        let object = server.object
        #expect(object["title"] as? String == "Odoo" && object["command"] == nil && object["auth"] == nil)
        #expect(object["package"] as? [String: String]
                == ["registry": "pypi", "name": "mcp-server-odoo", "version": "0.9.0", "as_of": "2026-11-08"])
        #expect(object["args"] as? [String] == ["--transport", "stdio"])
        #expect(object["settings"] as? [String: String] == ["ODOO_URL": "https://acme.example", "ODOO_DB": "acme"])
        #expect(object["env"] as? [String: String] == ["ODOO_API_KEY": "ACME_ODOO_KEY"])
        #expect(!String(describing: object).contains("41f9c2b8"))           // the key goes to the vault, never into team.json
        // The version of another package, or another version than the line names, is no version of this one.
        let other = MCPPackageVersion(registry: "pypi", name: "mcp-server-acme", version: "0.9.0", as_of: "2026-11-08")
        #expect(draft.server(features: features, resolved: other) == nil)
        draft.command = "uvx mcp-server-odoo==0.8.0"
        #expect(draft.server(features: features, resolved: odoo) == nil)
        // The program of a package goes with it.
        let tools = MCPPackageVersion(registry: "pypi", name: "acme-tools", version: "2.1.0", as_of: "2026-11-08")
        let from = try #require(program("uvx --from acme-tools acme-mcp").server(features: features, resolved: tools))
        #expect(from.object["package"] as? [String: String]
                == ["registry": "pypi", "name": "acme-tools", "version": "2.1.0", "as_of": "2026-11-08", "bin": "acme-mcp"])
    }

    /// A hub without `mcp_packages` refuses every server with settings or a package, and a key whose variable has no
    /// key's ending: the form stays off for them there. A program of the machine takes no argument on any hub.
    @Test func anOlderHubGetsNoSettingsPackagesOrNewKeyNames() throws {
        let old = [MCP.feature]
        let plain = try #require(program("notes-mcp").server(features: old)).object
        #expect(plain["command"] as? String == "notes-mcp" && plain["args"] == nil && plain["settings"] == nil)
        #expect(program("notes-mcp stdio").server(features: old) == nil && program("notes-mcp stdio").server(features: features) == nil)
        let root = [MCPVariable(name: "NOTES_ROOT", value: "/srv/notes")]
        #expect(program("notes-mcp", root).server(features: old) == nil)
        #expect(program("notes-mcp", root).server(features: features)?.settings == ["NOTES_ROOT": "/srv/notes"])
        let npm = MCPPackageVersion(registry: "npm", name: "notes-mcp", version: "1.2.0", as_of: "2026-11-08")
        #expect(program("npx -y notes-mcp").server(features: old, resolved: npm) == nil)
        #expect(program("npx -y notes-mcp").server(features: features, resolved: npm) != nil)
        // A key is no new field: `env` is as old as the program servers, but the older hub takes only a variable that
        // has a key's name itself.
        let keyed = program("notes-mcp", [MCPVariable(name: "NOTES_TOKEN", value: "notes-41f9c2b8")])
        #expect(keyed.server(features: old) != nil && keyed.keyValues.count == 1)
        for own in ["NOTES_AUTH", "notes_token", "NOTES_DSN"] {
            let other = program("notes-mcp", [MCPVariable(name: own, value: "notes-41f9c2b8")])
            #expect(other.server(features: old) == nil && other.server(features: features) != nil, "\(own)")
        }
    }

    /// **The variable of a key on the Secrets page always begins with the server's name**, so no key is ever named as a
    /// variable that a session holds already (`GH_TOKEN`), then a number where the fleet has that name; always a key's
    /// name that the hub takes.
    @Test func aKeysVariableAlwaysBeginsWithTheServersName() {
        #expect(MCP.sessionVariable(for: "ODOO_API_KEY", server: "odoo", taken: []) == "ODOO_ODOO_API_KEY")
        #expect(MCP.sessionVariable(for: "ODOO_API_KEY", server: "acme-odoo", taken: ["ACME_ODOO_ODOO_API_KEY"])
                == "ACME_ODOO_2_ODOO_API_KEY")
        #expect(MCP.sessionVariable(for: "api_key", server: "acme", taken: []) == "ACME_API_KEY")
        #expect(MCP.sessionVariable(for: "DATABASE_URL", server: "acme", taken: []) == "ACME_DATABASE_URL_KEY")
        #expect(MCP.sessionVariable(for: "TOKEN", server: "gh", taken: []) == "GH_2_TOKEN")        // never GH_TOKEN
        #expect(MCP.sessionVariable(for: "XAI_API_KEY", server: "acme", taken: []) == "ACME_XAI_API_KEY")
        #expect(MCP.sessionVariable(for: MCP.remoteKey, server: "acme-crm", taken: []) == "ACME_CRM_KEY")
        #expect(MCP.sessionVariable(for: MCP.remoteKey, server: "acme-crm", taken: ["ACME_CRM_KEY"]) == "ACME_CRM_2_KEY")
        #expect(MCP.sessionVariable(for: "ODOO_API_KEY", server: "claude-tools", taken: []) == "MCP_CLAUDE_TOOLS_ODOO_API_KEY")
        #expect(MCP.sessionVariable(for: "API_KEY", server: "node-tools", taken: []) == "MCP_NODE_TOOLS_API_KEY")
        let long = String(repeating: "A", count: 52) + "_API_KEY"
        let cut = MCP.sessionVariable(for: long, server: "acme", taken: [])
        #expect(cut?.count == 60 && cut?.hasPrefix("ACME_") == true && cut?.hasSuffix("_API_KEY") == true)
        for own in ["ODOO_API_KEY", "api_key", "DATABASE_URL", "odoo_pass", "GH_TOKEN", long, MCP.remoteKey] {
            for server in ["odoo", "acme-odoo", "claude-tools", "gh", "git-hub", "node-tools", String(repeating: "a", count: 31)] {
                let head = server.uppercased().replacingOccurrences(of: "-", with: "_") + "_"
                let variable = MCP.sessionVariable(for: own, server: server, taken: [head + own.uppercased()])
                #expect(variable != nil && variable.map(MCP.isServerKey) == true, "\(own) \(server)")
                #expect(variable?.hasPrefix(head) == true || variable?.hasPrefix("MCP_" + head) == true, "\(own) \(server)")
                #expect(variable != own.uppercased(), "\(own) \(server)")
            }
        }
    }

    @Test func theRegistriesNamesAreTheHubs() {
        #expect(MCPRegistry.npm.takes("@modelcontextprotocol/server-filesystem") && MCPRegistry.npm.takes("notes-mcp"))
        for bad in ["Notes", "@Acme/x", "@acme/", "-x", "a b", ""] { #expect(!MCPRegistry.npm.takes(bad), "\(bad)") }
        #expect(MCPRegistry.pypi.takes("mcp-server-odoo") && MCPRegistry.pypi.takes("Acme.Tools_2"))
        for bad in ["-x", "x-", "a b", "x[cli]", ""] { #expect(!MCPRegistry.pypi.takes(bad), "\(bad)") }
        #expect(MCP.version("0.9.0") == "0.9.0" && MCP.version("2026.8.31") != nil && MCP.version("1.2rc1") != nil)
        for bad in ["v1.0", "latest", "", "1 0", "^1.2", "1.0\n"] { #expect(MCP.version(bad) == nil, "\(bad)") }
        #expect(MCPRegistry.npm.line("notes-mcp") == "npx -y notes-mcp" && MCPRegistry.pypi.line("mcp-server-odoo") == "uvx mcp-server-odoo")
    }

    @Test func aPackageVersionIsTheHubsAnswerForThatPackage() throws {
        let answer = try JSONDecoder().decode(MCPPackageVersion.self, from: Data("""
        {"ok": true, "request_id": "x", "client": "mac", "registry": "pypi", "name": "mcp-server-odoo", "version": "0.9.0",
         "as_of": "2026-11-08", "published": "2026-10-01", "newest": "1.0.0", "bins": []}
        """.utf8))
        #expect(answer.words == "0.9.0 · PyPI")
        let spec = try #require(answer.spec(for: MCPPackageRef(registry: .pypi, name: "mcp-server-odoo")))
        #expect(spec.version == "0.9.0" && spec.asOf == "2026-11-08" && spec.bin == nil)
        #expect(answer.spec(for: MCPPackageRef(registry: .npm, name: "mcp-server-odoo")) == nil)
        #expect(answer.spec(for: MCPPackageRef(registry: .pypi, name: "mcp-server-odoo", version: "1.0.0")) == nil)
        #expect(MCPPackageVersion(registry: "pypi", name: "mcp-server-odoo", version: "0.9.0", as_of: "08/11/2026")
            .spec(for: MCPPackageRef(registry: .pypi, name: "mcp-server-odoo")) == nil)
    }
}

@Suite("A flag that takes a secret")
struct MCPSecretFlagTests {
    /// lifecycle.flag_words and secret_flag: camelCase too, as the second review of round 3 asked.
    @Test func aFlagNamesASecretByAnyOfItsWords() {
        #expect(MCP.flagWords("--accessToken") == ["ACCESS", "TOKEN"])
        #expect(MCP.flagWords("--api_key") == ["API", "KEY"])
        #expect(MCP.flagWords("--readOnly") == ["READ", "ONLY"])
        for flag in ["--accessToken", "--apiToken", "--clientSecret", "--authorization", "--api-key", "--pass"] {
            #expect(MCP.isSecretFlag(flag), "\(flag)")
        }
        for flag in ["--path", "--readOnly", "--passthrough", "-p"] {
            #expect(!MCP.isSecretFlag(flag), "\(flag)")
        }
    }
}

@Suite("An MCP server's keys go with it")
struct MCPServerKeyTests {
    /// The owner, 15 November 2026: "Yes, give the keys too". Odoo needs two keys that the form made for it and one
    /// that the owner named himself; the shop's key is the one that another server of the agent may also need; the
    /// GitHub tool is Fleet's own.
    private func reading() throws -> IntegrationsSnapshot {
        try snapshot(tools: [
            "odoo": tool(["title": "Odoo", "needs": ["ODOO_ODOO_API_KEY", "ODOO_2_ODOO_DB_PASSWORD", "ACME_ODOO_KEY"]]),
            "shop": tool(["title": "Shop", "url": "https://shop.example.com/mcp", "auth": "key", "needs": ["SHOP_KEY"]]),
            "shop-admin": tool(["title": "Shop admin", "needs": ["SHOP_KEY"]]),
            "node-tools": tool(["title": "Node tools", "needs": ["MCP_NODE_TOOLS_API_KEY"]]),
            "crm": tool(["title": "Acme CRM", "url": "https://mcp.acme.example/", "auth": "oauth",
                         "needs": ["FLEET_MCP_CRM"]]),
            "github": ["title": "GitHub", "command": "github-mcp-server", "args": ["stdio"], "runtimes": ["claude", "codex"],
                       "custom": false, "auth": "none", "needs": ["GH_TOKEN"]]])
    }

    private static func reference(_ number: Int) -> String {
        "bws://\(number)\(number)\(number)\(number)\(number)\(number)\(number)\(number)-1111-4111-8111-111111111111"
    }

    private let logins: [String: TeamLogin] = [
        MCPServerKeyTests.reference(1): TeamLogin(title: "Odoo", protected: false, kind: "api_key", env: "ACME_ODOO_KEY", grants: ["dev": "read"]),
        MCPServerKeyTests.reference(2): TeamLogin(title: "Shop", protected: false, kind: "api_key", env: "SHOP_KEY", grants: ["dev": "read"]),
        MCPServerKeyTests.reference(3): TeamLogin(title: "acme.example · agent", protected: false, kind: "login", env: "ACME_ODOO_KEY", grants: [:]),
        MCPServerKeyTests.reference(4): TeamLogin(title: "ODOO_ODOO_API_KEY", protected: false, kind: "api_key", env: "ODOO_ODOO_API_KEY",
                                grants: ["dev": "read"]),
        MCPServerKeyTests.reference(5): TeamLogin(title: "ODOO_2_ODOO_DB_PASSWORD", protected: false, kind: "api_key",
                                env: "ODOO_2_ODOO_DB_PASSWORD", grants: ["dev": "use"]),
        MCPServerKeyTests.reference(6): TeamLogin(title: "GH_TOKEN", protected: false, kind: "api_key", env: "GH_TOKEN", grants: [:]),
        MCPServerKeyTests.reference(7): TeamLogin(title: "MCP_NODE_TOOLS_API_KEY", protected: false, kind: "api_key",
                                env: "MCP_NODE_TOOLS_API_KEY", grants: ["dev": "read"])]

    private func grants(_ server: String, _ agent: String = "dev", giving: Bool, _ agentTools: [String] = []) throws
        -> [(login: String, grant: SecretGrant?)] {
        MCPServerKeys.grants(server: server, agent: agent, giving: giving, tools: try #require(try reading().tools),
                             agentTools: agentTools, logins: logins)
    }

    @Test func givingAServerGivesItsKeysOfWhichTheAgentHoldsNoGrant() throws {
        // Ops holds none of Odoo's keys: each API key, in Odoo's order, and never the login of the same name.
        let ops = try grants("odoo", "ops", giving: true, ["odoo"])
        #expect(ops.map(\.login) == [Self.reference(4), Self.reference(5), Self.reference(1)])
        #expect(ops.allSatisfy { $0.grant == .read })
        // Dev reads two of them and uses the third: each stays as it is, and no use becomes a read.
        #expect(try grants("odoo", giving: true, ["odoo"]).isEmpty)
        #expect(try grants("shop", giving: true, ["shop"]).isEmpty)                    // dev reads it already
        #expect(try grants("crm", giving: true, ["crm"]).isEmpty)                      // Connect's token is Fleet's
        #expect(try grants("github", "ops", giving: true, ["github"]).isEmpty)         // Fleet's own tool: its GH_TOKEN
        #expect(try grants("ghost", giving: true).isEmpty)
    }

    @Test func takingAServerBackTakesOnlyTheKeysThatTheFormMadeForIt() throws {
        // Odoo's own key that dev reads goes; the one that dev only uses stays, and so does the key that the owner named.
        let odoo = try grants("odoo", giving: false)
        #expect(odoo.map(\.login) == [Self.reference(4)] && odoo.map(\.grant) == [nil])
        let shop = try grants("shop", giving: false, ["odoo"])
        #expect(shop.map(\.login) == [Self.reference(2)] && shop.map(\.grant) == [nil])
        #expect(try grants("shop", giving: false, ["shop-admin"]).isEmpty)            // another server needs it still
        #expect(try grants("shop", giving: false, ["github"]).map(\.login) == [Self.reference(2)])  // Fleet's tool needs no key
        let node = try grants("node-tools", giving: false)
        #expect(node.map(\.login) == [Self.reference(7)])                              // its name with MCP_ before it
        #expect(try grants("github", giving: false).isEmpty)
        #expect(try grants("odoo", "ops", giving: false).isEmpty)                      // ops never had them
    }

    /// **The form's own names of a server's keys**, as `MCP.sessionVariable` makes them, and no other name.
    @Test func theFormsOwnKeysOfAServerAreKnownByTheirNames() {
        for (variable, server) in [("ODOO_ODOO_API_KEY", "odoo"), ("ODOO_2_ODOO_API_KEY", "odoo"), ("ACME_CRM_KEY", "acme-crm"),
                                   ("ACME_CRM_2_KEY", "acme-crm"), ("MCP_NODE_TOOLS_API_KEY", "node-tools"),
                                   ("MCP_CLAUDE_TOOLS_KEY", "claude-tools"), ("GH_2_TOKEN", "gh")] {
            #expect(MCP.isFormKey(variable, of: server), "\(variable) \(server)")
        }
        for (variable, server) in [("ACME_ODOO_KEY", "odoo"), ("SHOP_KEY", "odoo"), ("MCP_ODOO_API_KEY", "odoo"),
                                   ("NODE_TOOLS_API_KEY", "node-tools"), ("ODOO_", "odoo"), ("GH_TOKEN", "gh"),
                                   ("ODOO_REGION", "odoo"), ("odoo_odoo_api_key", "odoo")] {
            #expect(!MCP.isFormKey(variable, of: server), "\(variable) \(server)")
        }
        for own in ["ODOO_API_KEY", "api_key", "DATABASE_URL", MCP.remoteKey] {
            for server in ["odoo", "acme-odoo", "claude-tools", "node-tools", "gh"] {
                let head = MCP.keyHead(server)
                for taken in [Set<String>(), [MCP.sessionVariable(for: own, server: server, taken: []) ?? ""]] {
                    let made = MCP.sessionVariable(for: own, server: server, taken: taken)
                    #expect(made.map { MCP.isFormKey($0, of: server) } == true, "\(own) \(server) \(head)")
                }
            }
        }
    }
}

/// Find a server (`mcp_find`): the hub's results, the form after a pick, and the two lookups, which write nothing.
struct MCPFindTests {
    private func findings() throws -> [MCPFound] {
        try JSONDecoder().decode(MCPFindings.self, from: Data("""
        {"ok": true, "request_id": "x", "client": "mac", "replayed": false, "more": false, "servers": [
         {"id": "com.acme/crm", "title": "Acme CRM", "publisher": "acme.example", "description": "Orders and stores",
          "version": "1.0.0", "kind": "remote", "url": "https://mcp.acme.example/mcp", "auth": "oauth",
          "transport": "streamable-http", "package": null, "settings": [], "keys": []},
         {"id": "com.acme/shop", "title": "Shop", "publisher": "shop.example", "description": "", "version": "2.0.0",
          "kind": "remote", "url": "https://shop.example.com/mcp", "auth": "key", "package": null, "settings": [], "keys": []},
         {"id": "io.github.acme/odoo", "title": "Odoo", "publisher": "github.com/acme", "description": "Odoo over XML-RPC",
          "version": "0.9.0", "kind": "program", "url": null, "auth": "none",
          "package": {"registry": "pypi", "name": "mcp-server-odoo", "version": "0.9.0"},
          "settings": [{"name": "ODOO_URL", "description": "The Odoo address", "required": true, "default": null},
                       {"name": "ODOO_YOLO", "description": "", "required": false, "default": "false"},
                       {"name": "ODOO_AUTH_MODE", "description": "", "required": false, "default": "basic"},
                       {"name": "NODE_OPTIONS", "description": "", "required": false, "default": null}],
          "keys": [{"name": "ODOO_API_KEY", "description": "An API key of Odoo", "required": true}]},
         {"id": "com.acme/notes", "title": "Notes", "publisher": "acme.example", "kind": "program",
          "package": {"registry": "npm", "name": "@acme/notes-mcp", "version": null}, "args": ["--transport", "stdio"]},
         {"id": "bad/args", "title": "Bad", "kind": "program", "package": {"registry": "npm", "name": "acme-mcp"},
          "args": ["--root", "/srv/my notes"]},
         {"id": "bad/one", "title": "Bad", "kind": "program", "package": {"registry": "cargo", "name": "x"}},
         {"id": "bad/two", "title": "Bad", "kind": "remote", "url": "http://mcp.acme.example/"},
         {"id": "bad/ip", "title": "Bad", "kind": "remote", "url": "https://192.0.2.10/mcp"},
         {"id": "bad/loopback", "title": "Bad", "kind": "remote", "url": "https://localhost/mcp"},
         {"id": "bad/local", "title": "Bad", "kind": "remote", "url": "https://mcp.acme.local/mcp"},
         {"id": "bad/internal", "title": "Bad", "kind": "remote", "url": "https://mcp.corp.internal/mcp"},
         {"id": "bad/sse", "title": "Bad", "kind": "remote", "url": "https://mcp.acme.example/sse", "transport": "sse"},
         {"id": "bad/sse-type", "title": "Bad", "kind": "remote", "url": "https://mcp.acme.example/sse", "type": "sse"},
         {"title": "No id"}]}
        """.utf8)).servers
    }

    @Test func aPickFillsTheForm() throws {
        let found = try findings()
        // A server that the form cannot take, or read, is left out, and the others stay: a remote one only at an https
        // address of a name in the DNS, over streamable HTTP.
        #expect(found.map(\.id) == ["com.acme/crm", "com.acme/shop", "io.github.acme/odoo", "com.acme/notes"])
        #expect(found[0].line == "acme.example · remote · Orders and stores" && !found[0].isProgram)
        #expect(found[1].line == "shop.example · remote")
        #expect(found[2].line == "github.com/acme · PyPI · Odoo over XML-RPC" && found[2].isProgram)
        #expect(found[3].line == "acme.example · npm")

        let crm = MCPDraft(found: found[0])
        #expect(crm.kind == .remote && crm.title == "Acme CRM" && crm.address == "https://mcp.acme.example/mcp" && crm.auth == .oauth)
        #expect(crm.isComplete(features: [MCP.feature]) && crm.picked && !MCPDraft().picked)
        var shop = MCPDraft(found: found[1])
        #expect(shop.auth == .key && !shop.isComplete(features: [MCP.feature]))     // its key, in its secure field
        shop.remoteKey = "shop-41f9c2b8"
        #expect(shop.isComplete(features: [MCP.feature]) && shop.keyValues.map(\.name) == [MCP.remoteKey])
        let odoo = MCPDraft(found: found[2])
        #expect(odoo.kind == .local && odoo.command == "uvx mcp-server-odoo")
        #expect(odoo.package == MCPPackageRef(registry: .pypi, name: "mcp-server-odoo"))    // the newest that is 7 days old
        // A setting whose name the one rule of a secret calls a key's is a key row, and its default is no key.
        #expect(odoo.variables.map(\.name) == ["ODOO_URL", "ODOO_YOLO", "ODOO_AUTH_MODE", "ODOO_API_KEY"])
        #expect(odoo.variables.map(\.value) == ["", "false", "", ""])
        #expect(odoo.variables.map(\.isKey) == [false, false, true, true])
        #expect(odoo.variables[0].about == "The Odoo address" && odoo.variables.allSatisfy(\.named))
        // The fixed values of a program's required arguments come after its package; one that the line cannot hold
        // as a word leaves the server out.
        let notes = MCPDraft(found: found[3])
        #expect(notes.command == "npx -y @acme/notes-mcp --transport stdio")
        #expect(notes.line == .package(MCPPackageRef(registry: .npm, name: "@acme/notes-mcp"), args: ["--transport", "stdio"]))
        // A host of the public DNS, read as the hub reads it: no brackets, no trailing dots, in lower case.
        for host in ["mcp.acme.example", "acme.example", "cafe.example", "acme.example.", "MCP.Acme.Example",
                     "0x7f.acme.example", "192.0.2.10.acme.example"] {
            #expect(MCP.isPublicHost(host), "\(host)")
        }
        for host in ["192.0.2.10", "192.0.2.10.", "127.1", "0x7f.1", "0x7f000001.0", "localhost", "localhost.", "mcp.localhost",
                     "acme.local", "acme.local.", "acme.internal", "::1", "[2001:db8::1]", "[::ffff:192.0.2.10]", "acme", "acme.",
                     "nas.lan", "printer.home.arpa", "wiki.intranet", "mcp.corp"] {
            #expect(!MCP.isPublicHost(host), "\(host)")
        }
    }

    /// A remote server of Find a server whose Connect finds no OAuth at all needs no sign-in: the hub's refusal says
    /// so with the code `no_oauth`, and an older hub in its own words; no other refusal does.
    @Test func aConnectThatFindsNoOAuthMeansNoSignIn() {
        let coded = MCPClient.refusal(502, Data("""
        {"error": "the MCP server acme gave no OAuth endpoints: this MCP server has no OAuth metadata", "why": ["no_oauth"]}
        """.utf8))
        #expect(coded as? MCPRefusal == MCPRefusal(status: 502, words: "the MCP server acme gave no OAuth endpoints: this MCP "
                                                                         + "server has no OAuth metadata", why: ["no_oauth"]))
        #expect(MCP.hasNoOAuth(coded) && coded.localizedDescription.hasPrefix("the MCP server acme"))
        #expect(!MCP.hasNoOAuth(MCPRefusal(status: 502, words: "has no OAuth metadata", why: ["other"])))
        // A refusal with no code, or with a code that is no list, is one as every client reads it.
        let plain = MCPClient.refusal(409, Data("{\"error\": \"hub generation changed\", \"why\": \"busy\"}".utf8))
        if case HubError.refusal(let refused) = plain, refused.status == 409 {
            #expect(refused.hubWords == "hub generation changed")
        } else {
            Issue.record("a refusal with no list of codes is a hub refusal")
        }
        if case HubError.refusal(let refused) = MCPClient.refusal(500, Data("not json".utf8)), refused.status == 500 {
            #expect(refused.hubWords == HubError.unexplained)
        } else {
            Issue.record("a body that is no JSON is a hub refusal")
        }
        // An older hub: its words.
        #expect(MCP.hasNoOAuth(HubError.refusal(HubRefusal(status: 502, hubWords: "the MCP server acme gave no OAuth "
            + "endpoints: this MCP server has no OAuth metadata: it needs no Connect, or it is not an OAuth server"))))
        #expect(!MCP.hasNoOAuth(HubError.refusal(HubRefusal(status: 502, hubWords: "the MCP server acme refused a new "
                                                                                    + "client: no client_id"))))
        #expect(!MCP.hasNoOAuth(HubError.refusal(HubRefusal(status: 409, hubWords: "has no OAuth metadata"))))
        // A new hub gives a code: its words, which can hold the server's own text, decide nothing.
        #expect(!MCP.hasNoOAuth(HubError.refusal(HubRefusal(status: 502, hubWords: "the MCP server acme gave no OAuth "
            + "endpoints: the OAuth metadata of this MCP server cannot be read now: has no OAuth metadata",
            code: "mcp_no_endpoints"))))
        #expect(!MCP.hasNoOAuth(URLError(.timedOut)))
    }

    @Test func theSearchAndTheLookupAreCommandsThatWriteNothing() throws {
        #expect(try sent(.find(words: "odoo")) as? [String: String] == ["request_id": requestID, "db": "db", "words": "odoo"])
        #expect(try sent(.package(MCPPackageRef(registry: .pypi, name: "mcp-server-odoo"))) as? [String: String]
                == ["request_id": requestID, "db": "db", "registry": "pypi", "name": "mcp-server-odoo"])
        #expect(try sent(.package(MCPPackageRef(registry: .npm, name: "notes-mcp", version: "1.2.0")))["version"] as? String == "1.2.0")
        let find = MCPCommand.find(words: "odoo"), lookup = MCPCommand.package(MCPPackageRef(registry: .npm, name: "notes-mcp"))
        #expect(find.route == "ui/mcp/find" && lookup.route == "ui/mcp/package")
        #expect(!find.changes && !lookup.changes && MCPCommand.disconnect(name: "crm").changes)
        #expect(MCP.findWords("  odoo erp ") == "odoo erp" && MCP.findWords("acme/notes@1") == "acme/notes@1")
        for bad in ["", "   ", "@acme", "odoo; rm", String(repeating: "a", count: 61)] { #expect(MCP.findWords(bad) == nil, "\(bad)") }
    }
}
