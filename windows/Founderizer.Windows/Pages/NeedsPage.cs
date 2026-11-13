using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Page = Founderizer.Core.Page;

namespace Founderizer.Windows.Pages;

/// <summary>Needs you, as picture 3 draws it (the Mac's NeedsBoard): the page's title, the Open lane with its count and a
/// card for each request, and the request at hand beside it, with its options and its answer box. A press on a card
/// brings that request to hand; a press on an option answers it, and the next request comes to hand.
///
/// The second set adds the row of the answered requests ("2 answered", opened by day), "Nothing needs you" where a
/// request stands (picture 12), Details opened (2b), and an answered request at hand.</summary>
internal sealed class NeedsPage : Grid, IPageView, IAnswers, ILaneContext
{
    private readonly IFleetSource source;
    private readonly PageServices services;
    private readonly Action<Page> go;
    private readonly LaneView lane;
    private readonly RequestStepView step;
    private readonly ScrollViewer stage;
    private readonly EndedView ended = new();
    private readonly StackPanel empty = new() { Spacing = 12, Padding = new Thickness(0, 66, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock emptyWords = Look.Words("", brush: Look.Muted, wrap: false);
    private StoreState state = new();
    private DateTimeOffset now;
    private bool reduceMotion;
    private long? chosen;
    private ValueList<long>? order;

    public NeedsPage(PageServices services, long? chosen)
    {
        this.services = services;
        source = services.Source;
        go = services.Go;
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
        lane.Footer(ended);
        lanes.Children.Add(lane);
        step = new RequestStepView(this) { Margin = new Thickness(0, 66, 0, 24) };
        var mark = Icons.Of(Icons.CheckCircle, Look.Text, 22);
        mark.HorizontalAlignment = HorizontalAlignment.Center;
        emptyWords.HorizontalAlignment = HorizontalAlignment.Center;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(emptyWords, "NeedsEmpty");
        empty.Children.Add(mark);
        empty.Children.Add(emptyWords);
        stage = new ScrollViewer
        {
            Content = new Grid { Children = { step, empty } },
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
        ended.Show([], model.EndedCount == 0 ? null : model.EndedWords,
                   model.Ended.Select(day => (day.Day, (IReadOnlyList<EndedLine>)day.Rows
                       .Select(r => new EndedLine(r.Key, r.Mark, r.Title, r.Badge, () => OpenNeed(r.Id))).ToList())).ToList());
        if (model.AtHand is { } hand)
        {
            step.Visibility = Visibility.Visible;
            step.Show(hand, AnswerBoxModel.CanSend(next, at, hand.Answer.Draft, hand.Answer.Files.Count));
        }
        else step.Visibility = Visibility.Collapsed;
        emptyWords.Text = model.EmptyWords;
        empty.Visibility = model.AtHand is null && model.Empty ? Visibility.Visible : Visibility.Collapsed;
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
