using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.Cloud;

/// <summary>Akamai Cloud, which was Linode (the Mac's <c>CloudServers</c>, its Akamai parts): a token sees the whole
/// account; the firewall first, which drops all that comes in; then the Linode behind it, with this app's key for root
/// and the first boot's script; then the Linode, read until it runs. The Linode takes Akamai's older kind of network
/// interface by name (<c>legacy_config</c>), because a firewall that a Linode is made with stands in front of that kind
/// only. Akamai keeps no SSH key of its own: a Linode takes the key's text when it is made.</summary>
internal sealed class Akamai(HttpMessageHandler handler, ISecretBox box, TimeSpan? zone, Func<TimeSpan, CancellationToken, Task>? pause,
                     Action<Func<Task>>? follow)
    : CloudServers(CloudProvider.Akamai, handler, box, zone, pause, follow)
{
    /// <summary>Any token of the account may read its own profile, whatever products it was given.</summary>
    private protected override Task ReadCheckAsync(CloudCall call, CancellationToken cancel) =>
        call.SendAsync("GET", "profile", null, null, cancel);

    private protected override async Task<CloudServer> CreateAsync(Made made, CloudOrder order, SshPublicKey key, string userData,
                                                                   CloudCall call, CancellationToken cancel)
    {
        var chosen = Only(order.Offer, await OffersAsync(order.Use, call, cancel).ConfigureAwait(false)).FirstOrDefault()
                     ?? throw None(order.Offer);
        var firewall = await call.SendAsync("POST", "networking/firewalls", null, new JsonObject
        {
            ["label"] = made.FirewallName,
            ["rules"] = new JsonObject
            {
                ["inbound"] = new JsonArray(), ["inbound_policy"] = "DROP", ["outbound"] = new JsonArray(), ["outbound_policy"] = "ACCEPT",
            },
            ["tags"] = new JsonArray(Tag(order.Use)),
        }, cancel).ConfigureAwait(false);
        var firewallId = Json.Long(Json.At(firewall, "id")) ?? throw new CloudException(CloudFailure.NotUnderstood, Provider);
        made.Firewall = firewallId.ToString(CultureInfo.InvariantCulture);
        try
        {
            var answer = await CreateCallAsync("linode/instances", new JsonObject
            {
                ["authorized_keys"] = new JsonArray(key.Line),
                ["backups_enabled"] = false,
                ["booted"] = true,
                ["firewall_id"] = firewallId,
                ["image"] = Provider.Image(),
                ["interface_generation"] = "legacy_config",
                ["label"] = made.Name,
                ["metadata"] = new JsonObject { ["user_data"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(userData)) },
                ["private_ip"] = false,
                ["region"] = chosen.Location,
                ["root_pass"] = RootPassword(),
                ["tags"] = new JsonArray(Tag(order.Use)),
                ["type"] = chosen.Type,
            }, made, call, cancel).ConfigureAwait(false);
            if (!answer.Ok) throw await FailedAsync(answer, made, call).ConfigureAwait(false);
            if (Json.Long(Json.At(answer.Object, "id")) is not { } id) throw new CloudException(CloudFailure.NotUnderstood, Provider);
            made.Server = id.ToString(CultureInfo.InvariantCulture);
            var ipv4 = await WaitAsync(id, call, cancel).ConfigureAwait(false);
            return new CloudServer(Provider, made.Server, made.Name, ipv4, chosen.Type, chosen.Location, chosen.Price, chosen.Currency,
                                   made.Firewall);
        }
        catch (Exception error)
        {
            throw await UndoAsync(made, error, call).ConfigureAwait(false);
        }
    }

    /// <summary>The Linodes among the call's firewall's devices.</summary>
    private protected override async Task<IReadOnlyList<string>> MadeBehindAsync(Made made, CloudCall call, CancellationToken cancel)
    {
        if (made.Firewall is not { } firewall) return [];
        var read = await call.SendAsync("GET", Provider.FirewallPath(firewall) + "/devices", [("page_size", "500")], null, cancel).ConfigureAwait(false);
        return (AllObjects(Json.At(read, "data")) ?? []).Select(d => Json.At(d, "entity") as JsonObject)
            .Where(e => e is not null && Json.String(Json.At(e, "type")) == "linode").Select(e => Json.Long(Json.At(e, "id"))).OfType<long>()
            .Select(id => id.ToString(CultureInfo.InvariantCulture)).ToList();
    }

    /// <summary>The root password that Akamai asks of every Linode made from an image: 32 characters of chance, sent once
    /// and kept nowhere, so nobody has it. The server is reached with this app's key, and over the private network only.</summary>
    internal static string RootPassword() =>
        RandomNumberGenerator.GetString("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%+-.:=@^_~", 32);

    /// <summary>Each of Akamai's shared plans that fits what the server is for, in each region near the PC where Akamai has
    /// it free now, cheapest first and, at one price, nearest first.</summary>
    private protected override async Task<List<Offer>> OffersAsync(CloudServerUse use, CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "linode/types", [("page_size", "500")], null, cancel).ConfigureAwait(false);
        var types = (AllObjects(Json.At(listed, "data")) ?? []).Where(t => Fits(t, use)).ToList();
        if (types.Count == 0) return [];
        var offers = new List<(Offer Offer, int Place, int Order)>();
        var near = Provider.Near(Zone);
        for (var place = 0; place < near.Count; place++)
        {
            var region = near[place];
            // Every plan of the region, with whether it is free now: a list, not an object.
            var here = await call.AnswerAsync("GET", "regions/" + region + "/availability", null, null, cancel).ConfigureAwait(false);
            if (!here.Ok) throw call.Failure(here);
            var free = here.Items.Where(i => Json.Bool(Json.At(i, "available")) == true).Select(i => Json.String(Json.At(i, "plan")))
                .OfType<string>().ToHashSet();
            for (var order = 0; order < types.Count; order++)
            {
                var entry = types[order];
                if (Json.String(Json.At(entry, "id")) is not { } type || !free.Contains(type) || Monthly(entry, region) is not { } price) continue;
                offers.Add((new Offer(type, region, price, "USD", Json.Int(Json.At(entry, "vcpus")),
                                      Json.Double(Json.At(entry, "memory")) is { } memory ? memory / 1024 : null,
                                      Json.Int(Json.At(entry, "disk")) is { } disk ? disk / 1024 : null), place, order));
            }
        }
        return offers.OrderBy(o => o.Offer.Price).ThenBy(o => o.Place).ThenBy(o => o.Order).Select(o => o.Offer).ToList();
    }

    /// <summary>A shared plan that is not on its way out, with the memory that the server check asks of that use, room for
    /// the system and the install, and a monthly price.</summary>
    private static bool Fits(JsonObject type, CloudServerUse use) =>
        Json.String(Json.At(type, "class")) is "nanode" or "standard" && !Json.IsSet(type, "successor") &&
        Json.Int(Json.At(type, "memory")) is { } memory && memory >= Need(use) && Json.Int(Json.At(type, "disk")) is >= 20 * 1024 &&
        Json.Decimal(Json.At(Json.At(type, "price"), "monthly")) is not null;

    /// <summary>A plan's monthly price in one region: that region's own price where Akamai has one.</summary>
    private static decimal? Monthly(JsonObject type, string region)
    {
        var local = (AllObjects(Json.At(type, "region_prices")) ?? []).FirstOrDefault(p => Json.String(Json.At(p, "id")) == region);
        return Price(Json.At(local, "monthly")) ?? Price(Json.At(Json.At(type, "price"), "monthly"));
    }

    /// <summary>Reads the Linode until it runs, and answers its public IPv4 address.</summary>
    private async Task<string> WaitAsync(long id, CloudCall call, CancellationToken cancel)
    {
        for (var read = 0; read < WaitReads; read++)
        {
            var linode = await ReadAsync("linode/instances/" + id.ToString(CultureInfo.InvariantCulture), call, cancel).ConfigureAwait(false);
            if (Json.String(Json.At(linode, "status")) == "running" && PublicIpv4(Json.AllStrings(Json.At(linode, "ipv4"))) is { } ipv4)
                return ipv4;
            await Pause(WaitStep, cancel).ConfigureAwait(false);
        }
        throw new CloudException(CloudFailure.NotReady, Provider);
    }

    /// <summary>Akamai's Linodes, page by page (100 a page, at most 20 pages), each with its region's name from Akamai's own
    /// list; a list that cannot be read leaves the region's code.</summary>
    private protected override async Task<IReadOnlyList<CloudExisting>> ListAsync(CloudCall call, CancellationToken cancel)
    {
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            var regions = await call.SendAsync("GET", "regions", [("page_size", "500")], null, cancel).ConfigureAwait(false);
            foreach (var region in AllObjects(Json.At(regions, "data")) ?? [])
                if (Json.String(Json.At(region, "id")) is { } id && Json.String(Json.At(region, "label")) is { } label) names.TryAdd(id, label);
        }
        catch (CloudException) { }
        var found = new List<CloudExisting>();
        long page = 1;
        for (var read = 0; read < 20; read++)
        {
            var listed = await call.SendAsync("GET", "linode/instances",
                                              [("page_size", "100"), ("page", page.ToString(CultureInfo.InvariantCulture))], null, cancel)
                .ConfigureAwait(false);
            foreach (var linode in AllObjects(Json.At(listed, "data")) ?? [])
            {
                if (Json.Long(Json.At(linode, "id")) is not { } id || Json.String(Json.At(linode, "label")) is not { } label) continue;
                // "linode/ubuntu24.04" and "linode/debian12": the system, then its version. An image of the account's own
                // says neither.
                var image = Json.String(Json.At(linode, "image")) is { } written && written.StartsWith("linode/", StringComparison.Ordinal)
                    ? written[7..] : null;
                var system = image is null ? null : new string(image.TakeWhile(char.IsLetter).ToArray());
                var version = image is null ? null : new string(image.SkipWhile(char.IsLetter).ToArray());
                var region = Json.String(Json.At(linode, "region"));
                found.Add(new CloudExisting(
                    id.ToString(CultureInfo.InvariantCulture), label, PublicIpv4(Json.AllStrings(Json.At(linode, "ipv4"))),
                    Json.String(Json.At(linode, "type")) ?? "", Json.Int(Json.At(Json.At(linode, "specs"), "memory")),
                    string.IsNullOrEmpty(system) ? null : system, string.IsNullOrEmpty(version) ? null : version,
                    region is null ? null : names.GetValueOrDefault(region, region), Json.String(Json.At(linode, "status")) == "running", null,
                    MadeFor(Json.AllStrings(Json.At(linode, "tags")))));
            }
            if (Json.Long(Json.At(listed, "pages")) is not { } pages || page >= pages) break;
            page += 1;
        }
        return found;
    }

    /// <summary>Akamai's firewalls of this app for a server, page by page, each with its devices by its own list: a Linode
    /// by its id, anything else as another use.</summary>
    private protected override async Task<IReadOnlyList<CloudFirewall>> FirewallListAsync(string name, CloudCall call, CancellationToken cancel)
    {
        var found = new List<CloudFirewall>();
        long page = 1;
        for (var read = 0; read < 20; read++)
        {
            var listed = await call.SendAsync("GET", "networking/firewalls",
                                              [("page_size", "100"), ("page", page.ToString(CultureInfo.InvariantCulture))], null, cancel)
                .ConfigureAwait(false);
            foreach (var firewall in AllObjects(Json.At(listed, "data")) ?? [])
            {
                if (Json.Long(Json.At(firewall, "id")) is not { } id || Json.String(Json.At(firewall, "label")) is not { } candidate ||
                    !IsFirewallName(candidate, name, Provider)) continue;
                var key = id.ToString(CultureInfo.InvariantCulture);
                var answer = await call.SendAsync("GET", "networking/firewalls/" + key + "/devices", [("page_size", "500")], null, cancel)
                    .ConfigureAwait(false);
                if (AllObjects(Json.At(answer, "data")) is not { } devices)
                {
                    found.Add(new CloudFirewall(key, [], true));
                    continue;
                }
                var servers = devices.Select(d => Json.At(d, "entity")).Where(e => Json.String(Json.At(e, "type")) == "linode")
                    .Select(e => Json.Long(Json.At(e, "id"))).OfType<long>().Select(l => l.ToString(CultureInfo.InvariantCulture)).ToList();
                found.Add(new CloudFirewall(key, servers, servers.Count != devices.Count));
            }
            if (Json.Long(Json.At(listed, "pages")) is not { } pages || page >= pages) break;
            page += 1;
        }
        return found;
    }
}
