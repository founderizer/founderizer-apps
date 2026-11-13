using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;

namespace Founderizer.Core;

/// <summary>The owner's signing key, or a device's own signing key: ECDSA P-256 (FleetCore's OwnerKey). On Windows the key
/// lives in the TPM, behind this same interface, in a later slice; here a software key serves the tests and a PC with no
/// TPM, as the Mac uses one on a Mac with no Secure Enclave.</summary>
public interface IOwnerKey
{
    /// <summary>Standard base64, padded, of the 65-byte uncompressed point 04 || X || Y.</summary>
    string PublicKey { get; }

    /// <summary>Standard base64 of the DER signature (SEQUENCE { INTEGER r, INTEGER s }) over SHA-256 of the
    /// statement's UTF-8 bytes.</summary>
    string Sign(string statement);
}

/// <summary>A P-256 key in this process's memory.</summary>
public sealed class SoftwareOwnerKey : IOwnerKey, IDisposable
{
    private readonly ECDsa key;

    private SoftwareOwnerKey(ECDsa key) => this.key = key;

    /// <summary>A new random key.</summary>
    public static SoftwareOwnerKey Create() => new(ECDsa.Create(ECCurve.NamedCurves.nistP256));

    /// <summary>A key from its 32-byte private scalar and, where the platform cannot derive it, its public point.</summary>
    public static SoftwareOwnerKey Import(ReadOnlySpan<byte> privateScalar, string? publicKey = null)
    {
        if (privateScalar.Length != 32) throw new CryptographicException("a P-256 private key is 32 bytes");
        var parameters = new ECParameters { Curve = ECCurve.NamedCurves.nistP256, D = privateScalar.ToArray() };
        if (publicKey is not null)
        {
            var point = P256.Point(publicKey) ?? throw new CryptographicException("not a P-256 public key");
            parameters.Q = new ECPoint { X = point[1..33], Y = point[33..] };
        }
        return new SoftwareOwnerKey(ECDsa.Create(parameters));
    }

    public string PublicKey
    {
        get
        {
            var q = key.ExportParameters(false).Q;
            var point = new byte[65];
            point[0] = 4;
            q.X!.CopyTo(point, 1);
            q.Y!.CopyTo(point, 33);
            return Convert.ToBase64String(point);
        }
    }

    public string Sign(string statement) =>
        Convert.ToBase64String(key.SignData(Encoding.UTF8.GetBytes(statement), HashAlgorithmName.SHA256,
                                            DSASignatureFormat.Rfc3279DerSequence));

    public void Dispose() => key.Dispose();
}

/// <summary>The check of an owner signature, rule for rule as vault.owner_signed reads one: the signature is the standard
/// base64, padded, of a DER signature in its one shortest form; r and s are in 1..n-1, either s; the key is a point of
/// the curve in its uncompressed form; and the hash is SHA-256 of the statement's UTF-8 bytes.</summary>
public static class OwnerSignature
{
    /// <summary>True when one of <paramref name="ownerKeys"/> signed exactly the bytes of <paramref name="statement"/>.
    /// Every wrong shape is false, never an exception.</summary>
    public static bool Verify(IEnumerable<string> ownerKeys, string statement, string signature)
    {
        byte[] digest;
        try
        {
            digest = SHA256.HashData(new UTF8Encoding(false, throwOnInvalidBytes: true).GetBytes(statement));
        }
        catch (EncoderFallbackException)
        {
            return false;               // a text that is not UTF-8 was signed by nobody
        }
        if (!Base64Strict.TryDecode(signature, out var raw) || StrictDer.Read(raw) is not { } rs) return false;
        foreach (var text in ownerKeys)
        {
            if (P256.Point(text) is not { } point) continue;
            try
            {
                using var key = ECDsa.Create(new ECParameters
                {
                    Curve = ECCurve.NamedCurves.nistP256,
                    Q = new ECPoint { X = point[1..33], Y = point[33..] },
                });
                if (key.VerifyHash(digest, rs, DSASignatureFormat.IeeeP1363FixedFieldConcatenation)) return true;
            }
            catch (CryptographicException)
            {
                // not a point of the curve: no key of the owner
            }
        }
        return false;
    }

    public static bool Verify(string ownerKey, string statement, string signature) =>
        Verify([ownerKey], statement, signature);
}

/// <summary>The P-256 facts that the checks need.</summary>
public static class P256
{
    /// <summary>The order n of the base point.</summary>
    public static readonly byte[] Order = Convert.FromHexString(
        "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551");

