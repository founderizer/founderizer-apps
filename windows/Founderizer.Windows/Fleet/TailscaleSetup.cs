using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Install;
using Founderizer.Setup.Network;

namespace Founderizer.Windows.Fleet;

/// <summary>**This PC's Tailscale, as the first run reads it**: whether Tailscale's program is on the PC, and the text of
/// its <c>tailscale status --json</c> (<see cref="WindowsTailscale"/>). The proofs' build can read a stand-in instead
/// (<c>FOUNDERIZER_TAILSCALE_STATUS</c>: a file whose text is the status, or <c>none</c> for a PC with no Tailscale), so
/// that the first run's pages are proved in the VM without its own network, which is the owner's (plan, 8.15); with a
/// stand-in the app runs no program of Tailscale's. A release build reads no variable.</summary>
internal sealed class PcTailscale : ITailscaleStatus
{
    private readonly WindowsTailscale real = new();
    private readonly string? standIn;

    private PcTailscale(string? standIn) => this.standIn = standIn;

    public static PcTailscale Create() => new(Proofs.Variable("FOUNDERIZER_TAILSCALE_STATUS") is { Length: > 0 } file ? file : null);

    /// <summary>A stand-in that reads its status from a file (the proofs and the tests).</summary>
    internal static PcTailscale StandIn(string file) => new(file);

    /// <summary>A stand-in of the proofs reads for Tailscale: no program of Tailscale's runs.</summary>
    public bool IsStandIn => standIn is not null;

    /// <summary>Tailscale's program is on this PC.</summary>
    public bool Installed => standIn is { } file ? Read(file) is not "none" : File.Exists(WindowsTailscale.Program);

    public Task<string?> ReadAsync(CancellationToken cancel) =>
        standIn is { } file ? Task.FromResult(Read(file) is { } text && text != "none" ? text : null) : real.ReadAsync(cancel);

    /// <summary>Tailscale's own program, after its publisher check, or null: with a stand-in, never.</summary>
    public string? Program() => standIn is null && File.Exists(WindowsTailscale.Program) && real.IsTailscales() ? WindowsTailscale.Program : null;

