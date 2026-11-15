using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Core;

// The steps of a task (the owner's "Yes, as shown" of 14 November 2026 to the fourth set): the task's events as the Mac
// reads them (FleetCore's RuntimeEvent, RuntimePage and ActivityTimeline), the thread that the Mac's RuntimeActivity
// builds of them, and the words of its rows. GET /ui/tasks/<id>/events is under the device prefix /ui/tasks.

public sealed record EventLocation(string Path);
public sealed record EventSubagent(string Name);
public sealed record PlanEntry(string Content, string Status);

/// <summary>A file that a tool changed (FleetCore's FileChange).</summary>
public sealed record FileChange(string Path, string Action, long? Added = null, long? Removed = null)
{
    public bool IsValid => Path.Length is > 0 and <= 300 && Action is "add" or "modify" or "delete" or "move" &&
                           (Added is null or >= 0) && (Removed is null or >= 0);
}

/// <summary>One event of a task's record (FleetCore's RuntimeEvent).</summary>
public sealed record TaskEvent(
    long Id,
    long Attempt,
    string Session,
    long Seq,
    double? Ts,
    string Type,
    string? Runtime = null,
    string? RequestedModel = null,
    string? RequestedEffort = null,
    string? Model = null,
    string? Effort = null,
    string? Text = null,
    string? ToolCallId = null,
    string? Title = null,
    string? Kind = null,
    string? Status = null,
    string? Output = null,
    string? Message = null,
    IReadOnlyList<PlanEntry>? Entries = null,
    string? Parent = null,
    IReadOnlyList<EventLocation>? Locations = null,
    IReadOnlyList<FileChange>? Changes = null,
    EventSubagent? Subagent = null)
{
    public bool ValidDetails =>
        (Runtime is null || Runtime.Length <= 100) &&
        new[] { RequestedModel, RequestedEffort, Model, Effort }.All(v => v is null || v.Length <= 160) &&
        (Locations is null || Locations.Count <= 20 && Locations.All(l => l.Path.Length is > 0 and <= 300)) &&
        (Changes is null || Changes.Count <= 50 && Changes.All(c => c.IsValid)) &&
        (Subagent is null || Subagent.Name.Length is > 0 and <= 100);

    /// <summary>The key that a tool call's updates name (RuntimeToolKey).</summary>
    public (long Attempt, string Session, string? Parent, string Call)? ToolKey =>
        ToolCallId is { } call ? (Attempt, Session, Parent, call) : null;
}

/// <summary>One page of GET /ui/tasks/&lt;id&gt;/events (FleetCore's RuntimePage).</summary>
public sealed record TaskEventPage(string Db, long Task, IReadOnlyList<TaskEvent> Events, long Next, bool More)
{
    /// <summary>The most events that the hub puts in one page.</summary>
    public const int Most = 500;

    public bool IsValid(string database, long task, long after)
    {
        var ids = Events.Select(e => e.Id).ToList();
        return Db == database && Task == task && Events.Count <= Most && Next >= after &&
               ids.SequenceEqual(ids.Order()) && ids.Distinct().Count() == ids.Count &&
               Events.All(e => e.Id > after && e.Attempt > 0 && e.Seq > 0 && e.ValidDetails) &&
               Next == (Events.Count == 0 ? after : Events[^1].Id) && (!More || Events.Count > 0);
    }
}

