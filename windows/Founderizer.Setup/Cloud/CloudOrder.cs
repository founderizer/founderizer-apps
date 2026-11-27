using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.Cloud;

/// <summary>Hetzner Cloud, DigitalOcean, Vultr and Akamai: the providers a server can be made at from this PC, in the
/// order their cards stand (the Mac's <c>CloudProvider</c>).</summary>
public enum CloudProvider { Hetzner, DigitalOcean, Vultr, Akamai }

/// <summary>What a server is for, which says the smallest type that fits it.</summary>
public enum CloudServerUse { Hub, Agent }

/// <summary>What each provider is, as this app uses it.</summary>
public static partial class CloudProviders
{
    public static readonly IReadOnlyList<CloudProvider> All =
        [CloudProvider.Hetzner, CloudProvider.DigitalOcean, CloudProvider.Vultr, CloudProvider.Akamai];

    /// <summary>The provider's name as the Mac keeps it ("digitalocean").</summary>
    public static string Raw(this CloudProvider provider) => provider switch
    {
        CloudProvider.Hetzner => "hetzner",
        CloudProvider.DigitalOcean => "digitalocean",
        CloudProvider.Vultr => "vultr",
        _ => "akamai",
    };

    public static CloudProvider? FromRaw(string raw) => All.Cast<CloudProvider?>().FirstOrDefault(p => p!.Value.Raw() == raw);

    public static string Name(this CloudProvider provider) => provider switch
    {
        CloudProvider.Hetzner => "Hetzner",
        CloudProvider.DigitalOcean => "DigitalOcean",
        CloudProvider.Vultr => "Vultr",
        _ => "Akamai",
    };

    /// <summary>Where this provider's token is kept on this PC: the secret box (5.4; the Mac's Keychain item
    /// <c>com.founderizer.cloud.&lt;provider&gt;</c>).</summary>
    public static string BoxName(this CloudProvider provider) => "cloud-tokens/" + provider.Raw();

    /// <summary>Where each provider makes the token, for the step's one link (the Mac's <c>FleetCloudModel.tokenPage</c>).</summary>
    public static Uri TokenPage(this CloudProvider provider) => provider switch
    {
        CloudProvider.Hetzner => new Uri("https://console.hetzner.cloud/projects"),
        CloudProvider.DigitalOcean => new Uri("https://cloud.digitalocean.com/account/api/tokens"),
        CloudProvider.Vultr => new Uri("https://my.vultr.com/settings/#settingsapi"),
        _ => new Uri("https://cloud.linode.com/profile/tokens"),
    };

    internal static string Api(this CloudProvider provider) => provider switch
    {
        CloudProvider.Hetzner => "https://api.hetzner.cloud/v1",
        CloudProvider.DigitalOcean => "https://api.digitalocean.com/v2",
        CloudProvider.Vultr => "https://api.vultr.com/v2",
        _ => "https://api.linode.com/v4",
    };

    /// <summary>Ubuntu 24.04 by this provider's own name for it.</summary>
    internal static string Image(this CloudProvider provider) => provider switch
    {
        CloudProvider.Hetzner => "ubuntu-" + CloudServers.Ubuntu,
        CloudProvider.DigitalOcean => "ubuntu-" + CloudServers.Ubuntu.Replace('.', '-') + "-x64",
        CloudProvider.Vultr => "Ubuntu " + CloudServers.Ubuntu,
        _ => "linode/ubuntu" + CloudServers.Ubuntu,
    };

    /// <summary>The writes that ask whether a token may make what a server needs, each with an empty body that cannot
    /// make anything.</summary>
    internal static IReadOnlyList<string> WriteProbes(this CloudProvider provider) => provider switch
    {
        CloudProvider.Hetzner => ["ssh_keys"],
        CloudProvider.DigitalOcean => ["account/keys"],
        CloudProvider.Vultr => ["ssh-keys"],
        _ => ["linode/instances", "networking/firewalls"],
    };

