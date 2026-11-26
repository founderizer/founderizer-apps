using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Founderizer.Remote;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.Agents;

/// <summary>What the server's page of a manager with no server needs from the PC (the window gives each; a test gives
/// stand-ins). They are the first run's own parts (<see cref="SetupSettings"/>).</summary>
public sealed class AgentServerSettings
{
    public required ISecretBox Box { get; init; }
    /// <summary>SSH from the PC.</summary>
    public required IRemote Remote { get; init; }
    public required SetupRecords Records { get; init; }
    /// <summary>Tailscale's API with the fleet's key.</summary>
    public required IFleetNet Tailscale { get; init; }
    /// <summary>A provider.</summary>
    public required Func<CloudProvider, ICloud> Cloud { get; init; }
    /// <summary>This PC's <c>tailscale status --json</c>, or null with no Tailscale running.</summary>
    public required Func<CancellationToken, Task<string?>> Status { get; init; }
    public Func<DateTimeOffset> Now { get; init; } = () => DateTimeOffset.UtcNow;
    public Func<TimeSpan, CancellationToken, Task> Pause { get; init; } = Task.Delay;
    /// <summary>The clock of the join's installer (the system's, unless a test gives its own).</summary>
    public InstallerClock? JoinClock { get; init; }
    /// <summary>How many reads wait for the hub to offer the server that joined, and how long between two (the Mac's 40 and
    /// 3 s): a count ends the wait, and no clock.</summary>
    public int HandOverReads { get; init; } = 40;
    public TimeSpan HandOverEvery { get; init; } = TimeSpan.FromSeconds(3);
}

/// <summary>**The server's page as its window reads it**: an immutable value, with each change of <see
/// cref="AgentServerStep"/>.</summary>
public sealed record AgentServerView
{
    /// <summary>The owner chose the way "VPS" on the first page (the Mac's <c>.machine</c> page with <c>way == .linux</c>):
    /// the providers' cards show, under "A VPS for your agents". False on the first page, "&lt;Manager&gt;'s server".</summary>
    public bool ChoseVps { get; init; }
    /// <summary>The provider whose pages show (its token, the choice of the server, its build); null on the pages of the
    /// ways and of the providers' cards.</summary>
    public CloudProvider? Provider { get; init; }
    public required CloudStep.View Cloud { get; init; }
    /// <summary>The fleet's own Tailscale key is asked once before the provider's page (a PC whose box holds none, or whose
    /// key Tailscale ended).</summary>
    public bool AsksKey { get; init; }
    public KeyView Key { get; init; } = KeyView.Start;
    /// <summary>The hub is asked whether it answers, before a server is made.</summary>
    public bool AsksHub { get; init; }
    /// <summary>The join of the server to the fleet: its steps while it runs, its stop, its checks.</summary>
    public InstallView Install { get; init; } = InstallView.None;
    /// <summary>The server joined, and the step waits until the hub offers it.</summary>
    public bool HandsOver { get; init; }

    /// <summary>The provider makes the server, or it starts and comes on the private network.</summary>
    public bool Builds => Cloud.Stage is CloudStep.Stage.Making or CloudStep.Stage.Joining;

    /// <summary>**A build, a join or the hand-over runs: the page has no Back** (the Mac's rule: a Back there would leave a
    /// server at the provider and not in the fleet).</summary>
    public bool Runs => Builds || Install.Running || HandsOver || AsksHub;
}

/// <summary>**The server's page of a manager with no server, for a hub that exists** (windows-app-plan-v2.md, piece L4b; the
/// Mac's <c>AddServerView</c> with <c>placing</c>): a new server at a provider (<see cref="CloudStep"/>, for this hub), its
/// join to the fleet with the hub's one-time line, and the hand-over: as soon as the hub offers the server, it goes to the
/// manager's setup by itself. The server that the first run made for the manager and that did not join is installed by
/// itself, with no second server (the Mac's <c>installFirst</c>). One build, join or hand-over at a time; nothing here
/// draws.
///
/// Not here: Other VPS. Its check, the password once and the owner's key once are in <see cref="SetupStore"/> for the hub's
/// install alone; <see cref="Join"/> is the join of a server that such a check proved. Nor a server of the provider's own
/// list ("Use this server", wave C).</summary>
public sealed class AgentServerStep
{
    /// <summary>Where the owner's Tailscale policy is kept, among the kept answers (the first run's name).</summary>
    private const string PolicyChoice = "tailscalePolicyPlace";

