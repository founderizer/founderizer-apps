using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Owner.Tests;

/// <summary>**The owner's reads of servers, machines and the team** (piece L4), with the checks of the Mac's decoders,
/// and the writes of the agent setup with the checks of their receipts.</summary>
[TestClass]
public sealed class ReadsTests
{
    private const string Db = "db-1";

    private sealed class Calls(Func<string, string> answer) : OwnerReads.ICalls
    {
        public List<(string Route, string Body)> Posts { get; } = [];
        public string? Database => Db;

        public Task<OwnerAnswer<T>> GetAsync<T>(string route, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type, int limit,
                                                CancellationToken cancel) where T : class =>
            Task.FromResult(new OwnerAnswer<T>(JsonSerializer.Deserialize(answer(route), type)));

        public Task<OwnerAnswer<TAnswer>> PostAsync<TBody, TAnswer>(string route, TBody body,
            System.Text.Json.Serialization.Metadata.JsonTypeInfo<TBody> bodyType,
            System.Text.Json.Serialization.Metadata.JsonTypeInfo<TAnswer> answerType, Guid? requestId,
            CancellationToken cancel) where TAnswer : class
        {
            Posts.Add((route, JsonSerializer.Serialize(body, bodyType)));
            return Task.FromResult(new OwnerAnswer<TAnswer>(JsonSerializer.Deserialize(answer(route).Replace("REQUEST", requestId!.Value.ToString("D")), answerType)));
        }
    }

    private const string Servers = """
        {"db": "db-1", "time": 1763700100, "hub_shared": true, "shape": {"step": "one"},
         "join": {"name": "", "kind": "linux", "created": 1763700000, "expires_at": 1763703600, "state": "open"},
         "servers": [{"name": "worker-1", "hub": true, "joined": true, "agents": ["juno"], "available": false, "why": ["has_agent"],
                      "load": "not a load", "access": {"ssh": null},
                      "job": {"id": 5000000000, "kind": "install", "agent": "juno", "state": "running", "step": "runtime",
                              "created": 1763700000, "updated": 1763700050, "steps": 7, "code": ["x"]}}]}
        """;

    /// <summary>**A list of servers decodes as the Mac's**: a field that the Mac reads with <c>try?</c> of another type
    /// is no failure, a job's id above 32 bits reads, the kept step and the agent's server are read. Bug: a later hub's
    /// field of another type that fails the whole list, so that the PC's setup shows nothing.</summary>
    [TestMethod]
    public async Task A_list_of_servers_decodes_as_the_Macs_and_its_try_fields_never_fail_it()
    {
        var list = (await OwnerReads.ServersAsync(new Calls(_ => Servers))).Value!;
        Assert.AreEqual("one", list.KeptStep);
        Assert.AreEqual("worker-1", list.ServerOf("juno")?.Name);
        Assert.AreEqual(5000000000L, list.Servers[0].Job!.Id);
        Assert.IsNull(list.Servers[0].Job!.StepList, "a list of steps of another type is none");
        Assert.IsTrue(list.Join!.IsOf("", "linux", 1763703600));
    }

    /// <summary>**The checks of a list**: another generation, two servers of one name, a name of no known shape. Bug: a
    /// list of another fleet's generation taken for this one, whose servers the setup would place the manager on.</summary>
    [TestMethod]
    public async Task A_list_that_the_Mac_refuses_is_refused()
    {
        foreach (var (name, json) in new[]
                 {
                     ("another generation", Servers.Replace("\"db-1\"", "\"db-2\"")),
                     ("two servers of one name", Servers.Replace("\"servers\": [{", "\"servers\": [{\"name\": \"worker-1\", \"hub\": false, \"joined\": true, \"agents\": [], \"available\": true, \"why\": []}, {")),
                     ("a name of no shape", Servers.Replace("\"worker-1\"", "\"worker 1\"")),
                 })
            await Assert.ThrowsExactlyAsync<HubException>(() => OwnerReads.ServersAsync(new Calls(_ => json)), name);
        await Assert.ThrowsExactlyAsync<JsonException>(() => OwnerReads.ServersAsync(new Calls(_ => Servers.Replace("\"joined\": true, ", ""))),
                                                       "a field that the Mac requires");
    }

    private const string Machines = """
        {"db": "db-1", "desired_revision": "abc", "machines": [
          {"agent": "juno", "machine": "worker-1", "role": "manager", "update": {"state": "current"}, "security": {},
           "runtime": {"name": "claude", "signed_in": false}, "os": {}, "reported_at": 1763700000,
           "runtimes": {"codex": {"signed_in": true}, "grok": {"signed_in": "yes"}},
           "check": {"id": 3, "state": "completed", "requested_at": 1763700000, "completed_at": 1763700010},
           "login": {"id": 7, "runtime": "claude", "state": "needs_owner", "started_at": 1763700000, "updated_at": 1763700060,
                     "wants_code": true, "url": "https://claude.ai/oauth/authorize?code=true"}}]}
        """;

