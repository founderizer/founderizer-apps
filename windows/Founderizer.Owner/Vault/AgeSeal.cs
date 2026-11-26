using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;

namespace Founderizer.Owner.Vault;

/// <summary>Why a seal was not made: the recipient is no key that a value can be sealed to, or the random source gave no
/// bytes of the size asked.</summary>
public sealed class SealException(string message) : Exception(message);

/// <summary>**A value sealed for one machine's vault** (the Mac's <c>AgeSeal</c>, owner feature <c>secret_deliveries</c>):
/// an age file (age-encryption.org/v1) for one X25519 recipient, in ASCII armor, which only the holder of that
/// recipient's identity opens. The hub carries it and cannot open it; the app keeps no copy and no key.
///
/// It is age's own format, byte for byte as the Mac writes it (<c>vault-seal.json</c>): a random file key, wrapped for
/// the recipient with an ephemeral X25519 share (HKDF-SHA-256 and ChaCha20-Poly1305), the header's HMAC, and the payload
/// in ChaCha20-Poly1305 chunks of 64 KiB under a key of its own nonce. BouncyCastle gives X25519 and ChaCha20-Poly1305,
/// which .NET does not have on every PC; .NET gives HKDF and the HMAC.</summary>
public static class AgeSeal
{
    internal const string Head = "-----BEGIN AGE ENCRYPTED FILE-----";
    internal const string Tail = "-----END AGE ENCRYPTED FILE-----";
    private const int Chunk = 65_536;

    /// <summary>The longest sealed copy the hub takes (<c>DEPOSIT_COPY_MAX</c>): over this, <c>POST
    /// /ui/secrets/deliver</c> refuses the whole delivery, so a value too long to seal is refused in the form.</summary>
    public const int MaxCopy = 16_384;

    /// <summary>The header is one fixed size: the version line (22), "-> X25519 " and the ephemeral share (53), the
    /// wrapped file key with its line end (44), "---" (4), and the space, the header's HMAC and its line end (45).</summary>
    private const int HeaderBytes = 168;

    private const string Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

    /// <summary>The system's random source, as the Mac's <c>secureRandom</c>.</summary>
    public static byte[] SecureRandom(int count) => RandomNumberGenerator.GetBytes(count);

    /// <summary><paramref name="value"/> sealed to <paramref name="recipient"/> (<c>age1…</c>), as an armored file with LF
    /// line ends. <paramref name="random"/> gives the file key, the ephemeral key and the payload's nonce, in that order;
    /// only a test gives its own. The file key and the shared secrets are cleared once they are used.</summary>
    public static string Seal(ReadOnlySpan<byte> value, string recipient, Func<int, byte[]>? random = null)
    {
        random ??= SecureRandom;
        var share = PublicKeyOf(recipient) ?? throw new SealException("not an age recipient");
        var fileKey = Take(random, 16);
        var ephemeralBytes = Take(random, 32);
        var secret = new byte[32];
        byte[] wrapKey = [], headerKey = [], payloadKey = [];
        try
        {
            var ephemeral = new X25519PrivateKeyParameters(ephemeralBytes);
            var mine = ephemeral.GeneratePublicKey().GetEncoded();
            try
            {
                ephemeral.GenerateSecret(new X25519PublicKeyParameters(share), secret, 0);
            }
            catch (InvalidOperationException)
            {
                // A low-order key gives an all-zero secret, which wraps the file key for nobody.
                throw new SealException("the recipient is a key of low order");
            }
            wrapKey = Key(secret, [.. mine, .. share], "age-encryption.org/v1/X25519");
            var wrapped = ChaCha(wrapKey, new byte[12], fileKey);
            var header = $"age-encryption.org/v1\n-> X25519 {Raw(mine)}\n{Lines(Raw(wrapped))}\n---";
            headerKey = Key(fileKey, [], "header");
            var mac = HMACSHA256.HashData(headerKey, Encoding.ASCII.GetBytes(header));
            header += $" {Raw(mac)}\n";
            var nonce = Take(random, 16);
            payloadKey = Key(fileKey, nonce, "payload");
            var file = new List<byte>(Encoding.ASCII.GetBytes(header).Length + 16 + value.Length + 16 * (value.Length / Chunk + 1));
            file.AddRange(Encoding.ASCII.GetBytes(header));
            file.AddRange(nonce);
            var start = 0;
            ulong counter = 0;
            do
            {
                var end = Math.Min(start + Chunk, value.Length);
                // An 11-byte big-endian counter, then 1 for the last chunk. An empty value is one empty last chunk.
                var chunkNonce = new byte[12];
                for (var i = 0; i < 8; i++) chunkNonce[3 + i] = (byte)(counter >> (8 * (7 - i)));
                chunkNonce[11] = (byte)(end == value.Length ? 1 : 0);
                file.AddRange(ChaCha(payloadKey, chunkNonce, value[start..end]));
                start = end;
                counter++;
            } while (start < value.Length);
            var text = Convert.ToBase64String(file.ToArray());
            var armored = new StringBuilder(Head).Append('\n');
            for (var at = 0; at < text.Length; at += 64) armored.Append(text, at, Math.Min(64, text.Length - at)).Append('\n');
            return armored.Append(Tail).Append('\n').ToString();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(fileKey);
            CryptographicOperations.ZeroMemory(ephemeralBytes);
            CryptographicOperations.ZeroMemory(secret);
            CryptographicOperations.ZeroMemory(wrapKey);
            CryptographicOperations.ZeroMemory(headerKey);
            CryptographicOperations.ZeroMemory(payloadKey);
        }
    }

