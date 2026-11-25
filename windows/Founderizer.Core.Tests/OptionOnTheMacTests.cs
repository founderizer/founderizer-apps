using System;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>**The first option of a GitHub App's card and of an Add device card is the Mac's** (FleetCore's
/// OwnerNeed.firstOptionStartsOnTheMac, which the iPhone's MobileStore.startsOnTheMac holds to): only the Mac's press
/// makes the App (GitHub's manifest flow) or opens the Add device picture, and a press on Windows answered the card with
/// choice 0, so the hub closed it and nothing started. The option stands with its own words, grey and off; no route of
/// the store sends it; the other options still go. Example names only.</summary>
[TestClass]
public sealed class OptionOnTheMacTests
{
    private string folder = "";
    private FakeHub hub = null!;

    [TestInitialize]
    public void Make()
    {
        folder = Directory.CreateTempSubdirectory("founderizer-mac-option-").FullName;
        hub = new FakeHub();
        var needs = hub.Snapshot["needs"]!.AsArray();
        needs[0]!["github_app"] = "example-org";                  // "Refund it" stands for "Make the App"
        needs[1]!["add_device"] = 1;                              // "Send it on Monday" stands for "Show the picture"
        needs[1]!["multi"] = true;
        needs.Add(Need(3, "Connect the example shop?", "The import needs it.", "manager", Now - 600, "Yes", "No"));
        needs[2]!["github_app"] = "";                             // an empty account and add_device 0 change nothing
        needs[2]!["add_device"] = 0;
        // The Mac's rule takes only an item of two options or more that is no team yes, no full access and no give
        // (FleetCore's onlyOnAComputer): this PC presses those first options itself.
        needs.Add(Need(4, "Add the example designer to the team?", "They asked to join.", "manager", Now - 500, "Yes", "No"));
        needs[3]!["github_app"] = "example-org";
        needs[3]!["team"] = true;
        needs.Add(Need(5, "Give the example agent full access?", "It needs a shell.", "manager", Now - 400, "Give it", "Not now"));
        needs[4]!["add_device"] = 1;
        needs[4]!["door_host"] = "worker-1";
        needs.Add(Need(6, "Share the example server?", "Another agent needs it.", "manager", Now - 300, "Share it", "Not now"));
        needs[5]!["add_device"] = 1;
        needs[5]!["give"] = new JsonObject { ["vps"] = "use" };
        needs.Add(Need(7, "Make the example App?", "The repository needs it.", "manager", Now - 200, "Make it"));
        needs[6]!["github_app"] = "example-org";
    }

    [TestCleanup]
    public async Task Remove()
    {
        hub.Dispose();
        for (var i = 0; i < 10; i++)
        {
            try { Directory.Delete(folder, recursive: true); break; }
            catch (IOException) { await Task.Delay(100); }
        }
    }

    private async Task<OwnerStore> Store(ManualClock clock)
    {
        var store = new OwnerStore(new StoreSettings
        {
            Folder = folder, Keys = new MemoryKeyStore("device-key-1"), ClientLabel = "founderizer-windows/1", Clock = clock,
        });
        await store.ConnectAsync(hub.Address.ToString());
        store.Unlock();
        await store.RefreshAsync();
        return store;
    }

    private static OwnerNeed Item(OwnerStore store, long id) => store.State.Fleet!.Needs.Single(n => n.Id == id);

    /// <summary>Bug that this catches: the first option of such a card is a row like the others, which he presses on
    /// Windows, and the card closes with nothing started; or the PC holds a first option that the Mac's rule leaves to
    /// a computer's press. So the card in a chat and the request at hand on Needs you both hold that option off (with its
    /// own words), a click on it does nothing, and every other option stays on; a card with an empty account and
    /// add_device 0, a team yes, a full access, a give and a card of one option hold none (the Mac's rule, whole).</summary>
    [TestMethod]
    public async Task TheFirstOptionOfAGitHubAppOrAnAddDeviceCardIsOff()
    {
        await using var store = await Store(new ManualClock(DateTimeOffset.UtcNow));
        foreach (var id in new long[] { 1, 2 })
        {
            var card = Screens.Card(store.State, Item(store, id), [], Clock, Utc).Options;
            var step = Screens.Step(store.State, Item(store, id), [], Clock, Utc).Options;
            foreach (var options in new[] { card, step })
            {
                CollectionAssert.AreEqual(new[] { 0 }, options.OnlyOnTheMac.ToArray(), $"card {id}");
                Assert.AreEqual(Item(store, id).Choices[0], options.Labels[0], "the option keeps its own words");
                Assert.AreEqual(OptionClickKind.Nothing, options.Click(0, onPicture: false).Kind);
                Assert.AreNotEqual(OptionClickKind.Nothing, options.Click(1, onPicture: false).Kind);
            }
        }
        Assert.AreEqual(0, Screens.Card(store.State, Item(store, 3), [], Clock, Utc).Options.OnlyOnTheMac.Count);
        foreach (var (id, what) in new[] { (4L, "a team yes"), (5L, "full access"), (6L, "a give"), (7L, "one option") })
            Assert.IsFalse(Item(store, id).FirstOptionOnTheMac, what);
    }

    /// <summary>Bug that this catches: a route of the store sends choice 0 of such a card (a press, a press that waits for
    /// the store, the 5-second hold of a press, the ticks of a card whose options combine, their hold), and the hub
    /// closes the card with nothing started. So none of them reaches the hub, none waits on the card, and it stays open;
    /// the card's other options and ticks still go. The refused ticks end at once: a write would wait for the press
    /// before it on this test's clock, which moves only after them, and the test would hang and not fail.</summary>
    [TestMethod]
    public async Task NoRouteOfTheStoreSendsSuchAFirstOption()
    {
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        await using var store = await Store(clock);
        store.Press(1, 0);
        Assert.IsNull(store.Hold(1, CardAnswer.Option(0)));
        Assert.IsTrue(store.State.HeldAnswers.IsEmpty, "the 5-second hold of a press holds no such option");
        var ticks = store.TickAsync(2, [0, 1]);
        Assert.IsTrue(ticks.IsCompleted, "the ticks of such an option are no write, and wait for nothing");
        Assert.IsNull(await ticks);
        Assert.IsNull(store.Hold(2, CardAnswer.Ticked([0, 1])));
        Assert.IsTrue(store.State.HeldAnswers.IsEmpty, "the hold of ticks holds none with such an option");
        clock.Advance(TimeSpan.FromSeconds(6));
        await Task.Delay(400);
        Assert.AreEqual(0, hub.Writes.Count, "nothing reached the hub");
        Assert.IsTrue(store.State.HeldAnswers.IsEmpty && store.State.WaitingPresses.IsEmpty, "nothing waits on a card");
        Assert.IsTrue(Item(store, 1).IsOpen && Item(store, 2).IsOpen, "the cards stay open");

        // Another option goes, and the hub holds its answer: the store cannot write while it waits.
        hub.Hold = new ManualResetEventSlim(false);
        store.Press(1, 2);
        for (var i = 0; i < 200 && !store.State.Sending; i++) await Task.Delay(25);
        Assert.IsFalse(store.State.CanWrite(clock.Now), "a write is on its way");
        store.Press(2, 0);
        Assert.IsTrue(store.State.WaitingPresses.IsEmpty, "a press that waits for the store waits with no such option");
        hub.Hold.Set();
        for (var i = 0; i < 200 && !store.State.CanWrite(clock.Now); i++) await Task.Delay(25);
        Assert.AreEqual(2, hub.Writes.Single().Body.GetProperty("choice").GetInt32(), "another option goes");

        // The card's other ticks go: the wall is the first option's, not the card's.
        await store.TickAsync(2, [1]).WaitAsync(TimeSpan.FromSeconds(10));
        var ticked = hub.Writes.Skip(1).Single();
        Assert.AreEqual(("/ui/needs/2", 1), (ticked.Path, ticked.Body.GetProperty("choices").EnumerateArray().Single().GetInt32()),
                        "ticks with no such option go");
    }
}
