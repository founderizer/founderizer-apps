using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Founderizer.Core;
using Org.BouncyCastle.Crypto.Parameters;

namespace Founderizer.Owner.Vault;

/// <summary>**The owner's access key of one fleet** (the Mac's <c>OwnerAccessKey</c>): the way back for an owner who lost
/// the computer that he runs his fleet from and still has a copy of the fleet. It is one Ed25519 SSH key, made on the owner's
/// computer, once for a fleet. Its public half is a line of root's <c>authorized_keys</c> on each Linux server of the fleet;
/// its private half is in this PC's secret box (<see cref="OwnerAccessKeeping"/>) and in each copy of the fleet, as an
/// OpenSSH private key file.
///
/// **It is not the recovery code**: a copy also carries the central vault's store, sealed to the key that the recovery code
/// derives, and a copy that carried the code too would open every secret of the fleet by itself. It prints as its type's
/// name, so no log, report or crash record can carry it by accident.</summary>
public sealed class OwnerAccessKey : IEquatable<OwnerAccessKey>
{
    /// <summary>The comment of its <c>authorized_keys</c> line and of its key file.</summary>
    public const string Comment = "founderizer-owner-access";
    private const string Kind = "ssh-ed25519";
    private static readonly byte[] Magic = [.. "openssh-key-v1"u8, 0];

    private readonly byte[] seed;
    private readonly byte[] publicKey;

    private OwnerAccessKey(byte[] seed)
    {
        this.seed = seed;
        publicKey = new Ed25519PrivateKeyParameters(seed).GeneratePublicKey().GetEncoded();
    }

    /// <summary>The key of these 32 bytes, or null when they are not a key.</summary>
    public static OwnerAccessKey? Of(ReadOnlySpan<byte> seed) => seed.Length == 32 ? new OwnerAccessKey(seed.ToArray()) : null;

