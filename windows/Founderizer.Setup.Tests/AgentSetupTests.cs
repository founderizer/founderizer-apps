using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Remote;
using Founderizer.Setup.Agents;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The setup of an agent that is not the manager, and the server's page of a manager with no server**
/// (windows-app-plan-v2.md, piece L4b; the Mac's <c>AgentSetupWizard</c> and <c>AddServerView</c> with <c>placing</c>), over
/// stand-ins of the hub's owner routes, the tailnet, a provider and a server.</summary>
[TestClass]
public sealed class AgentSetupTests
{
    private static readonly Uri Hub = new("http://100.64.0.9:8765/");
    private static readonly string[] Features = ["servers", "machines", "machine_signin", "agent_setup", "manager_server"];
    private const double Time = 1763700100;

    /// <summary>The hub's reading: the manager, and Iris, a worker that a team card added, active or in setup.</summary>
    private static MobileSnapshot Fleet(bool irisActive) =>
        new(1, "db-1", Time, [new MobileAgent("juno", "manager", "claude", 0, [], Title: "Fleet Manager", Active: true, Alive: "manager"),
                              new MobileAgent("iris", "worker", "claude", 0, [], Active: irisActive)],
            [], [], [], [], [], UiFeatures: Features);

    /// <summary>The hub's servers: its own, the manager's, and Iris's with its install's job.</summary>
    private static string Servers(string job) =>
        "{\"db\": \"db-1\", \"time\": 1763700100, \"servers\": [" +
        "{\"name\": \"worker-1\", \"hub\": true, \"joined\": true, \"agents\": [], \"available\": false, \"why\": []}, " +
        "{\"name\": \"worker-2\", \"hub\": false, \"joined\": true, \"agents\": [\"juno\"], \"available\": false, \"why\": []}, " +
        $"{{\"name\": \"worker-3\", \"hub\": false, \"joined\": true, \"agents\": [\"iris\"], \"available\": false, \"why\": [], \"job\": {job}}}]}}";

    private static string Job(string state, string step, string more = "") =>
        $"{{\"id\": 9, \"kind\": \"install\", \"state\": \"{state}\", \"created\": 1763700000, \"updated\": 1763700090, \"agent\": \"iris\", " +
        $"\"runtime\": \"claude\", \"step\": \"{step}\"{more}}}";

    /// <summary>Iris's machine: signed in or not, its sign-in, its newest check and the result of it.</summary>
    private static string Machines(bool signedIn, string? login = null, string? check = null, string? verify = null) =>
        "{\"db\": \"db-1\", \"desired_revision\": \"" + new string('a', 40) + "\", \"machines\": [{\"agent\": \"iris\", \"machine\": \"worker-3\", " +
        "\"role\": \"worker\", \"update\": {\"state\": \"current\"}, \"security\": {}, \"os\": {}, \"reported_at\": 1763700090, \"stale\": false, " +
        "\"settings_pending\": false, \"revision\": \"" + new string('a', 40) + "\", " +
        $"\"runtime\": {{\"name\": \"claude\", \"signed_in\": {(signedIn ? "true" : "false")}}}" +
        (login is null ? "" : ", \"login\": " + login) + (check is null ? "" : ", \"check\": " + check) + (verify is null ? "" : ", \"verify\": " + verify) + "}]}";

    private static string Check(long id, string state, string? detail = null) =>
        $"{{\"id\": {id}, \"state\": \"{state}\", \"requested_at\": 1763700095" +
        (state == "requested" ? "" : ", \"completed_at\": 1763700098") + (detail is null ? "" : $", \"detail\": \"{detail}\"") + "}";

    /// <summary>The result of the check: its service passed, its sign-in passed or not.</summary>
    private static string Verify(long check, bool passes) =>
        $"{{\"check\": {check}, \"checked_at\": 1763700098, \"revision\": \"{new string('a', 40)}\", \"holds\": true, \"items\": [" +
        "{\"kind\": \"service\", \"ref\": \"fleet_service\", \"state\": \"ok\", \"detail\": \"\", \"required\": true}, " +
        $"{{\"kind\": \"login\", \"ref\": \"shop_login\", \"state\": \"{(passes ? "ok" : "missing")}\", \"detail\": \"{(passes ? "" : "The vault has no such login.")}\", \"required\": true}}]}}";

    private static ManagerSetup Iris(SetupHub hub, Func<MobileSnapshot?> fleet, ISetupChoices choices, Func<Task>? refresh = null) =>
        ManagerSetup.ForAgent(new ManagerSetupSettings { Calls = hub, Fleet = fleet, Choices = choices, Refresh = refresh }, Hub, "db-1", "iris");

    /// <summary>**An agent that a team card added goes from its server to its first session with no press but the sign-in**
    /// (proof B): its install, the owner's sign-in, then its machine's check and its activation, each once and by
    /// itself, and its chat. The bugs: an agent that is signed in and stands at "Setting up" for ever, because its setup
    /// takes it for a manager that is active from the start; a check or an activation at each read; a setup that takes the
    /// manager's kept mark, or its steps, for another agent's.</summary>
    [TestMethod]
    public async Task An_agent_that_a_team_card_added_goes_to_its_first_session_with_no_press_but_the_sign_in()
    {
        var fleet = Fleet(irisActive: false);
        var choices = new MemoryChoices();
        var mark = new ManagerSetupMark(Hub, "db-1", "juno", "claude", "worker-2");
        mark.Keep(choices);
        var hub = new SetupHub { Servers = Servers(Job("running", "checkout")), Machines = "{\"db\": \"db-1\", \"machines\": []}" };
        var setup = Iris(hub, () => fleet, choices, () =>
        {
            fleet = Fleet(irisActive: hub.PostsTo("ui/team/agents/iris").Count > 0);
            return Task.CompletedTask;
        });
        Assert.IsNull(ManagerSetupScreens.Of(setup.View).Progress, "no steps of the manager's first setup");
        Assert.IsTrue(AgentSetupFlow.Shows(SetupAgent.Of(fleet.Agents[1], null, null), Features), "the fleet's own reading shows its setup");

        await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("installing", "Installing Claude Code on worker-3", null as SetupProgress), (screen.Name, screen.Title, screen.Progress));
        Assert.IsTrue(setup.View.TakesChat && !setup.View.Shows && !ManagerSetupScreens.TakesWindow(setup.View), "in place of its chat, and not over the window");

