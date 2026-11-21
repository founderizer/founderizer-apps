using System;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The decode twin (windows-app-plan.md, section 7): each read and write of a device against the scratch hub that
/// app_decode.py serves, with this library's own client, which decodes and checks each answer as the Windows app does.
/// It runs only when FLEET_E2E_HUB is set (`python3 app_decode.py --windows`); otherwise each test is inconclusive.
///
/// app_decode.py gives: FLEET_E2E_HUB and FLEET_E2E_DB; FLEET_E2E_DEVICE_CODE, a code for the device at this process's
/// address; FLEET_E2E_TASKS, the tasks to read (the first two are working, attempt 1); FLEET_E2E_NEEDS, two open items;
/// FLEET_E2E_KNOWLEDGE, an owner knowledge file; FLEET_E2E_EVENTS, a task with a record and a permission that waits;
/// FLEET_E2E_PARKED, a task that its agent parked; FLEET_E2E_OUTPUTS, an accepted result that names a text, a PNG and a
/// JPEG; FLEET_E2E_SUBTASK, a subtask of the task with a record. The first step enrolls with the code, as a new PC does.</summary>
[TestClass]
[TestCategory("HubDecode")]
public sealed class HubDecodeTwin
{
    private static readonly string? HubText = Environment.GetEnvironmentVariable("FLEET_E2E_HUB");
    private static Uri Hub => new(HubText!.TrimEnd('/') + "/");
    private static string Database => Environment.GetEnvironmentVariable("FLEET_E2E_DB") ?? "";
    private static long[] Ids(string name) =>
        (Environment.GetEnvironmentVariable("FLEET_E2E_" + name) ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries)
        .Select(long.Parse).ToArray();

    private static MobileEnrollment? enrollment;
    private static HubException? enrollFailure;
    private const string Client = "Founderizer for Windows (decode twin)";

    [ClassInitialize]
    public static async Task Enroll(TestContext _)
    {
        if (HubText is null) return;
        using var client = new HubClient();
        try
        {
            enrollment = await client.EnrollAsync(Hub, Environment.GetEnvironmentVariable("FLEET_E2E_DEVICE_CODE") ?? "");
        }
        catch (HubException e)
        {
            enrollFailure = e;
        }
    }

    private static string Key()
    {
        if (HubText is null) Assert.Inconclusive("FLEET_E2E_HUB is not set: the twin runs from app_decode.py --windows");
        if (enrollFailure is not null) Assert.Fail($"enroll: {enrollFailure.Message} ({enrollFailure.Read}: {enrollFailure.HubWords})");
        return enrollment!.Key;
    }

    private static async Task<T> Read<T>(Func<HubClient, Task<T>> read)
    {
        using var client = new HubClient();
        try
        {
            return await read(client);
        }
        catch (HubException e)
        {
            Assert.Fail($"{e.Read ?? e.Kind.ToString()}: {e.Message} {e.HubWords} (status {e.Status}, auth {e.Auth})");
            throw;
        }
    }

    private static Task<SnapshotReading> Snapshot(string key) =>
        Read(async c => (await c.SnapshotAsync(Hub, key, Database, null))!);

    [TestMethod]
    public void enroll()
    {
        Key();
        Assert.IsFalse(string.IsNullOrEmpty(enrollment!.Device));
    }

    [TestMethod]
    public async Task mobile()
    {
        var key = Key();
        var first = await Snapshot(key);
        Assert.AreEqual(Database, first.Snapshot.Db);
        Assert.IsTrue(first.Snapshot.Offers("mobile"));
        Assert.IsNotNull(first.Snapshot.LiveToken, "the snapshot carries its change token");
        // With its tag the same read is 304, or a new body with another tag when the fleet moved in between.
        var again = await Read(c => c.SnapshotAsync(Hub, key, Database, first.ETag));
        if (again is not null) Assert.AreNotEqual(first.ETag, again.ETag);
    }

