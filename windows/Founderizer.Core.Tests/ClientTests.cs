using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The client against a hub on 127.0.0.1 that answers what each test says: the headers it sends, gzip, no
/// redirect, 304, the refusals and their `auth`, no answer, a timeout, and the size caps.</summary>
[TestClass]
public sealed class ClientTests
{
    private const string Snapshot =
        """{"schema_version":1,"db":"gen","time":1.0,"agents":[],"needs":[],"tasks":[],"recent":[],"holds":[],"outcomes":[],"token":"b.1.1"}""";

    private static byte[] Gzip(string text)
    {
        using var output = new MemoryStream();
        using (var zip = new GZipStream(output, CompressionLevel.Fastest)) zip.Write(Encoding.UTF8.GetBytes(text));
        return output.ToArray();
    }

    [TestMethod]
    public async Task AReadCarriesTheKeyAcceptsGzipAndReadsAGzippedAnswer()
    {
        using var hub = new LoopbackHub(_ => LoopbackHub.Raw(200, Gzip(Snapshot), ("Content-Type", "application/json"),
                                                             ("Content-Encoding", "gzip"), ("ETag", "\"tag1\"")));
        using var client = new HubClient();
        var reading = await client.SnapshotAsync(hub.Address, "device-key", "gen", "\"tag0\"");
        Assert.AreEqual("gen", reading!.Snapshot.Db);
        Assert.AreEqual("\"tag1\"", reading.ETag);
        Assert.IsTrue(hub.Received.TryDequeue(out var seen));
        Assert.AreEqual("GET /ui/mobile?db=gen", seen.Method + " " + seen.Target);
        Assert.AreEqual("Bearer device-key", seen.Header("Authorization"));
        Assert.AreEqual("\"tag0\"", seen.Header("If-None-Match"));
        Assert.AreEqual("application/json", seen.Header("Accept"));
        Assert.AreEqual("gzip", seen.Header("Accept-Encoding"));
        Assert.IsNull(seen.Header("Cookie"));
    }

    [TestMethod]
    public async Task ADeviceWithNoKeySendsNoAuthorizationAndAnUnchangedFleetIsNull()
    {
        using var hub = new LoopbackHub(_ => LoopbackHub.Raw(304, [], ("ETag", "\"tag1\"")));
        using var client = new HubClient();
        Assert.IsNull(await client.SnapshotAsync(hub.Address, null, null, "\"tag1\""));
        Assert.IsTrue(hub.Received.TryDequeue(out var seen));
        Assert.AreEqual("/ui/mobile", seen.Target);
        Assert.IsNull(seen.Header("Authorization"));
    }

    [TestMethod]
    public async Task ARedirectIsNeverFollowed()
    {
        using var hub = new LoopbackHub(_ => LoopbackHub.Json(302, "{}", ("Location", "http://127.0.0.1:9/ui/mobile")));
        using var client = new HubClient();
        var e = Expect.Hub(() => client.SnapshotAsync(hub.Address, "k", "gen", null));
        Assert.AreEqual((HubErrorKind.Refusal, 302), (e.Kind, e.Status));
        await Task.Delay(100);
        Assert.AreEqual(1, hub.Received.Count);
    }

    [TestMethod]
    public void ARefusalCarriesTheHubsWordsAndItsAuth()
    {
        using var hub = new LoopbackHub(seen => seen.Target.StartsWith("/ui/mobile/chat")
            ? LoopbackHub.Json(403, """{"error":"this is not pc's device key","auth":"device_key_mismatch"}""")
            : LoopbackHub.Json(422, """{"error":"text matches a registered login"}"""));
        using var client = new HubClient();
        var key = Expect.Hub(() => client.ChatAsync(hub.Address, "k", "gen", "manager"));
        Assert.AreEqual(("device_key_mismatch", 403), (key.Auth, key.Status));
        Assert.IsTrue(key.IsDefinitive);
        StringAssert.Contains(key.Message, "Add this phone again");
        var text = Expect.Hub(() => client.TaskAsync(hub.Address, "k", "gen", 3));
        Assert.AreEqual("Not sent: Text matches a registered login.", text.NotSentWords);
    }

