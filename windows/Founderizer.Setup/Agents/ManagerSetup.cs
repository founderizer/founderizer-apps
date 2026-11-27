using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Founderizer.Setup.FirstRun;

namespace Founderizer.Setup.Agents;

/// <summary>**What this PC keeps of the manager's first setup** (the Mac's <c>FleetStore</c> marks <c>unplacedAgents</c>,
/// <c>serversJoinedFor</c> and <c>providersChosenFor</c>, under one key: the hub's address, its generation and the
/// manager's name): the first run writes it at each reading of the hub that it claimed and at its hand-over, a current
/// reading of a manager with no server writes it too (<see cref="ManagerPlacing"/>), each start of the app reads it, and it
/// goes once the manager runs or Start again takes the hub away. So an app that starts again during the hub's install, the
/// manager's install or its sign-in opens on that page, and not on a chat that cannot answer yet. It holds the provider
/// that the owner chose for a manager with no server, the server that joined for it, and the server that the first run
/// made for it and that did not join (<see cref="Made"/>, the Mac's <c>firstRunServerFor</c>); no key, token or
/// code.</summary>
public sealed partial record ManagerSetupMark(Uri Hub, string Db, string Agent, string? Provider = null, string? Joined = null,
                                              FirstRunServer? Made = null)
{
    /// <summary>The name of the mark among the first run's kept answers (<see cref="ISetupChoices"/>).</summary>
    public const string ChoiceName = "managerFirstSetup";

    /// <summary>One write of the mark at a time in this app: the first run, the reading's rule and the setup each write it
    /// from a thread of their own, and a read and the write that follows it must have no other write between them.</summary>
    private static readonly object Writes = new();

    /// <summary>The part of a kept mark that says <see cref="FirstRunServer.Tried"/>.</summary>
    private const string TriedPart = "tried";

    /// <summary>The mark that this PC keeps, or null for none, or for one of no valid shape.</summary>
    public static ManagerSetupMark? Read(ISetupChoices choices)
    {
        if (choices.Get(ChoiceName)?.Split('|') is not [var hub, var db, var agent, var provider, var joined, .. var made] ||
            made.Length is not (0 or 2 or 3) || made.Length == 3 && made[2] != TriedPart)
            return null;
        Uri address;
        try { address = HubClient.Address(hub); }
        catch (HubException) { return null; }
        if (db.Length is 0 or > 200 || !AgentShape().IsMatch(agent) || provider is not ("" or "claude" or "codex") ||
            joined.Length > 0 && !ServerNames.IsMachine(joined) ||
            made.Length >= 2 && (!ServerNames.IsMachine(made[0]) || !System.Net.IPAddress.TryParse(made[1], out _)))
            return null;
        return new ManagerSetupMark(address, db, agent, provider.Length == 0 ? null : provider, joined.Length == 0 ? null : joined,
                                    made.Length >= 2 ? new FirstRunServer(made[0], made[1], made.Length == 3) : null);
    }

    /// <summary>Keeps this mark in place of the one before, the hub by its scheme, host and port alone; a mark with a "|"
    /// in a part, or a hub address that is not HTTP or HTTPS, is not kept. It never throws: the hand-over writes it.</summary>
    public void Keep(ISetupChoices choices)
    {
        if (Hub is not { IsAbsoluteUri: true, Scheme: "http" or "https" }) return;
        string[] parts = [Hub.GetLeftPart(UriPartial.Authority) + "/", Db, Agent, Provider ?? "", Joined ?? "",
                          .. Made is { } made ? made.Tried ? new[] { made.Name, made.Address, TriedPart } : new[] { made.Name, made.Address } : []];
        if (parts.Any(p => p.Contains('|'))) return;
        lock (Writes) choices.Set(ChoiceName, string.Join('|', parts));
    }

    /// <summary>**Keeps this mark when the PC keeps none of this hub and this generation**: a mark that the first run or
    /// the setup wrote keeps its provider and its joined server. A mark of another hub or generation is replaced.</summary>
    public void KeepIfNone(ISetupChoices choices)
    {
        lock (Writes)
            if (Read(choices)?.IsOf(Hub, Db) != true) Keep(choices);
    }

    /// <summary>**Keeps this mark when the kept one says something else**, and writes nothing for a mark that is there.</summary>
    public void KeepChanged(ISetupChoices choices)
    {
        lock (Writes)
            if (Read(choices) is not { } kept || !kept.IsOf(Hub, Db) || (kept.Agent, kept.Provider, kept.Joined, kept.Made) != (Agent, Provider, Joined, Made))
                Keep(choices);
    }

    public static void Forget(ISetupChoices choices)
    {
        lock (Writes) choices.Set(ChoiceName, null);
    }

    /// <summary>**The mark for which the window shows the manager's setup now**: the PC is the owner's computer of the hub
    /// of the mark, the store holds a reading of that generation, and that reading has the manager; or the reading has no
    /// agent of the mark's name any more and this window asked to rename that manager (<see cref="NoteRename"/>), and then
    /// the mark is that of the manager's name in it. Null otherwise.</summary>
    public static ManagerSetupMark? Shown(StoreState state, ISetupChoices choices)
    {
        if (state.Role != HubRole.Owner || state.Fleet is not { } fleet || Read(choices) is not { } mark || !mark.IsOf(state.Hub, fleet.Db))
            return null;
        if (fleet.Agents.Any(a => a.Name == mark.Agent)) return mark;
        return Renamed(state) is { } r && r.Was == mark.Agent ? mark with { Agent = r.Now } : null;
    }

    /// <summary>**The rename of this manager that this window asked for on this run** (the Mac's
    /// <c>FleetStore.renamedManager</c>): its hub, its generation and the name that it had. It is noted before the rename
    /// goes, and nothing takes it away but the reading that has no agent of that name: a refusal says only that its own
    /// command renamed nothing, and a note whose manager keeps its name does nothing. So an answer that is lost after the
    /// hub renamed still finds the manager, under the name that the reading gives it, and the mark goes there
    /// (<see cref="TakeRename"/>).</summary>
    private static ManagerRenameNote? renamed;

    /// <summary>Notes the rename of this manager before it goes.</summary>
    public static void NoteRename(Uri hub, string db, string was)
    {
        lock (Writes) renamed = new ManagerRenameNote(hub, db, was);
    }

    /// <summary>This window asked to rename this manager of this hub and generation, and no reading has shown it under
    /// another name since (the Mac's <c>renameNoted</c>).</summary>
    public static bool RenameNoted(Uri hub, string db, string was)
    {
        lock (Writes) return renamed?.Is(hub, db, was) == true;
    }

    /// <summary>The noted rename that this reading shows: of its hub and generation, with no agent of the noted name any
    /// more, and the manager's name in it; or null.</summary>
    private static (string Was, string Now)? Renamed(StoreState state)
    {
        lock (Writes)
            return renamed is { } note && state.Hub is { } hub && state.Fleet is { } fleet && note.Follow(hub, fleet) is { } now ? (note.Was, now) : null;
    }

    /// <summary>**The rename that this reading shows**, once: the reading of the note's hub and generation has no agent of
    /// the noted name, and its manager has another. The kept mark of that hub and generation goes to the manager's name
    /// now, with its provider and its joined server, and the window moves the manager's pages there (the Mac's
    /// <c>FleetStore.notePlacing</c> with <c>renamedManager</c>); the note goes.</summary>
    public static (string Was, string Now)? TakeRename(StoreState state, ISetupChoices choices)
    {
        lock (Writes)
        {
            if (Renamed(state) is not { } r) return null;
            renamed = null;
            if (Read(choices) is { } kept && kept.IsOf(state.Hub, state.Fleet!.Db) && kept.Agent == r.Was) (kept with { Agent = r.Now }).Keep(choices);
            return r;
        }
    }

    /// <summary>**A kept mark of an agent that the reading no longer has goes to the manager's name now**, with its provider
    /// and its joined server: a rename whose note this app does not have (an app that ended before the reading of the new
    /// name, another computer's rename). Nothing for a mark of another hub or generation, or of an agent that the reading
    /// has.</summary>
    public static void FollowManager(ISetupChoices choices, Uri hub, MobileSnapshot fleet, string manager)
    {
        lock (Writes)
            if (Read(choices) is { } kept && kept.IsOf(hub, fleet.Db) && kept.Agent != manager && fleet.Agents.Any(a => a.Name == manager) &&
                !fleet.Agents.Any(a => a.Name == kept.Agent))
                (kept with { Agent = manager }).Keep(choices);
    }

    /// <summary>A name that a mark can hold.</summary>
    public static bool Holds(string agent) => AgentShape().IsMatch(agent);

    /// <summary>The mark is of this hub: the same scheme, host and port (a hub's address has no path, and a recorded one
    /// with a path or a query is still that hub). It never throws: Start again asks it in its last step.</summary>
    public bool IsOf(Uri hub) =>
        hub.IsAbsoluteUri && Hub.IsAbsoluteUri &&
        Uri.Compare(hub, Hub, UriComponents.SchemeAndServer, UriFormat.SafeUnescaped, StringComparison.OrdinalIgnoreCase) == 0;

    /// <summary>The mark is of this hub and of this generation of it.</summary>
    public bool IsOf(Uri? hub, string? db) => hub is not null && db == Db && IsOf(hub);

    [GeneratedRegex(@"\A[a-z][a-z0-9_-]{0,63}\z", RegexOptions.CultureInvariant)]
    private static partial Regex AgentShape();
}

