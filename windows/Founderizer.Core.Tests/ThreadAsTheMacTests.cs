using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>A task's thread and board as the Mac's (the owner, 14 November 2026: "it needs to match the mac"): every row of
/// RuntimeActivity.swift and what it opens to, the owner's guidance, the live plan, a child agent's thread, the panel's
/// models and child agents (FleetView.swift taskFacts), and a task that waits for its subtasks (FleetCore Activity.swift,
/// Founderizer 0.1.220).</summary>
[TestClass]
public sealed class ThreadAsTheMacTests
{
    private static TaskEvent Call(long id, double? ts, string call, string? title, string? kind, string status, string? parent = null,
                                  string? output = null, IReadOnlyList<EventLocation>? locations = null, EventSubagent? subagent = null) =>
        new(id, 1, "s1", id, ts, "tool_call", ToolCallId: call, Title: title, Kind: kind, Status: status, Parent: parent, Output: output,
            Locations: locations, Subagent: subagent);

    private static TaskEvent Update(long id, double? ts, string call, string status, string? output = null) =>
        new(id, 1, "s1", id, ts, "tool_call_update", ToolCallId: call, Status: status, Output: output);

    private static TaskEvent Event(long id, double? ts, string type, string? text = null, string? parent = null, string? message = null,
                                   IReadOnlyList<PlanEntry>? entries = null) =>
        new(id, 1, "s1", id, ts, type, Text: text, Parent: parent, Message: message, Entries: entries);

    private static FleetTask Task(string state = "working", long attempt = 1) => HubDecode.TaskPage(Encoding.UTF8.GetBytes(new JsonObject
    {
        ["db"] = "gen1", ["cursor"] = 1, ["notes"] = new JsonArray(), ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
        ["task"] = new JsonObject
        {
            ["id"] = 7, ["title"] = "Answer today's support tickets", ["details"] = "Answer them.", ["done_when"] = "all answered",
            ["needs"] = "none", ["goal"] = null, ["owner"] = "wren", ["requester"] = "manager", ["state"] = state, ["created"] = Now - 9000,
            ["attempt"] = attempt, ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0, ["last_activity"] = Now - 60,
            ["delivered"] = state == "completed" ? Now - 60 : null,
        },
    }.ToJsonString()), "gen1", 7).Task;

    private static ActivityTimeline Record() => ActivityTimeline.Of([
        new TaskEvent(1, 1, "s1", 1, 1, "session", Runtime: "claude"),
        new TaskEvent(2, 1, "s1", 2, 1, "model", RequestedModel: "claude-opus-5-5", Model: "claude-sonnet-5-5", RequestedEffort: "xhigh", Effort: "high"),
        Call(3, 10, "c1", "fleet: hand_over", "other", "completed"),
        Call(4, 11, "c2", "Read notes.md", "read", "completed", output: "3 lines", locations: [new EventLocation("notes.md")]),
        Call(5, 12, "x1", "exec: python3 run.py", "execute", "in_progress"),
        Call(6, 13, "a", "Read a.txt", "read", "completed"),
        Update(7, 14, "x1", "completed", "Script completed in 1 s"),
        Call(8, 15, "t1", "Task: research", "other", "in_progress", subagent: new EventSubagent("Researcher")),
        Event(9, 16, "agent_message", "Found it.", parent: "t1"),
        Event(10, 17, "plan", parent: "t1", entries: [new PlanEntry("Search", "completed"), new PlanEntry("Write", "in_progress")]),
        Call(11, 18, "c3", "Search docs", "search", "completed", parent: "t1"),
        Event(12, 19, "error", parent: "t1", message: "Rate limited"),
        Call(13, 20, "c4", "fleet: report_progress", "other", "completed", parent: "t1"),
        Event(14, 21, "error"),
        Event(15, 22, "truncated"),
        Event(16, 23, "plan", entries: [new PlanEntry("Read the tickets", "completed"), new PlanEntry("Answer them", "in_progress"),
                                         new PlanEntry("Report", "pending")]),
    ]);

