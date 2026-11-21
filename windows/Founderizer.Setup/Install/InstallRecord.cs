using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using Founderizer.Core;
using Founderizer.Remote;

namespace Founderizer.Setup.Install;

/// <summary>**Why an install stopped, as a fixed kind** (the Mac's InstallRecord.Stop): the kind of the error that ended
/// it (<see cref="InstallStops.Of"/>). The kinds of a Mac's own installer are kept, so that a name never changes its
/// meaning between the apps.</summary>
public enum InstallStop
{
    CannotStart, InstallerStopped, ServerUnreached, LoginRefused, StepFailed, HubNotOurs, NotRoot, TimedOut, NoClaimCode,
    NoChecklist, CheckStopped, NeedsSudoPassword, NeedsSshPassword, NetworkKeyRefused, HubRefused, HubUnreached,
    MacRefused, MacUnreachable, MacUnreadable, Other,
}

/// <summary>The names of the stops, and the kind of an error.</summary>
public static class InstallStops
{
    private static readonly (InstallStop Stop, string Name)[] Names =
    [
        (InstallStop.CannotStart, "cannot_start"), (InstallStop.InstallerStopped, "installer_stopped"),
        (InstallStop.ServerUnreached, "server_unreached"), (InstallStop.LoginRefused, "login_refused"),
        (InstallStop.StepFailed, "step_failed"), (InstallStop.HubNotOurs, "hub_not_ours"), (InstallStop.NotRoot, "not_root"),
        (InstallStop.TimedOut, "timed_out"), (InstallStop.NoClaimCode, "no_claim_code"), (InstallStop.NoChecklist, "no_checklist"),
        (InstallStop.CheckStopped, "check_stopped"), (InstallStop.NeedsSudoPassword, "needs_sudo_password"),
        (InstallStop.NeedsSshPassword, "needs_ssh_password"), (InstallStop.NetworkKeyRefused, "network_key_refused"),
        (InstallStop.HubRefused, "hub_refused"), (InstallStop.HubUnreached, "hub_unreached"),
        (InstallStop.MacRefused, "mac_refused"), (InstallStop.MacUnreachable, "mac_unreachable"),
        (InstallStop.MacUnreadable, "mac_unreadable"), (InstallStop.Other, "other"),
    ];

    /// <summary>The name as the Mac writes it ("server_unreached").</summary>
    public static string Name(this InstallStop stop) => Names.First(n => n.Stop == stop).Name;

    /// <summary>A name that a later version wrote reads as <see cref="InstallStop.Other"/>.</summary>
    public static InstallStop Named(string name) => Names.FirstOrDefault(n => n.Name == name) is { Name: not null } found
        ? found.Stop : InstallStop.Other;

    /// <summary>**The kind of the error that ended an install**, read as <see cref="InstallError.Plain"/> reads it: the
    /// installer's stop mark with a reason after it, then a server not reached, then a login refused. Where the Mac reads
    /// <c>ssh</c>'s words, the PC reads the way IRemote failed.</summary>
    public static InstallStop Of(Exception error)
    {
        switch (error)
        {
            case InstallError install:
                switch (install.Kind)
                {
                    case InstallErrorKind.CannotStart: return InstallStop.CannotStart;
                    case InstallErrorKind.Step:
                        var says = install.Says ?? "";
                        if (says == Installer.NotThisPcs) return InstallStop.HubNotOurs;
                        if (InstallError.StopReason(says) is not null) return InstallStop.InstallerStopped;
                        return install.Failure switch
                        {
                            RemoteFailure.NotFound or RemoteFailure.Refused or RemoteFailure.NoAnswer or RemoteFailure.Closed
                                or RemoteFailure.Dropped => InstallStop.ServerUnreached,
                            RemoteFailure.LoginRefused or RemoteFailure.LoginNotOffered => InstallStop.LoginRefused,
                            _ => InstallStop.StepFailed,
                        };
                    case InstallErrorKind.NotRoot: return InstallStop.NotRoot;
                    case InstallErrorKind.TimedOut: return InstallStop.TimedOut;
                    case InstallErrorKind.NoClaimCode: return InstallStop.NoClaimCode;
                    case InstallErrorKind.NoChecklist: return InstallStop.NoChecklist;
                    case InstallErrorKind.CheckStopped: return InstallStop.CheckStopped;
                    case InstallErrorKind.NeedsPassword:
                        return install.Need == ServerCheck.PasswordNeed.Sudo ? InstallStop.NeedsSudoPassword : InstallStop.NeedsSshPassword;
                }
                return InstallStop.Other;
            case HubException hub:
                return hub.Kind == HubErrorKind.NoAnswer ? InstallStop.HubUnreached : InstallStop.HubRefused;
            case HttpRequestException:
                return InstallStop.HubUnreached;
            default:
                return InstallStop.Other;
        }
    }
}

