using System;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Page = Founderizer.Core.Page;

namespace Founderizer.Windows.Pages;

/// <summary>What a page may ask of the window: the store, a move to another page, and Needs you at one request.</summary>
internal sealed record PageServices(IFleetSource Source, Action<Page> Go, Action<long> OpenNeed, Func<IntPtr> Window);

/// <summary>A message's files on the PC: the pictures' bytes as images, a file opened in its own app (through a copy in
/// the user's temporary folder), and the files that he picks with Windows' picker.</summary>
internal static class Files
{
    public static async System.Threading.Tasks.Task<ImageSource?> Picture(byte[] bytes)
    {
        if (bytes.Length == 0) return null;
        var image = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
        using var stream = new System.IO.MemoryStream(bytes);
        await image.SetSourceAsync(System.IO.WindowsRuntimeStreamExtensions.AsRandomAccessStream(stream));
        return image;
    }

    /// <summary>Opens a file of a message in the app that Windows gives its kind.</summary>
    public static void Open(MessageAttachment file, byte[] bytes)
    {
        var folder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "Founderizer", file.Id.ToString(System.Globalization.CultureInfo.InvariantCulture));
        System.IO.Directory.CreateDirectory(folder);
        var name = string.Concat(file.Name.Select(c => System.IO.Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));
        var path = System.IO.Path.Combine(folder, name.Length == 0 ? "file" : name);
        System.IO.File.WriteAllBytes(path, bytes);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true })?.Dispose();
    }

    /// <summary>Windows' picker for one or more files; each with its name, bytes and kind.</summary>
    public static async System.Threading.Tasks.Task<System.Collections.Generic.List<(string Name, byte[] Bytes, string? Mime)>> Pick(IntPtr window)
    {
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
        picker.FileTypeFilter.Add("*");
        var picked = await picker.PickMultipleFilesAsync();
        var files = new System.Collections.Generic.List<(string, byte[], string?)>();
        foreach (var file in picked)
        {
            var buffer = await global::Windows.Storage.FileIO.ReadBufferAsync(file);
            var bytes = new byte[buffer.Length];
            using (var reader = global::Windows.Storage.Streams.DataReader.FromBuffer(buffer)) reader.ReadBytes(bytes);
            files.Add((file.Name, bytes, string.IsNullOrEmpty(file.ContentType) ? null : file.ContentType));
        }
        return files;
    }
}

/// <summary>The widths of the pane and of the panel beside a chat or a task (picture 11 of the second set, the Mac's
/// FleetStyle): 320 and 380 in a window of 1440 or wider; below it both give up width before the chat, down to 260 and
/// 320 at the least window of 960, where the chat keeps its 380.</summary>
internal static class Widths
{
    public const double LeastWidth = 960, LeastHeight = 560;

    public static double Pane { get; private set; } = 320;
    public static double Panel { get; private set; } = 380;

    public static event Action? Changed;

    public static void For(double window)
    {
        double t = Math.Clamp((1440 - window) / (1440 - LeastWidth), 0, 1);
        double pane = 320 - 60 * t, panel = 380 - 60 * t;
        if (pane == Pane && panel == Panel) return;
        Pane = pane;
        Panel = panel;
        Changed?.Invoke();
    }

    /// <summary>Keeps an element's width at the panel's while it is in the window.</summary>
    public static void FollowPanel(FrameworkElement element)
    {
        void Set() => element.Width = Panel;
        Set();
        element.Loaded += (_, _) => { Changed += Set; Set(); };
        element.Unloaded += (_, _) => Changed -= Set;
    }
}

/// <summary>Windows' button (the pictures' ".btn"): 32 high, 11 in from each side, Windows' fill and its edge with the
/// lighter bottom line, corners of 4; words, or a mark and words.</summary>
internal static class Buttons
{
    public static Button Plain(string words, Icon? icon = null, Brush? ink = null)
    {
        var label = Look.Words(words, brush: ink, wrap: false);
        label.VerticalAlignment = VerticalAlignment.Center;
        UIElement content = label;
        if (icon is { } mark)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            var glyph = Icons.Of(mark, ink ?? Look.Text);
            glyph.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(glyph);
            row.Children.Add(label);
            content = row;
        }
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            VerticalAlignment = VerticalAlignment.Center,
            Content = Face(content),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, words);
        return button;
    }

    /// <summary>The face of Windows' button around any content.</summary>
    public static Border Face(UIElement content) => new()
    {
        Height = 32,
        Padding = new Thickness(11, 0, 11, 0),
        CornerRadius = new CornerRadius(4),
        Background = Look.Brush(Look.White(0.06)),
        BorderBrush = Look.FieldEdge(32, Look.White(0.08), Look.White(0.04)),
        BorderThickness = new Thickness(1),
        Child = content,
    };

    /// <summary>A square button that holds only a mark (Stop of a paused task, a file's cross), with its hover words.</summary>
    public static Button IconOnly(Icon icon, string hover, double side = 32, double size = 16, Brush? ink = null, bool face = true)
    {
        var glyph = Icons.Of(icon, ink ?? Look.Text, size);
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            VerticalAlignment = VerticalAlignment.Center,
            Content = face ? new Border
            {
                Width = side,
                Height = side,
                CornerRadius = new CornerRadius(4),
                Background = Look.Brush(Look.White(0.06)),
                BorderBrush = Look.FieldEdge(side, Look.White(0.08), Look.White(0.04)),
                BorderThickness = new Thickness(1),
                Child = glyph,
            } : new Grid { Width = side, Height = side, Children = { glyph } },
        };
        ToolTipService.SetToolTip(button, hover);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, hover);
        return button;
    }
}

