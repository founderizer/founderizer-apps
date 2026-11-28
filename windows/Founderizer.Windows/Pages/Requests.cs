using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;
using System.Runtime.InteropServices;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Composition;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace Founderizer.Windows.Pages;

/// <summary>What a request's controls do: a press on an option, ticks and their send, his words in the answer box (his one
/// reply), his answer, and the open state that the screen keeps for each request while its page shows (Show all,
/// Details).</summary>
internal interface IAnswers
{
    void Press(long need, int choice);
    /// <summary>A quick reply ("Done", "Not now", "Tell me more"): its words are his answer (OwnerStore.Hold). The words that
    /// the box shows now where the store put them into its draft (a reply that waits for nothing); else null.</summary>
    string? Reply(long need, string words);
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

    /// <summary>A file of a message, or a picture of a request's option: its picture once its bytes came (null until
    /// then; the page draws again then), a press that opens it, and Read again.</summary>
    Microsoft.UI.Xaml.Media.ImageSource? Picture(FileTile tile) => null;
    void OpenFile(FileTile tile) { }
    void ReadAgain(FileTile tile) { }

    /// <summary>Needs clarification (owner feature `need_clarify`): a press on its link, his words in its field, and its
    /// Send (OwnerStore.OpenClarify, SetClarifyDraft, TalkAsync). OpenClarify is true when the field stands.</summary>
    bool OpenClarify(long need) => false;
    void TypeClarify(long need, string text) { }
    void SendClarify(long need) { }

    /// <summary>The hold of words that look like a key (KeyHold): whether the words of a box wait for his choice now (the
    /// store's StoreState.HoldsKey), and its "Keep it" (OwnerStore.KeepKey).</summary>
    bool HoldsKey(string box, string text) => false;
    void KeepKey(string box) { }

    /// <summary>Undo at the end of a folded card's answer line while his answer waits (OwnerStore.Undo), the mark that
    /// opens its task's page, and the task's Pause at the end of the line (OwnerStore.ControlAsync).</summary>
    void Undo(long need) { }
    void OpenTask(long task) { }
    void Pause(long task) { }
    /// <summary>The view showed the ticks that Undo <paramref name="number"/> gave back (OwnerStore.TicksShown).</summary>
    void TicksShown(long need, long number) { }
}

