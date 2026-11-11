import Foundation
import Testing
@testable import FleetCore

// What one person may use of an agent (the person access plan, owner feature `person_scope`): the `scope` of a row of a
// person's agents in `GET /ui/people` (UI-API.md, "agents[].scope"), and the `scopes` of `POST /ui/people`.

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

/// One agent of a person's list as the hub sends it, with `scope` as given, or without the key for nil.
private func row(_ scope: Any?) throws -> PeopleSnapshot.PersonAgent {
    var object: [String: Any] = ["agent": "dev", "can_chat": true, "says": NSNull()]
    if let scope { object["scope"] = scope }
    return try JSONDecoder().decode(PeopleSnapshot.PersonAgent.self, from: json(object))
}

private var crm: [String: Any] {
    ["resource": "repo:exampleowner/abc-crm", "title": "exampleowner/abc-crm", "level": "write", "held": true]
}

struct PersonScopeDecodeTests {
    /// No key is no select (no list can hold there, or an older hub); null is All; a list is the list, with the entries
    /// that the agent does not hold now kept apart.
    @Test func theScopeOfARowIsAbsentAllOrTheList() throws {
        #expect(try row(nil).scope == nil)
        let all = try #require(try row(NSNull()).scope)
        #expect(all == .all && all.isAll && all.list.isEmpty && all.entries.isEmpty && all.short == nil)
        let gone: [String: Any] = ["resource": "secret:bws://1111", "title": "ABC_API_TOKEN", "level": "use", "held": false]
        let only = try #require(try row([crm, gone]).scope)
        #expect(!only.isAll && only.entries.count == 2)
        #expect(only.entries.map(\.kind) == ["repo", "secret"] && only.entries[0].what == "exampleowner/abc-crm")
        #expect(only.entries[1].held == false && only.entries[1].title == "ABC_API_TOKEN")
        // What the agent no longer holds is not drawn and not written: the page's list leaves it out.
        #expect(only.list == ["repo:exampleowner/abc-crm": "write"])
        // An empty list is a list: the person talks with the agent and gets nothing of it.
        let empty = try #require(try row([] as [Any]).scope)
        #expect(empty == .only([]) && !empty.isAll && empty.list.isEmpty && empty.short == nil)
    }

    /// A newer or older hub never fails the read: a `scope` of a shape that this app cannot read is no select, so the app
    /// never writes over a list that it cannot read, and an entry's words and `held` read leniently.
    @Test func aScopeOfAnotherShapeIsNoSelectAndTheReadStillWorks() throws {
        #expect(try row("everything").scope == nil)
        #expect(try row(["repo:a/b": "read"]).scope == nil)
        #expect(try row([["title": "a/b", "level": "read"]]).scope == nil)               // no resource
        #expect(try row([["resource": "a/b", "level": "read"]]).scope == nil)           // no kind
        #expect(try row([["resource": "repo:a/b", "level": 2]]).scope == nil)           // no level
        let bare = try #require(try row([["resource": "repo:acme/web", "level": "read"]]).scope)
        #expect(bare.entries == [PersonScope.Entry(resource: "repo:acme/web", title: "acme/web", level: "read", held: true)])
        // The whole person reads, with the row that this app cannot read beside one it can.
        let person: [String: Any] = [
            "id": 7, "name": "África", "role": "peer", "role_means": "A colleague.", "note": NSNull(), "daily": NSNull(),
            "daily_set": NSNull(), "blocked": NSNull(), "added": 1000.0, "today": 0,
            "agents": [["agent": "dev", "can_chat": true, "says": NSNull(), "scope": [crm]],
                       ["agent": "web", "can_chat": false, "says": "Web waits.", "scope": 42],
                       ["agent": "ops", "can_chat": true, "says": NSNull()]],
            "handles": [], "conversations": []]
        let read = try JSONDecoder().decode(PeopleSnapshot.Person.self, from: json(person))
        let expected: [PersonScope?] = [PersonScope.only([PersonScope.Entry(resource: "repo:exampleowner/abc-crm",
                                                                            title: "exampleowner/abc-crm", level: "write",
                                                                            held: true)]), nil, nil]
        #expect(read.agents.map(\.scope) == expected)
        #expect(read.unreachable.map(\.says) == ["Web waits."])
    }

