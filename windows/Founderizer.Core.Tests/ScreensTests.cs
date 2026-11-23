using System;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The screen models of the seven pictures, on a fleet like their sample: the words and the rules that each
/// element takes from the Mac's views and the iPhone's pages.</summary>
[TestClass]
public sealed class ScreensTests
{
    private static readonly DateTimeOffset Now = SampleFleet.Clock;
    private static readonly ScreenContext Utc = SampleFleet.Utc;

    private static StoreState Sample(Action<JsonObject>? change = null)
    {
        var snapshot = SampleFleet.Snapshot();
        change?.Invoke(snapshot);
        return SampleFleet.State(SampleFleet.Decode(snapshot), Now);
    }

    private static StoreState WithChat(StoreState s, string agent, params JsonObject[] items)
    {
        var page = HubDecode.ChatPage(Encoding.UTF8.GetBytes(SampleFleet.ChatPage("gen1", agent, items).ToJsonString()), "gen1", agent);
        // A first read of fewer items than a page: the chat's whole history.
        return s with { Chats = s.Chats.SetItem(agent, new ChatPageState { Agent = agent, Items = ValueList.Of(page.Items), Whole = page.Items.Count < StoreState.ChatFirstPage }) };
    }

    [TestMethod]
    public void AStateWithANewReadingHasItsRolesAndMarksNotTheOnesBefore()
    {
        // A record's `with` copies private fields: the caches of Names and Marks must not carry the reading before
        // (found by the screens session while it wired slice 1.2).
        var before = Sample();
        Assert.AreEqual("Fleet Manager", before.Names.Label("manager"));
        Assert.AreEqual(5, before.Marks.Count);
        var snapshot = SampleFleet.Snapshot();
        snapshot["agents"]![0]!["title"] = "Chief of Staff";
        snapshot["agents"]!.AsArray().Add(SampleFleet.Agent("ivy", "worker", "Research"));
        var after = before with { Fleet = SampleFleet.Decode(snapshot) };
        // A role that holds no word of the name stands beside the name: "Manager · Chief of Staff".
        Assert.AreEqual(("Manager", "Chief of Staff"), (after.Names.Label("manager"), after.Names.Role("manager")));
        Assert.AreEqual("Research", after.Names.Role("ivy"));
        Assert.AreEqual(GlyphLook.Team(["manager", "wren", "theo", "pax", "orla", "ivy"])["ivy"], after.Marks["ivy"]);
        var ivy = Screens.Pane(after, Page.Tasks, Now, Utc).Agents.Last();
        Assert.AreEqual(("Ivy", "Research"), (ivy.Label, ivy.Role));
        Assert.AreEqual("Fleet Manager", before.Names.Label("manager"), "the state before keeps its own reading");
        var same = after with { Drafts = after.Drafts.SetItem("ivy", "hello") };
        Assert.AreSame(after.Names, same.Names, "a change that keeps the reading keeps its cache");
        Assert.AreSame(after.Marks, same.Marks);
    }