    private readonly AgentServerSettings settings;
    private readonly OwnerReads.ICalls calls;
    private readonly ISetupChoices choices;
    private readonly string hub;
    private readonly Uri hubAddress;
    private readonly Func<string, CancellationToken, Task<bool>> give;
    private readonly Func<bool> sameHub;
    private readonly Action<string> note;
    private readonly CloudStep cloud;
    private readonly object gate = new();
    private AgentServerView view;
    private bool joins;
    /// <summary>The server of the newest join, for its Try again: its address, its name when this PC made it.</summary>
    private (InstallTarget Target, string? Name)? joined;
    /// <summary>The words of the newest join that stopped in this run, by its record: a later opening of the page shows them
    /// again, where a record keeps no line that the server printed.</summary>
    private (Guid Record, string Words)? stopWords;

    /// <summary>Called after each change of <see cref="Now"/>, on no thread in particular.</summary>
    public event Action? Changed;

    /// <summary><paramref name="give"/> gives a server by its name to the manager's setup, which reads the hub's list again
    /// first and takes no server that another agent has (<see cref="ManagerSetup.TakeServerAsync"/>); true when it took
    /// it. <paramref name="sameHub"/>: the owner's store is still on this hub and this generation of it, the one that the
    /// setup is for; a server that it did not take stays the manager's in its mark, unless the hub lists it with another
    /// agent. <paramref name="note"/> keeps the server that joined for the manager in its mark at the join's end, so that a
    /// start of the app between the join's end and the hand-over still gives it.</summary>
    internal AgentServerStep(AgentServerSettings settings, OwnerReads.ICalls calls, ISetupChoices choices, Uri hub,
                             Func<string, CancellationToken, Task<bool>> give, Func<bool> sameHub, Action<string> note)
    {
        this.settings = settings;
        this.calls = calls;
        this.choices = choices;
        this.hub = hub.GetLeftPart(UriPartial.Authority) + "/";
        this.hubAddress = hub;
        this.give = give;
        this.sameHub = sameHub;
        this.note = note;
        cloud = new CloudStep(new CloudDeps(settings.Cloud, settings.Tailscale, settings.Status, AppPublicLine, settings.Records.Builds,
                                            settings.Now, settings.Pause, PolicyPlace.FromKept(choices.Get(PolicyChoice))));
        view = new AgentServerView { Cloud = cloud.Now };
        cloud.Changed += () => Set(v => v with { Cloud = cloud.Now, AsksKey = v.AsksKey || cloud.Now.KeyEnded });
    }

    public AgentServerView Now { get { lock (gate) return view; } }

    private void Set(Func<AgentServerView, AgentServerView> change)
    {
        lock (gate) view = change(view);
        Changed?.Invoke();
    }

