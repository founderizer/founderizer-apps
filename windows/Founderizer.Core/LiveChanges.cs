using System;
using System.Globalization;

namespace Founderizer.Core;

/// <summary>The hub says when something that the owner sees changed (owner feature `live_changes`, UI-API.md 1.47), and
/// the app reads at that moment: `GET /ui/wait?db=&amp;since=&amp;wait=` answers as soon as the hub's change count moves
/// past the token that the app holds, or after `wait` seconds with the same token. The pure rules of
/// app/Sources/FleetCore/LiveChanges.swift, rule for rule.</summary>
public static class LiveChanges
{
    public const string Feature = "live_changes";
    /// <summary>The longest wait that the hub takes, and the one that the watcher asks for.</summary>
    public const int Wait = 20;
    /// <summary>At most one wake-driven read, and one wake of the pages, in this many seconds.</summary>
    public const double Cap = 2;
    /// <summary>The fleet's own read on the clock.</summary>
    public const double Poll = 3;

    /// <summary>How long the clock's read waits now: its interval counts from the last read, whoever ran it.</summary>
    public static double UntilRead(double? last, double now, double every = Poll)
    {
        if (last is not { } then) return 0;
        return Math.Min(every, Math.Max(0, every - (now - then)));
    }
}

/// <summary>One token of the hub's change count, `&lt;boot&gt;.&lt;state&gt;.&lt;activity&gt;`.</summary>
public sealed record LiveToken
{
    public string Text { get; }
    public string Boot { get; }
    public ulong State { get; }
    public ulong Activity { get; }

    private LiveToken(string text, string boot, ulong state, ulong activity)
    {
        Text = text;
        Boot = boot;
        State = state;
        Activity = activity;
    }

    /// <summary>The token, or null for anything that is not one. The counts are the last two parts, so a boot with a dot
    /// in it still reads; the boot keeps to characters that travel in a query as they are.</summary>
    public static LiveToken? Parse(string? text)
    {
        if (text is null || System.Text.Encoding.UTF8.GetByteCount(text) > 200) return null;
        var parts = text.Split('.');
        if (parts.Length < 3) return null;
        if (Count(parts[^2]) is not { } state || Count(parts[^1]) is not { } activity) return null;
        var boot = string.Join('.', parts, 0, parts.Length - 2);
        if (boot.Length == 0) return null;
        foreach (var c in boot)
            if (!(c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '.' or '_' or ':' or '-'))
                return null;
        return new LiveToken(text, boot, state, activity);
    }

    /// <summary>The wake: another boot, or another state count. The activity count never wakes anything.</summary>
    public bool Wakes(LiveToken since) => Boot != since.Boot || State != since.State;

    /// <summary>A read with this token already shows what <paramref name="other"/> says changed.</summary>
    public bool Covers(LiveToken other) => Boot == other.Boot && State >= other.State;

    private static ulong? Count(string part)
    {
        if (part.Length == 0) return null;
        foreach (var c in part) if (c is < '0' or > '9') return null;
        return ulong.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : null;
    }
}

/// <summary>What one wait said: the hub's token now, or a generation that changed.</summary>
public sealed record LiveAnswer
{
    public LiveToken? Token { get; }
    public bool IsGenerationChanged => Token is null;
    private LiveAnswer(LiveToken? token) => Token = token;
    public static LiveAnswer Of(LiveToken token) => new(token);
    public static readonly LiveAnswer GenerationChanged = new((LiveToken?)null);
}

/// <summary>What <see cref="WakeCap.Wake"/> answers.</summary>
public readonly record struct WakeAnswer(WakeAnswer.Kinds Kind, double At = 0)
{
    public enum Kinds { Now, At, Folded }
    public static WakeAnswer Now => new(Kinds.Now);
    public static WakeAnswer Folded => new(Kinds.Folded);
    public static WakeAnswer Later(double at) => new(Kinds.At, at);
}

/// <summary>At most one wake in <see cref="Interval"/>; the wakes inside it fold into one at its end. Times are seconds
/// of one clock that only goes forward.</summary>
public sealed class WakeCap(double interval = LiveChanges.Cap)
{
    public double Interval { get; } = interval;
    public double? Last { get; private set; }
    public bool Held { get; private set; }

    public WakeAnswer Wake(double now)
    {
        if (Held) return WakeAnswer.Folded;
        if (Last is { } last && now - last < Interval)
        {
            Held = true;
            return WakeAnswer.Later(last + Interval);
        }
        Last = now;
        return WakeAnswer.Now;
    }

    /// <summary>The held wake went out.</summary>
    public void Fired(double now)
    {
        Held = false;
        Last = now;
    }

    /// <summary>Another hub or another generation: nothing is held, and the next wake goes at once.</summary>
    public void Reset()
    {
        Last = null;
        Held = false;
    }
}

/// <summary>How long the watcher waits after a wait that failed: 1, 2, 4, 8, 16 and then 30 seconds, each within a fifth
/// of its value either way, and never under 1 or over 30.</summary>
public static class WakeBackoff
{
    /// <summary><paramref name="jitter"/> is a draw between 0 and 1.</summary>
    public static double Delay(int failures, double jitter)
    {
        if (failures <= 0) return 0;
        var basis = Math.Min(30, Math.Pow(2, Math.Min(failures, 6) - 1));
        var spread = basis * (0.8 + 0.4 * Math.Min(Math.Max(jitter, 0), 1));
        return Math.Min(30, Math.Max(1, spread));
    }
}

/// <summary>What comes after one answer of the wait.</summary>
public readonly record struct WatchStep(WatchStep.Kinds Kind, double Pause = 0)
{
    public enum Kinds { Wake, Wait, Pause }
    public static WatchStep Wake => new(Kinds.Wake);
    public static WatchStep Wait => new(Kinds.Wait);
    public static WatchStep PauseFor(double seconds) => new(Kinds.Pause, seconds);
}

/// <summary>What the watcher holds between two waits: the token that the next wait asks from, and the failures in a
/// row.</summary>
public sealed class LiveWatch(LiveToken from)
{
    public LiveToken Since { get; private set; } = from;
    public int Failures { get; private set; }

    /// <summary>One answer that took <paramref name="seconds"/>. An answer with nothing new that came back at once is no
    /// wait at all, so it counts as a failure and the watcher never asks such a hub in a tight loop.</summary>
    public WatchStep Answered(LiveToken token, double seconds, double jitter)
    {
        var wakes = token.Wakes(Since);
        Since = token;
        if (wakes)
        {
            Failures = 0;
            return WatchStep.Wake;
        }
        if (seconds < 1) return WatchStep.PauseFor(Failed(jitter));
        Failures = 0;
        return WatchStep.Wait;
    }

    /// <summary>One wait that failed: how long to wait before the next one.</summary>
    public double Failed(double jitter)
    {
        Failures += 1;
        return WakeBackoff.Delay(Failures, jitter);
    }
}
