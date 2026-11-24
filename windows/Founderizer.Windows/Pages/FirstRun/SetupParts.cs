using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Founderizer.Windows.Marks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**The parts of the pages of piece U2** (set 8, pictures 8 to 17 with 13d and 14b), each a Mac part in step 1's
/// Windows look: the numbered steps over a field (<c>SetupSteps</c>), the field that a key or a token is pasted into
/// (<c>PasteField</c>), the field that shows no character (<c>SetupSecureField</c>), step 1's standard button
/// (<c>FleetOutlineButtonStyle</c>), a card of form rows (<c>FormSection</c>, <c>FormRow</c>), a provider's logo on its
/// tile (<c>CloudMark</c>), step 1's combo box (<c>FleetSelect</c>), and the fleet's boxes with a line or a choice under
/// each (<c>ServerBoxes</c>, <c>FleetBuildLine</c>, <c>ServerBoxChoice</c>).</summary>
internal static class SetupParts
{
    // Segoe Fluent Icons, as set 8 names them.
    public static readonly string KeyGlyph = char.ConvertFromUtf32(0xE8D7), ShieldGlyph = char.ConvertFromUtf32(0xEA18),
        LockGlyph = char.ConvertFromUtf32(0xE72E), CheckGlyph = char.ConvertFromUtf32(0xE73E), WarningGlyph = char.ConvertFromUtf32(0xE7BA),
        DoneGlyph = char.ConvertFromUtf32(0xEC61), FailedGlyph = char.ConvertFromUtf32(0xEB90), WaitingGlyph = char.ConvertFromUtf32(0xEA3A),
        ChevronDownGlyph = char.ConvertFromUtf32(0xE70D);

    /// <summary>The width of a form inside a step (set 8's <c>.form</c>): the step's own.</summary>
    public const double FormWidth = 460;

    // ------------------------------------------------------------------ the steps over a field

    private static readonly Regex LinkPattern = new(@"\[([^\]]+)\]\(([^)]+)\)", RegexOptions.CultureInvariant);
    private static readonly string Arrow = char.ConvertFromUtf32(0xA0) + char.ConvertFromUtf32(0x2197);

    /// <summary>**The steps over a field** (the Mac's <c>SetupSteps</c>, set 8's <c>.ssteps</c>): a number, muted, right in a
    /// column of 10, then 10 to the words at 15 on 21; 8 between two steps; a link (<c>[words](address)</c>) in the link's
    /// violet, underlined, with its arrow after it, which opens the page in the default browser. With
    /// <paramref name="open"/>, a press on a link calls it in place of that: the page opens its model's own link, and
    /// what goes with it (the manager's sign-in: Codex's code to the clipboard).</summary>
    public static StackPanel Steps(IReadOnlyList<string> lines, double width = StepLook.FieldWidth, string? id = null, Action? open = null)
    {
        var panel = new StackPanel { Width = width, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        for (int i = 0; i < lines.Count; i++)
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var number = Look.Words((i + 1).ToString(CultureInfo.InvariantCulture), StepLook.Text, StepLook.TextLine, Look.Muted, wrap: false);
            number.HorizontalAlignment = HorizontalAlignment.Right;
            row.Children.Add(number);
            var words = Look.Words("", StepLook.Text, StepLook.TextLine);
            words.Inlines.Clear();
            int at = 0;
            foreach (Match link in LinkPattern.Matches(lines[i]))
            {
                if (link.Index > at) words.Inlines.Add(new Run { Text = lines[i][at..link.Index] });
                var hyperlink = new Hyperlink { Foreground = Look.Link };
                if (open is not null) hyperlink.Click += (_, _) => open();
                else if (Uri.TryCreate(link.Groups[2].Value, UriKind.Absolute, out var address) && address.Scheme == Uri.UriSchemeHttps)
                    hyperlink.NavigateUri = address;
                hyperlink.Inlines.Add(new Run { Text = link.Groups[1].Value });
                words.Inlines.Add(hyperlink);
                // A no-break space and the arrow, as the Mac's SetupSteps.words writes them: the arrow never stands alone.
                words.Inlines.Add(new Run { Text = Arrow, Foreground = Look.Link });
                at = link.Index + link.Length;
            }
            if (at < lines[i].Length) words.Inlines.Add(new Run { Text = lines[i][at..] });
            Grid.SetColumn(words, 1);
            row.Children.Add(words);
            panel.Children.Add(row);
        }
        if (id is not null) AutomationProperties.SetAutomationId(panel, id);
        return panel;
    }

