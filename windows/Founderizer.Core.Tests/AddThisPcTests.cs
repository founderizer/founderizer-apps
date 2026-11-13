using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>Add this PC and Settings (slice 1.5): the enrollment with the PC's kind, the key in its protected file between
/// starts and its removal, the files that the owner picked between starts, and Connect with the iPhone's rules for an
/// address.</summary>
[TestClass]
public sealed class AddThisPcTests
{
    private string folder = "";
    private string keyFile = "";
    private FakeHub hub = null!;

    [TestInitialize]
    public void Make()
    {
        folder = Directory.CreateTempSubdirectory("founderizer-pc-").FullName;
        keyFile = Path.Combine(Directory.CreateTempSubdirectory("founderizer-key-").FullName, "device.key");
        hub = new FakeHub();
    }

    [TestCleanup]
    public void Remove()
    {
        hub.Dispose();
        Directory.Delete(folder, recursive: true);
        Directory.Delete(Path.GetDirectoryName(keyFile)!, recursive: true);
    }

    /// <summary>A protection for the tests only, which a key in the clear does not pass: a mark, then each byte turned.</summary>
    private sealed class TestProtection : IKeyProtection
    {
        private static readonly byte[] Mark = "test-protection:"u8.ToArray();
        public byte[] Protect(byte[] key) => [.. Mark, .. key.Select(b => (byte)(b ^ 0x5A))];
        public byte[] Unprotect(byte[] stored)
        {
            if (!stored.AsSpan().StartsWith(Mark)) throw new InvalidDataException("The key's file does not open.");
            return stored[Mark.Length..].Select(b => (byte)(b ^ 0x5A)).ToArray();
        }
    }

    private OwnerStore Launch(IDeviceKeyStore? keys = null) =>
        new(new StoreSettings { Folder = folder, Keys = keys ?? new FileKeyStore(keyFile, new TestProtection()) });

    [TestMethod]
    public async Task AnEnrollmentNamesThePcsKindAndTheDeviceListSaysIt()
    {
        await using var store = Launch();
        await store.ConnectAsync(hub.Address.ToString());
        Assert.IsNull(await store.EnrollAsync("ABCD-EFGH"));
        var sent = JsonDocument.Parse(hub.Server.Received.Single(r => r.Target == "/ui/owner/enroll").Body).RootElement;
        Assert.AreEqual(("ABCDEFGH", "windows"), (sent.GetProperty("code").GetString(), sent.GetProperty("kind").GetString()));
        var devices = HubDecode.Devices("""{"db":"gen1","limit":4,"devices":[{"device":"pc","label":"PC","address":"100.84.1.2","key":true,"since":1.0,"last_seen":null,"this_device":true,"kind":"windows"},{"device":"iphone","label":"iPhone","address":"100.84.1.9","key":false,"since":null,"last_seen":null,"this_device":false,"kind":null}]}"""u8.ToArray());
        Assert.AreEqual(("windows", (string?)null), (devices.ThisDevice!.Kind, devices.Devices[1].Kind));
        var older = HubDecode.Devices("""{"db":"gen1","devices":[{"device":"pc","label":"PC","address":"100.84.1.2","key":true,"this_device":true}]}"""u8.ToArray());
        Assert.IsNull(older.ThisDevice!.Kind, "a hub of before the kind decodes as before");
    }

