using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Founderizer.Core;

/// <summary>**The code that carries its hub** (FleetCore's PairingCode, F7 B3 and B6 of the owner's feedback of 22
/// November 2026: "The code carries the hub's address: 13 characters, nothing new leaves the fleet"). For a hub at
/// `http://&lt;an IPv4 address in 100.64.0.0/10&gt;:8765` the Mac's Add device shows 13 characters, `AAAAA-CCCC-CCCC`: 5
/// for the address (the 22 bits of its place in 100.64.0.0/10, then 3 check bits, the CRC-3 with x³ + x + 1 of those 22
/// bits and of the code's 40 bits), then the hub's own code of 8. Any other hub, and a Mac before B6, shows the 8. The
/// hub takes the 8 only. `app/vectors/join-code.json` (Setup's `makers/join_code.py`) holds the rule.</summary>
public static class PairingCode
{
    public const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    /// <summary>The hub's port, which the 13 characters do not carry.</summary>
    public const int Port = 8765;
    /// <summary>100.64.0.0/10, Tailscale's addresses: the first 10 bits of each address in it.</summary>
    private const uint Network = 100u << 24 | 64u << 16;

    /// <summary>What a typed code holds: the hub that its 13 characters carry, or null for 8; and the hub's code of 8 as
    /// `XXXX-XXXX`.</summary>
    public sealed record Reading(Uri? Hub, string Code);

    /// <summary>What the Mac shows for <paramref name="code"/> (`XXXX-XXXX`) of the hub at <paramref name="hub"/> (its
    /// address as written): 13 characters for a hub that the rule takes, else the code itself.</summary>
    public static string Shown(string hub, string code)
    {
        if (!Regex.IsMatch(code, "^[" + Alphabet + "]{4}-[" + Alphabet + "]{4}$") || Place(hub) is not { } place) return code;
        var values = code.Where(c => c != '-').Select(c => Alphabet.IndexOf(c)).ToList();
        var head = place << 3 | Check(place, values);
        return new string(Enumerable.Range(0, 5).Select(i => Alphabet[(int)(head >> (20 - 5 * i) & 31)]).ToArray()) + "-" + code;
    }

    /// <summary>The letters of what a person typed, with the case and the spaces and hyphens taken out, or null for a
    /// character outside the hub's alphabet (the code holds no I, O, 0 or 1).</summary>
    public static string? Letters(string typed)
    {
        var letters = new StringBuilder();
        foreach (var c in typed.ToUpperInvariant())
        {
            if (Gap(c)) continue;
            if (Alphabet.IndexOf(c) < 0) return null;
            letters.Append(c);
        }
        return letters.ToString();
    }

    /// <summary>The hub and the code that <paramref name="typed"/> holds, or null: a character outside the alphabet, a
    /// length that is not 8 or 13, or 13 characters whose check bits do not match (a typing fault, which goes to no
    /// address).</summary>
    public static Reading? Read(string typed)
    {
        if (Letters(typed) is not { } letters) return null;
        var values = letters.Select(c => Alphabet.IndexOf(c)).ToList();
        switch (values.Count)
        {
            case 8:
                return new Reading(null, CodeOf(values));
            case 13:
                var head = values.Take(5).Aggregate(0u, (sum, value) => sum << 5 | (uint)value);
                var rest = values.Skip(5).ToList();
                return (head & 7) == Check(head >> 3, rest) ? new Reading(HubAt(head >> 3), CodeOf(rest)) : null;
            default:
                return null;
        }
    }

    /// <summary>**A whole code to send now**, as its letters, or null while it is not whole. 13 letters go, and so do 8
    /// of an older Mac. **8 letters never go while 13 are still coming**: after a first group of 5 (`AAAAA-CCC`), where
    /// the first 5 letters carry the Tailscale hub that this PC knows (the start of 13, with a hyphen anywhere or none),
    /// and, while this PC knows no hub or a hub that the rule cannot compare (a name, another address: then the first 5
    /// letters say nothing), any 8 but the form that an older Mac shows (`XXXX-XXXX`). An older Mac's 8 whose first 5
    /// letters carry that hub by chance wait for a person to type on (1 in 4 million codes).</summary>
    public static string? Whole(string typed, Uri? hub)
    {
        if (Letters(typed) is not { } letters) return null;
        if (letters.Length == 13) return letters;
        if (letters.Length != 8) return null;
        var groups = new string(typed.Select(c => Gap(c) ? ' ' : c).ToArray()).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (groups.Length > 1 && groups[0].Length >= 5) return null;
        if (hub is null || Place(hub.AbsoluteUri) is not { } place) return groups.Length == 2 && groups[0].Length == 4 ? letters : null;
        var head = letters.Take(5).Aggregate(0u, (sum, c) => sum << 5 | (uint)Alphabet.IndexOf(c));
        return head >> 3 == place ? null : letters;
    }

