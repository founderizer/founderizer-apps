using System;
using System.IO;
using System.Linq;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The records of the first run outlive the page and the start of the app that wrote them** (the Mac's
/// KeptRecords, piece L4).</summary>
[TestClass]
public sealed class KeptRecordsTests
{
    private static BuildRecord Build(string name, DateTimeOffset at, string launch = "launch-1") =>
        BuildRecord.Begin("hetzner", "hub", null, name, launch, at);

    /// <summary>**A record written by a start that ended reads as cut off, never as work that runs, and a later start
    /// reads every record back from its file.** Bug: a build that the app's close cut off read as a build that runs, so
    /// that its server is never offered to Start again; or a record that only memory held.</summary>
    [TestMethod]
    public void A_record_of_an_earlier_start_reads_as_cut_off_and_every_record_comes_back_from_its_file()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-records-").FullName;
        try
        {
            var at = new DateTimeOffset(2026, 11, 21, 9, 0, 0, TimeSpan.Zero);
            var first = new SetupRecords(folder, "launch-1");
            var made = Build("worker-1", at).Made("101", at.AddSeconds(30), "cx23", 5.99m, "EUR");
            first.Builds.Write(made);
            first.Builds.Write(Build("worker-2", at.AddMinutes(1)).Joined(at.AddMinutes(2), "http://100.64.0.9:8765/"));
            Assert.AreEqual(BuildOutcome.Running, first.Builds.All().Single(r => r.Name == "worker-1").Outcome, "this start runs it");

            File.WriteAllText(Path.Combine(folder, "records", "builds", "not-a-record.json"), "{\"id\": 3}");
            File.WriteAllText(Path.Combine(folder, "records", "builds", Guid.NewGuid().ToString("D") + ".json"),
                              File.ReadAllText(Path.Combine(folder, "records", "builds", made.Id.ToString("D") + ".json")));

            var later = new SetupRecords(folder, "launch-2");
            var all = later.Builds.All();
            Assert.AreEqual(2, all.Count, "a file that is no record, or whose name is not its record's id, is passed over");
            var cut = all.Single(r => r.Name == "worker-1");
            Assert.AreEqual((BuildOutcome.Interrupted, "101", AtProvider.Server, 5.99m, at.AddSeconds(30)),
                            (cut.Outcome, cut.ServerId, cut.AtProvider, cut.MonthlyPrice, cut.MadeAt));
            Assert.IsTrue(cut.IsUnjoined, "a cut-off build that made a server can stand at its provider");
            Assert.AreEqual("http://100.64.0.9:8765/", all.Single(r => r.Name == "worker-2").Hub);

            later.Builds.Remove(r => r.Name == "worker-1");
            Assert.AreEqual(1, new SetupRecords(folder, "launch-3").Builds.All().Count, "a removal takes the file away");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    /// <summary>**Past the limit the oldest records go, but never one whose work this start still runs.** Bug: a long
    /// list of old builds that pushes out the record of the build that runs now.</summary>
    [TestMethod]
    public void The_oldest_records_go_past_the_limit_but_never_one_that_runs_now()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-records-").FullName;
        try
        {
            var at = new DateTimeOffset(2026, 11, 21, 9, 0, 0, TimeSpan.Zero);
            var store = new KeptRecords<BuildRecord>(Path.Combine(folder, "b"), RecordsJson.Default.BuildRecord, "launch-1", keeps: 2);
            var running = Build("worker-0", at);
            store.Write(running);
            for (var n = 1; n <= 3; n++) store.Write(Build("worker-" + n, at.AddMinutes(n)).End(at.AddMinutes(n)));
            var names = new KeptRecords<BuildRecord>(Path.Combine(folder, "b"), RecordsJson.Default.BuildRecord, "launch-1").All().Select(r => r.Name).ToList();
            CollectionAssert.AreEquivalent(new[] { "worker-0", "worker-2", "worker-3" }, names);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
