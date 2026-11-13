using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace Founderizer.Core;

/// <summary>The silhouette of an agent's glyph (FleetMark's GlyphKind), in FleetMark's order, which the hash indexes.</summary>
public enum GlyphKind { Sparkle, Clover, Flower, Burst, Squircle, Hexagon, Diamond, Triangle, Circle, Moon, Drop }

/// <summary>How a glyph moves while its agent works: a slow turn, a slow breath, or a small rock from side to side.</summary>
public enum GlyphMotion { Turn, Breathe, Rock }

/// <summary>A colour in sRGB, each part from 0 to 1.</summary>
public readonly record struct Rgb(double Red, double Green, double Blue)
{
    /// <summary>The colour as #RRGGBB.</summary>
    public string Hex => $"#{Byte(Red):X2}{Byte(Green):X2}{Byte(Blue):X2}";
    public static Rgb Grey(double white) => new(white, white, white);
    private static int Byte(double part) => (int)Math.Round(Math.Clamp(part, 0, 1) * 255);
}

/// <summary>An agent's own mark: a shape and a colour that come from its name and from its place in the hub's list of
/// agents, so one agent looks the same on every page and in every app (FleetMark's GlyphLook, rule for rule; the vectors
/// of app/vectors/agent-marks.json come from FleetMark itself).</summary>
public sealed record GlyphLook
{
    public GlyphKind Kind { get; }
    /// <summary>The place of its colour in the list of hues.</summary>
    public int Tone { get; }
    /// <summary>The lighter step: the gradient's top left.</summary>
    public Rgb Light { get; }
    /// <summary>The deeper step: the gradient's bottom right.</summary>
    public Rgb Deep { get; }
    /// <summary>A start time of its own in seconds, so that two glyphs do not move as one.</summary>
    public double Phase { get; }

    /// <summary>How much white the inner mark puts on the glyph (the moon's inner mark is its light colour).</summary>
    public const double CoreOpacity = 0.38;

    /// <summary>Nine hues, each as a lighter and a deeper step: coral, amber, lime, mint, sky, blue, sand, orchid, rose.</summary>
    private static readonly (Rgb Light, Rgb Deep)[] Tones =
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
    public static int ToneCount => Tones.Length;
    private static readonly int KindCount = Enum.GetValues<GlyphKind>().Length;

