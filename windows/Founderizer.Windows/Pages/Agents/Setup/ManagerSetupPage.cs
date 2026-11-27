using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using Founderizer.Owner.Reads;
using Founderizer.Setup.Agents;
using Founderizer.Setup.FirstRun;
using Founderizer.Windows.Pages.FirstRun;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Founderizer.Windows.Pages.Agents.Setup;

/// <summary>**The setup of the manager of a new fleet, filling the window** (windows-app-plan-v2.md, piece U3; set 8,
/// pictures 18 to 20; the Mac's <c>AgentSetupWizard</c> for the manager's first server, which the Mac draws alone, as the
/// first run, <c>FleetStore.fillsWindow</c>): the steps of the manager's setup on Back's line (Manager · AI provider ·
/// Servers · Sign in), Back only on the provider's page of a manager whose name's page came first (to that page; Esc is
/// Back), and one centred step under them: its mark, its title (moving while the server works) and
/// its one way on. Every word and rule is the library's (<see cref="ManagerSetup"/>, <see cref="ManagerSetupScreens"/>).
///
/// <list type="bullet">
/// <item>**"Name your manager"** of a hub whose first run did not ask (piece U3b): <see cref="ManagerNamePage"/>, in the
/// first run's look; its Continue renames the manager on the hub.</item>
/// <item>**The provider's page**: the manager's mark, "&lt;Manager&gt;'s AI provider" with its line, the cards; under them
/// in orange why the setup stopped, over Try again for a failed install.</item>
/// <item>**The install** (picture 18): the provider's own logo at 48, the moving "Installing &lt;provider&gt; on
/// &lt;server&gt;", and the job's steps as a bar of 240 (the Mac's <c>SetupStepsBar</c>): a done part in the words'
/// faded colour, the part that runs green and breathing (still with Windows' animation effects off), the rest the track.</item>
/// <item>**The sign-in** (pictures 19, 20): the logo, "Sign in to &lt;provider&gt;", the provider's steps; Claude Code's
/// field, which sends a pasted code by itself; Codex's code in its box with Copy. The first step's link opens the model's
/// link (only the provider's own hosts) in the default browser, and puts Codex's code on the clipboard; after the owner's
/// own press asked for the sign-in, it opens by itself once (the Mac's <c>opensByItself</c>).</item>
/// <item>**"Setting up &lt;Manager&gt;"**: the manager's mark at 96 (the Mac's <c>GlyphSize.making</c>, still: the
/// Mac's motion of its making is not ported yet), the moving title, until the manager runs and its chat takes the page.</item>
/// </list>
/// For its first second the page draws nothing but the frame, then "Setting up" until its first read (the Mac's
/// <c>Held</c>). A page of wave B or C (<see cref="ManagerSetupScreen.Drawn"/> false) draws its frame alone.</summary>
internal sealed class ManagerSetupPage : Grid
{
    private readonly ManagerSetup setup;
    private readonly DispatcherQueue queue;
    private readonly Action<string> named;
    private readonly Action changed;
    private readonly StepProgress progress = new();
    private readonly ScrollViewer scroll;
    private readonly Grid room = new();
    private readonly StepColumn column = new(StepLook.Width);
    private readonly TextBlock warning = StepControls.Warning("");
    private readonly Button back;
    private readonly UISettings settings = new();
    private CancellationTokenSource? run;
    private DispatcherQueueTimer? holdTimer;
    private bool held, open;
    private string? drawn, markOf, namedAs;
    private PasteField? paste;
    private ManagerNamePage? namePage;
    private Action? onwards;
    private StepsBar? bar;
    private readonly List<Button> cardButtons = [];

    public ManagerSetup Setup => setup;

