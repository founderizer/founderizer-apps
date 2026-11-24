using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;

namespace Founderizer.Core.Tests;

/// <summary>A fleet like the pictures' sample (ios/Sources/SampleFleetData.swift): five agents, two open requests, open
/// and ended tasks, at a clock of 15:12 UTC on 13 November 2026. Example names only.</summary>
internal static class SampleFleet
{
    public const double Now = 1_794_582_720;        // 13 November 2026, 15:12 UTC

    public static JsonObject Agent(string name, string role, string? title, string runtime = "claude", double? lastSeen = Now - 5,
                                   JsonObject? last = null, string? machine = null) => new()
    {
        ["name"] = name, ["role"] = role, ["title"] = title, ["runtime"] = runtime, ["active"] = true,
        ["direct_chat"] = true, ["last_seen"] = lastSeen, ["open_tasks"] = 0, ["usage"] = new JsonArray(),
        ["last"] = last, ["machine"] = machine,
    };

    public static JsonObject Preview(double ts, string side, string text) => new() { ["ts"] = ts, ["side"] = side, ["preview"] = text };

    public static JsonObject Need(long id, string title, string why, string by, double raised, params string[] options) => new()
    {
        ["id"] = id, ["title"] = title, ["why"] = why, ["todo"] = "Press one.", ["raised"] = raised, ["by"] = by,
        ["answer"] = null, ["answered"] = null, ["options"] = new JsonArray(options.Select(o => (JsonNode?)o).ToArray()),
        ["talk"] = new JsonArray(),
    };

    public static JsonObject Head(long id, string title, string owner, string state, double activity, string? waitingOn = null,
                                  long? accepted = null, bool? works = null, string? doing = null) => new()
    {
        ["id"] = id, ["title"] = title, ["state"] = state, ["owner"] = owner, ["requester"] = "manager", ["attempt"] = 1,
        ["created"] = activity - 600, ["started"] = activity - 600, ["last_activity"] = activity, ["waiting_on"] = waitingOn,
        ["accepted"] = accepted, ["works"] = works, ["doing"] = doing,
    };

    public static JsonObject Snapshot(string db = "gen1", string token = "boot.1.1") => new()
    {
        ["schema_version"] = 1, ["db"] = db, ["time"] = Now,
        ["ui_features"] = new JsonArray("mobile", "live_changes", "direct_chat", "need_talk", "task_controls",
                                        "task_steering", "attachments", "chat_waits", "edit_in_place"),
        ["agents"] = new JsonArray(
            Agent("manager", "manager", "Fleet Manager", last: Preview(Now - 480, "agent", "Yes. Marketing has the email ready."), machine: "hub"),
            Agent("wren", "worker", "Customer Support", last: Preview(Now - 60, "owner", "Which order is it?"), machine: "vps"),
            Agent("theo", "worker", "Developer", last: Preview(Now - 4000, "agent", "**Fixed** the build.")),
            Agent("pax", "worker", "DevOps", last: null),
            Agent("orla", "worker", "Marketing", last: Preview(Now - 1560, "agent", "The email is ready."))),
        ["needs"] = new JsonArray(
            Need(1, "Refund an order from 45 days ago?", "A customer asks for a refund 15 days after the 30-day window.",
                 "manager", Now - 2400, "Refund it", "Offer a 20% voucher", "Say no, politely"),
            Need(2, "Send the spring sale email on Monday?", "Marketing finished the email. It goes to 4,800 subscribers.",
                 "manager", Now - 1500, "Send it on Monday", "Show me the email first")),
        ["answered_needs"] = new JsonArray(),
        ["tasks"] = new JsonArray(
            Head(11, "Answer today's support tickets", "wren", "working", Now - 300, works: true, doing: "Reading its messages"),
            Head(12, "Fix the checkout error on iPhone", "theo", "working", Now - 720),
            Head(13, "Write the spring sale email", "orla", "input-required", Now - 1500, waitingOn: "N-2")),
        ["recent"] = new JsonArray(
            Head(21, "Post the weekly summary", "manager", "completed", Now - 86_400, accepted: 1),
            Head(22, "Rotate the staging keys", "pax", "completed", Now - 7200, accepted: 1),
            Head(23, "Draft the November newsletter", "orla", "completed", Now - 9000, accepted: 1)),
        ["holds"] = new JsonArray(),
        ["outcomes"] = new JsonArray(),
        ["counts"] = new JsonObject { ["tasks_open"] = 3, ["needs_open"] = 2, ["messages"] = 0, ["reports"] = 0 },
        ["token"] = token,
    };

