using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.Cloud;

/// <summary>**A server at a cloud provider, made from this PC with one token that the owner pastes once** (the Mac's
/// <c>CloudServers</c>; windows-app-plan-v2.md, piece L2). What a server made here is: Ubuntu 24.04; the cheapest type
/// that fits what it is for, near this PC; on the owner's private network from its first boot, with a single-use key
/// that lives one hour; behind a provider firewall with no inbound rule at all; with this app's own SSH key. A step that
/// fails takes away what this call made, the server and its firewall, and leaves the SSH key, which the next server uses
/// again; after the provider's own fault answer (a 5xx), or no answer, to the call that makes the server, the servers
/// with the call's own mark are read first (<see cref="MadeMeanwhileAsync"/>). The token stays in the secret box and
/// goes to its provider and nowhere else.
///
/// <see cref="For"/> gives the provider's own class; each one's file holds what is its own.</summary>
public abstract partial class CloudServers : ICloud
{
    /// <summary>The one system every server made here runs.</summary>
    public const string Ubuntu = "24.04";
    /// <summary>How many times a server that is being made is read, three seconds apart, before it counts as not made.</summary>
    internal const int WaitReads = 100;
    internal static readonly TimeSpan WaitStep = TimeSpan.FromSeconds(3);
    /// <summary>How many times a firewall that a deleted server still holds is asked to go.</summary>
    internal const int RemoveReads = 10;
    /// <summary>The reads after a call whose end is not known, and the wait before each: the join key's life, an hour, in
    /// which a server that the provider made later can still join (the Mac's <c>followReads</c> and <c>followStep</c>,
    /// held equal by the vectors).</summary>
    internal const int FollowReads = CloudJoin.KeyLife / 30;
    internal static readonly TimeSpan FollowStep = TimeSpan.FromSeconds(30);
    /// <summary>The memory that the server check asks of a hub's server and of a server for agents (the Mac's
    /// <c>ServerCheck.hubMemory</c> and <c>agentMemory</c>, held equal to them by the vectors).</summary>
    internal const int HubMemoryMb = 1800, AgentMemoryMb = 1800;
    /// <summary>How long a first boot waits for apt's lock before each try of Tailscale's installer, in seconds (the
    /// Mac's <c>InstallPlan.aptLockWait</c>, held equal by the vectors).</summary>
    internal const int AptLockWait = 1200;

    public CloudProvider Provider { get; }
    private readonly ProviderHttp http;
    private readonly ISecretBox box;
    /// <summary>The standard offset of this PC's time zone, which says where the server goes.</summary>
    protected TimeSpan Zone { get; }
    /// <summary>The wait between two reads of a server that is being made, which a test does not wait.</summary>
    protected Func<TimeSpan, CancellationToken, Task> Pause { get; }
    /// <summary>How a call starts the reads that go on after it ended (<see cref="FollowUp"/>): a task of its own, which a
    /// test can wait for.</summary>
    private readonly Action<Func<Task>> follow;

    private protected CloudServers(CloudProvider provider, HttpMessageHandler handler, ISecretBox box, TimeSpan? zone,
                                   Func<TimeSpan, CancellationToken, Task>? pause, Action<Func<Task>>? follow)
    {
        Provider = provider;
        http = new ProviderHttp(handler);
        this.box = box;
        Zone = zone ?? TimeZoneInfo.Local.BaseUtcOffset;
        Pause = pause ?? ((time, cancel) => Task.Delay(time, cancel));
        this.follow = follow ?? (body => _ = Task.Run(body));
    }

    /// <summary>The provider's own class, with the handler that all its HTTP goes through, the box that keeps its token,
    /// this PC's standard time offset (the local one when null), the wait between reads, and how a call starts the reads
    /// after an end that is not known (a task of its own when null).</summary>
    public static ICloud For(CloudProvider provider, HttpMessageHandler handler, ISecretBox box, TimeSpan? zone = null,
                             Func<TimeSpan, CancellationToken, Task>? pause = null, Action<Func<Task>>? follow = null) => provider switch
    {
        CloudProvider.Hetzner => new Hetzner(handler, box, zone, pause, follow),
        CloudProvider.DigitalOcean => new DigitalOcean(handler, box, zone, pause, follow),
        CloudProvider.Vultr => new Vultr(handler, box, zone, pause, follow),
        _ => new Akamai(handler, box, zone, pause, follow),
    };

    public bool IsHeld => HeldToken() is not null;

    private string? HeldToken()
    {
        try { return box.Read(Provider.BoxName()) is { Length: > 0 } stored ? Encoding.UTF8.GetString(stored) : null; }
        catch (CryptographicException) { return null; }
    }

    /// <summary>A call with the token this PC holds for this provider.</summary>
    private protected CloudCall HeldCall() =>
        new(Provider, HeldToken() ?? throw new CloudException(CloudFailure.NoToken, Provider), http);

    // Once: the token

