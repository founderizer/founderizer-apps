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
/// <c>CloudServersTests.aCreateWithNoSureAnswerReadsItsOwnMarkBeforeAnythingIsTakenBack</c>), and neither is a success
/// with no id that this app reads (the Mac's <c>aSuccessWithNoIDReadsItsOwnMarkBeforeAnythingIsTakenBack</c>): the rules
/// that no case of <c>cloud-requests.json</c> holds, each on a case of that file with some answers changed. The vector
/// cases hold the rest: the read by the call's own mark and name at each provider, the end that is not known, the
/// success with no id, the locked deletion, a gateway's page, and a Linode that does not go and is read for again.</summary>
[TestClass]
public sealed class CloudFaultTests
{
    private static readonly JsonElement File = Vectors.Read("cloud-requests.json");
    private const string HetznerFault = "Hetzner: a fault answer to the server: the server behind the call's firewall goes, then the firewall";
    private const string HetznerNoId = "Hetzner: a success with no id to the server: the server of its name behind the call's firewall goes, then the firewall";
    private const string OceanFault = "DigitalOcean: a 502 to the droplet: the droplet with the call's tag goes";
    private const string AkamaiStays = "Akamai: a Linode found that does not go keeps its firewall";
    private const string VultrFault = "Vultr: a 504 to the instance: the one behind the call's own group goes, with the group";

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

    /// <summary>**Two servers of the call's name with its mark are not the call's alone: nothing goes, now or in the hour
    /// of reads after it.** At DigitalOcean, where two droplets can have one name and a person can give a droplet any tag.
    /// Bug: a fault answer that deletes the first of two droplets of the call's name with its tag, one of which a person
    /// made.</summary>
    [TestMethod]
    public async Task Two_servers_with_the_calls_mark_are_never_deleted()
    {
        var stand = Stand(Case(OceanFault),
                          ("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\"},{\"id\":3164445,\"name\":\"hub-1\"}]}"));
        var error = await MakeAsync(Case(OceanFault), stand);
        Assert.AreEqual((CloudFailure.Unsure, "502 Bad Gateway", "hub-1"), (error.Failure, error.Says, error.Server));
        Assert.IsTrue(CloudServers.IsFirewallName(error.Mark!, "hub-1", CloudProvider.DigitalOcean), error.Mark);
        StringAssert.Contains(error.Message, $" with the tag {error.Mark} at DigitalOcean ");
        CollectionAssert.AreEqual(Array.Empty<string>(), Deleted(stand));
        Assert.AreEqual(1 + CloudServers.FollowReads, stand.Calls.Count(c => c.Method == "GET" && c.Url.AbsolutePath == "/v2/droplets"));
    }

    /// <summary>**A server of another name behind the call's mark is never deleted, now or in the hour of reads after it,
    /// at Hetzner, Akamai and Vultr, and neither is one after a failed read of Hetzner's names** (the Mac's
    /// <c>aServerOfAnotherNameBehindTheCallsMarkIsNeverDeleted</c>): a person's own server alone behind the call's new
    /// firewall is not the call's, and the end is not known. Hetzner's firewall names its servers by id only. Bugs: a
    /// mark read that keeps the firewall's ids when the read of the names fails or finds no server of that name; a label
    /// compared only when more than one server carries the mark.</summary>
    [TestMethod]
    public async Task A_server_of_another_name_behind_the_calls_mark_is_never_deleted_nor_after_a_failed_read_of_the_names()
    {
        const string alone = "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\",\"server\":{\"id\":1002}}]}}";
        async Task<StandIn> StaysAsync(string name, string says, params (string Method, string Path, int Status, string Body)[] instead)
        {
            var stand = Stand(Case(name), instead);
            var error = await MakeAsync(Case(name), stand);
            Assert.AreEqual((CloudFailure.Unsure, says, "hub-1"), (error.Failure, error.Says, error.Server), name);
            CollectionAssert.AreEqual(Array.Empty<string>(), Deleted(stand), name);
            return stand;
        }
        await StaysAsync(HetznerFault, "service unavailable", ("GET", "/v1/firewalls/77", 200, alone), ("GET", "/v1/servers", 200, "{\"servers\":[]}"));
        var blind = await StaysAsync(HetznerFault, "service unavailable", ("GET", "/v1/firewalls/77", 200, alone),
                                     ("GET", "/v1/servers", 503, "{\"error\":{\"code\":\"unavailable\",\"message\":\"service unavailable\"}}"));
        Assert.AreEqual(1 + CloudServers.FollowReads, blind.Calls.Count(c => c.Method == "GET" && c.Url.AbsolutePath == "/v1/servers"));
        await StaysAsync(AkamaiStays, "Please try again", ("GET", "/v4/networking/firewalls/88712/devices", 200,
                         "{\"data\":[{\"entity\":{\"id\":4242,\"type\":\"linode\",\"label\":\"shop\"}}]}"));
        await StaysAsync(VultrFault, "Gateway Timeout", ("GET", "/v2/instances", 200,
                         "{\"instances\":[{\"id\":\"shop\",\"label\":\"shop\",\"firewall_group_id\":\"1234abcd-5678-4ef0-9abc-def012345678\"}]}"));
    }