    /// <summary>True for an armored age file that this app made: the form the hub takes (<c>sealed_copy</c>), which also
    /// tells a sealed copy apart from a value at a glance. It does not open it.</summary>
    public static bool IsSealed(string text)
    {
        if (!text.StartsWith(Head + "\n", StringComparison.Ordinal) || !text.EndsWith(Tail + "\n", StringComparison.Ordinal)) return false;
        if (text.Length < Head.Length + 1 + Tail.Length + 1) return false;
        var inside = text[(Head.Length + 1)..^(Tail.Length + 1)];
        if (!inside.EndsWith('\n')) return false;
        var rows = inside.Split('\n')[..^1];
        if (rows.Length == 0 || rows[..^1].Any(r => r.Length != 64) || rows[^1].Length > 64) return false;
        var joined = string.Concat(rows);
        // Foundation's Data(base64Encoded:): the standard alphabet with its padding, and nothing else.
        if (joined.Length % 4 != 0 || joined.AsSpan().IndexOfAnyExcept("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=") >= 0)
            return false;
        byte[] file;
        try
        {
            file = Convert.FromBase64String(joined);
        }
        catch (FormatException)
        {
            return false;
        }
        return file.AsSpan().StartsWith("age-encryption.org/v1\n-> X25519 "u8);
    }

    /// <summary>How many characters <see cref="Seal"/> writes for a value of <paramref name="count"/> bytes. Nothing in
    /// the file varies with the value but its own length: one fixed header, the payload's nonce, and one tag for each
    /// chunk, in base64 lines of 64.</summary>
    public static int SealedLength(int count)
    {
        var chunks = Math.Max(1, (count + Chunk - 1) / Chunk);       // an empty value is one empty last chunk
        var text = (HeaderBytes + 16 + count + 16 * chunks + 2) / 3 * 4;
        return Head.Length + 1 + text + (text + 63) / 64 + Tail.Length + 1;
    }

    /// <summary>The longest value whose sealed copy is at most <paramref name="limit"/> characters.</summary>
    public static int LongestSealed(int limit)
    {
        int low = 0, high = Math.Max(0, limit);                     // base64 alone is longer than the value
        while (low < high)
        {
            var mid = (low + high + 1) / 2;
            if (SealedLength(mid) <= limit) low = mid;
            else high = mid - 1;
        }
        return low;
    }

