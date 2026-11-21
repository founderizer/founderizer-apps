using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace Founderizer.Core;

/// <summary>The pages of step 1 (windows-app-pictures.md), and the welcome page of the first run (windows-app-plan-v2.md,
/// 5.1; its picture is set 8).</summary>
public enum PageKind { AddThisPc, Settings, Needs, Tasks, Task, Chat, Welcome }

/// <summary>Where the window is: a page, with its agent or its task.</summary>
public sealed record Page(PageKind Kind, string? Agent = null, long? Task = null)
{
    public static readonly Page Needs = new(PageKind.Needs);
    public static readonly Page Tasks = new(PageKind.Tasks);
    public static readonly Page Settings = new(PageKind.Settings);
    public static readonly Page AddThisPc = new(PageKind.AddThisPc);
    public static readonly Page Welcome = new(PageKind.Welcome);
    public static Page Chat(string agent) => new(PageKind.Chat, agent);
    public static Page OfTask(long id) => new(PageKind.Task, Task: id);
}

/// <summary>Who made Founderizer: the words of the credit, the handle and the address it opens. The screens give the
/// credit of FleetCore's Credit.swift.</summary>
public sealed record Credit(string Line, string Handle, Uri Profile)
{
    /// <summary>Who made Founderizer, the same on the Mac, the phone and the PC: FleetCore's Credit.swift, value for value
    /// (the owner's yes of 10 November 2026, "Yes, add them", and his yes to picture 6). The one place of these values in
    /// this library; a test holds them equal to Credit.swift.</summary>
    public static readonly Credit Founderizer = new("Made by Miguel Pieras", "@mpieras", new Uri("https://x.com/mpieras"));

    /// <summary>The phone's one muted line (Credit.oneLine): these words, then the handle, which alone is the link to
    /// <see cref="Profile"/>.</summary>
    public string Words => Line + " · ";

    /// <summary>The whole line as text, for a screen reader.</summary>
    public string OneLine => Words + Handle;
}

/// <summary>The screen models of step 1, each built from one <see cref="StoreState"/>: what a screen draws, with the
/// rules and the words of the Mac's views and the iPhone's pages. A model is a record whose lists compare by value, so
/// two builds with the same rows are equal and <see cref="RowDiff"/> names the rows that changed.</summary>
public static partial class Screens
{
    // ---------------------------------------------------------------- the frame

    /// <summary>The page that the window opens on (FleetStore.home; windows-app-plan-v2.md, 5.1). A PC with no hub: in a
    /// window that has the welcome page (<see cref="StoreState.HasWelcome"/>), the welcome page once the PC's search
    /// found no Tailscale or no hub on it, else Add this PC, so a hub that the search finds opens Add this PC. A device
    /// with no key: Add this PC. Then Needs you while a request is open; else the chat of the first agent whose role is
    /// "manager". The owner's computer of a hub never opens on Add this PC: with no key it is known by its address.</summary>
    public static Page FirstPage(StoreState s)
    {
        if (s.HasNoHub)
            return s.HasWelcome && s.Search is HubSearch.NoNetwork or HubSearch.NoHub ? Page.Welcome : Page.AddThisPc;
        if (s.Role == HubRole.Device && s.Key == KeyState.None && s.Fleet is null) return Page.AddThisPc;
        if (s.Fleet is { } fleet && fleet.Needs.Any(n => n.IsOpen)) return Page.Needs;
        return Page.Chat(ManagerName(s));
    }

    /// <summary>The fleet's manager: the first agent with the role "manager", else the name "manager".</summary>
    public static string ManagerName(StoreState s) => s.Fleet?.Agents.FirstOrDefault(a => a.Role == "manager")?.Name ?? "manager";

    /// <summary>The line over every page while the reading is not current, with its one action, or null.</summary>
    public static ConnectionLine? Line(StoreState s, DateTimeOffset now) =>
        s.UnavailableWords(now) is { } words ? new ConnectionLine(words, s.OutageNeedsSettings) : null;

    // ---------------------------------------------------------------- the pane

    /// <summary>The pane: Needs you with its count (only while something waits, or while its page shows), Tasks, the
    /// agents in the hub's order with their marks, lines and times, and Search only with a hub's reading.</summary>
    public static PaneModel Pane(StoreState s, Page page, DateTimeOffset now, ScreenContext context, bool reduceMotion = false)
    {
        var fleet = s.Fleet;
        var count = fleet is null ? 0 : Activity.NeedsYouCount(fleet, s.EndedTasks);
        var hubNow = fleet?.Time ?? s.HubNow(now);
        var rows = new List<AgentRow>();
        foreach (var agent in fleet?.Agents ?? [])
        {
            var status = s.StatusOf(agent.Name, now);
            var (request, newest) = WaitingRequest(s, agent);
            var preview = request?.Title ?? ChatLine.Preview(agent.Name, agent.Last, fleet!.Tasks);
            var at = request is not null ? ChatLine.RequestTime(request, newest) : ChatLine.LastTime(agent.Last);
            // While it works, its line says what it does now (hub 1.148), as on the Mac and the iPhone.
            var action = status is { State: AgentState.Working, Old: false } ? ChatLine.ActionNow(agent.Name, fleet!.Tasks) : null;
            var line = action ?? preview;
            var needsYou = action is null && request is not null;
            var more = line is null || needsYou ? null : System.Text.RegularExpressions.Regex.Match(line, " \u00b7 \\+[0-9]+\\z");
            rows.Add(new AgentRow
            {
                Name = agent.Name,
                Label = s.Names.Label(agent.Name),
                Line = line,
                LineText = more is { Success: true } ? line![..more.Index] : line,
                LineCount = more is { Success: true } ? more.Value : null,
                NeedsYou = needsYou,
                Time = at is { } t ? TimeWords.RowTime(t, hubNow, context) : null,
                Mark = MarkLook.Of(s.MarkOf(agent.Name), status.MarkState, moves: !reduceMotion && !status.Old),
                Status = status,
                ShowsDot = status.HasDot(reduceMotion),
                Unread = s.HasNewReply(agent.Name),
                LineMoves = status.State == AgentState.Working && !status.Old && !reduceMotion,
                Selected = page.Kind == PageKind.Chat && page.Agent == agent.Name,
            });
        }
        return new PaneModel
        {
            ShowsNeeds = count > 0 || page.Kind == PageKind.Needs,
            NeedsCount = count,
            NeedsHover = NeedsWords.Count(count),
            NeedsSelected = page.Kind == PageKind.Needs,
            TasksSelected = page.Kind is PageKind.Tasks or PageKind.Task,
            SettingsSelected = page.Kind is PageKind.Settings or PageKind.AddThisPc,
            ShowsSearch = fleet is not null && !s.HasNoHub,
            Reading = s.ReadsTheHub,
            Agents = ValueList.Of(rows),
        };
    }

    /// <summary>The request that waits for him when its card is the newest thing in the agent's chat, over the newest
    /// <see cref="ChatLine.RowReads"/> items that the store holds of it, and the newest of them. A chat that the store has
    /// not read yet has none: the store reads a chat whose newest line changed, in the background.</summary>
    internal static (OwnerNeed? Need, MobileChatItem? Newest) WaitingRequest(StoreState s, MobileAgent agent)
    {
        if (s.Fleet is not { } fleet) return (null, null);
        var items = s.Items(agent.Name);
        var newest = items.Count > ChatLine.RowReads ? items.Skip(items.Count - ChatLine.RowReads).ToList() : items;
        var whole = newest.Count == items.Count &&
                    (s.Chats.TryGetValue(agent.Name, out var chat) ? chat.Whole : agent.Last is null && items.Count == 0);
        return (ChatLine.WaitingRequest(agent.Name, newest, whole, fleet.Needs), newest.LastOrDefault());
    }

    // ---------------------------------------------------------------- a chat

    /// <summary>One agent's chat: its pill, its rows (stamps, his messages, the agent's replies and the request cards in
    /// their places), the waiting line, the composer and the panel beside it.</summary>
    public static ChatModel Chat(StoreState s, string agent, DateTimeOffset now, ScreenContext context, bool reduceMotion = false,
                                 int shown = EarlierStep)
    {
        var fleet = s.Fleet;
        var entry = s.Agent(agent);
        var items = s.Items(agent);
        var waiting = OnItsWayTo(s, agent);
        var open = (fleet?.Needs ?? []).Where(n => n.By == agent).OrderBy(n => n.Raised).ToList();
        var ids = open.Select(n => n.Id).ToHashSet();
        // No card for a request that a new item replaced (owner API 1.274, Activity.Drawn), left out before the cards take
        // their places in time, so that no gap stands for it: the new item's card stands in the chat. One whose answer of
        // his is on its way or was refused keeps its card while the outbox holds it, so that the refusal has its place.
        var requests = open.Concat((fleet?.AnsweredNeeds ?? []).Where(n => n.By == agent && !ids.Contains(n.Id)))
            .Drawn(holding: s.Pending?.NeedId).ToList();
        var lines = items.ToList();
        if (waiting is not null && !OwnerStore.Holds(waiting, items)) lines.Add(OnItsWay(waiting));
        // His answer in his own words on its way is his message in the chat from the moment it goes (WordsOnTheirWay.
        // answerInWords); a press is not: its card shows it.
        foreach (var answer in AnswersInWordsTo(s, requests, items))
            lines.Add(OnItsWay(answer) with { AnswerTo = answer.NeedId, OnItsWay = true });
        // The Mac's "Earlier messages" (ThreadViews): the newest items first, and the press adds as many again. A PC holds
        // what it read since its first read of the chat (the newest 30, then the newer ones): no route gives older pages.
        var earlier = lines.Count > Math.Max(shown, 1);
        if (earlier) lines = lines.Skip(lines.Count - Math.Max(shown, 1)).ToList();
        // Each request where it was raised (the Mac's ChatRequestPlaces.inTime); one raised before the oldest item stands
        // only while the items are the chat's whole history.
        var whole = !earlier && s.Chats.TryGetValue(agent, out var page) && page.Whole;
        var places = ChatPlaces.InTime(requests, lines, whole);
        var byId = requests.GroupBy(n => n.Id).ToDictionary(g => g.Key, g => g.First());
        var parts = places.Rows(lines);
        var times = ChatPlaces.Times(parts, byId.ToDictionary(p => p.Key, p => p.Value.Raised));
        var rows = new List<ChatRow>();
        double? previous = null;
        for (var i = 0; i < parts.Count; i++)
        {
            if (Stamp(previous, times[i], Unix(now), context) is { } stamp)
                rows.Add(new ChatRow { Key = "stamp-" + parts[i].Id, Kind = ChatRowKind.Stamp, Text = stamp, Time = times[i] });
            previous = times[i];
            if (parts[i].Item is { } item) rows.Add(ItemRow(s, item, waiting, now, context));
            else if (byId.TryGetValue(parts[i].Need!.Value, out var need))
                rows.Add(RequestRow(s, need, items, now, context, places.Spoken.Contains(need.Id)));
        }
        var line = WaitingLine(s, agent, waiting, now, context);
        var status = s.StatusOf(agent, now);
        var moving = line is { Shows: true, Line.Moving: true };
        var canChat = fleet?.CanChat(agent) == true;
        var blank = items.Count == 0 && waiting is null && open.Count == 0;
        return new ChatModel
        {
            Agent = agent,
            Label = s.Names.Label(agent),
            PillMark = MarkLook.Of(s.MarkOf(agent), moving ? AgentState.Working : status.MarkState, !reduceMotion),
            PillWords = "Chat with " + s.Names.Label(agent),
            Rows = ValueList.Of(rows),
            Waiting = line,
            WaitingMark = MarkLook.Of(s.MarkOf(agent), AgentState.Working, moves: !reduceMotion && moving),
            Earlier = earlier ? "Earlier messages" : null,
            EmptyWords = $"No messages with {s.Names.Label(agent)} yet",
            Loading = blank && !s.HasRead(agent) && s.ReadCanCome,
            Empty = blank && s.HasRead(agent) && entry?.Last is null,
            Composer = Composer(s, agent, canChat, now),
            Panel = Panel(s, agent, now, context, reduceMotion),
        };
    }

    /// <summary>How many items a chat shows at first, and how many each "Earlier messages" adds (the Mac's 60).</summary>
    public const int EarlierStep = 60;

    /// <summary>His message to this agent on its way (WordsOnTheirWay.request): the waiting request while it is on its way
    /// or waits for its receipt, on its own hub and generation, and not a command, a correction or a refused one (the
    /// request line has those); else the one that went, until the chat holds the hub's copy.</summary>
    private static PendingRequest? OnItsWayTo(StoreState s, string agent)
    {
        bool Here(PendingRequest r) => r.Hub == s.Hub && r.Database == s.Fleet?.Db && r.Command is null &&
                                       r.ReplacesRequestId is null && r.NeedId is null && (r.Recipient ?? "manager") == agent;
        if (s.Pending is { Refusal: null } pending && Here(pending)) return pending;
        return s.Delivered is { } delivered && Here(delivered) ? delivered : null;
    }

    /// <summary>His message on its way, as the item it will be (MobileChatItem(waiting:)).</summary>
    private static MobileChatItem OnItsWay(PendingRequest request) =>
        new("message", request.CreatedAt.ToUnixTimeMilliseconds() / 1000.0, default, request.Text, request.Client,
            Replaces: request.ReplacesRequestId) { Key = request.RequestIdText };

    /// <summary>The stamp over an item (ChatStamp): over the first, and over one that came more than an hour after the
    /// item before or on another day; "Today 15:03", "Yesterday 09:10", a weekday within six days, else the date.</summary>
    private static string? Stamp(double? previous, double time, double now, ScreenContext context)
    {
        if (previous is { } before && time - before <= 3600 && context.Day(before) == context.Day(time)) return null;
        return StampWords(time, now, context);
    }

    /// <summary>His answers in his own words to this agent's requests on their way, until the chat holds the hub's copy
    /// (WordsOnTheirWay.answerInWords): the waiting request, not refused, of this hub and generation, or one that the hub
    /// took and that the chat has not read yet.</summary>
    private static IEnumerable<PendingRequest> AnswersInWordsTo(StoreState s, IReadOnlyList<OwnerNeed> requests, IReadOnlyList<MobileChatItem> items)
    {
        var asked = requests.Select(n => n.Id).ToHashSet();
        bool Here(PendingRequest r) => r.AnswersInWords && r.NeedId is { } need && asked.Contains(need) && r.Hub == s.Hub &&
                                       r.Database == s.Fleet?.Db && !OwnerStore.Holds(r, items);
        if (s.Pending is { Refusal: null } pending && Here(pending)) yield return pending;
        foreach (var taken in s.AnswersTaken.Values)
            if (taken.RequestId != s.Pending?.RequestId && Here(taken)) yield return taken;
    }

    private static double Unix(DateTimeOffset time) => time.ToUnixTimeMilliseconds() / 1000.0;

    /// <summary>ChatStamp.words: the day word, a space and the short time.</summary>
    public static string StampWords(double time, double now, ScreenContext context)
    {
        var date = context.LocalTime(time);
        var today = context.Day(now);
        var days = (today - date.Date).Days;
        var format = context.Culture.DateTimeFormat;
        var day = days == 0 ? "Today" : days == 1 ? "Yesterday"
            : days > 0 && days < 6 ? date.ToString("dddd", context.Culture)
            : date.ToString(format.LongDatePattern.Replace("dddd, ", "").Replace("dddd ", "").Replace("MMMM", "MMM"), context.Culture);
        return day + " " + date.ToString(format.ShortTimePattern, context.Culture);
    }

