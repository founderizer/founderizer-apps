using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>**Words that look like a key wait for his choice before they go** (UI-API 1.249: the Mac's and a PC's apps
/// hold text that looks like a key before it goes; the Mac's KeyHoldBanner): in a chat's composer, a request's answer box
/// and the field of Needs clarification, such words do not reach the hub until he chooses "Keep it", and the drafts' file
/// never keeps them. The rule is FleetCore's KeyInText, held equal to the Swift by app/vectors/key-in-text.json.
///
/// Every key here is made up, and put together from two parts: no file holds a key's whole shape as one literal, which
/// GitHub's push protection reads as a real key in the public copy of the apps.</summary>
[TestClass]
public sealed class KeyHoldTests
{
    /// <summary>A made-up key with the shape of an OpenAI key.</summary>
    private const string Key = "sk-proj-" + "EXAMPLEexampleEXAMPLE0123456789ab";

    private string folder = "";
    private FakeHub hub = null!;

    [TestInitialize]
    public void Make()
    {
        folder = Directory.CreateTempSubdirectory("founderizer-keyhold-").FullName;
        hub = new FakeHub();
        hub.Snapshot["ui_features"]!.AsArray().Add((JsonNode)NeedClarify.Feature);
        foreach (var need in hub.Snapshot["needs"]!.AsArray()) need!["clarify"] = true;
    }

    [TestCleanup]
    public async Task Remove()
    {
        hub.Dispose();
        // A store can still end a write in its folder while the folder goes: try again for a second (AnswerHoldTests).
        for (var i = 0; i < 10; i++)
        {
            try { Directory.Delete(folder, recursive: true); break; }
            catch (IOException) { await Task.Delay(100); }
        }
    }

    private async Task<OwnerStore> Store(ManualClock? clock = null)
    {
        var store = new OwnerStore(new StoreSettings
        {
            Folder = folder, Keys = new MemoryKeyStore("device-key-1"), ClientLabel = "founderizer-windows/1",
            Clock = clock ?? (IStoreClock)SystemClock.Shared,
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

    private string[] Texts(string path) =>
        hub.Writes.Where(w => w.Path == path).Select(w => w.Body.TryGetProperty("text", out var t) ? t.GetString()!
                                                        : w.Body.GetProperty("answer").GetString()!).ToArray();

    private string DraftsFile() => File.ReadAllText(Path.Combine(folder, "drafts.json"));

    private static RequestCard Card(OwnerStore store, long need) =>
        Screens.Card(store.State, store.State.Fleet!.Needs.First(n => n.Id == need), [], DateTimeOffset.UtcNow, Utc);

    /// <summary>Bug that this catches: the C# rule differs from FleetCore's on one of its cases (a shape's pattern, a
    /// limit of the random run, the value after `=`, the path of a web address, a place counted in other units than
    /// UTF-16, a word boundary or a space that ICU and Apple read otherwise than .NET), so a key that the Mac and the
    /// iPhone hold back goes from a PC, or words that they let go wait here. So each text of the Swift's vectors gives
    /// the place that the Swift found, and each run the Swift's answer; and the 15 shapes and the run are FleetCore's
    /// literals, word for word, so that an alternative that no vector names (a service's prefix, a length) cannot differ
    /// either (the review of round 2).</summary>
    [TestMethod]
    public void TheRuleFindsWhatFleetCoresRuleFinds()
    {
        var swift = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "sources", "KeyInText.swift"));
        var literals = Regex.Matches(swift, "#\"(.*?)\"#").Select(m => m.Groups[1].Value).ToArray();
        Assert.AreEqual(16, literals.Length, "FleetCore's 15 shapes and its run");
        CollectionAssert.AreEqual(literals, KeyInText.Patterns.ToArray(), "the patterns of KeyInText.swift, as written");
        var vectors = Vectors.Read("key-in-text.json");
        var (found, none) = (0, 0);
        foreach (var vector in vectors.GetProperty("texts").EnumerateArray())
        {
            var text = string.Concat(vector.GetProperty("text").EnumerateArray().Select(p => p.GetString()));
            var place = vector.GetProperty("found");
            (int, int)? expected = place.ValueKind == System.Text.Json.JsonValueKind.Null ? null
                : (place[0].GetInt32(), place[1].GetInt32());
            Assert.AreEqual(expected, KeyInText.First(text), vector.GetProperty("what").GetString());
            if (expected is null) none++; else found++;
        }
        Assert.IsTrue(found >= 25 && none >= 15, "the file has both kinds");
        var (random, plain) = (0, 0);
        foreach (var run in vectors.GetProperty("runs").EnumerateArray())
        {
            var words = run.GetProperty("run").GetString()!;
            var expected = run.GetProperty("random").GetBoolean();
            Assert.AreEqual(expected, KeyInText.LooksRandom(words), words);
            if (expected) random++; else plain++;
        }
        Assert.IsTrue(random >= 100 && plain >= 10, "the runs have both answers");
    }

    /// <summary>Bug that this catches (the review of round 4): the look for a web address's marks made a list and a
    /// string for each character of the word before each run of 32. On a pasted JSON line of 16,000 characters with no
    /// space, one look took 300 ms and 85 MiB, and each key that he types makes at least three looks on the window's
    /// thread, so typing stopped for about a second at each key. So one look at such a line allocates little: a measure
    /// that a busy Mac does not change, as it changes a time.</summary>
    [TestMethod]
    public void ALookAtALongLineWithNoSpaceAllocatesLittle()
    {
        var random = new Random(7);
        string Hex(int count) => string.Concat(Enumerable.Range(0, count).Select(_ => "0123456789abcdef"[random.Next(16)]));
        var json = new StringBuilder("{\"items\":[");
        while (json.Length < 15_800)
            json.Append("{\"id\":\"").Append(Hex(40)).Append("\",\"sha256\":\"").Append(Hex(64)).Append("\",\"ok\":true},");
        var text = json.ToString();
        Assert.IsFalse(KeyInText.Contains(text), "hashes in hex are no key");     // and the patterns are made once
        var before = GC.GetAllocatedBytesForCurrentThread();
        KeyInText.Contains(text);
        var bytes = GC.GetAllocatedBytesForCurrentThread() - before;
        Assert.IsTrue(bytes < 8 * 1024 * 1024, $"one look allocated {bytes / 1048576.0:F1} MiB");
    }

    /// <summary>Bug that this catches: the hold holds words that are no key (a hold that asks of every message, or a rule
    /// that reads a sentence about a key, an order's number, a hash or a document's address as one), so his everyday
    /// messages stop and wait for "Keep it", and their drafts leave the file. So such messages show no hold, go at once,
    /// and their draft is in the file.</summary>
    [TestMethod]
    public async Task ANormalMessageGoesAndItsDraftIsKept()
    {
        await using var store = await Store();
        string[] messages =
        [
            "Please save the OpenAI key for the studio agent today.",
            "Refund order 10452 and tell the customer it goes out on Tuesday.",
            "The fix is commit 3f786850e387550fdab836ed7e6dc881de23001b, see https://docs.google.com/document/d/1aBcD3fGhIjKlMnOpQrStUvWxYz0123456789/edit",
        ];
        foreach (var words in messages)
        {
            store.SetDraft("wren", words);
            Assert.IsNull(Screens.Chat(store.State, "wren", Clock, Utc).Composer.KeyHold, words);
            StringAssert.Contains(DraftsFile(), words.Split(' ')[1], "its draft is kept");
            Assert.IsNull(await store.SendMessageAsync("wren"), words);
        }
        CollectionAssert.AreEqual(messages, Texts("/ui/messages"), "each went as he wrote it");
    }

    /// <summary>Bugs that this catches: a key in a chat's message reaches the hub, and with it the agent's conversation, its
    /// runtime's transcript and the hub's records, before anything can mask it; or "Keep it" once lets every later key of
    /// that chat go with no question. So the composer shows the hold and no Send, the store sends nothing, "Keep it" lets
    /// those words go, and the next key in that box waits again.</summary>
    [TestMethod]
    public async Task AKeyInAMessageDoesNotGoUntilHeKeepsIt()
    {
        await using var store = await Store();
        store.SetDraft("wren", "the key is " + Key);
        var composer = Screens.Chat(store.State, "wren", Clock, Utc).Composer;
        Assert.AreEqual(("This message holds what looks like a key.", "In a message, Customer Support and its transcripts would have it.",
                         "Keep it", false),
                        (composer.KeyHold?.Words, composer.KeyHold?.Line, composer.KeyHold?.KeepWords, composer.CanSend));
        Assert.IsNull(await store.SendMessageAsync("wren"));
        Assert.IsNull(await store.SendMessageAsync("manager", "and " + Key));
        Assert.AreEqual(0, hub.Writes.Count, "nothing reached the hub");
        Assert.AreEqual("the key is " + Key, store.State.Drafts["wren"], "the words stay in the box");

        store.KeepKey(KeyHold.Chat("wren"));
        composer = Screens.Chat(store.State, "wren", Clock, Utc).Composer;
        Assert.AreEqual((null, true), (composer.KeyHold, composer.CanSend), "his choice: Send stands again");
        Assert.IsNull(await store.SendMessageAsync("wren"));
        CollectionAssert.AreEqual(new[] { "the key is " + Key }, Texts("/ui/messages"), "it went as he chose");

        store.SetDraft("wren", "one more: " + Key);
        Assert.IsNotNull(Screens.Chat(store.State, "wren", Clock, Utc).Composer.KeyHold, "a new key in the box asks again");
        Assert.IsNull(await store.SendMessageAsync("wren"));
        Assert.AreEqual(1, Texts("/ui/messages").Length);
    }

    /// <summary>Bugs that this catches: his typed answer with a key reaches the hub, or folds the card for 5 seconds with
    /// Undo as if it were going. So the card's box shows the hold and no Send, his Send holds nothing and the hub gets
    /// nothing after the 5 seconds, and "Keep it" lets it go as every answer goes.</summary>
    [TestMethod]
    public async Task AKeyInATypedAnswerDoesNotGo()
    {
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        await using var store = await Store(clock);
        store.SetAnswerDraft(2, "use this key: " + Key);
        var box = Card(store, 2).Answer;
        Assert.IsNotNull(box.KeyHold);
        Assert.AreEqual("In a message, Fleet Manager and its transcripts would have it.", box.KeyHold.Line);
        Assert.IsFalse(AnswerBoxModel.CanSend(store.State, clock.Now, box.Draft, 0, held: box.KeyHold is not null));
        store.Hold(2, CardAnswer.Typed);
        Assert.IsTrue(store.State.HeldAnswers.IsEmpty, "the card does not fold");
        Assert.IsNull(await store.AnswerAsync(2));
        clock.Advance(TimeSpan.FromSeconds(6));
        await Task.Delay(300);
        Assert.AreEqual(0, hub.Writes.Count, "nothing reached the hub");

        store.KeepKey(KeyHold.Answer(2));
        Assert.IsNull(Card(store, 2).Answer.KeyHold);
        store.Hold(2, CardAnswer.Typed);
        Assert.IsFalse(store.State.HeldAnswers.IsEmpty, "his choice waits 5 seconds with Undo, as every answer");
        clock.Advance(TimeSpan.FromSeconds(6));
        await Until(() => Texts("/ui/needs/2").Length == 1, "and then goes");
        Assert.AreEqual("use this key: " + Key, Texts("/ui/needs/2").Single());
    }

    /// <summary>Bug that this catches: his message under a card (Needs clarification) with a key reaches the hub: the
    /// field's words are in memory only, and still they go to the agent. So the field shows the hold and no Send, and
    /// the hub gets nothing until "Keep it".</summary>
    [TestMethod]
    public async Task AKeyInAMessageUnderACardDoesNotGo()
    {
        await using var store = await Store();
        Assert.IsTrue(store.OpenClarify(1));
        store.SetClarifyDraft(1, "is it " + Key + "?");
        var field = Card(store, 1).Clarify!;
        Assert.AreEqual((true, false), (field.KeyHold is not null, field.CanSend));
        Assert.IsNull(await store.TalkAsync(1));
        Assert.AreEqual(0, hub.Writes.Count, "nothing reached the hub");
        Assert.IsTrue(store.State.ClarifyDrafts.ContainsKey(1), "the words stay in the field");

        store.KeepKey(KeyHold.Talk(1));
        Assert.IsTrue(Card(store, 1).Clarify!.CanSend);
        await store.TalkAsync(1);
        CollectionAssert.AreEqual(new[] { "is it " + Key + "?" }, Texts("/ui/needs/1/talk"));
    }

    /// <summary>Bug that this catches (the review of round 2): the hold was asked again at each turn of a write that
    /// waited behind another write, with that turn's state. The field empties as his Send goes, the empty draft ends his
    /// "Keep it", and the write that waited then found a key that he had not kept: it went nowhere, and his words were
    /// gone from the field and the draft. The same for the answer of a key request, which goes with no 5-second wait. So
    /// his press decides, and a kept message and a kept answer reach the hub behind a write that the hub holds.</summary>
    [TestMethod]
    public async Task AKeptKeyGoesAlsoBehindAWriteThatWaits()
    {
        var keyRequest = Need(4, "The API key of the example shop", "For the price import.", "manager", Now - 500);
        keyRequest["kind"] = "secret";
        hub.Snapshot["needs"]!.AsArray().Add(keyRequest);
        await using var store = await Store();
        hub.Hold = new ManualResetEventSlim(false);
        var first = store.SendMessageAsync("manager", "Is the banner ready?");
        await Until(() => hub.Writes.Count == 1, "the first write is at the hub, which holds it");

        store.SetDraft("wren", "the key is " + Key);
        store.KeepKey(KeyHold.Chat("wren"));
        var message = store.SendMessageAsync("wren");
        store.SetDraft("wren", "");                         // the field empties at his Send
        store.SetAnswerDraft(4, "use " + Key);
        store.KeepKey(KeyHold.Answer(4));
        store.Hold(4, CardAnswer.Typed);                    // a key request's answer goes with no wait
        store.SetAnswerDraft(4, "");                        // and its box empties at his Send
        await Task.Delay(600);
        hub.Hold.Set();
        await first;
        await message;
        await Until(() => Texts("/ui/needs/4").Length == 1, "the key request's answer reached the hub");
        CollectionAssert.AreEqual(new[] { "Is the banner ready?", "the key is " + Key }, Texts("/ui/messages"));
        Assert.AreEqual("use " + Key, Texts("/ui/needs/4").Single());
    }

    /// <summary>Bug that this catches (the review of round 3): Undo put his typed words back into the box without the mark
    /// that keeps a box that held a key out of the drafts' file. A refusal of registered login text (422) empties the
    /// drafts, and so the mark, while a kept answer waits its 5 seconds; Undo then gave back words with a key and no mark,
    /// and one Backspace in the key put 31 of its 32 characters into the file. So the words that Undo gives back are
    /// marked as typed words are.</summary>
    [TestMethod]
    public async Task WordsThatUndoGivesBackStayOutOfTheDraftsFile()
    {
        const string run = "Xk7Qp2Lm9Rt4Vb8Nc3Wz6Hd1Jf5Gs0Ya";
        var clock = new ManualClock(DateTimeOffset.UtcNow);
        await using var store = await Store(clock);
        store.SetAnswerDraft(2, "token " + run);
        store.KeepKey(KeyHold.Answer(2));
        store.Hold(2, CardAnswer.Typed);
        Assert.IsFalse(store.State.HeldAnswers.IsEmpty, "his kept answer waits 5 seconds");
        hub.Refuse = (422, """{"error":"text matches a registered login"}""");
        await store.SendMessageAsync("manager", "the password is hunter2");
        Assert.IsTrue(store.State.AnswerDrafts.IsEmpty, "the refusal took the drafts off this PC");
        Assert.IsTrue(store.Undo(2));
        Assert.AreEqual("token " + run, store.State.AnswerDrafts[2], "Undo gave his words back");
        store.SetAnswerDraft(2, "token " + run[..31]);          // one Backspace
        Assert.IsFalse(DraftsFile().Contains(run[..31], StringComparison.Ordinal), "the rest of the key stays out");
    }

    /// <summary>Bugs that this catches: a key that he typed or pasted stays on this PC's disk in the drafts' file, where it
    /// outlives the box, the app and his choice; a write of the file after "Keep it" puts the kept key in; and one
    /// Backspace in a pasted key puts the rest of it in, because those words no longer match (the review of round 2). So
    /// neither a chat's draft nor an answer's draft with a key is in the file, also at a write after "Keep it", a box that
    /// held a key stays out until it is empty, the drafts without one are in, and the next start has those only.</summary>
    [TestMethod]
    public async Task AKeyIsNeverKeptInTheDraftsFile()
    {
        await using (var store = await Store())
        {
            store.SetDraft("manager", "Start the spring sale.");
            store.SetDraft("wren", "the key is " + Key);
            store.SetAnswerDraft(1, "and " + Key);
            store.SetAnswerDraft(2, "Show me the email first.");
            store.KeepKey(KeyHold.Chat("wren"));
            store.KeepKey(KeyHold.Answer(1));
            store.SetDraft("theo", "Fix the checkout first.");         // a write of the file after "Keep it"
            var file = DraftsFile();
            StringAssert.Contains(file, "Fix the checkout first.");
            Assert.IsFalse(file.Contains(Key[8..], StringComparison.Ordinal), "no key in the file");
            StringAssert.Contains(file, "Start the spring sale.");
            StringAssert.Contains(file, "Show me the email first.");
            Assert.AreEqual("the key is " + Key, store.State.Drafts["wren"], "the box keeps it while the app runs");

            // a pasted run of 32 that reads as random, then one Backspace: 31 of them match no more, and stay out
            const string run = "Xk7Qp2Lm9Rt4Vb8Nc3Wz6Hd1Jf5Gs0Ya";
            store.SetDraft("pax", "token " + run);
            store.SetDraft("pax", "token " + run[..31]);
            Assert.IsFalse(KeyInText.Contains("token " + run[..31]));
            Assert.IsFalse(DraftsFile().Contains(run[..31], StringComparison.Ordinal), "the rest of the key stays out");
            store.SetDraft("pax", "");
            store.SetDraft("pax", "The backup ran.");
            StringAssert.Contains(DraftsFile(), "The backup ran.", "an emptied box is kept again");
        }
        await using var next = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore("device-key-1") });
        Assert.AreEqual(("Start the spring sale.", false, false),
                        (next.State.Drafts["manager"], next.State.Drafts.ContainsKey("wren"), next.State.AnswerDrafts.ContainsKey(1)));
    }
}
