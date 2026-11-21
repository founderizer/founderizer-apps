using System;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Founderizer.Core;

namespace Founderizer.Setup.Install;

/// <summary>**The one-time code that a new hub's installer prints for the owner's computer**, and where to send it
/// (the Mac's ClaimCode, hubsetup.py <c>claim</c>): twelve characters in three groups of four, of which the hub keeps
/// only the SHA-256.</summary>
public static partial class ClaimCode
{
    /// <summary>The line the installer writes into its log, which carries the code and the address to send it to.</summary>
    public const string LogMark = "FLEET_CLAIM=";
    /// <summary>The alphabet of a code (hub.LINK_ALPHABET): no letters or digits that are read for one another.</summary>
    public const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    /// <summary>A code as the owner may give it: case, spaces and hyphens are forgiven.</summary>
    public static string? Read(string given)
    {
        var code = new string(given.ToUpperInvariant().Where(c => Alphabet.Contains(c)).ToArray());
        return code.Length == 12 ? code : null;
    }

    /// <summary>The code as the installer shows it, in three groups of four.</summary>
    public static string Grouped(string code)
    {
        var groups = new StringBuilder();
        for (var start = 0; start < code.Length; start += 4)
        {
            if (start > 0) groups.Append('-');
            groups.Append(code.AsSpan(start, Math.Min(4, code.Length - start)));
        }
        return groups.ToString();
    }

    /// <summary>**The code and the claim's address out of the installer's own log** (its last line that has both):
    /// <c>FLEET_CLAIM=ABCD-EFGH-JKLM sh -c "$(curl -fsS http://100.x.y.z:8765/claim)"</c>. Only a code of the right shape
    /// and a plain HTTP address on the fleet's private network are taken: the log comes from a server, and a server must
    /// not be able to point this PC at an address of its own choosing.</summary>
    public static (string Code, Uri Claim)? Found(string log)
    {
        foreach (var line in log.Split('\n').Reverse())
        {
            var mark = line.IndexOf(LogMark, StringComparison.Ordinal);
            if (mark < 0) continue;
            var rest = line[(mark + LogMark.Length)..];
            var word = new string(rest.TakeWhile(c => !char.IsWhiteSpace(c)).ToArray());
            if (Read(word) is not { } code) continue;
            var found = ClaimAddress().Match(rest);
            if (!found.Success || !Uri.TryCreate(found.Value, UriKind.Absolute, out var claim) || !IsPrivateAddress(claim.Host))
                continue;
            return (code, claim);
        }
        return null;
    }

    /// <summary>A Tailscale address of the fleet's own network (100.64.0.0/10), the only place a claim is made: four
    /// numbers of one byte each, as Swift's <c>UInt8(_:)</c> reads them.</summary>
    public static bool IsPrivateAddress(string host)
    {
        var parts = host.Split('.');
        if (parts.Length != 4) return false;
        var bytes = new byte[4];
        for (var i = 0; i < 4; i++)
            if (!ServerCheck.WholeNumber(parts[i], out var value) || value is < 0 or > 255 || parts[i].StartsWith('+') ||
                parts[i].StartsWith('-')) return false;
            else bytes[i] = (byte)value;
        return bytes[0] == 100 && bytes[1] is >= 64 and <= 127;
    }

    [GeneratedRegex(@"http://[0-9.]+:[0-9]{1,5}/claim", RegexOptions.CultureInvariant)]
    private static partial Regex ClaimAddress();
}