/// <summary>**The manager's own server that the first run made and that did not join** (the Mac's
/// <c>FleetStore.MadeServer</c>): its name and its address on the private network. The server's page installs it by itself,
/// once (<see cref="AgentServerStep"/>). <paramref name="Tried"/>: that join by itself of the page has started, so a stop
/// of it waits for Try again; before it, a stop of the first run's own join of this server holds nothing.</summary>
public sealed record FirstRunServer(string Name, string Address, bool Tried = false);

/// <summary>**A manager that the hub shows with no server gets its mark on the owner's computer, at a current reading**
/// (windows-app-plan-v2.md, the read of U3, fault 1; the Mac's <c>FleetStore.notePlacing</c>): so the manager's setup
/// shows also when no first run of this app wrote the mark, as after an app that ended between the hub's claim and its
/// first reading. The PC's reading of the hub (<c>/ui/mobile</c>) does not say where an agent runs, so the rule reads the
/// hub's servers, once for each generation of the hub while this PC keeps no mark of it, and never again in this run of
/// the app once the manager has its server. A mark that is there keeps its provider and its joined server.</summary>
public sealed class ManagerPlacing(OwnerReads.ICalls calls, ISetupChoices choices)
{
    private readonly object gate = new();
    private bool reading;
    /// <summary>The hub and the generation whose manager has its server: nothing more to read for them in this run.</summary>
    private string? placedOf;

    /// <summary>**One state of the owner's store**: only a current reading of a hub whose owner's computer this PC is, that
    /// offers the manager's own setup (<see cref="AgentSetupFlow.ServerFeature"/>). One read of the servers at a time; a
    /// read that does not answer is asked again at a later reading. The window does not wait for it; a test does.</summary>
    public async Task NoteAsync(StoreState state, DateTimeOffset now, CancellationToken cancel = default)
    {
        if (state.Role != HubRole.Owner || state.Hub is not { } hub || state.Fleet is not { } fleet || !state.IsFresh(now)) return;
        if (!fleet.Offers(AgentSetupFlow.ServerFeature) || !AgentSetupFlow.Features.All(fleet.Offers)) return;
        if (fleet.Agents.FirstOrDefault(a => a.Role == "manager") is not { } manager || !ManagerSetupMark.Holds(manager.Name)) return;
        if (ManagerSetupMark.Read(choices)?.IsOf(hub, fleet.Db) == true)
        {
            // A mark that is there keeps its provider and its joined server, under the manager's name now.
            ManagerSetupMark.FollowManager(choices, hub, fleet, manager.Name);
            return;
        }
        var key = hub.GetLeftPart(UriPartial.Authority) + "|" + fleet.Db;
        lock (gate)
        {
            if (reading || placedOf == key) return;
            reading = true;
        }
        try
        {
            if ((await OwnerReads.ServersAsync(calls, cancel).ConfigureAwait(false)).Value is not { } list || list.Db != fleet.Db) return;
            if (list.ServerOf(manager.Name) is not null)
            {
                lock (gate) placedOf = key;
                return;
            }
            new ManagerSetupMark(hub, fleet.Db, manager.Name).KeepIfNone(choices);
        }
        catch (Exception e) when (e is HubException or InvalidOperationException or System.Text.Json.JsonException) { }
        finally
        {
            lock (gate) reading = false;
        }
    }
}

/// <summary>What the manager's first setup needs from the PC (the window gives each; a test gives stand-ins).</summary>
public sealed class ManagerSetupSettings
{
    /// <summary>The owner's calls of the hub (<see cref="OwnerReads.Of"/> of the owner's store).</summary>
    public required OwnerReads.ICalls Calls { get; init; }
    /// <summary>The hub's reading that the owner's store holds now, or null while none is current.</summary>
    public required Func<MobileSnapshot?> Fleet { get; init; }
    /// <summary>The first run's kept answers, where the mark is (<see cref="ManagerSetupMark"/>).</summary>
    public required ISetupChoices Choices { get; init; }
    /// <summary>The owner's store reads the hub again now (the Mac's <c>store.refresh</c> while "Setting up" waits for the
    /// manager's session).</summary>
    public Func<Task>? Refresh { get; init; }
    /// <summary>**The owner's store holds a current reading of the hub** (the Mac's <c>store.isFresh</c>): the setup reads
    /// nothing, and counts no read, while it does not (a window that is behind, a hub that does not answer). Null: always.</summary>
    public Func<bool>? Fresh { get; init; }
    public Func<TimeSpan, CancellationToken, Task> Pause { get; init; } = Task.Delay;
    /// <summary>The hub that the owner's store is on now (its <c>State.Hub</c>): a press of the setup goes only to its mark's
    /// hub, and the server's page joins a server only while it is the hub of this setup, and its generation is this setup's
    /// (<see cref="OwnerReads.ICalls.Database"/>). Null: the generation alone says it.</summary>
    public Func<Uri?>? Hub { get; init; }
    /// <summary>**The owner's store can send a write now** (the Mac's <c>store.canWrite</c>): Try again of a stopped
    /// activation shows only then. Null: always.</summary>
    public Func<bool>? CanWrite { get; init; }
    /// <summary>What the server's page of a manager with no server needs to make one (piece L4b): null on a build that
    /// makes none, whose page only takes a server of the fleet.</summary>
    public AgentServerSettings? Server { get; init; }
}

