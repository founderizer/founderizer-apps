using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Founderizer.Install;
using Microsoft.Win32.SafeHandles;

namespace Founderizer.Launcher;

/// <summary>The launcher of the Start menu, its removal, and the setup (the project file says which is which).</summary>
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        using var carried = typeof(Program).Assembly.GetManifestResourceStream("build.zip");
        if (carried is not null) return Setup.Run(carried, args);
        var folder = new InstallFolder(Path.GetDirectoryName(Environment.ProcessPath!)!);
        if (args is ["--uninstall"]) return Removal.Run(folder);
        return Start.Run(folder, args);
    }

    /// <summary>Takes the launcher's gate; a gate whose holder died is taken as it is.</summary>
    internal static void Take(Mutex gate)
    {
        try
        {
            gate.WaitOne();
        }
        catch (AbandonedMutexException)
        {
        }
    }

    /// <summary>The app's processes that run a build of this install.</summary>
    internal static List<Process> Apps(InstallFolder folder)
    {
        var apps = new List<Process>();
        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(InstallFolder.AppName)))
        {
            string? path;
            try
            {
                path = process.MainModule?.FileName;
            }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException)
            {
                path = null;
            }
            // A process whose file cannot be read is counted as this install's: nothing of it is removed under it.
            if (path is null || path.StartsWith(folder.Builds + "\\", StringComparison.OrdinalIgnoreCase)) apps.Add(process);
            else process.Dispose();
        }
        return apps;
    }

    internal static void RemoveFolder(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    internal static void RemoveFile(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}

/// <summary>A wait for a process's end, beside a wait for an event.</summary>
internal sealed class ProcessEnd : WaitHandle
{
    public ProcessEnd(Process process) => SafeWaitHandle = new SafeWaitHandle(process.Handle, ownsHandle: false);
}

/// <summary>The start from the Start menu, and the start that ends an update (<c>--after &lt;pid&gt;</c>, when the app
/// that started it has ended). It removes what an earlier update left, starts a checked new build when one waits and
/// waits for its first good start, and starts the current build again when the new one ended before it (section 5,
/// step 6): an event ends each wait, never a clock.</summary>
internal static class Start
{
    private const string Who = "launcher";

    public static int Run(InstallFolder folder, string[] args)
    {
        var passOn = new List<string>();
        int? after = null;
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--after" && i + 1 < args.Length &&
                int.TryParse(args[i + 1], NumberStyles.None, CultureInfo.InvariantCulture, out var id))
            {
                after = id;
                i++;
            }
            else
            {
                passOn.Add(args[i]);
            }
        }
        if (after is { } pid) WaitForEnd(pid);
        using var gate = new Mutex(false, InstallFolder.LauncherGate);
        Program.Take(gate);
        try
        {
            return Choose(folder, passOn);
        }
        finally
        {
            gate.ReleaseMutex();
        }
    }

    private static void WaitForEnd(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            process.WaitForExit();
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception)
        {
            // It has ended already.
        }
    }

    private static int Choose(InstallFolder folder, List<string> passOn)
    {
        CleanUp(folder);
        var current = folder.Current;
        if (folder.Next is { } next && next != current && !folder.Failed.Contains(next) && File.Exists(folder.AppOf(next)))
        {
            if (TryNew(folder, next, current, passOn)) return 0;
        }
        if (current is { } build && File.Exists(folder.AppOf(build)))
        {
            try
            {
                Launch(folder, build, passOn).Dispose();
                folder.Log(Who, $"started build {build}");
                return 0;
            }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException)
            {
                folder.Log(Who, $"Windows did not start build {build}: {e.Message}");
                return 1;
            }
        }
        folder.Log(Who, "no build to start: \"current\" names none, or its folder is gone");
        return 1;
    }

    /// <summary>Starts a checked new build and waits for its first good start or its end. False when it ended before
    /// its first good start: it is kept as failed, so it is not taken again.</summary>
    private static bool TryNew(InstallFolder folder, long next, long? current, List<string> passOn)
    {
        using var goodStart = new EventWaitHandle(false, EventResetMode.ManualReset, InstallFolder.GoodStartSignal(next));
        Process process;
        try
        {
            process = Launch(folder, next, passOn);
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException)
        {
            folder.Log(Who, $"Windows did not start build {next} ({e.Message}): it is kept as failed and not taken again");
            folder.MarkFailed(next);
            return false;
        }
        using (process)
        {
            folder.Log(Who, $"started build {next}, which waits for its first good start" +
                            (current is { } c ? $"; build {c} is current" : ""));
            using var ended = new ProcessEnd(process);
            var which = WaitHandle.WaitAny([ended, goodStart]);
            if (which == 1 || folder.Current == next)
            {
                folder.Log(Who, $"build {next} had its first good start");
                return true;
            }
            process.WaitForExit();
            folder.Log(Who, $"build {next} ended before its first good start (exit code {process.ExitCode}): it is kept as " +
                            "failed and not taken again" + (current is { } back ? $", and build {back} starts again" : ""));
            folder.MarkFailed(next);
            return false;
        }
    }

    private static Process Launch(InstallFolder folder, long build, List<string> passOn)
    {
        var start = new ProcessStartInfo(folder.AppOf(build))
        {
            UseShellExecute = false,
            WorkingDirectory = folder.BuildFolder(build),
        };
        foreach (var argument in passOn) start.ArgumentList.Add(argument);
        var process = Process.Start(start) ?? throw new InvalidOperationException("no process");
        // A build that starts after an update does not ask for the front (--after-update); any other start does.
        WindowsEntries.LetComeToFront(process.Id);
        return process;
    }

    /// <summary>Removes what an update left: half-written files, a launcher that a newer one replaced while it ran, and,
    /// while no build of this install runs, every download folder and every build folder that "current" and "next" do
    /// not name (the build before the current one goes at the start after its successor's first good start).</summary>
    private static void CleanUp(InstallFolder folder)
    {
        folder.TrimLog();
        if (!Directory.Exists(folder.Root)) return;
        foreach (var file in Directory.EnumerateFiles(folder.Root, "*.new").Concat(Directory.EnumerateFiles(folder.Root, "*.old")))
            Program.RemoveFile(file);
        var apps = Program.Apps(folder);
        var running = apps.Count > 0;
        foreach (var app in apps) app.Dispose();
        if (running) return;
        if (Directory.Exists(folder.Updates))
            foreach (var download in Directory.EnumerateDirectories(folder.Updates)) Program.RemoveFolder(download);
        if (!Directory.Exists(folder.Builds)) return;
        var keep = new HashSet<long>();
        if (folder.Current is { } current) keep.Add(current);
        if (folder.Next is { } next) keep.Add(next);
        if (keep.Count == 0) return;
        foreach (var build in Directory.EnumerateDirectories(folder.Builds))
        {
            var name = Path.GetFileName(build);
            if (long.TryParse(name, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && keep.Contains(number)) continue;
            Program.RemoveFolder(build);
            if (!Directory.Exists(build)) folder.Log(Who, $"removed the folder of build {name}");
        }
    }
}

