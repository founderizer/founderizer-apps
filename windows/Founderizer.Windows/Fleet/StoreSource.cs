using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Remote;
using Founderizer.Setup.Agents;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Network;

namespace Founderizer.Windows.Fleet;

/// <summary>The library's store against a hub (app/windows/README.md, "What the screens call"). A normal start
/// (<see cref="Create"/>) keeps the store in the user's LocalAppData, the device key in its own file there under
/// Windows' protection of the user's data, the secret box of the owner's computer in its own folder under a protection
/// of its own purpose, and reads this PC's Tailscale to find the hub; with no hub it opens on Add this PC, or on the
/// welcome page of the first run in a build that has it (<see cref="FirstRunSwitch"/>). A build with the proofs' switch
/// (<see cref="Proofs"/>) can also take a hub, a code and a folder from the environment, with the key in memory
/// (<see cref="FromProofs"/>).</summary>
public sealed class StoreSource : IFleetSource
{
    private readonly OwnerStore store;
    private readonly ISecretBox? box;
    private readonly PcTailscale? tailscale;
    private SetupStore? firstRun;

    private StoreSource(OwnerStore store, ISecretBox? box = null, PcTailscale? tailscale = null)
    {
        this.store = store;
        this.box = box;
        this.tailscale = tailscale;
        store.Changed += (_, change) => Changed?.Invoke(this, new FleetChange(change.After, Stopwatch.GetTimestamp()));
        store.Notified += (_, due) => Notified?.Invoke(this, due);
        // A store that can be the owner's computer keeps the mark of a manager that its hub shows with no server, at each
        // current reading (the Mac's notePlacing): the window does not wait for the read that it may need.
        if (box is not null)
        {
            var placing = new ManagerPlacing(Founderizer.Owner.Reads.OwnerReads.Of(store), Choices());
            store.Changed += (_, change) => _ = placing.NoteAsync(change.After, DateTimeOffset.UtcNow);
        }
    }

    /// <summary>The store of a normal start.</summary>
    public static StoreSource Create()
    {
        var box = new FileSecretBox(AppFolders.Keys, new UserKeyProtection(UserKeyProtection.SecretBox));
        var tailscale = PcTailscale.Create();
        return new(new OwnerStore(new StoreSettings
        {
            Folder = AppFolders.Store,
            Keys = new FileKeyStore(AppFolders.KeyFile, new UserKeyProtection()),
            ClientLabel = "founderizer-windows/1/" + AppFolders.InstallationId(),
            Tailscale = tailscale,
            Box = box,
            Can = Navigation.Routes.Can,
            Welcome = FirstRunSwitch.Welcome,
        }), box, tailscale);
    }

    /// <summary>This PC's Tailscale as the first run reads it, or null for a store of the proofs with a hub.</summary>
    internal PcTailscale? Tailscale => tailscale;

    /// <summary>**The first run's store** (the library's <see cref="SetupStore"/>, piece L4), made once, when the welcome
    /// page first shows; null for a store that can be no owner's computer (no secret box). It shares this store and its
    /// box: the claim makes this store the owner's computer of the new hub. Its records, the servers' host keys and the
    /// owner's kept answers are in the first run's own folder; every key and token is in the box.</summary>
    internal SetupStore? FirstRun()
    {
        if (firstRun is not null || box is not { } secrets || tailscale is not { } pc) return firstRun;
        var hostKeys = new HostKeys(AppFolders.Setup);
        // One exchange for every provider: the provider's own client never disposes it (ProviderHttp).
        var providers = Providers();
        clouds = provider => CloudServers.For(provider, providers, secrets);
        firstRun = new SetupStore(new SetupSettings
        {
            Owner = store,
            Box = secrets,
            Remote = new SshRemote(hostKeys, () => secrets.Read(AppSshKey.BoxName)),
            HostKeys = hostKeys,
            Records = new SetupRecords(AppFolders.Setup),
            Tailscale = new FleetNet(new TailscaleApi(Providers(), secrets)),
            Cloud = clouds,
            Status = cancel => pc.ReadAsync(cancel),
            Choices = Choices(),
        });
        return firstRun;
    }

