using System;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**A provider's own fault answer (a 5xx), or no answer, to the call that makes a server is not "nothing
/// there"** (finding 3 of the checked audit of 24 November 2026; the Mac's
/// <c>CloudServersTests.aCreateWithNoSureAnswerReadsItsOwnMarkBeforeAnythingIsTakenBack</c>): the rules that no case of
/// <c>cloud-requests.json</c> holds, each on a case of that file with some answers changed. The vector cases hold the
/// rest: the read by the call's own mark at each provider, the end that is not known, the locked deletion, a gateway's
/// page, and a Linode that does not go.</summary>
[TestClass]
public sealed class CloudFaultTests
{
    private static readonly JsonElement File = Vectors.Read("cloud-requests.json");
    private const string HetznerFault = "Hetzner: a fault answer to the server: the server behind the call's firewall goes, then the firewall";
    private const string AkamaiStays = "Akamai: a Linode found that does not go keeps its firewall";

    private static JsonElement Case(string name) =>
        File.GetProperty("cases").EnumerateArray().Single(c => c.GetProperty("name").GetString() == name);

    /// <summary>The stand-in of a vector's case, with the answers of each method and path of <paramref name="instead"/> in
    /// place of the case's own.</summary>
    private static StandIn Stand(JsonElement one, params (string Method, string Path, int Status, string Body)[] instead)
    {
        var stand = new StandIn();
        var replaced = instead.Select(i => i.Method + " " + i.Path).ToHashSet(StringComparer.Ordinal);
        foreach (var a in one.GetProperty("answers").EnumerateArray())
        {
            var (method, path) = (a.GetProperty("method").GetString()!, a.GetProperty("path").GetString()!);
            if (!replaced.Contains(method + " " + path)) stand.Add(method, path, a.GetProperty("status").GetInt32(), a.GetProperty("body").GetString()!);
        }
        foreach (var (method, path, status, body) in instead) stand.Add(method, path, status, body);
        return stand;
    }

    private static ICloud Cloud(JsonElement one, HttpMessageHandler handler, Follows follows)
    {
        var provider = CloudProviders.FromRaw(one.GetProperty("provider").GetString()!)!.Value;
        var box = new MemorySecretBox();
        box.Write(provider.BoxName(), Encoding.UTF8.GetBytes(one.GetProperty("held").GetString()!));
        return CloudServers.For(provider, handler, box, TimeSpan.FromHours(File.GetProperty("zone_hours").GetDouble()), (_, _) => Task.CompletedTask,
                                follows.Follow);
    }

    /// <summary>The case's server, made with the case's keys: the error it ends with, once the reads after it ended.</summary>
    private static async Task<CloudException> MakeAsync(JsonElement one, HttpMessageHandler handler, CancellationToken cancel = default)
    {
        var follows = new Follows();
        var call = one.GetProperty("call");
        var order = new CloudOrder(call.GetProperty("name").GetString()!, CloudServerUse.Hub, call.GetProperty("public_key").GetString()!,
                                   call.GetProperty("auth_key").GetString()!);
        var error = await Assert.ThrowsExactlyAsync<CloudException>(() => Cloud(one, handler, follows).MakeAsync(order, cancel));
        await follows.DoneAsync();
        return error;
    }

    private static string[] Deleted(StandIn stand) => stand.Calls.Where(c => c.Method == "DELETE").Select(c => c.Url.AbsolutePath).ToArray();

