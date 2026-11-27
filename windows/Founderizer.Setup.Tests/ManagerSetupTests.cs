using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Founderizer.Setup.Agents;
using Founderizer.Setup.FirstRun;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The manager's first setup in the window** (windows-app-plan-v2.md, piece U3; the Mac's
/// <c>AgentSetupWizard</c> for the manager's first server), over a stand-in of the hub's owner routes: its server and its
/// provider by itself, the install with its bar, the sign-in, the wait for its session, and the mark that this PC keeps.</summary>
[TestClass]
public sealed class ManagerSetupTests
{
    private static readonly Uri Hub = new("http://100.64.0.9:8765/");

    /// <summary>The hub's reading as the owner's store holds it: the manager, its runtime, its sessions.</summary>
    private static MobileSnapshot Fleet(string runtime = "claude", string alive = "", IReadOnlyList<string>? features = null, string name = "juno") =>
        new(1, "db-1", 1763700100, [new MobileAgent(name, "manager", runtime, 0, [], Title: "Fleet Manager", Active: true, Alive: alive)],
            [], [], [], [], [], UiFeatures: features ?? ["servers", "machines", "machine_signin", "agent_setup", "manager_server"]);

    private static (ManagerSetup Setup, SetupHub Hub, MemoryChoices Choices) Setup(ManagerSetupMark mark, Func<MobileSnapshot?> fleet,
                                                                                  SetupHub? hub = null, Func<Task>? refresh = null,
                                                                                  Func<bool>? fresh = null, Func<Uri?>? hubOf = null)
    {
        var choices = new MemoryChoices();
        mark.Keep(choices);
        hub ??= new SetupHub();
        return (new ManagerSetup(new ManagerSetupSettings
        {
            Calls = hub, Fleet = fleet, Choices = choices, Refresh = refresh, Fresh = fresh, Hub = hubOf,
        }, mark), hub, choices);
    }

    /// <summary>**The manager gets the server that joined for it and the provider of the first run in one command, by
    /// itself, and the install's page follows with its bar** (the Mac's <c>placeChosen</c> and <c>.installing</c>): once on
    /// this visit, also while the hub's next read still lists it with no server; the bar's part never goes back while one
    /// job runs. The bugs: a second command for one choice, which the hub refuses or which installs twice; a setup that asks
    /// for a server again; a bar that jumps back when the server takes a step out of its list's order.</summary>
    [TestMethod]
    public async Task The_manager_gets_its_joined_server_and_its_provider_in_one_command_and_the_install_follows()
    {
        var fleet = Fleet();
        var (setup, hub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno", "claude", "worker-2"), () => fleet);
        Assert.AreEqual(2, ManagerSetupScreens.Of(setup.View).Progress?.Current, "the steps from the first frame, at Servers, before any read");
        hub.Servers = SetupHub.ServerList(managerOn: null);
        await setup.StepAsync();
        await setup.StepAsync();
        var moves = hub.PostsTo("/move");
        Assert.AreEqual(1, moves.Count, "one command, also when the next read still lists the manager with no server");
        StringAssert.Contains(moves[0], "\"server\":\"worker-2\"");
        StringAssert.Contains(moves[0], "\"runtime\":\"claude\"");

        hub.Servers = SetupHub.ServerList("worker-2", SetupHub.Job("running", "checkout"));
        await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("installing", "Installing Claude Code on worker-2", true, "claude"), (screen.Name, screen.Title, screen.Waits, screen.Logo));
        Assert.AreEqual(2, screen.Progress!.Current, "the step Servers");
        var bar = screen.Controls.Single(c => c.Kind == SetupControlKind.Bar);
        CollectionAssert.AreEqual(AgentSetupFlow.InstallSteps.Select(s => s.Title).ToArray(), bar.Lines!.ToArray());
        Assert.AreEqual("2", bar.Line, "the part of the step that runs");

        hub.Servers = SetupHub.ServerList("worker-2", SetupHub.Job("running", "runtime"));
        await setup.StepAsync();
        Assert.AreEqual("2", ManagerSetupScreens.Of(setup.View).Controls.Single(c => c.Kind == SetupControlKind.Bar).Line, "the bar does not go back");
        Assert.AreEqual(1, hub.PostsTo("/move").Count);
    }

    /// <summary>**The command that gives the manager its server goes once on a visit of the page, again after a cancel
    /// ended it, and again on a new visit** (the Mac's <c>placeAsked</c>, a state of its view). The bug: the page leaves
    /// while the command runs, the command never reaches the hub, and the page stands at "Installing … on worker-2" until
    /// the app starts again, because the setup that the app keeps for its whole run says that the command went.</summary>
    [TestMethod]
    public async Task The_command_goes_again_after_a_cancel_and_on_a_new_visit()
    {
        var fleet = Fleet();
        var (setup, hub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno", "claude", "worker-2"), () => fleet);
        hub.Servers = SetupHub.ServerList(managerOn: null);
        using var leave = new CancellationTokenSource();
        hub.BeforeAnswer = route => { if (route.EndsWith("/move", StringComparison.Ordinal)) leave.Cancel(); };
        var canceled = false;
        try { await setup.StepAsync(leave.Token); }
        catch (OperationCanceledException) { canceled = true; }
        Assert.IsTrue(canceled, "the page left while the command ran");
        hub.BeforeAnswer = null;

        await setup.StepAsync();
        Assert.AreEqual(2, hub.PostsTo("/move").Count, "the command goes again after the cancel");
        await setup.StepAsync();
        Assert.AreEqual(2, hub.PostsTo("/move").Count, "and once on this visit");
        setup.Visit();
        await setup.StepAsync();
        Assert.AreEqual(3, hub.PostsTo("/move").Count, "a new visit sends it again while the hub lists no server for the manager");
    }

    /// <summary>**A command that the hub refused shows the provider's page with the hub's own words, and only a press tries
    /// again** (the Mac's <c>placeRefused</c>). The bugs: a refusal that the page does not say, and a command sent again at
    /// each read, which the hub refuses again and again.</summary>
    [TestMethod]
    public async Task A_refused_command_shows_the_providers_page_with_the_hubs_words_and_a_press_tries_again()
    {
        var fleet = Fleet();
        var (setup, hub, choices) = Setup(new ManagerSetupMark(Hub, "db-1", "juno", "claude", "worker-2"), () => fleet);
        hub.Servers = SetupHub.ServerList(managerOn: null);
        hub.Refuses = route => route.EndsWith("/move", StringComparison.Ordinal) ? HubException.Refusal(409, null, "worker-2 takes no agent now.", "server_busy") : null;
        await setup.StepAsync();
        await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("provider", "Juno's AI provider", "worker-2 takes no agent now.", false),
                        (screen.Name, screen.Title, screen.Warning, screen.Back), "no Back: no name's page came first");
        CollectionAssert.AreEqual(new[] { "agent-setup-provider-codex", "agent-setup-provider-claude" }, screen.Controls.Select(c => c.Id).ToArray());
        Assert.IsTrue(screen.Controls.Single(c => c.Id == "agent-setup-provider-claude").Marked);
        Assert.AreEqual(1, hub.PostsTo("/move").Count, "no command again by itself");

        hub.Refuses = null;
        await setup.ChooseAsync("codex");
        var moves = hub.PostsTo("/move");
        Assert.AreEqual(2, moves.Count, "the press tries again");
        StringAssert.Contains(moves[1], "\"runtime\":\"codex\"");
        Assert.AreEqual("codex", ManagerSetupMark.Read(choices)!.Provider, "the choice is kept for a start of the app before the server takes it");
    }

