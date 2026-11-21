using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.Install;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.FirstRun;

/// <summary>The kinds of a page's controls.</summary>
public enum SetupControlKind
{
    /// <summary>A choice as a card: a mark, a name and one short line; <c>Marked</c> has the check mark.</summary>
    Card,
    /// <summary>The page's one way on (a white button), or Try again.</summary>
    Button,
    /// <summary>A quiet link of muted words.</summary>
    Link,
    /// <summary>A field for words that the owner types; <c>Words</c> is its placeholder.</summary>
    Field,
    /// <summary>A field that a key or a token is pasted into, which sends a paste by itself.</summary>
    Paste,
    /// <summary>A field that shows no character (a password, a passphrase).</summary>
    Secret,
    /// <summary>Numbered steps over a field: each a line of <c>Lines</c>, a link written as <c>[words](address)</c>.</summary>
    Steps,
    /// <summary>A line with a green check.</summary>
    Checked,
    /// <summary>A muted line.</summary>
    Muted,
    /// <summary>A form's row: its title, its detail (<c>Line</c>) and the words of its own button (<c>Lines</c>), or none.</summary>
    Row,
    /// <summary>An orange line under the control before it.</summary>
    Warning,
}

/// <summary>One control of a page: its kind, its words, its id for the window, its line, whether it has the check mark.</summary>
public sealed record SetupControl(SetupControlKind Kind, string Words, string Id, string? Line = null, bool Marked = false,
                                  IReadOnlyList<string>? Lines = null);

/// <summary>**One page of the first run, as the window draws it** (the Mac's <c>SetupStep</c> with its title, its line,
/// its form and its orange line): its name, its title (which moves while <c>Waits</c>), the muted line under the title,
/// the controls in their order, the one orange line, whether it has Back, and the steps on Back's line.</summary>
public sealed record SetupScreen(string Name, string Title, bool Waits, string? Detail, IReadOnlyList<SetupControl> Controls, string? Warning,
                                 bool Back, SetupProgress? Progress);

/// <summary>**The pages of the first run, from the state** (as <c>Screens</c> gives step 1's pages): the Mac's words with
/// "PC" for "Mac" (rule 14 of the plan), each sentence from here. The window adds the marks and the motion.</summary>
public static class SetupScreens
{
    // ---------------------------------------------------------------- the words of the pages

