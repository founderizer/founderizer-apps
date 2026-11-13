using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Founderizer.Core;

/// <summary>The models of the second set of pictures (windows-app-pictures-2.md, the owner's "Yes, as shown" of 13
/// November 2026): the request line of a write that waits, Search, the files of a message and of a composer, the
/// notification and the count on the taskbar icon, and the small states, each in the Mac's or the iPhone's words.</summary>
public static partial class Screens
{
    // ---------------------------------------------------------------- the request line (picture 14)

    /// <summary>The Mac's bar over the composer for a write that the hub did not confirm or refused (FleetView.pendingBar,
    /// choice 1 of the second set): it stands while a request waits and nothing is on its way, on every page. Each
    /// action only while it can act, never grey.</summary>
    public static PendingBarModel? PendingBar(StoreState s, DateTimeOffset now)
    {
        if (s.Pending is not { } p || s.Sending) return null;
        var actions = new List<BarAction> { new(WriteAction.RefreshReceipt, "Refresh receipt") };
        if (p.Refusal is not null) actions.Add(new(WriteAction.Discard, "Discard"));
        else if (s.CanRetry(now)) actions.Add(new(WriteAction.TryAgain, "Try again"));
        var composer = p.NeedId is { } need ? "need:" + need : "agent:" + (p.Recipient ?? "manager");
        var files = (s.Staged.GetValueOrDefault(composer) ?? ValueList<StagedFile>.Empty)
            .Where(f => f.Id is { } id && p.Attachments.Contains(id));
        return new PendingBarModel
        {
            State = p.Refusal ?? "Not sent",
            Why = p.Refusal is null ? "Your hub did not confirm it. Sending it again does not send it twice." : null,
            OtherHub = p.Hub != s.Hub || s.Fleet?.Db != p.Database ? "It belongs to another hub, so it is not sent again." : null,
            Text = RequestName(s, p),
            Files = ValueList.Of(files.Select(f => Chip(s, f, sending: true))),
            Actions = ValueList.Of(actions),
        };
    }

    /// <summary>A request's name in the request line (PendingRequest.name): a message's text, or a command's label, with
    /// its item's title only from a reading of the hub and the generation it belongs to.</summary>
    public static string RequestName(StoreState s, PendingRequest p)
    {
        if (p.Command is not { } command) return p.Text;
        string? title = null;
        if (p.Hub == s.Hub && s.Fleet is { } fleet && fleet.Db == p.Database)
            title = Activity.AllTasks(fleet).FirstOrDefault(t => t.Id == command.Target)?.Title;
        return CommandWords.Name(command, title);
    }

    // ---------------------------------------------------------------- Search (picture 1)

    /// <summary>The search card (the Mac's SearchPalette, with no "In messages": a device may not read /ui/history): the
    /// agents whose role or name holds the words in the pane's order, then the tasks whose title holds them or whose number
    /// they are, the one that moved last first (with nothing typed the newest 20, else at most 50). <paramref name="highlighted"/>
    /// is the row that Enter opens; it goes back to 0 when the words change (<see cref="SearchModel.Move"/>).</summary>
    public static SearchModel Search(StoreState s, string query, int highlighted, DateTimeOffset now, CultureInfo? culture = null)
    {
        var words = query.Trim();
        var fleet = s.Fleet;
        var compare = (culture ?? CultureInfo.CurrentCulture).CompareInfo;
        const CompareOptions loose = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreWidth;
        var agents = (fleet?.Agents ?? []).Where(a => words.Length == 0 || s.Names.Matches(a.Name, words, culture))
            .Select(a => new SearchAgentRow(a.Name, s.Names.Label(a.Name), ChatLine.Preview(a.Name, a.Last, fleet!.Tasks),
                                            MarkLook.Of(s.MarkOf(a.Name), s.StatusOf(a.Name, now).MarkState, moves: false)))
            .ToList();
        var all = fleet is null ? [] : Activity.AllTasks(fleet).OrderByDescending(t => t.ActivityTime()).ThenByDescending(t => t.Id).ToList();
        IEnumerable<MobileTaskHead> found;
        if (words.Length == 0) found = all.Take(20);
        else
        {
            var number = words.StartsWith("T-", StringComparison.OrdinalIgnoreCase) ? words[2..] : words;
            found = all.Where(t => compare.IndexOf(t.Title, words, loose) >= 0 ||
                                   t.Id.ToString(CultureInfo.InvariantCulture) == number).Take(50);
        }
        var holds = s.TaskPages.Values.SelectMany(p => p.Holds).ToList();
        var tasks = found.Select(t => new SearchTaskRow(t.Id, t.Title,
                TaskMark.Of(t, holds, s.Names, fleet!.Agents.Any(a => a.Name == t.Owner && a.Limit is not null))))
            .ToList();
        var count = agents.Count + tasks.Count;
        return new SearchModel
        {
            Words = words,
            Agents = ValueList.Of(agents),
            Tasks = ValueList.Of(tasks),
            Highlighted = count == 0 ? 0 : Math.Clamp(highlighted, 0, count - 1),
        };
    }

