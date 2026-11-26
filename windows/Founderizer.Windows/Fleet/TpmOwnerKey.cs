using System;
using System.Buffers;
using System.Buffers.Text;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>**The owner key in this PC's TPM** (windows-app-plan-v2.md, section 5.4, and piece U4; the Mac's
/// EnclaveOwnerKey, FleetCore/OwnerKey.swift): ECDSA P-256 in the TPM's own key storage ("Microsoft Platform Crypto
/// Provider"), made there for this Windows user, not exportable and with no prompt, so that its private half never leaves
/// the chip. The app hands the TPM the statement's hash, and the TPM hands back the signature. Its public half and its
/// signature have the forms of <see cref="IOwnerKey"/>: the point as standard base64, and the DER signature in its one
/// shortest form, which .NET makes from the TPM's r and s. **What it does not guard against, as on the Mac:** a program
/// that runs as the owner's Windows user can ask the TPM to sign with it.</summary>
internal sealed class TpmOwnerKey : IOwnerKey, IDisposable
{
    /// <summary>The TPM's key storage provider of Windows (measured in the build VM, app/windows/vm/readings/tpm-keys.cs).</summary>
    public const string Provider = "Microsoft Platform Crypto Provider";

    private readonly CngKey cng;
    private readonly ECDsaCng key;

    internal TpmOwnerKey(CngKey cng)
    {
        this.cng = cng;
        key = new ECDsaCng(cng);
    }

    /// <summary>The key's name in the TPM's storage (a key that this class holds is always a named one).</summary>
    internal string Name => cng.KeyName ?? "";

    /// <summary>Where it is, and what it lets go: its provider, whether its private half may leave it (never), whether
    /// it asks anything (never), and whether it is the machine's key (no: this Windows user's).</summary>
    internal string? ProviderName => cng.Provider?.Provider;
    internal CngExportPolicies ExportPolicy => cng.ExportPolicy;
    internal CngUIProtectionLevels Prompt => cng.UIPolicy.ProtectionLevel;
    internal bool IsMachineKey => cng.IsMachineKey;

    public string PublicKey => OwnerKeys.Point(key.ExportParameters(false));

    public string Sign(string statement) =>
        Convert.ToBase64String(key.SignData(Encoding.UTF8.GetBytes(statement), HashAlgorithmName.SHA256,
                                            DSASignatureFormat.Rfc3279DerSequence));

    public void Dispose()
    {
        key.Dispose();
        cng.Dispose();
    }
}

/// <summary>What <see cref="OwnerKeys.Key"/> found for a fleet.</summary>
internal enum OwnerKeyState
{
    /// <summary>The key, of the kind that was made.</summary>
    Held,
    /// <summary>No value in the box: no owner key was made for this fleet on this PC.</summary>
    None,
    /// <summary>A value is there, but its key cannot be used now: the box's value does not open, it is not an owner
    /// key's, or the TPM does not answer (busy, not ready, a lockout). A later try can find it again.</summary>
    Unavailable,
    /// <summary>The box names a key that the provider says it does not have (NTE_BAD_KEYSET; measured by deleting the
    /// key). What a clear of the TPM gives is not measured: it may be this, or Unavailable for good.</summary>
    Gone,
}

/// <summary>The outcome of a lookup: the key when it is <see cref="OwnerKeyState.Held"/>, and for the others the code
/// that Windows gave (0 when none) and why, in words for a log, never a value.</summary>
internal readonly record struct OwnerKeyLookup(OwnerKeyState State, IOwnerKey? Key = null, int Code = 0, string Why = "");