    [TestMethod]
    public void ThePaneHasNeedsYouWhileSomethingWaitsAndEachAgentsRow()
    {
        var pane = Screens.Pane(Sample(), Page.Chat("manager"), Now, Utc);
        Assert.IsTrue(pane.ShowsNeeds);
        Assert.AreEqual(2, pane.NeedsCount);
        Assert.AreEqual("2 items need you", pane.NeedsHover);
        CollectionAssert.AreEqual(new[] { "Fleet Manager", "Wren", "Theo", "Pax", "Orla" },
                                  pane.Agents.Select(a => a.Label).ToArray());
        // Each row's name before its role, as the Mac's AgentNameLine (set 8, picture 21: "Juno · Fleet Manager"); none
        // where the role is the label ("Fleet Manager" of "manager"). The bug: a pane that names an agent by its role
        // alone (the owner's answers of 22 November 2026 to F16), or that loses the role beside the name.
        CollectionAssert.AreEqual(new[] { null, "Customer Support", "Developer", "DevOps", "Marketing" },
                                  pane.Agents.Select(a => a.Role).ToArray());
        // The row draws the name, then the role muted, and an assistive app reads them in that order.
        Assert.AreEqual(("Wren", " · Customer Support", "Wren, Customer Support"),
                        (pane.Agents[1].Lead, pane.Agents[1].Trail, pane.Agents[1].Spoken));
        Assert.AreEqual(("Fleet Manager", "", "Fleet Manager"), (pane.Agents[0].Lead, pane.Agents[0].Trail, pane.Agents[0].Spoken));
        var manager = pane.Agents[0];
        Assert.AreEqual("Yes. Marketing has the email ready.", manager.Line);
        Assert.AreEqual("15:04", manager.Time);
        Assert.IsTrue(manager.Selected);
        Assert.AreEqual(GlyphKind.Sparkle, manager.Mark.Kind);
        // Wren works on a task: its line says what its running turn does, and moves.
        var wren = pane.Agents[1];
        Assert.AreEqual("Reading its messages", wren.Line);
        Assert.IsTrue(wren.LineMoves && wren.Mark.Moves);
        Assert.IsFalse(wren.ShowsDot, "work shows as motion, not a dot");
        // Theo's open task moved after its last message: the line is the task.
        Assert.AreEqual("Fix the checkout error on iPhone", pane.Agents[2].Line);
        Assert.IsNull(pane.Agents[3].Line);
        Assert.IsNull(pane.Agents[3].Time);
        // Orla's task waits for the owner: an orange word, with a dot.
        Assert.AreEqual(AgentState.Attention, pane.Agents[4].Status.State);
        Assert.IsTrue(pane.Agents[4].ShowsDot);
        var none = Screens.Pane(Sample(s => s["needs"] = new JsonArray()), Page.Tasks, Now, Utc);
        Assert.IsFalse(none.ShowsNeeds);
        Assert.IsTrue(Screens.Pane(Sample(s => s["needs"] = new JsonArray()), Page.Needs, Now, Utc).ShowsNeeds);
    }

    [TestMethod]
    public void AChatStandsItsRequestsWhereTheyWereRaisedAndStampsItsHours()
    {
        var s = WithChat(Sample(), "manager",
            SampleFleet.Message("0b5f6c8e-1111-4222-8333-444455556666", SampleFleet.Now - 540, "Can we start the spring sale on Monday?"),
            SampleFleet.Report(5, SampleFleet.Now - 480, "Yes. Marketing has the email ready, and there is a refund in Needs you."));
        var chat = Screens.Chat(s, "manager", Now, Utc);
        // The Mac's rule of 14 November 2026 (ChatRequestPlaces.inTime): both requests were raised before his message, so
        // they stand over it at their own time, and the hour's mark is the first request's.
        CollectionAssert.AreEqual(new[] { ChatRowKind.Stamp, ChatRowKind.Request, ChatRowKind.Request, ChatRowKind.Message, ChatRowKind.Reply },
                                  chat.Rows.Select(r => r.Kind).ToArray());
        Assert.AreEqual("Today 14:32", chat.Rows[0].Text);
        Assert.AreEqual("Refund an order from 45 days ago?", chat.Rows[1].Request!.Title);
        var card = chat.Rows[1].Request!;
        Assert.AreEqual("From Fleet Manager · 14:32", card.From);
        Assert.AreEqual("Show all", card.MoreClosed);
        CollectionAssert.AreEqual(new[] { "Refund it", "Offer a 20% voucher", "Say no, politely" }, card.Options.Labels.ToArray());
        Assert.AreEqual(OptionsKind.Press, card.Options.Kind);
        Assert.AreEqual("Message Fleet Manager", chat.Composer.Placeholder);
        Assert.IsFalse(chat.Composer.CanSend, "Send shows only with words");
        Assert.IsTrue(Screens.Chat(s with { Drafts = s.Drafts.SetItem("manager", "Go") }, "manager", Now, Utc).Composer.CanSend);
        Assert.IsNull(chat.Panel.Role, "\"Fleet Manager\" names the manager");
        Assert.AreEqual(((string?)null, "", "Chat with Fleet Manager"), (chat.Role, chat.PillTrail, chat.PillWords));
        Assert.AreEqual(("Claude Code", "hub"), (chat.Panel.Provider, chat.Panel.Machine));
        Assert.IsFalse(chat.Panel.ShowsUsage);
    }

