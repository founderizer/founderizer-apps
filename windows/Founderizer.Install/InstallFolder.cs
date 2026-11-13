using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace Founderizer.Install;

/// <summary>The folder of Founderizer for one user (windows-app-release-design.md, section 5):
/// <code>
/// %LOCALAPPDATA%\Programs\Founderizer\
///   Founderizer.exe            the launcher of the Start menu: it starts the build that "current" names
///   builds\&lt;build&gt;\            each build, whole, never changed after its check
///   current, previous          one build number each, written to a new file and moved over the old one
///   next                       the checked build that starts at the next start, before its first good start
///   failed                     the builds that ended before their first good start: none is taken again
///   updates\&lt;build&gt;-&lt;id&gt;\      one download, the user's only, removed at its end
///   update.log                 what the launcher, the setup and the updater did, one line each
/// </code>
/// The store and the device key are not here: they are in %LOCALAPPDATA%\Founderizer, which the removal keeps.</summary>
public sealed class InstallFolder(string root)
{
    public const string LauncherName = "Founderizer.exe";
    public const string AppName = "Founderizer.App.exe";
    /// <summary>The launcher holds it while it chooses and starts a build, and while it waits for a new build's first
    /// good start; the app takes it before it replaces the launcher's file.</summary>
    public const string LauncherGate = @"Local\Founderizer.Launcher";

    /// <summary>The name of the event that a build sets at its first good start, which the launcher waits for.</summary>
    public static string GoodStartSignal(long build) => @"Local\Founderizer.GoodStart." + Number(build);

    /// <summary>The folder of this user's install.</summary>
    public static InstallFolder ForUser() => new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Founderizer"));

    /// <summary>The install that holds a build's folder (<c>&lt;root&gt;\builds\&lt;build&gt;</c>), or null for a build
    /// that runs from anywhere else: such a build takes no update.</summary>
    public static InstallFolder? Holding(string buildFolder)
    {
        var folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(buildFolder));
        if (!long.TryParse(Path.GetFileName(folder), NumberStyles.None, CultureInfo.InvariantCulture, out var build) || build < 1)
            return null;
        var builds = Path.GetDirectoryName(folder);
        if (builds is null || !Path.GetFileName(builds).Equals("builds", StringComparison.OrdinalIgnoreCase)) return null;
        return Path.GetDirectoryName(builds) is { Length: > 0 } root ? new InstallFolder(root) : null;
    }

    public string Root { get; } = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
    public string Builds => Path.Combine(Root, "builds");
    public string Updates => Path.Combine(Root, "updates");
    public string Launcher => Path.Combine(Root, LauncherName);
    public string LogFile => Path.Combine(Root, "update.log");
    public string BuildFolder(long build) => Path.Combine(Builds, Number(build));
    public string AppOf(long build) => Path.Combine(BuildFolder(build), AppName);

    /// <summary>The build that had its first good start last: the launcher starts it.</summary>
    public long? Current => ReadNumber("current");
    /// <summary>The build that was current before it.</summary>
    public long? Previous => ReadNumber("previous");
    /// <summary>A checked build that waits for its first start.</summary>
    public long? Next => ReadNumber("next");

    /// <summary>The builds that ended before their first good start on this PC.</summary>
    public IReadOnlySet<long> Failed
    {
        get
        {
            var failed = new SortedSet<long>();
            foreach (var line in ReadText("failed")?.Split('\n') ?? [])
                if (long.TryParse(line.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var build) && build > 0)
                    failed.Add(build);
            return failed;
        }
    }

    /// <summary>This build had its first good start: it is current, and the build before it is previous.</summary>
    public void SetCurrent(long build)
    {
        if (Current is { } was && was != build) WriteText("previous", Number(was) + "\n");
        WriteText("current", Number(build) + "\n");
        if (Next == build) Remove("next");
    }

    public void SetNext(long build) => WriteText("next", Number(build) + "\n");

    public void ClearNext() => Remove("next");

    public void MarkFailed(long build)
    {
        var failed = new SortedSet<long>(Failed) { build };
        WriteText("failed", string.Concat(failed.Select(b => Number(b) + "\n")));
        if (Next == build) Remove("next");
    }

    /// <summary>Puts the launcher of <paramref name="build"/> at the top of the folder when it differs from the one there
    /// (section 5, step 7), with the new-file-and-move step. A launcher that runs cannot be replaced, but Windows lets its
    /// file be renamed: it moves aside, and the launcher's next start removes it. True when it changed.</summary>
    public bool PlaceLauncher(long build)
    {
        var source = Path.Combine(BuildFolder(build), LauncherName);
        if (!File.Exists(source) || File.Exists(Launcher) && SameBytes(source, Launcher)) return false;
        var fresh = Launcher + "." + Guid.NewGuid().ToString("N") + ".new";
        try
        {
            File.Copy(source, fresh);
            try
            {
                File.Move(fresh, Launcher, overwrite: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                File.Move(Launcher, Launcher + "." + Guid.NewGuid().ToString("N") + ".old");
                File.Move(fresh, Launcher);
            }
        }
        finally
        {
            if (File.Exists(fresh)) File.Delete(fresh);
        }
        return true;
    }

    private static bool SameBytes(string one, string other)
    {
        using var a = File.OpenRead(one);
        using var b = File.OpenRead(other);
        if (a.Length != b.Length) return false;
        return System.Security.Cryptography.SHA256.HashData(a).AsSpan().SequenceEqual(System.Security.Cryptography.SHA256.HashData(b));
    }

    /// <summary>One line of the log, with the time and who wrote it. A log that cannot be written stops nothing.</summary>
    public void Log(string who, string line)
    {
        try
        {
            Directory.CreateDirectory(Root);
            var text = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture) + " " + who +
                       ": " + line.Replace('\n', ' ').Replace('\r', ' ') + "\r\n";
            using var file = new FileStream(LogFile, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            file.Write(Encoding.UTF8.GetBytes(text));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Keeps the log's newest half when it grew past a megabyte. Only the launcher calls it, while it holds
    /// <see cref="LauncherGate"/>.</summary>
    public void TrimLog()
    {
        try
        {
            var info = new FileInfo(LogFile);
            if (!info.Exists || info.Length <= 1 << 20) return;
            var bytes = File.ReadAllBytes(LogFile);
            var keep = bytes.AsSpan(bytes.Length - (1 << 19));
            var start = keep.IndexOf((byte)'\n') + 1;
            WriteBytes(LogFile, keep[start..].ToArray());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public static string Number(long build) => build.ToString(CultureInfo.InvariantCulture);

    /// <summary>Writes a file of the folder whole: to a new file first, which then moves over the old one, so a reader
    /// finds the old text or the new one, never a part.</summary>
    public static void WriteBytes(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var fresh = path + "." + Guid.NewGuid().ToString("N") + ".new";
        try
        {
            using (var stream = new FileStream(fresh, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(fresh, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(fresh)) File.Delete(fresh);
        }
    }

    private void WriteText(string name, string text) => WriteBytes(Path.Combine(Root, name), Encoding.ASCII.GetBytes(text));

    private void Remove(string name) => File.Delete(Path.Combine(Root, name));

    private string? ReadText(string name)
    {
        try
        {
            return File.ReadAllText(Path.Combine(Root, name), Encoding.ASCII);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }
    }

    private long? ReadNumber(string name) =>
        long.TryParse(ReadText(name)?.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var build) && build > 0
            ? build : null;
}
