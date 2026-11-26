using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Founderizer.Remote;
using Founderizer.Setup.Agents;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.Install;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.FirstRun;

/// <summary>What the first run needs from the PC (the window gives each; a test gives stand-ins).</summary>
public sealed class SetupSettings
{
    /// <summary>The daily pages' store, as the owner's computer once the hub is claimed.</summary>
    public required OwnerStore Owner { get; init; }
    public required ISecretBox Box { get; init; }
    /// <summary>SSH from the PC (<see cref="SshRemote"/>).</summary>
    public required IRemote Remote { get; init; }
    /// <summary>The record of the servers' host keys that <see cref="Remote"/> keeps.</summary>
    public required HostKeys HostKeys { get; init; }
    public required SetupRecords Records { get; init; }
    /// <summary>Tailscale's API with the fleet's key (<c>new FleetNet(new TailscaleApi(ProviderHandler.Create(), box))</c>).</summary>
    public required IFleetNet Tailscale { get; init; }
    /// <summary>A provider (<c>CloudServers.For(provider, ProviderHandler.Create(), box)</c>).</summary>
    public required Func<CloudProvider, ICloud> Cloud { get; init; }
    /// <summary>This PC's <c>tailscale status --json</c>, or null with no Tailscale running.</summary>
    public required Func<CancellationToken, Task<string?>> Status { get; init; }
    /// <summary>The client of the claim and of the hub's read while an install waits for its code.</summary>
    public HubClient Hub { get; init; } = new();
    public ISetupChoices Choices { get; init; } = new MemoryChoices();
    public Func<DateTimeOffset> Now { get; init; } = () => DateTimeOffset.UtcNow;
    public Func<TimeSpan, CancellationToken, Task> Pause { get; init; } = Task.Delay;
    /// <summary>The installer of a plan with its auth key and its sudo password (a test gives one whose claim is its own).</summary>
    public Func<InstallPlan, string?, char[]?, Installer>? Installer { get; init; }
    /// <summary>This PC becomes the owner's computer of the hub that a claim gave (<see cref="OwnerStore.ConnectOwnerAsync"/>,
    /// unless a test gives its own).</summary>
    public Func<Uri, Task>? ConnectOwner { get; init; }
    /// <summary>The owner's calls of the new hub (<see cref="OwnerReads.Of"/> of <see cref="Owner"/>, unless a test gives
    /// its own).</summary>
    public OwnerReads.ICalls? Calls { get; init; }
    /// <summary>The hub's reading that the owner's computer holds now (<see cref="Owner"/>'s, unless a test gives its own).</summary>
    public Func<MobileSnapshot?>? Fleet { get; init; }
    /// <summary>The PC forgets the hub that Start again took away (<see cref="OwnerStore.ForgetOwnedHub"/>, unless a test
    /// gives its own).</summary>
    public Action<Uri, bool>? ForgetHub { get; init; }
    /// <summary>How many reads the manager's join waits for the new hub, and how long between two (the Mac's 60 and 10 s).</summary>
    public int JoinReads { get; init; } = 60;
    public TimeSpan JoinReadEvery { get; init; } = TimeSpan.FromSeconds(10);
    /// <summary>The clock of the join's installer: its waits between two reads of a server (the system's, unless a test
    /// gives one whose waits pass at once).</summary>
    public InstallerClock? JoinClock { get; init; }
}

/// <summary>**The first run of a PC, as a model** (windows-app-plan-v2.md, piece L4; the Mac's <c>FirstRunModel</c>,
/// <c>FirstRunWork</c>, <c>FleetNetworkModel</c>, <c>FleetCloudModel</c>, <c>FleetVPSModel</c> and the flow of
/// <c>FirstRunView</c>): one method for each press, an immutable <see cref="State"/>, and <see cref="Changed"/> after each
/// change. The window draws <see cref="SetupScreens"/> of the state and calls the presses; it runs Tailscale's installer
/// and Windows' own dialogs itself. Nothing here draws or calls Windows.
///
/// The order of the pages is the Mac's: welcome, Help improve Founderizer, Name your manager, the AI provider, Your
/// fleet's servers, then Connect Tailscale only for a PC on no tailnet and Your Tailscale key only for a box that holds no
/// fleet key, then the VPS, its token and "Your fleet", whose one press makes every server; the hub's install claims the
/// new hub from this PC (<see cref="OwnerStore.ConnectOwnerAsync"/>), the manager's own server joins it, and the window
/// goes to the manager's setup.</summary>
public sealed class SetupStore
{
    private readonly SetupSettings settings;
    private readonly object gate = new();
    private SetupState state;
    private readonly CloudStep hubCloud, managersCloud;
    private CancellationTokenSource? vpsWork, installWork, joinWork;
    /// <summary>The server of the newest install of the hub, for its Try again.</summary>
    private InstallTarget? installed;
    private char[]? sudoPassword;
    private bool signsIn;

    /// <summary>Called after each change of <see cref="State"/>, outside the store's lock and on no thread in particular.</summary>
    public event EventHandler<SetupState>? Changed;

    public SetupStore(SetupSettings settings)
    {
        this.settings = settings;
        var deps = new CloudDeps(settings.Cloud, settings.Tailscale, settings.Status, AppPublicLine, settings.Records.Builds,
                                 settings.Now, settings.Pause, Network.PolicyPlace.FromKept(settings.Choices.Get("tailscalePolicyPlace")));
        hubCloud = new CloudStep(deps);
        managersCloud = new CloudStep(deps);
        var choices = settings.Choices;
        state = new SetupState
        {
            ManagerName = choices.Get(SetupChoiceNames.ManagerName) ?? Install.ManagerName.Suggested,
            AiProvider = choices.Get(SetupChoiceNames.AiProvider) is "codex" or "claude" ? choices.Get(SetupChoiceNames.AiProvider) : null,
            ServersStep = ServersSteps.FromRaw(choices.Get(SetupChoiceNames.ServersStep)) ?? ServersStep.Two,
            SendsReports = Answer(choices.Get(SetupChoiceNames.Reports)),
            HoldsFleetKey = settings.Tailscale.IsHeld,
            Cloud = hubCloud.Now,
            ManagersCloud = managersCloud.Now,
        };
        hubCloud.Changed += () =>
        {
            var now = hubCloud.Now;
            Set(s => s with { Cloud = now, FleetKeyEnded = s.FleetKeyEnded || now.KeyEnded });
            OpensManagersChoice();
            ManagersRefused();
        };
        settings.Owner.Changed += (_, _) => OwnerChanged();
        managersCloud.Changed += () =>
        {
            Set(s => s with { ManagersCloud = managersCloud.Now });
            ManagersTokenTaken();
            ManagersRefused();
        };
    }

    public SetupState State { get { lock (gate) return state; } }

    /// <summary>The cards of the page of the manager's AI provider, in their order.</summary>
    public static readonly IReadOnlyList<string> AiChoices = ["codex", "claude"];

    /// <summary>**A reading of the owner's store**: whether the new hub answers this PC now (the page of checks that did not
    /// pass offers "Open Founderizer" only then, as the Mac's <c>afterInstall</c> does), then the hand-over's ask.</summary>
    internal void OwnerChanged()
    {
        var answers = FleetNow() is not null;
        if (State.HubAnswers != answers) Set(s => s with { HubAnswers = answers });
        else HandOverIfDue();
    }

    private void Set(Func<SetupState, SetupState> change)
    {
        SetupState now;
        lock (gate) { state = change(state); now = state; }
        Changed?.Invoke(this, now);
        HandOverIfDue();
    }

    private OwnerReads.ICalls Calls() => settings.Calls ?? OwnerReads.Of(settings.Owner);

    private MobileSnapshot? FleetNow() => settings.Fleet is { } fleet ? fleet() : settings.Owner.State.Fleet;

    private static bool? Answer(string? word) => word switch { "send" => true, "none" => false, _ => null };

    private ServerCheck.PolicyPlace? Policy() =>
        Network.PolicyPlace.FromKept(settings.Choices.Get("tailscalePolicyPlace")) is { } place
            ? new ServerCheck.PolicyPlace(place.Address, place.Tool)
            : null;

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

    // ---------------------------------------------------------------- the first pages

    /// <summary>A page and what starting it clears (the Mac's <c>start</c>): the welcome page starts the first run over.</summary>
    private void Go(SetupPage page, CloudProvider? provider = null) => Set(s =>
    {
        var next = s with { Page = page, TokenOf = page == SetupPage.Token ? provider ?? s.TokenOf : s.TokenOf, Failure = null };
        if (page == SetupPage.Installing) next = next with { Began = true };
        if (page == SetupPage.Welcome)
        {
            settings.Choices.Set(SetupChoiceNames.ReportsWaiting, null);
            next = next with { Named = false, ChoseAi = false, Shaped = false, ManagersProvider = null, ManagersToken = null, ManagersRefusal = null,
                               ManagersFull = new HashSet<CloudProvider>(), ManagersMoreShown = false };
        }
        return next;
    });

