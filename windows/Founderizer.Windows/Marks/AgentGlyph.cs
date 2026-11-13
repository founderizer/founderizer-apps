using System;
using System.Numerics;
using Founderizer.Core;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Founderizer.Windows.Marks;

/// <summary>An agent's glyph as the library's <see cref="MarkLook"/> says: FleetMark's outline in its gradient from the
/// top left to the bottom right and its inner mark (GlyphPaths, a square of 100 scaled to the side), grey for an agent
/// that is not there, a dashed outline in setup. While <see cref="MarkLook.Moves"/>, it moves by the library's moves
/// (GlyphLook.Moves: turn, breathe or rock, at the look's own pace), as the Mac and the iPhone run them. The compositor
/// runs the motion, so the app does no work for a frame; nothing moves at rest, and nothing moves where Windows'
/// animation effects are off.</summary>
public sealed class AgentGlyph : Grid
{
    public static readonly DependencyProperty MarkProperty = DependencyProperty.Register(
        nameof(Mark), typeof(MarkLook), typeof(AgentGlyph), new PropertyMetadata(null, (d, e) => ((AgentGlyph)d).MarkChanged((MarkLook?)e.OldValue)));
    public static readonly DependencyProperty SideProperty = DependencyProperty.Register(
        nameof(Side), typeof(double), typeof(AgentGlyph), new PropertyMetadata(28.0, (d, _) => ((AgentGlyph)d).Build()));

    public MarkLook? Mark { get => (MarkLook?)GetValue(MarkProperty); set => SetValue(MarkProperty, value); }
    public double Side { get => (double)GetValue(SideProperty); set => SetValue(SideProperty, value); }

    private static readonly TimeSpan Tween = TimeSpan.FromSeconds(GlyphMove.Tween);
    private static readonly UISettings Settings = new();

    private Grid? figure, orbit, core;
    private bool moving;
    private long generation;

    public AgentGlyph()
    {
        IsHitTestVisible = false;
        Loaded += (_, _) => { Settings.AnimationsEnabledChanged += AnimationsChanged; Update(); };
        Unloaded += (_, _) => { Settings.AnimationsEnabledChanged -= AnimationsChanged; Stop(eased: false); };
    }

    /// <summary>A new look draws again; a look that only starts or stops moving keeps its drawing.</summary>
    private void MarkChanged(MarkLook? old)
    {
        var mark = Mark;
        if (old is not null && mark is not null && old with { Moves = mark.Moves } == mark && figure is not null) Update();
        else Build();
    }

    private bool ShouldMove => Mark is { Moves: true, Dashed: false } && IsLoaded && Settings.AnimationsEnabled;

    /// <summary>Windows' animation effects were turned on or off: the motion follows at once.</summary>
    private void AnimationsChanged(UISettings sender, UISettingsAnimationsEnabledChangedEventArgs args) =>
        DispatcherQueue?.TryEnqueue(Update);

    private void Build()
    {
        Stop(eased: false);
        Children.Clear();
        figure = orbit = core = null;
        double s = Side;
        Width = Height = s;
        if (Mark is not { } mark || s <= 0) return;

        figure = Square(s);
        orbit = Square(s);
        core = Square(s);
        if (mark.Dashed)
        {
            // In setup: the outline alone, dashed, in the muted grey, inset so that its line stays inside the square.
            var (width, dash, gap, inset) = MarkLook.Dash(s);
            var inner = s - 2 * inset;
            figure.Children.Add(new Path
            {
                Data = Geometry(GlyphPaths.Outline(mark.Kind), new CompositeTransform
                {
                    ScaleX = inner / 100, ScaleY = inner / 100, TranslateX = inset, TranslateY = inset,
                }),
                Stroke = new SolidColorBrush(Color.FromArgb(255, 0x99, 0x99, 0x99)),
                StrokeThickness = width,
                StrokeDashArray = new DoubleCollection { dash / width, gap / width },
            });
        }
        else
        {
            var gradient = new LinearGradientBrush
            {
                MappingMode = BrushMappingMode.Absolute,
                StartPoint = new global::Windows.Foundation.Point(0, 0),
                EndPoint = new global::Windows.Foundation.Point(s, s),
            };
            gradient.GradientStops.Add(new GradientStop { Color = ToColor(mark.Light, 1), Offset = 0 });
            gradient.GradientStops.Add(new GradientStop { Color = ToColor(mark.Deep, 1), Offset = 1 });
            figure.Children.Add(new Path { Data = Geometry(GlyphPaths.Outline(mark.Kind), Scaled(s)), Fill = gradient });
            core.Children.Add(new Path
            {
                Data = Geometry(GlyphPaths.Core(mark.Kind), Scaled(s)),
                Fill = new SolidColorBrush(ToColor(mark.CoreFill, mark.CoreOpacity)),
            });
            orbit.Children.Add(core);
            figure.Children.Add(orbit);
        }
        Children.Add(figure);
        Update();
    }

    private void Update()
    {
        if (ShouldMove && !moving) Move();
        else if (!ShouldMove && moving) Stop(eased: true);
    }