    [TestMethod]
    public async Task TheKeyStaysBetweenStartsInItsProtectedFileAndForgetTakesItOff()
    {
        await using (var first = Launch())
        {
            Assert.AreEqual(KeyState.None, first.State.Key);
            await first.ConnectAsync(hub.Address.ToString());
            Assert.IsNull(await first.EnrollAsync("ABCD-EFGH"));
        }
        var stored = File.ReadAllBytes(keyFile);
        Assert.AreEqual(-1, Encoding.UTF8.GetString(stored).IndexOf("device-key-1", StringComparison.Ordinal), "the file holds no key in the clear");
        if (!OperatingSystem.IsWindows())
            Assert.AreEqual(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(keyFile));
        hub.Server.Received.Clear();
        await using (var second = Launch())
        {
            Assert.AreEqual(KeyState.Locked, second.State.Key, "a start holds the key back until the window is in front");
            second.Unlock();
            Assert.AreEqual(KeyState.InHand, second.State.Key);
            await second.RefreshAsync();
            Assert.AreEqual("gen1", second.State.Fleet!.Db);
            Assert.IsFalse(hub.Server.Received.Any(r => r.Target.StartsWith("/ui/owner/enroll", StringComparison.Ordinal)), "a start needs no new code");
            Assert.IsTrue(hub.Server.Received.Where(r => r.Target.StartsWith("/ui/mobile", StringComparison.Ordinal))
                .All(r => r.Header("Authorization") == "Bearer device-key-1"));
            Assert.IsNull(second.ForgetKey());
            Assert.AreEqual(KeyState.None, second.State.Key);
        }
        Assert.IsFalse(File.Exists(keyFile));
        await using (var third = Launch()) Assert.AreEqual(KeyState.None, third.State.Key);
        // A key file that does not open: the key did not open, and Settings is the way on.
        File.WriteAllBytes(keyFile, "not a protected key"u8.ToArray());
        await using var fourth = Launch();
        await fourth.ConnectAsync(hub.Address.ToString());
        fourth.Unlock();
        Assert.AreEqual(KeyState.Failed, fourth.State.Key);
        Assert.AreEqual("The key's file does not open.", fourth.State.KeyDetail);
        Assert.AreEqual("This PC's key did not open. Unlock it in Settings to read the hub.", fourth.State.KeyWords);
        Assert.IsTrue(fourth.State.OutageNeedsSettings);
    }

    [TestMethod]
    public async Task APickedFileStaysBetweenStartsUntilItsMessageTakesIt()
    {
        var bytes = "a note for the manager"u8.ToArray();
        Guid id;
        await using (var first = Launch(new MemoryKeyStore("device-key-1")))
        {
            await first.ConnectAsync(hub.Address.ToString());
            first.Unlock();
            await first.RefreshAsync();
            hub.RefuseUpload = (503, """{"error":"the hub is busy"}""");
            Assert.AreEqual("Not sent: The hub is busy.", await first.AddFileAsync("agent:manager", "note.txt", bytes));
            var staged = first.State.Staged["agent:manager"].Single();
            id = staged.RequestId;
            Assert.AreEqual(("note.txt", "text/plain", (long)bytes.Length, false, "Not sent: The hub is busy."),
                            (staged.Name, staged.Mime, staged.Size, staged.IsOnHub, staged.Failure));
            first.SetDraft("manager", "Here it is");
            var composer = Screens.Chat(first.State, "manager", DateTimeOffset.UtcNow, ScreenContext.Local).Composer;
            Assert.IsFalse(composer.CanSend, "a file that did not go holds the message back");
            Assert.AreEqual(("A file did not go up. Send it again, or take it out.", true), (composer.Note, composer.NoteIsWarning));
            Assert.AreEqual("This hub takes images, PDF, ZIP, text, Markdown, CSV and JSON.",
                            await first.AddFileAsync("agent:manager", "tool.exe", bytes));
            Assert.AreEqual("This hub takes images, PDF, ZIP, text, Markdown, CSV and JSON.", first.State.FileError);
        }
        Assert.IsTrue(File.Exists(Path.Combine(folder, "staged", id.ToString())), "its bytes wait in the store's folder");
        await using (var second = Launch(new MemoryKeyStore("device-key-1")))
        {
            var kept = second.State.Staged["agent:manager"].Single();
            Assert.AreEqual((id, "Not sent: The hub is busy."), (kept.RequestId, kept.Failure), "the file stays between starts");
            second.Unlock();
            await second.RefreshAsync();
            hub.RefuseUpload = null;
            Assert.IsNull(await second.UploadAsync("agent:manager", id));
            var sent = second.State.Staged["agent:manager"].Single();
            Assert.IsTrue(sent.IsOnHub);
            Assert.IsNull(sent.Failure);
            CollectionAssert.AreEqual(new long[] { 7 }, second.State.ReadyFiles("agent:manager").ToArray());
            var uploads = hub.Server.Received.Where(r => r.Target.StartsWith("/ui/attachments", StringComparison.Ordinal)).ToList();
            Assert.IsTrue(uploads.Count >= 2 && uploads.All(r => r.Header("X-Fleet-Request-Id") == id.ToString()),
                          "each try of a file carries its one number, so the hub keeps one file");
            Assert.IsNull(await second.UploadAsync("agent:manager", id), "a file on the hub never goes again");
            Assert.AreEqual(uploads.Count, hub.Server.Received.Count(r => r.Target.StartsWith("/ui/attachments", StringComparison.Ordinal)));
            CollectionAssert.AreEqual(bytes, await second.FileAsync(sent.File!), "its own copy, with no read of the hub");
            Assert.IsFalse(hub.Server.Received.Any(r => r.Method == "GET" && r.Target.StartsWith("/ui/attachments", StringComparison.Ordinal)));
            Assert.IsTrue(Screens.Chat(second.State with { Drafts = second.State.Drafts.SetItem("manager", "x") }, "manager",
                                       DateTimeOffset.UtcNow, ScreenContext.Local).Composer.CanSend);
            await second.SendMessageAsync("manager", "Here it is");
            Assert.AreEqual(7, hub.Writes.Last().Body.GetProperty("attachments")[0].GetInt64());
            Assert.IsFalse(second.State.Staged.ContainsKey("agent:manager"), "the file went with its message");
            // One that he takes out leaves with its bytes.
            Assert.IsNull(await second.AddFileAsync("need:2", "plan.md", "# Plan"u8.ToArray()));
            var other = second.State.Staged["need:2"].Single().RequestId;
            Assert.IsNull(Screens.Needs(second.State, 2, null, DateTimeOffset.UtcNow, ScreenContext.Local).AtHand!.Answer.Note);
            second.RemoveFile("need:2", other);
            Assert.IsFalse(second.State.Staged.ContainsKey("need:2"));
            Assert.IsFalse(File.Exists(Path.Combine(folder, "staged", other.ToString())));
        }
        Assert.IsFalse(File.Exists(Path.Combine(folder, "staged", id.ToString())), "the bytes of a file that went leave the PC");
        await using var third = Launch(new MemoryKeyStore("device-key-1"));
        Assert.AreEqual(0, third.State.Staged.Count);
    }

