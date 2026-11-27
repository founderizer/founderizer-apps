using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>What the PC does with the copy of a chat's file: it opens the copy in the app that Windows gives its kind, or
/// it shows the copy selected in File Explorer and starts nothing.</summary>
internal interface IFileStarts
{
    /// <summary>The shell's open of the copy (only for a kind of <see cref="ChatFileCopy.OpensInItsApp"/>).</summary>
    void Open(string copy);

    /// <summary>File Explorer with the copy selected. Nothing of the copy runs: a double-click there treats it as a
    /// browser's download, with its mark.</summary>
    void Show(string copy);
}

/// <summary>The starts of Windows itself: each way builds its <see cref="ProcessStartInfo"/>, and one call starts it.
/// The tests give that call a stand-in, so they see what each way starts, and never start a program or File
/// Explorer.</summary>
internal sealed class ShellStarts(Action<ProcessStartInfo> start) : IFileStarts
{
    /// <summary>Windows' own start: the one <c>Process.Start</c> of a chat's file, with the whole start of its way
    /// (<c>WindowRulesTests</c> holds this line).</summary>
    public static readonly ShellStarts Shared = new(info => Process.Start(info)?.Dispose());

    public void Open(string copy) => start(OpenStart(copy));

    public void Show(string copy) => start(ShowStart(copy));

    /// <summary>The shell's open of the copy: the app that Windows gives the copy's extension.</summary>
    public static ProcessStartInfo OpenStart(string copy) => new(copy) { UseShellExecute = true };

    /// <summary>File Explorer at its full path in the Windows folder (no search of PATH or of the current folder), with
    /// <c>/select,"&lt;copy&gt;"</c>. No shell open: the copy is an argument of Explorer, never the program. A copy's
    /// path has no quotation mark (<see cref="ChatFileCopy.DiskName"/> removes it, and Windows takes none in a path), and
    /// its name has no comma, so Explorer's command line does not split at one.</summary>
    public static ProcessStartInfo ShowStart(string copy) =>
        new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"))
        {
            Arguments = "/select,\"" + copy + "\"",
            UseShellExecute = false,
        };
}

/// <summary>**The PC's copies of a chat's files** (the Mac's <c>ChatFileCopy</c>): one folder for each file under this
/// user's temporary folder (<c>%TEMP%\Founderizer\&lt;id&gt;-&lt;SHA-256&gt;</c>, which only this user can read), the
/// file under a safe Windows name (<see cref="DiskName"/>) in a folder of its own, and the mark of a download on each
/// copy (the <c>Zone.Identifier</c> stream, <c>ZoneId=3</c>), read back before any open: a copy with no mark is removed
/// and never opened (the Mac's <c>marked</c>). A file comes from an agent, or from a stranger through a chat app.
///
/// The PC departs from the Mac here: the Mac shows a chat's file in its Quick Look preview and never starts it; Windows
/// has no such preview, so the PC opens only an inert kind in its own app (<see cref="OpensInItsApp"/>), and shows each
/// other kind selected in File Explorer, where a double-click treats it as a browser's download.</summary>
internal static class ChatFileCopy
{
    /// <summary>The kinds that open in their own app, by the extension of the name as Windows writes it, never by the
    /// mime that the hub gives (a <c>text/plain</c> file named <c>x.js</c> or <c>x.ps1</c> is a script to Windows):
    /// pictures (Photos), PDF (the PDF reader), plain text (Notepad), and the Office kinds that cannot hold a macro
    /// (Word, Excel and PowerPoint open them in Protected View with the mark). Not on the list, because their app is not
    /// sure to be inert: <c>.csv</c> (Excel takes it, not Notepad, and a cell can hold a formula), <c>.md</c> (a Markdown
    /// app shows the HTML in the text, and some of them ran its script), <c>.svg</c> and <c>.html</c> (a browser runs
    /// their script), a ZIP (Explorer, where a file in it has no mark), and each kind that runs code.</summary>
    public static readonly IReadOnlySet<string> Inert = new HashSet<string>(StringComparer.Ordinal)
    {
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp",
        ".pdf",
        ".txt", ".log", ".json",
        ".docx", ".xlsx", ".pptx",
    };

    /// <summary>The most UTF-16 units of a written name before its device mark and its <see cref="Neutral"/>: the
    /// folder of a copy in <c>%TEMP%</c> and this name stay under Windows' 260 of a path.</summary>
    public const int NameLimit = 120;

    /// <summary>The longest extension that a cut name keeps, with its dot.</summary>
    private const int ExtensionLimit = 16;

    /// <summary>The mark of a download, as a browser writes it: the Internet zone.</summary>
    public const string Mark = "[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=about:internet\r\n";

