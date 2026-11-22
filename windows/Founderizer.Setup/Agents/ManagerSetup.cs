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
/// that the owner chose for a manager with no server, and the server that joined for it; no key, token, code or address
/// of a server.</summary>
public sealed partial record ManagerSetupMark(Uri Hub, string Db, string Agent, string? Provider = null, string? Joined = null)
{
    /// <summary>The name of the mark among the first run's kept answers (<see cref="ISetupChoices"/>).</summary>
    public const string ChoiceName = "managerFirstSetup";

    /// <summary>One write of the mark at a time in this app: the first run, the reading's rule and the setup each write it
    /// from a thread of their own, and a read and the write that follows it must have no other write between them.</summary>
    private static readonly object Writes = new();

    /// <summary>The mark that this PC keeps, or null for none, or for one of no valid shape.</summary>
    public static ManagerSetupMark? Read(ISetupChoices choices)
    {
        if (choices.Get(ChoiceName)?.Split('|') is not [var hub, var db, var agent, var provider, var joined]) return null;
        Uri address;
        try { address = HubClient.Address(hub); }
        catch (HubException) { return null; }
        if (db.Length is 0 or > 200 || !AgentShape().IsMatch(agent) || provider is not ("" or "claude" or "codex") ||
            joined.Length > 0 && !ServerNames.IsMachine(joined))
            return null;
        return new ManagerSetupMark(address, db, agent, provider.Length == 0 ? null : provider, joined.Length == 0 ? null : joined);
    }

    /// <summary>Keeps this mark in place of the one before, the hub by its scheme, host and port alone; a mark with a "|"
    /// in a part, or a hub address that is not HTTP or HTTPS, is not kept. It never throws: the hand-over writes it.</summary>
    public void Keep(ISetupChoices choices)
    {
        if (Hub is not { IsAbsoluteUri: true, Scheme: "http" or "https" }) return;
        string[] parts = [Hub.GetLeftPart(UriPartial.Authority) + "/", Db, Agent, Provider ?? "", Joined ?? ""];
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
            if (Read(choices) is not { } kept || !kept.IsOf(Hub, Db) || (kept.Agent, kept.Provider, kept.Joined) != (Agent, Provider, Joined))
                Keep(choices);
    }

    public static void Forget(ISetupChoices choices)
    {
        lock (Writes) choices.Set(ChoiceName, null);
    }

    /// <summary>**The mark for which the window shows the manager's setup now**: the PC is the owner's computer of the hub
    /// of the mark, the store holds a reading of that generation, and that reading has the manager. Null otherwise.</summary>
    public static ManagerSetupMark? Shown(StoreState state, ISetupChoices choices) =>
        state.Role == HubRole.Owner && state.Fleet is { } fleet && Read(choices) is { } mark && mark.IsOf(state.Hub, fleet.Db) &&
        fleet.Agents.Any(a => a.Name == mark.Agent)
            ? mark
            : null;

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
        if (ManagerSetupMark.Read(choices)?.IsOf(hub, fleet.Db) == true) return;
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
}

/// <summary>**The manager's first setup as its pages read it**: an immutable value; each read and each press makes a new
/// one, and <see cref="ManagerSetup.Changed"/> says so.</summary>
public sealed record ManagerSetupView
{
    public required string Agent { get; init; }
    /// <summary>The manager as both apps name it: its role, else its name with capitals (the Mac's <c>agentLabel</c>).</summary>
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
    /// <summary>A press of this setup is on its way: no second one, and no Try again.</summary>
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
    /// mark alone).</summary>
    public bool Shows { get; init; } = true;
    /// <summary>The manager runs: the mark is gone, and the window shows its chat.</summary>
    public bool Ended { get; init; }
}

/// <summary>**The setup of the manager of a new fleet in the window** (windows-app-plan-v2.md, piece U3; the Mac's
/// <c>AgentSetupWizard</c> for the manager's first server): <see cref="AgentSetupModel"/> read every two seconds while
/// something goes on and every five otherwise, what runs by itself after each read (its server and its provider in one
/// command once both are there, the owner's store read again while the manager's session starts), and the end once the
/// manager runs. The window draws <see cref="ManagerSetupScreens"/> of <see cref="View"/> and calls the presses: a
/// provider's card, Claude Code's code, and the provider's page that it opened. Nothing here draws or opens a page.
///
/// Not here (wave B, piece L4b, and wave C): the server's page of a manager whose server did not join in the first run,
/// the slider's page and its root step on the hub's own server, the name's page of a hub whose first run did not ask,
/// the machine check and the activation of an agent that is not the manager of a new fleet, and a change of provider.
/// Their pages draw their frame alone, and do not take the window (<see cref="ManagerSetupScreens.TakesWindow"/>).</summary>
public sealed class ManagerSetup
{
    private readonly ManagerSetupSettings settings;
    private readonly AgentSetupModel model;
    private readonly object gate = new();
    /// <summary>One read or press of the model at a time, as the Mac's view runs them on one actor: a press that comes
    /// while a read runs goes after it.</summary>
    private readonly SemaphoreSlim turn = new(1, 1);
    private ManagerSetupView view;
    /// <summary>The command that gives a manager with no server its server and its provider went on this visit (the Mac's
    /// <c>placeAsked</c>, a state of its view): a new visit of the page (<see cref="Visit"/>) and a command that a cancel
    /// ended take it away.</summary>
    private bool placeAsked;
    private bool busy, ended, shareStopped;
    private int unreadReads, shareReads;
    private AgentPage? shownPage;
    private (long Job, int? Furthest) bar = (-1, null);

