using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>The third set of pictures (windows-app-pictures-3.md) and the Mac's rule of a request's place of 14 November
/// 2026 (7dd9104a0): each request where it was raised, his written answer as his message, and no check for written words.
/// The placement cases are FleetCore's ChatRequestPlacesTests (`inTime`), case for case.</summary>
[TestClass]
public sealed class ThirdSetTests
{
    // ---------------------------------------------------------------- the helpers of ChatRequestPlacesTests

    private static MobileChatItem Mine(string id, double at, long? answering = null, string text = "Synthetic", bool onItsWay = false) =>
        new("message", at, JsonDocument.Parse($"\"{id}\"").RootElement.Clone(), text, "test", AnswerTo: answering)
        { Key = id, OnItsWay = onItsWay };

    private static MobileChatItem Agents(long id, double at, string? replyingTo = null) =>
        new("report", at, JsonDocument.Parse(id.ToString()).RootElement.Clone(), "Synthetic", InReplyTo: replyingTo)
        { Key = id.ToString() };

    private static OwnerNeed Need(long id, double raised, double? answered = null, string[]? options = null, long? chosen = null,
                                  long[]? chose = null, bool multi = false) =>
        new(id, "Synthetic", "", "", raised, "manager", Answer: answered is null ? null : "Correos", Answered: answered,
            Options: options, Chosen: chosen, Multi: multi, Chose: chose);

    private static Dictionary<string, long[]> Places(IReadOnlyDictionary<string, IReadOnlyList<long>> places) =>
        places.ToDictionary(p => p.Key, p => p.Value.ToArray());

    private static void AreEqual(Dictionary<string, long[]> expected, IReadOnlyDictionary<string, IReadOnlyList<long>> actual)
    {
        var got = Places(actual);
        Assert.AreEqual(expected.Count, got.Count, string.Join(", ", got.Keys));
        foreach (var (key, value) in expected) CollectionAssert.AreEqual(value, got[key], key);
    }

    // ---------------------------------------------------------------- inTime, case for case

    [TestMethod]
    public void AtItsOwnTime()
    {
        var chat = new[] { Agents(1, 10), Mine("a", 20), Mine("b", 40), Agents(2, 50) };
        var places = ChatPlaces.InTime([Need(7, 30)], chat, whole: true);
        AreEqual(new() { ["message-b"] = [7] }, places.Before);
        Assert.IsTrue(places.After.Count == 0 && places.AtEnd.Count == 0 && places.Hidden.Count == 0 && places.Spoken.Count == 0);
    }

    [TestMethod]
    public void AtTheEndOnlyWhileNewest()
    {
        var chat = new List<MobileChatItem> { Agents(1, 10), Mine("a", 20) };
        CollectionAssert.AreEqual(new long[] { 7 }, ChatPlaces.InTime([Need(7, 30)], chat, whole: true).AtEnd.ToArray());
        var later = ChatPlaces.InTime([Need(7, 30)], [.. chat, Mine("b", 40)], whole: true);
        AreEqual(new() { ["message-b"] = [7] }, later.Before);
        Assert.AreEqual(0, later.AtEnd.Count);
    }

    [TestMethod]
    public void UnderTheReplyOfItsOwnTurn()
    {
        var turn = new[] { Agents(1, 10), Mine("a", 20), Agents(2, 40, replyingTo: "a"), Agents(3, 900) };
        var places = ChatPlaces.InTime([Need(7, 30), Need(8, 32)], turn, whole: true);
        AreEqual(new() { ["report-2"] = [7, 8] }, places.After);
        Assert.IsTrue(places.Before.Count == 0 && places.AtEnd.Count == 0);
        var first = new[] { Agents(1, 10), Mine("a", 20), Agents(2, 9_000), Agents(3, 9_100) };
        var own = ChatPlaces.InTime([Need(7, 30)], first, whole: true);
        AreEqual(new() { ["report-2"] = [7] }, own.Before);
        Assert.AreEqual(0, own.After.Count);
        var later = new[] { Agents(1, 10), Agents(2, 40, replyingTo: "b"), Mine("b", 35) }.OrderBy(i => i.Ts).ToList();
        var other = ChatPlaces.InTime([Need(7, 30)], later, whole: true);
        AreEqual(new() { ["message-b"] = [7] }, other.Before);
        Assert.AreEqual(0, other.After.Count);
    }

