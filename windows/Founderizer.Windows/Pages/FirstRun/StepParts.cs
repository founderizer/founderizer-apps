using System;
using System.Collections.Generic;
using System.Diagnostics;
using Founderizer.Core;
using Founderizer.Setup.FirstRun;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Marks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>What a page of the first run gets from its frame: the first run's store, this PC's Tailscale and its setup,
/// the window's way to Add this PC (W8), and whether Windows' animation effects are off.</summary>
internal sealed class StepHost
{
    public required SetupStore Store { get; init; }
    public required PcTailscale Pc { get; init; }
    public required TailscaleSetup Tailscale { get; init; }
    /// <summary>W8: the window opens step 1's Add this PC page.</summary>
    public required Action AddThisPc { get; init; }
    public required Func<bool> ReduceMotion { get; init; }
    public required DispatcherQueue Queue { get; init; }
}

/// <summary>One page of the first run as the window draws it: its view, and its model at each change of the first run.
/// The frame (<see cref="FirstRunHost"/>) draws Back and the steps; a page draws its step.</summary>
internal interface IStepView
{
    FrameworkElement View { get; }

    /// <summary>The first run's state and this page's model (<see cref="SetupScreens.Of"/>), on the window's thread.</summary>
    void Show(SetupState state, SetupScreen screen);

    /// <summary>Enter: the page's one way on while it shows (the Mac's default action); false when it has none now.</summary>
    bool Enter() => false;

    /// <summary>The page leaves: a press that runs for it stops, and its own timers end.</summary>
    void Left() { }
}

/// <summary>**The measures of a step, as set 8 draws them** (the Mac's <c>SetupMetrics</c> in step 1's Windows look): the
/// title at 22 in Segoe UI Variable Display, everything under it at 15, a step 460 wide (540 for "Your fleet's servers",
/// 700 for "Help improve Founderizer", 800 for the welcome page), a field 380 wide, a mark of 48.</summary>
internal static class StepLook
{
    public const double Width = 460, CardsWidth = 540, ReportsWidth = 700, WelcomeWidth = 800, FieldWidth = 380, Mark = 48;
    public const double Title = 22, TitleLine = 28, Text = 15, TextLine = 21;
    /// <summary>Between the controls of a step, as between its mark and its title (<c>SetupMetrics.gap</c>).</summary>
    public const double Gap = 18;

    public static readonly Color TileEdge = Look.White(0.09);
    public static readonly Color ButtonFill = Look.Rgb(0xF2, 0xF2, 0xF2);

    /// <summary>The words of a step: 15 on 21, centred, wrapping.</summary>
    public static TextBlock Words(string words, Brush? brush = null, double size = Text, double line = TextLine, bool semibold = false)
    {
        var block = Look.Words(words, size, line, brush, semibold);
        block.TextAlignment = TextAlignment.Center;
        block.HorizontalAlignment = HorizontalAlignment.Center;
        return block;
    }

    /// <summary>A 48 tile on the canvas with its mark in the middle (the Mac's <c>IconTile</c>): the surface, a white edge
    /// of 9 %, a corner of 12.5.</summary>
    public static Border Tile(UIElement mark, double side = Mark, double corner = 12.5) => new()
    {
        Width = side,
        Height = side,
        CornerRadius = new CornerRadius(corner),
        Background = Look.SurfaceBrush,
        BorderBrush = Look.Brush(TileEdge),
        BorderThickness = new Thickness(1),
        Child = mark,
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    /// <summary>A glyph of Segoe Fluent Icons at a size, in a brush.</summary>
    public static FontIcon Glyph(string glyph, double size, Brush? brush = null) => new()
    {
        Glyph = glyph,
        FontSize = size,
        FontFamily = new FontFamily("Segoe Fluent Icons"),
        Foreground = brush ?? Look.Text,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false,
    };

    public const string ChevronLeft = "", ChevronRight = "", Bug = "", Send = "", Cancel = "", CheckMark = "";

    /// <summary>An agent's mark at rest, as the manager of that name gets it (the Mac's <c>AgentGlyph(name:)</c> with no
    /// dot: the step's mark is its subject, not a status).</summary>
    public static AgentGlyph AgentMark(string name, double side)
    {
        var look = GlyphLook.Team([name])[name];
        return Look.Glyph(MarkLook.Of(look, AgentState.Online, moves: false), side);
    }

    public static Geometry Geometry(string data) => (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), data);
}

