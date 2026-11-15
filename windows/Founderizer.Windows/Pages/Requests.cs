using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Founderizer.Windows.Pages;

/// <summary>What a request's controls do: a press on an option, ticks and their send, his words in the answer box (his one
/// reply), his answer, and the open state that the screen keeps for each request while its page shows (Show all,
/// Details).</summary>
internal interface IAnswers
{
    void Press(long need, int choice);
    void Tick(long need, IReadOnlyCollection<int> choices);
    void Type(long need, string text);
    void Answer(long need);
    bool CanSendTicks(int ticked);
    /// <summary>The plus of a request's answer box: Windows' picker, and the files go to its composer ("need:&lt;id&gt;").</summary>
    void AddFiles(long need) { }
    /// <summary>A chip of the answer box: its cross (false) or Send it up again (true).</summary>
    void Chip(long need, FileChip chip, bool again) { }
    /// <summary>The request's open part: "more" (Show all, Details).</summary>
    bool IsOpen(long need, string part);
    void SetOpen(long need, string part, bool open);
}

/// <summary>A request's options and its answer box, as the pictures draw them in a chat's card (rows of 14) and in the
/// request at hand (rows of 15, 44 high). A press sends that option (OptionsKind.Press); a quick reply fills an empty
/// box and sends nothing; ticks (options that combine) mark each pressed row, and "Send N" sends them. An option whose
/// press waits for the store says "Sending…" at its end after a second.</summary>
internal sealed class AnswerParts
{
    private readonly IAnswers answers;
    private readonly bool step;
    private readonly StackPanel options;
    private readonly Field answerBox;
    private readonly Button sendTicks;
    private readonly TextBlock sendTicksWords;
    private readonly HashSet<int> ticked = new();
    private readonly List<(Border Square, FrameworkElement Check, TextBlock Sending)> rows = new();
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer? sendingTimer;
    private long need;
    private OptionsModel shown = new();

    public AnswerParts(IAnswers answers, bool step)
    {
        this.answers = answers;
        this.step = step;
        options = new StackPanel { Spacing = step ? 8 : 7 };
        answerBox = new Field(step ? 44 : 40, step ? 15 : 14, 42);
        answerBox.Typed += text => answers.Type(need, text);
        answerBox.PlusPressed += () => answers.AddFiles(need);
        answerBox.Sent += () =>
        {
            answers.Answer(need);
            answerBox.Clear();
        };
        sendTicks = Buttons.Plain("");
        sendTicksWords = (TextBlock)((Border)sendTicks.Content).Child;
        sendTicks.HorizontalAlignment = HorizontalAlignment.Left;
        sendTicks.Click += (_, _) =>
        {
            if (ticked.Count == 0) return;
            answers.Tick(need, ticked.OrderBy(i => i).ToList());
            ticked.Clear();
            DrawTicks();
        };
        sendingTimer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()?.CreateTimer();
        if (sendingTimer is { } timer)
        {
            timer.Interval = TimeSpan.FromSeconds(1);
            timer.IsRepeating = false;
            timer.Tick += (_, _) => DrawSending(true);
        }
    }

    public StackPanel Options => options;
    public Field Box => answerBox;

    public void Show(long id, OptionsModel model, AnswerBoxModel box, bool canSend)
    {
        bool same = id == need && model == shown;
        if (id != need)
        {
            answerBox.Load(box.Draft);
            ticked.Clear();
        }
        need = id;
        answerBox.Show(box.Placeholder, box.ShowsPlus, canSend);
        answerBox.Hovers(box.PlusHover, box.SendHover);
        answerBox.ShowChips(box.Chips.Select(chip => (UIElement)new FileChipView(chip, (c, again) => answers.Chip(id, c, again))).ToList());
        if (same)
        {
            DrawTicks();
            return;
        }
        var waitingBefore = shown.WaitingPress;
        shown = model;
        options.Children.Clear();
        rows.Clear();
        for (int i = 0; i < model.Labels.Count; i++)
        {
            int choice = i;
            string label = model.Labels[i];
            var row = Row(label, model.Kind == OptionsKind.Ticks, model.SendingWords);
            row.Click += (_, _) =>
            {
                switch (model.Kind)
                {
                    case OptionsKind.Press:
                        answers.Press(need, choice);
                        break;
                    case OptionsKind.Ticks:
                        if (!ticked.Remove(choice)) ticked.Add(choice);
                        DrawTicks();
                        break;
                    case OptionsKind.QuickReplies:
                        if (answerBox.Box.Text.Trim().Length == 0)
                        {
                            answerBox.Load(label);
                            answers.Type(need, label);
                        }
                        break;
                }
            };
            options.Children.Add(row);
        }
        if (model.Kind == OptionsKind.Ticks) options.Children.Add(sendTicks);
        DrawTicks();
        if (model.WaitingPress != waitingBefore)
        {
            DrawSending(false);
            if (model.WaitingPress is not null) sendingTimer?.Start();
        }
    }

