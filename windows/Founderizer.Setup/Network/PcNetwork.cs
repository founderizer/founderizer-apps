using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Founderizer.Core;

namespace Founderizer.Setup.Network;

/// <summary>**Tailscale on the owner's own PC** (the Mac's <c>MacNetwork</c> and <c>FleetOnTailscale</c>; windows-app-plan-v2.md,
/// piece L2): what this PC is on the private network, read from its own <c>tailscale status --json</c>, and which
/// installer of Tailscale's fits it. The PC signs in as the owner and is never given a key of the fleet's: a key would
/// tag it, and a tag takes a person's own identity off a device.
///
/// The window runs <c>tailscale.exe</c> (after its publisher check), downloads the installer, checks that Tailscale
/// signed it (<see cref="InstallerOrganisation"/>, <see cref="InstallerCountry"/>; section 8.2) and starts Windows'
/// installer. Nothing here runs a program or reaches the network.</summary>
public static partial class PcNetwork
{
    /// <summary>What this PC is, as far as the private network goes.</summary>
    public enum Step
    {
        /// <summary>No Tailscale on this PC at all.</summary>
        NotInstalled,
        /// <summary>Tailscale is here and nobody has signed in.</summary>
        NotSignedIn,
        /// <summary>Tailscale is here and signed in, and the tunnel is not up.</summary>
        NotConnected,
        /// <summary>This PC is on the private network.</summary>
        Connected,
    }

    /// <summary>This PC's standing: the one thing the page says, its address on the private network (100.64.0.0/10), the
    /// network it is on as Tailscale names it, and Tailscale's own word for its state.</summary>
    public sealed record Standing(Step Step, string? Address = null, string? Tailnet = null, string? Says = null)
    {
        public bool IsConnected => Step == Step.Connected;

        /// <summary>The standing as one mark: good on the network, bad otherwise, with the Mac's words behind it.</summary>
        public (bool Good, string Words) Mark => Step switch
        {
            Step.Connected => (true, "On your network"),
            Step.NotInstalled => (false, "Not installed"),
            Step.NotSignedIn => (false, "Not signed in"),
            _ => (false, "Not connected"),
        };
    }

    /// <summary>The standing out of <c>tailscale status --json</c> (the Mac's <c>MacNetwork.reading</c>).
    /// <paramref name="installed"/> false is a PC with no Tailscale; a Tailscale that gives no answer it can read is one
    /// that nobody has signed in to.</summary>
    public static Standing State(string? statusJson, bool installed = true)
    {
        if (!installed) return new Standing(Step.NotInstalled);
        if (Root(statusJson ?? "") is not { } root || Json.String(Json.At(root, "BackendState")) is not { } state)
            return new Standing(Step.NotSignedIn);
        var address = (Json.AllStrings(Json.At(Json.At(root, "Self"), "TailscaleIPs")) ?? []).FirstOrDefault(Tailnet.IsPrivateAddress);
        var tailnet = Json.String(Json.At(Json.At(root, "CurrentTailnet"), "Name"));
        var step = state switch
        {
            "Running" => address is null ? Step.NotConnected : Step.Connected,
            "NeedsLogin" or "NoState" => Step.NotSignedIn,
            _ => Step.NotConnected,
        };
        return new Standing(step, address, string.IsNullOrEmpty(tailnet) ? null : tailnet, state);
    }

    /// <summary>One other device of the network: its name in Tailscale (the first label of its MagicDNS name), its
    /// first private IPv4 address, whether Tailscale sees it online, and the name that the device gave itself, in lower
    /// case (a server that the app made keeps its provider's name there while Tailscale calls it "worker-1-1").</summary>
    public sealed record Device(string Name, string Address, bool Online, string Host);

    /// <summary>The other devices in the status, by name; one with no private IPv4 address is left out (the Mac's
    /// <c>FleetOnTailscale.devices</c>).</summary>
    public static IReadOnlyList<Device> Devices(string json)
    {
        var found = new List<Device>();
        if (Root(json) is not { } root || Json.At(root, "Peer") is not JsonObject peers) return found;
        foreach (var (_, node) in peers)
        {
            if (node is not JsonObject peer) continue;
            var name = FirstLabel(peer);
            var address = (Json.AllStrings(Json.At(peer, "TailscaleIPs")) ?? []).FirstOrDefault(Tailnet.IsPrivateAddress);
            if (name.Length == 0 || address is null) continue;
            found.Add(new Device(name, address, Json.Bool(Json.At(peer, "Online")) ?? false,
                                 (Json.String(Json.At(peer, "HostName")) ?? "").ToLowerInvariant()));
        }
        return found.OrderBy(d => d.Name, StringComparer.Ordinal).ToList();
    }

    /// <summary>**The devices of an answer that says what the network is now**, or null: the answer is read from its
    /// first <c>{</c> (a warning line can stand before it), Tailscale runs, and this PC is online in its network.</summary>
    public static IReadOnlyList<Device>? Live(string? output)
    {
        if (output is null || output.IndexOf('{') is not (var brace and >= 0)) return null;
        var json = output[brace..];
        if (Root(json) is not { } root || Json.String(Json.At(root, "BackendState")) != "Running" ||
            Json.Bool(Json.At(Json.At(root, "Self"), "Online")) != true) return null;
        return Devices(json);
    }