    public static MobileSnapshot Decode(JsonObject snapshot) => HubDecode.Snapshot(Encoding.UTF8.GetBytes(snapshot.ToJsonString()));

    public static JsonObject Message(string requestId, double ts, string text, string client = "founderizer-windows/1",
                                     long? answerTo = null) => new()
    {
        ["kind"] = "message", ["ts"] = ts, ["id"] = requestId, ["text"] = text, ["client"] = client, ["read_at"] = null,
        ["answer_to"] = answerTo,
    };

    public static JsonObject Report(long id, double ts, string text, string? inReplyTo = null) => new()
    {
        ["kind"] = "report", ["ts"] = ts, ["id"] = id, ["text"] = text, ["about"] = "chat", ["in_reply_to"] = inReplyTo,
        ["pushed"] = false,
    };

    public static JsonObject ChatPage(string db, string agent, params JsonObject[] items) => new()
    {
        ["db"] = db, ["agent"] = agent, ["items"] = new JsonArray(items.Select(i => (JsonNode?)i.DeepClone()).ToArray()),
        ["cursor"] = items.Length == 0 ? 0 : items[^1]["ts"]!.GetValue<double>(),
    };

    /// <summary>A store state that holds this reading as current at <paramref name="now"/>.</summary>
    public static StoreState State(MobileSnapshot fleet, DateTimeOffset now) => new()
    {
        Hub = new Uri("http://192.0.2.10:8765/"), Key = KeyState.InHand, Fleet = fleet, SnapshotAt = now, LastRead = now,
        Clock = now, Front = true,
    };

    public static DateTimeOffset Clock => DateTimeOffset.FromUnixTimeSeconds((long)Now);

    public static readonly ScreenContext Utc = new(TimeZoneInfo.Utc, new System.Globalization.CultureInfo("en-GB"));
}

/// <summary>A hub on 127.0.0.1 with state: the snapshot with its ETag, the chats and tasks, the writes it takes or
/// refuses, enrollment, the devices, the files, and the wait.</summary>
internal sealed class FakeHub : IDisposable
{
    public readonly LoopbackHub Server;
    public JsonObject Snapshot = SampleFleet.Snapshot();
    public readonly ConcurrentDictionary<string, JsonObject> Chats = new();
    public readonly ConcurrentDictionary<long, JsonObject> Tasks = new();
    public readonly ConcurrentQueue<(string Path, JsonElement Body, Seen Seen)> Writes = new();
    public readonly ConcurrentDictionary<string, string> RequestIds = new();
    /// <summary>The next write's refusal: its status and body; null takes it.</summary>
    public (int Status, string Body)? Refuse;
    /// <summary>The writes go unanswered (the hub holds the connection).</summary>
    public bool Silent;
    /// <summary>While it is set and not open, each write waits for it before its answer: its receipt is on its way.</summary>
    public ManualResetEventSlim? Hold;
    /// <summary>While it is set and not open, each read of the fleet waits for it: a read that has no answer yet.</summary>
    public ManualResetEventSlim? HoldReads;
    /// <summary>While it is set and not open, an enrollment waits for it before its answer: a code that waits.</summary>
    public ManualResetEventSlim? HoldEnroll;
    /// <summary>The refusal of each upload while it is set: its status and body.</summary>
    public (int Status, string Body)? RefuseUpload;
    public int MobileReads;
    public int WaitReads;
    public string? WaitToken;
    public long NextEvent = 100;
    /// <summary>Each task's record (GET /ui/tasks/&lt;id&gt;/events), in id order; a page holds at most EventPage.</summary>
    public readonly ConcurrentDictionary<long, List<JsonObject>> Events = new();
    public int EventPage = 500;
    public int EventReads;
    /// <summary>The answer of GET /ui/mobile/ended (owner API 1.166) while it is set, and how many reads came.</summary>
    public JsonObject? Ended;
    public int EndedReads;
    /// <summary>The window and the blocks of GET /ui/mobile/ended (owner API 1.270) while it is set.</summary>
    public EndedBlocksHub? Blocks;
    /// <summary>While it is set, the status and the body of each read of a record.</summary>
    public (int Status, string Body)? RefuseEvents;
    /// <summary>Each accepted task's checked files (GET /ui/tasks/&lt;id&gt;/artifacts and /artifact) from one commit.</summary>
    public readonly ConcurrentDictionary<long, List<(string Path, string Mime, byte[] Bytes)>> Artifacts = new();
    public string Commit = new('a', 40);
    /// <summary>While it is set, the status and the body of each read of a file.</summary>
    public (int Status, string Body)? RefuseArtifact;