/// <summary>One row of the record (FleetCore's ActivityRow): an event, with what its updates said since.</summary>
public sealed record ActivityRow(TaskEvent Event, string? Status, string? Output, IReadOnlyList<EventLocation> Locations,
                                 IReadOnlyList<FileChange> Changes, EventSubagent? Subagent, double? UpdatedAt, long LastEventId)
{
    /// <summary>A tool call with no finish, in an attempt that is over (the task's attempt is later, or the attempt that
    /// a confirmed stop ended): its result is not known.</summary>
    public bool EndedWithoutResult(long current, long? stopped) =>
        Event.Type == "tool_call" && Status is not ("completed" or "failed") && (Event.Attempt < current || Event.Attempt == stopped);

    /// <summary>What the agent said: its messages, an error, and the notice that the record was cut short.</summary>
    public bool IsSpoken => Event.Type is "agent_message" or "error" or "truncated";

    /// <summary>A Codex script (`exec:`), whose calls the hub records as rows of their own.</summary>
    public bool IsScript => Event.Type == "tool_call" && Event.Title?.StartsWith("exec:", StringComparison.Ordinal) == true;
    /// <summary>A script that no update ended: one with no update, or one whose last state is not completed or failed.</summary>
    public bool ScriptIsOpen => LastEventId == Event.Id || Status is not ("completed" or "failed");
    /// <summary>A call that the hub recorded at its end: a tool row that is no script and no agent.</summary>
    public bool IsCall => Event.Type == "tool_call" && !IsScript && Subagent is null && Event.Status is "completed" or "failed";
    internal (long Attempt, string Session, string? Parent) Thread => (Event.Attempt, Event.Session, Event.Parent);

    /// <summary>Fleet's own tools, which each have their own row in the app; the five that reach outside the fleet stay.</summary>
    public bool IsFleetTool => Event.Title is { } title && title.StartsWith("fleet: ", StringComparison.Ordinal) &&
                               title[7..] is not ("sign_in" or "hand_over" or "create_login" or "save_key" or "call_api");
}

/// <summary>A task's record as rows (FleetCore's ActivityTimeline): each update merged into its call, the AI providers of
/// each attempt, and the files that completed tools changed.</summary>
public sealed class ActivityTimeline
{
    private readonly List<ActivityRow> rows = [];
    private readonly Dictionary<(long, string, string?, string), int> tools = [];
    private readonly Dictionary<long, SortedSet<string>> runtimes = [];
    private readonly HashSet<long> keptScripts = [];
    private readonly List<ModelUse> models = [];
    private IReadOnlyList<PlanEntry> plan = [];

    public IReadOnlyList<ActivityRow> Rows => rows;
    public IReadOnlyDictionary<long, SortedSet<string>> Runtimes => runtimes;
    /// <summary>The scripts that were on screen with one of their calls when a page came (TaskActivity.keptScripts): they
    /// stay rows, so no row goes away while events arrive.</summary>
    public IReadOnlySet<long> KeptScripts => keptScripts;
    /// <summary>The models that each session of the top level asked for and used (`model` events), each once.</summary>
    public IReadOnlyList<ModelUse> Models => models;
    /// <summary>The plan that the top level wrote last (a top-level `plan` event), for the work that runs.</summary>
    public IReadOnlyList<PlanEntry> Plan => plan;

    /// <summary>The rows of the child agent that a call started (ActivityTimeline.children(of:)).</summary>
    public static IReadOnlyList<ActivityRow> Children(IEnumerable<ActivityRow> rows, (long Attempt, string Session, string? Parent, string Call) key) =>
        rows.Where(r => r.Event.Attempt == key.Attempt && r.Event.Session == key.Session && r.Event.Parent == key.Call).ToList();

    /// <summary>The child agents of the task (TaskActivity.children): each call with a subagent, its name and status.</summary>
    public static IReadOnlyList<TaskChild> ChildAgents(IEnumerable<ActivityRow> rows) =>
        rows.Where(r => r.Subagent is not null && r.Event.ToolKey is not null)
            .Select(r => new TaskChild(ToolKey.Of(r.Event.ToolKey!.Value), r.Subagent!.Name, r.Status)).ToList();

    /// <summary>The rows of the thread's own level (no parent) as they show, a completed script folded into its first call.</summary>
    public IReadOnlyList<ShownRow> TopRows => ShownRow.Of(rows.Where(r => r.Event.Parent is null).ToList(), keptScripts);

    public static ActivityTimeline Of(IEnumerable<TaskEvent> events)
    {
        var timeline = new ActivityTimeline();
        timeline.Append(events);
        return timeline;
    }