    /// <summary>The name of this PC itself in the same answer, so it is never a server's name.</summary>
    public static string? OwnName(string json)
    {
        if (Root(json) is not { } root || Json.At(root, "Self") is not JsonObject own) return null;
        var full = (Json.String(Json.At(own, "DNSName")) ?? "").ToLowerInvariant().Trim('.');
        return full.Split('.', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
    }

    /// <summary>**Which device of the private network a host is**, as this PC's own Tailscale says (the Mac's
    /// <c>MacNetwork.device(of:in:)</c>): the host is one of a device's Tailscale addresses, its MagicDNS name, or that
    /// name's first label. Null when no device, or more than one, is that host.</summary>
    public static string? DeviceOf(string host, string json)
    {
        if (Root(json) is not { } root) return null;
        var wanted = host.ToLowerInvariant().Trim('[', ']');
        var nodes = new List<JsonObject>();
        if (Json.At(root, "Self") is JsonObject own) nodes.Add(own);
        if (Json.At(root, "Peer") is JsonObject peers) nodes.AddRange(peers.Select(p => p.Value).OfType<JsonObject>());
        var names = new List<string>();
        foreach (var node in nodes)
        {
            var full = (Json.String(Json.At(node, "DNSName")) ?? "").ToLowerInvariant().Trim('.');
            var name = full.Split('.', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if (string.IsNullOrEmpty(name)) continue;
            var addresses = (Json.AllStrings(Json.At(node, "TailscaleIPs")) ?? []).Select(a => a.ToLowerInvariant());
            if (addresses.Contains(wanted) || wanted == full || wanted == name) names.Add(name);
        }
        return names.Distinct().Count() == 1 ? names[0] : null;
    }

    /// <summary>The private address of the device <paramref name="name"/> in this PC's network, when it is online.</summary>
    public static string? Online(string name, string? json) =>
        json is null ? null : Devices(json).FirstOrDefault(d => d.Name == name && d.Online)?.Address;

    // Tailscale's installer

    /// <summary>Tailscale's own list of its Windows packages, read over HTTPS with no redirect to another host.</summary>
    public static readonly Uri Packages = new("https://pkgs.tailscale.com/stable/?mode=json&os=windows");
    /// <summary>Where each package of that list is.</summary>
    public const string PackagesFolder = "https://pkgs.tailscale.com/stable/";
    /// <summary>Who must have signed the installer (section 8.2, measured in the VM on 13 November 2026): the signer's
    /// organisation and country, in a chain to a root that Windows trusts for code signing, with the revocation check.</summary>
    public const string InstallerOrganisation = "Tailscale Inc.";
    public const string InstallerCountry = "CA";

    /// <summary>One installer of Tailscale's for this kind of PC: its version, its file name and its address.</summary>
    public sealed record Installer(string Version, string File, Uri Address);

    /// <summary>The kind of PC as Tailscale's list names it: "amd64" or "arm64"; null for any other (Windows 11 runs on
    /// those two).</summary>
    public static string? Arch(Architecture architecture) => architecture switch
    {
        Architecture.X64 => "amd64",
        Architecture.Arm64 => "arm64",
        _ => null,
    };

    /// <summary>**The MSI for this kind of PC** from Tailscale's list (<see cref="Packages"/>): <c>MSIs.&lt;arch&gt;</c>, a
    /// file name of Tailscale's own form for that same kind and for the list's version, at <see cref="PackagesFolder"/>.
    /// Null for another kind of PC, a list that has none, and a name of any other form: a name from the network goes into
    /// an address and a file of this app's, so only that form passes.</summary>
    public static Installer? InstallerFor(string arch, string json)
    {
        if (arch is not ("amd64" or "arm64") || Root(json) is not { } root) return null;
        if (Json.String(Json.At(Json.At(root, "MSIs"), arch)) is not { } file || MsiName().Match(file) is not { Success: true } name ||
            name.Groups[2].Value != arch) return null;
        var version = name.Groups[1].Value;
        var listed = Json.String(Json.At(root, "MSIsVersion")) ?? Json.String(Json.At(root, "Version"));
        if (listed is not null && listed != version) return null;
        return new Installer(version, file, new Uri(PackagesFolder + file));
    }

    private static JsonObject? Root(string json)
    {
        return Json.Parse(json) as JsonObject;
    }

    private static string FirstLabel(JsonObject node)
    {
        var full = (Json.String(Json.At(node, "DNSName")) ?? "").ToLowerInvariant().Trim('.');
        return full.Split('.')[0];
    }

    [GeneratedRegex(@"\Atailscale-setup-([0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4})-(amd64|arm64)\.msi\z", RegexOptions.CultureInvariant)]
    private static partial Regex MsiName();
}