    [TestMethod]
    public void OldRequestsDoNotStandUnderTheNewestReply()
    {
        var chat = new[] { Mine("a", 10), Mine("b", 100), Mine("c", 200), Agents(9, 300) };
        var places = ChatPlaces.InTime([Need(1, 50), Need(2, 60), Need(3, 150)], chat, whole: true);
        AreEqual(new() { ["message-b"] = [1, 2], ["message-c"] = [3] }, places.Before);
        Assert.IsTrue(places.AtEnd.Count == 0 && places.After.Count == 0);
    }

    [TestMethod]
    public void AnAnswerInWordsIsHisMessage()
    {
        var chat = new[] { Mine("a", 10), Mine("b", 40), Mine("c", 60, answering: 7, text: "What is it for?"), Agents(2, 70) };
        var places = ChatPlaces.InTime([Need(7, 30, answered: 60)], chat, whole: true);
        AreEqual(new() { ["message-b"] = [7] }, places.Before);
        CollectionAssert.AreEqual(new long[] { 7 }, places.Spoken.ToArray());
        Assert.IsTrue(places.Hidden.Count == 0 && places.InPlaceOf.Count == 0);
    }

    [TestMethod]
    public void APressIsNoSecondBubble()
    {
        var chat = new[] { Mine("a", 10), Mine("c", 45, answering: 7, text: "Yes"), Mine("d", 55, answering: 8, text: "No, later"), Agents(2, 70) };
        var needs = new[]
        {
            Need(7, 20, answered: 45, options: ["Yes", "No"], chosen: 0),
            Need(8, 30, answered: 55, options: ["Yes", "No"]),
            Need(9, 44),
        };
        var places = ChatPlaces.InTime(needs, chat, whole: true);
        CollectionAssert.AreEqual(new[] { "message-c" }, places.Hidden.ToArray());
        CollectionAssert.AreEqual(new long[] { 8 }, places.Spoken.ToArray());
        AreEqual(new() { ["message-d"] = [7, 8, 9] }, places.Before);
        var ticked = Need(5, 20, answered: 45, options: ["A", "B", "C"], chose: [0, 2], multi: true);
        var both = ChatPlaces.InTime([ticked], [Mine("a", 10), Mine("c", 45, answering: 5, text: "A; C")], whole: true);
        Assert.IsTrue(both.Hidden.SetEquals(["message-c"]) && both.Spoken.Count == 0);
    }

    [TestMethod]
    public void OnItsWay()
    {
        var open = Need(7, 20, options: ["Yes", "No"]);
        var words = new[] { Mine("a", 10), Mine("c", 45, answering: 7, text: "Why?") };
        Assert.IsTrue(ChatPlaces.InTime([open], words, whole: true).Spoken.SetEquals([7L]));
        Assert.AreEqual(0, ChatPlaces.InTime([open], words, whole: true).Hidden.Count);
        var press = new[] { Mine("a", 10), Mine("c", 45, answering: 7, text: "No") };
        Assert.IsTrue(ChatPlaces.InTime([open], press, whole: true).Hidden.SetEquals(["message-c"]));
        CollectionAssert.AreEqual(new long[] { 7 }, ChatPlaces.InTime([open], press, whole: true).AtEnd.ToArray());
        // Words that he wrote and that are an option's own words: on their way they are his message at once.
        var same = new[] { Mine("a", 10), Mine("c", 45, answering: 7, text: "No", onItsWay: true) };
        var places = ChatPlaces.InTime([open], same, whole: true);
        Assert.IsTrue(places.Spoken.SetEquals([7L]) && places.Hidden.Count == 0);
        AreEqual(new() { ["message-c"] = [7] }, places.Before);
    }

