using System;
using System.Collections.Generic;
using System.Linq;

namespace Founderizer.Core;

/// <summary>The three lanes of the Tasks board (FleetCore's ActivityColumn).</summary>
public enum ActivityColumn { InProgress, Waiting, Done }

/// <summary>The date filter of the board: whole calendar days that end today (FleetCore's ActivityPeriod).</summary>
public enum ActivityPeriod { Today, Week, Month, All }

/// <summary>What a task waits for from the owner (FleetCore's OwnerWait): the request it waits on, an outcome that nobody
/// knows, a stop that its helper did not confirm, a sign-in of its agent's AI provider.</summary>
public sealed record OwnerWait(OwnerWait.Kinds Kind, long Need = 0, string Title = "")
{
    public enum Kinds { Request, Outcome, Stop, SignIn }

    /// <summary>The card's orange line.</summary>
    public string Words => Kind switch
    {
        Kinds.Request => Title,
        Kinds.Outcome => "Outcome not known: check it",
        Kinds.Stop => "Stop not confirmed",
        _ => "Sign-in needed",
    };
}

/// <summary>The rules of the Tasks board and of Needs you over the device's read (GET /ui/mobile), as FleetCore's
/// Activity.swift and NeedsLane.swift hold them over the Mac's state. The device's read differs from the Mac's in what it
/// carries: the heads of the open tasks and of the last 20 that ended (not every task), no `parked_until` and no
/// `trigger_id`, and the holds and outcomes that still stop work.</summary>
public static class Activity
{
    public static string Title(this ActivityColumn column) => column switch
    {
        ActivityColumn.InProgress => "In progress",
        ActivityColumn.Waiting => "Waiting",
        _ => "Ended",
    };

    public static string Title(this ActivityPeriod period) => period switch
    {
        ActivityPeriod.Today => "Today",
        ActivityPeriod.Week => "Last 7 days",
        ActivityPeriod.Month => "Last 30 days",
        _ => "All",
    };

    /// <summary>The first moment of a period, or null for all time: today's start, 6 days before it, or 29.</summary>
    public static double? Start(this ActivityPeriod period, double now, ScreenContext context)
    {
        var today = context.Day(now);
        return period switch
        {
            ActivityPeriod.Today => context.Unix(today),
            ActivityPeriod.Week => context.Unix(today.AddDays(-6)),
            ActivityPeriod.Month => context.Unix(today.AddDays(-29)),
            _ => null,
        };
    }

    /// <summary>The time of a task's last activity, or its created time while it has not started.</summary>
    public static double ActivityTime(this MobileTaskHead task) =>
        task.Started is null ? task.Created : task.LastActivity ?? task.Started ?? task.Created;

    /// <summary>A result that he must see: it failed, its requester rejected it, or did not accept it.</summary>
    public static bool EndedBadly(this MobileTaskHead task) =>
        task.State is "failed" or "rejected" || (task.State == "completed" && task.Accepted == 0);

    /// <summary>The word for a result that is not a success, or null.</summary>
    public static string? FailedResult(this MobileTaskHead task) => task.State switch
    {
        "failed" => "Failed",
        "rejected" => "Rejected",
        "canceled" => "Canceled",
        "completed" => task.Accepted == 0 ? "Not accepted" : null,
        _ => null,
    };

    /// <summary>A task's lane (FleetTask.activityColumn). <paramref name="held"/>: a hold that is not released, or a usage
    /// limit of its agent. <paramref name="needsOwner"/>: an outcome that he must record, or a stop that was not
    /// confirmed, also for a task that ended. The device's head has no `parked_until`, so a parked task reads by its
    /// state.</summary>
    public static ActivityColumn Column(this MobileTaskHead task, bool held, bool needsOwner = false)
    {
        if (needsOwner) return ActivityColumn.Waiting;
        if (task.IsTerminal) return ActivityColumn.Done;
        if (held || task.State is "input-required" or "auth-required" || !string.IsNullOrEmpty(task.WaitingOn))
            return ActivityColumn.Waiting;
        return task.State == "working" ? ActivityColumn.InProgress : ActivityColumn.Waiting;
    }

