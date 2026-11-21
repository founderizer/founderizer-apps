using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;
using Founderizer.Setup.FirstRun;
using Founderizer.Windows.Marks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**The welcome page** (set 8, picture 1; the Mac's <c>WelcomePage</c> with its first way alone, as on a Mac
/// with neither Claude Code nor Codex; plan section 7, 2.1): the team with its one sequence (<see cref="WelcomePlan"/>),
/// the title at 30, the card "Set it up yourself", and W8, the quiet link "Add this PC" for an owner who has a Mac (his
/// yes of 20 November 2026). Over the card, the marks' dots look a little toward it. The page fits its window with no
/// scroll: in a shorter or a narrower one the team, its lines and the two gaps take one smaller scale.</summary>
internal sealed class WelcomePage : IStepView
{
    private const double TeamGap = 48, TitleGap = 32, LeastScale = 0.4;
    private static readonly double WayWidth = (StepLook.CardsWidth - 14) / 2;

    private readonly StepHost host;
    private readonly StackPanel column = new() { Width = StepLook.WelcomeWidth, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Grid teamRoom = new() { HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Canvas team = new();
    private readonly StackPanel words = new();
    private readonly TextBlock title = StepLook.Words("", size: 30, line: 36, semibold: true);
    private readonly Button way;
    private readonly Button addThisPc;
    private readonly List<Path> lines = new();
    private readonly List<Ellipse> workDots = new();
    private readonly List<WelcomeMark> marks = new();
    private readonly List<(Point[] Points, double[] Lengths)> samples = new();
    private readonly Frames sequence;
    private readonly Frames looking;
    private double scale = 1, eyes, eyesFrom, eyesTo;
    private bool played;

    public WelcomePage(StepHost host)
    {
        this.host = host;
        title.FontFamily = Look.Display;
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);

        // The team, its lines under the marks, and the small dots that travel down the lines.
        team.Width = WelcomePlan.Width;
        team.Height = WelcomePlan.Height;
        foreach (var agent in WelcomePlan.Agents)
        {
            var (from, c1, c2, to) = WelcomePlan.Line(agent);
            samples.Add(Sample(from, c1, c2, to));
            var line = new Path
            {
                Stroke = Look.Brush(Look.White(0.22)),
                StrokeThickness = 1.5,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
            };
            lines.Add(line);
            team.Children.Add(line);
        }
        foreach (var _ in WelcomePlan.Agents)
        {
            var dot = new Ellipse { Width = 5, Height = 5, Fill = Look.Brush(Color.FromArgb(255, 255, 255, 255)), Opacity = 0 };
            workDots.Add(dot);
            team.Children.Add(dot);
        }
        var manager = new WelcomeMark(WelcomePlan.ManagerKind, WelcomePlan.ManagerTone, WelcomePlan.ManagerSize, manager: true, turns: false);
        Place(manager, WelcomePlan.ManagerAt);
        marks.Add(manager);
        team.Children.Add(manager);
        foreach (var agent in WelcomePlan.Agents)
        {
            var mark = new WelcomeMark(agent.Kind, agent.Tone, WelcomePlan.AgentSize, manager: false, turns: agent.Move != WelcomePlan.Move.Breathe);
            Place(mark, WelcomePlan.At(agent));
            marks.Add(mark);
            team.Children.Add(mark);
        }
        teamRoom.Children.Add(team);
        AutomationProperties.SetAccessibilityView(teamRoom, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        column.Children.Add(teamRoom);

        // The title, the one way, and W8 under it.
        var tile = new Border
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(9),
            Background = Look.SurfaceBrush,
            BorderBrush = Look.Brush(StepLook.TileEdge),
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 0, 0, 14),
            Child = StepMarks.Chevrons(18, Look.Brush(Look.Rgb(0xD0, 0xD0, 0xD0))),
        };
        var wayWords = new StackPanel { Padding = new Thickness(18) };
        wayWords.Children.Add(tile);
        wayWords.Children.Add(Look.Words(SetupScreens.SetItUp, StepLook.Text, 20, semibold: true));
        wayWords.Children.Add(Look.Words(SetupScreens.StepByStep, StepLook.Text, 20, Look.Muted));
        way = StepControls.Card(wayWords, SetupScreens.SetItUp, "first-run-set-up", minHeight: 104);
        way.Width = WayWidth;
        way.HorizontalAlignment = HorizontalAlignment.Center;
        way.Click += (_, _) => host.Store.SetUp();
        way.PointerEntered += (_, _) => LookAt(0.06);
        way.PointerExited += (_, _) => LookAt(0);
        addThisPc = StepControls.Link(SetupScreens.AddThisPc, "first-run-add-this-pc");
        addThisPc.Margin = new Thickness(0, 22 - 2, 0, 0);
        addThisPc.Click += (_, _) => host.AddThisPc();
        words.Children.Add(title);
        words.Children.Add(way);
        words.Children.Add(addThisPc);
        column.Children.Add(words);

        sequence = new Frames(now =>
        {
            Draw(now);
            return now < WelcomePlan.Ends;
        });
        looking = new Frames(now =>
        {
            double t = Math.Min(1, now / 0.28);
            eyes = eyesFrom + (eyesTo - eyesFrom) * Curves.Look(t);
            foreach (var mark in marks) mark.Eyes(eyes);
            return t < 1;
        });
        column.Loaded += (_, _) =>
        {
            Fit();
            if (root is null && column.XamlRoot is { } shown)
            {
                root = shown;
                root.Changed += RootChanged;
            }
        };
        column.Unloaded += (_, _) =>
        {
            if (root is not null) root.Changed -= RootChanged;
            root = null;
        };
        column.SizeChanged += (_, _) => Fit();
        Draw(WelcomePlan.Ends);
    }

    public FrameworkElement View => column;

    /// <summary>The window's root while the page shows: its size changes fit the page again.</summary>
    private XamlRoot? root;

    private void RootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => Fit();

    public void Show(SetupState state, SetupScreen screen)
    {
        title.Text = screen.Title;
        if (played) return;
        played = true;
        // A page that plays starts empty, and plays once when it shows; with Windows' animation effects off it is the
        // settled page from its first frame.
        if (host.ReduceMotion()) Draw(WelcomePlan.Ends);
        else
        {
            Draw(0);
            sequence.Start();
        }
    }

    public void Left()
    {
        sequence.Stop();
        looking.Stop();
    }

    /// <summary>The marks' dots look toward the card under the pointer (6 % of a mark's size down: the one card stands
    /// straight under the team), and back; not where Windows' animation effects are off.</summary>
    private void LookAt(double to)
    {
        if (host.ReduceMotion()) return;
        eyesFrom = eyes;
        eyesTo = to;
        looking.Start();
    }

    /// <summary>One moment of the sequence.</summary>
    private void Draw(double t)
    {
        bool settled = t >= WelcomePlan.Ends;
        for (int i = 0; i < lines.Count; i++)
        {
            lines[i].Data = settled ? Whole(WelcomePlan.Line(WelcomePlan.Agents[i])) : Trimmed(samples[i], WelcomePlan.Grown(i, t));
            var (along, opacity) = WelcomePlan.Dot(i, t);
            workDots[i].Opacity = settled ? 0 : opacity;
            var at = PointAt(samples[i], along > 0 ? along : 1);
            Canvas.SetLeft(workDots[i], at.X - 2.5);
            Canvas.SetTop(workDots[i], at.Y - 2.5);
        }
        marks[0].Pose(WelcomePlan.PoseAt(null, t));
        for (int i = 0; i < WelcomePlan.Agents.Count; i++) marks[i + 1].Pose(WelcomePlan.PoseAt(i, t));
        words.Opacity = WelcomePlan.Words(t);
    }

    /// <summary>One scale for the team, its lines and the two gaps: 1 where the page fits as the mock has it; less in a
    /// column narrower than the team, and in a window too short for the page with no scroll; never under 0.4.</summary>
    private void Fit()
    {
        double next = 1;
        if (column.ActualWidth > 0) next = Math.Min(next, column.ActualWidth / WelcomePlan.Width);
        if (column.XamlRoot is { } window && window.Size.Height > 0)
        {
            words.Measure(new Size(column.ActualWidth > 0 ? column.ActualWidth : StepLook.WelcomeWidth, double.PositiveInfinity));
            // The page's room under the window's title bar, less the room that a step keeps over and under it.
            double free = window.Size.Height - 48 - 128 - words.DesiredSize.Height;
            next = Math.Min(next, free / (WelcomePlan.Height + TeamGap + TitleGap));
        }
        next = Math.Max(LeastScale, next);
        if (Math.Abs(next - scale) < 0.001 && teamRoom.Width > 0) return;
        scale = next;
        team.RenderTransform = new ScaleTransform { ScaleX = scale, ScaleY = scale };
        teamRoom.Width = WelcomePlan.Width * scale;
        teamRoom.Height = WelcomePlan.Height * scale;
        words.Margin = new Thickness(0, TeamGap * scale + Look.TitleNudge, 0, 0);
        way.Margin = new Thickness(0, TitleGap * scale - Look.TitleNudge, 0, 0);
    }

    private static void Place(FrameworkElement mark, (double X, double Y) at)
    {
        Canvas.SetLeft(mark, at.X - mark.Width / 2);
        Canvas.SetTop(mark, at.Y - mark.Height / 2);
    }

    // ------------------------------------------------------------------ the lines

    private static Geometry Whole(((double X, double Y) From, (double X, double Y) C1, (double X, double Y) C2, (double X, double Y) To) line)
    {
        var figure = new PathFigure { StartPoint = new Point(line.From.X, line.From.Y), IsFilled = false };
        figure.Segments.Add(new BezierSegment
        {
            Point1 = new Point(line.C1.X, line.C1.Y),
            Point2 = new Point(line.C2.X, line.C2.Y),
            Point3 = new Point(line.To.X, line.To.Y),
        });
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    /// <summary>The cubic as 96 points and the length up to each, so that a line grows and a dot travels by length, as
    /// SwiftUI's trimmed path does.</summary>
    private static (Point[] Points, double[] Lengths) Sample((double X, double Y) a, (double X, double Y) b, (double X, double Y) c, (double X, double Y) d)
    {
        const int count = 96;
        var points = new Point[count + 1];
        var lengths = new double[count + 1];
        for (int i = 0; i <= count; i++)
        {
            double t = (double)i / count, u = 1 - t;
            double x = u * u * u * a.X + 3 * u * u * t * b.X + 3 * u * t * t * c.X + t * t * t * d.X;
            double y = u * u * u * a.Y + 3 * u * u * t * b.Y + 3 * u * t * t * c.Y + t * t * t * d.Y;
            points[i] = new Point(x, y);
            if (i > 0) lengths[i] = lengths[i - 1] + Math.Sqrt(Math.Pow(x - points[i - 1].X, 2) + Math.Pow(y - points[i - 1].Y, 2));
        }
        return (points, lengths);
    }

    private static Point PointAt((Point[] Points, double[] Lengths) line, double part)
    {
        double want = Math.Clamp(part, 0, 1) * line.Lengths[^1];
        for (int i = 1; i < line.Points.Length; i++)
        {
            if (line.Lengths[i] < want) continue;
            double span = line.Lengths[i] - line.Lengths[i - 1];
            double share = span <= 0 ? 0 : (want - line.Lengths[i - 1]) / span;
            var p = line.Points[i - 1];
            var q = line.Points[i];
            return new Point(p.X + (q.X - p.X) * share, p.Y + (q.Y - p.Y) * share);
        }
        return line.Points[^1];
    }

    private static Geometry Trimmed((Point[] Points, double[] Lengths) line, double part)
    {
        var geometry = new PathGeometry();
        if (part <= 0) return geometry;
        var figure = new PathFigure { StartPoint = line.Points[0], IsFilled = false };
        var segment = new PolyLineSegment();
        double want = Math.Clamp(part, 0, 1) * line.Lengths[^1];
        for (int i = 1; i < line.Points.Length && line.Lengths[i - 1] < want; i++)
            segment.Points.Add(line.Lengths[i] <= want ? line.Points[i] : PointAt(line, part));
        figure.Segments.Add(segment);
        geometry.Figures.Add(figure);
        return geometry;
    }
}

/// <summary>**One mark of the welcome page** (the Mac's <c>WelcomeMark</c>): FleetMark's outline of its kind in its hue's
/// gradient from the top left to the bottom right, and the mock's dot in place of the inner mark, a white dot with a soft
/// ring. It is nobody's mark, and moves by the page's timeline only. Only the outline turns or rocks, inside a gradient
/// that stays fixed in the mark's square; the dot stays where it looks.</summary>
internal sealed class WelcomeMark : Grid
{
    private readonly Ellipse ring, dot;
    private readonly (double X, double Y) at;
    private readonly double side;
    private readonly ScaleTransform grow;
    private readonly RotateTransform turn;

    public WelcomeMark(GlyphKind kind, int tone, double side, bool manager, bool turns)
    {
        this.side = side;
        Width = Height = side;
        IsHitTestVisible = false;
        var (light, deep) = WelcomePlan.Tones[tone];
        var gradient = new LinearGradientBrush
        {
            MappingMode = BrushMappingMode.Absolute,
            StartPoint = new Point(0.08 * side, 0.08 * side),
            EndPoint = new Point(0.92 * side, 0.92 * side),
        };
        gradient.GradientStops.Add(new GradientStop { Color = AgentGlyph.ToColor(light, 1), Offset = 0 });
        gradient.GradientStops.Add(new GradientStop { Color = AgentGlyph.ToColor(deep, 1), Offset = 1 });
        // The outline turns inside the path's own square, so the gradient, which is the square's, stays where it is.
        var outline = (Geometry)Microsoft.UI.Xaml.Markup.XamlBindingHelper.ConvertValue(typeof(Geometry), "F1 " + GlyphPaths.Outline(kind));
        turn = new RotateTransform { CenterX = side / 2, CenterY = side / 2 };
        // A scale of exactly 1 on a path's geometry makes WinUI draw nothing (measured in the VM on 21 November 2026: the
        // manager's mark of 100 vanished, one of 99 drew): the outline of 100 takes no scale.
        var scaled = side == 100 ? null : new ScaleTransform { ScaleX = side / 100, ScaleY = side / 100 };
        outline.Transform = !turns ? scaled : scaled is null ? turn : new TransformGroup { Children = { scaled, turn } };
        Children.Add(new Path { Width = side, Height = side, Data = outline, Fill = gradient });
        var (dotAt, dotSide) = WelcomePlan.DotOf(manager);
        at = dotAt;
        ring = new Ellipse { Width = side * dotSide * 1.75, Height = side * dotSide * 1.75, Fill = Look.Brush(Look.White(0.20)) };
        dot = new Ellipse { Width = side * dotSide, Height = side * dotSide, Fill = Look.Brush(Look.White(0.94)) };
        var dots = new Canvas { Width = side, Height = side };
        dots.Children.Add(ring);
        dots.Children.Add(dot);
        Children.Add(dots);
        Eyes(0);
        grow = new ScaleTransform { CenterX = side / 2, CenterY = side / 2 };
        RenderTransform = grow;
    }

    /// <summary>The dot looks down by a part of the mark's size.</summary>
    public void Eyes(double down)
    {
        double x = side * at.X, y = side * (at.Y + down);
        Canvas.SetLeft(ring, x - ring.Width / 2);
        Canvas.SetTop(ring, y - ring.Height / 2);
        Canvas.SetLeft(dot, x - dot.Width / 2);
        Canvas.SetTop(dot, y - dot.Height / 2);
    }

    public void Pose(WelcomePlan.Pose pose)
    {
        grow.ScaleX = grow.ScaleY = pose.Scale;
        Opacity = pose.Opacity;
        turn.Angle = pose.Angle;
    }
}
