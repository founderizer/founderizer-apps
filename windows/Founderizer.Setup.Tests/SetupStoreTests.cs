using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Remote;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Founderizer.Setup.Network;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The first run as a model** (windows-app-plan-v2.md, piece L4), on a stand-in PC: the order of its pages, the
/// one press that makes every server, the records that Start again deletes by, and the manager's name for the hub.</summary>
[TestClass]
public sealed class SetupStoreTests
{
    /// <summary>**A PC that is on a tailnet, with the fleet's key in its box, goes from the slider straight to the VPS
    /// page, and a provider whose token it holds opens its choice at once.** Bug: a network page or a key page that shows
    /// every time, which would send an owner with Tailscale to install it again, or ask for a second access token.</summary>
    [TestMethod]
    public async Task A_PC_on_a_tailnet_with_a_fleet_key_has_no_network_page_and_no_key_page()
    {
        await using var rig = new SetupRig();
        rig.ThroughTheFirstPages();
        Assert.AreEqual(SetupPage.Cloud, rig.Store.State.Page);
        rig.Store.ChooseProvider(CloudProvider.Hetzner);
        var s = await rig.Until(x => x.Cloud?.Offer is not null, "the hub's offer");
        Assert.AreEqual((SetupPage.Token, CloudProvider.Hetzner), (s.Page, s.TokenOf));
        Assert.AreEqual(new[] { "Manager", "AI provider", "Servers", "Network", "VPS", "Build" }.Length, s.Progress!.Names.Count);
        Assert.AreEqual(4, s.Progress.Current, "the token page is the step VPS");

        // On a tailnet with no fleet key in the box: the key's page, once, before the VPS page.
        await using var keyless = new SetupRig();
        keyless.Net.IsHeld = false;
        keyless.ThroughTheFirstPages();
        Assert.AreEqual(SetupPage.Key, keyless.Store.State.Page);
        await keyless.Store.SendKeyAsync("tskey-api-kEXAMPLE06-NOTAKEYNOTAKEY");
        Assert.AreEqual(SetupPage.Cloud, keyless.Store.State.Page);
    }

    /// <summary>**A PC on no tailnet gets Connect Tailscale first, and the key's page next while its box holds no fleet
    /// key; each goes on by itself to the card that was pressed.** Bug: a VPS page that a PC off the network reaches,
    /// whose install then cannot claim the hub at its private address; or a key page that ends on the VPS page when the
    /// owner had pressed a provider's card.</summary>
    [TestMethod]
    public async Task A_PC_off_the_network_gets_the_network_page_then_the_key_page_then_the_card_it_pressed()
    {
        await using var rig = new SetupRig();
        rig.Status.Connected = false;
        rig.Net.IsHeld = false;
        rig.ThroughTheFirstPages();
        Assert.AreEqual(SetupPage.Network, rig.Store.State.Page);
        Assert.AreEqual(3, rig.Store.State.Progress!.Current, "the network page is the step Network");
        rig.Store.PressConnect();
        Assert.AreEqual(SetupScreens.WaitingForTailscale, SetupScreens.Of(rig.Store.State).Title);
        rig.Status.Connected = true;
        rig.Store.ReadPc(rig.Status.Json());
        Assert.AreEqual(SetupPage.Key, rig.Store.State.Page, "no fleet key: the key's page comes after the network");
        await rig.Store.SendKeyAsync("tskey-api-kEXAMPLE05-NOTAKEYNOTAKEY");
        Assert.AreEqual(SetupPage.Cloud, rig.Store.State.Page);

        // The card that was pressed while the PC was off the network is the page that comes.
        await using var other = new SetupRig();
        other.Status.Connected = false;
        other.ThroughTheFirstPages();
        other.Store.Back();
        Assert.AreEqual(SetupPage.Servers, other.Store.State.Page, "Back from the network page goes to the slider");
        other.Store.ChooseServers();
        other.Store.Back();
        other.Store.ChooseServers();
        Assert.AreEqual(SetupPage.Network, other.Store.State.Page);
        other.Status.Connected = true;
        other.Store.ReadPc(other.Status.Json());
        Assert.AreEqual(SetupPage.Cloud, other.Store.State.Page);
        other.Status.Connected = false;
        other.Store.ReadPc(other.Status.Json());
        other.Store.ChooseProvider(CloudProvider.Hetzner);
        Assert.AreEqual(SetupPage.Network, other.Store.State.Page);
        other.Status.Connected = true;
        other.Store.ReadPc(other.Status.Json());
        Assert.AreEqual((SetupPage.Token, CloudProvider.Hetzner), (other.Store.State.Page, other.Store.State.TokenOf));
    }

    /// <summary>**One press makes every server of the fleet: the hub's and, on 2 servers, the manager's own; a second
    /// press while they are made makes nothing.** And the hub's installer gets the manager's name in the installer's
    /// form. Bugs: a press that makes only the hub's server (the manager's setup then asks for a VPS again), a double
    /// press that rents two of each, and "Juno" sent as typed, which the installer leaves out so that the manager is
    /// named "manager".</summary>
    [TestMethod]
    public async Task One_press_makes_every_server_and_never_two_builds_at_once()
    {
        await using var rig = new SetupRig();
        rig.ThroughTheFirstPages(ServersStep.Two, "Juno");
        rig.Store.ChooseProvider(CloudProvider.Hetzner);
        await rig.Until(x => x.Cloud?.Offer is not null && x.ManagersCloud?.Offer is not null, "both offers");
        var screen = SetupScreens.Of(rig.Store.State);
        Assert.AreEqual(SetupScreens.FleetTitle, screen.Title);
        Assert.AreEqual("Make 2 servers", screen.Controls.Single(c => c.Kind == SetupControlKind.Button).Words);

        Assert.IsTrue(rig.Store.MakeFleet());
        Assert.IsFalse(rig.Store.MakeFleet(), "a second press while the build runs makes nothing");
        await rig.Until(x => x.ManagersServer?.Address is not null && x.Install.Checklist is not null, "both servers and the hub's install");

        var hetzner = rig.Clouds[CloudProvider.Hetzner];
        CollectionAssert.AreEqual(new[] { CloudServerUse.Hub, CloudServerUse.Agent }, hetzner.Orders.Select(o => o.Use).ToList());
        Assert.AreEqual(2, hetzner.Orders.Select(o => o.Name).Distinct().Count(), "two servers of two names");
        Assert.IsTrue(rig.Clouds.Where(c => c.Key != CloudProvider.Hetzner).All(c => c.Value.Orders.Count == 0));

        var hub = rig.Plans.First();
        Assert.IsTrue(hub.Steps.Any(), "a hub plan ran");
        Assert.IsTrue(rig.Remote.Calls.Any(c => c.Program.Contains("--manager-name juno", StringComparison.Ordinal)),
                      "the installer gets the name in the installer's form");
        Assert.IsFalse(rig.Remote.Calls.Any(c => c.Program.Contains("--manager-name Juno", StringComparison.Ordinal)));
        Assert.AreEqual(1, rig.Connected.Count, "the claim made this PC the owner's computer of the new hub, once");
        Assert.AreEqual($"http://{rig.Status.AddressOf(hetzner.Orders[0].Name)}:8765/", rig.Connected[0].ToString());
    }