/// <summary>**One step: its mark, its title and the line under it, and what is under them** (the Mac's
/// <c>SetupStep</c>; set 8's <c>.st</c>): the title 18 under the mark, its line 6 under the title, the controls 24 under
/// those and 18 apart, all in the middle of a column of the step's width.</summary>
internal sealed class StepColumn : StackPanel
{
    private readonly ContentControl mark = new() { IsTabStop = false, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StepTitle title = new();
    private readonly TextBlock detail = StepLook.Words("", Look.Muted);

    /// <summary>The controls under the title, 18 apart.</summary>
    public StackPanel Controls { get; } = new() { Spacing = StepLook.Gap, HorizontalAlignment = HorizontalAlignment.Stretch };

    public StepColumn(double width)
    {
        Width = width;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
        // WinUI sets a title's line higher in its box than the pictures do (Look.TitleNudge).
        title.Margin = new Thickness(0, 18 + Look.TitleNudge, 0, -Look.TitleNudge);
        detail.Margin = new Thickness(0, 6, 0, 0);
        detail.Visibility = Visibility.Collapsed;
        Controls.Margin = new Thickness(0, 24, 0, 0);
        Children.Add(mark);
        Children.Add(title);
        Children.Add(detail);
        Children.Add(Controls);
    }

    public UIElement? Mark
    {
        get => mark.Content as UIElement;
        set => mark.Content = value;
    }

    /// <summary>The title, which moves while the machine works and he has nothing to do (<c>SetupTitle(moving:)</c>), and
    /// the one muted line under it, or none.</summary>
    public void Show(string words, bool waits, string? line, bool reduceMotion)
    {
        title.Show(words, waits, reduceMotion);
        detail.Text = line ?? "";
        detail.Visibility = line is null ? Visibility.Collapsed : Visibility.Visible;
    }
}

/// <summary>A step's title: still while he has something to do; moving words while the machine works (the Mac's
/// <c>SetupTitle</c>: <c>ShimmeringWords</c> in the title's type, muted, a band of light crossing them), still and muted
/// where Windows' animation effects are off.</summary>
internal sealed class StepTitle : Grid
{
    private readonly TextBlock still = StepLook.Words("", size: StepLook.Title, line: StepLook.TitleLine, semibold: true);
    private readonly ShimmerText moving = new() { HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };

