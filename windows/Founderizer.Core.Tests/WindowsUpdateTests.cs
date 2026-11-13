using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The library's part of the Windows release (windows-app-release-design.md, section 7): the manifest of a
/// Windows build against the vectors that releases.py signs, the comparison of builds in the Mac's words with "PC",
/// the read of the channel, and the download with its size and SHA-256 into a folder of its own. Every address is the
/// vectors' https host, which a handler of the test sends to a server on 127.0.0.1: nothing leaves this Mac.</summary>
[TestClass]
public sealed class WindowsUpdateTests
{
    private static JsonElement V => Vectors.Read("release-manifests.json");
    private static JsonElement Windows => V.GetProperty("windows");
    private static string Channel => Windows.GetProperty("channel").GetString()!;
    private static byte[][] Keys => [Convert.FromBase64String(V.GetProperty("public_key").GetString()!)];
    private static byte[] Manifest => Encoding.UTF8.GetBytes(Windows.GetProperty("manifest").GetRawText());
    private static readonly Version Windows11 = new(10, 0, 26100);

    [TestMethod]
    public void TheWindowsManifestVerifiesAndEachRefusedOneIsRefused()
    {
        var manifest = WindowsManifest.Check(Manifest, Keys, Channel, "arm64");
        Assert.AreEqual(Windows.GetProperty("signed_text").GetString(), Encoding.UTF8.GetString(manifest.SignedText()));
        Assert.AreEqual((23L, "arm64", "10.0.22621", false), (manifest.Build, manifest.Arch, manifest.MinimumSystem, manifest.Hold));
        var other = new[] { Convert.FromBase64String(V.GetProperty("other_public_key").GetString()!) };
        Assert.ThrowsExactly<ReleaseUntrusted>(() => WindowsManifest.Check(Manifest, other, Channel, "arm64"));
        Assert.ThrowsExactly<ReleaseUntrusted>(() => WindowsManifest.Check(Manifest, [], Channel, "arm64"));
        Assert.ThrowsExactly<ReleaseUntrusted>(() => WindowsManifest.Check(Manifest, Keys, "https://example.net", "arm64"));
        Assert.AreEqual("The channel's answer is a build for another kind of PC.",
                        Assert.ThrowsExactly<ReleaseUntrusted>(() => WindowsManifest.Check(Manifest, Keys, Channel, "x64")).Message,
                        "an x64 PC takes no arm64 build");
        foreach (var c in Windows.GetProperty("refused").EnumerateArray())
        {
            var refused = Encoding.UTF8.GetBytes(c.GetProperty("manifest").GetRawText());
            var arch = c.GetProperty("manifest").TryGetProperty("arch", out var a) && a.GetString() == "x64" ? "x64" : "arm64";
            Assert.ThrowsExactly<ReleaseUntrusted>(() => WindowsManifest.Check(refused, Keys, Channel, arch), c.GetProperty("name").GetString());
        }
    }

    [TestMethod]
    public void NoOtherKindIsReadAsAWindowsBuildAndAWindowsBuildIsReadAsNoOther()
    {
        // The Mac's own text of the same fields is other bytes, so the Mac's check refuses the Windows build.
        var macText = Windows.GetProperty("mac_text_of_its_fields").GetString()!;
        Assert.AreNotEqual(macText, Windows.GetProperty("signed_text").GetString());
        Assert.ThrowsExactly<ReleaseUntrusted>(() => AppManifest.Check(Manifest, Keys, Channel), "a Mac takes no Windows build");
        Assert.ThrowsExactly<ReleaseUntrusted>(() => FleetRelease.Check(Manifest, Keys), "a hub takes no Windows build");
        // A Mac build, with an arch put in, is no Windows build: its signature is over founderizer-app-1.
        var mac = JsonNode.Parse(V.GetProperty("app").GetProperty("manifest").GetRawText())!.AsObject();
        mac["arch"] = "arm64";
        Assert.ThrowsExactly<ReleaseUntrusted>(() => WindowsManifest.Check(Encoding.UTF8.GetBytes(mac.ToJsonString()), Keys, Channel, "arm64"));
        Assert.ThrowsExactly<ReleaseUntrusted>(() =>
            WindowsManifest.Check(Encoding.UTF8.GetBytes(V.GetProperty("fleet").GetProperty("manifest").GetRawText()), Keys, Channel, "arm64"));
        StringAssert.StartsWith(Windows.GetProperty("signed_text").GetString(), "founderizer-windows-1\n");
        Assert.AreEqual(10, Windows.GetProperty("signed_text").GetString()!.Count(c => c == '\n'));
    }

    // ---------------------------------------------------------------- the comparison of builds

    private static WindowsManifest Checked() => WindowsManifest.Check(Manifest, Keys, Channel, "arm64");