    /// <summary>A line's words without its links' addresses, as an assistive app reads them.</summary>
    public static string Plain(string line) => LinkPattern.Replace(line, m => m.Groups[1].Value);

    // ------------------------------------------------------------------ buttons and lines

    /// <summary>**Step 1's standard button** (set 8's <c>.btn</c>; the Mac's <c>FleetOutlineButtonStyle</c>): 32 high, 12 in
    /// from each side, Windows' fill and edge with the lighter foot, a corner of 4, words at 14.</summary>
    public static Button Standard(string words, string id)
    {
        var label = Look.Words(words, wrap: false);
        label.VerticalAlignment = VerticalAlignment.Center;
        var face = new Border
        {
            Height = 32,
            Padding = new Thickness(12, 0, 12, 0),
            CornerRadius = new CornerRadius(4),
            Background = Look.Brush(Look.White(0.06)),
            BorderBrush = Look.FieldEdge(32, Look.White(0.08), Look.White(0.04)),
            BorderThickness = new Thickness(1),
            Child = label,
        };
        var button = new Button { Style = StepControls.Plain, CornerRadius = new CornerRadius(4), Content = face, VerticalAlignment = VerticalAlignment.Center };
        button.PointerEntered += (_, _) => face.Background = Look.Brush(Look.White(0.083));
        button.PointerExited += (_, _) => face.Background = Look.Brush(Look.White(0.06));
        AutomationProperties.SetName(button, words);
        AutomationProperties.SetAutomationId(button, id);
        return button;
    }

    /// <summary>A muted line of a step (set 8's <c>.quiet</c>).</summary>
    public static TextBlock Quiet(string words, string? id = null)
    {
        var block = StepLook.Words(words, Look.Muted);
        if (id is not null) AutomationProperties.SetAutomationId(block, id);
        return block;
    }