    /// <summary>The app's own SSH key's public line: made once, its private half only in the secret box.</summary>
    private string AppPublicLine()
    {
        if (settings.Box.Read(AppSshKey.BoxName) is { } kept)
            try { return AppSshKey.PublicLine(kept); }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(kept); }
        var made = AppSshKey.Make();
        try
        {
            settings.Box.Write(AppSshKey.BoxName, made.PrivateKey);
            return made.PublicLine;
        }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(made.PrivateKey); }
    }

    // ---------------------------------------------------------------- the ways, and the provider

    /// <summary>**The card "VPS"** of the first page (the Mac's <c>choose(.linux)</c>): the providers' cards follow, under "A
    /// VPS for your agents". The PC has no second way: a Mac that stays on links with its installer, which the PC does not
    /// drive.</summary>
    public void ChooseVps()
    {
        if (Now.Runs) return;
        Set(v => v with { ChoseVps = true });
    }

    /// <summary>**A provider's card**: a provider whose token this PC holds opens its choice at once, else its token page
    /// shows; with no fleet key in the box, that key is asked first. Nothing while a build, a join or the hand-over runs.</summary>
    public void ChooseProvider(CloudProvider provider)
    {
        if (Now.Runs) return;
        cloud.Cancel();
        Set(v => v with { ChoseVps = true, Provider = provider, AsksKey = !settings.Tailscale.IsHeld, Key = KeyView.Start, Install = InstallView.None });
        if (!Now.AsksKey) Open(provider);
    }

    private void Open(CloudProvider provider)
    {
        if (cloud.Holds(provider)) _ = cloud.OpenAsync(provider, CloudServerUse.Agent, lists: false);
    }

    /// <summary>**The pasted access token makes the fleet's own Tailscale key, and goes** (the Mac's <c>net.sendKey</c>): the
    /// token is kept nowhere. With the key made, the provider's page follows, or the join that stopped for that key goes
    /// again.</summary>
    public async Task SendKeyAsync(string token, CancellationToken cancel = default)
    {
        var given = token.Trim();
        if (given.Length == 0 || Now is not { AsksKey: true, Key.Busy: false, Runs: false } asked) return;
        Set(v => v with { Key = new KeyView(true, null, null, null) });
        try
        {
            var setup = await settings.Tailscale.MakeFleetClientAsync(given, cancel).ConfigureAwait(false);
            if (setup.KeyMade) choices.Set(PolicyChoice, setup.Place.Kept);
            var made = setup.KeyMade && setup.LinesToAdd is null;
            Set(v => v with { Key = new KeyView(false, null, setup.LinesToAdd, setup.Asks, made), AsksKey = !made });
            if (!made) return;
            if (asked.Install.Failure is not null) JoinAgain();
            else if (asked.Provider is { } provider && Now.Provider == provider) Open(provider);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Set(v => v with { Key = new KeyView(false, error.Message, null, null) });
        }
        catch (OperationCanceledException) { Set(v => v with { Key = KeyView.Start }); }
    }

    /// <summary>The token of the provider, once; its choice then opens.</summary>
    public Task SendTokenAsync(string token) =>
        Now is { Runs: false, AsksKey: false, Provider: { } provider } ? cloud.SendTokenAsync(provider, token, CloudServerUse.Agent, lists: false)
                                                                       : Task.CompletedTask;

    /// <summary>The owner's type in the list under the new server.</summary>
    public void ChooseOffer(CloudOffer offer) => cloud.Choose(offer);

    /// <summary>**Make the server, once the hub has answered** (the Mac's <c>makeServer</c>): its join needs a line from the
    /// hub right after the build, so a hub that does not answer now would leave a paid server that nothing installs. Why
    /// not stands over the press, and nothing is made then. This setup is of one generation of the hub: a hub of another
    /// one (the owner's store moved, or the read says that the generation changed) makes nothing, with no line, and the
    /// window makes the setup of the new generation. The server is made only when the choice still shows what was
    /// pressed. False when nothing was started.</summary>
    public async Task<bool> MakeServerAsync(CancellationToken cancel = default)
    {
        var pressed = Now;
        if (pressed is not { Runs: false, Provider: { } provider, Cloud: { Stage: CloudStep.Stage.Choosing, Offer: { } offer } }) return false;
        lock (gate)
        {
            if (view.AsksHub) return false;
            view = view with { AsksHub = true };
        }
        Changed?.Invoke();
        try
        {
            cloud.Stop(null);
            // A read of another generation has no value: the hub took a write since this page's state.
            if (!sameHub() || (await OwnerReads.ServersAsync(calls, cancel).ConfigureAwait(false)).Value is null || !sameHub()) return false;
        }
        catch (Exception error) when (error is HubException or InvalidOperationException or System.Text.Json.JsonException)
        {
            cloud.Stop(HubWords.Of(error, hubAddress));
            return false;
        }
        finally { Set(v => v with { AsksHub = false }); }
        if (cloud.Now is not { Stage: CloudStep.Stage.Choosing } now || now.Provider != provider || now.Offer != offer) return false;
        string? name = null;
        return cloud.MakeNew(hub, (made, _) => name = made, target =>
        {
            Join(target, name);
            return Task.CompletedTask;
        });
    }

    // ---------------------------------------------------------------- the join, and the hand-over

    /// <summary>**The join of a server to this fleet**, by its address and the app's own key: a provider's new server, and any
    /// server that a check of the PC proved. <paramref name="name"/> is the name that this PC gave it, or null: the hub
    /// names a server by its name in Tailscale at its join. <paramref name="sudo"/> is the password of its user's
    /// <c>sudo</c> when that asks for one; the installer clears it. False while another join or hand-over runs.</summary>
    public bool Join(InstallTarget target, string? name = null, char[]? sudo = null)
    {
        lock (gate)
        {
            if (joins)
            {
                if (sudo is not null) Array.Clear(sudo);
                return false;
            }
            joins = true;
            joined = (target, name);
        }
        Set(v => v with { Install = new InstallView(true, [], [], settings.Now(), null, null, null, false, name, hub), HandsOver = false, AsksKey = false });
        _ = Task.Run(async () =>
        {
            try { await JoinAsync(target, name, sudo).ConfigureAwait(false); }
            finally { lock (gate) joins = false; }
        });
        return true;
    }

    /// <summary>**Try again of a join that stopped**: the same install on the same server, from its first step.</summary>
    public bool JoinAgain()
    {
        (InstallTarget Target, string? Name)? last;
        lock (gate) last = joined;
        return Now.Install is { Running: false, Failure: not null } && last is { } server && Join(server.Target, server.Name);
    }

    /// <summary>**One press, up to three tries** (the Mac's <c>installMachine</c> and <c>tries</c>, <see cref="InstallRetry"/>):
    /// the hub's one-time line, which a retry keeps while it has ten minutes left; a key of the fleet's for this one server;
    /// the Mac's plan of a join; and its record. A try that stopped for an error that passes runs again by itself, never
    /// after a sudo password. Then the hand-over.</summary>
    private async Task JoinAsync(InstallTarget target, string? name, char[]? sudo)
    {
        var log = new InstallLog(InstallKind.Join, hub, target.Host, settings.Records.Installs.Launch, settings.Now());
        void Keep() => settings.Records.Installs.Write(log.Record);
        Keep();
        var usedSudo = sudo is not null;
        JoinCode? code = null;
        var freshCode = false;
        try
        {
            for (var tries = 1; ; tries++)
            {
                string? authKey = null;
                FleetKeyException? keyRefused = null;
                var failed = new InstallRetry.FailedStep();
                try
                {
                    // **The join goes only to the fleet that the setup is for** (the Mac's `store.hub == fleet` before its
                    // install): a store that went to another hub or generation meanwhile would give that hub's line, and
                    // the paid server would join the wrong fleet. It stays at its provider, with its build record.
                    if (!sameHub())
                    {
                        if (log.Cancel(settings.Now())) Keep();
                        Set(v => v with { Install = InstallView.None, HandsOver = false });
                        return;
                    }
                    if (freshCode || code is null || !InstallRetry.KeepsCode(code.ExpiresAt, settings.Now().ToUnixTimeMilliseconds() / 1000.0))
                    {
                        code = null;
                        var made = (await OwnerReads.JoinCodeAsync(calls).ConfigureAwait(false)).Value;
                        code = made is { Line: not null, Code: not null } ? made : throw InstallError.CannotStart(SetupStore.NoJoinLine);
                    }
                    try
                    {
                        if (settings.Tailscale.IsHeld)
                            authKey = await settings.Tailscale.AuthKeyAsync(target.Host, TailscaleApi.KeyLifeSeconds).ConfigureAwait(false);
                    }
                    catch (FleetKeyException refused)
                    {
                        // A key that may not give the join line's tags leaves the server to Tailscale's own link.
                        if (NetworkSignIn.Tags(code.Line!).Count == 0) { keyRefused = refused; throw; }
                    }
                    var plan = InstallPlan.Join(target, code.Line!, code.Code!, authKey);
                    log.Hide(plan.Redactions);
                    Set(v => v with { Install = v.Install with { Planned = plan.Steps.Select(p => p.Id).ToList() } });
                    var installer = new Installer(plan, authKey, sudo, clock: settings.JoinClock, firstRun: false);
                    sudo = null;                    // the installer clears it when it ends
                    var checklist = await installer.RunAsync(settings.Remote, progress =>
                    {
                        failed.Note(progress);
                        if (log.Note(progress.Step, Recorded(progress.State), settings.Now())) Keep();
                        Set(v => v with { Install = v.Install.Reported(progress, settings.Now()) });
                    }, CancellationToken.None).ConfigureAwait(false);
                    if (log.Done(settings.Now())) Keep();
                    Set(v => v with { Install = v.Install with { Running = false, Checklist = checklist }, HandsOver = true });
                    if (name is not null) note(name);
                    break;
                }
                catch (Exception error)
                {
                    var stopped = InstallRetry.StoppedBy(error, keyRefused is not null, authKey is null);
                    var again = InstallRetry.Decision(stopped.Stop, stopped.Cause, InstallJob.Join, failed.Value, tries, stopped.NeedsNetworkKey, usedSudo);
                    if (again is null)
                    {
                        if (log.Stop(stopped.Stop, InstallRecord.WordsOf(error, target.Host), stopped.Cause, stopped.NeedsNetworkKey, settings.Now())) Keep();
                        var words = error switch
                        {
                            InstallError e => e.Plain(target.Host),
                            OperationCanceledException => ServerCheck.Unreached(target.Host),       // a call that ended by its own limit
                            _ => error.Message,
                        };
                        lock (gate) stopWords = (log.Record.Id, words);
                        Set(v => v with
                        {
                            Install = v.Install with { Running = false, Failure = words, NeedsNetworkKey = stopped.NeedsNetworkKey, NetworkFailure = keyRefused?.Message },
                            AsksKey = stopped.NeedsNetworkKey, Key = KeyView.Start,
                        });
                        return;
                    }
                    freshCode = again.FreshCode;
                    if (log.Retry(stopped.Stop, stopped.Cause)) Keep();
                    Set(v => v with { Install = v.Install with { Steps = [] } });
                    await InstallRetry.WaitAsync(again.Waits, () => settings.Pause(TimeSpan.FromSeconds(InstallRetry.ReadEvery), CancellationToken.None),
                                                 HubAnswersAsync, () => false).ConfigureAwait(false);
                }
            }
        }
        finally { if (sudo is not null) Array.Clear(sudo); }
        await HandOverAsync(code, name).ConfigureAwait(false);
    }

    /// <summary>One read of the hub, for the wait before a join's next try: whether it answered.</summary>
    private async Task<bool> HubAnswersAsync()
    {
        try
        {
            await OwnerReads.ServersAsync(calls).ConfigureAwait(false);
            return true;
        }
        catch (HubException e) { return e.Kind != HubErrorKind.NoAnswer; }
        catch (Exception e) when (e is InvalidOperationException or System.Text.Json.JsonException) { return false; }
    }

    /// <summary>**The server that joined goes to the manager's setup by itself, as soon as the hub offers it** (the Mac's
    /// <c>handOver</c>): its first reading comes some seconds after its join, so a count of reads waits for it. Then it is
    /// given also when the hub does not offer it yet: the hub says why not, in its own words, on the provider's page. The
    /// setup takes no server that another agent took meanwhile. With no name for the server, or with a server that was not
    /// given, the page of the providers' cards shows again; a server that was not given stays in the manager's mark, for the
    /// setup's own rule to give later, unless the hub lists it with another agent (the Mac's <c>handOver</c>, which notes it
    /// in all cases).</summary>
    private async Task HandOverAsync(JoinCode code, string? name)
    {
        try
        {
            string? server = name;
            for (var read = 0; read < settings.HandOverReads; read++)
            {
                if (read > 0) await settings.Pause(settings.HandOverEvery, CancellationToken.None).ConfigureAwait(false);
                ServerList? list = null;
                try { list = (await OwnerReads.ServersAsync(calls).ConfigureAwait(false)).Value; }
                catch (Exception e) when (e is HubException or InvalidOperationException or System.Text.Json.JsonException) { }
                if (list is null) continue;
                // The hub names the server at its join: that name is the server's, whatever name the provider's build took.
                if (list.Join is { State: "joined", Server: { } hubs } join && join.IsOf(code.Name, code.Kind, code.ExpiresAt)) server = hubs;
                if (list.Servers.FirstOrDefault(s => s.Name == server) is { } row && AgentSetupFlow.IsFree(row)) break;
            }
            // Given, or kept for the setup's own rule: the setup decides.
            if (server is not null) await give(server, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception e) when (e is not OutOfMemoryException) { }
        finally
        {
            // Given, or not to be given: this join hands over no more, here or on a later opening of the page.
            lock (gate) joined = null;
            cloud.Cancel();
            Set(v => v with { HandsOver = false, Install = InstallView.None, Provider = null });
        }
    }

    private static RecordStepState Recorded(ProgressState state) => state switch
    {
        ProgressState.Done => RecordStepState.Done,
        ProgressState.Failed => RecordStepState.Failed,
        _ => RecordStepState.Running,
    };

    // ---------------------------------------------------------------- the first run's server, and Back

    /// <summary>**The page shows: the server that the first run made for the manager and that did not join is installed by
    /// itself, once** (the Mac's <c>installFirst</c>), as root with the app's own key at its address on the private network,
    /// with no second server: only that server, which the manager's mark keeps (<see cref="ManagerSetupMark.Made"/>) until
    /// a join of it ended well (<c>note</c> at the join's end), and never a server that this page made or a build of an
    /// earlier run. The manager's setup asks once for each opening of the page (the Mac's <c>firstTried</c>), from the
    /// first page with nothing running. A server that is not on this PC's network at that address now, or that the hub
    /// lists as its own, with another agent, or with a job that runs there ("busy", as the Mac's reuse reads it), stays as
    /// it is; one that the hub lists free is still the page's (<see cref="ServerList.TakesFirst"/>): the hub takes a server
    /// at the join's POST, before the steps after it, and a join again finishes them. **Nothing joins it by itself while a
    /// join of it runs on this PC** (this PC's newest join record of it reads Running; only this start of the app's own
    /// does, so a start after a closed app is not held): two joins at once could each make a server key, and the hub would
    /// refuse that server for good. The page joins it once by itself, with its tries, also when the first run's own join of it
    /// stopped, as the Mac does; <paramref name="starts"/> notes in the mark that this join started (<see
    /// cref="FirstRunServer.Tried"/>). **Once it started, a stop of it, or a cut by a closed app, does not run again by
    /// itself** (<see cref="NewestJoin"/>): each later opening shows that stop with Try again (<see cref="JoinAgain"/>), the
    /// page's own elements of a join that stopped, so that a cause that lasts never holds the page, which has no Back while a
    /// join runs. Here the PC departs from the Mac in two points, until wave C gives the PC the provider's row "Use this
    /// server" (PARITY.md, <c>manager_server</c>): the Mac lets the server go as its join starts and keeps that row for it,
    /// and its <c>installFirst</c> returns when the hub lists the server, where the PC joins it while it is free. The
    /// records must be the first run's own (<see cref="AgentServerSettings.Records"/>): a second <see cref="SetupRecords"/>
    /// of the same folder does not see its writes. The work runs on its own: this returns at once after its reads.</summary>
    internal async Task OpenedAsync(FirstRunServer server, string agent, ServerList? list, Action starts, CancellationToken cancel)
    {
        if (list is null || !OnFirstPage) return;
        if (Listed(list, server.Name) is { } row && (!list.TakesFirst(agent, row.Name) || row.Why.Contains("busy"))) return;
        var devices = PcNetwork.Devices(await settings.Status(cancel).ConfigureAwait(false) ?? "{}");
        if (!devices.Any(d => d.Online && string.Equals(d.Name, server.Name, StringComparison.OrdinalIgnoreCase) && d.Address == server.Address)) return;
        if (!OnFirstPage) return;
        var newest = NewestJoin(server);
        if (newest is { Runs: true }) return;
        if (server.Tried && newest is { Outcome: InstallOutcome.Stopped or InstallOutcome.Interrupted }) ShowStop(server, newest);
        else if (Join(new InstallTarget(server.Address), server.Name)) starts();
    }

    /// <summary>**The newest join of this server, from this PC's install records**, or null: the newest record of a join to
    /// this hub at the server's address, with its name or none yet. Its outcome says whether a join of it runs now (only
    /// this start of the app's own reads Running), stopped or was cut off by a closed app (<see
    /// cref="InstallOutcome.Interrupted"/>), or ended well. It waits on no clock: "newest" is the records' own order
    /// (<c>KeptRecords.All</c>: newest first by when each began, then by its id). A record of another server, or of this
    /// name at another address (an earlier hub's server), is none, and a server that is no longer the mark's is never asked
    /// about.</summary>
    private InstallRecord? NewestJoin(FirstRunServer server) =>
        settings.Records.Installs.All()
                .FirstOrDefault(r => r.Kind == InstallKind.Join && r.Hub == hub && r.Host == server.Address &&
                                     (r.Server is null || string.Equals(r.Server, server.Name, StringComparison.OrdinalIgnoreCase)));

    /// <summary>**That stop, shown again as the page shows a join that stopped**: its words (this run's own, else the record's
    /// line, else the step where it stopped, as the page says it of a stop with no words), Try again on the same server
    /// at the mark's address, and the fleet's key when the stop waits for it.</summary>
    private void ShowStop(FirstRunServer server, InstallRecord stopped)
    {
        string words;
        lock (gate)
        {
            joined = (new InstallTarget(server.Address), server.Name);
            words = stopWords is { } kept && kept.Record == stopped.Id ? kept.Words : stopped.Says ?? StoppedAt(server, stopped);
        }
        Set(v => v with
        {
            Install = InstallView.None with { Failure = words, Server = server.Name, JoinHub = hub, NeedsNetworkKey = stopped.WaitsForNetwork },
            AsksKey = stopped.WaitsForNetwork, Key = KeyView.Start, HandsOver = false,
        });
    }

    /// <summary>The line of a kept stop with no words: the title of the join's step where it stopped (the first step for a
    /// record with none).</summary>
    private static string StoppedAt(FirstRunServer server, InstallRecord stopped)
    {
        var steps = InstallPlan.Join(new InstallTarget(server.Address), "", "", null).Steps;
        var step = steps.FirstOrDefault(s => stopped.StoppedAt is { } at && InstallStepIds.Named(s.Id) == at) ?? steps[0];
        return InstallError.StoppedAt(step.Title);
    }

    /// <summary>The first page, with nothing running and no join that stopped (the Mac's <c>page == .ways</c>,
    /// <c>!model.running</c> and <c>cloud.stage == .token</c>).</summary>
    private bool OnFirstPage => Now is { Runs: false, ChoseVps: false, Provider: null, Install.Failure: null };

    /// <summary>**The page opens again on its first page** (the Mac's view, whose states start again when it opens): the
    /// way, the provider, the key's page and a join that stopped go, as with Back; nothing while a build, a join or the
    /// hand-over runs.</summary>
    internal void NewVisit()
    {
        if (Now.Runs) return;
        cloud.Cancel();
        Set(v => v with { ChoseVps = false, Provider = null, AsksKey = false, Key = KeyView.Start, Install = InstallView.None });
    }

    private static ServerEntry? Listed(ServerList list, string name) =>
        list.Servers.FirstOrDefault(s => string.Equals(s.Name, name, StringComparison.OrdinalIgnoreCase));

    /// <summary>**One step back** (the Mac's <c>previous</c>): from a provider's pages or a join that stopped to the
    /// providers' cards, and from the cards to the first page; nothing while a build, a join or the hand-over runs, nor on
    /// the first page, which is the setup's own. A join that stopped goes with it, and its record stays in its file.</summary>
    public void Back()
    {
        var now = Now;
        if (now.Runs) return;
        cloud.Cancel();
        if (now is { Provider: null, Install.Failure: null, AsksKey: false })
        {
            Set(v => v with { ChoseVps = false });
            return;
        }
        Set(v => v with { Provider = null, AsksKey = false, Key = KeyView.Start, Install = InstallView.None });
    }
}