    /// <summary>**A server that the mark read found, after a fault answer or after a success with no id, and whose deletion
    /// ends in an error stays, keeps its firewall, is said as the answer was, never as deleted, and is read for and asked
    /// to go again in the hour after; once it goes there, its firewall goes after it** (the Mac's undo; the PC readers'
    /// point 5 of 26 November 2026). Bugs: Hetzner's deletion action that fails, read as a deletion, and the firewall then
    /// deleted in front of a server that runs; the found server said in the words "so this app deleted hub-1"; no reads
    /// after it, so that it runs on at the owner's cost; reads that delete it and leave its firewall.</summary>
    [TestMethod]
    public async Task A_found_server_that_does_not_go_keeps_its_firewall_and_the_providers_words()
    {
        const string failed = "{\"action\":{\"id\":601,\"status\":\"error\",\"error\":{\"code\":\"action_failed\",\"message\":\"not deleted\"}}}";
        var each = Enumerable.Repeat("/v1/servers/1001", 1 + CloudServers.FollowReads).ToArray();
        var stand = Stand(Case(HetznerFault), ("GET", "/v1/actions/601", 200, failed));
        var error = await MakeAsync(Case(HetznerFault), stand);
        Assert.AreEqual(CloudFailure.LeftBehind, error.Failure, error.Message);
        Assert.AreEqual(new CloudException(CloudFailure.Refused, CloudProvider.Hetzner, "service unavailable").Message, error.Says);
        Assert.AreEqual(2, error.Left.Count);
        Assert.AreEqual("the server hub-1", error.Left[0]);
        StringAssert.StartsWith(error.Left[1], "the firewall founderizer-hub-1-");
        CollectionAssert.AreEqual(each, Deleted(stand));
        // After a success with no id: in the words of an answer that this app does not understand.
        var unread = Stand(Case(HetznerNoId), ("GET", "/v1/actions/601", 200, failed));
        var left = await MakeAsync(Case(HetznerNoId), unread);
        Assert.AreEqual((CloudFailure.LeftBehind, new CloudException(CloudFailure.NotUnderstood, CloudProvider.Hetzner).Message, 2),
                        (left.Failure, left.Says, left.Left.Count), left.Message);
        CollectionAssert.AreEqual(each, Deleted(unread));
        // Hetzner keeps it locked past the asks (the Mac's "slow" case): the read after them deletes it, then its firewall.
        var slow = Stand(Case(HetznerNoId),
                         Enumerable.Repeat(("DELETE", "/v1/servers/1001", 423, "{\"error\":{\"code\":\"locked\"}}"), CloudServers.RemoveReads)
            .Append(("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601,\"command\":\"delete_server\",\"status\":\"running\"}}")).ToArray());
        Assert.AreEqual(CloudFailure.LeftBehind, (await MakeAsync(Case(HetznerNoId), slow)).Failure);
        CollectionAssert.AreEqual(Enumerable.Repeat("/v1/servers/1001", 1 + CloudServers.RemoveReads).Append("/v1/firewalls/77").ToArray(), Deleted(slow));
    }

