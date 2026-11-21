using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Founderizer.Owner.Reads;

// GET /ui/servers (owner feature `servers`), as the Mac's FleetCore/Servers.swift reads it: every machine that runs
// agents or can run them, with its newest reading, whether a new agent can go on it, and its newest job; the state of
// the newest join code (never the code), whether the hub's own server takes agents, and the kept step of the fleet's
// shape. The rules of a Swift Decodable (see Founderizer.Core's Models.cs): a field that is not optional must be there,
// and a field that the Mac reads with `try?` is a JsonElement here, read by a helper that never fails the list.

/// <summary>GET /ui/servers (the Mac's ServerList).</summary>
public sealed record ServerList(
    string Db,
    double Time,
    IReadOnlyList<ServerEntry> Servers,
    string? DesiredRevision = null,
    JoinState? Join = null,
    bool? HubShared = null,
    JsonElement? Shape = null)
{
    /// <summary>**The kept step of the fleet's shape**, or null: no step is kept, the hub does not say, or it says a step
    /// that this app does not know (the Mac's KeptShape: a value of another form never fails the read).</summary>
    public string? KeptStep =>
        Shape is { ValueKind: JsonValueKind.Object } shape && shape.TryGetProperty("step", out var step) &&
        step.ValueKind == JsonValueKind.String && step.GetString() is "one" or "two" or "each"
            ? step.GetString()
            : null;

    /// <summary>The hub's own row.</summary>
    public ServerEntry? HubRow => Servers.FirstOrDefault(s => s.Hub);

    /// <summary>The servers on which a new agent can go now.</summary>
    public IReadOnlyList<ServerEntry> Available => Servers.Where(s => s.Available).ToList();

    /// <summary>The server of an agent, or null.</summary>
    public ServerEntry? ServerOf(string agent) => Servers.FirstOrDefault(s => s.Agents.Contains(agent));

    /// <summary>The Mac's <c>validate(database:)</c>: this generation, a finite time, at most 1000 servers, each name once,
    /// each name a server's or a machine's from before servers.</summary>
    internal string? Problem(string database)
    {
        if (Db != database) return "the list is of another generation";
        if (!double.IsFinite(Time)) return "time is not finite";
        if (Servers.Count > 1000) return "more than 1000 servers";
        if (Servers.Select(s => s.Name).Distinct(StringComparer.Ordinal).Count() != Servers.Count) return "two servers have one name";
        if (!Servers.All(s => ServerNames.IsServer(s.Name) || ServerNames.IsMachine(s.Name))) return "a server's name is of no known shape";
        return null;
    }
}

/// <summary>One row of GET /ui/servers (the Mac's ServerEntry). <c>Kind</c> is linux or mac, null while no reading says
/// it. <c>User</c> is the OS user of its agents and its server service. <c>Why</c> is the codes of what stops a new
/// agent. The load, the hub's own hardening and the fleet's record of how it reaches the server are read by the Mac with
/// <c>try?</c>, so a value of another form never fails the list.</summary>
public sealed record ServerEntry(
    string Name,
    bool Hub,
    bool Joined,
    IReadOnlyList<string> Agents,
    bool Available,
    IReadOnlyList<string> Why,
    string? Kind = null,
    string? Address = null,
    string? User = null,
    ServerReading? Reading = null,
    ServerJob? Job = null,
    JsonElement? Load = null,
    JsonElement? Hardening = null,
    JsonElement? Access = null,
    IReadOnlyList<string>? ModelProviders = null)
{
    public bool IsMac => Kind == "mac";

    /// <summary>The server's newest job when it prepares a provider for this agent, or null.</summary>
    public ServerJob? Preparation(string agent) => Job is { Kind: "prepare" } job && job.Agent == agent ? job : null;
}

/// <summary>A server's newest reading (the Mac's ServerReading): <c>Source</c> is <c>server</c> (its own server service)
/// or <c>agent</c> (the helper of an agent on it, a machine from before servers). The browser parts and whom each agent
/// runs as are read by no page of the setup, and are skipped.</summary>
public sealed record ServerReading(
    string Source,
    ReadingSystem Os,
    IReadOnlyDictionary<string, ReadingRuntime> Runtimes,
    double ReportedAt,
    bool Stale,
    string? Revision = null,
    bool? Current = null,
    ReadingSecurity? Security = null,
    string? User = null)
{
    /// <summary>Read in the last ten minutes, by the hub's clock.</summary>
    public bool IsCurrent(double time) => !Stale && double.IsFinite(ReportedAt) && time - ReportedAt >= -5 && time - ReportedAt < 600;
}

