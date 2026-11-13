using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Founderizer.Core;

/// <summary>Where the screens are: the time zone and the culture that dates and times are written in. The tests give
/// their own; the app gives <see cref="Local"/>.</summary>
public sealed record ScreenContext(TimeZoneInfo Zone, CultureInfo Culture)
{
    public static ScreenContext Local => new(TimeZoneInfo.Local, CultureInfo.CurrentCulture);

    /// <summary>The calendar day in this zone of a Unix time.</summary>
    public DateTime Day(double unix) => LocalTime(unix).Date;

    public DateTime LocalTime(double unix) =>
        TimeZoneInfo.ConvertTimeFromUtc(DateTime.UnixEpoch.AddSeconds(unix), Zone);

    /// <summary>The first moment of a local day, as a Unix time.</summary>
    public double Unix(DateTime localDay) =>
        (TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(localDay, DateTimeKind.Unspecified), Zone) - DateTime.UnixEpoch)
        .TotalSeconds;
}

/// <summary>An agent by its role (FleetCore's AgentNames): both apps name an agent by its team.json `title` wherever they
/// name it, and an agent with no role by its name with capitals. One book for one reading of the hub.</summary>
public sealed class AgentBook
{
    private readonly Dictionary<string, string> roles;

    public AgentBook(IEnumerable<(string Name, string? Title)> agents)
    {
        roles = new Dictionary<string, string>();
        foreach (var (name, title) in agents)
        {
            var role = string.Join(' ', (title ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
            if (role.Length > 0) roles[name] = role;
        }
    }

    public static AgentBook Of(MobileSnapshot? snapshot) =>
        new((snapshot?.Agents ?? []).Select(a => (a.Name, a.Title)));

    public static readonly AgentBook Empty = new([]);

    public IReadOnlyDictionary<string, string> Roles => roles;

    /// <summary>The agent as both apps name it: its role, else its name with capitals ("web-dev" is "Web-Dev").</summary>
    public string Label(string name) => roles.TryGetValue(name, out var role) ? role : Capitalized(name);

    /// <summary>The small line under the role on the agent's panel: its name with capitals; null for an agent with no
    /// role, and for a role that says the name already ("Fleet Manager" over "Manager").</summary>
    public string? Under(string name)
    {
        if (!roles.TryGetValue(name, out var role)) return null;
        var words = new List<string>();
        var word = new StringBuilder();
        foreach (var c in role.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(c)) { word.Append(c); continue; }
            if (word.Length > 0) { words.Add(word.ToString()); word.Clear(); }
        }
        if (word.Length > 0) words.Add(word.ToString());
        return words.Contains(name.ToLowerInvariant()) ? null : Capitalized(name);
    }

    /// <summary>True when <paramref name="words"/> find this agent by its role or by its name, ignoring case and marks,
    /// as a search field does.</summary>
    public bool Matches(string name, string words, CultureInfo? culture = null)
    {
        // An empty text finds nobody, as Swift's localizedStandardContains("") (swift-words.json, "matches").
        if (words.Length == 0) return false;
        var compare = (culture ?? CultureInfo.CurrentCulture).CompareInfo;
        const CompareOptions loose = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreWidth;
        return compare.IndexOf(Label(name), words, loose) >= 0 || compare.IndexOf(name, words, loose) >= 0;
    }

    /// <summary>A name as Swift's `capitalized` writes it: each letter after a character that is no letter (or at the
    /// start) in upper case, every other letter in lower case ("web_dev" is "Web_Dev", "a1b2" is "A1B2").</summary>
    public static string Capitalized(string name)
    {
        var out_ = new StringBuilder(name.Length);
        var afterLetter = false;
        foreach (var c in name)
        {
            out_.Append(char.IsLetter(c) ? (afterLetter ? char.ToLowerInvariant(c) : char.ToUpperInvariant(c)) : c);
            afterLetter = char.IsLetter(c);
        }
        return out_.ToString();
    }
}

/// <summary>The words of times and ages, as the apps write them.</summary>
public static class TimeWords
{
    /// <summary>The time at the end of an agent's row, as a chat app writes it (ChatList.time): the time of day for
    /// today, "Yesterday", the weekday within the last week, else the date in numbers. A time ahead of the clock reads as
    /// today's. The patterns are the culture's (short time, weekday, short date).</summary>
    public static string RowTime(double timestamp, double now, ScreenContext context)
    {
        var date = context.LocalTime(timestamp);
        var days = (context.Day(now) - date.Date).Days;
        var format = context.Culture.DateTimeFormat;
        if (days <= 0) return date.ToString(format.ShortTimePattern, context.Culture);
        if (days == 1) return "Yesterday";
        if (days < 7) return date.ToString("dddd", context.Culture);
        return date.ToString(format.ShortDatePattern, context.Culture);
    }