    /// <summary>Every task head that the read carries, the open ones and the ones that ended, each once.</summary>
    public static IReadOnlyList<MobileTaskHead> AllTasks(MobileSnapshot snapshot)
    {
        var seen = new HashSet<long>();
        return snapshot.Tasks.Concat(snapshot.Recent).Where(t => seen.Add(t.Id)).ToList();
    }

    /// <summary>The tasks that only the owner can move: an outcome that is not known, a stop that was not confirmed.</summary>
    public static IReadOnlySet<long> OwnerOnly(MobileSnapshot snapshot) =>
        snapshot.Outcomes.Where(o => o.State == "unknown").Select(o => o.Task)
            .Concat(snapshot.Holds.Where(h => h.State == "not_confirmed").Select(h => h.Task)).ToHashSet();

    /// <summary>What each task waits for from the owner, by task (HubState.ownerWaits): an unknown outcome first, then a
    /// stop that was not confirmed, and for an open task the request it waits on (`waiting_on` "N-53" names the request,
    /// "Q-68" the question that a request carries) or its agent's sign-in.</summary>
    public static IReadOnlyDictionary<long, OwnerWait> OwnerWaits(MobileSnapshot snapshot)
    {
        var unknown = snapshot.Outcomes.Where(o => o.State == "unknown").Select(o => o.Task).ToHashSet();
        var unconfirmed = snapshot.Holds.Where(h => h.State == "not_confirmed").Select(h => h.Task).ToHashSet();
        var open = snapshot.Needs.Where(n => n.IsOpen).ToList();
        var byId = new Dictionary<long, OwnerNeed>();
        var byQuestion = new Dictionary<long, OwnerNeed>();
        foreach (var need in open)
        {
            byId.TryAdd(need.Id, need);
            if (need.Question is { } q) byQuestion.TryAdd(q, need);
        }
        var waits = new Dictionary<long, OwnerWait>();
        foreach (var task in AllTasks(snapshot))
        {
            if (unknown.Contains(task.Id)) { waits[task.Id] = new OwnerWait(OwnerWait.Kinds.Outcome); continue; }
            if (unconfirmed.Contains(task.Id)) { waits[task.Id] = new OwnerWait(OwnerWait.Kinds.Stop); continue; }
            if (task.IsTerminal) continue;
            OwnerNeed? need = null;
            if (Reference(task.WaitingOn, "N") is { } n) byId.TryGetValue(n, out need);
            if (need is null && Reference(task.WaitingOn, "Q") is { } question) byQuestion.TryGetValue(question, out need);
            if (need is not null) waits[task.Id] = new OwnerWait(OwnerWait.Kinds.Request, need.Id, need.Title);
            else if (task.State == "auth-required") waits[task.Id] = new OwnerWait(OwnerWait.Kinds.SignIn);
        }
        return waits;
    }

    /// <summary>The agents whose work waits for each open request's answer, by request, each agent once, in the order of
    /// the tasks (HubState.needWaits).</summary>
    public static IReadOnlyDictionary<long, IReadOnlyList<string>> NeedWaits(MobileSnapshot snapshot)
    {
        var waits = OwnerWaits(snapshot);
        var agents = new Dictionary<long, List<string>>();
        foreach (var task in AllTasks(snapshot))
        {
            if (!waits.TryGetValue(task.Id, out var wait) || wait.Kind != OwnerWait.Kinds.Request) continue;
            var list = agents.TryGetValue(wait.Need, out var found) ? found : agents[wait.Need] = [];
            if (!list.Contains(task.Owner)) list.Add(task.Owner);
        }
        return agents.ToDictionary(p => p.Key, p => (IReadOnlyList<string>)p.Value);
    }

    /// <summary>How many items need the owner: the open requests and the tasks that only he can move
    /// (HubState.needsYouCount): the count of the pane's Needs you row, which shows only while it is above 0.</summary>
    public static int NeedsYouCount(MobileSnapshot snapshot) =>
        snapshot.Needs.Count(n => n.IsOpen) + AllTasks(snapshot).Count(t => OwnerOnly(snapshot).Contains(t.Id));