    /// <summary>While it is set, it sees each request first: a hub's rule (its key, its claim) that answers a request
    /// itself with what it gives, or lets it through with null.</summary>
    public Func<Seen, byte[]?>? Gate;

    public FakeHub() => Server = new LoopbackHub(seen => Gate?.Invoke(seen) ?? Answer(seen));

    public Uri Address => Server.Address;
    public string Db => Snapshot["db"]!.GetValue<string>();
    private string ETag => "\"" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(Snapshot.ToJsonString())))[..16] + "\"";

    private byte[]? Answer(Seen seen)
    {
        var path = seen.Target.Split('?')[0];
        var query = seen.Target.Contains('?') ? seen.Target[(seen.Target.IndexOf('?') + 1)..] : "";
        var db = query.Split('&').Select(p => p.Split('=')).FirstOrDefault(p => p[0] == "db")?.ElementAtOrDefault(1);
        if (db is not null && Uri.UnescapeDataString(db) != Db)
            return LoopbackHub.Json(409, """{"error":"hub generation changed; refresh state"}""");
        if (path == "/ui/mobile")
        {
            Interlocked.Increment(ref MobileReads);
            HoldReads?.Wait(TimeSpan.FromSeconds(20));
            string tag, json;
            lock (talks) (tag, json) = (ETag, Snapshot.ToJsonString());      // a message under a card changes it
            if (seen.Header("If-None-Match") == tag) return LoopbackHub.Raw(304, [], ("ETag", tag));
            return LoopbackHub.Json(200, json, ("ETag", tag));
        }
        if (path == "/ui/mobile/ended" && Blocks is { } blocks)
        {
            string? Word(string name) => query.Split('&').Select(p => p.Split('=', 2)).FirstOrDefault(p => p[0] == name) is { Length: 2 } p
                ? Uri.UnescapeDataString(p[1]) : null;
            if (Word("window") == "1" || Word("blocks") == "1" || Word("block") is not null)
                return blocks.Answer(Db, Word("window") == "1", Word("blocks") == "1", Word("block"));
        }
        if (path == "/ui/mobile/ended" && Ended is { } ended)
        {
            Interlocked.Increment(ref EndedReads);
            return LoopbackHub.Json(200, ended.ToJsonString());
        }
        if (path.StartsWith("/ui/mobile/chat/", StringComparison.Ordinal))
        {
            var agent = path[16..];
            return LoopbackHub.Json(200, (Chats.TryGetValue(agent, out var page) ? page : SampleFleet.ChatPage(Db, agent)).ToJsonString());
        }
        if (path.StartsWith("/ui/mobile/task/", StringComparison.Ordinal) && Tasks.TryGetValue(long.Parse(path[16..]), out var task))
            return LoopbackHub.Json(200, task.ToJsonString());
        if (path.StartsWith("/ui/tasks/", StringComparison.Ordinal) && seen.Method == "GET")
        {
            var parts = path.Split('/');
            var id = long.Parse(parts[3]);
            string? Query(string name) => query.Split('&').Select(p => p.Split('=', 2)).FirstOrDefault(p => p[0] == name) is { Length: 2 } p
                ? Uri.UnescapeDataString(p[1]) : null;
            if (parts[4] == "events")
            {
                Interlocked.Increment(ref EventReads);
                if (RefuseEvents is { } refusedRead) return LoopbackHub.Json(refusedRead.Status, refusedRead.Body);
                var after = long.Parse(Query("after") ?? "0");
                var limit = Math.Min(int.Parse(Query("limit") ?? "200"), EventPage);
                List<JsonObject> rows;
                lock (Events) rows = (Events.TryGetValue(id, out var all) ? all : []).Where(e => e["id"]!.GetValue<long>() > after).ToList();
                var page = rows.Take(limit).Select(e => (JsonNode)e.DeepClone()).ToArray();
                var next = page.Length > 0 ? page[^1]!["id"]!.GetValue<long>() : after;
                return LoopbackHub.Json(200, new JsonObject
                {
                    ["db"] = Db, ["task"] = id, ["events"] = new JsonArray(page), ["next"] = next, ["more"] = rows.Count > limit,
                }.ToJsonString());
            }
            var files = Artifacts.TryGetValue(id, out var kept) ? kept : [];
            if (parts[4] == "artifacts")
                return LoopbackHub.Json(200, new JsonObject
                {
                    ["db"] = Db, ["task"] = id,
                    ["artifacts"] = new JsonArray(files.Select(f => (JsonNode)new JsonObject
                    {
                        ["path"] = f.Path, ["commit"] = Commit,
                        ["sha256"] = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(f.Bytes)),
                        ["bytes"] = f.Bytes.Length, ["mime"] = f.Mime,
                    }).ToArray()),
                }.ToJsonString());
            if (parts[4] == "artifact")
            {
                if (RefuseArtifact is { } refused) return LoopbackHub.Json(refused.Status, refused.Body);
                var file = files.Single(f => f.Path == Query("path"));
                return LoopbackHub.Raw(200, file.Bytes, ("Content-Type", file.Mime), ("X-Fleet-DB", Db),
                                       ("X-Fleet-Task", id.ToString(System.Globalization.CultureInfo.InvariantCulture)),
                                       ("X-Fleet-Commit", Query("commit") ?? ""));
            }
        }
        if (path == "/ui/wait")
        {
            Interlocked.Increment(ref WaitReads);
            Thread.Sleep(300);
            return LoopbackHub.Json(200, $$"""{"db":"{{Db}}","token":"{{WaitToken ?? Snapshot["token"]!.GetValue<string>()}}"}""");
        }
        if (path == "/ui/owner/enroll")
        {
            HoldEnroll?.Wait(TimeSpan.FromSeconds(20));
            return LoopbackHub.Json(200, """{"device":"pc","label":"PC","key":"device-key-1","since":1.0}""");
        }
        if (path == "/ui/owner/devices")
            return LoopbackHub.Json(200, $$"""{"db":"{{Db}}","devices":[{"device":"pc","label":"PC","address":"192.0.2.7","key":true,"since":1.0,"last_seen":{{SampleFleet.Now - 30}},"this_device":true}]}""");
        if (path == "/health") return LoopbackHub.Json(200, """{"ok":true}""");
        if (path == "/ui/attachments" && seen.Method == "POST")
        {
            if (RefuseUpload is { } refused) return LoopbackHub.Json(refused.Status, refused.Body);
            var hash = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(seen.Body));
            return LoopbackHub.Json(200, $$"""{"id":7,"name":"{{seen.Header("X-Fleet-Name")}}","mime":"{{seen.Header("Content-Type")}}","size":{{seen.Body.Length}},"sha256":"{{hash}}","created":1.0}""");
        }
        if (seen.Method == "POST")
        {
            var body = JsonDocument.Parse(seen.Body).RootElement.Clone();
            Writes.Enqueue((path, body, seen));
            Hold?.Wait(TimeSpan.FromSeconds(20));
            if (Silent) return null;
            if (Refuse is { } refusal) return LoopbackHub.Json(refusal.Status, refusal.Body);
            var id = body.GetProperty("request_id").GetString()!;
            if (path.EndsWith("/talk", StringComparison.Ordinal))
                return Talk(long.Parse(path.Split('/')[3]), body.GetProperty("text").GetString()!, id, seen.Header("X-Fleet-Client"));
            var replayed = !RequestIds.TryAdd(id, path);
            var recipient = body.TryGetProperty("recipient", out var r) ? $"\"{r.GetString()}\"" : "null";
            var files = body.TryGetProperty("attachments", out var a) ? a.GetRawText() : "[]";
            if (path.EndsWith("/control", StringComparison.Ordinal))
                return LoopbackHub.Json(200, new JsonObject
                {
                    ["ok"] = true, ["request_id"] = id, ["client"] = seen.Header("X-Fleet-Client"), ["replayed"] = replayed,
                    ["changed"] = true,
                    ["hold"] = new JsonObject
                    {
                        ["id"] = 1, ["task"] = long.Parse(path.Split('/')[3]), ["kind"] = body.GetProperty("action").GetString(),
                        ["state"] = "requested", ["attempt"] = 1,
                    },
                }.ToJsonString());
            if (path.EndsWith("/steer", StringComparison.Ordinal))
                return LoopbackHub.Json(200, new JsonObject
                {
                    ["ok"] = true, ["request_id"] = id, ["client"] = seen.Header("X-Fleet-Client"), ["replayed"] = replayed,
                    ["steer"] = new JsonObject
                    {
                        ["id"] = Interlocked.Increment(ref NextEvent), ["task"] = long.Parse(path.Split('/')[3]),
                        ["attempt"] = body.GetProperty("expected_attempt").GetInt64(), ["text"] = body.GetProperty("text").GetString(),
                        ["created"] = SampleFleet.Now, ["request_id"] = id, ["client"] = seen.Header("X-Fleet-Client"),
                    },
                }.ToJsonString());
            return LoopbackHub.Json(200, $$"""{"ok":true,"request_id":"{{id}}","event_id":{{Interlocked.Increment(ref NextEvent)}},"created":{{SampleFleet.Now}},"replayed":{{(replayed ? "true" : "false")}},"client":"{{seen.Header("X-Fleet-Client")}}","recipient":{{recipient}},"attachments":{{files}},"read_at":null}""");
        }
        return LoopbackHub.Json(404, """{"error":"not here"}""");
    }

    /// <summary>The message under a card (POST /ui/needs/&lt;id&gt;/talk, owner feature need_clarify), as command_run
    /// answers it: the card's talk with his message, in a command's receipt, and a repeat of the same request gets its
    /// first result. <see cref="TalkCut"/> "before": the send ends before the hub takes it; "after": the hub takes it and
    /// its first answer is lost (502, which no app takes as a refusal). The reading has the card's talk only while
    /// <see cref="TalkInReading"/>.</summary>
    public string TalkCut = "";
    public bool TalkInReading;
    private readonly Dictionary<long, JsonArray> talks = new();
    private readonly Dictionary<string, JsonObject> talkResults = new();

    private byte[] Talk(long need, string text, string id, string? client)
    {
        if (TalkCut == "before") return LoopbackHub.Json(502, """{"error":"bad gateway"}""");
        JsonObject result;
        bool first;
        lock (talks)
        {
            first = !talkResults.TryGetValue(id, out result!);
            if (first)
            {
                var talk = talks.TryGetValue(need, out var held) ? held : talks[need] = new JsonArray();
                talk.Add(new JsonObject { ["who"] = "owner", ["text"] = text, ["ts"] = SampleFleet.Now });
                if (TalkInReading)
                    Snapshot["needs"]!.AsArray().Concat(Snapshot["answered_needs"]!.AsArray())
                        .Single(n => n!["id"]!.GetValue<long>() == need)!["talk"] = talk.DeepClone();
                result = talkResults[id] = new JsonObject
                {
                    ["ok"] = true, ["request_id"] = id, ["client"] = client, ["need"] = need, ["talk"] = talk.DeepClone(),
                };
            }
        }
        if (first && TalkCut == "after") return LoopbackHub.Json(502, """{"error":"bad gateway"}""");
        var answer = (JsonObject)result.DeepClone();
        answer["replayed"] = !first;
        return LoopbackHub.Json(200, answer.ToJsonString());
    }

    public void Dispose() => Server.Dispose();
}