    internal static string ServerPath(this CloudProvider provider, string id) => provider switch
    {
        CloudProvider.Hetzner => "servers/" + id,
        CloudProvider.DigitalOcean => "droplets/" + id,
        CloudProvider.Vultr => "instances/" + id,
        _ => "linode/instances/" + id,
    };

    internal static string FirewallPath(this CloudProvider provider, string id) =>
        provider == CloudProvider.Akamai ? "networking/firewalls/" + id : "firewalls/" + id;

    /// <summary>DigitalOcean's droplet for each use: its smallest that the server check takes, 2 GB for both since 21
    /// November 2026.</summary>
    public static string DigitalOceanSize(CloudServerUse use) => "s-1vcpu-2gb";

    /// <summary>The locations this app makes servers in, each with the standard offset of its time zone from UTC, in
    /// hours, in the order this app prefers them when two are as near.</summary>
    internal static IReadOnlyList<(string Name, double Hours)> Locations(this CloudProvider provider) => provider switch
    {
        CloudProvider.Hetzner => [("fsn1", 1), ("nbg1", 1), ("hel1", 2), ("ash", -5), ("hil", -8), ("sin", 8)],
        CloudProvider.DigitalOcean => [("fra1", 1), ("ams3", 1), ("lon1", 0), ("nyc3", -5), ("sfo3", -8), ("sgp1", 8)],
        CloudProvider.Vultr => [("fra", 1), ("ams", 1), ("lhr", 0), ("ewr", -5), ("sjc", -8), ("sgp", 8)],
        _ => [("eu-central", 1), ("nl-ams", 1), ("eu-west", 0), ("us-east", -5), ("us-west", -8), ("ap-south", 8)],
    };

    private static readonly Dictionary<string, string> Places = new(StringComparer.Ordinal)
    {
        ["fsn1"] = "Falkenstein, Germany", ["nbg1"] = "Nuremberg, Germany", ["hel1"] = "Helsinki, Finland",
        ["ash"] = "Ashburn, USA", ["hil"] = "Hillsboro, USA", ["sin"] = "Singapore",
        ["fra1"] = "Frankfurt, Germany", ["ams3"] = "Amsterdam, Netherlands", ["lon1"] = "London, UK",
        ["nyc3"] = "New York, USA", ["sfo3"] = "San Francisco, USA", ["sgp1"] = "Singapore",
        ["fra"] = "Frankfurt, Germany", ["ams"] = "Amsterdam, Netherlands", ["lhr"] = "London, UK",
        ["ewr"] = "New Jersey, USA", ["sjc"] = "Silicon Valley, USA", ["sgp"] = "Singapore",
        ["eu-central"] = "Frankfurt, Germany", ["nl-ams"] = "Amsterdam, Netherlands", ["eu-west"] = "London, UK",
        ["us-east"] = "Newark, USA", ["us-west"] = "Fremont, USA", ["ap-south"] = "Singapore",
    };

    /// <summary>The city and country of one of the locations, in this app's own words; the code itself for one it does
    /// not know.</summary>
    public static string Place(this CloudProvider provider, string location) => Places.GetValueOrDefault(location, location);

    /// <summary>The locations nearest this PC first: by how far each location's time zone is from the PC's around the
    /// clock, in standard time, so a summer does not move a PC to another location.</summary>
    public static IReadOnlyList<string> Near(this CloudProvider provider, TimeSpan standardOffset)
    {
        var here = standardOffset.TotalHours;
        double Distance(double hours)
        {
            var apart = Math.Abs(here - hours) % 24;
            return Math.Min(apart, 24 - apart);
        }
        return provider.Locations().Select((l, i) => (l, i)).OrderBy(x => Distance(x.l.Hours)).ThenBy(x => x.i)
            .Select(x => x.l.Name).ToList();
    }

    /// <summary>A pasted token, trimmed, or the reason it is not one. Nothing goes to the provider before this.</summary>
    public static string Token(this CloudProvider provider, string given)
    {
        var token = given.Trim();
        if (token.Length is < 20 or > 256 || token.StartsWith("tskey-", StringComparison.Ordinal) || !TokenShape().IsMatch(token))
            throw new CloudException(CloudFailure.NotAToken, provider);
        return token;
    }