    [TestMethod]
    public void AChatSaysThinkingWhileTheAgentWorksOnHisMessage()
    {
        var mine = "0b5f6c8e-1111-4222-8333-777788889999";
        var s = WithChat(Sample(x => x["agents"]![1]!["waits_since"] = SampleFleet.Now - 60), "wren",
            SampleFleet.Report(4, SampleFleet.Now - 2460, "I answered 23 tickets today."),
            SampleFleet.Message(mine, SampleFleet.Now - 60, "Which order is it?"));
        var chat = Screens.Chat(s, "wren", Now, Utc);
        Assert.AreEqual("Thinking", chat.Waiting!.Line.Says);
        Assert.IsTrue(chat.Waiting.Shows && chat.Waiting.Line.Moving && chat.WaitingMark.Moves);
        Assert.AreEqual("Wren", chat.Label);
        Assert.AreEqual("Customer Support", chat.Panel.Role);
        // The pill over the chat: the name, then the role muted, as the Mac's chat header; an assistive app reads
        // "Chat with <name>", as VoiceOver reads the Mac's. The bug: a pill with the name alone.
        Assert.AreEqual((" · Customer Support", "Chat with Wren"), (chat.PillTrail, chat.PillWords));
        // Its server not answering: two words that stand still.
        var gone = WithChat(Sample(x => x["agents"]![1]!["last_seen"] = SampleFleet.Now - 600), "wren",
            SampleFleet.Message(mine, SampleFleet.Now - 60, "Which order is it?"));
        var still = Screens.Chat(gone, "wren", Now, Utc).Waiting!.Line;
        Assert.AreEqual(("Not answering", false), (still.Says, still.Moving));
        StringAssert.Contains(still.Detail, "Your message is kept");
    }

    /// <summary>The manager's chat waits under his answer to one of its cards, and a worker's chat does not (hub 1.283,
    /// FleetCore's ChatWaiting.waitsOnAnswers; the owner, 21 November 2026, after three answers in the manager's chat:
    /// "nothing moved on the left sidebar and the cards just remained with a check"). The manager works on the answer
    /// in a turn of its chat, so "Thinking" moves until that turn ends; a worker's answer goes to the task that asked,
    /// and nothing of its chat would end a wait on it. Only on a hub that names chat_waits_answers: an older hub's turn
    /// end never counts an answer.</summary>
    [TestMethod]
    public void TheManagersChatWaitsUnderHisAnswerToItsCardAndAWorkersDoesNot()
    {
        void Answered(JsonObject x, string by, bool counts = true)
        {
            if (counts) x["ui_features"]!.AsArray().Add((JsonNode?)ChatWaiting.AnswersFeature);
            var one = SampleFleet.Need(1, "Refund an order from 45 days ago?", "A customer asks.", by, SampleFleet.Now - 2400,
                                       "Refund it", "Offer a 20% voucher");
            one["answer"] = "Refund it";
            one["answered"] = SampleFleet.Now - 30;
            x["needs"] = new JsonArray();
            x["answered_needs"] = new JsonArray(one);
        }
        var answer = SampleFleet.Message("0b5f6c8e-1111-4222-8333-aaaabbbbcccc", SampleFleet.Now - 30, "Refund it", answerTo: 1);
        var asked = SampleFleet.Message("0b5f6c8e-1111-4222-8333-444455556666", SampleFleet.Now - 540, "Can we start the spring sale on Monday?");
        var reply = SampleFleet.Report(5, SampleFleet.Now - 480, "Yes. Marketing has the email ready.");
        var manager = WithChat(Sample(x => Answered(x, "manager")), "manager", asked, reply, answer);
        var line = Screens.Chat(manager, "manager", Now, Utc).Waiting!.Line;
        Assert.AreEqual((ChatWaiting.Working, true), (line.Says, line.Moving));
        // The row's rule with a hub from before chat_waits reads the same items.
        Assert.IsTrue(ChatWaiting.Thinks(manager.Agent("manager")!, manager.Items("manager"), SampleFleet.Now, false, true,
                                         answers: true));
        // An older hub, with no chat_waits_answers: no line under the answer, whose turn end that hub never counts.
        var older = WithChat(Sample(x => Answered(x, "manager", counts: false)), "manager", asked, reply, answer);
        Assert.IsNull(Screens.Chat(older, "manager", Now, Utc).Waiting);
        // The turn that read the answer has ended: nothing waits.
        var over = WithChat(Sample(x =>
        {
            Answered(x, "manager");
            x["agents"]![0]!["turn_ended_after"] = SampleFleet.Now - 30;
        }), "manager", asked, reply, answer);
        Assert.IsNull(Screens.Chat(over, "manager", Now, Utc).Waiting);
        // A worker's reply names his message, and his answer to a card of the worker's after it waits for nothing.
        var mine = "0b5f6c8e-1111-4222-8333-777788889999";
        var worker = WithChat(Sample(x => Answered(x, "wren")), "wren",
            SampleFleet.Message(mine, SampleFleet.Now - 120, "Which order is it?"),
            SampleFleet.Report(6, SampleFleet.Now - 90, "Order 4417. Shall I refund it?", inReplyTo: mine), answer);
        Assert.IsNull(Screens.Chat(worker, "wren", Now, Utc).Waiting);
        Assert.IsFalse(ChatWaiting.Thinks(worker.Agent("wren")!, worker.Items("wren"), SampleFleet.Now, false, true,
                                          answers: ChatWaiting.WaitsOnAnswers("worker", true)));
        Assert.IsFalse(ChatWaiting.WaitsOnAnswers("lead", true));
    }