    /// <summary>A new key from the system's random source.</summary>
    public static OwnerAccessKey Make(Func<int, byte[]>? random = null)
    {
        var bytes = (random ?? AgeSeal.SecureRandom)(32);
        try
        {
            return Of(bytes) ?? throw new SealException("the random source gave no bytes of that size");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    /// <summary>The 32 bytes of the Ed25519 private key, which are all the key is. The caller clears the copy.</summary>
    public byte[] Seed() => (byte[])seed.Clone();

    /// <summary>Its public half in SSH's own form: the key's kind and its 32 bytes, each with its length before it.</summary>
    private byte[] PublicBlob => [.. Text(Kind), .. Text(publicKey)];

    /// <summary>The line of <c>authorized_keys</c>: "ssh-ed25519 AAAA… founderizer-owner-access".</summary>
    public string PublicLine => $"{Kind} {Convert.ToBase64String(PublicBlob)} {Comment}";

    /// <summary>Its fingerprint as <c>ssh-keygen -l</c> prints it. It names the key where the key itself must not be
    /// written.</summary>
    public string Fingerprint => "SHA256:" + Convert.ToBase64String(SHA256.HashData(PublicBlob)).Replace("=", "", StringComparison.Ordinal);

    /// <summary>**The key as an OpenSSH private key file**, with no passphrase, which is what a copy carries: the same bytes
    /// for the same key, so a copy that gets the key twice gets one file. The two check numbers come from the public half,
    /// so the file of a key never changes.</summary>
    public string PrivateFile()
    {
        var check = SHA256.HashData([.. "founderizer check"u8, .. publicKey])[..4];
        // Every array that holds the seed is cleared once the file's text is made.
        byte[] both = [.. seed, .. publicKey], halves = Text(both), inner = [], whole = [];
        var secret = new List<byte>(256);
        string text;
        try
        {
            secret.AddRange([.. check, .. check, .. Text(Kind), .. Text(publicKey)]);
            secret.AddRange(halves);
            secret.AddRange(Text(Comment));
            for (byte pad = 1; secret.Count % 8 != 0; pad++) secret.Add(pad);
            inner = [.. secret];
            whole = [.. Magic, .. Text("none"), .. Text("none"), .. Text(""), .. Number(1), .. Text(PublicBlob), .. Number((uint)inner.Length), .. inner];
            text = Convert.ToBase64String(whole);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(both);
            CryptographicOperations.ZeroMemory(halves);
            CryptographicOperations.ZeroMemory(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(secret));
            CryptographicOperations.ZeroMemory(inner);
            CryptographicOperations.ZeroMemory(whole);
        }
        var file = new StringBuilder("-----BEGIN OPENSSH PRIVATE KEY-----\n");
        for (var at = 0; at < text.Length; at += 70) file.Append(text, at, Math.Min(70, text.Length - at)).Append('\n');
        return file.Append("-----END OPENSSH PRIVATE KEY-----\n").ToString();
    }

    /// <summary>The key that an OpenSSH private key file holds, when it is one Ed25519 key with no passphrase and its two
    /// halves belong together; else null. The file comes out of a copy, which is a file like any other: nothing of it is
    /// trusted before its own public half is made again from its private half.</summary>
    public static OwnerAccessKey? Read(string file)
    {
        var lines = file.Split(['\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029'], StringSplitOptions.RemoveEmptyEntries)
                        .Select(FoundationText.TrimBlanks).ToList();
        if (lines.Count < 3 || lines[0] != "-----BEGIN OPENSSH PRIVATE KEY-----" || lines[^1] != "-----END OPENSSH PRIVATE KEY-----") return null;
        if (!Base64Strict.TryDecode(string.Concat(lines.Skip(1).SkipLast(1)), out var whole)) return null;
        try
        {
            if (whole.Length > 4096 || !whole.AsSpan().StartsWith(Magic)) return null;
            var reader = new SshReader(whole.AsSpan(Magic.Length));
            if (!reader.Is("none"u8) || !reader.Is("none"u8) || !reader.Is([]) || !reader.Number(out var keys) || keys != 1 ||
                !reader.Text(out var blob) || !reader.Text(out var secret) || !reader.AtEnd) return null;
            var inner = new SshReader(secret);
            if (!inner.Number(out var first) || !inner.Number(out var second) || first != second || !inner.Is("ssh-ed25519"u8) ||
                !inner.Text(out var half) || half.Length != 32 || !inner.Text(out var both) || both.Length != 64 ||
                !both[32..].SequenceEqual(half) || !inner.Text(out _)) return null;
            return Of(both[..32]) is { } key && half.SequenceEqual(key.publicKey) && blob.SequenceEqual(key.PublicBlob) ? key : null;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(whole);      // the decoded file holds the private half
        }
    }

    public override string ToString() => "OwnerAccessKey";
    public bool Equals(OwnerAccessKey? other) => other is not null && CryptographicOperations.FixedTimeEquals(seed, other.seed);
    public override bool Equals(object? obj) => Equals(obj as OwnerAccessKey);
    public override int GetHashCode() => BitConverter.ToInt32(publicKey);

    /// <summary>A number as SSH writes it: four bytes, the highest first.</summary>
    private static byte[] Number(uint value) => [(byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value];
    /// <summary>Bytes as SSH writes them: their count as a number, then the bytes.</summary>
    private static byte[] Text(byte[] bytes) => [.. Number((uint)bytes.Length), .. bytes];
    private static byte[] Text(string text) => Text(Encoding.UTF8.GetBytes(text));

    /// <summary>Reads SSH's numbers and strings out of some bytes, and gives false past their end.</summary>
    private ref struct SshReader(ReadOnlySpan<byte> data)
    {
        private ReadOnlySpan<byte> rest = data;

        public readonly bool AtEnd => rest.IsEmpty;

        public bool Number(out uint value)
        {
            value = 0;
            if (rest.Length < 4) return false;
            value = (uint)(rest[0] << 24 | rest[1] << 16 | rest[2] << 8 | rest[3]);
            rest = rest[4..];
            return true;
        }

        public bool Text(out ReadOnlySpan<byte> value)
        {
            value = default;
            if (!Number(out var count) || count > rest.Length) return false;
            value = rest[..(int)count];
            rest = rest[(int)count..];
            return true;
        }

        public bool Is(ReadOnlySpan<byte> expected) => Text(out var value) && value.SequenceEqual(expected);
    }
}

/// <summary>**Where the owner's access key is kept** (the Mac's <c>OwnerAccessKeychain</c>): in this PC's secret box only,
/// one name for each fleet (<c>owner-access/&lt;fleet&gt;</c>). The app shows and logs it nowhere; it goes into the copies of
/// that fleet, and its public half to the fleet's servers.</summary>
public static class OwnerAccessKeeping
{
    public static string Name(string fleet) =>
        VaultIds.IsFleet(fleet) ? "owner-access/" + fleet : throw new ArgumentException("not a fleet's id", nameof(fleet));

    /// <summary>The key this PC keeps for the fleet, or null.</summary>
    public static OwnerAccessKey? Key(ISecretBox box, string fleet)
    {
        var kept = box.Read(Name(fleet));
        if (kept is null) return null;
        try
        {
            return OwnerAccessKey.Of(kept);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(kept);
        }
    }

    /// <summary>The key this PC keeps for the fleet, made and kept now **only when the box says that none is there** (the
    /// Mac's <c>FleetKeychainItem.held</c> and <c>mayMake</c>): a read that fails now throws, and so does a kept value that
    /// is no key, and either keeps what is there, because a new key would no longer match the key in the fleet's copies.
    /// **A new key goes in only where the name holds none, in one step** (<see cref="ISecretBox.WriteNew"/>): of two starts
    /// that both read "none", one keeps its key and the other reads that one back and gives it. It is read back before it
    /// is returned, because a key that is not kept would be a line on the servers that no copy can use.</summary>
    public static OwnerAccessKey Kept(ISecretBox box, string fleet, Func<int, byte[]>? random = null)
    {
        if (Held(box, fleet) is { } held) return held;  // a read that fails throws here, before anything is made
        var made = OwnerAccessKey.Make(random);
        var seed = made.Seed();
        bool written;
        try
        {
            written = box.WriteNew(Name(fleet), seed);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(seed);
        }
        if (!written) return Held(box, fleet) ?? throw new SealException("the secret box holds an owner access key that does not read now");
        return made.Equals(Key(box, fleet)) ? made : throw new SealException("the secret box did not keep the owner access key");
    }

    /// <summary>The key that the box holds, or null when it says that it holds none. A value that is no key throws.</summary>
    private static OwnerAccessKey? Held(ISecretBox box, string fleet)
    {
        if (box.Read(Name(fleet)) is not { } held) return null;
        try
        {
            return OwnerAccessKey.Of(held) ?? throw new SealException("the secret box holds an owner access key that does not read now");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(held);
        }
    }

    /// <summary>Keeps this key for the fleet, in place of any earlier one: a new PC keeps the key that it took from a copy.
    /// The one write here that replaces a value.</summary>
    public static void Keep(ISecretBox box, OwnerAccessKey key, string fleet)
    {
        var seed = key.Seed();
        try
        {
            box.Write(Name(fleet), seed);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(seed);
        }
        if (!key.Equals(Key(box, fleet))) throw new SealException("the secret box did not keep the owner access key");
    }
}