/// <summary>The line over a page (pictures 9a and 9b: the iPhone's HubBanner in the Mac's BandNotice): 40 high, orange
/// at 10 % over the main view only, the warning mark, the line's words, and its one way on, Settings or Try again; the
/// page under it moves down by its height. Collapsed while the hub reads as usual. Longer words (another language) take
/// a second line, and the band grows.</summary>
internal sealed class LineBand : Grid
{
    private readonly PageServices services;
    private readonly TextBlock words = Look.Words("");
    private readonly Button action;
    private readonly TextBlock actionWords;
    private ConnectionLine? shown;

    public LineBand(PageServices services)
    {
        this.services = services;
        // 40 high with one line: the button's 32 and 4 over and under it; a second line of words makes it grow.
        MinHeight = 40;
        Padding = new Thickness(24, 4, 24, 4);
        ColumnSpacing = 10;
        Background = Look.Brush(global::Windows.UI.Color.FromArgb(26, 0xFF, 0x9F, 0x0A));
        BorderBrush = Look.Line;
        BorderThickness = new Thickness(0, 0, 0, 1);
        Visibility = Visibility.Collapsed;
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var mark = Icons.Of(Icons.Warning, Look.Orange);
        mark.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(mark);
        words.VerticalAlignment = VerticalAlignment.Center;
        SetColumn(words, 1);
        Children.Add(words);
        action = Buttons.Plain("");
        actionWords = (TextBlock)((Border)action.Content).Child;
        action.Click += (_, _) => Act();
        SetColumn(action, 2);
        Children.Add(action);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(words, "Line");
    }

    public void Show(ConnectionLine? line)
    {
        shown = line;
        Visibility = line is null ? Visibility.Collapsed : Visibility.Visible;
        if (line is null) return;
        words.Text = line.Words;
        actionWords.Text = line.ActionWords;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(action, line.ActionWords);
        action.Visibility = line.ShowsAction ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Act()
    {
        if (shown is not { } line) return;
        if (line.ActionIsSettings) services.Go(Page.Settings);
        else _ = services.Source.RefreshAsync();
    }
}

/// <summary>The request line of a write that waits (picture 14, the Mac's pendingBar), over the composer, or at the foot
/// of a page that has none: on the surface with a hairline over it, the state in orange, why, whose hub it belongs to,
/// the request's words, its files, and each way on that can act now (Refresh receipt, Discard, Try again).</summary>
internal sealed class PendingBarView : Grid
{
    private readonly PageServices services;
    private readonly TextBlock state = Look.Words("", 12, 16, Look.Orange, semibold: true);
    private readonly TextBlock why = Look.Words("", 12, 16);
    private readonly TextBlock otherHub = Look.Words("", 12, 16);
    private readonly TextBlock text = Look.Words("", 12, 16);
    private readonly StackPanel files = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly StackPanel actions = new() { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 2, 0, 0) };
    private PendingBarModel? shown;

    public PendingBarView(PageServices services)
    {
        this.services = services;
        Background = Look.SurfaceBrush;
        BorderBrush = Look.Line;
        BorderThickness = new Thickness(0, 1, 0, 0);
        Padding = new Thickness(12);
        Visibility = Visibility.Collapsed;
        text.MaxLines = 2;
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(state, "PendingState");
        Children.Add(new StackPanel { Spacing = 8, Children = { state, why, otherHub, text, files, actions } });
    }

    public void Show(PendingBarModel? model)
    {
        Visibility = model is null ? Visibility.Collapsed : Visibility.Visible;
        if (model is null || model == shown) { shown = model; return; }
        shown = model;
        state.Text = model.State;
        why.Text = model.Why ?? "";
        why.Visibility = model.Why is null ? Visibility.Collapsed : Visibility.Visible;
        otherHub.Text = model.OtherHub ?? "";
        otherHub.Visibility = model.OtherHub is null ? Visibility.Collapsed : Visibility.Visible;
        text.Text = model.Text;
        text.Visibility = model.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        files.Children.Clear();
        foreach (var chip in model.Files) files.Children.Add(new FileChipView(chip, null));
        files.Visibility = model.Files.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        actions.Children.Clear();
        foreach (var action in model.Actions)
        {
            var button = Buttons.Plain(action.Words);
            var what = action.Action;
            button.Click += (_, _) => Act(what);
            actions.Children.Add(button);
        }
    }