    /// The select's words while a list is set: a repository without its owner, a secret by its name, two short names
    /// both, else the first one and how many more; only what the agent holds now.
    @Test func theListInAFewWords() throws {
        func scope(_ entries: [[String: Any]]) throws -> PersonScope { try #require(try row(entries).scope) }
        let secret: [String: Any] = ["resource": "secret:bws://2222", "title": "ABC_API_TOKEN", "level": "use", "held": true]
        let web: [String: Any] = ["resource": "repo:acme/web", "title": "acme/web", "level": "read", "held": true]
        let password: [String: Any] = ["resource": "secret:bws://3333", "title": "ABC_CLICKHOUSE_READ_PASSWORD",
                                       "level": "use", "held": true]
        #expect(try scope([crm]).short == "abc-crm")
        #expect(try scope([secret]).short == "ABC_API_TOKEN")
        #expect(try scope([crm, web]).short == "abc-crm, web")
        #expect(try scope([crm, secret]).short == "abc-crm, ABC_API_TOKEN")
        #expect(try scope([crm, password]).short == "abc-crm and 1 more")
        #expect(try scope([crm, web, secret]).short == "abc-crm and 2 more")
        var lost = crm
        lost["held"] = false
        #expect(try scope([lost, secret]).short == "ABC_API_TOKEN")
        #expect(try scope([lost]).short == nil)
        let long: [String: Any] = ["resource": "repo:acme/a-repository-with-a-very-long-name", "level": "read"]
        #expect(try scope([long]).short == "a-repository-with-a-very-lo…")
    }
}

struct PersonScopeWriteTests {
    /// The agent's own levels bound what a list gives: Read only for an agent at Read, and Write at most, also for an
    /// agent at Deploy. A secret's are Use and Read.
    @Test func aListGivesNoLevelAboveTheAgentsOwnAndNeverDeploy() {
        #expect(PersonScope.levels("repo", agentHas: "read") == ["read"])
        #expect(PersonScope.levels("repo", agentHas: "write") == ["read", "write"])
        #expect(PersonScope.levels("repo", agentHas: "deploy") == ["read", "write"])
        #expect(PersonScope.levels("repo", agentHas: "admin").isEmpty)
        #expect(PersonScope.levels("secret", agentHas: "use") == ["use"])
        #expect(PersonScope.levels("secret", agentHas: "read") == ["use", "read"])
        #expect(PersonScope.level("write", kind: "repo", agentHas: "read") == "read")
        #expect(PersonScope.level("deploy", kind: "repo", agentHas: "deploy") == "write")
        #expect(PersonScope.level("read", kind: "secret", agentHas: "use") == "use")
        #expect(PersonScope.level("use", kind: "secret", agentHas: "read") == "use")
        #expect(PersonScope.level("owner", kind: "repo", agentHas: "write") == nil)
    }