    public const string WelcomeTitle = "Your own team of AI agents";
    public const string SetItUp = "Set it up yourself", StepByStep = "Step by step";
    /// <summary>W8, the link from the welcome page to Add this PC (the owner's yes of 20 November 2026 to set 8).</summary>
    public const string AddThisPc = "Add this PC";
    public const string ReportsTitle = "Help improve Founderizer";
    public const string ReportsDetail = "Sends error codes, versions and counts to Founderizer. Never your work, names or keys.";
    public const string SendReports = "Send anonymous usage data", DontSend = "Don't send";
    public const string ReportsLater = "You can change this later in Settings › Help.", Privacy = "Privacy";
    public static readonly Uri PrivacyPage = new("https://platform.founderizer.com/privacy#error-reports");
    public const string NameTitle = "Name your manager", NameDetail = "It leads your team and is your main assistant.", NamePlaceholder = "Name";
    public const string Continue = "Continue";
    public const string ServersTitle = "Your fleet's servers", ServersDetail = "Fewer servers cost less. More servers keep your agents apart.";
    public const string LowerCost = "Lower cost", MoreSecure = "More secure";
    public const string ConnectTailscale = "Connect Tailscale", WaitingForTailscale = "Waiting for Tailscale", Connect = "Connect",
                        OpenTailscaleAgain = "Open Tailscale again";
    public const string KeyTitle = "Your Tailscale key", KeyBusy = "Connecting your network", PasteHere = "Paste it here";
    public const string CloudTitle = "A VPS for your fleet", OtherVps = "Other VPS", AnyServer = "Any server by SSH";
    public const string BuildingTitle = "Building your fleet", FleetTitle = "Your fleet", YourHub = "Your hub";
    public const string AnotherProject = "Servers in another project?";
    public const string VpsTitle = "Your VPS", Address = "Address", Password = "Password", Install = "Install", TryAgain = "Try again";
    /// <summary>The line under the password's field (W9: "PC" for "Mac"), and under the passphrase's (W14).</summary>
    public const string UsedOnce = "Used once, to add this PC's key. Never kept.";
    /// <summary>**The owner's key once** (the Mac's <c>MachineInstallForm</c> row "SSH key" with "Choose key" and "Change",
    /// and its row "Your key never leaves this Mac", with "PC"; the owner's "Choose key, as Mac" and his "Yes, as shown"
    /// to picture 13d with W14, the passphrase's field and its line).</summary>
    public const string SshKey = "SSH key", ChooseKeyWords = "Choose key", Change = "Change", KeyNeverLeaves = "Your key never leaves this PC";
    public const string PassphrasePlaceholder = "Passphrase";
    /// <summary>A passphrase that does not open the key: the line of picture 13d's second state, which the owner saw with his
    /// "Yes, as shown". A file that is no key that the app reads: the words of L1a's check, new words of the PC, which go
    /// to the owner with wave A's built pictures (not his yet).</summary>
    public const string NotAKey = "This app cannot read that file as an SSH private key.";
    public const string WrongPassphrase = "That passphrase does not open this key.";
    public const string HubDidNotInstall = "Your hub did not install", ConnectingToHub = "Connecting to your hub", HubInstalled = "Your hub is installed";
    public const string CheckingFleet = "Checking your fleet";
    public const string InstallAgainWords = "Install again";
    /// <summary>The row of an install that stopped for the network's key (the Mac's <c>MachineInstallRun.network</c>,
    /// with "PC").</summary>
    public const string NotOnNetwork = "Your server is not on your private network";
    public const string ConnectThenInstall = "Connect your network, then install again. This PC makes the key: used once, worthless in fifteen minutes.";

    /// <summary>The steps of the fleet's Tailscale key (the Mac's <c>SetupSteps.tailscaleKey</c>).</summary>
    public static IReadOnlyList<string> KeySteps =>
        [$"Open [Keys]({TailscaleApi.KeysPage.OriginalString}) in Tailscale", "Generate access token, then copy it"];

    /// <summary>A provider's token in its own words (the Mac's <c>SetupSteps.token</c>).</summary>
    public static IReadOnlyList<string> TokenSteps(CloudProvider provider)
    {
        var page = provider.TokenPage().OriginalString;
        return provider switch
        {
            CloudProvider.Hetzner => [$"Open your project in [Hetzner Console]({page})", "Security › API tokens › Generate API token",
                                      "Choose Read & Write, then copy the token"],
            CloudProvider.DigitalOcean => [$"Open [API]({page}) in DigitalOcean", "Generate New Token with Full Access", "Copy the token"],
            CloudProvider.Vultr => [$"Open [API]({page}) in Vultr", "Enable API, then copy the key"],
            _ => [$"Open [API Tokens]({page}) in Akamai", "Create a Personal Access Token", "Set Linodes and Firewalls to Read/Write",
                  "Create Token, then copy it"],
        };
    }

    /// <summary>The line of a provider's card on the VPS page.</summary>
    public static string CardLine(CloudProvider provider) => provider switch
    {
        CloudProvider.Hetzner => "Best price",
        CloudProvider.DigitalOcean => "Simple to use",
        CloudProvider.Vultr => "Many regions",
        _ => "Formerly Linode",
    };