    /// <summary>The 32 bytes of an <c>age1…</c> recipient, or null: Bech32 (BIP 173) in lower case, with the
    /// human-readable part "age", a valid checksum, and no padding bits that are set.</summary>
    public static byte[]? PublicKeyOf(string recipient)
    {
        if (recipient.Length != 62 || !recipient.StartsWith("age1", StringComparison.Ordinal)) return null;
        var values = new List<byte>(58);
        foreach (var c in recipient.AsSpan(4))
        {
            var index = Charset.IndexOf(c);
            if (index < 0) return null;
            values.Add((byte)index);
        }
        if (Polymod([.. Expand("age"), .. values]) != 1) return null;
        int accumulator = 0, bits = 0;
        var output = new List<byte>(32);
        foreach (var value in values.Take(values.Count - 6))
        {
            accumulator = accumulator << 5 | value;
            bits += 5;
            while (bits >= 8)
            {
                bits -= 8;
                output.Add((byte)(accumulator >> bits & 0xff));
            }
            accumulator &= (1 << bits) - 1;
        }
        return bits < 5 && accumulator == 0 && output.Count == 32 ? [.. output] : null;
    }

    /// <summary>Bech32 (BIP 173) of <paramref name="data"/> under the human-readable part <paramref name="hrp"/>, in
    /// lower case and with no length limit, as age writes its keys: "age" gives a recipient, and "AGE-SECRET-KEY-",
    /// upper-cased by the caller, an identity. The checksum is over the lower-case part, as age computes it.</summary>
    public static string Bech32(string hrp, ReadOnlySpan<byte> data)
    {
        var prefix = hrp.ToLowerInvariant();
        var values = new List<byte>(data.Length * 8 / 5 + 7);
        int accumulator = 0, bits = 0;
        foreach (var b in data)
        {
            accumulator = accumulator << 8 | b;
            bits += 8;
            while (bits >= 5)
            {
                bits -= 5;
                values.Add((byte)(accumulator >> bits & 31));
            }
            accumulator &= (1 << bits) - 1;
        }
        if (bits > 0) values.Add((byte)(accumulator << (5 - bits) & 31));      // the last group, padded with zero bits
        var check = Polymod([.. Expand(prefix), .. values, 0, 0, 0, 0, 0, 0]) ^ 1;
        var text = new StringBuilder(prefix).Append('1');
        foreach (var value in values) text.Append(Charset[value]);
        for (var i = 0; i < 6; i++) text.Append(Charset[(int)(check >> (5 * (5 - i)) & 31)]);
        return text.ToString();
    }

    private static byte[] Take(Func<int, byte[]> random, int count)
    {
        var bytes = random(count);
        return bytes.Length == count ? bytes : throw new SealException("the random source gave no bytes of that size");
    }

    private static byte[] Expand(string hrp)
    {
        var bytes = Encoding.ASCII.GetBytes(hrp);
        return [.. bytes.Select(b => (byte)(b >> 5)), 0, .. bytes.Select(b => (byte)(b & 31))];
    }

    private static uint Polymod(IEnumerable<byte> values)
    {
        uint[] generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
        uint check = 1;
        foreach (var value in values)
        {
            var top = check >> 25;
            check = (check & 0x1ffffff) << 5 ^ value;
            for (var i = 0; i < 5; i++)
                if ((top >> i & 1) == 1) check ^= generator[i];
        }
        return check;
    }

    private static byte[] Key(byte[] material, byte[] salt, string info) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, material, 32, salt, Encoding.ASCII.GetBytes(info));

    /// <summary>ChaCha20-Poly1305 of BouncyCastle: the ciphertext, then its 16-byte tag.</summary>
    private static byte[] ChaCha(byte[] key, byte[] nonce, ReadOnlySpan<byte> plain)
    {
        var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
        cipher.Init(true, new AeadParameters(new KeyParameter(key), 128, nonce));
        var input = plain.ToArray();
        var output = new byte[cipher.GetOutputSize(input.Length)];
        var length = cipher.ProcessBytes(input, 0, input.Length, output, 0);
        length += cipher.DoFinal(output, length);
        CryptographicOperations.ZeroMemory(input);
        return length == output.Length ? output : output[..length];
    }

    /// <summary>Base64 without padding, as age writes the header.</summary>
    private static string Raw(byte[] data) => Convert.ToBase64String(data).TrimEnd('=');

    /// <summary>A stanza's body in lines of 64 columns. A body whose last line is full ends with an empty line.</summary>
    private static string Lines(string text)
    {
        var rows = new List<string>();
        for (var at = 0; at < text.Length; at += 64) rows.Add(text.Substring(at, Math.Min(64, text.Length - at)));
        if (rows.Count == 0 || rows[^1].Length == 64) rows.Add("");
        return string.Join("\n", rows);
    }
}