    // ---------------------------------------------------------------- files (picture 4)

    /// <summary>A file of a message (MessageFilesView.item and PictureTile): a picture whole, else its mark, its name and
    /// its size; "Not loaded" when its last read failed (orange while the hub answers), and "Read &lt;name&gt; again" only
    /// while the hub answers and no read of it runs. "Reading…" shows over a picture after a second of its read, and stays
    /// half a second at least: the screen's timing.</summary>
    public static FileTile Tile(StoreState s, MessageAttachment file, DateTimeOffset now)
    {
        var unloaded = s.FilesUnloaded.Contains(file.Id);
        var fresh = s.IsFresh(now);
        var reading = s.FilesReading.Contains(file.Id);
        return new FileTile
        {
            File = file,
            IsPicture = file.IsImage,
            Symbol = file.Symbol,
            Name = file.Name,
            Words = unloaded ? "Not loaded" : MessageAttachment.SizeWords(file.Size),
            WordsAreWarning = unloaded && fresh,
            Reading = reading,
            ShowsReadAgain = unloaded && fresh && !reading,
            ReadAgainHover = $"Read {file.Name} again",
            Hover = $"Open {file.Name} ({MessageAttachment.SizeWords(file.Size)})",
        };
    }

    /// <summary>A file that he added to a composer (StagedFilesStrip.chip): its name, then why its upload failed ("Not
    /// sent" for a reason longer than 28 characters), "Going up…", its size once the hub holds it, else "Waiting"; Send it
    /// up again after a failure, and the cross that takes it out, both only while no message carries it.</summary>
    public static FileChip Chip(StoreState s, StagedFile file, bool sending = false) => new()
    {
        File = file,
        IsPicture = file.Mime.StartsWith("image/", StringComparison.Ordinal),
        Words = file.Failure is { } failure ? (new StringInfo(failure).LengthInTextElements > 28 ? "Not sent" : failure)
            : s.Uploading.Contains(file.RequestId) ? "Going up…"
            : file.IsOnHub ? MessageAttachment.SizeWords(file.Size) : "Waiting",
        WordsAreWarning = file.Failure is not null,
        ShowsSendAgain = !sending && file.Failure is not null,
        SendAgainHover = "Send this file up again",
        ShowsTakeOut = !sending,
        TakeOutHover = $"Take {file.Name} out",
    };

    // ---------------------------------------------------------------- the notification and the taskbar's count (picture 10)

    /// <summary>The count on the taskbar icon, as the Mac's Dock badge (FleetNotifications.update): the open requests,
    /// and one more while the manager's warning stands; null when there is none.</summary>
    public static string? TaskbarCount(StoreState s)
    {
        if (s.Fleet is not { } fleet) return null;
        var count = fleet.Needs.Count(n => n.IsOpen) + (Notifications.Episode(fleet.ManagerWarning) is null ? 0 : 1);
        return count == 0 ? null : count.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>Where a click on a notification goes (FleetStore.openNotification): Needs you at that request, while the
    /// reading is of the same hub and generation and still lists it; else nowhere (the window still comes to the front).</summary>
    public static long? NoticeTarget(StoreState s, Notice notice) =>
        notice.Need is { } need && s.Hub is { } hub && s.Fleet is { } fleet &&
        Notifications.Context(hub, fleet.Db) == notice.Context && fleet.Needs.Any(n => n.Id == need) ? need : null;

    // ---------------------------------------------------------------- the small states

    /// <summary>The line over a page (HubBanner), or null: on Settings, a line whose way on is Settings has no button.</summary>
    public static ConnectionLine? Line(StoreState s, DateTimeOffset now, Page page) =>
        Line(s, now) is { } line && line.ActionIsSettings && page.Kind is PageKind.Settings or PageKind.AddThisPc
            ? line with { ShowsAction = false } : Line(s, now);
}

/// <summary>The blocks of a request's reason (the Mac's NeedBody.blocks): each line trimmed, an empty line dropped, a
/// line that starts with "- ", "• " or "* " an item "•", one that starts with one or two digits and "." or ")" an item
/// "N.", and the other lines joined to the paragraph before them with a space.</summary>
public static class NeedBody
{
    public sealed record Block(string? Marker, string Text);

