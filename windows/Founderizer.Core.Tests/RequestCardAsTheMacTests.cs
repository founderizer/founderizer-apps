using System.Linq;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>A request's card and the request at hand as the Mac draws them since Founderizer 0.1.239 (app commit
/// 95811d21b): the task on the front by its kind and its door call, the reason and the task as message text, what stays
/// behind the link, and a message's hover time as how long ago. The present fields keep the approved pictures' look.</summary>
[TestClass]
public sealed class RequestCardAsTheMacTests
{
    private const string Hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    private static OwnerNeed Need(string why = "The release waits for one check.", string todo = "Run the check, then answer.",
                                  string? kind = null, long? conversation = null, string? doorCall = null,
                                  string? doorHost = null, string? doorScript = null, string? details = null) =>
        new(7, "Run the release check?", why, todo, Now - 60, "manager", Kind: kind, Conversation: conversation,
            DoorCall: doorCall, DoorHost: doorHost, DoorScript: doorScript, Details: details);

    private static StoreState Fleet() => State(Decode(Snapshot()), Clock);
    private static RequestBody OnCard(OwnerNeed need) => Screens.Card(Fleet(), need, [], Clock, Utc).Body;
    private static RequestBody AtHand(OwnerNeed need) => Screens.Step(Fleet(), need, [], Clock, Utc).Body;

    [TestMethod]
    public void TheTaskStandsInFrontByItsKindAndItsDoorCall()
    {
        Assert.IsTrue(Need().TaskInFront);
        Assert.IsTrue(Need(details: "The facts.").TaskInFront);
        Assert.IsFalse(Need(kind: "secret").TaskInFront, "the hub's sentence about its secure form");
        Assert.IsFalse(Need(kind: "question", conversation: 4).TaskInFront, "where the answer goes");
        Assert.IsFalse(Need(doorCall: Hash, doorHost: "web-1").TaskInFront, "his yes signs a hash");
        Assert.IsFalse(Need(doorCall: Hash).TaskInFront);

        foreach (var body in new[] { OnCard(Need()), AtHand(Need()) })
            Assert.AreEqual(("Run the check, then answer.", (string?)null), (body.Task, body.TodoBehind));
        foreach (var need in new[] { Need(kind: "question", conversation: 4), Need(doorCall: Hash, doorHost: "web-1") })
        foreach (var body in new[] { OnCard(need), AtHand(need) })
        {
            Assert.AreEqual(((string?)null, "Run the check, then answer."), (body.Task, body.TodoBehind));
            Assert.AreEqual("What it needs from you", body.TodoLabel);
        }
        foreach (var body in new[] { OnCard(Need(kind: "secret")), AtHand(Need(kind: "secret")) })
            Assert.AreEqual(((string?)null, (string?)null), (body.Task, body.TodoBehind), "a secret request's sentence is beside its form");
    }

    [TestMethod]
    public void ACodeBlockAndBoldInATaskAreMessageText()
    {
        const string todo = "1. Open [the settings page](https://example.com/settings) and press **Save**.\n2. Run this in a terminal:\n\n" +
                            "```\nexample-cli check --all\n```";
        var body = AtHand(Need(todo: todo));
        Assert.AreEqual(todo, body.Task);
        CollectionAssert.AreEqual(new[] { MessageBlock.Kinds.Item, MessageBlock.Kinds.Item, MessageBlock.Kinds.Code },
                                  body.TaskBlocks.Select(b => b.Kind).ToArray());
        Assert.AreEqual("example-cli check --all", body.TaskBlocks[2].Text, "the command alone, without its backticks");
        var runs = InlineMarks.Runs(body.TaskBlocks[0].Text);
        Assert.IsTrue(runs.Any(r => r is { Text: "Save", Bold: true }), "bold");
        Assert.IsTrue(runs.Any(r => r is { Text: "the settings page", Link: "https://example.com/settings" }), "a page is its link");
        // The hub tells a manager that a page in a task is its full address: the Mac links it bare, and so does the PC.
        var bare = AtHand(Need(todo: "Open https://example.com/settings and press **Save**.")).TaskBlocks.Single().Text;
        Assert.IsTrue(InlineMarks.Runs(bare).Any(r => r is { Text: "https://example.com/settings", Link: "https://example.com/settings" }));
        Assert.AreEqual(body.TaskBlocks.Count, OnCard(Need(todo: todo)).TaskBlocks.Count);

        // The present fields keep the approved pictures' look: the task as one text behind Details.
        var step = Screens.Step(Fleet(), Need(todo: todo), [], Clock, Utc);
        Assert.AreEqual((todo, "Details"), (step.Todo, step.MoreClosed));
        Assert.IsNull(step.Body.MoreClosed, "a short reason with its task in front has nothing behind a link");
    }

