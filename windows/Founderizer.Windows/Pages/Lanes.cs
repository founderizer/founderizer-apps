using System;
using System.Collections.Generic;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Founderizer.Windows.Pages;

/// <summary>One card of a lane, from Needs you (a request, or a task that only he can move) or from the board (a task):
/// its title, what the task waits for from him in orange, the agent's mark at 16 and role, the orange hourglass while
/// an agent's work waits on the request, and whether it is the request at hand.</summary>
internal sealed record LaneCard(string Key, long Id, bool IsTask, string Title, string? OwnerLine, long? OwnerLineNeed,
                                MarkLook Mark, string AgentLabel, bool Waits, string WaitWords, bool Selected, string? Why = null,
                                string? Hover = null)
{
    public static LaneCard Of(NeedCardRow row) => new(row.Key, row.Id, row.IsTask, row.Title, row.OwnerLine, null, row.Mark,
                                                      row.AgentLabel, row.Waits, row.WaitWords, row.Selected);

    public static LaneCard Of(TaskCardRow row) => new(row.Key, row.Id, true, row.Title, row.OwnerLine, row.OwnerLineNeed,
                                                      row.Mark, row.AgentLabel, false, "", false, row.Why,
                                                      row.Hover.Length == 0 ? null : row.Hover);
}

/// <summary>What a press on a card does: a request comes to hand, a task's page opens, and the orange line of a task
/// that waits on a request opens that request.</summary>
internal interface ILaneContext
{
    void Open(LaneCard card);
    void OpenNeed(long need);
}

/// <summary>A lane's card as pictures 3 and 4a draw it (NeedCard, ActivityCard): the surface, an edge of 8 %, a corner of
/// 8; the card of the request at hand a little lighter, with a stronger edge (BoardCardLook).</summary>
internal sealed class LaneCardView : HeldView<LaneCard>
{
    private readonly ILaneContext context;
    private readonly Border card;
    private readonly Button button;
    private readonly TextBlock title = Look.Words("", semibold: true);
    private readonly TextBlock ownerLine = Look.Words("", 12, 16, Look.Orange);
    private readonly TextBlock why = Look.Words("", 12, 16, Look.Muted);
    private readonly AgentGlyph mark = new() { Side = 16, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock agent = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly FrameworkElement hourglass = Icons.Of(Icons.Hourglass, Look.Orange);
    private LaneCard? shown;

    public LaneCardView(ILaneContext context)
    {
        this.context = context;
        agent.VerticalAlignment = VerticalAlignment.Center;
        hourglass.HorizontalAlignment = HorizontalAlignment.Right;
        hourglass.VerticalAlignment = VerticalAlignment.Center;
        hourglass.IsHitTestVisible = true;
        // Why a task waits stands at the end of its agent's line, 4 from the role at least (the Mac's ActivityCard):
        // "Until 16:00" for a task its agent parked, else its state word ("Waiting for Fleet Manager", "Paused").
        why.VerticalAlignment = VerticalAlignment.Center;
        why.HorizontalAlignment = HorizontalAlignment.Right;
        why.TextWrapping = TextWrapping.NoWrap;
        why.TextTrimming = TextTrimming.CharacterEllipsis;
        why.Margin = new Thickness(4, 0, 0, 0);
        var who = new Grid
        {
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
            Children =
            {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { mark, agent } },
                hourglass,
            },
        };
        Grid.SetColumn(why, 1);
        who.Children.Add(why);
        ownerLine.Tapped += OwnerLineTapped;
        card = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14, 12, 14, 12),
            Child = new StackPanel { Spacing = 8, Children = { title, ownerLine, who } },
        };
        button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            CornerRadius = new CornerRadius(8),
            Content = card,
        };
        button.Click += (_, _) => { if (shown is not null) context.Open(shown); };
        Children.Add(button);
        Padding = new Thickness(0, 0, 0, 8);
    }

    protected override void Draw(LaneCard item)
    {
        shown = item;
        title.Text = item.Title;
        ownerLine.Text = item.OwnerLine ?? "";
        ownerLine.Visibility = item.OwnerLine is null ? Visibility.Collapsed : Visibility.Visible;
        // A card's state line on the board (what holds the task), and its words under the pointer.
        why.Text = item.Why ?? "";
        why.Visibility = item.Why is null ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(button, item.Hover);
        mark.Mark = item.Mark;
        agent.Text = item.AgentLabel;
        hourglass.Visibility = item.Waits ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(hourglass, item.Waits ? item.WaitWords : null);
        card.Background = item.Selected ? Look.SelectBrush : Look.SurfaceBrush;
        card.BorderBrush = item.Selected ? Look.Brush(Look.White(0.26)) : Look.CardEdge;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, item.Title);
    }

    private void OwnerLineTapped(object sender, TappedRoutedEventArgs e)
    {
        if (shown?.OwnerLineNeed is not { } need) return;
        e.Handled = true;
        context.OpenNeed(need);
    }
}

