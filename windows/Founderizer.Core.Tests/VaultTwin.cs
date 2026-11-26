using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Founderizer.Owner.Vault;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>**The decode twin of the vault's reads** (windows-app-plan-v2.md, piece L5): GET /ui/vault, GET
/// /ui/secrets/salts, GET /ui/state?head=1 and the catalog of GET /ui/team of the scratch hub of app_decode.py, read with
/// this library's store and <c>Founderizer.Owner/Vault</c> as the owner's computer, with their checks. It runs only from
/// <c>python3 app_decode.py --windows</c> (or <c>--windows-only</c>), after the device run; otherwise it is
/// inconclusive.</summary>
[TestClass]
[TestCategory("OwnerDecode")]
public sealed class VaultTwin
{
    private static readonly string? HubText = Environment.GetEnvironmentVariable("FLEET_E2E_HUB");
    private static Uri Hub => new(HubText!.TrimEnd('/') + "/");
    private static string Database => Environment.GetEnvironmentVariable("FLEET_E2E_DB") ?? "";

    /// <summary>The reads decode and pass their checks, as the owner's computer: a field of the hub that this library reads
    /// in another type, a salt of another shape, a reading of another generation, or a head of the state with no time
    /// fails here before any PC seals or signs by it.</summary>
    [TestMethod]
    public async Task the_vault_the_salts_the_clock_and_the_catalog_as_the_owners_computer()
    {
        if (HubText is null) Assert.Inconclusive("FLEET_E2E_HUB is not set: the twin runs from app_decode.py --windows");
        var key = Environment.GetEnvironmentVariable("FLEET_E2E_OWNER_KEY");
        if (string.IsNullOrEmpty(key)) Assert.Fail("FLEET_E2E_OWNER_KEY is not set: app_decode.py gives the owner run's key");
        var box = new MemorySecretBox();
        OwnerPcKey.Promote(box, Hub, key);
        var folder = Directory.CreateTempSubdirectory("founderizer-vault-twin-").FullName;
        try
        {
            await using var store = new OwnerStore(new StoreSettings
            {
                Folder = folder, Keys = new MemoryKeyStore(), Box = box, ClientLabel = "Founderizer for Windows (decode twin)",
            });
            await store.ConnectOwnerAsync(Hub);
            if (store.State.ReadError is { } e) Assert.Fail($"{e.Read ?? e.Kind.ToString()}: {e.Message} {e.HubWords}");
            var calls = VaultCalls.Of(store);
            var reading = await VaultRoutes.ReadingAsync(calls);
            Assert.IsNotNull(reading, "this hub serves GET /ui/vault");
            Assert.AreEqual(Database, reading!.Db);
            Assert.IsTrue(VaultIds.IsFleet(reading.FleetId), "the hub names its fleet, which the owner's key is kept under");
            Assert.IsTrue(reading.Machines.Count > 0, "the scratch hub has machines");
            var reference = VaultIds.NewReference();
            var salts = await VaultRoutes.SaltsAsync(calls, reference);
            Assert.AreEqual(reference, salts.Login);
            Assert.AreNotEqual(salts.Password, salts.Totp, "each kind has its own salt");
            var clock = await VaultRoutes.ClockAsync(calls);
            Assert.IsNull(VaultPlan.ClockProblem(clock.HubTime, clock.ReadAt), "the scratch hub's clock is this machine's");
            var (team, catalog) = await VaultRoutes.TeamAsync(calls);
            Assert.AreEqual(Database, team.Db);
            Assert.IsNotNull(catalog, "the hub gives its list of secrets");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
