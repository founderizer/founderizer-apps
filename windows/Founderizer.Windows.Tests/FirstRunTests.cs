using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Install;
using Founderizer.Setup.Network;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Pages.FirstRun;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Windows.Tests;

/// <summary>**The window's own parts of the first run** (piece U1): Tailscale's install and its sign-in link, the owner's
/// kept answers, the welcome page's team, the line of a refused owner key, and the window's own words.</summary>
[TestClass]
public sealed class FirstRunTests
{
    private string scratch = "";

    [TestInitialize]
    public void MakeScratch()
    {
        scratch = Path.Combine(Path.GetTempPath(), "founderizer-first-run-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(scratch);
    }

    [TestCleanup]
    public void RemoveScratch() => Directory.Delete(scratch, recursive: true);

    // ------------------------------------------------------------------ Tailscale on this PC

    /// <summary>The bug: the app opens any link that <c>tailscale up</c> prints (a control server of someone else, a page
    /// with a user or a port, plain HTTP) in the owner's browser.</summary>
    [TestMethod]
    public void OnlyTailscalesOwnSignInPageOpens()
    {
        var link = TailscaleSetup.LoginLink("\thttps://login.tailscale.com/a/1a2b3c4d5e");
        Assert.IsNotNull(link);
        Assert.AreEqual("https://login.tailscale.com/a/1a2b3c4d5e", link.AbsoluteUri);
        Assert.IsNotNull(TailscaleSetup.LoginLink("To authenticate, visit: https://login.tailscale.com/a/1a2b3c4d5e"));
        foreach (var line in new[]
        {
            "http://login.tailscale.com/a/1a2b3c4d5e",
            "https://login.tailscale.com.example.com/a/1a2b3c4d5e",
            "https://example.com/https://login.tailscale.com/a/1a2b3c4d5e",
            "https://someone@login.tailscale.com/a/1a2b3c4d5e",
            "https://login.tailscale.com:8443/a/1a2b3c4d5e",
            "https://controlplane.example.com/a/1a2b3c4d5e",
            "Success.",
        })
            Assert.IsNull(TailscaleSetup.LoginLink(line), line);
    }

    /// <summary>The bug: a redirect, an answer that is not 200, or an answer of plain HTTP taken as Tailscale's list or
    /// installer.</summary>
    [TestMethod]
    public void OnlyTailscalesOwnAnswerIsTheInstaller()
    {
        static HttpResponseMessage Answer(HttpStatusCode status, string address) =>
            new(status) { RequestMessage = new HttpRequestMessage(HttpMethod.Get, address) };
        Assert.IsTrue(TailscaleSetup.FromTailscale(Answer(HttpStatusCode.OK, "https://pkgs.tailscale.com/stable/x.msi")));
        Assert.IsFalse(TailscaleSetup.FromTailscale(Answer(HttpStatusCode.Found, "https://pkgs.tailscale.com/stable/x.msi")));
        Assert.IsFalse(TailscaleSetup.FromTailscale(Answer(HttpStatusCode.OK, "http://pkgs.tailscale.com/stable/x.msi")));
        Assert.IsFalse(TailscaleSetup.FromTailscale(Answer(HttpStatusCode.OK, "https://pkgs.example.com/stable/x.msi")));
        Assert.IsFalse(TailscaleSetup.FromTailscale(new HttpResponseMessage(HttpStatusCode.OK)));
    }

    /// <summary>**The plan's "Must not": run a downloaded file before its check passed, or keep a downloaded file after a
    /// refusal.** A stand-in of Tailscale's list and of its installer, whose file nobody signed: the press says the Mac's
    /// sentence, the app's download folder is empty again, and nothing but the list and the file was asked for.</summary>
    [TestMethod]
    public async Task AnInstallerThatTailscaleDidNotSignIsRemovedAndNothingRuns()
    {
        var status = Path.Combine(scratch, "status.txt");
        File.WriteAllText(status, "none");
        var downloads = Path.Combine(scratch, "downloads");
        var asked = new List<string>();
        var stand = new StandIn(asked);
        using var setup = new TailscaleSetup(PcTailscale.StandIn(status), () => stand, downloads);
        Assert.IsFalse(PcTailscale.StandIn(status).Installed);
        var words = await setup.ConnectAsync(CancellationToken.None);
        Assert.AreEqual(TailscaleSetup.NotTailscales, words);
        Assert.IsTrue(!Directory.Exists(downloads) || !Directory.EnumerateFileSystemEntries(downloads).Any(), "the refused file is gone");
        var arch = PcNetwork.Arch(RuntimeInformation.OSArchitecture);
        CollectionAssert.AreEqual(new[] { PcNetwork.Packages.AbsoluteUri, $"{PcNetwork.PackagesFolder}tailscale-setup-1.104.7-{arch}.msi" }, asked);
    }

    private sealed class StandIn(List<string> asked) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
        {
            var address = request.RequestUri!.AbsoluteUri;
            asked.Add(address);
            HttpContent content = address == PcNetwork.Packages.AbsoluteUri
                ? new StringContent("""{"MSIs":{"amd64":"tailscale-setup-1.104.7-amd64.msi","arm64":"tailscale-setup-1.104.7-arm64.msi"},"MSIsVersion":"1.104.7"}""")
                : new ByteArrayContent(Encoding.ASCII.GetBytes(new string('x', 200_000)));
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content, RequestMessage = request });
        }
    }

    /// <summary>**Tailscale's real installer for this kind of PC passes the strict check, and a changed copy does not**: the
    /// list and the MSI from <c>pkgs.tailscale.com</c>, as the press reads them, with the revocation of the whole chain.
    /// The bug: a check so strict that Tailscale's own installer never passes it, and the press never installs.</summary>
    [TestMethod]
    [TestCategory("Network")]
    public async Task TailscalesRealInstallerPassesTheCheck()
    {
        if (Environment.GetEnvironmentVariable("FOUNDERIZER_NETWORK_TESTS") != "1") Assert.Inconclusive("FOUNDERIZER_NETWORK_TESTS=1 runs it");
        using var client = new HttpClient(ProviderHandler.Create()) { Timeout = TimeSpan.FromMinutes(10) };
        var list = await client.GetStringAsync(PcNetwork.Packages);
        var installer = PcNetwork.InstallerFor(PcNetwork.Arch(RuntimeInformation.OSArchitecture)!, list);
        Assert.IsNotNull(installer);
        var bytes = await client.GetByteArrayAsync(installer.Address);
        var file = Path.Combine(scratch, installer.File);
        File.WriteAllBytes(file, bytes);
        using (var held = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.IsTrue(Publisher.SignedBy(held, Signer.Organisation, Signer.Country));
        bytes[bytes.Length / 2] ^= 0x01;
        File.WriteAllBytes(file, bytes);
        Assert.IsFalse(Publisher.SignedBy(file, Signer.Organisation, Signer.Country));
    }

    // ------------------------------------------------------------------ the kept answers

    /// <summary>The bug: the owner's answers of the first run lost at the next start (the manager's name, the slider),
    /// or a file that does not read stopping the first run.</summary>
    [TestMethod]
    public void TheOwnersAnswersComeBackAtTheNextStart()
    {
        var path = Path.Combine(scratch, "setup", "choices.json");
        var first = new FileChoices(path);
        first.Set("firstRunManagerName", "Juno");
        first.Set("firstRunServersStep", "two");
        first.Set("firstRunAIProvider", "codex");
        first.Set("firstRunAIProvider", null);
        var next = new FileChoices(path);
        Assert.AreEqual("Juno", next.Get("firstRunManagerName"));
        Assert.AreEqual("two", next.Get("firstRunServersStep"));
        Assert.IsNull(next.Get("firstRunAIProvider"));
        File.WriteAllText(path, "{ not json");
        Assert.IsNull(new FileChoices(path).Get("firstRunManagerName"));
    }

    // ------------------------------------------------------------------ the welcome page

    /// <summary>The bug: a hue of the welcome page's marks that drifted from FleetMark's list, so the team's mint
    /// manager or one of its agents is not the colour of the Mac's page.</summary>
    [TestMethod]
    public void TheWelcomeMarksTakeFleetMarksHues()
    {
        Assert.AreEqual(GlyphLook.ToneCount, WelcomePlan.Tones.Count);
        for (int tone = 0; tone < GlyphLook.ToneCount; tone++)
        {
            var look = Enumerable.Range(0, 10_000).Select(i => new GlyphLook("agent-" + i)).First(l => l.Tone == tone);
            Assert.AreEqual(look.Light, WelcomePlan.Tones[tone].Light, $"tone {tone}");
            Assert.AreEqual(look.Deep, WelcomePlan.Tones[tone].Deep, $"tone {tone}");
        }
    }

    /// <summary>**A page that plays starts empty, and ends on the settled page exactly** (the Mac's rule of its keyframe
    /// timelines): the first frame is the bare canvas, and the last is what the page shows from its first frame where
    /// Windows' animation effects are off. The bugs: a quarter turn that ends at 90° (the Mac met it), a mark that never
    /// fully arrives, a dot that stays on a line, and words that stay faint.</summary>
    [TestMethod]
    public void TheWelcomeSequenceStartsEmptyAndEndsOnTheSettledPage()
    {
        int count = WelcomePlan.Agents.Count;
        Assert.AreEqual(0, WelcomePlan.PoseAt(null, 0).Opacity);
        for (int i = 0; i < count; i++)
        {
            Assert.AreEqual(0, WelcomePlan.PoseAt(i, 0).Opacity);
            Assert.AreEqual(0, WelcomePlan.Grown(i, 0));
            Assert.AreEqual(0, WelcomePlan.Dot(i, 0).Opacity);
        }
        Assert.AreEqual(0, WelcomePlan.Words(0));
        double end = WelcomePlan.Ends;
        Assert.IsTrue(end is > 5.5 and < 7, $"about six seconds, then stillness: {end}");
        Assert.AreEqual(new WelcomePlan.Pose(1, 1, 0), WelcomePlan.PoseAt(null, end));
        for (int i = 0; i < count; i++)
        {
            Assert.AreEqual(new WelcomePlan.Pose(1, 1, 0), WelcomePlan.PoseAt(i, end), $"agent {i}");
            Assert.AreEqual(1, WelcomePlan.Grown(i, end));
            Assert.AreEqual(0, WelcomePlan.Dot(i, end).Opacity);
            // Each agent makes its move: a turn or a rock leaves rest during it, a breath grows.
            var (_, moves, move) = WelcomePlan.Times(i);
            var during = WelcomePlan.PoseAt(i, moves + 0.4);
            Assert.IsTrue(move == WelcomePlan.Move.Breathe ? during.Scale > 1.05 : Math.Abs(during.Angle) > 5, $"agent {i} moves");
        }
        Assert.AreEqual(1, WelcomePlan.Words(end));
    }

    // ------------------------------------------------------------------ the line of a refused owner key

    /// <summary>The bug: the owner's computer says the phone's sentence for a refusal of its own key ("The hub refused this
    /// phone (owner_key_required)."), or sends the owner to Settings, where nothing repairs it; a device keeps step 1's
    /// line.</summary>
    [TestMethod]
    public void TheOwnersComputerSaysPcForTheRefusalsOfItsKey()
    {
        var hub = new Uri("http://100.64.0.9:8765/");
        var now = DateTimeOffset.UtcNow;
        foreach (var (auth, words) in new[]
        {
            (OwnerPcKey.Required, OwnerKeyLine.Required),
            (OwnerPcKey.Mismatch, OwnerKeyLine.Mismatch),
            (OwnerPcKey.NotExpected, OwnerKeyLine.NotExpected),
        })
        {
            var owner = new StoreState { Hub = hub, Role = HubRole.Owner, Key = KeyState.InHand, AuthProblem = auth };
            var line = OwnerKeyLine.Of(owner, Screens.Line(owner, now, Page.Tasks));
            Assert.IsNotNull(line, auth);
            Assert.AreEqual(words, line.Words);
            Assert.IsFalse(line.ActionIsSettings, auth);
            StringAssert.DoesNotMatch(line.Words, new System.Text.RegularExpressions.Regex("phone|Mac"));
        }
        var device = new StoreState { Hub = hub, Role = HubRole.Device, Key = KeyState.InHand, AuthProblem = OwnerPcKey.NotExpected };
        var library = Screens.Line(device, now, Page.Tasks);
        Assert.AreEqual(library, OwnerKeyLine.Of(device, library));
    }

    // ------------------------------------------------------------------ the window's own words

    /// <summary>**Each sentence of the window's own is the Mac's, with "PC"** (rule 14): the words of Tailscale's install,
    /// and of the first run's frame and boxes, which the Mac holds in its views only. The bug: a word that drifted from
    /// the Mac's.</summary>
    [TestMethod]
    public void TheWindowsOwnWordsAreTheMacs()
    {
        using var catalog = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "catalog", "Localizable.xcstrings")));
        var keys = catalog.RootElement.GetProperty("strings").EnumerateObject().Select(p => p.Name).ToHashSet(StringComparer.Ordinal);
        static string Mac(string words) => words.Replace("this PC", "this Mac").Replace("This PC", "This Mac");
        foreach (var words in new[]
        {
            TailscaleSetup.CannotDownload("%@"), TailscaleSetup.NoInstaller, TailscaleSetup.NotTailscales, TailscaleSetup.CannotOpen("%@"),
            SetupViewWords.Back, SetupViewWords.Server, SetupViewWords.Hub, SetupViewWords.Agent, SetupViewWords.AServer, SetupViewWords.Slider,
            SetupViewWords.Progress(0, 6, "%@").Replace("1 of 6", "%lld of %lld"), SetupViewWords.Progress(6, 6, "").Replace("6", "%lld"),
        })
            Assert.IsTrue(keys.Contains(Mac(words)), words);
    }
}