    public StepTitle()
    {
        still.FontFamily = Look.Display;
        var words = moving.Words;
        words.FontFamily = Look.Display;
        words.FontSize = StepLook.Title;
        words.LineHeight = StepLook.TitleLine;
        words.FontWeight = FontWeights.SemiBold;
        words.Foreground = Look.Muted;
        moving.Light = Look.TextColor;
        Children.Add(still);
        Children.Add(moving);
        AutomationProperties.SetHeadingLevel(this, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
    }

    public void Show(string words, bool waits, bool reduceMotion)
    {
        bool moves = waits && !reduceMotion;
        still.Text = words;
        still.Foreground = waits ? Look.Muted : Look.Text;
        still.Visibility = moves ? Visibility.Collapsed : Visibility.Visible;
        moving.Text = words;
        moving.Shimmer = moves;
        moving.Visibility = moves ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(this, words);
    }
}

/// <summary>The controls of a step in step 1's Windows look (set 8: "A macOS control takes step 1's Windows look").</summary>
internal static class StepControls
{
    /// <summary>**The step's one way on** (Continue, Connect): step 1's white button, 32 high, its words 14 semibold in the
    /// canvas's colour, a corner of 4; a little darker under the pointer and in the press.</summary>
    public static Button Primary(string words, string id)
    {
        var face = new Border
        {
            Height = 32,
            Padding = new Thickness(16, 0, 16, 0),
            CornerRadius = new CornerRadius(4),
            Background = Look.Brush(StepLook.ButtonFill),
            Child = new TextBlock
            {
                Text = words,
                FontFamily = Look.TextFont,
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
                Foreground = Look.CanvasBrush,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        var button = Pressable(face, StepLook.ButtonFill, Look.Rgb(0xDE, 0xDE, 0xDE), Look.Rgb(0xCF, 0xCF, 0xCF), words, id);
        button.HorizontalAlignment = HorizontalAlignment.Center;
        return button;
    }

    /// <summary>**A quiet link under a step** (the Mac's <c>SetupLink</c>: muted words at 15, no capsule; W8's "Add this
    /// PC", "Open Tailscale again"): the text colour under the pointer.</summary>
    public static Button Link(string words, string id)
    {
        var text = StepLook.Words(words, Look.Muted);
        var button = new Button
        {
            Style = Plain,
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(6, 2, 6, 2),
            Content = text,
        };
        button.PointerEntered += (_, _) => text.Foreground = Look.Text;
        button.PointerExited += (_, _) => text.Foreground = Look.Muted;
        Name(button, words, id);
        return button;
    }

    /// <summary>**A card of a step** (the Mac's <c>SetupChoice</c>, <c>ProviderCard</c> and the cards of "Help improve
    /// Founderizer"): the surface, an edge of white 8 %, a corner of 8; a little lighter under the pointer.</summary>
    public static Button Card(UIElement content, string name, string id, double? minHeight = null)
    {
        var face = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = Look.SurfaceBrush,
            BorderBrush = Look.CardEdge,
            BorderThickness = new Thickness(1),
            Child = content,
        };
        if (minHeight is { } least) face.MinHeight = least;
        var card = Pressable(face, Look.Surface, Look.Rgb(0x29, 0x29, 0x29), Look.Rgb(0x26, 0x26, 0x26), name, id);
        // A card takes the width of its place in its row (WinUI's own button stands at its words' width on the left).
        card.HorizontalAlignment = HorizontalAlignment.Stretch;
        return card;
    }

    /// <summary>A card's line: its mark of 28, its words at 15 semibold, and the check mark on the one chosen last
    /// (the Mac's <c>ProviderCard</c>: 18 in from each edge, 12 between the mark and the words).</summary>
    public static Grid CardLine(UIElement mark, string words, bool marked)
    {
        var line = new Grid { Padding = new Thickness(18), ColumnSpacing = 12 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (mark is FrameworkElement m) { m.HorizontalAlignment = HorizontalAlignment.Center; m.VerticalAlignment = VerticalAlignment.Center; }
        line.Children.Add(mark);
        var text = Look.Words(words, StepLook.Text, 20, semibold: true);
        text.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(text, 1);
        line.Children.Add(text);
        if (marked)
        {
            var check = StepLook.Glyph(StepLook.CheckMark, 12, Look.Muted);
            AutomationProperties.SetName(check, "Now");
            Grid.SetColumn(check, 2);
            line.Children.Add(check);
        }
        return line;
    }

    /// <summary>The step's one orange line (the Mac's <c>SetupWarning</c>: orange, at 15, no symbol).</summary>
    public static TextBlock Warning(string words)
    {
        var block = StepLook.Words(words, Look.Orange);
        AutomationProperties.SetLiveSetting(block, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        return block;
    }

    private static Button Pressable(Border face, Color rest, Color over, Color pressed, string name, string id)
    {
        var button = new Button { Style = Plain, CornerRadius = face.CornerRadius, Content = face };
        bool inside = false;
        button.PointerEntered += (_, _) => { inside = true; face.Background = Look.Brush(over); };
        button.PointerExited += (_, _) => { inside = false; face.Background = Look.Brush(rest); };
        button.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => face.Background = Look.Brush(pressed)), true);
        button.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => face.Background = Look.Brush(inside ? over : rest)), true);
        Name(button, name, id);
        return button;
    }

    /// <summary>A button that draws only what it holds: each face takes the pointer's fills itself, and Windows draws its
    /// focus frame for the keyboard.</summary>
    internal static Style Plain => plain ??= (Style)XamlReader.Load(
        "<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'>" +
        "<Setter Property='UseSystemFocusVisuals' Value='True'/><Setter Property='Padding' Value='0'/>" +
        "<Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'>" +
        "<Grid Background='Transparent' CornerRadius='{TemplateBinding CornerRadius}'><ContentPresenter Content='{TemplateBinding Content}' " +
        "Padding='{TemplateBinding Padding}' HorizontalContentAlignment='Stretch' VerticalContentAlignment='Stretch'/></Grid>" +
        "</ControlTemplate></Setter.Value></Setter></Style>");
    private static Style? plain;

