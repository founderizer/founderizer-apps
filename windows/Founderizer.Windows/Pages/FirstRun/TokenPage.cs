using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**A provider's pages** (the Mac's <c>token(_:)</c> of <c>FirstRunView</c>), one view for each state of the
/// page that the model gives (<see cref="SetupScreens.Token"/>):
/// <list type="bullet">
/// <item>**"Your Hetzner token"** (set 8, picture 10): the provider's logo at 48, the title, the provider's own steps over
/// the field, and the field that the token is pasted into, which takes 20 characters or more and no space, and sends
/// itself. The provider took a token once: the page never asks for it again (<c>TokenTaken</c>).</item>
/// <item>**"Your fleet"** (picture 11): in a step of 800, the fleet that the one press makes, each server's box with its
/// edge in dots and its combo box under it, and the press ("Make 2 servers"), with why the press made nothing over it.</item>
/// <item>The account's list, for an account that has servers (the Mac's <c>CloudChoice</c>; no picture of set 8): the
/// account's servers, then the new one, and the press.</item>
/// <item>The token of the manager's own provider (the Mac's <c>managersTokenFields</c>; no picture of set 8).</item>
/// <item>**"Building your fleet"** while the hub's server is made (picture 15: <see cref="BuildView"/>).</item>
/// </list>
/// "Servers in another project?", which the model gives for Hetzner, has no press in the model, and set 8 draws none: it
/// is not drawn.</summary>
internal sealed class TokenPage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.Width);
    private readonly BuildView build;
    private readonly FleetSelect hubSelect = new("first-run-fleet-hub");
    private readonly FleetSelect managersSelect = new("first-run-fleet-manager");
    private readonly ServerBoxes fleet = new();
    private readonly TextBlock warning = StepControls.Warning("");
    private PasteField? paste;
    private Button? press;
    private string? mode;
    private string? drawnFleet;
    private CloudProvider? markOf;
    private bool quietMark;

    public TokenPage(StepHost host)
    {
        this.host = host;
        build = new BuildView(host);
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen screen)
    {
        var provider = state.ManagersToken ?? state.TokenOf ?? CloudProvider.Hetzner;
        var building = state.CloudBuilds && state.Shaped;
        var choosing = state.Cloud?.Stage == CloudStep.Stage.Choosing;
        var showsFleet = state.ManagersToken is null && choosing && state.ShowsFleet;
        var next = building ? "build" : state.ManagersToken is not null ? "managers-token" : showsFleet ? "fleet" : choosing ? "list" : "token";
        if (building)
        {
            if (!quietMark) { column.Mark = SetupParts.QuietMark(); quietMark = true; markOf = null; }
        }
        else if (markOf != provider || quietMark)
        {
            column.Mark = SetupParts.CloudTile(provider, StepLook.Mark);
            markOf = provider;
            quietMark = false;
        }
        column.Width = next switch { "build" => BuildView.Width, "fleet" => 800, _ => StepLook.Width };
        column.Show(screen.Title, building ? build.Waits(state) : screen.Waits, building ? null : screen.Detail, host.ReduceMotion());
        if (next != mode)
        {
            if (mode == "build") build.Tick(false);
            mode = next;
            drawnFleet = null;
            Build(state, screen, provider);
        }
        switch (mode)
        {
            case "build": build.Show(state); break;
            case "fleet": ShowFleet(state, screen); break;
            case "list": ShowList(state, screen); break;
        }
        if (mode is "token" or "managers-token")
        {
            warning.Text = screen.Warning ?? "";
            warning.Visibility = screen.Warning is null ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    /// <summary>The page's controls for its state, made when the state comes.</summary>
    private void Build(SetupState state, SetupScreen screen, CloudProvider provider)
    {
        column.Controls.Children.Clear();
        paste = null;
        press = null;
        switch (mode)
        {
            case "build":
                column.Controls.Children.Add(build.Boxes);
                return;
            case "token" or "managers-token":
                var steps = screen.Controls.FirstOrDefault(c => c.Kind == SetupControlKind.Steps);
                var field = screen.Controls.FirstOrDefault(c => c.Kind == SetupControlKind.Paste);
                if (steps?.Lines is { } lines) column.Controls.Children.Add(SetupParts.Steps(lines, id: steps.Id));
                if (field is not null)
                {
                    var managers = mode == "managers-token";
                    paste = new PasteField(field.Words, field.Id, t => t.Length >= 20 && !t.Contains(' '),
                                           token => _ = managers ? host.Store.SendManagersTokenAsync(token) : host.Store.SendTokenAsync(token));
                    column.Controls.Children.Add(paste.Field);
                }
                column.Controls.Children.Add(warning);
                return;
        }
    }

    // ------------------------------------------------------------------ "Your fleet"

    private void ShowFleet(SetupState state, SetupScreen screen)
    {
        var shown = ManagerName.Shown(state.ManagerName);
        var name = ManagerName.AgentName(state.ManagerName) ?? ManagerName.Fallback;
        var hub = screen.Controls.FirstOrDefault(c => c.Id == "first-run-fleet-hub");
        var theirs = screen.Controls.FirstOrDefault(c => c.Id == "first-run-fleet-manager");
        var pressWords = screen.Controls.FirstOrDefault(c => c.Id == "cloud-choice-press")?.Words;
        var key = string.Join("|", state.ServersStep, name, shown, hub?.Line, theirs?.Line, pressWords, screen.Warning,
                              state.Cloud?.Choices.Count, state.ManagersCloud?.Choices.Count);
        if (key == drawnFleet) return;
        drawnFleet = key;
        foreach (var old in column.Controls.Children.OfType<Panel>()) if (old is not ServerBoxes) old.Children.Clear();
        column.Controls.Children.Clear();
        if (hub is null || pressWords is null)
        {
            // The offers are read: the title moves, and only a line of why shows.
            if (screen.Warning is not null) column.Controls.Children.Add(StepControls.Warning(screen.Warning));
            return;
        }
        var choices = new List<ServerBoxes.BoxChoice?>();
        if (state.Cloud is { } cloud)
        {
            hubSelect.Show(SetupScreens.YourHub, hub.Line ?? "", FleetSelect.Of(cloud, host.Holds, host.Store.ChooseOffer, host.Store.HubAt));
            choices.Add(new ServerBoxes.BoxChoice(hubSelect));
        }
        if (theirs is not null && state.ManagersCloud is { } managers)
        {
            managersSelect.Show(theirs.Words, theirs.Line ?? "", FleetSelect.Of(managers, host.Holds, host.Store.ChooseManagersOffer, host.Store.ManagersAt));
            choices.Add(new ServerBoxes.BoxChoice(managersSelect));
        }
        fleet.Draw(state.ServersStep, name, shown, null, choices);
        column.Controls.Children.Add(fleet);
        // Why the press made nothing, over the press (the Mac's FirstFleetChoice).
        if (screen.Warning is not null) column.Controls.Children.Add(StepControls.Warning(screen.Warning));
        press = StepControls.Primary(pressWords, "cloud-choice-press");
        press.Click += (_, _) => host.Store.MakeFleet();
        column.Controls.Children.Add(press);
    }

    // ------------------------------------------------------------------ the account's list

    /// <summary>**The account's servers and a new one** (the Mac's <c>CloudChoice</c> list): a row for each server of the
    /// account and the new server last, chosen by default, with what it costs, then the press. The model can make the new
    /// server and has no press yet to put the hub on a server of the account, so those rows stand grey, as the Mac's rows of
    /// servers that it cannot take.</summary>
    private void ShowList(SetupState state, SetupScreen screen)
    {
        var key = string.Join("|", screen.Controls.Select(c => c.Id + c.Words + c.Line + c.Marked)) + screen.Warning;
        if (key == drawnFleet) return;
        drawnFleet = key;
        column.Controls.Children.Clear();
        var made = screen.Controls.FirstOrDefault(c => c.Id == "cloud-choice-new");
        if (made is null)
        {
            if (screen.Warning is not null) column.Controls.Children.Add(StepControls.Warning(screen.Warning));
            return;
        }
        var rows = new List<SetupParts.Row>();
        foreach (var server in screen.Controls.Where(c => c.Kind == SetupControlKind.Card && c.Id != "cloud-choice-new"))
            rows.Add(new SetupParts.Row(Radio(false), server.Words, server.Line, MinHeight: 56, Id: server.Id, TitleSize: 14));
        rows.Add(new SetupParts.Row(Radio(true), SetupViewWords.NewServer, made.Words, MinHeight: 56, Id: made.Id));
        var card = SetupParts.Card(rows);
        // The account's own rows, grey: the model has no press to take one of them for the hub yet.
        if (card.Child is StackPanel list)
            for (int i = 0; i < list.Children.Count - 1; i++) if (list.Children[i] is Grid) list.Children[i].Opacity = 0.45;
        column.Controls.Children.Add(card);
        if (screen.Warning is not null) column.Controls.Children.Add(StepControls.Warning(screen.Warning));
        var words = screen.Controls.FirstOrDefault(c => c.Id == "cloud-choice-press")?.Words ?? "";
        press = StepControls.Primary(words, "cloud-choice-press");
        press.Click += (_, _) => host.Store.MakeFleet();
        column.Controls.Children.Add(press);
    }

    /// <summary>A row's mark of a choice: Windows' radio button, full or empty.</summary>
    private static string Radio(bool on) => char.ConvertFromUtf32(on ? 0xECCB : 0xECCA);

    public bool Enter()
    {
        switch (mode)
        {
            case "build": return build.Enter();
            case "fleet" or "list" when press is not null:
                host.Store.MakeFleet();
                return true;
            default: return paste?.Enter() ?? false;
        }
    }

    public void Left() => build.Tick(false);
}
