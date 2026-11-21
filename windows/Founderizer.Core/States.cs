using System;
using System.Collections.Generic;
using System.Linq;

namespace Founderizer.Core;

/// <summary>An agent's state, as the hub reports it (the iPhone's AgentState, ios/Sources/MobileStyle.swift).</summary>
public enum AgentState { Unknown, Setup, Offline, Limited, Working, Online, Attention }

/// <summary>The tone of a state's word or dot: green for an agent that answers or works, orange for one that needs
/// someone or cannot work, muted for one that is in setup, not known, or of an old reading.</summary>
public enum StateTone { Online, Warning, Muted }

/// <summary>An agent's state with its words and its look (AgentState with its `attention` words and its `old` case).</summary>
public sealed record AgentStatus(AgentState State, string? AttentionWords = null, bool Old = false)
{
    /// <summary>The state's words, the Mac's, on the screen and for a screen reader.</summary>
    public string Words => Old ? "Last reading" : State switch
    {
        AgentState.Unknown => "Last reading",
        AgentState.Setup => "In setup",
        AgentState.Offline => "Not answering",
        AgentState.Limited => "Usage limit",
        AgentState.Attention => AttentionWords ?? "",
        AgentState.Working => "Working",
        _ => "Online",
    };

    /// <summary>The colour of the dot, from the state the look is drawn from.</summary>
    public StateTone DotTone => State switch
    {
        AgentState.Online or AgentState.Working => StateTone.Online,
        AgentState.Offline or AgentState.Limited or AgentState.Attention => StateTone.Warning,
        _ => StateTone.Muted,
    };

    /// <summary>The colour of the words, which an old reading mutes.</summary>
    public StateTone WordTone => Old ? StateTone.Muted : DotTone;

    /// <summary>A dot is a problem: online has none, and work shows as motion (a dot only where the owner's system asks
    /// for less motion).</summary>
    public bool HasDot(bool reduceMotion) => State switch
    {
        AgentState.Online => false,
        AgentState.Working => reduceMotion,
        _ => true,
    };

    /// <summary>A ring, not a filled dot: the agent takes no work now.</summary>
    public bool IsRing => State is AgentState.Unknown or AgentState.Setup or AgentState.Offline;

    /// <summary>The state that the mark is drawn from: an old reading keeps the look it read, at rest.</summary>
    public AgentState MarkState => Old && State == AgentState.Working ? AgentState.Online : State;

    /// <summary>The agent's state from the device's read (MobileAgent.mobileState): in setup, not answering, its usage
    /// limit, then its open tasks by their marks (work only for a task in work with no hold, stall or lost session; a task
    /// that needs someone says its own word), and else online. <paramref name="thinking"/>: its chat says "Thinking".
    /// <paramref name="fresh"/>: the reading is current; an old one keeps its look and rests.</summary>
    public static AgentStatus Of(MobileAgent agent, MobileSnapshot snapshot, bool fresh, bool thinking = false)
    {
        var state = Read(agent, snapshot, thinking);
        return fresh ? state : state with { Old = true };
    }

    private static AgentStatus Read(MobileAgent agent, MobileSnapshot snapshot, bool thinking)
    {
        if (agent.Active == false) return new(AgentState.Setup);
        if (!agent.HelperIsRecent(snapshot.Time)) return new(AgentState.Offline);
        if (agent.Limit is not null) return new(AgentState.Limited);
        var marks = snapshot.Tasks.Where(t => t.Owner == agent.Name)
            .Select(t => TaskMark.Of(t, snapshot.Holds, AgentBook.Of(snapshot), limited: false)).ToList();
        if (thinking || marks.Any(m => m.InWork)) return new(AgentState.Working);
        if (marks.FirstOrDefault(m => m.Attention) is { } waiting) return new(AgentState.Attention, waiting.Words);
        return new(AgentState.Online);
    }
}