    /// <summary>The time beside a message (messageTime): the short time today, the weekday and time within six days,
    /// else the date and the time.</summary>
    public static string MessageTime(double time, double now, ScreenContext context)
    {
        var date = context.LocalTime(time);
        var days = (context.Day(now) - date.Date).Days;
        var format = context.Culture.DateTimeFormat;
        if (days == 0) return date.ToString(format.ShortTimePattern, context.Culture);
        if (days is >= 1 and <= 6) return date.ToString("dddd ", context.Culture) + date.ToString(format.ShortTimePattern, context.Culture);
        return TimeWords.DateAndTime(time, context);
    }

    private static ChatRow ItemRow(StoreState s, MobileChatItem item, PendingRequest? waiting, DateTimeOffset now, ScreenContext context)
    {
        var mine = waiting is not null && string.Equals(item.Key, waiting.RequestIdText, StringComparison.OrdinalIgnoreCase) &&
                   item.Kind == "message";
        // His message on its way: its time once the hub took it, "Sending…" while it goes (after a second), and no words
        // while it waits for its receipt: the request line over the composer says that (the Mac's pendingBar).
        string? slot = null;
        var unconfirmed = false;
        var sending = false;
        if (mine && waiting is not null)
        {
            if (s.Delivered?.RequestId == waiting.RequestId) slot = MessageTime(item.Ts, Unix(now), context);
            else if (s.Sending) { slot = "Sending…"; sending = true; }
            else unconfirmed = true;
        }
        string? hover = null;
        if (item.Kind == "message" && !mine)
            hover = MessageWords.TimeHover(TimeWords.DateAndTime(item.Ts, context), item.ReadAt is not null,
                                           item.Edited is { } edited ? MessageTime(edited, Unix(now), context) : null);
        return new ChatRow
        {
            Key = item.Id,
            Kind = item.Kind == "report" ? ChatRowKind.Reply : ChatRowKind.Message,
            Text = item.Text,
            Blocks = ValueList.Of(MessageBlock.Parse(item.Text)),
            Time = item.Ts,
            TimeWords = unconfirmed ? null : slot ?? MessageTime(item.Ts, Unix(now), context),
            TimeHover = hover,
            AgeWords = unconfirmed ? null : sending ? slot : MessageAge(item.Ts, now, context),
            AgeMoves = !unconfirmed && !sending,
            AgeHover = item.Kind == "report" ? TimeWords.DateAndTime(item.Ts, context) : hover,
            SlotIsWarning = false,
            SlotAction = WriteAction.None,
            SlotHoldsBack = mine && s.Sending && s.Delivered?.RequestId != waiting!.RequestId,
            Correction = item.Replaces is not null,
            Read = item.ReadAt is not null,
            Files = ValueList.Of(item.Attachments),
            Pushed = item.IsPushed,
        };
    }

    private static ChatRow RequestRow(StoreState s, OwnerNeed need, IReadOnlyList<MobileChatItem> items, DateTimeOffset now,
                                      ScreenContext context, bool spoken) =>
        new()
        {
            Key = "request-" + need.Id,
            Kind = ChatRowKind.Request,
            Time = need.Raised,
            Request = Card(s, need, items, now, context, spoken),
        };

    /// <summary>A request card in a chat (NeedRequestCard).</summary>
    public static RequestCard Card(StoreState s, OwnerNeed need, IReadOnlyList<MobileChatItem> items, DateTimeOffset now,
                                   ScreenContext context, bool spoken = false)
    {
        var taken = s.AnswersTaken.GetValueOrDefault(need.Id);
        var onItsWay = s.Pending is { NeedId: { } id } p && id == need.Id && p.Refusal is null ? p : taken;
        var inWords = onItsWay?.AnswersInWords ?? need.AnsweredInWords;
        var ended = !need.IsOpen || onItsWay is not null;
        var todo = need.AsksForSecret ? "" : need.Todo;
        var isShort = need.Details is not null || Characters(need.Why) <= NeedTalkWhy;
        var hasMore = need.Details is not null || !isShort || todo.Length > 0;
        var answer = (onItsWay?.Text ?? need.Answer ?? "").Trim();
        var inHub = s.Agent(need.By) is not null;
        return new RequestCard
        {
            Id = need.Id,
            Title = need.Title,
            Folded = ended,
            AnswerWords = answer.Length == 0 ? "Answered" : answer,
            AnsweredInWords = inWords,
            AnswerMark = AnsweredMark(s, need, inWords, now),
            MarkMoves = s.ShowsCurrent(now),
            Spoken = spoken,
            Answered = !need.IsOpen,
            Why = need.Why,
            Short = isShort,
            MoreClosed = !hasMore ? null : need.Details is not null ? (need.DoorHost is not null ? "Script" : "Details") : "Show all",
            MoreOpen = !hasMore ? null : need.Details is not null ? (need.DoorHost is not null ? "Script" : "Details") : "Show less",
            MoreChevron = need.Details is not null,
            Details = need.Details,
            DetailsIsCode = need.DoorScript is not null,
            Todo = todo.Length > 0 ? todo : null,
            TodoLabel = "What it needs from you",
            WhyBlocks = ValueList.Of(NeedBody.Blocks(need.Why)),
            From = $"From {s.Names.Label(need.By)} · {MessageTime(need.Raised, Unix(now), context)}",
            Agent = need.By,
            Mark = inHub ? MarkLook.Of(s.MarkOf(need.By), s.StatusOf(need.By, now).MarkState, moves: false) : null,
            Options = Options(s, need, now, ended),
            Answer = AnswerBox(s, need),
            AsksForSecret = need.AsksForSecret,
            AnswerFiles = ValueList.Of(items.LastOrDefault(i => i.AnswerTo == need.Id)?.Attachments ?? []),
            Body = BodyOf(need, step: false),
            // owner feature need_clarify: the talk over the answers of an open card, and the link under them; a folded
            // card in a chat shows neither (the Mac shows the talk only in an answered card that he opened)
            Talk = ended ? ValueList<TalkLine>.Empty : Talk(s, need),
            Clarify = ended ? null : Clarify(s, need, now),
        };
    }

    /// <summary>**The talk under a card** (owner feature `need_clarify`, the Mac's NeedTalkLines): his messages at the
    /// trailing side in his chat's bubble, the agent's replies at the leading side after its mark, oldest first, plain
    /// text (<see cref="StoreState.TalkOf"/>).</summary>
    private static ValueList<TalkLine> Talk(StoreState s, OwnerNeed need) =>
        ValueList.Of(s.TalkOf(need).Select(m => m.FromOwner
            ? new TalkLine(true, m.Text, "owner", "You", null)
            : new TalkLine(false, m.Text, m.Who, s.Names.Label(m.Who), MarkLook.Of(s.MarkOf(m.Who), AgentState.Online, moves: false))));

    /// <summary>**Needs clarification** under the answers, or null where the hub says that the card takes no message
    /// (<see cref="OwnerNeed.Clarifies"/>): the link, or its field in the link's place once he pressed it, with his words
    /// (<see cref="StoreState.ClarifyDrafts"/>). Send shows while the store can write and the field holds words within
    /// the hub's most.</summary>
    private static ClarifyModel? Clarify(StoreState s, OwnerNeed need, DateTimeOffset now)
    {
        if (!need.Clarifies(s.Fleet)) return null;
        var stands = s.ClarifyDrafts.TryGetValue(need.Id, out var draft);
        var words = (draft ?? "").Trim();
        return new ClarifyModel
        {
            Stands = stands,
            Draft = draft ?? "",
            Given = s.ClarifyGiven.GetValueOrDefault(need.Id),
            Placeholder = "Message to " + s.Names.Label(need.By),
            CanSend = stands && s.CanWrite(now) && words.Length > 0 && NeedClarify.Length(words) <= NeedClarify.Most &&
                      !s.AnswersTaken.ContainsKey(need.Id),
        };
    }

    /// <summary>What stands in the check's place of an answered request (NeedRequestCard's AnsweredMarkView and
    /// foldedMarkWords): its mark (<see cref="AnswerMark.Of"/>), or the plain check where none stands: an answer in his
    /// own words, a request that a saved key answered (the Mac's key card), and a card that the hub has not answered in
    /// a reading, whose answer is on its way. A press of Run is no option that he pressed, so it is in words here. The
    /// work of a task gets its agent's badge (<see cref="AnswerMark.Badge"/>), which its hover draws.</summary>
    public static AnswerMark AnsweredMark(StoreState s, OwnerNeed need, bool inWords, DateTimeOffset now)
    {
        if (inWords || need.IsOpen || need.AnsweredWithKeyOrWords) return AnswerMark.Plain;
        var mark = AnswerMark.Of(need, s.Fleet, need.Task is null ? [] : s.AllTasks(), s.Names);
        return mark is { Symbol: AnswerSymbol.Working, Agent: { Length: > 0 } agent }
            ? mark with { Badge = AgentBadge.Of(s, agent, now) }
            : mark;
    }

    /// <summary>NeedTalk.why: the most characters of a card's why that shows whole.</summary>
    public const int NeedTalkWhy = 240;

    private static int Characters(string text) => new StringInfo(text).LengthInTextElements;

    /// <summary>The options of a request; on a hub that names `need_pictures`, an open item with one picture for each
    /// option has them over its options (<see cref="NeedPictures.Drawn"/>), each as a file of a message is
    /// (<see cref="Tile"/>). An answered item, or one whose answer is on its way, draws as before.</summary>
    private static OptionsModel Options(StoreState s, OwnerNeed need, DateTimeOffset now, bool ended)
    {
        var choices = need.Choices;
        var kind = choices.Count == 0 ? OptionsKind.QuickReplies : need.Combines ? OptionsKind.Ticks : OptionsKind.Press;
        return new OptionsModel
        {
            Kind = kind,
            Labels = ValueList.Of(kind == OptionsKind.QuickReplies ? ["Done", "Not now", "Tell me more"] : choices),
            WaitingPress = s.WaitingPresses.TryGetValue(need.Id, out var press) ? press : null,
            Pictures = ended ? ValueList<FileTile>.Empty : ValueList.Of(NeedPictures.Drawn(s, need).Select(p => Tile(s, p, now))),
        };
    }

    private static AnswerBoxModel AnswerBox(StoreState s, OwnerNeed need)
    {
        var composer = "need:" + need.Id;
        var draft = s.AnswerDrafts.GetValueOrDefault(need.Id, "");
        var count = Characters(draft.Trim());
        // NeedsPage.note: the outbox, the file that was not taken, a file that waits, then the limit.
        (string Words, bool Warning)? note = s.StorageError is { } storage ? (storage, true)
            : s.FileError is { } file ? (file, true)
            : s.FileWaitWords(composer) is { } wait ? wait
            : count > StoreState.TextLimit ? ("Use no more than 16,000 characters.", true)
            : count > 15_500 ? ($"{count.ToString("N0", CultureInfo.CurrentCulture)} of 16,000 characters", false)
            : null;
        return new AnswerBoxModel
        {
            Placeholder = "Your answer",
            Draft = draft,
            ShowsPlus = s.Offers("attachments") && need.TakesFiles,
            Files = Unsent(s, s.Staged.GetValueOrDefault(composer)),
            Chips = ValueList.Of(Unsent(s, s.Staged.GetValueOrDefault(composer)).Select(f => Chip(s, f))),
            FilesWait = s.FilesWait(composer),
            Note = note?.Words,
            NoteIsWarning = note?.Warning ?? false,
            PlusHover = AttachWords.PlusHover(s.Staged.GetValueOrDefault(composer)?.Count ?? 0),
            SendHover = "Send this answer",
        };
    }

    /// <summary>The waiting line under his last message (ChatPage.waitingLine): what the agent does with it, and whether
    /// it shows now (an old reading keeps its room, unseen).</summary>
    private static WaitingLineModel? WaitingLine(StoreState s, string agent, PendingRequest? waiting, DateTimeOffset now,
                                                 ScreenContext context)
    {
        var current = s.ShowsCurrent(now);
        if (!(current || s.ReadsAgain) || s.Agent(agent) is not { } entry || s.Fleet is not { } fleet) return null;
        var shows = current;
        ChatPending pending;
        var items = s.Items(agent);
        var answers = ChatWaiting.WaitsOnAnswers(entry.Role, s.Offers(ChatWaiting.AnswersFeature));
        if (waiting is not null)
        {
            if (s.Delivered?.RequestId == waiting.RequestId) pending = ChatPending.Waiting;
            else if (waiting.Refusal is null && s.Sending)
            {
                pending = ChatPending.Waiting;
                shows = shows && ChatWaiting.Pending(items, entry.TurnEndedAfter, answers) == ChatPending.Waiting;
            }
            else return null;
        }
        else pending = ChatWaiting.Late(ChatWaiting.Pending(items, entry.TurnEndedAfter, answers),
                                        entry.ChatUndelivered);
        var hubNow = s.HubNow(now);
        var line = ChatWaiting.Of(agent, pending, false, entry.Limit,
                                  !entry.HelperIsRecent(fleet.Time) || entry.ChatUndelivered == true, s.Names,
                                  t => ComingTime(t, hubNow, context));
        return line is null ? null : new WaitingLineModel(line, shows);
    }

    /// <summary>A time to come (comingTime): the short time today, the short weekday and the time within six days, else
    /// the day and the month.</summary>
    public static string ComingTime(double time, double now, ScreenContext context)
    {
        var date = context.LocalTime(time);
        var days = (date.Date - context.Day(now)).Days;
        var format = context.Culture.DateTimeFormat;
        if (days == 0) return date.ToString(format.ShortTimePattern, context.Culture);
        if (days < 0) return date.ToString(format.MonthDayPattern.Replace("MMMM", "MMM"), context.Culture);
        if (days <= 6) return date.ToString("ddd ", context.Culture) + date.ToString(format.ShortTimePattern, context.Culture);
        return date.ToString(format.MonthDayPattern.Replace("MMMM", "MMM"), context.Culture);
    }

    private static ComposerModel Composer(StoreState s, string agent, bool canChat, DateTimeOffset now)
    {
        var draft = s.Drafts.GetValueOrDefault(agent, "");
        var count = Characters(draft.Trim());
        string? note = null;
        var warning = false;
        if (!canChat) { note = UnavailableWords(s, agent); warning = true; }
        else if (s.StorageError is not null) { note = s.StorageError; warning = true; }
        else if (s.FileError is not null) { note = s.FileError; warning = true; }
        else if (s.FileWaitWords("agent:" + agent) is { } wait) { note = wait.Words; warning = wait.Warning; }
        else if (count > StoreState.TextLimit) { note = "Use no more than 16,000 characters."; warning = true; }
        else if (count > 15_500) note = $"{count.ToString("N0", CultureInfo.CurrentCulture)} of 16,000 characters";
        var files = Unsent(s, s.Staged.GetValueOrDefault("agent:" + agent));
        var waits = s.FilesWait("agent:" + agent);
        return new ComposerModel
        {
            Placeholder = "Message " + s.Names.Label(agent),
            ShowsField = canChat,
            ShowsPlus = canChat && s.Offers("attachments"),
            Draft = draft,
            Files = files,
            Chips = ValueList.Of(files.Select(f => Chip(s, f))),
            PlusHover = AttachWords.PlusHover(s.Staged.GetValueOrDefault("agent:" + agent)?.Count ?? 0),
            Note = note,
            NoteIsWarning = warning,
            // A file on its way, or one that did not go, holds the message back (filesAreWaiting).
            CanSend = canChat && s.CanWrite(now) && !waits && count <= StoreState.TextLimit && (count > 0 || files.Count > 0),
            SendHover = "Send this message to " + s.Names.Label(agent),
        };
    }

    /// <summary>The files of a composer that no waiting request carries: the files of a message on its way are in the
    /// request line, not in the composer (StagedFilesStrip).</summary>
    private static ValueList<StagedFile> Unsent(StoreState s, ValueList<StagedFile>? files) =>
        files is null ? ValueList<StagedFile>.Empty
        : s.Pending is { } p && p.Attachments.Count > 0 ? ValueList.Of(files.Where(f => f.Id is not { } id || !p.Attachments.Contains(id)))
        : files;