    [TestMethod]
    public void HisMessageOnItsWayStandsAtTheEndWithItsState()
    {
        var s = Sample();
        var request = PendingRequest.New(s.Hub!, "gen1", "founderizer-windows/1", "Start now", recipient: "manager") with
        { CreatedAt = Now };
        var sending = Screens.Chat(s with { Pending = request, Sending = true }, "manager", Now, Utc);
        var row = sending.Rows.Last(r => r.Kind == ChatRowKind.Message);
        Assert.AreEqual(("Start now", "Sending…", true), (row.Text, row.TimeWords, row.SlotHoldsBack));
        // The second set (choice 1): the Mac's request line over the composer says it, and the bubble has no words.
        var failed = Screens.Chat(s with { Pending = request }, "manager", Now, Utc).Rows.Last(r => r.Kind == ChatRowKind.Message);
        Assert.AreEqual(("Start now", (string?)null, false, WriteAction.None), (failed.Text, failed.TimeWords, failed.SlotIsWarning, failed.SlotAction));
        Assert.AreEqual("Not sent", Screens.PendingBar(s with { Pending = request }, Now)!.State);
        var refused = Screens.Chat(s with { Pending = request with { Refusal = "Not sent: No." } }, "manager", Now, Utc);
        Assert.IsFalse(refused.Rows.Any(r => r.Text == "Start now"), "a refused message is the request line's, not the chat's");
    }

    [TestMethod]
    public void NeedsYouListsTheNewestFirstAndHandsTheFirstWithItsFacts()
    {
        var needs = Screens.Needs(Sample(), null, null, Now, Utc);
        Assert.AreEqual(2, needs.OpenCount);
        CollectionAssert.AreEqual(new long[] { 2, 1 }, needs.Cards.Select(c => c.Id).ToArray());
        Assert.IsTrue(needs.Cards[0].Selected);
        Assert.IsTrue(needs.Cards[0].Waits, "Marketing's task waits on request 2");
        Assert.AreEqual("Orla waits for this", needs.Cards[0].WaitWords);
        var step = needs.AtHand!;
        Assert.AreEqual("Fleet Manager · 25 min ago", step.From);
        Assert.AreEqual("Details", step.MoreClosed, "the request at hand says Details where its chat card says Show all");
        Assert.IsTrue(step.Centred);
        Assert.AreEqual("Your answer", step.Answer.Placeholder);
        Assert.IsTrue(step.Answer.ShowsPlus);
        // The chosen request, and the one that comes to hand when it leaves.
        Assert.AreEqual(1, Screens.Needs(Sample(), 1, null, Now, Utc).AtHand!.Id);
        var answered = Sample(x => x["needs"] = new JsonArray(SampleFleet.Need(1, "Refund?", "Why", "manager", SampleFleet.Now - 9)));
        Assert.AreEqual(1, Screens.Needs(answered, 2, needs.Order, Now, Utc).AtHand!.Id);
        Assert.IsTrue(Screens.Needs(Sample(x => x["needs"] = new JsonArray()), null, null, Now, Utc).Empty);
    }