    /// <summary>**The sign-in: Claude Code's code goes once in one body and stays nowhere, and a second one waits in its
    /// field while the first is on its way; Codex shows its code to enter on its page; the provider's page opens by itself
    /// only when the sign-in was asked for on this visit, by the owner's press on a card or by the command that gave the
    /// manager its chosen server and provider, and once** (the Mac's <c>signIn</c>, <c>send</c>, <c>opensByItself</c> and
    /// <c>placeChosen</c>). The bugs: a code sent twice to a sign-in that waits for one; a code kept in the page's state; a
    /// pasted code dropped with no word while another is on its way; a browser that opens a provider's page that nobody
    /// asked for, or at each read; no page after the place's install, where the Mac opens it.</summary>
    [TestMethod]
    public async Task The_sign_in_sends_a_code_once_and_opens_the_providers_page_only_when_it_was_asked_for()
    {
        const string code = "abcDEF123-code-of-the-test";
        var fleet = Fleet();
        var (setup, hub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno"), () => fleet);
        hub.Servers = SetupHub.ServerList("worker-2");
        hub.Machines = SetupHub.MachineList("claude", SetupHub.Login("claude", "needs_owner", url: "https://claude.ai/oauth/authorize?code=true", wantsCode: true));
        await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("signIn", "Sign in to Claude Code", false, "claude"), (screen.Name, screen.Title, screen.Waits, screen.Logo));
        Assert.AreEqual(3, screen.Progress!.Current, "the step Sign in");
        CollectionAssert.AreEqual(new[] { "Open [the sign-in page](https://claude.ai/oauth/authorize?code=true)", "Sign in, then copy the code it shows" },
                                  screen.Controls[0].Lines!.ToArray());
        Assert.AreEqual((SetupControlKind.Paste, SignInPage.CodePlaceholder), (screen.Controls[1].Kind, screen.Controls[1].Words));
        Assert.IsNull(setup.TakeOpening(), "no press asked for this sign-in on this visit");

        Assert.IsTrue(setup.TakesCode, "the sign-in waits for a code");
        Assert.IsTrue(await setup.SendCodeAsync(code));
        Assert.IsFalse(setup.TakesCode, "the code is on its way: a second paste stays in its field");
        Assert.IsFalse(await setup.SendCodeAsync(code), "the code is on its way: no second one");
        var sent = hub.PostsTo("/signin/code");
        Assert.AreEqual(1, sent.Count);
        StringAssert.Contains(sent[0], code);
        Assert.AreEqual("Signing in to Claude Code", ManagerSetupScreens.Of(setup.View).Title);
        Assert.IsFalse(setup.View.ToString().Contains(code, StringComparison.Ordinal), "the view keeps no code");
        Assert.IsFalse(ManagerSetupScreens.Of(setup.View).ToString().Contains(code, StringComparison.Ordinal), "the page keeps no code");

        // Codex, signed out, with no sign-in open: the press on its card asks for one, and its page opens by itself once.
        var codex = Fleet("codex");
        var (other, otherHub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno"), () => codex);
        otherHub.Servers = SetupHub.ServerList("worker-2");
        otherHub.Machines = SetupHub.MachineList("codex", null);
        await other.StepAsync();
        Assert.AreEqual("provider", ManagerSetupScreens.Of(other.View).Name);
        CollectionAssert.AreEqual(new[] { "agent-setup-provider-codex" }, ManagerSetupScreens.Of(other.View).Controls.Select(c => c.Id).ToArray(),
                                  "an agent on its server keeps its own provider: a change is a page of wave C");
        await other.ChooseAsync("codex");
        Assert.AreEqual(1, otherHub.PostsTo("/signin").Count);
        otherHub.Machines = SetupHub.MachineList("codex", SetupHub.Login("codex", "needs_owner", url: "https://auth.openai.com/codex/device", shows: "KDRT-7QXP"));
        await other.StepAsync();
        screen = ManagerSetupScreens.Of(other.View);
        Assert.AreEqual(("Sign in to Codex", "Sign in, then enter this code"), (screen.Title, screen.Controls[0].Lines![1]));
        Assert.AreEqual((SetupControlKind.Code, "KDRT-7QXP"), (screen.Controls[1].Kind, screen.Controls[1].Words));
        var opening = other.TakeOpening();
        Assert.AreEqual(("https://auth.openai.com/codex/device", "KDRT-7QXP"), (opening?.Link.OriginalString, opening?.Code));
        await other.StepAsync();
        Assert.IsNull(other.TakeOpening(), "once");

        // The command that gave the manager the server that joined for it and its chosen provider asked for the sign-in that
        // its install ends in (the Mac's placeChosen): that page opens by itself, once.
        var (placed, placedHub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno", "claude", "worker-2"), () => fleet);
        placedHub.Servers = SetupHub.ServerList(managerOn: null);
        await placed.StepAsync();
        Assert.AreEqual(1, placedHub.PostsTo("/move").Count);
        placedHub.Servers = SetupHub.ServerList("worker-2");
        placedHub.Machines = SetupHub.MachineList("claude", SetupHub.Login("claude", "needs_owner", url: "https://claude.ai/oauth/authorize?code=true", wantsCode: true));
        await placed.StepAsync();
        Assert.AreEqual("https://claude.ai/oauth/authorize?code=true", placed.TakeOpening()?.Link.OriginalString);
        Assert.IsNull(placed.TakeOpening(), "once");
    }

    /// <summary>**The setup waits for the manager's session under "Setting up", reads the owner's store again meanwhile,
    /// and ends when the manager runs, with its mark** (the Mac's <c>notePlacing</c>); a mark of another hub or generation
    /// opens no setup. The bugs: a chat that shows while the manager cannot answer yet; a setup that never ends; a setup
    /// that a hub of before shows over a new hub's chat.</summary>
    [TestMethod]
    public async Task The_setup_waits_for_the_managers_session_and_ends_when_it_runs()
    {
        var fleet = Fleet();
        var refreshes = 0;
        var mark = new ManagerSetupMark(Hub, "db-1", "juno");
        var (setup, hub, choices) = Setup(mark, () => fleet, refresh: () => { Interlocked.Increment(ref refreshes); return Task.CompletedTask; });
        Assert.AreEqual(3, ManagerSetupScreens.Of(setup.View).Progress?.Current, "before any read, a placed manager's sign-in is next");
        Assert.AreEqual(mark, ManagerSetupMark.Read(choices), "the mark reads as it was kept");
        Assert.IsTrue(mark.IsOf(new Uri("http://100.64.0.9:8765"), "db-1"));
        Assert.IsFalse(mark.IsOf(new Uri("http://100.64.0.10:8765/"), "db-1"), "another hub");
        Assert.IsFalse(mark.IsOf(Hub, "db-2"), "another generation of the hub");
        choices.Set(ManagerSetupMark.ChoiceName, "http://100.64.0.9:8765/|db-1|Juno!||");
        Assert.IsNull(ManagerSetupMark.Read(choices), "a mark of no valid shape");
        mark.Keep(choices);

        hub.Servers = SetupHub.ServerList("worker-2");
        hub.Machines = SetupHub.MachineList("claude", null, signedIn: true);
        await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("settingUp", "Setting up Juno", true, true), (screen.Name, screen.Title, screen.Waits, screen.Making));
        Assert.AreEqual(1, refreshes, "the owner's store reads again while the session starts");
        Assert.IsTrue(setup.View.Shows && !setup.View.Ended);

        fleet = Fleet(alive: "manager");
        await setup.StepAsync();
        Assert.IsTrue(setup.View.Ended, "the manager runs: its chat");
        Assert.IsNull(ManagerSetupMark.Read(choices), "the mark goes");
    }

    /// <summary>**A hub whose list of servers does not read leaves the page at "Setting up", and after eight such reads the
    /// page says so** (the Mac's <c>.unread</c> and <c>unreadReadsMost</c>); while the owner's store has no current reading
    /// (a window behind, a hub that does not answer), the setup reads and counts nothing (the Mac's <c>store.isFresh</c>).
    /// The bugs: a moving title with no end and no word; a manager read as placed for want of a list, whose page asks for a
    /// provider that it has; reads every two seconds of a window that is behind, and words of a hub that the owner's store
    /// already says does not answer.</summary>
    [TestMethod]
    public async Task A_hub_whose_servers_do_not_read_says_so_after_eight_reads()
    {
        var fleet = Fleet();
        var (stale, staleHub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno", "claude", "worker-2"), () => fleet, fresh: () => false);
        staleHub.ServersFail = true;
        for (var read = 0; read < 2 * ManagerSetup.UnreadReadsMost; read++) await stale.StepAsync();
        Assert.AreEqual((0, 0, null as string), (staleHub.Reads, stale.View.UnreadReads, ManagerSetupScreens.Of(stale.View).Warning),
                        "no read, and no count, while the owner's store has no current reading");

        var (setup, hub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno", "claude", "worker-2"), () => fleet);
        hub.ServersFail = true;
        for (var read = 0; read < ManagerSetup.UnreadReadsMost; read++) await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("settingUp", null as string), (screen.Name, screen.Warning));
        await setup.StepAsync();
        Assert.AreEqual(AgentSetupModel.CannotReadServer("Juno"), ManagerSetupScreens.Of(setup.View).Warning);
        Assert.AreEqual(0, hub.PostsTo("/move").Count);

        hub.ServersFail = false;
        hub.Servers = SetupHub.ServerList(managerOn: null);
        await setup.StepAsync();
        Assert.AreEqual(1, hub.PostsTo("/move").Count, "the first list that answers goes on by itself");
    }

    /// <summary>**The setup names its agent by the agent's label** (the Mac's <c>agentLabel</c> in <c>AgentSetupWizard</c>):
    /// here the owner's spelling of the name on a hub that keeps it (`agent_spelling`), else the name with capitals; its
    /// refusal of a server that the PC cannot read says that label. The bug: "juno's server" where every other place
    /// says "JuNo".</summary>
    [TestMethod]
    public async Task The_setup_names_its_agent_by_the_agents_label()
    {
        var fleet = Fleet(features: ["servers", "machines", AgentBook.SpellingFeature]);
        fleet = fleet with { Agents = [fleet.Agents[0] with { RawSpelling = JsonDocument.Parse("\"JuNo\"").RootElement }] };
        var model = new AgentSetupModel(new SetupHub(), "juno");
        Assert.AreEqual("Juno", model.Label, "before the first reading: the name with capitals");
        await model.ReadAsync(fleet);
        Assert.AreEqual("JuNo", model.Label);
        await model.ReadAsync(fleet with { UiFeatures = ["servers", "machines"] });
        Assert.AreEqual("Juno", model.Label, "a hub without the feature");
    }

    /// <summary>**With "1 server" kept, the wait for the hub's reading of its own server ends by a count of reads, with
    /// its words over Try again, which waits again; the server that then takes the manager gets it by itself** (the Mac's
    /// <c>HubShareModel.countRead</c>, <c>readsMost</c> and <c>stop</c>). The bug: a hub that never reports its server's
    /// service leaves "Setting up" moving with no end and no word.</summary>
    [TestMethod]
    public async Task A_wait_for_the_hubs_own_server_ends_with_its_words_and_Try_again_waits_again()
    {
        var fleet = Fleet(features: ["servers", "machines", "machine_signin", "agent_setup", "manager_server", "fleet_shape", "hub_shared_later"]);
        var (setup, hub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno", "claude"), () => fleet);
        hub.Servers = SetupHub.SharedHub(available: false);
        for (var read = 0; read < ManagerSetup.ShareReadsMost; read++) await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("settingUp", true, null as string, 0), (screen.Name, screen.Waits, screen.Warning, screen.Controls.Count));
        await setup.StepAsync();
        screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual((false, AgentSetupModel.NoAnswer), (screen.Waits, screen.Warning), "the wait stopped, with the Mac's words");
        Assert.AreEqual(("agent-setup-share-again", SetupScreens.TryAgain), (screen.Controls.Single().Id, screen.Controls.Single().Words));

        setup.ShareAgain();
        screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual((true, null as string), (screen.Waits, screen.Warning), "Try again waits again");
        Assert.AreEqual(0, hub.PostsTo("/move").Count);

        hub.Servers = SetupHub.SharedHub(available: true);
        await setup.StepAsync();
        var moves = hub.PostsTo("/move");
        Assert.AreEqual(1, moves.Count, "the hub's own server takes the manager, by itself");
        StringAssert.Contains(moves[0], "\"server\":\"worker-1\"");
    }

    /// <summary>**A page that this build draws as its frame alone does not take the window** (the read of U3, fault 2):
    /// Other VPS with "2 servers", the slider's default, makes no server for the manager, so its setup opens on the
    /// manager's server's page, which piece U3b draws; the window then shows the manager's page with its pane. The bug: a
    /// window that shows a frame alone, with no Back and no pane, and no way to any other page.</summary>
    [TestMethod]
    public async Task A_page_drawn_as_its_frame_alone_does_not_take_the_window()
    {
        var fleet = Fleet(features: ["servers", "machines", "machine_signin", "agent_setup", "manager_server", "fleet_shape", "hub_shared_later"]);
        var (setup, hub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno", "claude"), () => fleet);
        Assert.IsTrue(ManagerSetupScreens.TakesWindow(setup.View), "\"Setting up\" from the first frame");
        // The hub's own server alone, and "2 servers" kept: no server is there for the manager.
        hub.Servers = "{\"db\": \"db-1\", \"time\": 1763700100, \"shape\": {\"step\": \"two\"}, \"servers\": [" +
                      "{\"name\": \"worker-1\", \"hub\": true, \"joined\": true, \"agents\": [], \"available\": false, \"why\": []}]}";
        await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("server", false), (screen.Name, screen.Drawn));
        Assert.IsFalse(ManagerSetupScreens.TakesWindow(setup.View), "the manager's page with the pane");

        var (provider, providerHub, _) = Setup(new ManagerSetupMark(Hub, "db-1", "juno"), () => fleet);
        providerHub.Servers = hub.Servers;
        await provider.StepAsync();
        Assert.AreEqual("provider", ManagerSetupScreens.Of(provider.View).Name);
        Assert.IsTrue(ManagerSetupScreens.TakesWindow(provider.View), "a page that the build draws takes the window");
    }

    /// <summary>The features of a hub that keeps the fleet's shape and can rename a manager with no server: its setup
    /// starts on "Name your manager" when its first run did not ask.</summary>
    private static readonly string[] Renames =
        ["servers", "machines", "machine_signin", "agent_setup", "manager_server", "fleet_shape", "hub_shared_later", "manager_rename"];

    /// <summary>**A hub whose first run did not ask opens the manager's setup on "Name your manager", which takes the
    /// window, and Continue renames the manager on the hub; the setup of the new name goes on to the provider's page**
    /// (piece U3b; the Mac's <c>NameManagerPage</c> and <c>takeName</c>). Each hub of these tests is its own (an example
    /// address on a port of its own), because the note that the owner named it lasts for the app's run, as the Mac's. The
    /// bugs: a frame alone with no way out (the name's page undrawn); a name that the installer refuses sent to the hub; a
    /// rename with the typed capitals, against no team.json, or against the first one again when the team changed; the
    /// mark moved at the receipt, so that the setup of the new name reads a reading that does not have it yet and leaves
    /// the window; a mark that a reading of the new name does not move, so that the window loses the setup; and the name's
    /// page again after the rename, with no way on.</summary>
    [TestMethod]
    public async Task A_hub_whose_first_run_did_not_ask_names_its_manager_and_goes_on_to_its_provider()
    {
        var at = new Uri("http://100.64.0.9:8771/");
        var fleet = Fleet(features: Renames);
        var (setup, hub, choices) = Setup(new ManagerSetupMark(at, "db-1", "juno"), () => fleet);
        await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("name", "Name your manager", "It leads your team and is your main assistant.", true),
                        (screen.Name, screen.Title, screen.Detail, screen.Drawn));
        Assert.IsTrue(ManagerSetupScreens.TakesWindow(setup.View), "the page takes the window");
        Assert.AreEqual("Juno", setup.View.TypedName, "the field opens on the manager's own name with capitals");
        CollectionAssert.AreEqual(new[] { "agent-setup-name", "agent-setup-name-continue" }, screen.Controls.Select(c => c.Id).ToArray());

        foreach (var wrong in new[] { "J", "1nova", "hub", "abcdefghijklmnopqrstuvwxyza" })
        {
            setup.TypeName(wrong);
            var refused = ManagerSetupScreens.Of(setup.View);
            Assert.IsTrue(refused.Controls.Single(c => c.Id == "agent-setup-name").Marked, wrong);
            Assert.IsFalse(refused.Controls.Any(c => c.Id == "agent-setup-name-continue"), wrong);
            await setup.TakeNameAsync();
            Assert.AreEqual(0, hub.PostsTo("/rename").Count, wrong);
        }

        setup.TypeName(" Nova ");
        var tries = 0;
        hub.TeamShas.Enqueue(new string('b', 64));
        hub.TeamShas.Enqueue(new string('e', 64));
        hub.Refuses = route => route.EndsWith("/rename", StringComparison.Ordinal) && tries++ == 0
            ? HubException.Refusal(409, null, "The team changed.", "team_changed") : null;
        await setup.TakeNameAsync();
        var renames = hub.PostsTo("/rename");
        Assert.AreEqual(2, renames.Count, "a team.json that changed between the read and the press is read again, once");
        StringAssert.Contains(renames[0], $"\"base_sha256\":\"{new string('b', 64)}\"");
        StringAssert.Contains(renames[1], $"\"base_sha256\":\"{new string('e', 64)}\"", "the second rename goes against the team.json read again");
        StringAssert.Contains(renames[1], "\"name\":\"nova\"");
        Assert.IsFalse(setup.View.Busy, "Continue is held for the press only");
        hub.TeamLines = "[{\"agent\": \"nova\", \"role\": \"manager\"}]";
        await setup.TakeNameAsync();
        Assert.AreEqual(2, hub.PostsTo("/rename").Count, "a press after the rename sends nothing: the team has the new name");

        // Until a reading has the new name, the setup keeps its mark and stays on its name's page (the Mac's renaming): a
        // real hub's reading has the old name for a moment after the receipt, and a setup of the new name would read nothing
        // there and leave the window to the chat of an agent that is gone.
        var before = new StoreState { Hub = at, Role = HubRole.Owner, Fleet = fleet };
        var shown = ManagerSetupMark.Shown(before, choices);
        Assert.AreEqual("juno", shown?.Agent, "the mark keeps the old name until a reading has the new one");
        var (same, _, _) = Setup(shown!, () => fleet);
        await same.StepAsync();
        Assert.IsTrue(ManagerSetupScreens.TakesWindow(same.View), "the setup of the shown mark keeps the window over the old reading");
        Assert.AreEqual(("provider", true), (ManagerSetupScreens.Of(setup.View).Name, ManagerSetupScreens.TakesWindow(setup.View)),
                        "he named it: the provider's page, also over a reading from before");

        // The reading with the new name: the setup of that name, and the kept mark goes there, once.
        var after = before with { Fleet = Fleet(features: Renames, name: "nova") };
        Assert.AreEqual("nova", ManagerSetupMark.Shown(after, choices)?.Agent, "the setup of the new name");
        Assert.AreEqual(("juno", "nova"), ManagerSetupMark.TakeRename(after, choices));
        Assert.IsNull(ManagerSetupMark.TakeRename(after, choices), "once");
        var mark = ManagerSetupMark.Read(choices)!;
        Assert.AreEqual(("nova", null, null), (mark.Agent, mark.Provider, mark.Joined), "the kept mark takes the new name");

        // The setup of the new name, as the window makes it for the mark: on to the provider's page, not the name's again.
        var renamed = after.Fleet!;
        var (next, _, _) = Setup(mark, () => renamed);
        await next.StepAsync();
        var providers = ManagerSetupScreens.Of(next.View);
        Assert.AreEqual("provider", providers.Name, "the owner named it on this run of the app");

        // Back on the provider's page goes to the name's page, which has none (the Mac's SetupBack; the owner's "Match the
        // Mac"): a name that he wants to change after Continue can be changed.
        Assert.AreEqual((true, false), (providers.Back, screen.Back), "Back on the provider's page; none on the first page");
        next.BackToName();
        Assert.AreEqual(("name", (string?)null, false), (ManagerSetupScreens.Of(next.View).Name, ManagerSetupScreens.Of(next.View).Warning,
                                                          ManagerSetupScreens.Of(next.View).Back));
        Assert.AreEqual("Nova", next.View.TypedName, "the field holds the name that it has now");
    }

    /// <summary>**A rename that the hub refused keeps the name's page with the hub's words, and the name that the manager has
    /// goes on with no rename** (the Mac's <c>takeName</c>). The bugs: a refusal that the page does not say, or that moves
    /// the mark to a name that the hub does not have (the window then loses the setup); a rename sent for the name that the
    /// manager has, which the hub refuses, so that the owner cannot go on.</summary>
    [TestMethod]
    public async Task A_refused_rename_says_the_hubs_words_and_the_name_it_has_goes_on_with_no_rename()
    {
        var at = new Uri("http://100.64.0.9:8772/");
        var fleet = Fleet(features: Renames);
        var (setup, hub, choices) = Setup(new ManagerSetupMark(at, "db-1", "juno"), () => fleet);
        await setup.StepAsync();
        hub.Refuses = route => route.EndsWith("/rename", StringComparison.Ordinal)
            ? HubException.Refusal(409, null, "That name is taken.", "name_taken") : null;
        setup.TypeName("Nova");
        await setup.TakeNameAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("name", "That name is taken."), (screen.Name, screen.Warning));
        Assert.AreEqual("juno", ManagerSetupMark.Read(choices)!.Agent, "the mark keeps the name that the hub has");
        Assert.IsTrue(ManagerSetupMark.RenameNoted(at, "db-1", "juno"), "a refusal says only that its own command renamed nothing");

        // The line stays on the name's page: a page that is not the name's takes it away (a reading of a hub that cannot
        // rename, for one), and the name's page that comes back has none.
        fleet = Fleet();
        await setup.StepAsync();
        Assert.AreNotEqual("name", ManagerSetupScreens.Of(setup.View).Name);
        fleet = Fleet(features: Renames);
        await setup.StepAsync();
        Assert.AreEqual(("name", (string?)null), (ManagerSetupScreens.Of(setup.View).Name, ManagerSetupScreens.Of(setup.View).Warning),
                        "the line of a page before is gone");

        await setup.TakeNameAsync();
        Assert.AreEqual("That name is taken.", ManagerSetupScreens.Of(setup.View).Warning);
        setup.Visit();
        Assert.IsNull(ManagerSetupScreens.Of(setup.View).Warning, "a new visit has no orange line of a rename before it");

        // A store that went to another generation of the hub between the team's read and the second rename gets no second
        // rename (the Mac's guard of the hub and its db before each call).
        var before = hub.PostsTo("/rename").Count;
        hub.Refuses = route =>
        {
            if (!route.EndsWith("/rename", StringComparison.Ordinal)) return null;
            fleet = Fleet(features: Renames) with { Db = "db-2" };
            return HubException.Refusal(409, null, "The team changed.", "team_changed");
        };
        setup.TypeName("Vera");
        await setup.TakeNameAsync();
        Assert.AreEqual(before + 1, hub.PostsTo("/rename").Count, "no second rename in another generation");
        fleet = Fleet(features: Renames);

        hub.Refuses = null;
        setup.TypeName("Juno");
        await setup.TakeNameAsync();
        Assert.AreEqual(before + 1, hub.PostsTo("/rename").Count, "the name that it has goes on with no rename");
        Assert.AreEqual(("provider", (string?)null), (ManagerSetupScreens.Of(setup.View).Name, ManagerSetupScreens.Of(setup.View).Warning));

        // A press goes only to the hub of its mark: a store that went to another hub gets no rename (the hub half of the
        // generation's check; the Mac's guard of the hub of the press).
        Uri? current = new Uri("http://100.64.0.9:9999/");
        var own = new Uri("http://100.64.0.9:8778/");
        var (pressed, pressedHub, _) = Setup(new ManagerSetupMark(own, "db-1", "juno"), () => fleet, hubOf: () => current);
        await pressed.StepAsync();
        pressed.TypeName("Nova");
        await pressed.TakeNameAsync();
        Assert.AreEqual(0, pressedHub.PostsTo("/rename").Count, "no rename goes to a hub that is not the mark's");
        current = own;
        await pressed.TakeNameAsync();
        Assert.AreEqual(1, pressedHub.PostsTo("/rename").Count, "the press of the mark's own hub goes");

        // A refusal, or no answer, of a press whose store went to another generation meanwhile does nothing: no orange
        // line of the hub before (the Mac's `guard here()`).
        var moved = Fleet(features: Renames);
        var away = new Uri("http://100.64.0.9:8779/");
        var (gone, goneHub, _) = Setup(new ManagerSetupMark(away, "db-1", "juno"), () => moved);
        await gone.StepAsync();
        foreach (var answer in new[] { HubException.Refusal(409, null, "That name is taken.", "name_taken"), HubException.NoAnswer() })
        {
            goneHub.Refuses = route =>
            {
                if (!route.EndsWith("/rename", StringComparison.Ordinal)) return null;
                moved = Fleet(features: Renames) with { Db = "db-2" };
                return answer;
            };
            gone.TypeName("Nova");
            await gone.TakeNameAsync();
            Assert.IsNull(gone.View.Refusal, $"{answer.Message}: nothing of the press counts in another generation");
            moved = Fleet(features: Renames);
        }
    }