    [TestMethod]
    public void OlderThanTheWindowInTime()
    {
        var window = new[] { Agents(5, 100), Mine("z", 110, answering: 7, text: "Yes") };
        var waiting = ChatPlaces.InTime([Need(6, 50)], window, whole: false);
        Assert.IsTrue(waiting.Before.Count == 0 && waiting.After.Count == 0 && waiting.AtEnd.Count == 0 && waiting.Hidden.Count == 0 && waiting.Spoken.Count == 0);
        var pressed = Need(7, 50, answered: 110, options: ["Yes", "No"], chosen: 0);
        var outside = ChatPlaces.InTime([pressed], window, whole: false);
        Assert.IsTrue(outside.Hidden.SetEquals(["message-z"]) && outside.Before.Count == 0 && outside.After.Count == 0 && outside.AtEnd.Count == 0);
        CollectionAssert.AreEqual(new[] { "report-5" }, outside.Rows(window).Select(r => r.Id).ToArray());
        var written = ChatPlaces.InTime([Need(7, 50, answered: 110)], window, whole: false);
        Assert.IsTrue(written.Hidden.Count == 0 && written.Spoken.Count == 0 && written.Before.Count == 0);
        CollectionAssert.AreEqual(new[] { "report-5", "message-z" }, written.Rows(window).Select(r => r.Id).ToArray());
        var whole = ChatPlaces.InTime([pressed], [Mine("y", 90), .. window], whole: true);
        AreEqual(new() { ["message-y"] = [7] }, whole.Before);
        Assert.IsTrue(whole.Hidden.SetEquals(["message-z"]));
    }

    [TestMethod]
    public void RowsInOrder()
    {
        var chat = new List<MobileChatItem>
        {
            Mine("a", 10), Agents(1, 20, replyingTo: "a"), Mine("b", 40), Mine("c", 45, answering: 7, text: "Yes"), Agents(2, 50),
        };
        var needs = new[] { Need(6, 15), Need(7, 30, answered: 45, options: ["Yes", "No"], chosen: 0), Need(8, 60) };
        CollectionAssert.AreEqual(new[] { "message-a", "report-1", "need-6", "need-7", "message-b", "report-2", "need-8" },
                                  ChatPlaces.InTime(needs, chat, whole: true).Rows(chat).Select(r => r.Id).ToArray());
        var later = new List<MobileChatItem>(chat) { Mine("d", 70) };
        CollectionAssert.AreEqual(new[] { "report-2", "need-8", "message-d" },
                                  ChatPlaces.InTime(needs, later, whole: true).Rows(later).Select(r => r.Id).TakeLast(3).ToArray());
    }

    [TestMethod]
    public void WordsWithNoMessage()
    {
        var places = ChatPlaces.InTime([Need(7, 30, answered: 35)], [Mine("a", 10), Mine("b", 40)], whole: true);
        Assert.IsTrue(places.Spoken.Count == 0 && places.Hidden.Count == 0);
        AreEqual(new() { ["message-b"] = [7] }, places.Before);
    }

    [TestMethod]
    public void TheTurnsReplyByAnyCase()
    {
        var chat = new[] { Mine("ab-1", 20), Agents(2, 40, replyingTo: "AB-1") };
        AreEqual(new() { ["report-2"] = [7] }, ChatPlaces.InTime([Need(7, 30)], chat, whole: true).After);
    }

    [TestMethod]
    public void TimesOfRows()
    {
        var chat = new[] { Mine("a", 100), Agents(1, 300, replyingTo: "a"), Mine("b", 90_000) };
        var needs = new[] { Need(6, 200), Need(7, 50_000) };
        var rows = ChatPlaces.InTime(needs, chat, whole: true).Rows(chat);
        CollectionAssert.AreEqual(new[] { "message-a", "report-1", "need-6", "need-7", "message-b" }, rows.Select(r => r.Id).ToArray());
        CollectionAssert.AreEqual(new double[] { 100, 300, 300, 50_000, 90_000 },
                                  ChatPlaces.Times(rows, needs.ToDictionary(n => n.Id, n => n.Raised)).ToArray());
    }

    [TestMethod]
    public void WhatAPressWrites()
    {
        var one = Need(1, 1, options: ["Yes", "No; later"]);
        Assert.IsTrue(one.Offers("Yes") && one.Offers("No; later") && !one.Offers("yes please") && !one.Offers("Yes; No; later"));
        var many = Need(1, 1, options: ["A", "B", "C"], multi: true);
        Assert.IsTrue(many.Offers("A; C") && many.Offers("B") && !many.Offers("A; D"));
        Assert.IsFalse(Need(1, 1).Offers("Done"));
    }