    /// <summary>Where a reading goes: the hub to send its code of 8 to (Hub, with Join true
    /// when this PC must take that hub first), or the owner's words of why nothing goes. 13 characters with no hub on
    /// this PC take the hub that they carry; with a hub on this PC that the rule takes (a Tailscale address at the
    /// hub's port, which this PC's search finds), they must carry that hub; a hub that the rule cannot compare (a name,
    /// another address of the same server) takes their code. 8 characters go to the hub that this PC knows.</summary>
    public static (Uri? Hub, bool Join, string? Refusal) Target(Reading reading, Uri? known)
    {
        if (reading.Hub is { } carried)
        {
            if (known is null) return (carried, true, null);
            if (Place(known.AbsoluteUri) is { } place && place != Place(carried.AbsoluteUri)) return (null, false, OtherHubWords);
            return (known, false, null);
        }
        return known is null ? (null, false, NoHubWords) : (known, false, null);
    }

    /// <summary>The owner's words of a text that is no code (<see cref="Read"/>): the words of before. **They stay until
    /// the Mac shows the 13 characters** (Setup's F7 B6) and the owner says yes to the words of both codes: until then
    /// every Mac shows 8, so they are true.</summary>
    public const string CodeWords = "A code is eight characters, as the Mac app shows it (XXXX-XXXX).";
    /// <summary>The owner's words of a code whose 13 characters carry another hub than the Tailscale hub of this PC: the
    /// words of a text that is no code, for the same reason (no new sentence before the owner's yes).</summary>
    public const string OtherHubWords = CodeWords;
    /// <summary>The owner's words of a code of 8 with no hub on this PC.</summary>
    public const string NoHubWords = "Give your hub's address in Settings first.";

    /// <summary>The place of a hub's address in 100.64.0.0/10 (22 bits), or null for a hub that the rule does not take:
    /// only `http`, a dotted IPv4 address in that network in its own form (no zero in front of a number), the port 8765,
    /// and no path, user, query or fragment. <paramref name="hub"/> is the address as written. Only the ASCII digits are
    /// digits here: .NET's \d also takes other scripts' digits (full-width ones), which no number of an address holds.</summary>
    public static uint? Place(string hub)
    {
        var match = Regex.Match(hub, @"^http://([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):8765/?$");
        if (!match.Success) return null;
        uint value = 0;
        for (var i = 1; i <= 4; i++)
        {
            var part = match.Groups[i].Value;
            if (part.Length > 1 && part[0] == '0') return null;
            if (!uint.TryParse(part, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var octet) ||
                octet > 255)
                return null;
            value = value << 8 | octet;
        }
        return value >> 22 == Network >> 22 ? value & 0x3F_FFFF : null;
    }

    /// <summary>A character between the groups of a code: a hyphen or any white space (a no-break space, an ideographic
    /// space), the same set for <see cref="Letters"/> and for the groups of <see cref="Whole"/>.</summary>
    private static bool Gap(char c) => char.IsWhiteSpace(c) || c == '-';

    private static Uri HubAt(uint place) => new($"http://{Dotted(Network | place)}:{Port}");

    private static string Dotted(uint value) => string.Join(".", new[] { 24, 16, 8, 0 }.Select(shift => (value >> shift & 255).ToString(System.Globalization.CultureInfo.InvariantCulture)));

    private static string CodeOf(IReadOnlyList<int> values)
    {
        var text = new string(values.Select(v => Alphabet[v]).ToArray());
        return text[..4] + "-" + text[4..];
    }

    /// <summary>The CRC-3 with the polynomial x³ + x + 1 of the address's 22 bits, then the 5 bits of each character of
    /// the code, each from its highest bit: the remainder of those bits, followed by three zeros, divided by 1011.</summary>
    private static uint Check(uint place, IReadOnlyList<int> values)
    {
        var bits = new List<uint>();
        for (var i = 0; i < 22; i++) bits.Add(place >> (21 - i) & 1);
        foreach (var value in values)
            for (var i = 0; i < 5; i++) bits.Add((uint)value >> (4 - i) & 1);
        bits.AddRange([0, 0, 0]);
        uint remainder = 0;
        foreach (var bit in bits)
        {
            remainder = remainder << 1 | bit;
            if ((remainder & 0b1000) != 0) remainder ^= 0b1011;
        }
        return remainder;
    }
}
