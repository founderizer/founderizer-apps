using System;
using System.Collections.Generic;
using System.IO;
using System.Numerics;
using System.Reflection;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace Founderizer.Windows.Pages;

/// <summary>The panel at the right of a chat (AgentStatusPanel), as pictures 1 and 2 draw it: a card with the agent's mark
/// at 48, its role and the name under it; "Usage" with a card of its windows while it has a reading (picture 7 of the second
/// set: each window's length, a bar of 4 on a quiet track, its share, and when it resets); then "Runs on", with the
/// provider's logo and name and the machine.</summary>
internal sealed class AgentPanelView : Grid
{
    private readonly AgentGlyph mark = new() { Side = 48 };
    private readonly TextBlock label = Look.Words("", semibold: true, wrap: false);
    private readonly TextBlock under = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly TextBlock limit = Look.Words("", 12, 16, Look.Orange);
    private readonly TextBlock warning = Look.Words("", 12, 16, Look.Orange);
    private readonly TextBlock usageHeading = Look.Words("", semibold: true, wrap: false);
    private readonly StackPanel usageRows = new();
    private readonly Border usage;
    private ValueList<UsageRow> shownUsage = ValueList<UsageRow>.Empty;
    private readonly TextBlock runsOn = Look.Words("Runs on", semibold: true, wrap: false);
    private readonly Border runs;
    private readonly Grid providerRow;
    private readonly Image logo = new() { Width = 24, Height = 24, Margin = new Thickness(-4, 0, -4, 0) };
    private readonly TextBlock provider = Look.Words("", wrap: false);
    private readonly Grid machineRow;
    private readonly TextBlock machine = Look.Words("", wrap: false);
    private readonly Border rule = new() { Height = 1, Background = Look.Line };
    private string? shownRuntime;

    public AgentPanelView()
    {
        Widths.FollowPanel(this);

        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { label, under } };
        var who = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            Padding = new Thickness(16, 11, 16, 11),
            Children = { mark, names },
        };
        var card = new Border
        {
            Background = Look.ChromeBrush,
            BorderBrush = Look.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = who,
        };
        usageHeading.Margin = new Thickness(2, 18, 0, 10);
        usage = new Border
        {
            Background = Look.ChromeBrush,
            BorderBrush = Look.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = usageRows,
        };
        runsOn.Margin = new Thickness(2, 18, 0, 10);
        providerRow = Row(logo, provider);
        machineRow = Row(Icons.Of(Icons.Desktop, Look.Muted), machine);
        runs = new Border
        {
            Background = Look.ChromeBrush,
            BorderBrush = Look.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = new StackPanel { Children = { providerRow, rule, machineRow } },
        };
        Children.Add(new Border
        {
            Background = Look.RailBrush,
            BorderBrush = Look.Line,
            BorderThickness = new Thickness(1, 0, 0, 0),
            Padding = new Thickness(16),
            Child = new StackPanel { Children = { card, limit, warning, usageHeading, usage, runsOn, runs } },
        });
    }

    public void Show(AgentPanel panel)
    {
        mark.Mark = panel.Mark;
        label.Text = panel.Label;
        under.Text = panel.Under ?? "";
        under.Visibility = panel.Under is null ? Visibility.Collapsed : Visibility.Visible;
        // The agent's usage limit and the manager's warning, in orange under its card (the Mac's panel lines).
        limit.Text = panel.LimitWords ?? "";
        limit.Margin = new Thickness(2, 10, 2, 0);
        limit.Visibility = panel.LimitWords is null ? Visibility.Collapsed : Visibility.Visible;
        warning.Text = panel.Warning ?? "";
        warning.Margin = new Thickness(2, 10, 2, 0);
        warning.Visibility = panel.Warning is null ? Visibility.Collapsed : Visibility.Visible;
        usageHeading.Text = panel.UsageHeading;
        usageHeading.Visibility = usage.Visibility = panel.ShowsUsage && panel.Usage.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (panel.Usage != shownUsage)
        {
            shownUsage = panel.Usage;
            usageRows.Children.Clear();
            for (int i = 0; i < panel.Usage.Count; i++)
            {
                if (i > 0) usageRows.Children.Add(new Border { Height = 1, Background = Look.Line });
                usageRows.Children.Add(UsageView(panel.Usage[i]));
            }
        }
        if (panel.Runtime != shownRuntime)
        {
            shownRuntime = panel.Runtime;
            logo.Source = Logo(panel.Runtime);
        }
        provider.Text = panel.Provider ?? "";
        providerRow.Visibility = panel.Provider is null ? Visibility.Collapsed : Visibility.Visible;
        machine.Text = panel.Machine ?? "";
        machineRow.Visibility = panel.Machine is null ? Visibility.Collapsed : Visibility.Visible;
        rule.Visibility = panel.Provider is not null && panel.Machine is not null ? Visibility.Visible : Visibility.Collapsed;
        bool any = panel.Provider is not null || panel.Machine is not null;
        runsOn.Visibility = runs.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>One usage window (AllowanceMeter and ResetLine): its length, the bar (white at 70 % below 80 %, orange
    /// from 80 %, red when full, muted on an old reading), its share, and the time it resets under the bar.</summary>
    private static Grid UsageView(UsageRow row)
    {
        var grid = new Grid { Padding = new Thickness(16, 10, 16, 10), ColumnSpacing = 12 };
        // The length's column is 28 wide ("5h", "7d"), and wider for a longer label ("Window", another language).
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto, MinWidth = 28 });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Look.Words(row.Label, wrap: false));
        var fill = row.Level switch
        {
            UsageLevel.Full => Look.Rgb(0xFF, 0x45, 0x3A),
            UsageLevel.High => Look.OrangeColor,
            UsageLevel.Old => Look.MutedColor,
            _ => Look.White(0.7),
        };
        var track = new Grid { Height = 4, CornerRadius = new CornerRadius(2), Background = Look.Brush(Look.White(0.10)) };
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Clamp(row.Percent, 0, 100), GridUnitType.Star) });
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100 - Math.Clamp(row.Percent, 0, 100), GridUnitType.Star) });
        track.Children.Add(new Border { CornerRadius = new CornerRadius(2), Background = Look.Brush(fill) });
        var bar = new StackPanel { Padding = new Thickness(0, 8, 0, 0), Children = { track } };
        if (row.Resets is { } resets)
        {
            var mark = Icons.Of(Icons.Refresh, Look.Muted, 11);
            mark.VerticalAlignment = VerticalAlignment.Center;
            bar.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 3,
                Margin = new Thickness(0, 4, 0, 0),
                Children = { mark, Look.Words(resets, 12, 16, Look.Muted, wrap: false) },
            });
        }
        Grid.SetColumn(bar, 1);
        grid.Children.Add(bar);
        // The share in Windows' own form of a percentage for the PC's language: the library gives the number only.
        var share = Look.Words((row.Percent / 100.0).ToString("P0", System.Globalization.CultureInfo.CurrentCulture), wrap: false);
        Grid.SetColumn(share, 2);
        grid.Children.Add(share);
        ToolTipService.SetToolTip(grid, row.Hover);
        return grid;
    }

    private static Grid Row(FrameworkElement icon, TextBlock words)
    {
        icon.VerticalAlignment = VerticalAlignment.Center;
        words.VerticalAlignment = VerticalAlignment.Center;
        return new Grid
        {
            MinHeight = 44,
            Padding = new Thickness(16, 0, 16, 0),
            Children = { new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { icon, words } } },
        };
    }

    private static readonly Dictionary<string, BitmapImage?> Logos = new();

    /// <summary>The provider's logo (Assets/*.png, the Mac's own bytes), or none.</summary>
    private static BitmapImage? Logo(string? runtime)
    {
        if (runtime is null) return null;
        if (Logos.TryGetValue(runtime, out var known)) return known;
        BitmapImage? image = null;
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream($"Founderizer.Windows.Assets.{runtime}.png");
        if (stream is not null)
        {
            var memory = new MemoryStream();
            stream.CopyTo(memory);
            memory.Position = 0;
            image = new BitmapImage { DecodePixelWidth = 48 };
            image.SetSource(memory.AsRandomAccessStream());
        }
        Logos[runtime] = image;
        return image;
    }
}

