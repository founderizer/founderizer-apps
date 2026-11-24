using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;

namespace Founderizer.Setup.Install;

/// <summary>**The four steps that a server's install shows under its moving title, and the minutes left** (the Mac's
/// InstallPhases): what stands before the private network is the server, the private network is its own, the checks
/// are the end, and everything between them is the install.</summary>
public sealed partial record InstallPhases
{
    public static readonly IReadOnlyList<string> Names = ["VPS", "Network", "Install", "Checks"];

    /// <summary>The step that runs now, as an index of <see cref="Names"/>; <c>Names.Count</c> once every step is done.</summary>
    public int Current { get; }
    /// <summary>**The minutes left, only while they are true** (F4 of the owner's feedback of 22 November 2026): the
    /// estimates of the steps that are not done, less the time of the step that runs. Null once that step has run longer
    /// than its estimate, because then no count of ours is true. A page shows no minutes for null.</summary>
    public int? MinutesLeft { get; }
    /// <summary>What runs now, in a few words, for the line of a server on the build page: one phrase of the app's own
    /// table for each plan step and each heading of an installer (<see cref="StatusOf"/>), never the server's words.</summary>
    public string? Status { get; }
    /// <summary>**How much of each of the four steps is done**, from 0 to 1: the units that ended of the units that it
    /// has (F4, piece 3), one unit for each plan step and one for each heading that the installer prints while a step
    /// reads its log (<see cref="InstallerHeadings"/>). It never counts time, so a part is full only when its last step
    /// has ended.</summary>
    public IReadOnlyList<double> Parts { get; }
    /// <summary>The id of the plan's step that runs now or comes next; null once every step is done.</summary>
    public string? Step { get; }
    /// <summary>**This PC's last three reads of the step that runs reached nothing** (<see cref="InstallProgress.Unreachable"/>;
    /// F4 piece 5): no minutes show, since no count of ours is true then.</summary>
    public bool Unreachable { get; }
    /// <summary>The heading that the installer prints now is not in the app's table: the line stays the one that this step
    /// said last (<see cref="InstallHold"/>), and with no line before it, the step's own.</summary>
    internal bool HeadingUnknown { get; }

    /// <summary>Seconds that each step takes, as the proof run of 5 November 2026 measured them.</summary>
    public static readonly IReadOnlyDictionary<string, int> Seconds = new Dictionary<string, int>
    {
        ["read"] = 15, ["network"] = 45, ["code"] = 15, ["plan"] = 5, ["start"] = 5, ["wait_claim"] = 30, ["claim"] = 10,
        ["wait_ready"] = 650, ["verify"] = 75, ["join"] = 360,
    };
    public const int OtherStep = 30;

    /// <summary>**The headings that an installer prints while a plan step reads its log**, as units of that step's part
    /// of the bar: hub.sh prints "Founderizer step N: words" before each part of its install, and "wait_ready" reads them
    /// until the installer's end. A heading's number counts each heading before it. A step that is not here counts no
    /// heading: a heading that the app does not count (a join's, for one) holds the share where it stood.</summary>
    public static readonly IReadOnlyDictionary<string, int> InstallerHeadings = new Dictionary<string, int>
    {
        ["wait_ready"] = 19,
    };

    private InstallPhases(int current, int? minutesLeft, string? status, IReadOnlyList<double> parts, string? step,
                          bool unreachable, bool headingUnknown)
    {
        Current = current; MinutesLeft = minutesLeft; Status = status; Parts = parts; Step = step;
        Unreachable = unreachable; HeadingUnknown = headingUnknown;
    }

    /// <summary>These phases with other parts, step that runs and line (<see cref="InstallHold.Applied"/>).</summary>
    internal InstallPhases Held(IReadOnlyList<double> parts, int current, string? status) =>
        new(current, MinutesLeft, status, parts, Step, Unreachable, HeadingUnknown);

