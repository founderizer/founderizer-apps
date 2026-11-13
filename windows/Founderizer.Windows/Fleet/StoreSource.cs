using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>The library's store against a hub (app/windows/README.md, "What the screens call"). Until Add this PC and
/// the key storage come (slice 1.5 of the plan), it is set up from the environment, for the proofs only:
/// FOUNDERIZER_HUB (the hub's address), FOUNDERIZER_DEVICE_CODE (a code made on the Mac), and FOUNDERIZER_STORE (the
/// store's folder; the default is the app's folder in LocalAppData). The key stays in memory: each start enrolls again.</summary>
public sealed class StoreSource : IFleetSource
{
    private readonly OwnerStore store;

    private StoreSource(OwnerStore store)
    {
        this.store = store;
        store.Changed += (_, change) => Changed?.Invoke(this, new FleetChange(change.After, Stopwatch.GetTimestamp()));
    }

    /// <summary>The store of FOUNDERIZER_HUB, or null when that variable is not set.</summary>
    public static StoreSource? FromEnvironment()
    {
        if (Environment.GetEnvironmentVariable("FOUNDERIZER_HUB") is not { Length: > 0 }) return null;
        var folder = Environment.GetEnvironmentVariable("FOUNDERIZER_STORE")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Founderizer", "store");
        return new StoreSource(new OwnerStore(new StoreSettings
        {
            Folder = folder,
            Keys = new MemoryKeyStore(),
            ClientLabel = "founderizer-windows/1",
        }));
    }

    public StoreState State => store.State;

    public event EventHandler<FleetChange>? Changed;

    /// <summary>Connects to FOUNDERIZER_HUB and enrolls with FOUNDERIZER_DEVICE_CODE. The words of a failure, or null.</summary>
    public async Task<string?> StartAsync()
    {
        var hub = Environment.GetEnvironmentVariable("FOUNDERIZER_HUB")!;
        if (await store.ConnectAsync(hub) is { } refused) return refused;
        if (Environment.GetEnvironmentVariable("FOUNDERIZER_DEVICE_CODE") is { Length: > 0 } code)
        {
            return await store.EnrollAsync(code);
        }
        return null;
    }

    public void SetFront(bool front) => store.SetFront(front);

    public ValueTask DisposeAsync() => store.DisposeAsync();
}
