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
                                MarkLook Mark, string AgentLabel, bool Waits, string WaitWords, bool Selected)
{
    public static LaneCard Of(NeedCardRow row) => new(row.Key, row.Id, row.IsTask, row.Title, row.OwnerLine, null, row.Mark,
                                                      row.AgentLabel, row.Waits, row.WaitWords, row.Selected);

    public static LaneCard Of(TaskCardRow row) => new(row.Key, row.Id, true, row.Title, row.OwnerLine, row.OwnerLineNeed,
                                                      row.Mark, row.AgentLabel, false, "", false);
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
        scroll = new ScrollViewer
        {
            Content = repeater,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            IsTabStop = false,
        };
        SetRow(scroll, 1);
        Children.Add(scroll);
    }

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
