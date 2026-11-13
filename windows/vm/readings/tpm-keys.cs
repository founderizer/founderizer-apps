// Reading of slice 1.0 (app/windows/vm/README.md): P-256 keys in the TPM.
//
// It describes the "Microsoft Platform Crypto Provider" (the TPM's key storage provider), makes a P-256
// signing key in it, signs a message in DER form and verifies it in software with the exported public key.
// Then it makes a P-256 key agreement key in it, agrees a secret with a software key, and compares the raw
// secret with the software side. It deletes both keys at the end. Run it on Windows:
//
//   dotnet run tpm-keys.cs
//
// Two findings of 13 November 2026 are in the code: the provider refuses a key usage property on an ECDH key,
// and an agreement needs the peer's public key imported into the same provider, which .NET's ECDiffieHellmanCng
// does not do; so the agreement calls CNG directly.
//
// The exit code is 0 when the signature and the raw secret pass.

// Native AOT needs Microsoft's C++ linker, which the build VM does not have (README.md, "Limits").
#:property PublishAot=false
// The Windows target framework, so that its Windows-only calls raise no warning (app/windows/Directory.Build.props
// makes every warning an error).
#:property TargetFramework=net10.0-windows
// No package, so no lock file beside this program (the shared settings ask for one).
#:property RestorePackagesWithLockFile=false

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

const string ProviderName = "Microsoft Platform Crypto Provider";
var provider = new CngProvider(ProviderName);
string tag = Guid.NewGuid().ToString("N")[..8];
int failures = 0;

Console.WriteLine($"os: {RuntimeInformation.OSDescription}, process: {RuntimeInformation.ProcessArchitecture}, .NET {Environment.Version}");
Console.WriteLine($"provider: {ProviderName}");
Native.DescribeProvider(ProviderName);