/// <summary>A request's options and its answer box, as the pictures draw them in a chat's card (rows of 14) and in the
/// request at hand (rows of 15, 44 high). A press sends that option (OptionsKind.Press); a quick reply sends its words
/// as his answer with the box's files, and they stand in the box while it waits for the store (OwnerStore.Reply); ticks
/// (options that combine) mark each pressed row, and "Send N" sends them. An option whose press waits for the store
/// says "Sending…" at its end after a second.
///
/// Pictures as the options (owner feature `need_pictures`; the owner's "Yes, as shown" of 21 November 2026 to
/// w4-windows-chat.png and w4-windows-needs.png): three in a row and a row more for each three more, each picture
/// square over its option's row, 7 apart in a chat's card and 8 at hand, "Your answer" under them. A click on a picture
/// opens it as a file of a message opens, and answers nothing; a click on the row answers as a row of before does. The
/// rows of one row of pictures take one height. The ticks and "Send N" stay as before, under the pictures.
///
/// Needs clarification (owner feature `need_clarify`; the owner's "Yes, as shown" of 21 November 2026 to the same two
/// drawings, and his "Keep Your answer too" of 20 November for the Mac and the iPhone): his talk with the agent stands
/// over the options (<see cref="Talk"/>), and under "Your answer" the quiet link "Needs clarification" (<see
/// cref="Clarify"/>), small muted words at the leading side in a chat's card (12 on 16), muted words in the middle at
/// hand (15 on 21, 8 under the box). A press puts its field in the link's place: the answer's box with no plus,
/// "Message to" and the agent, Send with Enter. Once the outbox has his message the link comes back.</summary>
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
    private readonly List<OptionPictureView> pictures = new();
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer? sendingTimer;
    private long need;
    private OptionsModel shown = new();
    private bool filesWait;
    /// <summary>What the box and the ticks take at a draw: another card's draft and ticks, and what an Undo gave back.</summary>
    private readonly AnswerBoxLoad boxLoad = new();
    // Needs clarification: the talk over the options, and the link or its field under the answer box
    private readonly StackPanel talk = new() { Spacing = 6, Visibility = Visibility.Collapsed };
    private readonly Grid clarifyPlace = new() { Visibility = Visibility.Collapsed };
    private readonly Button clarifyLink;
    private readonly Field clarifyBox;
    private ValueList<TalkLine> shownTalk = ValueList<TalkLine>.Empty;
    /// <summary>The card that the parts show now.</summary>
    private long clarifyNeed;
    /// <summary>Which words the field loads, which of its changes are his, and when it takes the cursor.</summary>
    private readonly ClarifyField clarifyField = new();
    /// <summary>The pointer's press under the click that comes (its time in microseconds and its place), and the press
    /// of the last click that answered, for <see cref="SecondClick"/>.</summary>
    private (ulong At, global::Windows.Foundation.Point Place)? pressed, lastPress;

    [DllImport("user32.dll")]
    private static extern uint GetDoubleClickTime();

    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);

    /// <summary>A click that answers (an option, a quick reply, "Send N", the box's Send) is the second click of a
    /// double-click on the request at hand: the next request comes to hand under the pointer as the first click answers,
    /// and the second would answer that one too (the Mac's SecondClick, on the same four). A second click is Windows'
    /// own, by the pointer's presses and not by when the window gets to the click: within its double-click time of the
    /// press before it and within its double-click rectangle, so a quick press on another row goes. A press of the
    /// keyboard or of an assistive app has no pointer press, and is never one. Each click of a run of quick clicks counts
    /// as a second one.</summary>
    private bool SecondClick()
    {
        var press = pressed;
        pressed = null;
        var previous = lastPress;
        lastPress = press;
        if (!step || press is not { } now || previous is not { } before || now.At < before.At) return false;
        return now.At - before.At < GetDoubleClickTime() * 1000UL &&
               Math.Abs(now.Place.X - before.Place.X) * 2 <= GetSystemMetricsForDpi(36, 96) &&    // SM_CXDOUBLECLK
               Math.Abs(now.Place.Y - before.Place.Y) * 2 <= GetSystemMetricsForDpi(37, 96);      // SM_CYDOUBLECLK
    }

    /// <summary>The pointer's press on a control that answers, also when the button takes the press as its own.</summary>
    private void Watch(UIElement control) =>
        control.AddHandler(UIElement.PointerPressedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, e) =>
        {
            var point = e.GetCurrentPoint(null);
            pressed = (point.Timestamp, point.Position);
        }), handledEventsToo: true);

    public AnswerParts(IAnswers answers, bool step)
    {
        this.answers = answers;
        this.step = step;
        options = new StackPanel { Spacing = step ? 8 : 7 };
        answerBox = new Field(step ? 44 : 40, step ? 15 : 14, 42);
        answerBox.Typed += text => answers.Type(need, text);
        // words that look like a key stay in the box until "Keep it" (KeyHold), and do not fold the card
        answerBox.HoldsKey = text => answers.HoldsKey(KeyHold.Answer(need), text);
        answerBox.KeepPressed += () => answers.KeepKey(KeyHold.Answer(need));
        answerBox.PlusPressed += () => answers.AddFiles(need);
        Watch(answerBox.SendButton);
        answerBox.Sent += () =>
        {
            if (SecondClick()) return;
            answers.Answer(need);
            answerBox.Clear();
        };
        sendTicks = Buttons.Plain("");
        sendTicksWords = (TextBlock)((Border)sendTicks.Content).Child;
        sendTicks.HorizontalAlignment = HorizontalAlignment.Left;
        Watch(sendTicks);
        sendTicks.Click += (_, _) =>
        {
            if (ticked.Count == 0 || SecondClick()) return;
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

        // The drawings: "Needs clarification" in the muted grey, 12 on 16 at the leading side of a chat's card, 15 on
        // 21 in the middle at hand, 8 under the box (a card's stack puts its own 10 there).
        var linkWords = Look.Words("Needs clarification", step ? 15 : 12, step ? 21 : 16, Look.Muted, wrap: false);
        clarifyLink = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = step ? HorizontalAlignment.Center : HorizontalAlignment.Left,
            Content = linkWords,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(clarifyLink, linkWords.Text);
        Watch(clarifyLink);
        clarifyLink.Click += (_, _) =>
        {
            if (SecondClick()) return;
            // the cursor only for a field that the store opened (ClarifyField.Opened)
            var id = clarifyNeed;
            if (answers.OpenClarify(id)) clarifyField.Opened(id);
        };
        clarifyBox = new Field(step ? 44 : 40, step ? 15 : 14, 16);
        // a text box reports a text that this view set as a change too: only his own words go to the store
        clarifyBox.Typed += text =>
        {
            if (clarifyField.Typed(text) is { } card) answers.TypeClarify(card, text);
        };
        clarifyBox.HoldsKey = text => answers.HoldsKey(KeyHold.Talk(clarifyNeed), text);
        clarifyBox.KeepPressed += () => answers.KeepKey(KeyHold.Talk(clarifyNeed));
        Watch(clarifyBox.SendButton);
        clarifyBox.Sent += () =>
        {
            if (SecondClick()) return;
            answers.SendClarify(clarifyNeed);
        };
        clarifyPlace.Children.Add(clarifyLink);
        clarifyPlace.Children.Add(clarifyBox);
        if (step) clarifyPlace.Margin = new Thickness(0, 8, 0, 0);
    }

    public StackPanel Options => options;
    public Field Box => answerBox;
    /// <summary>His talk with the agent, which stands over the options.</summary>
    public StackPanel Talk => talk;
    /// <summary>The link Needs clarification, or its field, which stands under the answer box.</summary>
    public FrameworkElement Clarify => clarifyPlace;

    /// <summary>The talk of the request <paramref name="id"/>, and its link or field (null: the card takes no message).
    /// The field's words are loaded only as <see cref="ClarifyField.Show"/> says: when it comes to stand, when another
    /// request comes, and when the store gave words of its own (Discard of a refused message); never on another draw,
    /// which can come from a state older than his last key.</summary>
    public void ShowClarify(long id, ValueList<TalkLine> lines, ClarifyModel? model)
    {
        if (!lines.Equals(shownTalk))
        {
            shownTalk = lines;
            talk.Children.Clear();
            foreach (var line in lines) talk.Children.Add(TalkRow(line));
        }
        talk.Visibility = lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        clarifyNeed = id;
        clarifyPlace.Visibility = model is null ? Visibility.Collapsed : Visibility.Visible;
        bool stands = model?.Stands == true;
        var (load, cursor) = clarifyField.Show(id, model, clarifyBox.Box.Text);
        if (load is not null) clarifyBox.Load(load);
        clarifyLink.Visibility = model is not null && !stands ? Visibility.Visible : Visibility.Collapsed;
        clarifyBox.Visibility = stands ? Visibility.Visible : Visibility.Collapsed;
        clarifyBox.ShowHold(stands ? model!.KeyHold : null);
        if (model is null) return;
        clarifyBox.Show(model.Placeholder, showsPlus: false, model.CanSend);
        clarifyBox.Hovers(null, model.SendHover);
        if (cursor)
        {
            // the cursor comes once the field stands, as the key card's field takes it
            var box = clarifyBox.Box;
            box.DispatcherQueue?.TryEnqueue(() =>
            {
                box.Focus(FocusState.Programmatic);
                box.Select(box.Text.Length, 0);
            });
        }
    }

    /// <summary>One line of the talk (the Mac's NeedTalkLines): his message at the trailing side in his chat's bubble,
    /// 48 in from the leading edge; the agent's reply at the leading side after its 16-pixel mark, 48 in from the
    /// trailing edge. Plain text, which he can select. A line that an AI session sent for him is in the bubble's outline
    /// with the AI's mark, as in the chat (owner feature `message_hands`, <see cref="TalkLine.Hand"/>).</summary>
    private FrameworkElement TalkRow(TalkLine line)
    {
        var words = Blocks.Selectable(line.Text, size: step ? 15 : 14, lineHeight: step ? 21 : 20);
        FrameworkElement row;
        if (line.Own)
        {
            var bubble = new Border { CornerRadius = new CornerRadius(16), Child = words };
            Look.OwnBubble(bubble, line.Hand, new Thickness(12, 7, 12, 7));
            var mark = new AiSessionMark();
            mark.Show(line.Hand.Mark);
            row = new Grid
            {
                Margin = new Thickness(48, 0, 0, 0),
                HorizontalAlignment = HorizontalAlignment.Right,
                Children = { bubble, mark },
            };
        }
        else
        {
            var mark = new AgentGlyph { Side = 16, Mark = line.Mark, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
            var grid = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 0, 48, 0) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.Children.Add(mark);
            Grid.SetColumn(words, 1);
            grid.Children.Add(words);
            row = grid;
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, line.Spoken);
        return row;
    }

    public void Show(long id, OptionsModel model, AnswerBoxModel box, bool canSend)
    {
        // The request that the parts showed: a picture's read keeps its rows in place only for that one.
        bool sameNeed = id == need;
        bool same = sameNeed && model == shown;
        // Another card (a row that the list uses again, the next request at hand), or his Undo: the store's words and the
        // ticks that an Undo gave back, which this view takes for every view (AnswerBoxLoad).
        var (load, ticks) = boxLoad.Show(id, model, box);
        if (load is not null) answerBox.Load(load);
        if (ticks is not null)
        {
            ticked.Clear();
            ticked.UnionWith(ticks);
            if (ticks.Count > 0) answers.TicksShown(id, box.Given);
        }
        need = id;
        filesWait = box.FilesWait;
        answerBox.Show(box.Placeholder, box.ShowsPlus, canSend);
        answerBox.ShowHold(box.KeyHold);
        answerBox.Hovers(box.PlusHover, box.SendHover);
        answerBox.ShowChips(box.Chips.Select(chip => (UIElement)new FileChipView(chip, (c, again) => answers.Chip(id, c, again))).ToList());
        if (same)
        {
            DrawTicks();
            return;
        }
        // Only a picture's read began or ended: its tile draws again in place, and the rows keep their hover and focus.
        if (sameNeed && pictures.Count > 0 && model.Pictures.Count == pictures.Count && model with { Pictures = shown.Pictures } == shown)
        {
            shown = model;
            for (int i = 0; i < pictures.Count; i++) pictures[i].Show(model.Pictures[i], answers.Picture(model.Pictures[i]));
            DrawTicks();
            return;
        }
        var waitingBefore = shown.WaitingPress;
        shown = model;
        options.Children.Clear();
        rows.Clear();
        pictures.Clear();
        bool drawsPictures = model.Pictures.Count > 0 && model.Pictures.Count == model.Labels.Count;
        var grid = drawsPictures ? PictureGrid(model.Labels.Count) : null;
        for (int i = 0; i < model.Labels.Count; i++)
        {
            int choice = i;
            string label = model.Labels[i];
            // an option that only the Mac's press starts stands with its words, grey and off (OptionsModel.OnlyOnTheMac)
            var row = Row(label, model.Kind == OptionsKind.Ticks, model.SendingWords, drawsPictures, off: model.OnlyOnTheMac.Contains(i));
            Watch(row);
            row.Click += (_, _) =>
            {
                var click = shown.Click(choice, onPicture: false);
                switch (click.Kind)
                {
                    case OptionClickKind.Press:
                        if (SecondClick()) break;
                        answers.Press(need, click.Index);
                        break;
                    case OptionClickKind.Tick:
                        if (!ticked.Remove(click.Index)) ticked.Add(click.Index);
                        DrawTicks();
                        break;
                    case OptionClickKind.Reply when click.Words is { } words:
                        // The owner, 18 November 2026: "If I click done, I want to send it directly! not paste it into
                        // the text input!".
                        if (SecondClick()) break;
                        // Held, the words wait 5 seconds on the folded card with Undo (OwnerStore.Hold), and his own words
                        // stay in the box for Undo. Not held (a key request, a card whose own request waits unsent, a file
                        // of the box that goes up), they stand in the store's draft, and so in the box; while a file goes
                        // up they wait there for Enter or Send, with the caret.
                        if (answers.Reply(need, words) is { } standing)
                        {
                            answerBox.Load(standing);
                            if (filesWait)
                            {
                                answerBox.Box.Focus(FocusState.Programmatic);
                                answerBox.Box.Select(standing.Length, 0);
                            }
                        }
                        break;
                }
            };
            if (grid is null)
            {
                options.Children.Add(row);
                continue;
            }
            // The picture over its option: a click opens it, as a file of a message opens, and sends nothing.
            var picture = new OptionPictureView(() => shown.Click(choice, onPicture: true).Picture, answers.OpenFile, answers.ReadAgain);
            picture.Show(model.Pictures[i], answers.Picture(model.Pictures[i]));
            pictures.Add(picture);
            int line = i / NeedPictures.Columns, column = i % NeedPictures.Columns;
            Grid.SetRow(picture, line * 2);
            Grid.SetColumn(picture, column);
            grid.Children.Add(picture);
            Grid.SetRow(row, line * 2 + 1);
            Grid.SetColumn(row, column);
            grid.Children.Add(row);
        }
        if (grid is not null) options.Children.Add(grid);
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

    /// <summary>The grid of pictures and their rows: three columns of one width, and for each row of pictures a row of
    /// their options under it, whose height is its highest option's.</summary>
    private Grid PictureGrid(int count)
    {
        double gap = step ? 8 : 7;
        var grid = new Grid { ColumnSpacing = gap, RowSpacing = gap };
        for (int c = 0; c < NeedPictures.Columns; c++)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        int lines = (count + NeedPictures.Columns - 1) / NeedPictures.Columns;
        for (int r = 0; r < lines * 2; r++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        return grid;
    }

    private Button Row(string label, bool tick, string sendingWords, bool underPicture = false, bool off = false)
    {
        var words = Look.Words(label, step ? 15 : 14, 20, off ? Look.Muted : null);
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
        // Under a picture, the words stand in the middle of a row as high as the highest of its line.
        if (underPicture) line.VerticalAlignment = VerticalAlignment.Center;
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = underPicture ? VerticalAlignment.Stretch : VerticalAlignment.Top,
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
            // not enabled, also for an assistive app: a press would answer the card and start nothing
            IsEnabled = !off,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        return button;
    }
}

/// <summary>The mark in the place of an answered card's check (owner API 1.280, <see cref="AnswerMark"/>; the owner's "Yes,
/// as drawn" of 21 November 2026, and "Yes, same marks there" for the request at hand in Needs you), at the check's 12
/// pixels: the muted check; the search card's mark of work (circle_hint in the green of work), which turns once in three
/// seconds as the Mac's WorkMark does and rests, green, on a last reading and where Windows' animation effects are off;
/// the search card's red mark of a result that is no success; where the task's row needs him (his "Orange mark" of
/// the same day), the search card's icon of the task's own mark (<see cref="AnswerMark.Row"/>, <see cref="SearchCard.IconOf"/>)
/// in its orange; or, where his own pause holds the task (his "Gray pause, as the row" of the same day), that icon of
/// the row's pause mark in the muted gray of the row. Its <see cref="AnswerMark.Hover"/> shows under the pointer as the system's tooltip (none for the plain
/// check); the work of a task shows its tag under the mark instead (<see cref="WorkTag"/>). An assistive app reads its
/// <see cref="AnswerMark.Words"/> as its name (the Mac's value of the folded card). The compositor turns it, so the app
/// does no work for a frame.</summary>
internal sealed class AnswerMarkView : Grid
{
    private static readonly UISettings Settings = new();
    private static readonly SolidColorBrush FailedTint = Look.Brush(Look.Rgb(0xFF, 0x45, 0x3A));
    /// <summary>A badge's fill and edge: the link's colour at 12 and at 30 %, as the Mac's CardBadge draws them.</summary>
    private static readonly SolidColorBrush BadgeFill = Look.Brush(global::Windows.UI.Color.FromArgb(31, Look.LinkColor.R, Look.LinkColor.G, Look.LinkColor.B));
    private static readonly SolidColorBrush BadgeEdge = Look.Brush(global::Windows.UI.Color.FromArgb(77, Look.LinkColor.R, Look.LinkColor.G, Look.LinkColor.B));
    /// <summary>The widest that the tag's words run before they wrap (the Mac's HoverTag.widest).</summary>
    private const double TagWidest = 360;
    /// <summary>The room around the tag's words, and between the tag and its mark (the Mac's HoverTag.inset and gap).</summary>
    private const double TagInsetX = 9, TagInsetY = 6, TagGap = 6;
    /// <summary>The rest of the pointer on the mark before its tag shows (the Mac's AnsweredMarkView: 350 ms).</summary>
    private static readonly TimeSpan TagRest = TimeSpan.FromMilliseconds(350);
    private FrameworkElement? icon;
    /// <summary>The look drawn now: the mark's symbol, and for the orange and the gray mark the task's own symbol.</summary>
    private (AnswerSymbol, TaskSymbol?)? shown;
    /// <summary>The badge and the title of the tag that the mark has now: a reading with the same ones keeps its tooltip.</summary>
    private (AgentBadge, string)? tagged;
    /// <summary>The tag of a task's work, which this view opens and closes itself (<see cref="OpenTag"/>).</summary>
    private ToolTip? workTag;
    /// <summary>The tag's owner for the system's tooltip service, as large as the mark and at its place: the pointer never
    /// finds it, so the service never opens the tag by itself. A tooltip that the service opens for the pointer stands
    /// where the pointer is, whatever its placement rectangle says (WinUI's ToolTip,
    /// `PerformDirectionalPlacementWithWindowedPopup`).</summary>
    private readonly Border tagOwner = new() { IsHitTestVisible = false };
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? tagRest;
    /// <summary>A click, a key or a scroll took the tag away: it shows again only after the pointer left the mark (the
    /// Mac's HoverTag.silenced).</summary>
    private bool silenced;
    /// <summary>Where the mark stood in the window when its tag opened: the tag goes when the mark moves.</summary>
    private global::Windows.Foundation.Point tagAt;
    private bool moves;
    private bool turning;

    public AnswerMarkView()
    {
        Width = Height = 12;
        VerticalAlignment = VerticalAlignment.Center;
        // A clear fill, so that the pointer finds the mark for its words (the icon itself takes no pointer).
        Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(0, 0, 0, 0));
        Children.Add(tagOwner);
        Loaded += (_, _) => { Settings.AnimationsEnabledChanged += AnimationsChanged; Turn(); };
        Unloaded += (_, _) => { Settings.AnimationsEnabledChanged -= AnimationsChanged; Rest(); CloseTag(); };
        PointerEntered += (_, e) =>
        {
            if (workTag is null || silenced || e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Touch) return;
            if (tagRest is null)
            {
                tagRest = DispatcherQueue.CreateTimer();
                tagRest.Interval = TagRest;
                tagRest.IsRepeating = false;
                tagRest.Tick += (_, _) => OpenTag();
            }
            tagRest.Start();
        };
        PointerExited += (_, _) => LeaveTag();
        PointerCanceled += (_, _) => LeaveTag();
    }

    /// <summary>The pointer rested on the mark: its tag shows, at its place (<see cref="PlaceTag"/>).</summary>
    private void OpenTag()
    {
        if (workTag is not { } tag || silenced || !IsLoaded || XamlRoot is null) return;
        tagAt = TransformToVisual(null).TransformPoint(default);
        // A tag that showed before knows its size; a new one takes its place when it has one (Watch, its SizeChanged).
        if (tag.ActualWidth > 0) PlaceTag(tag, new global::Windows.Foundation.Size(tag.ActualWidth, tag.ActualHeight));
        tag.IsOpen = true;
    }

    /// <summary>The pointer left the mark: its tag goes, and the next rest shows it again.</summary>
    private void LeaveTag()
    {
        silenced = false;
        CloseTag();
    }

    private void CloseTag()
    {
        tagRest?.Stop();
        if (workTag is { IsOpen: true } tag) tag.IsOpen = false;
    }

    /// <summary>**The tag stands under its mark, its words at the answer line's left edge** (the Mac's HoverTag.show:
    /// `anchor.minX - inset`, the gap under the mark), and above the mark only where the window's bottom ends, so it
    /// never stands over another column, also where the answer line is centred (the request at hand in Needs you). The
    /// mark is the first part of its answer line, so its left edge is the line's. WinUI centres a tooltip that it does
    /// not open for the pointer on its placement rectangle (in its owner's points, which are the mark's): a rectangle as
    /// wide as the tag, from the inset left of the mark, puts the tag's left edge there; it reaches from the gap over the
    /// mark to the gap under it, so the tag stands at the same gap under the mark or over it. <paramref name="size"/>:
    /// the tag's own.</summary>
    private void PlaceTag(ToolTip tag, global::Windows.Foundation.Size size)
    {
        if (!IsLoaded || XamlRoot is null || size.Width <= 0) return;
        double top = TransformToVisual(null).TransformPoint(default).Y;
        var placement = top + ActualHeight + TagGap + size.Height <= XamlRoot.Size.Height
            ? Microsoft.UI.Xaml.Controls.Primitives.PlacementMode.Bottom
            : Microsoft.UI.Xaml.Controls.Primitives.PlacementMode.Top;
        if (tag.Placement != placement)
        {
            tag.Placement = placement;
            // WinUI places an open tag again when its rectangle changes, not when its placement does.
            if (tag.IsOpen) tag.PlacementRect = null;
        }
        tag.PlacementRect = new global::Windows.Foundation.Rect(-TagInsetX, -TagGap, size.Width, ActualHeight + 2 * TagGap);
    }

    public void Show(AnswerMark mark, bool marksMove)
    {
        if ((mark.Symbol, mark.Row) != shown)
        {
            Rest();
            shown = (mark.Symbol, mark.Row);
            if (icon is not null) Children.Remove(icon);
            icon = mark.Symbol switch
            {
                AnswerSymbol.Working => Icons.Of(Icons.Hint, Look.Green, 12),
                AnswerSymbol.Failed => Icons.Of(Icons.Dismiss16, FailedTint, 12),
                AnswerSymbol.Attention => Icons.Of(SearchCard.IconOf(mark.Row ?? TaskSymbol.Alert), Look.Orange, 12),
                AnswerSymbol.Paused => Icons.Of(SearchCard.IconOf(mark.Row ?? TaskSymbol.Paused), Look.Muted, 12),
                _ => Icons.Of(Icons.Check, Look.Muted, 12),
            };
            Children.Insert(0, icon);
        }
        if (marksMove != moves)
        {
            moves = marksMove;
            Rest();
        }
        Turn();
        if (mark.Badge is { } badge && mark.Title is { } title)
        {
            if (tagged != (badge, title))
            {
                // A new title while the tag shows: the new tag shows in its place.
                bool open = workTag?.IsOpen == true;
                CloseTag();
                tagged = (badge, title);
                workTag = WorkTag(badge, title);
                Watch(workTag);
                ToolTipService.SetToolTip(this, null);
                ToolTipService.SetToolTip(tagOwner, workTag);
                if (open) OpenTag();
            }
        }
        else
        {
            if (workTag is not null)
            {
                CloseTag();
                ToolTipService.SetToolTip(tagOwner, null);
                workTag = null;
            }
            tagged = null;
            ToolTipService.SetToolTip(this, mark.Hover);
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, mark.Words ?? "");
    }

    /// <summary>**The hover of a task's work** (the owner's "Yes, badge as drawn" of 21 November 2026; the Mac's
    /// AnsweredMarkView tag): the agent's badge, then " · " and the task's title, in one text that wraps at 360 under
    /// the badge. The badge is the Mac's CardBadge at the words' 12: the agent's mark at 10 (0.82 of the words' size),
    /// then its label in the words' colour, on the link's colour at 12 % with an edge at 30 %, 18 high, so that it stands
    /// a pixel over the line of 16 and a pixel under it, as the Mac's does. It is the system's tooltip, as the other
    /// marks' words are, so it takes no focus and no click; but this view opens it, after the Mac's rest of the pointer
    /// (350 ms, <see cref="OpenTag"/>), and it goes when the pointer leaves, when the mark moves, and at a click, a key or
    /// a scroll (<see cref="Watch"/>); it stands under the mark, its words at the answer line's left edge
    /// (<see cref="PlaceTag"/>), so that it hides no title of the card and no other column.</summary>
    private static ToolTip WorkTag(AgentBadge badge, string title)
    {
        var mark = Look.Glyph(badge.Mark, 10);
        mark.VerticalAlignment = VerticalAlignment.Center;
        var face = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        face.Children.Add(mark);
        face.Children.Add(Look.Words(badge.Label, 12, 16, wrap: false));
        var pill = new Border
        {
            Background = BadgeFill,
            BorderBrush = BadgeEdge,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(3, 0, 3, 0),
            // An element in a text stands on the text's baseline: 4 under it, the badge's middle is the line's.
            Margin = new Thickness(0, 0, 0, -4),
            Child = face,
        };
        var line = new Microsoft.UI.Xaml.Documents.Paragraph();
        line.Inlines.Add(new Microsoft.UI.Xaml.Documents.InlineUIContainer { Child = pill });
        line.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = " · " + title });
        var words = new RichTextBlock
        {
            FontFamily = Look.TextFont,
            FontSize = 12,
            LineHeight = 16,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = Look.Text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = false,
            MaxWidth = TagWidest,
        };
        words.Blocks.Add(line);
        // The tooltip's own widest (320) would wrap the words before 360; its room is the Mac's tag's.
        return new ToolTip
        {
            Content = words,
            MaxWidth = double.PositiveInfinity,
            Padding = new Thickness(TagInsetX, TagInsetY, TagInsetX, TagInsetY),
            BorderThickness = new Thickness(1),
            Placement = Microsoft.UI.Xaml.Controls.Primitives.PlacementMode.Bottom,
        };
    }

    /// <summary>While the tag shows: it takes its place again when its size changes (the first time that it shows, WinUI
    /// measures it then), and it goes when its mark moves, hides or leaves, and at a click, a key or a scroll anywhere in
    /// the window, as the Mac's does (HoverTag), and then stays away until the pointer leaves the mark. The window's
    /// content tells it only while it shows, also of a press or a key that a control took.</summary>
    private void Watch(ToolTip tag)
    {
        UIElement? root = null;
        var press = new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => { silenced = true; CloseTag(); });
        var key = new Microsoft.UI.Xaml.Input.KeyEventHandler((_, _) => { silenced = true; CloseTag(); });
        tag.SizeChanged += (_, e) => { if (tag.IsOpen) PlaceTag(tag, e.NewSize); };
        tag.Opened += (_, _) =>
        {
            root = XamlRoot?.Content;
            root?.AddHandler(PointerPressedEvent, press, true);
            root?.AddHandler(PointerWheelChangedEvent, press, true);
            root?.AddHandler(KeyDownEvent, key, true);
            LayoutUpdated -= Moved;
            LayoutUpdated += Moved;
        };
        tag.Closed += (_, _) =>
        {
            root?.RemoveHandler(PointerPressedEvent, press);
            root?.RemoveHandler(PointerWheelChangedEvent, press);
            root?.RemoveHandler(KeyDownEvent, key);
            root = null;
            // A tag of a new title can show before the old one has closed: the watch stays for it.
            if (workTag is not { IsOpen: true }) LayoutUpdated -= Moved;
        };
    }

    /// <summary>A layout of the window while the tag shows: the tag goes when its mark moved, hid or left.</summary>
    private void Moved(object? sender, object e)
    {
        if (workTag is not { IsOpen: true }) return;
        if (!IsLoaded || XamlRoot is null || Visibility != Visibility.Visible) { CloseTag(); return; }
        var at = TransformToVisual(null).TransformPoint(default);
        if (Math.Abs(at.X - tagAt.X) > 0.5 || Math.Abs(at.Y - tagAt.Y) > 0.5) CloseTag();
    }

    /// <summary>Windows' animation effects were turned on or off: the mark follows at once.</summary>
    private void AnimationsChanged(UISettings sender, UISettingsAnimationsEnabledChangedEventArgs args) =>
        DispatcherQueue?.TryEnqueue(() => { Rest(); Turn(); });

    private void Turn()
    {
        if (turning || shown?.Item1 != AnswerSymbol.Working || !moves || icon is null || !IsLoaded || !Settings.AnimationsEnabled) return;
        var visual = ElementCompositionPreview.GetElementVisual(icon);
        var c = visual.Compositor;
        visual.CenterPoint = new Vector3(6, 6, 0);
        var turn = c.CreateScalarKeyFrameAnimation();
        turn.InsertKeyFrame(0, 0);
        turn.InsertKeyFrame(1, 360, c.CreateLinearEasingFunction());
        turn.Duration = TimeSpan.FromSeconds(3);
        turn.IterationBehavior = AnimationIterationBehavior.Forever;
        visual.StartAnimation("RotationAngleInDegrees", turn);
        turning = true;
    }

    private void Rest()
    {
        if (!turning || icon is null) return;
        turning = false;
        var visual = ElementCompositionPreview.GetElementVisual(icon);
        visual.StopAnimation("RotationAngleInDegrees");
        visual.RotationAngleInDegrees = 0;
    }
}