    public void Append(IEnumerable<TaskEvent> events)
    {
        var list = events as IReadOnlyList<TaskEvent> ?? events.ToList();
        if (list.Count == 0) return;
        keptScripts.UnionWith(ShownRow.OpenScriptsWithRows(rows));
        foreach (var e in list)
        {
            if (e.Type == "session" && e.Parent is null && !string.IsNullOrEmpty(e.Runtime))
                (runtimes.TryGetValue(e.Attempt, out var set) ? set : runtimes[e.Attempt] = new SortedSet<string>(StringComparer.Ordinal)).Add(e.Runtime);
            if (e.Type == "model" && e.Parent is null && models.All(m => m.Id != e.Id))
                models.Add(new ModelUse(e.Id, e.Attempt, e.Session, e.RequestedModel, e.RequestedEffort, e.Model, e.Effort));
            if (e.Type == "plan" && e.Parent is null)
            {
                plan = e.Entries ?? [];
                continue;
            }
            if (e.Type == "tool_call_update" && e.ToolKey is { } key && tools.TryGetValue(key, out var index))
            {
                var row = rows[index];
                rows[index] = row with
                {
                    Status = e.Status ?? row.Status, Output = e.Output ?? row.Output, Locations = e.Locations ?? row.Locations,
                    Changes = e.Changes ?? row.Changes, Subagent = e.Subagent ?? row.Subagent, UpdatedAt = e.Ts ?? row.UpdatedAt,
                    LastEventId = e.Id,
                };
            }
            else if (e.Type is "agent_message" or "agent_thought" or "tool_call" or "error" or "truncated" or "plan")
            {
                if (e.ToolKey is { } call) tools[call] = rows.Count;
                rows.Add(new ActivityRow(e, e.Status, e.Output, e.Locations ?? [], e.Changes ?? [], e.Subagent, e.Ts, e.Id));
            }
        }
    }

    /// <summary>The latest completed tool report for each path, by path (ActivityTimeline.changedFiles): by its time, and
    /// by the later event when a time is missing or the same.</summary>
    public IReadOnlyList<FileChange> ChangedFiles
    {
        get
        {
            var files = new Dictionary<string, (FileChange Change, double? Time, long EventId)>();
            foreach (var row in rows.Where(r => r.Status == "completed"))
                foreach (var change in row.Changes)
                {
                    if (files.TryGetValue(change.Path, out var previous))
                    {
                        if (row.UpdatedAt is { } time && previous.Time is { } old && time != old) { if (time < old) continue; }
                        else if (row.LastEventId < previous.EventId) continue;
                    }
                    files[change.Path] = (change, row.UpdatedAt, row.LastEventId);
                }
            return files.Values.Select(v => v.Change).OrderBy(c => c.Path, StringComparer.Ordinal).ToList();
        }
    }
}

/// <summary>The key of a tool call (RuntimeToolKey): a child agent's thread opens by it.</summary>
public sealed record ToolKey(long Attempt, string Session, string? Parent, string Call)
{
    public static ToolKey Of((long Attempt, string Session, string? Parent, string Call) key) => new(key.Attempt, key.Session, key.Parent, key.Call);
    public (long, string, string?, string) Tuple => (Attempt, Session, Parent, Call);
}

/// <summary>A child agent of the task (FleetCore's TaskChild): the call that started it, its name and the call's state.</summary>
public sealed record TaskChild(ToolKey Key, string Name, string? Status);

/// <summary>The model and reasoning that a session asked for and used (FleetCore's RuntimeModelUse).</summary>
public sealed record ModelUse(long Id, long Attempt, string Session, string? RequestedModel, string? RequestedEffort, string? Model,
                              string? Effort)
{
    /// <summary>The provider used another model or reasoning than the one asked for.</summary>
    public bool Differs => (RequestedModel is not null && Model is not null && RequestedModel != Model) ||
                           (RequestedEffort is not null && Effort is not null && RequestedEffort != Effort);
}

/// <summary>A row of a thread as it shows (RuntimeActivity's ShownRow): a completed Codex script takes the place of its
/// first call, and the row keeps the script's id.</summary>
public sealed record ShownRow(long Id, ActivityRow Row, ActivityRow? Script = null)
{
    public double Time => (Script ?? Row).Event.Ts ?? 0;

