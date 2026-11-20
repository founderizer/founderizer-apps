using System;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Remote.Tests;

/// <summary>The run of piece L1's done-when line: 30 minutes, a line every 20 seconds, on one connection.</summary>
[TestClass]
[TestCategory("Long")]
public sealed class LongRunTests
{
    /// <summary>
    /// A hub install's longest step runs for many minutes on one connection. The scratch sshd asks the client to answer
    /// every 10 quiet seconds (ClientAliveInterval) and is set to make new keys every 5 minutes (RekeyLimit), so that
    /// the run meets key exchanges that the server starts. Bugs: a client that does not answer the server's keep-alive and is cut
    /// after 30 s; a key exchange in the middle of a program that breaks the channel; lines held back until the end.
    /// Runs only with FOUNDERIZER_REMOTE_LONG=1, alone, because it takes 30 minutes; FOUNDERIZER_REMOTE_LONG_MINUTES
    /// makes it shorter, for a check of the test itself.
    /// </summary>
    [TestMethod]
    public async Task A_run_of_30_minutes_keeps_its_connection()
    {
        if (Environment.GetEnvironmentVariable("FOUNDERIZER_REMOTE_LONG") != "1")
            Assert.Inconclusive("The 30-minute run needs FOUNDERIZER_REMOTE_LONG=1.");
        var minutes = int.TryParse(Environment.GetEnvironmentVariable("FOUNDERIZER_REMOTE_LONG_MINUTES"), out var given) ? given : 30;
        var count = minutes * 3;
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine],
            extra: "ClientAliveInterval 10\nClientAliveCountMax 3\nRekeyLimit default 5m");
        var started = DateTime.UtcNow;
        var arrivals = new System.Collections.Concurrent.ConcurrentQueue<TimeSpan>();
        var (result, lines) = await app.Run(sshd.Target,
            $"i=0; while [ $i -lt {count} ]; do echo \"line $i\"; i=$((i+1)); sleep 20; done; echo done",
            also: _ => arrivals.Enqueue(DateTime.UtcNow - started), seconds: (minutes + 10) * 60,
            limit: TimeSpan.FromMinutes(minutes + 5));
        Console.WriteLine($"ended after {DateTime.UtcNow - started}; {lines.Count} lines; failure {result.Failure}; status {result.ExitStatus}");
        Assert.IsNull(result.Failure);
        Assert.AreEqual(0, result.ExitStatus);
        Assert.AreEqual(count + 1, lines.Count);
        Assert.AreEqual("done", lines[^1]);
        var times = arrivals.ToArray();
        Assert.IsTrue(times[^1] >= TimeSpan.FromMinutes(minutes - 0.5), times[^1].ToString());
        for (var at = 0; at < count; at++)
            Assert.IsTrue(times[at] < TimeSpan.FromSeconds(20 * at + 15), $"line {at} came at {times[at]}, not as it was printed");
    }
}