    /// <summary>The 65 bytes of a public key in the one form that vault.owner_key reads: standard base64, padded, of
    /// 04 || X || Y. Null for anything else. That the point is on the curve is checked where it is imported.</summary>
    public static byte[]? Point(string text)
    {
        if (!Base64Strict.TryDecode(text, out var raw) || raw.Length != 65 || raw[0] != 4) return null;
        return raw;
    }
}

/// <summary>The strict reading of a DER signature (vault.der_signature): one SEQUENCE of two INTEGERs, each positive and
/// in its shortest form, every length in its one-byte form, and nothing after it.</summary>
public static class StrictDer
{
    /// <summary>r || s as two 32-byte numbers, or null.</summary>
    public static byte[]? Read(ReadOnlySpan<byte> raw)
    {
        if (raw.Length < 2 || raw[0] != 0x30 || raw[1] >= 0x80 || raw[1] != raw.Length - 2) return null;
        var body = raw[2..];
        var output = new byte[64];
        for (var i = 0; i < 2; i++)
        {
            if (body.Length < 3 || body[0] != 0x02 || body[1] >= 0x80 || body[1] < 1 || body[1] > body.Length - 2)
                return null;
            int size = body[1];
            var number = body.Slice(2, size);
            if ((number[0] & 0x80) != 0 || (size > 1 && number[0] == 0 && (number[1] & 0x80) == 0)) return null;
            var significant = number;
            while (significant.Length > 0 && significant[0] == 0) significant = significant[1..];
            if (significant.Length == 0 || significant.Length > 32) return null;     // zero, or longer than n
            var slot = output.AsSpan(i * 32, 32);
            significant.CopyTo(slot[(32 - significant.Length)..]);
            if (slot.SequenceCompareTo(P256.Order) >= 0) return null;               // not below n
            body = body[(2 + size)..];
        }
        return body.IsEmpty ? output : null;
    }
}

/// <summary>Base64 as vault.py and hub.py check it: the standard alphabet, padded, no white space, and the one text
/// that encodes the bytes (base64.b64encode(raw) == text).</summary>
public static class Base64Strict
{
    public static bool TryDecode(string? text, out byte[] bytes)
    {
        bytes = [];
        if (text is null || text.Length % 4 != 0) return false;
        foreach (var c in text)
            if (!(c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '+' or '/' or '='))
                return false;
        try
        {
            bytes = Convert.FromBase64String(text);
        }
        catch (FormatException)
        {
            return false;
        }
        return Convert.ToBase64String(bytes) == text;
    }
}

/// <summary>A device's signing key bound to the one-time value of the Mac's QR (FleetCore's DeviceBinding, owner feature
/// `door_calls`): HMAC-SHA256 with the 32 bytes of `bind` as its key, over the 65 bytes of the point. The hub never sees
/// `bind`, so it can forge no binding of a key of its own.</summary>
public static class DeviceBinding
{
    /// <summary>A new one-time value for one QR: 32 random bytes, base64url without padding.</summary>
    public static string NewBind() => Base64Url(RandomNumberGenerator.GetBytes(32));

    /// <summary>The binding of a public key (standard base64 of 04 || X || Y) to <paramref name="bind"/>, as standard
    /// base64, or null for a value that is not one.</summary>
    public static string? Binding(string bind, string key)
    {
        if (FromBase64Url(bind) is not { Length: 32 } secret) return null;
        if (!TryStandard(key, out var point) || point.Length != 65 || point[0] != 4) return null;
        return Convert.ToBase64String(HMACSHA256.HashData(secret, point));
    }

    /// <summary>The binding is this key's binding to <paramref name="bind"/>, compared in constant time.</summary>
    public static bool Matches(string bind, string key, string binding) =>
        Binding(bind, key) is { } made &&
        CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(made), Encoding.ASCII.GetBytes(binding));

    internal static string Base64Url(ReadOnlySpan<byte> data) =>
        Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    internal static byte[]? FromBase64Url(string text)
    {
        var standard = text.Replace('-', '+').Replace('_', '/');
        while (standard.Length % 4 != 0) standard += "=";
        return TryStandard(standard, out var bytes) ? bytes : null;
    }

    /// <summary>Standard base64 with its padding, as Foundation's Data(base64Encoded:) reads it: no white space.</summary>
    private static bool TryStandard(string text, out byte[] bytes)
    {
        bytes = [];
        if (text.Length % 4 != 0) return false;
        foreach (var c in text)
            if (!(c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '+' or '/' or '='))
                return false;
        try
        {
            bytes = Convert.FromBase64String(text);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