    /// <summary>**A check that passed, in one line** (picture 13: the server's system, memory and kind): a green check of
    /// 14, 8 to the words at 15.</summary>
    public static StackPanel Checked(string words, string id)
    {
        var check = StepLook.Glyph(CheckGlyph, 14, Look.Green);
        var text = Look.Words(words, StepLook.Text, StepLook.TextLine, wrap: false);
        text.VerticalAlignment = VerticalAlignment.Center;
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, Children = { check, text } };
        AutomationProperties.SetAutomationId(text, id);
        return line;
    }

    // ------------------------------------------------------------------ a card of form rows

    /// <summary>One row of a form (the Mac's <c>FormRow</c> on a step, set 8's <c>.row</c>): its glyph of 16, 12 to its
    /// title, its detail under the title, an orange warning under that, and its own control at the right.</summary>
    public sealed record Row(string Glyph, string Title, string? Detail = null, string? Warning = null, FrameworkElement? Accessory = null,
                             bool Bold = false, Brush? GlyphBrush = null, double MinHeight = 40, string? Id = null, double TitleSize = 14,
                             bool Tall = false, double DetailSize = 14);

    /// <summary>**A card of rows** (the Mac's <c>FormSection</c> in step 1's look; set 8's <c>.card</c>): the surface, an
    /// edge of white 8 %, a corner of 8, rows 16 in from each side with a hairline between two.</summary>
    public static Border Card(IEnumerable<Row> rows, double width = FormWidth)
    {
        var list = new StackPanel();
        bool first = true;
        foreach (var row in rows)
        {
            if (!first) list.Children.Add(new Rectangle { Height = 1, Fill = Look.Line });
            first = false;
            list.Children.Add(RowView(row));
        }
        return new Border
        {
            Width = width,
            HorizontalAlignment = HorizontalAlignment.Center,
            Background = Look.SurfaceBrush,
            BorderBrush = Look.CardEdge,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = list,
        };
    }

    private static FrameworkElement RowView(Row row)
    {
        var grid = new Grid { MinHeight = row.MinHeight, Padding = new Thickness(16, row.Tall ? 12 : 0, 16, row.Tall ? 12 : 0), ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var glyph = StepLook.Glyph(row.Glyph, 16, row.GlyphBrush ?? Look.Muted);
        glyph.VerticalAlignment = row.Tall ? VerticalAlignment.Top : VerticalAlignment.Center;
        if (row.Tall) glyph.Margin = new Thickness(0, 2, 0, 0);
        grid.Children.Add(glyph);
        var words = new StackPanel { Spacing = 2, VerticalAlignment = row.Tall ? VerticalAlignment.Top : VerticalAlignment.Center };
        var title = Look.Words(row.Title, row.TitleSize, 20, semibold: row.Bold);
        if (row.Id is not null) AutomationProperties.SetAutomationId(title, row.Id);
        words.Children.Add(title);
        if (row.Detail is { Length: > 0 } detail) words.Children.Add(Look.Words(detail, row.DetailSize, row.DetailSize >= 14 ? 20 : 16, Look.Muted));
        if (row.Warning is { Length: > 0 } warning) words.Children.Add(Look.Words(warning, 12, 16, Look.Orange));
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        if (row.Accessory is { } accessory)
        {
            accessory.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(accessory, 2);
            grid.Children.Add(accessory);
        }
        return grid;
    }

    /// <summary>A section's title over its card (set 8's <c>.gh</c>): semibold, 8 over the card, 2 in.</summary>
    public static TextBlock SectionTitle(string words)
    {
        var title = Look.Words(words, semibold: true, wrap: false);
        title.Margin = new Thickness(2, 0, 0, 8);
        return title;
    }

    // ------------------------------------------------------------------ a provider's logo, and the product's quiet mark

    private static readonly Dictionary<string, ImageSource?> Logos = new();

    /// <summary>**A provider's real logo on its white tile** (the Mac's <c>CloudMark</c>, FleetMark's <c>CloudLogo</c> bytes
    /// in Assets): a corner of 26 % of its side; Hetzner's red square is the whole tile, any other logo 65 % of it.</summary>
    public static Border CloudTile(CloudProvider provider, double side)
    {
        var raw = provider.Raw();
        var full = provider == CloudProvider.Hetzner;
        var tile = new Border
        {
            Width = side,
            Height = side,
            CornerRadius = new CornerRadius(side * 0.26),
            Background = Look.Brush(Color.FromArgb(255, 255, 255, 255)),
            HorizontalAlignment = HorizontalAlignment.Center,
            IsHitTestVisible = false,
        };
        if (Logo(raw) is { } image)
        {
            double logo = full ? side : side * 0.65;
            tile.Child = new Image { Source = image, Width = logo, Height = logo, Stretch = Stretch.Uniform };
        }
        return tile;
    }

    private static ImageSource? Logo(string name)
    {
        if (Logos.TryGetValue(name, out var known)) return known;
        ImageSource? image = null;
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream($"Founderizer.Windows.Assets.{name}.png");
        if (stream is not null)
        {
            var memory = new MemoryStream();
            stream.CopyTo(memory);
            memory.Position = 0;
            var bitmap = new BitmapImage();
            bitmap.SetSource(memory.AsRandomAccessStream());
            image = bitmap;
        }
        Logos[name] = image;
        return image;
    }

    /// <summary>**The first run's quiet mark** (the Mac's <c>mark</c>: FounderizerMark at 48, its plate white 5 %, its
    /// chevrons white 13 %).</summary>
    public static FrameworkElement QuietMark()
    {
        var mark = ProductMark.Muted(StepLook.Mark);
        mark.HorizontalAlignment = HorizontalAlignment.Center;
        return mark;
    }

    /// <summary>**A server on a card's tile** (picture 9's Other VPS, set 8's <c>.wt</c>): 34, a corner of 9, the surface
    /// and an edge of white 9 %, the server in light grey at 18.</summary>
    public static Border ServerCardTile() => new()
    {
        Width = 34,
        Height = 34,
        CornerRadius = new CornerRadius(9),
        Background = Look.SurfaceBrush,
        BorderBrush = Look.Brush(Look.White(0.09)),
        BorderThickness = new Thickness(1),
        Child = StepMarks.Server(18, Look.Brush(Look.Rgb(0xD0, 0xD0, 0xD0))),
        HorizontalAlignment = HorizontalAlignment.Left,
    };
}

