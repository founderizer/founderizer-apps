using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Remote;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Founderizer.Setup.Network;
using Founderizer.Owner.Reads;

namespace Founderizer.Setup.Tests;

/// <summary>A tailnet that the test drives: whether the box holds the fleet's key, and each key and device call.</summary>
internal sealed class StandInNet : IFleetNet
{
    public const string AuthKey = "tskey-auth-kEXAMPLE04-NOTAKEYNOTAKEYNOTAKEY";
    public bool IsHeld { get; set; } = true;
    public List<string> Keys { get; } = [];
    public List<FleetDevice> Devices { get; } = [];
    public List<string> Deleted { get; } = [];
    public FleetKeySetup Setup { get; set; } = new(true, true, null, PolicyPlace.Tailscale);

    public Task<FleetKeySetup> MakeFleetClientAsync(string accessToken, CancellationToken cancel = default)
    {
        if (Setup.KeyMade) IsHeld = true;
        return Task.FromResult(Setup);
    }

    /// <summary>A refusal of the next keys, by the server's name: Tailscale ended the fleet's key, for one.</summary>
    public Func<string, Exception?>? Refuses { get; set; }

    public Task<string> AuthKeyAsync(string hostname, int lifeSeconds, CancellationToken cancel = default)
    {
        lock (Keys) Keys.Add(hostname);
        if (Refuses?.Invoke(hostname) is { } refused) return Task.FromException<string>(refused);
        return Task.FromResult(AuthKey);
    }

    public Task<JoinedDevice?> JoinedAsync(string hostname, DateTimeOffset since, CancellationToken cancel = default) =>
        Task.FromResult<JoinedDevice?>(null);

    public Task<IReadOnlyList<FleetDevice>> DevicesAsync(CancellationToken cancel = default) =>
        Task.FromResult<IReadOnlyList<FleetDevice>>(Devices.ToList());

    public Task DeleteDeviceAsync(string id, CancellationToken cancel = default)
    {
        lock (Deleted) Deleted.Add(id);
        return Task.CompletedTask;
    }
}

/// <summary>**The new hub's owner calls**: its list of servers (the manager on its server or not), a join code, and the
/// sign-in; each write is kept.</summary>
internal sealed class StandInCalls : OwnerReads.ICalls
{
    public string? Database => "db-1";
    /// <summary>The server that the hub lists the manager on, or null for a manager with no server.</summary>
    public string? ManagerOn { get; set; }
    public List<string> Posts { get; } = [];
    /// <summary>The join line that the hub gives for a new server.</summary>
    public string JoinLine { get; set; } = "curl -fsS http://100.64.0.9:8765/join | FLEET_JOIN=7KMQ2PRJ4TVW sh";
    /// <summary>The next reads of GET /ui/servers that the hub does not answer.</summary>
    public int ServersFails { get; set; }

    public Task<Founderizer.Core.OwnerAnswer<T>> GetAsync<T>(string route, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type, int limit,
                                                             CancellationToken cancel) where T : class
    {
        if (route == "ui/servers" && ServersFails > 0)
        {
            ServersFails--;
            throw Founderizer.Core.HubException.NoAnswer();
        }
        var agents = ManagerOn is null ? "[]" : "[\"juno\"]";
        var json = route == "ui/servers"
            ? $"{{\"db\": \"db-1\", \"time\": 1763700100, \"servers\": [{{\"name\": \"{ManagerOn ?? "worker-1"}\", \"hub\": true, \"joined\": true, \"agents\": {agents}, \"available\": false, \"why\": []}}]}}"
            : throw new InvalidOperationException("no read " + route);
        return Task.FromResult(new Founderizer.Core.OwnerAnswer<T>(System.Text.Json.JsonSerializer.Deserialize(json, type)));
    }

    public Task<Founderizer.Core.OwnerAnswer<TAnswer>> PostAsync<TBody, TAnswer>(string route, TBody body,
        System.Text.Json.Serialization.Metadata.JsonTypeInfo<TBody> bodyType,
        System.Text.Json.Serialization.Metadata.JsonTypeInfo<TAnswer> answerType, Guid? requestId, CancellationToken cancel) where TAnswer : class
    {
        lock (Posts) Posts.Add(route);
        var id = requestId!.Value.ToString("D");
        var json = route == "ui/servers/join"
            ? $"{{\"ok\": true, \"request_id\": \"{id}\", \"name\": \"\", \"kind\": \"linux\", \"expires_at\": 1763703600, \"code\": \"7KMQ2PRJ4TVW\", \"line\": \"{System.Text.Json.JsonEncodedText.Encode(JoinLine)}\"}}"
            : route == "ui/error-reports" ? $"{{\"ok\": true, \"request_id\": \"{id}\", \"send\": true}}"
            : $"{{\"ok\": true, \"request_id\": \"{id}\"}}";
        return Task.FromResult(new Founderizer.Core.OwnerAnswer<TAnswer>(System.Text.Json.JsonSerializer.Deserialize(json, answerType)));
    }

