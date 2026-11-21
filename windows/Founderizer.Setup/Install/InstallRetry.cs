using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Setup.Install;

/// <summary>**An install that tries again by itself after an error that passes** (the Mac's InstallRetry, the owner's
/// "Yes, build it" of 16 November 2026): one table, by the stop's kind and then its cause (<see cref="Decision"/>);
/// anything not in it stops as before.</summary>
public sealed record InstallRetry(InstallRetry.Wait Waits, bool FreshCode = false)
{
    /// <summary>What a retry waits for before the install runs again: nothing, or a count of reads of the hub, one every
    /// <see cref="ReadEvery"/> seconds (<c>UntilAnswer</c>: the first read that the hub answers ends the wait).</summary>
    public abstract record Wait
    {
        private Wait() { }
        public sealed record Nothing : Wait;
        public sealed record Reads(int Count, bool UntilAnswer) : Wait;
    }

    /// <summary>The retries after the owner's press: three tries in all.</summary>
    public const int Most = 2;
    /// <summary>The pace of <see cref="Wait.Reads"/>.</summary>
    public const double ReadEvery = ServerCheck.WaitEvery;
    /// <summary>A join's retry keeps its code only while the code has this many seconds left.</summary>
    public const double CodeLeftAtLeast = 600;

    /// <summary>Whether a join's next try runs the code that it has, by the code's own end at <paramref name="now"/>.</summary>
    public static bool KeepsCode(double expiresAt, double now) => expiresAt - now >= CodeLeftAtLeast;

    /// <summary>The steps of the hub's plan that run again after SSH lost the server.</summary>
    internal static readonly IReadOnlySet<string> AgainAfterALostServer = new HashSet<string> { "code", "plan" };

    /// <summary>**Whether the install runs again**, and what it waits for first; null: it stops as before.
    /// <paramref name="tries"/>: the tries of this press, the one that just stopped included.</summary>
    public static InstallRetry? Decision(InstallStop stop, InstallCause? cause, InstallJob job, string? step, int tries,
                                        bool needsNetworkKey, bool usedSudoPassword)
    {
        if (tries > Most || needsNetworkKey || usedSudoPassword) return null;
        switch (stop)
        {
            case InstallStop.InstallerStopped:
                return cause switch
                {
                    InstallCause.HubBusy when job == InstallJob.Join => new(new Wait.Reads(8, false)),
                    InstallCause.ServerNameUnread when job == InstallJob.Join => new(new Wait.Reads(4, false)),
                    InstallCause.JoinCodeExpired when job == InstallJob.Join => new(new Wait.Nothing(), FreshCode: true),
                    InstallCause.HubNoAnswer when job == InstallJob.Join => new(new Wait.Reads(20, true)),
                    InstallCause.PrivateNetwork or InstallCause.Packages or InstallCause.AgentProgram => new(new Wait.Nothing()),
                    InstallCause.CodeNotFetched when job == InstallJob.Hub => new(new Wait.Nothing()),
                    _ => null,
                };
            case InstallStop.ServerUnreached:
                return step is not null && AgainAfterALostServer.Contains(step) ? new(new Wait.Nothing()) : null;
            case InstallStop.HubUnreached when job == InstallJob.Join:
                return new(new Wait.Reads(20, true));
            default:
                return null;
        }
    }

    /// <summary>What a decision reads of the error that ended a try.</summary>
    public sealed record Stopped(InstallStop Stop, InstallCause? Cause, bool NeedsNetworkKey);

    /// <summary>The stop's kind (<paramref name="networkKeyRefused"/>: Tailscale refused a key, which this library does
    /// not know), the installer's own cause, and whether the stop waits for the owner's Tailscale key.</summary>
    public static Stopped StoppedBy(Exception error, bool networkKeyRefused, bool authKeyEmpty)
    {
        var says = error is InstallError install ? install.Description : error.Message;
        return new Stopped(networkKeyRefused ? InstallStop.NetworkKeyRefused : InstallStops.Of(error), InstallCauses.Of(error),
                           networkKeyRefused || (InstallPlan.NeedsNetworkKey(says) && authKeyEmpty));
    }

    /// <summary>**The wait before a retry**: <paramref name="pause"/> waits one step of <see cref="ReadEvery"/>,
    /// <paramref name="read"/> reads the hub and says whether it answered, <paramref name="canceled"/> ends the wait at
    /// once.</summary>
    public static async Task WaitAsync(Wait wait, Func<Task> pause, Func<Task<bool>> read, Func<bool> canceled)
    {
        if (wait is not Wait.Reads reads) return;
        for (var n = 0; n < reads.Count; n++)
        {
            await pause();
            if (canceled()) return;
            if (await read() && reads.UntilAnswer) return;
        }
    }

    /// <summary>**The step that a run of a plan stopped at**, noted where the installer reports it.</summary>
    public sealed class FailedStep
    {
        private readonly Lock gate = new();
        private string? step;

        public void Note(InstallProgress progress)
        {
            if (progress.State != ProgressState.Failed) return;
            lock (gate) step = progress.Step;
        }

        public string? Value
        {
            get { lock (gate) return step; }
        }
    }

    /// <summary>The name that a retry keeps in the record: the cause when the installer gave one, else the stop's kind.</summary>
    public static string Name(InstallStop stop, InstallCause? cause) => cause?.Name() ?? stop.Name();
}
