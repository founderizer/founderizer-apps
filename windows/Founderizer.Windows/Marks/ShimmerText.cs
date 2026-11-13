using System;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Founderizer.Windows.Marks;

/// <summary>One line of muted words that, while <see cref="Shimmer"/> is on, a band of light crosses from right to
/// left, as the Mac's and the iPhone's line of an agent at work (ShimmeringWords, ChatWaitingLine.swift): one pass
/// every 2.8 seconds, the light in the middle fifth of a box four times the words' width. The compositor moves the
/// band through a mask of the words themselves, so the app does no work for a frame. A line that does not fit ends
/// in "…", and the band crosses the words as they show.</summary>
public sealed class ShimmerText : Grid
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(
        nameof(Text), typeof(string), typeof(ShimmerText), new PropertyMetadata("", (d, e) => ((ShimmerText)d).words.Text = (string)e.NewValue));
    public static readonly DependencyProperty ShimmerProperty = DependencyProperty.Register(
        nameof(Shimmer), typeof(bool), typeof(ShimmerText), new PropertyMetadata(false, (d, _) => ((ShimmerText)d).Update()));

    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public bool Shimmer { get => (bool)GetValue(ShimmerProperty); set => SetValue(ShimmerProperty, value); }

    private const double Pass = 2.8, Box = 4, LightBegins = 0.4, LightEnds = 0.6;
    private static readonly UISettings Settings = new();
    private readonly TextBlock words;
    private SpriteVisual? band;
    private CompositionLinearGradientBrush? gradient;
    private CompositionVisualSurface? surface;
    private Vector2 shown;

    public ShimmerText()
    {
        IsHitTestVisible = false;
        words = new TextBlock
        {
            HorizontalAlignment = HorizontalAlignment.Left,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            // The pane's line under an agent's name: 12 on 16, muted.
            FontSize = 12,
            LineHeight = 16,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = (Brush)Application.Current.Resources["MutedBrush"],
        };
        Children.Add(words);
        words.SizeChanged += (_, _) => Update();
        Loaded += (_, _) => { Settings.AnimationsEnabledChanged += AnimationsChanged; Update(); };
        Unloaded += (_, _) => { Settings.AnimationsEnabledChanged -= AnimationsChanged; Clear(); };
    }

    /// <summary>The words' own text block, for its font, size and colour.</summary>
    public TextBlock Words => words;

    /// <summary>The colour of the light: the text colour of the page.</summary>
    public Color Light { get; set; } = Color.FromArgb(255, 0xE6, 0xE6, 0xE6);

    /// <summary>Windows' animation effects were turned on or off: the motion follows at once.</summary>
    private void AnimationsChanged(UISettings sender, UISettingsAnimationsEnabledChangedEventArgs args) =>
        DispatcherQueue?.TryEnqueue(Update);

    private void Update()
    {
        bool on = Shimmer && IsLoaded && Settings.AnimationsEnabled && words.ActualWidth > 0 && words.ActualHeight > 0;
        if (!on) { Clear(); return; }
        var size = new Vector2((float)words.ActualWidth, (float)words.ActualHeight);
        if (band is not null && size == shown) return;
        Clear();
        shown = size;
        var c = ElementCompositionPreview.GetElementVisual(this).Compositor;
        surface = c.CreateVisualSurface();
        surface.SourceVisual = ElementCompositionPreview.GetElementVisual(words);
        surface.SourceSize = size;
        var mask = c.CreateSurfaceBrush(surface);
        mask.Stretch = CompositionStretch.None;
        mask.HorizontalAlignmentRatio = 0;
        mask.VerticalAlignmentRatio = 0;
        var clear = Color.FromArgb(0, Light.R, Light.G, Light.B);
        gradient = c.CreateLinearGradientBrush();
        gradient.MappingMode = CompositionMappingMode.Absolute;
        gradient.StartPoint = Vector2.Zero;
        gradient.EndPoint = new Vector2(size.X * (float)Box, 0);
        gradient.ColorStops.Add(c.CreateColorGradientStop(0, clear));
        gradient.ColorStops.Add(c.CreateColorGradientStop((float)LightBegins, clear));
        gradient.ColorStops.Add(c.CreateColorGradientStop(0.5f, Light));
        gradient.ColorStops.Add(c.CreateColorGradientStop((float)LightEnds, clear));
        gradient.ColorStops.Add(c.CreateColorGradientStop(1, clear));
        var masked = c.CreateMaskBrush();
        masked.Source = gradient;
        masked.Mask = mask;
        band = c.CreateSpriteVisual();
        band.Size = size;
        band.Brush = masked;
        ElementCompositionPreview.SetElementChildVisual(this, band);

        // The light's middle starts past the words' right end and goes past their left end (the Mac's sweep).
        double half = (LightEnds - LightBegins) * Box / 2, centre = Box / 2;
        var sweep = c.CreateScalarKeyFrameAnimation();
        sweep.InsertKeyFrame(0, (float)((1 + half - centre) * size.X));
        sweep.InsertKeyFrame(1, (float)((-half - centre) * size.X), c.CreateLinearEasingFunction());
        sweep.Duration = TimeSpan.FromSeconds(Pass);
        sweep.IterationBehavior = AnimationIterationBehavior.Forever;
        gradient.StartAnimation("Offset.X", sweep);
    }

    private void Clear()
    {
        if (band is null) return;
        gradient?.StopAnimation("Offset.X");
        ElementCompositionPreview.SetElementChildVisual(this, null);
        band.Dispose();
        surface?.Dispose();
        band = null;
        gradient = null;
        surface = null;
        shown = Vector2.Zero;
    }
}
