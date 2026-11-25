using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.RootJobs;

/// <summary>Why a registration of the owner's computer key did not go through (the Mac's Failure). Each is a name for the
/// log and for the count of tries; no page shows one.</summary>
public enum ProofFailure
{
    /// <summary>The hub did not take the first call, or named no path that the PC may read.</summary>
    NoPath,
    /// <summary>The SSH connection gave no value: no connection, no right to read, or another file.</summary>
    NoValue,
    /// <summary>The hub refused the value.</summary>
    Refused,
    /// <summary>No answer came to the call with the value. The hub can have registered the key: it waits, and the next read
    /// of the hub carries it.</summary>
    NoAnswer,
    /// <summary>The PC could not write its key. Before the call that tells the hub: nothing was sent. After the hub's yes:
    /// the key still waits, and the next read of the hub carries it.</summary>
    NotKept,
}

/// <summary>**How the owner's computer registers its key on a hub that runs** (<c>POST /ui/owner/key</c>; the Mac's
/// OwnerMacKeyRegistration), with no first-caller gap: the hub writes a one-time value into a file of its own server, the PC
/// reads that file over the SSH connection that it has to that server, and sends the value back with the SHA-256 of its new
/// key. A guest behind the PC has the PC's address and no SSH key, so it cannot read the file.
///
/// **The path comes from the hub, and the PC can be root on the hub's server while the hub's own user is not.** So nothing
/// here reads the path with more rights than its owner has: the program on the server reads the file **as the user that
/// owns it**, and never as root. The path must also be a plain absolute path whose last part is the hub's own name for the
/// file, and only a value of the right shape, after the program's own mark, is ever sent back.
///
/// On a PC a hub is always a number (a hub written as a name has no key place, <see cref="OwnerPcKey.Name"/>), so the Mac's
/// check of a name's number against the server's addresses has no case here.</summary>
public static partial class OwnerKeyProof
{
    /// <summary>The name that the hub gives the file (<c>hub.py</c> <c>OWNER_PROOF_FILE</c>).</summary>
    public const string ProofFile = "owner-key.proof";

    /// <summary>What the program prints before the file's bytes, so that a line of <c>sudo</c>, of a login shell or of SSH
    /// itself in the output is not taken for the value and does not hide it.</summary>
    internal const string Mark = "founderizer-proof:";
    /// <summary>What the program prints before the server's own addresses.</summary>
    internal const string AddressMark = "founderizer-addresses:";

    /// <summary>The path as the PC may read it, or null: absolute, of plain letters, with no <c>..</c> and no empty part, at
    /// most 512 letters, and its last part the hub's own name for the file.</summary>
    public static string? Path(string? said)
    {
        if (said is null || said.Length > 512 || !PathShape().IsMatch(said)) return null;
        var parts = said.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts[^1] == ProofFile && !parts.Contains("..") && !parts.Contains(".") ? said : null;
    }

    [GeneratedRegex(@"\A(/[A-Za-z0-9._-]+)+\z", RegexOptions.CultureInvariant)]
    private static partial Regex PathShape();

    /// <summary>**The program that reads the file on the hub's server, as the file's own user** (the Mac's, byte for byte). It
    /// asks who owns the path by the user's number, and refuses root's; it reads at most 64 bytes as that user: by itself when
    /// it runs as that user, else through <c>sudo -n -u</c>, which root may always do. Then it prints its mark and what it read
    /// in one piece, and last the server's own addresses.</summary>
    public static string Program(string path)
    {
        var file = InstallPlan.Quote(path);
        return $"f={file}; u=$(stat -c %u -- \"$f\" 2>/dev/null || stat -f %u -- \"$f\" 2>/dev/null); "
               + "[ -n \"$u\" ] && [ \"$u\" != 0 ] || exit 1; "
               + "v=$(if [ \"$(id -u)\" = \"$u\" ]; then head -c 64 -- \"$f\"; else sudo -n -u \"#$u\" -- head -c 64 -- \"$f\"; fi 2>/dev/null); "
               + $"printf '{Mark}%s\\n' \"$v\"; "
               + "a=$(PATH=\"$PATH:/usr/sbin:/sbin\"; { ip -o addr 2>/dev/null || ifconfig 2>/dev/null; } | tr '\\n' ' '); "
               + $"printf '{AddressMark}%s\\n' \"$a\"";
    }

