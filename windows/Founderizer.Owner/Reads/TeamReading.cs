using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Founderizer.Owner.Reads;

/// <summary>**GET /ui/team** (owner API 1.6), as the Mac's FleetCore/Team.swift reads it: the reporting lines at the
/// revision of team.json that the hub read, that file's SHA-256 (the base of every write against the team), and each
/// agent's open tasks. The setup reads a line's role and its place (the machine and the runtime); the settings, the
/// accounts, the logins and the default models that other pages read are skipped. The Mac reads the same lines a
/// second time as its members (<c>TeamMember</c>): here <see cref="TeamLine"/> holds both.</summary>
public sealed partial record TeamReading(
    string Db,
    string Revision,
    string Sha256,
    IReadOnlyList<TeamLine> Lines,
    IReadOnlyDictionary<string, long> OpenTasks,
    JsonElement? Accounts = null)
{
    public TeamLine? LineOf(string agent) => Lines.FirstOrDefault(l => l.Agent == agent);

    public TeamLine? Manager => Lines.FirstOrDefault(l => l.Role == "manager");

    /// <summary>The Mac's <c>validate(database:)</c>: this generation, a revision of 40 and a SHA-256 of 64 small hex
    /// digits, lines that are a team (<see cref="LinesProblem"/>), accounts of an object, open tasks of no negative count
    /// and of agents of the lines only.</summary>
    internal string? Problem(string database)
    {
        if (Db != database) return "the team is of another generation";
        if (!RevisionShape().IsMatch(Revision)) return "the revision is not a commit";
        if (!ShaShape().IsMatch(Sha256)) return "the SHA-256 is not one";
        if (LinesProblem(Lines) is { } lines) return lines;
        if (Accounts is { } accounts && accounts.ValueKind is not (JsonValueKind.Object or JsonValueKind.Null)) return "the accounts are not an object";
        if (OpenTasks.Values.Any(v => v < 0)) return "an open count is negative";
        if (!OpenTasks.Keys.All(k => Lines.Any(l => l.Agent == k))) return "an open count is of an agent with no line";
        return null;
    }

    /// <summary>**Lines that are a team** (the Mac's <c>TeamLinesInput.problem</c>, with its words): 1 to 1000, each agent
    /// once and of the agents' shape; one manager, who reports to nobody; each other agent a lead or a worker that reports
    /// to the manager or a lead, in no loop, on a line that reaches the manager.</summary>
    public static string? LinesProblem(IReadOnlyList<TeamLine> lines)
    {
        if (lines.Count is 0 or > 1000 || lines.Select(l => l.Agent).Distinct(StringComparer.Ordinal).Count() != lines.Count ||
            !lines.All(l => AgentShape().IsMatch(l.Agent)))
            return "The team contains an invalid or repeated agent.";
        var managers = lines.Where(l => l.Role == "manager").ToList();
        if (managers.Count != 1 || managers[0].ReportsTo is not null) return "The team must have one manager.";
        var manager = managers[0];
        var members = lines.ToDictionary(l => l.Agent, StringComparer.Ordinal);
        foreach (var line in lines.Where(l => l.Agent != manager.Agent))
        {
            if (line.Role is not ("lead" or "worker") || line.ReportsTo is not { } parent || parent == line.Agent ||
                !members.TryGetValue(parent, out var recipient) || recipient.Role is not ("manager" or "lead"))
                return "Each agent must report to the manager or a lead.";
            var seen = new HashSet<string>(StringComparer.Ordinal) { line.Agent };
            string? next = parent;
            while (next is { } name && name != manager.Agent)
            {
                if (!seen.Add(name) || !members.TryGetValue(name, out var member)) return "Reporting lines cannot form a loop.";
                next = member.ReportsTo;
            }
            if (next != manager.Agent) return "Each reporting line must reach the manager.";
        }
        return null;
    }

    [GeneratedRegex(@"\A[a-f0-9]{40}\z", RegexOptions.CultureInvariant)]
    private static partial Regex RevisionShape();

    [GeneratedRegex(@"\A[a-f0-9]{64}\z", RegexOptions.CultureInvariant)]
    private static partial Regex ShaShape();

    [GeneratedRegex(@"\A[a-z][a-z0-9_-]{0,63}\z", RegexOptions.CultureInvariant)]
    private static partial Regex AgentShape();
}

/// <summary>One line of the team (the Mac's ReportingLine and TeamMember): its agent, role and whom it reports to,
/// whether it is active (false while it is in setup), its Tools boxes, and where it runs.</summary>
public sealed record TeamLine(
    string Agent,
    string Role,
    string? ReportsTo = null,
    bool? Active = null,
    IReadOnlyList<string>? Can = null,
    bool? SettingsPending = null,
    string? Title = null,
    TeamPlacement? Placement = null);

