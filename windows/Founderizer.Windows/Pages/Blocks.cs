using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Founderizer.Windows.Pages;

/// <summary>An agent's words as the library's message blocks give them (MessageBlock.Parse): each paragraph, heading,
/// list item, quote, code block, rule and table in its own form, and the inline marks in the Mac's form (MessageText):
/// bold, italic, struck through, code in the monospaced font of 12.5 on the bubble's grey, and a link in the link colour
/// that opens the PC's browser (the library's InlineMarks.Runs). The measures are picture 4 of the third set's: 21
/// between blocks and 10 between the items of a list, a heading of 15.5 on 22, code in Consolas.</summary>
internal static class Blocks
{
    public const double LineHeight = 22;
    private static readonly FontFamily Mono = new("Consolas");

    /// <summary>Where message text stands: a chat, and a request's card in it (14 on 22, 21 between blocks, 10 between
    /// two items, code 12.5), or a step (the request at hand: the step's one size, 15 on 23, 9 between blocks, code 13.5,
    /// the Mac's MessageText(step:)).</summary>
    internal sealed record Measure(double Size, double Line, double BlockGap, double ItemGap, double Code, double CodeLine, double Heading)
    {
        public static readonly Measure Chat = new(14, LineHeight, 21, 10, 12.5, 17, 15.5);
        public static readonly Measure Step = new(15, 23, 9, 9, 13.5, 18, 15);
    }

    /// <summary><paramref name="script"/>: the script of the door's card (the Mac's MessageText.script): its code block
    /// wraps and does not scroll sideways, so that the end of a long line is on screen before he answers Run it once.
    /// <paramref name="measure"/>: a chat's (the default) or a step's. <paramref name="card"/>: the text stands on a
    /// request's card, whose fill is the code block's: the block is a well in the canvas's colour there (the Mac's
    /// MessageText.card). <paramref name="copies"/>: a code block shows a copy icon at its top right under the pointer
    /// (the Mac's CodeBlock.copies), never over a wrapped script. <paramref name="centred"/>: a paragraph stands in the
    /// middle, as a step's line does. <paramref name="values"/>: the values of a request's words, block by block (the
    /// library's <see cref="RequestBody"/>): each is a chip with a copy icon (<see cref="ValueChips"/>); never in a door's
    /// script, and no other text has them.</summary>
    public static StackPanel Of(IReadOnlyList<MessageBlock> blocks, string text, bool script = false, Measure? measure = null,
                                bool card = false, bool copies = false, bool centred = false,
                                IReadOnlyList<ValueList<CardValue>>? values = null)
    {
        var m = measure ?? Measure.Chat;
        var panel = new StackPanel();
        if (blocks.Count == 0) blocks = [new MessageBlock(MessageBlock.Kinds.Paragraph, text)];
        MessageBlock? before = null;
        for (int index = 0; index < blocks.Count; index++)
        {
            var block = blocks[index];
            var chips = values is not null && !script && index < values.Count ? values[index] : null;
            var view = Block(block, script, m, card, copies && !script, centred, chips);
            double top = before is null ? 0
                : before.Kind == MessageBlock.Kinds.Item && block.Kind == MessageBlock.Kinds.Item ? m.ItemGap
                : block.Kind == MessageBlock.Kinds.Table ? m.BlockGap + 2 : m.BlockGap;
            var margin = view.Margin;
            view.Margin = new Thickness(margin.Left, top, margin.Right, block.Kind == MessageBlock.Kinds.Table ? 2 : margin.Bottom);
            panel.Children.Add(view);
            before = block;
        }
        return panel;
    }