    public async Task CheckTokenAsync(string pasted, CancellationToken cancel = default)
    {
        var token = Provider.Token(pasted);
        var call = new CloudCall(Provider, token, http);
        await ReadCheckAsync(call, cancel).ConfigureAwait(false);
        // Whether it may write is asked with a write that cannot make anything: a token that may write is told its input
        // is wrong; one that may only read is refused for being one.
        foreach (var path in Provider.WriteProbes())
        {
            var probe = await call.AnswerAsync("POST", path, null, new JsonObject(), cancel).ConfigureAwait(false);
            if (!(probe.Ok || probe.Status is 400 or 422)) throw call.Failure(probe);
        }
        var stored = Encoding.UTF8.GetBytes(token);
        try { box.Write(Provider.BoxName(), stored); }
        finally { CryptographicOperations.ZeroMemory(stored); }
    }

    /// <summary>The read that a token of this provider must be able to make, before its write probes.</summary>
    private protected abstract Task ReadCheckAsync(CloudCall call, CancellationToken cancel);

    // Each time: one server

    public async Task<CloudServer> MakeAsync(CloudOrder order, CancellationToken cancel = default)
    {
        if (!IsName(order.Name)) throw new CloudException(CloudFailure.NotAServerName, Provider);
        var key = SshPublicKey.Of(order.PublicKey) ?? throw new CloudException(CloudFailure.NotAPublicKey, Provider);
        if (!TailscaleApi.IsAuthKey(order.AuthKey)) throw new CloudException(CloudFailure.NotAnAuthKey, Provider);
        var call = HeldCall();
        var made = new Made(order.Name, FirewallName(order.Name, Provider));
        return await CreateAsync(made, order, key, UserData(order.AuthKey, order.Name), call, cancel).ConfigureAwait(false);
    }

    private protected abstract Task<CloudServer> CreateAsync(Made made, CloudOrder order, SshPublicKey key, string userData,
                                                             CloudCall call, CancellationToken cancel);

    // Before a server is made: what it would be, and what the account holds already

    public async Task<IReadOnlyList<CloudOffer>> OffersAsync(CloudServerUse use, IReadOnlySet<string>? except = null,
                                                             CancellationToken cancel = default)
    {
        var call = HeldCall();
        var rows = new HashSet<string>(StringComparer.Ordinal);
        var each = (await OffersAsync(use, call, cancel).ConfigureAwait(false))
            .Where(o => (except is null || !except.Contains(Key(o.Type, o.Location))) && rows.Add(Kind(Provider, o.Type, o.Cores, o.MemoryGb, o.Dedicated)))
            .ToList();
        if (each.Count == 0) throw new CloudException(CloudFailure.NoRoom, Provider);
        return each.Select(o => new CloudOffer(Provider, o.Type, o.Location, o.Cores, o.MemoryGb, o.DiskGb, o.Price, o.Currency, o.Dedicated))
            .ToList();
    }

    /// <summary>Every offer of this provider for what the server is for, the one to show first first.</summary>
    private protected abstract Task<List<Offer>> OffersAsync(CloudServerUse use, CloudCall call, CancellationToken cancel);

    public Task<IReadOnlyList<CloudExisting>> ServersAsync(CancellationToken cancel = default) => ListAsync(HeldCall(), cancel);

    private protected abstract Task<IReadOnlyList<CloudExisting>> ListAsync(CloudCall call, CancellationToken cancel);

    /// <summary>One offer's name in a set of offers: its type and its location.</summary>
    internal static string Key(string type, string location) => type + "@" + location;

    /// <summary>One row of the list under a server: Hetzner's type; another provider's size as its row says it (cores,
    /// memory, own cores), in the Mac's own words for each value.</summary>
    internal static string Kind(CloudProvider provider, string type, int? cores, double? memoryGb, bool dedicated) =>
        provider == CloudProvider.Hetzner ? type
            : (cores ?? 0).ToString(CultureInfo.InvariantCulture) + " " + Json.SwiftDouble(memoryGb ?? 0) + " " + (dedicated ? "true" : "false");

    /// <summary>The offers to try: the one the owner said yes to, when it is still offered, and only that one; every
    /// offer when he was shown none.</summary>
    internal static List<Offer> Only(CloudOffer? chosen, List<Offer> offers) =>
        chosen is null ? offers : offers.Where(o => o.Type == chosen.Type && o.Location == chosen.Location).ToList();

    /// <summary>No server could be made of the offers tried: the chosen one is taken now, or with none chosen nothing
    /// that fits is free.</summary>
    private protected CloudException None(CloudOffer? chosen) =>
        new(chosen is null ? CloudFailure.NoRoom : CloudFailure.Taken, Provider);

    // The first boot

    /// <summary>**The server's first boot**: Tailscale by Tailscale's own installer, once apt's lock is free, three tries
    /// at most, and onto the owner's network once, under the server's own name (the Mac's <c>userData</c>, in the words
    /// of hub.py's TAILSCALE_INSTALL). The key stands in the provider's metadata, which is why it is single-use and
    /// worthless after an hour. DNS stays the server's own.</summary>
    public static string UserData(string authKey, string hostname) => string.Join("\n",
        "#!/bin/sh",
        "for try in 1 2 3; do DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=" + AptLockWait.ToString(CultureInfo.InvariantCulture) +
        " -q install </dev/null >/dev/null 2>&1; curl -fsSL https://tailscale.com/install.sh | sh && " +
        "command -v tailscale >/dev/null && break; sleep 20; done",
        "tailscale up --auth-key=" + authKey + " --hostname=" + hostname + " --accept-dns=false") + "\n";

