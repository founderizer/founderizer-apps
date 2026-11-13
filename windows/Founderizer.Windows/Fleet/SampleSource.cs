using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>The sample fleet of the Mac and iPhone apps (Sample/SampleFleet.json, a copy of
/// app/ios/Sources/SampleFleetData.swift): its reads of GET /ui/mobile, of each chat and of each task, with their times
/// ("@-480": seconds before now) set from the clock, decoded by the library's own decoders, as a store's state that
/// reads current. While the window is in front the reading stays current, as a store that reads the hub every 30
/// seconds keeps it. It keeps his drafts as he types; it sends nothing (the store's writes are proved against a hub,
/// app/windows/vm/README.md).
///
/// For the pictures and the readings only: FOUNDERIZER_SAMPLE_ASK adds one message of his to Customer Support's chat,
/// a minute before the clock, which the agent works on (picture 2); FOUNDERIZER_READING=long-chat gives Customer
/// Support a chat of 2,000 messages and replies.</summary>
public sealed partial class SampleSource : IFleetSource
{
    /// <summary>The messages and replies of the long chat of the scroll reading.</summary>
    public const int LongChat = 2000;

    private readonly JsonObject all;
    private readonly double now;
    private readonly object gate = new();
    private readonly string? ask = Proofs.Variable("FOUNDERIZER_SAMPLE_ASK");
    private readonly bool longChat = Proofs.Variable("FOUNDERIZER_READING") == "long-chat";
    private readonly ImmutableDictionary<string, ChatPageState> chats;
    private readonly ImmutableDictionary<long, TaskPageState> tasks;
    private ImmutableDictionary<string, string> drafts = ImmutableDictionary<string, string>.Empty;
    private ImmutableDictionary<long, string> answerDrafts = ImmutableDictionary<long, string>.Empty;
    private MobileSnapshot fleet;
    private StoreState state;
    private long version;
    private Timer? renew;
    private Timer? changes;
    private int changeCount;

    public SampleSource()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Founderizer.Windows.Sample.SampleFleet.json")
            ?? throw new InvalidOperationException("the sample fleet is not in the build");
        all = JsonNode.Parse(stream)!.AsObject();
        now = Clock();
        fleet = HubDecode.Snapshot(MobileJson());
        chats = Chats();
        tasks = Tasks();
        state = Read(DateTimeOffset.UtcNow);
        NotifyLater();
        // A reading of rule 6 (app/windows/vm/README.md, "Readings"): the sample changes one line every 3 seconds, and
        // the window logs the time from each change to its frame. Off unless the reading asks for it.
        if (Proofs.Variable("FOUNDERIZER_READING") == "changes")
        {
            changes = new Timer(_ => Change(), null, TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(3));
        }
    }

    public StoreState State { get { lock (gate) return state; } }

    public event EventHandler<FleetChange>? Changed;

    public void SetFront(bool front)
    {
        lock (gate)
        {
            renew?.Dispose();
            renew = front ? new Timer(_ => Renew(), null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15)) : null;
        }
    }

    public ValueTask DisposeAsync()
    {
        renew?.Dispose();
        changes?.Dispose();
        return ValueTask.CompletedTask;
    }

    // Every chat and task of the sample is read at the start, so a page that opens needs no read.
    public void OpenChat(string? agent) { }

    public void OpenTask(long? task) { }

    public void SetDraft(string agent, string text)
    {
        lock (gate) drafts = text.Length == 0 ? drafts.Remove(agent) : drafts.SetItem(agent, text);
        Renew();
    }

    public void SetAnswerDraft(long need, string text)
    {
        lock (gate) answerDrafts = text.Length == 0 ? answerDrafts.Remove(need) : answerDrafts.SetItem(need, text);
        Renew();
    }

    public Task<string?> SendMessageAsync(string agent) => Task.FromResult<string?>(null);

    public Task<string?> AnswerAsync(long need) => Task.FromResult<string?>(null);

    public Task<string?> TickAsync(long need, IReadOnlyCollection<int> choices) => Task.FromResult<string?>(null);

    public void Press(long need, int choice) { }

    public Task<string?> ControlAsync(long task, TaskControl action) => Task.FromResult<string?>(null);

    public Task<string?> GuideAsync(long task, string text) => Task.FromResult<string?>(null);

    public Task RefreshAsync() => Task.CompletedTask;

    public Task RetryAsync() => Task.CompletedTask;

    public void DiscardRefused() { }

    public Task<string?> AddFileAsync(string composer, string name, byte[] bytes, string? mime) => Task.FromResult<string?>(null);

    public Task<string?> UploadAsync(string composer, Guid file) => Task.FromResult<string?>(null);

    public void RemoveFile(string composer, Guid file) { }

    public Task<byte[]> FileAsync(MessageAttachment file) => Task.FromResult(SampleFile(file));

    /// <summary>The sample notifies only in the state of picture 10 (SampleStates.cs).</summary>
    public event EventHandler<IReadOnlyList<Notice>>? Notified;

    public Task<string?> ConnectAsync(string address)
    {
        var refused = Connect(address);
        Renew();
        return Task.FromResult(refused);
    }

    public Task<string?> EnrollAsync(string code) => Task.FromResult(EnrollWords());

    public string? ForgetKey() => null;

    public Task ReadDeviceAsync() => Task.CompletedTask;

    /// <summary>Now, in seconds since 1970. FOUNDERIZER_SAMPLE_CLOCK=HH:mm puts the sample at that time of today, as the
    /// approved pictures show it at 15:12; the window shows no sign of it.</summary>
    private static double Clock()
    {
        var at = DateTimeOffset.Now;
        if (Proofs.Variable("FOUNDERIZER_SAMPLE_CLOCK") is { } clock
            && TimeSpan.TryParseExact(clock, @"hh\:mm", CultureInfo.InvariantCulture, out var time))
        {
            at = new DateTimeOffset(at.Date + time, at.Offset);
        }
        return at.ToUnixTimeMilliseconds() / 1000.0;
    }

    /// <summary>A whole new state, read at <paramref name="at"/>.</summary>
    private StoreState Read(DateTimeOffset at) => Picture(new()
    {
        Version = ++version,
        // The Mac's example address and this PC's line as Settings shows them (picture 6), with an example address of
        // the public copy's list (app/public-copy/example-addresses.txt) for this PC, where the picture has one that is not on it.
        Hub = new Uri("http://100.84.1.2:8765/"),
        Key = KeyState.InHand,
        Device = new MobileDevice("pc", "PC", "100.84.1.9", Key: true, LastSeen: at.ToUnixTimeMilliseconds() / 1000.0, ThisDevice: true, Kind: "pc"),
        Fleet = fleet,
        SnapshotAt = at,
        LastRead = at,
        Clock = at,
        Front = true,
        Chats = chats,
        TaskPages = tasks,
        Drafts = drafts,
        AnswerDrafts = answerDrafts,
    }, at);

    private void Renew()
    {
        StoreState next;
        lock (gate) next = state = Read(DateTimeOffset.UtcNow);
        Changed?.Invoke(this, new FleetChange(next, Stopwatch.GetTimestamp()));
    }

    private byte[] MobileJson(Action<JsonObject>? change = null)
    {
        var mobile = Timed(all["mobile"]!.DeepClone(), now)!.AsObject();
        if (ask is not null)
        {
            foreach (var agent in mobile["agents"]!.AsArray())
            {
                if ((string?)agent!["name"] != "wren") continue;
                agent["last"] = new JsonObject { ["preview"] = ask, ["side"] = "owner", ["ts"] = now - 60 };
            }
        }
        PictureMobile(mobile);
        change?.Invoke(mobile);
        return Encoding.UTF8.GetBytes(mobile.ToJsonString());
    }

    private ImmutableDictionary<string, ChatPageState> Chats()
    {
        var pages = ImmutableDictionary.CreateBuilder<string, ChatPageState>();
        foreach (var (agent, node) in all["chats"]!.AsObject())
        {
            var chat = Timed(node!.DeepClone(), now)!.AsObject();
            var items = chat["items"]!.AsArray();
            if (agent == "wren" && longChat)
            {
                items.Clear();
                foreach (var item in LongItems()) items.Add(item);
            }
            if (agent == "wren" && ask is not null) items.Add(Message("00000000-0000-0000-0000-0000000000a1", ask, now - 60));
            PictureChat(agent, chat);
            var page = HubDecode.ChatPage(Encoding.UTF8.GetBytes(chat.ToJsonString()), "sample", agent);
            pages[agent] = new ChatPageState { Agent = agent, Items = ValueList.Of(page.Items) };
        }
        return pages.ToImmutable();
    }

    private ImmutableDictionary<long, TaskPageState> Tasks()
    {
        var pages = ImmutableDictionary.CreateBuilder<long, TaskPageState>();
        foreach (var (key, node) in all["tasks"]!.AsObject())
        {
            long id = long.Parse(key, CultureInfo.InvariantCulture);
            var timed = Timed(node!.DeepClone(), now)!.AsObject();
            PictureTask(id, timed);
            var page = HubDecode.TaskPage(Encoding.UTF8.GetBytes(timed.ToJsonString()), "sample", id);
            pages[id] = new TaskPageState
            {
                Task = page.Task,
                Notes = ValueList.Of(page.Notes),
                Holds = ValueList.Of(page.Holds),
                Outcomes = ValueList.Of(page.Outcomes),
            };
        }
        return pages.ToImmutable();
    }

    private static JsonObject Message(string id, string text, double ts) => new()
    {
        ["answer_to"] = null,
        ["attachments"] = new JsonArray(),
        ["client"] = "PC",
        ["edited"] = null,
        ["id"] = id,
        ["kind"] = "message",
        ["read_at"] = ts + 5,
        ["replaces"] = null,
        ["text"] = text,
        ["ts"] = ts,
    };

    private static JsonObject Report(long id, string text, double ts) => new()
    {
        ["about"] = "",
        ["id"] = id,
        ["in_reply_to"] = null,
        ["kind"] = "report",
        ["pushed"] = false,
        ["text"] = text,
        ["ts"] = ts,
    };

    /// <summary>The long chat: his message and the agent's reply in turn, ten minutes apart, the newest a reply an hour
    /// before the clock, the replies of one, two or three paragraphs, a list or a code block, as agents write.</summary>
    private IEnumerable<JsonObject> LongItems()
    {
        string[] replies =
        [
            "I answered the ticket and closed it.",
            "I checked the order. The payment went through, and the parcel left the warehouse yesterday.\n\nThe customer has the tracking number now.",
            "Three customers asked about the spring sale:\n\n- one wants the date\n- one asks for the code\n- one asks if it covers shipping\n\nI answered all three.",
            "The refund rule is in the help centre. I sent the customer the link and a short summary of the 30 days.",
            "I tried the reset link that the customer had:\n\n```\nhttps://shop.example.com/reset?token=expired\n```\n\nIt expired, so I sent a new one.",
            "Two tickets are about the same delivery delay. I joined them and wrote one answer for both.\n\nI will check the carrier's page again in an hour.\n\nNothing else is open.",
        ];
        string[] messages = ["How many are open?", "Thanks. Anything urgent?", "Which order is it?", "Can you send me the summary?", "Good. Go on."];
        double newest = now - 3600;
        for (int i = 0; i < LongChat; i++)
        {
            double ts = newest - (LongChat - 1 - i) * 600;
            if (i % 2 == 0) yield return Message($"00000000-0000-0000-0000-{i:D12}", messages[i / 2 % messages.Length], ts);
            else yield return Report(1000 + i, replies[i / 2 % replies.Length], ts);
        }
    }

    /// <summary>Every time of the sample, "@-480" or "@i-480" (a whole number), as seconds from now (SampleHub.timed).</summary>
    private static JsonNode? Timed(JsonNode? node, double now)
    {
        switch (node)
        {
            case JsonValue value when value.TryGetValue(out string? words) && words.StartsWith('@'):
                if (words.StartsWith("@i", StringComparison.Ordinal)
                    && long.TryParse(words[2..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long whole))
                {
                    return JsonValue.Create((long)now + whole);
                }
                return double.TryParse(words[1..], NumberStyles.Float, CultureInfo.InvariantCulture, out double seconds)
                    ? JsonValue.Create(now + seconds)
                    : value;
            case JsonArray list:
                for (int i = 0; i < list.Count; i++) list[i] = Timed(list[i]?.DeepClone(), now);
                return list;
            case JsonObject fields:
                var names = new List<string>();
                foreach (var pair in fields) names.Add(pair.Key);
                foreach (var name in names) fields[name] = Timed(fields[name]?.DeepClone(), now);
                return fields;
            default:
                return node;
        }
    }

    /// <summary>The reading's change: DevOps's last line changes, so its row changes and no other.</summary>
    private void Change()
    {
        long arrived = Stopwatch.GetTimestamp();
        int n = Interlocked.Increment(ref changeCount);
        var changed = HubDecode.Snapshot(MobileJson(mobile =>
        {
            foreach (var agent in mobile["agents"]!.AsArray())
            {
                if ((string?)agent!["name"] != "pax") continue;
                var last = agent["last"]!.AsObject();
                last["preview"] = n % 2 == 1 ? "A reading: the line changed." : "Backups ran at 03:00 and I tested one restore.";
                last["ts"] = now - 60;
            }
        }));
        StoreState next;
        lock (gate)
        {
            fleet = changed;
            next = state = Read(DateTimeOffset.UtcNow);
        }
        Changed?.Invoke(this, new FleetChange(next, arrived));
    }
}
