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

    /// <summary>A hub with `ended_blocks` and the heads of the ended tasks 1001 to 1350: the window holds those from 1300,
    /// and the blocks the others (owner API 1.270).</summary>
    private static FakeHub BlocksHub()
    {
        var hub = new FakeHub { Blocks = new EndedBlocksHub { Before = 1300 } };
        hub.Blocks.Add(Enumerable.Range(1001, 350).Select(n => (long)n));
        foreach (var feature in new[] { "mobile_ended", "ended_blocks" }) hub.Snapshot["ui_features"]!.AsArray().Add((JsonNode)feature);
        hub.Snapshot["ended_mark"] = "m1";
        return hub;
    }

    private static OwnerStore Store(string folder) => new(new StoreSettings
    {
        Folder = folder, Keys = new MemoryKeyStore("device-key-1"), ClientLabel = "founderizer-windows/1",
    });

    private static long[] Ids(OwnerStore store) => store.State.Ended!.Tasks.Select(t => t.Id).ToArray();

    private static void Moved(FakeHub hub, string mark)
    {
        hub.Blocks!.Mark = mark;
        hub.Snapshot["ended_mark"] = mark;
    }

    [TestMethod]
    public async Task TheStoreJoinsTheWindowAndTheBlocksAndReadsABlockAgainOnlyWhenItsMarkMoves()
    {
        // The Windows app's read of the ended tasks does not grow with the fleet's history (owner API 1.270): it reads the
        // window, the list, and each block once; then only a block whose mark moved; and at a new start only the blocks
        // that changed, from the ones in its folder. Its Ended lane holds every head, as with the whole read.
        var folder = Directory.CreateTempSubdirectory("founderizer-ended-blocks-").FullName;
        using var hub = BlocksHub();
        var blocks = hub.Blocks!;
        try
        {
            await using (var store = Store(folder))
            {
                await store.ConnectAsync(hub.Address.ToString());
                store.Unlock();
                await store.RefreshAsync();
                CollectionAssert.AreEqual(Enumerable.Range(1001, 350).Select(n => (long)n).ToArray(), Ids(store));
                CollectionAssert.AreEqual(Enumerable.Range(0, 13).Select(n => 1200L - 100 * n).ToArray(), blocks.BlockReads,
                                          "each block below the window once, the newest first");
                Assert.AreEqual((1, 1, 0), (blocks.WindowReads, blocks.ListReads, hub.EndedReads), "no read of every head");
                var whole = Activity.Lanes(store.State.Fleet!, null, ActivityPeriod.All, Utc,
                                           blocks.Heads.Values.Select(h => JsonSerializer.Deserialize(h.ToJsonString(), CoreJson.Default.MobileTaskHead)!).ToList());
                var lane = Screens.Board(store.State, ActivityPeriod.All, null, DateTimeOffset.UtcNow, Utc).Lanes.Single(l => l.Column == ActivityColumn.Done);
                Assert.AreEqual(whole[ActivityColumn.Done].Count, lane.Count, "the lane of every head");

                await store.RefreshAsync();
                Assert.AreEqual((1, 1, 13), (blocks.WindowReads, blocks.ListReads, blocks.BlockReads.Count), "the same mark reads nothing");

                blocks.Heads[1150]["title"] = "Weekly report";
                blocks.Touch(1150);
                Moved(hub, "m2");
                await store.RefreshAsync();
                Assert.AreEqual((2, 2, 1100L), (blocks.WindowReads, blocks.ListReads, blocks.BlockReads[^1]));
                Assert.AreEqual(14, blocks.BlockReads.Count, "only the block whose mark moved");
                Assert.AreEqual("Weekly report", store.State.Ended!.Tasks.Single(t => t.Id == 1150).Title);

                blocks.Add([1351]);
                Moved(hub, "m3");
                await store.RefreshAsync();
                Assert.AreEqual((3, 2, 14, 1351L), (blocks.WindowReads, blocks.ListReads, blocks.BlockReads.Count, Ids(store)[^1]),
                                "a task that ends in the window is in the window alone");
            }
            // The window moves up while the app is closed: the next start reads only the block that it left.
            blocks.Add(Enumerable.Range(1352, 99).Select(n => (long)n));
            blocks.Before = 1400;
            Moved(hub, "m4");
            await using (var again = Store(folder))
            {
                again.Unlock();
                await again.RefreshAsync();
                CollectionAssert.AreEqual(Enumerable.Range(1001, 450).Select(n => (long)n).ToArray(), Ids(again));
                Assert.AreEqual((15, 1300L), (blocks.BlockReads.Count, blocks.BlockReads[^1]), "the kept blocks are read no more");
            }
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public async Task ABlockThatCannotBeReadStopsNoOtherAndItsHeadsStay()
    {
        // A block whose answer the hub cannot make: the others come, it is asked for again three times at its mark and
        // then rests, and at a new mark once more. The heads that the lane showed for its tasks stay meanwhile, as a head
        // that leaves the window stays until its block comes. A window with no `older` is every head: the blocks go.
        var folder = Directory.CreateTempSubdirectory("founderizer-ended-broken-").FullName;
        using var hub = BlocksHub();
        var blocks = hub.Blocks!;
        try
        {
            await using var store = Store(folder);
            await store.ConnectAsync(hub.Address.ToString());
            store.Unlock();
            blocks.Broken.Add(1100);
            await store.RefreshAsync();
            Assert.AreEqual(250, Ids(store).Length, "every head but the block's");
            for (var pass = 0; pass < 4; pass++) await store.RefreshAsync();
            Assert.AreEqual(3, blocks.BlockReads.Count(b => b == 1100), "three times at one mark, then it rests");
            Assert.AreEqual(1, blocks.BlockReads.Count(b => b == 1000));

            blocks.Heads.Remove(1050);              // a task that left the records, while the block of 1100 still fails
            blocks.Touch(1050);
            Moved(hub, "m2");
            await store.RefreshAsync();
            Assert.AreEqual((249, 4), (Ids(store).Length, blocks.BlockReads.Count(b => b == 1100)),
                            "the task leaves with its block's answer, and the failed block is asked for once more at a new mark");

            blocks.Broken.Clear();
            Moved(hub, "m2b");
            await store.RefreshAsync();
            Assert.AreEqual(4, blocks.BlockReads.Count(b => b == 1100), "it failed once more at this mark: it rests");
            blocks.Touch(1250);
            Moved(hub, "m2c");
            await store.RefreshAsync();
            Assert.AreEqual((349, 5), (Ids(store).Length, blocks.BlockReads.Count(b => b == 1100)), "and comes at the next");

            blocks.Add(Enumerable.Range(1351, 100).Select(n => (long)n));
            Moved(hub, "m3");
            await store.RefreshAsync();
            blocks.Before = 1400;
            blocks.Broken.Add(1300);
            Moved(hub, "m4");
            await store.RefreshAsync();
            Assert.AreEqual((449, 1300L), (Ids(store).Length, blocks.BlockReads[^1]),
                            "the heads that left the window stay until their block comes");
            Assert.IsTrue(Directory.GetFiles(Path.Combine(folder, "ended")).Length > 0);

            blocks.NoOlder = true;
            Moved(hub, "m5");
            await store.RefreshAsync();
            Assert.AreEqual(449, Ids(store).Length, "a window with no older is every head");
            Assert.AreEqual(0, Directory.GetFiles(Path.Combine(folder, "ended")).Length, "and the blocks go");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public async Task AHubThatNoLongerOffersTheBlocksIsReadWholeOnce()
    {
        // A read of the blocks that a restart of the hub broke off, and then a hub of a release before owner API 1.270:
        // the store reads every head once, as before, and its blocks go with their files. Not again at each pass.
        var folder = Directory.CreateTempSubdirectory("founderizer-ended-older-hub-").FullName;
        using var hub = BlocksHub();
        var blocks = hub.Blocks!;
        try
        {
            await using var store = Store(folder);
            await store.ConnectAsync(hub.Address.ToString());
            store.Unlock();
            await store.RefreshAsync();
            blocks.ListFails = true;
            blocks.Touch(1050);
            Moved(hub, "m2");
            await store.RefreshAsync();
            Assert.AreEqual((2, 2, 350), (blocks.WindowReads, blocks.ListReads, Ids(store).Length));

            var features = hub.Snapshot["ui_features"]!.AsArray();
            features.Remove(features.Single(f => f!.GetValue<string>() == "ended_blocks"));
            hub.Ended = new JsonObject
            {
                ["db"] = "gen1", ["mark"] = "m3",
                ["tasks"] = new JsonArray(blocks.Heads.Values.Select(h => (JsonNode?)h.DeepClone()).ToArray()),
            };
            hub.Snapshot["ended_mark"] = "m3";
            for (var pass = 0; pass < 3; pass++) await store.RefreshAsync();
            Assert.AreEqual((1, 350, 2), (hub.EndedReads, Ids(store).Length, blocks.WindowReads), "every head once");
            Assert.AreEqual(0, Directory.GetFiles(Path.Combine(folder, "ended")).Length, "and the blocks go");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
