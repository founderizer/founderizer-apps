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
    /// middle, as a step's line does.</summary>
    public static StackPanel Of(IReadOnlyList<MessageBlock> blocks, string text, bool script = false, Measure? measure = null,
                                bool card = false, bool copies = false, bool centred = false)
    {
        var m = measure ?? Measure.Chat;
        var panel = new StackPanel();
        if (blocks.Count == 0) blocks = [new MessageBlock(MessageBlock.Kinds.Paragraph, text)];
        MessageBlock? before = null;
        foreach (var block in blocks)
        {
            var view = Block(block, script, m, card, copies && !script, centred);
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

    private static FrameworkElement Block(MessageBlock block, bool script, Measure m, bool card, bool copies, bool centred)
    {
        switch (block.Kind)
        {
            case MessageBlock.Kinds.Heading:
            {
                var heading = Marked(block.Text, semibold: true, size: m.Heading, lineHeight: m.Line, codeSize: m.Code);
                if (m == Measure.Chat) heading.FontFamily = Look.Display;
                return heading;
            }
            case MessageBlock.Kinds.Item:
            {
                var grid = new Grid { Margin = new Thickness(3 + block.Level * 20, 0, 0, 0), ColumnSpacing = 9 };
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto, MinWidth = 12 });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var marker = Look.Words(block.Marker.Length > 0 ? block.Marker : "•", m.Size, m.Line, wrap: false);
                marker.HorizontalAlignment = HorizontalAlignment.Right;
                var words = Marked(block.Text, size: m.Size, lineHeight: m.Line, codeSize: m.Code);
                Grid.SetColumn(words, 1);
                grid.Children.Add(marker);
                grid.Children.Add(words);
                return grid;
            }
            case MessageBlock.Kinds.Quote:
            {
                var words = Marked(block.Text, Look.Muted, size: m.Size, lineHeight: m.Line, codeSize: m.Code);
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
                var words = Marked(block.Text, size: m.Size, lineHeight: m.Line, codeSize: m.Code);
                if (centred) words.TextAlignment = TextAlignment.Center;
                return words;
            }
        }
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
    public static void Fill(TextBlock block, string text, Brush? brush = null, double codeSize = 12.5)
    {
        block.Inlines.Clear();
        block.TextHighlighters.Clear();
        var code = new TextHighlighter { Background = CodeGround, Foreground = brush ?? Look.Text };
        int at = 0;
        foreach (var run in InlineMarks.Runs(text))
        {
            var words = new Run { Text = run.Text };
            if (run.Bold) words.FontWeight = FontWeights.SemiBold;
            if (run.Italic) words.FontStyle = global::Windows.UI.Text.FontStyle.Italic;
            if (run.Struck) words.TextDecorations = global::Windows.UI.Text.TextDecorations.Strikethrough;
            if (run.Code)
            {
                words.FontFamily = Mono;
                words.FontSize = codeSize;
                code.Ranges.Add(new TextRange { StartIndex = at, Length = run.Text.Length });
            }
            if (run.Link is { } link && Uri.TryCreate(link, UriKind.Absolute, out var address))
            {
                // The link colour, with no underline, as the Mac's tint; a press opens the PC's browser (or mail).
                var hyperlink = new Hyperlink { Foreground = Look.Link, UnderlineStyle = UnderlineStyle.None };
                hyperlink.Inlines.Add(words);
                hyperlink.Click += (_, _) => _ = global::Windows.System.Launcher.LaunchUriAsync(address);
                block.Inlines.Add(hyperlink);
            }
            else block.Inlines.Add(words);
            at += run.Text.Length;
        }
        if (code.Ranges.Count > 0) block.TextHighlighters.Add(code);
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
