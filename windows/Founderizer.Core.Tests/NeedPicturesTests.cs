using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>Pictures as the options of a request (owner feature `need_pictures`, owner API 1.285): the state read says
/// that this build draws them, a card draws them only with one picture for each option, a click on a picture answers
/// nothing while a click on its words answers with that option's index or ticks it, and the pictures are read one after
/// another, a failed one only again by Read again, each by its id and SHA-256 in one generation. Example names
/// only.</summary>
[TestClass]
public sealed class NeedPicturesTests
{
    /// <summary>The bytes of each picture: the store checks their size and SHA-256, and never draws them.</summary>
    private static readonly byte[] Bytes = [0x89, (byte)'P', (byte)'N', (byte)'G', 13, 10, 26, 10, 1, 2, 3, 4];

    private static JsonObject Picture(long id) => new()
    {
        ["id"] = id, ["name"] = $"banner-{id}.png", ["mime"] = "image/png", ["size"] = Bytes.Length,
        ["sha256"] = Convert.ToHexStringLower(SHA256.HashData(Bytes)), ["created"] = Now - 300,
    };

    /// <summary>Marketing's request of three options, with the first <paramref name="pictures"/> of their pictures.</summary>
    private static JsonObject Asks(int pictures)
    {
        var need = Need(7, "Pick the banner for the spring sale", "The one you pick goes live on Monday.", "orla", Now - 240,
                        "Green, the flowers", "Yellow, big words", "Blue, the sky");
        need["pictures"] = new JsonArray(Enumerable.Range(0, pictures).Select(i => (JsonNode)Picture(801 + i)).ToArray());
        return need;
    }

    /// <summary>The sample fleet on a hub that names the feature, with <paramref name="need"/> open.</summary>
    private static JsonObject Fleet(JsonObject need)
    {
        var snapshot = Snapshot();
        snapshot["ui_features"]!.AsArray().Add((JsonNode)NeedPictures.Feature);
        snapshot["needs"]!.AsArray().Add(need);
        return snapshot;
    }

    private static (OptionsModel Card, OptionsModel AtHand) Options(JsonObject snapshot)
    {
        var state = State(Decode(snapshot), Clock);
        var need = state.Fleet!.Needs.Single(n => n.Id == 7);
        return (Screens.Card(state, need, [], Clock, Utc).Options, Screens.Step(state, need, [], Clock, Utc).Options);
    }

    /// <summary>Bug: the build draws the pictures and the hub never learns it, so no item ever has them; or a device's
    /// read says nothing, which takes its word back. The app's one read of the state, as a device (its key) and as the
    /// owner's computer (no key), says exactly what this build draws.</summary>
    [TestMethod]
    public async Task EachReadOfTheStateSaysThatThisBuildDrawsPictures()
    {
        using var hub = new LoopbackHub(_ => LoopbackHub.Json(200, Snapshot().ToJsonString()));
        using var client = new HubClient();
        await client.SnapshotAsync(hub.Address, "device-key", "gen1", null);
        await client.SnapshotAsync(hub.Address, null, null, "\"tag0\"");
        var reads = hub.Received.ToArray();
        Assert.AreEqual(2, reads.Length);
        foreach (var read in reads) Assert.AreEqual("need_pictures", read.Header("X-Fleet-Draws"), read.Target);
    }

    /// <summary>Bug: a picture over an option that is not its own. With three options and two pictures no picture can be
    /// known to be an option's, so the card in the chat and the request at hand are the card of before, word for word;
    /// with three, each option has its own, in their order.</summary>
    [TestMethod]
    public void ANeedWithFewerPicturesThanOptionsDrawsTheCardOfBefore()
    {
        var before = Options(Fleet(Asks(0)));
        Assert.AreEqual((OptionsKind.Press, 3, 0), (before.Card.Kind, before.Card.Labels.Count, before.Card.Pictures.Count));
        var two = Options(Fleet(Asks(2)));
        Assert.AreEqual(before.Card, two.Card);
        Assert.AreEqual(before.AtHand, two.AtHand);

        var three = Options(Fleet(Asks(3)));
        foreach (var options in new[] { three.Card, three.AtHand })
        {
            CollectionAssert.AreEqual(new long[] { 801, 802, 803 }, options.Pictures.Select(p => p.File.Id).ToArray());
            Assert.AreEqual(before.Card with { Pictures = options.Pictures }, options, "the options themselves stay as they are");
        }
    }