    public static string AiTitle(string name) => $"{name}'s AI provider";
    public static string AiDetail(string name) => $"The AI that {name} works with. You sign in with your own account.";
    public static string TokenTitle(CloudProvider provider) => $"Your {provider.Name()} token";
    public static string HubServerAt(CloudProvider provider) => $"Your hub's server at {provider.Name()}";
    public static string Checking(string host) => $"Checking {host}";
    public static string WaitingFor(string host) => $"Waiting for {host}";
    public static string PasswordFor(string user, string host) => $"Password for {user}@{host}";
    public static string ManagersServer(string name) => $"{name}'s server";
    public static string MakeManagersServer(string name) => $"Make {name}'s server";
    public static string MakingAt(CloudProvider provider) => $"Making your server at {provider.Name()}";

    /// <summary>Hetzner's own way to more servers, under the refusal of an account with no room.</summary>
    public static string HetznerMore => $"How to get more servers at {CloudProvider.Hetzner.Name()}";
    public static IReadOnlyList<string> HetznerMoreSteps =>
        [$"Open [Hetzner Console]({CloudProvider.Hetzner.TokenPage().OriginalString})", "Limits › Request change › Limit increase",
         $"When {CloudProvider.Hetzner.Name()} says yes, make the server again"];
    public const string HetznerMoreNote = "Hetzner answers by hand, in its business hours. An account younger than a month cannot ask yet.";

    // ---------------------------------------------------------------- the pages

    /// <summary>The page that the state shows now.</summary>
    public static SetupScreen Of(SetupState s, bool runs = false, bool showsBuild = false, CultureInfo? culture = null) => s.Page switch
    {
        SetupPage.Welcome => Welcome(),
        SetupPage.ErrorReports => Reports(s),
        SetupPage.Name => Name(s),
        SetupPage.AiProvider => Ai(s),
        SetupPage.Servers => Servers(s),
        SetupPage.Network => Network(s),
        SetupPage.Key => Key(s),
        SetupPage.Cloud => Cloud(s),
        SetupPage.Token => Token(s, culture),
        SetupPage.Vps => Vps(s),
        SetupPage.Installing => Installing(s, runs, showsBuild),
        _ => new SetupScreen("done", CheckingFleet, true, null, [], null, true, null),
    };

    /// <summary>The welcome page: the team, its title, its one way, and W8.</summary>
    public static SetupScreen Welcome() =>
        new("welcome", WelcomeTitle, false, null,
            [new(SetupControlKind.Card, SetItUp, "first-run-set-up", StepByStep), new(SetupControlKind.Link, AddThisPc, "first-run-add-this-pc")],
            null, false, null);

    public static SetupScreen Reports(SetupState s) =>
        new("errorReports", ReportsTitle, false, ReportsDetail,
            [new(SetupControlKind.Card, SendReports, "first-run-reports-send", Marked: s.SendsReports == true),
             new(SetupControlKind.Card, DontSend, "first-run-reports-none", Marked: s.SendsReports == false),
             new(SetupControlKind.Muted, ReportsLater, "first-run-reports-later", Privacy)],
            null, true, s.Progress);

    /// <summary>Continue shows only for a name that the hub's installer takes; the field's edge is orange for another.</summary>
    public static SetupScreen Name(SetupState s)
    {
        var controls = new List<SetupControl> { new(SetupControlKind.Field, NamePlaceholder, "first-run-name", Marked: s.ManagerName.Length > 0 && Founderizer.Setup.Install.ManagerName.AgentName(s.ManagerName) is null) };
        if (Founderizer.Setup.Install.ManagerName.AgentName(s.ManagerName) is not null) controls.Add(new(SetupControlKind.Button, Continue, "first-run-name-continue"));
        return new SetupScreen("name", NameTitle, false, NameDetail, controls, null, true, s.Progress);
    }

    public static SetupScreen Ai(SetupState s)
    {
        var shown = Founderizer.Setup.Install.ManagerName.Shown(s.ManagerName);
        return new SetupScreen("aiProvider", AiTitle(shown), false, AiDetail(shown),
            SetupStore.AiChoices.Select(p => new SetupControl(SetupControlKind.Card, Agents.SignIn.ProviderName(p), "first-run-ai-" + p, Marked: s.AiProvider == p)).ToList(),
            null, true, s.Progress);
    }

