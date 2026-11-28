using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>**The code that carries its hub** (FleetCore's PairingCode, F7 B3 and B6): the PC reads the Mac's 13
/// characters as app/vectors/join-code.json holds them, sends their last 8 to the hub that they carry or that it found on
/// Tailscale, takes the hub that they carry only with its key, still reads an older Mac's 8, and never sends 8 while 13
/// are still coming. Example addresses only.</summary>
[TestClass]
public sealed class PairingCodeTests
{
    private static Uri? Hub(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : new Uri(value.GetString()!);

    /// <summary>Bug that this catches: the PC's reader differs from the Mac's coder on one case of the shared file (the
    /// alphabet, the address's 22 bits, the check bits, the hubs that the rule takes, the typed forms that it reads), so
    /// a code that the Mac shows is refused on a PC, or a typing fault goes to a wrong address. So every case of
    /// join-code.json gives here what it gives there, and of the 403 changes of one character in its first code, the
    /// same 364 are refused.</summary>
    [TestMethod]
    public void TheReaderReadsEveryCaseOfTheMacsCodes()
    {
        var vectors = Vectors.Read("join-code.json");
        Assert.AreEqual((PairingCode.Alphabet, PairingCode.Port, "100.64.0.0/10", "1011"),
                        (vectors.GetProperty("alphabet").GetString(), vectors.GetProperty("port").GetInt32(),
                         vectors.GetProperty("network").GetString(), vectors.GetProperty("polynomial").GetString()));
        var shown = vectors.GetProperty("shown").EnumerateArray().ToList();
        Assert.AreEqual(32, shown.Count);
        foreach (var c in shown)
        {
            var name = c.GetProperty("name").GetString();
            var text = c.GetProperty("shown").GetString()!;
            Assert.AreEqual(text, PairingCode.Shown(c.GetProperty("hub").GetString()!, c.GetProperty("code").GetString()!), name);
            var reading = PairingCode.Read(text);
            if (c.TryGetProperty("reads_as", out var readsAs) && readsAs.ValueKind != JsonValueKind.Null)
                Assert.AreEqual(new PairingCode.Reading(Hub(readsAs.GetProperty("hub")), readsAs.GetProperty("code").GetString()!), reading, name);
            else
                Assert.AreEqual(new PairingCode.Reading(null, c.GetProperty("code").GetString()!), reading, name + ": the 8 of another hub");
        }
        var read = vectors.GetProperty("read").EnumerateArray().ToList();
        Assert.AreEqual(6, read.Count);
        foreach (var c in read)
            Assert.AreEqual(new PairingCode.Reading(Hub(c.GetProperty("hub")), c.GetProperty("code").GetString()!),
                            PairingCode.Read(c.GetProperty("typed").GetString()!), c.GetProperty("name").GetString());
        var refused = vectors.GetProperty("refused").EnumerateArray().ToList();
        Assert.AreEqual(14, refused.Count);
        foreach (var c in refused)
            Assert.IsNull(PairingCode.Read(c.GetProperty("typed").GetString()!), c.GetProperty("name").GetString());
        var singles = vectors.GetProperty("single_changes");
        var plain = singles.GetProperty("of").GetString()!.Replace("-", "");
        var changes = Enumerable.Range(0, plain.Length).SelectMany(i => PairingCode.Alphabet.Where(c => c != plain[i])
            .Select(c => plain[..i] + c + plain[(i + 1)..])).ToList();
        Assert.AreEqual(singles.GetProperty("changes").GetInt32(), changes.Count);
        Assert.AreEqual(singles.GetProperty("refused").GetInt32(), changes.Count(text => PairingCode.Read(text) is null));
    }

    /// <summary>Bug that this catches: the field sends the first 8 letters of a code of 13 while he still types it, as
    /// an older Mac's code: the hub refuses it, counts a wrong code, and the code may not go again. So, typed one key at a
    /// time with hyphens or with none, a code of 13 goes once, when it is whole; an older Mac's code (XXXX-XXXX, or one
    /// run of 8 to a Tailscale hub that its first 5 do not carry) still goes at 8; one run of 8 waits while this PC knows
    /// no hub or a hub that the rule cannot compare (192.0.2.10, a name), or while its first 5 carry the known hub; a
    /// space that is no plain space (a no-break space, an ideographic space) parts the groups as it parts the letters;
    /// and the 13 that he typed on while an older Mac's 8 were on their way go after the hub's answer, once.</summary>
    [TestMethod]
    public void TheFieldNeverSendsEightWhileThirteenAreComing()
    {
        var hub = new Uri("http://100.84.1.20:8765/");
        var other = new Uri("http://192.0.2.10:8765/");
        var name = new Uri("http://hub.example.ts.net:8765/");
        string[] Sends(string typed, Uri? known)
        {
            var form = new EnrollForm();
            var sent = new System.Collections.Generic.List<string>();
            for (var i = 1; i <= typed.Length; i++)
            {
                var (next, send) = form.Typed(typed[..i], known);
                form = next;
                if (send) sent.Add(form.Sent!);
            }
            return sent.ToArray();
        }
        foreach (var known in new Uri?[] { hub, null, other, name })
        {
            CollectionAssert.AreEqual(new[] { "LACFBYD92MYTA" }, Sends("LACFB-YD92-MYTA", known), $"hyphens, {known}");
            CollectionAssert.AreEqual(new[] { "LACFBYD92MYTA" }, Sends("lacfb yd92 myta", known), $"spaces, {known}");
            CollectionAssert.AreEqual(new[] { "LACFBYD92MYTA" }, Sends("LACFBYD92MYTA", known), $"no hyphen, {known}");
            CollectionAssert.AreEqual(new[] { "LACFBYD92MYTA" }, Sends("  LA-CFBYD-92MYTA ", known), $"hyphens in other places, {known}");
            CollectionAssert.AreEqual(new[] { "YD92MYTA" }, Sends("YD92-MYTA", known), $"an older Mac's code, {known}");
            CollectionAssert.AreEqual(new[] { "YD92MYTA" }, Sends("YD92\u00A0MYTA", known), $"a no-break space, {known}");
            CollectionAssert.AreEqual(new[] { "YD92MYTA" }, Sends("YD92\u3000MYTA", known), $"an ideographic space, {known}");
        }
        CollectionAssert.AreEqual(new[] { "YD92MYTA" }, Sends("YD92MYTA", hub), "an older Mac's code with no hyphen");
        foreach (var known in new Uri?[] { null, other, name })
            Assert.AreEqual(0, Sends("YD92MYTA", known).Length, $"one run of 8 waits for 13 where its first 5 say nothing, {known}");
        var (field, goes) = new EnrollForm().Typed("LACF-BYD9", other);
        Assert.IsTrue(goes, "an older Mac's form goes at 8");
        (field, goes) = field.Typed("LACF-BYD92MYTA", other);
        Assert.IsFalse(goes, "one code at a time");
        (field, goes) = field.Answered("This code did not work. Make a new one on your Mac.", other);
        Assert.AreEqual((true, "LACFBYD92MYTA"), (goes, field.Sent), "the 13 that he typed on go after the answer");
        (field, goes) = field.Answered("Your hub did not answer. Check that its server is on.", other);
        Assert.IsFalse(goes, "a code goes once");
    }

    /// <summary>Bug that this catches: the hub that a code of 13 carries is not the one that the PC sends to, so its 8 go
    /// to the wrong hub, or a typing fault that the check bits do not see sends a code to a wrong address. So with no
    /// hub on the PC, the carried hub is taken; with its own Tailscale hub, a code must carry that hub; a hub that the
    /// rule cannot compare (a name, another address) takes the code; and 8 characters go to the known hub only. And an
    /// address with full-width digits, which .NET's \d takes and its number parse throws on, is no hub of the rule and
    /// no fault.</summary>
    [TestMethod]
    public void ACodeGoesToTheHubThatItCarriesOrThatThePcFound()
    {
        var carries = PairingCode.Read("LACFB-YD92-MYTA")!;
        var tailscale = new Uri("http://100.84.1.20:8765/");
        Assert.AreEqual((new Uri("http://100.84.1.20:8765"), true, (string?)null), PairingCode.Target(carries, null));
        Assert.AreEqual((tailscale, false, (string?)null), PairingCode.Target(carries, tailscale));
        Assert.AreEqual(((Uri?)null, false, PairingCode.OtherHubWords),
                        PairingCode.Target(carries, new Uri("http://100.84.4.148:8765/")), "a typing fault the check missed");
        var name = new Uri("http://hub.example.ts.net:8765/");
        Assert.AreEqual((name, false, (string?)null), PairingCode.Target(carries, name));
        var old = PairingCode.Read("YD92-MYTA")!;
        Assert.AreEqual((tailscale, false, (string?)null), PairingCode.Target(old, tailscale));
        Assert.AreEqual(((Uri?)null, false, PairingCode.NoHubWords), PairingCode.Target(old, null));
        Assert.IsNull(PairingCode.Place("http://\uFF11\uFF10\uFF10.84.1.20:8765"), "full-width digits");
        Assert.AreEqual("YD92-MYTA", PairingCode.Shown("http://100.84.1.\uFF12\uFF10:8765", "YD92-MYTA"), "full-width digits");
    }

    /// <summary>The carried hub's address, which the test's hub on this machine answers; any other address goes as it is.</summary>
    private sealed class CarriedHub(Uri carried, Uri local) : DelegatingHandler(HubClient.NewHandler(new HubClientOptions()))
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
        {
            var to = request.RequestUri!;
            if (to.Host == carried.Host && to.Port == carried.Port)
                request.RequestUri = new UriBuilder(to) { Host = local.Host, Port = local.Port }.Uri;
            return base.SendAsync(request, cancel);
        }
    }

    /// <summary>A store of the device key whose write fails, as a full disk or a refused file does.</summary>
    private sealed class KeysThatCannotBeWritten : IDeviceKeyStore
    {
        public bool Has => false;
        public string? Read() => null;
        public void Write(string key) => throw new IOException("There is no room for the key.");
        public void Remove() { }
    }

    /// <summary>Bug that this catches: a PC with no hub does not take the hub that a code of 13 carries, so it stays with
    /// no hub; or it takes that hub before the hub answered, so a code that the hub refused, or a typing fault that the
    /// check bits did not see, keeps a wrong hub on this PC. So the code goes to the hub that it carries; a refusal leaves
    /// this PC with no hub and no hub.json; and the key that came makes that hub this PC's, read with the key, also at the
    /// next start.</summary>
    [TestMethod]
    public async Task APcWithNoHubTakesTheHubThatItsCodeCarriesOnlyWithTheKey()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-pairing-").FullName;
        using var hub = new FakeHub();
        var carried = new Uri("http://100.84.1.20:8765/");
        var keys = new MemoryKeyStore();
        OwnerStore Launch() => new(new StoreSettings { Folder = folder, Keys = keys }, new HubClient(new CarriedHub(carried, hub.Address)));
        try
        {
            await using (var store = Launch())
            {
                Assert.IsTrue(store.State.HasNoHub);
                hub.Gate = seen => seen.Target == "/ui/owner/enroll" ? LoopbackHub.Json(403, """{"error":"invalid or expired code"}""") : null;
                Assert.AreEqual("This code did not work. Make a new one on your Mac.", await store.EnrollAsync("LACFB-YD92-MYTA"));
                Assert.AreEqual(((Uri?)null, false), (store.State.Hub, File.Exists(Path.Combine(folder, "hub.json"))),
                                "a refused code leaves this PC with no hub");
                hub.Gate = null;
                Assert.IsNull(await store.EnrollAsync("LACFB-YD92-MYTA"));
                Assert.AreEqual((carried, KeyState.InHand, "device-key-1"), (store.State.Hub, store.State.Key, keys.Read()));
                Assert.AreEqual(2, hub.Server.Received.Count(r => r.Target == "/ui/owner/enroll"), "each code went to the hub that it carries");
                Assert.AreEqual("gen1", store.State.Fleet?.Db, "that hub is read with the key");
            }
            await using var again = Launch();
            Assert.AreEqual(carried, again.State.Hub, "the next start keeps that hub");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    /// <summary>Bug that this catches: the answer of a join moves in although this PC's hub changed while the code waited,
    /// so the carried hub and a key that is not for his new hub replace the hub that he connected to; or a join whose
    /// search found the code's own hub meanwhile loses a good key; or a key that this PC cannot keep leaves it on the
    /// carried hub with no key. So, with the answer held: Connect to another hub keeps that hub, with no key and no key
    /// sent to it; Connect to the carried hub keeps the key; and a failed write of the key leaves this PC with no hub
    /// and no hub.json.</summary>
    [TestMethod]
    public async Task TheAnswerOfAJoinMovesInOnlyWhileThePcHasNoHubOrTheCarriedOne()
    {
        var carried = new Uri("http://100.84.1.20:8765/");
        const string Spent = "This PC could not keep its key. Make a new code.";
        async Task Join(IDeviceKeyStore keys, Func<OwnerStore, Task> meanwhile, Action<string?, StoreState, bool> check)
        {
            var folder = Directory.CreateTempSubdirectory("founderizer-pairing-").FullName;
            using var hub = new FakeHub();
            try
            {
                await using var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = keys },
                                                       new HubClient(new CarriedHub(carried, hub.Address)));
                hub.HoldEnroll = new ManualResetEventSlim(false);
                var joining = store.EnrollAsync("LACFB-YD92-MYTA");
                for (var i = 0; i < 200 && !hub.Server.Received.Any(r => r.Target == "/ui/owner/enroll"); i++) await Task.Delay(25);
                await meanwhile(store);
                hub.HoldEnroll.Set();
                check(await joining, store.State, File.Exists(Path.Combine(folder, "hub.json")));
            }
            finally
            {
                Directory.Delete(folder, recursive: true);
            }
        }
        using var other = new FakeHub();
        var first = new MemoryKeyStore();
        await Join(first, async store => Assert.IsNull(await store.ConnectAsync(other.Address.ToString())),
                   (words, state, _) => Assert.AreEqual((Spent, other.Address, (string?)null), (words, state.Hub, first.Read()),
                                                        "he went to another hub: it stays, with no key"));
        Assert.IsFalse(other.Server.Received.Any(r => r.Header("Authorization") is not null), "no key reached the other hub");
        var second = new MemoryKeyStore();
        await Join(second, async store => Assert.IsNull(await store.ConnectAsync(carried.ToString())),
                   (words, state, _) => Assert.AreEqual(((string?)null, carried, KeyState.InHand, "device-key-1"),
                                                        (words, state.Hub, state.Key, second.Read()),
                                                        "the search found the code's own hub meanwhile: the key stays"));
        await Join(new KeysThatCannotBeWritten(), _ => Task.CompletedTask,
                   (words, state, kept) => Assert.AreEqual((Spent, (Uri?)null, false), (words, state.Hub, kept),
                                                           "a key that this PC cannot keep: no hub"));
    }

    /// <summary>Bug that this catches: the hub gets the 13 characters, which it does not take, or none. So the store sends
    /// a code of 13 for its own hub as the hub's 8, once (the hub here is on 127.0.0.1, which the rule cannot compare).</summary>
    [TestMethod]
    public async Task TheHubGetsTheLastEightCharacters()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-pairing-").FullName;
        using var hub = new FakeHub();
        try
        {
            await using var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore() });
            await store.ConnectAsync(hub.Address.ToString());
            Assert.IsNull(await store.EnrollAsync("LACFB-YD92-MYTA"));
            var enroll = hub.Server.Received.Single(r => r.Target.StartsWith("/ui/owner/enroll", StringComparison.Ordinal));
            Assert.AreEqual("YD92MYTA", JsonDocument.Parse(enroll.Body).RootElement.GetProperty("code").GetString());
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