    /// <summary>Why a chat takes no message, in the owner's words (chatUnavailableWords), or null.</summary>
    public static string? UnavailableWords(StoreState s, string agent)
    {
        if (s.Fleet?.CanChat(agent) == true) return null;
        if (s.Agent(agent)?.Active == false) return "This agent is in setup. Activate it in the Mac app before sending work.";
        if (!s.Offers("direct_chat") && agent != "manager") return "This hub needs an update before direct chat is available.";
        return "Direct chat is unavailable for this agent. Send a task to Manager.";
    }

    /// <summary>The panel beside a chat: the agent's mark, its role and the name under it, its usage while it has
    /// something to say, and where it runs.</summary>
    public static AgentPanel Panel(StoreState s, string agent, DateTimeOffset now, ScreenContext context, bool reduceMotion = false)
    {
        var entry = s.Agent(agent);
        var status = s.StatusOf(agent, now);
        var hubNow = s.HubNow(now);
        var windows = (entry?.Usage ?? []).Where(w => w.UsedPercent is not null &&
                                                     (Percent(w) > 0 || !(w.Label ?? "").Contains('(')))
            .Select(w => new UsageRow(ShortLabel(w.Label), Percent(w),
                                      !s.ShowsCurrent(now) ? UsageLevel.Old : Percent(w) >= 100 ? UsageLevel.Full
                                          : Percent(w) >= 80 ? UsageLevel.High : UsageLevel.Low,
                                      w.ResetsAt is { } r && r > hubNow ? ComingTime(Minute(r), hubNow, context) : null)
            {
                // The Mac's usageWords: the window's whole name and share, and when it resets.
                Hover = UsageWords.Hover(w.Label ?? ShortLabel(w.Label), (w.UsedPercent ?? 0).ToString("0.#", context.Culture),
                                         w.ResetsAt is { } at ? TimeWords.DateAndTime(Minute(at), context) : null,
                                         entry?.Limit is { } l ? ComingTime(l.Until, hubNow, context) : null),
            })
            .ToList();
        var warning = entry?.Role == "manager" && s.Fleet?.ManagerWarning is { } w
            ? $"The manager needs attention: {HubWords(w.Kind)} since {TimeWords.DateAndTime(w.Since, context)}." : null;
        return new AgentPanel
        {
            Listed = entry is not null,
            NotListedWords = entry is null ? $"This hub does not list {s.Names.Label(agent)}." : null,
            Mark = MarkLook.Of(s.MarkOf(agent), status.MarkState, moves: !reduceMotion),
            ShowsDot = status.HasDot(reduceMotion),
            Label = s.Names.Label(agent),
            Under = s.Names.Under(agent),
            Status = status,
            Warning = warning,
            LimitWords = entry?.Limit is { } limit ? "Usage limit until " + ComingTime(limit.Until, hubNow, context) : null,
            Usage = ValueList.Of(windows),
            ShowsUsage = entry?.Limit is not null || windows.Count > 0,
            Provider = entry is null ? null : ProviderName(entry.Runtime),
            Runtime = entry?.Runtime,
            Machine = string.IsNullOrEmpty(entry?.Machine) ? null : entry!.Machine,
        };
    }

    /// <summary>A reset time at its minute, half a minute up (ResetLine.minute).</summary>
    private static double Minute(double time) => Math.Round(time / 60, MidpointRounding.AwayFromZero) * 60;

    private static int Percent(MobileUsageWindow window) => (int)Math.Round(window.UsedPercent ?? 0, MidpointRounding.AwayFromZero);