/// <summary>**The server's page of a manager with no server, from its view** (the Mac's <c>AddServerView</c> with
/// <c>placing</c>), each sentence the Mac's, in the Mac's order: "&lt;Manager&gt;'s server" with the way "VPS"; then "A VPS
/// for your agents" with the providers' cards; the fleet's Tailscale key; a provider's token, its new server and its
/// build; and the join, with what stopped it. Not yet: Other VPS among the cards (its check is <see cref="SetupStore"/>'s),
/// and a Mac that stays on, which the PC does not link. The page gives no card for a server of the fleet (<see
/// cref="ManagerSetupView.Free"/>): the Mac offers one in its provider's list alone.</summary>
public static class AgentServerScreens
{
    public const string MakeTheServer = "Make the server", InstallingTheServer = "Installing the server", ServerDidNotInstall = "The server did not install";
    /// <summary>The first page's one way (the Mac's <c>ways</c> with <c>placing</c>), its line on hover, and the title of
    /// the providers' cards (the Mac's <c>.machine</c> page of a VPS).</summary>
    public const string Vps = "VPS", VpsLine = "Hetzner, DigitalOcean, Vultr, Akamai, or any VPS by its address.",
                        VpsForYourAgents = "A VPS for your agents";
    private const string TheServer = "The server";
    public static string NeedsAServer(string manager) => $"{manager} needs a server of its own that stays on.";
    public static string ServerAt(string manager, string provider) => $"{manager}'s server at {provider}";
    public static string Installing(string server) => $"Installing {server}";
    public static string DidNotInstall(string server) => $"{server} did not install";
    public static string IsInstalled(string server) => $"{server} is installed";

