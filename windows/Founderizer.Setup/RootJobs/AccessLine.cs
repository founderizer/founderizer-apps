using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Owner.Reads;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.RootJobs;

/// <summary>**Which fleet servers have the owner's access line, as the owner's computer knows it** (the Mac's
/// OwnerAccessMarks): for each server, the fingerprint of the key whose line this PC put in root's <c>authorized_keys</c>
/// there. A mark is kept by the hub's address, the server's name and the server's private address: the fleet gives a new
/// server the name of a server that it removed, and the new server has another private address, so it gets its line too.
/// The Mac also knows a mark of before 14 November 2026 (no address); a PC never wrote one.</summary>
public sealed class AccessMarks(Dictionary<string, string> all)
{
    /// <summary>The name of each mark and the fingerprint of its key: what the app keeps.</summary>
    public IReadOnlyDictionary<string, string> All => all;

    public AccessMarks() : this(new Dictionary<string, string>(StringComparer.Ordinal)) { }

    /// <summary>The name of one server's mark: the hub's address, the server's name and its private address.</summary>
    public static string Name(string machine, string? address, Uri hub) => $"{hub.AbsoluteUri} {machine} {address ?? ""}";

    /// <summary>The line of the key of this fingerprint is on this server.</summary>
    public bool InPlace(string machine, string? address, Uri hub, string fingerprint) =>
        all.TryGetValue(Name(machine, address, hub), out var kept) && kept == fingerprint;

    /// <summary>Keeps the mark of this key for this server, in place of every earlier mark of a server of this name on this
    /// hub (the marks of other addresses): there is one mark for each name.</summary>
    public void Keep(string fingerprint, string machine, string? address, Uri hub)
    {
        var prefix = $"{hub.AbsoluteUri} {machine} ";
        foreach (var name in all.Keys.Where(k => k.StartsWith(prefix, StringComparison.Ordinal)).ToList()) all.Remove(name);
        all[Name(machine, address, hub)] = fingerprint;
    }
}

/// <summary>**The owner's access key on the fleet's servers, put there by itself** (the Mac's OwnerAccess and
/// OwnerAccessModel): the public half of the key that is in each copy of the fleet must be a line of root's
/// <c>authorized_keys</c> on each Linux server before the owner's computer is lost. The key itself is another piece's: this
/// type takes its public line and its fingerprint, both plain text, and never holds the key.</summary>
public sealed partial class AccessLine(RootRecords records)
{
    /// <summary>What <see cref="Program"/> prints once the key's line is in the file.</summary>
    public const string InPlaceWord = "founderizer-owner-access-in-place";
    /// <summary>Where root keeps the keys that it logs in with, on every system that the installers take.</summary>
    public const string RootKeys = "/root/.ssh/authorized_keys";
    /// <summary>The least time between two rounds over the servers, in seconds (the Mac's <c>every</c>).</summary>
    public const double Every = 900;
    /// <summary>The time limit of the program (the Mac's <c>timeout: 60</c>).</summary>
    public static readonly TimeSpan RunLimit = TimeSpan.FromSeconds(60);

    /// <summary>This start's tries of each server by its mark's name: a server that cannot be reached as root is tried again
    /// after ten minutes, six times at most, and then left until the next start (the Mac's <c>tries</c>).</summary>
    private readonly Dictionary<string, JobTries> tries = new(StringComparer.Ordinal);

    /// <summary>**The program that puts the key's public half on one Linux server of the fleet**, for root there (the Mac's
    /// <c>OwnerAccess.install</c>, byte for byte): its line goes into root's <c>authorized_keys</c>, once, after a file that
    /// may not end with a new line, and nothing else in the file changes. It prints <see cref="InPlaceWord"/> when the line
    /// is there, also when it was there before. **Only a line of the fleet's access key** ("<c>ssh-ed25519 AAAA…
    /// founderizer-owner-access</c>", <see cref="IsAccessLine"/>): the Mac makes the line from the key itself, while the PC
    /// gets it as text, and a new line in it would be a second line of root's keys, a "-" at its start an option of
    /// <c>grep</c>. Any other text throws, and no program is made.</summary>
    public static string Program(string publicLine, string file = RootKeys)
    {
        if (!IsAccessLine(publicLine)) throw new ArgumentException("This is not a line of the fleet's access key.", nameof(publicLine));
        string line = InstallPlan.Quote(publicLine), keys = InstallPlan.Quote(file);
        return $"f={keys}; umask 077; mkdir -p \"$(dirname \"$f\")\"; touch \"$f\"; "
               + $"grep -qxF {line} \"$f\" || {{ [ -z \"$(tail -c1 \"$f\")\" ] || echo >> \"$f\"; "
               + $"printf '%s\\n' {line} >> \"$f\"; }}; grep -qxF {line} \"$f\" && echo {InPlaceWord}";
    }

    /// <summary>Whether the program's output says that the line is in place.</summary>
    public static bool IsInPlace(string output) => RootJob.Lines(output).Any(l => l == InPlaceWord);

    /// <summary>Whether this text is one line of the fleet's access key, as the Mac's <c>publicLine</c> makes it: its kind,
    /// its base64, its comment, one space between them, and nothing else.</summary>
    public static bool IsAccessLine(string? text) => text is not null && AccessLineShape().IsMatch(text);

    [GeneratedRegex(@"\Assh-ed25519 [A-Za-z0-9+/]+=* founderizer-owner-access\z", RegexOptions.CultureInvariant)]
    private static partial Regex AccessLineShape();

    /// <summary>**One round** over the hub's servers: the hub's own server and each Linux server that has not got its line
    /// yet. <paramref name="publicLine"/> and <paramref name="fingerprint"/> are of the fleet's access key: a line that is not
    /// one throws before any server is reached (<see cref="Program"/>). Each server is reached only with
    /// <see cref="ServerRecords.RootConnectionAsync"/>, at an address that this PC's own Tailscale names as that server
    /// (<paramref name="tailscaleStatus"/>); <paramref name="run"/> runs one program there as root. A cancel ends it
    /// between two servers.</summary>
    public async Task RoundAsync(Uri hub, IReadOnlyList<ServerEntry> servers, string publicLine, string fingerprint,
                                 ServerRecords connections, string? tailscaleStatus,
                                 Func<InstallTarget, string, TimeSpan, Task<string>> run, double now, CancellationToken cancel = default)
    {
        var program = Program(publicLine);
        foreach (var server in servers.Where(s => s.Hub || s.Kind == "linux"))
        {
            if (cancel.IsCancellationRequested) return;
            var mark = AccessMarks.Name(server.Name, server.Address, hub);
            if (records.Marks().InPlace(server.Name, server.Address, hub, fingerprint)) continue;
            if (tries.TryGetValue(mark, out var before) && !before.IsDue(now)) continue;
            try
            {
                var output = await run(await connections.RootConnectionAsync(server, tailscaleStatus).ConfigureAwait(false), program, RunLimit)
                    .ConfigureAwait(false);
                if (!IsInPlace(output)) throw new InvalidOperationException("the line is not in the file");
                var marks = records.Marks();
                marks.Keep(fingerprint, server.Name, server.Address, hub);
                records.KeepMarks(marks);
                tries.Remove(mark);
            }
            catch (Exception e) when (e is not OutOfMemoryException)
            {
                tries[mark] = JobTries.Failed(tries.GetValueOrDefault(mark), now, RootJob.Describe(e));
            }
        }
    }
}
