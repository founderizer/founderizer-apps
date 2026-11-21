using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>His answer on a card waits 5 seconds with Undo before it goes (the owner's "Yes, 5 seconds (Recommended)" and
/// "Yes, Undo there too" of 21 November 2026; the Mac's AnswerHolds): nothing reaches the hub during the wait, it goes
/// once when the wait ends or at the app's end, and Undo opens the card as it was. Example names only.</summary>
[TestClass]
public sealed class AnswerHoldTests
{
    private string folder = "";
    private FakeHub hub = null!;

    [TestInitialize]
    public void Make()
    {
        folder = Directory.CreateTempSubdirectory("founderizer-holds-").FullName;
        hub = new FakeHub();
    }

    [TestCleanup]
    public async Task Remove()
    {
        hub.Hold?.Set();
        hub.Dispose();
        // A store can still end a write in its folder while the folder goes: try again for a second (NeedPicturesTests).
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

    private static async Task Until(Func<bool> condition, string what)
    {
        for (var i = 0; i < 200 && !condition(); i++) await Task.Delay(25);
        Assert.IsTrue(condition(), what);
    }

    /// <summary>The bodies of his answers to <paramref name="need"/> that reached the hub.</summary>
    private System.Text.Json.JsonElement[] Answers(long need) =>
        hub.Writes.Where(w => w.Path == $"/ui/needs/{need}").Select(w => w.Body).ToArray();

    /// <summary>The hub's reading has the request answered, as the hub writes it once it took his answer.</summary>
    private void Answered(long id, string answer)
    {
        var needs = hub.Snapshot["needs"]!.AsArray();
        var need = needs.Single(n => n!["id"]!.GetValue<long>() == id)!.AsObject();
        needs.Remove(need);
        need["answer"] = answer;
        need["answered"] = Now;
        need["answered_by"] = "owner";
        hub.Snapshot["answered_needs"]!.AsArray().Add(need);
    }

    private static RequestCard Card(OwnerStore store, long need) =>
        Screens.Card(store.State, store.State.Fleet!.Needs.Concat(store.State.Fleet.AnsweredNeeds ?? []).First(n => n.Id == need), [],
                     DateTimeOffset.UtcNow, Utc);

    /// <summary>Bugs that this catches: the answer goes at the press, or never; Undo still stands, and takes the answer
    /// back, after it went; the app's end sends an answer again that the wait sent. So: the card stands folded with his
    /// answer and Undo, with no mark, and the hub has nothing at 4.9 seconds; the answer goes once at 5 seconds, as the
    /// option's press went before (its index); then the card shows it on its way with no Undo, Undo does nothing, and
    /// the app's end sends nothing more.</summary>
    [TestMethod]
    public async Task AnAnswerWaitsFiveSecondsWithUndoAndThenGoesOnce()
    {
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        var store = await Store(clock);
        try
        {
            store.Hold(1, CardAnswer.Option(1));
            var held = Card(store, 1);
            Assert.AreEqual((true, true, false, "Offer a 20% voucher", "Undo"), (held.Folded, held.Holds, held.ShowsCheck, held.AnswerWords, held.UndoWords),
                            "folded, with his answer and Undo, and no mark");
            clock.Advance(TimeSpan.FromSeconds(4.9));
            await Task.Delay(300);
            Assert.AreEqual(0, hub.Writes.Count, "nothing reaches the hub during the 5 seconds");
            Assert.IsTrue(Card(store, 1).Holds);

            hub.Hold = new ManualResetEventSlim(false);
            clock.Advance(TimeSpan.FromSeconds(0.2));
            await Until(() => Answers(1).Length == 1, "the answer is at the hub after 5 seconds");
            Assert.AreEqual(1, Answers(1).Single().GetProperty("choice").GetInt32(), "the option that he pressed");
            var going = Card(store, 1);
            Assert.AreEqual((true, false), (going.Folded, going.Holds), "on its way, with no Undo");
            Assert.IsFalse(store.Undo(1), "Undo after the wait ended takes nothing back");
            Assert.AreEqual((true, false), (Card(store, 1).Folded, Card(store, 1).Holds), "and leaves the card folded");
            // (this hub keeps the request open after its receipt: a second send of the answer would be taken)
            hub.Hold.Set();
            await Until(() => store.State is { Pending: null, Sending: false, HeldAnswers.IsEmpty: true },
                        "its receipt came, and nothing waits any more");
        }
        finally
        {
            await store.DisposeAsync();
        }
        await Task.Delay(300);
        Assert.AreEqual(1, hub.Writes.Count, "the app's end sends nothing again");
    }

    /// <summary>Bugs that this catches: Undo leaves the card folded, or opens it with his ticks or his typed words lost, or
    /// puts the words of a quick reply in the place of his own; the request at hand in Needs you leaves at the press, or
    /// stays after its answer went; the answer still goes after Undo. So, for an option, ticks, his typed words and a
    /// quick reply: the card opens again with what he had, Needs you keeps the request at hand during the wait and moves
    /// on after it, and the hub gets only the answers that he did not take back, each in its own words.</summary>
    [TestMethod]
    public async Task UndoOpensTheCardAsItWasAndSendsNothing()
    {
        var needs = hub.Snapshot["needs"]!.AsArray();
        needs[0]!["multi"] = true;
        needs.Add(Need(3, "Is the deploy done?", "The release waits on it.", "manager", Now - 600));
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        await using var store = await Store(clock);
        RequestStep? AtHand() => Screens.Needs(store.State, null, null, clock.Now, Utc).AtHand;

        // an option, on the request at hand in Needs you
        Assert.AreEqual(3L, AtHand()?.Id);
        store.Hold(2, CardAnswer.Option(0));
        Assert.AreEqual(3L, AtHand()?.Id, "the newest request is at hand");
        var step = Screens.Needs(store.State, 2, null, clock.Now, Utc).AtHand!;
        Assert.AreEqual((2L, true, true, "Send it on Monday"), (step.Id, step.Ended, step.Holds, step.AnswerWords));
        Assert.IsTrue(store.Undo(2));
        var open = Card(store, 2);
        Assert.AreEqual((false, false), (open.Folded, open.Holds), "the card is open again, with its options");

        // ticks: they come back as he had them
        store.Hold(1, CardAnswer.Ticked([2, 0]));
        Assert.AreEqual("Refund it; Say no, politely", Card(store, 1).AnswerWords);
        Assert.IsTrue(store.Undo(1));
        var ticks = Card(store, 1);
        Assert.IsFalse(ticks.Folded);
        CollectionAssert.AreEqual(new[] { 0, 2 }, ticks.Options.Ticked.ToArray(), "his ticks again");
        Assert.AreNotEqual(0L, ticks.Answer.Given, "the box takes them once");

        // his typed words: the box emptied at Send, and Undo gives them back
        store.SetAnswerDraft(2, "Ask Marketing for the subject line first");
        store.Hold(2, CardAnswer.Typed);
        store.SetAnswerDraft(2, "");
        var words = Card(store, 2);
        Assert.AreEqual((true, true, false, "Ask Marketing for the subject line first"),
                        (words.Folded, words.Holds, words.ShowsCheck, words.AnswerWords), "his words, with no check");
        var given = words.Answer.Given;
        Assert.IsTrue(store.Undo(2));
        var back = Card(store, 2);
        Assert.AreEqual(("Ask Marketing for the subject line first", false), (back.Answer.Draft, back.Folded));
        Assert.AreNotEqual(given, back.Answer.Given, "the box loads them again");

        // a quick reply: his own words stay in the box
        store.SetAnswerDraft(3, "It looks");
        store.Hold(3, CardAnswer.Reply("Done"));
        var reply = Card(store, 3);
        Assert.AreEqual((true, "Done"), (reply.Holds, reply.AnswerWords));
        Assert.AreEqual(3L, AtHand()?.Id, "the request stays at hand for its wait");
        Assert.IsTrue(store.Undo(3));
        Assert.AreEqual(("It looks", false), (Card(store, 3).Answer.Draft, Card(store, 3).Folded));

        clock.Advance(TimeSpan.FromSeconds(10));
        await Task.Delay(400);
        Assert.AreEqual(0, hub.Writes.Count, "nothing that he took back went");

        // the answers that he did not take back go, each on its path, and the request at hand moves on
        store.Hold(3, CardAnswer.Reply("Done"));
        Assert.AreEqual(3L, AtHand()?.Id);
        hub.Hold = new ManualResetEventSlim(false);
        clock.Advance(TimeSpan.FromSeconds(5.1));
        await Until(() => Answers(3).Length == 1, "the quick reply is at the hub");
        Assert.AreEqual(2L, AtHand()?.Id, "the next request comes to hand once its wait ended");
        Assert.AreEqual("Done", Answers(3).Single().GetProperty("answer").GetString());
        Answered(3, "Done");
        hub.Hold.Set();
        await Until(() => store.State is { Pending: null, Sending: false, HeldAnswers.IsEmpty: true }, "its receipt came");
        Assert.AreEqual(2L, AtHand()?.Id, "and it stays there");
        store.Hold(1, CardAnswer.Ticked([2, 0]));
        clock.Advance(TimeSpan.FromSeconds(5.1));
        await Until(() => Answers(1).Length == 1 && store.State.HeldAnswers.IsEmpty, "the ticks went");
        CollectionAssert.AreEqual(new[] { 0, 2 }, Answers(1).Single().GetProperty("choices").EnumerateArray().Select(e => e.GetInt32()).ToArray());
    }

    /// <summary>Bug that this catches (the review of round 1, as the Mac's round 1): held ticks and typed words whose wait
    /// ends while the store cannot write for a cause that a write takes as lasting (here a reading that is no longer
    /// current) went nowhere, and their cards opened with no ticks and an empty box. So they stay folded on their way and
    /// go once the store can write, as an option's press does; the receipt takes the words out of the draft.</summary>
    [TestMethod]
    public async Task HeldTicksAndWordsWaitUntilTheStoreCanWrite()
    {
        hub.Snapshot["needs"]![0]!["multi"] = true;
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        await using var store = await Store(clock);
        store.Hold(1, CardAnswer.Ticked([2, 0]));
        store.SetAnswerDraft(2, "Send it on Tuesday instead");
        store.Hold(2, CardAnswer.Typed);
        store.SetAnswerDraft(2, "");
        clock.Advance(TimeSpan.FromSeconds(50));        // the waits end, on a reading older than 45 seconds
        await Task.Delay(400);
        Assert.IsFalse(store.State.CanWrite(clock.Now));
        Assert.AreEqual(0, hub.Writes.Count, "nothing goes on an old reading");
        Assert.AreEqual((true, false, true, false), (Card(store, 1).Folded, Card(store, 1).Holds, Card(store, 2).Folded, Card(store, 2).Holds),
                        "both stay folded, on their way, with no Undo");
        await store.RefreshAsync();
        for (var i = 0; i < 100 && !(Answers(1).Length == 1 && Answers(2).Length == 1 && store.State is { HeldAnswers.IsEmpty: true, Sending: false }); i++)
        {
            clock.Advance(TimeSpan.FromMilliseconds(300));
            await Task.Delay(30);
        }
        Assert.AreEqual((1, 1), (Answers(1).Length, Answers(2).Length), "both went once the store could write");
        CollectionAssert.AreEqual(new[] { 0, 2 }, Answers(1).Single().GetProperty("choices").EnumerateArray().Select(e => e.GetInt32()).ToArray());
        Assert.AreEqual("Send it on Tuesday instead", Answers(2).Single().GetProperty("answer").GetString());
        Assert.IsFalse(store.State.AnswerDrafts.ContainsKey(2), "the receipt took the words out of the draft");
    }

    /// <summary>Bug that this catches (the review of round 1): typed words that wait lived only in memory: the box that
    /// empties at his Send wrote an empty draft into the store and its file, so a crash, a kill or the app's end in the 5
    /// seconds lost them, and so did an answer that could not go at the app's end. So the draft and its file keep them
    /// while they wait, and after an app's end at which another write was on its way, the next start has them.</summary>
    [TestMethod]
    public async Task TypedWordsStayInTheDraftWhileTheyWait()
    {
        const string words = "Send it on Tuesday instead";
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        var store = await Store(clock);
        store.SetAnswerDraft(2, words);
        store.Hold(2, CardAnswer.Typed);
        store.SetAnswerDraft(2, "");                     // the box empties at his Send
        Assert.AreEqual(words, store.State.AnswerDrafts.GetValueOrDefault(2), "the draft keeps them");
        StringAssert.Contains(File.ReadAllText(Path.Combine(folder, "drafts.json")), words, "and its file, for a crash or a kill");
        hub.Hold = new ManualResetEventSlim(false);
        _ = store.SendMessageAsync("manager", "Is the banner ready?");
        await Until(() => hub.Writes.Count == 1, "another write waits for its receipt");
        await store.DisposeAsync();
        Assert.AreEqual(0, Answers(2).Length, "the answer could not go in this run");
        hub.Hold.Set();
        await using var next = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1"), Clock = clock });
        Assert.AreEqual(words, next.State.AnswerDrafts.GetValueOrDefault(2), "the next start has his words in the box");
    }

    /// <summary>Bugs that this catches (the review of round 1): the ticks that Undo gave back went only to the view that
    /// showed the card open before (a chat row that the list uses for another card, or the next request at hand, took
    /// none), or went again to each view that showed the card later. So the next view that shows the card ticks them,
    /// whichever it is, once (the Mac's restoredTicks(of:)); a draw with nothing new loads nothing; an Undo of his words
    /// loads the words and leaves the view's ticks.</summary>
    [TestMethod]
    public async Task TheTicksOfAnUndoGoToTheNextViewThatShowsTheCardOnce()
    {
        hub.Snapshot["needs"]![0]!["multi"] = true;
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        await using var store = await Store(clock);
        var row = new AnswerBoxLoad();
        var other = Card(store, 2);
        row.Show(2, other.Options, other.Answer);           // a row that showed another card
        store.Hold(1, CardAnswer.Ticked([2, 0]));
        Assert.IsTrue(store.Undo(1));
        var one = Card(store, 1);
        var (load, ticks) = row.Show(1, one.Options, one.Answer);
        CollectionAssert.AreEqual(new[] { 0, 2 }, ticks?.ToArray(), "the view that shows the card next ticks them");
        Assert.AreEqual("", load);
        var again = row.Show(1, one.Options, one.Answer);
        Assert.IsTrue(again.Load is null && again.Ticks is null, "another draw loads nothing");
        store.TicksShown(1, one.Answer.Given);
        var later = Card(store, 1);
        Assert.AreEqual((0, one.Answer.Given), (later.Options.Ticked.Count, later.Answer.Given), "once");
        Assert.AreEqual(0, new AnswerBoxLoad().Show(1, later.Options, later.Answer).Ticks?.Count, "a view that shows it later ticks none");

        store.SetAnswerDraft(1, "Refund half of it");
        store.Hold(1, CardAnswer.Typed);
        Assert.IsTrue(store.Undo(1));
        var words = Card(store, 1);
        var back = row.Show(1, words.Options, words.Answer);
        Assert.IsTrue(back.Load == "Refund half of it" && back.Ticks is null, "his words, and the view keeps its ticks");
    }

    /// <summary>Bug that this catches (the review of round 1): a quick reply that waits for nothing (here on a key
    /// request) puts its words into the store's draft, and the box kept its old words, so a later Send sent words that the
    /// box did not show. So the store says which words the box shows now; a held reply leaves his own words in both.</summary>
    [TestMethod]
    public async Task AQuickReplyThatIsNotHeldStandsInTheBoxAsInTheDraft()
    {
        var needs = hub.Snapshot["needs"]!.AsArray();
        needs.Add(Need(3, "Is the deploy done?", "The release waits on it.", "manager", Now - 600));
        var key = Need(4, "The API key of the example shop", "For the price import.", "manager", Now - 500);
        key["kind"] = "secret";
        needs.Add(key);
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        await using var store = await Store(clock);
        store.SetAnswerDraft(3, "It looks");
        Assert.IsNull(store.Hold(3, CardAnswer.Reply("Done")), "held: the box keeps what it shows");
        Assert.AreEqual("It looks", store.State.AnswerDrafts.GetValueOrDefault(3));
        store.SetAnswerDraft(4, "It looks");
        hub.Hold = new ManualResetEventSlim(false);
        Assert.AreEqual("Not now", store.Hold(4, CardAnswer.Reply("Not now")), "not held: the box shows the reply's words");
        Assert.AreEqual("Not now", store.State.AnswerDrafts.GetValueOrDefault(4), "the draft that a Send sends");
        hub.Hold.Set();
        await Until(() => store.State is { Pending: null, Sending: false }, "its write ended");
    }

    /// <summary>Bug that this catches: an answer that waits is lost when the app ends (the window closes, or an update's
    /// restart) before its 5 seconds end. So the app's end sends it at once: the hub has it, or the outbox keeps it for
    /// the next start.</summary>
    [TestMethod]
    public async Task TheAppsEndSendsAnAnswerThatWaits()
    {
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        var store = await Store(clock);
        store.SetAnswerDraft(2, "Send it on Tuesday instead");
        store.Hold(2, CardAnswer.Typed);
        store.SetAnswerDraft(2, "");
        await store.DisposeAsync();
        await Task.Delay(300);
        var kept = new Outbox(Path.Combine(folder, "outbox.json")).Load();
        var atHub = Answers(2).Select(w => w.GetProperty("answer").GetString()).ToArray();
        Assert.IsTrue(atHub.SequenceEqual(new[] { "Send it on Tuesday instead" }) || kept is { NeedId: 2, Text: "Send it on Tuesday instead" },
                      $"the hub has it ({atHub.Length}) or the outbox keeps it ({kept?.Text})");
    }
}
