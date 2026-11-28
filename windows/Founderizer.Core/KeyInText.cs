using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Founderizer.Core;

/// <summary>**What looks like a key in a text that the owner is about to send** (FleetCore's KeyInText, rule for rule;
/// UI-API 1.249: the Mac's and a PC's apps hold text that looks like a key before it goes). The hub masks only the values
/// that it already knows, so a key in a message is in the agent's conversation, its runtime's own transcript and the
/// hub's records before anything can mask it.
///
/// It looks for two things: the shapes of the keys that the common services issue (each with its own prefix, so a match
/// is all but certain), and a long unbroken run of letters and digits in both cases that reads as random. It is a guard
/// and not a filter: the owner can always go on (<see cref="KeyHold"/>), and a text that it misses is no worse than
/// before. Its places are UTF-16 units, as the Mac's NSRange: the vectors of app/vectors/key-in-text.json, which the
/// Swift rule writes, hold the two equal.</summary>
public static partial class KeyInText
{
    /// <summary>The keys with a shape of their own, as FleetCore's KeyInText.swift writes them, literal for literal (a test
    /// compares the two files). A private key matches from its first line to its last.</summary>
    internal static readonly string[] ShapePatterns =
    {
        @"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----(?:[\s\S]{0,20000}?-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----)?",
        @"\bsk-(?:ant-[a-z0-9]+-|proj-|svcacct-|admin-|or-v1-)?[A-Za-z0-9_-]{20,}",      // Anthropic, OpenAI, OpenRouter
        @"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}", @"\bwhsec_[A-Za-z0-9]{20,}",          // Stripe
        @"\bgh[pousr]_[A-Za-z0-9]{30,}", @"\bgithub_pat_[A-Za-z0-9_]{40,}", @"\bglpat-[A-Za-z0-9_-]{20,}",
        @"\bxox[abposr]-[A-Za-z0-9-]{10,}", @"\bxapp-[A-Za-z0-9-]{10,}",                     // Slack
        @"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b", @"\bAIza[0-9A-Za-z_-]{35}",                          // AWS, Google
        @"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}",                                       // SendGrid
        @"\b(?:hf|gsk|r8|npm|xai|pplx|tvly|lin_api|shpat|shpss|dop_v1)_[A-Za-z0-9_-]{20,}",
        @"\b(?:xai|pplx)-[A-Za-z0-9]{30,}",
        @"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",                    // a signed token
    };

    /// <summary>A run that can be a key with no shape of its own: base64 and URL-safe letters, at least 32 of them.</summary>
    internal const string RunPattern = @"[A-Za-z0-9+/=_-]{32,4096}";

    /// <summary>The literal start of each shape that begins with `\b`, which every find of it begins with (null for the
    /// private key, which begins with none), in the order of <see cref="ShapePatterns"/>: the hub's
    /// <c>KEY_SHAPE_HEADS</c>. Each shape's pattern begins with its start (<see cref="Compile"/> checks it).</summary>
    internal static readonly string?[] ShapeHeads =
    [
        null, "sk-", "(?:sk|rk)_", "whsec_", "gh[pousr]_", "github_pat_", "glpat-", "xox[abposr]-", "xapp-", "(?:AKIA|ASIA)",
        "AIza", @"SG\.", "(?:hf|gsk|r8|npm|xai|pplx|tvly|lin_api|shpat|shpss|dop_v1)_", "(?:xai|pplx)-", "eyJ",
    ];

    /// <summary>One shape as .NET runs it: its pattern without the `\b` at its start or its end, which
    /// <see cref="Boundary"/> checks as ICU does. A shape with a literal start has <c>Starts</c>, its start alone, which
    /// .NET finds with its fast search for a literal, and <c>Anchored</c>, its pattern tried at one place; <c>SkipsRun</c>:
    /// a failed try leaves out the starts inside its run (<see cref="FirstOf"/>).</summary>
    private sealed record Shape(Regex Regex, bool Before, bool After, Regex? Starts = null, Regex? Anchored = null, bool SkipsRun = false);

    private static readonly Shape[] Shapes = ShapePatterns.Zip(ShapeHeads, Compile).ToArray();

    private static readonly Regex Run = new(RunPattern, RegexOptions.CultureInvariant);