    /// <summary>The slider's page: its two ends, its three steps, the card of the chosen step, Continue.</summary>
    public static SetupScreen Servers(SetupState s) =>
        new("servers", ServersTitle, false, ServersDetail,
            [new(SetupControlKind.Muted, LowerCost, "first-run-servers-lower"), new(SetupControlKind.Muted, MoreSecure, "first-run-servers-more"),
             .. ServersSteps.All.Select(step => new SetupControl(SetupControlKind.Card, ServersSketch.Words(step), "first-run-servers-" + step.Raw(),
                                                                  Marked: step == s.ServersStep)),
             new(SetupControlKind.Muted, s.ServersStep.Fact(), "first-run-servers-fact", s.ServersStep.Risk()),
             new(SetupControlKind.Button, Continue, "first-run-servers-continue")],
            null, true, s.Progress);

    public static SetupScreen Network(SetupState s)
    {
        var controls = new List<SetupControl>();
        if (!s.Network.Busy)
            controls.Add(s.Network.Pressed ? new(SetupControlKind.Link, OpenTailscaleAgain, "first-run-network-again")
                                           : new(SetupControlKind.Button, Connect, "first-run-network-connect"));
        return new SetupScreen("network", s.Network.Pressed ? WaitingForTailscale : ConnectTailscale, s.Network.Pressed, null, controls,
                               s.Network.Failure, true, s.Progress);
    }

    public static SetupScreen Key(SetupState s)
    {
        var controls = new List<SetupControl>();
        if (!s.Key.Busy)
        {
            controls.Add(new(SetupControlKind.Steps, "", "first-run-key-steps", Lines: KeySteps));
            controls.Add(new(SetupControlKind.Paste, PasteHere, "first-run-tailscale-key"));
        }
        if (s.Key is { LinesToAdd: { } lines, Asks: { } asks })
            controls.Add(new(SetupControlKind.Muted, asks, "first-run-key-lines", lines));
        return new SetupScreen("key", s.Key.Busy ? KeyBusy : KeyTitle, s.Key.Busy, null, controls, s.Key.Failure, true, s.Progress);
    }

    public static SetupScreen Cloud(SetupState s) =>
        new("cloud", CloudTitle, false, null,
            [.. CloudProviders.All.Select(p => new SetupControl(SetupControlKind.Card, p.Name(), "first-run-cloud-" + p.Raw(), CardLine(p))),
             new(SetupControlKind.Card, OtherVps, "first-run-cloud-other", AnyServer)],
            null, true, s.Progress);

