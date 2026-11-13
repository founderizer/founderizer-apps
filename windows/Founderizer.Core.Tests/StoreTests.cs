using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The store against a hub on 127.0.0.1 (MobileStore's rules): the read with its ETag, a new generation, the
/// open chat and its merge, the seen marks, the writes through the outbox with their receipts and refusals, enrollment,
/// Connect, what it keeps between launches, the wait, and the changes that it raises.</summary>
[TestClass]
public sealed class StoreTests
{
    private string folder = "";
    private FakeHub hub = null!;

    [TestInitialize]
    public void Make()
    {
        folder = Directory.CreateTempSubdirectory("founderizer-store-").FullName;
        hub = new FakeHub();
    }

    [TestCleanup]
    public void Remove()
    {
        hub.Dispose();
        Directory.Delete(folder, recursive: true);
    }

    private async Task<OwnerStore> Store(string? key = "device-key-1", HubClientOptions? options = null)
    {
        var store = new OwnerStore(new StoreSettings
        {
            Folder = folder, Keys = new MemoryKeyStore(key), ClientLabel = "founderizer-windows/1",
            Client = options ?? new HubClientOptions(),
        });
        await store.ConnectAsync(hub.Address.ToString());
        store.Unlock();
        await store.RefreshAsync();
        return store;
    }

    [TestMethod]
    public async Task AReadKeepsTheFleetAndAnUnchangedFleetIsA304()
    {
        await using var store = await Store();
        var s = store.State;
        Assert.AreEqual("gen1", s.Fleet!.Db);
        Assert.IsTrue(s.AnswersWrites(DateTimeOffset.UtcNow));
        Assert.AreEqual(KeyState.InHand, s.Key);
        var fleet = s.Fleet;
        await store.RefreshAsync();
        Assert.AreSame(fleet, store.State.Fleet, "a 304 keeps the reading");
        Assert.IsTrue(hub.Server.Received.Any(r => r.Target == "/ui/mobile?db=gen1" && r.Header("If-None-Match") is not null));
        Assert.IsTrue(hub.Server.Received.All(r => r.Target.StartsWith("/ui/owner/enroll") || r.Header("Authorization") == "Bearer device-key-1"));
    }

    [TestMethod]
    public async Task ANewGenerationForgetsTheChatsAndReadsAgain()
    {
        hub.Chats["manager"] = SampleFleet.ChatPage("gen1", "manager", SampleFleet.Report(5, SampleFleet.Now - 480, "Yes."));
        await using var store = await Store();
        store.OpenChat("manager");
        await store.RefreshAsync();
        Assert.AreEqual(1, store.State.Items("manager").Count);
        hub.Snapshot = SampleFleet.Snapshot(db: "gen2");
        hub.Chats.Clear();
        store.OpenChat(null);
        await store.RefreshAsync();
        for (var i = 0; i < 50 && store.State.Fleet?.Db != "gen2"; i++) await Task.Delay(50);
        Assert.AreEqual("gen2", store.State.Fleet!.Db);
        Assert.AreEqual(0, store.State.Items("manager").Count);
    }

    [TestMethod]
    public async Task TheOpenChatIsReadFirstAndItsPagesMergeByItem()
    {
        var mine = Guid.NewGuid().ToString("D");
        hub.Chats["wren"] = SampleFleet.ChatPage("gen1", "wren",
            SampleFleet.Report(4, SampleFleet.Now - 2400, "I answered 23 tickets today."),
            SampleFleet.Message(mine, SampleFleet.Now - 60, "Which order is it?"));
        await using var store = await Store();
        store.OpenChat("wren");
        await store.RefreshAsync();
        Assert.AreEqual(2, store.State.Items("wren").Count);
        hub.Chats["wren"] = SampleFleet.ChatPage("gen1", "wren",
            SampleFleet.Message(mine, SampleFleet.Now - 60, "Which order is it? (corrected)"),
            SampleFleet.Report(6, SampleFleet.Now - 30, "Order 1042.", inReplyTo: mine));
        await store.RefreshAsync();
        var items = store.State.Items("wren");
        Assert.AreEqual(3, items.Count);
        Assert.AreEqual("Which order is it? (corrected)", items[1].Text, "a held item takes the hub's newest version");
        Assert.AreEqual("report-6", items[2].Id);
        var chatRead = hub.Server.Received.ToList().FindIndex(r => r.Target.StartsWith("/ui/mobile/chat/wren"));
        var mobileRead = hub.Server.Received.ToList().FindLastIndex(r => r.Target.StartsWith("/ui/mobile?"));
        Assert.IsTrue(chatRead >= 0 && mobileRead > chatRead, "the open chat goes before the fleet on a known generation");
    }

    [TestMethod]
    public async Task ANewHubTakesItsRepliesAsSeenAndALaterReplyIsNew()
    {
        await using var store = await Store();
        Assert.IsFalse(store.State.HasNewReply("manager"));
        var snapshot = SampleFleet.Snapshot();
        snapshot["agents"]![0]!["last"] = SampleFleet.Preview(SampleFleet.Now + 10, "agent", "A new reply.");
        hub.Snapshot = snapshot;
        await store.RefreshAsync();
        Assert.IsTrue(store.State.HasNewReply("manager"));
        store.OpenChat("manager");
        Assert.IsFalse(store.State.HasNewReply("manager"));
        Assert.IsTrue(File.Exists(Path.Combine(folder, "seen.json")));
    }

    [TestMethod]
    public async Task AMessageGoesThroughTheOutboxAndItsReceiptClearsIt()
    {
        await using var store = await Store();
        store.SetDraft("wren", "  Which order is it?  ");
        await store.SendMessageAsync("wren");
        Assert.IsTrue(hub.Writes.TryDequeue(out var write));
        Assert.AreEqual("/ui/messages", write.Path);
        Assert.AreEqual("Which order is it?", write.Body.GetProperty("text").GetString());
        Assert.AreEqual("wren", write.Body.GetProperty("recipient").GetString());
        Assert.AreEqual("founderizer-windows/1", write.Seen.Header("X-Fleet-Client"));
        var s = store.State;
        Assert.IsNull(s.Pending);
        Assert.IsNull(s.SendError);
        Assert.IsFalse(s.Drafts.ContainsKey("wren"));
        Assert.IsNotNull(s.Delivered, "the bubble stays until the chat holds the message");
        Assert.IsNull(new Outbox(Path.Combine(folder, "outbox.json")).Load());
        // The chat's read that brings the message lets the delivered one go.
        hub.Chats["wren"] = SampleFleet.ChatPage("gen1", "wren",
            SampleFleet.Message(s.Delivered!.RequestIdText, SampleFleet.Now, "Which order is it?"));
        store.OpenChat("wren");
        await store.RefreshAsync();
        Assert.IsNull(store.State.Delivered);
    }

    [TestMethod]
    public async Task ARefusalKeepsTheRequestUntilItIsDiscardedAndGivesTheWordsBack()
    {
        await using var store = await Store();
        hub.Refuse = (403, """{"error":"wren is in setup"}""");
        store.SetDraft("wren", "Hello");
        await store.SendMessageAsync("wren");
        var s = store.State;
        Assert.AreEqual("Not sent: Wren is in setup.", s.Pending!.Refusal);
        Assert.AreEqual("Not sent: Wren is in setup.", s.SendError);
        Assert.IsFalse(s.CanWrite(DateTimeOffset.UtcNow), "one request waits at a time");
        store.DiscardRefused();
        Assert.IsNull(store.State.Pending);
        Assert.AreEqual("Hello", store.State.Drafts["wren"]);
    }

    [TestMethod]
    public async Task AWriteWithNoAnswerWaitsAndARetrySendsTheSameNumber()
    {
        await using var store = await Store(options: new HubClientOptions { RequestTimeout = TimeSpan.FromMilliseconds(400) });
        hub.Silent = true;
        store.SetDraft("manager", "Start the sale.");
        await store.SendMessageAsync("manager");
        var waiting = store.State.Pending!;
        Assert.AreEqual("Your hub did not confirm it. Sending it again does not send it twice.", store.State.SendError);
        hub.Silent = false;
        await store.RefreshAsync();
        Assert.IsTrue(store.State.CanRetry(DateTimeOffset.UtcNow));
        await store.RetryAsync();
        Assert.IsNull(store.State.Pending);
        var ids = hub.Writes.Select(w => w.Body.GetProperty("request_id").GetString()).Distinct().ToList();
        CollectionAssert.AreEqual(new[] { waiting.RequestIdText }, ids);
    }

    [TestMethod]
    public async Task RegisteredLoginTextTakesTheWordsAndTheDraftsOffThePc()
    {
        await using var store = await Store();
        hub.Refuse = (422, """{"error":"text matches a registered login"}""");
        store.SetDraft("manager", "the password is hunter2");
        store.SetAnswerDraft(1, "and hunter2");
        await store.SendMessageAsync("manager");
        var s = store.State;
        Assert.AreEqual("", s.Pending!.Text);
        Assert.IsNotNull(s.Pending.Refusal);
        Assert.AreEqual(0, s.Drafts.Count + s.AnswerDrafts.Count);
        Assert.IsFalse(File.ReadAllText(Path.Combine(folder, "outbox.json")).Contains("hunter2"));
        Assert.IsFalse(File.ReadAllText(Path.Combine(folder, "drafts.json")).Contains("hunter2"));
    }

    [TestMethod]
    public async Task APressAnswersARequestAndAPressThatCannotGoWaits()
    {
        await using var store = await Store();
        hub.Silent = true;
        var options = new HubClientOptions { RequestTimeout = TimeSpan.FromMilliseconds(300) };
        await using var slow = await Store(options: options);
        slow.SetDraft("manager", "first");
        await slow.SendMessageAsync("manager");                         // a request waits now
        slow.Press(2, 0);
        Assert.AreEqual(0, slow.State.WaitingPresses[2], "the press waits while the store cannot write");
        hub.Silent = false;
        await slow.RetryAsync();
        for (var i = 0; i < 40 && hub.Writes.All(w => w.Path != "/ui/needs/2"); i++) await Task.Delay(100);
        var answer = hub.Writes.First(w => w.Path == "/ui/needs/2");
        Assert.AreEqual(0, answer.Body.GetProperty("choice").GetInt32());
        Assert.IsFalse(answer.Body.TryGetProperty("answer", out _));
    }

    [TestMethod]
    public async Task EnrollmentKeepsTheKeyAndReadsThisPc()
    {
        var keys = new MemoryKeyStore();
        await using var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = keys });
        Assert.AreEqual(PageKind.AddThisPc, Screens.FirstPage(store.State).Kind);
        await store.ConnectAsync(hub.Address.ToString());
        Assert.AreEqual("A code is eight characters, as the Mac app shows it (XXXX-XXXX).", await store.EnrollAsync("ABC"));
        Assert.IsNull(await store.EnrollAsync("abcd-efgh"));
        Assert.AreEqual("device-key-1", keys.Read());
        Assert.AreEqual(KeyState.InHand, store.State.Key);
        Assert.AreEqual("pc", store.State.Device!.Device);
        Assert.IsNull(store.ForgetKey());
        Assert.AreEqual(KeyState.None, store.State.Key);
        Assert.IsNull(keys.Read());
    }

    [TestMethod]
    public async Task ConnectTakesOnlyAHubAddress()
    {
        await using var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore() });
        Assert.AreEqual("Enter an HTTP or HTTPS hub address without a path or login.", await store.ConnectAsync("hub/path"));
        Assert.AreEqual("Enter an HTTP or HTTPS hub address without a path or login.", store.State.AddressError);
        Assert.IsTrue(store.State.HasNoHub);
        Assert.IsNull(await store.ConnectAsync(hub.Address.ToString()));
        Assert.AreEqual(hub.Address, store.State.Hub);
        Assert.IsNull(store.State.AddressError);
    }

    [TestMethod]
    public async Task TheStoreKeepsItsReadingChatsSeenMarksDraftsAndWriteBetweenLaunches()
    {
        hub.Chats["manager"] = SampleFleet.ChatPage("gen1", "manager", SampleFleet.Report(5, SampleFleet.Now - 480, "Yes."));
        await using (var first = await Store())
        {
            first.OpenChat("manager");
            await first.RefreshAsync();
            first.SetDraft("orla", "Send it");
            hub.Refuse = (403, """{"error":"no"}""");
            first.SetDraft("theo", "Ship it");
            await first.SendMessageAsync("theo");
        }
        await using var second = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1") });
        var s = second.State;
        Assert.AreEqual(hub.Address, s.Hub);
        Assert.AreEqual("gen1", s.Fleet!.Db);
        Assert.AreEqual(1, s.Items("manager").Count);
        Assert.AreEqual("report-5", s.Items("manager")[0].Id);
        Assert.AreEqual("Send it", s.Drafts["orla"]);
        Assert.AreEqual("Ship it", s.Pending!.Text);
        Assert.IsNotNull(s.Pending.Refusal);
        Assert.IsNotNull(s.SeenContext);
        Assert.AreEqual(KeyState.Locked, s.Key, "a launch holds the key back until the window is in front");
        Assert.IsNull(s.LastRead, "a launch has read nothing yet");
        Assert.IsFalse(s.ShowsCurrent(DateTimeOffset.UtcNow));
    }

    [TestMethod]
    public async Task InFrontTheStoreWaitsOnTheHubAndAWakeReadsAgain()
    {
        await using var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1") });
        await store.ConnectAsync(hub.Address.ToString());
        store.SetFront(true);
        for (var i = 0; i < 50 && hub.WaitReads == 0; i++) await Task.Delay(50);
        Assert.IsTrue(hub.WaitReads > 0, "the store waits on GET /ui/wait in front");
        var reads = hub.MobileReads;
        hub.WaitToken = "boot.2.1";                                  // the state count moved: a wake
        for (var i = 0; i < 60 && hub.MobileReads == reads; i++) await Task.Delay(50);
        Assert.IsTrue(hub.MobileReads > reads, "a wake reads the fleet again");
        store.SetFront(false);
        // Behind, the open app keeps its key and its wait, so that a new request notifies (decision D4); a start still
        // holds the key back until the window is in front.
        Assert.AreEqual(KeyState.InHand, store.State.Key);
    }

    [TestMethod]
    public async Task EachChangeSaysWhichRowsChangedAndComesInOrder()
    {
        var changes = new ConcurrentQueue<StoreChange>();
        await using var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1") });
        store.Changed += (_, change) => changes.Enqueue(change);
        await store.ConnectAsync(hub.Address.ToString());
        store.Unlock();
        await store.RefreshAsync();
        var versions = changes.Select(c => c.After.Version).ToList();
        CollectionAssert.AreEqual(versions.Order().ToList(), versions, "the changes come in order");
        Assert.IsTrue(changes.Any(c => c.Fleet && c.Agents.Contains("manager") && c.Needs.Contains(2) && c.Tasks.Contains(13)));
        changes.Clear();
        var snapshot = SampleFleet.Snapshot();
        snapshot["agents"]![4]!["last"] = SampleFleet.Preview(SampleFleet.Now + 5, "agent", "Sent.");
        hub.Snapshot = snapshot;
        await store.RefreshAsync();
        var fleetChange = changes.First(c => c.Fleet);
        Assert.IsTrue(fleetChange.Agents.Contains("orla"));
        Assert.IsFalse(fleetChange.Needs.Contains(1), "a request that did not change is not named");
        var before = Screens.Pane(fleetChange.Before, Page.Needs, SampleFleet.Clock, SampleFleet.Utc);
        var after = Screens.Pane(fleetChange.After, Page.Needs, SampleFleet.Clock, SampleFleet.Utc);
        var rows = RowDiff.Of(before.Agents, after.Agents, r => r.Key);
        CollectionAssert.AreEqual(new[] { "orla" }, rows.Changed.ToArray());
        Assert.IsFalse(rows.Moved);
    }

    [TestMethod]
    public async Task AFileGoesUpBeforeItsMessageAndComesBackFromThePcsOwnCopy()
    {
        await using var store = await Store();
        var bytes = "a note"u8.ToArray();
        Assert.AreEqual("This hub takes images, PDF, ZIP, text, Markdown, CSV and JSON.",
                        await store.AddFileAsync("agent:manager", "tool.exe", bytes));
        Assert.IsNull(await store.AddFileAsync("agent:manager", "note.txt", bytes));
        var staged = store.State.Staged["agent:manager"].Single();
        Assert.AreEqual("note.txt", staged.File!.Name);
        CollectionAssert.AreEqual(bytes, await store.FileAsync(staged.File));
        await store.SendMessageAsync("manager", "");
        var write = hub.Writes.Last();
        Assert.AreEqual(7, write.Body.GetProperty("attachments")[0].GetInt64());
        Assert.IsFalse(store.State.Staged.ContainsKey("agent:manager"), "a file that went leaves its composer");
    }

    [TestMethod]
    public async Task TheCommandsOfATaskAndARequestGoWithTheirFeatures()
    {
        await using var store = await Store();
        await store.ControlAsync(12, TaskControl.Pause);
        var control = hub.Writes.Last();
        Assert.AreEqual("/ui/tasks/12/control", control.Path);
        Assert.AreEqual("pause", control.Body.GetProperty("action").GetString());
        Assert.IsNull(store.State.Pending);
        var snapshot = SampleFleet.Snapshot();
        snapshot["ui_features"] = new JsonArray("mobile");
        hub.Snapshot = snapshot;
        await store.RefreshAsync();
        var count = hub.Writes.Count;
        await store.ControlAsync(12, TaskControl.Stop);
        Assert.AreEqual(count, hub.Writes.Count, "a hub without the feature gets no command");
    }
}
