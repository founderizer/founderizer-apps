using System;
using System.Linq;
using System.Text.Json;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.RootJobs;

/// <summary>What the install of the central vault printed last: the vault's key and its fleet, its own reason for stopping,
/// or (the app's own install only) that the vault on that machine holds another owner key and was left as it is (the Mac's
/// CentralInstall).</summary>
public abstract record VaultInstalled
{
    private VaultInstalled() { }

    public sealed record Ready(string Recipient, string Fleet) : VaultInstalled;
    public sealed record Refused(string Says) : VaultInstalled;
    public sealed record OtherOwner : VaultInstalled;
}

/// <summary>**The install of the central vault on the hub's own machine, over the owner's SSH connection** (the Mac's
/// CentralVaultRemote.install, .bridge and .installed). It takes plain values (the owner's public key, the release keys of
/// this build) and gives a program and what its output says; it names nothing of the vault's other pieces. The app runs it
/// from root's own clone of the published repository, at the revision of a release whose manifest a release key signed, and
/// from nowhere else: never from a folder that the hub's user can change, and never from a path that the hub names.</summary>
public static class VaultInstall
{
    /// <summary>Root's own clone of the published repository on the hub's machine.</summary>
    public const string RootKit = "/usr/local/lib/founderizer-kit";
    /// <summary>Where a server's own vault keeps its configuration (<c>vault.py</c>).</summary>
    public const string BrokerConfig = "/etc/fleet-vault/vault.json";

    /// <summary>**The install, as root on the hub's own machine**: the clone brought to the hub's newest signed release
    /// (<c>kit-clone</c>), then its <c>hubsetup.py central-vault</c> with the owner's public key. Running it again is how the
    /// vault is updated. <paramref name="keepOwner"/>: the app's own install, which leaves a vault that another computer's key
    /// holds as it is. Null for a key that is not one (65 bytes of the uncompressed point, 04 first).
    /// <paramref name="releaseKeys"/>: this build's own release keys, one for each line, never a key that the hub names
    /// (<see cref="Bridge"/>).</summary>
    public static string? Program(string ownerKey, bool keepOwner, string releaseKeys)
    {
        if (Base64(ownerKey) is not { Length: 65 } point || point[0] != 4) return null;
        const string setup = "python3 " + RootKit + "/hubsetup.py";
        return Bridge(releaseKeys) + $"; {setup} kit-clone && {setup} central-vault --owner-key {InstallPlan.Quote(ownerKey)}"
               + (keepOwner ? " --keep-owner" : "");
    }

    /// <summary>**The bridge across the key change of 4 November 2026** (the Mac's): root's clone of a hub installed before
    /// that day has no <c>early-key.pub</c>, and in such a clone only, this build's own release keys go into
    /// <c>release-key.pub</c> first, so that the clone's own code checks the hub's signed release with them. Its second part
    /// makes the clone, from the installer's own tree (root's own folder), on a hub from before its installer made
    /// one.</summary>
    internal static string Bridge(string releaseKeys, string kit = RootKit, string tree = InstallPlan.HubKit)
    {
        var keys = releaseKeys.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(RootJob.Trimmed)
                              .Where(k => Base64(k) is { Length: 32 }).ToList();
        var clone = $"if ! test -e {kit}/hubsetup.py && test -e {tree}/hubsetup.py; then python3 {tree}/hubsetup.py kit-clone || exit 1; fi";
        if (keys.Count == 0) return clone;
        return $"if test -d {kit}/.git && ! test -e {kit}/early-key.pub; then printf '%s\\n' "
               + string.Join(" ", keys.Select(k => $"'{k}'")) + $" > {kit}/release-key.pub || exit 1; fi; " + clone;
    }

    /// <summary>Strict base64, as Swift's <c>Data(base64Encoded:)</c>: with no white space.</summary>
    private static byte[]? Base64(string text)
    {
        if (text.Length == 0 || text.Any(char.IsWhiteSpace)) return null;
        var buffer = new byte[text.Length];
        return Convert.TryFromBase64String(text, buffer, out var written) ? buffer[..written] : null;
    }

