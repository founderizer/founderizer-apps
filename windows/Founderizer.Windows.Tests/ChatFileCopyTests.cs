using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Windows.Tests;

/// <summary>The PC's copy of a chat's file (<see cref="ChatFileCopy"/>): a file from an agent, or from a stranger through
/// a chat app, opens only with the mark of a download, only an inert kind starts in its own app, and its name is a safe
/// Windows name. The copies are real files on the machine's NTFS disk, with real streams; a stand-in takes the place of
/// the starts, so no test starts a program or File Explorer, and no test runs a file.</summary>
[TestClass]
public sealed class ChatFileCopyTests
{
    private static readonly byte[] Bytes = Encoding.ASCII.GetBytes("example bytes of a chat's file\r\n");

    private string root = "";

    [TestInitialize]
    public void MakeRoot()
    {
        root = Path.Combine(Path.GetTempPath(), "fz-chat-file-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        // The mark is a stream of NTFS: on another disk, these tests would say nothing of it.
        Assert.AreEqual("NTFS", new DriveInfo(Path.GetPathRoot(root)!).DriveFormat, root);
    }

    [TestCleanup]
    public void RemoveRoot() => Directory.Delete(root, recursive: true);

    private static MessageAttachment Attachment(long id, string name, string mime) =>
        new(id, name, mime, Bytes.Length, new string('0', 64), 1);

    /// <summary>A stand-in for Windows' starts: each call, with the mark that the copy has at that moment.</summary>
    private sealed class Starts : IFileStarts
    {
        public readonly List<(string How, string Copy, string? Mark)> Calls = [];

        public void Open(string copy) => Calls.Add(("open", copy, MarkOf(copy)));

        public void Show(string copy) => Calls.Add(("show", copy, MarkOf(copy)));
    }

    private static string? MarkOf(string copy)
    {
        try
        {
            return System.IO.File.ReadAllText(copy + ":Zone.Identifier");
        }
        catch (IOException)
        {
            return null;
        }
    }

    /// <summary>Each copy has the mark of a download (the Internet zone) before it opens or shows, so Windows asks before
    /// a file runs and Office opens it in Protected View. The bug that this catches: the mark's write left out, so a ZIP's
    /// <c>.bat</c> runs at a double-click with no question.</summary>
    [TestMethod]
    public void TheCopyHasTheMarkOfADownloadBeforeItOpensOrShows()
    {
        var starts = new Starts();
        ChatFileCopy.Open(Attachment(1, "report.pdf", "application/pdf"), Bytes, starts, root, ChatFileCopy.MarkDownloaded);
        ChatFileCopy.Open(Attachment(2, "bundle.zip", "application/zip"), Bytes, starts, root, ChatFileCopy.MarkDownloaded);
        Assert.AreEqual(2, starts.Calls.Count);
        foreach (var (_, copy, mark) in starts.Calls)
        {
            Assert.IsNotNull(mark, copy);
            Assert.Contains("[ZoneTransfer]", mark, copy);
            Assert.Contains("ZoneId=3", mark, copy);
            Assert.Contains("HostUrl=about:internet", mark, copy);
            CollectionAssert.AreEqual(Bytes, System.IO.File.ReadAllBytes(copy), copy);
            Assert.IsTrue(ChatFileCopy.HasMark(copy), copy);
        }
    }

    /// <summary>A copy whose mark does not write (a volume with no streams, an access fault) or says another zone is
    /// removed and not opened, and the open throws, so the page notes it as a file that did not open. The bugs that this
    /// catches: the write trusted with no read back, the copy left on the disk with no mark, and any stream taken for the
    /// mark.</summary>
    [TestMethod]
    public void ACopyWithNoMarkIsRemovedAndNotOpened()
    {
        var marks = new (string What, Action<string> Mark)[]
        {
            ("a write that does nothing", _ => { }),
            ("a volume with no streams", _ => throw new IOException("example: the volume has no streams")),
            ("an access fault", _ => throw new UnauthorizedAccessException("example: no access")),
            ("a mark of this computer's zone", c => System.IO.File.WriteAllText(c + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=0\r\n")),
        };
        long id = 10;
        foreach (var (what, mark) in marks)
        {
            var starts = new Starts();
            var file = Attachment(++id, "notes.txt", "text/plain");
            Assert.ThrowsExactly<IOException>(() => ChatFileCopy.Open(file, Bytes, starts, root, mark), what);
            Assert.AreEqual(0, starts.Calls.Count, what);
            Assert.AreEqual(0, Directory.GetFiles(root, "*", SearchOption.AllDirectories).Length, what);
        }
    }

    /// <summary>Only an inert kind starts in its own app, by the extension of the name that Windows writes and never by
    /// the hub's mime; each other kind, a ZIP included, is shown selected in File Explorer and never started. The bugs
    /// that this catches: a kind judged by its mime (a <c>text/plain</c> file named <c>x.js</c> or <c>x.ps1</c> is a
    /// script to Windows), a ZIP on the list, and the kind of the first extension (<c>x.pdf.exe</c>).</summary>
    [TestMethod]
    public void OnlyAnInertKindStartsInItsApp()
    {
        var never = new[]
        {
            ("x.js", "text/plain"), ("x.ps1", "text/plain"), ("x.vbs", "text/plain"), ("x.cmd", "text/plain"),
            ("x.bat", "application/zip"), ("x.bat.", "application/zip"), ("x.bat ", "application/zip"),
            ("x.pdf.exe", "application/pdf"), ("x.lnk", "application/octet-stream"), ("x.url", "application/zip"),
            ("x.zip", "application/zip"),
            ("x.hta", "text/plain"), ("x.csv", "text/csv"), ("x.md", "text/markdown"), ("x.svg", "image/svg+xml"),
            ("x", "text/plain"),
        };
        var opens = new[] { ("x.pdf", "application/pdf"), ("x.png", "image/png"), ("x.txt", "text/plain"), ("X.JPG", "image/jpeg"),
                            ("x.json", "application/json") };
        long id = 100;
        foreach (var (name, mime) in never.Concat(opens))
        {
            var starts = new Starts();
            var copy = ChatFileCopy.Open(Attachment(++id, name, mime), Bytes, starts, root, ChatFileCopy.MarkDownloaded);
            Assert.AreEqual(1, starts.Calls.Count, name);
            Assert.AreEqual(copy, starts.Calls[0].Copy, name);
            Assert.AreEqual(opens.Contains((name, mime)) ? "open" : "show", starts.Calls[0].How, name);
            Assert.IsTrue(System.IO.File.Exists(copy), name);
        }
        // The rule alone, also on a name that the copy never has: the dots and spaces at its end go, and a path part or
        // a second stream is no inert kind; "x.j\u017fon" is a look-alike of ".json", which no rule takes.
        foreach (var name in new[] { "x.bat.", "x.bat ", "x.bat. .", "x.pdf:evil.exe", "a\\x.pdf", "x.j\u017fon" })
            Assert.IsFalse(ChatFileCopy.OpensInItsApp(name), name);
    }

    /// <summary>Windows' starts of each way, through the one call that starts them (a stand-in here): Show starts File
    /// Explorer at its full path with the copy only as the argument of <c>/select,</c>, and no shell open; Open is the
    /// shell's open of the copy. The bugs that this catches: the show built as a shell open of the copy, which starts the
    /// file, and the open built as a show.</summary>
    [TestMethod]
    public void TheShowStartsFileExplorerAndNeverTheFile()
    {
        var started = new List<System.Diagnostics.ProcessStartInfo>();
        var starts = new ShellStarts(started.Add);
        var zip = Path.Combine(root, "5-0123456789ab", "bundle.zip");
        var pdf = Path.Combine(root, "6-0123456789ab", "report.pdf");
        starts.Show(zip);
        starts.Open(pdf);
        Assert.AreEqual(2, started.Count);
        var show = started[0];
        Assert.AreEqual(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"), show.FileName);
        Assert.IsTrue(Path.IsPathFullyQualified(show.FileName), show.FileName);
        Assert.IsFalse(show.UseShellExecute);
        Assert.AreEqual("/select,\"" + zip + "\"", show.Arguments);
        var open = started[1];
        Assert.IsTrue(open.UseShellExecute);
        Assert.AreEqual(pdf, open.FileName);
        Assert.AreEqual("", open.Arguments);
    }

    /// <summary>A copy is in a folder of its number and of its bytes' SHA-256: a new hub database numbers its files from
    /// 1 again. The bug that this catches: the folder of the number alone, so another file of that number lands beside
    /// an old copy.</summary>
    [TestMethod]
    public void ACopyIsAloneInAFolderOfItsNumberAndItsBytes()
    {
        var starts = new Starts();
        var first = ChatFileCopy.Open(Attachment(300, "a.txt", "text/plain"), Bytes, starts, root, ChatFileCopy.MarkDownloaded);
        // A new hub database gives the number 300 to another file.
        var other = Encoding.ASCII.GetBytes("other example bytes\r\n");
        var second = ChatFileCopy.Open(new MessageAttachment(300, "b.zip", "application/zip", other.Length, new string('0', 64), 1), other,
                                       starts, root, ChatFileCopy.MarkDownloaded);
        Assert.AreNotEqual(Path.GetDirectoryName(first), Path.GetDirectoryName(second));
        Assert.IsTrue(System.IO.File.Exists(first), first);
        CollectionAssert.AreEqual(new[] { "b.zip" }, Directory.GetFileSystemEntries(Path.GetDirectoryName(second)!).Select(Path.GetFileName).ToArray());
    }

    /// <summary>A copy that is there with the same bytes and the mark opens with no new write, so a second open while an
    /// app holds the copy (as Word holds a document) does not fail; a copy that lost its mark is written and marked
    /// again before it opens; and the files beside the copy are this user's own and stay. The bugs that this catches: a
    /// new write of a held copy, which fails; a copy opened again with no check of its mark; and a cleanup of the
    /// folder, which removes the files that Explorer's "Extract All" put there and a file that an app saved
    /// there.</summary>
    [TestMethod]
    public void ACopyThatIsThereWithItsMarkOpensWithNoNewWrite()
    {
        var starts = new Starts();
        var file = Attachment(400, "bundle.zip", "application/zip");
        var copy = ChatFileCopy.Open(file, Bytes, starts, root, ChatFileCopy.MarkDownloaded);
        var saved = Path.Combine(Path.GetDirectoryName(copy)!, "bundle", "report (2).docx");
        Directory.CreateDirectory(Path.GetDirectoryName(saved)!);
        System.IO.File.WriteAllBytes(saved, Bytes);
        using (new FileStream(copy, FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.AreEqual(copy, ChatFileCopy.Open(file, Bytes, starts, root, ChatFileCopy.MarkDownloaded));
        Assert.IsTrue(System.IO.File.Exists(saved), saved);
        System.IO.File.Delete(copy + ":Zone.Identifier");
        Assert.IsFalse(ChatFileCopy.HasMark(copy), copy);
        Assert.AreEqual(copy, ChatFileCopy.Open(file, Bytes, starts, root, ChatFileCopy.MarkDownloaded));
        Assert.AreEqual(3, starts.Calls.Count);
        foreach (var (_, _, mark) in starts.Calls) Assert.Contains("ZoneId=3", mark ?? "", copy);
        Assert.IsTrue(System.IO.File.Exists(saved), saved);
    }

    /// <summary>A name from the hub is a safe Windows name: no device, no second stream, no path part, no comma, no dot or
    /// space at its end, no hidden direction mark, a length that Windows takes, a neutral extension after a kind that
    /// File Explorer reads with no click, and the copy is that one file in its folder. The bugs that this catches:
    /// <c>CON.txt</c> written to the console's device, <c>a:b.txt</c> written as a stream of a file <c>a</c>, a comma
    /// that splits Explorer's command line, a long name that the write refuses, <c>x.bat.</c> kept with its dot, and a
    /// stranger's <c>x.url</c> or <c>desktop.ini</c> whose icon Explorer reads from another computer's share, which sends
    /// this user's sign-in there.</summary>
    [TestMethod]
    public void ANameIsASafeWindowsName()
    {
        var cases = new[]
        {
            ("CON.txt", "_CON.txt"), ("con", "_con"), ("Nul.tar.gz", "_Nul.tar.gz"), ("COM1.pdf", "_COM1.pdf"),
            ("LPT9", "_LPT9"), ("AUX .txt", "_AUX .txt"), ("COM\u00b2.png", "_COM\u00b2.png"), ("CONOUT$", "_CONOUT$"),
            ("CONSOLE.txt", "CONSOLE.txt"), ("COM10.txt", "COM10.txt"),
            ("a:b.txt", "a_b.txt"), ("x.pdf:Zone.Identifier", "x.pdf_Zone.Identifier"),
            ("..\\..\\evil.bat", "_.._.._evil.bat"), ("a/b.txt", "a_b.txt"), ("a<b>\"c|?*.txt", "a_b__c___.txt"),
            ("x.bat.", "x.bat"), ("x.bat ", "x.bat"), ("x.bat . .", "x.bat"), ("  report.pdf  ", "report.pdf"),
            ("", "file"), ("   ", "file"), ("...", "file"), (".env", "_.env"),
            ("invoice\u202etxt.exe", "invoicetxt.exe"), ("tab\there.txt", "tabhere.txt"), ("a,b.zip", "a_b.zip"),
            ("x.url", "x.url.download"), ("desktop.ini", "desktop.ini.download"), ("Desktop.INI", "Desktop.INI.download"),
            ("x.pif", "x.pif.download"), ("x.appref-ms", "x.appref-ms.download"), ("x.settingcontent-ms", "x.settingcontent-ms.download"),
            ("X.LNK", "X.LNK.download"), ("x.scf", "x.scf.download"), ("x.searchConnector-ms", "x.searchConnector-ms.download"),
            ("x.library-ms", "x.library-ms.download"), ("x.search-ms", "x.search-ms.download"), ("x.theme", "x.theme.download"),
            ("x.themepack", "x.themepack.download"), ("x.deskthemepack", "x.deskthemepack.download"),
            ("x.website", "x.website.download"), ("x.url.", "x.url.download"), ("x.url.txt", "x.url.txt"), ("my desktop.ini.txt", "my desktop.ini.txt"),
        };
        foreach (var (name, safe) in cases) Assert.AreEqual(safe, ChatFileCopy.DiskName(name), name);

        var longName = ChatFileCopy.DiskName(new string('a', 296) + ".txt");
        Assert.AreEqual(ChatFileCopy.NameLimit, longName.Length, longName);
        Assert.IsTrue(longName.EndsWith(".txt", StringComparison.Ordinal) && longName.StartsWith("aaaa", StringComparison.Ordinal), longName);
        // A cut never leaves half of a character.
        var cut = ChatFileCopy.DiskName(new string('a', ChatFileCopy.NameLimit - 5) + "\ud83d\ude00\ud83d\ude00\ud83d\ude00.txt");
        Assert.IsTrue(cut.Length <= ChatFileCopy.NameLimit && cut.EndsWith(".txt", StringComparison.Ordinal), cut);
        Assert.IsTrue(cut.EnumerateRunes().All(r => r.Value != 0xFFFD), cut);

        // On the disk: the copy is the one file of its folder, under that name, and no other file or stream comes.
        long id = 200;
        foreach (var name in new[] { "CON.txt", "a:b.txt", new string('b', 296) + ".txt", "x.bat.", "x.url", "desktop.ini" })
        {
            var starts = new Starts();
            var copy = ChatFileCopy.Open(Attachment(++id, name, "text/plain"), Bytes, starts, root, ChatFileCopy.MarkDownloaded);
            var folder = Path.GetDirectoryName(copy)!;
            var written = Directory.GetFiles(folder).Select(Path.GetFileName).ToList();
            CollectionAssert.AreEqual(new[] { ChatFileCopy.DiskName(name) }, written, name);
            CollectionAssert.AreEqual(Bytes, System.IO.File.ReadAllBytes(copy), name);
            Assert.AreEqual(1, starts.Calls.Count, name);
        }
        var names = Directory.GetFiles(root, "*", SearchOption.AllDirectories).Select(Path.GetFileName).ToList();
        CollectionAssert.Contains(names, "x.url.download");
        CollectionAssert.Contains(names, "desktop.ini.download");
        CollectionAssert.DoesNotContain(names, "x.url");
        CollectionAssert.DoesNotContain(names, "desktop.ini");
    }
}