/// <summary>**Where this PC keeps the owner key of each fleet** (windows-app-plan-v2.md, section 5.4; the Mac's
/// OwnerKeychain): one value of the secret box for each fleet, <c>owner-key/&lt;fleet id&gt;</c>. For a key in the TPM it
/// holds the key's name there, for a software key the key itself, and for both the public half, as the Mac's Keychain
/// item holds the enclave's wrapped key or the software key. So a later start finds the same key, of the same kind.
///
/// **A PC whose TPM gives no P-256 key still gets one** (section 8.12): a software key, kept in the box, as on a Mac
/// with no Secure Enclave. Only <see cref="GivesNoKey"/> says that: a TPM that is busy, not ready yet, or in a lockout
/// gives its code to the caller, and the box stays as it was, so a key in the TPM is never traded for a software key by a
/// failure that passes.
///
/// **Nothing here replaces a key.** <see cref="Make"/> makes a key only for a fleet whose box value is absent, and
/// deletes nothing; <see cref="Key"/> tells a fleet with no key (<see cref="OwnerKeyState.None"/>) from one whose key
/// cannot be used now (<see cref="OwnerKeyState.Unavailable"/>) or that the provider says it does not have
/// (<see cref="OwnerKeyState.Gone"/>). A replacement is a later, separate step that the owner asks for. One lock for each
/// fleet holds a lookup and a make apart in one process, and the box takes the value only where the name holds none
/// (<see cref="ISecretBox.WriteNew"/>), so of two processes that make the key at once one wins and the other deletes its
/// own new key. Nothing here asks the owner anything, and nothing draws.</summary>
internal sealed partial class OwnerKeys
{
    private const string InTpm = "tpm";
    private const string InSoftware = "software";

    /// <summary>NTE_BAD_KEYSET: the provider has no key of that name.</summary>
    internal const int NoSuchKey = unchecked((int)0x80090016);

    /// <summary>NTE_DEVICE_NOT_READY: CNG's code for a new key of the TPM's provider on a PC with no TPM (measured on 24
    /// November 2026 on an Azure machine with its vTPM turned off), and also its code for a TPM that is not ready yet.</summary>
    internal const int DeviceNotReady = unchecked((int)0x80090030);

    /// <summary>**What TBS (Tbsi_GetDeviceInfo, which any user may call) says of a PC whose TPM gives no key**: no TPM
    /// (TBS_E_TPM_NOT_FOUND, measured with the vTPM turned off) and the TPM's services turned off (TBS_E_SERVICE_DISABLED).
    /// Only together with CNG's NTE_DEVICE_NOT_READY.</summary>
    internal static readonly IReadOnlyDictionary<int, string> NoTpm = new Dictionary<int, string>
    {
        [unchecked((int)0x8028400F)] = "TBS_E_TPM_NOT_FOUND",
        [unchecked((int)0x80284010)] = "TBS_E_SERVICE_DISABLED",
    };

    /// <summary>**CNG's codes of a provider that this PC does not have**: STATUS_NOT_FOUND (measured with a name that no PC
    /// has) and NTE_PROV_DLL_NOT_FOUND.</summary>
    internal static readonly IReadOnlyDictionary<int, string> NoProvider = new Dictionary<int, string>
    {
        [unchecked((int)0xC0000225)] = "STATUS_NOT_FOUND",
        [unchecked((int)0x8009001E)] = "NTE_PROV_DLL_NOT_FOUND",
    };

    /// <summary>TBS's TPM version of a TPM 1.2 (TPM_VERSION_12), which has no P-256 key.</summary>
    internal const uint Tpm12 = 1;

    /// <summary>**Whether this PC's TPM gives no P-256 key**, from CNG's code for a new key and TBS's answer (its code and
    /// the TPM's version), and the code that says so; null for every other pair, which goes to the caller (a TPM that is
    /// not ready while TBS has it or starts, a lockout, a busy TPM, NTE_NOT_SUPPORTED of a TPM 2.0: the app asked for
    /// something that the provider refuses). The software key only for: no such provider; NTE_DEVICE_NOT_READY with no TPM
    /// or its services turned off; a TPM 1.2.</summary>
    internal static int? GivesNoKey(int cng, int tbs, uint version) =>
        NoProvider.ContainsKey(cng) ? cng
        : cng == DeviceNotReady && NoTpm.ContainsKey(tbs) ? tbs
        : tbs == 0 && version == Tpm12 ? cng
        : null;

    private static readonly ConcurrentDictionary<string, object> Locks = new(StringComparer.Ordinal);

    private readonly ISecretBox box;
    private readonly string provider;
    private readonly Func<string, CngKeyCreationParameters, CngKey> create;
    private readonly Func<(int Code, uint Version)> tbs;