    /// <summary>**A list of machines decodes, with its sign-in and its readings of each provider.** Bug: an entry of
    /// <c>runtimes</c> of another form that fails the list, or that reads as a provider signed in.</summary>
    [TestMethod]
    public async Task A_list_of_machines_decodes_with_its_sign_in_and_its_providers()
    {
        var list = (await OwnerReads.MachinesAsync(new Calls(_ => Machines))).Value!;
        var juno = list.Of("juno")!;
        Assert.AreEqual(false, juno.SignedIn("claude"));
        Assert.AreEqual(true, juno.SignedIn("codex"));
        Assert.IsNull(juno.SignedIn("grok"), "an entry that the Mac's Failable drops says nothing");
        Assert.AreEqual(new Uri("https://claude.ai/oauth/authorize?code=true"), juno.Login!.SignInUrl);
        Assert.IsTrue(juno.Login.WaitsForCode);
        Assert.IsFalse(juno.Login.ToString().Contains("claude.ai", StringComparison.Ordinal), "its text names no link");
        await Assert.ThrowsExactlyAsync<HubException>(() => OwnerReads.MachinesAsync(new Calls(_ => Machines.Replace("\"completed_at\": 1763700010", "\"completed_at\": 1"))),
                                                      "a check that ended before it was asked");
    }

    private const string Team = """
        {"db": "db-1", "revision": "0123456789abcdef0123456789abcdef01234567",
         "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
         "open_tasks": {"juno": 1},
         "lines": [{"agent": "juno", "role": "manager", "reports_to": null, "placement": {"machine": null, "runtime": "claude"}},
                   {"agent": "ada", "role": "worker", "reports_to": "juno"}]}
        """;

    /// <summary>**The team decodes, and lines that are no team are refused, in the Mac's words.** Bug: a team with two
    /// managers, a loop, or a worker that reports to a worker, taken as the base of a move.</summary>
    [TestMethod]
    public async Task The_team_decodes_and_lines_that_are_no_team_are_refused()
    {
        var team = (await OwnerReads.TeamAsync(new Calls(_ => Team))).Value!;
        Assert.AreEqual("juno", team.Manager!.Agent);
        Assert.AreEqual("claude", team.LineOf("juno")!.Placement!.Runtime);
        TeamLine Line(string agent, string role, string? to) => new(agent, role, to);
        Assert.AreEqual("The team must have one manager.", TeamReading.LinesProblem([Line("a", "worker", "b"), Line("b", "worker", "a")]));
        Assert.AreEqual("Each agent must report to the manager or a lead.", TeamReading.LinesProblem([Line("m", "manager", null), Line("a", "worker", "b"), Line("b", "worker", "m")]));
        Assert.AreEqual("Reporting lines cannot form a loop.", TeamReading.LinesProblem([Line("m", "manager", null), Line("a", "lead", "b"), Line("b", "lead", "a")]));
        Assert.AreEqual("The team contains an invalid or repeated agent.", TeamReading.LinesProblem([Line("m", "manager", null), Line("m", "worker", "m")]));
        Assert.IsNull(TeamReading.LinesProblem([Line("m", "manager", null), Line("l", "lead", "m"), Line("w", "worker", "l")]));
        await Assert.ThrowsExactlyAsync<HubException>(() => OwnerReads.TeamAsync(new Calls(_ => Team.Replace("{\"juno\": 1}", "{\"zed\": 1}"))),
                                                      "an open count of an agent with no line");
    }

    /// <summary>**The writes of the agent setup send what the Mac sends, and their receipts are checked.** Bug: a move
    /// whose answer names another server taken as done, or a code sent that is no code.</summary>
    [TestMethod]
    public async Task The_writes_of_the_agent_setup_send_the_Macs_fields_and_check_their_receipts()
    {
        var calls = new Calls(route => route switch
        {
            "ui/servers/join" => """{"ok": true, "request_id": "REQUEST", "name": "", "kind": "linux", "expires_at": 1763703600, "code": "7KMQ2PRJ4TVW", "line": "curl …"}""",
            "ui/team/agents/juno/move" => """{"ok": true, "request_id": "REQUEST", "agent": "juno", "server": "worker-2", "runtime": "claude", "job": 9, "revision": "r", "sha256": "s"}""",
            _ => """{"ok": true, "request_id": "REQUEST"}""",
        });
        var join = (await OwnerReads.JoinCodeAsync(calls)).Value!;
        Assert.IsFalse(join.ToString().Contains("7KMQ", StringComparison.Ordinal), "its text names no code");
        Assert.AreEqual("{\"kind\":\"linux\"}", calls.Posts[0].Body);
        await OwnerReads.MoveAsync(calls, "juno", new string('a', 64), "worker-2", "claude");
        Assert.AreEqual("{\"base_sha256\":\"" + new string('a', 64) + "\",\"server\":\"worker-2\",\"runtime\":\"claude\"}", calls.Posts[1].Body);
        await Assert.ThrowsExactlyAsync<HubException>(() => OwnerReads.MoveAsync(calls, "juno", new string('a', 64), "worker-3", "claude"));
        await OwnerReads.SignInAsync(calls, "juno", "claude");
        Assert.AreEqual(("ui/machines/juno/signin", "{\"runtime\":\"claude\",\"replace\":false}"), calls.Posts[3]);
        await Assert.ThrowsExactlyAsync<ArgumentException>(() => OwnerReads.SignInAsync(calls, "juno", "grok"));
        await Assert.ThrowsExactlyAsync<ArgumentException>(() => OwnerReads.SignInCodeAsync(calls, "juno", "two words"));
    }
}
