using System.Collections.Generic;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Founderizer.Windows.Pages;

/// <summary>The line between a task's work and its result (the Mac's TaskView, Rule()).</summary>
internal sealed record RuleRow;

/// <summary>A result's check, folded or open (the Mac's FoldRow), with the result it belongs to; its checked outputs'
/// button is the library's (CheckedOutputsModel: "View outputs", then "Reload outputs").</summary>
internal sealed record CheckRow(ResultModel Result, bool Open);

/// <summary>A field of a task's thread (the Mac's DetailField): its label, muted, and its value, with an agent's mark.</summary>
internal sealed record DetailRow(string Label, string Value, MarkLook? Mark);

/// <summary>A checked output opened (fourth set, 1b to 1d): the library's model, its picture as the window decoded it,
/// and whether its verified download stands open.</summary>
internal sealed record OutputBoxRow(OpenedOutputModel Opened, ImageSource? Picture, bool VerifyOpen);

/// <summary>A muted line of a task's thread: no checked output to list (fourth set, 1e).</summary>
internal sealed record MutedLine(string Words);

/// <summary>The face of a fold (the Mac's FoldRow): a mark, the title, a state at the right end and a chevron, in the
/// thread's light grey; a title cuts with "…" before the state. With no state, the chevron follows the title.
/// <paramref name="chat"/>: a row of a thread (a mark of 17, 14 on <paramref name="line"/>, a chevron of 10, 10
/// between); else a fold in a form's detail (15, 12 on 16, 9, 9 between: "Verified download").</summary>
internal sealed class FoldFace : Grid
{
    public static readonly Brush Grey = Look.Brush(Look.Rgb(0xB3, 0xB3, 0xB3));
    private readonly bool chat;
    private readonly ContentControl mark = new() { IsTabStop = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock title;
    private readonly TextBlock status = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly ContentControl chevron = new() { IsTabStop = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly Brush ink;

    public FoldFace(bool chat, double line = 20, Brush? ink = null)
    {
        this.chat = chat;
        this.ink = ink ?? (chat ? Grey : Look.Muted);
        title = chat ? Look.Words("", 14, line, this.ink, wrap: false) : Look.Words("", 12, 16, this.ink, wrap: false);
        title.VerticalAlignment = status.VerticalAlignment = VerticalAlignment.Center;
        // The room between the parts is margins, not the grid's column spacing, which an empty state's column takes too.
        double gap = chat ? 10 : 9;
        mark.Margin = new Thickness(0, 0, gap, 0);
        status.Margin = chevron.Margin = new Thickness(gap, 0, 0, 0);
        foreach (var _ in new[] { 0, 1, 2, 3 }) ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        SetColumn(title, 1);
        SetColumn(status, 2);
        SetColumn(chevron, 3);
        Children.Add(mark);
        Children.Add(title);
        Children.Add(status);
        Children.Add(chevron);
    }

    public string Title => title.Text;

    /// <summary>A mark's Fluent icon (the Mac's toolSymbol): a kind of tool that the pictures do not show takes the run's
    /// own mark.</summary>
    public static Icon IconOf(FoldMark mark) => mark switch
    {
        FoldMark.Read => Icons.DocumentText,
        FoldMark.Search => Icons.Search,
        FoldMark.Edit => Icons.Edit,
        FoldMark.Execute => Icons.Console,
        FoldMark.Fetch => Icons.Globe,
        FoldMark.Hand => Icons.Hand,
        FoldMark.Thought => Icons.Sparkle,
        FoldMark.Child => Icons.Child,
        _ => Icons.Steps,
    };

    public void Show(Icon icon, string words, string state, bool warn, bool open)
    {
        double side = chat ? 17 : 15;
        mark.Content = Icons.Of(icon, ink, side);
        mark.Width = mark.Height = side;
        title.Text = words;
        status.Text = state;
        status.Foreground = warn ? Look.Orange : Look.Muted;
        status.Visibility = state.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        double turn = chat ? 10 : 9;
        chevron.Content = Icons.Of(open ? Icons.ChevronDown : Icons.ChevronRight, ink, turn);
        chevron.Width = chevron.Height = turn;
        // With a state the face takes the row's width, the state at its right end; without, it is as wide as its words.
        bool wide = state.Length > 0;
        ColumnDefinitions[1].Width = wide ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
        HorizontalAlignment = wide ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
    }
}

/// <summary>A fold's face as a button: a press opens it or folds it again.</summary>
internal sealed class FoldButton : Button
{
    public readonly FoldFace Face;

    public FoldButton(bool chat, double line = 20)
    {
        Face = new FoldFace(chat, line);
        if (line != 20) Face.Height = line;
        Style = (Style)Application.Current.Resources["QuietButtonStyle"];
        Content = Face;
    }

    public void Show(Icon icon, string words, string state, bool warn, bool open)
    {
        Face.Show(icon, words, state, warn, open);
        HorizontalAlignment = Face.HorizontalAlignment;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, state.Length == 0 ? words : words + ", " + state);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(this, open ? "Expanded" : "Collapsed");
    }
}

/// <summary>The box of an open fold (the Mac's FoldRow): 8 under its face, 10 of room, on the surface, corners of 8.</summary>
internal static class FoldBox
{
    public static Border Make() => new()
    {
        Margin = new Thickness(0, 8, 0, 0),
        Padding = new Thickness(10),
        CornerRadius = new CornerRadius(8),
        Background = Look.SurfaceBrush,
    };