    /// <param name="create">How a key is made in the TPM, and <paramref name="tbs"/> what TBS says of the TPM (a test
    /// gives stand-ins that answer with given codes).</param>
    public OwnerKeys(ISecretBox box, string provider = TpmOwnerKey.Provider,
                     Func<string, CngKeyCreationParameters, CngKey>? create = null, Func<(int Code, uint Version)>? tbs = null)
    {
        this.box = box;
        this.provider = provider;
        this.create = create ?? ((name, parameters) => CngKey.Create(CngAlgorithm.ECDsaP256, name, parameters));
        this.tbs = tbs ?? TbsCode;
    }

    /// <summary>Why the last <see cref="Make"/> made a software key: the code of <see cref="GivesNoKey"/>, or null when it
    /// made a key in the TPM. <see cref="TpmCodes"/>: CNG's and TBS's codes, and TBS's TPM version, of the last make that
    /// failed in the TPM.</summary>
    public int? SoftwareBecause { get; private set; }
    public (int Cng, int Tbs, uint Version)? TpmCodes { get; private set; }

    /// <summary>The name of a fleet's value in the box: the hub's fleet id is sixteen hex characters.</summary>
    public static string Name(string fleet) =>
        FleetId().IsMatch(fleet) ? "owner-key/" + fleet : throw new ArgumentException("not a fleet's id", nameof(fleet));

    /// <summary>The owner key that this PC holds for the fleet, or why there is none to use. Never a new key.</summary>
    public OwnerKeyLookup Key(string fleet)
    {
        var name = Name(fleet);
        lock (Locks.GetOrAdd(fleet, _ => new object()))
        {
            byte[]? raw;
            try
            {
                raw = box.Read(name);
            }
            catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException)
            {
                return new(OwnerKeyState.Unavailable, Code: e.HResult, Why: "the box's value does not open");
            }
            if (raw is null) return new(OwnerKeyState.None);
            try
            {
                if (Parse(raw) is not { } record)
                    return new(OwnerKeyState.Unavailable, Why: "the box's value is not an owner key's");
                try
                {
                    return record.Kind == InTpm ? OpenTpm(record.Held, record.PublicKey) : OpenSoftware(record.Held, record.PublicKey);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(record.Held);
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(raw);
            }
        }
    }

