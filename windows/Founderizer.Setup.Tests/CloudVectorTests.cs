using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.Network;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**Each cloud provider's API as the PC calls it is the Mac's, request for request**
/// (app/vectors/cloud-requests.json, which FleetCore's own code writes; windows-app-plan-v2.md, piece L2), at a PC in
/// Berlin's time zone. A wrong field makes a server with no key, a server outside its firewall, or a server that never
/// joins the network; a wrong reading offers a server the owner cannot have, or leaves one running at his cost. Beside
/// the cases the pure rules: the first boot, the nearest places, a pasted token, this app's key, the names and the words.</summary>
[TestClass]
public sealed class CloudVectorTests
{
    private static readonly JsonElement File = Vectors.Read("cloud-requests.json");

    private static async Task<(JsonNode? Result, Exception? Error)> Run(ICloud cloud, CloudProvider provider, JsonElement call)
    {
        try
        {
            switch (call.GetProperty("do").GetString())
            {
                case "check_token":
                    await cloud.CheckTokenAsync(call.GetProperty("token").GetString()!);
                    return ("kept", null);
                case "offers":
                    var except = call.GetProperty("except").EnumerateArray().Select(e => e.GetString()!).ToHashSet();
                    var offers = await cloud.OffersAsync(Use(call), except);
                    return (new JsonArray(offers.Select(o => (JsonNode?)Offer(o)).ToArray()), null);
                case "make":
                    var offer = call.GetProperty("offer");
                    var chosen = offer.ValueKind == JsonValueKind.Null ? null : new CloudOffer(
                        provider, offer.GetProperty("type").GetString()!, offer.GetProperty("location").GetString()!,
                        offer.GetProperty("cores").ValueKind == JsonValueKind.Null ? null : offer.GetProperty("cores").GetInt32(),
                        offer.GetProperty("memory_gb").ValueKind == JsonValueKind.Null ? null : offer.GetProperty("memory_gb").GetDouble(),
                        offer.GetProperty("disk_gb").ValueKind == JsonValueKind.Null ? null : offer.GetProperty("disk_gb").GetInt32(),
                        decimal.Parse(offer.GetProperty("price").GetString()!, CultureInfo.InvariantCulture),
                        offer.GetProperty("currency").GetString()!, offer.GetProperty("dedicated").GetBoolean());
                    var server = await cloud.MakeAsync(new CloudOrder(call.GetProperty("name").GetString()!, Use(call),
                                                                      call.GetProperty("public_key").GetString()!,
                                                                      call.GetProperty("auth_key").GetString()!, chosen));
                    return (new JsonObject
                    {
                        ["id"] = server.Id, ["name"] = server.Name, ["ipv4"] = server.Ipv4, ["type"] = server.Type,
                        ["location"] = server.Location, ["price"] = server.MonthlyPrice.ToString(CultureInfo.InvariantCulture),
                        ["currency"] = server.Currency, ["firewall_id"] = server.FirewallId,
                    }, null);
                case "servers":
                    return (new JsonArray((await cloud.ServersAsync()).Select(e => (JsonNode?)new JsonObject
                    {
                        ["id"] = e.Id, ["name"] = e.Name, ["ipv4"] = e.Ipv4, ["type"] = e.Type, ["memory_mb"] = e.MemoryMb,
                        ["system"] = e.System, ["version"] = e.Version, ["place"] = e.Place, ["running"] = e.Running,
                        ["project"] = e.Project, ["made_for"] = e.MadeFor, ["summary"] = e.Summary,
                    }).ToArray()), null);
                case "delete_server":
                    var accepted = false;
                    var deletion = await cloud.DeleteAsync(call.GetProperty("id").GetString()!, () => accepted = true);
                    var deleted = new JsonObject { ["deleted"] = deletion.Deleted, ["accepted"] = accepted };
                    if (deletion.NotThere is { } notThere) deleted["not_there"] = Error(notThere);
                    return (deleted, null);
                case "firewalls":
                    return (new JsonArray((await cloud.FirewallsAsync(call.GetProperty("name").GetString()!)).Select(f => (JsonNode?)new JsonObject
                    {
                        ["id"] = f.Id, ["servers"] = Same.Strings(f.Servers), ["other"] = f.Other,
                    }).ToArray()), null);
                case "delete_firewalls":
                    await cloud.DeleteFirewallsAsync(call.GetProperty("name").GetString()!,
                                                     call.GetProperty("deleted").EnumerateArray().Select(d => d.GetString()!).ToHashSet());
                    return ("done", null);
                case "delete_key":
                    await cloud.DeleteKeyAsync(call.GetProperty("public_key").GetString()!);
                    return ("done", null);
                default:
                    throw new InvalidOperationException("no such call");
            }
        }
        catch (CloudException e) { return (null, e); }
        catch (FleetKeyException e) { return (null, e); }
    }