    /// <summary><paramref name="named"/> gets each page's title, the window's name of its page for assistive apps;
    /// <paramref name="changed"/> is called after each change of the setup, on the window's thread, so that the window shows
    /// the manager's chat once the setup ends.</summary>
    public ManagerSetupPage(ManagerSetup setup, DispatcherQueue queue, Action<string> named, Action changed)
    {
        this.setup = setup;
        this.queue = queue;
        this.named = named;
        this.changed = changed;
        Background = Look.CanvasBrush;
        scroll = new ScrollViewer
        {
            Content = room,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            IsTabStop = false,
        };
        scroll.SizeChanged += (_, e) => room.MinHeight = e.NewSize.Height;
        Children.Add(scroll);
        column.HorizontalAlignment = HorizontalAlignment.Center;
        column.VerticalAlignment = VerticalAlignment.Center;
        room.Children.Add(column);
        // Back on Back's line, as the first run's (FirstRunHost): only on the provider's page of a manager whose name's
        // page came first (ManagerSetupScreen.Back; the Mac's SetupBack); Esc is Back.
        back = new Button
        {
            Style = StepControls.Plain,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(22, 20, 0, 0),
            Padding = new Thickness(6, 4, 8, 4),
            Visibility = Visibility.Collapsed,
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 7,
                Children = { StepLook.Glyph(StepLook.ChevronLeft, 12, Look.Muted), Look.Words(SetupViewWords.Back, StepLook.Text, 20, Look.Muted, wrap: false) },
            },
        };
        AutomationProperties.SetName(back, SetupViewWords.Back);
        AutomationProperties.SetAutomationId(back, "agent-setup-back");
        back.Click += (_, _) => setup.BackToName();
        Children.Add(back);
        progress.HorizontalAlignment = HorizontalAlignment.Center;
        progress.VerticalAlignment = VerticalAlignment.Top;
        progress.Margin = new Thickness(0, 25, 0, 0);
        Children.Add(progress);
        AutomationProperties.SetAutomationId(this, "agent-setup");