    /// <summary>This PC's network as the window read it: <paramref name="statusJson"/> is <c>tailscale status --json</c>
    /// (null when Tailscale does not answer), <paramref name="installed"/> false with no Tailscale on the PC. On the network
    /// page, a PC that is on the network goes on by itself.</summary>
    public void ReadPc(string? statusJson, bool installed = true)
    {
        var standing = PcNetwork.State(statusJson, installed);
        Set(s => s with { Pc = standing, PcReady = standing.IsConnected, HoldsFleetKey = settings.Tailscale.IsHeld });
        if (standing.IsConnected && State.Page == SetupPage.Network) Onwards();
    }

    /// <summary>The welcome page's way: "Set it up yourself", on to "Help improve Founderizer".</summary>
    public void SetUp() { if (State.Page == SetupPage.Welcome) Go(SetupPage.ErrorReports); }

    /// <summary>A press on a card of "Help improve Founderizer": the check mark, the answer that the next hub gets, and
    /// on to "Name your manager".</summary>
    public void ChooseReports(bool send)
    {
        var word = send ? "send" : "none";
        settings.Choices.Set(SetupChoiceNames.Reports, word);
        settings.Choices.Set(SetupChoiceNames.ReportsWaiting, word);
        Set(s => s with { SendsReports = send });
        Go(SetupPage.Name);
    }

    /// <summary>The words in the name's field.</summary>
    public void TypeName(string typed) => Set(s => s with { ManagerName = typed });

    /// <summary>Continue of "Name your manager": only for a name that the hub's installer takes.</summary>
    public void ChooseName()
    {
        var s = State;
        if (Install.ManagerName.AgentName(s.ManagerName) is null) return;
        settings.Choices.Set(SetupChoiceNames.ManagerName, Install.ManagerName.Shown(s.ManagerName));
        Set(x => x with { Named = true });
        Go(SetupPage.AiProvider);
    }

    /// <summary>A press on a card of the manager's AI provider: on to "Your fleet's servers".</summary>
    public void ChooseAi(string provider)
    {
        if (!AiChoices.Contains(provider)) return;
        settings.Choices.Set(SetupChoiceNames.AiProvider, provider);
        Set(s => s with { AiProvider = provider, ChoseAi = true });
        Go(SetupPage.Servers);
    }

    /// <summary>The slider's step.</summary>
    public void MoveSlider(ServersStep step) => Set(s => s with { ServersStep = step });

    /// <summary>Continue of "Your fleet's servers": on to the VPS page, with this PC's network and the fleet's key first
    /// when they are missing.</summary>
    public void ChooseServers()
    {
        settings.Choices.Set(SetupChoiceNames.ServersStep, State.ServersStep.Raw());
        Set(s => s with { Shaped = true });
        Choose(SetupPage.Cloud);
    }

    /// <summary>**The card that the owner pressed** (the Mac's <c>choose</c>): a PC that is not on the private network is put
    /// on it first, and the fleet's own Tailscale key is made once before the first server.</summary>
    private void Choose(SetupPage way, CloudProvider? provider = null)
    {
        var s = State;
        if (s.PcReady == false)
        {
            Set(x => x with { After = way, AfterProvider = provider });
            Go(SetupPage.Network);
        }
        else if (!settings.Tailscale.IsHeld || s.FleetKeyEnded)
        {
            Set(x => x with { After = way, AfterProvider = provider, HoldsFleetKey = false });
            Go(SetupPage.Key);
        }
        else
        {
            Go(way, provider);
            if (way == SetupPage.Token) OpensChoice();
        }
    }

    /// <summary>On from the network page: to the card's page, with the key's page first while the box holds no key.</summary>
    private void Onwards()
    {
        var s = State;
        if (s.After is not { } next) { Go(SetupPage.Cloud); return; }
        if (!settings.Tailscale.IsHeld || s.FleetKeyEnded) { Go(SetupPage.Key); return; }
        Go(next, s.AfterProvider);
        if (next == SetupPage.Token) OpensChoice();
    }

    /// <summary>Connect of the network page: the window starts Tailscale's installer or Tailscale itself; the title waits
    /// for Tailscale from now on.</summary>
    public void PressConnect() => Set(s => s with { Network = s.Network with { Pressed = true, Failure = null } });

    /// <summary>What stopped Tailscale's installer or its start, in the window's words (its publisher, its download).</summary>
    public void NetworkStopped(string words) => Set(s => s with { Network = s.Network with { Failure = words } });

    /// <summary>**The pasted access token makes the fleet's own key, and goes** (the Mac's <c>sendKey</c>): the token is
    /// kept nowhere; the OAuth client goes into the box, in place of one that Tailscale ended. On the key's page the
    /// first run goes on to the card that was pressed; on the install's page of a stop for the network's key, the page
    /// then offers Install again (the Mac's <c>PrivateNetworkSection</c> there).</summary>
    public async Task SendKeyAsync(string token, CancellationToken cancel = default)
    {
        var given = token.Trim();
        if (given.Length == 0 || State.Key.Busy) return;
        Set(s => s with { Key = new KeyView(true, null, null, null) });
        try
        {
            var setup = await settings.Tailscale.MakeFleetClientAsync(given, cancel).ConfigureAwait(false);
            if (setup.KeyMade) settings.Choices.Set("tailscalePolicyPlace", setup.Place.Kept);
            var made = setup.KeyMade && setup.LinesToAdd is null;
            Set(s => s with
            {
                Key = new KeyView(false, null, setup.LinesToAdd, setup.Asks, made), HoldsFleetKey = settings.Tailscale.IsHeld,
                FleetKeyEnded = s.FleetKeyEnded && !made,
            });
            if (made && State.Page == SetupPage.Key)
            {
                var s = State;
                Go(s.After ?? SetupPage.Cloud, s.AfterProvider);
                if (State.Page == SetupPage.Token) OpensChoice();
            }
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Set(s => s with { Key = new KeyView(false, error.Message, null, null) });
        }
    }

    /// <summary>A provider's card of the VPS page.</summary>
    public void ChooseProvider(CloudProvider provider) => Choose(SetupPage.Token, provider);

    /// <summary>The card Other VPS.</summary>
    public void ChooseOtherVps()
    {
        ResetVps();
        Choose(SetupPage.Vps);
    }

    /// <summary>A provider whose token this PC holds opens its choice at once; else its page asks for the token first.</summary>
    private void OpensChoice()
    {
        var s = State;
        if (s is { Page: SetupPage.Token, TokenOf: { } provider } && hubCloud.Now.Stage == CloudStep.Stage.Token && hubCloud.Holds(provider))
            _ = hubCloud.OpenAsync(provider, CloudServerUse.Hub);
    }

    /// <summary>The token of the hub's provider, once.</summary>
    public Task SendTokenAsync(string token) =>
        State.TokenOf is { } provider ? hubCloud.SendTokenAsync(provider, token, CloudServerUse.Hub) : Task.CompletedTask;

    /// <summary>The owner's type in the list under the hub's server.</summary>
    public void ChooseOffer(CloudOffer offer) => hubCloud.Choose(offer);

    /// <summary>The owner's type in the list under the manager's own server.</summary>
    public void ChooseManagersOffer(CloudOffer offer) => managersCloud.Choose(offer);

    /// <summary>A server of the account's list for the hub, or null for the new one.</summary>
    public void ChooseExisting(string? id) => hubCloud.ChooseExisting(id);

    /// <summary>**The manager's own server's offer opens with the hub's**, on 2 servers and 1 per agent, at the hub's
    /// provider or at the one that the owner chose for it, once this PC holds that provider's token.</summary>
    private void OpensManagersChoice()
    {
        var s = State;
        if (!s.MakesManagersServer || s.Page != SetupPage.Token || s.TokenOf is not { } hubs || hubCloud.Now is not { Stage: CloudStep.Stage.Choosing, TokenTaken: true })
            return;
        var provider = s.ManagersProvider ?? hubs;
        var m = managersCloud.Now;
        if (m.Stage == CloudStep.Stage.Token)
        {
            if (!managersCloud.Busy && managersCloud.Holds(provider)) _ = managersCloud.OpenAsync(provider, CloudServerUse.Agent, lists: false);
        }
        else if (m.Stage == CloudStep.Stage.Choosing && m.Provider != provider)
        {
            managersCloud.Cancel();
            if (managersCloud.Holds(provider)) _ = managersCloud.OpenAsync(provider, CloudServerUse.Agent, lists: false);
        }
    }

    /// <summary>The manager's own provider took its token: "Your fleet" again, with that provider's offer.</summary>
    private void ManagersTokenTaken()
    {
        var m = managersCloud.Now;
        if (m.TokenTaken && State.ManagersToken is not null) Set(s => s with { ManagersToken = null });
        if (m.Stopped == CloudStep.Stage.Token && State.ManagersProvider is { } own && m.Provider == own && !m.TokenTaken)
            Set(s => s with { ManagersToken = own });
    }