/// <summary>**The field that a key or a token is pasted into, which sends it by itself** (the Mac's <c>PasteField</c>):
/// a paste that the field takes goes at once, and so does Enter; words that it does not take show in its orange edge.
/// The words are the step's own, never in a console's type. The field is emptied the moment it sends, so it shows no
/// character after the press. With <c>ready</c>, words that the field takes stay in it while their step cannot take them
/// (a code while another is on its way: the Mac's <c>send</c> returns before it clears its field), and Enter sends them
/// later.</summary>
internal sealed class PasteField
{
    private readonly Func<string, bool> accepts;
    private readonly Action<string> send;
    private readonly Func<bool>? ready;
    private int length;

    public StepField Field { get; }

    public PasteField(string placeholder, string id, Func<string, bool> accepts, Action<string> send, Func<bool>? ready = null)
    {
        this.accepts = accepts;
        this.send = send;
        this.ready = ready;
        Field = new StepField(placeholder, id);
        Field.Box.TextChanged += (_, _) =>
        {
            var text = Field.Box.Text;
            var grew = text.Length - length;
            length = text.Length;
            var trimmed = text.Trim();
            Field.Wrong = trimmed.Length > 0 && !accepts(trimmed);
            if (grew >= 8 && accepts(trimmed) && ready?.Invoke() != false) Send();
        };
        Field.Box.Loaded += (_, _) => Field.Box.Focus(FocusState.Programmatic);
    }

    /// <summary>Enter: the words go when the field takes them and their step can.</summary>
    public bool Enter()
    {
        if (!accepts(Field.Box.Text.Trim()) || ready?.Invoke() == false) return false;
        Send();
        return true;
    }

    private void Send()
    {
        var text = Field.Box.Text.Trim();
        length = 0;
        Field.Box.Text = "";
        Field.Wrong = false;
        send(text);
    }
}

/// <summary>**A step's field that shows no character** (the Mac's <c>SetupSecureField</c> in step 1's look, the form of
/// set 8's <c>.fld</c>): 380 by 34, WinUI's password box with no button to show the words, the caret's violet line at its
/// foot. <see cref="Take"/> gives what was typed as characters that the caller clears, and empties the field. (WinUI
/// keeps the typed words as a string, which .NET cannot clear: that copy lives until the garbage collector takes it.)</summary>
internal sealed class SecretField : Grid
{
    private readonly Border frame = new() { CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1) };
    private readonly Rectangle focusLine;
    public PasswordBox Box { get; }

    public SecretField(string placeholder, string id)
    {
        Width = StepLook.FieldWidth;
        Height = 34;
        HorizontalAlignment = HorizontalAlignment.Center;
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
        Box = new PasswordBox
        {
            FontSize = StepLook.Text,
            FontFamily = Look.TextFont,
            Padding = new Thickness(0),
            MinHeight = 0,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(11, 1, 11, 0),
            PlaceholderText = placeholder,
            PasswordRevealMode = PasswordRevealMode.Hidden,
            Height = 20,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        // The password box's template keeps WinUI's own height of 32 and sets its words at the top of it: the field's
        // words stand where a step's text field has them.
        Box.Resources["TextControlThemeMinHeight"] = 0d;
        Box.Resources["TextControlThemePadding"] = new Thickness(0);
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
        Box.Loaded += (_, _) => Box.Focus(FocusState.Programmatic);
        Children.Add(frame);
        Children.Add(Box);
        Children.Add(focusLine);
        Paint();
    }

    public bool Focused => Box.FocusState != FocusState.Unfocused;

    /// <summary>What was typed, as characters that the caller gives on and that are cleared there; the field is empty
    /// again. Null for an empty field.</summary>
    public char[]? Take()
    {
        if (Box.Password.Length == 0) return null;
        var typed = Box.Password.ToCharArray();
        Box.Password = "";
        return typed;
    }

    private void Paint()
    {
        bool focused = Focused;
        frame.Background = Look.Brush(focused ? Look.Rgb(0x1E, 0x1E, 0x1E) : Look.White(0.06));
        frame.BorderBrush = Look.FieldEdge(34, focused ? Look.White(0.08) : Look.White(0.45));
        focusLine.Visibility = focused ? Visibility.Visible : Visibility.Collapsed;
    }
}