    /// <summary>A field of a fold's box (DetailField): its label, muted, 4 over its value, 12 on 16.</summary>
    public static StackPanel Field(string label, string value, bool select = false)
    {
        var k = Look.Words(label, 12, 16, Look.Muted);
        k.Margin = new Thickness(0, 0, 0, 4);
        var v = Look.Words(value, 12, 16);
        v.IsTextSelectionEnabled = select;
        return new StackPanel { Children = { k, v } };
    }
}

/// <summary>The line: 1 high, in the line's colour (picture 1 of the third set).</summary>
internal sealed class RuleRowView : RowView
{
    public RuleRowView() => Children.Add(new Rectangle { Height = 1, Fill = Look.Line, VerticalAlignment = VerticalAlignment.Top });

    public override RowKind Kind => RowKind.Rule;

    protected override void DrawRow(ThreadItem item) { }
}

/// <summary>The check of a result (pictures 1 and 2 of the third set): its fold, with the check's mark, folded as the
/// page opens; a press opens it on a box of 12 on 16: the output, how it was checked, a note, and when. A result that
/// was accepted has its checked outputs under it, with "View outputs", which lists them (fourth set, 1a), and then
/// "Reload outputs".</summary>
internal sealed class CheckRowView : RowView
{
    private readonly FoldButton fold = new(chat: true);
    private readonly Border box = FoldBox.Make();
    private readonly StackPanel boxRows = new() { Spacing = 10 };
    private readonly Grid outputs = new() { Margin = new Thickness(0, 21, 0, 0), ColumnSpacing = 8 };
    private readonly TextBlock outputsWords = Look.Words("", 12, 16, semibold: true, wrap: false);
    private readonly Button view = Buttons.Plain("");

    public CheckRowView(IThreadContext context)
    {
        fold.Click += (_, _) => context.ToggleCheck();
        box.Child = boxRows;

        outputs.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        outputs.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        outputs.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var document = Icons.Of(Icons.DocumentText, Look.Muted, 16);
        document.VerticalAlignment = VerticalAlignment.Center;
        outputsWords.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(outputsWords, 1);
        Grid.SetColumn(view, 2);
        view.Click += (_, _) => context.ListOutputs();
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(view, "ViewOutputs");
        outputs.Children.Add(document);
        outputs.Children.Add(outputsWords);
        outputs.Children.Add(view);

        Children.Add(new StackPanel { Children = { fold, box, outputs } });
    }

    public override RowKind Kind => RowKind.Check;

