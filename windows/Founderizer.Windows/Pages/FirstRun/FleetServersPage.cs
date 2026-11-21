using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Founderizer.Windows.Marks;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using Windows.UI;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**"Your fleet's servers"** (set 8, picture 5; the Mac's <c>FleetServersPage</c>): a server on its tile, the
/// title and its line, the slider from "Lower cost" to "More secure", one card for the chosen step with its headline, a
/// box for each server with what runs on it (before a team exists: the hub, the manager and two agents to come) and the
/// step's risk in its quiet line, and Continue. It shows no price: it stands before the provider's token.</summary>
internal sealed class FleetServersPage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.CardsWidth);
    private readonly ServersSlider slider;
    private readonly TextBlock headline = StepLook.Words("", size: 17, line: 22, semibold: true);
    private readonly StackPanel boxes = new() { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock risk = StepLook.Words("", Look.Muted, 13, 19);
    private (ServersStep Step, string Manager)? drawn;

    public FleetServersPage(StepHost host)
    {
        this.host = host;
        column.Mark = StepLook.Tile(StepMarks.Server(22));
        column.Controls.Spacing = 16;
        slider = new ServersSlider(step => host.Store.MoveSlider(step), host.ReduceMotion) { Margin = new Thickness(0, 6, 0, 0) };
        column.Controls.Children.Add(slider);
        risk.MinHeight = 42;
        var card = new Border
        {
            Background = Look.SurfaceBrush,
            BorderBrush = Look.CardEdge,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(20, 20, 20, 12),
            Child = new StackPanel { Spacing = 16, Children = { headline, boxes, risk } },
        };
        column.Controls.Children.Add(card);
        var next = StepControls.Primary(SetupScreens.Continue, "first-run-servers-continue");
        next.Click += (_, _) => Enter();
        column.Controls.Children.Add(next);
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen screen)
    {
        column.Show(screen.Title, screen.Waits, screen.Detail, host.ReduceMotion());
        var ends = screen.Controls.Where(c => c.Kind == SetupControlKind.Muted).ToList();
        var steps = screen.Controls.Where(c => c.Kind == SetupControlKind.Card).Select(c => c.Words).ToList();
        slider.Show(ends[0].Words, ends[1].Words, steps, state.ServersStep);
        var fact = screen.Controls.First(c => c.Id == "first-run-servers-fact");
        headline.Text = fact.Words;
        risk.Text = fact.Line ?? "";
        var manager = ManagerName.Shown(state.ManagerName);
        if (drawn == (state.ServersStep, manager)) return;
        drawn = (state.ServersStep, manager);
        boxes.Children.Clear();
        var name = ManagerName.AgentName(state.ManagerName) ?? ManagerName.Fallback;
        foreach (var server in ServersSketch.Servers(state.ServersStep))
            boxes.Children.Add(Box(server, name, manager));
    }

    public bool Enter()
    {
        host.Store.ChooseServers();
        return true;
    }

    /// <summary>One server: "Server" over what runs on it, each a mark of 36 over its name in a column of 64.</summary>
    private static Border Box(IReadOnlyList<ServersSketch.Part> parts, string agentName, string shown)
    {
        var kind = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 5,
            HorizontalAlignment = HorizontalAlignment.Center,
            Children = { StepMarks.Server(12, Look.Muted), Look.Words(SetupViewWords.Server, 12, 16, Look.Muted, wrap: false) },
        };
        var tiles = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var part in parts)
        {
            FrameworkElement mark = part switch
            {
                ServersSketch.Part.Hub => ProductMark.Hub(36),
                ServersSketch.Part.Manager => StepLook.AgentMark(agentName, 36),
                _ => new Ellipse
                {
                    Width = 36,
                    Height = 36,
                    Stroke = Look.Brush(Look.White(0.32)),
                    StrokeThickness = 1.5,
                    StrokeDashArray = new DoubleCollection { 0.1 / 1.5, 5.2 / 1.5 },
                    StrokeDashCap = PenLineCap.Round,
                },
            };
            mark.HorizontalAlignment = HorizontalAlignment.Center;
            var words = part switch { ServersSketch.Part.Hub => SetupViewWords.Hub, ServersSketch.Part.Manager => shown, _ => SetupViewWords.Agent };
            var name = Look.Words(words, 13, 18, part == ServersSketch.Part.Next ? Look.Muted : Look.Text, semibold: true, wrap: false);
            name.HorizontalAlignment = HorizontalAlignment.Center;
            tiles.Children.Add(new StackPanel { Width = 64, Spacing = 7, Children = { mark, name } });
        }
        var box = new Border
        {
            Padding = new Thickness(10, 10, 10, 12),
            CornerRadius = new CornerRadius(6),
            Background = Look.Brush(Look.White(0.05)),
            BorderBrush = Look.Brush(Look.White(0.10)),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Top,
            Child = new StackPanel { Spacing = 10, Children = { kind, tiles } },
        };
        AutomationProperties.SetName(box, SetupViewWords.AServer);
        return box;
    }
}