    /// <summary>**A rename whose answer is lost after the hub renamed still finds the new name at the next reading** (the
    /// read of U3b, Must 1; the Mac notes the rename before it goes, and keeps the note when no answer comes): the reading
    /// with the new name gives the setup of that name, and the kept mark goes there with its provider. The bug: a mark left,
    /// on disk, on a name that the hub no longer has, so that the window opens Tasks, also after a restart, and the
    /// manager has no server and no way on.</summary>
    [TestMethod]
    public async Task A_rename_whose_answer_is_lost_finds_the_new_name_at_the_next_reading()
    {
        var at = new Uri("http://100.64.0.9:8773/");
        var fleet = Fleet(features: Renames);
        var (setup, hub, choices) = Setup(new ManagerSetupMark(at, "db-1", "juno", "claude"), () => fleet);
        await setup.StepAsync();
        Assert.AreEqual("name", ManagerSetupScreens.Of(setup.View).Name);
        hub.Refuses = route => route.EndsWith("/rename", StringComparison.Ordinal) ? HubException.NoAnswer() : null;
        setup.TypeName("Nova");
        await setup.TakeNameAsync();
        Assert.AreEqual(1, hub.PostsTo("/rename").Count, "the rename reached the hub");
        Assert.AreEqual(("name", AgentSetupModel.NoAnswer), (ManagerSetupScreens.Of(setup.View).Name, ManagerSetupScreens.Of(setup.View).Warning));

        var after = new StoreState { Hub = at, Role = HubRole.Owner, Fleet = Fleet(features: Renames, name: "nova") };
        Assert.AreEqual(new ManagerSetupMark(at, "db-1", "nova", "claude"), ManagerSetupMark.Shown(after, choices), "the setup of the new name");
        Assert.AreEqual(("juno", "nova"), ManagerSetupMark.TakeRename(after, choices));
        Assert.AreEqual(new ManagerSetupMark(at, "db-1", "nova", "claude"), ManagerSetupMark.Read(choices), "the kept mark, with its provider");
    }

