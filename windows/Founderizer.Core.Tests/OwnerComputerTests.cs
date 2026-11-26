using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The PC as the owner's computer of a hub (windows-app-plan-v2.md, piece L0): the key of each role on every
/// call, the claim with the key of the owner's computer (the Mac's cases of OwnerMacKeyTests), and the secret box.</summary>
[TestClass]
public sealed class OwnerComputerTests
{
    private readonly List<string> folders = [];
    private readonly List<FakeHub> hubs = [];

    private string Folder()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-owner-").FullName;
        folders.Add(folder);
        return folder;
    }

    private FakeHub Hub()
    {
        var hub = new FakeHub();
        hubs.Add(hub);
        return hub;
    }

    [TestCleanup]
    public void Remove()
    {
        foreach (var hub in hubs) hub.Dispose();
        foreach (var folder in folders) Directory.Delete(folder, recursive: true);
    }

    /// <summary>The hub's rule of one key (hub.py owner_key_allowed): each request whose bearer is not that key is
    /// refused before it is read.</summary>
    private static Func<Seen, byte[]?> Takes(string key) => seen =>
        seen.Header("Authorization") == "Bearer " + key ? null
            : LoopbackHub.Json(403, """{"error":"this is not the key of the owner's computer","auth":"owner_key_mismatch"}""");

    private static string Bearer(Seen seen) => seen.Header("Authorization") ?? "(none)";

    /// <summary>**As the owner's computer every call carries the key of the owner's computer, and as a device the device
    /// key**, also after a new start, which reads the role from the hub's kept address, after Connect on the address that
    /// the PC has, and after Connect on another hub that this PC owns. The bug: the store sends the device key (or no
    /// key) where the hub holds the owner's, and every read of the owner's computer is refused (403); or the owner's key
    /// goes to a hub where this PC is only a device; or a line that names the call writes the key.</summary>
    [TestMethod]
    public async Task EveryCallCarriesTheKeyOfThisPcsRoleAtThatHub()
    {
        var folder = Folder();
        var owned = Hub();
        var box = new MemorySecretBox();
        var ownerKey = OwnerPcKey.Make();
        OwnerPcKey.Promote(box, owned.Address, ownerKey);
        owned.Gate = Takes(ownerKey);
        var settings = new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1"), Box = box };
        await using (var store = new OwnerStore(settings))
        {
            await store.ConnectOwnerAsync(owned.Address);
            store.OpenChat("manager");
            await store.RefreshAsync();
            var s = store.State;
            Assert.AreEqual((HubRole.Owner, KeyState.InHand), (s.Role, s.Key));
            Assert.IsNull(s.ReadError, s.ReadError?.Message);
            Assert.AreEqual("gen1", s.Fleet?.Db);
            Assert.AreNotEqual(PageKind.AddThisPc, Screens.FirstPage(s).Kind);
            var devices = await store.OwnerGetAsync("ui/owner/devices", CoreJson.Default.MobileDeviceList);
            Assert.AreEqual("gen1", devices.Value?.Db);
            Assert.IsFalse($"{store.Call()}".Contains(ownerKey), "the text of a call holds no key");
            Assert.IsNull(store.ForgetKey());
            Assert.AreEqual("device-key-1", settings.Keys.Read(), "the owner's computer takes no device key off");
            // Connect on the address that Settings shows keeps the owner's computer.
            Assert.IsNull(await store.ConnectAsync(owned.Address.ToString()));
            Assert.AreEqual((HubRole.Owner, KeyState.InHand), (store.State.Role, store.State.Key));
            Assert.IsNull(store.State.ReadError, store.State.ReadError?.Message);
        }
        await using (var again = new OwnerStore(settings))
        {
            Assert.AreEqual((HubRole.Owner, owned.Address), (again.State.Role, again.State.Hub), "the role is kept with the hub");
            again.Unlock();
            await again.RefreshAsync();
            Assert.IsNull(again.State.ReadError, again.State.ReadError?.Message);
        }
        var sent = owned.Server.Received.ToList();
        Assert.IsTrue(sent.Any(r => r.Target.StartsWith("/ui/mobile/chat/manager", StringComparison.Ordinal)));
        Assert.IsTrue(sent.Any(r => r.Target.StartsWith("/ui/owner/devices", StringComparison.Ordinal)));
        Assert.IsTrue(sent.All(r => Bearer(r) == "Bearer " + ownerKey), string.Join(", ", sent.Select(Bearer).Distinct()));

        // Connect on another hub that this PC owns (the box holds its key): the owner's computer there, with that key.
        var second = Hub();
        var secondKey = OwnerPcKey.Make();
        OwnerPcKey.Promote(box, second.Address, secondKey);
        second.Gate = Takes(secondKey);
        // The same PC is a device of a third hub, for which the box holds no key: there the device key goes.
        var other = Hub();
        other.Gate = Takes("device-key-1");
        await using (var device = new OwnerStore(settings))
        {
            await device.ConnectAsync(second.Address.ToString());
            Assert.AreEqual((HubRole.Owner, KeyState.InHand), (device.State.Role, device.State.Key));
            Assert.IsNull(device.State.ReadError, device.State.ReadError?.Message);
            await device.ConnectAsync(other.Address.ToString());
            await device.RefreshAsync();
            Assert.AreEqual((HubRole.Device, KeyState.InHand), (device.State.Role, device.State.Key));
            Assert.IsNull(device.State.ReadError, device.State.ReadError?.Message);
            Assert.AreEqual(PageKind.Needs, Screens.FirstPage(device.State).Kind);
        }
        Assert.IsTrue(second.Server.Received.All(r => Bearer(r) == "Bearer " + secondKey));
        Assert.IsTrue(other.Server.Received.All(r => Bearer(r) == "Bearer device-key-1"));
    }

    /// <summary>**The PC says what it is in exactly the body that the hub takes, and a refusal is not sent again** before a
    /// new generation (owner API 1.273: the hub refuses any field beside kind and can). The bug: the body carries
    /// request_id and db, the hub answers 400, and the store sends it again at every read, for ever.</summary>
    [TestMethod]
    public async Task TheComputerSaysOnlyItsKindAndCanAndARefusalGoesNoMore()
    {
        var hub = Hub();
        var box = new MemorySecretBox();
        var key = OwnerPcKey.Make();
        OwnerPcKey.Promote(box, hub.Address, key);
        hub.Snapshot["ui_features"]!.AsArray().Add((System.Text.Json.Nodes.JsonNode)"owner_computer");
        var said = new List<Seen>();
        var answer = LoopbackHub.Json(400, """{"error":"unknown field db"}""");
        hub.Gate = seen =>
        {
            if (seen.Target != "/ui/owner/computer") return null;
            lock (said) said.Add(seen);
            return answer;
        };
        await using var store = new OwnerStore(new StoreSettings
        {
            Folder = Folder(), Keys = new MemoryKeyStore(), Box = box, Can = ["devices", "agents", "devices"],
        });
        await store.ConnectOwnerAsync(hub.Address);
        await store.RefreshAsync();
        await store.RefreshAsync();
        Assert.AreEqual(1, said.Count, "a hub that refused the body is asked once");
        using (var body = System.Text.Json.JsonDocument.Parse(said[0].Body))
        {
            CollectionAssert.AreEqual(new[] { "can", "kind" }, body.RootElement.EnumerateObject().Select(p => p.Name).ToArray());
            Assert.AreEqual("windows", body.RootElement.GetProperty("kind").GetString());
            CollectionAssert.AreEqual(new[] { "agents", "devices" },
                                      body.RootElement.GetProperty("can").EnumerateArray().Select(n => n.GetString()).ToArray());
        }
        Assert.AreEqual("Bearer " + key, said[0].Header("Authorization"));

        // A new generation asks again; the hub keeps a PC now, and the next reads ask no more.
        answer = LoopbackHub.Json(200, """{"owner_computer":{"kind":"windows","label":"PC","can":["agents","devices"]},"changed":true}""");
        var next = SampleFleet.Snapshot(db: "gen2");
        next["ui_features"]!.AsArray().Add((System.Text.Json.Nodes.JsonNode)"owner_computer");
        hub.Snapshot = next;
        for (var i = 0; i < 50 && store.State.Fleet?.Db != "gen2"; i++) await store.RefreshAsync();
        await store.RefreshAsync();
        await store.RefreshAsync();
        Assert.AreEqual(2, said.Count);
        Assert.IsTrue(await store.SayComputerAsync(), "the hub keeps this computer as a PC");
    }

    /// <summary>**Only a 409 whose code says so is a changed generation** (the Mac's HubError.conflict): another 409 (a
    /// stale base, a request number used again, an action that the state does not allow) reaches the caller with the
    /// hub's words. The bug: every 409 reads as a changed generation, and the owner never learns why his change did
    /// not go.</summary>
    [TestMethod]
    public async Task AnOwnerCallMeetsAChangedGenerationOnlyByItsCode()
    {
        var hub = Hub();
        var box = new MemorySecretBox();
        OwnerPcKey.Promote(box, hub.Address, OwnerPcKey.Make());
        await using var store = new OwnerStore(new StoreSettings { Folder = Folder(), Keys = new MemoryKeyStore(), Box = box });
        await store.ConnectOwnerAsync(hub.Address);
        hub.Gate = seen => seen.Target.StartsWith("/ui/servers", StringComparison.Ordinal)
            ? LoopbackHub.Json(409, """{"error":"the server's setup changed meanwhile","code":"base_changed"}""") : null;
        var refused = await Assert.ThrowsExactlyAsync<HubException>(() => store.OwnerGetAsync("ui/servers", CoreJson.Default.MobileDeviceList));
        Assert.AreEqual((409, "the server's setup changed meanwhile"), (refused.Status, refused.HubWords));
        hub.Gate = seen => seen.Target.StartsWith("/ui/servers", StringComparison.Ordinal)
            ? LoopbackHub.Json(409, """{"error":"hub generation changed; refresh state","code":"hub_changed"}""") : null;
        Assert.IsTrue((await store.OwnerGetAsync("ui/servers", CoreJson.Default.MobileDeviceList)).IsGenerationChanged);
    }

    // ------------------------------------------------------------ the claim of a new hub

    /// <summary>The claim's listener and then the hub on one address (the Mac's KeyedHub): the listener keeps the
    /// SHA-256 that a claim carries and answers "kept" (or, as an installer from before the key, nothing), and the hub
    /// then takes a call only with the key of that SHA-256.</summary>
    private sealed class ClaimHub
    {
        public readonly FakeHub Hub;
        public string? Sha;
        public bool RefusesClaim;
        public bool Keeps = true;
        /// <summary>The next answers of a claim that do not arrive, after the listener did what it asked.</summary>
        public int Loses;
        public readonly List<string?> Claims = [];

        public ClaimHub(FakeHub hub)
        {
            Hub = hub;
            hub.Gate = Answer;
        }

        public Uri Claim => new(Hub.Address, "claim");

        private byte[]? Answer(Seen seen)
        {
            lock (this)
            {
                if (seen.Target == "/claim")
                {
                    var sha = seen.Header(OwnerPcKey.ClaimHeader);
                    Claims.Add(sha);
                    if (RefusesClaim)
                        return LoopbackHub.Raw(403, "Founderizer: this is not the claim code. Copy the whole line from the installer again.\n"u8.ToArray());
                    if (Keeps) Sha = sha;
                    if (Loses > 0)
                    {
                        Loses--;
                        return [];
                    }
                    return LoopbackHub.Raw(200, "Founderizer: claimed\n"u8.ToArray(),
                                           Keeps && sha is not null ? [(OwnerPcKey.ClaimKept, "kept")] : []);
                }
                if (Sha is null) return null;
                var bearer = seen.Header("Authorization");
                if (bearer is null) return LoopbackHub.Json(403, """{"error":"no key","auth":"owner_key_required"}""");
                return bearer.StartsWith("Bearer ", StringComparison.Ordinal) && OwnerPcKey.Digest(bearer[7..]) == Sha
                    ? null : LoopbackHub.Json(403, """{"error":"another key","auth":"owner_key_mismatch"}""");
            }
        }
    }

    private static async Task<string?> Claim(ISecretBox box, ClaimHub hub, string code = "7KMQ2PRJ4TVW")
    {
        using var client = new HubClient();
        return await OwnerPcKey.SendClaimAsync(client, box, hub.Claim, code, default);
    }

    /// <summary>**The claim carries the SHA-256 of a new key, the PC keeps the key when the installer does, and the hub
    /// that starts there takes the PC's calls with it and not the address alone.** The claim goes only to an address of
    /// the fleet's network. The bug: the key is sent, or not kept, or the store reads without it.</summary>
    [TestMethod]
    public async Task TheClaimCarriesTheShaOfANewKeyAndThePcKeepsItWhenTheInstallerDoes()
    {
        var hub = new ClaimHub(Hub());
        var box = new MemorySecretBox();
        using (var client = new HubClient())
            Assert.AreEqual(OwnerPcKey.NotOnYourNetwork, await OwnerPcKey.ClaimAsync(client, box, hub.Claim, "7KMQ2PRJ4TVW"));
        Assert.AreEqual(0, hub.Hub.Server.Received.Count, "a claim to an address off the fleet's network sends nothing");
        Assert.IsNull(await Claim(box, hub));
        var key = OwnerPcKey.Read(box, hub.Hub.Address);
        Assert.IsNotNull(key);
        Assert.AreEqual(43, key.Length);
        CollectionAssert.AreEqual(new[] { OwnerPcKey.Digest(key) }, hub.Claims);
        Assert.AreEqual(OwnerPcKey.Digest(key), hub.Sha);
        Assert.IsNull(OwnerPcKey.Waiting(box, hub.Hub.Address));
        Assert.IsFalse(hub.Hub.Server.Received.Any(r => r.Text.Contains(key) || (r.Header("Authorization") ?? "").Contains(key)),
                       "the key itself never goes with the claim");
        await using var store = new OwnerStore(new StoreSettings { Folder = Folder(), Keys = new MemoryKeyStore(), Box = box });
        await store.ConnectOwnerAsync(hub.Hub.Address);
        Assert.IsNull(store.State.ReadError, store.State.ReadError?.Message);
        Assert.AreEqual("gen1", store.State.Fleet?.Db);
        using var bare = new HubClient();
        Assert.AreEqual("owner_key_required", Expect.Hub(() => bare.SnapshotAsync(hub.Hub.Address, null, null, null)).Auth);
    }

    /// <summary>**A claim whose answer was lost keeps its key: the next claim sends the same one, and so does the store's
    /// first read, which makes it the key when the hub takes it.** The listener answers a second claim with 410 once it
    /// has its owner, so the read is how a PC whose answer was lost gets in. The bug: a new key for each claim, or a
    /// key that waits forever, and the hub holds the SHA-256 of a key that the PC does not use.</summary>
    [TestMethod]
    public async Task AClaimWhoseAnswerWasLostKeepsItsKeyForTheNextClaimAndTheFirstRead()
    {
        var hub = new ClaimHub(Hub()) { Loses = 1 };
        var box = new MemorySecretBox();
        Assert.IsNotNull(await Claim(box, hub));
        var waits = OwnerPcKey.Waiting(box, hub.Hub.Address);
        Assert.IsNotNull(waits);
        Assert.AreEqual(OwnerPcKey.Digest(waits), hub.Sha, "the listener took it");
        Assert.IsNull(OwnerPcKey.Read(box, hub.Hub.Address));
        Assert.IsNull(await Claim(box, hub));
        CollectionAssert.AreEqual(new[] { OwnerPcKey.Digest(waits), OwnerPcKey.Digest(waits) }, hub.Claims);
        Assert.AreEqual(waits, OwnerPcKey.Read(box, hub.Hub.Address));
        Assert.IsNull(OwnerPcKey.Waiting(box, hub.Hub.Address));

        // Lost again on another hub, and no second claim: the store reads with the key that waits, and the hub took it.
        var lost = new ClaimHub(Hub()) { Loses = 1 };
        Assert.IsNotNull(await Claim(box, lost));
        var second = OwnerPcKey.Waiting(box, lost.Hub.Address)!;
        await using var store = new OwnerStore(new StoreSettings { Folder = Folder(), Keys = new MemoryKeyStore(), Box = box });
        await store.ConnectOwnerAsync(lost.Hub.Address);
        Assert.IsNull(store.State.ReadError, store.State.ReadError?.Message);
        Assert.AreEqual(second, OwnerPcKey.Read(box, lost.Hub.Address));
        Assert.IsNull(OwnerPcKey.Waiting(box, lost.Hub.Address));
        Assert.IsTrue(lost.Hub.Server.Received.Where(r => r.Target != "/claim").All(r => Bearer(r) == "Bearer " + second));

        // A second claim of a hub that this PC owns, whose answer was lost: the hub holds the new key, and the PC keeps
        // the old one beside the new one that waits. The hub refuses the old key, the next read carries the one that
        // waits, and the hub's yes makes it the key (the Mac's rule of two keys).
        var again = new ClaimHub(Hub());
        Assert.IsNull(await Claim(box, again));
        var old = OwnerPcKey.Read(box, again.Hub.Address)!;
        again.Loses = 1;
        Assert.IsNotNull(await Claim(box, again));
        var held = OwnerPcKey.Waiting(box, again.Hub.Address)!;
        Assert.AreEqual(OwnerPcKey.Digest(held), again.Sha);
        await using var owner = new OwnerStore(new StoreSettings { Folder = Folder(), Keys = new MemoryKeyStore(), Box = box });
        await owner.ConnectOwnerAsync(again.Hub.Address);
        for (var i = 0; i < 40 && OwnerPcKey.Read(box, again.Hub.Address) != held; i++) await owner.RefreshAsync();
        Assert.AreEqual(held, OwnerPcKey.Read(box, again.Hub.Address));
        Assert.IsNull(OwnerPcKey.Waiting(box, again.Hub.Address));
        Assert.IsNull(owner.State.ReadError, owner.State.ReadError?.Message);
        Assert.IsTrue(again.Hub.Server.Received.Any(r => Bearer(r) == "Bearer " + old), "the kept key went first");
    }

    /// <summary>**A new claim never loses a key**: a claim that the listener refuses keeps the key that waits for the next
    /// claim, and the key that this PC kept for that hub before stays until an installer says that it kept the new
    /// one; an installer from before the key leaves the PC with the key that it had, or none. The bug: the PC throws a
    /// kept key away on a claim that did not change the hub, and cannot reach its own hub again.</summary>
    [TestMethod]
    public async Task ANewClaimNeverLosesAKeptKeyAndARefusedOneKeepsItsKeyForTheNext()
    {
        var hub = new ClaimHub(Hub()) { RefusesClaim = true };
        var box = new MemorySecretBox();
        Assert.AreEqual("Founderizer: this is not the claim code. Copy the whole line from the installer again.",
                        await Claim(box, hub, "7KMQ2PRJ4TVX"));
        var waits = OwnerPcKey.Waiting(box, hub.Hub.Address)!;
        Assert.IsNull(hub.Sha);
        hub.RefusesClaim = false;
        Assert.IsNull(await Claim(box, hub));
        CollectionAssert.AreEqual(new[] { OwnerPcKey.Digest(waits), OwnerPcKey.Digest(waits) }, hub.Claims);
        Assert.AreEqual(waits, OwnerPcKey.Read(box, hub.Hub.Address));

        // A second claim of the same hub: refused, lost, then an installer from before the key. The kept key stays.
        hub.RefusesClaim = true;
        Assert.IsNotNull(await Claim(box, hub));
        hub.RefusesClaim = false;
        hub.Loses = 1;
        Assert.IsNotNull(await Claim(box, hub));
        Assert.AreEqual(waits, OwnerPcKey.Read(box, hub.Hub.Address));
        var next = OwnerPcKey.Waiting(box, hub.Hub.Address);
        Assert.IsNotNull(next);
        Assert.AreNotEqual(waits, next);
        hub.Keeps = false;
        Assert.IsNull(await Claim(box, hub));
        Assert.AreEqual(waits, OwnerPcKey.Read(box, hub.Hub.Address));
        Assert.IsNull(OwnerPcKey.Waiting(box, hub.Hub.Address));

        var old = new ClaimHub(Hub()) { Keeps = false };
        Assert.IsNull(await Claim(box, old));
        Assert.AreEqual(1, old.Claims.Count);
        Assert.IsNull(OwnerPcKey.Read(box, old.Hub.Address));
        Assert.IsNull(OwnerPcKey.Waiting(box, old.Hub.Address));
    }

    // ------------------------------------------------------------ the secret box

    private sealed class TestProtection : IKeyProtection
    {
        private static readonly byte[] Mark = "test-protection:"u8.ToArray();
        public byte[] Protect(byte[] key) => [.. Mark, .. key.Select(b => (byte)(b ^ 0x5A))];
        public byte[] Unprotect(byte[] stored) =>
            stored.AsSpan().StartsWith(Mark) ? stored[Mark.Length..].Select(b => (byte)(b ^ 0x5A)).ToArray()
                : throw new CryptographicException("does not open");
    }

    /// <summary>**A value of the box opens only under its own name**, and not as text in its file. The bug: the key that
    /// waits, copied over the kept key's file (or a device key's file put in the box), opens as the key of the owner's
    /// computer; or a name with ".." writes outside the box.</summary>
    [TestMethod]
    public void AValueOfTheBoxOpensOnlyUnderItsOwnName()
    {
        var folder = Folder();
        var box = new FileSecretBox(Path.Combine(folder, "keys"), new TestProtection());
        var hub = new Uri("http://100.64.0.9:8765/");
        var key = OwnerPcKey.Make();
        OwnerPcKey.KeepWaiting(box, hub, key);
        Assert.AreEqual("owner-keys/100.64.0.9_8765", OwnerPcKey.Name(hub));
        Assert.AreEqual(key, OwnerPcKey.Waiting(box, hub));
        var waiting = Path.Combine(folder, "keys", "owner-keys", "100.64.0.9_8765.pending");
        Assert.IsFalse(Encoding.UTF8.GetString(File.ReadAllBytes(waiting)).Contains(key));
        File.Copy(waiting, Path.Combine(folder, "keys", "owner-keys", "100.64.0.9_8765"));
        Assert.ThrowsExactly<CryptographicException>(() => OwnerPcKey.Read(box, hub));
        var device = new FileKeyStore(Path.Combine(folder, "device-key"), new TestProtection());
        device.Write(key);
        File.Copy(device.FilePath, Path.Combine(folder, "keys", "device-key"));
        Assert.ThrowsExactly<CryptographicException>(() => box.Read("device-key"));
        Assert.ThrowsExactly<ArgumentException>(() => box.Write("owner-keys/../../x", [1]));
        Assert.IsNull(OwnerPcKey.Name(new Uri("http://hub.example.com:8765/")), "a hub written as a name has no key");
        box.Remove("owner-keys/100.64.0.9_8765.pending");
        box.Remove("owner-keys/100.64.0.9_8765.pending");
        Assert.IsNull(OwnerPcKey.Waiting(box, hub));
    }

    /// <summary>**A new value goes only where the name holds none** (WriteNew, the owner key's first make, U4): a name that
    /// holds a value, also one that does not open, keeps it, and WriteNew says false. The bug: WriteNew writes over the
    /// value, so of two starts that make the owner key at once the box keeps one key and the vault gets the other's public
    /// half.</summary>
    [TestMethod]
    public void A_new_value_goes_only_where_the_name_holds_none()
    {
        var folder = Folder();
        foreach (ISecretBox box in new ISecretBox[] { new FileSecretBox(Path.Combine(folder, "keys"), new TestProtection()), new MemorySecretBox() })
        {
            Assert.IsTrue(box.WriteNew("owner-key/0123456789abcdef", [1, 2, 3]));
            Assert.IsFalse(box.WriteNew("owner-key/0123456789abcdef", [4, 5, 6]));
            CollectionAssert.AreEqual(new byte[] { 1, 2, 3 }, box.Read("owner-key/0123456789abcdef"));
        }
        var place = Path.Combine(folder, "keys", "owner-key", "fedcba9876543210");
        File.WriteAllBytes(place, "not a sealed value"u8.ToArray());
        var file = new FileSecretBox(Path.Combine(folder, "keys"), new TestProtection());
        Assert.IsFalse(file.WriteNew("owner-key/fedcba9876543210", [7]));
        CollectionAssert.AreEqual("not a sealed value"u8.ToArray(), File.ReadAllBytes(place));
        Assert.AreEqual(2, Directory.GetFiles(Path.Combine(folder, "keys", "owner-key")).Length, "no temporary file stays");

        // Another process writes the name after WriteNew looked (while it seals): the move does not go over it.
        var raced = Path.Combine(folder, "race", "owner-key", "0011223344556677");
        Directory.CreateDirectory(Path.GetDirectoryName(raced)!);
        var racing = new FileSecretBox(Path.Combine(folder, "race"), new RacingProtection(raced));
        Assert.IsFalse(racing.WriteNew("owner-key/0011223344556677", [9]));
        CollectionAssert.AreEqual("the other start's value"u8.ToArray(), File.ReadAllBytes(raced));
        Assert.AreEqual(1, Directory.GetFiles(Path.GetDirectoryName(raced)!).Length, "no temporary file stays");
    }

    /// <summary>**Remove also takes a temporary file that a crash left** between WriteNew's write and its move (a sealed
    /// copy of the value, for an owner key its software key), and no file of another name; the value goes first, and
    /// nothing after it throws, so a caller's next step (OwnerKeys.Remove's delete of the TPM key) runs. The bugs: the copy
    /// stays in the box's folder after its name was taken away (also when WriteNew's form of the name changed and
    /// Remove's reading did not); a temporary name that a name of the box can have; a held left file, or a folder that
    /// does not list, that makes Remove throw after the value went.</summary>
    [TestMethod]
    public void Remove_takes_a_temporary_file_that_a_crash_left()
    {
        // The maker's exact form, with letters among its hex digits (a maker that writes small letters fails here on each
        // run, not only when its random digits have a letter), and one with no letter: the fixed capital "T" keeps that
        // one too from being a name of the box.
        var letters = FileSecretBox.NewTemporaryName("0123456789abcdef", [0xAB, 0xCD, 0xEF, 0x01]);
        Assert.AreEqual(".0123456789abcdef.TABCDEF01.new", letters);
        Assert.IsTrue(FileSecretBox.IsNewTemporary("0123456789abcdef", letters));
        var digits = FileSecretBox.NewTemporaryName("0123456789abcdef", [0x12, 0x34, 0x56, 0x78]);
        Assert.IsTrue(FileSecretBox.IsNewTemporary("0123456789abcdef", digits));
        Assert.IsFalse(SecretNames.IsName("owner-key/" + digits[1..]), "no name of the box is one of them");
        Assert.IsFalse(FileSecretBox.IsNewTemporary("0123456789abcdef", ".0123456789abcdef.12345678.new"));

        var folder = Folder();
        var box = new FileSecretBox(Path.Combine(folder, "keys"), new TestProtection());
        box.Write("owner-key/0123456789abcdef", [1]);
        box.Write("owner-key/0123456789abcdef.next", [2]);
        var keys = Path.Combine(folder, "keys", "owner-key");
        // Each left file's name made by WriteNew's own maker, so that the test and Remove read the same form.
        var left = FileSecretBox.NewTemporaryName("0123456789abcdef");
        var others = FileSecretBox.NewTemporaryName("0123456789abcdef.next");
        File.WriteAllBytes(Path.Combine(keys, left), [3]);
        File.WriteAllBytes(Path.Combine(keys, others), [4]);
        box.Remove("owner-key/0123456789abcdef");
        CollectionAssert.AreEquivalent(new[] { "0123456789abcdef.next", others },
                                       Directory.GetFiles(keys).Select(f => Path.GetFileName(f)).ToArray());

        // A left file that another program holds open: the value goes all the same, and Remove does not throw. Only
        // Windows refuses to delete an open file, so only there this part reaches the catch (on the Mac and on Linux the
        // file goes at once); there the file stays, and a later Remove of the same name takes it.
        box.Write("owner-key/fedcba9876543210", [5]);
        var held = Path.Combine(keys, FileSecretBox.NewTemporaryName("fedcba9876543210"));
        File.WriteAllBytes(held, [6]);
        using (new FileStream(held, FileMode.Open, FileAccess.Read, FileShare.None))
            box.Remove("owner-key/fedcba9876543210");
        Assert.IsNull(box.Read("owner-key/fedcba9876543210"), "the value is gone although a left file was held");
        if (OperatingSystem.IsWindows())
        {
            Assert.IsTrue(File.Exists(held), "Windows kept the held file, so the catch was reached");
            box.Remove("owner-key/fedcba9876543210");
        }
        Assert.IsFalse(File.Exists(held), "a later Remove of the same name takes the left file");

        // A folder whose listing stops part way: the value goes, the fixed temporary file (which needs no listing) and
        // the left file that the listing gave before it stopped go with it, and Remove does not throw. The listing is a
        // stand-in that gives one name and then refuses: a rule that denies the listing does not stop every user (on the
        // test machine of 25 November the Windows user listed the folder all the same).
        var found = FileSecretBox.NewTemporaryName("0011223344556677");
        var unlisted = new FileSecretBox(Path.Combine(folder, "keys"), new TestProtection())
        {
            FilesOf = each => FoundThenRefused(Path.Combine(each, found)),
        };
        unlisted.Write("owner-key/0011223344556677", [7]);
        var fixedLeft = Path.Combine(keys, ".0011223344556677.new");
        File.WriteAllBytes(fixedLeft, [8]);
        File.WriteAllBytes(Path.Combine(keys, found), [9]);
        unlisted.Remove("owner-key/0011223344556677");
        Assert.IsNull(unlisted.Read("owner-key/0011223344556677"), "the value is gone although the folder did not list");
        Assert.IsFalse(File.Exists(fixedLeft), "the fixed temporary file goes");
        Assert.IsFalse(File.Exists(Path.Combine(keys, found)), "the left file that the listing gave before it stopped goes");

        static IEnumerable<string> FoundThenRefused(string file)
        {
            yield return file;
            throw new UnauthorizedAccessException("the folder does not list");
        }
    }

    /// <summary>**A Remove of a name whose folder does not exist is no error** (a name that holds nothing, as ISecretBox
    /// says), and it makes no folder. The bug: .NET's File.Delete throws DirectoryNotFoundException there, so
    /// OwnerKeys.Remove throws on a PC that never made an owner key.</summary>
    [TestMethod]
    public void Remove_of_a_name_with_no_folder_is_no_error()
    {
        var folder = Folder();
        var box = new FileSecretBox(Path.Combine(folder, "keys"), new TestProtection());
        box.Remove("owner-key/0123456789abcdef");
        Assert.IsFalse(Directory.Exists(Path.Combine(folder, "keys")), "no box folder yet");
        box.Write("device-key", [1]);
        box.Remove("owner-key/0123456789abcdef");
        Assert.IsFalse(Directory.Exists(Path.Combine(folder, "keys", "owner-key")), "a Remove makes no folder");
        CollectionAssert.AreEqual(new byte[] { 1 }, box.Read("device-key"));
    }

    /// <summary>The test protection, which also writes another value into a box's place while it seals: the stand-in of
    /// another process that writes the same name at the same time.</summary>
    private sealed class RacingProtection(string place) : IKeyProtection
    {
        public byte[] Protect(byte[] key)
        {
            if (!File.Exists(place)) File.WriteAllBytes(place, "the other start's value"u8.ToArray());
            return new TestProtection().Protect(key);
        }

        public byte[] Unprotect(byte[] stored) => new TestProtection().Unprotect(stored);
    }

    /// <summary>**A box value that does not open stops no claim**: the claim makes a new key in place of a key that waits
    /// and does not open, carries it, and the hub's "kept" puts it in place of a kept value that does not open. The bug:
    /// the claim goes with no key, or throws after the hub took it, and the PC holds no key of a hub that holds one.</summary>
    [TestMethod]
    public async Task AClaimMakesAKeyInPlaceOfValuesThatDoNotOpen()
    {
        var folder = Folder();
        var box = new FileSecretBox(Path.Combine(folder, "keys"), new TestProtection());
        var hub = new ClaimHub(Hub());
        var name = OwnerPcKey.Name(hub.Hub.Address)!;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.Combine(folder, "keys", name))!);
        File.WriteAllBytes(Path.Combine(folder, "keys", name), "not a sealed value"u8.ToArray());
        File.WriteAllBytes(Path.Combine(folder, "keys", name + ".pending"), "not a sealed value"u8.ToArray());
        Assert.IsNull(await Claim(box, hub));
        Assert.IsNotNull(hub.Claims.Single(), "the claim carries a key");
        var key = OwnerPcKey.Read(box, hub.Hub.Address);
        Assert.AreEqual(hub.Claims.Single(), key is null ? null : OwnerPcKey.Digest(key));
        Assert.IsNull(OwnerPcKey.Waiting(box, hub.Hub.Address));
    }

    /// <summary>**Start again's last step makes this PC a PC that was never given a hub** (step 2, piece L4; the Mac's
    /// <c>forgetFleet</c>): the store holds no hub, a new start reads none from its folder, the first page is the welcome
    /// page, and the key of the owner's computer for that hub goes from the box only when the run deleted the hub's own
    /// server. A store at another hub forgets nothing. The bug: Start again that leaves the dead hub in the app, so that
    /// the next first run never shows and the PC keeps reading a hub that is gone; or a key that goes for a hub that
    /// still runs.</summary>
    [TestMethod]
    public async Task Forgetting_an_owned_hub_leaves_a_PC_that_was_never_given_one()
    {
        foreach (var deleted in new[] { true, false })
        {
            var folder = Folder();
            var owned = Hub();
            var box = new MemorySecretBox();
            var ownerKey = OwnerPcKey.Make();
            OwnerPcKey.Promote(box, owned.Address, ownerKey);
            owned.Gate = Takes(ownerKey);
            var settings = new StoreSettings { Folder = folder, Keys = new MemoryKeyStore(), Box = box, Welcome = true };
            await using (var store = new OwnerStore(settings))
            {
                await store.ConnectOwnerAsync(owned.Address);
                Assert.IsNotNull(store.State.Fleet);
                store.ForgetOwnedHub(new Uri("http://127.0.0.2:8765/"), deleted);
                Assert.AreEqual(owned.Address, store.State.Hub, "a store at another hub forgets nothing");
                store.ForgetOwnedHub(owned.Address, deleted);
                var s = store.State;
                Assert.AreEqual((null as Uri, null as MobileSnapshot, HubRole.Device), (s.Hub, s.Fleet, s.Role));
                Assert.IsTrue(s.HasNoHub && s.HasWelcome);
            }
            await using (var again = new OwnerStore(settings))
                Assert.IsTrue(again.State.HasNoHub, "a new start reads no hub from the folder");
            Assert.AreEqual(!deleted, OwnerPcKey.Read(box, owned.Address) is not null,
                            deleted ? "the key of a deleted hub goes" : "the key of a hub that stays alive stays");
        }
    }
}
