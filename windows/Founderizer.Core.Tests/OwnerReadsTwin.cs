using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Founderizer.Owner.Reads;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>**The decode twin of the reads of the first run and the agent setup** (windows-app-plan-v2.md, piece L4): GET
/// /ui/servers, GET /ui/machines and GET /ui/team of the scratch hub of app_decode.py, read with this library's store and
/// the reads of <c>Founderizer.Owner/Reads</c> as the owner's computer, with their checks. It runs only from
/// <c>python3 app_decode.py --windows</c> (or <c>--windows-only</c>), after the device run; otherwise it is inconclusive.</summary>
[TestClass]
[TestCategory("OwnerDecode")]
public sealed class OwnerReadsTwin
{
    private static readonly string? HubText = Environment.GetEnvironmentVariable("FLEET_E2E_HUB");
    private static Uri Hub => new(HubText!.TrimEnd('/') + "/");
    private static string Database => Environment.GetEnvironmentVariable("FLEET_E2E_DB") ?? "";

    /// <summary>The three reads decode and pass their checks, as the owner's computer: a field of the hub that this
    /// library reads in another type, a required field that the hub left out, or a check that refuses the hub's own
    /// answer, fails here before any PC reads it.</summary>
    [TestMethod]
    public async Task servers_machines_and_the_team_as_the_owners_computer()
    {
        if (HubText is null) Assert.Inconclusive("FLEET_E2E_HUB is not set: the twin runs from app_decode.py --windows");
        var key = Environment.GetEnvironmentVariable("FLEET_E2E_OWNER_KEY");
        if (string.IsNullOrEmpty(key)) Assert.Fail("FLEET_E2E_OWNER_KEY is not set: app_decode.py gives the owner run's key");
        var box = new MemorySecretBox();
        OwnerPcKey.Promote(box, Hub, key);
        var folder = Directory.CreateTempSubdirectory("founderizer-owner-reads-twin-").FullName;
        try
        {
            await using var store = new OwnerStore(new StoreSettings
            {
                Folder = folder, Keys = new MemoryKeyStore(), Box = box, ClientLabel = "Founderizer for Windows (decode twin)",
            });
            await store.ConnectOwnerAsync(Hub);
            if (store.State.ReadError is { } e) Assert.Fail($"{e.Read ?? e.Kind.ToString()}: {e.Message} {e.HubWords}");
            var calls = OwnerReads.Of(store);
            var servers = (await OwnerReads.ServersAsync(calls)).Value;
            var machines = (await OwnerReads.MachinesAsync(calls)).Value;
            var team = (await OwnerReads.TeamAsync(calls)).Value;
            Assert.AreEqual(Database, servers?.Db);
            Assert.AreEqual(Database, machines?.Db);
            Assert.AreEqual(Database, team?.Db);
            Assert.IsNotNull(team!.Manager, "the scratch team has its manager");
            Assert.IsTrue(machines!.Machines.Count > 0, "the scratch hub has machines");
            Assert.IsTrue(servers!.Servers.Count > 0, "the scratch hub has servers");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
