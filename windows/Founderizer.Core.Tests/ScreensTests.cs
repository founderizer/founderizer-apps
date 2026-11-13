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
        return s with { Chats = s.Chats.SetItem(agent, new ChatPageState { Agent = agent, Items = ValueList.Of(page.Items) }) };
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
        Assert.AreEqual("Chief of Staff", after.Names.Label("manager"));
        Assert.AreEqual("Research", after.Names.Label("ivy"));
        Assert.AreEqual(GlyphLook.Team(["manager", "wren", "theo", "pax", "orla", "ivy"])["ivy"], after.Marks["ivy"]);
        Assert.AreEqual("Research", Screens.Pane(after, Page.Tasks, Now, Utc).Agents.Last().Label);
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
        CollectionAssert.AreEqual(new[] { "Fleet Manager", "Customer Support", "Developer", "DevOps", "Marketing" },
                                  pane.Agents.Select(a => a.Label).ToArray());
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
    public void AChatStandsItsRequestsAfterTheMessageThatToldHimAndStampsItsHours()
    {
        var s = WithChat(Sample(), "manager",
            SampleFleet.Message("0b5f6c8e-1111-4222-8333-444455556666", SampleFleet.Now - 540, "Can we start the spring sale on Monday?"),
            SampleFleet.Report(5, SampleFleet.Now - 480, "Yes. Marketing has the email ready, and there is a refund in Needs you."));
        var chat = Screens.Chat(s, "manager", Now, Utc);
        CollectionAssert.AreEqual(new[] { ChatRowKind.Stamp, ChatRowKind.Message, ChatRowKind.Reply, ChatRowKind.Request, ChatRowKind.Request },
                                  chat.Rows.Select(r => r.Kind).ToArray());
        Assert.AreEqual("Today 15:03", chat.Rows[0].Text);
        Assert.AreEqual("Refund an order from 45 days ago?", chat.Rows[3].Request!.Title);
        var card = chat.Rows[3].Request!;
        Assert.AreEqual("From Fleet Manager · 14:32", card.From);
        Assert.AreEqual("Show all", card.MoreClosed);
        Assert.IsTrue(card.ShowsDiscuss);
        CollectionAssert.AreEqual(new[] { "Refund it", "Offer a 20% voucher", "Say no, politely" }, card.Options.Labels.ToArray());
        Assert.AreEqual(OptionsKind.Press, card.Options.Kind);
        Assert.AreEqual("Message Fleet Manager", chat.Composer.Placeholder);
        Assert.IsFalse(chat.Composer.CanSend, "Send shows only with words");
        Assert.IsTrue(Screens.Chat(s with { Drafts = s.Drafts.SetItem("manager", "Go") }, "manager", Now, Utc).Composer.CanSend);
        Assert.IsNull(chat.Panel.Under, "\"Fleet Manager\" names the manager");
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
        Assert.AreEqual("Customer Support", chat.Label);
        Assert.AreEqual("Wren", chat.Panel.Under);
        // Its server not answering: two words that stand still.
        var gone = WithChat(Sample(x => x["agents"]![1]!["last_seen"] = SampleFleet.Now - 600), "wren",
            SampleFleet.Message(mine, SampleFleet.Now - 60, "Which order is it?"));
        var still = Screens.Chat(gone, "wren", Now, Utc).Waiting!.Line;
        Assert.AreEqual(("Not answering", false), (still.Says, still.Moving));
        StringAssert.Contains(still.Detail, "Your message is kept");
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
        var failed = Screens.Chat(s with { Pending = request }, "manager", Now, Utc).Rows.Last(r => r.Kind == ChatRowKind.Message);
        Assert.AreEqual(("Not sent", true, WriteAction.TryAgain), (failed.TimeWords, failed.SlotIsWarning, failed.SlotAction));
        var refused = Screens.Chat(s with { Pending = request with { Refusal = "Not sent: No." } }, "manager", Now, Utc)
            .Rows.Last(r => r.Kind == ChatRowKind.Message);
        Assert.AreEqual(("Not sent: No.", WriteAction.Discard), (refused.TimeWords, refused.SlotAction));
    }

    [TestMethod]
    public void NeedsYouListsTheNewestFirstAndHandsTheFirstWithItsFacts()
    {
        var needs = Screens.Needs(Sample(), null, null, Now, Utc);
        Assert.AreEqual(2, needs.OpenCount);
        CollectionAssert.AreEqual(new long[] { 2, 1 }, needs.Cards.Select(c => c.Id).ToArray());
        Assert.IsTrue(needs.Cards[0].Selected);
        Assert.IsTrue(needs.Cards[0].Waits, "Marketing's task waits on request 2");
        Assert.AreEqual("Marketing waits for this", needs.Cards[0].WaitWords);
        var step = needs.AtHand!;
        Assert.AreEqual("Fleet Manager · 25 min ago", step.From);
        Assert.AreEqual("Details", step.MoreClosed, "the request at hand says Details where its chat card says Show all");
        Assert.IsTrue(step.Centred);
        Assert.IsTrue(step.Discussable && !step.ShowsDiscussion);
        Assert.AreEqual("Your answer", step.Answer.Placeholder);
        Assert.IsTrue(step.Answer.ShowsPlus);
        // The chosen request, and the one that comes to hand when it leaves.
        Assert.AreEqual(1, Screens.Needs(Sample(), 1, null, Now, Utc).AtHand!.Id);
        var answered = Sample(x => x["needs"] = new JsonArray(SampleFleet.Need(1, "Refund?", "Why", "manager", SampleFleet.Now - 9)));
        Assert.AreEqual(1, Screens.Needs(answered, 2, needs.Order, Now, Utc).AtHand!.Id);
        Assert.IsTrue(Screens.Needs(Sample(x => x["needs"] = new JsonArray()), null, null, Now, Utc).Empty);
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
        var noTalk = Sample(x => x["ui_features"] = new JsonArray("mobile"));
        Assert.IsFalse(Screens.Needs(noTalk, null, null, Now, Utc).AtHand!.Discussable);
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
        Assert.AreEqual("Developer", model.Who);
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
        Assert.AreEqual(("Message to Customer Support", "Refused", WriteAction.Discard), (waiting.Title, waiting.Value, waiting.Action));
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