/// <summary>The picture of a request's option (owner feature `need_pictures`): a square as wide as its column, from the
/// first frame, with a card's corners. The picture stands in it whole, on the fill of a file's place; while its bytes
/// come, the square keeps its size with "Reading…" in it, and a picture that did not come says "Not loaded" with Read
/// again, as a picture of a message does (FileTileView). A click opens it, as a file of a message opens.</summary>
internal sealed partial class OptionPictureView : Panel
{
    private readonly Button face;
    private readonly Image image = new() { Stretch = Stretch.Uniform };
    private readonly TextBlock words = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly Button read;
    private FileTile? tile;

    /// <param name="current">The option's picture now (<see cref="OptionsModel.Click"/>): what a click opens.</param>
    public OptionPictureView(Func<FileTile?> current, Action<FileTile> open, Action<FileTile> again)
    {
        words.HorizontalAlignment = HorizontalAlignment.Center;
        words.VerticalAlignment = VerticalAlignment.Center;
        read = Buttons.IconOnly(Icons.Refresh, "");
        read.HorizontalAlignment = HorizontalAlignment.Center;
        read.VerticalAlignment = VerticalAlignment.Bottom;
        read.Margin = new Thickness(0, 0, 0, 16);
        read.Click += (_, _) => { if (tile is { } t) again(t); };
        face = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            CornerRadius = new CornerRadius(8),
            Content = new Grid
            {
                Children =
                {
                    // The picture with a card's corners, as FileTileView draws a picture of a message.
                    new Border { CornerRadius = new CornerRadius(8), Background = Look.SelectBrush, Child = image },
                    words,
                    read,
                },
            },
        };
        face.Click += (_, _) => { if (current() is { } t) open(t); };
        Children.Add(face);
    }

    public void Show(FileTile next, ImageSource? picture)
    {
        tile = next;
        image.Source = picture;
        image.Visibility = picture is null ? Visibility.Collapsed : Visibility.Visible;
        words.Text = next.Reading ? next.ReadingWords : next.Words;
        words.Foreground = next.WordsAreWarning ? Look.Orange : Look.Muted;
        words.Visibility = picture is null ? Visibility.Visible : Visibility.Collapsed;
        read.Visibility = picture is null && next.ShowsReadAgain ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(read, next.ReadAgainHover);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(read, next.ReadAgainHover);
        ToolTipService.SetToolTip(face, next.Hover);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(face, next.Name);
    }

    /// <summary>A square as wide as the column gives.</summary>
    protected override global::Windows.Foundation.Size MeasureOverride(global::Windows.Foundation.Size available)
    {
        double side = double.IsFinite(available.Width) ? available.Width : 0;
        face.Measure(new global::Windows.Foundation.Size(side, side));
        return new global::Windows.Foundation.Size(side, side);
    }

    protected override global::Windows.Foundation.Size ArrangeOverride(global::Windows.Foundation.Size final)
    {
        face.Arrange(new global::Windows.Foundation.Rect(0, 0, final.Width, final.Width));
        return new global::Windows.Foundation.Size(final.Width, final.Width);
    }
}