    [GeneratedRegex(@"\A[A-Za-z0-9_-]+\z", RegexOptions.CultureInvariant)]
    private static partial Regex TokenShape();
}

/// <summary>**One server to make** (the Mac's <c>createServer</c>'s arguments): its name at the provider and in
/// Tailscale, what it is for, this app's own SSH public key as one line of <c>authorized_keys</c>, the single-use key it
/// joins the private network with, and the offer the owner said yes to (then the only one tried; null tries each offer
/// in turn). Its text holds no key.</summary>
public sealed record CloudOrder(string Name, CloudServerUse Use, string PublicKey, string AuthKey, CloudOffer? Offer = null)
{
    public override string ToString() => $"CloudOrder {{ Name = {Name}, Use = {Use} }}";
}

/// <summary>One server, as its provider made it: its id there, its public IPv4 address (which nothing from outside
/// reaches: its firewall lets nothing in), its type, location and monthly price, and the id of its firewall.</summary>
public sealed record CloudServer(CloudProvider Provider, string Id, string Name, string Ipv4, string Type, string Location,
                                 decimal MonthlyPrice, string Currency, string FirewallId);

/// <summary>**The server this app would make**: its type and what it is made of, where, and what it costs a month, as the
/// provider's own data says, with the tax the provider adds for this account.</summary>
public sealed partial record CloudOffer(CloudProvider Provider, string Type, string Location, int? Cores, double? MemoryGb,
                                        int? DiskGb, decimal MonthlyPrice, string Currency, bool Dedicated = false)
{
    /// <summary>Its name in a set of offers ("cx23@nbg1").</summary>
    public string Key => CloudServers.Key(Type, Location);

    /// <summary>Its row in the list under a server: Hetzner's type; another provider's size.</summary>
    public string Kind => CloudServers.Kind(Provider, Type, Cores, MemoryGb, Dedicated);

    /// <summary>The city and country of its location, in this app's own words.</summary>
    public string Place => Provider.Place(Location);
}

/// <summary>**One server that the provider's account holds already**, as its provider lists it.</summary>
public sealed partial record CloudExisting(string Id, string Name, string? Ipv4, string Type, int? MemoryMb, string? System,
                                           string? Version, string? Place, bool Running, string? Project, string? MadeFor);

/// <summary>One firewall that this app made for a server, as the provider's list gives it: the servers it stands in
/// front of now, and whether something the list does not name by a server's id uses it.</summary>
public sealed record CloudFirewall(string Id, IReadOnlyList<string> Servers, bool Other)
{
    /// <summary>Nothing uses it but the servers that a run deleted.</summary>
    public bool IsFreeOf(IReadOnlySet<string> deleted) => !Other && Servers.All(deleted.Contains);
}

/// <summary>How a call to delete a server ended, when it did not fail: the provider took the deletion, or it has no
/// server of this id for this token (gone, or of another project or account), with its answer.</summary>
public sealed record CloudDeletion(bool Deleted, CloudException? NotThere = null);

/// <summary>Why a step with a provider stopped (the Mac's <c>CloudError</c>). <c>Unsure</c>: the provider answered the
/// call that makes the server with a fault of its own (a 5xx), or not at all, and this PC does not know whether the server
/// is there (finding 3 of the checked audit of 24 November 2026); <c>TakenBack</c>: it had made the server all the same,
/// and this app deleted it. <c>Unread</c> and <c>UnreadTakenBack</c> are the same two ends after a success answer that
/// holds no id that this app reads (the Mac's <c>unread</c> and <c>unreadTakenBack</c>; the PC readers' point 1 of 26
/// November 2026).</summary>
public enum CloudFailure
{
    NotAToken, NoToken, TokenNotAccepted, ReadOnlyToken, RateLimited, Unreachable, Refused, Unsure, TakenBack, Unread,
    UnreadTakenBack, NotUnderstood, NoRoom, Full, Taken, NotReady, NotAServerName, NotAPublicKey, NotAnAuthKey, LeftBehind,
}

