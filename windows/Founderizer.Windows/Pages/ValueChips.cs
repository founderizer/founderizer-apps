using System;
using System.Collections.Generic;
using Founderizer.Core;
using Founderizer.Windows.Marks;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Founderizer.Windows.Pages;

/// <summary>**Each value that the agent put in inline code is a chip with a copy icon** (the Mac's CardValueText; the
/// owner, 21 November 2026: "Sometimes tasks contain names, codes and other values that need to be copied... it would be
/// nice to identify those and add a small icon button next to them to copy them directly", and his "Yes, as drawn"): in
/// the reason, the task, the steps and the details of a request's card and of the request at hand in Needs you (the
/// library's <see cref="RequestBody"/> gives the values, <see cref="CardValues"/>), each value stands in inline code's
/// fill with the copy icon after it, muted, always shown. A press anywhere on the chip copies the value exactly, with the
/// hand under the pointer, and the icon is a check for 1.5 seconds, again from a second press; under the pointer the
/// chip is a little lighter and the icon in the words' colour. The keyboard reaches each chip's icon (Tab), and Enter or
/// Space copies; an assistive app reads "Copy &lt;value&gt;".
///
/// The words stay one text block, which wraps, selects and centres as before, and gain no character: the fill is the
/// text block's own highlighter of the value's characters, and the icon's room is the spacing after the value's last
/// character (<see cref="Room"/>), so a selection and a copy of the words hold them as written, and the icon never
/// stands at a line's start apart from its value. A value that wraps has its fill on each line and its icon on its last.
/// The icon and the presses stand over the words, at the places that the text block's layout gives
/// (<c>TextPointer.GetCharacterRect</c>), measured again when its size changes.</summary>
internal sealed class ValueChips : Grid
{
    /// <summary>The room after a value, in the words' size (the Mac's CardValueText.room): a gap, the icon and the
    /// chip's edge.</summary>
    public const double Room = 1.45;
    /// <summary>The icon's side, in the words' size.</summary>
    private const double Side = 0.9;
    /// <summary>The icon's check after a press.</summary>
    private static readonly TimeSpan Copied = TimeSpan.FromSeconds(1.5);
    /// <summary>Inline code's fill (<see cref="Blocks"/>' bubble grey), and a little lighter under the pointer (the Mac
    /// adds white at 6 %).</summary>
    public static readonly Brush Fill = Look.Brush(Look.Rgb(0x30, 0x30, 0x30));
    private static readonly Brush Over = Look.Brush(Look.Rgb(0x3C, 0x3C, 0x3C));
    private static readonly Brush Clear = Look.Brush(global::Windows.UI.Color.FromArgb(0, 0, 0, 0));

    /// <summary>One value's words in a text block: the value, the highlighter of its characters, and the runs that hold
    /// them (the last one holds its last character alone, with the room after it).</summary>
    internal sealed class Words(CardValue value, TextHighlighter fill)
    {
        public CardValue Value { get; } = value;
        public TextHighlighter Fill { get; } = fill;
        public List<Run> Runs { get; } = [];
    }

    private readonly TextBlock words;
    private readonly Canvas over = new();
    private readonly List<Chip> chips = [];

    /// <param name="words">The text block, filled by <see cref="Blocks.FillValues"/>.</param>
    /// <param name="found">Its values' words.</param>
    /// <param name="size">The size of the words around the values.</param>
    public ValueChips(TextBlock words, IReadOnlyList<Words> found, double size)
    {
        this.words = words;
        Children.Add(words);
        Children.Add(over);
        foreach (var one in found)
            if (one.Runs.Count > 0) chips.Add(new Chip(this, one, size));
        words.SizeChanged += (_, _) => Place();
        Loaded += (_, _) => Place();
    }

    /// <summary>Each chip's presses and icon at the places of its words now.</summary>
    private void Place()
    {
        foreach (var chip in chips) chip.Place();
    }

    /// <summary>The lines of a value's words in the text block, from its layout: on each line, from the leading edge of
    /// its first character there to the trailing edge of its last (which holds the room on the value's last line).</summary>
    private static List<Rect> Lines(IReadOnlyList<Run> runs)
    {
        var lines = new List<Rect>();
        foreach (var run in runs)
        {
            var text = run.Text;
            for (int i = 0; i < text.Length;)
            {
                int n = System.Globalization.StringInfo.GetNextTextElementLength(text, i);
                var lead = run.ContentStart.GetPositionAtOffset(i, LogicalDirection.Forward).GetCharacterRect(LogicalDirection.Forward);
                var trail = run.ContentStart.GetPositionAtOffset(i + n, LogicalDirection.Backward).GetCharacterRect(LogicalDirection.Backward);
                double left = lead.X;
                // a rectangle of the character itself, or a caret at its trailing edge on the same line
                double right = Math.Abs(trail.Y - lead.Y) > 1 ? lead.X + lead.Width : trail.Width > 0 ? trail.X + trail.Width : trail.X;
                if (lines.Count > 0 && Math.Abs(lines[^1].Y - lead.Y) <= 1)
                {
                    var line = lines[^1];
                    double l = Math.Min(line.X, left), r = Math.Max(line.X + line.Width, right);
                    lines[^1] = new Rect(l, line.Y, Math.Max(0, r - l), Math.Max(line.Height, lead.Height));
                }
                else lines.Add(new Rect(left, lead.Y, Math.Max(0, right - left), lead.Height));
                i += n;
            }
        }
        return lines;
    }