    /// What a change sends: each repository and secret that the agent holds, at the lower of the two levels; one that
    /// it does not hold left out, since the hub refuses it with 400; a kind that the page does not draw as it was.
    @Test func aChangeWritesWhatTheAgentHoldsAtTheLevelsTheHubTakes() {
        let holdings = ["repo:exampleowner/abc-crm": "deploy", "repo:acme/web": "read", "secret:bws://1111": "use",
                        "secret:bws://2222": "read"]
        let list = ["repo:exampleowner/abc-crm": "write", "repo:acme/web": "write", "repo:acme/gone": "read",
                    "secret:bws://1111": "read", "secret:bws://2222": "read", "secret:bws://3333": "use",
                    "drive:a@b.com": "read"]
        #expect(PersonScope.written(list, holdings: holdings) == [
            "repo:exampleowner/abc-crm": "write", "repo:acme/web": "read", "secret:bws://1111": "use",
            "secret:bws://2222": "read", "drive:a@b.com": "read"])
        #expect(PersonScope.written([:], holdings: holdings).isEmpty)
    }

    /// The body of `POST /ui/people`: the person, and `scopes` with the one agent, whose null is All and whose empty
    /// object is a list with nothing in it.
    @Test func theWriteNamesOneAgentWithNullForAll() throws {
        func body(_ list: [String: String]?) throws -> [String: Any] {
            let data = try IntegrationsClient.body(PersonScope.fields(person: 7, agent: "dev", list: list),
                                                   requestID: "r-1", database: "g1")
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let all = try body(nil)
        #expect(Set(all.keys) == ["id", "scopes", "request_id", "db"])
        #expect(all["id"] as? Int == 7 && all["request_id"] as? String == "r-1" && all["db"] as? String == "g1")
        let scopes = try #require(all["scopes"] as? [String: Any])
        #expect(Set(scopes.keys) == ["dev"] && scopes["dev"] is NSNull)
        let only = try #require(try body(["repo:exampleowner/abc-crm": "write", "secret:bws://1111": "use"])["scopes"]
            as? [String: Any])
        #expect(only["dev"] as? [String: String] == ["repo:exampleowner/abc-crm": "write", "secret:bws://1111": "use"])
        let empty = try #require(try body([:])["scopes"] as? [String: Any])
        #expect(empty["dev"] as? [String: String] == [:])
    }

    /// The page's rows: what the agent holds of the two kinds that a list names, at its own level, by resource.
    @Test func theRowsAreTheRepositoriesAndSecretsThatTheAgentHolds() {
        func resource(_ id: String, _ holders: [ResourceHolder]) -> FleetResource {
            let kind = PersonScope.kind(of: id)
            return FleetResource(id: id, kind: kind, what: String(id.dropFirst(kind.count + 1)), title: id, needs: "",
                                 levels: [], uses: [], credential: "none", connected: true, grant: nil, holders: holders)
        }
        let reading = ResourceList(db: "g1", revision: nil, sha256: String(repeating: "a", count: 64), audience: "workers",
                                   limit: 100, kinds: [], resources: [
                                       resource("repo:exampleowner/abc-crm", [.init(agent: "dev", level: "deploy")]),
                                       resource("repo:acme/web", [.init(agent: "web", level: "write")]),
                                       resource("secret:bws://1111", [.init(agent: "dev", level: "use"),
                                                                      .init(agent: "web", level: "read")]),
                                       resource("tool:crm", [.init(agent: "dev", level: "use")]),
                                       resource("gmail:a@b.com", [.init(agent: "dev", level: "send")])])
        #expect(reading.scopeHoldings(of: "dev") == ["repo:exampleowner/abc-crm": "deploy", "secret:bws://1111": "use"])
        #expect(reading.scopeHoldings(of: "web") == ["repo:acme/web": "write", "secret:bws://1111": "read"])
        #expect(reading.scopeHoldings(of: "ops").isEmpty)
    }
}

struct PersonDailyWordsTests {
    /// "Messages a day" with no number to count against shows no limit, never "of 0"; the owner's own number counts
    /// where the hub's does not only for a person with a list (an agent that this person has a list with, also an
    /// empty one), and an owner's own 0 is a limit.
    @Test func aDayWithNoNumberShowsNoLimit() throws {
        func person(daily: Int?, set: Int?, scope: Any? = nil) throws -> PeopleSnapshot.Person {
            let agents: [[String: Any]] = scope.map { [["agent": "dev", "can_chat": true, "says": NSNull(), "scope": $0]] } ?? []
            return try JSONDecoder().decode(PeopleSnapshot.Person.self, from: json([
                "id": 1, "name": "África", "role": "peer", "role_means": NSNull(), "note": NSNull(),
                "daily": daily.map { $0 as Any } ?? NSNull(), "daily_set": set.map { $0 as Any } ?? NSNull(),
                "blocked": NSNull(), "added": 1000.0, "today": 2, "agents": agents, "handles": [], "conversations": []]))
        }
        #expect(try person(daily: nil, set: nil).todayWords == "2 today")
        #expect(try person(daily: nil, set: nil).dailyLimit == nil)
        #expect(try person(daily: 30, set: nil).todayWords == "2 today of 30")
        #expect(try person(daily: nil, set: 20).todayWords == "2 today")
        #expect(try person(daily: nil, set: 20, scope: NSNull()).todayWords == "2 today")
        #expect(try person(daily: nil, set: 20, scope: [Any]()).todayWords == "2 today of 20")
        #expect(try person(daily: 0, set: 0).todayWords == "2 today of 0")
    }
}
