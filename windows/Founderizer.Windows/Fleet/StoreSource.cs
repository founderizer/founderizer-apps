using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>The library's store against a hub (app/windows/README.md, "What the screens call"). A normal start
/// (<see cref="Create"/>) keeps the store in the user's LocalAppData, the device key in its own file there under
/// Windows' protection of the user's data, and reads this PC's Tailscale to find the hub; with no hub it opens on Add
/// this PC. A build with the proofs' switch (<see cref="Proofs"/>) can also take a hub, a code and a folder from the
/// environment, with the key in memory (<see cref="FromProofs"/>).</summary>
public sealed class StoreSource : IFleetSource
{
    private readonly OwnerStore store;

    private StoreSource(OwnerStore store)
    {
        this.store = store;
        store.Changed += (_, change) => Changed?.Invoke(this, new FleetChange(change.After, Stopwatch.GetTimestamp()));
        store.Notified += (_, due) => Notified?.Invoke(this, due);
    }

    /// <summary>The store of a normal start.</summary>
    public static StoreSource Create() => new(new OwnerStore(new StoreSettings
    {
        Folder = AppFolders.Store,
        Keys = new FileKeyStore(AppFolders.KeyFile, new UserKeyProtection()),
        ClientLabel = "founderizer-windows/1/" + AppFolders.InstallationId(),
        Tailscale = new WindowsTailscale(),
    }));

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

    public Task<string?> ControlAsync(long task, TaskControl action) => store.ControlAsync(task, action);

    public Task<string?> GuideAsync(long task, string text) => store.GuideAsync(task, text);

    public Task RefreshAsync() => store.RefreshAsync();

    public Task RetryAsync() => store.RetryAsync();

    public void DiscardRefused() => store.DiscardRefused();

    public Task<string?> AddFileAsync(string composer, string name, byte[] bytes, string? mime) =>
        store.AddFileAsync(composer, name, bytes, mime);

    public Task<string?> UploadAsync(string composer, Guid file) => store.UploadAsync(composer, file);

    public void RemoveFile(string composer, Guid file) => store.RemoveFile(composer, file);

    public Task<byte[]> FileAsync(MessageAttachment file) => store.FileAsync(file);

    public event EventHandler<IReadOnlyList<Notice>>? Notified;

    public Task<string?> ConnectAsync(string address) => store.ConnectAsync(address);

    public Task<string?> EnrollAsync(string code) => store.EnrollAsync(code);

    public string? ForgetKey() => store.ForgetKey();

    public Task ReadDeviceAsync() => store.ReadDeviceAsync();

    public ValueTask DisposeAsync() => store.DisposeAsync();
}