    /// <summary>**A press after a rename whose answer was lost finds the hub's answer in the team, and sends no second
    /// rename** (the read of U3b, round 2, Should 1; the Mac's <c>ManagerRename</c>, d95e1044c). The hub has the new name
    /// and the owner's store still holds the reading from before, so the page has the old name and Continue. The bugs: a
    /// second rename, whose 404 the refusal takes the note away, so that at the reading of the new name the window forgets
    /// the manager's chat and opens Tasks; the name from before typed again, which clears the note while the hub has
    /// another name; a third name, which a press leaves on the page; a rename that went through and shows Continue.</summary>
    [TestMethod]
    public async Task A_press_after_a_lost_rename_keeps_its_note_and_sends_no_second_rename()
    {
        var port = 8780;
        // The same name again, the name from before again, and another device's name meanwhile.
        foreach (var (typed, has) in new[] { ("Nova", "nova"), ("Juno", "nova"), ("Nova", "atlas") })
        {
            var at = new Uri($"http://100.64.0.9:{port++}/");
            var fleet = Fleet(features: Renames);
            var (setup, hub, choices) = Setup(new ManagerSetupMark(at, "db-1", "juno", "claude"), () => fleet);
            await setup.StepAsync();
            hub.Refuses = route => route.EndsWith("/rename", StringComparison.Ordinal) ? HubException.NoAnswer() : null;
            setup.TypeName("Nova");
            await setup.TakeNameAsync();
            Assert.AreEqual(1, hub.PostsTo("/rename").Count, "the rename reached the hub");
            Assert.AreEqual((AgentSetupModel.NoAnswer, false), (ManagerSetupScreens.Of(setup.View).Warning, setup.View.Busy), "Continue is on again");

            // The hub has another name; its 404 "no such agent" is what a second rename would get.
            hub.TeamLines = $"[{{\"agent\": \"{has}\", \"role\": \"manager\"}}]";
            hub.Refuses = route => route.EndsWith("/rename", StringComparison.Ordinal)
                ? HubException.Refusal(404, null, "There is no such agent.", "no_such_agent") : null;
            setup.TypeName(typed);
            await setup.TakeNameAsync();
            Assert.AreEqual(1, hub.PostsTo("/rename").Count, $"{typed}: no second rename");
            var page = ManagerSetupScreens.Of(setup.View);
            // The mark has its provider, so the page after the name is the fleet's servers.
            var same = string.Equals(typed, has, StringComparison.OrdinalIgnoreCase);
            Assert.AreEqual((same ? "servers" : "name", (string?)null, false), (page.Name, page.Warning, setup.View.Busy),
                            $"{typed}: the press ends with Continue on, and the page of the name that he asked for goes on");
            await setup.TakeNameAsync();
            Assert.AreEqual(1, hub.PostsTo("/rename").Count, $"{typed}: the next press sends nothing either");

            // The reading of the name that the hub has: the setup and the kept mark go there, with the provider kept.
            var after = new StoreState { Hub = at, Role = HubRole.Owner, Fleet = Fleet(features: Renames, name: has) };
            Assert.AreEqual(new ManagerSetupMark(at, "db-1", has, "claude"), ManagerSetupMark.Shown(after, choices), $"{typed}: the setup of the name that the hub has");
            Assert.AreEqual(("juno", has), ManagerSetupMark.TakeRename(after, choices), $"{typed}: the window moves there");
            Assert.AreEqual(new ManagerSetupMark(at, "db-1", has, "claude"), ManagerSetupMark.Read(choices), typed);

            // The page of that setup: the provider's for the name that he asked for, else the name's page again (the Mac's
            // `renamed(now)`, where a name that is not the wanted one shows its own page).
            var (next, _, _) = Setup(ManagerSetupMark.Read(choices)!, () => Fleet(features: Renames, name: has));
            await next.StepAsync();
            Assert.AreEqual(same ? "servers" : "name", ManagerSetupScreens.Of(next.View).Name, $"{typed}: the page of the name that the hub has ({has})");
        }

        // "No such agent" without a name that the hub has: the note stays, and a later reading finds the name. And the
        // name from before, typed again for a rename that never came: no call but the team's read, and on to the provider.
        var late = new Uri("http://100.64.0.9:8790/");
        var (gone, goneHub, goneChoices) = Setup(new ManagerSetupMark(late, "db-1", "juno"), () => Fleet(features: Renames));
        await gone.StepAsync();
        goneHub.Refuses = route => route.EndsWith("/rename", StringComparison.Ordinal)
            ? HubException.Refusal(404, null, "There is no such agent.", "no_such_agent") : null;
        gone.TypeName("Nova");
        await gone.TakeNameAsync();
        Assert.AreEqual(("name", "There is no such agent."), (ManagerSetupScreens.Of(gone.View).Name, ManagerSetupScreens.Of(gone.View).Warning));
        Assert.IsTrue(ManagerSetupMark.RenameNoted(late, "db-1", "juno"), "the note of a rename that can have been made stays");
        Assert.AreEqual(("juno", "nova"), ManagerSetupMark.TakeRename(new StoreState { Hub = late, Role = HubRole.Owner, Fleet = Fleet(features: Renames, name: "nova") }, goneChoices));

        // Another device renamed the manager before any press of this window: the press finds it, sends nothing, notes
        // it, and the reading takes the page there, to that name's own page.
        var device = new Uri("http://100.64.0.9:8795/");
        var (first, firstHub, firstChoices) = Setup(new ManagerSetupMark(device, "db-1", "juno"), () => Fleet(features: Renames));
        await first.StepAsync();
        firstHub.TeamLines = "[{\"agent\": \"atlas\", \"role\": \"manager\"}]";
        first.TypeName("Nova");
        await first.TakeNameAsync();
        Assert.AreEqual(0, firstHub.PostsTo("/rename").Count, "no rename of a name that is gone");
        Assert.AreEqual("name", ManagerSetupScreens.Of(first.View).Name, "another name than his: its own name page");
        Assert.AreEqual(("juno", "atlas"), ManagerSetupMark.TakeRename(new StoreState { Hub = device, Role = HubRole.Owner, Fleet = Fleet(features: Renames, name: "atlas") }, firstChoices),
                        "the press noted the rename, and the reading moves the window");

        // Nothing is renamed, the name is the one it has, and no press before this one waits: the hub is asked nothing.
        var quiet = new Uri("http://100.64.0.9:8792/");
        var (asks, asksHub, _) = Setup(new ManagerSetupMark(quiet, "db-1", "juno"), () => Fleet(features: Renames));
        await asks.StepAsync();
        var reads = asksHub.Reads;
        asks.TypeName("Juno");
        await asks.TakeNameAsync();
        Assert.AreEqual((reads, "provider"), (asksHub.Reads, ManagerSetupScreens.Of(asks.View).Name), "no call of the hub, and on to the provider");

        var keep = new Uri("http://100.64.0.9:8791/");
        var (kept, keptHub, _) = Setup(new ManagerSetupMark(keep, "db-1", "juno"), () => Fleet(features: Renames));
        await kept.StepAsync();
        keptHub.Refuses = route => route.EndsWith("/rename", StringComparison.Ordinal) ? HubException.NoAnswer() : null;
        kept.TypeName("Nova");
        await kept.TakeNameAsync();
        keptHub.Refuses = null;
        kept.TypeName("Juno");
        await kept.TakeNameAsync();
        Assert.AreEqual(1, keptHub.PostsTo("/rename").Count, "the name from before sends nothing more");
        Assert.AreEqual("provider", ManagerSetupScreens.Of(kept.View).Name, "he goes on with the name that the hub has");
        Assert.IsTrue(ManagerSetupMark.RenameNoted(keep, "db-1", "juno"), "the note of the rename stays: a rename that still comes takes the page with it");

        // A refused read of the team says nothing of a rename (a hub that restarts): the note stays, and the reading of the
        // new name takes the page with it.
        var restarts = new Uri("http://100.64.0.9:8793/");
        var (waits, waitsHub, waitsChoices) = Setup(new ManagerSetupMark(restarts, "db-1", "juno"), () => Fleet(features: Renames));
        await waits.StepAsync();
        waitsHub.Refuses = route => route.EndsWith("/rename", StringComparison.Ordinal) ? HubException.NoAnswer() : null;
        waits.TypeName("Nova");
        await waits.TakeNameAsync();
        waitsHub.Throws = route => route == "ui/team" ? HubException.Refusal(503, null, "The hub restarts.", "restarting") : null;
        await waits.TakeNameAsync();
        Assert.AreEqual(("name", "The hub restarts."), (ManagerSetupScreens.Of(waits.View).Name, ManagerSetupScreens.Of(waits.View).Warning));
        Assert.AreEqual(("juno", "nova"), ManagerSetupMark.TakeRename(new StoreState { Hub = restarts, Role = HubRole.Owner, Fleet = Fleet(features: Renames, name: "nova") }, waitsChoices),
                        "the page goes with the reading of the name");

        // The manager got another name than the one that this window asked for, and a worker has that one: the page goes
        // to the manager, never to the worker.
        var worker = new Uri("http://100.64.0.9:8794/");
        var (taken, takenHub, takenChoices) = Setup(new ManagerSetupMark(worker, "db-1", "juno"), () => Fleet(features: Renames));
        await taken.StepAsync();
        takenHub.Refuses = route => route.EndsWith("/rename", StringComparison.Ordinal) ? HubException.NoAnswer() : null;
        taken.TypeName("Nova");
        await taken.TakeNameAsync();
        var mixed = Fleet(features: Renames, name: "atlas");
        var reading = mixed with { Agents = [new MobileAgent("nova", "worker", "claude", 0, []), .. mixed.Agents] };
        Assert.AreEqual(("juno", "atlas"), ManagerSetupMark.TakeRename(new StoreState { Hub = worker, Role = HubRole.Owner, Fleet = reading }, takenChoices),
                        "the manager's name, not the worker's");
    }

