using System;
using System.Collections.Generic;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Founderizer.Windows.Pages;

/// <summary>What a request's controls do: a press on an option, his words in the answer box, and his answer.</summary>
internal interface IAnswers
{
    void Press(long need, int choice);
    void Type(long need, string text);
    void Answer(long need);
}

/// <summary>A request's options and its answer box, as the pictures draw them in a chat's card (rows of 14) and in the
/// request at hand (rows of 15, 44 high). A press sends that option (OptionsKind.Press); a quick reply fills an empty
/// box and sends nothing. Ticks with "Send N" wait for their picture: a press on a tick does nothing yet.</summary>
internal sealed class AnswerParts
{
    private readonly IAnswers answers;
    private readonly bool step;
    private readonly StackPanel options;
    private readonly Field answerBox;
    private long need;
    private OptionsModel shown = new();

    public AnswerParts(IAnswers answers, bool step)
    {
        this.answers = answers;
        this.step = step;
        options = new StackPanel { Spacing = step ? 8 : 7 };
        answerBox = new Field(step ? 44 : 40, step ? 15 : 14, 42);
        answerBox.Typed += text => answers.Type(need, text);
        answerBox.Sent += () =>
        {
            answers.Answer(need);
            answerBox.Clear();
        };
    }

    public StackPanel Options => options;
    public Field Box => answerBox;

    public void Show(long id, OptionsModel model, AnswerBoxModel box, bool canSend)
    {
        bool same = id == need && model == shown;
        if (id != need) answerBox.Load(box.Draft);
        need = id;
        answerBox.Show(box.Placeholder, box.ShowsPlus, canSend);
        if (same) return;
        shown = model;
        options.Children.Clear();
        for (int i = 0; i < model.Labels.Count; i++)
        {
            int choice = i;
            string label = model.Labels[i];
            var row = Row(label);
            row.Click += (_, _) =>
            {
                switch (model.Kind)
                {
                    case OptionsKind.Press:
                        answers.Press(need, choice);
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
    }

    private Button Row(string label)
    {
        var words = Look.Words(label, step ? 15 : 14, 20);
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
                Child = words,
            },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        return button;
    }
}

/// <summary>A request's card in a chat (NeedRequestCard), as picture 1 draws it: its title, its reason, "Show all" or
/// "Details" and Discuss, who asks and when, the options and the answer box. Show all, Details and Discuss do nothing
/// yet: their opened states wait for their pictures. An answered card (folded to its title and answer) waits too, so the
/// chat leaves it out.</summary>
internal sealed class RequestCardView : Grid
{
    private readonly StackPanel stack = new() { Spacing = 10 };
    private readonly TextBlock title = Look.Words("", semibold: true);
    private readonly ContentControl why = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly Grid links = new();
    private readonly TextBlock more = Look.Words("", 12, 16, Look.Link, wrap: false);
    private readonly Button moreButton;
    private readonly Button discuss;
    private readonly StackPanel from = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly AgentGlyph fromMark = new() { Side = 16, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock fromWords = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly AnswerParts parts;
    private string shownWhy = "";

    public RequestCardView(IAnswers answers)
    {
        parts = new AnswerParts(answers, step: false);

        moreButton = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            Content = more,
        };
        var discussWords = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { Icons.Of(Icons.Discuss), Look.Words("Discuss", wrap: false) },
        };
        discuss = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Content = new Border
            {
                Height = 32,
                Padding = new Thickness(11, 0, 11, 0),
                CornerRadius = new CornerRadius(4),
                Background = Look.Brush(Look.White(0.06)),
                BorderBrush = Look.FieldEdge(32, Look.White(0.08), Look.White(0.04)),
                BorderThickness = new Thickness(1),
                Child = discussWords,
            },
        };
        links.Children.Add(moreButton);
        links.Children.Add(discuss);
        from.Children.Add(fromMark);
        from.Children.Add(fromWords);

        stack.Children.Add(title);
        stack.Children.Add(why);
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

    public void Show(RequestCard card, bool canSend)
    {
        title.Text = card.Title;
        if (card.Why != shownWhy)
        {
            shownWhy = card.Why;
            if (card.Short) why.Content = Blocks.Of(MessageBlock.Parse(card.Why), card.Why);
            else
            {
                var block = Blocks.Selectable(InlineMarks.Plain(card.Why));
                block.MaxLines = 3;
                block.TextTrimming = TextTrimming.CharacterEllipsis;
                why.Content = block;
            }
        }
        more.Text = card.MoreClosed ?? "";
        moreButton.Visibility = card.MoreClosed is null ? Visibility.Collapsed : Visibility.Visible;
        discuss.Visibility = card.ShowsDiscuss ? Visibility.Visible : Visibility.Collapsed;
        links.Visibility = card.MoreClosed is null && !card.ShowsDiscuss ? Visibility.Collapsed : Visibility.Visible;
        fromMark.Mark = card.Mark;
        fromMark.Visibility = card.Mark is null ? Visibility.Collapsed : Visibility.Visible;
        fromWords.Text = card.From;
        parts.Show(card.Id, card.Options, card.Answer, canSend);
    }
}

/// <summary>The request at hand in Needs you (NeedStep), as picture 3 draws it: the asking agent's mark at 48, who asks
/// and how long ago with the orange hourglass while an agent's work waits on it, the title, the reason, "Details" with
/// its chevron, the options, the answer box and "Discuss". Details and Discuss do nothing yet: their opened states wait
/// for their pictures.</summary>
internal sealed class RequestStepView : StackPanel
{
    private readonly AgentGlyph mark = new() { Side = 48, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock fromWords = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly FrameworkElement hourglass = Icons.Of(Icons.Hourglass, Look.Orange);
    private readonly TextBlock title = Look.Words("", 20, 28, semibold: true);
    private readonly TextBlock why = Look.Words("", 15, 23);
    private readonly Button details;
    private readonly TextBlock detailsWords = Look.Words("", 15, 20, Look.Link, wrap: false);
    private readonly FrameworkElement chevron = Icons.Of(Icons.ChevronRight, Look.Link, 12);
    private readonly AnswerParts parts;
    private readonly Button discuss;

    public RequestStepView(IAnswers answers)
    {
        Width = 540;
        HorizontalAlignment = HorizontalAlignment.Center;
        parts = new AnswerParts(answers, step: true);
        title.FontFamily = Look.Display;
        title.TextAlignment = TextAlignment.Center;
        title.Margin = new Thickness(0, 14, 0, 0);
        why.TextAlignment = TextAlignment.Center;
        why.Margin = new Thickness(0, 12, 0, 0);
        why.IsTextSelectionEnabled = true;

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
        chevron.VerticalAlignment = VerticalAlignment.Center;
        parts.Options.Margin = new Thickness(0, 24, 0, 0);
        parts.Box.Margin = new Thickness(0, 8, 0, 0);
        discuss = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 18, 0, 0),
            Content = Look.Words("Discuss", 15, 20, Look.Link, wrap: false),
        };

