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
/// A card's state word stands at the end of its agent's line (the Mac's ActivityCard): "Until 16:00" for a task that its
/// agent parked (fourth set, 3), else what holds it. States that no picture shows wait: "No tasks".</summary>
internal sealed class BoardPage : Grid, IPageView, ILaneContext
{
    private readonly Action<Page> go;
    private readonly Action<long> openNeed;
    private readonly LaneView[] lanes = new LaneView[3];
    private readonly EndedView ended;
    private readonly TextBlock empty = Look.Words("", brush: Look.Muted, wrap: false);
    private readonly TextBlock period = Look.Words("", wrap: false);
    private readonly TextBlock agentWords = Look.Words("", wrap: false);
    private readonly Button periodBox;
    private readonly Button agentBox;
    private StoreState state = new();
    private ActivityPeriod chosenPeriod = ActivityPeriod.Week;
    private string? chosenAgent;
    private TaskBoardModel? model;

    public BoardPage(Action<Page> go, Action<long> openNeed)
    {
        this.go = go;
        this.openNeed = openNeed;
        ended = new EndedView(id => go(Page.OfTask(id)));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(period, "BoardPeriod");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(agentWords, "BoardAgent");
        Padding = new Thickness(24, 0, 24, 0);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var title = Look.PageTitle("Tasks");
        title.Margin = new Thickness(0, 28 + Look.TitleNudge, 0, 16 - Look.TitleNudge);
        Children.Add(title);

        periodBox = Combo(Icons.Calendar, period);
        agentBox = Combo(Icons.People, agentWords);
        periodBox.Click += (_, _) => Choose(periodBox, model?.Periods.Select(p => (p.Words, (Action)(() => chosenPeriod = p.Value))));
        agentBox.Click += (_, _) => Choose(agentBox, model?.Agents.Select(a => (a.Words, (Action)(() => chosenAgent = a.Agent))));
        var filters = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Margin = new Thickness(0, 0, 0, 22),
            Children = { periodBox, agentBox },
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
        lanes[2].Footer(ended);
        SetRow(board, 2);
        Children.Add(board);
        empty.HorizontalAlignment = HorizontalAlignment.Center;
        empty.VerticalAlignment = VerticalAlignment.Top;
        empty.Margin = new Thickness(0, 66, 0, 0);
        SetRow(empty, 2);
        Children.Add(empty);
    }

    public FrameworkElement View => this;

    public void Show(StoreState next, DateTimeOffset now, bool reduceMotion)
    {
        state = next;
        var board = model = Screens.Board(next, chosenPeriod, chosenAgent, now, ScreenContext.Local);
        period.Text = board.Periods.FirstOrDefault(p => p.Value == board.Period)?.Words ?? "";
        agentWords.Text = board.Agents.FirstOrDefault(a => a.Agent == board.Agent)?.Words ?? "";
        ToolTipService.SetToolTip(periodBox, board.PeriodHover);
        ToolTipService.SetToolTip(agentBox, board.AgentHover);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(periodBox, board.PeriodLabel);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(agentBox, board.AgentLabel);
        empty.Text = board.EmptyWords ?? "";
        empty.Visibility = board.EmptyWords is null ? Visibility.Collapsed : Visibility.Visible;
        for (int i = 0; i < lanes.Length && i < board.Lanes.Count; i++)
        {
            var lane = board.Lanes[i];
            lanes[i].Show(lane.Title, lane.Count, lane.Cards.Select(LaneCard.Of).ToList());
            if (lane.Ended is { } end)
            {
                var (first, days) = EndedRows.Of(end);
                ended.Show(first, end.RestWords, days);
            }
        }
    }

