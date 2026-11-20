using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The decode twin as the owner's computer (windows-app-plan-v2.md, section 6 and piece L0): the scratch hub of
/// app_decode.py, whose owner is this process's address and which keeps the SHA-256 of a key of the run's own, read with
/// this library's store and client, as the PC that claimed that hub reads it. It runs only from
/// `python3 app_decode.py --windows` (or `--windows-only`), after the device run of <see cref="HubDecodeTwin"/>; otherwise
/// it is inconclusive.
///
/// app_decode.py gives FLEET_E2E_HUB and FLEET_E2E_DB, and FLEET_E2E_OWNER_KEY: the key of the owner's computer, a test
/// key of that scratch hub. Each page family adds a test file of this category for its own reads.</summary>
[TestClass]
[TestCategory("OwnerDecode")]
public sealed class OwnerDecodeTwin
{
    private static readonly string? HubText = Environment.GetEnvironmentVariable("FLEET_E2E_HUB");
    private static Uri Hub => new(HubText!.TrimEnd('/') + "/");
    private static string Database => Environment.GetEnvironmentVariable("FLEET_E2E_DB") ?? "";

    private static string Key()
    {
        if (HubText is null) Assert.Inconclusive("FLEET_E2E_HUB is not set: the twin runs from app_decode.py --windows");
        var key = Environment.GetEnvironmentVariable("FLEET_E2E_OWNER_KEY");
        if (string.IsNullOrEmpty(key)) Assert.Fail("FLEET_E2E_OWNER_KEY is not set: app_decode.py gives the owner run's key");
        return key;
    }

    /// <summary>GET /ui/mobile and an owner read (GET /ui/owner/devices) decode, as the owner's computer with its key from
    /// the secret box; and the hub holds that key, because the same read with no key is refused.</summary>
    [TestMethod]
    public async Task mobile_and_an_owner_read_as_the_owners_computer()
    {
        var key = Key();
        using (var bare = new HubClient())
        {
            var refused = Expect.Hub(() => bare.SnapshotAsync(Hub, null, Database, null));
            Assert.AreEqual((403, OwnerPcKey.Required), (refused.Status, refused.Auth), refused.Message);
        }
        var box = new MemorySecretBox();
        OwnerPcKey.Promote(box, Hub, key);
        var folder = Directory.CreateTempSubdirectory("founderizer-owner-twin-").FullName;
        try
        {
            await using var store = new OwnerStore(new StoreSettings
            {
                Folder = folder, Keys = new MemoryKeyStore(), Box = box, ClientLabel = "Founderizer for Windows (decode twin)",
            });
            await store.ConnectOwnerAsync(Hub);
            var s = store.State;
            if (s.ReadError is { } e) Assert.Fail($"{e.Read ?? e.Kind.ToString()}: {e.Message} {e.HubWords} (status {e.Status}, auth {e.Auth})");
            Assert.AreEqual((HubRole.Owner, KeyState.InHand, Database), (s.Role, s.Key, s.Fleet?.Db));
            Assert.IsTrue(s.Fleet!.Offers("mobile"));
            var devices = await store.OwnerGetAsync("ui/owner/devices", CoreJson.Default.MobileDeviceList);
            Assert.AreEqual(Database, devices.Value?.Db);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