    /// <summary>A window's length in few characters, as the Mac writes it: "5 h", "7 d", "45 min".</summary>
    public static string ShortLabel(string? label)
    {
        var words = label?.Trim();
        if (string.IsNullOrEmpty(words)) return "Window";
        var bucket = words.LastIndexOf(" / ", StringComparison.Ordinal);
        if (bucket >= 0) words = words[(bucket + 3)..];
        var scope = words.IndexOf(" (", StringComparison.Ordinal);
        if (scope >= 0) words = words[..scope];
        var parts = words.Split(' ');
        if (parts.Length != 2 || !int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var length) || length <= 0)
            return words;
        var minutes = parts[1].ToLowerInvariant() switch
        {
            "minute" or "minutes" => length,
            "hour" or "hours" => length * 60,
            "day" or "days" => length * 1440,
            _ => -1,
        };
        if (minutes < 0) return words;
        if (minutes % 1440 == 0) return $"{minutes / 1440} d";
        if (minutes % 60 == 0) return $"{minutes / 60} h";
        return $"{minutes} min";
    }

    /// <summary>The name of an AI provider: "Claude Code", "Codex", "Grok Build", else the runtime with capitals.</summary>
    public static string ProviderName(string runtime) => runtime switch
    {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "grok" => "Grok Build",
        _ => AgentBook.Capitalized(runtime),
    };

    /// <summary>A hub word as words: "not_confirmed" is "Not confirmed".</summary>
    public static string HubWords(string value)
    {
        var words = value.Replace('_', ' ');
        return words.Length == 0 ? words : char.ToUpperInvariant(words[0]) + words[1..];
    }

    // ---------------------------------------------------------------- Needs you

    /// <summary>Needs you: the lane (the open requests by the hub's number, highest first, then the tasks that only he can
    /// move), the row of the answered ones, and the request at hand. <paramref name="chosen"/>: the request he chose;
    /// <paramref name="order"/>: the lane as it stood before (for the request that comes to hand when one leaves).</summary>
    public static NeedsModel Needs(StoreState s, long? chosen, IReadOnlyList<long>? order, DateTimeOffset now, ScreenContext context)
    {
        var fleet = s.Fleet;
        var hubNow = fleet?.Time ?? s.HubNow(now);
        var sent = new HashSet<long>();
        if (s.Pending is { NeedId: { } p, Refusal: null }) sent.Add(p);
        foreach (var id in s.AnswersTaken.Keys) sent.Add(id);
        var all = (fleet?.Needs ?? []).Concat((fleet?.AnsweredNeeds ?? []).Where(a => fleet!.Needs.All(n => n.Id != a.Id))).ToList();
        var lane = new NeedsLane(all, hubNow, context, sent);
        var openIds = lane.Open.Select(n => n.Id).ToList();
        var hand = NeedsLane.AtHand(chosen, order ?? openIds, openIds);
        var waits = fleet is null ? new Dictionary<long, IReadOnlyList<string>>() : Activity.NeedWaits(fleet);
        var ownerWaits = fleet is null ? new Dictionary<long, OwnerWait>() : Activity.OwnerWaits(fleet, s.EndedTasks);
        var owner = fleet is null ? new HashSet<long>() : Activity.OwnerOnly(fleet, s.EndedTasks);
        var ownerTasks = s.AllTasks().Where(t => owner.Contains(t.Id)).OrderByDescending(t => t.Id).ToList();
        var cards = new List<NeedCardRow>();
        foreach (var need in lane.Open)
        {
            var agents = waits.GetValueOrDefault(need.Id) ?? [];
            var words = NeedsLane.WaitWords(agents, s.Names);
            cards.Add(new NeedCardRow
            {
                Key = "need-" + need.Id,
                Id = need.Id,
                Title = need.Title,
                Agent = need.By,
                AgentLabel = s.Names.Label(need.By),
                Mark = MarkLook.Of(s.MarkOf(need.By), s.StatusOf(need.By, now).MarkState, moves: false),
                Waits = agents.Count > 0,
                WaitWords = words,
                Hover = agents.Count == 0 ? need.Title : need.Title + "\n" + words,
                Selected = need.Id == hand,
            });
        }
        foreach (var task in ownerTasks)
        {
            var line = ownerWaits.GetValueOrDefault(task.Id)?.Words;
            cards.Add(new NeedCardRow
            {
                Key = "task-" + task.Id,
                Id = task.Id,
                IsTask = true,
                Title = task.Title,
                Agent = task.Owner,
                AgentLabel = s.Names.Label(task.Owner),
                Mark = MarkLook.Of(s.MarkOf(task.Owner), s.StatusOf(task.Owner, now).MarkState, moves: false),
                OwnerLine = line,
                Hover = task.Title + "\n" + (line ?? TaskWords.State(task, fleet!, s.Names)),
            });
        }
        var ended = lane.Ended.Select(day => new EndedDayModel(DayWords(day.Start, hubNow, context),
            ValueList.Of(day.Needs.Select(n => new EndedRowModel("need-" + n.Id, n.Id, n.Title, n.By, s.Names.Label(n.By),
                                                                  MarkLook.Of(s.MarkOf(n.By), s.StatusOf(n.By, now).MarkState, false), null)))))
            .ToList();
        // A request that he chose and that ended (he answered it, here or elsewhere, or opened it from the answered ones)
        // stays at hand with the check of its answer until he chooses another (NeedStep.answers).
        var endedChoice = chosen is { } c && !openIds.Contains(c) ? all.FirstOrDefault(n => n.Id == c) : null;
        var atHand = endedChoice ?? (hand is { } h ? lane.Open.FirstOrDefault(n => n.Id == h) : null);
        return new NeedsModel
        {
            OpenCount = lane.Open.Count + ownerTasks.Count,
            Cards = ValueList.Of(cards),
            Order = ValueList.Of(openIds),
            EndedCount = lane.EndedCount,
            EndedWords = $"{lane.EndedCount} answered",
            Ended = ValueList.Of(ended),
            AtHand = atHand is null ? null : Step(s, atHand, waits.GetValueOrDefault(atHand.Id) ?? [], now, context),
            Empty = fleet is not null && atHand is null && ownerTasks.Count == 0,
        };
    }

    /// <summary>The request at hand (NeedStep).</summary>
    public static RequestStep Step(StoreState s, OwnerNeed need, IReadOnlyList<string> waits, DateTimeOffset now, ScreenContext context)
    {
        var hubNow = s.Fleet?.Time ?? s.HubNow(now);
        var taken = s.AnswersTaken.GetValueOrDefault(need.Id);
        var onItsWay = s.Pending is { NeedId: { } id } p && id == need.Id && p.Refusal is null ? p : taken;
        var ended = !need.IsOpen || onItsWay is not null;
        var todo = need.AsksForSecret ? "" : need.Todo;
        var isShort = need.Details is not null || Characters(need.Why) <= NeedTalkWhy;
        var hasMore = need.Details is not null || !isShort || todo.Length > 0;
        var blocks = MessageBlock.Parse(need.Why);
        var inWords = onItsWay?.AnswersInWords ?? need.AnsweredInWords;
        var answer = (onItsWay?.Text ?? need.Answer ?? "").Trim();
        return new RequestStep
        {
            Id = need.Id,
            Mark = MarkLook.Of(s.MarkOf(need.By), s.StatusOf(need.By, now).MarkState, moves: false),
            From = $"{s.Names.Label(need.By)} · {TimeWords.Age(need.Raised, hubNow, context)}",
            Waits = waits.Count > 0,
            WaitWords = NeedsLane.WaitWords(waits, s.Names),
            Title = need.Title,
            Why = need.Why,
            Short = isShort,
            Centred = Characters(need.Why) <= NeedTalkWhy && blocks.Count == 1 && blocks[0].Kind == MessageBlock.Kinds.Paragraph,
            ShortWhy = string.Join(' ', need.Why.ReplaceLineEndings("\n").Split('\n')),
            MoreClosed = !hasMore ? null : isShort ? (need.DoorHost is not null && need.Details is not null ? "Script" : "Details") : "Show all",
            MoreOpen = !hasMore ? null : isShort ? (need.DoorHost is not null && need.Details is not null ? "Script" : "Details") : "Show less",
            MoreChevron = hasMore && isShort,
            Details = need.Details,
            DetailsIsCode = need.DoorScript is not null,
            Todo = todo.Length > 0 ? todo : null,
            TodoLabel = "What it needs from you",
            Ended = ended,
            AnswerWords = answer.Length == 0 ? "Answered" : answer,
            AnsweredInWords = inWords,
            AnswerMark = AnsweredMark(s, need, inWords, now),
            MarkMoves = s.ShowsCurrent(now),
            Options = Options(s, need, now, ended),
            Answer = AnswerBox(s, need),
            AsksForSecret = need.AsksForSecret,
            AnswerFiles = ValueList.Of(s.Items(need.By).LastOrDefault(i => i.AnswerTo == need.Id)?.Attachments ?? []),
            Body = BodyOf(need, step: true),
            // owner feature need_clarify: the talk over the answers, and over his answer once the request ended, read
            // only (the Mac's NeedStep.answers); the link under the answers while it is open
            Talk = Talk(s, need),
            Clarify = ended ? null : Clarify(s, need, now),
        };
    }

    /// <summary>The body of a request as the Mac draws it since Founderizer 0.1.239 (app commit 95811d21b): the reason
    /// and the task as message text, the task on the front when <see cref="OwnerNeed.TaskInFront"/>, and the link and
    /// what stays behind it. <paramref name="step"/> is the request at hand (NeedStep), else the card in a chat
    /// (NeedRequestCard): their links have their own words.</summary>
    public static RequestBody BodyOf(OwnerNeed need, bool step)
    {
        var todo = need.AsksForSecret ? "" : need.Todo;
        var task = need.TaskInFront ? todo : "";
        var behind = task.Length == 0 ? todo : "";
        var isShort = need.Details is not null || Characters(need.Why) <= NeedTalkWhy;
        var hasMore = need.Details is not null || !isShort || behind.Length > 0;
        var script = need.DoorHost is not null && need.Details is not null;
        string? closed = null, open = null;
        if (hasMore && step)
            (closed, open) = isShort ? (script ? ("Script", "Script") : ("Details", "Details")) : ("Show all", "Show less");
        else if (hasMore)
            (closed, open) = need.Details is not null ? (need.DoorHost is not null ? ("Script", "Script") : ("Details", "Details"))
                : ("Show all", "Show less");
        static bool OneParagraph(string text) =>
            MessageBlock.Parse(text) is var blocks && (blocks.Count == 0 || blocks is [{ Kind: MessageBlock.Kinds.Paragraph }]);
        var taskOne = OneParagraph(task);
        var whyOne = Characters(need.Why) <= NeedTalkWhy && OneParagraph(need.Why);
        return new RequestBody
        {
            Why = need.Why,
            WhyBlocks = ValueList.Of(MessageBlock.Parse(need.Why)),
            Short = isShort,
            FoldedWhy = string.Join(' ', need.Why.ReplaceLineEndings("\n").Split('\n')),
            Task = task.Length > 0 ? task : null,
            TaskBlocks = ValueList.Of(MessageBlock.Parse(task)),
            MoreClosed = closed,
            MoreOpen = open,
            MoreChevron = hasMore && (step ? isShort : need.Details is not null),
            Details = need.Details,
            DetailsBlocks = ValueList.Of(MessageBlock.Parse(need.Details ?? "")),
            DetailsIsScript = need.DoorScript is not null,
            TodoBehind = behind.Length > 0 ? behind : null,
            TodoBehindBlocks = ValueList.Of(MessageBlock.Parse(behind)),
            CentredClosed = step && taskOne && (!isShort || whyOne),
            CentredOpen = step && taskOne && whyOne,
        };
    }

    /// <summary>How long ago a message came, in its footer under the pointer (messageAge, Founderizer 0.1.239; the owner,
    /// 15 November 2026: "apply the style of the hover time (relative too)"): the app's words of an age, by this PC's
    /// clock. Read it when the footer shows, as the Mac reads it then.</summary>
    public static string MessageAge(double time, DateTimeOffset now, ScreenContext context) =>
        TimeWords.Age(time, Unix(now), context);

    /// <summary>A day of a list that opens by day (ActivityBoard.dayWords): "Today", "Yesterday", else the short weekday,
    /// the day and the short month.</summary>
    public static string DayWords(double start, double now, ScreenContext context)
    {
        var days = (context.Day(now) - context.Day(start)).Days;
        if (days == 0) return "Today";
        if (days == 1) return "Yesterday";
        return context.LocalTime(start).ToString("ddd d MMM", context.Culture);
    }

    // ---------------------------------------------------------------- Tasks

    /// <summary>The board: the period and the agent, the three lanes with their counts and cards, and the Ended rule.</summary>
    public static TaskBoardModel Board(StoreState s, ActivityPeriod period, string? agent, DateTimeOffset now, ScreenContext context)
    {
        var fleet = s.Fleet;
        var periods = Enum.GetValues<ActivityPeriod>().Select(p => new Choice<ActivityPeriod>(p, p.Title())).ToList();
        var agents = new List<AgentChoice> { new(null, "All agents", null) };
        if (fleet is not null)
            agents.AddRange(Activity.Agents(fleet, agent, s.EndedTasks).Select(a => new AgentChoice(a, s.Names.Label(a),
                MarkLook.Of(s.MarkOf(a), s.StatusOf(a, now).MarkState, moves: false))));
        var lanes = new List<LaneModel>();
        var any = false;
        if (fleet is not null)
        {
            var columns = Activity.Lanes(fleet, agent, period, context, s.EndedTasks);
            var waits = Activity.OwnerWaits(fleet, s.EndedTasks);
            foreach (var column in Enum.GetValues<ActivityColumn>())
            {
                var tasks = columns[column];
                any |= tasks.Count > 0;
                lanes.Add(new LaneModel
                {
                    Column = column,
                    Title = column.Title(),
                    Count = tasks.Count,
                    Cards = column == ActivityColumn.Done ? ValueList<TaskCardRow>.Empty
                        : ValueList.Of(tasks.Select(t => TaskCard(s, fleet, t, column, waits, now, context))),
                    Ended = column == ActivityColumn.Done ? Ended(s, fleet, tasks, now, context) : null,
                });
            }
        }
        var hasTasks = fleet is not null && s.AllTasks().Any(t => agent is null || t.Owner == agent);
        return new TaskBoardModel
        {
            Waiting = fleet is null,
            Periods = ValueList.Of(periods),
            Period = period,
            Agents = ValueList.Of(agents),
            Agent = agent,
            Lanes = ValueList.Of(lanes),
            Empty = fleet is not null && !any,
            EmptyWords = fleet is null || any ? null : hasTasks ? "No tasks" : "No tasks yet",
        };
    }

    /// <summary>Until when its agent parked a task, at the end of its agent's line (ActivityBoard.why): "Until 16:00", while
    /// no hold of the owner's and no usage limit holds it. Else null: its state word.</summary>
    public static string? Parked(StoreState s, MobileSnapshot fleet, MobileTaskHead task, DateTimeOffset now, ScreenContext context) =>
        task.ParkedUntil is { } until && !fleet.Holds.Any(h => h.Task == task.Id) &&
        !fleet.Agents.Any(a => a.Name == task.Owner && a.Limit is not null)
            ? $"Until {ComingTime(until, s.HubNow(now), context)}" : null;

    private static TaskCardRow TaskCard(StoreState s, MobileSnapshot fleet, MobileTaskHead task, ActivityColumn column,
                                        IReadOnlyDictionary<long, OwnerWait> waits, DateTimeOffset now, ScreenContext context)
    {
        var wait = waits.GetValueOrDefault(task.Id);
        var word = TaskWords.State(task, fleet, s.Names);
        // A task that waits for its subtasks names their agents where its state word would say "Working" (the Mac's
        // ActivityBoard.why of 14 November 2026), and its hover says the same.
        var waitsFor = column == ActivityColumn.Waiting && Activity.SubtaskWaits(fleet).TryGetValue(task.Id, out var agents) ? agents : null;
        var subtasks = waitsFor is not null && word == "Working" ? Activity.SubtaskWords(waitsFor, s.Names) : null;
        string? why = column switch
        {
            ActivityColumn.InProgress => word == "Working" ? null : word,
            ActivityColumn.Waiting => wait is null ? Parked(s, fleet, task, now, context) ?? subtasks ?? word : null,
            _ => null,
        };
        return new TaskCardRow
        {
            Key = "task-" + task.Id,
            Id = task.Id,
            Title = task.Title,
            OwnerLine = wait?.Words,
            OwnerLineNeed = wait is { Kind: OwnerWait.Kinds.Request } ? wait.Need : null,
            Agent = task.Owner,
            AgentLabel = s.Names.Label(task.Owner),
            Mark = MarkLook.Of(s.MarkOf(task.Owner), s.StatusOf(task.Owner, now).MarkState, moves: false),
            Why = why,
            Hover = task.Title + "\n" + (wait?.Words ?? (waitsFor is not null ? why : null) ?? word),
        };
    }

    private static EndedModel Ended(StoreState s, MobileSnapshot fleet, IReadOnlyList<MobileTaskHead> tasks, DateTimeOffset now,
                                    ScreenContext context)
    {
        var ended = new EndedTasks(tasks, context);
        return new EndedModel
        {
            Failed = ValueList.Of(ended.Failed.Select(t => new EndedRowModel("task-" + t.Id, t.Id, t.Title, t.Owner,
                s.Names.Label(t.Owner), MarkLook.Of(s.MarkOf(t.Owner), s.StatusOf(t.Owner, now).MarkState, false), t.FailedResult()))),
            Rest = ended.Rest,
            RestWords = ended.Rest == 0 ? null : ended.Failed.Count == 0 ? "Show all" : $"{ended.Rest} more",
            Days = ValueList.Of(ended.Days.Select(day => new EndedTaskDay(DayWords(day.Start, fleet.Time, context),
                ValueList.Of(day.Groups.Select(g => new EndedGroup(
                    "group-" + g.Id, g.Title, g.Owner, s.Names.Label(g.Owner),
                    g.Tasks.Count == 1 ? (g.Tasks[0].Accepted != 1 ? TaskWords.State(g.Tasks[0], fleet, s.Names) : null)
                                       : "×" + g.Tasks.Count,
                    ValueList.Of(g.Tasks.Select(t => new EndedTask(t.Id, t.Title, MessageTime(t.ActivityTime(), fleet.Time, context)))))
                {
                    Mark = MarkLook.Of(s.MarkOf(g.Owner), s.StatusOf(g.Owner, now).MarkState, false),
                })))))
        };
    }

    /// <summary>A task's page: what it asks, its thread, who did it, its state word and controls, its guidance box, and the
    /// facts of the panel. Null before its first read; on a current reading of a hub that keeps a thread's events, also
    /// until the first read of its record has every page, so that the thread and the panel come in one frame (the Mac's
    /// TaskView.shows).</summary>
    public static TaskPageModel? Task(StoreState s, long id, DateTimeOffset now, ScreenContext context)
    {
        if (!s.TaskPages.TryGetValue(id, out var page)) return null;
        if (page.Activity is null && s.Offers("thread_events") && s.IsFresh(now)) return null;
        var task = page.Task;
        var fleet = s.Fleet;
        var hold = page.Holds.FirstOrDefault(h => h.State != "released");
        var limited = fleet?.Agents.Any(a => a.Name == task.Owner && a.Limit is not null) == true;
        var word = TaskWords.State(task.State, task.Accepted, task.Requester, s.Names, task.WaitingOn,
                                   task.StalledSince is not null || task.NudgeLevel > 0, task.MissingSince is not null,
                                   hold, limited);
        // Resume checks every unknown outcome: the hub refuses a plain resume while one is unknown (the Mac's
        // TaskHoldControls). The usage limit stands back only for a check that is the owner's (the Mac's limitHolding).
        var unknown = page.Outcomes.Any(o => o.State == "unknown");
        var ownerChecks = page.Outcomes.Any(o => o.WaitsOnOwner(page.Holds, task.IsTerminal, Activity.ShellOff(fleet, task.Owner)));
        ControlsModel? controls = null;
        if (s.Offers("task_controls") && !task.IsTerminal)
        {
            var agentStop = hold is { Kind: "stop" } && hold.By is not null and not ("owner" or "hub");
            controls = new ControlsModel
            {
                StateWord = word,
                Alert = hold?.State == "not_confirmed",
                Held = hold is not null,
                ShowsPause = hold is null,
                ShowsStop = hold is null || hold.State == "not_confirmed" || hold.Kind == "pause" || agentStop,
                ShowsResume = hold?.State == "stopped",
                ResumeAction = unknown ? TaskControl.ResumeCheck : TaskControl.Resume,
                Enabled = s.CanWrite(now),
            };
        }
        GuidanceModel? guidance = null;
        if (!task.IsTerminal && s.Offers("task_steering") &&
            task.State is "submitted" or "working" or "input-required" or "auth-required" && hold is null)
            guidance = new GuidanceModel { Placeholder = "Guide this task…", SendHover = "Send this guidance to the task" };
        var thread = page.Notes.Select(n => new NoteRow("note-" + n.Id, n.Text, ValueList.Of(MessageBlock.Parse(n.Text)),
                                                        MessageTime(n.Ts, Unix(now), context))).ToList();
        var stopped = page.Holds.FirstOrDefault(h => h.State == "stopped")?.Attempt;
        string? waitingLabel = null, waitingValue = null, waitingAgent = null;
        if (!string.IsNullOrEmpty(task.WaitingOn))
        {
            if (TaskWords.Waiter(task.WaitingOn, s.Names) is { } who) { waitingLabel = "Waiting on"; waitingValue = who; waitingAgent = task.WaitingOn; }
            else
            {
                waitingLabel = "Waiting for";
                waitingValue = task.Requester == "owner" ? "You" : s.Names.Label(task.Requester);
                waitingAgent = task.Requester == "owner" ? null : task.Requester;
            }
        }
        return new TaskPageModel
        {
            Id = task.Id,
            Title = task.Title,
            Asks = task.Details,
            StalledReason = task.StalledReason,
            LimitWords = !task.IsTerminal && !ownerChecks && hold is null && limited
                ? (fleet!.Agents.First(a => a.Name == task.Owner).Limit is { ResetKnown: true } l
                    ? $"{s.Names.Label(task.Owner)} is at its usage limit until {ComingTime(l.Until, s.HubNow(now), context)}."
                    : $"{s.Names.Label(task.Owner)} is at its usage limit.") : null,
            Notes = ValueList.Of(thread),
            Thread = ValueList.Of(Thread(page, task, stopped, now, context)),
            ThreadTopRows = page.Activity?.TopRows.Count ?? 0,
            ActivityError = s.IsFresh(now) && s.Offers("thread_events") ? page.ActivityError : null,
            OfflineWords = s.IsFresh(now) ? null : StepWords.Offline,
            LivePlan = !task.IsTerminal && page.Activity is { Plan.Count: > 0 } live ? ValueList.Of(live.Plan.Select(PlanStep.Of)) : null,
            MissingWords = !task.IsTerminal && task.MissingSince is { } m ? "Session missing since " + TimeWords.DateAndTime(m, context) : null,
            WaitingLabel = waitingLabel,
            WaitingValue = waitingValue,
            WaitingAgent = waitingAgent,
            Result = task.Delivered is null ? null : new ResultModel
            {
                What = task.What ?? "No result reported",
                Check = CheckStatus(task, s.Names),
                Output = task.Where ?? "Not reported",
                How = task.How ?? "Not reported",
                Note = task.CheckNote,
                CheckedAt = task.CheckedAt is { } c ? TimeWords.DateAndTime(c, context) : null,
                Outputs = task.Accepted == 1 ? Outputs(s, task.Id, now) : null,
            },
            Who = s.Names.Label(task.Owner),
            Controls = controls,
            Guidance = guidance,
            Facts = ValueList.Of(Facts(s, task, word, context, page.Activity)),
            ParentTask = ParentTask(s, page),
            Subtasks = Subtasks(s, page),
            ChildAgents = page.Activity is { Children.Count: > 0 } kids
                ? new ChildAgentsModel(ValueList.Of(kids.Children.Take(20).Select(c => new ChildAgentRow(
                    c.Key, c.Name, c.Status switch { "completed" => ChildState.Done, "failed" => ChildState.Failed, _ => ChildState.Working },
                    StepWords.OpenChild(c.Key.Attempt)))), kids.Children.Count > 20 ? StepWords.MoreAgents : null) : null,
            ChangedFiles = page.Activity is { ChangedFiles.Count: > 0 } a
                ? new ChangedFilesModel(ValueList.Of(a.ChangedFiles.Select(c => new ChangedFileRow(
                    c.Path, StepWords.Action(c.Action), c.Added is { } added ? StepWords.Added(added) : null,
                    c.Removed is { } removed ? StepWords.Removed(removed) : null)))) : null,
        };
    }

    /// <summary>"Parent task · &lt;title&gt;", or "Parent task" when its title is not known, as a link to it (the Mac's
    /// taskFacts).</summary>
    private static ParentTaskModel? ParentTask(StoreState s, TaskPageState page)
    {
        if (page.Task.Parent is not { } parent) return null;
        var title = page.ParentTask is { } head && head.Id == parent ? head.Title
            : s.AllTasks().FirstOrDefault(t => t.Id == parent)?.Title;
        return new ParentTaskModel(parent, title is null ? "Parent task" : $"Parent task · {title}");
    }

    /// <summary>"Subtasks": each subtask by id, its title and its state word, a press opens it (the Mac's taskFacts). From
    /// the task read (owner API 1.163), else from the reading's heads.</summary>
    private static SubtasksModel? Subtasks(StoreState s, TaskPageState page)
    {
        if (s.Fleet is not { } fleet) return null;
        var heads = page.Subtasks?.ToList() ?? s.AllTasks().Where(t => t.Parent == page.Task.Id).OrderBy(t => t.Id).ToList();
        return heads.Count == 0 ? null
            : new SubtasksModel(ValueList.Of(heads.Select(t => new SubtaskRow(t.Id, t.Title, TaskWords.State(t, fleet, s.Names)))));
    }

    /// <summary>A task's thread (RuntimeActivity.entries): runs of steps, what the agent said (a message, an error, the
    /// record's cut), its notes, the permissions that wait or were refused, and the owner's guidance, in one order.</summary>
    private static IEnumerable<ThreadRowModel> Thread(TaskPageState page, FleetTask task, long? stopped, DateTimeOffset now,
                                                      ScreenContext context)
    {
        var activity = page.Activity;
        var top = (IReadOnlyList<ShownRow>?)activity?.TopRows ?? [];
        foreach (var entry in ThreadEntry.Of(top, page.Notes, page.Permissions, page.Steers))
        {
            if (entry.Steps is { } rows) yield return new ThreadRowModel { Key = "steps-" + rows[0].Id, Kind = ThreadRowKind.Steps, Steps = Steps(rows, task, stopped, activity, now, context) };
            else if (entry.Said is { } said)
            {
                var row = Row(said, task, stopped, activity, now, context);
                yield return new ThreadRowModel
                {
                    Key = "event-" + said.Id,
                    Kind = said.Row.Event.Type switch { "agent_message" => ThreadRowKind.Message, "error" => ThreadRowKind.Error, _ => ThreadRowKind.Truncated },
                    Words = row.Words,
                    Text = said.Row.Event.Type == "agent_message" ? null : row.Text,
                };
            }
            else if (entry.Note is { } n)
                yield return new ThreadRowModel
                {
                    Key = "note-" + n.Id, Kind = ThreadRowKind.Note,
                    Words = new NoteRow("note-" + n.Id, n.Text, ValueList.Of(MessageBlock.Parse(n.Text)), MessageTime(n.Ts, Unix(now), context)),
                };
            else if (entry.Permission is { } p)
                yield return new ThreadRowModel
                {
                    Key = "permission-" + p.Id, Kind = ThreadRowKind.Permission,
                    Permission = new PermissionRowModel(p.Tool, p.Decision ?? StepWords.Waiting, p.Input, p.Reason),
                };
            else if (entry.Steer is { } g)
                yield return new ThreadRowModel
                {
                    Key = "steer-" + g.Id, Kind = ThreadRowKind.Guidance,
                    Guidance = new SteerRowModel(g.Text, StepWords.Guidance(g, task.Attempt), TimeWords.DateAndTime(g.ReadAt ?? g.Created, context)),
                };
        }
    }

    /// <summary>One run of steps as one fold row (RuntimeActivity's StepsRow): the step that runs now while one runs, else
    /// the count, with its failures in orange; each step a row as the Mac's RuntimeRow draws it.</summary>
    public static StepsModel Steps(IReadOnlyList<ShownRow> rows, FleetTask task, long? stopped, TaskActivity? activity = null,
                                   DateTimeOffset now = default, ScreenContext? context = null)
    {
        bool Ended(ActivityRow row) => row.EndedWithoutResult(task.Attempt, stopped);
        var running = rows.Select(r => r.Row).LastOrDefault(r => r.Event.Type == "tool_call" && r.Status is not ("completed" or "failed") && !Ended(r));
        var failures = rows.Count(r => r.Row.Status == "failed");
        return new StepsModel
        {
            Title = running is not null ? StepWords.ToolTitle(running.Event.Title) : StepWords.Count(rows.Count),
            Status = running is not null ? StepWords.Running(rows.Count) : failures == 0 ? "" : StepWords.Failed(failures),
            Orange = failures > 0,
            Symbol = running is not null ? StepWords.Symbol(running.Event.Kind) : StepSymbol.Steps,
            Rows = ValueList.Of(rows.Select(shown => Row(shown, task, stopped, activity, now, context ?? ScreenContext.Local))),
        };
    }

    /// <summary>One row of a thread as the Mac's RuntimeRow draws it: a message, a thought ("Thinking"), a tool call with
    /// what it opens to, a child agent's plan ("Plan"), an error, or the record's cut.</summary>
    private static StepRowModel Row(ShownRow shown, FleetTask task, long? stopped, TaskActivity? activity, DateTimeOffset now,
                                    ScreenContext context)
    {
        var row = shown.Row;
        var e = row.Event;
        var key = "event-" + shown.Id;
        switch (e.Type)
        {
            case "agent_message":
                var text = e.Text ?? "";
                return new StepRowModel(key, StepSymbol.Other, "", "", false)
                {
                    Kind = ActivityRowKind.Message,
                    Words = new NoteRow(key, text, ValueList.Of(MessageBlock.Parse(text)), e.Ts is { } ts ? MessageTime(ts, Unix(now), context) : ""),
                };
            case "agent_thought":
                return new StepRowModel(key, StepSymbol.Thought, StepWords.Thinking, "", false) { Kind = ActivityRowKind.Thought, Text = e.Text ?? "" };
            case "plan":
                return new StepRowModel(key, StepSymbol.Plan, StepWords.Plan, "", false)
                {
                    Kind = ActivityRowKind.Plan, Plan = ValueList.Of((e.Entries ?? []).Select(PlanStep.Of)),
                };
            case "error":
                return new StepRowModel(key, StepSymbol.Other, "", "", true) { Kind = ActivityRowKind.Error, Text = e.Message ?? StepWords.RuntimeError };
            case "truncated":
                return new StepRowModel(key, StepSymbol.Other, "", "", false) { Kind = ActivityRowKind.Truncated, Text = StepWords.Truncated };
        }
        var ended = row.EndedWithoutResult(task.Attempt, stopped);
        var children = row.Subagent is not null && e.ToolKey is { } call && activity is not null
            ? ActivityTimeline.Children(activity.Rows, call) : [];
        return new StepRowModel(key, row.Subagent is null ? StepWords.Symbol(e.Kind) : StepSymbol.Subagent,
                                row.Subagent?.Name ?? StepWords.ToolTitle(e.Title),
                                ended ? StepWords.ResultUnknown : StepWords.ToolStatus(row.Status), row.Status == "failed")
        {
            Kind = ActivityRowKind.Tool,
            FullTitle = e.Title is { } title && StepWords.ToolTitle(title) != title ? title : null,
            Locations = ValueList.Of(row.Locations.Select(l => l.Path)),
            Output = row.Output is not null || row.Subagent is null ? row.Output ?? StepWords.NoOutput : null,
            Script = shown.Script is { } script ? script.Event.Title ?? "exec" : null,
            ScriptResult = shown.Script is { } done ? done.Output ?? StepWords.NoOutput : null,
            ChildLines = ValueList.Of(children.TakeLast(3).Select(c => c.Event.Title ?? c.Event.Text ?? c.Event.Message ?? StepWords.Activity)),
            Child = row.Subagent is not null && e.ToolKey is { } opens ? ToolKey.Of(opens) : null,
        };
    }

    /// <summary>A child agent's thread, in place of the task's own thread (RuntimeActivity.childThread): Back, its name or
    /// "Agent thread", its attempt, and its rows as a plain list without Fleet's own calls ("Waiting for agent activity."
    /// while it has none). Null while the task's page or its record is not read, or the call has no agent.</summary>
    public static ChildThreadModel? ChildThread(StoreState s, long id, ToolKey child, DateTimeOffset now, ScreenContext context)
    {
        if (!s.TaskPages.TryGetValue(id, out var page) || page.Activity is not { } activity) return null;
        var call = activity.Rows.FirstOrDefault(r => r.Event.ToolKey == child.Tuple && r.Subagent is not null);
        if (call is null) return null;
        var stopped = page.Holds.FirstOrDefault(h => h.State == "stopped")?.Attempt;
        var rows = ActivityTimeline.Children(activity.Rows, child.Tuple);
        var shown = ShownRow.Of(rows, activity.KeptScripts).Where(r => !r.Row.IsFleetTool);
        return new ChildThreadModel
        {
            Title = call.Subagent?.Name ?? StepWords.AgentThread,
            AttemptWords = StepWords.Attempt(child.Attempt),
            Rows = ValueList.Of(shown.Select(r => Row(r, page.Task, stopped, activity, now, context))),
            WaitingWords = rows.Count == 0 ? StepWords.WaitingForAgent : null,
        };
    }

    /// <summary>The checked outputs of an accepted result (the Mac's ArtifactSection), from what the store holds for the
    /// open task. A reading that is not current holds nothing: what was read is discarded.</summary>
    public static CheckedOutputsModel Outputs(StoreState s, long task, DateTimeOffset now)
    {
        var fresh = s.IsFresh(now);
        var held = s.Outputs is { } o && o.Task == task ? o : null;
        if (!fresh && held is { } h && (h.Listed || h.Opened is not null || h.Loading is not null || h.Files.Count > 0))
            held = new OutputsState { Task = task, Error = OutputWords.Discarded };
        var loading = held?.Loading;
        var enabled = fresh && loading is null;
        OpenedOutputModel? opened = null;
        if (held?.Opened is { } content)
        {
            var file = content.File;
            var newlines = content.Text?.Count(c => c == '\n') ?? 0;
            opened = new OpenedOutputModel
            {
                Path = file.Path,
                Text = content.Text,
                EmptyText = content.Text?.Length == 0,
                TextHeight = Math.Min(320, Math.Max(80, (Math.Min(newlines, 17) + 1) * 18 + 16)),
                Picture = content.Picture,
                Width = content.Width,
                Height = content.Height,
                PictureName = content.Picture is null ? null : OutputWords.VerifiedImage(file.Path),
                Download = OutputWords.VerifiedDownload(file.Bytes),
                Facts = ValueList.Of(new[] { new Fact(OutputWords.Commit, file.Commit), new Fact(OutputWords.Sha256, file.Sha256),
                                             new Fact(OutputWords.Type, file.Mime) }),
            };
        }
        return new CheckedOutputsModel
        {
            ViewWords = held?.Listed == true ? OutputWords.Reload : OutputWords.View,
            Enabled = enabled,
            ConnectionWords = fresh ? null : OutputWords.Connection,
            Loading = loading,
            Error = held?.Error,
            NoFilesWords = held is { Listed: true, Files.Count: 0 } ? OutputWords.NoFiles : null,
            Files = ValueList.Of((held?.Files ?? ValueList<ArtifactFile>.Empty).Select(f =>
                new OutputFileRow(f, f.IsImage, OutputWords.ViewNamed(f.Path), enabled))),
            Opened = opened,
        };
    }

    /// <summary>Who checks the result (FleetTask.checkStatus).</summary>
    public static string CheckStatus(FleetTask task, AgentBook names)
    {
        // One whole sentence for each case, as FleetTask.checkStatus (swift-words.json, "checks").
        var owner = task.Requester == "owner";
        var who = names.Label(task.Requester);
        return task.Accepted switch
        {
            1 => owner ? "Accepted by you" : $"Accepted by {who}",
            0 => owner ? "Not accepted by you" : $"Not accepted by {who}",
            _ => task.Delivered is null ? "No result yet" : owner ? "Waiting for your check" : $"Waiting for {who}'s check",
        };
    }

    private static List<Fact> Facts(StoreState s, FleetTask task, string word, ScreenContext context, TaskActivity? activity)
    {
        var facts = new List<Fact>();
        if (task.Project is { } project) facts.Add(new Fact("Project", project));
        facts.Add(task.Requester == "owner" ? new Fact("Asked by", "Owner")
                  : new Fact("Asked by", s.Names.Label(task.Requester), s.Agent(task.Requester) is null ? null : task.Requester));
        if (!string.IsNullOrEmpty(task.Why)) facts.Add(new Fact("Why this agent", task.Why));
        if (task.TriggerId is { } trigger)
            facts.Add(new Fact("Schedule", trigger.ToString(CultureInfo.InvariantCulture) +
                                           (task.TriggerRun is { } run ? $" · run {run}" : "")));
        facts.Add(new Fact("Agent", s.Names.Label(task.Owner), task.Owner));
        facts.Add(new Fact("State", word));
        if (task.Attempt > 1 || task.Restarts > 0)
        {
            var parts = new List<string>();
            if (task.Attempt > 1) parts.Add($"Attempt {task.Attempt}");
            if (task.Restarts > 0) parts.Add(task.Restarts == 1 ? "Restarted 1 time" : $"Restarted {task.Restarts} times");
            facts.Add(new Fact("Attempt", string.Join(" · ", parts)));
        }
        // The AI providers of its attempt now, from the record (the Mac's taskFacts): by their own names, else as written.
        var runtimes = activity?.Runtimes.Where(r => r.Attempt == task.Attempt).Select(r => r.Runtime).Order(StringComparer.Ordinal).ToList();
        if (runtimes is { Count: > 0 })
            facts.Add(new Fact("AI provider", string.Join(", ", runtimes.Select(r => r switch
            {
                "claude" => "Claude Code",
                "codex" => "Codex",
                "grok" => "Grok Build",
                _ => r,
            }))));
        foreach (var model in activity?.Models.Where(m => m.Attempt == task.Attempt) ?? [])
        {
            facts.Add(new Fact("Model requested", model.RequestedModel ?? StepWords.Automatic));
            facts.Add(new Fact("Model used", model.Model ?? StepWords.NotReported));
            facts.Add(new Fact("Reasoning requested", model.RequestedEffort is { } asked ? StepWords.Reasoning(asked) : StepWords.Automatic));
            facts.Add(new Fact("Reasoning used", model.Effort is { } used ? StepWords.Reasoning(used) : StepWords.NotReported));
            if (model.Differs) facts.Add(new Fact("", StepWords.OtherSettings) { Warning = true });
        }
        facts.Add(new Fact("Last activity", task.LastActivity is { } at ? TimeWords.DateAndTime(at, context) : "Not reported"));
        facts.Add(new Fact("Done when", task.DoneWhen));
        if (task.Delivered is not null || task.Accepted is not null) facts.Add(new Fact("Result check", CheckStatus(task, s.Names)));
        if (task.Follows is { } follows)
        {
            var title = s.AllTasks().FirstOrDefault(t => t.Id == follows)?.Title;
            facts.Add(new Fact("Follow-up to", title ?? "An earlier task"));
        }
        return facts;
    }

    // ---------------------------------------------------------------- Settings and Add this PC

    /// <summary>Settings (the iPhone's Settings page, with "PC" for "phone"). The credit is Founderizer's unless a caller
    /// gives another.</summary>
    public static SettingsModel Settings(StoreState s, string addressText, DateTimeOffset now, ScreenContext context,
                                         Credit? credit = null)
    {
        PendingSection? pending = null;
        if (s.StorageError is not null)
            pending = new PendingSection("Sending is blocked", s.StorageError, "Blocked", true, null, WriteAction.None, null);
        else if (s.Pending is { } p)
            pending = new PendingSection(s.PendingSummary ?? "", p.Refusal ?? s.SendError ?? "It waits for its receipt.",
                                         p.Refusal is null ? "Waiting" : "Refused", p.Refusal is not null,
                                         p.Text.Length > 0 ? p.Text : null,
                                         p.Refusal is not null ? WriteAction.Discard : s.CanRetry(now) ? WriteAction.TryAgain : WriteAction.None,
                                         p.Hub != s.Hub || (s.Fleet is not null && s.Fleet.Db != p.Database)
                                             ? "It belongs to another hub, so it is not sent again." : null);
        return new SettingsModel
        {
            HubPlaceholder = "http://100.84.1.2:8765",
            HubAddress = addressText,
            AddressError = s.AddressError,
            LastReading = !s.ShowsCurrent(now) && !s.HasNoHub
                ? s.LastRead is { } read ? Age(read.ToUnixTimeMilliseconds() / 1000.0, now.ToUnixTimeMilliseconds() / 1000.0, context) : "Never"
                : null,
            KeyWords = s.Key switch { KeyState.Locked => "Locked", KeyState.InHand => "In hand", KeyState.Failed => "Not given", _ => "None" },
            KeyTone = s.Key switch { KeyState.InHand => StateTone.Online, KeyState.None => StateTone.Muted, _ => StateTone.Warning },
            KeyDetail = s.KeyDetail,
            ShowsUnlock = !s.HasNoHub && (s.Key == KeyState.Locked || s.KeyWords is not null),
            Address = s.Device is { } d ? new DeviceLine("This PC's address", $"{d.Label} · {d.Address}",
                                                         d.LastSeen is { } seen ? Age(seen, s.HubNow(now), context) : "No read yet") : null,
            ShowsForget = s.Key != KeyState.None,
            Pending = pending,
            Credit = credit ?? Credit.Founderizer,
        };
    }

    /// <summary>How long ago, in Settings' words (fleetAge): "just now", "5 min ago", "3 h ago", else the date and time.</summary>
    public static string Age(double time, double now, ScreenContext context)
    {
        var seconds = Math.Max(0, now - time);
        if (seconds < 60) return "just now";
        if (seconds < 3600) return $"{(int)(seconds / 60)} min ago";
        if (seconds < 86_400) return $"{(int)(seconds / 3600)} h ago";
        return TimeWords.DateAndTime(time, context);
    }
}