/// <summary>The mark of a task, from its head (the iPhone's MobileTaskHead.mark, FleetCore's FleetTask.mark): its symbol,
/// its one state word, whether it needs someone, and whether it is work now. The symbol is a name of the meaning, which
/// each app draws with its own icon.</summary>
public sealed record TaskMark(TaskSymbol Symbol, string Words, bool Attention, bool InWork)
{
    /// <summary>The mark: an outcome that is not known first, then the owner's hold, a result, the usage limit, a stall, a
    /// lost session, a question or a sign-in, a wait, and its state.</summary>
    public static TaskMark Of(MobileTaskHead task, IReadOnlyList<TaskHold> holds, AgentBook names, bool limited,
                              bool outcomeUnknown = false)
    {
        if (outcomeUnknown) return new(TaskSymbol.Unknown, "Outcome not known: check it", true, false);
        var hold = holds.FirstOrDefault(h => h.Task == task.Id && h.State != "released");
        var words = TaskWords.State(task.State, task.Accepted, task.Requester, names, task.WaitingOn,
                                    task.StalledSince is not null || (task.NudgeLevel ?? 0) > 0,
                                    task.MissingSince is not null, hold, limited);
        if (hold is not null)
            return hold.State == "not_confirmed" ? new(TaskSymbol.Alert, words, true, false) : new(TaskSymbol.Paused, words, false, false);
        if (task.IsTerminal)
        {
            if (task.Accepted == 1 && task.State == "completed") return new(TaskSymbol.Checked, words, false, false);
            if (task.FailedResult() is not null) return new(TaskSymbol.Failed, words, task.State != "canceled", false);
            return new(TaskSymbol.Ended, words, false, false);
        }
        if (limited) return new(TaskSymbol.Limit, words, true, false);
        if (task.StalledSince is not null || (task.NudgeLevel ?? 0) > 0) return new(TaskSymbol.Alert, words, true, false);
        if (task.MissingSince is not null) return new(TaskSymbol.Reconnecting, words, true, false);
        if (task.State == "input-required") return new(TaskSymbol.Question, words, true, false);
        if (task.State == "auth-required") return new(TaskSymbol.SignIn, words, true, false);
        if (!string.IsNullOrEmpty(task.WaitingOn)) return new(TaskSymbol.Limit, words, true, false);
        return task.State switch
        {
            // No work now where its agent parked it until a time (`parked_until`, hub 1.161), or where its session's last
            // turn ended and nothing of it runs (`works` false, hub 1.147).
            "working" => new(TaskSymbol.Working, words, false, task.ParkedUntil is null && task.Works != false),
            "submitted" => new(TaskSymbol.Queued, words, false, false),
            _ => new(TaskSymbol.Ended, words, false, false),
        };
    }
}

/// <summary>The mark in the place of an answered card's check (FleetCore's AnsweredMark; owner API 1.280, feature
/// `need_marks`; the owner's "Yes, as drawn" of 21 November 2026 to the marks on an answered Needs-you card in the chats,
/// and his "Yes, same marks there" to the answered request at hand in Needs you): the check while nothing runs that the
/// hub knows, the turning green mark of work while a record proves that work runs, the red mark of work that ended with
/// no success, and the orange mark of a task that needs him (his "Orange mark" of the same day: "The same orange mark as
/// the task's own row"), with the row's own symbol (<see cref="Row"/>) and words, so that the row and the card never
/// disagree. A task whose row is muted (queued, at rest, his own pause, a result that waits for its check) is the check
/// with its state word. <see cref="Words"/> are what an assistive app reads for the mark, and <see cref="Hover"/> what
/// shows under the pointer; for the work of a task, <see cref="Badge"/> and <see cref="Title"/> show there. <see cref="Plain"/>
/// is the check with no words, where no mark of his answer stands: a written answer, a request that a saved key answered,
/// an answer on its way, and an open card. <see cref="Row"/> is null for the other three looks.</summary>
public sealed record AnswerMark(AnswerSymbol Symbol, string? Words = null, string? Agent = null, string? Title = null,
                                TaskSymbol? Row = null)
{
    public static readonly AnswerMark Plain = new(AnswerSymbol.Check);

    /// <summary>`ui_features` of a hub that gives an item's `team_state`, `team_reason` and `task`.</summary>
    public const string Feature = "need_marks";

    /// <summary>The badge of the agent whose task is in work now (<see cref="Agent"/>), which the hover of the work mark
    /// draws before " · " and the task's <see cref="Title"/>; <see cref="Screens.AnsweredMark"/> adds it. Null for every
    /// other mark.</summary>
    public AgentBadge? Badge { get; init; }

    /// <summary>The plain words under the pointer, as the system's tooltip. None for the work of a task: there the
    /// pointer shows the tag of the owner's "Yes, badge as drawn" (21 November 2026; the Mac's AnsweredMarkView tag),
    /// the agent's <see cref="Badge"/>, then " · " and the task's <see cref="Title"/>, and an assistive app reads the
    /// same <see cref="Words"/>. Null where there are no words, so that no empty tip shows.</summary>
    public string? Hover =>
        string.IsNullOrEmpty(Words) || Symbol == AnswerSymbol.Working && !string.IsNullOrEmpty(Agent) ? null : Words;

    /// <summary>The mark of <paramref name="need"/> once he answered it with an option (OwnerNeed.answeredMark), from the
    /// reading: a team card says where its plan stands (`team_state`: "The hub makes the change", "Changed", or the hub's
    /// own `team_reason`); Give that he pressed is "Given"; the task that his answer lets go on (`task`), in the order of
    /// the Mac's FleetTask.tint, as <see cref="TaskMark"/> marks it: the red mark for a result that is no success, with its
    /// word ("Failed", "Rejected", "Canceled", "Not accepted"), the check with "Done" for a checked result, the orange mark
    /// where the task's row needs someone (<see cref="TaskMark.Attention"/>: an outcome that is not known, a hold of his
    /// that is not confirmed, a usage limit, a stall, a lost session, a question, a sign-in, a wait), with the row's symbol
    /// and words, work while it is in work now (its agent and its title), and else the check with its state word
    /// ("Queued", "Working" at rest, "Paused", "Awaiting check"). <see cref="TaskMark.Of"/> reads an outcome that is not
    /// known first and the owner's hold before a result and before work, so a task that failed and is held wears its
    /// hold's mark (orange for a hold that is not confirmed, the check with "Paused" for his own pause), and a held task is
    /// never work now. Else, from a hub before the feature, and for a task that the reading does not hold, the check, and
    /// the agent that raised it has his answer. The caller leaves out the cards that keep no mark
    /// (<see cref="Screens.AnsweredMark"/>).</summary>
    public static AnswerMark Of(OwnerNeed need, MobileSnapshot? fleet, IReadOnlyList<MobileTaskHead> tasks, AgentBook names)
    {
        var received = new AnswerMark(AnswerSymbol.Check, $"{names.Label(need.By)} has your answer");
        if (fleet is null || !fleet.Offers(Feature)) return received;
        switch (need.TeamState)
        {
            case "making": return new(AnswerSymbol.Working, "The hub makes the change");
            case "not_made": return new(AnswerSymbol.Failed, need.TeamReason ?? "");
            case "made": return new(AnswerSymbol.Check, "Changed");
        }
        if (need.Gives && need.Chosen == 0) return new(AnswerSymbol.Check, "Given");
        if (need.Task is not { } id || tasks.FirstOrDefault(t => t.Id == id) is not { } task) return received;
        var mark = TaskMark.Of(task, fleet.Holds, names, fleet.Agents.Any(a => a.Name == task.Owner && a.Limit is not null),
                               outcomeUnknown: Activity.OutcomeUnknown(fleet, task));
        // The task's tint (FleetTask.tint): a filled red or green result only for a task that is over with no hold, as
        // TaskMark draws them; then orange where its row is orange, with the row's symbol and words.
        if (mark.Symbol == TaskSymbol.Failed) return new(AnswerSymbol.Failed, task.FailedResult() ?? mark.Words);
        if (mark.Symbol == TaskSymbol.Checked) return new(AnswerSymbol.Check, "Done");
        if (mark.Attention) return new(AnswerSymbol.Attention, mark.Words, Row: mark.Symbol);
        if (mark.InWork) return new(AnswerSymbol.Working, $"{names.Label(task.Owner)} · {task.Title}", task.Owner, task.Title);
        return new(AnswerSymbol.Check, mark.Words);
    }
}