    [TestMethod]
    public async Task mobile_chat()
    {
        var key = Key();
        var snapshot = (await Snapshot(key)).Snapshot;
        Assert.IsTrue(snapshot.Agents.Count > 0);
        foreach (var agent in snapshot.Agents)
        {
            var page = await Read(c => c.ChatAsync(Hub, key, Database, agent.Name));
            await Read(c => c.ChatAsync(Hub, key, Database, agent.Name, page.Cursor));
        }
    }

    [TestMethod]
    public async Task mobile_task()
    {
        var key = Key();
        Assert.IsTrue(Ids("TASKS").Length > 0);
        foreach (var id in Ids("TASKS"))
        {
            var page = await Read(c => c.TaskAsync(Hub, key, Database, id));
            await Read(c => c.TaskAsync(Hub, key, Database, id, page.Cursor));
        }
    }

    /// <summary>Owner API 1.161: the task read has the permission that waits, with the fields of the Mac's row.</summary>
    [TestMethod]
    public async Task mobile_task_permissions()
    {
        var key = Key();
        var page = await Read(c => c.TaskAsync(Hub, key, Database, Ids("EVENTS")[0]));
        var permission = page.Permissions!.Single();
        Assert.AreEqual(("Bash", null, true), (permission.Tool, permission.Decision, permission.NeedsReading));
        StringAssert.Contains(permission.Input, "https://help.example.com/api/tickets/1");
        Assert.AreEqual(0, (await Read(c => c.TaskAsync(Hub, key, Database, Ids("OUTPUTS")[0]))).Permissions!.Count);
    }

    /// <summary>Owner API 1.162: the task read has the owner's guidance, as GET /ui/state gives it.</summary>
    [TestMethod]
    public async Task mobile_task_steers()
    {
        var key = Key();
        var task = Ids("EVENTS")[0];
        var page = await Read(c => c.TaskAsync(Hub, key, Database, task));
        var words = "Guidance from the decode twin, " + Guid.NewGuid();
        await Read(c => c.CommandAsync(PendingRequest.New(Hub, Database, Client, words, command: OwnerCommand.Steer(task, page.Task.Attempt)), key));
        var steer = (await Read(c => c.TaskAsync(Hub, key, Database, task))).Steers!.Single(g => g.Text == words);
        Assert.AreEqual((task, page.Task.Attempt, Client), (steer.Task, steer.Attempt, steer.Client));
        Assert.IsTrue(steer.IsValid);
    }

    /// <summary>Owner API 1.162: each head names the task it is a subtask of; 1.163: the task read has the heads of its
    /// subtasks and of its parent.</summary>
    [TestMethod]
    public async Task mobile_parent()
    {
        var key = Key();
        var heads = (await Snapshot(key)).Snapshot.Tasks;
        Assert.AreEqual(Ids("EVENTS")[0], heads.Single(t => t.Id == Ids("SUBTASK")[0]).Parent);
        Assert.IsNull(heads.Single(t => t.Id == Ids("EVENTS")[0]).Parent);
        // Owner API 1.163: the task read has the heads of its subtasks and of its parent.
        var lead = await Read(c => c.TaskAsync(Hub, key, Database, Ids("EVENTS")[0]));
        Assert.AreEqual(Ids("SUBTASK")[0], lead.Subtasks!.Single().Id);
        Assert.IsNull(lead.ParentTask);
        var child = await Read(c => c.TaskAsync(Hub, key, Database, Ids("SUBTASK")[0]));
        Assert.AreEqual((Ids("EVENTS")[0], 0), (child.ParentTask!.Id, child.Subtasks!.Count));
    }

