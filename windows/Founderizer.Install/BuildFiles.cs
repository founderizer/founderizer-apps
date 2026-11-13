using System;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Founderizer.Install;

/// <summary>A build that may not be put in place, and why, in words for the log. Nothing that it reached stays.</summary>
public sealed class BuildRefused(string says) : Exception(says);

/// <summary>The build's own <c>build.json</c>, beside its <c>Founderizer.App.exe</c>: the version that the owner reads,
/// the build number that decides which build is newer, and the kind of PC it runs on. The build script writes it, the
/// unpack checks it against the signed manifest, and the running app reads it to know which build it is.</summary>
public sealed record BuildInfo(string Version, long Build, string Arch)
{
    public const string FileName = "build.json";

    /// <summary>The kind of PC of this process, in the manifest's words.</summary>
    public static string ThisArch => RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.Arm64 => "arm64",
        Architecture.X64 => "x64",
        _ => "",
    };

    public string Line => $"{Version} (build {InstallFolder.Number(Build)}, {Arch})";

    /// <summary>The build.json of a build's folder, or null when it is missing or cannot be read.</summary>
    public static BuildInfo? Read(string folder)
    {
        try
        {
            return Parse(File.ReadAllBytes(Path.Combine(folder, FileName)));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or BuildRefused)
        {
            return null;
        }
    }

    /// <summary>The three fields, each by the manifest's own rule; other fields are left for later builds.</summary>
    public static BuildInfo Parse(ReadOnlySpan<byte> data)
    {
        if (data.Length is 0 or > 4096) throw new BuildRefused("its build.json is empty or longer than 4 KB");
        try
        {
            using var document = JsonDocument.Parse(data.ToArray());
            var raw = document.RootElement;
            if (raw.ValueKind != JsonValueKind.Object) throw new BuildRefused("its build.json is not a JSON object");
            var version = raw.TryGetProperty("version", out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            if (version is null || !IsVersion(version)) throw new BuildRefused("its build.json has no version name");
            if (!raw.TryGetProperty("build", out var b) || b.ValueKind != JsonValueKind.Number ||
                b.GetRawText().AsSpan().IndexOfAny('.', 'e', 'E') >= 0 || !b.TryGetInt64(out var build) ||
                build is < 1 or > 2_000_000_000)
                throw new BuildRefused("its build.json has no build number");
            var arch = raw.TryGetProperty("arch", out var a) && a.ValueKind == JsonValueKind.String ? a.GetString() : null;
            if (arch is not ("x64" or "arm64")) throw new BuildRefused("its build.json names no kind of PC (x64 or arm64)");
            return new BuildInfo(version, build, arch);
        }
        catch (JsonException)
        {
            throw new BuildRefused("its build.json is not JSON");
        }
    }

    /// <summary>The bytes of build.json that the build script writes.</summary>
    public byte[] Json() => Encoding.UTF8.GetBytes(
        $"{{\"version\":\"{Version}\",\"build\":{InstallFolder.Number(Build)},\"arch\":\"{Arch}\"}}\n");

    /// <summary>The library's rule for a version name (CoreJson's Version): a letter or a digit, then at most 40 of
    /// letters, digits, space, dot, underscore, plus and minus.</summary>
    private static bool IsVersion(string text) =>
        text.Length is >= 1 and <= 41 && char.IsAsciiLetterOrDigit(text[0]) &&
        text.All(c => char.IsAsciiLetterOrDigit(c) || c is ' ' or '.' or '_' or '+' or '-');
}

/// <summary>The unpack of a build's zip into a new folder (windows-app-release-design.md, section 5, step 3): every
/// entry's path stays inside the folder, the build holds one <c>Founderizer.App.exe</c> at its top, and its
/// build.json names the build that the signed manifest names. Each entry's name is checked before the first byte is
/// written, so a zip with one bad name writes nothing.</summary>
public static class BuildUnpack
{
    public const int MostEntries = 20_000;
    public const long MostBytes = 2L << 30;

    /// <summary>Why an entry's name may not be written, or null when it may. A name ending in "/" is a folder.</summary>
    public static string? PathRefusal(string name)
    {
        if (name.Length is 0 or > 260) return "has no name, or a name longer than 260 characters";
        var body = name.EndsWith('/') ? name[..^1] : name;
        if (body.Length == 0) return "has no name";
        if (body[0] is '/' or '\\') return "starts at the top of a disk";
        foreach (var c in body)
        {
            if (c == ':') return "names a disk or a stream of a file (\":\")";
            if (c < 0x20 || c is '<' or '>' or '"' or '|' or '?' or '*') return "has a character that Windows refuses in a name";
        }
        foreach (var part in body.Split('/', '\\'))
        {
            if (part.Length == 0) return "has an empty part";
            if (part == "..") return "leaves its folder (\"..\")";
            if (part == ".") return "has a part \".\"";
            if (part.EndsWith('.') || part.EndsWith(' ')) return "has a part that ends with a dot or a space";
            if (IsDevice(part)) return "names a device of Windows";
        }
        return null;
    }