    /// <summary>**Two servers with the call's mark are not the call's alone: nothing goes, now or in the hour of reads
    /// after it.** Bug: a fault answer that deletes the first of two servers behind the call's firewall, one of which a
    /// person put there.</summary>
    [TestMethod]
    public async Task Two_servers_with_the_calls_mark_are_never_deleted()
    {
        var stand = Stand(Case(HetznerFault),
                          ("POST", "/v1/servers", 502, "{\"error\":{\"code\":\"unavailable\",\"message\":\"bad gateway\"}}"),
                          ("GET", "/v1/firewalls/77", 200,
                           "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\",\"server\":{\"id\":1001}},{\"type\":\"server\",\"server\":{\"id\":1002}}]}}"));
        var error = await MakeAsync(Case(HetznerFault), stand);
        Assert.AreEqual((CloudFailure.Unsure, "bad gateway", "hub-1"), (error.Failure, error.Says, error.Server));
        Assert.IsTrue(CloudServers.IsFirewallName(error.Mark!, "hub-1", CloudProvider.Hetzner), error.Mark);
        StringAssert.Contains(error.Message, $" behind the firewall {error.Mark} at Hetzner ");
        CollectionAssert.AreEqual(Array.Empty<string>(), Deleted(stand));
        Assert.AreEqual(1 + CloudServers.FollowReads, stand.Calls.Count(c => c.Method == "GET" && c.Url.AbsolutePath == "/v1/firewalls/77"));
    }

    /// <summary>**A server found after a fault answer whose deletion ends in an error stays, keeps its firewall, and is said
    /// in the provider's words, never as deleted.** Bug: Hetzner's deletion action that fails, read as a deletion, and the
    /// firewall then deleted in front of a server that runs.</summary>
    [TestMethod]
    public async Task A_found_server_that_does_not_go_keeps_its_firewall_and_the_providers_words()
    {
        var stand = Stand(Case(HetznerFault),
                          ("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"error\",\"error\":{\"code\":\"action_failed\",\"message\":\"not deleted\"}}}"));
        var error = await MakeAsync(Case(HetznerFault), stand);
        Assert.AreEqual(CloudFailure.LeftBehind, error.Failure, error.Message);
        Assert.AreEqual(new CloudException(CloudFailure.Refused, CloudProvider.Hetzner, "service unavailable").Message, error.Says);
        Assert.AreEqual(2, error.Left.Count);
        Assert.AreEqual("the server hub-1", error.Left[0]);
        StringAssert.StartsWith(error.Left[1], "the firewall founderizer-hub-1-");
        CollectionAssert.AreEqual(new[] { "/v1/servers/1001" }, Deleted(stand));
    }

    /// <summary>**A server that comes after an end that is not known, and that does not go at the first deletion, is asked
    /// again in the reads that follow until it goes, then its firewall.** Bug: the reads that stop after one deletion that
    /// failed, and leave a server running at the owner's cost with no record that finds it.</summary>
    [TestMethod]
    public async Task The_reads_after_an_unsure_end_go_on_while_the_server_stays()
    {
        const string linode = "/v4/linode/instances/54748754", devices = "/v4/networking/firewalls/88712/devices";
        var stand = Stand(Case(AkamaiStays),
                          ("GET", devices, 200, "{\"data\":[]}"),
                          ("GET", devices, 200, "{\"data\":[{\"entity\":{\"id\":54748754,\"type\":\"linode\"}}]}"),
                          ("DELETE", linode, 500, "{\"errors\":[{\"reason\":\"busy\"}]}"),
                          ("DELETE", linode, 200, "{}"),
                          ("DELETE", "/v4/networking/firewalls/88712", 200, "{}"));
        var error = await MakeAsync(Case(AkamaiStays), stand);
        Assert.AreEqual((CloudFailure.Unsure, "Please try again"), (error.Failure, error.Says));
        StringAssert.Contains(error.Message, $" behind the firewall {error.Mark} at Akamai ");
        CollectionAssert.AreEqual(new[] { linode, linode, "/v4/networking/firewalls/88712" }, Deleted(stand));
    }