    private void DrawTicks()
    {
        for (int i = 0; i < rows.Count; i++)
        {
            bool on = ticked.Contains(i);
            rows[i].Square.Background = on ? Look.Brush(Look.Accent) : Look.Brush(Look.White(0));
            rows[i].Square.BorderBrush = on ? Look.Brush(Look.Accent) : Look.Brush(Look.White(0.45));
            rows[i].Check.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        }
        sendTicksWords.Text = OptionsModel.SendWords(ticked.Count);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(sendTicks, sendTicksWords.Text);
        sendTicks.Visibility = shown.Kind == OptionsKind.Ticks && ticked.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        sendTicks.IsEnabled = answers.CanSendTicks(ticked.Count);
    }

    private void DrawSending(bool on)
    {
        for (int i = 0; i < rows.Count; i++)
            rows[i].Sending.Visibility = on && shown.WaitingPress == i ? Visibility.Visible : Visibility.Collapsed;
    }

    private Button Row(string label, bool tick, string sendingWords)
    {
        var words = Look.Words(label, step ? 15 : 14, 20);
        var square = new Border
        {
            Width = 16,
            Height = 16,
            CornerRadius = new CornerRadius(3),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var check = Icons.Of(Icons.Check, Look.Brush(global::Windows.UI.Color.FromArgb(255, 255, 255, 255)), 12);
        check.HorizontalAlignment = HorizontalAlignment.Center;
        check.VerticalAlignment = VerticalAlignment.Center;
        square.Child = check;
        var sending = Look.Words(sendingWords, 12, 16, Look.Muted, wrap: false);
        sending.VerticalAlignment = VerticalAlignment.Center;
        sending.Visibility = Visibility.Collapsed;
        var line = new Grid { ColumnSpacing = 10 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (tick) line.Children.Add(square);
        else line.ColumnSpacing = 0;
        Grid.SetColumn(words, 1);
        line.Children.Add(words);
        Grid.SetColumn(sending, 2);
        line.Children.Add(sending);
        rows.Add((square, check, sending));
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Content = new Border
            {
                Background = Look.Brush(Look.White(0.05)),
                BorderBrush = Look.Brush(Look.White(0.10)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(4),
                Padding = step ? new Thickness(14, 11, 14, 11) : new Thickness(12, 10, 12, 10),
                MinHeight = step ? 44 : 0,
                Child = line,
            },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        return button;
    }
}

/// <summary>A request's card in a chat (NeedRequestCard), as pictures 1, 2a and 16 draw it: its title, its reason
/// (three lines, or whole after Show all, with what it needs from him and its details), "Show all" or "Show less" alone
/// on its row (Discuss left the product: the owner, 13 November 2026), who asks and when, the options and the answer
/// box, his one reply. After his answer the card folds to its title and his answer with a check.</summary>
internal sealed class RequestCardView : Grid
{
    private readonly IAnswers answers;
    private readonly StackPanel stack = new() { Spacing = 10 };
    private readonly TextBlock title = Look.Words("", semibold: true);
    private readonly ContentControl why = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly ContentControl task = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 11, 0, 0) };
    private readonly TextBlock todoLabel = Look.Words("", 12, 16, Look.Muted, semibold: true);
    private readonly ContentControl todo = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly ContentControl details = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly Grid links = new();
    private readonly TextBlock more = Look.Words("", 12, 16, Look.Link, wrap: false);
    private readonly ContentControl moreChevron = new() { IsTabStop = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button moreButton;
    private readonly StackPanel from = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly AgentGlyph fromMark = new() { Side = 16, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock fromWords = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly StackPanel answered = new() { Orientation = Orientation.Horizontal, Spacing = 5, Margin = new Thickness(0, -6, 0, 0) };
    private readonly TextBlock answeredWords = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly FrameworkElement answeredCheck = Icons.Of(Icons.Check, Look.Muted, 12);
    private readonly AnswerParts parts;
    private RequestCard? card;
    private bool canSend;
    private string shownWhy = "", shownTask = "", shownTodo = "", shownDetails = "";
    private bool shownWhole;

    public RequestCardView(IAnswers answers)
    {
        this.answers = answers;
        parts = new AnswerParts(answers, step: false);

        moreButton = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, Children = { more, moreChevron } },
        };
        moreButton.Click += (_, _) =>
        {
            if (card is not { } c) return;
            answers.SetOpen(c.Id, "more", !answers.IsOpen(c.Id, "more"));
            Show(c, canSend);
        };
        links.Children.Add(moreButton);
        from.Children.Add(fromMark);
        from.Children.Add(fromWords);
        todoLabel.Margin = new Thickness(0, 2, 0, 0);
        answeredCheck.VerticalAlignment = VerticalAlignment.Center;
        answered.Children.Add(answeredCheck);
        answered.Children.Add(answeredWords);

        stack.Children.Add(title);
        stack.Children.Add(answered);
        stack.Children.Add(why);
        stack.Children.Add(task);
        stack.Children.Add(details);
        stack.Children.Add(todoLabel);
        stack.Children.Add(todo);
        stack.Children.Add(links);
        stack.Children.Add(from);
        stack.Children.Add(parts.Options);
        stack.Children.Add(parts.Box);
        Children.Add(new Border
        {
            Background = Look.SurfaceBrush,
            BorderBrush = Look.CardEdge,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(16),
            Child = stack,
        });
    }

    public void Show(RequestCard next, bool sendable)
    {
        card = next;
        canSend = sendable;
        title.Text = next.Title;
        bool folded = next.Folded;
        // His answer in his own words is his message bubble (the Mac's rule of 14 November 2026): the card then folds to
        // its title, with no answer line and no check; a pressed option keeps both.
        answered.Visibility = folded && next.ShowsAnswerLine ? Visibility.Visible : Visibility.Collapsed;
        answeredCheck.Visibility = next.ShowsCheck ? Visibility.Visible : Visibility.Collapsed;
        answeredWords.Text = next.AnswerWords;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, folded ? next.FoldedWords : "");
        // The Mac's card of Founderizer 0.1.239 (NeedRequestCard; the owner, 15 November 2026: "the task itself need to
        // be very clear and also formatted like the chat messages (links, code format etc)"): the reason and the task are
        // message text, a message's room apart (21), and the link shows only when something stands behind it.
        var b = next.Body;
        bool whole = answers.IsOpen(next.Id, "more") && b.MoreClosed is not null;
        if (b.Why != shownWhy || whole != shownWhole)
        {
            shownWhy = b.Why;
            shownWhole = whole;
            if (b.Short || whole) why.Content = Blocks.Of(b.WhyBlocks, b.Why, card: true, copies: true);
            else
            {
                // The start of a long reason, with its inline marks, in three lines, until Show all.
                var block = Blocks.Marked(b.FoldedWhy);
                block.MaxLines = 3;
                block.TextTrimming = TextTrimming.CharacterEllipsis;
                why.Content = block;
            }
        }
        why.Visibility = folded ? Visibility.Collapsed : Visibility.Visible;
        bool taskShows = !folded && b.Task is not null;
        task.Visibility = taskShows ? Visibility.Visible : Visibility.Collapsed;
        if (taskShows && b.Task != shownTask) { shownTask = b.Task!; task.Content = Blocks.Of(b.TaskBlocks, b.Task!, card: true, copies: true); }
        // Behind the link: the details (a door's script is one fenced block from the hub already, door_script_details),
        // then a task that stays behind it (a door call, a conversation's item), under its label.
        bool detailsShow = !folded && whole && b.Details is not null;
        details.Visibility = detailsShow ? Visibility.Visible : Visibility.Collapsed;
        if (detailsShow && b.Details != shownDetails)
        {
            shownDetails = b.Details!;
            details.Content = Blocks.Of(b.DetailsBlocks, b.Details!, script: b.DetailsIsScript, card: true, copies: true);
        }
        bool todoShows = !folded && whole && b.TodoBehind is not null;
        todoLabel.Text = b.TodoLabel;
        todoLabel.Visibility = todo.Visibility = todoShows ? Visibility.Visible : Visibility.Collapsed;
        if (todoShows && b.TodoBehind != shownTodo) { shownTodo = b.TodoBehind!; todo.Content = Blocks.Of(b.TodoBehindBlocks, b.TodoBehind!, card: true, copies: true); }
        more.Text = (whole ? b.MoreOpen : b.MoreClosed) ?? "";
        moreChevron.Content = Icons.Of(whole ? Icons.ChevronDown : Icons.ChevronRight, Look.Link, 12);
        moreChevron.Visibility = b.MoreChevron ? Visibility.Visible : Visibility.Collapsed;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(moreButton, more.Text);
        moreButton.Visibility = folded || b.MoreClosed is null ? Visibility.Collapsed : Visibility.Visible;
        links.Visibility = moreButton.Visibility;
        from.Visibility = folded ? Visibility.Collapsed : Visibility.Visible;
        fromMark.Mark = next.Mark;
        fromMark.Visibility = next.Mark is null ? Visibility.Collapsed : Visibility.Visible;
        fromWords.Text = next.From;
        parts.Options.Visibility = parts.Box.Visibility = folded ? Visibility.Collapsed : Visibility.Visible;
        if (!folded) parts.Show(next.Id, next.Options, next.Answer, sendable);
    }
}