    /// <summary>The look of a name. <paramref name="attempt"/> 0 is its first look; each next number is its next look,
    /// for a team where an earlier agent has the same shape or colour.</summary>
    public GlyphLook(string name, int attempt = 0)
    {
        // FNV-1a over "fleet-glyph-13675:" + the name in lower case (+ "#attempt"), as FleetMark hashes it.
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes("fleet-glyph-13675:" + name.ToLowerInvariant() +
                                                 (attempt == 0 ? "" : "#" + attempt)))
            hash = unchecked((hash ^ b) * 0x100000001b3UL);
        Kind = (GlyphKind)(int)(hash % (ulong)KindCount);
        Tone = (int)((hash >> 20) % (ulong)Tones.Length);
        Light = Tones[Tone].Light;
        Deep = Tones[Tone].Deep;
        Phase = (hash % 6283) / 1000.0;
    }

    /// <summary>The looks of a team, in the hub's order of its agents (GlyphLook.team): the first agent keeps the first
    /// look of its name, and a later one takes the next look of its name while an earlier agent has its shape or its
    /// colour, so a new agent at the end of the list changes no other agent.</summary>
    public static IReadOnlyDictionary<string, GlyphLook> Team(IEnumerable<string> names)
    {
        var looks = new Dictionary<string, GlyphLook>();
        var kinds = new HashSet<GlyphKind>();
        var hues = new HashSet<int>();
        foreach (var name in names)
        {
            if (looks.ContainsKey(name)) continue;
            if (kinds.Count == KindCount) kinds.Clear();
            if (hues.Count == Tones.Length) hues.Clear();
            GlyphLook? found = null;
            for (var attempt = 0; attempt < 200 && found is null; attempt++)
            {
                var look = new GlyphLook(name, attempt);
                if (!kinds.Contains(look.Kind) && !hues.Contains(look.Tone)) found = look;
            }
            found ??= new GlyphLook(name);
            looks[name] = found;
            kinds.Add(found.Kind);
            hues.Add(found.Tone);
        }
        return looks;
    }

    /// <summary>How this kind moves while its agent works.</summary>
    public GlyphMotion Motion => MotionOf(Kind);

    public static GlyphMotion MotionOf(GlyphKind kind) => kind switch
    {
        GlyphKind.Sparkle or GlyphKind.Clover or GlyphKind.Flower or GlyphKind.Burst => GlyphMotion.Turn,
        GlyphKind.Squircle or GlyphKind.Hexagon or GlyphKind.Circle or GlyphKind.Drop => GlyphMotion.Breathe,
        _ => GlyphMotion.Rock,
    };

    /// <summary>The centre of the inner mark in a unit square, for a mark that changes its size in place.</summary>
    public static (double X, double Y) CoreAnchor(GlyphKind kind) => kind switch
    {
        GlyphKind.Moon => (0.71, 0.32),
        GlyphKind.Drop => (0.39, 0.68),
        GlyphKind.Triangle => (0.5, 0.57),
        _ => (0.5, 0.5),
    };

    /// <summary>The kind's name as FleetMark writes it ("sparkle").</summary>
    public static string Name(GlyphKind kind) => kind.ToString().ToLowerInvariant();

    /// <summary>The motion of this look while its agent works, as the Mac and the iPhone run it
    /// (ios/Sources/AgentMark.swift, BreathingLayer.breathe): each part's moves, each at the look's own pace, within 10%
    /// of the kind's (0.9 + 0.2 × phase / 2π). A swing goes from <see cref="GlyphMove.From"/> to
    /// <see cref="GlyphMove.To"/> and back for ever, easing in and out; a turn goes on at an even speed; a swing whose
    /// rest is in its middle first reaches its start in <see cref="GlyphMove.Tween"/> seconds. Work ends on the mark at
    /// rest: each part goes back to rest in <see cref="GlyphMove.Tween"/> seconds, easing out.</summary>
    public IReadOnlyList<GlyphMove> Moves()
    {
        var pace = 0.9 + 0.2 * Phase / (2 * Math.PI);
        const double whole = 2 * Math.PI;
        return Motion switch
        {
            GlyphMotion.Turn =>
            [
                GlyphMove.Turn(GlyphPart.Figure, whole, 6 * pace),
                GlyphMove.Swing(GlyphPart.Figure, GlyphProperty.Scale, 0.86, 1, 1, 0.95 * pace),
                GlyphMove.Turn(GlyphPart.Orbit, -whole, 3 * pace),
                GlyphMove.Swing(GlyphPart.Core, GlyphProperty.Scale, 0.75, 1.25, 1, 0.8 * pace),
            ],
            GlyphMotion.Breathe => Kind == GlyphKind.Drop
                ? [GlyphMove.Swing(GlyphPart.Figure, GlyphProperty.Scale, 0.8, 1, 1, 0.85 * pace),
                   GlyphMove.Swing(GlyphPart.Core, GlyphProperty.Scale, 0.6, 1.4, 1, 0.7 * pace)]
                : [GlyphMove.Swing(GlyphPart.Figure, GlyphProperty.Scale, 0.8, 1, 1, 0.85 * pace),
                   GlyphMove.Turn(GlyphPart.Orbit, whole, 2.2 * pace)],
            _ =>
            [
                GlyphMove.Swing(GlyphPart.Figure, GlyphProperty.Rotation, -0.3, 0.3, 0, 0.95 * pace),
                GlyphMove.Swing(GlyphPart.Figure, GlyphProperty.Scale, 0.88, 1, 1, 0.95 * pace),
                GlyphMove.Swing(GlyphPart.Core, GlyphProperty.Scale, 0.7, 1.3, 1, 0.7 * pace),
            ],
        };
    }
}

/// <summary>The parts of a moving mark: the whole figure, the inner mark, and the orbit, a layer that holds the inner
/// mark and turns about the figure's centre.</summary>
public enum GlyphPart { Figure, Orbit, Core }

/// <summary>What a move changes: the turn about the centre (radians) or the size (a factor).</summary>
public enum GlyphProperty { Rotation, Scale }

/// <summary>One move of a moving mark.</summary>
public sealed record GlyphMove(GlyphPart Part, GlyphProperty Property, double From, double To, double Rest,
                               double Seconds, bool Turns)
{
    /// <summary>The seconds of the way from rest to a swing's start, and back to rest when work ends.</summary>
    public const double Tween = 0.25;

    /// <summary>A turn without an end, from 0 to <paramref name="angle"/> radians, at an even speed.</summary>
    public static GlyphMove Turn(GlyphPart part, double angle, double seconds) =>
        new(part, GlyphProperty.Rotation, 0, angle, 0, seconds, true);

    /// <summary>A swing between two values without an end. Where rest is one end, it starts there; otherwise it starts
    /// at the far end of the two after a tween from rest.</summary>
    public static GlyphMove Swing(GlyphPart part, GlyphProperty property, double low, double high, double rest,
                                  double seconds)
    {
        var start = rest == low ? low : high;
        return new GlyphMove(part, property, start, start == low ? high : low, rest, seconds, false);
    }
}

