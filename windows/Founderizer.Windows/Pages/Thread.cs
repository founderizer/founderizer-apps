using System;
using System.Collections.Generic;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages;

/// <summary>The "Thinking" line's model: the library's waiting line and the agent's mark beside it.</summary>
internal sealed record WaitingRow(ChatWaiting Line, MarkLook Mark);

/// <summary>What a thread's rows need from their page: the request controls, and whether a request's answer can go.</summary>
internal interface IThreadContext : IAnswers
{
    bool CanSendAnswer(RequestCard card);

    /// <summary>"Earlier messages" over the first row: the chat shows more of its items.</summary>
    void ShowEarlier() { }

    // A file of a message (Picture, OpenFile and ReadAgain) is a member of IAnswers: a request's pictures use it too.

    /// <summary>A press on a result's check: it opens, or folds again.</summary>
    void ToggleCheck() { }

    /// <summary>"View outputs" or "Reload outputs": the result's checked outputs are read again (ArtifactSection).</summary>
    void ListOutputs() { }

    /// <summary>"View" on a checked output: it is read, checked and opened under the list.</summary>
    void ViewOutput(ArtifactFile file) { }

    /// <summary>"Close" on the output opened: the file and the list go.</summary>
    void CloseOutput() { }

    /// <summary>A press on "Verified download": its facts open, or fold again.</summary>
    void ToggleVerify() { }

    /// <summary>A press on a fold of the thread (a run of steps, a permission, a step, a script's result): it opens, or
    /// folds again.</summary>
    void ToggleFold(string key) { }

    /// <summary>"Open agent thread", or a child agent in the panel: its thread takes the task thread's place.</summary>
    void OpenChild(ToolKey child) { }

    /// <summary>"Back" over a child agent's thread: one level up.</summary>
    void CloseChild() { }

    /// <summary>"Earlier activity": 80 rows more over the thread.</summary>
    void ShowEarlierActivity() { }
}

/// <summary>His message with its files under it (picture 4).</summary>
internal sealed record OwnRow(ChatRow Row, ValueList<FileTile> Files);

/// <summary>A thread's rows in a virtualized list (ItemsRepeater in a ScrollViewer: only the rows in view and near it
/// exist), in a column of at most 692. A new model changes only the rows that came, went, moved or changed.</summary>
internal sealed class ThreadList
{
    private readonly KeyedItems<ThreadItem> items = new(item => item.Key, item => (int)item.Kind);
    private readonly ItemsRepeater repeater;