    /// <summary>The one-time value out of what the program printed, or null: what follows the program's last mark, to the end
    /// of that line, when it is 43 letters of base64url and nothing else.</summary>
    public static string? Value(string output)
    {
        var at = output.LastIndexOf(Mark, StringComparison.Ordinal);
        if (at < 0) return null;
        var rest = output[(at + Mark.Length)..];
        var end = rest.IndexOfAny(['\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029']);
        var text = end < 0 ? rest : rest[..end];
        return ValueShape().IsMatch(text) ? text : null;
    }

    [GeneratedRegex(@"\A[A-Za-z0-9_-]{43}\z", RegexOptions.CultureInvariant)]
    private static partial Regex ValueShape();

    /// <summary>**The whole registration** (the Mac's <c>run</c>). <paramref name="post"/>: one JSON body to
    /// <c>POST /ui/owner/key</c> of the hub, with no key of the PC (a PC that asks has none that the hub takes; the route
    /// knows it by its address and by the file's value), which gives the answer's status and bytes. <paramref name="read"/>:
    /// the program run on the hub's server, which gives what it printed.
    ///
    /// The key is made here and kept as the key that waits **before** the call that tells the hub its SHA-256. So a write that
    /// fails sends nothing, and an answer that is lost loses nothing: the next call of the PC carries the key that waits. **A
    /// registration that the hub refused keeps its key waiting**: the hub can hold that key all the same, and then the next
    /// read with it makes it the key; else it waits until the next registration writes over it. Null when it went
    /// through.</summary>
    public static async Task<ProofFailure?> RunAsync(Uri hub, ISecretBox box,
                                                     Func<IReadOnlyDictionary<string, string>, Task<(int Status, byte[] Data)>> post,
                                                     Func<string, Task<string>> read)
    {
        if (OwnerPcKey.Name(hub) is null) return ProofFailure.NotKept;
        // A call or a read that throws is the failure of its own step, as the Mac's try? of each is.
        if (await Try(() => post(new Dictionary<string, string>())).ConfigureAwait(false) is not { Status: 200 } first ||
            Answer(first.Data, ProofJson.Default.ProofAsked) is not { Registered: false } asked ||
            Path(asked.ProofFile) is not { } path) return ProofFailure.NoPath;
        if (await Try(() => read(Program(path))).ConfigureAwait(false) is not { } output || Value(output) is not { } proof) return ProofFailure.NoValue;
        string key;
        try
        {
            key = OwnerPcKey.Make();
            OwnerPcKey.KeepWaiting(box, hub, key);
        }
        catch (Exception e) when (e is not OutOfMemoryException) { return ProofFailure.NotKept; }
        var sent = await Try(() => post(new Dictionary<string, string> { ["sha256"] = OwnerPcKey.Digest(key), ["proof"] = proof })).ConfigureAwait(false);
        if (sent is not { } second) return ProofFailure.NoAnswer;
        if (second.Status != 200 || Answer(second.Data, ProofJson.Default.ProofRegistered) is not { Registered: true }) return ProofFailure.Refused;
        OwnerPcKey.Promote(box, hub, key);
        try { return OwnerPcKey.Read(box, hub) == key ? null : ProofFailure.NotKept; }
        catch (Exception e) when (e is not OutOfMemoryException) { return ProofFailure.NotKept; }
    }