    /// <summary>**The setup's reads go on after a read that throws** (the read of U3: one error that was not the window's
    /// leave ended them for good, while the Mac's <c>try?</c> reads on): the hub's client that gives up throws a cancel of
    /// its own, and an answer of no form an error of another kind. The bug: a page that stands still at its last read, and
    /// a manager whose install and sign-in it never shows.</summary>
    [TestMethod]
    public async Task The_reads_go_on_after_a_read_that_throws()
    {
        var fleet = Fleet();
        var thrown = new Queue<Exception>([new TaskCanceledException("the hub's client gave up"), new ArgumentException("an answer of no form")]);
        var hub = new SetupHub { Servers = SetupHub.ServerList(managerOn: null) };
        hub.Throws = route => route == "ui/servers" && thrown.TryDequeue(out var error) ? error : null;
        using var leave = new CancellationTokenSource();
        var pauses = 0;
        var setup = new ManagerSetup(new ManagerSetupSettings
        {
            Calls = hub, Fleet = () => fleet, Choices = new MemoryChoices(),
            Pause = (_, _) =>
            {
                if (++pauses == 3) leave.Cancel();
                return Task.CompletedTask;
            },
        }, new ManagerSetupMark(Hub, "db-1", "juno"));
        await setup.RunAsync(leave.Token);
        Assert.AreEqual(0, thrown.Count, "both errors came");
        Assert.AreEqual(3, pauses, "three turns, and only the window's leave ended them");
        Assert.IsTrue(setup.View.Answered, "the third read answered");
        Assert.AreEqual("provider", ManagerSetupScreens.Of(setup.View).Name);
    }