/// <summary>**The manager's first setup as its pages read it**: an immutable value; each read and each press makes a new
/// one, and <see cref="ManagerSetup.Changed"/> says so.</summary>
public sealed record ManagerSetupView
{
    public required string Agent { get; init; }
    /// <summary>The manager as the apps name it: its name with capitals, or its role when one word of the role is the
    /// name (the Mac's <c>agentLabel</c>).</summary>
    public required string Label { get; init; }
    /// <summary>A read of this setup answered: the page comes from it (the Mac's <c>readingsCurrent</c>).</summary>
    public bool Answered { get; init; }
    public AgentReading? Reading { get; init; }
    /// <summary>The page that the setup shows, or null before the first read.</summary>
    public AgentPage? Page { get; init; }
    public ManagerSetupStart? Start { get; init; }
    /// <summary>The provider cards, in their order, and the one with the check mark.</summary>
    public IReadOnlyList<string> Cards { get; init; } = [];
    public string? Marked { get; init; }
    /// <summary>The hub's words when it refused a step, or this app's for one that it did not answer, until the next step.</summary>
    public string? Refusal { get; init; }
    /// <summary>The words in the field of "Name your manager".</summary>
    public string TypedName { get; init; } = "";
    /// <summary>The hub's features at this visit's first read (the Mac's <c>startFeatures</c>), or null before it.</summary>
    public IReadOnlyList<string>? StartFeatures { get; init; }
    /// <summary>Why the setup stopped the last time, in the hub's own words (<see cref="AgentSetupFlow.Stopped"/>), split
    /// in two lines where it says why (the Mac's <c>lines</c>).</summary>
    public string? Stopped { get; init; }
    /// <summary>The agent's install failed: Try again runs it again.</summary>
    public bool InstallFailed { get; init; }
    public SignInPage? SignIn { get; init; }
    /// <summary>The steps of the server's job as a bar, and the part that runs, which never goes back while one job runs.</summary>
    public IReadOnlyList<string>? BarSteps { get; init; }
    public int? BarPart { get; init; }
    /// <summary>The server that the install title names (the Mac's <c>serverName</c>).</summary>
    public string Server { get; init; } = ManagerSetupScreens.ItsServer;
    /// <summary>A press of this setup is on its way: no second one, no Try again, and no Continue.</summary>
    public bool Busy { get; init; }
    /// <summary>The reads in a row that had no list of the hub's servers while the hub answered its state.</summary>
    public int UnreadReads { get; init; }
    /// <summary>**The wait for the hub's reading of its own server stopped** (the Mac's <c>HubShareModel.stop</c> after
    /// <see cref="ManagerSetup.ShareReadsMost"/> reads): "1 server" is kept, and the hub never said that its server takes
    /// the manager. The page says so over Try again.</summary>
    public bool ShareStopped { get; init; }
    /// <summary>The step on Back's line before the first read (the Mac draws them from the first frame): the servers'
    /// step for a manager that the first run gave a server or a provider to, else the sign-in; null for no line.</summary>
    public int? FirstStep { get; init; }
    /// <summary>The setup fills the window now (<see cref="AgentSetupFlow.FillsWindow"/>; before its first read, by the
    /// mark alone). Never for an agent that is not the manager of a new fleet.</summary>
    public bool Shows { get; init; } = true;
    /// <summary>The manager runs: the mark is gone, and the window shows its chat. For any other agent: its setup's pages
    /// no longer take the place of its chat (<see cref="AgentSetupFlow.AddingEnds"/>).</summary>
    public bool Ended { get; init; }
    /// <summary>The first setup of the manager of a new fleet, with the steps on Back's line and the line of its provider's
    /// page (the Mac's <c>isFirstSetupOfManager</c>). False for the setup of any other agent (<see
    /// cref="ManagerSetup.ForAgent"/>).</summary>
    public bool FirstSetup { get; init; } = true;
    /// <summary>**The setup's pages take the place of the agent's chat now** (the Mac's <c>AgentSetupFlow.shows</c>): also
    /// for an agent whose setup does not fill the window, as a worker that a team card added.</summary>
    public bool TakesChat { get; init; } = true;
    /// <summary>It is active and only signed out: its last page waits for the machine to report the sign-in, and nothing
    /// activates it.</summary>
    public bool SigningInAgain { get; init; }
    /// <summary>**What stopped the machine's check or the activation**, on the activation's page: one line or none over Try
    /// again. Null while they run by themselves, and on every other page.</summary>
    public ActivationStop? Activation { get; init; }
    /// <summary>The owner's store can send a write now (<see cref="ManagerSetupSettings.CanWrite"/>).</summary>
    public bool CanWrite { get; init; } = true;
    /// <summary>The servers of the fleet that a manager with no server can take now (<see cref="AgentSetupFlow.IsFree"/>), by
    /// their names; none for an agent that has its server.</summary>
    public IReadOnlyList<string> Free { get; init; } = [];
    /// <summary>The server's page as the setup makes a server there (<see cref="ManagerSetup.Server"/>), or null.</summary>
    public AgentServerView? NewServer { get; init; }
}

/// <summary>**The setup of one agent in the window** (windows-app-plan-v2.md, pieces U3 and L4b; the Mac's
/// <c>AgentSetupWizard</c>): the first setup of the manager of a new fleet, with the mark that this PC keeps of it, and
/// with <see cref="ForAgent"/> the setup of any other agent that the hub shows in setup (one that a team card added, one
/// that the owner deactivated) or signed out. <see cref="AgentSetupModel"/> read every two seconds while something goes on
/// and every five otherwise, what runs by itself after each read (the manager's server and its provider in one command
/// once both are there, the machine's check and the activation of an agent that is not active, the owner's store read
/// again while its session starts), and the end: the manager runs, or the agent's chat takes the place of its setup. The
/// window draws <see cref="ManagerSetupScreens"/> of <see cref="View"/> and calls the presses: a provider's card, Claude
/// Code's code, the provider's page that it opened, Try again of a stopped activation, and on the server's page of a
/// manager a server of the fleet (<see cref="TakeServerAsync"/>) or a new one (<see cref="Server"/>). Nothing here draws or
/// opens a page.
///
/// The name's page of a hub whose first run did not ask is here (piece U3b): its field and Continue, which renames the
/// manager on the hub (<see cref="TakeNameAsync"/>).
///
/// Not here (U3b's Server step and L6, and wave C): the drawing of the server's page, the slider's page and its root
/// step on the hub's own server, and a change of provider. Their pages draw their frame alone, and do not take the
/// window (<see cref="ManagerSetupScreens.TakesWindow"/>).</summary>
public sealed class ManagerSetup
{
    private readonly ManagerSetupSettings settings;
    private readonly AgentSetupModel model;
    /// <summary>The first setup of the manager of a new fleet: the mark is kept, and only it is written or taken away.</summary>
    private readonly bool firstSetup;
    private readonly object gate = new();
    /// <summary>One read or press of the model at a time, as the Mac's view runs them on one actor: a press that comes
    /// while a read runs goes after it.</summary>
    private readonly SemaphoreSlim turn = new(1, 1);
    private ManagerSetupView view;
    /// <summary>The command that gives a manager with no server its server and its provider went on this visit (the Mac's
    /// <c>placeAsked</c>, a state of its view): a new visit of the page (<see cref="Visit"/>) and a command that a cancel
    /// ended take it away.</summary>
    private bool placeAsked;
    /// <summary>The server's page asked for the first run's server on this visit (<see cref="AgentServerStep"/>).</summary>
    private bool serverOpened;
    private bool busy, ended, shareStopped;
    /// <summary>The name's page: the words in its field, and a rename that is on its way (the page stays the name's, with
    /// Continue off, until the press ends: the Mac's <c>renaming</c>), and the words of a rename that the hub refused or
    /// did not answer.</summary>
    private string typedName;
    private bool renaming;
    private string? nameRefusal;
    /// <summary>The hub's features at the first read of this visit (the Mac's <c>startFeatures</c>).</summary>
    private IReadOnlyList<string>? startFeatures;
    private int unreadReads, shareReads;

    /// <summary>**The hubs and generations where the owner went on from the name's page, on this run of the app** (the
    /// Mac's <c>FleetStore.namedManagers</c>): the provider's page is next there, until the hub keeps a step. One set for
    /// the app, because the setup of the new name is another setup.</summary>
    private static readonly HashSet<string> NamedOn = [];
    private string NamedKey => Mark.Hub.GetLeftPart(UriPartial.Authority) + "|" + Mark.Db;

    /// <summary>The owner went on from the name's page of this hub and generation, on this run of the app.</summary>
    private bool Named { get { lock (NamedOn) return NamedOn.Contains(NamedKey); } }

    private void NoteNamed()
    {
        lock (NamedOn) NamedOn.Add(NamedKey);
    }

    /// <summary>**Back on the provider's page** (the Mac's <c>SetupBack</c> there, and Esc): the name's page again, with no
    /// orange line, by the note that he named the manager taken away (the Mac's <c>noteManagerNamed(false)</c>). Nothing
    /// while the page shows no Back (<see cref="ManagerSetupScreen.Back"/>).</summary>
    public void BackToName()
    {
        lock (gate)
        {
            if (!ManagerSetupScreens.Of(view).Back) return;
            nameRefusal = null;
            model.ForgetRefusal();
        }
        lock (NamedOn) NamedOn.Remove(NamedKey);
        Publish();
    }
    private AgentPage? shownPage;
    private (long Job, int? Furthest) bar = (-1, null);