    /// <summary>**The hub's server at another provider** (its capsule's "Another provider").</summary>
    public void HubAt(CloudProvider provider)
    {
        if (State.ManagersProvider == provider) Set(s => s with { ManagersProvider = null });
        hubCloud.Cancel();
        if (State.ManagersProvider is null && managersCloud.Now.Stage == CloudStep.Stage.Choosing && managersCloud.Now.Provider != provider)
            managersCloud.Cancel();
        Choose(SetupPage.Token, provider);
        OpensManagersChoice();
    }

    /// <summary>**The manager's own server at another provider**: its choice opens there when this PC holds that
    /// provider's token, and that provider's token page shows first when not.</summary>
    public void ManagersAt(CloudProvider provider)
    {
        if (hubCloud.Now.Provider is not { } hubs || managersCloud.Now.Stage is not (CloudStep.Stage.Token or CloudStep.Stage.Choosing)) return;
        Set(s => s with { ManagersProvider = provider == hubs ? null : provider });
        managersCloud.Cancel();
        if (managersCloud.Holds(provider)) _ = managersCloud.OpenAsync(provider, CloudServerUse.Agent, lists: false);
        else Set(s => s with { ManagersToken = provider });
    }

    /// <summary>The token of the manager's own provider (its page on "Your fleet" or on the build page).</summary>
    public Task SendManagersTokenAsync(string token) =>
        State.ManagersToken is { } provider ? managersCloud.SendTokenAsync(provider, token, CloudServerUse.Agent, lists: false) : Task.CompletedTask;

    /// <summary>The link under a refusal of Hetzner's account: its steps show in its place.</summary>
    public void ShowManagersMore() => Set(s => s with { ManagersMoreShown = true });

    // ---------------------------------------------------------------- one press makes every server

    /// <summary>**"Make the server" or "Make 2 servers"** (the Mac's <c>makeFleet</c>): the hub's server, whose install
    /// starts as soon as it is on the private network, and on 2 servers and 1 per agent the manager's own server, made from
    /// that moment on. A build that runs refuses a second press: the press makes nothing then.</summary>
    public bool MakeFleet()
    {
        var managers = State.MakesManagersServer;
        Set(s => s with { ManagersRefusal = null, ManagersFull = new HashSet<CloudProvider>(), ManagersMoreShown = false });
        return hubCloud.MakeNew(null, null, target =>
        {
            Set(s => s with { HubBuilt = true });
            StartInstall(target, null);
            if (managers && StartAgain.HubAddress(target.Host) is { } future) MakeManagersServer(future);
            return Task.CompletedTask;
        });
    }

    /// <summary>**The manager's own server, made under the hood once the hub's server is on the private network**: its
    /// build record names the hub's address that the claim gives. A server of an earlier try of this run is kept for the
    /// new hub's address, and no other is made.</summary>
    private void MakeManagersServer(string future)
    {
        Set(s => s with { ManagersHub = future });
        // A server of an earlier try that is on the private network is kept for this hub; a build that left none (it was
        // refused) is made again (the Mac's managersServer, which only a server that joined has).
        if (State.ManagersServer is { Address: not null } made)
        {
            KeepManagersServer(made, future);
            return;
        }
        if (managersCloud.Now.Provider is not { } provider) return;
        managersCloud.MakeNew(future, (name, id) => Set(s => s with { ManagersServer = new MadeServer(name, null, id, provider) }), target =>
        {
            Set(s => s with { ManagersServer = s.ManagersServer is { } m ? m with { Address = target.Host } : null });
            if (State is { ManagersHub: { } newest, ManagersServer: { } server } && newest != future) KeepManagersServer(server, newest);
            StartManagersJoin();
            return Task.CompletedTask;
        });
    }

    /// <summary>The manager's own server of this run, kept for another try's hub address: its build record, by its id.</summary>
    private void KeepManagersServer(MadeServer made, string hub)
    {
        if (made.Id is not { } id) return;
        foreach (var record in settings.Records.Builds.All().Where(r => r.ServerId == id && r.Provider == made.Provider.Raw()))
            settings.Records.Builds.Update(record.Id, r => r with { Hub = hub });
    }

    /// <summary>**The press "Make &lt;name&gt;'s server"** after a refusal: the manager's own server, for this run's hub.</summary>
    public void MakeManagersServerAgain()
    {
        if (State.ManagersHub is not { } future || managersCloud.Now.Stage != CloudStep.Stage.Choosing) return;
        Set(s => s with { ManagersRefusal = null });
        MakeManagersServer(future);
    }

    /// <summary>**A refusal of the manager's own server on the build page**: its words stay over its capsule, and an
    /// account with no room opens another provider whose token this PC holds.</summary>
    private void ManagersRefused()
    {
        var s = State;
        var m = managersCloud.Now;
        // The Mac's managersRefusedNow: no server joined, and the build's record has no id of the provider's.
        var refusedNow = s.Page == SetupPage.Installing && s.MakesManagersServer && s.ManagersServer is not { Address: not null } &&
                         s.ManagersServer?.Id is null && m.Stopped == CloudStep.Stage.Making && m.Stage == CloudStep.Stage.Choosing;
        if (!refusedNow || m.Failure is not { } words || m.Provider is not { } provider || s.ManagersRefusal == words) return;
        var full = m.AccountFull ? new HashSet<CloudProvider>(s.ManagersFull) { provider } : s.ManagersFull;
        Set(x => x with { ManagersRefusal = words, ManagersFull = full });
        if (m.AccountFull && CloudProviders.All.FirstOrDefault(p => !full.Contains(p) && settings.Cloud(p).IsHeld) is var other &&
            !full.Contains(other) && settings.Cloud(other).IsHeld)
            ManagersAt(other);
    }

    /// <summary>The first run waits for the manager's own server: while its build runs, and while its refused choice is
    /// open and can lead on.</summary>
    public bool ManagersHolds
    {
        get
        {
            var s = State;
            var m = managersCloud.Now;
            var builds = m.Stage is CloudStep.Stage.Making or CloudStep.Stage.Joining;
            var stuck = s.ManagersToken is null && m.Provider is { } p && s.ManagersFull.Contains(p);
            return builds || ManagersChoiceOpen && !stuck;
        }
    }

    /// <summary>The manager's own server was refused, and its choice shows.</summary>
    public bool ManagersChoiceOpen
    {
        get
        {
            var s = State;
            var m = managersCloud.Now;
            if (!s.MakesManagersServer || s.ManagersServer is { Address: not null }) return false;
            var refusedNow = s.Page == SetupPage.Installing && s.ManagersServer?.Id is null && m.Stopped == CloudStep.Stage.Making &&
                             m.Stage == CloudStep.Stage.Choosing;
            if (s.ManagersRefusal is null && !refusedNow) return false;
            return m.Offer is not null || s.ManagersToken is not null || (m.Stage == CloudStep.Stage.Choosing && m.Stopped != CloudStep.Stage.Choosing);
        }
    }

    // ---------------------------------------------------------------- Other VPS

    private void ResetVps()
    {
        CancellationTokenSource? old;
        lock (gate) { old = vpsWork; vpsWork = null; }
        old?.Cancel();
        ClearSudo();
        ClearKey();
        Set(s => s with { Vps = VpsView.Start });
    }

    // ---------------------------------------------------------------- the owner's key once

    /// <summary>The bytes of the key file that the owner chose, and its passphrase: this model's only copies, in memory,
    /// for the step's length. No record, setting, box or line ever holds them, nor the file's path; the page shows the
    /// file's name alone, which goes with them.</summary>
    private byte[]? ownerKey;
    private char[]? ownerPassphrase;

    /// <summary>The model holds a byte of the owner's key or its passphrase now (for a test).</summary>
    internal bool HoldsOwnerKey { get { lock (gate) return ownerKey is not null || ownerPassphrase is not null; } }

    private void ClearKey()
    {
        byte[]? key;
        char[]? passphrase;
        lock (gate) { key = ownerKey; passphrase = ownerPassphrase; ownerKey = null; ownerPassphrase = null; }
        if (key is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(key);
        if (passphrase is not null) Array.Clear(passphrase);
        if (State.Vps is { KeyName: not null } or { KeyAsksPassphrase: true })
            Set(s => s with { Vps = s.Vps with { KeyName = null, KeyAsksPassphrase = false } });
    }

    /// <summary>**"SSH key · Choose key"** on the stop of a server that takes keys only (the owner's "Choose key, as Mac";
    /// picture 13d), and on the password's page of an SSH password, where the owner gives the password or the key (his
    /// "Key row here too", picture 14b; <see cref="VpsView.TakesKey"/>): the bytes of the one file that the owner picked in
    /// Windows' own picker (at most 64 KiB), and its name for the row. The file is checked before any connection, off the
    /// caller's thread (<see cref="OwnerKeyFile.Check"/>): a file that is no key says its sentence and the row is empty
    /// again; a key with a passphrase shows the passphrase's field; a key with none is its own press and puts this PC's
    /// key on the server at once. The model takes <paramref name="file"/>: the caller lets go of its copy. Anywhere else
    /// (the password's page of a <c>sudo</c> password among them), and while a call runs, the bytes are cleared and
    /// nothing is done.</summary>
    public async Task ChooseKey(byte[] file, string name)
    {
        if (State.Vps is not { TakesKey: true, Target: { } target } || file.Length > OwnerKeyFile.MaxLength || BeginVps() is not { } cancel)
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(file);
            return;
        }
        try
        {
            ClearKey();
            var check = await Task.Run(() => OwnerKeyFile.Check(file, null), cancel).ConfigureAwait(false);
            if (check is OwnerKeyCheck.NotAKey)
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(file);
                Set(s => s with { Vps = s.Vps with { KeyName = null, KeyAsksPassphrase = false, KeyWarning = SetupScreens.NotAKey } });
                return;
            }
            lock (gate) ownerKey = file;
            Set(s => s with { Vps = s.Vps with { KeyName = name, KeyAsksPassphrase = check is not OwnerKeyCheck.Usable, KeyWarning = null } });
            if (check is OwnerKeyCheck.Usable) await AddWithKeyAsync(target, null, cancel).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { ClearKey(); }
        catch (Exception) { System.Security.Cryptography.CryptographicOperations.ZeroMemory(file); Failed(target); }
        finally { EndVps(cancel); }
    }