    /// <summary>The reads with no list of the hub's servers after which the page says so (the Mac's <c>unreadReadsMost</c>).</summary>
    public const int UnreadReadsMost = 8;

    /// <summary>The reads that wait for the hub's reading of its own server, with "1 server" kept, after which the wait
    /// stops with its words (the Mac's <c>HubShareModel.readsMost</c>).</summary>
    public const int ShareReadsMost = 45;

    /// <summary>Called after each change of <see cref="View"/>, on no thread in particular.</summary>
    public event EventHandler<ManagerSetupView>? Changed;

    public ManagerSetupMark Mark { get; private set; }

    public ManagerSetup(ManagerSetupSettings settings, ManagerSetupMark mark)
    {
        this.settings = settings;
        Mark = mark;
        model = new AgentSetupModel(settings.Calls, mark.Agent) { Provider = mark.Provider, Joined = mark.Joined };
        var fleet = settings.Fleet();
        var role = fleet?.Agents.FirstOrDefault(a => a.Name == mark.Agent)?.Role;
        view = new ManagerSetupView
        {
            Agent = mark.Agent,
            Label = AgentBook.Of(fleet).Label(mark.Agent),
            FirstStep = role != "manager" ? null
                : (mark.Joined ?? mark.Provider) is not null ? (int)ManagerSetupStep.Servers : (int)ManagerSetupStep.SignIn,
        };
    }

    public ManagerSetupView View { get { lock (gate) return view; } }

    /// <summary>**The page shows again: a new visit** (the Mac's view, whose states start again when it opens): the command
    /// that gives the manager its server and its provider may go again by itself, a refusal and the words of a stop are
    /// gone, no code is on its way, and no sign-in is asked; the reads go on from what the setup read last.</summary>
    public void Visit()
    {
        lock (gate)
        {
            placeAsked = false;
            unreadReads = 0;
            model.NewVisit();
        }
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
        Publish(answered: true);
        return true;
    }

    /// <summary>**What runs by itself after each read** (the Mac's <c>follow</c>): the count of reads with no list of the
    /// servers; for a manager with no server whose provider the owner chose and whose server is there now, the command
    /// that gives both, once on this visit; the owner's store read again while the page waits for the manager's session;
    /// and the end of the setup once the manager runs.</summary>
    private async Task FollowAsync(CancellationToken cancel)
    {
        if (model.Reading is not { } reading || Busy) return;
        var start = model.Start(reading, named: true);
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
                await model.PlaceChosenAsync(reading, named: true, cancel).ConfigureAwait(false);
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
        if (View.Page?.Kind == AgentSetupPage.Activate && settings.Refresh is { } refresh) await refresh().ConfigureAwait(false);
        if (reading.Agent is { } agent && AgentSetupFlow.Runs(agent))
        {
            // The manager runs: the mark goes, and the window shows its chat (the Mac's `notePlacing`).
            if (ManagerSetupMark.Read(settings.Choices) == Mark) ManagerSetupMark.Forget(settings.Choices);
            lock (gate) ended = true;
            Publish();
        }
    }

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
                if (reading.Agent?.Placed == false)
                {
                    Mark = Mark with { Provider = provider };
                    if (ManagerSetupMark.Read(settings.Choices)?.IsOf(Mark.Hub, Mark.Db) == true) Mark.Keep(settings.Choices);
                    if (model.PlaceOn(reading, model.Start(reading, named: true)) is not null) placeAsked = true;
                }
                await model.ChooseAsync(reading, provider, named: true, cancel).ConfigureAwait(false);
                await ReadAsync(cancel).ConfigureAwait(false);
            }
            finally { turn.Release(); }
        }
        catch (OperationCanceledException) { }
        finally { End(); }
    }

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
        reading.Features.Contains("servers") && reading.Servers is null || model.Start(reading, named: true) is ManagerSetupStart.Unread;

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
            var page = reading is null ? null : unread ? AgentPage.Of(AgentSetupPage.Servers) : model.Page(reading, named: true);
            if (page is not null && page != shownPage)
            {
                if (shownPage is not null) model.PageChanged(page);
                shownPage = page;
            }
            var job = Job(reading);
            var machine = reading?.Machine(Mark.Agent);
            var runtime = reading?.Agent?.Runtime ?? "codex";
            var start = reading is null ? null : unread ? new ManagerSetupStart.Unread() : model.Start(reading, named: true);
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
                Refusal = model.Refusal,
                Stopped = stopped is null ? null : Lines(stopped),
                InstallFailed = job is { Kind: "install", State: "failed" },
                SignIn = page?.Kind == AgentSetupPage.SignIn && reading is not null ? model.SignInPage(reading, page.Runtime ?? runtime) : null,
                BarSteps = barSteps,
                BarPart = barPart,
                Server = reading?.Server(Mark.Agent)?.Name ?? machine?.Machine ?? placeOn ?? ManagerSetupScreens.ItsServer,
                Busy = busy,
                UnreadReads = unreadReads,
                ShareStopped = shareStopped,
                Shows = reading is null || AgentSetupFlow.FillsWindow(reading.Agent, reading.Features, placing: true),
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
/// page that this build does not draw yet: it does not take the window (<see cref="ManagerSetupScreens.TakesWindow"/>).</summary>
public sealed record ManagerSetupScreen(string Name, string Title, bool Waits, string? Detail, IReadOnlyList<SetupControl> Controls,
                                        string? Warning, SetupProgress? Progress, string? Logo = null, bool Making = false, bool Drawn = true);