    public int SignIns { get { lock (Posts) return Posts.Count(p => p.EndsWith("/signin", StringComparison.Ordinal)); } }
}

/// <summary>A provider that the test drives: one offer of each use, the account's servers, each server that it made and
/// each deletion, and the network status that a made server joins.</summary>
internal sealed class StandInCloud(CloudProvider provider, StandInStatus status) : ICloud
{
    public CloudProvider Provider { get; } = provider;
    public bool IsHeld { get; set; } = true;
    public List<CloudOrder> Orders { get; } = [];
    public List<string> DeletedServers { get; } = [];
    public List<string> FirewallsOf { get; } = [];
    public List<CloudExisting> Existing { get; } = [];
    public Func<CloudOrder, Exception?>? Refuses { get; set; }
    private int next = 100;

    public Task CheckTokenAsync(string pasted, CancellationToken cancel = default) { IsHeld = true; return Task.CompletedTask; }

    public Task<IReadOnlyList<CloudOffer>> OffersAsync(CloudServerUse use, IReadOnlySet<string>? except = null, CancellationToken cancel = default) =>
        Task.FromResult<IReadOnlyList<CloudOffer>>(
            [new CloudOffer(Provider, use == CloudServerUse.Hub ? "cx23" : "cx33", "nbg1", 2, use == CloudServerUse.Hub ? 4 : 8, 40,
                            use == CloudServerUse.Hub ? 5.99m : 9.49m, "EUR")]);

    public Task<IReadOnlyList<CloudExisting>> ServersAsync(CancellationToken cancel = default) =>
        Task.FromResult<IReadOnlyList<CloudExisting>>(Existing.ToList());

    public Task<CloudServer> MakeAsync(CloudOrder order, CancellationToken cancel = default)
    {
        lock (Orders) Orders.Add(order);
        if (Refuses?.Invoke(order) is { } refused) throw refused;
        var id = Interlocked.Increment(ref next).ToString(System.Globalization.CultureInfo.InvariantCulture);
        status.Join(order.Name);
        return Task.FromResult(new CloudServer(Provider, id, order.Name, "203.0.113." + id[^2..], order.Offer?.Type ?? "cx23", "nbg1",
                                               order.Offer?.MonthlyPrice ?? 5.99m, "EUR", "fw-" + id));
    }

    public Task<CloudDeletion> DeleteAsync(string id, Action? accepted = null, CancellationToken cancel = default)
    {
        lock (DeletedServers) DeletedServers.Add(id);
        accepted?.Invoke();
        return Task.FromResult(new CloudDeletion(true));
    }

    public Task<IReadOnlyList<CloudFirewall>> FirewallsAsync(string serverName, CancellationToken cancel = default) =>
        Task.FromResult<IReadOnlyList<CloudFirewall>>([]);

    public Task DeleteFirewallsAsync(string serverName, IReadOnlySet<string> deleted, CancellationToken cancel = default)
    {
        lock (FirewallsOf) FirewallsOf.Add(serverName);
        return Task.CompletedTask;
    }

    public Task DeleteFirewallAsync(string id, CancellationToken cancel = default) => Task.CompletedTask;

    public Task DeleteKeyAsync(string publicKey, CancellationToken cancel = default) => Task.CompletedTask;
}

/// <summary>This PC's <c>tailscale status --json</c>: this PC online at 100.64.0.1, and each server that a provider made
/// online at the next address from 100.64.0.9 on.</summary>
internal sealed class StandInStatus
{
    private readonly List<(string Name, string Address)> peers = [];
    public bool Connected { get; set; } = true;

    public void Join(string name)
    {
        lock (peers) peers.Add((name, "100.64.0." + (9 + peers.Count)));
    }

    public string AddressOf(string name) { lock (peers) return peers.First(p => p.Name == name).Address; }

