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
        var who = new Grid
        {
            Children =
            {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { mark, agent } },
                hourglass,
            },
        };
        ownerLine.Tapped += OwnerLineTapped;
        card = new Border
        {
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14, 12, 14, 12),
            Child = new StackPanel { Spacing = 8, Children = { title, why, ownerLine, who } },
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

/// <summary>One ended row (pictures 5 and 12): the agent's mark at 16, the title cut with "…", and a red word on a red
/// capsule for a result that did not succeed; a press opens it.</summary>
internal sealed record EndedLine(string Key, MarkLook? Mark, string Title, string? Badge, Action Open);

/// <summary>The ended part of a lane (the Mac's endedRows and restRows): the rows that always show, then the row that
/// opens the rest ("2 more", "2 answered") with its chevron, and, opened, the rest by day under each day's heading.</summary>
internal sealed class EndedView : StackPanel
{
    private readonly StackPanel always = new();
    private readonly Button more;
    private readonly TextBlock moreWords = Look.Words("", wrap: false, brush: Look.Muted);
    private readonly ContentControl chevron = new() { IsTabStop = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel rest = new();
    private bool open;
    private IReadOnlyList<(string Day, IReadOnlyList<EndedLine> Rows)> days = [];

    public EndedView()
    {
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
        Children.Add(always);
        Children.Add(more);
        Children.Add(rest);
        DrawRest();
    }

    public bool IsOpen => open;

    public void Show(IReadOnlyList<EndedLine> first, string? moreText, IReadOnlyList<(string Day, IReadOnlyList<EndedLine> Rows)> byDay)
    {
        always.Children.Clear();
        foreach (var line in first) always.Children.Add(Row(line));
        moreWords.Text = moreText ?? "";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, moreText ?? "");
        more.Visibility = moreText is null ? Visibility.Collapsed : Visibility.Visible;
        days = byDay;
        DrawRest();
    }

    private void DrawRest()
    {
        chevron.Content = Icons.Of(open ? Icons.ChevronDown : Icons.ChevronRight, Look.Muted, 12);
        rest.Children.Clear();
        rest.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        if (!open) return;
        foreach (var (day, rows) in days)
        {
            var heading = Look.Words(day, 12, 16, Look.Muted, semibold: true, wrap: false);
            heading.VerticalAlignment = VerticalAlignment.Bottom;
            rest.Children.Add(new Grid { MinHeight = 28, Padding = new Thickness(10, 0, 0, 0), Children = { heading } });
            foreach (var line in rows) rest.Children.Add(Row(line));
        }
    }

    private static Button Row(EndedLine line)
    {
        var grid = new Grid { MinHeight = 36, Padding = new Thickness(10, 0, 10, 0), ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var mark = new AgentGlyph { Side = 16, Mark = line.Mark, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(mark);
        var title = Look.Words(line.Title, wrap: false);
        title.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(title, 1);
        grid.Children.Add(title);
        if (line.Badge is { } badge)
        {
            var capsule = new Border
            {
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(7, 2, 7, 2),
                Background = Look.Brush(global::Windows.UI.Color.FromArgb(41, 255, 59, 48)),
                VerticalAlignment = VerticalAlignment.Center,
                Child = Look.Words(badge, 12, 16, Look.Brush(Look.Rgb(0xFF, 0x6B, 0x6B)), semibold: true, wrap: false),
            };
            Grid.SetColumn(capsule, 2);
            grid.Children.Add(capsule);
        }
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Content = grid,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, line.Title);
        button.Click += (_, _) => line.Open();
        return button;
    }
}