/// <summary>Where an agent runs (owner API 1.12): its machine, that machine's address, its runtime, and the other agents
/// of that machine.</summary>
public sealed record TeamPlacement(string? Machine = null, string? Address = null, string? Runtime = null,
                                   IReadOnlyList<string>? SharedWith = null);

/// <summary>The body of POST /ui/team/agents/&lt;agent&gt;/move (owner API 1.74 and 1.82): the agent on a server with
/// no agent, against the team.json that the app read, with the provider that the owner chose.</summary>
public sealed record MoveAsk(string BaseSha256, string Server, string Runtime);

/// <summary>The answer of the move (the Mac's AgentMoveReceipt): <c>Was</c> is null for the manager of a new fleet,
/// which had no machine; <c>Job</c> is the install of the agent on its new server.</summary>
public sealed record MoveReceipt(bool Ok, string RequestId, string Agent, string Server, string Runtime, long Job,
                                 string Revision, string Sha256, string? Was = null);

/// <summary>The body of POST /ui/team/agents/&lt;agent&gt; for an activation (owner API 1.9; the Mac's
/// <c>agentActivation</c>): against the team.json that the app read, the one field <c>active</c>.</summary>
public sealed record ActivationAsk(string BaseSha256, bool Active);

/// <summary>**The answer of an activation** (the Mac's <c>ControlReceipt</c> of <c>agentActivation</c>): the agent, the
/// new team.json, each change (only <c>active</c>), the updates that it asked for, whether the agent's settings are
/// still to load, and the check that let the hub activate it. The changes are read with the Mac's rule: one value of
/// another form never fails the decode, and then the answer is not this command's.</summary>
public sealed partial record ActivationReceipt(
    bool Ok,
    string RequestId,
    string? Agent = null,
    string? Sha256 = null,
    string? Revision = null,
    JsonElement? Changed = null,
    IReadOnlyList<string>? UpdatesRequested = null,
    bool? SettingsPending = null,
    ActivationCheck? Activation = null)
{
    /// <summary>The Mac's <c>matches</c> of <c>agentActivation</c>: this agent, a SHA-256 and a revision of their shapes,
    /// changes of the field <c>active</c> to <paramref name="active"/> only, updates of this agent only, and the state of
    /// its settings; the check that let the hub activate it when the activation changed something, and no check else.</summary>
    internal bool Matches(string agent, bool active)
    {
        if (!Ok || Agent != agent || Sha256 is null || !ShaShape().IsMatch(Sha256) || Revision is null || !RevisionShape().IsMatch(Revision) ||
            SettingsPending is null || UpdatesRequested is not { } updates || !updates.All(u => u == agent))
            return false;
        if (Changed is not { ValueKind: JsonValueKind.Array } changes) return false;
        var count = 0;
        foreach (var change in changes.EnumerateArray())
        {
            if (change.ValueKind != JsonValueKind.Object || !change.TryGetProperty("field", out var field) ||
                field.ValueKind != JsonValueKind.String || field.GetString() != "active" || !change.TryGetProperty("after", out var after) ||
                after.ValueKind != (active ? JsonValueKind.True : JsonValueKind.False))
                return false;
            count++;
        }
        if (active && count > 0) return Activation is { Check: > 0 } check && double.IsFinite(check.CheckedAt) && check.CheckedAt > 0;
        return Activation is null;
    }

    [GeneratedRegex(@"\A[a-f0-9]{40}\z", RegexOptions.CultureInvariant)]
    private static partial Regex RevisionShape();

    [GeneratedRegex(@"\A[a-f0-9]{64}\z", RegexOptions.CultureInvariant)]
    private static partial Regex ShaShape();
}

/// <summary>The check that let the hub activate an agent: its id and when it was done.</summary>
public sealed record ActivationCheck(long Check, double CheckedAt);

/// <summary>The body of POST /ui/team/agents/&lt;agent&gt;/rename (owner feature <c>manager_rename</c>; the Mac's
/// <c>nameManager</c>): the manager's new name, against the team.json that the app read.</summary>
public sealed record RenameAsk(string BaseSha256, string Name);

/// <summary>The answer of the rename (the Mac's ManagerNameReceipt): <c>Agent</c> is the new name, <c>Was</c> the name
/// that the manager had.</summary>
public sealed record RenameReceipt(bool Ok, string RequestId, string Agent, string Was, string Revision, string Sha256);