    private static Shape Compile(string pattern, string? head)
    {
        var before = pattern.StartsWith(@"\b", StringComparison.Ordinal);
        var after = pattern.EndsWith(@"\b", StringComparison.Ordinal);
        var body = pattern[(before ? 2 : 0)..^(after ? 2 : 0)];
        if (body.Contains(@"\b", StringComparison.Ordinal))
            throw new InvalidOperationException("a word boundary inside a shape: " + pattern);
        var regex = new Regex(body, RegexOptions.CultureInvariant);
        if (head is null) return new Shape(regex, before, after);
        if (!before || !body.StartsWith(head, StringComparison.Ordinal))
            throw new InvalidOperationException("a shape that does not begin with its start: " + pattern);
        return new Shape(regex, before, after, new Regex(head, RegexOptions.CultureInvariant),
                         new Regex(@"\G" + body, RegexOptions.CultureInvariant), SkipsRun: head == "eyJ");
    }

    /// <summary>The first match of a shape whose word boundaries hold where ICU, the Mac's regular expressions, sees
    /// them. A boundary is zero-width, so the first place that passes gives the match that ICU gives. **A shape with a
    /// literal start is tried only where its start is and ICU's boundary holds, in place** (the hub's
    /// <c>key_shape_finds_by_start</c>, 25 November 2026): a search from each place ran the shape's tail over the whole
    /// run at each start whose boundary failed, so <c>"ask-"</c> repeated took minutes for a megabyte. And a failed try
    /// of the signed token (<c>eyJ R\.eyJ R\.R</c>, R a run of <c>[A-Za-z0-9_-]</c> with no ".") leaves out each later
    /// start inside its run: the first R of each ends where the run ends, and the rest is the same, so each of them fails
    /// as it did (<c>" " + "eyJ-"</c> repeated read the run again from each start). The finds stay the same.</summary>
    private static Match? FirstOf(Shape shape, string text)
    {
        if (shape.Starts is { } starts && shape.Anchored is { } anchored)
        {
            for (var at = 0; at < text.Length; )
            {
                var head = starts.Match(text, at);
                if (!head.Success) return null;
                // The next start can begin inside this one: the search goes on from the unit after it.
                var start = head.Index;
                at = start + 1;
                // A start after an ASCII letter, digit or "_" has no boundary for ICU either: every start begins with an
                // ASCII letter.
                if (start > 0 && IsAsciiWord(text[start - 1]) || !Boundary(text, start)) continue;
                var match = anchored.Match(text, start);
                if (match.Success && (!shape.After || Boundary(text, match.Index + match.Length))) return match;
                if (!match.Success && shape.SkipsRun) at = RunEnd(text, start);
            }
            return null;
        }
        for (var at = 0; at <= text.Length; )
        {
            var match = shape.Regex.Match(text, at);
            if (!match.Success) return null;
            if ((!shape.Before || Boundary(text, match.Index)) && (!shape.After || Boundary(text, match.Index + match.Length)))
                return match;
            at = match.Index + 1;
        }
        return null;
    }

    /// <summary>**ICU's `\b`** (its isWordBoundary): no boundary before a joiner that it looks past
    /// (<see cref="Skipped"/>: the marks, the format characters such as a zero-width space or joiner, the spacing marks of
    /// Grapheme_Extend and Apple's private-use joiners); else a boundary where a word character meets a character that
    /// is none, with the joiners before the place skipped. .NET's own `\b` reads a combining mark as a word character, a
    /// format character as none, and half of a pair as none, so a key after " \u0301", after "a\u200B" or after a
    /// letter outside the first plane was held on the Mac and not here. Word characters as ICU's: letters, letter
    /// numbers, marks, digits, connector punctuation, and the zero-width joiner and non-joiner.</summary>
    internal static bool Boundary(string text, int at)
    {
        var here = false;
        if (at < text.Length)
        {
            var rune = RuneAt(text, at);
            if (Skipped(rune)) return false;
            here = IsWord(rune);
        }
        var before = false;
        for (var end = at; end > 0; )
        {
            Rune rune;
            if (end >= 2 && char.IsLowSurrogate(text[end - 1]) && char.IsHighSurrogate(text[end - 2]))
            {
                rune = new Rune(text[end - 2], text[end - 1]);
                end -= 2;
            }
            else
            {
                rune = char.IsSurrogate(text[end - 1]) ? Rune.ReplacementChar : new Rune(text[end - 1]);
                end -= 1;
            }
            if (Skipped(rune)) continue;
            before = IsWord(rune);
            break;
        }
        return here != before;
    }