    /// <summary>**The passphrase of the chosen key** (W14, "One field, only then"): a passphrase that does not open the key
    /// says its sentence under the field, which is empty again, and no call goes to the server; one that opens it puts
    /// this PC's key on the server. The model takes the array and clears it with the key.</summary>
    public async Task GiveKeyPassphrase(char[] passphrase)
    {
        byte[]? key;
        lock (gate) key = ownerKey;
        if (key is null || State.Vps is not { KeyAsksPassphrase: true, TakesKey: true, Target: { } target } || passphrase.Length == 0 || BeginVps() is not { } cancel)
        {
            Array.Clear(passphrase);
            return;
        }
        try
        {
            var check = await Task.Run(() => OwnerKeyFile.Check(key, passphrase), cancel).ConfigureAwait(false);
            if (check is not OwnerKeyCheck.Usable)
            {
                Array.Clear(passphrase);
                var notAKey = check is OwnerKeyCheck.NotAKey;
                if (notAKey) ClearKey();
                Set(s => s with { Vps = s.Vps with { KeyWarning = notAKey ? SetupScreens.NotAKey : SetupScreens.WrongPassphrase } });
                return;
            }
            lock (gate) ownerPassphrase = passphrase;
            Set(s => s with { Vps = s.Vps with { KeyWarning = null } });
            await AddWithKeyAsync(target, null, cancel).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { ClearKey(); }
        catch (Exception) { Array.Clear(passphrase); Failed(target); }
        finally { EndVps(cancel); }
    }

    /// <summary>The chosen key goes, with its passphrase and its name.</summary>
    public void ForgetKey()
    {
        ClearKey();
        Set(s => s with { Vps = s.Vps with { KeyWarning = null } });
    }

    /// <summary>**One call with the owner's key, then the app's own key alone** (<see cref="PasswordOnce.KeyAsync"/>): the
    /// call gets copies of the key and its passphrase, which it clears; the model clears its own when the call ends well
    /// or the server refuses the key. A user that is not root and whose sudo asks for its password gets that password asked
    /// once, and the same call goes again with it on its input's first line; the key stays for that one call.</summary>
    private async Task AddWithKeyAsync(InstallTarget target, char[]? sudo, CancellationToken cancel)
    {
        byte[] file;
        char[]? passphrase;
        lock (gate)
        {
            if (ownerKey is null) { if (sudo is not null) Array.Clear(sudo); return; }
            file = (byte[])ownerKey.Clone();
            passphrase = ownerPassphrase is null ? null : (char[])ownerPassphrase.Clone();
        }
        Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Checking, KeyWarning = null } });
        PasswordOnce.Outcome outcome;
        try
        {
            outcome = await PasswordOnce.KeyAsync(settings.Remote, target, new RemoteLogin.KeyOnce(file, passphrase), sudo, AppPublicLine(), cancel)
                                        .ConfigureAwait(false);
        }
        finally
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(file);
            if (passphrase is not null) Array.Clear(passphrase);
        }
        switch (outcome)
        {
            case PasswordOnce.Outcome.Refused refused when sudo is null && target.User != "root" && refused.Says == ServerCheck.NotRoot(target.User):
                // The sudo of that user asks for its password: asked once, as the Mac's PasswordNeed.sudo.
                Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Password, Need = ServerCheck.PasswordNeed.Sudo, Why = null } });
                return;
            case PasswordOnce.Outcome.Refused refused:
                // The page that the key was chosen on shows again, its row empty, with the sentence under it: the stop of a
                // server that takes keys only, or the password's page of an SSH password.
                ClearKey();
                Set(s => s with
                {
                    Vps = s.Vps.KeysOnly
                        ? s.Vps with { Phase = VpsPhase.Stopped, KeyWarning = refused.Says }
                        : s.Vps with { Phase = VpsPhase.Password, Need = ServerCheck.PasswordNeed.Ssh, Why = null, KeyWarning = refused.Says },
                });
                return;
            case PasswordOnce.Outcome.Ready ready:
                ClearKey();
                if (ready.KeepsPassword && sudo is not null) lock (gate) { sudoPassword = sudo; }
                Set(s => s with { Vps = s.Vps with { HoldsSudo = HoldsSudo(), KeysOnly = false } });
                await ReadVpsAsync(target, cancel).ConfigureAwait(false);
                return;
        }
    }

    private void ClearSudo()
    {
        char[]? old;
        lock (gate) { old = sudoPassword; sudoPassword = null; }
        if (old is not null) Array.Clear(old);
    }

    private CancellationToken? BeginVps()
    {
        lock (gate)
        {
            if (vpsWork is not null) return null;
            vpsWork = new CancellationTokenSource();
            return vpsWork.Token;
        }
    }

    private void EndVps(CancellationToken token)
    {
        lock (gate) if (vpsWork is not null && vpsWork.Token == token) { vpsWork.Dispose(); vpsWork = null; }
    }

    /// <summary>**Any VPS, by its address**: one check with the app's own key, a busy server read again every 15 seconds,
    /// then Install, the password once, or one orange line of why not. The PC takes an address or
    /// <c>user@address:port</c>; it reads no SSH config, so it takes no alias.</summary>
    public async Task CheckVpsAsync(string address)
    {
        var typed = address.Trim();
        if (typed.Length == 0 || BeginVps() is not { } cancel) return;
        try
        {
            var target = Target(typed);
            ClearKey();
            Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Checking, Address = typed, Target = target, Why = null, KeysOnly = false, KeyWarning = null } });
            if (target.Problem is { } problem)
            {
                Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Stopped, Why = problem } });
                return;
            }
            await ReadVpsAsync(target, cancel).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        catch (Exception) { Failed(State.Vps.Target); }
        finally { EndVps(cancel); }
    }

    /// <summary>"root@203.0.113.10:2222" as the server, its user and its port; a user that is not root becomes root with
    /// <c>sudo</c>. The owner typed the port, so it is the owner's for that host (<see cref="InstallTarget.PortGivenFor"/>).</summary>
    internal static InstallTarget Target(string typed)
    {
        var user = "root";
        var rest = typed;
        if (rest.LastIndexOf('@') is var at and > 0) { user = rest[..at]; rest = rest[(at + 1)..]; }
        var port = 22;
        if (!rest.StartsWith('[') && rest.Count(c => c == ':') == 1 && int.TryParse(rest[(rest.IndexOf(':') + 1)..], out var given))
        {
            port = given;
            rest = rest[..rest.IndexOf(':')];
        }
        var host = rest.Trim('[', ']');
        return new InstallTarget(host, user, port, user != "root") { PortGivenFor = host };
    }

    /// <summary>One check, and a busy server read again every fifteen seconds until it says something else.</summary>
    private async Task ReadVpsAsync(InstallTarget target, CancellationToken cancel)
    {
        // Each check logs in with the app's own key: a PC that has made no server at a provider has none yet, and
        // SshRemote takes no call with a key that is not there (the title stood at "Checking" for ever). Every way to a
        // check passes here: the address, Try again, the password once and the owner's key.
        AppPublicLine();
        while (!cancel.IsCancellationRequested)
        {
            var result = await ServerCheck.RunAsync(settings.Remote, target, InstallJob.Hub, new RemoteLogin.AppKey(), HoldsSudo(),
                                                    State.Pc?.Tailnet, firstRun: true, Policy(), cancel).ConfigureAwait(false);
            switch (result.Verdict)
            {
                case ServerCheck.Verdict.Ready ready:
                    ClearKey();
                    Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Ready, Summary = ready.Summary, Changes = ready.Changes, Why = null } });
                    return;
                case ServerCheck.Verdict.NeedsPassword needs:
                    Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Password, Need = needs.Need, Why = null, KeysOnly = false } });
                    return;
                case ServerCheck.Verdict.KeysOnly keys:
                    // The server named its ways, and no password way: the key's stop at once, with no password try.
                    Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Stopped, Why = keys.Says, KeysOnly = true } });
                    return;
                case ServerCheck.Verdict.Stop stop:
                    Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Stopped, Why = stop.Says, KeysOnly = false } });
                    return;
                case ServerCheck.Verdict.Wait wait:
                    Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Waiting, Why = wait.Says, KeysOnly = false } });
                    await settings.Pause(TimeSpan.FromSeconds(15), cancel).ConfigureAwait(false);
                    break;
            }
        }
    }

    private bool HoldsSudo() { lock (gate) return sudoPassword is not null; }

    /// <summary>**The password, once**: the app's own key goes onto the server, then the check runs again with that key.
    /// The array is cleared here, unless the server's <c>sudo</c> asks for it, when the install that follows takes it and
    /// clears it when it ends. A key that the server does not take says its sentence. An SSH password is the owner's way
    /// in of the two on its page: a key chosen there goes, with its passphrase and its name.</summary>
    public async Task GivePasswordAsync(char[] password)
    {
        var s = State;
        if (s.Vps is not { Phase: VpsPhase.Password, Need: { } need, Target: { } target } || password.Length == 0 || BeginVps() is not { } cancel)
        {
            Array.Clear(password);
            return;
        }
        try
        {
            if (need == ServerCheck.PasswordNeed.Sudo && HoldsOwnerKey)
            {
                var given = password;
                password = [];
                await AddWithKeyAsync(target, given, cancel).ConfigureAwait(false);
                return;
            }
            if (need == ServerCheck.PasswordNeed.Ssh) ClearKey();
            Set(x => x with { Vps = x.Vps with { Phase = VpsPhase.Checking, KeyWarning = null } });
            var outcome = await PasswordOnce.RunAsync(settings.Remote, target, need, password, AppPublicLine(), cancel).ConfigureAwait(false);
            if (outcome is PasswordOnce.Outcome.Refused refused)
            {
                Set(x => x with { Vps = x.Vps with { Phase = VpsPhase.Stopped, Why = refused.Says, KeysOnly = refused.Says == ServerCheck.KeysOnly(target.Host) } });
                return;
            }
            if (outcome is PasswordOnce.Outcome.Ready { KeepsPassword: true })
                lock (gate) { sudoPassword = password; password = []; }
            Set(x => x with { Vps = x.Vps with { HoldsSudo = HoldsSudo() } });
            await ReadVpsAsync(target, cancel).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        catch (Exception) { Failed(target); }
        finally
        {
            if (password.Length > 0 && !ReferenceEquals(password, sudoPassword)) Array.Clear(password);
            EndVps(cancel);
        }
    }

    /// <summary>Try again of a stop on Other VPS: the same server checked again.</summary>
    public async Task VpsAgainAsync()
    {
        if (State.Vps.Target is not { } target) { ResetVps(); return; }
        if (BeginVps() is not { } cancel) return;
        try
        {
            Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Checking, Why = null } });
            await ReadVpsAsync(target, cancel).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        catch (Exception) { Failed(target); }
        finally { EndVps(cancel); }
    }

    /// <summary>**A way of Other VPS that threw** (a box that does not open, a call that the remote refuses): the stop of
    /// a server not reached, in the Mac's words (its <c>ServerCheck.run</c> turns each error into that stop), and the
    /// owner's key and its passphrase go. The title never stands at "Checking" with no end.</summary>
    private void Failed(InstallTarget? target)
    {
        ClearKey();
        var host = target?.Host ?? State.Vps.Host;
        Set(s => s with { Vps = s.Vps with { Phase = VpsPhase.Stopped, Why = ServerCheck.Unreached(host), KeysOnly = false, KeyWarning = null } });
    }

    /// <summary>Install of Other VPS, after a check that passed.</summary>
    public void InstallVps()
    {
        if (State.Vps is not { Phase: VpsPhase.Ready, Target: { } target }) return;
        char[]? sudo;
        lock (gate) { sudo = sudoPassword; sudoPassword = null; }
        Set(s => s with { HubBuilt = false });
        StartInstall(target, sudo);
    }

    // ---------------------------------------------------------------- the hub's install and the manager's join

    /// <summary>**Try again of a stopped install, and Install again after a new key of the network** (the Mac's
    /// <c>install.installHub(store:)</c> from the install's page): the same install on the same server, from its first
    /// step. A sudo password that the first try held is gone (the try cleared it), as on the Mac. Nothing while an install
    /// runs, or with no install that stopped.</summary>
    public void InstallAgain()
    {
        var s = State;
        InstallTarget? target;
        lock (gate) target = installed;
        if (s.Page != SetupPage.Installing || s.Install.Running || s.Install.Failure is null || target is null) return;
        StartInstall(target, null);
    }

    /// <summary>**"Open Founderizer" under checks that did not pass** (the Mac's <c>afterInstall</c> and <c>openApp</c>,
    /// which is its <c>finish</c>): the hub claimed itself from this PC and answers it, so the window goes on to the
    /// manager's setup as after checks that passed. The hand-over then comes by its own rule: once the manager's own server
    /// neither joins nor waits for the owner's choice. Nothing while the button does not show.</summary>
    public void OpenApp()
    {
        var s = State;
        if (s.Page != SetupPage.Installing || s.Install.Running || s.Install.Checklist is null || s.Install.Passed || !s.HubAnswers ||
            s.HandedOver || s.OpenAsked) return;
        Set(x => x with { OpenAsked = true });
    }

    private Installer MakeInstaller(InstallPlan plan, string? authKey, char[]? sudo) =>
        settings.Installer?.Invoke(plan, authKey, sudo) ??
        Installer.For(plan, settings.Hub, settings.Box, authKey, sudo, firstRun: true, Policy());

    /// <summary>**The hub's install** (the Mac's <c>startInstall</c> and <c>installHub</c>): a fresh install record, a join
    /// key from the fleet's key, the plan with the manager's name in the installer's form (<see cref="SetupState.HubName"/>),
    /// one server for all, the slider's step and the chosen AI; up to three tries for a stop that passes (the Mac's
    /// <c>tries</c>, but never after a sudo password, which a try clears). At the claim, this PC becomes the owner's
    /// computer of the new hub.</summary>
    private void StartInstall(InstallTarget target, char[]? sudo)
    {
        CancellationTokenSource source;
        lock (gate)
        {
            if (installWork is not null) { if (sudo is not null) Array.Clear(sudo); return; }
            installWork = source = new CancellationTokenSource();
            installed = target;
        }
        Set(s => s with
        {
            ManagersRefusal = null, ManagersFull = new HashSet<CloudProvider>(), ManagersMoreShown = false, OpenAsked = false,
            Install = new InstallView(true, [], [], settings.Now(), null, null, null, false),
            ManagerInstall = s.ManagerInstall.Running ? s.ManagerInstall : InstallView.None,
        });
        Go(SetupPage.Installing);
        _ = Task.Run(() => RunHubInstallAsync(target, sudo, source.Token));
    }

    private async Task RunHubInstallAsync(InstallTarget target, char[]? sudo, CancellationToken cancel)
    {
        var s = State;
        var log = new InstallLog(InstallKind.Hub, null, target.Host, settings.Records.Installs.Launch, settings.Now());
        void Keep() => settings.Records.Installs.Write(log.Record);
        Keep();
        var tries = 0;
        var usedSudo = sudo is not null;
        try
        {
            while (true)
            {
                tries++;
                string? authKey = null;
                FleetKeyException? keyRefused = null;
                try
                {
                    if (settings.Tailscale.IsHeld) authKey = await settings.Tailscale.AuthKeyAsync("hub", TailscaleApi.KeyLifeSeconds, cancel).ConfigureAwait(false);
                }
                catch (FleetKeyException refused) { keyRefused = refused; }
                var plan = InstallPlan.Hub(target, InstallPlan.DefaultSource, authKey, s.HubName, s.OneServer, s.Shaped ? s.ServersStep : null, s.ChosenAi);
                log.Hide(plan.Redactions);
                Set(x => x with { Install = x.Install with { Planned = plan.Steps.Select(p => p.Id).ToList() } });
                var installer = MakeInstaller(plan, authKey, sudo);
                sudo = null;            // the installer clears it when it ends
                var failed = new InstallRetry.FailedStep();
                try
                {
                    if (keyRefused is not null) throw keyRefused;
                    var checklist = await installer.RunAsync(settings.Remote, progress =>
                    {
                        failed.Note(progress);
                        if (log.Note(progress.Step, Recorded(progress.State), settings.Now())) Keep();
                        Set(x => x with { Install = x.Install.Reported(progress, settings.Now()) });
                        if (progress is { Step: "claim", State: ProgressState.Done } && installer.ClaimedHub is { } hub) Claimed(hub, log, Keep);
                    }, cancel).ConfigureAwait(false);
                    if (log.Done(settings.Now())) Keep();
                    Set(x => x with { Install = x.Install with { Running = false, Checklist = checklist } });
                    return;
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    var stopped = InstallRetry.StoppedBy(error, keyRefused is not null, authKey is null);
                    var again = InstallRetry.Decision(stopped.Stop, stopped.Cause, InstallJob.Hub, failed.Value, tries, stopped.NeedsNetworkKey, usedSudo);
                    if (again is null)
                    {
                        var words = error is InstallError install ? install.Plain(target.Host) : error.Message;
                        if (log.Stop(stopped.Stop, InstallRecord.WordsOf(error, target.Host), stopped.Cause, stopped.NeedsNetworkKey, settings.Now())) Keep();
                        Set(x => x with
                        {
                            Install = x.Install with { Running = false, Failure = words, NeedsNetworkKey = stopped.NeedsNetworkKey, NetworkFailure = keyRefused?.Message },
                            FleetKeyEnded = x.FleetKeyEnded || keyRefused is { Failure: FleetKeyFailure.FleetKeyEnded },
                            Key = KeyView.Start,
                        });
                        return;
                    }
                    if (log.Retry(stopped.Stop, stopped.Cause)) Keep();
                    await InstallRetry.WaitAsync(again.Waits, () => settings.Pause(TimeSpan.FromSeconds(InstallRetry.ReadEvery), cancel), () => Task.FromResult(false),
                                                 () => cancel.IsCancellationRequested).ConfigureAwait(false);
                    cancel.ThrowIfCancellationRequested();
                    Set(x => x with { Install = x.Install with { Steps = [] } });
                }
            }
        }
        catch (OperationCanceledException)
        {
            if (log.Cancel(settings.Now())) Keep();
            Set(x => x with { Install = x.Install with { Running = false } });
        }
        finally
        {
            if (sudo is not null) Array.Clear(sudo);
            lock (gate) { installWork?.Dispose(); installWork = null; }
        }
    }

    private static RecordStepState Recorded(ProgressState state) => state switch
    {
        ProgressState.Done => RecordStepState.Done,
        ProgressState.Failed => RecordStepState.Failed,
        _ => RecordStepState.Running,
    };

    /// <summary>**The claim step ended well**: this PC is the owner's computer of the new hub, its record has the hub's
    /// address, and the manager's own server joins as soon as the hub answers.</summary>
    private void Claimed(Uri hub, InstallLog log, Action keep)
    {
        var address = hub.ToString();
        if (log.Place(hub: address)) keep();
        Set(s => s with { Install = s.Install with { ClaimedHub = address } });
        _ = Task.Run(async () =>
        {
            try { await (settings.ConnectOwner?.Invoke(hub) ?? settings.Owner.ConnectOwnerAsync(hub)).ConfigureAwait(false); }
            catch (Exception e) when (e is ArgumentException or InvalidOperationException) { }
            StartManagersJoin();
            await DeliverReportsAsync().ConfigureAwait(false);
        });
    }

    /// <summary>**The first run's answer on "Help improve Founderizer" goes to the new hub** (the Mac's
    /// <c>FirstRunReports.deliver</c>): once a hub offers <c>error_reports</c>, and only its receipt ends the wait.</summary>
    internal async Task<bool> DeliverReportsAsync()
    {
        if (Answer(settings.Choices.Get(SetupChoiceNames.ReportsWaiting)) is not { } send || FleetNow()?.Offers("error_reports") != true)
            return false;
        try
        {
            var answer = await Calls().PostAsync("ui/error-reports", new ErrorReportsAsk(send), SetupJson.Default.ErrorReportsAsk,
                                                 SetupJson.Default.ErrorReportsReceipt, Guid.NewGuid(), CancellationToken.None).ConfigureAwait(false);
            if (answer.Value is null) return false;
        }
        catch (HubException) { return false; }
        if (Answer(settings.Choices.Get(SetupChoiceNames.ReportsWaiting)) == send) settings.Choices.Set(SetupChoiceNames.ReportsWaiting, null);
        return true;
    }

    /// <summary>**The manager's join starts once the hub has claimed itself** (the Mac's <c>startManagersJoin</c>): when
    /// the new hub answers this PC and the manager's own server is on the private network, the join goes to that hub while
    /// the hub's own install ends. A count of reads ends the wait (no clock ends work), and so does a stop of the hub's
    /// install; the manager's setup then installs the server.</summary>
    private void StartManagersJoin()
    {
        var s = State;
        if (!s.MakesManagersServer || s.Install.ClaimedHub is null || s.ManagersServer?.Address is null) return;
        CancellationTokenSource source;
        lock (gate)
        {
            if (joinWork is not null || s.ManagerInstall.Running || s.ManagerInstall.Checklist is not null) return;
            joinWork = source = new CancellationTokenSource();
        }
        _ = Task.Run(() => RunJoinAsync(source.Token));
    }

    private async Task RunJoinAsync(CancellationToken cancel)
    {
        try
        {
            for (var read = 0; read < settings.JoinReads; read++)
            {
                if (read > 0) await settings.Pause(settings.JoinReadEvery, cancel).ConfigureAwait(false);
                var s = State;
                if (s.Install.Failure is not null || s.ManagerInstall.Failure is not null || s.HandedOver || s.Page != SetupPage.Installing) return;
                if (s.ManagersServer is not { Address: { } address } server || FleetNow() is null) continue;
                await JoinAsync(new InstallTarget(address), server.Name, s.Install.ClaimedHub!, cancel).ConfigureAwait(false);
                return;
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            lock (gate) { joinWork?.Dispose(); joinWork = null; }
            HandOverIfDue();
        }
    }

    /// <summary>The words of a join whose hub gave no line (the Mac's <c>installMachine</c>).</summary>
    public const string NoJoinLine = "The hub gave no join line. Try again.";

    /// <summary>One join of a server to the hub that this PC owns: the hub's one-time line, a key of the fleet's for this
    /// one server, and the plan of the Mac's join.</summary>
    private async Task JoinAsync(InstallTarget target, string name, string hub, CancellationToken cancel)
    {
        var log = new InstallLog(InstallKind.Join, hub, target.Host, settings.Records.Installs.Launch, settings.Now());
        void Keep() => settings.Records.Installs.Write(log.Record);
        Set(s => s with { ManagerInstall = new InstallView(true, [], [], settings.Now(), null, null, null, false, name, hub) });
        Keep();
        try
        {
            var join = (await OwnerReads.JoinCodeAsync(Calls(), cancel: cancel).ConfigureAwait(false)).Value;
            if (join is not { Line: { } line, Code: { } code }) throw InstallError.CannotStart(NoJoinLine);
            string? authKey = null;
            try { if (settings.Tailscale.IsHeld) authKey = await settings.Tailscale.AuthKeyAsync(target.Host, TailscaleApi.KeyLifeSeconds, cancel).ConfigureAwait(false); }
            catch (FleetKeyException) when (NetworkSignIn.Tags(line).Count > 0) { }
            var plan = InstallPlan.Join(target, line, code, authKey);
            log.Hide(plan.Redactions);
            Set(s => s with { ManagerInstall = s.ManagerInstall with { Planned = plan.Steps.Select(p => p.Id).ToList() } });
            // The plan's key step sends the installer's key: the same key, or the server never reaches the private network.
            var checklist = await new Installer(plan, authKey, clock: settings.JoinClock).RunAsync(settings.Remote, progress =>
            {
                if (log.Note(progress.Step, Recorded(progress.State), settings.Now())) Keep();
                Set(s => s with { ManagerInstall = s.ManagerInstall.Reported(progress, settings.Now()) });
            }, cancel).ConfigureAwait(false);
            if (log.Done(settings.Now())) Keep();
            Set(s => s with { ManagerInstall = s.ManagerInstall with { Running = false, Checklist = checklist } });
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error)
        {
            var stopped = InstallRetry.StoppedBy(error, false, true);
            if (log.Stop(stopped.Stop, InstallRecord.WordsOf(error, target.Host), stopped.Cause, false, settings.Now())) Keep();
            Set(s => s with { ManagerInstall = s.ManagerInstall with { Running = false, Failure = error is InstallError e ? e.Plain(target.Host) : error.Message } });
        }
    }

    // ---------------------------------------------------------------- the hand-over

    /// <summary>The manager that the hand-over gave a provider or a joined server to, for the manager's setup: the
    /// server that joined for it, the provider that the owner chose in this first run, whether its sign-in was asked, and
    /// the manager's own server that this run made and that did not join, which the manager's setup installs (the Mac's
    /// <c>FleetStore.noteJoined</c>, <c>noteProvider</c> and <c>noteMadeServer</c>).</summary>
    public sealed record Handover(string Manager, string? Provider, string? Joined, bool SignInAsked, MadeServer? Made = null);

    private Handover? handover;

    /// <summary>What the first run gave the manager's setup, once it handed the window over.</summary>
    public Handover? HandedOver { get { lock (gate) return handover; } }

    /// <summary>The hand-over runs now: two asks at once start one, and ask for the sign-in once. It is cleared when the
    /// hand-over ends, however it ends; a hand-over that ended stops a second one by <see cref="SetupState.HandedOver"/>,
    /// which Start again takes away with the rest of the run.</summary>
    private int handing;

    /// <summary>A join of the manager's own server runs now, or waits for the new hub to answer.</summary>
    private bool JoinWorks { get { lock (gate) return joinWork is not null; } }

    /// <summary>**On to the manager's setup by itself, decided at each change that can make it true** (the Mac's
    /// <c>.onChange(of: checked &amp;&amp; passed &amp;&amp; store.state != nil &amp;&amp; !managerInstall.running &amp;&amp; !managersHolds)</c>
    /// of the install page): the hub's install ended with its checks passed, the new hub answers this PC, and the
    /// manager's own server neither builds, nor joins, nor waits for the owner's choice of it that can still lead on. A
    /// state of the store, a reading of the owner's store and the end of the join's wait each ask again. Stricter than the
    /// Mac in one point: it waits for the join's wait for the new hub too (a count of reads), so that a hand-over never
    /// comes between that wait's reads and leaves the manager's server unjoined.</summary>
    private void HandOverIfDue()
    {
        KeepClaimedMark();
        var s = State;
        if (s.HandedOver || s.Page != SetupPage.Installing || s.Install.Running || s.Install.Checklist is null || !(s.Install.Passed || s.OpenAsked)) return;
        if (s.ManagerInstall.Running || JoinWorks || ManagersHolds || FleetNow() is null) return;
        if (Interlocked.Exchange(ref handing, 1) == 1) return;
        _ = Task.Run(async () =>
        {
            try { await FinishAsync().ConfigureAwait(false); }
            finally { Interlocked.Exchange(ref handing, 0); }
        });
    }

    /// <summary>Asks the hand-over again (for a test: the window's changes ask by themselves).</summary>
    internal void Recheck() => HandOverIfDue();

    /// <summary>One write of the manager's mark at a time from this run, and none from a change of the run once the
    /// hand-over wrote it, or while Start again takes it away.</summary>
    private readonly object markGate = new();
    private bool marksEnded;

    /// <summary>**The manager's first setup is this PC's to show from the claim on** (the read of U3, fault 1): the hub's
    /// install claims the hub minutes before it ends, and an app that ends in that time (the window closed, an update, a
    /// restart of the PC) would start again as the owner's computer of a hub with no welcome page and no mark, on a chat
    /// that cannot answer. So each change of this run after the claim keeps the mark of the claimed hub as its reading
    /// gives it: its generation, the manager, the provider that the owner chose and, once the manager's own server joined
    /// that hub, that server (the Mac's <c>noteJoined</c>), or, while it did not, that server with its address on the private
    /// network (<see cref="MadeHere"/>, the Mac's <c>noteMadeServer</c>): an app that ends while that server joins, or waits
    /// to, would lose the paid server, and no later start runs this run again. The setup uses the provider and the servers
    /// only while its own read says that the manager has no server. The hand-over writes the mark last, and no change of this run writes it
    /// after that: the setup then changes it, and takes it away when the manager runs.</summary>
    private void KeepClaimedMark()
    {
        var s = State;
        if (s.HandedOver || s.Install.ClaimedHub is not { } claimed || !Uri.TryCreate(claimed, UriKind.Absolute, out var hub)) return;
        if (FleetNow() is not { } fleet || fleet.Agents.FirstOrDefault(a => a.Role == "manager") is not { } manager) return;
        var joined = JoinedHere(s);
        var mark = new ManagerSetupMark(hub, fleet.Db, manager.Name, s.ChosenAi, joined, MadeHere(s, joined));
        // A reading of another hub than the claimed one, which the owner's store held a moment before the claim, is none.
        if (settings.Owner.State.Hub is { } reads && !mark.IsOf(reads)) return;
        lock (markGate)
            if (!marksEnded) mark.KeepChanged(settings.Choices);
    }

    /// <summary>The manager's own server that joined the claimed hub in this run, or null.</summary>
    private static string? JoinedHere(SetupState s) =>
        s.ManagerInstall.Checklist is not null && s.ManagerInstall.JoinHub == s.Install.ClaimedHub ? s.ManagerInstall.Server ?? s.ManagersServer?.Name : null;

    /// <summary>The manager's own server that this run made, that is on the private network and that did not join, for the
    /// mark (<paramref name="joined"/>: the server that joined, or null); else null.</summary>
    private static FirstRunServer? MadeHere(SetupState s, string? joined) =>
        joined is null && s.ManagersServer is { Address: { } at } own ? new FirstRunServer(own.Name, at) : null;

    /// <summary>**Into the app, at the manager's setup** (the Mac's <c>finish</c>): the manager's AI provider that the owner
    /// chose in this first run is not asked again. A manager with no server gets it with its server; a manager that the
    /// installer put on the hub's own server with that program gets its sign-in now.</summary>
    internal async Task FinishAsync()
    {
        var fleet = FleetNow();
        var manager = fleet?.Agents.FirstOrDefault(a => a.Role == "manager");
        var name = manager?.Name ?? "manager";
        bool? placed = null;
        try
        {
            if (manager is not null && fleet!.Offers("servers") && (await OwnerReads.ServersAsync(Calls()).ConfigureAwait(false)).Value is { } list)
                placed = list.ServerOf(name) is not null;
        }
        catch (Exception e) when (e is HubException or InvalidOperationException or System.Text.Json.JsonException) { }
        var s = State;
        var joined = placed == false && s.ManagerInstall.Checklist is not null && s.ManagerInstall.JoinHub == s.Install.ClaimedHub
            ? s.ManagerInstall.Server ?? s.ManagersServer?.Name
            : null;
        var decision = FirstRunHandover.Of(s.ChosenAi, placed, manager?.Runtime, s.Began && s.OneServer, writes: true, asked: signsIn);
        var asked = false;
        if (decision is FirstRunHandover.SignIn signIn)
        {
            signsIn = true;
            try
            {
                await OwnerReads.SignInAsync(Calls(), name, signIn.Provider).ConfigureAwait(false);
                asked = true;
            }
            catch (Exception e) when (e is HubException or InvalidOperationException or ArgumentException) { }
        }
        var made = placed == false && joined is null && s.ManagersServer is { Address: not null } server ? server : null;
        var provider = (decision as FirstRunHandover.Keep)?.Provider ?? s.ChosenAi;
        // **The manager's first setup is this PC's to show until the manager runs** (the Mac's `noteFirstSetup`,
        // `noteJoined` and `noteProvider`, under the hub's address, its generation and the manager's name): kept, so that
        // an app that starts again during its install or its sign-in opens on that page, and not on a chat that cannot
        // answer yet. A manager with no server gets the chosen provider with the server that joined for it. They are kept
        // also when the read of the servers did not answer here (`placed` null): the setup uses them only while its own
        // read says that the manager has no server, and without them it would ask for the provider again and never give
        // the manager the server that joined for it.
        var markJoined = placed != true ? JoinedHere(s) : null;
        // The manager's own server that this run made and that did not join, which the setup installs by itself once, also
        // after a start of the app (the Mac's `noteMadeServer`).
        var markMade = placed != true ? MadeHere(s, markJoined) : null;
        lock (markGate)
        {
            marksEnded = true;
            if (fleet is not null && s.Install.ClaimedHub is { } claimed && Uri.TryCreate(claimed, UriKind.Absolute, out var hubAddress))
                new ManagerSetupMark(hubAddress, fleet.Db, name, placed != true ? provider : null, markJoined, markMade).Keep(settings.Choices);
        }
        lock (gate) handover = new Handover(name, provider, joined, asked, made);
        Set(x => x with { HandedOver = true, HandedTo = name });
    }

    // ---------------------------------------------------------------- Back, and a try again

    /// <summary>**A build or an install that runs has no Back**, as Add server's has none: leaving it would leave a server
    /// half made at its provider, or the password of a sudo that the running install still holds.</summary>
    public bool Runs
    {
        get
        {
            var s = State;
            if (s.Page == SetupPage.Token && s.CloudBuilds) return true;
            if (s.Page != SetupPage.Installing) return false;
            return s.Install.Running || s.ManagerInstall.Running || ManagersHolds && ShowsBuild;
        }
    }

    /// <summary>**The build page shows the install** while the fleet builds with nothing for the owner to do or read.</summary>
    public bool ShowsBuild
    {
        get
        {
            var s = State;
            if (!s.Shaped || s.Page != SetupPage.Installing) return false;
            // Tailscale's link of an install that waits for the owner's yes is the install's own page (the Mac's
            // `showsBuild`): the build page has no place for it.
            var clear = s.Install.Failure is null && !s.Install.NeedsNetworkKey && s.Install.NetworkSignIn is null && s.ManagerInstall.NetworkSignIn is null;
            return clear && (s.Install.Running || (s.ManagerInstall.Running || ManagersHolds) && s.Install.Checklist is not null);
        }
    }

    /// <summary>One step back (the Mac's <c>back</c>); nothing while a build or an install runs.</summary>
    public void Back()
    {
        var s = State;
        if (s.Page == SetupPage.Welcome || Runs) return;
        switch (s.Page)
        {
            case SetupPage.ErrorReports: Go(SetupPage.Welcome); break;
            case SetupPage.Name: Go(SetupPage.ErrorReports); break;
            case SetupPage.AiProvider: Go(SetupPage.Name); break;
            case SetupPage.Servers: Go(SetupPage.AiProvider); break;
            case SetupPage.Network or SetupPage.Key: Go(s.Named && s.After == SetupPage.Cloud ? SetupPage.Servers : SetupPage.Cloud); break;
            case SetupPage.Token when s.ManagersToken is not null:
                Set(x => x with { ManagersToken = null, ManagersProvider = null });
                managersCloud.Cancel();
                OpensManagersChoice();
                break;
            case SetupPage.Token:
                hubCloud.Cancel();
                if (managersCloud.Now.Stage == CloudStep.Stage.Choosing) managersCloud.Cancel();
                Set(x => x with { ManagersProvider = null });
                Go(SetupPage.Cloud);
                break;
            case SetupPage.Vps:
                ResetVps();
                Go(SetupPage.Cloud);
                break;
            case SetupPage.Installing when s.ManagersToken is not null && ShowsBuild:
                Set(x => x with { ManagersToken = null, ManagersProvider = null });
                managersCloud.Cancel();
                if (hubCloud.Now.Provider is { } hubs && managersCloud.Holds(hubs)) _ = managersCloud.OpenAsync(hubs, CloudServerUse.Agent, lists: false);
                break;
            case SetupPage.Installing:
                Set(x => x with
                {
                    Install = InstallView.None,
                    ManagerInstall = x.ManagerInstall.Running ? x.ManagerInstall : InstallView.None,
                    ManagersToken = null, ManagersProvider = null, ManagersRefusal = null, OpenAsked = false,
                });
                if (managersCloud.Now is { Stage: CloudStep.Stage.Choosing, Stopped: CloudStep.Stage.Making }) managersCloud.Cancel();
                ResetVps();
                Go(SetupPage.Cloud);
                break;
            case SetupPage.Done: Go(SetupPage.Cloud); break;
            case SetupPage.Cloud when s.Named: Go(SetupPage.Servers); break;
            case SetupPage.Cloud: Go(SetupPage.Welcome); break;
        }
    }

    // ---------------------------------------------------------------- Start again

    /// <summary>**What "Start again" would take away for the hub at <paramref name="hub"/>** (the Mac's page before the
    /// press): the servers that this PC's records prove, read against each provider's list whose token this PC holds,
    /// and the machines that the private network still has.</summary>
    public async Task<StartAgain.Plan> StartAgainPlanAsync(string hub, CancellationToken cancel = default)
    {
        var builds = settings.Records.Builds.All();
        var listed = new Dictionary<CloudProvider, IReadOnlyList<CloudExisting>>();
        foreach (var provider in builds.Where(b => b.Hub == hub).Select(b => CloudProviders.FromRaw(b.Provider)).OfType<CloudProvider>().Distinct())
        {
            var cloud = settings.Cloud(provider);
            if (!cloud.IsHeld) continue;
            try { listed[provider] = await cloud.ServersAsync(cancel).ConfigureAwait(false); }
            catch (CloudException) { }
        }
        IReadOnlyList<FleetDevice>? devices = null;
        try { if (settings.Tailscale.IsHeld) devices = await settings.Tailscale.DevicesAsync(cancel).ConfigureAwait(false); }
        catch (FleetKeyException) { }
        var status = await settings.Status(cancel).ConfigureAwait(false);
        var own = StartAgain.OwnAddresses(status);
        var name = status is null ? null : PcNetwork.OwnName(status);
        var online = StartAgain.OnlineAddresses(status);
        var rivals = StartAgain.Rivals(hub, builds);
        var proven = StartAgain.ProvenFor(hub, builds, listed,
                                          build => devices is not null && StartAgain.IsAlive(build, devices, online, own, name, rivals));
        return StartAgain.Plan.Of(hub, proven, devices, own, name);
    }

    /// <summary>**The run of "Start again"**: the provider deletes each proven server by its id, then its firewalls and
    /// the app's key there, then the machines leave the private network, then the app forgets this fleet: its build and
    /// install records of this hub (and of no other), its record of the servers' host keys (<see cref="HostKeys.ForgetAll"/>,
    /// because the words of a changed host key name Start again as the way out), and the hub itself, so that the PC is
    /// one that was never given a hub (<see cref="OwnerStore.ForgetOwnedHub"/>; the key of the owner's computer goes only
    /// when the run deleted the hub's own server).</summary>
    public Task<IReadOnlyList<StartAgain.Step>> StartAgainRunAsync(StartAgain.Plan plan, IReadOnlyList<StartAgain.Step>? steps = null,
                                                                  Action<IReadOnlyList<StartAgain.Step>>? tell = null, CancellationToken cancel = default) =>
        StartAgain.RunAsync(steps ?? plan.Steps(), plan.Builds, plan.Rivals, new StartAgainWork(this, plan.Hub), tell, cancel);

    private readonly HashSet<string> deletedHere = new(StringComparer.Ordinal);

    private sealed class StartAgainWork(SetupStore store, string hub) : StartAgain.IWork
    {
        private SetupSettings S => store.settings;

        public Task<CloudDeletion> DeleteServerAsync(StartAgain.Server server, Action accepted, CancellationToken cancel) =>
            S.Cloud(server.Provider).DeleteAsync(server.ServerId, accepted, cancel);

        public Task DeleteFirewallsAsync(CloudProvider provider, string name, IReadOnlySet<string> deleted, CancellationToken cancel) =>
            S.Cloud(provider).DeleteFirewallsAsync(name, deleted, cancel);

        public Task DeleteKeyAsync(CloudProvider provider, CancellationToken cancel) =>
            S.Cloud(provider).DeleteKeyAsync(store.AppPublicLine(), cancel);

        public Task<IReadOnlyList<FleetDevice>> DevicesAsync(CancellationToken cancel) => S.Tailscale.DevicesAsync(cancel);

        public Task DeleteDeviceAsync(string id, CancellationToken cancel) => S.Tailscale.DeleteDeviceAsync(id, cancel);

        public async Task<(IReadOnlySet<string> Addresses, string? Name)> ThisPcAsync(CancellationToken cancel)
        {
            var status = await S.Status(cancel).ConfigureAwait(false);
            return (StartAgain.OwnAddresses(status), status is null ? null : PcNetwork.OwnName(status));
        }

        public async Task<IReadOnlySet<string>> OnlineAsync(CancellationToken cancel) =>
            StartAgain.OnlineAddresses(await S.Status(cancel).ConfigureAwait(false));

        public void NoteDeleted(CloudProvider provider, string id) { lock (store.deletedHere) store.deletedHere.Add(provider.Raw() + "|" + id); }
        public void ForgetDeleted(CloudProvider provider, string id) { lock (store.deletedHere) store.deletedHere.Remove(provider.Raw() + "|" + id); }
        public bool DeletedBefore(CloudProvider provider, string id) { lock (store.deletedHere) return store.deletedHere.Contains(provider.Raw() + "|" + id); }

        public Task ClearAppAsync(bool hubServerDeleted, CancellationToken cancel)
        {
            S.HostKeys.ForgetAll();
            S.Records.Builds.Remove(r => r.Hub == hub);
            S.Records.Installs.Remove(r => r.Hub == hub);
            S.Choices.Set(SetupChoiceNames.ReportsWaiting, null);
            // The manager's first setup of the hub that goes, which no window shows again; and no change of this run
            // keeps it again until the run starts as a first one.
            lock (store.markGate)
            {
                store.marksEnded = true;
                if (Agents.ManagerSetupMark.Read(S.Choices) is { } mark && Uri.TryCreate(hub, UriKind.Absolute, out var gone) && mark.IsOf(gone))
                    Agents.ManagerSetupMark.Forget(S.Choices);
            }
            // The run is over: the next first run of this app's run starts as a first one (the Mac's FirstRunWork.drop),
            // with no hand-over, no sign-in asked, no install to try again, no build or choice of a provider, no key.
            lock (store.gate) { store.handover = null; store.signsIn = false; store.installed = null; }
            store.hubCloud.Cancel();
            store.managersCloud.Cancel();
            store.ClearSudo();
            store.ClearKey();
            if (Uri.TryCreate(hub, UriKind.Absolute, out var address))
            {
                if (S.ForgetHub is { } forget) forget(address, hubServerDeleted);
                else S.Owner.ForgetOwnedHub(address, hubServerDeleted);
            }
            store.Set(_ => new SetupState { HoldsFleetKey = S.Tailscale.IsHeld, Cloud = store.hubCloud.Now, ManagersCloud = store.managersCloud.Now });
            lock (store.markGate) store.marksEnded = false;
            return Task.CompletedTask;
        }
    }

    /// <summary>**A server that the app made is deleted** (a step that failed, a try again, Start again): the PC forgets
    /// the host key of each address at which it reached that server over SSH, so that a later server at the same address
    /// does not stop with the words of a changed host key. For a provider's server that is its address on the private
    /// network only: its firewall lets nothing in at its public address.</summary>
    public void ForgetServer(IEnumerable<string> addresses)
    {
        foreach (var address in addresses) settings.HostKeys.Forget(address, 22);
    }
}
