using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Marks;
using Founderizer.Windows.Navigation;
using Founderizer.Windows.Pages;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Graphics;
using Windows.System;
using Windows.UI;
using Windows.UI.ViewManagement;
using Page = Founderizer.Core.Page;

namespace Founderizer.Windows;

/// <summary>The window: the frame of the approved pictures, the pane as the library's Screens.Pane gives it, and the
/// content area, where the page of the history opens (a chat, Needs you, the board or a task). It draws; every rule,
/// word and order is the library's.</summary>
public sealed partial class MainWindow : Window
{
    private readonly IFleetSource source;
    private readonly PageServices services;
    private readonly History history;
    private readonly ObservableCollection<AgentRowView> rows = new();
    private readonly UISettings settings = new();
    private StoreState state;
    private PaneModel pane = new();
    /// <summary>The first page is settled: it was asked for, a reading chose it, or he went to a page.</summary>
    private bool homeChosen;
    /// <summary>Ages that move with the clock alone ("25 min ago") raise no change of the store: while the window is
    /// in front, the pane and the open page are drawn again every 30 seconds, and only what changed is drawn.</summary>
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? clock;
    /// <summary>The page that the content area shows now, or null for a page of a later slice.</summary>
    private IPageView? page;
    /// <summary>The line over the page that shows now (the page's own, or the window's over a page with no panel).</summary>
    private LineBand? band;
    /// <summary>The request line of a write that waits (the page's own over its composer, or the window's at its foot).</summary>
    private PendingBarView? bar;
    /// <summary>The first read runs: the pane's line waits a second before it shows (the screens' timing).</summary>
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? readingTimer;
    /// <summary>The content area shows the waiting page (nothing) while the first read runs.</summary>
    private bool waitingPage;
    /// <summary>The search card over the whole window (Ctrl+K and the magnifier).</summary>
    private readonly SearchCard search;
    private readonly WindowsNotices notices;
    private TaskbarCount? taskbar;
    /// <summary>The request that Needs you brings to hand when it opens from a task's orange line.</summary>
    private long? needToOpen;