    /// <summary>**A build keeps the record of each server that it made, with the hub that it is for, so that Start again
    /// deletes those and no other**: not a server of another hub's record, not a server of the account that no record
    /// names; and Start again forgets the host keys and the records of this hub. Bugs: a record written only when the
    /// build ends (a build that stopped leaves a paid server that nothing knows), a manager's server kept with no hub,
    /// or Start again by a server's name or label, which deletes the owner's own servers.</summary>
    [TestMethod]
    public async Task Start_again_deletes_the_servers_that_this_PCs_records_prove_and_no_other()
    {
        await using var rig = new SetupRig();
        rig.ThroughTheFirstPages(ServersStep.Two);
        rig.Store.ChooseProvider(CloudProvider.Hetzner);
        await rig.Until(x => x.Cloud?.Offer is not null && x.ManagersCloud?.Offer is not null, "both offers");
        rig.Store.MakeFleet();
        await rig.Until(x => x.ManagersServer?.Address is not null && x.Install.ClaimedHub is not null, "both servers and the claim");
        var hub = rig.Store.State.Install.ClaimedHub!;
        var builds = rig.Records.Builds.All();
        Assert.AreEqual(2, builds.Count);
        Assert.IsTrue(builds.All(b => b.Hub == hub && b.ServerId is not null), string.Join("; ", builds.Select(b => $"{b.Name} {b.Hub} {b.ServerId}")));

        // Another hub's server, and a server of the account that no record names.
        rig.Records.Builds.Write(BuildRecord.Begin("hetzner", "hub", "http://100.64.0.99:8765/", "worker-9", "launch-0", DateTimeOffset.UtcNow)
                                            .Made("999", DateTimeOffset.UtcNow));
        rig.Records.Builds.Write(BuildRecord.Begin("hetzner", "hub", null, "worker-8", "launch-0", DateTimeOffset.UtcNow).End(DateTimeOffset.UtcNow));
        var hetzner = rig.Clouds[CloudProvider.Hetzner];
        hetzner.Existing.Add(new CloudExisting("555", "owners-own", "203.0.113.55", "cx22", 4096, "ubuntu", "24.04", "Nuremberg", true, null, null));
        hetzner.Existing.Add(new CloudExisting("999", "worker-9", "203.0.113.99", "cx23", 4096, "ubuntu", "24.04", "Nuremberg", true, null, null));
        foreach (var b in builds) hetzner.Existing.Add(new CloudExisting(b.ServerId!, b.Name, null, "cx23", 4096, "ubuntu", "24.04", "Nuremberg", true, null, null));
        File.WriteAllText(rig.HostKeys.Path, "{}");

        var plan = await rig.Store.StartAgainPlanAsync(hub);
        CollectionAssert.AreEquivalent(builds.Select(b => b.ServerId).ToList(), plan.Servers.Select(s => s.ServerId).ToList());
        Assert.AreEqual(CloudServerUse.Hub, plan.Servers[0].Use, "the hub's own server first");
        var steps = await rig.Store.StartAgainRunAsync(plan);
        Assert.IsTrue(steps.All(s => s.State == StartAgain.StepState.Done), string.Join("; ", steps.Select(s => $"{s.Title} {s.State} {s.Says}")));
        CollectionAssert.AreEquivalent(builds.Select(b => b.ServerId).ToList(), hetzner.DeletedServers);
        Assert.IsFalse(File.Exists(rig.HostKeys.Path), "Start again forgets the host keys");
        CollectionAssert.AreEqual(new[] { (new Uri(hub), true) }, rig.Forgotten, "the PC forgets the hub, with its key: its server was deleted");
        CollectionAssert.AreEquivalent(new[] { "worker-9", "worker-8" }, rig.Records.Builds.All().Select(b => b.Name).ToList(),
                                       "the other hub's record and a record of no hub stay: the run deleted neither server");
        Assert.AreEqual(SetupPage.Welcome, rig.Store.State.Page);
    }

    /// <summary>**A build that stops after the provider made the server keeps its record**, so the server stays known.
    /// Bug: a stopped build that forgets what it left at the provider.</summary>
    [TestMethod]
    public async Task A_build_that_stopped_keeps_the_record_of_the_server_that_it_made()
    {
        await using var rig = new SetupRig();
        rig.ThroughTheFirstPages(ServersStep.One);
        rig.Store.ChooseProvider(CloudProvider.Hetzner);
        await rig.Until(x => x.Cloud?.Offer is not null, "the hub's offer");
        rig.Clouds[CloudProvider.Hetzner].Refuses = _ => new CloudException(CloudFailure.LeftBehind, CloudProvider.Hetzner, "The firewall did not come up.", ["worker-1"]);
        Assert.IsTrue(rig.Store.MakeFleet());
        var s = await rig.Until(x => x.Cloud?.Stopped is not null && x.Cloud.Stage == CloudStep.Stage.Token, "the stop");
        Assert.IsNotNull(s.Cloud!.Failure);
        var record = rig.Records.Builds.All().Single();
        Assert.AreEqual((BuildOutcome.Stopped, AtProvider.LeftBehind), (record.Outcome, record.AtProvider));
        Assert.IsTrue(record.IsUnjoined);
    }

    /// <summary>**"1 server" makes one server, and Other VPS installs the hub on the owner's own server with the app's
    /// key, with no build at all.** Bug: a press of "1 server" that rents the manager's server too.</summary>
    [TestMethod]
    public async Task One_server_makes_one_server_and_other_vps_makes_none()
    {
        await using var rig = new SetupRig();
        rig.ThroughTheFirstPages(ServersStep.One);
        rig.Store.ChooseProvider(CloudProvider.Hetzner);
        await rig.Until(x => x.Cloud?.Offer is not null, "the hub's offer");
        Assert.AreEqual("Make the server", SetupScreens.Of(rig.Store.State).Controls.Single(c => c.Kind == SetupControlKind.Button).Words);
        rig.Store.MakeFleet();
        await rig.Until(x => x.Install.Checklist is not null, "the hub's install");
        Assert.AreEqual(1, rig.Clouds[CloudProvider.Hetzner].Orders.Count);

        await using var own = new SetupRig();
        own.ThroughTheFirstPages(ServersStep.One);
        own.Store.ChooseOtherVps();
        await own.Store.CheckVpsAsync("203.0.113.10");
        Assert.AreEqual(VpsPhase.Ready, own.Store.State.Vps.Phase, own.Store.State.Vps.Why);
        own.Store.InstallVps();
        await own.Until(x => x.Install.Checklist is not null, "the hub's install on the owner's server");
        Assert.IsTrue(own.Clouds.Values.All(c => c.Orders.Count == 0));
        Assert.IsTrue(own.Remote.Calls.All(c => c.Login is RemoteLogin.AppKey));
    }