    private static StoreState Page(FleetTask task, ActivityTimeline? record = null, string? error = null, bool fresh = true)
    {
        var fleet = Decode(Snapshot()) with { UiFeatures = ["mobile", "thread_events"] };
        var s = State(fleet, fresh ? Clock : Clock - TimeSpan.FromMinutes(5));
        var steers = new[]
        {
            new TaskSteer(1, 7, 1, "Look at the logs first.", Now - 30, "r-1", "founderizer-windows/1", ReadAt: Now - 20),
            new TaskSteer(2, 7, 1, "Then the config.", Now - 10, "r-2", "founderizer-windows/1"),
        };
        return s with
        {
            TaskPages = s.TaskPages.SetItem(7, new TaskPageState
            {
                Task = task, Steers = ValueList.Of(steers), ActivityError = error,
                Activity = TaskActivity.Of(record ?? Record(), 16),
            }),
        };
    }

    [TestMethod]
    public void EveryRowOfTheThreadIsTheMacs()
    {
        var model = Screens.Task(Page(Task()), 7, Clock, Utc)!;
        CollectionAssert.AreEqual(new[] { ThreadRowKind.Steps, ThreadRowKind.Error, ThreadRowKind.Truncated, ThreadRowKind.Guidance, ThreadRowKind.Guidance },
                                  model.Thread.Select(r => r.Kind).ToArray());
        var steps = model.Thread[0].Steps!;
        Assert.AreEqual(("Task: research", "Step 4 · Running"), (steps.Title, steps.Status), "the child agent's call runs");
        CollectionAssert.AreEqual(new[] { "event-3", "event-4", "event-5", "event-8" }, steps.Rows.Select(r => r.Key).ToArray(),
                                  "the completed script keeps its id and shows its first call");

        var handOver = steps.Rows[0];
        Assert.AreEqual(("Hand Over", "fleet: hand_over", "No output reported.", "Done"), (handOver.Title, handOver.FullTitle, handOver.Output, handOver.Status));
        var read = steps.Rows[1];
        Assert.AreEqual((null, "3 lines", StepSymbol.Read), (read.FullTitle, read.Output, read.Symbol));
        CollectionAssert.AreEqual(new[] { "notes.md" }, read.Locations.ToArray());
        var script = steps.Rows[2];
        Assert.AreEqual(("Read a.txt", "exec: python3 run.py", "Script completed in 1 s", "Script result"),
                        (script.Title, script.Script, script.ScriptResult, script.ScriptResultTitle));
        var agent = steps.Rows[3];
        Assert.AreEqual((StepSymbol.Subagent, "Researcher", "Running", null, "Open agent thread"),
                        (agent.Symbol, agent.Title, agent.Status, agent.Output, agent.OpenChildWords));
        CollectionAssert.AreEqual(new[] { "Search docs", "Rate limited", "fleet: report_progress" }, agent.ChildLines.ToArray(),
                                  "the last three rows that it wrote, as the Mac lists them");
        Assert.AreEqual(new ToolKey(1, "s1", null, "t1"), agent.Child);

        Assert.AreEqual("Runtime error", model.Thread[1].Text);
        Assert.AreEqual("The worker reached its activity record limit.", model.Thread[2].Text);
        Assert.AreEqual(new SteerRowModel("Look at the logs first.", "Guidance · Attempt 1 · Read", TimeWords.DateAndTime(Now - 20, Utc)),
                        model.Thread[3].Guidance);
        Assert.AreEqual("Guidance · Attempt 1 · Received", model.Thread[4].Guidance!.Line);
        Assert.AreEqual("Not delivered · task restarted",
                        StepWords.Delivery(new TaskSteer(2, 7, 1, "Then the config.", Now - 10, "r-2", "c"), currentAttempt: 2));

        CollectionAssert.AreEqual(new[] { new PlanStep("Read the tickets", PlanState.Done), new PlanStep("Answer them", PlanState.Running),
                                          new PlanStep("Report", PlanState.ToDo) }, model.LivePlan!.ToArray());
        Assert.AreEqual((null, null, "Earlier activity"), (model.ActivityError, model.OfflineWords, model.EarlierWords));
        Assert.AreEqual(6, model.ThreadTopRows, "the top rows as they show: seven, a script folded into its call, the child's not");
    }