/// <summary>**Step 1's combo box under a server** (the Mac's <c>FleetSelect</c> with <c>FleetSelectLabel</c>, set 8's
/// <c>.combo</c>): 32 high, 11 in from each side, its words at 13 and Windows' chevron at 10, 10 apart; a press opens
/// Windows' own menu of its choices, the provider's types with their prices first and then the other providers.</summary>
internal sealed class FleetSelect : Button
{
    public sealed record Choice(string Words, string? Detail, bool Chosen, Action Pick, string? Section = null);

    private readonly TextBlock label = Look.Words("", 13, 18, wrap: false);
    private IReadOnlyList<Choice> choices = [];

    public FleetSelect(string id)
    {
        Style = StepControls.Plain;
        CornerRadius = new CornerRadius(4);
        HorizontalAlignment = HorizontalAlignment.Center;
        label.VerticalAlignment = VerticalAlignment.Center;
        var chevron = StepLook.Glyph(SetupParts.ChevronDownGlyph, 10);
        Content = new Border
        {
            Height = 32,
            Padding = new Thickness(11, 0, 11, 0),
            CornerRadius = new CornerRadius(4),
            Background = Look.Brush(Look.White(0.06)),
            BorderBrush = Look.FieldEdge(32, Look.White(0.08), Look.White(0.04)),
            BorderThickness = new Thickness(1),
            Child = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { label, chevron } },
        };
        AutomationProperties.SetAutomationId(this, id);
        Click += (_, _) => Open();
    }

    public void Show(string title, string words, IReadOnlyList<Choice> list)
    {
        label.Text = words;
        choices = list;
        AutomationProperties.SetName(this, words);
        AutomationProperties.SetHelpText(this, title);
    }

    private void Open()
    {
        if (choices.Count == 0) return;
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft };
        string? section = null;
        foreach (var choice in choices)
        {
            if (choice.Section != section)
            {
                if (section is not null) menu.Items.Add(new MenuFlyoutSeparator());
                section = choice.Section;
                if (section is not null) menu.Items.Add(new MenuFlyoutItem { Text = section, IsEnabled = false });
            }
            var item = new ToggleMenuFlyoutItem { Text = choice.Words, IsChecked = choice.Chosen };
            if (choice.Detail is { } detail) item.KeyboardAcceleratorTextOverride = detail;
            var pick = choice.Pick;
            item.Click += (_, _) => pick();
            menu.Items.Add(item);
        }
        menu.ShowAt(this);
    }

    /// <summary>**One server's list** (the Mac's <c>ServerBoxChoice.of</c>): its provider's five cheapest types that fit,
    /// the cheapest first, with the one that the press makes checked (a dearer one takes the fifth's place), then each
    /// other provider, with "asks for its token" where this PC holds none.</summary>
    public static IReadOnlyList<Choice> Of(CloudStep.View cloud, Func<CloudProvider, bool> holds, Action<CloudOffer> choose,
                                           Action<CloudProvider> elsewhere)
    {
        if (cloud.Offer is not { } offer || cloud.Provider is not { } provider) return [];
        var shown = cloud.Choices.Take(5).ToList();
        if (!shown.Contains(offer) && shown.Count > 0) shown[^1] = offer;
        var list = new List<Choice>();
        foreach (var type in shown)
        {
            var chosen = type;
            list.Add(new Choice(type.Choice, type.Amount(), type.Key == offer.Key, () => choose(chosen), provider.Name()));
        }
        foreach (var other in CloudProviders.All.Where(p => p != provider))
        {
            var to = other;
            list.Add(new Choice(other.Name(), holds(other) ? null : SetupViewWords.AsksForToken, false, () => elsewhere(to), SetupViewWords.AnotherProvider));
        }
        return list;
    }
}

