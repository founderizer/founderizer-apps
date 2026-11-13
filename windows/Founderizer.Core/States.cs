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
            // No work now where its session's last turn ended and nothing of it runs (`works` false, hub 1.147).
            "working" => new(TaskSymbol.Working, words, false, task.Works != false),
            "submitted" => new(TaskSymbol.Queued, words, false, false),
            _ => new(TaskSymbol.Ended, words, false, false),
        };
    }
}

/// <summary>The meaning of a task's mark. The Mac and the iPhone draw them as SF Symbols: Unknown questionmark.circle,
/// Alert exclamationmark.circle, Paused pause.circle, Checked checkmark.circle.fill, Failed exclamationmark.circle.fill,
/// Ended circle, Limit hourglass, Reconnecting arrow.triangle.2.circlepath, Question questionmark.circle, SignIn key,
/// Working circle.dotted, Queued clock.</summary>
public enum TaskSymbol { Unknown, Alert, Paused, Checked, Failed, Ended, Limit, Reconnecting, Question, SignIn, Working, Queued }
