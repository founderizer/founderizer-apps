using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Install;
using Founderizer.Windows.Fleet;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Founderizer.Windows.Update;

/// <summary>The update of an installed build, under the hood: no element on the owner's screen
/// (windows-app-release-design.md, sections 5 and 6, and the Mac's AppUpdatePolicy). At the build's first good start
/// (its window drew, and the store read its folder) it becomes current and tells the launcher. Then it reads the
/// channel at once and every hour, sooner after a read that failed; downloads a newer build that is offered into a
/// folder of its own; unpacks it with the path rules and its build.json; checks each .exe and .dll with the publisher
/// check; and puts it in builds\&lt;build&gt; as "next". When the owner has been away from the window for two minutes
/// and no write is on its way, the app ends and the launcher starts the new build. What it did is in update.log.</summary>
internal sealed class Updater
{
    private const string Who = "app";
    private readonly InstallFolder folder;
    private readonly BuildInfo running;
    private readonly IFleetSource source;
    private readonly Window window;
    private readonly DispatcherQueue ui;
    private readonly bool minimizeAtStart;
    private readonly HttpMessageInvoker http = ReleaseChannel.NewClient();
    private DateTimeOffset? awaySince;
    private DispatcherQueueTimer? swapTimer;
    private bool confirmed;
    private bool swapping;
    private long? waiting;

    /// <summary>The install and the build of this process, or null when it does not run from an install (the VM's
    /// output folder, a developer's build): such a build takes no update.</summary>
    public static (InstallFolder Folder, BuildInfo Build)? ThisInstall()
    {
        var here = Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
        if (InstallFolder.Holding(here) is not { } folder || BuildInfo.Read(here) is not { } build) return null;
        if (Path.GetFileName(here) != InstallFolder.Number(build.Build)) return null;
        if (!string.Equals(Environment.ProcessPath, Path.Combine(here, InstallFolder.AppName), StringComparison.OrdinalIgnoreCase))
            return null;
        return (folder, build);
    }

    /// <param name="afterUpdate">The launcher started this build after the build before it ended for this update
    /// (<c>--after-update</c>, and <c>--after-update=minimized</c> when its window was minimized): the owner is
    /// away.</param>
    public Updater(InstallFolder folder, BuildInfo running, IFleetSource source, Window window, string? afterUpdate)
    {
        this.folder = folder;
        this.running = running;
        this.source = source;
        this.window = window;
        ui = window.DispatcherQueue;
        minimizeAtStart = afterUpdate == "--after-update=minimized";
        awaySince = afterUpdate is null ? null : DateTimeOffset.UtcNow;
        window.Activated += (_, e) =>
        {
            awaySince = e.WindowActivationState == WindowActivationState.Deactivated ? awaySince ?? DateTimeOffset.UtcNow : null;
            CheckSwap();
        };
        source.Changed += (_, _) => ui.TryEnqueue(CheckSwap);
        CompositionTarget.Rendering += FirstFrame;
    }

    /// <summary>The window of a build that the launcher started after an update: shown, not activated, and behind the
    /// window that the owner uses, so that nothing comes to the front while he is away.</summary>
    public static void ShowWithoutActivation(Window window)
    {
        var handle = Win32Interop.GetWindowFromWindowId(window.AppWindow.Id);
        var front = GetForegroundWindow();
        window.AppWindow.Show(activateWindow: false);
        if (front != IntPtr.Zero && front != handle && (GetWindowLongPtr(front, -20 /* GWL_EXSTYLE */) & 0x8 /* WS_EX_TOPMOST */) == 0)
            SetWindowPos(handle, front, 0, 0, 0, 0, 0x1 | 0x2 | 0x10 /* SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE */);
    }

    private void FirstFrame(object? sender, object e)
    {
        CompositionTarget.Rendering -= FirstFrame;
        GoodStart();
    }