/// <summary>**One server's line on the build page** (the Mac's <c>FleetBuildLine</c>, set 8's <c>.bl</c>): 240 wide, its
/// words at 12 and the minutes left after them in the muted colour, the owner's turn in orange with no minutes, and 7
/// under them a bar of four parts of 34 by 3, 4 apart: a part that is done in the words' faded colour, the part that runs
/// in green as far as its steps ended. **The part that runs breathes** (the owner's "Yes, as drawn" of 22 November 2026
/// to F4's picture P7: "each bar fills by the steps that ended, its part in work breathing"): its opacity from 1 to 0.3
/// and back in 0.9 s each way, as the Mac's layer and the PC's <see cref="StepsBar"/> do, at least as wide as it is thick,
/// so a part with no step ended yet still shows that it works; with Windows' animation effects off it stands still. A box
/// with no line keeps the line's room, so the boxes of a row stay level.</summary>
internal sealed class BuildLine : StackPanel
{
    public const double LineWidth = 240, Part = 34, Gap = 4, Thickness = 3;
    private static readonly UISettings Motion = new();
    private readonly TextBlock words = Look.Words(" ", 12, 16, wrap: false);
    private readonly StackPanel bar = new() { Orientation = Orientation.Horizontal, Spacing = Gap, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Rectangle[] fills = new Rectangle[InstallPhases.Names.Count];
    private Storyboard? breath;
    /// <summary>The part that runs, which breathes; null for none (an owner's turn, a ready server, no line).</summary>
    private int? running;
    private bool reduced;

    public BuildLine()
    {
        Width = LineWidth;
        Spacing = 7;
        // A line that leaves the page stops its breath; one that comes back starts it again.
        Loaded += (_, _) => Breathe();
        Unloaded += (_, _) => Rest();
        words.HorizontalAlignment = HorizontalAlignment.Center;
        Children.Add(words);
        for (int i = 0; i < fills.Length; i++)
        {
            fills[i] = new Rectangle { Height = Thickness, RadiusX = 1.5, RadiusY = 1.5, HorizontalAlignment = HorizontalAlignment.Left };
            bar.Children.Add(new Grid
            {
                Width = Part,
                Height = Thickness,
                Children = { new Rectangle { RadiusX = 1.5, RadiusY = 1.5, Fill = Look.Brush(Look.White(0.10)) }, fills[i] },
            });
        }
        Children.Add(bar);
    }

    public void Show(FleetBuildRow? row)
    {
        Opacity = row is null ? 0 : 1;
        words.Inlines.Clear();
        if (row?.Words is { } said)
        {
            words.Inlines.Add(new Run { Text = said, Foreground = row.OwnersTurn ? Look.Orange : Look.Text });
            if (row.Minutes is { } minutes && !row.OwnersTurn)
                words.Inlines.Add(new Run { Text = " · " + SetupViewWords.Minutes(minutes), Foreground = Look.Muted });
        }
        else words.Inlines.Add(new Run { Text = " " });
        bar.Opacity = row?.Parts is null ? 0 : 1;
        // The part that runs: the first that is not full, while the row is no owner's turn (the Mac's `running`).
        int? runs = null;
        if (row is { OwnersTurn: false, Parts: { } all })
            for (int i = 0; i < all.Count && runs is null; i++)
                if (all[i] < 1) runs = i;
        for (int i = 0; i < fills.Length; i++)
        {
            double share = row?.Parts is { } parts && i < parts.Count ? Math.Clamp(parts[i], 0, 1) : 0;
            fills[i].Width = i == runs ? Math.Max(Thickness, Part * share) : Part * share;
            fills[i].Fill = share >= 1 ? Look.Brush(Color.FromArgb((byte)Math.Round(0.62 * 255), 0xE6, 0xE6, 0xE6)) : Look.Green;
        }
        var still = !Motion.AnimationsEnabled;
        if (runs != running || still != reduced)
        {
            Rest();
            running = runs;
            reduced = still;
            if (IsLoaded) Breathe();
        }
        AutomationProperties.SetName(this, row?.Words ?? "");
        AutomationProperties.SetAccessibilityView(this, row?.Words is null
            ? Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw : Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Content);
    }

    /// <summary>The breath of the part that runs, unless Windows' animation effects are off.</summary>
    private void Breathe()
    {
        if (breath is not null || running is not { } at || at >= fills.Length || reduced) return;
        var animation = new DoubleAnimation
        {
            From = 1,
            To = 0.3,
            Duration = TimeSpan.FromSeconds(0.9),
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        };
        Storyboard.SetTarget(animation, fills[at]);
        Storyboard.SetTargetProperty(animation, "Opacity");
        breath = new Storyboard();
        breath.Children.Add(animation);
        breath.Begin();
    }

    /// <summary>The breath stops: the line left the page, or another part runs.</summary>
    private void Rest()
    {
        breath?.Stop();
        breath = null;
    }
}

/// <summary>**The fleet's servers, each a box with what runs on it** (the Mac's <c>ServerBoxes</c> before a team exists,
/// set 8's <c>.boxes</c>), with under each box either nothing, its line on the build page (<see cref="BuildLine"/>), or
/// its choice: why it was refused, Hetzner's own way to more servers, its combo box and its press. A box with a choice
/// has its edge in dots (a server that the press makes); any other has the edge of white 10 %.</summary>
internal sealed class ServerBoxes : StackPanel
{
    /// <summary>One box's choice (the Mac's <c>ServerBoxChoice</c>).</summary>
    public sealed record BoxChoice(FleetSelect Select, string? Why = null, Button? Press = null, FrameworkElement? More = null);

