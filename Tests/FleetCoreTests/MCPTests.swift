import Foundation
import Testing
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
                    "ftp://mcp.example.com/", "https://", "", "https://a b/", String(repeating: "x", count: 400)] {
            #expect(MCP.address(bad) == nil, "\(bad)")
        }
        #expect(MCP.program("notes-mcp stdio")?.program == "notes-mcp")
        #expect(MCP.program("notes-mcp stdio --root /tmp")?.args == ["stdio", "--root", "/tmp"])
        for bad in ["", "/usr/bin/notes", "notes-mcp | tee x", "notes-mcp $HOME", "notes-mcp 'a b'",
                    "notes-mcp " + Array(repeating: "a", count: 17).joined(separator: " ")] {
            #expect(MCP.program(bad) == nil, "\(bad)")
        }
        #expect(MCP.variable(" acme_crm_key ") == "ACME_CRM_KEY" && MCP.variable("SHOP_KEY") == "SHOP_KEY")
        for bad in ["", "1KEY", "FLEET_X", "PATH", "CLAUDE_CODE", "A-B"] { #expect(MCP.variable(bad) == nil, "\(bad)") }
    }

    @Test func theFormGivesTheServerThatTheHubTakes() throws {
        var draft = MCPDraft()
        #expect(!draft.isComplete && draft.auth == .oauth && draft.kind == .remote)
        draft.title = "Acme CRM"
        draft.address = "mcp.acme.example"
        #expect(draft.isComplete && draft.name == "acme-crm")
        #expect(try #require(draft.server).object as? [String: String]
                == ["title": "Acme CRM", "url": "https://mcp.acme.example", "auth": "oauth"])
        draft.auth = .key
        #expect(!draft.isComplete)                                  // a key server needs its variable name
        draft.key = "acme_crm_key"
        #expect(try #require(draft.server).object as? [String: String]
                == ["title": "Acme CRM", "url": "https://mcp.acme.example", "auth": "key", "key": "ACME_CRM_KEY"])
        draft.auth = .none
        #expect(try #require(draft.server).object as? [String: String]
                == ["title": "Acme CRM", "url": "https://mcp.acme.example"])

        var program = MCPDraft()
        program.title = "Notes"
        program.kind = .local
        program.choices.forEach { #expect($0 != .oauth) }           // a program has no Connect
        program.command = "notes-mcp stdio"
        var object = try #require(program.server).object
        #expect(object["command"] as? String == "notes-mcp" && object["args"] as? [String] == ["stdio"])
        #expect(object["auth"] == nil && object["env"] == nil)
        program.auth = .key
        program.key = "NOTES_KEY"
        object = try #require(program.server).object
        #expect(object["env"] as? [String: String] == ["NOTES_KEY": "NOTES_KEY"])
        program.variable = "notes_token"
        #expect(try #require(program.server).object["env"] as? [String: String] == ["NOTES_TOKEN": "NOTES_KEY"])
    }

    @Test func eachWriteHasItsCommandFieldsAndNoSecret() throws {
        let server = try #require({ () -> MCPServerSpec? in
            var draft = MCPDraft()
            draft.title = "Acme CRM"
            draft.address = "https://mcp.acme.example/"
            return draft.server
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
        #expect(remote.isComplete)

        let program = try #require(MCP.read(snippet: """
        {"mcpServers": {"notes": {"command": "npx", "args": ["-y", "notes-mcp"],
                                  "env": {"NOTES_TOKEN": "sk-live-41f9c2b8"}}}}
        """))
        #expect(program.kind == .local && program.command == "npx -y notes-mcp")
        #expect(program.title == "notes")
    }

    /// The one that matters: a snippet usually carries a real token, and this app holds no key. The variable's name
    /// is kept, because the program reads it; the value is dropped.
    @Test func aPastedKeyIsNeverKept() throws {
        let snippet = """
        {"mcpServers": {"notes": {"command": "notes-mcp", "env": {"NOTES_TOKEN": "sk-live-41f9c2b8"}}}}
        """
        let draft = try #require(MCP.read(snippet: snippet))
        #expect(draft.variable == "NOTES_TOKEN")        // what the program reads
        #expect(draft.key.isEmpty)                      // which API key goes in it stays the owner's choice
        for field in [draft.title, draft.address, draft.command, draft.key, draft.variable] {
            #expect(!field.contains("sk-live"), "a pasted key reached \(field)")
        }
        // And nothing of the value reaches the hub either.
        draftCarriesNoValue(draft)
    }

    private func draftCarriesNoValue(_ draft: MCPDraft) {
        guard var draft = Optional(draft) else { return }
        draft.key = "NOTES_KEY"
        guard let server = draft.server else { return }
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
}
