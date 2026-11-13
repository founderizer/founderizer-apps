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
    /// <summary>The refusal of each upload while it is set: its status and body.</summary>
    public (int Status, string Body)? RefuseUpload;
    public int MobileReads;
    public int WaitReads;
    public string? WaitToken;
    public long NextEvent = 100;

    public FakeHub() => Server = new LoopbackHub(Answer);

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
            if (seen.Header("If-None-Match") == ETag) return LoopbackHub.Raw(304, [], ("ETag", ETag));
            return LoopbackHub.Json(200, Snapshot.ToJsonString(), ("ETag", ETag));
        }
        if (path.StartsWith("/ui/mobile/chat/", StringComparison.Ordinal))
        {
            var agent = path[16..];
            return LoopbackHub.Json(200, (Chats.TryGetValue(agent, out var page) ? page : SampleFleet.ChatPage(Db, agent)).ToJsonString());
        }
        if (path.StartsWith("/ui/mobile/task/", StringComparison.Ordinal) && Tasks.TryGetValue(long.Parse(path[16..]), out var task))
            return LoopbackHub.Json(200, task.ToJsonString());
        if (path == "/ui/wait")
        {
            Interlocked.Increment(ref WaitReads);
            Thread.Sleep(300);
            return LoopbackHub.Json(200, $$"""{"db":"{{Db}}","token":"{{WaitToken ?? Snapshot["token"]!.GetValue<string>()}}"}""");
        }
        if (path == "/ui/owner/enroll")
            return LoopbackHub.Json(200, """{"device":"pc","label":"PC","key":"device-key-1","since":1.0}""");
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
            if (Silent) return null;
            if (Refuse is { } refusal) return LoopbackHub.Json(refusal.Status, refusal.Body);
            var id = body.GetProperty("request_id").GetString()!;
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
            return LoopbackHub.Json(200, $$"""{"ok":true,"request_id":"{{id}}","event_id":{{Interlocked.Increment(ref NextEvent)}},"created":{{SampleFleet.Now}},"replayed":{{(replayed ? "true" : "false")}},"client":"{{seen.Header("X-Fleet-Client")}}","recipient":{{recipient}},"attachments":{{files}},"read_at":null}""");
        }
        return LoopbackHub.Json(404, """{"error":"not here"}""");
    }

    public void Dispose() => Server.Dispose();
}