    /// <summary>Owner API 1.274 (the owner, 20 November 2026, of a folded card that said "Replaced by manager with a new
    /// item: …" over the card of the new item): a request that a new item replaced is no card in its chat, and no row
    /// and no count of the answered ones on Needs you. The field decides, never the hub's words, and his answer to it on
    /// its way, or refused, keeps its card, whose words need its place.</summary>
    [TestMethod]
    public void ARequestThatANewItemReplacedIsNoCardAndIsNotCounted()
    {
        StoreState Reading(bool replacedBy) => WithChat(Sample(x =>
        {
            var need = SampleFleet.Need(3, "Send the spring sale email?", "Marketing finished the email.", "manager", SampleFleet.Now - 1800);
            need["answer"] = "Replaced by manager with a new item: Send the spring sale email on Monday?";
            need["answered"] = SampleFleet.Now - 1500;
            if (replacedBy) need["replaced_by"] = 2;
            x["answered_needs"] = new JsonArray(need);
        }), "manager", SampleFleet.Message("0b5f6c8e-1111-4222-8333-444455556666", SampleFleet.Now - 540, "Can we start the spring sale on Monday?"));
        long[] Cards(StoreState s) =>
            Screens.Chat(s, "manager", Now, Utc).Rows.Where(r => r.Kind == ChatRowKind.Request).Select(r => r.Request!.Id).ToArray();
        var replaced = Reading(replacedBy: true);
        CollectionAssert.AreEqual(new long[] { 1, 2 }, Cards(replaced), "the new item's card stands in the chat, and the old one is gone");
        var needs = Screens.Needs(replaced, null, null, Now, Utc);
        Assert.AreEqual((0, 0), (needs.EndedCount, needs.Ended.Count), "no row and no count among the answered ones");
        var answer = PendingRequest.New(replaced.Hub!, "gen1", "founderizer-windows/1", "Not now", needId: 3) with { CreatedAt = Now };
        CollectionAssert.AreEqual(new long[] { 1, 3, 2 }, Cards(replaced with { Pending = answer with { Refusal = "Not sent: No." } }));
        Assert.AreEqual(1, Screens.Needs(replaced with { Pending = answer }, null, null, Now, Utc).EndedCount);
        // From a hub before the field, the same words are a card and a row, as before.
        var before = Reading(replacedBy: false);
        CollectionAssert.AreEqual(new long[] { 1, 3, 2 }, Cards(before));
        Assert.AreEqual(1, Screens.Needs(before, null, null, Now, Utc).EndedCount);
    }

    [TestMethod]
    public void TheOptionsOfARequestAreItsOwnTicksOrTheAppsQuickReplies()
    {
        var quick = Sample(x => x["needs"] = new JsonArray(SampleFleet.Need(3, "Anything else?", "Why", "manager", SampleFleet.Now)));
        Assert.AreEqual(OptionsKind.QuickReplies, Screens.Needs(quick, null, null, Now, Utc).AtHand!.Options.Kind);
        CollectionAssert.AreEqual(new[] { "Done", "Not now", "Tell me more" },
                                  Screens.Needs(quick, null, null, Now, Utc).AtHand!.Options.Labels.ToArray());
        var ticks = Sample(x =>
        {
            var need = SampleFleet.Need(4, "Which channels?", "Why", "manager", SampleFleet.Now, "Mail", "Chat", "Phone");
            need["multi"] = true;
            x["needs"] = new JsonArray(need);
        });
        Assert.AreEqual(OptionsKind.Ticks, Screens.Needs(ticks, null, null, Now, Utc).AtHand!.Options.Kind);
        Assert.AreEqual("Send 2", OptionsModel.SendWords(2));
    }