    /// <summary>Windows' reserved names of devices (the list of <c>BuildUnpack</c>'s check of a build's files): a file
    /// with one of them as the part before its first dot (with or without an extension) is the device, not a file of
    /// the folder.</summary>
    private static readonly HashSet<string> Devices = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
        "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
        "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³",
    };

    /// <summary>The characters that Windows takes in no name, or that leave the folder or open a second stream, and
    /// the comma, at which Explorer's command line splits.</summary>
    private const string Unsafe = "/\\:*?\"<>|,";

    /// <summary>The kinds that File Explorer reads with no click, to draw an icon or a preview: a stranger's shortcut
    /// (<c>.lnk</c>, <c>.pif</c>, <c>.url</c>, <c>.website</c>, <c>.appref-ms</c>), shell command file, settings
    /// shortcut, library, search, theme or folder settings can point at a share of another computer, and
    /// Windows then sends this user's sign-in (NTLM) to that computer. Each gets <see cref="Neutral"/> after its
    /// name, so Explorer shows a plain icon and reads nothing of it.</summary>
    private static readonly HashSet<string> ExplorerReads = new(StringComparer.OrdinalIgnoreCase)
    {
        ".lnk", ".pif", ".url", ".website", ".scf", ".appref-ms", ".settingcontent-ms", ".library-ms", ".searchConnector-ms",
        ".search-ms", ".theme", ".themepack", ".deskthemepack",
    };

    /// <summary>An extension that Windows gives no app and no icon of its own, after the name of a kind of
    /// <see cref="ExplorerReads"/>.</summary>
    public const string Neutral = ".download";

    /// <summary>The folder of the copies: this user's own temporary folder.</summary>
    public static string Folder => Path.Combine(Path.GetTempPath(), "Founderizer");

    /// <summary>Opens a chat's file as <see cref="Open(MessageAttachment, byte[], IFileStarts, string, Action{string})"/>
    /// does, with Windows' own starts, folder and mark.</summary>
    public static string Open(MessageAttachment file, byte[] bytes) => Open(file, bytes, ShellStarts.Shared, Folder, MarkDownloaded);

    /// <summary>Writes the marked copy, then opens an inert kind in its own app and shows each other kind selected in
    /// File Explorer. The kind is the extension of the name that it wrote; the hub's mime does not count. Throws an
    /// <see cref="IOException"/> when the copy has no mark (it is then removed), and an exception of the file system
    /// when the folder or the write fails. Gives the copy's path.</summary>
    public static string Open(MessageAttachment file, byte[] bytes, IFileStarts starts, string root, Action<string> mark)
    {
        var copy = Written(file, bytes, root, mark);
        if (OpensInItsApp(Path.GetFileName(copy))) starts.Open(copy);
        else starts.Show(copy);
        return copy;
    }

    /// <summary>The bytes in the file's own folder under its safe name, with the mark of a download, checked. The
    /// folder is the file's number and the start of its bytes' own SHA-256: a new hub database numbers its files from 1
    /// again, and another file under an old number gets a folder of its own. The app removes nothing in the folder: what
    /// is there beside the copy is this user's own (the files of a ZIP that Explorer's "Extract All" put there, a file
    /// that an app saved there). A copy that is there with these bytes and with the mark opens with no new write, so a
    /// second open while an app holds the copy does not fail.</summary>
    public static string Written(MessageAttachment file, byte[] bytes, string root, Action<string> mark)
    {
        var hash = SHA256.HashData(bytes);
        var place = Path.Combine(root, file.Id.ToString(CultureInfo.InvariantCulture) + "-" + Convert.ToHexStringLower(hash)[..12]);
        Directory.CreateDirectory(place);
        var copy = Path.Combine(place, DiskName(file.Name));
        if (IsCopyOf(copy, hash) && HasMark(copy)) return copy;
        File.WriteAllBytes(copy, bytes);
        Marked(copy, mark);
        return copy;
    }

    /// <summary>The file is there and holds bytes of this SHA-256 (read while an app holds it for reading).</summary>
    private static bool IsCopyOf(string copy, byte[] hash)
    {
        try
        {
            using var held = new FileStream(copy, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return SHA256.HashData(held).AsSpan().SequenceEqual(hash);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>Puts the mark on the copy and reads it back: a copy with no mark (a volume with no streams, an access
    /// fault, a mark of another zone) is removed and throws, so it is never opened.</summary>
    public static void Marked(string copy, Action<string> mark)
    {
        try
        {
            mark(copy);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
        {
            // The read below decides.
        }
        if (HasMark(copy)) return;
        try
        {
            File.Delete(copy);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // A copy that stays has no mark, and it is not opened all the same.
        }
        throw new IOException("the copy of a chat's file has no mark of a download, so it does not open");
    }

    /// <summary>Writes the <c>Zone.Identifier</c> stream of the copy (NTFS only).</summary>
    public static void MarkDownloaded(string copy) => File.WriteAllText(copy + ":Zone.Identifier", Mark, Encoding.ASCII);

    /// <summary>The copy's <c>Zone.Identifier</c> stream reads, and it says the Internet zone (3) or the restricted
    /// zone (4).</summary>
    public static bool HasMark(string copy)
    {
        try
        {
            var lines = File.ReadAllLines(copy + ":Zone.Identifier").Select(l => l.Trim()).ToList();
            return lines.Contains("[ZoneTransfer]") && (lines.Contains("ZoneId=3") || lines.Contains("ZoneId=4"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
        {
            return false;
        }
    }

    /// <summary>The written name's kind opens in its own app: its extension, after Windows' removal of the dots and
    /// spaces at a name's end (so <c>x.bat.</c> and <c>x.bat </c> are <c>.bat</c>), is on <see cref="Inert"/>, in ASCII
    /// letters only. A name with a path part or a second stream is no such kind.</summary>
    public static bool OpensInItsApp(string written)
    {
        if (written.IndexOfAny(['/', '\\', ':']) >= 0) return false;
        var name = WindowsEnd(written);
        var dot = name.LastIndexOf('.');
        if (dot <= 0) return false;
        var extension = name[dot..];
        return extension.All(char.IsAscii) && Inert.Contains(extension.ToLowerInvariant());
    }

    /// <summary>The name as one file of a folder on Windows. The Mac's rules (<c>MessageAttachment.diskName</c>): an
    /// invisible format or control character (a right-to-left override) goes, so the name never shows another extension
    /// than its own; a slash or a colon becomes "_", so the name never leaves its folder and never opens a second
    /// stream; a name that begins with a dot gets "_" in front; an empty name is "file". Windows' rules: the other
    /// characters that Windows takes in no name, and the comma, become "_"; no dot or space at the end (Windows removes
    /// them, so the name is the name that Windows writes); at most <see cref="NameLimit"/> units, with the extension
    /// kept; a reserved name of a device (<c>CON</c>, <c>NUL</c>, <c>COM1</c>, also <c>CON.txt</c>) gets "_" in front;
    /// a kind that Explorer reads with no click (<see cref="ExplorerReads"/>, and <c>desktop.ini</c>) gets
    /// <see cref="Neutral"/> after it.</summary>
    public static string DiskName(string name)
    {
        var kept = new StringBuilder(name.Length);
        foreach (var rune in name.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.Format or UnicodeCategory.Control
                or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator)
                continue;
            if (rune.IsAscii && Unsafe.Contains((char)rune.Value, StringComparison.Ordinal)) kept.Append('_');
            else kept.Append(rune.ToString());
        }
        var cleaned = WindowsEnd(kept.ToString().Trim());
        if (cleaned.Length == 0) return "file";
        if (cleaned[0] == '.') cleaned = "_" + cleaned;
        if (cleaned.Length > NameLimit) cleaned = Cut(cleaned);
        var stem = cleaned.Split('.')[0].TrimEnd(' ');
        var named = Devices.Contains(stem) ? "_" + cleaned : cleaned;
        return ReadByExplorer(named) ? named + Neutral : named;
    }

    /// <summary>File Explorer reads a file of this name with no click: <c>desktop.ini</c>, or a kind of
    /// <see cref="ExplorerReads"/>.</summary>
    private static bool ReadByExplorer(string name)
    {
        var dot = name.LastIndexOf('.');
        return string.Equals(name, "desktop.ini", StringComparison.OrdinalIgnoreCase) || (dot > 0 && ExplorerReads.Contains(name[dot..]));
    }

    /// <summary>A long name at <see cref="NameLimit"/>: the start of its stem and its extension (an extension longer
    /// than <see cref="ExtensionLimit"/> goes with the rest), never half of a character.</summary>
    private static string Cut(string name)
    {
        var dot = name.LastIndexOf('.');
        var extension = dot > 0 && name.Length - dot <= ExtensionLimit ? name[dot..] : "";
        var stem = name[..(NameLimit - extension.Length)];
        if (char.IsHighSurrogate(stem[^1])) stem = stem[..^1];
        stem = WindowsEnd(stem);
        return (stem.Length == 0 ? "file" : stem) + extension;
    }

    /// <summary>The name with no dot or white space at its end, as Windows writes a name.</summary>
    private static string WindowsEnd(string name)
    {
        var end = name.Length;
        while (end > 0 && (name[end - 1] == '.' || char.IsWhiteSpace(name[end - 1]))) end--;
        return name[..end];
    }
}