    /// <summary>The tasks of the board for one agent (null: all) and one period, newest activity first in each lane, and in
    /// Waiting the tasks that wait for the owner before the others (HubState.activity). A task that waits for the owner
    /// shows whatever the period.</summary>
    public static IReadOnlyDictionary<ActivityColumn, IReadOnlyList<MobileTaskHead>> Lanes(
        MobileSnapshot snapshot, string? agent, ActivityPeriod period, ScreenContext context)
    {
        var start = period.Start(snapshot.Time, context) ?? double.NegativeInfinity;
        var held = snapshot.Holds.Where(h => h.State != "released").Select(h => h.Task).ToHashSet();
        var limited = snapshot.Agents.Where(a => a.Limit is not null).Select(a => a.Name).ToHashSet();
        var owner = OwnerOnly(snapshot);
        var waits = OwnerWaits(snapshot);
        var lanes = new Dictionary<ActivityColumn, List<MobileTaskHead>>
        {
            [ActivityColumn.InProgress] = [], [ActivityColumn.Waiting] = [], [ActivityColumn.Done] = [],
        };
        foreach (var task in AllTasks(snapshot))
        {
            if (agent is not null && task.Owner != agent) continue;
            if (task.ActivityTime() < start && !waits.ContainsKey(task.Id)) continue;
            lanes[task.Column(held.Contains(task.Id) || limited.Contains(task.Owner), owner.Contains(task.Id))].Add(task);
        }
        var sorted = lanes.ToDictionary(p => p.Key, p => p.Value
            .OrderByDescending(t => t.ActivityTime()).ThenByDescending(t => t.Id).ToList());
        var waiting = sorted[ActivityColumn.Waiting];
        sorted[ActivityColumn.Waiting] = waiting.Where(t => waits.ContainsKey(t.Id))
            .Concat(waiting.Where(t => !waits.ContainsKey(t.Id))).ToList();
        return sorted.ToDictionary(p => p.Key, p => (IReadOnlyList<MobileTaskHead>)p.Value);
    }

    /// <summary>The choices of the agent filter (HubState.activityAgents): the hub's agents in its order, then other
    /// owners of tasks, then the saved choice when the hub no longer has it.</summary>
    public static IReadOnlyList<string> Agents(MobileSnapshot snapshot, string? saved)
    {
        var names = snapshot.Agents.Select(a => a.Name).ToList();
        names.AddRange(AllTasks(snapshot).Select(t => t.Owner).Distinct().Except(names).Order(StringComparer.Ordinal));
        if (!string.IsNullOrEmpty(saved) && !names.Contains(saved)) names.Add(saved);
        return names;
    }

    /// <summary>The number of the hub's reference "&lt;letter&gt;-&lt;number&gt;", or null.</summary>
    private static long? Reference(string? text, string letter)
    {
        if (text is null || !text.StartsWith(letter + "-", StringComparison.Ordinal)) return null;
        var digits = text[(letter.Length + 1)..];
        return digits.Length > 0 && digits.All(c => c is >= '0' and <= '9') && long.TryParse(digits, out var n) ? n : null;
    }
}

/// <summary>The Ended lane as it shows (FleetCore's EndedTasks): the results that he must see, one row each, and every
/// other ended task behind one row that opens them by day, grouped by agent and title (the device's heads carry no
/// schedule).</summary>
public sealed record EndedTasks
{
    public sealed record Group(string Title, IReadOnlyList<MobileTaskHead> Tasks)
    {
        public long Id => Tasks[^1].Id;
        public string Owner => Tasks[0].Owner;
    }

    public sealed record Day(double Start, IReadOnlyList<Group> Groups);

    public IReadOnlyList<MobileTaskHead> Failed { get; }
    public IReadOnlyList<Day> Days { get; }
    public int Rest { get; }

    /// <summary><paramref name="tasks"/>: the Ended lane, newest first.</summary>
    public EndedTasks(IReadOnlyList<MobileTaskHead> tasks, ScreenContext context)
    {
        Failed = tasks.Where(t => t.EndedBadly()).ToList();
        var others = tasks.Where(t => !t.EndedBadly()).ToList();
        Rest = others.Count;
        var days = new List<Day>();
        double? start = null;
        var members = new List<MobileTaskHead>();
        foreach (var task in others)
        {
            var day = context.Unix(context.Day(task.ActivityTime()));
            if (start != day)
            {
                if (start is { } s) days.Add(new Day(s, Groups(members)));
                start = day;
                members = [];
            }
            members.Add(task);
        }
        if (start is { } last) days.Add(new Day(last, Groups(members)));
        Days = days;
    }

