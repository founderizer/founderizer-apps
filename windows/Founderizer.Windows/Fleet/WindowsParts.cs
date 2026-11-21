using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Install;

namespace Founderizer.Windows.Fleet;

/// <summary>Where this PC keeps what the app holds, in the user's own LocalAppData: the store's folder, the device key's
/// file beside it (outside the folder, which holds no key), the secret box's folder (<c>keys</c>), the first run's own
/// folder (<c>setup</c>: its records, the servers' host keys and the owner's kept answers, none of them a secret), and
/// the folder of a download that waits for its check (<c>downloads</c>).</summary>
internal static class AppFolders
{
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Founderizer");
    public static string Store => Path.Combine(Root, "store");
    public static string KeyFile => Path.Combine(Root, "device-key");
    /// <summary>The secret box (<see cref="FileSecretBox"/>): one protected file for each secret, never a plain one.</summary>
    public static string Keys => Path.Combine(Root, "keys");
    public static string Setup => Path.Combine(Root, "setup");
    public static string Downloads => Path.Combine(Root, "downloads");

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

/// <summary>A key's protection: Windows' own protection of the signed-in user's data (DPAPI, CryptProtectData for the
/// current user). Only this Windows user, on this PC, can unprotect it; the file holds no key that can be read as text.
/// The TPM is a later choice (app/windows/vm/README.md). **Each use has its own purpose** (the device key, the secret
/// box): data that another program, or another use of this one, protects for the same user does not open here.</summary>
internal sealed class UserKeyProtection(string purpose) : IKeyProtection
{
    public const string DeviceKey = "Founderizer for Windows: device key";
    public const string SecretBox = "Founderizer for Windows: secret box";

    /// <summary>The device key's protection, as step 1 made it.</summary>
    public UserKeyProtection() : this(DeviceKey)
    {
    }

    private readonly byte[] Purpose = Encoding.UTF8.GetBytes(purpose);

    public byte[] Protect(byte[] key) => Crypt(key, protect: true);

    public byte[] Unprotect(byte[] stored) => Crypt(stored, protect: false);

    private byte[] Crypt(byte[] data, bool protect)
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

    /// <summary>The program is Tailscale's (<see cref="Publisher.SignedBy(string, string, string)"/>: Windows finds its
    /// signature valid with the revocation check of the whole chain, and its signer is Tailscale Inc. of CA, as for
    /// Tailscale's installer). A pass holds while the file does not change; a refusal is checked again after 30 seconds,
    /// so that a check that failed for a moment (a file in use, the network) does not hide Tailscale until the next
    /// start.</summary>
    public bool IsTailscales()
    {
        DateTime write;
        try { write = File.GetLastWriteTimeUtc(Program); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        lock (gate)
        {
            if (write == checkedWrite && (trusted || DateTime.UtcNow - checkedAt < TimeSpan.FromSeconds(30))) return trusted;
        }
        bool now;
        try { now = Publisher.SignedBy(Program, Signer.Organisation, Signer.Country); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
        {
            now = false;
        }
        lock (gate)
        {
            checkedWrite = write;
            checkedAt = DateTime.UtcNow;
            trusted = now;
        }
        return now;
    }

    private readonly object gate = new();
    private DateTime checkedAt;
}

/// <summary>Who signs Tailscale's programs and its installer (windows-app-plan-v2.md, section 8.2, measured in the VM on 13
/// November 2026; the library's <c>PcNetwork.InstallerOrganisation</c> and <c>InstallerCountry</c>).</summary>
internal static class Signer
{
    public const string Organisation = Founderizer.Setup.Network.PcNetwork.InstallerOrganisation;
    public const string Country = Founderizer.Setup.Network.PcNetwork.InstallerCountry;
}