    [TestMethod]
    public void ThePanelHasTheMacsModelsAndChildAgents()
    {
        var model = Screens.Task(Page(Task()), 7, Clock, Utc)!;
        var labels = model.Facts.Select(f => f.Label).ToList();
        var at = labels.IndexOf("AI provider");
        CollectionAssert.AreEqual(new[] { "AI provider", "Model requested", "Model used", "Reasoning requested", "Reasoning used", "", "Last activity" },
                                  labels.Skip(at).Take(7).ToArray());
        CollectionAssert.AreEqual(new[] { "Claude Code", "claude-opus-5-5", "claude-sonnet-5-5", "Extra high", "High", "The AI provider used other settings" },
                                  model.Facts.Skip(at).Take(6).Select(f => f.Value).ToArray());
        Assert.IsTrue(model.Facts[at + 5].Warning);
        Assert.AreEqual(("Child agents", null), (model.ChildAgents!.Heading, model.ChildAgents.MoreWords));
        Assert.AreEqual(new ChildAgentRow(new ToolKey(1, "s1", null, "t1"), "Researcher", ChildState.Working, "Open child thread · Attempt 1"),
                        model.ChildAgents.Rows.Single());

        var asked = ActivityTimeline.Of([new TaskEvent(1, 1, "s1", 1, 1, "model")]);
        var plain = Screens.Task(Page(Task(), asked), 7, Clock, Utc)!;
        CollectionAssert.AreEqual(new[] { "Automatic", "Not reported", "Automatic", "Not reported" },
                                  plain.Facts.Where(f => f.Label.StartsWith("Model") || f.Label.StartsWith("Reasoning")).Select(f => f.Value).ToArray());
        Assert.IsFalse(plain.Facts.Any(f => f.Warning));
        Assert.IsNull(plain.ChildAgents);
        Assert.AreEqual(("Max", "Extra high"), (StepWords.Reasoning("max"), StepWords.Reasoning("xhigh")));
        Assert.IsNull(Screens.Task(Page(Task(attempt: 2)), 7, Clock, Utc)!.Facts.FirstOrDefault(f => f.Label == "Model used"),
                      "only the models of the attempt now");

        var many = ActivityTimeline.Of(Enumerable.Range(1, 21).Select(i =>
            Call(i, i, "t" + i, "Task", "other", "completed", subagent: new EventSubagent("Agent " + i))));
        Assert.AreEqual((20, "More agents in the task thread", ChildState.Done),
                        (Screens.Task(Page(Task(), many), 7, Clock, Utc)!.ChildAgents!.Rows.Count,
                         Screens.Task(Page(Task(), many), 7, Clock, Utc)!.ChildAgents!.MoreWords,
                         Screens.Task(Page(Task(), many), 7, Clock, Utc)!.ChildAgents!.Rows[0].State));
    }

    [TestMethod]
    public void AChildAgentsThreadIsTheMacs()
    {
        var s = Page(Task());
        var child = Screens.ChildThread(s, 7, new ToolKey(1, "s1", null, "t1"), Clock, Utc)!;
        Assert.AreEqual(("Back", "Researcher", "Attempt 1", null, "Earlier activity"),
                        (child.BackWords, child.Title, child.AttemptWords, child.WaitingWords, child.EarlierWords));
        CollectionAssert.AreEqual(new[] { ActivityRowKind.Message, ActivityRowKind.Plan, ActivityRowKind.Tool, ActivityRowKind.Error },
                                  child.Rows.Select(r => r.Kind).ToArray(), "a plain list, without Fleet's own calls");
        Assert.AreEqual("Found it.", child.Rows[0].Words!.Text);
        Assert.AreEqual(("Plan", StepSymbol.Plan), (child.Rows[1].Title, child.Rows[1].Symbol));
        CollectionAssert.AreEqual(new[] { new PlanStep("Search", PlanState.Done), new PlanStep("Write", PlanState.Running) }, child.Rows[1].Plan.ToArray());
        Assert.AreEqual(("Rate limited", true), (child.Rows[3].Text, child.Rows[3].Orange));
        Assert.IsNull(Screens.ChildThread(s, 7, new ToolKey(1, "s1", null, "c2"), Clock, Utc), "a call with no agent has no thread");

        var waiting = ActivityTimeline.Of([Call(1, 1, "t1", "Task", "other", "in_progress", subagent: new EventSubagent("Researcher"))]);
        Assert.AreEqual("Waiting for agent activity.",
                        Screens.ChildThread(Page(Task(), waiting), 7, new ToolKey(1, "s1", null, "t1"), Clock, Utc)!.WaitingWords);
    }