    private static FrameworkElement Block(MessageBlock block, bool script, Measure m, bool card, bool copies, bool centred,
                                          IReadOnlyList<CardValue>? values)
    {
        switch (block.Kind)
        {
            case MessageBlock.Kinds.Heading:
            {
                var heading = Valued(block.Text, values, m, semibold: true, size: m.Heading);
                if (m == Measure.Chat) heading.Words.FontFamily = Look.Display;
                return heading.View;
            }
            case MessageBlock.Kinds.Item:
            {
                var grid = new Grid { Margin = new Thickness(3 + block.Level * 20, 0, 0, 0), ColumnSpacing = 9 };
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto, MinWidth = 12 });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var marker = Look.Words(block.Marker.Length > 0 ? block.Marker : "•", m.Size, m.Line, wrap: false);
                marker.HorizontalAlignment = HorizontalAlignment.Right;
                var words = Valued(block.Text, values, m).View;
                Grid.SetColumn(words, 1);
                grid.Children.Add(marker);
                grid.Children.Add(words);
                return grid;
            }
            case MessageBlock.Kinds.Quote:
            {
                var words = Valued(block.Text, values, m, Look.Muted).View;
                words.Margin = new Thickness(12, 0, 0, 0);
                return new Grid
                {
                    Children =
                    {
                        new Rectangle { Width = 3, Fill = Look.Line, HorizontalAlignment = HorizontalAlignment.Left, RadiusX = 1.5, RadiusY = 1.5 },
                        words,
                    },
                };
            }
            case MessageBlock.Kinds.Code:
            {
                // One line stays one line, and the block scrolls sideways (the Mac's CodeBlock); a door's script wraps.
                var words = Look.Words(block.Text, m.Code, m.CodeLine, wrap: script);
                words.FontFamily = Mono;
                words.IsTextSelectionEnabled = true;
                var well = card ? Look.CanvasBrush : Look.SurfaceBrush;
                if (script)
                    return new Border { Background = well, CornerRadius = new CornerRadius(8), Padding = new Thickness(12), Child = words };
                var border = new Border
                {
                    Background = well,
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(12),
                    Child = new ScrollViewer
                    {
                        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                        HorizontalScrollMode = ScrollMode.Auto,
                        VerticalScrollMode = ScrollMode.Disabled,
                        Content = words,
                    },
                };
                return copies ? Copies(border, block.Text) : border;
            }
            case MessageBlock.Kinds.Rule:
                return new Rectangle { Height = 1, Fill = Look.Line, Margin = new Thickness(0, 6, 0, 6) };
            case MessageBlock.Kinds.Table:
                return Table(block);
            default:
            {
                var words = Valued(block.Text, values, m);
                if (centred) words.Words.TextAlignment = TextAlignment.Center;
                return words.View;
            }
        }
    }

    /// <summary>A block's words with their inline marks, and a chip for each of their values (<see cref="ValueChips"/>)
    /// where they have some; else the text block alone, as before.</summary>
    private static (TextBlock Words, FrameworkElement View) Valued(string text, IReadOnlyList<CardValue>? values, Measure m,
                                                                   Brush? brush = null, bool semibold = false, double? size = null)
    {
        var words = Selectable("", brush, semibold, size ?? m.Size, m.Line);
        if (values is not { Count: > 0 })
        {
            Fill(words, text, brush, m.Code);
            return (words, words);
        }
        var found = FillValues(words, text, brush, m.Code, values, ValueChips.Room * (size ?? m.Size));
        return (words, new ValueChips(words, found, size ?? m.Size));
    }

    /// <summary>A code block with the Mac's copy icon (CodeBlock.copies): a quiet button of 28 at its top right, 6 in from
    /// the corner, which shows while the pointer is over the block; a press copies the code alone and shows a check
    /// until the pointer leaves. A one-line block is 41 high, so the icon stands in its middle.</summary>
    private static FrameworkElement Copies(Border block, string code)
    {
        var copy = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            Width = 28,
            Height = 28,
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 6, 6, 0),
            Content = Icons.Of(Icons.Copy16, Look.Muted, 12),
            Opacity = 0,
            IsHitTestVisible = false,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(copy, "Copy code");
        copy.Click += (_, _) =>
        {
            var package = new global::Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(code);
            global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
            copy.Content = Icons.Of(Icons.Check, Look.Muted, 12);
        };
        var grid = new Grid { Children = { block, copy } };
        grid.PointerEntered += (_, _) => { copy.Opacity = 1; copy.IsHitTestVisible = true; };
        grid.PointerExited += (_, _) =>
        {
            copy.Opacity = 0;
            copy.IsHitTestVisible = false;
            copy.Content = Icons.Of(Icons.Copy16, Look.Muted, 12);
        };
        return grid;
    }

    /// <summary>A table: its first row the header in semibold with a line under it, 18 after each column, 7 over each
    /// row of the body, whose lines are 20 high.</summary>
    private static FrameworkElement Table(MessageBlock block)
    {
        var rows = block.Rows;
        int columns = rows.Count == 0 ? 0 : rows.Max(r => r.Count);
        var grid = new Grid { HorizontalAlignment = HorizontalAlignment.Left };
        for (int c = 0; c < columns; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (int r = 0; r < rows.Count; r++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (int c = 0; c < rows[r].Count; c++)
            {
                var cell = Marked(rows[r][c], semibold: r == 0, lineHeight: r == 0 ? LineHeight : 20);
                cell.Margin = new Thickness(0, r == 0 ? 0 : 7, 18, r == 0 ? 7 : 0);
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
        }
        if (rows.Count > 0 && columns > 0)
        {
            var line = new Rectangle { Height = 1, Fill = Look.Line, VerticalAlignment = VerticalAlignment.Bottom };
            Grid.SetColumnSpan(line, columns);
            grid.Children.Add(line);
        }
        return new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Auto,
            VerticalScrollMode = ScrollMode.Disabled,
            Content = grid,
        };
    }

    /// <summary>The bubble's grey under inline code (the Mac's FleetStyle.bubble, white at 0.19).</summary>
    private static readonly Brush CodeGround = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 0x30, 0x30, 0x30));

    /// <summary>A block's words with their inline marks, selectable as on the Mac.</summary>
    public static TextBlock Marked(string text, Brush? brush = null, bool semibold = false, double size = 14,
                                   double lineHeight = LineHeight, double codeSize = 12.5)
    {
        var block = Selectable("", brush, semibold, size, lineHeight);
        Fill(block, text, brush, codeSize);
        return block;
    }

    /// <summary>A text block's words, again, with their inline marks (a reply's one paragraph reuses its block).</summary>
    public static void Fill(TextBlock block, string text, Brush? brush = null, double codeSize = 12.5) =>
        FillValues(block, text, brush, codeSize, null, 0);

    /// <summary>A text block's words with their inline marks, and each of <paramref name="values"/> (the library's
    /// <see cref="CardValue"/>, in the same plain words) with a highlighter of its own in inline code's fill and
    /// <paramref name="room"/> pixels after its last character, as the spacing of a run that holds that character alone:
    /// the room of its copy icon (<see cref="ValueChips"/>), with no character added. Gives each value's words.</summary>
    internal static List<ValueChips.Words> FillValues(TextBlock block, string text, Brush? brush, double codeSize,
                                                      IReadOnlyList<CardValue>? values, double room)
    {
        block.Inlines.Clear();
        block.TextHighlighters.Clear();
        var code = new TextHighlighter { Background = CodeGround, Foreground = brush ?? Look.Text };
        var chips = new List<ValueChips.Words>();
        foreach (var value in values ?? [])
            chips.Add(new ValueChips.Words(value, new TextHighlighter { Background = ValueChips.Fill, Foreground = brush ?? Look.Text }));
        int at = 0;
        foreach (var run in InlineMarks.Runs(text))
        {
            var chip = run.Code && run.Link is null
                ? chips.Find(c => c.Value.Start <= at && at + run.Text.Length <= c.Value.Start + c.Value.Length) : null;
            // the value's last character in a run of its own, whose spacing after it is the icon's room
            int cut = chip is not null && at + run.Text.Length == chip.Value.Start + chip.Value.Length ? LastElement(run.Text) : -1;
            string[] pieces = cut <= 0 ? [run.Text] : [run.Text[..cut], run.Text[cut..]];
            for (int p = 0; p < pieces.Length; p++)
            {
                var words = new Run { Text = pieces[p] };
                if (run.Bold) words.FontWeight = FontWeights.SemiBold;
                if (run.Italic) words.FontStyle = global::Windows.UI.Text.FontStyle.Italic;
                if (run.Struck) words.TextDecorations = global::Windows.UI.Text.TextDecorations.Strikethrough;
                if (run.Code)
                {
                    words.FontFamily = Mono;
                    words.FontSize = codeSize;
                }
                if (cut >= 0 && p == pieces.Length - 1) words.CharacterSpacing = (int)Math.Round(room / codeSize * 1000);
                chip?.Runs.Add(words);
                if (run.Link is { } link && Uri.TryCreate(link, UriKind.Absolute, out var address))
                {
                    // The link colour, with no underline, as the Mac's tint; a press opens the PC's browser (or mail).
                    var made = new Hyperlink { Foreground = Look.Link, UnderlineStyle = UnderlineStyle.None };
                    made.Inlines.Add(words);
                    made.Click += (_, _) => _ = global::Windows.System.Launcher.LaunchUriAsync(address);
                    block.Inlines.Add(made);
                }
                else block.Inlines.Add(words);
            }
            if (run.Code && chip is null) code.Ranges.Add(new TextRange { StartIndex = at, Length = run.Text.Length });
            at += run.Text.Length;
        }
        if (code.Ranges.Count > 0) block.TextHighlighters.Add(code);
        foreach (var chip in chips)
        {
            chip.Fill.Ranges.Add(new TextRange { StartIndex = chip.Value.Start, Length = chip.Value.Length });
            block.TextHighlighters.Add(chip.Fill);
        }
        return chips;
    }

    /// <summary>Where the last character of <paramref name="words"/> starts, as a person sees one (a text element: a
    /// letter with its marks, an emoji of two code units).</summary>
    private static int LastElement(string words)
    {
        int at = 0, last = 0;
        while (at < words.Length)
        {
            last = at;
            at += System.Globalization.StringInfo.GetNextTextElementLength(words, at);
        }
        return last;
    }

    /// <summary>Words he can select and copy, as on the Mac.</summary>
    public static TextBlock Selectable(string words, Brush? brush = null, bool semibold = false, double size = 14,
                                       double lineHeight = LineHeight)
    {
        var block = Look.Words(words, size, lineHeight, brush);
        if (semibold) block.FontWeight = FontWeights.SemiBold;
        block.IsTextSelectionEnabled = true;
        return block;
    }
}
