using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace Founderizer.Core;

/// <summary>The pages of step 1 (windows-app-pictures.md).</summary>
public enum PageKind { AddThisPc, Settings, Needs, Tasks, Task, Chat }

/// <summary>Where the window is: a page, with its agent or its task.</summary>
public sealed record Page(PageKind Kind, string? Agent = null, long? Task = null)
{
    public static readonly Page Needs = new(PageKind.Needs);
    public static readonly Page Tasks = new(PageKind.Tasks);
    public static readonly Page Settings = new(PageKind.Settings);
    public static readonly Page AddThisPc = new(PageKind.AddThisPc);
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

    /// <summary>The page that the window opens on (FleetStore.home): Add this PC on a PC with no hub or no key; Needs
    /// you while a request is open; else the chat of the first agent whose role is "manager".</summary>
    public static Page FirstPage(StoreState s)
    {
        if (s.HasNoHub || (s.Key == KeyState.None && s.Fleet is null)) return Page.AddThisPc;
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
        var count = fleet is null ? 0 : Activity.NeedsYouCount(fleet);
        var hubNow = fleet?.Time ?? s.HubNow(now);
        var rows = new List<AgentRow>();
        foreach (var agent in fleet?.Agents ?? [])
        {
            var status = s.StatusOf(agent.Name, now);
            var preview = ChatLine.Preview(agent.Name, agent.Last, fleet!.Tasks);
            var at = ChatLine.PreviewTime(agent.Name, agent.Last, fleet.Tasks);
            // While it works, its line says what it does now (hub 1.148), as on the Mac and the iPhone.
            var line = status is { State: AgentState.Working, Old: false } ? ChatLine.ActionNow(agent.Name, fleet.Tasks) ?? preview : preview;
            var more = line is null ? null : System.Text.RegularExpressions.Regex.Match(line, " \u00b7 \\+[0-9]+\\z");
            rows.Add(new AgentRow
            {
                Name = agent.Name,
                Label = s.Names.Label(agent.Name),
                Line = line,
                LineText = more is { Success: true } ? line![..more.Index] : line,
                LineCount = more is { Success: true } ? more.Value : null,
                Time = line is not null && at is { } t ? TimeWords.RowTime(t, hubNow, context) : null,
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
            NeedsHover = count switch { 0 => "Nothing needs you", 1 => "1 item needs you", _ => $"{count} items need you" },
            NeedsSelected = page.Kind == PageKind.Needs,
            TasksSelected = page.Kind is PageKind.Tasks or PageKind.Task,
            SettingsSelected = page.Kind is PageKind.Settings or PageKind.AddThisPc,
            ShowsSearch = fleet is not null && !s.HasNoHub,
            Reading = s.ReadsTheHub,
            Agents = ValueList.Of(rows),
        };
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
        var requests = open.Concat((fleet?.AnsweredNeeds ?? []).Where(n => n.By == agent && !ids.Contains(n.Id))).ToList();
        var lines = items.ToList();
        if (waiting is not null && !OwnerStore.Holds(waiting, items)) lines.Add(OnItsWay(waiting));
        // The Mac's "Earlier messages" (ThreadViews): the newest items first, and the press adds as many again. A PC holds
        // what it read since its first read of the chat (the newest 30, then the newer ones): no route gives older pages.
        var earlier = lines.Count > Math.Max(shown, 1);
        if (earlier) lines = lines.Skip(lines.Count - Math.Max(shown, 1)).ToList();
        var places = ChatPlaces.Of(requests, items);
        var byId = requests.GroupBy(n => n.Id).ToDictionary(g => g.Key, g => g.First());
        var rows = new List<ChatRow>();
        MobileChatItem? previous = null;
        foreach (var item in lines)
        {
            if (places.Hidden.Contains(item.Id)) continue;
            if (Stamp(previous, item, Unix(now), context) is { } stamp)
                rows.Add(new ChatRow { Key = "stamp-" + item.Id, Kind = ChatRowKind.Stamp, Text = stamp, Time = item.Ts });
            previous = item;
            if (places.InPlaceOf.TryGetValue(item.Id, out var inPlace) && byId.TryGetValue(inPlace, out var answered))
            {
                rows.Add(RequestRow(s, answered, items, now, context));
                continue;
            }
            rows.Add(ItemRow(s, item, waiting, now, context));
            foreach (var card in places.After.GetValueOrDefault(item.Id) ?? [])
                if (byId.TryGetValue(card, out var need)) rows.Add(RequestRow(s, need, items, now, context));
        }
        foreach (var card in places.AtEnd)
            if (byId.TryGetValue(card, out var need)) rows.Add(RequestRow(s, need, items, now, context));
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
    private static string? Stamp(MobileChatItem? previous, MobileChatItem item, double now, ScreenContext context)
    {
        if (previous is not null && item.Ts - previous.Ts <= 3600 && context.Day(previous.Ts) == context.Day(item.Ts)) return null;
        return StampWords(item.Ts, now, context);
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
        if (mine && waiting is not null)
        {
            if (s.Delivered?.RequestId == waiting.RequestId) slot = MessageTime(item.Ts, Unix(now), context);
            else if (s.Sending) slot = "Sending…";
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
                                      ScreenContext context) =>
        new()
        {
            Key = "request-" + need.Id,
            Kind = ChatRowKind.Request,
            Time = need.Raised,
            Request = Card(s, need, items, now, context),
        };

    /// <summary>A request card in a chat (NeedRequestCard).</summary>
    public static RequestCard Card(StoreState s, OwnerNeed need, IReadOnlyList<MobileChatItem> items, DateTimeOffset now,
                                   ScreenContext context)
    {
        var taken = s.AnswersTaken.GetValueOrDefault(need.Id);
        var onItsWay = s.Pending is { NeedId: { } id } p && id == need.Id && p.Refusal is null ? p : taken;
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
            Options = Options(s, need),
            Answer = AnswerBox(s, need),
            AsksForSecret = need.AsksForSecret,
            AnswerFiles = ValueList.Of(items.LastOrDefault(i => i.AnswerTo == need.Id)?.Attachments ?? []),
        };
    }

    /// <summary>NeedTalk.why: the most characters of a card's why that shows whole.</summary>
    public const int NeedTalkWhy = 240;

    private static int Characters(string text) => new StringInfo(text).LengthInTextElements;

    private static OptionsModel Options(StoreState s, OwnerNeed need)
    {
        var choices = need.Choices;
        var kind = choices.Count == 0 ? OptionsKind.QuickReplies : need.Combines ? OptionsKind.Ticks : OptionsKind.Press;
        return new OptionsModel
        {
            Kind = kind,
            Labels = ValueList.Of(kind == OptionsKind.QuickReplies ? ["Done", "Not now", "Tell me more"] : choices),
            WaitingPress = s.WaitingPresses.TryGetValue(need.Id, out var press) ? press : null,
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
            PlusHover = (s.Staged.GetValueOrDefault(composer)?.Count ?? 0) >= MessageAttachment.PerMessage
                ? $"A message carries at most {MessageAttachment.PerMessage} files"
                : "Send a picture, a PDF, a ZIP or a text file with this message",
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
        if (waiting is not null)
        {
            if (s.Delivered?.RequestId == waiting.RequestId) pending = ChatPending.Waiting;
            else if (waiting.Refusal is null && s.Sending)
            {
                pending = ChatPending.Waiting;
                shows = shows && ChatWaiting.Pending(items, entry.TurnEndedAfter) == ChatPending.Waiting;
            }
            else return null;
        }
        else pending = ChatWaiting.Late(ChatWaiting.Pending(items, entry.TurnEndedAfter), entry.ChatUndelivered);
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
        var ownerWaits = fleet is null ? new Dictionary<long, OwnerWait>() : Activity.OwnerWaits(fleet);
        var ownerTasks = fleet is null ? [] : Activity.AllTasks(fleet).Where(t => Activity.OwnerOnly(fleet).Contains(t.Id))
            .OrderByDescending(t => t.Id).ToList();
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
            Options = Options(s, need),
            Answer = AnswerBox(s, need),
            AsksForSecret = need.AsksForSecret,
            AnswerFiles = ValueList.Of(s.Items(need.By).LastOrDefault(i => i.AnswerTo == need.Id)?.Attachments ?? []),
        };
    }

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
            agents.AddRange(Activity.Agents(fleet, agent).Select(a => new AgentChoice(a, s.Names.Label(a),
                MarkLook.Of(s.MarkOf(a), s.StatusOf(a, now).MarkState, moves: false))));
        var lanes = new List<LaneModel>();
        var any = false;
        if (fleet is not null)
        {
            var columns = Activity.Lanes(fleet, agent, period, context);
            var waits = Activity.OwnerWaits(fleet);
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
                        : ValueList.Of(tasks.Select(t => TaskCard(s, fleet, t, column, waits, now))),
                    Ended = column == ActivityColumn.Done ? Ended(s, fleet, tasks, now, context) : null,
                });
            }
        }
        var hasTasks = fleet is not null && Activity.AllTasks(fleet).Any(t => agent is null || t.Owner == agent);
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