/// <summary>A lane: its heading and count (ActivityColumn.title), then its cards in a virtualized list, 10 under the
/// heading and 8 apart.</summary>
internal sealed class LaneView : Grid
{
    private readonly TextBlock title = Look.Words("", semibold: true, wrap: false);
    private readonly TextBlock count = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly KeyedItems<LaneCard> cards = new(card => card.Key);
    private readonly ScrollViewer scroll;
    private readonly StackPanel footer = new();

    public LaneView(ILaneContext context)
    {
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        title.VerticalAlignment = count.VerticalAlignment = VerticalAlignment.Center;
        var heading = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            MinHeight = 28,
            Padding = new Thickness(2, 0, 0, 0),
            Margin = new Thickness(0, 0, 0, 10),
            Children = { title, count },
        };
        Children.Add(heading);
        var repeater = new ItemsRepeater
        {
            Layout = new StackLayout { Spacing = 0 },
            ItemTemplate = new ViewFactory<LaneCard, LaneCardView>(() => new LaneCardView(context)),
            ItemsSource = cards.Items,
        };
        footer.Children.Add(repeater);
        scroll = new ScrollViewer
        {
            Content = footer,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            IsTabStop = false,
        };
        SetRow(scroll, 1);
        Children.Add(scroll);
    }

    /// <summary>A part of the lane under its cards, in the same scroll (the ended rows).</summary>
    public void Footer(FrameworkElement element) => footer.Children.Add(element);

    /// <summary>Room for a lane's other content in place of its cards (the Ended rule).</summary>
    public void Below(FrameworkElement element)
    {
        SetRow(element, 1);
        element.VerticalAlignment = VerticalAlignment.Top;
        Children.Add(element);
    }

    public void Show(string heading, int number, IReadOnlyList<LaneCard> next)
    {
        title.Text = heading;
        count.Text = number.ToString(System.Globalization.CultureInfo.CurrentCulture);
        cards.Show(next);
    }
}

/// <summary>The ended part of a lane (the Mac's endedRows and restRows): the rows that always show, then the row that
/// opens the rest ("2 more", "2 answered") with its chevron, and, opened, the rest by day under each day's heading.
/// Both lists are virtualized and keyed, as the cards are: a new model draws again only the rows that changed, so a row
/// keeps its view and the keyboard's focus, and the open makes only the rows near the view (a week of a busy fleet is
/// hundreds of rows).</summary>
internal sealed class EndedView : StackPanel
{
    private readonly KeyedItems<EndedLine> always = new(line => line.Key);
    private readonly KeyedItems<EndedItem> rest = new(item => item.Key);
    private readonly ItemsRepeater restList;
    private readonly Button more;
    private readonly TextBlock moreWords = Look.Words("", wrap: false, brush: Look.Muted);
    private readonly ContentControl chevron = new() { IsTabStop = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly HashSet<string> opened = new();
    private bool open;
    private IReadOnlyList<(string Day, IReadOnlyList<EndedLine> Rows)> days = [];

    /// <summary><paramref name="openRow"/>: what a press on a row opens, by its id. A press on a row of several tasks
    /// opens or closes its runs instead.</summary>
    public EndedView(Action<long> openRow)
    {
        void Press(EndedLine line)
        {
            if (line.Runs is null) { openRow(line.Id); return; }
            if (!opened.Remove(line.Key)) opened.Add(line.Key);
            rest.Show(Items());
        }
        moreWords.VerticalAlignment = VerticalAlignment.Center;
        more = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Left,
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                MinHeight = 32,
                Padding = new Thickness(10, 0, 0, 0),
                Children = { moreWords, chevron },
            },
        };
        more.Click += (_, _) =>
        {
            open = !open;
            DrawRest();
        };
        Children.Add(new ItemsRepeater
        {
            Layout = new StackLayout { Spacing = 0 },
            ItemTemplate = new ViewFactory<EndedLine, EndedLineView>(() => new EndedLineView(Press)),
            ItemsSource = always.Items,
        });
        Children.Add(more);
        restList = new ItemsRepeater
        {
            Layout = new StackLayout { Spacing = 0 },
            ItemTemplate = new ViewFactory<EndedItem, EndedItemView>(() => new EndedItemView(Press)),
            ItemsSource = rest.Items,
        };
        Children.Add(restList);
        DrawRest();
    }

    public bool IsOpen => open;

    public void Show(IReadOnlyList<EndedLine> first, string? moreText, IReadOnlyList<(string Day, IReadOnlyList<EndedLine> Rows)> byDay)
    {
        always.Show(first);
        moreWords.Text = moreText ?? "";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, moreText ?? "");
        more.Visibility = moreText is null ? Visibility.Collapsed : Visibility.Visible;
        days = byDay;
        if (open) rest.Show(Items());
    }

    /// <summary>The rest, closed: no row and no view; opened: each day's heading and its rows.</summary>
    private void DrawRest()
    {
        chevron.Content = Icons.Of(open ? Icons.ChevronDown : Icons.ChevronRight, Look.Muted, 12);
        if (open)
        {
            rest.Show(Items());
            restList.Visibility = Visibility.Visible;
        }
        else
        {
            restList.Visibility = Visibility.Collapsed;
            rest.Items.Clear();
        }
    }

    private List<EndedItem> Items() => EndedRows.Items(days, opened);
}