    /// <summary>The install's answer: its last line that is a JSON object with <c>ok</c>. Its other lines and anything the
    /// machine printed on standard error come before it. Null when it printed none.</summary>
    public static VaultInstalled? Installed(string output)
    {
        foreach (var line in Enumerable.Reverse(output.Split('\n', StringSplitOptions.RemoveEmptyEntries)))
        {
            var text = RootJob.Trimmed(line);
            if (!text.StartsWith('{')) continue;
            JsonElement found;
            try
            {
                using var document = JsonDocument.Parse(text);
                found = document.RootElement.Clone();
            }
            catch (JsonException) { continue; }
            if (found.ValueKind != JsonValueKind.Object || !found.TryGetProperty("ok", out var ok) ||
                ok.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) continue;
            string? Text(string name) => found.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
            if (ok.ValueKind == JsonValueKind.False)
                return Text("owner") == "other" ? new VaultInstalled.OtherOwner()
                                                : new VaultInstalled.Refused(Text("error") is { } says ? RootJob.Prefix(says, 300) : GaveNoReason);
            if (Text("recipient") is not { } recipient || !AgeRecipient.IsValid(recipient) || Text("fleet") is not { } fleet || !IsFleet(fleet))
                return new VaultInstalled.Refused(NoKeyToRead);
            return new VaultInstalled.Ready(recipient, fleet);
        }
        return null;
    }

    /// <summary>**Why a key that the install printed may not become the pin**, or null when it may (the Mac's
    /// <c>CentralVaultPins.refusal</c>, M2 of the validation of 23 November 2026). The vault's keys never change in an install
    /// or an update, so at an update, or at the app's own install, a key that is not the pin that this PC holds comes only
    /// from a fault, and the pin stays. Only the owner's Set up (<paramref name="setUp"/>) and a first install, with no pin
    /// held, write a pin.</summary>
    public static string? PinRefusal(string printed, string? held, bool setUp) =>
        !setUp && held is not null && held != printed ? OtherKey : null;

    /// <summary>**Whether this PC's own Tailscale names the connection's host and the host of this PC's hub address as one
    /// node**, before any step reads the central vault as root there: its install and its update, which pin the key that
    /// they print (the Mac's <c>CentralVaultRemote.hubMachineStop</c>). The connection's address is the hub's word, so the
    /// address alone is not enough; the node is compared by its ID or its whole name, never by a first label that two nodes
    /// can share. Null when they are one node; else the words of the stop, and the step runs nothing.</summary>
    public static string? HubMachineStop(string targetHost, Uri hub, string machine, string? tailscaleStatus)
    {
        var address = hub.Host;
        if (TailnetNodes.Node(address, tailscaleStatus) is not { } hubs) return VaultPins.TailscaleSaysOther(address, machine);
        return TailnetNodes.Node(targetHost, tailscaleStatus) == hubs ? null : VaultPins.TailscaleSaysOther(targetHost, machine);
    }

    /// <summary>The Mac's words of a hub that names another vault key than the one this PC pinned (<c>VaultPlan.otherKey</c>).</summary>
    internal const string OtherKey = "The hub names another vault key than the one this PC pinned.";

    /// <summary>The Mac's words of an install that refused with none, and of one whose answer the app cannot read.</summary>
    internal const string GaveNoReason = "It gave no reason.";
    internal const string NoKeyToRead = "It printed no vault key and no fleet that Founderizer can read.";

    /// <summary>A fleet's id, as the hub's <c>fleet_id()</c> writes it: 16 lower-case hex characters.</summary>
    internal static bool IsFleet(string text) => text.Length == 16 && text.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
}

/// <summary>**An <c>age1…</c> recipient** (the Mac's <c>AgeSeal.publicKey(of:)</c>): Bech32 (BIP 173) in lower case, with the
/// human-readable part "age", a valid checksum, and no padding bits that are set, of 32 bytes. A text that is not one is read
/// as missing.</summary>
internal static class AgeRecipient
{
    private const string Alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

    public static bool IsValid(string recipient)
    {
        if (recipient.Length != 62 || !recipient.StartsWith("age1", StringComparison.Ordinal)) return false;
        var values = recipient[4..].Select(c => Alphabet.IndexOf(c)).ToList();
        if (values.Contains(-1)) return false;
        var hrp = "age";
        var expanded = hrp.Select(c => c >> 5).Append(0).Concat(hrp.Select(c => c & 31)).Concat(values);
        if (Polymod(expanded) != 1) return false;
        int accumulator = 0, bits = 0, bytes = 0;
        foreach (var value in values.Take(values.Count - 6))
        {
            accumulator = (accumulator << 5) | value;
            bits += 5;
            while (bits >= 8)
            {
                bits -= 8;
                bytes++;
            }
            accumulator &= (1 << bits) - 1;
        }
        return bits < 5 && accumulator == 0 && bytes == 32;
    }

    private static uint Polymod(System.Collections.Generic.IEnumerable<int> values)
    {
        uint[] generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
        uint check = 1;
        foreach (var value in values)
        {
            var top = check >> 25;
            check = ((check & 0x1ffffff) << 5) ^ (uint)value;
            for (var index = 0; index < 5; index++)
                if (((top >> index) & 1) == 1) check ^= generator[index];
        }
        return check;
    }
}