    /// <summary>How long ago, in a few words (activityAge): "Just now", "5 min ago", "3 h ago", "2 days ago", and from
    /// seven days the day and the month, with the year when it is not this year's.</summary>
    public static string Age(double time, double now, ScreenContext context)
    {
        var seconds = Math.Max(0, now - time);
        if (seconds < 60) return "Just now";
        if (seconds < 3600) return $"{(int)(seconds / 60)} min ago";
        if (seconds < 86_400) return $"{(int)(seconds / 3600)} h ago";
        if (seconds < 7 * 86_400) return (int)(seconds / 86_400) == 1 ? "1 day ago" : $"{(int)(seconds / 86_400)} days ago";
        var date = context.LocalTime(time);
        var pattern = context.Culture.DateTimeFormat.MonthDayPattern.Replace("MMMM", "MMM");
        if (date.Year != context.LocalTime(now).Year)
            pattern += pattern.TrimStart('\'').StartsWith('M') ? ", yyyy" : " yyyy";
        return date.ToString(pattern, context.Culture);
    }

    /// <summary>A day and a time as the Mac's facts write them (fleetDate): the medium date and the short time, "13 Nov
    /// 2026 at 15:00".</summary>
    public static string DateAndTime(double time, ScreenContext context)
    {
        var date = context.LocalTime(time);
        var day = date.ToString(context.Culture.DateTimeFormat.LongDatePattern
                                    .Replace("dddd, ", "").Replace("dddd ", "").Replace("MMMM", "MMM"), context.Culture);
        return day + " at " + date.ToString(context.Culture.DateTimeFormat.ShortTimePattern, context.Culture);
    }
}

/// <summary>One block of an agent's words, as both apps draw them (FleetCore's MessageBlock): a paragraph, a heading, a
/// list item, a quote, a code block, a rule or a table. A block keeps its inline marks in its text; a code block's text is
/// literal.</summary>
public sealed partial record MessageBlock(MessageBlock.Kinds Kind, string Text, string Marker = "", int Level = 0,
                                  IReadOnlyList<IReadOnlyList<string>>? Cells = null)
{
    public enum Kinds { Paragraph, Heading, Code, Item, Quote, Rule, Table }

    public IReadOnlyList<IReadOnlyList<string>> Rows => Cells ?? [];

    /// <summary>The blocks of one text, in order (MessageBlock.parse, rule for rule).</summary>
    public static IReadOnlyList<MessageBlock> Parse(string text)
    {
        var result = new List<MessageBlock>();
        var paragraph = new List<string>();
        List<string>? code = null;
        var codeIndent = 0;
        List<IReadOnlyList<string>>? table = null;
        var indents = new List<int>();
        var openItem = false;
        void Flush()
        {
            if (paragraph.Count > 0)
            {
                result.Add(new MessageBlock(Kinds.Paragraph, string.Join('\n', paragraph)));
                paragraph.Clear();
            }
            if (table is not null)
            {
                result.Add(new MessageBlock(Kinds.Table, "", Cells: table));
                table = null;
            }
        }
        void EndList() { indents.Clear(); openItem = false; }
        var lines = text.Split('\n');
        for (var index = 0; index < lines.Length; index++)
        {
            var line = lines[index];
            if (code is not null)
            {
                if (line.Trim(' ', '\t').StartsWith("```", StringComparison.Ordinal))
                {
                    result.Add(new MessageBlock(Kinds.Code, string.Join('\n', code)));
                    code = null;
                }
                else
                {
                    code.Add(DropLeading(line, Math.Min(codeIndent, Leading(line))));
                }
                continue;
            }
            if (table is not null)
            {
                if (TableRow(line) is { } row)
                {
                    if (!row.All(IsTableRule)) table.Add(row);
                    continue;
                }
                Flush();
            }
            else if (TableRow(line) is { } head && index + 1 < lines.Length && TableRow(lines[index + 1]) is { } next &&
                     next.All(IsTableRule))
            {
                Flush();
                EndList();
                table = [head];
                continue;
            }
            var indent = Leading(line);
            var trimmed = line.TrimStart(' ', '\t');
            if (trimmed.StartsWith("```", StringComparison.Ordinal))
            {
                Flush();
                openItem = false;
                code = [];
                codeIndent = indent;
            }
            else if (trimmed.Length == 0)
            {
                Flush();
                openItem = false;
            }
            else if (indent < 4 && trimmed is "---" or "***")
            {
                Flush();
                EndList();
                result.Add(new MessageBlock(Kinds.Rule, ""));
            }
            else if (indent < 4 && Heading().Match(trimmed) is { Success: true } heading)
            {
                Flush();
                EndList();
                result.Add(new MessageBlock(Kinds.Heading, trimmed[heading.Length..]));
            }
            else if (ItemMark().Match(trimmed) is { Success: true } mark)
            {
                Flush();
                while (indents.Count > 0 && indent < indents[^1]) indents.RemoveAt(indents.Count - 1);
                if (indents.Count == 0 || indent > indents[^1]) indents.Add(indent);
                var level = Math.Min(indents.Count - 1, 3);
                var written = mark.Value.Trim(' ');
                result.Add(new MessageBlock(Kinds.Item, trimmed[mark.Length..],
                                            written.Length == 1 ? "\u2022" : written, level));
                openItem = true;
            }
            else if (trimmed.StartsWith("> ", StringComparison.Ordinal))
            {
                Flush();
                EndList();
                result.Add(new MessageBlock(Kinds.Quote, trimmed[2..]));
            }
            else if (openItem && result.Count > 0)
            {
                var item = result[^1];
                result[^1] = item with { Text = item.Text + "\n" + trimmed };
            }
            else
            {
                if (indent < 2) EndList();
                paragraph.Add(indents.Count == 0 ? line : trimmed);
            }
        }
        Flush();
        if (code is not null) result.Add(new MessageBlock(Kinds.Code, string.Join('\n', code)));
        return result;
    }

    /// <summary>The words of a text without its marks, on one line (MessageBlock.plain): what a list of conversations
    /// shows of its newest message.</summary>
    public static string Plain(string text)
    {
        var words = new List<string>();
        foreach (var block in Parse(text))
        {
            switch (block.Kind)
            {
                case Kinds.Rule: break;
                case Kinds.Code: words.Add(block.Text); break;
                case Kinds.Table:
                    words.Add(string.Join(' ', block.Rows.Select(row => string.Join(' ', row.Select(InlineMarks.Plain)))));
                    break;
                default: words.Add(InlineMarks.Plain(block.Text)); break;
            }
        }
        var joined = string.Join(' ', words).Replace("**", "").Replace("`", "");
        return string.Join(' ', joined.Split(LineBreaks, StringSplitOptions.None)).Trim(' ');
    }

    private static readonly string[] LineBreaks = ["\r\n", "\n", "\r", "\u2028", "\u2029", "\u0085", "\u000b", "\u000c"];

    /// <summary>The width of a line's indent: a tab is four spaces.</summary>
    private static int Leading(string line)
    {
        var width = 0;
        foreach (var c in line)
        {
            if (c == ' ') width += 1;
            else if (c == '\t') width += 4;
            else break;
        }
        return width;
    }

    /// <summary>The line without its first <paramref name="count"/> characters of indent, as Swift's dropFirst does.</summary>
    private static string DropLeading(string line, int count) => line.Length <= count ? "" : line[count..];

    /// <summary>The cells of a table row: a line that starts with "|". A backslash before a "|" keeps it in its cell.</summary>
    private static List<string>? TableRow(string line)
    {
        var trimmed = line.Trim(' ', '\t');
        if (!trimmed.StartsWith('|') || trimmed.Length <= 1) return null;
        var cells = trimmed.Replace("\\|", "\u0001").Split('|').Skip(1).ToList();
        if (cells.Count > 0 && cells[^1].Trim(' ', '\t').Length == 0) cells.RemoveAt(cells.Count - 1);
        return cells.Count == 0 ? null : cells.Select(c => c.Replace("\u0001", "|").Trim(' ', '\t')).ToList();
    }

    /// <summary>A cell of the row under a table's header: dashes, with an optional ":" at each end.</summary>
    private static bool IsTableRule(string cell) => TableRule().IsMatch(cell);

    [GeneratedRegex(@"\A#{1,6} ", RegexOptions.CultureInvariant)]
    private static partial Regex Heading();

    [GeneratedRegex(@"\A(?:[-*+] |[0-9]+[.)] )", RegexOptions.CultureInvariant)]
    private static partial Regex ItemMark();

    [GeneratedRegex(@"\A:?-+:?\z", RegexOptions.CultureInvariant)]
    private static partial Regex TableRule();
}

/// <summary>Inline Markdown read to its words: bold, italic, strikethrough, inline code, links and escapes, as the apps
/// read a block's inline marks before they show its plain words (Swift's AttributedString with inline-only syntax). A
/// mark that does not close stays as it is. It covers the marks that agents write; a rare form of CommonMark (nested
/// brackets in a link's words, a run of three or more delimiters) can read differently.</summary>
public static partial class InlineMarks
{
    public static string Plain(string text)
    {
        // Escapes first: a backslash before ASCII punctuation is the punctuation, which no later rule reads.
        var protectedText = Escape().Replace(text, m => "\uE000" + (int)m.Groups[1].Value[0] + "\uE001");
        var codes = new List<string>();
        protectedText = Code().Replace(protectedText, m =>
        {
            codes.Add(m.Groups[2].Value);
            return "\uE002" + (codes.Count - 1) + "\uE003";
        });
        protectedText = Image().Replace(protectedText, "$1");
        protectedText = Link().Replace(protectedText, "$1");
        protectedText = AutoLink().Replace(protectedText, "$1");
        string before;
        do
        {
            before = protectedText;
            protectedText = Strong().Replace(protectedText, "$2");
            protectedText = Struck().Replace(protectedText, "$1");
            protectedText = StarEmphasis().Replace(protectedText, "$1");
            protectedText = UnderscoreEmphasis().Replace(protectedText, "$1$2");
        } while (protectedText != before);
        protectedText = Coded().Replace(protectedText, m => codes[int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)]);
        protectedText = Escaped().Replace(protectedText,
                                         m => ((char)int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)).ToString());
        return System.Net.WebUtility.HtmlDecode(protectedText.Replace("&<", "&\uE004<")).Replace("&\uE004<", "&<");
    }

    [GeneratedRegex(@"\\([!-/:-@\[-`{-~])")]
    private static partial Regex Escape();

    [GeneratedRegex(@"\uE000(\d+)\uE001")]
    private static partial Regex Escaped();

    [GeneratedRegex(@"(`+)(.+?)\1")]
    private static partial Regex Code();

    [GeneratedRegex(@"\uE002(\d+)\uE003")]
    private static partial Regex Coded();

    [GeneratedRegex(@"!\[([^\]]*)\]\([^)\s]*(?:\s+""[^""]*"")?\)")]
    private static partial Regex Image();

    [GeneratedRegex(@"\[([^\]]+)\]\([^)\s]*(?:\s+""[^""]*"")?\)")]
    private static partial Regex Link();

    [GeneratedRegex(@"<((?:https?|mailto):[^>\s]+)>")]
    private static partial Regex AutoLink();

    [GeneratedRegex(@"(\*\*|__)(?=\S)(.+?)(?<=\S)\1")]
    private static partial Regex Strong();

    [GeneratedRegex(@"~~(?=\S)(.+?)(?<=\S)~~")]
    private static partial Regex Struck();

    [GeneratedRegex(@"(?<!\*)\*(?=[^\s*])([^*]+?)(?<=[^\s*])\*(?!\*)")]
    private static partial Regex StarEmphasis();

    [GeneratedRegex(@"(?<![\p{L}\p{N}_])_(?=[^\s_])([^_]+?)(?<=[^\s_])_(?![\p{L}\p{N}_])()")]
    private static partial Regex UnderscoreEmphasis();
}