/// <summary>The removal from Windows' list of installed apps (<c>--uninstall</c>): it ends the app of this install,
/// removes the Start menu entry, the entry of the list, every build, every download and the launcher's files, and
/// then, after this process ended, the launcher itself and the folder. It keeps %LOCALAPPDATA%\Founderizer, the store
/// and the device key: a setup run later reads with the same key and no new code, as the iPhone keeps its key in its
/// keychain when the app is deleted, and Remove on the owner's Mac is what ends this PC's access.</summary>
internal static class Removal
{
    public static int Run(InstallFolder folder)
    {
        // Only this user's install, or the one that Windows' list names: a launcher copied elsewhere removes nothing.
        if (!folder.Root.Equals(InstallFolder.ForUser().Root, StringComparison.OrdinalIgnoreCase) &&
            !WindowsEntries.UninstallEntryIsOurs(folder))
            return 2;
        EndApps(folder);
        using var gate = new Mutex(false, InstallFolder.LauncherGate);
        Program.Take(gate);
        try
        {
            // A launcher that waited for a new build's first good start may have started the current build again.
            EndApps(folder);
            WindowsEntries.Remove(folder);
            Program.RemoveFolder(folder.Builds);
            Program.RemoveFolder(folder.Updates);
            foreach (var name in new[] { "current", "previous", "next", "failed", "update.log" })
                Program.RemoveFile(Path.Combine(folder.Root, name));
            if (Directory.Exists(folder.Root))
                foreach (var file in Directory.EnumerateFiles(folder.Root, "*.new").Concat(Directory.EnumerateFiles(folder.Root, "*.old")))
                    Program.RemoveFile(file);
        }
        finally
        {
            gate.ReleaseMutex();
        }
        // This file runs, so Windows keeps it until this process ends: Windows PowerShell waits for that end, then
        // removes the launcher's file and the folder, only if nothing else is left in it.
        var script = $"Wait-Process -Id {Environment.ProcessId} -ErrorAction SilentlyContinue; " +
                     $"Remove-Item -LiteralPath '{Quoted(folder.Launcher)}' -Force -ErrorAction SilentlyContinue; " +
                     $"Remove-Item -LiteralPath '{Quoted(folder.Root)}' -ErrorAction SilentlyContinue";
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"))
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-EncodedCommand",
                                         Convert.ToBase64String(Encoding.Unicode.GetBytes(script)) })
            start.ArgumentList.Add(argument);
        try
        {
            Process.Start(start)?.Dispose();
        }
        catch (Win32Exception)
        {
            return 1;
        }
        return 0;
    }

    private static void EndApps(InstallFolder folder)
    {
        foreach (var app in Program.Apps(folder))
        {
            using (app)
            {
                try
                {
                    app.Kill();
                    app.WaitForExit();
                }
                catch (Exception e) when (e is Win32Exception or InvalidOperationException)
                {
                }
            }
        }
    }

    private static string Quoted(string path) => path.Replace("'", "''", StringComparison.Ordinal);
}