    /// <summary>The window drew, and the store read its folder before the window was made (OwnerStore reads it when
    /// it is made): this build becomes current, and the launcher that waits for it ends.</summary>
    private void GoodStart()
    {
        if (confirmed) return;
        confirmed = true;
        var handle = Win32Interop.GetWindowFromWindowId(window.AppWindow.Id);
        // A window that Windows did not bring to the front raised no Activated: the owner is away from it.
        if (GetForegroundWindow() != handle) awaySince ??= DateTimeOffset.UtcNow;
        if (minimizeAtStart) ShowWindow(handle, 7 /* SW_SHOWMINNOACTIVE */);
        try
        {
            var was = folder.Current;
            if (was != running.Build)
            {
                folder.SetCurrent(running.Build);
                folder.Log(Who, $"build {running.Line} had its first good start (its window drew, and the store read its " +
                                $"folder): it is current" + (was is { } before ? $", and build {before} is previous" : ""));
            }
            if (EventWaitHandle.TryOpenExisting(InstallFolder.GoodStartSignal(running.Build), out var signal))
                using (signal) signal.Set();
            if (WindowsEntries.UninstallEntryIsOurs(folder)) WindowsEntries.WriteUninstallEntry(folder, running);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            folder.Log(Who, $"build {running.Build} could not write that it is current: {e.Message}");
        }
        _ = Task.Run(PlaceLauncher);
        _ = Task.Run(RunAsync);
    }

