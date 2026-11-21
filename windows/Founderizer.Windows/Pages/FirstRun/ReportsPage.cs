using System.Linq;
using Founderizer.Setup.FirstRun;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**"Help improve Founderizer"** (set 8, picture 2; the Mac's <c>FirstRunReportsPage</c>): the ladybug on its
/// tile, the title and its line, two cards of one weight in a row of 700 (the owner's "Widen, one line"), each 343 with
/// its symbol, its words and the check mark on the one chosen last on this PC (none before the first answer), and one
/// muted line with the privacy page as its link. A press on a card is the way on.</summary>
internal sealed class ReportsPage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.ReportsWidth);
    private readonly Grid cards = new() { ColumnSpacing = 14 };
    private readonly TextBlock later = StepLook.Words("", Look.Muted);
    private (bool Send, bool None)? marked;
    /// <summary>The line under the cards is drawn (a text block made with no words holds an empty run already).</summary>
    private bool lineDrawn;

    public ReportsPage(StepHost host)
    {
        this.host = host;
        column.Mark = StepLook.Tile(StepLook.Glyph(StepLook.Bug, 21));
        cards.ColumnDefinitions.Add(new ColumnDefinition());
        cards.ColumnDefinitions.Add(new ColumnDefinition());
        column.Controls.Children.Add(cards);
        column.Controls.Children.Add(later);
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen screen)
    {
        column.Show(screen.Title, screen.Waits, screen.Detail, host.ReduceMotion());
        var send = screen.Controls.First(c => c.Id == "first-run-reports-send");
        var none = screen.Controls.First(c => c.Id == "first-run-reports-none");
        if (marked != (send.Marked, none.Marked))
        {
            marked = (send.Marked, none.Marked);
            cards.Children.Clear();
            var left = Card(send, StepLook.Send, true);
            var right = Card(none, StepLook.Cancel, false);
            Grid.SetColumn(right, 1);
            cards.Children.Add(left);
            cards.Children.Add(right);
        }
        if (!lineDrawn && screen.Controls.FirstOrDefault(c => c.Id == "first-run-reports-later") is { } line)
        {
            lineDrawn = true;
            later.Inlines.Clear();
            // "You can change this later in Settings › Help. Privacy ↗": the link in the violet of a link, underlined.
            later.Inlines.Add(new Run { Text = line.Words + " " });
            var privacy = new Hyperlink { NavigateUri = SetupScreens.PrivacyPage, Foreground = Look.Link };
            privacy.Inlines.Add(new Run { Text = line.Line ?? SetupScreens.Privacy });
            later.Inlines.Add(privacy);
            later.Inlines.Add(new Run { Text = " ↗", Foreground = Look.Link });
        }
    }

    private Button Card(SetupControl control, string symbol, bool send)
    {
        var card = StepControls.Card(StepControls.CardLine(StepLook.Glyph(symbol, 20), control.Words, control.Marked), control.Words, control.Id);
        card.Click += (_, _) => host.Store.ChooseReports(send);
        return card;
    }
}
