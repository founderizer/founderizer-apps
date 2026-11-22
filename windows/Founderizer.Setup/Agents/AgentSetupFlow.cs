using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Core;
using Founderizer.Owner.Reads;

namespace Founderizer.Setup.Agents;

/// <summary>**A page of the setup of one agent that is not active yet, or that is signed out**, in place of its chat
/// (the Mac's AgentSetupPage; the owner, 25 October 2026: "Choose the server, choose AI provider, sign in... and
/// confirm! that's it!!"). <c>Installing</c>, <c>Switching</c> and <c>SignIn</c> carry the provider (<see
/// cref="AgentPage.Runtime"/>).</summary>
public enum AgentSetupPage
{
    /// <summary>Its name, for a manager with no server on a hub that can rename it.</summary>
    Name,
    /// <summary>The fleet's servers, after its name and its AI provider: the slider of the first run.</summary>
    Servers,
    /// <summary>Where it runs, for the manager of a new fleet, which has no server yet.</summary>
    Server,
    /// <summary>Which AI runs it: both providers, with a check mark on the one it has now.</summary>
    Provider,
    /// <summary>The server installs or prepares the provider by itself: one wait, nothing to press.</summary>
    Installing,
    /// <summary>The agent goes over to the other provider.</summary>
    Switching,
    /// <summary>The owner's own sign-in, on the provider's page.</summary>
    SignIn,
    /// <summary>The machine check, then the activation, both by themselves.</summary>
    Activate,
}

/// <summary>One page of an agent's setup, with the provider of an install, a switch or a sign-in.</summary>
public sealed record AgentPage(AgentSetupPage Kind, string? Runtime = null)
{
    public static AgentPage Of(AgentSetupPage kind) => new(kind);
    public static AgentPage Installing(string runtime) => new(AgentSetupPage.Installing, runtime);
    public static AgentPage Switching(string runtime) => new(AgentSetupPage.Switching, runtime);
    public static AgentPage SignIn(string runtime) => new(AgentSetupPage.SignIn, runtime);
}

/// <summary>**One agent as its setup reads it** (the fields of the Mac's FleetAgent that the setup reads), from the
/// owner's reads of the PC: GET /ui/mobile's row (its role, runtime, active, and the sessions that its helper lists),
/// GET /ui/servers (it is placed when a server lists it: the hub lists no agent whose team.json entry says
/// <c>"placed": false</c>), and GET /ui/machines (its machine's sign-in of its own runtime, null for a stale reading, as
/// the hub's <c>signed_in_now</c> says it).</summary>
public sealed record SetupAgent(string Name, string Role, string Runtime, bool? Active, bool Placed, bool? SignedIn,
                                string? Alive = null, bool? ChatReady = null, bool AtLimit = false, double? LastSeen = null)
{
    public static SetupAgent Of(MobileAgent row, ServerList? servers, MachineList? machines)
    {
        var machine = machines?.Of(row.Name);
        var signedIn = machine is null || machine.Stale == true ? null : machine.SignedIn(row.Runtime);
        var placed = servers is null || servers.ServerOf(row.Name) is not null;
        return new SetupAgent(row.Name, row.Role, row.Runtime, row.Active, placed, signedIn, row.Alive, null, row.Limit is not null,
                              row.LastSeen);
    }

    /// <summary>The helper answered in the last minute of the hub's own clock.</summary>
    public bool HelperIsRecent(double serverTime) => LastSeen is { } seen && serverTime - seen >= -5 && serverTime - seen < 60;
}

/// <summary>**The rules of an agent's setup, as the pages its screen shows in place of its chat** (the Mac's
/// FleetCore/AgentSetupFlow.swift). The PC has no agent on a key or a model server in step 2 (its seal is wave B, its
/// pages wave C): the Mac's branches for <c>modelProvider</c> are not here.</summary>
public static class AgentSetupFlow
{
    /// <summary>The hub features that the setup pages stand on. A hub without one of them keeps the agent's chat.</summary>
    public static readonly IReadOnlyList<string> Features = ["servers", "machine_signin", "agent_setup", "machines"];

