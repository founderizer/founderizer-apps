using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Owner.Reads;
using Founderizer.Remote;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.RootJobs;

// The root jobs of the owner's computer (windows-app-plan-v2.md, piece L6): the steps that the owner's Mac runs by
// itself as root on the fleet's servers, over the SSH connection that it already has to each of them (the Mac's
// OwnerAccessSweep.swift: OwnerAccessModel and ServerHardeningModel). This file is their engine, the Mac's
// ServerHardening.step, .turn and .Memory and the Mac's VaultTries: the round, the two-rounds rule, the tries and their
// record. **Nothing of it is on a page**: what a run said goes to the log only, and only the app's own programs run as
// root (rule 12): no program's text comes from the hub or from a server.

/// <summary>**The tries of one automatic step** (the Mac's VaultTries): how many failed in a row, when the last one did,
/// and why. A step that failed is tried again after ten minutes, at most six times in a row.</summary>
public sealed record JobTries(int Failures, double Last, string Reason)
{
    /// <summary>The wait after a failure, in seconds.</summary>
    public const double Wait = 600;
    /// <summary>The most failures in a row.</summary>
    public const int Most = 6;

    /// <summary>The step failed <see cref="Most"/> times in a row: it waits for good (or for the next start of the app,
    /// for the tries that are not kept).</summary>
    public bool GivenUp => Failures >= Most;

    public bool IsDue(double now) => !GivenUp && now - Last >= Wait;

    /// <summary>One more failure, after the ones before it.</summary>
    public static JobTries Failed(JobTries? earlier, double now, string reason) => new((earlier?.Failures ?? 0) + 1, now, reason);
}

/// <summary>What one round reads of one server for a sweep that settles it (the Mac's ServerHardening.Reading).</summary>
public enum SweepReading
{
    /// <summary>Nothing that counts: not a server of this sweep, no current reading, a reading that carries neither fact,
    /// the hour after its join or the hub's claim, or an open job of its service.</summary>
    Unread,
    /// <summary>What the sweep puts in place holds.</summary>
    Holds,
    /// <summary>What the sweep puts in place is missing.</summary>
    Faulty,
}

/// <summary>**What the owner's computer keeps of one server for a sweep that settles it**, from one start of the app to
/// the next (the Mac's ServerHardening.Memory): the runs in a row that did not settle it, the time of the last one, what
/// it said, and whether it is settled. A settled server is never acted on again.</summary>
public sealed record SweepMemory(int Failures = 0, double Last = 0, string Reason = "", bool Settled = false)
{
    public JobTries? Tries => Failures == 0 ? null : new JobTries(Failures, Last, Reason);

    /// <summary>One more run that did not settle the server.</summary>
    public SweepMemory Failed(double now, string reason)
    {
        var next = JobTries.Failed(Tries, now, reason);
        return this with { Failures = next.Failures, Last = next.Last, Reason = next.Reason };
    }
}

/// <summary>What one round does with one server (the Mac's ServerHardening.Step).</summary>
public enum SweepStep
{
    /// <summary>Nothing: the reading says nothing, or the server is settled.</summary>
    Nothing,
    /// <summary>It holds: the server is settled.</summary>
    Settle,
    /// <summary>The fault, in the first round that reads it: the next round decides.</summary>
    Seen,
    /// <summary>The fault again, but its next try is not due yet, or all six were spent.</summary>
    Wait,
    /// <summary>The fault in a second round in a row, and a try is due: the program runs.</summary>
    Run,
}

/// <summary>What one run of a sweep's program came to (the Mac's ServerHardening.Outcome).</summary>
public abstract record SweepOutcome
{
    private SweepOutcome() { }

    /// <summary>It holds now.</summary>
    public sealed record Holds : SweepOutcome;
    /// <summary>The server is left as the join leaves it, by the server's own choice (the hardening: no account has an SSH
    /// key).</summary>
    public sealed record LeftAsItIs : SweepOutcome;
    /// <summary>Anything else of a program that started, with the words for the log.</summary>
    public sealed record Failed(string Said) : SweepOutcome;
    /// <summary>The output reads as a program that did not start: nothing ran on the server.</summary>
    public sealed record NotStarted(string Said) : SweepOutcome;
}