    [TestMethod]
    public void OnlyAHigherBuildThatIsNotHeldAndThatThisWindowsRunsIsOffered()
    {
        var m = Checked();
        var offered = WindowsUpdate.Reading(m, 200, new InstalledBuild("0.2.2", 22), Windows11);
        Assert.IsTrue(offered.Offered);
        Assert.AreEqual("Founderizer 0.2.3 is ready to install. This PC runs 0.2.2.", offered.Says);
        var same = WindowsUpdate.Reading(m, 200, new InstalledBuild("0.2.3", 23), Windows11);
        Assert.IsTrue(same is { Offered: false, Current: true });
        Assert.AreEqual("Founderizer 0.2.3 is the newest build. Nothing to install.", same.Says);
        Assert.IsTrue(WindowsUpdate.Reading(m, 200, new InstalledBuild("0.3.0", 30), Windows11).Current, "a lower build is never offered");
        var held = WindowsUpdate.Reading(m with { Hold = true }, 200, new InstalledBuild("0.2.2", 22), Windows11);
        Assert.AreEqual(("Founderizer 0.2.3 is held by us. No PC takes a held build.", false), (held.Says, held.Offered));
        var unknown = WindowsUpdate.Reading(m, 200, null, Windows11);
        Assert.IsFalse(unknown.Offered);
        StringAssert.StartsWith(unknown.Says, "Founderizer cannot tell which build it is");
        var old = WindowsUpdate.Reading(m, 200, new InstalledBuild("0.2.2", 22), new Version(10, 0, 22000));
        Assert.AreEqual(("Founderizer 0.2.3 needs Windows 10.0.22621, and this PC runs 10.0.22000. Update Windows first.", false),
                        (old.Says, old.Offered));
    }

    [TestMethod]
    public void AWindowsVersionIsComparedByMajorMinorAndBuild()
    {
        Assert.IsTrue(WindowsUpdate.Meets("10.0.22621", new Version(10, 0, 22621)));
        Assert.IsTrue(WindowsUpdate.Meets("10.0.22621", new Version(10, 0, 26100)));
        Assert.IsTrue(WindowsUpdate.Meets("10.0.22621", new Version(11, 0, 0)));
        Assert.IsFalse(WindowsUpdate.Meets("10.0.22621", new Version(10, 0, 19045)));
        Assert.IsFalse(WindowsUpdate.Meets("10.1.0", new Version(10, 0, 26100)));
        Assert.IsTrue(WindowsUpdate.Meets("10.0.0", new Version(10, 0)), "a Version with no build is build 0");
    }

    // ---------------------------------------------------------------- the channel and the download, on 127.0.0.1

    /// <summary>The PC's own client, whose requests to the vectors' host reach the local server; every other address
    /// has no route.</summary>
    private sealed class ToTheLocalServer(Uri server) : DelegatingHandler(new SocketsHttpHandler { UseCookies = false })
    {
        public int Sent;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
        {
            Interlocked.Increment(ref Sent);
            var to = request.RequestUri!;
            if (to.Scheme != "https" || to.Host != new Uri(Channel).Host) throw new HttpRequestException("no route in the test");
            request.RequestUri = new UriBuilder(to) { Scheme = "http", Host = server.Host, Port = server.Port }.Uri;
            return base.SendAsync(request, cancel);
        }
    }

    private string root = "";
    [TestInitialize] public void Make() => root = Directory.CreateTempSubdirectory("founderizer-update-").FullName;
    [TestCleanup] public void Remove() => Directory.Delete(root, recursive: true);

    [TestMethod]
    public async Task TheChannelIsAskedForThisArchAndItsTrackAndItsAnswerIsChecked()
    {
        using var server = new LoopbackHub(seen => seen.Target.StartsWith("/releases/windows?arch=arm64", StringComparison.Ordinal)
            ? LoopbackHub.Json(200, Windows.GetProperty("manifest").GetRawText())
            : LoopbackHub.Json(404, """{"error":"no release"}"""));
        using var http = new HttpMessageInvoker(new ToTheLocalServer(server.Address));
        var reading = await WindowsUpdate.ReadAsync(http, Channel, "arm64", early: true, Keys, new InstalledBuild("0.2.2", 22), Windows11, fleet: "0123456789abcdef");
        Assert.IsTrue(reading.Offered, reading.Says);
        var asked = server.Received.Single();
        Assert.AreEqual("/releases/windows?arch=arm64&track=early", asked.Target);
        Assert.AreEqual("0123456789abcdef", asked.Header("Founderizer-Fleet"));
        var x64 = await WindowsUpdate.ReadAsync(http, Channel, "x64", early: false, Keys, new InstalledBuild("0.2.2", 22), Windows11);
        Assert.AreEqual((404, "No build of Founderizer is published yet.", false), (x64.Status, x64.Says, x64.Offered));
        var untrusted = await WindowsUpdate.ReadAsync(http, Channel, "arm64", early: false, [], new InstalledBuild("0.2.2", 22), Windows11);
        StringAssert.StartsWith(untrusted.Says, "This build of Founderizer carries no release key");
        Assert.AreEqual(2, server.Received.Count, "a PC with no key asks nothing");
        using var nothing = new HttpMessageInvoker(new ToTheLocalServer(new Uri("http://127.0.0.1:9/")));
        var away = await WindowsUpdate.ReadAsync(nothing, Channel, "arm64", false, Keys, new InstalledBuild("0.2.2", 22), Windows11);
        Assert.AreEqual(("Founderizer could not reach our channel. Nothing changed on this PC, and it asks again by itself.", true),
                        (away.Says, away.Unreachable));
    }