    /// <summary>Owner API 1.166: the device reads every ended task when the mark of GET /ui/mobile says so, and its Ended
    /// lane of each period equals the lane of every task of GET /ui/state, which the Mac counts from (the lane's rule is
    /// FleetCore's by EndedLaneTests); "Last 7 days" holds more than the 20 of `recent`.</summary>
    [TestMethod]
    public async Task mobile_ended()
    {
        var key = Key();
        var fleet = (await Snapshot(key)).Snapshot;
        Assert.IsTrue(fleet.Offers("mobile_ended"));
        var ended = await Read(c => c.EndedAsync(Hub, key, Database));
        Assert.AreEqual(fleet.EndedMark, ended.Mark);
        Assert.IsTrue(ended.Tasks.Any(t => t.TriggerId is not null), "the heads carry their schedule");
        using var http = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(Hub, $"ui/state?db={Database}"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var answer = await http.SendAsync(request);
        Assert.AreEqual(200, (int)answer.StatusCode);
        using var state = System.Text.Json.JsonDocument.Parse(await answer.Content.ReadAsStringAsync());
        var every = state.RootElement.GetProperty("tasks").EnumerateArray()
            .Select(t => System.Text.Json.JsonSerializer.Deserialize(t.GetRawText(), CoreJson.Default.MobileTaskHead)!).ToList();
        var mac = fleet with { Tasks = every.Where(t => !t.IsTerminal).ToList(), Recent = [] };
        var macEnded = every.Where(t => t.IsTerminal).ToList();
        foreach (var period in new[] { ActivityPeriod.Today, ActivityPeriod.Week, ActivityPeriod.Month, ActivityPeriod.All })
        {
            var mine = Activity.Lanes(fleet, null, period, ScreenContext.Local, ended.Tasks)[ActivityColumn.Done];
            var theirs = Activity.Lanes(mac, null, period, ScreenContext.Local, macEnded)[ActivityColumn.Done];
            CollectionAssert.AreEqual(theirs.Select(t => t.Id).ToArray(), mine.Select(t => t.Id).ToArray(), period.ToString());
            var (a, b) = (new EndedTasks(mine, ScreenContext.Local), new EndedTasks(theirs, ScreenContext.Local));
            CollectionAssert.AreEqual(b.Days.SelectMany(d => d.Groups.Select(g => d.Start + " " + g.Title + " " + string.Join(",", g.Tasks.Select(t => t.Id)))).ToArray(),
                                      a.Days.SelectMany(d => d.Groups.Select(g => d.Start + " " + g.Title + " " + string.Join(",", g.Tasks.Select(t => t.Id)))).ToArray(),
                                      period + ": the rows by day");
        }
        var week = Activity.Lanes(fleet, null, ActivityPeriod.Week, ScreenContext.Local, ended.Tasks)[ActivityColumn.Done].Count;
        Assert.IsTrue(week > 20, $"the week holds {week}");
        Assert.IsTrue(Activity.Lanes(fleet, null, ActivityPeriod.Week, ScreenContext.Local)[ActivityColumn.Done].Count <= 20,
                      "without the read, the 20 of recent");

        // Owner API 1.270: the window and the blocks of the list, joined, are the whole read, head for head.
        Assert.IsTrue(fleet.Offers("ended_blocks"));
        var window = await Read(c => c.EndedWindowAsync(Hub, key, Database));
        var list = await Read(c => c.EndedBlocksAsync(Hub, key, Database));
        Assert.AreEqual((fleet.EndedMark, window.Older!.Mark), (window.Mark, list.Mark));
        Assert.IsTrue(list.Blocks.Count(b => b.Tasks > 0) >= 2, $"the twin's hub has blocks with heads: {list.Blocks.Count}");
        var blocks = new EndedBlocks();
        blocks.See(window);
        foreach (var entry in blocks.Wanted(list))
            Assert.IsTrue(blocks.Take(await Read(c => c.EndedBlockAsync(Hub, key, Database, entry.From, list.Block))));
        blocks.Finish(list);
        Assert.IsFalse(blocks.IsBehind);
        var joined = blocks.Join(window, null);
        Assert.AreEqual((ended.Db, ended.Mark, null), (joined.Db, joined.Mark, joined.Older));
        CollectionAssert.AreEqual(ended.Tasks.ToArray(), joined.Tasks.ToArray(), "the same heads, with the same values");
    }

    /// <summary>Owner API 1.161: a parked task's head says until when, and the board puts it in Waiting.</summary>
    [TestMethod]
    public async Task mobile_parked()
    {
        var key = Key();
        var snapshot = (await Snapshot(key)).Snapshot;
        var parked = snapshot.Tasks.Single(t => t.Id == Ids("PARKED")[0]);
        Assert.IsTrue(parked.ParkedUntil > snapshot.Time, "parked until a time to come");
        Assert.AreEqual(ActivityColumn.Waiting, parked.Column(held: false));
        Assert.IsTrue(snapshot.Tasks.Where(t => t.Id != parked.Id).All(t => t.ParkedUntil is null));
    }

    /// <summary>The steps of a task (GET /ui/tasks/&lt;id&gt;/events) as a device: every task's first page decodes and
    /// keeps the page's rules; the task with a record reads the same in pages of one; its thread, its AI provider and its
    /// changed file are the Mac's.</summary>
    [TestMethod]
    public async Task task_events()
    {
        var key = Key();
        foreach (var id in Ids("TASKS").Append(Ids("OUTPUTS")[0]))
            await Read(c => c.TaskEventsAsync(Hub, key, Database, id, 0, TaskEventPage.Most));
        var task = Ids("EVENTS")[0];
        var whole = await Read(c => c.TaskEventsAsync(Hub, key, Database, task, 0, TaskEventPage.Most));
        Assert.IsFalse(whole.More);
        var timeline = new ActivityTimeline();
        long after = 0;
        var pages = 0;
        while (true)
        {
            var from = after;
            var page = await Read(c => c.TaskEventsAsync(Hub, key, Database, task, from, 1));
            timeline.Append(page.Events);
            after = page.Next;
            pages++;
            if (!page.More) break;
        }
        Assert.AreEqual(Math.Max(1, whole.Events.Count), pages, "one event in each page, and no page without one but the last");
        Assert.AreEqual(whole.Next, after);
        CollectionAssert.AreEqual(new[] { "claude" }, timeline.Runtimes[1].ToArray());
        var file = timeline.ChangedFiles.Single();
        Assert.AreEqual(("replies/make_reply.py", "modify", 4L, 1L), (file.Path, file.Action, file.Added, file.Removed));
        var thread = ThreadEntry.Of(timeline.TopRows, [], []);
        Assert.AreEqual(3, thread.Count, "a run of three steps, the agent's message, then the error, as the Mac's thread");
        var steps = thread[0].Steps!;
        Assert.AreEqual(("Edit replies/make_reply.py", "completed"), (steps[0].Row.Event.Title, steps[0].Row.Status));
        Assert.AreEqual(("agent_thought", "The reply needs the order number."), (steps[1].Row.Event.Type, steps[1].Row.Event.Text));
        Assert.AreEqual(("python3 replies/make_reply.py", "failed"), (steps[2].Row.Event.Title, steps[2].Row.Status));
        Assert.AreEqual("I answered the tickets of today.", thread[1].Said!.Row.Event.Text);
        Assert.AreEqual("An example error.", thread[2].Said!.Row.Event.Message);
    }

    /// <summary>The checked outputs as a device: the list of an accepted result, and each file with its size, SHA-256,
    /// commit and type checked, the text as UTF-8 and each picture's size from its header; an open result is refused in
    /// the Mac's words.</summary>
    [TestMethod]
    public async Task task_artifacts()
    {
        var key = Key();
        var task = Ids("OUTPUTS")[0];
        var list = await Read(c => c.TaskArtifactsAsync(Hub, key, Database, task));
        CollectionAssert.AreEqual(new[] { "text/plain", "image/png", "image/jpeg" },
                                  list.Artifacts.OrderBy(a => a.Path, StringComparer.Ordinal).Select(a => a.Mime).ToArray());
        foreach (var file in list.Artifacts)
        {
            var content = await Read(c => c.TaskArtifactAsync(Hub, key, Database, task, file));
            if (file.Mime == "text/plain") StringAssert.StartsWith(content.Text, "Certificate of the example shop");
            else if (file.Mime == "image/png") Assert.AreEqual((3, 2), (content.Width, content.Height));
            else Assert.AreEqual((640, 400), (content.Width, content.Height));
        }
        using var client = new HubClient();
        try
        {
            await client.TaskArtifactsAsync(Hub, key, Database, Ids("TASKS")[0]);
            Assert.Fail("an open task has no checked outputs");
        }
        catch (OutputException e)
        {
            Assert.AreEqual(OutputException.Problem.Stale, e.Kind, e.Message);
        }
    }

    [TestMethod]
    public async Task owner_devices()
    {
        var key = Key();
        var devices = await Read(c => c.DevicesAsync(Hub, key, Database));
        Assert.AreEqual(enrollment!.Device, devices.ThisDevice?.Device);
        Assert.IsTrue(devices.ThisDevice!.Key == true);
        // Owner API 1.149: the hub keeps the kind that the enrollment named. A hub of before it sends none.
        Assert.IsTrue(devices.ThisDevice.Kind is null or HubClient.DeviceKind, devices.ThisDevice.Kind);
    }

    [TestMethod]
    public async Task knowledge()
    {
        var key = Key();
        var path = Environment.GetEnvironmentVariable("FLEET_E2E_KNOWLEDGE") ?? "";
        var file = await Read(c => c.KnowledgeAsync(Hub, key, Database, path));
        Assert.IsTrue(file.Text.Length > 0);
    }

    [TestMethod]
    public async Task wait()
    {
        var key = Key();
        var token = (await Snapshot(key)).Snapshot.LiveToken!;
        var answer = await Read(c => c.WaitAsync(Hub, key, Database, token, 0));
        Assert.IsFalse(answer.IsGenerationChanged);
        Assert.IsTrue((await Read(c => c.WaitAsync(Hub, key, "another generation", token, 0))).IsGenerationChanged);
    }

    [TestMethod]
    public async Task message()
    {
        var key = Key();
        var request = PendingRequest.New(Hub, Database, Client, "A message from the decode twin.");
        var receipt = await Read(c => c.SendAsync(request, key));
        Assert.IsFalse(receipt.Replayed);
        var replay = await Read(c => c.SendAsync(request, key));        // the same request again is the same request
        Assert.IsTrue(replay.Replayed);
    }

    [TestMethod]
    public async Task need_answer()
    {
        var key = Key();
        var need = Ids("NEEDS")[1];
        var request = PendingRequest.New(Hub, Database, Client, "Option B", needId: need, choice: 1);
        await Read(c => c.SendAsync(request, key));
        var answered = (await Snapshot(key)).Snapshot;
        Assert.IsFalse(answered.Needs.Any(n => n.Id == need), "an answered item is no longer open");
    }

    [TestMethod]
    public async Task task_steer()
    {
        var key = Key();
        var task = Ids("TASKS")[0];
        var page = await Read(c => c.TaskAsync(Hub, key, Database, task));
        var request = PendingRequest.New(Hub, Database, Client, "Look at the logs first.",
                                         command: OwnerCommand.Steer(task, page.Task.Attempt));
        var receipt = await Read(c => c.CommandAsync(request, key));
        Assert.AreEqual(task, receipt.Steer!.Task);
    }

    [TestMethod]
    public async Task task_control()
    {
        var key = Key();
        var request = PendingRequest.New(Hub, Database, Client, "",
                                         command: OwnerCommand.Control(Ids("TASKS")[1], TaskControl.Pause));
        var receipt = await Read(c => c.CommandAsync(request, key));
        Assert.AreEqual(Ids("TASKS")[1], receipt.Hold!.Task);
    }

    [TestMethod]
    public async Task files()
    {
        // A file goes up before its message; a device reads it only once a message carries it (the hub's fix of
        // 13 November 2026, afb3188de); its bytes come back with their size and SHA-256 checked.
        var key = Key();
        var bytes = System.Text.Encoding.UTF8.GetBytes("A note from the decode twin, " + Guid.NewGuid());
        var file = await Read(c => c.UploadAsync(Hub, key, Database, bytes, "twin note.txt", "text/plain", Guid.NewGuid(), Client));
        Assert.AreEqual("twin note.txt", file.Name);
        using (var client = new HubClient())
        {
            var before = Expect.Hub(() => client.AttachmentAsync(Hub, key, Database, file));
            Assert.AreEqual(404, before.Status, "an upload that no message carries is not a device's to read");
        }
        var message = PendingRequest.New(Hub, Database, Client, "The note is attached.", attachments: [file.Id]);
        var receipt = await Read(c => c.SendAsync(message, key));
        CollectionAssert.AreEqual(new[] { file.Id }, receipt.Attachments!.ToArray());
        var back = await Read(c => c.AttachmentAsync(Hub, key, Database, file));
        CollectionAssert.AreEqual(bytes, back);
        var page = await Read(c => c.ChatAsync(Hub, key, Database, "manager"));
        Assert.IsTrue(page.Items.Any(i => i.Attachments.Any(a => a.Id == file.Id && a.Sha256 == file.Sha256)));
    }

    [TestMethod]
    public async Task store()
    {
        // The whole store against the hub: a read, the open chat, a message through the outbox, and the models.
        var key = Key();
        var folder = System.IO.Directory.CreateTempSubdirectory("founderizer-twin-store-").FullName;
        try
        {
            await using var store = new OwnerStore(new StoreSettings
            {
                Folder = folder, Keys = new MemoryKeyStore(key), ClientLabel = Client,
            });
            Assert.IsNull(await store.ConnectAsync(Hub.ToString()));
            store.Unlock();
            store.OpenChat("manager");
            await store.RefreshAsync();
            var s = store.State;
            Assert.IsNull(s.ReadError, s.ReadError?.Message + " " + s.ReadError?.HubWords);
            Assert.AreEqual(Database, s.Fleet!.Db);
            Assert.IsTrue(s.HasRead("manager"));
            store.SetDraft("manager", "A message from the store of the decode twin.");
            await store.SendMessageAsync("manager");
            Assert.IsNull(store.State.Pending, store.State.SendError);
            await store.RefreshAsync();
            Assert.IsNull(store.State.Delivered, "the chat's read brought the hub's copy of the message");
            var now = DateTimeOffset.UtcNow;
            var pane = Screens.Pane(store.State, Page.Chat("manager"), now, ScreenContext.Local);
            Assert.AreEqual(store.State.Fleet!.Agents.Count, pane.Agents.Count);
            var chat = Screens.Chat(store.State, "manager", now, ScreenContext.Local);
            Assert.IsTrue(chat.Rows.Any(r => r.Text == "A message from the store of the decode twin."));
            Screens.Needs(store.State, null, null, now, ScreenContext.Local);
            Screens.Board(store.State, ActivityPeriod.All, null, now, ScreenContext.Local);
            await store.ReadDeviceAsync();
            Assert.AreEqual(enrollment!.Device, store.State.Device?.Device);
        }
        finally
        {
            System.IO.Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public async Task store_task_page()
    {
        // The store's task page against the hub: the record of the open task comes in its first read, then its thread,
        // its AI provider and its changed file; the checked outputs of an accepted result list and open.
        var key = Key();
        var folder = System.IO.Directory.CreateTempSubdirectory("founderizer-twin-task-").FullName;
        try
        {
            await using var store = new OwnerStore(new StoreSettings
            {
                Folder = folder, Keys = new MemoryKeyStore(key), ClientLabel = Client,
            });
            Assert.IsNull(await store.ConnectAsync(Hub.ToString()));
            store.Unlock();
            store.SetFront(true);
            var task = Ids("EVENTS")[0];
            store.OpenTask(task);
            await store.RefreshAsync();
            for (var i = 0; i < 100 && !(store.State.TaskPages.TryGetValue(task, out var p1) && p1.Activity is not null); i++) await Task.Delay(100);
            var now = DateTimeOffset.UtcNow;
            var page = Screens.Task(store.State, task, now, ScreenContext.Local);
            Assert.IsNotNull(page, "the page shows once its record came");
            CollectionAssert.AreEqual(new[] { ThreadRowKind.Steps, ThreadRowKind.Message, ThreadRowKind.Error },
                                      page.Thread.Take(3).Select(r => r.Kind).ToArray());
            Assert.AreEqual(("3 steps", "1 failed", true), (page.Thread[0].Steps!.Title, page.Thread[0].Steps!.Status, page.Thread[0].Steps!.Orange));
            Assert.AreEqual(("Thinking", "An example error."), (page.Thread[0].Steps!.Rows[1].Title, page.Thread[2].Text));
            var permission = page.Thread.Single(r => r.Kind == ThreadRowKind.Permission).Permission!;
            Assert.AreEqual(("Bash", "Waiting"), (permission.Title, permission.Status));
            Assert.AreEqual("Claude Code", page.Facts.Single(f => f.Label == "AI provider").Value);
            Assert.AreEqual(("Modify", "+4", "−1"), (page.ChangedFiles!.Rows[0].Action, page.ChangedFiles.Rows[0].Added, page.ChangedFiles.Rows[0].Removed));

            // Owner API 1.166: the store read every ended task, and the board counts them.
            Assert.IsNotNull(store.State.Ended);
            var lane = Screens.Board(store.State, ActivityPeriod.Week, null, DateTimeOffset.UtcNow, ScreenContext.Local)
                .Lanes.Single(l => l.Column == ActivityColumn.Done);
            Assert.IsTrue(lane.Count > 20, $"Ended {lane.Count}");

            var outputs = Ids("OUTPUTS")[0];
            store.OpenTask(outputs);
            await store.RefreshAsync();
            for (var i = 0; i < 100 && !(store.State.TaskPages.TryGetValue(outputs, out var p2) && p2.Activity is not null); i++) await Task.Delay(100);
            await store.ListOutputsAsync();
            var listed = Screens.Task(store.State, outputs, DateTimeOffset.UtcNow, ScreenContext.Local)!.Result!.Outputs!;
            Assert.AreEqual(("Reload outputs", 3, null), (listed.ViewWords, listed.Files.Count, listed.Error));
            await store.ViewOutputAsync(listed.Files.Single(f => !f.IsImage).File);
            var opened = Screens.Task(store.State, outputs, DateTimeOffset.UtcNow, ScreenContext.Local)!.Result!.Outputs!;
            Assert.IsNull(opened.Error, opened.Error);
            StringAssert.StartsWith(opened.Opened!.Text, "Certificate of the example shop");
            StringAssert.StartsWith(opened.Opened.Download, "Verified download · ");
            store.CloseOutputs();
            Assert.AreEqual("View outputs", Screens.Task(store.State, outputs, DateTimeOffset.UtcNow, ScreenContext.Local)!.Result!.Outputs!.ViewWords);
        }
        finally
        {
            System.IO.Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public async Task device_level()
    {
        // The device reaches the device routes only: the team stays on the owner's Mac.
        var key = Key();
        using var http = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(Hub, $"ui/team?db={Database}"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var response = await http.SendAsync(request);
        Assert.AreEqual(403, (int)response.StatusCode);
        StringAssert.Contains(await response.Content.ReadAsStringAsync(), "device_not_allowed");
    }
}