    /// <summary>The rows of one level as they show, in the same order (Array.shown(keeping:)). A script folds only when the
    /// record is clear: completed with "Script completed", one row or more recorded between its first event and its last
    /// update in its thread, each of them a call, and no earlier script of its thread open when it started; and not one in
    /// <paramref name="kept"/>.</summary>
    public static IReadOnlyList<ShownRow> Of(IReadOnlyList<ActivityRow> rows, IReadOnlySet<long> kept)
    {
        var places = new Dictionary<long, ActivityRow>();
        var folded = new HashSet<long>();
        var ends = new Dictionary<(long, string, string?), long>();
        for (var index = 0; index < rows.Count; index++)
        {
            var script = rows[index];
            if (!script.IsScript) continue;
            var thread = script.Thread;
            var before = ends.GetValueOrDefault(thread);
            var overlaps = before > script.Event.Id;
            ends[thread] = Math.Max(before, script.ScriptIsOpen ? long.MaxValue : script.LastEventId);
            if (overlaps || kept.Contains(script.Event.Id) || script.Status != "completed" ||
                script.Output?.StartsWith("Script completed", StringComparison.Ordinal) != true) continue;
            var recorded = rows.Skip(index + 1).TakeWhile(r => r.Event.Id < script.LastEventId).Where(r => r.Thread == thread).ToList();
            if (recorded.Count == 0 || !recorded.All(r => r.IsCall)) continue;
            places[script.Event.Id] = recorded[0];
            folded.Add(recorded[0].Event.Id);
        }
        return rows.Where(r => !folded.Contains(r.Event.Id))
            .Select(r => places.TryGetValue(r.Event.Id, out var call) ? new ShownRow(r.Event.Id, call, r) : new ShownRow(r.Event.Id, r))
            .ToList();
    }

    /// <summary>The scripts that have not ended and already have a later row in their thread.</summary>
    public static IEnumerable<long> OpenScriptsWithRows(IReadOnlyList<ActivityRow> rows) =>
        rows.Select((script, index) => (script, index))
            .Where(x => x.script.IsScript && x.script.ScriptIsOpen && rows.Skip(x.index + 1).Any(r => r.Thread == x.script.Thread))
            .Select(x => x.script.Event.Id);
}

/// <summary>A permission of the task that its thread shows (GET /ui/mobile/task/&lt;id&gt; since owner API 1.161; FleetCore's
/// FleetPermission): one that waits, or a refusal.</summary>
public sealed record TaskPermission(long Id, string Tool, string Input, double Created, string? Decision = null, string? Reason = null)
{
    /// <summary>The thread shows it (FleetPermission.needsReading).</summary>
    public bool NeedsReading => Decision is null or "deny";
}