/// <summary>An agent's name as a badge in words (the Mac's CardBadgeText for an agent): its mark, then its
/// <see cref="Label"/> as the words name it. The mark is at rest, in its own colours, and grey for an agent that is not
/// there (offline, or not in the reading), as the Mac's badge draws it.</summary>
public sealed record AgentBadge(string Label, MarkLook Mark)
{
    /// <summary>The badge of <paramref name="agent"/> in this reading.</summary>
    public static AgentBadge Of(StoreState s, string agent, DateTimeOffset now)
    {
        var absent = s.StatusOf(agent, now).State is AgentState.Offline or AgentState.Unknown;
        return new(s.Names.Label(agent), MarkLook.Of(s.MarkOf(agent), absent ? AgentState.Offline : AgentState.Online, moves: false));
    }
}

/// <summary>The four looks of an answered card's mark: the check, the turning green mark of work (as the search card's
/// <see cref="TaskSymbol.Working"/>), the red mark of a result that is no success (its <see cref="TaskSymbol.Failed"/>),
/// and the orange mark of a task that needs him: the task's own symbol (<see cref="AnswerMark.Row"/>) with the search
/// card's icon for it, in the search card's orange.</summary>
public enum AnswerSymbol { Check, Working, Failed, Attention }

/// <summary>The meaning of a task's mark. The Mac and the iPhone draw them as SF Symbols: Unknown questionmark.circle,
/// Alert exclamationmark.circle, Paused pause.circle, Checked checkmark.circle.fill, Failed exclamationmark.circle.fill,
/// Ended circle, Limit hourglass, Reconnecting arrow.triangle.2.circlepath, Question questionmark.circle, SignIn key,
/// Working circle.dotted, Queued clock.</summary>
public enum TaskSymbol { Unknown, Alert, Paused, Checked, Failed, Ended, Limit, Reconnecting, Question, SignIn, Working, Queued }