    private readonly List<BuildLine> lines = [];

    public ServerBoxes()
    {
        Orientation = Orientation.Horizontal;
        Spacing = 10;
        HorizontalAlignment = HorizontalAlignment.Center;
    }

    /// <summary>Draws the boxes of <paramref name="step"/> for a manager of that name. <paramref name="rows"/>: the build
    /// page's lines, by place (a box with none keeps the line's room); <paramref name="choices"/>: a choice by place.</summary>
    public void Draw(ServersStep step, string managerName, string shown, IReadOnlyList<FleetBuildRow?>? rows,
                     IReadOnlyList<BoxChoice?>? choices)
    {
        // A page's own controls (its combo boxes and presses) come back in the new columns: each leaves its old one first.
        foreach (var old in Children.OfType<Panel>()) old.Children.Clear();
        Children.Clear();
        lines.Clear();
        var servers = ServersSketch.Servers(step);
        for (int i = 0; i < servers.Count; i++)
        {
            var choice = choices is not null && i < choices.Count ? choices[i] : null;
            var column = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Top };
            column.Children.Add(Box(servers[i], managerName, shown, dotted: choice is not null, least: rows is not null ? 240 : 236));
            if (rows is not null)
            {
                var line = new BuildLine { HorizontalAlignment = HorizontalAlignment.Center };
                line.Show(i < rows.Count ? rows[i] : null);
                lines.Add(line);
                column.Children.Add(line);
            }
            if (choice is not null)
            {
                if (choice.Why is { } why)
                {
                    var words = Look.Words(why, 12, 16, Look.Muted);
                    words.TextAlignment = TextAlignment.Center;
                    words.HorizontalAlignment = HorizontalAlignment.Center;
                    words.MaxWidth = BuildLine.LineWidth;
                    column.Children.Add(words);
                }
                if (choice.More is { } more) column.Children.Add(more);
                column.Children.Add(choice.Select);
                if (choice.Press is { } press) column.Children.Add(press);
            }
            Children.Add(column);
        }
    }

    /// <summary>The lines again, with no box drawn anew (the minutes every 20 seconds).</summary>
    public void Lines(IReadOnlyList<FleetBuildRow?> rows)
    {
        for (int i = 0; i < lines.Count; i++) lines[i].Show(i < rows.Count ? rows[i] : null);
    }

    private static Grid Box(IReadOnlyList<ServersSketch.Part> parts, string agentName, string shown, bool dotted, double least)
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
        var box = new Grid { MinWidth = least, VerticalAlignment = VerticalAlignment.Top };
        box.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(6),
            Background = Look.Brush(Look.White(0.05)),
            BorderBrush = dotted ? null : Look.Brush(Look.White(0.10)),
            BorderThickness = new Thickness(dotted ? 0 : 1),
        });
        if (dotted)
            box.Children.Add(new Rectangle
            {
                RadiusX = 6,
                RadiusY = 6,
                Stroke = Look.Brush(Look.White(0.32)),
                StrokeThickness = 1.5,
                StrokeDashArray = new DoubleCollection { 0.01, 2 },
                StrokeDashCap = PenLineCap.Round,
            });
        box.Children.Add(new StackPanel { Padding = new Thickness(10, 10, 10, 12), Spacing = 10, Children = { kind, tiles } });
        AutomationProperties.SetName(box, SetupViewWords.AServer);
        return box;
    }
}
