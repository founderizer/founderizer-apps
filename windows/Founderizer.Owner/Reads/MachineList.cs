using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Founderizer.Owner.Reads;

// GET /ui/machines (owner API 1.2), as the Mac's FleetCore/Machines.swift and MachineSignin.swift read it: each agent's
// machine with its reading, its sign-in and its newest check. The fields that the setup and the sign-in read are typed;
// the ones that only other pages read (its access, its models, its settings, its use) are skipped, and a field that the
// Mac requires and that this app does not read is kept as a JsonElement whose presence the decode still requires.

/// <summary>GET /ui/machines (the Mac's MachineList).</summary>
public sealed record MachineList(string Db, IReadOnlyList<MachineStatus> Machines, string? DesiredRevision = null)
{
    /// <summary>The Mac's <c>validate(database:)</c>: this generation, at most 1000 machines, each agent once, a report time
    /// that is finite and after 1970, and a check of a valid shape.</summary>
    internal string? Problem(string database)
    {
        if (Db != database) return "the list is of another generation";
        if (Machines.Count > 1000) return "more than 1000 machines";
        if (Machines.Select(m => m.Agent).Distinct(StringComparer.Ordinal).Count() != Machines.Count) return "two machines have one agent";
        if (!Machines.All(m => m.ReportedAt is not { } at || double.IsFinite(at) && at > 0)) return "a report time is not a time";
        if (!Machines.All(m => m.Check?.IsValid != false)) return "a check is of no valid shape";
        if (!Machines.All(m => m.Security.ValueKind == JsonValueKind.Object && m.Os.ValueKind == JsonValueKind.Object))
            return "a machine has no security or no system";
        return null;
    }

    public MachineStatus? Of(string agent) => Machines.FirstOrDefault(m => m.Agent == agent);
}