/// <summary>**The slider of "Your fleet's servers"** (the Mac's <c>ServersSlider</c>, set 8's <c>.sld</c>): "Lower cost"
/// and "More secure" over its two ends, a dot for each step on a track of 6 filled up to the knob, the knob a raised
/// capsule of 46 by 28 with two chevrons, and each step's count under it, the chosen one larger and in the text's colour.
/// A press on the track or on a count slides the knob there and chooses that step; the knob follows a drag and settles on
/// the nearest step when he lets go; Left and Right move it one step. The track ends where the words under its two end
/// steps still stand inside the slider. The knob wears a ring only for the keyboard's focus.</summary>
internal sealed class ServersSlider : UserControl
{
    private readonly Grid root = new();
    private const double SliderHeight = 84, TrackY = 40, CountsY = 74, TrackHeight = 6, Dot = 10, KnobWidth = 46, KnobHeight = 28;

    private static readonly IReadOnlyList<ServersStep> Steps = ServersSteps.All;
    private readonly Action<ServersStep> choose;
    private readonly Func<bool> reduceMotion;
    private readonly Canvas canvas = new();
    private readonly TextBlock lower = Look.Words("", 12, 16, Look.Muted, semibold: true, wrap: false);
    private readonly TextBlock higher = Look.Words("", 12, 16, Look.Muted, semibold: true, wrap: false);
    private readonly Rectangle track = new() { Height = TrackHeight, RadiusX = 3, RadiusY = 3, Fill = Look.Brush(Look.White(0.10)) };
    private readonly Rectangle done = new() { Height = TrackHeight, RadiusX = 3, RadiusY = 3, Fill = Look.Brush(Look.White(0.34)) };
    private readonly List<Ellipse> dots = new();
    private readonly List<TextBlock> counts = new();
    private readonly Grid knob = new() { Width = KnobWidth, Height = KnobHeight };
    private readonly Border ring;
    private readonly Frames slide;
    private IReadOnlyList<string> words = [];
    private ServersStep step = ServersStep.Two;
    private double knobAt = double.NaN, slideFrom, slideTo;
    private double? held, grab;

