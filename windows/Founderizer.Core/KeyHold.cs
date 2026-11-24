using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Linq;

namespace Founderizer.Core;

/// <summary>**The hold of words that look like a key, over a box that the owner writes in** (the Mac's KeyHoldBanner, in
/// the chat's composer, a request's answer box and the field of Needs clarification; UI-PATTERNS.md): while the box's
/// words hold what looks like a key (<see cref="KeyInText"/>), they do not go, Send stands down, and the hold asks him
/// what to do. "Keep it" (<see cref="OwnerStore.KeepKey"/>) lets those words go, and no second question comes while the
/// key stays in the box. Such words are never kept in the drafts' file, also after "Keep it".
///
/// The Mac's hold has a second button, "Save it as a secret", which puts the key into the vault's form: this app has no
/// form of a secret yet (PARITY.md, `secrets`, waits for 2.3), so its hold has only what it can do here, and its words
/// say nothing of a vault. The Mac's second hold, of a key that Cmd+V would paste ("Paste it anyway"), is that button's
/// way to the clipboard: here a pasted key stands in the box and this hold takes it, so it goes nowhere either.</summary>
public sealed record KeyHoldModel
{
    /// <summary>The hold's first line, the Mac's for a text.</summary>
    public string Words => "This message holds what looks like a key.";
    /// <summary>Its second line, in the muted colour: who would have the key.</summary>
    public string Line { get; init; } = "";
    /// <summary>The one button: the words go as they are.</summary>
    public string KeepWords => "Keep it";
    /// <summary>What an assistive app reads for the hold.</summary>
    public string Spoken => Words + " " + Line;
}

/// <summary>The boxes that the hold watches, by the names of their files' composers, and the hold of one box.</summary>
public static class KeyHold
{
    /// <summary>A chat's composer.</summary>
    public static string Chat(string agent) => "agent:" + agent;
    /// <summary>A request's answer box.</summary>
    public static string Answer(long need) => "need:" + need;
    /// <summary>The field of Needs clarification under a request.</summary>
    public static string Talk(long need) => "talk:" + need;

    /// <summary>The hold over <paramref name="box"/>, whose words go to <paramref name="agent"/>, or null while it holds
    /// nothing: its words hold no key, or he chose to keep it.</summary>
    public static KeyHoldModel? Of(StoreState s, string box, string text, string agent) =>
        s.HoldsKey(box, text)
            ? new KeyHoldModel { Line = $"In a message, {s.Names.Label(agent)} and its transcripts would have it." }
            : null;

    /// <summary>The words of a box in the state, or null for a name that is no box.</summary>
    internal static string? TextOf(StoreState s, string box)
    {
        if (box.StartsWith("agent:", StringComparison.Ordinal)) return s.Drafts.GetValueOrDefault(box[6..], "");
        if (box.StartsWith("need:", StringComparison.Ordinal) && long.TryParse(box.AsSpan(5), out var need))
            return s.AnswerDrafts.GetValueOrDefault(need, "");
        if (box.StartsWith("talk:", StringComparison.Ordinal) && long.TryParse(box.AsSpan(5), out var card))
            return s.ClarifyDrafts.GetValueOrDefault(card, "");
        return null;
    }

    /// <summary>The state after a change: "Keep it" only for the boxes whose words still hold a key (a box whose words hold
    /// none, because he took the key out or it went, asks again for the next one, as the Mac's keyAllowed ends), and the
    /// drafts out of the file only while their box is not empty (<see cref="StoreState.KeyDrafts"/>).</summary>
    public static StoreState Tidy(StoreState s)
    {
        if (s.KeysKept.Count > 0 && !s.KeysKept.All(box => TextOf(s, box) is { } text && KeyInText.Contains(text)))
            s = s with { KeysKept = s.KeysKept.Where(box => TextOf(s, box) is { } text && KeyInText.Contains(text)).ToImmutableHashSet() };
        if (s.KeyDrafts.Count > 0 && !s.KeyDrafts.All(box => TextOf(s, box) is { Length: > 0 }))
            s = s with { KeyDrafts = s.KeyDrafts.Where(box => TextOf(s, box) is { Length: > 0 }).ToImmutableHashSet() };
        return s;
    }
}