/// <summary>What one round did with one server: whether it read the fault (the next round's <c>seenBefore</c>), and the
/// lines for the log, which go nowhere else (the Mac's Turn).</summary>
public sealed record JobTurn(bool Seen, IReadOnlyList<string> Lines)
{
    public static readonly JobTurn None = new(false, []);
    public static readonly JobTurn SeenOnly = new(true, []);
}

/// <summary>One round's turn of a sweep that settles a server, with what the owner's computer keeps of that server after
/// it and this start's tries that ran nothing there.</summary>
public sealed record SweepTurn(JobTurn Turn, SweepMemory Memory, JobTries? Unreached);

/// <summary>**Why a step ran nothing on a server**: the Mac's ServerRecords.Unreached, a try that is never kept.</summary>
public sealed class RootUnreached(string reason) : Exception(reason)
{
    /// <summary>The owner's computer keeps no connection to the server, and the fleet's record of it is known and is none.</summary>
    public static RootUnreached NoConnection() => new("noConnection");
    /// <summary>It keeps none, and a page of the hub that holds the fleet's record of it did not answer.</summary>
    public static RootUnreached RecordNotRead() => new("recordNotRead");
    /// <summary>This PC's Tailscale does not name the connection's address as this server: no step ran there.</summary>
    public static RootUnreached NotThatServer() => new("this PC's Tailscale does not name the connection's address as this server");
}

/// <summary>**The engine of the root jobs** (the Mac's ServerHardening.step and .turn, which its other sweeps share).</summary>
public static class RootJob
{
    /// <summary>The hub's <c>JOIN_GRACE</c>: the hour after a join, and after the hub's claim, in which the join or the
    /// hub's install still updates and hardens the server, so a reading of that time says nothing.</summary>
    public const double JoinGrace = 3600;

    /// <summary>**The two-rounds rule**: a fault runs the program only when the round before read it too, and a try is
    /// due. <paramref name="unreached"/>: this start's tries that ran nothing on the server, which are not in
    /// <paramref name="memory"/>.</summary>
    public static SweepStep Step(SweepReading reading, SweepMemory memory, bool seenBefore, double now, JobTries? unreached = null)
    {
        if (memory.Settled) return SweepStep.Nothing;
        switch (reading)
        {
            case SweepReading.Unread: return SweepStep.Nothing;
            case SweepReading.Holds: return SweepStep.Settle;
            default:
                if (!seenBefore) return SweepStep.Seen;
                if (unreached is { } tries && !tries.IsDue(now)) return SweepStep.Wait;
                return memory.Tries is not { } kept || kept.IsDue(now) ? SweepStep.Run : SweepStep.Wait;
        }
    }

