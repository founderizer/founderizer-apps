using System;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using Windows.UI;

namespace Founderizer.Windows.Pages;

/// <summary>How a field looks: the composer's fill (a chat, an answer, guidance), or a text box of a page (Settings'
/// address, the code of Add this PC) with its own fill, its placeholder's colour, its words in the middle and semibold.
/// <see cref="Nudge"/> moves the words down, where WinUI's box puts them higher than the pictures.</summary>
internal sealed record FieldLook(Color Fill, Brush? Placeholder = null, bool Centred = false, bool SemiBold = false,
                                 int Spacing = 0, double? Nudge = null)
{
    public static readonly FieldLook Composer = new(Look.ComposerFill);
}

/// <summary>A field he writes in, as the pictures draw the composer, the answer box and the guidance box: the composer's
/// fill, Windows' edge with its lighter bottom line, a corner of 4; the plus of the files at its left where the model
/// offers it, and the Mac's round Send at its right only while there is something to send (SendSlot, SendMark). Enter
/// sends. The plus does nothing yet: the chip of a picked file waits for its picture.</summary>
internal sealed class Field : Grid
{
    private readonly Border frame;
    private readonly TextBox box;
    private readonly Button plus;
    private readonly Button send;
    private readonly Ellipse sendFill;
    private readonly Path sendArrow;
    private bool showing;

    /// <summary>His words changed.</summary>
    public event Action<string>? Typed;

    /// <summary>Enter or Send: the words go.</summary>
    public event Action? Sent;

    public Field(double height, double fontSize, double textLeft, FieldLook? look = null)
    {
        look ??= FieldLook.Composer;
        Height = height;
        frame = new Border
        {
            Background = Look.Brush(look.Fill),
            BorderBrush = Look.FieldEdge(height, Look.White(0.45)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
        };

        plus = new Button
        {
            Width = 28,
            Height = 28,
            Margin = new Thickness(5, 0, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            Content = Center(Icons.Of(Icons.Add, Look.Muted)),
            Visibility = Visibility.Collapsed,
            IsTabStop = false,
        };

        box = new TextBox
        {
            FontSize = fontSize,
            FontFamily = Look.TextFont,
            Padding = new Thickness(0),
            MinHeight = 0,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)),
            VerticalAlignment = VerticalAlignment.Center,
            // The pictures centre the words' line in the field; WinUI's box draws them 2 pixels higher (2.5 at 15).
            Margin = new Thickness(textLeft, look.Nudge ?? (fontSize >= 15 ? 5 : 4), look.Centred ? textLeft : 40, 0),
            TextAlignment = look.Centred ? TextAlignment.Center : TextAlignment.Left,
            FontWeight = look.SemiBold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
            CharacterSpacing = look.Spacing,
            AcceptsReturn = false,
            TextWrapping = TextWrapping.NoWrap,
        };
        // At rest, under the pointer and with the caret: the same fill and no line of its own (the field's edge is the
        // Border's), the text and the placeholder in the pictures' colours.
        foreach (var state in new[] { "", "PointerOver", "Focused", "Disabled" })
        {
            box.Resources["TextControlBackground" + state] = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            box.Resources["TextControlBorderBrush" + state] = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            box.Resources["TextControlForeground" + state] = Look.Text;
            box.Resources["TextControlPlaceholderForeground" + state] = look.Placeholder ?? Look.Muted;
        }
        box.Resources["TextControlBorderThemeThickness"] = new Thickness(0);
        box.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        box.TextChanged += (_, _) => Typed?.Invoke(box.Text);
        box.KeyDown += Key;

        sendFill = new Ellipse { Width = 28, Height = 28 };
        sendArrow = new Path
        {
            Data = (Geometry)Microsoft.UI.Xaml.Markup.XamlBindingHelper.ConvertValue(typeof(Geometry), "M8 12.5V3.5M4.25 7.25 8 3.5 11.75 7.25"),
            StrokeThickness = 1.7,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            Width = 16,
            Height = 16,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        send = new Button
        {
            Width = 28,
            Height = 28,
            Margin = new Thickness(0, 0, 5, 0),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            CornerRadius = new CornerRadius(14),
            Content = new Grid { Children = { sendFill, sendArrow } },
            Visibility = Visibility.Collapsed,
        };
        send.Click += (_, _) => Sent?.Invoke();
        Tint(Look.Accent, Color.FromArgb(255, 255, 255, 255));

        frame.Child = new Grid { Children = { box, plus, send } };
        Children.Add(frame);
    }

    public TextBox Box => box;

    /// <summary>Enter sends even with no Send shown (Settings' address: Enter is Connect).</summary>
    public bool EnterAlwaysSends { get; set; }

    /// <summary>The model's placeholder, whether the plus shows, and whether Send shows.</summary>
    public void Show(string placeholder, bool showsPlus, bool canSend)
    {
        if (box.PlaceholderText != placeholder)
        {
            box.PlaceholderText = placeholder;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, placeholder);
        }
        plus.Visibility = showsPlus ? Visibility.Visible : Visibility.Collapsed;
        showing = canSend;
        send.Visibility = canSend ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>The words of a saved draft, when the page opens; never while he types.</summary>
    public void Load(string draft)
    {
        if (box.Text != draft) box.Text = draft;
    }

    /// <summary>The field empties after a send, in the frame he pressed (the Mac's SendSlot).</summary>
    public void Clear()
    {
        box.Text = "";
        send.Visibility = Visibility.Collapsed;
        showing = false;
    }

    /// <summary>Send's colour: the agent's tint in a chat, the violet of what he presses elsewhere.</summary>
    public void Tint(Color fill, Color ink)
    {
        sendFill.Fill = new SolidColorBrush(fill);
        sendArrow.Stroke = new SolidColorBrush(ink);
    }

    private void Key(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        if (showing || EnterAlwaysSends) Sent?.Invoke();
    }

    private static Grid Center(FrameworkElement child)
    {
        child.HorizontalAlignment = HorizontalAlignment.Center;
        child.VerticalAlignment = VerticalAlignment.Center;
        return new Grid { Children = { child } };
    }
}