    private static List<Group> Groups(List<MobileTaskHead> tasks)
    {
        var order = new List<string>();
        var groups = new Dictionary<string, List<MobileTaskHead>>();
        foreach (var task in tasks)
        {
            var key = task.Owner + "\u001f" + "title " + task.Title;
            if (!groups.ContainsKey(key)) { order.Add(key); groups[key] = []; }
            groups[key].Add(task);
        }
        return order.Select(k => new Group(TitleOf(groups[k]), groups[k])).ToList();
    }

    /// <summary>The words of a row of several tasks: their shared title, cut at a whole word, else the newest one's.</summary>
    internal static string TitleOf(IReadOnlyList<MobileTaskHead> tasks)
    {
        var first = tasks[0].Title;
        if (tasks.All(t => t.Title == first)) return first;
        var shared = first.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        foreach (var task in tasks.Skip(1))
        {
            var words = task.Title.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var same = 0;
            while (same < Math.Min(shared.Count, words.Length) && shared[same] == words[same]) same++;
            shared = shared.Take(same).ToList();
        }
        return shared.Count < 2 ? first : string.Join(' ', shared).Trim(' ', ':', ';', ',', '.', '-', '–', '—');
    }
}

/// <summary>The lane of the Needs you page (FleetCore's NeedsLane): the requests that wait for him, newest first, and the
/// ones that ended by day.</summary>
public sealed record NeedsLane
{
    public sealed record Day(double Start, IReadOnlyList<OwnerNeed> Needs);

    public IReadOnlyList<OwnerNeed> Open { get; }
    public IReadOnlyList<Day> Ended { get; }
    public int EndedCount { get; }

    /// <summary><paramref name="sent"/>: requests whose answer is on its way, which leave the lane; <paramref name="held"/>:
    /// requests that stay in it whatever else is true (one he answered a moment ago, while the answer settles).</summary>
    public NeedsLane(IEnumerable<OwnerNeed> needs, double now, ScreenContext context, IReadOnlySet<long>? sent = null,
                     IReadOnlySet<long>? held = null)
    {
        sent ??= new HashSet<long>();
        held ??= new HashSet<long>();
        var all = needs.ToList();
        bool Waits(OwnerNeed n) => held.Contains(n.Id) || (n.IsOpen && !sent.Contains(n.Id));
        Open = all.Where(Waits).OrderByDescending(n => n.Id).ToList();
        var done = all.Where(n => !Waits(n)).Select(n => (Need: n, At: n.Answered ?? (n.IsOpen ? now : n.Raised)))
            .OrderByDescending(e => e.At).ThenByDescending(e => e.Need.Id).ToList();
        var days = new List<Day>();
        foreach (var (need, at) in done)
        {
            var start = context.Unix(context.Day(at));
            if (days.Count > 0 && days[^1].Start == start) days[^1] = days[^1] with { Needs = [.. days[^1].Needs, need] };
            else days.Add(new Day(start, [need]));
        }
        Ended = days;
        EndedCount = done.Count;
    }

    /// <summary>The request that comes to hand when <paramref name="id"/> leaves the lane: the one under it in
    /// <paramref name="order"/>, else the one over it.</summary>
    public static long? Successor(long id, IReadOnlyList<long> order, IReadOnlySet<long> open)
    {
        var index = -1;
        for (var i = 0; i < order.Count; i++) if (order[i] == id) { index = i; break; }
        if (index < 0) return null;
        for (var i = index + 1; i < order.Count; i++) if (open.Contains(order[i])) return order[i];
        for (var i = index - 1; i >= 0; i--) if (open.Contains(order[i])) return order[i];
        return null;
    }