/// <summary>The line under an agent's name in the pane (FleetCore's ChatList, read from the device's answers): what it
/// is doing while one of its open tasks moved after its last message, else its last message, the owner's with "You: ".</summary>
public static partial class ChatLine
{
    /// <summary>The most a line reads of a message.</summary>
    public const int Reads = 400;

    /// <summary>What an agent is doing now (AgentActivity.doingNow): the title of the open task that moved last, with
    /// "· +N" for the others; null with no open task.</summary>
    public static string? DoingNow(string agent, IEnumerable<MobileTaskHead> tasks)
    {
        var open = tasks.Where(t => t.Owner == agent && !t.IsTerminal).ToList();
        if (open.Count == 0) return null;
        var last = open.OrderByDescending(Moved).First();
        return open.Count == 1 ? last.Title : $"{last.Title} \u00b7 +{open.Count - 1}";
    }

    private static double Moved(MobileTaskHead task) => task.LastActivity ?? task.Started ?? task.Created;

    /// <summary>What an agent does now, in plain words (hub 1.148; MobileSnapshot.action and AgentActivity.actionNow):
    /// the words of its task whose session works now, the one that moved last when several do; null when none of its
    /// tasks has a running turn that says something. While the agent works, the pane's line says this.</summary>
    public static string? ActionNow(string agent, IEnumerable<MobileTaskHead> tasks) =>
        tasks.Where(t => t.Owner == agent && !t.IsTerminal && t.State == "working" && t.Works == true &&
                         !string.IsNullOrWhiteSpace(t.Doing))
            .OrderByDescending(t => t.ActivityTime()).FirstOrDefault()?.Doing;