    public ServersSlider(Action<ServersStep> choose, Func<bool> reduceMotion)
    {
        this.choose = choose;
        this.reduceMotion = reduceMotion;
        Height = SliderHeight;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        root.Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
        Content = root;
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
        lower.HorizontalAlignment = HorizontalAlignment.Left;
        higher.HorizontalAlignment = HorizontalAlignment.Right;
        root.Children.Add(lower);
        root.Children.Add(higher);
        root.Children.Add(canvas);
        canvas.Children.Add(track);
        canvas.Children.Add(done);

        var face = new Border
        {
            Width = KnobWidth,
            Height = KnobHeight,
            CornerRadius = new CornerRadius(KnobHeight / 2),
            Background = Look.Text,
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 9,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Children =
                {
                    Chevron(StepLook.ChevronLeft), Chevron(StepLook.ChevronRight),
                },
            },
        };
        ring = new Border
        {
            Margin = new Thickness(-4),
            CornerRadius = new CornerRadius(KnobHeight / 2 + 4),
            BorderBrush = Look.Link,
            BorderThickness = new Thickness(2.5),
            Visibility = Visibility.Collapsed,
        };
        knob.Children.Add(Shadows.Under(face, Look.TextColor, (float)(KnobHeight / 2), 10, 2, 0.5f));
        knob.Children.Add(face);
        knob.Children.Add(ring);
        slide = new Frames(now =>
        {
            double t = Math.Min(1, now / 0.18);
            Place(slideFrom + (slideTo - slideFrom) * Curves.EaseOut(t));
            return t < 1;
        });

