using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**"A VPS for your fleet"** (set 8, picture 9; the Mac's <c>cloudStep</c> and <c>CloudCards</c>): the first
/// run's quiet mark, the title, and three cards in a row, 14 apart, in a step of 540: each provider's real logo on its
/// tile of 34 with its name and its one line under it, and Other VPS, any server by SSH, last. A press on a card is the
/// way on.</summary>
internal sealed class CloudPage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.CardsWidth) { Mark = SetupParts.QuietMark() };
    private readonly Grid cards = new() { ColumnSpacing = 14, RowSpacing = 14 };
    private bool drawn;

    public CloudPage(StepHost host)
    {
        this.host = host;
        for (int i = 0; i < 3; i++) cards.ColumnDefinitions.Add(new ColumnDefinition());
        column.Controls.Children.Add(cards);
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen screen)
    {
        column.Show(screen.Title, screen.Waits, screen.Detail, host.ReduceMotion());
        if (drawn) return;
        drawn = true;
        int at = 0;
        foreach (var control in screen.Controls)
        {
            if (control.Kind != SetupControlKind.Card) continue;
            var provider = CloudProviders.FromRaw(control.Id["first-run-cloud-".Length..]);
            FrameworkElement mark = provider is { } p ? SetupParts.CloudTile(p, 34) : SetupParts.ServerCardTile();
            mark.HorizontalAlignment = HorizontalAlignment.Left;
            var title = Look.Words(control.Words, StepLook.Text, 20, semibold: true);
            var line = Look.Words(control.Line ?? "", StepLook.Text, 20, Look.Muted);
            mark.Margin = new Thickness(0, 0, 0, 14);
            var content = new StackPanel { Padding = new Thickness(18), Children = { mark, title, line } };
            var card = StepControls.Card(content, control.Words, control.Id, minHeight: 104);
            card.VerticalAlignment = VerticalAlignment.Stretch;
            if (provider is { } chosen) card.Click += (_, _) => host.Store.ChooseProvider(chosen);
            else card.Click += (_, _) => host.Store.ChooseOtherVps();
            if (cards.RowDefinitions.Count <= at / 3) cards.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(card, at / 3);
            Grid.SetColumn(card, at % 3);
            cards.Children.Add(card);
            at++;
        }
    }
}