    public static IReadOnlyList<Block> Blocks(string text)
    {
        var blocks = new List<Block>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim(' ', '\t');
            if (line.Length == 0) continue;
            if (Marker(line) is { } found) blocks.Add(found);
            else if (blocks.Count > 0 && blocks[^1].Marker is null) blocks[^1] = blocks[^1] with { Text = blocks[^1].Text + " " + line };
            else blocks.Add(new Block(null, line));
        }
        return blocks;
    }

    private static Block? Marker(string line)
    {
        if (line.Length > 2 && "-•*".Contains(line[0]) && line[1] == ' ') return new Block("•", line[2..]);
        var digits = 0;
        while (digits < line.Length && char.IsDigit(line[digits])) digits++;
        if (digits is 0 or > 2 || digits >= line.Length || line[digits] is not ('.' or ')')) return null;
        return new Block(line[..digits] + ".", line[(digits + 1)..].Trim(' ', '\t'));
    }
}

/// <summary>When a notification is due (the Mac's NotificationLedger and FleetNotifications): a request of the manager
/// whose number is above the highest that this PC saw for that hub and generation, and open; the first reading of a hub
/// and generation notifies nothing; the manager's warning once for each new episode. The ledger stays between starts, so
/// a start notifies what came while the app was closed, and never twice.</summary>
public sealed class NotificationLedger
{
    public Dictionary<string, long> Seen { get; init; } = new();
    public Dictionary<string, string>? Warnings { get; set; }

    /// <summary>The requests to notify in this reading.</summary>
    public IReadOnlyList<long> Observe(string context, IEnumerable<OwnerNeed> needs)
    {
        var list = needs.ToList();
        var had = Seen.TryGetValue(context, out var previous);
        Seen[context] = Math.Max(had ? previous : 0, list.Count == 0 ? 0 : list.Max(n => n.Id));
        if (!had) return [];
        return list.Where(n => n.Id > previous && n.IsOpen && n.By == "manager").Select(n => n.Id).ToList();
    }

    /// <summary>The manager's warning episode to notify in this reading, or null.</summary>
    public string? ObserveWarning(string context, ManagerWarning? warning)
    {
        string? previous = null;
        var had = Warnings?.TryGetValue(context, out previous) == true;
        Warnings ??= new Dictionary<string, string>();
        if (Notifications.Episode(warning) is not { } episode)
        {
            if (!had) Warnings[context] = "";
            return null;
        }
        Warnings[context] = episode;
        return had && previous != episode ? episode : null;
    }
}

/// <summary>A notification that is due, with the words that the Mac writes, and the tag by which the screens take it away
/// when its request is no longer open.</summary>
public sealed record Notice(string Context, long? Need, string Title, string Body)
{
    public string Tag => Need is { } need ? $"{Context}/{need}" : $"{Context}/warning";
}

