using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Founderizer.Install;

/// <summary>The publisher check of a build (windows-app-release-design.md, section 4): each <c>.exe</c> and <c>.dll</c>
/// carries an Authenticode signature that Windows finds valid (WinVerifyTrust: the file's hash, the signature, and a
/// chain to a root that this PC trusts), and its signer is the signer of the build that runs. The running build is the
/// reference, as an ad hoc Mac build takes only an ad hoc one (app/Sources/FleetCore/AppUpdateInstall.swift): a build
/// signed with the build VM's test certificate takes only that same certificate, and a build with no valid signature
/// takes no update at all. The rule for Azure Artifact Signing, whose certificate changes every three days (the same
/// subject and the same identity EKU, with revocation and a timestamp), comes with that signing (plan decision D2).</summary>
public static partial class Publisher
{
    /// <summary>Windows finds the file's signature valid. No revocation check (WTD_REVOCATION_CHECK_NONE): the test
    /// certificate has no revocation list, and the signer is compared by its bytes after this.</summary>
    public static bool SignatureIsValid(string path) => Verify(path, null, wholeChainRevocation: false, out _) == 0;

    /// <summary>**A program of another company, before it runs, or before an administrator's install runs it**
    /// (windows-app-plan-v2.md, section 8.2; Tailscale's installer and its <c>tailscale.exe</c>): Windows finds the
    /// file's Authenticode signature valid with the revocation check of the whole chain (WTD_REVOKE_WHOLECHAIN), in a
    /// chain to a root that this PC trusts for code signing (WINTRUST_ACTION_GENERIC_VERIFY_V2), and the signer that
    /// Windows checked names exactly one organisation and one country, equal to these. Not a fingerprint: a code
    /// signing certificate lives about a year, and a renewal would stop every install. False for anything else. What
    /// Windows does when it cannot reach a certificate's revocation list or responder is Windows' own policy of that
    /// check, which this app does not set and which is not measured here.</summary>
    public static bool SignedBy(string path, string organisation, string country)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return SignedBy(file, organisation, country);
    }

    /// <summary>The same check of a file that the caller holds open, so that nobody can write it between the check and
    /// its use: open it with <see cref="FileShare.Read"/>, check it, and keep it open while the program that reads it
    /// runs.</summary>
    public static bool SignedBy(FileStream file, string organisation, string country)
    {
        if (Verify(file.Name, file.SafeFileHandle, wholeChainRevocation: true, out var signer) != 0) return false;
        using (signer) return signer is not null && Names(signer, organisation, country);
    }

    /// <summary>The X.500 attribute types id-at-organizationName and id-at-countryName (RFC 5280, A.1): the arcs 2, 5, 4
    /// with 10 and with 6, written by their arcs, as their dotted form reads like a network address.</summary>
    private static readonly string OrganizationName = string.Join('.', 2, 5, 4, 10), CountryName = string.Join('.', 2, 5, 4, 6);

    /// <summary>The signer names exactly one organisation (O) and one country (C), and they are these, letter for letter.</summary>
    public static bool Names(X509Certificate2 signer, string organisation, string country)
    {
        string? o = null, c = null;
        int os = 0, cs = 0;
        foreach (var part in signer.SubjectName.EnumerateRelativeDistinguishedNames())
        {
            if (part.HasMultipleElements) return false;
            var type = part.GetSingleElementType().Value;
            if (type == OrganizationName) { os++; o = part.GetSingleElementValue(); }
            else if (type == CountryName) { cs++; c = part.GetSingleElementValue(); }
        }
        return os == 1 && cs == 1 && string.Equals(o, organisation, StringComparison.Ordinal) && string.Equals(c, country, StringComparison.Ordinal);
    }

    /// <summary>**The one Windows call of the publisher checks** (WinVerifyTrust): 0 when Windows finds the signature
    /// valid. With <paramref name="handle"/>, Windows reads the file through that handle. With
    /// <paramref name="wholeChainRevocation"/>, the revocation of every certificate of the chain is checked, and the
    /// certificate of the signer that Windows checked comes back in <paramref name="signer"/>; else no revocation is
    /// checked and no signer comes back.</summary>
    private static int Verify(string path, SafeHandle? handle, bool wholeChainRevocation, out X509Certificate2? signer)
    {
        signer = null;
        bool added = false;
        handle?.DangerousAddRef(ref added);
        var file = new TrustFile
        {
            Size = Marshal.SizeOf<TrustFile>(),
            Path = Marshal.StringToHGlobalUni(path),
            Handle = added ? handle!.DangerousGetHandle() : IntPtr.Zero,
        };
        var pinned = GCHandle.Alloc(file, GCHandleType.Pinned);
        var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); // WINTRUST_ACTION_GENERIC_VERIFY_V2
        var data = new TrustData
        {
            Size = Marshal.SizeOf<TrustData>(),
            UiChoice = 2,                                           // WTD_UI_NONE
            RevocationChecks = wholeChainRevocation ? 1 : 0,        // WTD_REVOKE_WHOLECHAIN, or WTD_REVOKE_NONE
            UnionChoice = 1,                                        // WTD_CHOICE_FILE
            File = pinned.AddrOfPinnedObject(),
            StateAction = wholeChainRevocation ? 1 : 0,             // WTD_STATEACTION_VERIFY keeps the state for the signer
            ProvFlags = wholeChainRevocation ? 0x40 : 0x10,         // WTD_REVOCATION_CHECK_CHAIN, or WTD_REVOCATION_CHECK_NONE
        };
        try
        {
            var result = WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            if (result == 0 && wholeChainRevocation) signer = SignerOf(data.StateData);
            return result == 0 && wholeChainRevocation && signer is null ? -1 : result;
        }
        finally
        {
            if (wholeChainRevocation && data.StateData != IntPtr.Zero)
            {
                data.StateAction = 2; // WTD_STATEACTION_CLOSE
                WinVerifyTrust(new IntPtr(-1), ref action, ref data);
            }
            pinned.Free();
            Marshal.FreeHGlobal(file.Path);
            if (added) handle!.DangerousRelease();
        }
    }

    /// <summary>The certificate of the first signer of a checked file, from the state of the check (a copy).</summary>
    private static X509Certificate2? SignerOf(IntPtr state)
    {
        var provider = WTHelperProvDataFromStateData(state);
        if (provider == IntPtr.Zero) return null;
        var signer = WTHelperGetProvSignerFromChain(provider, 0, 0, 0);
        if (signer == IntPtr.Zero) return null;
        var certificate = WTHelperGetProvCertFromChain(signer, 0);
        if (certificate == IntPtr.Zero) return null;
        // CRYPT_PROVIDER_CERT: a DWORD, then the PCCERT_CONTEXT at the next pointer's place.
        var context = Marshal.ReadIntPtr(certificate, IntPtr.Size);
        return context == IntPtr.Zero ? null : new X509Certificate2(context);
    }

    /// <summary>The certificate that signed the file, when Windows finds its signature valid; else null.</summary>
    public static X509Certificate2? ValidSigner(string path)
    {
        if (!SignatureIsValid(path)) return null;
        try
        {
#pragma warning disable SYSLIB0057 // The loader of .NET 9 reads no Authenticode signature; this call reads the signer of a signed file.
            return new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    /// <summary>The same certificate, byte for byte.</summary>
    public static bool SameSigner(X509Certificate2 signer, X509Certificate2 running) =>
        signer.RawData.AsSpan().SequenceEqual(running.RawData);

    /// <summary>Why the build in <paramref name="folder"/> may not run, or null when every .exe and .dll in it, at any
    /// depth, has a valid signature by <paramref name="running"/>. Counts the files it checked.</summary>
    public static string? Refusal(string folder, X509Certificate2 running, out int checkedFiles)
    {
        checkedFiles = 0;
        foreach (var file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories))
        {
            var extension = Path.GetExtension(file);
            if (!extension.Equals(".exe", StringComparison.OrdinalIgnoreCase) && !extension.Equals(".dll", StringComparison.OrdinalIgnoreCase))
                continue;
            checkedFiles++;
            var name = Path.GetRelativePath(folder, file);
            using var signer = ValidSigner(file);
            if (signer is null) return $"{name} carries no signature that Windows finds valid";
            if (!SameSigner(signer, running))
                return $"{name} is signed by \"{signer.Subject}\" ({signer.Thumbprint}), not by the signer of this build " +
                       $"(\"{running.Subject}\", {running.Thumbprint})";
        }
        return null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrustFile
    {
        public int Size;
        public IntPtr Path;
        public IntPtr Handle;
        public IntPtr KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData
    {
        public int Size;
        public IntPtr PolicyCallbackData;
        public IntPtr SipClientData;
        public int UiChoice;
        public int RevocationChecks;
        public int UnionChoice;
        public IntPtr File;
        public int StateAction;
        public IntPtr StateData;
        public IntPtr UrlReference;
        public int ProvFlags;
        public int UiContext;
        public IntPtr SignatureSettings;
    }

    [LibraryImport("wintrust.dll")]
    private static partial int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);

    [LibraryImport("wintrust.dll")]
    private static partial IntPtr WTHelperProvDataFromStateData(IntPtr state);

    [LibraryImport("wintrust.dll")]
    private static partial IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint signer, int counterSigner, uint counterSignerIndex);

    [LibraryImport("wintrust.dll")]
    private static partial IntPtr WTHelperGetProvCertFromChain(IntPtr signer, uint certificate);
}
