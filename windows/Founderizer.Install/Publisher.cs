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
    public static bool SignatureIsValid(string path)
    {
        var file = new TrustFile { Size = Marshal.SizeOf<TrustFile>(), Path = Marshal.StringToHGlobalUni(path) };
        var pinned = GCHandle.Alloc(file, GCHandleType.Pinned);
        try
        {
            var data = new TrustData
            {
                Size = Marshal.SizeOf<TrustData>(),
                UiChoice = 2,          // WTD_UI_NONE
                RevocationChecks = 0,  // WTD_REVOKE_NONE
                UnionChoice = 1,       // WTD_CHOICE_FILE
                File = pinned.AddrOfPinnedObject(),
                StateAction = 0,
                ProvFlags = 0x10,      // WTD_REVOCATION_CHECK_NONE
            };
            var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); // WINTRUST_ACTION_GENERIC_VERIFY_V2
            return WinVerifyTrust(new IntPtr(-1), ref action, ref data) == 0;
        }
        finally
        {
            pinned.Free();
            Marshal.FreeHGlobal(file.Path);
        }
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
}
