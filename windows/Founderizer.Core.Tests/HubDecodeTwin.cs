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
/// FLEET_E2E_KNOWLEDGE, an owner knowledge file. The first step enrolls with the code, as a new PC does.</summary>
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

    /// <summary>Discuss left the product (owner API 1.158): the route of a question about a request answers 404 for a
    /// device, so no build of this app has a write that goes there.</summary>
    [TestMethod]
    public async Task need_talk_route_is_gone()
    {
        var key = Key();
        using var http = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(Hub, $"ui/needs/{Ids("NEEDS")[0]}/talk"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        request.Headers.TryAddWithoutValidation("X-Fleet-Client", Client);
        request.Content = new StringContent($$"""{"request_id":"{{Guid.NewGuid()}}","db":"{{Database}}","text":"What does B cost?"}""",
                                            System.Text.Encoding.UTF8, "application/json");
        using var answer = await http.SendAsync(request);
        Assert.AreEqual(404, (int)answer.StatusCode, await answer.Content.ReadAsStringAsync());
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