    private static bool IsAsciiWord(char c) => c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '_';

    /// <summary>The end of the run of <c>[A-Za-z0-9_-]</c> that begins at <paramref name="start"/>.</summary>
    private static int RunEnd(string text, int start)
    {
        var end = start;
        while (end < text.Length && text[end] is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '_' or '-') end++;
        return end;
    }

    private static Rune RuneAt(string text, int at) =>
        Rune.TryGetRuneAt(text, at, out var rune) ? rune : Rune.ReplacementChar;

    /// <summary>**A scalar that ICU's boundary looks past**, as measured on the Mac that wrote the shared vectors
    /// (<see cref="BoundarySkips"/>, <c>tables.boundary_skips</c>): the marks that do not stand alone, the format
    /// characters, every character of Grapheme_Extend (a spacing one too, such as U+09BE or U+1D165) and Apple's
    /// private-use joiners (U+F870-F87F, U+F884-F899, U+F89F). Not .NET's own Unicode data, which has none of the last two
    /// kinds (the Door area's reader, 25 November 2026).</summary>
    private static bool Skipped(Rune rune) => InRanges(rune.Value, BoundarySkips);

    /// <summary><paramref name="value"/> is in one of <paramref name="ranges"/>, which are in order and do not touch.</summary>
    private static bool InRanges(int value, (int First, int Last)[] ranges)
    {
        int low = 0, high = ranges.Length - 1;
        while (low <= high)
        {
            var middle = low + (high - low) / 2;
            if (value < ranges[middle].First) high = middle - 1;
            else if (value > ranges[middle].Last) low = middle + 1;
            else return true;
        }
        return false;
    }

    /// <summary>A word character as ICU's: also the circled and squared Latin letters, which its <c>\w</c> holds by their
    /// Alphabetic property though their category is a symbol (U+24B6-24E9; the squared, negative circled and
    /// negative squared capitals U+1F130-1F149, U+1F150-1F169 and U+1F170-1F189, and not the symbols between them).
    /// Measured against ICU over every code point on 24 November 2026: the same for each assigned one but Apple's
    /// private-use U+F870-F8D6, and the code points that Unicode 17 assigned, which .NET 10's data does not have.</summary>
    private static bool IsWord(Rune rune) => rune.Value is 0x200C or 0x200D or (>= 0x24B6 and <= 0x24E9) or (>= 0x1F130 and <= 0x1F149) or
        (>= 0x1F150 and <= 0x1F169) or (>= 0x1F170 and <= 0x1F189) || Rune.GetUnicodeCategory(rune) is
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter or
        UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter or UnicodeCategory.LetterNumber or
        UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark or
        UnicodeCategory.DecimalDigitNumber or UnicodeCategory.ConnectorPunctuation;

    /// <summary>The 15 shapes and the run, as written: what the test compares with FleetCore's file.</summary>
    internal static IReadOnlyList<string> Patterns => [.. ShapePatterns, RunPattern];

    /// <summary>The first part of <paramref name="text"/> that looks like a key (its first UTF-16 unit and its count of
    /// them), or null.</summary>
    public static (int Start, int Length)? First(string text)
    {
        (int Start, int Length)? found = null;
        foreach (var shape in Shapes)
        {
            if (FirstOf(shape, text) is { } match && (found is not { } before || match.Index < before.Start))
                found = (match.Index, match.Length);
        }
        // A run comes first only when it ends before the key with a shape begins: a run that holds that key is no better
        // a guess at it, and `NAME=sk-…` is the key and not its name.
        var read = new Words(text);
        foreach (Match match in Run.Matches(text))
        {
            if (found is { } shaped && match.Index + match.Length > shaped.Start) continue;
            var value = Assigned(match.Index, match.Length, text);
            if (value.Length >= 32 && !read.InPicture(value.Start, value.Length) && !read.InAddressPath(value.Start) &&
                LooksRandom(text.Substring(value.Start, value.Length)))
            {
                found = value;
                break;
            }
        }
        return found;
    }

    /// <summary>Whether <paramref name="text"/> holds something that looks like a key.</summary>
    public static bool Contains(string text) => First(text) is not null;

