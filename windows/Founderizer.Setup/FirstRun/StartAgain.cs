using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.Install;
using Founderizer.Setup.Network;

namespace Founderizer.Setup.FirstRun;

/// <summary>**"Start again": what the app may delete of one fleet, and how the run goes** (the Mac's
/// FleetCore/StartAgain.swift; the owner's "Yes, build it" of 15 November 2026, and "the start again should clean
/// tailscale etc and any trace"). Two rules stand over all of it:
///
/// 1. **It deletes a server only when this PC can prove that the server is this fleet's**: the provider's own id of
///    the server in this PC's build records for this hub. A provider's label names no fleet, and a name alone is never
///    a proof.
/// 2. **It never asks the hub.** It uses the provider's token and the fleet's Tailscale key that this PC keeps.
///
/// The Mac has a second proof, its <c>MadeServers</c> notes (a name and an id for a hub, with no provider). The PC
/// writes no such note: every server that it makes has a build record with the hub's address (<see
/// cref="BuildRecord.Hub"/>), which is the first proof.</summary>
public static class StartAgain
{
    /// <summary>One server that this PC's records prove to be this fleet's, at its provider.</summary>
    public sealed record Server(CloudProvider Provider, string ServerId, string Name, CloudServerUse Use, string? Type = null,
                                decimal? MonthlyPrice = null, string? Currency = null, BuildRecord? Build = null)
    {
        public string Id => Provider.Raw() + "|" + ServerId;
    }

    /// <summary>What this PC's records prove for one hub: the servers that a run deletes, the hub's own first; the
    /// builds whose server the provider no longer has; and every other build that can have made a machine.</summary>
    public sealed record Proven(IReadOnlyList<Server> Servers, IReadOnlyList<BuildRecord> Gone, IReadOnlyList<BuildRecord> Rivals)
    {
        /// <summary>The builds whose device a run removes when the private network still has it.</summary>
        public IReadOnlyList<BuildRecord> Builds => Servers.Where(s => s.Build is not null).Select(s => s.Build!).Concat(Gone).ToList();
    }

    /// <summary>**The servers of this hub that this PC may delete**: each build record with this hub and the provider's
    /// id of its server, at the record's own provider. When that provider's list was read and no longer has the id, the
    /// server is gone, unless the machine that the build made still runs (<paramref name="alive"/>): a list is the list of
    /// one token. When the list was not read, the row is the record's own, with no type and no price. <paramref
    /// name="hub"/> is the hub's address in the PC's own form; <paramref name="builds"/> every kept build record;
    /// <paramref name="listed"/> the servers of each provider whose list was read now (a provider whose read failed is not
    /// in it); <paramref name="alive"/> says that the machine of a build still runs.</summary>
    public static Proven ProvenFor(string hub, IEnumerable<BuildRecord> builds, IReadOnlyDictionary<CloudProvider, IReadOnlyList<CloudExisting>> listed,
                                   Func<BuildRecord, bool>? alive = null)
    {
        var all = builds.ToList();
        var servers = new List<Server>();
        var gone = new List<BuildRecord>();
        var taken = new HashSet<string>(StringComparer.Ordinal);
        foreach (var build in all)
        {
            if (!IsOwn(build, hub) || CloudProviders.FromRaw(build.Provider) is not { } provider) continue;
            var id = build.ServerId!;
            if (!taken.Add(provider.Raw() + "|" + id)) continue;
            var use = build.Use == "hub" ? CloudServerUse.Hub : CloudServerUse.Agent;
            if (!listed.TryGetValue(provider, out var list))
            {
                servers.Add(new Server(provider, id, build.Name, use, Build: build));
                continue;
            }
            var there = list.FirstOrDefault(s => s.Id == id);
            if (there is null)
            {
                if (alive?.Invoke(build) == true) servers.Add(new Server(provider, id, build.Name, use, Build: build));
                else gone.Add(build);
                continue;
            }
            servers.Add(new Server(provider, id, build.Name, use, there.Type.Length == 0 ? build.Type : there.Type, build.MonthlyPrice,
                                   build.Currency, build));
        }
        var sorted = servers.OrderBy(s => s.Use == CloudServerUse.Hub ? 0 : 1)
                            .ThenBy(s => s.Build?.Began ?? DateTimeOffset.MaxValue)
                            .ThenBy(s => s.Name, StringComparer.Ordinal).ThenBy(s => s.Id, StringComparer.Ordinal).ToList();
        return new Proven(sorted, gone, Rivals(hub, all));
    }