    /// <summary>The library's moves of this look, from the glyph at rest: a turn starts at 0, a swing at its rest end,
    /// or after a tween from rest when rest is in its middle.</summary>
    private void Move()
    {
        if (figure is null || orbit is null || core is null || Mark is not { } mark) return;
        moving = true;
        long mine = ++generation;
        double s = Side;
        var (ax, ay) = GlyphLook.CoreAnchor(mark.Kind);
        foreach (var move in mark.Look.Moves())
        {
            var (element, x, y) = move.Part switch
            {
                GlyphPart.Figure => (figure, s / 2, s / 2),
                GlyphPart.Orbit => (orbit, s / 2, s / 2),
                _ => (core, ax * s, ay * s),
            };
            var visual = ElementCompositionPreview.GetElementVisual(element);
            visual.CenterPoint = new Vector3((float)x, (float)y, 0);
            Run(visual, move, mine);
        }
    }

    private void Run(Visual visual, GlyphMove move, long mine)
    {
        var c = visual.Compositor;
        bool size = move.Property == GlyphProperty.Scale;
        string property = size ? "Scale" : "RotationAngleInDegrees";
        // The library gives a turn in radians; the compositor turns in degrees.
        float Value(double v) => (float)(size ? v : v * 180 / Math.PI);
        KeyFrameAnimation Frames(double from, double to, CompositionEasingFunction ease)
        {
            if (size)
            {
                var a = c.CreateVector3KeyFrameAnimation();
                a.InsertKeyFrame(0, new Vector3(Value(from), Value(from), 1));
                a.InsertKeyFrame(1, new Vector3(Value(to), Value(to), 1), ease);
                return a;
            }
            var b = c.CreateScalarKeyFrameAnimation();
            b.InsertKeyFrame(0, Value(from));
            b.InsertKeyFrame(1, Value(to), ease);
            return b;
        }
        var linear = c.CreateLinearEasingFunction();
        var inOut = c.CreateCubicBezierEasingFunction(new Vector2(0.42f, 0), new Vector2(0.58f, 1));
        var loop = Frames(move.From, move.To, move.Turns ? linear : inOut);
        loop.Duration = TimeSpan.FromSeconds(move.Seconds);
        loop.IterationBehavior = AnimationIterationBehavior.Forever;
        if (!move.Turns) loop.Direction = AnimationDirection.Alternate;
        if (move.Turns || move.Rest == move.From)
        {
            visual.StartAnimation(property, loop);
            return;
        }
        var tween = Frames(move.Rest, move.From, inOut);
        tween.Duration = Tween;
        var batch = c.CreateScopedBatch(CompositionBatchTypes.Animation);
        visual.StartAnimation(property, tween);
        batch.End();
        batch.Completed += (_, _) => DispatcherQueue.TryEnqueue(() =>
        {
            if (moving && generation == mine) visual.StartAnimation(property, loop);
        });
    }

    /// <summary>Work ends on the glyph at rest, not with a snap: each part goes back from where it shows now to rest,
    /// easing out (GlyphMove.Tween).</summary>
    private void Stop(bool eased)
    {
        if (!moving) return;
        moving = false;
        generation++;
        foreach (var element in new UIElement?[] { figure, orbit, core })
        {
            if (element is null) continue;
            var visual = ElementCompositionPreview.GetElementVisual(element);
            visual.StopAnimation("RotationAngleInDegrees");
            visual.StopAnimation("Scale");
            if (!eased)
            {
                visual.RotationAngleInDegrees = 0;
                visual.Scale = Vector3.One;
                continue;
            }
            var c = visual.Compositor;
            var easeOut = c.CreateCubicBezierEasingFunction(new Vector2(0, 0), new Vector2(0.58f, 1));
            var turn = c.CreateScalarKeyFrameAnimation();
            turn.InsertExpressionKeyFrame(0, "this.StartingValue");
            turn.InsertKeyFrame(1, 0, easeOut);
            turn.Duration = Tween;
            visual.StartAnimation("RotationAngleInDegrees", turn);
            var grow = c.CreateVector3KeyFrameAnimation();
            grow.InsertExpressionKeyFrame(0, "this.StartingValue");
            grow.InsertKeyFrame(1, Vector3.One, easeOut);
            grow.Duration = Tween;
            visual.StartAnimation("Scale", grow);
        }
    }

    private static Grid Square(double s) => new() { Width = s, Height = s };

    private static ScaleTransform Scaled(double s) => new() { ScaleX = s / 100, ScaleY = s / 100 };

    /// <summary>Path data as a geometry, with SVG's nonzero fill ("F1"; XAML's default is even-odd) and a transform.</summary>
    private static Geometry Geometry(string data, Transform transform)
    {
        var geometry = (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), "F1 " + data);
        geometry.Transform = transform;
        return geometry;
    }

    public static Color ToColor(Rgb rgb, double opacity) => Color.FromArgb(
        (byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255), Byte(rgb.Red), Byte(rgb.Green), Byte(rgb.Blue));

    private static byte Byte(double part) => (byte)Math.Round(Math.Clamp(part, 0, 1) * 255);
}
