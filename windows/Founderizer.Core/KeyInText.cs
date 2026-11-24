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
public static class KeyInText
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

    /// <summary>One shape as .NET runs it: its pattern without the `\b` at its start or its end, which
    /// <see cref="Boundary"/> checks as ICU does.</summary>
    private sealed record Shape(Regex Regex, bool Before, bool After);

    private static readonly Shape[] Shapes = ShapePatterns.Select(Compile).ToArray();

    private static readonly Regex Run = new(RunPattern, RegexOptions.CultureInvariant);

    private static Shape Compile(string pattern)
    {
        var before = pattern.StartsWith(@"\b", StringComparison.Ordinal);
        var after = pattern.EndsWith(@"\b", StringComparison.Ordinal);
        var body = pattern[(before ? 2 : 0)..^(after ? 2 : 0)];
        if (body.Contains(@"\b", StringComparison.Ordinal))
            throw new InvalidOperationException("a word boundary inside a shape: " + pattern);
        return new Shape(new Regex(body, RegexOptions.CultureInvariant), before, after);
    }

    /// <summary>The first match of a shape whose word boundaries hold where ICU, the Mac's regular expressions, sees
    /// them. A boundary is zero-width, so the first place that passes gives the match that ICU gives.</summary>
    private static Match? FirstOf(Shape shape, string text)
    {
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

    /// <summary>**ICU's `\b`** (its isWordBoundary): no boundary before a combining mark or a format character (a
    /// zero-width space or joiner); else a boundary where a word character meets a character that is none, with the
    /// marks and format characters before the place skipped. .NET's own `\b` reads a combining mark as a word character,
    /// a format character as none, and half of a pair as none, so a key after " \u0301", after "a\u200B" or after a
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

    private static Rune RuneAt(string text, int at) =>
        Rune.TryGetRuneAt(text, at, out var rune) ? rune : Rune.ReplacementChar;

    /// <summary>A character that ICU's boundary passes over: a mark that does not stand alone, or a format character.</summary>
    private static bool Skipped(Rune rune) => Rune.GetUnicodeCategory(rune) is
        UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.Format;

    private static bool IsWord(Rune rune) => rune.Value is 0x200C or 0x200D || Rune.GetUnicodeCategory(rune) is
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
        foreach (Match match in Run.Matches(text))
        {
            if (found is { } shaped && match.Index + match.Length > shaped.Start) continue;
            var value = Assigned(match.Index, match.Length, text);
            if (value.Length >= 32 && !InAddressPath(value.Start, text) && LooksRandom(text.Substring(value.Start, value.Length)))
            {
                found = value;
                break;
            }
        }
        return found;
    }

    /// <summary>Whether <paramref name="text"/> holds something that looks like a key.</summary>
    public static bool Contains(string text) => First(text) is not null;

    /// <summary>The part of a run after its last `=` that is not base64's padding: the value of `NAME=value`, or the run.</summary>
    internal static (int Start, int Length) Assigned(int start, int length, string text)
    {
        var body = text.Substring(start, length).TrimEnd('=');
        var sign = body.LastIndexOf('=');
        if (sign < 0) return (start, length);
        var skip = sign + 1;
        return (start + skip, length - skip);
    }

    /// <summary>Whether a run stands in the path of a web address, where the id of a document, a file or a commit reads as
    /// random and is no key: after `://` and before the address's query. A run in a query (`?key=…`) is looked at, and a
    /// key with a shape of its own is found anywhere.</summary>
    internal static bool InAddressPath(int start, string text)
    {
        // The word that holds the run: from the space before it, by Apple's whitespace, which also holds the zero-width
        // space. The Mac's reading of one UTF-16 unit as a scalar stops at half of a pair, as this does.
        var from = start;
        while (from > 0 && !char.IsSurrogate(text[from - 1]) && !IsSpace(text[from - 1])) from--;
        // Swift searches this word (NSString's substring) as Foundation does: by UTF-16 unit, where a find of `://`, `?`
        // or `#` does not count when the unit after it, in the word, extends it with a non-spacing mark, an enclosing
        // mark or U+200C (a variation selector is a non-spacing mark); a spacing mark, U+200D or a prepended mark
        // changes nothing (some differ, see the commit), and the search for `://` goes on past a find that does not
        // count (the review of round 4). No copy of the word: a pasted line with no space has a run of 32 every few
        // dozen characters, and each looks back to its start.
        var word = text.AsSpan(from, start - from);
        var scheme = Found(word, "://");
        if (scheme < 0) return false;
        for (var at = scheme + 3; at < word.Length; at++)
            if (word[at] is '?' or '#' && Stands(word, at + 1)) return false;
        return true;
    }

    /// <summary>The first find of <paramref name="what"/> in <paramref name="word"/> that counts (<see cref="Stands"/>),
    /// or -1.</summary>
    private static int Found(ReadOnlySpan<char> word, string what)
    {
        for (var from = 0; from <= word.Length - what.Length; )
        {
            var at = word[from..].IndexOf(what.AsSpan(), StringComparison.Ordinal);
            if (at < 0) return -1;
            at += from;
            if (Stands(word, at + what.Length)) return at;
            from = at + 1;
        }
        return -1;
    }

    /// <summary>Whether a find that ends before unit <paramref name="next"/> of the word counts on the Mac: not when that
    /// unit extends it with a non-spacing mark, an enclosing mark or U+200C (the variation selectors are non-spacing
    /// marks).</summary>
    private static bool Stands(ReadOnlySpan<char> word, int next)
    {
        if (next >= word.Length) return true;
        var unit = word[next];
        if (unit == (char)0x200C) return false;
        var rune = Rune.ReplacementChar;
        if (char.IsHighSurrogate(unit) && next + 1 < word.Length) Rune.TryCreate(unit, word[next + 1], out rune);
        else if (!char.IsSurrogate(unit)) rune = new Rune(unit);
        return Rune.GetUnicodeCategory(rune) is not (UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark);
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

    /// <summary>Apple's whitespacesAndNewlines: .NET's whitespace and the zero-width space (U+200B).</summary>
    private static bool IsSpace(char c) => char.IsWhiteSpace(c) || c == (char)0x200B;

    private static int Kind(Rune scalar) => scalar.Value switch
    {
        >= 'A' and <= 'Z' => 0,
        >= 'a' and <= 'z' => 1,
        >= '0' and <= '9' => 2,
        _ => 3,
    };
}