    [TestMethod]
    public void WhichAnswersAreWords()
    {
        Assert.IsTrue(Need(1, 1, answered: 2).AnsweredInWords);
        Assert.IsTrue(Need(1, 1, answered: 2, options: ["Yes", "No"]).AnsweredInWords);
        Assert.IsFalse(Need(1, 1, answered: 2, options: ["Yes", "No"], chosen: 1).AnsweredInWords);
        Assert.IsFalse(Need(1, 1, answered: 2, options: ["A", "B"], chose: [0], multi: true).AnsweredInWords);
        Assert.IsFalse(Need(1, 1).AnsweredInWords);
        var hub = new Uri("http://127.0.0.9:8765/");
        Assert.IsTrue(PendingRequest.New(hub, "d", "c", "Why?", needId: 1).AnswersInWords);
        Assert.IsFalse(PendingRequest.New(hub, "d", "c", "Yes", needId: 1, choice: 0).AnswersInWords);
        Assert.IsFalse(PendingRequest.New(hub, "d", "c", "A; B", needId: 1, choices: [0, 1]).AnswersInWords);
        Assert.IsFalse(PendingRequest.New(hub, "d", "c", "A message").AnswersInWords);
    }

    // ---------------------------------------------------------------- the chat and Needs you with the new rule

    [TestMethod]
    public void AWrittenAnswerIsHisBubbleAndItsCardFoldsToItsTitleWithNoCheck()
    {
        var snapshot = Snapshot();
        var answered = SampleFleet.Need(1, "Refund an order from 45 days ago?", "A customer asks.", "manager", Now - 2400, "Refund it", "Say no");
        answered["answer"] = "What does the customer say?";
        answered["answered"] = Now - 600;
        snapshot["needs"] = new JsonArray();
        snapshot["answered_needs"] = new JsonArray(answered);
        var s = State(Decode(snapshot), Clock) with
        {
            Chats = System.Collections.Immutable.ImmutableDictionary<string, ChatPageState>.Empty.Add("manager", new ChatPageState
            {
                Agent = "manager", Whole = true,
                Items = ValueList.Of([Agents(4, Now - 3000), Mine("ans-1", Now - 600, answering: 1, text: "What does the customer say?"), Agents(5, Now - 500)]),
            }),
        };
        var rows = Screens.Chat(s, "manager", Clock, Utc).Rows.Where(r => r.Kind != ChatRowKind.Stamp).ToList();
        CollectionAssert.AreEqual(new[] { "report-4", "request-1", "message-ans-1", "report-5" }, rows.Select(r => r.Key).ToArray());
        var card = rows[1].Request!;
        Assert.AreEqual((true, true, false, false), (card.Folded, card.AnsweredInWords, card.ShowsAnswerLine, card.ShowsCheck));
        Assert.AreEqual("Refund an order from 45 days ago?, answered", card.FoldedWords);
        // A pressed option: no bubble, and its card has the check and the option's words.
        answered["answer"] = "Say no";
        answered["chosen"] = 1;
        var pressed = s with { Fleet = Decode(snapshot) };
        pressed = pressed with { Chats = pressed.Chats.SetItem("manager", pressed.Chats["manager"] with { Items = ValueList.Of([Agents(4, Now - 3000), Mine("ans-1", Now - 600, answering: 1, text: "Say no"), Agents(5, Now - 500)]) }) };
        var keys = Screens.Chat(pressed, "manager", Clock, Utc).Rows.Where(r => r.Kind != ChatRowKind.Stamp).Select(r => r.Key).ToArray();
        CollectionAssert.AreEqual(new[] { "report-4", "request-1", "report-5" }, keys);
        var press = Screens.Chat(pressed, "manager", Clock, Utc).Rows.Single(r => r.Key == "request-1").Request!;
        Assert.AreEqual((false, true, true, "Say no"), (press.AnsweredInWords, press.ShowsAnswerLine, press.ShowsCheck, press.AnswerWords));
        // On Needs you, the written answer under the request at hand has no check; the pressed one has.
        Assert.IsFalse(Screens.Needs(s, 1, null, Clock, Utc).AtHand!.ShowsCheck);
        Assert.IsTrue(Screens.Needs(pressed, 1, null, Clock, Utc).AtHand!.ShowsCheck);
    }