    [TestMethod]
    public void TheBoardHasItsThreeLanesTheWaitOfTheOwnerAndTheEndedRule()
    {
        var board = Screens.Board(Sample(), ActivityPeriod.Week, null, Now, Utc);
        Assert.AreEqual("Last 7 days", board.Periods[1].Words);
        Assert.AreEqual("All agents", board.Agents[0].Words);
        CollectionAssert.AreEqual(new[] { "In progress", "Waiting", "Ended" }, board.Lanes.Select(l => l.Title).ToArray());
        CollectionAssert.AreEqual(new[] { 2, 1, 3 }, board.Lanes.Select(l => l.Count).ToArray());
        var waiting = board.Lanes[1].Cards.Single();
        Assert.AreEqual("Send the spring sale email on Monday?", waiting.OwnerLine);
        Assert.AreEqual(2, waiting.OwnerLineNeed);
        Assert.IsNull(waiting.Why, "a task that waits for him says that in orange, not again in its agent line");
        var ended = board.Lanes[2].Ended!;
        Assert.AreEqual(0, ended.Failed.Count);
        Assert.AreEqual("Show all", ended.RestWords);
        var today = Screens.Board(Sample(), ActivityPeriod.Today, "wren", Now, Utc);
        Assert.AreEqual(1, today.Lanes[0].Count);
        Assert.AreEqual(0, today.Lanes[2].Count);
        var failed = Sample(x => x["recent"]!.AsArray().Add(SampleFleet.Head(24, "Renew the domain", "pax", "failed", SampleFleet.Now - 600)));
        Assert.AreEqual(("Failed", "3 more"), (Screens.Board(failed, ActivityPeriod.Week, null, Now, Utc).Lanes[2].Ended!.Failed[0].Badge,
                                                Screens.Board(failed, ActivityPeriod.Week, null, Now, Utc).Lanes[2].Ended!.RestWords));
    }