    /// <summary>**A current reading of a manager with no server keeps its mark on the owner's computer** (the read of U3,
    /// fault 1; the Mac's <c>notePlacing</c>), also with no first run in this app, as after an app that ended between the
    /// claim and the first reading of the hub. A device, an old reading and a hub without the manager's own setup keep
    /// none; a mark that is there keeps its provider; a manager on its server is read once in a run. The bugs: a PC that
    /// owns a hub whose manager's page is a chat that cannot answer; a reading that takes the provider out of the mark; a
    /// read of the servers at each reading of a fleet whose manager runs.</summary>
    [TestMethod]
    public async Task A_current_reading_of_a_manager_with_no_server_keeps_its_mark()
    {
        var choices = new MemoryChoices();
        var hub = new SetupHub { Servers = SetupHub.ServerList(managerOn: null) };
        var placing = new ManagerPlacing(hub, choices);
        var now = DateTimeOffset.UtcNow;
        var state = new StoreState { Hub = Hub, Role = HubRole.Owner, Fleet = Fleet(), LastRead = now, Clock = now };
        await placing.NoteAsync(state with { Role = HubRole.Device }, now);
        await placing.NoteAsync(state with { LastRead = now - TimeSpan.FromMinutes(5) }, now);
        await placing.NoteAsync(state with { Fleet = Fleet(features: ["servers", "machines", "machine_signin", "agent_setup"]) }, now);
        Assert.AreEqual((null as ManagerSetupMark, 0), (ManagerSetupMark.Read(choices), hub.Reads));

        await placing.NoteAsync(state, now);
        var mark = ManagerSetupMark.Read(choices);
        Assert.IsNotNull(mark, "the manager with no server has its mark");
        Assert.AreEqual(("juno", "db-1", null as string, null as string), (mark.Agent, mark.Db, mark.Provider, mark.Joined));
        Assert.AreEqual(mark, ManagerSetupMark.Shown(state, choices), "the window shows its setup");
        Assert.IsNull(ManagerSetupMark.Shown(state with { Role = HubRole.Device }, choices));

        new ManagerSetupMark(Hub, "db-1", "juno", "claude", "worker-2").Keep(choices);
        await placing.NoteAsync(state, now);
        Assert.AreEqual(("claude", "worker-2"), (ManagerSetupMark.Read(choices)!.Provider, ManagerSetupMark.Read(choices)!.Joined));

        // A rename that this app has no note of (another computer's, or an app that ended before the reading of the new
        // name): the kept mark follows the manager's name now, with its provider and its joined server (piece U3b's read).
        await placing.NoteAsync(state with { Fleet = Fleet(name: "nova") }, now);
        Assert.AreEqual(("nova", "claude", "worker-2"), (ManagerSetupMark.Read(choices)!.Agent, ManagerSetupMark.Read(choices)!.Provider,
                                                         ManagerSetupMark.Read(choices)!.Joined), "the mark of a renamed manager");
        Assert.AreEqual("nova", ManagerSetupMark.Shown(state with { Fleet = Fleet(name: "nova") }, choices)?.Agent, "its setup shows");

        ManagerSetupMark.Forget(choices);
        hub.Servers = SetupHub.ServerList(managerOn: "worker-2");
        var reads = hub.Reads;
        await placing.NoteAsync(state, now);
        await placing.NoteAsync(state, now);
        Assert.AreEqual((null as ManagerSetupMark, reads + 1), (ManagerSetupMark.Read(choices), hub.Reads));
    }
}

