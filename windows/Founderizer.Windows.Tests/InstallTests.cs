using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using Founderizer.Install;
using Founderizer.Windows.Update;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Windows.Tests;

/// <summary>The install's own rules, with no install: the names a build's zip may hold, the unpack, the build's
/// build.json, the folder's pointers, and the keys that a release build trusts.</summary>
[TestClass]
public sealed class InstallTests
{
    private string scratch = "";

    [TestInitialize]
    public void MakeScratch()
    {
        scratch = Path.Combine(Path.GetTempPath(), "founderizer-install-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(scratch);
    }

    [TestCleanup]
    public void RemoveScratch() => Directory.Delete(scratch, recursive: true);

    [TestMethod]
    public void AnEntryStaysInItsFolder()
    {
        foreach (var good in new[] { "Founderizer.App.exe", "runtimes/win-arm64/native/a.dll", "Assets/", "a b.txt", "x.y.z",
                                     "COM10.txt", "console.dll", "lpt.txt" })
            Assert.IsNull(BuildUnpack.PathRefusal(good), good);
        foreach (var bad in new[] { "", "/", "../outside.txt", "a/../../b", "a\\..\\b", "/top.dll", "\\top.dll", "C:x.dll",
                                    "a/b:stream", "x/./y", "a//b", "a.", "a ", "a/b./c", "CON", "con.txt", "a/NUL.dll",
                                    "COM1", "Lpt9.log", "COM¹.txt", "CONOUT$", "a<b", "a|b", "a\u0001b",
                                    new string('a', 261) })
            Assert.IsNotNull(BuildUnpack.PathRefusal(bad), bad);
    }

    [TestMethod]
    public void AZipWithAnEntryThatLeavesItsFolderWritesNothing()
    {
        var zip = Zip(("Founderizer.App.exe", "app"), ("build.json", Json(7)), ("../outside.txt", "out"));
        var target = Path.Combine(scratch, "unpacked");
        var refused = Assert.ThrowsExactly<BuildRefused>(() => BuildUnpack.Unpack(zip, target, null));
        StringAssert.Contains(refused.Message, "leaves its folder");
        Assert.IsFalse(Directory.Exists(target));
        Assert.IsFalse(File.Exists(Path.Combine(scratch, "outside.txt")));
    }

    [TestMethod]
    public void ABuildHoldsOneAppAtItsTopAndNamesTheSignedBuild()
    {
        var good = BuildUnpack.Unpack(Zip(("Founderizer.App.exe", "app"), ("build.json", Json(7)), ("sub/a.dll", "a")),
                                      Path.Combine(scratch, "good"), new BuildInfo("0.2.3", 7, "arm64"));
        Assert.AreEqual(new BuildInfo("0.2.3", 7, "arm64"), good);
        Assert.AreEqual("a", File.ReadAllText(Path.Combine(scratch, "good", "sub", "a.dll")));

        var two = Zip(("Founderizer.App.exe", "app"), ("build.json", Json(7)), ("sub/founderizer.app.exe", "other"));
        StringAssert.Contains(Assert.ThrowsExactly<BuildRefused>(() => BuildUnpack.Unpack(two, Path.Combine(scratch, "two"), null)).Message,
                              "holds 2");
        var deep = Zip(("sub/Founderizer.App.exe", "app"), ("build.json", Json(7)));
        Assert.ThrowsExactly<BuildRefused>(() => BuildUnpack.Unpack(deep, Path.Combine(scratch, "deep"), null));
        var none = Zip(("Founderizer.App.exe", "app"));
        Assert.ThrowsExactly<BuildRefused>(() => BuildUnpack.Unpack(none, Path.Combine(scratch, "none"), null));

        var other = Zip(("Founderizer.App.exe", "app"), ("build.json", Json(8)));
        var words = Assert.ThrowsExactly<BuildRefused>(() =>
            BuildUnpack.Unpack(other, Path.Combine(scratch, "other"), new BuildInfo("0.2.3", 7, "arm64"))).Message;
        StringAssert.Contains(words, "names 0.2.3 (build 8, arm64), where the signed manifest names 0.2.3 (build 7, arm64)");

        var twice = Zip(("Founderizer.App.exe", "app"), ("build.json", Json(7)), ("a.dll", "1"), ("A.DLL", "2"));
        StringAssert.Contains(Assert.ThrowsExactly<BuildRefused>(() => BuildUnpack.Unpack(twice, Path.Combine(scratch, "twice"), null)).Message,
                              "twice");
    }

    [TestMethod]
    public void BuildJsonTakesItsThreeFieldsAndLeavesOthers()
    {
        Assert.AreEqual(new BuildInfo("0.2.3", 23, "x64"),
                        BuildInfo.Parse(Encoding.UTF8.GetBytes("{\"version\":\"0.2.3\",\"build\":23,\"arch\":\"x64\",\"later\":1}")));
        Assert.AreEqual(new BuildInfo("0.2.3", 23, "arm64"), BuildInfo.Parse(new BuildInfo("0.2.3", 23, "arm64").Json()));
        foreach (var bad in new[] { "{\"version\":\"0.2.3\",\"build\":23.0,\"arch\":\"x64\"}", "{\"version\":\"0.2.3\",\"build\":\"23\",\"arch\":\"x64\"}",
                                    "{\"version\":\"0.2.3\",\"build\":23,\"arch\":\"x86\"}", "{\"version\":\"\",\"build\":23,\"arch\":\"x64\"}",
                                    "{\"version\":\"0.2.3\",\"build\":0,\"arch\":\"x64\"}", "[]", "not json" })
            Assert.ThrowsExactly<BuildRefused>(() => BuildInfo.Parse(Encoding.UTF8.GetBytes(bad)), bad);
    }

    [TestMethod]
    public void ThePointersAreWrittenWholeAndFailedBuildsStay()
    {
        var folder = new InstallFolder(Path.Combine(scratch, "Founderizer"));
        Assert.IsNull(folder.Current);
        folder.SetCurrent(1);
        folder.SetNext(2);
        Assert.AreEqual(1L, folder.Current);
        Assert.AreEqual(2L, folder.Next);
        folder.SetCurrent(2);
        Assert.AreEqual(2L, folder.Current);
        Assert.AreEqual(1L, folder.Previous);
        Assert.IsNull(folder.Next);
        folder.SetNext(3);
        folder.MarkFailed(3);
        folder.MarkFailed(5);
        CollectionAssert.AreEqual(new long[] { 3, 5 }, folder.Failed.ToArray());
        Assert.IsNull(folder.Next);
        Assert.AreEqual(0, Directory.EnumerateFiles(folder.Root, "*.new").Count());

        var held = InstallFolder.Holding(folder.BuildFolder(2) + "\\");
        Assert.AreEqual(folder.Root, held?.Root);
        Assert.IsNull(InstallFolder.Holding(Path.Combine(scratch, "out", "arm64")));
        Assert.IsNull(InstallFolder.Holding(Path.Combine(folder.Root, "updates", "2")));
    }

    [TestMethod]
    public void AReleaseBuildTrustsTheLinesOfTheTwoKeyFiles()
    {
        // The lines of release-key.pub and early-key.pub of the fleet repository, as the Mac's AppUpdateTests holds them.
        foreach (var name in new[] { "KEY", "CHANNEL", "PIN", "EVERY", "AWAY" })
            Environment.SetEnvironmentVariable("FOUNDERIZER_UPDATE_" + name, null);
        string[] shipped = ["8Gc80zgZcWqA7nX3+lChW09v2cOSi0lfjf4OzFiY2Ao=", "pQ2RwJ1nL5KXI7dv6Pt71GHMqk61hMA0NQmPUwlSFiY="];
        const string early = "VxNkV9MNGrcPp62dGE9/mQjXsfgq7WAfWfnNzWSGZe4=";
        CollectionAssert.AreEqual(shipped, ReleaseChannel.Keys(early: false).Select(Convert.ToBase64String).ToArray());
        CollectionAssert.AreEqual(shipped.Append(early).ToArray(), ReleaseChannel.Keys(early: true).Select(Convert.ToBase64String).ToArray());
        Assert.AreEqual("https://founderizer.com", ReleaseChannel.Channel);
        Assert.AreEqual(TimeSpan.FromSeconds(120), ReleaseChannel.Away);
        Assert.AreEqual(TimeSpan.FromSeconds(60), ReleaseChannel.Retry(1));
        Assert.AreEqual(TimeSpan.FromSeconds(3600), ReleaseChannel.Every);
    }

    private static string Json(long build) => $"{{\"version\":\"0.2.3\",\"build\":{build},\"arch\":\"arm64\"}}";

    private static MemoryStream Zip(params (string Name, string Text)[] entries)
    {
        var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
            foreach (var (name, text) in entries)
            {
                using var writer = new StreamWriter(archive.CreateEntry(name).Open());
                writer.Write(text);
            }
        stream.Position = 0;
        return stream;
    }
}