    private FileChoices? choices;

    /// <summary>The first run's kept answers, one file read by one instance: the first run and the manager's setup both
    /// keep their marks there (the instance holds what it read, so a second one would not see the first one's writes).</summary>
    private FileChoices Choices() => choices ??= new FileChoices(System.IO.Path.Combine(AppFolders.Setup, "choices.json"));

    private ManagerSetup? managerSetup;

    /// <summary>**The setup of the manager of a new fleet** (piece U3), while this PC keeps its mark for the hub that it
    /// owns now, of this generation, with that manager in its reading: the first run writes it from the claim on, a
    /// current reading of a manager with no server writes it (<see cref="ManagerPlacing"/>), and the manager's run takes
    /// it away. Null otherwise, and for a store that can be no owner's computer. Made once for a mark,
    /// so that its readings stay while its page comes and goes. A build with the proofs' switch takes the stand-in of
    /// FOUNDERIZER_SETUP_READINGS in its place (<see cref="SetupStandIn"/>).</summary>
    internal ManagerSetup? ManagerSetup()
    {
#if PROOFS
        if (SetupStandIn.Create() is { } standIn)
        {
            return managerSetup ??= new ManagerSetup(new ManagerSetupSettings { Calls = standIn, Fleet = standIn.Fleet, Choices = Choices() }, standIn.Mark());
        }
#endif
        if (box is null || ManagerSetupMark.Shown(store.State, Choices()) is not { } mark) return null;
        if (managerSetup is { } kept && kept.Mark.IsOf(mark.Hub, mark.Db) && kept.Mark.Agent == mark.Agent) return kept;
        return managerSetup = new ManagerSetup(new ManagerSetupSettings
        {
            Calls = Founderizer.Owner.Reads.OwnerReads.Of(store),
            Fleet = () => store.State.Fleet,
            Hub = () => store.State.Hub,
            Choices = Choices(),
            Refresh = store.RefreshAsync,
            Fresh = () => store.State.IsFresh(DateTimeOffset.UtcNow),
        }, mark);
    }

    /// <summary>**The manager's rename that this reading shows** (piece U3b, <see cref="ManagerSetupMark.TakeRename"/>): the
    /// kept mark goes to the new name, and the window moves the manager's pages there. Null for none.</summary>
    internal (string Was, string Now)? TakeRename(StoreState next) => ManagerSetupMark.TakeRename(next, Choices());

    private Func<CloudProvider, ICloud>? clouds;

    /// <summary>Whether this PC holds a token of the provider, as the first run's list under a server reads it.</summary>
    internal bool HoldsToken(CloudProvider provider) => clouds?.Invoke(provider).IsHeld == true;

    /// <summary>The way out to the providers' own APIs: Windows' exchange with no redirect (<see cref="ProviderHandler"/>).
    /// A build with the proofs' switch takes the stand-in of FOUNDERIZER_PROVIDERS in its place
    /// (<see cref="ProviderStandIn"/>); any other build has no such way.</summary>
    private static System.Net.Http.HttpMessageHandler Providers()
    {
#if PROOFS
        if (ProviderStandIn.Create() is { } standIn) return standIn;
#endif
        return ProviderHandler.Create();
    }

    /// <summary>For the proofs only: the store of FOUNDERIZER_HUB, or null when the build has no switch or the variable
    /// is not set; the key stays in memory, so each start enrolls again with FOUNDERIZER_DEVICE_CODE.</summary>
    public static StoreSource? FromProofs()
    {
        if (Proofs.Variable("FOUNDERIZER_HUB") is not { Length: > 0 }) return null;
        var folder = Proofs.Variable("FOUNDERIZER_STORE") ?? AppFolders.Store;
        return new StoreSource(new OwnerStore(new StoreSettings
        {
            Folder = folder,
            Keys = new MemoryKeyStore(),
            ClientLabel = "founderizer-windows/1",
        }))
        { fromProofs = true };
    }