public sealed record ReadingSystem(string? Name = null, string? Kernel = null);

public sealed record ReadingRuntime(string? Version = null, bool? SignedIn = null);

/// <summary>A reading's security (the Mac's ServerReading.Security): each fact null where the server does not say.</summary>
public sealed record ReadingSecurity(
    bool? UnattendedUpgrades = null,
    long? PendingSecurity = null,
    bool? RebootRequired = null,
    string? Firewall = null,
    bool? Tailscale = null,
    double? UpgradedAt = null,
    bool? SshKeysOnly = null,
    bool? NpmRule = null,
    bool? MemoryGuard = null,
    bool? RestartGuard = null);

/// <summary>**One job of a server's service** (the Mac's ServerJob): the install of an agent (<c>install</c>), the
/// preparation of the other provider before a switch (<c>prepare</c>), or what was the own of an agent that the owner
/// deleted (<c>remove</c>). <c>State</c>: queued, running, needs_owner, done, failed or canceled. <c>Step</c>: user,
/// runtime, checkout, service or sign_in. The five fields of the AI providers build (<c>steps</c>,
/// <c>provider_label</c>, <c>code</c>, <c>names</c>, <c>sign_in</c>) are read apart, as the Mac reads them (review
/// M12): one of another type from a later hub is null and never costs the read of the servers.</summary>
public sealed record ServerJob(
    long Id,
    string Kind,
    string State,
    double Created,
    double Updated,
    string? Agent = null,
    string? Runtime = null,
    string? Step = null,
    string? Detail = null,
    JobPrompt? Prompt = null,
    bool? TimedOut = null,
    JsonElement? Steps = null,
    JsonElement? ProviderLabel = null,
    JsonElement? Code = null,
    JsonElement? Names = null,
    JsonElement? SignIn = null)
{
    public bool IsOpen => State is "queued" or "running" or "needs_owner";

    /// <summary>The rows of the install of an agent on a key or a model server, or null.</summary>
    public IReadOnlyList<string>? StepList => Lenient.Strings(Steps);
    public string? CodeName => Lenient.Text(Code);
    public string? SignInWord => Lenient.Text(SignIn);

    /// <summary>The install of an agent on a key or on a model server, which has no sign-in.</summary>
    public bool HasNoSignIn => SignInWord == "none" || (Kind == "install" && StepList is { } steps && !steps.Contains("sign_in"));
}

/// <summary>The owner's sign-in while a job waits (the Mac's ServerJob.Prompt): Codex's link and code, or the one command
/// for Claude Code's own sign-in in a terminal on the server.</summary>
public sealed record JobPrompt(string Kind, string Purpose, string? Url = null, string? Code = null, string? Command = null)
{
    /// <summary>Codex's device sign-in page, only on its own host, over HTTPS, with no user, password or port.</summary>
    public Uri? SignInUrl =>
        Kind == "open_url" && Purpose == "codex_login" && Url is { } url && SignInLinks.Of(url, ["auth.openai.com"]) is { } link
            ? link
            : null;

    /// <summary>The one command for Claude Code's own sign-in: one line without control characters, at most 1000 bytes.
    /// The app shows it and copies it, and never runs it.</summary>
    public string? TerminalCommand =>
        Kind == "terminal" && Purpose == "claude_login" && Command is { Length: > 0 } command &&
        System.Text.Encoding.UTF8.GetByteCount(command) <= 1000 && !command.Any(char.IsControl)
            ? command
            : null;

    /// <summary>The code to enter on Codex's page, in its own shape.</summary>
    public string? DeviceCode => Code is { } code && ServerNames.DeviceCode().IsMatch(code) ? code : null;

    /// <summary>Its text names no link, no code and no command: each is of one sign-in, and the code is the owner's.</summary>
    public override string ToString() => $"JobPrompt {{ Kind = {Kind}, Purpose = {Purpose} }}";
}