    /// <summary>A name that Windows reads as a device in every folder: CON, PRN, AUX, NUL, COM0 to COM9, LPT0 to LPT9
    /// (and with ¹, ² or ³), CONIN$ and CONOUT$, with any extension.</summary>
    private static bool IsDevice(string part)
    {
        var stem = part.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
        if (stem is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$") return true;
        return stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) &&
               (char.IsAsciiDigit(stem[3]) || stem[3] is '¹' or '²' or '³');
    }

    /// <summary>Unpacks <paramref name="zip"/> into <paramref name="target"/>, which must not exist yet, and gives the
    /// build's build.json; else <see cref="BuildRefused"/>. With <paramref name="expected"/>, its build.json must name
    /// the same version, build number and kind of PC. The caller removes the folder when this throws.</summary>
    public static BuildInfo Unpack(Stream zip, string target, BuildInfo? expected)
    {
        ZipArchive archive;
        try
        {
            archive = new ZipArchive(zip, ZipArchiveMode.Read, leaveOpen: true);
        }
        catch (InvalidDataException)
        {
            throw new BuildRefused("the download is not a zip");
        }
        using (archive)
        {
            var entries = archive.Entries;
            if (entries.Count > MostEntries) throw new BuildRefused($"the build has {entries.Count} entries, more than {MostEntries}");
            foreach (var entry in entries)
                if (PathRefusal(entry.FullName) is { } why)
                    throw new BuildRefused($"the entry \"{Printable(entry.FullName)}\" {why}");
            var apps = entries.Where(e => Leaf(e.FullName).Equals(InstallFolder.AppName, StringComparison.OrdinalIgnoreCase)).ToList();
            if (apps.Count != 1 || !apps[0].FullName.Equals(InstallFolder.AppName, StringComparison.OrdinalIgnoreCase))
                throw new BuildRefused($"the build holds {apps.Count} {InstallFolder.AppName}, where it must hold one, at its top");
            if (!entries.Any(e => e.FullName.Equals(BuildInfo.FileName, StringComparison.OrdinalIgnoreCase)))
                throw new BuildRefused($"the build has no {BuildInfo.FileName} at its top");

            var top = Path.TrimEndingDirectorySeparator(Path.GetFullPath(target));
            if (Directory.Exists(top) || File.Exists(top)) throw new IOException($"{top} is there already");
            Directory.CreateDirectory(top);
            long total = 0;
            var buffer = new byte[1 << 16];
            foreach (var entry in entries)
            {
                var path = Path.GetFullPath(Path.Combine(top, entry.FullName.Replace('/', '\\')));
                if (!path.StartsWith(top + "\\", StringComparison.OrdinalIgnoreCase))
                    throw new BuildRefused($"the entry \"{Printable(entry.FullName)}\" leaves its folder");
                if (entry.FullName.EndsWith('/'))
                {
                    Directory.CreateDirectory(path);
                    continue;
                }
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                FileStream file;
                try
                {
                    file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                }
                catch (IOException) when (File.Exists(path) || Directory.Exists(path))
                {
                    throw new BuildRefused($"the entry \"{Printable(entry.FullName)}\" is in the build twice");
                }
                using (file)
                using (var source = entry.Open())
                {
                    int read;
                    while ((read = source.Read(buffer)) > 0)
                    {
                        total += read;
                        if (total > MostBytes) throw new BuildRefused("the build unpacks to more than 2 GB");
                        file.Write(buffer, 0, read);
                    }
                }
            }
            var info = BuildInfo.Read(top) ?? throw new BuildRefused($"its {BuildInfo.FileName} cannot be read");
            if (expected is not null && info != expected)
                throw new BuildRefused($"its {BuildInfo.FileName} names {info.Line}, where the signed manifest names {expected.Line}");
            return info;
        }
    }

    private static string Leaf(string name)
    {
        var body = name.TrimEnd('/');
        var cut = body.LastIndexOfAny(['/', '\\']);
        return cut < 0 ? body : body[(cut + 1)..];
    }

    /// <summary>A name as the log may show it: no control character, and not longer than 120 characters.</summary>
    private static string Printable(string name)
    {
        var text = new string(name.Select(c => c < 0x20 ? '?' : c).ToArray());
        return text.Length <= 120 ? text : text[..120] + "…";
    }
}