    private static void Name(FrameworkElement element, string name, string id)
    {
        AutomationProperties.SetName(element, name);
        AutomationProperties.SetAutomationId(element, id);
    }
}

/// <summary>**A step's field** (the Mac's <c>SetupField</c> in step 1's Windows look, set 8's <c>.fld</c>): 380 by 34,
/// WinUI's text box in step 1's colours, its words at 15; with the caret, a darker fill and the violet line of 2 at its
/// foot; an orange edge for words that the step does not take (<c>wrong</c>).</summary>
internal sealed class StepField : Grid
{
    private readonly Border frame;
    private readonly Rectangle focusLine;
    public TextBox Box { get; }
    private bool wrong;

    public StepField(string placeholder, string id)
    {
        Width = StepLook.FieldWidth;
        Height = 34;
        HorizontalAlignment = HorizontalAlignment.Center;
        frame = new Border { CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1) };
        focusLine = new Rectangle
        {
            Height = 2,
            VerticalAlignment = VerticalAlignment.Bottom,
            Fill = Look.Link,
            RadiusX = 1,
            RadiusY = 1,
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(0.5, 0, 0.5, 0),
        };
        Box = new PlainTextBox
        {
            FontSize = StepLook.Text,
            FontFamily = Look.TextFont,
            Padding = new Thickness(0),
            MinHeight = 0,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(11, 1, 11, 0),
            AcceptsReturn = false,
            TextWrapping = TextWrapping.NoWrap,
            PlaceholderText = placeholder,
        };
        foreach (var state in new[] { "", "PointerOver", "Focused", "Disabled" })
        {
            Box.Resources["TextControlBackground" + state] = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            Box.Resources["TextControlBorderBrush" + state] = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            Box.Resources["TextControlForeground" + state] = Look.Text;
            Box.Resources["TextControlPlaceholderForeground" + state] = Look.Muted;
        }
        Box.Resources["TextControlBorderThemeThickness"] = new Thickness(0);
        Box.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        AutomationProperties.SetName(Box, placeholder);
        AutomationProperties.SetAutomationId(Box, id);
        Box.GotFocus += (_, _) => Paint();
        Box.LostFocus += (_, _) => Paint();
        Children.Add(frame);
        Children.Add(Box);
        Children.Add(focusLine);
        Paint();
    }

    /// <summary>The words that the step does not take: the field wears the orange edge.</summary>
    public bool Wrong
    {
        get => wrong;
        set { if (wrong != value) { wrong = value; Paint(); } }
    }

    private void Paint()
    {
        bool focused = Box.FocusState != FocusState.Unfocused;
        frame.Background = Look.Brush(focused ? Look.Rgb(0x1E, 0x1E, 0x1E) : Look.White(0.06));
        frame.BorderBrush = wrong ? Look.Orange : Look.FieldEdge(34, focused ? Look.White(0.08) : Look.White(0.45));
        focusLine.Visibility = focused && !wrong ? Visibility.Visible : Visibility.Collapsed;
    }
}

/// <summary>**A text box with no clear button**: Windows' own "✕" in a field with words and the caret is a button that set 8
/// does not draw (the Mac's field has none), so its part of the template has no template of its own: it draws nothing,
/// takes no room and takes no press, whatever state the text box puts it in. (A width of 0 alone hid it, but its glyph
/// still stood over the field's end, where UI Automation listed it.)</summary>
internal sealed class PlainTextBox : TextBox
{
    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        if (GetTemplateChild("DeleteButton") is Button clear)
        {
            clear.Template = null;
            clear.Width = 0;
            clear.MinWidth = 0;
            clear.IsTabStop = false;
            clear.IsHitTestVisible = false;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(clear, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        }
    }
}

