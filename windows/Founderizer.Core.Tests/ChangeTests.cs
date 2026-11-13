using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>Fewer changes from the store: one only when a model of a screen changed, and each says which parts did. The
/// window session measured about five changes for each change of the hub, and 68 of 80 that changed nothing on the
/// pane.</summary>
[TestClass]
public sealed class ChangeTests
{
    private static readonly DateTimeOffset Now = SampleFleet.Clock;
    private static readonly ScreenContext Utc = SampleFleet.Utc;

    private static StoreState Sample() => SampleFleet.State(SampleFleet.Decode(SampleFleet.Snapshot()), Now);

    private static StoreState WithChat(StoreState s, string agent, int items)
    {
        var page = HubDecode.ChatPage(Encoding.UTF8.GetBytes(SampleFleet.ChatPage("gen1", agent,
            Enumerable.Range(1, items).Select(i => i % 2 == 0
                ? SampleFleet.Report(i, SampleFleet.Now - 9000 + i * 30, $"Reply {i} with **bold**, `code` and a [link](https://example.com).")
                : SampleFleet.Message($"0b5f6c8e-1111-4222-8333-{i:D12}", SampleFleet.Now - 9000 + i * 30, $"Message {i}")).ToArray()).ToJsonString()), "gen1", agent);
        return s with { Chats = s.Chats.SetItem(agent, new ChatPageState { Agent = agent, Items = ValueList.Of(page.Items) }) };
    }

    [TestMethod]
    public void TwoReadingsOfOneFleetChangeNoModel()
    {
        // Each read decodes new objects: the models compare by value, so the same fleet read again changes nothing.
        var s = WithChat(Sample(), "manager", 12) with { OpenChat = "manager", OpenTask = 12 };
        var again = WithChat(s with { Fleet = SampleFleet.Decode(SampleFleet.Snapshot()) }, "manager", 12);
        Assert.AreNotSame(s.Items("manager")[0], again.Items("manager")[0]);
        var change = StoreChange.Between(s, again, Now, Utc);
        Assert.AreEqual(StoreParts.None, change.Parts);
        Assert.AreEqual(0, change.Agents.Count);
        Assert.AreEqual(StoreParts.None, StoreChange.Between(s, s with { Version = 9, Clock = Now.AddSeconds(5), Refreshing = true }, Now, Utc).Parts,
                        "a read that runs changes nothing that a screen draws while the reading is current");
    }

    [TestMethod]
    public void EachChangeNamesThePartsWhoseModelsChanged()
    {
        var s = Sample();
        Assert.AreEqual(StoreParts.None, StoreChange.Between(s, s with { Drafts = s.Drafts.SetItem("wren", "Hi") }, Now, Utc).Parts,
                        "the draft of a chat that is not open draws nothing");
        var open = s with { OpenChat = "wren" };
        Assert.AreEqual(StoreParts.Chat, StoreChange.Between(s, open, Now, Utc).Parts);
        Assert.AreEqual(StoreParts.Chat, StoreChange.Between(open, open with { Drafts = s.Drafts.SetItem("wren", "Hi") }, Now, Utc).Parts);
        Assert.AreEqual(StoreParts.Settings, StoreChange.Between(s, s with { Search = HubSearch.Looking }, Now, Utc).Parts);
        // One more request: the pane's count, Needs you, the manager's row and the board of the task that waits on it.
        var snapshot = SampleFleet.Snapshot();
        snapshot["needs"]!.AsArray().Add(SampleFleet.Need(3, "Renew the domain?", "It ends on Friday.", "pax", SampleFleet.Now - 60));
        var more = s with { Fleet = SampleFleet.Decode(snapshot) };
        var change = StoreChange.Between(s, more, Now, Utc);
        Assert.IsTrue(change.Parts.HasFlag(StoreParts.Pane) && change.Parts.HasFlag(StoreParts.Needs), change.Parts.ToString());
        Assert.IsFalse(change.Parts.HasFlag(StoreParts.Settings) || change.Parts.HasFlag(StoreParts.Line) || change.Parts.HasFlag(StoreParts.Chat));
        Assert.IsTrue(change.Needs.Contains(3));
        // The reading grows old: the line, the pane's marks and Settings' last reading.
        var old = StoreChange.Between(s, s with { ReadError = HubException.NoAnswer() }, Now, Utc);
        Assert.IsTrue(old.Parts.HasFlag(StoreParts.Line) && old.Parts.HasFlag(StoreParts.Settings), old.Parts.ToString());
    }

    [TestMethod]
    public void TheModelsOfAChangeCostLittle()
    {
        var s = WithChat(Sample(), "manager", 200) with { OpenChat = "manager" };
        StoreView.Of(s, Now, Utc);
        var watch = Stopwatch.StartNew();
        for (var i = 0; i < 20; i++) StoreView.Of(s, Now, Utc);
        var each = watch.Elapsed.TotalMilliseconds / 20;
        Console.WriteLine($"the models of one state, with a chat of 200 items open: {each:F2} ms");
        Assert.IsTrue(each < 50, $"{each:F2} ms");
    }

    // ---------------------------------------------------------------- the store against a hub

    private string folder = "";
    private FakeHub hub = null!;

    [TestInitialize]
    public void Make()
    {
        folder = Directory.CreateTempSubdirectory("founderizer-change-").FullName;
        hub = new FakeHub();
    }

    [TestCleanup]
    public void Remove()
    {
        hub.Dispose();
        Directory.Delete(folder, recursive: true);
    }

    [TestMethod]
    public async Task AReadThatBringsNothingNewRaisesNoChangeAndAHubChangeRaisesOne()
    {
        await using var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1") });
        await store.ConnectAsync(hub.Address.ToString());
        store.Unlock();
        await store.RefreshAsync();
        await Task.Delay(300);                                       // the chats that changed are read in the background
        var changes = new ConcurrentQueue<StoreChange>();
        store.Changed += (_, change) => changes.Enqueue(change);
        for (var i = 0; i < 10; i++) await store.RefreshAsync();
        await Task.Delay(300);
        Assert.AreEqual(0, changes.Count, string.Join("; ", changes.Select(c => c.Parts)));
        Assert.IsTrue(hub.MobileReads >= 11);
        // Marketing's last message: one change, of the pane, that names its row.
        var snapshot = SampleFleet.Snapshot();
        snapshot["agents"]![4]!["last"] = SampleFleet.Preview(SampleFleet.Now + 5, "agent", "Sent.");
        hub.Snapshot = snapshot;
        await store.RefreshAsync();
        await Task.Delay(300);
        Assert.AreEqual(1, changes.Count, string.Join("; ", changes.Select(c => c.Parts)));
        var change = changes.Single();
        Assert.AreEqual(StoreParts.Pane, change.Parts);
        CollectionAssert.AreEqual(new[] { "orla" }, change.Agents.ToArray());
        Assert.IsTrue(change.Fleet);
    }
}
