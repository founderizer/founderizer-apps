using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Founderizer.Setup.FirstRun;

namespace Founderizer.Setup.Agents;

/// <summary>**What the setup of one agent reads now** (the Mac's <c>AgentSetupWizard</c>'s reads): the agent's row of
/// GET /ui/mobile with the hub's features and time, GET /ui/servers and GET /ui/machines.</summary>
public sealed record AgentReading(SetupAgent? Agent, IReadOnlyList<string> Features, double Time, ServerList? Servers, MachineList? Machines)
{
    public ServerEntry? Server(string agent) => Servers?.ServerOf(agent);
    public MachineStatus? Machine(string agent) => Machines?.Of(agent);
}

/// <summary>**The activation stopped** (the Mac's <c>ActivationState.stopped</c>): the hub's words or the check's own one
/// line, or none.</summary>
public sealed record ActivationStop(string? Why);

/// <summary>**The setup of one agent, as a model** (windows-app-plan-v2.md, pieces L4 and L4b; the Mac's
/// <c>AgentSetupWizard</c>): the page from the hub's own readings; for the manager of a new fleet, the server and the
/// provider that the first run gave it, placed by itself; the sign-in; and for an agent that is not active (one that a
/// team card added, for example), the machine's check and then its activation, both by themselves once its machine is
/// signed in. It reads through the owner's calls of the PC (<see cref="OwnerReads"/>). A change of provider is wave C's.
/// <paramref name="placing"/>: this PC saw the agent with no server on this generation of the hub (the Mac's
/// <c>FleetStore.placing</c>), which is the manager's first setup, by its mark; false for every other agent.</summary>
public sealed class AgentSetupModel(OwnerReads.ICalls calls, string agent, bool placing = true)
{
    /// <summary>The agent of this setup.</summary>
    public string Agent { get; } = agent;

    /// <summary>The agent as the apps name it (<see cref="AgentBook.Label"/>), from the newest reading.</summary>
    public string Label { get; private set; } = AgentBook.Empty.Label(agent);

    /// <summary>The words of a step that the hub did not answer, of a server that the PC cannot read, of a code that did
    /// not reach the hub, and of a team that the activation could not read (the Mac's <c>AgentSetupWizard</c>).</summary>
    public const string NoAnswer = "The hub has not answered. Try again.";
    public const string CodeLost = "The code did not reach the hub. Paste it again.";
    public const string CannotReadTeam = "Founderizer cannot read the team now. Try again.";
    public static string CannotReadServer(string agent) => $"Founderizer cannot read {agent}'s server now.";

    /// <summary>**The provider cards of the setup's provider page**: both for an agent with no server yet (its provider
    /// goes with its first server), and for an agent on its server its own provider only, because a change to the other
    /// provider is a page of wave C on this PC, which no card offers yet.</summary>
    public IReadOnlyList<string> Cards(AgentReading reading) =>
        reading.Agent is { Placed: true } placed ? [placed.Runtime] : ["codex", "claude"];

    /// <summary>The provider that the first run chose for it, and the server that joined for it on this PC (the Mac's
    /// <c>FleetStore.chosenProvider</c> and <c>joinedServer</c>).</summary>
    public string? Provider { get; set; }
    public string? Joined { get; set; }

    /// <summary>The words of the hub when it refused a step, in orange under it, until the next attempt.</summary>
    public string? Refusal { get; private set; }

    /// <summary>The hub refused the command that gives the agent its server: the provider's page shows again.</summary>
    public bool PlaceRefused { get; private set; }

    /// <summary>The owner's own press on a provider's card asked for the sign-in on this visit.</summary>
    public bool AskedSignIn { get; private set; }

    /// <summary>The sign-in's page was opened by itself once.</summary>
    public bool Opened { get; set; }

    /// <summary>The sign-in's <c>updated_at</c> when the owner sent the code.</summary>
    public double? SentFrom { get; private set; }

    public AgentReading? Reading { get; private set; }