/// <summary>The face of one ended row, made once and drawn again with each model of its row (the Mac's EndedRow): the
/// red word on its capsule, or the muted note at the row's end, in the same place; a run without its mark, its muted
/// title where the row's title begins.</summary>
internal sealed class EndedRowFace
{
    private readonly AgentGlyph mark = new() { Side = 16, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock title = Look.Words("", wrap: false);
    private readonly TextBlock note = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly Border capsule;
    private readonly TextBlock badge = Look.Words("", 12, 16, Look.Brush(Look.Rgb(0xFF, 0x6B, 0x6B)), semibold: true, wrap: false);
    private EndedLine? line;

    public Button Button { get; }

    public EndedRowFace(Action<EndedLine> press)
    {
        var grid = new Grid { MinHeight = 36, Padding = new Thickness(10, 0, 10, 0), ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(mark);
        title.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(title, 1);
        grid.Children.Add(title);
        capsule = new Border
        {
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(7, 2, 7, 2),
            Background = Look.Brush(global::Windows.UI.Color.FromArgb(41, 255, 59, 48)),
            VerticalAlignment = VerticalAlignment.Center,
            Child = badge,
        };
        Grid.SetColumn(capsule, 2);
        grid.Children.Add(capsule);
        note.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(note, 2);
        grid.Children.Add(note);
        Button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Content = grid,
        };
        Button.Click += (_, _) =>
        {
            if (line is not null) press(line);
        };
    }

    public void Show(EndedLine next)
    {
        line = next;
        mark.Mark = next.Mark;
        mark.Visibility = next.Indent ? Visibility.Collapsed : Visibility.Visible;
        title.Text = next.Title;
        title.Foreground = next.Indent ? Look.Muted : Look.Text;
        title.Margin = new Thickness(next.Indent ? 16 : 0, 0, 0, 0);
        badge.Text = next.Badge ?? "";
        capsule.Visibility = next.Badge is null ? Visibility.Collapsed : Visibility.Visible;
        note.Text = next.Badge is null ? next.Note ?? "" : "";
        note.Visibility = next.Badge is null && next.Note is not null ? Visibility.Visible : Visibility.Collapsed;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Button, next.Title);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(Button, next.Runs is null ? "" : next.Opened ? "Open" : "Closed");
    }
}

/// <summary>A row that always shows: a result that he must see, or an answered request.</summary>
internal sealed class EndedLineView : HeldView<EndedLine>
{
    private readonly EndedRowFace face;

    public EndedLineView(Action<EndedLine> press)
    {
        face = new EndedRowFace(press);
        Children.Add(face.Button);
    }

    protected override void Draw(EndedLine item) => face.Show(item);
}

/// <summary>A line of the opened rest: a day's heading, or a row.</summary>
internal sealed class EndedItemView : HeldView<EndedItem>
{
    private readonly Grid heading;
    private readonly TextBlock day = Look.Words("", 12, 16, Look.Muted, semibold: true, wrap: false);
    private readonly EndedRowFace face;

    public EndedItemView(Action<EndedLine> press)
    {
        day.VerticalAlignment = VerticalAlignment.Bottom;
        heading = new Grid { MinHeight = 28, Padding = new Thickness(10, 0, 0, 0), Children = { day } };
        face = new EndedRowFace(press);
        Children.Add(heading);
        Children.Add(face.Button);
    }

    protected override void Draw(EndedItem item)
    {
        heading.Visibility = item.Line is null ? Visibility.Visible : Visibility.Collapsed;
        face.Button.Visibility = item.Line is null ? Visibility.Collapsed : Visibility.Visible;
        if (item.Line is { } line) face.Show(line);
        else day.Text = item.Day ?? "";
    }
}
