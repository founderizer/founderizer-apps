using System;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Founderizer.Core;
using Org.BouncyCastle.Crypto.Parameters;

namespace Founderizer.Owner.Vault;

/// <summary>**The owner's recovery code** for the fleet's central vault (the Mac's <c>RecoveryCode</c>): 26 symbols of
/// Crockford's base32, 130 random bits. The central vault seals its backup to the age key that this code derives, so a
/// backup opens with the code and with nothing that the hub or a server holds. The app makes it by itself and keeps it in
/// this PC's secret box only (<see cref="RecoveryKeeping"/>), where a later restore reads it.
///
/// The key is HKDF-SHA-256 of the code in its normal form (salt "founderizer recovery v1", info "age X25519", 32 bytes),
/// taken as an X25519 key: <see cref="Recipient"/> is its <c>age1…</c> public key, which the owner's key signs for the
/// vault, and <see cref="Identity"/> its <c>AGE-SECRET-KEY-1…</c> form, for a restore tool that opens the backup with
/// <c>age</c>. It prints as nothing, so no log, report or crash record can carry it by accident.</summary>
public sealed class RecoveryCode : IEquatable<RecoveryCode>
{
    /// <summary>Crockford's alphabet: the digits and the letters without I, L, O and U.</summary>
    public const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    public const int Length = 26;

    /// <summary>The code in its normal form: 26 symbols of the alphabet, upper case, no "-".</summary>
    public string Normalized { get; }

    private RecoveryCode(string normalized) => Normalized = normalized;

    /// <summary>A code as the owner types it back, in any of the ways he may read it off his paper: null when it is not
    /// one.</summary>
    public static RecoveryCode? Read(string text)
    {
        var code = Normalize(text);
        return code.Length == Length && code.All(c => Alphabet.Contains(c)) ? new RecoveryCode(code) : null;
    }