    protected override void DrawRow(ThreadItem item)
    {
        var (result, open) = (CheckRow)item.Model;
        fold.Show(Icons.CheckCircle20, result.Check, "", false, open);
        box.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        boxRows.Children.Clear();
        if (open)
        {
            boxRows.Children.Add(FoldBox.Field(result.OutputLabel, result.Output));
            boxRows.Children.Add(FoldBox.Field(result.HowLabel, result.How));
            if (result.Note is { } note) boxRows.Children.Add(Look.Words(note, 12, 16));
            if (result.CheckedAt is { } at) boxRows.Children.Add(Look.Words(at, 12, 16, Look.Muted));
        }
        outputs.Visibility = result.Outputs is null ? Visibility.Collapsed : Visibility.Visible;
        if (result.Outputs is { } o)
        {
            outputsWords.Text = o.Heading;
            ((TextBlock)((Border)view.Content).Child).Text = o.ViewWords;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(view, o.ViewWords);
            view.IsEnabled = o.Enabled;
        }
    }
}

/// <summary>A checked output in the list (fourth set, 1a): its mark (a document's or a picture's) at 16, muted, its path
/// at 12 on 16, which wraps, and "View" at the right end.</summary>
internal sealed class OutputFileRowView : RowView
{
    private readonly ContentControl mark = new() { IsTabStop = false, Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock path = Look.Words("", 12, 16);
    private readonly Button view = Buttons.Plain("");
    private OutputFileRow? shown;

    public OutputFileRowView(IThreadContext context)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        path.VerticalAlignment = VerticalAlignment.Center;
        path.IsTextSelectionEnabled = true;
        Grid.SetColumn(path, 1);
        Grid.SetColumn(view, 2);
        view.Click += (_, _) => { if (shown is not null) context.ViewOutput(shown.File); };
        row.Children.Add(mark);
        row.Children.Add(path);
        row.Children.Add(view);
        Children.Add(row);
    }

    public override RowKind Kind => RowKind.OutputFile;

    protected override void DrawRow(ThreadItem item)
    {
        var row = (OutputFileRow)item.Model;
        shown = row;
        mark.Content = Icons.Of(row.IsImage ? Icons.Image : Icons.DocumentText, Look.Muted, 16);
        path.Text = row.Path;
        ((TextBlock)((Border)view.Content).Child).Text = row.ViewWords;
        // "View" with the file's path, for an assistive app (the Mac's "View \(file.path)").
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(view, row.ViewName);
        view.IsEnabled = row.Enabled;
    }
}

/// <summary>A checked output opened (fourth set, 1b to 1d): a box of 12 on the surface, corners of 8 (the Mac's are
/// 13), 10 between its parts: the path, semibold, and "Close"; the text in Consolas 12 on 18 in a scroll of 80 to 320
/// high (TextHeight), or the picture at most 340 high; and "Verified download · size", a fold of a form's detail that
/// opens on the snapshot's commit, the SHA-256 and the type.</summary>
internal sealed class OutputBoxRowView : RowView
{
    private static readonly FontFamily Mono = new("Consolas");
    private readonly TextBlock path = Look.Words("", 12, 16, semibold: true);
    private readonly Button close = Buttons.Plain("");
    private readonly TextBlock text = new()
    {
        FontFamily = Mono,
        FontSize = 12,
        LineHeight = 18,
        LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
        Foreground = Look.Text,
        IsTextSelectionEnabled = true,
        Padding = new Thickness(0, 1, 0, 0),
    };
    private readonly ScrollViewer scroll = new()
    {
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollMode = ScrollMode.Auto,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };
    private readonly Image picture = new() { MaxHeight = 340, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock empty = Look.Words("", brush: Look.Muted);
    private readonly Button verify = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private readonly FoldFace verifyFace = new(chat: false);
    private readonly StackPanel verifyBox = new() { Spacing = 8, Padding = new Thickness(10) };

    public OutputBoxRowView(IThreadContext context)
    {
        var head = new Grid { ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        path.VerticalAlignment = VerticalAlignment.Center;
        path.IsTextSelectionEnabled = true;
        Grid.SetColumn(close, 1);
        close.Click += (_, _) => context.CloseOutput();
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(close, "CloseOutput");
        head.Children.Add(path);
        head.Children.Add(close);

        scroll.Content = text;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(text, "OutputText");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(picture, "OutputPicture");
        verify.Style = (Style)Application.Current.Resources["QuietButtonStyle"];
        verify.Content = verifyFace;
        verify.Click += (_, _) => context.ToggleVerify();
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(verify, "VerifiedDownload");

        Children.Add(new Border
        {
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(8),
            Background = Look.SurfaceBrush,
            Child = new StackPanel { Spacing = 10, Children = { head, scroll, picture, empty, verify, verifyBox } },
        });
    }

    public override RowKind Kind => RowKind.OutputBox;

    protected override void DrawRow(ThreadItem item)
    {
        var (opened, image, verifyOpen) = (OutputBoxRow)item.Model;
        string shownPath = path.Text;
        path.Text = opened.Path;
        ((TextBlock)((Border)close.Content).Child).Text = opened.CloseWords;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(close, opened.CloseWords);

        bool hasText = !string.IsNullOrEmpty(opened.Text);
        scroll.Visibility = hasText ? Visibility.Visible : Visibility.Collapsed;
        // A file opened again starts at its top; the verified download's fold keeps the place he scrolled to.
        if (hasText && (opened.Path != shownPath || opened.Text != text.Text))
        {
            text.Text = opened.Text!;
            scroll.Height = opened.TextHeight;
            scroll.ChangeView(0, 0, null, true);
        }
        picture.Source = image;
        picture.MaxHeight = opened.PictureMaxHeight;
        picture.Visibility = image is null ? Visibility.Collapsed : Visibility.Visible;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picture, opened.PictureName ?? "");
        empty.Text = opened.EmptyWords;
        empty.Visibility = opened.EmptyText ? Visibility.Visible : Visibility.Collapsed;

        verifyFace.Show(Icons.ShieldCheck, opened.Download, "", false, verifyOpen);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(verify, opened.Download);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(verify, verifyOpen ? "Expanded" : "Collapsed");
        verifyBox.Children.Clear();
        verifyBox.Visibility = verifyOpen ? Visibility.Visible : Visibility.Collapsed;
        if (verifyOpen)
            foreach (var fact in opened.Facts)
            {
                var field = FoldBox.Field(fact.Label, fact.Value, select: true);
                ((TextBlock)field.Children[1]).TextWrapping = TextWrapping.Wrap;
                verifyBox.Children.Add(field);
            }
    }
}

/// <summary>A fold of a task's thread (fourth set, 2a to 2c): a run of steps, or a permission that waits, which opens on
/// its command in code (Consolas 12.5 on 17, wrapping anywhere) and its reason.</summary>
internal sealed class FoldRowView : RowView
{
    private static readonly FontFamily Mono = new("Consolas");
    private readonly FoldButton fold = new(chat: true);
    private readonly Border box = FoldBox.Make();
    private readonly TextBlock code = new()
    {
        FontFamily = Mono,
        FontSize = 12.5,
        LineHeight = 17,
        LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
        Foreground = Look.Text,
        // A long command breaks anywhere, as the Mac's code does, not only at its spaces.
        TextWrapping = TextWrapping.Wrap,
        IsTextSelectionEnabled = true,
    };
    private readonly TextBlock words = Look.Words("");
    private string key = "";