    private static CloudServerUse Use(JsonElement call) => call.GetProperty("use").GetString() == "hub" ? CloudServerUse.Hub : CloudServerUse.Agent;

    private static JsonObject Offer(CloudOffer o) => new()
    {
        ["type"] = o.Type, ["location"] = o.Location, ["price"] = o.MonthlyPrice.ToString(CultureInfo.InvariantCulture),
        ["currency"] = o.Currency, ["cores"] = o.Cores, ["memory_gb"] = o.MemoryGb, ["disk_gb"] = o.DiskGb, ["dedicated"] = o.Dedicated,
        ["key"] = o.Key, ["kind"] = o.Kind, ["size"] = o.Size, ["choice"] = o.Choice, ["place"] = o.Place,
    };

    /// <summary>An error as the vectors write one, its words with "PC" turned back to "Mac" only where the Mac's had it.</summary>
    private static JsonObject Error(CloudException e)
    {
        var named = new JsonObject { ["case"] = Same.Snake(e.Failure), ["words"] = e.Message };
        if (e.Failure is CloudFailure.Refused or CloudFailure.LeftBehind or CloudFailure.Unsure or CloudFailure.TakenBack) named["says"] = e.Says;
        if (e.Failure is CloudFailure.Unsure or CloudFailure.TakenBack or CloudFailure.Unread or CloudFailure.UnreadTakenBack) named["server"] = e.Server;
        if (e.Failure is CloudFailure.Unsure or CloudFailure.Unread) named["mark"] = e.Mark;
        if (e.Failure == CloudFailure.LeftBehind) named["left"] = Same.Strings(e.Left);
        return named;
    }

