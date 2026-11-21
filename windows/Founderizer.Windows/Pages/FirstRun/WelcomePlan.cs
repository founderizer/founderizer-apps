using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**The team of the welcome page and its one sequence** (the Mac's <c>WelcomeView.swift</c>: <c>TeamPlan</c>,
/// <c>WelcomeTeam</c>, <c>WorkDot</c>, <c>WelcomeMark</c>; the owner's yes of 14 November 2026 to its moving mock, and set
/// 8's picture 1 of its last frame). No WinUI here: the window draws these values, and the tests read them.
///
/// The manager's mark (100) over six agents' marks (56) on a flat arc, a hairline from the manager to each, in a box of
/// 776 by 238. One sequence of about six seconds, then stillness: the manager arrives, its lines grow from it, inner ones
/// first, and each agent arrives where its line ends; the title and the cards fade in; then the manager breathes once and
/// sends one small dot down each line, one after the other, and each agent makes its one move when its dot arrives.
/// Nothing loops. Every value starts at the start of the arrival (the bare canvas) and ends on the settled page exactly,
/// which is what the page shows from its first frame where Windows' animation effects are off.</summary>
internal static class WelcomePlan
{
    public const double ManagerSize = 100, AgentSize = 56;
    /// <summary>The mock put the manager's middle at 208 and its top at 158: the team's box starts at that top.</summary>
    private const double Top = 208 - ManagerSize / 2;

    /// <summary>How an agent answers the work that reaches it: the one move its mark makes.</summary>
    public enum Move { Breathe, Rock, QuarterTurn, SixthTurn }

    public sealed record Agent(double Dx, GlyphKind Kind, int Tone, Move Move);

    /// <summary>From left to right: circle sky, sparkle amber, hexagon blue, diamond orchid, clover coral, flower rose.</summary>
    public static readonly IReadOnlyList<Agent> Agents =
    [
        new(-360, GlyphKind.Circle, 4, Move.Breathe),
        new(-216, GlyphKind.Sparkle, 1, Move.QuarterTurn),
        new(-72, GlyphKind.Hexagon, 5, Move.Breathe),
        new(72, GlyphKind.Diamond, 7, Move.Rock),
        new(216, GlyphKind.Clover, 0, Move.QuarterTurn),
        new(360, GlyphKind.Flower, 8, Move.SixthTurn),
    ];

    /// <summary>The manager: the mint squircle.</summary>
    public const GlyphKind ManagerKind = GlyphKind.Squircle;
    public const int ManagerTone = 3;

    /// <summary>**FleetMark's nine hues** (<see cref="GlyphLook"/>'s list, by its places: coral, amber, lime, mint, sky,
    /// blue, sand, orchid, rose), each as its lighter and its deeper step. The marks of this page are nobody's, so they take
    /// a hue by its place, as the Mac's <c>GlyphLook(kind:tone:)</c> does; a test holds this list to the library's.</summary>
    public static readonly IReadOnlyList<(Rgb Light, Rgb Deep)> Tones =
    [
        (new(1.00, 0.62, 0.54), new(0.94, 0.34, 0.28)),
        (new(1.00, 0.81, 0.40), new(0.95, 0.60, 0.09)),
        (new(0.79, 0.92, 0.44), new(0.50, 0.74, 0.17)),
        (new(0.47, 0.92, 0.76), new(0.12, 0.71, 0.53)),
        (new(0.49, 0.86, 0.97), new(0.11, 0.62, 0.83)),
        (new(0.56, 0.71, 0.99), new(0.08, 0.44, 0.72)),
        (new(0.90, 0.76, 0.58), new(0.68, 0.45, 0.22)),
        (new(0.83, 0.61, 0.98), new(0.68, 0.16, 0.78)),
        (new(0.98, 0.60, 0.81), new(0.88, 0.27, 0.60)),
    ];

    public static double Width => 2 * Agents.Max(a => Math.Abs(a.Dx)) + AgentSize;
    public static double Height => 368 + AgentSize / 2 - Top;

    public static (double X, double Y) ManagerAt => (Width / 2, 208 - Top);

    public static (double X, double Y) At(Agent agent) => (Width / 2 + agent.Dx, 368 - 0.00014 * agent.Dx * agent.Dx - Top);

    /// <summary>The line from the manager to an agent, as a cubic: it leaves down and arrives down.</summary>
    public static ((double X, double Y) From, (double X, double Y) C1, (double X, double Y) C2, (double X, double Y) To) Line(Agent agent)
    {
        var from = ManagerAt;
        var to = At(agent);
        return (from, (from.X, from.Y + 96), (to.X, to.Y - 96), to);
    }

    /// <summary>The dot of a welcome mark: its middle in the mark's square, and its side as a part of the mark's; its soft
    /// ring is 1.75 times as wide. The manager's looks from its top right; an agent's stands in its middle.</summary>
    public static ((double X, double Y) At, double Side) DotOf(bool manager) => manager ? ((0.655, 0.345), 0.19) : ((0.5, 0.5), 0.18);

    // ------------------------------------------------------------------ the timeline

    /// <summary>When each line starts to grow: the inner agents first, 0.07 s apart from 0.28 s.</summary>
    public static double Grows(int index)
    {
        var order = Enumerable.Range(0, Agents.Count)
                              .OrderBy(i => Math.Abs(Agents[i].Dx)).ThenBy(i => i).ToList();
        return 0.28 + 0.07 * order.IndexOf(index);
    }

    /// <summary>The order in which the manager sends work down the lines, 0.45 s apart from 2 s.</summary>
    public static readonly IReadOnlyList<int> Turns = [2, 4, 0, 5, 1, 3];

    public static double Sent(int index) => 2.0 + 0.45 * Turns.ToList().IndexOf(index);

    /// <summary>When the manager and an agent arrive, and when each makes its one move.</summary>
    public static (double Arrives, double Moves, Move Move) Times(int? agent) =>
        agent is { } i ? (Grows(i) + 0.34, Sent(i) + 0.72, Agents[i].Move) : (0, 1.75, Move.Breathe);

    /// <summary>The moment after which nothing moves.</summary>
    public static double Ends => Enumerable.Range(0, Agents.Count).Select(i => Sent(i) + 0.72 + 1.15).Append(Sent(Turns[^1]) + 0.8).Max();

    public readonly record struct Pose(double Scale, double Opacity, double Angle);

    /// <summary>A mark at a moment: it arrives (scale 0.5 to 1 with its opacity, 0.8 s), then makes its one move. A
    /// breath goes to 1.14 at 45 % of one second, and back. A quarter turn (sparkle, clover) or a sixth (flower) ends where
    /// the shape looks as it began, and then stands at 0° again, so the last value is the mark that never turned. A rock
    /// goes 9° to each side and back, in 1.1 s. Only the outline turns; the dot stays where it looks.</summary>
    public static Pose PoseAt(int? agent, double t)
    {
        var (arrives, moves, move) = Times(agent);
        double scale = t < arrives ? 0.5 : Curves.Between(t, arrives, 0.8, 0.5, 1, Curves.Arrive);
        double opacity = t < arrives ? 0 : Curves.Between(t, arrives, 0.8, 0, 1, Curves.Arrive);
        double angle = 0;
        if (t >= moves)
        {
            double m = t - moves;
            switch (move)
            {
                case Move.Breathe:
                    scale = m < 0.45 ? Curves.Between(m, 0, 0.45, 1, 1.14, Curves.EaseInOut) : Curves.Between(m, 0.45, 0.55, 1.14, 1, Curves.EaseInOut);
                    break;
                case Move.QuarterTurn or Move.SixthTurn:
                    double full = move == Move.QuarterTurn ? 90 : 60;
                    angle = m < 1.1 ? Curves.Between(m, 0, 1.1, 0, full, Curves.Turn) : 0;
                    break;
                case Move.Rock:
                    angle = m < 0.33 ? Curves.Between(m, 0, 0.33, 0, -9, Curves.EaseInOut)
                          : m < 0.77 ? Curves.Between(m, 0.33, 0.44, -9, 9, Curves.EaseInOut)
                          : Curves.Between(m, 0.77, 0.33, 9, 0, Curves.EaseInOut);
                    break;
            }
        }
        return new Pose(scale, opacity, angle);
    }

    /// <summary>How much of a line is drawn: none until it grows, then all of it in 0.6 s.</summary>
    public static double Grown(int index, double t) => Curves.Between(t, Grows(index), 0.6, 0, 1, Curves.Draw);

    /// <summary>The small white dot down a line: how far it went (a part of the line's length), and its opacity. It shows
    /// only while it travels.</summary>
    public static (double Along, double Opacity) Dot(int index, double t)
    {
        double sent = Sent(index);
        double along = t < sent ? 0 : Curves.Between(t, sent, 0.8, 0, 1, Curves.Travel);
        double opacity = t < sent ? 0
            : t < sent + 0.096 ? Curves.Between(t, sent, 0.096, 0, 0.9, Curves.Linear)
            : t < sent + 0.68 ? 0.9
            : Curves.Between(t, sent + 0.68, 0.12, 0.9, 0, Curves.Linear);
        return (along, opacity);
    }

    /// <summary>The title and the cards come at 0.9 s, in half a second.</summary>
    public static double Words(double t) => Curves.Between(t, 0.9, 0.5, 0, 1, Curves.EaseOut);
}

/// <summary>Timing curves as SwiftUI's <c>UnitCurve.bezier</c> and CSS's <c>cubic-bezier</c>: the progress at a share of
/// the time.</summary>
internal static class Curves
{
    public static Func<double, double> Bezier(double x1, double y1, double x2, double y2) => x =>
    {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        double low = 0, high = 1, t = x;
        for (int i = 0; i < 40; i++)
        {
            t = (low + high) / 2;
            double at = Cubic(t, x1, x2);
            if (Math.Abs(at - x) < 1e-7) break;
            if (at < x) low = t; else high = t;
        }
        return Cubic(t, y1, y2);
    };

    private static double Cubic(double t, double p1, double p2)
    {
        double u = 1 - t;
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t;
    }

    public static readonly Func<double, double> Linear = x => Math.Clamp(x, 0, 1);
    /// <summary>SwiftUI's <c>easeInOut</c> and <c>easeOut</c>.</summary>
    public static readonly Func<double, double> EaseInOut = Bezier(0.42, 0, 0.58, 1);
    public static readonly Func<double, double> EaseOut = Bezier(0, 0, 0.58, 1);
    /// <summary>The mock's curves (<c>TeamPlan.arrive</c>, <c>draw</c>, <c>travel</c>, <c>turn</c>), and the marks' look
    /// toward the card under the pointer (<c>SetupMetrics.lookCurve</c>).</summary>
    public static readonly Func<double, double> Arrive = Bezier(0.16, 1, 0.3, 1);
    public static readonly Func<double, double> Draw = Bezier(0.3, 0.7, 0.2, 1);
    public static readonly Func<double, double> Travel = Bezier(0.4, 0, 0.2, 1);
    public static readonly Func<double, double> Turn = Bezier(0.3, 0, 0.2, 1);
    public static readonly Func<double, double> Look = Bezier(0.2, 0.8, 0.2, 1);

    /// <summary>The value of a stretch of a timeline: <paramref name="from"/> until <paramref name="start"/>, then along
    /// the curve to <paramref name="to"/> in <paramref name="seconds"/>.</summary>
    public static double Between(double now, double start, double seconds, double from, double to, Func<double, double> curve) =>
        now <= start ? from : now >= start + seconds ? to : from + (to - from) * curve((now - start) / seconds);
}