/// <summary>The marks of set 8 that Windows' fonts do not have, drawn as the pictures draw them.</summary>
internal static class StepMarks
{
    /// <summary>**Tailscale's logo on its white tile** (the Mac's <c>NetworkMark</c>): nine dots of 7.8, 11.7 apart, in
    /// Tailscale's ink; the four of its T full, the rest at 20 %.</summary>
    public static Border Network()
    {
        var canvas = new Canvas { Width = 48, Height = 48 };
        for (int k = 0; k < 9; k++)
        {
            var dot = new Ellipse
            {
                Width = 7.8,
                Height = 7.8,
                Fill = Look.Brush(Look.Rgb(0x24, 0x24, 0x24)),
                Opacity = k is 3 or 4 or 5 or 7 ? 1 : 0.2,
            };
            Canvas.SetLeft(dot, 24 - 3.9 + (k % 3 - 1) * 11.7);
            Canvas.SetTop(dot, 24 - 3.9 + (k / 3 - 1) * 11.7);
            canvas.Children.Add(dot);
        }
        return new Border
        {
            Width = 48,
            Height = 48,
            CornerRadius = new CornerRadius(12.5),
            Background = Look.Brush(Color.FromArgb(255, 255, 255, 255)),
            Child = canvas,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
    }

    /// <summary>**A server** (the Mac's <c>server.rack</c>; set 8 draws it in Fluent's line style, as Segoe Fluent Icons
    /// has no server): two boxes, a line and a light in each, in a square of 20, at <paramref name="side"/>.</summary>
    public static Viewbox Server(double side, Brush? brush = null)
    {
        brush ??= Look.Text;
        var canvas = new Canvas { Width = 20, Height = 20 };
        foreach (var top in new[] { 3.5, 11.0 })
        {
            var box = new Rectangle { Width = 13, Height = 5.5, RadiusX = 1.5, RadiusY = 1.5, Stroke = brush, StrokeThickness = 1 };
            Canvas.SetLeft(box, 3.5);
            Canvas.SetTop(box, top);
            canvas.Children.Add(box);
        }
        canvas.Children.Add(new Path
        {
            Data = StepLook.Geometry("M6 6.25H10M6 13.75H10"),
            Stroke = brush,
            StrokeThickness = 1,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        });
        foreach (var y in new[] { 6.25, 13.75 })
        {
            var light = new Ellipse { Width = 1.8, Height = 1.8, Fill = brush };
            Canvas.SetLeft(light, 13.5 - 0.9);
            Canvas.SetTop(light, y - 0.9);
            canvas.Children.Add(light);
        }
        return new Viewbox { Width = side, Height = side, Child = canvas, IsHitTestVisible = false };
    }

    /// <summary>**The product's chevrons as a line mark** (the Mac's <c>WayChevrons</c>: FounderizerMark's chevrons with
    /// no plate, their box from 96 to 416 of its 512, strokes of 44 and 54 there).</summary>
    public static Viewbox Chevrons(double side, Brush brush)
    {
        var canvas = new Canvas { Width = 320, Height = 320 };
        foreach (var (data, width) in new[] { ("M76 121L160 37L244 121", 44.0), ("M52 277L160 169L268 277", 54.0) })
            canvas.Children.Add(new Path
            {
                Data = StepLook.Geometry(data),
                Stroke = brush,
                StrokeThickness = width,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                StrokeLineJoin = PenLineJoin.Round,
            });
        return new Viewbox { Width = side, Height = side, Child = canvas, IsHitTestVisible = false };
    }
}

/// <summary>**A motion that runs for a while and ends** (the Mac's keyframe timelines and short animations, which never
/// loop): <see cref="Tick"/> gets the seconds since the start at each frame that Windows draws, until it says it is done.
/// Nothing runs where Windows' animation effects are off: the caller draws the end at once.</summary>
internal sealed class Frames
{
    private readonly Func<double, bool> tick;
    private readonly Stopwatch clock = new();
    private bool running, begun;

    /// <summary><paramref name="tick"/> draws the moment and gives true while the motion goes on.</summary>
    public Frames(Func<double, bool> tick) => this.tick = tick;

    public bool Running => running;

    /// <summary>The motion begins at the first frame that Windows draws after this: a window that takes a moment to
    /// show its first frame shows the motion from its start.</summary>
    public void Start()
    {
        begun = false;
        clock.Restart();
        if (running) return;
        running = true;
        CompositionTarget.Rendering += Rendering;
    }

    public void Stop()
    {
        if (!running) return;
        running = false;
        CompositionTarget.Rendering -= Rendering;
    }

    private void Rendering(object? sender, object e)
    {
        if (!begun) { begun = true; clock.Restart(); }
        if (!tick(clock.Elapsed.TotalSeconds)) Stop();
    }
}