    private static async Task<SetupRig> Built(SetupRig rig, ServersStep step = ServersStep.Two, string name = "Juno")
    {
        rig.ThroughTheFirstPages(step, name);
        rig.Store.ChooseProvider(CloudProvider.Hetzner);
        await rig.Until(x => x.Cloud?.Offer is not null && (step == ServersStep.One || x.ManagersCloud?.Offer is not null), "the offers");
        Assert.IsTrue(rig.Store.MakeFleet());
        return rig;
    }

    /// <summary>**The hand-over waits for the manager's join and comes at its end, with the server that joined; the join
    /// sends the key that the fleet's key gave for that server.** The bugs: a first run that goes to the manager's setup
    /// while its server joins, so that the setup asks for a server again; one that never leaves the build page; and a
    /// join whose installer was made without its plan's key (24 November 2026): the key step wrote an empty key, and the
    /// joined server never reached the private network; and a second key made for the installer, which is not the one
    /// that the plan was made with. The key step shows in the join's progress, and done in its record, and no line of
    /// the join holds the key, also where the server prints it back. The hand-over keeps his capitals of the manager's
    /// name, which the installer took in small letters, for the hub (the validator's W-S1: "McBot" showed as "Mcbot").</summary>
    [TestMethod]
    public async Task The_hand_over_comes_at_the_joins_end_with_the_server_that_joined()
    {
        // Each key step prints back what it got on standard input, as a program that prints its input would. The key is
        // kept here, at the call: the installer zeroes its bytes once the call ends.
        var keys = new System.Collections.Concurrent.ConcurrentQueue<(string Host, string Key)>();
        await using var rig = new SetupRig(call =>
        {
            if (call.Input is not { } input || !call.Program.Contains("cat > /root/fleet-authkey", StringComparison.Ordinal)) return null;
            var key = Encoding.UTF8.GetString(input);
            keys.Enqueue((call.Target.Host, key));
            return StandInRemote.Said("got " + key + "\n" + (ClaimCode.IsPrivateAddress(call.Target.Host) ? call.Target.Host : Printed.PrivateAddress));
        }) { Fleet = SetupRig.NewFleet() };
        await Built(rig, name: "JuNo");
        var s = await rig.Until(x => x.HandedOver, "the hand-over");
        Assert.IsNotNull(s.ManagerInstall.Checklist, "the join ended before the hand-over");
        var handed = rig.Store.HandedOver!;
        Assert.AreEqual(("juno", "claude", s.ManagersServer!.Name, false, null as MadeServer), (handed.Manager, handed.Provider, handed.Joined, handed.SignInAsked, handed.Made));
        Assert.AreEqual(new Agents.AgentSpellingNote(new Uri(s.Install.ClaimedHub!), "db-1", "juno", "JuNo"),
                        Agents.AgentSpellingNotes.Read(rig.Choices).SingleOrDefault(), "his spelling waits for the hub");
        Assert.AreEqual(0, rig.Calls.SignIns, "a manager with no server gets its provider with its server, and no sign-in now");
        Assert.AreEqual(1, rig.Calls.Posts.Count(p => p == "ui/servers/join"));

        var sent = keys.Where(k => k.Host == s.ManagersServer.Address).Select(k => k.Key).ToArray();
        CollectionAssert.AreEqual(new[] { StandInNet.AuthKey }, sent, "the join's key step sends the key of the fleet's key, once");
        // The stand-in's fleet gives the same key for each server, so the count proves that the key that went is the one
        // that the plan was made with: a second key made for the installer would be a second one here.
        Assert.AreEqual(1, rig.Net.Keys.Count(h => h == s.ManagersServer.Address), "one key for the server that joins");
        var network = s.ManagerInstall.Steps.Last(p => p.Step == "network");
        Assert.AreEqual((ProgressState.Done, "Tailscale, with your key on standard input, and the address it gets."), (network.State, network.Says));
        CollectionAssert.Contains(network.Lines.ToList(), "got (not shown)", "the server's line, without the key");
        var record = rig.Records.Installs.All().Single(r => r.Kind == InstallKind.Join);
        Assert.IsTrue(record.Steps.Any(st => st.Id == InstallStepId.Network && st.State == RecordStepState.Done), "the join's record has its network step, done");
        var lines = s.ManagerInstall.Steps.SelectMany(p => p.Lines.Append(p.Detail ?? "").Append(p.ToString()));
        Assert.IsFalse(lines.Any(t => t.Contains(StandInNet.AuthKey, StringComparison.Ordinal)), "no line of the join holds the key");
    }

    /// <summary>**When the join's wait ends by its count and the new hub answers late, the hand-over comes at that
    /// answer, with the server that the run made for the manager's setup to install.** The bug: the run stays on the build
    /// page for good (the hand-over was asked only at the two ends of the installs).</summary>
    [TestMethod]
    public async Task The_hand_over_comes_when_the_joins_wait_ended_and_the_hub_answers_late()
    {
        await using var rig = new SetupRig();
        await Built(rig);
        await rig.Until(x => x.Install.Checklist is not null && x.ManagersServer?.Address is not null, "the hub's install and the manager's server");
        await Task.Delay(100);
        Assert.IsFalse(rig.Store.State.HandedOver, "no hand-over before the hub answers this PC");
        Assert.AreEqual(0, rig.Calls.Posts.Count(p => p == "ui/servers/join"), "the join's wait ended by its count");
        rig.Fleet = SetupRig.NewFleet();
        rig.Store.Recheck();
        await rig.Until(x => x.HandedOver, "the hand-over at the hub's late answer");
        var handed = rig.Store.HandedOver!;
        Assert.IsNull(handed.Joined);
        Assert.AreEqual(rig.Store.State.ManagersServer, handed.Made, "the manager's setup gets the server that the run made");
        var made = rig.Store.State.ManagersServer!;
        Assert.AreEqual(new Agents.FirstRunServer(made.Name, made.Address!), Agents.ManagerSetupMark.Read(rig.Choices)?.Made,
                        "and its mark keeps it for a start of the app before its install");
    }

    /// <summary>**A manager's server that its provider refused with no way on does not hold the run**: the hand-over comes
    /// after the hub's install, and the manager's setup asks for the server. The bug: a first run that waits for good for
    /// a choice that cannot lead on.</summary>
    [TestMethod]
    public async Task The_hand_over_comes_when_the_managers_server_is_refused_with_no_way_on()
    {
        await using var rig = new SetupRig { Fleet = SetupRig.NewFleet() };
        rig.Clouds[CloudProvider.Hetzner].Refuses = order => order.Use == CloudServerUse.Agent ? new CloudException(CloudFailure.Full, CloudProvider.Hetzner) : null;
        await Built(rig);
        var s = await rig.Until(x => x.HandedOver, "the hand-over");
        Assert.IsTrue(s.ManagersFull.Contains(CloudProvider.Hetzner));
        Assert.AreEqual((null as string, null as MadeServer), (rig.Store.HandedOver!.Joined, rig.Store.HandedOver.Made));
    }