    /// <summary>The steps of an install that has a private network step; null for a plan with none (a restart, an
    /// update). <paramref name="planned"/>: the ids of the plan's steps, in order, for the steps not reported yet.
    /// <paramref name="runningFor"/>: how long the step that runs now has run. It changes the minutes only, never
    /// <see cref="Parts"/>.</summary>
    public static InstallPhases? Of(IReadOnlyList<InstallProgress> reported, IReadOnlyList<string>? planned = null,
                                    double runningFor = 0)
    {
        var known = reported.Select(r => r.Step).ToHashSet();
        var steps = reported.Concat((planned ?? []).Where(id => !known.Contains(id))
                                    .Select(id => new InstallProgress(id, id, "", ProgressState.Waiting))).ToList();
        var network = steps.FindIndex(s => s.Step == "network");
        if (network < 0) return null;
        int Phase(int index) => index < network ? 0 : index == network ? 1 : steps[index].Step == "verify" ? 3 : 2;
        int Estimate(int index) => Seconds.TryGetValue(steps[index].Step, out var s) ? s : OtherStep;
        var open = Enumerable.Range(0, steps.Count).Where(i => steps[i].State != ProgressState.Done).ToList();
        var current = open.Count > 0 ? Phase(open[0]) : Names.Count;
        var left = open.Sum(Estimate);
        int? running = open.Count > 0 && steps[open[0]].State == ProgressState.Running ? Estimate(open[0]) : null;
        var unreachable = open.Count > 0 && steps[open[0]] is { State: ProgressState.Running, Unreachable: true };
        int? minutes;
        if (running is { } estimate && (runningFor > estimate || unreachable)) minutes = null;
        else
        {
            var ran = running is { } e ? Math.Min(Math.Max(0, (int)runningFor), Math.Max(0, e - 30)) : 0;
            minutes = (int)Math.Ceiling((left - ran) / 60.0);
        }
        var join = steps.Any(s => s.Step == "join");
        var status = open.Count > 0 ? StatusOf(steps[open[0]], join) : null;
        var headingUnknown = open.Count > 0 && HeadingOf(steps[open[0]], join) == HeadingLine.Unknown;
        var units = new int[Names.Count];
        var ended = new int[Names.Count];
        for (var index = 0; index < steps.Count; index++)
        {
            var part = Phase(index);
            var headings = InstallerHeadings.TryGetValue(steps[index].Step, out var h) ? h : 0;
            units[part] += 1 + headings;
            switch (steps[index].State)
            {
                case ProgressState.Done: ended[part] += 1 + headings; break;
                case ProgressState.Running:
                    // The heading that runs has not ended; each one before it has. The step's own unit ends only with it.
                    var newest = steps[index].Lines.Select(InstallerStepNumber).LastOrDefault(n => n is not null) ?? 0;
                    ended[part] += Math.Min(headings, Math.Max(0, newest - 1));
                    break;
                case ProgressState.Waiting or ProgressState.Failed: break;
            }
        }
        var parts = Enumerable.Range(0, Names.Count)
                              .Select(p => units[p] > 0 ? (double)ended[p] / units[p] : p < current ? 1.0 : 0.0).ToList();
        return new InstallPhases(current, minutes, status, parts, open.Count > 0 ? steps[open[0]].Step : null, unreachable, headingUnknown);
    }

