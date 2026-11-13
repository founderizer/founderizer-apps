using System;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.Text;

namespace Founderizer.Windows.Pages;

/// <summary>The look of the pages as the approved pictures draw it (windows-app-pictures.html: the Mac's FleetStyle
/// colours, Windows' type and corners). One place for each colour, size and edge, so that the pages agree.</summary>
internal static class Look
{
    public static readonly Color Canvas = Rgb(0x19, 0x19, 0x19);
    public static readonly Color Rail = Rgb(0x20, 0x20, 0x20);
    public static readonly Color Chrome = Rgb(0x25, 0x25, 0x25);
    public static readonly Color Surface = Rgb(0x22, 0x22, 0x22);
    public static readonly Color Select = Rgb(0x30, 0x30, 0x30);
    public static readonly Color ComposerFill = Rgb(0x34, 0x34, 0x34);
    public static readonly Color Own = Rgb(0x3D, 0x3D, 0x3D);
    public static readonly Color TextColor = Rgb(0xE6, 0xE6, 0xE6);
    public static readonly Color MutedColor = Rgb(0x99, 0x99, 0x99);
    public static readonly Color LinkColor = Rgb(0x8F, 0x88, 0xFF);
    public static readonly Color Accent = Rgb(0x63, 0x5B, 0xFF);
    public static readonly Color OrangeColor = Rgb(0xFF, 0x9F, 0x0A);
    public static readonly Color Ink = Rgb(0x11, 0x12, 0x13);

    private static SolidColorBrush? text, muted, link, orange, line, cardEdge, surface, chrome, rail, canvas, own, select;

    public static SolidColorBrush Text => text ??= new(TextColor);
    public static SolidColorBrush Muted => muted ??= new(MutedColor);
    public static SolidColorBrush Link => link ??= new(LinkColor);
    public static SolidColorBrush Orange => orange ??= new(OrangeColor);
    /// <summary>The hairline between parts: white at 6.5 %.</summary>
    public static SolidColorBrush Line => line ??= new(White(0.065));
    /// <summary>A card's edge: white at 8 %.</summary>
    public static SolidColorBrush CardEdge => cardEdge ??= new(White(0.08));
    public static SolidColorBrush SurfaceBrush => surface ??= new(Surface);
    public static SolidColorBrush ChromeBrush => chrome ??= new(Chrome);
    public static SolidColorBrush RailBrush => rail ??= new(Rail);
    public static SolidColorBrush CanvasBrush => canvas ??= new(Canvas);
    public static SolidColorBrush OwnBrush => own ??= new(Own);
    public static SolidColorBrush SelectBrush => select ??= new(Select);

    /// <summary>The pictures' type: Segoe UI Variable's Text instance for all words, its Display instance for titles.
    /// Named, so that small words do not take a smaller optical size than the pictures have.</summary>
    public static readonly FontFamily TextFont = new("Segoe UI Variable Text");
    public static readonly FontFamily Display = new("Segoe UI Variable Display");

    public static Color Rgb(byte r, byte g, byte b) => Color.FromArgb(255, r, g, b);

    public static Color White(double alpha) => Color.FromArgb((byte)Math.Round(alpha * 255), 255, 255, 255);

    public static SolidColorBrush Brush(Color color) => new(color);

    /// <summary>A text block: 14 on 20 unless asked, wrapping, in the text colour.</summary>
    public static TextBlock Words(string words, double size = 14, double lineHeight = 20, Brush? brush = null,
                                  bool semibold = false, bool wrap = true)
    {
        var block = new TextBlock
        {
            Text = words,
            FontFamily = TextFont,
            FontSize = size,
            LineHeight = lineHeight,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = brush ?? Text,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        };
        if (semibold) block.FontWeight = FontWeights.SemiBold;
        return block;
    }

    /// <summary>A page's title: Segoe UI Variable Display, 28 on 36, semibold. WinUI sets its line 2.5 pixels higher in
    /// the line box than the pictures do, so a title's margin takes 2.5 from below and gives it above.</summary>
    public const double TitleNudge = 2.5;

    /// <summary>A page's title: Segoe UI Variable Display, 28 on 36, semibold.</summary>
    public static TextBlock PageTitle(string words)
    {
        var block = Words(words, 28, 36, semibold: true, wrap: false);
        block.FontFamily = Display;
        return block;
    }

    /// <summary>A field's edge as Windows draws it: the edge all round, and a lighter bottom line of one pixel.</summary>
    public static Brush FieldEdge(double height, Color bottom) => FieldEdge(height, White(0.08), bottom);

    public static Brush FieldEdge(double height, Color edge, Color bottom)
    {
        var brush = new LinearGradientBrush
        {
            MappingMode = BrushMappingMode.Absolute,
            StartPoint = new global::Windows.Foundation.Point(0, 0),
            EndPoint = new global::Windows.Foundation.Point(0, height),
        };
        double at = (height - 1) / height;
        brush.GradientStops.Add(new GradientStop { Color = edge, Offset = 0 });
        brush.GradientStops.Add(new GradientStop { Color = edge, Offset = at });
        brush.GradientStops.Add(new GradientStop { Color = bottom, Offset = at });
        brush.GradientStops.Add(new GradientStop { Color = bottom, Offset = 1 });
        return brush;
    }

    /// <summary>A card: the surface, its 8-% edge, a corner of 8.</summary>
    public static Border Card(UIElement child, Thickness padding, Color? fill = null) => new()
    {
        Background = Brush(fill ?? Surface),
        BorderBrush = CardEdge,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(8),
        Padding = padding,
        Child = child,
    };

    /// <summary>An agent's mark at a side, at rest unless its look moves.</summary>
    public static AgentGlyph Glyph(MarkLook? mark, double side) => new() { Side = side, Mark = mark };

    /// <summary>The colour of a chat's Send: the middle of the agent's gradient, with white or the ink on it by white's
    /// contrast (the Mac's AgentTint, WCAG 2).</summary>
    public static (Color Fill, Color Ink) Tint(MarkLook? mark)
    {
        if (mark is null) return (Accent, Colors.White);
        double r = (mark.Light.Red + mark.Deep.Red) / 2, g = (mark.Light.Green + mark.Deep.Green) / 2,
            b = (mark.Light.Blue + mark.Deep.Blue) / 2;
        static double Linear(double v) => v <= 0.04045 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4);
        double luminance = 0.2126 * Linear(r) + 0.7152 * Linear(g) + 0.0722 * Linear(b);
        var fill = Color.FromArgb(255, (byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));
        return (fill, 1.05 / (luminance + 0.05) >= 3 ? Colors.White : Ink);
    }

    private static class Colors
    {
        public static readonly Color White = Color.FromArgb(255, 255, 255, 255);
    }
}