    /// <summary>The hub gives the manager of a new fleet its server in its own setup (owner API 1.82).</summary>
    public const string ServerFeature = "manager_server";

    /// <summary>The setup pages take the place of the chat: the agent is not active, its machine reports it signed out,
    /// or it gets its first server.</summary>
    public static bool Shows(SetupAgent? agent, IReadOnlyList<string> features, bool placing = false)
    {
        if (agent is null || !Features.All(features.Contains)) return false;
        if (!MachineLogin.CanSignIn(agent.Runtime)) return false;
        return agent.Active == false || agent.SignedIn == false || Places(agent, features, placing);
    }

    /// <summary>**The manager of a new fleet gets its server in its own setup**: while it has none, and after the press
    /// that gives it one, through the install and the sign-in, until it runs. <paramref name="placing"/>: this PC saw it
    /// with no server on this hub generation.</summary>
    public static bool Places(SetupAgent agent, IReadOnlyList<string> features, bool placing) =>
        features.Contains(ServerFeature) && (!agent.Placed || (placing && !Runs(agent)));

    /// <summary>**Its setup fills the window, drawn alone, as the first run is** (the Mac's <c>fillsWindow</c> of an agent
    /// that Add agent did not add on this computer: the PC has no Add agent yet): the setup of the manager of a new fleet,
    /// from its server's page to its first session. An agent that ran before keeps its setup in its page (wave C).</summary>
    public static bool FillsWindow(SetupAgent? agent, IReadOnlyList<string> features, bool placing) =>
        agent is not null && Shows(agent, features, placing) && Places(agent, features, placing);

    /// <summary>**The end of its first setup**: signed in on its own server, with its standing session listed.</summary>
    public static bool Runs(SetupAgent agent) =>
        agent.Placed && agent.SignedIn == true && (agent.Alive ?? "").Split(',').Contains("manager");

    /// <summary>**Adding an agent ends** on a reading that answered: its setup no longer shows and its chat can answer, or
    /// the hub no longer lists it.</summary>
    public static bool AddingEnds(SetupAgent? agent, IReadOnlyList<string> features, bool placing = false) =>
        agent is null || (!Shows(agent, features, placing) && agent.ChatReady != false);

    /// <summary>**A server it can go on**: one that the hub offers for a new agent and that has none yet, and not the
    /// hub's own.</summary>
    public static bool IsFree(ServerEntry server) => server.Available && server.Agents.Count == 0 && !server.Hub;

    /// <summary>**"Setting up" in place of a chat that cannot answer yet**: while the reading is current, its machine is
    /// online and at no usage limit.</summary>
    public static bool ChatStarts(SetupAgent? agent, double serverTime, bool fresh) =>
        agent is not null && fresh && agent.ChatReady == false && !agent.AtLimit && agent.HelperIsRecent(serverTime);

    /// <summary>The newest job of the agent's server, when that job is about this agent. The install of an active agent
    /// that is over is history, however it ended.</summary>
    public static ServerJob? Job(string agent, ServerEntry? server, bool active = false)
    {
        if (server?.Job is not { } job || job.Agent != agent) return null;
        if (active && job.Kind == "install" && !job.IsOpen) return null;
        return job;
    }

    /// <summary>The steps of an install (the Mac's <c>Servers.installSteps</c>), of a preparation, and of a removal.</summary>
    public static readonly IReadOnlyList<(string Id, string Title)> InstallSteps =
        [("user", "User"), ("runtime", "AI provider"), ("checkout", "Checkout"), ("service", "Service"), ("sign_in", "Sign-in")];
    public static readonly IReadOnlyList<(string Id, string Title)> PrepareSteps = [("runtime", "AI provider"), ("sign_in", "Sign-in")];
    public static readonly IReadOnlyList<(string Id, string Title)> RemoveSteps =
        [("service", "Its service"), ("files", "Its files"), ("user", "Its account")];
    public static readonly IReadOnlyList<(string Id, string Title)> AccountInstallSteps =
        [("user", "User"), ("checkout", "Checkout"), ("runtime", "AI provider"), ("service", "Service")];