    [TestMethod]
    public void AnAddressIsHttpOrHttpsAHostAndNothingMore()
    {
        foreach (var refused in new[] { "", "   ", "hub", "hub:8765", "ftp://hub", "http://", "http://user:secret@hub",
                                        "http://hub/path", "http://hub:8765/ui/mobile", "http://hub/?", "http://hub/?a=1",
                                        "http://hub/#part", "http://hub#", "mailto:owner@example.com", "file:///tmp" })
        {
            var e = Assert.ThrowsExactly<HubException>(() => HubClient.Address(refused), refused);
            Assert.AreEqual("Enter an HTTP or HTTPS hub address without a path or login.", e.Message);
        }
        Assert.AreEqual(new Uri("http://100.84.1.2:8765/"), HubClient.Address("  http://100.84.1.2:8765  "));
        Assert.AreEqual(new Uri("https://hub.example.com/"), HubClient.Address("https://hub.example.com/"));
        Assert.AreEqual(new Uri("http://hub-1.tail1234.ts.net:8765/"), HubClient.Address("http://hub-1.tail1234.ts.net:8765"));
    }

    [TestMethod]
    public async Task ConnectToAnotherHubDropsWhatThePcHeldOfTheOld()
    {
        await using var store = Launch(new MemoryKeyStore("device-key-1"));
        await store.ConnectAsync(hub.Address.ToString());
        store.Unlock();
        await store.RefreshAsync();
        await store.ReadDeviceAsync();
        Assert.IsNotNull(store.State.Fleet);
        Assert.IsNotNull(store.State.Device);
        Assert.AreEqual("Enter an HTTP or HTTPS hub address without a path or login.", await store.ConnectAsync("http://hub/path"));
        Assert.AreEqual(hub.Address, store.State.Hub, "a refused address keeps the hub");
        Assert.IsNotNull(store.State.Fleet);
        Assert.AreEqual("Enter an HTTP or HTTPS hub address without a path or login.",
                        Screens.Settings(store.State, "http://hub/path", DateTimeOffset.UtcNow, ScreenContext.Local).AddressError);
        using var other = new FakeHub();
        other.Snapshot["db"] = "gen9";
        Assert.IsNull(await store.ConnectAsync(other.Address.ToString()));
        var s = store.State;
        Assert.AreEqual((other.Address, (string?)null), (s.Hub, s.AddressError));
        Assert.AreEqual("gen9", s.Fleet!.Db, "the new hub's reading, and nothing of the old one");
        Assert.IsNull(s.Device);
        Assert.IsTrue(s.Chats.Keys.All(agent => other.Server.Received.Any(r => r.Target.StartsWith($"/ui/mobile/chat/{agent}", StringComparison.Ordinal))),
                      "the chats that it holds are the new hub's");
        await using var next = Launch(new MemoryKeyStore("device-key-1"));
        Assert.AreEqual(other.Address, next.State.Hub, "the address stays between starts");
    }
}