    private bool fromProofs;

    public StoreState State => store.State;

    public event EventHandler<FleetChange>? Changed;

    /// <summary>For the proofs only: connects to FOUNDERIZER_HUB and enrolls with FOUNDERIZER_DEVICE_CODE. The words of a
    /// failure, or null. A normal start does nothing here: the store reads what it kept.</summary>
    public async Task<string?> StartAsync()
    {
        if (!fromProofs || Proofs.Variable("FOUNDERIZER_HUB") is not { } hub) return null;
        if (await store.ConnectAsync(hub) is { } refused) return refused;
        if (Proofs.Variable("FOUNDERIZER_DEVICE_CODE") is { Length: > 0 } code)
        {
            return await store.EnrollAsync(code);
        }
        return null;
    }

    public void SetFront(bool front) => store.SetFront(front);

    // A page that opens reads at once, as the iPhone's chat and task pages do (beginWait, then refresh).
    public void OpenChat(string? agent)
    {
        store.OpenChat(agent);
        if (agent is not null) _ = store.RefreshAsync();
    }

    public void OpenTask(long? task)
    {
        store.OpenTask(task);
        if (task is not null) _ = store.RefreshAsync();
    }

    public void SetDraft(string agent, string text) => store.SetDraft(agent, text);

    public Task<string?> SendMessageAsync(string agent) => store.SendMessageAsync(agent);

    public void SetAnswerDraft(long need, string text) => store.SetAnswerDraft(need, text);

    public Task<string?> AnswerAsync(long need) => store.AnswerAsync(need);

    public Task<string?> TickAsync(long need, IReadOnlyCollection<int> choices) => store.TickAsync(need, choices);

    public void Press(long need, int choice) => store.Press(need, choice);

    public void Reply(long need, string words) => store.Reply(need, words);

    public string? Hold(long need, CardAnswer answer) => store.Hold(need, answer);

    public void Undo(long need) => store.Undo(need);

    public void TicksShown(long need, long number) => store.TicksShown(need, number);

    public Task<string?> ControlAsync(long task, TaskControl action) => store.ControlAsync(task, action);

    public Task<string?> GuideAsync(long task, string text) => store.GuideAsync(task, text);

    public bool OpenClarify(long need) => store.OpenClarify(need);

    public void SetClarifyDraft(long need, string text) => store.SetClarifyDraft(need, text);

    public Task<string?> TalkAsync(long need) => store.TalkAsync(need);

    public void KeepKey(string box) => store.KeepKey(box);

    public Task RefreshAsync() => store.RefreshAsync();

    public Task RetryAsync() => store.RetryAsync();

    public void DiscardRefused() => store.DiscardRefused();

    public Task<string?> AddFileAsync(string composer, string name, byte[] bytes, string? mime) =>
        store.AddFileAsync(composer, name, bytes, mime);

    public Task<string?> UploadAsync(string composer, Guid file) => store.UploadAsync(composer, file);

    public void RemoveFile(string composer, Guid file) => store.RemoveFile(composer, file);

    public Task<byte[]> FileAsync(MessageAttachment file) => store.FileAsync(file);

    public Task ListOutputsAsync() => store.ListOutputsAsync();

    public Task ViewOutputAsync(ArtifactFile file) => store.ViewOutputAsync(file);

    public void CloseOutputs() => store.CloseOutputs();

    public event EventHandler<IReadOnlyList<Notice>>? Notified;

    public Task<string?> ConnectAsync(string address) => store.ConnectAsync(address);

    public Task<string?> EnrollAsync(string code) => store.EnrollAsync(code);

    public string? ForgetKey() => store.ForgetKey();

    public Task ReadDeviceAsync() => store.ReadDeviceAsync();

    public ValueTask DisposeAsync() => store.DisposeAsync();
}