    /// <summary>**The line of each step that runs, from one table** (the Mac's <c>InstallPhases.status(_:join:)</c>, F4 of
    /// 22 November 2026, piece 4): the plan's steps, and inside the long step of each install the heading that its
    /// installer prints now. A hub's headings before its security updates are part of starting the hub, the hardening and
    /// the network after them secure the server, and its own "verify" checks the hub. A join groups its headings as
    /// installing Founderizer, securing the server, its security updates and preparing it for agents; a join with no
    /// heading says that it installs Founderizer for the whole step.</summary>
    internal static string? StatusOf(InstallProgress step, bool join)
    {
        switch (step.Step)
        {
            case "read": return "Starting your server";
            case "network": return "Joining your private network";
            case "code" or "plan": return "Copying the Founderizer code";
            case "start": return "Starting your hub";
            case "claim": return "Linking your hub to this PC";
            case "verify": return join ? "Checking your server" : "Checking your hub";
            case "wait_claim" or "wait_ready" or "join":
                // No heading yet, or one that the table does not have: the step's own line.
                var known = HeadingOf(step, join) is { } heading && heading != HeadingLine.Unknown ? heading : (HeadingLine?)null;
                return (known ?? (join ? HeadingLine.InstallingFounderizer : HeadingLine.StartingHub)) switch
                {
                    HeadingLine.StartingHub => "Starting your hub",
                    HeadingLine.InstallingFounderizer => "Installing Founderizer",
                    HeadingLine.Securing => "Securing your server",
                    HeadingLine.Updates => "Installing security updates",
                    HeadingLine.Preparing => "Preparing your server for agents",
                    HeadingLine.CheckingHub => "Checking your hub",
                    HeadingLine.CheckingServer => "Checking your server",
                    _ => null,
                };
            default: return null;
        }
    }

    /// <summary>The group of an installer's heading, for the line of what runs; <c>Unknown</c> for a heading that the
    /// table does not have.</summary>
    internal enum HeadingLine { StartingHub, InstallingFounderizer, Securing, Updates, Preparing, CheckingHub, CheckingServer, Unknown }

    /// <summary>**The headings of hub.sh, in the order of its <c>main</c>**, by the start of their fixed words, each with
    /// its line (the Mac's <c>hubHeadings</c>, which the vectors' <c>heading_lines</c> hold).</summary>
    internal static readonly IReadOnlyList<(string Words, HeadingLine Line)> HubHeadings =
    [
        ("this server and this copy of Founderizer", HeadingLine.StartingHub), ("base packages", HeadingLine.StartingHub),
        ("the user", HeadingLine.StartingHub), ("the private network (Tailscale)", HeadingLine.StartingHub),
        ("the firewall: the private network only", HeadingLine.StartingHub),
        ("the Founderizer repository on this hub", HeadingLine.StartingHub), ("the first team.json", HeadingLine.StartingHub),
        ("the root helpers that make an agent's OS user", HeadingLine.StartingHub),
        ("one OS user for each agent of this machine", HeadingLine.StartingHub), ("this server's vault", HeadingLine.StartingHub),
        ("the services fleet-hub", HeadingLine.StartingHub), ("each agent of this machine, under its own OS user", HeadingLine.StartingHub),
        ("the checks the owner can act on", HeadingLine.StartingHub), ("this fleet's own id", HeadingLine.StartingHub),
        ("the server service of this server", HeadingLine.StartingHub), ("security updates", HeadingLine.Updates),
        ("this server's own hardening", HeadingLine.Securing), ("the network: a kept connection keeps its speed", HeadingLine.Securing),
        ("verify", HeadingLine.CheckingHub),
    ];

    /// <summary>**The headings of join.sh** (the Mac's <c>joinHeadings</c>): the parts that it has with hub.sh keep the
    /// same words, in the order of a join.</summary>
    internal static readonly IReadOnlyList<(string Words, HeadingLine Line)> JoinHeadings =
    [
        ("base packages", HeadingLine.InstallingFounderizer), ("the user", HeadingLine.InstallingFounderizer),
        ("the firewall: the private network only", HeadingLine.Securing), ("this server's own hardening", HeadingLine.Securing),
        ("security updates", HeadingLine.Updates), ("the root helpers that make an agent's OS user", HeadingLine.Preparing),
        ("one OS user for each agent of this machine", HeadingLine.Preparing), ("this server's vault", HeadingLine.Preparing),
        ("verify", HeadingLine.CheckingServer),
    ];