/// <summary>One entry of a task's thread (RuntimeActivity.entries): a run of steps, a row that the agent said, a note, a
/// permission, or the owner's guidance.</summary>
public sealed record ThreadEntry(IReadOnlyList<ShownRow>? Steps = null, ShownRow? Said = null, ProgressNote? Note = null,
                                 TaskPermission? Permission = null, TaskSteer? Steer = null)
{
    /// <summary>The thread of a task, as the Mac makes it: the top rows in order, with Fleet's own tools left out; what
    /// the agent said (a message, an error, the record's cut) ends a run of steps and stands alone, and a thought is a
    /// step of its run; the owner's guidance, each note and each permission that needs reading go in, in that order at
    /// one time, where their time is not later than the latest row so far, and end the run before them; the rest at the
    /// end.</summary>
    public static IReadOnlyList<ThreadEntry> Of(IReadOnlyList<ShownRow> top, IReadOnlyList<ProgressNote> notes,
                                                IReadOnlyList<TaskPermission> permissions, IReadOnlyList<TaskSteer>? steers = null)
    {
        var said = (steers ?? []).Select(g => (Time: g.Created, Entry: new ThreadEntry(Steer: g)))
            .Concat(notes.Select(n => (Time: n.Ts, Entry: new ThreadEntry(Note: n))))
            .Concat(permissions.Where(p => p.NeedsReading).Select(p => (Time: p.Created, Entry: new ThreadEntry(Permission: p))))
            .OrderBy(x => x.Time).ToList();
        var composed = new List<ThreadEntry>();
        var work = new List<ShownRow>();
        var spoken = 0;
        var clock = 0.0;
        void Flush()
        {
            if (work.Count == 0) return;
            composed.Add(new ThreadEntry(Steps: work.ToList()));
            work.Clear();
        }
        void Say(double moment)
        {
            while (spoken < said.Count && said[spoken].Time <= moment)
            {
                Flush();
                composed.Add(said[spoken].Entry);
                spoken++;
            }
        }
        foreach (var shown in top.Where(r => r.Row.Event.Parent is null && !r.Row.IsFleetTool))
        {
            clock = Math.Max(clock, shown.Time);
            Say(clock);
            if (shown.Row.IsSpoken)
            {
                Flush();
                composed.Add(new ThreadEntry(Said: shown));
            }
            else work.Add(shown);
        }
        Flush();
        Say(double.PositiveInfinity);
        return composed;
    }
}

/// <summary>The words of a task's steps (RuntimeActivity: StepsRow, RuntimeRow, toolTitle, toolStatus), one whole sentence
/// each.</summary>
public static class StepWords
{
    public static string Count(int steps) => steps == 1 ? "1 step" : $"{steps} steps";
    public static string Failed(int failed) => failed == 1 ? "1 failed" : $"{failed} failed";
    public static string Running(int steps) => steps == 1 ? "Running" : $"Step {steps} · Running";

    /// <summary>A tool's title as the thread writes it: "Tool" with none, "Run tools" for a script, a Fleet tool's name
    /// in words, else the title as it is.</summary>
    public static string ToolTitle(string? title) => title switch
    {
        null => "Tool",
        _ when title.StartsWith("exec:", StringComparison.Ordinal) => "Run tools",
        _ when title.StartsWith("fleet: ", StringComparison.Ordinal) => AgentBook.Capitalized(title[7..].Replace('_', ' ')),
        _ => title,
    };

    /// <summary>A step with no finish in an attempt that is over.</summary>
    public const string ResultUnknown = "Result unknown";
    public const string Thinking = "Thinking";
    public const string NoOutput = "No output reported.";
    public const string ScriptResult = "Script result";
    /// <summary>A child agent's row with no title, text or message, under its call.</summary>
    public const string Activity = "Activity";
    public const string OpenAgentThread = "Open agent thread";
    public const string RuntimeError = "Runtime error";
    public const string Truncated = "The worker reached its activity record limit.";
    public const string Plan = "Plan";
    public const string Earlier = "Earlier activity";
    /// <summary>The rows that a thread shows at first, and that "Earlier activity" adds each time.</summary>
    public const int ShownAtOnce = 80;
    public const string Offline = "Offline · last activity";
    public const string Unavailable = "Activity is unavailable. Retrying…";
    public const string Back = "Back";
    public const string AgentThread = "Agent thread";
    public const string WaitingForAgent = "Waiting for agent activity.";
    public const string ChildAgents = "Child agents";
    public const string MoreAgents = "More agents in the task thread";
    public const string OtherSettings = "The AI provider used other settings";
    public const string Automatic = "Automatic";
    public const string NotReported = "Not reported";

