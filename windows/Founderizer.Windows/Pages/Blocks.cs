using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Founderizer.Windows.Pages;

/// <summary>An agent's words as the library's message blocks give them (MessageBlock.Parse): each paragraph, heading,
/// list item, quote, code block, rule and table in its own form, the inline marks read to their words
/// (InlineMarks.Plain). The pictures draw a reply as one paragraph of 14 on 22.</summary>
internal static class Blocks
{
    public const double LineHeight = 22;
    private static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    public static StackPanel Of(IReadOnlyList<MessageBlock> blocks, string text)
    {
        var panel = new StackPanel { Spacing = 10 };
        if (blocks.Count == 0) blocks = [new MessageBlock(MessageBlock.Kinds.Paragraph, text)];
        foreach (var block in blocks) panel.Children.Add(Block(block));
        return panel;
    }

    private static FrameworkElement Block(MessageBlock block)
    {
        switch (block.Kind)
        {
            case MessageBlock.Kinds.Heading:
                return Selectable(Plain(block.Text), semibold: true);
            case MessageBlock.Kinds.Item:
            {
                var grid = new Grid { Margin = new Thickness(block.Level * 20, 0, 0, 0), ColumnSpacing = 6 };
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var marker = Look.Words(block.Marker.Length > 0 ? block.Marker : "•", 14, LineHeight, wrap: false);
                marker.HorizontalAlignment = HorizontalAlignment.Right;
                var words = Selectable(Plain(block.Text));
                Grid.SetColumn(words, 1);
                grid.Children.Add(marker);
                grid.Children.Add(words);
                return grid;
            }
            case MessageBlock.Kinds.Quote:
            {
                var words = Selectable(Plain(block.Text), Look.Muted);
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
                var words = Look.Words(block.Text, 12, 18, wrap: false);
                words.FontFamily = Mono;
                words.IsTextSelectionEnabled = true;
                return new Border
                {
                    Background = Look.SurfaceBrush,
                    BorderBrush = Look.CardEdge,
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(12, 8, 12, 8),
                    Child = new ScrollViewer
                    {
                        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                        HorizontalScrollMode = ScrollMode.Auto,
                        VerticalScrollMode = ScrollMode.Disabled,
                        Content = words,
                    },
                };
            }
            case MessageBlock.Kinds.Rule:
                return new Rectangle { Height = 1, Fill = Look.Line, Margin = new Thickness(0, 6, 0, 6) };
            case MessageBlock.Kinds.Table:
                return Table(block);
            default:
                return Selectable(Plain(block.Text));
        }
    }

    private static FrameworkElement Table(MessageBlock block)
    {
        var rows = block.Rows;
        int columns = rows.Count == 0 ? 0 : rows.Max(r => r.Count);
        var grid = new Grid { ColumnSpacing = 16, RowSpacing = 4 };
        for (int c = 0; c < columns; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (int r = 0; r < rows.Count; r++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (int c = 0; c < rows[r].Count; c++)
            {
                var cell = Selectable(Plain(rows[r][c]), semibold: r == 0);
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
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

    private static string Plain(string text) => InlineMarks.Plain(text);

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
