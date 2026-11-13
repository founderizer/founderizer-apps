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

/// <summary>Tasks, the board, as picture 4a draws it (the Mac's ActivityBoard): the page's title, the period and the
/// agent, and three lanes with their counts and cards; Ended shows "Show all". A press on a card opens the task's page;
/// a press on the orange line of a task that waits on a request opens that request in Needs you.
///
/// States that no picture shows wait: the period's and the agent's lists (a press on either does nothing yet), the
/// opened Ended lane ("Show all" does nothing yet), the failed results, a card's state line, and "No tasks".</summary>
internal sealed class BoardPage : Grid, IPageView, ILaneContext
{
    private readonly Action<Page> go;
    private readonly Action<long> openNeed;
    private readonly LaneView[] lanes = new LaneView[3];
    private readonly Button showAll;
    private readonly TextBlock showAllWords = Look.Words("", wrap: false, brush: Look.Muted);
    private readonly TextBlock period = Look.Words("", wrap: false);
    private readonly TextBlock agentWords = Look.Words("", wrap: false);

    public BoardPage(Action<Page> go, Action<long> openNeed)
    {
        this.go = go;
        this.openNeed = openNeed;
        Padding = new Thickness(24, 0, 24, 0);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var title = Look.PageTitle("Tasks");
        title.Margin = new Thickness(0, 28 + Look.TitleNudge, 0, 16 - Look.TitleNudge);
        Children.Add(title);

        var filters = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Margin = new Thickness(0, 0, 0, 22),
            Children = { Combo(Icons.Calendar, period), Combo(Icons.People, agentWords) },
        };
        SetRow(filters, 1);
        Children.Add(filters);

        var board = new Grid { ColumnSpacing = 24 };
        for (int i = 0; i < 3; i++)
        {
            board.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            lanes[i] = new LaneView(this);
            SetColumn(lanes[i], i);
            board.Children.Add(lanes[i]);
        }
        var chevron = Icons.Of(Icons.ChevronRight, Look.Muted, 12);
        chevron.VerticalAlignment = VerticalAlignment.Center;
        showAllWords.VerticalAlignment = VerticalAlignment.Center;
        showAll = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Left,
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                MinHeight = 32,
                Padding = new Thickness(10, 0, 0, 0),
                Children = { showAllWords, chevron },
            },
        };
        lanes[2].Below(showAll);
        SetRow(board, 2);
        Children.Add(board);
    }

    public FrameworkElement View => this;

    public void Show(StoreState state, DateTimeOffset now, bool reduceMotion)
    {
        var model = Screens.Board(state, ActivityPeriod.Week, null, now, ScreenContext.Local);
        period.Text = model.Periods.FirstOrDefault(p => p.Value == model.Period)?.Words ?? "";
        agentWords.Text = model.Agents.FirstOrDefault(a => a.Agent == model.Agent)?.Words ?? "";
        for (int i = 0; i < lanes.Length && i < model.Lanes.Count; i++)
        {
            var lane = model.Lanes[i];
            lanes[i].Show(lane.Title, lane.Count, lane.Cards.Select(LaneCard.Of).ToList());
            if (lane.Ended is { } ended)
            {
                showAllWords.Text = ended.RestWords ?? "";
                showAll.Visibility = ended.RestWords is not null && ended.Failed.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            }
        }
    }

    public void Open(LaneCard card) => go(Page.OfTask(card.Id));

    public void OpenNeed(long need) => openNeed(need);

    /// <summary>A drop-down box as Windows draws it (the Mac's period and agent selects): its icon, its words and the
    /// chevron. Its list waits for its picture.</summary>
    private static Button Combo(Icon icon, TextBlock words)
    {
        var mark = Icons.Of(icon, Look.Muted);
        var chevron = Icons.Of(Icons.ChevronDown, Look.Text, 12);
        chevron.Margin = new Thickness(22, 0, 0, 0);
        foreach (var part in new[] { mark, chevron, (FrameworkElement)words }) part.VerticalAlignment = VerticalAlignment.Center;
        return new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Left,
            Content = new Border
            {
                Height = 32,
                Padding = new Thickness(11, 0, 11, 0),
                CornerRadius = new CornerRadius(4),
                Background = Look.Brush(Look.White(0.06)),
                BorderBrush = Look.FieldEdge(32, Look.White(0.08), Look.White(0.04)),
                BorderThickness = new Thickness(1),
                Child = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { mark, words, chevron } },
            },
        };
    }
}

/// <summary>One task's page, as picture 4b draws it (the Mac's TaskView): what the task asks in his bubble, the agent's
/// progress notes, who did it, the task's state word with Pause and Stop, its guidance box, and the panel of facts. The
/// notes are virtualized.
///
/// States that no picture shows wait: Resume, the alert of a stop that was not confirmed, the result, the stalled, the
/// limit and the missing lines.</summary>
internal sealed class TaskPage : Grid, IPageView, IThreadContext
{
    private readonly long id;
    private readonly IFleetSource source;
    private readonly ThreadList thread;
    private readonly TextBlock stateWord = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly Button pause;
    private readonly Button stop;
    private readonly Grid controls;
    private readonly Field guidance;
    private readonly TextBlock heading = Look.Words("", semibold: true);
    // The facts' words sit 1 pixel higher in WinUI's line than in the pictures: 19 above in place of 18.
    private readonly StackPanel facts = new() { Spacing = 15, Padding = new Thickness(16, 19, 16, 17) };
    private List<Fact>? shownFacts;
    private StoreState state = new();
    private DateTimeOffset now;
    private bool loaded;
    private int settle;