    /// <summary><paramref name="endRoom"/>: empty room under the last row, over the composer (the Mac's ManagerView.endRoom,
    /// 88): the view opens and follows with it, and "Latest" leaves it out of its measure (keepsEnd(room:)).</summary>
    public ThreadList(IThreadContext context, Thickness padding, double endRoom = 0)
    {
        this.endRoom = endRoom;
        padding.Bottom += endRoom;
        repeater = new ItemsRepeater
        {
            Layout = new StackLayout { Spacing = 0 },
            ItemTemplate = new RowFactory(context),
            ItemsSource = items.Items,
            MaxWidth = 692,
            Margin = padding,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var content = new Grid { Children = { repeater }, Padding = new Thickness(23.5, 0, 23.5, 0) };
        Scroll = new ScrollViewer
        {
            Content = content,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            // The top of what he reads stays in place (rows that come above him, a taller window that shows more below
            // him, up to the end, as the Mac's chat does); while the view follows its end, it goes there itself.
            VerticalAnchorRatio = 0,
            IsTabStop = false,
        };
        // The scroll's own measure for the library's ChatEnd: where the view stands each time its offset, its content's
        // height or its room changes; where it rests; and when he takes it in hand: the wheel (an inertial change of the
        // view, which the scroll view starts before any event of the page sees the wheel), a touch or a touchpad, the
        // keys, and a press on the scroll bar.
        Scroll.ViewChanged += (_, e) =>
        {
            Measure();
            if (e.IsIntermediate) return;
            if (Trace) App.Note(FormattableString.Invariant($"thread {Environment.TickCount64 % 100000:D5} rested under {Under:F0} jumping {jumping} taken {taken}"));
            // A rest after his scroll or after the view's own jump (ChatEnd.Rested); a rest after a correction of the
            // layout is neither, and changes nothing (measured: it stopped the following short of the end).
            if (jumping || taken) End.Rested(Rows, jumping);
            jumping = false;
            Changed();
        };
        Scroll.SizeChanged += (_, _) => Measure();
        // Measured on 14 November 2026 (FOUNDERIZER_THREAD_TRACE): the wheel's scroll comes as inertial changes of the
        // view; the corrections of the layout after a long jump (an end that became shorter as rows got their height,
        // rows put into place) come as changes that are not inertial, with no input of his. Those are not his.
        Scroll.ViewChanging += (_, e) =>
        {
            if (Trace) App.Note(FormattableString.Invariant(
                $"thread {Environment.TickCount64 % 100000:D5} changing to {e.NextView.VerticalOffset:F0} final {e.FinalView.VerticalOffset:F0} inertial {e.IsInertial} jumping {jumping}"));
            if (e.IsInertial) Take();
        };
        Scroll.AddHandler(UIElement.PointerPressedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, e) =>
        {
            for (var node = e.OriginalSource as DependencyObject; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
            {
                if (node is Microsoft.UI.Xaml.Controls.Primitives.ScrollBar) { Take(); return; }
                if (ReferenceEquals(node, Scroll)) return;
            }
        }), true);
        // Content that changed is measured after this layout: rows that come into view above him make it longer before
        // the view keeps his top in place, and that is no content under the view.
        content.SizeChanged += (_, _) =>
        {
            if (measureQueued) return;
            measureQueued = true;
            Scroll.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                measureQueued = false;
                Measure();
            });
        };
        Scroll.AddHandler(UIElement.PointerWheelChangedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => Take()), true);
        Scroll.DirectManipulationStarted += (_, _) => Take();
        Scroll.AddHandler(UIElement.KeyDownEvent, new Microsoft.UI.Xaml.Input.KeyEventHandler((_, e) =>
        {
            if (e.Key is global::Windows.System.VirtualKey.Up or global::Windows.System.VirtualKey.Down or
                global::Windows.System.VirtualKey.PageUp or global::Windows.System.VirtualKey.PageDown or
                global::Windows.System.VirtualKey.Home or global::Windows.System.VirtualKey.End) Take();
        }), true);
        // A thread that follows its end goes there after the rows that came have their height (a few layouts).
        Scroll.LayoutUpdated += (_, _) =>
        {
            if (settle <= 0) return;
            settle--;
            Jump(animate: false);
        };
    }

    public ScrollViewer Scroll { get; }

    public int Count => items.Items.Count;

    /// <summary>Whether the view stands at its end and follows it, and whether "Latest" shows (the library's ChatEnd,
    /// FleetCore's): one for this view, from its first drawing.</summary>
    public ChatEnd End { get; } = new();

    /// <summary>The end's answer may have changed: "Latest" draws again.</summary>
    public event Action? EndChanged;

    private bool jumping, measureQueued;
    private int settle;
    private double offset = -1, extent = -1, room = -1;
    private readonly double endRoom;

    /// <summary>The points of content under the view's bottom edge.</summary>
    private double Under => Math.Max(0, Scroll.ExtentHeight - Scroll.VerticalOffset - Scroll.ViewportHeight);

    /// <summary>The points of rows under the view: <see cref="Under"/> without the empty room under the last row, which is
    /// no part of the chat. The library's ChatEnd takes this measure, so "Latest" shows when 100 points of messages stand
    /// under the view, as before the room.</summary>
    private double Rows => Math.Max(0, Under - endRoom);

    private void Measure()
    {
        double o = Scroll.VerticalOffset, x = Scroll.ExtentHeight, v = Scroll.ViewportHeight;
        if (o == offset && x == extent && v == room) return;
        bool moved = offset >= 0 && o != offset && x == extent && v == room;
        bool smaller = room >= 0 && v < room, grew = extent >= 0 && x > extent;
        (offset, extent, room) = (o, x, v);
        // The view moved itself only by his hand: a move of the layout's own (rows put into place) is not his.
        End.Stands(Rows, moved && taken);
        // A view at its true end is his own again: rows that grow there are the ones it brought.
        if (Under <= 0.5) taken = false;
        // While the view follows its end: a room that became smaller keeps the end in view; and while nobody took the
        // view since its own last jump (the opening, a row it followed, "Latest"), any layout that leaves it short of its
        // true end brings it there: rows that it brought get their height after a few layouts on Windows (at once on
        // the Mac), and a long list puts its rows into place after a jump. After he took it, the view follows only the
        // rows that came at its end (Show), not a row near the view that changed its height.
        if ((smaller || !taken) && End.FollowsLatest && Under > 0.5) Follow(room: smaller);
        if (Trace) App.Note(FormattableString.Invariant(
            $"thread {Environment.TickCount64 % 100000:D5} offset {o:F0} extent {x:F0} room {v:F0} under {Under:F0} moved {moved} grew {grew} jumping {jumping} taken {taken} follows {End.FollowsLatest}"));
        Changed();
    }

    /// <summary>The proofs' trace of each measure of the view (FOUNDERIZER_THREAD_TRACE=1 with FOUNDERIZER_DEBUG_LOG).</summary>
    private static readonly bool Trace = Proofs.Variable("FOUNDERIZER_THREAD_TRACE") == "1";

    private bool followQueued, followRoom;

    /// <summary>Goes to the end after this layout. A follow for a smaller room holds whatever he did; one for content
    /// that grew holds only while nobody took the view meanwhile.</summary>
    private void Follow(bool room)
    {
        followRoom |= room;
        if (followQueued) return;
        followQueued = true;
        Scroll.DispatcherQueue.TryEnqueue(() =>
        {
            bool forRoom = followRoom;
            followQueued = followRoom = false;
            if (End.FollowsLatest && Under > 0.5 && (forRoom || !taken)) Jump(animate: false);
        });
    }

    private void Take()
    {
        Taken();
        Changed();
    }

    /// <summary>He took the view in hand since its own last jump.</summary>
    private bool taken;

    private void Taken()
    {
        if (Trace) App.Note(FormattableString.Invariant($"thread {Environment.TickCount64 % 100000:D5} taken"));
        taken = true;
        End.Taken();
    }

    private void Changed() => EndChanged?.Invoke();

    /// <summary>The rows of a new model; only the rows that came, went, moved or changed are drawn again. The first
    /// rows of a long thread go in at once: the list takes them without the repeater, which then reads them once. The
    /// view goes to its newest row when it opens (<paramref name="opening"/>) and while it follows its end.</summary>
    public void Show(IReadOnlyList<ThreadItem> next, bool opening)
    {
        bool follow = opening || End.FollowsLatest;
        if (opening) taken = false;
        bool first = items.Items.Count == 0 && next.Count > 32;
        if (first) repeater.ItemsSource = null;
        items.Show(next);
        if (first) repeater.ItemsSource = items.Items;
        if (follow && Count > 0) settle = opening ? 6 : 2;
    }

    /// <summary>"Latest": the view goes to its end, with motion, and follows it again.</summary>
    public void Latest()
    {
        End.FollowsLatest = true;
        taken = false;
        Jump(animate: true);
        Changed();
    }

    /// <summary>A scroll that the view makes itself, to its newest row. A view at its end makes none: a scroll that
    /// changes nothing ends with no rest, and the view would count his next scroll as its own.</summary>
    private void Jump(bool animate)
    {
        if (Under <= 0.5) return;
        jumping = Scroll.ChangeView(null, Scroll.ScrollableHeight, null, !animate) || jumping;
    }

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
        RowKind.Rule => new RuleRowView(),
        RowKind.Check => new CheckRowView(context),
        RowKind.Detail => new DetailRowView(),
        RowKind.OutputFile => new OutputFileRowView(context),
        RowKind.OutputBox => new OutputBoxRowView(context),
        RowKind.Fold => new FoldRowView(context),
        RowKind.Step => new StepRowView(context),
        RowKind.Line => new LineRowView(),
        RowKind.Guidance => new GuidanceRowView(),
        RowKind.Plan => new PlanRowView(),
        RowKind.EarlierActivity => new EarlierActivityRowView(context),
        RowKind.ChildHead => new ChildHeadRowView(context),
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

