using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Owner.Reads;

/// <summary>The JSON context of the owner's reads of servers, machines and the team (windows-app-plan-v2.md, section 6:
/// each family keeps its own), with the rules of a Swift Decodable, as Founderizer.Core's CoreJson.</summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    RespectNullableAnnotations = true,
    RespectRequiredConstructorParameters = true,
    NumberHandling = JsonNumberHandling.Strict,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(ServerList))]
[JsonSerializable(typeof(MachineList))]
[JsonSerializable(typeof(TeamReading))]
[JsonSerializable(typeof(ServerJob))]
[JsonSerializable(typeof(MachineStatus))]
[JsonSerializable(typeof(MachineVerification))]
[JsonSerializable(typeof(JoinAsk))]
[JsonSerializable(typeof(JoinCode))]
[JsonSerializable(typeof(MoveAsk))]
[JsonSerializable(typeof(MoveReceipt))]
[JsonSerializable(typeof(SignInAsk))]
[JsonSerializable(typeof(SignInCode))]
[JsonSerializable(typeof(MachineReceipt))]
[JsonSerializable(typeof(CheckAsk))]
[JsonSerializable(typeof(CheckReceipt))]
[JsonSerializable(typeof(ActivationAsk))]
[JsonSerializable(typeof(ActivationReceipt))]
[JsonSerializable(typeof(AgentAsk))]
[JsonSerializable(typeof(ServerAgentReceipt))]
public sealed partial class ReadsJson : JsonSerializerContext;

/// <summary>**The owner's reads of servers, machines and the team, and the writes of the agent setup**, as the owner's
/// computer (the Mac's <c>HubClient.servers</c>, <c>machines</c>, <c>team</c>, <c>joinCode</c>, <c>moveAgent</c>,
/// <c>addServerAgent</c> and the commands <c>machineSignin</c>, <c>machineSigninCode</c>, <c>machineCheck</c> and
/// <c>agentActivation</c>), through the store's owner calls. Each read has the
/// Mac's size cap and its check of the answer; a changed generation is its own answer, and the store then reads the
/// fleet again.</summary>
public static class OwnerReads
{
    /// <summary>The Mac's caps of these reads: 2 MiB for the servers, 1 MiB for the machines and for the team.</summary>
    public const int ServersLimit = 2_097_152, MachinesLimit = 1_048_576, TeamLimit = 1_048_576;

    /// <summary>The store's owner calls that these reads need: the hub reads them, a test gives a stand-in.</summary>
    public interface ICalls
    {
        string? Database { get; }
        Task<OwnerAnswer<T>> GetAsync<T>(string route, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type, int limit,
                                         CancellationToken cancel) where T : class;
        Task<OwnerAnswer<TAnswer>> PostAsync<TBody, TAnswer>(string route, TBody body,
            System.Text.Json.Serialization.Metadata.JsonTypeInfo<TBody> bodyType,
            System.Text.Json.Serialization.Metadata.JsonTypeInfo<TAnswer> answerType, Guid? requestId,
            CancellationToken cancel) where TAnswer : class;
    }

    /// <summary>The calls of an <see cref="OwnerStore"/> as the owner's computer.</summary>
    public static ICalls Of(OwnerStore store) => new StoreCalls(store);

    /// <summary>GET /ui/servers (owner feature <c>servers</c>).</summary>
    public static async Task<OwnerAnswer<ServerList>> ServersAsync(ICalls calls, CancellationToken cancel = default)
    {
        var database = calls.Database ?? throw new InvalidOperationException("no generation of the hub is read yet");
        var answer = await calls.GetAsync("ui/servers", ReadsJson.Default.ServerList, ServersLimit, cancel).ConfigureAwait(false);
        if (answer.Value is { } list && list.Problem(database) is { } why) throw HubException.InvalidResponse("GET /ui/servers", why);
        return answer;
    }

    /// <summary>GET /ui/machines (owner API 1.2).</summary>
    public static async Task<OwnerAnswer<MachineList>> MachinesAsync(ICalls calls, CancellationToken cancel = default)
    {
        var database = calls.Database ?? throw new InvalidOperationException("no generation of the hub is read yet");
        var answer = await calls.GetAsync("ui/machines", ReadsJson.Default.MachineList, MachinesLimit, cancel).ConfigureAwait(false);
        if (answer.Value is { } list && list.Problem(database) is { } why) throw HubException.InvalidResponse("GET /ui/machines", why);
        return answer;
    }

    /// <summary>GET /ui/team (owner API 1.6).</summary>
    public static async Task<OwnerAnswer<TeamReading>> TeamAsync(ICalls calls, CancellationToken cancel = default)
    {
        var database = calls.Database ?? throw new InvalidOperationException("no generation of the hub is read yet");
        var answer = await calls.GetAsync("ui/team", ReadsJson.Default.TeamReading, TeamLimit, cancel).ConfigureAwait(false);
        if (answer.Value is { } team && team.Problem(database) is { } why) throw HubException.InvalidResponse("GET /ui/team", why);
        return answer;
    }