    private static string? Read(string file)
    {
        try { return File.ReadAllText(file).Trim(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }
}

/// <summary>**Connect Tailscale on this PC** (windows-app-plan-v2.md, 2.1 and 8.2; the Mac's <c>FleetNetworkModel.connect</c>
/// and <c>MacNetwork.install</c>): with no Tailscale on the PC, the app reads Tailscale's list of its Windows packages,
/// downloads the MSI for this kind of PC into a folder of its own, checks that Tailscale signed it
/// (<see cref="Publisher.SignedBy(FileStream, string, string)"/>, with the revocation of the whole chain) while it holds
/// the file open so that nothing writes it, and starts Windows' installer with it: Windows asks for an administrator's
/// yes in its own dialog. A file that fails the check is removed, and nothing runs. Then, and on a PC that has Tailscale
/// already, Tailscale's own sign-in: <c>tailscale up</c> (after its publisher check), whose sign-in link opens in the
/// default browser when it is Tailscale's own page. The app gives the PC no key and no tag: the PC signs in as the owner.
///
/// Each sentence is the Mac's, with "PC" (rule 14). A test gives its own handler of the exchange and its own folder.</summary>
internal sealed class TailscaleSetup(PcTailscale tailscale, Func<HttpMessageHandler>? handler = null, string? downloads = null) : IDisposable
{
    public static string CannotDownload(string says) => $"Tailscale's installer could not be downloaded: {says}";
    public const string NoInstaller = "Tailscale's own download page did not give the installer.";
    public const string NotTailscales = "That download is not signed by Tailscale, so this PC did not open it. Nothing was installed.";
    public static string CannotOpen(string path) => $"This PC could not open {path}. Open it yourself to install Tailscale.";

    /// <summary>Tailscale's sign-in page: the one host whose link the app opens.</summary>
    public const string SignInHost = "login.tailscale.com";

    private static string Msiexec => Path.Combine(Environment.SystemDirectory, "msiexec.exe");

    private readonly object gate = new();
    private Process? waiting;
    private bool disposed;

    /// <summary>**The press of Connect, and of Open Tailscale again**: the install when Tailscale is not on this PC, then
    /// Tailscale's sign-in. Null when the press went as far as it could; else the Mac's words of what stopped it. A
    /// cancelled download leaves nothing and says nothing; Windows' installer, once it runs, is never cut off.</summary>
    public async Task<string?> ConnectAsync(CancellationToken cancel)
    {
        if (!tailscale.Installed)
        {
            var (stop, installed) = await InstallAsync(cancel);
            if (stop is not null || !installed) return stop;
        }
        await SignInAsync(cancel);
        return null;
    }

    // ------------------------------------------------------------------ the install

    private async Task<(string? Stop, bool Installed)> InstallAsync(CancellationToken cancel)
    {
        if (PcNetwork.Arch(RuntimeInformation.OSArchitecture) is not { } arch) return (CannotDownload(NoInstaller), false);
        using var client = new HttpClient((handler ?? ProviderHandler.Create)(), disposeHandler: true)
        {
            // About 39 MB: no limit on the whole download, which ends with the owner's press (Back) instead.
            Timeout = Timeout.InfiniteTimeSpan,
            MaxResponseContentBufferSize = 1 << 20,
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Founderizer (Windows)");
        PcNetwork.Installer installer;
        try
        {
            using var list = await client.GetAsync(PcNetwork.Packages, HttpCompletionOption.ResponseContentRead, cancel);
            if (!FromTailscale(list)) return (CannotDownload(NoInstaller), false);
            if (PcNetwork.InstallerFor(arch, await list.Content.ReadAsStringAsync(cancel)) is not { } found)
                return (CannotDownload(NoInstaller), false);
            installer = found;
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested) { return (null, false); }
        catch (Exception e) when (e is HttpRequestException or IOException or OperationCanceledException)
        {
            return (CannotDownload(e.Message), false);
        }

        var folder = Path.Combine(downloads ?? AppFolders.Downloads, Guid.NewGuid().ToString("N"));
        var path = Path.Combine(folder, installer.File);
        try
        {
            Directory.CreateDirectory(folder);
            using var answer = await client.GetAsync(installer.Address, HttpCompletionOption.ResponseHeadersRead, cancel);
            if (!FromTailscale(answer))
            {
                Remove(folder);
                return (CannotDownload(NoInstaller), false);
            }
            await using var from = await answer.Content.ReadAsStreamAsync(cancel);
            await using var to = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            await from.CopyToAsync(to, cancel);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            Remove(folder);
            return (null, false);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            Remove(folder);
            return (CannotDownload(e.Message), false);
        }

        // Held open from the check to the installer's end: nobody writes the file between the two.
        FileStream held;
        try { held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Remove(folder);
            return (CannotDownload(e.Message), false);
        }
        bool signed;
        try { signed = await Task.Run(() => Publisher.SignedBy(held, Signer.Organisation, Signer.Country), CancellationToken.None); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException) { signed = false; }
        if (!signed || cancel.IsCancellationRequested)
        {
            held.Dispose();
            Remove(folder);
            return (signed ? null : NotTailscales, false);
        }

        Process? install;
        try
        {
            var start = new ProcessStartInfo(Msiexec) { UseShellExecute = false };
            foreach (var word in new[] { "/i", path, "/passive", "/norestart" }) start.ArgumentList.Add(word);
            install = Process.Start(start);
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException)
        {
            install = null;
        }
        if (install is null)
        {
            // The file passed its check and stays, so that the owner can open it, as the Mac's words say.
            held.Dispose();
            return (CannotOpen(path), false);
        }
        using (install)
        {
            await install.WaitForExitAsync(CancellationToken.None);
            held.Dispose();
            Remove(folder);
            // 0: installed; 3010: installed, and Windows wants a restart later. Anything else, his "No" to Windows'
            // question among them (1602), installed nothing: the page waits, and "Open Tailscale again" asks again.
            return (null, install.ExitCode is 0 or 3010);
        }
    }

    /// <summary>An answer that is Tailscale's own: 200, over HTTPS, from the host that was asked. No redirect is followed
    /// (<see cref="ProviderHandler.Create"/>), so another host's answer is a 3xx, which is no installer either.</summary>
    internal static bool FromTailscale(HttpResponseMessage answer) =>
        answer.StatusCode == HttpStatusCode.OK && answer.RequestMessage?.RequestUri is { Scheme: "https", Host: "pkgs.tailscale.com" };

    private static void Remove(string folder)
    {
        try { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    // ------------------------------------------------------------------ the sign-in

    /// <summary>**Tailscale's own sign-in**: <c>tailscale up</c>, with no setting of its own, which connects a PC that is
    /// signed in already and prints the link of Tailscale's sign-in page for one that is not. That link opens in the
    /// default browser; the program waits there until the sign-in ends, or until the page goes on or is left
    /// (<see cref="Stop"/>). Right after an install Tailscale's service can take a moment to answer: up to five tries,
    /// two seconds apart.</summary>
    private async Task SignInAsync(CancellationToken cancel)
    {
        Stop();
        for (int attempt = 0; attempt < 5 && !cancel.IsCancellationRequested; attempt++)
        {
            // The publisher check reads the network for the revocation: never on the window's thread.
            if (await Task.Run(() => tailscale.Program(), CancellationToken.None) is not { } program)
            {
                await Pause(cancel);
                continue;
            }
            var start = new ProcessStartInfo(program)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            start.ArgumentList.Add("up");
            Process process;
            try { process = Process.Start(start) ?? throw new InvalidOperationException(); }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException) { return; }
            var opened = 0;
            void Line(string? line)
            {
                if (line is null || LoginLink(line) is not { } link || Interlocked.Exchange(ref opened, 1) == 1) return;
                try { Process.Start(new ProcessStartInfo(link.AbsoluteUri) { UseShellExecute = true })?.Dispose(); }
                catch (Exception e) when (e is Win32Exception or InvalidOperationException) { }
            }
            process.OutputDataReceived += (_, e) => Line(e.Data);
            process.ErrorDataReceived += (_, e) => Line(e.Data);
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            lock (gate)
            {
                if (disposed) { Kill(process); return; }
                waiting = process;
            }
            // A service that does not answer yet ends the program at once, with no link.
            using var soon = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            try { await process.WaitForExitAsync(soon.Token); }
            catch (OperationCanceledException) { return; }
            if (process.ExitCode == 0 || opened == 1) return;
            lock (gate) if (waiting == process) waiting = null;
            process.Dispose();
            await Pause(cancel);
        }
    }

    private static async Task Pause(CancellationToken cancel)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(2), cancel); }
        catch (OperationCanceledException) { }
    }

    /// <summary>The link of Tailscale's own sign-in page in a line of <c>tailscale up</c>, or null: only HTTPS, only
    /// <see cref="SignInHost"/>, with no user and no port. Any other address in the line is never opened.</summary>
    internal static Uri? LoginLink(string line)
    {
        foreach (var word in line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (!word.StartsWith("https://", StringComparison.Ordinal)) continue;
            // The browser gets the parsed address (AbsoluteUri), so these checks of it are the whole rule.
            if (Uri.TryCreate(word, UriKind.Absolute, out var link) && link.Scheme == Uri.UriSchemeHttps &&
                link.Host == SignInHost && link.IsDefaultPort && link.UserInfo.Length == 0)
                return link;
        }
        return null;
    }

    /// <summary>The page went on, or was left: the program that waits for the sign-in ends. The sign-in itself goes on in
    /// Tailscale's service and in the browser.</summary>
    public void Stop()
    {
        Process? process;
        lock (gate) { process = waiting; waiting = null; }
        if (process is not null) Kill(process);
    }

    private static void Kill(Process process)
    {
        try { if (!process.HasExited) process.Kill(); }
        catch (Exception e) when (e is InvalidOperationException or Win32Exception) { }
        process.Dispose();
    }

    public void Dispose()
    {
        lock (gate) disposed = true;
        Stop();
    }
}