/// <summary>The line over every page while the reading is not current: its words, and whether its one action is
/// Settings (else "Try again").</summary>
public sealed record ConnectionLine(string Words, bool ActionIsSettings)
{
    public string ActionWords => ActionIsSettings ? "Settings" : "Try again";
    /// <summary>The line's button; none for Settings on the Settings page itself (HubBanner.action).</summary>
    public bool ShowsAction { get; init; } = true;
}

public sealed record PaneModel
{
    public bool ShowsNeeds { get; init; }
    public int NeedsCount { get; init; }
    public string NeedsHover { get; init; } = "";
    public bool NeedsSelected { get; init; }
    public bool TasksSelected { get; init; }
    public bool SettingsSelected { get; init; }
    public bool ShowsSearch { get; init; }
    /// <summary>The first read of the hub runs: one muted line where the agents will stand, after a second (the screen's
    /// timing), and nothing else.</summary>
    public bool Reading { get; init; }
    public string ReadingWords => "Reading the hub\u2026";
    public ValueList<AgentRow> Agents { get; init; } = ValueList<AgentRow>.Empty;
}

/// <summary>One agent's row of the pane.</summary>
public sealed record AgentRow
{
    public string Key => Name;
    public string Name { get; init; } = "";
    public string Label { get; init; } = "";
    /// <summary>The line under the name, or null: the row shows the name alone.</summary>
    public string? Line { get; init; }
    /// <summary>The line without its " · +N" count, which a narrow row cuts with "…" (the Mac's splitCount).</summary>
    public string? LineText { get; init; }
    /// <summary>The line's " · +N" count, or null: a narrow row keeps it whole after the cut text.</summary>
    public string? LineCount { get; init; }
    /// <summary>The line is a request that waits for him, its title in orange and whole, with no count (ChatRow needsYou,
    /// the Mac's rule of 14 November 2026); the row's time is the card's. The status dot does not change.</summary>
    public bool NeedsYou { get; init; }
    /// <summary>The time of the chat's last message, at the end of the name's line (ChatList.lastTime), also while the
    /// line names a task; null before the first message.</summary>
    public string? Time { get; init; }
    public MarkLook Mark { get; init; } = null!;
    public AgentStatus Status { get; init; } = new(AgentState.Unknown);
    public bool ShowsDot { get; init; }
    /// <summary>A reply that he has not seen: the violet dot and the name in semibold.</summary>
    public bool Unread { get; init; }
    /// <summary>The line moves as "Thinking" does while the agent works.</summary>
    public bool LineMoves { get; init; }
    public bool Selected { get; init; }
}

