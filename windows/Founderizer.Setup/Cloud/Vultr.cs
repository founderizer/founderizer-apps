using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.Cloud;

/// <summary>Vultr (the Mac's <c>CloudServers</c>, its Vultr parts): a key sees the whole account; the firewall group
/// first, which lets nothing in while it has no rule; then the instance on the offer the owner said yes to (or the first
/// offer); then the instance, read until it is active with its public address. Vultr's plans were read where they are
/// free a moment before, so a refusal is said in Vultr's own words, and no other offer is tried.</summary>
internal sealed class Vultr(HttpMessageHandler handler, ISecretBox box, TimeSpan? zone, Func<TimeSpan, CancellationToken, Task>? pause,
                    Action<Func<Task>>? follow)
    : CloudServers(CloudProvider.Vultr, handler, box, zone, pause, follow)
{
    /// <summary>Vultr lets a user's key read the account only with the billing permission, so the write that follows,
    /// which any key that may add things can make, is the whole check.</summary>
    private protected override Task ReadCheckAsync(CloudCall call, CancellationToken cancel) => Task.CompletedTask;

    private protected override async Task<CloudServer> CreateAsync(Made made, CloudOrder order, SshPublicKey key, string userData,
                                                                   CloudCall call, CancellationToken cancel)
    {
        var keyId = await KeyAsync(key, call, cancel).ConfigureAwait(false);
        var system = await SystemAsync(call, cancel).ConfigureAwait(false);
        var chosen = Only(order.Offer, await OffersAsync(order.Use, call, cancel).ConfigureAwait(false)).FirstOrDefault()
                     ?? throw None(order.Offer);
        var firewall = await call.SendAsync("POST", "firewalls", null, new JsonObject { ["description"] = made.FirewallName }, cancel)
            .ConfigureAwait(false);
        if (Json.String(Json.At(Json.At(firewall, "firewall_group"), "id")) is not { Length: > 0 } firewallId)
            throw new CloudException(CloudFailure.NotUnderstood, Provider);
        made.Firewall = firewallId;
        try
        {
            var answer = await CreateCallAsync("instances", new JsonObject
            {
                ["activation_email"] = false,
                ["backups"] = "disabled",
                ["enable_ipv6"] = true,
                ["firewall_group_id"] = firewallId,
                ["hostname"] = made.Name,
                ["label"] = made.Name,
                ["os_id"] = system,
                ["plan"] = chosen.Type,
                ["region"] = chosen.Location,
                ["sshkey_id"] = new JsonArray(keyId),
                ["tags"] = new JsonArray(Tag(order.Use)),
                ["user_data"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(userData)),
            }, made, call, cancel).ConfigureAwait(false);
            if (!answer.Ok) throw await FailedAsync(answer, made, call).ConfigureAwait(false);
            if (Json.String(Json.At(Json.At(answer.Object, "instance"), "id")) is not { Length: > 0 } id)
                throw new CloudException(CloudFailure.NotUnderstood, Provider);
            made.Server = id;
            var ipv4 = await WaitAsync(id, call, cancel).ConfigureAwait(false);
            return new CloudServer(Provider, id, made.Name, ipv4, chosen.Type, chosen.Location, chosen.Price, chosen.Currency, firewallId);
        }
        catch (Exception error)
        {
            throw await UndoAsync(made, error, call).ConfigureAwait(false);
        }
    }

    /// <summary>The instances of the call's name behind its firewall group.</summary>
    private protected override async Task<IReadOnlyList<string>> MadeBehindAsync(Made made, CloudCall call, CancellationToken cancel)
    {
        if (made.Firewall is not { } firewall) return [];
        var read = await call.SendAsync("GET", "instances", [("label", made.Name), ("per_page", "500")], null, cancel).ConfigureAwait(false);
        return (AllObjects(Json.At(read, "instances")) ?? []).Where(i => Json.String(Json.At(i, "firewall_group_id")) == firewall)
            .Select(i => Json.String(Json.At(i, "id"))).OfType<string>().ToList();
    }

    /// <summary>The id of this app's SSH key at Vultr: found by the key itself (Vultr lists its keys without a
    /// fingerprint), or registered once.</summary>
    private async Task<string> KeyAsync(SshPublicKey key, CloudCall call, CancellationToken cancel)
    {
        if (await FoundAsync(key, call, cancel).ConfigureAwait(false) is { } id) return id;
        var answer = await call.AnswerAsync("POST", "ssh-keys", null, new JsonObject { ["name"] = key.Name, ["ssh_key"] = key.Line }, cancel)
            .ConfigureAwait(false);
        if (answer.Ok && Json.String(Json.At(Json.At(answer.Object, "ssh_key"), "id")) is { } made) return made;
        throw answer.Ok ? new CloudException(CloudFailure.NotUnderstood, Provider) : call.Failure(answer);
    }

    private static async Task<string?> FoundAsync(SshPublicKey key, CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "ssh-keys", [("per_page", "500")], null, cancel).ConfigureAwait(false);
        return (AllObjects(Json.At(listed, "ssh_keys")) ?? []).Where(k => key.Same(Json.String(Json.At(k, "ssh_key"))))
            .Select(k => Json.String(Json.At(k, "id"))).FirstOrDefault();
    }

    /// <summary>Vultr's id of Ubuntu 24.04 for x86, from Vultr's own list of systems, whose ids are Vultr's to change.</summary>
    private async Task<long> SystemAsync(CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "os", [("per_page", "500")], null, cancel).ConfigureAwait(false);
        var system = (AllObjects(Json.At(listed, "os")) ?? []).FirstOrDefault(s =>
            Json.String(Json.At(s, "family")) == "ubuntu" && Json.String(Json.At(s, "arch")) == "x64" &&
            Json.String(Json.At(s, "name"))?.StartsWith(Provider.Image() + " ", StringComparison.Ordinal) == true);
        return Json.Long(Json.At(system, "id")) ?? throw new CloudException(CloudFailure.NotUnderstood, Provider);
    }

    /// <summary>Each of Vultr's plans that fits what the server is for, in each location near the PC where Vultr has it
    /// free now, cheapest first and, at one price, nearest first.</summary>
    private protected override async Task<List<Offer>> OffersAsync(CloudServerUse use, CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "plans", [("per_page", "500")], null, cancel).ConfigureAwait(false);
        var plans = (AllObjects(Json.At(listed, "plans")) ?? []).Where(p => Fits(p, use)).ToList();
        if (plans.Count == 0) return [];
        var offers = new List<(Offer Offer, int Place, int Order)>();
        var near = Provider.Near(Zone);
        for (var place = 0; place < near.Count; place++)
        {
            var location = near[place];
            var here = await call.SendAsync("GET", "regions/" + location + "/availability", null, null, cancel).ConfigureAwait(false);
            var free = (Json.AllStrings(Json.At(here, "available_plans")) ?? []).ToHashSet();
            for (var order = 0; order < plans.Count; order++)
            {
                var plan = plans[order];
                if (Json.String(Json.At(plan, "id")) is not { } type || !free.Contains(type) ||
                    !(Json.AllStrings(Json.At(plan, "locations")) ?? []).Contains(location) || Monthly(plan, location) is not { } price) continue;
                offers.Add((new Offer(type, location, price, "USD", Json.Int(Json.At(plan, "vcpu_count")),
                                      Json.Double(Json.At(plan, "ram")) is { } ram ? ram / 1024 : null, Json.Int(Json.At(plan, "disk"))),
                            place, order));
            }
        }
        return offers.OrderBy(o => o.Offer.Price).ThenBy(o => o.Place).ThenBy(o => o.Order).Select(o => o.Offer).ToList();
    }

    /// <summary>A plan that can take what the server is for: a virtual machine of Vultr's usual kinds with a disk of its own
    /// and a public IPv4 address, that may be ordered now, with the memory that the server check asks of that use and
    /// room for the system and the install.</summary>
    private static bool Fits(JsonObject plan, CloudServerUse use) =>
        Json.String(Json.At(plan, "id")) is { } id && !id.EndsWith("-v6", StringComparison.Ordinal) &&
        Json.String(Json.At(plan, "type")) is "vc2" or "vhf" or "vhp" or "voc" && Json.Bool(Json.At(plan, "deploy_ondemand")) != false &&
        Json.Int(Json.At(plan, "ram")) is { } ram && ram >= Need(use) && Json.Int(Json.At(plan, "disk")) is >= 20 &&
        Json.Double(Json.At(plan, "monthly_cost")) is > 0.0;

    /// <summary>A plan's monthly price at one location: that location's own price where Vultr has one.</summary>
    private static decimal? Monthly(JsonObject plan, string location) =>
        Price(Json.At(Json.At(Json.At(plan, "location_cost"), location), "monthly_cost")) ?? Price(Json.At(plan, "monthly_cost"));

    /// <summary>Reads the instance until it is active with its public IPv4 address; Vultr says 0.0.0.0 until it has given
    /// it one.</summary>
    private async Task<string> WaitAsync(string id, CloudCall call, CancellationToken cancel)
    {
        for (var read = 0; read < WaitReads; read++)
        {
            var instance = Json.At(await ReadAsync("instances/" + id, call, cancel).ConfigureAwait(false), "instance");
            if (Json.String(Json.At(instance, "status")) == "active" && Json.String(Json.At(instance, "main_ip")) is { } ipv4 &&
                IsIpv4(ipv4) && ipv4 != "0.0.0.0") return ipv4;
            await Pause(WaitStep, cancel).ConfigureAwait(false);
        }
        throw new CloudException(CloudFailure.NotReady, Provider);
    }

    /// <summary>Vultr's instances (up to 500), each with its city from Vultr's own list of regions; a list that cannot be
    /// read leaves the region's code.</summary>
    private protected override async Task<IReadOnlyList<CloudExisting>> ListAsync(CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "instances", [("per_page", "500")], null, cancel).ConfigureAwait(false);
        var cities = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            var regions = await call.SendAsync("GET", "regions", [("per_page", "500")], null, cancel).ConfigureAwait(false);
            foreach (var region in AllObjects(Json.At(regions, "regions")) ?? [])
                if (Json.String(Json.At(region, "id")) is { } id && Json.String(Json.At(region, "city")) is { } city) cities.TryAdd(id, city);
        }
        catch (CloudException) { }
        var found = new List<CloudExisting>();
        foreach (var instance in AllObjects(Json.At(listed, "instances")) ?? [])
        {
            if (Json.String(Json.At(instance, "id")) is not { } id || Json.String(Json.At(instance, "label")) is not { } label) continue;
            // "Ubuntu 24.04 LTS x64" and "Debian 12 x64 (bookworm)": the system, then its version.
            var words = (Json.String(Json.At(instance, "os")) ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var region = Json.String(Json.At(instance, "region"));
            var ipv4 = Json.String(Json.At(instance, "main_ip"));
            found.Add(new CloudExisting(
                id, label, ipv4 is not null && IsIpv4(ipv4) && ipv4 != "0.0.0.0" ? ipv4 : null, Json.String(Json.At(instance, "plan")) ?? "",
                Json.Int(Json.At(instance, "ram")), words.FirstOrDefault()?.ToLowerInvariant(), words.Length > 1 ? words[1] : null,
                region is null ? null : cities.GetValueOrDefault(region, region),
                Json.String(Json.At(instance, "status")) == "active" && Json.String(Json.At(instance, "power_status")) == "running", null,
                MadeFor(Json.AllStrings(Json.At(instance, "tags")))));
        }
        return found;
    }

    /// <summary>Vultr's list gives only how many servers a group stands in front of, not which: a group with one, or with a
    /// count that the answer does not give, is in use.</summary>
    private protected override async Task<IReadOnlyList<CloudFirewall>> FirewallListAsync(string name, CloudCall call, CancellationToken cancel)
    {
        var listed = await call.SendAsync("GET", "firewalls", [("per_page", "500")], null, cancel).ConfigureAwait(false);
        return (AllObjects(Json.At(listed, "firewall_groups")) ?? [])
            .Where(g => Json.String(Json.At(g, "description")) is { } candidate && IsFirewallName(candidate, name, Provider) &&
                        Json.String(Json.At(g, "id")) is not null)
            .Select(g => new CloudFirewall(Json.String(Json.At(g, "id"))!, [], Json.Int(Json.At(g, "instance_count")) != 0)).ToList();
    }

    private protected override async Task<string?> KeyPathAsync(SshPublicKey key, CloudCall call, CancellationToken cancel) =>
        await FoundAsync(key, call, cancel).ConfigureAwait(false) is { } id && IsId(id) ? "ssh-keys/" + id : null;
}