/// <summary>A request's card in a chat (NeedRequestCard), as pictures 1, 2a and 16 draw it: its title, its reason
/// (three lines, or whole after Show all, with what it needs from him and its details), "Show all" or "Show less" alone
/// on its row (Discuss left the product: the owner, 13 November 2026), who asks and when, the options and the answer
/// box, his answer. Where the hub says that the card takes a message (owner feature `need_clarify`), his talk with the
/// agent stands over the options and "Needs clarification" under the box (w4-windows-chat.png). After his answer the
/// card folds to its title and his answer with a check.
///
/// His answer waits 5 seconds with Undo (the owner's "Yes, 5 seconds (Recommended)", 21 November 2026;
/// <see cref="RequestCard.Holds"/>): the folded card shows his answer with "Undo" at the end of its line, in the link's
/// colour, and no mark. While his answer's task works, the task's Pause icon stands there (his "Both (Recommended)";
/// <see cref="RequestCard.Pause"/>), 20 square, so the line keeps its height; and the turning mark, the orange mark and
/// the gray mark of his pause open the task's page (his "Yes, open task"; <see cref="RequestCard.OpensTask"/>,
/// <see cref="MarkPress"/>).</summary>
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
    /// <summary>The folded card's answer line: the mark (or the press that holds it), his answer, and at its end Undo or
    /// Pause.</summary>
    private readonly Grid answered = new() { Margin = new Thickness(0, -6, 0, 0) };
    private readonly TextBlock answeredWords = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly AnswerMarkView answeredMark = new();
    private readonly MarkPress markPress = new();
    private readonly Button undo;
    private readonly Button pause;
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
        answered.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        answered.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        answered.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        answeredWords.TextTrimming = TextTrimming.CharacterEllipsis;
        answeredWords.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(answeredWords, 1);
        answered.Children.Add(answeredMark);
        answered.Children.Add(answeredWords);
        markPress.Click += (_, _) => { if (card?.OpensTask is { } t) answers.OpenTask(t); };
        // At the end of the line, 8 after his answer (the Mac's Spacer(minLength: 8)): Undo, or the task's Pause.
        undo = LinkPress("Undo", 12, 16);
        undo.Margin = new Thickness(8, 0, 0, 0);
        undo.Click += (_, _) => { if (card is { Holds: true } c) answers.Undo(c.Id); };
        pause = Buttons.IconOnly(Icons.Pause, "Pause", side: 20, size: 12);
        // its 20 stand over the line of 16 and do not make it taller: the card keeps its height when Pause comes and goes
        pause.Margin = new Thickness(8, -2, 0, -2);
        pause.Click += (_, _) => { if (card?.Pause is { } t) answers.Pause(t); };
        var end = new Grid { VerticalAlignment = VerticalAlignment.Center, Children = { undo, pause } };
        Grid.SetColumn(end, 2);
        answered.Children.Add(end);

        stack.Children.Add(title);
        stack.Children.Add(answered);
        stack.Children.Add(why);
        stack.Children.Add(task);
        stack.Children.Add(details);
        stack.Children.Add(todoLabel);
        stack.Children.Add(todo);
        stack.Children.Add(links);
        stack.Children.Add(from);
        stack.Children.Add(parts.Talk);
        stack.Children.Add(parts.Options);
        stack.Children.Add(parts.Box);
        stack.Children.Add(parts.Clarify);
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
        // In the check's place, the mark of where the work of his answer stands (owner API 1.280); none while his
        // answer waits with Undo. A mark of a task's work, of a task that needs him, or of his pause opens the task.
        PlaceMark(next.OpensTask is not null);
        (next.OpensTask is null ? (FrameworkElement)answeredMark : markPress).Visibility =
            next.ShowsCheck ? Visibility.Visible : Visibility.Collapsed;
        answeredMark.Visibility = next.ShowsCheck ? Visibility.Visible : Visibility.Collapsed;
        answeredMark.Show(next.AnswerMark, next.MarkMoves);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(markPress, next.AnswerMark.Words ?? "");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(markPress, next.OpenWords);
        answeredWords.Text = next.AnswerWords;
        // 5 after the mark, as before; at the leading edge where no mark stands (his words, an answer that waits)
        answeredWords.Margin = new Thickness(next.ShowsCheck ? 5 : 0, 0, 0, 0);
        undo.Visibility = next.Holds ? Visibility.Visible : Visibility.Collapsed;
        pause.Visibility = next.Pause is not null && !next.Holds ? Visibility.Visible : Visibility.Collapsed;
        pause.IsEnabled = next.PauseEnabled;
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
            if (b.Short || whole) why.Content = Blocks.Of(b.WhyBlocks, b.Why, card: true, copies: true, values: b.WhyValues);
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
        if (taskShows && b.Task != shownTask) { shownTask = b.Task!; task.Content = Blocks.Of(b.TaskBlocks, b.Task!, card: true, copies: true, values: b.TaskValues); }
        // Behind the link: the details (a door's script is one fenced block from the hub already, door_script_details),
        // then a task that stays behind it (a door call, a conversation's item), under its label.
        bool detailsShow = !folded && whole && b.Details is not null;
        details.Visibility = detailsShow ? Visibility.Visible : Visibility.Collapsed;
        if (detailsShow && b.Details != shownDetails)
        {
            shownDetails = b.Details!;
            details.Content = Blocks.Of(b.DetailsBlocks, b.Details!, script: b.DetailsIsScript, card: true, copies: true, values: b.DetailsValues);
        }
        bool todoShows = !folded && whole && b.TodoBehind is not null;
        todoLabel.Text = b.TodoLabel;
        todoLabel.Visibility = todo.Visibility = todoShows ? Visibility.Visible : Visibility.Collapsed;
        if (todoShows && b.TodoBehind != shownTodo) { shownTodo = b.TodoBehind!; todo.Content = Blocks.Of(b.TodoBehindBlocks, b.TodoBehind!, card: true, copies: true, values: b.TodoBehindValues); }
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
        // a folded card's model has no talk and no link
        parts.ShowClarify(next.Id, next.Talk, next.Clarify);
    }

    /// <summary>The mark stands in its press while it opens a task, else alone, as before: a mark that opens nothing has
    /// no hand, no fill and no place in the keyboard's order.</summary>
    private void PlaceMark(bool opens)
    {
        bool inPress = ReferenceEquals(markPress.Content, answeredMark);
        if (opens == inPress) return;
        if (opens)
        {
            answered.Children.Remove(answeredMark);
            markPress.Content = answeredMark;
            answered.Children.Insert(0, markPress);
        }
        else
        {
            markPress.Content = null;
            answered.Children.Remove(markPress);
            answered.Children.Insert(0, answeredMark);
        }
    }

    /// <summary>A press in words in the link's colour, with the hand, as Undo (the Mac's Undo with its link pointer).</summary>
    internal static Button LinkPress(string words, double size, double lineHeight)
    {
        var label = Look.Words(words, size, lineHeight, Look.Link, wrap: false);
        var button = new HandButton
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            Content = label,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, words);
        return button;
    }
}