    /// <summary>The reads with no list of the hub's servers after which the page says so (the Mac's <c>unreadReadsMost</c>).</summary>
    public const int UnreadReadsMost = 8;

    /// <summary>The reads that wait for the hub's reading of its own server, with "1 server" kept, after which the wait
    /// stops with its words (the Mac's <c>HubShareModel.readsMost</c>).</summary>
    public const int ShareReadsMost = 45;

    /// <summary>Called after each change of <see cref="View"/>, on no thread in particular.</summary>
    public event EventHandler<ManagerSetupView>? Changed;

    /// <summary>The agent of this setup, its hub and that hub's generation; for the manager's first setup the mark that this
    /// PC keeps. The mark of another agent is kept nowhere.</summary>
    public ManagerSetupMark Mark { get; private set; }

    /// <summary>**The server's page makes a new server here** (piece L4b): null for an agent that is not the manager of a new
    /// fleet, whose server was chosen when it was added, and on a build that makes none.</summary>
    public AgentServerStep? Server { get; }

    /// <summary>The first setup of the manager of a new fleet.</summary>
    public ManagerSetup(ManagerSetupSettings settings, ManagerSetupMark mark) : this(settings, mark, firstSetup: true) { }

    /// <summary>**The setup of an agent that is not the manager of a new fleet** (piece L4b): from the hub's own readings,
    /// with no mark, no server's page and no steps on Back's line; it ends when its chat takes its place.</summary>
    public static ManagerSetup ForAgent(ManagerSetupSettings settings, Uri hub, string db, string agent) =>
        new(settings, new ManagerSetupMark(hub, db, agent), firstSetup: false);

    private ManagerSetup(ManagerSetupSettings settings, ManagerSetupMark mark, bool firstSetup)
    {
        this.settings = settings;
        this.firstSetup = firstSetup;
        Mark = mark;
        model = new AgentSetupModel(settings.Calls, mark.Agent, placing: firstSetup) { Provider = mark.Provider, Joined = mark.Joined };
        // The name's field opens on the manager's own name with capitals, never on its role, which is no name; and on the
        // suggestion when it has the hub's default (the Mac's typedName).
        typedName = mark.Agent == Install.ManagerName.Fallback ? Install.ManagerName.Suggested : AgentBook.Capitalized(mark.Agent);
        var fleet = settings.Fleet();
        var role = fleet?.Agents.FirstOrDefault(a => a.Name == mark.Agent)?.Role;
        view = new ManagerSetupView
        {
            Agent = mark.Agent,
            Label = AgentBook.Of(fleet).Label(mark.Agent),
            FirstSetup = firstSetup,
            Shows = firstSetup,
            FirstStep = !firstSetup || role != "manager" ? null
                : (mark.Joined ?? mark.Provider) is not null ? (int)ManagerSetupStep.Servers : (int)ManagerSetupStep.SignIn,
        };
        if (firstSetup && settings.Server is { } parts)
        {
            Server = new AgentServerStep(parts, settings.Calls, settings.Choices, mark.Hub, GiveAsync, SameHub, NoteJoined);
            Server.Changed += () => Publish();
            view = view with { NewServer = Server.Now };
        }
    }

    public ManagerSetupView View { get { lock (gate) return view; } }

    /// <summary>**The page shows again: a new visit** (the Mac's view, whose states start again when it opens): the command
    /// that gives the manager its server and its provider may go again by itself, a refusal and the words of a stop are
    /// gone, no code is on its way, no sign-in is asked, and the server's page is on its first page; the reads go on from
    /// what the setup read last.</summary>
    public void Visit()
    {
        lock (gate)
        {
            placeAsked = false;
            serverOpened = false;
            unreadReads = 0;
            nameRefusal = null;
            startFeatures = null;
            model.NewVisit();
        }
        Server?.NewVisit();
        Publish();
    }

    /// <summary>**Claude Code's code can go now**: its sign-in waits for one, none is on its way, and no press of this setup
    /// runs. While it cannot, a pasted code stays in its field (the Mac's <c>send</c>, which returns before it clears it).</summary>
    public bool TakesCode
    {
        get
        {
            lock (gate)
                return !busy && model.Reading?.Machine(Mark.Agent)?.Login is { WaitsForCode: true } login && !login.CodeOnItsWay(model.SentFrom);
        }
    }

    /// <summary>**Try again of a wait for the hub's own server that stopped**: the reads count again from none (the Mac's
    /// Continue of the slider keeps the step and starts the wait again; the slider and the root step on the hub's server
    /// are wave B's, so this press starts only the wait).</summary>
    public void ShareAgain()
    {
        lock (gate) { shareReads = 0; shareStopped = false; }
        Publish();
    }