/// <summary>A step with a provider that stopped, with the PC's words for it (the Mac's sentences with "PC" for "Mac").
/// <see cref="Says"/> holds the provider's own words for a refusal, or the reason of a step that left things behind,
/// with the token taken out; <see cref="Left"/> what is still there. An end that is not sure, or a server taken back,
/// names its <see cref="Server"/>; an end that is not sure also names the call's own <see cref="Mark"/>: its firewall,
/// or at DigitalOcean the tag of its droplet, by which the owner tells that server from another of the same name in
/// the provider's own pages (the Mac's <c>CloudError.unsure</c>, <c>takenBack</c>, <c>unread</c> and
/// <c>unreadTakenBack</c>).</summary>
public sealed class CloudException(CloudFailure failure, CloudProvider provider, string? says = null, IReadOnlyList<string>? left = null,
                                   string? server = null, string? mark = null)
    : Exception(Words(failure, provider, says, left ?? [], server, mark))
{
    public CloudFailure Failure { get; } = failure;
    public CloudProvider Provider { get; } = provider;
    public string? Says { get; } = says;
    public IReadOnlyList<string> Left { get; } = left ?? [];
    public string? Server { get; } = server;
    public string? Mark { get; } = mark;

    /// <summary>A call's own mark in the words of the provider's own pages: the firewall that its server stands behind, or
    /// at DigitalOcean the tag that its droplet carries.</summary>
    internal static string Marked(string? mark, CloudProvider provider) =>
        provider == CloudProvider.DigitalOcean ? $"with the tag {mark}" : $"behind the firewall {mark}";

    public static string Words(CloudFailure failure, CloudProvider provider, string? says, IReadOnlyList<string> left,
                               string? server = null, string? mark = null)
    {
        var name = provider.Name();
        return failure switch
        {
            CloudFailure.NotAToken => $"This is not a {name} API token. Copy the token {name} showed you, and paste it.",
            CloudFailure.NoToken => $"This PC holds no {name} token yet. Paste one first.",
            CloudFailure.TokenNotAccepted => $"{name} did not accept this token: it was deleted, or it is not whole. Make a new one and paste it.",
            CloudFailure.ReadOnlyToken => provider switch
            {
                CloudProvider.Hetzner => "This Hetzner token can only read. Make a token with Read & Write in the project's Security page, and paste it.",
                CloudProvider.Vultr => "This Vultr API key cannot make servers. Use the API key of the account, or of a user who may manage servers, and paste it.",
                CloudProvider.Akamai => "This Akamai token cannot make servers. Make one with Read/Write for Linodes and Firewalls, and paste it.",
                _ => $"This {name} token cannot make servers. Make one with full access, or with write access to Droplets, SSH keys and firewalls, and paste it.",
            },
            CloudFailure.RateLimited => $"{name} asks this PC to wait. Try again in a minute.",
            CloudFailure.Unreachable => $"{name} could not be reached. Check this PC's connection to the internet.",
            CloudFailure.Refused => $"{name} refused: {says}",
            CloudFailure.Unsure when says is not null =>
                $"{name} answered with a fault of its own ({says}), so it may have made {server} all the same. While this app is open, it looks for {server} for an hour and deletes it if it comes. If you quit it sooner, delete the {server} {Marked(mark, provider)} at {name} if it is there.",
            CloudFailure.Unsure =>
                $"{name} did not answer the call that makes {server}, so it may have made it all the same. While this app is open, it looks for {server} for an hour and deletes it if it comes. If you quit it sooner, delete the {server} {Marked(mark, provider)} at {name} if it is there.",
            CloudFailure.TakenBack when says is not null =>
                $"{name} answered with a fault of its own ({says}), but it had made {server} all the same, so this app deleted it.",
            CloudFailure.TakenBack => $"{name} did not answer the call that makes {server}, but it had made it all the same, so this app deleted it.",
            CloudFailure.Unread =>
                $"{name} may have made {server}, but this app cannot read its answer. While this app is open, it looks for {server} for an hour and deletes it if it comes. If you quit it sooner, delete the {server} {Marked(mark, provider)} at {name} if it is there.",
            CloudFailure.UnreadTakenBack => $"{name} made {server}, but this app cannot read its answer, so this app deleted {server}.",
            CloudFailure.NotUnderstood => $"{name} answered something this app does not understand.",
            CloudFailure.NoRoom => $"{name} has no server free now.",
            CloudFailure.Full => $"{name} has no room for another server in your account.",
            CloudFailure.Taken => $"That server is not free at {name} any more.",
            CloudFailure.NotReady => $"The server did not come up at {name} in time, so it was deleted. Try again.",
            CloudFailure.NotAServerName => "Use a name of 2 to 31 characters: a-z, 0-9 and -, starting with a letter and not ending in -.",
            CloudFailure.NotAPublicKey => "This app's SSH public key could not be read.",
            CloudFailure.NotAnAuthKey => "The key for the private network is not a Tailscale auth key.",
            _ => left.Count == 2
                ? $"{says} This app could not delete {left[0]} and {left[1]}: delete it at {name}."
                : $"{says} This app could not delete {string.Join(" and ", left)}: delete it at {name}.",
        };
    }
}