    [TestMethod]
    public void AReasonIsMessageText()
    {
        var body = OnCard(Need(why: "The `deploy` job failed on [the build page](https://example.com/build/12)."));
        Assert.AreEqual(MessageBlock.Kinds.Paragraph, body.WhyBlocks.Single().Kind);
        var runs = InlineMarks.Runs(body.WhyBlocks[0].Text);
        Assert.IsTrue(runs.Any(r => r is { Text: "deploy", Code: true }));
        Assert.IsTrue(runs.Any(r => r is { Text: "the build page", Link: "https://example.com/build/12" }));
        CollectionAssert.AreEqual(new[] { MessageBlock.Kinds.Paragraph, MessageBlock.Kinds.Item, MessageBlock.Kinds.Item },
                                  OnCard(Need(why: "Two checks failed:\n- lint\n- tests")).WhyBlocks.Select(b => b.Kind).ToArray());

        // A long reason folds to its start, its lines on one line, until Show all; on the card and on the step.
        var why = string.Join(' ', Enumerable.Repeat("The check of the release failed on two servers.", 6)) + "\nIt needs a second run.";
        foreach (var folded in new[] { OnCard(Need(why: why)), AtHand(Need(why: why)) })
        {
            Assert.IsFalse(folded.Short);
            Assert.AreEqual(why.Replace('\n', ' '), folded.FoldedWhy);
            Assert.AreEqual(("Show all", "Show less", false), (folded.MoreClosed, folded.MoreOpen, folded.MoreChevron));
        }
    }

    [TestMethod]
    public void WhatStaysBehindTheLinkIsTheMacs()
    {
        // The door's card: its script is one code block of the hub's details, and its task stays behind the link.
        var door = Need(doorCall: Hash, doorHost: "web-1", doorScript: "systemctl restart example\n",
                        details: "```\nsystemctl restart example\n```", todo: "Press Run it once.");
        foreach (var body in new[] { OnCard(door), AtHand(door) })
        {
            Assert.AreEqual(("Script", "Script", true, true), (body.MoreClosed, body.MoreOpen, body.MoreChevron, body.DetailsIsScript));
            Assert.AreEqual((MessageBlock.Kinds.Code, "systemctl restart example"), (body.DetailsBlocks.Single().Kind, body.DetailsBlocks[0].Text));
            Assert.AreEqual(MessageBlock.Kinds.Paragraph, body.TodoBehindBlocks.Single().Kind);
        }
        // Details of an agent's item are message text, with the chevron.
        var detailed = AtHand(Need(details: "The **second** server is example-2."));
        Assert.AreEqual(("Details", true, false), (detailed.MoreClosed, detailed.MoreChevron, detailed.DetailsIsScript));
        Assert.IsTrue(InlineMarks.Runs(detailed.DetailsBlocks.Single().Text).Any(r => r is { Text: "second", Bold: true }));
        // A conversation's item keeps its task behind the link: the card says Show all, the step Details with its chevron.
        var talk = Need(kind: "question", conversation: 4);
        Assert.AreEqual(("Show all", "Show less", false), (OnCard(talk).MoreClosed, OnCard(talk).MoreOpen, OnCard(talk).MoreChevron));
        Assert.AreEqual(("Details", "Details", true), (AtHand(talk).MoreClosed, AtHand(talk).MoreOpen, AtHand(talk).MoreChevron));
    }

    [TestMethod]
    public void TheRequestAtHandStandsInTheMiddleAsTheMacs()
    {
        var plain = AtHand(Need());
        Assert.AreEqual((true, true), (plain.CentredClosed, plain.CentredOpen), "one short paragraph and a task of one");
        var command = AtHand(Need(todo: "Run this:\n```\nexample-cli check\n```"));
        Assert.AreEqual((false, false), (command.CentredClosed, command.CentredOpen), "a command takes both to the edge");
        var list = AtHand(Need(why: "Two checks failed:\n- lint\n- tests"));
        Assert.AreEqual((false, false), (list.CentredClosed, list.CentredOpen));
        var why = string.Join(' ', Enumerable.Repeat("The check of the release failed on two servers.", 6));
        var long_ = AtHand(Need(why: why));
        Assert.AreEqual((true, false), (long_.CentredClosed, long_.CentredOpen), "the start of a long reason, closed");
        var card = OnCard(Need());
        Assert.AreEqual((false, false), (card.CentredClosed, card.CentredOpen), "a card reads from its edge");
    }

    [TestMethod]
    public void AMessagesHoverTimeIsHowLongAgo()
    {
        var reply = new MobileChatItem("report", Now - 300, JsonDocument.Parse("3").RootElement.Clone(), "Synthetic reply") { Key = "3" };
        var mine = new MobileChatItem("message", Now - 3 * 3600, JsonDocument.Parse("\"a\"").RootElement.Clone(), "Synthetic", "test")
            { Key = "a" };
        var s = Fleet();
        s = s with { Chats = s.Chats.SetItem("manager", new ChatPageState { Agent = "manager", Items = ValueList.Of(new[] { mine, reply }), Whole = true }) };
        var rows = Screens.Chat(s, "manager", Clock, Utc).Rows;
        var replied = rows.Single(r => r.Key == reply.Id);
        Assert.AreEqual(("5 min ago", true, TimeWords.DateAndTime(reply.Ts, Utc)), (replied.AgeWords, replied.AgeMoves, replied.AgeHover));
        Assert.AreEqual(Screens.MessageTime(reply.Ts, Now, Utc), replied.TimeWords, "the present field keeps the clock time");
        var sent = rows.Single(r => r.Key == mine.Id);
        Assert.AreEqual(("3 h ago", true), (sent.AgeWords, sent.AgeMoves));
        Assert.IsNotNull(sent.TimeHover);
        Assert.AreEqual(sent.TimeHover, sent.AgeHover, "his message: the date, read or not, and its edit");
        Assert.AreEqual("Just now", Screens.MessageAge(Now - 30, Clock, Utc));
    }
}