public enum ChatRowKind { Stamp, Message, Reply, Request }

/// <summary>What the one action under a write says: none, Try again, or Discard.</summary>
public enum WriteAction { None, TryAgain, Discard, RefreshReceipt }

/// <summary>One row of a chat: a stamp, his message, the agent's reply, or a request card.</summary>
public sealed record ChatRow
{
    public string Key { get; init; } = "";
    public ChatRowKind Kind { get; init; }
    public string Text { get; init; } = "";
    public ValueList<MessageBlock> Blocks { get; init; } = ValueList<MessageBlock>.Empty;
    public double Time { get; init; }
    /// <summary>The time beside a message, or the state of his message on its way ("Sending…", "Not sent", a refusal).</summary>
    public string? TimeWords { get; init; }
    public bool SlotIsWarning { get; init; }
    public WriteAction SlotAction { get; init; }
    /// <summary>"Sending…" shows only after a second.</summary>
    public bool SlotHoldsBack { get; init; }
    /// <summary>The hover of a message's time in its footer: the date and time, whether the agent read it, and when it
    /// was edited; null for a reply and for his message on its way.</summary>
    public string? TimeHover { get; init; }
    /// <summary>The footer's time as the Mac's of Founderizer 0.1.239 says it (messageAge; the owner, 15 November 2026:
    /// "apply the style of the hover time (relative too)"): how long ago, "5 min ago", or the state of his message on
    /// its way as <see cref="TimeWords"/> says it. Beside <see cref="TimeWords"/>, which keeps the clock time of the
    /// approved pictures until the window draws this one.</summary>
    public string? AgeWords { get; init; }
    /// <summary><see cref="AgeWords"/> is an age: the window reads it again when the footer shows, with
    /// <c>Screens.MessageAge(Time, now, context)</c>, as the Mac reads it then.</summary>
    public bool AgeMoves { get; init; }
    /// <summary>The hover of <see cref="AgeWords"/>: the exact date and time of a reply (fleetDate), and of his message
    /// <see cref="TimeHover"/>, with whether the agent read it and when he edited it.</summary>
    public string? AgeHover { get; init; }
    /// <summary>The footer's action under the pointer: it copies <see cref="Text"/>, the message as he wrote it.</summary>
    public string CopyWords => "Copy message";
    public bool Correction { get; init; }
    public bool Read { get; init; }
    public bool Pushed { get; init; }
    public ValueList<MessageAttachment> Files { get; init; } = ValueList<MessageAttachment>.Empty;
    public RequestCard? Request { get; init; }
}

public sealed record WaitingLineModel(ChatWaiting Line, bool Shows);

public sealed record ChatModel
{
    public string Agent { get; init; } = "";
    public string Label { get; init; } = "";
    public MarkLook PillMark { get; init; } = null!;
    public string PillWords { get; init; } = "";
    public ValueList<ChatRow> Rows { get; init; } = ValueList<ChatRow>.Empty;
    public WaitingLineModel? Waiting { get; init; }
    /// <summary>The mark before "Thinking": it moves with the line.</summary>
    public MarkLook WaitingMark { get; init; } = null!;
    /// <summary>What an assistive app says for the empty chat's mark (the Mac's accessibility label); the mark alone shows.</summary>
    public string EmptyWords { get; init; } = "";
    /// <summary>The line of a chat that was not read yet (the iPhone's LoadingLine), after a second.</summary>
    public string LoadingWords => "Reading\u2026";
    /// <summary>"Earlier messages" over the first row while the chat holds more than it shows, else null.</summary>
    public string? Earlier { get; init; }
    /// <summary>The words of the button that brings the end back while he reads higher up (the screen decides when).</summary>
    public string LatestWords => "Latest";
    /// <summary>"Reading…": the chat was not read yet.</summary>
    public bool Loading { get; init; }
    /// <summary>The empty chat's logo.</summary>
    public bool Empty { get; init; }
    public ComposerModel Composer { get; init; } = new();
    public AgentPanel Panel { get; init; } = new();
}

public sealed record ComposerModel
{
    public string Placeholder { get; init; } = "";
    public bool ShowsField { get; init; }
    public bool ShowsPlus { get; init; }
    public string Draft { get; init; } = "";
    public ValueList<StagedFile> Files { get; init; } = ValueList<StagedFile>.Empty;
    /// <summary>Each file of <see cref="Files"/> as its chip draws it.</summary>
    public ValueList<FileChip> Chips { get; init; } = ValueList<FileChip>.Empty;
    /// <summary>The hover of the plus, the answer box's own sentence.</summary>
    public string PlusHover { get; init; } = "";
    public string? Note { get; init; }
    public bool NoteIsWarning { get; init; }
    /// <summary>Send shows only while this is true.</summary>
    public bool CanSend { get; init; }
    public string SendHover { get; init; } = "";
}

public enum UsageLevel { Low, High, Full, Old }

public sealed record UsageRow(string Label, int Percent, UsageLevel Level, string? Resets)
{
    /// <summary>The share under the bar, as both apps write it.</summary>
    public string ShareWords => Founderizer.Core.ShareWords.Of(Percent);
    public string Hover { get; init; } = "";
}

public sealed record AgentPanel
{
    public bool Listed { get; init; }
    public string? NotListedWords { get; init; }
    public MarkLook Mark { get; init; } = null!;
    public bool ShowsDot { get; init; }
    public string Label { get; init; } = "";
    public string? Under { get; init; }
    public AgentStatus Status { get; init; } = new(AgentState.Unknown);
    public string? Warning { get; init; }
    public string? LimitWords { get; init; }
    public bool ShowsUsage { get; init; }
    public string UsageHeading => "Usage";
    public ValueList<UsageRow> Usage { get; init; } = ValueList<UsageRow>.Empty;
    public string? Provider { get; init; }
    public string? Runtime { get; init; }
    public string? Machine { get; init; }
}

public enum OptionsKind { QuickReplies, Ticks, Press }

/// <summary>The options of a request: the app's quick replies (a press sends its words as his answer at once, or when the
/// store can write: OwnerStore.Reply), ticks with a "Send N" button, or one press each.</summary>
public sealed record OptionsModel
{
    public OptionsKind Kind { get; init; }
    public ValueList<string> Labels { get; init; } = ValueList<string>.Empty;
    /// <summary>The option whose press waits for the store: <see cref="SendingWords"/> at its end, after a second.</summary>
    public int? WaitingPress { get; init; }
    public string SendingWords => "Sending\u2026";
    public static string SendWords(int ticked) => $"Send {ticked}";
    /// <summary>Send of ticked options is on with one tick at least while the store can write.</summary>
    public static bool CanSendTicks(StoreState s, DateTimeOffset now, int ticked) => ticked > 0 && s.CanWrite(now);

    /// <summary>One picture over each option, in their order (owner feature `need_pictures`), each as a file of a message
    /// is: <see cref="NeedPictures.Columns"/> in a row, the option's words under each. Empty: the options of before.</summary>
    public ValueList<FileTile> Pictures { get; init; } = ValueList<FileTile>.Empty;

    /// <summary>What a click on option <paramref name="index"/> does, on its picture or on its words: the one command of
    /// the window's options. A click on a picture opens it (<see cref="OptionClickKind.Open"/>) and answers nothing; a
    /// click on the words answers with that option's index, ticks it, or sends a quick reply's words, as before.</summary>
    public OptionClick Click(int index, bool onPicture)
    {
        if (index < 0 || index >= Labels.Count) return OptionClick.Nothing;
        if (onPicture) return index < Pictures.Count ? new(OptionClickKind.Open, index, Picture: Pictures[index]) : OptionClick.Nothing;
        return Kind switch
        {
            OptionsKind.Press => new(OptionClickKind.Press, index),
            OptionsKind.Ticks => new(OptionClickKind.Tick, index),
            _ => new(OptionClickKind.Reply, index, Labels[index]),
        };
    }
}

public enum OptionClickKind { Nothing, Press, Tick, Reply, Open }

/// <summary>What a click on an option does (<see cref="OptionsModel.Click"/>): Press, the answer with the option's
/// <see cref="Index"/> (OwnerStore.Press); Tick, its tick; Reply, a quick reply's <see cref="Words"/>
/// (OwnerStore.Reply); Open, its <see cref="Picture"/> in the app that Windows gives its kind, as a file of a message
/// opens; Nothing.</summary>
public sealed record OptionClick(OptionClickKind Kind, int Index = -1, string? Words = null, FileTile? Picture = null)
{
    public static readonly OptionClick Nothing = new(OptionClickKind.Nothing);
}

/// <summary>Pictures as the options of a request (owner feature `need_pictures`, owner API 1.285; the owner, 20 November
/// 2026: "the idea would be that Needs You shows multiple options as images too, so I can choose between different ads
/// or designs for example without going to the chat"; his "Yes, as shown" of 21 November 2026 to the Windows drawings).
/// The hub gives an item `pictures` only while each app of the owner's says that it draws them
/// (<see cref="HubClient.DrawsHeader"/>).</summary>
public static class NeedPictures
{
    /// <summary>The hub's name: what this build draws (hub.py APP_DRAWS), and the feature of a hub that gives them.</summary>
    public const string Feature = "need_pictures";

    /// <summary>Pictures in a row; a row more for each three more.</summary>
    public const int Columns = 3;

    /// <summary>The pictures that a request's card draws over its options, or none for the card of before: only on a
    /// hub that names the feature, and only when the item has one picture for each of its options, in their order, each
    /// a picture that an app may ask for. With fewer or more pictures than options, no picture stands over an option,
    /// because none can be known to be its picture.</summary>
    public static IReadOnlyList<MessageAttachment> Drawn(StoreState s, OwnerNeed need)
    {
        if (!s.Offers(Feature) || need.AsksForSecret || need.Pictures is not { Count: > 0 } pictures) return [];
        if (pictures.Count != (need.Options ?? []).Count || pictures.Count != need.Choices.Count) return [];
        return pictures.All(p => p.IsImage && p.IsValid) ? pictures : [];
    }
}

public sealed record AnswerBoxModel
{
    public string Placeholder { get; init; } = "";
    public string Draft { get; init; } = "";
    public bool ShowsPlus { get; init; }
    public string PlusHover { get; init; } = "";
    public ValueList<StagedFile> Files { get; init; } = ValueList<StagedFile>.Empty;
    public ValueList<FileChip> Chips { get; init; } = ValueList<FileChip>.Empty;
    /// <summary>A file of this box is on its way up, or did not go: the answer waits for it.</summary>
    public bool FilesWait { get; init; }
    /// <summary>The line under the box, or null: the outbox, a file, or the count of characters.</summary>
    public string? Note { get; init; }
    public bool NoteIsWarning { get; init; }
    public string SendHover { get; init; } = "";

    /// <summary>Send shows while the store can write, no file of the box waits, and the box holds words or files, within
    /// the limit. <paramref name="files"/>: the box's files that the hub holds.</summary>
    public static bool CanSend(StoreState s, DateTimeOffset now, string text, int files, bool filesWait = false) =>
        s.CanWrite(now) && !filesWait && new StringInfo(text.Trim()).LengthInTextElements is var n && n <= StoreState.TextLimit &&
        (n > 0 || files > 0);
}

/// <summary>A request card in a chat (NeedRequestCard).</summary>
public sealed record RequestCard
{
    public long Id { get; init; }
    public string Title { get; init; } = "";
    /// <summary>Answered (or its answer on its way): two lines, the title and the answer, until he opens it.</summary>
    public bool Folded { get; init; }
    public string AnswerWords { get; init; } = "";
    /// <summary>He answered in his own words: words can ask something back or say no, so they have no check.</summary>
    public bool AnsweredInWords { get; init; }
    /// <summary>His answer stands in the chat as his own message: the folded card is its title alone.</summary>
    public bool Spoken { get; init; }
    /// <summary>The folded card's second line, the answer's words: not while his own message in the chat says them.</summary>
    public bool ShowsAnswerLine => !(AnsweredInWords && Spoken);
    /// <summary>The check before the answer's words: only for an option that he pressed or ticked.</summary>
    public bool ShowsCheck => !AnsweredInWords;
    /// <summary>What stands in the check's place (owner API 1.280, <see cref="Screens.AnsweredMark"/>): the check, the
    /// turning green mark of work, the red mark of work that ended with no success, or the orange mark of a task that
    /// needs him (its row's symbol); its <see cref="AnswerMark.Hover"/> under the pointer (for the work of a task, its
    /// agent's <see cref="AnswerMark.Badge"/> and the task's title), and its <see cref="AnswerMark.Words"/> for an
    /// assistive app.</summary>
    public AnswerMark AnswerMark { get; init; } = AnswerMark.Plain;
    /// <summary>The work mark turns: the reading is current (the Mac's marksMove). On a last reading it rests, green, as
    /// it does where Windows' animation effects are off.</summary>
    public bool MarkMoves { get; init; }
    /// <summary>What an assistive app says for the folded card (NeedRequestCard).</summary>
    public string FoldedWords => AnsweredInWords && Spoken ? $"{Title}, answered" : $"{Title}, answered: {AnswerWords}";
    public bool Answered { get; init; }
    public string Why { get; init; } = "";
    public bool Short { get; init; }
    public string? MoreClosed { get; init; }
    public string? MoreOpen { get; init; }
    public bool MoreChevron { get; init; }
    public string? Details { get; init; }
    public bool DetailsIsCode { get; init; }
    public string? Todo { get; init; }
    public string TodoLabel { get; init; } = "";
    /// <summary>The heading of an answered card that he opened, and the label over his answer in it.</summary>
    public string AnsweredHeading => "Answered";
    public string YourAnswerLabel => "Your answer";
    /// <summary>The reason as NeedBody draws it: items and paragraphs; a long reason, closed, shows its first block in
    /// three lines.</summary>
    public ValueList<NeedBody.Block> WhyBlocks { get; init; } = ValueList<NeedBody.Block>.Empty;
    public string From { get; init; } = "";