/// <summary>The window and the blocks of GET /ui/mobile/ended (owner API 1.270) as the hub gives them, from its heads: the
/// heads at or above <see cref="Before"/> in the window, the others in blocks of 100 ids, each with a count that a write
/// of one of its heads moves (<see cref="Touch"/>), and the reads of each.</summary>
internal sealed class EndedBlocksHub
{
    public const long Size = 100;
    private readonly object gate = new();
    public readonly SortedDictionary<long, JsonObject> Heads = new();
    public long Before;
    /// <summary>`ended_mark` of GET /ui/mobile, which the window gives back.</summary>
    public string Mark = "m1";
    /// <summary>The count of each block, by its first id.</summary>
    public readonly Dictionary<long, int> Counts = new();
    /// <summary>A hub whose marks are not in place: the window is every head, with no `older`.</summary>
    public bool NoOlder;
    /// <summary>The blocks whose answer the hub cannot make (500).</summary>
    public readonly HashSet<long> Broken = new();
    /// <summary>The list does not come: the hub restarts (503).</summary>
    public bool ListFails;
    public int WindowReads, ListReads;
    public readonly List<long> BlockReads = new();

    /// <summary>Heads of ended tasks with these ids, at a block's count of 1.</summary>
    public void Add(IEnumerable<long> ids)
    {
        lock (gate)
            foreach (var id in ids)
            {
                var head = SampleFleet.Head(id, "Daily report " + id, "pax", id % 9 == 0 ? "failed" : "completed", SampleFleet.Now - (2000 - id) * 600);
                head["trigger_id"] = id % 2 == 0 ? 4 : null;
                Heads[id] = head;
                Counts[id / Size * Size] = Counts.GetValueOrDefault(id / Size * Size) + 1;
            }
    }

