using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>A press of the owner is never lost with no word (the window session's scripted run of slice 1.4: the first
/// Pause made no hold). The window draws a change after the store made it, so a press can come while the store cannot
/// write: such a write waits for the write before it, or for the read that comes, and then goes; a write that cannot go
/// for a lasting reason gives the owner's words. The reading that turns old by time alone raises its change then.</summary>
[TestClass]
public sealed class WriteWaitTests
{
    private string folder = "";
    private FakeHub hub = null!;

    [TestInitialize]
    public void Make()
    {
        folder = Directory.CreateTempSubdirectory("founderizer-writes-").FullName;
        hub = new FakeHub();
    }

    [TestCleanup]
    public void Remove()
    {
        hub.Hold?.Set();
        hub.HoldReads?.Set();
        hub.Dispose();
        Directory.Delete(folder, recursive: true);
    }

    private async Task<OwnerStore> Store(IStoreClock? clock = null, HubClientOptions? options = null)
    {
        var store = new OwnerStore(new StoreSettings
        {
            Folder = folder, Keys = new MemoryKeyStore("device-key-1"), ClientLabel = "founderizer-windows/1",
            Clock = clock ?? SystemClock.Shared, Client = options ?? new HubClientOptions(),
        });
        await store.ConnectAsync(hub.Address.ToString());
        store.Unlock();
        await store.RefreshAsync();
        return store;
    }

    private static async Task Until(Func<bool> condition, string what)
    {
        for (var i = 0; i < 200 && !condition(); i++) await Task.Delay(25);
        Assert.IsTrue(condition(), what);
    }

    [TestMethod]
    public async Task APauseThatComesWhileTheGuidanceWaitsForItsReceiptGoesAfterIt()
    {
        await using var store = await Store();
        hub.Hold = new ManualResetEventSlim(false);
        var guidance = store.GuideAsync(12, "Test the checkout on Windows too.");
        await Until(() => hub.Writes.Count == 1 && store.State.Sending, "the guidance is at the hub, and its receipt is on its way");
        Assert.IsTrue(Screens.Task(store.State, 12, DateTimeOffset.UtcNow, SampleFleet.Utc) is null or { Controls.Enabled: false },
                      "the model draws Pause off now; a window that has not drawn it yet still shows it on");
        var pause = store.ControlAsync(12, TaskControl.Pause);
        await Task.Delay(300);
        Assert.IsFalse(pause.IsCompleted, "the press waits for the write before it");
        hub.Hold.Set();
        var guided = await guidance;
        Assert.IsNull(guided, guided);
        Assert.IsNull(await pause, "the press went");
        CollectionAssert.AreEqual(new[] { "/ui/tasks/12/steer", "/ui/tasks/12/control" }, hub.Writes.Select(w => w.Path).ToArray());
        Assert.AreEqual("pause", hub.Writes.Last().Body.GetProperty("action").GetString());
        Assert.IsNull(store.State.Pending);
    }

    [TestMethod]
    public async Task PressesThatWaitGoInTheOrderTheyCameAndOneAtATime()
    {
        await using var store = await Store();
        hub.Hold = new ManualResetEventSlim(false);
        var first = store.SendMessageAsync("manager", "First.");
        await Until(() => hub.Writes.Count == 1, "the first message is at the hub");
        var stop = store.ControlAsync(12, TaskControl.Stop);
        await Task.Delay(50);
        var second = store.SendMessageAsync("manager", "Second.");
        await Task.Delay(50);
        var pause = store.ControlAsync(13, TaskControl.Pause);
        await Task.Delay(200);
        Assert.AreEqual(1, hub.Writes.Count, "nothing goes while a write is on its way");
        hub.Hold.Set();
        foreach (var write in new[] { first, stop, second, pause }) Assert.IsNull(await write);
        CollectionAssert.AreEqual(new[] { "/ui/messages", "/ui/tasks/12/control", "/ui/messages", "/ui/tasks/13/control" },
                                  hub.Writes.Select(w => w.Path).ToArray());
        Assert.AreEqual("Second.", hub.Writes.ElementAt(2).Body.GetProperty("text").GetString());
    }

    [TestMethod]
    public async Task APressThatCannotGoForALastingReasonGivesTheOwnersWords()
    {
        await using var store = await Store(options: new HubClientOptions { RequestTimeout = TimeSpan.FromSeconds(1) });
        // The write before it gets no receipt: it stays in the outbox, and the press behind it does not go.
        hub.Silent = true;
        var message = store.SendMessageAsync("manager", "Is the build green?");
        await Until(() => hub.Writes.Count == 1, "the message is at the hub");
        var pause = store.ControlAsync(12, TaskControl.Pause);
        Assert.AreEqual("Your hub did not confirm it. Sending it again does not send it twice.", await message);
        Assert.AreEqual("A saved request waits. Check it in Settings.", await pause);
        Assert.AreEqual(StoreState.SavedRequestWaits, await store.GuideAsync(12, "And on Windows."), "a press after it says it at once");
        Assert.AreEqual(1, hub.Writes.Count, "nothing of the two presses went");
        // The hub that does not answer: the connection line's words.
        var held = store.State with { Pending = null, ReadError = HubException.NoAnswer(new IOException("no route")) };
        Assert.AreEqual(new WriteHold(false, "Your hub did not answer. Check that its server is on."), held.HoldsWrites(DateTimeOffset.UtcNow));
        Assert.AreEqual(new WriteHold(true, null), (held with { ReadError = null, Sending = true }).HoldsWrites(DateTimeOffset.UtcNow));
        Assert.AreEqual(new WriteHold(false, "Cannot save this request. Nothing was sent."),
                        (held with { StorageError = "Cannot save this request. Nothing was sent." }).HoldsWrites(DateTimeOffset.UtcNow));
    }

    [TestMethod]
    public async Task AWriteOnAReadingThatTurnedOldWaitsForTheReadThatRunsAndGoesAfterIt()
    {
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        await using var store = await Store(clock);
        store.SetFront(true);
        await Until(() => store.State.Front && !store.State.Refreshing && store.State.CanWrite(clock.Now), "in front, read");
        // The front loop's next read comes and gets no answer yet: the reading turns old while it runs.
        hub.HoldReads = new ManualResetEventSlim(false);
        clock.Advance(TimeSpan.FromSeconds(50));
        await Until(() => store.State.Refreshing, "a read runs");
        Assert.IsFalse(store.State.CanWrite(clock.Now), "the reading is old");
        Assert.AreEqual(new WriteHold(true, null), store.State.HoldsWrites(clock.Now), "a read comes: the press waits for it");
        var pause = store.ControlAsync(12, TaskControl.Pause);
        for (var i = 0; i < 10; i++) { clock.Advance(TimeSpan.FromMilliseconds(100)); await Task.Delay(20); }
        Assert.IsFalse(pause.IsCompleted);
        Assert.AreEqual(0, hub.Writes.Count, "nothing goes on an old reading");
        hub.HoldReads.Set();
        for (var i = 0; i < 200 && !pause.IsCompleted; i++) { clock.Advance(TimeSpan.FromMilliseconds(100)); await Task.Delay(20); }
        Assert.IsNull(await pause, "the press went after the read answered");
        Assert.AreEqual("/ui/tasks/12/control", hub.Writes.Single().Path);
        store.SetFront(false);
    }

    [TestMethod]
    public async Task TheReadingThatTurnsOldRaisesItsChangeAtThatMoment()
    {
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        await using var store = await Store(clock);
        store.OpenChat("manager");
        store.SetDraft("manager", "Hello.");
        await store.RefreshAsync();
        await Task.Delay(300);
        Assert.IsTrue(Screens.Chat(store.State, "manager", clock.Now, SampleFleet.Utc).Composer.CanSend);
        var changes = new ConcurrentQueue<StoreChange>();
        store.Changed += (_, change) => changes.Enqueue(change);
        clock.Advance(TimeSpan.FromSeconds(40));
        await Task.Delay(100);
        Assert.IsTrue(store.State.CanWrite(clock.Now));
        clock.Advance(TimeSpan.FromSeconds(6));
        await Until(() => !changes.IsEmpty, "a change at the moment the reading turned old");
        var change = changes.Last();
        Assert.IsTrue(change.Parts.HasFlag(StoreParts.Chat), change.Parts.ToString());
        Assert.IsFalse(Screens.Chat(change.After, "manager", clock.Now, SampleFleet.Utc).Composer.CanSend,
                       "the window draws Send off with that change");
    }
}

/// <summary>A clock that moves only when a test moves it; its delays end then.</summary>
internal sealed class ManualClock(DateTimeOffset start) : IStoreClock
{
    private readonly object gate = new();
    private DateTimeOffset now = start;
    private double up = 1000;
    private readonly List<(double At, TaskCompletionSource Done)> waits = [];

    public DateTimeOffset Now { get { lock (gate) return now; } }
    public double Uptime { get { lock (gate) return up; } }

    public Task Delay(TimeSpan delay, CancellationToken cancel)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate) waits.Add((up + delay.TotalSeconds, done));
        if (cancel.CanBeCanceled) cancel.Register(() => done.TrySetCanceled(cancel));
        return done.Task;
    }

    public void Advance(TimeSpan by)
    {
        List<TaskCompletionSource> due;
        lock (gate)
        {
            now += by;
            up += by.TotalSeconds;
            due = waits.Where(w => w.At <= up).Select(w => w.Done).ToList();
            waits.RemoveAll(w => w.At <= up);
        }
        foreach (var d in due) d.TrySetResult();
    }
}
