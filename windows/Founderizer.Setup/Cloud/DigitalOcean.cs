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

/// <summary>DigitalOcean (the Mac's <c>CloudServers</c>, its DigitalOcean parts): a token sees its team's droplets in all
/// its projects; the droplet first, on the first offer DigitalOcean takes, with the tag of what it is for and the
/// firewall's name as its tag (the call's own mark), and its firewall at once; then the droplet, read until it runs,
/// because DigitalOcean gives it its address only then.</summary>
internal sealed class DigitalOcean(HttpMessageHandler handler, ISecretBox box, TimeSpan? zone, Func<TimeSpan, CancellationToken, Task>? pause,
                           Action<Func<Task>>? follow)
    : CloudServers(CloudProvider.DigitalOcean, handler, box, zone, pause, follow)
{
    private protected override async Task ReadCheckAsync(CloudCall call, CancellationToken cancel)
    {
        var account = Json.At(await call.SendAsync("GET", "account", null, null, cancel).ConfigureAwait(false), "account");
        if (Json.String(Json.At(account, "status")) == "locked")
        {
            var says = Json.String(Json.At(account, "status_message"))?.Trim() ?? "";
            throw new CloudException(CloudFailure.Refused, Provider, says.Length == 0 ? "the account is locked." : says);
        }
    }

    private protected override async Task<CloudServer> CreateAsync(Made made, CloudOrder order, SshPublicKey key, string userData,
                                                                   CloudCall call, CancellationToken cancel)
    {
        var keyId = await KeyAsync(key, call, cancel).ConfigureAwait(false);
        var offers = Only(order.Offer, await OffersAsync(order.Use, call, cancel).ConfigureAwait(false));
        if (offers.Count == 0) throw None(order.Offer);
        try
        {
            (long Id, Offer Offer)? taken = null;
            CloudAnswer? refusal = null;
            foreach (var offer in offers)
            {
                var answer = await CreateCallAsync("droplets", new JsonObject
                {
                    ["image"] = Provider.Image(),
                    ["name"] = made.Name,
                    ["region"] = offer.Location,
                    ["size"] = offer.Type,
                    ["ssh_keys"] = new JsonArray(keyId),
                    ["tags"] = new JsonArray(Tag(order.Use), made.FirewallName),
                    ["user_data"] = userData,
                }, made, call, cancel).ConfigureAwait(false);
                // DigitalOcean's answer for a size that a region cannot take now: the next offer. Its other 422s (a
                // limit) end the try at once, in its own words.
                if (SaysUnavailable(answer)) { refusal = answer; continue; }
                if (!answer.Ok) throw await FailedAsync(answer, made, call).ConfigureAwait(false);
                if (Json.Long(Json.At(Json.At(answer.Object, "droplet"), "id")) is not { } id)
                    throw new CloudException(CloudFailure.NotUnderstood, Provider);
                taken = (id, offer);
                break;
            }
            if (taken is not { } chosen)
            {
                // The size that the owner said yes to, which this region cannot take now: the page shows the next one.
                if (order.Offer is not null && refusal is not null && SaysUnavailable(refusal)) throw new CloudException(CloudFailure.Taken, Provider);
                throw refusal is not null ? call.Failure(refusal) : None(order.Offer);
            }
            made.Server = chosen.Id.ToString(CultureInfo.InvariantCulture);
            var firewall = await call.SendAsync("POST", "firewalls", null, new JsonObject
            {
                ["droplet_ids"] = new JsonArray(chosen.Id),
                ["name"] = made.FirewallName,
                ["outbound_rules"] = Outbound(),
            }, cancel).ConfigureAwait(false);
            if (Json.String(Json.At(Json.At(firewall, "firewall"), "id")) is not { Length: > 0 } firewallId)
                throw new CloudException(CloudFailure.NotUnderstood, Provider);
            made.Firewall = firewallId;
            var ipv4 = await WaitAsync(chosen.Id, call, cancel).ConfigureAwait(false);
            return new CloudServer(Provider, made.Server, made.Name, ipv4, chosen.Offer.Type, chosen.Offer.Location, chosen.Offer.Price,
                                   chosen.Offer.Currency, firewallId);
        }
        catch (Exception error)
        {
            throw await UndoAsync(made, error, call).ConfigureAwait(false);
        }
    }

    /// <summary>Everything out, to every address; and no inbound rule, which at DigitalOcean lets nothing in.</summary>
    private static JsonArray Outbound()
    {
        static JsonObject Everywhere() => new() { ["addresses"] = new JsonArray("0.0.0.0/0", "::/0") };
        return new JsonArray(
            new JsonObject { ["destinations"] = Everywhere(), ["ports"] = "0", ["protocol"] = "tcp" },
            new JsonObject { ["destinations"] = Everywhere(), ["ports"] = "0", ["protocol"] = "udp" },
            new JsonObject { ["destinations"] = Everywhere(), ["protocol"] = "icmp" });
    }

    /// <summary>The droplets with the call's tag.</summary>
    private protected override async Task<IReadOnlyList<string>> MadeBehindAsync(Made made, CloudCall call, CancellationToken cancel)
    {
        var read = await call.SendAsync("GET", "droplets", [("tag_name", made.FirewallName), ("per_page", "200")], null, cancel).ConfigureAwait(false);
        return (AllObjects(Json.At(read, "droplets")) ?? []).Select(d => Json.Long(Json.At(d, "id"))).OfType<long>()
            .Select(id => id.ToString(CultureInfo.InvariantCulture)).ToList();
    }

    /// <summary>The id of this app's SSH key at DigitalOcean: found by its fingerprint, or registered once.</summary>
    private async Task<long> KeyAsync(SshPublicKey key, CloudCall call, CancellationToken cancel)
    {
        static long? Id(CloudAnswer answer) => Json.Long(Json.At(Json.At(answer.Object, "ssh_key"), "id"));
        var found = await call.AnswerAsync("GET", "account/keys/" + key.Fingerprint, null, null, cancel).ConfigureAwait(false);
        if (found.Ok && Id(found) is { } held) return held;
        if (found.Status != 404) throw found.Ok ? new CloudException(CloudFailure.NotUnderstood, Provider) : call.Failure(found);
        var answer = await call.AnswerAsync("POST", "account/keys", null, new JsonObject { ["name"] = key.Name, ["public_key"] = key.Line },
                                            cancel).ConfigureAwait(false);
        if (answer.Ok && Id(answer) is { } made) return made;
        // Registered meanwhile, by another window of this app: DigitalOcean says it is in use, and it is the same key.
        if (answer.Status == 422)
        {
            try
            {
                var again = await call.AnswerAsync("GET", "account/keys/" + key.Fingerprint, null, null, cancel).ConfigureAwait(false);
                if (again.Ok && Id(again) is { } same) return same;
            }
            catch (CloudException) { }
        }
        throw answer.Ok ? new CloudException(CloudFailure.NotUnderstood, Provider) : call.Failure(answer);
    }

    /// <summary>Each of DigitalOcean's sizes that fits the use, in each region near the PC where DigitalOcean has it now,
    /// cheapest first and, at one price, its smallest droplet for the use first and then the nearest region.</summary>
    private protected override async Task<List<Offer>> OffersAsync(CloudServerUse use, CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "sizes", [("per_page", "200")], null, cancel).ConfigureAwait(false);
        var smallest = CloudProviders.DigitalOceanSize(use);
        var near = Provider.Near(Zone);
        var offers = new List<(Offer Offer, bool First, int Place, int Order)>();
        var sizes = AllObjects(Json.At(listed, "sizes")) ?? [];
        for (var order = 0; order < sizes.Count; order++)
        {
            var size = sizes[order];
            if (!Fits(size, use) || Json.String(Json.At(size, "slug")) is not { } type || Price(Json.At(size, "price_monthly")) is not { } price)
                continue;
            var regions = (Json.AllStrings(Json.At(size, "regions")) ?? []).ToHashSet();
            for (var place = 0; place < near.Count; place++)
            {
                if (!regions.Contains(near[place])) continue;
                offers.Add((new Offer(type, near[place], price, "USD", Json.Int(Json.At(size, "vcpus")),
                                      Json.Double(Json.At(size, "memory")) is { } memory ? memory / 1024 : null, Json.Int(Json.At(size, "disk"))),
                            type == smallest, place, order));
            }
        }
        return offers.OrderBy(o => o.Offer.Price).ThenBy(o => o.First ? 0 : 1).ThenBy(o => o.Place).ThenBy(o => o.Order)
            .Select(o => o.Offer).ToList();
    }

    /// <summary>A size that can take what the server is for: one that may be ordered now, with no GPU, the memory that the
    /// server check asks of that use, room for the system and the install, and a monthly price.</summary>
    private static bool Fits(JsonObject size, CloudServerUse use) =>
        Json.Bool(Json.At(size, "available")) != false && Json.String(Json.At(size, "slug")) is { } slug &&
        !slug.StartsWith("gpu-", StringComparison.Ordinal) && Json.Int(Json.At(size, "memory")) is { } memory && memory >= Need(use) &&
        Json.Int(Json.At(size, "disk")) is >= 20 && Json.Double(Json.At(size, "price_monthly")) is > 0.0;

    /// <summary>DigitalOcean's refusal of a droplet whose size the region cannot take now: its 422, in words such as "Size
    /// is not available in this region."</summary>
    private static bool SaysUnavailable(CloudAnswer answer)
    {
        var words = answer.Says.ToLowerInvariant();
        return answer.Status == 422 && words.Contains("size", StringComparison.Ordinal) &&
               (words.Contains("not available", StringComparison.Ordinal) || words.Contains("unavailable", StringComparison.Ordinal));
    }

    /// <summary>Reads the droplet until it runs with its public IPv4 address.</summary>
    private async Task<string> WaitAsync(long id, CloudCall call, CancellationToken cancel)
    {
        for (var read = 0; read < WaitReads; read++)
        {
            var droplet = Json.At(await ReadAsync("droplets/" + id.ToString(CultureInfo.InvariantCulture), call, cancel).ConfigureAwait(false), "droplet");
            var addresses = AllObjects(Json.At(Json.At(droplet, "networks"), "v4")) ?? [];
            if (Json.String(Json.At(droplet, "status")) == "active" &&
                addresses.FirstOrDefault(a => Json.String(Json.At(a, "type")) == "public") is { } address &&
                Json.String(Json.At(address, "ip_address")) is { } ipv4 && IsIpv4(ipv4)) return ipv4;
            await Pause(WaitStep, cancel).ConfigureAwait(false);
        }
        throw new CloudException(CloudFailure.NotReady, Provider);
    }

    /// <summary>DigitalOcean's droplets (up to 200), each with its project's name when the team has more than one project,
    /// and what this app made it for by its tag, so that the account's list shows a stray droplet as this app's and not
    /// as a server to choose.</summary>
    private protected override async Task<IReadOnlyList<CloudExisting>> ListAsync(CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "droplets", [("per_page", "200")], null, cancel).ConfigureAwait(false);
        var projects = await ProjectsAsync(call, cancel).ConfigureAwait(false);
        var found = new List<CloudExisting>();
        foreach (var droplet in AllObjects(Json.At(listed, "droplets")) ?? [])
        {
            if (Json.Long(Json.At(droplet, "id")) is not { } id || Json.String(Json.At(droplet, "name")) is not { } name) continue;
            var image = Json.At(droplet, "image");
            var addresses = AllObjects(Json.At(Json.At(droplet, "networks"), "v4")) ?? [];
            var ipv4 = addresses.FirstOrDefault(a => Json.String(Json.At(a, "type")) == "public") is { } address
                ? Json.String(Json.At(address, "ip_address")) : null;
            // "24.04 (LTS) x64" and "12 x64": the version is the first word.
            var version = Json.String(Json.At(image, "name"))?.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            var key = id.ToString(CultureInfo.InvariantCulture);
            found.Add(new CloudExisting(key, name, ipv4 is not null && IsIpv4(ipv4) ? ipv4 : null, Json.String(Json.At(droplet, "size_slug")) ?? "",
                                        Json.Int(Json.At(droplet, "memory")), Json.String(Json.At(image, "distribution"))?.ToLowerInvariant(),
                                        version, Json.String(Json.At(Json.At(droplet, "region"), "name")),
                                        Json.String(Json.At(droplet, "status")) == "active", projects.GetValueOrDefault(key),
                                        MadeFor(Json.AllStrings(Json.At(droplet, "tags")))));
        }
        return found;
    }

    /// <summary>The project of each droplet, by the droplet's id, when the team has more than one project; empty when it
    /// has one, or when the token may not read projects.</summary>
    private static async Task<Dictionary<string, string>> ProjectsAsync(CloudCall call, CancellationToken cancel)
    {
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        List<JsonObject>? projects;
        try { projects = AllObjects(Json.At(await call.SendAsync("GET", "projects", [("per_page", "200")], null, cancel).ConfigureAwait(false), "projects")); }
        catch (CloudException) { return names; }
        if (projects is not { Count: > 1 }) return names;
        foreach (var project in projects)
        {
            if (Json.String(Json.At(project, "id")) is not { } id || Json.String(Json.At(project, "name")) is not { } name) continue;
            JsonObject held;
            try { held = await call.SendAsync("GET", "projects/" + id + "/resources", [("per_page", "200")], null, cancel).ConfigureAwait(false); }
            catch (CloudException) { continue; }
            foreach (var resource in AllObjects(Json.At(held, "resources")) ?? [])
                if (Json.String(Json.At(resource, "urn")) is { } urn && urn.StartsWith("do:droplet:", StringComparison.Ordinal))
                    names[urn["do:droplet:".Length..]] = name;
        }
        return names;
    }

    /// <summary>DigitalOcean's firewalls of this app for a server, each with its droplets; one whose list of droplets the
    /// answer does not give is not known to be free.</summary>
    private protected override async Task<IReadOnlyList<CloudFirewall>> FirewallListAsync(string name, CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "firewalls", [("per_page", "200")], null, cancel).ConfigureAwait(false);
        var found = new List<CloudFirewall>();
        foreach (var firewall in AllObjects(Json.At(listed, "firewalls")) ?? [])
        {
            if (Json.String(Json.At(firewall, "name")) is not { } candidate || !IsFirewallName(candidate, name, Provider) ||
                Json.String(Json.At(firewall, "id")) is not { } id) continue;
            if (Json.At(firewall, "droplet_ids") is not JsonArray droplets)
            {
                found.Add(new CloudFirewall(id, [], true));
                continue;
            }
            var servers = droplets.Select(Json.Long).OfType<long>().Select(d => d.ToString(CultureInfo.InvariantCulture)).ToList();
            var tags = Json.At(firewall, "tags") as JsonArray;
            found.Add(new CloudFirewall(id, servers, servers.Count != droplets.Count || (tags is not null && tags.Count > 0)));
        }
        return found;
    }

    private protected override async Task<string?> KeyPathAsync(SshPublicKey key, CloudCall call, CancellationToken cancel)
    {
        var found = await call.AnswerAsync("GET", "account/keys/" + key.Fingerprint, null, null, cancel).ConfigureAwait(false);
        if (found.Status == 404) return null;
        if (!found.Ok || Json.Long(Json.At(Json.At(found.Object, "ssh_key"), "id")) is not { } id)
            throw found.Ok ? new CloudException(CloudFailure.NotUnderstood, Provider) : call.Failure(found);
        return "account/keys/" + id.ToString(CultureInfo.InvariantCulture);
    }
}