    [TestMethod]
    public void HisWrittenAnswerOnItsWayIsHisBubbleAtOnce()
    {
        var s = State(Decode(Snapshot()), Clock);
        var answer = PendingRequest.New(s.Hub!, "gen1", "founderizer-windows/1", "Which customer is it?", needId: 1) with { CreatedAt = Clock };
        var chat = Screens.Chat(s with { Pending = answer, Sending = true }, "manager", Clock, Utc);
        Assert.IsTrue(chat.Rows.Any(r => r.Kind == ChatRowKind.Message && r.Text == "Which customer is it?"), "his words, from the moment they go");
        var press = answer with { Text = "Refund it", Choice = 0 };
        Assert.IsFalse(Screens.Chat(s with { Pending = press, Sending = true }, "manager", Clock, Utc).Rows.Any(r => r.Text == "Refund it"),
                       "a press is no bubble: its card shows it");
    }

    [TestMethod]
    public void AChatHoldsItsWholeHistoryOnlyWhenItsFirstReadGaveLessThanAPage()
    {
        var s = State(Decode(Snapshot()), Clock);
        var old = s with
        {
            Chats = System.Collections.Immutable.ImmutableDictionary<string, ChatPageState>.Empty.Add("manager", new ChatPageState
            {
                Agent = "manager", Items = ValueList.Of([Agents(4, Now - 100)]), Whole = false,
            }),
        };
        // Both open requests were raised before the one item: with a part of the history they do not stand in the chat.
        Assert.IsFalse(Screens.Chat(old, "manager", Clock, Utc).Rows.Any(r => r.Kind == ChatRowKind.Request));
        var whole = old with { Chats = old.Chats.SetItem("manager", old.Chats["manager"] with { Whole = true }) };
        CollectionAssert.AreEqual(new[] { "request-1", "request-2", "report-4" },
                                  Screens.Chat(whole, "manager", Clock, Utc).Rows.Where(r => r.Kind != ChatRowKind.Stamp).Select(r => r.Key).ToArray());
    }

    // ---------------------------------------------------------------- the result, the wait, a reply in Markdown

    private static FleetTask Task(Action<JsonObject> change)
    {
        var task = new JsonObject
        {
            ["id"] = 4, ["title"] = "Renew the shop's certificate", ["details"] = "The shop's certificate ends this week. Renew it.",
            ["done_when"] = "the new certificate serves", ["needs"] = "none", ["goal"] = null, ["owner"] = "pax", ["requester"] = "manager",
            ["state"] = "completed", ["created"] = Now - 9000, ["attempt"] = 1, ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0,
            ["last_activity"] = Now - 3600, ["delivered"] = Now - 3600,
        };
        change(task);
        return HubDecode.TaskPage(Encoding.UTF8.GetBytes(new JsonObject
        {
            ["db"] = "gen1", ["cursor"] = 1, ["task"] = task, ["notes"] = new JsonArray(), ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
        }.ToJsonString()), "gen1", 4).Task;
    }

    private static TaskPageModel Page(FleetTask task)
    {
        var s = State(Decode(Snapshot()), Clock);
        return Screens.Task(s with { TaskPages = s.TaskPages.SetItem(task.Id, new TaskPageState { Task = task }) }, task.Id, Clock, Utc)!;
    }

    [TestMethod]
    public void AnAcceptedResultHasItsFoldedCheckAndCheckedOutputsWithNoEffectYet()
    {
        var page = Page(Task(t =>
        {
            t["what"] = "Renewed the certificate"; t["where_"] = "outputs/"; t["how"] = "Checked it"; t["accepted"] = 1;
            t["checked_at"] = Now - 10_740;
        }));
        var result = page.Result!;
        Assert.AreEqual(("Renewed the certificate", "Accepted by Fleet Manager", "outputs/", "Checked it", "13 Nov 2026 at 12:13"),
                        (result.What, result.Check, result.Output, result.How, result.CheckedAt));
        Assert.IsTrue(result.CheckOpensFolded);
        Assert.AreEqual(("Checked outputs", "View outputs", 0, null), (result.Outputs!.Heading, result.Outputs.ViewWords, result.Outputs.Files.Count,
                                                                     (OpenedOutputModel?)result.Outputs.Opened));
        Assert.IsNull(page.Controls, "no controls under a task that is over");
        Assert.IsNull(page.Guidance);
        Assert.AreEqual("Accepted by Fleet Manager", page.Facts.Last(f => f.Label == "Result check").Value);
        Assert.AreEqual("Checked", page.Facts.Single(f => f.Label == "State").Value);
    }