    /// <summary>A record of a build is this hub's own for the proof: it names this hub, and it has an id of the provider.</summary>
    internal static bool IsOwn(BuildRecord build, string hub) => build.Hub == hub && build.ServerId is { } id && CloudServers.IsId(id);

    /// <summary>**The records of every other build that can have made a machine**: of another hub, of none, or with no
    /// id of the provider. A try that left nothing at its provider made no machine, and is no rival.</summary>
    public static IReadOnlyList<BuildRecord> Rivals(string hub, IEnumerable<BuildRecord> builds) =>
        builds.Where(b => !IsOwn(b, hub) && b.AtProvider != AtProvider.Nothing).ToList();

    /// <summary>How long before a build's start its device can have been made, and how long after the provider's answer
    /// a server can take to come up on the private network: its join key's life, with the same slack.</summary>
    public static readonly TimeSpan DeviceSlack = TimeSpan.FromSeconds(300);
    public static readonly TimeSpan DeviceWindow = TimeSpan.FromSeconds(CloudJoin.KeyLife) + DeviceSlack;

    /// <summary>**The one device of the private network that this build made**, or null: its hostname is the build's
    /// name, it has the fleet's tag, it is authorized and the tailnet's own, and it was made within the build's window.
    /// Two devices that fit prove nothing; a device that fits another build of that name too proves nothing; this PC is
    /// never the answer.</summary>
    public static FleetDevice? Device(BuildRecord build, IReadOnlyList<FleetDevice> devices, IReadOnlySet<string>? thisPc = null,
                                      string? thisPcName = null, IReadOnlyList<BuildRecord>? rivals = null)
    {
        var wanted = build.Name.ToLowerInvariant();
        if (wanted.Length == 0 || build.ServerId is null) return null;
        if (thisPcName is { Length: > 0 } own && own.ToLowerInvariant() == wanted) return null;
        var others = (rivals ?? []).Where(r => r.Id != build.Id && r.Name.ToLowerInvariant() == wanted).ToList();
        var found = devices.Where(d =>
            d.Hostname.ToLowerInvariant() == wanted && d.Authorized && !d.External && d.Tags.Contains(TailscaleApi.Tag) &&
            d.Created is { } created && Fits(created, build) && !(thisPc ?? new HashSet<string>()).Overlaps(d.Addresses) &&
            !others.Any(o => Fits(created, o))).ToList();
        return found.Count == 1 ? found[0] : null;
    }

    internal static bool Fits(DateTimeOffset created, BuildRecord build) =>
        created >= build.Began - DeviceSlack && created <= (build.MadeAt ?? build.Began) + DeviceWindow;

    /// <summary>**The machine that this build made still runs**: its one device is there, and Tailscale says that it
    /// holds its connection, or this PC's own Tailscale shows one of its addresses online.</summary>
    public static bool IsAlive(BuildRecord build, IReadOnlyList<FleetDevice> devices, IReadOnlySet<string> online,
                               IReadOnlySet<string>? thisPc = null, string? thisPcName = null, IReadOnlyList<BuildRecord>? rivals = null) =>
        Device(build, devices, thisPc, thisPcName, rivals) is { } device && (device.Connected || online.Overlaps(device.Addresses));

    /// <summary>The addresses that this PC's own Tailscale shows online now, out of its <c>tailscale status --json</c>.</summary>
    public static IReadOnlySet<string> OnlineAddresses(string? json) => Addresses(json, peers: true);

    /// <summary>This PC's own addresses on the private network, out of its <c>tailscale status --json</c>.</summary>
    public static IReadOnlySet<string> OwnAddresses(string? json) => Addresses(json, peers: false);