    [TestMethod]
    public void ThePanelHasTheMacsParentTaskAndSubtasks()
    {
        var parentOf = Task() with { Parent = 30 };
        var s = Page(parentOf);
        MobileTaskHead Head(long id, string title, string state, long? parent, long? accepted = null) =>
            new(id, title, state, "theo", "manager", 1, Now - 600, Accepted: accepted, Started: Now - 600, LastActivity: Now - 60, Parent: parent);
        var page = s.TaskPages[7];
        var fromRead = s with
        {
            TaskPages = s.TaskPages.SetItem(7, page with
            {
                ParentTask = Head(30, "Ship the release", "working", null),
                Subtasks = ValueList.Of(new[] { Head(8, "Write the notes", "completed", 7, accepted: 1), Head(9, "Fix the build", "working", 7) }),
            }),
        };
        var model = Screens.Task(fromRead, 7, Clock, Utc)!;
        Assert.AreEqual(new ParentTaskModel(30, "Parent task · Ship the release"), model.ParentTask);
        Assert.AreEqual("Subtasks", model.Subtasks!.Heading);
        CollectionAssert.AreEqual(new[] { (8L, "Write the notes"), (9L, "Fix the build") }, model.Subtasks.Rows.Select(r => (r.Id, r.Title)).ToArray());
        Assert.AreEqual(TaskWords.State(Head(9, "Fix the build", "working", 7), fromRead.Fleet!, fromRead.Names), model.Subtasks.Rows[1].Status);

        // A hub before owner API 1.163: the parent's title and the subtasks from the reading's heads, else "Parent task".
        Assert.AreEqual(new ParentTaskModel(30, "Parent task"), Screens.Task(s, 7, Clock, Utc)!.ParentTask);
        Assert.IsNull(Screens.Task(s, 7, Clock, Utc)!.Subtasks);
        var withHeads = s with { Fleet = s.Fleet! with { Tasks = [.. s.Fleet.Tasks, Head(30, "Ship the release", "working", null), Head(9, "Fix the build", "working", 7)] } };
        var fallback = Screens.Task(withHeads, 7, Clock, Utc)!;
        Assert.AreEqual(("Parent task · Ship the release", 9L), (fallback.ParentTask!.Words, fallback.Subtasks!.Rows.Single().Id));
        Assert.IsNull(Screens.Task(Page(Task()), 7, Clock, Utc)!.ParentTask, "a task with no parent has no link");
    }

    [TestMethod]
    public void TheLinesOverTheThreadAreTheMacs()
    {
        Assert.AreEqual("Activity is unavailable. Retrying…", Screens.Task(Page(Task(), error: StepWords.Unavailable), 7, Clock, Utc)!.ActivityError);
        var old = Screens.Task(Page(Task(), error: StepWords.Unavailable, fresh: false), 7, Clock, Utc)!;
        Assert.AreEqual((null, "Offline · last activity"), (old.ActivityError, old.OfflineWords));
        Assert.IsNull(Screens.Task(Page(Task("completed")), 7, Clock, Utc)!.LivePlan, "a task that ended is read by its result");
    }

    [TestMethod]
    public void ATaskThatWaitsForItsSubtasksStandsInWaitingAsOnTheMac()
    {
        JsonObject Sub(long id, string owner, double activity, long parent, string state = "working")
        {
            var head = Head(id, "Subtask " + id, owner, state, activity);
            head["parent"] = parent;
            return head;
        }
        MobileSnapshot Fleet(bool? works, Action<JsonObject>? change = null)
        {
            var snapshot = Snapshot();
            var heads = snapshot["tasks"]!.AsArray();
            heads.Add(Head(40, "Ship the release", "manager", "working", Now - 3000, works: works));
            heads.Add(Sub(41, "pax", Now - 900, 40));
            heads.Add(Sub(42, "theo", Now - 100, 40));
            heads.Add(Sub(43, "theo", Now - 2000, 40));
            heads.Add(Sub(44, "wren", Now - 50, 40, state: "completed"));
            change?.Invoke(snapshot);
            return Decode(snapshot);
        }
        var fleet = Fleet(works: false);
        CollectionAssert.AreEqual(new[] { "theo", "pax" }, Activity.SubtaskWaits(fleet)[40].ToArray(), "each agent once, the newest first; an ended one is not");
        var s = State(fleet, Clock);
        TaskCardRow Card(StoreState state)
        {
            var (column, card) = Screens.Board(state, ActivityPeriod.All, null, Clock, Utc).Lanes
                .SelectMany(l => l.Cards.Select(c => (l.Column, c))).Single(x => x.c.Id == 40);
            return column == ActivityColumn.Waiting ? card : card with { Why = "in progress" };
        }
        var waits = Card(s);
        Assert.AreEqual("Waiting for Theo, Pax", waits.Why);
        StringAssert.EndsWith(waits.Hover, "Waiting for Theo, Pax");

        Assert.AreEqual("in progress", Card(State(Fleet(works: true), Clock)).Why, "its session works, to check a result");
        Assert.AreEqual("in progress", Card(State(Fleet(works: null), Clock)).Why, "a hub that does not say changes nothing");

        var parked = Fleet(works: false, snapshot => snapshot["tasks"]!.AsArray().Single(t => t!["id"]!.GetValue<long>() == 40)!["parked_until"] = Now + 3600);
        var until = Card(State(parked, Clock));
        StringAssert.StartsWith(until.Why, "Until ");
        StringAssert.EndsWith(until.Hover, until.Why!, "its hover says what the card says");
        var held = fleet with { Holds = [new TaskHold(1, 40, "pause", "stopped", 1)] };
        Assert.AreEqual("Paused", Card(State(held, Clock)).Why, "a hold keeps its own word");
    }

