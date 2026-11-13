using System;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Marks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Page = Founderizer.Core.Page;

namespace Founderizer.Windows.Pages;

/// <summary>The parts of a page of Settings, as pictures 5 and 6 draw them (the iPhone's grouped form, the Windows way): a
/// form of 680 under the page's title, a group's heading, a card of rows, a muted line under a card.</summary>
internal static class Form
{
    public static readonly Color Green = Look.Rgb(0x30, 0xD1, 0x58);
    public static readonly Color Red = Look.Rgb(0xFF, 0x45, 0x3A);

    /// <summary>The page: its title, and the form under it, at the left of the content area.</summary>
    public static (Grid Page, StackPanel Form) Page(string title)
    {
        var form = new StackPanel { Width = 680, HorizontalAlignment = HorizontalAlignment.Left };
        var words = Look.PageTitle(title);
        words.Margin = new Thickness(0, 28 + Look.TitleNudge, 0, 22 - Look.TitleNudge);
        form.Children.Add(words);
        var page = new Grid
        {
            Padding = new Thickness(24, 0, 24, 0),
            Children =
            {
                new ScrollViewer
                {
                    Content = form,
                    HorizontalScrollMode = ScrollMode.Disabled,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    IsTabStop = false,
                },
            },
        };
        return (page, form);
    }

    /// <summary>A group's heading: semibold, 2 in from the card's edge, 10 above it.</summary>
    public static TextBlock Heading(string words)
    {
        var block = Look.Words(words, semibold: true, wrap: false);
        block.Margin = new Thickness(2, 0, 0, 10);
        return block;
    }

    /// <summary>The muted line under a card (a group's footer).</summary>
    public static TextBlock Footer(string words)
    {
        var block = Look.Words(words, 12, 16, Look.Muted);
        block.Margin = new Thickness(2, 8, 2, 0);
        return block;
    }

    /// <summary>A card with its rows one under the other, a hairline between two rows.</summary>
    public static Border Card(StackPanel rows) => new()
    {
        Background = Look.SurfaceBrush,
        BorderBrush = Look.CardEdge,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(8),
        Child = rows,
    };

    /// <summary>A row of a card: at least 44 high, 16 in from each side.</summary>
    public static Grid Row(UIElement left, UIElement? right = null)
    {
        var row = new Grid { MinHeight = 44, Padding = new Thickness(16, 0, 16, 0) };
        if (left is FrameworkElement l) l.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(left);
        if (right is FrameworkElement r)
        {
            r.HorizontalAlignment = HorizontalAlignment.Right;
            r.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(r);
        }
        return row;
    }

    /// <summary>The hairline between two rows of a card.</summary>
    public static Border Rule() => new() { Height = 1, Background = Look.Line };