    /// <summary>**A knowledge file's text as the hub saves it** (FleetCore's <c>savedForm</c>, the hub's
    /// <c>knowledge_saved_text</c>): one "\n" for each line end ("\r\n" and "\r"), and a space for each other control
    /// character (U+0000-0008, U+000B-001F and U+007F-009F; a tab and "\n" stay). A knowledge file's check, and the
    /// parts that he keeps with "Keep it", read this form, as the hub checks it: in the raw text a private key's lines can
    /// end in "\r\n", and U+001F joins words that the saved file parts. Each other guard (a chat, a request's answer, the
    /// field of Needs clarification) reads the raw text. The PC writes no knowledge file yet, so nothing calls this; it
    /// is here, held to the shared vectors' <c>saved</c> cases, for the day it does.</summary>
    public static string SavedForm(string text)
    {
        var saved = new StringBuilder(text.Length);
        var afterReturn = false;
        foreach (var unit in text)
        {
            if (afterReturn && unit == '\n')
            {
                // "\r\n": the "\n" of its "\r"
                afterReturn = false;
                continue;
            }
            afterReturn = unit == '\r';
            if (unit == '\r') saved.Append('\n');
            else if (unit <= (char)0x08 || unit is >= (char)0x0B and <= (char)0x1F || unit is >= (char)0x7F and <= (char)0x9F) saved.Append(' ');
            else saved.Append(unit);
        }
        return saved.ToString();
    }

    /// <summary>The part of a run after its last `=` that is not base64's padding: the value of `NAME=value`, or the run.</summary>
    internal static (int Start, int Length) Assigned(int start, int length, string text)
    {
        var body = text.Substring(start, length).TrimEnd('=');
        var sign = body.LastIndexOf('=');
        if (sign < 0) return (start, length);
        var skip = sign + 1;
        return (start + skip, length - skip);
    }

    /// <summary>A run that reads as random: capitals, small letters and digits all three, not a path, about as varied as
    /// random letters are, changing between them as often, and with few runs of small letters that read as words. A name
    /// in camel case, a hash in hex, a path and a UUID are none of these. Of random runs of 32 letters and digits, about 1
    /// in 40 passes as not random; of longer ones, almost none.</summary>
    internal static bool LooksRandom(string run)
    {
        var scalars = run.EnumerateRunes().ToArray();
        if (scalars.Length < 32 || run.StartsWith('/') || run.Contains("//", StringComparison.Ordinal)) return false;
        var kinds = scalars.Select(Kind).ToArray();
        if (!kinds.Contains(0) || !kinds.Contains(1) || !kinds.Contains(2)) return false;
        var counts = new Dictionary<Rune, int>();
        foreach (var scalar in scalars) counts[scalar] = counts.GetValueOrDefault(scalar) + 1;
        double total = scalars.Length;
        var entropy = 0.0;
        foreach (var count in counts.Values)
        {
            var share = count / total;
            entropy -= share * Math.Log2(share);
        }
        var changes = kinds.Zip(kinds.Skip(1)).Count(pair => pair.First != pair.Second) / (total - 1);
        // The letters that stand in runs of four or more small letters: most of a name, little of a key.
        int wordy = 0, small = 0;
        foreach (var kind in kinds.Append(0))
        {
            if (kind == 1) { small++; continue; }
            if (small >= 4) wordy += small;
            small = 0;
        }
        return entropy >= 4.2 && changes >= 0.4 && wordy / total < 0.4;
    }

    /// <summary>Apple's whitespacesAndNewlines: .NET's whitespace and the zero-width space (U+200B). Measured over the
    /// first plane on 24 November 2026: the two sets are the same then (neither holds U+001C to U+001F).</summary>
    private static bool IsSpace(char c) => char.IsWhiteSpace(c) || c == (char)0x200B;

    /// <summary>**The words of a text, read once from its first unit to its last** (FleetCore's <c>Words</c>, d739adb48):
    /// each run read its word back to the space before it, so a long word, such as a picture's data in a Markdown file,
    /// took seconds for a megabyte. A word reaches from the last whitespace (<see cref="IsSpace"/>) or half of a pair
    /// before a place, as a run's word was read (the Mac reads one UTF-16 unit as a scalar, which stops at half of a
    /// pair); each place asked for is at or after the one before.</summary>
    internal struct Words(string text)
    {
        private const string ImageMark = "data:image/", Base64Mark = ";base64,";