/// <summary>A soft shadow under a rounded element, drawn by the compositor (the pill's 0 3 10 black at 35 %): a layer
/// with a drop shadow of a rounded rectangle of the element's own fill, behind the element.</summary>
internal static class Shadows
{
    public static Canvas Under(FrameworkElement target, Color fill, float corner, float blur, float y, float opacity)
    {
        var host = new Canvas { IsHitTestVisible = false };
        var compositor = ElementCompositionPreview.GetElementVisual(host).Compositor;
        var layer = compositor.CreateLayerVisual();
        var shadow = compositor.CreateDropShadow();
        shadow.BlurRadius = blur;
        shadow.Offset = new Vector3(0, y, 0);
        shadow.Color = Color.FromArgb(255, 0, 0, 0);
        shadow.Opacity = opacity;
        layer.Shadow = shadow;
        var geometry = compositor.CreateRoundedRectangleGeometry();
        geometry.CornerRadius = new Vector2(corner, corner);
        var shape = compositor.CreateSpriteShape(geometry);
        shape.FillBrush = compositor.CreateColorBrush(fill);
        var shapes = compositor.CreateShapeVisual();
        shapes.Shapes.Add(shape);
        layer.Children.InsertAtTop(shapes);
        ElementCompositionPreview.SetElementChildVisual(host, layer);
        void Place()
        {
            var size = new Vector2((float)target.ActualWidth, (float)target.ActualHeight);
            var at = target.TransformToVisual(host).TransformPoint(new global::Windows.Foundation.Point(0, 0));
            layer.Size = shapes.Size = geometry.Size = size;
            layer.Offset = new Vector3((float)at.X, (float)at.Y, 0);
        }
        target.SizeChanged += (_, _) => Place();
        target.LayoutUpdated += (_, _) => Place();
        return host;
    }
}
