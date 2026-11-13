using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Core;

/// <summary>This PC's Tailscale, as the screens read it: the JSON of `tailscale status --json`, or null when Tailscale
/// is not on this PC or does not run. The screens project runs Windows' own Tailscale; the tests give their own.</summary>
public interface ITailscaleStatus
{
    Task<string?> ReadAsync(CancellationToken cancel);
}

/// <summary>What the PC reads off its own Tailscale (the Mac's FleetOnTailscale): the devices of the network, and the
/// hub of the fleet that runs on one of them, so that a PC finds its hub with no address typed.</summary>
public static class Tailnet
{
    /// <summary>One other device of the network: its name in Tailscale (the first label of its MagicDNS name), its first
    /// private IPv4 address, and whether Tailscale sees it online.</summary>
    public sealed record Device(string Name, string Address, bool Online);

    /// <summary>The hub's own port on every server of a fleet.</summary>
    public const int HubPort = 8765;

    /// <summary>How long one device has to answer GET /health.</summary>
    public static readonly TimeSpan HealthTimeout = TimeSpan.FromSeconds(2);

    /// <summary>The other devices in the status, by name. A device with no private IPv4 address is left out, and an answer
    /// that is not JSON has none.</summary>
    public static IReadOnlyList<Device> Devices(string json)
    {
        var found = new List<Device>();
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object ||
                !document.RootElement.TryGetProperty("Peer", out var peers) || peers.ValueKind != JsonValueKind.Object)
                return found;
            foreach (var peer in peers.EnumerateObject())
            {
                if (peer.Value.ValueKind != JsonValueKind.Object || Name(peer.Value) is not { } name) continue;
                string? address = null;
                if (peer.Value.TryGetProperty("TailscaleIPs", out var ips) && ips.ValueKind == JsonValueKind.Array)
                    address = ips.EnumerateArray().Where(ip => ip.ValueKind == JsonValueKind.String)
                        .Select(ip => ip.GetString()!).FirstOrDefault(IsPrivateAddress);
                if (address is null) continue;
                var online = peer.Value.TryGetProperty("Online", out var on) && on.ValueKind == JsonValueKind.True;
                found.Add(new Device(name, address, online));
            }
        }
        catch (JsonException) { return []; }
        return found.OrderBy(d => d.Name, StringComparer.Ordinal).ToList();
    }

    /// <summary>The name of this PC itself in the same status.</summary>
    public static string? OwnName(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return document.RootElement.ValueKind == JsonValueKind.Object &&
                   document.RootElement.TryGetProperty("Self", out var self) && self.ValueKind == JsonValueKind.Object
                ? Name(self) : null;
        }
        catch (JsonException) { return null; }
    }

    /// <summary>The addresses to ask for a hub, online devices first: every device of the network may be a fleet's
    /// server.</summary>
    public static IReadOnlyList<Uri> Candidates(string json) =>
        Devices(json).OrderBy(d => d.Online ? 0 : 1).Select(d => new Uri($"http://{d.Address}:{HubPort}/")).ToList();

    /// <summary>A Tailscale address (100.64.0.0/10), which every device of the owner's network has.</summary>
    public static bool IsPrivateAddress(string host)
    {
        var parts = host.Split('.');
        if (parts.Length != 4) return false;
        var bytes = new byte[4];
        for (var i = 0; i < 4; i++)
            if (!byte.TryParse(parts[i], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out bytes[i]))
                return false;
        return bytes[0] == 100 && bytes[1] is >= 64 and <= 127;
    }

    /// <summary>A fleet that already runs on this PC's network: each device is asked once, at the same time, whether
    /// it answers as a hub (<paramref name="answers"/>, GET /health in two seconds), and the first that answers is the
    /// address. Null when no device answers, or with no status (no network).</summary>
    public static async Task<Uri?> FindAsync(string? status, Func<Uri, CancellationToken, Task<bool>> answers,
                                             CancellationToken cancel = default)
    {
        if (status is null) return null;
        var addresses = Candidates(status);
        if (addresses.Count == 0) return null;
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        var asked = addresses.Select(async address =>
        {
            try { return await answers(address, stop.Token) ? address : null; }
            catch (Exception e) when (e is not OutOfMemoryException) { return null; }
        }).ToList();
        while (asked.Count > 0)
        {
            var done = await Task.WhenAny(asked);
            asked.Remove(done);
            if (await done is { } found)
            {
                stop.Cancel();
                return found;
            }
        }
        cancel.ThrowIfCancellationRequested();
        return null;
    }

    private static string? Name(JsonElement node)
    {
        if (!node.TryGetProperty("DNSName", out var dns) || dns.ValueKind != JsonValueKind.String) return null;
        var full = dns.GetString()!.ToLowerInvariant().Trim('.');
        var name = full.Split('.')[0];
        return name.Length == 0 ? null : name;
    }
}