    /// <summary>**A provider's page**: its token's steps and field, then "Your fleet" (an account with no server) or the
    /// account's list, and the build page while its server is made.</summary>
    public static SetupScreen Token(SetupState s, CultureInfo? culture = null)
    {
        var provider = s.TokenOf ?? CloudProvider.Hetzner;
        var cloud = s.Cloud;
        var building = s.CloudBuilds;
        var choosing = cloud?.Stage == CloudStep.Stage.Choosing;
        var managersWait = s.ShowsFleet && s.MakesManagersServer && s.ManagersCloud?.Offer is null;
        var waits = building || (choosing && (cloud?.Offer is null || managersWait));
        if (s.ManagersToken is { } other)
            return new SetupScreen("token", TokenTitle(other), s.ManagersCloud?.Stage == CloudStep.Stage.Choosing, null,
                [new(SetupControlKind.Steps, "", "first-run-managers-token-steps", Lines: TokenSteps(other)),
                 new(SetupControlKind.Paste, PasteHere, "first-run-managers-token")],
                s.ManagersCloud?.Failure, true, s.Progress);
        if (building)
            return new SetupScreen("building", BuildingTitle, true,
                                   cloud?.Stage == CloudStep.Stage.Joining ? "Starting your server" : MakingAt(provider), [], null, false, null);
        var title = choosing || cloud?.TokenTaken == true ? (s.ShowsFleet ? FleetTitle : HubServerAt(provider)) : TokenTitle(provider);
        var controls = new List<SetupControl>();
        if (choosing && s.ShowsFleet)
        {
            if (cloud?.Offer is { } offer && (!s.MakesManagersServer || s.ManagersCloud?.Offer is not null))
            {
                controls.Add(new(SetupControlKind.Card, YourHub, "first-run-fleet-hub", offer.Pick(culture)));
                if (s.MakesManagersServer && s.ManagersCloud?.Offer is { } theirs)
                    controls.Add(new(SetupControlKind.Card, ManagersServer(Founderizer.Setup.Install.ManagerName.Shown(s.ManagerName)), "first-run-fleet-manager", theirs.Pick(culture)));
                controls.Add(new(SetupControlKind.Button, s.ServersStep.FirstPress(), "cloud-choice-press"));
                if (provider == CloudProvider.Hetzner) controls.Add(new(SetupControlKind.Link, AnotherProject, "cloud-choice-project"));
            }
        }
        else if (choosing)
        {
            if (cloud?.Offer is { } offer)
            {
                controls.Add(new(SetupControlKind.Card, offer.Row(culture), "cloud-choice-new", Marked: cloud.Chosen is null));
                foreach (var server in cloud.Existing)
                    controls.Add(new(SetupControlKind.Card, server.Name, "cloud-choice-" + server.Id, server.Summary, cloud.Chosen == server.Id));
                controls.Add(new(SetupControlKind.Button, cloud.Chosen is null ? "Make the server" : "Use this server", "cloud-choice-press"));
                if (provider == CloudProvider.Hetzner) controls.Add(new(SetupControlKind.Link, AnotherProject, "cloud-choice-project"));
            }
        }
        else if (cloud?.TokenTaken != true)
        {
            controls.Add(new(SetupControlKind.Steps, "", "first-run-cloud-token-steps", Lines: TokenSteps(provider)));
            controls.Add(new(SetupControlKind.Paste, PasteHere, "first-run-cloud-token"));
        }
        var warning = cloud?.Failure;
        if (choosing && s.ShowsFleet && s.MakesManagersServer && s.ManagersCloud is { Offer: null, Failure: { } theirs2 } && theirs2 != warning)
            warning ??= theirs2;
        return new SetupScreen("token", title, waits, null, controls, warning, true, s.Progress);
    }

    /// <summary>**Other VPS**: the address, the check's wait, the password once, Install with what changes, or a stop.</summary>
    public static SetupScreen Vps(SetupState s)
    {
        var v = s.Vps;
        return v.Phase switch
        {
            VpsPhase.Address => new("vps", VpsTitle, false, null, [new(SetupControlKind.Field, Address, "first-run-vps-address")], null, true, s.Progress),
            VpsPhase.Checking => new("vps", Checking(v.Host), true, null, [], null, true, s.Progress),
            VpsPhase.Waiting => new("vps", WaitingFor(v.Host), true, null, [new(SetupControlKind.Muted, v.Why ?? "", "first-run-vps-wait")], null, true, s.Progress),
            VpsPhase.Password => new("vps", PasswordFor(v.Target?.User ?? "root", v.Host), false, null,
                                     [new(SetupControlKind.Secret, Password, "first-run-vps-password"), new(SetupControlKind.Muted, UsedOnce, "first-run-vps-used-once"),
                                      .. v.TakesKey ? KeyControls(v) : []],
                                     null, true, s.Progress),
            VpsPhase.Ready => new("vps", v.Host, false, null,
                                  [new(SetupControlKind.Checked, v.Summary ?? "", "first-run-vps-summary"), new(SetupControlKind.Button, Install, "first-run-vps-install"),
                                   new(SetupControlKind.Muted, v.Changes ?? "", "first-run-vps-changes")],
                                  null, true, s.Progress),
            VpsPhase.Stopped when v.TakesKey => new("vps", v.Host, false, null, KeyControls(v), v.Why, true, s.Progress),
            _ => new("vps", v.Host, false, null, [new(SetupControlKind.Button, TryAgain, "first-run-vps-again")], v.Why, true, s.Progress),
        };
    }