        KeyboardAccelerators.Add(Enter());
        var escape = new KeyboardAccelerator { Key = global::Windows.System.VirtualKey.Escape };
        escape.Invoked += (_, e) =>
        {
            if (back.Visibility != Visibility.Visible) return;
            setup.BackToName();
            e.Handled = true;
        };
        KeyboardAccelerators.Add(escape);
        settings.AnimationsEnabledChanged += (_, _) => queue.TryEnqueue(() => { drawn = null; Show(); });
        Loaded += (_, _) => Open();
        Unloaded += (_, _) => Close();
    }

    private KeyboardAccelerator Enter()
    {
        var enter = new KeyboardAccelerator { Key = global::Windows.System.VirtualKey.Enter };
        enter.Invoked += (_, e) =>
        {
            if (paste?.Enter() == true) e.Handled = true;
            else if (onwards is { } press)
            {
                press();
                e.Handled = true;
            }
        };
        return enter;
    }

    private bool Reduced => !settings.AnimationsEnabled;

    /// <summary>The page shows: its reads run while it shows, and the first second shows nothing.</summary>
    private void Open()
    {
        if (open) return;
        open = true;
        // A new visit of the page, as the Mac's view that opens: its command may go again by itself (ManagerSetup.Visit).
        setup.Visit();
        setup.Changed += Changed;
        run = new CancellationTokenSource();
        _ = setup.RunAsync(run.Token);
        held = setup.View.Answered;
        if (!held)
        {
            holdTimer = queue.CreateTimer();
            holdTimer.Interval = TimeSpan.FromSeconds(1);
            holdTimer.IsRepeating = false;
            holdTimer.Tick += (_, _) => { held = true; Show(); };
            holdTimer.Start();
        }
        Show();
    }

    /// <summary>The page leaves the window: its reads stop. The setup stays, for the next time it shows.</summary>
    public void Close()
    {
        if (!open) return;
        open = false;
        setup.Changed -= Changed;
        run?.Cancel();
        run = null;
        holdTimer?.Stop();
        bar?.Rest();
    }

    private void Changed(object? sender, ManagerSetupView view) => queue.TryEnqueue(() =>
    {
        Show();
        changed();
    });

    /// <summary>The setup as its page shows it now.</summary>
    private void Show()
    {
        if (!open) return;
        var view = setup.View;
        var screen = ManagerSetupScreens.Of(view);
        progress.Show(screen.Progress);
        room.Padding = new Thickness(0, screen.Progress is null ? 0 : 56, 0, 0);
        var shows = screen.Drawn && (view.Answered || held);
        column.Visibility = shows ? Visibility.Visible : Visibility.Collapsed;
        back.Visibility = shows && screen.Back ? Visibility.Visible : Visibility.Collapsed;
        if (screen.Title != namedAs)
        {
            namedAs = screen.Title;
            named(screen.Title);
        }
        if (!shows) return;
        // The name's page: the mark of the typed name at 72, as the first run's (ManagerNamePage).
        var isName = screen.Name == "name";
        var mark = isName ? "name:" + ManagerNamePage.MarkOf(view)
            : screen.Logo is { } logo ? "logo:" + logo : (screen.Making ? "making:" : "agent:") + view.Agent;
        if (mark != markOf)
        {
            markOf = mark;
            column.Mark = isName ? StepLook.AgentMark(ManagerNamePage.MarkOf(view), 72)
                : screen.Logo is { } provider ? ProviderPage.Logo(provider, StepLook.Mark, 12)
                : StepLook.AgentMark(view.Agent, screen.Making ? 96 : StepLook.Mark);
        }
        column.Show(screen.Title, screen.Waits, screen.Detail, Reduced);
        // The name's field holds the typed words itself: its page is drawn once, not at each key.
        var key = isName ? "name" : screen.Name + "|" + string.Join(",", screen.Controls.Select(c => c.Kind + c.Id + c.Words + c.Marked + string.Join("/", c.Lines ?? [])));
        if (key != drawn)
        {
            drawn = key;
            Draw(view, screen);
        }
        else if (bar is not null && screen.Controls.FirstOrDefault(c => c.Kind == SetupControlKind.Bar) is { } part)
        {
            bar.Show(Part(part), Reduced);
        }
        // The provider cards take no press while one is on its way (the Mac's ProviderCard with busy), in place, so that a
        // field of the page keeps what it holds.
        foreach (var card in cardButtons) card.IsEnabled = !view.Busy;
        if (isName) namePage?.Show(view, screen);
        warning.Text = screen.Warning ?? "";
        warning.Visibility = screen.Warning is null ? Visibility.Collapsed : Visibility.Visible;
        if (setup.TakeOpening() is { } opening) OpenSignIn(opening.Link, opening.Code);
    }

    private static int? Part(SetupControl bar) =>
        int.TryParse(bar.Line, NumberStyles.None, CultureInfo.InvariantCulture, out var part) ? part : null;

    private void Draw(ManagerSetupView view, ManagerSetupScreen screen)
    {
        bar?.Rest();
        bar = null;
        paste = null;
        onwards = null;
        column.Controls.Children.Clear();
        cardButtons.Clear();
        if (screen.Name == "name")
        {
            // "Name your manager": the field, the orange line of a refused rename, and Continue (the Mac's order).
            namePage ??= new ManagerNamePage(setup);
            column.Controls.Children.Add(namePage.Field);
            column.Controls.Children.Add(warning);
            column.Controls.Children.Add(namePage.Next);
            onwards = () => namePage.Enter();
            return;
        }
        var cards = screen.Controls.Where(c => c.Kind == SetupControlKind.Card).ToList();
        if (cards.Count > 0) column.Controls.Children.Add(Cards(cards, view.Busy));
        foreach (var control in screen.Controls.Where(c => c.Kind != SetupControlKind.Card))
        {
            switch (control.Kind)
            {
                case SetupControlKind.Bar:
                    bar = new StepsBar(control.Lines ?? []);
                    bar.Show(Part(control), Reduced);
                    column.Controls.Children.Add(bar);
                    break;
                case SetupControlKind.Steps:
                    column.Controls.Children.Add(SetupParts.Steps(control.Lines ?? [], id: control.Id, open: OpenSignIn));
                    break;
                case SetupControlKind.Paste:
                    // A code that cannot go now (another is on its way, a press runs) stays in its field, for Enter.
                    paste = new PasteField(control.Words, control.Id, t => MachineLogin.CodeOf(t) is not null, code => _ = setup.SendCodeAsync(code),
                                           ready: () => setup.TakesCode);
                    column.Controls.Children.Add(paste.Field);
                    break;
                case SetupControlKind.Code:
                    column.Controls.Children.Add(new CodeBox(control.Words, control.Id));
                    break;
                case SetupControlKind.Button:
                    // Try again: of a failed install, the same install again with the provider it has; of the wait for the
                    // hub's own server, the wait again.
                    var again = StepControls.Primary(control.Words, control.Id);
                    var provider = view.Marked ?? view.Reading?.Agent?.Runtime ?? "codex";
                    onwards = control.Id == "agent-setup-share-again" ? setup.ShareAgain : () => _ = setup.ChooseAsync(provider);
                    again.Click += (_, _) => onwards?.Invoke();
                    column.Controls.Children.Add(again);
                    break;
            }
        }
        // The orange line stands under the cards and over Try again (the Mac's providers, and its words over Continue), else
        // last.
        var at = column.Controls.Children.IndexOf(column.Controls.Children.OfType<Button>()
            .LastOrDefault(b => AutomationProperties.GetAutomationId(b) is "agent-setup-install-again" or "agent-setup-share-again"));
        if (at >= 0) column.Controls.Children.Insert(at, warning);
        else column.Controls.Children.Add(warning);
    }

    /// <summary>The provider cards in one row, 14 apart, each with its logo at 28, its name and the check mark on the chosen
    /// one (the Mac's <c>ProviderCard</c>, as the first run's provider page draws them); while a press is on its way they
    /// take no press (the Mac's <c>.disabled(busy)</c>).</summary>
    private Grid Cards(IReadOnlyList<SetupControl> cards, bool busy)
    {
        var row = new Grid { ColumnSpacing = 14 };
        for (int i = 0; i < cards.Count; i++)
        {
            var control = cards[i];
            var provider = control.Id["agent-setup-provider-".Length..];
            row.ColumnDefinitions.Add(new ColumnDefinition());
            var card = StepControls.Card(StepControls.CardLine(ProviderPage.Logo(provider), control.Words, control.Marked), control.Words, control.Id);
            card.IsEnabled = !busy;
            cardButtons.Add(card);
            card.Click += (_, _) => _ = setup.ChooseAsync(provider);
            Grid.SetColumn(card, i);
            row.Children.Add(card);
        }
        return row;
    }

    /// <summary>The first step's link: the model's own link of this sign-in, which is only ever of the provider's own hosts,
    /// in the default browser; Codex's code to the clipboard with it (the Mac's <c>openSignIn</c>).</summary>
    private void OpenSignIn()
    {
        if (setup.View.SignIn is not { Link: { } link } page) return;
        setup.Opened();
        OpenSignIn(link, page.ShownCode);
    }

    private static void OpenSignIn(Uri link, string? code)
    {
        if (code is not null) ClipboardText.Copy(code, once: true);
        _ = global::Windows.System.Launcher.LaunchUriAsync(link);
    }
}

