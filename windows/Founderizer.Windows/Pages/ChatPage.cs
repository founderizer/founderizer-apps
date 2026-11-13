using System;
using System.Collections.Generic;
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
}

/// <summary>One agent's chat with its panel, as pictures 1 and 2 draw it (the Mac's ManagerView and AgentStatusPanel):
/// the pill over the chat, the chat at its end with its top faded under the pill, the stamps, his bubbles, the replies,
/// the request cards in their places, the "Thinking" line, the composer, and the panel at the right. The rows are
/// virtualized, and a new state changes only the rows that changed.
///
/// States that no picture shows wait and are not drawn: the time and the state beside his message ("Sending…", "Not
/// sent"), files, an answered card, "Reading…", the empty chat, the composer's notes, and a wait other than "Thinking".</summary>
internal sealed class ChatPage : Grid, IPageView, IThreadContext
{
    private readonly string agent;
    private readonly IFleetSource source;
    private readonly ThreadList thread;
    private readonly Border pill;
    private readonly AgentGlyph pillMark = new() { Side = 22, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock pillWords = Look.Words("", semibold: true, wrap: false);
    private readonly Field composer;
    private readonly AgentPanelView panel = new();
    private StoreState state = new();
    private DateTimeOffset now;
    private bool loaded;
    private int settle;

    public ChatPage(string agent, IFleetSource source)
    {
        this.agent = agent;
        this.source = source;
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
        composer.Sent += () =>
        {
            _ = source.SendMessageAsync(agent);
            composer.Clear();
        };

        var chat = new Grid { Children = { thread.Scroll, fade, shadow, pill, composer } };
        Children.Add(chat);
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

    public string Agent => agent;

    /// <summary>The chat's scroll, for the scroll reading (Readings.ScrollWhenAsked).</summary>
    public ScrollViewer Scroll => thread.Scroll;

    public void Show(StoreState next, DateTimeOffset at, bool reduceMotion)
    {
        state = next;
        now = at;
        var model = Screens.Chat(next, agent, at, ScreenContext.Local, reduceMotion);
        pillMark.Mark = model.PillMark;
        pillWords.Text = model.Label;
        panel.Show(model.Panel);

        composer.Visibility = model.Composer.ShowsField ? Visibility.Visible : Visibility.Collapsed;
        composer.Show(model.Composer.Placeholder, model.Composer.ShowsPlus, model.Composer.CanSend);
        var tint = Look.Tint(MarkLook.Of(next.MarkOf(agent), AgentState.Online, moves: false));
        composer.Tint(tint.Fill, tint.Ink);
        if (!loaded) composer.Load(model.Composer.Draft);

        bool atEnd = !loaded || thread.AtEnd;
        thread.Show(Rows(model));
        if (atEnd && thread.Count > 0) settle = loaded ? 2 : 6;
        loaded = true;
    }

    /// <summary>The model's rows as the thread's rows, with the room of picture 1 between them.</summary>
    private static List<ThreadItem> Rows(ChatModel model)
    {
        var rows = new List<ThreadItem>();
        RowKind? previous = null;
        void Add(string key, RowKind kind, object row)
        {
            rows.Add(new ThreadItem(key, kind, ThreadList.GapAfter(previous, 28), row));
            previous = kind;
        }
        foreach (var row in model.Rows)
        {
            switch (row.Kind)
            {
                case ChatRowKind.Stamp: Add(row.Key, RowKind.Stamp, row); break;
                case ChatRowKind.Message: Add(row.Key, RowKind.Own, row); break;
                case ChatRowKind.Reply: Add(row.Key, RowKind.Reply, row); break;
                case ChatRowKind.Request when row.Request is { Folded: false }: Add(row.Key, RowKind.Request, row); break;
            }
        }
        if (model.Waiting is { Shows: true } waiting && waiting.Line.Says == ChatWaiting.Working)
            Add("waiting", RowKind.Waiting, new WaitingRow(waiting.Line, model.WaitingMark));
        return rows;
    }

    public bool CanSendAnswer(RequestCard card) =>
        AnswerBoxModel.CanSend(state, now, card.Answer.Draft, card.Answer.Files.Count);

    public void Press(long need, int choice) => source.Press(need, choice);

    public void Type(long need, string text) => source.SetAnswerDraft(need, text);

    public void Answer(long need) => _ = source.AnswerAsync(need);
}