    /// <summary>**The key's card** (picture 13d), on the stop of a server that takes keys only and under the password's
    /// field and its line on the password's page of an SSH password (the owner's "Key row here too", picture 14b, W15):
    /// the key's row with its file's name and Choose key or Change, the row "Your key never leaves this PC", and only for
    /// a key with a passphrase its one field and its line (W14); the sentence of a file that is no key, of a wrong
    /// passphrase, or of a key that the server refused, under them.</summary>
    private static IReadOnlyList<SetupControl> KeyControls(VpsView v)
    {
        var controls = new List<SetupControl>
        {
            new(SetupControlKind.Row, SshKey, "first-run-vps-key", v.KeyName, Lines: [v.KeyName is null ? ChooseKeyWords : Change]),
            new(SetupControlKind.Row, KeyNeverLeaves, "first-run-vps-key-stays"),
        };
        if (v.KeyAsksPassphrase)
        {
            controls.Add(new(SetupControlKind.Secret, PassphrasePlaceholder, "first-run-vps-passphrase"));
            controls.Add(new(SetupControlKind.Muted, UsedOnce, "first-run-vps-passphrase-used-once"));
        }
        if (v.KeyWarning is { } warning) controls.Add(new(SetupControlKind.Warning, warning, "first-run-vps-key-warning"));
        return controls;
    }

    /// <summary>**The build page or the install's own page** (the Mac's <c>machineHead</c>): a stop has a true title, and
    /// the moving title stands until the app goes on by itself.</summary>
    public static SetupScreen Installing(SetupState s, bool runs, bool showsBuild)
    {
        var i = s.Install;
        if (showsBuild && s.ManagersToken is { } other)
            return new SetupScreen("installing", TokenTitle(other), s.ManagersCloud?.Stage == CloudStep.Stage.Choosing, null,
                [new(SetupControlKind.Steps, "", "first-run-managers-token-steps", Lines: TokenSteps(other)),
                 new(SetupControlKind.Paste, PasteHere, "first-run-managers-token")],
                s.ManagersCloud?.Failure, !runs, null);
        if (showsBuild) return new SetupScreen("installing", BuildingTitle, true, null, [], null, !runs, null);
        var checkedDone = !i.Running && i.Checklist is not null;
        var stopped = !i.Running && i.Failure is not null;
        if (stopped && i.NeedsNetworkKey)
        {
            var network = new List<SetupControl>
            {
                new(SetupControlKind.Muted, NotOnNetwork, "install-network-row", ConnectThenInstall),
                new(SetupControlKind.Steps, "", "install-network-key-steps", Lines: KeySteps),
                new(SetupControlKind.Paste, PasteHere, "install-network-key"),
            };
            if (s.Key.Made) network.Add(new(SetupControlKind.Button, InstallAgainWords, "install-again-key"));
            return new SetupScreen("installing", HubDidNotInstall, s.Key.Busy, null, network, i.NetworkFailure ?? s.Key.Failure, !runs, null);
        }
        var title = stopped ? HubDidNotInstall : checkedDone ? (s.HandedOver ? HubInstalled : ConnectingToHub) : BuildingTitle;
        var controls = stopped ? new List<SetupControl> { new(SetupControlKind.Button, TryAgain, "first-run-install-again") } : [];
        return new SetupScreen("installing", title, i.Running || checkedDone && !s.HandedOver, null, controls, i.Failure, !runs, null);
    }
}