/// <summary>Which install a record is of.</summary>
public enum InstallKind { Hub, Join, Mac }

/// <summary>How an install stands or ended. <c>Interrupted</c> is never written: a store gives it for a record that says
/// <c>Running</c> and that another start of the app wrote.</summary>
public enum InstallOutcome { Running, Done, Stopped, Cancelled, Interrupted }

/// <summary>A step of the record: running, done or failed.</summary>
public enum RecordStepState { Running, Done, Failed }

/// <summary>**The steps by their fixed names** (the ids of the two plans), <c>Order</c> for a Mac's installer that has
/// no step yet, and <c>Other</c> for every other id.</summary>
public enum InstallStepId { Read, Network, Code, Plan, Start, WaitClaim, Claim, WaitReady, Verify, Join, Order, Other }

/// <summary>The names of the record's steps.</summary>
public static class InstallStepIds
{
    private static readonly (InstallStepId Id, string Name)[] Names =
    [
        (InstallStepId.Read, "read"), (InstallStepId.Network, "network"), (InstallStepId.Code, "code"),
        (InstallStepId.Plan, "plan"), (InstallStepId.Start, "start"), (InstallStepId.WaitClaim, "wait_claim"),
        (InstallStepId.Claim, "claim"), (InstallStepId.WaitReady, "wait_ready"), (InstallStepId.Verify, "verify"),
        (InstallStepId.Join, "join"), (InstallStepId.Order, "order"), (InstallStepId.Other, "other"),
    ];

    /// <summary>The fixed names of the steps, for a reader that holds its own list to them.</summary>
    public static readonly IReadOnlyList<string> All = Names.Select(n => n.Name).ToList();

    public static string Name(this InstallStepId id) => Names.First(n => n.Id == id).Name;

    /// <summary>The step of an id that a plan or an installer gave: <c>Other</c> for one not on the list.</summary>
    public static InstallStepId Named(string id) => Names.FirstOrDefault(n => n.Name == id) is { Name: not null } found
        ? found.Id : InstallStepId.Other;
}

/// <summary>One step of a record.</summary>
public sealed record InstallRecordStep(InstallStepId Id, RecordStepState State, DateTimeOffset Began, DateTimeOffset? Ended);

/// <summary>**One install that this PC ran, kept after its page is gone** (the Mac's InstallRecord): which install it
/// was, each step by a fixed name with its state and its times, and how it ended. **What it never holds**: a line that
/// the server printed, a join code, a key or a password. <c>Says</c> is the page's one orange line, kept only where the
/// words are this app's own (<see cref="WordsOf"/>), for the owner's own eyes on this PC.</summary>
public sealed record InstallRecord : Founderizer.Setup.FirstRun.IKeptRecord<InstallRecord>
{
    public const int SaysLimit = 300;
    public const int MostSteps = 64;
    public const int NameLimit = 64;