    /// <summary>The steps of a job, as a server's page draws them as rows (the Mac's <c>Servers.steps</c>).</summary>
    public static IReadOnlyList<(string Id, string Title)> Steps(ServerJob job, bool onMac = false)
    {
        if (job.Kind == "prepare") return PrepareSteps;
        if (job.HasNoSignIn && job.Kind is "install" or "rename")
        {
            var titles = AccountInstallSteps.ToDictionary(s => s.Id, s => s.Title);
            var rows = job.StepList is { } ids ? ids.Where(titles.ContainsKey).Select(id => (id, titles[id])).ToList() : AccountInstallSteps.ToList();
            return onMac ? rows.Where(r => r.Item1 != "user").ToList() : rows;
        }
        var steps = job.Kind == "remove" ? RemoveSteps : InstallSteps;
        return onMac ? steps.Where(s => s.Id != "user").ToList() : steps;
    }

    /// <summary>**The install's steps, as a bar under its moving title**: one part for each step of the server's job,
    /// with the part that runs now from 0, or null while the job waits in the queue or for a step that the list does not
    /// hold. With no job yet, the steps of an install on that server, none running. Null for a job of another kind.</summary>
    public static (IReadOnlyList<string> Steps, int? Running)? InstallBar(ServerJob? job, bool onMac)
    {
        if (job is null) return (InstallSteps.Where(s => !onMac || s.Id != "user").Select(s => s.Title).ToList(), null);
        if (job.Kind is not ("install" or "prepare")) return null;
        var steps = Steps(job, onMac);
        int? running = null;
        if (job.State == "running")
            for (var i = 0; i < steps.Count; i++)
                if (steps[i].Id == job.Step) { running = i; break; }
        return (steps.Select(s => s.Title).ToList(), running);
    }

    /// <summary>**The part of the bar that runs, which never goes back while one job runs**.</summary>
    public static int? BarPart(int? running, int? furthest) => running is { } now ? Math.Max(now, furthest ?? now) : furthest;

    /// <summary>The title of the install's page: what installs and where.</summary>
    public static string Installing(string provider, string server) => $"Installing {provider} on {server}";

    /// <summary>**The page the setup shows now, from the hub's own readings.** A job or a sign-in that goes on is its own
    /// page. <paramref name="switchingTo"/> is the other provider that the owner chose on this visit, until the agent
    /// runs it. An agent that its machine reports signed in is activated by itself; any other starts with its provider.</summary>
    public static AgentPage Page(string runtime, ServerJob? job, MachineStatus? machine, string? switchingTo)
    {
        if (job is { IsOpen: true })
        {
            var provider = job.Runtime ?? runtime;
            return job.State == "needs_owner" ? AgentPage.SignIn(provider) : AgentPage.Installing(provider);
        }
        if (machine?.Login is { IsOpen: true } login) return AgentPage.SignIn(login.Runtime);
        if (switchingTo is { } to)
        {
            if (job is { Kind: "prepare", State: "failed" } && job.Runtime == to) return AgentPage.Of(AgentSetupPage.Provider);
            if (to != runtime || machine?.SettingsPending == true || machine?.Runtime.Name != to) return AgentPage.Switching(to);
        }
        if (SignedIn(runtime, machine)) return AgentPage.Of(AgentSetupPage.Activate);
        return AgentPage.Of(AgentSetupPage.Provider);
    }

    /// <summary>Its machine reports the agent's own provider loaded and signed in.</summary>
    public static bool SignedIn(string runtime, MachineStatus? machine) =>
        machine is { Stale: not true } && machine.Runtime.Name == runtime && machine.Runtime.SignedIn == true;

