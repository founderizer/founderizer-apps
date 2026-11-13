using System;
using System.Collections.Generic;
using System.Linq;

namespace Founderizer.Core;

/// <summary>Where each request of an agent stands in its chat (FleetCore's ChatRequestPlaces, read over the device's
/// chat items as the iPhone's ChatPage.places reads it): right after the agent's message that told the owner about it,
/// else a waiting one at the end and an answered one in the place of his answer.</summary>
public sealed record ChatPlaces
{
    /// <summary>The cards that stand right after an item, by the item's id ("report-17"), in the order raised.</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<long>> After { get; init; } = new Dictionary<string, IReadOnlyList<long>>();
    /// <summary>The requests at the end of the chat, in the order raised.</summary>
    public IReadOnlyList<long> AtEnd { get; init; } = [];
    /// <summary>His answer messages, by item id, whose folded card stands in their place.</summary>
    public IReadOnlyDictionary<string, long> InPlaceOf { get; init; } = new Dictionary<string, long>();
    /// <summary>His answer messages that are not drawn: their card shows them.</summary>
    public IReadOnlySet<string> Hidden { get; init; } = new HashSet<string>();

    /// <summary>The places of <paramref name="needs"/> (this agent's requests, waiting and answered) among its chat's
    /// items, oldest first. The device holds a chat's newest pages only (`whole` false): a request older than every item
    /// waits at the end. A waiting card whose answer the chat already holds hides that answer, and an answered card whose
    /// answer the chat has not read yet stands at the end, where that answer comes.</summary>
    public static ChatPlaces Of(IReadOnlyList<OwnerNeed> needs, IReadOnlyList<MobileChatItem> items, bool whole = false)
    {
        if (needs.Count == 0) return new ChatPlaces();
        var after = new Dictionary<string, List<long>>();
        var atEnd = new List<long>();
        var inPlaceOf = new Dictionary<string, long>();
        var hidden = new HashSet<string>();
        foreach (var need in needs.OrderBy(n => n.Raised).ThenBy(n => n.Id))
        {
            var answer = items.FirstOrDefault(i => i.Kind == "message" && i.AnswerTo == need.Id)?.Id;
            if (Told(need, items, whole) is { } message)
            {
                (after.TryGetValue(message, out var list) ? list : after[message] = []).Add(need.Id);
                if (answer is not null) hidden.Add(answer);
            }
            else if (need.IsOpen) atEnd.Add(need.Id);
            else if (answer is not null) inPlaceOf[answer] = need.Id;
        }
        foreach (var id in atEnd)
            if (items.FirstOrDefault(i => i.Kind == "message" && i.AnswerTo == id) is { } answer) hidden.Add(answer.Id);
        if (items.Count > 0)
        {
            var newest = items[^1].Ts;
            var placed = after.Values.SelectMany(v => v).Concat(atEnd).Concat(inPlaceOf.Values).ToHashSet();
            var late = needs.Where(n => !n.IsOpen && !placed.Contains(n.Id) && (n.Answered ?? 0) > newest).ToList();
            if (late.Count > 0)
                atEnd = needs.Where(n => atEnd.Contains(n.Id)).Concat(late).OrderBy(n => n.Raised).ThenBy(n => n.Id)
                    .Select(n => n.Id).ToList();
        }
        return new ChatPlaces
        {
            After = after.ToDictionary(p => p.Key, p => (IReadOnlyList<long>)p.Value),
            AtEnd = atEnd,
            InPlaceOf = inPlaceOf,
            Hidden = hidden,
        };
    }

    /// <summary>The agent's message that told the owner about a request: its reply after the request was raised (up to
    /// his next message), else its message right before it with nothing of his between, else none.</summary>
    private static string? Told(OwnerNeed need, IReadOnlyList<MobileChatItem> items, bool whole)
    {
        var split = items.Count;
        for (var i = 0; i < items.Count; i++) if (items[i].Ts >= need.Raised) { split = i; break; }
        if (split == 0 && !whole) return null;
        string? reply = null;
        for (var i = split; i < items.Count; i++)
        {
            if (items[i].Kind != "report") break;
            reply = items[i].Id;
        }
        if (reply is not null) return reply;
        return split > 0 && items[split - 1].Kind == "report" ? items[split - 1].Id : null;
    }
}