    /// <summary>**One round's work for one server**: <see cref="Step"/>, and for a run the connection, the program and what
    /// each came to. <paramref name="connection"/> gives the connection to the server or throws; <paramref name="run"/>
    /// runs the program there as root and gives its output (<see cref="RootCall.RunAsync"/>), or throws when the call
    /// could not start.
    ///
    /// **A try is a kept run only when the program started on the server**, which its own first line says
    /// (<paramref name="started"/>). A try that ran nothing there is counted in the turn's <c>Unreached</c> and never in
    /// its memory: no connection to the server, a call that did not start, or an output that reads as a program that did
    /// not start (a host key that is not on record, a refused login, nothing that answered, <c>sudo</c> that asked for a
    /// password). Nothing ends that count in a start of the app: six are the most for one start. A run that started and
    /// did not settle the server is counted in the memory, also when it did not end: six such runs are the most for
    /// good.</summary>
    public static async Task<SweepTurn> TurnAsync(SweepReading reading, SweepMemory memory, JobTries? unreached, bool seenBefore,
                                                  double now, string started, Func<string, SweepOutcome> outcome,
                                                  string settledLine, Func<Task<InstallTarget>> connection,
                                                  Func<InstallTarget, Task<string>> run)
    {
        switch (Step(reading, memory, seenBefore, now, unreached))
        {
            case SweepStep.Nothing: return new SweepTurn(JobTurn.None, memory, unreached);
            case SweepStep.Seen or SweepStep.Wait: return new SweepTurn(JobTurn.SeenOnly, memory, unreached);
            case SweepStep.Settle: return new SweepTurn(JobTurn.None, memory with { Settled = true }, unreached);
        }
        var lines = new List<string>();
        string? nothingRan = null;
        try
        {
            var output = await run(await connection().ConfigureAwait(false)).ConfigureAwait(false);
            lines.AddRange(Lines(output).Where(l => l.Length > 0 && l != started).TakeLast(6));
            switch (outcome(output))
            {
                case SweepOutcome.Holds or SweepOutcome.LeftAsItIs: memory = memory with { Settled = true }; break;
                case SweepOutcome.Failed failed: memory = memory.Failed(now, failed.Said); break;
                case SweepOutcome.NotStarted missed: nothingRan = missed.Said; break;
            }
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            nothingRan = Describe(e);
        }
        if (nothingRan is not null)
        {
            var tries = JobTries.Failed(unreached, now, nothingRan);
            if (tries.GivenUp)
                lines.Add($"nothing ran there in {tries.Failures} tries ({tries.Reason}): left until this app starts again");
            return new SweepTurn(new JobTurn(true, lines), memory, tries);
        }
        if (memory.Settled) lines.Add(settledLine);
        else if (memory.Tries?.GivenUp == true) lines.Add($"left after {memory.Failures} tries ({memory.Reason})");
        return new SweepTurn(new JobTurn(true, lines), memory, unreached);
    }

    /// <summary>The words of a try that ran nothing, for the log: the Mac's <c>String(describing: error)</c>.</summary>
    internal static string Describe(Exception e) => e.Message;

    /// <summary>**The lines of a program's output, as the Mac reads them**: split at each line end, empty pieces left out,
    /// each without the spaces and tabs at its ends (Swift's <c>split(whereSeparator: \.isNewline)</c> and
    /// <c>trimmingCharacters(in: .whitespaces)</c>).</summary>
    internal static IReadOnlyList<string> Lines(string output) =>
        output.Split(['\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'], StringSplitOptions.RemoveEmptyEntries)
              .Select(Trimmed).ToList();

    /// <summary>A text without the spaces and tabs at its ends (Swift's <c>CharacterSet.whitespaces</c>: the tab and the
    /// spaces of Unicode).</summary>
    internal static string Trimmed(string text)
    {
        static bool Space(char c) => c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
        var start = 0;
        var end = text.Length;
        while (start < end && Space(text[start])) start++;
        while (end > start && Space(text[end - 1])) end--;
        return text[start..end];
    }

    /// <summary>The first <paramref name="count"/> characters of a text as Swift counts them (its <c>prefix</c>: whole
    /// characters, never half of one).</summary>
    internal static string Prefix(string text, int count)
    {
        var info = new StringInfo(text);
        return info.LengthInTextElements <= count ? text : info.SubstringByTextElements(0, count);
    }
}

/// <summary>**One root program on one server, over the app's own key** (the Mac's <c>SSHRun.run</c> of
/// <c>CentralVaultRemote.arguments</c>): the host key must be on record (<see cref="HostKeyRule.Known"/>, the Mac's
/// <c>StrictHostKeyChecking=yes</c>: a server that this PC has not met is refused, and nothing is sent), and the program
/// goes as root through <c>sudo -n</c> for a user that is not root. The output is the program's lines of both streams in
/// the order they came, at most 1 MiB, as the Mac's <c>LocalShell</c> gives them. A call that IRemote refused to make (the
/// app's key not in the box, a target that SSH cannot take) throws, as the Mac's <c>ssh</c> that did not start.</summary>
public static class RootCall
{
    /// <summary>The most characters of an output that are kept (the Mac's 1 MiB of LocalShell).</summary>
    public const int MaxOutput = 1_048_576;