    /// <summary>**POST /ui/servers/join**: a one-time join code for one new Linux server, with its line (the Mac's
    /// <c>joinCode</c> on a hub with <c>server_names</c>, which names the server by its name in Tailscale at the join, so
    /// the app sends no name). The hub gives the code once and keeps only its SHA-256; the app keeps it in the page
    /// only.</summary>
    public static async Task<OwnerAnswer<JoinCode>> JoinCodeAsync(ICalls calls, Guid? requestId = null, CancellationToken cancel = default)
    {
        var id = requestId ?? Guid.NewGuid();
        var answer = await calls.PostAsync("ui/servers/join", new JoinAsk("linux"), ReadsJson.Default.JoinAsk,
                                           ReadsJson.Default.JoinCode, id, cancel).ConfigureAwait(false);
        if (answer.Value is { } code && !(code.Ok && Same(code.RequestId, id) && code.Name.Length == 0 && code.Kind == "linux" &&
                                          double.IsFinite(code.ExpiresAt)))
            throw HubException.InvalidResponse("POST /ui/servers/join", "the answer is not the code of this request");
        return answer;
    }

    /// <summary>**POST /ui/team/agents/&lt;agent&gt;/move** (the Mac's <c>moveAgent</c>): the agent on a server with no
    /// agent, against the team.json whose SHA-256 the app read, with the provider of the owner's choice. For the manager
    /// of a new fleet (<c>manager_server</c>) it is its first server.</summary>
    public static async Task<OwnerAnswer<MoveReceipt>> MoveAsync(ICalls calls, string agent, string sha256, string server,
                                                                 string runtime, Guid? requestId = null, CancellationToken cancel = default)
    {
        if (!AgentName(agent) || !(ServerNames.IsMachine(server)) || !Sha(sha256) || runtime is not ("claude" or "codex"))
            throw new ArgumentException("the agent, the server, the base or the provider is of no valid shape");
        var id = requestId ?? Guid.NewGuid();
        var answer = await calls.PostAsync($"ui/team/agents/{agent}/move", new MoveAsk(sha256, server, runtime),
                                           ReadsJson.Default.MoveAsk, ReadsJson.Default.MoveReceipt, id, cancel).ConfigureAwait(false);
        if (answer.Value is { } r && !(r.Ok && Same(r.RequestId, id) && r.Agent == agent && r.Server == server && r.Runtime == runtime && r.Job > 0))
            throw HubException.InvalidResponse($"POST /ui/team/agents/{agent}/move", "the answer is not the move of this request");
        return answer;
    }

    /// <summary>**POST /ui/machines/&lt;agent&gt;/signin**: the machine's own runtime sign-in starts on that machine
    /// (owner feature <c>machine_signin</c>). Only for Claude Code and Codex.</summary>
    public static async Task<OwnerAnswer<MachineReceipt>> SignInAsync(ICalls calls, string agent, string runtime, bool replace = false,
                                                                      Guid? requestId = null, CancellationToken cancel = default)
    {
        if (!AgentName(agent) || !MachineLogin.CanSignIn(runtime)) throw new ArgumentException("no sign-in for this agent or provider");
        var id = requestId ?? Guid.NewGuid();
        var answer = await calls.PostAsync($"ui/machines/{agent}/signin", new SignInAsk(runtime, replace), ReadsJson.Default.SignInAsk,
                                           ReadsJson.Default.MachineReceipt, id, cancel).ConfigureAwait(false);
        Receipt(answer, id, $"POST /ui/machines/{agent}/signin");
        return answer;
    }

    /// <summary>**POST /ui/machines/&lt;agent&gt;/signin/code**: the code that the provider gave the owner, for the
    /// machine to type into its own sign-in, sent once in this body and kept nowhere. A code of another shape is refused
    /// before it is sent (<see cref="MachineLogin.CodeOf"/>).</summary>
    public static async Task<OwnerAnswer<MachineReceipt>> SignInCodeAsync(ICalls calls, string agent, string given,
                                                                          Guid? requestId = null, CancellationToken cancel = default)
    {
        if (!AgentName(agent) || MachineLogin.CodeOf(given) is not { } code) throw new ArgumentException("that is not a sign-in code");
        var id = requestId ?? Guid.NewGuid();
        var answer = await calls.PostAsync($"ui/machines/{agent}/signin/code", new SignInCode(code), ReadsJson.Default.SignInCode,
                                           ReadsJson.Default.MachineReceipt, id, cancel).ConfigureAwait(false);
        Receipt(answer, id, $"POST /ui/machines/{agent}/signin/code");
        return answer;
    }