    /// <summary>**Two asks of the hand-over at once ask for the manager's sign-in once**: "1 server" puts the manager on the
    /// hub's own server, and the run asks for its sign-in as it hands over. The bug: two codes started on one machine.</summary>
    [TestMethod]
    public async Task Two_asks_of_the_hand_over_at_once_ask_for_the_sign_in_once()
    {
        await using var rig = new SetupRig();
        rig.Calls.ManagerOn = "worker-1";
        await Built(rig, ServersStep.One);
        await rig.Until(x => x.Install.Checklist is not null, "the hub's install");
        rig.Fleet = SetupRig.NewFleet();
        await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => Task.Run(rig.Store.Recheck)));
        await rig.Until(x => x.HandedOver, "the hand-over");
        await Task.Delay(50);
        Assert.AreEqual(1, rig.Calls.SignIns);
        Assert.IsTrue(rig.Store.HandedOver!.SignInAsked);
    }

    /// <summary>A checklist of the server with one check that failed.</summary>
    private const string FailedChecklist =
        "[{\"check\": \"services\", \"state\": \"fail\", \"says\": \"The hub's service does not run.\", \"fix\": \"Restart the server.\"}]";

    /// <summary>**Checks that did not pass offer "Open Founderizer" once the hub answers this PC, and its press goes on to
    /// the manager's setup** (the Mac's <c>afterInstall</c> and <c>openApp</c>; U2's report: "There is no 'Open
    /// Founderizer'"). Before the hub answers, the title moves at "Connecting to your hub" with no press; after the press it
    /// moves again until the hand-over, which keeps the manager's first setup for this hub. The bugs: a first run whose
    /// checks did not pass that stands on its page for good; a press offered before the hub answers, which leads nowhere.</summary>
    [TestMethod]
    public async Task Checks_that_did_not_pass_offer_Open_Founderizer_once_the_hub_answers_and_its_press_hands_over()
    {
        await using var rig = new SetupRig(call => call.Program.Contains("verify --json", StringComparison.Ordinal) ? StandInRemote.Said(FailedChecklist) : null);
        await Built(rig, ServersStep.One);
        var s = await rig.Until(x => x.Install.Checklist is not null, "the hub's install");
        Assert.IsFalse(s.Install.Passed);
        var screen = SetupScreens.Of(s);
        Assert.AreEqual((SetupScreens.ConnectingToHub, true), (screen.Title, screen.Waits), "before the hub answers");
        Assert.IsFalse(screen.Controls.Any(c => c.Kind == SetupControlKind.Button), "no press before the hub answers");
        rig.Store.OpenApp();
        Assert.IsFalse(rig.Store.State.OpenAsked, "a press that the page does not offer does nothing");

        rig.Fleet = SetupRig.NewFleet();
        rig.Store.OwnerChanged();
        screen = SetupScreens.Of(rig.Store.State);
        Assert.AreEqual((SetupScreens.HubInstalled, false), (screen.Title, screen.Waits));
        CollectionAssert.AreEqual(new[] { (SetupControlKind.Button, SetupScreens.OpenFounderizer), (SetupControlKind.Muted, SetupScreens.ServesThisPc) },
                                  screen.Controls.Select(c => (c.Kind, c.Words)).ToArray());
        await Task.Delay(50);
        Assert.IsFalse(rig.Store.State.HandedOver, "checks that did not pass hand nothing over by themselves");

        rig.Store.OpenApp();
        screen = SetupScreens.Of(rig.Store.State);
        Assert.AreEqual((SetupScreens.ConnectingToHub, true, 0), (screen.Title, screen.Waits, screen.Controls.Count), "after the press");
        await rig.Until(x => x.HandedOver, "the hand-over after the press");
        var mark = Agents.ManagerSetupMark.Read(rig.Choices);
        Assert.IsNotNull(mark, "the manager's first setup is kept for this hub");
        Assert.AreEqual(("juno", "db-1", "claude"), (mark.Agent, mark.Db, mark.Provider));
        Assert.IsTrue(mark.IsOf(new Uri(rig.Store.State.Install.ClaimedHub!), "db-1"));
    }

    /// <summary>**The manager's first setup is kept from the claim on, so an app that ends before the hand-over opens on it
    /// at its next start** (the read of U3, fault 1): the hub's install claims the hub minutes before it ends, and checks
    /// that did not pass hold the hand-over until the owner's press. At the next start no first run runs: the PC owns the
    /// hub, reads it, and its kept mark gives the setup, which gives the manager the server that joined, with the provider
    /// that the owner chose. The bug: the mark written only at the hand-over, and a PC that owns a hub with no welcome page,
    /// whose manager's page is a chat that cannot answer.</summary>
    [TestMethod]
    public async Task The_managers_setup_is_kept_from_the_claim_for_an_app_that_ends_before_the_hand_over()
    {
        await using var rig = new SetupRig(call => call.Program.Contains("verify --json", StringComparison.Ordinal) ? StandInRemote.Said(FailedChecklist) : null)
        {
            Fleet = SetupRig.NewFleet(),
        };
        await Built(rig);
        var s = await rig.Until(x => x.Install.Checklist is not null && x.ManagerInstall.Checklist is not null, "the hub's install and the manager's join");
        Assert.IsFalse(s.HandedOver, "the app ends here, before the hand-over");
        var joined = s.ManagersServer!.Name;
        // The change that ended the join writes the mark right after it: a few moments of real time at most.
        for (var i = 0; i < SetupRig.HangReads && Agents.ManagerSetupMark.Read(rig.Choices)?.Joined is null; i++) await Task.Delay(10);
        var kept = Agents.ManagerSetupMark.Read(rig.Choices);
        Assert.IsNotNull(kept, "the mark from the claim on");
        Assert.AreEqual(("juno", "db-1", "claude", joined), (kept.Agent, kept.Db, kept.Provider, kept.Joined));

        // The next start: the PC is the owner's computer of the claimed hub, with a current reading of it, and no first run.
        var now = DateTimeOffset.UtcNow;
        var state = new Founderizer.Core.StoreState { Hub = new Uri(s.Install.ClaimedHub!), Role = Founderizer.Core.HubRole.Owner, Fleet = rig.Fleet, LastRead = now, Clock = now };
        var mark = Agents.ManagerSetupMark.Shown(state, rig.Choices);
        Assert.IsNotNull(mark, "the window shows the manager's setup");
        var hub = new SetupHub { Servers = SetupHub.ServerList(managerOn: null, server: joined) };
        var setup = new Agents.ManagerSetup(new Agents.ManagerSetupSettings { Calls = hub, Fleet = () => rig.Fleet, Choices = rig.Choices }, mark);
        Assert.IsTrue(Agents.ManagerSetupScreens.TakesWindow(setup.View));
        await setup.StepAsync();
        Assert.IsTrue(Agents.ManagerSetupScreens.TakesWindow(setup.View), "it fills the window");
        var moves = hub.PostsTo("/move");
        Assert.AreEqual(1, moves.Count, "the setup gives the manager the server that joined, by itself");
        StringAssert.Contains(moves[0], $"\"server\":\"{joined}\"");
        StringAssert.Contains(moves[0], "\"runtime\":\"claude\"");
    }

    /// <summary>**An app that ends while the manager's own server joins opens at its next start on a setup that joins that
    /// server once by itself** (the Mac's <c>noteMadeServer</c>): the mark keeps the server, by its name and its address on
    /// the private network, from the moment that it is there, and no later start runs the first run again. The bug: only
    /// the hand-over kept it, so that the next start's page shows nothing of the server and its only way on is a second paid
    /// server.</summary>
    [TestMethod]
    public async Task An_app_that_ends_while_the_managers_server_joins_joins_it_at_the_next_start()
    {
        using var ended = new ManualResetEventSlim();
        await using var rig = new SetupRig(call =>
        {
            // The join's call waits for the test to let it go; the bound only stops a hang (SetupRig.HangWait).
            if (call.Program.Contains("FLEET_JOIN=", StringComparison.Ordinal)) ended.Wait(SetupRig.HangWait);
            return null;
        })
        { Fleet = SetupRig.NewFleet() };
        try
        {
            await Built(rig);
            var s = await rig.Until(x => x.ManagerInstall.Running && x.ManagersServer?.Address is not null, "the manager's join");
            for (var i = 0; i < SetupRig.HangReads && Agents.ManagerSetupMark.Read(rig.Choices)?.Made is null; i++) await Task.Delay(10);
            var server = new Agents.FirstRunServer(s.ManagersServer!.Name, s.ManagersServer.Address!);
            var kept = Agents.ManagerSetupMark.Read(rig.Choices);
            Assert.AreEqual(("juno", "db-1", "claude", null as string, server), (kept?.Agent, kept?.Db, kept?.Provider, kept?.Joined, kept?.Made),
                            "the server is in the mark while its join runs");
            Assert.IsFalse(s.HandedOver, "the app ends here, before the hand-over");

            // The next start: the PC is the owner's computer of the claimed hub, with no first run.
            var now = DateTimeOffset.UtcNow;
            var state = new Founderizer.Core.StoreState { Hub = new Uri(s.Install.ClaimedHub!), Role = Founderizer.Core.HubRole.Owner, Fleet = rig.Fleet, LastRead = now, Clock = now };
            var mark = Agents.ManagerSetupMark.Shown(state, rig.Choices);
            Assert.IsNotNull(mark, "the window shows the manager's setup");
            var hub = new SetupHub { Servers = "{\"db\": \"db-1\", \"time\": 1763700100, \"servers\": [{\"name\": \"worker-1\", \"hub\": true, \"joined\": true, \"agents\": [], \"available\": false, \"why\": []}]}" };
            var records = new SetupRecords(rig.Folder, "launch-2");
            var setup = new Agents.ManagerSetup(new Agents.ManagerSetupSettings
            {
                Calls = hub, Fleet = () => rig.Fleet, Choices = rig.Choices,
                Server = new Agents.AgentServerSettings
                {
                    Box = rig.Box, Remote = SetupRig.Answering(null), Records = records, Tailscale = rig.Net, Cloud = p => rig.Clouds[p],
                    Status = _ => Task.FromResult<string?>(rig.Status.Json()), Pause = (_, cancel) => Task.Delay(1, cancel),
                    JoinClock = new StandInClock(), HandOverReads = 1, HandOverEvery = TimeSpan.FromMilliseconds(1),
                },
            }, mark);
            await setup.StepAsync();
            Assert.AreEqual(true, Agents.ManagerSetupMark.Read(rig.Choices)!.Made?.Tried, "its join by itself started");
            for (var i = 0; i < SetupRig.HangReads && records.Installs.All().All(r => r.Launch != "launch-2" || r.Runs); i++) await Task.Delay(10);
            for (var read = 0; read < 2; read++) await setup.StepAsync();
            var own = records.Installs.All().Where(r => r.Launch == "launch-2").ToList();
            Assert.AreEqual((1, InstallOutcome.Done), (own.Count, own[0].Outcome), "one join of that server, which ended well");
            for (var i = 0; i < SetupRig.HangReads && Agents.ManagerSetupMark.Read(rig.Choices)!.Made is not null; i++) await Task.Delay(10);
            Assert.IsNull(Agents.ManagerSetupMark.Read(rig.Choices)!.Made, "the mark lets it go at the end of a join that ended well");
        }
        finally
        {
            ended.Set();
            await rig.Until(x => !x.ManagerInstall.Running, "the first run's own join to end");
        }
    }

    /// <summary>**The manager's setup joins nothing by itself while the first run's own join of its server runs** (the
    /// mark holds that server from the claim on, so a setup that the window made before the hand-over could ask for it): the
    /// first run's own records, which the setup reads, say that the join runs. The bug: two joins of one server at once,
    /// each of which can make a server key; the hub keeps the first and refuses the second, and a server whose key file
    /// ends with the second one is refused for good.</summary>
    [TestMethod]
    public async Task The_managers_setup_joins_nothing_while_the_first_runs_join_of_its_server_runs()
    {
        using var ended = new ManualResetEventSlim();
        await using var rig = new SetupRig(call =>
        {
            // The join's call waits for the test to let it go; the bound only stops a hang (SetupRig.HangWait).
            if (call.Program.Contains("FLEET_JOIN=", StringComparison.Ordinal)) ended.Wait(SetupRig.HangWait);
            return null;
        })
        { Fleet = SetupRig.NewFleet() };
        try
        {
            await Built(rig);
            await rig.Until(x => x.ManagerInstall.Running && x.ManagersServer?.Address is not null, "the manager's join");
            for (var i = 0; i < SetupRig.HangReads && Agents.ManagerSetupMark.Read(rig.Choices)?.Made is null; i++) await Task.Delay(10);
            var mark = Agents.ManagerSetupMark.Read(rig.Choices)!;
            Assert.IsNotNull(mark.Made, "the server is in the mark while its join runs");

            // The page opens in this start of the app, with the first run's own records.
            var hub = new SetupHub { Servers = "{\"db\": \"db-1\", \"time\": 1763700100, \"servers\": [{\"name\": \"worker-1\", \"hub\": true, \"joined\": true, \"agents\": [], \"available\": false, \"why\": []}]}" };
            var setup = new Agents.ManagerSetup(new Agents.ManagerSetupSettings
            {
                Calls = hub, Fleet = () => rig.Fleet, Choices = rig.Choices,
                Server = new Agents.AgentServerSettings
                {
                    Box = rig.Box, Remote = rig.Remote, Records = rig.Records, Tailscale = rig.Net, Cloud = p => rig.Clouds[p],
                    Status = _ => Task.FromResult<string?>(rig.Status.Json()), Pause = (_, cancel) => Task.Delay(1, cancel),
                    JoinClock = new StandInClock(), HandOverReads = 1, HandOverEvery = TimeSpan.FromMilliseconds(1),
                },
            }, mark);
            for (var read = 0; read < 2; read++) await setup.StepAsync();
            Assert.AreEqual((InstallView.None, false), (setup.View.NewServer!.Install, Agents.ManagerSetupMark.Read(rig.Choices)!.Made?.Tried),
                            "no second join of that server");
        }
        finally
        {
            ended.Set();
            await rig.Until(x => !x.ManagerInstall.Running, "the first run's own join to end");
        }
    }

    /// <summary>**A join that waits for the owner's yes at Tailscale shows its link on the install's page, with its one
    /// press** (the Mac's <c>MachineInstallRun.approve</c>): the fleet's key may not give the tags of the hub's join line,
    /// so the manager's own server signs in by Tailscale's link. The build page has no place for it, so the install's page
    /// shows it, and the build page comes back once the server is on the network. The bug: a join that waits sixteen
    /// minutes on a link that no page shows, and a manager's server that never joins.</summary>
    [TestMethod]
    public async Task A_join_that_waits_for_Tailscale_shows_its_link_with_its_one_press()
    {
        const string link = "https://login.tailscale.com/a/0a1b2c3d4e5f";
        using var approved = new ManualResetEventSlim();
        var watched = 0;
        await using var rig = new SetupRig(call =>
        {
            if (!call.Program.Contains("fleet-machine-name=", StringComparison.Ordinal)) return null;
            if (Interlocked.Increment(ref watched) == 1) return StandInRemote.Said($"fleet-machine-name=worker-2\nTo authenticate, visit:\n{link}");
            // The second watch waits for the test's yes; the bound only stops a hang (SetupRig.HangWait).
            approved.Wait(SetupRig.HangWait);
            return StandInRemote.Said("fleet-machine-name=worker-2\nfleet-on-network\n100.64.0.12");
        }) { Fleet = SetupRig.NewFleet() };
        rig.Calls.JoinLine = "curl -fsS http://100.64.0.9:8765/join | FLEET_JOIN=7KMQ2PRJ4TVW sh -s -- --advertise-tags=tag:founderizer";
        // The join asks for a key by the server's address; the provider's builds ask by the servers' names, and get theirs.
        rig.Net.Refuses = name => System.Net.IPAddress.TryParse(name, out _) ? new FleetKeyException(FleetKeyFailure.RoleCannotWrite) : null;
        await Built(rig);
        // The hub's own install ended too: its title would be "Connecting to your hub" there.
        var s = await rig.Until(x => x.ManagerInstall.NetworkSignIn is not null && x.Install.Checklist is not null, "the join's link");
        Assert.AreEqual((link, "worker-2"), (s.ManagerInstall.NetworkSignIn!.Url.OriginalString, s.ManagerInstall.NetworkSignIn.Server));
        Assert.IsFalse(rig.Store.ShowsBuild, "the install's own page, not the build page");
        var screen = SetupScreens.Of(s, rig.Store.Runs, rig.Store.ShowsBuild);
        Assert.AreEqual((SetupScreens.BuildingTitle, true), (screen.Title, screen.Waits), "the build's moving title over the install's form");
        var rows = screen.Controls.Where(c => c.Kind == SetupControlKind.Row).ToList();
        CollectionAssert.AreEqual(new[] { SetupScreens.NotOnNetwork, SetupScreens.ApproveServer("worker-2") }, rows.Select(r => r.Words).ToArray());
        Assert.AreEqual(SetupScreens.OpenLink, rows[1].Lines!.Single());
        Assert.IsFalse(rig.Store.State.HandedOver, "no hand-over while the join waits");

        approved.Set();
        await rig.Until(x => x.HandedOver, "the hand-over after the server joined");
        Assert.IsNull(rig.Store.State.ManagerInstall.NetworkSignIn);
        Assert.IsNotNull(rig.Store.HandedOver!.Joined, "the server that joined goes to the manager's setup");
    }

    /// <summary>**A read of the servers that does not answer at the hand-over keeps the chosen provider and the server
    /// that joined in the manager's mark, and the setup then gives the manager both by itself.** The setup uses them only
    /// while its own read says that the manager has no server. The bug: one read that fails at that moment, and the setup
    /// asks for the AI provider again and then stands for ever at the frame of a server's page, for a server that did
    /// join.</summary>
    [TestMethod]
    public async Task A_read_that_fails_at_the_hand_over_keeps_the_provider_and_the_joined_server()
    {
        await using var rig = new SetupRig { Fleet = SetupRig.NewFleet() };
        rig.Calls.ServersFails = 1;
        await Built(rig);
        var s = await rig.Until(x => x.HandedOver, "the hand-over");
        Assert.AreEqual(0, rig.Calls.ServersFails);
        Assert.IsNull(rig.Store.HandedOver!.Joined, "the hand-over's own read of the servers did not answer");
        var joined = s.ManagersServer!.Name;
        var mark = Agents.ManagerSetupMark.Read(rig.Choices)!;
        Assert.AreEqual(("claude", joined), (mark.Provider, mark.Joined));

        var hub = new SetupHub { Servers = SetupHub.ServerList(managerOn: null, server: joined) };
        var setup = new Agents.ManagerSetup(new Agents.ManagerSetupSettings { Calls = hub, Fleet = () => rig.Fleet, Choices = rig.Choices }, mark);
        await setup.StepAsync();
        var moves = hub.PostsTo("/move");
        Assert.AreEqual(1, moves.Count, "the setup gives the manager the server that joined, by itself");
        StringAssert.Contains(moves[0], $"\"server\":\"{joined}\"");
        StringAssert.Contains(moves[0], "\"runtime\":\"claude\"");
    }

    /// <summary>**Start again ends its last step for a hub recorded with a path or a query**: the manager's mark of that hub
    /// goes, with the spellings that wait for it, and the PC forgets the hub. The bug: the mark's check of the hub's address
    /// throws for such an address, and Start again stops in its last step with the hub, its records and the mark still on
    /// the PC; or the kept answers still hold the address of a hub that went.</summary>
    [TestMethod]
    public async Task Start_again_ends_for_a_hub_recorded_with_a_path()
    {
        await using var rig = new SetupRig();
        new Agents.ManagerSetupMark(new Uri("http://100.64.0.9:8765/"), "db-1", "juno", "claude").Keep(rig.Choices);
        Agents.AgentSpellingNotes.Note(rig.Choices, new Uri("http://100.64.0.9:8765/"), "db-1", "juno", "JuNo");
        Agents.AgentSpellingNotes.Note(rig.Choices, new Uri("http://100.64.0.12:8765/"), "db-2", "nova", "NoVa");
        const string recorded = "http://100.64.0.9:8765/claim?from=install";
        var plan = await rig.Store.StartAgainPlanAsync(recorded);
        var steps = await rig.Store.StartAgainRunAsync(plan);
        Assert.IsTrue(steps.All(x => x.State == StartAgain.StepState.Done), string.Join("; ", steps.Select(x => $"{x.Title} {x.State} {x.Says}")));
        Assert.IsNull(Agents.ManagerSetupMark.Read(rig.Choices), "the mark of that hub goes");
        Assert.AreEqual("nova", Agents.AgentSpellingNotes.Read(rig.Choices).Single().Agent, "its spelling goes, and another hub's stays");
        CollectionAssert.AreEqual(new[] { (new Uri(recorded), false) }, rig.Forgotten, "the PC forgets the hub");
    }

    /// <summary>**Try again of a stopped install runs the same install again**, from its first step. The bug: a stop with a
    /// Try again that does nothing.</summary>
    [TestMethod]
    public async Task Try_again_runs_a_stopped_install_again()
    {
        var failures = 1;
        await using var rig = new SetupRig(call => call.Program.Contains("git clone", StringComparison.Ordinal) && Interlocked.Decrement(ref failures) >= 0
            ? StandInRemote.Said("fatal: unable to access the repository", 128) : null);
        await Built(rig, ServersStep.One);
        var stopped = await rig.Until(x => x.Install.Failure is not null, "the stop");
        var screen = SetupScreens.Of(stopped);
        Assert.AreEqual(SetupScreens.HubDidNotInstall, screen.Title);
        Assert.AreEqual("first-run-install-again", screen.Controls.Single(c => c.Kind == SetupControlKind.Button).Id);
        rig.Store.InstallAgain();
        await rig.Until(x => x.Install.Checklist is not null, "the second try's checks");
        Assert.AreEqual(2, rig.Plans.Count(p => p.Steps.Any(st => st.Id == "claim")), "the same install again");
    }

    /// <summary>**A report of the step that runs keeps its start; a report of the next step sets a new one**
    /// (<see cref="InstallView.Reported"/>, the Mac's <c>if now != runningStep</c>; F4 piece 2). The bug: each Running
    /// report set the start to now, also a wait of the server check for apt's lock and a heading of the hub's installer,
    /// so the minutes said "· 9 min" after eight minutes of one step.</summary>
    [TestMethod]
    public void A_report_of_the_step_that_runs_keeps_its_start_and_one_of_the_next_step_sets_a_new_one()
    {
        var t0 = new DateTimeOffset(2026, 11, 22, 12, 0, 0, TimeSpan.Zero);
        InstallProgress Step(string id, ProgressState state, params string[] lines) => new(id, id, "", state, lines);
        var plan = InstallPlan.Hub(new InstallTarget("server"), "", null).Steps.Select(st => st.Id).ToList();
        var view = new InstallView(true, [], plan, t0, null, null, null, false).Reported(Step("read", ProgressState.Running), t0.AddSeconds(1));
        Assert.AreEqual(t0.AddSeconds(1), view.RunningSince, "the first step began");
        view = view.Reported(Step("read", ProgressState.Running, "Waiting for apt's lock"), t0.AddSeconds(480));
        Assert.AreEqual(t0.AddSeconds(1), view.RunningSince, "a wait of the same step");
        view = view.Reported(Step("read", ProgressState.Done), t0.AddSeconds(490)).Reported(Step("network", ProgressState.Running), t0.AddSeconds(491));
        Assert.AreEqual(t0.AddSeconds(491), view.RunningSince, "the next step");
        // A retry empties the steps, so its first step has a time of its own.
        view = (view with { Steps = [] }).Reported(Step("read", ProgressState.Running), t0.AddSeconds(600));
        Assert.AreEqual(t0.AddSeconds(600), view.RunningSince, "the retry's first step");
    }

    /// <summary>**The minutes of a long step count from its start, not from its last heading** (the Mac's
    /// <c>MachineInstallModel.record</c>; F4 piece 2). The bug: each heading of the hub's installer reports its step again,
    /// and each report set the step's start to now, so the build page said "· 13 min" for the whole wait.</summary>
    [TestMethod]
    public async Task The_minutes_of_a_long_step_count_from_its_start_not_from_its_last_heading()
    {
        using var finish = new ManualResetEventSlim();
        var reads = 0;
        SetupRig? clock = null;
        await using var rig = clock = new SetupRig(call =>
        {
            if (!call.Program.Contains("tail -n 40", StringComparison.Ordinal)) return null;
            switch (Interlocked.Increment(ref reads))
            {
                case 1: clock!.Ahead = TimeSpan.FromSeconds(300); return StandInRemote.Said("Founderizer step 14: security updates");
                case 2: clock!.Ahead = TimeSpan.FromSeconds(600); return StandInRemote.Said("Founderizer step 15: this server's own hardening");
                // The last step waits for the test to let it go; the bound only stops a hang (SetupRig.HangWait).
                default: finish.Wait(SetupRig.HangWait); return StandInRemote.Said("READY");
            }
        });
        try
        {
            await Built(rig, ServersStep.One);
            var s = await rig.Until(x => x.Install.Steps.Any(p => p is { Step: "wait_ready", State: ProgressState.Running } &&
                                                                    p.Lines.Any(l => l.Contains("step 15", StringComparison.Ordinal))), "the second heading");
            // 651 seconds after the step began, of its estimate of 650, and 51 after its last heading.
            var at = DateTimeOffset.UtcNow + rig.Ahead + TimeSpan.FromSeconds(51);
            Assert.IsNull(InstallPhases.Of(s.Install.Steps, s.Install.Planned, (at - s.Install.RunningSince).TotalSeconds)!.MinutesLeft,
                          $"the step began at {s.Install.RunningSince:O}");
        }
        finally { finish.Set(); }
        await rig.Until(x => x.Install.Checklist is not null, "the checks");
    }

    /// <summary>**A retry of the install never sends the build page's bar back, and a new press starts it again** (the
    /// Mac's <c>InstallHold</c> in <c>MachineInstallModel</c>; F4 piece 3: "a part never goes back while one press runs,
    /// also through a retry of the app"). The bugs: the retry empties the steps, so the bar fell back to its start while
    /// the same press ran on; or Install again keeps the hold of the press before, so a new install shows parts that it
    /// never did.</summary>
    [TestMethod]
    public async Task A_retry_of_the_install_never_sends_the_bar_back_and_a_new_press_starts_it_again()
    {
        var clones = 0;
        await using var rig = new SetupRig(call => !call.Program.Contains("git clone", StringComparison.Ordinal) ? null
            : Interlocked.Increment(ref clones) switch
            {
                1 => StandInRemote.Failed(RemoteFailure.Dropped),                          // a lost server: the press tries again
                2 => StandInRemote.Said("fatal: unable to access the repository", 128),   // a stop: the press ends
                _ => null,
            });
        var press = 1;
        var shown = new List<(int Press, InstallHold? Hold, IReadOnlyList<double> Parts)>();
        // The state at each change, read under one lock, so that the list goes in the store's own order.
        rig.Store.Changed += (_, _) =>
        {
            lock (shown) if (rig.Store.State.Install is { Running: true } install && install.Phases(0) is { } now) shown.Add((press, install.Hold, now.Parts));
        };
        await Built(rig, ServersStep.One);
        await rig.Until(x => x.Install.Failure is not null, "the second try's stop");
        Assert.AreEqual(2, rig.Plans.Count(p => p.Steps.Any(st => st.Id == "claim")), "the lost server's retry");
        lock (shown) press = 2;
        rig.Store.InstallAgain();
        await rig.Until(x => x.Install.Checklist is not null, "the new press's checks");
        lock (shown)
        {
            var first = shown.Where(s => s.Press == 1).Select(s => s.Parts).ToList();
            for (var i = 1; i < first.Count; i++)
                for (var part = 0; part < first[i].Count; part++)
                    Assert.IsTrue(first[i][part] >= first[i - 1][part], $"part {part} went back: {string.Join(" ", first[i - 1])} then {string.Join(" ", first[i])}");
            var again = shown.First(s => s.Press == 2);
            Assert.IsNull(again.Hold, "a new press starts a new hold");
            CollectionAssert.AreEqual(new[] { 0.0, 0, 0, 0 }, again.Parts.ToList(), "the new press's bar starts at the plan's start");
        }
    }

    /// <summary>**A fleet key that Tailscale ended says L2's sentence and asks for the key again**: on the install's page a
    /// paste makes a new key and Install again shows; before a server the key's page comes again though the box holds the
    /// ended key. The bug: "Connect Tailscale again" with no way to connect it.</summary>
    [TestMethod]
    public async Task An_ended_fleet_key_asks_for_the_key_again()
    {
        await using var rig = new SetupRig();
        rig.Net.Refuses = name => name == "hub" ? new FleetKeyException(FleetKeyFailure.FleetKeyEnded) : null;
        rig.ThroughTheFirstPages(ServersStep.One);
        rig.Store.ChooseOtherVps();
        await rig.Store.CheckVpsAsync("203.0.113.10");
        rig.Store.InstallVps();
        var s = await rig.Until(x => x.Install.Failure is not null, "the stop");
        Assert.IsTrue(s.Install.NeedsNetworkKey && s.FleetKeyEnded);
        var screen = SetupScreens.Of(s);
        Assert.AreEqual(new FleetKeyException(FleetKeyFailure.FleetKeyEnded).Message, screen.Warning, "L2's own sentence");
        Assert.IsTrue(screen.Controls.Any(c => c.Kind == SetupControlKind.Paste));
        Assert.IsFalse(screen.Controls.Any(c => c.Words == SetupScreens.InstallAgainWords), "no Install again before a new key");
        rig.Net.Refuses = null;
        await rig.Store.SendKeyAsync("tskey-api-kEXAMPLE07-NOTAKEYNOTAKEY");
        Assert.AreEqual(SetupPage.Installing, rig.Store.State.Page);
        Assert.IsTrue(SetupScreens.Of(rig.Store.State).Controls.Any(c => c.Words == SetupScreens.InstallAgainWords));
        rig.Store.InstallAgain();
        await rig.Until(x => x.Install.Checklist is not null, "the install with the new key");

        // Before a server: the key's page again, while the key that the box holds is the ended one.
        await using var other = new SetupRig();
        other.Net.Refuses = _ => new FleetKeyException(FleetKeyFailure.FleetKeyEnded);
        await Built(other, ServersStep.One);
        await other.Until(x => x.Cloud?.Stopped is not null && x.Cloud.Stage == CloudStep.Stage.Token, "the build's stop");
        Assert.IsTrue(other.Store.State.FleetKeyEnded);
        other.Store.Back();
        other.Store.ChooseProvider(CloudProvider.Hetzner);
        Assert.AreEqual(SetupPage.Key, other.Store.State.Page);
    }

    /// <summary>**A whole run on the stand-in PC leaves no secret in the state's text, a record's file or a step's
    /// line**: not the auth key of a server, not the hub's one-time join code, not the claim's link code, not the
    /// password once. The bug: a record or a line that a person or a report can read, with a key to the private network
    /// or a code that claims the hub in it.</summary>
    [TestMethod]
    public async Task A_whole_run_leaves_no_secret_in_the_state_a_record_or_a_line()
    {
        string[] secrets = [StandInNet.AuthKey, "7KMQ2PRJ4TVW", "ABCD-EFGH-JKLM", "ABCDEFGHJKLM", "correct horse battery"];
        await using var rig = new SetupRig { Fleet = SetupRig.NewFleet() };
        await Built(rig);
        await rig.Until(x => x.HandedOver, "the hand-over");
        await using var own = new SetupRig(call => call.Program == "/bin/sh -s" && call.Login is Remote.RemoteLogin.AppKey && own_keyless
            ? StandInRemote.Failed(Remote.RemoteFailure.LoginRefused) : null);
        own_keyless = true;
        own.ThroughTheFirstPages(ServersStep.One);
        own.Store.ChooseOtherVps();
        await own.Store.CheckVpsAsync("203.0.113.10");
        Assert.AreEqual(VpsPhase.Password, own.Store.State.Vps.Phase);
        own_keyless = false;
        await own.Store.GivePasswordAsync("correct horse battery".ToCharArray());
        Assert.AreEqual(VpsPhase.Ready, own.Store.State.Vps.Phase, own.Store.State.Vps.Why);
        own.Store.InstallVps();
        await own.Until(x => x.Install.Checklist is not null, "the install of the owner's server");
        foreach (var r in new[] { rig, own })
        {
            var s = r.Store.State;
            var texts = new List<string> { s.ToString(), s.Install.ToString(), s.ManagerInstall.ToString(), s.Vps.ToString(), $"{r.Store.HandedOver}" };
            texts.AddRange(s.Install.Steps.Concat(s.ManagerInstall.Steps).SelectMany(p => p.Lines.Append(p.Detail ?? "").Append(p.ToString())));
            texts.AddRange(Directory.EnumerateFiles(Path.Combine(r.Folder, "records"), "*", SearchOption.AllDirectories).Select(File.ReadAllText));
            foreach (var secret in secrets)
                Assert.IsFalse(texts.Any(x => x.Contains(secret, StringComparison.Ordinal)), "a text holds " + secret);
        }
    }

    private static volatile bool own_keyless;

    /// <summary>**A second first run after Start again, in the same run of the app, hands over again**: Start again stands
    /// on the manager's pages, after the first run's hand-over, and proof A runs twice with it between. The bug: the
    /// hand-over's flag, or the first run's hand-over, that stays set, so the second run's build page stays for good.</summary>
    [TestMethod]
    public async Task A_second_first_run_after_start_again_hands_over()
    {
        await using var rig = new SetupRig { Fleet = SetupRig.NewFleet() };
        await Built(rig);
        var first = await rig.Until(x => x.HandedOver, "the first hand-over");
        var hub = first.Install.ClaimedHub!;
        var firstServer = first.ManagersServer!.Name;
        var plan = await rig.Store.StartAgainPlanAsync(hub);
        var steps = await rig.Store.StartAgainRunAsync(plan);
        Assert.IsTrue(steps.All(st => st.State == StartAgain.StepState.Done), string.Join("; ", steps.Select(st => $"{st.Title} {st.Says}")));
        Assert.AreEqual(SetupPage.Welcome, rig.Store.State.Page);
        Assert.IsNull(rig.Store.HandedOver, "Start again takes the first run's hand-over away");

        await Built(rig);
        var second = await rig.Until(x => x.HandedOver, "the second hand-over");
        Assert.AreNotEqual(hub, second.Install.ClaimedHub, "a new hub");
        Assert.AreEqual(second.ManagersServer!.Name, rig.Store.HandedOver!.Joined);
        Assert.AreNotEqual(firstServer, rig.Store.HandedOver.Joined);
    }
}