    public FoldRowView(IThreadContext context)
    {
        fold.Click += (_, _) => context.ToggleFold(key);
        words.IsTextSelectionEnabled = true;
        box.Child = new StackPanel { Spacing = 9, Children = { code, words } };
        Children.Add(new StackPanel { Children = { fold, box } });
    }

    public override RowKind Kind => RowKind.Fold;

    protected override void DrawRow(ThreadItem item)
    {
        var row = (FoldRowModel)item.Model;
        key = row.Key;
        fold.Show(FoldFace.IconOf(row.Mark), row.Title, row.Status, row.Warn, row.Open);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(fold, "Fold-" + row.Key);
        bool boxed = row.Open && (row.Code is not null || row.Words is not null);
        box.Visibility = boxed ? Visibility.Visible : Visibility.Collapsed;
        code.Text = row.Code ?? "";
        code.Visibility = row.Code is null ? Visibility.Collapsed : Visibility.Visible;
        words.Text = row.Words ?? "";
        words.Visibility = row.Words is null ? Visibility.Collapsed : Visibility.Visible;
    }
}

/// <summary>The code font of a step's parts (ChatStyle.code): Consolas 12.5 on 17, wrapping anywhere, selectable.</summary>
internal static class Code
{
    private static readonly FontFamily Mono = new("Consolas");

    public static TextBlock Of(string text, Brush? brush = null) => new()
    {
        Text = text,
        FontFamily = Mono,
        FontSize = 12.5,
        LineHeight = 17,
        LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
        Foreground = brush ?? Look.Text,
        TextWrapping = TextWrapping.Wrap,
        IsTextSelectionEnabled = true,
    };
}

/// <summary>A step (fourth set, 2b; fifth set, 1a to 6a; the Mac's RuntimeRow): its face, 22 high, which opens it; on its
/// run's box (20 between two steps, 10 of room at the box's edges, the box's corners on its first and last step) or alone
/// in a child agent's thread. Opened, 8 under its face and 10 in: a tool's full title, its files, its output, the script
/// that made it with "Script result" folded, a child agent's last rows and "Open agent thread"; a thought's words; a
/// plan's steps. Alone, the opened part stands on the surface, as a fold's box does.</summary>
internal sealed class StepRowView : RowView
{
    private readonly IThreadContext context;
    private readonly FoldButton face = new(chat: true, line: TaskThreadRows.StepFace);
    private readonly Border box = new();
    private readonly Border opened = FoldBox.Make();
    private readonly StackPanel parts = new() { Spacing = 10 };
    private StepRow? shown;