    /// <summary>A build of <paramref name="size"/> bytes, and its manifest as the library checks it.</summary>
    private static (byte[] Bytes, WindowsManifest Manifest) Build(int size)
    {
        var bytes = new byte[size];
        new Random(7).NextBytes(bytes);
        var manifest = Checked() with { Size = size, Sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)) };
        return (bytes, manifest);
    }

    private static byte[] Raw(byte[] body, string? length) =>
        [.. Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/zip\r\n" +
                                    (length is null ? "" : $"Content-Length: {length}\r\n") + "\r\n"), .. body];

    [TestMethod]
    public async Task ADownloadGoesIntoAFolderOfItsOwnAndIsCheckedForSizeAndChecksum()
    {
        var (bytes, manifest) = Build(300_000);
        using var server = new LoopbackHub(_ => Raw(bytes, bytes.Length.ToString()));
        using var http = new HttpMessageInvoker(new ToTheLocalServer(server.Address));
        var parts = new System.Collections.Concurrent.ConcurrentQueue<double>();
        var file = await BuildDownload.FetchAsync(http, manifest, root, new Progress<double>(parts.Enqueue));
        CollectionAssert.AreEqual(bytes, await File.ReadAllBytesAsync(file));
        Assert.AreEqual(BuildDownload.FileName, Path.GetFileName(file));
        var folder = Path.GetDirectoryName(file)!;
        Assert.AreEqual(root, Path.GetDirectoryName(folder));
        StringAssert.StartsWith(Path.GetFileName(folder), "23-");
        if (!OperatingSystem.IsWindows())
            Assert.AreEqual(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute, File.GetUnixFileMode(folder));
        Assert.AreEqual("/downloads/Founderizer-Windows-0.2.3-arm64.zip", server.Received.Single().Target);
        Assert.AreEqual("application/zip", server.Received.Single().Header("Accept"));
        // A second download is a second folder: no download takes the place of another.
        var again = await BuildDownload.FetchAsync(http, manifest, root);
        Assert.AreNotEqual(folder, Path.GetDirectoryName(again));
        Assert.AreEqual(2, Directory.GetDirectories(root).Length);
    }

    [TestMethod]
    public async Task ADownloadThatIsNotTheSignedBytesLeavesNothingBehind()
    {
        var (bytes, manifest) = Build(200_000);
        var cases = new (string Name, byte[] Answer, string Says)[]
        {
            ("another file of the same size", Raw(bytes.Reverse().ToArray(), bytes.Length.ToString()),
             "The download does not match the checksum our channel signed. It was thrown away and nothing on this PC changed."),
            ("a length that is not the signed size", Raw(bytes, (bytes.Length + 1).ToString()),
             "The download is not the size the signed manifest promised. Nothing was unpacked."),
            ("more bytes than the signed size, with no length", Raw([.. bytes, .. new byte[70_000]], null),
             "The download is not the size the signed manifest promised. Nothing was unpacked."),
            ("fewer bytes than the signed size, with no length", Raw(bytes[..150_000], null),
             "The download is not the size the signed manifest promised. Nothing was unpacked."),
            ("fewer bytes than its length", Raw(bytes[..150_000], bytes.Length.ToString()),
             "The download is not the size the signed manifest promised. Nothing was unpacked."),
            ("no download", LoopbackHub.Json(404, """{"error":"not here"}"""),
             "The download did not start (404). Nothing on this PC changed."),
        };
        foreach (var (name, answer, says) in cases)
        {
            using var server = new LoopbackHub(_ => answer);
            using var http = new HttpMessageInvoker(new ToTheLocalServer(server.Address));
            var failed = await Assert.ThrowsExactlyAsync<UpdateFailure>(() => BuildDownload.FetchAsync(http, manifest, root), name);
            Assert.AreEqual(says, failed.Message, name);
            Assert.AreEqual(0, Directory.GetFileSystemEntries(root).Length, name + ": its folder is gone");
        }
        // A manifest whose address is not https asks nothing.
        using var none = new LoopbackHub(_ => Raw(bytes, bytes.Length.ToString()));
        var handler = new ToTheLocalServer(none.Address);
        using var client = new HttpMessageInvoker(handler);
        await Assert.ThrowsExactlyAsync<UpdateFailure>(() => BuildDownload.FetchAsync(client, manifest with { Url = "http://releases.example.com/a.zip" }, root));
        Assert.AreEqual(0, handler.Sent);
    }
}