    /// <summary>What one call gave: the program's lines, and the way that the call failed, or null.</summary>
    public sealed record Answer(string Output, RemoteFailure? Failure);

    public static async Task<Answer> AnswerAsync(IRemote remote, InstallTarget target, string program, TimeSpan limit,
                                                 Runs runs = Runs.Root, CancellationToken cancel = default)
    {
        var text = new StringBuilder();
        var gate = new object();
        var call = new RemoteCall(target.Remote, InstallPlan.Command(program, target, runs), null, new RemoteLogin.AppKey(),
                                  HostKeyRule.Known, RemoteCall.ConnectTimeout) { Limit = limit };
        var result = await remote.RunAsync(call, line =>
        {
            lock (gate)
                if (text.Length < MaxOutput) text.Append(line).Append('\n');
        }, cancel).ConfigureAwait(false);
        lock (gate) return new Answer(text.ToString(), result.Failure);
    }

    /// <summary>The output, with the way a call failed as its last line, where the Mac's output has <c>ssh</c>'s own
    /// words: a job reads the program's first line to know whether it started (<see cref="RootJob.TurnAsync"/>).</summary>
    public static async Task<string> RunAsync(IRemote remote, InstallTarget target, string program, TimeSpan limit,
                                              Runs runs = Runs.Root, CancellationToken cancel = default)
    {
        var answer = await AnswerAsync(remote, target, program, limit, runs, cancel).ConfigureAwait(false);
        return answer.Failure is { } failure ? answer.Output + failure + "\n" : answer.Output;
    }
}

/// <summary>**What the owner's computer keeps of the root jobs between two starts of the app** (the Mac keeps it in its
/// defaults: <c>serverHardening</c>, <c>serverBrowser</c>, <c>ownerAccessInPlace</c>): for each kind of job, the record
/// of each server by its name (the hub's address, the server's name and its private address). One file,
/// <c>records/root-jobs.json</c> in the app's folder, written whole at each change (a new file, then moved over the old
/// one). It holds no secret: counts, times, the last reason of a run, and the fingerprint of a public key. A file that does
/// not read is an empty record, as the Mac's defaults that give nothing: each server then has at most six more tries; and
/// so is a member that is null.
///
/// Safe from any thread, and from two objects of one folder in this process (the round's and the access line's): they
/// share one lock, and each reads the file again when another wrote it since it read it, or the file changed on disk, so
/// none writes over the others' records. A record that could not be written stays in this object's memory for this start:
/// a server whose record the disk does not take still has six tries at most.</summary>
public sealed class RootRecords
{
    public const string Hardening = "hardening", Browser = "browser";

    /// <summary>One lock and one count of writes for each file in this process (as <c>HostKeys</c> keeps one lock).</summary>
    private sealed class Shared
    {
        public long Writes;
    }

    private static readonly ConcurrentDictionary<string, Shared> Files = new(StringComparer.Ordinal);

    private readonly string file;
    private readonly Shared gate;
    private RootFile? kept;
    private long keptWrites;
    private (long Length, DateTime Written)? keptStamp;

    public RootRecords(string appFolder)
    {
        file = Path.Combine(Path.GetFullPath(appFolder), "records", "root-jobs.json");
        gate = Files.GetOrAdd(file, _ => new Shared());
    }

    /// <summary>**The name of a server's records**: the hub's address, the server's name and its private address, so a
    /// new server with the name of an earlier one starts with nothing kept (the Mac's <c>memoryName</c>).</summary>
    public static string NameOf(Uri hub, ServerEntry server) => $"{hub.AbsoluteUri} {server.Name} {server.Address ?? ""}";