    public StepRowView(IThreadContext context)
    {
        this.context = context;
        face.Click += (_, _) => { if (shown is not null) this.context.ToggleFold(shown.Step.Key); };
        opened.Child = parts;
        box.Child = new StackPanel { Children = { face, opened } };
        Children.Add(box);
    }

    public override RowKind Kind => RowKind.Step;

    protected override void DrawRow(ThreadItem item)
    {
        var row = (StepRow)item.Model;
        var step = row.Step;
        bool same = shown is { } before && before.Step == step && before.Open == row.Open && before.ScriptOpen == row.ScriptOpen;
        shown = row;
        face.Show(FoldFace.IconOf(row.Mark), step.Title, step.Status, step.Orange, row.Open);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(face, "Step-" + step.Key);
        if (row.Boxed)
        {
            box.Background = Look.SurfaceBrush;
            box.Padding = new Thickness(10, TaskThreadRows.StepTop(row), 10, TaskThreadRows.StepBottom(row));
            box.CornerRadius = new CornerRadius(row.First ? 8 : 0, row.First ? 8 : 0, row.Last ? 8 : 0, row.Last ? 8 : 0);
        }
        else
        {
            box.Background = null;
            box.Padding = new Thickness(0);
            box.CornerRadius = new CornerRadius(0);
        }
        // On the run's box the opened part is on the same surface; alone, it has its own.
        opened.Background = row.Boxed ? null : Look.SurfaceBrush;
        opened.Visibility = row.Open ? Visibility.Visible : Visibility.Collapsed;
        if (!row.Open || same) return;
        parts.Children.Clear();
        switch (step.Kind)
        {
            case ActivityRowKind.Thought:
                var thought = Look.Words(step.Text ?? "");
                thought.IsTextSelectionEnabled = true;
                parts.Children.Add(thought);
                break;
            case ActivityRowKind.Plan:
                parts.Children.Add(PlanRowView.Steps(step.Plan));
                break;
            default:
                Tool(step, row.ScriptOpen);
                break;
        }
    }

    private void Tool(StepRowModel step, bool scriptOpen)
    {
        if (step.FullTitle is { } full) parts.Children.Add(Code.Of(full));
        foreach (var location in step.Locations)
        {
            var mark = Icons.Of(Icons.DocumentText, Look.Muted, 14);
            mark.VerticalAlignment = VerticalAlignment.Center;
            var path = Look.Words(location, 12, 16, Look.Muted);
            path.IsTextSelectionEnabled = true;
            path.VerticalAlignment = VerticalAlignment.Center;
            var line = new Grid { ColumnSpacing = 6, ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
            Grid.SetColumn(path, 1);
            line.Children.Add(mark);
            line.Children.Add(path);
            parts.Children.Add(line);
        }
        if (step.Output is { } output) parts.Children.Add(Code.Of(output));
        if (step.Script is { } script)
        {
            parts.Children.Add(Code.Of(script, Look.Muted));
            var fold = new FoldButton(chat: false);
            fold.Show(Icons.Console, step.ScriptResultTitle, "", false, scriptOpen);
            fold.Click += (_, _) => context.ToggleFold(TaskThreadRows.ScriptKey(step.Key));
            var result = FoldBox.Make();
            result.Background = null;
            result.Child = Code.Of(step.ScriptResult ?? "");
            result.Visibility = scriptOpen ? Visibility.Visible : Visibility.Collapsed;
            parts.Children.Add(new StackPanel { Children = { fold, result } });
        }
        if (step.Child is { } child)
        {
            var kids = new StackPanel { Spacing = 8 };
            foreach (var line in step.ChildLines)
            {
                var words = Look.Words(line, 12, 16, Look.Muted);
                words.MaxLines = 2;
                words.TextTrimming = TextTrimming.CharacterEllipsis;
                kids.Children.Add(words);
            }
            var arrow = Icons.Of(Icons.OpenThread, Look.Text, 12);
            arrow.VerticalAlignment = VerticalAlignment.Center;
            var label = Look.Words(step.OpenChildWords, 12, 16, wrap: false);
            var open = new Button
            {
                Style = (Style)Application.Current.Resources["QuietButtonStyle"],
                HorizontalAlignment = HorizontalAlignment.Left,
                Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { arrow, label } },
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(open, step.OpenChildWords);
            open.Click += (_, _) => context.OpenChild(child);
            kids.Children.Add(open);
            parts.Children.Add(new Border
            {
                BorderBrush = Look.Line,
                BorderThickness = new Thickness(1, 0, 0, 0),
                Padding = new Thickness(12, 0, 0, 0),
                Child = kids,
            });
        }
    }
}

/// <summary>A line of a task's thread (fifth set, 2 and 7; the Mac's RuntimeActivity and RuntimeRow): an error in orange
/// with its mark, at the chat's size; a read of the record that failed, in orange with its mark, small; "Offline · last
/// activity" in orange, small; the record's cut, muted, small; a child agent that wrote nothing yet, muted.</summary>
internal sealed class LineRowView : RowView
{
    private readonly ContentControl mark = new() { IsTabStop = false, VerticalAlignment = VerticalAlignment.Top };
    private readonly TextBlock words = Look.Words("");