    public static ManagerSetupScreen Of(ManagerSetupView v, SetupProgress? progress, CultureInfo? culture = null)
    {
        if (v.NewServer is not { } server) return new("server", SetupScreens.ManagersServer(v.Label), false, NeedsAServer(v.Label), [], null, progress);
        if (server.Install is { Running: true } or { Failure: not null } || server.HandsOver) return Join(server);
        if (!server.ChoseVps)
            return new("server", SetupScreens.ManagersServer(v.Label), false, NeedsAServer(v.Label),
                       [new SetupControl(SetupControlKind.Card, Vps, "add-machine-way-linux", VpsLine)], null, progress);
        if (server.Provider is not { } provider)
            return new("serverMachine", VpsForYourAgents, false, null,
                       CloudProviders.All.Select(p => new SetupControl(SetupControlKind.Card, p.Name(), "add-server-cloud-" + p.Raw(), SetupScreens.CardLine(p))).ToList(),
                       null, progress, Back: true);
        return server.AsksKey ? Key(server, progress) : Token(v.Label, provider, server, progress, culture);
    }

    /// <summary>**The fleet's own Tailscale key, once**: what the owner does at Tailscale, and the paste.</summary>
    private static ManagerSetupScreen Key(AgentServerView server, SetupProgress? progress)
    {
        var key = server.Key;
        return new("serverKey", key.Busy ? SetupScreens.KeyBusy : SetupScreens.KeyTitle, key.Busy, null, KeyControls(server), key.Failure, progress, Back: !key.Busy);
    }