    private static IReadOnlySet<string> Addresses(string? json, bool peers)
    {
        var found = new HashSet<string>(StringComparer.Ordinal);
        if (string.IsNullOrEmpty(json)) return found;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return found;
            IEnumerable<JsonElement> nodes = [];
            if (peers && root.TryGetProperty("Peer", out var all) && all.ValueKind == JsonValueKind.Object)
                nodes = all.EnumerateObject().Select(p => p.Value)
                           .Where(p => p.ValueKind == JsonValueKind.Object && p.TryGetProperty("Online", out var on) && on.ValueKind == JsonValueKind.True);
            else if (!peers && root.TryGetProperty("Self", out var self) && self.ValueKind == JsonValueKind.Object)
                nodes = [self];
            foreach (var node in nodes)
                if (node.TryGetProperty("TailscaleIPs", out var ips) && ips.ValueKind == JsonValueKind.Array)
                    foreach (var ip in ips.EnumerateArray())
                        if (ip.ValueKind == JsonValueKind.String) found.Add(ip.GetString()!);
        }
        catch (JsonException) { }
        return found;
    }

    // ---------------------------------------------------------------- the plan: what the page shows before anything goes

    public sealed record Section(string Id, string Title, IReadOnlyList<Row> Rows);

    public sealed record Row(string Id, string Title, string Symbol, string Detail);

    /// <summary>What one run takes away, as the page "Start again" shows it before the press. <see cref="Builds"/>: the
    /// builds whose device the run removes when the private network still has it, only the ones whose machine the page
    /// names (all of them when the read of the private network failed).</summary>
    public sealed record Plan(string Hub, IReadOnlyList<Server> Servers, IReadOnlyList<BuildRecord> Builds, IReadOnlyList<BuildRecord> Rivals,
                              IReadOnlyList<string> Machines)
    {
        public static Plan Of(string hub, Proven proven, IReadOnlyList<FleetDevice>? devices, IReadOnlySet<string>? thisPc = null,
                              string? thisPcName = null)
        {
            var named = new List<BuildRecord>();
            var names = new List<string>();
            foreach (var build in proven.Builds)
            {
                if (devices is not null && Device(build, devices, thisPc, thisPcName, proven.Rivals) is null) continue;
                named.Add(build);
                if (!names.Contains(build.Name)) names.Add(build.Name);
            }
            return new Plan(hub, proven.Servers, named, proven.Rivals, names);
        }

        /// <summary>The providers that have a server to delete, in the order of the rows.</summary>
        public IReadOnlyList<CloudProvider> Providers => Servers.Select(s => s.Provider).Distinct().ToList();

        public IReadOnlyList<Server> ServersAt(CloudProvider provider) => Servers.Where(s => s.Provider == provider).ToList();

        /// <summary>The sections of the page, in its order. A section with no row is not there; the app's own always is.</summary>
        public IReadOnlyList<Section> Sections(CultureInfo? culture = null)
        {
            var sections = Providers.Select(provider =>
            {
                var its = ServersAt(provider);
                return new Section(provider.Raw(), Words.DeletedAt(provider),
                    [.. its.Select(s => new Row(s.Id, s.Name, "server", Words.Detail(s, culture))),
                     new Row(provider.Raw() + "|firewalls", Words.Firewalls(its.Count, provider), "shield", Words.MadeFor(its.Count, provider))]);
            }).ToList();
            if (Machines.Count > 0)
                sections.Add(new Section("tailscale", "Removed from your Tailscale network",
                    [new Row("machines", Words.MachinesOf(Machines), "network", "This PC and your other devices stay in the network.")]));
            sections.Add(new Section("app", "Removed from the Founderizer app",
                [new Row("app", "What the app keeps of this fleet", "tray", "Its address, its keys and its copies. Nothing else on this PC changes.")]));
            return sections;
        }

        /// <summary>The steps of a run, in the order of the page: each server, then each provider's firewalls and key, then
        /// the machines of the private network, then the app's own part.</summary>
        public IReadOnlyList<Step> Steps()
        {
            var kinds = new List<StepKind>();
            kinds.AddRange(Servers.Select(s => (StepKind)new StepKind.ServerStep(s)));
            kinds.AddRange(Providers.Select(p => (StepKind)new StepKind.Firewalls(p, ServersAt(p))));
            if (Machines.Count > 0) kinds.Add(new StepKind.MachinesStep(Machines.Count));
            kinds.Add(new StepKind.App());
            return kinds.Select((kind, i) => new Step(i, kind)).ToList();
        }
    }

    /// <summary>The words of the pages, and their variants for another count or another provider (the Mac's with "PC").</summary>
    public static class Words
    {
        public const string Start = "Start again";
        public const string Starting = "Starting again";
        public const string Press = "Delete and start again";
        public const string StillCosts = "The server is still there and still costs money.";

        public static string DeletedAt(CloudProvider provider) => $"Deleted at {provider.Name()}";

        /// <summary>"Your fleet's server · CX23 · €5.49 a month": what the server is for, then its type and its price a
        /// month, each only when the app knows it.</summary>
        public static string Detail(Server server, CultureInfo? culture = null)
        {
            var parts = new List<string> { server.Use == CloudServerUse.Hub ? "Your fleet's server" : "The manager's server" };
            if (server.Type is { Length: > 0 } type) parts.Add(server.Provider == CloudProvider.Hetzner ? type.ToUpperInvariant() : type);
            if (server.MonthlyPrice is { } price && server.Currency is { Length: > 0 } currency) parts.Add(Monthly(price, currency, culture));
            return string.Join(" · ", parts);
        }

        /// <summary>"€5.49 a month", in this PC's own way of writing an amount (as <see cref="CloudOffer.Monthly"/>).</summary>
        public static string Monthly(decimal price, string currency, CultureInfo? culture = null) =>
            new CloudOffer(CloudProvider.Hetzner, "", "", null, null, null, price, currency).Monthly(culture);

        /// <summary>The row of what the app made beside the servers. Akamai keeps no SSH key of its own.</summary>
        public static string Firewalls(int count, CloudProvider provider) => (count == 1, provider == CloudProvider.Akamai) switch
        {
            (true, false) => "Its firewall and Founderizer's SSH key",
            (false, false) => $"Their {count} firewalls and Founderizer's SSH key",
            (true, true) => "Its firewall",
            _ => $"Their {count} firewalls",
        };

        public static string MadeFor(int count, CloudProvider provider) => (count == 1, provider == CloudProvider.Akamai) switch
        {
            (true, false) => "Founderizer made them for this server.",
            (true, true) => "Founderizer made it for this server.",
            _ => "Founderizer made them for these servers.",
        };

        /// <summary>"The machine worker-1", "The machines worker-1 and worker-2", "The machines worker-1, worker-2 and worker-3".</summary>
        public static string MachinesOf(IReadOnlyList<string> names) =>
            names.Count > 1 ? $"The machines {string.Join(", ", names.Take(names.Count - 1))} and {names[^1]}" : $"The machine {names.FirstOrDefault() ?? ""}";

        /// <summary>The row of one step while the run goes.</summary>
        public static string Title(StepKind kind) => kind switch
        {
            StepKind.ServerStep s => $"Delete {s.Server.Name} at {s.Server.Provider.Name()}",
            StepKind.Firewalls f => (f.Servers.Count == 1, f.Provider == CloudProvider.Akamai) switch
            {
                (true, false) => $"Delete its firewall and SSH key at {f.Provider.Name()}",
                (false, false) => $"Delete their firewalls and SSH key at {f.Provider.Name()}",
                (true, true) => $"Delete its firewall at {f.Provider.Name()}",
                _ => $"Delete their firewalls at {f.Provider.Name()}",
            },
            StepKind.MachinesStep m => m.Count switch
            {
                1 => "Remove the machine from Tailscale",
                2 => "Remove both machines from Tailscale",
                _ => $"Remove the {m.Count} machines from Tailscale",
            },
            _ => "Clear what the app keeps of this fleet",
        };

        public static string Word(StepState state) => state switch
        {
            StepState.Waiting => "Waiting",
            StepState.Now => "Now",
            StepState.Done => "Done",
            _ => "Failed",
        };

        /// <summary>The orange line of a failed step: what the provider or the private network said, in the app's own
        /// words. A token that the provider does not take is one short sentence: this page has no field for another.</summary>
        public static string Says(Exception error, CloudProvider? provider = null) => error switch
        {
            CloudException { Failure: CloudFailure.TokenNotAccepted or CloudFailure.ReadOnlyToken } cloud => $"{cloud.Provider.Name()} refused the token.",
            CloudException cloud => cloud.Message,
            FleetKeyException key => key.Message,
            _ => provider is { } p ? CloudException.Words(CloudFailure.Unreachable, p, null, [])
                                   : new FleetKeyException(FleetKeyFailure.Unreachable).Message,
        };

        /// <summary>Words that end as a sentence ends, so that another sentence can follow them.</summary>
        public static string Sentence(string words)
        {
            var trimmed = words.Trim();
            return trimmed.Length == 0 || ".!?".Contains(trimmed[^1]) ? trimmed : trimmed + ".";
        }
    }

    // ---------------------------------------------------------------- the steps and the run

    public enum StepState { Waiting, Now, Done, Failed }

    public abstract record StepKind
    {
        /// <summary>The provider deletes this one server, by its id.</summary>
        public sealed record ServerStep(Server Server) : StepKind;
        /// <summary>The firewalls of the servers that this run deleted at the provider, and the app's own SSH key there.</summary>
        public sealed record Firewalls(CloudProvider Provider, IReadOnlyList<Server> Servers) : StepKind;
        /// <summary>The devices that the builds made go from the private network; the count is the row's.</summary>
        public sealed record MachinesStep(int Count) : StepKind;
        /// <summary>The app clears what it keeps of this fleet.</summary>
        public sealed record App : StepKind;
    }

    /// <summary>One step of a run, as its row shows it. <c>Deleted</c>, for a server's step: **the provider took this
    /// run's deletion of the server**; a server that the provider did not have (404) is done too, and this run did not
    /// delete it.</summary>
    public sealed record Step(int Id, StepKind Kind, StepState State = StepState.Waiting, string? Says = null, string? FailedTitle = null,
                              bool Deleted = false)
    {
        public string Title => Words.Title(Kind);
    }

    /// <summary>The calls of a run. The rules give each one only what the proof holds: a server's own id, the name of a
    /// server that this run deleted, a device's own id.</summary>
    public interface IWork
    {
        /// <summary>Deletes this one server at its provider, by its id; <paramref name="accepted"/> at the moment the
        /// provider takes the deletion.</summary>
        Task<CloudDeletion> DeleteServerAsync(Server server, Action accepted, CancellationToken cancel);
        Task DeleteFirewallsAsync(CloudProvider provider, string name, IReadOnlySet<string> deleted, CancellationToken cancel);
        Task DeleteKeyAsync(CloudProvider provider, CancellationToken cancel);
        Task<IReadOnlyList<FleetDevice>> DevicesAsync(CancellationToken cancel);
        Task DeleteDeviceAsync(string id, CancellationToken cancel);
        /// <summary>This PC's own addresses on the private network, and its own name.</summary>
        Task<(IReadOnlySet<string> Addresses, string? Name)> ThisPcAsync(CancellationToken cancel);
        /// <summary>The addresses that this PC's own Tailscale shows online now.</summary>
        Task<IReadOnlySet<string>> OnlineAsync(CancellationToken cancel);
        /// <summary>A provider took a deletion of this server from this app, in this start of the app.</summary>
        void NoteDeleted(CloudProvider provider, string id);
        void ForgetDeleted(CloudProvider provider, string id);
        bool DeletedBefore(CloudProvider provider, string id);
        /// <summary>Clears what the app keeps of this fleet, its record of host keys among it.
        /// <paramref name="hubServerDeleted"/>: this run deleted the hub's own server.</summary>
        Task ClearAppAsync(bool hubServerDeleted, CancellationToken cancel);
    }

    private sealed class Stop(string title, string says) : Exception(says)
    {
        public string Title { get; } = title;
        public string Says { get; } = says;
    }

    /// <summary>**Runs the steps that are not done, one at a time and in their order, and stops at the first that
    /// fails** (the Mac's <c>run</c>). A step that is done never runs again, so Try again goes on at the step that
    /// failed. Nothing after a failed step runs, and **the app's own step runs last and only when every step before it is
    /// done**. A server that the provider does not have for this token, and whose machine still runs, is not deleted:
    /// its step fails with the provider's own answer. It asks the hub nothing, and no clock ends a step.</summary>
    public static async Task<IReadOnlyList<Step>> RunAsync(IReadOnlyList<Step> given, IReadOnlyList<BuildRecord> builds,
                                                           IReadOnlyList<BuildRecord> rivals, IWork work, Action<IReadOnlyList<Step>>? tell = null,
                                                           CancellationToken cancel = default)
    {
        var steps = given.Select(s => s.State == StepState.Done ? s : s with { State = StepState.Waiting, Says = null, FailedTitle = null }).ToList();
        for (var index = 0; index < steps.Count; index++)
        {
            if (steps[index].State == StepState.Done) continue;
            if (cancel.IsCancellationRequested || !steps.Take(index).All(s => s.State == StepState.Done)) break;
            steps[index] = steps[index] with { State = StepState.Now };
            tell?.Invoke(steps.ToList());
            if (cancel.IsCancellationRequested)
            {
                steps[index] = steps[index] with { State = StepState.Waiting };
                break;
            }
            try
            {
                switch (steps[index].Kind)
                {
                    case StepKind.ServerStep { Server: var server }:
                        var taken = 0;
                        try
                        {
                            var outcome = await work.DeleteServerAsync(server, () =>
                            {
                                Interlocked.Exchange(ref taken, 1);
                                work.NoteDeleted(server.Provider, server.ServerId);
                            }, cancel).ConfigureAwait(false);
                            if (outcome.Deleted)
                            {
                                steps[index] = steps[index] with { Deleted = true };
                                work.NoteDeleted(server.Provider, server.ServerId);
                            }
                            else if (server.Build is { } build && !work.DeletedBefore(server.Provider, server.ServerId))
                            {
                                var own = await work.ThisPcAsync(cancel).ConfigureAwait(false);
                                IReadOnlyList<FleetDevice>? devices = null;
                                try { devices = await work.DevicesAsync(cancel).ConfigureAwait(false); }
                                catch (Exception e) when (e is not OperationCanceledException) { }
                                if (devices is not null &&
                                    IsAlive(build, devices, await work.OnlineAsync(cancel).ConfigureAwait(false), own.Addresses, own.Name, rivals))
                                    throw (Exception?)outcome.NotThere ?? new CloudException(CloudFailure.NotUnderstood, server.Provider);
                            }
                        }
                        catch (Exception error) when (error is not Stop)
                        {
                            if (Volatile.Read(ref taken) == 1 && error is CloudException { Failure: not CloudFailure.Unreachable })
                                work.ForgetDeleted(server.Provider, server.ServerId);
                            throw new Stop($"{server.Name} is not deleted", Words.Sentence(Words.Says(error, server.Provider)) + " " + Words.StillCosts);
                        }
                        break;
                    case StepKind.Firewalls { Provider: var provider } firewalls:
                        var took = steps.Where(s => s is { Deleted: true, Kind: StepKind.ServerStep { Server: var one } } && one.Provider == provider)
                                        .Select(s => ((StepKind.ServerStep)s.Kind).Server).ToList();
                        var deleted = took.Select(s => s.ServerId).ToHashSet(StringComparer.Ordinal);
                        Stop? stop = null;
                        foreach (var name in took.Select(s => s.Name).Distinct())
                        {
                            try { await work.DeleteFirewallsAsync(provider, name, deleted, cancel).ConfigureAwait(false); }
                            catch (Exception error) when (error is not OperationCanceledException)
                            {
                                stop ??= new Stop(firewalls.Servers.Count == 1 ? "The firewall is not deleted" : "The firewalls are not deleted",
                                                  Words.Says(error, provider));
                            }
                        }
                        if (provider != CloudProvider.Akamai && took.Count > 0)
                        {
                            try { await work.DeleteKeyAsync(provider, cancel).ConfigureAwait(false); }
                            catch (Exception error) when (error is not OperationCanceledException)
                            {
                                stop ??= new Stop("The SSH key is not deleted", Words.Says(error, provider));
                            }
                        }
                        if (stop is not null) throw stop;
                        break;
                    case StepKind.MachinesStep:
                        var current = builds.FirstOrDefault()?.Name ?? "";
                        try
                        {
                            var devices = await work.DevicesAsync(cancel).ConfigureAwait(false);
                            var own = await work.ThisPcAsync(cancel).ConfigureAwait(false);
                            var online = await work.OnlineAsync(cancel).ConfigureAwait(false);
                            var gone = steps.Where(s => s is { Deleted: true, Kind: StepKind.ServerStep })
                                            .Select(s => ((StepKind.ServerStep)s.Kind).Server.Id).ToHashSet(StringComparer.Ordinal);
                            var removed = new HashSet<string>(StringComparer.Ordinal);
                            foreach (var build in builds)
                            {
                                current = build.Name;
                                if (Device(build, devices, own.Addresses, own.Name, rivals) is not { } device || !removed.Add(device.Id)) continue;
                                var id = build.ServerId ?? "";
                                var provider = CloudProviders.FromRaw(build.Provider);
                                var deletedHere = provider is { } p && gone.Contains(p.Raw() + "|" + id);
                                if (!deletedHere && (device.Connected || online.Overlaps(device.Addresses)) &&
                                    !(provider is { } q && work.DeletedBefore(q, id)))
                                    throw new Stop($"{current} is not deleted", Words.StillCosts);
                                await work.DeleteDeviceAsync(device.Id, cancel).ConfigureAwait(false);
                            }
                        }
                        catch (Exception error) when (error is not Stop and not OperationCanceledException)
                        {
                            throw new Stop($"{current} is not removed", Words.Says(error));
                        }
                        break;
                    default:
                        var hubServerDeleted = steps.Any(s => s is { State: StepState.Done, Deleted: true, Kind: StepKind.ServerStep { Server: var one } } &&
                                                              one.Use == CloudServerUse.Hub && one.Build is not null);
                        await work.ClearAppAsync(hubServerDeleted, cancel).ConfigureAwait(false);
                        break;
                }
                steps[index] = steps[index] with { State = StepState.Done };
            }
            catch (Exception error)
            {
                var stop = error as Stop;
                steps[index] = steps[index] with
                {
                    State = StepState.Failed,
                    Says = stop?.Says ?? Words.Says(error),
                    FailedTitle = stop?.Title,
                };
                tell?.Invoke(steps.ToList());
                return steps;
            }
            tell?.Invoke(steps.ToList());
        }
        return steps;
    }

    // ---------------------------------------------------------------- the address that a first run's hub will have

    /// <summary>The hub's port on the private network.</summary>
    public const int HubPort = 8765;

    /// <summary>**A hub's address as the app writes it for a server's address on the private network**: that address at
    /// the hub's port, with the last slash of the PC's own form of a hub (<see cref="Installer.ClaimedHub"/>). The one
    /// form for the address that a claim gives the app, and the address under which a first run's server is kept before
    /// any hub exists.</summary>
    public static string HubText(string address) => $"http://{address}:{HubPort}/";

    /// <summary>The hub's address for a server at this address on the private network; null for what is no such address.</summary>
    public static string? HubAddress(string address) => ClaimCode.IsPrivateAddress(address) ? HubText(address) : null;

    /// <summary>**The link "Start again" shows on the manager's server page** only while those pages give the manager its
    /// first server, no install and no build of a server runs, the page does not ask the hub, and the kept reading has no
    /// other agent than the manager and no server with an agent on it.</summary>
    public static bool Offers(bool givesManagerItsServer, bool runs, bool asksHub, int otherAgents, int serversWithAnAgent) =>
        givesManagerItsServer && !runs && !asksHub && otherAgents == 0 && serversWithAnAgent == 0;
}
