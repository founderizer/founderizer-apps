using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Marks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace Founderizer.Windows.Pages;

/// <summary>A page of the content area: the page of the history that it shows, and its drawing of each new state.</summary>
internal interface IPageView
{
    FrameworkElement View { get; }
    void Show(StoreState state, DateTimeOffset now, bool reduceMotion);

    /// <summary>The line over the page when the page puts it over its main column itself (a chat and a task, beside
    /// their panel); null when the window puts it over the whole page.</summary>
    LineBand? Band => null;

    /// <summary>The request line when the page puts it over its own composer; null when the window puts it at the foot
    /// of the page.</summary>
    PendingBarView? Bar => null;
}

/// <summary>A page with the line over it: the line's row, and the page under it, pushed down by the line's height.</summary>
internal static class Banded
{
    public static Grid Wrap(UIElement page, LineBand band, PendingBarView? bar = null)
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(band);
        Grid.SetRow((FrameworkElement)page, 1);
        grid.Children.Add(page);
        if (bar is not null)
        {
            Grid.SetRow(bar, 2);
            grid.Children.Add(bar);
        }
        return grid;
    }
}

/// <summary>One agent's chat with its panel, as pictures 1 and 2 draw it (the Mac's ManagerView and AgentStatusPanel):
/// the pill over the chat, the chat at its end with its top faded under the pill, the stamps, his bubbles, the replies,
/// the request cards in their places, the "Thinking" line, the composer, and the panel at the right. The rows are
/// virtualized, and a new state changes only the rows that changed.
///
/// The states of the second set: the line over the chat (9a), an answered card folded to two lines (16), "Earlier
/// messages" over the newest items of a long chat, and the request line of a write that waits over the composer (14).</summary>
internal sealed class ChatPage : Grid, IPageView, IThreadContext
{
    private readonly string agent;
    private readonly IFleetSource source;
    private readonly PageServices services;
    private readonly Dictionary<long, ImageSource?> pictures = new();
    private readonly HashSet<long> reading = new();
    private readonly Dictionary<(string, long), ImageSource?> thumbs = new();
    private readonly LineBand band;
    private readonly PendingBarView bar;
    private readonly ThreadList thread;
    private readonly Button latest;
    private readonly TextBlock note = Look.Words("", 12, 16, Look.Muted);
    private readonly Border pill;
    private readonly AgentGlyph pillMark = new() { Side = 22, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock pillWords = Look.Words("", semibold: true, wrap: false);
    private readonly Field composer;
    private readonly AgentPanelView panel = new();
    private StoreState state = new();
    private DateTimeOffset now;
    private bool loaded;
    private int settle;
    /// <summary>The plus's words: the library's ComposerModel has none, so the answer box's (AnswerBoxModel.PlusHover).</summary>
    private const string PlusWords = "Send a picture, a PDF, a ZIP or a text file with this message";

    // The scroll reading of slice 1.3 scrolls the whole long chat, end to start: all its items show at once there.
    private int shown = Proofs.Variable("FOUNDERIZER_READING") == "long-chat" ? int.MaxValue : Screens.EarlierStep;

    public ChatPage(string agent, PageServices services)
    {
        this.agent = agent;
        this.services = services;
        source = services.Source;
        band = new LineBand(services);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        thread = new ThreadList(this, new Thickness(0, 70, 0, 12));
        thread.Scroll.Margin = new Thickness(0, 0, 0, 64);

        // The top of the chat fades out under the pill: the canvas from 0 to 20, then to clear at 72 (topFade).
        var fade = new Rectangle { Height = 72, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false };
        var gradient = new LinearGradientBrush { StartPoint = new(0, 0), EndPoint = new(0, 1) };
        gradient.GradientStops.Add(new GradientStop { Color = Look.Canvas, Offset = 0 });
        gradient.GradientStops.Add(new GradientStop { Color = Look.Canvas, Offset = 20.0 / 72 });
        gradient.GradientStops.Add(new GradientStop { Color = Color.FromArgb(0, 0x19, 0x19, 0x19), Offset = 1 });
        fade.Fill = gradient;

        pill = new Border
        {
            Height = 32,
            Padding = new Thickness(4, 0, 13, 0),
            Margin = new Thickness(0, 14, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Background = Look.SurfaceBrush,
            BorderBrush = Look.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(15),
            Child = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7, Children = { pillMark, pillWords } },
        };
        pillWords.VerticalAlignment = VerticalAlignment.Center;
        var shadow = Shadows.Under(pill, Look.Surface, 15, 10, 3, 0.35f);

        composer = new Field(40, 14, 42)
        {
            MaxWidth = 692,
            Margin = new Thickness(23.5, 0, 23.5, 12),
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        composer.Typed += text => source.SetDraft(agent, text);
        composer.PlusPressed += AddFiles;
        composer.Sent += () =>
        {
            _ = source.SendMessageAsync(agent);
            composer.Clear();
        };

        // The request line stands over the composer, and the chat ends over it.
        bar = new PendingBarView(services) { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 64) };
        bar.SizeChanged += (_, _) => Lift();
        bar.RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => Lift());

        // "Latest" while he reads above the end (the Mac's jump to the newest), and the composer's note over it.
        latest = Buttons.Plain("");
        latest.HorizontalAlignment = HorizontalAlignment.Center;
        latest.VerticalAlignment = VerticalAlignment.Bottom;
        latest.Margin = new Thickness(0, 0, 0, 76);
        latest.Visibility = Visibility.Collapsed;
        latest.Click += (_, _) => thread.Scroll.ChangeView(null, thread.Scroll.ScrollableHeight, null, false);
        thread.Scroll.ViewChanged += (_, _) => latest.Visibility = thread.AtEnd || thread.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        note.MaxWidth = 692;
        note.Margin = new Thickness(23.5 + 2, 0, 23.5, 58);
        note.VerticalAlignment = VerticalAlignment.Bottom;
        note.Visibility = Visibility.Collapsed;

        var chat = new Grid { Children = { thread.Scroll, fade, shadow, pill, latest, bar, note, composer } };
        Children.Add(Banded.Wrap(chat, band));
        SetColumn(panel, 1);
        Children.Add(panel);

        // The chat opens at its end, and stays there while new rows come, unless he scrolled up.
        thread.Scroll.LayoutUpdated += (_, _) =>
        {
            if (settle <= 0) return;
            settle--;
            thread.ToEnd();
        };
    }