/// <summary>**The pages of the manager's first setup, from its view** (the Mac's <c>AgentSetupWizard</c>), each sentence the
/// Mac's: the provider's cards, the install with its bar, the sign-in with its steps over Claude Code's code field or
/// Codex's code, and the moving "Setting up &lt;Manager&gt;" until it runs.</summary>
public static class ManagerSetupScreens
{
    public const string ItsServer = "its server";
    public const string Copy = "Copy", Copied = "Copied";
    public static string SettingUp(string name) => $"Setting up {name}";

    /// <summary>**The setup takes the window now**: it shows (<see cref="ManagerSetupView.Shows"/>), it has not ended, and
    /// this build draws its page. A page that the build draws as its frame alone (<see cref="ManagerSetupScreen.Drawn"/>
    /// false: the server's page, the fleet's servers with the root step, the name's page, which piece U3b draws) does not
    /// take it: the manager's page shows with the pane, so that every other page stays in reach (the read of U3, fault 2).</summary>
    public static bool TakesWindow(ManagerSetupView v) => v is { Shows: true, Ended: false } && Of(v).Drawn;

    public static ManagerSetupScreen Of(ManagerSetupView v)
    {
        var page = v.Page;
        // The steps on Back's line from the first frame, as the Mac draws them while its first read runs: before it, the
        // step that the first run's hand-over says comes next.
        var progress = page is null || !v.Answered
            ? v.FirstStep is { } first ? new SetupProgress(ManagerSetupSteps.Names, first) : null
            : v.Reading?.Agent?.Role == "manager" ? new SetupProgress(ManagerSetupSteps.Names, ManagerSetupSteps.Current(page.Kind)) : null;
        if (!v.Answered || page is null) return SettingUpPage(v, progress);
        switch (page.Kind)
        {
            case AgentSetupPage.Name:
                return new("name", SetupScreens.NameTitle, false, null, [], null, progress, Drawn: false);
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
                return new("server", SetupScreens.ManagersServer(v.Label), false, null, [], null, progress, Drawn: false);
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
            default:
                // Switching, and the end of a manager that gets its first server: one moving title until it runs.
                return SettingUpPage(v, progress);
        }
    }

    private static ManagerSetupScreen SettingUpPage(ManagerSetupView v, SetupProgress? progress) =>
        new("settingUp", SettingUp(v.Label), true, null, [], null, progress, Making: true);

    /// <summary>**"&lt;Manager&gt;'s AI provider"** (the Mac's <c>providers</c>): one line under the title in the manager's
    /// first setup; its cards, the check mark on the one chosen; under them in orange why the setup stopped the last time,
    /// and over a failed install Try again, which runs the same install again.</summary>
    private static ManagerSetupScreen Providers(ManagerSetupView v, SetupProgress? progress)
    {
        var controls = v.Cards.Select(p => new SetupControl(SetupControlKind.Card, SignIn.ProviderName(p), "agent-setup-provider-" + p,
                                                            Marked: p == v.Marked)).ToList();
        var why = v.Refusal ?? v.Stopped;
        if (why is not null && v.InstallFailed && !v.Busy) controls.Add(new(SetupControlKind.Button, SetupScreens.TryAgain, "agent-setup-install-again"));
        return new("provider", SetupScreens.AiTitle(v.Label), false, SetupScreens.AiDetail(v.Label), controls, why, progress);
    }
}