/// <summary>How a mark is drawn in each state of its agent (the Mac's AgentGlyph and the iPhone's AgentMark): its own
/// colours while it answers, grey drawn whole while it is offline or not known, and a dashed outline in the muted grey
/// while it is in setup. It moves only while its agent works, and only where it stands for the agent itself (a pane row,
/// the pill over its chat, the "Thinking" of its chat, its panel), never where a list names it.</summary>
public sealed record MarkLook
{
    public GlyphLook Look { get; init; } = null!;
    public GlyphKind Kind => Look.Kind;
    /// <summary>The gradient's two colours, top left to bottom right: the look's, or the grey of an agent that is not
    /// there.</summary>
    public Rgb Light { get; init; }
    public Rgb Deep { get; init; }
    /// <summary>The inner mark's fill: white at <see cref="GlyphLook.CoreOpacity"/>, or the light colour for a moon.</summary>
    public Rgb CoreFill { get; init; }
    public double CoreOpacity { get; init; }
    /// <summary>In setup: only the outline, dashed, in the muted grey (see <see cref="Dash"/>).</summary>
    public bool Dashed { get; init; }
    /// <summary>It moves now: its agent works, and the place lets it move.</summary>
    public bool Moves { get; init; }

    /// <summary>The grey of an agent that is not there (AgentMark.absentLight and absentDeep).</summary>
    public static readonly Rgb AbsentLight = Rgb.Grey(0.62);
    public static readonly Rgb AbsentDeep = Rgb.Grey(0.42);

    /// <summary>The dashed outline of a mark of <paramref name="size"/> in setup: its line width, its dash and gap, and the
    /// inset of the outline (AgentMark.figure).</summary>
    public static (double Width, double Dash, double Gap, double Inset) Dash(double size) =>
        (Math.Max(1.2, size * 0.06), size * 0.13, size * 0.11, size * 0.05);

    /// <summary>The mark of an agent in a state. <paramref name="moves"/>: the place stands for the agent itself, and the
    /// owner's system does not ask for less motion.</summary>
    public static MarkLook Of(GlyphLook look, AgentState state, bool moves = true)
    {
        var absent = state is AgentState.Offline or AgentState.Unknown;
        var light = absent ? AbsentLight : look.Light;
        var deep = absent ? AbsentDeep : look.Deep;
        return new MarkLook
        {
            Look = look,
            Light = light,
            Deep = deep,
            CoreFill = look.Kind == GlyphKind.Moon ? light : Rgb.Grey(1),
            CoreOpacity = look.Kind == GlyphKind.Moon ? 1 : GlyphLook.CoreOpacity,
            Dashed = state == AgentState.Setup,
            Moves = moves && state == AgentState.Working,
        };
    }
}

/// <summary>The outline and the inner mark of each kind as SVG path data in a square of 100 (y down), as FleetMark draws
/// them. They are read from app/vectors/agent-marks.json, which FleetMark itself writes (MarkVectorsTests), and which the
/// library carries: the clover, the flower and the moon are unions and differences of circles, which only that code
/// computes. Scale them to the size of the mark.</summary>
public static class GlyphPaths
{
    private static readonly Lazy<Dictionary<GlyphKind, (string Outline, string Core)>> Table = new(Load);

    public static string Outline(GlyphKind kind) => Table.Value[kind].Outline;
    public static string Core(GlyphKind kind) => Table.Value[kind].Core;

    private static Dictionary<GlyphKind, (string, string)> Load()
    {
        using var stream = typeof(GlyphPaths).Assembly.GetManifestResourceStream("agent-marks.json")
                           ?? throw new InvalidOperationException("the library carries no agent-marks.json");
        using var document = JsonDocument.Parse(stream);
        var table = new Dictionary<GlyphKind, (string, string)>();
        foreach (var shape in document.RootElement.GetProperty("shapes").EnumerateArray())
        {
            var kind = Enum.Parse<GlyphKind>(shape.GetProperty("kind").GetString()!, ignoreCase: true);
            table[kind] = (shape.GetProperty("outline").GetString()!, shape.GetProperty("core").GetString()!);
        }
        if (table.Count != Enum.GetValues<GlyphKind>().Length)
            throw new InvalidDataException("agent-marks.json does not hold every kind");
        return table;
    }
}
