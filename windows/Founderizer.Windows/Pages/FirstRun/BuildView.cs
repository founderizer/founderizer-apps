using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**"Building your fleet"** (set 8, pictures 15 and 16; the Mac's <c>FleetBuildPage</c> and the first run's
/// <c>buildPage</c>): the first run's quiet mark, the title, which moves while something builds and stands when only the
/// owner's choice is left (<see cref="BuildRows.Waits"/>), and in a step of 700 the fleet as "Your fleet" drew it, each
/// server with its line under its box (<see cref="BuildRows"/>), its minutes read again every 20 seconds. After a refusal
/// of the manager's own server, its box has its edge in dots, and under it why, Hetzner's own way to more servers when
/// Hetzner's account had no room, its combo box, and the press that makes it. No Back and no steps while it builds (the
/// frame's).</summary>
internal sealed class BuildView
{
    public const double Width = 700;
    private readonly StepHost host;
    private readonly ServerBoxes boxes = new();
    private readonly FleetSelect managersSelect = new("first-run-build-manager");
    private readonly Button managersPress;
    private readonly Button moreLink;
    private readonly StackPanel moreSteps = new() { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
    private DispatcherQueueTimer? clock;
    private string? drawn;
    private SetupState? state;
    private bool choiceOpen;

    public BuildView(StepHost host)
    {
        this.host = host;
        managersPress = StepControls.Primary("", "first-run-build-manager-press");
        managersPress.Click += (_, _) => host.Store.MakeManagersServerAgain();
        moreLink = StepControls.Link(SetupScreens.HetznerMore, "first-run-build-more");
        moreLink.Click += (_, _) => host.Store.ShowManagersMore();
        moreSteps.Children.Add(SetupParts.Steps(SetupScreens.HetznerMoreSteps, 270));
        var note = Look.Words(SetupScreens.HetznerMoreNote, 12, 16, Look.Muted);
        note.TextAlignment = TextAlignment.Center;
        note.MaxWidth = 270;
        moreSteps.Children.Add(note);
    }

    /// <summary>The boxes, with their lines and the manager's choice.</summary>
    public FrameworkElement Boxes => boxes;

    /// <summary>The title moves while something builds; with only the owner's choice left it stands.</summary>
    public bool Waits(SetupState s) => BuildRows.Waits(s, host.Store.ManagersChoiceOpen);

    public void Show(SetupState s)
    {
        state = s;
        choiceOpen = host.Store.ManagersChoiceOpen;
        var shown = ManagerName.Shown(s.ManagerName);
        var name = ManagerName.AgentName(s.ManagerName) ?? ManagerName.Fallback;
        var rows = BuildRows.Of(s, choiceOpen, DateTimeOffset.UtcNow);
        var why = choiceOpen ? s.ManagersRefusal ?? s.ManagersCloud?.Failure : null;
        var more = choiceOpen && s.ManagersFull.Contains(CloudProvider.Hetzner) &&
                   why == new CloudException(CloudFailure.Full, CloudProvider.Hetzner).Message;
        var options = choiceOpen && s.ManagersCloud is { } m ? FleetSelect.Of(m, host.Holds, host.Store.ChooseManagersOffer, host.Store.ManagersAt) : [];
        var key = string.Join("|", s.ServersStep, name, shown, choiceOpen, why, more, s.ManagersMoreShown, options.Count, s.ManagersCloud?.Offer?.Key);
        if (key != drawn)
        {
            drawn = key;
            IReadOnlyList<ServerBoxes.BoxChoice?>? choices = null;
            if (choiceOpen && s.ManagersCloud?.Offer is { } offer)
            {
                managersSelect.Show(SetupScreens.ManagersServer(shown), offer.Pick(), options);
                var press = SetupScreens.MakeManagersServer(shown);
                if (managersPress.Content is Border { Child: TextBlock label }) label.Text = press;
                AutomationProperties.SetName(managersPress, press);
                FrameworkElement? extra = more ? s.ManagersMoreShown ? moreSteps : moreLink : null;
                choices = [null, new ServerBoxes.BoxChoice(managersSelect, why, managersPress, extra)];
            }
            boxes.Draw(s.ServersStep, name, shown, rows, choices);
        }
        else boxes.Lines(rows);
        Tick(true);
    }

    /// <summary>The minutes go down within a long step too: the lines are read again every 20 seconds while the page
    /// shows (the Mac's <c>TimelineView(.periodic(by: 20))</c>).</summary>
    public void Tick(bool on)
    {
        if (!on) { clock?.Stop(); return; }
        if (clock is null)
        {
            clock = host.Queue.CreateTimer();
            clock.Interval = TimeSpan.FromSeconds(20);
            clock.IsRepeating = true;
            clock.Tick += (_, _) => { if (state is { } s) boxes.Lines(BuildRows.Of(s, choiceOpen, DateTimeOffset.UtcNow)); };
        }
        if (!clock.IsRunning) clock.Start();
    }

    /// <summary>Enter on the build page: the press of the manager's server, while it shows.</summary>
    public bool Enter()
    {
        if (!choiceOpen) return false;
        host.Store.MakeManagersServerAgain();
        return true;
    }
}