    /// <summary>The group of the heading that <paramref name="step"/> reports now: the newest heading in its lines, read
    /// in its install's table; null for a step that reads no installer's log, and before its first heading.</summary>
    internal static HeadingLine? HeadingOf(InstallProgress step, bool join)
    {
        if (step.Step is not ("wait_claim" or "wait_ready" or "join")) return null;
        if (step.Lines.Select(InstallerStep).LastOrDefault(w => w is not null)?.ToLowerInvariant() is not { } words) return null;
        foreach (var (start, line) in join ? JoinHeadings : HubHeadings)
            if (words.StartsWith(start.ToLowerInvariant(), StringComparison.Ordinal)) return line;
        return HeadingLine.Unknown;
    }

    /// <summary>What the hub's installer says it does now, from one line of its log: "Founderizer step 14: security
    /// updates" gives "security updates". Null for any other line.</summary>
    public static string? InstallerStep(string line)
    {
        var found = Heading().Match(line);
        if (!found.Success) return null;
        var words = line[found.Length..].Trim(' ', '\t');
        return words.Length == 0 ? null : words;
    }

    /// <summary>The number of the installer's heading in one line of its log: "Founderizer step 14: security updates"
    /// gives 14. Null for any line that <see cref="InstallerStep"/> does not read as a heading.</summary>
    internal static int? InstallerStepNumber(string line)
    {
        if (InstallerStep(line) is null) return null;
        var digits = new string(line["Founderizer step ".Length..].TakeWhile(char.IsAsciiDigit).Take(9).ToArray());
        return int.Parse(digits, NumberStyles.None, CultureInfo.InvariantCulture);
    }

    [GeneratedRegex(@"\AFounderizer step [0-9]+: ", RegexOptions.CultureInvariant)]
    private static partial Regex Heading();
}

/// <summary>**The bar of one press, which never goes back** (the Mac's <c>InstallHold</c>; F4 of 22 November 2026, piece
/// 3: "a part never goes back while one press runs, also through a retry of the app"). A press runs up to three tries
/// (<see cref="InstallRetry"/>), and each try reports its steps again from the first one; a step that failed counts no
/// heading. The hold keeps the furthest share of each part that the press reached, and the part that runs where it
/// stood; the minutes stay those of the step that runs now. It also keeps the line of the step that runs from a heading
/// of the table (piece 4), for a heading that the table does not have: the PC installs <c>hub.sh</c> from the public
/// repository, so an app older than its installer meets new headings. A new press starts a new hold; a retry keeps
/// it.</summary>
public sealed record InstallHold(IReadOnlyList<double>? Parts = null, string? LineStep = null, string? LineWords = null)
{
    public static InstallHold None { get; } = new();

    /// <summary>This hold with each part of what the install reports now where it is further than before, and the line
    /// of a heading that the table has.</summary>
    public InstallHold Keep(InstallPhases phases)
    {
        var parts = Parts is { } before ? before.Zip(phases.Parts, Math.Max).ToList() : phases.Parts;
        return !phases.HeadingUnknown && phases.Step is { } step && phases.Status is { } words
            ? new InstallHold(parts, step, words)
            : this with { Parts = parts };
    }

    /// <summary><paramref name="phases"/> with each part, and the part that runs, at the furthest that this press
    /// reached, and for a heading that the table does not have, the line that its step said last.</summary>
    public InstallPhases Applied(InstallPhases phases)
    {
        var status = phases.HeadingUnknown && LineStep is not null && LineStep == phases.Step ? LineWords : phases.Status;
        if (Parts is not { } parts || parts.Count != phases.Parts.Count)
            return status == phases.Status ? phases : phases.Held(phases.Parts, phases.Current, status);
        var held = parts.Zip(phases.Parts, Math.Max).ToList();
        var first = held.FindIndex(p => p < 1);
        return phases.Held(held, Math.Max(phases.Current, first >= 0 ? first : phases.Current), status);
    }
}