/// <summary>A button with the hand under the pointer.</summary>
internal class HandButton : Button
{
    public HandButton() => ProtectedCursor = Microsoft.UI.Input.InputSystemCursor.Create(Microsoft.UI.Input.InputSystemCursorShape.Hand);
}

/// <summary>**A press of an answered card's mark opens its task** (the owner's "Both (Recommended)" and "Yes, open task"
/// of 21 November 2026; the Mac's AnsweredMarkView.pressable): the mark in it at its own place, the hand and a soft fill,
/// a circle 3 wider than the mark, under the pointer (his sign of a press), the system's focus frame, and Enter or Space
/// from the keyboard. The mark's own words and its tag under the pointer stay.</summary>
internal sealed class MarkPress : HandButton
{
    private static readonly SolidColorBrush Fill = Look.Brush(Look.White(0.16));
    private static readonly SolidColorBrush Clear = new(global::Windows.UI.Color.FromArgb(0, 0, 0, 0));

    public MarkPress()
    {
        Style = (Style)Application.Current.Resources["ChipKeyStyle"];
        Width = Height = 18;
        Margin = new Thickness(-3);
        CornerRadius = new CornerRadius(9);
        VerticalAlignment = VerticalAlignment.Center;
        Background = Clear;
        PointerEntered += (_, _) => Background = Fill;
        PointerExited += (_, _) => Background = Clear;
        PointerCanceled += (_, _) => Background = Clear;
        PointerCaptureLost += (_, _) => Background = Clear;
    }
}

