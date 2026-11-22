using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Setup.FirstRun;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Navigation;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VirtualKey = Windows.System.VirtualKey;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**The frame of the first run** (windows-app-plan-v2.md, piece U1; the Mac's <c>SetupPage</c> in a window that
/// the first run fills, set 8's frame): the page is the canvas under the window's title bar; Back stands at its top left
/// on every page but the welcome page, and not while a build or an install runs; the wizard's steps stand on Back's line,
/// in the middle; the page's step stands in the middle of the room under them. Esc is Back; Enter is the page's way on.
/// Every word, rule and order is the library's (<see cref="SetupStore"/>, <see cref="SetupScreens"/>); a page that no
/// family draws yet (<see cref="Routes.Step"/>) shows its frame alone.
///
/// The frame reads this PC's Tailscale once when it opens and every two seconds on the network's page (the Mac's
/// <c>MacNetwork.read</c>), and gives it to the store (<see cref="SetupStore.ReadPc"/>): the page goes on by itself when
/// the PC is on its network.</summary>
internal sealed class FirstRunHost : Grid
{
    private readonly SetupStore store;
    private readonly StepHost host;
    private readonly Button back;
    private readonly StepProgress progress = new();
    private readonly ScrollViewer scroll;
    private readonly Grid room = new();
    private readonly UISettings settings = new();
    private IStepView? view;
    private SetupPage? shown;
    private string? namedAs;
    private DispatcherQueueTimer? poll;
    private int reading;
    private bool open;

    private readonly Action<string> named;
    /// <summary>For the proofs only: a state that the page shows in place of the store's (<c>SetupStandIn.Sample</c>).</summary>
    private readonly Func<SetupState?>? sample;

    /// <summary><paramref name="named"/> gets the title of each page that opens: the window's name of its page, for
    /// assistive apps. <paramref name="sample"/>: a proofs' build only, a state of the first run to show in place of the
    /// store's.</summary>
    public FirstRunHost(SetupStore store, PcTailscale pc, TailscaleSetup tailscale, Action addThisPc, DispatcherQueue queue, Action<string> named,
                        IntPtr window = default, Func<Founderizer.Setup.Cloud.CloudProvider, bool>? holds = null,
                        Func<SetupState?>? sample = null)
    {
        this.store = store;
        this.named = named;
        this.sample = sample;
        host = new StepHost
        {
            Store = store,
            Pc = pc,
            Tailscale = tailscale,
            AddThisPc = addThisPc,
            ReduceMotion = () => !settings.AnimationsEnabled,
            Queue = queue,
            Window = window,
            Holds = holds ?? (_ => false),
        };
        Background = Look.CanvasBrush;

        // The step in the middle of the room under the steps; a step taller than its room scrolls.
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

        back = new Button
        {
            Style = StepControls.Plain,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(22, 20, 0, 0),
            Padding = new Thickness(6, 4, 8, 4),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 7,
                Children = { StepLook.Glyph(StepLook.ChevronLeft, 12, Look.Muted), Look.Words(SetupViewWords.Back, StepLook.Text, 20, Look.Muted, wrap: false) },
            },
        };
        AutomationProperties.SetName(back, SetupViewWords.Back);
        AutomationProperties.SetAutomationId(back, "setup-back");
        back.Click += (_, _) => store.Back();
        Children.Add(back);

        progress.HorizontalAlignment = HorizontalAlignment.Center;
        progress.VerticalAlignment = VerticalAlignment.Top;
        progress.Margin = new Thickness(0, 25, 0, 0);
        Children.Add(progress);

        KeyboardAccelerators.Add(Key(VirtualKey.Escape, () => { if (back.Visibility == Visibility.Visible) store.Back(); }));
        KeyboardAccelerators.Add(Key(VirtualKey.Enter, () => view?.Enter()));

        settings.AnimationsEnabledChanged += (_, _) => queue.TryEnqueue(Show);
        Loaded += (_, _) =>
        {
            if (open) return;
            open = true;
            store.Changed += Changed;
            _ = ReadPcAsync();
            Show();
        };
        Unloaded += (_, _) => Close();
    }

    private void Changed(object? sender, SetupState state) => host.Queue.TryEnqueue(Show);

    /// <summary>The frame leaves the window (Add this PC): the page's own work and the reads stop. The store stays.</summary>
    public void Close()
    {
        if (!open) return;
        open = false;
        store.Changed -= Changed;
        poll?.Stop();
        view?.Left();
        view = null;
        shown = null;
        namedAs = null;
        host.Tailscale.Stop();
    }

    private static KeyboardAccelerator Key(VirtualKey key, Action act)
    {
        var accelerator = new KeyboardAccelerator { Key = key };
        accelerator.Invoked += (_, e) => { act(); e.Handled = true; };
        return accelerator;
    }

    /// <summary>The state as the page shows it: a new page makes its view; each change shows the model again.</summary>
    private void Show()
    {
        if (!open) return;
        var sampled = sample?.Invoke();
        var state = sampled ?? store.State;
        // A sample has no store of its own: an install of it runs while its state says so.
        var runs = sampled is null ? store.Runs : sampled.Install.Running || sampled.ManagerInstall.Running;
        var screen = sampled is null ? SetupScreens.Of(state, store.Runs, store.ShowsBuild) : SetupScreens.Of(state, runs);
        if (state.Page != shown)
        {
            view?.Left();
            view = Routes.Step(state.Page)?.Invoke(host);
            room.Children.Clear();
            if (view is not null)
            {
                view.View.HorizontalAlignment = HorizontalAlignment.Center;
                view.View.VerticalAlignment = VerticalAlignment.Center;
                room.Children.Add(view.View);
            }
            shown = state.Page;
            scroll.ChangeView(null, 0, null, disableAnimation: true);
        }
        // The window's name of its page follows the page's title at each change ("Waiting for Tailscale" after Connect,
        // "Checking 203.0.113.10" while a check runs), not only when the page changes.
        if (screen.Title != namedAs)
        {
            namedAs = screen.Title;
            named(screen.Title);
        }
        back.Visibility = screen.Back && !runs ? Visibility.Visible : Visibility.Collapsed;
        progress.Show(screen.Progress);
        // With the steps, the step's room starts under their names (set 8's 56 more over the step).
        room.Padding = new Thickness(0, screen.Progress is null ? 0 : 56, 0, 0);
        view?.Show(state, screen);
        Poll(state.Page == SetupPage.Network);
    }

    /// <summary>Every two seconds on the network's page, this PC's Tailscale again.</summary>
    private void Poll(bool on)
    {
        if (!on) { poll?.Stop(); return; }
        if (poll is null)
        {
            poll = host.Queue.CreateTimer();
            poll.Interval = TimeSpan.FromSeconds(2);
            poll.IsRepeating = true;
            poll.Tick += (_, _) => _ = ReadPcAsync();
        }
        if (!poll.IsRunning) poll.Start();
    }

    private async Task ReadPcAsync()
    {
        if (Interlocked.Exchange(ref reading, 1) == 1) return;
        try
        {
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var status = await Task.Run(() => host.Pc.ReadAsync(limit.Token));
            if (open) store.ReadPc(status, host.Pc.Installed);
        }
        catch (Exception e) when (e is OperationCanceledException or System.ComponentModel.Win32Exception or System.IO.IOException)
        {
        }
        finally
        {
            Interlocked.Exchange(ref reading, 0);
        }
    }
}