public static partial class Notifications
{
    /// <summary>The hub and the generation that a notification belongs to (FleetNotifications.context): the SHA-256 of
    /// "&lt;hub&gt;\n&lt;db&gt;" in lower-case hex.</summary>
    public static string Context(Uri hub, string database) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(hub.AbsoluteUri + "\n" + database)));

    /// <summary>The episode of the manager's warning (ManagerWarning.episode), or null.</summary>
    public static string? Episode(ManagerWarning? warning) =>
        warning is { } w && double.IsFinite(w.Since) && w.Since > 0 && WarningKind().IsMatch(w.Kind)
            ? $"{w.Kind}/{SwiftDouble(w.Since)}" : null;

    /// <summary>The notifications of one reading, as the Mac makes them: for a request, its agent as the title and its
    /// title (else its reason) as the text; for the manager's warning, its two lines.</summary>
    public static IReadOnlyList<Notice> Due(NotificationLedger ledger, Uri hub, MobileSnapshot fleet, AgentBook names)
    {
        var context = Context(hub, fleet.Db);
        var notices = new List<Notice>();
        foreach (var id in ledger.Observe(context, fleet.Needs))
        {
            var need = fleet.Needs.First(n => n.Id == id);
            notices.Add(new Notice(context, id, names.Label(need.By), need.Title.Length == 0 ? need.Why : need.Title));
        }
        if (ledger.ObserveWarning(context, fleet.ManagerWarning) is not null)
            notices.Add(new Notice(context, null, "Check the Founderizer manager", "The manager needs your attention."));
        return notices;
    }

    /// <summary>The tags of the notifications that may stay: the open requests, and the warning while it stands.</summary>
    public static IReadOnlySet<string> Open(Uri hub, MobileSnapshot fleet)
    {
        var context = Context(hub, fleet.Db);
        var open = fleet.Needs.Where(n => n.IsOpen).Select(n => $"{context}/{n.Id}").ToHashSet();
        if (Episode(fleet.ManagerWarning) is not null) open.Add($"{context}/warning");
        return open;
    }

    /// <summary>A Double as Swift writes it in a string ("1794582720.0", "1.5"): the shortest form that reads back, with
    /// ".0" for a whole number.</summary>
    internal static string SwiftDouble(double value)
    {
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        return text.Contains('.') || text.Contains('E') ? text : text + ".0";
    }

    [GeneratedRegex(@"\A[a-z][a-z0-9_-]{0,63}\z", RegexOptions.CultureInvariant)]
    private static partial Regex WarningKind();
}

public sealed record BarAction(WriteAction Action, string Words);

/// <summary>The request line: its state in orange, why, the other hub's line, what it is, its files, and its actions.</summary>
public sealed record PendingBarModel
{
    public string State { get; init; } = "";
    public string? Why { get; init; }
    public string? OtherHub { get; init; }
    /// <summary>A message's text or a command's label, at most three lines.</summary>
    public string Text { get; init; } = "";
    public ValueList<FileChip> Files { get; init; } = ValueList<FileChip>.Empty;
    public ValueList<BarAction> Actions { get; init; } = ValueList<BarAction>.Empty;
}

public sealed record SearchAgentRow(string Name, string Label, string? Line, MarkLook Mark);

public sealed record SearchTaskRow(long Id, string Title, TaskMark Mark);

public sealed record SearchModel
{
    public string Placeholder => "Search";
    public string AgentsHeading => "Agents";
    public string TasksHeading => "Tasks";
    public string Words { get; init; } = "";
    /// <summary>The agents; the group shows only when it is not empty.</summary>
    public ValueList<SearchAgentRow> Agents { get; init; } = ValueList<SearchAgentRow>.Empty;
    public ValueList<SearchTaskRow> Tasks { get; init; } = ValueList<SearchTaskRow>.Empty;
    /// <summary>The row with the selected fill, which Enter opens: agents first, then tasks.</summary>
    public int Highlighted { get; init; }
    public int Count => Agents.Count + Tasks.Count;

    /// <summary>Up (-1) and Down (+1) move the selected row and stay inside the list.</summary>
    public static int Move(int highlighted, int delta, int count) => Math.Clamp(highlighted + delta, 0, Math.Max(count - 1, 0));

    /// <summary>The row at <paramref name="index"/>: an agent's chat or a task's page; null with no row.</summary>
    public Page? Open(int index) =>
        index < 0 || index >= Count ? null
        : index < Agents.Count ? Page.Chat(Agents[index].Name) : Page.OfTask(Tasks[index - Agents.Count].Id);
}

public sealed record FileTile
{
    public MessageAttachment File { get; init; } = null!;
    public bool IsPicture { get; init; }
    public FileSymbol Symbol { get; init; }
    public string Name { get; init; } = "";
    public string Words { get; init; } = "";
    public bool WordsAreWarning { get; init; }
    /// <summary>A read of its bytes runs: "Reading…" over a picture, after a second.</summary>
    public bool Reading { get; init; }
    public string ReadingWords => "Reading…";
    public bool ShowsReadAgain { get; init; }
    public string ReadAgainHover { get; init; } = "";
    public string Hover { get; init; } = "";
}

public sealed record FileChip
{
    public StagedFile File { get; init; } = null!;
    /// <summary>A picture shows its small picture (26 px, from the bytes this PC holds); else a picture's or a file's mark.</summary>
    public bool IsPicture { get; init; }
    public string Words { get; init; } = "";
    public bool WordsAreWarning { get; init; }
    public bool ShowsSendAgain { get; init; }
    public string SendAgainHover { get; init; } = "";
    public bool ShowsTakeOut { get; init; }
    public string TakeOutHover { get; init; } = "";
}
