using System;
using System.Collections.Generic;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages;

/// <summary>The kinds of a thread's rows: a chat's stamp, his message, the agent's reply, a request card and the
/// "Thinking" line; a task's notes are replies, and its last row says who did the work.</summary>
internal enum RowKind { Stamp, Own, Reply, Request, Waiting, Who, Earlier }

/// <summary>One row of a thread: its key, its kind, the room above it, and the model it draws. Equal by value, so a row
/// whose model did not change is not drawn again.</summary>
internal sealed record ThreadItem(string Key, RowKind Kind, double Gap, object Model);

/// <summary>The "Thinking" line's model: the library's waiting line and the agent's mark beside it.</summary>
internal sealed record WaitingRow(ChatWaiting Line, MarkLook Mark);

/// <summary>What a thread's rows need from their page: the request controls, and whether a request's answer can go.</summary>
internal interface IThreadContext : IAnswers
{
    bool CanSendAnswer(RequestCard card);

    /// <summary>"Earlier messages" over the first row: the chat shows more of its items.</summary>
    void ShowEarlier() { }

    /// <summary>A file of a message: its picture once its bytes came (null until then; the row draws again then), a
    /// press that opens it, and Read again.</summary>
    Microsoft.UI.Xaml.Media.ImageSource? Picture(FileTile tile) => null;
    void OpenFile(FileTile tile) { }
    void ReadAgain(FileTile tile) { }
}

/// <summary>His message with its files under it (picture 4).</summary>
internal sealed record OwnRow(ChatRow Row, ValueList<FileTile> Files);

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
        RowKind.Own => new OwnRowView(context),
        RowKind.Reply => new ReplyRowView(),
        RowKind.Request => new RequestRowView(context),
        RowKind.Waiting => new WaitingRowView(),
        RowKind.Earlier => new EarlierRowView(context),
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

/// <summary>The footer of a message or a reply (the Mac's message footer): its time and "Copy message", under the
/// pointer only; a word of its state on its way ("Sending…") stays.</summary>
internal sealed class MessageFooter : StackPanel
{
    private readonly TextBlock time = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly Button copy;
    private string text = "";
    private bool pointer;
    private bool always;

    public MessageFooter(bool right)
    {
        Orientation = Orientation.Horizontal;
        Spacing = 10;
        // In the room under its row (the next row's gap of 28): it takes no height, so nothing moves when it shows.
        Margin = new Thickness(0, 4, 0, -20);
        Height = 16;
        HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        var words = Look.Words("", 12, 16, Look.Link, wrap: false);
        copy = new Button { Style = (Style)Application.Current.Resources["QuietButtonStyle"], Content = words };
        copy.Click += (_, _) =>
        {
            var package = new global::Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(text);
            global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        };
        Children.Add(time);
        Children.Add(copy);
        Visibility = Visibility.Collapsed;
    }

    /// <summary>Shows the footer of a row; the row's view tells it when the pointer comes and goes.</summary>
    public void Show(ChatRow row)
    {
        text = row.Text;
        time.Text = row.TimeWords ?? "";
        time.Foreground = row.SlotIsWarning ? Look.Orange : Look.Muted;
        ToolTipService.SetToolTip(time, row.TimeHover);
        ((TextBlock)copy.Content).Text = row.CopyWords;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(copy, row.CopyWords);
        // A word of the message's way (the slot) stays; its time shows under the pointer.
        always = row.TimeWords is { } words && words.EndsWith('\u2026');
        copy.Visibility = always ? Visibility.Collapsed : Visibility.Visible;
        Draw();
    }

    public void Hide() { always = false; Draw(); }

    public void Pointer(bool over)
    {
        pointer = over;
        Draw();
    }