    public string Json()
    {
        lock (peers)
        {
            var list = string.Join(",", peers.Select((p, i) =>
                $"\"node{i}\": {{\"DNSName\": \"{p.Name}.tail1234.ts.net.\", \"HostName\": \"{p.Name}\", \"TailscaleIPs\": [\"{p.Address}\"], \"Online\": true}}"));
            return Connected
                ? $"{{\"BackendState\": \"Running\", \"Self\": {{\"DNSName\": \"desk.tail1234.ts.net.\", \"TailscaleIPs\": [\"100.64.0.1\"], \"Online\": true}}, \"CurrentTailnet\": {{\"Name\": \"example.com\"}}, \"Peer\": {{{list}}}}}"
                : "{\"BackendState\": \"NeedsLogin\"}";
        }
    }
}

/// <summary>**An owner's server that does not take the app's key yet** (piece L4c): it refuses the app's key and names
/// its ways with the refusal (<see cref="RemoteResult.LoginWays"/>; "publickey" alone by default, a server that takes
/// keys only; null for a server that names none), takes no password (ways with no password way: a password not
/// offered, as <see cref="SshRemote"/> says it, with no list; else a wrong password; with <see cref="AsksNoPassword"/>,
/// a password not offered whatever it named), and takes the owner's key, whose call adds the app's key (with the sudo of
/// <paramref name="user"/>), unless <paramref name="keyCall"/> answers it.</summary>
internal sealed class KeyServer(string user = "root", Func<RemoteCall, byte[]?, RemoteResult?>? keyCall = null)
{
    public static readonly string[] KeysOnly = ["publickey"];
    public bool HasAppKey;
    public IReadOnlyList<string>? Ways { get; init; } = KeysOnly;

    /// <summary>A server that names a password way and then asks for no password on it: keyboard-interactive with no
    /// prompt that hides its answer (a PAM stack of keys or of one-time codes), so the password once is never sent.</summary>
    public bool AsksNoPassword { get; init; }

    public RemoteResult? Answer(RemoteCall call, byte[]? input)
    {
        switch (call.Login)
        {
            case RemoteLogin.PasswordOnce:
                return AsksNoPassword || Ways is { } named && !named.Contains("password") && !named.Contains("keyboard-interactive")
                    ? StandInRemote.Failed(RemoteFailure.LoginNotOffered)
                    : StandInRemote.Failed(RemoteFailure.LoginRefused) with { LoginWays = Ways };
            case RemoteLogin.KeyOnce:
                if (keyCall?.Invoke(call, input) is { } given) return given;
                HasAppKey = true;
                return StandInRemote.Said($"{PasswordOnce.KeyAdded}\n{PasswordOnce.SudoMark}{(user == "root" ? "root" : "nopasswd")}");
            default:
                if (!HasAppKey) return StandInRemote.Failed(RemoteFailure.LoginRefused) with { LoginWays = Ways };
                if (call.Program == "/bin/sh -s" && user != "root") return StandInRemote.Said(Printed.Ready($"user={user}", "uid=1000", "sudo=password"));
                return null;
        }
    }
}

/// <summary>**A first run on a stand-in PC**: a box, records and host keys in a folder of its own, the stand-ins of the
/// tailnet, the providers and the servers, and an installer whose claim is the test's.</summary>
internal sealed class SetupRig : IAsyncDisposable
{
    public string Folder { get; } = Directory.CreateTempSubdirectory("founderizer-setup-").FullName;
    public MemorySecretBox Box { get; } = new();
    public StandInNet Net { get; } = new();
    public StandInStatus Status { get; } = new();
    public Dictionary<CloudProvider, StandInCloud> Clouds { get; } = [];
    public StandInRemote Remote { get; }
    public HostKeys HostKeys { get; }
    public SetupRecords Records { get; }
    public OwnerStore Owner { get; }
    public MemoryChoices Choices { get; } = new();
    public List<Uri> Connected { get; } = [];
    public List<(Uri Hub, bool Deleted)> Forgotten { get; } = [];
    public StandInCalls Calls { get; } = new();
    /// <summary>The new hub's reading that the owner's computer holds: null until the hub answered it.</summary>
    public Founderizer.Core.MobileSnapshot? Fleet { get; set; }

    /// <summary>A reading of a new fleet: its manager on Claude Code, and the hub's features of the setup.</summary>
    public static Founderizer.Core.MobileSnapshot NewFleet() =>
        new(1, "db-1", 1763700100, [new Founderizer.Core.MobileAgent("juno", "manager", "claude", 0, [])], [], [], [], [], [],
            UiFeatures: ["servers", "machines", "machine_signin", "agent_setup", "manager_server", "error_reports"]);
    public List<InstallPlan> Plans { get; } = [];
    public SetupStore Store { get; }