/// <summary>**The hub's owner routes of an agent's setup**, as the test sets them: its list of servers, its machines, its
/// team; each write is kept with its body, and a refusal by its route.</summary>
internal sealed class SetupHub : OwnerReads.ICalls
{
    public string? Database { get; set; } = "db-1";
    /// <summary>The team's lines (GET /ui/team), the manager alone unless a test gives others.</summary>
    public string TeamLines { get; set; } = "[{\"agent\": \"juno\", \"role\": \"manager\"}]";
    public string Servers { get; set; } = ServerList(managerOn: null);
    public string Machines { get; set; } = "{\"db\": \"db-1\", \"machines\": []}";
    public bool ServersFail { get; set; }
    /// <summary>The SHA-256 of the team.json of each next read, in order; then the same one each time.</summary>
    public System.Collections.Concurrent.ConcurrentQueue<string> TeamShas { get; } = new();
    /// <summary>An error of a read, by its route, that is not the hub's (the hub's client that gives up, an answer of no form).</summary>
    public Func<string, Exception?>? Throws { get; set; }
    public Func<string, HubException?>? Refuses { get; set; }
    /// <summary>Called with a write's route after the write reached the hub and before its answer (a page that leaves
    /// then cancels the write's wait).</summary>
    public Action<string>? BeforeAnswer { get; set; }
    private readonly List<(string Route, string Body)> posts = [];

    public List<string> PostsTo(string end)
    {
        lock (posts) return posts.Where(p => p.Route.EndsWith(end, StringComparison.Ordinal)).Select(p => p.Body).ToList();
    }

