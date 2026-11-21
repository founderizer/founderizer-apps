using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
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

    // ---------------------------------------------------------------- an answered card's mark (owner API 1.280)

    /// <summary>An answered item as the hub gives it: his press of its first option, with the fields of
    /// <paramref name="marks"/> (`team_state`, `team_reason`, `task`).</summary>
    private static JsonObject Pressed(long id, JsonObject marks)
    {
        var need = SampleFleet.Need(id, "Change the team?", "Two changes of profiles.", "manager", Now - 900, "Yes: change both", "No");
        need["answer"] = "Yes: change both";
        need["answered"] = Now - 600;
        need["chosen"] = 0;
        foreach (var (key, value) in marks) need[key] = value?.DeepClone();
        return need;
    }

    /// <summary>A store state whose reading holds these answered items, from a hub that names `need_marks` or not. Beside
    /// the sample's tasks (11 in work now, 13 waiting for the manager, 22 checked), it holds a task in state working whose
    /// session does no work now (14), a queued one (15), one that failed (24), one whose result was not accepted (25) and
    /// one whose result waits for its check (26).</summary>
    private static StoreState Answered(bool needMarks, params JsonObject[] answered)
    {
        var snapshot = Snapshot();
        if (needMarks) snapshot["ui_features"]!.AsArray().Add((JsonNode?)AnswerMark.Feature);
        snapshot["answered_needs"] = new JsonArray(answered.Select(n => (JsonNode?)n.DeepClone()).ToArray());
        snapshot["tasks"]!.AsArray().Add(Head(14, "Check the backups", "pax", "working", Now - 900, works: false));
        snapshot["tasks"]!.AsArray().Add(Head(15, "Renew the certificates", "pax", "submitted", Now - 100));
        snapshot["recent"]!.AsArray().Add(Head(24, "Reopen the stuck nodes", "pax", "failed", Now - 400));
        snapshot["recent"]!.AsArray().Add(Head(25, "Resize the database", "pax", "completed", Now - 500, accepted: 0));
        snapshot["recent"]!.AsArray().Add(Head(26, "Clean the old logs", "pax", "completed", Now - 450));
        return State(Decode(snapshot), Clock);
    }

    /// <summary>The marks of these answered items, as their cards in the manager's chat draw them.</summary>
    private static AnswerMark[] MarksOf(bool needMarks, params JsonObject[] answered)
    {
        var s = Answered(needMarks, answered);
        return s.Fleet!.AnsweredNeeds!.Select(n => Screens.Card(s, n, [], Clock, Utc).AnswerMark).ToArray();
    }

    private static JsonObject Marks(string? teamState = null, string? teamReason = null, long? task = null) =>
        new() { ["team_state"] = teamState, ["team_reason"] = teamReason, ["task"] = task };

    private static AnswerMark Done(string words) => new(AnswerSymbol.Check, words);

    /// <summary>The Mac's AnsweredMark of a team card and of Give (NeedMarksTests.aTeamCardSaysWhereItsPlanStandsAndGiveIsGiven):
    /// a team card says where its plan stands after his yes, from the item's own `team_state`, in the Mac's words ("The
    /// hub makes the change", "Changed") or the hub's own for a plan that it did not make; Give that he pressed is
    /// "Given", and No on the same card says that the agent that raised it has his answer, as a hub without `need_marks`
    /// does. Breaks if the PC writes its own words, reads Give as a plain decision, or draws the marks from a hub that does
    /// not name the feature.</summary>
    [TestMethod]
    public void AnAnsweredTeamCardSaysWhereItsPlanStandsAndGiveIsGiven()
    {
        const string reason = "The hub did not make this change: the fleet changed after your yes. Nothing changed, and Fleet Manager knows.";
        var give = new JsonObject { ["agent"] = "theo", ["level"] = "write", ["repos"] = new JsonArray("acme/web") };
        var refused = Pressed(35, new JsonObject { ["give"] = give.DeepClone() });
        refused["chosen"] = 1;
        refused["answer"] = "No";
        var cards = new[]
        {
            Pressed(31, Marks("making")), Pressed(32, Marks("not_made", reason)), Pressed(33, Marks("made")),
            Pressed(34, new JsonObject { ["give"] = give.DeepClone() }), refused,
        };
        CollectionAssert.AreEqual(new[]
        {
            new AnswerMark(AnswerSymbol.Working, "The hub makes the change"),
            new AnswerMark(AnswerSymbol.Failed, reason),
            Done("Changed"),
            Done("Given"),
            Done("Fleet Manager has your answer"),
        }, MarksOf(true, cards));
        Assert.AreEqual("The hub makes the change", MarksOf(true, cards)[0].Hover, "the plan's work has its words on hover");
        CollectionAssert.AreEqual(Enumerable.Repeat(Done("Fleet Manager has your answer"), 5).ToArray(), MarksOf(false, cards),
                                  "a hub before need_marks: the check, also for a value that it could not have sent");
    }

    /// <summary>The Mac's AnsweredMark of a card whose answer lets a task go on (NeedMarksTests
    /// .aCardWithATaskTurnsOnlyWhileItWorksAndIsRedOnlyWhenItFailed): the turning mark only while the task is in work now,
    /// with "Role · title" for an assistive app and no hover yet (the badge's hover waits for the Mac); the red mark for a
    /// result that is no success, with its word; the check with "Done" for a checked result; and else, with no fourth
    /// look, the check with the task's state word ("Working" at rest, "Queued", "Waiting for Fleet Manager", a result that
    /// waits for its check). A task that the reading does not hold: the agent that raised it has his answer. The work
    /// mark turns only on a current reading. Breaks if the work mark follows the state alone, if a waiting task loses its
    /// state word or a checked one its "Done", or if a task's work shows words on hover.</summary>
    [TestMethod]
    public void AnAnsweredCardTurnsOnlyWhileItsTaskWorksAndIsRedOnlyWhenItFailed()
    {
        var ids = new long[] { 11, 14, 15, 13, 24, 25, 22, 26, 999 };
        var marks = MarksOf(true, ids.Select((task, i) => Pressed(41 + i, Marks(task: task))).ToArray());
        var work = new AnswerMark(AnswerSymbol.Working, "Customer Support · Answer today's support tickets", "wren",
                                  "Answer today's support tickets");
        CollectionAssert.AreEqual(new[]
        {
            work, Done("Working"), Done("Queued"), Done("Waiting for Fleet Manager"),
            new AnswerMark(AnswerSymbol.Failed, "Failed"), new AnswerMark(AnswerSymbol.Failed, "Not accepted"),
            Done("Done"), Done("Awaiting check"), Done("Fleet Manager has your answer"),
        }, marks, "work, at rest, queued, waiting, failed, not accepted, checked, awaiting its check, not in the reading");
        Assert.IsNull(marks[0].Hover, "no hover for a task's work until the Mac draws its badge there");
        Assert.AreEqual("Failed", marks[4].Hover);
        var s = Answered(true, Pressed(41, Marks(task: 11)));
        var need = s.Fleet!.AnsweredNeeds![0];
        Assert.IsTrue(Screens.Card(s, need, [], Clock, Utc).MarkMoves, "a current reading turns the work mark");
        var old = s with { LastRead = Clock.AddMinutes(-5) };
        Assert.IsFalse(Screens.Card(old, need, [], Clock, Utc).MarkMoves, "a last reading: the work mark rests");
    }

    /// <summary>No mark of his answer stands, only the plain check with no words, where the Mac draws no AnsweredMarkView
    /// and its folded card's value is empty: a card that he answered in his own words, a key request that a saved key
    /// answered (the key card), and a card whose answer is on its way while the reading still has it open. Breaks if one
    /// of them says that the agent has his answer, or takes the mark of its task.</summary>
    [TestMethod]
    public void NoMarkStandsForWordsAKeyOrAnAnswerOnItsWay()
    {
        var words = Pressed(51, Marks(task: 11));
        words["chosen"] = null;
        words["answer"] = "Only the first one, please.";
        var key = Pressed(52, Marks());
        key["kind"] = "secret";
        key["chosen"] = null;
        key["answer"] = "Saved.";
        key["secret"] = new JsonObject { ["kind"] = "api_key", ["env"] = "SHOP_KEY", ["saved"] = "bws://0f8fad5b-d9cb-469f-a165-70867728950e" };
        CollectionAssert.AreEqual(new[] { AnswerMark.Plain, AnswerMark.Plain }, MarksOf(true, words, key));

        var open = Pressed(53, Marks(task: 11));
        open["answer"] = null;
        open["answered"] = null;
        open["chosen"] = null;
        var snapshot = Snapshot();
        snapshot["ui_features"]!.AsArray().Add((JsonNode?)AnswerMark.Feature);
        snapshot["needs"]!.AsArray().Add(open);
        var s = State(Decode(snapshot), Clock);
        var press = PendingRequest.New(s.Hub!, "gen1", "founderizer-windows/1", "Yes: change both", needId: 53) with { Choice = 0, CreatedAt = Clock };
        var card = Screens.Card(s with { Pending = press, Sending = true }, s.Fleet!.Needs.Single(n => n.Id == 53), [], Clock, Utc);
        Assert.AreEqual((true, AnswerMark.Plain), (card.Folded, card.AnswerMark), "on its way: the plain check, with no words");
    }

    /// <summary>The owner's "Yes, same marks there" (21 November 2026): an answered request at hand in Needs you draws in
    /// its check's place the mark of its card in the chat, with the same words. Breaks if the request at hand keeps the
    /// plain check, or reads its mark another way than the card.</summary>
    [TestMethod]
    public void TheAnsweredRequestAtHandWearsTheMarkOfItsCard()
    {
        var s = Answered(true, Pressed(61, Marks(task: 11)), Pressed(62, Marks("not_made", "The hub did not make this change.")));
        foreach (var need in s.Fleet!.AnsweredNeeds!)
        {
            var step = Screens.Needs(s, need.Id, null, Clock, Utc).AtHand!;
            Assert.AreEqual(Screens.Card(s, need, [], Clock, Utc).AnswerMark, step.AnswerMark);
            Assert.AreNotEqual(AnswerMark.Plain, step.AnswerMark);
            Assert.IsTrue(step.MarkMoves);
        }
    }
}
