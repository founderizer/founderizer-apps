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

/// <summary>An agent by its name (FleetCore's AgentNames; the owner's answers of 22 November 2026 to F16, option (a)):
/// the apps name an agent by its name with capitals wherever they name it, and its role, its team.json `title`, stands
/// beside the name where a place shows the agent as an entry of its own. A role that holds the name is the label alone
/// ("Fleet Manager" for `manager`). One book for one reading of the hub.</summary>
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

    /// <summary>The agent as the apps name it: its name with capitals ("web-dev" is "Web-Dev"), or its role when one word
    /// of the role is the name ("Fleet Manager" for `manager`).</summary>
    public string Label(string name) =>
        roles.TryGetValue(name, out var role) && Says(role, name) ? role : Capitalized(name);

    /// <summary>The role beside the label: after " · " in the pane's row, under the name on the agent's panel; null for an
    /// agent with no role, and for a role that is the label already ("Fleet Manager").</summary>
    public string? Role(string name) =>
        roles.TryGetValue(name, out var role) && !Says(role, name) ? role : null;

    /// <summary>True when one word of the role is the name: the role in small letters, cut at each character that is no
    /// letter and no digit.</summary>
    private static bool Says(string role, string name)
    {
        var words = new List<string>();
        var word = new StringBuilder();
        foreach (var c in role.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(c)) { word.Append(c); continue; }
            if (word.Length > 0) { words.Add(word.ToString()); word.Clear(); }
        }
        if (word.Length > 0) words.Add(word.ToString());
        return words.Contains(name.ToLowerInvariant());
    }

    /// <summary>True when <paramref name="words"/> find this agent by its label, its name or its role, ignoring case and
    /// marks, as a search field does.</summary>
    public bool Matches(string name, string words, CultureInfo? culture = null)
    {
        // An empty text finds nobody, as Swift's localizedStandardContains("") (swift-words.json, "matches").
        if (words.Length == 0) return false;
        var compare = (culture ?? CultureInfo.CurrentCulture).CompareInfo;
        const CompareOptions loose = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreWidth;
        return compare.IndexOf(Label(name), words, loose) >= 0 || compare.IndexOf(name, words, loose) >= 0
               || (roles.TryGetValue(name, out var role) && compare.IndexOf(role, words, loose) >= 0);
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

    /// <summary>The block's words as runs with their inline marks (<see cref="InlineMarks.Runs"/>): a code block's lines
    /// are one run of code, and a rule has none.</summary>
    public IReadOnlyList<InlineRun> Runs => Kind switch
    {
        Kinds.Code => Text.Length == 0 ? [] : [new InlineRun(Text, false, false, false, true, null)],
        Kinds.Rule or Kinds.Table => [],
        _ => InlineMarks.Runs(Text),
    };

    /// <summary>A table's cells as runs, row by row, the header first.</summary>
    public IReadOnlyList<IReadOnlyList<IReadOnlyList<InlineRun>>> RowRuns =>
        Rows.Select(row => (IReadOnlyList<IReadOnlyList<InlineRun>>)row.Select(InlineMarks.Runs).ToList()).ToList();

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
/// <summary>One run of a text's inline marks: its words, and what it is.</summary>
public sealed record InlineRun(string Text, bool Bold, bool Italic, bool Struck, bool Code, string? Link);

public static partial class InlineMarks
{
    public static string Plain(string text)
    {
        // Code spans first, as CommonMark reads them: their words are literal, a backslash and an entity in them too
        // (`\\server\share`, `C:\fz\`), and they come back last. Then the escapes: a backslash before ASCII punctuation
        // is the punctuation, which no later rule reads.
        var codes = new List<string>();
        var protectedText = Code().Replace(text, m =>
        {
            codes.Add(CodeWords(m.Groups[2].Value));
            return "\uE002" + (codes.Count - 1) + "\uE003";
        });
        protectedText = Escape().Replace(protectedText, m => "\uE000" + (int)m.Groups[1].Value[0] + "\uE001");
        protectedText = Image().Replace(protectedText, "$1");
        // A link's words hold no bare address: they are marked while the addresses are read, and no longer after that.
        protectedText = Link().Replace(protectedText, "$1");
        protectedText = AutoLink().Replace(protectedText, "$1");
        var bare = new List<string>();
        protectedText = BareAddresses(protectedText, '', '', (_, words) => Kept(bare, words))
            .Replace("", "").Replace("", "");
        string before;
        do
        {
            before = protectedText;
            protectedText = Strong().Replace(protectedText, "$2");
            protectedText = Struck().Replace(protectedText, "$1");
            protectedText = StarEmphasis().Replace(protectedText, "$1");
            protectedText = UnderscoreEmphasis().Replace(protectedText, "$1$2");
        } while (protectedText != before);
        protectedText = Escaped().Replace(protectedText,
                                         m => ((char)int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)).ToString());
        protectedText = System.Net.WebUtility.HtmlDecode(protectedText.Replace("&<", "&\uE004<")).Replace("&\uE004<", "&<");
        return Coded().Replace(Restored(protectedText, bare), m => codes[int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)]);
    }

    /// <summary>The text's runs, each with its marks (the Mac's MessageText draws MessageBlock.inline's runs): bold,
    /// italic, struck, inline code, and a link, whose address is only http, https or mailto (any other is its words with
    /// no link). The same steps as <see cref="Plain"/>, so the runs' words joined are always <c>Plain(text)</c>; in the
    /// rare text where a mark changes what a later step reads, the text is one run with no mark.</summary>
    public static IReadOnlyList<InlineRun> Runs(string text)
    {
        var codes = new List<string>();
        var marked = Code().Replace(text, m =>
        {
            codes.Add(CodeWords(m.Groups[2].Value));
            return "\uE002" + (codes.Count - 1) + "\uE003";
        });
        marked = Escape().Replace(marked, m => "\uE000" + (int)m.Groups[1].Value[0] + "\uE001");
        var links = new List<string>();
        string LinkTo(string address, string words)
        {
            links.Add(address);
            return "\uE018" + (links.Count - 1) + "\uE019" + words + "\uE01A";
        }
        marked = Image().Replace(marked, "$1");
        marked = LinkAddress().Replace(marked, m => LinkTo(m.Groups[2].Value, m.Groups[1].Value));
        marked = AutoLink().Replace(marked, m => LinkTo(m.Groups[1].Value, m.Groups[1].Value));
        var bare = new List<string>();
        marked = BareAddresses(marked, '\uE018', '\uE01A', (address, words) => LinkTo(address, Kept(bare, words)));
        string before;
        do
        {
            before = marked;
            marked = Strong().Replace(marked, "\uE010$2\uE011");
            marked = Struck().Replace(marked, "\uE012$1\uE013");
            marked = StarEmphasis().Replace(marked, "\uE014$1\uE015");
            marked = UnderscoreEmphasis().Replace(marked, "\uE014$1\uE015$2");
        } while (marked != before);
        // An email address is read after the emphasis, in the words that are left (the reader's own order).
        marked = EmailAddresses(marked, LinkTo);
        marked = Escaped().Replace(marked, m => ((char)int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)).ToString());
        marked = System.Net.WebUtility.HtmlDecode(marked.Replace("&<", "&\uE004<")).Replace("&\uE004<", "&<");
        marked = Restored(marked, bare);
        // The code spans' words last, as they were written (no escape and no entity is read in them).
        marked = Coded().Replace(marked, m => "\uE016" + codes[int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)] + "\uE017");

        var runs = new List<InlineRun>();
        var words = new StringBuilder();
        int bold = 0, italic = 0, struck = 0, code = 0;
        var open = new Stack<string?>();
        void Emit()
        {
            if (words.Length == 0) return;
            var link = open.Count > 0 ? open.Peek() : null;
            var run = new InlineRun(words.ToString(), bold > 0, italic > 0, struck > 0, code > 0, link);
            if (runs.Count > 0 && runs[^1] with { Text = run.Text } == run) runs[^1] = runs[^1] with { Text = runs[^1].Text + run.Text };
            else runs.Add(run);
            words.Clear();
        }
        for (var i = 0; i < marked.Length; i++)
        {
            var c = marked[i];
            switch (c)
            {
                case '\uE010': Emit(); bold++; break;
                case '\uE011': Emit(); bold--; break;
                case '\uE012': Emit(); struck++; break;
                case '\uE013': Emit(); struck--; break;
                case '\uE014': Emit(); italic++; break;
                case '\uE015': Emit(); italic--; break;
                case '\uE016': Emit(); code++; break;
                case '\uE017': Emit(); code--; break;
                case '\uE018':
                    Emit();
                    var end = marked.IndexOf('\uE019', i);
                    var address = links[int.Parse(marked.AsSpan(i + 1, end - i - 1), CultureInfo.InvariantCulture)];
                    open.Push(OpensInBrowser(address) ? address : null);
                    i = end;
                    break;
                case '\uE01A': Emit(); if (open.Count > 0) open.Pop(); break;
                default: words.Append(c); break;
            }
        }
        Emit();
        var plain = Plain(text);
        if (string.Concat(runs.Select(r => r.Text)) != plain || bold != 0 || italic != 0 || struck != 0 || code != 0)
            return plain.Length == 0 ? [] : [new InlineRun(plain, false, false, false, false, null)];
        return runs;
    }

    /// <summary>A link's address that the PC's browser may open: http, https or mailto, with something after it.</summary>
    public static bool OpensInBrowser(string address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var uri) &&
        (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeMailto);

    /// <summary>The words of a bare address, kept out of the emphasis and the entities: the reader takes them as they
    /// are written, so `https://example.com/**x**` is no bold and `&amp;` in it stays `&amp;`.</summary>
    private static string Kept(List<string> kept, string words)
    {
        kept.Add(words);
        return "" + (kept.Count - 1).ToString(CultureInfo.InvariantCulture) + "";
    }

    private static string Restored(string marked, List<string> kept) =>
        kept.Count == 0 ? marked : KeptWords().Replace(marked, m => kept[int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture)]);

    /// <summary>The bare addresses of a text as the Mac's reader of inline Markdown links them: Apple's swift-cmark, with
    /// the autolinks of GitHub's Markdown (its <c>url_match</c>, <c>www_match</c> and <c>autolink_delim</c>), measured on a
    /// Mac on 15 November 2026. An address of http, https or ftp (any case, its scheme not after a letter), and one that
    /// starts with "www." (after a space, "*", "_", "~" or "(", or at the start), whose host is not empty and has no "_"
    /// in its last two parts. It runs to a space or "&lt;"; then a final "?", "!", ".", ",", ":", "*", "_", "~", "'" or
    /// """, an entity, and a ")" with no "(" of its own leave it. A "www." address goes to http. The words of a link
    /// hold none: <paramref name="open"/> and <paramref name="close"/> mark them.</summary>
    private static string BareAddresses(string marked, char open, char close, Func<string, string, string> make)
    {
        StringBuilder? result = null;
        var copied = 0;
        var depth = 0;
        for (var i = 0; i < marked.Length; i++)
        {
            var c = marked[i];
            if (c == open) { depth++; continue; }
            if (c == close) { depth--; continue; }
            if (depth > 0) continue;
            int start, end;
            string address;
            if (c == ':' && Url(marked, i, out start, out end)) address = marked[start..end];
            else if (c == 'w' && Www(marked, i, out end)) { start = i; address = "http://" + marked[i..end]; }
            else continue;
            if (start < copied) continue;
            result ??= new StringBuilder(marked.Length + 16);
            result.Append(marked, copied, start - copied).Append(make(address, marked[start..end]));
            copied = end;
            i = end - 1;
        }
        return result is null ? marked : result.Append(marked, copied, marked.Length - copied).ToString();
    }

    private static bool Url(string s, int colon, out int start, out int end)
    {
        start = end = 0;
        if (s.Length - colon < 4 || s[colon + 1] != '/' || s[colon + 2] != '/') return false;
        var rewind = 0;
        while (colon - rewind - 1 >= 0 && char.IsAsciiLetter(s[colon - rewind - 1])) rewind++;
        start = colon - rewind;
        var scheme = s[start..colon].ToLowerInvariant();
        var host = colon + 3;
        if (scheme is not ("http" or "https" or "ftp") || host >= s.Length || !IsHostChar(s, host)) return false;
        var domain = Domain(s, host, allowShort: true);
        if (domain == 0) return false;
        var linkEnd = host + domain;
        while (linkEnd < s.Length && !IsSpace(s[linkEnd]) && s[linkEnd] != '<' && !IsMark(s[linkEnd])) linkEnd++;
        var length = Delim(s, colon, linkEnd - colon);
        if (length == 0) return false;
        end = colon + length;
        return true;
    }

    private static bool Www(string s, int w, out int end)
    {
        end = 0;
        if (w > 0 && "*_~(".IndexOf(s[w - 1]) < 0 && !IsSpace(s[w - 1])) return false;
        if (s.Length - w < 4 || string.CompareOrdinal(s, w, "www.", 0, 4) != 0) return false;
        var domain = Domain(s, w, allowShort: false);
        if (domain == 0) return false;
        var linkEnd = w + domain;
        while (linkEnd < s.Length && !IsSpace(s[linkEnd]) && s[linkEnd] != '<' && !IsMark(s[linkEnd])) linkEnd++;
        var length = Delim(s, w, linkEnd - w);
        if (length == 0) return false;
        end = w + length;
        return true;
    }

    /// <summary>check_domain: how far the host goes from <paramref name="from"/>, or 0 for a host with "_" in one of its
    /// last two parts, or with no "." when a short host is not taken.</summary>
    private static int Domain(string s, int from, bool allowShort)
    {
        var size = s.Length - from;
        int i, dots = 0, before = 0, last = 0;
        for (i = 1; i < size - 1; i++)
        {
            if (s[from + i] == '\\' && i < size - 2) i++;
            var c = s[from + i];
            if (c == '_') last++;
            else if (c == '.') { before = last; last = 0; dots++; }
            else if (!IsHostChar(s, from + i) && c != '-') break;
        }
        if (before > 0 || last > 0) return 0;
        return allowShort || dots > 0 ? i : 0;
    }

    /// <summary>autolink_delim: the length of the link in <paramref name="length"/> characters from
    /// <paramref name="from"/>, without what ends a sentence.</summary>
    private static int Delim(string s, int from, int length)
    {
        int opening = 0, closing = 0;
        for (var i = 0; i < length; i++)
        {
            var c = s[from + i];
            if (c == '<') { length = i; break; }
            if (c == '(') opening++;
            else if (c == ')') closing++;
        }
        while (length > 0)
        {
            switch (s[from + length - 1])
            {
                case ')':
                    if (closing <= opening) return length;
                    closing--;
                    length--;
                    break;
                case '?' or '!' or '.' or ',' or ':' or '*' or '_' or '~' or '\'' or '"':
                    length--;
                    break;
                case ';':
                    var entity = length - 2;
                    while (entity > 0 && char.IsAsciiLetter(s[from + entity])) entity--;
                    if (entity < length - 2 && s[from + entity] == '&') length = entity;
                    else length--;
                    break;
                default:
                    return length;
            }
        }
        return length;
    }

    /// <summary>The email addresses of the words that the emphasis left, as the reader's autolinks read them after it:
    /// letters and digits of ASCII, ".", "+", "-" and "_" before one "@" (and "mailto:" before them, not after a letter or
    /// a digit), and after it a host with a "." between two letters or digits, which ends on a letter or a ".". It goes
    /// to mailto, and loses what ends a sentence as an address does.</summary>
    private static string EmailAddresses(string marked, Func<string, string, string> make)
    {
        StringBuilder? result = null;
        var copied = 0;
        var depth = 0;
        for (var i = 0; i < marked.Length; i++)
        {
            var c = marked[i];
            if (c == '') { depth++; continue; }
            if (c == '') { depth--; continue; }
            if (depth > 0 || c != '@') continue;
            var rewind = 0;
            var mailto = true;
            while (i - rewind - 1 >= copied)
            {
                var p = marked[i - rewind - 1];
                if (char.IsAsciiLetterOrDigit(p) || p is '.' or '+' or '-' or '_') { rewind++; continue; }
                if (p == ':' && Protocol(marked, i - rewind - 1, copied)) { mailto = false; rewind++; continue; }
                break;
            }
            if (rewind == 0) continue;
            int at = 0, dots = 0, k;
            for (k = 0; i + k < marked.Length; k++)
            {
                var q = marked[i + k];
                if (char.IsAsciiLetterOrDigit(q)) continue;
                if (q == '@') at++;
                else if (q == '.' && i + k < marked.Length - 1 && char.IsAsciiLetterOrDigit(marked[i + k + 1])) dots++;
                else if (q != '-' && q != '_') break;
            }
            if (k < 2 || at != 1 || dots == 0 || (!char.IsAsciiLetter(marked[i + k - 1]) && marked[i + k - 1] != '.')) continue;
            var length = Delim(marked, i, k);
            if (length == 0) continue;
            var start = i - rewind;
            var words = marked[start..(i + length)];
            result ??= new StringBuilder(marked.Length + 16);
            result.Append(marked, copied, start - copied).Append(make(mailto ? "mailto:" + words : words, words));
            copied = i + length;
            i = copied - 1;
        }
        return result is null ? marked : result.Append(marked, copied, marked.Length - copied).ToString();
    }

    /// <summary>validate_protocol for "mailto:" whose colon is at <paramref name="colon"/>: the word before it, not after
    /// a letter or a digit.</summary>
    private static bool Protocol(string s, int colon, int floor)
    {
        const string protocol = "mailto:";
        var from = colon + 1 - protocol.Length;
        if (from < floor || string.CompareOrdinal(s, from, protocol, 0, protocol.Length) != 0) return false;
        return from == floor || !char.IsAsciiLetterOrDigit(s[from - 1]);
    }

    /// <summary>is_valid_hostchar: not a space and not punctuation (ASCII's, and Unicode's of the P categories). The
    /// second half of a pair of surrogates is part of its character. The library's own marks end a host.</summary>
    private static bool IsHostChar(string s, int i)
    {
        var c = s[i];
        if (IsMark(c)) return false;
        if (char.IsLowSurrogate(c)) return true;
        if (c < 128) return c is not (' ' or '\t' or '\n' or '\f' or '\r') && !char.IsPunctuation(c) && !char.IsSymbol(c);
        var category = char.IsHighSurrogate(c) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1])
            ? CharUnicodeInfo.GetUnicodeCategory(char.ConvertToUtf32(c, s[i + 1])) : CharUnicodeInfo.GetUnicodeCategory(c);
        return category is not (UnicodeCategory.SpaceSeparator or UnicodeCategory.ConnectorPunctuation
            or UnicodeCategory.DashPunctuation or UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation
            or UnicodeCategory.InitialQuotePunctuation or UnicodeCategory.FinalQuotePunctuation
            or UnicodeCategory.OtherPunctuation);
    }

    /// <summary>cmark_isspace: the spaces of ASCII.</summary>
    private static bool IsSpace(char c) => c is ' ' or '\t' or '\n' or '\v' or '\f' or '\r';

    /// <summary>A mark of this reader's own (the private-use characters that hold a code span, an escape or a link).</summary>
    private static bool IsMark(char c) => c is >= '' and <= '';

    [GeneratedRegex(@"(\d+)")]
    private static partial Regex KeptWords();

    [GeneratedRegex(@"\[([^\]]+)\]\(((?:[^()\s]|\([^()\s]*\))*)(?:\s+""[^""]*"")?\)")]
    private static partial Regex LinkAddress();

    [GeneratedRegex(@"\\([!-/:-@\[-`{-~])")]
    private static partial Regex Escape();

    [GeneratedRegex(@"\uE000(\d+)\uE001")]
    private static partial Regex Escaped();

    /// <summary>A code span as CommonMark reads it, and so the Mac (Foundation's AttributedString, measured on a Mac on 21
    /// November 2026): a whole run of backticks that no backslash escapes opens it, only a whole run of as many closes it,
    /// and it goes on over a line's end. "a `x``" holds no code, and "\`x\`" none.</summary>
    [GeneratedRegex(@"(?<!(?<!\\)(?:\\\\)*\\)(?:(?<!`)|(?<=(?<!\\)(?:\\\\)*\\`))(`+)(?!`)(.+?)(?<!`)\1(?!`)", RegexOptions.Singleline)]
    private static partial Regex Code();

    /// <summary>The words of a code span as CommonMark gives them, and so the Mac: each line's end is a space, and one
    /// space goes from each end when both ends have one and the words are not all spaces ("` ls `" is "ls", "`ls `" stays
    /// "ls "). A value's copy holds exactly these characters (<see cref="CardValues"/>).</summary>
    private static string CodeWords(string words)
    {
        words = words.Replace("\r\n", " ").Replace('\r', ' ').Replace('\n', ' ');
        return words.Length >= 2 && words[0] == ' ' && words[^1] == ' ' && words.Any(c => c != ' ') ? words[1..^1] : words;
    }

    [GeneratedRegex(@"\uE002(\d+)\uE003")]
    private static partial Regex Coded();

    // A link's address may hold balanced parentheses, one level deep, as CommonMark reads it ("javascript:alert(1)").
    [GeneratedRegex(@"!\[([^\]]*)\]\((?:[^()\s]|\([^()\s]*\))*(?:\s+""[^""]*"")?\)")]
    private static partial Regex Image();

    [GeneratedRegex(@"\[([^\]]+)\]\((?:[^()\s]|\([^()\s]*\))*(?:\s+""[^""]*"")?\)")]
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

    /// <summary>How many of a chat's newest items a row reads to find where its newest card stands (ChatList.rowReads).</summary>
    public const int RowReads = 20;

    /// <summary>The request that waits for him when its card is the newest thing in the agent's chat (ChatList.waitingRequest,
    /// the Mac's rule of 14 November 2026, Founderizer 0.1.224): its title is then the row's line, in orange, and the row's
    /// time is the card's. The card's place is the chat's own (<see cref="ChatPlaces.InTime"/>), so a card under the
    /// agent's reply of its turn is still the newest thing. <paramref name="items"/>: the chat's newest items, oldest
    /// first; <paramref name="whole"/>: they are its whole chat.</summary>
    public static OwnerNeed? WaitingRequest(string agent, IReadOnlyList<MobileChatItem> items, bool whole, IEnumerable<OwnerNeed> needs)
    {
        var mine = needs.Where(n => n.By == agent).ToList();
        if (!mine.Any(n => n.IsOpen)) return null;
        return ChatPlaces.InTime(mine, items, whole).Rows(items).LastOrDefault() is { Need: { } id }
            ? mine.FirstOrDefault(n => n.Id == id && n.IsOpen) : null;
    }

    /// <summary>The time of a row whose line is a waiting request's (ChatList.requestTime): when its card came, or the
    /// reply over it when that came later.</summary>
    public static double RequestTime(OwnerNeed need, MobileChatItem? last) => Math.Max(need.Raised, last?.Ts ?? 0);

    /// <summary>The time at the end of an agent's row (ChatList.lastTime): the time of the last message of its chat,
    /// his or the agent's, also while the line names what the agent is doing; null before the first message. It was the
    /// last move of the agent's open tasks while the line named one (the owner, 14 November 2026: "last message is from
    /// Thursday but on the sidebar it says 8:09 today").</summary>
    public static double? LastTime(MobilePreview? last) => Preview("", last, []) is null ? null : last?.Ts;

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
        // his message under a card (the Mac's label of needTalk), with the item's title
        (OwnerCommand.TalkKind, _, null) => "Ask about a request",
        (OwnerCommand.TalkKind, _, { } t) => $"Ask about \u201c{t}\u201d",
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

/// <summary>How many things need him, as the Mac's Needs you row says it (FleetView.needsRow): one whole sentence for
/// each count.</summary>
public static class NeedsWords
{
    public static string Count(int count) => count switch
    {
        0 => "Nothing needs you",
        1 => "1 item needs you",
        _ => $"{count} items need you",
    };
}

/// <summary>The hover of a composer's plus, the same for a chat and for an answer (AttachButton.words).</summary>
public static class AttachWords
{
    public static string PlusHover(int staged) => staged < MessageAttachment.PerMessage
        ? "Send a picture, a PDF, a ZIP or a text file with this message"
        : $"A message carries at most {MessageAttachment.PerMessage} files";
}

/// <summary>A usage window's share as both apps write it under its bar ("\(n)%", AgentStatusPanel and AgentPage).</summary>
public static class ShareWords
{
    public static string Of(int percent) => $"{percent}%";
}