    private static TaskCardRow TaskCard(StoreState s, MobileSnapshot fleet, MobileTaskHead task, ActivityColumn column,
                                        IReadOnlyDictionary<long, OwnerWait> waits, DateTimeOffset now)
    {
        var wait = waits.GetValueOrDefault(task.Id);
        var word = TaskWords.State(task, fleet, s.Names);
        string? why = column switch
        {
            ActivityColumn.InProgress => word == "Working" ? null : word,
            ActivityColumn.Waiting => wait is null ? word : null,
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
            Hover = task.Title + "\n" + (wait?.Words ?? word),
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

    /// <summary>A task's page: what it asks, its notes, who did it, its state word and controls, its guidance box, and the
    /// facts of the panel. Null before its first read.</summary>
    public static TaskPageModel? Task(StoreState s, long id, DateTimeOffset now, ScreenContext context)
    {
        if (!s.TaskPages.TryGetValue(id, out var page)) return null;
        var task = page.Task;
        var fleet = s.Fleet;
        var hold = page.Holds.FirstOrDefault(h => h.State != "released");
        var limited = fleet?.Agents.Any(a => a.Name == task.Owner && a.Limit is not null) == true;
        var word = TaskWords.State(task.State, task.Accepted, task.Requester, s.Names, task.WaitingOn,
                                   task.StalledSince is not null || task.NudgeLevel > 0, task.MissingSince is not null,
                                   hold, limited);
        var unknown = page.Outcomes.Any(o => o.State == "unknown");
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
            LimitWords = !task.IsTerminal && !unknown && hold is null && limited
                ? (fleet!.Agents.First(a => a.Name == task.Owner).Limit is { ResetKnown: true } l
                    ? $"{s.Names.Label(task.Owner)} is at its usage limit until {ComingTime(l.Until, s.HubNow(now), context)}."
                    : $"{s.Names.Label(task.Owner)} is at its usage limit.") : null,
            Notes = ValueList.Of(thread),
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
            },
            Who = s.Names.Label(task.Owner),
            Controls = controls,
            Guidance = guidance,
            Facts = ValueList.Of(Facts(s, task, word, context)),
        };
    }