/// <summary>One agent's machine (the Mac's MachineStatus). <c>Security</c> and <c>Os</c> are objects that the Mac
/// requires and that no page of the setup reads.</summary>
public sealed record MachineStatus(
    string Agent,
    string Machine,
    string Role,
    MachineUpdate Update,
    JsonElement Security,
    MachineRuntime Runtime,
    JsonElement Os,
    string? Address = null,
    string? Revision = null,
    MachineCheck? Check = null,
    double? ReportedAt = null,
    bool? Stale = null,
    IReadOnlyList<string>? Features = null,
    bool? SettingsPending = null,
    MachineVerification? Verify = null,
    MachineLogin? Login = null,
    JsonElement? Runtimes = null,
    IReadOnlyDictionary<string, IReadOnlyList<string>>? SignInShared = null,
    bool? ReleaseRefused = null)
{
    /// <summary>Its report is of the last ten minutes, by the hub's clock, and the hub does not call it stale.</summary>
    public bool IsCurrent(double time) => Stale != true && ReportedAt is { } at && time - at >= -5 && time - at < 600;

    /// <summary>The names of the runtimes that its helper reads (the Mac's <c>Runtimes.byName</c>: an entry that cannot
    /// be read is left out).</summary>
    public IReadOnlyList<string> RuntimeNames =>
        Runtimes is { ValueKind: JsonValueKind.Object } all
            ? all.EnumerateObject().Where(e => ReadsAsRuntime(e.Value)).Select(e => e.Name).ToList()
            : [];

    /// <summary>An entry of <c>runtimes</c> that the Mac's <c>Failable&lt;Runtime&gt;</c> reads: an object whose
    /// <c>name</c> and <c>version</c> are text or null and whose <c>signed_in</c> is true, false or null.</summary>
    private static bool ReadsAsRuntime(JsonElement entry)
    {
        if (entry.ValueKind != JsonValueKind.Object) return false;
        foreach (var (field, kinds) in new[] { ("name", "s"), ("version", "s"), ("signed_in", "b") })
        {
            if (!entry.TryGetProperty(field, out var value) || value.ValueKind == JsonValueKind.Null) continue;
            if (kinds == "s" ? value.ValueKind != JsonValueKind.String
                             : value.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return false;
        }
        return true;
    }

    /// <summary>What this machine's reading says of this provider's sign-in: true, false, or null when it does not name
    /// the provider or does not know (the Mac's <c>signedIn(_:)</c>: its entry of <c>runtimes</c> first, else the
    /// runtime that it loaded when that is the provider).</summary>
    public bool? SignedIn(string provider)
    {
        if (Runtimes is { ValueKind: JsonValueKind.Object } all && all.TryGetProperty(provider, out var entry) && ReadsAsRuntime(entry))
            return entry.TryGetProperty("signed_in", out var signed) && signed.ValueKind != JsonValueKind.Null
                ? signed.ValueKind == JsonValueKind.True
                : null;
        return Runtime.Name == provider ? Runtime.SignedIn : null;
    }

    /// <summary>The runtime this machine would be signed in to: the one it loaded, else the first that can sign in.</summary>
    public string? SignInRuntime =>
        Runtime.Name is { } name && MachineLogin.CanSignIn(name) ? name : RuntimeNames.FirstOrDefault(MachineLogin.CanSignIn);

    /// <summary>The sign-in that runs or ran last on this machine, when it is of this provider.</summary>
    public MachineLogin? LoginOf(string provider) => Login is { } login && login.Runtime == provider ? login : null;

    /// <summary>The sign-in of the provider that this machine would be signed in to.</summary>
    public MachineLogin? OwnLogin => SignInRuntime is { } name ? LoginOf(name) : null;

    /// <summary>Its reading says that it is not signed in to this provider.</summary>
    public bool SignedOut(string provider) => SignedIn(provider) == false;

    /// <summary>Its runtime says that it is not signed in, so the owner has something to do.</summary>
    public bool NeedsSignIn => SignInRuntime is { } name && SignedOut(name);

    /// <summary>It waits for the owner's own sign-in: not signed in, or a sign-in goes on now.</summary>
    public bool WaitsForSignIn => NeedsSignIn || OwnLogin?.IsOpen == true;
}

public sealed record MachineUpdate(string? State = null, string? Detail = null, double? RequestedAt = null, double? FinishedAt = null);

public sealed record MachineRuntime(string? Name = null, string? Version = null, bool? SignedIn = null);

/// <summary>The newest check of a machine (the Mac's MachineCheck).</summary>
public sealed record MachineCheck(long Id, string State, double RequestedAt, double? CompletedAt = null, string? Detail = null)
{
    public bool IsPending => State == "requested";

    public bool IsValid =>
        Id > 0 && double.IsFinite(RequestedAt) && RequestedAt > 0 && State is "requested" or "completed" or "failed" or "offline" &&
        (IsPending ? CompletedAt is null : CompletedAt is { } done && double.IsFinite(done) && done >= RequestedAt);
}

/// <summary>The result of a machine's check for activation (the Mac's MachineVerification).</summary>
public sealed record MachineVerification(long Check, double CheckedAt, string Revision, IReadOnlyList<VerificationItem> Items, bool? Holds = null)
{
    /// <summary>The newest check of this machine passed for its saved settings, recently enough for the hub to
    /// activate it (the Mac's <c>permitsActivation</c>).</summary>
    public bool PermitsActivation(MachineStatus machine, string? desiredRevision, double time) =>
        machine.IsCurrent(time) && machine.Update.State == "current" && machine.SettingsPending == false &&
        machine.Check?.Id == Check && machine.Check?.State == "completed" &&
        (Holds ?? (Revision == desiredRevision || Revision == machine.Revision)) &&
        double.IsFinite(CheckedAt) && time - CheckedAt >= -5 && time - CheckedAt <= 3600 && Items.Count > 0 &&
        Items.All(i => i.Required is { } required && (!required || i.State == "ok"));
}

/// <summary>One item of a check. Its code and names are read as the Mac reads them, with <c>try?</c>.</summary>
public sealed record VerificationItem(string Kind, string Ref, string State, string Detail, bool? Required = null,
                                      JsonElement? Code = null, JsonElement? Names = null)
{
    public string? CodeName => Lenient.Text(Code);
    public IReadOnlyDictionary<string, string>? NameMap => Lenient.Texts(Names);
}

/// <summary>**The owner signs a machine's runtime in from the app** (<c>machine_signin</c>; the Mac's MachineLogin). The
/// provider's own flow runs on the machine: the hub starts it there, passes on the link that it prints, and types back
/// the code that the owner got from the provider. So this app opens the link in the owner's own browser and nowhere else,
/// keeps the code in the one request body that carries it, and offers no sign-in for Grok. <c>State</c>:
/// <c>signing_out</c>, <c>starting</c>, <c>needs_owner</c>, <c>signing_in</c>, <c>done</c> or <c>failed</c>.</summary>
public sealed partial record MachineLogin(
    long Id,
    string Runtime,
    string State,
    double StartedAt,
    double UpdatedAt,
    bool WantsCode,
    string? Detail = null,
    string? Url = null,
    string? ShowsCode = null,
    bool? TimedOut = null)
{
    public const string Feature = "machine_signin";

    /// <summary>The runtimes that a sign-in can be driven for. Grok is not one of them.</summary>
    public static readonly IReadOnlyList<string> Runtimes = ["claude", "codex"];

    /// <summary>The hosts of each provider's own sign-in (the Mac's <c>hosts</c>, which the hub's <c>RUNTIMES</c> must
    /// say too: <c>claude.com</c> is the host that Claude Code's own <c>/login</c> prints).</summary>
    public static readonly IReadOnlyDictionary<string, IReadOnlyList<string>> Hosts = new Dictionary<string, IReadOnlyList<string>>
    {
        ["claude"] = ["claude.ai", "claude.com", "console.anthropic.com"],
        ["codex"] = ["auth.openai.com"],
    };

    public static bool CanSignIn(string runtime) => Runtimes.Contains(runtime);

    /// <summary>The code as it may be sent, which is what the machine that types it allows: letters, digits, and the dot,
    /// underscore, hash and dash, 4 to 201 of them (Claude's own code is <c>code#state</c>, about ninety). Anything else
    /// is refused before it is sent, because it would be typed into a terminal on that machine.</summary>
    public static string? CodeOf(string given)
    {
        var code = given.Trim();
        return LoginCode().IsMatch(code) ? code : null;
    }

    [GeneratedRegex(@"\A[A-Za-z0-9][A-Za-z0-9._#-]{3,200}\z", RegexOptions.CultureInvariant)]
    private static partial Regex LoginCode();

    /// <summary>The link to open, only while the sign-in waits for the owner, and only on this provider's own hosts.</summary>
    public Uri? SignInUrl =>
        State == "needs_owner" && Url is { } url && Hosts.TryGetValue(Runtime, out var hosts) ? SignInLinks.Of(url, hosts) : null;

    /// <summary>It failed, and the owner hears of it: one that only waited too long for the owner did not.</summary>
    public bool IsFailure => State == "failed" && TimedOut != true;

    /// <summary>**Why it did not finish, without the step that the button already is**; nothing for one that only waited
    /// too long for the owner.</summary>
    public string? Reason
    {
        get
        {
            if (!IsFailure) return null;
            var words = (Detail ?? "The sign-in did not finish.").Trim();
            foreach (var tail in new[] { "Start the sign-in again.", "Start it again.", "Try again." })
                if (words.EndsWith(tail, StringComparison.Ordinal)) words = words[..^tail.Length].Trim();
            return words.Length == 0 ? "The sign-in did not finish." : words;
        }
    }

    /// <summary>The code that the runtime printed, when it is one.</summary>
    public string? DeviceCode => ShowsCode is { } shown && CodeOf(shown) is not null ? shown : null;

    /// <summary>This sign-in goes on. <c>signing_out</c> is the first half of a change of account.</summary>
    public bool IsOpen => State is "signing_out" or "starting" or "needs_owner" or "signing_in";

    /// <summary>The code that the owner sent is still on its way: this sign-in has not moved since it went.</summary>
    public bool CodeOnItsWay(double? sentFrom) => State == "needs_owner" && UpdatedAt == sentFrom;

    public bool IsSigningOut => State == "signing_out";

    /// <summary>It waits for the owner to open the link.</summary>
    public bool WaitsForOwner => State == "needs_owner" && SignInUrl is not null;

    /// <summary>It waits for the code that the provider gave the owner.</summary>
    public bool WaitsForCode => WaitsForOwner && WantsCode;

    /// <summary>One line for the machine's row, in the owner's own words (the Mac's <c>summary</c>).</summary>
    public string Summary => State switch
    {
        "signing_out" => "Signing out of the account it used…",
        "starting" => "Starting the sign-in on that server…",
        "needs_owner" when WantsCode => "Open the link, then paste the code it gives you.",
        "needs_owner" => DeviceCode is { } code ? $"Open the link and enter {code} there." : "Open the link to finish the sign-in.",
        "signing_in" => "The code went to the server…",
        "done" => Detail ?? "Signed in.",
        _ => Detail ?? "The sign-in did not finish.",
    };

    /// <summary>Its text names no link and no code: a link holds the provider's state, and a code is the owner's.</summary>
    public override string ToString() => $"MachineLogin {{ Id = {Id}, Runtime = {Runtime}, State = {State} }}";
}

/// <summary>The body of POST /ui/machines/&lt;agent&gt;/signin (the Mac's <c>machineSignin</c>): the provider, and
/// whether a sign-in of another account replaces the one there.</summary>
public sealed record SignInAsk(string Runtime, bool Replace);

/// <summary>The body of POST /ui/machines/&lt;agent&gt;/signin/code: the code that the provider gave the owner, in this
/// request body alone. Its text holds no code.</summary>
public sealed record SignInCode(string Code)
{
    public override string ToString() => "SignInCode { code not shown }";
}

/// <summary>The answer of a machine's command (a sign-in, its code, a check): the request, and the hub's job.</summary>
public sealed record MachineReceipt(bool Ok, string RequestId, string? Agent = null);