    public FrameworkElement View => this;

    public LineBand Band => band;

    public PendingBarView Bar => bar;

    public string Agent => agent;

    /// <summary>The chat's scroll, for the scroll reading (Readings.ScrollWhenAsked).</summary>
    public ScrollViewer Scroll => thread.Scroll;

    public void Show(StoreState next, DateTimeOffset at, bool reduceMotion)
    {
        state = next;
        now = at;
        var model = Screens.Chat(next, agent, at, ScreenContext.Local, reduceMotion, shown);
        bar.Show(Screens.PendingBar(next, at));
        pillMark.Mark = model.PillMark;
        pillWords.Text = model.Label;
        panel.Show(model.Panel);

        composer.Visibility = model.Composer.ShowsField ? Visibility.Visible : Visibility.Collapsed;
        composer.Show(model.Composer.Placeholder, model.Composer.ShowsPlus, model.Composer.CanSend);
        composer.Hovers(PlusWords, model.Composer.SendHover);
        ((TextBlock)((Border)latest.Content).Child).Text = model.LatestWords;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(latest, model.LatestWords);
        note.Text = model.Composer.Note ?? "";
        note.Foreground = model.Composer.NoteIsWarning ? Look.Orange : Look.Muted;
        note.Visibility = model.Composer.Note is null ? Visibility.Collapsed : Visibility.Visible;
        composer.ShowChips(model.Composer.Chips.Select(chip => (UIElement)new FileChipView(chip, Chip, Thumb(chip))).ToList());
        var tint = Look.Tint(MarkLook.Of(next.MarkOf(agent), AgentState.Online, moves: false));
        composer.Tint(tint.Fill, tint.Ink);
        if (!loaded) composer.Load(model.Composer.Draft);

        bool atEnd = !loaded || thread.AtEnd;
        thread.Show(Rows(model, next, at));
        if (atEnd && thread.Count > 0) settle = loaded ? 2 : 6;
        loaded = true;
    }

    /// <summary>The model's rows as the thread's rows, with the room of picture 1 between them.</summary>
    private List<ThreadItem> Rows(ChatModel model, StoreState s, DateTimeOffset at)
    {
        var rows = new List<ThreadItem>();
        RowKind? previous = null;
        void Add(string key, RowKind kind, object row)
        {
            rows.Add(new ThreadItem(key, kind, ThreadList.GapAfter(previous, 28), row));
            previous = kind;
        }
        if (model.Earlier is { } earlier) Add("earlier", RowKind.Earlier, earlier);
        foreach (var row in model.Rows)
        {
            switch (row.Kind)
            {
                case ChatRowKind.Stamp: Add(row.Key, RowKind.Stamp, row); break;
                case ChatRowKind.Message:
                    Add(row.Key, RowKind.Own, new OwnRow(row, ValueList.Of(row.Files.Select(f => Screens.Tile(s, f, at) with
                    {
                        // A picture whose bytes came draws whole: the row draws again then.
                        Reading = !pictures.ContainsKey(f.Id) && reading.Contains(f.Id),
                    }))));
                    break;
                case ChatRowKind.Reply: Add(row.Key, RowKind.Reply, row); break;
                case ChatRowKind.Request when row.Request is not null: Add(row.Key, RowKind.Request, row); break;
            }
        }
        if (model.Waiting is { Shows: true } waiting)
            Add("waiting", RowKind.Waiting, new WaitingRow(waiting.Line, model.WaitingMark));
        return rows;
    }