    /// <summary>When an agent's open tasks last moved, or null with none.</summary>
    public static double? MovedAt(string agent, IEnumerable<MobileTaskHead> tasks)
    {
        var times = tasks.Where(t => t.Owner == agent && !t.IsTerminal).Select(Moved).ToList();
        return times.Count == 0 ? null : times.Max();
    }

    /// <summary>The line (ChatList.preview): the task it is doing when one of its open tasks moved at or after its last
    /// line, else its last line, the owner's with "You: ". Null before the first line.</summary>
    public static string? Preview(string agent, MobilePreview? last, IEnumerable<MobileTaskHead> tasks)
    {
        var heads = tasks as IReadOnlyCollection<MobileTaskHead> ?? tasks.ToList();
        if (DoingNow(agent, heads) is { } doing && MovedAt(agent, heads) is { } moved && moved >= (last?.Ts ?? 0))
            return doing;
        if (last is null) return null;
        var words = Plain(last.Preview);
        if (words is null) return null;
        return last.Side == "agent" ? words : "You: " + words;
    }

    /// <summary>When that line is from (ChatList.previewTime), or null with no line.</summary>
    public static double? PreviewTime(string agent, MobilePreview? last, IEnumerable<MobileTaskHead> tasks)
    {
        var heads = tasks as IReadOnlyCollection<MobileTaskHead> ?? tasks.ToList();
        if (DoingNow(agent, heads) is not null && MovedAt(agent, heads) is { } moved && moved >= (last?.Ts ?? 0))
            return moved;
        return Preview(agent, last, []) is null ? null : last?.Ts;
    }

