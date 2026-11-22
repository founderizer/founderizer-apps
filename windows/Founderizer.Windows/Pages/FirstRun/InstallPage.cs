using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**The hub's install** (the Mac's <c>machine</c> of <c>FirstRunView</c> with <c>MachineInstallRun</c>), one
/// view for each state that the model gives (<see cref="SetupScreens.Installing"/>):
/// <list type="bullet">
/// <item>**"Building your fleet"** while the fleet builds with nothing for the owner to do or read (set 8, pictures 15 and
/// 16: <see cref="BuildView"/>), and the token page of the manager's own provider in its place;</item>
/// <item>**"Your hub did not install"** (picture 17): the stop has a true title, then "Your hub" with each step that the
/// installer reported by its name and its state, and nothing that the server printed; then the stop's card with what
/// stopped in plain words, and Try again, which runs the same install again;</item>
/// <item>a stop for the network's key (the Mac's <c>MachineInstallRun.network</c>; no picture of set 8): the row of why,
/// Tailscale's steps and the field of the access token, then Install again once a key is made;</item>
/// <item>checks that did not pass (the Mac's <c>VerifyChecklistView</c>; no picture of set 8), under "Your hub is
/// installed" with "Open Founderizer" and its line once the hub answers this PC (piece U3, the Mac's <c>afterInstall</c>);</item>
/// <item>an install that waits for the owner's yes at Tailscale: the join of the manager's own server, whose link the build
/// page has no place for (piece U3, the Mac's <c>MachineInstallRun.approve</c>; no picture of set 8);</item>
/// <item>"Connecting to your hub" in moving words until the window goes to the manager's setup by itself.</item>
/// </list>
/// The install's own page stands from the top of the window (picture 17: 104 under the title bar), as a form that can be
/// long; the build page stands in the middle. Picture 17's "Report a problem" opens the report form (set 11, piece U11),
/// which this build does not have: until then the stop has Try again alone, as the Mac's row has where it has no report
/// form (<c>MachineInstallRun.report</c> nil).</summary>
internal sealed class InstallPage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.Width);
    private readonly BuildView build;
    private readonly TextBlock warning = StepControls.Warning("");
    private PasteField? paste;
    private Button? again;
    /// <summary>The way on of checks that did not pass (Open Founderizer) or of Tailscale's link (Open link), for Enter.</summary>
    private Action? onwards;
    private string? mode, drawn;
    private CloudProvider? markOf;
    private bool quietMark;

    public InstallPage(StepHost host)
    {
        this.host = host;
        build = new BuildView(host);
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen screen)
    {
        var showsBuild = host.Store.ShowsBuild;
        var install = state.Install;
        var stopped = !install.Running && install.Failure is not null;
        var checkedDone = !install.Running && install.Checklist is not null;
        var next = showsBuild && state.ManagersToken is not null ? "managers-token"
            : showsBuild ? "build"
            : stopped && install.NeedsNetworkKey ? "network"
            : stopped ? "stop"
            : (install.NetworkSignIn ?? state.ManagerInstall.NetworkSignIn) is not null ? "approve"
            : checkedDone && !install.Passed ? "checks"
            : "wait";
        if (next == "managers-token")
        {
            var other = state.ManagersToken!.Value;
            if (markOf != other) { column.Mark = SetupParts.CloudTile(other, StepLook.Mark); markOf = other; quietMark = false; }
        }
        else if (!quietMark) { column.Mark = SetupParts.QuietMark(); quietMark = true; markOf = null; }
        column.Width = next == "build" ? BuildView.Width : StepLook.Width;
        // The install's own page stands from the top (picture 17); the others in the middle of the room.
        var top = next is "stop" or "network" or "checks" or "approve";
        column.VerticalAlignment = top ? VerticalAlignment.Top : VerticalAlignment.Center;
        column.Margin = new Thickness(0, top ? 104 : 0, 0, top ? 40 : 0);
        column.Show(screen.Title, next == "build" ? build.Waits(state) : screen.Waits, screen.Detail, host.ReduceMotion());
        var key = next + "|" + install.Failure + "|" + install.Steps.Count + "|" + string.Join(",", install.Steps.Select(s => s.Step + s.State)) +
                  "|" + state.Key.Made + "|" + state.Key.Busy + "|" + (install.Checklist?.Checks.Count ?? -1) +
                  "|" + string.Join(",", screen.Controls.Select(c => c.Id + c.Words));
        if (next != mode)
        {
            if (mode == "build") build.Tick(false);
            mode = next;
            drawn = null;
        }
        if (mode == "build")
        {
            if (drawn is null)
            {
                column.Controls.Children.Clear();
                column.Controls.Children.Add(build.Boxes);
                drawn = "build";
            }
            build.Show(state);
            return;
        }
        if (key != drawn)
        {
            drawn = key;
            Draw(state, screen);
        }
        warning.Text = screen.Warning ?? "";
        warning.Visibility = screen.Warning is null || mode is "stop" or "network" ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Draw(SetupState state, SetupScreen screen)
    {
        column.Controls.Children.Clear();
        paste = null;
        again = null;
        onwards = null;
        switch (mode)
        {
            case "managers-token":
                var steps = screen.Controls.FirstOrDefault(c => c.Kind == SetupControlKind.Steps);
                if (steps?.Lines is { } lines) column.Controls.Children.Add(SetupParts.Steps(lines, id: steps.Id));
                paste = new PasteField(SetupScreens.PasteHere, "first-run-managers-token", t => t.Length >= 20 && !t.Contains(' '),
                                       token => _ = host.Store.SendManagersTokenAsync(token));
                column.Controls.Children.Add(paste.Field);
                column.Controls.Children.Add(warning);
                break;
            case "stop":
                column.Controls.Children.Add(Stop(state.Install));
                break;
            case "network":
                column.Controls.Children.Add(Network(state, screen));
                break;
            case "checks":
                column.Controls.Children.Add(Checks(state.Install.Checklist!));
                if (screen.Controls.FirstOrDefault(c => c.Id == "first-run-open") is { } open)
                    column.Controls.Children.Add(OpenApp(open, screen.Controls.FirstOrDefault(c => c.Id == "first-run-open-line")));
                column.Controls.Children.Add(warning);
                break;
            case "approve":
                column.Controls.Children.Add(Approve(screen));
                column.Controls.Children.Add(warning);
                break;
            default:
                column.Controls.Children.Add(warning);
                break;
        }
    }

    /// <summary>**A stop with its words** (picture 17; the Mac's <c>MachineInstallRun.run</c> after a failure): "Your
    /// hub" over a card of each step that the installer reported, its state's mark and word (Done, Failed, or none while
    /// it runs); 22 under it the stop's card: the warning's mark, "The install stopped", what stopped in orange at 12, and
    /// under them at the right Try again (Report a problem beside it comes with the report form, piece U11).</summary>
    private StackPanel Stop(InstallView install)
    {
        var form = new StackPanel { Width = SetupParts.FormWidth, Spacing = 22, HorizontalAlignment = HorizontalAlignment.Center };
        if (install.Steps.Count > 0)
        {
            var section = new StackPanel();
            section.Children.Add(SetupParts.SectionTitle(SetupScreens.YourHub));
            section.Children.Add(SetupParts.Card(install.Steps.Select(step =>
            {
                var (glyph, word, brush) = step.State switch
                {
                    ProgressState.Done => (SetupParts.DoneGlyph, SetupViewWords.Done, Look.Muted),
                    ProgressState.Failed => (SetupParts.FailedGlyph, SetupViewWords.Failed, Look.Orange),
                    ProgressState.Waiting => (SetupParts.WaitingGlyph, SetupViewWords.Waiting, Look.Muted),
                    _ => (SetupParts.WaitingGlyph, "", Look.Muted),
                };
                var value = Look.Words(word, wrap: false);
                value.Foreground = brush;
                AutomationProperties.SetAutomationId(value, "install-step-" + step.Step + "-state");
                return new SetupParts.Row(glyph, step.Title, Accessory: word.Length == 0 ? null : value, Id: "install-step-" + step.Step);
            })));
            form.Children.Add(section);
        }
        again = StepControls.Primary(SetupScreens.TryAgain, "install-again");
        again.Click += (_, _) => host.Store.InstallAgain();
        var presses = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        presses.Children.Add(again);
        var card = SetupParts.Card([new SetupParts.Row(SetupParts.WarningGlyph, SetupViewWords.InstallStopped, Warning: install.Failure, Tall: true,
                                                       Id: "install-stopped")]);
        if (card.Child is StackPanel rows && rows.Children.LastOrDefault() is Grid row)
        {
            Grid.SetColumnSpan(presses, 2);
            Grid.SetColumn(presses, 1);
            row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(presses, 1);
            row.Children.Add(presses);
        }
        form.Children.Add(card);
        return form;
    }

    /// <summary>**A stop for the network's key** (the Mac's <c>MachineInstallRun.network</c>, with "PC"): the row of why
    /// with what this PC does and the words of Tailscale's refusal, then Tailscale's steps and the field of the access
    /// token, then Install again once a key is made.</summary>
    private StackPanel Network(SetupState state, SetupScreen screen)
    {
        var form = new StackPanel { Spacing = StepLook.Gap };
        var why = screen.Controls.FirstOrDefault(c => c.Id == "install-network-row");
        if (why is not null)
            form.Children.Add(SetupParts.Card([new SetupParts.Row(SetupParts.WarningGlyph, why.Words, why.Line, screen.Warning, Tall: true,
                                                                  DetailSize: 12, Id: why.Id)]));
        if (!state.Key.Busy)
        {
            form.Children.Add(SetupParts.Steps(SetupScreens.KeySteps, id: "install-network-key-steps"));
            paste = new PasteField(SetupScreens.PasteHere, "install-network-key", t => t.StartsWith("tskey-api-", System.StringComparison.Ordinal),
                                   token => _ = host.Store.SendKeyAsync(token));
            form.Children.Add(paste.Field);
        }
        if (screen.Controls.Any(c => c.Id == "install-again-key"))
        {
            again = StepControls.Primary(SetupScreens.InstallAgainWords, "install-again-key");
            again.Click += (_, _) => host.Store.InstallAgain();
            form.Children.Add(again);
        }
        return form;
    }

    /// <summary>**The checks that did not pass** (the Mac's <c>VerifyChecklistView</c>): "Checks" with its state word at
    /// the right, the summary, a row for each check with what it says and its fix, and the footer.</summary>
    private StackPanel Checks(VerifyChecklist checklist)
    {
        var form = new StackPanel { Width = SetupParts.FormWidth, HorizontalAlignment = HorizontalAlignment.Center };
        var head = new Grid();
        head.Children.Add(SetupParts.SectionTitle(SetupViewWords.Checks));
        var state = Look.Words(checklist.Checks.Count == 0 ? SetupViewWords.NotChecked : checklist.IsReady ? SetupViewWords.Ready : SetupViewWords.NotReady,
                               12, 16, checklist.IsReady ? Look.Green : Look.Orange, wrap: false);
        state.HorizontalAlignment = HorizontalAlignment.Right;
        AutomationProperties.SetAutomationId(state, "verify-line");
        head.Children.Add(state);
        form.Children.Add(head);
        form.Children.Add(new TextBlock { Text = checklist.Summary, FontSize = 12, Foreground = Look.Muted, Margin = new Thickness(2, 0, 0, 8), TextWrapping = TextWrapping.Wrap });
        form.Children.Add(SetupParts.Card(checklist.Checks.Select(check =>
        {
            var word = check.Failed ? SetupViewWords.Failed : check.Warned ? SetupViewWords.Warning : SetupViewWords.Ready;
            var value = Look.Words(word, 12, 16, check.Failed ? Look.Orange : check.Warned ? Look.Brush(global::Windows.UI.Color.FromArgb(255, 0xFF, 0xD6, 0x0A)) : Look.Muted, wrap: false);
            var glyph = check.Failed ? SetupParts.FailedGlyph : check.Warned ? SetupParts.WarningGlyph : SetupParts.DoneGlyph;
            return new SetupParts.Row(glyph, check.Title, check.Says, check.Passed ? null : check.Fix, value, Tall: true, DetailSize: 12, Id: "verify-" + check.Check);
        })));
        // The Mac's footer under the checks sends the owner to the server's own page ("check this server again from its
        // page"), which this PC has only with the servers' pages (piece U7): until then the page leaves that line out,
        // rather than say a way that is not there (plan v2, U3 and section 13).
        return form;
    }

    /// <summary>**"Open Founderizer" under checks that did not pass** (the Mac's <c>afterInstall</c> in its
    /// <c>SetupAction</c>): step 1's white button in the middle, and under it the muted line that says where the hub serves
    /// its pages, in the middle at 15. Its press goes on to the manager's setup (<see cref="SetupStore.OpenApp"/>).</summary>
    private StackPanel OpenApp(SetupControl open, SetupControl? line)
    {
        var way = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) };
        var press = StepControls.Primary(open.Words, open.Id);
        // A press only: the Mac's Open Founderizer is no default action of its page, so the page's Enter does not press
        // it (a keyboard focus on it still does: PARITY.md).
        press.Click += (_, _) => host.Store.OpenApp();
        way.Children.Add(press);
        if (line is not null) way.Children.Add(SetupParts.Quiet(line.Words, line.Id));
        return way;
    }

    /// <summary>**An install that waits for the owner's yes at Tailscale** (the Mac's <c>MachineInstallRun.approve</c>):
    /// one card of two rows, "Your server is not on your private network" with the warning's mark, then "Approve
    /// &lt;server&gt; in Tailscale" with the network's mark and Open link at its right. The press opens only the link that
    /// the model reads at the press, which is Tailscale's own sign-in page (<c>NetworkSignIn.Found</c>), in the default
    /// browser, so that a link that Tailscale gave again is the one that opens; the install goes on by itself once he
    /// approved it. Enter presses it (the Mac's <c>.defaultAction</c>).</summary>
    private Border Approve(SetupScreen screen)
    {
        var rows = screen.Controls.Where(c => c.Kind == SetupControlKind.Row).ToList();
        var press = StepControls.Primary(rows.Last().Lines?.FirstOrDefault() ?? SetupScreens.OpenLink, "install-network-sign-in-open");
        onwards = () =>
        {
            var now = host.Store.State;
            if ((now.Install.NetworkSignIn ?? now.ManagerInstall.NetworkSignIn)?.Url is { } link)
                _ = global::Windows.System.Launcher.LaunchUriAsync(link);
        };
        press.Click += (_, _) => onwards?.Invoke();
        return SetupParts.Card(rows.Select((row, at) => at == 0
            ? new SetupParts.Row(SetupParts.WarningGlyph, row.Words, Id: row.Id)
            : new SetupParts.Row(NetworkGlyph, row.Words, Accessory: press, MinHeight: 56, Id: row.Id)));
    }

    /// <summary>Segoe Fluent Icons' Globe, the Mac's <c>network</c> symbol of the row.</summary>
    private static readonly string NetworkGlyph = char.ConvertFromUtf32(0xE774);

    public bool Enter()
    {
        switch (mode)
        {
            case "build": return build.Enter();
            case "stop" or "network" when again is not null:
                host.Store.InstallAgain();
                return true;
            // Enter presses Open link (the Mac's `.defaultAction` of that row); the Mac's Open Founderizer has none, so Enter
            // does not press it.
            case "approve" when onwards is not null:
                onwards();
                return true;
            default: return paste?.Enter() ?? false;
        }
    }

    public void Left() => build.Tick(false);
}