    /// <summary>A new code from the system's random source. Each symbol takes the low five bits of one random byte, and
    /// 256 is a multiple of 32, so every symbol is equally likely.</summary>
    public static RecoveryCode Make(Func<int, byte[]>? random = null)
    {
        var bytes = (random ?? AgeSeal.SecureRandom)(Length);
        try
        {
            if (bytes.Length != Length) throw new SealException("the random source gave no bytes of that size");
            return new RecoveryCode(new string(bytes.Select(b => Alphabet[b & 31]).ToArray()));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    /// <summary>Upper case, without "-" and white space, with I and L read as 1 and O as 0, as Crockford's decoding
    /// reads them.</summary>
    public static string Normalize(string text)
    {
        var output = new StringBuilder(text.Length);
        foreach (var rune in text.ToUpperInvariant().EnumerateRunes())
        {
            if (rune.Value == '-' || Rune.IsWhiteSpace(rune)) continue;
            output.Append(rune.Value switch { 'I' or 'L' => "1", 'O' => "0", _ => rune.ToString() });
        }
        return output.ToString();
    }

    /// <summary>The code as the card shows it: groups of four, joined by "-".</summary>
    public string Grouped => string.Join("-", Enumerable.Range(0, (Normalized.Length + 3) / 4)
                                                       .Select(i => Normalized.Substring(i * 4, Math.Min(4, Normalized.Length - i * 4))));

    /// <summary>The 32 bytes of the X25519 private key.</summary>
    internal byte[] PrivateKey()
    {
        var code = Encoding.UTF8.GetBytes(Normalized);
        try
        {
            return HKDF.DeriveKey(HashAlgorithmName.SHA256, code, 32, Encoding.ASCII.GetBytes("founderizer recovery v1"),
                                  Encoding.ASCII.GetBytes("age X25519"));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(code);
        }
    }

    /// <summary>The <c>age1…</c> key the central vault seals its backup to. Any 32 bytes are an X25519 key: the clamping
    /// is part of the function, in BouncyCastle as in age.</summary>
    public string Recipient
    {
        get
        {
            var key = PrivateKey();
            try
            {
                return AgeSeal.Bech32("age", new X25519PrivateKeyParameters(key).GeneratePublicKey().GetEncoded());
            }
            finally
            {
                CryptographicOperations.ZeroMemory(key);
            }
        }
    }

    /// <summary>The <c>AGE-SECRET-KEY-1…</c> identity that opens what was sealed to <see cref="Recipient"/>, for a
    /// restore tool.</summary>
    public string Identity
    {
        get
        {
            var key = PrivateKey();
            try
            {
                return AgeSeal.Bech32("AGE-SECRET-KEY-", key).ToUpperInvariant();
            }
            finally
            {
                CryptographicOperations.ZeroMemory(key);
            }
        }
    }

    public override string ToString() => "RecoveryCode(not shown)";
    public bool Equals(RecoveryCode? other) => other is not null && other.Normalized == Normalized;
    public override bool Equals(object? obj) => Equals(obj as RecoveryCode);
    public override int GetHashCode() => Normalized.GetHashCode(StringComparison.Ordinal);
}

/// <summary>**Where the recovery code is kept** (the Mac's <c>RecoveryKeychain</c>): in this PC's secret box only, one
/// name for each fleet (<c>recovery-code/&lt;fleet&gt;</c>), the way the owner's other keys are kept (windows-app-plan-v2.md,
/// 5.4). The app shows, copies, logs and sends the code nowhere: the central vault gets its public key, signed, and a
/// restore reads it from here.</summary>
public static class RecoveryKeeping
{
    /// <summary>The box's name of the code of <paramref name="fleet"/>, a fleet's id (16 small hex characters).</summary>
    public static string Name(string fleet) =>
        VaultIds.IsFleet(fleet) ? "recovery-code/" + fleet : throw new ArgumentException("not a fleet's id", nameof(fleet));

    /// <summary>The code this PC keeps for the fleet, or null.</summary>
    public static RecoveryCode? Code(ISecretBox box, string fleet)
    {
        var kept = box.Read(Name(fleet));
        if (kept is null) return null;
        try
        {
            return RecoveryCode.Read(Encoding.UTF8.GetString(kept));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(kept);
        }
    }

    /// <summary>The code this PC keeps for the fleet, made and kept now **only when the box says that none is there** (the
    /// Mac's <c>FleetKeychainItem.held</c> and <c>mayMake</c>): a read that fails now throws, and so does a kept value that
    /// is no code, and either keeps what is there, because a new code would leave each backup that was sealed to the old
    /// one with no code to open it. **A new code goes in only where the name holds none, in one step**
    /// (<see cref="ISecretBox.WriteNew"/>): of two starts that both read "none", one keeps its code and the other reads
    /// that one back and gives it; and a read that said "none" by mistake (a file that the system did not show for a
    /// moment) writes over nothing. It is read back before it is returned, because a recovery key whose code is not kept
    /// would seal every backup to a key nobody has.</summary>
    public static RecoveryCode Kept(ISecretBox box, string fleet, Func<int, byte[]>? random = null)
    {
        if (Held(box, fleet) is { } held) return held;  // a read that fails throws here, before anything is made
        var made = RecoveryCode.Make(random);
        var bytes = Encoding.UTF8.GetBytes(made.Normalized);
        bool written;
        try
        {
            written = box.WriteNew(Name(fleet), bytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
        if (!written) return Held(box, fleet) ?? throw new SealException("the secret box holds a recovery code that does not read now");
        return Equals(Code(box, fleet), made) ? made : throw new SealException("the secret box did not keep the recovery code");
    }

    /// <summary>The code that the box holds, or null when it says that it holds none. A value that is no code throws.</summary>
    private static RecoveryCode? Held(ISecretBox box, string fleet)
    {
        if (box.Read(Name(fleet)) is not { } held) return null;
        try
        {
            return RecoveryCode.Read(Encoding.UTF8.GetString(held))
                   ?? throw new SealException("the secret box holds a recovery code that does not read now");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(held);
        }
    }
}
