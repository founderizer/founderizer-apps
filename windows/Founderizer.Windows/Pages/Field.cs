using System;
using System.Collections.Generic;
using Founderizer.Core;
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
/// sends. The plus picks files; the files that he added stand over the line, in the same frame (picture 4 of the second
/// set), and the field grows by their row.</summary>
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

    /// <summary>The plus: he wants to add files.</summary>
    public event Action? PlusPressed;

    /// <summary>"Keep it" of the hold of a key over the line (<see cref="ShowHold"/>).</summary>
    public event Action? KeepPressed;

    /// <summary>Whether the words of the field wait for his choice now (the store's <see cref="StoreState.HoldsKey"/>):
    /// then Enter and Send do nothing, also in the moment before the next draw shows the hold. Null: no hold.</summary>
    public Func<string, bool>? HoldsKey { get; set; }

    // 12 over the chips, under the field's edge (picture 4: 13 from the edge's top to the chip).
    private readonly StackPanel chips = new() { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(6, 12, 8, 0), Visibility = Visibility.Collapsed };
    /// <summary>The hold of a key, over the line inside the field's edge, as the Mac's stands inside its capsule.</summary>
    private readonly ContentControl hold = new()
    {
        IsTabStop = false,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
        Margin = new Thickness(6, 6, 6, 0),
        Visibility = Visibility.Collapsed,
    };
    private KeyHoldView? holdView;
    private readonly double lineHeight;

    public Field(double height, double fontSize, double textLeft, FieldLook? look = null)
    {
        look ??= FieldLook.Composer;
        lineHeight = height;
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
        send.Click += (_, _) => Send();
        Tint(Look.Accent, Color.FromArgb(255, 255, 255, 255));

        plus.Click += (_, _) => PlusPressed?.Invoke();
        var line = new Grid { Height = height - 2, Children = { box, plus, send } };
        var rows = new Grid();
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rows.Children.Add(chips);
        Grid.SetRow(hold, 1);
        rows.Children.Add(hold);
        Grid.SetRow(line, 2);
        rows.Children.Add(line);
        frame.Child = rows;
        // The edge's lighter bottom line stays at the foot while the field grows by its files.
        frame.SizeChanged += (_, e) => frame.BorderBrush = Look.FieldEdge(Math.Max(e.NewSize.Height, 2), Look.White(0.45));
        Children.Add(frame);
    }

    /// <summary>The files that he added, over the line (none: the field is one line high again).</summary>
    public void ShowChips(IReadOnlyList<UIElement> files)
    {
        chips.Children.Clear();
        foreach (var file in files) chips.Children.Add(file);
        chips.Visibility = files.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>**The hold of words that look like a key** over the line (the model's <see cref="KeyHoldModel"/>, the
    /// Mac's KeyHoldBanner): its mark, its two lines and "Keep it"; null takes it away. The field grows by its height.</summary>
    public void ShowHold(KeyHoldModel? model)
    {
        if (model is null)
        {
            hold.Visibility = Visibility.Collapsed;
            return;
        }
        if (holdView is null)
        {
            holdView = new KeyHoldView();
            holdView.Kept += () => KeepPressed?.Invoke();
            hold.Content = holdView;
        }
        holdView.Show(model);
        hold.Visibility = Visibility.Visible;
    }

    public double LineHeight => lineHeight;

    /// <summary>The plus's and Send's words under the pointer (the models' hovers), also their names for assistive apps.</summary>
    public void Hovers(string? plusWords, string? sendWords)
    {
        ToolTipService.SetToolTip(plus, plusWords);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(plus, plusWords ?? "");
        ToolTipService.SetToolTip(send, sendWords);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(send, sendWords ?? "");
    }

    public TextBox Box => box;

    /// <summary>The round Send, for a watch of its pointer presses (a request's second click: AnswerParts).</summary>
    public Button SendButton => send;

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
        if (showing || EnterAlwaysSends) Send();
    }

    /// <summary>Enter or Send, unless the words wait for his choice (<see cref="HoldsKey"/>): they stay in the field.</summary>
    private void Send()
    {
        if (HoldsKey?.Invoke(box.Text) == true) return;
        Sent?.Invoke();
    }

    private static Grid Center(FrameworkElement child)
    {
        child.HorizontalAlignment = HorizontalAlignment.Center;
        child.VerticalAlignment = VerticalAlignment.Center;
        return new Grid { Children = { child } };
    }
}

/// <summary>**The hold of words that look like a key** (the Mac's KeyHoldBanner, in Windows' look): orange at 10 % with an
/// orange edge at 35 %, corners of 4, 10 inside; the key's mark in orange, the hold's words in the text colour and the line
/// under them muted, 12 on 16, and "Keep it", Windows' button, at the right. Longer words take a second line, and the
/// hold grows. The Mac's second button, "Save it as a secret", is not here: this app has no form of a secret yet
/// (<see cref="KeyHoldModel"/>).</summary>
internal sealed class KeyHoldView : Grid
{
    private readonly TextBlock words = Look.Words("", 12, 16, semibold: true);
    private readonly TextBlock line = Look.Words("", 12, 16, Look.Muted);
    private readonly Button keep;
    private readonly TextBlock keepWords;

    /// <summary>"Keep it".</summary>
    public event Action? Kept;

    public KeyHoldView()
    {
        Background = Look.Brush(Color.FromArgb(26, 0xFF, 0x9F, 0x0A));
        BorderBrush = Look.Brush(Color.FromArgb(89, 0xFF, 0x9F, 0x0A));
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(4);
        Padding = new Thickness(10, 8, 8, 8);
        // the Mac's key.horizontal: Segoe Fluent Icons' key, which Windows has
        var mark = new FontIcon { Glyph = "\uE8D7", FontSize = 14, Foreground = Look.Orange, VerticalAlignment = VerticalAlignment.Center };
        var lines = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Children = { words, line } };
        keep = Buttons.Plain("");
        keepWords = (TextBlock)((Border)keep.Content).Child;
        keep.Click += (_, _) => Kept?.Invoke();
        ColumnSpacing = 10;
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Children.Add(mark);
        SetColumn(lines, 1);
        Children.Add(lines);
        SetColumn(keep, 2);
        Children.Add(keep);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(this, "KeyHold");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(keep, "KeyHoldKeep");
        // an assistive app says the hold when it comes
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetLiveSetting(this, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
    }

    public void Show(KeyHoldModel model)
    {
        words.Text = model.Words;
        line.Text = model.Line;
        keepWords.Text = model.KeepWords;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, model.Spoken);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(keep, model.KeepWords);
    }
}
