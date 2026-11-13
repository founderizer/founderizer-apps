using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>What a PC reads off its own Tailscale (the Mac's FleetOnTailscaleTests, with the same status): the devices,
/// the addresses to ask, the hub that answers, and the store that finds its hub with no address typed. No request leaves
/// this Mac: the one device that answers is the fake hub on 127.0.0.1.</summary>
[TestClass]
public sealed class TailnetTests
{
    internal const string Status = """
        {"BackendState": "Running",
         "Self": {"DNSName": "sams-macbook.tail1234.ts.net.", "TailscaleIPs": ["100.101.100.180", "fd7a:115c:a1e0::1"]},
         "Peer": {
           "a": {"DNSName": "worker-1.tail1234.ts.net.", "TailscaleIPs": ["100.96.100.130"], "Online": false},
           "b": {"DNSName": "worker-2.tail1234.ts.net.", "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.96.10.20"], "Online": true},
           "c": {"DNSName": "iphone.tail1234.ts.net.", "TailscaleIPs": ["100.101.100.90"], "Online": true},
           "d": {"DNSName": "", "TailscaleIPs": ["100.64.0.9"], "Online": true}
         }}
        """;

    private static readonly Uri Worker2 = new("http://100.96.10.20:8765/");

    [TestMethod]
    public void TheDevicesAreReadByTheirNameInTailscale()
    {
        var devices = Tailnet.Devices(Status);
        CollectionAssert.AreEqual(new[] { "iphone", "worker-1", "worker-2" }, devices.Select(d => d.Name).ToArray());
        Assert.AreEqual("100.96.10.20", devices.Single(d => d.Name == "worker-2").Address);
        Assert.AreEqual("sams-macbook", Tailnet.OwnName(Status));
        Assert.AreEqual(0, Tailnet.Devices("not json").Count);
        Assert.AreEqual(0, Tailnet.Devices("[]").Count);
    }

    [TestMethod]
    public void OnlineDevicesAreAskedFirst()
    {
        var asked = Tailnet.Candidates(Status).Select(u => u.ToString()).ToList();
        Assert.AreEqual(3, asked.Count);
        Assert.AreEqual("http://100.96.100.130:8765/", asked.Last());
    }

    [TestMethod]
    public void OnlyATailscaleAddressIsAsked()
    {
        foreach (var yes in new[] { "100.64.0.0", "100.127.255.255", "100.96.10.20" }) Assert.IsTrue(Tailnet.IsPrivateAddress(yes), yes);
        foreach (var no in new[] { "192.0.2.1", "198.51.100.7", "10.0.0.1", "127.0.0.1", "100.64.1", "100.64.0.256",
                                   "100.64.0.1.5", "fd7a:115c:a1e0::2", "+100.64.0.1", "" })
            Assert.IsFalse(Tailnet.IsPrivateAddress(no), no);
    }

    [TestMethod]
    public async Task TheHubThatAnswersFirstIsFoundAndNoAnswerFindsNone()
    {
        Assert.AreEqual(Worker2, await Tailnet.FindAsync(Status, (u, _) => Task.FromResult(u.Host == "100.96.10.20")));
        Assert.IsNull(await Tailnet.FindAsync(Status, (_, _) => Task.FromResult(false)));
        Assert.IsNull(await Tailnet.FindAsync("{}", (_, _) => Task.FromResult(true)), "a PC on no network finds none");
        Assert.IsNull(await Tailnet.FindAsync(null, (_, _) => Task.FromResult(true)));
        // Every device is asked at once, and the first answer wins, not the first device asked; a failure is no answer.
        var found = await Tailnet.FindAsync(Status, async (u, cancel) =>
        {
            if (u.Host == "100.101.100.90") throw new InvalidOperationException("no answer");
            await Task.Delay(u.Host == "100.96.10.20" ? 400 : 20, cancel);
            return true;
        });
        Assert.AreEqual("100.96.100.130", found!.Host);
    }

    // ---------------------------------------------------------------- the store

    /// <summary>The PC's own client, whose requests to worker-2 reach the fake hub; every other address has no route, so
    /// nothing leaves this Mac.</summary>
    private sealed class OneDeviceAnswers(Uri hub) : DelegatingHandler(HubClient.NewHandler(new HubClientOptions()))
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
        {
            var to = request.RequestUri!;
            if (to.Host != Worker2.Host || to.Port != Worker2.Port) throw new HttpRequestException("no route in the test");
            request.RequestUri = new UriBuilder(to) { Host = hub.Host, Port = hub.Port }.Uri;
            return base.SendAsync(request, cancel);
        }
    }

    private sealed class FixedStatus(string? json) : ITailscaleStatus
    {
        public int Reads;
        public Task<string?> ReadAsync(CancellationToken cancel)
        {
            Interlocked.Increment(ref Reads);
            return Task.FromResult(json);
        }
    }

    private string folder = "";
    private FakeHub hub = null!;

    [TestInitialize]
    public void Make()
    {
        folder = Directory.CreateTempSubdirectory("founderizer-tailnet-").FullName;
        hub = new FakeHub();
    }

    [TestCleanup]
    public void Remove()
    {
        hub.Dispose();
        Directory.Delete(folder, recursive: true);
    }

    private OwnerStore Store(string? status) => new(new StoreSettings
    {
        Folder = folder, Keys = new MemoryKeyStore("device-key-1"), Tailscale = new FixedStatus(status),
    }, new HubClient(new OneDeviceAnswers(hub.Address)));

    [TestMethod]
    public async Task APcWithNoHubFindsItOnItsTailscaleReadsItAndKeepsIt()
    {
        await using (var store = Store(Status))
        {
            Assert.IsTrue(store.State.HasNoHub);
            Assert.AreEqual(Worker2, await store.FindHubAsync());
            Assert.AreEqual((Worker2, HubSearch.Found), (store.State.Hub, store.State.Search));
            Assert.AreEqual("gen1", store.State.Fleet!.Db, "the hub that it found is read at once");
            Assert.IsTrue(hub.Server.Received.Any(r => r.Target == "/health"));
            Assert.IsNull(await store.FindHubAsync(), "a PC with a hub looks for none");
        }
        await using var again = Store(null);
        Assert.AreEqual((Worker2, HubSearch.None), (again.State.Hub, again.State.Search), "the next start keeps the hub");
        Assert.IsNull(await again.ConnectAsync(hub.Address.ToString()));
        Assert.AreEqual(HubSearch.None, again.State.Search, "an address that he types is his");
    }

    [TestMethod]
    public async Task APcOnNoNetworkOrWithNoHubOnItKeepsItsPageWithNoHub()
    {
        var cases = new (string? Status, HubSearch Search)[]
        {
            (null, HubSearch.NoNetwork),
            ("""{"BackendState": "Stopped", "Peer": {"b": {"DNSName": "worker-2.tail1234.ts.net.", "TailscaleIPs": ["100.96.10.20"], "Online": true}}}""", HubSearch.NoNetwork),
            ("""{"BackendState": "Running", "Peer": {"a": {"DNSName": "worker-1.tail1234.ts.net.", "TailscaleIPs": ["100.96.100.130"], "Online": true}}}""", HubSearch.NoHub),
            ("{}", HubSearch.NoHub),
        };
        foreach (var (status, search) in cases)
        {
            await using var store = Store(status);
            Assert.IsNull(await store.FindHubAsync());
            var s = store.State;
            Assert.AreEqual(search, s.Search, status);
            Assert.IsTrue(s.HasNoHub);
            Assert.AreEqual(PageKind.AddThisPc, Screens.FirstPage(s).Kind);
            Assert.IsNull(s.UnavailableWords(DateTimeOffset.UtcNow), "a PC with no hub has no line about one");
        }
        Assert.IsFalse(File.Exists(Path.Combine(folder, "hub.json")));
    }

    [TestMethod]
    public async Task InFrontAPcWithNoHubLooksForItByItself()
    {
        await using var store = Store(Status);
        store.SetFront(true);
        for (var i = 0; i < 100 && store.State.Fleet is null; i++) await Task.Delay(50);
        Assert.AreEqual(Worker2, store.State.Hub);
        Assert.AreEqual("gen1", store.State.Fleet?.Db);
        store.SetFront(false);
    }
}