    public LineRowView()
    {
        words.IsTextSelectionEnabled = true;
        var line = new Grid { ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
        Grid.SetColumn(words, 1);
        line.Children.Add(mark);
        line.Children.Add(words);
        Children.Add(line);
    }

    public override RowKind Kind => RowKind.Line;

    protected override void DrawRow(ThreadItem item)
    {
        var (text, look) = (ThreadLine)item.Model;
        bool large = look is LineLook.Error or LineLook.Waiting;
        bool orange = look is LineLook.Error or LineLook.ActivityError or LineLook.Offline;
        bool marked = look is LineLook.Error or LineLook.ActivityError;
        words.Text = text;
        words.FontSize = large ? 14 : 12;
        words.LineHeight = large ? 20 : 16;
        words.Foreground = orange ? Look.Orange : Look.Muted;
        double side = large ? 16 : 14;
        mark.Content = marked ? Icons.Of(Icons.ErrorCircle, Look.Orange, side) : null;
        mark.Width = mark.Height = marked ? side : 0;
        mark.Margin = new Thickness(0, ((large ? 20 : 16) - side) / 2, marked ? (large ? 8 : 6) : 0, 0);
    }
}

/// <summary>His guidance in the thread (fifth set, 5; the Mac's RuntimeActivity .steer): his words in his bubble at the
/// right, and under it, 5 lower, "Guidance · Attempt 1 · Read" muted, with when it was read on hover.</summary>
internal sealed class GuidanceRowView : RowView
{
    private readonly TextBlock words = Blocks.Selectable("", lineHeight: 20);
    private readonly TextBlock line = Look.Words("", 12, 16, Look.Muted, wrap: false);

    public GuidanceRowView()
    {
        line.HorizontalAlignment = HorizontalAlignment.Right;
        var bubble = new Border
        {
            Background = Look.OwnBrush,
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(16, 12, 16, 12),
            HorizontalAlignment = HorizontalAlignment.Right,
            MaxWidth = 692 * 0.72,
            Child = words,
        };
        Children.Add(new StackPanel { Spacing = 5, Children = { bubble, line } });
    }

    public override RowKind Kind => RowKind.Guidance;

    protected override void DrawRow(ThreadItem item)
    {
        var steer = ((GuidanceRow)item.Model).Steer;
        words.Text = steer.Text;
        line.Text = steer.Line;
        ToolTipService.SetToolTip(line, steer.Hover);
    }
}

/// <summary>The plan of the work that runs (fifth set, 4; the Mac's LivePlan and PlanSteps): on the surface, 10 of room,
/// corners of 8, 8 between its steps; a step done muted with its check, the step in work with a dotted ring, a step to
/// come with a ring.</summary>
internal sealed class PlanRowView : RowView
{
    private readonly Border box = new() { Padding = new Thickness(10), CornerRadius = new CornerRadius(8), Background = Look.SurfaceBrush };

    public PlanRowView() => Children.Add(box);

    public override RowKind Kind => RowKind.Plan;