    /// <summary>What is kept of one server for the sweep of <paramref name="kind"/>; a new memory where nothing is.</summary>
    public SweepMemory Sweep(string kind, string name)
    {
        lock (gate)
            return Loaded().Sweeps.TryGetValue(kind, out var all) && all.TryGetValue(name, out var memory) ? memory : new SweepMemory();
    }

    public void KeepSweep(string kind, string name, SweepMemory memory)
    {
        lock (gate)
        {
            var all = Loaded();
            if (!all.Sweeps.TryGetValue(kind, out var sweep)) all.Sweeps[kind] = sweep = new Dictionary<string, SweepMemory>(StringComparer.Ordinal);
            if (sweep.TryGetValue(name, out var before) && before == memory) return;
            sweep[name] = memory;
            Save(all);
        }
    }

    public BrowserMemory BrowserOf(string name)
    {
        lock (gate) return Loaded().Browser.TryGetValue(name, out var memory) ? memory : new BrowserMemory();
    }

    public void KeepBrowser(string name, BrowserMemory memory)
    {
        lock (gate)
        {
            var all = Loaded();
            if (all.Browser.TryGetValue(name, out var before) && before == memory) return;
            all.Browser[name] = memory;
            Save(all);
        }
    }

    /// <summary>The marks of the owner's access line (<see cref="AccessMarks"/>): mark name and fingerprint.</summary>
    public AccessMarks Marks()
    {
        lock (gate) return new AccessMarks(new Dictionary<string, string>(Loaded().Access, StringComparer.Ordinal));
    }

    public void KeepMarks(AccessMarks marks)
    {
        lock (gate)
        {
            var all = Loaded();
            all.Access.Clear();
            foreach (var (name, fingerprint) in marks.All) all.Access[name] = fingerprint;
            Save(all);
        }
    }

    /// <summary>The records, read again when another object of this file wrote it since this one read it, or the file is not
    /// the one that this object read or wrote. Under the lock.</summary>
    private RootFile Loaded()
    {
        var stamp = Stamp(file);
        if (kept is not null && keptWrites == gate.Writes && stamp == keptStamp) return kept;
        RootFile? read = null;
        if (KeptBytes(file) is { } data)
        {
            try { read = JsonSerializer.Deserialize(data, RootJson.Default.RootFile); }
            catch (JsonException) { }
        }
        kept = Clean(read);
        keptWrites = gate.Writes;
        keptStamp = stamp;
        return kept;
    }

    /// <summary>The records of a file, where a member that is null, and a server's record that is null, is no record.</summary>
    private static RootFile Clean(RootFile? read)
    {
        var all = new RootFile();
        if (read is null) return all;
        if (read.Sweeps is not null)
            foreach (var (kind, servers) in read.Sweeps)
            {
                if (servers is null) continue;
                var sweep = new Dictionary<string, SweepMemory>(StringComparer.Ordinal);
                foreach (var (name, memory) in servers)
                    if (memory is not null) sweep[name] = memory with { Reason = memory.Reason ?? "" };
                all.Sweeps[kind] = sweep;
            }
        if (read.Browser is not null)
            foreach (var (name, memory) in read.Browser)
                if (memory is not null) all.Browser[name] = memory with { Digest = memory.Digest ?? "", Reason = memory.Reason ?? "" };
        if (read.Access is not null)
            foreach (var (name, fingerprint) in read.Access)
                if (fingerprint is not null) all.Access[name] = fingerprint;
        return all;
    }