        SizeChanged += (_, _) => Layout();
        PointerPressed += Pressed;
        PointerMoved += Moved;
        PointerReleased += (_, e) => { ReleasePointerCapture(e.Pointer); Settle(); };
        PointerCaptureLost += (_, _) => Settle();
        KeyDown += Key;
        GotFocus += (_, _) => ring.Visibility = FocusState == FocusState.Keyboard ? Visibility.Visible : Visibility.Collapsed;
        LostFocus += (_, _) => ring.Visibility = Visibility.Collapsed;
        AutomationProperties.SetName(this, SetupViewWords.Slider);
        AutomationProperties.SetAutomationId(this, "first-run-servers-slider");
    }

    private static FontIcon Chevron(string glyph)
    {
        var icon = StepLook.Glyph(glyph, 9, Look.Brush(Color.FromArgb(178, 0x19, 0x19, 0x19)));
        icon.FontWeight = FontWeights.Bold;
        return icon;
    }

    /// <summary>The ends' words, each step's count, and the chosen step.</summary>
    public void Show(string lowerWords, string higherWords, IReadOnlyList<string> stepWords, ServersStep chosen)
    {
        lower.Text = lowerWords;
        higher.Text = higherWords;
        bool rebuilt = !words.SequenceEqual(stepWords);
        if (rebuilt)
        {
            words = stepWords;
            foreach (var dot in dots) canvas.Children.Remove(dot);
            foreach (var count in counts) canvas.Children.Remove(count);
            dots.Clear();
            counts.Clear();
            for (int i = 0; i < words.Count; i++)
            {
                var dot = new Ellipse { Width = Dot, Height = Dot };
                dots.Add(dot);
                canvas.Children.Add(dot);
                var count = Look.Words(words[i], 13, 20, Look.Muted, wrap: false);
                counts.Add(count);
                canvas.Children.Add(count);
            }
            canvas.Children.Remove(knob);
            canvas.Children.Add(knob);
        }
        var was = step;
        step = chosen;
        AutomationProperties.SetItemStatus(this, words.Count > Index(chosen) ? words[Index(chosen)] : "");
        if (rebuilt || double.IsNaN(knobAt)) Layout();
        else if (was != chosen && held is null) SlideTo(X(Index(chosen)));
        else Paint();
    }

    private static int Index(ServersStep step)
    {
        for (int i = 0; i < Steps.Count; i++) if (Steps[i] == step) return i;
        return 0;
    }

    /// <summary>The track's ends: 30 in from each side, or more where an end step's words are wider (in the chosen
    /// step's type, the widest that they take).</summary>
    private double Inset
    {
        get
        {
            double widest = 0;
            foreach (var w in new[] { words.FirstOrDefault(), words.LastOrDefault() })
            {
                if (w is null) continue;
                var block = Look.Words(w, 15, 20, semibold: true, wrap: false);
                block.Measure(new global::Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
                widest = Math.Max(widest, Math.Ceiling(block.DesiredSize.Width));
            }
            return Math.Max(30, widest / 2);
        }
    }

    private double TrackWidth => Math.Max(1, ActualWidth - 2 * Inset);

    private double X(int index) => Inset + TrackWidth * index / Math.Max(1, Steps.Count - 1);

    private ServersStep Nearest(double x)
    {
        int index = (int)Math.Round((x - Inset) / TrackWidth * (Steps.Count - 1));
        return Steps[Math.Clamp(index, 0, Steps.Count - 1)];
    }

    private double Clamp(double x) => Math.Clamp(x, Inset, Inset + TrackWidth);

    private void Layout()
    {
        if (ActualWidth <= 0) return;
        Canvas.SetLeft(track, Inset);
        Canvas.SetTop(track, TrackY - TrackHeight / 2);
        track.Width = TrackWidth;
        Canvas.SetTop(done, TrackY - TrackHeight / 2);
        Canvas.SetLeft(done, Inset);
        Place(held ?? X(Index(step)));
    }

    private void SlideTo(double x)
    {
        if (reduceMotion() || double.IsNaN(knobAt)) { slide.Stop(); Place(x); return; }
        slideFrom = knobAt;
        slideTo = x;
        slide.Start();
    }

    /// <summary>The knob at a place, the track filled up to it, the dots it passed, and the counts.</summary>
    private void Place(double x)
    {
        knobAt = x;
        Canvas.SetLeft(knob, x - KnobWidth / 2);
        Canvas.SetTop(knob, TrackY - KnobHeight / 2);
        done.Width = Math.Max(TrackHeight, x - Inset);
        Paint();
    }

    private void Paint()
    {
        int chosen = Index(step);
        for (int i = 0; i < dots.Count; i++)
        {
            double at = X(i);
            dots[i].Fill = Look.Brush(at <= knobAt + 0.5 ? Look.White(0.62) : Look.Rgb(0x6B, 0x6B, 0x6B));
            Canvas.SetLeft(dots[i], at - Dot / 2);
            Canvas.SetTop(dots[i], TrackY - Dot / 2);
            var count = counts[i];
            count.FontSize = i == chosen ? 15 : 13;
            count.FontWeight = i == chosen ? FontWeights.SemiBold : FontWeights.Normal;
            count.Foreground = i == chosen ? Look.Text : Look.Muted;
            count.Measure(new global::Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(count, at - count.DesiredSize.Width / 2);
            Canvas.SetTop(count, CountsY - 10);
        }
    }

    private void Pressed(object sender, PointerRoutedEventArgs e)
    {
        Focus(FocusState.Pointer);
        CapturePointer(e.Pointer);
        double x = e.GetCurrentPoint(this).Position.X;
        bool onKnob = Math.Abs(x - knobAt) <= KnobWidth / 2;
        grab = onKnob ? knobAt - x : 0;
        double place = Clamp(onKnob ? knobAt : x);
        held = place;
        if (onKnob) Place(place);
        else SlideTo(place);
        Choose(Nearest(place));
        e.Handled = true;
    }

    private void Moved(object sender, PointerRoutedEventArgs e)
    {
        if (grab is not { } offset) return;
        double place = Clamp(e.GetCurrentPoint(this).Position.X + offset);
        held = place;
        slide.Stop();
        Place(place);
        Choose(Nearest(place));
    }

    /// <summary>The drag let go: the knob slides to the step that it chose.</summary>
    private void Settle()
    {
        if (held is null && grab is null) return;
        held = null;
        grab = null;
        SlideTo(X(Index(step)));
    }

    private void Key(object sender, KeyRoutedEventArgs e)
    {
        int index = Index(step);
        if (e.Key == VirtualKey.Left && index > 0) Choose(Steps[index - 1]);
        else if (e.Key == VirtualKey.Right && index < Steps.Count - 1) Choose(Steps[index + 1]);
        else return;
        ring.Visibility = Visibility.Visible;
        e.Handled = true;
    }

    private void Choose(ServersStep next)
    {
        if (next == step) return;
        choose(next);
    }
}
