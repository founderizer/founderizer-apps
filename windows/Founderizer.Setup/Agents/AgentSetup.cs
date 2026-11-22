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

/// <summary>**The setup of the manager of a new fleet, as a model** (windows-app-plan-v2.md, piece L4; the Mac's
/// <c>AgentSetupWizard</c> for the manager's first server): the page from the hub's own readings, the server and the
/// provider that the first run gave it, placed by itself, and the sign-in. It reads through the owner's calls of the
/// PC (<see cref="OwnerReads"/>). The pages of an agent that runs, and a change of provider, are wave C's.</summary>
public sealed class AgentSetupModel(OwnerReads.ICalls calls, string agent)
{
    /// <summary>The agent of this setup.</summary>
    public string Agent { get; } = agent;

    /// <summary>The words of a step that the hub did not answer, of a server that the PC cannot read, and of a code that
    /// did not reach the hub (the Mac's <c>AgentSetupWizard</c>).</summary>
    public const string NoAnswer = "The hub has not answered. Try again.";
    public const string CodeLost = "The code did not reach the hub. Paste it again.";
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

    /// <summary>**A new visit of the setup's page** (the Mac's view, whose states start again): no refusal, no command
    /// refused, no code on its way, no sign-in asked or opened.</summary>
    public void NewVisit()
    {
        Refusal = null;
        PlaceRefused = false;
        SentFrom = null;
        Opened = false;
        AskedSignIn = false;
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
        var entry = list.Servers.FirstOrDefault(s => s.Name == joined);
        return entry is not null && !entry.Hub && entry.Agents.All(a => a == Agent) ? joined : null;
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
        reading.Agent is { } a && AgentSetupFlow.Places(a, reading.Features, placing: true);

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
        await PlaceAsync(server, provider, cancel).ConfigureAwait(false);
        PlaceRefused = Refusal is not null;
        AskedSignIn = Refusal is null;
    }

    /// <summary>**Its server and its provider, in one command** (owner API 1.82): a team.json that changed between the
    /// read and the press is read again, once.</summary>
    private async Task PlaceAsync(string server, string provider, CancellationToken cancel)
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
            catch (HubException refused) when (refused is { Status: 409, Code: "team_changed" } && attempt == 0) { }
            catch (HubException refused) when (refused.Kind == HubErrorKind.Refusal)
            {
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
                await PlaceAsync(server.Name, provider, cancel).ConfigureAwait(false);
                break;
            case AgentSetupFlow.Start.InstallAgain:
                Refusal = CannotReadServer(Agent);
                break;
            case AgentSetupFlow.Start.Prepare:
                // A change to the other provider is a page of wave C: no card offers it (Cards), and a press gets nothing.
                return;
        }
        AskedSignIn = start.SignsIn() && Refusal is null;
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
