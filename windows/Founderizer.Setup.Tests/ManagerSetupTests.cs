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
    private static MobileSnapshot Fleet(string runtime = "claude", string alive = "", IReadOnlyList<string>? features = null) =>
        new(1, "db-1", 1763700100, [new MobileAgent("juno", "manager", runtime, 0, [], Title: "Fleet Manager", Active: true, Alive: alive)],
            [], [], [], [], [], UiFeatures: features ?? ["servers", "machines", "machine_signin", "agent_setup", "manager_server"]);

    private static (ManagerSetup Setup, SetupHub Hub, MemoryChoices Choices) Setup(ManagerSetupMark mark, Func<MobileSnapshot?> fleet,
                                                                                  SetupHub? hub = null, Func<Task>? refresh = null,
                                                                                  Func<bool>? fresh = null)
    {
        var choices = new MemoryChoices();
        mark.Keep(choices);
        hub ??= new SetupHub();
        return (new ManagerSetup(new ManagerSetupSettings { Calls = hub, Fleet = fleet, Choices = choices, Refresh = refresh, Fresh = fresh }, mark),
                hub, choices);
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
        Assert.AreEqual(("provider", "Fleet Manager's AI provider", "worker-2 takes no agent now."), (screen.Name, screen.Title, screen.Warning));
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
        Assert.AreEqual(("settingUp", "Setting up Fleet Manager", true, true), (screen.Name, screen.Title, screen.Waits, screen.Making));
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
        Assert.AreEqual(AgentSetupModel.CannotReadServer("Fleet Manager"), ManagerSetupScreens.Of(setup.View).Warning);
        Assert.AreEqual(0, hub.PostsTo("/move").Count);

        hub.ServersFail = false;
        hub.Servers = SetupHub.ServerList(managerOn: null);
        await setup.StepAsync();
        Assert.AreEqual(1, hub.PostsTo("/move").Count, "the first list that answers goes on by itself");
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
    public string? Database => "db-1";
    public string Servers { get; set; } = ServerList(managerOn: null);
    public string Machines { get; set; } = "{\"db\": \"db-1\", \"machines\": []}";
    public bool ServersFail { get; set; }
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
            "ui/team" => "{\"db\": \"db-1\", \"revision\": \"" + new string('a', 40) + "\", \"sha256\": \"" + new string('b', 64) +
                         "\", \"lines\": [{\"agent\": \"juno\", \"role\": \"manager\"}], \"open_tasks\": {}}",
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
        var json = body is MoveAsk move
            ? $"{{\"ok\": true, \"request_id\": \"{id}\", \"agent\": \"juno\", \"server\": \"{move.Server}\", \"runtime\": \"{move.Runtime}\", \"job\": 7, " +
              $"\"revision\": \"{new string('a', 40)}\", \"sha256\": \"{new string('c', 64)}\"}}"
            : $"{{\"ok\": true, \"request_id\": \"{id}\"}}";
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