    private static List<SetupControl> KeyControls(AgentServerView server)
    {
        var controls = new List<SetupControl>();
        if (!server.Key.Busy)
        {
            controls.Add(new(SetupControlKind.Steps, "", "add-server-key-steps", Lines: SetupScreens.KeySteps));
            controls.Add(new(SetupControlKind.Paste, SetupScreens.PasteHere, "add-server-tailscale-key"));
        }
        if (server.Key is { LinesToAdd: { } lines, Asks: { } asks }) controls.Add(new(SetupControlKind.Muted, asks, "add-server-key-lines", lines));
        return controls;
    }

    /// <summary>A provider's page: its token's steps and field, the new server and its price with the one press, and the
    /// build, which has no Back.</summary>
    private static ManagerSetupScreen Token(string manager, CloudProvider provider, AgentServerView server, SetupProgress? progress, CultureInfo? culture)
    {
        var cloud = server.Cloud;
        if (server.Builds) return new("serverBuild", InstallingTheServer, true, null, [], null, null);
        var choosing = cloud.Stage == CloudStep.Stage.Choosing;
        var controls = new List<SetupControl>();
        if (choosing && cloud.Offer is { } offer)
        {
            controls.Add(new(SetupControlKind.Card, offer.Row(culture), "cloud-choice-new", Marked: true));
            if (!server.AsksHub) controls.Add(new(SetupControlKind.Button, MakeTheServer, "cloud-choice-press"));
        }
        else if (!choosing && !cloud.TokenTaken)
        {
            controls.Add(new(SetupControlKind.Steps, "", "add-server-cloud-token-steps", Lines: SetupScreens.TokenSteps(provider)));
            controls.Add(new(SetupControlKind.Paste, SetupScreens.PasteHere, "add-server-cloud-token"));
        }
        return new("serverToken", choosing || cloud.TokenTaken ? ServerAt(manager, provider.Name()) : SetupScreens.TokenTitle(provider),
                   server.AsksHub || choosing && cloud.Offer is null, null, controls, cloud.Failure, progress, Back: !server.Runs);
    }