    public SetupRig(Func<RemoteCall, RemoteResult?>? first = null)
    {
        foreach (var provider in CloudProviders.All) Clouds[provider] = new StandInCloud(provider, Status) { IsHeld = provider == CloudProvider.Hetzner };
        Remote = Answering(first);
        Remote.HoldsAppKey = () => Box.Read(AppSshKey.BoxName) is not null;
        HostKeys = new HostKeys(Folder);
        Records = new SetupRecords(Folder, "launch-1");
        Owner = new OwnerStore(new StoreSettings { Folder = Path.Combine(Folder, "store"), Keys = new MemoryKeyStore(), Box = Box, ClientLabel = "Founderizer for Windows (test)" });
        Store = new SetupStore(new SetupSettings
        {
            Owner = Owner, Box = Box, Remote = Remote, HostKeys = HostKeys, Records = Records, Tailscale = Net,
            Cloud = p => Clouds[p], Status = _ => Task.FromResult<string?>(Status.Json()), Choices = Choices,
            Pause = (_, cancel) => Task.Delay(1, cancel),
            Installer = (plan, key, sudo) =>
            {
                lock (Plans) Plans.Add(plan);
                return new Installer(plan, key, sudo, (_, _, _) => Task.FromResult<string?>(null), null, new StandInClock());
            },
            ConnectOwner = hub => { lock (Connected) Connected.Add(hub); return Task.CompletedTask; },
            ForgetHub = (hub, deleted) => { lock (Forgotten) Forgotten.Add((hub, deleted)); },
            Calls = Calls, Fleet = () => Fleet,
            JoinReads = 2, JoinReadEvery = TimeSpan.FromMilliseconds(1), JoinClock = new StandInClock(),
        });
    }

    /// <summary>A server that answers each program by what it is, as L3's tests' server: the check, the network step, the
    /// claim's log at the server's own address, the installer's end and the checks; "ok" for the rest.</summary>
    private static StandInRemote Answering(Func<RemoteCall, RemoteResult?>? first) =>
        new((call, _) =>
        {
            if (first?.Invoke(call) is { } given) return given;
            var program = call.Program;
            if (program == "/bin/sh -s") return StandInRemote.Said(Printed.Ready());
            if (program.Contains("tailscale ip -4", StringComparison.Ordinal) && !program.Contains("fleet-on-network", StringComparison.Ordinal))
                return StandInRemote.Said(ClaimCode.IsPrivateAddress(call.Target.Host) ? call.Target.Host : Printed.PrivateAddress);
            if (program.Contains("tail -n 60", StringComparison.Ordinal)) return StandInRemote.Said(Printed.ClaimLog(call.Target.Host));
            if (program.Contains("tail -n 40", StringComparison.Ordinal)) return StandInRemote.Said("READY");
            if (program.Contains("FLEET_JOIN=", StringComparison.Ordinal)) return StandInRemote.Said("READY");
            if (program.Contains("verify --json", StringComparison.Ordinal)) return StandInRemote.Said(Printed.Checklist);
            if (program == PasswordOnce.WorksProgram) return StandInRemote.Said(PasswordOnce.KeyWorks);
            if (program.Contains(PasswordOnce.KeyAdded, StringComparison.Ordinal))
                return StandInRemote.Said(PasswordOnce.KeyAdded + "\n" + PasswordOnce.SudoMark + "root");
            return StandInRemote.Said("ok");
        });

    /// <summary>The first pages, as an owner goes through them: the reports, the name, the AI, the slider.</summary>
    public void ThroughTheFirstPages(ServersStep step = ServersStep.Two, string name = "Juno", string ai = "claude")
    {
        Store.ReadPc(Status.Json());
        Store.SetUp();
        Store.ChooseReports(true);
        Store.TypeName(name);
        Store.ChooseName();
        Store.ChooseAi(ai);
        Store.MoveSlider(step);
        Store.ChooseServers();
    }

    /// <summary>Waits until <paramref name="holds"/> is true of the store's state, at most a few seconds of real time.</summary>
    public async Task<SetupState> Until(Func<SetupState, bool> holds, string what)
    {
        for (var i = 0; i < 500; i++)
        {
            if (holds(Store.State)) return Store.State;
            await Task.Delay(10);
        }
        throw new TimeoutException("the first run never came to: " + what + $" (page {Store.State.Page}, hub's stage {Store.State.Cloud?.Stage}, failure {Store.State.Cloud?.Failure ?? Store.State.Install.Failure})");
    }

    public async ValueTask DisposeAsync()
    {
        await Owner.DisposeAsync();
        try { Directory.Delete(Folder, recursive: true); } catch (IOException) { }
    }
}