/// <summary>What the hub knows about the owner's newest message to an agent (FleetCore's ChatWaiting.Pending).</summary>
public enum ChatPending { None, Waiting, SpokenSince, TurnOver }

/// <summary>What the chat says while the owner waits for an answer (FleetCore's ChatWaiting): one word for the agent's own
/// work, and words of their own, standing still, for a wait that is not its work.</summary>
public sealed record ChatWaiting(string Says, bool Moving, string? Detail = null)
{
    public const string Working = "Thinking";
    public const string Limited = "Usage limit";

    /// <summary>The meaning of a still wait's mark: the hourglass for a usage limit, the clock for the others.</summary>
    public string Symbol => Says == Limited ? "hourglass" : "clock";

    /// <summary>The turn that took his message is over (hub 1.110): a message sent at or before the time that the hub
    /// gives was read in a turn that ended.</summary>
    public static bool TurnIsOver(double sent, double? turnEndedAfter) => turnEndedAfter is { } ended && sent <= ended;

    /// <summary>His newest message, as the chat's items say it (ChatPage.pending): only a reply that names it answers it;
    /// a report since that names none says nothing either way; a report the agent wrote first is no reply; his answer to
    /// a request is no message that waits; and a message read in a turn that ended is not worked on.</summary>
    public static ChatPending Pending(IReadOnlyList<MobileChatItem> items, double? turnEndedAfter = null)
    {
        var message = items.LastOrDefault(i => i.Kind == "message" && i.AnswerTo is null);
        if (message is null) return ChatPending.None;
        var replies = items.Where(i => i.Kind == "report" && !i.IsPushed).ToList();
        if (replies.Any(r => string.Equals(r.InReplyTo, message.Key, StringComparison.OrdinalIgnoreCase))) return ChatPending.None;
        if (replies.Any(r => r.InReplyTo is null && r.Ts >= message.Ts)) return ChatPending.SpokenSince;
        if (TurnIsOver(message.Ts, turnEndedAfter)) return ChatPending.TurnOver;
        return ChatPending.Waiting;
    }

    /// <summary>The wait when the hub says that his newest message is late (hub 1.144): a word of the agent that names no
    /// message ends nothing then.</summary>
    public static ChatPending Late(ChatPending pending, bool? late) =>
        late == true && pending == ChatPending.SpokenSince ? ChatPending.Waiting : pending;

    /// <summary>What the chat shows under the last message, or null when nothing is waited for (ChatWaiting.of).
    /// <paramref name="sending"/>: a request of this device to this agent is on its way. <paramref name="until"/> writes a
    /// time of the fleet for the owner.</summary>
    public static ChatWaiting? Of(string agent, ChatPending pending, bool sending, RuntimeLimit? limit, bool offline,
                                  AgentBook names, Func<double, string> until)
    {
        if (pending != ChatPending.Waiting && !sending) return null;
        var who = names.Label(agent);
        if (limit is not null)
            return new ChatWaiting(Limited, false, limit.ResetKnown ? $"{who} is at its usage limit until {until(limit.Until)}."
                                                                    : $"{who} is at its usage limit.");
        if (offline)
            return new ChatWaiting("Not answering", false,
                                   $"{who} is not answering. Your message is kept and reaches it when it is back.");
        return new ChatWaiting(Working, true);
    }

    /// <summary>Whether an agent works on his newest chat message now (MobileStore.thinks): its mark moves, and its row's
    /// line moves, as for a task in work. Never while it is in setup, at its usage limit, with a server that does not
    /// answer, while his message is late, or from a reading that is not current. With the hub's word (`chat_waits`), from
    /// `waits_since`; with an older hub, only for a chat that this device read up to its newest line.</summary>
    public static bool Thinks(MobileAgent agent, IReadOnlyList<MobileChatItem> items, double time, bool hubSays, bool current)
    {
        if (!current || agent.Active == false || agent.Limit is not null || !agent.HelperIsRecent(time) ||
            agent.ChatUndelivered == true)
            return false;
        if (hubSays)
            return agent.WaitsSince is { } sent && !TurnIsOver(sent, agent.TurnEndedAfter);
        if (agent.Last is not { } last || items.Count == 0 || items.Max(i => i.Ts) < last.Ts - 0.001) return false;
        return Pending(items, agent.TurnEndedAfter) == ChatPending.Waiting;
    }
}