/// <summary>**What a stop of a server's page leads to** (the Mac's <c>CloudStop</c>): the token asked for again, or the
/// list read again with its press.</summary>
public static class CloudStop
{
    /// <summary>The provider's refusal of the token itself, after which the page asks for a token again.</summary>
    public static bool RefusesToken(Exception error) =>
        error is CloudException { Failure: CloudFailure.NotAToken or CloudFailure.NoToken or CloudFailure.TokenNotAccepted or CloudFailure.ReadOnlyToken };

    /// <summary>**A build's stop after which the list is read again, with its press**: nothing of the try can be at the
    /// provider, and another press can do better; before the call for the server (<paramref name="called"/> false),
    /// anything but the network's own key.</summary>
    public static bool ReadsListAgain(Exception error, bool called)
    {
        if (error is CloudException cloud)
            return cloud.Failure is CloudFailure.Taken or CloudFailure.NoRoom or CloudFailure.NotReady or CloudFailure.RateLimited
                or CloudFailure.Full && called;
        if (called) return false;
        return error is not FleetKeyException { Failure: FleetKeyFailure.FleetKeyEnded or FleetKeyFailure.NoFleetKey };
    }
}

/// <summary>**The wait for a new server on the private network** (the Mac's <c>CloudServers.joined</c>), from the
/// moment its provider made it, which is after its key was minted: so the wait ends a little after the key.</summary>
public static class CloudJoin
{
    /// <summary>How long a new server has to join the owner's private network, in seconds: the life of its single-use key,
    /// and the app waits for it as long (the owner's choice of 11 November 2026, "1 hour, both").</summary>
    public const int KeyLife = 3600;
    internal static readonly TimeSpan LookEvery = TimeSpan.FromSeconds(5);
    internal static readonly TimeSpan ListAfter = TimeSpan.FromSeconds(300), ListEvery = TimeSpan.FromSeconds(60);

    /// <summary>How the wait ended: this PC sees the server online at its private address; the tailnet's own list had it
    /// at two reads in a row while this PC never showed it online; or the key's life went by.</summary>
    public abstract record End
    {
        public sealed record Online(string Address) : End;
        public sealed record Listed(JoinedDevice Device) : End;
        public sealed record Ended : End;
    }