    /// <summary>The join while it runs, its stop over Try again (or over the network's key), and the moving title until the
    /// hub offers the server. An install that waits for the owner's yes at Tailscale has its one press.</summary>
    private static ManagerSetupScreen Join(AgentServerView server)
    {
        var install = server.Install;
        var name = install.Server;
        if (install is { Running: false, Failure: { } failure })
        {
            var title = name is null ? ServerDidNotInstall : DidNotInstall(name);
            if (!server.AsksKey)
                return new("serverInstall", title, false, null, [new SetupControl(SetupControlKind.Button, SetupScreens.TryAgain, "first-run-install-again")],
                           failure, null, Back: true);
            return new("serverInstall", title, server.Key.Busy, null,
                       [new SetupControl(SetupControlKind.Muted, SetupScreens.NotOnNetwork, "install-network-row", SetupScreens.ConnectThenInstall), .. KeyControls(server)],
                       install.NetworkFailure ?? server.Key.Failure, null, Back: !server.Key.Busy);
        }
        if (server.HandsOver) return new("serverInstall", IsInstalled(name ?? TheServer), true, null, [], null, null);
        var controls = new List<SetupControl>();
        if (install.NetworkSignIn is { } link)
        {
            controls.Add(new(SetupControlKind.Row, SetupScreens.NotOnNetwork, "install-network-row"));
            controls.Add(new(SetupControlKind.Row, link.Server is { } approves ? SetupScreens.ApproveServer(approves) : SetupScreens.ApproveInTailscale,
                             "install-network-sign-in", Lines: [SetupScreens.OpenLink]));
        }
        return new("serverInstall", name is null ? InstallingTheServer : Installing(name), true, null, controls, null, null);
    }
}