    /// <summary>**Why the setup stopped the last time, in the hub's own words**, for the provider page: an install or a
    /// preparation of this agent that failed, or a sign-in that failed while it is still signed out. Nothing while either
    /// goes on, once it is signed in, or for one that only waited too long for the owner.</summary>
    public static string? Stopped(string runtime, ServerJob? job, MachineStatus? machine)
    {
        if (SignedIn(runtime, machine)) return null;
        if (machine is not null && SignIn.Line(machine, working: false) is { Warn: true } line) return machine.Login?.Reason ?? line.Says;
        if (job is { State: "failed" } && job.TimedOut != true)
            return Offline(job.Detail, runtime, machine?.Machine) ?? Trimmed(job.Detail) ?? "The install stopped.";
        return null;
    }

    /// <summary>**An install that could not reach the internet, in plain words**: the hub's detail carries the system's
    /// own code ("… (ETIMEDOUT)").</summary>
    internal static string? Offline(string? detail, string runtime, string? server)
    {
        if (detail is null || !new[] { "ETIMEDOUT", "ECONNRESET", "EAI_AGAIN" }.Any(detail.Contains)) return null;
        var name = SignIn.ProviderName(runtime);
        return server is not null ? $"{name} did not install: {server} could not reach the internet."
                                  : $"{name} did not install: its server could not reach the internet.";
    }

    /// <summary>The hub's words without the step that they end with: the provider cards are that step.</summary>
    internal static string? Trimmed(string? detail)
    {
        var words = detail?.Trim();
        if (string.IsNullOrEmpty(words)) return null;
        foreach (var tail in new[] { "Try again in Fleet.", "Try again in Founderizer.", "Try again." })
            if (words.EndsWith(tail, StringComparison.Ordinal)) words = words[..^tail.Length].Trim();
        return words.Length == 0 ? null : words;
    }

    /// <summary>**What a choice of provider asks the hub to do**, given what the hub has now.</summary>
    public enum Start
    {
        /// <summary>The agent's install failed: the same install again.</summary>
        InstallAgain,
        /// <summary>The provider is installed and signed out: a sign-in on the agent's machine.</summary>
        SignIn,
        /// <summary>It is signed in already: on to the activation.</summary>
        Activate,
        /// <summary>The other provider: the server installs and signs it in, then the agent switches to it.</summary>
        Prepare,
    }

    /// <summary>**The owner's press asks for the sign-in** (the owner, 6 November 2026: "when I said claude code I wanted
    /// to sign in! we should save that click"): so the page opens the provider's sign-in page by itself, once.</summary>
    public static bool SignsIn(this Start start) => start != Start.Activate;

    public static Start StartOf(string chosen, string runtime, ServerJob? job, MachineStatus? machine)
    {
        if (chosen != runtime) return Start.Prepare;
        if (SignedIn(runtime, machine)) return Start.Activate;
        if (job is { Kind: "install", State: "failed" }) return Start.InstallAgain;
        return Start.SignIn;
    }

    /// <summary>**The provider's page opens without a second press** only for a sign-in that the owner's own press on a
    /// card asked for on this visit, and only until it is open.</summary>
    public static bool OpensByItself(bool askedHere, bool opened, Uri? link) => askedHere && !opened && link is not null;

    /// <summary>**The one check item that stands between the agent and its activation**, in a line: the first required
    /// item that did not pass, with the check's own detail.</summary>
    public static string? Blocker(MachineVerification? result)
    {
        var item = result?.Items.FirstOrDefault(i => i.Required == true && i.State != "ok");
        if (item is null) return null;
        var detail = item.Detail.Trim();
        if (item.Kind == "account") return detail.Length == 0 ? null : detail;
        var title = string.Join(' ', item.Ref.Replace('_', ' ').Split(' ').Select(Capital));
        return detail.Length == 0 ? $"{title} did not pass." : $"{title}: {detail}";
    }

    /// <summary>Swift's <c>capitalized</c> of one word: its first letter large, the rest small.</summary>
    private static string Capital(string word) =>
        word.Length == 0 ? word : char.ToUpperInvariant(word[0]) + word[1..].ToLowerInvariant();
}