/// <summary>The footer of a message or a reply (the Mac's message footer): how long ago it came, with its exact date and
/// time under the pointer (messageAge, Founderizer 0.1.239; the owner, 15 November 2026: "apply the style of the hover
/// time (relative too)"), and "Copy message", under the pointer only; a word of its state on its way ("Sending…")
/// stays.</summary>
internal sealed class MessageFooter : StackPanel
{
    private readonly TextBlock time = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly Button copy;
    private ChatRow? row;
    private string text = "";
    private bool pointer;
    private bool always;

    public MessageFooter(bool right)
    {
        Orientation = Orientation.Horizontal;
        Spacing = 10;
        // In the room under its row (the next row's gap of 28): it takes no height, so nothing moves when it shows. Its
        // own room of 4 over its words takes the pointer, so the pointer goes from the message to its time without
        // leaving the row, and the time's tooltip (the exact date and time) can be reached.
        Margin = new Thickness(0, 0, 0, -20);
        Padding = new Thickness(0, 4, 0, 0);
        Height = 20;
        Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent);
        HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        var words = Look.Words("", 12, 16, Look.Link, wrap: false);
        copy = new Button { Style = (Style)Application.Current.Resources["QuietButtonStyle"], Content = words };
        copy.Click += (_, _) => ClipboardText.Copy(text);
        Children.Add(time);
        Children.Add(copy);
        Visibility = Visibility.Collapsed;
    }

    /// <summary>Shows the footer of a row; the row's view tells it when the pointer comes and goes.</summary>
    public void Show(ChatRow row)
    {
        this.row = row;
        text = row.Text;
        time.Text = row.AgeWords ?? "";
        time.Foreground = row.SlotIsWarning ? Look.Orange : Look.Muted;
        ToolTipService.SetToolTip(time, row.AgeHover);
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
        // An age reads again when the footer shows, as the Mac reads it then.
        if (over && row is { AgeMoves: true } r) time.Text = Screens.MessageAge(r.Time, DateTimeOffset.UtcNow, ScreenContext.Local);
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

/// <summary>His message in his bubble (OwnerBubble): at the right, at most 72 % of the column, a corner of 16. Words that
/// another hand sent for him stand in the bubble's outline, and an AI session's have its mark at the bubble's lower left
/// corner (owner feature `message_hands`, <see cref="ChatRow.Hand"/>).</summary>
internal sealed class OwnRowView : RowView
{
    private static readonly Thickness Room = new(16, 12, 16, 12);
    private readonly IThreadContext? context;
    private readonly TextBlock words = Blocks.Selectable("", lineHeight: 20);
    private readonly Border bubble;
    private readonly AiSessionMark mark = new();
    private readonly Grid bubbleCell;
    private readonly StackPanel files = new() { Spacing = 8, Margin = new Thickness(0, 6, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
    private readonly MessageFooter footer = new(right: true);

    public OwnRowView(IThreadContext? context = null)
    {
        this.context = context;
        bubble = new Border
        {
            Background = Look.OwnBrush,
            CornerRadius = new CornerRadius(16),
            Padding = Room,
            MaxWidth = 692 * 0.72,
            Child = words,
        };
        bubbleCell = new Grid { HorizontalAlignment = HorizontalAlignment.Right, Children = { bubble, mark } };
        Children.Add(new StackPanel { Children = { bubbleCell, files, footer } });
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
        bubbleCell.Visibility = words.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        var hand = item.Model switch { OwnRow own => own.Row.Hand, ChatRow row => row.Hand, _ => HandLook.His };
        Look.OwnBubble(bubble, hand, Room);
        mark.Show(hand.Mark);
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
            // A result's words (ResultModel.What), as the agent's words.
            string words => (MessageBlock.Parse(words) is { } parsed ? ValueList.Of(parsed) : ValueList<MessageBlock>.Empty, words),
            _ => (ValueList<MessageBlock>.Empty, ""),
        };
        if (item.Model is ChatRow chatRow) footer.Show(chatRow);
        else footer.Hide();
        if (blocks.Count <= 1 && (blocks.Count == 0 || blocks[0].Kind == MessageBlock.Kinds.Paragraph))
        {
            Blocks.Fill(paragraph, blocks.Count == 0 ? text : blocks[0].Text);
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
        // Who did the work, muted; a line of what holds the task (stalled, its usage limit, a lost session), orange; a
        // line of the checked outputs (none to list), muted.
        words.Text = item.Model switch { AlertLine alert => alert.Words, MutedLine line => line.Words, _ => (string)item.Model };
        words.Foreground = item.Model is AlertLine ? Look.Orange : Look.Muted;
        words.TextWrapping = item.Model is string ? TextWrapping.NoWrap : TextWrapping.Wrap;
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
