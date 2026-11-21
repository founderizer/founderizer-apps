using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Setup.Network;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**Tailscale's API as the PC calls it is the Mac's, request for request** (app/vectors/tailscale-requests.json,
/// which FleetCore's own code writes; windows-app-plan-v2.md, piece L2). Each case gives the stand-in the Mac's answers,
/// and the PC must send each request the Mac sent (a wrong field makes a fleet key that cannot make keys, a key with no
/// tag, or a policy that locks the owner out), give back what the Mac gave or stop where it stopped, in the Mac's words
/// with "PC", and keep what it kept. Beside them the policy file's rules, this PC's own Tailscale, and the reach.</summary>
[TestClass]
public sealed class NetworkVectorTests
{
    private static readonly JsonElement File = Vectors.Read("tailscale-requests.json");

    private static async Task<(JsonNode? Result, Exception? Error)> Run(TailscaleApi api, JsonElement call)
    {
        try
        {
            switch (call.GetProperty("do").GetString())
            {
                case "connect":
                    var setup = await api.MakeFleetClientAsync(call.GetProperty("token").GetString()!);
                    return (new JsonObject
                    {
                        ["key_made"] = setup.KeyMade, ["wrote_policy"] = setup.WrotePolicy, ["lines_to_add"] = setup.LinesToAdd,
                        ["place"] = setup.Place.Kept, ["asks"] = setup.Asks,
                    }, null);
                case "mint":
                    return (new JsonObject
                    {
                        ["key"] = await api.AuthKeyAsync(call.GetProperty("hostname").GetString()!, call.GetProperty("life").GetInt32()),
                    }, null);
                case "joined":
                    var since = DateTimeOffset.FromUnixTimeMilliseconds((long)(call.GetProperty("since").GetDouble() * 1000));
                    var device = await api.JoinedAsync(call.GetProperty("hostname").GetString()!, since);
                    return (device is null ? null : new JsonObject
                    {
                        ["name"] = device.Name, ["addresses"] = Same.Strings(device.Addresses), ["locked"] = device.Locked,
                    }, null);
                case "devices":
                    return (new JsonArray((await api.DevicesAsync()).Select(d => (JsonNode?)new JsonObject
                    {
                        ["id"] = d.Id, ["hostname"] = d.Hostname, ["name"] = d.Name, ["addresses"] = Same.Strings(d.Addresses),
                        ["tags"] = Same.Strings(d.Tags),
                        ["created"] = d.Created is { } created ? (created - DateTimeOffset.UnixEpoch).TotalSeconds : null,
                        ["authorized"] = d.Authorized, ["external"] = d.External, ["connected"] = d.Connected,
                    }).ToArray()), null);
                case "delete_device":
                    await api.DeleteDeviceAsync(call.GetProperty("id").GetString()!);
                    return ("removed", null);
                default:
                    throw new InvalidOperationException("no such call");
            }
        }
        catch (FleetKeyException e) { return (null, e); }
        catch (System.Security.Cryptography.CryptographicException e) { return (null, e); }
    }

    /// <summary>Each case of the Mac's: the requests, the answer or the stop, and the fleet key kept (or none).</summary>
    [TestMethod]
    public async Task EachRequestToTailscaleIsTheMacsAndSoIsWhatComesOfIt()
    {
        var secrets = File.GetProperty("secrets");
        var problems = new List<string>();
        var count = 0;
        foreach (var one in File.GetProperty("cases").EnumerateArray())
        {
            var name = one.GetProperty("name").GetString()!;
            var stand = StandIn.From(one.GetProperty("answers"));
            var memory = new MemorySecretBox();
            if (one.GetProperty("held").ValueKind == JsonValueKind.String)
                memory.Write(TailscaleApi.ClientName, Encoding.UTF8.GetBytes(one.GetProperty("held").GetString()!));
            ISecretBox box = one.GetProperty("refuses").GetBoolean() ? new RefusingBox(memory) : memory;
            var (result, error) = await Run(new TailscaleApi(stand, box), one.GetProperty("call"));
            Same.Requests(one.GetProperty("requests"), stand.Calls, secrets, [], problems, name);
            var expected = one.GetProperty("error");
            if (expected.ValueKind == JsonValueKind.Null)
            {
                if (error is not null) problems.Add($"{name}: stopped: {error.Message}");
                else Same.Json(one.GetProperty("result"), result, name, problems);
            }
            else Error(expected, error, name, problems);
            var kept = memory.Read(TailscaleApi.ClientName) is { } value ? Encoding.UTF8.GetString(value) : null;
            var wanted = one.GetProperty("kept").ValueKind == JsonValueKind.Null ? null : one.GetProperty("kept").GetString();
            if (kept != wanted) problems.Add($"{name}: kept {kept ?? "nothing"}, the vector {wanted ?? "nothing"}");
            count++;
        }
        Same.None(problems, count);
    }

    private static void Error(JsonElement expected, Exception? error, string name, List<string> problems)
    {
        var wanted = expected.GetProperty("case").GetString()!;
        if (wanted == "kept_nowhere")
        {
            if (error is not System.Security.Cryptography.CryptographicException) problems.Add($"{name}: {error?.Message ?? "no stop"}, the box's own stop expected");
            return;
        }
        if (error is not FleetKeyException fleet) { problems.Add($"{name}: {error?.Message ?? "no stop"}, the vector {wanted}"); return; }
        if (Same.Snake(fleet.Failure) != wanted) problems.Add($"{name}: {Same.Snake(fleet.Failure)}, the vector {wanted}");
        if (expected.TryGetProperty("says", out var says) && says.GetString() != fleet.Says) problems.Add($"{name}: says {fleet.Says}, the vector {says.GetString()}");
        if (Same.OnPc(expected.GetProperty("words").GetString()!) != fleet.Message) problems.Add($"{name}: words {fleet.Message}");
    }

    /// <summary>The policy file is read as the Mac reads it, and written by inserting the Mac's very bytes in the Mac's
    /// very places: every byte that the owner wrote stays, and a file that this app cannot read is not written.</summary>
    [TestMethod]
    public void ThePolicyFileIsReadAndWrittenByteForByteAsTheMacDoes()
    {
        var problems = new List<string>();
        var count = 0;
        foreach (var policy in File.GetProperty("policies").EnumerateArray())
        {
            var text = policy.GetProperty("text").GetString()!;
            var where = "policy " + (text.Length > 40 ? text[..40] : text).Replace("\n", " ");
            var needs = FleetPolicy.NeedsIn(text);
            Same.Json(policy.GetProperty("needs"), needs is null ? null : new JsonObject
            {
                ["tag"] = needs.Tag,
                ["grants"] = new JsonArray(needs.Grants.Select(g => (JsonNode?)FleetPolicy.Grants.ToList().IndexOf(g)).ToArray()),
            }, where + " needs", problems);
            Text(policy.GetProperty("written"), needs is null ? null : FleetPolicy.Writing(needs, text), where + " written", problems);
            Text(policy.GetProperty("written_tag"), FleetPolicy.Writing(new FleetPolicy.Needs(true, []), text), where + " tag", problems);
            Text(policy.GetProperty("written_all"), FleetPolicy.Writing(new FleetPolicy.Needs(true, FleetPolicy.Grants), text), where + " all", problems);
            count++;
        }
        Same.None(problems, count);
    }

    private static void Text(JsonElement expected, string? actual, string where, List<string> problems)
    {
        var wanted = expected.ValueKind == JsonValueKind.Null ? null : expected.GetString();
        if (wanted != actual) problems.Add($"{where}:\n{actual ?? "null"}\nthe vector\n{wanted ?? "null"}");
    }

    /// <summary>This PC's own Tailscale is read as the Mac reads its own: the standing, the devices with their own names,
    /// a live answer, this PC's name, and which device a host is.</summary>
    [TestMethod]
    public void ThisPcsTailscaleIsReadAsTheMacReadsItsOwn()
    {
        var problems = new List<string>();
        var count = 0;
        foreach (var network in File.GetProperty("network").EnumerateArray())
        {
            var status = network.GetProperty("status").GetString()!;
            var where = "status " + (status.Length > 30 ? status[..30] : status).Replace("\n", " ");
            var standing = PcNetwork.State(status);
            var step = standing.Step.ToString();
            Same.Json(network, new JsonObject
            {
                ["status"] = status, ["step"] = char.ToLowerInvariant(step[0]) + step[1..], ["address"] = standing.Address,
                ["tailnet"] = standing.Tailnet, ["says"] = standing.Says,
                ["devices"] = new JsonArray(PcNetwork.Devices(status).Select(d => (JsonNode?)new JsonObject
                {
                    ["name"] = d.Name, ["address"] = d.Address, ["online"] = d.Online, ["host"] = d.Host,
                }).ToArray()),
                ["live"] = PcNetwork.Live(status) is { } live ? Same.Strings(live.Select(d => d.Name)) : null,
                ["own_name"] = PcNetwork.OwnName(status),
                ["device_of"] = new JsonObject(network.GetProperty("device_of").EnumerateObject()
                    .Select(h => KeyValuePair.Create(h.Name, (JsonNode?)PcNetwork.DeviceOf(h.Name, status)))),
            }, where, problems);
            count++;
        }
        foreach (var reach in File.GetProperty("reach").EnumerateArray())
        {
            var device = new JoinedDevice(reach.GetProperty("name").GetString()!,
                                          reach.GetProperty("addresses").EnumerateArray().Select(a => a.GetString()!).ToList(),
                                          reach.GetProperty("locked").GetBoolean());
            if (FleetReach.Keeps(device, reach.GetProperty("status").GetString()!) != reach.GetProperty("keeps").GetBoolean())
                problems.Add($"keeps {device} in {reach.GetProperty("status").GetString()![..20]}: not the Mac's");
            count++;
        }
        Same.None(problems, count);
    }

    /// <summary>Every word of the network's steps is the Mac's sentence with "PC" for "Mac", and every rule of a pasted
    /// token, a key's description, an auth key and a device's id is the Mac's.</summary>
    [TestMethod]
    public void TheNetworksWordsAndShapesAreTheMacs()
    {
        var words = File.GetProperty("words");
        var problems = new List<string>();
        var count = 0;
        foreach (var error in words.GetProperty("errors").EnumerateArray())
        {
            var failure = Enum.GetValues<FleetKeyFailure>().Single(f => Same.Snake(f) == error.GetProperty("case").GetString());
            var said = new FleetKeyException(failure, error.TryGetProperty("says", out var says) ? says.GetString() : null).Message;
            if (said != Same.OnPc(error.GetProperty("words").GetString()!) || said.Contains("Mac")) problems.Add($"error words: {said}");
            count++;
        }
        foreach (var place in words.GetProperty("places").EnumerateArray())
        {
            var named = place.GetProperty("place").GetString()!;
            PolicyPlace? at = named switch
            {
                "none" => null,
                "tailscale" => PolicyPlace.Tailscale,
                "tool" => PolicyPlace.OfTool(null),
                _ => PolicyPlace.OfTool(new Uri(named[5..])),
            };
            Same.Json(place, new JsonObject
            {
                ["place"] = named, ["address"] = at?.Address, ["tag_ask"] = at?.TagAsk,
                ["hidden"] = FleetReach.Hidden("worker-3", false, at), ["hidden_hub"] = FleetReach.Hidden("hub-1", true, at),
                ["unreached"] = FleetReach.Unreached("worker-3", "22", at),
            }, "place " + named, problems, onPc: true);
            count++;
        }
        if (FleetReach.Unseen("worker-3") != Same.OnPc(words.GetProperty("unseen").GetString()!)) problems.Add("unseen");
        foreach (var token in words.GetProperty("tokens").EnumerateArray())
        {
            string? given;
            try { given = TailscaleApi.CheckedToken(token.GetProperty("pasted").GetString()!); }
            catch (FleetKeyException) { given = null; }
            Same.Json(token.GetProperty("token"), given, "token " + token.GetProperty("pasted").GetString(), problems);
            count++;
        }
        foreach (var description in words.GetProperty("descriptions").EnumerateArray())
            if (TailscaleApi.KeyDescription(description.GetProperty("hostname").GetString()!) != description.GetProperty("description").GetString())
                problems.Add("description of " + description.GetProperty("hostname").GetString());
        foreach (var key in words.GetProperty("auth_keys").EnumerateArray())
            if (TailscaleApi.IsAuthKey(key.GetProperty("key").GetString()!) != key.GetProperty("is").GetBoolean()) problems.Add("auth key " + key);
        foreach (var id in words.GetProperty("device_ids").EnumerateArray())
            if (TailscaleApi.IsDeviceId(id.GetProperty("id").GetString()!) != id.GetProperty("is").GetBoolean()) problems.Add("device id " + id);
        var constants = words.GetProperty("constants");
        Same.Json(constants, new JsonObject
        {
            ["tag"] = TailscaleApi.Tag, ["keys_page"] = TailscaleApi.KeysPage.AbsoluteUri, ["ports"] = Same.Strings(TailscaleApi.Ports),
            ["hub_ports"] = Same.Strings(TailscaleApi.HubPorts), ["owners"] = Same.Strings(TailscaleApi.Owners),
            ["scopes"] = Same.Strings(TailscaleApi.Scopes), ["client_description"] = TailscaleApi.ClientDescription,
            ["key_life_seconds"] = TailscaleApi.KeyLifeSeconds, ["join_key_life"] = Cloud.CloudJoin.KeyLife,
            ["tag_line"] = FleetPolicy.TagLine, ["grants"] = Same.Strings(FleetPolicy.Grants.Select(g => g.Text)),
        }, "constants", problems);
        Same.None(problems, count);
    }
}