    /// <summary>Reads the servers and the machines, with the agent's row of the fleet that the store holds. Each read
    /// stands alone, as the Mac's <c>try?</c> of each (<c>AgentSetupWizard.read</c>): one that fails, or that is of
    /// another generation, keeps its last answer of this generation, and the other still comes.</summary>
    public async Task<AgentReading> ReadAsync(MobileSnapshot fleet, CancellationToken cancel = default)
    {
        Label = AgentBook.Of(fleet).Label(Agent);
        var features = fleet.UiFeatures ?? [];
        var servers = Reading?.Servers is { } lastServers && lastServers.Db == fleet.Db ? lastServers : null;
        var machines = Reading?.Machines is { } lastMachines && lastMachines.Db == fleet.Db ? lastMachines : null;
        if (features.Contains("servers"))
            try { servers = (await OwnerReads.ServersAsync(calls, cancel).ConfigureAwait(false)).Value ?? servers; }
            catch (Exception e) when (e is HubException or InvalidOperationException or System.Text.Json.JsonException) { }
        if (features.Contains("machines"))
            try { machines = (await OwnerReads.MachinesAsync(calls, cancel).ConfigureAwait(false)).Value ?? machines; }
            catch (Exception e) when (e is HubException or InvalidOperationException or System.Text.Json.JsonException) { }
        var row = fleet.Agents.FirstOrDefault(a => a.Name == Agent);
        Reading = new AgentReading(row is null ? null : SetupAgent.Of(row, servers, machines), features, fleet.Time, servers, machines);
        return Reading;
    }

    /// <summary>**Another page of the setup shows** (the Mac's <c>.onChange(of: page)</c>): the provider's page is not
    /// open on it, no code is on its way, and the sign-in that a press asked for stands only through the pages that end in
    /// it (the install, a switch, the sign-in).</summary>
    public void PageChanged(AgentPage now)
    {
        Opened = false;
        SentFrom = null;
        if (now.Kind is not (AgentSetupPage.Installing or AgentSetupPage.Switching or AgentSetupPage.SignIn)) AskedSignIn = false;
    }

    /// <summary>The page's orange line goes (the Mac's <c>refusal = nil</c> of a Back).</summary>
    public void ForgetRefusal() => Refusal = null;

    /// <summary>**A new visit of the setup's page** (the Mac's view, whose states start again): no refusal, no command
    /// refused, no code on its way, no sign-in asked or opened, and no check or activation asked on this visit.</summary>
    public void NewVisit()
    {
        Refusal = null;
        PlaceRefused = false;
        SentFrom = null;
        Opened = false;
        AskedSignIn = false;
        AskedCheck = null;
        AskedActivation = false;
        Activated = false;
    }

    /// <summary>**The provider's own page is open** (the Mac's <c>openSignIn</c>): by itself once, or by the press on the
    /// first step's link; a press asks for nothing more after it.</summary>
    public void OpenedSignIn()
    {
        Opened = true;
        AskedSignIn = false;
    }

    /// <summary>**The server that joined for the agent, when it can still take it**: one that left the fleet, or that
    /// another agent took since, is not one to give it.</summary>
    public string? PlaceOn(AgentReading reading, ManagerSetupStart start)
    {
        if (start is ManagerSetupStart.OnHub onHub) return onHub.Machine;
        if (Joined is not { } joined) return null;
        if (reading.Servers is not { } list) return joined;
        return list.TakesFirst(Agent, joined) ? joined : null;
    }

    /// <summary>**What comes before the server's page of a manager with no server.**</summary>
    public ManagerSetupStart Start(AgentReading reading, bool named) =>
        ManagerSetupStart.Page(reading.Agent?.Role, reading.Agent?.Placed, Joined is not null, reading.Features, named, reading.Servers);