        /// <summary>The part of a picture's address that <see cref="at"/> stands in (<see cref="Read"/>): its media type
        /// after "data:image/" (<see cref="Picture.Type"/>), or its base64 after ";base64," (<see cref="Picture.Data"/>).</summary>
        private enum Picture { None, Type, Data }

        /// <summary>The units read: up to here.</summary>
        private int at;
        private Picture picture;
        /// <summary>Of the word that begins at <see cref="word"/>: the end of its first <c>://</c>, and the place of the
        /// first <c>?</c> or <c>#</c> after it, as the words before a run were searched; found once for the whole word
        /// (<see cref="Facts"/>).</summary>
        private int word = -1;
        private int? scheme, query;

        /// <summary>The first unit of the word that the next unread unit stands in.</summary>
        public int Start { get; private set; }

        /// <summary>**Whether a run stands in the base64 of a picture's <c>data:</c> address** (in a Markdown or HTML
        /// file: <c>![logo](data:image/png;base64,…)</c>), whose letters read as random and are no key. All of this, in
        /// one word:
        /// 1. "data:image/", then ";base64,", and between them only the units of a media type and its parameters: A-Z,
        ///    a-z, 0-9 and <c>. + - _ ; = %</c>;
        /// 2. from just after ";base64," to the run, only base64's letters: A-Z, a-z, 0-9, "+" and "/";
        /// 3. the run itself is base64: those letters, and "=" only at its end.
        /// Any other unit ends the picture for good, "=" too: a later ";base64," of the word opens nothing until another
        /// "data:image/" (25 November 2026: <c>…=","k":"x;base64,RUN</c> and <c>…=token=RUN</c> were let through). So a
        /// comma, a quote, a bracket or a colon before ";base64,", and a run right after the "=" of a picture, are read as
        /// any text, as is a <c>data:</c> address of another kind. A picture longer than one run (4,096 letters) stays a
        /// picture in each of its runs. A key with a shape of its own is found there all the same. The same rule in each
        /// port of <c>app/vectors/key-in-text.json</c>.
        ///
        /// What it still lets through: a random run, and a key whose shape needs a word boundary at its start or its end
        /// (AWS, Google, SendGrid), that is base64 letters and touches a picture's letters with no mark between: it reads
        /// as more of the picture, at any length (the rule before 24 November 2026 held it from 32 letters). So a key
        /// that is the whole of a picture's data (<c>data:image/png;base64,&lt;key&gt;</c>), a key at the start of the
        /// data with letters of the picture after it, and a key joined to them with "+" or "/", which are base64's letters
        /// too. After "=", a quote, a bracket or a space every key is found again, and a run with "-" or "_" in it is no
        /// base64 (3).
        ///
        /// What it holds that is no key, by choice: a picture whose base64 a "-" or "_" follows with no mark between, as
        /// the end of an HTML comment (<c>data:image/png;base64,…--&gt;</c>): the run holds them, so it is no base64 (3).
        /// He can keep it with "Keep it".</summary>
        public bool InPicture(int location, int length)
        {
            Read(location);
            if (picture != Picture.Data) return false;
            // a run's value holds "=" only at its end (Assigned); this holds the rule also for a caller that does not
            var padding = false;
            for (var index = location; index < location + length; index++)
            {
                var unit = text[index];
                if (unit == '=') padding = true;
                else if (padding || !IsLetter(unit)) return false;
            }
            return true;
        }

        /// <summary>**Whether a run that begins at <paramref name="location"/> stands in the path of a web address**,
        /// where the id of a document, a file or a commit reads as random and is no key: after the word's first
        /// <c>://</c> and before its query or fragment (<c>?</c> or <c>#</c>). A run in a query (<c>?key=…</c>) is looked
        /// at, and a key with a shape of its own is found anywhere. The word's <c>://</c> and its <c>?</c> or <c>#</c>
        /// are found once for all its runs (each run searched its word up to itself, so a line of thousands of hashes or
        /// ids took minutes); a find before the run's start is a find of the words before it, because whether it counts
        /// reads only the unit after it (<see cref="Stands"/>).</summary>
        public bool InAddressPath(int location)
        {
            Read(location);
            if (word != Start) Facts();
            if (scheme is not { } after || after > location) return false;
            return query is not { } mark || mark >= location;
        }