        // The server's job starts the sign-in on the agent's machine, and the owner signs in: his one press.
        hub.Servers = Servers(Job("needs_owner", "sign_in", ", \"prompt\": {\"kind\": \"signin\", \"purpose\": \"claude_login\"}"));
        hub.Machines = Machines(false, SetupHub.Login("claude", "needs_owner", url: "https://claude.ai/oauth/authorize?code=true", wantsCode: true));
        await setup.StepAsync();
        Assert.AreEqual(("signIn", "Sign in to Claude Code"), (ManagerSetupScreens.Of(setup.View).Name, ManagerSetupScreens.Of(setup.View).Title));
        Assert.IsTrue(await setup.SendCodeAsync("abcDEF123-code-of-the-test"));

        // Signed in: its machine's check goes by itself, once.
        hub.Servers = Servers(Job("done", "sign_in"));
        hub.Machines = Machines(true);
        await setup.StepAsync();
        await setup.StepAsync();
        screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("settingUp", "Setting up Iris", true, null as string), (screen.Name, screen.Title, screen.Waits, screen.Warning));
        CollectionAssert.AreEqual(new[] { "{\"agent\":\"iris\",\"note\":\"\"}" }, hub.PostsTo("ui/machines/iris/check"), "one check");

        hub.Machines = Machines(true, check: Check(4, "requested"));
        await setup.StepAsync();
        Assert.AreEqual(0, hub.PostsTo("ui/team/agents/iris").Count, "the check has no result yet");

        // The check passed: the activation goes by itself, once, and its answer has the owner's store read the fleet again.
        hub.Machines = Machines(true, check: Check(4, "completed"), verify: Verify(4, passes: true));
        await setup.StepAsync();
        CollectionAssert.AreEqual(new[] { "{\"base_sha256\":\"" + new string('b', 64) + "\",\"active\":true}" }, hub.PostsTo("ui/team/agents/iris"));
        Assert.AreEqual(true, setup.View.Reading?.Agent?.Active, "the owner's store read the fleet again right after the activation, in the same turn");
        await setup.StepAsync();

        Assert.IsTrue(setup.View is { Ended: true, TakesChat: false }, "active and signed in: its chat");
        CollectionAssert.AreEqual(new[] { "ui/machines/iris/signin/code", "ui/machines/iris/check", "ui/team/agents/iris" }, hub.Routes, "no other write");
        Assert.AreEqual(mark, ManagerSetupMark.Read(choices), "the manager's own mark stays as it was");
    }

    /// <summary>**A check that does not pass shows the Mac's one line over Try again, and activates nothing** (the Mac's
    /// <c>activationState</c> and <c>blocker</c>), also at later reads; Try again runs the check again and, once it passed,
    /// the activation. An activation that the hub refuses shows the hub's own words and goes again only by Try again. The
    /// bugs: an agent activated with a login that it cannot use; a page that moves for ever after a check that failed, with
    /// no word of why; a check or a refused activation sent at each read.</summary>
    [TestMethod]
    public async Task A_check_that_does_not_pass_shows_its_one_line_and_activates_nothing()
    {
        var fleet = Fleet(irisActive: false);
        var hub = new SetupHub { Servers = Servers(Job("done", "sign_in")), Machines = Machines(true) };
        var setup = Iris(hub, () => fleet, new MemoryChoices());
        await setup.StepAsync();
        hub.Machines = Machines(true, check: Check(4, "completed"), verify: Verify(4, passes: false));
        for (var read = 0; read < 3; read++) await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("activate", "Activate Iris", false, "Shop Login: The vault has no such login."), (screen.Name, screen.Title, screen.Waits, screen.Warning));
        Assert.AreEqual(("agent-setup-again", SetupScreens.TryAgain), (screen.Controls.Single().Id, screen.Controls.Single().Words));
        CollectionAssert.AreEqual(new[] { "ui/machines/iris/check" }, hub.Routes, "one check, and no activation");

        // A check that failed itself says its own detail.
        hub.Machines = Machines(true, check: Check(5, "failed", "The helper did not answer."));
        await setup.StepAsync();
        Assert.AreEqual("The helper did not answer.", ManagerSetupScreens.Of(setup.View).Warning);

        await setup.TryAgainAsync();
        Assert.AreEqual(("settingUp", 2), (ManagerSetupScreens.Of(setup.View).Name, hub.PostsTo("ui/machines/iris/check").Count), "Try again checks again");
        hub.Machines = Machines(true, check: Check(6, "completed"), verify: Verify(6, passes: true));
        hub.Refuses = route => route == "ui/team/agents/iris" ? HubException.Refusal(409, null, "Iris cannot be activated yet.", "not_ready") : null;
        for (var read = 0; read < 3; read++) await setup.StepAsync();
        screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("activate", "Iris cannot be activated yet.", 1), (screen.Name, screen.Warning, hub.PostsTo("ui/team/agents/iris").Count));

        // A new visit of the page asks once more, as the Mac's view whose states start again; still refused, its words.
        setup.Visit();
        for (var read = 0; read < 2; read++) await setup.StepAsync();
        screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("activate", "Iris cannot be activated yet.", 2), (screen.Name, screen.Warning, hub.PostsTo("ui/team/agents/iris").Count));

        hub.Refuses = null;
        await setup.TryAgainAsync();
        Assert.AreEqual(("settingUp", 3), (ManagerSetupScreens.Of(setup.View).Name, hub.PostsTo("ui/team/agents/iris").Count));
        Assert.IsFalse(setup.View.Ended, "until the hub's reading shows it active");

        // While the owner's store cannot send a write, a stop has its line and no Try again (the Mac's store.canWrite).
        var blocked = ManagerSetup.ForAgent(new ManagerSetupSettings { Calls = hub, Fleet = () => fleet, Choices = new MemoryChoices(), CanWrite = () => false },
                                            Hub, "db-1", "iris");
        hub.Machines = Machines(true);
        await blocked.StepAsync();
        hub.Machines = Machines(true, check: Check(8, "completed"), verify: Verify(8, passes: false));
        for (var read = 0; read < 2; read++) await blocked.StepAsync();
        Assert.AreEqual(("activate", 0), (ManagerSetupScreens.Of(blocked.View).Name, ManagerSetupScreens.Of(blocked.View).Controls.Count));
    }

    /// <summary>**A server that another agent took meanwhile is not given** to a manager with no server: neither the one that
    /// joined in the first run, nor a free one of the fleet that the owner took at that moment, nor the new one that this
    /// PC made and that joined (or the first run's, whose join did not end and which the page installs by itself, with no
    /// second server). Its page shows again and nothing of it is kept; a server that is still free then goes to the
    /// manager by itself, with its provider. The bugs: two agents on one server; a manager that stays with a server that
    /// it never gets, at each start of the app; a second paid server for one that the first run made.</summary>
    [TestMethod]
    public async Task A_server_that_another_agent_took_meanwhile_is_not_given()
    {
        await using var rig = new ServerRig();
        var hub = rig.HubCalls;
        // The first run's server joined, and Iris has it now.
        hub.Servers = ServerRig.List(("worker-2", "iris", false), ("worker-5", null, true));
        var setup = rig.Setup(joined: "worker-2");
        await setup.StepAsync();
        await setup.StepAsync();
        Assert.AreEqual(("server", "Juno's server"), (ManagerSetupScreens.Of(setup.View).Name, ManagerSetupScreens.Of(setup.View).Title));
        CollectionAssert.AreEqual(new[] { "worker-5" }, setup.View.Free.ToArray(), "what a manager with no server can take");
        Assert.AreEqual(0, hub.PostsTo("/move").Count, "no server that another agent has");

        // The page showed worker-5 free, and Iris took it before the press.
        setup = rig.Setup(joined: null);
        await setup.StepAsync();
        hub.Servers = ServerRig.List(("worker-5", "iris", false));
        Assert.IsFalse(await setup.TakeServerAsync("worker-5"));
        Assert.IsFalse(await setup.TakeServerAsync("worker-1"), "never the hub's own server");
        Assert.IsFalse(await setup.TakeServerAsync("worker-9"), "nor one that left the fleet");
        Assert.AreEqual((0, null as string), (hub.PostsTo("/move").Count, ManagerSetupMark.Read(rig.Choices)!.Joined));

        // The first run made worker-2 and its join did not end: its page installs it by itself, once, with no order at the
        // provider. The hub then lists it with Iris on it: it is not given.
        hub.Servers = ServerRig.List();
        rig.Joins = name => hub.Servers = ServerRig.List((name, "iris", false));
        setup = rig.Setup(joined: null, made: rig.Made("worker-2"));
        await setup.StepAsync();
        await rig.Until(setup, v => v.NewServer is { Runs: false } && rig.Joined.Count == 1, "the first run's server to end its join");
        await setup.StepAsync();
        await setup.StepAsync();
        CollectionAssert.AreEqual(new[] { "worker-2" }, rig.Joined, "once");
        Assert.AreEqual((0, 0, null as string, "server"),
                        (rig.Cloud.Orders.Count, hub.PostsTo("/move").Count, ManagerSetupMark.Read(rig.Choices)!.Joined, ManagerSetupScreens.Of(setup.View).Name));

        // A new server at the provider, for this hub: it joins and, free, goes to the manager by itself.
        hub.Servers = ServerRig.List(("worker-2", "iris", false));
        rig.Joins = name => hub.Servers = ServerRig.List(("worker-2", "iris", false), (name, null, true));
        setup.Server!.ChooseProvider(CloudProvider.Hetzner);
        await rig.Until(setup, v => v.NewServer?.Cloud.Offer is not null, "the offer");
        Assert.IsTrue(await setup.Server.MakeServerAsync());
        await rig.Until(setup, _ => hub.PostsTo("/move").Count == 1, "the new server given");
        Assert.AreEqual("worker-3", rig.Cloud.Orders.Single().Name);
        StringAssert.Contains(hub.PostsTo("/move")[0], "\"server\":\"worker-3\",\"runtime\":\"claude\"");
        Assert.AreEqual("worker-3", ManagerSetupMark.Read(rig.Choices)!.Joined);
        Assert.AreEqual(Hub.ToString(), rig.Records.Builds.All().Single(r => r.Name == "worker-3").Hub, "Start again of this hub finds it");

        // The command meets a changed team, and another agent took the server meanwhile: it does not go again.
        var raced = rig.Setup(joined: null);
        hub.Servers = ServerRig.List(("worker-6", null, true));
        var refused = 0;
        hub.Refuses = route =>
        {
            if (!route.EndsWith("/move", StringComparison.Ordinal) || refused++ > 0) return null;
            hub.Servers = ServerRig.List(("worker-6", "iris", false));
            return HubException.Refusal(409, null, "The team changed.", "team_changed");
        };
        await raced.StepAsync();
        Assert.IsTrue(await raced.TakeServerAsync("worker-6"), "free when it was read");
        Assert.AreEqual(2, hub.PostsTo("/move").Count, "the one command that met the changed team, and no second one");
        Assert.AreEqual(("provider", "The team changed."), (ManagerSetupScreens.Of(raced.View).Name, ManagerSetupScreens.Of(raced.View).Warning),
                        "the refusal's words, as the Mac's");
        hub.Refuses = null;
    }

    /// <summary>**The page installs by itself only the server that the first run made, and once** (the Mac's
    /// <c>installFirst</c> and <c>noteMadeServer</c>): the server that the mark keeps, at the address that the first run
    /// gave it, which leaves the mark once its join ended well; never a build of an earlier run or of this page. The bugs: a
    /// server that the owner left at Back joined as root at the next start of the app; the first run's server joined again
    /// at each start; a server joined at another address than the first run's.</summary>
    [TestMethod]
    public async Task Only_the_first_runs_server_joins_by_itself_and_once()
    {
        await using var rig = new ServerRig();
        rig.HubCalls.Servers = ServerRig.List();
        // This page made worker-3 in an earlier run of the app, and its join stopped: a new start joins nothing.
        rig.Made("worker-3");
        var setup = rig.Setup(joined: null);
        await setup.StepAsync();
        await setup.StepAsync();
        Assert.AreEqual(("server", InstallView.None), (ManagerSetupScreens.Of(setup.View).Name, setup.View.NewServer!.Install), "no join of an earlier build");

        // The first run's server, which this PC's network has at another address now: it stays in the mark.
        var first = rig.Made("worker-2");
        setup = rig.Setup(joined: null, made: first with { Address = "100.64.0.99" });
        await setup.StepAsync();
        await setup.StepAsync();
        Assert.AreEqual((InstallView.None, "worker-2"), (setup.View.NewServer!.Install, ManagerSetupMark.Read(rig.Choices)!.Made?.Name));

        // At its own address: it joins by itself, and leaves the mark once its join ended well.
        setup = rig.Setup(joined: null, made: first);
        await setup.StepAsync();
        await rig.Until(setup, v => v.NewServer is { Runs: false } && rig.Joined.Count == 1, "the first run's server to end its join");
        Assert.IsNull(ManagerSetupMark.Read(rig.Choices)!.Made, "the mark lets it go once its join ended well");

        // The next start of the app joins it no more.
        setup = rig.Start();
        await setup.StepAsync();
        await setup.StepAsync();
        Assert.AreEqual(InstallView.None, setup.View.NewServer!.Install, "once");
    }

    /// <summary>**The page joins the first run's server once by itself, and after a stop of that join only by Try again**
    /// (the PC's departure from the Mac until wave C, PARITY.md <c>manager_server</c>): a stop of the first run's own join
    /// of it holds nothing, so the first opening joins it, as the Mac does; the mark notes that this join started and keeps
    /// the server until a join of it ended well, and this PC's install records keep the stop, so more reads, Back, a new
    /// visit and a new start each leave it at that one join, and an opening shows its stop with Try again. A join of the
    /// page that a closed app cut off counts as a stop, with the words of the step where it was; a stop of another server,
    /// or of this name at another address, counts for nothing. The bugs: a first run's server that the page never joins by
    /// itself, because the first run's own join of it stopped; a paid server that the PC can never join again; a join by
    /// itself at each opening of a server whose cause lasts, each with no Back for as long as its steps' limits.</summary>
    [TestMethod]
    public async Task A_first_run_server_whose_join_stopped_joins_again_only_by_try_again()
    {
        await using var rig = new ServerRig();
        rig.HubCalls.Servers = ServerRig.List();
        var first = rig.Made("worker-2");
        rig.JoinRecord("100.64.0.99", "worker-2", InstallOutcome.Stopped);        // this name at an earlier hub's address
        rig.JoinRecord(rig.Made("worker-3").Address, "worker-3", InstallOutcome.Stopped);
        rig.JoinRecord(first.Address, "worker-2", InstallOutcome.Stopped);          // the first run's own join of it, which stopped
        // A cause that lasts: the server never takes the join.
        rig.First = call => call.Program.Contains("FLEET_JOIN=", StringComparison.Ordinal)
            ? StandInRemote.Said("Founderizer join stopped: package lists could not be updated", 1) : null;
        var setup = rig.Setup(joined: null, made: first);
        await setup.StepAsync();
        await rig.Until(setup, v => v.NewServer is { Runs: false, Install.Failure: not null }, "the join by itself to stop");
        for (var read = 0; read < 3; read++) await setup.StepAsync();
        setup.Server!.Back();
        await setup.StepAsync();
        Assert.AreEqual((4, InstallView.None, true), (rig.Records.Installs.All().Count, setup.View.NewServer!.Install, ManagerSetupMark.Read(rig.Choices)!.Made?.Tried),
                        "one join by itself, which the mark notes, also after Back");

        // A new visit, then a new start: its stop with Try again, and no join by itself.
        setup.Visit();
        await setup.StepAsync();
        AssertStop(setup, "worker-2", "Package lists could not be updated");

        // Newer joins that ended well: of another server, of this name at another address, and of another name at this
        // address (a device that Tailscale registered again). None of them is this server's.
        rig.JoinRecord(rig.Network.AddressOf("worker-3"), "worker-3", InstallOutcome.Done);
        rig.JoinRecord("100.64.0.99", "worker-2", InstallOutcome.Done);
        rig.JoinRecord(first.Address, "worker-9", InstallOutcome.Done);
        setup = rig.Start();
        await setup.StepAsync();
        await setup.StepAsync();
        AssertStop(setup, "worker-2", "It stopped at “Join the fleet”.");
        Assert.AreEqual(7, rig.Records.Installs.All().Count, "no second join by itself");

        // Try again joins it once more, on the kept record's server; a join that ended well lets it go from the mark.
        rig.First = null;
        Assert.IsTrue(setup.Server!.JoinAgain());
        await rig.Until(setup, v => v.NewServer is { Runs: false } && rig.Joined.Count == 1, "the join of Try again to end");
        Assert.AreEqual((8, null as FirstRunServer), (rig.Records.Installs.All().Count, ManagerSetupMark.Read(rig.Choices)!.Made));

        // A join of the page that a closed app cut off counts as a stop, with the words of the step where it was.
        var cut = rig.Made("worker-4");
        rig.JoinRecord(cut.Address, "worker-4", InstallOutcome.Running);
        setup = rig.Setup(joined: null, made: cut with { Tried = true });
        await setup.StepAsync();
        await setup.StepAsync();
        AssertStop(setup, "worker-4", "It stopped at “Join the fleet”.");
        Assert.AreEqual(9, rig.Records.Installs.All().Count, "no join by itself");
    }

    /// <summary>**The first run's server that the hub already took is joined once by itself while it is free** (the first
    /// run's own join stopped after the join's POST, so the mark is not tried and the hub lists the server free): the page
    /// joins it once by itself, with its tries, and the hand-over gives it to the manager; while a job runs there ("busy"),
    /// nothing joins it by itself. The bugs: a listed server that the page never joins, so that the only way on is a second
    /// paid server; a join by itself on a server where an agent's job runs.</summary>
    [TestMethod]
    public async Task A_first_run_server_that_the_hub_lists_free_joins_once_by_itself_and_goes_to_the_manager()
    {
        await using var rig = new ServerRig();
        var hub = rig.HubCalls;
        var first = rig.Made("worker-2");
        rig.JoinRecord(first.Address, "worker-2", InstallOutcome.Stopped);      // the first run's own join, after the hub took the server
        // A job runs there ("busy", which the Mac's reuse does not take): nothing joins it by itself.
        hub.Servers = ServerRig.List(("worker-2", null, false)).Replace("\"why\": []}]}", "\"why\": [\"busy\"]}]}");
        var busy = rig.Setup(joined: null, made: first);
        for (var read = 0; read < 2; read++) await busy.StepAsync();
        Assert.AreEqual((InstallView.None, false), (busy.View.NewServer!.Install, ManagerSetupMark.Read(rig.Choices)!.Made?.Tried), "no join of a busy server");

        hub.Servers = ServerRig.List(("worker-2", null, true));
        var setup = rig.Setup(joined: null, made: first);
        await setup.StepAsync();
        Assert.AreEqual(true, ManagerSetupMark.Read(rig.Choices)!.Made?.Tried, "its join by itself started");
        await rig.Until(setup, _ => hub.PostsTo("/move").Count == 1, "the server given");
        CollectionAssert.AreEqual(new[] { "worker-2" }, rig.Joined, "one join of the page");
        Assert.AreEqual(2, rig.Records.Installs.All().Count, "the first run's and the page's");
        StringAssert.Contains(hub.PostsTo("/move").Single(), "\"server\":\"worker-2\",\"runtime\":\"claude\"");
    }

    /// <summary>The page shows a join of <paramref name="server"/> that stopped, with these words and Try again, and no join
    /// runs.</summary>
    private static void AssertStop(ManagerSetup setup, string server, string words)
    {
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("serverInstall", server + " did not install", words), (screen.Name, screen.Title, screen.Warning));
        Assert.AreEqual("first-run-install-again", screen.Controls.Single().Id, "Try again");
        Assert.IsFalse(setup.View.NewServer!.Install.Running, "no join by itself");
    }

    /// <summary>**The first run's server that the hub took before its join stopped is still the page's while it is free**
    /// (the hub takes a server at the join's POST, before the root helper, the firewall and the updates): the page shows
    /// its stop with Try again, the join finishes what is missing, and the hand-over gives it; while another agent holds
    /// it, the page shows nothing of it, joins nothing, and the mark keeps it. The bugs: a paid server in the fleet that
    /// the PC never joins again, so that the only way on is a second paid server; a join of a server that another agent
    /// has.</summary>
    [TestMethod]
    public async Task A_first_run_server_that_the_hub_took_stays_the_pages_while_it_is_free()
    {
        await using var rig = new ServerRig();
        var hub = rig.HubCalls;
        hub.Servers = ServerRig.List();
        var first = rig.Made("worker-2");
        rig.First = call => call.Program.Contains("FLEET_JOIN=", StringComparison.Ordinal)
            ? StandInRemote.Said("Founderizer join stopped: package lists could not be updated", 1) : null;
        var setup = rig.Setup(joined: null, made: first);
        await setup.StepAsync();
        await rig.Until(setup, v => v.NewServer is { Runs: false, Install.Failure: not null }, "the join to stop");

        // The hub took it at the join's POST, and Iris has it now: the page shows nothing of it, and the mark keeps it.
        hub.Servers = ServerRig.List(("worker-2", "iris", false));
        setup.Visit();
        await setup.StepAsync();
        await setup.StepAsync();
        Assert.AreEqual((InstallView.None, "worker-2"), (setup.View.NewServer!.Install, ManagerSetupMark.Read(rig.Choices)!.Made?.Name));

        // Free: the next start shows its stop, Try again finishes the join, and the hand-over gives it to the manager.
        hub.Servers = ServerRig.List(("worker-2", null, true));
        rig.First = null;
        setup = rig.Start();
        await setup.StepAsync();
        AssertStop(setup, "worker-2", "It stopped at “Join the fleet”.");
        Assert.IsTrue(setup.Server!.JoinAgain());
        await rig.Until(setup, _ => hub.PostsTo("/move").Count == 1, "the server given");
        StringAssert.Contains(hub.PostsTo("/move").Single(), "\"server\":\"worker-2\",\"runtime\":\"claude\"");
        Assert.AreEqual((2, null as FirstRunServer), (rig.Records.Installs.All().Count, ManagerSetupMark.Read(rig.Choices)!.Made));
    }

    /// <summary>**A server that joined and that the hand-over did not give stays the manager's to take** (the Mac's
    /// <c>handOver</c>, which notes it in all cases): the hub lists it only after the hand-over's reads, and the next start
    /// gives it once the hub offers it. The bug: a good join whose server the manager never gets, so that the only way on
    /// is a second paid server.</summary>
    [TestMethod]
    public async Task A_joined_server_that_the_hand_over_did_not_give_stays_the_managers()
    {
        await using var rig = new ServerRig();
        var hub = rig.HubCalls;
        hub.Servers = ServerRig.List();      // the hub does not list it during the hand-over's reads
        var made = rig.Made("worker-2");
        var setup = rig.Setup(joined: null);
        Assert.IsTrue(setup.Server!.Join(new InstallTarget(made.Address), "worker-2"));
        await rig.Until(setup, v => v.NewServer is { Runs: false } && rig.Joined.Count == 1, "the join and its hand-over to end");
        Assert.AreEqual((0, "worker-2"), (hub.PostsTo("/move").Count, ManagerSetupMark.Read(rig.Choices)!.Joined), "not given, and kept");

        hub.Servers = ServerRig.List(("worker-2", null, true));
        await rig.Start().StepAsync();
        StringAssert.Contains(hub.PostsTo("/move").Single(), "\"server\":\"worker-2\",\"runtime\":\"claude\"");
    }

    /// <summary>**A server that joined goes to the manager after a new start of the app** (the Mac's <c>noteJoined</c>): the
    /// join's end keeps it in the manager's mark, and the setup that the next start makes from that mark gives it, with
    /// its provider, as soon as the hub offers it. The bug: an app that ends while the hand-over waits for the hub, and a
    /// paid server in the fleet that the manager never gets.</summary>
    [TestMethod]
    public async Task A_server_that_joined_goes_to_the_manager_after_a_new_start_of_the_app()
    {
        await using var rig = new ServerRig();
        var hub = rig.HubCalls;
        hub.Servers = ServerRig.List();
        var made = rig.Made("worker-2");
        rig.Pause = (_, _) => new TaskCompletionSource().Task;      // the app ends while the hand-over waits for the hub
        var setup = rig.Setup(joined: null);
        Assert.IsTrue(setup.Server!.Join(new InstallTarget(made.Address), "worker-2"));
        await rig.Until(setup, _ => ManagerSetupMark.Read(rig.Choices)?.Joined == "worker-2", "the server in the kept mark at the join's end");
        Assert.AreEqual(0, hub.PostsTo("/move").Count, "no hand-over yet");

        hub.Servers = ServerRig.List(("worker-2", null, true));
        await rig.Start().StepAsync();
        StringAssert.Contains(hub.PostsTo("/move").Single(), "\"server\":\"worker-2\",\"runtime\":\"claude\"");
    }

    /// <summary>**A join that tries again by itself keeps its bar where the first try left it** (F4's one report rule, <see
    /// cref="InstallView.Reported"/>, on the join of the server's page): the hold of the press goes through the retry. The
    /// bug: the page's own copy of the old rule, with no hold, so that the bar goes back to the start at each retry.</summary>
    [TestMethod]
    public async Task A_join_that_tries_again_keeps_its_bar()
    {
        await using var rig = new ServerRig();
        rig.Made("worker-2");
        var address = rig.Network.AddressOf("worker-2");
        var setup = rig.Setup(joined: null);
        InstallPhases? first = null, again = null;
        var joins = 0;
        rig.First = call =>
        {
            if (call.Program.Contains("FLEET_JOIN=", StringComparison.Ordinal) && joins++ == 0)
            {
                first = setup.Server!.Now.Install.Phases(0);
                return StandInRemote.Said("Founderizer join stopped: package lists could not be updated", 1);
            }
            if (call.Program == "/bin/sh -s" && joins == 1 && again is null) again = setup.Server!.Now.Install.Phases(0);
            return null;
        };
        Assert.IsTrue(setup.Server!.Join(new InstallTarget(address), "worker-2"));
        await rig.Until(setup, _ => rig.Joined.Count == 1 && setup.Server.Now is { Runs: false }, "the join to end after its retry");
        Assert.IsNotNull(first, "the first try reached the line");
        Assert.IsNotNull(again, "the second try started");
        Assert.IsTrue(first.Parts.Sum() > 0);
        for (var part = 0; part < first.Parts.Count; part++)
            Assert.IsTrue(again.Parts[part] >= first.Parts[part], $"part {part} went back: {again.Parts[part]} after {first.Parts[part]}");
        Assert.AreEqual(2, joins, "one retry");
    }

    /// <summary>**A join goes only to the fleet that the setup is for** (the Mac's <c>store.hub == fleet</c> before its
    /// install): the owner's store moves to another hub or generation while the provider makes the server, and the server
    /// asks that hub for no line. The bug: the paid server joins the other fleet.</summary>
    [TestMethod]
    public async Task A_join_goes_only_to_the_fleet_of_the_setup()
    {
        await using var rig = new ServerRig();
        var hub = rig.HubOf;
        hub.Servers = ServerRig.List();
        var setup = rig.Setup(joined: null);
        await setup.StepAsync();
        rig.Cloud.Refuses = _ =>
        {
            hub.Database = "db-2";
            return null;
        };
        setup.Server!.ChooseProvider(CloudProvider.Hetzner);
        await rig.Until(setup, v => v.NewServer?.Cloud.Offer is not null, "the offer");
        Assert.IsTrue(await setup.Server.MakeServerAsync());
        await rig.Until(setup, _ => rig.Records.Installs.All().Any(r => r.Kind == InstallKind.Join && r.Outcome != InstallOutcome.Running) &&
                                    setup.Server.Now is { Runs: false }, "the join to end");
        Assert.AreEqual((1, 0, 0), (rig.Cloud.Orders.Count, hub.PostsTo("ui/servers/join").Count, rig.Joined.Count), "no line of the other hub");
        Assert.AreEqual(Hub.ToString(), rig.Records.Builds.All().Single().Hub, "the server stays this hub's, for Start again");
    }

    /// <summary>**A failed install goes again with the agent's own role, on its own server** (the Mac's <c>choose</c> of
    /// <c>.installAgain</c>): Try again over the provider's page of a lead whose install failed. The bugs: a lead installed
    /// again as a worker; a press that says it cannot read the server.</summary>
    [TestMethod]
    public async Task A_failed_install_goes_again_with_the_agents_role_on_its_server()
    {
        var fleet = Fleet(irisActive: false);
        var hub = new SetupHub
        {
            Servers = Servers(Job("failed", "runtime", ", \"detail\": \"Claude Code did not install.\"")), Machines = "{\"db\": \"db-1\", \"machines\": []}",
            TeamLines = "[{\"agent\": \"juno\", \"role\": \"manager\"}, {\"agent\": \"iris\", \"role\": \"lead\", \"reports_to\": \"juno\"}]",
        };
        var setup = Iris(hub, () => fleet, new MemoryChoices());
        await setup.StepAsync();
        var screen = ManagerSetupScreens.Of(setup.View);
        Assert.AreEqual(("provider", "Claude Code did not install."), (screen.Name, screen.Warning));
        Assert.IsTrue(screen.Controls.Any(c => c.Id == "agent-setup-install-again"), "Try again over the stop");
        await setup.ChooseAsync("claude");
        var sent = hub.PostsTo("ui/servers/worker-3/agents");
        Assert.AreEqual(1, sent.Count, string.Join(", ", hub.Routes));
        StringAssert.Contains(sent[0], "\"agent\":\"iris\",\"runtime\":\"claude\",\"role\":\"lead\"");
    }

    /// <summary>**An active agent that signs in again gets no check and no activation** (the Mac's <c>signingInAgain</c>):
    /// its pages are the sign-in's, and they end when its machine reports it signed in. The bug: an agent that runs is
    /// checked and activated again at each sign-in.</summary>
    [TestMethod]
    public async Task An_active_agent_that_signs_in_again_gets_no_check_and_no_activation()
    {
        var fleet = Fleet(irisActive: true);
        var hub = new SetupHub { Servers = Servers(Job("done", "sign_in")), Machines = Machines(false) };
        var setup = Iris(hub, () => fleet, new MemoryChoices());
        await setup.StepAsync();
        Assert.AreEqual(("provider", false), (ManagerSetupScreens.Of(setup.View).Name, setup.View.Ended), "signed out: its provider");
        hub.Machines = Machines(true);
        await setup.StepAsync();
        Assert.AreEqual(0, hub.Routes.Count, string.Join(", ", hub.Routes));
        Assert.IsTrue(setup.View.Ended, "signed in again: its chat");
    }

    /// <summary>A manager with no server on a stand-in PC: a provider that makes a server on the tailnet, a server that takes
    /// the join, and the hub's owner routes.</summary>
    private sealed class ServerRig : IAsyncDisposable
    {
        private readonly string folder = Directory.CreateTempSubdirectory("founderizer-agent-").FullName;
        private readonly StandInStatus status = new();
        private readonly StandInRemote remote;
        public SetupHub HubCalls { get; } = new();
        public MemoryChoices Choices { get; } = new();
        public StandInCloud Cloud { get; }
        public SetupRecords Records { get; }
        /// <summary>The servers whose join ran to its end, and what the hub then lists.</summary>
        public List<string> Joined { get; } = [];
        public Action<string>? Joins { get; set; }
        /// <summary>An answer of the server that comes before the rig's own, or null.</summary>
        public Func<RemoteCall, RemoteResult?>? First { get; set; }
        /// <summary>The page's pause, in place of one millisecond.</summary>
        public Func<TimeSpan, CancellationToken, Task>? Pause { get; set; }
        public SetupHub HubOf => HubCalls;
        public StandInStatus Network => status;

        public ServerRig()
        {
            status.Join("worker-1");
            Cloud = new StandInCloud(CloudProvider.Hetzner, status);
            Records = new SetupRecords(folder, "launch-1");
            remote = new StandInRemote((call, _) =>
            {
                if (First?.Invoke(call) is { } given) return given;
                if (call.Program == "/bin/sh -s") return StandInRemote.Said(Printed.Ready());
                if (call.Program.Contains("tailscale ip -4", StringComparison.Ordinal) && !call.Program.Contains("fleet-on-network", StringComparison.Ordinal))
                    return StandInRemote.Said(call.Target.Host);
                if (call.Program.Contains("FLEET_JOIN=", StringComparison.Ordinal)) return StandInRemote.Said("READY");
                if (!call.Program.Contains("verify --json", StringComparison.Ordinal)) return StandInRemote.Said("ok");
                var name = Records!.Builds.All().Select(r => r.Name).First(n => status.AddressOf(n) == call.Target.Host);
                lock (Joined) Joined.Add(name);
                Joins?.Invoke(name);
                return StandInRemote.Said(Printed.Checklist);
            });
        }

        /// <summary>The hub's servers: its own, then each of these with its agent, or none.</summary>
        public static string List(params (string Name, string? Agent, bool Available)[] servers) =>
            "{\"db\": \"db-1\", \"time\": 1763700100, \"servers\": [" +
            "{\"name\": \"worker-1\", \"hub\": true, \"joined\": true, \"agents\": [], \"available\": false, \"why\": []}" +
            string.Concat(servers.Select(s => $", {{\"name\": \"{s.Name}\", \"hub\": false, \"joined\": true, \"agents\": [{(s.Agent is null ? "" : "\"" + s.Agent + "\"")}], " +
                                              $"\"available\": {(s.Available ? "true" : "false")}, \"why\": []}}")) + "]}";

        /// <summary>A build of this server: made for an agent of this hub, and on the private network now.</summary>
        public FirstRunServer Made(string name)
        {
            status.Join(name);
            Records.Builds.Write(BuildRecord.Begin("hetzner", "agent", Hub.ToString(), name, "launch-1", DateTimeOffset.UtcNow)
                                            .Made("100", DateTimeOffset.UtcNow).Joined(DateTimeOffset.UtcNow));
            return new FirstRunServer(name, status.AddressOf(name));
        }

        /// <summary>A record of a join to this hub at <paramref name="host"/> by an earlier start of the app, at its join step:
        /// stopped there, ended well, or cut off there by the app's close (<see cref="InstallOutcome.Running"/>: it says that
        /// it runs).</summary>
        public void JoinRecord(string host, string name, InstallOutcome end)
        {
            var at = DateTimeOffset.UtcNow;
            var log = new InstallLog(InstallKind.Join, Hub.ToString(), host, "launch-0", at);
            log.Place(server: name);
            log.Note("join", RecordStepState.Running, at);
            if (end == InstallOutcome.Stopped) log.Stop(InstallStop.StepFailed, null, InstallCause.Packages, at: at);
            if (end == InstallOutcome.Done) log.Done(at);
            Records.Installs.Write(log.Record);
        }

        /// <summary>The manager's setup from a mark with this server that joined for it, and this server of the first run.</summary>
        public ManagerSetup Setup(string? joined, FirstRunServer? made = null)
        {
            new ManagerSetupMark(Hub, "db-1", "juno", "claude", joined, made).Keep(Choices);
            return Start();
        }

        /// <summary>A start of the app: the manager's setup from the mark that this PC keeps.</summary>
        public ManagerSetup Start()
        {
            var mark = ManagerSetupMark.Read(Choices)!;
            var fleet = new MobileSnapshot(1, "db-1", Time, [new MobileAgent("juno", "manager", "claude", 0, [], Title: "Fleet Manager", Active: true)],
                                           [], [], [], [], [], UiFeatures: Features);
            return new ManagerSetup(new ManagerSetupSettings
            {
                Calls = HubCalls, Fleet = () => fleet, Choices = Choices,
                Server = new AgentServerSettings
                {
                    Box = new MemorySecretBox(), Remote = remote, Records = Records, Tailscale = new StandInNet(), Cloud = _ => Cloud,
                    Status = _ => Task.FromResult<string?>(status.Json()), Pause = Pause ?? ((_, cancel) => Task.Delay(1, cancel)),
                    JoinClock = new StandInClock(), HandOverReads = 3, HandOverEvery = TimeSpan.FromMilliseconds(1),
                },
            }, mark);
        }

        /// <summary>Waits until <paramref name="holds"/> is true of the setup's view, at most a few seconds of real time.</summary>
        public async Task Until(ManagerSetup setup, Func<ManagerSetupView, bool> holds, string what)
        {
            for (var i = 0; i < 500; i++)
            {
                if (holds(setup.View)) return;
                await Task.Delay(10);
            }
            throw new TimeoutException($"the setup never came to: {what} (failure {setup.View.NewServer?.Install.Failure ?? setup.View.NewServer?.Cloud.Failure})");
        }

        public ValueTask DisposeAsync()
        {
            try { Directory.Delete(folder, recursive: true); } catch (IOException) { }
            return default;
        }
    }
}