/// <summary>**The steps of the wizard on Back's line** (the Mac's <c>SetupProgress</c>; set 8's <c>.prog</c>): a dot of 10
/// for each step on a rule of 2, the name under it 8 lower at 15; a done step in the words' colour, the page's own step
/// green with a soft ring of 18, the rest dim. Each step is as wide as the longest name and 16, and at least 92. It is no
/// control: an assistive app reads "Step 2 of 6: AI provider.".</summary>
internal sealed class StepProgress : StackPanel
{
    private SetupProgress? shown;

    public StepProgress()
    {
        Orientation = Orientation.Horizontal;
        IsHitTestVisible = false;
    }

    public void Show(SetupProgress? progress)
    {
        if (progress is null)
        {
            Visibility = Visibility.Collapsed;
            shown = null;
            return;
        }
        Visibility = Visibility.Visible;
        if (shown is { } was && was.Current == progress.Current && was.Names.SequenceEqual(progress.Names)) return;
        shown = progress;
        Children.Clear();
        var names = progress.Names;
        int current = progress.Current;
        double width = Math.Max(92, Math.Ceiling(names.Select(Measure).DefaultIfEmpty(0).Max() + 16));
        var done = Look.Brush(Color.FromArgb((byte)Math.Round(0.85 * 255), 0xE6, 0xE6, 0xE6));
        var dim = Look.Brush(Color.FromArgb((byte)Math.Round(0.3 * 255), 0x99, 0x99, 0x99));
        for (int i = 0; i < names.Count; i++)
        {
            var mark = new Grid { Height = 18 };
            mark.ColumnDefinitions.Add(new ColumnDefinition());
            mark.ColumnDefinitions.Add(new ColumnDefinition());
            if (i > 0) mark.Children.Add(new Rectangle { Height = 2, Fill = i <= current ? done : dim });
            if (i < names.Count - 1)
            {
                var right = new Rectangle { Height = 2, Fill = i + 1 <= current ? done : dim };
                Grid.SetColumn(right, 1);
                mark.Children.Add(right);
            }
            if (i == current)
            {
                var ring = new Ellipse { Width = 18, Height = 18, Fill = Look.Brush(Color.FromArgb(64, 0x30, 0xD1, 0x58)) };
                Grid.SetColumnSpan(ring, 2);
                mark.Children.Add(ring);
            }
            var dot = new Ellipse
            {
                Width = 10,
                Height = 10,
                Fill = i < current ? Look.Text : i == current ? Look.Green : Look.Brush(Color.FromArgb((byte)Math.Round(0.35 * 255), 0x99, 0x99, 0x99)),
            };
            Grid.SetColumnSpan(dot, 2);
            mark.Children.Add(dot);
            var name = Look.Words(names[i], StepLook.Text, 20, i <= current ? Look.Text : Look.Muted, wrap: false);
            name.HorizontalAlignment = HorizontalAlignment.Center;
            Children.Add(new StackPanel { Width = width, Spacing = 8, Children = { mark, name } });
        }
        AutomationProperties.SetName(this, SetupViewWords.Progress(current, names.Count, current < names.Count ? names[current] : ""));
    }

    private static double Measure(string words)
    {
        var block = Look.Words(words, StepLook.Text, 20, wrap: false);
        block.Measure(new global::Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        return block.DesiredSize.Width;
    }
}