    /// <summary>**The page the setup shows now** (the Mac's <c>page</c>): with no server yet, its name, its provider, the
    /// fleet's servers, its server and the install that the server and the provider start together; once placed, the
    /// hub's job and the machine's sign-in.</summary>
    public AgentPage Page(AgentReading reading, bool named = true, bool renaming = false)
    {
        var line = reading.Agent;
        if (line?.Placed == false) return Start(reading, named).PageOf(renaming, Provider, PlaceOn(reading, Start(reading, named)), PlaceRefused);
        var job = AgentSetupFlow.Job(Agent, reading.Server(Agent), active: line?.Active == true && !Placing(reading));
        return AgentSetupFlow.Page(line?.Runtime ?? "codex", job, reading.Machine(Agent), null);
    }

    /// <summary>It gets its first server: its own install counts as an agent's in setup, and nothing activates it.</summary>
    public bool Placing(AgentReading reading) =>
        reading.Agent is { } a && AgentSetupFlow.Places(a, reading.Features, placing);

    /// <summary>It is active and only signed out (the Mac's <c>signingInAgain</c>): no machine check and no activation; its
    /// setup ends when its machine reports it signed in again.</summary>
    public bool SigningInAgain(AgentReading reading) => reading.Agent?.Active == true && !Placing(reading);

    /// <summary>**The sign-in page** of this setup, from the readings.</summary>
    public SignInPage SignInPage(AgentReading reading, string provider)
    {
        var job = AgentSetupFlow.Job(Agent, reading.Server(Agent), active: reading.Agent?.Active == true && !Placing(reading));
        return SignIn.Page(provider, job, reading.Machine(Agent), SentFrom, Refusal);
    }

    /// <summary>**The server and the provider that the owner chose, once both are there**, for the manager of a new
    /// fleet: by itself once the server is there. A refusal shows the provider's page again with its words.</summary>
    public async Task PlaceChosenAsync(AgentReading reading, bool named = true, CancellationToken cancel = default)
    {
        if (reading.Agent?.Placed != false || Provider is not { } provider || PlaceOn(reading, Start(reading, named)) is not { } server) return;
        await PlaceAsync(server, provider, named, cancel).ConfigureAwait(false);
        PlaceRefused = Refusal is not null;
        AskedSignIn = Refusal is null;
    }

