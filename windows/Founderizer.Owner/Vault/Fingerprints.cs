using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Founderizer.Owner.Vault;

/// <summary>**GET /ui/secrets/salts** (the Mac's <c>SecretSalts</c>): the salts for the fingerprints of one login
/// reference. A salt is no secret. A save into the central vault makes the fingerprints from them here, in the save's
/// memory, and the central vault makes them again from what it opens and keeps the value only when the two
/// agree.</summary>
public sealed partial record SecretSalts(string Login, string Password, string Totp)
{
    /// <summary>The reference, and two salts of 32 small hex characters.</summary>
    public bool IsValid => VaultIds.IsReference(Login) && Hex32().IsMatch(Password) && Hex32().IsMatch(Totp);

    /// <summary>The salts of the hub's answer, with the rules of the Mac's Decodable: the three fields as text, and any
    /// other field skipped. Null for an answer that is not one.</summary>
    public static SecretSalts? Read(JsonElement answer)
    {
        if (answer.ValueKind != JsonValueKind.Object) return null;
        string? Field(string name) =>
            answer.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        return Field("login") is { } login && Field("password") is { } password && Field("totp") is { } totp
            ? new SecretSalts(login, password, totp) : null;
    }

    [GeneratedRegex(@"\A[0-9a-f]{32}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Hex32();
}

/// <summary>One salted fingerprint of a login's value, as the hub takes it (the Mac's <c>SecretFingerprint</c>). It is
/// not the value.</summary>
public sealed partial record SecretFingerprint(string Kind, string Hash, int Len)
{
    /// <summary>The hub's rule for one registration: one to three items, at most one <c>password</c> and two
    /// <c>totp</c>, each with a hash of 64 small hex characters and a length of 8 or more.</summary>
    public static bool AreValid(IReadOnlyList<SecretFingerprint> items) =>
        items.Count is >= 1 and <= 3 && items.Count(i => i.Kind == "password") <= 1 && items.Count(i => i.Kind == "totp") <= 2 &&
        items.All(i => i.Kind is "password" or "totp" && i.Len >= 8 && Hex64().IsMatch(i.Hash));

    /// <summary>The fingerprints of one item value (<see cref="LoginSecret.Value"/>), exactly as every vault makes them
    /// (<c>vault.py</c> <c>fingerprints</c>): the password, the seed as typed, and the seed in its canonical form when that
    /// differs, each SHA-256 of its salt and the value, and each only when it has 8 or more characters and no white space.
    /// A length is Python's, in code points. Nothing of the value is in the result.</summary>
    public static IReadOnlyList<SecretFingerprint> Of(ReadOnlySpan<byte> value, SecretSalts salts) =>
        Printable(value).Select(part =>
        {
            var bytes = Encoding.UTF8.GetBytes((part.Kind == "password" ? salts.Password : salts.Totp) + part.Text);
            try
            {
                return new SecretFingerprint(part.Kind, Convert.ToHexStringLower(SHA256.HashData(bytes)), CodePoints(part.Text));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }).ToList();

    /// <summary>The parts of one item value that get a fingerprint, by the rule of <see cref="Of"/>. None is a value that
    /// the central vault never takes, because the hub then registers no fingerprint for it (the owner's choice C42).
    /// Throws <see cref="FormatException"/> for an item that is no object with a password.</summary>
    internal static IReadOnlyList<(string Kind, string Text)> Printable(ReadOnlySpan<byte> value)
    {
        string? password = null, totp = null;
        try
        {
            var reader = new Utf8JsonReader(value);
            using var document = JsonDocument.ParseValue(ref reader);
            var item = document.RootElement;
            if (item.ValueKind != JsonValueKind.Object) throw new FormatException("an item value is a JSON object");
            if (item.TryGetProperty("password", out var p) && p.ValueKind == JsonValueKind.String) password = p.GetString();
            if (item.TryGetProperty("totp", out var t) && t.ValueKind == JsonValueKind.String) totp = t.GetString();
        }
        catch (JsonException e)
        {
            throw new FormatException("an item value is a JSON object", e);
        }
        if (string.IsNullOrEmpty(password)) throw new FormatException("an item value has a password");
        var values = new List<(string Kind, string Text)> { ("password", password) };
        if (!string.IsNullOrEmpty(totp))
        {
            values.Add(("totp", totp));
            var seed = CanonicalSeed(totp);
            if (seed != totp) values.Add(("totp", seed));
        }
        return values.Where(v => CodePoints(v.Text) >= 8 && !v.Text.EnumerateRunes().Any(IsWhitespace)).ToList();
    }

    /// <summary>Python's white space (<c>str.isspace</c>, <c>\s</c>), as the Mac reads it: Unicode's White_Space, and the
    /// four ASCII separators U+001C to U+001F.</summary>
    internal static bool IsWhitespace(Rune rune) => rune.Value switch
    {
        >= 0x09 and <= 0x0D or >= 0x1C and <= 0x20 or 0x85 or 0xA0 or 0x1680 or >= 0x2000 and <= 0x200A or 0x2028 or 0x2029 or
            0x202F or 0x205F or 0x3000 => true,
        _ => false,
    };

    /// <summary><c>vault.py</c>'s <c>canonical_seed</c>: the <c>secret</c> of an <c>otpauth://</c> address, read as
    /// Python's <c>urlsplit</c> and <c>parse_qs</c> read it, or the value itself; then without white space, "=" and "-",
    /// in upper case.</summary>
    public static string CanonicalSeed(string value)
    {
        var seed = value;
        if (value.StartsWith("otpauth://", StringComparison.Ordinal))
        {
            // urlsplit drops tabs and line ends anywhere; the fragment goes at the first "#", and the query starts at the
            // first "?" before it. parse_qs keeps the "&" pairs that have a "=" and something after it, reads "+" as a
            // space and then the %-escapes as UTF-8, and the first value of `secret` wins.
            var address = new string(value.Where(c => c is not ('\t' or '\r' or '\n')).ToArray());
            var head = address.Split('#', 2)[0];
            var mark = head.IndexOf('?');
            var query = mark >= 0 ? head[(mark + 1)..] : "";
            seed = "";
            foreach (var pair in query.Split('&'))
            {
                var equals = pair.IndexOf('=');
                if (equals < 0 || equals + 1 >= pair.Length || Unescaped(pair[..equals]) != "secret") continue;
                seed = Unescaped(pair[(equals + 1)..]);
                break;
            }
        }
        var kept = new StringBuilder(seed.Length);
        foreach (var rune in seed.EnumerateRunes())
            if (!IsWhitespace(rune) && rune.Value != '=' && rune.Value != '-') kept.Append(rune.ToString());
        // A seed with a letter beyond ASCII is no base32, and the form refuses it (LoginSecret.IsSeed): the case where
        // Swift's upper case and .NET's differ never comes to a fingerprint.
        return kept.ToString().ToUpperInvariant();
    }

    /// <summary>The length of a text as Python counts it: its code points.</summary>
    internal static int CodePoints(string text) => text.EnumerateRunes().Count();

    /// <summary>One part of a query as Python's <c>unquote_plus</c> reads it: "+" is a space, a "%" with two hex digits is
    /// one byte, any other "%" stays as it is, and the bytes are UTF-8, each broken sequence read as U+FFFD.</summary>
    private static string Unescaped(string part)
    {
        var bytes = Encoding.UTF8.GetBytes(part.Replace('+', ' '));
        var output = new List<byte>(bytes.Length);
        for (var i = 0; i < bytes.Length;)
        {
            if (bytes[i] == '%' && i + 2 < bytes.Length && Digit(bytes[i + 1]) is { } high && Digit(bytes[i + 2]) is { } low)
            {
                output.Add((byte)(high << 4 | low));
                i += 3;
            }
            else
            {
                output.Add(bytes[i]);
                i++;
            }
        }
        return Encoding.UTF8.GetString(output.ToArray());
    }

    private static int? Digit(byte b) => b switch
    {
        >= (byte)'0' and <= (byte)'9' => b - '0',
        >= (byte)'a' and <= (byte)'f' => b - 'a' + 10,
        >= (byte)'A' and <= (byte)'F' => b - 'A' + 10,
        _ => null,
    };

    [GeneratedRegex(@"\A[0-9a-f]{64}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Hex64();
}