        Children.Add(mark);
        Children.Add(from);
        Children.Add(title);
        Children.Add(why);
        Children.Add(details);
        Children.Add(parts.Options);
        Children.Add(parts.Box);
        Children.Add(discuss);
    }

    public void Show(RequestStep step, bool canSend)
    {
        mark.Mark = step.Mark;
        fromWords.Text = step.From;
        hourglass.Visibility = step.Waits ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(hourglass, step.Waits ? step.WaitWords : null);
        hourglass.IsHitTestVisible = step.Waits;
        title.Text = step.Title;
        why.Text = step.Short ? InlineMarks.Plain(step.Why) : step.ShortWhy;
        why.MaxLines = step.Short ? 0 : 3;
        why.TextTrimming = step.Short ? TextTrimming.None : TextTrimming.CharacterEllipsis;
        why.TextAlignment = step.Centred ? TextAlignment.Center : TextAlignment.Left;
        detailsWords.Text = step.MoreClosed ?? "";
        details.Visibility = step.MoreClosed is null ? Visibility.Collapsed : Visibility.Visible;
        chevron.Visibility = step.MoreChevron ? Visibility.Visible : Visibility.Collapsed;
        discuss.Visibility = step.Discussable && !step.ShowsDiscussion ? Visibility.Visible : Visibility.Collapsed;
        parts.Show(step.Id, step.Options, step.Answer, canSend);
    }
}