    /// <summary>The request at hand: the chosen one while it waits; when it left, its successor; else the first.</summary>
    public static long? AtHand(long? chosen, IReadOnlyList<long> order, IReadOnlyList<long> open)
    {
        if (chosen is not { } c) return open.Count > 0 ? open[0] : null;
        if (open.Contains(c)) return c;
        return Successor(c, order, open.ToHashSet()) ?? (open.Count > 0 ? open[0] : null);
    }

    /// <summary>The words of the mark on a request that agents wait for: "Marketing waits for this", "A and B wait for
    /// this".</summary>
    public static string WaitWords(IReadOnlyList<string> agents, AgentBook names)
    {
        var labels = agents.Select(names.Label).ToList();
        return labels.Count switch
        {
            0 => "",
            1 => $"{labels[0]} waits for this",
            _ => $"{string.Join(", ", labels.Take(labels.Count - 1))} and {labels[^1]} wait for this",
        };
    }
}

/// <summary>One task's state in a few words, the same on every screen (FleetCore's TaskWords).</summary>
public static class TaskWords
{
    /// <summary>The state word: the owner's hold first, then for open work its agent's usage limit, a stall and a lost
    /// session; then a checked result, what the task waits on, and its own state.</summary>
    public static string State(string state, long? accepted, string requester, AgentBook names, string? waitingOn = null,
                               bool stalled = false, bool reconnecting = false, TaskHold? hold = null, bool limited = false)
    {
        if (hold is not null && hold.State != "released")
        {
            if (hold.State == "requested") return "Stopping…";
            if (hold.State == "not_confirmed") return "Stop not confirmed";
            return hold.Kind == "pause" ? "Paused" : "Stopped";
        }
        var over = state is "completed" or "failed" or "rejected" or "canceled";
        if (!over && limited) return "Usage limit";
        if (!over && stalled) return "Stalled";
        if (!over && reconnecting) return "Reconnecting";
        if (accepted == 1 && state == "completed") return "Checked";
        if (accepted == 0 && state == "completed") return "Not accepted";
        if (!over && !string.IsNullOrEmpty(waitingOn)) return Waiting(waitingOn, requester, names);
        return state switch
        {
            "working" => "Working",
            "submitted" => "Queued",
            "input-required" => WaitingFor(requester, names),
            "auth-required" => "Sign-in needed",
            "completed" => "Awaiting check",
            "canceled" => "Canceled",
            "" => "",
            _ => char.ToUpperInvariant(state[0]) + state[1..],
        };
    }

    /// <summary>The state word of a task head, with the snapshot's holds and its agent's limit.</summary>
    public static string State(MobileTaskHead task, MobileSnapshot snapshot, AgentBook names)
    {
        var hold = snapshot.Holds.FirstOrDefault(h => h.Task == task.Id && h.State != "released");
        var limited = snapshot.Agents.Any(a => a.Name == task.Owner && a.Limit is not null);
        return State(task.State, task.Accepted, task.Requester, names, task.WaitingOn,
                     task.StalledSince is not null || (task.NudgeLevel ?? 0) > 0, task.MissingSince is not null, hold,
                     limited);
    }

    /// <summary>"Waiting for you" when its requester is the owner, else "Waiting for Manager".</summary>
    public static string WaitingFor(string requester, AgentBook names) =>
        requester == "owner" ? "Waiting for you" : "Waiting for " + names.Label(requester);

    /// <summary>The one a task waits on when it is not its requester: an agent; null for the hub's own references
    /// ("Q-1", "P-3", "CM-7") and its screen, which are its requester's to answer.</summary>
    public static string? Waiter(string waitingOn, AgentBook names) =>
        IsReference(waitingOn) ? null : names.Label(waitingOn);

    private static string Waiting(string waitingOn, string requester, AgentBook names) =>
        Waiter(waitingOn, names) is { } who ? "Waiting on " + who : WaitingFor(requester, names);

    private static bool IsReference(string waitingOn)
    {
        if (waitingOn == "its screen") return true;
        var dash = waitingOn.IndexOf('-');
        return dash > 0 && dash < waitingOn.Length - 1 && waitingOn[..dash].All(c => c is >= 'A' and <= 'Z') &&
               waitingOn[(dash + 1)..].All(c => c is >= '0' and <= '9');
    }
}