    /// <summary>An unknown outcome asks the owner only when the check is the owner's, as on the Mac (FleetCore's
    /// TaskOutcome.waitsOnOwner; the owner, 19 November 2026, of an orange check on a task whose new session had not
    /// started: "who needs to check?"): a hold holds the task, it has ended, or its agent is a worker or a lead with no
    /// Shell box. While it runs or waits for its next session, that session checks it first: no Needs-you row or count,
    /// no place before the owner's checks in Waiting, no orange line, and the task's usage limit line stays.</summary>
    [TestMethod]
    public void AnUnknownOutcomeAsksTheOwnerOnlyWhenNoSessionOfItsAgentChecksItFirst()
    {
        static JsonObject Unknown(long id, long task) => new()
        {
            ["id"] = id, ["task"] = task, ["attempt"] = 1, ["title"] = "Send the note", ["kind"] = "send", ["state"] = "unknown",
        };
        static void Boxes(JsonObject x, string name, params string[] can) =>
            x["agents"]!.AsArray().Single(a => a!["name"]!.GetValue<string>() == name)!["can"] = new JsonArray(can.Select(c => (JsonNode?)c).ToArray());
        var snapshot = SampleFleet.Snapshot();
        foreach (var name in new[] { "wren", "theo", "pax" }) Boxes(snapshot, name, "shell", "web");
        Boxes(snapshot, "orla", "web");                                                     // its Shell box is off
        snapshot["tasks"]!.AsArray().Add(SampleFleet.Head(14, "Ask which page to change", "theo", "input-required", SampleFleet.Now - 100));
        snapshot["holds"] = new JsonArray(new JsonObject { ["id"] = 1, ["task"] = 11, ["kind"] = "pause", ["state"] = "stopped", ["attempt"] = 1 });
        snapshot["outcomes"] = new JsonArray(Unknown(1, 11), Unknown(2, 12), Unknown(3, 13), Unknown(4, 14), Unknown(5, 22));
        var s = SampleFleet.State(SampleFleet.Decode(snapshot), Now);
        // The owner's: 11 (held), 13 (Shell off) and 22 (ended), under the open requests. Theo's next session checks 12 and 14.
        var needs = Screens.Needs(s, null, null, Now, Utc);
        CollectionAssert.AreEqual(new[] { "need-2", "need-1", "task-22", "task-13", "task-11" }, needs.Cards.Select(c => c.Key).ToArray());
        Assert.AreEqual((5, 5), (needs.OpenCount, Screens.Pane(s, Page.Tasks, Now, Utc).NeedsCount));
        Assert.IsTrue(needs.Cards.Where(c => c.IsTask).All(c => c.OwnerLine == "Outcome not known: check it"));
        var lanes = Screens.Board(s, ActivityPeriod.Week, null, Now, Utc).Lanes;
        CollectionAssert.AreEqual(new long[] { 12 }, lanes[0].Cards.Select(c => c.Id).ToArray(), "a running task stays in work");
        CollectionAssert.AreEqual(new long[] { 11, 13, 22, 14 }, lanes[1].Cards.Select(c => c.Id).ToArray(), "the owner's checks first");
        CollectionAssert.AreEqual(new[] { "Outcome not known: check it", "Outcome not known: check it", "Outcome not known: check it", null },
                                  lanes[1].Cards.Select(c => c.OwnerLine).ToArray());
        Assert.IsFalse(TaskOutcome.ShellOff("manager", []), "a manager's sessions always record what they find");
        // The task page's usage limit line gives way only to the owner's check (the Mac's limitHolding).
        snapshot["agents"]!.AsArray().Single(a => a!["name"]!.GetValue<string>() == "theo")!["limit"] =
            new JsonObject { ["since"] = SampleFleet.Now - 60, ["until"] = SampleFleet.Now + 3600, ["reset_known"] = true };
        var page = new TaskPageState
        {
            Task = new FleetTask(12, "Fix the checkout error on iPhone", "", "done", "none", null, "theo", "manager", "working",
                                 SampleFleet.Now - 900, 1, 0, 0, 0),
            Outcomes = ValueList.Of(new[] { new TaskOutcome(2, 12, 1, "Send the note", "send", "unknown") }),
        };
        StoreState Limited()
        {
            var state = SampleFleet.State(SampleFleet.Decode(snapshot), Now);
            return state with { TaskPages = state.TaskPages.SetItem(12, page) };
        }
        Assert.AreEqual("Theo is at its usage limit until 16:12.", Screens.Task(Limited(), 12, Now, Utc)!.LimitWords);
        Boxes(snapshot, "theo", "web");
        Assert.IsNull(Screens.Task(Limited(), 12, Now, Utc)!.LimitWords, "a Shell-off agent's check is the owner's, and comes first");
    }

    [TestMethod]
    public void ATasksPageHasItsControlsWhileItIsOpenAndItsFacts()
    {
        var page = HubDecode.TaskPage(Encoding.UTF8.GetBytes(new JsonObject
        {
            ["db"] = "gen1", ["cursor"] = 1,
            ["task"] = new JsonObject
            {
                ["id"] = 12, ["title"] = "Fix the checkout error on iPhone", ["details"] = "Some orders fail at checkout on iPhone.",
                ["done_when"] = "a test order goes through on an iPhone", ["needs"] = "none", ["goal"] = null, ["owner"] = "theo",
                ["requester"] = "manager", ["state"] = "working", ["created"] = SampleFleet.Now - 900, ["attempt"] = 1,
                ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0, ["last_activity"] = SampleFleet.Now - 720,
            },
            ["notes"] = new JsonArray(new JsonObject { ["id"] = 1, ["task"] = 12, ["agent"] = "theo", ["ts"] = SampleFleet.Now - 800, ["text"] = "Started: Fix the checkout error on iPhone." }),
            ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
        }.ToJsonString()), "gen1", 12);
        var s = Sample() with
        {
            TaskPages = Sample().TaskPages.SetItem(12, new TaskPageState
            {
                Task = page.Task, Notes = ValueList.Of(page.Notes), Holds = ValueList.Of(page.Holds), Outcomes = ValueList.Of(page.Outcomes),
            }),
        };
        var model = Screens.Task(s, 12, Now, Utc)!;
        Assert.AreEqual("Some orders fail at checkout on iPhone.", model.Asks);
        Assert.AreEqual("Started: Fix the checkout error on iPhone.", model.Notes.Single().Text);
        Assert.AreEqual("Theo", model.Who);
        Assert.AreEqual(("Working", true, true, false), (model.Controls!.StateWord, model.Controls.ShowsPause, model.Controls.ShowsStop, model.Controls.ShowsResume));
        Assert.AreEqual("Guide this task…", model.Guidance!.Placeholder);
        CollectionAssert.AreEqual(new[] { "Asked by", "Agent", "State", "Last activity", "Done when" }, model.Facts.Select(f => f.Label).ToArray());
        Assert.AreEqual("13 Nov 2026 at 15:00", model.Facts.Single(f => f.Label == "Last activity").Value);
        var held = s with
        {
            TaskPages = s.TaskPages.SetItem(12, s.TaskPages[12] with { Holds = ValueList.Of(new[] { new TaskHold(1, 12, "pause", "stopped", 1) }) }),
        };
        var paused = Screens.Task(held, 12, Now, Utc)!;
        Assert.AreEqual(("Paused", false, true, true), (paused.Controls!.StateWord, paused.Controls.ShowsPause, paused.Controls.ShowsStop, paused.Controls.ShowsResume));
        Assert.IsNull(paused.Guidance, "a paused task has no guidance box");
        Assert.IsNull(Screens.Task(s with { Fleet = SampleFleet.Decode(SampleFleet.Snapshot()) with { UiFeatures = ["mobile"] } }, 12, Now, Utc)!.Controls);
    }