    public string Agent { get; init; } = "";
    /// <summary>The 16-px mark before "From", only for an agent of the hub.</summary>
    public MarkLook? Mark { get; init; }
    public OptionsModel Options { get; init; } = new();
    public AnswerBoxModel Answer { get; init; } = new();
    public bool AsksForSecret { get; init; }
    public ValueList<MessageAttachment> AnswerFiles { get; init; } = ValueList<MessageAttachment>.Empty;
    /// <summary>The body as the Mac's card of Founderizer 0.1.239 draws it (<see cref="RequestBody"/>), beside the
    /// fields above, which keep the look of the approved pictures until the window draws this one.</summary>
    public RequestBody Body { get; init; } = new();
    /// <summary>His talk with the agent under the card, over its answers (owner feature `need_clarify`); empty on a hub
    /// without it and on a folded card.</summary>
    public ValueList<TalkLine> Talk { get; init; } = ValueList<TalkLine>.Empty;
    /// <summary>Needs clarification under "Your answer": its link or its field; null where the card takes no message.</summary>
    public ClarifyModel? Clarify { get; init; }
}

/// <summary>One line of the talk under a card (the Mac's NeedTalkLines): his message (<see cref="Own"/>) in his chat's
/// bubble at the trailing side, or the agent's reply at the leading side after its <see cref="Mark"/>.</summary>
public sealed record TalkLine(bool Own, string Text, string Agent, string AgentLabel, MarkLook? Mark)
{
    /// <summary>What an assistive app reads: who wrote it, and its words.</summary>
    public string Spoken => $"{AgentLabel}: {Text}";
}

/// <summary>**Needs clarification** under the answers of a card (owner feature `need_clarify`; the owner's "Yes, as
/// shown" of 21 November 2026 to w4-windows-chat.png and w4-windows-needs.png): the quiet link, small muted words at the
/// leading side in a chat's card and in the middle on the request at hand; a press puts its field in the link's place,
/// the answer's box with no plus, "Message to" and the agent as its words, Send with Enter. His message goes to the
/// agent and the card stays open (OwnerStore.TalkAsync).</summary>
public sealed record ClarifyModel
{
    public string LinkWords => "Needs clarification";
    /// <summary>The field stands in the link's place.</summary>
    public bool Stands { get; init; }
    /// <summary>The store's words of the field. A window loads them only as <see cref="ClarifyField"/> says.</summary>
    public string Draft { get; init; } = "";
    /// <summary>The store gave the field words of its own (<see cref="StoreState.ClarifyGiven"/>): a new number loads them.</summary>
    public int Given { get; init; }
    public string Placeholder { get; init; } = "";
    /// <summary>Send shows: the store can write, and the field holds words within the hub's most.</summary>
    public bool CanSend { get; init; }
    public string SendHover => "Send this message";
}

/// <summary>**The field of Needs clarification as one view of a card keeps it** (the review of 21 November 2026): which
/// words it loads, which of its text changes are his, and when it takes the cursor. A WinUI text box reports a text that
/// code set as a change too, later and with the text that it has then, and a draw can come from a state older than his
/// last key. So: the store's words go into the field only when it comes to stand, when the view shows another card, and
/// when the store gave the field words of its own (<see cref="ClarifyModel.Given"/>); a change that the view made (a
/// load, or the empty field of a card that folded) and a change of a field that does not stand are not his words, so
/// the words that the store keeps for the card stay while it folds and opens again (the iPhone's round 1); and the field
/// takes the cursor once, after a press on the link whose field the store opened, and only for that card, so a view that
/// shows another card later takes none.</summary>
public sealed class ClarifyField
{
    private long? need;
    private bool stands;
    private int given;
    /// <summary>The text that the view put in the field: its change report is not his.</summary>
    private string? set;
    /// <summary>The card whose field the store opened at his press, until the field stands.</summary>
    private long? cursorFor;

    /// <summary>He pressed the link of card <paramref name="id"/>, and the store opened its field.</summary>
    public void Opened(long id) => cursorFor = id;

    /// <summary>A draw of card <paramref name="id"/>, whose field holds <paramref name="text"/> now: the words to put in
    /// the field (null: leave it as it is), and whether the field takes the cursor now.</summary>
    public (string? Load, bool Cursor) Show(long id, ClarifyModel? model, string text)
    {
        var now = model?.Stands == true;
        string? load = null;
        if (now && (!stands || need != id || model!.Given != given)) load = model!.Draft;
        else if (!now && stands) load = "";
        if (load == text) load = null;
        if (load is not null) set = load;
        need = id;
        stands = now;
        given = model?.Given ?? 0;
        var cursor = now && cursorFor == id;
        if (cursor || cursorFor != id) cursorFor = null;
        return (load, cursor);
    }

    /// <summary>The field's text changed: the card whose words they are, or null for a change that the view made or of a
    /// field that does not stand.</summary>
    public long? Typed(string text)
    {
        if (set is not null && text == set)
        {
            set = null;
            return null;
        }
        set = null;
        return stands ? need : null;
    }
}

/// <summary>The body of a request's card in a chat and of the request at hand as the Mac draws them since Founderizer
/// 0.1.239 (app commit 95811d21b; the owner, 15 November 2026: "the task itself need to be very clear and also formatted
/// like the chat messages (links, code format etc)"). The reason and the task are message text (the blocks of
/// <see cref="MessageBlock.Parse"/> with the runs of <see cref="InlineMarks.Runs"/>: a link, inline code, a code block
/// between two lines of three backticks, bold and a list), and the task stands under the reason when the item's
/// <see cref="OwnerNeed.TaskInFront"/>; else it stays behind the link, under "What it needs from you". A secret
/// request has no task here: the hub's sentence of its form is beside its form.</summary>
public sealed record RequestBody
{
    /// <summary>The reason, as message text, whole while <see cref="Short"/> or open.</summary>
    public string Why { get; init; } = "";
    public ValueList<MessageBlock> WhyBlocks { get; init; } = ValueList<MessageBlock>.Empty;
    /// <summary>A reason of one or two sentences, or one with details: whole. A longer one shows
    /// <see cref="FoldedWhy"/> until the link opens it.</summary>
    public bool Short { get; init; }
    /// <summary>The start of a long reason, closed: its lines joined with a space, drawn with its inline runs in at most
    /// three lines.</summary>
    public string FoldedWhy { get; init; } = "";
    /// <summary>The task on the front, under the reason, as message text: a message's room between the two. Null when
    /// the item has none, or when it stays behind the link (<see cref="TodoBehind"/>).</summary>
    public string? Task { get; init; }
    public ValueList<MessageBlock> TaskBlocks { get; init; } = ValueList<MessageBlock>.Empty;
    /// <summary>The link under them, closed and open, or null when nothing stands behind it: a card says "Details" (or
    /// "Script" for the door's card) for an item with details, else "Show all" and "Show less"; the request at hand says
    /// "Details" (or "Script") for a short reason, else "Show all" and "Show less".</summary>
    public string? MoreClosed { get; init; }
    public string? MoreOpen { get; init; }
    /// <summary>The chevron after the link's words.</summary>
    public bool MoreChevron { get; init; }
    /// <summary>The long part behind the link, as message text. The door's script (<see cref="DetailsIsScript"/>) is
    /// one code block in the hub's own details, whose long lines wrap and which has no copy icon.</summary>
    public string? Details { get; init; }
    public ValueList<MessageBlock> DetailsBlocks { get; init; } = ValueList<MessageBlock>.Empty;
    public bool DetailsIsScript { get; init; }
    /// <summary>The task that stays behind the link, under <see cref="TodoLabel"/>, as message text: an item with a door
    /// call, or with a kind (a conversation's item).</summary>
    public string? TodoBehind { get; init; }
    public ValueList<MessageBlock> TodoBehindBlocks { get; init; } = ValueList<MessageBlock>.Empty;
    public string TodoLabel => "What it needs from you";
    /// <summary>The request at hand only: the reason and the task stand in the middle, as a step's line does, while the
    /// link is closed and while it is open. Both read from the leading edge when the task is more than one paragraph (a
    /// list, a command, several paragraphs); a long reason stands in the middle while it is closed, and a short one
    /// when it is one paragraph. A card reads from its leading edge.</summary>
    public bool CentredClosed { get; init; }
    public bool CentredOpen { get; init; }
}

/// <summary>One card of the Needs you lane: a request, or a task that only he can move.</summary>
public sealed record NeedCardRow
{
    public string Key { get; init; } = "";
    public long Id { get; init; }
    public bool IsTask { get; init; }
    public string Title { get; init; } = "";
    public string Agent { get; init; } = "";
    public string AgentLabel { get; init; } = "";
    public MarkLook Mark { get; init; } = null!;
    /// <summary>The orange hourglass: an agent's work waits for this answer.</summary>
    public bool Waits { get; init; }
    public string WaitWords { get; init; } = "";
    public string Hover { get; init; } = "";
    public bool Selected { get; init; }
    public string? OwnerLine { get; init; }
}

public sealed record EndedRowModel(string Key, long Id, string Title, string Agent, string AgentLabel, MarkLook Mark, string? Badge);

public sealed record EndedDayModel(string Day, ValueList<EndedRowModel> Rows);

public sealed record NeedsModel
{
    public string Title => "Needs you";
    public string LaneHeading => "Open";
    public int OpenCount { get; init; }
    public ValueList<NeedCardRow> Cards { get; init; } = ValueList<NeedCardRow>.Empty;
    /// <summary>The lane's order of the open requests: give it back as the order when the next model is built.</summary>
    public ValueList<long> Order { get; init; } = ValueList<long>.Empty;
    public int EndedCount { get; init; }
    public string EndedWords { get; init; } = "";
    public ValueList<EndedDayModel> Ended { get; init; } = ValueList<EndedDayModel>.Empty;
    public RequestStep? AtHand { get; init; }
    /// <summary>"Nothing needs you", with its mark (drawn by itself after his last answer); never before the first reading.</summary>
    public bool Empty { get; init; }
    public string EmptyWords => "Nothing needs you";
}

/// <summary>The request at hand (NeedStep).</summary>
public sealed record RequestStep
{
    public long Id { get; init; }
    public MarkLook Mark { get; init; } = null!;
    public string From { get; init; } = "";
    public bool Waits { get; init; }
    public string WaitWords { get; init; } = "";
    public string Title { get; init; } = "";
    public string Why { get; init; } = "";
    public bool Short { get; init; }
    public bool Centred { get; init; }
    /// <summary>A long reason, closed: its lines on one line, at most three lines.</summary>
    public string ShortWhy { get; init; } = "";
    public string? MoreClosed { get; init; }
    public string? MoreOpen { get; init; }
    public bool MoreChevron { get; init; }
    public string? Details { get; init; }
    public bool DetailsIsCode { get; init; }
    public string? Todo { get; init; }
    public string TodoLabel { get; init; } = "";
    public bool Ended { get; init; }
    public string AnswerWords { get; init; } = "";
    /// <summary>He answered in his own words: the answer under it has no check (NeedAnswered), as a press has.</summary>
    public bool AnsweredInWords { get; init; }
    public bool ShowsCheck => !AnsweredInWords;
    /// <summary>What stands in the check's place, as on the card in a chat (<see cref="RequestCard.AnswerMark"/>; the
    /// owner's "Yes, same marks there", 21 November 2026).</summary>
    public AnswerMark AnswerMark { get; init; } = AnswerMark.Plain;
    /// <summary>The work mark turns: the reading is current (<see cref="RequestCard.MarkMoves"/>).</summary>
    public bool MarkMoves { get; init; }
    public OptionsModel Options { get; init; } = new();
    public AnswerBoxModel Answer { get; init; } = new();
    public bool AsksForSecret { get; init; }
    /// <summary>The files of his answer, under the check of an ended request at hand.</summary>
    public ValueList<MessageAttachment> AnswerFiles { get; init; } = ValueList<MessageAttachment>.Empty;
    /// <summary>The body as the Mac's request at hand of Founderizer 0.1.239 draws it (<see cref="RequestBody"/>),
    /// beside the fields above, which keep the look of the approved pictures until the window draws this one.</summary>
    public RequestBody Body { get; init; } = new();
    /// <summary>His talk with the agent, over the answers, and over his answer once the request ended (owner feature
    /// `need_clarify`).</summary>
    public ValueList<TalkLine> Talk { get; init; } = ValueList<TalkLine>.Empty;
    /// <summary>Needs clarification under "Your answer", in the middle; null where it takes no message or ended.</summary>
    public ClarifyModel? Clarify { get; init; }
}

public sealed record Choice<T>(T Value, string Words);

public sealed record AgentChoice(string? Agent, string Words, MarkLook? Mark);

public sealed record TaskCardRow
{
    public string Key { get; init; } = "";
    public long Id { get; init; }
    public string Title { get; init; } = "";
    /// <summary>What the task waits for from him, in orange; a request's title opens that request.</summary>
    public string? OwnerLine { get; init; }
    public long? OwnerLineNeed { get; init; }
    public string Agent { get; init; } = "";
    public string AgentLabel { get; init; } = "";
    public MarkLook Mark { get; init; } = null!;
    public string? Why { get; init; }
    public string Hover { get; init; } = "";
}

public sealed record EndedTask(long Id, string Title, string Time);

public sealed record EndedGroup(string Key, string Title, string Agent, string AgentLabel, string? Note, ValueList<EndedTask> Tasks)
{
    /// <summary>The agent's glyph, grey while it does not answer.</summary>
    public MarkLook? Mark { get; init; }
}

public sealed record EndedTaskDay(string Day, ValueList<EndedGroup> Groups);

/// <summary>The Ended lane: the results that he must see, and the row that opens the rest by day.</summary>
public sealed record EndedModel
{
    public ValueList<EndedRowModel> Failed { get; init; } = ValueList<EndedRowModel>.Empty;
    public int Rest { get; init; }
    /// <summary>"Show all" when nothing failed, else "N more"; null with no other ended task.</summary>
    public string? RestWords { get; init; }
    public ValueList<EndedTaskDay> Days { get; init; } = ValueList<EndedTaskDay>.Empty;
}

public sealed record LaneModel
{
    public ActivityColumn Column { get; init; }
    public string Title { get; init; } = "";
    public int Count { get; init; }
    public ValueList<TaskCardRow> Cards { get; init; } = ValueList<TaskCardRow>.Empty;
    public EndedModel? Ended { get; init; }
}

public sealed record TaskBoardModel
{
    public string Title => "Tasks";
    /// <summary>No reading yet: the page shows its title alone (the Mac's waitingPage).</summary>
    public bool Waiting { get; init; }
    public string PeriodLabel => "Period";
    public string PeriodHover => "Show the tasks of one period";
    public string AgentLabel => "Agent";
    public string AgentHover => "Show the tasks of one agent";
    public ValueList<Choice<ActivityPeriod>> Periods { get; init; } = ValueList<Choice<ActivityPeriod>>.Empty;
    public ActivityPeriod Period { get; init; }
    public ValueList<AgentChoice> Agents { get; init; } = ValueList<AgentChoice>.Empty;
    public string? Agent { get; init; }
    public ValueList<LaneModel> Lanes { get; init; } = ValueList<LaneModel>.Empty;
    public bool Empty { get; init; }
    public string? EmptyWords { get; init; }
}

public sealed record NoteRow(string Key, string Text, ValueList<MessageBlock> Blocks, string Time);

public sealed record ResultModel
{
    public string OutputLabel => "Output";
    public string HowLabel => "How it was checked";
    public string What { get; init; } = "";
    public string Check { get; init; } = "";
    public string Output { get; init; } = "";
    public string How { get; init; } = "";
    public string? Note { get; init; }
    public string? CheckedAt { get; init; }
    /// <summary>The check is a row that folds (its title <see cref="Check"/>, its mark and a chevron) and stands folded as
    /// the page opens; a press opens it on <see cref="Output"/>, <see cref="How"/>, <see cref="Note"/> and
    /// <see cref="CheckedAt"/> (the Mac's FoldRow).</summary>
    public bool CheckOpensFolded => true;
    /// <summary>"Checked outputs" with its button, only for a result that was accepted (the Mac's ArtifactSection).</summary>
    public CheckedOutputsModel? Outputs { get; init; }
}