    public TaskPage(long id, IFleetSource source)
    {
        this.id = id;
        this.source = source;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        thread = new ThreadList(this, new Thickness(0, 14, 0, 12));
        thread.Scroll.Margin = new Thickness(0, 0, 0, 104);

        pause = IconButton(Icons.Pause, "Pause", TaskControl.Pause);
        stop = IconButton(Icons.Stop, "Stop", TaskControl.Stop);
        stateWord.VerticalAlignment = VerticalAlignment.Center;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(stateWord, "TaskState");
        controls = new Grid
        {
            Height = 40,
            MaxWidth = 692,
            Margin = new Thickness(23.5, 0, 23.5, 64),
            VerticalAlignment = VerticalAlignment.Bottom,
            Children =
            {
                stateWord,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 12,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Children = { pause, stop },
                },
            },
        };

        guidance = new Field(40, 14, 16)
        {
            MaxWidth = 692,
            Margin = new Thickness(23.5, 0, 23.5, 12),
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        guidance.Typed += text => guidance.Show(guidance.Box.PlaceholderText, false, GuidanceModel.CanSend(state, DateTimeOffset.UtcNow, text));
        guidance.Sent += () =>
        {
            _ = source.GuideAsync(id, guidance.Box.Text);
            guidance.Clear();
        };

        Children.Add(new Grid { Children = { thread.Scroll, controls, guidance } });

        heading.Padding = new Thickness(16, 16, 16, 14);
        var panel = new Border
        {
            Width = 380,
            Background = Look.RailBrush,
            BorderBrush = Look.Line,
            BorderThickness = new Thickness(1, 0, 0, 0),
            Child = new StackPanel
            {
                Children =
                {
                    new Border { BorderBrush = Look.Line, BorderThickness = new Thickness(0, 0, 0, 1), Child = heading },
                    facts,
                },
            },
        };
        SetColumn(panel, 1);
        Children.Add(panel);

        thread.Scroll.LayoutUpdated += (_, _) =>
        {
            if (settle <= 0) return;
            settle--;
            thread.ToEnd();
        };
    }

    public FrameworkElement View => this;

    public void Show(StoreState next, DateTimeOffset at, bool reduceMotion)
    {
        state = next;
        now = at;
        if (Screens.Task(next, id, at, ScreenContext.Local) is not { } model) return;
        heading.Text = model.Title;
        if (shownFacts is null || !shownFacts.SequenceEqual(model.Facts))
        {
            shownFacts = model.Facts.ToList();
            facts.Children.Clear();
            foreach (var fact in model.Facts) facts.Children.Add(FactView(next, fact, at));
        }

        if (model.Controls is { } c)
        {
            controls.Visibility = Visibility.Visible;
            stateWord.Text = c.StateWord;
            pause.Visibility = c.ShowsPause ? Visibility.Visible : Visibility.Collapsed;
            stop.Visibility = c.ShowsStop ? Visibility.Visible : Visibility.Collapsed;
            pause.IsEnabled = stop.IsEnabled = c.Enabled;
        }
        else controls.Visibility = Visibility.Collapsed;

        guidance.Visibility = model.Guidance is null ? Visibility.Collapsed : Visibility.Visible;
        if (model.Guidance is { } g)
            guidance.Show(g.Placeholder, false, GuidanceModel.CanSend(next, at, guidance.Box.Text));

        var rows = new List<ThreadItem>();
        RowKind? previous = null;
        void Add(string key, RowKind kind, object row)
        {
            rows.Add(new ThreadItem(key, kind, ThreadList.GapAfter(previous, 21), row));
            previous = kind;
        }
        Add("asks", RowKind.Own, model.Asks);
        foreach (var note in model.Notes) Add(note.Key, RowKind.Reply, note);
        Add("who", RowKind.Who, model.Who);
        bool atEnd = !loaded || thread.AtEnd;
        thread.Show(rows);
        if (atEnd) settle = loaded ? 2 : 6;
        loaded = true;
    }

    /// <summary>One fact of the panel (DetailField): its label, muted, and its value, with the agent's mark when it is
    /// an agent.</summary>
    private static StackPanel FactView(StoreState state, Fact fact, DateTimeOffset now)
    {
        var value = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (fact.Agent is { } agent)
        {
            value.Children.Add(new AgentGlyph
            {
                Side = 16,
                VerticalAlignment = VerticalAlignment.Center,
                Mark = MarkLook.Of(state.MarkOf(agent), state.StatusOf(agent, now).MarkState, moves: false),
            });
        }
        var words = Look.Words(fact.Value, 12, 16);
        words.IsTextSelectionEnabled = true;
        words.VerticalAlignment = VerticalAlignment.Center;
        value.Children.Add(words);
        var label = Look.Words(fact.Label, 12, 16, Look.Muted, wrap: false);
        label.Margin = new Thickness(0, 0, 0, 4);
        return new StackPanel { Children = { label, value } };
    }

    private Button IconButton(Icon icon, string words, TaskControl action)
    {
        var mark = Icons.Of(icon);
        mark.HorizontalAlignment = HorizontalAlignment.Center;
        mark.VerticalAlignment = VerticalAlignment.Center;
        var button = new Button
        {
            Width = 32,
            Height = 32,
            VerticalAlignment = VerticalAlignment.Center,
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            Content = new Grid { Children = { mark } },
        };
        ToolTipService.SetToolTip(button, words);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, words);
        button.Click += (_, _) => _ = source.ControlAsync(id, action);
        return button;
    }

    // A task's thread has no request cards.
    public bool CanSendAnswer(RequestCard card) => false;
    public void Press(long need, int choice) { }
    public void Type(long need, string text) { }
    public void Answer(long need) { }
}