    [TestMethod]
    public void SettingsSaysTheKeyTheAddressAndTheWaitingWrite()
    {
        var s = Sample() with { Device = new MobileDevice("pc", "PC", "192.0.2.7", true, 1, SampleFleet.Now - 30, true) };
        var model = Screens.Settings(s, "http://192.0.2.10:8765", Now, Utc, new Credit("Made by an example", "@example", new Uri("https://example.com")));
        Assert.AreEqual(("In hand", StateTone.Online), (model.KeyWords, model.KeyTone));
        Assert.AreEqual(new DeviceLine("This PC's address", "PC · 192.0.2.7", "just now"), model.Address);
        Assert.IsNull(model.LastReading);
        Assert.IsNull(model.Pending);
        var request = PendingRequest.New(s.Hub!, "gen1", "c", "hi", recipient: "wren") with { Refusal = "Not sent: No." };
        var waiting = Screens.Settings(s with { Pending = request }, "", Now, Utc, null).Pending!;
        Assert.AreEqual(("Message to Wren", "Refused", WriteAction.Discard), (waiting.Title, waiting.Value, waiting.Action));
        var old = Screens.Settings(s with { LastRead = Now.AddMinutes(-5) }, "", Now, Utc, null);
        Assert.AreEqual("5 min ago", old.LastReading);
        Assert.AreEqual("Your hub did not answer. Check that its server is on.",
                        (s with { LastRead = Now.AddMinutes(-5), ReadError = HubException.NoAnswer() }).UnavailableWords(Now));
        Assert.AreEqual("This PC's key is not the one the hub keeps. Add this PC again with a new code.",
                        Screens.Line(s with { LastRead = Now.AddMinutes(-5), AuthProblem = "device_key_mismatch" }, Now)!.Words);
    }

    [TestMethod]
    public void AWholeCodeSendsItselfOnceAndARefusedCodeMayNotGoAgain()
    {
        var form = new EnrollForm();
        var (typed, send) = form.Typed("ABCD-EF");
        Assert.IsFalse(send);
        (typed, send) = typed.Typed("ABCD-EFGH");
        Assert.IsTrue(send);
        Assert.IsTrue(typed.Working);
        (typed, send) = typed.Typed("abcd efgh");
        Assert.IsFalse(send, "a code goes once");
        var refused = typed.Answered("This code did not work. Make a new one on your Mac.");
        Assert.IsFalse(refused.ShowsTryAgain);
        var noAnswer = typed.Answered("Your hub did not answer. Check that its server is on.");
        Assert.IsTrue(noAnswer.ShowsTryAgain);
        Assert.AreEqual("", typed.Answered(null).Code);
    }
}