/// <summary>The request at hand in Needs you (NeedStep), as picture 3 and picture 2b of the second set draw it: the
/// asking agent's mark at 48, who asks and how long ago with the orange hourglass while an agent's work waits on it, the
/// title, the reason, "Details" with its chevron (opened: what it needs from him and its details, from the leading edge),
/// the options and the answer box, his one reply, with nothing under it (Discuss left the product).</summary>
internal sealed class RequestStepView : StackPanel
{
    private readonly IAnswers answers;
    private readonly AgentGlyph mark = new() { Side = 48, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock fromWords = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly FrameworkElement hourglass = Icons.Of(Icons.Hourglass, Look.Orange);
    private readonly TextBlock title = Look.Words("", 20, 28, semibold: true);
    private readonly ContentControl why = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 12, 0, 0) };
    private readonly ContentControl task = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 12, 0, 0) };
    private readonly Button details;
    private readonly TextBlock detailsWords = Look.Words("", 15, 20, Look.Link, wrap: false);
    private readonly ContentControl chevron = new() { IsTabStop = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel more = new() { Spacing = 12, Margin = new Thickness(0, 14, 0, 0) };
    private readonly StackPanel answered = new() { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 18, 0, 0) };
    private readonly TextBlock answeredWords = Look.Words("", 15, 20, Look.Muted, wrap: false);
    private readonly FrameworkElement answeredCheck = Icons.Of(Icons.Check, Look.Muted, 12);
    private readonly AnswerParts parts;
    private RequestStep? step;
    private bool canSend;
    private string shownWhy = "", shownTask = "";

    public RequestStepView(IAnswers answers)
    {
        this.answers = answers;
        Width = 540;
        HorizontalAlignment = HorizontalAlignment.Center;
        parts = new AnswerParts(answers, step: true);
        title.FontFamily = Look.Display;
        title.TextAlignment = TextAlignment.Center;
        title.Margin = new Thickness(0, 14, 0, 0);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(title, "NeedAtHand");

        var from = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 14, 0, 0),
            Children = { fromWords, hourglass },
        };
        details = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 10, 0, 0),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 3,
                Children = { detailsWords, chevron },
            },
        };
        details.Click += (_, _) =>
        {
            if (step is not { } s) return;
            answers.SetOpen(s.Id, "more", !answers.IsOpen(s.Id, "more"));
            Show(s, canSend);
        };
        parts.Options.Margin = new Thickness(0, 24, 0, 0);
        parts.Box.Margin = new Thickness(0, 8, 0, 0);
        Children.Add(mark);
        Children.Add(from);
        Children.Add(title);
        Children.Add(why);
        Children.Add(task);
        Children.Add(details);
        Children.Add(more);
        answeredCheck.VerticalAlignment = VerticalAlignment.Center;
        answered.Children.Add(answeredCheck);
        answered.Children.Add(answeredWords);
        Children.Add(answered);
        Children.Add(parts.Options);
        Children.Add(parts.Box);
    }

    public void Show(RequestStep next, bool sendable)
    {
        step = next;
        canSend = sendable;
        mark.Mark = next.Mark;
        fromWords.Text = next.From;
        hourglass.Visibility = next.Waits ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(hourglass, next.Waits ? next.WaitWords : null);
        hourglass.IsHitTestVisible = next.Waits;
        title.Text = next.Title;
        // The Mac's request at hand of Founderizer 0.1.239 (NeedStep): the reason and the task as message text in the
        // step's one size, the task under the reason; both in the middle as a step's line, or from the leading edge when
        // the task is a list, a command or several paragraphs (CentredClosed, CentredOpen); a long reason opens in place.
        var b = next.Body;
        bool open = answers.IsOpen(next.Id, "more") && b.MoreClosed is not null;
        bool centred = open ? b.CentredOpen : b.CentredClosed;
        var whyKey = (b.Short || open ? "whole\u001f" : "start\u001f") + centred + "\u001f" + b.Why;
        if (whyKey != shownWhy)
        {
            shownWhy = whyKey;
            if (b.Short || open) why.Content = Blocks.Of(b.WhyBlocks, b.Why, measure: Blocks.Measure.Step, copies: true, centred: centred);
            else
            {
                // The start of a long reason, with its inline marks, in three lines, until Show all.
                var start = Blocks.Marked(b.FoldedWhy, size: 15, lineHeight: 23, codeSize: 13.5);
                start.MaxLines = 3;
                start.TextTrimming = TextTrimming.CharacterEllipsis;
                start.TextAlignment = centred ? TextAlignment.Center : TextAlignment.Left;
                why.Content = start;
            }
        }
        task.Visibility = b.Task is null ? Visibility.Collapsed : Visibility.Visible;
        var taskKey = centred + "\u001f" + b.Task;
        if (b.Task is { } words && taskKey != shownTask)
        {
            shownTask = taskKey;
            task.Content = Blocks.Of(b.TaskBlocks, words, measure: Blocks.Measure.Step, copies: true, centred: centred);
        }
        detailsWords.Text = (open ? b.MoreOpen ?? b.MoreClosed : b.MoreClosed) ?? "";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(details, detailsWords.Text);
        details.Visibility = b.MoreClosed is null ? Visibility.Collapsed : Visibility.Visible;
        chevron.Content = Icons.Of(open ? Icons.ChevronDown : Icons.ChevronRight, Look.Link, 12);
        chevron.Visibility = b.MoreChevron ? Visibility.Visible : Visibility.Collapsed;
        more.Children.Clear();
        if (open)
        {
            // Behind the link, from the leading edge: the details (a door's script wraps), then a task that stays there.
            if (b.Details is { } text)
                more.Children.Add(Blocks.Of(b.DetailsBlocks, text, script: b.DetailsIsScript, measure: Blocks.Measure.Step, copies: true));
            if (b.TodoBehind is { } behind)
            {
                more.Children.Add(Look.Words(b.TodoLabel, 15, 23, Look.Muted, semibold: true));
                more.Children.Add(Blocks.Of(b.TodoBehindBlocks, behind, measure: Blocks.Measure.Step, copies: true));
            }
        }
        more.Visibility = more.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        // An ended request at hand (he chose it among the answered ones): his answer with a check, and nothing to press.
        answered.Visibility = next.Ended ? Visibility.Visible : Visibility.Collapsed;
        answeredCheck.Visibility = next.ShowsCheck ? Visibility.Visible : Visibility.Collapsed;
        answeredWords.Text = next.AnswerWords;
        parts.Options.Visibility = parts.Box.Visibility = next.Ended ? Visibility.Collapsed : Visibility.Visible;
        if (!next.Ended) parts.Show(next.Id, next.Options, next.Answer, sendable);
    }
}