    /// <summary>The route of each write that reached the hub, in order.</summary>
    public List<string> Routes { get { lock (posts) return posts.Select(p => p.Route).ToList(); } }

    /// <summary>The reads that reached the hub.</summary>
    public int Reads => reads;
    private int reads;

    public Task<OwnerAnswer<T>> GetAsync<T>(string route, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type, int limit,
                                            CancellationToken cancel) where T : class
    {
        Interlocked.Increment(ref reads);
        if (Throws?.Invoke(route) is { } error) throw error;
        var json = route switch
        {
            "ui/servers" when ServersFail => throw HubException.NoAnswer(),
            "ui/servers" => Servers,
            "ui/machines" => Machines,
            "ui/team" => "{\"db\": \"db-1\", \"revision\": \"" + new string('a', 40) + "\", \"sha256\": \"" +
                         (TeamShas.TryDequeue(out var sha) ? sha : new string('b', 64)) +
                         "\", \"lines\": " + TeamLines + ", \"open_tasks\": {}}",
            _ => throw new InvalidOperationException("no read " + route),
        };
        return Task.FromResult(new OwnerAnswer<T>(JsonSerializer.Deserialize(json, type)));
    }

    public Task<OwnerAnswer<TAnswer>> PostAsync<TBody, TAnswer>(string route, TBody body,
        System.Text.Json.Serialization.Metadata.JsonTypeInfo<TBody> bodyType,
        System.Text.Json.Serialization.Metadata.JsonTypeInfo<TAnswer> answerType, Guid? requestId, CancellationToken cancel) where TAnswer : class
    {
        lock (posts) posts.Add((route, JsonSerializer.Serialize(body, bodyType)));
        BeforeAnswer?.Invoke(route);
        cancel.ThrowIfCancellationRequested();
        if (Refuses?.Invoke(route) is { } refused) throw refused;
        var id = requestId!.Value.ToString("D");
        var part = route.Split('/');
        var json = body switch
        {
            MoveAsk move => $"{{\"ok\": true, \"request_id\": \"{id}\", \"agent\": \"juno\", \"server\": \"{move.Server}\", \"runtime\": \"{move.Runtime}\", \"job\": 7, " +
                            $"\"revision\": \"{new string('a', 40)}\", \"sha256\": \"{new string('c', 64)}\"}}",
            CheckAsk check => $"{{\"ok\": true, \"request_id\": \"{id}\", \"agent\": \"{check.Agent}\", \"changed\": true, " +
                              "\"check\": {\"id\": 4, \"state\": \"requested\", \"requested_at\": 1763700095, \"completed_at\": null, \"detail\": null}}",
            ActivationAsk => $"{{\"ok\": true, \"request_id\": \"{id}\", \"agent\": \"{part[^1]}\", \"revision\": \"{new string('a', 40)}\", " +
                             $"\"sha256\": \"{new string('c', 64)}\", \"changed\": [{{\"field\": \"active\", \"before\": false, \"after\": true}}], " +
                             "\"updates_requested\": [], \"settings_pending\": false, \"activation\": {\"check\": 4, \"checked_at\": 1763700098}}",
            AgentAsk add => $"{{\"ok\": true, \"request_id\": \"{id}\", \"agent\": \"{add.Agent}\", \"server\": \"{part[2]}\", \"runtime\": \"{add.Runtime}\", " +
                            $"\"job\": 8, \"revision\": \"{new string('a', 40)}\", \"sha256\": \"{new string('c', 64)}\"}}",
            JoinAsk => $"{{\"ok\": true, \"request_id\": \"{id}\", \"name\": \"\", \"kind\": \"linux\", \"expires_at\": 1763703600, \"code\": \"7KMQ2PRJ4TVW\", " +
                       "\"line\": \"curl -fsS http://100.64.0.9:8765/join | FLEET_JOIN=7KMQ2PRJ4TVW sh\"}",
            // The rename of a manager with no server: no job and no server (POST /ui/team/agents/<agent>/rename).
            RenameAsk rename => $"{{\"ok\": true, \"request_id\": \"{id}\", \"agent\": \"{rename.Name}\", \"was\": \"{route.Split('/')[3]}\", " +
                                $"\"server\": null, \"job\": null, \"revision\": \"{new string('a', 40)}\", \"sha256\": \"{new string('d', 64)}\"}}",
            _ => $"{{\"ok\": true, \"request_id\": \"{id}\"}}",
        };
        return Task.FromResult(new OwnerAnswer<TAnswer>(JsonSerializer.Deserialize(json, answerType)));
    }

    /// <summary>The hub's server and worker-2, with the manager on <paramref name="managerOn"/> or on none, and the newest
    /// job of worker-2.</summary>
    public static string ServerList(string? managerOn, string? job = null, string server = "worker-2") =>
        "{\"db\": \"db-1\", \"time\": 1763700100, \"servers\": [" +
        "{\"name\": \"worker-1\", \"hub\": true, \"joined\": true, \"agents\": [], \"available\": false, \"why\": []}, " +
        $"{{\"name\": \"{server}\", \"hub\": false, \"joined\": true, \"agents\": [{(managerOn == server ? "\"juno\"" : "")}], " +
        $"\"available\": {(managerOn is null ? "true" : "false")}, \"why\": []{(job is null ? "" : ", \"job\": " + job)}}}]}}";

    /// <summary>A fleet of "1 server" whose hub's own server takes agents (the hub's shape kept, shared): it takes the
    /// manager once it is <paramref name="available"/>.</summary>
    public static string SharedHub(bool available) =>
        "{\"db\": \"db-1\", \"time\": 1763700100, \"hub_shared\": true, \"shape\": {\"step\": \"one\"}, \"servers\": [" +
        $"{{\"name\": \"worker-1\", \"hub\": true, \"joined\": true, \"agents\": [], \"available\": {(available ? "true" : "false")}, \"why\": []}}]}}";

    public static string Job(string state, string step) =>
        $"{{\"id\": 7, \"kind\": \"install\", \"state\": \"{state}\", \"created\": 1763700000, \"updated\": 1763700090, \"agent\": \"juno\", " +
        $"\"runtime\": \"claude\", \"step\": \"{step}\"}}";

    public static string Login(string runtime, string state, string? url = null, bool wantsCode = false, string? shows = null) =>
        $"{{\"id\": 7, \"runtime\": \"{runtime}\", \"state\": \"{state}\", \"started_at\": 1763700000, \"updated_at\": 1763700060, " +
        $"\"wants_code\": {(wantsCode ? "true" : "false")}{(url is null ? "" : $", \"url\": \"{url}\"")}{(shows is null ? "" : $", \"shows_code\": \"{shows}\"")}}}";

    /// <summary>The manager's machine on worker-2, signed out of <paramref name="runtime"/> (or in), with a sign-in or none.</summary>
    public static string MachineList(string runtime, string? login, bool signedIn = false) =>
        "{\"db\": \"db-1\", \"machines\": [{\"agent\": \"juno\", \"machine\": \"worker-2\", \"role\": \"manager\", \"update\": {\"state\": \"current\"}, " +
        $"\"security\": {{}}, \"os\": {{}}, \"reported_at\": 1763700090, \"stale\": false, \"runtime\": {{\"name\": \"{runtime}\", \"signed_in\": {(signedIn ? "true" : "false")}}}" +
        (login is null ? "" : ", \"login\": " + login) + "}]}";
}