    public Guid Id { get; init; } = Guid.NewGuid();
    public InstallKind Kind { get; init; }
    /// <summary>The start of the app that wrote this record.</summary>
    public string Launch { get; init; } = "";
    /// <summary>The hub's address in the app's own form, with its last slash; null for a hub's own install until its
    /// claim step ended well.</summary>
    [System.Text.Json.Serialization.JsonInclude]
    public string? Hub { get; internal set; }
    /// <summary>The address that the install reached the server at: the one given, then the one on the private network.</summary>
    [System.Text.Json.Serialization.JsonInclude]
    public string Host { get; internal set; } = "";
    [System.Text.Json.Serialization.JsonInclude]
    public string? Server { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public IReadOnlyList<InstallRecordStep> Steps { get; internal set; } = [];
    public DateTimeOffset Began { get; init; }
    [System.Text.Json.Serialization.JsonInclude]
    public DateTimeOffset? Ended { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public InstallOutcome Outcome { get; internal set; } = InstallOutcome.Running;
    [System.Text.Json.Serialization.JsonInclude]
    public InstallStop? Stop { get; internal set; }
    /// <summary>The install stopped only because the server is not on the private network and no key was given.</summary>
    [System.Text.Json.Serialization.JsonInclude]
    public bool WaitsForNetwork { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public string? Says { get; internal set; }
    [System.Text.Json.Serialization.JsonInclude]
    public InstallCause? Cause { get; internal set; }
    /// <summary>How many tries the owner's press made: 2 or 3 after a retry; null for one try.</summary>
    [System.Text.Json.Serialization.JsonInclude]
    public int? Tries { get; internal set; }
    /// <summary>Why each earlier try stopped, oldest first: the fixed name of its cause or of its stop.</summary>
    [System.Text.Json.Serialization.JsonInclude]
    public IReadOnlyList<string>? Retried { get; internal set; }

    /// <summary>**The line that a record keeps for a stop**: the page's own line where its words are this app's own,
    /// else none (the installer's own stop, whose reason the server printed; an error of another program).</summary>
    public static string? WordsOf(Exception error, string host) =>
        error is InstallError install && InstallStops.Of(install) != InstallStop.InstallerStopped ? install.Plain(host) : null;

    /// <summary>The step that the install stopped at: the one that failed, else the one that ran.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public InstallStepId? StoppedAt => Outcome is InstallOutcome.Running or InstallOutcome.Done
        ? null
        : Steps.FirstOrDefault(s => s.State == RecordStepState.Failed)?.Id ?? Steps.LastOrDefault(s => s.State == RecordStepState.Running)?.Id;

    /// <summary>The newest time in the record.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public DateTimeOffset LastChange =>
        Steps.Aggregate(Max(Began, Ended ?? Began), (at, step) => Max(at, Max(step.Began, step.Ended ?? step.Began)));

    /// <summary>The same record as a later start reads it when it says that its work runs: cut off.</summary>
    public InstallRecord CutOff() => this with { Outcome = InstallOutcome.Interrupted };

    /// <summary>The record says that its work runs.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool Runs => Outcome == InstallOutcome.Running;

    private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;
}

/// <summary>**The record of the install that runs now** (the Mac's InstallLog), with each step under the name that its
/// installer gave it. Every change says whether the record changed, so that its keeper writes only then.</summary>
public sealed class InstallLog
{
    private readonly Dictionary<string, int> places = [];
    private readonly List<string> hides = [];
    private readonly List<InstallRecordStep> steps = [];

    public InstallRecord Record { get; private set; }

    public InstallLog(InstallKind kind, string? hub, string host, string launch, DateTimeOffset began) =>
        Record = new InstallRecord { Kind = kind, Hub = hub, Host = host, Launch = launch, Began = began };

    /// <summary>The strings that the plan takes out of every line, for the one line that the record keeps. Only while
    /// the install runs.</summary>
    public void Hide(IEnumerable<string> secrets)
    {
        if (Record.Outcome != InstallOutcome.Running) return;
        hides.AddRange(secrets.Where(s => s.Length >= 8));
    }

    /// <summary>The hub's address, the address that the install reached, and the server's name, each once known.</summary>
    public bool Place(string? hub = null, string? host = null, string? server = null)
    {
        var before = Record;
        var next = Record with { };
        if (!string.IsNullOrEmpty(hub)) next.Hub = hub;
        if (!string.IsNullOrEmpty(host)) next.Host = host;
        if (!string.IsNullOrEmpty(server)) next.Server = server.Length > InstallRecord.NameLimit ? server[..InstallRecord.NameLimit] : server;
        Record = next;
        return next.Hub != before.Hub || next.Host != before.Host || next.Server != before.Server;
    }

    /// <summary>A step began, or its state changed. False for a report that changes nothing.</summary>
    public bool Note(string name, RecordStepState state, DateTimeOffset at)
    {
        DateTimeOffset? ends = state == RecordStepState.Running ? null : at;
        if (!places.TryGetValue(name, out var place))
        {
            if (steps.Count >= InstallRecord.MostSteps) return false;
            places[name] = steps.Count;
            steps.Add(new InstallRecordStep(InstallStepIds.Named(name), state, at, ends));
            Commit(Record with { });
            return true;
        }
        if (steps[place].State == state) return false;
        steps[place] = steps[place] with { State = state, Ended = ends };
        Commit(Record with { });
        return true;
    }

    /// <summary>The install ended well: every step that still says that it runs is done.</summary>
    public bool Done(DateTimeOffset at)
    {
        if (Record.Outcome != InstallOutcome.Running) return false;
        for (var i = 0; i < steps.Count; i++)
            if (steps[i].State == RecordStepState.Running) steps[i] = steps[i] with { State = RecordStepState.Done, Ended = at };
        var next = Record with { };
        next.Outcome = InstallOutcome.Done;
        next.Ended = at;
        Commit(next);
        hides.Clear();
        return true;
    }

    /// <summary>**The install stopped.** <paramref name="says"/> is the line that its caller chose to keep
    /// (<see cref="InstallRecord.WordsOf"/>); here it loses the plan's secrets again and is cut. An install that its page
    /// ended stays cancelled.</summary>
    public bool Stop(InstallStop stop, string? says, InstallCause? cause = null, bool waitsForNetwork = false, DateTimeOffset? at = null)
    {
        if (Record.Outcome == InstallOutcome.Cancelled) return false;
        var before = Record;
        var next = Record with { };
        next.Outcome = InstallOutcome.Stopped;
        next.Ended = at ?? DateTimeOffset.UtcNow;
        next.Stop = stop;
        next.Cause = cause;
        next.WaitsForNetwork = waitsForNetwork;
        next.Says = says is null ? null : Kept(says);
        hides.Clear();
        Commit(next);
        return before.Outcome != next.Outcome || before.Ended != next.Ended || before.Stop != next.Stop ||
               before.Cause != next.Cause || before.WaitsForNetwork != next.WaitsForNetwork || before.Says != next.Says;
    }

    /// <summary>**The install runs again by itself**: the try that stopped is counted and the name of its stop kept, and
    /// the steps start again for the next try.</summary>
    public bool Retry(InstallStop stop, InstallCause? cause)
    {
        if (Record.Outcome != InstallOutcome.Running) return false;
        var next = Record with { };
        next.Tries = (Record.Tries ?? 1) + 1;
        next.Retried = (Record.Retried ?? []).Append(InstallRetry.Name(stop, cause)).TakeLast(InstallRetry.Most).ToList();
        steps.Clear();
        places.Clear();
        Commit(next);
        return true;
    }

    /// <summary>The page ended an install that ran.</summary>
    public bool Cancel(DateTimeOffset at)
    {
        if (Record.Outcome != InstallOutcome.Running) return false;
        var next = Record with { };
        next.Outcome = InstallOutcome.Cancelled;
        next.Ended = at;
        hides.Clear();
        Commit(next);
        return true;
    }

    private void Commit(InstallRecord next)
    {
        next.Steps = steps.ToList();
        Record = next;
    }

    /// <summary>The line as the record keeps it: without the plan's secrets, on one line, <see cref="InstallRecord.SaysLimit"/>
    /// characters at most.</summary>
    private string Kept(string words)
    {
        var line = words;
        foreach (var secret in hides) line = line.Replace(secret, "(not shown)", StringComparison.Ordinal);
        line = string.Join(" ", ServerCheck.Lines(line));
        return line.Length > InstallRecord.SaysLimit ? line[..InstallRecord.SaysLimit] : line;
    }
}