    /// <summary>A chip's small picture: the bytes he picked, or, for a file on the hub (after a start), its bytes there.</summary>
    private ImageSource? Thumb(FileChip chip)
    {
        if (!chip.IsPicture) return null;
        if (thumbs.TryGetValue((chip.File.Name, chip.File.Size), out var picked)) return picked;
        if (chip.File.File is not { } file) return null;
        if (pictures.TryGetValue(file.Id, out var image)) return image;
        if (reading.Add(file.Id)) _ = LoadAsync(file);
        return null;
    }

    /// <summary>A picture of a message: its image once its bytes came; the first ask starts its read.</summary>
    public ImageSource? Picture(FileTile tile)
    {
        if (pictures.TryGetValue(tile.File.Id, out var image)) return image;
        if (tile.IsPicture && reading.Add(tile.File.Id)) _ = LoadAsync(tile.File);
        return null;
    }

    private async System.Threading.Tasks.Task LoadAsync(MessageAttachment file)
    {
        try
        {
            pictures[file.Id] = await Files.Picture(await source.FileAsync(file));
        }
        catch (Exception e) when (e is HubException or System.IO.IOException or System.Runtime.InteropServices.COMException)
        {
            // The store keeps it as not loaded (state.FilesUnloaded): its tile says so, with Read again.
        }
        reading.Remove(file.Id);
        Show(state, DateTimeOffset.UtcNow, false);
    }

    public async void OpenFile(FileTile tile)
    {
        try
        {
            Files.Open(tile.File, await source.FileAsync(tile.File));
        }
        catch (Exception e) when (e is HubException or System.IO.IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            Readings.Note("open file: " + e.Message);
        }
    }

    public void ReadAgain(FileTile tile)
    {
        pictures.Remove(tile.File.Id);
        if (reading.Add(tile.File.Id)) _ = LoadAsync(tile.File);
    }

    /// <summary>The plus: Windows' picker, and each file goes to the composer (the store sends it up).</summary>
    private async void AddFiles()
    {
        List<(string Name, byte[] Bytes, string? Mime)> picked;
        try
        {
            picked = await Files.Pick(services.Window());
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            Readings.Note("pick: " + e.Message);
            return;
        }
        foreach (var (name, bytes, mime) in picked)
        {
            if (mime?.StartsWith("image/", StringComparison.Ordinal) == true)
                thumbs[(name, bytes.LongLength)] = await Files.Picture(bytes);
            var refused = await source.AddFileAsync("agent:" + agent, name, bytes, mime);
            if (refused is not null) Readings.Note("add file: " + refused);
        }
    }

    /// <summary>A chip's cross (false) or its Send it up again (true).</summary>
    private void Chip(FileChip chip, bool again)
    {
        if (again) _ = source.UploadAsync("agent:" + agent, chip.File.RequestId);
        else source.RemoveFile("agent:" + agent, chip.File.RequestId);
    }

    /// <summary>The thread ends over the request line while it stands.</summary>
    private void Lift() => thread.Scroll.Margin = new Thickness(0, 0, 0,
        64 + (bar.Visibility == Visibility.Visible ? bar.ActualHeight : 0));

    /// <summary>"Earlier messages": as many items again (the Mac's 60).</summary>
    public void ShowEarlier()
    {
        shown += Screens.EarlierStep;
        Show(state, DateTimeOffset.UtcNow, false);
    }

    public bool CanSendAnswer(RequestCard card) =>
        AnswerBoxModel.CanSend(state, now, card.Answer.Draft, card.Answer.Files.Count);

    public void Press(long need, int choice) => source.Press(need, choice);

    public void Type(long need, string text) => source.SetAnswerDraft(need, text);

    public void Answer(long need) => _ = source.AnswerAsync(need);

    private readonly HashSet<(long, string)> openParts = new();

    public void Tick(long need, IReadOnlyCollection<int> choices) => _ = source.TickAsync(need, choices);



    public bool CanSendTicks(int ticked) => OptionsModel.CanSendTicks(state, DateTimeOffset.UtcNow, ticked);

    public async void AddFiles(long need)
    {
        try
        {
            foreach (var (name, bytes, mime) in await Files.Pick(services.Window()))
                if (await source.AddFileAsync("need:" + need, name, bytes, mime) is { } refused) Readings.Note("add file: " + refused);
        }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            Readings.Note("pick: " + e.Message);
        }
    }

    public void Chip(long need, FileChip chip, bool again)
    {
        if (again) _ = source.UploadAsync("need:" + need, chip.File.RequestId);
        else source.RemoveFile("need:" + need, chip.File.RequestId);
    }

    public bool IsOpen(long need, string part) => openParts.Contains((need, part));

    public void SetOpen(long need, string part, bool open)
    {
        if (open) openParts.Add((need, part));
        else openParts.Remove((need, part));
    }
}