/// <summary>The request at hand in Needs you (NeedStep), as picture 3 and picture 2b of the second set draw it: the
/// asking agent's mark at 48, who asks and how long ago with the orange hourglass while an agent's work waits on it, the
/// title, the reason, "Details" with its chevron (opened: what it needs from him and its details, from the leading edge),
/// the options and the answer box, his answer. Where the hub says that the request takes a message (owner feature
/// `need_clarify`), "Needs clarification" stands in the middle under the box (w4-windows-needs.png), and his talk with
/// the agent over the options, and over his answer once the request ended, where it keeps its place.</summary>
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
    private readonly AnswerMarkView answeredMark = new();
    private readonly Button undo;
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
        parts.Talk.Margin = new Thickness(0, 24, 0, 0);
        Children.Add(parts.Talk);
        answered.Children.Add(answeredMark);
        answered.Children.Add(answeredWords);
        // His answer waits 5 seconds with Undo at the end of its line (his "Yes, Undo there too"; RequestStep.Holds).
        undo = RequestCardView.LinkPress("Undo", 15, 20);
        undo.Margin = new Thickness(4, 0, 0, 0);
        undo.Click += (_, _) => { if (step is { Holds: true } s) answers.Undo(s.Id); };
        answered.Children.Add(undo);
        Children.Add(answered);
        Children.Add(parts.Options);
        Children.Add(parts.Box);
        Children.Add(parts.Clarify);
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
            if (b.Short || open) why.Content = Blocks.Of(b.WhyBlocks, b.Why, measure: Blocks.Measure.Step, copies: true, centred: centred, values: b.WhyValues);
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
            task.Content = Blocks.Of(b.TaskBlocks, words, measure: Blocks.Measure.Step, copies: true, centred: centred, values: b.TaskValues);
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
                more.Children.Add(Blocks.Of(b.DetailsBlocks, text, script: b.DetailsIsScript, measure: Blocks.Measure.Step, copies: true, values: b.DetailsValues));
            if (b.TodoBehind is { } behind)
            {
                more.Children.Add(Look.Words(b.TodoLabel, 15, 23, Look.Muted, semibold: true));
                more.Children.Add(Blocks.Of(b.TodoBehindBlocks, behind, measure: Blocks.Measure.Step, copies: true, values: b.TodoBehindValues));
            }
        }
        more.Visibility = more.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        // An ended request at hand (he chose it among the answered ones): his answer, and nothing to press. In the check's
        // place, the card's mark of where the work of his answer stands (owner API 1.280; his "Yes, same marks there").
        answered.Visibility = next.Ended ? Visibility.Visible : Visibility.Collapsed;
        answeredMark.Visibility = next.ShowsCheck ? Visibility.Visible : Visibility.Collapsed;
        answeredMark.Show(next.AnswerMark, next.MarkMoves);
        answeredWords.Text = next.AnswerWords;
        undo.Visibility = next.Holds ? Visibility.Visible : Visibility.Collapsed;
        parts.Options.Visibility = parts.Box.Visibility = next.Ended ? Visibility.Collapsed : Visibility.Visible;
        if (!next.Ended) parts.Show(next.Id, next.Options, next.Answer, sendable);
        // His talk keeps its place over the answers, and over his answer once it ended (the Mac's NeedStep.answers): what
        // stands under it comes 10 under it, as the Mac's answers do.
        parts.ShowClarify(next.Id, next.Talk, next.Clarify);
        bool talks = next.Talk.Count > 0;
        parts.Options.Margin = new Thickness(0, talks ? 10 : 24, 0, 0);
        answered.Margin = new Thickness(0, talks ? 10 : 18, 0, 0);
    }
}