    /// <summary>The wait: <paramref name="status"/> is this PC's network (its <c>tailscale status --json</c>), read every
    /// five seconds and once more at the end; <paramref name="listed"/>, the tailnet's own list, ends the wait early for a
    /// server that joined and that this PC does not see: read from five minutes on, once a minute, and two reads in a row
    /// that have it end the wait. A cancel ends it at once, also after a read that saw the server.</summary>
    public static async Task<End> WaitAsync(string name, DateTimeOffset made, Func<CancellationToken, Task<string?>> status,
                                            Func<CancellationToken, Task<JoinedDevice?>>? listed, Func<DateTimeOffset> now,
                                            Func<TimeSpan, CancellationToken, Task> pause, CancellationToken cancel = default)
    {
        var until = made.AddSeconds(KeyLife);
        var nextList = made + ListAfter;
        var listedBefore = false;
        while (now() < until)
        {
            cancel.ThrowIfCancellationRequested();
            var json = await status(cancel).ConfigureAwait(false);
            cancel.ThrowIfCancellationRequested();
            if (PcNetwork.Online(name, json) is { } address) return new End.Online(address);
            if (listed is not null && now() >= nextList)
            {
                nextList = now() + ListEvery;
                var device = await listed(cancel).ConfigureAwait(false);
                cancel.ThrowIfCancellationRequested();
                if (device is not null && listedBefore) return new End.Listed(device);
                listedBefore = device is not null;
            }
            await pause(LookEvery, cancel).ConfigureAwait(false);
        }
        // A last look at the end: a PC that slept past the end did not read the network in the last minutes.
        var last = await status(cancel).ConfigureAwait(false);
        cancel.ThrowIfCancellationRequested();
        return PcNetwork.Online(name, last) is { } seen ? new End.Online(seen) : new End.Ended();
    }

    /// <summary>The step's one line when a new server did not join within the key's life.</summary>
    public static string NotJoined(string name, CloudProvider provider) =>
        $"{name} did not join your network within an hour. Open it in {provider.Name()}'s console.";
}

/// <summary>**A cloud provider with one token** (windows-app-plan-v2.md, piece L2): the token checked and kept, the
/// servers the account holds, the offers for a new one, one server made behind a firewall that lets nothing in, and
/// what this app made deleted one thing at a time ("Start again").</summary>
public interface ICloud
{
    CloudProvider Provider { get; }
    /// <summary>Whether this PC holds a token of this provider.</summary>
    bool IsHeld { get; }
    /// <summary>Checks a pasted token, that the provider takes it and that it may make things, and keeps it in the box.
    /// Nothing is kept for a token that fails.</summary>
    Task CheckTokenAsync(string pasted, CancellationToken cancel = default);
    /// <summary>Every type of this provider that fits what the server is for, each once, the one to show first first;
    /// <paramref name="except"/> the keys of offers refused as taken in this run.</summary>
    Task<IReadOnlyList<CloudOffer>> OffersAsync(CloudServerUse use, IReadOnlySet<string>? except = null, CancellationToken cancel = default);
    /// <summary>The servers that this provider's account holds already.</summary>
    Task<IReadOnlyList<CloudExisting>> ServersAsync(CancellationToken cancel = default);
    /// <summary>Makes one server; a step that fails takes away what this call made, the server and its firewall.</summary>
    Task<CloudServer> MakeAsync(CloudOrder order, CancellationToken cancel = default);
    /// <summary>Deletes one server by the provider's own id of it, and nothing else. <paramref name="accepted"/> is
    /// called the moment the provider takes the deletion.</summary>
    Task<CloudDeletion> DeleteAsync(string id, Action? accepted = null, CancellationToken cancel = default);
    /// <summary>The firewalls that this app made for a server of this name, with what uses each.</summary>
    Task<IReadOnlyList<CloudFirewall>> FirewallsAsync(string serverName, CancellationToken cancel = default);
    /// <summary>Deletes the firewalls that this app made for a server of this name, after this run deleted the servers
    /// <paramref name="deleted"/>.</summary>
    Task DeleteFirewallsAsync(string serverName, IReadOnlySet<string> deleted, CancellationToken cancel = default);
    /// <summary>Deletes one firewall by its id.</summary>
    Task DeleteFirewallAsync(string id, CancellationToken cancel = default);
    /// <summary>Deletes this app's own SSH key at the provider; none there deletes nothing.</summary>
    Task DeleteKeyAsync(string publicKey, CancellationToken cancel = default);
}
