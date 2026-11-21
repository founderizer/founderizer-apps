using System;
using System.Linq;
using System.Threading.Tasks;
using Founderizer.Setup.Install;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**What an install keeps after its page is gone, and the wait before a retry** (the Mac's InstallLog,
/// BuildRecord and InstallRetry.wait).</summary>
[TestClass]
public sealed class InstallRecordTests
{
    private static readonly DateTimeOffset At = new(2026, 11, 20, 12, 0, 0, TimeSpan.Zero);

    /// <summary>**The one line that a record keeps holds no secret of the plan, on one line, cut to its limit**, and a
    /// retry counts its tries, keeps the last two names and starts the steps again. A record whose line kept the
    /// Tailscale key would hold it on the PC's disk.</summary>
    [TestMethod]
    public void A_stops_kept_line_holds_no_secret_and_a_retry_starts_the_steps_again()
    {
        const string key = "tskey-auth-kEXAMPLE03-NOTAKEYNOTAKEYNOTAKEY";
        var log = new InstallLog(InstallKind.Join, null, "203.0.113.10", "launch-1", At);
        log.Hide([key, "short"]);
        Assert.IsTrue(log.Note("read", RecordStepState.Running, At));
        Assert.IsFalse(log.Note("read", RecordStepState.Running, At.AddSeconds(1)), "a report that changes nothing");
        Assert.IsTrue(log.Note("read", RecordStepState.Done, At.AddSeconds(2)));
        Assert.IsTrue(log.Note("network", RecordStepState.Failed, At.AddSeconds(3)));
        Assert.IsTrue(log.Retry(InstallStop.InstallerStopped, InstallCause.HubBusy));
        Assert.IsTrue(log.Retry(InstallStop.ServerUnreached, null));
        Assert.IsTrue(log.Retry(InstallStop.InstallerStopped, InstallCause.Packages));
        Assert.AreEqual(4, log.Record.Tries);
        CollectionAssert.AreEqual(new[] { "server_unreached", "packages" }, log.Record.Retried!.ToList());
        Assert.AreEqual(0, log.Record.Steps.Count);

        log.Note("join", RecordStepState.Failed, At.AddSeconds(9));
        var words = $"It used {key}\nand said short " + new string('x', 400);
        Assert.IsTrue(log.Stop(InstallStop.StepFailed, words, at: At.AddSeconds(10)));
        var says = log.Record.Says!;
        Assert.IsFalse(says.Contains(key, StringComparison.Ordinal));
        StringAssert.StartsWith(says, "It used (not shown) and said short xxx");
        Assert.AreEqual(InstallRecord.SaysLimit, says.Length);
        Assert.AreEqual(InstallStepId.Join, log.Record.StoppedAt);
        Assert.IsFalse(log.Cancel(At.AddSeconds(11)), "a stop keeps its end");
    }

    /// <summary>**A build that did not join and may have left a server keeps that name in use while its key lives**,
    /// and a build that left nothing or joined does not: a new server under a name in use is installed onto the old one.</summary>
    [TestMethod]
    public void A_build_that_may_have_left_a_server_keeps_its_name_in_use()
    {
        var life = TimeSpan.FromHours(1);
        var refused = BuildRecord.Begin("hetzner", "hub", null, "fleet-1", "l", At).CallEnded(AtProvider.Nothing).End(At.AddMinutes(1));
        var made = BuildRecord.Begin("hetzner", "agents", null, "fleet-2", "l", At).Made("4711", At.AddMinutes(1)).End(At.AddMinutes(5));
        var unknown = BuildRecord.Begin("vultr", "agents", null, "fleet-3", "l", At).End(At.AddMinutes(2), cancelled: true);
        var joined = BuildRecord.Begin("hetzner", "agents", null, "fleet-4", "l", At).Made("4712", At).Joined(At.AddMinutes(3), "http://100.64.0.9:8765/");

        Assert.IsFalse(refused.IsUnjoined);
        Assert.IsTrue(made.IsUnjoined && made.IsMade);
        Assert.IsTrue(unknown.IsUnjoined && !unknown.IsMade);
        Assert.IsFalse(joined.IsUnjoined);
        Assert.AreEqual("http://100.64.0.9:8765/", joined.Hub);
        CollectionAssert.AreEqual(new[] { "fleet-2", "fleet-3" },
                                  BuildRecord.NamesInUse([refused, made, unknown, joined], At.AddMinutes(30), life).ToList());
        Assert.AreEqual(0, BuildRecord.NamesInUse([made, unknown], At.AddHours(2), life).Count);
    }

    /// <summary>**The wait before a retry makes its count of reads, and ends at the first answer only when it waits for
    /// one**: a hub that restarted is tried again at once, and a busy hub (which answers while it is busy) is given its
    /// whole count. A page that ends the wait ends it at once.</summary>
    [TestMethod]
    public async Task The_wait_before_a_retry_reads_its_count_and_ends_at_an_answer_only_when_it_waits_for_one()
    {
        async Task<int> Reads(InstallRetry.Wait wait, int answersAt, bool canceled = false)
        {
            var reads = 0;
            await InstallRetry.WaitAsync(wait, () => Task.CompletedTask, () => Task.FromResult(++reads >= answersAt), () => canceled);
            return reads;
        }
        Assert.AreEqual(2, await Reads(new InstallRetry.Wait.Reads(20, true), 2));
        Assert.AreEqual(8, await Reads(new InstallRetry.Wait.Reads(8, false), 1));
        Assert.AreEqual(0, await Reads(new InstallRetry.Wait.Nothing(), 1));
        Assert.AreEqual(0, await Reads(new InstallRetry.Wait.Reads(8, false), 1, canceled: true));
    }
}
