using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**"&lt;Name&gt;'s AI provider"** (set 8, picture 4; the Mac's <c>ManagerAIPage</c>): the manager's mark at 48,
/// the title and its line, and two cards, Codex first, each with the provider's own logo at 28, its name, and the check
/// mark on the card chosen the last time on this PC (none before the first choice). A press on a card is the way on.</summary>
internal sealed class ProviderPage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.Width);
    private readonly Grid cards = new() { ColumnSpacing = 14 };
    private string? shownFor;
    private string? markFor;

    public ProviderPage(StepHost host)
    {
        this.host = host;
        column.Controls.Children.Add(cards);
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen screen)
    {
        column.Show(screen.Title, screen.Waits, screen.Detail, host.ReduceMotion());
        var name = ManagerName.AgentName(state.ManagerName) ?? ManagerName.Fallback;
        if (name != markFor)
        {
            markFor = name;
            column.Mark = StepLook.AgentMark(name, StepLook.Mark);
        }
        var key = string.Join("|", screen.Controls.Select(c => c.Id + c.Marked));
        if (key == shownFor) return;
        shownFor = key;
        cards.Children.Clear();
        cards.ColumnDefinitions.Clear();
        int at = 0;
        foreach (var control in screen.Controls.Where(c => c.Kind == SetupControlKind.Card))
        {
            var provider = control.Id["first-run-ai-".Length..];
            cards.ColumnDefinitions.Add(new ColumnDefinition());
            var card = StepControls.Card(StepControls.CardLine(Logo(provider), control.Words, control.Marked), control.Words, control.Id);
            card.Click += (_, _) => host.Store.ChooseAi(provider);
            Grid.SetColumn(card, at++);
            cards.Children.Add(card);
        }
    }

    private static readonly Dictionary<string, ImageSource?> Logos = new();

    /// <summary>The provider's own logo at 28 with a corner of 7 (Assets/*.png, the Mac's own bytes); at 48 with a corner of
    /// 12 over a page of the manager's setup (set 8's <c>.plogo</c>, the Mac's <c>ProviderIcon</c> at a step's mark).</summary>
    internal static FrameworkElement Logo(string provider, double side = 28, double corner = 7)
    {
        var key = provider + "@" + side.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (!Logos.TryGetValue(key, out var image))
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream($"Founderizer.Windows.Assets.{provider}.png");
            if (stream is not null)
            {
                var memory = new MemoryStream();
                stream.CopyTo(memory);
                memory.Position = 0;
                // The screen's own pixels at the pictures' scale of 2.
                var bitmap = new BitmapImage { DecodePixelWidth = (int)(side * 2) };
                bitmap.SetSource(memory.AsRandomAccessStream());
                image = bitmap;
            }
            Logos[key] = image;
        }
        return new Border
        {
            Width = side,
            Height = side,
            CornerRadius = new CornerRadius(corner),
            Background = image is null ? null : new ImageBrush { ImageSource = image, Stretch = Stretch.UniformToFill },
        };
    }
}
