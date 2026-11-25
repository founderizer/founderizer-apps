using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace Founderizer.Setup.RootJobs;

/// <summary>A device of this PC's Tailscale that a host is: its name (the first label of its MagicDNS name), and the
/// <c>OS</c> that Tailscale says each node of that name runs ("linux", "macOS", and so on).</summary>
public sealed record TailnetPeer(string Name, IReadOnlySet<string> Os);

/// <summary>**Which device of this PC's own Tailscale a host is**, out of its <c>tailscale status --json</c> (the Mac's
/// <c>MacNetwork.peer(of:in:)</c> and <c>node(of:in:)</c>). A root job runs only where this PC's own knowledge names the
/// connection's address as the server: the address can come from the hub's record, and the hub's word alone reaches
/// nothing as root and pins nothing. The host is one of a node's Tailscale addresses, its whole MagicDNS name, or that
/// name's first label.</summary>
public static class TailnetNodes
{
    /// <summary>The device that a host is, with the <c>OS</c> of its nodes; null when no device is that host, more than one
    /// is, or the status does not read.</summary>
    public static TailnetPeer? Peer(string host, string? json)
    {
        var found = Matching(host, json).ToList();
        var names = found.Select(n => n.Name).Distinct(StringComparer.Ordinal).ToList();
        if (names.Count != 1) return null;
        return new TailnetPeer(names[0], found.Where(n => n.Os is not null).Select(n => n.Os!).ToHashSet(StringComparer.Ordinal));
    }

    /// <summary>The device's name alone (the Mac's <c>device(of:in:)</c>).</summary>
    public static string? DeviceOf(string host, string? json) => Peer(host, json)?.Name;

    /// <summary>**The one node that a host is**: its stable node ID (<c>ID</c>), else its whole MagicDNS name; null when no
    /// node is that host, or more than one is. Two nodes can share a first label (a node that another tailnet shares into
    /// this one), so a host of that first label is null, while each node's address and whole name still give it. The
    /// vault's steps on the hub's machine compare these, never first labels.</summary>
    public static string? Node(string host, string? json)
    {
        var found = Matching(host, json).Select(n => n.Id is { Length: > 0 } id ? "id:" + id : "name:" + n.Full).ToList();
        return found.Count == 1 ? found[0] : null;
    }

    private sealed record Found(string Name, string Full, string? Os, string? Id);

    private static IEnumerable<Found> Matching(string host, string? json)
    {
        if (json is null) yield break;
        JsonElement root;
        try
        {
            using var document = JsonDocument.Parse(json);
            root = document.RootElement.Clone();
        }
        catch (JsonException) { yield break; }
        if (root.ValueKind != JsonValueKind.Object) yield break;
        var wanted = host.ToLowerInvariant().Trim('[', ']');
        var nodes = new List<JsonElement>();
        if (root.TryGetProperty("Self", out var self) && self.ValueKind == JsonValueKind.Object) nodes.Add(self);
        if (root.TryGetProperty("Peer", out var peers) && peers.ValueKind == JsonValueKind.Object)
            nodes.AddRange(peers.EnumerateObject().Select(p => p.Value).Where(v => v.ValueKind == JsonValueKind.Object));
        foreach (var node in nodes)
        {
            var full = (Text(node, "DNSName") ?? "").ToLowerInvariant().Trim('.');
            var name = full.Split('.', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if (string.IsNullOrEmpty(name)) continue;
            var addresses = node.TryGetProperty("TailscaleIPs", out var ips) && ips.ValueKind == JsonValueKind.Array
                ? ips.EnumerateArray().All(a => a.ValueKind == JsonValueKind.String)
                    ? ips.EnumerateArray().Select(a => a.GetString()!.ToLowerInvariant()).ToList()
                    : []
                : new List<string>();
            if (addresses.Contains(wanted) || wanted == full || wanted == name)
                yield return new Found(name, full, Text(node, "OS"), Text(node, "ID"));
        }
    }

    private static string? Text(JsonElement node, string name) =>
        node.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
