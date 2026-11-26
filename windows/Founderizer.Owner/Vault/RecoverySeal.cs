using System;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Asn1.X9;
using Org.BouncyCastle.Crypto.EC;
using Org.BouncyCastle.Crypto.Engines;
using Org.BouncyCastle.Crypto.Modes;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math;
using ECPoint = Org.BouncyCastle.Math.EC.ECPoint;

namespace Founderizer.Owner.Vault;

/// <summary>**The recovery code's copy for one phone** (the Mac's <c>RecoverySeal</c>, owner feature
/// <c>recovery_copy</c>): once a phone's binding matched a QR of this computer, the code is sealed to that phone's own key
/// agreement key with an ephemeral P-256 key agreement, HKDF-SHA-256 over its shared secret, and AES-GCM. The hub
/// carries the box and cannot open it, and only that phone's chip opens it.
///
/// The box, in standard base64: the ephemeral public point (<c>04 || X || Y</c>, 65 bytes), then AES-GCM's 12-byte
/// nonce, the sealed code and its 16-byte tag. The device's name is bound into the key and the tag. BouncyCastle makes
/// the key agreement and AES-GCM, so the box is the same on every PC.</summary>
public static class RecoverySeal
{
    public const string Info = "founderizer recovery copy v1";

    private static readonly X9ECParameters Curve = CustomNamedCurves.GetByName("P-256");
    private static readonly ECDomainParameters Domain = new(Curve);

    /// <summary>The box for this phone, with a new random ephemeral key and nonce.</summary>
    public static string Seal(ReadOnlySpan<byte> code, string key, string device) => Seal(code, key, device, null, null);

    /// <summary>The box with a test's own <paramref name="ephemeral"/> (a 32-byte scalar) and <paramref name="nonce"/> (12
    /// bytes), or new random ones for null.</summary>
    internal static string Seal(ReadOnlySpan<byte> code, string key, string device, byte[]? ephemeral, byte[]? nonce)
    {
        var theirs = Point(key) ?? throw new SealException("not a phone's recovery key");
        var scalar = ephemeral is null ? NewScalar() : Scalar(ephemeral) ?? throw new SealException("not a P-256 scalar");
        var mine = Domain.G.Multiply(scalar).Normalize().GetEncoded(false);
        var symmetric = Derive(Shared(theirs, scalar), mine, device);
        nonce ??= RandomNumberGenerator.GetBytes(12);
        var plain = code.ToArray();
        try
        {
            if (nonce.Length != 12) throw new SealException("an AES-GCM nonce is 12 bytes");
            var sealedCode = Gcm(true, symmetric, nonce, Bound(device), plain);
            return Convert.ToBase64String([.. mine, .. nonce, .. sealedCode]);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(symmetric);
            CryptographicOperations.ZeroMemory(plain);
        }
    }

    /// <summary>The code from its box, with the phone's own private scalar: a test's, and a phone's chip has its own.
    /// Throws <see cref="SealException"/> for a box that is not one or that does not open.</summary>
    internal static byte[] Open(string box, string device, byte[] privateScalar)
    {
        byte[] raw;
        try
        {
            raw = Convert.FromBase64String(box);
        }
        catch (FormatException)
        {
            throw new SealException("not a recovery box");
        }
        if (raw.Length <= 65 + 12 + 16 || Point(Convert.ToBase64String(raw[..65])) is not { } ephemeral ||
            Scalar(privateScalar) is not { } scalar)
            throw new SealException("not a recovery box");
        var symmetric = Derive(Shared(ephemeral, scalar), raw[..65], device);
        try
        {
            return Gcm(false, symmetric, raw[65..77], Bound(device), raw[77..]);
        }
        catch (Org.BouncyCastle.Crypto.InvalidCipherTextException)
        {
            throw new SealException("the recovery box does not open");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(symmetric);
        }
    }

    internal static byte[] Bound(string device) => Encoding.UTF8.GetBytes(Info + "|" + device);

    /// <summary>CryptoKit's <c>hkdfDerivedSymmetricKey</c>: HKDF-SHA-256 of the shared x coordinate, with the ephemeral
    /// point as its salt and the bound name as its info.</summary>
    private static byte[] Derive(byte[] shared, byte[] ephemeral, string device)
    {
        try
        {
            return HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, ephemeral, Bound(device));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(shared);
        }
    }

    /// <summary>The point of a key in the one form the Mac reads: standard base64 of 65 bytes, 04 first, on the curve.</summary>
    private static ECPoint? Point(string key)
    {
        if (!Founderizer.Core.Base64Strict.TryDecode(key, out var raw) || raw.Length != 65 || raw[0] != 4) return null;
        try
        {
            var point = Curve.Curve.DecodePoint(raw);
            return point.IsValid() && !point.IsInfinity ? point : null;
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private static BigInteger? Scalar(byte[] bytes)
    {
        if (bytes.Length != 32) return null;
        var d = new BigInteger(1, bytes);
        return d.SignValue > 0 && d.CompareTo(Domain.N) < 0 ? d : null;
    }

    private static BigInteger NewScalar()
    {
        while (true)
        {
            var bytes = RandomNumberGenerator.GetBytes(32);
            var d = Scalar(bytes);
            CryptographicOperations.ZeroMemory(bytes);
            if (d is not null) return d;
        }
    }

    private static byte[] Shared(ECPoint theirs, BigInteger scalar)
    {
        var point = theirs.Multiply(scalar).Normalize();
        if (point.IsInfinity) throw new SealException("the key agreement failed");
        return point.AffineXCoord.GetEncoded();
    }

    private static byte[] Gcm(bool seal, byte[] key, byte[] nonce, byte[] bound, byte[] input)
    {
        var cipher = new GcmBlockCipher(new AesEngine());
        cipher.Init(seal, new AeadParameters(new KeyParameter(key), 128, nonce, bound));
        var output = new byte[cipher.GetOutputSize(input.Length)];
        var length = cipher.ProcessBytes(input, 0, input.Length, output, 0);
        length += cipher.DoFinal(output, length);
        return length == output.Length ? output : output[..length];
    }
}