/// <summary>**The steps of a server's job as a bar** (the Mac's <c>SetupStepsBar</c>; set 8's <c>.bar4</c>): 240 wide, 4
/// high, 6 between two parts, each part as wide as the others with a round end; a done part in the words' colour at 62 %,
/// the part that runs the green of work over the track and breathing (its opacity from 1 to 0.3 and back in 0.9 s each
/// way, as the Mac's layer does), the rest the track of white 10 %. With Windows' animation effects off the part that runs
/// is green and still. No number and no word: an assistive app reads "Step 3 of 4: Checkout.".</summary>
internal sealed class StepsBar : Grid
{
    private const double Thickness = 4, Gap = 6, Width0 = 240;
    private readonly IReadOnlyList<string> steps;
    private readonly List<Border> parts = [];
    private readonly List<Border> breaths = [];
    private Storyboard? breath;
    private int? shownPart;
    private bool? shownReduced;

    public StepsBar(IReadOnlyList<string> steps)
    {
        this.steps = steps;
        Width = Width0;
        Height = Thickness;
        ColumnSpacing = Gap;
        HorizontalAlignment = HorizontalAlignment.Center;
        IsHitTestVisible = false;
        AutomationProperties.SetAutomationId(this, "agent-setup-bar");
        for (int i = 0; i < steps.Count; i++)
        {
            ColumnDefinitions.Add(new ColumnDefinition());
            var part = new Border { CornerRadius = new CornerRadius(Thickness / 2), Background = Track };
            var green = new Border { CornerRadius = new CornerRadius(Thickness / 2), Background = Look.Green, Opacity = 0 };
            Grid.SetColumn(part, i);
            Grid.SetColumn(green, i);
            Children.Add(part);
            Children.Add(green);
            parts.Add(part);
            breaths.Add(green);
        }
    }