        /// <summary>The word's first <c>://</c> that counts, and the first <c>?</c> or <c>#</c> that counts after it
        /// (<see cref="Stands"/>): read once from the word's start to its end, as the hub's port reads them
        /// (<c>key_word_facts</c>).</summary>
        private void Facts()
        {
            word = Start;
            scheme = null;
            query = null;
            var end = Start;
            while (end < text.Length && !Stops(text[end])) end++;
            for (var index = Start; index + 3 <= end; index++)
            {
                if (text[index] == ':' && text[index + 1] == '/' && text[index + 2] == '/' && Stands(index + 3, end))
                {
                    scheme = index + 3;
                    break;
                }
            }
            if (scheme is not { } from) return;
            for (var mark = from; mark < end; mark++)
            {
                if (text[mark] is '?' or '#' && Stands(mark + 1, end))
                {
                    query = mark;
                    return;
                }
            }
        }

        /// <summary>**Whether a find that ends before unit <paramref name="at"/> counts**: not when that unit joins the find's
        /// last character (<see cref="ExtendsFind"/>), as Foundation's search read the words before a run, whatever came
        /// after them. Half of a pair stands. The same in the Mac's and the hub's ports (<c>stands</c>,
        /// <c>key_stands</c>).</summary>
        private readonly bool Stands(int at, int end) => at >= end || !ExtendsFind(text[at]);

        /// <summary>**A unit that joins the character before it, so that a find of <c>://</c>, <c>?</c> or <c>#</c> before it
        /// does not count**, as Foundation's search reads it: one of the 1,141 units of the first plane that the Mac which
        /// wrote the shared vectors measured (<see cref="AddressMarks"/>, <c>tables.address_marks</c>): every non-spacing
        /// and enclosing mark, U+200C, the spacing marks of Grapheme_Extend, and the marks that Unicode 16 and 17 added.
        /// Not .NET's own Unicode data, which may lack the newest ones (the validator's M1: "https://" + U+1ACF + "x/" +
        /// RUN). Half of a pair is no mark.</summary>
        internal static bool ExtendsFind(char unit) => InRanges(unit, AddressMarks);

        /// <summary>Reads up to <paramref name="location"/>, where the run begins; <see cref="Start"/> is then its word's
        /// first unit.</summary>
        private void Read(int location)
        {
            while (at < location)
            {
                var unit = text[at];
                if (Stops(unit))
                {
                    Start = at + 1;
                    picture = Picture.None;
                }
                else
                {
                    switch (picture)
                    {
                        case Picture.Type:
                            // ";base64," cannot reach back into "data:image/", which holds no ";"
                            if (Ends(at, Base64Mark)) picture = Picture.Data;
                            else if (!IsType(unit)) picture = Picture.None;
                            break;
                        case Picture.Data:
                            // "=" ends the base64 too: what follows it is no picture
                            if (!IsLetter(unit)) picture = Picture.None;
                            break;
                    }
                    // the ":" of "data:image/" ended any picture before it, so this begins a picture of its own
                    if (picture == Picture.None && Ends(at, ImageMark)) picture = Picture.Type;
                }
                at++;
            }
        }

        /// <summary>The units up to <paramref name="index"/> end with <paramref name="mark"/>.</summary>
        private readonly bool Ends(int index, string mark) =>
            index + 1 >= mark.Length && text.AsSpan(index + 1 - mark.Length, mark.Length).SequenceEqual(mark);

        /// <summary>A unit that ends a word: whitespace, or half of a pair, where the walk back from a run stopped.</summary>
        private static bool Stops(char unit) => char.IsSurrogate(unit) || IsSpace(unit);

        /// <summary>Base64's letters, without its "=".</summary>
        private static bool IsLetter(char c) => c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '+' or '/';

        /// <summary>The units of a media type and its parameters (<c>image/svg+xml;charset=utf-8</c>).</summary>
        private static bool IsType(char c) =>
            c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '.' or '+' or '-' or '_' or ';' or '=' or '%';
    }

    private static int Kind(Rune scalar) => scalar.Value switch
    {
        >= 'A' and <= 'Z' => 0,
        >= 'a' and <= 'z' => 1,
        >= '0' and <= '9' => 2,
        _ => 3,
    };
}