    public static string Attempt(long attempt) => $"Attempt {attempt}";
    /// <summary>A child agent's hover in the panel.</summary>
    public static string OpenChild(long attempt) => $"Open child thread · Attempt {attempt}";
    /// <summary>The line under the owner's guidance in the thread: its attempt and whether it reached the task.</summary>
    public static string Guidance(TaskSteer steer, long currentAttempt) => $"Guidance · Attempt {steer.Attempt} · {Delivery(steer, currentAttempt)}";
    /// <summary>TaskSteer.deliveryLabel: "Read", "Not delivered · task restarted" or "Received".</summary>
    public static string Delivery(TaskSteer steer, long currentAttempt) =>
        steer.ReadAt is not null ? "Read" : currentAttempt > steer.Attempt ? "Not delivered · task restarted" : "Received";
    /// <summary>A reasoning level as the owner reads it (reasoningName): "Extra high" for xhigh, else with a capital.</summary>
    public static string Reasoning(string level) => level == "xhigh" ? "Extra high" : level.Length == 0 ? level : char.ToUpperInvariant(level[0]) + level[1..];
    /// <summary>The hub's own sentence of a refused read (HubError.said), or null when it gave none (this client's "The
    /// hub gave no reason.", the Mac's "Unexpected HTTP response.").</summary>
    public static string? Said(Exception e) =>
        e is HubException { Kind: HubErrorKind.Refusal, HubWords: { } words } && words.Trim() is { Length: > 0 } said &&
        said is not ("Unexpected HTTP response." or "The hub gave no reason.") ? said : null;
    /// <summary>A permission that waits for its decision.</summary>
    public const string Waiting = "Waiting";

    public static string ToolStatus(string? status) => status switch
    {
        "completed" => "Done",
        "failed" => "Failed",
        "in_progress" => "Running",
        _ => "Waiting",
    };

    public static StepSymbol Symbol(string? kind) => kind switch
    {
        "read" => StepSymbol.Read,
        "search" => StepSymbol.Search,
        "edit" or "move" or "delete" => StepSymbol.Edit,
        "execute" => StepSymbol.Execute,
        "fetch" => StepSymbol.Fetch,
        _ => StepSymbol.Other,
    };

    /// <summary>A changed file's action as the panel writes it: "Add", "Modify", "Delete", "Move".</summary>
    public static string Action(string action) => action switch
    {
        "add" => "Add",
        "modify" => "Modify",
        "delete" => "Delete",
        "move" => "Move",
        _ => AgentBook.Capitalized(action),
    };

    public static string Added(long added) => $"+{added}";
    public static string Removed(long removed) => $"−{removed}";
}

/// <summary>The mark of a step: a tool's kind, a thought, a child agent, or the run's own mark.</summary>
public enum StepSymbol { Read, Search, Edit, Execute, Fetch, Other, Thought, Subagent, Steps, Plan }

public sealed partial class HubClient
{
    /// <summary>GET /ui/tasks/&lt;id&gt;/events?db=&amp;after=&amp;limit= (HubClient.taskEvents): one page of a task's
    /// record after <paramref name="after"/>, held to the page's rules.</summary>
    public async Task<TaskEventPage> TaskEventsAsync(Uri hub, string? key, string database, long task, long after, int limit,
                                                     CancellationToken cancel = default)
    {
        if (task <= 0 || after < 0) throw HubException.InvalidResponse("GET /ui/tasks/events", "not a task and a cursor");
        limit = Math.Clamp(limit, 1, TaskEventPage.Most);
        using var request = Request(HttpMethod.Get, hub, $"ui/tasks/{task}/events", key,
                                    [("db", database), ("after", after.ToString(CultureInfo.InvariantCulture)),
                                     ("limit", limit.ToString(CultureInfo.InvariantCulture))]);
        var bytes = Math.Max(3, (3 * limit + 199) / 200) * 1024 * 1024;
        var answer = await SendAsync(request, bytes, options.RequestTimeout, cancel);
        TaskEventPage page;
        try
        {
            page = System.Text.Json.JsonSerializer.Deserialize(answer.Body, CoreJson.Default.TaskEventPage)
                   ?? throw HubException.InvalidResponse("GET /ui/tasks/events", "no page");
        }
        catch (System.Text.Json.JsonException e)
        {
            throw HubException.InvalidResponse("GET /ui/tasks/events", e.Message, e);
        }
        if (!page.IsValid(database, task, after)) throw HubException.InvalidResponse("GET /ui/tasks/events", "the page breaks its rules");
        return page;
    }
}
