using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>Where this PC keeps what the app holds: the store's folder, and the device key's file beside it (outside the
/// folder, which holds no key), in the user's own LocalAppData.</summary>
internal static class AppFolders
{
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Founderizer");
    public static string Store => Path.Combine(Root, "store");
    public static string KeyFile => Path.Combine(Root, "device-key");

    /// <summary>This installation's own id, made once: the client of each write is founderizer-windows/1/&lt;id&gt;.</summary>
    public static string InstallationId()
    {
        var path = Path.Combine(Root, "installation");
        try
        {
            if (File.Exists(path) && Guid.TryParse(File.ReadAllText(path).Trim(), out var known)) return known.ToString();
            Directory.CreateDirectory(Root);
            var id = Guid.NewGuid().ToString();
            File.WriteAllText(path, id);
            return id;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Guid.Empty.ToString();
        }
    }
}

/// <summary>The device key's protection: Windows' own protection of the signed-in user's data (DPAPI, CryptProtectData
/// for the current user). Only this Windows user, on this PC, can unprotect it; the file holds no key that can be read
/// as text. The TPM is a later choice (app/windows/vm/README.md).</summary>
internal sealed class UserKeyProtection : IKeyProtection
{
    // Ties the protected key to this use: data that another program protects for the same user does not open here.
    private static readonly byte[] Purpose = Encoding.UTF8.GetBytes("Founderizer for Windows: device key");

    public byte[] Protect(byte[] key) => Crypt(key, protect: true);

    public byte[] Unprotect(byte[] stored) => Crypt(stored, protect: false);

    private static byte[] Crypt(byte[] data, bool protect)
    {
        var input = GCHandle.Alloc(data, GCHandleType.Pinned);
        var entropy = GCHandle.Alloc(Purpose, GCHandleType.Pinned);
        var output = new Blob();
        try
        {
            var inBlob = new Blob { Size = data.Length, Data = input.AddrOfPinnedObject() };
            var entropyBlob = new Blob { Size = Purpose.Length, Data = entropy.AddrOfPinnedObject() };
            bool done = protect
                ? CryptProtectData(ref inBlob, null, ref entropyBlob, IntPtr.Zero, IntPtr.Zero, UiForbidden, ref output)
                : CryptUnprotectData(ref inBlob, IntPtr.Zero, ref entropyBlob, IntPtr.Zero, IntPtr.Zero, UiForbidden, ref output);
            if (!done) throw new IOException($"Windows could not {(protect ? "protect" : "open")} the device key (error {Marshal.GetLastWin32Error()}).");
            var result = new byte[output.Size];
            Marshal.Copy(output.Data, result, 0, output.Size);
            return result;
        }
        finally
        {
            if (output.Data != IntPtr.Zero)
            {
                // The plain key in Windows' buffer is cleared before it is given back.
                for (int i = 0; i < output.Size; i++) Marshal.WriteByte(output.Data, i, 0);
                LocalFree(output.Data);
            }
            input.Free();
            entropy.Free();
        }
    }

    private const int UiForbidden = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct Blob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(ref Blob input, string? description, ref Blob entropy, IntPtr reserved,
                                                IntPtr prompt, int flags, ref Blob output);

    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, ref Blob entropy, IntPtr reserved,
                                                  IntPtr prompt, int flags, ref Blob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}

/// <summary>This PC's Tailscale, from Tailscale's own program: `tailscale status --json`, run by its full path, and only
/// when Windows finds the program's Authenticode signature valid and Tailscale Inc. as its signer. Null when Tailscale
/// is not on this PC, its program is not Tailscale's, or it does not answer in five seconds.</summary>
internal sealed class WindowsTailscale : ITailscaleStatus
{
    public static readonly string Program = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tailscale", "tailscale.exe");

    private DateTime checkedWrite;
    private bool trusted;

    public async Task<string?> ReadAsync(CancellationToken cancel)
    {
        if (!File.Exists(Program) || !IsTailscales()) return null;
        var start = new ProcessStartInfo(Program, "status --json")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var process = Process.Start(start);
        if (process is null) return null;
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        limit.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            var output = process.StandardOutput.ReadToEndAsync(limit.Token);
            _ = process.StandardError.ReadToEndAsync(limit.Token);
            await process.WaitForExitAsync(limit.Token);
            var text = await output;
            return text.TrimStart().StartsWith('{') ? text : null;
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            try { process.Kill(); } catch (InvalidOperationException) { }
            return null;
        }
    }

    /// <summary>The program is Tailscale's: its signature is valid for Windows (WinVerifyTrust, with the chain to a
    /// trusted root) and its signer is the organisation Tailscale Inc. Checked again when the file changes.</summary>
    private bool IsTailscales()
    {
        var write = File.GetLastWriteTimeUtc(Program);
        if (write == checkedWrite) return trusted;
        checkedWrite = write;
        trusted = SignatureIsValid(Program) && SignerIsTailscale(Program);
        return trusted;
    }

    internal static bool SignerIsTailscale(string path)
    {
        try
        {
#pragma warning disable SYSLIB0057 // The loader of .NET 9 reads no Authenticode signature; this call reads the signer of a signed file.
            using var signer = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
            return signer.GetNameInfo(X509NameType.SimpleName, false) == "Tailscale Inc." &&
                   signer.Subject.Contains("O=Tailscale Inc.", StringComparison.Ordinal);
        }
        catch (System.Security.Cryptography.CryptographicException)
        {
            return false;
        }
    }

    internal static bool SignatureIsValid(string path)
    {
        var file = new TrustFile { Size = Marshal.SizeOf<TrustFile>(), Path = Marshal.StringToHGlobalUni(path) };
        var fileHandle = GCHandle.Alloc(file, GCHandleType.Pinned);
        try
        {
            var data = new TrustData
            {
                Size = Marshal.SizeOf<TrustData>(),
                UiChoice = 2,          // WTD_UI_NONE
                RevocationChecks = 0,  // WTD_REVOKE_NONE: the chain, not a network check of revocation
                UnionChoice = 1,       // WTD_CHOICE_FILE
                File = fileHandle.AddrOfPinnedObject(),
                StateAction = 0,
                ProvFlags = 0x10,      // WTD_CACHE_ONLY_URL_RETRIEVAL: no download while it checks
            };
            var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); // WINTRUST_ACTION_GENERIC_VERIFY_V2
            return WinVerifyTrust(new IntPtr(-1), ref action, ref data) == 0;
        }
        finally
        {
            fileHandle.Free();
            Marshal.FreeHGlobal(file.Path);
        }
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

    [DllImport("wintrust.dll", CharSet = CharSet.Unicode)]
    private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
}