    private void Act(WriteAction action)
    {
        switch (action)
        {
            case WriteAction.RefreshReceipt: _ = services.Source.RefreshAsync(); break;
            case WriteAction.Discard: services.Source.DiscardRefused(); break;
            case WriteAction.TryAgain: _ = services.Source.RetryAsync(); break;
        }
    }
}

/// <summary>A file that he added to a composer (picture 4, the Mac's StagedFilesStrip chip): on the selected fill with a
/// control's corners, its small picture (or its mark), its name and its size or its state, then Send it up again and the
/// cross that takes it out, each only while it can act.</summary>
internal sealed class FileChipView : Grid
{
    public FileChipView(FileChip chip, Action<FileChip, bool>? act, ImageSource? thumb = null)
    {
        Background = Look.SelectBrush;
        CornerRadius = new CornerRadius(4);
        Padding = new Thickness(8, 6, 8, 6);
        MaxWidth = 190;
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        FrameworkElement mark = thumb is not null
            ? new Border
            {
                Width = 26,
                Height = 26,
                CornerRadius = new CornerRadius(4),
                Child = new Image { Source = thumb, Stretch = Stretch.UniformToFill },
            }
            : Icons.Of(Icons.Document, Look.Brush(Look.Accent), 20);
        mark.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(mark);
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(Look.Words(chip.File.Name, 12, 16, wrap: false));
        words.Children.Add(Look.Words(chip.Words, 12, 16, chip.WordsAreWarning ? Look.Orange : Look.Muted, wrap: false));
        Grid.SetColumn(words, 1);
        row.Children.Add(words);
        var tools = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (act is not null && chip.ShowsSendAgain)
        {
            var again = Buttons.IconOnly(Icons.Refresh, chip.SendAgainHover, 20, 12, Look.Muted, face: false);
            again.Click += (_, _) => act(chip, true);
            tools.Children.Add(again);
        }
        if (act is not null && chip.ShowsTakeOut)
        {
            var cross = Buttons.IconOnly(Icons.Dismiss12, chip.TakeOutHover, 20, 12, Look.Muted, face: false);
            cross.Click += (_, _) => act(chip, false);
            tools.Children.Add(cross);
        }
        Grid.SetColumn(tools, 2);
        row.Children.Add(tools);
        Children.Add(row);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, chip.File.Name);
    }
}

/// <summary>A file of a message (picture 4, the Mac's MessageFilesView and PictureTile): a picture whole, at most 373 by
/// 210, with a card's corners; another file on the selected fill with a control's corners, its mark in violet, its name
/// and its size. A press opens it. "Reading…" over a picture whose bytes have not come after a second, and "Not loaded"
/// with Read again when its read failed.</summary>
internal sealed class FileTileView : Grid
{
    public FileTileView(FileTile tile, ImageSource? picture, Action<FileTile> open, Action<FileTile> again)
    {
        HorizontalAlignment = HorizontalAlignment.Right;
        UIElement face;
        if (tile.IsPicture && picture is not null)
        {
            face = new Border
            {
                CornerRadius = new CornerRadius(8),
                MaxWidth = 373,
                MaxHeight = 210,
                Child = new Image { Source = picture, Stretch = Stretch.Uniform, MaxWidth = 373, MaxHeight = 210 },
            };
        }
        else if (tile.IsPicture)
        {
            var words = Look.Words(tile.Reading ? tile.ReadingWords : tile.Words, 12, 16, tile.WordsAreWarning ? Look.Orange : Look.Muted, wrap: false);
            words.HorizontalAlignment = HorizontalAlignment.Center;
            words.VerticalAlignment = VerticalAlignment.Center;
            var place = new Grid { Width = 373, Height = 210, CornerRadius = new CornerRadius(8), Background = Look.SelectBrush, Children = { words } };
            if (tile.ShowsReadAgain)
            {
                // A mark with the library's hover ("Read spring-sale.png again"), as the Mac's arrow.
                var read = Buttons.IconOnly(Icons.Refresh, tile.ReadAgainHover);
                read.HorizontalAlignment = HorizontalAlignment.Center;
                read.VerticalAlignment = VerticalAlignment.Bottom;
                read.Margin = new Thickness(0, 0, 0, 16);
                read.Click += (_, _) => again(tile);
                place.Children.Add(read);
            }
            face = place;
        }
        else
        {
            var row = new Grid { ColumnSpacing = 9, MinWidth = 180, Padding = new Thickness(10, 7, 10, 7), CornerRadius = new CornerRadius(4), Background = Look.SelectBrush };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var mark = Icons.Of(Icons.Document, Look.Brush(Look.Accent), 20);
            mark.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(mark);
            var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            words.Children.Add(Look.Words(tile.Name, 12, 16, wrap: false));
            words.Children.Add(Look.Words(tile.Words, 12, 16, tile.WordsAreWarning ? Look.Orange : Look.Muted, wrap: false));
            Grid.SetColumn(words, 1);
            row.Children.Add(words);
            face = row;
        }
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Right,
            Content = face,
        };
        ToolTipService.SetToolTip(button, tile.Hover);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tile.Name);
        button.Click += (_, _) => open(tile);
        Children.Add(button);
    }
}
