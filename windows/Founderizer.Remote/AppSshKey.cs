using System;
using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;

namespace Founderizer.Remote;

/// <summary>
/// **The app's own SSH key** (the Mac's <c>AppSSHKey</c>): one Ed25519 key with no passphrase, made once on the PC.
/// Its private half is 32 bytes (the Ed25519 seed of RFC 8032) that live only in the secret box, under
/// <see cref="BoxName"/>; it is never a file, so <c>ssh.exe</c>'s rules for a key file do not apply and no copy of it
/// sits on the disk as text. Its public half is the line that goes into a server's <c>authorized_keys</c>.
/// </summary>
public static class AppSshKey
{
    /// <summary>The name of the private half in the secret box.</summary>
    public const string BoxName = "app-ssh-key";

    /// <summary>The comment of the public line. It names no PC: the PC's name can be the owner's own.</summary>
    public const string Comment = "founderizer";

    /// <summary>The length of the private half.</summary>
    public const int Length = 32;

    /// <summary>A new key: the private half for the box, and the public line.</summary>
    public readonly record struct Made(byte[] PrivateKey, string PublicLine);

    /// <summary>Makes a new key from the system's random numbers.</summary>
    public static Made Make()
    {
        var seed = RandomNumberGenerator.GetBytes(Length);
        return new Made(seed, PublicLine(seed));
    }

    /// <summary>The public line of a private half: "<c>ssh-ed25519 &lt;base64&gt; founderizer</c>".</summary>
    public static string PublicLine(ReadOnlySpan<byte> privateKey) =>
        "ssh-ed25519 " + Convert.ToBase64String(PublicBlob(privateKey)) + " " + Comment;

    /// <summary>The SSH blob of the public half: the string "ssh-ed25519" and the 32-byte point, each with its length.</summary>
    internal static byte[] PublicBlob(ReadOnlySpan<byte> privateKey)
    {
        if (privateKey.Length != Length) throw new ArgumentException("The app's SSH key is 32 bytes.", nameof(privateKey));
        var point = new Ed25519PrivateKeyParameters(privateKey).GeneratePublicKey().GetEncoded();
        var type = Encoding.ASCII.GetBytes("ssh-ed25519");
        var blob = new byte[4 + type.Length + 4 + point.Length];
        BinaryPrimitives.WriteUInt32BigEndian(blob, (uint)type.Length);
        type.CopyTo(blob, 4);
        BinaryPrimitives.WriteUInt32BigEndian(blob.AsSpan(4 + type.Length), (uint)point.Length);
        point.CopyTo(blob, 8 + type.Length);
        return blob;
    }
}