    /// <summary>One value: its fill, a press on each of its lines, and the icon at the end of its last line, which takes
    /// the keyboard.</summary>
    private sealed class Chip
    {
        private readonly ValueChips owner;
        private readonly Words value;
        private readonly double size, room;
        private readonly ChipKey key;
        private readonly List<ChipPart> parts = [];
        private Microsoft.UI.Dispatching.DispatcherQueueTimer? timer;
        private int inside;
        private bool copied;

        public Chip(ValueChips owner, Words value, double size)
        {
            this.owner = owner;
            this.value = value;
            this.size = size;
            room = Room * size;
            key = new ChipKey
            {
                Style = (Style)Application.Current.Resources["ChipKeyStyle"],
                Width = room,
                Padding = new Thickness(0),
                Visibility = Visibility.Collapsed,
            };
            AutomationProperties.SetName(key, "Copy " + value.Value.Text);
            key.Click += (_, _) => Copy();
            Hover(key);
            owner.over.Children.Add(key);
            Show();
        }

        /// <summary>The presses and the icon at the value's lines now; none before the text block has a layout.</summary>
        public void Place()
        {
            var lines = Lines(value.Runs);
            while (parts.Count < lines.Count)
            {
                var part = new ChipPart();
                part.Tapped += (_, e) => { e.Handled = true; Copy(); };
                Hover(part);
                AutomationProperties.SetAccessibilityView(part, AccessibilityView.Raw);
                // under the icon, which stays the last child
                owner.over.Children.Insert(owner.over.Children.IndexOf(key), part);
                parts.Add(part);
            }
            for (int i = 0; i < parts.Count; i++)
            {
                var part = parts[i];
                part.Visibility = i < lines.Count && lines[i].Width > 0 ? Visibility.Visible : Visibility.Collapsed;
                if (i >= lines.Count) continue;
                Canvas.SetLeft(part, lines[i].X);
                Canvas.SetTop(part, lines[i].Y);
                part.Width = lines[i].Width;
                part.Height = lines[i].Height;
            }
            if (lines.Count == 0 || lines[^1].Width < room)
            {
                key.Visibility = Visibility.Collapsed;
                return;
            }
            var last = lines[^1];
            Canvas.SetLeft(key, last.X + last.Width - room);
            Canvas.SetTop(key, last.Y);
            key.Height = last.Height;
            key.Visibility = Visibility.Visible;
        }

        /// <summary>The pointer over any part of the chip: a little lighter, and the icon in the words' colour.</summary>
        private void Hover(UIElement element)
        {
            element.PointerEntered += (_, _) => { inside++; Show(); };
            element.PointerExited += (_, _) => { inside = Math.Max(0, inside - 1); Show(); };
            element.PointerCanceled += (_, _) => { inside = Math.Max(0, inside - 1); Show(); };
            element.PointerCaptureLost += (_, _) => Show();
        }

        /// <summary>Copies the value's exact characters to the system's clipboard; the icon is a check for 1.5 s.</summary>
        private void Copy()
        {
            if (!ClipboardText.Copy(value.Value.Text)) return;
            copied = true;
            timer ??= MakeTimer();
            timer?.Stop();
            timer?.Start();
            Show();
        }

        private Microsoft.UI.Dispatching.DispatcherQueueTimer? MakeTimer()
        {
            var made = owner.DispatcherQueue?.CreateTimer();
            if (made is null) return null;
            made.Interval = Copied;
            made.IsRepeating = false;
            made.Tick += (_, _) => { copied = false; Show(); };
            return made;
        }

        private void Show()
        {
            bool lit = inside > 0;
            var fill = lit ? Over : Fill;
            if (!ReferenceEquals(value.Fill.Background, fill))
            {
                // a highlighter draws what it had when the text block took it: it goes and comes back with its new fill
                owner.words.TextHighlighters.Remove(value.Fill);
                value.Fill.Background = fill;
                owner.words.TextHighlighters.Add(value.Fill);
            }
            var icon = Icons.Of(copied ? Icons.Check : Icons.Copy16, lit ? Look.Text : Look.Muted, Math.Round(size * Side));
            icon.HorizontalAlignment = HorizontalAlignment.Center;
            icon.VerticalAlignment = VerticalAlignment.Center;
            key.Content = icon;
        }
    }

    /// <summary>A press on one line of a chip: clear, so that the pointer finds it, with the hand.</summary>
    private sealed class ChipPart : Grid
    {
        public ChipPart()
        {
            Background = Clear;
            ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
        }
    }

    /// <summary>The icon: a button with no fill of its own (the chip lightens), the hand, the system's focus frame.</summary>
    private sealed class ChipKey : Button
    {
        public ChipKey() => ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
    }
}
