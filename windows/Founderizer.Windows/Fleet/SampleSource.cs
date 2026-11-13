using System;
using System.Collections.Generic;
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
/// app/ios/Sources/SampleFleetData.swift): its GET /ui/mobile read, with its times ("@-480": seconds before now) set
/// from the clock, decoded by the library's own decoder, as a store's state that reads current. While the window is in
/// front the reading stays current, as a store that reads the hub every 30 seconds keeps it.</summary>
public sealed class SampleSource : IFleetSource
{
    private readonly JsonObject all;
    private readonly double now;
    private readonly object gate = new();
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
        state = Read(DateTimeOffset.UtcNow);
        // A reading of rule 6 (app/windows/vm/README.md, "Readings"): the sample changes one line every 3 seconds, and
        // the window logs the time from each change to its frame. Off unless the reading asks for it.
        if (Environment.GetEnvironmentVariable("FOUNDERIZER_READING") == "changes")
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

    /// <summary>Now, in seconds since 1970. FOUNDERIZER_SAMPLE_CLOCK=HH:mm puts the sample at that time of today, as the
    /// approved pictures show it at 15:12; the window shows no sign of it.</summary>
    private static double Clock()
    {
        var at = DateTimeOffset.Now;
        if (Environment.GetEnvironmentVariable("FOUNDERIZER_SAMPLE_CLOCK") is { } clock
            && TimeSpan.TryParseExact(clock, @"hh\:mm", CultureInfo.InvariantCulture, out var time))
        {
            at = new DateTimeOffset(at.Date + time, at.Offset);
        }
        return at.ToUnixTimeMilliseconds() / 1000.0;
    }

    /// <summary>A whole new state (never a `with` of the last one), read at <paramref name="at"/>.</summary>
    private StoreState Read(DateTimeOffset at) => new()
    {
        Version = ++version,
        Hub = new Uri("http://sample.invalid/"),
        Key = KeyState.InHand,
        Fleet = fleet,
        SnapshotAt = at,
        LastRead = at,
        Clock = at,
        Front = true,
    };

    private void Renew()
    {
        StoreState next;
        lock (gate) next = state = Read(DateTimeOffset.UtcNow);
        Changed?.Invoke(this, new FleetChange(next, Stopwatch.GetTimestamp()));
    }

    private byte[] MobileJson(Action<JsonObject>? change = null)
    {
        var mobile = Timed(all["mobile"]!.DeepClone(), now)!.AsObject();
        change?.Invoke(mobile);
        return Encoding.UTF8.GetBytes(mobile.ToJsonString());
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