/// <summary>The setup: this program with one build inside. It checks the build as an update is checked (the path
/// rules, one app, its build.json, and every .exe and .dll signed by the setup's own signer), puts it in place for this
/// user, writes the launcher, the Start menu entry and the entry of Windows' list of installed apps, and starts the
/// app (not with <c>--no-start</c>). A build that is not newer than the installed one changes nothing but the two
/// entries. A refusal leaves the PC as it was, with its line in update.log.</summary>
internal static class Setup
{
    private const string Who = "setup";

    public static int Run(Stream zip, string[] args)
    {
        var folder = InstallFolder.ForUser();
        using var gate = new Mutex(false, InstallFolder.LauncherGate);
        Program.Take(gate);
        long launch;
        try
        {
            folder.Log(Who, $"starts: {Environment.ProcessPath}");
            using var signer = Publisher.ValidSigner(Environment.ProcessPath!);
            if (signer is null)
            {
                folder.Log(Who, "this setup carries no signature that Windows finds valid, so it installs nothing");
                return 2;
            }
            Directory.CreateDirectory(folder.Builds);
            Directory.CreateDirectory(folder.Updates);
            var work = Path.Combine(folder.Updates, "setup-" + Guid.NewGuid().ToString("N"));
            try
            {
                var unpacked = Path.Combine(work, "build");
                Directory.CreateDirectory(work);
                var info = BuildUnpack.Unpack(zip, unpacked, expected: null);
                if (info.Arch != BuildInfo.ThisArch)
                    throw new BuildRefused($"it is a build for {info.Arch}, and this setup runs as {BuildInfo.ThisArch}");
                if (Publisher.Refusal(unpacked, signer, out var count) is { } why) throw new BuildRefused(why);
                folder.Log(Who, $"build {info.Line}: unpacked, and its {count} .exe and .dll files carry the signature of " +
                                $"this setup's signer (\"{signer.Subject}\", {signer.Thumbprint})");
                var current = folder.Current;
                if (current is { } installed && installed >= info.Build && File.Exists(folder.AppOf(installed)))
                {
                    folder.Log(Who, $"build {installed} is installed, and it is not older than this build: it stays");
                    launch = installed;
                }
                else
                {
                    var target = folder.BuildFolder(info.Build);
                    if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
                    Directory.Move(unpacked, target);
                    if (current is null)
                    {
                        folder.SetCurrent(info.Build);
                        folder.Log(Who, $"build {info.Build} is in builds\\{info.Build}, and it is current");
                    }
                    else
                    {
                        folder.SetNext(info.Build);
                        folder.Log(Who, $"build {info.Build} is in builds\\{info.Build}, and it starts at the next start; " +
                                        $"build {current} is current until its first good start");
                    }
                    launch = info.Build;
                }
            }
            catch (Exception e) when (e is BuildRefused or IOException or UnauthorizedAccessException)
            {
                folder.Log(Who, $"refused: {e.Message}; nothing on this PC changed");
                return 3;
            }
            finally
            {
                Program.RemoveFolder(work);
            }
            if (folder.PlaceLauncher(launch)) folder.Log(Who, $"the launcher of build {launch} is at the top of the folder");
            WindowsEntries.WriteStartMenuEntry(folder);
            var running = BuildInfo.Read(folder.BuildFolder(folder.Current ?? launch));
            if (running is not null) WindowsEntries.WriteUninstallEntry(folder, running);
            folder.Log(Who, $"the Start menu entry ({WindowsEntries.StartMenuEntry}) and the entry of Windows' list of " +
                            "installed apps are written; no step asked for an administrator");
        }
        finally
        {
            gate.ReleaseMutex();
        }
        if (args.Contains("--no-start")) return 0;
        try
        {
            Process.Start(new ProcessStartInfo(folder.Launcher) { UseShellExecute = false, WorkingDirectory = folder.Root })?.Dispose();
        }
        catch (Win32Exception e)
        {
            folder.Log(Who, $"Windows did not start the launcher: {e.Message}");
            return 1;
        }
        return 0;
    }
}