    /// <summary>**The setup while the window shows it** (the Mac's <c>poll</c>): one read and what follows it by itself,
    /// then a pause of two seconds while something goes on, else five, until the manager runs or the window leaves. A read
    /// or a step that fails is tried again at the next turn, as the Mac's <c>try?</c> does: only the window's leave ends
    /// the reads (the read of U3: one error ended them for good, and the page stood still).</summary>
    public async Task RunAsync(CancellationToken cancel)
    {
        while (!cancel.IsCancellationRequested && !View.Ended)
        {
            try
            {
                await StepAsync(cancel).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { return; }
            catch (Exception e) when (e is not OutOfMemoryException) { }
            if (View.Ended) return;
            try
            {
                await settings.Pause(TimeSpan.FromSeconds(Quick ? 2 : 5), cancel).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>Something goes on that the page is about: an install, a sign-in, the wait for the session.</summary>
    private bool Quick
    {
        get
        {
            var v = View;
            var job = Job(v.Reading);
            return job?.IsOpen == true || v.Reading?.Machine(v.Agent)?.Login?.IsOpen == true ||
                   v.Page?.Kind is AgentSetupPage.Activate or AgentSetupPage.Servers;
        }
    }

    /// <summary>**One read, and what runs by itself after it** (the Mac's <c>read</c> and <c>follow</c>).</summary>
    public async Task StepAsync(CancellationToken cancel = default)
    {
        await turn.WaitAsync(cancel).ConfigureAwait(false);
        try
        {
            if (!await ReadAsync(cancel).ConfigureAwait(false)) return;
            await FollowAsync(cancel).ConfigureAwait(false);
        }
        finally { turn.Release(); }
    }

    /// <summary>Reads the servers and the machines while the owner's store holds a current reading of this generation of
    /// the hub (the Mac's <c>store.isFresh</c>, <see cref="ManagerSetupSettings.Fresh"/>): false with none, and nothing
    /// changes or counts.</summary>
    private async Task<bool> ReadAsync(CancellationToken cancel)
    {
        if (settings.Fresh?.Invoke() == false || settings.Fleet() is not { } fleet || fleet.Db != Mark.Db) return false;
        await model.ReadAsync(fleet, cancel).ConfigureAwait(false);
        lock (gate) startFeatures ??= model.Reading?.Features;
        Publish(answered: true);
        return true;
    }

    /// <summary>**What runs by itself after each read** (the Mac's <c>follow</c>): the count of reads with no list of the
    /// servers; for a manager with no server whose provider the owner chose and whose server is there now, the command
    /// that gives both, once on this visit; for an agent that is not active and that its machine reports signed in, the
    /// machine's check and the activation; on the server's page, the install of the first run's server that did not join;
    /// the owner's store read again while the page waits for the agent's session; and the end of the setup.</summary>
    private async Task FollowAsync(CancellationToken cancel)
    {
        if (model.Reading is not { } reading || Busy) return;
        var start = model.Start(reading, named: Named);
        if (start is ManagerSetupStart.Sharing sharing)
        {
            // "1 server" is kept and the page waits for the hub's reading of its own server's service: a count of reads
            // ends that wait with its words (the Mac's `share.countRead`). It is a read and no write. With a root step to
            // make (no server service on the hub's server), the slider is the page, and nothing counts.
            if (!sharing.RootStep)
                lock (gate)
                    if (!shareStopped && ++shareReads > ShareReadsMost) shareStopped = true;
            Publish();
            return;
        }
        lock (gate) { shareReads = 0; shareStopped = false; }
        if (Unread(reading))
        {
            lock (gate) unreadReads++;
            Publish();
            return;
        }
        lock (gate) unreadReads = 0;
        if (reading.Agent is { Placed: false } && !placeAsked && !model.PlaceRefused && model.Provider is not null &&
            model.PlaceOn(reading, start) is not null)
        {
            if (!Begin()) return;
            try
            {
                placeAsked = true;
                await model.PlaceChosenAsync(reading, named: Named, cancel).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // The page left while the command ran: it may not have reached the hub, so the next visit's read sends it
                // again if the manager still has no server.
                lock (gate) placeAsked = false;
                throw;
            }
            finally { End(); }
            await ReadAsync(cancel).ConfigureAwait(false);
            return;
        }
        if (View.Page is { } page && model.ActivationDue(reading, page))
        {
            // The machine's check, and the activation once it passed, by themselves (the Mac's `follow`).
            if (!Begin()) return;
            try { await model.FollowActivationAsync(reading, page, cancel).ConfigureAwait(false); }
            finally { End(); }
            if (model.Activated && settings.Refresh is { } reread) await reread().ConfigureAwait(false);
            await ReadAsync(cancel).ConfigureAwait(false);
            return;
        }
        if (View.Page?.Kind == AgentSetupPage.Server && Server is { } step && reading.Servers is { } list && !serverOpened)
        {
            // Once for each opening of the page, with the first list that it read (the Mac's `installFirst` and `firstTried`):
            // only the server that the first run made, which the mark keeps until its join ended well.
            serverOpened = true;
            if (Mark.Made is { } first) await step.OpenedAsync(first, Mark.Agent, list, NoteTried, cancel).ConfigureAwait(false);
        }
        if (View.Page?.Kind == AgentSetupPage.Activate && settings.Refresh is { } refresh) await refresh().ConfigureAwait(false);
        if (Over(reading))
        {
            // The manager runs: the mark goes, and the window shows its chat (the Mac's `notePlacing`).
            if (firstSetup && ManagerSetupMark.Read(settings.Choices) == Mark) ManagerSetupMark.Forget(settings.Choices);
            lock (gate) ended = true;
            Publish();
        }
    }

    /// <summary>**The end of this setup**, on a reading that answered: the manager of a new fleet runs; any other agent is
    /// active and its machine does not report it signed out, so that its chat takes its setup's place (the Mac's
    /// <c>addingEnds</c>), or the hub lists it no more. With no reading of the machines yet, nothing says that it is
    /// signed in.</summary>
    private bool Over(AgentReading reading) =>
        firstSetup ? reading.Agent is { } manager && AgentSetupFlow.Runs(manager)
                   : reading.Agent is null || (reading.Machines is not null || !reading.Features.Contains("machines")) &&
                     AgentSetupFlow.AddingEnds(reading.Agent, reading.Features);

    // ---------------------------------------------------------------- the presses

    /// <summary>**A press on a provider's card** (the Mac's <c>choose</c>): for a manager with no server, the provider is
    /// kept until its server is there, and the command that gives both goes at once when the server is there already; for
    /// one on its server, the install again after a failed install, or its sign-in. A refusal is the page's orange line.</summary>
    public async Task ChooseAsync(string provider, CancellationToken cancel = default)
    {
        if (!Begin()) return;
        try
        {
            await turn.WaitAsync(cancel).ConfigureAwait(false);
            try
            {
                if (model.Reading is not { } reading || !model.Cards(reading).Contains(provider)) return;
                if (firstSetup && reading.Agent?.Placed == false)
                {
                    Mark = Mark with { Provider = provider };
                    if (ManagerSetupMark.Read(settings.Choices)?.IsOf(Mark.Hub, Mark.Db) == true) Mark.Keep(settings.Choices);
                    if (model.PlaceOn(reading, model.Start(reading, named: Named)) is not null) placeAsked = true;
                }
                await model.ChooseAsync(reading, provider, named: Named, cancel).ConfigureAwait(false);
                await ReadAsync(cancel).ConfigureAwait(false);
            }
            finally { turn.Release(); }
        }
        catch (OperationCanceledException) { }
        finally { End(); }
    }

    /// <summary>The words in the name's field, as he types them.</summary>
    public void TypeName(string typed)
    {
        lock (gate) typedName = typed;
        Publish();
    }

    /// <summary>**Continue of "Name your manager"** (the Mac's <c>takeName</c>): a press of <see cref="ManagerRename"/>, against
    /// the team that the hub gives at the press, and only while the store holds the mark's hub and generation. The page
    /// stays the name's until the press ends, with Continue off, and a reading that has the new name then moves the mark
    /// (<see cref="ManagerSetupMark.TakeRename"/>) and the window to the setup of that name. The rename is noted before it
    /// goes (<see cref="ManagerSetupMark.NoteRename"/>), so an answer that is lost, or a press after one, still finds the
    /// manager in the team: nothing takes the note away but the reading of the manager's other name. A refusal says only
    /// that its own command renamed nothing. The hub's words of a refusal, or this app's of no answer, are the page's
    /// orange line. Nothing goes for words that the installer does not take, or with no current reading of this hub's
    /// generation.</summary>
    public async Task TakeNameAsync(CancellationToken cancel = default)
    {
        string typed;
        lock (gate) typed = typedName;
        if (Install.ManagerName.AgentName(typed) is not { } wanted || !Begin()) return;
        try
        {
            await turn.WaitAsync(cancel).ConfigureAwait(false);
            try
            {
                lock (gate) nameRefusal = null;
                if (settings.Fresh?.Invoke() == false || !OfThisGeneration()) return;
                if (wanted == Mark.Agent && !ManagerSetupMark.RenameNoted(Mark.Hub, Mark.Db, Mark.Agent))
                {
                    // He goes on with the name that it has, and no rename of an earlier press waits: nothing to ask the hub.
                    NoteNamed();
                    return;
                }
                // Continue is held for the press only (the Mac's `defer { renaming = false }`): its refresh is part of it.
                lock (gate) renaming = true;
                Publish();
                try
                {
                    var outcome = await ManagerRename.PressAsync(Mark.Agent, wanted, async () =>
                    {
                        // The hub and generation of the press, before each call (the Mac's guard of store.hub and its db): a
                        // store that went to another one, or a call that it answered with nothing, gets no rename.
                        var read = await OwnerReads.TeamAsync(settings.Calls, cancel).ConfigureAwait(false);
                        return read.Value is { } team && OfThisGeneration()
                            ? new ManagerRename.Team(team.Lines.Select(l => l.Agent).ToArray(), team.Manager?.Agent, team.Sha256)
                            : null;
                    }, async sha256 =>
                    {
                        // **The note goes before the rename** (the Mac's noteRename before nameManager): an answer that is lost
                        // after the hub renamed still finds the manager at the next reading (ManagerSetupMark.TakeRename).
                        ManagerSetupMark.NoteRename(Mark.Hub, Mark.Db, Mark.Agent);
                        var answer = await OwnerReads.RenameAsync(settings.Calls, Mark.Agent, sha256, wanted, cancel: cancel).ConfigureAwait(false);
                        return answer.Value is not null && OfThisGeneration();
                    }, cancel).ConfigureAwait(false);
                    switch (outcome)
                    {
                        case ManagerRename.Outcome.Keep:
                            NoteNamed();
                            break;
                        case ManagerRename.Outcome.Named:
                            // The next reading has the new name: the mark goes to it then, and the setup of that name takes
                            // this one's place (the Mac's renaming).
                            NoteNamed();
                            await RefreshAsync().ConfigureAwait(false);
                            break;
                        case ManagerRename.Outcome.Renamed renamed:
                            // The hub has another name already, of a press before this one or of another device: it is noted,
                            // nothing goes, and the reading says the name. A third name's own page shows again then.
                            ManagerSetupMark.NoteRename(Mark.Hub, Mark.Db, Mark.Agent);
                            if (renamed.Now == wanted) NoteNamed();
                            await RefreshAsync().ConfigureAwait(false);
                            break;
                        case ManagerRename.Outcome.Refused refused:
                            // The hub refused this command. The rename of an earlier press can have been made all the same:
                            // the note stays, and a reading says which name it is.
                            if (!OfThisGeneration()) break;
                            lock (gate) nameRefusal = refused.Refusal.HubWords ?? refused.Refusal.Message;
                            await RefreshAsync().ConfigureAwait(false);
                            break;
                        case ManagerRename.Outcome.Unanswered:
                            // The hub can have the new name. The next reading says which name it is, and the page goes with it.
                            if (!OfThisGeneration()) break;
                            lock (gate) nameRefusal = AgentSetupModel.NoAnswer;
                            await RefreshAsync().ConfigureAwait(false);
                            break;
                    }
                }
                finally { lock (gate) renaming = false; }
            }
            finally { turn.Release(); }
        }
        catch (OperationCanceledException) { lock (gate) renaming = false; }
        finally { End(); }
    }

    private async Task RefreshAsync()
    {
        if (settings.Refresh is { } refresh) await refresh().ConfigureAwait(false);
    }

    /// <summary>The owner's store holds a reading of this setup's hub and generation, and the calls go to them.</summary>
    private bool OfThisGeneration() =>
        settings.Fleet()?.Db == Mark.Db && settings.Calls.Database == Mark.Db && (settings.Hub?.Invoke() is not { } hub || Mark.IsOf(hub));

    /// <summary>**Claude Code's code, to the machine, and then forgotten here** (the Mac's <c>send</c>): only while the
    /// sign-in waits for it and no code is on its way. False when it did not go.</summary>
    public async Task<bool> SendCodeAsync(string code, CancellationToken cancel = default)
    {
        if (!Begin()) return false;
        try
        {
            await turn.WaitAsync(cancel).ConfigureAwait(false);
            try
            {
                if (model.Reading is not { } reading) return false;
                var sent = await model.SendCodeAsync(reading, code, cancel).ConfigureAwait(false);
                await ReadAsync(cancel).ConfigureAwait(false);
                return sent;
            }
            finally { turn.Release(); }
        }
        catch (OperationCanceledException) { return false; }
        finally { End(); }
    }

    /// <summary>**Try again of a stop on the activation's page** (the Mac's <c>tryAgain</c>): the check and the activation run
    /// again by themselves, from a new read.</summary>
    public async Task TryAgainAsync(CancellationToken cancel = default)
    {
        try
        {
            await turn.WaitAsync(cancel).ConfigureAwait(false);
            try { lock (gate) model.TryAgain(); }
            finally { turn.Release(); }
            Publish();
            await StepAsync(cancel).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>**A server of the fleet for a manager with no server** (the Mac's <c>placing.place</c>): one that is free
    /// (<see cref="ManagerSetupView.Free"/>), and the one that joined for it here (<see cref="Server"/>'s hand-over). The
    /// hub's list is read again first: a server that left the fleet, that is the hub's own, or that another agent took
    /// meanwhile is not given, and nothing of it is kept. Once given, the command that gives the manager its server and
    /// its provider goes by itself, as for the server that joined in the first run. False when it was not given.</summary>
    public async Task<bool> TakeServerAsync(string server, CancellationToken cancel = default)
    {
        if (!firstSetup || !Begin()) return false;
        bool given;
        try
        {
            await turn.WaitAsync(cancel).ConfigureAwait(false);
            try { given = (await TakeAsync(server, cancel).ConfigureAwait(false)).Given; }
            finally { turn.Release(); }
        }
        catch (OperationCanceledException) { return false; }
        finally { End(); }
        try { await StepAsync(cancel).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        return given;
    }

    /// <summary>The hand-over of a server that joined for the manager on this PC, from the server's page itself (<see
    /// cref="AgentServerStep"/>): taken as <see cref="TakeServerAsync"/> takes it, also while a press is on its way, and the
    /// read and the command follow at once. One that it did not take stays the manager's (<see cref="KeepJoined"/>).</summary>
    private async Task<bool> GiveAsync(string server, CancellationToken cancel)
    {
        (bool Given, ServerList? List) taken;
        await turn.WaitAsync(cancel).ConfigureAwait(false);
        try
        {
            taken = await TakeAsync(server, cancel).ConfigureAwait(false);
            if (!taken.Given) KeepJoined(server, taken.List);
        }
        finally { turn.Release(); }
        if (taken.Given) await StepAsync(cancel).ConfigureAwait(false);
        return taken.Given;
    }

    /// <summary>**A server that joined here and that the hand-over did not give stays the manager's server to take** (the
    /// Mac's <c>handOver</c>, which notes it in all cases): the hub may list it only after the hand-over's reads, and the
    /// setup's own rule checks it again at each read and at each start (<see cref="AgentSetupModel.PlaceOn"/>). Only a
    /// server that the hub lists with another agent leaves the setup and its mark.</summary>
    private void KeepJoined(string server, ServerList? list)
    {
        var taken = list?.Servers.FirstOrDefault(s => s.Name == server) is { } row && row.Agents.Any(a => a != Mark.Agent);
        lock (gate)
        {
            if (taken && model.Joined == server) model.Joined = null;
            if (!taken) model.Joined = server;
            Mark = Mark with { Joined = model.Joined };
        }
        if (ManagerSetupMark.Read(settings.Choices)?.IsOf(Mark.Hub, Mark.Db) == true) Mark.Keep(settings.Choices);
    }

    /// <summary>The owner's store is still on the hub and the generation of this setup.</summary>
    private bool SameHub() =>
        settings.Calls.Database == Mark.Db && (settings.Hub?.Invoke() is not { } now || Mark.IsOf(now));

    /// <summary>**The server that joined for the manager on this PC, in its mark, at the join's end**: a start of the app
    /// before the hand-over still gives it to the manager, which the setup's own rule then checks (<see
    /// cref="AgentSetupModel.PlaceOn"/>). The command waits for the hand-over in this run of the app. **The first run's
    /// server leaves the mark here, at the end of a join that ended well** (<see cref="ManagerSetupMark.Made"/>), and never
    /// at its start: a join that stopped keeps it, with its stop for Try again.</summary>
    private void NoteJoined(string server)
    {
        lock (gate)
            Mark = Mark with
            {
                Joined = server,
                Made = string.Equals(Mark.Made?.Name, server, StringComparison.OrdinalIgnoreCase) ? null : Mark.Made,
            };
        if (ManagerSetupMark.Read(settings.Choices)?.IsOf(Mark.Hub, Mark.Db) == true) Mark.Keep(settings.Choices);
    }

    /// <summary>**The page's own join by itself of the first run's server has started** (<see cref="FirstRunServer.Tried"/>):
    /// from now on, a stop of it waits for Try again at each opening of the page and after a start of the app.</summary>
    private void NoteTried()
    {
        lock (gate) Mark = Mark with { Made = Mark.Made is { } made ? made with { Tried = true } : null };
        if (ManagerSetupMark.Read(settings.Choices)?.IsOf(Mark.Hub, Mark.Db) == true) Mark.Keep(settings.Choices);
    }

    /// <summary>The hub's list read again, and the server given when it still takes the manager first; the list that was
    /// read, or null when the hub did not give one.</summary>
    private async Task<(bool Given, ServerList? List)> TakeAsync(string server, CancellationToken cancel)
    {
        ServerList? list;
        try { list = (await OwnerReads.ServersAsync(settings.Calls, cancel).ConfigureAwait(false)).Value; }
        catch (Exception e) when (e is HubException or InvalidOperationException or System.Text.Json.JsonException) { list = null; }
        if (list is null || list.Db != Mark.Db) return (false, null);
        if (!list.TakesFirst(Mark.Agent, server)) return (false, list);
        lock (gate)
        {
            model.Joined = server;
            Mark = Mark with { Joined = server };
        }
        if (ManagerSetupMark.Read(settings.Choices)?.IsOf(Mark.Hub, Mark.Db) == true) Mark.Keep(settings.Choices);
        return (true, list);
    }

    /// <summary>**The provider's page to open by itself now**, once (the Mac's <c>.task(id:)</c> of the sign-in page): only
    /// for a sign-in that was asked for on this visit, by the owner's press on a provider's card or by the command that
    /// gave the manager the server and the provider that he chose (the Mac's <c>placeChosen</c>: "its install ends in his
    /// sign-in"), and only a link of the provider's own hosts (<see cref="SignInPage.Link"/>), with the code to copy for
    /// its page; null for none. The model then holds it open.</summary>
    public (Uri Link, string? Code)? TakeOpening()
    {
        lock (gate)
        {
            if (view.SignIn is not { Link: { } link } page || !model.OpensByItself(page)) return null;
            model.OpenedSignIn();
            return (link, page.ShownCode);
        }
    }

    /// <summary>The owner opened the provider's page by the first step's link: a press asks for nothing more.</summary>
    public void Opened()
    {
        lock (gate) model.OpenedSignIn();
    }

    private bool Busy { get { lock (gate) return busy; } }

    private bool Begin()
    {
        lock (gate)
        {
            if (busy) return false;
            busy = true;
        }
        Publish();
        return true;
    }

    private void End()
    {
        lock (gate) busy = false;
        Publish();
    }

    // ---------------------------------------------------------------- the view

    /// <summary>**No list of the hub's servers has answered yet, while the hub offers it** (the Mac's
    /// <c>ManagerSetupStart.unread</c>): the page waits under "Setting up", and after <see cref="UnreadReadsMost"/> such reads
    /// says so. Without a list, a manager would read as placed (<see cref="SetupAgent.Of"/>), and its setup would show the
    /// provider's page of an agent that runs.</summary>
    private bool Unread(AgentReading reading) =>
        firstSetup && reading.Features.Contains("servers") && reading.Servers is null || model.Start(reading, named: Named) is ManagerSetupStart.Unread;

    private ServerJob? Job(AgentReading? reading) =>
        reading is null ? null : AgentSetupFlow.Job(Mark.Agent, reading.Server(Mark.Agent),
                                                    active: reading.Agent?.Active == true && !model.Placing(reading));

    private void Publish(bool answered = false)
    {
        ManagerSetupView now;
        lock (gate)
        {
            var reading = model.Reading;
            var unread = reading is not null && Unread(reading);
            var page = reading is null ? null : unread ? AgentPage.Of(AgentSetupPage.Servers) : model.Page(reading, named: Named, renaming: renaming);
            // The name's orange line stays on the name's page only (the Mac's refusal, cleared when the page changes).
            if (page is not null && page.Kind != AgentSetupPage.Name) nameRefusal = null;
            if (page is not null && page != shownPage)
            {
                if (shownPage is not null) model.PageChanged(page);
                shownPage = page;
            }
            var job = Job(reading);
            var machine = reading?.Machine(Mark.Agent);
            var runtime = reading?.Agent?.Runtime ?? "codex";
            var start = reading is null ? null : unread ? new ManagerSetupStart.Unread() : model.Start(reading, named: Named);
            string? placeOn = reading is null || start is null ? null : model.PlaceOn(reading, start);
            IReadOnlyList<string>? barSteps = null;
            int? barPart = null;
            if (page?.Kind == AgentSetupPage.Installing)
            {
                var onMac = (reading?.Server(Mark.Agent) ?? reading?.Servers?.Servers.FirstOrDefault(s => s.Name == placeOn))?.IsMac == true;
                if (AgentSetupFlow.InstallBar(job, onMac) is { } installBar)
                {
                    var id = job?.Id ?? 0;
                    if (bar.Job != id) bar = (id, null);
                    barPart = AgentSetupFlow.BarPart(installBar.Running, bar.Furthest);
                    bar = (id, barPart);
                    barSteps = installBar.Steps;
                    if (barPart is { } part && part >= barSteps.Count) barPart = null;
                }
            }
            var stopped = AgentSetupFlow.Stopped(runtime, job, machine);
            view = view with
            {
                Label = AgentBook.Of(settings.Fleet()).Label(Mark.Agent),
                Answered = view.Answered || answered,
                Reading = reading,
                Page = page,
                Start = start,
                Cards = reading is null ? [] : model.Cards(reading),
                Marked = reading?.Agent?.Placed == false ? model.Provider ?? runtime : runtime,
                Refusal = nameRefusal ?? model.Refusal,
                TypedName = typedName,
                StartFeatures = startFeatures,
                Stopped = stopped is null ? null : Lines(stopped),
                InstallFailed = job is { Kind: "install", State: "failed" },
                SignIn = page?.Kind == AgentSetupPage.SignIn && reading is not null ? model.SignInPage(reading, page.Runtime ?? runtime) : null,
                SigningInAgain = !firstSetup && reading is not null && model.SigningInAgain(reading),
                CanWrite = settings.CanWrite?.Invoke() != false,
                Activation = page?.Kind == AgentSetupPage.Activate && reading is not null && !model.SigningInAgain(reading) && !model.Placing(reading)
                    ? model.Activation(reading, busy)
                    : null,
                Free = reading is { Agent.Placed: false, Servers: { } servers } ? servers.Servers.Where(AgentSetupFlow.IsFree).Select(s => s.Name).ToList() : [],
                NewServer = Server?.Now,
                BarSteps = barSteps,
                BarPart = barPart,
                Server = reading?.Server(Mark.Agent)?.Name ?? machine?.Machine ?? placeOn ?? ManagerSetupScreens.ItsServer,
                Busy = busy,
                UnreadReads = unreadReads,
                ShareStopped = shareStopped,
                Shows = reading is null ? firstSetup : AgentSetupFlow.FillsWindow(reading.Agent, reading.Features, placing: firstSetup),
                TakesChat = reading is null || AgentSetupFlow.Shows(reading.Agent, reading.Features, placing: firstSetup),
                Ended = ended,
            };
            now = view;
        }
        Changed?.Invoke(this, now);
    }

    /// <summary>**What stopped, over why, in two short lines** (the Mac's <c>AgentSetupWizard.lines</c>): the hub writes
    /// "Codex did not install: vps-2 could not reach the internet." as one line, so its words are split where they say
    /// why.</summary>
    public static string Lines(string words)
    {
        var colon = words.IndexOf(": ", StringComparison.Ordinal);
        if (colon <= 0 || colon + 2 >= words.Length) return words;
        return words[..colon] + ".\n" + words[(colon + 2)..];
    }
}

/// <summary>**One page of the manager's setup, as the window draws it** (the Mac's <c>SetupStep</c> of
/// <c>AgentSetupWizard</c>): its name, its title (which moves while <c>Waits</c>), its muted line, its controls, its one
/// orange line, the steps on Back's line, and its mark: the provider's own logo (<c>Logo</c>, a provider's name), else
/// the manager's mark, at twice a step's size while it waits for the server (<c>Making</c>). <c>Drawn</c> is false for a
/// page that this build does not draw yet: it does not take the window (<see cref="ManagerSetupScreens.TakesWindow"/>).
/// <c>Back</c>: Back stands at the page's top left (<see cref="AgentServerStep.Back"/>).</summary>
public sealed record ManagerSetupScreen(string Name, string Title, bool Waits, string? Detail, IReadOnlyList<SetupControl> Controls,
                                        string? Warning, SetupProgress? Progress, string? Logo = null, bool Making = false, bool Drawn = true,
                                        bool Back = false);

/// <summary>**The pages of an agent's setup, from its view** (the Mac's <c>AgentSetupWizard</c>), each sentence the Mac's:
/// the provider's cards, the install with its bar, the sign-in with its steps over Claude Code's code field or Codex's
/// code, the moving "Setting up &lt;Agent&gt;" while it is checked and activated or until the manager runs, and "Activate
/// &lt;Agent&gt;" over what stopped that.</summary>
public static class ManagerSetupScreens
{
    public const string ItsServer = "its server";
    public const string Copy = "Copy", Copied = "Copied";
    public static string SettingUp(string name) => $"Setting up {name}";
    public static string SigningIn(string provider) => $"Signing in to {provider}";
    public static string Activate(string name) => $"Activate {name}";

    /// <summary>**The setup takes the window now**: it shows (<see cref="ManagerSetupView.Shows"/>), it has not ended, and
    /// this build draws its page. A page that the build draws as its frame alone (<see cref="ManagerSetupScreen.Drawn"/>
    /// false: the server's page and the fleet's servers with the root step, which wave B draws after L4b and L6) does not
    /// take it: the manager's page shows with the pane, so that every other page stays in reach (the read of U3, fault 2).</summary>
    public static bool TakesWindow(ManagerSetupView v) => v is { Shows: true, Ended: false } && Of(v).Drawn;

    public static ManagerSetupScreen Of(ManagerSetupView v)
    {
        var page = v.Page;
        // The steps on Back's line from the first frame, as the Mac draws them while its first read runs: before it, the
        // step that the first run's hand-over says comes next.
        var progress = page is null || !v.Answered
            ? v.FirstStep is { } first ? new SetupProgress(ManagerSetupSteps.Names, first) : null
            : v.FirstSetup && v.Reading?.Agent?.Role == "manager" ? new SetupProgress(ManagerSetupSteps.Names, ManagerSetupSteps.Current(page.Kind)) : null;
        if (!v.Answered || page is null) return SettingUpPage(v, progress);
        switch (page.Kind)
        {
            case AgentSetupPage.Name:
                return NamePage(v, progress);
            case AgentSetupPage.Servers:
                return v.Start switch
                {
                    ManagerSetupStart.Unread => SettingUpPage(v, progress) with
                    {
                        Warning = v.UnreadReads > ManagerSetup.UnreadReadsMost ? AgentSetupModel.CannotReadServer(v.Label) : null,
                    },
                    // The wait for the hub's own server stopped: the Mac's words of that stop under the still title, over
                    // Try again, which waits again (the Mac shows its slider there, with Continue: wave B's root step).
                    ManagerSetupStart.Sharing { RootStep: false } when v.ShareStopped => SettingUpPage(v, progress) with
                    {
                        Waits = false,
                        Warning = AgentSetupModel.NoAnswer,
                        Controls = [new SetupControl(SetupControlKind.Button, SetupScreens.TryAgain, "agent-setup-share-again")],
                    },
                    ManagerSetupStart.Sharing { RootStep: false } => SettingUpPage(v, progress),
                    _ => new("servers", SetupScreens.ServersTitle, false, null, [], null, progress, Drawn: false),
                };
            case AgentSetupPage.Server:
                return AgentServerScreens.Of(v, progress) with { Drawn = false };
            case AgentSetupPage.Provider:
                return Providers(v, progress);
            case AgentSetupPage.Installing:
            {
                var provider = page.Runtime ?? "codex";
                var controls = v.BarSteps is { } steps
                    ? [new SetupControl(SetupControlKind.Bar, "", "agent-setup-bar", v.BarPart?.ToString(CultureInfo.InvariantCulture), Lines: steps)]
                    : new List<SetupControl>();
                return new("installing", AgentSetupFlow.Installing(SignIn.ProviderName(provider), v.Server), true, null, controls, null, progress,
                           Logo: provider);
            }
            case AgentSetupPage.SignIn when v.SignIn is { } signIn:
            {
                var controls = new List<SetupControl>();
                if (signIn.Steps.Count > 0) controls.Add(new(SetupControlKind.Steps, "", "agent-setup-steps", Lines: signIn.Steps));
                if (signIn.AsksCode) controls.Add(new(SetupControlKind.Paste, SignInPage.CodePlaceholder, "agent-setup-paste"));
                else if (signIn.ShownCode is { } code && signIn.Link is not null) controls.Add(new(SetupControlKind.Code, code, "agent-setup-code"));
                return new("signIn", signIn.Title, signIn.Waits, null, controls, signIn.Refusal, progress, Logo: page.Runtime ?? "codex");
            }
            case AgentSetupPage.Activate when v.SigningInAgain:
            {
                // Active and signed in again: its last page until the reading that says so (the Mac's `.activate` with
                // `signingInAgain`).
                var runtime = v.Reading?.Agent?.Runtime ?? "codex";
                return new("signingIn", SigningIn(SignIn.ProviderName(runtime)), true, null, [], null, progress, Logo: runtime);
            }
            case AgentSetupPage.Activate when v.Activation is { } stop:
                // What stopped the check or the activation, in one orange line over Try again, which runs both again: only
                // while the owner's store can send a write (the Mac's `store.canWrite`).
                return new("activate", Activate(v.Label), false, null,
                           v.CanWrite ? [new SetupControl(SetupControlKind.Button, SetupScreens.TryAgain, "agent-setup-again")] : [],
                           stop.Why, progress);
            default:
                // Switching, the check and the activation, and the end of a manager that gets its first server: one
                // moving title until it runs.
                return SettingUpPage(v, progress);
        }
    }

    /// <summary>**"Name your manager"** of a hub whose first run did not ask (the Mac's <c>NameManagerPage</c> in its
    /// setup): the first run's words, the field with the typed words, which wears its orange edge for words that the
    /// installer does not take; Continue only for a name that it takes; and in orange the hub's words of a refused rename.</summary>
    private static ManagerSetupScreen NamePage(ManagerSetupView v, SetupProgress? progress)
    {
        var name = Install.ManagerName.AgentName(v.TypedName);
        var controls = new List<SetupControl>
        {
            new(SetupControlKind.Field, SetupScreens.NamePlaceholder, "agent-setup-name", v.TypedName, Marked: v.TypedName.Length > 0 && name is null),
        };
        if (name is not null) controls.Add(new(SetupControlKind.Button, SetupScreens.Continue, "agent-setup-name-continue"));
        return new("name", SetupScreens.NameTitle, false, SetupScreens.NameDetail, controls, v.Refusal, progress);
    }

    private static ManagerSetupScreen SettingUpPage(ManagerSetupView v, SetupProgress? progress) =>
        new("settingUp", SettingUp(v.Label), true, null, [], null, progress, Making: true);

    /// <summary>**"&lt;Agent&gt;'s AI provider"** (the Mac's <c>providers</c>): one line under the title in the manager's
    /// first setup; its cards, the check mark on the one chosen; under them in orange why the setup stopped the last time,
    /// and over a failed install Try again, which runs the same install again.</summary>
    private static ManagerSetupScreen Providers(ManagerSetupView v, SetupProgress? progress)
    {
        var controls = v.Cards.Select(p => new SetupControl(SetupControlKind.Card, SignIn.ProviderName(p), "agent-setup-provider-" + p,
                                                            Marked: p == v.Marked)).ToList();
        var why = v.Refusal ?? v.Stopped;
        if (why is not null && v.InstallFailed && !v.Busy) controls.Add(new(SetupControlKind.Button, SetupScreens.TryAgain, "agent-setup-install-again"));
        var detail = v.FirstSetup && v.Reading?.Agent?.Role == "manager" ? SetupScreens.AiDetail(v.Label) : null;
        return new("provider", SetupScreens.AiTitle(v.Label), false, detail, controls, why, progress, Back: GoesBackToName(v));
    }

    /// <summary>**Back on the provider's page goes to the name's page** (the Mac's <c>SetupBack</c> of
    /// <c>AgentSetupWizard</c>): for a manager with no server, of a hub that can rename it, whose setup starts on the fleet's
    /// servers (its name's page came first), while no press is on its way. "Name your manager" is the first page, with no
    /// Back.</summary>
    private static bool GoesBackToName(ManagerSetupView v) =>
        !v.Busy && v.Start is ManagerSetupStart.Servers && v.Reading is { Agent.Placed: false } &&
        v.StartFeatures?.Contains(FleetShapeHub.Rename) == true;
}