    /// <summary>The file's length and time of its last write, or null where there is none to read.</summary>
    private static (long Length, DateTime Written)? Stamp(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? (info.Length, info.LastWriteTimeUtc) : null;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    /// <summary>The largest file that is read: a record of a server is about 200 bytes.</summary>
    public const int LargestFile = 4 * 1024 * 1024;

    /// <summary>The file's bytes, only when it is a regular file of at most <see cref="LargestFile"/> bytes.</summary>
    private static byte[]? KeptBytes(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || info.Length > LargestFile ||
                (info.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory | FileAttributes.Device)) != 0) return null;
            return File.ReadAllBytes(path);
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    private void Save(RootFile all)
    {
        try
        {
            var folder = Path.GetDirectoryName(file)!;
            if (OperatingSystem.IsWindows()) Directory.CreateDirectory(folder);
            else Directory.CreateDirectory(folder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var temporary = Path.Combine(folder, "." + Path.GetFileName(file) + ".new");
            var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var stream = new FileStream(temporary, options))
            {
                JsonSerializer.Serialize(stream, all, RootJson.Default.RootFile);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, file, overwrite: true);
            keptWrites = ++gate.Writes;
            keptStamp = Stamp(file);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

/// <summary>The file of <see cref="RootRecords"/>.</summary>
public sealed class RootFile
{
    public Dictionary<string, Dictionary<string, SweepMemory>> Sweeps { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, BrowserMemory> Browser { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, string> Access { get; set; } = new(StringComparer.Ordinal);
}

/// <summary>The file form of the root jobs' records: members in small letters with underscores.</summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
                             GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(RootFile))]
internal sealed partial class RootJson : JsonSerializerContext;

/// <summary>**One server of the hub's list for a round**, with the two facts of its reading that the list of the
/// setup's reads leaves out (owner API 1.224): the agents' browser parts, and whom each agent runs as
/// (<see cref="BrowserParts.Read"/>, <see cref="AgentUsers.Read"/>, from the row's <c>reading.browser</c> and
/// <c>reading.agents</c>).</summary>
public sealed record RootServer(ServerEntry Entry, BrowserParts? Browser = null, AgentUsers? Users = null)
{
    /// <summary>The server with the two facts read from its row as the hub sent it.</summary>
    public static RootServer Of(ServerEntry entry, JsonElement? row)
    {
        JsonElement? reading = row is { ValueKind: JsonValueKind.Object } r && r.TryGetProperty("reading", out var inner) ? inner : null;
        return new RootServer(entry, BrowserParts.Read(Member(reading, "browser")), AgentUsers.Read(Member(reading, "agents")));
    }

    internal static JsonElement? Member(JsonElement? value, string name) =>
        value is { ValueKind: JsonValueKind.Object } o && o.TryGetProperty(name, out var member) ? member : null;
}

/// <summary>**What one round over the hub's servers reads**: the hub, its clock and its newest join (GET /ui/servers),
/// its servers, and from a whole state of the hub its agents and their tasks (null when this round has none: then the
/// browser parts wait, as on the Mac).</summary>
public sealed record RootFleet(Uri Hub, double Time, JoinState? Join, IReadOnlyList<RootServer> Servers,
                               IReadOnlyList<BrowserAgent>? Agents = null, IReadOnlyList<BrowserTask>? Tasks = null);

/// <summary>**The round of the root jobs on each Linux server, by itself** (the Mac's ServerHardeningModel): every five
/// minutes at most, for each server that the join's hardening is for, that hardening's turn and then the browser parts'
/// turn, each with its own record and its own count. A fault, or a want of the browser parts, runs its program only when
/// the round before read the same (the two-rounds rule), so this object keeps what the last round read and this start's
/// tries that ran nothing on a server; the counts of the runs are in <see cref="RootRecords"/>. The jobs of the Mac's list
/// that come later (the memory limit, the restart, the system libraries) are each a turn more here (the plan's L15).
///
/// One round at a time: the caller starts the next after this one ended.</summary>
public sealed class RootRound(RootRecords records)
{
    /// <summary>The least time between two rounds, in seconds (the Mac's <c>every</c>).</summary>
    public const double Every = 300;
    /// <summary>The time limit of a hardening run and of a browser run (the Mac's <c>timeout: 120</c>).</summary>
    public static readonly TimeSpan RunLimit = TimeSpan.FromSeconds(120);

    private const string BrowserMark = "browser ";
    private HashSet<string> seen = new(StringComparer.Ordinal);
    private readonly Dictionary<string, JobTries> unreached = new(StringComparer.Ordinal);

    /// <summary>**One round**: each server is reached only with <see cref="ServerRecords.RootConnectionAsync"/> (the Mac's
    /// <c>OwnerAccessModel.connection</c>), at an address that this PC's own Tailscale names as that server
    /// (<paramref name="tailscaleStatus"/>, read for this round); <paramref name="run"/> runs one program there as root
    /// (<see cref="RootCall.RunAsync"/>). <paramref name="now"/> is this PC's clock. It gives the lines for the log. A
    /// cancel ends it between two servers, and then the next round is a first round.</summary>
    public async Task<IReadOnlyList<string>> RunAsync(RootFleet fleet, ServerRecords servers, string? tailscaleStatus,
                                                      Func<InstallTarget, string, TimeSpan, Task<string>> run,
                                                      Func<double> now, CancellationToken cancel = default)
    {
        Task<InstallTarget> Connection(ServerEntry entry) => servers.RootConnectionAsync(entry, tailscaleStatus);
        var log = new List<string>();
        var seenNow = new HashSet<string>(StringComparer.Ordinal);
        foreach (var server in fleet.Servers.Where(s => Hardening.Applies(s.Entry)))
        {
            if (cancel.IsCancellationRequested) return Stopped(log);
            var entry = server.Entry;
            var name = RootRecords.NameOf(fleet.Hub, entry);
            var kept = records.Sweep(RootRecords.Hardening, name);
            var turn = await RootJob.TurnAsync(
                Hardening.ReadingOf(entry, fleet.Join, fleet.Time), kept, unreached.GetValueOrDefault(name), seen.Contains(name),
                now(), Hardening.Started, Hardening.Outcome, "its hardening is in order", () => Connection(entry),
                target => run(target, Hardening.Program(), RunLimit)).ConfigureAwait(false);
            Keep(unreached, name, turn.Unreached);
            if (turn.Turn.Seen) seenNow.Add(name);
            log.AddRange(turn.Turn.Lines.Select(l => $"{entry.Name}: {l}"));
            if (turn.Memory != kept) records.KeepSweep(RootRecords.Hardening, name, turn.Memory);

            // The agents' browser parts, with a record and a count of their own, and only from a whole state of the hub.
            if (cancel.IsCancellationRequested) return Stopped(log);
            if (fleet.Agents is null || fleet.Tasks is null) continue;
            var browserName = BrowserMark + name;
            var keptBrowser = records.BrowserOf(name);
            var work = Browser.WorkFor(server, fleet.Agents, fleet.Tasks, fleet.Join, fleet.Time);
            var seenKey = work?.Digest is { } digest ? browserName + " " + digest : null;
            var browserTurn = await Browser.TurnAsync(work, keptBrowser, unreached.GetValueOrDefault(browserName),
                                                      seenKey is not null && seen.Contains(seenKey), now(), () => Connection(entry),
                                                      (target, program) => run(target, program, RunLimit)).ConfigureAwait(false);
            Keep(unreached, browserName, browserTurn.Unreached);
            if (browserTurn.Turn.Seen && seenKey is not null) seenNow.Add(seenKey);
            log.AddRange(browserTurn.Turn.Lines.Select(l => $"{entry.Name}: browser: {l}"));
            if (browserTurn.Memory != keptBrowser) records.KeepBrowser(name, browserTurn.Memory);
        }
        seen = seenNow;
        return log;
    }

    /// <summary>A round that was ended part of the way: what it read is no round, so the next one is a first round.</summary>
    private List<string> Stopped(List<string> log)
    {
        seen = new HashSet<string>(StringComparer.Ordinal);
        return log;
    }

    private static void Keep(Dictionary<string, JobTries> all, string name, JobTries? tries)
    {
        if (tries is null) all.Remove(name);
        else all[name] = tries;
    }
}