    [TestMethod]
    public void AFailedResultWaitsForItsCheckAndHasNoCheckedOutputs()
    {
        var page = Page(Task(t => { t["state"] = "failed"; t["what"] = "The post did not go live."; }));
        Assert.AreEqual(("The post did not go live.", "Waiting for Fleet Manager's check"), (page.Result!.What, page.Result.Check));
        Assert.IsNull(page.Result.Outputs, "the result was not accepted");
        Assert.AreEqual("Failed", page.Facts.Single(f => f.Label == "State").Value);
    }

    [TestMethod]
    public void ATaskThatWaitsSaysWhatItWaitsForInTheThreadAndInItsState()
    {
        var page = Page(Task(t => { t["state"] = "input-required"; t["waiting_on"] = "N-2"; t["delivered"] = null; }));
        Assert.AreEqual(("Waiting for", "Fleet Manager", "manager"), (page.WaitingLabel, page.WaitingValue, page.WaitingAgent));
        Assert.AreEqual("Waiting for Fleet Manager", page.Controls!.StateWord);
        Assert.AreEqual("Waiting for Fleet Manager", page.Facts.Single(f => f.Label == "State").Value);
        Assert.IsNotNull(page.Guidance);
    }

    [TestMethod]
    public void TheCheckAndTheWaitAreFleetCoresWholeSentences()
    {
        var words = Vectors.Read("swift-words.json");
        var names = AgentBook.Empty;
        foreach (var c in words.GetProperty("checks").EnumerateArray())
        {
            var requester = c.GetProperty("requester").GetString()!;
            var task = Task(t =>
            {
                t["requester"] = requester;
                t["accepted"] = c.TryGetProperty("accepted", out var a) ? a.GetInt64() : null;
                t["delivered"] = c.TryGetProperty("delivered", out var d) ? d.GetDouble() : null;
            });
            Assert.AreEqual(c.GetProperty("words").GetString(), Screens.CheckStatus(task, names), c.ToString());
        }
        foreach (var w in words.GetProperty("waits").EnumerateArray())
        {
            var requester = w.GetProperty("requester").GetString()!;
            var expected = w.GetProperty("words").GetString();
            var got = w.TryGetProperty("waiting_on", out var on) ? TaskWords.Waiting(on.GetString()!, requester, names) : TaskWords.WaitingFor(requester, names);
            Assert.AreEqual(expected, got, w.ToString());
        }
    }

    [TestMethod]
    public void AReplyInMarkdownIsItsBlocksWithTheirRuns()
    {
        var blocks = MessageBlock.Parse("## Last night's backups\n\nAll three ran at **03:00**.\n\n- **Database:** 2.1 GB\n- **Settings:** `settings-2026-11-13.tar`\n\n```\nls -lh /backups/2026-11-13\n```\n\n| Backup | Time |\n|---|---|\n| Files | 03:00 |\n\nSee [the backup report](https://example.com/report).");
        CollectionAssert.AreEqual(new[] { MessageBlock.Kinds.Heading, MessageBlock.Kinds.Paragraph, MessageBlock.Kinds.Item, MessageBlock.Kinds.Item,
                                          MessageBlock.Kinds.Code, MessageBlock.Kinds.Table, MessageBlock.Kinds.Paragraph },
                                  blocks.Select(b => b.Kind).ToArray());
        CollectionAssert.AreEqual(new[] { new InlineRun("All three ran at ", false, false, false, false, null), new InlineRun("03:00", true, false, false, false, null),
                                          new InlineRun(".", false, false, false, false, null) }, blocks[1].Runs.ToArray());
        Assert.IsTrue(blocks[3].Runs.Any(r => r.Code && r.Text == "settings-2026-11-13.tar"));
        CollectionAssert.AreEqual(new[] { new InlineRun("ls -lh /backups/2026-11-13", false, false, false, true, null) }, blocks[4].Runs.ToArray());
        Assert.AreEqual(0, blocks[5].Runs.Count, "a table's words are its cells' runs");
        Assert.AreEqual("Backup", blocks[5].RowRuns[0][0].Single().Text);
        Assert.AreEqual("https://example.com/report", blocks[6].Runs.Single(r => r.Link is not null).Link);
    }
}