    /// <summary>Who checks the result (FleetTask.checkStatus).</summary>
    public static string CheckStatus(FleetTask task, AgentBook names)
    {
        var who = task.Requester == "owner" ? "you" : names.Label(task.Requester);
        if (task.Accepted == 1) return "Accepted by " + who;
        if (task.Accepted == 0) return "Not accepted by " + who;
        return task.Delivered is null ? "No result yet" : task.Requester == "owner" ? "Waiting for your check" : $"Waiting for {who}'s check";
    }

    private static List<Fact> Facts(StoreState s, FleetTask task, string word, ScreenContext context)
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
            if (task.Restarts > 0) parts.Add($"Restarted {task.Restarts} " + (task.Restarts == 1 ? "time" : "times"));
            facts.Add(new Fact("Attempt", string.Join(" · ", parts)));
        }
        facts.Add(new Fact("Last activity", task.LastActivity is { } at ? TimeWords.DateAndTime(at, context) : "Not reported"));
        facts.Add(new Fact("Done when", task.DoneWhen));
        if (task.Delivered is not null || task.Accepted is not null) facts.Add(new Fact("Result check", CheckStatus(task, s.Names)));
        if (task.Follows is { } follows)
        {
            var title = s.Fleet is null ? null : Activity.AllTasks(s.Fleet).FirstOrDefault(t => t.Id == follows)?.Title;
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
    /// <summary>The time at the end of the name's line, only with a line.</summary>
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
    public string? Note { get; init; }
    public bool NoteIsWarning { get; init; }
    /// <summary>Send shows only while this is true.</summary>
    public bool CanSend { get; init; }
    public string SendHover { get; init; } = "";
}

public enum UsageLevel { Low, High, Full, Old }

public sealed record UsageRow(string Label, int Percent, UsageLevel Level, string? Resets)
{
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

/// <summary>The options of a request: the app's quick replies (they fill an empty box and send nothing), ticks with a
/// "Send N" button, or one press each.</summary>
public sealed record OptionsModel
{
    public OptionsKind Kind { get; init; }
    public ValueList<string> Labels { get; init; } = ValueList<string>.Empty;
    /// <summary>The option whose press waits for the store ("Sending…" at its end, after a second).</summary>
    public int? WaitingPress { get; init; }
    public static string SendWords(int ticked) => $"Send {ticked}";
    /// <summary>Send of ticked options is on with one tick at least while the store can write.</summary>
    public static bool CanSendTicks(StoreState s, DateTimeOffset now, int ticked) => ticked > 0 && s.CanWrite(now);
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
    public OptionsModel Options { get; init; } = new();
    public AnswerBoxModel Answer { get; init; } = new();
    public bool AsksForSecret { get; init; }
    /// <summary>The files of his answer, under the check of an ended request at hand.</summary>
    public ValueList<MessageAttachment> AnswerFiles { get; init; } = ValueList<MessageAttachment>.Empty;
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
    public string What { get; init; } = "";
    public string Check { get; init; } = "";
    public string Output { get; init; } = "";
    public string How { get; init; } = "";
    public string? Note { get; init; }
    public string? CheckedAt { get; init; }
}

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

public sealed record Fact(string Label, string Value, string? Agent = null);

public sealed record TaskPageModel
{
    public long Id { get; init; }
    public string Title { get; init; } = "";
    /// <summary>What the task asks, in his bubble.</summary>
    public string Asks { get; init; } = "";
    public string? StalledReason { get; init; }
    public string? LimitWords { get; init; }
    public ValueList<NoteRow> Notes { get; init; } = ValueList<NoteRow>.Empty;
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