    /// <summary>A box's list, as Windows draws a drop-down's (the Mac's period and agent selects): a press chooses, and
    /// the board draws again.</summary>
    private void Choose(Button box, IEnumerable<(string Words, Action Pick)>? choices)
    {
        if (choices is null) return;
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft };
        foreach (var (words, pick) in choices)
        {
            var item = new MenuFlyoutItem { Text = words };
            item.Click += (_, _) =>
            {
                pick();
                Show(state, DateTimeOffset.UtcNow, false);
            };
            menu.Items.Add(item);
        }
        menu.ShowAt(box);
    }

    public void Open(LaneCard card) => go(Page.OfTask(card.Id));

    public void OpenNeed(long need) => openNeed(need);

    /// <summary>A drop-down box as Windows draws it (the Mac's period and agent selects): its icon, its words and the
    /// chevron.</summary>
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
    private readonly LineBand band;
    private readonly PendingBarView bar;
    private readonly ThreadList thread;
    private readonly TextBlock stateWord = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly Button pause;
    private readonly Button stop;
    private readonly Button resume;
    private readonly FrameworkElement heldMark = Icons.Of(Icons.PauseCircle, Look.Muted);
    private TaskControl resumeAction = TaskControl.Resume;
    private readonly Grid controls;
    private readonly Field guidance;
    private readonly TextBlock heading = Look.Words("", semibold: true);
    // The facts' words sit 1 pixel higher in WinUI's line than in the pictures: 19 above in place of 18.
    private readonly StackPanel facts = new() { Spacing = 15, Padding = new Thickness(16, 19, 16, 17) };
    private List<Fact>? shownFacts;
    private (ParentTaskModel?, SubtasksModel?, ChildAgentsModel?, ChangedFilesModel?)? shownPanel;
    private StoreState state = new();
    private DateTimeOffset now;
    private bool loaded;
    private readonly Button latest;
    private readonly PageServices services;

    public TaskPage(long id, PageServices services)
    {
        this.services = services;
        source = services.Source;
        band = new LineBand(services);
        bar = new PendingBarView(services);
        this.id = id;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        thread = new ThreadList(this, new Thickness(0, 14, 0, 12));
        thread.Scroll.Margin = new Thickness(0, 0, 0, 104);

        pause = IconButton(Icons.Pause, "Pause", TaskControl.Pause);
        stop = IconButton(Icons.Stop, "Stop", TaskControl.Stop);
        resume = Buttons.Plain(new ControlsModel().ResumeWords, Icons.Play);
        resume.Click += (_, _) => _ = source.ControlAsync(id, resumeAction);
        stateWord.VerticalAlignment = VerticalAlignment.Center;
        heldMark.VerticalAlignment = VerticalAlignment.Center;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(stateWord, "TaskState");
        controls = new Grid
        {
            Height = 40,
            MaxWidth = 692,
            Margin = new Thickness(23.5, 0, 23.5, 64),
            VerticalAlignment = VerticalAlignment.Bottom,
            Children =
            {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { heldMark, stateWord } },
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 12,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Children = { resume, pause, stop },
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

        // "Latest" while the thread stands away from its end (the Mac's TaskView, FleetCore's ChatEnd), as in a chat:
        // the library's word for it is the chat's (ChatModel.LatestWords).
        var words = new ChatModel().LatestWords;
        // On a task's thread, "Latest" is the Mac's capsule at the lower right (TaskView; fifth set, 7): the arrow down
        // and the word, 12 on 16, muted, on the surface, corners of 16.
        var down = Icons.Of(Icons.ArrowDown, Look.Muted, 12);
        down.VerticalAlignment = VerticalAlignment.Center;
        var latestWords = Look.Words(words, 12, 16, Look.Muted, wrap: false);
        latestWords.VerticalAlignment = VerticalAlignment.Center;
        latest = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            CornerRadius = new CornerRadius(16),
            Content = new Border
            {
                Background = Look.SurfaceBrush,
                CornerRadius = new CornerRadius(16),
                Padding = new Thickness(12, 9, 12, 9),
                Child = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { down, latestWords } },
            },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(latest, words);
        latest.HorizontalAlignment = HorizontalAlignment.Right;
        latest.VerticalAlignment = VerticalAlignment.Bottom;
        latest.Margin = new Thickness(0, 0, 12, 128);
        latest.Visibility = Visibility.Collapsed;
        latest.Click += (_, _) => thread.Latest();
        thread.EndChanged += () => latest.Visibility = thread.End.ShowsLatest && thread.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        Children.Add(Banded.Wrap(new Grid { Children = { thread.Scroll, controls, guidance, latest } }, band, bar));

        heading.Padding = new Thickness(16, 16, 16, 14);
        var panel = new Border
        {
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
        Widths.FollowPanel(panel);
        SetColumn(panel, 1);
        Children.Add(panel);

    }

    public FrameworkElement View => this;

    public LineBand Band => band;

    public PendingBarView Bar => bar;

    public void Show(StoreState next, DateTimeOffset at, bool reduceMotion)
    {
        state = next;
        now = at;
        if (Screens.Task(next, id, at, ScreenContext.Local) is not { } model) return;
        heading.Text = model.Title;
        var panelParts = (model.ParentTask, model.Subtasks, model.ChildAgents, model.ChangedFiles);
        if (shownFacts is null || !shownFacts.SequenceEqual(model.Facts) || !Equals(shownPanel, panelParts))
        {
            shownFacts = model.Facts.ToList();
            shownPanel = panelParts;
            facts.Children.Clear();
            foreach (var fact in model.Facts) facts.Children.Add(fact.Warning ? WarningView(fact) : FactView(next, fact, at));
            // After the facts, as the Mac's taskFacts: the parent task, the subtasks, the child agents, the changed files.
            if (model.ParentTask is { } parent) facts.Children.Add(ParentView(parent));
            if (model.Subtasks is { Rows.Count: > 0 } subtasks) foreach (var part in SubtasksView(subtasks)) facts.Children.Add(part);
            if (model.ChildAgents is { Rows.Count: > 0 } children) foreach (var part in ChildAgentsView(children)) facts.Children.Add(part);
            if (model.ChangedFiles is { } files) foreach (var part in ChangedFiles(files)) facts.Children.Add(part);
        }

        if (model.Controls is { } c)
        {
            controls.Visibility = Visibility.Visible;
            stateWord.Text = c.StateWord;
            stateWord.Foreground = c.Alert ? Look.Orange : Look.Muted;
            heldMark.Visibility = c.Held ? Visibility.Visible : Visibility.Collapsed;
            pause.Visibility = c.ShowsPause ? Visibility.Visible : Visibility.Collapsed;
            stop.Visibility = c.ShowsStop ? Visibility.Visible : Visibility.Collapsed;
            resume.Visibility = c.ShowsResume ? Visibility.Visible : Visibility.Collapsed;
            resumeAction = c.ResumeAction;
            ToolTipService.SetToolTip(pause, c.PauseWords);
            ToolTipService.SetToolTip(stop, c.StopWords);
            pause.IsEnabled = stop.IsEnabled = resume.IsEnabled = c.Enabled;
        }
        else controls.Visibility = Visibility.Collapsed;

        // While a hold stands there is no guidance box (TaskSteering.shows): the controls take its place at the foot.
        guidance.Visibility = model.Guidance is null ? Visibility.Collapsed : Visibility.Visible;
        controls.Margin = new Thickness(23.5, 0, 23.5, model.Guidance is null ? 12 : 64);
        // A task that is over has neither (pictures 1 and 2 of the third set): its thread goes down to the foot.
        thread.Scroll.Margin = new Thickness(0, 0, 0, model.Guidance is not null ? 104 : model.Controls is not null ? 52 : 0);
        latest.Margin = new Thickness(0, 0, 12, thread.Scroll.Margin.Bottom + 24);
        if (model.Guidance is { } g)
            guidance.Show(g.Placeholder, false, GuidanceModel.CanSend(next, at, guidance.Box.Text));

        var rows = new List<ThreadItem>();
        RowKind? previous = null;
        bool previousOpen = false;
        void Add(string key, RowKind kind, object row, double gap = 21)
        {
            rows.Add(new ThreadItem(key, kind, ThreadList.GapAfter(previous, gap), row));
            (previous, previousOpen) = (kind, false);
        }
        Add("asks", RowKind.Own, model.Asks);
        void AddAll(IEnumerable<(string Key, RowKind Kind, double Gap, object Model)> some)
        {
            foreach (var (key, kind, gap, row) in some)
            {
                rows.Add(new ThreadItem(key, kind, ThreadList.GapAfter(previous, gap), row));
                (previous, previousOpen) = (kind, row is FoldRowModel { Open: true });
            }
        }
        // A child agent's thread takes the task thread's place (fifth set, 6b), until Back; one that is no longer in the
        // record takes it back.
        var child = childPath.Count > 0 ? Screens.ChildThread(next, id, childPath.Peek(), at, ScreenContext.Local) : null;
        if (childPath.Count > 0 && child is null) childPath.Clear();
        bool childChanged = shownChild != (childPath.Count > 0 ? childPath.Peek() : null);
        shownChild = childPath.Count > 0 ? childPath.Peek() : null;
        if (child is not null) AddAll(TaskThreadRows.Child(child, openFolds));
        else
        {
            // Over the thread (the Mac's RuntimeActivity): a read of its record that failed, and offline.
            if (model.ActivityError is { } failed) Add("activity-error", RowKind.Line, new ThreadLine(failed, LineLook.ActivityError));
            if (model.OfflineWords is { } offline)
                Add("offline", RowKind.Line, new ThreadLine(offline, LineLook.Offline), model.ActivityError is null ? 21 : TaskThreadRows.UnderOverLine);
            // Under a line over the thread the next row has the Mac's 20 under a 12 pt line (35 apart).
            double? underLine = model.ActivityError is not null || model.OfflineWords is not null ? TaskThreadRows.UnderOverLine : null;
            // The thread's last rows (fifth set, 7): 80, and 80 more for each press on "Earlier activity"; rows that come
            // while he reads further up add to what shows, so the rows he reads stay where they are.
            if (shownTopRows > 0 && model.ThreadTopRows > shownTopRows && !thread.End.FollowsLatest) visibleRows += model.ThreadTopRows - shownTopRows;
            shownTopRows = model.ThreadTopRows;
            var shownThread = model.Thread.Count > visibleRows ? model.Thread.Skip(model.Thread.Count - visibleRows).ToList() : (IReadOnlyList<ThreadRowModel>)model.Thread;
            if (model.Thread.Count > visibleRows)
            {
                Add("earlier-activity", RowKind.EarlierActivity, new EarlierActivity(model.EarlierWords), underLine ?? 21);
                underLine = null;
            }
            AddAll(TaskThreadRows.Of(shownThread, openFolds, previous, underLine));
            // The plan of the work that runs, open under the newest row (fifth set, 4).
            if (model.LivePlan is { } plan)
                Add("live-plan", RowKind.Plan, new PlanRow(plan), TaskThreadRows.Under(previous, previousOpen));
        }
        // What it waits for (picture 3 of the third set), and a result: the line, its words, its check (pictures 1 and 2).
        if (model.WaitingLabel is { } waitingLabel && model.WaitingValue is { } waitingValue)
            Add("waiting-for", RowKind.Detail, new DetailRow(waitingLabel, waitingValue, model.WaitingAgent is { } waiter
                ? MarkLook.Of(next.MarkOf(waiter), next.StatusOf(waiter, at).MarkState, moves: false) : null));
        if (model.Result is { } result)
        {
            Add("rule", RowKind.Rule, new RuleRow());
            Add("what", RowKind.Reply, result.What);
            Add("check", RowKind.Check, new CheckRow(result, checkOpen));
            // The checked outputs (fourth set, 1a to 1e): 10 between the list's parts (ArtifactSection's spacing). The
            // lines while a read runs, of a refusal and of a reading that is not current wait for their pictures.
            if (result.Outputs is { } outputs)
            {
                if (outputs.NoFilesWords is { } none) rows.Add(new ThreadItem("outputs-none", RowKind.Who, 10, new MutedLine(none)));
                foreach (var file in outputs.Files) rows.Add(new ThreadItem("output-" + file.Path, RowKind.OutputFile, 10, file));
                if (outputs.Opened is { } opened && Picture(opened) is var (ready, image) && ready)
                {
                    if (opened.Path != verifyFor) (verifyFor, verifyOpen) = (opened.Path, false);
                    rows.Add(new ThreadItem("output-open", RowKind.OutputBox, 10, new OutputBoxRow(opened, image, verifyOpen)));
                }
                previous = RowKind.OutputFile;
            }
        }
        Add("who", RowKind.Who, model.Who);
        foreach (var (key, words) in new[] { ("stalled", model.StalledReason), ("limit", model.LimitWords), ("missing", model.MissingWords) })
            if (words is not null) Add(key, RowKind.Who, new AlertLine(words));
        thread.Show(rows, opening: !loaded || childChanged);
        loaded = true;
        lastReduceMotion = reduceMotion;
    }

    /// <summary>The result's check stands folded as the page opens; a press opens it, or folds it again.</summary>
    private bool checkOpen;
    private bool lastReduceMotion;

    public void ToggleCheck()
    {
        checkOpen = !checkOpen;
        Redraw();
    }

    private void Redraw() => Show(state, DateTimeOffset.UtcNow, lastReduceMotion);

    // The checked outputs are the store's (CheckedOutputsModel): the page keeps only whether the opened file's verified
    // download stands open, and the opened picture as Windows decoded it.
    private bool verifyOpen;
    private string? verifyFor;
    private byte[]? pictureBytes;
    private Microsoft.UI.Xaml.Media.ImageSource? pictureImage;

    public void ListOutputs() => _ = source.ListOutputsAsync();

    public void ViewOutput(ArtifactFile file) => _ = source.ViewOutputAsync(file);

    public void CloseOutput() => source.CloseOutputs();

    public void ToggleVerify()
    {
        verifyOpen = !verifyOpen;
        Redraw();
    }

    /// <summary>The opened file's picture: ready with no picture for a text; for a picture, ready once Windows decoded its
    /// verified bytes, at most ThumbnailMost a side (the Mac's thumbnail), so the box comes whole in one frame.</summary>
    private (bool Ready, Microsoft.UI.Xaml.Media.ImageSource? Image) Picture(OpenedOutputModel opened)
    {
        if (opened.Picture is not { } bytes) return (true, null);
        if (ReferenceEquals(bytes, pictureBytes)) return (pictureImage is not null, pictureImage);
        pictureBytes = bytes;
        pictureImage = null;
        _ = Decode(bytes, opened);
        return (false, null);
    }

    private async System.Threading.Tasks.Task Decode(byte[] bytes, OpenedOutputModel opened)
    {
        var image = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
        if (opened.Width >= opened.Height && opened.Width > opened.ThumbnailMost) image.DecodePixelWidth = opened.ThumbnailMost;
        else if (opened.Height > opened.Width && opened.Height > opened.ThumbnailMost) image.DecodePixelHeight = opened.ThumbnailMost;
        try
        {
            using var stream = new System.IO.MemoryStream(bytes);
            await image.SetSourceAsync(System.IO.WindowsRuntimeStreamExtensions.AsRandomAccessStream(stream));
        }
        catch (Exception)
        {
            // The library checked the picture's kind and size; one that Windows still cannot decode shows no picture.
        }
        if (!ReferenceEquals(bytes, pictureBytes)) return;
        pictureImage = image;
        Redraw();
    }

    /// <summary>The folds of the thread that he opened (a run of steps, a permission, a step, a script's result), by key.</summary>
    private readonly HashSet<string> openFolds = new();

    // A child agent's thread in the task thread's place: the path of the threads that he opened, the deepest on top.
    private readonly Stack<ToolKey> childPath = new();
    private ToolKey? shownChild;

    public void OpenChild(ToolKey child)
    {
        if (childPath.Contains(child)) return;
        childPath.Push(child);
        Redraw();
    }

    public void CloseChild()
    {
        if (childPath.Count > 0) childPath.Pop();
        Redraw();
    }

    // The rows of the thread that show (RuntimeActivity.visibleCount): the last 80, 80 more for each "Earlier activity".
    private int visibleRows = StepWords.ShownAtOnce;
    private int shownTopRows;

    public void ShowEarlierActivity()
    {
        visibleRows += StepWords.ShownAtOnce;
        Redraw();
    }

    /// <summary>A fact in orange with the error's mark and no label (the Mac's taskFacts: "The AI provider used other
    /// settings").</summary>
    private static UIElement WarningView(Fact fact)
    {
        var mark = Icons.Of(Icons.ErrorCircle, Look.Orange, 16);
        mark.VerticalAlignment = VerticalAlignment.Top;
        var words = Look.Words(fact.Value, 12, 16, Look.Orange);
        var line = new Grid { ColumnSpacing = 6, ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
        Grid.SetColumn(words, 1);
        line.Children.Add(mark);
        line.Children.Add(words);
        return line;
    }

    /// <summary>"Parent task · title" in the link's colour (fifth set, 8); a press opens it.</summary>
    private UIElement ParentView(ParentTaskModel parent)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Left,
            Content = Look.Words(parent.Words, 12, 16, Look.Link),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, parent.Words);
        button.Click += (_, _) => services.Go(Page.OfTask(parent.Id));
        return button;
    }

    /// <summary>"Subtasks" and each subtask: its title (two lines at most) and its state word under it, muted; a press
    /// opens it.</summary>
    private IEnumerable<UIElement> SubtasksView(SubtasksModel subtasks)
    {
        yield return Look.Words(subtasks.Heading, 12, 16, semibold: true);
        foreach (var row in subtasks.Rows)
        {
            var title = Look.Words(row.Title, 12, 16);
            title.MaxLines = 2;
            title.TextTrimming = TextTrimming.CharacterEllipsis;
            title.Margin = new Thickness(0, 0, 0, 3);
            var button = new Button
            {
                Style = (Style)Application.Current.Resources["QuietButtonStyle"],
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Content = new StackPanel { Children = { title, Look.Words(row.Status, 12, 16, Look.Muted) } },
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, row.Title);
            long id = row.Id;
            button.Click += (_, _) => services.Go(Page.OfTask(id));
            yield return button;
        }
    }

    /// <summary>A line, "Child agents", and each child agent with its state's mark, its name and the arrow that opens its
    /// thread (fifth set, 6a); "More agents in the task thread" past 20.</summary>
    private IEnumerable<UIElement> ChildAgentsView(ChildAgentsModel children)
    {
        yield return new Microsoft.UI.Xaml.Shapes.Rectangle { Height = 1, Fill = Look.Line };
        yield return Look.Words(children.Heading, 12, 16, semibold: true);
        foreach (var row in children.Rows)
        {
            var mark = row.State switch
            {
                ChildState.Done => Icons.Of(Icons.CheckCircle20, Look.Muted, 16),
                ChildState.Failed => Icons.Of(Icons.ErrorCircle, Look.Orange, 16),
                _ => Icons.Of(Icons.Hint, Look.Muted, 16),
            };
            mark.VerticalAlignment = VerticalAlignment.Top;
            var name = Look.Words(row.Name, 12, 16);
            name.MaxLines = 2;
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            var arrow = Icons.Of(Icons.OpenThread, Look.Text, 12);
            arrow.VerticalAlignment = VerticalAlignment.Top;
            arrow.Margin = new Thickness(0, 2, 0, 0);
            var line = new Grid
            {
                ColumnSpacing = 8,
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = GridLength.Auto },
                    new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                    new ColumnDefinition { Width = GridLength.Auto },
                },
            };
            Grid.SetColumn(name, 1);
            Grid.SetColumn(arrow, 2);
            line.Children.Add(mark);
            line.Children.Add(name);
            line.Children.Add(arrow);
            var button = new Button
            {
                Style = (Style)Application.Current.Resources["QuietButtonStyle"],
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Content = line,
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, row.Name);
            ToolTipService.SetToolTip(button, row.Hover);
            var key = row.Key;
            button.Click += (_, _) => OpenChild(key);
            yield return button;
        }
        if (children.MoreWords is { } more) yield return Look.Words(more, 12, 16, Look.Muted);
    }

    public void ToggleFold(string key)
    {
        if (!openFolds.Remove(key)) openFolds.Add(key);
        Redraw();
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

    /// <summary>The files that the task changed, under the facts (fourth set, 2a; the Mac's TaskView): a line, "Changed
    /// files" semibold, each file's path and under it, 3 lower, its action with its lines added in green and removed in
    /// orange, all 12 on 16; and the note of what the counts are, muted. 15 between them, as between the facts.</summary>
    private static IEnumerable<UIElement> ChangedFiles(ChangedFilesModel files)
    {
        yield return new Microsoft.UI.Xaml.Shapes.Rectangle { Height = 1, Fill = Look.Line };
        yield return Look.Words(files.Heading, 12, 16, semibold: true);
        foreach (var change in files.Rows)
        {
            var path = Look.Words(change.Path, 12, 16);
            path.IsTextSelectionEnabled = true;
            path.Margin = new Thickness(0, 0, 0, 3);
            var counts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { Look.Words(change.Action, 12, 16, Look.Muted) } };
            if (change.Added is { } added) counts.Children.Add(Look.Words(added, 12, 16, Look.Green));
            if (change.Removed is { } removed) counts.Children.Add(Look.Words(removed, 12, 16, Look.Orange));
            yield return new StackPanel { Children = { path, counts } };
        }
        yield return Look.Words(files.Footer, 12, 16, Look.Muted);
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
    public void Tick(long need, IReadOnlyCollection<int> choices) { }
    public void Type(long need, string text) { }
    public void Answer(long need) { }
    public bool CanSendTicks(int ticked) => false;
    public bool IsOpen(long need, string part) => false;
    public void SetOpen(long need, string part, bool open) { }
}