/// <summary>The checked outputs of an accepted result (the Mac's ArtifactSection; the owner's yes of 14 November 2026 to
/// the fourth set): its heading and button, then one of: the line while a read runs with Cancel, an error in orange, the
/// line for a result with no file, the files with View, and the file opened under them.</summary>
public sealed record CheckedOutputsModel
{
    public string Heading => OutputWords.Heading;
    /// <summary>"View outputs", or "Reload outputs" once the list was read. A press calls OwnerStore.ListOutputsAsync.</summary>
    public string ViewWords { get; init; } = OutputWords.View;
    /// <summary>The button and each View take presses: the reading is current and no read runs.</summary>
    public bool Enabled { get; init; }
    /// <summary>In orange while the reading is not current.</summary>
    public string? ConnectionWords { get; init; }
    /// <summary>The line while a read runs, muted, with Cancel (OwnerStore.CloseOutputs).</summary>
    public string? Loading { get; init; }
    public string CancelWords => OutputWords.Cancel;
    /// <summary>In orange, its words selectable.</summary>
    public string? Error { get; init; }
    /// <summary>Muted, in the place of the list.</summary>
    public string? NoFilesWords { get; init; }
    public ValueList<OutputFileRow> Files { get; init; } = ValueList<OutputFileRow>.Empty;
    public OpenedOutputModel? Opened { get; init; }
}

/// <summary>A checked file: a picture's mark or a text's, its path, and View (OwnerStore.ViewOutputAsync).</summary>
public sealed record OutputFileRow(ArtifactFile File, bool IsImage, string ViewName, bool Enabled)
{
    public string Path => File.Path;
    public string ViewWords => OutputWords.ViewFile;
}

/// <summary>A file opened, in a box on the surface: its path in semibold and Close (OwnerStore.CloseOutputs); the text
/// in the code font in a scroll <see cref="TextHeight"/> high, "Empty text file", or the picture at most
/// <see cref="PictureMaxHeight"/> high from a thumbnail of at most <see cref="ThumbnailMost"/> pixels; then the fold
/// "Verified download · size" with its three facts.</summary>
public sealed record OpenedOutputModel
{
    public string Path { get; init; } = "";
    public string CloseWords => OutputWords.Close;
    public string? Text { get; init; }
    public bool EmptyText { get; init; }
    public string EmptyWords => OutputWords.EmptyText;
    public double TextHeight { get; init; }
    public byte[]? Picture { get; init; }
    public int Width { get; init; }
    public int Height { get; init; }
    public double PictureMaxHeight => 340;
    public int ThumbnailMost => 2048;
    public string? PictureName { get; init; }
    public string Download { get; init; } = "";
    public ValueList<Fact> Facts { get; init; } = ValueList<Fact>.Empty;
}

/// <summary>What a row of a task's thread is: a run of steps, the agent's message, a note, a permission, the owner's
/// guidance, an error (orange, with its mark) or the record's cut (muted).</summary>
public enum ThreadRowKind { Steps, Message, Note, Permission, Guidance, Error, Truncated }

/// <summary>What a row of the record is, inside a run or in a child agent's thread (the Mac's RuntimeRow).</summary>
public enum ActivityRowKind { Tool, Thought, Message, Plan, Error, Truncated }

/// <summary>One step of a plan: its words and its mark (done, running, or to do), muted once done.</summary>
public sealed record PlanStep(string Content, PlanState State)
{
    public static PlanStep Of(PlanEntry entry) =>
        new(entry.Content, entry.Status switch { "completed" => PlanState.Done, "in_progress" => PlanState.Running, _ => PlanState.ToDo });
}

public enum PlanState { ToDo, Running, Done }

/// <summary>The owner's guidance in the thread: his words in his bubble, and under it, muted, "Guidance · Attempt 1 ·
/// Read" with the time it was read (else sent) on hover.</summary>
public sealed record SteerRowModel(string Text, string Line, string Hover);

/// <summary>A child agent's thread: Back (one level up), its name, its attempt, and its rows.</summary>
public sealed record ChildThreadModel
{
    public string BackWords => StepWords.Back;
    public string Title { get; init; } = "";
    public string AttemptWords { get; init; } = "";
    public ValueList<StepRowModel> Rows { get; init; } = ValueList<StepRowModel>.Empty;
    public string? WaitingWords { get; init; }
    public string EarlierWords => StepWords.Earlier;
}

public enum ChildState { Working, Done, Failed }

/// <summary>A child agent in the panel: its state's mark (done, failed in orange, or working), its name, and the arrow
/// that opens its thread; <see cref="Hover"/> on hover.</summary>
public sealed record ChildAgentRow(ToolKey Key, string Name, ChildState State, string Hover);

/// <summary>"Parent task · &lt;title&gt;" under the facts, in the link's colour; a press opens that task's page.</summary>
public sealed record ParentTaskModel(long Id, string Words);

/// <summary>One subtask: its title (two lines at most) and, muted under it, its state word; a press opens its page.</summary>
public sealed record SubtaskRow(long Id, string Title, string Status);

/// <summary>"Subtasks" under the parent's link, before "Child agents".</summary>
public sealed record SubtasksModel(ValueList<SubtaskRow> Rows)
{
    public string Heading => "Subtasks";
}

/// <summary>"Child agents" in the panel, at most 20, and "More agents in the task thread" past them.</summary>
public sealed record ChildAgentsModel(ValueList<ChildAgentRow> Rows, string? MoreWords)
{
    public string Heading => StepWords.ChildAgents;
}

/// <summary>One row of a task's thread: a run of steps, a message of the agent or a note (both drawn as the agent's
/// reply, <see cref="Words"/>), or a permission that waits or was refused.</summary>
public sealed record ThreadRowModel
{
    public string Key { get; init; } = "";
    public ThreadRowKind Kind { get; init; }
    public StepsModel? Steps { get; init; }
    public NoteRow? Words { get; init; }
    public PermissionRowModel? Permission { get; init; }
    public SteerRowModel? Guidance { get; init; }
    /// <summary>An error's words, or the record's cut.</summary>
    public string? Text { get; init; }
}

/// <summary>A run of steps as one fold row: its mark, its title ("8 steps", or the step that runs), its state ("1 failed"
/// in orange, "Step 8 · Running", or none), and its steps under it when it opens.</summary>
public sealed record StepsModel
{
    public string Title { get; init; } = "";
    public string Status { get; init; } = "";
    /// <summary>The state in orange (a step failed), else muted.</summary>
    public bool Orange { get; init; }
    public StepSymbol Symbol { get; init; }
    public ValueList<StepRowModel> Rows { get; init; } = ValueList<StepRowModel>.Empty;
}

/// <summary>A row of the record (the Mac's RuntimeRow). A tool call: its kind's mark, its title, its state word (orange
/// for Failed) and a chevron; opened, its full title in the code font when the title says it in words, its locations
/// (each with a file's mark), its output in the code font, the script that made it with "Script result" folded, and for a
/// child agent the last three rows it wrote and "Open agent thread". A thought: "Thinking", its text opened. A plan:
/// "Plan", its steps opened. A message: the agent's reply (<see cref="Words"/>). An error: its words in orange with the
/// error's mark. The record's cut: its words, muted.</summary>
public sealed record StepRowModel(string Key, StepSymbol Symbol, string Title, string Status, bool Orange)
{
    public ActivityRowKind Kind { get; init; } = ActivityRowKind.Tool;
    /// <summary>A thought's text, an error's words, or the record's cut.</summary>
    public string? Text { get; init; }
    public NoteRow? Words { get; init; }
    public string? FullTitle { get; init; }
    public ValueList<string> Locations { get; init; } = ValueList<string>.Empty;
    /// <summary>The output, or "No output reported."; null for a child agent's call that reported none.</summary>
    public string? Output { get; init; }
    /// <summary>The script that made this call (muted, code font), and its own result in the fold "Script result".</summary>
    public string? Script { get; init; }
    public string? ScriptResult { get; init; }
    public string ScriptResultTitle => StepWords.ScriptResult;
    public ValueList<string> ChildLines { get; init; } = ValueList<string>.Empty;
    /// <summary>The child agent's thread that "Open agent thread" opens (Screens.ChildThread).</summary>
    public ToolKey? Child { get; init; }
    public string OpenChildWords => StepWords.OpenAgentThread;
    public ValueList<PlanStep> Plan { get; init; } = ValueList<PlanStep>.Empty;
}

/// <summary>A permission of the task: the hand, the tool's name, its state in orange ("Waiting", or the decision); opened,
/// what it asks to run in the code font, then the reason once decided.</summary>
public sealed record PermissionRowModel(string Title, string Status, string Input, string? Reason);

/// <summary>"Changed files" in the panel: each path, its action, "+N" in green and "−N" in orange, and the footer.</summary>
public sealed record ChangedFilesModel(ValueList<ChangedFileRow> Rows)
{
    public string Heading => "Changed files";
    public string Footer => "Latest completed tool report per file.";
}

public sealed record ChangedFileRow(string Path, string Action, string? Added, string? Removed);

/// <summary>The controls under a task: its state word, then Pause and Stop, or Resume and Stop for a held task.</summary>
public sealed record ControlsModel
{
    public string StateWord { get; init; } = "";
    public bool Alert { get; init; }
    public bool Held { get; init; }
    public bool ShowsPause { get; init; }
    public bool ShowsStop { get; init; }
    public bool ShowsResume { get; init; }
    public TaskControl ResumeAction { get; init; }
    public bool Enabled { get; init; }
    public string PauseWords => "Pause";
    public string StopWords => "Stop";
    public string ResumeWords => "Resume";
}

public sealed record GuidanceModel
{
    public string Placeholder { get; init; } = "";
    public string SendHover { get; init; } = "";

    /// <summary>Send shows while the store can write and the box holds words, at most 4000 characters.</summary>
    public static bool CanSend(StoreState s, DateTimeOffset now, string text) =>
        s.CanWrite(now) && text.Trim().Length > 0 && text.Length <= 4000;
}

public sealed record Fact(string Label, string Value, string? Agent = null)
{
    /// <summary>A line in orange with the error's mark and no label ("The AI provider used other settings").</summary>
    public bool Warning { get; init; }
}

public sealed record TaskPageModel
{
    public long Id { get; init; }
    public string Title { get; init; } = "";
    /// <summary>What the task asks, in his bubble.</summary>
    public string Asks { get; init; } = "";
    public string? StalledReason { get; init; }
    public string? LimitWords { get; init; }
    /// <summary>The notes alone, as before the fourth set. <see cref="Thread"/> holds them in their place among the steps.</summary>
    public ValueList<NoteRow> Notes { get; init; } = ValueList<NoteRow>.Empty;
    /// <summary>The thread under what the task asks: its steps, what the agent said, its notes, the permissions and the
    /// owner's guidance. The page shows the last <see cref="StepWords.ShownAtOnce"/> rows; "Earlier activity" over them
    /// shows that many more, and rows that come while he reads further up add to what shows (<see cref="ThreadTopRows"/>
    /// grows).</summary>
    public ValueList<ThreadRowModel> Thread { get; init; } = ValueList<ThreadRowModel>.Empty;
    public int ThreadTopRows { get; init; }
    public string EarlierWords => StepWords.Earlier;
    /// <summary>In orange with the error's mark over the thread: its last read failed. The window leaves it out while its
    /// line over the page says the hub is away.</summary>
    public string? ActivityError { get; init; }
    /// <summary>In orange over the thread while the reading is not current.</summary>
    public string? OfflineWords { get; init; }
    /// <summary>The plan of the work that runs, open under the thread, in the box of an open fold; null once the task
    /// ended.</summary>
    public ValueList<PlanStep>? LivePlan { get; init; }
    public string? MissingWords { get; init; }
    public string? WaitingLabel { get; init; }
    public string? WaitingValue { get; init; }
    public string? WaitingAgent { get; init; }
    public ResultModel? Result { get; init; }
    /// <summary>Who did it, at the end of the thread.</summary>
    public string Who { get; init; } = "";
    public ControlsModel? Controls { get; init; }
    public GuidanceModel? Guidance { get; init; }
    public ValueList<Fact> Facts { get; init; } = ValueList<Fact>.Empty;
    /// <summary>"Parent task · &lt;title&gt;" under the facts (after "Follow-up to"), then "Subtasks".</summary>
    public ParentTaskModel? ParentTask { get; init; }
    public SubtasksModel? Subtasks { get; init; }
    /// <summary>"Child agents" under the facts, before the changed files; a row opens its thread in place of the task's.</summary>
    public ChildAgentsModel? ChildAgents { get; init; }
    /// <summary>"Changed files" under the facts, or null when no completed tool reported one.</summary>
    public ChangedFilesModel? ChangedFiles { get; init; }
}

public sealed record DeviceLine(string Title, string Detail, string Value);

public sealed record PendingSection(string Title, string Detail, string Value, bool Warning, string? Text, WriteAction Action,
                                    string? Footer);

public sealed record SettingsModel
{
    public string Title => "Settings";
    public string HubHeading => "Hub";
    public string HubPlaceholder { get; init; } = "";
    public string HubAddress { get; init; } = "";
    public string ConnectWords => "Connect";
    public string? AddressError { get; init; }
    /// <summary>"Last reading" with its age, only while the reading is not current.</summary>
    public string? LastReading { get; init; }
    public string LastReadingLabel => "Last reading";
    public string DeviceHeading => "This PC";
    public string KeyLabel => "Device key";
    public string KeyWords { get; init; } = "";
    public StateTone KeyTone { get; init; }
    public string? KeyDetail { get; init; }
    public bool ShowsUnlock { get; init; }
    public DeviceLine? Address { get; init; }
    public string AddWords => "Add this PC";
    public bool ShowsForget { get; init; }
    public string ForgetWords => "Forget the key";
    public PendingSection? Pending { get; init; }
    public Credit? Credit { get; init; }
}

/// <summary>The form of Add this PC (the iPhone's EnrollPage): a whole code sends itself, once; a code that the hub
/// refused may not go again; "Try again" shows for a code that went and failed for another reason.</summary>
public sealed record EnrollForm
{
    public const string Title = "Add this PC";
    public const string Heading = "The code";
    public const string Placeholder = "XXXX-XXXX";
    public const string Footer = "In the Mac app: Settings, Servers, Add device, New code. The code works for ten minutes and once.";

    public string Code { get; init; } = "";
    /// <summary>The normalized code that went last.</summary>
    public string? Sent { get; init; }
    public bool Working { get; init; }
    public string? Problem { get; init; }

    /// <summary>He typed: the form with the new code, and whether a whole new code sends itself now.</summary>
    public (EnrollForm Form, bool Send) Typed(string code)
    {
        var form = this with { Code = code };
        if (HubClient.NormalizedCode(code) is not { } whole || whole == Sent || Working) return (form, false);
        return (form with { Sent = whole, Working = true, Problem = null }, true);
    }

    /// <summary>"Try again" pressed: the same code goes again.</summary>
    public EnrollForm Again() => this with { Working = true, Problem = null };

    /// <summary>The hub answered: null took the key (the field empties), else the owner's words.</summary>
    public EnrollForm Answered(string? problem) =>
        problem is null ? this with { Code = "", Working = false, Problem = null } : this with { Working = false, Problem = problem };

    public bool ShowsTryAgain =>
        !Working && HubClient.NormalizedCode(Code) is { } code && code == Sent && !RefusedCode(Problem);

    /// <summary>The words of a code that the hub refused, which cannot go again.</summary>
    public static bool RefusedCode(string? words) =>
        words == "This code did not work. Make a new one on your Mac." || words?.StartsWith("Too many wrong codes", StringComparison.Ordinal) == true;
}