    /// <summary>**A success with no id at Akamai deletes the Linode of the call's mark and name, then its firewall** (the
    /// Mac's <c>aSuccessWithNoIDReadsItsOwnMarkBeforeAnythingIsTakenBack</c>, its Akamai part, which no vector case holds).
    /// Bug: the found Linode kept out of what the call takes back, so that its firewall goes (Akamai deletes a firewall
    /// that a Linode uses) and the Linode runs on with none, at the owner's cost.</summary>
    [TestMethod]
    public async Task A_success_with_no_id_at_Akamai_deletes_the_Linode_of_its_mark_then_its_firewall()
    {
        const string linode = "/v4/linode/instances/54748754", firewall = "/v4/networking/firewalls/88712";
        var stand = Stand(Case(AkamaiStays), ("POST", "/v4/linode/instances", 200, "{\"label\":\"hub-1\"}"), ("DELETE", linode, 200, "{}"),
                          ("DELETE", firewall, 200, "{}"));
        var error = await MakeAsync(Case(AkamaiStays), stand);
        Assert.AreEqual("Akamai made hub-1, but this app cannot read its answer, so this app deleted hub-1.", error.Message);
        Assert.AreEqual((CloudFailure.UnreadTakenBack, "hub-1"), (error.Failure, error.Server));
        CollectionAssert.AreEqual(new[] { linode, firewall }, Deleted(stand));
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
                          ("GET", devices, 200, "{\"data\":[{\"entity\":{\"id\":54748754,\"type\":\"linode\",\"label\":\"hub-1\"}}]}"),
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
    /// the read of the call's mark, both of its reads at Hetzner, is not cut short by the stop; the server of the call's
    /// name that the provider made all the same goes with its firewall, and the server of another name behind that
    /// firewall stays. Bugs: a stop that takes the firewall back and leaves the server, which the provider made, with none
    /// and with no record; a read of the names that the stop cuts short.</summary>
    [TestMethod]
    public async Task A_stop_while_the_call_for_the_server_is_on_its_way_reads_the_mark_first()
    {
        var stand = Stand(Case(HetznerFault));
        using var stop = new CancellationTokenSource();
        using var handler = new StopsOnTheWay(stand, stop, "/v1/servers");
        var error = await MakeAsync(Case(HetznerFault), handler, stop.Token);
        Assert.AreEqual((CloudFailure.TakenBack, (string?)null, "hub-1"), (error.Failure, error.Says, error.Server));
        Assert.AreEqual("Hetzner did not answer the call that makes hub-1, but it had made it all the same, so this app deleted it.", error.Message);
        Assert.AreEqual("?name=hub-1", stand.Calls.Single(c => c.Method == "GET" && c.Url.AbsolutePath == "/v1/servers").Url.Query);
        CollectionAssert.AreEqual(new[] { "/v1/servers/1001", "/v1/firewalls/77" }, Deleted(stand));
    }

    /// <summary>**A droplet that this app made carries in the account's list what this app made it for, by its tag**, as
    /// at Vultr and Akamai, for the Mac's rule that makes it no server to choose (<c>CloudExisting.unfit</c>, which the PC
    /// takes with pieces L3 and L4). Bug: DigitalOcean's list that reads no tag, so that rule would offer a stray droplet
    /// of an unsure end.</summary>
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

    /// <summary>**The build's record keeps the name of a server that may be at the provider**: an end that is not known,
    /// after a fault answer or after a success with no id, leaves the name in use for the hour, and a server that this app
    /// took back frees it. Bug: an unsure or unread end read as a refusal, whose name a retry takes, and whose join then
    /// installs onto the stray server.</summary>
    [TestMethod]
    public void An_unsure_end_keeps_the_name_in_use_and_a_server_taken_back_frees_it()
    {
        var unsure = new CloudException(CloudFailure.Unsure, CloudProvider.Hetzner, "service unavailable", null, "worker-3", "founderizer-worker-3-k3j9x2");
        var back = new CloudException(CloudFailure.TakenBack, CloudProvider.Hetzner, "service unavailable", null, "worker-4");
        var unread = new CloudException(CloudFailure.Unread, CloudProvider.Hetzner, null, null, "worker-5", "founderizer-worker-5-k3j9x2");
        var unreadBack = new CloudException(CloudFailure.UnreadTakenBack, CloudProvider.Hetzner, null, null, "worker-6");
        Assert.AreEqual((AtProvider.NotKnown, AtProvider.Nothing, AtProvider.NotKnown, AtProvider.Nothing),
                        (CloudStep.After(unsure), CloudStep.After(back), CloudStep.After(unread), CloudStep.After(unreadBack)));
        var at = new DateTimeOffset(2026, 11, 26, 9, 0, 0, TimeSpan.Zero);
        var records = new[] { (unsure, "worker-3"), (back, "worker-4"), (unread, "worker-5"), (unreadBack, "worker-6") }
            .Select(e => BuildRecord.Begin("hetzner", "agent", null, e.Item2, "l", at).CallEnded(CloudStep.After(e.Item1)).End(at.AddMinutes(1)))
            .ToArray();
        CollectionAssert.AreEqual(new[] { "worker-3", "worker-5" }, BuildRecord.NamesInUse(records, at.AddMinutes(5), TimeSpan.FromHours(1)).ToArray());
    }
}
