using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Marks;
using Founderizer.Windows.Navigation;
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
/// content area, where the page of the history opens. It draws; every rule, word and order is the library's.</summary>
public sealed partial class MainWindow : Window
{
    private readonly IFleetSource source;
    private readonly History history;
    private readonly ObservableCollection<AgentRowView> rows = new();
    private readonly UISettings settings = new();
    private StoreState state;
    private PaneModel pane = new();
    /// <summary>The first page is settled: it was asked for, a reading chose it, or he went to a page.</summary>
    private bool homeChosen;

    public MainWindow(IFleetSource source, Page? asked)
    {
        this.source = source;
        InitializeComponent();
        NeedsIcon.Content = PaneIcons.Icon(PaneIcons.NeedsYou);
        TasksIcon.Content = PaneIcons.Icon(PaneIcons.Tasks);
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
        settings.AnimationsEnabledChanged += (_, _) => DispatcherQueue.TryEnqueue(ShowPane);

        // The store reads only while the window is in front (StoreSettings): shown and not minimized.
        VisibilityChanged += (_, _) => Front();
        AppWindow.Changed += (_, e) => { if (e.DidPresenterChange) Front(); };
        Closed += async (_, _) => await source.DisposeAsync();
        Front();

        // Back and Forward from the keyboard and the mouse's side buttons, as Windows' apps take them.
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
        source.SetFront(Visible && !minimized);
    }

    private static KeyboardAccelerator Accelerator(VirtualKey key,
        global::Windows.Foundation.TypedEventHandler<KeyboardAccelerator, KeyboardAcceleratorInvokedEventArgs> invoked)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Menu };
        accelerator.Invoked += invoked;
        return accelerator;
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
        state = next;
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
        Passthrough();
    }

    private int IndexOf(string name, int from)
    {
        for (int i = from; i < rows.Count; i++) if (rows[i].Name == name) return i;
        return -1;
    }

    /// <summary>The page of the history opens in the content area, and the pane and the title bar follow. The pages come
    /// in the later slices: until then the area is empty, with the page's name for assistive apps.</summary>
    private void ShowPage()
    {
        BackButton.IsEnabled = history.CanGoBack;
        ForwardButton.IsEnabled = history.CanGoForward;
        var page = history.Current;
        string name = page.Kind switch
        {
            PageKind.Needs => "Needs you",
            PageKind.Tasks => "Tasks",
            PageKind.Settings => "Settings",
            PageKind.AddThisPc => "Add this PC",
            PageKind.Task => state.Fleet?.Tasks.FirstOrDefault(t => t.Id == page.Task)?.Title ?? "Tasks",
            _ => state.Names.Label(page.Agent ?? ""),
        };
        PageHost.Content = new Grid();
        AutomationProperties.SetName(PageHost, name);
        ShowPane();
    }

    private static void Show(UIElement fill, UIElement bar, bool on) =>
        fill.Visibility = bar.Visibility = on ? Visibility.Visible : Visibility.Collapsed;

    private void Go(Page page)
    {
        homeChosen = true;
        history.Go(page);
    }

    private void GoBack() => history.GoBack();
    private void GoForward() => history.GoForward();

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