    private static void Cases(string provider)
    {
        var secrets = File.GetProperty("secrets");
        var chance = Same.Chance(File);
        var problems = new List<string>();
        var count = 0;
        foreach (var one in File.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("provider").GetString() == provider))
        {
            var name = one.GetProperty("name").GetString()!;
            var at = CloudProviders.FromRaw(provider)!.Value;
            var stand = StandIn.From(one.GetProperty("answers"));
            var box = new MemorySecretBox();
            if (one.GetProperty("held").ValueKind == JsonValueKind.String)
                box.Write(at.BoxName(), Encoding.UTF8.GetBytes(one.GetProperty("held").GetString()!));
            // The reads that a call starts after it ended are in the case's requests: the case waits for them.
            var follows = new Follows();
            var cloud = CloudServers.For(at, stand, box, TimeSpan.FromHours(File.GetProperty("zone_hours").GetDouble()), (_, _) => Task.CompletedTask,
                                         follows.Follow);
            var (result, error) = Run(cloud, at, one.GetProperty("call")).GetAwaiter().GetResult();
            follows.DoneAsync().GetAwaiter().GetResult();
            Same.Requests(one.GetProperty("requests"), stand.Calls, secrets, chance, problems, name);
            var expected = one.GetProperty("error");
            if (expected.ValueKind == JsonValueKind.Null)
            {
                if (error is not null) problems.Add($"{name}: stopped: {error.Message}");
                else Same.Json(one.GetProperty("result"), Shown(result, secrets, chance), name, problems, onPc: true);
            }
            else
            {
                JsonNode? given = error switch
                {
                    CloudException cloudError => Error(cloudError),
                    FleetKeyException fleet => new JsonObject { ["case"] = Same.Snake(fleet.Failure), ["words"] = fleet.Message },
                    _ => null,
                };
                Same.Json(expected, Shown(given, secrets, chance), name + " (stop)", problems, onPc: true);
            }
            var kept = box.Read(at.BoxName()) is { } value ? Encoding.UTF8.GetString(value) : null;
            var wanted = one.GetProperty("kept").ValueKind == JsonValueKind.Null ? null : one.GetProperty("kept").GetString();
            if (kept != wanted) problems.Add($"{name}: kept {(kept is null ? "nothing" : "a token")}, the vector {(wanted is null ? "nothing" : "a token")}");
            count++;
        }
        Same.None(problems, count);
    }

    private static JsonNode? Shown(JsonNode? node, JsonElement secrets, IReadOnlyList<(string, string)> chance) => node switch
    {
        JsonObject o => new JsonObject(o.Select(m => KeyValuePair.Create(m.Key, Shown(m.Value, secrets, chance)))),
        JsonArray a => new JsonArray(a.Select(v => Shown(v, secrets, chance)).ToArray()),
        JsonValue v when v.GetValueKind() == JsonValueKind.String => Same.Shown(v.GetValue<string>(), secrets, chance),
        _ => node?.DeepClone(),
    };

    [TestMethod]
    public void EachRequestToHetznerIsTheMacsAndSoIsWhatComesOfIt() => Cases("hetzner");

    [TestMethod]
    public void EachRequestToDigitalOceanIsTheMacsAndSoIsWhatComesOfIt() => Cases("digitalocean");

    [TestMethod]
    public void EachRequestToVultrIsTheMacsAndSoIsWhatComesOfIt() => Cases("vultr");

    [TestMethod]
    public void EachRequestToAkamaiIsTheMacsAndSoIsWhatComesOfIt() => Cases("akamai");

    /// <summary>The first boot, the nearest places, a pasted token, this app's key and its fingerprint, the names and ids,
    /// the providers' own names for things, the words of each stop with "PC" for "Mac", and which stop asks for the token
    /// again: each the Mac's.</summary>
    [TestMethod]
    public void TheCloudsRulesAndWordsAreTheMacs()
    {
        var rules = File.GetProperty("rules");
        var problems = new List<string>();
        var count = 0;
        foreach (var data in rules.GetProperty("user_data").EnumerateArray())
        {
            if (CloudServers.UserData(data.GetProperty("auth_key").GetString()!, data.GetProperty("hostname").GetString()!) != data.GetProperty("text").GetString())
                problems.Add("user data of " + data.GetProperty("hostname").GetString());
            count++;
        }
        foreach (var near in rules.GetProperty("near").EnumerateArray())
            foreach (var provider in CloudProviders.All)
            {
                var given = provider.Near(TimeSpan.FromHours(near.GetProperty("hours").GetDouble()));
                Same.Json(near.GetProperty(provider.Raw()), Same.Strings(given), $"near {near.GetProperty("hours")} {provider}", problems);
                count++;
            }
        foreach (var token in rules.GetProperty("tokens").EnumerateArray())
        {
            string? given;
            try { given = CloudProvider.Hetzner.Token(token.GetProperty("pasted").GetString()!); }
            catch (CloudException) { given = null; }
            Same.Json(token.GetProperty("token"), given, "token " + token.GetProperty("pasted").GetString(), problems);
        }
        foreach (var key in rules.GetProperty("public_keys").EnumerateArray())
        {
            var read = SshPublicKey.Of(key.GetProperty("text").GetString()!);
            Same.Json(key, new JsonObject
            {
                ["text"] = key.GetProperty("text").GetString(), ["line"] = read?.Line, ["fingerprint"] = read?.Fingerprint, ["name"] = read?.Name,
            }, "key " + key.GetProperty("text").GetString(), problems);
            count++;
        }
        foreach (var name in rules.GetProperty("names").EnumerateArray())
            if (CloudServers.IsName(name.GetProperty("name").GetString()!) != name.GetProperty("is").GetBoolean()) problems.Add("name " + name);
        foreach (var id in rules.GetProperty("ids").EnumerateArray())
            if (CloudServers.IsId(id.GetProperty("id").GetString()!) != id.GetProperty("is").GetBoolean()) problems.Add("id " + id);
        foreach (var firewall in rules.GetProperty("firewall_names").EnumerateArray())
            if (CloudServers.IsFirewallName(firewall.GetProperty("candidate").GetString()!, firewall.GetProperty("server").GetString()!,
                                            CloudProviders.FromRaw(firewall.GetProperty("provider").GetString()!)!.Value) != firewall.GetProperty("is").GetBoolean())
                problems.Add("firewall name " + firewall);
        foreach (var address in rules.GetProperty("ipv4").EnumerateArray())
            if (CloudServers.IsIpv4(address.GetProperty("address").GetString()!) != address.GetProperty("is").GetBoolean()) problems.Add("ipv4 " + address);
        foreach (var list in rules.GetProperty("public_ipv4").EnumerateArray())
            Same.Json(list.GetProperty("public"), CloudServers.PublicIpv4(list.GetProperty("addresses").EnumerateArray().Select(a => a.GetString()!).ToList()),
                      "public " + list, problems);
        foreach (var named in rules.GetProperty("providers").EnumerateArray())
        {
            var provider = CloudProviders.FromRaw(named.GetProperty("provider").GetString()!)!.Value;
            var errors = new[]
            {
                new CloudException(CloudFailure.NotAToken, provider), new CloudException(CloudFailure.NoToken, provider),
                new CloudException(CloudFailure.TokenNotAccepted, provider), new CloudException(CloudFailure.ReadOnlyToken, provider),
                new CloudException(CloudFailure.RateLimited, provider), new CloudException(CloudFailure.Unreachable, provider),
                new CloudException(CloudFailure.Refused, provider, "an example refusal"),
                new CloudException(CloudFailure.Unsure, provider, "an example fault", null, "worker-3", "founderizer-worker-3-k3j9x2"),
                new CloudException(CloudFailure.Unsure, provider, null, null, "worker-3", "fz-worker-3-k3j9x2"),
                new CloudException(CloudFailure.TakenBack, provider, "an example fault", null, "worker-3"),
                new CloudException(CloudFailure.TakenBack, provider, null, null, "worker-3"),
                new CloudException(CloudFailure.Unread, provider, null, null, "worker-3", "founderizer-worker-3-k3j9x2"),
                new CloudException(CloudFailure.UnreadTakenBack, provider, null, null, "worker-3"),
                new CloudException(CloudFailure.NotUnderstood, provider),
                new CloudException(CloudFailure.NoRoom, provider), new CloudException(CloudFailure.Full, provider),
                new CloudException(CloudFailure.Taken, provider), new CloudException(CloudFailure.NotReady, provider),
                new CloudException(CloudFailure.LeftBehind, provider, "It failed.", ["the server hub-1"]),
                new CloudException(CloudFailure.LeftBehind, provider, "It failed.", ["the server hub-1", "the firewall founderizer-hub-1-abc123"]),
            };
            Same.Json(named, new JsonObject
            {
                ["provider"] = provider.Raw(), ["name"] = provider.Name(), ["api"] = provider.Api(), ["image"] = provider.Image(),
                ["write_probes"] = Same.Strings(provider.WriteProbes()), ["locations"] = Same.Strings(provider.Locations().Select(l => l.Name)),
                ["places"] = new JsonObject(provider.Locations().Select(l => l.Name).Append("xyz")
                    .Select(l => KeyValuePair.Create(l, (JsonNode?)provider.Place(l)))),
                ["server_path"] = provider.ServerPath("1001"), ["firewall_path"] = provider.FirewallPath("77"),
                ["tag_hub"] = CloudServers.Tag(CloudServerUse.Hub), ["tag_agent"] = CloudServers.Tag(CloudServerUse.Agent),
                ["errors"] = Shown(new JsonArray(errors.Select(e => (JsonNode?)Error(e)).ToArray()), File.GetProperty("secrets"), Same.Chance(File)),
            }, "provider " + provider, problems, onPc: true);
            foreach (var e in errors)
                if (e.Message.Contains("Mac", StringComparison.Ordinal)) problems.Add("a word of the Mac: " + e.Message);
            count++;
        }
        Same.Json(rules.GetProperty("sizes"), new JsonObject
        {
            ["hub"] = CloudProviders.DigitalOceanSize(CloudServerUse.Hub), ["agent"] = CloudProviders.DigitalOceanSize(CloudServerUse.Agent),
        }, "sizes", problems);
        var existing = new[]
        {
            new CloudExisting("1", "a", null, "cx23", 4096, "ubuntu", "24.04", null, true, null, null),
            new CloudExisting("2", "b", null, "s-1vcpu-2gb", 1536, "debian", "12", null, true, "Web", null),
            new CloudExisting("3", "c", null, "", 512, "rocky", "9", null, true, null, null),
            new CloudExisting("4", "d", null, "vc2-1c-1gb", null, null, "1", null, true, null, null),
        };
        Same.Json(rules.GetProperty("existing"), new JsonArray(existing.Select(e => (JsonNode?)new JsonObject { ["id"] = e.Id, ["summary"] = e.Summary }).ToArray()),
                  "summaries", problems);
        foreach (var size in rules.GetProperty("megabytes").EnumerateArray())
            if (CloudExisting.Size(size.GetProperty("megabytes").GetInt32()) != size.GetProperty("words").GetString()) problems.Add("size " + size);
        var stops = new Dictionary<string, Exception>
        {
            ["taken"] = new CloudException(CloudFailure.Taken, CloudProvider.Hetzner), ["no_room"] = new CloudException(CloudFailure.NoRoom, CloudProvider.Vultr),
            ["not_ready"] = new CloudException(CloudFailure.NotReady, CloudProvider.Akamai),
            ["rate_limited"] = new CloudException(CloudFailure.RateLimited, CloudProvider.Hetzner),
            ["full"] = new CloudException(CloudFailure.Full, CloudProvider.DigitalOcean),
            ["refused"] = new CloudException(CloudFailure.Refused, CloudProvider.Hetzner, "x"),
            ["token_not_accepted"] = new CloudException(CloudFailure.TokenNotAccepted, CloudProvider.Hetzner),
            ["read_only_token"] = new CloudException(CloudFailure.ReadOnlyToken, CloudProvider.Vultr),
            ["no_token"] = new CloudException(CloudFailure.NoToken, CloudProvider.Akamai),
            ["not_a_token"] = new CloudException(CloudFailure.NotAToken, CloudProvider.Hetzner),
            ["fleet_key_ended"] = new FleetKeyException(FleetKeyFailure.FleetKeyEnded),
            ["no_fleet_key"] = new FleetKeyException(FleetKeyFailure.NoFleetKey),
            ["fleet_unreachable"] = new FleetKeyException(FleetKeyFailure.Unreachable),
        };
        foreach (var stop in rules.GetProperty("stops").EnumerateArray())
        {
            var error = stops[stop.GetProperty("error").GetString()!];
            var called = stop.GetProperty("called").GetBoolean();
            if (CloudStop.ReadsListAgain(error, called) != stop.GetProperty("reads_list_again").GetBoolean() ||
                CloudStop.RefusesToken(error) != stop.GetProperty("refuses_token").GetBoolean()) problems.Add("stop " + stop);
            count++;
        }
        if (CloudJoin.NotJoined("worker-3", CloudProvider.Hetzner) != rules.GetProperty("not_joined").GetString()) problems.Add("not joined");
        Same.Json(rules.GetProperty("constants"), new JsonObject
        {
            ["ubuntu"] = CloudServers.Ubuntu, ["join_key_life"] = CloudJoin.KeyLife, ["wait_reads"] = CloudServers.WaitReads,
            ["remove_reads"] = CloudServers.RemoveReads, ["hub_memory_mb"] = CloudServers.HubMemoryMb,
            ["agent_memory_mb"] = CloudServers.AgentMemoryMb, ["apt_lock_wait"] = CloudServers.AptLockWait,
            ["follow_reads"] = CloudServers.FollowReads, ["follow_step"] = (int)CloudServers.FollowStep.TotalSeconds,
        }, "constants", problems);
        Same.None(problems, count);
    }
}