    /// <summary>A row that is pressed whole (Add this PC, Forget the key).</summary>
    public static Button Pressable(Grid row)
    {
        return new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            CornerRadius = new CornerRadius(0),
            Content = row,
        };
    }

    /// <summary>A button as Windows draws it (picture 6's Connect): 32 high, Windows' fill and edge.</summary>
    public static Button Plain(string words)
    {
        var button = new Button
        {
            Style = (Style)Application.Current.Resources["QuietButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Content = new Border
            {
                Height = 32,
                Padding = new Thickness(11, 0, 11, 0),
                CornerRadius = new CornerRadius(4),
                Background = Look.Brush(Look.White(0.06)),
                BorderBrush = Look.FieldEdge(32, Look.White(0.08), Look.White(0.04)),
                BorderThickness = new Thickness(1),
                Child = new TextBlock
                {
                    Text = words,
                    FontFamily = Look.TextFont,
                    FontSize = 14,
                    Foreground = Look.Text,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, words);
        return button;
    }

    /// <summary>A text box of a page: Windows' fill and edge on the card, with its lighter bottom line.</summary>
    public static FieldLook TextBox(Brush? placeholder = null, bool centred = false, bool semibold = false, int spacing = 0,
                                    double? nudge = null) =>
        new(Look.White(0.06), placeholder, centred, semibold, spacing, nudge);
}

/// <summary>Add this PC, as pictures 5 and 8 draw it (the iPhone's EnrollPage, with "PC"): the title, "The code", the
/// code's field in the middle at 26, the line under it, and under that in orange what the hub answered to a code that
/// did not work. A whole code sends itself, once (EnrollForm): no button.</summary>
internal sealed class AddThisPcPage : IPageView
{
    private readonly IFleetSource source;
    private readonly Grid page;
    private readonly Field code;
    private readonly TextBlock problem = Look.Words("", 12, 16, Look.Orange);
    private EnrollForm form = new();

    public AddThisPcPage(IFleetSource source)
    {
        this.source = source;
        (page, var stack) = Form.Page(EnrollForm.Title);
        stack.Children.Add(Form.Heading(EnrollForm.Heading));
        code = new Field(56, 26, 11, Form.TextBox(Look.Brush(Look.White(0.4)), centred: true, semibold: true, spacing: 19, nudge: 9));
        code.Box.CharacterCasing = CharacterCasing.Upper;
        code.Box.MaxLength = 16;
        code.Show(EnrollForm.Placeholder, showsPlus: false, canSend: false);
        code.Typed += Typed;
        stack.Children.Add(Form.Card(new StackPanel { Padding = new Thickness(16, 12, 16, 12), Children = { code } }));
        stack.Children.Add(Form.Footer(EnrollForm.Footer));
        problem.Margin = new Thickness(2, 6, 2, 0);
        problem.Visibility = Visibility.Collapsed;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(problem, "CodeProblem");
        stack.Children.Add(problem);
    }

    public FrameworkElement View => page;

    public void Show(StoreState state, DateTimeOffset now, bool reduceMotion) { }

    private async void Typed(string text)
    {
        var (next, send) = form.Typed(text);
        form = next;
        if (!send || form.Sent is not { } whole) return;
        problem.Visibility = Visibility.Collapsed;
        var refused = await source.EnrollAsync(whole);
        Readings.Note("enroll: " + (refused ?? "the PC took its key"));
        form = form.Answered(refused);
        if (refused is null) code.Clear();
        problem.Text = form.Problem ?? "";
        problem.Visibility = form.Problem is null ? Visibility.Collapsed : Visibility.Visible;
    }
}

/// <summary>Settings, as picture 6 draws it (the iPhone's Settings page, with "PC"): the hub's address and Connect; This
/// PC with the device key, this PC's address as the hub knows it, Add this PC and Forget the key; and Founderizer's
/// credit, its handle the one link. Pictures 9b and 9c add the orange line of an address that cannot be a hub's under
/// the Hub card, and Last reading in orange while the reading is not current.</summary>
internal sealed class SettingsPage : IPageView
{
    private readonly IFleetSource source;
    private readonly Action<Page> go;
    private readonly Action forgot;
    private readonly Grid page;
    private readonly Field address;
    private readonly TextBlock addressError = Look.Words("", 12, 16, Look.Orange);
    private readonly Border lastBlock = new() { Height = 22 };
    private readonly Border lastCard;
    private readonly TextBlock lastAge = Look.Words("", brush: Look.Orange, wrap: false);
    private readonly TextBlock keyWords = Look.Words("", wrap: false);
    private readonly Grid addressRow;
    private readonly TextBlock addressDetail = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly TextBlock addressAge = Look.Words("", brush: Look.Muted, wrap: false);
    private readonly Border addressRule = Form.Rule();
    private readonly Button forget;
    private readonly Border forgetRule = Form.Rule();
    private readonly TextBlock credit = Look.Words("", 12, 16, Look.Muted, wrap: false);
    private readonly Run creditWords = new();
    private readonly Hyperlink creditLink = new();
    private string loadedText = "";
    private bool edited;

    public SettingsPage(IFleetSource source, Action<Page> go, Action forgot)
    {
        this.source = source;
        this.go = go;
        this.forgot = forgot;
        (page, var stack) = Form.Page("Settings");

        stack.Children.Add(Form.Heading("Hub"));
        address = new Field(32, 14, 11, Form.TextBox(nudge: 0)) { EnterAlwaysSends = true };
        address.Sent += Connect;
        address.Typed += text => { if (text != loadedText) edited = true; };
        var connect = Form.Plain("Connect");
        connect.Click += (_, _) => Connect();
        // A row of at least 44 inside its padding of 12, as the picture's form has it: 68 high, its parts in the middle.
        var hubRow = new Grid { Padding = new Thickness(16, 12, 16, 12), MinHeight = 68, ColumnSpacing = 12 };
        address.VerticalAlignment = VerticalAlignment.Center;
        hubRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        hubRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        hubRow.Children.Add(address);
        Grid.SetColumn(connect, 1);
        hubRow.Children.Add(connect);
        stack.Children.Add(Form.Card(new StackPanel { Children = { hubRow } }));
        addressError.Margin = new Thickness(2, 8, 2, 0);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(addressError, "AddressError");
        stack.Children.Add(addressError);
        stack.Children.Add(lastBlock);
        lastCard = Form.Card(new StackPanel { Children = { Form.Row(Look.Words(new SettingsModel().LastReadingLabel, wrap: false), lastAge) } });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(lastAge, "LastReading");
        stack.Children.Add(lastCard);

        stack.Children.Add(new Border { Height = 22 });
        stack.Children.Add(Form.Heading("This PC"));
        var rows = new StackPanel();
        rows.Children.Add(Form.Row(Look.Words("Device key", wrap: false), keyWords));
        rows.Children.Add(addressRule);
        var two = new StackPanel { Padding = new Thickness(0, 12, 0, 12), Children = { Look.Words("This PC's address", wrap: false), addressDetail } };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(addressDetail, "DeviceLine");
        addressRow = Form.Row(two, addressAge);
        rows.Children.Add(addressRow);
        rows.Children.Add(Form.Rule());
        var chevron = Icons.Of(new Icon(16, "M5.65 3.15a.5.5 0 0 0 0 .7L9.79 8l-4.14 4.15a.5.5 0 0 0 .7.7l4.5-4.5a.5.5 0 0 0 0-.7l-4.5-4.5a.5.5 0 0 0-.7 0"), Look.Muted);
        var add = Form.Pressable(Form.Row(Look.Words("Add this PC", wrap: false), chevron));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(add, "Add this PC");
        add.Click += (_, _) => go(Page.AddThisPc);
        rows.Children.Add(add);
        rows.Children.Add(forgetRule);
        forget = Form.Pressable(Form.Row(Look.Words("Forget the key", brush: Look.Brush(Form.Red), wrap: false)));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(forget, "Forget the key");
        forget.Click += (_, _) => { if (source.ForgetKey() is null) forgot(); };
        rows.Children.Add(forget);
        stack.Children.Add(Form.Card(rows));

        credit.HorizontalAlignment = HorizontalAlignment.Center;
        credit.Margin = new Thickness(2, 22, 2, 0);
        creditLink.Foreground = Look.Link;
        creditLink.UnderlineStyle = UnderlineStyle.None;
        credit.Inlines.Add(creditWords);
        credit.Inlines.Add(creditLink);
        stack.Children.Add(credit);
        _ = source.ReadDeviceAsync();
    }

    public FrameworkElement View => page;

    public void Show(StoreState state, DateTimeOffset now, bool reduceMotion)
    {
        // The field shows the hub the PC has, found or typed, until he types in it; then it keeps what he types.
        var hub = state.Hub?.ToString().TrimEnd('/') ?? "";
        if (!edited && hub != loadedText)
        {
            loadedText = hub;
            address.Load(hub);
        }
        var model = Screens.Settings(state, address.Box.Text, now, ScreenContext.Local);
        address.Show(model.HubPlaceholder, showsPlus: false, canSend: false);
        addressError.Text = model.AddressError ?? "";
        addressError.Visibility = model.AddressError is null ? Visibility.Collapsed : Visibility.Visible;
        lastAge.Text = model.LastReading ?? "";
        lastBlock.Visibility = lastCard.Visibility = model.LastReading is null ? Visibility.Collapsed : Visibility.Visible;
        keyWords.Text = model.KeyWords;
        keyWords.Foreground = model.KeyTone switch
        {
            StateTone.Online => Look.Brush(Form.Green),
            StateTone.Warning => Look.Orange,
            _ => Look.Muted,
        };
        bool hasAddress = model.Address is not null;
        addressRow.Visibility = addressRule.Visibility = hasAddress ? Visibility.Visible : Visibility.Collapsed;
        if (model.Address is { } line)
        {
            addressDetail.Text = line.Detail;
            addressAge.Text = line.Value;
        }
        forget.Visibility = forgetRule.Visibility = model.ShowsForget ? Visibility.Visible : Visibility.Collapsed;
        if (model.Credit is { } c)
        {
            creditWords.Text = c.Words;
            if (creditLink.Inlines.Count == 0) creditLink.Inlines.Add(new Run { Text = c.Handle });
            creditLink.NavigateUri = c.Profile;
        }
    }

    private async void Connect()
    {
        var refused = await source.ConnectAsync(address.Box.Text);
        Readings.Note("connect: " + (refused ?? "the store took the address"));
    }
}
