using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>The fourth set of pictures (the owner's "Yes, as shown" of 14 November 2026): the checked outputs with the
/// Mac's checks and words, the steps of a task from its record, a permission that waits, and a task parked until a time.
/// Each rule is the Mac's at origin/main of that day (ArtifactSection.swift, Artifact.swift, RuntimeActivity.swift,
/// FleetView.swift taskFacts, ActivityBoard.swift why, FleetCore Activity.swift).</summary>
[TestClass]
public sealed class FourthSetTests
{
    private const string Commit = "2660dc5aa1b2c3d4e5f60718293a4b5c6d7e8f90";

    private static ArtifactFile File(string path, byte[] bytes, string mime) =>
        new(path, Commit, Convert.ToHexStringLower(SHA256.HashData(bytes)), bytes.Length, mime);

    private static byte[] Png(uint width, uint height)
    {
        var bytes = new byte[33];
        new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, (byte)'I', (byte)'H', (byte)'D', (byte)'R' }.CopyTo(bytes, 0);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(16), width);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(20), height);
        return bytes;
    }

    /// <summary>A JPEG head: SOI, an APP0 segment, then a baseline frame (SOF0) of the given size.</summary>
    private static byte[] Jpeg(ushort width, ushort height) =>
        [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, .. "JFIF\0"u8, 1, 1, 0, 0, 1, 0, 1, 0, 0,
         0xFF, 0xC0, 0x00, 0x11, 0x08, (byte)(height >> 8), (byte)height, (byte)(width >> 8), (byte)width, 3,
         1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xFF, 0xD9];

    private static OutputException Output(Func<Task> call)
    {
        try { call().GetAwaiter().GetResult(); }
        catch (OutputException e) { return e; }
        Assert.Fail("no OutputException");
        return null!;
    }

    // ---------------------------------------------------------------- the checked outputs: the client

    [TestMethod]
    public void AFileReferenceKeepsTheMacsRules()
    {
        var text = File("outputs/T-4/certificate.txt", "x"u8.ToArray(), "text/plain");
        Assert.IsTrue(text.IsValid);
        Assert.IsTrue((text with { Path = "outputs/T-4/shop-page.PNG", Mime = "image/png" }).IsValid, "the extension in any case");
        Assert.IsTrue((text with { Path = "outputs/a.jpeg", Mime = "image/jpeg", Bytes = ArtifactFile.PictureLimit }).IsValid);
        foreach (var bad in new[]
        {
            text with { Path = "output/T-4/a.txt" }, text with { Path = "outputs/" }, text with { Path = "outputs//a.txt" },
            text with { Path = "outputs/../a.txt" }, text with { Path = "outputs/./a.txt" }, text with { Path = "outputs/a\u0007.txt" },
            text with { Path = "outputs/a%20b.txt" }, text with { Path = "outputs/a:b.txt" }, text with { Path = "outputs/a?.txt" },
            text with { Path = "outputs/a#.txt" }, text with { Path = "outputs/a\\b.txt" }, text with { Path = "outputs/" + new string('a', 1020) + ".txt" },
            text with { Path = "outputs/a.pdf" }, text with { Mime = "image/png" }, text with { Commit = Commit[..39] },
            text with { Commit = Commit[..39] + "g" }, text with { Sha256 = text.Sha256[..63] }, text with { Bytes = -1 },
            text with { Bytes = ArtifactFile.TextLimit + 1 }, text with { Path = "outputs/a.png", Mime = "image/png", Bytes = ArtifactFile.PictureLimit + 1 },
        })
            Assert.IsFalse(bad.IsValid, bad.ToString());
    }

    [TestMethod]
    public async Task TheListIsHeldToItsRules()
    {
        var a = File("outputs/T-4/certificate.txt", "x"u8.ToArray(), "text/plain");
        var b = File("outputs/T-4/shop-page.png", Png(2, 2), "image/png");
        JsonObject Item(ArtifactFile f) => new() { ["path"] = f.Path, ["commit"] = f.Commit, ["sha256"] = f.Sha256, ["bytes"] = f.Bytes, ["mime"] = f.Mime };
        string Body(string db, long task, params ArtifactFile[] files) =>
            new JsonObject { ["db"] = db, ["task"] = task, ["artifacts"] = new JsonArray(files.Select(f => (JsonNode)Item(f)).ToArray()) }.ToJsonString();
        var answer = "";
        using var hub = new LoopbackHub(_ => LoopbackHub.Json(200, answer));
        using var client = new HubClient();

        answer = Body("gen1", 4, a, b);
        var list = await client.TaskArtifactsAsync(hub.Address, "device-key-1", "gen1", 4);
        Assert.AreEqual(2, list.Artifacts.Count);
        Assert.AreEqual("/ui/tasks/4/artifacts?db=gen1", hub.Received.Last().Target);
        answer = Body("gen1", 4);
        Assert.AreEqual(0, (await client.TaskArtifactsAsync(hub.Address, "device-key-1", "gen1", 4)).Artifacts.Count);

        foreach (var (body, kind) in new[]
        {
            (Body("gen2", 4, a), OutputException.Problem.Identity),
            (Body("gen1", 5, a), OutputException.Problem.Identity),
            (Body("gen1", 4, a, a), OutputException.Problem.Metadata),
            (Body("gen1", 4, a, b with { Commit = new string('b', 40) }), OutputException.Problem.Metadata),
            (Body("gen1", 4, a with { Path = "outputs/a.exe" }), OutputException.Problem.Metadata),
            ("""{"db":"gen1","task":4}""", OutputException.Problem.Metadata),
            ("not json", OutputException.Problem.Metadata),
            ("[" + new string(' ', HubClient.ArtifactListLimit) + "]", OutputException.Problem.Size),
        })
        {
            answer = body;
            Assert.AreEqual(kind, Output(() => client.TaskArtifactsAsync(hub.Address, "device-key-1", "gen1", 4)).Kind, body[..Math.Min(60, body.Length)]);
        }
    }

    [TestMethod]
    public async Task TheHubsRefusalsHaveTheMacsWords()
    {
        (int, string) answer = (409, "");
        using var hub = new LoopbackHub(_ => LoopbackHub.Json(answer.Item1, answer.Item2));
        using var client = new HubClient();
        foreach (var (status, body, words) in new[]
        {
            (409, """{"error":"the requester has not accepted this result"}""", "The checked output list changed. Reload checked outputs."),
            (422, """{"error":"registered login text cannot be displayed"}""", "The hub blocked text that contains a registered login. Nothing was displayed or saved."),
            (413, """{"error":"  output is too large to display  "}""", "Hub refused the request (413): output is too large to display"),
            (503, "not json", "Hub refused the request (503): Unexpected HTTP response."),
            (500, """{"error":"%"}""".Replace("%", new string('w', 600)), "Hub refused the request (500): " + new string('w', 500)),
        })
        {
            answer = (status, body);
            Assert.AreEqual(words, Output(() => client.TaskArtifactsAsync(hub.Address, "device-key-1", "gen1", 4)).Message);
        }
        await Task.CompletedTask;
    }

    [TestMethod]
    public async Task AFileIsCheckedBeforeItShows()
    {
        var text = "Certificate of the example shop\nIssued 14 November 2026\n"u8.ToArray();
        var file = File("outputs/T-4/certificate.txt", text, "text/plain");
        byte[] body = text;
        var headers = new List<(string, string)>();
        void Answer(byte[] bytes, string type = "text/plain", string db = "gen1", string task = "4", string? commit = null, params (string, string)[] more)
        {
            body = bytes;
            headers = [("Content-Type", type), ("X-Fleet-DB", db), ("X-Fleet-Task", task), ("X-Fleet-Commit", commit ?? Commit), .. more];
        }
        using var hub = new LoopbackHub(_ => LoopbackHub.Raw(200, body, [.. headers]));
        using var client = new HubClient();

        Answer(text);
        var content = await client.TaskArtifactAsync(hub.Address, "device-key-1", "gen1", 4, file);
        Assert.AreEqual(Encoding.UTF8.GetString(text), content.Text);
        var seen = hub.Received.Last();
        Assert.AreEqual($"/ui/tasks/4/artifact?db=gen1&path=outputs%2FT-4%2Fcertificate.txt&commit={Commit}", seen.Target);
        Assert.AreEqual("text/plain", seen.Header("Accept"));
        StringAssert.Contains(seen.Header("Accept-Encoding"), "identity");
        Answer(text, "text/plain; charset=utf-8", commit: Commit.ToUpperInvariant());
        Assert.IsNotNull((await client.TaskArtifactAsync(hub.Address, "device-key-1", "gen1", 4, file)).Text, "a charset of UTF-8, a commit in capitals");

        var faults = new (Action Set, OutputException.Problem Kind)[]
        {
            (() => Answer(text, db: "gen2"), OutputException.Problem.Identity),
            (() => Answer(text, task: "5"), OutputException.Problem.Identity),
            (() => Answer(text, commit: new string('b', 40)), OutputException.Problem.Identity),
            (() => Answer(text, "image/png"), OutputException.Problem.Mime),
            (() => Answer(text, "text/plain; charset=iso-8859-1"), OutputException.Problem.Mime),
            (() => Answer(text, more: ("Content-Encoding", "br")), OutputException.Problem.Mime),
            (() => Answer(text[..^1]), OutputException.Problem.Size),
            (() => Answer([.. text, (byte)'x']), OutputException.Problem.Size),
            (() => Answer(text.Select(b => b == (byte)'C' ? (byte)'K' : b).ToArray()), OutputException.Problem.Checksum),
        };
        foreach (var (set, kind) in faults)
        {
            set();
            Assert.AreEqual(kind, Output(() => client.TaskArtifactAsync(hub.Address, "device-key-1", "gen1", 4, file)).Kind, kind.ToString());
        }

        var latin = new byte[] { 0x63, 0x61, 0x66, 0xE9 };
        Answer(latin);
        Assert.AreEqual("The output is not valid UTF-8 text.",
                        Output(() => client.TaskArtifactAsync(hub.Address, "device-key-1", "gen1", 4, File("outputs/T-4/a.txt", latin, "text/plain"))).Message);
        Answer([]);
        Assert.AreEqual("", (await client.TaskArtifactAsync(hub.Address, "device-key-1", "gen1", 4, File("outputs/T-4/empty.md", [], "text/plain"))).Text);
        Assert.AreEqual(OutputException.Problem.Metadata,
                        Output(() => client.TaskArtifactAsync(hub.Address, "device-key-1", "gen1", 4, file with { Path = "outputs/a.exe" })).Kind);

        var png = Png(1440, 900);
        Answer(png, "image/png");
        var picture = await client.TaskArtifactAsync(hub.Address, "device-key-1", "gen1", 4, File("outputs/T-4/shop-page.png", png, "image/png"));
        Assert.AreEqual((1440, 900, png.Length), (picture.Width, picture.Height, picture.Picture!.Length));
        var huge = Png(16_384, 2_442);
        Answer(huge, "image/png");
        Assert.AreEqual("The image cannot be displayed safely. Supported images are PNG or JPEG, up to 40 million pixels.",
                        Output(() => client.TaskArtifactAsync(hub.Address, "device-key-1", "gen1", 4, File("outputs/T-4/huge.png", huge, "image/png"))).Message);
    }

    [TestMethod]
    public void APicturesSizeComesFromItsHeader()
    {
        Assert.AreEqual((640, 400), PictureCheck.Size(Jpeg(640, 400), "image/jpeg"));
        Assert.AreEqual((3, 2), PictureCheck.Size(Png(3, 2), "image/png"));
        Assert.AreEqual((16_384, 2_441), PictureCheck.Size(Png(16_384, 2_441), "image/png"), "40,009,... is over; 2,441 rows are 39,993,344 pixels");
        Assert.IsNull(PictureCheck.Size(Png(16_384, 2_442), "image/png"), "over 40 million pixels");
        Assert.IsNull(PictureCheck.Size(Png(16_385, 1), "image/png"), "a side over 16,384");
        Assert.IsNull(PictureCheck.Size(Png(0, 10), "image/png"));
        Assert.IsNull(PictureCheck.Size(Png(3, 2), "image/jpeg"), "the bytes must be the type that the reference names");
        Assert.IsNull(PictureCheck.Size(Jpeg(640, 400), "image/png"));
        Assert.IsNull(PictureCheck.Size("not a picture"u8, "image/png"));
        Assert.IsNull(PictureCheck.Size(Jpeg(0, 400), "image/jpeg"));
    }

    /// <summary>Foundation's ByteCountFormatter with the file style, read on this Mac on 14 November 2026 (its decimal
    /// mark there is the Spanish comma; here the culture's own).</summary>
    [TestMethod]
    public void AFileSizeIsWrittenAsFoundationWritesIt()
    {
        var english = CultureInfo.GetCultureInfo("en-US");
        foreach (var (bytes, words) in new (long, string)[]
        {
            (0, "Zero KB"), (1, "1 byte"), (2, "2 bytes"), (149, "149 bytes"), (999, "999 bytes"), (1000, "1 KB"), (1499, "1 KB"),
            (1500, "2 KB"), (2500, "3 KB"), (4500, "5 KB"), (219_000, "219 KB"), (999_499, "999 KB"), (999_500, "1 MB"),
            (1_000_000, "1 MB"), (1_049_999, "1 MB"), (1_050_000, "1.1 MB"), (1_150_000, "1.2 MB"), (1_250_000, "1.3 MB"),
            (1_234_567, "1.2 MB"), (8_250_000, "8.3 MB"), (8_388_608, "8.4 MB"), (99_950_000, "100 MB"), (120_000_000, "120 MB"),
            (999_949_999, "999.9 MB"), (999_950_000, "1 GB"), (1_200_000_000, "1.2 GB"), (1_234_567_890, "1.23 GB"),
        })
            Assert.AreEqual(words, FileSize.Words(bytes, english), bytes.ToString(CultureInfo.InvariantCulture));
        Assert.AreEqual("1,2 MB", FileSize.Words(1_234_567, CultureInfo.GetCultureInfo("es-ES")), "the Mac's own line");
        Assert.AreEqual("Verified download · 149 bytes", OutputWords.VerifiedDownload(149));
    }

    // ---------------------------------------------------------------- the checked outputs: the model and the store

    private static StoreState Accepted(OutputsState? outputs, DateTimeOffset now, bool fresh = true)
    {
        var task = HubDecode.TaskPage(Encoding.UTF8.GetBytes(new JsonObject
        {
            ["db"] = "gen1", ["cursor"] = 1, ["notes"] = new JsonArray(), ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
            ["task"] = new JsonObject
            {
                ["id"] = 4, ["title"] = "Renew the shop's certificate", ["details"] = "Renew it.", ["done_when"] = "it serves",
                ["needs"] = "none", ["goal"] = null, ["owner"] = "pax", ["requester"] = "manager", ["state"] = "completed", ["created"] = Now - 9000,
                ["attempt"] = 1, ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0, ["delivered"] = Now - 3600,
                ["accepted"] = 1, ["where_"] = "outputs/T-4/certificate.txt",
            },
        }.ToJsonString()), "gen1", 4).Task;
        var s = State(Decode(Snapshot()), fresh ? now : now - TimeSpan.FromMinutes(5));
        return s with { OpenTask = 4, Outputs = outputs, TaskPages = s.TaskPages.SetItem(4, new TaskPageState { Task = task }) };
    }

    private static CheckedOutputsModel OutputsOf(StoreState s) => Screens.Task(s, 4, Clock, Utc)!.Result!.Outputs!;

    [TestMethod]
    public void TheOutputsSectionShowsTheMacsStates()
    {
        var text = File("outputs/T-4/certificate.txt", "a\nb\nc\nd"u8.ToArray(), "text/plain");
        var picture = File("outputs/T-4/shop-page.png", Png(3, 2), "image/png");

        var start = OutputsOf(Accepted(null, Clock));
        Assert.AreEqual(("Checked outputs", "View outputs", true, null, null, null, 0), (start.Heading, start.ViewWords, start.Enabled,
                        start.ConnectionWords, start.Loading, start.NoFilesWords, start.Files.Count));

        var loading = OutputsOf(Accepted(new OutputsState { Task = 4, Loading = OutputWords.LoadingList }, Clock));
        Assert.AreEqual(("Loading checked outputs…", "Cancel", false), (loading.Loading, loading.CancelWords, loading.Enabled));

        var none = OutputsOf(Accepted(new OutputsState { Task = 4, Listed = true }, Clock));
        Assert.AreEqual(("Reload outputs", "No supported output files are listed for this checked task."), (none.ViewWords, none.NoFilesWords));

        var listed = OutputsOf(Accepted(new OutputsState { Task = 4, Listed = true, Files = ValueList.Of(new[] { text, picture }) }, Clock));
        Assert.IsNull(listed.NoFilesWords);
        Assert.AreEqual(("outputs/T-4/certificate.txt", false, "View", "View outputs/T-4/certificate.txt", true),
                        (listed.Files[0].Path, listed.Files[0].IsImage, listed.Files[0].ViewWords, listed.Files[0].ViewName, listed.Files[0].Enabled));
        Assert.IsTrue(listed.Files[1].IsImage);

        var opened = OutputsOf(Accepted(new OutputsState
        {
            Task = 4, Listed = true, Files = ValueList.Of(new[] { text }), Opened = new ArtifactContent(text, "a\nb\nc\nd", null),
        }, Clock)).Opened!;
        Assert.AreEqual(("outputs/T-4/certificate.txt", "Close", false, 88.0, "Verified download · 7 bytes", null),
                        (opened.Path, opened.CloseWords, opened.EmptyText, opened.TextHeight, opened.Download, opened.PictureName));
        CollectionAssert.AreEqual(new[] { ("Snapshot commit", Commit), ("SHA-256", text.Sha256), ("Type", "text/plain") },
                                  opened.Facts.Select(f => (f.Label, f.Value)).ToArray());
        var tall = OutputsOf(Accepted(new OutputsState { Task = 4, Opened = new ArtifactContent(text, new string('\n', 40), null) }, Clock)).Opened!;
        Assert.AreEqual(320.0, tall.TextHeight, "18 lines at most: 18 × 18 + 16 is over 320");
        var small = OutputsOf(Accepted(new OutputsState { Task = 4, Opened = new ArtifactContent(text, "one line", null) }, Clock)).Opened!;
        Assert.AreEqual(80.0, small.TextHeight);
        var empty = OutputsOf(Accepted(new OutputsState { Task = 4, Opened = new ArtifactContent(text with { Bytes = 0 }, "", null) }, Clock)).Opened!;
        Assert.AreEqual((true, "Empty text file", "Verified download · Zero KB"), (empty.EmptyText, empty.EmptyWords, empty.Download));
        var image = OutputsOf(Accepted(new OutputsState { Task = 4, Opened = new ArtifactContent(picture, null, Png(3, 2), 3, 2) }, Clock)).Opened!;
        Assert.AreEqual(("Verified image: outputs/T-4/shop-page.png", 3, 2, 340.0, 2048), (image.PictureName, image.Width, image.Height,
                        image.PictureMaxHeight, image.ThumbnailMost));

        var refused = OutputsOf(Accepted(new OutputsState { Task = 4, Error = OutputException.Words(OutputException.Problem.Stale) }, Clock));
        Assert.AreEqual(("The checked output list changed. Reload checked outputs.", "View outputs"), (refused.Error, refused.ViewWords));

        var old = OutputsOf(Accepted(new OutputsState { Task = 4, Listed = true, Files = ValueList.Of(new[] { text }) }, Clock, fresh: false));
        Assert.AreEqual(("Connection required. Reload outputs after the hub reconnects.", "Output discarded because the hub state is stale.", 0, false),
                        (old.ConnectionWords, old.Error, old.Files.Count, old.Enabled));
        Assert.AreEqual(0, OutputsOf(Accepted(new OutputsState { Task = 9, Listed = true, Files = ValueList.Of(new[] { text }) }, Clock)).Files.Count,
                        "what the store holds for another task is not this one's");
    }

    // ---------------------------------------------------------------- the steps of a task

    private static TaskEvent Call(long id, double? ts, string call, string? title, string? kind, string status, string? parent = null,
                                  IReadOnlyList<FileChange>? changes = null, string? output = null) =>
        new(id, 1, "s1", id, ts, "tool_call", ToolCallId: call, Title: title, Kind: kind, Status: status, Parent: parent, Changes: changes, Output: output);

    private static TaskEvent Update(long id, double? ts, string call, string status, string? output = null, IReadOnlyList<FileChange>? changes = null) =>
        new(id, 1, "s1", id, ts, "tool_call_update", ToolCallId: call, Status: status, Output: output, Changes: changes);

    private static TaskEvent Said(long id, double? ts, string type, string? text = null) => new(id, 1, "s1", id, ts, type, Text: text);

    [TestMethod]
    public void TheRecordMergesUpdatesAndKeepsItsProvidersAndFiles()
    {
        var timeline = ActivityTimeline.Of([
            new TaskEvent(1, 1, "s1", 1, 10, "session", Runtime: "claude"),
            new TaskEvent(2, 1, "s2", 1, 10, "session", Runtime: "codex", Parent: "call-x"),
            new TaskEvent(3, 2, "s3", 1, 10, "session", Runtime: "codex"),
            new TaskEvent(4, 1, "s1", 2, 11, "plan", Entries: [new PlanEntry("Read", "pending")]),
            Call(5, 12, "c1", "Edit a.py", "edit", "in_progress", changes: [new FileChange("a.py", "modify", 4, 1)]),
            Update(6, 13, "c1", "completed", "Edited."),
            Call(7, 14, "c2", "Edit a.py", "edit", "completed", changes: [new FileChange("a.py", "modify", 9, 9)]),
            Call(8, 15, "c3", "Write b.py", "edit", "failed", changes: [new FileChange("b.py", "add", 3)]),
            Update(9, 16, "nobody", "completed"),
        ]);
        CollectionAssert.AreEqual(new[] { "claude" }, timeline.Runtimes[1].ToArray(), "a child's session names no provider of the attempt");
        CollectionAssert.AreEqual(new[] { "codex" }, timeline.Runtimes[2].ToArray());
        Assert.AreEqual(3, timeline.Rows.Count, "the plan of the top level is not a row, an update of no call is nothing");
        Assert.AreEqual(("completed", "Edited.", 6L), (timeline.Rows[0].Status, timeline.Rows[0].Output, timeline.Rows[0].LastEventId));
        var file = timeline.ChangedFiles.Single();
        Assert.AreEqual(("a.py", 9L), (file.Path, file.Added), "the latest completed report of each path; a failed one is none");
    }

    [TestMethod]
    public void TheThreadIsTheMacs()
    {
        var timeline = ActivityTimeline.Of([
            Call(1, 10, "c1", "Fetch https://help.example.com", "fetch", "completed"),
            Said(2, 11, "agent_thought", "Thinking about it."),
            Call(3, 12, "c2", "fleet: report_progress", "other", "completed"),
            Call(4, 13, "c3", "fleet: sign_in", "other", "failed"),
            Said(5, 20, "agent_message", "I answered 23 tickets today."),
            Said(6, 21, "error", null),
            Call(7, 30, "c4", "Read notes.md", "read", "completed"),
            Call(8, 31, "c5", "python3 make.py", "execute", "in_progress"),
            Call(9, 32, "c6", "Search tickets", "search", "completed", parent: "c9"),
        ]);
        var notes = new[] { new ProgressNote(70, 4, "wren", 25, "Halfway.") };
        var permissions = new[]
        {
            new TaskPermission(1, "Bash", "curl -s -X POST https://help.example.com/api/tickets/10517/reply", 35),
            new TaskPermission(2, "Write", "replies/1.json", 12.5, "deny", "Not that folder."),
            new TaskPermission(3, "Read", "notes.md", 14, "allow", "Fine."),
        };
        var steers = new[] { new TaskSteer(3, 4, 1, "Look at the logs first.", 22, "r-1", "founderizer-windows/1") };
        var thread = ThreadEntry.Of(timeline.TopRows, notes, permissions, steers);
        string Kind(ThreadEntry e) => e.Steps is { } s ? "steps:" + string.Join(",", s.Select(r => r.Id)) : e.Said is { } m ? "said:" + m.Id
            : e.Note is { } n ? "note:" + n.Id : e.Steer is { } g ? "steer:" + g.Id : "permission:" + e.Permission!.Id;
        CollectionAssert.AreEqual(new[] { "steps:1,2", "permission:2", "steps:4", "said:5", "said:6", "steer:3", "note:70", "steps:7,8", "permission:1" },
                                  thread.Select(Kind).ToArray(),
                                  "a thought is a step of its run; an error stands alone; Fleet's own tool is not a step, its sign-in is; a child's row is not here");

        var task = HubDecode.TaskPage(Encoding.UTF8.GetBytes(new JsonObject
        {
            ["db"] = "gen1", ["cursor"] = 1, ["notes"] = new JsonArray(), ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
            ["task"] = new JsonObject
            {
                ["id"] = 4, ["title"] = "Answer today's support tickets", ["details"] = "Answer them.", ["done_when"] = "all answered",
                ["needs"] = "none", ["goal"] = null, ["owner"] = "wren", ["requester"] = "manager", ["state"] = "working", ["created"] = Now - 9000,
                ["attempt"] = 1, ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0,
            },
        }.ToJsonString()), "gen1", 4).Task;
        var thinking = Screens.Steps(thread[0].Steps!, task, null);
        Assert.AreEqual(("2 steps", ""), (thinking.Title, thinking.Status));
        Assert.AreEqual((ActivityRowKind.Thought, "Thinking", StepSymbol.Thought, "Thinking about it."),
                        (thinking.Rows[1].Kind, thinking.Rows[1].Title, thinking.Rows[1].Symbol, thinking.Rows[1].Text));
        var running = Screens.Steps(thread[7].Steps!, task, null);
        Assert.AreEqual(("python3 make.py", "Step 2 · Running", false, StepSymbol.Execute), (running.Title, running.Status, running.Orange, running.Symbol));
        Assert.AreEqual(("Read notes.md", "Done", StepSymbol.Read), (running.Rows[0].Title, running.Rows[0].Status, running.Rows[0].Symbol));
        Assert.AreEqual(("Running", false), (running.Rows[1].Status, running.Rows[1].Orange));
        var failed = Screens.Steps(thread[2].Steps!, task, null);
        Assert.AreEqual(("1 step", "1 failed", true, StepSymbol.Steps), (failed.Title, failed.Status, failed.Orange, failed.Symbol));
        Assert.AreEqual(("Sign In", "Failed", true), (failed.Rows[0].Title, failed.Rows[0].Status, failed.Rows[0].Orange));
        var later = Screens.Steps(thread[7].Steps!, task with { Attempt = 2 }, null);
        Assert.AreEqual(("2 steps", "", "Result unknown"), (later.Title, later.Status, later.Rows[1].Status), "a call of an attempt that is over");
        Assert.AreEqual("Result unknown", Screens.Steps(thread[7].Steps!, task, stopped: 1).Rows[1].Status, "the attempt that a stop ended");
    }

    [TestMethod]
    public void ACompletedScriptFoldsIntoItsFirstCallAsTheMacFoldsIt()
    {
        TaskEvent Script(long id, string call) => Call(id, id, call, "exec: python3 run.py", "execute", "in_progress");
        var events = new List<TaskEvent>
        {
            Script(1, "x1"), Call(2, 2, "a", "Read a.txt", "read", "completed"), Call(3, 3, "b", "Read b.txt", "read", "completed"),
            Update(4, 4, "x1", "completed", "Script completed with 2 calls"),
            Script(5, "x2"), Call(6, 6, "c", "Read c.txt", "read", "completed"), Update(7, 7, "x2", "failed", "Exit 1"),
        };
        var timeline = ActivityTimeline.Of(events);
        var shown = timeline.TopRows;
        CollectionAssert.AreEqual(new long[] { 1, 3, 5, 6 }, shown.Select(r => r.Id).ToArray());
        Assert.AreEqual(("Read a.txt", "exec: python3 run.py"), (shown[0].Row.Event.Title, shown[0].Script!.Event.Title));
        Assert.AreEqual("Run tools", StepWords.ToolTitle(shown[2].Row.Event.Title), "a failed script stays a row of its own");

        // A script on screen with one of its calls when a page came stays a row, so that no row goes away.
        var kept = new ActivityTimeline();
        kept.Append(events.Take(2));
        kept.Append(events.Skip(2));
        Assert.IsTrue(kept.KeptScripts.Contains(1));
        CollectionAssert.AreEqual(new long[] { 1, 2, 3, 5, 6 }, kept.TopRows.Select(r => r.Id).ToArray());
    }

    [TestMethod]
    public void TheStepWordsAreTheMacs()
    {
        Assert.AreEqual(("1 step", "8 steps", "1 failed", "3 failed", "Running", "Step 8 · Running"),
                        (StepWords.Count(1), StepWords.Count(8), StepWords.Failed(1), StepWords.Failed(3), StepWords.Running(1), StepWords.Running(8)));
        Assert.AreEqual(("Tool", "Run tools", "Hand Over", "Read a.txt"),
                        (StepWords.ToolTitle(null), StepWords.ToolTitle("exec: ls"), StepWords.ToolTitle("fleet: hand_over"), StepWords.ToolTitle("Read a.txt")));
        Assert.AreEqual(("Done", "Failed", "Running", "Waiting", "Waiting"),
                        (StepWords.ToolStatus("completed"), StepWords.ToolStatus("failed"), StepWords.ToolStatus("in_progress"),
                         StepWords.ToolStatus("pending"), StepWords.ToolStatus(null)));
        CollectionAssert.AreEqual(new[] { StepSymbol.Read, StepSymbol.Search, StepSymbol.Edit, StepSymbol.Edit, StepSymbol.Edit, StepSymbol.Execute, StepSymbol.Fetch, StepSymbol.Other, StepSymbol.Other },
                                  new[] { "read", "search", "edit", "move", "delete", "execute", "fetch", "think", null }.Select(StepWords.Symbol).ToArray());
        Assert.AreEqual(("Modify", "+4", "−1"), (StepWords.Action("modify"), StepWords.Added(4), StepWords.Removed(1)));
    }

    [TestMethod]
    public void AnEventsPageKeepsItsRules()
    {
        TaskEventPage Page(long next, bool more, params long[] ids) =>
            new("gen1", 4, ids.Select(id => Said(id, id, "agent_message", "x")).ToList(), next, more);
        Assert.IsTrue(Page(12, false, 11, 12).IsValid("gen1", 4, 10));
        Assert.IsTrue(Page(10, false).IsValid("gen1", 4, 10), "no events: next is the cursor");
        Assert.IsTrue(Page(12, true, 11, 12).IsValid("gen1", 4, 10));
        Assert.IsFalse(Page(12, false, 11, 12).IsValid("gen2", 4, 10));
        Assert.IsFalse(Page(12, false, 11, 12).IsValid("gen1", 5, 10));
        Assert.IsFalse(Page(12, false, 12, 11).IsValid("gen1", 4, 10), "in id order");
        Assert.IsFalse(Page(11, false, 11, 11).IsValid("gen1", 4, 10), "each id once");
        Assert.IsFalse(Page(12, false, 10, 12).IsValid("gen1", 4, 10), "after the cursor");
        Assert.IsFalse(Page(11, false, 11, 12).IsValid("gen1", 4, 10), "next is the last id");
        Assert.IsFalse(Page(10, true).IsValid("gen1", 4, 10), "more needs events");
        Assert.IsFalse((Page(11, false, 11) with { Events = [Said(11, 11, "agent_message") with { Attempt = 0 }] }).IsValid("gen1", 4, 10));
    }

    [TestMethod]
    public void ThePageWaitsForItsRecordThenDrawsItsStepsAndPanel()
    {
        var fleet = Decode(Snapshot()) with { UiFeatures = ["mobile", "thread_events", "task_controls", "task_steering"] };
        var task = HubDecode.TaskPage(Encoding.UTF8.GetBytes(new JsonObject
        {
            ["db"] = "gen1", ["cursor"] = 1, ["notes"] = new JsonArray(), ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
            ["task"] = new JsonObject
            {
                ["id"] = 7, ["title"] = "Answer today's support tickets", ["details"] = "Answer them.", ["done_when"] = "all answered",
                ["needs"] = "none", ["goal"] = null, ["owner"] = "wren", ["requester"] = "manager", ["state"] = "input-required", ["created"] = Now - 9000,
                ["attempt"] = 2, ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0, ["last_activity"] = Now - 60,
            },
        }.ToJsonString()), "gen1", 7).Task;
        var page = new TaskPageState
        {
            Task = task,
            Permissions = ValueList.Of(new[] { new TaskPermission(1, "Bash", "curl -s https://help.example.com", Now - 30) }),
        };
        var s = State(fleet, Clock);
        s = s with { TaskPages = s.TaskPages.SetItem(7, page) };
        Assert.IsNull(Screens.Task(s, 7, Clock, Utc), "on a current reading the page waits for its record");
        var old = State(fleet, Clock - TimeSpan.FromMinutes(5));
        Assert.IsNotNull(Screens.Task(old with { TaskPages = s.TaskPages }, 7, Clock, Utc), "an old reading draws what it has");

        var timeline = ActivityTimeline.Of([
            new TaskEvent(1, 1, "s0", 1, Now - 900, "session", Runtime: "codex"),
            new TaskEvent(2, 2, "s1", 1, Now - 600, "session", Runtime: "grok"),
            new TaskEvent(3, 2, "s2", 1, Now - 600, "session", Runtime: "claude"),
            Call(4, Now - 500, "c1", "Edit replies/make_reply.py", "edit", "completed", changes: [new FileChange("replies/make_reply.py", "modify", 4, 1)]),
            Said(5, Now - 400, "agent_message", "I answered 23 tickets today."),
        ]);
        s = s with { TaskPages = s.TaskPages.SetItem(7, page with { Activity = TaskActivity.Of(timeline, 5) }) };
        var model = Screens.Task(s, 7, Clock, Utc)!;
        CollectionAssert.AreEqual(new[] { ThreadRowKind.Steps, ThreadRowKind.Message, ThreadRowKind.Permission }, model.Thread.Select(r => r.Kind).ToArray());
        Assert.AreEqual(("steps-4", "1 step"), (model.Thread[0].Key, model.Thread[0].Steps!.Title));
        Assert.AreEqual(("event-5", "I answered 23 tickets today."), (model.Thread[1].Key, model.Thread[1].Words!.Text));
        Assert.AreEqual(new PermissionRowModel("Bash", "Waiting", "curl -s https://help.example.com", null), model.Thread[2].Permission);
        var labels = model.Facts.Select(f => f.Label).ToList();
        Assert.AreEqual(labels.IndexOf("Attempt") + 1, labels.IndexOf("AI provider"));
        Assert.AreEqual(labels.IndexOf("AI provider") + 1, labels.IndexOf("Last activity"));
        Assert.AreEqual("Claude Code, Grok Build", model.Facts.Single(f => f.Label == "AI provider").Value, "the attempt now's, by raw name");
        Assert.AreEqual(("Changed files", "Latest completed tool report per file."), (model.ChangedFiles!.Heading, model.ChangedFiles.Footer));
        Assert.AreEqual(new ChangedFileRow("replies/make_reply.py", "Modify", "+4", "−1"), model.ChangedFiles.Rows.Single());
        Assert.IsTrue(model.Notes.Count == 0);

        var decided = page with { Permissions = ValueList.Of(new[] { new TaskPermission(1, "Bash", "ls", Now - 30, "deny", "Not now.") }) };
        var refusal = Screens.Task(s with { TaskPages = s.TaskPages.SetItem(7, decided with { Activity = TaskActivity.Of(new ActivityTimeline(), 0) }) }, 7, Clock, Utc)!;
        Assert.AreEqual(new PermissionRowModel("Bash", "deny", "ls", "Not now."), refusal.Thread.Single().Permission, "the Mac writes the decision as it is");
        Assert.IsNull(refusal.ChangedFiles);
        Assert.IsFalse(refusal.Facts.Any(f => f.Label == "AI provider"));
    }

    // ---------------------------------------------------------------- a parked task

    [TestMethod]
    public void AParkedTaskWaitsUntilItsTimeAsTheMacSaysIt()
    {
        var snapshot = Snapshot();
        var heads = snapshot["tasks"]!.AsArray();
        var parked = Head(31, "Answer today's support tickets", "wren", "working", Now - 60, works: false);
        parked["parked_until"] = Now + 3 * 3600;
        heads.Add(parked);
        var fleet = Decode(snapshot);
        var head = fleet.Tasks.Single(t => t.Id == 31);
        Assert.AreEqual(ActivityColumn.Waiting, head.Column(held: false));
        Assert.AreEqual(ActivityColumn.InProgress, (head with { ParkedUntil = null }).Column(held: false));
        var s = State(fleet, Clock);
        var card = Screens.Board(s, ActivityPeriod.All, null, Clock, Utc).Lanes.Single(l => l.Column == ActivityColumn.Waiting).Cards.Single(c => c.Id == 31);
        Assert.AreEqual("Until " + Screens.ComingTime(Now + 3 * 3600, s.HubNow(Clock), Utc), card.Why);
        Assert.IsNull(card.OwnerLine);
        Assert.IsFalse(TaskMark.Of(head with { Works = true }, [], s.Names, limited: false).InWork, "a parked task is no work now");

        var held = Screens.Parked(s, fleet with { Holds = [new TaskHold(1, 31, "pause", "stopped", 1)] }, head, Clock, Utc);
        Assert.IsNull(held, "a hold of the owner's says its own word");
        var limited = fleet with { Agents = [.. fleet.Agents.Select(a => a.Name == "wren" ? a with { Limit = new RuntimeLimit(Now - 60, Now + 600, true) } : a)] };
        Assert.IsNull(Screens.Parked(s, limited, head, Clock, Utc), "a usage limit says its own word");

        // A hub with task_limit (owner API 1.330; the owner, 24 November 2026: an agent's usage was wrong): a task's own
        // `limit` alone holds it, and its agent's `limit` (the hold of the agent's own route) holds none of the tasks
        // whose own `limit` is null. Without the feature the agent's `limit` decides, as before. Fails when the rule
        // reads the agent's `limit` on every hub: a desktop task that a hold of the screen route keeps waiting said
        // "Working" for days.
        var hold = new RuntimeLimit(Now - 60, Now + 600, true);
        var served = limited with { UiFeatures = [.. fleet.UiFeatures ?? [], TaskLimit.Feature] };
        Assert.IsNotNull(Screens.Parked(s, served, head, Clock, Utc), "its agent's own route alone holds no task of it");
        Assert.AreEqual("Working", TaskWords.State(head, served, s.Names));
        var own = head with { Limit = hold };
        var screen = served with { Agents = fleet.Agents, Tasks = [.. fleet.Tasks.Select(t => t.Id == 31 ? own with { ParkedUntil = null } : t)] };
        Assert.IsNull(Screens.Parked(s, served with { Agents = fleet.Agents }, own, Clock, Utc), "its own hold says its own word");
        Assert.AreEqual("Usage limit", TaskWords.State(own, screen, s.Names));
        Assert.AreEqual(TaskSymbol.Limit, TaskMark.Of(own, [], s.Names, TaskLimit.Of(screen, own) is not null).Symbol);
        CollectionAssert.Contains(Activity.Lanes(screen, null, ActivityPeriod.All, Utc)[ActivityColumn.Waiting].Select(t => t.Id).ToList(), 31L);
        var free = served with { Tasks = [.. fleet.Tasks.Select(t => t.Id == 31 ? head with { ParkedUntil = null } : t)] };
        CollectionAssert.Contains(Activity.Lanes(free, null, ActivityPeriod.All, Utc)[ActivityColumn.InProgress].Select(t => t.Id).ToList(), 31L);
        // An older hub sends no task `limit`: there a head's own hold alone says nothing.
        Assert.AreEqual("Working", TaskWords.State(own, fleet, s.Names));
        Assert.IsNotNull(Screens.Parked(s, fleet, own, Clock, Utc));

        // The hub's own JSON gives the hold, on a head and on the task of its page ({since, until, reset_known}), and the
        // page's limit line is the task's: it says the task's own hold while its agent has none, and nothing for an
        // agent's hold that the task does not have.
        static JsonObject Limit() => new() { ["since"] = Now - 60, ["until"] = Now + 600, ["reset_known"] = true };
        parked["limit"] = Limit();
        Assert.AreEqual(hold, Decode(snapshot).Tasks.Single(t => t.Id == 31).Limit);
        var json = TaskPageJson(31, "working", accepted: null);
        json["task"]!["limit"] = Limit();
        var task = HubDecode.TaskPage(Encoding.UTF8.GetBytes(json.ToJsonString()), "gen1", 31).Task;
        Assert.AreEqual(hold, task.Limit);
        StoreState WithPage(MobileSnapshot reading, FleetTask of)
        {
            var state = State(reading, Clock);
            return state with { TaskPages = state.TaskPages.SetItem(31, new TaskPageState { Task = of }) };
        }
        // The line says what holds the task (his complaint of 24 November 2026: "Wren is at its usage limit" while Wren
        // chatted and worked): its own hold, which a hold of the agent's screen route gives, in the agent panel's words,
        // and no line when the reset's time is not known; the agent's sentence only where the agent's own route is held.
        var until = "Usage limit until " + Screens.ComingTime(Now + 600, State(screen, Clock).HubNow(Clock), Utc);
        var line = Screens.Task(WithPage(screen, task), 31, Clock, Utc)!.LimitWords;
        Assert.AreEqual(until, line, "its own hold");
        StringAssert.DoesNotMatch(line!, new System.Text.RegularExpressions.Regex("Wren|is at its usage limit"));
        Assert.IsNull(Screens.Task(WithPage(screen, task with { Limit = hold with { ResetKnown = false } }), 31, Clock, Utc)!.LimitWords,
                      "its own hold, with no known reset: the state word alone");
        Assert.IsNull(Screens.Task(WithPage(served, task with { Limit = null }), 31, Clock, Utc)!.LimitWords, "its agent's hold alone");
        StringAssert.StartsWith(Screens.Task(WithPage(served, task), 31, Clock, Utc)!.LimitWords, "Wren is at its usage limit until ",
                                "its agent's own route holds it");
        StringAssert.StartsWith(Screens.Task(WithPage(limited, task with { Limit = null }), 31, Clock, Utc)!.LimitWords,
                                "Wren is at its usage limit until ", "an older hub: its agent's");
        // The other marks of the task read the same rule: its Search row and the mark of an answered card on it.
        var marks = screen with { UiFeatures = [.. screen.UiFeatures ?? [], AnswerMark.Feature] };
        Assert.AreEqual(TaskSymbol.Limit, Screens.Search(State(marks, Clock), "", 0, Clock).Tasks.Single(t => t.Id == 31).Mark.Symbol);
        var asked = new OwnerNeed(5, "Which tickets first?", "", "", Now - 300, "wren", Answer: "The oldest", Answered: Now - 200, Task: 31);
        Assert.AreEqual(TaskSymbol.Limit, AnswerMark.Of(asked, marks, marks.Tasks, s.Names).Row);
        var free31 = marks with { Tasks = [.. marks.Tasks.Select(t => t.Id == 31 ? t with { Limit = null } : t)], Agents = limited.Agents };
        Assert.AreNotEqual(TaskSymbol.Limit, Screens.Search(State(free31, Clock), "", 0, Clock).Tasks.Single(t => t.Id == 31).Mark.Symbol,
                           "its agent's own route alone holds no task of it");
        Assert.AreNotEqual(TaskSymbol.Limit, AnswerMark.Of(asked, free31, free31.Tasks, s.Names).Row);
    }

    // ---------------------------------------------------------------- the store

    [TestMethod]
    public async Task TheStoreReadsTheOpenTasksRecordAndItsOutputs()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-fourth-").FullName;
        using var hub = new FakeHub();
        try
        {
            hub.Snapshot["ui_features"]!.AsArray().Add((JsonNode)"thread_events");
            var task = TaskPageJson(7, "working", accepted: null);
            task["permissions"] = new JsonArray(new JsonObject { ["id"] = 1, ["tool"] = "Bash", ["input"] = "ls", ["created"] = Now - 30, ["decision"] = null, ["reason"] = null });
            hub.Tasks[7] = task;
            hub.EventPage = 2;
            hub.Events[7] = [Event(1, "session", j => j["runtime"] = "claude"), Event(2, "tool_call", ToolCall("c1", "completed")),
                             Event(3, "tool_call", ToolCall("c2", "failed")), Event(4, "agent_message", j => j["text"] = "Done for today.")];
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
            await Until(() => store.State.TaskPages.TryGetValue(7, out var p) && p.Activity is not null);
            var page = store.State.TaskPages[7];
            Assert.AreEqual((4L, 3), (page.Activity!.Cursor, page.Activity.TopRows.Count), "the first read keeps all of its pages at once");
            Assert.AreEqual("Bash", page.Permissions.Single().Tool);
            var model = Screens.Task(store.State, 7, clock.Now, Utc)!;
            Assert.AreEqual("2 steps", model.Thread[0].Steps!.Title);

            lock (hub.Events) hub.Events[7].Add(Event(5, "tool_call", ToolCall("c3", "in_progress")));
            var reads = hub.EventReads;
            await ThreadAsTheMacTests.Ticking(clock, () => store.State.TaskPages[7].Activity!.Cursor == 5, "a later read");
            Assert.IsTrue(hub.Server.Received.Any(r => r.Target == "/ui/tasks/7/events?db=gen1&after=4&limit=200"), "a later read asks for 200");
            Assert.IsTrue(hub.EventReads > reads);

            // The checked outputs of an accepted result.
            var text = "Certificate of the example shop\n"u8.ToArray();
            hub.Tasks[8] = TaskPageJson(8, "completed", accepted: 1);
            hub.Artifacts[8] = [("outputs/T-8/certificate.txt", "text/plain", text), ("outputs/T-8/dot.png", "image/png", Png(3, 2))];
            store.OpenTask(8);
            Assert.AreEqual(5L, store.State.TaskPages[7].Activity!.Cursor, "another task's record stays");
            await store.RefreshAsync();
            await Until(() => store.State.TaskPages.TryGetValue(8, out var p) && p.Activity is not null);
            await store.ListOutputsAsync();
            Assert.AreEqual((true, 2, null), (store.State.Outputs!.Listed, store.State.Outputs.Files.Count, store.State.Outputs.Loading));
            await store.ViewOutputAsync(store.State.Outputs.Files[0]);
            Assert.AreEqual("Certificate of the example shop\n", store.State.Outputs!.Opened!.Text);
            Assert.AreEqual(2, store.State.Outputs.Files.Count, "the list stays under the file");
            await store.ViewOutputAsync(store.State.Outputs.Files[1]);
            Assert.AreEqual((3, 2), (store.State.Outputs!.Opened!.Width, store.State.Outputs.Opened.Height));

            hub.RefuseArtifact = (409, """{"error":"output revision changed; reload the output list"}""");
            await store.ViewOutputAsync(store.State.Outputs.Files[0]);
            Assert.AreEqual(("The checked output list changed. Reload checked outputs.", false, 0, null),
                            (store.State.Outputs!.Error, store.State.Outputs.Listed, store.State.Outputs.Files.Count, store.State.Outputs.Opened));
            hub.RefuseArtifact = null;
            await store.ListOutputsAsync();
            store.CloseOutputs();
            Assert.IsNull(store.State.Outputs, "Close and Cancel clear the section");
            await store.ListOutputsAsync();
            store.OpenTask(7);
            Assert.IsNull(store.State.Outputs, "another task's page clears them");

            store.OpenTask(8);
            await store.ListOutputsAsync();
            clock.Advance(StoreState.CurrentFor + TimeSpan.FromSeconds(1));
            await Until(() => store.State.Outputs?.Error is not null);
            Assert.AreEqual(("Output discarded because the hub state is stale.", 0), (store.State.Outputs!.Error, store.State.Outputs.Files.Count));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    private static async Task Until(Func<bool> done)
    {
        for (var i = 0; i < 200 && !done(); i++) await Task.Delay(25);
        Assert.IsTrue(done(), "the store did not get there");
    }

    private static Action<JsonObject> ToolCall(string call, string status) => j =>
    {
        j["tool_call_id"] = call; j["title"] = "Read " + call; j["kind"] = "read"; j["status"] = status;
    };

    private static JsonObject Event(long id, string type, Action<JsonObject>? more = null)
    {
        var e = new JsonObject { ["id"] = id, ["attempt"] = 1, ["session"] = "s1", ["seq"] = id, ["ts"] = Now - 100 + id, ["type"] = type };
        more?.Invoke(e);
        return e;
    }

    private static JsonObject TaskPageJson(long id, string state, long? accepted) => new()
    {
        ["db"] = "gen1", ["cursor"] = 1, ["notes"] = new JsonArray(), ["holds"] = new JsonArray(), ["outcomes"] = new JsonArray(),
        ["task"] = new JsonObject
        {
            ["id"] = id, ["title"] = "Example task " + id, ["details"] = "Do it.", ["done_when"] = "done", ["needs"] = "none", ["goal"] = null,
            ["owner"] = "wren", ["requester"] = "manager", ["state"] = state, ["created"] = Now - 9000, ["attempt"] = 1,
            ["restarts"] = 0, ["nudge_level"] = 0, ["stop_sent"] = 0, ["accepted"] = accepted,
            ["delivered"] = state == "completed" ? Now - 600 : null, ["where_"] = state == "completed" ? "outputs/T-8/certificate.txt" : null,
        },
    };
}
