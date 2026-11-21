using System.Linq;
using System.Threading;
using Founderizer.Setup.FirstRun;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**Connect Tailscale, and Waiting for Tailscale** (set 8, pictures 6 and 7; the Mac's network step of
/// <c>FirstRunView</c>): Tailscale's logo on its white tile, the title, and Connect; after the press the moving title
/// "Waiting for Tailscale" and the quiet link "Open Tailscale again", which presses again. While a press runs (the
/// download, its check, Windows' installer) neither shows, as on the Mac. What stopped a press is the one orange line
/// under them. The frame reads this PC every two seconds, and the page goes on by itself once the PC is on its network
/// (<see cref="SetupStore.ReadPc"/>). Back stops a download that runs; Windows' installer, once it runs, is never cut
/// off.</summary>
internal sealed class NetworkPage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.Width) { Mark = StepMarks.Network() };
    private readonly Button connect = StepControls.Primary(SetupScreens.Connect, "first-run-network-connect");
    private readonly Button again = StepControls.Link(SetupScreens.OpenTailscaleAgain, "first-run-network-again");
    private readonly TextBlock warning = StepControls.Warning("");
    private CancellationTokenSource? press;
    private bool busy;

    public NetworkPage(StepHost host)
    {
        this.host = host;
        column.Controls.Children.Add(connect);
        column.Controls.Children.Add(again);
        column.Controls.Children.Add(warning);
        connect.Click += (_, _) => Press();
        again.Click += (_, _) => Press();
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen screen)
    {
        column.Show(screen.Title, screen.Waits, screen.Detail, host.ReduceMotion());
        connect.Visibility = !busy && screen.Controls.Any(c => c.Id == "first-run-network-connect") ? Visibility.Visible : Visibility.Collapsed;
        again.Visibility = !busy && screen.Controls.Any(c => c.Id == "first-run-network-again") ? Visibility.Visible : Visibility.Collapsed;
        warning.Text = screen.Warning ?? "";
        warning.Visibility = screen.Warning is null ? Visibility.Collapsed : Visibility.Visible;
    }

    public bool Enter()
    {
        if (connect.Visibility != Visibility.Visible) return false;
        Press();
        return true;
    }

    /// <summary>Connect, or Open Tailscale again: Tailscale's installer when this PC has none, then Tailscale's sign-in.</summary>
    private async void Press()
    {
        if (busy) return;
        busy = true;
        press = new CancellationTokenSource();
        var cancel = press.Token;
        host.Store.PressConnect();
        string? stop;
        try { stop = await host.Tailscale.ConnectAsync(cancel); }
        finally { busy = false; }
        if (cancel.IsCancellationRequested) return;
        if (stop is not null) host.Store.NetworkStopped(stop);
        else Show(host.Store.State, SetupScreens.Of(host.Store.State, host.Store.Runs, host.Store.ShowsBuild));
    }

    public void Left()
    {
        press?.Cancel();
        host.Tailscale.Stop();
    }
}
