using System;
using System.Collections.Generic;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages;

/// <summary>The kinds of a thread's rows: a chat's stamp, his message, the agent's reply, a request card and the
/// "Thinking" line; a task's notes are replies, and its last row says who did the work.</summary>
internal enum RowKind { Stamp, Own, Reply, Request, Waiting, Who }

/// <summary>One row of a thread: its key, its kind, the room above it, and the model it draws. Equal by value, so a row
/// whose model did not change is not drawn again.</summary>
internal sealed record ThreadItem(string Key, RowKind Kind, double Gap, object Model);

/// <summary>The "Thinking" line's model: the library's waiting line and the agent's mark beside it.</summary>
internal sealed record WaitingRow(ChatWaiting Line, MarkLook Mark);

/// <summary>What a thread's rows need from their page: the request controls, and whether a request's answer can go.</summary>
internal interface IThreadContext : IAnswers
{
    bool CanSendAnswer(RequestCard card);
}

/// <summary>A thread's rows in a virtualized list (ItemsRepeater in a ScrollViewer: only the rows in view and near it
/// exist), in a column of at most 692. A new model changes only the rows that came, went, moved or changed.</summary>
internal sealed class ThreadList
{
    private readonly KeyedItems<ThreadItem> items = new(item => item.Key, item => (int)item.Kind);
    private readonly ItemsRepeater repeater;

    public ThreadList(IThreadContext context, Thickness padding)
    {
        repeater = new ItemsRepeater
        {
            Layout = new StackLayout { Spacing = 0 },
            ItemTemplate = new RowFactory(context),
            ItemsSource = items.Items,
            MaxWidth = 692,
            Margin = padding,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        Scroll = new ScrollViewer
        {
            Content = new Grid { Children = { repeater }, Padding = new Thickness(23.5, 0, 23.5, 0) },
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalAnchorRatio = 1,
            IsTabStop = false,
        };
    }

    public ScrollViewer Scroll { get; }

    public int Count => items.Items.Count;

    /// <summary>He is at the end, or near it: a new row keeps the end in view.</summary>
    public bool AtEnd => Scroll.ScrollableHeight - Scroll.VerticalOffset < 24;

    /// <summary>The rows of a new model; only the rows that came, went, moved or changed are drawn again. The first
    /// rows of a long thread go in at once: the list takes them without the repeater, which then reads them once.</summary>
    public void Show(IReadOnlyList<ThreadItem> next)
    {
        bool first = items.Items.Count == 0 && next.Count > 32;
        if (first) repeater.ItemsSource = null;
        items.Show(next);
        if (first) repeater.ItemsSource = items.Items;
    }

    /// <summary>Goes to the end of the thread, without motion.</summary>
    public void ToEnd() => Scroll.ChangeView(null, Scroll.ScrollableHeight, null, true);

    /// <summary>The rows' room: 28 between rows (21 in a task's thread), none under a stamp, which keeps its own 14.</summary>
    public static double GapAfter(RowKind? previous, double gap) => previous is null or RowKind.Stamp ? 0 : gap;
}

/// <summary>Makes and reuses the view of each kind of row: the repeater asks for a row's view when it comes into view
/// and gives it back when it leaves, so a long thread holds the views of the rows near the view only.</summary>
internal sealed class RowFactory : IElementFactory
{
    private readonly IThreadContext context;
    private readonly Dictionary<RowKind, Stack<RowView>> pool = new();

    public RowFactory(IThreadContext context) => this.context = context;

    /// <summary>For the scroll reading: the rows that came into view, and the views that had to be made for them.</summary>
    public static int Realized, Made;

    public UIElement GetElement(ElementFactoryGetArgs args)
    {
        var holder = (Holder<ThreadItem>)args.Data;
        var kind = holder.Item.Kind;
        Realized++;
        var view = pool.TryGetValue(kind, out var free) && free.Count > 0 ? free.Pop() : Make(kind);
        view.Hold(holder);
        return view;
    }

    public void RecycleElement(ElementFactoryRecycleArgs args)
    {
        if (args.Element is not RowView view) return;
        view.Hold(null);
        if (!pool.TryGetValue(view.Kind, out var free)) pool[view.Kind] = free = new Stack<RowView>();
        free.Push(view);
    }

    private RowView Make(RowKind kind)
    {
        Made++;
        return MakeView(kind);
    }

    private RowView MakeView(RowKind kind) => kind switch
    {
        RowKind.Stamp => new StampRowView(),
        RowKind.Own => new OwnRowView(),
        RowKind.Reply => new ReplyRowView(),
        RowKind.Request => new RequestRowView(context),
        RowKind.Waiting => new WaitingRowView(),
        _ => new WhoRowView(),
    };
}

/// <summary>A row's view: its kind, and the room above it.</summary>
internal abstract class RowView : HeldView<ThreadItem>
{
    public abstract RowKind Kind { get; }