    /// <summary>A stop of the call while its request is on its way: the request goes, and its answer never comes.</summary>
    private sealed class StopsOnTheWay(StandIn stand, CancellationTokenSource stop, string path) : DelegatingHandler(stand)
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.Method != HttpMethod.Post || request.RequestUri!.AbsolutePath != path) return await base.SendAsync(request, cancellationToken);
            await stop.CancelAsync();
            await Task.Delay(Timeout.Infinite, cancellationToken);
            throw new InvalidOperationException("no answer");
        }
    }

    /// <summary>**A stop of the call for the server while it is on its way is a call with no answer** (the Mac's Back):
    /// the read of the call's mark is not cut short by the stop, and the server that the provider made all the same goes
    /// with its firewall. Bug: a stop that takes the firewall back and leaves the server, which the provider made, with none
    /// and with no record.</summary>
    [TestMethod]
    public async Task A_stop_while_the_call_for_the_server_is_on_its_way_reads_the_mark_first()
    {
        var stand = Stand(Case(HetznerFault));
        using var stop = new CancellationTokenSource();
        using var handler = new StopsOnTheWay(stand, stop, "/v1/servers");
        var error = await MakeAsync(Case(HetznerFault), handler, stop.Token);
        Assert.AreEqual((CloudFailure.TakenBack, (string?)null, "hub-1"), (error.Failure, error.Says, error.Server));
        Assert.AreEqual("Hetzner did not answer the call that makes hub-1, but it had made it all the same, so this app deleted it.", error.Message);
        CollectionAssert.AreEqual(new[] { "/v1/servers/1001", "/v1/firewalls/77" }, Deleted(stand));
    }

    /// <summary>**A droplet that this app made shows in the account's list as this app's, by its tag**, as at Vultr and
    /// Akamai, so a stray droplet of an unsure end is no server to choose. Bug: DigitalOcean's list that reads no tag.</summary>
    [TestMethod]
    public async Task A_droplet_with_this_apps_tag_is_listed_as_this_apps()
    {
        var stand = new StandIn();
        stand.Add("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\",\"tags\":[\"founderizer-hub\",\"founderizer-hub-1-k3j9x2\"]}," +
                                             "{\"id\":31,\"name\":\"api\",\"tags\":[\"web\"]}]}");
        var box = new MemorySecretBox();
        box.Write(CloudProvider.DigitalOcean.BoxName(), Encoding.UTF8.GetBytes("notarealtoken0123456789"));
        var listed = await CloudServers.For(CloudProvider.DigitalOcean, stand, box, TimeSpan.Zero).ServersAsync();
        CollectionAssert.AreEqual(new[] { "hub", null }, listed.Select(e => e.MadeFor).ToArray());
    }

    /// <summary>**The build's record keeps the name of a server that may be at the provider**: an end that is not known
    /// leaves the name in use for the hour, and a server that this app took back frees it. Bug: an unsure end read as a
    /// refusal, whose name a retry takes, and whose join then installs onto the stray server.</summary>
    [TestMethod]
    public void An_unsure_end_keeps_the_name_in_use_and_a_server_taken_back_frees_it()
    {
        var unsure = new CloudException(CloudFailure.Unsure, CloudProvider.Hetzner, "service unavailable", null, "worker-3", "founderizer-worker-3-k3j9x2");
        var back = new CloudException(CloudFailure.TakenBack, CloudProvider.Hetzner, "service unavailable", null, "worker-4");
        Assert.AreEqual((AtProvider.NotKnown, AtProvider.Nothing), (CloudStep.After(unsure), CloudStep.After(back)));
        var at = new DateTimeOffset(2026, 11, 26, 9, 0, 0, TimeSpan.Zero);
        var records = new[]
        {
            BuildRecord.Begin("hetzner", "agent", null, "worker-3", "l", at).CallEnded(CloudStep.After(unsure)).End(at.AddMinutes(1)),
            BuildRecord.Begin("hetzner", "agent", null, "worker-4", "l", at).CallEnded(CloudStep.After(back)).End(at.AddMinutes(1)),
        };
        CollectionAssert.AreEqual(new[] { "worker-3" }, BuildRecord.NamesInUse(records, at.AddMinutes(5), TimeSpan.FromHours(1)).ToArray());
    }
}