    /// <summary>**POST /ui/machines/&lt;agent&gt;/check** (the Mac's <c>machineCheck</c>): the agent's helper runs its
    /// status collection and the check for its activation now, with no AI turn and no change. The answer is the check
    /// that the hub started, or the one that waits already; its result comes with a later GET /ui/machines.</summary>
    public static async Task<OwnerAnswer<CheckReceipt>> CheckAsync(ICalls calls, string agent, Guid? requestId = null,
                                                                   CancellationToken cancel = default)
    {
        if (!AgentName(agent)) throw new ArgumentException("the agent is of no valid shape");
        var id = requestId ?? Guid.NewGuid();
        var answer = await calls.PostAsync($"ui/machines/{agent}/check", new CheckAsk(agent, ""), ReadsJson.Default.CheckAsk,
                                           ReadsJson.Default.CheckReceipt, id, cancel).ConfigureAwait(false);
        if (answer.Value is { } r && !(r.Ok && Same(r.RequestId, id) && r.Agent == agent && r.Check is { IsValid: true, IsPending: true }))
            throw HubException.InvalidResponse($"POST /ui/machines/{agent}/check", "the answer is not the check of this request");
        return answer;
    }

    /// <summary>**POST /ui/team/agents/&lt;agent&gt; with <c>active: true</c>** (owner API 1.9; the Mac's
    /// <c>agentActivation</c>): against the team.json whose SHA-256 the app read. The hub takes it only after a check of
    /// the agent's saved settings that passed, and refuses it with its own words else.</summary>
    public static async Task<OwnerAnswer<ActivationReceipt>> ActivateAsync(ICalls calls, string agent, string sha256, Guid? requestId = null,
                                                                           CancellationToken cancel = default)
    {
        if (!AgentName(agent) || !Sha(sha256)) throw new ArgumentException("the agent or the base is of no valid shape");
        var id = requestId ?? Guid.NewGuid();
        var answer = await calls.PostAsync($"ui/team/agents/{agent}", new ActivationAsk(sha256, true), ReadsJson.Default.ActivationAsk,
                                           ReadsJson.Default.ActivationReceipt, id, cancel).ConfigureAwait(false);
        if (answer.Value is { } r && !(Same(r.RequestId, id) && r.Matches(agent, active: true)))
            throw HubException.InvalidResponse($"POST /ui/team/agents/{agent}", "the answer is not the activation of this request");
        return answer;
    }

    /// <summary>**POST /ui/servers/&lt;server&gt;/agents** for an agent on a plan (the Mac's <c>addServerAgent</c>): the
    /// install of that agent on that server with <paramref name="runtime"/>, as a worker or a lead. The setup sends it for
    /// an install that failed: the same agent, server and provider, and the server repeats only what is missing.</summary>
    public static async Task<OwnerAnswer<ServerAgentReceipt>> AddAgentAsync(ICalls calls, string server, string sha256, string agent,
                                                                            string runtime, string role, string? reportsTo = null,
                                                                            Guid? requestId = null, CancellationToken cancel = default)
    {
        if (!ServerNames.IsMachine(server) || !AgentName(agent) || !Sha(sha256) || runtime is not ("claude" or "codex") ||
            role is not ("worker" or "lead") || reportsTo is not null && !AgentName(reportsTo))
            throw new ArgumentException("the server, the agent, the base, the provider or the role is of no valid shape");
        var id = requestId ?? Guid.NewGuid();
        var answer = await calls.PostAsync($"ui/servers/{server}/agents", new AgentAsk(sha256, agent, runtime, role, reportsTo),
                                           ReadsJson.Default.AgentAsk, ReadsJson.Default.ServerAgentReceipt, id, cancel).ConfigureAwait(false);
        if (answer.Value is { } r && !(r.Ok && Same(r.RequestId, id) && r.Agent == agent && r.Server == server && r.Job > 0))
            throw HubException.InvalidResponse($"POST /ui/servers/{server}/agents", "the answer is not the install of this request");
        return answer;
    }

    private static void Receipt(OwnerAnswer<MachineReceipt> answer, Guid id, string write)
    {
        if (answer.Value is { } r && !(r.Ok && Same(r.RequestId, id))) throw HubException.InvalidResponse(write, "the answer is not of this request");
    }

    private static bool Same(string said, Guid id) => string.Equals(said, id.ToString("D"), StringComparison.OrdinalIgnoreCase);

    private static bool AgentName(string name) =>
        name.Length is >= 1 and <= 64 && name[0] is >= 'a' and <= 'z' &&
        name.AsSpan(1).IndexOfAnyExcept("abcdefghijklmnopqrstuvwxyz0123456789_-") < 0;

    private static bool Sha(string text) => text.Length == 64 && text.AsSpan().IndexOfAnyExcept("0123456789abcdef") < 0;

    private sealed class StoreCalls(OwnerStore store) : ICalls
    {
        public string? Database => store.State.Fleet?.Db;

        public Task<OwnerAnswer<T>> GetAsync<T>(string route, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type, int limit,
                                                CancellationToken cancel) where T : class =>
            store.OwnerGetAsync(route, type, null, limit, cancel);

        public Task<OwnerAnswer<TAnswer>> PostAsync<TBody, TAnswer>(string route, TBody body,
            System.Text.Json.Serialization.Metadata.JsonTypeInfo<TBody> bodyType,
            System.Text.Json.Serialization.Metadata.JsonTypeInfo<TAnswer> answerType, Guid? requestId,
            CancellationToken cancel) where TAnswer : class =>
            store.OwnerPostAsync(route, body, bodyType, answerType, requestId, cancel);
    }
}