    private void Draw() => Visibility = always || (pointer && time.Text.Length > 0) ? Visibility.Visible : Visibility.Collapsed;
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
    private readonly IThreadContext? context;
    private readonly TextBlock words = Blocks.Selectable("", lineHeight: 20);
    private readonly Border bubble;
    private readonly StackPanel files = new() { Spacing = 8, Margin = new Thickness(0, 6, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
    private readonly MessageFooter footer = new(right: true);

    public OwnRowView(IThreadContext? context = null)
    {
        this.context = context;
        bubble = new Border
        {
            Background = Look.OwnBrush,
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(16, 12, 16, 12),
            HorizontalAlignment = HorizontalAlignment.Right,
            MaxWidth = 692 * 0.72,
            Child = words,
        };
        Children.Add(new StackPanel { Children = { bubble, files, footer } });
        PointerEntered += (_, _) => footer.Pointer(true);
        PointerExited += (_, _) => footer.Pointer(false);
    }

    public override RowKind Kind => RowKind.Own;

    protected override void DrawRow(ThreadItem item)
    {
        words.Text = item.Model switch
        {
            OwnRow own => own.Row.Text,
            ChatRow row => row.Text,
            string asks => asks,
            _ => "",
        };
        bubble.Visibility = words.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (item.Model is OwnRow { Row: var chatRow }) footer.Show(chatRow);
        else if (item.Model is ChatRow plain) footer.Show(plain);
        else footer.Hide();
        files.Children.Clear();
        if (item.Model is OwnRow { Files.Count: > 0 } withFiles && context is not null)
            foreach (var tile in withFiles.Files)
                files.Children.Add(new FileTileView(tile, context.Picture(tile), context.OpenFile, context.ReadAgain));
        files.Visibility = files.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }
}

/// <summary>An agent's reply, or a task's progress note, as plain text in its blocks (AgentReply), 14 on 22.</summary>
internal sealed class ReplyRowView : RowView
{
    private readonly ContentControl content = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    // Most replies are one paragraph: the view keeps its one text block and changes only its words.
    private readonly TextBlock paragraph = Blocks.Selectable("");
    private readonly MessageFooter footer = new(right: false);

    public ReplyRowView()
    {
        Children.Add(new StackPanel { Children = { content, footer } });
        PointerEntered += (_, _) => footer.Pointer(true);
        PointerExited += (_, _) => footer.Pointer(false);
    }

    public override RowKind Kind => RowKind.Reply;

    protected override void DrawRow(ThreadItem item)
    {
        var (blocks, text) = item.Model switch
        {
            ChatRow row => (row.Blocks, row.Text),
            NoteRow note => (note.Blocks, note.Text),
            _ => (ValueList<MessageBlock>.Empty, ""),
        };
        if (item.Model is ChatRow chatRow) footer.Show(chatRow);
        else footer.Hide();
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

    protected override void DrawRow(ThreadItem item)
    {
        // Who did the work, muted; a line of what holds the task (stalled, its usage limit, a lost session), orange.
        words.Text = item.Model is AlertLine alert ? alert.Words : (string)item.Model;
        words.Foreground = item.Model is AlertLine ? Look.Orange : Look.Muted;
        words.TextWrapping = item.Model is AlertLine ? TextWrapping.Wrap : TextWrapping.NoWrap;
    }
}

/// <summary>A line of what holds a task, at the end of its thread.</summary>
internal sealed record AlertLine(string Words);

/// <summary>"Earlier messages" over the first row of a chat that holds more than it shows (the Mac's ThreadViews): a
/// link in the middle, 12 on 16; a press shows as many items again.</summary>
internal sealed class EarlierRowView : RowView
{
    private readonly TextBlock words = Look.Words("", 12, 16, Look.Link, wrap: false);

    public EarlierRowView(IThreadContext context)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 14),
            Content = words,
        };
        button.Click += (_, _) => context.ShowEarlier();
        this.button = button;
        Children.Add(button);
    }

    public override RowKind Kind => RowKind.Earlier;

    private readonly Button button;

    protected override void DrawRow(ThreadItem item)
    {
        words.Text = (string)item.Model;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, words.Text);
    }
}