    /// <summary>What a message of Markdown says, on one line (ChatList.plain): the words it shows, without the marks of
    /// its headings, lists, quotes, emphasis, code and links. Null when nothing is left.</summary>
    public static string? Plain(string text)
    {
        var lines = new List<string>();
        var head = text.Length > Reads ? text[..Reads] : text;
        foreach (var raw in head.Split(LineBreaks, StringSplitOptions.RemoveEmptyEntries))
        {
            var line = raw.Trim(' ', '\t');
            if (line.StartsWith("```", StringComparison.Ordinal) || line.All(c => c is '|' or '-' or ':' or ' ')) continue;
            line = HeadingMark().Replace(line, "");
            line = QuoteMark().Replace(line, "");
            line = ListMark().Replace(line, "");
            if (line.StartsWith('|')) line = line.Replace('|', ' ');
            lines.Add(line);
        }
        var words = InlineMarks.Plain(string.Join(' ', lines));
        var single = string.Join(' ', words.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return single.Length == 0 ? null : single;
    }

    private static readonly string[] LineBreaks = ["\r\n", "\n", "\r", "\u2028", "\u2029", "\u0085", "\u000b", "\u000c"];

    [GeneratedRegex(@"\A#{1,6}\s+")]
    private static partial Regex HeadingMark();

    [GeneratedRegex(@"\A(>\s*)+")]
    private static partial Regex QuoteMark();

    [GeneratedRegex(@"\A([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?")]
    private static partial Regex ListMark();
}

/// <summary>The hover of a message's time in its footer (the Mac's footer): one whole sentence for each case, with its
/// values in it.</summary>
public static class MessageWords
{
    public static string TimeHover(string date, bool read, string? edited) => (read, edited) switch
    {
        (true, null) => $"{date} · Read",
        (false, null) => $"{date} · Received, not read yet",
        (true, { } at) => $"{date} · Read · Edited {at}",
        (false, { } at) => $"{date} · Received, not read yet · Edited {at}",
    };
}

/// <summary>The hover of one usage window (the Mac's usageWords): one whole sentence for each case.</summary>
public static class UsageWords
{
    public static string Hover(string label, string percent, string? resets, string? limited) => (resets, limited) switch
    {
        (null, null) => $"{label}: {percent}% used",
        ({ } r, null) => $"{label}: {percent}% used · resets {r}",
        (null, { } l) => $"{label}: {percent}% used · limited until {l}",
        ({ } r, { } l) => $"{label}: {percent}% used · resets {r} · limited until {l}",
    };
}

/// <summary>A command's name in the request line (OwnerCommand.label and label(in:)): one whole sentence for each
/// command, with its item's title in it when the reading has it.</summary>
public static class CommandWords
{
    public static string Name(OwnerCommand command, string? title) => (command.Kind, command.Action, title) switch
    {
        ("steer", _, null) => "Guide the task",
        ("steer", _, { } t) => $"Guide \u201c{t}\u201d",
        ("control", TaskControl.Pause, null) => "Pause the task",
        ("control", TaskControl.Pause, { } t) => $"Pause \u201c{t}\u201d",
        ("control", TaskControl.Stop, null) => "Stop the task",
        ("control", TaskControl.Stop, { } t) => $"Stop \u201c{t}\u201d",
        ("control", TaskControl.Resume, null) => "Resume the task",
        ("control", TaskControl.Resume, { } t) => $"Resume \u201c{t}\u201d",
        (_, _, null) => "Resume Check the task",
        (_, _, { } t) => $"Resume Check \u201c{t}\u201d",
    };
}