    // Names and ids

    /// <summary>A server's name as the hub takes it, and as a host name may be: it must not end in a hyphen.</summary>
    public static bool IsName(string name) => NameShape().IsMatch(name) && !name.EndsWith('-');

    /// <summary>The firewall's name: the server's, and six letters of chance, so a firewall that a crash left behind never
    /// stands in the way of the next one. Akamai takes a label of 32 characters at most.</summary>
    internal static string FirewallName(string name, CloudProvider provider)
    {
        var chance = RandomNumberGenerator.GetString("abcdefghijklmnopqrstuvwxyz0123456789", 6);
        if (provider != CloudProvider.Akamai) return "founderizer-" + name + "-" + chance;
        var cut = name.Length > 32 - 4 - 6 ? name[..(32 - 4 - 6)] : name;
        cut = cut.TrimEnd('-');
        return "fz-" + cut + "-" + chance;
    }

    /// <summary>Whether a firewall's name is one that this app gave the firewall of a server of this name: the same start,
    /// then exactly six characters of a to z and 0 to 9.</summary>
    internal static bool IsFirewallName(string candidate, string name, CloudProvider provider)
    {
        var model = FirewallName(name, provider);
        var start = model[..^6];
        return candidate.Length == model.Length && candidate.StartsWith(start, StringComparison.Ordinal) &&
               candidate[start.Length..].All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9');
    }

    /// <summary>A provider's own id of a server, a firewall or a key, as it may stand in a path: ASCII letters, digits
    /// and hyphens, 1 to 64 of them.</summary>
    public static bool IsId(string id) => id.Length is >= 1 and <= 64 && id.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');

    internal static bool IsIpv4(string address) => Ipv4Shape().IsMatch(address);