    private static readonly Brush Track = Look.Brush(Look.White(0.10));
    private static readonly Brush Done = Look.Brush(Color.FromArgb((byte)Math.Round(0.62 * 255), 0xE6, 0xE6, 0xE6));

    /// <summary>The part that runs, from 0, or null while none runs that the list holds.</summary>
    public void Show(int? running, bool reduced)
    {
        if (shownPart == running && shownReduced == reduced) return;
        shownPart = running;
        shownReduced = reduced;
        Rest();
        for (int i = 0; i < parts.Count; i++)
        {
            parts[i].Background = running is { } at && i < at ? Done : Track;
            breaths[i].Opacity = running == i ? 1 : 0;
        }
        AutomationProperties.SetName(this, running is { } now && now < steps.Count
            ? $"Step {now + 1} of {steps.Count}: {steps[now]}."
            : "");
        if (running is { } run && !reduced)
        {
            var animation = new DoubleAnimation
            {
                From = 1,
                To = 0.3,
                Duration = TimeSpan.FromSeconds(0.9),
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
            };
            Storyboard.SetTarget(animation, breaths[run]);
            Storyboard.SetTargetProperty(animation, "Opacity");
            breath = new Storyboard();
            breath.Children.Add(animation);
            breath.Begin();
        }
    }

    /// <summary>The breath stops (the page left, or another part runs).</summary>
    public void Rest()
    {
        breath?.Stop();
        breath = null;
    }
}

/// <summary>**A sign-in code in its box, with Copy** (the Mac's <c>SetupCode</c> and <c>CopyButton</c>; set 8's
/// <c>.code</c>): as wide as a step's field (380), 18 in at the left and 12 at the right and over and under it, a corner of
/// 6, white 5 % with the canvas's hairline; the code at the title's size (22 on 28), semibold, 3 apart, figures of one
/// width, selectable; Copy at its right, step 1's standard button, which says Copied for two seconds.</summary>
internal sealed class CodeBox : Grid
{
    private readonly Button copy;
    private readonly DispatcherQueueTimer back;

    public CodeBox(string code, string id)
    {
        Width = StepLook.FieldWidth;
        HorizontalAlignment = HorizontalAlignment.Center;
        Padding = new Thickness(18, 12, 12, 12);
        CornerRadius = new CornerRadius(6);
        Background = Look.Brush(Look.White(0.05));
        BorderBrush = Look.Line;
        BorderThickness = new Thickness(1);
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = new TextBlock
        {
            Text = code,
            FontFamily = Look.Display,
            FontSize = 22,
            LineHeight = 28,
            FontWeight = FontWeights.SemiBold,
            CharacterSpacing = 136,
            Foreground = Look.Text,
            IsTextSelectionEnabled = true,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(words, id);
        grid.Children.Add(words);
        copy = SetupParts.Standard(SetupViewWords.Copy, id + "-copy");
        back = DispatcherQueue.GetForCurrentThread().CreateTimer();
        back.Interval = TimeSpan.FromSeconds(2);
        back.IsRepeating = false;
        back.Tick += (_, _) => Say(SetupViewWords.Copy);
        // A second press says Copied again for its own two seconds.
        copy.Click += (_, _) =>
        {
            if (!ClipboardText.Copy(code, once: true)) return;
            Say(SetupViewWords.Copied);
            back.Stop();
            back.Start();
        };
        Grid.SetColumn(copy, 1);
        grid.Children.Add(copy);
        Children.Add(grid);
    }

    private void Say(string words)
    {
        if (copy.Content is Border { Child: TextBlock label }) label.Text = words;
        AutomationProperties.SetName(copy, words);
    }
}