/// <summary>**The Mac's words for a read of the hub that failed** (FleetCore's <c>HubReach.words</c>, its first line, with
/// "PC" for "Mac"): the line over the press of a new server that the hub did not let go on.</summary>
public static class HubWords
{
    public const string DidNotAnswer = "Your hub did not answer.";
    public const string RefusedRead = "Your hub refused this read.";
    public const string NotReadable = "Your hub answered something this app could not read.";
    public const string NotAnAddress = "That is not a hub address.";
    public static string NotServed(string at) => $"Your hub answered{at}, and it does not serve its pages to this PC.";
    public static string NotAHub(string at) => $"Something answered{at}, but it is not a Founderizer hub.";

    /// <summary>The line for <paramref name="error"/> of a read of the hub at <paramref name="hub"/>.</summary>
    public static string Of(Exception error, Uri hub)
    {
        var at = " at " + (hub.IsDefaultPort ? hub.Host : hub.Host + ":" + hub.Port.ToString(CultureInfo.InvariantCulture));
        return error switch
        {
            HubException { Kind: HubErrorKind.InvalidAddress } => NotAnAddress,
            HubException { Kind: HubErrorKind.Refusal, Status: 403 } => NotServed(at),
            HubException { Kind: HubErrorKind.Refusal, Status: 404 } => NotAHub(at),
            HubException { Kind: HubErrorKind.Refusal } => RefusedRead,
            HubException { Kind: HubErrorKind.InvalidResponse } or System.Text.Json.JsonException => NotReadable,
            _ => DidNotAnswer,
        };
    }
}
