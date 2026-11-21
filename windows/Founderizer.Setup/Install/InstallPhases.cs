using System;
using System.Collections.Generic;
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
    public int MinutesLeft { get; }
    /// <summary>What runs now, in a few words, for the line under the first run's title.</summary>
    public string? Status { get; }
    /// <summary>How much of each of the four steps is done, from 0 to 1.</summary>
    public IReadOnlyList<double> Parts { get; }
    /// <summary>The id of the plan's step that runs now or comes next; null once every step is done.</summary>
    public string? Step { get; }

    /// <summary>Seconds that each step takes, as the proof run of 5 November 2026 measured them.</summary>
    public static readonly IReadOnlyDictionary<string, int> Seconds = new Dictionary<string, int>
    {
        ["read"] = 15, ["network"] = 45, ["code"] = 15, ["plan"] = 5, ["start"] = 5, ["wait_claim"] = 30, ["claim"] = 10,
        ["wait_ready"] = 650, ["verify"] = 75, ["join"] = 360,
    };
    public const int OtherStep = 30;

    private InstallPhases(int current, int minutesLeft, string? status, IReadOnlyList<double> parts, string? step)
    {
        Current = current; MinutesLeft = minutesLeft; Status = status; Parts = parts; Step = step;
    }

    /// <summary>The steps of an install that has a private network step; null for a plan with none (a restart, an
    /// update). <paramref name="planned"/>: the ids of the plan's steps, in order, for the steps not reported yet.
    /// <paramref name="runningFor"/>: how long the step that runs now has run.</summary>
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
        if (open.Count > 0 && steps[open[0]].State == ProgressState.Running)
            left -= Math.Min(Math.Max(0, (int)runningFor), Math.Max(0, Estimate(open[0]) - 30));
        var minutes = (int)Math.Ceiling(left / 60.0);
        var status = open.Count > 0 ? StatusOf(steps[open[0]]) : null;
        var total = new int[Names.Count];
        var done = new double[Names.Count];
        for (var index = 0; index < steps.Count; index++)
        {
            var part = Phase(index);
            var estimate = Estimate(index);
            total[part] += estimate;
            if (steps[index].State == ProgressState.Done) done[part] += estimate;
            else if (open.Count > 0 && index == open[0] && steps[index].State == ProgressState.Running)
                done[part] += Math.Min(Math.Max(0, runningFor), estimate);
        }
        var parts = Enumerable.Range(0, Names.Count)
                              .Select(p => total[p] > 0 ? Math.Min(1, done[p] / total[p]) : p < current ? 1.0 : 0.0).ToList();
        return new InstallPhases(current, minutes, status, parts, open.Count > 0 ? steps[open[0]].Step : null);
    }

    /// <summary>The words of one step that runs, in the order the first run meets them.</summary>
    internal static string? StatusOf(InstallProgress step)
    {
        switch (step.Step)
        {
            case "read": return "Starting your server";
            case "network": return "Joining your private network";
            case "code" or "plan": return "Copying the Founderizer code";
            case "start" or "wait_claim": return "Starting your hub";
            case "claim": return "Linking your hub to this PC";
            case "verify": return "Checking your hub";
            case "wait_ready":
                var doing = step.Lines.Select(InstallerStep).LastOrDefault(w => w is not null)?.ToLowerInvariant() ?? "";
                if (doing.Contains("security updates", StringComparison.Ordinal)) return "Installing security updates";
                if (doing.StartsWith("verify", StringComparison.Ordinal)) return "Checking your hub";
                return "Starting your hub";
            default: return null;
        }
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

    [GeneratedRegex(@"\AFounderizer step [0-9]+: ", RegexOptions.CultureInvariant)]
    private static partial Regex Heading();
}