    /// <summary>The store against a stand-in hub that gives <paramref name="snapshot"/> and the bytes of each picture.</summary>
    private static async Task WithStore(JsonObject snapshot, Func<OwnerStore, FakeHub, Task> work)
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-pictures-").FullName;
        using var hub = new FakeHub { Snapshot = snapshot };
        hub.Gate = seen => seen.Target.StartsWith("/ui/attachments/", StringComparison.Ordinal)
            ? LoopbackHub.Raw(200, Bytes, ("Content-Type", "image/png")) : null;
        try
        {
            await using var store = new OwnerStore(new StoreSettings
            {
                Folder = folder, Keys = new MemoryKeyStore("device-key-1"), ClientLabel = "founderizer-windows/1",
            });
            await store.ConnectAsync(hub.Address.ToString());
            store.Unlock();
            await store.RefreshAsync();
            await work(store, hub);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    private static async Task<(string Path, JsonElement Body)> FirstWrite(FakeHub hub)
    {
        // The first write ends the wait; the cap of 20 s only makes a press that never goes fail here, in place of a
        // hang. A cap of 4 s failed once on a Mac that built in the VM and ran other tests (21 November 2026).
        for (var i = 0; i < 200 && hub.Writes.IsEmpty; i++) await Task.Delay(100);
        var write = hub.Writes.Single();
        return (write.Path, write.Body);
    }

    /// <summary>Bug: a look at a picture answers the request. A click on a picture opens it (its bytes, read and checked)
    /// and sends nothing; a click on an option's words sends `choice` with that option's index.</summary>
    [TestMethod]
    public Task AClickOnAPictureSendsNothingAndAClickOnItsWordsSendsItsIndex() => WithStore(Fleet(Asks(3)), async (store, hub) =>
    {
        var need = store.State.Fleet!.Needs.Single(n => n.Id == 7);
        var options = Screens.Card(store.State, need, [], Clock, Utc).Options;

        var picture = options.Click(1, onPicture: true);
        Assert.AreEqual((OptionClickKind.Open, 802L), (picture.Kind, picture.Picture?.File.Id));
        CollectionAssert.AreEqual(Bytes, await store.FileAsync(picture.Picture!.File), "the window opens its bytes");
        Assert.AreEqual(0, hub.Writes.Count, "a look at a picture answers nothing");

        var words = options.Click(1, onPicture: false);
        Assert.AreEqual((OptionClickKind.Press, 1), (words.Kind, words.Index));
        store.Press(need.Id, words.Index);
        var (path, body) = await FirstWrite(hub);
        Assert.AreEqual("/ui/needs/7", path);
        Assert.AreEqual(1, body.GetProperty("choice").GetInt32());
    });

    /// <summary>Bug: on a card of pictures whose options combine, a click on the words answers at once with one option,
    /// or Send sends other options than the ones ticked. A click on the words ticks that option and sends nothing; Send
    /// sends `choices` with the ticked indexes.</summary>
    [TestMethod]
    public Task OnACardThatCombinesAClickTicksAndSendSendsTheTickedIndexes()
    {
        var asks = Asks(3);
        asks["multi"] = true;
        return WithStore(Fleet(asks), async (store, hub) =>
        {
            var need = store.State.Fleet!.Needs.Single(n => n.Id == 7);
            var options = Screens.Card(store.State, need, [], Clock, Utc).Options;
            Assert.AreEqual((OptionsKind.Ticks, 3), (options.Kind, options.Pictures.Count));

            var first = options.Click(0, onPicture: false);
            var third = options.Click(2, onPicture: false);
            Assert.AreEqual((OptionClickKind.Tick, 0), (first.Kind, first.Index));
            Assert.AreEqual((OptionClickKind.Tick, 2), (third.Kind, third.Index));
            Assert.AreEqual(OptionClickKind.Open, options.Click(1, onPicture: true).Kind);
            await Task.Delay(300);
            Assert.AreEqual(0, hub.Writes.Count, "a tick and a look answer nothing");

            Assert.IsNull(await store.TickAsync(need.Id, [first.Index, third.Index]));
            var (path, body) = await FirstWrite(hub);
            Assert.AreEqual("/ui/needs/7", path);
            CollectionAssert.AreEqual(new long[] { 0, 2 }, body.GetProperty("choices").EnumerateArray().Select(e => e.GetInt64()).ToArray());
        });
    }

    // ---------------------------------------------------------------- the reads of the pictures (PictureLoads)

    private static MessageAttachment File(long id, char hash = 'a') =>
        new(id, $"banner-{id}.png", "image/png", 12, new string(hash, 64), Now - 300);

    /// <summary>Waits until <paramref name="done"/> holds, for at most two seconds.</summary>
    private static async Task Until(Func<bool> done)
    {
        for (var i = 0; i < 40 && !done(); i++) await Task.Delay(50);
    }

    /// <summary>Bug: a failed read starts again at each draw, with no end (a hub that does not answer, 409, 410, bytes
    /// whose SHA-256 is not the file's): the page draws again after each failure, and each draw asks for the picture. A
    /// failed read stays failed until Read again.</summary>
    [TestMethod]
    public async Task AFailedPictureReadStaysFailedUntilReadAgain()
    {
        var reads = 0;
        var fail = true;
        var first = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var loads = new PictureLoads<string>(async _ =>
        {
            Interlocked.Increment(ref reads);
            await first.Task;
            return fail ? throw new AttachmentException(AttachmentException.Problem.Bytes) : Bytes;
        }, _ => Task.FromResult<string?>("picture"), () => { });
        var file = File(801);

        Assert.IsNull(loads.Of(file));
        Assert.IsTrue(loads.Reads(file), "Reading…");
        first.SetResult();
        await loads.IdleAsync();
        Assert.AreEqual((1, true, false), (reads, loads.Failed(file), loads.Reads(file)));
        for (var draw = 0; draw < 5; draw++) Assert.IsNull(loads.Of(file));
        await loads.IdleAsync();
        Assert.AreEqual(1, reads, "a draw after the failure reads nothing");

        fail = false;
        loads.Again(file);
        await loads.IdleAsync();
        Assert.AreEqual((2, "picture"), (reads, loads.Of(file)));
    }

    /// <summary>Bug: a card's pictures all read at once, so on a slow link each waits behind the others and all fail at
    /// their timeout together. They are read one after another, in the order of the options.</summary>
    [TestMethod]
    public async Task ACardsPicturesAreReadOneAfterAnotherInTheOrderOfItsOptions()
    {
        var gates = new[] { 801L, 802, 803 }.ToDictionary(id => id, _ => new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously));
        var started = new List<long>();
        var loads = new PictureLoads<string>(async file =>
        {
            lock (started) started.Add(file.Id);
            await gates[file.Id].Task;
            return Bytes;
        }, _ => Task.FromResult<string?>("picture"), () => { });
        long[] Started() { lock (started) return started.ToArray(); }

        foreach (var id in new long[] { 801, 802, 803 }) loads.Of(File(id));
        foreach (var id in new long[] { 801, 802, 803 })
        {
            await Until(() => Started().Contains(id));
            await Task.Delay(150);
            Assert.AreEqual(id, Started().Last(), "the read of the next option waits");
            gates[id].SetResult();
        }
        await loads.IdleAsync();
        CollectionAssert.AreEqual(new long[] { 801, 802, 803 }, Started());
        Assert.AreEqual("picture", loads.Of(File(803)));
    }

    /// <summary>Bug: after a restore or a new database, an id names another file, and the picture of before stands over
    /// an option. A picture is its id and its SHA-256, and a new generation forgets every picture.</summary>
    [TestMethod]
    public async Task APictureIsItsIdAndItsHashInOneGeneration()
    {
        var reads = 0;
        var loads = new PictureLoads<string>(file =>
        {
            Interlocked.Increment(ref reads);
            return Task.FromResult(System.Text.Encoding.UTF8.GetBytes(file.Sha256[..1]));
        }, bytes => Task.FromResult<string?>(System.Text.Encoding.UTF8.GetString(bytes)), () => { });
        loads.Generation("hub gen1");
        var before = File(801, 'a');
        var other = File(801, 'b');

        loads.Of(before);
        await loads.IdleAsync();
        Assert.AreEqual("a", loads.Of(before));
        Assert.IsNull(loads.Of(other), "another file with the same id");
        await loads.IdleAsync();
        Assert.AreEqual(("b", "a"), (loads.Of(other), loads.Of(before)));

        loads.Generation("hub gen2");
        Assert.IsNull(loads.Of(before), "a new generation reads it again");
        await loads.IdleAsync();
        Assert.AreEqual(3, reads);
    }
}