    /// <summary>Puts this build's launcher at the top of the folder when it differs, after the launcher that started
    /// this build ended (its gate).</summary>
    private void PlaceLauncher()
    {
        try
        {
            using var gate = new Mutex(false, InstallFolder.LauncherGate);
            try
            {
                gate.WaitOne();
            }
            catch (AbandonedMutexException)
            {
            }
            try
            {
                if (folder.PlaceLauncher(running.Build))
                    folder.Log(Who, $"the launcher of build {running.Build} replaced the one at the top of the folder");
            }
            finally
            {
                gate.ReleaseMutex();
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            folder.Log(Who, $"the launcher at the top of the folder stays as it was: {e.Message}");
        }
    }

    private async Task RunAsync()
    {
        using var signer = Publisher.ValidSigner(Environment.ProcessPath!);
        if (signer is null)
        {
            folder.Log(Who, $"build {running.Line} carries no signature that Windows finds valid, so it takes no update");
            return;
        }
        var failures = 0;
        while (true)
        {
            var answered = await ReadOnceAsync(signer);
            failures = answered ? 0 : failures + 1;
            await Task.Delay(failures == 0 ? ReleaseChannel.Every : ReleaseChannel.Retry(failures));
        }
    }

    /// <summary>One read of the channel, and the download and the checks of a build that it offers. False when the read
    /// or the download failed, so the next read comes sooner.</summary>
    private async Task<bool> ReadOnceAsync(X509Certificate2 signer)
    {
        UpdateReading reading;
        try
        {
            reading = await WindowsUpdate.ReadAsync(http, ReleaseChannel.Channel, running.Arch, early: false,
                                                    ReleaseChannel.Keys(early: false), new InstalledBuild(running.Version, running.Build),
                                                    Environment.OSVersion.Version);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or InvalidOperationException)
        {
            folder.Log(Who, $"read: {e.Message}");
            return false;
        }
        var offered = reading.Manifest;
        folder.Log(Who, $"read ({reading.Status}): {reading.Says}" +
                        (offered is { } m ? $" The channel offers {m.Version} (build {m.Build}, {m.Arch}); this PC runs build {running.Build}." : ""));
        if (reading.Unreachable) return false;
        if (!reading.Offered || offered is null) return true;
        if (folder.Failed.Contains(offered.Build))
        {
            folder.Log(Who, $"build {offered.Build} ended before its first good start on this PC, so it is not taken again");
            return true;
        }
        if (waiting == offered.Build) return true;
        try
        {
            await TakeAsync(offered, signer);
            return true;
        }
        catch (UpdateFailure e)
        {
            folder.Log(Who, $"build {offered.Build} is not taken: {e.Message} Its download folder is gone.");
            return false;
        }
        catch (BuildRefused e)
        {
            folder.Log(Who, $"build {offered.Build} is refused: {e.Message}. Its download folder is gone, and nothing on this PC changed.");
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            folder.Log(Who, $"build {offered.Build} is not taken: {e.Message}. Its download folder is gone.");
            return false;
        }
    }

    private async Task TakeAsync(WindowsManifest manifest, X509Certificate2 signer)
    {
        folder.Log(Who, $"the download of {manifest.Version} (build {manifest.Build}, {manifest.Size} bytes) starts");
        var zip = await BuildDownload.FetchAsync(http, manifest, folder.Updates);
        var work = Path.GetDirectoryName(zip)!;
        try
        {
            var count = 0;
            await Task.Run(() =>
            {
                var unpacked = Path.Combine(work, "build");
                using (var file = File.OpenRead(zip))
                    BuildUnpack.Unpack(file, unpacked, new BuildInfo(manifest.Version, manifest.Build, manifest.Arch));
                File.Delete(zip);
                if (Publisher.Refusal(unpacked, signer, out count) is { } why) throw new BuildRefused(why);
                var target = folder.BuildFolder(manifest.Build);
                if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
                Directory.Move(unpacked, target);
                folder.SetNext(manifest.Build);
            });
            folder.Log(Who, $"build {manifest.Build}: its size and SHA-256 are the signed ones, its entries stay in their folder, " +
                            $"its build.json names it, and its {count} .exe and .dll files carry the signature of this build's " +
                            $"signer; it waits in builds\\{manifest.Build} until the owner has been away for " +
                            $"{ReleaseChannel.Away.TotalSeconds:F0} s and no write is on its way");
        }
        finally
        {
            try
            {
                if (Directory.Exists(work)) Directory.Delete(work, recursive: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
        waiting = manifest.Build;
        ui.TryEnqueue(CheckSwap);
    }

    /// <summary>On the window's thread: ends the app for the waiting build once the owner has been away for
    /// <see cref="ReleaseChannel.Away"/> and no write is on its way (the Mac's shouldInstall). A write on its way
    /// is asked about again at the store's next change.</summary>
    private void CheckSwap()
    {
        if (swapping || waiting is not { } build || awaySince is not { } since)
        {
            swapTimer?.Stop();
            return;
        }
        var left = since + ReleaseChannel.Away - DateTimeOffset.UtcNow;
        if (left > TimeSpan.Zero)
        {
            if (swapTimer is null)
            {
                swapTimer = ui.CreateTimer();
                swapTimer.IsRepeating = false;
                swapTimer.Tick += (_, _) => CheckSwap();
            }
            swapTimer.Stop();
            swapTimer.Interval = left;
            swapTimer.Start();
            return;
        }
        var state = source.State;
        if (state.Sending || state.Pending is not null) return;
        Swap(build, DateTimeOffset.UtcNow - since);
    }

    private void Swap(long build, TimeSpan away)
    {
        swapping = true;
        var minimized = window.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized };
        var start = new ProcessStartInfo(folder.Launcher) { UseShellExecute = false, WorkingDirectory = folder.Root };
        start.ArgumentList.Add("--after");
        start.ArgumentList.Add(Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
        start.ArgumentList.Add(minimized ? "--after-update=minimized" : "--after-update");
        try
        {
            Process.Start(start)?.Dispose();
        }
        catch (Win32Exception e)
        {
            folder.Log(Who, $"the launcher did not start ({e.Message}): build {build} starts at the next start");
            return;
        }
        folder.Log(Who, $"build {build} waits, the owner has been away for {away.TotalSeconds:F0} s, and no write is on its " +
                        $"way: build {running.Build} ends, and the launcher starts build {build}");
        window.Close();
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr window, int command);
}