    /// <summary>**A new owner key for a fleet that has none on this PC** (the install that follows gives the central
    /// vault its public half): in the TPM, or a software key where <see cref="GivesNoKey"/> says that the TPM gives none.
    /// It throws, and changes nothing, when the box holds any value for the fleet (one that opens or one that does not),
    /// and when the TPM fails with any other code. It deletes no key.</summary>
    public IOwnerKey Make(string fleet)
    {
        var name = Name(fleet);
        lock (Locks.GetOrAdd(fleet, _ => new object()))
        {
            bool held;
            try
            {
                var raw = box.Read(name);
                held = raw is not null;
                if (raw is not null) CryptographicOperations.ZeroMemory(raw);
            }
            catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException)
            {
                held = true;
            }
            if (held) throw new InvalidOperationException("this PC holds a value for the owner key of this fleet: no new key is made");

            SoftwareBecause = null;
            TpmCodes = null;
            IOwnerKey made;
            byte[] value;
            var tpmName = $"Founderizer owner key {fleet} {Convert.ToHexString(RandomNumberGenerator.GetBytes(4)).ToLowerInvariant()}";
            CngKey? cng = null;
            try
            {
                cng = create(tpmName, new CngKeyCreationParameters
                {
                    Provider = new CngProvider(provider),
                    KeyUsage = CngKeyUsages.Signing,
                    ExportPolicy = CngExportPolicies.None,
                    UIPolicy = new CngUIPolicy(CngUIProtectionLevels.None),
                });
            }
            catch (CryptographicException e)
            {
                var said = tbs();
                TpmCodes = (e.HResult, said.Code, said.Version);
                SoftwareBecause = GivesNoKey(e.HResult, said.Code, said.Version);
                if (SoftwareBecause is null) throw;
            }
            catch (PlatformNotSupportedException)
            {
                SoftwareBecause = 0;
            }
            if (cng is not null)
            {
                TpmOwnerKey? tpm = null;
                try
                {
                    tpm = new TpmOwnerKey(cng);
                    value = Record(InTpm, Encoding.UTF8.GetBytes(tpmName), tpm.PublicKey);
                    made = tpm;
                }
                catch
                {
                    // A key that the TPM made but could not give in full does not stay there.
                    tpm?.Dispose();
                    Delete(tpmName);
                    cng.Dispose();
                    throw;
                }
            }
            else
            {
                using var software = ECDsa.Create(ECCurve.NamedCurves.nistP256);
                var parameters = software.ExportParameters(true);
                byte[] scalar = new byte[Base64.GetMaxEncodedToUtf8Length(32)];
                try
                {
                    var publicKey = Point(parameters);
                    // The key first: a refusal of its import leaves no value of its bytes to clear.
                    made = SoftwareOwnerKey.Import(parameters.D!, publicKey);
                    if (Base64.EncodeToUtf8(parameters.D!, scalar, out _, out int length) != OperationStatus.Done)
                    {
                        ((IDisposable)made).Dispose();
                        throw new CryptographicException("the software key was not written");
                    }
                    value = Record(InSoftware, scalar.AsSpan(0, length).ToArray(), publicKey);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(parameters.D);
                    CryptographicOperations.ZeroMemory(scalar);
                }
            }
            bool written;
            try
            {
                // Only where the name holds none, in one step: of two processes that make the key at once, one wins.
                written = box.WriteNew(name, value);
            }
            catch
            {
                Unkeep(made);
                throw;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(value);
            }
            if (!written)
            {
                Unkeep(made);
                throw new InvalidOperationException("another start made the owner key of this fleet first: this one keeps none");
            }
            return made;
        }
    }

    /// <summary>A key that was made and not kept: out of the TPM, and disposed.</summary>
    private void Unkeep(IOwnerKey made)
    {
        if (made is TpmOwnerKey unkept) Delete(unkept.Name);
        (made as IDisposable)?.Dispose();
    }

    /// <summary>Takes the fleet's owner key away when a caller asks: its value in the box, and its key in the TPM.</summary>
    public void Remove(string fleet)
    {
        var name = Name(fleet);
        lock (Locks.GetOrAdd(fleet, _ => new object()))
        {
            (string Kind, byte[] Held, string PublicKey)? record = null;
            try
            {
                if (box.Read(name) is { } raw)
                {
                    record = Parse(raw);
                    CryptographicOperations.ZeroMemory(raw);
                }
            }
            catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException)
            {
                // a value that does not open names no key that can be found
            }
            try
            {
                box.Remove(name);
                if (record is { Kind: InTpm } old) Delete(Encoding.UTF8.GetString(old.Held));
            }
            finally
            {
                if (record is { } any) CryptographicOperations.ZeroMemory(any.Held);
            }
        }
    }

    /// <summary>The 65-byte point 04 || X || Y as standard base64 (<see cref="IOwnerKey.PublicKey"/>).</summary>
    internal static string Point(ECParameters parameters)
    {
        var point = new byte[65];
        point[0] = 4;
        parameters.Q.X!.CopyTo(point, 1);
        parameters.Q.Y!.CopyTo(point, 33);
        return Convert.ToBase64String(point);
    }

    private OwnerKeyLookup OpenTpm(byte[] held, string publicKey)
    {
        var tpmName = Encoding.UTF8.GetString(held);
        CngKey? cng = null;
        try
        {
            cng = CngKey.Open(tpmName, new CngProvider(provider), CngKeyOpenOptions.Silent);
        }
        catch (CryptographicException e) when (e.HResult == NoSuchKey)
        {
            return new(OwnerKeyState.Gone, Code: e.HResult, Why: "the provider says that it has no key of the name that the box holds");
        }
        catch (Exception e) when (e is CryptographicException or PlatformNotSupportedException)
        {
            return new(OwnerKeyState.Unavailable, Code: e.HResult, Why: "the TPM does not give the key now");
        }
        var tpm = new TpmOwnerKey(cng);
        try
        {
            if (tpm.PublicKey == publicKey) return new(OwnerKeyState.Held, tpm);
        }
        catch (CryptographicException e)
        {
            tpm.Dispose();
            return new(OwnerKeyState.Unavailable, Code: e.HResult, Why: "the TPM does not give the key now");
        }
        tpm.Dispose();
        return new(OwnerKeyState.Unavailable, Why: "the TPM's key of that name has another public half than the box holds");
    }

    private static OwnerKeyLookup OpenSoftware(byte[] held, string publicKey)
    {
        var scalar = new byte[Base64.GetMaxDecodedFromUtf8Length(held.Length)];
        try
        {
            if (Base64.DecodeFromUtf8(held, scalar, out _, out int written) != OperationStatus.Done || written != 32)
                return new(OwnerKeyState.Unavailable, Why: "the box's value is not an owner key's");
            var software = SoftwareOwnerKey.Import(scalar.AsSpan(0, 32), publicKey);
            if (software.PublicKey == publicKey) return new(OwnerKeyState.Held, software);
            software.Dispose();
            return new(OwnerKeyState.Unavailable, Why: "the box's software key has another public half than the box holds");
        }
        catch (CryptographicException e)
        {
            return new(OwnerKeyState.Unavailable, Code: e.HResult, Why: "the box's value is not an owner key's");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(scalar);
        }
    }

    /// <summary>The bytes of a value: its kind, the key's name in the TPM or the software key in base64, and the public
    /// half, a line each. The software key goes from bytes to bytes, never through a string.</summary>
    private static byte[] Record(string kind, byte[] held, string publicKey)
    {
        try
        {
            var head = Encoding.UTF8.GetBytes(kind + "\n");
            var tail = Encoding.UTF8.GetBytes("\n" + publicKey + "\n");
            var value = new byte[head.Length + held.Length + tail.Length];
            head.CopyTo(value, 0);
            held.CopyTo(value, head.Length);
            tail.CopyTo(value, head.Length + held.Length);
            return value;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(held);
        }
    }

    /// <summary>A value read strictly: its kind, its second line as bytes, and the public half; null when it is not of
    /// this form.</summary>
    private static (string Kind, byte[] Held, string PublicKey)? Parse(byte[] raw)
    {
        var span = raw.AsSpan();
        int first = span.IndexOf((byte)'\n');
        if (first < 0) return null;
        var rest = span[(first + 1)..];
        int second = rest.IndexOf((byte)'\n');
        if (second <= 0) return null;
        var after = rest[(second + 1)..];
        int third = after.IndexOf((byte)'\n');
        if (third < 0 || third != after.Length - 1) return null;
        var kind = Encoding.UTF8.GetString(span[..first]);
        var publicKey = Encoding.UTF8.GetString(after[..third]);
        if (kind is not (InTpm or InSoftware) || P256.Point(publicKey) is null) return null;
        return (kind, rest[..second].ToArray(), publicKey);
    }

    private void Delete(string tpmName)
    {
        try
        {
            using var old = CngKey.Open(tpmName, new CngProvider(provider), CngKeyOpenOptions.Silent);
            old.Delete();
        }
        catch (Exception e) when (e is CryptographicException or PlatformNotSupportedException)
        {
            // gone already, or the TPM does not answer now
        }
    }

    /// <summary>TBS's code for this PC's TPM (0 when it has one, TBS_E_TPM_NOT_FOUND when not, also when Windows has no
    /// TBS at all), and the TPM's version (1 for a TPM 1.2, 2 for a TPM 2.0).</summary>
    private static (int Code, uint Version) TbsCode()
    {
        var info = new byte[16];
        try
        {
            int code = unchecked((int)Tbsi_GetDeviceInfo(16, info));
            return (code, code == 0 ? BitConverter.ToUInt32(info, 4) : 0);
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
        {
            return (unchecked((int)0x8028400F), 0);
        }
    }

    /// <summary>TBS's device information (TPM_DEVICE_INFO: its struct version, the TPM's version, the interface, the
    /// revision; 4 bytes each).</summary>
    [DllImport("tbs.dll")]
    private static extern uint Tbsi_GetDeviceInfo(uint size, [Out] byte[] info);

    [GeneratedRegex(@"\A[0-9a-f]{16}\z", RegexOptions.CultureInvariant)]
    private static partial Regex FleetId();
}
