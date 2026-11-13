using System;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Page = Founderizer.Core.Page;

namespace Founderizer.Windows.Pages;

/// <summary>Needs you, as picture 3 draws it (the Mac's NeedsBoard): the page's title, the Open lane with its count and a
/// card for each request, and the request at hand beside it, with its options and its answer box. A press on a card
/// brings that request to hand; a press on an option answers it, and the next request comes to hand.
///
/// States that no picture shows wait and are not drawn: the row of the answered requests, "Nothing needs you", a
/// discussion with lines, and an answered request at hand.</summary>
internal sealed class NeedsPage : Grid, IPageView, IAnswers, ILaneContext
{
    private readonly IFleetSource source;
    private readonly Action<Page> go;
    private readonly LaneView lane;
    private readonly RequestStepView step;
    private readonly ScrollViewer stage;
    private StoreState state = new();
    private DateTimeOffset now;
    private bool reduceMotion;
    private long? chosen;
    private ValueList<long>? order;

    public NeedsPage(IFleetSource source, Action<Page> go, long? chosen)
    {
        this.source = source;
        this.go = go;
        this.chosen = chosen;
        Padding = new Thickness(24, 0, 24, 0);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var title = Look.PageTitle("Needs you");
        title.Margin = new Thickness(0, 28 + Look.TitleNudge, 0, 22 - Look.TitleNudge);
        Children.Add(title);

        var lanes = new Grid { ColumnSpacing = 24 };
        lanes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(341) });
        lanes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        lane = new LaneView(this);
        lanes.Children.Add(lane);
        step = new RequestStepView(this) { Margin = new Thickness(0, 66, 0, 24) };
        stage = new ScrollViewer
        {
            Content = step,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            IsTabStop = false,
        };
        SetColumn(stage, 1);
        lanes.Children.Add(stage);
        SetRow(lanes, 1);
        Children.Add(lanes);
    }

    public FrameworkElement View => this;

    public void Show(StoreState next, DateTimeOffset at, bool reduce)
    {
        state = next;
        now = at;
        reduceMotion = reduce;
        var model = Screens.Needs(next, chosen, order, at, ScreenContext.Local);
        order = model.Order;
        lane.Show(model.LaneHeading, model.OpenCount, model.Cards.Select(LaneCard.Of).ToList());
        if (model.AtHand is { Ended: false } hand)
        {
            step.Visibility = Visibility.Visible;
            step.Show(hand, AnswerBoxModel.CanSend(next, at, hand.Answer.Draft, hand.Answer.Files.Count));
        }
        else step.Visibility = Visibility.Collapsed;
    }

    public void Open(LaneCard card)
    {
        if (card.IsTask) { go(Page.OfTask(card.Id)); return; }
        chosen = card.Id;
        Show(state, DateTimeOffset.UtcNow, reduceMotion);
    }

    public void OpenNeed(long need)
    {
        chosen = need;
        Show(state, DateTimeOffset.UtcNow, reduceMotion);
    }

    public void Press(long need, int choice) => source.Press(need, choice);

    public void Type(long need, string text) => source.SetAnswerDraft(need, text);

    public void Answer(long need) => _ = source.AnswerAsync(need);
}