    protected override void DrawRow(ThreadItem item) => box.Child = Steps(((PlanRow)item.Model).Steps);

    public static StackPanel Steps(IEnumerable<PlanStep> steps)
    {
        var list = new StackPanel { Spacing = 8 };
        foreach (var step in steps)
        {
            var ink = step.State == PlanState.Done ? Look.Muted : Look.Text;
            var mark = Icons.Of(step.State switch { PlanState.Done => Icons.CheckCircle20, PlanState.Running => Icons.Hint, _ => Icons.Circle }, ink, 16);
            mark.VerticalAlignment = VerticalAlignment.Top;
            mark.Margin = new Thickness(0, 2, 0, 0);
            var words = Look.Words(step.Content, brush: ink);
            var row = new Grid { ColumnSpacing = 8, ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
            Grid.SetColumn(words, 1);
            row.Children.Add(mark);
            row.Children.Add(words);
            list.Children.Add(row);
        }
        return list;
    }
}

/// <summary>"Earlier activity" over the thread's first shown row (fifth set, 7): muted, 12 on 16, with the arrow up; a
/// press shows 80 rows more.</summary>
internal sealed class EarlierActivityRowView : RowView
{
    private readonly TextBlock words = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly Button button;

    public EarlierActivityRowView(IThreadContext context)
    {
        var arrow = Icons.Of(Icons.Earlier, Look.Muted, 12);
        arrow.VerticalAlignment = VerticalAlignment.Center;
        words.VerticalAlignment = VerticalAlignment.Center;
        button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Left,
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { arrow, words } },
        };
        button.Click += (_, _) => context.ShowEarlierActivity();
        Children.Add(button);
    }

    public override RowKind Kind => RowKind.EarlierActivity;

    protected override void DrawRow(ThreadItem item)
    {
        words.Text = ((EarlierActivity)item.Model).Words;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, words.Text);
    }
}

/// <summary>The head of a child agent's thread (fifth set, 6b; the Mac's childThread): "Back" muted with its arrow, the
/// child's name semibold, its attempt muted at the right.</summary>
internal sealed class ChildHeadRowView : RowView
{
    private readonly TextBlock back = Look.Words("", brush: Look.Muted, wrap: false);
    private readonly TextBlock title = Look.Words("", semibold: true, wrap: false);
    private readonly TextBlock attempt = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly Button button;

    public ChildHeadRowView(IThreadContext context)
    {
        var arrow = Icons.Of(Icons.BackArrow, Look.Muted, 16);
        arrow.VerticalAlignment = back.VerticalAlignment = title.VerticalAlignment = attempt.VerticalAlignment = VerticalAlignment.Center;
        button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Left,
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { arrow, back } },
        };
        button.Click += (_, _) => context.CloseChild();
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(button, "ChildBack");
        var head = new Grid
        {
            ColumnSpacing = 10,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = GridLength.Auto },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
        };
        Grid.SetColumn(title, 1);
        Grid.SetColumn(attempt, 2);
        head.Children.Add(button);
        head.Children.Add(title);
        head.Children.Add(attempt);
        Children.Add(head);
    }

    public override RowKind Kind => RowKind.ChildHead;

    protected override void DrawRow(ThreadItem item)
    {
        var row = (ChildHeadRow)item.Model;
        back.Text = row.BackWords;
        title.Text = row.Title;
        attempt.Text = row.AttemptWords;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, row.BackWords);
    }
}

/// <summary>A field of the thread (picture 3 of the third set: "Waiting for", and the agent with its mark): 12 on 16, the
/// label muted, 4 over the value.</summary>
internal sealed class DetailRowView : RowView
{
    private readonly TextBlock label = Look.Words("", 12, 16, Look.Muted);
    private readonly AgentGlyph mark = new() { Side = 16, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock value = Look.Words("", 12, 16);

    public DetailRowView()
    {
        label.Margin = new Thickness(0, 0, 0, 4);
        value.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(new StackPanel
        {
            Children = { label, new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { mark, value } } },
        });
    }

    public override RowKind Kind => RowKind.Detail;

    protected override void DrawRow(ThreadItem item)
    {
        var row = (DetailRow)item.Model;
        label.Text = row.Label;
        value.Text = row.Value;
        mark.Mark = row.Mark;
        mark.Visibility = row.Mark is null ? Visibility.Collapsed : Visibility.Visible;
    }
}