/// <summary>The newest join code, without the code (the Mac's JoinState). <c>State</c>: open, joined, expired or
/// canceled; <c>Server</c> the name of the server that joined with it.</summary>
public sealed record JoinState(string Name, string Kind, double Created, double ExpiresAt, string State, string? Server = null)
{
    /// <summary>This is the join of the code that the hub made: a code with a name is found by its name, as before
    /// <c>server_names</c>; else by its kind and its end, which the hub wrote once for both answers.</summary>
    public bool IsOf(string name, string kind, double expiresAt) =>
        name.Length == 0 ? Kind == kind && Math.Abs(ExpiresAt - expiresAt) < 0.001 : Name == name;
}

/// <summary>The answer of POST /ui/servers/join: the code and its line, given once (a repeat of the request gives them
/// null). Its text holds neither.</summary>
public sealed record JoinCode(bool Ok, string RequestId, string Name, string Kind, double ExpiresAt, string? Code = null, string? Line = null)
{
    public override string ToString() => $"JoinCode {{ Name = {Name}, Kind = {Kind}, code not shown }}";
}

/// <summary>The body of POST /ui/servers/join, as the Mac's <c>joinCode</c> sends it for a Linux server of a hub with
/// <c>server_names</c>: its kind alone.</summary>
public sealed record JoinAsk(string Kind);

/// <summary>The names of servers, as the Mac's Servers.swift has them.</summary>
public static partial class ServerNames
{
    /// <summary>A server's name (the Mac's <c>Servers.namePattern</c>).</summary>
    public static bool IsServer(string name) => ServerName().IsMatch(name);

    /// <summary>The name of a machine from before servers (team.json "addresses"; the Mac's <c>machinePattern</c>).</summary>
    public static bool IsMachine(string name) => MachineName().IsMatch(name);

    [GeneratedRegex(@"\A[a-z][a-z0-9-]{1,30}\z", RegexOptions.CultureInvariant)]
    private static partial Regex ServerName();

    [GeneratedRegex(@"\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z", RegexOptions.CultureInvariant)]
    private static partial Regex MachineName();

    [GeneratedRegex(@"\A[A-Z0-9]{4}-[A-Z0-9]{4,6}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex DeviceCode();
}

/// <summary>**A provider's sign-in link, only on its own hosts**, over HTTPS, with no user, no password and no port: a
/// machine must not be able to put a page of its own in front of the owner (the Mac's <c>signInURL</c> rules).</summary>
public static class SignInLinks
{
    public static Uri? Of(string text, IReadOnlyCollection<string> hosts)
    {
        if (!Uri.TryCreate(text, UriKind.Absolute, out var link)) return null;
        if (link.Scheme != Uri.UriSchemeHttps || link.UserInfo.Length > 0 || !link.IsDefaultPort) return null;
        // A port written out, even 443, is a port: the Mac's URL has one then, and refuses it.
        var authority = text[(text.IndexOf("://", StringComparison.Ordinal) + 3)..];
        var end = authority.IndexOfAny(['/', '?', '#']);
        if ((end < 0 ? authority : authority[..end]).Contains(':')) return null;
        return hosts.Contains(link.Host.ToLowerInvariant()) ? link : null;
    }
}

/// <summary>The Mac's <c>try?</c> reads of a member: a value of another type is null.</summary>
internal static class Lenient
{
    public static string? Text(JsonElement? value) => value is { ValueKind: JsonValueKind.String } text ? text.GetString() : null;

    public static IReadOnlyList<string>? Strings(JsonElement? value)
    {
        if (value is not { ValueKind: JsonValueKind.Array } list) return null;
        var all = new List<string>();
        foreach (var item in list.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String) return null;
            all.Add(item.GetString()!);
        }
        return all;
    }

    public static IReadOnlyDictionary<string, string>? Texts(JsonElement? value)
    {
        if (value is not { ValueKind: JsonValueKind.Object } map) return null;
        var all = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var member in map.EnumerateObject())
        {
            if (member.Value.ValueKind != JsonValueKind.String) return null;
            all[member.Name] = member.Value.GetString()!;
        }
        return all;
    }
}