    private static async Task<T?> Try<T>(Func<Task<T>> call) where T : class
    {
        try { return await call().ConfigureAwait(false); }
        catch (Exception e) when (e is not OutOfMemoryException) { return null; }
    }

    private static async Task<(int Status, byte[] Data)?> Try(Func<Task<(int Status, byte[] Data)>> call)
    {
        try { return await call().ConfigureAwait(false); }
        catch (Exception e) when (e is not OutOfMemoryException) { return null; }
    }

    private static T? Answer<T>(byte[] data, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type) where T : class
    {
        try { return JsonSerializer.Deserialize(data, type); }
        catch (JsonException) { return null; }
    }
}

/// <summary>The hub's answer to a call with no proof.</summary>
public sealed record ProofAsked(bool Registered, string? ProofFile = null);

/// <summary>The hub's answer to a call with the proof.</summary>
public sealed record ProofRegistered(bool Registered);

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower, RespectNullableAnnotations = true,
                             RespectRequiredConstructorParameters = true, GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(ProofAsked))]
[JsonSerializable(typeof(ProofRegistered))]
internal sealed partial class ProofJson : JsonSerializerContext;

/// <summary>**When the owner's computer registers its key, with no reads of its own** (the Mac's OwnerKeyPlan).</summary>
public static class OwnerKeyPlan
{
    public enum Step
    {
        Nothing,
        /// <summary>The hub takes this PC's key: keep the SSH connection to the hub's server for a day on which the key is
        /// lost.</summary>
        Remember,
        Register,
    }

    /// <summary>How the owner's computer can reach the hub's own server.</summary>
    public abstract record Reach
    {
        private Reach() { }

        public sealed record Target(InstallTarget Install) : Reach;
        /// <summary>The fleet's record of the hub's server is known and is no connection, and the PC keeps none.</summary>
        public sealed record None : Reach;
        /// <summary>The fleet's record of the hub's server is not known, and the PC keeps no connection.</summary>
        public sealed record Unknown : Reach;
    }

    /// <summary>- <paramref name="held"/>: the PC has a key for the hub, and the hub did not refuse that key as one it does
    /// not expect. <paramref name="known"/>: the place of the PC's key for the hub is known (while it is not, nothing is
    /// registered). <paramref name="refused"/>: the hub refused the PC's last call for want of the right key.
    /// <paramref name="takesKeys"/>: the hub lists the feature. <paramref name="fresh"/>: the PC reads the hub now.
    /// <paramref name="registered"/>: when a registration last went through, or null. One that went through is not made again
    /// for ten minutes, whatever the hub answers: each is an SSH command on the hub's server and a new key for every program
    /// of the PC.</summary>
    public static Step StepOf(bool held, bool refused, bool takesKeys, bool fresh, bool remembered, JobTries? tries,
                              double? registered, double now, bool known = true)
    {
        if (held && !refused) return fresh && !remembered ? Step.Remember : Step.Nothing;
        if (!known || !(refused || (fresh && takesKeys))) return Step.Nothing;
        if (tries is not null && !tries.IsDue(now)) return Step.Nothing;
        if (registered is { } last && now - last < JobTries.Wait) return Step.Nothing;
        return Step.Register;
    }

    /// <summary>Whether System status says that the PC could not register its key: at once when the fleet's record of the hub's
    /// server is known and is no connection, because another try changes nothing; else from the second failure in a
    /// row.</summary>
    public static bool Cannot(Reach reach, int failures) => reach is Reach.None || failures >= 2;

    /// <summary>What the PC has when the fleet's record gives no connection: the connection that it keeps from an earlier day,
    /// else <see cref="Reach.None"/> when the record is known to have none, and <see cref="Reach.Unknown"/> when not.</summary>
    public static Reach Without(FleetRecord record, InstallTarget? kept) =>
        kept is { } target ? new Reach.Target(target) : record is FleetRecord.Unknown ? new Reach.Unknown() : new Reach.None();
}