    /// <summary>A write of the head <paramref name="id"/>: its block's count moves.</summary>
    public void Touch(long id)
    {
        lock (gate) Counts[id / Size * Size] = Counts.GetValueOrDefault(id / Size * Size) + 1;
    }

    private string OlderMark => $"{Before}.{Counts.Where(c => c.Key < Before).Sum(c => c.Value)}.s1";

    private string BlockMark(long from) => $"{Counts.GetValueOrDefault(from)}.s1";

    private JsonArray Of(Func<long, bool> which) => new(Heads.Where(h => which(h.Key)).Select(h => (JsonNode?)h.Value.DeepClone()).ToArray());

    public byte[] Answer(string db, bool window, bool list, string? block)
    {
        lock (gate)
        {
            if (block is not null)
            {
                var from = long.Parse(block, System.Globalization.CultureInfo.InvariantCulture);
                if (from >= Before) return LoopbackHub.Json(404, """{"error":"no such block of ended tasks"}""");
                BlockReads.Add(from);
                if (Broken.Contains(from)) return LoopbackHub.Json(500, """{"error":"the hub could not make it"}""");
                return LoopbackHub.Json(200, new JsonObject
                {
                    ["db"] = db, ["from"] = from, ["mark"] = BlockMark(from), ["tasks"] = Of(id => id >= from && id < from + Size),
                }.ToJsonString());
            }
            if (list)
            {
                ListReads++;
                if (ListFails) return LoopbackHub.Json(503, """{"error":"the hub restarts"}""");
                var blocks = new JsonArray();
                for (var from = 0L; from < Before; from += Size)
                {
                    var start = from;
                    blocks.Add(new JsonObject { ["from"] = start, ["mark"] = BlockMark(start), ["tasks"] = Heads.Keys.Count(id => id >= start && id < start + Size) });
                }
                return LoopbackHub.Json(200, new JsonObject
                {
                    ["db"] = db, ["before"] = Before, ["block"] = Size, ["mark"] = OlderMark, ["blocks"] = blocks,
                }.ToJsonString());
            }
            WindowReads++;
            var answer = new JsonObject { ["db"] = db, ["mark"] = Mark, ["tasks"] = Of(id => NoOlder || id >= Before) };
            if (!NoOlder) answer["older"] = new JsonObject { ["before"] = Before, ["block"] = Size, ["mark"] = OlderMark };
            return LoopbackHub.Json(200, answer.ToJsonString());
        }
    }
}
