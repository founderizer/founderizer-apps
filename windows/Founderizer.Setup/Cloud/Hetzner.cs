using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.Cloud;

/// <summary>Hetzner Cloud (the Mac's <c>CloudServers</c>, its Hetzner parts): a token sees its own project only; the
/// firewall first, so the server has it from its first boot; the server on the first offer Hetzner takes; its creation
/// read until it ends.</summary>
internal sealed class Hetzner(HttpMessageHandler handler, ISecretBox box, TimeSpan? zone, Func<TimeSpan, CancellationToken, Task>? pause)
    : CloudServers(CloudProvider.Hetzner, handler, box, zone, pause)
{
    private protected override Task ReadCheckAsync(CloudCall call, CancellationToken cancel) =>
        call.SendAsync("GET", "locations", null, null, cancel);

    private protected override async Task<CloudServer> CreateAsync(Made made, CloudOrder order, SshPublicKey key, string userData,
                                                                   CloudCall call, CancellationToken cancel)
    {
        var keyId = await KeyAsync(key, call, cancel).ConfigureAwait(false);
        var offers = Only(order.Offer, await OffersAsync(order.Use, call, cancel).ConfigureAwait(false));
        if (offers.Count == 0) throw None(order.Offer);
        var firewall = await call.SendAsync("POST", "firewalls", null, new JsonObject
        {
            ["labels"] = new JsonObject { ["founderizer"] = Use(order.Use) },
            ["name"] = made.FirewallName,
            ["rules"] = new JsonArray(),
        }, cancel).ConfigureAwait(false);
        var firewallId = Json.Long(Json.At(Json.At(firewall, "firewall"), "id")) ?? throw new CloudException(CloudFailure.NotUnderstood, Provider);
        made.Firewall = firewallId.ToString(CultureInfo.InvariantCulture);
        try
        {
            foreach (var offer in offers)
            {
                var answer = await call.AnswerAsync("POST", "servers", null, new JsonObject
                {
                    ["firewalls"] = new JsonArray(new JsonObject { ["firewall"] = firewallId }),
                    ["image"] = Provider.Image(),
                    ["labels"] = new JsonObject { ["founderizer"] = Use(order.Use) },
                    ["location"] = offer.Location,
                    ["name"] = made.Name,
                    // One public address, IPv4, for what the server reaches out to: each address takes one of the
                    // account's primary IPs, which Hetzner limits. The fleet reaches the server over Tailscale.
                    ["public_net"] = new JsonObject { ["enable_ipv4"] = true, ["enable_ipv6"] = false },
                    ["server_type"] = offer.Type,
                    ["ssh_keys"] = new JsonArray(keyId),
                    ["start_after_create"] = true,
                    ["user_data"] = userData,
                }, cancel).ConfigureAwait(false);
                // None free there after all, since the offers were read: the next offer.
                if (answer.Code is "resource_unavailable" or "placement_error") continue;
                if (!answer.Ok) throw call.Failure(answer);
                if (Json.At(answer.Object, "server") is not JsonObject server || Json.Long(Json.At(server, "id")) is not { } id)
                    throw new CloudException(CloudFailure.NotUnderstood, Provider);
                made.Server = id.ToString(CultureInfo.InvariantCulture);
                var ipv4 = Json.String(Json.At(Json.At(Json.At(server, "public_net"), "ipv4"), "ip"));
                if (ipv4 is null || !IsIpv4(ipv4) || Json.Long(Json.At(Json.At(answer.Object, "action"), "id")) is not { } action)
                    throw new CloudException(CloudFailure.NotUnderstood, Provider);
                await ActionWaitAsync(action, call, cancel).ConfigureAwait(false);
                return new CloudServer(Provider, made.Server, made.Name, ipv4, offer.Type, offer.Location, offer.Price, offer.Currency,
                                       made.Firewall);
            }
            throw None(order.Offer);
        }
        catch (Exception error)
        {
            throw await UndoAsync(made, error, call).ConfigureAwait(false);
        }
    }

    /// <summary>The id of this app's SSH key at Hetzner: found by its fingerprint, or registered once.</summary>
    private async Task<long> KeyAsync(SshPublicKey key, CloudCall call, CancellationToken cancel)
    {
        if (await FoundAsync(key, call, cancel).ConfigureAwait(false) is { } id) return id;
        var answer = await call.AnswerAsync("POST", "ssh_keys", null, new JsonObject
        {
            ["labels"] = new JsonObject { ["founderizer"] = "app" },
            ["name"] = key.Name,
            ["public_key"] = key.Line,
        }, cancel).ConfigureAwait(false);
        if (answer.Ok && Json.Long(Json.At(Json.At(answer.Object, "ssh_key"), "id")) is { } made) return made;
        // Registered meanwhile, by another window of this app: it is the same key.
        if (answer.Code == "uniqueness_error" && await FoundAsync(key, call, cancel).ConfigureAwait(false) is { } again) return again;
        throw answer.Ok ? new CloudException(CloudFailure.NotUnderstood, Provider) : call.Failure(answer);
    }

    private static async Task<long?> FoundAsync(SshPublicKey key, CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "ssh_keys", [("fingerprint", key.Fingerprint)], null, cancel).ConfigureAwait(false);
        return (AllObjects(Json.At(listed, "ssh_keys")) ?? []).Where(k => Json.String(Json.At(k, "fingerprint")) == key.Fingerprint)
            .Select(k => Json.Long(Json.At(k, "id"))).FirstOrDefault();
    }

    /// <summary>Each of Hetzner's types that fits what the server is for, in each location where Hetzner has it free and
    /// not on its way out, cheapest first and, at one price, nearest first, with what it costs there a month: the type,
    /// and the one public IPv4 address it comes with, which Hetzner prices on its own. Hetzner's own list, because its
    /// types change.</summary>
    private protected override async Task<List<Offer>> OffersAsync(CloudServerUse use, CloudCall call, CancellationToken cancel)
    {
        var pricing = Json.At(await call.SendAsync("GET", "pricing", null, null, cancel).ConfigureAwait(false), "pricing") as JsonObject;
        if (pricing is null || Json.String(Json.At(pricing, "currency")) is not { Length: > 0 } currency)
            throw new CloudException(CloudFailure.NotUnderstood, Provider);
        var addresses = (AllObjects(Json.At(pricing, "primary_ips")) ?? []).Where(p => Json.String(Json.At(p, "type")) == "ipv4")
            .Select(p => AllObjects(Json.At(p, "prices")) ?? []).ToList();
        var near = Provider.Near(Zone);
        var listed = await call.SendAsync("GET", "server_types", [("per_page", "50")], null, cancel).ConfigureAwait(false);
        var offers = new List<(Offer Offer, int Place, int Order)>();
        var types = AllObjects(Json.At(listed, "server_types")) ?? [];
        for (var order = 0; order < types.Count; order++)
        {
            var entry = types[order];
            if (Json.String(Json.At(entry, "name")) is not { } type || !Fits(entry, use)) continue;
            var free = (AllObjects(Json.At(entry, "locations")) ?? [])
                .Where(l => Json.Bool(Json.At(l, "available")) == true && !Json.IsSet(l, "deprecation"))
                .Select(l => Json.String(Json.At(l, "name"))).OfType<string>().ToHashSet();
            var prices = AllObjects(Json.At(entry, "prices")) ?? [];
            for (var place = 0; place < near.Count; place++)
            {
                var location = near[place];
                if (!free.Contains(location) || Monthly(prices, location) is not { } server) continue;
                var extra = addresses.Select(a => Monthly(a, location)).OfType<decimal>().Sum();
                offers.Add((new Offer(type, location, server + extra, currency, Json.Int(Json.At(entry, "cores")),
                                      Json.Double(Json.At(entry, "memory")), Json.Int(Json.At(entry, "disk")),
                                      Json.String(Json.At(entry, "cpu_type")) == "dedicated"), place, order));
            }
        }
        return offers.OrderBy(o => o.Offer.Price).ThenBy(o => o.Place).ThenBy(o => o.Order).Select(o => o.Offer).ToList();
    }

    /// <summary>A type of Hetzner's that can take what the server is for: not on its way out, x86 or Arm, with the memory
    /// that the server check asks of that use, and a disk with room for the system and the install's free space.</summary>
    private static bool Fits(JsonObject type, CloudServerUse use) =>
        !Json.IsSet(type, "deprecation") && Json.String(Json.At(type, "architecture")) is "x86" or "arm" &&
        Json.Double(Json.At(type, "memory")) is { } memory && memory * 1024 >= Need(use) && Json.Int(Json.At(type, "disk")) is >= 20;

    /// <summary>A monthly price of Hetzner's at one location, with the tax Hetzner adds for this account.</summary>
    private static decimal? Monthly(List<JsonObject> prices, string location) =>
        prices.FirstOrDefault(p => Json.String(Json.At(p, "location")) == location) is { } price
            ? Price(Json.String(Json.At(Json.At(price, "price_monthly"), "gross"))) : null;

    /// <summary>Hetzner's servers, page by page (50 a page, at most 20 pages).</summary>
    private protected override async Task<IReadOnlyList<CloudExisting>> ListAsync(CloudCall call, CancellationToken cancel)
    {
        var found = new List<CloudExisting>();
        long page = 1;
        for (var read = 0; read < 20; read++)
        {
            var listed = await call.SendAsync("GET", "servers", [("per_page", "50"), ("page", page.ToString(CultureInfo.InvariantCulture))],
                                              null, cancel).ConfigureAwait(false);
            foreach (var server in AllObjects(Json.At(listed, "servers")) ?? [])
            {
                if (Json.Long(Json.At(server, "id")) is not { } id || Json.String(Json.At(server, "name")) is not { } name) continue;
                var type = Json.At(server, "server_type") as JsonObject;
                var image = Json.At(server, "image") as JsonObject;
                // `location` since 2025; `datacenter.location` before it.
                var place = Json.At(server, "location") as JsonObject ?? Json.At(Json.At(server, "datacenter"), "location") as JsonObject;
                var ipv4 = Json.String(Json.At(Json.At(Json.At(server, "public_net"), "ipv4"), "ip"));
                found.Add(new CloudExisting(
                    id.ToString(CultureInfo.InvariantCulture), name, ipv4 is not null && IsIpv4(ipv4) ? ipv4 : null,
                    Json.String(Json.At(type, "name")) ?? "", Json.Double(Json.At(type, "memory")) is { } memory ? Megabytes(memory) : null,
                    Json.String(Json.At(image, "os_flavor"))?.ToLowerInvariant(), Json.String(Json.At(image, "os_version")),
                    Json.String(Json.At(place, "city")), Json.String(Json.At(server, "status")) == "running", null,
                    Json.String(Json.At(Json.At(server, "labels"), "founderizer"))));
            }
            var pages = Json.At(Json.At(listed, "meta"), "pagination");
            if (Json.Long(Json.At(pages, "next_page")) is not { } next || next <= page) break;
            page = next;
        }
        return found;
    }

    /// <summary>Hetzner's firewalls with this app's label, page by page, each with the servers it is applied to.</summary>
    private protected override async Task<IReadOnlyList<CloudFirewall>> FirewallListAsync(string name, CloudCall call, CancellationToken cancel)
    {
        var found = new List<CloudFirewall>();
        long page = 1;
        for (var read = 0; read < 20; read++)
        {
            var listed = await call.SendAsync("GET", "firewalls",
                                              [("label_selector", "founderizer"), ("per_page", "50"), ("page", page.ToString(CultureInfo.InvariantCulture))],
                                              null, cancel).ConfigureAwait(false);
            foreach (var firewall in AllObjects(Json.At(listed, "firewalls")) ?? [])
            {
                if (Json.Long(Json.At(firewall, "id")) is not { } id || Json.String(Json.At(firewall, "name")) is not { } candidate ||
                    !IsFirewallName(candidate, name, Provider) || !Json.Has(Json.At(firewall, "labels"), "founderizer")) continue;
                var uses = AllObjects(Json.At(firewall, "applied_to")) ?? [];
                var servers = uses.Select(u => Json.Long(Json.At(Json.At(u, "server"), "id"))).OfType<long>()
                    .Select(s => s.ToString(CultureInfo.InvariantCulture)).ToList();
                found.Add(new CloudFirewall(id.ToString(CultureInfo.InvariantCulture), servers, servers.Count != uses.Count));
            }
            var pages = Json.At(Json.At(listed, "meta"), "pagination");
            if (Json.Long(Json.At(pages, "next_page")) is not { } next || next <= page) break;
            page = next;
        }
        return found;
    }

    private protected override async Task<string?> KeyPathAsync(SshPublicKey key, CloudCall call, CancellationToken cancel) =>
        await FoundAsync(key, call, cancel).ConfigureAwait(false) is { } id ? "ssh_keys/" + id.ToString(CultureInfo.InvariantCulture) : null;
}