    /// <summary>**Its server and its provider, in one command** (owner API 1.82): a team.json that changed between the
    /// read and the press is read again, once, and so is the list of servers: the move goes again only while the server
    /// still takes the agent (the Mac's <c>place</c> and <c>stillTakes</c>); else the refusal's words show.</summary>
    private async Task PlaceAsync(string server, string provider, bool named, CancellationToken cancel)
    {
        Refusal = null;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                var team = (await OwnerReads.TeamAsync(calls, cancel).ConfigureAwait(false)).Value;
                if (team is null) continue;
                var moved = await OwnerReads.MoveAsync(calls, Agent, team.Sha256, server, provider, cancel: cancel).ConfigureAwait(false);
                if (moved.Value is not null) return;
            }
            catch (HubException refused) when (refused.Kind == HubErrorKind.Refusal)
            {
                if (refused is { Status: 409, Code: "team_changed" } && attempt == 0 &&
                    await StillTakesAsync(server, named, cancel).ConfigureAwait(false))
                    continue;
                Refusal = refused.HubWords ?? refused.Message;
                return;
            }
            // No answer, or one that is not of this request (the Mac's `catch`): the next read says where it stands.
            catch (Exception e) when (e is HubException or InvalidOperationException or ArgumentException or System.Text.Json.JsonException)
            {
                Refusal = NoAnswer;
                return;
            }
        }
        Refusal ??= NoAnswer;
    }

    /// <summary>**After a refusal for a team.json that changed** (the Mac's <c>stillTakes</c>): the servers read again, kept
    /// for the pages, and true only while <paramref name="server"/> still takes this agent by the rule of its first server
    /// (<see cref="ServerList.TakesFirst"/>), or is the hub's own server that the manager of a new fleet goes to. A list that
    /// the hub does not give is no go.</summary>
    private async Task<bool> StillTakesAsync(string server, bool named, CancellationToken cancel)
    {
        ServerList? list;
        try { list = (await OwnerReads.ServersAsync(calls, cancel).ConfigureAwait(false)).Value; }
        catch (Exception e) when (e is HubException or InvalidOperationException or System.Text.Json.JsonException) { return false; }
        if (list is null) return false;
        if (Reading is { } reading) Reading = reading with { Servers = list };
        if (Reading is { } now && Start(now, named) is ManagerSetupStart.OnHub onHub && onHub.Machine == server) return true;
        return list.TakesFirst(Agent, server);
    }

    /// <summary>**A press on a provider's card** (the Mac's <c>choose</c>): with no server yet the PC keeps the provider
    /// until the server is there; once placed, what the choice asks the hub to do now (<see
    /// cref="AgentSetupFlow.StartOf"/>). A change to the other provider is a page of wave C.</summary>
    public async Task ChooseAsync(AgentReading reading, string provider, bool named = true, CancellationToken cancel = default)
    {
        Refusal = null;
        if (reading.Agent?.Placed == false)
        {
            Provider = provider;
            PlaceRefused = false;
            await PlaceChosenAsync(reading, named, cancel).ConfigureAwait(false);
            return;
        }
        var runtime = reading.Agent?.Runtime ?? "codex";
        var job = AgentSetupFlow.Job(Agent, reading.Server(Agent), active: reading.Agent?.Active == true && !Placing(reading));
        var start = AgentSetupFlow.StartOf(provider, runtime, job, reading.Machine(Agent));
        switch (start)
        {
            case AgentSetupFlow.Start.SignIn:
                try { await OwnerReads.SignInAsync(calls, Agent, provider, cancel: cancel).ConfigureAwait(false); }
                catch (HubException refused) when (refused.Kind == HubErrorKind.Refusal) { Refusal = refused.HubWords ?? refused.Message; }
                catch (Exception e) when (e is HubException or InvalidOperationException or ArgumentException or System.Text.Json.JsonException) { Refusal = NoAnswer; }
                break;
            case AgentSetupFlow.Start.InstallAgain when Placing(reading) && reading.Server(Agent) is { } server:
                await PlaceAsync(server.Name, provider, named, cancel).ConfigureAwait(false);
                break;
            case AgentSetupFlow.Start.InstallAgain when reading.Server(Agent) is { } server:
                await InstallAgainAsync(server.Name, provider, cancel).ConfigureAwait(false);
                break;
            case AgentSetupFlow.Start.InstallAgain:
                Refusal = CannotReadServer(Label);
                break;
            case AgentSetupFlow.Start.Prepare:
                // A change to the other provider is a page of wave C: no card offers it (Cards), and a press gets nothing.
                return;
        }
        AskedSignIn = start.SignsIn() && Refusal is null;
    }

    /// <summary>**The install of an agent that is not placing, again** (the Mac's <c>choose</c> of <c>.installAgain</c>):
    /// the same command on the same server, with the provider it has and its role in the team, a lead as a lead and any
    /// other as a worker. The server repeats only what is missing, and its sign-in step gives the owner a new code.</summary>
    private async Task InstallAgainAsync(string server, string provider, CancellationToken cancel)
    {
        try
        {
            if ((await OwnerReads.TeamAsync(calls, cancel).ConfigureAwait(false)).Value is not { } team)
            {
                Refusal = NoAnswer;
                return;
            }
            var role = team.LineOf(Agent)?.Role == "lead" ? "lead" : "worker";
            await OwnerReads.AddAgentAsync(calls, server, team.Sha256, Agent, provider, role, cancel: cancel).ConfigureAwait(false);
        }
        catch (HubException refused) when (refused.Kind == HubErrorKind.Refusal) { Refusal = refused.HubWords ?? refused.Message; }
        catch (Exception e) when (e is HubException or InvalidOperationException or ArgumentException or System.Text.Json.JsonException)
        {
            Refusal = NoAnswer;
        }
    }

    // ---------------------------------------------------------------- the machine check and the activation

    /// <summary>The check that this visit asked for, by the id of the newest check before it (0 for none), so that each
    /// one is asked once (the Mac's <c>askedCheck</c>); null before the first.</summary>
    public long? AskedCheck { get; private set; }

    /// <summary>This visit asked the hub to activate the agent: once, and again only by Try again (the Mac's
    /// <c>askedActivation</c>).</summary>
    public bool AskedActivation { get; private set; }

    /// <summary>The hub took the activation: the page waits for the reading that says so (the Mac's <c>activated</c>).</summary>
    public bool Activated { get; private set; }

    /// <summary>**The newest check of its machine passed for its saved settings, recently enough for the hub to activate
    /// it** (the Mac's <c>permits</c>, by the hub's own clock).</summary>
    public bool Permits(AgentReading reading) =>
        reading.Machine(Agent) is { Verify: { } verify } machine && verify.PermitsActivation(machine, reading.Machines?.DesiredRevision, reading.Time);

    /// <summary>A check of its machine waits for its result.</summary>
    private static bool Checking(MachineStatus? machine) => machine?.Check?.IsPending == true;

    /// <summary>The newest check of its machine has its result.</summary>
    private static bool Checked(MachineStatus? machine) =>
        machine?.Check is { State: "completed" } check && machine.Verify?.Check == check.Id;

    /// <summary>Its machine is still taking its new settings: a check now would check the old ones.</summary>
    private static bool Loading(MachineStatus? machine) =>
        machine is not null && (machine.SettingsPending == true || machine.Update.State != "current");

    /// <summary>**Where the activation stands** (the Mac's <c>activationState</c>): null while the check or the activation
    /// goes on, or goes next by itself; else it stopped, with the hub's words, or with the check's own one line (the first
    /// item that the activation needs and that did not pass, <see cref="AgentSetupFlow.Blocker"/>), or with no words for
    /// an activation that the hub took and that no reading shows yet. <paramref name="busy"/>: a press of this setup is on
    /// its way.</summary>
    public ActivationStop? Activation(AgentReading reading, bool busy)
    {
        var machine = reading.Machine(Agent);
        if (busy || Checking(machine) || Loading(machine)) return null;
        if (Refusal is { } refusal) return new ActivationStop(refusal);
        if (Permits(reading)) return AskedActivation && !Activated ? new ActivationStop(null) : null;
        if (AskedCheck is not { } asked || machine?.Check is not { } check || check.Id <= asked || check.IsPending) return null;
        return new ActivationStop(Checked(machine) ? AgentSetupFlow.Blocker(machine.Verify) : check.Detail);
    }

    /// <summary>**A check or an activation goes next by itself on the activation's page** (the Mac's <c>follow</c>), once on
    /// each visit: the machine's check, and the activation once a check passed. Not for an agent that is only signed out,
    /// nor for the manager of a new fleet, which is active from the start; not while a check waits or the machine loads its
    /// settings, and not after a stop, which only Try again ends.</summary>
    public bool ActivationDue(AgentReading reading, AgentPage page)
    {
        var machine = reading.Machine(Agent);
        if (page.Kind != AgentSetupPage.Activate || SigningInAgain(reading) || Placing(reading) || Checking(machine) || Loading(machine) ||
            Refusal is not null)
            return false;
        return Permits(reading) ? !AskedActivation : AskedCheck is null;
    }

    /// <summary>**Runs it**: the activation when the newest check permits it, else the check. A command that a cancel ended
    /// may not have reached the hub, so the next read asks again: the hub keeps one check that waits, and an activation of
    /// an active agent changes nothing.</summary>
    public async Task FollowActivationAsync(AgentReading reading, AgentPage page, CancellationToken cancel = default)
    {
        if (!ActivationDue(reading, page)) return;
        try
        {
            if (Permits(reading))
            {
                AskedActivation = true;
                await ActivateAsync(reading, cancel).ConfigureAwait(false);
            }
            else await CheckAsync(reading, cancel).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            AskedActivation = false;
            AskedCheck = null;
            throw;
        }
    }

    /// <summary>**The machine's check** (the Mac's <c>check</c>): asked once for this visit. A refusal is the page's orange
    /// line. A check that got no answer is asked again at the next read: the Mac's request line sends such a command again
    /// by itself, and the PC has no such line for it (the hub keeps one check that waits, and a second ask gets that one).</summary>
    private async Task CheckAsync(AgentReading reading, CancellationToken cancel)
    {
        AskedCheck = reading.Machine(Agent)?.Check?.Id ?? 0;
        Refusal = null;
        try { await OwnerReads.CheckAsync(calls, Agent, cancel: cancel).ConfigureAwait(false); }
        catch (HubException refused) when (refused.Kind == HubErrorKind.Refusal) { Refusal = refused.HubWords ?? refused.Message; }
        catch (HubException lost) when (lost.Kind == HubErrorKind.NoAnswer) { AskedCheck = null; }
        catch (Exception e) when (e is HubException or InvalidOperationException or ArgumentException or System.Text.Json.JsonException) { }
    }

    /// <summary>**The activation, against the newest team.json** (the Mac's <c>activate</c>): the hub takes it only after a
    /// passed check of the saved settings, and the setup's page then waits for the reading that shows the agent active. A
    /// team.json that changed between the read and the press is read again, once, as the Mac's request line does.</summary>
    private async Task ActivateAsync(AgentReading reading, CancellationToken cancel)
    {
        if (!Permits(reading)) return;
        Refusal = null;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            TeamReading? team;
            try { team = (await OwnerReads.TeamAsync(calls, cancel).ConfigureAwait(false)).Value; }
            catch (Exception e) when (e is HubException or InvalidOperationException or System.Text.Json.JsonException) { team = null; }
            if (team is null)
            {
                Refusal = CannotReadTeam;
                return;
            }
            try
            {
                if ((await OwnerReads.ActivateAsync(calls, Agent, team.Sha256, cancel: cancel).ConfigureAwait(false)).Value is not null)
                    Activated = true;
                return;
            }
            catch (HubException refused) when (refused is { Status: 409, Code: "team_changed" } && attempt == 0) { }
            catch (HubException refused) when (refused.Kind == HubErrorKind.Refusal)
            {
                Refusal = refused.HubWords ?? refused.Message;
                return;
            }
            catch (Exception e) when (e is HubException or InvalidOperationException or ArgumentException or System.Text.Json.JsonException)
            {
                Refusal = NoAnswer;
                return;
            }
        }
    }

    /// <summary>**Try again of a stop on the activation's page** (the Mac's <c>tryAgain</c>): the check and the activation
    /// run again by themselves, as on a first visit.</summary>
    public void TryAgain()
    {
        Refusal = null;
        AskedCheck = null;
        AskedActivation = false;
        Activated = false;
    }

    /// <summary>**Claude Code's code, to the machine, and then forgotten here**: only while the sign-in waits for it and
    /// no code is on its way.</summary>
    public async Task<bool> SendCodeAsync(AgentReading reading, string code, CancellationToken cancel = default)
    {
        if (reading.Machine(Agent)?.Login is not { } login || login.CodeOnItsWay(SentFrom) || MachineLogin.CodeOf(code) is null) return false;
        Refusal = null;
        SentFrom = login.UpdatedAt;
        try
        {
            await OwnerReads.SignInCodeAsync(calls, Agent, code, cancel: cancel).ConfigureAwait(false);
            return true;
        }
        catch (Exception e) when (e is HubException or InvalidOperationException or ArgumentException or System.Text.Json.JsonException)
        {
            SentFrom = null;
            Refusal = (e as HubException) is { Kind: HubErrorKind.Refusal } refused ? refused.HubWords ?? CodeLost : CodeLost;
            return false;
        }
    }

    /// <summary>**The provider's own page opens by itself** only for a sign-in that the owner's press asked for here, and
    /// only once; the window opens <see cref="Agents.SignInPage.Link"/>, which is only ever a link of the provider's own
    /// hosts.</summary>
    public bool OpensByItself(SignInPage page) => AgentSetupFlow.OpensByItself(AskedSignIn, Opened, page.Link);
}