    protected override void Draw(ThreadItem item)
    {
        Padding = new Thickness(0, item.Gap, 0, 0);
        DrawRow(item);
    }

    protected abstract void DrawRow(ThreadItem item);
}

/// <summary>The time stamp over a message (ChatStamp): 12 on 16, muted, in the middle, 14 above the row under it.</summary>
internal sealed class StampRowView : RowView
{
    private readonly TextBlock words = Look.Words("", 12, 16, Look.Muted, wrap: false);

    public StampRowView()
    {
        words.HorizontalAlignment = HorizontalAlignment.Center;
        words.Margin = new Thickness(0, 0, 0, 14);
        Children.Add(words);
    }

    public override RowKind Kind => RowKind.Stamp;

    protected override void DrawRow(ThreadItem item) => words.Text = ((ChatRow)item.Model).Text;
}

/// <summary>His message in his bubble (OwnerBubble): at the right, at most 72 % of the column, a corner of 16.</summary>
internal sealed class OwnRowView : RowView
{
    private readonly TextBlock words = Blocks.Selectable("", lineHeight: 20);
    private readonly Border bubble;

    public OwnRowView()
    {
        bubble = new Border
        {
            Background = Look.OwnBrush,
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(16, 12, 16, 12),
            HorizontalAlignment = HorizontalAlignment.Right,
            MaxWidth = 692 * 0.72,
            Child = words,
        };
        Children.Add(bubble);
    }

    public override RowKind Kind => RowKind.Own;

    protected override void DrawRow(ThreadItem item) => words.Text = item.Model switch
    {
        ChatRow row => row.Text,
        string asks => asks,
        _ => "",
    };
}

/// <summary>An agent's reply, or a task's progress note, as plain text in its blocks (AgentReply), 14 on 22.</summary>
internal sealed class ReplyRowView : RowView
{
    private readonly ContentControl content = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    // Most replies are one paragraph: the view keeps its one text block and changes only its words.
    private readonly TextBlock paragraph = Blocks.Selectable("");

    public ReplyRowView() => Children.Add(content);

    public override RowKind Kind => RowKind.Reply;

    protected override void DrawRow(ThreadItem item)
    {
        var (blocks, text) = item.Model switch
        {
            ChatRow row => (row.Blocks, row.Text),
            NoteRow note => (note.Blocks, note.Text),
            _ => (ValueList<MessageBlock>.Empty, ""),
        };
        if (blocks.Count <= 1 && (blocks.Count == 0 || blocks[0].Kind == MessageBlock.Kinds.Paragraph))
        {
            paragraph.Text = InlineMarks.Plain(blocks.Count == 0 ? text : blocks[0].Text);
            content.Content = paragraph;
        }
        else content.Content = Blocks.Of(blocks, text);
    }
}

/// <summary>A request card at its place in the chat.</summary>
internal sealed class RequestRowView : RowView
{
    private readonly IThreadContext context;
    private readonly RequestCardView card;

    public RequestRowView(IThreadContext context)
    {
        this.context = context;
        card = new RequestCardView(context);
        Children.Add(card);
    }

    public override RowKind Kind => RowKind.Request;

    protected override void DrawRow(ThreadItem item)
    {
        var request = ((ChatRow)item.Model).Request!;
        card.Show(request, context.CanSendAnswer(request));
    }
}

/// <summary>"Thinking" under his last message (ChatWaitingLine): the agent's mark at 16 and the words, 12 on 16, muted;
/// while the agent works, the mark moves and a band of light crosses the words, in the compositor.</summary>
internal sealed class WaitingRowView : RowView
{
    private readonly AgentGlyph mark = new() { Side = 16, VerticalAlignment = VerticalAlignment.Center };
    private readonly ShimmerText words = new() { VerticalAlignment = VerticalAlignment.Center };

    public WaitingRowView()
    {
        Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { mark, words } });
    }

    public override RowKind Kind => RowKind.Waiting;

    protected override void DrawRow(ThreadItem item)
    {
        var row = (WaitingRow)item.Model;
        mark.Mark = row.Mark;
        words.Text = row.Line.Says;
        words.Shimmer = row.Line.Moving && row.Mark.Moves;
    }
}

/// <summary>Who did a task's work, at the end of its thread: 12 on 16, muted.</summary>
internal sealed class WhoRowView : RowView
{
    private readonly TextBlock words = Look.Words("", 12, 16, Look.Muted, wrap: false);

    public WhoRowView() => Children.Add(words);

    public override RowKind Kind => RowKind.Who;

    protected override void DrawRow(ThreadItem item) => words.Text = (string)item.Model;
}