    /// <summary>The first public IPv4 address of a list that also holds a private one (Akamai's).</summary>
    internal static string? PublicIpv4(IReadOnlyList<string>? addresses) => addresses?.FirstOrDefault(address =>
    {
        if (!IsIpv4(address)) return false;
        var parts = address.Split('.').Select(p => int.Parse(p, CultureInfo.InvariantCulture)).ToArray();
        return !(parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && parts[1] is >= 16 and <= 31));
    });

    /// <summary>The tag that says what this app made a server and its firewall for, at DigitalOcean, Vultr and Akamai.</summary>
    internal static string Tag(CloudServerUse use) => "founderizer-" + Use(use);

    internal static string Use(CloudServerUse use) => use == CloudServerUse.Hub ? "hub" : "agent";

    /// <summary>What this app made a server for, by that tag; null for a server this app did not make.</summary>
    internal static string? MadeFor(IReadOnlyList<string>? tags) =>
        tags is null ? null : new[] { CloudServerUse.Hub, CloudServerUse.Agent }.Where(u => tags.Contains(Tag(u))).Select(Use).FirstOrDefault();

    /// <summary>The memory that a type needs for what the server is for.</summary>
    internal static int Need(CloudServerUse use) => use == CloudServerUse.Hub ? HubMemoryMb : AgentMemoryMb;

    /// <summary>A number as the Mac's <c>Decimal(string: number.stringValue)</c> reads one.</summary>
    internal static decimal? Price(JsonNode? node) => Json.Decimal(node);

    /// <summary>A decimal from a text such as "4.1531".</summary>
    internal static decimal? Price(string? text) =>
        decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;

    /// <summary>A list of objects, or null when one item is not an object (Swift's <c>as? [[String: Any]]</c>).</summary>
    internal static List<JsonObject>? AllObjects(JsonNode? node) =>
        node is JsonArray list && list.All(i => i is JsonObject) ? list.OfType<JsonObject>().ToList() : null;

    /// <summary>Memory in GB as a provider gives it, in MB rounded as the Mac rounds it.</summary>
    internal static int Megabytes(double gigabytes) => (int)Math.Round(gigabytes * 1024, MidpointRounding.AwayFromZero);

    // Waiting and taking back

    /// <summary>One read of a server that is being made. A read that does not get through, or that the provider asks this
    /// PC to wait with, says nothing about the server: the next read asks again, within the same count.</summary>
    private protected static async Task<JsonObject?> ReadAsync(string path, CloudCall call, CancellationToken cancel)
    {
        try { return await call.SendAsync("GET", path, null, null, cancel).ConfigureAwait(false); }
        catch (CloudException e) when (e.Failure is CloudFailure.Unreachable or CloudFailure.RateLimited) { return null; }
    }

    /// <summary>Reads one of Hetzner's actions until it ends: one that ends in an error is a failure in Hetzner's words,
    /// and so is one that does not end within the reads.</summary>
    private protected async Task ActionWaitAsync(long action, CloudCall call, CancellationToken cancel)
    {
        for (var read = 0; read < WaitReads; read++)
        {
            var state = Json.At(await ReadAsync("actions/" + action.ToString(CultureInfo.InvariantCulture), call, cancel).ConfigureAwait(false), "action");
            switch (Json.String(Json.At(state, "status")))
            {
                case "success": return;
                case "error":
                    throw new CloudException(CloudFailure.Refused, Provider,
                                             Json.String(Json.At(Json.At(state, "error"), "message")) ?? "the server was not made.");
                default:
                    await Pause(WaitStep, cancel).ConfigureAwait(false);
                    break;
            }
        }
        throw new CloudException(CloudFailure.NotReady, Provider);
    }

    /// <summary>What one call has made so far. <see cref="FirewallName"/>, six letters of chance after the server's name,
    /// is the call's own mark: at Hetzner, Vultr and Akamai the firewall is made first and the server is made behind it;
    /// at DigitalOcean the droplet carries the name as its tag (<see cref="MadeBehindAsync"/>).</summary>
    private protected sealed class Made(string name, string firewallName)
    {
        public string Name { get; } = name;
        public string FirewallName { get; } = firewallName;
        public string? Server { get; set; }
        public string? Firewall { get; set; }
    }

    /// <summary>**The servers that carry this call's own mark** (the Mac's <c>madeBehind</c>): at Hetzner the servers that
    /// its firewall stands in front of, at Akamai the Linodes of its firewall's devices, at Vultr the instances of that
    /// name behind its firewall group, at DigitalOcean the droplets with its tag. One read, and nothing else of the
    /// account: a name alone can be another build's server, of another fleet in the same account or of another computer
    /// of this fleet.</summary>
    private protected abstract Task<IReadOnlyList<string>> MadeBehindAsync(Made made, CloudCall call, CancellationToken cancel);

    /// <summary>The servers with the call's mark, or null when the read does not get through.</summary>
    private async Task<IReadOnlyList<string>?> MarkedAsync(Made made, CloudCall call)
    {
        try { return await MadeBehindAsync(made, call, CancellationToken.None).ConfigureAwait(false); }
        catch (Exception e) when (e is not OutOfMemoryException) { return null; }
    }

    /// <summary>**After the provider's own fault answer (a 5xx), or no answer at all, to the call that makes the server**
    /// (finding 3 of the checked audit of 24 November 2026; the Mac's <c>madeMeanwhile</c>): the provider can have made
    /// the server all the same, so the servers with this call's mark are read before anything is taken back, the
    /// firewall included, with no cancel (the owner's stop of the call must not cut this read short). The one server
    /// there is this call's: its id is what <see cref="UndoAsync"/> then deletes with the rest. Every other end throws
    /// <paramref name="unsure"/>, and nothing is taken back: no such server yet (a gateway's 502 or 504, or a time-out,
    /// while the provider goes on making it: a firewall taken back now would leave it with none), a read that does not
    /// get through, or two of them. <see cref="FollowUp"/> reads on then.</summary>
    private async Task<string> MadeMeanwhileAsync(Made made, CloudCall call, CloudException unsure)
    {
        if (await MarkedAsync(made, call).ConfigureAwait(false) is not { Count: 1 } marked)
        {
            FollowUp(made, call);
            throw unsure;
        }
        return marked[0];
    }

    /// <summary>**A call that ended not knowing whether the provider made the server goes on reading for it**, in a task
    /// of its own, while this app runs (the Mac's <c>followUp</c>: else a server that came later runs at the owner's cost,
    /// with no record that finds it): every <see cref="FollowStep"/>, <see cref="FollowReads"/> times, the servers with
    /// the call's mark. The one that comes is deleted with the call's firewall (<see cref="RemoveAsync"/>), and the reads
    /// go on while it stays: a deletion that failed, or Hetzner's <c>locked</c> while it still makes the server. Two with
    /// the mark are not the call's alone: nothing is deleted, and the reads go on. A firewall with no server stays: it
    /// costs nothing, and a server can still come behind it.</summary>
    private void FollowUp(Made made, CloudCall call)
    {
        var firewall = made.Firewall;
        follow(async () =>
        {
            for (var read = 0; read < FollowReads; read++)
            {
                try { await Pause(FollowStep, CancellationToken.None).ConfigureAwait(false); }
                catch (Exception e) when (e is not OutOfMemoryException) { return; }
                if (await MarkedAsync(made, call).ConfigureAwait(false) is not { Count: 1 } marked) continue;
                var found = new Made(made.Name, made.FirewallName) { Server = marked[0], Firewall = firewall };
                // Done once the server is gone: a firewall that stays after it costs nothing.
                if (!(await RemoveAsync(found, call).ConfigureAwait(false)).ServerStays) return;
            }
        });
    }

    /// <summary>**The call for the server** (the Mac's <c>create</c>), whose answer this PC may not get: a time-out, a
    /// connection that ended, or a stop of the call while it was on its way. The provider can have made the server all
    /// the same, so the servers with the call's mark are read as after a fault answer: the one there goes with the rest,
    /// and the call ends as <c>TakenBack</c> with no words of the provider's; else it ends <c>Unsure</c>.</summary>
    private protected async Task<CloudAnswer> CreateCallAsync(string path, JsonObject body, Made made, CloudCall call, CancellationToken cancel)
    {
        // A stop before the call goes sends nothing: what this call made is taken back, as before.
        cancel.ThrowIfCancellationRequested();
        try { return await call.AnswerAsync("POST", path, null, body, cancel).ConfigureAwait(false); }
        catch (Exception e) when (e is CloudException { Failure: CloudFailure.Unreachable } || (e is OperationCanceledException && cancel.IsCancellationRequested))
        {
            var unsure = new CloudException(CloudFailure.Unsure, Provider, null, null, made.Name, made.FirewallName);
            made.Server = await MadeMeanwhileAsync(made, call, unsure).ConfigureAwait(false);
            throw new CloudException(CloudFailure.TakenBack, Provider, null, null, made.Name);
        }
    }

    /// <summary>The error of a call for the server that the provider did not answer with one (the Mac's <c>failed</c>):
    /// after the provider's own fault answer (a 5xx), the server that it made all the same is <c>made.Server</c>
    /// (<see cref="MadeMeanwhileAsync"/>), and the error is <c>TakenBack</c>, or the call ends <c>Unsure</c>. Any other
    /// refusal is the provider's, with no read.</summary>
    private protected async Task<CloudException> FailedAsync(CloudAnswer answer, Made made, CloudCall call)
    {
        var fault = call.Failure(answer);
        if (answer.Status < 500) return fault;
        // The line's own brackets end the provider's words.
        var says = (fault.Failure == CloudFailure.Refused ? fault.Says : fault.Message)?.TrimEnd('.') ?? "";
        var unsure = new CloudException(CloudFailure.Unsure, Provider, says, null, made.Name, made.FirewallName);
        made.Server = await MadeMeanwhileAsync(made, call, unsure).ConfigureAwait(false);
        return new CloudException(CloudFailure.TakenBack, Provider, says, null, made.Name);
    }

    /// <summary>Takes away what one call made, and says so when it could not. It runs to its end also when the call was
    /// cancelled, so that a create the owner stopped still leaves no server running at his cost. A call whose end is not
    /// known (<c>Unsure</c>) takes nothing back: a server that the provider made all the same can stand behind the
    /// firewall that this call made, and Akamai deletes a firewall that a Linode uses.</summary>
    private protected async Task<Exception> UndoAsync(Made made, Exception error, CloudCall call)
    {
        if (error is CloudException { Failure: CloudFailure.Unsure }) return error;
        var (left, _) = await RemoveAsync(made, call).ConfigureAwait(false);
        if (left.Count == 0) return error;
        // A server that the call found and could not delete is said in the provider's own words, never as deleted.
        var said = error is CloudException { Failure: CloudFailure.TakenBack } back
            ? back.Says is { } says ? new CloudException(CloudFailure.Refused, Provider, says) : new CloudException(CloudFailure.Unreachable, Provider)
            : error;
        return new CloudException(CloudFailure.LeftBehind, Provider, said.Message, left);
    }

    /// <summary>Deletes the server, then its firewall, and answers what is still there, and whether the server stays. A
    /// firewall goes only once no server uses it, so it is asked again while the server's deletion runs. A server that
    /// does not go keeps its firewall: Akamai deletes a firewall that a Linode uses, which would leave that server open.
    /// Hetzner refuses to delete a server that it still makes (<c>locked</c>), so that deletion is asked again while it
    /// is, and its deletion is an action: one that ends in an error leaves the server there.</summary>
    private async Task<(List<string> Left, bool ServerStays)> RemoveAsync(Made made, CloudCall call)
    {
        var left = new List<string>();
        var serverStays = false;
        var none = CancellationToken.None;
        if (made.Server is { } server)
        {
            async Task<CloudAnswer?> DeleteOnceAsync()
            {
                try { return await call.AnswerAsync("DELETE", Provider.ServerPath(server), null, null, none).ConfigureAwait(false); }
                catch (CloudException) { return null; }
            }
            var answer = await DeleteOnceAsync().ConfigureAwait(false);
            for (var read = 1; read < RemoveReads && answer?.Code == "locked"; read++)
            {
                try { await Pause(WaitStep, none).ConfigureAwait(false); }
                catch (OperationCanceledException) { }
                answer = await DeleteOnceAsync().ConfigureAwait(false);
            }
            if (answer is not null && (answer.Ok || answer.Status == 404))
            {
                if (Json.Long(Json.At(Json.At(answer.Object, "action"), "id")) is { } action)
                {
                    try { await ActionWaitAsync(action, call, none).ConfigureAwait(false); }
                    catch (CloudException) { serverStays = true; }
                }
            }
            else serverStays = true;
            if (serverStays) left.Add($"the server {made.Name}");
        }
        if (made.Firewall is not null && serverStays) left.Add($"the firewall {made.FirewallName}");
        else if (made.Firewall is { } firewall)
        {
            var gone = false;
            for (var read = 0; read < RemoveReads; read++)
            {
                CloudAnswer answer;
                try { answer = await call.AnswerAsync("DELETE", Provider.FirewallPath(firewall), null, null, none).ConfigureAwait(false); }
                catch (CloudException) { break; }
                if (answer.Ok || answer.Status == 404) { gone = true; break; }
                if (!InUse(answer)) break;
                try { await Pause(WaitStep, none).ConfigureAwait(false); }
                catch (OperationCanceledException) { }
            }
            if (!gone) left.Add($"the firewall {made.FirewallName}");
        }
        return (left, serverStays);
    }

    /// <summary>Hetzner says a firewall is still in use while the server's deletion runs; Vultr and Akamai say it in words
    /// of their own, so any refusal of theirs but the token's is asked again.</summary>
    private bool InUse(CloudAnswer answer) =>
        answer.Code == "resource_in_use" ||
        (Provider is CloudProvider.Vultr or CloudProvider.Akamai && answer.Status is not (401 or 403));

    // Deleting what this app made, one thing at a time ("Start again")

    public async Task<CloudDeletion> DeleteAsync(string id, Action? accepted = null, CancellationToken cancel = default)
    {
        if (!IsId(id)) throw new CloudException(CloudFailure.NotUnderstood, Provider);
        var call = HeldCall();
        var answer = await call.AnswerAsync("DELETE", Provider.ServerPath(id), null, null, cancel).ConfigureAwait(false);
        if (answer.Status == 404) return new CloudDeletion(false, call.Failure(answer));
        if (!answer.Ok) throw call.Failure(answer);
        accepted?.Invoke();
        if (Json.Long(Json.At(Json.At(answer.Object, "action"), "id")) is not { } action) return new CloudDeletion(true);
        for (var read = 0; read < WaitReads; read++)
        {
            var state = Json.At(await ReadAsync("actions/" + action.ToString(CultureInfo.InvariantCulture), call, cancel).ConfigureAwait(false), "action");
            switch (Json.String(Json.At(state, "status")))
            {
                case "success": return new CloudDeletion(true);
                case "error":
                    var error = Json.At(state, "error");
                    throw new CloudException(CloudFailure.Refused, Provider,
                                             Json.String(Json.At(error, "message")) ?? Json.String(Json.At(error, "code")) ?? "error");
                default:
                    await Pause(WaitStep, cancel).ConfigureAwait(false);
                    break;
            }
        }
        var after = await call.AnswerAsync("GET", Provider.ServerPath(id), null, null, cancel).ConfigureAwait(false);
        if (after.Status != 404) throw after.Ok ? new CloudException(CloudFailure.NotUnderstood, Provider) : call.Failure(after);
        return new CloudDeletion(true);
    }

    public Task<IReadOnlyList<CloudFirewall>> FirewallsAsync(string serverName, CancellationToken cancel = default) =>
        IsName(serverName) ? FirewallListAsync(serverName, HeldCall(), cancel) : Task.FromResult<IReadOnlyList<CloudFirewall>>([]);

    /// <summary>The firewalls of this provider's list whose name is one that this app gave a server of this name.</summary>
    private protected abstract Task<IReadOnlyList<CloudFirewall>> FirewallListAsync(string name, CloudCall call, CancellationToken cancel);

    public async Task DeleteFirewallsAsync(string serverName, IReadOnlySet<string> deleted, CancellationToken cancel = default)
    {
        var found = await FirewallsAsync(serverName, cancel).ConfigureAwait(false);
        if (Provider == CloudProvider.Vultr)
        {
            // Vultr says only how many servers a group has: a group that still has one is read again while the server's
            // own deletion can still run.
            for (var reads = 1; reads < RemoveReads && found.Any(f => !f.IsFreeOf(deleted)); reads++)
            {
                await Pause(WaitStep, cancel).ConfigureAwait(false);
                found = await FirewallsAsync(serverName, cancel).ConfigureAwait(false);
            }
        }
        Exception? failed = null;
        foreach (var firewall in found)
        {
            // Hetzner refuses to delete a firewall that a server still uses; the others delete one in use, so there a
            // firewall that anything but the deleted servers uses stays.
            if (Provider != CloudProvider.Hetzner && !firewall.IsFreeOf(deleted)) continue;
            try { await DeleteFirewallAsync(firewall.Id, cancel).ConfigureAwait(false); }
            catch (CloudException e) { failed ??= e; }
        }
        if (failed is not null) throw failed;
    }

    public async Task DeleteFirewallAsync(string id, CancellationToken cancel = default)
    {
        if (!IsId(id)) throw new CloudException(CloudFailure.NotUnderstood, Provider);
        var call = HeldCall();
        CloudAnswer? last = null;
        for (var read = 0; read < RemoveReads; read++)
        {
            var answer = await call.AnswerAsync("DELETE", Provider.FirewallPath(id), null, null, cancel).ConfigureAwait(false);
            if (answer.Ok || answer.Status == 404) return;
            last = answer;
            if (!InUse(answer)) break;
            await Pause(WaitStep, cancel).ConfigureAwait(false);
        }
        throw last is null ? new CloudException(CloudFailure.NotUnderstood, Provider) : call.Failure(last);
    }

    public async Task DeleteKeyAsync(string publicKey, CancellationToken cancel = default)
    {
        var key = SshPublicKey.Of(publicKey) ?? throw new CloudException(CloudFailure.NotAPublicKey, Provider);
        if (Provider == CloudProvider.Akamai) return;
        var call = HeldCall();
        if (await KeyPathAsync(key, call, cancel).ConfigureAwait(false) is not { } path) return;
        var answer = await call.AnswerAsync("DELETE", path, null, null, cancel).ConfigureAwait(false);
        if (!answer.Ok && answer.Status != 404) throw call.Failure(answer);
    }

    /// <summary>The path of this app's own key at the provider, or null when the provider has none.</summary>
    private protected virtual Task<string?> KeyPathAsync(SshPublicKey key, CloudCall call, CancellationToken cancel) =>
        Task.FromResult<string?>(null);

    public override string ToString() => $"CloudServers({Provider.Name()})";

    [GeneratedRegex(@"\A[a-z][a-z0-9-]{1,30}\z", RegexOptions.CultureInvariant)]
    private static partial Regex NameShape();

    [GeneratedRegex(@"\A[0-9]{1,3}(\.[0-9]{1,3}){3}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Ipv4Shape();
}

/// <summary>One offer of a provider: a type, a location, and what it costs there a month, with what the type is made of.</summary>
internal sealed record Offer(string Type, string Location, decimal Price, string Currency, int? Cores = null, double? MemoryGb = null,
                             int? DiskGb = null, bool Dedicated = false);

/// <summary>One answer of a provider: its status, its body as an object (empty for any other), as a list of objects
/// (Akamai's list of a region's free plans), and its first 300 bytes as text.</summary>
internal sealed class CloudAnswer(int status, JsonObject obj, IReadOnlyList<JsonObject> items, string text)
{
    public int Status { get; } = status;
    public JsonObject Object { get; } = obj;
    public IReadOnlyList<JsonObject> Items { get; } = items;
    public string Text { get; } = text;
    public bool Ok => Status is >= 200 and <= 299;

    /// <summary>The provider's own code for a refusal: Hetzner's <c>error.code</c>, DigitalOcean's <c>id</c>.</summary>
    public string? Code => Json.String(Json.At(Json.At(Object, "error"), "code")) ?? Json.String(Json.At(Object, "id"));

    /// <summary>The provider's own words for it: Hetzner's <c>error.message</c>, DigitalOcean's <c>message</c>, Vultr's
    /// <c>error</c>, and each of Akamai's <c>errors</c>.</summary>
    public string Says
    {
        get
        {
            if (Json.String(Json.At(Json.At(Object, "error"), "message")) is { } message) return message;
            if (Json.String(Json.At(Object, "message")) is { } said) return said;
            if (Json.String(Json.At(Object, "error")) is { } error) return error;
            var reasons = (CloudServers.AllObjects(Json.At(Object, "errors")) ?? []).Select(e =>
            {
                if (Json.String(Json.At(e, "reason")) is not { } reason) return null;
                return Json.String(Json.At(e, "field")) is { } part ? part + ": " + reason : reason;
            }).OfType<string>().ToList();
            return reasons.Count == 0 ? Text : string.Join("; ", reasons);
        }
    }
}

/// <summary>One provider's API with one token: the request, the answer as JSON, and a refusal in the provider's own
/// words, with the token never in them.</summary>
internal sealed class CloudCall(CloudProvider provider, string token, ProviderHttp http)
{
    public CloudProvider Provider { get; } = provider;

    public async Task<CloudAnswer> AnswerAsync(string method, string path, IReadOnlyList<(string Name, string Value)>? query,
                                               JsonObject? body, CancellationToken cancel)
    {
        var url = Provider.Api() + "/" + path;
        if (query is { Count: > 0 }) url += "?" + string.Join("&", query.Select(q => QueryValue(q.Name) + "=" + QueryValue(q.Value)));
        var headers = new List<(string, string)> { ("Authorization", "Bearer " + token), ("Accept", "application/json") };
        ProviderAnswer answer;
        try
        {
            answer = await http.SendAsync(method, new Uri(url), headers, body is null ? null : Json.Write(body),
                                          body is null ? null : "application/json", cancel).ConfigureAwait(false);
        }
        catch (ProviderUnreachableException) { throw new CloudException(CloudFailure.Unreachable, Provider); }
        var parsed = Json.Parse(answer.Body);
        var text = Encoding.UTF8.GetString(answer.Body, 0, Math.Min(300, answer.Body.Length));
        return new CloudAnswer(answer.Status, parsed as JsonObject ?? new JsonObject(), CloudServers.AllObjects(parsed) ?? [], text);
    }

    /// <summary>The answer of a request that must succeed.</summary>
    public async Task<JsonObject> SendAsync(string method, string path, IReadOnlyList<(string Name, string Value)>? query,
                                            JsonObject? body, CancellationToken cancel)
    {
        var answer = await AnswerAsync(method, path, query, body, cancel).ConfigureAwait(false);
        if (!answer.Ok) throw Failure(answer);
        return answer.Object;
    }

    /// <summary>What a refusal means for the owner: a token that may only read, a token that is not taken, a wait, the
    /// account's limit of servers, or the provider's own words without the token.</summary>
    public CloudException Failure(CloudAnswer answer)
    {
        var says = answer.Says;
        switch (Provider, answer.Status)
        {
            case (CloudProvider.Vultr, 401) when !says.Contains("IP address", StringComparison.OrdinalIgnoreCase):
                return new CloudException(CloudFailure.TokenNotAccepted, Provider);
            case (CloudProvider.Vultr, 403) or (CloudProvider.Akamai, 403):
                return new CloudException(CloudFailure.ReadOnlyToken, Provider);
            case (CloudProvider.Akamai, 401):
                return new CloudException(says.Contains("not authorized", StringComparison.OrdinalIgnoreCase)
                                              ? CloudFailure.ReadOnlyToken : CloudFailure.TokenNotAccepted, Provider);
        }
        if (Provider == CloudProvider.Vultr && answer.Status == 401) return new CloudException(CloudFailure.Refused, Provider, Words(answer));
        if (Provider == CloudProvider.Hetzner && answer.Code == "resource_limit_exceeded") return new CloudException(CloudFailure.Full, Provider);
        if (Provider == CloudProvider.DigitalOcean && says.Contains("droplet limit", StringComparison.OrdinalIgnoreCase))
            return new CloudException(CloudFailure.Full, Provider);
        return (answer.Status, answer.Code) switch
        {
            (401, "token_readonly") or (403, "token_readonly") or (403, "forbidden") => new CloudException(CloudFailure.ReadOnlyToken, Provider),
            (401, _) => new CloudException(CloudFailure.TokenNotAccepted, Provider),
            (429, _) => new CloudException(CloudFailure.RateLimited, Provider),
            _ => new CloudException(CloudFailure.Refused, Provider, Words(answer)),
        };
    }

    /// <summary>The provider's own words for a refusal, on one line and without the token.</summary>
    private string Words(CloudAnswer answer)
    {
        var says = answer.Says.Replace(token, "(not shown)", StringComparison.Ordinal).Trim().Replace("\n", " ", StringComparison.Ordinal);
        // A gateway's own page (a 502 or 504 of HTML) is no words for the owner: its status is.
        var page = says.StartsWith('<') || says.Contains("<html", StringComparison.OrdinalIgnoreCase);
        if (says.Length == 0 || page) return $"it answered {answer.Status} and said nothing.";
        var shown = new StringInfo(says);
        return shown.LengthInTextElements > 300 ? shown.SubstringByTextElements(0, 300) : says;
    }

    /// <summary>A value of a query as Foundation's <c>URLComponents</c> writes the values that this app sends.</summary>
    private static string QueryValue(string value)
    {
        var shown = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            if (b < 0x80 && (char.IsAsciiLetterOrDigit((char)b) || "-._~:@/".Contains((char)b))) shown.Append((char)b);
            else shown.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return shown.ToString();
    }

    public override string ToString() => $"CloudCall({Provider.Name()}, token not shown)";
}

/// <summary>This app's own SSH public key, as one line of <c>authorized_keys</c>, with its MD5 fingerprint as Hetzner and
/// DigitalOcean write it (the Mac's <c>SSHPublicKey</c>).</summary>
internal sealed partial record SshPublicKey(string Line, string Fingerprint)
{
    private static readonly string[] Kinds = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"];

    /// <summary>The key, when it is one: one line, a kind this app knows, and a key whose own bytes name that same kind.</summary>
    public static SshPublicKey? Of(string text)
    {
        var line = text.Trim();
        if (line.Any(c => c is '\n' or '\r' or (char)0x0B or (char)0x0C or (char)0x85 or (char)0x2028 or (char)0x2029) ||
            Encoding.UTF8.GetByteCount(line) > 16_384) return null;
        var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length < 2 || !Kinds.Contains(fields[0]) || fields[1].Length % 4 != 0 || !Base64Shape().IsMatch(fields[1])) return null;
        byte[] blob;
        try { blob = Convert.FromBase64String(fields[1]); }
        catch (FormatException) { return null; }
        if (blob.Length <= 4) return null;
        var length = (long)blob[0] << 24 | (long)blob[1] << 16 | (long)blob[2] << 8 | blob[3];
        if (blob.Length < 4 + length || Encoding.UTF8.GetString(blob, 4, (int)length) != fields[0]) return null;
        var fingerprint = string.Join(":", MD5.HashData(blob).Select(b => b.ToString("x2", CultureInfo.InvariantCulture)));
        return new SshPublicKey(line, fingerprint);
    }

    /// <summary>Its name at the provider, which carries the start of its fingerprint.</summary>
    public string Name => "founderizer-" + Fingerprint.Replace(":", "", StringComparison.Ordinal)[..12];

    /// <summary>Whether a key that a provider lists is this one: the same kind and the same key, whatever its comment.</summary>
    public bool Same(string? listed) =>
        listed is not null && listed.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2)
            .SequenceEqual(Line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2));

    [GeneratedRegex(@"\A[A-Za-z0-9+/]*={0,2}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Base64Shape();
}