CngKey? signKey = null;
try
{
    signKey = CngKey.Create(CngAlgorithm.ECDsaP256, "fz-reading-sign-" + tag, new CngKeyCreationParameters
    {
        Provider = provider,
        KeyUsage = CngKeyUsages.Signing,
        ExportPolicy = CngExportPolicies.None,
    });
    Describe(signKey, "signing key");
    using var tpm = new ECDsaCng(signKey);
    byte[] message = Encoding.UTF8.GetBytes("{\"kind\":\"reading\",\"n\":1}");
    byte[] der = tpm.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
    Console.WriteLine($"signature: {der.Length} bytes, first byte 0x{der[0]:x2} (DER SEQUENCE is 0x30): {Convert.ToHexString(der)}");
    using var software = ECDsa.Create(tpm.ExportParameters(false));
    bool verifies = software.VerifyData(message, der, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
    byte[] changed = (byte[])message.Clone();
    changed[^2] ^= 1;
    bool changedVerifies = software.VerifyData(changed, der, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
    Console.WriteLine($"verifies in software with the exported public key: {verifies}; a changed message verifies: {changedVerifies}");
    Console.WriteLine($"public key (SubjectPublicKeyInfo): {Convert.ToBase64String(software.ExportSubjectPublicKeyInfo())}");
    if (der[0] != 0x30 || !verifies || changedVerifies) failures++;
}
catch (Exception e)
{
    Console.WriteLine($"signing FAILED: {e.GetType().Name}: {e.Message}");
    failures++;
}
finally
{
    signKey?.Delete();
}

CngKey? agreeKey = null;
try
{
    // The ways CNG names a P-256 key agreement key; the first that the provider takes is used.
    var ways = new (string Name, Func<CngKey> Make)[]
    {
        ("ECDH_P256, key usage KeyAgreement", () => CngKey.Create(CngAlgorithm.ECDiffieHellmanP256, "fz-reading-agree-a-" + tag,
            new CngKeyCreationParameters { Provider = provider, KeyUsage = CngKeyUsages.KeyAgreement })),
        ("ECDH_P256, no key usage", () => CngKey.Create(CngAlgorithm.ECDiffieHellmanP256, "fz-reading-agree-b-" + tag,
            new CngKeyCreationParameters { Provider = provider })),
        ("ECDH with the curve nistP256", () =>
        {
            var parameters = new CngKeyCreationParameters { Provider = provider };
            parameters.Parameters.Add(new CngProperty("ECCCurveName", Encoding.Unicode.GetBytes("nistP256\0"), CngPropertyOptions.None));
            return CngKey.Create(CngAlgorithm.ECDiffieHellman, "fz-reading-agree-c-" + tag, parameters);
        }),
        ("ECDSA_P256 with key usage KeyAgreement and Signing", () => CngKey.Create(CngAlgorithm.ECDsaP256, "fz-reading-agree-d-" + tag,
            new CngKeyCreationParameters { Provider = provider, KeyUsage = CngKeyUsages.KeyAgreement | CngKeyUsages.Signing })),
    };
    foreach (var way in ways)
    {
        try
        {
            agreeKey = way.Make();
            Console.WriteLine($"key agreement key made as: {way.Name}");
            break;
        }
        catch (CryptographicException e)
        {
            Console.WriteLine($"key agreement key as {way.Name}: refused, 0x{e.HResult:x8} {e.Message}");
        }
    }
    if (agreeKey is null) throw new CryptographicException("the provider made no P-256 key agreement key");
    Describe(agreeKey, "key agreement key");
    using var tpm = new ECDiffieHellmanCng(agreeKey);
    using var peer = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
    using var tpmPublic = ECDiffieHellman.Create(tpm.ExportParameters(false));
    byte[] z = peer.DeriveRawSecretAgreement(tpmPublic.PublicKey);
    // CNG agrees a secret only between two keys of one provider, so the peer's public key goes into the TPM's
    // provider first. .NET's own routes import it into the software provider ("The supplied handle is invalid"),
    // or pass import flags that the TPM's provider refuses ("Invalid flags specified"), so these steps call CNG.
    using var peerCng = new ECDiffieHellmanCng(ECCurve.NamedCurves.nistP256);
    peerCng.ImportParameters(peer.ExportParameters(true));
    byte[] blob = peerCng.Key.Export(CngKeyBlobFormat.EccPublicBlob);
    byte[]? raw = Native.AgreeRaw(agreeKey, ProviderName, blob);
    if (raw is null)
    {
        failures++;
    }
    else
    {
        bool equal = raw.AsSpan().SequenceEqual(z);
        Console.WriteLine($"raw secret: {raw.Length} bytes, equal to the software side: {equal}");
        if (raw.Length != 32 || !equal) failures++;
    }
}
catch (Exception e)
{
    Console.WriteLine($"key agreement FAILED: {e.GetType().Name}: {e.Message}");
    failures++;
}
finally
{
    agreeKey?.Delete();
}

Console.WriteLine(failures == 0 ? "RESULT: pass" : $"RESULT: {failures} failure(s)");
return failures == 0 ? 0 : 1;

static void Describe(CngKey key, string what)
{
    string implementation;
    try
    {
        uint flags = BitConverter.ToUInt32(key.GetProperty("Impl Type", CngPropertyOptions.None).GetValue()!);
        implementation = $"0x{flags:x} (hardware flag {(flags & 1) != 0})";
    }
    catch (Exception e)
    {
        implementation = "unknown: " + e.Message;
    }
    Console.WriteLine($"{what}: {key.Algorithm.Algorithm}, {key.KeySize} bits, provider {key.Provider?.Provider}, machine key {key.IsMachineKey}, implementation {implementation}");
}

static class Native
{
    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    static extern int NCryptOpenStorageProvider(out IntPtr provider, string name, int flags);
    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    static extern int NCryptGetProperty(IntPtr handle, string property, byte[]? output, int size, out int written, int flags);
    [DllImport("ncrypt.dll")]
    static extern int NCryptEnumAlgorithms(IntPtr provider, int operations, out int count, out IntPtr list, int flags);
    [DllImport("ncrypt.dll")]
    static extern int NCryptFreeBuffer(IntPtr buffer);
    [DllImport("ncrypt.dll")]
    static extern int NCryptFreeObject(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    struct AlgorithmName { public IntPtr Name; public int Class; public int Operations; public int Flags; }

    // Prints the provider's platform (which TPM it uses), its implementation type, and the algorithms that it
    // offers for asymmetric encryption, secret agreement and signatures.
    public static void DescribeProvider(string name)
    {
        int status = NCryptOpenStorageProvider(out IntPtr provider, name, 0);
        if (status != 0) { Console.WriteLine($"cannot open the provider: 0x{status:x8}"); return; }
        try
        {
            Console.WriteLine($"provider platform (PCP_PLATFORM_TYPE): {Text(provider, "PCP_PLATFORM_TYPE")}");
            byte[]? type = Bytes(provider, "Impl Type");
            Console.WriteLine(type is null ? "provider implementation type: unknown"
                : $"provider implementation type: 0x{BitConverter.ToUInt32(type):x} (hardware flag {(BitConverter.ToUInt32(type) & 1) != 0})");
            // NCRYPT_ASYMMETRIC_ENCRYPTION_OPERATION 4, NCRYPT_SECRET_AGREEMENT_OPERATION 8, NCRYPT_SIGNATURE_OPERATION 16.
            status = NCryptEnumAlgorithms(provider, 4 | 8 | 16, out int count, out IntPtr list, 0);
            if (status != 0) { Console.WriteLine($"cannot list the algorithms: 0x{status:x8}"); return; }
            var names = new List<string>();
            int size = Marshal.SizeOf<AlgorithmName>();
            for (int i = 0; i < count; i++)
            {
                var algorithm = Marshal.PtrToStructure<AlgorithmName>(list + i * size);
                var operations = new List<string>();
                if ((algorithm.Operations & 4) != 0) operations.Add("encryption");
                if ((algorithm.Operations & 8) != 0) operations.Add("agreement");
                if ((algorithm.Operations & 16) != 0) operations.Add("signature");
                names.Add($"{Marshal.PtrToStringUni(algorithm.Name)} ({string.Join("+", operations)})");
            }
            NCryptFreeBuffer(list);
            Console.WriteLine($"provider algorithms: {string.Join(", ", names)}");
        }
        finally
        {
            NCryptFreeObject(provider);
        }
    }

    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    static extern int NCryptImportKey(IntPtr provider, IntPtr importKey, string blobType, IntPtr parameters, out IntPtr key, byte[] data, int size, int flags);
    [DllImport("ncrypt.dll")]
    static extern int NCryptSecretAgreement(SafeNCryptKeyHandle privateKey, IntPtr publicKey, out IntPtr secret, int flags);
    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
    static extern int NCryptDeriveKey(IntPtr secret, string kdf, IntPtr parameters, byte[]? output, int size, out int written, int flags);

    // Imports the peer's public key into the provider, agrees a secret with the private key, and returns the raw
    // secret Z (BCRYPT_KDF_RAW_SECRET, "TRUNCATE"), big-endian as in the standard (CNG gives it little-endian).
    // It prints each step's status and returns null at the first step that fails.
    public static byte[]? AgreeRaw(CngKey privateKey, string providerName, byte[] peerPublicBlob)
    {
        IntPtr provider = IntPtr.Zero, publicKey = IntPtr.Zero, secret = IntPtr.Zero;
        try
        {
            int status = NCryptOpenStorageProvider(out provider, providerName, 0);
            if (status != 0) { Console.WriteLine($"open the provider: 0x{status:x8}"); return null; }
            status = NCryptImportKey(provider, IntPtr.Zero, "ECCPUBLICBLOB", IntPtr.Zero, out publicKey, peerPublicBlob, peerPublicBlob.Length, 0);
            Console.WriteLine($"import the peer's public key into the TPM's provider: 0x{status:x8}");
            if (status != 0) return null;
            using SafeNCryptKeyHandle handle = privateKey.Handle;
            status = NCryptSecretAgreement(handle, publicKey, out secret, 0);
            Console.WriteLine($"secret agreement in the TPM's provider: 0x{status:x8}");
            if (status != 0) return null;
            status = NCryptDeriveKey(secret, "TRUNCATE", IntPtr.Zero, null, 0, out int size, 0);
            if (status != 0) { Console.WriteLine($"raw secret (TRUNCATE): 0x{status:x8}"); return null; }
            var output = new byte[size];
            status = NCryptDeriveKey(secret, "TRUNCATE", IntPtr.Zero, output, size, out size, 0);
            Console.WriteLine($"raw secret (TRUNCATE): 0x{status:x8}");
            if (status != 0) return null;
            Array.Resize(ref output, size);
            Array.Reverse(output);
            return output;
        }
        finally
        {
            if (secret != IntPtr.Zero) NCryptFreeObject(secret);
            if (publicKey != IntPtr.Zero) NCryptFreeObject(publicKey);
            if (provider != IntPtr.Zero) NCryptFreeObject(provider);
        }
    }

    static byte[]? Bytes(IntPtr handle, string property)
    {
        if (NCryptGetProperty(handle, property, null, 0, out int size, 0) != 0 || size == 0) return null;
        var output = new byte[size];
        return NCryptGetProperty(handle, property, output, size, out _, 0) == 0 ? output : null;
    }

    static string Text(IntPtr handle, string property)
    {
        byte[]? output = Bytes(handle, property);
        return output is null ? "unknown" : Encoding.Unicode.GetString(output).TrimEnd('\0');
    }
}