    [TestMethod]
    public void AHubWithoutThePhonesRoutesAndAHubThatIsNotThereAreTheirOwnErrors()
    {
        using var old = new LoopbackHub(_ => LoopbackHub.Json(404, """{"error":"not found"}"""));
        using var client = new HubClient();
        Assert.AreEqual(HubErrorKind.NoPhoneRoutes, Expect.Hub(() => client.SnapshotAsync(old.Address, "k", "gen", null)).Kind);
        var closed = new TcpListener(IPAddress.Loopback, 0);
        closed.Start();
        var port = ((IPEndPoint)closed.LocalEndpoint).Port;
        closed.Stop();
        var gone = Expect.Hub(() => client.SnapshotAsync(new Uri($"http://127.0.0.1:{port}/"), "k", "gen", null));
        Assert.AreEqual(HubErrorKind.NoAnswer, gone.Kind);
        Assert.IsFalse(gone.IsDefinitive);
    }

    [TestMethod]
    public void AHubThatDoesNotAnswerInTimeIsNoAnswer()
    {
        using var hub = new LoopbackHub(_ => null);
        using var client = new HubClient(new HubClientOptions { RequestTimeout = TimeSpan.FromMilliseconds(300) });
        Assert.AreEqual(HubErrorKind.NoAnswer, Expect.Hub(() => client.DevicesAsync(hub.Address, "k", "gen")).Kind);
    }

    [TestMethod]
    public void AnAnswerOverItsCapIsNeverReadWhole()
    {
        var large = "{\"db\":\"gen\",\"devices\":[],\"x\":\"" + new string('a', HubDecode.DevicesLimit) + "\"}";
        using var hub = new LoopbackHub(_ => LoopbackHub.Json(200, large));
        using var client = new HubClient();
        Assert.AreEqual(HubErrorKind.InvalidResponse, Expect.Hub(() => client.DevicesAsync(hub.Address, "k", "gen")).Kind);
    }

    [TestMethod]
    public async Task TheWaitAsksFromTheTokenAndAnotherGenerationIsAnAnswer()
    {
        using var hub = new LoopbackHub(seen => seen.Target.Contains("db=old")
            ? LoopbackHub.Json(409, """{"error":"hub generation changed; refresh state"}""")
            : LoopbackHub.Json(200, """{"db":"gen","token":"b.6.2"}"""));
        using var client = new HubClient();
        var answer = await client.WaitAsync(hub.Address, "k", "gen", LiveToken.Parse("b.5.1")!, 99);
        Assert.AreEqual("b.6.2", answer.Token!.Text);
        Assert.IsTrue(hub.Received.TryDequeue(out var seen));
        Assert.AreEqual("/ui/wait?db=gen&since=b.5.1&wait=20", seen.Target);
        Assert.IsTrue((await client.WaitAsync(hub.Address, "k", "old", LiveToken.Parse("b.5.1")!)).IsGenerationChanged);
    }

    [TestMethod]
    public async Task AWriteCarriesItsClientItsNumberAndItsBodyAndTakesOnlyItsOwnReceipt()
    {
        PendingRequest? sent = null;
        using var hub = new LoopbackHub(seen =>
        {
            var body = JsonDocument.Parse(seen.Body).RootElement;
            var id = body.GetProperty("request_id").GetString();
            return LoopbackHub.Json(200, $$"""{"ok":true,"request_id":"{{id}}","event_id":4,"created":2.0,"replayed":false,"client":"pc","recipient":"vps","read_at":null}""");
        });
        using var client = new HubClient();
        sent = PendingRequest.New(hub.Address, "gen", "pc", "hello", recipient: "vps");
        var receipt = await client.SendAsync(sent, "k");
        Assert.AreEqual(4, receipt.EventId);
        Assert.IsTrue(hub.Received.TryDequeue(out var seen));
        Assert.AreEqual("POST /ui/messages", seen.Method + " " + seen.Target);
        Assert.AreEqual("pc", seen.Header("X-Fleet-Client"));
        Assert.AreEqual(sent.RequestIdText, seen.Header("X-Fleet-Request-Id"));
        Assert.AreEqual("application/json", seen.Header("Content-Type"));
        Assert.AreEqual("hello", JsonDocument.Parse(seen.Body).RootElement.GetProperty("text").GetString());
        // A receipt of another recipient is no receipt of this message.
        var other = PendingRequest.New(hub.Address, "gen", "pc", "hello", recipient: "manager");
        Assert.AreEqual(HubErrorKind.InvalidResponse, Expect.Hub(() => client.SendAsync(other, "k")).Kind);
        Expect.Hub(() => client.CommandAsync(sent, "k"));
    }

