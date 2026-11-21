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

/// <summary>Needs clarification on every card (owner feature `need_clarify`, owner API 1.272): his message under a card
/// goes once, as the hub's command, and the card shows the talk only where the hub gives it. Example names only.</summary>
[TestClass]
public sealed class NeedClarifyTests
{
    /// <summary>The sample fleet on a hub that takes a message under the manager's cards.</summary>
    private static JsonObject Fleet()
    {
        var snapshot = Snapshot();
        snapshot["ui_features"]!.AsArray().Add((JsonNode)NeedClarify.Feature);
        foreach (var need in snapshot["needs"]!.AsArray()) need!["clarify"] = true;
        return snapshot;
    }

    private static JsonObject Line(string who, string text) => new() { ["who"] = who, ["text"] = text, ["ts"] = Now - 60 };

    /// <summary>Bugs of the iPhone's four review rounds, as they can happen here: read as an answer's receipt, every
    /// message that the hub took waited as "Not sent", with every later write of this PC behind it; a press on the card's
    /// options waited behind his unsent message with no end, with "Sending…" at its option; a message whose receipt was
    /// lost stood in the card's talk while the request line said "Not sent"; an older line of his with the same words
    /// sent a waiting message by itself; and a refused message's words went to the manager's chat, or nowhere. So: the
    /// message goes on its own route, once; a press behind it is dropped; Try again sends the same request, whose
    /// command's receipt confirms it and puts it in the card before a read has it; a lost receipt is confirmed by the
    /// next read whose talk gained his words, and only by such a read, also when he answered the card on another device
    /// before that read (the review of 21 November 2026: it read the open cards alone); the Discard of a refused message
    /// gives its words back to the card's field, which loads them also where it stood empty.</summary>
    [TestMethod]
    public async Task AMessageUnderACardGoesOnceAsTheHubsCommandAndAPressDoesNotWaitBehindIt()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-clarify-").FullName;
        using var hub = new FakeHub { Snapshot = Fleet() };
        hub.Snapshot["needs"]![1]!["clarify"] = false;
        try
        {
            await using var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1") });
            await store.ConnectAsync(hub.Address.ToString());
            store.Unlock();
            await store.RefreshAsync();
            Assert.IsFalse(store.OpenClarify(2), "a card that takes no message has no field, and no cursor waits for one");
            string[] Sent() => hub.Writes.Where(w => w.Path == "/ui/needs/1/talk").Select(w => w.Body.GetProperty("request_id").GetString()!).ToArray();
            RequestStep Step() => Screens.Step(store.State, store.State.Fleet!.Needs.Single(n => n.Id == 1), [], Clock, Utc);
            string[] Talk() => Step().Talk.Select(l => (l.Own ? "you: " : "manager: ") + l.Text).ToArray();
            ClarifyModel Clarify() => Step().Clarify!;
            async Task Write(string words)
            {
                store.OpenClarify(1);
                store.SetClarifyDraft(1, words);
                await store.TalkAsync(1);
            }

            // a send that the hub cut before it took it: the message waits unsent on its own route, the field went back to
            // its link, and a press on the card is dropped
            const string first = "Is it the same customer as last month?";
            hub.TalkCut = "before";
            await Write(first);
            var waiting = store.State.Pending!;
            Assert.AreEqual((1L, (string?)null), (waiting.TalkNeed, waiting.Refusal));
            var body = hub.Writes.Single().Body;
            Assert.AreEqual((first, false), (body.GetProperty("text").GetString(), body.TryGetProperty("answer", out _)));
            Assert.IsFalse(store.State.ClarifyDrafts.ContainsKey(1), "the outbox has it: the link comes back");
            Assert.AreEqual("Ask about “Refund an order from 45 days ago?”", Screens.PendingBar(store.State, Clock)!.Text);
            store.Press(1, 0);
            Assert.IsFalse(store.State.WaitingPresses.ContainsKey(1), "a press behind the card's own message is dropped");

            // Try again: the same request, which the command's receipt confirms; the card shows it from that receipt
            hub.TalkCut = "";
            await store.RetryAsync();
            Assert.IsNull(store.State.Pending);
            Assert.AreEqual((2, 1), (Sent().Length, Sent().Distinct().Count()));
            CollectionAssert.AreEqual(new[] { "you: " + first }, Talk(), "before a read has it");

            // a receipt that was lost: the next read has the message in the card's talk, and that request goes once more,
            // which the hub's first result confirms
            const string second = "And the voucher, does it end this month?";
            hub.TalkInReading = true;
            hub.TalkCut = "after";
            await Write(second);
            for (var i = 0; i < 100 && (store.State.Pending is not null || store.State.Sending); i++) await Task.Delay(50);
            Assert.IsNull(store.State.Pending, "a read whose talk has it confirms it");
            Assert.AreEqual((4, 2), (Sent().Length, Sent().Distinct().Count()));
            CollectionAssert.AreEqual(new[] { "you: " + first, "you: " + second }, Talk());

            // the same words again, cut before the hub took them: his older line with those words is no sign, so no read
            // sends them by itself, and his Try again does
            hub.TalkCut = "before";
            await Write(second);
            await store.RefreshAsync();
            await Task.Delay(300);
            for (var i = 0; i < 100 && store.State.Sending; i++) await Task.Delay(50);
            Assert.AreEqual((5, 1L), (Sent().Length, store.State.Pending?.TalkNeed));
            hub.TalkCut = "";
            await store.RetryAsync();
            Assert.AreEqual(((PendingRequest?)null, 6), (store.State.Pending, Sent().Length));

            // a refused message: its Discard gives its words back to the card's field, never to the manager's chat
            const string third = "Can you ask them first?";
            hub.Refuse = (409, """{"error":"an item of a conversation is that person's question"}""");
            await Write(third);
            Assert.IsNotNull(store.State.Pending?.Refusal);
            hub.Refuse = null;
            Assert.IsTrue(store.OpenClarify(1), "he opened the field again, and it stands empty");
            var given = Clarify().Given;
            store.DiscardRefused();
            Assert.AreEqual((third, ""), (store.State.ClarifyDrafts.GetValueOrDefault(1), store.State.Drafts.GetValueOrDefault("manager", "")));
            Assert.AreNotEqual(given, Clarify().Given, "a field that stood empty loads them too (ClarifyField)");

            // a lost receipt on a card that he answered on another device before the next read: that read has his
            // message in the answered card's talk, and the request goes once more
            hub.TalkCut = "after";
            hub.HoldReads = new ManualResetEventSlim(false);
            var going = store.TalkAsync(1);
            for (var i = 0; i < 100 && store.State.SendError is null; i++) await Task.Delay(50);
            var needs = hub.Snapshot["needs"]!.AsArray();
            var answered = needs.Single(n => (long?)n!["id"] == 1)!;
            needs.Remove(answered);
            answered["answer"] = "Refund it";
            answered["answered"] = Now;
            answered["chosen"] = 0;
            hub.Snapshot["answered_needs"]!.AsArray().Add(answered);
            hub.HoldReads.Set();
            await going;
            for (var i = 0; i < 100 && (store.State.Pending is not null || store.State.Sending); i++) await Task.Delay(50);
            // (the sends so far: 7 of 4 requests, the refused one with them)
            Assert.AreEqual(((PendingRequest?)null, 9, 5), (store.State.Pending, Sent().Length, Sent().Distinct().Count()));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    /// <summary>Bugs of the review of 21 November 2026, in a view's field: the field's own empty text, when the card
    /// folded under his answer, went to the store as his words and wrote over the words that it keeps for the card, so
    /// the card that opened again after a refused answer had an empty field; a draw from a state older than his last key
    /// put back words that he had just deleted; and the cursor waited for a field after his press, so a view that showed
    /// another card later took it.</summary>
    [TestMethod]
    public void TheFieldKeepsHisWordsThroughTheFoldAndOnlyTheCardThatOpenedTakesTheCursor()
    {
        var field = new ClarifyField();
        static ClarifyModel Stands(string draft, int given = 0) => new() { Stands = true, Draft = draft, Given = given };
        const string words = "Which customer is it?";
        field.Opened(1);
        Assert.AreEqual(((string?)null, true), field.Show(1, Stands(""), ""), "it stands, and takes the cursor");
        Assert.AreEqual(1L, field.Typed(words));

        // the card folds under his answer: the view empties the field, which is no change of his
        Assert.AreEqual(("", false), field.Show(1, null, words));
        Assert.IsNull(field.Typed(""));
        // the hub refused the answer, and the card opens with the words that the store kept
        Assert.AreEqual((words, false), field.Show(1, Stands(words), ""));
        Assert.IsNull(field.Typed(words));

        // he deletes them, and a draw of an older state comes: the field stays empty
        Assert.AreEqual(1L, field.Typed(""));
        Assert.AreEqual(((string?)null, false), field.Show(1, Stands(words), ""));
        // words that the store gave (a refused message's Discard) come
        Assert.AreEqual(("Can you ask them first?", false), field.Show(1, Stands("Can you ask them first?", given: 1), ""));

        // the field of card 2 opened at his press, and the view shows card 3, then card 2: no cursor
        field.Opened(2);
        Assert.IsFalse(field.Show(3, Stands(""), "").Cursor);
        Assert.IsFalse(field.Show(2, Stands(""), "").Cursor);
    }

    /// <summary>Bug: the link stands where the hub refuses the message (a key request, a person's question, another
    /// agent's card, a hub without the feature), so his words come back refused; or the talk is lost once he answered.
    /// The link stands only on an open card that the hub says takes a message, on a hub that names the feature; the
    /// talk stands over the answers there and over his answer once the request ended, with no link.</summary>
    [TestMethod]
    public void TheLinkStandsOnlyWhereTheHubTakesAMessageAndTheTalkStaysAfterTheAnswer()
    {
        var snapshot = Fleet();
        var needs = snapshot["needs"]!.AsArray();
        needs[0]!["talk"] = new JsonArray(Line("owner", "Which customer?"), Line("manager", "The one from the spring order."));
        needs[1]!["clarify"] = false;
        var answered = Need(3, "Renew the domain?", "It ends in a week.", "manager", Now - 900, "Renew it", "Let it end");
        answered["answer"] = "Renew it";
        answered["answered"] = Now - 300;
        answered["chosen"] = 0;
        answered["clarify"] = false;
        answered["talk"] =new JsonArray(Line("owner", "For how long?"), Line("manager", "One year."));
        snapshot["answered_needs"]!.AsArray().Add(answered);
        RequestStep? AtHand(JsonObject fleet, long id) => Screens.Needs(State(Decode(fleet), Clock), id, null, Clock, Utc).AtHand;

        var open = AtHand(snapshot, 1)!;
        Assert.IsNotNull(open.Clarify);
        CollectionAssert.AreEqual(new[] { (true, "Which customer?"), (false, "The one from the spring order.") },
                                  open.Talk.Select(l => (l.Own, l.Text)).ToArray());
        Assert.IsNull(AtHand(snapshot, 2)!.Clarify, "the hub says that this card takes no message");
        var ended = AtHand(snapshot, 3)!;
        Assert.AreEqual((true, 2, (ClarifyModel?)null), (ended.Ended, ended.Talk.Count, ended.Clarify));

        snapshot["ui_features"]!.AsArray().Remove(snapshot["ui_features"]!.AsArray().First(f => (string?)f == NeedClarify.Feature));
        var before = AtHand(snapshot, 1)!;
        Assert.AreEqual((0, (ClarifyModel?)null), (before.Talk.Count, before.Clarify), "a hub without the feature");
    }
}