    public MainWindow(IFleetSource source, Page? asked)
    {
        this.source = source;
        services = new PageServices(source, Go, OpenNeed, () => WinRT.Interop.WindowNative.GetWindowHandle(this));
        InitializeComponent();
        NeedsIcon.Content = Icons.Of(Icons.NeedsYou);
        TasksIcon.Content = Icons.Of(Icons.Tasks);
        AgentRows.ItemsSource = rows;

        // The title bar is the window's own (W1, W2): tall, as it carries Back, with Windows' caption buttons in the
        // page's colours. The window opens over the whole screen, as the Mac app does.
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        var bar = AppWindow.TitleBar;
        bar.PreferredHeightOption = TitleBarHeightOption.Tall;
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonForegroundColor = Color.FromArgb(255, 0xE6, 0xE6, 0xE6);
        bar.ButtonInactiveForegroundColor = Color.FromArgb(255, 0x99, 0x99, 0x99);
        bar.ButtonHoverBackgroundColor = Color.FromArgb(0x0F, 255, 255, 255);
        bar.ButtonHoverForegroundColor = Color.FromArgb(255, 0xE6, 0xE6, 0xE6);
        bar.ButtonPressedBackgroundColor = Color.FromArgb(0x0A, 255, 255, 255);
        bar.ButtonPressedForegroundColor = Color.FromArgb(255, 0xE6, 0xE6, 0xE6);
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.Maximize();
        // The least window (picture 11, the Mac's 960 by 560), in the screen's own pixels at the window's scale; the
        // pane and the panel give up width before the chat below 1440.
        Root.Loaded += (_, _) =>
        {
            LeastSize();
            Content.XamlRoot.Changed += (_, _) => LeastSize();
        };
        Root.SizeChanged += (_, e) => Widths.For(e.NewSize.Width);
        Widths.Changed += () =>
        {
            PaneColumn.Width = new GridLength(Widths.Pane);
            Canvas.SetLeft(SearchButton, Widths.Pane - 48);
            Passthrough();
        };
        TitleBar.SizeChanged += (_, _) => Passthrough();
        TitleBar.Loaded += (_, _) => Passthrough();

        // The page it opens on: the one asked for (-openPage), else the library's first page (FleetStore.home).
        state = source.State;
        homeChosen = asked is not null || state.Fleet is not null;
        history = new History(asked ?? Screens.FirstPage(state));
        history.Changed += ShowPage;
        ShowPane();
        ShowPage();
        source.Changed += (_, change) => DispatcherQueue.TryEnqueue(() => Apply(change.State, change.ArrivedTicks));
        settings.AnimationsEnabledChanged += (_, _) => DispatcherQueue.TryEnqueue(() =>
        {
            ShowPane();
            page?.Show(state, DateTimeOffset.UtcNow, !settings.AnimationsEnabled);
        });

        // The store reads only while the window is in front (StoreSettings): shown and not minimized.
        VisibilityChanged += (_, _) => Front();
        AppWindow.Changed += (_, e) =>
        {
            if (e.DidPresenterChange) Front();
            if (e.DidSizeChange || e.DidPresenterChange) LeastSize();
        };
        Closed += async (_, _) => await source.DisposeAsync();
        Front();

        // Back and Forward from the keyboard and the mouse's side buttons, as Windows' apps take them. WinUI would show
        // the keys in a tooltip wherever the pointer rests over the window ("Alt+Left"): no picture has that tooltip.
        Root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        notices = new WindowsNotices(source, DispatcherQueue, () => state, OpenNotice);
        Root.Loaded += async (_, _) =>
        {
            taskbar = new TaskbarCount(WinRT.Interop.WindowNative.GetWindowHandle(this), CountBadge, words => CountWords.Text = words);
            _ = taskbar.Show(Screens.TaskbarCount(state));
            if (await WindowsNotices.MarkFile(TitleMark, AppFolders.Root) is { } mark) notices.Start(mark);
        };
        Closed += (_, _) => notices.Stop();
        search = new SearchCard(() => state, Go, () =>
        {
            Passthrough();
            PageHost.Focus(FocusState.Programmatic);
        });
        Grid.SetRowSpan(search, 2);
        Grid.SetColumnSpan(search, 2);
        Root.Children.Add(search);
        // Ctrl+K on the Search button: Windows writes the key's own name in its tooltip, beside the library's word.
        var ctrlK = new KeyboardAccelerator { Key = VirtualKey.K, Modifiers = VirtualKeyModifiers.Control };
        ctrlK.Invoked += (_, e) => { OpenSearch(); e.Handled = true; };
        SearchButton.KeyboardAccelerators.Add(ctrlK);
        SearchButton.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Auto;
        ToolTipService.SetToolTip(SearchButton, new SearchModel().Placeholder);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(SearchButton, new SearchModel().Placeholder);
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Left, (_, e) => { GoBack(); e.Handled = true; }));
        Root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Right, (_, e) => { GoForward(); e.Handled = true; }));
        Root.PointerPressed += (_, e) =>
        {
            var point = e.GetCurrentPoint(Root).Properties;
            if (point.IsXButton1Pressed) GoBack();
            else if (point.IsXButton2Pressed) GoForward();
        };

        Readings.FirstFrame();
        Readings.BlockTheUiThread(DispatcherQueue);
    }

    private void Front()
    {
        bool minimized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized };
        bool front = Visible && !minimized;
        source.SetFront(front);
        if (clock is null)
        {
            clock = DispatcherQueue.CreateTimer();
            clock.Interval = TimeSpan.FromSeconds(30);
            clock.IsRepeating = true;
            clock.Tick += (_, _) =>
            {
                ShowPane();
                ShowLine();
                page?.Show(state, DateTimeOffset.UtcNow, !settings.AnimationsEnabled);
            };
        }
        if (front) clock.Start();
        else clock.Stop();
    }

    private static KeyboardAccelerator Accelerator(VirtualKey key,
        global::Windows.Foundation.TypedEventHandler<KeyboardAccelerator, KeyboardAcceleratorInvokedEventArgs> invoked)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Menu };
        accelerator.Invoked += invoked;
        return accelerator;
    }

    /// <summary>Windows keeps the window's outer frame at its least size, and the frame is a little larger than the
    /// window's content (its edges for resizing): the least size takes the frame's own part, read while the window is
    /// not maximized.</summary>
    private (int Width, int Height) frame = (0, 0);

    private void LeastSize()
    {
        if (AppWindow.Presenter is not OverlappedPresenter presenter || Content?.XamlRoot is not { } root) return;
        if (presenter.State == OverlappedPresenterState.Restored)
            frame = (Math.Max(0, AppWindow.Size.Width - AppWindow.ClientSize.Width), Math.Max(0, AppWindow.Size.Height - AppWindow.ClientSize.Height));
        presenter.PreferredMinimumWidth = (int)Math.Ceiling(Widths.LeastWidth * root.RasterizationScale) + frame.Width;
        presenter.PreferredMinimumHeight = (int)Math.Ceiling(Widths.LeastHeight * root.RasterizationScale) + frame.Height;
    }

    /// <summary>The buttons in the title bar take the pointer; the rest of it moves the window.</summary>
    private void Passthrough()
    {
        if (Content?.XamlRoot is not { } root) return;
        double scale = root.RasterizationScale;
        var rects = new List<RectInt32>();
        foreach (var button in new FrameworkElement[] { BackButton, ForwardButton, SearchButton })
        {
            if (button.Visibility != Visibility.Visible || button.ActualWidth <= 0) continue;
            var at = button.TransformToVisual(null).TransformPoint(new global::Windows.Foundation.Point(0, 0));
            rects.Add(new RectInt32((int)Math.Round(at.X * scale), (int)Math.Round(at.Y * scale),
                (int)Math.Round(button.ActualWidth * scale), (int)Math.Round(button.ActualHeight * scale)));
        }
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, rects.ToArray());
    }

    /// <summary>A new state of the store: once a reading can choose it, the first page; pages of agents that left go;
    /// then the pane draws what changed.</summary>
    private void Apply(StoreState next, long arrived)
    {
        var before = state;
        state = next;
        // A PC that took its key and read its fleet leaves Add this PC for its first page, as the iPhone's EnrollPage
        // closes: the launch's first page, with no way back to the code.
        if (history.Current.Kind == PageKind.AddThisPc && next.Key == KeyState.InHand && next.Fleet is not null &&
            (before.Key != KeyState.InHand || before.Fleet is null))
        {
            homeChosen = true;
            history.Start(Screens.FirstPage(next));
        }
        if (!homeChosen && next.Fleet is not null)
        {
            homeChosen = true;
            history.Start(Screens.FirstPage(next));
        }
        if (next.Fleet is { } fleet)
        {
            var names = fleet.Agents.Select(a => a.Name).ToHashSet();
            history.Forget(p => p.Kind == PageKind.Chat && !names.Contains(p.Agent!));
            if (history.Current.Kind == PageKind.Chat && !names.Contains(history.Current.Agent!)) history.Go(Page.Tasks);
        }
        var was = pane;
        ShowPane();
        search.Show();
        notices.Prune(next);
        if (taskbar is not null) _ = taskbar.Show(Screens.TaskbarCount(next));
        if (WaitingPage(next) != waitingPage) ShowPage();
        ShowLine();
        page?.Show(next, DateTimeOffset.UtcNow, !settings.AnimationsEnabled);
        var now = pane;
        Readings.ChangeShown(arrived, () => Shown(was, now));
    }

    /// <summary>For the timing log: what the pane shows differently after a change.</summary>
    private static string Shown(PaneModel was, PaneModel now)
    {
        var parts = new List<string>();
        if (was.ShowsNeeds != now.ShowsNeeds || was.NeedsCount != now.NeedsCount) parts.Add($"needs {now.NeedsCount}");
        var rows = RowDiff.Of(was.Agents, now.Agents, row => row.Name);
        parts.AddRange(rows.Added.Concat(rows.Changed).Select(name => "row " + name));
        return parts.Count == 0 ? "nothing new" : string.Join(", ", parts);
    }

    /// <summary>The pane as the library's model gives it: Needs you and its count, Tasks, the agents' rows (each row
    /// changed only where it changed), Settings, the selection, and Search.</summary>
    private void ShowPane()
    {
        var next = Screens.Pane(state, history.Current, DateTimeOffset.UtcNow, ScreenContext.Local, reduceMotion: !settings.AnimationsEnabled);
        NeedsButton.Visibility = next.ShowsNeeds ? Visibility.Visible : Visibility.Collapsed;
        NeedsCount.Text = next.NeedsCount.ToString(System.Globalization.CultureInfo.CurrentCulture);
        SearchButton.Visibility = next.ShowsSearch ? Visibility.Visible : Visibility.Collapsed;
        Show(NeedsFill, NeedsBar, next.NeedsSelected);
        Show(TasksFill, TasksBar, next.TasksSelected);
        Show(SettingsFill, SettingsBar, next.SettingsSelected);

        var changes = RowDiff.Of(pane.Agents, next.Agents, row => row.Key);
        if (!changes.None || rows.Count != next.Agents.Count)
        {
            for (int i = 0; i < next.Agents.Count; i++)
            {
                var row = next.Agents[i];
                int at = IndexOf(row.Name, i);
                if (at < 0) rows.Insert(i, new AgentRowView(row.Name));
                else if (at != i) rows.Move(at, i);
                rows[i].Show(row);
            }
            while (rows.Count > next.Agents.Count) rows.RemoveAt(rows.Count - 1);
        }
        pane = next;
        ShowReading(next.Reading);
        Passthrough();
    }

    /// <summary>"Reading the hub…" in the pane, one second after the first read began, while it runs.</summary>
    private void ShowReading(bool reading)
    {
        if (!reading)
        {
            readingTimer?.Stop();
            ReadingLine.Visibility = Visibility.Collapsed;
            return;
        }
        ReadingLine.Text = pane.ReadingWords;
        ReadingLine.Shimmer = settings.AnimationsEnabled;
        if (ReadingLine.Visibility == Visibility.Visible || readingTimer?.IsRunning == true) return;
        if (readingTimer is null)
        {
            readingTimer = DispatcherQueue.CreateTimer();
            readingTimer.Interval = TimeSpan.FromSeconds(1);
            readingTimer.IsRepeating = false;
            readingTimer.Tick += (_, _) => { if (pane.Reading) ReadingLine.Visibility = Visibility.Visible; };
        }
        readingTimer.Start();
    }

    private int IndexOf(string name, int from)
    {
        for (int i = from; i < rows.Count; i++) if (rows[i].Name == name) return i;
        return -1;
    }

    /// <summary>The page of the history opens in the content area, and the pane and the title bar follow; the store reads
    /// the chat or the task that shows.</summary>
    private void ShowPage()
    {
        BackButton.IsEnabled = history.CanGoBack;
        ForwardButton.IsEnabled = history.CanGoForward;
        var current = history.Current;
        source.OpenChat(current.Kind == PageKind.Chat ? current.Agent : null);
        source.OpenTask(current.Kind == PageKind.Task ? current.Task : null);
        long? chosen = needToOpen;
        needToOpen = null;
        // While the first read runs, the pages of the fleet wait: the content area is empty (the Mac's waitingPage).
        waitingPage = WaitingPage(state);
        page = waitingPage ? null : current.Kind switch
        {
            PageKind.Chat => new ChatPage(current.Agent!, services),
            PageKind.Needs => new NeedsPage(services, chosen),
            PageKind.Tasks => new BoardPage(Go, OpenNeed),
            PageKind.Task => new TaskPage(current.Task!.Value, services),
            PageKind.Settings => new SettingsPage(source, Go, () => history.Start(Page.AddThisPc)),
            PageKind.AddThisPc => new AddThisPcPage(source),
            _ => null,
        };
        band = page?.Band ?? new LineBand(services);
        bar = page?.Bar ?? new PendingBarView(services);
        PageHost.Content = page is null ? new Grid() : page.Band is null ? Banded.Wrap(page.View, band, page.Bar is null ? bar : null) : page.View;
        ShowLine();
        page?.Show(state, DateTimeOffset.UtcNow, !settings.AnimationsEnabled);
        if (page is ChatPage chat) Readings.ScrollWhenAsked(chat.Scroll);
        string name = current.Kind switch
        {
            PageKind.Needs => "Needs you",
            PageKind.Tasks => "Tasks",
            PageKind.Settings => "Settings",
            PageKind.AddThisPc => "Add this PC",
            PageKind.Task => state.Fleet?.Tasks.FirstOrDefault(t => t.Id == current.Task)?.Title ?? "Tasks",
            _ => state.Names.Label(current.Agent ?? ""),
        };
        AutomationProperties.SetName(PageHost, name);
        ShowPane();
    }

    private bool WaitingPage(StoreState s) =>
        s.ReadsTheHub && history.Current.Kind is PageKind.Chat or PageKind.Needs or PageKind.Tasks or PageKind.Task;

    /// <summary>The line over the page (Screens.Line): it comes and goes with the reading, and with the clock, since a
    /// reading turns old by itself.</summary>
    private void ShowLine()
    {
        var now = DateTimeOffset.UtcNow;
        band?.Show(Screens.Line(state, now, history.Current));
        bar?.Show(Screens.PendingBar(state, now));
    }

    private static void Show(UIElement fill, UIElement bar, bool on) =>
        fill.Visibility = bar.Visibility = on ? Visibility.Visible : Visibility.Collapsed;

    private void Go(Page page)
    {
        homeChosen = true;
        history.Go(page);
    }

    /// <summary>A press on a notification: the window to the front, and Needs you at its request when it still stands.</summary>
    private void OpenNotice(long? need)
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        Activate();
        if (need is { } id) OpenNeed(id);
    }

    /// <summary>A task's orange line: Needs you opens with that request at hand.</summary>
    private void OpenNeed(long need)
    {
        needToOpen = need;
        Go(Page.Needs);
    }

    private void GoBack() => history.GoBack();
    private void GoForward() => history.GoForward();

    /// <summary>The search card, while the pane offers Search (a hub's reading). While it is open, the title bar takes
    /// no drag: a press on the dim closes the card.</summary>
    private void OpenSearch()
    {
        if (!pane.ShowsSearch || search.IsOpen) return;
        if (Content?.XamlRoot is { } root)
        {
            double scale = root.RasterizationScale;
            InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough,
                [new RectInt32(0, 0, (int)Math.Round(TitleBar.ActualWidth * scale), (int)Math.Round(TitleBar.ActualHeight * scale))]);
        }
        search.Open();
    }

    private void Search_Click(object sender, RoutedEventArgs e) => OpenSearch();

    private void Back_Click(object sender, RoutedEventArgs e) => GoBack();
    private void Forward_Click(object sender, RoutedEventArgs e) => GoForward();
    private void Needs_Click(object sender, RoutedEventArgs e) => Go(Page.Needs);
    private void Tasks_Click(object sender, RoutedEventArgs e) => Go(Page.Tasks);
    private void Settings_Click(object sender, RoutedEventArgs e) => Go(Page.Settings);

    private void Agent_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string name }) Go(Page.Chat(name));
    }
}