    [TestMethod]
    public async Task EnrollmentSendsTheCodeAloneWithNoKey()
    {
        using var hub = new LoopbackHub(_ => LoopbackHub.Json(200, """{"device":"pc","label":"PC","key":"new-key","since":1.0}"""));
        using var client = new HubClient();
        var enrolled = await client.EnrollAsync(hub.Address, "abcd-efgh", signing: ("K", "B"), recovery: ("R", "RB"));
        Assert.AreEqual("new-key", enrolled.Key);
        Assert.IsTrue(hub.Received.TryDequeue(out var seen));
        Assert.IsNull(seen.Header("Authorization"));
        var body = JsonDocument.Parse(seen.Body).RootElement;
        Assert.AreEqual("ABCDEFGH", body.GetProperty("code").GetString());
        Assert.AreEqual("RB", body.GetProperty("recovery_binding").GetString());
        Assert.AreEqual(HubErrorKind.InvalidResponse, Expect.Hub(() => client.EnrollAsync(hub.Address, "ABCD-EFG1")).Kind);
        Assert.IsNull(HubClient.NormalizedCode("ABCD-EFGO"));
        Assert.AreEqual("ABCDEFGH", HubClient.NormalizedCode(" abcd efgh "));
    }

    [TestMethod]
    public void AnAddressIsAHubAndNothingElse()
    {
        Assert.AreEqual("http://192.0.2.10:8765/", HubClient.Address(" http://192.0.2.10:8765 ").ToString());
        Assert.AreEqual("https://hub.example.com/", HubClient.Address("https://hub.example.com/").ToString());
        foreach (var bad in new[] { "ftp://hub.example.com", "http://user:pass@hub.example.com", "http://hub.example.com/x",
                                    "http://hub.example.com/?a=1", "http://hub.example.com/#x", "hub.example.com", "" })
            Assert.AreEqual(HubErrorKind.InvalidAddress, Expect.Hub(() => HubClient.Address(bad)).Kind, bad);
    }

    [TestMethod]
    public void TheHandlerIsTheMacsHardenedSession()
    {
        using var handler = HubClient.NewHandler(new HubClientOptions());
        Assert.IsFalse(handler.AllowAutoRedirect);
        Assert.AreEqual(DecompressionMethods.GZip, handler.AutomaticDecompression);
        Assert.IsFalse(handler.UseCookies);
        Assert.IsFalse(handler.UseProxy);
        Assert.AreEqual(TimeSpan.FromSeconds(10), handler.ConnectTimeout);
        var options = new HubClientOptions();
        Assert.AreEqual((15, 40, 90), ((int)options.RequestTimeout.TotalSeconds, (int)options.WaitTimeout.TotalSeconds,
                                       (int)options.KnowledgeTimeout.TotalSeconds));
    }

    [TestMethod]
    public void TheChatAndTaskReadsRefuseANameOrANumberThatIsNoneBeforeAnythingGoes()
    {
        using var hub = new LoopbackHub(_ => LoopbackHub.Json(500, "{}"));
        using var client = new HubClient();
        Expect.Hub(() => client.ChatAsync(hub.Address, "k", "gen", "../state"));
        Expect.Hub(() => client.TaskAsync(hub.Address, "k", "gen", 0));
        Assert.AreEqual(0, hub.Received.Count);
    }
}
