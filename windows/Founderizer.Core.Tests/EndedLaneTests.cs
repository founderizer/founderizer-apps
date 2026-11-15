using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using static Founderizer.Core.Tests.SampleFleet;

namespace Founderizer.Core.Tests;

/// <summary>The Ended lane counts and opens every ended task of its period, as the Mac's does (the owner, 14 November 2026:
/// "Yes, as the Mac"; owner API 1.166): equal to FleetCore's lane (HubState.activity and EndedTasks, written into
/// swift-words.json by WordsVectorsTests.swift) in each period, and read by the store when the reading's mark moves.</summary>
[TestClass]
public sealed class EndedLaneTests
{
    private static readonly ActivityPeriod[] Periods = [ActivityPeriod.Today, ActivityPeriod.Week, ActivityPeriod.Month, ActivityPeriod.All];

    private static MobileTaskHead Head(JsonElement t)
    {
        double? Number(string name) => t.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;
        long? Whole(string name) => t.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;
        return new MobileTaskHead(t.GetProperty("id").GetInt64(), t.GetProperty("title").GetString()!, t.GetProperty("state").GetString()!,
                                  t.GetProperty("owner").GetString()!, "manager", 1, t.GetProperty("created").GetDouble(),
                                  Accepted: Whole("accepted"), Started: Number("started"), LastActivity: Number("last_activity"),
                                  TriggerId: Whole("trigger_id"));
    }

    [TestMethod]
    public void TheEndedLaneOfEachPeriodIsFleetCores()
    {
        var ended = Vectors.Read("swift-words.json").GetProperty("ended");
        var heads = ended.GetProperty("tasks").EnumerateArray().Select(Head).ToList();
        var fleet = Decode(Snapshot()) with
        {
            Time = ended.GetProperty("now").GetDouble(), Tasks = heads.Where(t => !t.IsTerminal).ToList(), Recent = [],
            Holds = [], Outcomes = [], Needs = [],
        };
        var all = heads.Where(t => t.IsTerminal).ToList();
        // The reading's own 20 newest ended heads carry no schedule (GET /ui/mobile `recent`): beside the ended read they
        // change nothing.
        var recent = all.OrderByDescending(t => t.Id).Take(20).Select(t => t with { TriggerId = null }).ToList();
        foreach (var reading in new[] { fleet, fleet with { Recent = recent } })
        foreach (var lane in ended.GetProperty("lanes").EnumerateArray())
        {
            fleet = reading;
            var period = Periods.Single(p => p.ToString().Equals(lane.GetProperty("period").GetString(), StringComparison.OrdinalIgnoreCase));
            var done = Activity.Lanes(fleet, null, period, Utc, all)[ActivityColumn.Done];
            var shown = new EndedTasks(done, Utc);
            Assert.AreEqual(lane.GetProperty("count").GetInt32(), done.Count, period + ": the count");
            CollectionAssert.AreEqual(lane.GetProperty("failed").EnumerateArray().Select(i => i.GetInt64()).ToArray(),
                                      shown.Failed.Select(t => t.Id).ToArray(), period + ": the results that he must see");
            Assert.AreEqual(lane.GetProperty("rest").GetInt32(), shown.Rest, period + ": behind Show all");
            var days = lane.GetProperty("days").EnumerateArray().ToList();
            Assert.AreEqual(days.Count, shown.Days.Count, period + ": the days");
            foreach (var (day, mine) in days.Zip(shown.Days))
            {
                Assert.AreEqual(day.GetProperty("start").GetDouble(), mine.Start, period + ": a day's start");
                CollectionAssert.AreEqual(
                    day.GetProperty("groups").EnumerateArray().Select(g => g.GetProperty("title").GetString() + ": " +
                        string.Join(",", g.GetProperty("ids").EnumerateArray().Select(i => i.GetInt64()))).ToArray(),
                    mine.Groups.Select(g => g.Title + ": " + string.Join(",", g.Tasks.Select(t => t.Id))).ToArray(), period + ": a day's rows");
            }
        }
        // Without the ended read, a schedule's runs of one day with other titles are rows of their own: the case that
        // the schedule's id settles.
        var byTitle = new EndedTasks(Activity.Lanes(fleet, null, ActivityPeriod.Today, Utc,
            all.Select(t => t with { TriggerId = null }).ToList())[ActivityColumn.Done], Utc);
        Assert.IsTrue(byTitle.Days[0].Groups.Count > new EndedTasks(Activity.Lanes(fleet, null, ActivityPeriod.Today, Utc, all)[ActivityColumn.Done], Utc).Days[0].Groups.Count);
    }

    [TestMethod]
    public async Task TheStoreReadsEveryEndedTaskWhenTheMarkMoves()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-ended-").FullName;
        using var hub = new FakeHub();
        try
        {
            JsonObject Ended(string mark, int count) => new()
            {
                ["db"] = "gen1", ["mark"] = mark,
                ["tasks"] = new JsonArray(Enumerable.Range(1, count).Select(n =>
                {
                    var head = SampleFleet.Head(1000 + n, "Daily report " + n, "pax", n % 9 == 0 ? "failed" : "completed", Now - n * 3600);
                    head["trigger_id"] = n % 2 == 0 ? 4 : null;
                    return (JsonNode)head;
                }).ToArray()),
            };
            hub.Ended = Ended("m1", 30);
            await using var store = new OwnerStore(new StoreSettings
            {
                Folder = folder, Keys = new MemoryKeyStore("device-key-1"), ClientLabel = "founderizer-windows/1",
            });
            await store.ConnectAsync(hub.Address.ToString());
            store.Unlock();
            await store.RefreshAsync();
            Assert.AreEqual(0, hub.EndedReads, "a hub without mobile_ended: the lane stays on the reading's own");
            Assert.IsNull(store.State.Ended);

            hub.Snapshot["ui_features"]!.AsArray().Add((JsonNode)"mobile_ended");
            hub.Snapshot["ended_mark"] = "m1";
            await store.RefreshAsync();
            Assert.AreEqual((1, "m1", 30), (hub.EndedReads, store.State.Ended!.Mark, store.State.Ended.Tasks.Count));
            var lane = Screens.Board(store.State, ActivityPeriod.All, null, DateTimeOffset.UtcNow, Utc).Lanes.Single(l => l.Column == ActivityColumn.Done);
            Assert.AreEqual(30 + store.State.Fleet!.Recent.Count(t => t.Id < 1000), lane.Count, "every ended task, and the reading's own");
            await store.RefreshAsync();
            Assert.AreEqual(1, hub.EndedReads, "the same mark reads nothing");

            hub.Ended = Ended("m2", 31);
            hub.Snapshot["ended_mark"] = "m2";
            await store.RefreshAsync();
            Assert.AreEqual((2, 31), (hub.EndedReads, store.State.Ended!.Tasks.Count));
            Assert.AreEqual(31, store.State.AllTasks().Count(t => t.Id > 1000));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