    [TestMethod]
    public async Task TheStoreKeepsTheGuidanceAndTheWordsOfAFailedRead()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-thread-").FullName;
        using var hub = new FakeHub();
        try
        {
            hub.Snapshot["ui_features"]!.AsArray().Add((JsonNode)"thread_events");
            var page = new JsonObject
            {
                ["db"] = "gen1", ["cursor"] = 1, ["notes"] = new JsonArray(), ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
                ["task"] = new JsonObject
                {
                    ["id"] = 7, ["title"] = "Example task", ["details"] = "Do it.", ["done_when"] = "done", ["needs"] = "none", ["goal"] = null,
                    ["owner"] = "wren", ["requester"] = "manager", ["state"] = "working", ["created"] = Now - 9000, ["attempt"] = 1,
                    ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0,
                },
                ["steers"] = new JsonArray(new JsonObject
                {
                    ["id"] = 3, ["task"] = 7, ["attempt"] = 1, ["text"] = "Look at the logs first.", ["created"] = Now - 30,
                    ["read_at"] = Now - 20, ["request_id"] = "r-1", ["client"] = "founderizer-windows/1",
                }),
            };
            hub.Tasks[7] = page;
            hub.Events[7] = [];
            var clock = new ManualClock(Clock);
            await using var store = new OwnerStore(new StoreSettings
            {
                Folder = folder, Keys = new MemoryKeyStore("device-key-1"), ClientLabel = "founderizer-windows/1", Clock = clock,
            });
            await store.ConnectAsync(hub.Address.ToString());
            store.Unlock();
            await store.RefreshAsync();
            store.OpenTask(7);
            await store.RefreshAsync();
            await Until(() => store.State.TaskPages.TryGetValue(7, out var p) && p.Activity is not null, "first read");
            Assert.AreEqual("Guidance · Attempt 1 · Read", Screens.Task(store.State, 7, clock.Now, Utc)!.Thread.Single().Guidance!.Line);

            hub.RefuseEvents = (503, """{"error":"the record is busy"}""");
            await Ticking(clock, () => store.State.TaskPages[7].ActivityError is not null, "the refusal");
            Assert.AreEqual("the record is busy", Screens.Task(store.State, 7, clock.Now, Utc)!.ActivityError, "the hub's own sentence");
            hub.RefuseEvents = (500, "not json");
            await Ticking(clock, () => store.State.TaskPages[7].ActivityError == StepWords.Unavailable, "no words");
            hub.RefuseEvents = null;
            await Ticking(clock, () => store.State.TaskPages[7].ActivityError is null, "answered");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    /// <summary>The clock moves 3 seconds at a time until the store gets there: the store's loop sets its next wait only
    /// after its read, so one move can come before that wait.</summary>
    internal static async Task Ticking(ManualClock clock, Func<bool> done, string step = "")
    {
        for (var i = 0; i < 10 && !done(); i++)
        {
            clock.Advance(TimeSpan.FromSeconds(3));
            for (var j = 0; j < 8 && !done(); j++) await System.Threading.Tasks.Task.Delay(25);
        }
        Assert.IsTrue(done(), "the store did not get there: " + step);
    }

    private static async Task Until(Func<bool> done, string step = "")
    {
        for (var i = 0; i < 200 && !done(); i++) await System.Threading.Tasks.Task.Delay(25);
        Assert.IsTrue(done(), "the store did not get there: " + step);
    }
}
